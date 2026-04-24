# review-agent · openclaw skill

**Async pre-meeting review coach for Lark.** Each Requester gets a dedicated
per-peer subagent with arch-level context isolation (no shared SOP routing).
Rooted in 1942 US Army Completed Staff Work doctrine.

This is the **openclaw skill form** of [review-agent](https://github.com/jimmyag2026-prog/review-agent). v1 (hermes) lives in that main repo; v2 is here as a standalone skill.

## One-line install

```bash
git clone https://github.com/jimmyag2026-prog/review-agent-skill ~/.openclaw/skills/review-agent
cd ~/.openclaw/skills/review-agent
bash install.sh
```

The installer copies the workspace template to `~/.openclaw/workspace/templates/review-agent/`, seeds `~/.openclaw/review-agent/responder-profile.md`, and wires `channels.feishu` in `~/.openclaw/openclaw.json` for dynamic-agent spawning.

## What it does

See `SKILL.md` for the full spec. In one screen:

Requester DMs your Lark bot → openclaw auto-spawns a dedicated subagent with its own isolated workspace → subagent runs four-pillar review + responder simulation + Q&A loop until the brief is decision-ready → delivers a 6-section summary to both Responder and Requester.

## Admin commands

```bash
# Check for updates (silent if up to date)
bash ~/.openclaw/skills/review-agent/update.sh --check

# Update to latest
bash ~/.openclaw/skills/review-agent/update.sh

# Remove (keep peer data)
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes

# Remove everything including peer sessions (IRREVERSIBLE)
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes --purge --revert-config

# Edit your Responder profile
bash ~/.openclaw/skills/review-agent/assets/admin/setup-responder.sh

# Watch sessions across all peer workspaces
python3 ~/.openclaw/skills/review-agent/assets/admin/dashboard-server.py
```

## Upgrade from hermes v1

If you have v1 installed via hermes, see the monorepo's `openclaw-v2/docs/V1_TO_V2_UPGRADE.md` and the migration script at `assets/migrate/migrate-v1-to-v2.sh`.

## Links

- Main repo (history, design docs, issues): https://github.com/jimmyag2026-prog/review-agent
- License: MIT
- Author: see main repo
