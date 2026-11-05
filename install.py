#!/usr/bin/env python3
"""caelestia-XTend installer: add XTend features to an existing caelestia shell.

    ./install.py                    pick features interactively
    ./install.py --features cheatsheet,filesearch --noconfirm
    ./install.py --check            show what would happen, change nothing
    ./install.py --remove hotspot   remove one feature
    ./install.py --uninstall        remove everything XTend added
    ./install.py --update           re-apply after a caelestia-shell update

Edits to caelestia's own files are anchored to exact upstream lines and marked
with `xtend:<feature>` comments, so features install and uninstall in any
order (see xtend/engine.py). Nothing is changed before you confirm.
"""

import argparse
import datetime
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO))

from xtend import engine  # noqa: E402
from xtend.features import BY_NAME, FEATURES, resolve  # noqa: E402

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state")
USER_SHELL = CONFIG / "quickshell/caelestia"
SYSTEM_SHELL = Path("/etc/xdg/quickshell/caelestia")
STATE_FILE = CONFIG / "caelestia/xtend.json"
ENV_FILE = CONFIG / "caelestia/.env"
BACKUPS = STATE_HOME / "caelestia/xtend-backups"
TESTED_VERSIONS = {"2.5.0"}

BIND_MARK_BEGIN = "xtend:begin (managed by caelestia-XTend install.py, edits here are overwritten)"
BIND_MARK_END = "xtend:end"
CHEATSHEET_BIND = ("SUPER + Slash", "SUPER", "slash", "Launcher: Toggle keybind cheatsheet")
HOTSPOT_BIND = ("SUPER + ALT + H", "SUPER ALT", "h", "Utilities: Toggle Wi-Fi hotspot")

NOCONFIRM = False


# --- Output helpers ---------------------------------------------------------

def say(msg=""):
    print(msg, flush=True)


def head(msg):
    say(f"\n\033[1;36m::\033[0m \033[1m{msg}\033[0m")


def warn(msg):
    say(f"\033[33m   ! {msg}\033[0m")


def ok(msg):
    say(f"\033[32m   ✓\033[0m {msg}")


def ask(question, default=True):
    if NOCONFIRM:
        return default
    hint = "Y/n" if default else "y/N"
    while True:
        a = input(f"   {question} [{hint}] ").strip().lower()
        if not a:
            return default
        if a in ("y", "yes", "n", "no"):
            return a.startswith("y")


def run(cmd, check=False, capture=True, **kw):
    return subprocess.run(cmd, check=check, capture_output=capture, text=True, **kw)


def have(cmd):
    return shutil.which(cmd) is not None


# --- Detection --------------------------------------------------------------

def caelestia_version():
    tool = Path("/usr/lib/caelestia/version")
    if tool.exists():
        lines = run([str(tool), "-t"]).stdout.split()
        if len(lines) >= 2:
            return lines[1]
    out = run(["pacman", "-Q", "caelestia-shell"]).stdout.split()
    return out[1].split("-")[0] if len(out) >= 2 else None


def detect_hypr():
    """Return (kind, keybinds_file, user_file) for the user's Hyprland setup.

    kind is "caelestia" (caelestia's dotfiles), "lua" (own Lua config), "conf"
    (own hyprlang config) or None.
    """
    hypr = CONFIG / "hypr"
    kb = hypr / "hyprland/keybinds.lua"

    def has(path, text):
        return path.exists() and text in path.read_text(errors="ignore")

    # caelestia's hyprland.lua loads ~/.config/caelestia/hypr-user.lua; that
    # line stays even when someone rewrites keybinds.lua without create_bind
    if has(hypr / "hyprland.lua", 'require("hypr-user")') or has(kb, "create_bind"):
        return "caelestia", kb if kb.exists() else hypr / "hyprland.lua", CONFIG / "caelestia/hypr-user.lua"
    if (hypr / "hyprland.lua").exists():
        return "lua", hypr / "hyprland.lua", hypr / "xtend.lua"
    if (hypr / "hyprland.conf").exists():
        return "conf", hypr / "hyprland.conf", hypr / "xtend.conf"
    return None, None, None


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {"features": []}


def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


# --- Shell files ------------------------------------------------------------

