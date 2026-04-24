#!/bin/bash
# setup-responder.sh — edit the global responder profile that every peer
# workspace reads via symlink.
#
# Usage:
#   setup-responder.sh          # open in $EDITOR
#   setup-responder.sh --show   # cat the file
#   setup-responder.sh --reset  # restore the functional-default template
set -euo pipefail

GLOBAL_RA="$HOME/.openclaw/review-agent"
PROFILE="$GLOBAL_RA/responder-profile.md"
SKILL="$HOME/.openclaw/skills/review-agent"

if [ ! -f "$PROFILE" ]; then
  echo "error: $PROFILE not found."
  echo "  review-agent v2 not installed. Run install-openclaw.sh first."
  exit 2
fi

case "${1:-edit}" in
  --show|show) cat "$PROFILE" ;;
  --reset|reset)
    SRC="$SKILL/references/template/boss_profile.md"
    if [ ! -f "$SRC" ]; then
      echo "error: default profile not found at $SRC"; exit 3
    fi
    cp "$PROFILE" "$PROFILE.bak.$(date +%s)"
    cp "$SRC" "$PROFILE"
    echo "✓ responder-profile reset to default (backup written)"
    ;;
  --check|check)
    python3 "$SKILL/scripts/check-profile.py" "$PROFILE"
    ;;
  edit|*)
    : "${EDITOR:=vim}"
    $EDITOR "$PROFILE"
    python3 "$SKILL/scripts/check-profile.py" "$PROFILE" || true
    ;;
esac
