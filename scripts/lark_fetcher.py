#!/usr/bin/env python3
"""lark_fetcher.py — fetch Lark wiki/docx content via Lark Open API.

WATCHER-SIDE script. Runs as the openclaw user (which has FS access to
openclaw.json with feishu app credentials). Peer subagents do NOT call
this directly — peers write a request file, the watcher detects it,
runs this fetcher, and writes the fetched content to peer's workspace.

This way Lark credentials never enter peer's sandbox.

Usage:
  python3 lark_fetcher.py <url> <output-file>

Supported URL formats (whitelist enforced):
  https://<domain>.larksuite.com/wiki/<node_token>
  https://<domain>.larksuite.com/docx/<doc_id>
  https://<domain>.feishu.cn/wiki/<node_token>
  https://<domain>.feishu.cn/docx/<doc_id>

Returns markdown plain text. Output file written atomically.

Exit codes:
  0  ok
  2  bad args
  3  url not in whitelist
  4  url type not yet implemented (drive/file/sheet)
  5  openclaw.json missing or no feishu creds
  6  Lark API error (token / node lookup / docx fetch)
"""
from __future__ import annotations
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path


URL_PATTERN = re.compile(
    # Accept any number of subdomain levels (0..N) before the apex —
    # Lark uses multi-level subdomains for region pinning, e.g.
    # jsg8iy06jkpz.sg.larksuite.com (tenant.region.larksuite.com).
    r"https?://(?:[\w-]+\.)*(larksuite\.com|feishu\.cn|feishu-pre\.cn)"
    r"/(wiki|docx)/([A-Za-z0-9_-]+)",
    re.IGNORECASE,
)


def _read_credentials():
    """Find openclaw.json by trying $OPENCLAW_HOME, /home/openclaw, $HOME."""
    candidates = []
    if os.environ.get("OPENCLAW_HOME"):
        candidates.append(Path(os.environ["OPENCLAW_HOME"]) / ".openclaw" / "openclaw.json")
    candidates.extend([
        Path("/home/openclaw/.openclaw/openclaw.json"),
        Path.home() / ".openclaw" / "openclaw.json",
    ])
    for p in candidates:
        if p.exists():
            cfg_path = p
            break
    else:
        print(f"error: openclaw.json not found in any of {candidates}",
              file=sys.stderr)
        sys.exit(5)

    try:
        cfg = json.loads(cfg_path.read_text())
    except Exception as e:
        print(f"error: cannot parse {cfg_path}: {e}", file=sys.stderr)
        sys.exit(5)

    feishu = cfg.get("channels", {}).get("feishu", {})
    accounts = feishu.get("accounts", {})
    default = accounts.get("default", {})
    app_id = default.get("appId") or feishu.get("appId")
    app_secret = default.get("appSecret") or feishu.get("appSecret")
    if not app_id or not app_secret:
        print(f"error: feishu app_id / app_secret missing in {cfg_path}",
              file=sys.stderr)
        sys.exit(5)

    # Pick API base by domain
    domain = (default.get("domain") or feishu.get("domain") or "lark").lower()
    api_base = ("https://open.larksuite.com" if domain == "lark"
                else "https://open.feishu.cn")
    return app_id, app_secret, api_base


def _http_call(req, timeout):
    """Call urlopen; if Lark returns non-2xx, decode the body so we can
    surface the actual `{code, msg}` instead of just 'HTTP 400'."""
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            return json.loads(body)
        except Exception:
            return {"code": -1, "msg": f"HTTP {e.code}: {body[:300]}"}


def _http_post(url, body, headers=None, timeout=15):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", **(headers or {})},
        method="POST",
    )
    return _http_call(req, timeout)


def _http_get(url, headers=None, timeout=20):
    req = urllib.request.Request(url, headers=headers or {})
    return _http_call(req, timeout)


def _get_tenant_token(app_id, app_secret, api_base):
    data = _http_post(
        f"{api_base}/open-apis/auth/v3/tenant_access_token/internal",
        {"app_id": app_id, "app_secret": app_secret},
    )
    if data.get("code") != 0:
        print(f"error: tenant_access_token failed: {data}", file=sys.stderr)
        sys.exit(6)
    return data["tenant_access_token"]


def _fetch_docx(token, api_base, doc_id, title=""):
    """Fetch docx raw content (markdown)."""
    auth = {"Authorization": f"Bearer {token}"}
    data = _http_get(
        f"{api_base}/open-apis/docx/v1/documents/{doc_id}/raw_content",
        headers=auth,
    )
    if data.get("code") != 0:
        print(f"error: docx fetch failed (doc_id={doc_id}): {data}", file=sys.stderr)
        sys.exit(6)
    content = data.get("data", {}).get("content", "")
    header = f"# {title}\n\n" if title else ""
    return header + content + "\n"


def _fetch_wiki(token, api_base, node_token):
    """Resolve wiki node → docx → fetch."""
    auth = {"Authorization": f"Bearer {token}"}
    info = _http_get(
        f"{api_base}/open-apis/wiki/v2/spaces/get_node?token={node_token}",
        headers=auth,
    )
    if info.get("code") != 0:
        print(f"error: wiki node lookup failed (node={node_token}): {info}",
              file=sys.stderr)
        sys.exit(6)
    node = info.get("data", {}).get("node", {})
    obj_type = node.get("obj_type", "")
    title = node.get("title", "")
    if obj_type != "docx":
        print(f"error: wiki node type '{obj_type}' not supported (only docx)",
              file=sys.stderr)
        sys.exit(4)
    return _fetch_docx(token, api_base, node["obj_token"], title)


def main():
    if len(sys.argv) != 3:
        print("usage: lark_fetcher.py <url> <output-file>", file=sys.stderr)
        sys.exit(2)
    url, out_path = sys.argv[1], sys.argv[2]

    m = URL_PATTERN.search(url)
    if not m:
        print(f"error: URL not in whitelist (only larksuite.com/feishu.cn "
              f"wiki|docx URLs accepted): {url}", file=sys.stderr)
        sys.exit(3)

    kind = m.group(2).lower()
    token_part = m.group(3)

    app_id, app_secret, api_base = _read_credentials()
    tenant_token = _get_tenant_token(app_id, app_secret, api_base)

    if kind == "wiki":
        content = _fetch_wiki(tenant_token, api_base, token_part)
    elif kind == "docx":
        content = _fetch_docx(tenant_token, api_base, token_part)
    else:
        print(f"error: url kind '{kind}' not implemented", file=sys.stderr)
        sys.exit(4)

    # Atomic write
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(out.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.rename(out)
    print(f"ok: wrote {len(content)} chars to {out}")


if __name__ == "__main__":
    main()
