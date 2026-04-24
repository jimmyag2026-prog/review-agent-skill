#!/bin/bash
# install-openclaw.sh — one-shot install of review-agent v2 into openclaw.
#
# Two phases:
#   A. Install files (reversible, always runs)
#       - ~/.openclaw/skills/review-agent/            (shared skill)
#       - ~/.openclaw/workspace/templates/review-agent/  (per-peer template)
#       - ~/.openclaw/review-agent/responder-profile.md  (global profile)
#   B. Enable (opt-in prompt)
#       - Patch ~/.openclaw/openclaw.json channels.feishu knobs
#       - Seed Admin/Responder identity into workspace-template/owner.json
#       - Restart openclaw gateway
#
# Safe to re-run. No hermes required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

ADMIN_OID=""; ADMIN_NAME=""; RESPONDER_NAME=""
MODE="full"   # full | install-only | enable-only
SKIP_RESTART=0

while [ $# -gt 0 ]; do
  case "$1" in
    --admin-open-id) ADMIN_OID="$2"; shift 2 ;;
    --admin-name) ADMIN_NAME="$2"; shift 2 ;;
    --responder-name) RESPONDER_NAME="$2"; shift 2 ;;
    --install-only) MODE="install-only"; shift ;;
    --enable-only)  MODE="enable-only"; shift ;;
    --skip-restart) SKIP_RESTART=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done
ORIGINAL_ADMIN_OID="$ADMIN_OID"

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
banner() {
  echo; echo -e "${BLUE}════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════${NC}"
}

SKILL_DST="$HOME/.openclaw/skills/review-agent"
TEMPLATE_DST="$HOME/.openclaw/workspace/templates/review-agent"
GLOBAL_RA_DIR="$HOME/.openclaw/review-agent"

