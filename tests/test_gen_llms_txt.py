#!/usr/bin/env python3
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "gen-llms-txt"
LOADER = importlib.machinery.SourceFileLoader("gen_llms_txt", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
MODULE = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(MODULE)


class StripFrontmatterTests(unittest.TestCase):
    def test_removes_leading_yaml_frontmatter(self) -> None:
        text = '---\ntitle: "Guide"\n---\n\n# Guide\n\nBody.\n'
        self.assertEqual(MODULE.strip_frontmatter(text), "# Guide\n\nBody.\n")


class StripTitleBlockTests(unittest.TestCase):
    def test_collapses_duplicate_title_with_only_date_metadata(self) -> None:
        text = "# Guide\n\n2026-06-18\n\n# Guide\n\nBody.\n"
        self.assertEqual(MODULE.strip_title_block(text), "# Guide\n\nBody.\n")

    def test_preserves_authored_prose_before_repeated_title(self) -> None:
        text = "# Guide\n\nLead paragraph.\n\n# Guide\n\nBody.\n"
        self.assertEqual(MODULE.strip_title_block(text), text)

    def test_removes_bare_date_after_single_title(self) -> None:
        text = "# Guide\n\n2026-06-18\n\nBody.\n"
        self.assertEqual(MODULE.strip_title_block(text), "# Guide\n\nBody.\n")

    def test_leaves_unrelated_content_unchanged(self) -> None:
        text = "# Guide\n\nBody.\n"
        self.assertEqual(MODULE.strip_title_block(text), text)


class NormalizeTwinsTests(unittest.TestCase):
    def test_renames_twin_and_rewrites_only_href(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "guide-gfm.md").write_text("# Guide\n\nBody.\n", encoding="utf-8")
            html = out / "guide.html"
            html.write_text(
                '<a href="guide-gfm.md">GFM</a>'
                "<p>guide-gfm.md</p><code>guide-gfm.md</code>",
                encoding="utf-8",
            )

            MODULE.normalize_twins(out)

            self.assertFalse((out / "guide-gfm.md").exists())
            self.assertTrue((out / "guide.md").exists())
            self.assertEqual(
                html.read_text(encoding="utf-8"),
                '<a href="guide.md">GFM</a>'
                "<p>guide-gfm.md</p><code>guide-gfm.md</code>",
            )

    def test_is_idempotent_after_rename(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            target = out / "guide-gfm.md"
            target.write_text("# Guide\n\nBody.\n", encoding="utf-8")
            MODULE.normalize_twins(out)
            first = (out / "guide.md").read_text(encoding="utf-8")
            MODULE.normalize_twins(out)
            self.assertEqual((out / "guide.md").read_text(encoding="utf-8"), first)


class SummaryTests(unittest.TestCase):
    def test_skips_ordered_lists(self) -> None:
        text = "# Guide\n\n1. First item\n2) Second item\n\nSummary paragraph.\n"
        self.assertEqual(MODULE.first_paragraph(text), "Summary paragraph.")


class CommandTests(unittest.TestCase):
    def test_explains_missing_markdown_twins(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "_site"
            out.mkdir()
            env = os.environ.copy()
            env["QUARTO_PROJECT_OUTPUT_DIR"] = str(out)
            result = subprocess.run(
                [str(SCRIPT)],
                cwd=tmp,
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("no Markdown twins found", result.stderr)


if __name__ == "__main__":
    unittest.main()
