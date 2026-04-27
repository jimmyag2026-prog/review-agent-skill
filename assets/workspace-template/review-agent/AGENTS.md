# AGENTS.md · /review commands + dispatch

> Routing reference. SOUL.md sets persona; this sets the message → action map.

## Command table

Everything the Requester might send, and what you do.

| Requester message | Action |
|---|---|
| `/review start [主题]` | start-review flow (see below) |
| `/review end <reason>` | close-session: set `meta.status=closed`, write reason, deliver summary |
| `/review status` | print active session info (subject, round, # findings open) |
| `/review help` | show command list + plain "just send your material" |
| `/chat` + then normal message | skip review routing for that one message |
| Plain chat + **attachment** (PDF / image / audio) | 🚨 **start review immediately** — ingest → scan → first finding |
| Plain chat + **Lark doc/wiki URL** | pre-fetch via native `feishu_wiki.read` / `feishu_doc.read`, drop as `.txt` into `input/`, then ingest. If scope denied → ask Requester to paste text (see SOUL.md Step 1). |
| Plain chat + Google Doc URL | same flow; try `gdrive read-file-content` or ask for paste |
| Plain chat + long text (>300 chars, proposal-like) | start review (ask one confirming Q if ambiguous) |
| Explicit ask wording ("请批准 X", "approve this", "帮我决定 A 还是 B") | start review |
| Keyword triggers (see SOUL.md six-dimension list) + NO material attached | **ask for material first**: "你有材料要一起看吗？附件 / Lark 链接 / 一段文字都行。" Do NOT start review yet — wait for their 2nd message with content. |
| Weak signal ("帮我看看", no material) | same as above — ask for material, don't start review |
| `more` / `继续` / `下一批` during Q&A loop | pull deferred findings into pending; continue Q&A |
| `done` after Q&A loop | close session → merge-draft + final-gate → deliver |
| Plain chat, no review signal | normal response |

## start-review flow (what "start" does internally)

1. **Create session dir**: `sessions/<YYYYMMDD-HHMMSS>-<subject-slug>/{input,final}/`
2. **Save inbound**: write the Requester's message text to `sessions/<id>/input/initial.md`; log to `conversation.jsonl`
3. **Save attachments**: download any attached files into `sessions/<id>/input/`
4. **Write meta.json**: subject, round=0, status=awaiting_subject_confirmation, created_at
5. **Freeze profile + rules**: `cp responder-profile.md sessions/<id>/profile.md` (snapshot so future edits to global don't affect in-flight sessions); `cp review_rules.md sessions/<id>/review_rules.md`
6. **Run ingest**: `python3 .skill/scripts/ingest.py . sessions/<id>` — creates `normalized.md`. If ingest exits 3 (tool missing) → relay its stdout to Lark, mark session `ingest_failed`, STOP.
7. **Confirm topic**: send Lark message asking Requester to confirm subject scope (one line, yes/no-ish)
8. After their confirmation → run scan.py + responder simulation
9. Enter Q&A loop (qa-step.py)
10. When cursor empty → merge-draft + final-gate → deliver summary

## Q&A loop — exact tool-call sequence per turn

Each Requester reply. Two tool calls in order:

**1. `exec` — run the next pipeline step**
```json
{
  "name": "exec",
  "arguments": {
    "command": "python3 .skill/scripts/qa-step.py sessions/<session_id> \"<reply_text>\""
  }
}
```

Capture the stdout.

**2. `message` — send the stdout to Requester**
```json
{
  "name": "message",
  "arguments": {
    "action": "send",
    "message": "<paste the exec stdout VERBATIM here — no paraphrasing, no adding context, no stripping>"
  }
}
```

🚨 **Omit the `target` field.** openclaw auto-routes to the current DM. If you pass `target: "ou_xxx"` (bare open_id), openclaw silently drops the message. Only use explicit target in the form `user:<open_id>` or `chat:<chat_id>` when you deliberately want to send elsewhere.

qa-step.py classifies intent (accepted / modified / rejected / clarifying / scope change) and returns the next finding. Its stdout is already Lark-formatted — relay verbatim.

**Shortcut replies** (already wired in qa-step.py): `a` / `b` / `c` / `p` (pass) / custom text / free text.

## Happy path full example

Requester sends: "我想让 jimmy 看看这个计划 [Lark wiki URL] 这是 Astros 大使激励机制"

```
Turn 1  exec: python3 .skill/scripts/ingest.py sessions/<new_id>
Turn 2  exec: python3 .skill/scripts/confirm-topic.py sessions/<new_id>
Turn 3  message: (omit target) message=<confirm-topic stdout, the a/b/c options>
```

Requester replies: "a"

```
Turn 4  exec: python3 .skill/scripts/scan.py sessions/<new_id>
Turn 5  exec: python3 .skill/scripts/qa-step.py sessions/<new_id> "a"
Turn 6  message: (omit target) message=<qa-step stdout, the first finding>
```

And so on. **One `message` send per Requester turn.** Scripts are your orchestration; the `message` tool is how the Requester sees anything.

## End of loop

When cursor has no pending findings:

```bash
python3 .skill/scripts/merge-draft.py <session_id>
python3 .skill/scripts/final-gate.py <session_id> --verify-final
```

If final-gate verdict is `READY` or `READY_WITH_OPEN_ITEMS`:
- Publish to Lark doc via native `feishu_doc.create` + share to Requester (edit) + Responder (view)
- Send 6-section summary to both parties via `feishu_chat`
- Mark `meta.status = closed`

If verdict is `FAIL`:
- Reopen Q&A loop with the new BLOCKERs at the front of the cursor

## What you MUST NOT do

- Reply to the Requester with tool previews, bash commands, stderr, or tracebacks. The gateway's display policy should suppress them at the platform layer, but don't relay them in message text even so.
- Compose the final brief yourself — `merge-draft.py` is the only path to a revised document.
- Skip `ingest.py` for PDF / image / audio attachments — the Lark inbound message only gives you a URL or file handle; `ingest.py` does the actual extraction.
- Read `sessions/*/` contents of OTHER workspaces — you only ever have access to your own `.` (cwd). (openclaw enforces this architecturally, but don't try.)

## Context keepers

- `responder-profile.md` — Responder's standards. Symlinked to global `~/.openclaw/review-agent/responder-profile.md`. Re-read at start of every session.
- `review_rules.md` — shared pillar thresholds / severity rules. Frozen per session.
- `USER.md` — peer identity + the Responder this peer reviews against (filled by first-DM hook)
- `owner.json` — Admin identity
- `memory/` — persistent notes across sessions for THIS peer only
