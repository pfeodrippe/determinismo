// SPDX-License-Identifier: MIT
// The examples quint_check.js uses, made as the image builds (from Quint's examples directory):
// those whose dashboard (README.md) says their tests pass, with the --main Quint's own
// .scripts/run-example.sh gives them, kept if their tests pass on both backends here (seed 1);
// `runs` says whether it has a state machine to simulate (quint run takes it).
// Prints the JSON: [{"file": "...", "main": ["--main=..."], "runs": true}].
"use strict";

const { execFileSync } = require("child_process");
const fs = require("fs");

const rows = fs.readFileSync("README.md", "utf8").split("\n").filter((line) => line.startsWith("| ["));
const kept = [];
for (const row of rows) {
  const cells = row.split("|").map((cell) => cell.trim());
  const file = (cells[1].match(/\]\(\.\/([^)]*)\)/) || [])[1];
  if (!file || !cells[4].includes("white_check_mark")) continue;
  const main = execFileSync("bash", ["-c", 'source <(sed -n "/^get_main ()/,/^}/p" .scripts/run-example.sh); get_main "$1"', "_", file])
    .toString()
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  let passes = true;
  for (const backend of ["typescript", "rust"]) {
    try {
      execFileSync("quint", ["test", ...main, "--backend", backend, "--seed=1", "--max-samples=10", file], {
        stdio: "ignore",
        timeout: 300000,
      });
    } catch {
      passes = false;
    }
  }
  let runs = true;
  try {
    execFileSync("quint", ["run", ...main, "--seed=1", "--max-samples=1", "--max-steps=1", file], { stdio: "ignore", timeout: 300000 });
  } catch {
    runs = false;
  }
  if (passes) kept.push({ file, main, runs });
  else process.stderr.write(`manifest: ${file} left out (its tests do not pass on both backends here)\n`);
}
process.stderr.write(`manifest: ${kept.length} examples\n`);
process.stdout.write(JSON.stringify(kept, null, 1) + "\n");
