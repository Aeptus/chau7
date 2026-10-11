//! System notifications (UNUserNotificationCenter): permission, posting
//! banners, showing them while Chau7 Next is in front, and clicks.
//!
//! Results that the OS reports later (permission answer, a click on a
//! banner) arrive as [`NotificationEvent`]s: drain them with
//! [`Notifier::drain_events`] on the main thread.
//!
//! UserNotifications only works from the app bundle (`Chau7 Next.app`, see
//! `scripts/bundle-macos.sh`). Unbundled (`cargo run`) every call returns
//! [`PlatformError::NotBundled`](super::PlatformError::NotBundled), since the
//! framework aborts the process otherwise.

use super::{EventQueue, Result};

/// One banner to show.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Notification {
    /// Request identifier, returned in [`NotificationEvent::Clicked`]. Posting
    /// again with the same id replaces the banner.
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub body: String,
    /// Play the default notification sound.
    pub sound: bool,
    /// Groups banners in Notification Center (for example per tab).
    pub thread_id: Option<String>,
}

/// Notification permission, as System Settings shows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthorizationStatus {
    NotDetermined,
    Denied,
    Authorized,
    /// Delivered quietly to Notification Center only.
    Provisional,
    /// Not available on this OS or outside the app bundle.
    Unavailable,
}

/// Something the OS reported after the fact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotificationEvent {
    /// Answer to [`Notifier::request_authorization`] or
    /// [`Notifier::refresh_authorization`].
    Authorization(AuthorizationStatus),
    /// The user clicked the banner (or one of its actions).
    Clicked { id: String, action: String },
    /// The user dismissed the banner.
    Dismissed { id: String },
    /// Delivery settings read with the permission: whether Notification
    /// Center is on for the app (off counts as Focus / Do Not Disturb in
    /// Swift) and whether banners or alerts are allowed.
    Delivery {
        notification_center: bool,
        alerts: bool,
    },
    /// The system refused a banner [`Notifier::post`] queued; the caller
    /// shows it another way (Swift falls back to AppleScript).
    PostFailed {
        id: String,
        title: String,
        body: String,
        message: String,
    },
}

/// The `display notification` AppleScript for a banner (Swift
/// `sendAppleScriptNotification`): quotes and backslashes escaped, line
/// breaks flattened.
pub fn applescript_source(title: &str, body: &str) -> String {
    let escape = |s: &str| {
        s.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', " ")
            .replace('\r', "")
    };
    format!(
        "display notification \"{}\" with title \"{}\" sound name \"default\"",
        escape(body),
        escape(title)
    )
}

/// Show a banner with AppleScript (`osascript`), the fallback when the app
/// may not post native notifications (no permission, not bundled, or after
/// an error). Runs in the background.
pub fn post_applescript(title: &str, body: &str) -> Result<()> {
    imp::post_applescript(applescript_source(title, body), title.to_string())
}

/// System Settings > Notifications, for "System Settings" buttons.
pub const SYSTEM_SETTINGS_URL: &str =
    "x-apple.systempreferences:com.apple.Notifications-Settings.extension";

/// Action identifier UserNotifications sends for a plain click.
pub const DEFAULT_ACTION: &str = "com.apple.UNNotificationDefaultActionIdentifier";
/// Action identifier UserNotifications sends for a dismissal.
pub const DISMISS_ACTION: &str = "com.apple.UNNotificationDismissActionIdentifier";

/// Event for a notification response.
pub fn response_event(id: String, action: &str) -> NotificationEvent {
    if action == DISMISS_ACTION {
        NotificationEvent::Dismissed { id }
    } else {
        NotificationEvent::Clicked {
            id,
            action: action.to_string(),
        }
    }
}

pub trait Notifier: Send + Sync {
    /// Asks for alert, sound and badge permission (a system prompt the first
    /// time). The answer arrives as [`NotificationEvent::Authorization`].
    fn request_authorization(&self) -> Result<()>;
    /// Reads the current permission; arrives as
    /// [`NotificationEvent::Authorization`].
    fn refresh_authorization(&self) -> Result<()>;
    /// Shows a banner. Banners are also shown while Chau7 Next is in front.
    fn post(&self, notification: &Notification) -> Result<()>;
    /// Removes delivered banners from Notification Center.
    fn remove_delivered(&self, ids: &[String]) -> Result<()>;
    /// Every event since the last call, oldest first.
    fn drain_events(&self) -> Vec<NotificationEvent>;
}

/// Events pushed by the OS callbacks.
static EVENTS: EventQueue<NotificationEvent> = EventQueue::new();

