# Platform layer

Every macOS-only API Chau7 Next calls goes through this folder (see
"Platform traits" in `AGENTS.md`). Feature code never calls AppKit,
Foundation, Security, ServiceManagement, UserNotifications or libproc
directly. macOS has the real implementation; Linux and Windows get stubs that
log once and return `PlatformError::Unsupported` or a neutral value.

## Which module for which inventory "macOS API" value

| macOS API (inventory column) | Module | Entry points |
|---|---|---|
| Keychain, Keychain (SecItem), Keychain (service name), Keychain (API key, app layer) | `secrets` | `secrets::current()` (`SecretStore`: get, set, delete), `MemorySecretStore` for tests. Services are stored as `com.chau7.next.<service>` |
| UNUserNotificationCenter | `notifications` | `notifications::current()` (`Notifier`): request and refresh permission, post, remove; clicks and permission answers via `drain_events()` |
| NSAppleScript (`display notification` fallback), UNNotificationSettings (Focus, alert style) | `notifications` | `post_applescript(title, body)`; `NotificationEvent::Delivery` and `PostFailed` from `drain_events()` |
| CGSessionCopyCurrentDictionary | `system` | `system::screen_locked()` |
| os_log (unified log) | `oslog` | `oslog::log(category, level, message)`; C shim `oslog_shim.c` built by `build.rs` |
| NSSound, NSBeep | `sound` | `sound::beep()`, `play_named("Pop", volume)`, `play_file(path, volume)`, `sound_source(setting)` |
| NSSpeechSynthesizer | `sound` | `sound::speak(text, voice, rate)`, `stop_speaking()` |
| NSApplication.requestUserAttention | `attention` | `request_attention(critical)`, `cancel_attention(..)` |
| Dock badge | `attention` | `set_dock_badge(Some("3"))` |
| NSApplication.ActivationPolicy (menu bar only mode) | `attention` | `set_dock_icon_visible(false)` |
| NSWorkspace (open with a given app, default app) | `workspace` | `open_url_with(url, bundle_id)`, `open_file_with(..)`, `app_path(bundle_id)`, `default_app_for_url(..)`, `default_app_for_file(..)` |
| NSWorkspace (file icons) | `workspace` | `file_icon_png(path, size)` |
| NSWorkspace accessibilityDisplayShouldIncreaseContrast, NSWorkspace accessibility (Reduce Motion) | `system` | `increase_contrast()`, `reduce_motion()` |
| NSPasteboard (copies made in other apps) | `pasteboard` | `change_count()`, `ChangeWatcher::poll()` |
| LaunchAgent, launchctl (Launch at Login) | `login_item` | `login_item::current()` (`LoginItem`: status, set_enabled, open_system_settings), SMAppService (macOS 13+) |
| NSProcessInfo.beginActivity (opt out of App Nap) | `power` | `begin_latency_critical(reason)`, `end_latency_critical()` |
| NSUbiquitousKeyValueStore (iCloud settings sync) | `icloud` | `icloud::current()` (`CloudStore`: is_available, string, set_string, synchronize) |
| NSStatusItem | `status_item` | `status_item::create()` (`StatusItem`: SF Symbol or PNG icon, title, tooltip, menu, visibility), clicks and menu choices via `drain_events()` |
| libproc, mach task_info | `process` | `process_cwd`, `child_pids`, `child_process_count`, `process_tree`, `process_usage`, `tree_usage`, `own_resident_bytes` |
| Host.current().localizedName, IOPlatformUUID via `ioreg` | `system` | `host_name()`, `hardware_uuid()` |
| login keychain cert trust | `cert_trust` | `pem_to_der`, `is_trusted`, `trust`, `remove_trust` |
| Password AutoFill (NSTextInputClient), NSTextInputClient (AutoFill) | `autofill` | `autofill::is_available()`, `autofill::request()` (the password arrives through the GPUI input handler) |
| NSTextInputClient (discard marked text on focus loss) | `input_method` | `input_method::discard_marked_text()` |
| NSServices (selection to Services, text back) | `services` | `services::install(window)`, `set_selection(..)`, `drain_returned_text()` |
| NSDraggingDestination (raw PNG/TIFF dropped, no file) | `drop_image` | `drop_image::install(window)`, `window_key(window)`, `drain_events()` |
| NSPrintOperation | `print` | `print::print_text(text, font, size)` (print panel for the terminal text) |
| Unix sockets (MCP server) | `local_socket` | `Listener::bind(path)` (stale file removed, mode 0600), `accept()`, `remove(path)`; real on every Unix, stub on Windows |
| UserDefaults (hidden preferences set with `defaults write`) | `defaults` | `app_bool`, `app_string`, `app_int`, `set_app_bool`, `disable_press_and_hold` |
| NSAppearance (app theme), NSWindow alphaValue, NSWindow level | `window_style` | `set_app_theme(Some(dark))`, `set_window_alpha(window, a)`, `set_window_floating(window, on)` |

OS callbacks are queued (`EventQueue`) and drained by the app on its main
thread. AppKit calls (`attention`, `status_item`, `sound`) must run on the
main thread and return `PlatformError::NotMainThread` otherwise.
Notifications and launch at login need the app bundle
(`scripts/bundle-macos.sh`) and return `PlatformError::NotBundled` under
`cargo run`.

## Use GPUI instead

| macOS API | GPUI |
|---|---|
| NSPasteboard read and write (copy, paste, OSC 52) | `cx.read_from_clipboard()`, `cx.write_to_clipboard(..)` |
| NSWorkspace open URL in the default browser | `cx.open_url(url)` |
| NSWorkspace open a file with its default app | `cx.open_with_system(path)` |
| NSWorkspace reveal in Finder | `cx.reveal_path(path)` |
| NSOpenPanel, NSSavePanel | `cx.prompt_for_paths(..)`, `cx.prompt_for_new_path(..)` |
| NSAlert | `window.prompt(..)` |
| NSMenu (app menu, Window menu, Dock menu) | `cx.set_menus(..)`, `cx.set_dock_menu(..)` |
| NSApplication activate, hide, hide others | `cx.activate(true)`, `cx.hide()`, `cx.hide_other_apps()`, `window.activate_window()` |
| NSApplicationDelegate reopen (Dock click) | `cx.on_reopen(..)` |
| CFBundleURLTypes, open URLs | `cx.on_open_urls(..)`, `cx.register_url_scheme(..)` |
| NSAppearance | `cx.window_appearance()`, `window.appearance()` |
| NSWindow level, fullscreen | `WindowKind::PopUp`, `window.toggle_fullscreen()` |

## Adding to it

One module per concern, a trait (or plain functions when there is no
state), `#[cfg(target_os = "macos")] mod imp` with the real code and a
`#[cfg(not(target_os = "macos"))] mod imp` stub. Enable only the `objc2-*`
crate features the code uses (`crates/chau7_next/Cargo.toml`). Pure logic
(parsing, naming) goes outside `imp` with unit tests, so it runs on Linux CI.
