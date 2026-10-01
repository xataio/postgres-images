#!/usr/bin/env python3
"""Apply the updates in a Renovate report to the working tree.

Renovate's local mode only reports what it would change. This script makes the
same edits Renovate makes on a branch: in each file it replaces the matched
text of a dependency with the same text holding the new value.

Usage: apply-report.py REPORT.json
"""

import json
import sys


def main(report_path):
    with open(report_path, encoding="utf-8") as f:
        report = json.load(f)

    edits = {}  # path -> {old text: new text}
    for repo in report["repositories"].values():
        for files in repo["packageFiles"].values():
            for file in files:
                for dep in file["deps"]:
                    for update in dep.get("updates", [])[:1]:
                        old = dep["replaceString"]
                        edits.setdefault(file["packageFile"], {})[old] = old.replace(
                            dep["currentValue"], update["newValue"]
                        )

    for path, replacements in sorted(edits.items()):
        with open(path, encoding="utf-8", newline="") as f:
            text = f.read()
        for old, new in replacements.items():
            if old not in text:
                sys.exit(f"{path}: cannot find {old!r}")
            text = text.replace(old, new)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        print(f"updated {path}")


if __name__ == "__main__":
    main(sys.argv[1])