phase_install() {
  banner "Phase A · Prereq check"
  if ! bash "$SCRIPT_DIR/check_prereqs.sh"; then
    echo -e "${RED}→ fix blocking issues above and re-run.${NC}"; exit 2
  fi

  banner "Phase A · Install skill (${SKILL_DST})"
  mkdir -p "$(dirname "$SKILL_DST")"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude=".git" --exclude=".DS_Store" --exclude="install.sh" --exclude="check_prereqs.sh" --exclude="patch_openclaw_json.py" --exclude="assets" --exclude="docs" --exclude="README.md" \
          "$REPO_ROOT/" "$SKILL_DST/"
  else
    rm -rf "$SKILL_DST"; cp -R "$REPO_ROOT" "$SKILL_DST"
  fi
  chmod +x "$SKILL_DST"/scripts/*.py 2>/dev/null || true
  echo -e "${GREEN}✓${NC} skill installed"

  banner "Phase A · Install workspace template (${TEMPLATE_DST})"
  mkdir -p "$(dirname "$TEMPLATE_DST")"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude=".git" --exclude=".DS_Store" \
          "$REPO_ROOT/assets/workspace-template/review-agent/" "$TEMPLATE_DST/"
  else
    rm -rf "$TEMPLATE_DST"; cp -R "$REPO_ROOT/assets/workspace-template/review-agent" "$TEMPLATE_DST"
  fi
  # Remove the install-only marker if present
  rm -f "$TEMPLATE_DST/responder-profile.md.INSTALL_SHOULD_SYMLINK"
  echo -e "${GREEN}✓${NC} template installed"

  banner "Phase A · Global responder profile (${GLOBAL_RA_DIR})"
  mkdir -p "$GLOBAL_RA_DIR"
  if [ ! -f "$GLOBAL_RA_DIR/responder-profile.md" ]; then
    # Seed from v1's functional-default profile
    if [ -f "$REPO_ROOT/references/template/boss_profile.md" ]; then
      cp "$REPO_ROOT/references/template/boss_profile.md" \
         "$GLOBAL_RA_DIR/responder-profile.md"
      echo -e "${GREEN}✓${NC} seeded responder-profile from functional default"
    else
      # fallback: placeholder
      cat > "$GLOBAL_RA_DIR/responder-profile.md" <<'EOF'
# Responder Profile (global)
# Edit this file to describe the Responder's review standards.
# Every peer workspace will symlink to here.
EOF
      echo -e "${YELLOW}!${NC} wrote placeholder responder-profile (no default found)"
    fi
  else
    echo -e "${YELLOW}!${NC} responder-profile.md already exists — left as-is"
  fi

  # Install symlink so every FUTURE template-clone inherits it.
  # openclaw copies the template dir; a symlink in the template → resolves
  # inside the cloned peer workspace to the absolute target. Make the symlink
  # absolute-target:
  ( cd "$TEMPLATE_DST" && rm -f responder-profile.md && \
    ln -s "$GLOBAL_RA_DIR/responder-profile.md" responder-profile.md )
  echo -e "${GREEN}✓${NC} template responder-profile.md → $GLOBAL_RA_DIR/responder-profile.md"

  echo
  echo -e "${GREEN}Phase A complete.${NC} Skill files are installed but openclaw is not yet wired."
}

phase_enable() {
  if [ ! -f "$SKILL_DST/SKILL.md" ]; then
    echo -e "${RED}error:${NC} skill not found at $SKILL_DST"
    echo "  run install.sh (without --enable-only) first"
    exit 2
  fi

  NON_INTERACTIVE=0
  [ -n "${ORIGINAL_ADMIN_OID:-}" ] && NON_INTERACTIVE=1

  banner "Phase B · Identify Admin + Responder"
  echo "Default: you are both Admin and Responder."

  if [ -z "$ADMIN_OID" ]; then
    echo
    echo "Tip: find your Lark open_id via 'openclaw pairing list' (feishu row)"
    echo
    openclaw pairing list 2>&1 | grep -i feishu | head -5 || true
    echo
    read -rp "Your Lark open_id (starts with 'ou_'): " ADMIN_OID
  fi
  if [ -z "$ADMIN_OID" ] || [[ ! "$ADMIN_OID" =~ ^ou_ ]]; then
    echo -e "${RED}error:${NC} open_id required, must start with 'ou_'"; exit 3
  fi
  [ -z "$ADMIN_NAME" ] && read -rp "Display name (blank for '$USER'): " ADMIN_NAME
  [ -z "$ADMIN_NAME" ] && ADMIN_NAME="$USER"
  [ -z "$RESPONDER_NAME" ] && RESPONDER_NAME="$ADMIN_NAME"

  # Seed owner.json into the template (every NEW peer workspace inherits it)
  cat > "$TEMPLATE_DST/owner.json" <<EOF
{
  "admin_open_id": "$ADMIN_OID",
  "admin_display_name": "$ADMIN_NAME",
  "responder_open_id": "$ADMIN_OID",
  "responder_name": "$RESPONDER_NAME",
  "note": "openclaw-managed. Rewrite by re-running install-openclaw.sh --enable-only."
}
EOF
  rm -f "$TEMPLATE_DST/owner.json.template"   # cleanup template marker
  echo -e "${GREEN}✓${NC} template owner.json seeded"

  # Replace {responder_name} in persona files at template level so the
  # cloned workspaces don't need a templating step
  for f in "$TEMPLATE_DST/SOUL.md" "$TEMPLATE_DST/AGENTS.md" "$TEMPLATE_DST/HEARTBEAT.md"; do
    [ -f "$f" ] && sed -i.bak "s|{responder_name}|$RESPONDER_NAME|g" "$f" && rm -f "$f.bak"
  done
  echo -e "${GREEN}✓${NC} persona files parameterized ({responder_name} → $RESPONDER_NAME)"

  banner "Phase B · Patch ~/.openclaw/openclaw.json"
  python3 "$SCRIPT_DIR/patch_openclaw_json.py"

  banner "Phase B · Profile sanity check"
  GPROFILE="$GLOBAL_RA_DIR/responder-profile.md"
  if [ -f "$GPROFILE" ]; then
    if ! python3 "$SKILL_DST/scripts/check-profile.py" "$GPROFILE"; then
      echo -e "${YELLOW}!${NC} The global responder-profile still has placeholders."
      echo "    Edit to personalize: vim $GPROFILE"
      echo "    Reviews work immediately but will be generic until you customize."
    fi
  fi

  # Enabled stamp
  mkdir -p "$GLOBAL_RA_DIR"
  cat > "$GLOBAL_RA_DIR/enabled.json" <<EOF
{
  "enabled_at": "$(date -Iseconds)",
  "skill_dst": "$SKILL_DST",
  "template_dst": "$TEMPLATE_DST",
  "admin_open_id": "$ADMIN_OID",
  "version": "2.0.0"
}
EOF

  # Gateway restart prompt
  if [ $SKIP_RESTART -eq 0 ] && [ $NON_INTERACTIVE -eq 0 ]; then
    echo
    read -rp "Restart openclaw gateway now? [Y/n] " ANS
    case "${ANS:-Y}" in
      n|N|no|NO) echo "  skipped. Run manually: openclaw gateway restart" ;;
      *)
        echo "  running: openclaw gateway restart"
        openclaw gateway restart 2>&1 | tail -5 \
          && echo -e "  ${GREEN}✓${NC} gateway restarted" \
          || echo -e "  ${YELLOW}!${NC} restart reported errors — check: openclaw gateway status"
        ;;
    esac
  elif [ $SKIP_RESTART -eq 0 ]; then
    echo
    echo "! Run: openclaw gateway restart"
  fi

  banner "Done — review-agent v2 ENABLED"
  cat <<EOF

${YELLOW}What happens next:${NC}

1. A new Requester DMs your Lark bot → openclaw auto-clones $TEMPLATE_DST
   to ~/.openclaw/workspace-feishu-dm-<open_id>/ and spawns a dedicated subagent
   for that peer.
2. The peer's subagent loads SOUL.md + AGENTS.md + your responder profile.
3. When the peer sends an attachment or /review start, the subagent invokes
   the review-agent skill's scripts in their own workspace.
4. Each peer is context-isolated from every other peer — no MEMORY.md SOP needed.

${BLUE}Edit your Responder profile${NC} (personalize the standards):
     vim $GLOBAL_RA_DIR/responder-profile.md

${BLUE}Dashboard${NC} (watch sessions across all peer workspaces):
     bash $REPO_ROOT/admin/dashboard-server.py

${BLUE}Docs${NC}: https://github.com/jimmyag2026-prog/review-agent

EOF
}

banner "review-agent v2 · install (openclaw)"

case "$MODE" in
  install-only)
    phase_install
    echo; echo "To enable later:"
    echo "     bash $SCRIPT_DIR/install-openclaw.sh --enable-only"
    ;;
  enable-only) phase_enable ;;
  full)
    phase_install
    if [ -n "${ORIGINAL_ADMIN_OID:-}" ]; then
      phase_enable
    else
      echo
      cat <<'INTRO'
━━━ About review-agent v2 (openclaw) ━━━

Review-agent is a CSW-style pre-meeting coach for Lark. In v2 each Requester
gets their OWN dedicated subagent with isolated context — no prompt-level
SOP routing. Your subordinates DM the bot, the agent runs four-pillar review
+ simulates how you'd react, walks them through Q&A until the brief is
signing-ready, then delivers a 6-section summary to both of you.

Three roles:
  • Admin     — you (manage config, responder profile)
  • Responder — whose review standards apply (you, by default)
  • Requester — submits drafts (auto-enrolled on first DM)

Requester commands (typed in Lark DM):
  /review start <主题>    开启 review
  /review end <理由>      结束当前 session
  /review status          看进度
  /review help            命令列表
  (发 PDF/文档/链接或长文本会自动启动 review；普通聊天不受影响)

━━━
INTRO
      read -rp "Enable review-agent now? [y/N] " ENABLE_NOW
      case "${ENABLE_NOW:-N}" in
        y|Y|yes|YES) phase_enable ;;
        *)
          echo
          echo "${YELLOW}Skipped.${NC}  Skill files installed but openclaw isn't wired yet."
          echo "When ready:  bash $SCRIPT_DIR/install-openclaw.sh --enable-only"
          ;;
      esac
    fi
    ;;
esac
