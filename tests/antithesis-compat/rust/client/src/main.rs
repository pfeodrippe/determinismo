// SPDX-License-Identifier: MIT
//! The maze with determinismo's Rust SDK: three digits to guess, one branch each. Its edges,
//! from rustc's trace-pc-guard, are reported as the source lines they are on (the binary is in
//! /symbols), as the C maze's.

fn digit() -> u64 {
    determinismo::random_below(10)
}

fn main() {
    let mut found = 0;
    if digit() == 7 {
        found = 1;
        if digit() == 3 {
            found = 2;
            if digit() == 9 {
                found = 3;
            }
        }
    }
    println!("maze (rust): {found} digits");
}
