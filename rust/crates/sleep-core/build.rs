//! build.rs for sleep-core.
//!
//! Runs `swift_bridge_build::parse_bridges` over `src/bindings.rs` and writes
//! the generated Swift + C header into `$OUT_DIR/generated` at build time.
//!
//! `scripts/gen_bindings.sh` copies the outputs into
//! `apple/SleepKit/Sources/SleepKit/Generated/` so they become part of the
//! Swift Package target.

use std::path::PathBuf;

fn main() {
    let bridges = vec![PathBuf::from("src/bindings.rs")];
    for path in &bridges {
        println!("cargo:rerun-if-changed={}", path.display());
    }

    let out_dir: PathBuf = match std::env::var_os("SWIFT_BRIDGE_OUT_DIR") {
        Some(v) => PathBuf::from(v),
        None => PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR missing")).join("generated"),
    };
    std::fs::create_dir_all(&out_dir).expect("mkdir SWIFT_BRIDGE_OUT_DIR");

    swift_bridge_build::parse_bridges(bridges)
        .write_all_concatenated(&out_dir, "SleepCore");

    println!("cargo:warning=swift-bridge output -> {}", out_dir.display());
}
