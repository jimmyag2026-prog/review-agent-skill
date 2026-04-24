# Field notes · openclaw v2 debugging journal

> Running log of what we learned from hands-on testing. Not pushed to GitHub until verified + polished. Kept raw on purpose.

## 2026-04-24 · first live Lark test

### Setup

- Admin + Responder: `ou_4f8da259748bd7bcf4034a8eb23637c1` (me via openclaw app)
- Requester (test): **Evie** = `ou_ccaf7d129aa54926aeb22286dd0206ad` in openclaw's feishu app (different from her hermes app open_id — Lark open_ids are per-app)
- Skill installed via ClawHub to `~/.openclaw/workspace/skills/review-agent/` v2.0.2

### Bug 1 · wrong config key broke gateway

**Symptom**: `openclaw gateway start` rejected with `channels.feishu: invalid config: must NOT have additional properties`.

**Cause**: my `patch_openclaw_json.py` inserted `dynamicAgents` / `dm.createAgentOnFirstMessage` / `workspaceTemplate` into `channels.feishu`. I had copied that schema from the wecom plugin's config without verifying feishu accepted the same keys.

**Why I thought it worked**: the wecom plugin's `openclaw.plugin.json` has `"additionalProperties": true` — so wecom accepts ANY keys. Feishu uses the built-in strict schema.

**Fix**: revert the bad patch, use the correct feishu-native key: **`dynamicAgentCreation`** (not `dynamicAgents`):

```json
"channels": {
  "feishu": {
    "dynamicAgentCreation": {
      "enabled": true,
      "maxAgents": 100
    }
  }
}
```

Allowed sub-keys (from `/opt/homebrew/lib/node_modules/openclaw/dist/plugin-sdk/extensions/feishu/src/config-schema.d.ts`):
- `enabled: boolean`
- `workspaceTemplate: string` (default `~/.openclaw/workspace-{agentId}` — this is the TARGET PATH for the new workspace, **not** a template source)
- `agentDirTemplate: string` (default `~/.openclaw/agents/{agentId}/agent`)
- `maxAgents: number`

Placeholders: `{userId}` = sender open_id, `{agentId}` = `feishu-{open_id}`.

### Channel support matrix

Checked which openclaw channels support per-peer dynamic agents (scanned `/opt/homebrew/lib/node_modules/openclaw/dist/plugin-sdk/extensions/*/src/*.d.ts`):

| Channel | Supports | Key |
|---|---|---|
| **wecom** | ✅ (via `@sunnoy/wecom` npm plugin) | `dynamicAgents`, `dm.createAgentOnFirstMessage`, `workspaceTemplate` (plugin schema is `additionalProperties: true`) |
| **feishu** | ✅ (built-in, openclaw core) | `dynamicAgentCreation` (strict schema, 4 sub-keys) |
| telegram | ❌ | none |
| whatsapp | ❌ | none |
| imessage | ❌ | none |
| discord | ❌ | none |
| slack | ❌ | none |
| mattermost | ❌ | none |
| bluebubbles | ❌ | none |

→ Only feishu + wecom make sense as channels for review-agent v2's per-peer-subagent architecture on current openclaw (2026.3.28).

### Bug 2 · auto-spawned workspace loaded openclaw's "memorist" default, not review-agent

**Symptom**: Evie DM'd "我想讨论大使招募主题". Gateway log showed `creating dynamic agent feishu-ou_ccaf…` and `dispatching to agent (session=agent:feishu-ou_ccaf…:main)` — arch isolation WORKED. But her reply was a generic "Hey I just came online, who am I? Who are you? What should I call you?" followed by identity-negotiation questions. Completely wrong persona.

**Cause**: openclaw core's `maybeCreateDynamicAgent` (in `dist/monitor-D9C3Olkl.js`) only `mkdir`s the workspace dir. It does NOT copy our workspace template contents in. Later during `agent:bootstrap`, openclaw core seeds the workspace with its **built-in default templates** (the "memorist" / generic-companion persona), via `writeFileIfMissing(bootstrapPath, await loadTemplate("BOOTSTRAP.md"))` at `dist/workspace-CFIQ0-q3.js:330`.

The default templates ("# SOUL.md - Who You Are / You're not a chatbot. You're becoming someone." + "BOOTSTRAP.md: 'Hey. I just came online. Who am I?'") completely override what our `workspace-template/review-agent/` ships with, because openclaw never looks at our template.

