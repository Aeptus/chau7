//! Numeric entry for Swift's TextField(value:format:.number), independent of
//! interface language and the separate AI usage number-format preference.

pub(super) use imp::NumberFormat;

#[cfg(target_os = "macos")]
mod imp {
    use core_foundation::{
        base::{CFType, TCFType},
        string::CFString,
    };
    use core_foundation_sys::{
        base::CFRange,
        locale::{CFLocaleCopyCurrent, CFLocaleCreate},
        number::{CFNumberGetValue, kCFBooleanTrue, kCFNumberSInt64Type},
        number_formatter::{
            CFNumberFormatterCreate, CFNumberFormatterCreateNumberFromString,
            CFNumberFormatterCreateStringWithValue, CFNumberFormatterRef,
            CFNumberFormatterSetProperty, kCFNumberFormatterDecimalStyle,
            kCFNumberFormatterIsLenient, kCFNumberFormatterParseIntegersOnly,
        },
        string::CFStringGetLength,
    };

    /// Held by one SettingsView and only used on its GPUI thread.
    pub(crate) struct NumberFormat(Option<CFType>);
    impl NumberFormat {
        pub(crate) fn current() -> Self {
            Self::new(None)
        }
        fn new(identifier: Option<&str>) -> Self {
            // All Copy/Create references are released by owned CFType wrappers.
            unsafe {
                let locale = match identifier {
                    Some(id) => {
                        CFLocaleCreate(std::ptr::null(), CFString::new(id).as_concrete_TypeRef())
                    }
                    None => CFLocaleCopyCurrent(),
                };
                if locale.is_null() {
                    return Self(None);
                }
                let locale = CFType::wrap_under_create_rule(locale.cast());
                let formatter = CFNumberFormatterCreate(
                    std::ptr::null(),
                    locale.as_CFTypeRef().cast(),
                    kCFNumberFormatterDecimalStyle,
                );
                if formatter.is_null() {
                    return Self(None);
                }
                CFNumberFormatterSetProperty(
                    formatter,
                    kCFNumberFormatterIsLenient,
                    kCFBooleanTrue.cast(),
                );
                Self(Some(CFType::wrap_under_create_rule(formatter.cast())))
            }
        }
        fn raw(&self) -> Option<CFNumberFormatterRef> {
            self.0
                .as_ref()
                .map(|value| value.as_CFTypeRef().cast_mut().cast())
        }
        pub(crate) fn format(&self, value: usize) -> String {
            let value = value as i64; // Scrollback is bounded to 100,000 by its store.
            let Some(formatter) = self.raw() else {
                return value.to_string();
            };
            unsafe {
                let text = CFNumberFormatterCreateStringWithValue(
                    std::ptr::null(),
                    formatter,
                    kCFNumberSInt64Type,
                    (&value as *const i64).cast(),
                );
                if text.is_null() {
                    value.to_string()
                } else {
                    CFString::wrap_under_create_rule(text).to_string()
                }
            }
        }
        pub(crate) fn parse(&self, text: &str) -> Option<i64> {
            let Some(formatter) = self.raw() else {
                return text.trim().parse().ok();
            };
            let text = CFString::new(text.trim());
            unsafe {
                let mut range = CFRange {
                    location: 0,
                    length: CFStringGetLength(text.as_concrete_TypeRef()),
                };
                let number = CFNumberFormatterCreateNumberFromString(
                    std::ptr::null(),
                    formatter,
                    text.as_concrete_TypeRef(),
                    &mut range,
                    kCFNumberFormatterParseIntegersOnly,
                );
                if number.is_null() {
                    return None;
                }
                let number = CFType::wrap_under_create_rule(number.cast());
                let mut value = 0i64;
                // Failed exact conversion rejects overflow before the setting clamp.
                CFNumberGetValue(
                    number.as_CFTypeRef().cast(),
                    kCFNumberSInt64Type,
                    (&mut value as *mut i64).cast(),
                )
                .then_some(value)
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn native_region_and_numbering_system_display_match_foundation() {
            for (locale, small, large) in [
                ("es_ES", "1234", "10.000"),
                ("he_IL", "1,234", "10,000"),
                ("ar_EG", "١٬٢٣٤", "١٠٬٠٠٠"),
            ] {
                let format = NumberFormat::new(Some(locale));
                assert_eq!(format.format(1234), small, "{locale}");
                assert_eq!(format.format(10000), large, "{locale}");
                assert_eq!(format.parse(small), Some(1234), "{locale}");
                assert_eq!(format.parse(large), Some(10000), "{locale}");
            }
        }
        #[test]
        fn native_integer_entry_matches_foundation_number_style_goldens() {
            for (locale, display, comma) in [
                ("en_US", "10,000", 10000),
                ("fr_FR", "10\u{202f}000", 10),
                ("en_US@rg=frzzzz", "10\u{202f}000", 10),
                ("ar", "10,000", 10000),
            ] {
                let format = NumberFormat::new(Some(locale));
                assert_eq!(format.format(10000), display, "{locale}");
                assert_eq!(format.parse(display), Some(10000), "{locale}");
                assert_eq!(format.parse("10,000"), Some(comma), "{locale}");
                for (input, expected) in [
                    ("10 000", 10000),
                    ("10\u{202f}000", 10000),
                    ("١٠٠٠٠", 10000),
                    ("13.5", 13),
                    ("13,5", 13),
                    ("-100", -100),
                    ("99", 99),
                    ("100001", 100001),
                ] {
                    assert_eq!(format.parse(input), Some(expected), "{locale}: {input}");
                }
                for input in [
                    "",
                    "+",
                    "99999999999999999999999999999999999999999999",
                    "9223372036854775808",
                    "-9223372036854775809",
                ] {
                    assert_eq!(format.parse(input), None, "{locale}: {input}");
                }
                assert_eq!(format.parse("9223372036854775807"), Some(i64::MAX));
                assert_eq!(format.parse("-9223372036854775808"), Some(i64::MIN));
            }
        }
    }
}

#[cfg(any(not(target_os = "macos"), test))]
mod portable {
    use chau7_next_core::l10n::{Lang, formatters, numbers::RegionalNumberFormat};
    pub(crate) struct NumberFormat {
        region: RegionalNumberFormat,
        display_language: Option<Lang>,
    }
    impl NumberFormat {
        pub(crate) fn current() -> Self {
            Self::for_locale(sys_locale::get_locale().as_deref().unwrap_or("en_US"))
        }
        fn for_locale(locale: &str) -> Self {
            let locale = locale.to_ascii_lowercase();
            Self {
                region: if locale.starts_with("fr") || locale.contains("rg=fr") {
                    RegionalNumberFormat::French
                } else if ["de", "es", "it", "pt"]
                    .iter()
                    .any(|prefix| locale.starts_with(prefix))
                {
                    RegionalNumberFormat::European
                } else {
                    RegionalNumberFormat::UnitedStates
                },
                display_language: if locale == "es"
                    || locale.starts_with("es_es")
                    || locale.starts_with("es-es")
                {
                    Some(Lang::Es)
                } else if locale.starts_with("ar_eg")
                    || locale.starts_with("ar-eg")
                    || locale.contains("-u-nu-arab")
                    || locale.contains("numbers=arab")
                {
                    Some(Lang::Ar)
                } else {
                    None
                },
            }
        }
        pub(crate) fn format(&self, value: usize) -> String {
            match self.display_language {
                Some(language) => formatters::integer(language, value as i64),
                None => self.region.integer(value as i64),
            }
        }
        pub(crate) fn parse(&self, text: &str) -> Option<i64> {
            let text: Vec<char> = text.trim().chars().collect();
            let mut index = 0;
            let negative = match text.first() {
                Some('-' | '−') => {
                    index = 1;
                    true
                }
                Some('+') => {
                    index = 1;
                    false
                }
                _ => false,
            };
            let mut value = 0i64;
            let mut digits = 0;
            while let Some(&ch) = text.get(index) {
                let digit = digit(ch);
                if let Some(digit) = digit {
                    value = value.checked_mul(10)?;
                    value = if negative {
                        value.checked_sub(i64::from(digit))?
                    } else {
                        value.checked_add(i64::from(digit))?
                    };
                    digits += 1;
                } else {
                    // Lenient Foundation integer parsing stops before fractions or
                    // malformed punctuation; complete groups are consumed.
                    let grouping = ch == '٬' && self.display_language == Some(Lang::Ar)
                        || match self.region {
                            RegionalNumberFormat::French => ch.is_whitespace(),
                            RegionalNumberFormat::European => ch == '.' || ch.is_whitespace(),
                            RegionalNumberFormat::UnitedStates => ch == ',' || ch.is_whitespace(),
                        };
                    let next_digits = text[index + 1..]
                        .iter()
                        .take_while(|&&ch| self::digit(ch).is_some())
                        .count();
                    if !grouping || next_digits != 3 || digits == 0 {
                        break;
                    }
                }
                index += 1;
            }
            (digits > 0).then_some(value)
        }
    }
    fn digit(ch: char) -> Option<u32> {
        for zero in ['0', '٠', '۰'] {
            let value = (ch as u32).wrapping_sub(zero as u32);
            if value < 10 {
                return Some(value);
            }
        }
        None
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn portable_spanish_and_arabic_regional_formats_roundtrip() {
            for (locale, small, large) in
                [("es_ES", "1234", "10.000"), ("ar_EG", "١٬٢٣٤", "١٠٬٠٠٠")]
            {
                let format = NumberFormat::for_locale(locale);
                assert_eq!(format.format(1234), small);
                assert_eq!(format.format(10000), large);
                assert_eq!(format.parse(small), Some(1234));
                assert_eq!(format.parse(large), Some(10000));
            }
        }
        #[test]
        fn portable_common_numeric_locales_match_probed_foundation_examples() {
            // Exercise the real current-locale constructor even on macOS so this
            // fallback remains type checked without changing process locale.
            assert!(!NumberFormat::current().format(10000).is_empty());
            for (locale, display, comma) in [
                ("en_US", "10,000", 10000),
                ("fr_FR", "10\u{202f}000", 10),
                ("en_US@rg=frzzzz", "10\u{202f}000", 10),
                ("ar", "10,000", 10000),
            ] {
                let format = NumberFormat::for_locale(locale);
                assert_eq!(format.format(10000), display);
                assert_eq!(format.parse("10,000"), Some(comma));
                for (input, expected) in [
                    ("10 000", 10000),
                    ("10\u{202f}000", 10000),
                    ("١٠٠٠٠", 10000),
                    ("13.5", 13),
                    ("13,5", 13),
                    ("-100", -100),
                ] {
                    assert_eq!(format.parse(input), Some(expected), "{locale}: {input}");
                }
                assert_eq!(format.parse("9223372036854775807"), Some(i64::MAX));
                assert_eq!(format.parse("-9223372036854775808"), Some(i64::MIN));
                assert_eq!(format.parse("9223372036854775808"), None);
                assert_eq!(format.parse("-9223372036854775809"), None);
                assert_eq!(format.parse("+"), None);
            }
        }
    }
}
#[cfg(not(target_os = "macos"))]
mod imp {
    pub(crate) use super::portable::NumberFormat;
}
