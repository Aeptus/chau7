# Relay credentials

Source readiness is separate from deployment. These commands describe an
operator workflow; implementing this change does not read, replace or deploy
production secrets. Use a built `chau7-remote` helper (or `go run
./cmd/chau7-remote` from `services/chau7-remote`) for management commands.

## Initial provisioning

1. On the Mac, run `chau7-remote identity --state <state.json>`. It prints only
   public `device_id` and `mac_public_key`. A missing state is created explicitly,
   with a wrapped private key, via exclusive publication; an existing identity
   is validated and preserved. Do not replace state to recover an unwrap failure.
2. On the trusted operator machine, run `chau7-remote keyring-init --output
   <root-keyring.json>`. This generates 32 random root bytes and a random public
   key ID. Output is exclusively created, mode 0600. No root is printed.
3. Use a separately authorized deployment to configure the JSON file as the
   `RELAY_AUTH_KEYS` secret on both relay and issue Workers. Do not distribute
   this operator root file to Macs or phones.
4. On the operator machine, run `chau7-remote credentials-derive --keyring
   <root-keyring.json> --device-id <public-device-id> --output <bundle.json>`.
   The bundle contains only this device's distinct derived Mac/iOS role keys,
   its device ID and public key ID. Deliver it to that Mac through a trusted
   secure channel, preserving owner-only permissions.
5. On the Mac, run `chau7-remote provision --bundle <bundle.json> --state
   <state.json>`. It validates identity, device scope, key strength, ownership,
   mode 0600/0400 and no symlink; it atomically writes mode 0600
   `credentials.json` next to the state, without rewriting identity or trust.
6. Enable Remote and scan its QR in Chau7 iOS. The QR contains only the derived
   iOS credential. Settings text and clipboard device details omit credentials.
   The iOS pairing store retains the QR credential in Keychain. Missing or
   invalid credentials produce a settings/startup error; no unauthenticated
   connection or old global-secret fallback is attempted.

Management commands run before the parent-process watcher and never accept
secret values as command-line arguments. Root/credential material is written
to owner-only files, not stdout or logs. Treat the secure QR and credential
bundle as admission credentials for that device namespace. Individual phone
trust still requires the existing X25519 handshake and Mac confirmation.

## Rotation

On the operator machine, run `chau7-remote keyring-rotate --keyring
<current.json> --output <next.json> --overlap 1h`. The fresh root is current;
the former current root becomes the sole previous key with explicit Unix
`grace_started_at`/`accept_until`. Overlap must be whole seconds from one
second through 24 hours. Output never overwrites an existing keyring file.

Deploy that keyring consistently to both Workers, derive replacement bundles
using it, provision them on Macs and scan replacement QR codes on phones
before the grace ends. State, Mac private key and paired-device identities
remain unchanged. The helper reloads the credential file for every new dial,
HTTP authorization and pairing payload; a malformed replacement blocks those
operations instead of using cached credentials. The paired phone reconnects
using its new key ID/credential without replacing its long-lived X25519 key.
After grace, previous-key admission and forwarding fail. Remove the previous
root in a later authorized deployment once migration is complete.

## Revocation and migration

Set `RELAY_REVOKED_DEVICES` consistently on both Workers to a JSON array of
revoked Mac namespace IDs (maximum 256). These IDs fail current/previous-key
admission. Forwarding rechecks admitted socket metadata against current policy;
quiet sockets are checked on their next send/receive, not forcibly awakened.
Use Mac paired-device controls to revoke one phone's cryptographic trust.

Old global `RELAY_SECRET`, state `relay_secret` and v2 bearer tokens do not
satisfy the v3 policy. Old pairing JSON can decode for migration, but requires
a fresh provisioned QR before connecting. Coordinate server/client rollout
explicitly; this source change alone does not claim zero-downtime migration
or verify production posture. Explicit local open mode requires both
`ENVIRONMENT=development` and `RELAY_ALLOW_UNAUTHENTICATED=true`, with no
keyring provided; malformed configured keys always fail closed, and issue
intake has no open mode.
