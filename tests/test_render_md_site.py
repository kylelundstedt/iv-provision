import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class RenderMarkdownSiteTests(unittest.TestCase):
    def setUp(self):
        if shutil.which("apex") is None:
            self.skipTest("apex is not installed")

    def test_apex_preserves_known_regression_cases(self):
        repo_root = Path(__file__).resolve().parents[1]
        renderer = repo_root / "bin" / "render-md-site"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            long_line = "a" * 4096 + "END-OF-LONG-LINE"
            (root / "index.md").write_text(
                "# Site\n\n"
                "## Verb contracts [TBD — define schema]\n\n"
                f"{long_line}\n\n"
                "- **Item.** Some text here.\n\n"
                "  Intro:\n\n"
                "  | A | B |\n"
                "  | --- | --- |\n"
                "  | 1 | 2 |\n\n"
                "  The relationship is **WAP : table writes :: AVE : executions**.\n\n"
                "::: {#home-recent}\nRecent content.\n:::\n",
                encoding="utf-8",
            )
            subprocess.run(
                [str(renderer), str(root)], check=True, env=os.environ.copy()
            )
            html = (root / "_site" / "index.html").read_text(encoding="utf-8")

        self.assertIn("Verb contracts [TBD — define schema]", html)
        self.assertIn("END-OF-LONG-LINE", html)
        self.assertIn("<table>", html)
        self.assertIn("<strong>WAP : table writes :: AVE : executions</strong>", html)
        self.assertIn('<div id="home-recent">', html)

    def test_links_resolve_against_what_the_render_produces(self):
        """A .md -> .html rewrite is only correct if the target is a page.

        Regression: iv-docs excluded spikes/ and agent_docs/ from the site but
        kept linking to them, and the pure-string rewrite turned 14 live links
        into 404s. Excluded targets must lose the link, not the text; linked
        non-page files must be published so the link keeps working.
        """
        repo_root = Path(__file__).resolve().parents[1]
        renderer = repo_root / "bin" / "render-md-site"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "spikes").mkdir()
            (root / "schemas").mkdir()
            (root / "spikes" / "01-spike.md").write_text("# Spike\n", encoding="utf-8")
            (root / "schemas" / "pkg.json").write_text("{}\n", encoding="utf-8")
            (root / "page.md").write_text("# Page\n", encoding="utf-8")
            (root / "index.md").write_text(
                "# Site\n\n"
                "- [rendered](page.md)\n"
                "- [excluded](spikes/01-spike.md)\n"
                "- [asset](schemas/pkg.json)\n"
                "- [missing](nope.md)\n"
                "- [external](https://example.com/x.md)\n",
                encoding="utf-8",
            )
            proc = subprocess.run(
                [str(renderer), str(root), "--exclude", "spikes/**"],
                check=True,
                capture_output=True,
                text=True,
                env=os.environ.copy(),
            )
            site = root / "_site"
            html = (site / "index.html").read_text(encoding="utf-8")
            asset_published = (site / "schemas" / "pkg.json").exists()

        # A link to a rendered page is rewritten to .html.
        self.assertIn('href="page.html"', html)
        # A link to an excluded page keeps its text but loses the dead href.
        self.assertIn("excluded", html)
        self.assertNotIn('href="spikes/01-spike.html"', html)
        # Same for a target that does not exist at all.
        self.assertIn("missing", html)
        self.assertNotIn('href="nope.html"', html)
        # A linked non-page file is published, so the link still resolves.
        self.assertTrue(asset_published)
        self.assertIn('href="schemas/pkg.json"', html)
        # External URLs are never touched, even when they end in .md.
        self.assertIn('href="https://example.com/x.md"', html)
        # The operator is told what the exclusions cost.
        self.assertIn("unlinked 2 link(s)", proc.stderr)

    def test_links_escaping_the_repo_are_not_rewritten(self):
        """`str.lstrip` takes a character set, not a prefix.

        Regression: the escape check normalised with `.lstrip("./")`, which
        turned "../decisions/x.md" into "decisions/x.md" -- eating the ".."
        it existed to detect. iv-docs had exactly one such authoring typo
        (spikes/ page linking "../../decisions/..." where "../" was meant) and
        the renderer rewrote it to a confident 404 instead of reporting it.
        """
        repo_root = Path(__file__).resolve().parents[1]
        renderer = repo_root / "bin" / "render-md-site"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "decisions").mkdir()
            (root / "sub").mkdir()
            (root / "decisions" / "d.md").write_text("# D\n", encoding="utf-8")
            (root / "index.md").write_text("# Site\n", encoding="utf-8")
            # One "../" reaches decisions/; two escapes the repo entirely.
            (root / "sub" / "page.md").write_text(
                "# Page\n\n- [ok](../decisions/d.md)\n- [escapes](../../decisions/d.md)\n",
                encoding="utf-8",
            )
            proc = subprocess.run(
                [str(renderer), str(root)],
                check=True,
                capture_output=True,
                text=True,
                env=os.environ.copy(),
            )
            html = (root / "_site" / "sub" / "page.html").read_text(encoding="utf-8")

        # The in-tree link still resolves.
        self.assertIn('href="../decisions/d.html"', html)
        # The escaping link is unlinked, not rewritten into a 404.
        self.assertNotIn('href="../../decisions/d.html"', html)
        self.assertIn("escapes", html)
        self.assertIn("unlinked 1 link(s)", proc.stderr)


if __name__ == "__main__":
    unittest.main()
