//! The launch splash and the welcome screen (Views module):
//! `Views/SplashView.swift` (`SplashView`, `WelcomeView`,
//! `SplashWindowController`).
//!
//! The windows are in `chau7_next::views`; this module has their texts,
//! sizes, and the rule for when the welcome screen goes away.

/// UserDefaults key in Swift; the app keeps the same name in its defaults.
pub const HAS_SHOWN_WELCOME_KEY: &str = "app.hasShownWelcome";

/// Size of the loading splash, in points.
pub const SPLASH_SIZE: (f32, f32) = (300.0, 280.0);
/// Size of the welcome screen, in points.
pub const WELCOME_SIZE: (f32, f32) = (440.0, 460.0);
/// The splash fades out this long after the launch (the terminal windows
/// have appeared by then).
pub const SPLASH_SECS: f32 = 1.5;
/// Length of the fade-out (`NSAnimationContext` duration).
pub const FADE_SECS: f32 = 0.3;

pub const SPLASH_TITLE: &str = "Chau7";
#[cfg(feature = "production")]
pub const WELCOME_TITLE: &str = "Welcome to Chau7";
#[cfg(not(feature = "production"))]
pub const WELCOME_TITLE: &str = "Welcome to Chau7 Next";
pub const GET_STARTED: &str = "Get Started";

/// One of the three tips of the welcome screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WelcomeTip {
    /// SF Symbol name in Swift.
    pub icon: &'static str,
    pub title: &'static str,
    pub body: &'static str,
}

pub const TIPS: [WelcomeTip; 3] = [
    WelcomeTip {
        icon: "rectangle.stack.fill",
        title: "Tabs are context-full",
        body: "Each tab tracks its AI session, repo, and command history. Name them (double-click) and group by repo (right-click) to manage parallel agents at a glance.",
    },
    WelcomeTip {
        icon: "bell.badge.fill",
        title: "Side panel is your companion",
        body: "The menu bar icon opens a command center with live AI activity, notifications, and quick actions. Keep it handy when running multiple agents.",
    },
    WelcomeTip {
        icon: "keyboard.fill",
        title: "Shortcuts, shortcuts, shortcuts",
        body: "Cmd+T new tab  \u{b7}  Cmd+W close  \u{b7}  Cmd+Shift+] / [ switch\nCmd+Shift+D data explorer  \u{b7}  Cmd+K command palette",
    },
];

/// When the welcome screen closes: after the user pressed Get Started and
/// the app finished loading, whichever comes last
/// (`SplashWindowController.tryDismissWelcome`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WelcomeGate {
    app_ready: bool,
    user_dismissed: bool,
}

impl WelcomeGate {
    /// A welcome screen opened from the Help menu: the app is running.
    pub fn already_running() -> Self {
        Self {
            app_ready: true,
            user_dismissed: false,
        }
    }

    /// "Get Started". Returns whether the screen should close now.
    pub fn get_started(&mut self) -> bool {
        self.user_dismissed = true;
        self.should_close()
    }

    /// The terminal windows are up (`markAppReady`). Returns whether the
    /// screen should close now.
    pub fn mark_ready(&mut self) -> bool {
        self.app_ready = true;
        self.should_close()
    }

    pub fn should_close(&self) -> bool {
        self.app_ready && self.user_dismissed
    }
}

/// What to show at launch: the welcome screen the first time, the loading
/// splash after that.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchScreen {
    Welcome,
    Splash,
}

pub fn launch_screen(has_shown_welcome: bool) -> LaunchScreen {
    if has_shown_welcome {
        LaunchScreen::Splash
    } else {
        LaunchScreen::Welcome
    }
}

/// Opacity of the splash `elapsed` seconds after it appeared: full until
/// [`SPLASH_SECS`], then fading to 0 over [`FADE_SECS`]; `None` when done.
pub fn splash_alpha(elapsed: f32) -> Option<f32> {
    if elapsed < SPLASH_SECS {
        Some(1.0)
    } else if elapsed < SPLASH_SECS + FADE_SECS {
        Some(1.0 - (elapsed - SPLASH_SECS) / FADE_SECS)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn welcome_title_matches_app_channel() {
        let expected = format!("Welcome to {}", crate::data_root::APP_NAME);
        assert_eq!(WELCOME_TITLE, expected.as_str());
    }

    #[test]
    fn three_tips() {
        assert_eq!(TIPS.len(), 3);
        assert_eq!(TIPS[0].title, "Tabs are context-full");
        assert!(TIPS[2].body.contains("Cmd+K command palette"));
        for tip in TIPS {
            assert!(!tip.body.contains('\u{2014}'));
        }
    }

    #[test]
    fn first_launch_shows_welcome_then_splash() {
        assert_eq!(launch_screen(false), LaunchScreen::Welcome);
        assert_eq!(launch_screen(true), LaunchScreen::Splash);
    }

    #[test]
    fn welcome_waits_for_both_the_click_and_the_app() {
        let mut gate = WelcomeGate::default();
        assert!(!gate.get_started());
        assert!(gate.mark_ready());

        let mut gate = WelcomeGate::default();
        assert!(!gate.mark_ready());
        assert!(!gate.should_close());
        assert!(gate.get_started());
    }

    #[test]
    fn welcome_from_the_help_menu_closes_on_the_click() {
        let mut gate = WelcomeGate::already_running();
        assert!(!gate.should_close());
        assert!(gate.get_started());
    }

    #[test]
    fn splash_fades_after_one_and_a_half_seconds() {
        assert_eq!(splash_alpha(0.0), Some(1.0));
        assert_eq!(splash_alpha(1.49), Some(1.0));
        let mid = splash_alpha(1.65).unwrap();
        assert!((mid - 0.5).abs() < 0.01);
        assert_eq!(splash_alpha(1.8), None);
    }
}
