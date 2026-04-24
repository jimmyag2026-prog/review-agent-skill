# Installing review-agent v2 (openclaw)

## Prereqs (same as v1)

- Lark Open app (bot) with scopes: `im:message`, `im:message:send_as_bot`, `docx:document`, `drive:file`, `drive:drive`
- OpenRouter API key
- **openclaw** installed (`openclaw --version` works) — https://clawhub.com
- `~/.openclaw/openclaw.json` exists and the feishu channel is enabled (run `openclaw setup` if not)
- Python ≥ 3.9
- `pdftotext` OR `pdfminer.six` for PDF ingest (blocker — PDFs are the most common attachment)
- `tesseract` / `whisper` recommended (optional — enables image OCR / audio transcription)

## Install

```bash
git clone https://github.com/jimmyag2026-prog/review-agent.git ~/code/review-agent
cd ~/code/review-agent/openclaw-v2
bash install/install-openclaw.sh
```

The installer has **two phases**:

**Phase A (always runs, reversible):**
- Copies skill → `~/.openclaw/skills/review-agent/`
- Copies template → `~/.openclaw/workspace/templates/review-agent/`
- Seeds global responder profile → `~/.openclaw/review-agent/responder-profile.md`

**Phase B (opt-in via prompt):**
- Prompts for your Lark open_id + display name
- Writes owner.json into the template (inherited by every new peer workspace)
- Substitutes `{responder_name}` placeholder in persona files
- Patches `~/.openclaw/openclaw.json`:
  - `channels.feishu.dynamicAgents.enabled = true`
  - `channels.feishu.dm.createAgentOnFirstMessage = true`
  - `channels.feishu.workspaceTemplate = "~/.openclaw/workspace/templates/review-agent"`
- Restarts openclaw gateway

Non-interactive:
```bash
bash install/install-openclaw.sh --admin-open-id ou_xxx --admin-name "Your Name"
```

## What happens on first DM

A new Requester DMs your Lark bot → openclaw auto-clones the template to `~/.openclaw/workspace-feishu-dm-<open_id>/`, creates `~/.openclaw/agents/feishu-dm-<open_id>/`, registers a bindings entry, spawns a dedicated subagent process for that peer. The subagent loads your responder profile (via symlink) + the shared review-agent skill. Subsequent messages from that peer route to their subagent only — isolated from every other peer.

## Post-install

1. Edit the global responder profile to match your standards:
   ```bash
   bash admin/setup-responder.sh        # opens in $EDITOR
   ```
   or:
   ```bash
   vim ~/.openclaw/review-agent/responder-profile.md
   ```
2. Open the dashboard (watch sessions + findings):
   ```bash
   python3 admin/dashboard-server.py    # http://127.0.0.1:8765
   ```

## Remove a peer

```bash
bash admin/remove-peer.sh ou_xxxxxxxx      # dry-run: --dry-run
```

Deletes the peer's workspace + subagent dir + bindings entry.

## Upgrade from v1

See `V1_TO_V2_UPGRADE.md`.
