#!/usr/bin/env python3
"""feishu_seed_workspace_patch.py — local patch of openclaw's feishu
dynamic-agent creator so newly-spawned peer workspaces get seeded with
the review-agent persona template (SOUL.md / AGENTS.md / BOOTSTRAP.md /
IDENTITY.md / USER.md / HEARTBEAT.md / responder-profile.md symlink).

Rationale
---------
openclaw core's `maybeCreateDynamicAgent` for feishu (in
`monitor-D9C3Olkl.js`) only `mkdir`s an empty workspace + agent dir on
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
`openclaw update` overwrites the target file. Backs up to
`monitor-D9C3Olkl.js.pre-review-agent-patch.<ts>` before any write.

Usage
-----
  python3 feishu_seed_workspace_patch.py              # apply
  python3 feishu_seed_workspace_patch.py --dry-run    # preview
  python3 feishu_seed_workspace_patch.py --revert     # restore latest backup

Options
-------
  --monitor-js <path>   path to monitor-D9C3Olkl.js
                        (default: /opt/homebrew/lib/node_modules/openclaw/dist/monitor-D9C3Olkl.js)
  --template <path>     path to the review-agent workspace template
                        (default: ~/.openclaw/workspace/templates/review-agent)
"""
import argparse
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path


DEFAULT_MONITOR = Path("/opt/homebrew/lib/node_modules/openclaw/dist/monitor-D9C3Olkl.js")
DEFAULT_TEMPLATE = Path.home() / ".openclaw" / "workspace" / "templates" / "review-agent"

MARKER = "review-agent local patch: seed workspace"

# JS block to inject right after the two mkdirs (workspace + agentDir).
# Uses dynamic import of child_process to avoid adding top-level imports,
# and wraps in try/catch so any failure here never breaks spawn.
PATCH_BLOCK = r'''
	// ── review-agent local patch: seed workspace from template ──
	try {
		const raSeedTemplate = path.join(os.homedir(), ".openclaw", "workspace", "templates", "review-agent");
		if (fsSync.existsSync(raSeedTemplate)) {
			const { execSync: raExecSync } = await import("node:child_process");
			// Copy template contents (not the dir itself) into the new workspace.
			// Uses POSIX cp -R; Windows users would need a different path but openclaw
			// feishu is macOS/Linux only in practice.
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


def find_latest_backup(monitor_js: Path):
    cands = sorted(monitor_js.parent.glob(monitor_js.name + ".pre-review-agent-patch.*"))
    return cands[-1] if cands else None


def do_revert(monitor_js: Path):
    bak = find_latest_backup(monitor_js)
    if not bak:
        print(f"no backup found at {monitor_js.parent}", file=sys.stderr)
        sys.exit(2)
    shutil.copy2(bak, monitor_js)
    print(f"reverted {monitor_js} ← {bak.name}")


def do_patch(monitor_js: Path, dry_run: bool):
    if not monitor_js.exists():
        print(f"error: {monitor_js} not found", file=sys.stderr)
        sys.exit(2)

    src = monitor_js.read_text()

    if MARKER in src:
        print(f"already patched (marker '{MARKER}' present) — no-op.")
        return 0

    m = ANCHOR_RE.search(src)
    if not m:
        print("error: couldn't find the mkdir(agentDir) anchor in the file.\n"
              "  openclaw source may have moved. Inspect manually:",
              file=sys.stderr)
        print(f"  grep -n 'mkdir(agentDir' {monitor_js}", file=sys.stderr)
        sys.exit(3)

    new_src = src[:m.end()] + PATCH_BLOCK + src[m.end():]

    if dry_run:
        print(f"--- {monitor_js} (dry-run) ---")
        print(f"anchor found at byte {m.end()}")
        print(f"file size would grow from {len(src)} to {len(new_src)} "
              f"(+{len(new_src)-len(src)})")
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
    print("  2. have a NEW feishu peer DM the bot (or test by deleting an existing")
    print("     workspace-feishu-* dir + binding so spawn fires again)")
    print("  3. the new workspace should now contain review-agent persona files")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--monitor-js", default=str(DEFAULT_MONITOR))
    ap.add_argument("--template", default=str(DEFAULT_TEMPLATE))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--revert", action="store_true")
    args = ap.parse_args()

    monitor_js = Path(args.monitor_js).expanduser().resolve()

    if args.revert:
        do_revert(monitor_js)
        return

    template = Path(args.template).expanduser()
    if not template.exists():
        print(f"warning: template {template} not found — patch will still install,\n"
              f"  but won't seed anything until the template is put in place.",
              file=sys.stderr)

    sys.exit(do_patch(monitor_js, args.dry_run) or 0)


if __name__ == "__main__":
    main()
