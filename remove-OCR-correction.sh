#!/usr/bin/env bash
set -euo pipefail

exec python3 - "$@" <<'PY'
"""Remove the OCR Corrections Notes section and its linked footnote refs."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

HEADING_RE = re.compile(r"^(#{1,6})\s*OCR\s+Corrections?\s+Notes?\s*$", re.IGNORECASE)
FOOTNOTE_DEF_RE = re.compile(r"^\[\^([^\]]+)\]:")
HORIZONTAL_RULE_RE = re.compile(r"^(-{3,}|\*{3,}|_{3,})\s*$")


def detect_newline(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def find_ocr_section(lines: list[str]) -> tuple[int | None, int | None, int | None]:
    """Return (start_idx, heading_idx, end_idx) for OCR notes section."""
    for i, line in enumerate(lines):
        m = HEADING_RE.match(line.strip())
        if not m:
            continue
        level = len(m.group(1))
        start = i
        # Pull in an adjacent horizontal rule (and surrounding blanks) if present.
        j = i - 1
        while j >= 0 and lines[j].strip() == "":
            j -= 1
        if j >= 0 and HORIZONTAL_RULE_RE.match(lines[j].strip()):
            start = j
            while start - 1 >= 0 and lines[start - 1].strip() == "":
                start -= 1
        # Find end of section: next heading of same or higher level, or EOF.
        end = len(lines)
        for k in range(i + 1, len(lines)):
            m2 = re.match(r"^(#{1,6})\s+\S", lines[k])
            if m2 and len(m2.group(1)) <= level:
                end = k
                break
        return start, i, end
    return None, None, None


def remove_ocr_notes(text: str) -> tuple[str, dict]:
    newline = detect_newline(text)
    had_trailing_newline = text.endswith("\n") or text.endswith("\r\n")
    lines = text.splitlines()

    start, heading_idx, end = find_ocr_section(lines)
    if start is None:
        return text, {
            "section_removed": False,
            "removed_ids": set(),
            "ref_count": 0,
        }

    section_lines = lines[start:end]
    ocr_ids = set()
    for line in section_lines:
        m = FOOTNOTE_DEF_RE.match(line.strip())
        if m:
            ocr_ids.add(m.group(1))

    remaining_lines = lines[:start] + lines[end:]

    # Avoid removing refs for ids that still have definitions elsewhere.
    other_defs = set()
    for line in remaining_lines:
        m = FOOTNOTE_DEF_RE.match(line.strip())
        if m:
            other_defs.add(m.group(1))
    remove_ids = ocr_ids - other_defs

    new_text = newline.join(remaining_lines)
    ref_count = 0
    if remove_ids:
        ids_pattern = "|".join(sorted((re.escape(i) for i in remove_ids), key=len, reverse=True))
        pattern = re.compile(r"\[\^(?:" + ids_pattern + r")\]")
        new_text, ref_count = pattern.subn("", new_text)

    if had_trailing_newline and not new_text.endswith(newline):
        new_text += newline

    return new_text, {
        "section_removed": True,
        "removed_ids": remove_ids,
        "ref_count": ref_count,
    }


def unique_backup_path(path: pathlib.Path) -> pathlib.Path:
    base = path.with_name(path.name + ".bak")
    if not base.exists():
        return base
    counter = 1
    while True:
        candidate = path.with_name(path.name + f".bak.{counter}")
        if not candidate.exists():
            return candidate
        counter += 1


def process_file(path: pathlib.Path, output: pathlib.Path | None) -> int:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        print(f"Error: file not found: {path}", file=sys.stderr)
        return 2

    new_text, info = remove_ocr_notes(text)
    if new_text == text:
        if info["section_removed"]:
            print(f"No changes needed for: {path}")
        else:
            print(f"No OCR Corrections Notes section found in: {path}")
        return 0

    if output:
        output.write_text(new_text, encoding="utf-8")
        print(f"Wrote updated markdown to: {output}")
    else:
        backup = unique_backup_path(path)
        backup.write_text(text, encoding="utf-8")
        path.write_text(new_text, encoding="utf-8")
        print(f"Updated: {path}")
        print(f"Backup: {backup}")

    removed_ids = sorted(info["removed_ids"], key=lambda s: (len(s), s))
    if removed_ids:
        print(f"Removed {len(removed_ids)} OCR footnote id(s) and {info['ref_count']} reference(s).")
    else:
        print("Removed OCR Corrections Notes section.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Remove the OCR Corrections Notes section from a cleaned markdown file "
            "and delete any footnote references that link to it."
        )
    )
    parser.add_argument("paths", nargs="+", help="Markdown file(s) to process")
    parser.add_argument(
        "-o",
        "--output",
        help="Write result to this file (only valid with a single input file)",
    )
    args = parser.parse_args()

    if args.output and len(args.paths) != 1:
        print("Error: --output requires exactly one input file.", file=sys.stderr)
        return 2

    output_path = pathlib.Path(args.output) if args.output else None

    exit_code = 0
    for raw_path in args.paths:
        path = pathlib.Path(raw_path)
        out = output_path
        if output_path and len(args.paths) == 1:
            out = output_path
        else:
            out = None
        exit_code = max(exit_code, process_file(path, out))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
PY
