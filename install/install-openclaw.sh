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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
    rsync -a --delete --exclude=".git" --exclude=".DS_Store" \
          "$REPO_ROOT/skill/" "$SKILL_DST/"
  else
    rm -rf "$SKILL_DST"; cp -R "$REPO_ROOT/skill" "$SKILL_DST"
  fi
  chmod +x "$SKILL_DST"/scripts/*.py 2>/dev/null || true
  echo -e "${GREEN}✓${NC} skill installed"

  banner "Phase A · Install workspace template (${TEMPLATE_DST})"
  mkdir -p "$(dirname "$TEMPLATE_DST")"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude=".git" --exclude=".DS_Store" \
          "$REPO_ROOT/workspace-template/review-agent/" "$TEMPLATE_DST/"
  else
    rm -rf "$TEMPLATE_DST"; cp -R "$REPO_ROOT/workspace-template/review-agent" "$TEMPLATE_DST"
  fi
  # Remove the install-only marker if present
  rm -f "$TEMPLATE_DST/responder-profile.md.INSTALL_SHOULD_SYMLINK"
  echo -e "${GREEN}✓${NC} template installed"

  banner "Phase A · Global responder profile (${GLOBAL_RA_DIR})"
  mkdir -p "$GLOBAL_RA_DIR"
  if [ ! -f "$GLOBAL_RA_DIR/responder-profile.md" ]; then
    # Seed from v1's functional-default profile
    if [ -f "$REPO_ROOT/skill/references/template/boss_profile.md" ]; then
      cp "$REPO_ROOT/skill/references/template/boss_profile.md" \
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

  # ── Apply the openclaw source patch (seed workspace with our template) ──
  # Required for feishu dynamic agents to load review-coach persona instead
  # of openclaw's default memorist template.
  PATCHER="$SCRIPT_DIR/openclaw_patches/feishu_seed_workspace_patch.py"
  if [ -f "$PATCHER" ]; then
    banner "Phase B · Patch openclaw feishu seed (makes per-peer subagents load review-coach, not default)"
    python3 "$PATCHER" || echo -e "${YELLOW}!${NC} patcher had issues — subagents may fall back to memorist persona. See docs/FIELD_NOTES.md"
  fi

  banner "Done — review-agent v2 ENABLED"

  # ── Offer to DM the Admin a quickstart guide via Lark ──
  if [ $NON_INTERACTIVE -eq 0 ] && command -v curl >/dev/null 2>&1; then
    echo
    read -rp "DM you the post-install quickstart guide via Lark? [Y/n] " ANS
    case "${ANS:-Y}" in
      n|N|no|NO) : ;;
      *)
        # Try to send POST_INSTALL.md summary to admin via Lark Open API
        POST_INSTALL="$SKILL_DST/POST_INSTALL.md"
        APP_ID=$(grep ^FEISHU_APP_ID ~/.hermes/.env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | head -1)
        APP_SECRET=$(grep ^FEISHU_APP_SECRET ~/.hermes/.env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | head -1)
        if [ -z "$APP_ID" ]; then
          # Fallback to openclaw feishu config
          APP_ID=$(python3 -c "
import json
d = json.load(open('$HOME/.openclaw/openclaw.json'))
print(d.get('channels',{}).get('feishu',{}).get('accounts',{}).get('default',{}).get('appId',''))")
          APP_SECRET=$(python3 -c "
import json
d = json.load(open('$HOME/.openclaw/openclaw.json'))
print(d.get('channels',{}).get('feishu',{}).get('accounts',{}).get('default',{}).get('appSecret',''))")
        fi
        if [ -n "$APP_ID" ] && [ -n "$APP_SECRET" ] && [ -f "$POST_INSTALL" ]; then
          echo "  sending quickstart to your Lark DM (open_id=$ADMIN_OID)…"
          python3 <<PYEOF
import json, urllib.request
app_id, app_secret, admin_oid = "$APP_ID", "$APP_SECRET", "$ADMIN_OID"
# tenant token
r = urllib.request.urlopen(urllib.request.Request(
    "https://open.larksuite.com/open-apis/auth/v3/tenant_access_token/internal",
    data=json.dumps({"app_id": app_id, "app_secret": app_secret}).encode(),
    headers={"Content-Type":"application/json"}), timeout=10)
token = json.loads(r.read())["tenant_access_token"]
# Digest of POST_INSTALL.md as text (trim to ~1500 chars)
txt = open("$POST_INSTALL").read()
# First 1500 chars — enough for the checklist; full file lives on disk
msg = f"🔧 review-agent v2 安装完成\\n\\n全文见 ~/.openclaw/skills/review-agent/POST_INSTALL.md\\n\\n3 步 Admin checklist:\\n\\n1) 跑 openclaw seed patch:\\n   python3 ~/code/review-agent-skill/install/openclaw_patches/feishu_seed_workspace_patch.py\\n\\n2) 编辑你的 Responder profile:\\n   bash ~/code/review-agent-skill/assets/admin/setup-responder.sh\\n\\n3) openclaw gateway restart\\n\\n然后让一个 colleague DM 你的 bot 测试。gateway.log 看到 replies=1 就 OK。\\n\\n详细故障排查 + channel 兼容性 + uninstall 命令都在 POST_INSTALL.md 里。"
body = json.dumps({"receive_id": admin_oid, "msg_type":"text", "content": json.dumps({"text": msg})})
req = urllib.request.Request(
    "https://open.larksuite.com/open-apis/im/v1/messages?receive_id_type=open_id",
    data=body.encode(), headers={"Authorization":f"Bearer {token}","Content-Type":"application/json"})
try:
    r = urllib.request.urlopen(req, timeout=10)
    print("  ✓ quickstart DMed to your Lark")
except Exception as e:
    print(f"  ! DM failed (non-fatal): {e}")
PYEOF
        else
          echo "  (skipped — missing Lark app creds or POST_INSTALL.md)"
        fi
        ;;
    esac
  fi

  cat <<EOF

${YELLOW}Post-install checklist (full version in $SKILL_DST/POST_INSTALL.md):${NC}

${BLUE}1. Personalize Responder profile${NC} (10 min; bad defaults = generic reviews)
     vim $GLOBAL_RA_DIR/responder-profile.md

${BLUE}2. Grant Lark app scopes${NC} (for Lark wiki/doc pre-fetch to work):
     im:message, im:message:send_as_bot, docx:document, wiki:wiki:readonly,
     drive:file, drive:drive
     (Lark developer console → your app → Permissions)

${BLUE}3. Watch the dashboard${NC}:
     python3 $REPO_ROOT/admin/dashboard-server.py   # http://127.0.0.1:8765

${BLUE}4. First test${NC}: have a colleague DM your bot a proposal or Lark doc URL.
     In the gateway log you should see:
       creating dynamic agent "feishu-ou_..."
       review-agent: seeded
       dispatch complete (replies=1)

${BLUE}Channel compatibility${NC}:
  ✅ feishu / wecom → v2 full architecture (per-peer subagent)
  ❌ telegram / whatsapp / discord / slack / iMessage → fallback to shared
     main agent (no per-peer isolation). For those, consider hermes v1
     (https://github.com/jimmyag2026-prog/review-agent).

${BLUE}Full docs${NC}: https://github.com/jimmyag2026-prog/review-agent-skill/blob/main/POST_INSTALL.md

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
