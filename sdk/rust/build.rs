// SPDX-License-Identifier: MIT
// The coverage callbacks (feature `coverage`), compiled in C without the instrumentation.
fn main() {
    #[cfg(feature = "coverage")]
    cc::Build::new().file("src/coverage.c").compile("determinismo_coverage");
    println!("cargo:rerun-if-changed=src/coverage.c");
}
