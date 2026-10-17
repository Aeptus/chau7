//! Builds the one C file Chau7 Next needs: the shim for the macOS unified log
//! (`os_log_with_type` is a macro, so Rust cannot call it directly). Other
//! targets compile nothing.

fn main() {
    println!("cargo:rerun-if-changed=src/platform/oslog_shim.c");
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("src/platform/oslog_shim.c")
            .compile("chau7_oslog_shim");
    }
}
