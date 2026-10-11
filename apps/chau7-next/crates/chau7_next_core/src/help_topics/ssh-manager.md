# SSH Connection Manager

Manage your SSH connections in one place. Save hosts, configure options, and connect with a single click.

## Opening SSH Manager

- Press **⇧⌘O**
- Or use Command Palette: **⇧⌘P** → "SSH Connections"

## Adding a Connection

1. Click the **+** button
2. Enter the connection details:
   - **Name**: A friendly name for the connection
   - **Host**: The hostname or IP address
   - **Port**: SSH port (default: 22)
   - **User**: Your username
   - **Identity File**: Path to your SSH key (optional)
   - **Jump Host**: Bastion/proxy host (optional)

## Importing from ~/.ssh/config

Click the **...** menu and select "Import from ~/.ssh/config" to automatically import your existing SSH configurations.

## Connecting

Double-click a connection or select it and click "Connect" to open a new tab with the SSH session.
