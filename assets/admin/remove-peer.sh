#!/bin/bash
# remove-peer.sh — fully de-enroll a Requester.
#
# Wipes:
#   1. ~/.openclaw/workspace-feishu-dm-<open_id>/
#   2. ~/.openclaw/agents/feishu-dm-<open_id>/
#   3. bindings entry in ~/.openclaw/openclaw.json
#
# Usage:
#   remove-peer.sh <open_id> [--dry-run] [--yes]
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $(basename "$0") <open_id> [--dry-run] [--yes]" >&2
  exit 1
fi

OID="$1"; shift
DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    *) echo "unknown: $1"; exit 1 ;;
  esac
done

WS="$HOME/.openclaw/workspace-feishu-dm-$OID"
AG="$HOME/.openclaw/agents/feishu-dm-$OID"

echo "Will remove:"
[ -d "$WS" ] && echo "  workspace: $WS" || echo "  (no workspace dir — already removed?)"
[ -d "$AG" ] && echo "  agent:     $AG" || echo "  (no agent dir)"
echo "  bindings entry for peer_id=$OID in openclaw.json"
echo

if [ $DRY -eq 1 ]; then
  echo "(dry-run; nothing removed)"
  exit 0
fi

if [ $YES -ne 1 ]; then
  read -rp "Proceed? [y/N] " a
  case "$a" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

[ -d "$WS" ] && rm -rf "$WS" && echo "✓ removed $WS"
[ -d "$AG" ] && rm -rf "$AG" && echo "✓ removed $AG"

# Remove bindings entry
python3 <<PYEOF
import json, shutil
from datetime import datetime
from pathlib import Path
p = Path.home() / '.openclaw' / 'openclaw.json'
d = json.loads(p.read_text())
before = len(d.get('bindings', []))
d['bindings'] = [
    b for b in d.get('bindings', [])
    if not (b.get('match', {}).get('channel') == 'feishu'
            and b.get('match', {}).get('peer', {}).get('id') == '$OID')
]
after = len(d['bindings'])
if before != after:
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    shutil.copy2(p, p.with_suffix(f'.json.bak.remove-peer-{ts}'))
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
    print(f'✓ removed {before - after} bindings entry/entries for $OID')
else:
    print('(no bindings entry to remove)')
PYEOF

echo
echo "Restart the gateway for changes to take effect:"
echo "  openclaw gateway restart"
