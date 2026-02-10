# Profiles

Automatic profile switching, SSH connection management, and SSH config synchronization.

## Files

| File | Purpose |
|------|---------|
| `ProfileAutoSwitcher.swift` | Evaluates context rules (directory, SSH host, env) to auto-switch settings profiles |
| `SSHConnectionManager.swift` | Manages saved SSH connections with host, port, identity file, and jump host |
| `SharedSSHProfiles.swift` | Syncs SSH profiles between ~/.ssh/config and Chau7's SSH connection manager |

## Key Types

- `ProfileAutoSwitcher` — ObservableObject evaluating profile switch rules against terminal context
- `SSHConnectionManager` — singleton managing CRUD for SSH connection profiles
- `SharedSSHProfileManager` — watches ~/.ssh/config and auto-imports new host entries

## Dependencies

- **Uses:** Logging, Settings, Monitoring (FileMonitor)
- **Used by:** Overlay, Settings/Views
