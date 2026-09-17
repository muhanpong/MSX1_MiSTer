#!/usr/bin/env bash
# patched/ must be exactly the untouched originals (../) plus patches/*.patch, in order.
set -eu
here=$(cd "$(dirname "$0")" && pwd); src=$here/..; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a"
cp "$src"/nextz80cpu.v "$src"/nextz80reg.v "$src"/nextz80alu.v "$tmp/a/"
for p in "$here"/0*.patch; do ( cd "$tmp/a" && patch -s -p1 < "$p" ); done
ok=1
for f in nextz80cpu.v nextz80reg.v nextz80alu.v; do
  cmp -s "$tmp/a/$f" "$src/patched/$f" || { echo "MISMATCH $f"; ok=0; }
done
[ $ok = 1 ] && echo "patched/ == originals + $(ls "$here"/0*.patch | wc -l) patches"
