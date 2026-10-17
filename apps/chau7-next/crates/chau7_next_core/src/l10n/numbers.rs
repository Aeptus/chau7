//! Number formatting chosen independently of the interface language.
//! Matches Swift RegionalNumberFormat and its fr_FR/de_DE/en_US locales.
use std::sync::atomic::{AtomicU8, Ordering};

use super::{Lang, formatters};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum RegionalNumberFormat {
    #[default]
    French,
    European,
    UnitedStates,
}

impl RegionalNumberFormat {
    pub const ALL: [Self; 3] = [Self::French, Self::European, Self::UnitedStates];
    pub fn id(self) -> &'static str {
        match self {
            Self::French => "fr",
            Self::European => "eu",
            Self::UnitedStates => "us",
        }
    }
    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|format| format.id() == id)
    }
    pub fn display_name(self) -> &'static str {
        match self {
            Self::French => "French",
            Self::European => "European",
            Self::UnitedStates => "US",
        }
    }
    pub fn example(self) -> &'static str {
        match self {
            Self::French => "1 234,56",
            Self::European => "1.234,56",
            Self::UnitedStates => "1,234.56",
        }
    }
    pub fn locale_id(self) -> &'static str {
        match self {
            Self::French => "fr_FR",
            Self::European => "de_DE",
            Self::UnitedStates => "en_US",
        }
    }
    pub fn decimal(self, value: f64, max_fraction: usize) -> String {
        match self {
            Self::French => formatters::decimal(Lang::Fr, value, max_fraction),
            Self::European => {
                formatters::decimal(Lang::Fr, value, max_fraction).replace('\u{202F}', ".")
            }
            Self::UnitedStates => formatters::decimal(Lang::En, value, max_fraction),
        }
    }
    pub fn integer(self, value: i64) -> String {
        self.decimal(value as f64, 0)
    }
    pub fn percent(self, fraction: f64) -> String {
        let value = self.decimal(fraction * 100.0, 1);
        match self {
            Self::UnitedStates => format!("{value}%"),
            _ => format!("{value}\u{00A0}%"),
        }
    }
    pub fn currency(self, amount: f64) -> String {
        self.currency_fraction(amount, 2)
    }
    pub fn cost_precise(self, amount: f64) -> String {
        self.currency_fraction(amount, if amount > 0.0 && amount < 0.01 { 4 } else { 2 })
    }
    pub fn abbreviated(self, count: i64) -> String {
        if count >= 1_000_000 {
            format!("{}M", self.decimal(count as f64 / 1_000_000.0, 1))
        } else if count >= 1000 {
            format!("{}K", self.decimal(count as f64 / 1000.0, 1))
        } else {
            self.integer(count)
        }
    }
    fn currency_fraction(self, amount: f64, digits: usize) -> String {
        let negative = if amount < 0.0 { "-" } else { "" };
        let value = self.decimal(amount.abs(), digits);
        let separator = if self == Self::UnitedStates { '.' } else { ',' };
        let mut value = value;
        let existing = value
            .split_once(separator)
            .map(|(_, fraction)| fraction.len());
        if existing.is_none() {
            value.push(separator);
        }
        for _ in existing.unwrap_or(0)..digits {
            value.push('0');
        }
        match self {
            Self::French => format!("{negative}{value}\u{00A0}$US"),
            Self::European => format!("{negative}{value}\u{00A0}$"),
            Self::UnitedStates => format!("{negative}${value}"),
        }
    }
}

static CURRENT: AtomicU8 = AtomicU8::new(0);
pub fn current() -> RegionalNumberFormat {
    match CURRENT.load(Ordering::Relaxed) {
        1 => RegionalNumberFormat::European,
        2 => RegionalNumberFormat::UnitedStates,
        _ => RegionalNumberFormat::French,
    }
}
pub fn set_current(format: RegionalNumberFormat) {
    CURRENT.store(
        match format {
            RegionalNumberFormat::French => 0,
            RegionalNumberFormat::European => 1,
            RegionalNumberFormat::UnitedStates => 2,
        },
        Ordering::Relaxed,
    );
}
pub fn integer(value: i64) -> String {
    current().integer(value)
}
pub fn decimal(value: f64, max_fraction: usize) -> String {
    current().decimal(value, max_fraction)
}
pub fn percent(fraction: f64) -> String {
    current().percent(fraction)
}
pub fn abbreviated(count: i64) -> String {
    current().abbreviated(count)
}
pub fn cost_precise(amount: f64) -> String {
    current().cost_precise(amount)
}
pub fn currency(amount: f64) -> String {
    current().currency(amount)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn raw_values_defaults_and_locales_match_swift() {
        assert_eq!(
            RegionalNumberFormat::default(),
            RegionalNumberFormat::French
        );
        for (id, locale) in [("fr", "fr_FR"), ("eu", "de_DE"), ("us", "en_US")] {
            assert_eq!(
                RegionalNumberFormat::from_id(id).unwrap().locale_id(),
                locale
            );
        }
        assert_eq!(RegionalNumberFormat::from_id("es"), None);
    }
    #[test]
    fn foundation_number_and_currency_examples() {
        let f = RegionalNumberFormat::French;
        let e = RegionalNumberFormat::European;
        let u = RegionalNumberFormat::UnitedStates;
        assert_eq!(f.integer(1234567), "1\u{202F}234\u{202F}567");
        assert_eq!(e.integer(1234567), "1.234.567");
        assert_eq!(u.integer(1234567), "1,234,567");
        assert_eq!(f.percent(0.256), "25,6\u{00A0}%");
        assert_eq!(e.percent(0.256), "25,6\u{00A0}%");
        assert_eq!(u.percent(0.256), "25.6%");
        assert_eq!(f.currency(1234.5), "1\u{202F}234,50\u{00A0}$US");
        assert_eq!(e.currency(1234.5), "1.234,50\u{00A0}$");
        assert_eq!(u.currency(1234.5), "$1,234.50");
        assert_eq!(u.currency(-1.0), "-$1.00");
        assert_eq!(u.cost_precise(0.0012), "$0.0012");
        assert_eq!(f.cost_precise(0.0012), "0,0012\u{00A0}$US");
        assert_eq!(f.abbreviated(1250), "1,2K");
        assert_eq!(u.abbreviated(1000), "1K");
        assert_eq!(e.currency(1000.0), "1.000,00\u{00A0}$");
    }
}
