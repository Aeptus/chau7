# Chau7 iOS App

This directory hosts the native iOS companion app for Chau7.

## Scope (v1)
- Live terminal output streaming (view-only by default).
- Simple input with Send button (hold-to-send default).
- Tab switcher for active macOS tabs.
- Pairing via pasted JSON payload (no camera required).
- Live Activity / Dynamic Island status for the most relevant remote AI task.

## Specs
See:

- `docs/REMOTE-UX.md` for product and Live Activity behavior
- `../../services/chau7-remote/docs/PROTOCOL.md` for the transport and payload contract

## Build
Open `apps/chau7-ios/Chau7RemoteApp/Chau7RemoteApp.xcodeproj` in Xcode.

The iOS target links the local `Chau7Core` Swift package from `apps/chau7-macos`, so keep the repository layout intact when opening the project.

The Xcode project now includes two targets:
- `Chau7RemoteApp` for the companion app UI and websocket client.
- `Chau7RemoteWidget` for Lock Screen and Dynamic Island rendering via ActivityKit.

To test on an iPhone:
- Connect your device and trust the computer if prompted.
- Select the `Chau7RemoteApp` scheme and your iPhone as the run destination.
- Use automatic signing with your Apple team selected in Xcode if code signing needs to be configured.

## Live Activity Behavior
- macOS is the source of truth for AI task state and sends a distilled activity payload over the existing remote-control websocket.
- iOS renders one Live Activity for the highest-priority remote task instead of mirroring every tab.
- Action URLs from the Live Activity route back into the app and reuse the existing remote control paths for open, tab switch, and approvals.
