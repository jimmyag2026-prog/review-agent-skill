# USER.md · peer metadata

_Populated when openclaw clones this template into a per-peer workspace. Don't edit by hand._

- **Peer open_id:** (auto-filled on first DM)
- **Peer display name:** (auto-filled from Lark profile at first DM)
- **Channel:** feishu
- **Reviews against Responder:** `~/.openclaw/review-agent/responder-profile.md` (global)
- **Enrolled at:** (auto)
- **Admin:** see `owner.json`

## What the agent should keep in memory across sessions with this peer

- Topic preferences (what subjects this peer tends to bring)
- Persistent blind spots observed in prior sessions (e.g. "always short on stakeholder context")
- Pet handoff patterns (how they usually want feedback — direct text vs Lark doc)

Record in `memory/` as plain markdown notes. Re-read at every session start.