**Fix**: local patch of `monitor-D9C3Olkl.js` — insert a `cp -R` of our review-agent template into the new workspace right after openclaw's `mkdir`s but **before** openclaw core's default-template seeding. Because the seeder uses `writeFileIfMissing`, our files (in place first) win.

Patcher: `openclaw-v2/install/openclaw_patches/feishu_seed_workspace_patch.py` — idempotent, marker-guarded, backs up before write. Will be overwritten by `openclaw update`; re-run to restore.

Pattern copied from the v1 hermes `admin_notify_patch.py` approach.

### Bug 3 · LLM "thinking" block leaked to Lark

**Symptom**: Evie's first reply (before our patches) contained literal text:

```
think
Thinking Process:
Analyze the Request: The user (ou_ccaf…) wants to discuss ...
Identify the User/Context: ...
Drafting Response:
  "你好！我刚刚上线..."
Output Generation: Just output the response. 你好！我刚刚上线...
```

All the model's chain-of-thought reasoning shipped verbatim to the user.

**Cause**: openclaw has `stripReasoningTagsFromText()` (in `dist/auth-profiles-B5ypC5S-.js`) that runs on every outbound message — but it ONLY strips XML-like `<think>...</think>` / `<thinking>...</thinking>` tags. The LLM (kimi or deepseek — whichever is currently hermes-main-agent default) emitted reasoning as **plain markdown** with `## Thinking Process:` headings. Markdown is not a tag, so the stripper ignored it.

**Fix**: persona-level instruction in `SOUL.md` and `BOOTSTRAP.md`:

