#!/bin/bash
# update.sh — fetch the latest review-agent skill from GitHub and re-install.
#
# For the human Admin to run from the command line. Not invoked by subagents.
#
# Flow:
#   1. Detect currently installed version (from ~/.openclaw/skills/review-agent/VERSION)
#   2. Query GitHub releases/tags to find the latest stable version
#   3. Show the diff (changelog since current version) if available
#   4. Prompt for confirmation (unless --yes)
#   5. Clone latest into a temp dir, rsync into place, restart openclaw gateway
#
# The skill is designed to be self-contained so update only rewrites files
# under ~/.openclaw/skills/review-agent/ and ~/.openclaw/workspace/templates/review-agent/.
# Peer workspaces (workspace-feishu-dm-*/) + global config (~/.openclaw/review-agent/)
# are NEVER touched by update — they carry your session history + responder profile.
#
# Usage:
#   update.sh                  # interactive
#   update.sh --yes            # non-interactive
#   update.sh --check          # only check, don't update
#   update.sh --force          # update even if already on latest
#   update.sh --ref <tag|branch|sha>   # pin to a specific ref
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

# Where the skill is installed.
SKILL_DIR="$HOME/.openclaw/skills/review-agent"
TEMPLATE_DIR="$HOME/.openclaw/workspace/templates/review-agent"

# GitHub source of truth — if the skill has its own repo, point check-updates.py at it.
REPO="${REVIEW_AGENT_SKILL_REPO:-jimmyag2026-prog/review-agent-skill}"
FALLBACK_REPO="jimmyag2026-prog/review-agent"  # monorepo fallback

YES=0; CHECK_ONLY=0; FORCE=0; PIN_REF=""
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    --ref=*) PIN_REF="${a#--ref=}" ;;
    --ref) shift; PIN_REF="$1" ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown: $a"; exit 1 ;;
  esac
done

# ── detect current ──
CURRENT="unknown"
if [ -f "$SKILL_DIR/VERSION" ]; then
  CURRENT=$(cat "$SKILL_DIR/VERSION" | tr -d ' \n')
elif [ -f "$SKILL_DIR/SKILL.md" ]; then
  # fallback: parse frontmatter
  CURRENT=$(awk -F': ' '/^version:/ {print $2; exit}' "$SKILL_DIR/SKILL.md" | tr -d '"')
fi
echo "current installed: ${CURRENT:-<none>}"

