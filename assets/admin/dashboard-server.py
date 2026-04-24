#!/usr/bin/env python3
"""Local read-only web dashboard for review-agent Admin.

Serves a browser-friendly view of all users + sessions at http://127.0.0.1:8765
(default port). Localhost bind only — no external network required.

Read-only: no endpoint mutates state. The human admin uses this to see active
sessions, closed summaries, dissent, and Responder-simulation questions at a
glance without running CLI commands.

Usage:
  dashboard-server.py [--port 8765] [--host 127.0.0.1] [--open]
"""
import argparse
import json
import os
import re
import sys
import webbrowser
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse, quote as urlquote, unquote


ROOT = Path(os.environ.get("REVIEW_AGENT_WORKSPACE_ROOT",
                           Path.home() / ".openclaw"))
# v2: peers live at ROOT / workspace-<channel>-dm-<peer_id>/
PEER_DIR_RE = re.compile(r"^workspace-(?P<channel>[a-z]+)-dm-(?P<peer_id>[\w-]+)$")


# ─────────────────────────────────────────────────────────────
# Data readers (all read-only)
# ─────────────────────────────────────────────────────────────

def _iter_peer_workspaces():
    """Yield (workspace_path, channel, peer_id) triples."""
    if not ROOT.exists():
        return
    for p in sorted(ROOT.iterdir()):
        if not p.is_dir():
            continue
        m = PEER_DIR_RE.match(p.name)
        if m:
            yield p, m.group("channel"), m.group("peer_id")


def list_users():
    """Each peer workspace = one entry. v2 architecture: every DMer gets a
    dedicated subagent + workspace; they map 1-1 to Requesters."""
    out = []
    for ws, channel, peer_id in _iter_peer_workspaces():
        owner = {}
        try:
            owner_file = ws / "owner.json"
            if owner_file.exists():
                owner = json.loads(owner_file.read_text())
        except Exception:
            pass
        peer_name = peer_id
        user_md_path = ws / "USER.md"
        if user_md_path.exists():
            txt = user_md_path.read_text()
            m = re.search(r"\*\*Peer display name:\*\*\s*(.+)", txt)
            if m and m.group(1).strip() and not m.group(1).strip().startswith("("):
                peer_name = m.group(1).strip()
        sessions = list_sessions(peer_id, _ws=ws)
        active = sum(1 for s in sessions if s["status"] != "closed")
        closed = sum(1 for s in sessions if s["status"] == "closed")
        out.append({
            "open_id": peer_id,
            "channel": channel,
            "workspace": str(ws),
            "display_name": peer_name,
            "roles": ["Requester"],
            "responder": owner.get("responder_open_id"),
            "responder_name": owner.get("responder_name"),
            "created_at": None,
            "active_count": active,
            "closed_count": closed,
            "has_profile": (ws / "responder-profile.md").exists(),
            "has_active_pointer": bool(
                next((s for s in sessions if s["status"] in
                     ("active", "awaiting_subject_confirmation")), None)
            ),
        })
    return out


def list_sessions(open_id, _ws=None):
    ws = _ws
    if ws is None:
        for p in (ROOT.iterdir() if ROOT.exists() else ()):
            m = PEER_DIR_RE.match(p.name)
            if m and m.group("peer_id") == open_id:
                ws = p
                break
    if ws is None:
        return []
    sdir = ws / "sessions"
    out = []
    if not sdir.exists(): return out
    for s in sorted(sdir.iterdir(), reverse=True):
        if not s.is_dir(): continue
        m = s / "meta.json"
        if not m.exists(): continue
        try:
            meta = json.load(open(m))
            anns = load_jsonl(s / "annotations.jsonl")
            out.append({
                "session_id": meta.get("session_id", s.name),
                "subject": meta.get("subject", ""),
                "label": meta.get("label"),
                "tags": meta.get("tags", []),
                "status": meta.get("status", "?"),
                "round": meta.get("round", 0),
                "termination": meta.get("termination"),
                "created_at": meta.get("created_at"),
                "last_activity_at": meta.get("last_activity_at"),
                "closed_at": meta.get("closed_at"),
                "n_findings": len(anns),
                "n_open": sum(1 for a in anns if a.get("status") == "open"),
                "n_accepted": sum(1 for a in anns if a.get("status") == "accepted"),
                "n_rejected": sum(1 for a in anns if a.get("status") == "rejected"),
                "n_unresolvable": sum(1 for a in anns if a.get("status") == "unresolvable"),
            })
        except Exception: pass
    return out