- Never emit `Thinking Process:` / `Analyze the Request:` / `Drafting Response:` / similar "show your work" markdown
- If reasoning is necessary, wrap it in XML `<think>...</think>` — openclaw strips those automatically
- Hard-block any "Hey I just came online" / "Who am I?" opening (that's the default bootstrap talking, not us)

Bake-in applies to both the template on disk AND the copy that lands in each new peer workspace via the feishu_seed_workspace_patch.

### Bug 4 · Admin/Responder open_id wasn't set in owner.json

**Symptom**: Evie's subagent had no idea who "the Responder" was. `owner.json` template was there but not filled in.

**Cause**: the install-time seeding of `owner.json` only writes it into the TEMPLATE at `~/.openclaw/workspace/templates/review-agent/owner.json`. The seeding patch I wrote above does `cp -R template/. workspace/`, so as long as the template has the Admin's open_id written in, each new peer workspace gets it.

Today's state: install.sh did run enable-phase at 11:12 and wrote `~/.openclaw/review-agent/enabled.json` with `admin_open_id: ou_4f8da259748bd7bcf4034a8eb23637c1`. But whether the template's `owner.json` got populated needs a check — the template file was `owner.json.template` originally.

**Verify + fix**: inspect template dir after re-running install.sh enable-phase. If `owner.json.template` is still present and `owner.json` is missing, the install_sh enable code has a bug — need to make sure `cp owner.json.template → owner.json` + sed placeholders runs.

### Noted but not fixed

- `[feishu] ignoring stale permission scope error: Access denied ... contact:contact.base:readonly` — Lark app is missing the contact scope; openclaw logs + continues. Not blocking review-agent. If we want `resolveSenderNames: true` to work properly, grant that scope in Lark app console.
- `[telegram] getUpdates conflict: 409 terminated by other getUpdates request` — two bot instances polling same Telegram token. Unrelated to review-agent.
- `[feishu] streaming start failed: Create card request failed with HTTP 400` — card renderer hiccup on some reply. Low priority.

### Bug 5 · subagent called `message` tool with wrong `target` → silent drop

**Symptom**: after the template-seed patch worked, subagent correctly ran ingest/scan/qa-step and generated 4 quality review findings as `message` tool calls — but `dispatch complete (replies=0)`. Evie's Lark never received anything.

**Cause**: subagent passed `target: "ou_ccaf7d129aa54926aeb22286dd0206ad"` (bare open_id) to the `message` tool. openclaw's outbound router doesn't recognize that format — silently drops.

**Authoritative spec** (from `auth-profiles-B5ypC5S-.js`):
> "Feishu targeting: omit `target` to reply to the current conversation (auto-inferred). Explicit targets: `user:open_id` or `chat:chat_id`."

**Fix**: SOUL.md + AGENTS.md now instruct the subagent to **omit `target`** entirely for normal reply-to-requester. Includes a concrete JSON example of the `message` tool call pattern and flags `NO_REPLY` as a silent-token pitfall.

### Bug 6 · each Evie DM triggers a new `maybeCreateDynamicAgent` spawn

**Symptom**: every single DM from Evie logs `creating dynamic agent "feishu-ou_ccaf..."` + `review-agent: seeded` even though the binding already exists in openclaw.json. Not obviously harmful (cp -R is idempotent, in-flight session state under `sessions/` is preserved) but looks wrong.

**Suspected cause**: openclaw's `maybeCreateDynamicAgent` receives a `cfg` snapshot per message. If that snapshot doesn't include the binding written by a previous spawn (in-memory cache mismatch, or cfg re-reads stale disk state), the early-return at line 492 fails and it re-creates.

Not my patch's fault — my inserted block is strictly after the mkdirs, before the cfg write. The re-spawn happens at the function-entry level.

**Status**: filed as upstream openclaw bug. Left running — doesn't break functionality, just noisy.

### Bug 7 · Lark wiki URL can't be fetched (missing scope)

**Symptom**: Evie's message contained a Lark wiki URL. Subagent tried to fetch it via `feishu_wiki` tool. Log: `Access denied. One of the following scopes is required: [wiki:wiki, wiki:wiki:readonly, wiki:node:read]`.

**Fix**: grant the Lark app `wiki:wiki:readonly` scope in the Lark developer console. Until then, subagent should prompt Requester to paste text instead.

### ✅ 2026-04-24 11:54 — first successful E2E reply

After nuking Evie's subagent session files (to force fresh LLM context that reads the updated SOUL.md) and a fresh DM:

```
creating dynamic agent "feishu-ou_ccaf..."
review-agent: seeded workspace
DM from ou_ccaf...: "a"
dispatching to agent (session=agent:feishu-ou_ccaf...:main)
dispatch complete (queuedFinal=true, replies=1)  ← first time
```

Evie received a clean four-pillar Intent BLOCKER finding + a/b/c/p/custom options. No thinking leak, no memorist wording, no NO_REPLY.

### Key learning: `<final>[[reply_to_current]]` sentinel

Gemini-3-Pro picked a DIFFERENT way to reply than what we taught in SOUL.md:

```
<final>[[reply_to_current]] <reply text here></final>
```

That's openclaw's **native sentinel syntax** for "this assistant output IS the reply to the current conversation channel." openclaw strips the `<final>` / `[[reply_to_current]]` markers before forwarding to Lark. No `message` tool call needed.

Turns out openclaw supports at least three ways for an agent to reply:
1. `message` tool call with `target` omitted (what SOUL.md teaches)
2. `<final>[[reply_to_current]]...</final>` sentinel in assistant text (what gemini-3 picked)
3. Plain assistant text without any wrapper (may or may not get sent — channel-dependent)

Lesson: SOUL.md instructions should be a **sufficient** path for the LLM to follow, not an exclusive one. The LLM picks the easiest mechanism it knows. Both (1) and (2) work.

### LLM prompt cache: persona updates don't hot-reload

Critical gotcha: openclaw prompt-caches the system prompt (built from SOUL.md + AGENTS.md + etc.) **per agent session**. Updating SOUL.md mid-session has zero effect on the running subagent. To propagate persona updates:

```bash
# Force a fresh LLM session next DM:
rm -f ~/.openclaw/agents/feishu-ou_xxx/sessions/*.jsonl
rm -f ~/.openclaw/agents/feishu-ou_xxx/sessions/sessions.json
# Next DM → fresh context with latest SOUL.md
```

Workflow note for future prompt-engineering cycles: edit SOUL.md → `rm -f sessions/*` → test → iterate.

### Pending before next push

- [ ] Verify template seed patch works end-to-end (Evie re-DMs, get review-agent persona reply)
- [ ] Fix install.sh enable-phase `owner.json` population so template gets real open_ids, not placeholders
- [ ] Update SKILL.md / README to reflect:
  - feishu support requires openclaw source patch (not a bare-metal ClawHub install)
  - channel matrix: only wecom + feishu currently viable
  - Drop misleading "one-line install" claim — realistic path is ClawHub skill + bundle install.sh + openclaw patch
- [ ] Update `patch_openclaw_json.py` in the skill bundle to use correct `dynamicAgentCreation` key
- [ ] Ship `feishu_seed_workspace_patch.py` as part of install.sh Phase B
- [ ] Consider: upstream PR to openclaw adding a "workspaceTemplateSource" key (path to clone from, not target) so the patch isn't needed forever
