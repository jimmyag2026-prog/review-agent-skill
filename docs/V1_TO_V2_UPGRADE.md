# v1 → v2 upgrade (hermes → openclaw)

## Should I upgrade?

- **Single Requester, low volume** → v1 is fine. No pressure.
- **Multiple Requesters** (≥3 concurrent reviews) → v2 gives you real context isolation (architectural, not SOP-enforced). Recommended.
- **Want cleaner architecture** (no MEMORY.md SOP, no config patches) → v2.

## What changes at runtime

| Aspect | v1 (hermes) | v2 (openclaw) |
|---|---|---|
| Which bot/gateway to use | hermes gateway | openclaw gateway |
| Where context lives | `~/.review-agent/users/<oid>/...` | `~/.openclaw/workspace-feishu-<oid>/...` |
| Per-Requester agent | Shared main agent + MEMORY.md SOP routing | Dedicated subagent process per peer |
| Routing | Prompt-based (SOP) | Config-based (`bindings[]` for admin → main; `dynamicAgentCreation` for feishu peers, `dynamicAgents` for wecom peers) |
| Outbound to Lark | `send-lark.sh` shell wrapper | Native `feishu_chat` tool |

## Upgrade steps

1. **Install v2** (doesn't disturb v1):
   ```bash
   cd ~/code/review-agent/openclaw-v2
   bash install/install-openclaw.sh
   ```
2. **Stop hermes gateway** (one machine can't run both — conflicting Lark subscriptions):
   ```bash
   hermes gateway stop
   ```
3. **Migrate data**:
   ```bash
   bash migrate/migrate-v1-to-v2.sh --dry-run    # preview
   bash migrate/migrate-v1-to-v2.sh              # do it
   ```
   This walks every `~/.review-agent/users/<oid>/` with role `Requester`, clones the v2 template to `~/.openclaw/workspace-feishu-dm-<oid>/`, copies over `sessions/` + `active_session.json`, and prints a JSON snippet of bindings to merge into `~/.openclaw/openclaw.json`.
4. **Merge bindings** — paste the JSON from step 3 into `~/.openclaw/openclaw.json` under `"bindings"`.
5. **Restart openclaw gateway**:
   ```bash
   openclaw gateway restart
   ```
6. **Verify** — DM your bot; the peer's subagent should respond with its persona.
7. **Decommission v1** (optional, once you're confident):
   ```bash
   # Back up first if you want the history:
   tar czf ~/review-agent-v1-backup.tgz ~/.review-agent ~/.hermes/memories
   # Then:
   rm -rf ~/.review-agent
   # And remove the orchestrator SOP block from MEMORY.md (between the v2 markers)
   vim ~/.hermes/memories/MEMORY.md
   ```

## What doesn't transfer

- `orchestrator_sop.md` in MEMORY.md — v2 doesn't use it; safe to remove the marker block after verifying v2 works.
- `~/.hermes/config.yaml` display patches — openclaw has its own display policies; leave the hermes config alone.
- `install/hermes_patches/admin_notify_patch.py` — openclaw has native allowlist + admin model.

## Rollback

v1 data under `~/.review-agent/` is not modified by the migrate script — it's read-only source. If v2 doesn't work, stop openclaw, restart hermes, and you're back where you were:

```bash
openclaw gateway stop
hermes gateway start
```

Your v1 `~/.review-agent/` is untouched. You can leave v2 files in `~/.openclaw/skills/review-agent/` and `~/.openclaw/workspace/templates/review-agent/` dormant (they only activate when `dm.createAgentOnFirstMessage=true`, which you can toggle off).
