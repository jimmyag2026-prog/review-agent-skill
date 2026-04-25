# Changelog

All notable changes to review-agent are tracked here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.1.2] — 2026-04-24 (Linux compat + absolute path hotfix)

### 🔴 Fixed — two VPS blockers

**1. `feishu_seed_workspace_patch.py` hardcoded macOS Homebrew path**

The patcher had `DEFAULT_MONITOR = Path("/opt/homebrew/lib/node_modules/openclaw/dist/monitor-D9C3Olkl.js")`. On Linux VPS:
- openclaw installs to `/usr/lib/node_modules/openclaw/dist/` (not `/opt/homebrew/...`)
- File hash suffix is different (e.g. `6KpSIhEL` / `BAWxXKRf` / `BMI3D6x8` — newer builds also **split into multiple `monitor-*.js`** files)

Result: patcher failed silently on every Linux install → subagents fell back to openclaw's default memorist persona instead of loading review-coach.

**Fix**: replaced hardcoded path with **auto-discovery**:
1. Ask `npm root -g` for the authoritative node_modules dir
2. Search well-known install paths (macOS Apple Silicon / Intel brew / Linux system / user-local npm / project-local)
3. Within each dir, glob `monitor-*.js` and pick the file that actually contains our anchor (`mkdir(agentDir, {recursive: true})`)
4. Give a helpful error with all searched paths if nothing matches, and accept `--monitor-js <explicit>` as override

Works on macOS (brew / pkg install) and Linux (npm install -g).

**2. `patch_openclaw_json.py` wrote `~/.openclaw/...` path literals**

openclaw's `resolveUserPath()` DOES expand `~/` in some code paths, but not all — reported on Linux VPS: subagents couldn't find the template because the workspaceTemplate value was literally `~/.openclaw/...` with the tilde unexpanded in some runtime context.

Also: the previous patcher was conceptually wrong — it wrote `workspaceTemplate: "~/.openclaw/workspace/templates/review-agent"` (the SOURCE template dir), but openclaw's `workspaceTemplate` is actually the **OUTPUT path template** with `{agentId}` placeholder (where peer workspaces get created). That path is then passed through `resolveUserPath` + `.replace("{agentId}", agentId)` to produce the per-peer workspace path.

**Fix**: patcher now writes **absolute** paths with the correct `{agentId}` placeholder, using `Path.home()` at patch-time:

```json
"dynamicAgentCreation": {
  "enabled": true,
  "workspaceTemplate": "/home/openclaw/.openclaw/workspace-{agentId}",
  "agentDirTemplate": "/home/openclaw/.openclaw/agents/{agentId}/agent",
  "maxAgents": 100
}
```

(On macOS `Path.home()` gives `/Users/yourname/...`; on Linux `/home/youruser/...`. Either way: no ambiguity about HOME resolution.)

### Recovery path for broken installs

```bash
cd ~/code/review-agent-skill && git pull
python3 install/patch_openclaw_json.py                   # fixes the config
python3 install/openclaw_patches/feishu_seed_workspace_patch.py  # re-applies monitor patch w/ auto-discovery
openclaw gateway restart
```

Patchers are idempotent + auto-clean legacy bad keys.

## [2.1.1] — 2026-04-24 (hotfix)

### 🔴 Fixed — install.sh was bricking the gateway

`patch_openclaw_json.py` in v2.0.0–v2.1.0 wrote the WRONG 4 keys into `channels.feishu`:

```
channels.feishu.dynamicAgents.enabled = true            # wecom-plugin key, not feishu
channels.feishu.dynamicAgents.adminBypass = false       # wecom-plugin key
channels.feishu.dm.createAgentOnFirstMessage = true     # wecom-plugin key
channels.feishu.workspaceTemplate = "..."               # wecom-plugin key
```

Feishu's built-in channel schema is **strict** (`additionalProperties: false`) and rejected all four with:

```
Invalid config at ~/.openclaw/openclaw.json:
- channels.feishu: invalid config: must NOT have additional properties
```

→ **gateway refused to start** on every fresh install. This was discovered during live Evie testing today, manually fixed on my own machine, but the SOURCE patcher was never updated — so every `bash install.sh` ran by any user would reproduce the same gateway crash.

