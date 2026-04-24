# review-agent · openclaw skill

**Async pre-meeting review coach for Lark (and WeCom).** Each Requester gets a dedicated per-peer subagent with arch-level context isolation. Rooted in 1942 US Army Completed Staff Work doctrine.

This is the full install bundle (skill + workspace template + installer + openclaw patch + admin tools). For the lean skill-only form, see [ClawHub](https://clawhub.com/skills/review-agent).

## One-line install

```bash
git clone https://github.com/jimmyag2026-prog/review-agent-skill ~/code/review-agent-skill
cd ~/code/review-agent-skill
bash install.sh
```

After Phase B enable, installer will offer to **DM you the quickstart via Lark** + apply the openclaw source patch automatically.

## Already installed from ClawHub? Finish the setup

The ClawHub bundle is skill-only (SKILL.md + scripts + references). The openclaw source patch + workspace template + admin tools live here. Run:

```bash
git clone https://github.com/jimmyag2026-prog/review-agent-skill ~/code/review-agent-skill
cd ~/code/review-agent-skill
bash install.sh --enable-only
```

Installer is idempotent; skips anything ClawHub already installed.

## Channel support

| Channel | Per-peer subagent | Notes |
|---|---|---|
| feishu (Lark) | ✅ | v2 full architecture (requires patch_openclaw_json + feishu_seed_workspace patch) |
| wecom | ✅ | v2 full architecture (via `@sunnoy/wecom` plugin) |
| telegram / whatsapp / iMessage / discord / slack / mattermost | ❌ | Fallback to shared main agent mode. For those, consider [hermes v1](https://github.com/jimmyag2026-prog/review-agent). |

## Admin commands

```bash
bash ~/.openclaw/skills/review-agent/update.sh --check
bash ~/.openclaw/skills/review-agent/update.sh
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes --purge --revert-config   # full wipe
bash ~/code/review-agent-skill/assets/admin/setup-responder.sh
python3 ~/code/review-agent-skill/assets/admin/dashboard-server.py
```

## Full docs

- `POST_INSTALL.md` (bundled) — 3-step Admin checklist, Lark scopes, troubleshooting
- `docs/DESIGN.md` — architecture, channel compat matrix, decisions
- `docs/FIELD_NOTES.md` — raw debugging journal from live testing
- Monorepo: https://github.com/jimmyag2026-prog/review-agent
- ClawHub: https://clawhub.com/skills/review-agent

## License

MIT
