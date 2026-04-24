# review-agent v2.0 — openclaw port · design

> Source of truth for the architecture. Implementation tracks this doc.

## Why v2 exists

v1.x runs on hermes. Per-Requester context isolation is **soft** — a single main agent handles every Lark DM, and we enforce "don't cross-read session files" via a MEMORY.md SOP. That's OPEN_ISSUES.md#I-001.

openclaw ships a `dynamicAgents` feature: every new peer DMing the bot gets a **dedicated subagent process** with its own workspace + persona + session history. Context isolation becomes architectural instead of prompt-enforced. This is the right home for review-agent.

## File layout decision

Decision 1 (user): keep review-agent repo; v2 lives in a new subfolder `openclaw-v2/`. v1 stays on `main` / `v1.x`.

Decision 2 (user): port scripts to openclaw native tool form. Research showed openclaw's "native tool" is **the same SKILL.md-based format** hermes uses (AgentSkills spec). So "port" = install the skill directory at `~/.openclaw/skills/review-agent/` and use native `feishu_chat` / `feishu_doc` tools instead of our `send-lark.sh` / `lark-doc-publish.py` shell wrappers.

Decision 3 (user): responder-profile is a **global file** at `~/.openclaw/review-agent/responder-profile.md`. Every peer workspace symlinks it.

## Repo layout

```
openclaw-v2/
├── docs/
│   ├── DESIGN.md                    ← this file
│   ├── INSTALL_OPENCLAW.md          ← user-facing install guide
│   └── V1_TO_V2_UPGRADE.md          ← migration guide
├── skill/                           ← → ~/.openclaw/skills/review-agent/
│   ├── SKILL.md
│   ├── scripts/
│   │   ├── ingest.py               (v1 port, cwd-relative paths)
│   │   ├── scan.py                 (v1 port)
│   │   ├── qa-step.py              (v1 port)
│   │   ├── merge-draft.py          (v1 port)
│   │   ├── final-gate.py           (v1 port)
│   │   ├── check-profile.py        (v1, unchanged)
│   │   ├── _build_summary.py       (v1 port)
│   │   ├── _model.py               (v1, unchanged — reads openclaw.json now)
│   │   ├── _json_repair.py         (v1, unchanged)
│   │   └── check-updates.py        (v1, unchanged)
│   └── references/
│       ├── agent_persona.md        (ported, {responder_name} still in place)
│       ├── four_pillars.md         (v1, unchanged)
│       ├── annotation_schema.md    (v1, unchanged)
│       └── delivery/               (v1, unchanged)
├── workspace-template/review-agent/ ← → ~/.openclaw/workspace/templates/review-agent/
│   ├── SOUL.md                     (review coach persona)
│   ├── AGENTS.md                   (/review commands cheatsheet + dispatch)
│   ├── IDENTITY.md                 (agent name/avatar/vibe)
│   ├── USER.md                     (peer + responder metadata, filled by binding)
│   ├── HEARTBEAT.md                (openclaw standard)
│   ├── BOOTSTRAP.md                (openclaw standard)
│   ├── owner.json.template
│   ├── review_rules.md             (copied into each peer workspace)
│   ├── responder-profile.md → ../../review-agent/responder-profile.md
│   │                               (symlink; runtime resolves to global)
│   └── memory/                     (empty; scripts create sessions/)
├── install/
│   ├── install-openclaw.sh         (one-shot installer)
│   ├── patch_openclaw_json.py      (add channels.feishu.* knobs idempotently)
│   └── check_prereqs.sh            (openclaw + ingest tools check)
├── admin/
│   ├── dashboard-server.py         (reads ~/.openclaw/workspace-feishu-dm-*/)
│   ├── setup-responder.sh          (edits global responder-profile.md)
│   └── remove-peer.sh              (rm workspace + agent + bindings entry)
└── migrate/
    └── migrate-v1-to-v2.sh         (hermes ~/.review-agent → openclaw workspaces)
```

## Runtime flow (new peer's first message)

```
Lark DM arrives →
  openclaw gateway (main agent) sees peer open_id not in bindings yet
  → channels.feishu.dm.createAgentOnFirstMessage=true fires
  → clones ~/.openclaw/workspace/templates/review-agent/
         to  ~/.openclaw/workspace-feishu-dm-<open_id>/
  → creates ~/.openclaw/agents/feishu-dm-<open_id>/
  → adds bindings entry: {agentId: feishu-dm-<oid>, match: {channel: feishu, peer: <oid>}}
  → spawns subagent with cwd=peer workspace
  → subagent loads SOUL.md + AGENTS.md + review_rules.md + responder-profile.md (symlink)
  → subagent auto-loads shared skill ~/.openclaw/skills/review-agent/ (via SKILL.md discovery)
  → message dispatched to subagent
  → subagent sees attachment → invokes skill scripts/ingest.py .
      (cwd = peer workspace → sessions/<id>/ lives here)
  → scan/qa/etc. all operate in peer workspace
  → outbound via native feishu_chat tool
```

