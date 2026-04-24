# BOOTSTRAP.md

First-run checklist for THIS peer's subagent. Run once on the first inbound message after the workspace is cloned.

1. Read `IDENTITY.md`, `SOUL.md`, `AGENTS.md`, `HEARTBEAT.md` (in that order). Internalize the persona.
2. Read `responder-profile.md` (symlink → global). This is your north star for what "signing-ready" means.
3. Read `review_rules.md` — pillar thresholds.
4. Read `owner.json` — note the Admin's identity.
5. Check `USER.md` — if peer metadata isn't filled yet (first DM of a new peer), populate from Lark profile API and write back.
6. Verify the `review-agent` skill is loaded: `openclaw skills list` should show it under "loaded". If not, the subagent should still work for chat but won't have review commands.
7. Greet the Requester ONCE briefly: "Hi, 我是 {responder_name} 的 Review Agent. 发材料过来我就帮你走一遍 review；或 `/review help` 看命令。"

After bootstrap: fall back to HEARTBEAT.md-only checks each turn.
