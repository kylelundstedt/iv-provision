#!/usr/bin/env python3
"""sitediff.py <quarto_site> <apex_site> — compare rendered CONTENT, not filenames.

Filename parity is a weak test: a renderer that silently drops a section still
passes it. This extracts the article body from each page, normalises it to
plain text, and diffs word-by-word — so a lost paragraph, table row or code
block shows up.

Also compares structural inventories (headings, tables, code blocks, links,
images), because prose can match while structure is mangled — exactly the
failure where apex's relaxed-table default turned <th> into <td> while the
words stayed identical.
"""
import difflib
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

SKIP_TAGS = {"script", "style", "nav", "aside", "header", "footer"}

# Typography is a KNOWN, intentional difference, not a regression: Quarto/pandoc
# curl quotes and collapse "..." to an ellipsis; apex's gfm mode leaves them
# straight. Comparing raw text made every page differ by ~3.6%, which would bury
# a genuine dropped paragraph in noise. Normalise both sides so what remains is
# real.
TYPO = str.maketrans({"\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"'})


def normalise(t: str) -> str:
    return t.translate(TYPO).replace("\u2026", "...")


class Extract(HTMLParser):
    """Text + structure from the main content region, ignoring site chrome."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.depth_skip = 0
        self.in_main = False
        self.main_depth = 0
        self.depth = 0
        self.counts = {"h": 0, "table": 0, "th": 0, "tr": 0, "pre": 0, "a": 0, "img": 0, "li": 0}
        self.headings: list[str] = []
        self._grab_heading = False
        self._heading_buf: list[str] = []

    def handle_starttag(self, tag, attrs):
        self.depth += 1
        a = dict(attrs)
        # Quarto: <main class="content" id="quarto-document-content">
        # apex:   <main>
        if tag == "main" and not self.in_main:
            self.in_main = True
            self.main_depth = self.depth
            return
        if tag in SKIP_TAGS:
            self.depth_skip += 1
            return
        if not self.in_main or self.depth_skip:
            return
        if tag in ("h1", "h2", "h3", "h4"):
            self.counts["h"] += 1
            self._grab_heading = True
            self._heading_buf = []
        for k in ("table", "th", "tr", "pre", "a", "img", "li"):
            if tag == k:
                self.counts[k] += 1

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS and self.depth_skip:
            self.depth_skip -= 1
        if tag in ("h1", "h2", "h3", "h4") and self._grab_heading:
            self.headings.append(normalise(" ".join("".join(self._heading_buf).split())))
            self._grab_heading = False
        if tag == "main" and self.in_main and self.depth == self.main_depth:
            self.in_main = False
        self.depth -= 1

    def handle_data(self, data):
        if self.in_main and not self.depth_skip:
            self.parts.append(data)
            if self._grab_heading:
                self._heading_buf.append(data)

    def text(self) -> str:
        return normalise(" ".join("".join(self.parts).split()))


def parse(path: Path) -> Extract:
    e = Extract()
    e.feed(path.read_text(encoding="utf-8", errors="replace"))
    return e


def main() -> int:
    a_root, b_root = Path(sys.argv[1]), Path(sys.argv[2])
    a_pages = {p.relative_to(a_root).as_posix() for p in a_root.rglob("*.html")}
    b_pages = {p.relative_to(b_root).as_posix() for p in b_root.rglob("*.html")}

    only_a, only_b = sorted(a_pages - b_pages), sorted(b_pages - a_pages)
    if only_a:
        print(f"ONLY IN {a_root.name}: {', '.join(only_a)}")
    if only_b:
        print(f"ONLY IN {b_root.name}: {', '.join(only_b)}")

    worst = 0.0
    for rel in sorted(a_pages & b_pages):
        A, B = parse(a_root / rel), parse(b_root / rel)
        ta, tb = A.text(), B.text()
        ratio = difflib.SequenceMatcher(None, ta.split(), tb.split()).ratio()
        worst = max(worst, 1 - ratio)
        struct = []
        for k in ("h", "table", "th", "tr", "pre", "a", "img", "li"):
            if A.counts[k] != B.counts[k]:
                struct.append(f"{k}:{A.counts[k]}->{B.counts[k]}")
        hd = ""
        if A.headings != B.headings:
            miss = [h for h in A.headings if h not in B.headings]
            extra = [h for h in B.headings if h not in A.headings]
            hd = f"  headings missing={miss[:3]} extra={extra[:3]}"
        flag = "OK " if ratio > 0.995 and not struct and not hd else "DIFF"
        print(f"{flag} {rel:<44} text={ratio:.4f} {' '.join(struct)}{hd}")
        if ratio <= 0.995:
            sm = difflib.SequenceMatcher(None, ta.split(), tb.split())
            for op, i1, i2, j1, j2 in sm.get_opcodes():
                if op == "equal":
                    continue
                if op in ("delete", "replace"):
                    print(f"      -{' '.join(ta.split()[i1:i2])[:160]}")
                if op in ("insert", "replace"):
                    print(f"      +{' '.join(tb.split()[j1:j2])[:160]}")
    print(f"\nworst text divergence: {worst:.4%}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