### Fix

- `patch_openclaw_json.py` now writes the CORRECT feishu-native key: **`channels.feishu.dynamicAgentCreation`** (single nested object with `enabled`/`workspaceTemplate`/`agentDirTemplate`/`maxAgents`). Schema-valid.
- Patcher also auto-removes the old wrong keys if they exist from prior runs — so users hit by the v2.0/v2.1.0 bug get automatic recovery on v2.1.1 re-run.
- Idempotent verified against a polluted test fixture.

### Recovery path for users already on broken v2.0–v2.1.0

```bash
git pull   # in your bundle repo (or re-clone the standalone skill repo)
python3 ~/code/review-agent-skill/install/patch_openclaw_json.py
openclaw gateway restart
```

The patcher will strip the 3 legacy bad keys and install the correct one. Gateway should start.

## [2.1.0] — 2026-04-24

Emerged from the first real Lark testing session with Evie as Requester. The v2.0 architecture was sound but the feishu wiring had several undocumented gotchas. This release closes the gap between "it ran once in isolation" and "a new peer DMs the bot and gets a proper review coach."

### Fixed — from live Lark testing

1. **Wrong openclaw.json key for feishu dynamic agents**. v2.0 `patch_openclaw_json.py` copied wecom's `dynamicAgents` / `dm.createAgentOnFirstMessage` / `workspaceTemplate` into `channels.feishu` — but feishu's strict schema rejected all three ("must NOT have additional properties"). The correct key is **`dynamicAgentCreation`** (single nested object with `enabled` / `workspaceTemplate` / `agentDirTemplate` / `maxAgents`). Patcher fixed.

2. **Auto-spawned workspace loaded default "memorist" persona, not review-coach**. openclaw core's `maybeCreateDynamicAgent` only `mkdir`s the peer workspace; the `writeFileIfMissing` step then seeds openclaw's built-in generic-companion templates ("Hey. I just came online. Who am I?"). Our review-coach SOUL.md never got loaded. **New**: `openclaw-v2/install/openclaw_patches/feishu_seed_workspace_patch.py` — idempotent marker-guarded local patch to `monitor-D9C3Olkl.js` that inserts `cp -R <template> <workspace>` between the `mkdir` and openclaw's `writeFileIfMissing`. Our files land first → `writeFileIfMissing` leaves them alone.

3. **`replies=0` on dispatch_complete — subagent emitted `NO_REPLY` or used wrong `target` format**. openclaw's `message` tool accepts either (a) `target` omitted → reply to current DM, or (b) `target: "user:<open_id>"` / `target: "chat:<chat_id>"`. Subagent was passing bare `target: "ou_xxx"` — silently dropped. SOUL.md + AGENTS.md now include explicit JSON examples teaching "omit target" and flagging `NO_REPLY` as a silent-skip pitfall.

4. **"Thinking Process:" markdown headings leaked to Lark**. openclaw's `stripReasoningTagsFromText` only strips XML `<think>...</think>` tags, not markdown. SOUL.md now has a 硬规则 forbidding markdown-style reasoning and directs the model to use `<think>` if reasoning is needed.

5. **Repeated `creating dynamic agent` per DM even with existing binding**. openclaw core re-fires `maybeCreateDynamicAgent` even when bindings already match. Our cp -R seed is idempotent so no data loss, but logs are noisy. Filed as upstream. Documented in FIELD_NOTES.md as "non-issue".

6. **owner.json didn't get populated in the template**. install.sh Phase B writes it correctly; but an intermediate `rsync --delete` during debugging wiped it. Not an install.sh bug per se, but documented in field notes.

7. **LLM prompt-cache stickiness**. Updating SOUL.md mid-session has zero effect on running subagent because openclaw caches the system prompt per agent session. To force a refresh: `rm -f ~/.openclaw/agents/feishu-ou_xxx/sessions/*.jsonl`. Documented in POST_INSTALL.md and FIELD_NOTES.md.

### Changed — per user feedback

