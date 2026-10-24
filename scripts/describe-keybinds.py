#!/usr/bin/env python3
"""Add descriptions to caelestia's Hyprland keybinds.

The keybind cheatsheet only lists binds that have a description, and
upstream's hypr/hyprland/keybinds.lua has none. This adds them from
keybind-descriptions.json (next to this script), matching each bind by its
action, so remapped keys still match. Binds that already have a
description, and binds the table doesn't know, are left untouched.

caelestia's CLI resets keybinds.lua on `caelestia update`, so this is safe to
re-run: a second run changes nothing.

Usage: describe-keybinds.py [--check] [--no-reload] [path/to/keybinds.lua]
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TABLE = Path(__file__).resolve().with_name("keybind-descriptions.json")
DEFAULT_TARGET = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "hypr/hyprland/keybinds.lua"

# Upstream's create_bind, and the same function with an optional description
# merged into a copy of the bind's flags (flag tables like `locked` are shared)
CREATE_BIND_OLD = """local function create_bind(keybinds, action, flags)
    local get_flags = type(flags) == "function" and flags or function()
        return flags
    end

    for _, key in ipairs(flatten_keybinds(keybinds)) do
        hl.bind(key, action, get_flags(key))
    end
end"""

CREATE_BIND_NEW = """-- description is optional; use "Category: Label" so the shell cheatsheet can
-- group binds (it lists `hyprctl binds -j` entries that have a description)
local function create_bind(keybinds, action, flags, description)
    local get_flags = type(flags) == "function" and flags or function()
        return flags
    end

    for _, key in ipairs(flatten_keybinds(keybinds)) do
        local key_flags = get_flags(key)
        if description then
            local merged = { description = description }
            for k, v in pairs(key_flags or {}) do
                merged[k] = v
            end
            key_flags = merged
        end
        hl.bind(key, action, key_flags)
    end