def load_jsonl(path):
    if not os.path.exists(path): return []
    out = []
    for line in open(path):
        line = line.strip()
        if not line: continue
        try: out.append(json.loads(line))
        except: pass
    return out


def find_session(session_id):
    # v2: walk all per-peer workspaces
    for ws, _channel, _peer_id in _iter_peer_workspaces():
        p = ws / "sessions" / session_id
        if p.is_dir():
            return p
    return None


def session_detail(session_id):
    sd = find_session(session_id)
    if not sd: return None
    meta = json.load(open(sd / "meta.json"))
    anns = load_jsonl(sd / "annotations.jsonl")
    cursor = json.load(open(sd / "cursor.json")) if (sd / "cursor.json").exists() else {}
    conv = load_jsonl(sd / "conversation.jsonl")
    dissent_md = (sd / "dissent.md").read_text() if (sd / "dissent.md").exists() else ""
    summary_md = (sd / "summary.md").read_text() if (sd / "summary.md").exists() else ""
    audit_md = (sd / "summary_audit.md").read_text() if (sd / "summary_audit.md").exists() else ""
    normalized_md = (sd / "normalized.md").read_text() if (sd / "normalized.md").exists() else ""
    final_files = []
    fd = sd / "final"
    if fd.exists():
        for f in fd.iterdir():
            if f.is_file():
                final_files.append({"name": f.name, "content": f.read_text()[:10000]})
    return {
        "meta": meta,
        "annotations": anns,
        "cursor": cursor,
        "conversation": conv[-50:],   # last 50 turns
        "dissent_md": dissent_md,
        "summary_md": summary_md,
        "summary_audit_md": audit_md,
        "normalized_md": normalized_md[:15000],
        "final_files": final_files,
        "session_dir": str(sd),
    }


# ─────────────────────────────────────────────────────────────
# HTML rendering (no CDN, no JS framework)
# ─────────────────────────────────────────────────────────────

CSS = """
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro", "PingFang SC", sans-serif;
         margin: 0; padding: 0; background: #f7f7f8; color: #1a1a1a; line-height: 1.55; }
  header { background: #1a1a2e; color: #eee; padding: 14px 24px; display: flex; align-items: center; gap: 20px; }
  header h1 { margin: 0; font-size: 17px; font-weight: 600; }
  header .meta { font-size: 12px; color: #aaa; margin-left: auto; }
  main { padding: 20px 24px; max-width: 1300px; margin: 0 auto; }
  .card { background: white; border-radius: 6px; padding: 16px 20px; margin-bottom: 16px;
          box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
  .card h2 { margin: 0 0 10px 0; font-size: 15px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; padding: 6px 8px; background: #f0f0f2; font-weight: 600;
       border-bottom: 1px solid #ddd; }
  td { padding: 6px 8px; border-bottom: 1px solid #eee; vertical-align: top; }
  tr:hover { background: #fafafb; }
  a { color: #2353b5; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .pill { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px;
          font-weight: 500; }
  .pill.active { background: #e8f4ff; color: #0366d6; }
  .pill.closed { background: #eee; color: #888; }
  .pill.admin { background: #fff0e8; color: #d6800c; }
  .pill.responder { background: #e8f5e9; color: #2e7d32; }
  .pill.requester { background: #e8eaf6; color: #3949ab; }
  .pill.blocker { background: #fee; color: #c62828; }
  .pill.improvement { background: #fffbe6; color: #8a6d00; }
  .pill.nice { background: #f0f4f8; color: #666; }
  .count { color: #666; font-size: 11px; }
  pre { background: #0d1117; color: #c9d1d9; padding: 12px; border-radius: 4px;
        overflow-x: auto; font-size: 12px; line-height: 1.5; }
  pre.md { background: #fafafa; color: #1a1a1a; border: 1px solid #eee; white-space: pre-wrap; }
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .finding { padding: 10px 12px; background: #fafafa; border-left: 3px solid #ccc;
             margin-bottom: 8px; border-radius: 4px; font-size: 13px; }
  .finding.open.BLOCKER { border-left-color: #c62828; }
  .finding.open.IMPROVEMENT { border-left-color: #f9a825; }
  .finding.accepted { border-left-color: #2e7d32; opacity: 0.75; }
  .finding.rejected { border-left-color: #6a1b9a; background: #fef5ff; }
  .finding.modified { border-left-color: #0277bd; }
  .finding.unresolvable { border-left-color: #37474f; }
  .finding .hdr { font-size: 11px; color: #666; margin-bottom: 4px; }
  .finding .issue { font-weight: 500; margin-bottom: 4px; }
  .finding .suggest { color: #444; font-size: 12px; }
  .finding .reply { margin-top: 6px; padding: 4px 8px; background: #eee; border-radius: 3px;
                   font-size: 12px; font-style: italic; }
  .subtle { color: #888; font-size: 12px; }
  nav { font-size: 12px; margin-bottom: 14px; }
  nav a { color: #666; }
  .tabs { border-bottom: 1px solid #ddd; margin-bottom: 12px; }
  .tabs a { display: inline-block; padding: 6px 12px; color: #666; border-bottom: 2px solid transparent;
            margin-right: 4px; font-size: 13px; }
  .tabs a.on { color: #1a1a2e; border-bottom-color: #1a1a2e; }
  .update-banner { margin: 8px 16px 0; padding: 8px 12px; border-radius: 4px;
                   background: #fff7e6; border: 1px solid #ffd591; color: #874d00;
                   font-size: 13px; }
  .update-banner a { color: #874d00; text-decoration: underline; }
</style>
"""


