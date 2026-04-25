#!/bin/bash
# vps-doctor.sh — auto-diagnose + auto-fix every common review-agent issue.
# Run as root or as the openclaw user. Idempotent. No prompts.
#
# What it heals (each step is a no-op when state is already good):
#   1. global responder-profile.md present
#   2. template files: substitute {responder_name} + materialize owner.json
#   3. re-seed every existing peer workspace from fresh template
#   4. clear cached subagent sessions (prompt-cache stickiness)
#   5. patch openclaw.json: dynamicAgentCreation + admin→main binding +
#      sandbox.docker.binds collision auto-clear + legacy key cleanup
#   6. ensure peer-workspace seeder watcher is running
#   7. restart openclaw gateway
#
# Usage:
#   bash vps-doctor.sh                    # auto everything
#   RESPONDER_NAME=XiaEvie bash vps-doctor.sh  # override responder name
set -e
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

# ── detect target user + HOME ──
if [ "$(whoami)" = "root" ]; then
  if id openclaw >/dev/null 2>&1; then
    TARGET_USER="openclaw"
    HOME_OC="/home/openclaw"
    RUN="sudo -u openclaw -H"
  else
    TARGET_USER="root"
    HOME_OC="/root"
    RUN=""
  fi
else
  TARGET_USER="$(whoami)"
  HOME_OC="$HOME"
  RUN=""
fi

OC=$HOME_OC/.openclaw
TEMPLATE=$OC/workspace/templates/review-agent
GLOBAL_PROFILE=$OC/review-agent/responder-profile.md
ENABLED_JSON=$OC/review-agent/enabled.json

# ── find script dir for the patcher ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$SCRIPT_DIR/patch_openclaw_json.py"
SETUP_WATCHER="$SCRIPT_DIR/setup_watcher.sh"
[ ! -f "$PATCHER" ] && PATCHER="$OC/skills/review-agent/install/patch_openclaw_json.py"
[ ! -f "$SETUP_WATCHER" ] && SETUP_WATCHER="$OC/skills/review-agent/install/setup_watcher.sh"

# ── decide responder name + admin oid ──
ADMIN_NAME="${RESPONDER_NAME:-}"
ADMIN_OID=""
if [ -f "$ENABLED_JSON" ]; then
  ADMIN_OID=$($RUN python3 -c "import json; print(json.load(open('$ENABLED_JSON')).get('admin_open_id',''))" 2>/dev/null)
  [ -z "$ADMIN_NAME" ] && ADMIN_NAME=$($RUN python3 -c "import json; d=json.load(open('$ENABLED_JSON')); print(d.get('admin_display_name','') or d.get('responder_name',''))" 2>/dev/null)
fi
[ -z "$ADMIN_NAME" ] && ADMIN_NAME="Responder"

echo "─── review-agent VPS doctor ───"
echo "  user=$TARGET_USER  HOME=$HOME_OC"
echo "  responder_name=$ADMIN_NAME  admin_oid=${ADMIN_OID:-<unknown>}"
echo

# ── 1. global responder-profile.md ──
echo "─── 1. global responder-profile.md ───"
$RUN mkdir -p "$OC/review-agent"
if [ ! -f "$GLOBAL_PROFILE" ]; then
  $RUN bash -c "cat > $GLOBAL_PROFILE <<EOF
# Responder Profile
Name: $ADMIN_NAME
Decision style: data-first, fast yes/no
Pet peeves: vague asks, no numbers
Always asks: smallest version testable in a week? who disagrees?
EOF"
  echo "  ✓ created minimal default"
else
  echo "  ✓ exists"
fi

# ── 2. template substitution ──
echo "─── 2. template substitution ───"
if [ -d "$TEMPLATE" ]; then
  for f in SOUL.md AGENTS.md BOOTSTRAP.md HEARTBEAT.md IDENTITY.md USER.md; do
    [ -f "$TEMPLATE/$f" ] && $RUN sed -i.bak "s|{responder_name}|$ADMIN_NAME|g" "$TEMPLATE/$f" && $RUN rm -f "$TEMPLATE/$f.bak"
  done
  if [ -f "$TEMPLATE/owner.json.template" ] && [ ! -f "$TEMPLATE/owner.json" ]; then
    $RUN bash -c "cat > $TEMPLATE/owner.json <<EOF
{
  \"admin_open_id\": \"$ADMIN_OID\",
  \"admin_display_name\": \"$ADMIN_NAME\",
  \"responder_open_id\": \"$ADMIN_OID\",
  \"responder_name\": \"$ADMIN_NAME\"
}
EOF"
    $RUN rm -f "$TEMPLATE/owner.json.template"
  fi
  $RUN rm -f "$TEMPLATE/responder-profile.md.INSTALL_SHOULD_SYMLINK"
  $RUN bash -c "[ -L $TEMPLATE/responder-profile.md ] || (rm -f $TEMPLATE/responder-profile.md && ln -s $GLOBAL_PROFILE $TEMPLATE/responder-profile.md)"
  echo "  ✓ template ready"
