#!/usr/bin/env python3
"""
Watch pg_stat_subscription for logical replication tablesync workers
and auto-update .vscode/launch.json with GDB attach configurations.

When a new sync worker appears, a configuration entry is appended to
launch.json.  When the worker exits, the entry is removed.  VS Code
picks up file changes automatically.

NOTE: launch.json is rewritten as plain JSON on every update, so
      hand-written comments will be lost after the first write.
      Keep comments in .vscode/launch.base.jsonc if you need them.

Usage:
    python3 watch_sync_workers.py [options]

Options:
    --interval SEC   Poll interval in seconds (default: 1)
    --host    HOST   psql -h
    --port    PORT   psql -p
    --dbname  DB     psql -d
    --username USER  psql -U
"""

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parent
LAUNCH_JSON = WORKSPACE / ".vscode" / "launch.json"

# Marker used to identify auto-generated entries (VS Code ignores unknown fields)
_AUTO_MARKER = "_auto_sync_worker"
_NAME_PREFIX = "[auto] tablesync"


def _strip_jsonc(text: str) -> str:
    """Remove // line comments and /* block comments */ from JSONC."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    # Avoid stripping URLs (http://...) by requiring the // is not preceded by :
    text = re.sub(r"(?<!:)//[^\n]*", "", text)
    return text


def _load() -> dict:
    raw = LAUNCH_JSON.read_text(encoding="utf-8")
    return json.loads(_strip_jsonc(raw))


def _save(data: dict) -> None:
    LAUNCH_JSON.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n",
                           encoding="utf-8")


def _make_config(pid: int, subname: str, relid: int) -> dict:
    return {
        "name": f"{_NAME_PREFIX}: {subname} relid={relid} pid={pid}",
        _AUTO_MARKER: True,
        "type": "cppdbg",
        "request": "attach",
        "program": str(WORKSPACE / "src/backend/postgres"),
        "processId": pid,
        "MIMode": "gdb",
        "miDebuggerPath": "/usr/bin/gdb",
        "setupCommands": [
            {
                "description": "Enable pretty-printing",
                "text": "-enable-pretty-printing",
                "ignoreFailures": True,
            },
            {
                "description": "Load PostgreSQL GDB helpers",
                "text": f"source {WORKSPACE}/.gdbinit",
                "ignoreFailures": True,
            },
        ],
    }


def _is_auto(cfg: dict) -> bool:
    return bool(cfg.get(_AUTO_MARKER))


def _query_workers(psql_args: list[str]) -> dict[int, dict]:
    """Return {pid: {subname, relid}} for running tablesync workers."""
    cmd = [
        "psql", *psql_args,
        "-t", "-A", "-F", "\t", "-c",
        "SELECT pid, subname, relid "
        "FROM pg_stat_subscription "
        "WHERE worker_type = 'table synchronization' AND pid IS NOT NULL",
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        workers: dict[int, dict] = {}
        for line in r.stdout.strip().splitlines():
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            pid_s, subname, relid_s = parts
            workers[int(pid_s)] = {"subname": subname, "relid": int(relid_s)}
        return workers
    except Exception as e:
        print(f"[warn] psql query failed: {e}", file=sys.stderr)
        return {}


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def _update_launch_json(new_pids: set[int],
                        gone_pids: set[int],
                        workers: dict[int, dict]) -> None:
    try:
        data = _load()
    except Exception as e:
        print(f"[error] failed to read launch.json: {e}", file=sys.stderr)
        return

    configs: list[dict] = data.get("configurations", [])

    # Remove entries for workers that have exited
    configs = [c for c in configs
               if not (_is_auto(c) and c.get("processId") in gone_pids)]

    # Append entries for new workers
    for pid in sorted(new_pids):
        w = workers[pid]
        cfg = _make_config(pid, w["subname"], w["relid"])
        configs.append(cfg)
        print(f"[{_now()}] + NEW  pid={pid:6d}  subname={w['subname']}  relid={w['relid']}")
        print(f"           added  \"{cfg['name']}\"")

    for pid in sorted(gone_pids):
        print(f"[{_now()}] - GONE pid={pid:6d}  (entry removed from launch.json)")

    data["configurations"] = configs

    try:
        _save(data)
    except Exception as e:
        print(f"[error] failed to write launch.json: {e}", file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Auto-update .vscode/launch.json for tablesync workers"
    )
    ap.add_argument("--interval", type=float, default=1.0,
                    metavar="SEC", help="poll interval (default: 1)")
    ap.add_argument("--host",     metavar="HOST")
    ap.add_argument("--port",     metavar="PORT")
    ap.add_argument("--dbname",   metavar="DB")
    ap.add_argument("--username", metavar="USER")
    args = ap.parse_args()

    psql_args: list[str] = []
    if args.host:     psql_args += ["-h", args.host]
    if args.port:     psql_args += ["-p", str(args.port)]
    if args.dbname:   psql_args += ["-d", args.dbname]
    if args.username: psql_args += ["-U", args.username]

    print(f"Watching pg_stat_subscription every {args.interval}s ...")
    print(f"launch.json: {LAUNCH_JSON}")
    print("Press Ctrl+C to stop.\n")

    known: set[int] = set()

    while True:
        current = _query_workers(psql_args)
        current_pids = set(current.keys())

        new_pids = current_pids - known
        gone_pids = known - current_pids

        if new_pids or gone_pids:
            _update_launch_json(new_pids, gone_pids, current)

        known = current_pids
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped.")