def ensure_user_shell(state, dry):
    """XTend edits a user copy of the shell; make one from the package if needed."""
    if (USER_SHELL / "shell.qml").exists():
        return True
    if not (SYSTEM_SHELL / "shell.qml").exists():
        warn(f"No caelestia shell found in {USER_SHELL} or {SYSTEM_SHELL}. Install caelestia-shell first.")
        return False
    say(f"   Your shell runs from the package copy ({SYSTEM_SHELL}), which updates")
    say(f"   overwrite. XTend needs an editable copy in {USER_SHELL}.")
    say("   After caelestia-shell updates, run ./install.py --update to refresh it.")
    if dry:
        return True
    if not ask("Create that copy now?"):
        return False
    shutil.copytree(SYSTEM_SHELL, USER_SHELL, symlinks=True)
    state["copied_from_system"] = True
    state["_created_copy"] = True
    ok(f"copied {SYSTEM_SHELL} → {USER_SHELL}")
    return True


def backup_shell():
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = BACKUPS / stamp
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(USER_SHELL, dest, symlinks=True)
    ok(f"backed up the shell to {dest}")
    return str(dest)


def add_feature(f):
    for rel in f.files:
        dst = USER_SHELL / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / rel, dst)
    engine.apply(USER_SHELL, f.name, f.ops)


def drop_feature(f):
    engine.remove(USER_SHELL, f.name, f.ops)
    for rel in f.files:
        p = USER_SHELL / rel
        if p.exists():
            p.unlink()
        try:
            p.parent.rmdir()  # only removes now-empty feature folders
        except OSError:
            pass


# --- System setup -----------------------------------------------------------

def missing_packages(pkgs):
    # pacman -T prints the ones nothing installed satisfies, so a package that
    # *provides* one counts as installed (iptables-nft provides iptables)
    if not pkgs:
        return []
    unmet = set(run(["pacman", "-T", *pkgs]).stdout.split())
    return [p for p in pkgs if p in unmet]


def install_packages(repo, aur, dry):
    repo, aur = missing_packages(repo), missing_packages(aur)
    if not repo and not aur:
        return True
    if dry:
        say(f"   would install: {' '.join(repo + aur)}")
        return True
    nc = ["--noconfirm"] if NOCONFIRM else []
    if repo:
        say(f"   installing {' '.join(repo)} (pacman will ask for your password)")
        if run(["sudo", "pacman", "-S", "--needed", *nc, *repo], capture=False).returncode != 0:
            warn("pacman failed")
            return False
    if aur:
        helper = next((h for h in ("paru", "yay") if have(h)), None)
        if not helper:
            warn(f"no AUR helper (paru/yay) found; install these yourself: {' '.join(aur)}")
            return False
        if run([helper, "-S", "--needed", *nc, *aur], capture=False).returncode != 0:
            warn(f"{helper} failed for {' '.join(aur)}")
            return False
    return True


def setup_plocate(dry):
    # Arch's plocate ships its timer statically enabled; only enable it where
    # it isn't, and build the index once if it doesn't exist yet
    timer = run(["systemctl", "is-enabled", "plocate-updatedb.timer"]).stdout.strip()
    db = Path("/var/lib/plocate/plocate.db")
    need_timer = timer not in ("enabled", "static")
    if not need_timer and db.exists():
        return
    if dry:
        say("   would " + ("enable the daily file index and " if need_timer else "") + "build the file index once")
        return
    if need_timer:
        say("   enabling the daily file index (plocate-updatedb.timer)")
        run(["sudo", "systemctl", "enable", "--now", "plocate-updatedb.timer"], capture=False)
    if not db.exists():
        say("   building the file index once (sudo updatedb)")
        run(["sudo", "updatedb"], capture=False)


def env_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")


def env_get(text, key):
    m = re.search(rf'^{key}="((?:[^"\\]|\\.)*)"\s*$', text, re.M)
    return re.sub(r"\\(.)", r"\1", m.group(1)) if m else None


def env_set(text, key, value):
    line = f'{key}="{env_escape(value)}"'
    pat = re.compile(rf'^{key}="(?:[^"\\]|\\.)*"\s*$', re.M)
    if pat.search(text):
        return pat.sub(lambda _: line, text, count=1)
    return text + ("" if not text or text.endswith("\n") else "\n") + line + "\n"