No MEMORY.md SOP. No main-agent disambiguation. Each message → single subagent context.

## Three-role mapping

| Role (v1 concept) | v2 realization |
|---|---|
| **Admin** | openclaw workspace owner (the "main" agent). Edits `~/.openclaw/review-agent/responder-profile.md`; runs admin scripts. |
| **Responder** | Profile source at `~/.openclaw/review-agent/responder-profile.md` (global). Every peer workspace symlinks. Admin == Responder stays the default (Phase 6 could split). |
| **Requester** | Each peer → own subagent → own workspace. Auto-enrolled on first DM via `dm.createAgentOnFirstMessage`. |

## What gets dropped from v1

| v1 component | Why dropped in v2 |
|---|---|
| `install/orchestrator_sop.md` + `patch_memory_sop.py` | Routing is config-driven, no SOP injection. |
| `install/patch_hermes_config.py` | openclaw has its own display policies; no hermes config to patch. |
| `install/hermes_patches/admin_notify_patch.py` | openclaw has native allowlist + admin-bypass. |
| `install/check_lark_scopes.py` | Still useful but no longer blocks install; becomes admin tool. |
| `skill/scripts/send-lark.sh` | Use native `feishu_chat` tool. |
| `skill/scripts/lark-fetch.sh` | Use native `feishu_doc.read` / `feishu_wiki.read`. |
| `skill/scripts/lark-doc-publish.py` | Use native `feishu_doc.create` + `feishu_drive.share`. |
| `skill/scripts/start-review.sh` | Subagent handles the start flow in-prompt from its SKILL.md. |
| `skill/scripts/review-cmd.sh` | Same — subagent parses `/review …` natively. |
| `skill/scripts/new-session.sh` | Folded into `ingest.py` which creates sessions dir on demand. |
| `skill/scripts/setup.sh` | Install writes template once; auto-onboarding replaces manual setup. |
| `skill/scripts/add-requester.sh` | Auto-enrollment. Optional pre-seed retained via admin script. |

## What stays identical from v1

- four-pillar scan methodology (scan.py prompts)
- Responder simulation layer (scan.py Layer B)
- six challenge dimensions (agent_persona.md)
- Q&A loop turn-taking (qa-step.py)
- final-gate verification (final-gate.py)
- merge-draft rewrite logic (merge-draft.py)
- ingest multi-modal extraction (ingest.py, already hard-failing per v1.1.1)
- lenient JSON parser (_json_repair.py)
- model follow main-agent (_model.py, but reads openclaw.json now)
- six-section decision brief template (_build_summary.py)
- dashboard HTML layout (rewired data source only)
- placeholder guard (check-profile.py)
- update check (check-updates.py)

## _model.py port

v1 reads `~/.hermes/config.yaml` → `model.default`. v2 reads `~/.openclaw/openclaw.json` → `agents.defaults.models["openrouter/..."]` or `models.providers.openrouter.models[0]`. Since user just added DeepSeek V4 and has multiple models, we pick by alias if available, else first openrouter model. Env override `REVIEW_AGENT_MODEL` still wins.

## Session directory

v1: `~/.review-agent/users/<open_id>/sessions/<session_id>/`
v2: `<peer_workspace>/sessions/<session_id>/`  (cwd of subagent)

Layout inside session dir is unchanged: `input/`, `normalized.md`, `annotations.jsonl`, `conversation.jsonl`, `cursor.json`, `meta.json`, `final/`, `dissent.md`, `profile.md` (frozen at session start from symlinked responder-profile), `review_rules.md` (frozen).

## Self-verify plan (Phase 6)

Synthetic end-to-end without touching real Lark:
1. `cp -R workspace-template/review-agent/ /tmp/peer-A/`; `/tmp/peer-B/`
2. Drop a fake proposal PDF + .txt into each's `input/`
3. `cd /tmp/peer-A/ && python3 ~/.openclaw/skills/review-agent/scripts/ingest.py`
4. Verify `/tmp/peer-A/sessions/.../normalized.md` exists; `/tmp/peer-B/` empty (isolation)
5. `scan.py`, `qa-step.py`, `merge-draft.py`, `final-gate.py` each tested per-peer
6. Concurrency: run scan on A and B in parallel, diff their annotations — must be different (they each see only their own input)
7. Dashboard: point it at `/tmp/` via REVIEW_AGENT_WORKSPACE_ROOT=`/tmp/` env, confirm it lists peer-A and peer-B with session counts

Only after synthetic E2E green → push to GitHub + tag v2.0.

## Non-goals for v2.0

- Multi-responder (each peer picks a different responder) — Phase 7. Requires a mapping file + SOUL.md parameterization.
- Running hermes v1 and openclaw v2 side-by-side on the same machine (conflicting channel claims). v1 users choose one or the other.
- Rewriting scripts as JavaScript/TypeScript. Python stays; openclaw skills bundle language-agnostic scripts.
