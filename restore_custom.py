#!/usr/bin/env python3
"""Restore the custom Dawarich code (GTFS/transit, track_pick) after an upgrade.

Community-script upgrades replace /opt/dawarich/app wholesale. This repo
(/opt/dawarich-custom, origin onedev.crusand.org/dawarich-custom) is the source
of truth for everything we add on top of upstream:

  files/<rel>                  custom-only files, copied verbatim
  ours/<rel>                   our version of a modified upstream file
  upstream/<version>/<rel>     the pristine upstream file `ours` was made from
  manifest.json                base_version + the two file lists

A custom file dropped from the manifest is removed from the app if it still has
the content we wrote (state.json); otherwise it is left and reported.

Modified upstream files are 3-way merged (git merge-file): ours vs
upstream/<base_version> vs the new upstream file. Nothing is written to the app
unless every file merges cleanly and no guard fires; on a conflict the merge
output is left under /var/lib/dawarich-custom/conflicts/<version>/ and Discord
gets the list. The app then stays plain upstream (working, without transit).

After writing: bundle check/install (if the Gemfile changed), db:migrate,
assets:precompile, restart of the units below, and a smoke check that /transit
is routed again (302 to sign-in, not 404).

Commands:
  restore_custom.py [--dry-run]   restore (default); --dry-run only prints the plan
  restore_custom.py --settle      the same, after waiting for an upgrade to finish
                                  (app tree quiet, web and worker active): used by
                                  the .path trigger install/lxc.sh sets up
  restore_custom.py capture       copy the live custom files back into the repo
                                  (after editing on the box; then git commit)
  restore_custom.py rebase        after a clean merge on a new upstream version:
                                  make that version the new merge base
  restore_custom.py export OUT [--version V]
                                  Docker build: merge onto a copy of the upstream
                                  app (DAWARICH_APP) and write the changed files to
                                  OUT; no state, systemd or Discord; exit 2 on a
                                  conflict (docker/Dockerfile)
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(os.environ.get("DAWARICH_CUSTOM_REPO") or Path(__file__).resolve().parent)
APP = Path(os.environ.get("DAWARICH_APP", "/opt/dawarich/app"))
VAR = Path(os.environ.get("DAWARICH_CUSTOM_STATE", "/var/lib/dawarich-custom"))
STATE = VAR / "state.json"
LOCK = Path(os.environ.get("DAWARICH_CUSTOM_LOCK", "/run/dawarich-custom-restore.lock"))
ENV_FILES = (Path("/opt/dawarich/.env"), Path("/opt/dawarich/gtfs.env"))
DISCORD_ENV = Path("/opt/dawarich-osrm/discord.env")
RBENV_SHIMS = "/root/.rbenv/shims"

# Restarted (and smoke-checked) only where installed and enabled or running
# (unit_wanted): a fresh community-scripts CT has no dawarich-web-local, and
# the bot only once it is set up (install/proxmox.sh leaves it disabled).
RESTART_UNITS = ("dawarich-web", "dawarich-web-local", "dawarich-worker", "dawarich-gtfs-discord-bot")
# (url, unit) -- /transit must be routed: 302 to sign-in, not 404
SMOKE_URLS = (("http://127.0.0.1:3000/transit", "dawarich-web"),
              ("http://127.0.0.1:3002/transit", "dawarich-web-local"))
SMOKE_TIMEOUT_SEC = 240
# --settle: the .path trigger fires while the upgrade is still writing
SETTLE_QUIET_SEC = 120
SETTLE_MAX_SEC = 45 * 60
SETTLE_POLL_SEC = 15
BOT_UNIT = "dawarich-gtfs-discord-bot"
GEM_FILES = ("Gemfile", "Gemfile.lock")
MIGRATION_RE = re.compile(r"^db/migrate/(\d{14})_.+\.rb$")
# Ruby backtrace lines ("/path/x.rb:12:in 'm'", "\tfrom /path/x.rb:12:in ..."): dropped
# from error reports so the actual exception (PG::..., rake aborted!) survives the tail
BACKTRACE_RE = re.compile(r"^\s*(from\s+)?\S+:\d+:in\s")


# --- helpers -------------------------------------------------------------

def log(msg: str, err: bool = False) -> None:
    stamp = datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
    for line in str(msg).splitlines() or [""]:
        print(f"{stamp} {line}", file=sys.stderr if err else sys.stdout, flush=True)


def sha(data: bytes | None) -> str | None:
    return None if data is None else hashlib.sha256(data).hexdigest()


def read(path: Path) -> bytes | None:
    return path.read_bytes() if path.is_file() else None


def atomic_write(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        mode = path.stat().st_mode & 0o777
    tmp = path.with_name(path.name + ".custom-new")
    tmp.write_bytes(data)
    tmp.chmod(mode)
    os.replace(tmp, path)


def load_dotenv(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("export "):
            line = line[7:].strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def app_version() -> str:
    p = APP / ".app_version"
    return (p.read_text(encoding="utf-8").strip() if p.is_file() else "") or "unknown"


def load_manifest() -> dict:
    m = json.loads((REPO / "manifest.json").read_text(encoding="utf-8"))
    for key in ("base_version", "custom_files", "patched_files"):
        if key not in m:
            raise RuntimeError(f"manifest.json: missing {key}")
    return m


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(state: dict) -> None:
    VAR.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, STATE)


def acquire_lock() -> int | None:
    import fcntl

    fd = os.open(str(LOCK), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def rails_env() -> dict[str, str]:
    env = dict(os.environ)
    for f in ENV_FILES:
        env.update(load_dotenv(f))
    env["RAILS_ENV"] = env.get("RAILS_ENV") or "production"
    env["PATH"] = f"{RBENV_SHIMS}:/root/.rbenv/bin:" + env.get("PATH", "/usr/bin:/bin")
    env.setdefault("HOME", "/root")
    return env


def run(cmd: list[str], timeout: int, env: dict | None = None) -> None:
    log("$ " + " ".join(cmd))
    r = subprocess.run(cmd, cwd=APP, env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        lines = [l[:300] for l in (r.stderr or r.stdout).strip().splitlines() if not BACKTRACE_RE.match(l)]
        tail = "\n".join(lines[-15:])
        raise RuntimeError(f"{' '.join(cmd)} failed ({r.returncode}):\n{tail}")


def notify(title: str, lines: list[str], ok: bool) -> None:
    webhook = os.environ.get("DISCORD_WEBHOOK_URL") or load_dotenv(DISCORD_ENV).get("DISCORD_WEBHOOK_URL")
    if not webhook:
        log("no DISCORD_WEBHOOK_URL; skip notify", err=True)
        return
    payload = {"embeds": [{
        "title": title,
        "description": "\n".join(lines)[:3900],
        "color": 0x22C55E if ok else 0xEF4444,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }]}
    req = urllib.request.Request(
        webhook, data=json.dumps(payload).encode("utf-8"), method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "dawarich-custom-restore"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp.read()
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        log(f"discord notify failed: {e}", err=True)


def merge_file(ours: bytes, base: bytes, theirs: bytes, labels: tuple[str, str, str]) -> tuple[bytes, int]:
    """git merge-file -p: returns (merged, number of conflicts)."""
    with tempfile.TemporaryDirectory(prefix="dawarich-merge-") as d:
        paths = []
        for name, data in (("ours", ours), ("base", base), ("theirs", theirs)):
            p = Path(d) / name
            p.write_bytes(data)
            paths.append(str(p))
        cmd = ["git", "merge-file", "-p", "--diff3"]
        for label in labels:
            cmd += ["-L", label]
        r = subprocess.run(cmd + paths, capture_output=True)
    if r.returncode < 0 or r.returncode > 127:
        raise RuntimeError(f"git merge-file failed: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout, r.returncode


# --- planning (no writes to the app) --------------------------------------

def pristine_path(version: str, rel: str) -> Path:
    in_repo = REPO / "upstream" / version / rel
    return in_repo if in_repo.is_file() else VAR / "pristine" / version / rel


def plan_restore(manifest: dict, state: dict, version: str):
    """Returns (writes {rel: bytes, or None = remove}, archive {rel: bytes}, records, conflicts, notes)."""
    base_version = manifest["base_version"]
    records = dict(state.get("files", {}))
    writes: dict[str, bytes | None] = {}
    archive: dict[str, bytes] = {}
    conflicts: list[str] = []
    conflict_output: dict[str, bytes] = {}
    notes: list[str] = []

    custom = set(manifest["custom_files"])

    # Guard 1: migration versions must be unique. An upstream migration with
    # the same version as ours is silently skipped by db:migrate (the version is
    # already in schema_migrations), so this has to stop the restore.
    ours_versions: dict[str, str] = {}
    for rel in custom:
        m = MIGRATION_RE.match(rel)
        if m:
            ours_versions[m.group(1)] = rel
    for p in sorted((APP / "db/migrate").glob("*.rb")):
        rel = f"db/migrate/{p.name}"
        m = MIGRATION_RE.match(rel)
        if m and rel not in custom and m.group(1) in ours_versions:
            conflicts.append(
                f"migration version {m.group(1)}: upstream `{p.name}` collides with ours "
                f"`{Path(ours_versions[m.group(1)]).name}` (upstream one was skipped by db:migrate; "
                "rename ours, fix schema_migrations, re-run migrate)"
            )

    # Custom-only files: copy, but never overwrite something we did not write.
    for rel in manifest["custom_files"]:
        src = read(REPO / "files" / rel)
        if src is None:
            conflicts.append(f"`files/{rel}` missing from repo")
            continue
        cur = read(APP / rel)
        rec = records.get(rel, {})
        if cur == src:
            records[rel] = {"version": version, "written_sha": sha(cur)}
        elif cur is None or sha(cur) == rec.get("written_sha"):
            writes[rel] = src
            records[rel] = {"version": version, "written_sha": sha(src)}
        else:
            conflicts.append(f"`{rel}` exists and differs (new upstream file on our path, or edited live without capture)")

    # Modified upstream files: 3-way merge.
    for rel in manifest["patched_files"]:
        ours = read(REPO / "ours" / rel)
        base = read(REPO / "upstream" / base_version / rel)
        if ours is None or base is None:
            conflicts.append(f"`{rel}`: ours/ or upstream/{base_version}/ copy missing from repo")
            continue
        cur = read(APP / rel)
        if cur is None:
            conflicts.append(f"`{rel}` no longer exists upstream in {version}")
            continue
        rec = records.get(rel, {})
        if cur == ours:
            records[rel] = {"version": version, "written_sha": sha(cur), "ours_sha": sha(ours)}
            continue
        pristine = read(pristine_path(version, rel))
        if rec.get("version") == version and sha(cur) == rec.get("written_sha"):
            # Our earlier merge for this version; re-merge only if ours/ changed.
            if rec.get("ours_sha") == sha(ours):
                continue
            if pristine is None:
                conflicts.append(f"`{rel}`: ours/ changed but no pristine {version} copy to re-merge against")
                continue
            theirs = pristine
        elif pristine is not None and cur != pristine:
            conflicts.append(f"`{rel}` differs from upstream {version} and from our merge (edited live without capture?)")
            continue
        else:
            theirs = cur
            if pristine is None:
                archive[rel] = cur
        if theirs == base:
            merged, n = ours, 0  # upstream did not touch this file
        else:
            merged, n = merge_file(ours, base, theirs, (f"ours ({base_version}+custom)", f"upstream {base_version}", f"upstream {version}"))
            notes.append(f"`{rel}`: upstream changed it, merged ({'CONFLICT' if n else 'clean'})")
        if n:
            conflicts.append(f"`{rel}`: {n} merge conflict(s)")
            conflict_output[rel] = merged
        elif merged != cur:
            writes[rel] = merged
        records[rel] = {"version": version, "written_sha": sha(merged), "ours_sha": sha(ours)}

    # Dropped from the manifest: remove what we wrote, unless it changed since.
    managed = custom | set(manifest["patched_files"])
    for rel, rec in state.get("files", {}).items():
        if rel in managed:
            continue
        cur = read(APP / rel)
        if cur is None:
            records.pop(rel, None)
        elif "ours_sha" in rec:
            # was a merged upstream file: deleting it would break the app
            notes.append(f"`{rel}` no longer patched; put the upstream copy back by hand")
            records.pop(rel, None)
        elif sha(cur) == rec.get("written_sha"):
            writes[rel] = None
            records.pop(rel, None)
        else:
            notes.append(f"`{rel}` dropped from manifest but differs from what we wrote; left in place")

    return writes, archive, records, conflicts, conflict_output, notes


# --- apply ----------------------------------------------------------------

def apply_writes(writes: dict[str, bytes | None], stamp: str) -> dict[str, bytes | None]:
    """Back up and write (None: remove). Returns {rel: previous bytes or None} for rollback."""
    backup_dir = VAR / "backup" / stamp
    previous: dict[str, bytes | None] = {}
    for rel, data in sorted(writes.items()):
        dst = APP / rel
        prev = read(dst)
        previous[rel] = prev
        if prev is not None:
            b = backup_dir / rel
            b.parent.mkdir(parents=True, exist_ok=True)
            b.write_bytes(prev)
        if data is None:
            dst.unlink(missing_ok=True)
            d = dst.parent
            while d != APP and d.is_dir() and not any(d.iterdir()):
                d.rmdir()  # dirs only we used; rollback's atomic_write recreates them
                d = d.parent
        else:
            atomic_write(dst, data)
    return previous


def rollback(previous: dict[str, bytes | None]) -> None:
    for rel, prev in previous.items():
        dst = APP / rel
        if prev is None:
            dst.unlink(missing_ok=True)
        else:
            atomic_write(dst, prev)


def http_status(url: str) -> int | None:
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, headers={"Host": "localhost", "User-Agent": "dawarich-custom-smoke"})
    try:
        with opener.open(req, timeout=10) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except (urllib.error.URLError, TimeoutError, OSError):
        return None


def unit_wanted(unit: str) -> bool:
    r = subprocess.run(["systemctl", "show", unit, "-p", "LoadState", "-p", "UnitFileState", "-p", "ActiveState"],
                       capture_output=True, text=True)
    props = dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)
    if props.get("LoadState") != "loaded":
        return False
    return (props.get("UnitFileState", "").startswith("enabled")
            or props.get("ActiveState") in ("active", "activating", "reloading"))


def smoke_check(units: list[str]) -> list[str]:
    errors: list[str] = []
    deadline = time.monotonic() + SMOKE_TIMEOUT_SEC
    for url, unit in SMOKE_URLS:
        if unit not in units:
            continue
        status = None
        while time.monotonic() < deadline:
            status = http_status(url)
            if status is not None and status not in (502, 503):
                break
            time.sleep(5)
        if status is None or status == 404 or status >= 500:
            errors.append(f"smoke: {url} ({unit}) -> {status}")
        else:
            log(f"smoke: {url} -> {status}")
    if BOT_UNIT in units:
        time.sleep(20)  # the bot exits fast on a missing rake task or a bad token
        r = subprocess.run(["systemctl", "is-active", "--quiet", BOT_UNIT], check=False)
        if r.returncode != 0:
            errors.append(f"smoke: {BOT_UNIT} not active")
    return errors


def wait_for_upgrade_to_settle() -> None:
    """Until the app tree has been quiet for SETTLE_QUIET_SEC and web and
    worker are active again (the community-scripts update restarts them
    last), at most SETTLE_MAX_SEC."""
    deadline = time.monotonic() + SETTLE_MAX_SEC
    units = [u for u in ("dawarich-web", "dawarich-worker") if unit_wanted(u)]
    log(f"settle: waiting for the app tree to be quiet {SETTLE_QUIET_SEC}s and {', '.join(units)} active")
    while time.monotonic() < deadline:
        newest = 0.0
        for path in (APP, APP / ".app_version", APP / "config", APP / "public/assets", APP / "Gemfile.lock"):
            try:
                newest = max(newest, path.stat().st_mtime)
            except OSError:
                pass
        quiet = time.time() - newest
        active = all(subprocess.run(["systemctl", "is-active", "--quiet", u], check=False).returncode == 0 for u in units)
        if APP.is_dir() and quiet >= SETTLE_QUIET_SEC and active:
            log(f"settle: ok (quiet {quiet:.0f}s)")
            return
        time.sleep(SETTLE_POLL_SEC)
    log("settle: timeout, restoring anyway")


def restore(dry_run: bool) -> int:
    if not APP.is_dir():
        log("dawarich app missing; skip", err=True)
        return 0
    manifest = load_manifest()
    state = load_state()
    version = app_version()
    writes, archive, records, conflicts, conflict_output, notes = plan_restore(manifest, state, version)

    if dry_run:
        removes = sorted(r for r, d in writes.items() if d is None)
        log(f"app {version}, base {manifest['base_version']}: {len(writes) - len(removes)} write(s), "
            f"{len(removes)} removal(s), {len(conflicts)} conflict(s)")
        for rel in sorted(writes):
            log(f"  {'remove' if writes[rel] is None else 'write '} {rel}")
        for n in notes:
            log(f"  note  {n}")
        for c in conflicts:
            log(f"  CONFLICT {c}")
        return 2 if conflicts else 0

    for rel, data in archive.items():
        p = VAR / "pristine" / version / rel
        if not p.is_file():
            atomic_write(p, data)

    if conflicts:
        cdir = VAR / "conflicts" / version
        for rel, data in conflict_output.items():
            atomic_write(cdir / rel, data)
        log("refused: " + "; ".join(conflicts), err=True)
        if state.get("blocked") != {"version": version, "conflicts": conflicts}:
            notify("Dawarich custom restore BLOCKED", [
                f"Dawarich verzió: **{version}** (custom base: {manifest['base_version']})",
                "Semmit nem írtam az appba, a GTFS/transit és a track_pick most nem fut. Ütközések:",
                *[f"• {c}" for c in conflicts],
                f"Merge-kimenet: `{cdir}/`. Feloldás után: `restore_custom.py --dry-run`, majd újrafuttatás.",
            ], ok=False)
        state["blocked"] = {"version": version, "conflicts": conflicts}
        save_state(state)
        return 2

    state.pop("blocked", None)
    restart_pending = bool(state.get("restart_pending"))
    if not writes and not restart_pending:
        state.update({"app_version": version, "files": records})
        save_state(state)
        log(f"ok (v{version}, no changes)")
        return 0

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    lines = [f"Dawarich verzió: **{version}**" + (
        f" (előző: {state.get('app_version')})" if state.get("app_version") not in (None, version) else "")]
    env = rails_env()
    previous: dict[str, bytes | None] = {}
    try:
        if writes:
            previous = apply_writes(writes, stamp)
            log(f"wrote {len(writes)} file(s), backup: {VAR / 'backup' / stamp}")
            lines.append(f"Visszatett fájlok: {sum(1 for r in writes if r in manifest['custom_files'])} custom, "
                         f"{sum(1 for r in writes if r in manifest['patched_files'])} merge-elt upstream, "
                         f"{sum(1 for d in writes.values() if d is None)} törölt (kikerült a manifestből)")
            lines.extend(f"• {n}" for n in notes)
            if any(r in GEM_FILES for r in writes):
                try:
                    run(["bundle", "check"], 300, env)
                except RuntimeError:
                    run(["bundle", "install"], 1800, env)
            run(["bundle", "exec", "rails", "db:migrate"], 1800, env)
            run(["bundle", "exec", "rake", "assets:precompile"], 1800, env)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as e:
        # Gems, migrate or assets failed: running processes still have the old
        # code loaded, so put the files back and do not restart.
        try:
            rollback(previous)
            rolled = "fájlok visszaállítva, nincs újraindítás"
        except OSError as re_err:
            rolled = f"ROLLBACK FAILED: {re_err}"
        log(f"failed: {e} ({rolled})", err=True)
        notify("Dawarich custom restore FAILED", lines + [f"Hiba: {e}", rolled], ok=False)
        save_state(state)
        return 1

    state.update({"app_version": version, "files": records, "restart_pending": True,
                  "last_restore": datetime.now(timezone.utc).isoformat()})
    save_state(state)  # a failed restart is retried on the next run
    errors: list[str] = []
    units = [u for u in RESTART_UNITS if unit_wanted(u)]
    for unit in units:
        r = subprocess.run(["systemctl", "restart", unit], capture_output=True, text=True)
        if r.returncode != 0:
            errors.append(f"systemctl restart {unit}: {(r.stderr or r.stdout).strip()}")
    if not errors:
        state["restart_pending"] = False
        lines.append("Újraindítva: " + ", ".join(f"`{u}`" for u in units))
        errors = smoke_check(units)
    save_state(state)
    if not errors:
        ports = ", ".join(url.split(":")[2].split("/")[0] for url, unit in SMOKE_URLS if unit in units)
        lines.append(f"Smoke check: `/transit` routolva ({ports})" + (", a bot fut." if BOT_UNIT in units else "."))
        if version != manifest["base_version"]:
            lines.append(f"Merge-bázis még {manifest['base_version']}: `restore_custom.py rebase`, majd commit + push.")
    notify("Dawarich custom restore" + (" FAILED" if errors else ""), lines + [f"• {e}" for e in errors], ok=not errors)
    for e in errors:
        log(e, err=True)
    return 1 if errors else 0


# --- maintenance commands ---------------------------------------------------

def capture() -> int:
    """Live app -> repo, for files edited on the box. Then: git diff, commit, push."""
    manifest = load_manifest()
    version = app_version()
    if version != manifest["base_version"]:
        log(f"app is {version}, repo base is {manifest['base_version']}: run `rebase` first", err=True)
        return 2
    changed = []
    for rel in manifest["custom_files"]:
        cur = read(APP / rel)
        if cur is not None and cur != read(REPO / "files" / rel):
            atomic_write(REPO / "files" / rel, cur)
            changed.append(f"files/{rel}")
    for rel in manifest["patched_files"]:
        cur = read(APP / rel)
        if cur is not None and cur != read(REPO / "ours" / rel):
            atomic_write(REPO / "ours" / rel, cur)
            changed.append(f"ours/{rel}")
    write_patches(manifest)
    state = load_state()
    files = state.setdefault("files", {})
    for rel in manifest["custom_files"] + manifest["patched_files"]:
        cur = read(APP / rel)
        if cur is not None:
            files[rel] = {"version": version, "written_sha": sha(cur)}
            if rel in manifest["patched_files"]:
                files[rel]["ours_sha"] = sha(cur)
    save_state(state)
    log("captured: " + (", ".join(changed) if changed else "nothing changed"))
    log("new custom file? add it to manifest.json custom_files, re-run capture")
    return 0


def rebase() -> int:
    """After a clean restore on a new upstream version, make it the merge base."""
    manifest = load_manifest()
    version = app_version()
    old = manifest["base_version"]
    if version == old:
        log(f"base is already {version}")
        return 0
    state = load_state()
    if state.get("blocked") or state.get("app_version") != version:
        log(f"no clean restore recorded for {version}; run the restore first", err=True)
        return 2
    for rel in manifest["patched_files"]:
        pristine = read(pristine_path(version, rel))
        if pristine is None:
            # upstream did not change it: the old base is still the pristine file
            pristine = read(REPO / "upstream" / old / rel)
        cur = read(APP / rel)
        if pristine is None or cur is None:
            log(f"{rel}: missing pristine or live copy", err=True)
            return 2
        atomic_write(REPO / "upstream" / version / rel, pristine)
        atomic_write(REPO / "ours" / rel, cur)
    shutil.rmtree(REPO / "upstream" / old, ignore_errors=True)
    manifest["base_version"] = version
    (REPO / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    write_patches(manifest)
    log(f"rebased {old} -> {version}; review `git diff`, then commit and push")
    return 0


def write_patches(manifest: dict) -> None:
    """patches/ is for reading only; restore merges from ours/ + upstream/."""
    base = manifest["base_version"]
    shutil.rmtree(REPO / "patches", ignore_errors=True)
    for rel in manifest["patched_files"]:
        r = subprocess.run(
            ["diff", "-u", "--label", f"a/{rel}", "--label", f"b/{rel}",
             str(REPO / "upstream" / base / rel), str(REPO / "ours" / rel)],
            capture_output=True,
        )
        out = REPO / "patches" / f"{rel}.patch"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(r.stdout)


def export(out: Path, version: str | None) -> int:
    """The image build's restore: plan against DAWARICH_APP (a copy of the
    upstream image's app) with no previous state, and write every file that
    differs from upstream under `out`, to be copied over the app. The upstream
    image has no .app_version, so the build passes the version."""
    if not APP.is_dir():
        log(f"{APP} missing", err=True)
        return 1
    manifest = load_manifest()
    version = version or app_version()
    writes, _archive, _records, conflicts, conflict_output, notes = plan_restore(manifest, {}, version)
    # A fresh database gets upstream's schema.rb loaded, which marks our older
    # migrations as run; lib/tasks/gtfs_schema.rake runs them, but only those it lists.
    repair = read(REPO / "files" / "lib/tasks/gtfs_schema.rake") or b""
    for rel in manifest["custom_files"]:
        m = MIGRATION_RE.match(rel)
        if m and m.group(1).encode() not in repair:
            conflicts.append(f"migration {m.group(1)} missing from GtfsSchemaRepair::VERSIONS (lib/tasks/gtfs_schema.rake)")
    for n in notes:
        log(f"note  {n}")
    if conflicts:
        for c in conflicts:
            log(f"CONFLICT {c}", err=True)
        for rel, data in conflict_output.items():
            atomic_write(out.parent / f"{out.name}-conflicts" / rel, data)
        return 2
    for rel, data in sorted(writes.items()):
        if data is not None:
            atomic_write(out / rel, data)
    log(f"exported {sum(1 for d in writes.values() if d is not None)} file(s) for upstream {version} "
        f"(custom base {manifest['base_version']}) into {out}")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["export"]:
        if len(args) < 2:
            log("usage: restore_custom.py export OUT [--version V]", err=True)
            return 1
        version = args[args.index("--version") + 1] if "--version" in args[2:-1] else None
        return export(Path(args[1]), version)
    fd = acquire_lock()
    if fd is None:
        log("another restore is running; skip")
        return 0
    try:
        if args[:1] == ["capture"]:
            return capture()
        if args[:1] == ["rebase"]:
            return rebase()
        if "--settle" in args:
            wait_for_upgrade_to_settle()
        return restore(dry_run="--dry-run" in args)
    except Exception as e:  # unexpected crash: tell Discord, keep the exit code
        if "--dry-run" not in args:
            notify("Dawarich custom restore CRASHED", [f"{type(e).__name__}: {e}"], ok=False)
        raise
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