end"""


def calls(src, name):
    """Yield (args, close) for every `name(...)` call that isn't commented out.

    args is a list of (start, end) spans; close is the index of the closing
    paren. Commas only split at the call's own level: not inside strings,
    brackets or Lua blocks (function/if/do ... end).
    """
    i = 0
    while (i := src.find(name + "(", i)) != -1:
        line_start = src.rfind("\n", 0, i) + 1
        if (i > 0 and (src[i - 1].isalnum() or src[i - 1] in "_.")) or "--" in src[line_start:i]:
            i += 1
            continue
        j = i + len(name) + 1
        depth, blocks, args, start = 1, 0, [], j
        while depth:
            c = src[j]
            if src.startswith("[[", j):
                j = src.index("]]", j) + 2
                continue
            if c in "\"'":
                k = j + 1
                while src[k] != c:
                    k += 2 if src[k] == "\\" else 1
                j = k + 1
                continue
            if src.startswith("--", j):
                j = src.index("\n", j)
                continue
            if c.isalpha() or c == "_":
                k = j
                while k < len(src) and (src[k].isalnum() or src[k] == "_"):
                    k += 1
                word = src[j:k]
                if word in ("function", "if", "do"):
                    blocks += 1
                elif word == "end":
                    blocks -= 1
                j = k
                continue
            if c in "({[":
                depth += 1
            elif c in ")}]":
                depth -= 1
            elif c == "," and depth == 1 and blocks == 0:
                args.append((start, j))
                start = j + 1
            j += 1
        args.append((start, j - 1))
        yield args, j - 1
        i = j


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_desc(template):
    """Turn "Text {i}" into the Lua expression "Text " .. i"""
    parts = re.split(r"\{(\w+)\}", template)
    out = []
    for n, part in enumerate(parts):
        if n % 2:
            out.append(part)
        elif part:
            out.append(lua_str(part))
    return " .. ".join(out)


class Table:
    def __init__(self, path):
        self.binds = json.loads(path.read_text())["binds"]

    def lookup(self, action):
        action = norm(action)
        for b in self.binds:
            if "action" in b:
                cands = [b["action"]]
                if re.search(r"\bdir\b", b["action"]):
                    cands += [re.sub(r"\bdir\b", f'"{d}"', b["action"]) for d in ("left", "right", "up", "down")]
                if action in cands:
                    return b["description"]
            elif action == b["function"] or (action.startswith("function") and b["function"] in action):
                return b["description"]
        return None


def describe(src, table):
    """Return (new_src, added, already, unknown)."""
    edits = []  # (position, text to insert)
    added, already, unknown = 0, 0, []
    has_create_bind = CREATE_BIND_OLD in src or CREATE_BIND_NEW in src
    if CREATE_BIND_OLD in src:
        src = src.replace(CREATE_BIND_OLD, CREATE_BIND_NEW)

    if has_create_bind:
        for args, _ in calls(src, "create_bind"):
            text = [src[a:b] for a, b in args]
            if norm(text[0]) == "keybinds":  # the definition itself
                continue
            if len(text) >= 4:
                already += 1
                continue
            desc = table.lookup(text[1])
            if desc is None:
                unknown.append(norm(text[1])[:80])
                continue
            # Insert right after the last argument, matching the call's layout:
            # one argument per line stays one per line
            last_end = args[-1][1]
            while src[last_end - 1].isspace():
                last_end -= 1
            first = src[args[0][0] : args[0][1]]
            if first[: len(first) - len(first.lstrip())].count("\n"):
                arg_start = args[-1][0]
                while src[arg_start].isspace():
                    arg_start += 1
                indent = src[src.rfind("\n", 0, arg_start) + 1 : arg_start]
                sep = ",\n" + (indent if indent.strip() == "" else "    ")
            else:
                sep = ", "
            flags = "" if len(text) == 3 else "nil" + sep
            edits.append((last_end, sep + flags + lua_desc(desc)))
            added += 1

    for args, close in calls(src, "hl.bind"):
        text = [src[a:b] for a, b in args]
        if len(text) < 2 or norm(text[0]) == "key":  # create_bind's own hl.bind call
            continue
        if len(text) >= 3 and "description" in text[2]:
            already += 1
            continue
        desc = table.lookup(text[1])
        if desc is None:
            unknown.append(norm(text[1])[:80])
            continue
        if len(text) == 2:
            last_end = args[-1][1]
            while src[last_end - 1].isspace():
                last_end -= 1
            edits.append((last_end, ", { description = " + lua_desc(desc) + " }"))
        else:
            opts = text[2].strip()
            if not (opts.startswith("{") and opts.endswith("}")):
                unknown.append(norm(text[1])[:80] + " (flags not a table literal)")
                continue
            brace = src.index("{", args[2][0])
            inner = opts[1:-1].strip()
            edits.append((brace + 1, " description = " + lua_desc(desc) + ("," if inner else " ")))
        added += 1

    for pos, text in sorted(edits, reverse=True):
        src = src[:pos] + text + src[pos:]
    return src, added, already, unknown


def lua_syntax_ok(path):
    for luac in ("luac", "luac5.4", "luac5.3"):
        if shutil.which(luac):
            r = subprocess.run([luac, "-p", "-o", os.devnull, str(path)], capture_output=True, text=True)
            return r.returncode == 0, r.stderr.strip()
    if shutil.which("luajit"):
        r = subprocess.run(["luajit", "-bl", str(path)], capture_output=True, text=True)
        return r.returncode == 0, r.stderr.strip()
    return None, "no Lua compiler found (luac/luajit), skipped syntax check"


def described_count():
    r = subprocess.run(["hyprctl", "binds", "-j"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return sum(1 for b in json.loads(r.stdout) if b.get("has_description"))


def main():
    p = argparse.ArgumentParser(description="Add cheatsheet descriptions to caelestia's Hyprland keybinds.")
    p.add_argument("target", nargs="?", type=Path, default=DEFAULT_TARGET)
    p.add_argument("--check", action="store_true", help="show what would change, write nothing")
    p.add_argument("--no-reload", action="store_true", help="don't run `hyprctl reload` afterwards")
    p.add_argument("--table", type=Path, default=TABLE)
    a = p.parse_args()

    target = a.target.expanduser().resolve()  # follow the CLI's symlink to the real file
    if not target.is_file():
        sys.exit(f"error: {target} not found")

    src = target.read_text()
    new, added, already, unknown = describe(src, Table(a.table))

    print(f"{target}")
    print(f"  {added} to describe, {already} already described, {len(unknown)} not in the table")
    for u in unknown:
        print(f"    skipped: {u}")
    if new == src:
        print("  nothing to change")
        return
    if a.check:
        print("  --check: no changes written")
        return

    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as tmp:
        tmp.write(new)
    ok, err = lua_syntax_ok(Path(tmp.name))
    if ok is False:
        os.unlink(tmp.name)
        sys.exit(f"error: result is not valid Lua, nothing written\n{err}")
    if ok is None:
        print(f"  warning: {err}")

    backup = target.with_name(target.name + ".xtend-bak")
    shutil.copy2(target, backup)
    shutil.copymode(target, tmp.name)
    os.replace(tmp.name, target)
    print(f"  written (backup: {backup})")

    if a.no_reload or not shutil.which("hyprctl"):
        return
    before = described_count()
    subprocess.run(["hyprctl", "reload"], capture_output=True)
    after = described_count()
    if after is None or (before is not None and after < before):
        shutil.copy2(backup, target)
        subprocess.run(["hyprctl", "reload"], capture_output=True)
        sys.exit("error: Hyprland didn't pick up the change, restored the backup")
    print(f"  reloaded Hyprland: {after} binds now have descriptions")


if __name__ == "__main__":
    main()
