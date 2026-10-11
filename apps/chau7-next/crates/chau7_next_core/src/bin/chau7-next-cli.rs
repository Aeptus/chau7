//! Shell-accessible Next helper; launching it never starts the GUI.
use std::io::Write;
fn main() {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    let result = chau7_next_core::skills::cli::Runner::default().run(&arguments);
    if std::io::stdout()
        .lock()
        .write_all(result.stdout.as_bytes())
        .is_err()
        || std::io::stderr()
            .lock()
            .write_all(result.stderr.as_bytes())
            .is_err()
    {
        std::process::exit(1);
    }
    std::process::exit(result.exit_code);
}