- **Top-5 findings by default**. `scan.py` now caps the Q&A queue to the top-5 most important (BLOCKER > IMPROVEMENT > NICE-TO-HAVE). Remainder lives in `cursor.deferred`. `qa-step.py` emits an automatic preamble on the first finding: "我扫到 N 条问题。先带你过最关键的 5 条——过完再看剩下 (N-5) 条要不要继续。" Override with `REVIEW_AGENT_TOP_N` env or `--top-n` flag. Reply `more` / `继续` / `下一批` to pull deferred findings; reply `done` to close.
- **Attachment-first flow**. SOUL.md decision tree: Step 1 — material present → immediately ingest + review. Step 2 — no material, clear review intent → ask "你有材料要一起看吗？" BEFORE starting review. Step 3 — no review signal → normal chat. Lark wiki URLs pre-fetched via native `feishu_wiki.read`; on scope denial the subagent asks Requester to paste text instead of hallucinating.
- **SKILL.md description** updated: mentions WeCom compatibility, top-5 default, new `more`/`done` commands, channel-limitation disclaimer.

### Added

- **`openclaw-v2/skill/POST_INSTALL.md`** — Admin-facing quickstart with 3-step checklist, channel compatibility matrix, required Lark scopes, day-to-day admin commands, common troubleshooting. Distributed with the skill so ClawHub users see it on first inspect.
- **Lark DM auto-send** in `install.sh` Phase B — offers to DM the admin (via Lark Open API direct call) a summary of POST_INSTALL.md with the 3-step checklist.
- **Channel compatibility matrix** in README.md + DESIGN.md + POST_INSTALL.md — definitively explains per-peer auto-spawn is feishu + wecom only, all other channels fall back to shared-main-agent.
- **`openclaw-v2/install/openclaw_patches/`** directory for all future openclaw-core local patches.
- **`openclaw-v2/docs/FIELD_NOTES.md`** — raw debugging journal preserved for future contributors.

### Note

All fixes were validated live with Evie as Requester on 2026-04-24. End-to-end goes: inbound DM → feishu dynamicAgentCreation → template seed (review-coach) → subagent loads SOUL.md → ingest → scan → confirm-topic → Q&A loop → output replies=1 → Lark delivery. Leak check clean (no thinking process, no memorist wording, no NO_REPLY).

## [2.0.2] — 2026-04-24

### Published to ClawHub

- **Live on ClawHub**: slug `review-agent`, version `2.0.2` (bumped from 2.0.1 to fix an auto-derived display name that included the staging folder path).
- **Install commands now work**:
  ```bash
  clawhub install review-agent           # with user prompt to review code
  clawhub install review-agent --force   # non-interactive
  openclaw skills install review-agent   # via openclaw native
  ```
- ClawHub holds new/updated skills behind a 30s–2min security scan before making them install-visible. After that, the three commands above resolve.

## [2.0.1] — 2026-04-24

### Published to ClawHub

- Slug: `review-agent`, published version 2.0.1 (ClawHub ID `k977gfc9sm9pd4kz1m9dz129yh85frrr`).
- Install via: `clawhub install review-agent` or `openclaw skills install review-agent`.
- ClawHub bundle is the lean skill (SKILL.md + scripts + references + README + uninstall.sh + update.sh — ~30 files). The heavier openclaw-level setup (workspace template + installer + admin tools) stays in the standalone skill repo + monorepo.



### Added

- **`openclaw-v2/skill/uninstall.sh`** — Admin-run removal script. Takes out the skill and workspace template by default; with `--purge` also clears the global responder profile + all peer workspaces + per-peer agent dirs + bindings; with `--revert-config` unsets the `channels.feishu` knobs the skill introduced. Backs up `openclaw.json` before any mutation. Dry-runs by default — requires `--yes` to actually delete.
- **`openclaw-v2/skill/update.sh`** — self-update script. Fetches the latest skill version from GitHub (standalone skill repo preferred, monorepo fallback), shows current → latest, re-installs into place, restarts openclaw gateway. Supports `--check` / `--force` / `--yes` / `--ref <tag|branch|sha>`. Never touches peer workspaces or global data.
- **`openclaw-v2/skill/VERSION`** — version stamp for update detection.

### Changed

- **`check-updates.py`** now points at the standalone skill repo `jimmyag2026-prog/review-agent-skill` (monorepo remains as fallback for v1 installs).

### Standalone skill repo published

