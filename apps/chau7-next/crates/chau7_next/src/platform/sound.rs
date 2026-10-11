//! Sounds and speech: the system beep (bell, NSBeep), named system sounds
//! and sound files (NSSound: bell "subtle" Pop, "Play sound" action) and
//! spoken text (NSSpeechSynthesizer: "Voice announce" action).
//!
//! Call these on the main thread: AppKit keeps playing sounds and speech
//! objects alive here only while the main thread owns them.

use std::path::Path;

use super::Result;

/// Folder of the macOS system sounds (`Pop.aiff`, `Glass.aiff`, ...).
pub const SYSTEM_SOUNDS_DIR: &str = "/System/Library/Sounds";

/// How a "play sound" setting value is played: a named system sound
/// (`Pop`, `Glass`) or a file path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SoundSource {
    Named(String),
    File(String),
}

/// Reads a setting value: anything with a `/` is a file path (expand `~`
/// before playing it), anything else a system sound name. `Pop.aiff` is the
/// system sound `Pop`.
pub fn sound_source(value: &str) -> Option<SoundSource> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    if value.contains('/') {
        return Some(SoundSource::File(value.to_string()));
    }
    let name = value
        .strip_suffix(".aiff")
        .or_else(|| value.strip_suffix(".aif"))
        .unwrap_or(value);
    Some(SoundSource::Named(name.to_string()))
}

/// Volume clamped to the 0..=1 range NSSound expects.
pub fn clamp_volume(volume: f32) -> f32 {
    if volume.is_nan() {
        1.0
    } else {
        volume.clamp(0.0, 1.0)
    }
}

/// The system alert sound. Does nothing (logged once) on other OSes.
pub fn beep() {
    imp::beep()
}

/// Plays a system sound by name (`Pop`, `Glass`, `Submarine`), at `volume`
/// from 0 to 1.
pub fn play_named(name: &str, volume: f32) -> Result<()> {
    imp::play_named(name, clamp_volume(volume))
}

/// Plays a sound file (aiff, wav, mp3, m4a), at `volume` from 0 to 1.
pub fn play_file(path: &Path, volume: f32) -> Result<()> {
    imp::play_file(path, clamp_volume(volume))
}

/// Speaks `text`. `voice` is a voice identifier such as
/// `com.apple.speech.synthesis.voice.Alex` (system voice when `None`);
/// `rate` is in words per minute (system rate when `None`). Interrupts what
/// was being said.
pub fn speak(text: &str, voice: Option<&str>, rate: Option<f32>) -> Result<()> {
    imp::speak(text, voice, rate)
}

/// Stops speaking.
pub fn stop_speaking() {
    imp::stop_speaking()
}

#[cfg(target_os = "macos")]
#[allow(deprecated)] // NSSpeechSynthesizer: AVSpeechSynthesizer is not in AppKit.
mod imp {
    use std::cell::RefCell;
    use std::path::Path;

    use objc2::AnyThread;
    use objc2::rc::Retained;
    use objc2_app_kit::{NSBeep, NSSound, NSSpeechSynthesizer};
    use objc2_foundation::NSString;

    use crate::platform::{PlatformError, Result, main_thread};

    thread_local! {
        /// Sounds still playing, kept alive until they finish.
        static PLAYING: RefCell<Vec<Retained<NSSound>>> = const { RefCell::new(Vec::new()) };
        static SPEECH: RefCell<Option<Retained<NSSpeechSynthesizer>>> = const { RefCell::new(None) };
    }

    pub fn beep() {
        NSBeep();
    }

    fn play(sound: Retained<NSSound>, volume: f32) -> Result<()> {
        main_thread()?;
        sound.setVolume(volume);
        if !sound.play() {
            return Err(PlatformError::Failed(
                "the sound could not be played".into(),
            ));
        }
        PLAYING.with(|playing| {
            let mut playing = playing.borrow_mut();
            playing.retain(|s| s.isPlaying());
            playing.push(sound);
        });
        Ok(())
    }

    pub fn play_named(name: &str, volume: f32) -> Result<()> {
        let sound = NSSound::soundNamed(&NSString::from_str(name))
            .ok_or_else(|| PlatformError::Failed(format!("no system sound named {name}")))?;
        play(sound, volume)
    }

    pub fn play_file(path: &Path, volume: f32) -> Result<()> {
        let path_text = path.to_string_lossy();
        let sound = NSSound::initWithContentsOfFile_byReference(
            NSSound::alloc(),
            &NSString::from_str(&path_text),
            true,
        )
        .ok_or_else(|| PlatformError::Failed(format!("cannot read sound file {path_text}")))?;
        play(sound, volume)
    }

    pub fn speak(text: &str, voice: Option<&str>, rate: Option<f32>) -> Result<()> {
        main_thread()?;
        let voice = voice.map(NSString::from_str);
        let synth =
            NSSpeechSynthesizer::initWithVoice(NSSpeechSynthesizer::alloc(), voice.as_deref())
                .ok_or_else(|| PlatformError::Failed("speech voice not available".into()))?;
        if let Some(rate) = rate {
            synth.setRate(rate);
        }
        stop_speaking();
        if !synth.startSpeakingString(&NSString::from_str(text)) {
            return Err(PlatformError::Failed("speech could not start".into()));
        }
        SPEECH.with(|speech| *speech.borrow_mut() = Some(synth));
        Ok(())
    }

    pub fn stop_speaking() {
        SPEECH.with(|speech| {
            if let Some(synth) = speech.borrow_mut().take() {
                synth.stopSpeaking();
            }
        });
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::path::Path;

    use crate::platform::{Result, log_unsupported_once, unsupported};

    pub fn beep() {
        log_unsupported_once("system beep");
    }

    pub fn play_named(_name: &str, _volume: f32) -> Result<()> {
        unsupported("system sounds")
    }

    pub fn play_file(_path: &Path, _volume: f32) -> Result<()> {
        unsupported("system sounds")
    }

    pub fn speak(_text: &str, _voice: Option<&str>, _rate: Option<f32>) -> Result<()> {
        unsupported("speech")
    }

    pub fn stop_speaking() {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sound_sources() {
        assert_eq!(sound_source(""), None);
        assert_eq!(sound_source("Pop"), Some(SoundSource::Named("Pop".into())));
        assert_eq!(
            sound_source("Glass.aiff"),
            Some(SoundSource::Named("Glass".into()))
        );
        assert_eq!(
            sound_source("/System/Library/Sounds/Pop.aiff"),
            Some(SoundSource::File("/System/Library/Sounds/Pop.aiff".into()))
        );
        assert_eq!(
            sound_source("~/ding.wav"),
            Some(SoundSource::File("~/ding.wav".into()))
        );
    }

    #[test]
    fn volumes_are_clamped() {
        assert_eq!(clamp_volume(-1.0), 0.0);
        assert_eq!(clamp_volume(0.4), 0.4);
        assert_eq!(clamp_volume(3.0), 1.0);
        assert_eq!(clamp_volume(f32::NAN), 1.0);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn stubs_do_not_panic() {
        beep();
        stop_speaking();
        assert!(play_named("Pop", 1.0).is_err());
        assert!(speak("hi", None, None).is_err());
    }
}
