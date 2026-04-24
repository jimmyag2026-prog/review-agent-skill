#!/bin/bash
# migrate-v1-to-v2.sh — one-shot migration from hermes review-agent v1 to openclaw v2.
#
# Preserves everything that matters: each user's profile, session history,
# active sessions, and logs. Does not touch v1 source; only reads from
# ~/.review-agent/ and writes to ~/.openclaw/.
#
# Usage:
#   migrate-v1-to-v2.sh [--dry-run] [--yes]
#
# Assumes install-openclaw.sh has already run (so skill + template are in place).
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown: $1"; exit 1 ;;
  esac
done

V1_ROOT="${REVIEW_AGENT_ROOT:-$HOME/.review-agent}"
OC_ROOT="$HOME/.openclaw"
V2_TEMPLATE="$OC_ROOT/workspace/templates/review-agent"
V2_GLOBAL_RA="$OC_ROOT/review-agent"

# Sanity
if [ ! -d "$V1_ROOT/users" ]; then
  echo -e "${YELLOW}!${NC} No v1 install found at $V1_ROOT — nothing to migrate."
  exit 0
fi
if [ ! -d "$V2_TEMPLATE" ]; then
  echo -e "${RED}error:${NC} v2 not installed ($V2_TEMPLATE missing)."
  echo "  Run openclaw-v2/install/install-openclaw.sh first (install phase is enough)."
  exit 2
fi

