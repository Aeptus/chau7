fn main() {
    // Chau7 Next links this crate as an rlib and does not need the C header.
    // Skipping regeneration keeps its builds from rewriting include/.
    // Any rerun-if-* line turns off Cargo's default "rerun on any file
    // change", so list the header inputs explicitly.
    println!("cargo:rerun-if-env-changed=CHAU7_TERMINAL_SKIP_CBINDGEN");
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var_os("CHAU7_TERMINAL_SKIP_CBINDGEN").is_some() {
        return;
    }
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    cbindgen::generate(&crate_dir)
        .expect("Unable to generate bindings")
        .write_to_file("include/chau7_terminal.h");
}
