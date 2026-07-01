# Privacy Policy — Chau7 Remote

_Last updated: 2026-07-01_

Chau7 Remote ("the app") is a companion for the Chau7 desktop application. This
policy explains what the app does and does not do with your information. Host
this page at a public URL and enter that URL in App Store Connect.

## The short version

- We do **not** collect, sell, or share your personal data.
- We do **not** use analytics, advertising, or tracking of any kind.
- Your terminal content moves only between **your own devices** (your iPhone/iPad
  and your paired Mac) and is **end-to-end encrypted**.

## What the app handles

**Pairing information.** When you pair with your Mac, the app stores the pairing
details (relay address, device identifier, public keys, pairing code) in the
iOS Keychain on your device. This never leaves your device except as part of the
encrypted connection to your own Mac.

**Terminal session data.** To let you monitor and control your Mac, the app
sends and receives terminal output, command-approval requests, and prompts. This
traffic is **end-to-end encrypted** (ChaCha20-Poly1305 with keys derived via
Curve25519 key agreement) and travels between your phone and your Mac through a
relay. The relay forwards only sealed data it cannot read. We do not store or
have access to this content.

**Push notifications.** If you enable notifications, your Mac (via the relay)
sends alerts to Apple's Push Notification service so you can be notified of
approvals and prompts. Notification content can be redacted in Settings.

**On-device diagnostics (optional).** The app can keep a local diagnostics log
to help you troubleshoot. This log stays on your device and is never uploaded.
Optional keystroke capture is **off by default** and only records anything after
you explicitly consent; it too stays on-device until you choose to export it.

## What we do not do

- No accounts, no sign-in, no email collection.
- No advertising identifiers, no third-party analytics or trackers.
- No data is used to track you across apps or websites.

## Data retention

The app keeps pairing details and any diagnostics locally on your device until
you unpair, clear the log, or delete the app. Removing the app removes this data.

## Children

The app is not directed at children and does not knowingly collect data from
anyone.

## Changes

We may update this policy; material changes will be reflected by the "Last
updated" date above.

## Contact

Questions: privacy@aeptus.com  _(replace with your real contact)_
