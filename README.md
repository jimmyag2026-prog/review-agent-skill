# review-agent · openclaw skill

**Async pre-meeting review coach for Lark.** Each Requester gets a dedicated per-peer subagent with arch-level context isolation. Rooted in 1942 US Army Completed Staff Work doctrine.

This is the full install bundle (skill + workspace template + installer + admin tools). For the lean skill-only form, see [ClawHub](https://clawhub.com/skills/review-agent) or `clawhub install review-agent`.

## One-line install

```bash
git clone https://github.com/jimmyag2026-prog/review-agent-skill ~/code/review-agent-skill
cd ~/code/review-agent-skill
bash install.sh
```

## Already installed from ClawHub? Finish the setup

The ClawHub bundle is skill-only (SKILL.md + scripts + references). It doesn't include the per-peer workspace template or the openclaw.json patches. Run this once:

```bash
git clone https://github.com/jimmyag2026-prog/review-agent-skill ~/code/review-agent-skill
cd ~/code/review-agent-skill
bash install.sh --enable-only
```

The installer is idempotent and will skip pieces ClawHub already installed.

## Admin commands (bundled at skill root)

```bash
bash ~/.openclaw/skills/review-agent/update.sh --check
bash ~/.openclaw/skills/review-agent/update.sh
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes --purge --revert-config  # full wipe
bash ~/code/review-agent-skill/assets/admin/setup-responder.sh   # edit global responder profile
python3 ~/code/review-agent-skill/assets/admin/dashboard-server.py
```

## Upgrade from hermes v1

See `assets/migrate/migrate-v1-to-v2.sh` and `docs/V1_TO_V2_UPGRADE.md`.

## Links

- Main repo (history + design): https://github.com/jimmyag2026-prog/review-agent
- ClawHub: https://clawhub.com/skills/review-agent
- License: MIT
