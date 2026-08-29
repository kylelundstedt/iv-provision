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

    def _render(self, root, *args):
        renderer = Path(__file__).resolve().parents[1] / "bin" / "render-md-site"
        return subprocess.run(
            [str(renderer), str(root), *args],
            check=True,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
        )

    def test_root_readme_becomes_the_landing_page(self):
        """A repo with a README and no index.md should open on the README.

        Before this, the site root was a <meta refresh> stub pointing at
        whatever sorted first -- for fannie-sflpd-poc that was
        control/schemas/, so the site opened on a schema reference. Links to
        README.md must follow it to index.html, since that is what nested docs
        use to point home.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "spec").mkdir()
            (root / "README.md").write_text(
                "# My Project\n\nIntro prose.\n", encoding="utf-8"
            )
            (root / "spec" / "thing.md").write_text(
                "# Thing\n\nHome: [readme](../README.md)\n", encoding="utf-8"
            )
            proc = self._render(root)
            index = (root / "_site" / "index.html").read_text(encoding="utf-8")
            thing = (root / "_site" / "spec" / "thing.html").read_text(encoding="utf-8")
            has_readme_html = (root / "_site" / "README.html").exists()

        self.assertIn("using README.md as the landing page", proc.stdout)
        # Real content, not a redirect stub.
        self.assertIn("Intro prose", index)
        self.assertNotIn('http-equiv="refresh"', index)
        # One landing page, not two near-duplicates.
        self.assertFalse(has_readme_html)
        # A link to README.md follows it to index.html.
        self.assertIn('href="../index.html"', thing)

    def test_readme_fallback_yields_to_explicit_intent(self):
        """index.md wins; --exclude opts out; --include means exactly these."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "README.md").write_text("# Readme Title\n", encoding="utf-8")
            (root / "doc.md").write_text("# Doc\n", encoding="utf-8")

            # 1. An authored index.md beats the README.
            (root / "index.md").write_text("# Index Title\n", encoding="utf-8")
            proc = self._render(root)
            self.assertNotIn("using README.md", proc.stdout)
            self.assertIn(
                "Index Title", (root / "_site" / "index.html").read_text("utf-8")
            )
            (root / "index.md").unlink()

            # 2. An explicit --exclude opts out entirely.
            proc = self._render(root, "--exclude", "README.md")
            self.assertNotIn("using README.md", proc.stdout)
            self.assertNotIn(
                "Readme Title", (root / "_site" / "index.html").read_text("utf-8")
            )

            # 3. An --include that NAMES the README asks for it at its own path.
            proc = self._render(root, "--include", "README.md", "--include", "doc.md")
            self.assertNotIn("using README.md", proc.stdout)
            self.assertTrue((root / "_site" / "README.html").exists())

    def test_glob_include_does_not_forfeit_the_landing_page(self):
        """A glob that sweeps the README in is not a request to relocate it.

        --include first suppressed promotion outright, on the reasoning that
        "render exactly these" states complete intent. But callers reach for
        --include to re-admit files the defaults drop -- fannie-sflpd-poc
        re-including three nested READMEs that are real pages -- and that cost
        them their landing page: `--include '**/*.md'`, a no-op restatement of
        the default, turned the site root back into a redirect stub AND emitted
        a duplicate README.html.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "sub").mkdir()
            (root / "README.md").write_text("# Root Readme\n", encoding="utf-8")
            (root / "sub" / "README.md").write_text("# Nested\n", encoding="utf-8")
            (root / "sub" / "p.md").write_text("# P\n", encoding="utf-8")
            proc = self._render(
                root, "--include", "**/*.md", "--include", "sub/README.md"
            )
            site = root / "_site"
            index = (site / "index.html").read_text(encoding="utf-8")
            pages = sorted(p.relative_to(site).as_posix() for p in site.rglob("*.html"))

        self.assertIn("using README.md as the landing page", proc.stdout)
        self.assertIn("Root Readme", index)
        self.assertNotIn('http-equiv="refresh"', index)
        # Promoted once -- not also emitted at its own path.
        self.assertEqual(pages, ["index.html", "sub/README.html", "sub/p.html"])

    def test_unpromoted_readme_links_are_not_redirected_to_index(self):
        """The README->index redirect must only apply when promotion happened.

        Regression: the redirect was gated on "README.html was not rendered",
        which is also true when a repo HAS an index.qmd and its README stays
        excluded as repo hygiene. ave-adapters is exactly that shape, and its
        index page's link to README.md became a link to itself.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "README.md").write_text("# Guide\n", encoding="utf-8")
            (root / "index.md").write_text(
                "# Site\n\n- [guide](README.md)\n", encoding="utf-8"
            )
            self._render(root)
            index = (root / "_site" / "index.html").read_text(encoding="utf-8")
        # Compare the <main> body only: the sidebar legitimately links to
        # index.html on every page, including this one.
        body = index.split("<main>")[1].split("</main>")[0]

        # The README was never rendered, so the link is dropped -- not pointed
        # at index.html, which is the page doing the linking.
        self.assertNotIn("href=", body)
        self.assertIn("guide", body)

    def test_nested_readmes_stay_out_of_the_site(self):
        """Only the ROOT README is promoted; sub/README.md is a directory note."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "sub").mkdir()
            (root / "README.md").write_text("# Root\n", encoding="utf-8")
            (root / "sub" / "README.md").write_text("# Nested\n", encoding="utf-8")
            (root / "sub" / "p.md").write_text("# P\n", encoding="utf-8")
            self._render(root)
            pages = sorted(
                p.relative_to(root / "_site").as_posix()
                for p in (root / "_site").rglob("*.html")
            )
        self.assertEqual(pages, ["index.html", "sub/p.html"])


if __name__ == "__main__":
    unittest.main()