def setup_env(names, dry):
    text = ENV_FILE.read_text() if ENV_FILE.exists() else "# caelestia secrets and settings (bash double-quote escaping)\n"
    new = text
    if "hotspot" in names:
        if not env_get(new, "HOTSPOT_SSID"):
            ssid = "caelestia" if NOCONFIRM else (input("   Hotspot name (SSID) [caelestia]: ").strip() or "caelestia")
            new = env_set(new, "HOTSPOT_SSID", ssid)
        if not env_get(new, "HOTSPOT_PASS"):
            if NOCONFIRM:
                warn("no HOTSPOT_PASS set; add it to ~/.config/caelestia/.env (8-63 characters) before using the hotspot")
            else:
                while True:
                    pw = getpass.getpass("   Hotspot password (8-63 characters, hidden): ")
                    if 8 <= len(pw) <= 63:
                        break
                    warn("must be 8-63 characters")
                new = env_set(new, "HOTSPOT_PASS", pw)
    if "google" in names and not env_get(new, "EXA_API_KEY") and not NOCONFIRM:
        key = getpass.getpass("   Exa API key for the AI preview (optional, Enter to skip, hidden): ").strip()
        if key:
            new = env_set(new, "EXA_API_KEY", key)
    if new == text or dry:
        return
    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(ENV_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(new)
    os.chmod(ENV_FILE, 0o600)
    ok(f"saved settings to {ENV_FILE} (readable only by you)")


# --- Keybinds ---------------------------------------------------------------

def hypr_binds():
    r = run(["hyprctl", "binds", "-j"])
    try:
        return json.loads(r.stdout) if r.returncode == 0 else None
    except ValueError:
        return None


MODS = {"SHIFT": 1, "CAPS": 2, "CTRL": 4, "CONTROL": 4, "ALT": 8, "MOD2": 16, "MOD3": 32, "SUPER": 64, "MOD5": 128}


def existing_bind(binds, mods, key):
    mask = sum(MODS[m] for m in mods.split())
    for b in binds or []:
        if b.get("modmask") == mask and b.get("key", "").lower() == key.lower():
            return b
    return None


def bind_lines(kind, wanted):
    """Keybind lines for the user's config format."""
    out = []
    for combo, mods, key, desc, action in wanted:
        if kind == "conf":
            if action[0] == "global":
                out.append(f"bindd = {mods}, {key}, {desc}, global, {action[1]}")
            else:
                out.append(f"bindd = {mods}, {key}, {desc}, exec, {action[1]}")
        else:
            if action[0] == "global":
                out.append(f'hl.bind("{combo}", hl.dsp.global("{action[1]}"), {{ description = "{desc}" }})')
            else:
                out.append(f'hl.bind("{combo}", hl.dsp.exec_cmd("{action[1]}"), {{ description = "{desc}" }})')
    return out


def write_bind_block(path, kind, lines):
    """Replace (or remove, if lines is empty) the xtend block in `path`."""
    c = "#" if kind == "conf" else "--"
    text = path.read_text() if path.exists() else ""
    block = "\n".join([f"{c} {BIND_MARK_BEGIN}", *lines, f"{c} {BIND_MARK_END}"]) + "\n"
    pat = re.compile(rf"^{re.escape(c)} xtend:begin.*?^{re.escape(c)} {BIND_MARK_END}\n?", re.M | re.S)
    if pat.search(text):
        new = pat.sub(lambda _: block if lines else "", text, count=1)
    elif lines:
        new = text + ("" if not text or text.endswith("\n") else "\n") + block
    else:
        return False
    if new != text:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(new)
        return True
    return False


def hook_user_file(kind, main_cfg, user_file):
    """For own configs, load our separate file from the main config (once)."""
    if kind == "lua":
        line = f'dofile(os.getenv("HOME") .. "/.config/hypr/{user_file.name}") -- xtend'
    elif kind == "conf":
        line = f"source = ~/.config/hypr/{user_file.name} # xtend"
    else:
        return False  # caelestia's dotfiles already load hypr-user.lua
    text = main_cfg.read_text()
    if line in text:
        return False
    main_cfg.write_text(text + ("" if text.endswith("\n") else "\n") + line + "\n")
    return True


def unhook_user_file(kind, main_cfg):
    if kind not in ("lua", "conf") or not main_cfg.exists():
        return
    text = main_cfg.read_text()
    new = "".join(l for l in text.splitlines(True) if not (l.rstrip().endswith("-- xtend") or l.rstrip().endswith("# xtend")))
    if new != text:
        main_cfg.write_text(new)
    own = main_cfg.parent / ("xtend.lua" if kind == "lua" else "xtend.conf")
    if own.exists() and not own.read_text().strip():
        own.unlink()


def setup_keybinds(names, dry, state):
    kind, main_cfg, user_file = detect_hypr()
    if not kind:
        warn("couldn't find your Hyprland config; add keybinds yourself (see README)")
        return
    wanted = []
    if "cheatsheet" in names:
        combo, mods, key, desc = CHEATSHEET_BIND
        wanted.append((combo, mods, key, desc, ("global", "caelestia:cheatsheet")))
    if "hotspot" in names and "hotspot_bind" not in state and not dry:
        state["hotspot_bind"] = ask("Add a hotspot toggle keybind (Super + Alt + H)?", default=False)
    if "hotspot" in names and state.get("hotspot_bind"):
        combo, mods, key, desc = HOTSPOT_BIND
        wanted.append((combo, mods, key, desc, ("exec", f"bash {USER_SHELL}/assets/hotspot-toggle.sh")))

    # Lua binds show up in hyprctl only as "__lua <id>", so what a bind does
    # can't be read back. Ownership comes from our own block and descriptions.
    text = user_file.read_text() if user_file.exists() else ""
    m = re.search(r"xtend:begin.*?xtend:end", text, re.S)
    ours = m.group(0) if m else ""
    binds = hypr_binds()
    final = []
    for w in wanted:
        combo, mods, key, desc, action = w
        b = existing_bind(binds, mods, key)
        topic = "cheatsheet" if "cheatsheet" in action[1] else "hotspot"
        if not b or f'"{combo}"' in ours or f"{mods}, {key}," in ours:
            final.append(w)
        elif topic in (b.get("description", "") + b.get("arg", "")).lower():
            say(f"   {combo} already does this in your config ({b.get('description') or b.get('arg')}), leaving it as is")
        else:
            warn(f"{combo} is already bound to \"{b.get('description') or b.get('dispatcher') + ' ' + b.get('arg', '')}\"; not adding it")

    where = f"{user_file}" + ("" if kind == "caelestia" else f" (loaded from {main_cfg.name})")
    if dry:
        for w in final:
            say(f"   would bind {w[0]} → {w[3]} in {where}")
        return
    changed = write_bind_block(user_file, kind, bind_lines(kind, final))
    if final:
        hook_user_file(kind, main_cfg, user_file)
    if changed:
        ok(f"keybinds updated in {where}")
        if have("hyprctl"):
            run(["hyprctl", "reload"])
            errs = run(["hyprctl", "configerrors"]).stdout.strip()
            if errs and "no errors" not in errs.lower():
                warn(f"Hyprland reports config errors after reload:\n{errs}")


def describe_keybinds(dry):
    kind, main_cfg, _ = detect_hypr()
    if kind not in ("caelestia", "lua"):
        if kind == "conf":
            warn("keybind descriptions are only added automatically for Lua configs")
        return
    script = USER_SHELL / "scripts/describe-keybinds.py"
    if dry:
        say(f"   would add cheatsheet descriptions to {main_cfg} (scripts/describe-keybinds.py)")
        return
    if not ask(f"Add cheatsheet descriptions to the keybinds in {main_cfg}? (keeps a backup)"):
        return
    run([sys.executable, str(script), str(main_cfg)], capture=False)


# --- Shell restart ----------------------------------------------------------

def caelestia_pids():
    """PIDs of every running caelestia shell, from either config location."""
    out = run(["qs", "list", "--all"]).stdout
    pids, pid = [], None
    for line in re.sub(r"\x1b\[[0-9;]*m", "", out).splitlines():
        line = line.strip()
        if line.startswith("Process ID:"):
            pid = line.split(":", 1)[1].strip()
        elif line.startswith("Config path:") and pid and "caelestia" in line:
            pids.append(pid)
    return pids


def ipc(pid, *args):
    """Call a caelestia IPC function on one shell instance; returns its output."""
    r = run(["qs", "ipc", "--pid", pid, "call", *args])
    if r.returncode != 0:
        return None
    out = r.stdout.strip().splitlines()
    return out[-1].strip() if out else ""  # "" = success with no return value


class KeepAwake:
    """Turn on caelestia's idle inhibitor while installing, so the screen
    can't lock mid-install (the lock screen is part of the shell, and
    restarting a shell that holds the lock leaves Hyprland's crashed-lock
    screen), then restore the previous setting."""

    def __enter__(self):
        self.enabled = []
        if have("qs"):
            for pid in caelestia_pids():
                if ipc(pid, "idleInhibitor", "isEnabled") == "false" and ipc(pid, "idleInhibitor", "enable") is not None:
                    self.enabled.append(pid)
        return self

    def __exit__(self, *exc):
        if self.enabled:
            for pid in caelestia_pids():  # possibly new instances after a restart
                ipc(pid, "idleInhibitor", "disable")
        return False


def wait_until_unlocked(timeout=1800):
    """Never restart a shell that's showing the lock screen."""
    def locked():
        return any(ipc(p, "lock", "isLocked") == "true" for p in caelestia_pids())
    if not locked():
        return True
    say("   your screen is locked; waiting for you to unlock it before restarting the shell (Ctrl+C to skip)")
    end = time.time() + timeout
    try:
        while time.time() < end:
            time.sleep(3)
            if not locked():
                return True
    except KeyboardInterrupt:
        pass
    return False


def restart_shell():
    """Restart every caelestia shell. Returns True/False for clean/errors, or
    None if it was skipped because the screen stayed locked."""
    if not have("qs"):
        return True
    if not wait_until_unlocked():
        warn("skipped restarting the shell; run ./install.py --restart when you're back")
        return None
    # Kill by PID: `caelestia shell -k` only targets the config path that
    # `qs -c caelestia` currently resolves to, and misses a stock instance
    # that was started from /etc/xdg before XTend created the user copy.
    for pid in caelestia_pids():
        run(["qs", "kill", "--pid", pid])
    time.sleep(1)
    start = ["caelestia", "shell", "-d"] if have("caelestia") else ["qs", "-c", "caelestia", "-n", "-d"]
    run(start)
    time.sleep(6)
    logs = sorted(Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "quickshell/by-id").glob("*/log.qslog"),
                  key=lambda p: p.stat().st_mtime)
    if not logs:
        warn("couldn't find the shell's log to check it started cleanly")
        return True
    log = run(["qs", "log", str(logs[-1])]).stdout
    errors = [l for l in re.sub(r"\x1b\[[0-9;]*m", "", log).splitlines()
              if re.search(r"TypeError|ReferenceError|caused by|Failed to load configuration", l)]
    if errors:
        warn("the shell reported errors:")
        for l in errors[:10]:
            say(f"     {l.strip()}")
        return False
    ok("shell restarted, no errors in its log")
    return True


