// SPDX-License-Identifier: MIT
//! The SDK's catalog and assertions, outside determinismo: `cargo run --example catalog`, with
//! DETERMINISMO_SDK_LOCAL_OUTPUT set to see the events a file gets.
use determinismo::{always, catalog, json, reachable, sometimes, unreachable};

fn main() {
    always!(2 + 2 == 4, "arithmetic holds", &json!({ "sum": 4 }));
    sometimes!(determinismo::random_below(2) == 0, "a coin comes up heads");
    reachable!("the example runs");
    if determinismo::random_below(1) == 1 {
        unreachable!("an impossible draw");
    }
    catalog::write(&mut std::io::stdout()).unwrap();
}
