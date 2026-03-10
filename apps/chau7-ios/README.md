# Chau7 iOS App

This directory hosts the native iOS companion app for Chau7.

## Scope (v1)
- Live terminal output streaming (view-only by default).
- Simple input with Send button (hold-to-send default).
- Tab switcher for active macOS tabs.
- Pairing via pasted JSON payload (no camera required).

## Specs
See `docs/remote-control/SPEC-Remote-Control.md` for protocol and UX details.

## Build
Open `apps/chau7-ios/Chau7RemoteApp/Chau7RemoteApp.xcodeproj` in Xcode.

The iOS target links the local `Chau7Core` Swift package from `apps/chau7-macos`, so keep the repository layout intact when opening the project.

To test on an iPhone:
- Connect your device and trust the computer if prompted.
- Select the `Chau7RemoteApp` scheme and your iPhone as the run destination.
- Use automatic signing with your Apple team selected in Xcode if code signing needs to be configured.