- GitHub: https://github.com/jimmyag2026-prog/review-agent-skill
- One-line install: `git clone https://github.com/jimmyag2026-prog/review-agent-skill ~/code/review-agent-skill && cd ~/code/review-agent-skill && bash install.sh`
- Flat layout: SKILL.md + scripts/ + references/ at root (openclaw/clawhub-discoverable), workspace template + admin tools + migrate script under `assets/`.

## [2.0.0] — 2026-04-24

**First openclaw port.** Lives under `openclaw-v2/` as a separate subtree; hermes v1.x is unchanged on `main` and still supported. Pick one runtime per machine — you can't have both hermes and openclaw claiming the same Lark bot.

### Why

v1 on hermes routes every Lark DM through a single main agent, using a MEMORY.md SOP to decide "is this Requester A's review or Requester B's?". Context isolation is documentation-enforced (see v1 `OPEN_ISSUES.md#I-001`). In v2 on openclaw, every peer gets a **dedicated subagent** with its own workspace and session history — isolation is architectural.

### Architecture delta

| Dimension | v1 (hermes) | v2 (openclaw) |
|---|---|---|
| Per-Requester agent | Shared main agent + SOP routing | Dedicated subagent per peer (auto-spawned on first DM) |
| State storage | `~/.review-agent/users/<oid>/...` | `~/.openclaw/workspace-feishu-dm-<oid>/...` |
| Persona injection | `agent_persona.md` pulled per script | Workspace `SOUL.md` + `AGENTS.md` + `IDENTITY.md` loaded natively |
| Outbound Lark | `send-lark.sh` shell wrapper | Native `feishu_chat` tool |
| Lark doc publish | `lark-doc-publish.py` + raw API | Native `feishu_doc` tool |
| Responder profile | Per-user `profile.md` | Global `~/.openclaw/review-agent/responder-profile.md`, symlinked per peer |
| Routing | MEMORY.md SOP (prompt-based) | `dynamicAgents` + `bindings` (config-based) |
| SOP install | Required (`patch_memory_sop.py`) | Dropped |
| Display config patch | Required (`patch_hermes_config.py`) | Dropped (openclaw has native display policies) |
| User enrollment | Manual `setup.sh` + `add-requester.sh` | Auto on first DM via `dm.createAgentOnFirstMessage` |

### What stays unchanged (same methodology, re-homed)

- Four-pillar review (`scan.py`)
- Responder simulation layer
- Six challenge dimensions
- Q&A loop turn-taking (`qa-step.py`)
- Final-gate verification (`final-gate.py`)
- Merge-draft rewrite (`merge-draft.py`)
- 6-section decision brief (`_build_summary.py`)
- Ingest hard-fail on missing tools (v1.1.1 behavior preserved)
- Placeholder guard (`check-profile.py`)
- Update check (`check-updates.py`)
- Lenient JSON parser (`_json_repair.py`)
- Model-follow-config (`_model.py`, now reading `openclaw.json`)

### New in v2

- `openclaw-v2/skill/` — AgentSkills-compatible skill ready to install at `~/.openclaw/skills/review-agent/` (shared across all per-peer subagents)
- `openclaw-v2/workspace-template/review-agent/` — per-peer workspace template (cloned by openclaw on first DM)
- `openclaw-v2/install/install-openclaw.sh` — two-phase installer (install + enable), mirrors v1's UX
- `openclaw-v2/install/patch_openclaw_json.py` — idempotent channel config patcher
- `openclaw-v2/admin/dashboard-server.py` — dashboard rewired to read `~/.openclaw/workspace-feishu-dm-*/`
- `openclaw-v2/admin/setup-responder.sh` — edit global responder profile
- `openclaw-v2/admin/remove-peer.sh` — purge workspace + agent + bindings
- `openclaw-v2/migrate/migrate-v1-to-v2.sh` — one-shot migration from hermes v1
- `openclaw-v2/docs/DESIGN.md`, `INSTALL_OPENCLAW.md`, `V1_TO_V2_UPGRADE.md`

### Dropped from v2

