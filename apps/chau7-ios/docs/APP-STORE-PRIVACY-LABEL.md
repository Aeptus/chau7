# App Privacy ("nutrition label") answers — Chau7 Remote

How to answer the **App Privacy** questionnaire in App Store Connect. This maps
to the `PrivacyInfo.xcprivacy` manifests already in the project (app + widget).

## Data collection

> "Do you or your third-party partners collect data from this app?"

**Answer: No** — data is not collected.

Rationale: the app has no accounts, no analytics, and no ad/tracking SDKs.
Terminal content is transmitted **only between the user's own devices**
(end-to-end encrypted) and is not received or stored by the developer. On-device
diagnostics never leave the device unless the user exports them. Under Apple's
definition, transient data sent solely to provide the requested functionality
between the user's own devices is **not "collection."**

If App Review pushes back and insists something be listed, the only defensible
category is **Diagnostics → Crash/Performance Data**, marked **not linked to
identity** and **not used for tracking** — but only if diagnostics ever leave the
device, which today they do not. Prefer "No" unless told otherwise.

## Tracking

> "Does this app track users?"

**Answer: No.** (`NSPrivacyTracking = false` in both manifests; no tracking domains.)

## Required-reason API declarations (already in PrivacyInfo.xcprivacy)

| API category | Reason code | Why |
|---|---|---|
| User Defaults | `CA92.1` | App settings (@AppStorage) read/written by the app itself |
| System Boot Time | `35F9.1` | `ProcessInfo.systemUptime` for on-device diagnostics timing |

Widget target declares no accessed APIs and no tracking.

## Summary to enter
- Data used to track you: **None**
- Data linked to you: **None**
- Data not linked to you: **None** (see rationale above)
