#!/bin/bash
# setup_watcher.sh — install the review-agent peer-workspace seeder.
#
# Why: openclaw's `dynamicAgentCreation` creates an empty workspace on first
# DM. Without this watcher, the subagent loads openclaw's bundled "memorist"
# default persona (the "Hey I just came online" bootstrap) instead of our
# review-coach. The watcher polls/inotify-watches `~/.openclaw/` and as soon
# as a `workspace-feishu-<oid>/` (or `workspace-wecom-<oid>/`) appears, copies
# our review-agent template into it BEFORE openclaw seeds defaults
# (writeFileIfMissing means our files win).
#
# Auto-detects the right deployment mode:
#   1. Systemd SYSTEM service (root + /etc/systemd/system writable + service
#      will run as a non-root user) — used on VPS where openclaw runs as
#      a dedicated 'openclaw' user via system service.
#   2. Systemd USER service (default user install, `loginctl enable-linger`
#      survives ssh disconnect).
#   3. nohup fallback — when systemd is unavailable (macOS, WSL without
#      systemd, exotic distros). Writes a launchd plist on macOS.
#
# Watch mechanism: prefers `inotifywait` (event-driven, instant); falls back
# to a 2-second poll loop if inotify-tools is missing.
#
# Usage:
#   bash setup_watcher.sh                       # auto-detect + install
#   bash setup_watcher.sh --target-user openclaw  # explicit target user
#   bash setup_watcher.sh --uninstall
#   bash setup_watcher.sh --dry-run             # show what would happen
set -e

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

UNIT_NAME=review-agent-seeder
TARGET_USER=""
UNINSTALL=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target-user) TARGET_USER="$2"; shift 2 ;;
    --uninstall)   UNINSTALL=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown: $1"; exit 1 ;;
  esac
done

# ─── detect target user + their HOME ───
detect_target() {
  if [ -n "$TARGET_USER" ]; then
    echo "$TARGET_USER"; return
  fi
  # If running as root and 'openclaw' user exists, target it (VPS image)
  if [ "$(id -u)" = "0" ] && id openclaw >/dev/null 2>&1; then
    echo "openclaw"; return
  fi
  # Otherwise, current user
  whoami
}

TARGET_USER="$(detect_target)"
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
[ -z "$TARGET_HOME" ] && TARGET_HOME="$HOME"
TPL="$TARGET_HOME/.openclaw/workspace/templates/review-agent"
LOG="$TARGET_HOME/.openclaw/seeder.log"

# Run-as helper: when we're root targeting a non-root user, drop privileges
RUN_AS() {
  if [ "$(id -u)" = "0" ] && [ "$TARGET_USER" != "root" ]; then
    sudo -u "$TARGET_USER" -H "$@"
  else
    "$@"
  fi
}

echo "─── review-agent watcher installer ───"
echo "  target user: $TARGET_USER"
echo "  target HOME: $TARGET_HOME"
echo "  template:    $TPL"

# ─── pick deployment mode ───
detect_mode() {
  # macOS → launchd
  if [ "$(uname)" = "Darwin" ]; then echo "launchd"; return; fi
  # systemd available?
  if ! command -v systemctl >/dev/null 2>&1; then echo "nohup"; return; fi
  # If we're root and target is non-root → system service
  if [ "$(id -u)" = "0" ] && [ "$TARGET_USER" != "root" ]; then
    echo "systemd-system"; return
  fi
  # If user systemd is reachable
  if systemctl --user status >/dev/null 2>&1; then
    echo "systemd-user"; return
  fi
  echo "nohup"
}

MODE="$(detect_mode)"
echo "  install mode: $MODE"

