#!/usr/bin/env python3
"""Checks the installer's edits against a clean caelestia shell.

    python3 tests/test_edits.py [--base REF]   (default REF: v2.5.0)
    python3 tests/test_edits.py --base origin/main   (upstream's latest code)

The base tree is exported from this git repo, so run it from a clone. Checks:

1. every combination of features installs (all anchors found) and produces
   valid QML (qmlformat, if installed)
2. installing twice changes nothing
3. removing everything restores the base byte for byte
4. removing one feature gives exactly what installing the others gives
5. any install order, removed in a different order, ends at the base
6. this branch's edited files equal "base + all features" (only with v2.5.0)
"""

import argparse
import itertools
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from xtend import engine  # noqa: E402
from xtend.features import BY_NAME, FEATURES, resolve  # noqa: E402

VISIBLE = [f.name for f in FEATURES if not f.hidden]
EDITED = []  # the files the features edit in the base being tested; set in main()
def find_qmlformat():
    # Must be Qt 6's: Qt 5's qmlformat rejects Qt 6 syntax like typed functions
    for p in ("/usr/lib/qt6/bin/qmlformat", "qmlformat6", "qmlformat"):
        if shutil.which(p):
            out = subprocess.run([p, "--version"], capture_output=True, text=True).stdout
            if any(f" {v}." in f" {out}" for v in ("6", "7")):
                return p
    return None


QMLFORMAT = find_qmlformat()


class Tree:
    """A scratch copy of the base, with features added and removed like the installer does."""

    def __init__(self, base, work):
        self.base, self.work, self.installed = base, work, []
        if work.exists():
            shutil.rmtree(work)
        shutil.copytree(base, work)

    def add(self, name):
        for f in resolve([name]):
            if f.name in self.installed:
                continue
            problems = engine.preflight(self.work, f.name, f.ops)
            assert not problems, f"{f.name}: {problems}"
            for rel in f.files:
                (self.work / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPO / rel, self.work / rel)
            engine.apply(self.work, f.name, f.ops)
            self.installed.append(f.name)

    def drop(self, name):
        others = [n for n in self.installed if n != name and not BY_NAME[n].hidden]
        keep = {f.name for f in resolve(others)}
        for f in reversed(resolve([name])):
            if f.name in keep or f.name not in self.installed:
                continue
            engine.remove(self.work, f.name, f.ops)
            for rel in f.files:
                (self.work / rel).unlink()
            self.installed.remove(f.name)

    def edited(self):
        return {p: (self.work / p).read_text() for p in EDITED}

    def is_base(self):
        return all((self.work / p).read_text() == (self.base / p).read_text() for p in EDITED)

    def syntax_errors(self):
        if not QMLFORMAT:
            return []
        return [p for p in EDITED
                if subprocess.run([QMLFORMAT, str(self.work / p)], capture_output=True).returncode != 0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="v2.5.0", help="upstream git ref to test against")
    args = ap.parse_args()

    tmp = Path(tempfile.mkdtemp(prefix="xtend-test-"))
    base, work = tmp / "base", tmp / "work"
    base.mkdir()
    archive = subprocess.run(["git", "-C", str(REPO), "archive", args.base], capture_output=True, check=True)
    subprocess.run(["tar", "-x", "-C", str(base)], input=archive.stdout, check=True)
    # Where each edit lands in this base (upstream has moved some files)
    EDITED[:] = sorted({engine.locate(base, op.file) for f in FEATURES for op in f.ops})

    fails = []

    def check(cond, msg):
        if not cond:
            fails.append(msg)
            print("FAIL", msg)

    if not QMLFORMAT:
        print("note: qmlformat not found, skipping QML syntax checks")

    combos = [c for k in range(len(VISIBLE) + 1) for c in itertools.combinations(VISIBLE, k)]
    for combo in combos:
        t = Tree(base, work)
        for n in combo:
            t.add(n)
        once = t.edited()
        check(not t.syntax_errors(), f"invalid QML with {combo}: {t.syntax_errors()}")
        t2 = Tree(base, work)
        for n in combo:
            t2.add(n)
        for n in combo:  # adding again must be a no-op
            for f in resolve([n]):
                engine.apply(t2.work, f.name, f.ops)
        check(t2.edited() == once, f"not idempotent: {combo}")
        for n in combo:
            t2.drop(n)
        check(t2.is_base(), f"removing {combo} doesn't restore the base")
        for gone in combo:
            rest = [c for c in combo if c != gone]
            a = Tree(base, work)
            for n in rest:
                a.add(n)
            want = a.edited()
            b = Tree(base, work)
            for n in combo:
                b.add(n)
            b.drop(gone)
            check(b.edited() == want, f"removing {gone} from {combo} differs from installing {rest}")
    print(f"combinations: {len(combos)}")

    orders = list(itertools.permutations(VISIBLE))
    for order in orders:
        t = Tree(base, work)
        for n in order:
            t.add(n)
        for n in reversed(order[1:] + order[:1]):
            t.drop(n)
        check(t.is_base() and not t.installed, f"install order {order} doesn't uninstall cleanly")
    print(f"install orders: {len(orders)}")

    # The branch itself is "v2.5.0 + every feature"; other bases only test the edits
    if args.base == "v2.5.0":
        t = Tree(base, work)
        for n in VISIBLE:
            t.add(n)
        stale = [p for p in EDITED if (REPO / p).read_text() != (t.work / p).read_text()]
        check(not stale, f"branch files differ from base + all features: {stale} "
                         "(regenerate them from the installer's output)")

    shutil.rmtree(tmp)
    print(f"\n{'OK' if not fails else f'{len(fails)} FAILED'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
