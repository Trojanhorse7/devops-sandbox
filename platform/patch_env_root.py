#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> None:
    root = Path(sys.argv[1]).resolve()
    env_path = Path(".env")
    text = env_path.read_text(encoding="utf-8")
    replacement = f"SANDBOX_ROOT={root.as_posix()}"
    if re.search(r"^SANDBOX_ROOT=", text, flags=re.MULTILINE):
        text = re.sub(
            r"^SANDBOX_ROOT=.*$",
            replacement,
            text,
            flags=re.MULTILINE,
        )
    else:
        if not text.endswith("\n"):
            text += "\n"
        text += replacement + "\n"
    env_path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_env_root.py <repo_root>")
    main()