# ─── install or uninstall ───
if [ $UNINSTALL -eq 1 ]; then
  echo "─── uninstall ───"
  case "$MODE" in
    systemd-system)
      [ $DRY_RUN -eq 0 ] && systemctl disable --now ${UNIT_NAME}.service 2>/dev/null
      [ $DRY_RUN -eq 0 ] && rm -f /etc/systemd/system/${UNIT_NAME}.service
      [ $DRY_RUN -eq 0 ] && systemctl daemon-reload
      ;;
    systemd-user)
      [ $DRY_RUN -eq 0 ] && RUN_AS systemctl --user disable --now ${UNIT_NAME}.service 2>/dev/null
      [ $DRY_RUN -eq 0 ] && RUN_AS rm -f "$TARGET_HOME/.config/systemd/user/${UNIT_NAME}.service"
      [ $DRY_RUN -eq 0 ] && RUN_AS systemctl --user daemon-reload 2>/dev/null
      ;;
    launchd)
      [ $DRY_RUN -eq 0 ] && launchctl unload "$TARGET_HOME/Library/LaunchAgents/com.review-agent.seeder.plist" 2>/dev/null
      [ $DRY_RUN -eq 0 ] && rm -f "$TARGET_HOME/Library/LaunchAgents/com.review-agent.seeder.plist"
      ;;
    nohup)
      [ $DRY_RUN -eq 0 ] && pkill -f "review-agent-seeder.sh" 2>/dev/null || true
      [ $DRY_RUN -eq 0 ] && rm -f "$TARGET_HOME/.openclaw/review-agent-seeder.sh"
      ;;
  esac
  echo -e "${GREEN}✓${NC} uninstalled ($MODE)"
  exit 0
fi

# ─── prereq checks ───
if [ ! -d "$TPL" ]; then
  echo -e "${RED}✗${NC} template not found at $TPL"
  echo "  install.sh first to install the workspace template"
  exit 2
fi

# ─── write seeder script (used by all modes) ───
SEEDER="$TARGET_HOME/.openclaw/review-agent-seeder.sh"
[ $DRY_RUN -eq 0 ] && RUN_AS mkdir -p "$TARGET_HOME/.openclaw"

# Heredoc with ALL vars escaped (template should be literal at runtime)
write_seeder() {
  cat > "$1" <<SEEDEREOF
#!/bin/bash
# review-agent-seeder — auto-generated by setup_watcher.sh. Do not edit.
TPL="$TPL"
LOG="$LOG"
WATCH_DIR="$TARGET_HOME/.openclaw"
GLOBAL_PROFILE="$TARGET_HOME/.openclaw/review-agent/responder-profile.md"

seed_one() {
  local NEW="\$1"
  case "\$(basename \$NEW)" in
    workspace-feishu-*|workspace-wecom-*) ;;
    *) return ;;
  esac
  [ -d "\$NEW" ] || return
  # Tight race: openclaw mkdir → writeFileIfMissing(memorist defaults) →
  # spawn subagent (reads SOUL.md). Our cp -R must land BEFORE subagent
  # spawn to avoid first-message memorist persona. 0.2s lets openclaw
  # finish its writeFileIfMissing batch (we overwrite anyway via cp -R),
  # while keeping the window tighter than a full second.
  sleep 0.2
  cp -R "\$TPL/." "\$NEW/" 2>/dev/null
  # Symlink global responder-profile if it exists
  if [ -f "\$GLOBAL_PROFILE" ]; then
    rm -f "\$NEW/responder-profile.md"
    ln -sf "\$GLOBAL_PROFILE" "\$NEW/responder-profile.md"
  fi
  # Substitute {responder_name} from owner.json if present
  if [ -f "\$NEW/owner.json" ] && command -v python3 >/dev/null 2>&1; then
    NAME=\$(python3 -c "import json; print(json.load(open('\$NEW/owner.json')).get('responder_name','Responder'))" 2>/dev/null)
    if [ -n "\$NAME" ]; then
      for f in SOUL.md AGENTS.md BOOTSTRAP.md HEARTBEAT.md IDENTITY.md USER.md; do
        [ -f "\$NEW/\$f" ] && sed -i.bak "s|{responder_name}|\$NAME|g" "\$NEW/\$f" && rm -f "\$NEW/\$f.bak"
      done
    fi
  fi
  # Clear stale session cache for this peer (prompt-cache won't stick to old persona)
  AGENT_DIR="\$(dirname \$NEW)/agents/\$(basename \$NEW | sed 's/workspace-//')"
  rm -f "\$AGENT_DIR/sessions/"*.jsonl "\$AGENT_DIR/sessions/sessions.json" "\$AGENT_DIR/sessions/"*.lock 2>/dev/null
  echo "\$(date -Iseconds) seeded \$NEW" >> "\$LOG"
}

# Initial sweep — handle peers created BEFORE watcher started
for p in "\$WATCH_DIR"/workspace-feishu-* "\$WATCH_DIR"/workspace-wecom-*; do
  [ -d "\$p" ] || continue
  # Only re-seed if SOUL.md missing or contains the openclaw default
  if [ ! -f "\$p/SOUL.md" ] || grep -q "I just came online\\|just woke up" "\$p/SOUL.md" 2>/dev/null; then
    seed_one "\$p"
  fi
done

