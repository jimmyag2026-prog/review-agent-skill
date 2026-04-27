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
  # Copy skill scripts into peer workspace as .skill/ — peer's docker
  # sandbox only mounts /workspace, so it can't see the host skill dir
  # at ~/.openclaw/skills/review-agent. We give each peer its own copy
  # so peer can call \`python3 .skill/<name>.py\` (relative path) in
  # both docker-sandboxed (vps) and non-sandboxed (mac dev) modes.
  SKILL_SRC="\$(dirname \$(dirname \$TPL))/skills/review-agent/scripts"
  if [ -d "\$SKILL_SRC" ]; then
    rm -rf "\$NEW/.skill"
    cp -R "\$SKILL_SRC" "\$NEW/.skill"
  fi
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
  # Marker so the polling loop / next sweep doesn't re-seed forever.
  # Critical: SOUL.md content can't be used as the marker because our SOUL.md
  # contains the literal openclaw-default phrases inside its "don't say this"
  # rule list — leading to infinite re-seed loops on every polling tick.
  : > "\$NEW/.review-agent-seeded"
  echo "\$(date -Iseconds) seeded \$NEW" >> "\$LOG"
}

# A peer needs seeding iff:
#   - dir name matches our pattern AND
#   - the .review-agent-seeded marker is absent AND
#   - SOUL.md is absent (fresh openclaw-created dir, before openclaw plants
#     its own default). If SOUL.md is already present without our marker,
#     it belongs to a DIFFERENT agent (e.g., memoirist on this user's mac
#     for wecom-dm-*), so we must NOT touch it. To force re-seed for a
#     pre-v2.2 review-agent peer, run vps-doctor.sh.
needs_seed() {
  local p="\$1"
  [ -d "\$p" ] || return 1
  case "\$(basename \$p)" in
    workspace-feishu-*|workspace-wecom-*) ;;
    *) return 1 ;;
  esac
  [ -f "\$p/.review-agent-seeded" ] && return 1
  [ -f "\$p/SOUL.md" ] && return 1
  return 0
}

# ─── Lark fetch broker ─────────────────────────────────────────────
# Peer subagents have no feishu_* tools (openclaw architectural restriction).
# When a Requester sends a Lark wiki/docx URL, peer's fetch-via-watcher.py
# writes a request file under <peer-workspace>/lark-fetch/<id>.request.json.
# We detect those, run lark_fetcher.py (which has access to openclaw.json
# credentials since we run as the openclaw user), and write the result
# back into peer's workspace. Credentials never enter peer's sandbox.
LARK_FETCHER="$TARGET_HOME/.openclaw/skills/review-agent/scripts/lark_fetcher.py"

process_lark_requests() {
  local req url req_dir out_fn err_fn out err
  for req in "\$WATCH_DIR"/workspace-feishu-*/lark-fetch/*.request.json \\
             "\$WATCH_DIR"/workspace-wecom-*/lark-fetch/*.request.json; do
    [ -f "\$req" ] || continue
    [ ! -f "\$LARK_FETCHER" ] && continue
    url=\$(python3 -c "import json; d=json.load(open('\$req')); print(d.get('url',''))" 2>/dev/null)
    # Filename-only fields (peer writes filenames; watcher resolves to host paths).
    out_fn=\$(python3 -c "import json; d=json.load(open('\$req')); print(d.get('out_filename',''))" 2>/dev/null)
    err_fn=\$(python3 -c "import json; d=json.load(open('\$req')); print(d.get('err_filename',''))" 2>/dev/null)
    req_dir=\$(dirname "\$req")
    out="\$req_dir/\$out_fn"
    err="\$req_dir/\$err_fn"
    if [ -z "\$url" ] || [ -z "\$out_fn" ]; then
      [ -n "\$err_fn" ] && echo "malformed request" > "\$err"
      rm -f "\$req"; continue
    fi
    # Use a TEMP err file. If subprocess succeeds, err is discarded;
    # if subprocess fails, move temp → final err. This avoids a race
    # where peer's poller sees an empty err file (created by stderr
    # redirect) before lark_fetcher finishes and treats it as failure.
    local tmp_err=\$(mktemp)
    if python3 "\$LARK_FETCHER" "\$url" "\$out" 2>"\$tmp_err"; then
      echo "\$(date -Iseconds) lark-fetched: \$url → \$out" >> "\$LOG"
      rm -f "\$tmp_err"
    else
      mv "\$tmp_err" "\$err"
      echo "\$(date -Iseconds) lark-fetch FAILED: \$url (see \$err)" >> "\$LOG"
    fi
    rm -f "\$req"
  done
}

# Initial sweep — handle peers created BEFORE watcher started
for p in "\$WATCH_DIR"/workspace-feishu-* "\$WATCH_DIR"/workspace-wecom-*; do
  needs_seed "\$p" && seed_one "\$p"
done

# Watch loop. Three backends in priority order:
#   1. inotifywait (linux) — event-driven for new dirs; lark fetch via 2s poll
#   2. fswatch (macOS, brew install fswatch) — same pattern
#   3. polling (universal fallback) — both in same loop

# Lark-fetch background poller runs in all modes (event-driven for dir
# creation works fine; for fetch requests inside existing dirs we'd need
# recursive inotify which is fragile, so just poll every 2s — request
# files are rare and small).
( while true; do process_lark_requests; sleep 2; done ) &

if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -m -e create --format %w%f "\$WATCH_DIR" 2>/dev/null | while read NEW; do
    seed_one "\$NEW"
  done
elif command -v fswatch >/dev/null 2>&1; then
  fswatch -0 --event=Created "\$WATCH_DIR" 2>/dev/null | while IFS= read -r -d "" NEW; do
    seed_one "\$NEW"
  done
else
  while true; do
    for p in "\$WATCH_DIR"/workspace-feishu-* "\$WATCH_DIR"/workspace-wecom-*; do
      needs_seed "\$p" && seed_one "\$p"
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