def html_escape(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                   .replace('"', "&quot;"))


def _update_banner_html():
    """Returns a small HTML banner if an update is available, else ''.
    Reads ~/.review-agent/.update-check.json — never hits the network from
    the web handler (that runs in a request thread). A background refresh
    is triggered on miss, but the current page shows no banner until the
    next hit."""
    import subprocess, threading
    cache = ROOT / ".update-check.json"
    try:
        if cache.exists():
            d = json.loads(cache.read_text())
            local, remote = d.get("local"), d.get("remote_tag")
            if local and remote:
                from re import match as _m
                def _t(v):
                    v = (v or "").lstrip("v")
                    mm = _m(r"^(\d+)\.(\d+)(?:\.(\d+))?", v)
                    return tuple(int(x or 0) for x in mm.groups()) if mm else (0, 0, 0)
                if _t(remote) > _t(local):
                    url = html_escape(d.get("remote_url", ""))
                    return (f'<div class="update-banner">'
                            f'📦 update available: <b>{html_escape(remote)}</b> '
                            f'(you have {html_escape(local)}) — '
                            f'<a href="{url}" target="_blank">release notes</a>'
                            f'</div>')
    except Exception:
        pass

    # Trigger a background refresh if the cache is missing or old. Non-blocking.
    def _bg_refresh():
        try:
            subprocess.run(
                ["python3", str(Path(__file__).parent / "check-updates.py"), "--json"],
                capture_output=True, timeout=10,
            )
        except Exception:
            pass
    threading.Thread(target=_bg_refresh, daemon=True).start()
    return ""


def render_page(title, body, refresh=30):
    banner = _update_banner_html()
    return f"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><title>{html_escape(title)}</title>
