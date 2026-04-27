#!/bin/bash
# uninstall.sh — remove review-agent skill from openclaw.
#
# For the human Admin to run from the command line. Not invoked by subagents.
#
# Default (no flags): dry-run preview of what would be removed.
#
# What --yes removes:
#   - watcher daemon (systemd-system / systemd-user / launchd / nohup, all modes)
#   - ~/.openclaw/skills/review-agent/                  (the shared skill)
#   - ~/.openclaw/workspace/templates/review-agent/     (per-peer workspace template)
#   - ~/.openclaw/review-agent-seeder.sh + seeder.log   (watcher artifacts)
#
# With --purge, ALSO removes:
#   - ~/.openclaw/review-agent/                         (global responder profile + enabled.json)
#   - Every ~/.openclaw/workspace-feishu-*/             (v2 — IRREVERSIBLE)
#   - Every ~/.openclaw/workspace-feishu-dm-*/          (v1 back-compat)
#   - Every ~/.openclaw/agents/feishu-*/                (v2 per-peer subagent dirs)
#   - Every ~/.openclaw/agents/feishu-dm-*/             (v1 back-compat)
#   - Bindings in openclaw.json whose agentId points to a removed peer
#   - /root/.review-agent/ if running as root and it exists (v1 leftovers)
#
# With --revert-config:
#   - channels.feishu.dynamicAgentCreation              (v2 key)
#   - channels.feishu.dynamicAgents                     (legacy v2.0 mistakenly written)
#   - channels.feishu.dm.createAgentOnFirstMessage      (legacy v2.0)
#   - channels.feishu.workspaceTemplate                 (legacy v2.0)
#
# Always: snapshots openclaw.json to a uniform .bak.uninstall-<ts> at the
# start of any mutation path (consolidated rollback).
#
# Usage:
#   uninstall.sh                    # dry-run
#   uninstall.sh --yes              # remove skill + template + watcher
#   uninstall.sh --yes --revert-config
#   uninstall.sh --yes --purge
#   uninstall.sh --yes --purge --revert-config   # full uninstall
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

YES=0; PURGE=0; REVERT=0
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --purge) PURGE=1 ;;
    --revert-config) REVERT=1 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown: $a"; exit 1 ;;
  esac
done

# ─── target user / HOME detection (matches install.sh logic) ──────────
if [ "$(id -u)" = "0" ] && id openclaw >/dev/null 2>&1; then
  TARGET_USER="openclaw"
  OC_HOME="/home/openclaw"
  RUN_AS="sudo -u openclaw -H"
else
  TARGET_USER="$(whoami)"
  OC_HOME="$HOME"
  RUN_AS=""
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SKILL=$OC_HOME/.openclaw/skills/review-agent
TEMPLATE=$OC_HOME/.openclaw/workspace/templates/review-agent
GLOBAL=$OC_HOME/.openclaw/review-agent
SEEDER_SCRIPT=$OC_HOME/.openclaw/review-agent-seeder.sh
SEEDER_LOG=$OC_HOME/.openclaw/seeder.log
OPENCLAW_JSON=$OC_HOME/.openclaw/openclaw.json

oc_run() { if [ -n "$RUN_AS" ]; then $RUN_AS "$@"; else "$@"; fi; }

# ─── what watcher artifacts exist on this machine ─────────────────────
WATCHER_ARTIFACTS=()
[ -f /etc/systemd/system/review-agent-seeder.service ] && \
  WATCHER_ARTIFACTS+=("systemd-system: /etc/systemd/system/review-agent-seeder.service")
[ -f "$OC_HOME/.config/systemd/user/review-agent-seeder.service" ] && \
  WATCHER_ARTIFACTS+=("systemd-user: $OC_HOME/.config/systemd/user/review-agent-seeder.service")
[ -f "$OC_HOME/Library/LaunchAgents/com.review-agent.seeder.plist" ] && \
  WATCHER_ARTIFACTS+=("launchd: $OC_HOME/Library/LaunchAgents/com.review-agent.seeder.plist")
