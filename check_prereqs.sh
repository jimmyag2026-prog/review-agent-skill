#!/bin/bash
# check_prereqs.sh — verify openclaw + ingest tools are ready for review-agent v2
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
fails=0; warns=0

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; fails=$((fails+1))
         [ -n "${2:-}" ] && echo -e "     ${CYAN}→ fix:${NC} $2"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; warns=$((warns+1))
         [ -n "${2:-}" ] && echo -e "     ${CYAN}→ fix:${NC} $2"; }

OS="unknown"
if [ "$(uname)" = "Darwin" ]; then OS="macos"
elif [ -f /etc/os-release ]; then . /etc/os-release; OS="${ID:-linux}"
fi

# Resolve target openclaw HOME (honor env from install-openclaw.sh)
OC_HOME="${OPENCLAW_HOME:-$HOME}"
if [ -z "${OPENCLAW_HOME:-}" ] && [ "$(id -u)" = "0" ] && id openclaw >/dev/null 2>&1; then
  OC_HOME="/home/openclaw"
fi
OPENCLAW_JSON="$OC_HOME/.openclaw/openclaw.json"

echo "Prerequisite check for review-agent v2 (openclaw)"
echo "  OS: $OS"
echo "  openclaw HOME: $OC_HOME"
echo "  openclaw.json: $OPENCLAW_JSON"
echo

# openclaw CLI
command -v openclaw >/dev/null 2>&1 \
  && ok "openclaw CLI ($(openclaw --version 2>&1 | head -1))" \
  || warn "openclaw CLI not in PATH" "if openclaw runs as system service this is OK; otherwise install per https://clawhub.com"

# openclaw.json present
if [ -f "$OPENCLAW_JSON" ]; then
  ok "openclaw.json exists at $OPENCLAW_JSON"
else
  fail "openclaw.json missing at $OPENCLAW_JSON" "run 'openclaw setup' as the target user first"
fi

# OpenRouter API key (either in openclaw.json or env)
KEY_FOUND=0
if [ -f "$OPENCLAW_JSON" ]; then
  KEY=$(python3 -c "
import json
try:
  d = json.load(open('$OPENCLAW_JSON'))
  k = d.get('models',{}).get('providers',{}).get('openrouter',{}).get('apiKey','')
  if k and not k.startswith('\${'): print('YES')
except: pass
")
  [ "$KEY" = "YES" ] && KEY_FOUND=1
fi
[ -n "${OPENROUTER_API_KEY:-}" ] && KEY_FOUND=1
if [ $KEY_FOUND -eq 1 ]; then
  ok "OpenRouter API key configured"
else
  fail "No OpenRouter API key found" "review-agent's analysis scripts (scan / qa-step / merge-draft / final-gate / _build_summary) call OpenRouter directly for structured tasks. Even if your openclaw subagent uses Google/Anthropic/etc. for IM replies, these scripts need their own OR key. Set: openclaw config set models.providers.openrouter.apiKey sk-or-v1-... OR export OPENROUTER_API_KEY=sk-or-v1-..."
fi

# feishu channel enabled
if [ -f "$OPENCLAW_JSON" ]; then
  FEISHU=$(python3 -c "
import json
d = json.load(open('$OPENCLAW_JSON'))
print('YES' if d.get('channels',{}).get('feishu',{}).get('enabled') else 'NO')
")
  [ "$FEISHU" = "YES" ] && ok "feishu channel enabled" \
                       || fail "feishu channel not enabled in openclaw.json" "openclaw gateway restart after enabling"

  # Sandbox binds collision pre-check (warning only — installer will offer fix)
  BAD_BINDS=$(python3 -c "
import json
d = json.load(open('$OPENCLAW_JSON'))
binds = d.get('agents',{}).get('defaults',{}).get('sandbox',{}).get('docker',{}).get('binds',[])
base = '$OC_HOME/.openclaw/workspace'
bad = [b for b in binds if isinstance(b,str) and b.startswith(base+'/') and 'workspace-feishu-' not in b and 'workspace-wecom-' not in b]
print(len(bad))
")
  if [ "$BAD_BINDS" != "0" ]; then
    warn "$BAD_BINDS sandbox.docker.binds entr(y/ies) collide with per-peer subagent allowed_roots" \
         "installer will offer to auto-clear; or run: python3 patch_openclaw_json.py --clear-bad-binds"
  fi
fi

# Daemon user check (root-targeting-non-root case)
if [ "$(id -u)" = "0" ] && [ "$OC_HOME" != "/root" ]; then
  DAEMON_USER=$(basename "$OC_HOME")
  if id "$DAEMON_USER" >/dev/null 2>&1; then
    ok "running as root, will install as user '$DAEMON_USER'"
  else
    warn "running as root but user matching $OC_HOME doesn't exist" "specify --target-user explicitly"
  fi
fi

# python3 + version
if command -v python3 >/dev/null 2>&1; then
  PY=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
  MAJ=$(python3 -c 'import sys; print(sys.version_info[0])')
  MIN=$(python3 -c 'import sys; print(sys.version_info[1])')
  if [ "$MAJ" -ge 3 ] && [ "$MIN" -ge 9 ]; then ok "python3 $PY"
  else fail "python3 $PY too old (need ≥ 3.9)" "upgrade python"
  fi
else
  fail "python3 not found" "install python3"
fi

# PDF extractor — blocker (same as v1.1.1)
HAVE_PDFTOTEXT=0; HAVE_PDFMINER=0
command -v pdftotext >/dev/null 2>&1 && HAVE_PDFTOTEXT=1
python3 -c "import pdfminer" 2>/dev/null && HAVE_PDFMINER=1
if [ $HAVE_PDFTOTEXT -eq 1 ]; then ok "pdftotext available"
elif [ $HAVE_PDFMINER -eq 1 ]; then ok "pdfminer.six available (fallback)"
else
  case "$OS" in
    macos) hint="brew install poppler  # or: pip3 install pdfminer.six" ;;
    ubuntu|debian) hint="sudo apt install -y poppler-utils  # or: pip3 install pdfminer.six" ;;
    *) hint="install poppler-utils or 'pip3 install pdfminer.six'" ;;
  esac
  fail "no PDF extractor (pdftotext OR pdfminer.six)" "$hint"
fi

# tesseract + whisper — warnings
command -v tesseract >/dev/null 2>&1 && ok "tesseract (image OCR)" \
  || warn "tesseract not installed — image attachments degrade to 'paste text'" "brew/apt install tesseract tesseract-ocr-chi-sim"
command -v whisper >/dev/null 2>&1 && ok "whisper (audio transcription)" \
  || warn "whisper not installed — audio attachments degrade to 'paste text'" "pip3 install openai-whisper && ffmpeg"

echo
if [ $fails -gt 0 ]; then
  echo -e "${RED}✗ $fails blocking issue(s)${NC}. Fix the → fix lines above, then re-run."
  exit 1
elif [ $warns -gt 0 ]; then
  echo -e "${YELLOW}! $warns warning(s)${NC}. Install可继续。"
  exit 0
else
  echo -e "${GREEN}✓ all checks passed.${NC}"
  exit 0
fi