/// UserNotifications on macOS; a stub elsewhere.
pub fn current() -> &'static dyn Notifier {
    static NOTIFIER: imp::Center = imp::Center;
    &NOTIFIER
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ptr::NonNull;
    use std::sync::Once;

    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::{Bool, NSObject, ProtocolObject};
    use objc2::{AnyThread, define_class, msg_send};
    use objc2_foundation::{NSArray, NSError, NSObjectProtocol, NSString};
    use objc2_user_notifications::{
        UNAlertStyle, UNAuthorizationOptions, UNAuthorizationStatus, UNMutableNotificationContent,
        UNNotification, UNNotificationPresentationOptions, UNNotificationRequest,
        UNNotificationResponse, UNNotificationSetting, UNNotificationSettings, UNNotificationSound,
        UNUserNotificationCenter, UNUserNotificationCenterDelegate,
    };

    use super::{AuthorizationStatus, EVENTS, Notification, NotificationEvent, response_event};
    use crate::platform::{PlatformError, Result, running_from_app_bundle};

    define_class!(
        // SAFETY:
        // - NSObject has no subclassing requirements.
        // - `Delegate` does not implement `Drop`.
        #[unsafe(super(NSObject))]
        struct Delegate;

        // SAFETY: NSObjectProtocol has no safety requirements.
        unsafe impl NSObjectProtocol for Delegate {}

        // SAFETY: the method signatures match the protocol.
        unsafe impl UNUserNotificationCenterDelegate for Delegate {
            #[unsafe(method(userNotificationCenter:willPresentNotification:withCompletionHandler:))]
            fn will_present(
                &self,
                _center: &UNUserNotificationCenter,
                _notification: &UNNotification,
                completion_handler: &block2::DynBlock<dyn Fn(UNNotificationPresentationOptions)>,
            ) {
                // Show banners while the app is in front too (NOT-004); the
                // system still applies the user's notification settings.
                completion_handler.call((UNNotificationPresentationOptions::Banner
                    | UNNotificationPresentationOptions::List
                    | UNNotificationPresentationOptions::Sound
                    | UNNotificationPresentationOptions::Badge,));
            }

            #[unsafe(method(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:))]
            fn did_receive(
                &self,
                _center: &UNUserNotificationCenter,
                response: &UNNotificationResponse,
                completion_handler: &block2::DynBlock<dyn Fn()>,
            ) {
                let id = response.notification().request().identifier().to_string();
                let action = response.actionIdentifier().to_string();
                EVENTS.push(response_event(id, &action));
                completion_handler.call(());
            }
        }
    );

    impl Delegate {
        fn new() -> Retained<Self> {
            let this = Self::alloc().set_ivars(());
            // SAFETY: NSObject's `init` has this signature.
            unsafe { msg_send![super(this), init] }
        }
    }

    /// The notification center, with our delegate installed. Fails outside
    /// the app bundle, where `currentNotificationCenter` would abort.
    fn center() -> Result<Retained<UNUserNotificationCenter>> {
        if !running_from_app_bundle() {
            return Err(PlatformError::NotBundled);
        }
        let center = UNUserNotificationCenter::currentNotificationCenter();
        static INSTALL: Once = Once::new();
        INSTALL.call_once(|| {
            let delegate = Delegate::new();
            center.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
            // The center keeps a weak reference: keep the delegate alive for
            // the whole process.
            std::mem::forget(delegate);
        });
        Ok(center)
    }

    fn status(status: UNAuthorizationStatus) -> AuthorizationStatus {
        match status {
            UNAuthorizationStatus::Denied => AuthorizationStatus::Denied,
            UNAuthorizationStatus::Authorized => AuthorizationStatus::Authorized,
            UNAuthorizationStatus::Provisional | UNAuthorizationStatus::Ephemeral => {
                AuthorizationStatus::Provisional
            }
            _ => AuthorizationStatus::NotDetermined,
        }
    }

    fn push_current_status(center: &UNUserNotificationCenter) {
        let block = RcBlock::new(|settings: NonNull<UNNotificationSettings>| {
            // SAFETY: the framework passes a valid settings object for the
            // duration of the call.
            let settings = unsafe { settings.as_ref() };
            EVENTS.push(NotificationEvent::Authorization(status(
                settings.authorizationStatus(),
            )));
            EVENTS.push(NotificationEvent::Delivery {
                notification_center: settings.notificationCenterSetting()
                    != UNNotificationSetting::Disabled,
                alerts: settings.alertSetting() != UNNotificationSetting::Disabled
                    && settings.alertStyle() != UNAlertStyle::None,
            });
        });
        center.getNotificationSettingsWithCompletionHandler(&block);
    }

    pub fn post_applescript(source: String, title: String) -> Result<()> {
        std::thread::Builder::new()
            .name("applescript-notification".into())
            .spawn(move || {
                match std::process::Command::new("/usr/bin/osascript")
                    .arg("-e")
                    .arg(&source)
                    .output()
                {
                    Ok(out) if out.status.success() => {
                        log::info!("AppleScript notification sent: {title}")
                    }
                    Ok(out) => log::error!(
                        "AppleScript notification error: {}",
                        String::from_utf8_lossy(&out.stderr).trim()
                    ),
                    Err(err) => log::error!("AppleScript notification error: {err}"),
                }
            })
            .map(|_| ())
            .map_err(|e| PlatformError::Failed(e.to_string()))
    }

    pub struct Center;

    impl super::Notifier for Center {
        fn request_authorization(&self) -> Result<()> {
            let center = center()?;
            let block = RcBlock::new(|granted: Bool, error: *mut NSError| {
                if !error.is_null() {
                    // SAFETY: non-null, valid for the duration of the call.
                    let message = unsafe { &*error }.localizedDescription().to_string();
                    log::warn!("notification permission request failed: {message}");
                }
                log::info!("notification permission granted: {}", granted.as_bool());
                push_current_status(&UNUserNotificationCenter::currentNotificationCenter());
            });
            center.requestAuthorizationWithOptions_completionHandler(
                UNAuthorizationOptions::Alert
                    | UNAuthorizationOptions::Sound
                    | UNAuthorizationOptions::Badge,
                &block,
            );
            Ok(())
        }

        fn refresh_authorization(&self) -> Result<()> {
            let center = center()?;
            push_current_status(&center);
            Ok(())
        }

        fn post(&self, notification: &Notification) -> Result<()> {
            let center = center()?;
            let content = UNMutableNotificationContent::new();
            content.setTitle(&NSString::from_str(&notification.title));
            if let Some(subtitle) = &notification.subtitle {
                content.setSubtitle(&NSString::from_str(subtitle));
            }
            content.setBody(&NSString::from_str(&notification.body));
            if notification.sound {
                let sound = UNNotificationSound::defaultSound();
                content.setSound(Some(&*sound));
            }
            if let Some(thread) = &notification.thread_id {
                content.setThreadIdentifier(&NSString::from_str(thread));
            }
            let request = UNNotificationRequest::requestWithIdentifier_content_trigger(
                &NSString::from_str(&notification.id),
                &content,
                None,
            );
            let id = notification.id.clone();
            let (title, body) = (notification.title.clone(), notification.body.clone());
            let done = RcBlock::new(move |error: *mut NSError| {
                if !error.is_null() {
                    // SAFETY: non-null, valid for the duration of the call.
                    let message = unsafe { &*error }.localizedDescription().to_string();
                    log::warn!("notification {id} not shown: {message}");
                    EVENTS.push(NotificationEvent::PostFailed {
                        id: id.clone(),
                        title: title.clone(),
                        body: body.clone(),
                        message,
                    });
                }
            });
            center.addNotificationRequest_withCompletionHandler(&request, Some(&*done));
            Ok(())
        }

        fn remove_delivered(&self, ids: &[String]) -> Result<()> {
            let center = center()?;
            let ids: Vec<Retained<NSString>> =
                ids.iter().map(|id| NSString::from_str(id)).collect();
            center.removeDeliveredNotificationsWithIdentifiers(&NSArray::from_retained_slice(&ids));
            Ok(())
        }

        fn drain_events(&self) -> Vec<NotificationEvent> {
            EVENTS.drain()
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::{AuthorizationStatus, EVENTS, Notification, NotificationEvent};
    use crate::platform::{Result, unsupported};

    pub fn post_applescript(_source: String, _title: String) -> Result<()> {
        unsupported("AppleScript notifications")
    }

    pub struct Center;

    impl super::Notifier for Center {
        fn request_authorization(&self) -> Result<()> {
            EVENTS.push(NotificationEvent::Authorization(
                AuthorizationStatus::Unavailable,
            ));
            unsupported("system notifications")
        }

        fn refresh_authorization(&self) -> Result<()> {
            EVENTS.push(NotificationEvent::Authorization(
                AuthorizationStatus::Unavailable,
            ));
            unsupported("system notifications")
        }

        fn post(&self, _notification: &Notification) -> Result<()> {
            unsupported("system notifications")
        }

        fn remove_delivered(&self, _ids: &[String]) -> Result<()> {
            unsupported("system notifications")
        }

        fn drain_events(&self) -> Vec<NotificationEvent> {
            EVENTS.drain()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn responses_map_to_events() {
        assert_eq!(
            response_event("n1".into(), DEFAULT_ACTION),
            NotificationEvent::Clicked {
                id: "n1".into(),
                action: DEFAULT_ACTION.into()
            }
        );
        assert_eq!(
            response_event("n1".into(), DISMISS_ACTION),
            NotificationEvent::Dismissed { id: "n1".into() }
        );
        assert_eq!(
            response_event("n2".into(), "open-tab"),
            NotificationEvent::Clicked {
                id: "n2".into(),
                action: "open-tab".into()
            }
        );
    }

    #[test]
    fn applescript_escapes_quotes_and_lines() {
        assert_eq!(
            applescript_source("A \"b\"", "x\\y\nz\r"),
            "display notification \"x\\\\y z\" with title \"A \\\"b\\\"\" sound name \"default\""
        );
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stub_reports_unavailable() {
        let notifier = current();
        assert!(notifier.post(&Notification::default()).is_err());
        assert!(notifier.refresh_authorization().is_err());
        assert!(
            notifier
                .drain_events()
                .contains(&NotificationEvent::Authorization(
                    AuthorizationStatus::Unavailable
                ))
        );
    }
}
