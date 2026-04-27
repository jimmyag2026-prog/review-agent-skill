#!/bin/bash
# install.sh — one-shot install of review-agent v2.2 into openclaw
# (standalone-skill-repo edition).
#
# Two phases:
#   A. Install files (reversible, always runs)
#       - $OC_HOME/.openclaw/skills/review-agent/
#       - $OC_HOME/.openclaw/workspace/templates/review-agent/
#       - $OC_HOME/.openclaw/review-agent/responder-profile.md
#   B. Enable (opt-in prompt)
#       - Patch openclaw.json: dynamicAgentCreation, admin → main binding,
#                              sandbox.docker.binds collision auto-fix
#       - Seed Admin/Responder identity into workspace-template/owner.json
#       - Install peer-workspace seeder watcher (systemd / launchd / nohup)
#       - Clear stale peer session caches
#       - Restart openclaw gateway
#
# Auto-detects: macOS vs linux, root vs user, system vs user systemd, and
# whether openclaw runs as a dedicated user (e.g. 'openclaw' on a VPS).
#
# Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

ADMIN_OID=""; ADMIN_NAME=""; RESPONDER_NAME=""
TARGET_USER=""
MODE="full"   # full | install-only | enable-only
SKIP_RESTART=0
SKIP_WATCHER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --admin-open-id)  ADMIN_OID="$2"; shift 2 ;;
    --admin-name)     ADMIN_NAME="$2"; shift 2 ;;
    --responder-name) RESPONDER_NAME="$2"; shift 2 ;;
    --target-user)    TARGET_USER="$2"; shift 2 ;;
    --install-only)   MODE="install-only"; shift ;;
    --enable-only)    MODE="enable-only"; shift ;;
    --skip-restart)   SKIP_RESTART=1; shift ;;
    --skip-watcher)   SKIP_WATCHER=1; shift ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# ─── detect target user + their HOME ───
if [ -z "$TARGET_USER" ]; then
  if [ "$(id -u)" = "0" ] && id openclaw >/dev/null 2>&1; then
    TARGET_USER="openclaw"
  else
    TARGET_USER="$(whoami)"
  fi
fi

if [ "$TARGET_USER" = "$(whoami)" ]; then
  OC_HOME="$HOME"
  RUN_AS=""
else
  OC_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
  if [ -z "$OC_HOME" ]; then
    echo "error: user '$TARGET_USER' not found"; exit 2
  fi
  RUN_AS="sudo -u $TARGET_USER -H"
fi

SKILL_DST="$OC_HOME/.openclaw/skills/review-agent"
TEMPLATE_DST="$OC_HOME/.openclaw/workspace/templates/review-agent"
GLOBAL_RA_DIR="$OC_HOME/.openclaw/review-agent"

oc_run() { if [ -n "$RUN_AS" ]; then $RUN_AS "$@"; else "$@"; fi; }

