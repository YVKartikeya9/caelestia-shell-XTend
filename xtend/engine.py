"""Anchored, reversible edits to caelestia's shell files.

Every edit is tied to an exact piece of upstream text (an anchor), so it is
applied only if that text exists exactly once, and can be removed again
without touching anything else. Inserted lines carry an `xtend:<feature>`
marker comment so they're easy to spot in the edited files.

Edits from different features never overlap: each one inserts next to
unchanged upstream text, or replaces text only that one feature touches.
That's what lets any combination of features be installed in any order.
"""

from dataclasses import dataclass


def candidates(file):
    """An edit's file is one path, or a tuple of paths when upstream has moved
    the file between versions (oldest location first)."""
    return (file,) if isinstance(file, str) else tuple(file)


def locate(root, file):
    """The path an edit applies to under `root`: the first candidate that exists."""
    paths = candidates(file)
    return next((p for p in paths if (root / p).is_file()), paths[0])


def _indent(text):
    for line in text.splitlines():
        if line.strip():
            return line[: len(line) - len(line.lstrip())]
    return ""


def mark(feature, text):
    """Wrap inserted text with xtend markers (a trailing comment for one line)."""
    text = text.rstrip("\n")
    if "\n" not in text:
        return f"{text} // xtend:{feature}"
    ind = _indent(text)
    return f"{ind}// xtend:{feature}\n{text}\n{ind}// xtend:{feature} end"


def mark_inline(feature, text):
    """Markers for text inserted mid-line (e.g. list items): block comments,
    so whatever follows on the same line (like a comma) stays code."""
    text = text.rstrip("\n")
    return f"{_indent(text)}/* xtend:{feature} */\n{text} /* xtend:{feature} end */"


@dataclass
class Insert:
    """Insert `text` on new lines after (or before) the line(s) in `anchor`.

    With `inline`, the text goes directly after the anchor with no newline in
    between, prefixed by `prefix` (e.g. a list separator).
    """

    file: "str | tuple"  # see candidates()
    anchor: str
    text: str
    where: str = "after"
    inline: bool = False
    prefix: str = ""

    def _insertion(self, feature):
        if self.inline:
            return self.prefix + "\n" + mark_inline(feature, self.text)
        body = mark(feature, self.text)
        return "\n" + body if self.where == "after" else body + "\n"

    def applied(self, src, feature):
        return self._insertion(feature) in src

    def problem(self, src, feature):
        if self.applied(src, feature):
            return None
        n = src.count(self.anchor)
        return None if n == 1 else f"anchor found {n} times (expected 1): {self.anchor.strip()[:70]!r}"

    def apply(self, src, feature):
        if self.applied(src, feature):
            return src
        i = src.index(self.anchor)
        pos = i + len(self.anchor) if self.where == "after" else i
        return src[:pos] + self._insertion(feature) + src[pos:]

    def remove(self, src, feature):
        return src.replace(self._insertion(feature), "", 1)


@dataclass
class Replace:
    """Replace text that only this feature edits. `new` should carry a marker.

    If other features insert lines inside `new` (a hook), set `marker` to a
    string unique to `new`, so the edit still counts as applied after that.
    """

    file: "str | tuple"  # see candidates()
    old: str
    new: str
    marker: str = ""

    def applied(self, src, feature):
        return (self.marker or self.new) in src

    def problem(self, src, feature):
        if self.applied(src, feature):
            return None
        n = src.count(self.old)
        return None if n == 1 else f"text found {n} times (expected 1): {self.old.strip()[:70]!r}"

    def apply(self, src, feature):
        return src if self.applied(src, feature) else src.replace(self.old, self.new, 1)

    def remove(self, src, feature):
        return src.replace(self.new, self.old, 1)


def preflight(root, feature, ops):
    """Return a list of problems that would stop `feature`'s edits applying."""
    problems = []
    for op in ops:
        rel = locate(root, op.file)
        path = root / rel
        if not path.is_file():
            problems.append(f"{' or '.join(candidates(op.file))}: file not found")
            continue
        if p := op.problem(path.read_text(), feature):
            problems.append(f"{rel}: {p}")
    return problems


def _rewrite(root, feature, ops, method):
    changed = set()
    for op in ops:
        rel = locate(root, op.file)
        path = root / rel
        src = path.read_text()
        new = getattr(op, method)(src, feature)
        if new != src:
            path.write_text(new)
            changed.add(rel)
    return changed


def apply(root, feature, ops):
    return _rewrite(root, feature, ops, "apply")


def remove(root, feature, ops):
    # Reverse order, so an edit made on top of another one is undone first
    return _rewrite(root, feature, list(reversed(ops)), "remove")
