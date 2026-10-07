package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/chau7/chau7-remote/internal/agent"
)

// Management commands accept secret files, never secret command-line values.
// Only public identity metadata and completion notices are written to output.
func runManagementCommand(args []string, output io.Writer) error {
	if len(args) == 0 {
		return errors.New("expected identity, keyring-init, keyring-rotate, credentials-derive, or provision")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", agent.DefaultRemoteStatePath(), "existing identity state file")
	keyringPath := flags.String("keyring", "", "owner-only operator root keyring file")
	outputPath := flags.String("output", "", "new owner-only output file")
	bundlePath := flags.String("bundle", "", "owner-only derived credentials file")
	deviceID := flags.String("device-id", "", "public remote device ID")
	keyID := flags.String("key-id", "", "public initial key ID")
	overlap := flags.Duration("overlap", time.Hour, "rotation grace, at most 24 hours")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	now := time.Now()
	switch args[0] {
	case "identity":
		info, err := agent.PrepareRelayIdentity(*state)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(info)
	case "keyring-init":
		keyring, err := agent.NewRelayKeyring(*keyID)
		if err != nil {
			return err
		}
		if err := agent.WritePrivateRelayJSON(*outputPath, keyring, false); err != nil {
			return err
		}
	case "keyring-rotate":
		keyring, err := agent.LoadRelayKeyring(*keyringPath, now)
		if err != nil {
			return err
		}
		next, err := agent.RotateRelayKeyring(keyring, *overlap, now)
		if err != nil {
			return err
		}
		if err := agent.WritePrivateRelayJSON(*outputPath, next, false); err != nil {
			return err
		}
	case "credentials-derive":
		keyring, err := agent.LoadRelayKeyring(*keyringPath, now)
		if err != nil {
			return err
		}
		credentials, err := agent.DeriveRelayCredentials(keyring, *deviceID, now)
		if err != nil {
			return err
		}
		if err := agent.WritePrivateRelayJSON(*outputPath, credentials, false); err != nil {
			return err
		}
	case "provision":
		if err := agent.ProvisionRelayCredentials(*bundlePath, *state); err != nil {
			return err
		}
	default:
		return errors.New("unknown command; use identity, keyring-init, keyring-rotate, credentials-derive, or provision")
	}
	_, err := fmt.Fprintln(output, "Relay configuration saved to an owner-only file.")
	return err
}
