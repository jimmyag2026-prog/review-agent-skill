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

    cwd = Path.cwd().resolve()
    if "workspace-feishu-" not in str(cwd) and "workspace-wecom-" not in str(cwd):
        print(f"error: must be run from a peer workspace (got: {cwd})",
              file=sys.stderr)
        sys.exit(2)

    # Use a unique request id so multiple concurrent fetches don't collide
    req_id = uuid.uuid4().hex[:8]
    req_dir = cwd / "lark-fetch"
    req_dir.mkdir(parents=True, exist_ok=True)
    req_file = req_dir / f"{req_id}.request.json"
    out_file = req_dir / f"{req_id}.result.md"
    err_file = req_dir / f"{req_id}.error.txt"

    req_file.write_text(json.dumps({
        "url": args.url,
        "out": str(out_file),
        "err": str(err_file),
        "request_id": req_id,
        "submitted_at": time.time(),
    }) + "\n")

    print(f"submitted fetch request {req_id} (waiting up to {args.timeout}s for watcher)",
          file=sys.stderr)

    # Poll for result or error
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        if out_file.exists():
            content = out_file.read_text()
            # Cleanup
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
        if err_file.exists():
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
