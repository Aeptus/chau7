# App Review notes — Chau7 Remote

Paste into the **App Review Information → Notes** field in App Store Connect.
The single biggest rejection risk is that the app needs a paired Mac to show its
main functionality — address that head-on with a demo path.

---

## Notes for the reviewer (paste this)

```
Chau7 Remote is a companion app for the Chau7 macOS desktop application. It lets
a developer monitor and approve actions taken by AI coding agents (Claude,
Codex) and shell commands running in Chau7 on their own Mac.

IMPORTANT — the app requires a paired Mac to show live content:
Without a paired Mac the app shows its onboarding, pairing screen, and settings,
but no terminal sessions. To review full functionality, please use ONE of:

  1) Demo video: <link to a screen recording showing pairing + approving a
     command + a lock-screen notification>.  ← recommended, add before submitting
  2) Live demo build: we can provide a staged Mac + relay on request; contact
     <email> and we will pair a device to your test account within 24h.

CONNECTIVITY:
- The app connects to an encrypted relay over wss:// (TLS). No local network
  access, no arbitrary HTTP.
- All phone<->Mac traffic is end-to-end encrypted; the relay cannot read it.

PERMISSIONS:
- Camera: used ONLY to scan the pairing QR code shown by Chau7 on the Mac.
- Notifications: approval/prompt alerts (time-sensitive). Optional.

PRIVACY / DIAGNOSTICS:
- Optional keystroke capture is OFF by default and only records after the user
  explicitly accepts an in-app consent prompt. It stays on-device.
- No accounts, no analytics, no tracking.

ENCRYPTION: standard cryptography only (Apple CryptoKit — ChaCha20-Poly1305,
Curve25519). Declared as exempt (ITSAppUsesNonExemptEncryption = NO).
```

## Pre-submission checklist for this field
- [ ] Record and link the **demo video** (pairing → approve a command → lock-screen alert).
- [ ] Provide a monitored **contact email** for the staged-demo option.
- [ ] Confirm the reviewer link/relay is reachable at submission time.
