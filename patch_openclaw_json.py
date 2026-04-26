#!/usr/bin/env python3
"""patch_openclaw_json.py — bring ~/.openclaw/openclaw.json to the
canonical state required for review-agent v2.2+.

Performs four jobs (each idempotent, each with its own --skip flag):

1. **dynamicAgentCreation** — write the feishu-native key with absolute
   paths so per-peer subagents land in `workspace-feishu-<oid>/`.
2. **admin → main binding** — if --admin-open-id is given, add
   `bindings[*]` mapping admin's peer DM to the main agent (so admin's
   own messages don't trigger a peer subagent + review-coach persona).
3. **sandbox.docker.binds collision detection** — peer subagents have
   allowed_roots = peer workspace ONLY. Bind mounts whose source is
   outside that root cause every model fallback to die with "Sandbox
   security: ... outside allowed roots", surfacing to the user as the
   generic "Something went wrong while processing your request". We
   detect this and either WARN (default) or auto-clear with --clear-bad-binds.
4. **legacy key cleanup** — strip wecom-style keys planted by pre-v2.1.1.

Idempotent. Safe to re-run. Backup on every write.

Usage:
  python3 patch_openclaw_json.py
  python3 patch_openclaw_json.py --admin-open-id ou_xxx
  python3 patch_openclaw_json.py --admin-open-id ou_xxx --clear-bad-binds
  python3 patch_openclaw_json.py --skip-binds-check       # don't touch sandbox
  python3 patch_openclaw_json.py --openclaw-home /home/openclaw
"""
from __future__ import annotations
import argparse
import json
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Tuple


LEGACY_BAD_KEYS = ("dynamicAgents", "dm", "workspaceTemplate")


def _resolve_openclaw_home(explicit: Optional[str]) -> Path:
    """Find the openclaw HOME — where openclaw.json lives.

    Priority:
      1. --openclaw-home <path>
      2. $OPENCLAW_HOME env
      3. If running as root and 'openclaw' user exists → /home/openclaw
         (matches the DigitalOcean droplet image)
      4. Path.home()
    """
    if explicit:
        return Path(explicit).expanduser().resolve()
    env = os.environ.get("OPENCLAW_HOME")
    if env:
        return Path(env).expanduser().resolve()
    if os.geteuid() == 0:
        oc_home = Path("/home/openclaw")
        if oc_home.exists():
            return oc_home
    return Path.home()


def _detect_bad_binds(cfg: dict, openclaw_home: Path) -> List[Tuple[str, str]]:
    """Return a list of (bind_string, reason) for sandbox binds whose source
    is OUTSIDE per-peer workspaces.

    Per-peer subagents are sandboxed with allowed_roots = their own
    workspace-feishu-<oid>/ ONLY. Any bind mount with a source path elsewhere
    in $HOME/.openclaw/workspace/ (e.g., the openclaw default homebrew/skills/npm
    mounts) will be rejected at spawn-time and bricks the subagent.
    """
    binds = (cfg.get("agents", {}).get("defaults", {})
             .get("sandbox", {}).get("docker", {}).get("binds", []))
    bad = []
    # A bind is BAD if its source lives in the shared `.openclaw/workspace/`
    # dir (where openclaw plants homebrew/skills/npm) but NOT in a per-peer
    # `workspace-feishu-<oid>/` or `workspace-wecom-<oid>/` dir. Per-peer
    # sandboxes have allowed_roots = peer dir ONLY → shared-dir binds get
    # rejected and brick the subagent.
    #
    # We pattern-match on the substring `/.openclaw/workspace/` rather than
    # the resolved openclaw_home prefix, so detection works even if the
    # config file has a literal path that doesn't match the runtime $HOME
    # (e.g. a config copied from another box).
    for b in binds:
        if not isinstance(b, str):
            continue
        # Format: "src:dst:mode" or "src:dst"
        src = b.split(":", 1)[0]
        if "/.openclaw/workspace/" in src and \
           "workspace-feishu-" not in src and \
           "workspace-wecom-" not in src:
            bad.append((b, f"source '{src}' lives in shared workspace dir; "
                        f"peer subagent sandbox only allows its own "
                        f"workspace-feishu-<oid>/ as root"))
    return bad