[ -f "$SEEDER_SCRIPT" ] && \
  WATCHER_ARTIFACTS+=("script: $SEEDER_SCRIPT")
RUNNING_COUNT=$(pgrep -f review-agent-seeder.sh 2>/dev/null | wc -l | tr -d ' ')
if [ "$RUNNING_COUNT" -gt 0 ]; then
  WATCHER_ARTIFACTS+=("running process(es): $RUNNING_COUNT")
fi

# ─── enumerate peer dirs that BELONG to review-agent ──────────────────
# Convention: feishu-* peers are review-agent's (review-agent is the only
# v2 skill that uses dynamicAgentCreation on feishu). v1 used the
# feishu-dm-* prefix.
#
# wecom-* is shared territory (memoirist also runs on wecom on shared
# installs), so we ONLY include wecom peers with our `.review-agent-seeded`
# marker file. memoirist-only wecom peers stay untouched.
peer_workspaces() {
  ls -d "$OC_HOME/.openclaw/"workspace-feishu-* 2>/dev/null || true
  ls -d "$OC_HOME/.openclaw/"workspace-feishu-dm-* 2>/dev/null || true
  for w in "$OC_HOME/.openclaw/"workspace-wecom-*; do
    [ -d "$w" ] && [ -f "$w/.review-agent-seeded" ] && echo "$w" || true
  done
  return 0
}
peer_agents() {
  ls -d "$OC_HOME/.openclaw/agents/"feishu-* 2>/dev/null || true
  ls -d "$OC_HOME/.openclaw/agents/"feishu-dm-* 2>/dev/null || true
  for w in "$OC_HOME/.openclaw/"workspace-wecom-*; do
    if [ -d "$w" ] && [ -f "$w/.review-agent-seeded" ]; then
      AID="$(basename "$w" | sed 's/workspace-//')"
      [ -d "$OC_HOME/.openclaw/agents/$AID" ] && echo "$OC_HOME/.openclaw/agents/$AID"
    fi
  done
  return 0
}

PEER_DIRS=$(peer_workspaces | sort -u)
PEER_AGENTS=$(peer_agents | sort -u)
PEER_COUNT=$(printf "%s\n" "$PEER_DIRS" | sed '/^$/d' | wc -l | tr -d ' ')
AGENT_COUNT=$(printf "%s\n" "$PEER_AGENTS" | sed '/^$/d' | wc -l | tr -d ' ')

# ─── dry-run preview ──────────────────────────────────────────────────
echo -e "${BLUE}Will remove:${NC}"
[ -d "$SKILL" ]    && echo "  ✓ skill      $SKILL"         || echo "  (no skill dir)"
[ -d "$TEMPLATE" ] && echo "  ✓ template   $TEMPLATE"      || echo "  (no template dir)"