Everything hermes-specific or replaced by openclaw natives:
- `send-lark.sh`, `lark-fetch.sh`, `lark-doc-publish.py`, `lark-doc-probe.py`
- `start-review.sh`, `review-cmd.sh`, `new-session.sh`, `close-session.sh`
- `setup.sh`, `add-requester.sh`, `add-responder.sh`
- `patch_memory_sop.py`, `patch_hermes_config.py`
- `install/orchestrator_sop.md`, `install/hermes_patches/*`
- `_deliver.py`, `deliver.sh` (subagent sends directly via `feishu_chat`)

### Self-verification (done before release)

- Synthetic 2-peer E2E in `/tmp/ra-v2-e2e/` with real LLM calls:
  - Ingest handles text content per-workspace, never cross-reads
  - Scan produced 10/12 findings against each peer's own material
  - qa-step advanced cursor correctly (p1 accepted → p2)
  - Zero cross-contamination: peer A findings mention only Postgres, peer B only hiring (validated via substring check)
- Dashboard reads both peer workspaces, counts sessions per peer
- Installer patcher idempotency verified against real `openclaw.json`
- All 12 scripts syntax-clean

## [1.1.1] — 2026-04-23

Patch release from a one-click-install audit. Closes gaps that would cause a
fresh hermes+Lark user to hit silent degradation or post-install busywork.

### Fixed

- **`SKILL.md` version + author**: was `version: 0.2.0` (stale) and had a personal `author:` field. Bumped to `1.1.1` and removed the author field.
- **PDF / image / audio hard-fail**: `ingest.py` used to return a placeholder string `"[PDF ingest unavailable …]"` when `pdftotext`/`pdfminer.six` were both missing, and `scan.py` would then run the full four-pillar review on that placeholder text — producing confident-looking but garbage findings. Now raises a structured `IngestError`, writes `ingest_failed.json`, and exits 3 with a clear Requester-facing message ("让 Admin 装一下 / 你直接贴正文也行"). Same pattern for `tesseract` (OCR) and `whisper` (audio).
- **`start-review.sh` propagates ingest failure**: was swallowing the exit code (`>/dev/null 2>&1 || echo fallback`). Now detects exit 3, relays the user message to Lark, marks session `status: ingest_failed`, clears `active_session.json`, and skips `confirm-topic`/scan entirely.
- **`check_prereqs.sh` escalated PDF tools to blocker**: was a warning. Since SOP v2 routes any PDF straight to ingest and ingest now hard-fails, missing PDF tools would be a first-review crash. Now blocks install unless `pdftotext` OR `pdfminer.six` is available. `tesseract` and `whisper` remain warnings (Requester gets a "paste text" prompt instead of a hard fail for images/audio).

### Added

- **Post-install interactive prompts** in `install.sh` Phase B:
  1. "Restart hermes gateway now? [Y/n]" — runs `hermes gateway restart` or the `systemctl --user restart hermes-gateway` equivalent on Linux.
  2. "Add your first Requester now? [y/N]" — interactive wizard that calls `add-requester.sh --approve-pairing` with the given open_id + name.
  Both prompts are skipped when `--admin-open-id` is passed on the CLI (implied non-interactive mode).
- **`install/check_lark_scopes.py`** — queries Lark Open API with `FEISHU_APP_ID`/`SECRET` from `~/.hermes/.env`, probes each required scope (`im:message`, `im:message:send_as_bot`, `docx:document`, `drive:file`, `drive:drive`) and reports per-scope PRESENT/MISSING/UNKNOWN. Non-blocking — granting scopes is a human step in the Lark developer console. Wired into `install.sh` Phase B.

## [1.1.0] — 2026-04-22

### Changed

- **LLM model follows hermes main agent** instead of hard-pinning `anthropic/claude-sonnet-4.6`. All LLM-calling scripts now resolve the model from `~/.hermes/config.yaml` → `model.default` and map hermes-style ids to OpenRouter format (strip `-YYYYMMDD` date suffix, convert trailing `-N-N` to `-N.N`, add provider prefix). Precedence: `REVIEW_AGENT_MODEL` env var > hermes config > fallback `anthropic/claude-sonnet-4.6`.
- New shared helper `skill/scripts/_model.py` exposes `get_main_agent_model()`.
- `--model` CLI flag on each script now defaults to `None` (resolve at call time) instead of a hardcoded string. Pass `--model <id>` to override per-call.
- Removed `model:` pin from `skill/SKILL.md` frontmatter.
- **Installer split into two phases**: Phase A installs files (always runs, reversible), Phase B configures Admin/Responder + patches `config.yaml` + installs MEMORY.md SOP (opt-in via prompt or `--enable-only`). Run with `--install-only` to stage files without activating.
- **Responder profile default**: `boss_profile.md` template rewritten as a functional senior-reviewer default — reviews now work out of the box without editing, though personalizing still improves quality. Old version was all placeholders and produced degraded reviews when unedited.