USERS=("$V1_ROOT"/users/*)
echo -e "${BLUE}Migration plan:${NC}"
echo "  v1 source: $V1_ROOT"
echo "  v2 target: $OC_ROOT/workspace-feishu-dm-<open_id>/"
echo

N_USERS=0; N_REQUESTERS=0; N_SESSIONS=0
for U in "${USERS[@]}"; do
  [ -d "$U" ] || continue
  OID=$(basename "$U")
  META="$U/meta.json"
  [ -f "$META" ] || continue
  N_USERS=$((N_USERS+1))
  ROLE=$(python3 -c "import json; d=json.load(open('$META')); print(','.join(d.get('roles',[])))")
  SESSIONS=$(ls -d "$U"/sessions/* 2>/dev/null | wc -l | tr -d ' ')
  echo "  peer $OID  (roles=$ROLE, sessions=$SESSIONS)"
  case "$ROLE" in
    *Requester*) N_REQUESTERS=$((N_REQUESTERS+1)); N_SESSIONS=$((N_SESSIONS+SESSIONS)) ;;
  esac
done
echo
echo "Will migrate $N_REQUESTERS Requester(s), $N_SESSIONS session(s)."
echo "(Admin/Responder without Requester role don't need a per-peer workspace — they"
echo " live in the global \$V2_GLOBAL_RA.)"
echo

if [ $DRY -eq 1 ]; then echo "(dry-run; no writes)"; exit 0; fi
if [ $YES -ne 1 ]; then
  read -rp "Proceed? [y/N] " a
  case "$a" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

# Step 1: copy v1 global responder profile → v2 global (if not already set)
echo
echo -e "${BLUE}Step 1: Responder profile${NC}"
V1_RESPONDERS=()
for U in "${USERS[@]}"; do
  [ -d "$U" ] || continue
  META="$U/meta.json"
  [ -f "$META" ] || continue
  IS_RESP=$(python3 -c "import json; d=json.load(open('$META')); print('Y' if 'Responder' in d.get('roles',[]) else 'N')")
  if [ "$IS_RESP" = "Y" ]; then
    V1_RESPONDERS+=("$U")
  fi
done
if [ ${#V1_RESPONDERS[@]} -eq 1 ]; then
  RESP_U="${V1_RESPONDERS[0]}"
  RESP_PROFILE="$RESP_U/profile.md"
  if [ -f "$RESP_PROFILE" ]; then
    mkdir -p "$V2_GLOBAL_RA"
    if [ -f "$V2_GLOBAL_RA/responder-profile.md" ]; then
      echo "  $V2_GLOBAL_RA/responder-profile.md already exists — keeping v2 version"
      echo "  (v1 profile at $RESP_PROFILE — merge manually if needed)"
    else
      cp "$RESP_PROFILE" "$V2_GLOBAL_RA/responder-profile.md"
      echo -e "  ${GREEN}✓${NC} copied v1 profile to $V2_GLOBAL_RA/responder-profile.md"
    fi
  fi
elif [ ${#V1_RESPONDERS[@]} -gt 1 ]; then
  echo -e "  ${YELLOW}!${NC} v1 had multiple Responders (${#V1_RESPONDERS[@]}). v2 defaults to"
  echo "      single global responder profile. Merge manually into $V2_GLOBAL_RA/responder-profile.md"
else
  echo "  (no Responder found in v1 — using v2 default)"
fi

# Step 2: per-Requester workspace migration
echo
echo -e "${BLUE}Step 2: per-Requester workspaces${NC}"
BINDINGS_JSON="[]"
for U in "${USERS[@]}"; do
  [ -d "$U" ] || continue
  OID=$(basename "$U")
  META="$U/meta.json"
  [ -f "$META" ] || continue
  IS_REQ=$(python3 -c "import json; d=json.load(open('$META')); print('Y' if 'Requester' in d.get('roles',[]) else 'N')")
  [ "$IS_REQ" != "Y" ] && continue
  WS="$OC_ROOT/workspace-feishu-dm-$OID"
  if [ -d "$WS" ]; then
    echo -e "  ${YELLOW}!${NC} $WS already exists — skipping $OID (remove manually first if you want overwrite)"
    continue
  fi
  # Clone template
  cp -R "$V2_TEMPLATE" "$WS"
  # Copy over user-specific artifacts from v1
  [ -d "$U/sessions" ] && cp -R "$U/sessions" "$WS/sessions"
  [ -f "$U/active_session.json" ] && cp "$U/active_session.json" "$WS/active_session.json"
  [ -f "$U/owner.json" ] && cp "$U/owner.json" "$WS/owner.json.v1"
  # Write USER.md with peer info
  NAME=$(python3 -c "import json; d=json.load(open('$META')); print(d.get('display_name') or '')")
  cat > "$WS/USER.md" <<EOF
# USER.md · peer metadata (migrated from v1)

- **Peer open_id:** $OID
- **Peer display name:** $NAME
- **Channel:** feishu
- **Reviews against Responder:** ~/.openclaw/review-agent/responder-profile.md (global)
- **Migrated from v1 at:** $(date -Iseconds)
EOF
  echo -e "  ${GREEN}✓${NC} migrated $OID → $WS"
done

# Step 3: print bindings JSON to merge into openclaw.json
echo
echo -e "${BLUE}Step 3: bindings to add to openclaw.json${NC}"
python3 <<'PYEOF'
import json, os
v1 = os.path.expanduser(os.environ.get('REVIEW_AGENT_ROOT','~/.review-agent'))
users_dir = os.path.join(v1, 'users')
out = []
for oid in sorted(os.listdir(users_dir)) if os.path.isdir(users_dir) else []:
    meta_path = os.path.join(users_dir, oid, 'meta.json')
    if not os.path.exists(meta_path): continue
    try:
        m = json.load(open(meta_path))
    except: continue
    if 'Requester' in m.get('roles', []):
        out.append({
            'agentId': f'feishu-dm-{oid}',
            'match': {'channel': 'feishu', 'peer': {'kind': 'direct', 'id': oid}},
        })
print(json.dumps(out, indent=2, ensure_ascii=False))
PYEOF

echo
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Merge the JSON above into ~/.openclaw/openclaw.json under 'bindings' key"
echo "     (or re-run install-openclaw.sh --enable-only to refresh everything)"
echo "  2. openclaw gateway restart"
echo "  3. Verify in dashboard: python3 openclaw-v2/admin/dashboard-server.py"
echo "  4. Once verified, you can decommission v1:"
echo "       hermes gateway stop"
echo "       # optionally: rm -rf ~/.review-agent (IRREVERSIBLE — back up sessions first)"
