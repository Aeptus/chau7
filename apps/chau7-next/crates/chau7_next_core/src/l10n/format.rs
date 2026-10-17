//! `String(format:)` for the `%@`, `%d`, `%s`, `%f` and positional (`%1$@`)
//! specifiers the `.strings` files use.

/// One argument of a localized format string.
#[derive(Debug, Clone, PartialEq)]
pub enum Arg {
    Str(String),
    Int(i64),
    Float(f64),
}

impl From<&str> for Arg {
    fn from(v: &str) -> Arg {
        Arg::Str(v.to_string())
    }
}
impl From<String> for Arg {
    fn from(v: String) -> Arg {
        Arg::Str(v)
    }
}
impl From<i64> for Arg {
    fn from(v: i64) -> Arg {
        Arg::Int(v)
    }
}
impl From<usize> for Arg {
    fn from(v: usize) -> Arg {
        Arg::Int(v as i64)
    }
}
impl From<u32> for Arg {
    fn from(v: u32) -> Arg {
        Arg::Int(v as i64)
    }
}
impl From<f64> for Arg {
    fn from(v: f64) -> Arg {
        Arg::Float(v)
    }
}

impl Arg {
    fn text(&self) -> String {
        match self {
            Arg::Str(s) => s.clone(),
            Arg::Int(i) => i.to_string(),
            Arg::Float(f) => format!("{f:.6}"),
        }
    }
}

/// Fill `fmt` with `args`. `%%` is a percent sign; a specifier without an
/// argument is left as written.
pub fn format_printf(fmt: &str, args: &[Arg]) -> String {
    let chars: Vec<char> = fmt.chars().collect();
    let mut out = String::new();
    let mut next = 0usize;
    let mut i = 0;
    while i < chars.len() {
        if chars[i] != '%' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        if chars.get(i + 1) == Some(&'%') {
            out.push('%');
            i += 2;
            continue;
        }
        let start = i;
        i += 1;
        // Positional "1$".
        let mut position = None;
        let digits_end = (i..chars.len())
            .find(|&j| !chars[j].is_ascii_digit())
            .unwrap_or(chars.len());
        if digits_end > i && chars.get(digits_end) == Some(&'$') {
            position = chars[i..digits_end]
                .iter()
                .collect::<String>()
                .parse::<usize>()
                .ok();
            i = digits_end + 1;
        }
        // Flags, width, precision, length modifiers.
        let mut precision = None;
        while i < chars.len() && "-+ 0#".contains(chars[i]) {
            i += 1;
        }
        while i < chars.len() && chars[i].is_ascii_digit() {
            i += 1;
        }
        if chars.get(i) == Some(&'.') {
            i += 1;
            let p_start = i;
            while i < chars.len() && chars[i].is_ascii_digit() {
                i += 1;
            }
            precision = chars[p_start..i]
                .iter()
                .collect::<String>()
                .parse::<usize>()
                .ok()
                .or(Some(0));
        }
        while i < chars.len() && "hlqLzjt".contains(chars[i]) {
            i += 1;
        }
        let Some(&conv) = chars.get(i) else {
            out.extend(&chars[start..]);
            break;
        };
        i += 1;
        let index = position.map(|p| p.saturating_sub(1)).unwrap_or_else(|| {
            next += 1;
            next - 1
        });
        let Some(arg) = args.get(index) else {
            out.extend(&chars[start..i]);
            continue;
        };
        match (conv, arg) {
            ('d' | 'i' | 'u', Arg::Int(v)) => out.push_str(&v.to_string()),
            ('d' | 'i' | 'u', Arg::Float(v)) => out.push_str(&(*v as i64).to_string()),
            ('f' | 'g', Arg::Float(v)) => {
                out.push_str(&format!("{:.*}", precision.unwrap_or(6), v))
            }
            ('f' | 'g', Arg::Int(v)) => {
                out.push_str(&format!("{:.*}", precision.unwrap_or(6), *v as f64))
            }
            ('x', Arg::Int(v)) => out.push_str(&format!("{v:x}")),
            _ => out.push_str(&arg.text()),
        }
    }
    out
}