### Added

- `skill/scripts/check-profile.py` — scans a profile for leftover `<e.g., …>` / `<your …>` placeholders. Invoked by `install.sh` Phase B (user-facing warning) and `new-session.sh` (stderr log only, never blocks).
- `~/.review-agent/enabled.json` stamp written after Phase B for install/enable-state detection.
- **`docs/HERMES_FEISHU_HARDENING.md`** — three-layer hardening guide for multi-user Lark deployments: allowlist env, `unauthorized_dm_behavior: pair` config (note the key-based vs value-based fallback quirk in hermes), and a local hermes patch for admin-notify on pairing.
- **`install/hermes_patches/admin_notify_patch.py`** — idempotent, marker-guarded patcher for `gateway/run.py`. Inserts a best-effort hook that DMs each `FEISHU_ADMIN_USERS` open_id whenever an unauthorized user triggers pairing. Supports `--dry-run` and `--revert`. Safe to re-run after `hermes update` overwrites the upstream file.
- Troubleshooting entries in `INSTALL.md` and `docs/VPS_SETUP.md` for: stale gateway PID file, silent drop of unauthorized DMs when allowlist is non-empty, fail2ban dropping SSH on rapid reconnects.
- **Passive update check** — `skill/VERSION` file + `skill/scripts/check-updates.py` compares against GitHub (releases API with tags fallback, 24h cache, 5s timeout, fails open). Surfaces in two Admin-facing touchpoints: dashboard web banner (orange, links to release notes) and `dashboard-web.sh` stdout on launch. Silent when up-to-date or offline. User can disable with `check-updates.py --disable`.

### Fixed

- **PDF / attachment dialog removed** (reported 2026-04-22): when a Requester sent a PDF, the main agent would reply "收到 PDF 文件 📄 你想怎么处理？…" and list options. SOP now has an explicit hard rule: any attachment from a Requester = immediate `review-cmd.sh start`, no dialogue. Size guardrails added (>20 MB PDF or >100 pages → ask for smaller version; >10 MB image; >50 MB / >30 min audio). ingest.py already handles PDF/image/audio extraction inside the session, so the main agent should never run `pdftotext` / `pdfminer` / `whisper` itself.
- **`💻 terminal:` tool-call previews leaking into Lark** (reported 2026-04-22): broadened `patch_hermes_config.py` with defensive OFF values for `show_tool_calls`, `show_tool_results`, `show_code_blocks`, `show_bash` (unknown keys are harmless on hermes versions that ignore them). SOP also gained an explicit "progress messages" protocol: one short "处理中…" message while ingest/scan run; never relay tool previews, stderr, or tracebacks.
- **SOP bumped to v2** with auto-upgrade: `patch_memory_sop.py` now detects an older-version install and replaces the block in place (preserving everything after the `§` separator), instead of refusing to run because the v1 marker exists.
- **`feishu.unauthorized_dm_behavior: pair`** now seeded by `patch_hermes_config.py` on fresh installs (only if absent — respects explicit user choice) so the Layer 2 hardening from HERMES_FEISHU_HARDENING.md is the default rather than opt-in.

## [1.0.0] — 2026-04-22

First public release. Complete end-to-end pipeline for async pre-meeting review coaching via Lark IM + Lark Doc, with a local admin dashboard.

### Architecture

- **Three-role model**: Admin / Responder / Requester. Default install folds Admin+Responder into one user; multi-Responder is on the v1.x roadmap.
- **Per-subtask isolation**: `~/.review-agent/users/<open_id>/sessions/<id>/` each with frozen copies of `admin_style.md` + per-Responder `profile.md` + shared `review_rules.md`.
- **Runtime**: hermes (native Lark gateway) + OpenRouter (Sonnet 4.6 default) for LLM calls. No hermes fork or private API needed.