# ── detect latest via GitHub ──
# Try the dedicated skill repo first, fall back to the monorepo tag.
fetch_latest_tag() {
  local repo="$1"
  # Prefer /releases/latest (has release notes), fall back to /tags
  local data
  data=$(curl -s -f -H "Accept: application/vnd.github+json" \
         "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || true)
  if [ -n "$data" ]; then
    tag=$(echo "$data" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name","") or "")' 2>/dev/null)
    [ -n "$tag" ] && { echo "$tag"; return 0; }
  fi
  # Fallback: tags
  data=$(curl -s -f -H "Accept: application/vnd.github+json" \
         "https://api.github.com/repos/$repo/tags" 2>/dev/null || true)
  if [ -n "$data" ]; then
    echo "$data" | python3 -c 'import sys,json
tags=[t["name"] for t in json.load(sys.stdin) if t.get("name")]
# pick highest semver-ish
def key(v):
    import re
    v=v.lstrip("v")
    m=re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?",v)
    return tuple(int(x or 0) for x in m.groups()) if m else (0,0,0)
tags.sort(key=key, reverse=True)
print(tags[0] if tags else "")' 2>/dev/null
    return 0
  fi
  echo ""
}

LATEST=""
ACTIVE_REPO="$REPO"
if [ -n "$PIN_REF" ]; then
  LATEST="$PIN_REF"
  echo "pinned ref: $PIN_REF"
else
  LATEST=$(fetch_latest_tag "$REPO" 2>/dev/null)
  if [ -z "$LATEST" ]; then
    LATEST=$(fetch_latest_tag "$FALLBACK_REPO" 2>/dev/null)
    [ -n "$LATEST" ] && ACTIVE_REPO="$FALLBACK_REPO"
  fi
fi

if [ -z "$LATEST" ]; then
  echo -e "${YELLOW}!${NC} couldn't reach GitHub to check for updates. Offline?"
  exit 1
fi
echo "latest available: $LATEST  (from github.com/$ACTIVE_REPO)"

# ── compare ──
semver_tuple() {
  python3 -c "
import re,sys
v=sys.argv[1].lstrip('v')
m=re.match(r'^(\d+)\.(\d+)(?:\.(\d+))?', v)
print(' '.join(m.group(1), m.group(2), m.group(3) or '0')) if m else print('0 0 0')" "$1" 2>/dev/null || echo "0 0 0"
}

if [ "$CURRENT" = "$LATEST" ] || [ "${CURRENT#v}" = "${LATEST#v}" ]; then
  if [ $FORCE -eq 0 ]; then
    echo -e "${GREEN}✓${NC} already on latest. Nothing to do."
    exit 0
  fi
  echo -e "${YELLOW}!${NC} --force: re-installing $LATEST anyway"
fi

if [ $CHECK_ONLY -eq 1 ]; then
  echo
  echo -e "${BLUE}update available:${NC} $CURRENT → $LATEST"
  echo "run without --check to apply."
  exit 0
fi

# ── confirm ──
if [ $YES -ne 1 ]; then
  echo
  read -rp "Update from $CURRENT → $LATEST? [Y/n] " ans
  case "${ans:-Y}" in
    n|N|no|NO) echo "aborted."; exit 1 ;;
  esac
fi

# ── fetch + install ──
TMP=$(mktemp -d -t review-agent-update-XXXXXX)
trap "rm -rf $TMP" EXIT

echo
echo "cloning github.com/$ACTIVE_REPO at $LATEST..."
git clone --depth 1 --branch "$LATEST" "https://github.com/$ACTIVE_REPO.git" "$TMP/repo" 2>&1 | tail -3 \
  || { echo -e "${RED}✗${NC} clone failed"; exit 2; }

# Figure out layout: skill-only repo vs monorepo
SKILL_SRC=""
TEMPLATE_SRC=""
INSTALLER=""
if [ -f "$TMP/repo/SKILL.md" ]; then
  # standalone skill repo: SKILL.md at root
  SKILL_SRC="$TMP/repo"
  # template lives alongside if packaged
  [ -d "$TMP/repo/workspace-template/review-agent" ] && TEMPLATE_SRC="$TMP/repo/workspace-template/review-agent"
  INSTALLER="$TMP/repo/install-openclaw.sh"
  [ ! -f "$INSTALLER" ] && INSTALLER=""
elif [ -f "$TMP/repo/openclaw-v2/skill/SKILL.md" ]; then
  # monorepo layout (this repo)
  SKILL_SRC="$TMP/repo/openclaw-v2/skill"
  TEMPLATE_SRC="$TMP/repo/openclaw-v2/workspace-template/review-agent"
  INSTALLER="$TMP/repo/openclaw-v2/install/install-openclaw.sh"
else
  echo -e "${RED}✗${NC} can't locate SKILL.md in cloned repo. Aborting."
  exit 3
fi

# ── sync skill ──
echo "updating $SKILL_DIR..."
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude=".git" --exclude=".DS_Store" \
        "$SKILL_SRC/" "$SKILL_DIR/"
else
  rm -rf "$SKILL_DIR"; cp -R "$SKILL_SRC" "$SKILL_DIR"
fi
chmod +x "$SKILL_DIR/scripts/"*.py "$SKILL_DIR"/*.sh 2>/dev/null || true
echo -e "${GREEN}✓${NC} skill updated"

# ── sync template (if present) ──
if [ -n "$TEMPLATE_SRC" ] && [ -d "$TEMPLATE_SRC" ]; then
  echo "updating $TEMPLATE_DIR..."
  if command -v rsync >/dev/null 2>&1; then
    # NOT --delete here — we want to preserve any Admin-added files in the
    # template (like a custom owner.json). Only override known template files.
    rsync -a --exclude=".git" --exclude=".DS_Store" "$TEMPLATE_SRC/" "$TEMPLATE_DIR/"
  else
    cp -R "$TEMPLATE_SRC"/* "$TEMPLATE_DIR/" 2>/dev/null
  fi
  # Restore the symlink to global responder profile (rsync might have overwritten)
  ( cd "$TEMPLATE_DIR" && [ -e "$HOME/.openclaw/review-agent/responder-profile.md" ] && \
    rm -f responder-profile.md && ln -s "$HOME/.openclaw/review-agent/responder-profile.md" responder-profile.md ) || true
  echo -e "${GREEN}✓${NC} workspace template updated"
fi

# ── stamp version ──
echo "$LATEST" > "$SKILL_DIR/VERSION" 2>/dev/null || true

# ── restart gateway ──
echo
if command -v openclaw >/dev/null 2>&1; then
  if [ $YES -eq 1 ]; then
    openclaw gateway restart 2>&1 | tail -3 || true
  else
    read -rp "Restart openclaw gateway now? [Y/n] " ans
    case "${ans:-Y}" in
      n|N|no|NO) echo "  remember to: openclaw gateway restart" ;;
      *) openclaw gateway restart 2>&1 | tail -3 ;;
    esac
  fi
fi

echo
echo -e "${GREEN}✓ update complete${NC}: $CURRENT → $LATEST"
