#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Installs the pinned toolchain into ~/opt, checked against its published checksums: Zig, babashka
# (notebooks) and the TLA+ tools (`determinismo tla`). Idempotent. Runs on the host as the user.
# Usage: infra/host/tools.sh
set -euo pipefail
opt=$HOME/opt
mkdir -p "$opt"

# fetch <url> <sha256> <file>: downloads unless the file is there with that checksum.
fetch() {
  if [ -f "$3" ] && echo "$2  $3" | sha256sum -c --status; then return; fi
  curl -fsSL -o "$3.part" "$1"
  echo "$2  $3.part" | sha256sum -c --status || { echo "error: checksum of $1" >&2; exit 1; }
  mv "$3.part" "$3"
}

zig=zig-x86_64-linux-0.17.0
if [ ! -x "$opt/$zig/zig" ]; then
  fetch "https://ziglang.org/download/0.17.0/$zig.tar.xz" \
    1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 "$opt/$zig.tar.xz"
  tar -xJf "$opt/$zig.tar.xz" -C "$opt"
  rm "$opt/$zig.tar.xz"
fi
ln -sfn "$opt/$zig" "$opt/zig"

bb=babashka-1.13.225-linux-amd64-static.tar.gz
if ! "$opt/bb/bb" --version 2>/dev/null | grep -q 'v1.13.225'; then
  mkdir -p "$opt/bb"
  fetch "https://github.com/babashka/babashka/releases/download/v1.13.225/$bb" \
    ab0e98307405ba19e7c5ba0c3c7cd17a6f90aa90577a72709055f120796d6bfe "$opt/$bb"
  tar -xzf "$opt/$bb" -C "$opt/bb"
  rm "$opt/$bb"
fi

mkdir -p "$opt/tla"
fetch https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar \
  d15655eeaff4b3f7b3d65c46b838bc0f35d131b2ef4b1e473689b62c98d4726f "$opt/tla/tla2tools.jar"

echo "zig $("$opt/zig/zig" version), $("$opt/bb/bb" --version), tla2tools v1.8.0"
