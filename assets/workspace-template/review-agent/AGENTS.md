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
| Plain chat + **attachment** (PDF / image / audio / Lark doc URL / Google doc URL) | 🚨 **start review immediately**, no "你想怎么处理" dialogue |
| Plain chat + structured proposal (>300 chars with headers / tables / numbered options) | start review (ask one confirming Q if ambiguous) |
| Explicit ask wording ("请批准 X", "approve this", "帮我决定 A 还是 B") | start review |
| Keyword triggers (see SOUL.md six-dimension list) | start review |
| Weak signal ("帮我看看", no material attached) | ONE clarifying question: "这条要走 review 流程，还是普通聊天？" |
| Plain chat, no review signal | normal response |

## start-review flow (what "start" does internally)

1. **Create session dir**: `sessions/<YYYYMMDD-HHMMSS>-<subject-slug>/{input,final}/`
2. **Save inbound**: write the Requester's message text to `sessions/<id>/input/initial.md`; log to `conversation.jsonl`
3. **Save attachments**: download any attached files into `sessions/<id>/input/`
4. **Write meta.json**: subject, round=0, status=awaiting_subject_confirmation, created_at
5. **Freeze profile + rules**: `cp responder-profile.md sessions/<id>/profile.md` (snapshot so future edits to global don't affect in-flight sessions); `cp review_rules.md sessions/<id>/review_rules.md`
6. **Run ingest**: `python3 ~/.openclaw/skills/review-agent/scripts/ingest.py . sessions/<id>` — creates `normalized.md`. If ingest exits 3 (tool missing) → relay its stdout to Lark, mark session `ingest_failed`, STOP.
7. **Confirm topic**: send Lark message asking Requester to confirm subject scope (one line, yes/no-ish)
8. After their confirmation → run scan.py + responder simulation
9. Enter Q&A loop (qa-step.py)
10. When cursor empty → merge-draft + final-gate → deliver summary

## Q&A loop

Each Requester reply goes to:

```bash
python3 ~/.openclaw/skills/review-agent/scripts/qa-step.py <session_id> "<reply>"
```

qa-step.py classifies intent (accepted / modified / rejected / clarifying / scope change) and returns the next finding to emit. Send its stdout as the Lark reply (no modification — it's already Lark-formatted).

**Shortcut replies** (already wired in qa-step.py): `a` / `b` / `c` / `p` (pass) / custom text / free text.

## End of loop

When cursor has no pending findings:

```bash
python3 ~/.openclaw/skills/review-agent/scripts/merge-draft.py <session_id>
python3 ~/.openclaw/skills/review-agent/scripts/final-gate.py <session_id> --verify-final
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
