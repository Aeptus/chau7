package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/chau7/chau7-remote/internal/viewer"
)

// runViewer is `chau7-remote viewer [flags] <code>`: a read-only viewer for
// a terminal shared by Chau7 Next (debug tool, see
// docs/remote-control/VIEWER-PROTOCOL.md). It needs no relay credential.
func runViewer(args []string) int {
	flags := flag.NewFlagSet("viewer", flag.ContinueOnError)
	relayURL := flags.String("relay", os.Getenv("CHAU7_RELAY_URL"), "relay URL (default $CHAU7_RELAY_URL)")
	name := flags.String("name", "chau7-remote viewer", "name shown to the owner")
	id := flags.String("id", "", "viewer id (random by default; reuse one to be a known viewer)")
	flags.Usage = func() {
		fmt.Fprintln(flags.Output(), "usage: chau7-remote viewer [-relay URL] [-name NAME] [-id ID] <share code>")
		flags.PrintDefaults()
	}
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 1 || *relayURL == "" {
		flags.Usage()
		return 2
	}
	viewerID := *id
	if viewerID == "" {
		b := make([]byte, 8)
		_, _ = rand.Read(b)
		viewerID = "cli-" + hex.EncodeToString(b)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err := viewer.Run(ctx, viewer.Config{
		RelayURL: *relayURL,
		Code:     flags.Arg(0),
		ViewerID: viewerID,
		Name:     *name,
		Output:   os.Stdout,
		Log:      os.Stderr,
	})
	var denied viewer.ErrDenied
	switch {
	case err == nil:
		return 0
	case errors.Is(err, viewer.ErrEnded):
		fmt.Fprintln(os.Stderr, "viewer: the owner ended the viewing")
		return 0
	case errors.As(err, &denied):
		fmt.Fprintf(os.Stderr, "viewer: %v\n", err)
		return 1
	default:
		fmt.Fprintf(os.Stderr, "viewer: %v\n", err)
		return 1
	}
}
