#!/usr/bin/env python3
"""feishu_seed_workspace_patch.py — local patch of openclaw's feishu
dynamic-agent creator so newly-spawned peer workspaces get seeded with
the review-agent persona template (SOUL.md / AGENTS.md / BOOTSTRAP.md /
IDENTITY.md / USER.md / HEARTBEAT.md / responder-profile.md symlink).

Rationale
---------
openclaw core's `maybeCreateDynamicAgent` (lives in a `monitor-*.js` file
inside openclaw's dist/) only `mkdir`s an empty workspace + agent dir on
first DM. After that, openclaw seeds the workspace with its BUILT-IN
"memorist" default templates (with the "Hey I just came online, who am
I?" bootstrap). Those defaults are completely wrong for a review-agent
deployment — the subagent ends up asking the Requester for identity
negotiation instead of running a review.

This patch inserts a block right after the mkdirs that copies our
review-agent workspace template into the new workspace BEFORE openclaw
seeds its defaults. Because openclaw's seeding uses `writeFileIfMissing`,
our files (copied first) win: openclaw won't overwrite them.

The patch is idempotent and marker-guarded — safe to re-run after
`openclaw update` overwrites the target file. Backs up before any write.

## Path discovery (fixes bug #2 reported from Linux VPS)

openclaw's bundled monitor-*.js lives in different places depending on
how openclaw was installed:

  - macOS Homebrew:     /opt/homebrew/lib/node_modules/openclaw/dist/monitor-<hash>.js
  - macOS Intel:        /usr/local/lib/node_modules/openclaw/dist/monitor-<hash>.js
  - Linux system npm:   /usr/lib/node_modules/openclaw/dist/monitor-<hash>.js
  - Linux alt locations: various $(npm root -g) paths
  - Windows:            %APPDATA%/npm/node_modules/openclaw/dist/  (untested)

The `<hash>` suffix changes across openclaw releases (my dev machine:
D9C3Olkl; VPS: 6KpSIhEL / BAWxXKRf / BMI3D6x8 — 3 split files in newer
builds!). So we can't hardcode the path. We search candidate dirs, glob
for `monitor-*.js`, and pick the file that actually contains our anchor.

Usage
-----
  python3 feishu_seed_workspace_patch.py              # apply
  python3 feishu_seed_workspace_patch.py --dry-run    # preview
  python3 feishu_seed_workspace_patch.py --revert     # restore latest backup
  python3 feishu_seed_workspace_patch.py --monitor-js <path>   # explicit path

Options
-------
  --monitor-js <path>   explicit path to monitor-*.js (skip auto-discovery)
  --template <path>     path to the review-agent workspace template
                        (default: ~/.openclaw/workspace/templates/review-agent)
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path


DEFAULT_TEMPLATE = Path.home() / ".openclaw" / "workspace" / "templates" / "review-agent"

MARKER = "review-agent local patch: seed workspace"

# JS block to inject right after the two mkdirs (workspace + agentDir).
# Uses dynamic import of child_process to avoid adding top-level imports,
# and wraps in try/catch so any failure here never breaks spawn.
# os.homedir() in the JS runtime resolves to the openclaw process's HOME,
# which is correct regardless of install method.
PATCH_BLOCK = r'''
	// ── review-agent local patch: seed workspace from template ──
	try {
		const raSeedTemplate = path.join(os.homedir(), ".openclaw", "workspace", "templates", "review-agent");
		if (fsSync.existsSync(raSeedTemplate)) {
			const { execSync: raExecSync } = await import("node:child_process");
			// POSIX cp -R to copy template contents into the new workspace.
			// openclaw feishu dynamic agents are macOS/Linux only in practice.
			raExecSync(`cp -R "${raSeedTemplate}/." "${workspace}/"`, { stdio: "ignore" });
			log(`  review-agent: seeded ${workspace} from ${raSeedTemplate}`);
		}
	} catch (raErr) {
		log(`  review-agent: seed failed (non-fatal): ${String(raErr)}`);
	}
	// ── /review-agent local patch ──
'''


# Anchor: the second mkdir line. We insert immediately AFTER it.
ANCHOR_RE = re.compile(
    r'(await fsSync\.promises\.mkdir\(agentDir, \{ recursive: true \}\);)',
)


# Auto-discovery candidates. Search order: most specific → least.
def _candidate_dist_dirs():
    dirs = []
    # 1. Let npm tell us the global node_modules root (most authoritative)
    try:
        r = subprocess.run(["npm", "root", "-g"], capture_output=True,
                           text=True, timeout=3)
        if r.returncode == 0 and r.stdout.strip():
            dirs.append(Path(r.stdout.strip()) / "openclaw" / "dist")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    # 2. Well-known install locations across OSes
    dirs.extend([
        Path("/opt/homebrew/lib/node_modules/openclaw/dist"),          # macOS Apple Silicon brew
        Path("/usr/local/lib/node_modules/openclaw/dist"),             # macOS Intel brew / Linux local
        Path("/usr/lib/node_modules/openclaw/dist"),                   # Linux system npm
        Path.home() / ".local" / "lib" / "node_modules" / "openclaw" / "dist",  # user-level npm
        Path.home() / "node_modules" / "openclaw" / "dist",            # project-local
    ])
    # Dedupe while preserving order
    seen = set()
    out = []
    for d in dirs:
        key = str(d.resolve()) if d.exists() else str(d)
        if key not in seen:
            out.append(d)
            seen.add(key)
    return out


def find_monitor_js(explicit=None):
    """Return (path, all_searched) where path is the monitor-*.js containing
    our anchor, or None if not found."""
    searched = []
    if explicit:
        p = Path(explicit).expanduser().resolve()
        searched.append(str(p))
        if p.exists():
            try:
                if ANCHOR_RE.search(p.read_text()):
                    return p, searched
            except Exception:
                pass
        return None, searched

    for dist_dir in _candidate_dist_dirs():
        searched.append(str(dist_dir))
        if not dist_dir.exists():
            continue
        # Match monitor-<hash>.js (hash is variable suffix)
        for candidate in sorted(dist_dir.glob("monitor-*.js")):
            try:
                if ANCHOR_RE.search(candidate.read_text()):
                    return candidate, searched
            except Exception:
                continue
    return None, searched


def find_latest_backup(monitor_js: Path):
    cands = sorted(monitor_js.parent.glob(
        monitor_js.name + ".pre-review-agent-patch.*"))
    return cands[-1] if cands else None


def do_revert(monitor_js: Path):
    bak = find_latest_backup(monitor_js)
    if not bak:
        print(f"no backup found at {monitor_js.parent}", file=sys.stderr)
        sys.exit(2)
    shutil.copy2(bak, monitor_js)
    print(f"reverted {monitor_js} ← {bak.name}")


def do_patch(monitor_js: Path, dry_run: bool):
    src = monitor_js.read_text()

    if MARKER in src:
        print(f"already patched (marker '{MARKER}' present) — no-op.")
        return 0

    m = ANCHOR_RE.search(src)
    if not m:
        print(f"error: anchor not found in {monitor_js}", file=sys.stderr)
        sys.exit(3)

    new_src = src[:m.end()] + PATCH_BLOCK + src[m.end():]

    if dry_run:
        print(f"--- {monitor_js} (dry-run) ---")
        print(f"anchor found at byte {m.end()}")
        print(f"file size would grow from {len(src)} to {len(new_src)} "
              f"(+{len(new_src) - len(src)})")
        return 0

    ts = datetime.now().strftime("%Y%m%d%H%M%S")
    bak = monitor_js.with_suffix(monitor_js.suffix + f".pre-review-agent-patch.{ts}")
    shutil.copy2(monitor_js, bak)
    monitor_js.write_text(new_src)
    print(f"patched {monitor_js}")
    print(f"backup: {bak}")
    print()
    print("next steps:")
    print("  1. restart gateway:  openclaw gateway restart")
    print("  2. have a NEW feishu peer DM the bot — the workspace should be")
    print("     seeded with review-agent persona, not openclaw's default memorist.")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--monitor-js", default=None,
                    help="explicit path to monitor-*.js (skips auto-discovery)")
    ap.add_argument("--template", default=str(DEFAULT_TEMPLATE))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--revert", action="store_true")
    args = ap.parse_args()

    monitor_js, searched = find_monitor_js(args.monitor_js)

    if monitor_js is None:
        print("error: could not locate openclaw's monitor-*.js with the "
              "dynamic-agent creator function.", file=sys.stderr)
        print("Searched:", file=sys.stderr)
        for d in searched:
            print(f"  - {d}", file=sys.stderr)
        print(file=sys.stderr)
        print("Either openclaw isn't installed globally, or your install",
              file=sys.stderr)
        print("lives in a non-standard location. Find it manually and pass",
              file=sys.stderr)
        print("  python3 feishu_seed_workspace_patch.py --monitor-js <path>",
              file=sys.stderr)
        sys.exit(2)

    print(f"openclaw monitor-js: {monitor_js}")
    print()

    if args.revert:
        do_revert(monitor_js)
        return

    template = Path(args.template).expanduser()
    if not template.exists():
        print(f"warning: template {template} not found — patch will still "
              f"install, but won't seed anything until the template is put "
              f"in place.", file=sys.stderr)

    sys.exit(do_patch(monitor_js, args.dry_run) or 0)


if __name__ == "__main__":
    main()
