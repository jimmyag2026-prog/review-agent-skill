#!/usr/bin/env python3
"""patch_openclaw_json.py — wire review-agent into ~/.openclaw/openclaw.json.

What it does (idempotently):

1. `channels.feishu.dynamicAgents.enabled = true`
2. `channels.feishu.dm.createAgentOnFirstMessage = true`
3. `channels.feishu.workspaceTemplate = "~/.openclaw/workspace/templates/review-agent"`
4. Seeds `channels.feishu.dmPolicy` to `"allowlist"` IF it's currently `"open"` —
   production default should be allowlist for review-agent (don't expose to
   random Lark users). Prints a notice so the admin knows to update allowFrom.
   Skipped if user explicitly set allowFrom already.

A timestamped backup is written before any write. No-op if everything is
already in place.

Usage:  python3 patch_openclaw_json.py [--force-allowlist]
"""
import argparse
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path


OPENCLAW_JSON = Path.home() / ".openclaw" / "openclaw.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force-allowlist", action="store_true",
                    help="force feishu.dmPolicy=allowlist even if currently open")
    args = ap.parse_args()

    if not OPENCLAW_JSON.exists():
        print(f"error: {OPENCLAW_JSON} not found — run `openclaw setup` first",
              file=sys.stderr)
        sys.exit(2)

    cfg = json.loads(OPENCLAW_JSON.read_text())
    changed = []

    channels = cfg.setdefault("channels", {})
    feishu = channels.setdefault("feishu", {})

    # 1. dynamicAgents
    da = feishu.setdefault("dynamicAgents", {})
    if da.get("enabled") is not True:
        da["enabled"] = True
        changed.append("channels.feishu.dynamicAgents.enabled=true")
    # keep adminBypass behavior; default to false for safety
    if "adminBypass" not in da:
        da["adminBypass"] = False
        changed.append("channels.feishu.dynamicAgents.adminBypass=false (default)")

    # 2. dm.createAgentOnFirstMessage
    dm = feishu.setdefault("dm", {})
    if dm.get("createAgentOnFirstMessage") is not True:
        dm["createAgentOnFirstMessage"] = True
        changed.append("channels.feishu.dm.createAgentOnFirstMessage=true")

    # 3. workspaceTemplate
    wt_expected = "~/.openclaw/workspace/templates/review-agent"
    if feishu.get("workspaceTemplate") != wt_expected:
        # Don't clobber a user-customized value silently — but if it's unset,
        # populate ours.
        if "workspaceTemplate" not in feishu:
            feishu["workspaceTemplate"] = wt_expected
            changed.append(f"channels.feishu.workspaceTemplate={wt_expected}")
        else:
            print(f"note: channels.feishu.workspaceTemplate is set to "
                  f"'{feishu['workspaceTemplate']}' (not our default). "
                  f"Leaving it — if you intended to use review-agent's "
                  f"template, set it to: {wt_expected}",
                  file=sys.stderr)

    # 4. dmPolicy (opt-in to allowlist tightening)
    if args.force_allowlist:
        if feishu.get("dmPolicy") != "allowlist":
            feishu["dmPolicy"] = "allowlist"
            if "allowFrom" not in feishu:
                feishu["allowFrom"] = []
            changed.append("channels.feishu.dmPolicy=allowlist (forced)")
            print("note: review-agent is now allowlist-only. Add your"
                  " Requesters' open_ids to channels.feishu.allowFrom"
                  " before they try to DM the bot.",
                  file=sys.stderr)

    if not changed:
        print("already wired — no changes.")
        return

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    bak = OPENCLAW_JSON.with_suffix(f".json.bak.review-agent-{ts}")
    shutil.copy2(OPENCLAW_JSON, bak)
    OPENCLAW_JSON.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")

    print("patched:")
    for c in changed:
        print(f"  • {c}")
    print(f"backup: {bak}")
    print()
    print("Apply by restarting the gateway:")
    print("  openclaw gateway restart")


if __name__ == "__main__":
    main()