# --- Commands ---------------------------------------------------------------

def choose_features(state):
    visible = [f for f in FEATURES if not f.hidden]
    installed = set(state.get("features", []))
    head("Features")
    picked = []
    for f in visible:
        mark = " (installed)" if f.name in installed else ""
        say(f"   \033[1m{f.title}\033[0m{mark}\n     {f.summary}")
        for n in f.notes:
            say(f"     \033[33mnote:\033[0m {n}")
        if ask(f"Add {f.title}?", default=f.name in installed or f.default):
            picked.append(f.name)
    return picked


def simulate(root, features):
    """Check features in install order against a scratch copy of the files.

    Later features can depend on edits made by earlier ones (e.g. a hook that
    launcher-hints adds), so each is checked against the files as they'll be
    by then, not as they are now. Returns (installable, skipped-with-reasons).
    """
    import tempfile
    files = {op.file for f in features for op in f.ops}
    todo, skipped, bad = [], [], set()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for rel in files:
            if (root / rel).is_file():
                (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(root / rel, tmp / rel)
        for f in features:
            probs = engine.preflight(tmp, f.name, f.ops)
            if set(f.requires) & bad:
                probs = probs or [f"needs {', '.join(sorted(set(f.requires) & bad))}, which can't be installed"]
            if probs:
                skipped.append((f, probs))
                bad.add(f.name)
            else:
                engine.apply(tmp, f.name, f.ops)
                todo.append((f, []))
    return todo, skipped


def do_install(names, state, dry):
    version = caelestia_version()
    head("Checking your setup")
    say(f"   caelestia-shell: {version or 'not found'}")
    if version and version not in TESTED_VERSIONS:
        warn(f"XTend was tested with caelestia-shell {', '.join(sorted(TESTED_VERSIONS))}; edits that don't fit are skipped")
    kind, main_cfg, _ = detect_hypr()
    say(f"   Hyprland config: {({'caelestia': 'caelestia dotfiles', 'lua': 'your own (Lua)', 'conf': 'your own (hyprland.conf)'}).get(kind, 'not found')}")
    if not ensure_user_shell(state, dry):
        return 1

    root = USER_SHELL if (USER_SHELL / "shell.qml").exists() else SYSTEM_SHELL
    todo, skipped = simulate(root, resolve(names))

    head("Plan")
    for f, _ in todo:
        if not f.hidden:
            say(f"   + {f.title}")
    for f, probs in skipped:
        warn(f"skipping {f.title}: it doesn't fit this caelestia version")
        for p in probs[:3]:
            say(f"       {p}")
    pkgs = sorted({p for f, _ in todo for p in f.packages})
    aur = sorted({p for f, _ in todo for p in f.aur})
    if pkgs or aur:
        say(f"   packages: {' '.join(pkgs + aur)} (already-installed ones are skipped)")
    if not todo:
        say("   nothing to do")
        return 0 if not skipped else 1
    if dry:
        chosen = [f.name for f, _ in todo]
        install_packages(pkgs, aur, True)
        if "filesearch" in chosen:
            setup_plocate(True)
        setup_keybinds(chosen, True, state)
        if "cheatsheet" in chosen:
            describe_keybinds(True)
        say("\n   --check: nothing was changed")
        return 0
    if not ask("Go ahead?"):
        return 1

    with KeepAwake():
        return _install(todo, pkgs, aur, version, state)


def _install(todo, pkgs, aur, version, state):
    head("Installing")
    created_copy = state.pop("_created_copy", False)
    prev_features = list(state.get("features", []))
    state["backup"] = backup_shell()
    installed = state.setdefault("features", [])
    for f, _ in todo:
        add_feature(f)
        if f.name not in installed:
            installed.append(f.name)
        if not f.hidden:
            ok(f.title)
    state["caelestia_version"] = version
    save_state(state)

    chosen = [f.name for f, _ in todo]
    install_packages(pkgs, aur, False)
    if "filesearch" in chosen:
        setup_plocate(False)
    setup_env(chosen, False)
    head("Keybinds")
    setup_keybinds(list(installed), False, state)
    save_state(state)
    if "cheatsheet" in chosen:
        describe_keybinds(False)
    head("Restarting the shell")
    if restart_shell() is False:
        rollback(state, prev_features, created_copy)
        return 1
    for f, _ in todo:
        for n in f.notes:
            say(f"   \033[33mnote:\033[0m {n}")
    return 0


def rollback(state, prev_features, created_copy):
    """The shell didn't load: put the previous shell files back and restart."""
    head("Rolling back")
    if created_copy:
        shutil.rmtree(USER_SHELL)
        state.pop("copied_from_system", None)
        ok("removed the shell copy XTend created; the stock caelestia shell runs again")
    else:
        shutil.rmtree(USER_SHELL)
        shutil.copytree(state["backup"], USER_SHELL, symlinks=True)
        ok(f"restored the shell from {state['backup']}")
    state["features"] = prev_features
    save_state(state)
    setup_keybinds(prev_features, False, state)
    restart_shell()
    warn("installing failed and was rolled back; please report the errors above")


def do_remove(names, state, dry):
    installed = state.get("features", [])
    visible_left = [n for n in installed if not BY_NAME[n].hidden and n not in names]
    keep = {f.name for f in resolve(visible_left)}
    gone = [f for f in reversed(resolve(names)) if f.name in installed and f.name not in keep]
    if not gone:
        say("   nothing to remove")
        return 0
    head("Removing")
    for f in gone:
        say(f"   - {f.title}")
    if dry or not ask("Go ahead?"):
        return 0
    state["backup"] = backup_shell()
    for f in gone:
        drop_feature(f)
        installed.remove(f.name)
    save_state(state)
    head("Keybinds")
    setup_keybinds(installed, False, state)
    if not installed:
        kind, main_cfg, _ = detect_hypr()
        unhook_user_file(kind, main_cfg)
        release_user_shell(state)
    head("Restarting the shell")
    restart_shell()
    return 0


def differing_files(a, b):
    import filecmp
    out = []
    def walk(d, rel=""):
        out.extend(rel + n for n in d.left_only + d.right_only + d.diff_files + d.funny_files)
        for name, sub in d.subdirs.items():
            walk(sub, f"{rel}{name}/")
    walk(filecmp.dircmp(a, b))
    return out


def release_user_shell(state):
    """After a full uninstall, delete the shell copy XTend made, if it's back
    to identical with the package, so the stock shell (and its updates) run."""
    if not state.get("copied_from_system") or not SYSTEM_SHELL.exists():
        return
    diff = differing_files(USER_SHELL, SYSTEM_SHELL)
    if diff:
        warn(f"kept {USER_SHELL}: it differs from the package copy in {len(diff)} file(s), e.g. {', '.join(diff[:3])}")
        return
    shutil.rmtree(USER_SHELL)
    state.pop("copied_from_system", None)
    save_state(state)
    ok(f"removed {USER_SHELL}; the stock caelestia shell runs again and follows package updates")


def do_update(state, dry):
    names = [n for n in state.get("features", []) if not BY_NAME[n].hidden]
    if not names:
        say("   no XTend features installed")
        return 0
    if state.get("copied_from_system") and not dry:
        # Start again from the freshly updated package copy, then re-apply
        backup_shell()
        shutil.rmtree(USER_SHELL)
        shutil.copytree(SYSTEM_SHELL, USER_SHELL, symlinks=True)
        state["features"] = []
        ok("refreshed the shell from the updated caelestia-shell package")
    return do_install(names, state, dry)


def main():
    global NOCONFIRM
    p = argparse.ArgumentParser(description="Add caelestia-XTend features to your caelestia shell.")
    p.add_argument("--features", help="comma-separated: " + ", ".join(f.name for f in FEATURES if not f.hidden))
    p.add_argument("--remove", help="comma-separated features to remove")
    p.add_argument("--uninstall", action="store_true", help="remove everything XTend added")
    p.add_argument("--update", action="store_true", help="re-apply features after a caelestia-shell update")
    p.add_argument("--check", action="store_true", help="show what would happen, change nothing")
    p.add_argument("--restart", action="store_true", help="just restart the shell (e.g. after a skipped restart)")
    p.add_argument("--noconfirm", action="store_true", help="use defaults for every question")
    a = p.parse_args()
    NOCONFIRM = a.noconfirm

    state = load_state()

    def parse(s):
        names = [n.strip() for n in s.split(",") if n.strip()]
        unknown = [n for n in names if n not in BY_NAME or BY_NAME[n].hidden]
        if unknown:
            sys.exit(f"unknown feature(s): {', '.join(unknown)}")
        return names

    if a.restart:
        return 0 if restart_shell() else 1
    if a.uninstall:
        return do_remove([n for n in state.get("features", []) if not BY_NAME[n].hidden], state, a.check)
    if a.remove:
        return do_remove(parse(a.remove), state, a.check)
    if a.update:
        return do_update(state, a.check)
    names = parse(a.features) if a.features else choose_features(state)
    if not names:
        say("   no features selected")
        return 0
    return do_install(names, state, a.check)


if __name__ == "__main__":
    sys.exit(main())