### Review framework

- **Core principle**: agent is a challenger, not a summarizer. Points out problems, asks questions, never writes answers for the Requester.
- **Six challenge dimensions**: data integrity / logical consistency / plan feasibility / stakeholders / risk assessment / ROI clarity.
- **Four pillars** (replaces earlier 7-axis model; legacy axis-based annotations are backward-compat mapped):
  - Background · Materials · Framework · **Intent (CSW gate)**
- **Responder Simulation top layer**: LLM role-plays the Responder using their profile.md and produces top-5 questions in their voice.

### Pipeline (6 stages)

INTAKE → SUBJECT CONFIRMATION → FOUR-PILLAR SCAN + RESPONDER SIMULATION → Q&A LOOP → DOCUMENT MERGE (conditional) → FINAL GATE + CLOSE + FORWARD.

### User-facing features

- **IM-based Q&A loop** with shortcut replies: `a` / `b` / `c` / `p` (pass) / `custom` / free text, auto-scoped to top-3 BLOCKER findings with remainder deferred for later.
- **Lark Doc publishing**: material + findings go into an auto-created Lark docx with inline agent callouts (content-injection style; Lark Open API doesn't expose true inline comment anchoring), shared to Requester (edit) and Responder (view).
- **Decision-ready summary**: LLM synthesizes a 6-section brief (议题摘要 / 核心数据 / 团队自检结果 / 待决策事项 / 建议时间分配 / 风险提示) delivered to both parties on close. Audit-trail version saved separately.
- **Local dashboard**: `http://127.0.0.1:8765`, read-only view of all users, active sessions, findings progress.

### Engineering hardening

- **Session isolation guardrails**: MEMORY.md SOP forbids main agent from reading session files; scripts run as isolated Python processes; stderr shrunk to minimal lifecycle markers.
- **IM outbound hygiene**: hermes config patched to stop `tool_progress` from leaking into Lark DMs (feishu platform tier = MINIMAL).
- **Lenient JSON parser**: handles LLM output with unescaped newlines, inner quotes, trailing commas, markdown fences, line comments.
- **Idempotent install**: marker-guarded SOP append, backup-on-patch, re-run safe.

### Tooling

- **One-command install** for pre-configured hermes + **bootstrap.sh** for bare-metal/VPS (auto-detects OS across Ubuntu/Debian/Fedora/Arch/Alpine/macOS).
- **check_prereqs.sh** with OS-specific install hints for each missing dep.
- **sync-to-hermes.sh** for dev → skill copy iteration.

### Known limitations

- Session context isolation at main-agent layer is documentation-enforced only; see [OPEN_ISSUES.md I-001](OPEN_ISSUES.md) for hardening path.
- Lark API does not support programmatic inline comment anchoring on docx; worked around via content injection.
- Single-Responder v0 scope; multi-Responder deferred to v1.x.
- `more` / `deepen` follow-up commands from Responder on the delivered summary are documented in output but backend routing not yet implemented.

### Scripts index

User mgmt: `setup` / `add-requester` / `add-responder` / `set-role` / `list-users` / `remove-user`.
Session lifecycle: `new-session` / `close-session` / `review-cmd` / `start-review` / `confirm-and-scan`.
LLM stages: `confirm-topic.py` / `scan.py` / `qa-step.py` / `merge-draft.py` / `_build_summary.py` / `final-gate.py`.
Input normalization: `ingest.py` / `lark-fetch.sh`.
Outputs: `_deliver.py` / `deliver.sh` / `send-lark.sh` / `lark-doc-publish.py`.
Ops: `dashboard-web.sh` / `dashboard-server.py` / `dashboard.sh` / `sync-to-hermes.sh`.
Install: `install.sh` + `install/{bootstrap,check_prereqs,patch_hermes_config,patch_memory_sop}`.

### Repo layout

```
review-agent/
├── install.sh           # one-shot installer
├── install/             # bootstrap + prereq + config patchers + SOP source
├── skill/               # the hermes skill (SKILL.md + scripts + references)
├── design/              # architecture & flow design docs
├── publish/             # LESSONS / NOTES for skill authors + public README
├── research/            # methodology landscape survey
└── test_logs/           # test plans
```