if [ ${#WATCHER_ARTIFACTS[@]} -gt 0 ]; then
  echo -e "${BLUE}Watcher artifacts:${NC}"
  for art in "${WATCHER_ARTIFACTS[@]}"; do echo "  ✓ $art"; done
else
  echo "  (no watcher artifacts detected)"
fi

if [ $PURGE -eq 1 ]; then
  echo -e "${RED}  ✓ (PURGE) global:   $GLOBAL${NC}"
  echo -e "${RED}  ✓ (PURGE) peers:    $PEER_COUNT workspace(s)${NC}"
  [ $PEER_COUNT -gt 0 ] && printf "%s\n" "$PEER_DIRS" | sed 's/^/      - /' | head -10
  echo -e "${RED}  ✓ (PURGE) agents:   $AGENT_COUNT review-agent peer agent dir(s)${NC}"
  echo -e "${RED}  ✓ (PURGE) bindings: openclaw.json bindings whose agentId is a removed peer${NC}"
  [ "$(id -u)" = "0" ] && [ -d /root/.review-agent ] && \
    echo -e "${RED}  ✓ (PURGE) v1 leftovers: /root/.review-agent${NC}"
else
  [ -d "$GLOBAL" ] && echo "  (--purge not set) keeping global config: $GLOBAL"
  [ $PEER_COUNT -gt 0 ] && echo "  (--purge not set) keeping $PEER_COUNT peer workspace(s)"
fi

if [ $REVERT -eq 1 ]; then
  echo "  ✓ (revert-config) unset channels.feishu.dynamicAgentCreation"
  echo "                    + legacy: dynamicAgents / dm.createAgentOnFirstMessage / workspaceTemplate"
else
  echo "  (--revert-config not set) leaving openclaw.json knobs as-is"
fi

echo
if [ $YES -ne 1 ]; then
  echo -e "${YELLOW}(dry-run — use --yes to actually remove)${NC}"
  exit 0
fi

# ─── consolidated openclaw.json snapshot ──────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
if [ -f "$OPENCLAW_JSON" ] && [ $(($PURGE + $REVERT)) -gt 0 ]; then
  oc_run cp "$OPENCLAW_JSON" "$OPENCLAW_JSON.bak.uninstall-$TS"
  echo -e "${GREEN}✓${NC} snapshot: $OPENCLAW_JSON.bak.uninstall-$TS"
fi

# ─── 1. tear down watcher BEFORE removing files ───────────────────────
echo -e "${BLUE}─── tearing down watcher ───${NC}"
if [ -f "$SCRIPT_DIR/setup_watcher.sh" ]; then
  bash "$SCRIPT_DIR/setup_watcher.sh" --uninstall --target-user "$TARGET_USER" 2>&1 | sed 's/^/  /'
else
  # Inline teardown — covers all 4 install modes
  if [ "$(uname)" = "Darwin" ]; then
    launchctl bootout gui/$UID/com.review-agent.seeder 2>/dev/null || \
      launchctl unload "$OC_HOME/Library/LaunchAgents/com.review-agent.seeder.plist" 2>/dev/null
    rm -f "$OC_HOME/Library/LaunchAgents/com.review-agent.seeder.plist"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if [ -f /etc/systemd/system/review-agent-seeder.service ]; then
      systemctl disable --now review-agent-seeder.service 2>/dev/null || true
      rm -f /etc/systemd/system/review-agent-seeder.service
      systemctl daemon-reload 2>/dev/null || true
    fi
    if [ -f "$OC_HOME/.config/systemd/user/review-agent-seeder.service" ]; then
      oc_run systemctl --user disable --now review-agent-seeder.service 2>/dev/null || true
      oc_run rm -f "$OC_HOME/.config/systemd/user/review-agent-seeder.service"
      oc_run systemctl --user daemon-reload 2>/dev/null || true
    fi
  fi
  pkill -f review-agent-seeder.sh 2>/dev/null || true
fi
oc_run rm -f "$SEEDER_SCRIPT" "$SEEDER_LOG"
echo -e "  ${GREEN}✓${NC} watcher teardown complete"

# ─── 2. remove skill + template ───────────────────────────────────────
echo -e "${BLUE}─── removing skill + template ───${NC}"
[ -d "$SKILL" ]    && oc_run rm -rf "$SKILL"    && echo -e "  ${GREEN}✓${NC} removed $SKILL"
[ -d "$TEMPLATE" ] && oc_run rm -rf "$TEMPLATE" && echo -e "  ${GREEN}✓${NC} removed $TEMPLATE"

# ─── 3. --purge: global + peers + bindings + v1 leftovers ─────────────
if [ $PURGE -eq 1 ]; then
  echo -e "${BLUE}─── purging global config + peer data ───${NC}"
  [ -d "$GLOBAL" ] && oc_run rm -rf "$GLOBAL" && \
    echo -e "  ${GREEN}✓${NC} removed $GLOBAL"

  # Capture removed agent IDs BEFORE deletion (needed for binding cleanup)
  REMOVED_AGENT_IDS=()
  while IFS= read -r ad; do
    [ -z "$ad" ] && continue
    REMOVED_AGENT_IDS+=("$(basename "$ad")")
  done <<< "$PEER_AGENTS"

  # Remove peer workspaces (v1 + v2 patterns)
  removed_w=0
  while IFS= read -r w; do
    [ -z "$w" ] && continue
    [ -d "$w" ] && oc_run rm -rf "$w" && removed_w=$((removed_w+1))
  done <<< "$PEER_DIRS"
  [ $removed_w -gt 0 ] && echo -e "  ${GREEN}✓${NC} removed $removed_w peer workspace(s)"

  # Remove peer agent dirs
  removed_a=0
  while IFS= read -r ad; do
    [ -z "$ad" ] && continue
    [ -d "$ad" ] && oc_run rm -rf "$ad" && removed_a=$((removed_a+1))
  done <<< "$PEER_AGENTS"
  [ $removed_a -gt 0 ] && echo -e "  ${GREEN}✓${NC} removed $removed_a peer agent dir(s)"

  # v1 leftovers
  if [ "$(id -u)" = "0" ] && [ -d /root/.review-agent ]; then
    rm -rf /root/.review-agent
    echo -e "  ${GREEN}✓${NC} removed /root/.review-agent (v1 leftovers)"
  fi

  # Bindings cleanup — TIGHT filter: only remove bindings whose agentId
  # is in the list of agent dirs we just removed. Prevents nuking the
  # admin → main binding (which is feishu-DM-shaped but NOT review-agent
  # specific in agentId).
  if [ -f "$OPENCLAW_JSON" ] && [ ${#REMOVED_AGENT_IDS[@]} -gt 0 ]; then
    REMOVED_AGENTS_JSON=$(printf '%s\n' "${REMOVED_AGENT_IDS[@]}" | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
    oc_run python3 - "$OPENCLAW_JSON" "$REMOVED_AGENTS_JSON" <<'PYEOF'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
removed_agents = set(json.loads(sys.argv[2]))
d = json.loads(p.read_text())
old = d.get('bindings', [])
new = [b for b in old if b.get('agentId') not in removed_agents]
# Also drop agents.list entries for removed agents
agents_list = d.get('agents', {}).get('list', [])
new_list = [a for a in agents_list if a.get('id') not in removed_agents]
d['bindings'] = new
if 'agents' in d and 'list' in d['agents']:
    d['agents']['list'] = new_list
p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
print(f'  removed {len(old) - len(new)} binding(s) and {len(agents_list) - len(new_list)} agents.list entr{"y" if (len(old)-len(new)+len(agents_list)-len(new_list))==1 else "ies"} (matched: {", ".join(sorted(removed_agents))[:200]})')
PYEOF
  fi
fi

# ─── 4. --revert-config ───────────────────────────────────────────────
if [ $REVERT -eq 1 ]; then
  echo -e "${BLUE}─── reverting openclaw.json knobs ───${NC}"
  oc_run python3 - "$OPENCLAW_JSON" <<'PYEOF'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    raise SystemExit(0)
d = json.loads(p.read_text())
feishu = d.get('channels', {}).get('feishu', {})
removed = []
# v2 canonical key (current)
if 'dynamicAgentCreation' in feishu:
    del feishu['dynamicAgentCreation']
    removed.append('dynamicAgentCreation')
# v2.0/2.1.0 legacy mistaken keys
if 'dynamicAgents' in feishu:
    del feishu['dynamicAgents']
    removed.append('dynamicAgents')
if isinstance(feishu.get('dm'), dict):
    if 'createAgentOnFirstMessage' in feishu['dm']:
        del feishu['dm']['createAgentOnFirstMessage']
        removed.append('dm.createAgentOnFirstMessage')
    if not feishu['dm']:
        del feishu['dm']
if isinstance(feishu.get('workspaceTemplate'), str) and feishu['workspaceTemplate'].endswith('/review-agent'):
    del feishu['workspaceTemplate']
    removed.append('workspaceTemplate')
if removed:
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
    print(f'  ✓ unset: {", ".join(removed)}')
else:
    print('  (nothing to revert — knobs already absent)')
PYEOF
fi

echo
echo -e "${GREEN}Done.${NC}"
echo "Restart openclaw for config changes to take effect:"
if [ "$(id -u)" = "0" ] && systemctl is-active openclaw >/dev/null 2>&1; then
  echo "  systemctl restart openclaw"
else
  echo "  openclaw gateway restart"
fi
