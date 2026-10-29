#!/usr/bin/env python3
"""Claude Code statusLine command: persists only rate_limits + a timestamp.

Reads the statusLine JSON from stdin, writes
~/Library/Application Support/YACW/state.json atomically, prints nothing
to the status bar. Nothing else from the payload is stored.
"""
import json, os, sys, time

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    limits = data.get("rate_limits")
    if not isinstance(limits, dict):
        return  # absent until the first API response / non-subscribers
    out_dir = os.path.expanduser("~/Library/Application Support/YACW")
    os.makedirs(out_dir, exist_ok=True)
    tmp = os.path.join(out_dir, "state.json.tmp")
    with open(tmp, "w") as f:
        json.dump({"updated_at": int(time.time()), "rate_limits": limits}, f)
    os.replace(tmp, os.path.join(out_dir, "state.json"))

main()
