use std::env;
use std::fs;
use std::io::{self, Read};
use std::process;
use termimad::{MadSkin, crossterm::style::Color};

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() > 1 && (args[1] == "-h" || args[1] == "--help") {
        eprintln!("Usage: chau7-md [FILE]");
        eprintln!("Render markdown to the terminal with ANSI formatting.");
        eprintln!("Reads from FILE or stdin if no file is given.");
        process::exit(0);
    }

    if args.len() > 2 {
        eprintln!("chau7-md: warning: extra arguments ignored, only rendering {}", args[1]);
    }

    let markdown = if args.len() > 1 {
        match fs::read_to_string(&args[1]) {
            Ok(content) => content,
            Err(e) => {
                eprintln!("chau7-md: {}: {}", args[1], e);
                process::exit(1);
            }
        }
    } else {
        let mut buf = String::new();
        if let Err(e) = io::stdin().read_to_string(&mut buf) {
            eprintln!("chau7-md: failed to read stdin: {}", e);
            process::exit(1);
        }
        buf
    };

    let skin = build_skin();
    // Print the rendered markdown to stdout (termimad handles ANSI output)
    skin.print_text(&markdown);
}

/// Builds a terminal skin tuned for dark backgrounds (typical terminal).
fn build_skin() -> MadSkin {
    let mut skin = MadSkin::default();

    // Headings: bold, colored, distinct hierarchy
    skin.headers[0].set_fg(Color::Cyan);
    skin.headers[1].set_fg(Color::Green);
    skin.headers[2].set_fg(Color::Yellow);
    skin.headers[3].set_fg(Color::Magenta);
    skin.headers[4].set_fg(Color::Blue);
    skin.headers[5].set_fg(Color::Red);

    // Bold & italic
    skin.bold.set_fg(Color::White);
    skin.italic.set_fg(Color::Magenta);

    // Inline code
    skin.inline_code.set_fg(Color::Yellow);
    skin.inline_code.set_bg(Color::AnsiValue(236)); // Dark grey background

    // Code blocks
    skin.code_block.set_bg(Color::AnsiValue(235));

    // Block quotes — dimmer, with a subtle tint
    skin.quote_mark.set_fg(Color::AnsiValue(245));

    // Horizontal rule
    skin.horizontal_rule.set_fg(Color::AnsiValue(240));

    // Bullet points
    skin.bullet.set_fg(Color::Cyan);

    // Links / URLs
    skin.paragraph.set_fg(Color::AnsiValue(252)); // Slightly off-white body text

    skin
}
