#!/bin/bash
# uninstall.sh — remove review-agent skill from openclaw.
#
# For the human Admin to run from the command line. Not invoked by subagents.
#
# What it removes:
#   ~/.openclaw/skills/review-agent/                 (the shared skill)
#   ~/.openclaw/workspace/templates/review-agent/    (per-peer workspace template)
#
# With --purge, ALSO removes:
#   ~/.openclaw/review-agent/                        (global responder profile + logs)
#   Every ~/.openclaw/workspace-feishu-dm-*/         (all per-peer sessions — IRREVERSIBLE)
#   ~/.openclaw/agents/feishu-dm-*/                  (per-peer subagent dirs)
#   Bindings entries in ~/.openclaw/openclaw.json for peers that used review-agent
#
# Reverts openclaw.json patches if --revert-config:
#   channels.feishu.dynamicAgents
#   channels.feishu.dm.createAgentOnFirstMessage
#   channels.feishu.workspaceTemplate
#   (Only unsets the three keys we set; other channels config untouched.)
#
# Usage:
#   uninstall.sh                    # dry-run equivalent — lists what it WOULD do
#   uninstall.sh --yes              # remove skill + template only
#   uninstall.sh --yes --revert-config   # also unset openclaw.json knobs
#   uninstall.sh --yes --purge      # also delete all peer workspaces + global data
#   uninstall.sh --yes --purge --revert-config   # full uninstall
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

YES=0; PURGE=0; REVERT=0
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --purge) PURGE=1 ;;
    --revert-config) REVERT=1 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown: $a"; exit 1 ;;
  esac
done

SKILL=$HOME/.openclaw/skills/review-agent
TEMPLATE=$HOME/.openclaw/workspace/templates/review-agent
GLOBAL=$HOME/.openclaw/review-agent

echo -e "${BLUE}Will remove:${NC}"
[ -d "$SKILL" ]    && echo "  ✓ skill      $SKILL"         || echo "  (no skill dir)"
[ -d "$TEMPLATE" ] && echo "  ✓ template   $TEMPLATE"      || echo "  (no template dir)"

PEER_COUNT=0; AGENT_COUNT=0
for w in "$HOME/.openclaw/"workspace-feishu-dm-*; do [ -d "$w" ] && PEER_COUNT=$((PEER_COUNT+1)); done
for a in "$HOME/.openclaw/agents/"feishu-dm-*;      do [ -d "$a" ] && AGENT_COUNT=$((AGENT_COUNT+1)); done

if [ $PURGE -eq 1 ]; then
  echo -e "${RED}  ✓ (PURGE) global:   $GLOBAL${NC}"
  echo -e "${RED}  ✓ (PURGE) peers:    $PEER_COUNT workspace-feishu-dm-*/ dir(s)${NC}"
  echo -e "${RED}  ✓ (PURGE) agents:   $AGENT_COUNT agents/feishu-dm-*/ dir(s)${NC}"
  echo -e "${RED}  ✓ (PURGE) bindings: review-agent peer entries in openclaw.json${NC}"
else
  [ -d "$GLOBAL" ] && echo "  (--purge not set) keeping global config: $GLOBAL"
  [ $PEER_COUNT -gt 0 ] && echo "  (--purge not set) keeping $PEER_COUNT peer workspace(s)"
fi

if [ $REVERT -eq 1 ]; then
  echo "  ✓ (revert-config) unset channels.feishu.dynamicAgents / dm.createAgentOnFirstMessage / workspaceTemplate"
else
  echo "  (--revert-config not set) leaving openclaw.json knobs as-is"
fi

echo

if [ $YES -ne 1 ]; then
  echo -e "${YELLOW}(dry-run — use --yes to actually remove)${NC}"
  exit 0
fi

# Remove files
[ -d "$SKILL" ]    && rm -rf "$SKILL"    && echo -e "${GREEN}✓${NC} removed $SKILL"
[ -d "$TEMPLATE" ] && rm -rf "$TEMPLATE" && echo -e "${GREEN}✓${NC} removed $TEMPLATE"

if [ $PURGE -eq 1 ]; then
  [ -d "$GLOBAL" ] && rm -rf "$GLOBAL" && echo -e "${GREEN}✓${NC} removed $GLOBAL"
  removed_w=0
  for w in "$HOME/.openclaw/"workspace-feishu-dm-*; do
    [ -d "$w" ] && rm -rf "$w" && removed_w=$((removed_w+1))
  done
  [ $removed_w -gt 0 ] && echo -e "${GREEN}✓${NC} removed $removed_w peer workspace(s)"
  removed_a=0
  for a in "$HOME/.openclaw/agents/"feishu-dm-*; do
    [ -d "$a" ] && rm -rf "$a" && removed_a=$((removed_a+1))
  done
  [ $removed_a -gt 0 ] && echo -e "${GREEN}✓${NC} removed $removed_a peer agent dir(s)"

  # Purge bindings
  python3 <<'PYEOF'
import json, shutil
from datetime import datetime
from pathlib import Path
p = Path.home() / '.openclaw' / 'openclaw.json'
if p.exists():
    d = json.loads(p.read_text())
    before = len(d.get('bindings', []))
    d['bindings'] = [
        b for b in d.get('bindings', [])
        if not (b.get('match', {}).get('channel') == 'feishu'
                and (b.get('match', {}).get('peer', {}).get('id', '') or '').startswith('ou_'))
    ]
    after = len(d['bindings'])
    if before != after:
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        shutil.copy2(p, p.with_suffix(f'.json.bak.uninstall-{ts}'))
        p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
        print(f'  ✓ removed {before - after} feishu peer binding(s)')
PYEOF
fi

if [ $REVERT -eq 1 ]; then
  python3 <<'PYEOF'
import json, shutil
from datetime import datetime
from pathlib import Path
p = Path.home() / '.openclaw' / 'openclaw.json'
if not p.exists():
    raise SystemExit(0)
d = json.loads(p.read_text())
feishu = d.get('channels', {}).get('feishu', {})
removed = []
if 'dynamicAgents' in feishu:
    del feishu['dynamicAgents']; removed.append('dynamicAgents')
if 'dm' in feishu:
    dm = feishu['dm']
    if 'createAgentOnFirstMessage' in dm:
        del dm['createAgentOnFirstMessage']
        removed.append('dm.createAgentOnFirstMessage')
    if not dm:
        del feishu['dm']
if feishu.get('workspaceTemplate', '').endswith('/review-agent'):
    del feishu['workspaceTemplate']; removed.append('workspaceTemplate')
if removed:
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    shutil.copy2(p, p.with_suffix(f'.json.bak.uninstall-revert-{ts}'))
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
    print('  ✓ unset:', ', '.join(removed))
else:
    print('  (nothing to revert — knobs already absent)')
PYEOF
fi

echo
echo -e "${GREEN}Done.${NC}"
echo "Restart openclaw for config changes to take effect:"
echo "  openclaw gateway restart"
