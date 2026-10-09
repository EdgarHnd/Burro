#!/usr/bin/env bash
# Build the pinned Rust helper; never install a toolchain implicitly.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if ! command -v cargo >/dev/null 2>&1 && [[ -x "$ROOT_DIR/.build/cargo/bin/cargo" ]]; then
  export CARGO_HOME="$ROOT_DIR/.build/cargo"
  export RUSTUP_HOME="$ROOT_DIR/.build/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
command -v cargo >/dev/null 2>&1 || { echo "Rust is required. Install rustup, then rerun this script (see README.md)." >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --manifest-path "$ROOT_DIR/Rust/Cargo.toml" --target-dir "$ROOT_DIR/.build/rust" --release --locked
if [[ -n "${1:-}" ]]; then
  mkdir -p "$1"
  cp "$ROOT_DIR/.build/rust/release/burro-log-worker" "$1/burro-log-worker"
fi
