#!/usr/bin/env python3
"""fetch-via-watcher.py — peer-side wrapper to fetch Lark content via watcher.

PEER-SIDE script. The peer subagent calls this when a Requester sends
a Lark wiki/docx URL. It:
  1. Validates URL is in whitelist (larksuite.com / feishu.cn wiki/docx)
  2. Writes a request file in the peer's workspace
  3. Polls (up to 60s) for the result file the watcher writes
  4. Prints the fetched content to stdout

The watcher (running as openclaw user) does the actual API call. Peer
never touches Lark credentials.

Usage:
  python3 fetch-via-watcher.py <url>
  python3 fetch-via-watcher.py <url> --out <file>     # write to file instead

Exit codes:
  0  ok
  2  bad args / url not whitelisted
  3  watcher didn't respond in time (timeout)
  4  fetcher reported an error (see <session-dir>/lark-fetched-error.txt)
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path


URL_PATTERN = re.compile(
    r"https?://(?:[\w-]+\.)*(larksuite\.com|feishu\.cn|feishu-pre\.cn)"
    r"/(wiki|docx)/([A-Za-z0-9_-]+)",
    re.IGNORECASE,
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--out", default=None,
                    help="write fetched content to this file (default: stdout)")
    ap.add_argument("--timeout", type=int, default=60,
                    help="seconds to wait for watcher (default 60)")
    args = ap.parse_args()

    if not URL_PATTERN.search(args.url):
        print(f"error: URL not in whitelist (only larksuite.com / feishu.cn "
              f"wiki|docx URLs accepted): {args.url}", file=sys.stderr)
        sys.exit(2)

    # cwd validation: peer should be in its workspace.
    # In docker-sandbox mode this is /workspace (bind-mounted from host's
    # workspace-feishu-<oid>/ dir). In non-sandboxed mode it's the host
    # workspace dir directly. Accept either.
    cwd = Path.cwd().resolve()
    cwd_str = str(cwd)
    if cwd_str != "/workspace" and "workspace-feishu-" not in cwd_str \
            and "workspace-wecom-" not in cwd_str:
        print(f"error: must be run from a peer workspace (got: {cwd}; "
              f"expected /workspace or .../workspace-feishu-<oid>/)",
              file=sys.stderr)
        sys.exit(2)

    # The watcher (running on host) discovers request files via glob
    # against the host's workspace dirs; the peer's docker bind-mount
    # makes its writes visible there. But the request's `out` / `err`
    # paths must be writable BY THE WATCHER (which runs on host with no
    # /workspace dir). So we store FILENAMES only — watcher resolves
    # them against the host workspace dir it found the request in.
    req_id = uuid.uuid4().hex[:8]
    req_dir = cwd / "lark-fetch"
    req_dir.mkdir(parents=True, exist_ok=True)
    req_file = req_dir / f"{req_id}.request.json"
    # Peer-side paths (used for polling)
    peer_out = req_dir / f"{req_id}.result.md"
    peer_err = req_dir / f"{req_id}.error.txt"

    req_file.write_text(json.dumps({
        "url": args.url,
        # Filename only — watcher resolves to <host_workspace>/lark-fetch/<filename>
        "out_filename": f"{req_id}.result.md",
        "err_filename": f"{req_id}.error.txt",
        "request_id": req_id,
        "submitted_at": time.time(),
    }) + "\n")
    out_file = peer_out
    err_file = peer_err

    print(f"submitted fetch request {req_id} (waiting up to {args.timeout}s for watcher)",
          file=sys.stderr)

    # Poll for result or error.
    # Watcher writes out_file (via atomic .tmp+rename) on success, or err_file
    # with content on failure. Empty err_file = transient (watcher's stderr
    # redirect created an empty file but subprocess hasn't finished yet) —
    # ignore until non-empty.
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        if out_file.exists() and out_file.stat().st_size > 0:
            content = out_file.read_text()
            try: req_file.unlink(missing_ok=True)
            except: pass
            try: out_file.unlink()
            except: pass
            if args.out:
                Path(args.out).write_text(content)
                print(f"ok: wrote {len(content)} chars to {args.out}",
                      file=sys.stderr)
            else:
                sys.stdout.write(content)
            return
        if err_file.exists() and err_file.stat().st_size > 0:
            err = err_file.read_text()
            try: req_file.unlink(missing_ok=True)
            except: pass
            try: err_file.unlink()
            except: pass
            print(f"watcher reported fetch error: {err}", file=sys.stderr)
            sys.exit(4)
        time.sleep(0.5)

    print(f"error: watcher didn't respond in {args.timeout}s. "
          f"Is review-agent-seeder running? "
          f"(check ~/.openclaw/seeder.log on the host)",
          file=sys.stderr)
    sys.exit(3)


if __name__ == "__main__":
    main()