# Watch loop — inotify if available, else 2s poll
if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -m -e create --format %w%f "\$WATCH_DIR" 2>/dev/null | while read NEW; do
    seed_one "\$NEW"
  done
else
  declare -A SEEN
  while true; do
    for p in "\$WATCH_DIR"/workspace-feishu-* "\$WATCH_DIR"/workspace-wecom-*; do
      [ -d "\$p" ] || continue
      if [ -z "\${SEEN[\$p]:-}" ]; then
        SEEN[\$p]=1
        seed_one "\$p"
      fi
    done
    sleep 2
  done
fi
SEEDEREOF
}

if [ $DRY_RUN -eq 0 ]; then
  TMP_SEEDER="$(mktemp)"
  write_seeder "$TMP_SEEDER"
  if [ "$(id -u)" = "0" ] && [ "$TARGET_USER" != "root" ]; then
    install -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$TMP_SEEDER" "$SEEDER"
  else
    install -m 755 "$TMP_SEEDER" "$SEEDER"
  fi
  rm -f "$TMP_SEEDER"
fi

echo "  ✓ seeder script: $SEEDER"

# ─── install per chosen mode ───
case "$MODE" in
  systemd-system)
    UNIT="/etc/systemd/system/${UNIT_NAME}.service"
    if [ $DRY_RUN -eq 0 ]; then
      cat > "$UNIT" <<UNITEOF
[Unit]
Description=review-agent peer-workspace template seeder
After=openclaw.service
PartOf=openclaw.service

[Service]
Type=simple
User=$TARGET_USER
ExecStart=/bin/bash $SEEDER
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
      systemctl daemon-reload
      systemctl enable --now ${UNIT_NAME}.service
    fi
    echo -e "${GREEN}✓${NC} systemd-system service installed"
    [ $DRY_RUN -eq 0 ] && systemctl status ${UNIT_NAME}.service --no-pager 2>&1 | head -6 || true
    ;;

  systemd-user)
    UNIT_DIR="$TARGET_HOME/.config/systemd/user"
    UNIT="$UNIT_DIR/${UNIT_NAME}.service"
    if [ $DRY_RUN -eq 0 ]; then
      RUN_AS mkdir -p "$UNIT_DIR"
      RUN_AS bash -c "cat > '$UNIT' <<UNITEOF
[Unit]
Description=review-agent peer-workspace template seeder
After=default.target

[Service]
Type=simple
ExecStart=/bin/bash $SEEDER
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNITEOF"
      RUN_AS systemctl --user daemon-reload
      RUN_AS systemctl --user enable --now ${UNIT_NAME}.service

      # Linger so it survives ssh disconnect
      if command -v loginctl >/dev/null 2>&1; then
        if ! loginctl show-user "$TARGET_USER" 2>/dev/null | grep -q Linger=yes; then
          if sudo -n true 2>/dev/null; then
            sudo loginctl enable-linger "$TARGET_USER"
            echo -e "${GREEN}✓${NC} loginctl linger enabled"
          else
            echo -e "${YELLOW}!${NC} for watcher to survive ssh disconnect:"
            echo "    sudo loginctl enable-linger $TARGET_USER"
          fi
        fi
      fi
    fi
    echo -e "${GREEN}✓${NC} systemd-user service installed"
    ;;

  launchd)
    PLIST="$TARGET_HOME/Library/LaunchAgents/com.review-agent.seeder.plist"
    if [ $DRY_RUN -eq 0 ]; then
      mkdir -p "$(dirname "$PLIST")"
      cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.review-agent.seeder</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SEEDER</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLISTEOF
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load "$PLIST"
    fi
    echo -e "${GREEN}✓${NC} launchd agent installed"
    ;;

  nohup)
    if [ $DRY_RUN -eq 0 ]; then
      pkill -f "review-agent-seeder.sh" 2>/dev/null || true
      RUN_AS nohup /bin/bash "$SEEDER" >/dev/null 2>&1 &
    fi
    echo -e "${GREEN}✓${NC} nohup background process started"
    echo -e "  ${YELLOW}!${NC} won't survive reboot. Add to your shell rc or use systemd if available."
    ;;
esac

echo
echo -e "${GREEN}done.${NC} watcher will seed review-coach into every new peer workspace."
echo "  log: $LOG"
echo
echo "Test: have a new feishu/wecom user DM your bot, then check:"
echo "    tail -3 $LOG"
echo "should show: <timestamp> seeded <path>"
echo
echo "Uninstall: bash $0 --uninstall"