phase_install() {
  banner "Phase A · Prereq check"
  if ! OPENCLAW_HOME="$OC_HOME" bash "$REPO_ROOT/check_prereqs.sh"; then
    echo -e "${RED}→ fix blocking issues above and re-run.${NC}"; exit 2
  fi

  banner "Phase A · Install skill (${SKILL_DST})"
  oc_run mkdir -p "$(dirname "$SKILL_DST")"
  # Copy the skill — exclude install/ops scripts and assets (they belong in
  # the repo, not in the deployed skill dir)
  if command -v rsync >/dev/null 2>&1; then
    oc_run rsync -a --delete \
          --exclude=".git" --exclude=".DS_Store" \
          --exclude="install.sh" --exclude="setup_watcher.sh" \
          --exclude="check_prereqs.sh" --exclude="patch_openclaw_json.py" \
          --exclude="vps-doctor.sh" --exclude="openclaw_patches" \
          --exclude="assets" --exclude="docs" --exclude="README.md" \
          --exclude="CHANGELOG.md" \
          "$REPO_ROOT/" "$SKILL_DST/"
  else
    oc_run rm -rf "$SKILL_DST"; oc_run mkdir -p "$SKILL_DST"
    for item in SKILL.md VERSION POST_INSTALL.md uninstall.sh update.sh scripts references; do
      [ -e "$REPO_ROOT/$item" ] && oc_run cp -R "$REPO_ROOT/$item" "$SKILL_DST/"
    done
  fi
  oc_run chmod +x "$SKILL_DST"/scripts/*.py 2>/dev/null || true
  echo -e "${GREEN}✓${NC} skill installed"

  banner "Phase A · Install workspace template (${TEMPLATE_DST})"
  oc_run mkdir -p "$(dirname "$TEMPLATE_DST")"
  if command -v rsync >/dev/null 2>&1; then
    oc_run rsync -a --delete --exclude=".git" --exclude=".DS_Store" \
          "$REPO_ROOT/assets/workspace-template/review-agent/" "$TEMPLATE_DST/"
  else
    oc_run rm -rf "$TEMPLATE_DST"
    oc_run cp -R "$REPO_ROOT/assets/workspace-template/review-agent" "$TEMPLATE_DST"
  fi
  oc_run rm -f "$TEMPLATE_DST/responder-profile.md.INSTALL_SHOULD_SYMLINK"
  echo -e "${GREEN}✓${NC} template installed"

  banner "Phase A · Global responder profile (${GLOBAL_RA_DIR})"
  oc_run mkdir -p "$GLOBAL_RA_DIR"
  if [ ! -f "$GLOBAL_RA_DIR/responder-profile.md" ]; then
    if [ -f "$REPO_ROOT/references/template/boss_profile.md" ]; then
      oc_run cp "$REPO_ROOT/references/template/boss_profile.md" \
                "$GLOBAL_RA_DIR/responder-profile.md"
      echo -e "${GREEN}✓${NC} seeded responder-profile from default"
    else
      oc_run bash -c "cat > '$GLOBAL_RA_DIR/responder-profile.md' <<'EOF'
# Responder Profile (global)
# Edit to describe the Responder's review standards.
EOF"
      echo -e "${YELLOW}!${NC} wrote placeholder responder-profile"
    fi
  else
    echo -e "${YELLOW}!${NC} responder-profile.md already exists — left as-is"
  fi

  oc_run bash -c "cd '$TEMPLATE_DST' && rm -f responder-profile.md && \
    ln -s '$GLOBAL_RA_DIR/responder-profile.md' responder-profile.md"
  echo -e "${GREEN}✓${NC} template responder-profile.md → global"

  echo
  echo -e "${GREEN}Phase A complete.${NC} Skill files installed; openclaw not yet wired."
  echo
  echo -e "${YELLOW}Heads-up — Phase B will ask for your Lark open_id (ou_xxx).${NC}"
  echo "If you don't already know it, the easiest way:"
  echo "  1. In Lark, DM your bot a single message ('hi' is fine)"
  echo "  2. Phase B will auto-detect it from the gateway log"
  echo "(if you DM AFTER Phase B has already prompted, ctrl-C and re-run"
  echo " 'bash install.sh --enable-only')"
}

# ─── Admin open_id discovery (interactive) ───
discover_admin_oid() {
  local LOGFILE
  for cand in \
    "/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log" \
    "$OC_HOME/.openclaw/logs/gateway.log" \
    ; do
    if [ -r "$cand" ]; then LOGFILE="$cand"; break; fi
  done
  local recent_oids=""
  if [ -n "${LOGFILE:-}" ]; then
    recent_oids=$(grep -oE 'received message from ou_[a-f0-9]{32}' "$LOGFILE" 2>/dev/null | \
                  grep -oE 'ou_[a-f0-9]{32}' | sort -u | tail -5 || true)
  fi
  if [ -z "$recent_oids" ] && command -v journalctl >/dev/null 2>&1; then
    recent_oids=$(journalctl -u openclaw --no-pager --since "24 hours ago" 2>/dev/null | \
                  grep -oE 'received message from ou_[a-f0-9]{32}' | \
                  grep -oE 'ou_[a-f0-9]{32}' | sort -u | tail -5 || true)
  fi
  if [ -n "$recent_oids" ]; then
    echo "Recent feishu senders (from gateway log):"
    echo "$recent_oids" | sed 's/^/  /'
    echo
    echo "If yours is above, paste it below."
    echo "If not, ctrl-C now → DM bot once → re-run: bash install.sh --enable-only"
  else
    echo "No recent feishu DMs found in the gateway log."
    echo
    echo "Easiest way to surface your open_id:"
    echo "  1. ctrl-C to abort"
    echo "  2. In Lark, DM your bot 'hi' (anything works)"
    echo "  3. Re-run:  bash install.sh --enable-only"
    echo "     The script will auto-detect your open_id from the log."
    echo
    echo "Or paste your open_id directly below if you already know it."
  fi
}

phase_enable() {
  if [ ! -f "$SKILL_DST/SKILL.md" ]; then
    echo -e "${RED}error:${NC} skill not found at $SKILL_DST"
    echo "  run install.sh (without --enable-only) first"
    exit 2
  fi

  NON_INTERACTIVE=0
  [ -n "${ORIGINAL_ADMIN_OID:-}" ] && NON_INTERACTIVE=1

  banner "Phase B · Identify Admin"
  echo "Admin = the person who owns this bot."
  echo "Admin DMs go to the MAIN openclaw agent (chat/admin), not the review subagent."
  echo "Other Lark users (Requesters) get per-peer review-coach subagents."
  echo

  if [ -z "$ADMIN_OID" ]; then
    discover_admin_oid
    echo
    read -rp "Admin's Lark open_id (ou_xxx): " ADMIN_OID
  fi
  if [ -z "$ADMIN_OID" ] || [[ ! "$ADMIN_OID" =~ ^ou_ ]]; then
    echo -e "${RED}error:${NC} open_id required, must start with 'ou_'"; exit 3
  fi

  [ -z "$ADMIN_NAME" ] && read -rp "Admin display name [$TARGET_USER]: " ADMIN_NAME
  [ -z "$ADMIN_NAME" ] && ADMIN_NAME="$TARGET_USER"

  echo
  echo "Responder = the person whose review style the agent simulates."
  echo "(Often the same as Admin, but can differ — e.g. you operate the bot, but"
  echo " the agent reviews proposals as if your CEO were reviewing them.)"
  [ -z "$RESPONDER_NAME" ] && read -rp "Responder name [$ADMIN_NAME]: " RESPONDER_NAME
  [ -z "$RESPONDER_NAME" ] && RESPONDER_NAME="$ADMIN_NAME"

  banner "Phase B · Seed identity into template (${TEMPLATE_DST})"
  oc_run bash -c "cat > '$TEMPLATE_DST/owner.json' <<EOF
{
  \"admin_open_id\": \"$ADMIN_OID\",
  \"admin_display_name\": \"$ADMIN_NAME\",
  \"responder_open_id\": \"$ADMIN_OID\",
  \"responder_name\": \"$RESPONDER_NAME\",
  \"note\": \"openclaw-managed. Re-run install.sh --enable-only to update.\"
}
EOF"
  oc_run rm -f "$TEMPLATE_DST/owner.json.template"
  echo -e "${GREEN}✓${NC} template owner.json seeded"

  for f in SOUL.md AGENTS.md BOOTSTRAP.md HEARTBEAT.md IDENTITY.md USER.md; do
    [ -f "$TEMPLATE_DST/$f" ] && \
      oc_run sed -i.bak "s|{responder_name}|$RESPONDER_NAME|g" "$TEMPLATE_DST/$f" && \
      oc_run rm -f "$TEMPLATE_DST/$f.bak"
  done
  echo -e "${GREEN}✓${NC} {responder_name} → '$RESPONDER_NAME' in all persona files"

  # Also fix the global responder-profile.md so the LLM sees the actual name
  # in its system prompt (the bundled boss_profile.md template ships with
  # `Name: Responder` as a placeholder; without this substitution the agent
  # sees "I represent Jimmy" in SOUL.md but Name=Responder in the profile,
  # and hedges by calling the Responder "上级" / "your manager" instead of
  # using the actual name).
  GPROFILE="$GLOBAL_RA_DIR/responder-profile.md"
  if [ -f "$GPROFILE" ]; then
    oc_run sed -i.bak "s|^- \\*\\*Name\\*\\*: Responder$|- **Name**: $RESPONDER_NAME|" "$GPROFILE" && \
      oc_run rm -f "$GPROFILE.bak"
    echo -e "${GREEN}✓${NC} responder-profile.md Name → '$RESPONDER_NAME'"
  fi

  banner "Phase B · Patch openclaw.json"
  if [ -n "$RUN_AS" ]; then
    $RUN_AS python3 "$REPO_ROOT/patch_openclaw_json.py" \
      --admin-open-id "$ADMIN_OID" \
      --openclaw-home "$OC_HOME" \
      --clear-bad-binds
  else
    OPENCLAW_HOME="$OC_HOME" python3 "$REPO_ROOT/patch_openclaw_json.py" \
      --admin-open-id "$ADMIN_OID" \
      --openclaw-home "$OC_HOME" \
      --clear-bad-binds
  fi

  banner "Phase B · Profile sanity check"
  GPROFILE="$GLOBAL_RA_DIR/responder-profile.md"
  if [ -f "$GPROFILE" ] && [ -f "$SKILL_DST/scripts/check-profile.py" ]; then
    if ! oc_run python3 "$SKILL_DST/scripts/check-profile.py" "$GPROFILE" 2>/dev/null; then
      echo -e "${YELLOW}!${NC} responder-profile has placeholder content."
      echo "    Edit to personalize: vim $GPROFILE"
    fi
  fi

  if [ $SKIP_WATCHER -eq 0 ]; then
    banner "Phase B · Install peer-workspace seeder watcher"
    bash "$REPO_ROOT/setup_watcher.sh" --target-user "$TARGET_USER" || \
      echo -e "${YELLOW}!${NC} watcher install had issues — peer subagents may load openclaw default persona"

    # Health check: verify watcher is actually RUNNING (not just exited 0).
    # setup_watcher.sh can finish without starting the daemon if e.g.
    # `launchctl load` returned 0 but the service died immediately.
    sleep 2
    WATCHER_OK=0
    if [ "$(uname)" = "Darwin" ]; then
      # launchd: PID column is column 1; "-" means not running
      if launchctl list com.review-agent.seeder 2>/dev/null | grep -q '"PID"'; then
        WATCHER_OK=1
      fi
    elif command -v systemctl >/dev/null 2>&1; then
      # systemd: check unit is active
      if [ -n "$RUN_AS" ]; then
        $RUN_AS systemctl --user is-active review-agent-seeder >/dev/null 2>&1 && WATCHER_OK=1
        systemctl is-active review-agent-seeder >/dev/null 2>&1 && WATCHER_OK=1
      else
        systemctl --user is-active review-agent-seeder >/dev/null 2>&1 && WATCHER_OK=1
      fi
    else
      # nohup mode: check process by name
      pgrep -f review-agent-seeder.sh >/dev/null 2>&1 && WATCHER_OK=1
    fi

    if [ $WATCHER_OK -eq 1 ]; then
      echo -e "  ${GREEN}✓${NC} watcher running (will seed review-coach into new peer workspaces)"
    else
      echo -e "  ${RED}✗${NC} watcher installed but NOT running."
      echo "      Symptom: new Requester DMs will get 'Hey I just came online' instead"
      echo "      of review-coach. To diagnose:"
      echo "        bash $REPO_ROOT/setup_watcher.sh           # reinstall"
      echo "        bash $REPO_ROOT/vps-doctor.sh              # full self-heal"
      echo "        cat $OC_HOME/.openclaw/seeder.log          # see error logs"
    fi
  else
    echo -e "${YELLOW}!${NC} --skip-watcher: peer subagents will load openclaw default persona"
    echo "    Install later: bash $REPO_ROOT/setup_watcher.sh"
  fi

  banner "Phase B · Clear stale peer session caches"
  # Only clear review-agent peer sessions. On machines that share wecom
  # with memoirist (or any other agent), blindly globbing wecom-* would
  # wipe unrelated agent histories. Detect review-agent peers via the
  # .review-agent-seeded marker (or our SOUL.md content as fallback).
  CLEARED=0
  for ws in "$OC_HOME/.openclaw/"workspace-feishu-* "$OC_HOME/.openclaw/"workspace-wecom-*; do
    [ -d "$ws" ] || continue
    if [ ! -f "$ws/.review-agent-seeded" ] && \
       ! oc_run grep -q "review-agent\|pre-meeting review\|挑刺" "$ws/SOUL.md" 2>/dev/null; then
      continue
    fi
    AGENT_ID="$(basename $ws | sed 's/workspace-//')"
    AD="$OC_HOME/.openclaw/agents/$AGENT_ID"
    [ -d "$AD/sessions" ] || continue
    oc_run bash -c "rm -f '$AD/sessions/'*.jsonl '$AD/sessions/sessions.json' '$AD/sessions/'*.lock 2>/dev/null"
    CLEARED=$((CLEARED+1))
  done
  echo "  ✓ cleared $CLEARED review-agent peer session cache(s) (other agents untouched)"

  ADMIN_PEER_DIR="$OC_HOME/.openclaw/agents/feishu-${ADMIN_OID}"
  ADMIN_WS="$OC_HOME/.openclaw/workspace-feishu-${ADMIN_OID}"
  if [ -d "$ADMIN_PEER_DIR" ] || [ -d "$ADMIN_WS" ]; then
    echo "  ! admin had a stale peer subagent — removing"
    oc_run rm -rf "$ADMIN_PEER_DIR" "$ADMIN_WS"
  fi

  oc_run mkdir -p "$GLOBAL_RA_DIR"
  oc_run bash -c "cat > '$GLOBAL_RA_DIR/enabled.json' <<EOF
{
  \"enabled_at\": \"$(date -Iseconds)\",
  \"version\": \"$(cat $REPO_ROOT/VERSION 2>/dev/null || echo 'unknown')\",
  \"target_user\": \"$TARGET_USER\",
  \"openclaw_home\": \"$OC_HOME\",
  \"skill_dst\": \"$SKILL_DST\",
  \"template_dst\": \"$TEMPLATE_DST\",
  \"admin_open_id\": \"$ADMIN_OID\",
  \"admin_display_name\": \"$ADMIN_NAME\",
  \"responder_name\": \"$RESPONDER_NAME\"
}
EOF"

  if [ $SKIP_RESTART -eq 0 ]; then
    banner "Phase B · Restart openclaw"
    if [ "$(id -u)" = "0" ] && systemctl is-active openclaw >/dev/null 2>&1; then
      systemctl restart openclaw && \
        echo -e "  ${GREEN}✓${NC} systemd service restarted"
    elif command -v openclaw >/dev/null 2>&1; then
      oc_run openclaw gateway restart 2>&1 | tail -3 && \
        echo -e "  ${GREEN}✓${NC} gateway restarted"
    else
      echo -e "  ${YELLOW}!${NC} restart manually"
    fi
  fi

  banner "Done — review-agent v2.2 ENABLED"
  cat <<EOF

review-agent 是给 $RESPONDER_NAME 准备的 pre-meeting review 教练。从现在
起，任何 Lark 用户给你的 bot 发方案 / PDF / Lark 文档链接，bot 都会按
$RESPONDER_NAME 的 review 标准帮 ta 挑刺、追问，直到那份材料修到
"$RESPONDER_NAME 一打开就能决策" 的状态。最后 bot 把一份 6 段决策 brief
同时发给 $RESPONDER_NAME 和 Requester。

这套架构里有三个角色：

  • ${BLUE}Admin${NC}     — 你（$ADMIN_NAME，open_id 已绑定）
                  你 DM bot 走 main openclaw agent，是普通聊天 / 管理对话，
                  不会被卷进 review 流。

  • ${BLUE}Responder${NC} — $RESPONDER_NAME（被代言的人，review-agent 模仿其风格）
                  当前默认 = Admin。如果你只是负责运维但实际审 review
                  的是另一个人，可以 --enable-only 重设。

  • ${BLUE}Requester${NC} — 其他任何 Lark 用户
                  ta 第一次 DM bot 时，openclaw 会自动给 ta 起一个独立
                  subagent 进程，加载 review-coach 人格，session 上下文
                  跟其他 Requester 完全隔离。无需注册、无需邀请。

${BLUE}Requester 来了之后会发生什么${NC}：

  1. ta 在 Lark 给 bot 发材料（PDF / docx 链接 / 长文本）
  2. bot 自动起一个 sandbox subagent，跑四柱扫描（背景 / 资料 / 框架 / 意图）
  3. bot 用 ${BLUE}$RESPONDER_NAME${NC} 的 standards 找前 5 条最关键漏洞
  4. 一条 finding 一条 finding 发给 ta，等 ta 回答 / 改 / 反驳
  5. 全部走完后合成一份 brief，同时发给 $RESPONDER_NAME 和 ta

你不需要做任何事——它是异步的、自托管的、按需触发的。

${BLUE}让 review 更精准${NC}（强烈推荐做一次）：

review-agent 默认用一份"通用 senior decision-maker"的画像。要让 review
出来真像 $RESPONDER_NAME 自己在审，跑一下：

    bash $REPO_ROOT/assets/admin/setup-responder.sh --guided

5 个问题（Role / Decision style / Pet peeves / 3 必问问题 / 风格备注），
~3 分钟。改完自动生效，下次 Requester DM 就用新画像。

${BLUE}成本预期${NC}：每次完整 review（attachment → top-5 Q&A → brief）大约调
8-20 次 LLM。当前 \`agents.defaults.model.primary\` 决定主 agent 用哪个，
skill 脚本独立调 OpenRouter（见 \`agents.defaults.model.primary\` 同步设定）。
便宜组合参考：deepseek-v4-flash ≈ \$0.05-0.20/review；强模型 (gemini-3-pro
/ claude-opus / gpt-4) ≈ \$0.5-3/review。可在 OpenClaw config / OpenRouter
dashboard 切换 + 监控。

${BLUE}日常运维${NC}（用到再翻）：

  • 看版本/升级：   bash $SKILL_DST/update.sh
  • 出问题自愈：   bash $REPO_ROOT/vps-doctor.sh
  • 完整指南：     $REPO_ROOT/ADMIN_GUIDE.md
  • 卸载：         bash $SKILL_DST/uninstall.sh --yes [--purge]

${BLUE}Channel${NC}：feishu / wecom 全功能（per-peer subagent）；其他 channel
（telegram / whatsapp / discord / slack / iMessage）退化为 shared-main 模式。

EOF

  # Offer to run the personalization wizard right now (interactive only).
  # Skipped in non-interactive mode (--admin-open-id passed at command line).
  if [ $NON_INTERACTIVE -eq 0 ]; then
    echo
    read -rp "现在跑一下 5 问引导填 Responder 画像吗？[Y/n] " WIZARD_NOW
    case "${WIZARD_NOW:-Y}" in
      n|N|no|NO)
        echo "  Skipped. 用到时跑：bash $REPO_ROOT/assets/admin/setup-responder.sh --guided"
        ;;
      *)
        echo
        bash "$REPO_ROOT/assets/admin/setup-responder.sh" --guided
        ;;
    esac
  fi
}

banner "review-agent v2.2 · install (openclaw)"
echo "  target user: $TARGET_USER  ($([ -n "$RUN_AS" ] && echo "via sudo" || echo "current user"))"
echo "  openclaw HOME: $OC_HOME"

case "$MODE" in
  install-only)
    phase_install
    echo; echo "To enable later:"
    echo "     bash $REPO_ROOT/install.sh --enable-only"
    ;;
  enable-only) phase_enable ;;
  full)
    phase_install
    if [ -n "${ORIGINAL_ADMIN_OID:-}" ]; then
      phase_enable
    else
      echo
      cat <<'INTRO'
━━━ About review-agent v2 ━━━
Per-peer review coach for Lark/Feishu (or WeCom). Three roles:
  • Admin     — you (manage, DMs go to main openclaw agent)
  • Responder — whose review standards apply (you, by default)
  • Requester — submits drafts (auto-enrolled per-peer subagent)
━━━
INTRO
      read -rp "Enable review-agent now? [y/N] " ENABLE_NOW
      case "${ENABLE_NOW:-N}" in
        y|Y|yes|YES) phase_enable ;;
        *)
          echo
          echo -e "${YELLOW}Skipped.${NC} Skill files installed but openclaw isn't wired yet."
          echo "When ready: bash $REPO_ROOT/install.sh --enable-only"
          ;;
      esac
    fi
    ;;
esac