def _ensure_admin_binding(cfg: dict, admin_oid: str) -> List[str]:
    """Ensure bindings[*] contains an entry routing admin's DM → main agent."""
    msgs = []
    bindings = cfg.setdefault("bindings", [])

    desired = {
        "agentId": "main",
        "match": {
            "channel": "feishu",
            "peer": {"kind": "direct", "id": admin_oid},
        },
    }

    # Look for any existing binding for this peer
    found_idx = None
    for i, b in enumerate(bindings):
        peer_id = (b.get("match") or {}).get("peer", {}).get("id")
        channel = (b.get("match") or {}).get("channel")
        if peer_id == admin_oid and channel == "feishu":
            found_idx = i
            break

    if found_idx is None:
        bindings.append(desired)
        msgs.append(f"ADDED binding: feishu peer {admin_oid} → agent 'main' "
                    f"(prevents admin DM from spawning a review-coach subagent)")
    elif bindings[found_idx].get("agentId") != "main":
        old_aid = bindings[found_idx].get("agentId")
        bindings[found_idx] = desired
        msgs.append(f"REWROTE binding: feishu peer {admin_oid}: "
                    f"'{old_aid}' → 'main'")

    # Also remove the admin from agents.list if previously planted as peer
    agents_list = cfg.get("agents", {}).get("list", [])
    new_list = [a for a in agents_list if a.get("id") != f"feishu-{admin_oid}"]
    if len(new_list) != len(agents_list):
        cfg["agents"]["list"] = new_list
        msgs.append(f"REMOVED stale agents.list entry feishu-{admin_oid} "
                    f"(admin shouldn't have a peer subagent)")

    return msgs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--admin-open-id", default=None,
                    help="Admin's Lark open_id (ou_xxx). If given, write a "
                    "bindings entry routing admin's DM → main agent.")
    ap.add_argument("--openclaw-home", default=None,
                    help="Override openclaw HOME (default: auto-detect)")
    ap.add_argument("--clear-bad-binds", action="store_true",
                    help="Auto-clear sandbox binds that conflict with "
                    "per-peer subagent allowed_roots. Without this flag, "
                    "we WARN but leave binds in place.")
    ap.add_argument("--skip-binds-check", action="store_true",
                    help="Don't inspect sandbox binds at all")
    ap.add_argument("--no-cleanup", action="store_true",
                    help="Don't strip legacy wecom-style keys")
    ap.add_argument("--force-allowlist", action="store_true",
                    help="Force feishu.dmPolicy=allowlist")
    args = ap.parse_args()

    openclaw_home = _resolve_openclaw_home(args.openclaw_home)
    openclaw_json = openclaw_home / ".openclaw" / "openclaw.json"
    if not openclaw_json.exists():
        print(f"error: {openclaw_json} not found — run `openclaw setup` first",
              file=sys.stderr)
        sys.exit(2)

    cfg = json.loads(openclaw_json.read_text())
    changed = []

    # ── 1. dynamicAgentCreation (canonical, absolute paths) ──
    feishu_dac = {
        "enabled": True,
        "workspaceTemplate":
            f"{openclaw_home}/.openclaw/workspace-{{agentId}}",
        "agentDirTemplate":
            f"{openclaw_home}/.openclaw/agents/{{agentId}}/agent",
        "maxAgents": 100,
    }
    channels = cfg.setdefault("channels", {})
    feishu = channels.setdefault("feishu", {})

    if not args.no_cleanup:
        for bad in LEGACY_BAD_KEYS:
            if bad in feishu:
                if bad == "dm" and isinstance(feishu["dm"], dict):
                    if "createAgentOnFirstMessage" in feishu["dm"]:
                        del feishu["dm"]["createAgentOnFirstMessage"]
                        changed.append("REMOVED legacy "
                                       "channels.feishu.dm.createAgentOnFirstMessage")
                    if not feishu["dm"]:
                        del feishu["dm"]
                else:
                    del feishu[bad]
                    changed.append(f"REMOVED legacy channels.feishu.{bad}")

    existing_dac = feishu.get("dynamicAgentCreation") or {}
    merged = dict(existing_dac)
    for k, v in feishu_dac.items():
        if merged.get(k) != v:
            merged[k] = v
    if merged != existing_dac:
        feishu["dynamicAgentCreation"] = merged
        changed.append(f"channels.feishu.dynamicAgentCreation = "
                       f"{{enabled: True, paths under {openclaw_home}/.openclaw/}}")

    # Drop legacy `unauthorized_dm_behavior` if present — newer openclaw
    # (≥2026.4.24) removed this from the feishu schema and rejects the
    # entire channels.feishu block as "additional properties not allowed"
    # if it's there. The pairing-flow / dmPolicy combo replaced it.
    if "unauthorized_dm_behavior" in feishu:
        del feishu["unauthorized_dm_behavior"]
        changed.append("REMOVED channels.feishu.unauthorized_dm_behavior "
                       "(rejected by openclaw ≥2026.4.24 schema)")

    # When dmPolicy=open, openclaw ≥2026.4.24 requires allowFrom=["*"].
    # Without it, gateway clobbers config to last-known-good on restart.
    if feishu.get("dmPolicy") == "open" and not feishu.get("allowFrom"):
        feishu["allowFrom"] = ["*"]
        changed.append("channels.feishu.allowFrom = ['*'] "
                       "(required when dmPolicy='open' on openclaw ≥2026.4.24)")

    if args.force_allowlist and feishu.get("dmPolicy") != "allowlist":
        feishu["dmPolicy"] = "allowlist"
        feishu.setdefault("allowFrom", [])
        changed.append("channels.feishu.dmPolicy = 'allowlist' (forced)")

    # ── 2. admin → main binding ──
    if args.admin_open_id:
        if not args.admin_open_id.startswith("ou_"):
            print(f"error: --admin-open-id must start with 'ou_', got "
                  f"{args.admin_open_id}", file=sys.stderr)
            sys.exit(3)
        changed.extend(_ensure_admin_binding(cfg, args.admin_open_id))

    # ── 3. sandbox.docker.binds collision check ──
    if not args.skip_binds_check:
        bad_binds = _detect_bad_binds(cfg, openclaw_home)
        if bad_binds:
            print()
            print("⚠ sandbox.docker.binds collision detected:", file=sys.stderr)
            for b, reason in bad_binds:
                print(f"   - {b}", file=sys.stderr)
                print(f"     reason: {reason}", file=sys.stderr)
            print()
            if args.clear_bad_binds:
                sb = (cfg.setdefault("agents", {}).setdefault("defaults", {})
                      .setdefault("sandbox", {}).setdefault("docker", {}))
                old = sb.get("binds", [])
                bad_strs = {b for b, _ in bad_binds}
                sb["binds"] = [b for b in old if b not in bad_strs]
                changed.append(f"CLEARED {len(bad_binds)} colliding "
                               f"sandbox.docker.binds entr{'y' if len(bad_binds) == 1 else 'ies'}")
                print(f"  → cleared (kept {len(sb['binds'])} other binds)",
                      file=sys.stderr)
            else:
                print("  Symptom: every Requester DM dies with 'Something went "
                      "wrong while processing your request'.", file=sys.stderr)
                print("  Re-run with --clear-bad-binds to auto-fix, or edit "
                      "manually.", file=sys.stderr)
                print(file=sys.stderr)

    if not changed:
        print("already canonical — no changes.")
        return

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    bak = openclaw_json.with_suffix(f".json.bak.review-agent-{ts}")
    shutil.copy2(openclaw_json, bak)
    openclaw_json.write_text(
        json.dumps(cfg, indent=2, ensure_ascii=False) + "\n"
    )

    print("patched:")
    for c in changed:
        print(f"  • {c}")
    print(f"backup: {bak}")
    print()
    print("Apply by restarting the gateway:")
    print("  openclaw gateway restart  # or: systemctl restart openclaw")


if __name__ == "__main__":
    main()