else
  echo -e "  ${RED}✗${NC} no template at $TEMPLATE — install.sh first"
  exit 2
fi

# ── 3. re-seed every existing peer workspace from fresh template ──
echo "─── 3. re-seed existing peer workspaces ───"
SEEDED=0
for ws in "$OC"/workspace-feishu-* "$OC"/workspace-wecom-*; do
  [ -d "$ws" ] || continue
  # Skip admin's own workspace if it exists (admin → main, no peer)
  if [ -n "$ADMIN_OID" ] && [[ "$(basename $ws)" == *"$ADMIN_OID"* ]]; then
    echo "  ! removing admin's stale peer workspace: $(basename $ws)"
    $RUN rm -rf "$ws"
    continue
  fi
  $RUN cp -R "$TEMPLATE/." "$ws/" 2>/dev/null
  $RUN sed -i.bak "s|{responder_name}|$ADMIN_NAME|g" "$ws/SOUL.md" "$ws/AGENTS.md" "$ws/BOOTSTRAP.md" "$ws/HEARTBEAT.md" "$ws/IDENTITY.md" "$ws/USER.md" 2>/dev/null
  $RUN rm -f "$ws"/*.bak 2>/dev/null
  $RUN rm -f "$ws/owner.json.template"
  $RUN bash -c "[ -L $ws/responder-profile.md ] || (rm -f $ws/responder-profile.md && ln -s $GLOBAL_PROFILE $ws/responder-profile.md)"
  echo "  ✓ $ws"
  SEEDED=$((SEEDED+1))
done
[ $SEEDED -eq 0 ] && echo "  (no peer workspaces yet — watcher will seed on next DM)"

# ── 4. clear cached subagent sessions ──
echo "─── 4. clear subagent prompt-cache ───"
CLEARED=0
for ad in "$OC/agents/"feishu-* "$OC/agents/"wecom-*; do
  [ -d "$ad/sessions" ] || continue
  # Skip admin's own agent dir
  if [ -n "$ADMIN_OID" ] && [[ "$(basename $ad)" == *"$ADMIN_OID"* ]]; then
    $RUN rm -rf "$ad"
    continue
  fi
  $RUN bash -c "rm -f $ad/sessions/*.jsonl $ad/sessions/sessions.json $ad/sessions/*.lock 2>/dev/null"
  CLEARED=$((CLEARED+1))
done
echo "  ✓ cleared $CLEARED agent's session cache"

# ── 5. patch openclaw.json ──
echo "─── 5. patch openclaw.json ───"
if [ -f "$PATCHER" ]; then
  ARGS="--openclaw-home $HOME_OC --clear-bad-binds"
  [ -n "$ADMIN_OID" ] && ARGS="$ARGS --admin-open-id $ADMIN_OID"
  $RUN python3 "$PATCHER" $ARGS || true
else
  echo -e "  ${YELLOW}!${NC} patcher not found at $PATCHER — skipping"
fi

# ── 6. ensure watcher is running ──
echo "─── 6. ensure peer-workspace seeder watcher ───"
if [ -f "$SETUP_WATCHER" ]; then
  bash "$SETUP_WATCHER" --target-user "$TARGET_USER" 2>&1 | tail -5
else
  echo -e "  ${YELLOW}!${NC} setup_watcher.sh not found at $SETUP_WATCHER — skipping"
fi

# ── 7. restart openclaw ──
echo "─── 7. restart openclaw ───"
if [ "$(whoami)" = "root" ] && systemctl is-active openclaw >/dev/null 2>&1; then
  systemctl restart openclaw && echo "  ✓ restarted (system service)"
elif command -v openclaw >/dev/null 2>&1; then
  $RUN openclaw gateway restart 2>&1 | tail -3
else
  echo -e "  ${YELLOW}!${NC} restart manually: systemctl restart openclaw  OR  openclaw gateway restart"
fi

echo
echo -e "${GREEN}═══ DONE ═══${NC}"
echo
echo "Verify:"
echo "  1. As Admin, DM bot 'who are you' → expect main agent reply"
echo "  2. As a different user, DM bot a proposal → expect review-coach"
echo "  3. tail -F $OC/seeder.log               # watcher log"
echo "  4. journalctl -u openclaw -f            # gateway log (or ~/.openclaw/logs/gateway.log)"
