package agent

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The same vector is asserted by the relay (test/phones.test.js): the Mac and
// the relay must derive the same credential for a phone.
func TestPhoneRelaySecretMatchesTheRelay(t *testing.T) {
	macSecret := base64.RawURLEncoding.EncodeToString([]byte(strings.Repeat("*", 32)))
	got, err := derivePhoneRelaySecret(macSecret, "dPhoneOne")
	if err != nil {
		t.Fatal(err)
	}
	if want := "8Yon2Jg2hJkLfWpBFnytJ0CCn9V14ZTubWeV265o2Hw"; got != want {
		t.Fatalf("phone secret = %s, want %s", got, want)
	}
	if _, err := derivePhoneRelaySecret("short", "dPhoneOne"); err == nil {
		t.Fatal("a malformed Mac credential must not derive a phone credential")
	}
}

func TestPhoneRelayIDIsStableAndDistinctPerPhone(t *testing.T) {
	first := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("a", 32)))
	second := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("b", 32)))
	idA, err := phoneRelayID(first)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := phoneRelayID(first)
	idB, _ := phoneRelayID(second)
	if idA != again || idA == idB {
		t.Fatalf("ids: %s %s %s", idA, again, idB)
	}
	if !strings.HasPrefix(idA, "d") || !relayKeyIDPattern.MatchString(idA) {
		t.Fatalf("id %q is not a relay phone id", idA)
	}
	if _, err := phoneRelayID("not-a-key"); err == nil {
		t.Fatal("an invalid public key must not get an id")
	}
}

func phoneTestAgent(t *testing.T, relayURL string, devices ...string) *Agent {
	t.Helper()
	state := &State{DeviceID: "device-1"}
	for _, pub := range devices {
		if _, err := state.UpsertPairedDevice("phone", pub, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	return &Agent{
		relayBaseURL: relayURL + "/connect",
		state:        state,
		credentials:  testRelayCredentials(t, "device-1"),
	}
}

func TestSyncRelayPhonesSendsTheTrustedPhonesAndLearnsSupport(t *testing.T) {
	pub := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("a", 32)))
	var got struct {
		Phones []string `json:"phones"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut || r.URL.Path != "/phones/device-1" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		if !strings.Contains(r.Header.Get("Authorization"), ".phones.") {
			t.Errorf("token is not scoped to the phone list: %s", r.Header.Get("Authorization"))
		}
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		_, _ = w.Write([]byte(`{"locked":false,"phones":1}`))
	}))
	defer server.Close()

	a := phoneTestAgent(t, server.URL, pub)
	if !a.syncRelayPhones(context.Background()) {
		t.Fatal("a relay that accepts the list supports per-phone credentials")
	}
	want, _ := phoneRelayID(pub)
	if len(got.Phones) != 1 || got.Phones[0] != want {
		t.Fatalf("phones = %v, want [%s]", got.Phones, want)
	}
}

func TestAnOlderRelayKeepsTheSharedCredential(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	defer server.Close()
	a := phoneTestAgent(t, server.URL)
	a.phoneCredentialsSupported.Store(true)
	if a.syncRelayPhones(context.Background()) {
		t.Fatal("a relay without the route does not support per-phone credentials")
	}
	a.refreshPairingCode()
	if info, _ := a.buildPairingInfo(); info.RelayPairID != "" || info.RelayPairSecret != "" {
		t.Fatalf("pairing info offers a pairing-window credential the relay would refuse: %+v", info)
	}
}

func TestARelayErrorDoesNotChangeWhatIsKnown(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	a := phoneTestAgent(t, server.URL)
	a.phoneCredentialsSupported.Store(true)
	if !a.syncRelayPhones(context.Background()) {
		t.Fatal("one failed request must not switch phones back to the shared credential")
	}
}

func TestPairingInfoCarriesAPairingWindowCredential(t *testing.T) {
	a := phoneTestAgent(t, "http://relay.invalid")
	a.phoneCredentialsSupported.Store(true)
	a.refreshPairingCode()
	info, err := a.buildPairingInfo()
	if err != nil {
		t.Fatal(err)
	}
	a.pairingMu.Lock()
	expires := a.pairingExpires
	a.pairingMu.Unlock()
	if info.RelayPairID != pairWindowRelayID(expires.Unix()) {
		t.Fatalf("pair id = %q", info.RelayPairID)
	}
	want, _ := derivePhoneRelaySecret(a.credentials.MacSecret, info.RelayPairID)
	if info.RelayPairSecret != want || info.RelayPairSecret == a.credentials.MacSecret {
		t.Fatalf("pair secret = %q", info.RelayPairSecret)
	}
}
