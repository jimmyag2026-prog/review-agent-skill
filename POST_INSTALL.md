# 🔧 POST-INSTALL · Admin checklist (v2.2)

_You just installed `review-agent`. Read this ONCE and follow the steps. Everything else is automatic._

## What you just got

A **per-peer review coach** for Lark / WeCom. Every Requester who DMs your bot gets a dedicated subagent that runs four-pillar review + Responder simulation + Q&A loop, then hands you a 6-section decision brief.

## Three roles

- **Admin** — you (manage config). Your DMs go to the **MAIN openclaw agent** (chat/admin), NOT the review subagent.
- **Responder** — whose review standards apply. Often the same as Admin.
- **Requester** — anyone else who DMs the bot. Auto-enrolled on first DM into a per-peer subagent.

## Was it a bundle install or a clawhub install?

**Bundle install (recommended)** — `bash install/install-openclaw.sh` from the repo. Runs Phase A (files) + Phase B (config + watcher + restart). Skip to "Verify" below.

**ClawHub install (`clawhub install review-agent`)** — only the SKILL files land. You also need:
```bash
git clone https://github.com/jimmyag2026-prog/review-agent-skill ~/code/review-agent-skill
cd ~/code/review-agent-skill
bash install/install-openclaw.sh --enable-only
```

The `--enable-only` Phase B does config patches, watcher install, session-cache clear, gateway restart.

## Verify (right after install)

### 1. As Admin, DM the bot "你是谁" (or "who are you")
- **Expect**: regular openclaw assistant reply. NOT a review-coach asking for materials.
- **Log**: gateway log shows `dispatching to agent (session=agent:main:main)`.
- **If you see review-coach instead**: the admin → main binding didn't land. Re-run:
  ```bash
  python3 ~/code/review-agent-skill/install/patch_openclaw_json.py --admin-open-id ou_xxx
  ```

### 2. As a Requester (a DIFFERENT Lark user), DM the bot a proposal
- **Expect**: review-coach reply with first finding ("我扫到 N 条问题. 先带你过最关键的 5 条…")
- **Log**: gateway shows `creating dynamic agent feishu-ou_xxx`; seeder log shows `seeded .../workspace-feishu-ou_xxx`
- **If you see "Hey I just came online, who am I?"**: watcher didn't seed. Check:
  ```bash
  tail -10 ~/.openclaw/seeder.log
  systemctl --user status review-agent-seeder    # or: systemctl status review-agent-seeder
  ```

### 3. Watch the seeder log live
```bash
tail -F ~/.openclaw/seeder.log
```

## Daily ops

```bash
# update to latest
bash ~/.openclaw/skills/review-agent/update.sh

# check version
cat ~/.openclaw/skills/review-agent/VERSION

# customize Responder profile (10 min — bad defaults give generic reviews)
vim ~/.openclaw/review-agent/responder-profile.md

# self-heal anything that breaks (idempotent)
bash ~/code/review-agent-skill/scripts/vps-doctor.sh

# uninstall (keep peer sessions)
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes

# nuke everything
bash ~/.openclaw/skills/review-agent/uninstall.sh --yes --purge --revert-config
```

## Channel compatibility

| Channel | Per-peer subagent | Mechanism |
|---|---|---|
| **feishu / lark** | ✅ full v2 | openclaw `dynamicAgentCreation` + watcher seeds template |
| **wecom** | ✅ full v2 | `@sunnoy/wecom` plugin + `dynamicAgents` + watcher |
| **telegram** | ❌ | falls back to shared main agent |
| **whatsapp** | ❌ | same |
| **discord / slack / iMessage** | ❌ | same |

For non-feishu/wecom channels, run `bash scripts/setup-shared-mode.sh` to install review-coach persona on the main agent (all Requesters share context — fine for ≤3 active users). Or use [hermes v1](https://github.com/jimmyag2026-prog/review-agent) which has true per-peer routing for all channels.

## Lark app scopes (for Lark wiki/doc pre-fetch)

```
im:message:send_as_bot     im:message
docx:document              wiki:wiki:readonly
drive:file                 drive:drive
```

Set in Lark developer console → your app → Permissions. Without these, the subagent will politely ask the Requester to paste text instead.

## Architecture summary (v2.2)

```
Lark DM
  ├─ from Admin (open_id matches enabled.json admin_open_id)
  │     → bindings[*] routes to agent:main → openclaw default assistant
  │
  └─ from Requester (any other open_id)
        → channels.feishu.dynamicAgentCreation creates workspace-feishu-<oid>/
        → watcher (systemd/launchd/nohup) seeds review-agent template within ~1s
        → openclaw spawns peer subagent reading SOUL.md + AGENTS.md + responder-profile.md (symlink → global)
        → review-coach behavior takes over
```

Key files written by install:

```
~/.openclaw/skills/review-agent/                      # the skill (scripts + references)
~/.openclaw/workspace/templates/review-agent/         # template seeded into peer workspaces
~/.openclaw/review-agent/responder-profile.md         # global Responder persona
~/.openclaw/review-agent/enabled.json                 # marker + admin_open_id + responder_name
~/.openclaw/review-agent-seeder.sh                    # the watcher script (auto-generated)
~/.openclaw/openclaw.json                             # patched: dynamicAgentCreation + admin binding + binds cleanup
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| "Something went wrong while processing your request" | sandbox.docker.binds collision (binds outside per-peer allowed_roots) | `python3 install/patch_openclaw_json.py --clear-bad-binds` |
| Admin DM gets review-coach reply (asks for materials) | admin → main binding missing or wrong open_id | `python3 install/patch_openclaw_json.py --admin-open-id ou_xxx` |
| Requester DM gets "Hey I just came online" | watcher not running or template missing | `bash install/setup_watcher.sh` |
| `replies=0` on dispatch | subagent's `message` tool used wrong target format | clear sessions: `rm ~/.openclaw/agents/feishu-ou_*/sessions/*.jsonl` |
| Reply contains "Thinking Process:" | SOUL.md not loaded | check workspace SOUL.md exists & contains "不要填 target 字段" |
| Each DM logs "creating dynamic agent" | harmless — openclaw re-attaches per message; cp -R is idempotent | none |
| `Access denied wiki:wiki:readonly` | Lark app missing scope | grant in Lark developer console |

If anything is unclear or stuck, run the diagnostic+heal-all script:

```bash
bash ~/code/review-agent-skill/scripts/vps-doctor.sh
```

It's idempotent — safe to run any time.

## Full docs

- Monorepo (history + v1 hermes + design): https://github.com/jimmyag2026-prog/review-agent
- Standalone skill bundle: https://github.com/jimmyag2026-prog/review-agent-skill
- Field notes: `openclaw-v2/docs/FIELD_NOTES.md` in monorepo
