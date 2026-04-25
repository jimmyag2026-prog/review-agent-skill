#!/usr/bin/env python3
"""patch_openclaw_json.py — wire review-agent into ~/.openclaw/openclaw.json.

Applies the ONE correct key for feishu dynamic agents:

    channels.feishu.dynamicAgentCreation = {
        "enabled": true,
        "workspaceTemplate": "~/.openclaw/workspace/templates/review-agent",
        "agentDirTemplate": "~/.openclaw/agents/{agentId}/agent",
        "maxAgents": 100
    }

*not* the wecom-plugin keys `dynamicAgents` / `dm.createAgentOnFirstMessage` /
top-level `workspaceTemplate`. Those are specific to the @sunnoy/wecom plugin
(which declares `additionalProperties: true` in its schema) and are REJECTED
by the feishu built-in channel schema with "invalid config: must NOT have
additional properties".

For backward compat: if an earlier version of this patcher left the bad
wecom-style keys in the config, we clean them up before writing the correct
key. That restores validity and brings the gateway back up.

Also seeds `channels.feishu.unauthorized_dm_behavior = "pair"` IF the key
is absent (respects explicit user choice; this is the hardening default).

Idempotent — safe to re-run. Backup on every write.

Usage:
  python3 patch_openclaw_json.py
  python3 patch_openclaw_json.py --force-allowlist
  python3 patch_openclaw_json.py --no-cleanup   (keep wecom-style keys in place)
"""
import argparse
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path


OPENCLAW_JSON = Path.home() / ".openclaw" / "openclaw.json"

# NOTE: workspaceTemplate / agentDirTemplate must be ABSOLUTE paths.
# openclaw's `resolveUserPath()` DOES expand `~/` in some code paths but not
# all — reported on Linux VPS that subagents couldn't find the template when
# workspaceTemplate was written as `~/.openclaw/...`. Writing the absolute
# path from Python's Path.home() at patch time is the safe option. The
# `{agentId}` placeholder is an openclaw template token (double-braced in
# the f-string to escape .format()).
_HOME = str(Path.home())
FEISHU_DAC_TARGET = {
    "enabled": True,
    "workspaceTemplate": f"{_HOME}/.openclaw/workspace-{{agentId}}",
    "agentDirTemplate": f"{_HOME}/.openclaw/agents/{{agentId}}/agent",
    "maxAgents": 100,
}

# Legacy wrong-keys planted by pre-v2.1.1 patcher runs. We strip these so
# feishu schema accepts the config again.
LEGACY_BAD_KEYS = ("dynamicAgents", "dm", "workspaceTemplate")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force-allowlist", action="store_true",
                    help="force feishu.dmPolicy=allowlist even if currently open")
    ap.add_argument("--no-cleanup", action="store_true",
                    help="don't remove legacy wecom-style keys from channels.feishu")
    args = ap.parse_args()

    if not OPENCLAW_JSON.exists():
        print(f"error: {OPENCLAW_JSON} not found — run `openclaw setup` first",
              file=sys.stderr)
        sys.exit(2)

    cfg = json.loads(OPENCLAW_JSON.read_text())
    changed = []

    channels = cfg.setdefault("channels", {})
    feishu = channels.setdefault("feishu", {})

    # 1. Cleanup legacy bad keys if present (from earlier broken patcher runs)
    if not args.no_cleanup:
        for bad in LEGACY_BAD_KEYS:
            if bad in feishu:
                # Be surgical: only remove `dm.createAgentOnFirstMessage`, not
                # the entire `dm` sub-object (in case other `dm.*` keys exist
                # and are valid). We know `dm` contained `createAgentOnFirstMessage`
                # and that's the only key pre-v2.1.1 patcher wrote there.
                if bad == "dm" and isinstance(feishu["dm"], dict):
                    if "createAgentOnFirstMessage" in feishu["dm"]:
                        del feishu["dm"]["createAgentOnFirstMessage"]
                        changed.append("REMOVED legacy channels.feishu.dm.createAgentOnFirstMessage (feishu schema rejects this — it's a wecom-plugin key)")
                    if not feishu["dm"]:
                        del feishu["dm"]
                else:
                    del feishu[bad]
                    changed.append(f"REMOVED legacy channels.feishu.{bad} (feishu schema rejects this — it's a wecom-plugin key)")

    # 2. Write the correct feishu-native key: dynamicAgentCreation
    existing = feishu.get("dynamicAgentCreation") or {}
    merged = dict(existing)
    for k, v in FEISHU_DAC_TARGET.items():
        if merged.get(k) != v:
            merged[k] = v
    if merged != existing:
        feishu["dynamicAgentCreation"] = merged
        changed.append("channels.feishu.dynamicAgentCreation = "
                       f"{{enabled: True, maxAgents: {FEISHU_DAC_TARGET['maxAgents']}, workspaceTemplate: …, agentDirTemplate: …}}")

    # 3. Hardening default: seed unauthorized_dm_behavior=pair if absent
    if "unauthorized_dm_behavior" not in feishu:
        feishu["unauthorized_dm_behavior"] = "pair"
        changed.append("channels.feishu.unauthorized_dm_behavior = 'pair' (new key)")

    # 4. Optional: tighten to allowlist
    if args.force_allowlist:
        if feishu.get("dmPolicy") != "allowlist":
            feishu["dmPolicy"] = "allowlist"
            if "allowFrom" not in feishu:
                feishu["allowFrom"] = []
            changed.append("channels.feishu.dmPolicy = 'allowlist' (forced)")
            print("note: allowlist mode — add your Requesters' open_ids to "
                  "channels.feishu.allowFrom before testing.",
                  file=sys.stderr)

    if not changed:
        print("already wired correctly — no changes.")
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