<meta http-equiv="refresh" content="{refresh}">
{CSS}
</head><body>
<header>
<h1>review-agent · admin dashboard</h1>
<span class="subtle">{html_escape(str(ROOT))}</span>
<span class="meta">auto-refresh {refresh}s · {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</span>
</header>
{banner}
<main>{body}</main>
</body></html>"""


def render_overview():
    users = list_users()
    total_active = sum(u["active_count"] for u in users)
    total_closed = sum(u["closed_count"] for u in users)

    by_role = {"Admin": [], "Responder": [], "Requester": []}
    for u in users:
        for r in u["roles"]:
            if r in by_role: by_role[r].append(u)

    nav = '<nav><a href="/">overview</a></nav>'

    # Summary card
    summary = f"""
    <div class="card">
      <h2>概览</h2>
      <table>
        <tr><th>Users</th><td>{len(users)}</td></tr>
        <tr><th>Responders</th><td>{len(by_role['Responder'])}</td></tr>
        <tr><th>Requesters</th><td>{len(by_role['Requester'])}</td></tr>
        <tr><th>Active sessions</th><td>{total_active}</td></tr>
        <tr><th>Closed sessions</th><td>{total_closed}</td></tr>
      </table>
    </div>"""

    # Users table
    user_rows = []
    for u in users:
        roles = " ".join(f'<span class="pill {r.lower()}">{r}</span>' for r in u["roles"])
        active_marker = ' <span class="pill active">in-flight</span>' if u["has_active_pointer"] else ""
        user_rows.append(f"""
        <tr>
          <td><code>{html_escape(u['open_id'])}</code></td>
          <td>{html_escape(u['display_name'])}</td>
          <td>{roles}{active_marker}</td>
          <td>{u['active_count']} <span class="count">active</span></td>
          <td>{u['closed_count']} <span class="count">closed</span></td>
          <td><a href="/user/{urlquote(u['open_id'])}">详情 →</a></td>
        </tr>""")

    users_table = f"""
    <div class="card">
      <h2>Users ({len(users)})</h2>
      <table>
        <thead>
          <tr><th>open_id</th><th>name</th><th>roles</th><th>active</th><th>closed</th><th></th></tr>
        </thead>
        <tbody>
        {"".join(user_rows) or '<tr><td colspan="6" class="subtle">no users yet</td></tr>'}
        </tbody>
      </table>
    </div>"""

    # Active sessions across all requesters
    active_rows = []
    for u in users:
        if "Requester" in u["roles"]:
            for s in list_sessions(u["open_id"]):
                if s["status"] != "closed":
                    active_rows.append({"user": u, "session": s})
    active_rows.sort(key=lambda x: x["session"].get("last_activity_at", ""), reverse=True)

    active_html = []
    for row in active_rows:
        u, s = row["user"], row["session"]
        active_html.append(f"""
        <tr>
          <td><a href="/session/{urlquote(s['session_id'])}"><code>{html_escape(s['session_id'][:24])}</code></a></td>
          <td>{html_escape(u['display_name'])}</td>
          <td>{html_escape(s['subject'][:40])}</td>
          <td>{s['round']}</td>
          <td><span class="pill active">{html_escape(s['status'])}</span></td>
          <td>{s['n_open']}/{s['n_findings']} open</td>
          <td class="subtle">{html_escape(s.get('last_activity_at','')[:19])}</td>
        </tr>""")

    active_card = f"""
    <div class="card">
      <h2>Active sessions ({len(active_rows)})</h2>
      <table>
        <thead>
          <tr><th>session_id</th><th>requester</th><th>subject</th><th>round</th>
              <th>status</th><th>findings</th><th>last activity</th></tr>
        </thead>
        <tbody>
        {"".join(active_html) or '<tr><td colspan="7" class="subtle">no active sessions</td></tr>'}
        </tbody>
      </table>
    </div>"""

    # Recent closed
    closed_rows = []
    for u in users:
        if "Requester" in u["roles"]:
            for s in list_sessions(u["open_id"]):
                if s["status"] == "closed":
                    closed_rows.append({"user": u, "session": s})
    closed_rows.sort(key=lambda x: x["session"].get("closed_at", ""), reverse=True)

    closed_html = []
    for row in closed_rows[:15]:
        u, s = row["user"], row["session"]
        tags = " ".join(f'<span class="pill nice">{html_escape(t)}</span>' for t in s.get("tags", []))
        closed_html.append(f"""
        <tr>
          <td><a href="/session/{urlquote(s['session_id'])}"><code>{html_escape(s['session_id'][:24])}</code></a></td>
          <td>{html_escape(u['display_name'])}</td>
          <td>{html_escape(s['subject'][:40])} {tags}</td>
          <td>{s.get('termination','?')}</td>
          <td class="subtle">{html_escape(s.get('closed_at','')[:19])}</td>
        </tr>""")

    closed_card = f"""
    <div class="card">
      <h2>Recent closed sessions ({len(closed_rows)}，show ≤15)</h2>
      <table>
        <thead>
          <tr><th>session_id</th><th>requester</th><th>subject / tags</th>
              <th>termination</th><th>closed_at</th></tr>
        </thead>
        <tbody>
        {"".join(closed_html) or '<tr><td colspan="5" class="subtle">none</td></tr>'}
        </tbody>
      </table>
    </div>"""

    return render_page("review-agent dashboard", nav + summary + users_table + active_card + closed_card)


def render_user(open_id):
    u = next((x for x in list_users() if x["open_id"] == open_id), None)
    if not u:
        return render_page("User not found", f'<div class="card">user <code>{html_escape(open_id)}</code> not found</div>')

    sessions = list_sessions(open_id)
    roles = " ".join(f'<span class="pill {r.lower()}">{r}</span>' for r in u["roles"])
    nav = f'<nav><a href="/">← overview</a> · user <code>{html_escape(open_id)}</code></nav>'

    info = f"""
    <div class="card">
      <h2>{html_escape(u['display_name'])} <span class="subtle">· {html_escape(open_id)}</span></h2>
      <p>Roles: {roles}</p>
      <p class="subtle">Created: {html_escape(u.get('created_at','?'))} · Active sessions: {u['active_count']} · Closed: {u['closed_count']}</p>
    </div>"""

    rows = []
    for s in sessions:
        tags = " ".join(f'<span class="pill nice">{html_escape(t)}</span>' for t in s.get("tags", []))
        rows.append(f"""
        <tr>
          <td><a href="/session/{urlquote(s['session_id'])}"><code>{html_escape(s['session_id'])}</code></a></td>
          <td>{html_escape(s['subject'])} {tags}</td>
          <td>{s['round']}</td>
          <td><span class="pill {'closed' if s['status']=='closed' else 'active'}">{html_escape(s['status'])}</span></td>
          <td>{s['n_accepted']}✓ {s['n_open']}? {s['n_rejected']}✗ {s['n_unresolvable']}⊘</td>
          <td class="subtle">{html_escape(s.get('last_activity_at','')[:19])}</td>
        </tr>""")

    sessions_card = f"""
    <div class="card">
      <h2>Sessions ({len(sessions)})</h2>
      <table>
        <thead>
          <tr><th>session_id</th><th>subject</th><th>round</th>
              <th>status</th><th>findings (✓ open ✗ ⊘)</th><th>last activity</th></tr>
        </thead>
        <tbody>{"".join(rows) or '<tr><td colspan="6" class="subtle">none</td></tr>'}</tbody>
      </table>
    </div>"""

    return render_page(f"User {u['display_name']}", nav + info + sessions_card)


def render_session(session_id):
    detail = session_detail(session_id)
    if not detail:
        return render_page("Session not found", f'<div class="card">session <code>{html_escape(session_id)}</code> not found</div>')

    meta = detail["meta"]
    req_oid = meta.get("requester_open_id", "")
    nav = f'<nav><a href="/">← overview</a> · <a href="/user/{urlquote(req_oid)}">requester</a> · session <code>{html_escape(session_id)}</code></nav>'

    tags_html = " ".join(f'<span class="pill nice">{html_escape(t)}</span>' for t in meta.get("tags", []))
    info = f"""
    <div class="card">
      <h2>{html_escape(meta.get('subject',''))} <span class="subtle">· {html_escape(session_id)}</span></h2>
      <p>{tags_html}</p>
      <p class="subtle">
        Requester: <code>{html_escape(meta.get('requester_open_id',''))}</code> ·
        Responder: <code>{html_escape(meta.get('responder_open_id',''))}</code> ·
        Round: {meta.get('round', 0)} ·
        Status: <span class="pill {'closed' if meta.get('status')=='closed' else 'active'}">{html_escape(meta.get('status','?'))}</span> ·
        Termination: {html_escape(meta.get('termination') or '-')}
      </p>
      <p class="subtle">Created: {html_escape(meta.get('created_at',''))} · Closed: {html_escape(meta.get('closed_at') or '-')}</p>
      <p class="subtle">Folder: <code>{html_escape(detail['session_dir'])}</code></p>
      {f'<p><b>Label</b>: {html_escape(meta.get("label",""))}</p>' if meta.get('label') else ''}
      {f'<p class="subtle"><b>Notes</b>: {html_escape(meta.get("notes",""))}</p>' if meta.get('notes') else ''}
    </div>"""

    # Findings
    findings_html = []
    anns = detail["annotations"]
    for a in anns:
        sev = a.get("severity", "IMPROVEMENT")
        pillar = a.get("pillar") or a.get("axis", "?")
        status = a.get("status", "open")
        src = a.get("source", "?")
        sim_q = a.get("simulated_question", "")
        reply = a.get("reply", "")
        findings_html.append(f"""
        <div class="finding {status} {sev}">
          <div class="hdr">
            <b>[{html_escape(a.get('id','?'))}]</b>
            <span class="pill {sev.lower()}">{sev}</span>
            <span class="subtle">· {html_escape(pillar)} · {html_escape(src)} · status=<b>{status}</b></span>
          </div>
          <div class="issue">{html_escape(a.get('issue','')[:500])}</div>
          <div class="suggest">{html_escape(a.get('suggest','')[:500])}</div>
          {f'<div class="suggest"><i>Simulated Q</i>: {html_escape(sim_q)}</div>' if sim_q else ''}
          {f'<div class="reply">Requester: {html_escape(reply)}</div>' if reply else ''}
        </div>""")

    findings_card = f"""
    <div class="card">
      <h2>Findings ({len(anns)})</h2>
      {"".join(findings_html) or '<p class="subtle">none</p>'}
    </div>"""

    # Summary
    summary_card = ""
    if detail["summary_md"]:
        summary_card = f"""
        <div class="card">
          <h2>summary.md (decision brief)</h2>
          <pre class="md">{html_escape(detail['summary_md'])}</pre>
        </div>"""

    # Conversation (tail)
    conv_rows = []
    for e in detail["conversation"]:
        role = e.get("role", "?")
        text = e.get("text", "")[:400]
        ts = e.get("ts", "")[:19]
        extra = ""
        if e.get("finding_id"): extra = f" <span class='subtle'>· finding={e.get('finding_id')}</span>"
        conv_rows.append(f"""
        <tr>
          <td class="subtle">{html_escape(ts)}</td>
          <td><span class="pill {'requester' if role=='requester' else 'admin'}">{role}</span>{extra}</td>
          <td><pre class="md" style="max-height: 200px; overflow: auto;">{html_escape(text)}</pre></td>
        </tr>""")

    conv_card = f"""
    <div class="card">
      <h2>Conversation (last {len(detail['conversation'])} turns)</h2>
      <table>
        <thead><tr><th>ts</th><th>role</th><th>text</th></tr></thead>
        <tbody>{"".join(conv_rows) or '<tr><td colspan="3" class="subtle">empty</td></tr>'}</tbody>
      </table>
    </div>"""

    dissent_card = ""
    if detail["dissent_md"].strip():
        dissent_card = f"""
        <div class="card">
          <h2>Dissent log</h2>
          <pre class="md">{html_escape(detail['dissent_md'])}</pre>
        </div>"""

    return render_page(f"Session {session_id}",
                       nav + info + findings_card + summary_card + dissent_card + conv_card)


# ─────────────────────────────────────────────────────────────
# HTTP server
# ─────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        try:
            if path == "/":
                body = render_overview()
            elif path.startswith("/user/"):
                oid = unquote(path.split("/user/", 1)[1])
                body = render_user(oid)
            elif path.startswith("/session/"):
                sid = unquote(path.split("/session/", 1)[1])
                body = render_session(sid)
            elif path == "/healthz":
                self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
            else:
                self.send_response(404); self.end_headers(); self.wfile.write(b"not found"); return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
        except Exception as e:
            self.send_response(500)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"error: {e}".encode())

    def log_message(self, format, *args):
        # Silence default access log to keep terminal clean
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1",
                   help="bind address; keep as 127.0.0.1 for local-only access")
    ap.add_argument("--open", action="store_true", help="open in browser on start")
    args = ap.parse_args()

    # Safety: warn if binding non-localhost
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print(f"⚠ binding to {args.host}:{args.port} — dashboard exposed beyond localhost!",
              file=sys.stderr)
        print("   sessions content will be readable by any device on the network.", file=sys.stderr)

    url = f"http://{args.host}:{args.port}/"
    print(f"review-agent dashboard serving at {url}")
    print(f"  root: {ROOT}")
    print(f"  Ctrl+C to stop")

    if args.open:
        webbrowser.open(url)

    try:
        HTTPServer((args.host, args.port), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nshutdown")


if __name__ == "__main__":
    main()
