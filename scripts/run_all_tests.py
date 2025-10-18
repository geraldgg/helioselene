#!/usr/bin/env python3
"""
Run the full HelioSelene test suite:
  1. Rust unit/integration tests (cargo test)
  2. Flutter/Dart tests (flutter test)
  3. Python FFI smoke test
  4. Python Rust-vs-Skyfield comparison check

The script stops at the first failure and exits with the failing command's code.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(cmd: list[str], *, cwd: Path | None = None) -> int:
    """Execute a command, streaming output, and return its exit code."""
    pretty = " ".join(cmd)
    print(f"\n=== Running: {pretty} ===")
    completed = subprocess.run(cmd, cwd=cwd or ROOT)
    print(f"=== Exit code: {completed.returncode} ({pretty}) ===\n")
    return completed.returncode


def main() -> int:
    steps: list[list[str]] = [
        ["cargo", "test", "--manifest-path", "rust/isscore/Cargo.toml"],
        ["flutter", "test"],
        [sys.executable, "rust/isscore/tests/simple_ffi_test.py"],
        [sys.executable, "rust/isscore/tests/compare_rust_python.py"],
    ]

    for cmd in steps:
        code = run(cmd)
        if code != 0:
            return code
    return 0


if __name__ == "__main__":
    sys.exit(main())
