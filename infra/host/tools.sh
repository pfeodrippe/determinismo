#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Installs the pinned toolchain into ~/opt, checked against its published checksums: Zig, babashka
# (notebooks), DuckDB (the events database) and the TLA+ tools (`determinismo tla`). Idempotent.
# Runs on the host as the user.
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

# DuckDB (the events database, linked into determinismo by build.zig): its static libraries for
# musl, and the libstdc++ they were built against (Alpine 3.22's, GCC 14.2.0).
duckdb=$opt/duckdb-2.0.0
if [ ! -f "$duckdb/libstdc++.a" ]; then
  mkdir -p "$duckdb"
  fetch https://github.com/duckdb/duckdb/releases/download/v2.0.0/duckdb-static-libs-linux-amd64-musl.tar.gz \
    2f783d69fc8713cf8482577fcde7e000f487997908feb9ef20ad35a3a642f59c "$opt/duckdb-static-libs.tar.gz"
  tar -xzf "$opt/duckdb-static-libs.tar.gz" -C "$duckdb"
  rm "$opt/duckdb-static-libs.tar.gz"
  # An apk is gzip members of tar archives one after another (--ignore-zeros reads past each).
  fetch https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/libstdc++-dev-14.2.0-r6.apk \
    13e2169b46a24f03c87caf91387312724b01951c222bd061d6d87c48903836a9 "$opt/libstdc++-dev.apk"
  tar -xzf "$opt/libstdc++-dev.apk" --ignore-zeros -C "$duckdb" --strip-components 2 \
    usr/lib/libstdc++.a 2>/dev/null
  rm "$opt/libstdc++-dev.apk"
  echo "150c8c511468a90780f804058d984c07c1c69519f3bd8fe0689c49c9a1f7da70  $duckdb/libstdc++.a" |
    sha256sum -c --status || { echo "error: libstdc++.a from the apk" >&2; exit 1; }
fi
ln -sfn "$duckdb" "$opt/duckdb"

mkdir -p "$opt/tla"
# v1.8.0 is a prerelease its project republishes under the same tag (2026-10-26 23:14 UTC): a
# changed checksum is that, never a reason to skip the check; pin the new jar after a look.
fetch https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar \
  78f7e2c6bf9a8b65eda665a23e94431255587e0b43a834a4e2af1723562d9b4a "$opt/tla/tla2tools.jar"

echo "zig $("$opt/zig/zig" version), $("$opt/bb/bb" --version), duckdb v2.0.0, tla2tools v1.8.0"
