#!/usr/bin/env python3
import argparse
import json
import os
import sys
from datetime import datetime


def parse_args():
    parser = argparse.ArgumentParser(
        description="Render a readable per-session SpeakFlow observability timeline."
    )
    parser.add_argument(
        "--file",
        default=os.path.expanduser("~/.speakflow/observability/app/events.jsonl"),
        help="Path to observability events.jsonl",
    )
    parser.add_argument("--session", help="Session UUID to render")
    parser.add_argument(
        "--latest",
        action="store_true",
        help="Render the latest session found in the log (default if --session omitted)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Optional max number of events to print from the end of the session",
    )
    return parser.parse_args()


def load_events(path):
    events = []
    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            events.append(json.loads(line))
    return events


def choose_session(events, requested):
    if requested:
        return requested
    for event in reversed(events):
        session_id = event.get("sessionId")
        if session_id:
            return session_id
    return None


def format_timestamp(value):
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        parsed = datetime.fromisoformat(value)
        return parsed.isoformat(timespec="milliseconds")
    except Exception:
        return value


def summarize_metadata(event):
    metadata = event.get("metadata") or {}
    preferred_keys = [
        "reason",
        "messageType",
        "providerMessageSequence",
        "isFinal",
        "speechFinal",
        "replacingChars",
        "typedText",
        "text",
        "transcript",
        "fullText",
        "payloadPreview",
        "error",
        "requestId",
        "latencyMs",
        "elapsedSeconds",
        "trailingTimeout",
        "pending",
        "providerId",
        "providerMode",
        "state",
    ]
    pairs = []
    seen = set()
    for key in preferred_keys:
        if key in metadata:
            pairs.append(f"{key}={metadata[key]}")
            seen.add(key)
    for key in sorted(metadata):
        if key in seen:
            continue
        value = metadata[key]
        if key.endswith("Fingerprint"):
            pairs.append(f"{key}={value[:12]}")
        else:
            pairs.append(f"{key}={value}")
    return " ".join(pairs)


def main():
    args = parse_args()
    if not os.path.exists(args.file):
        print(f"events file not found: {args.file}", file=sys.stderr)
        return 1

    events = load_events(args.file)
    if not events:
        print("no observability events found", file=sys.stderr)
        return 1

    session_id = choose_session(events, args.session)
    if not session_id:
        print("no session-scoped events found", file=sys.stderr)
        return 1

    session_events = [event for event in events if event.get("sessionId") == session_id]
    if args.limit > 0:
        session_events = session_events[-args.limit:]

    first = session_events[0]
    last = session_events[-1]
    print(f"session={session_id}")
    print(
        f"events={len(session_events)} "
        f"start={format_timestamp(first.get('timestamp', ''))} "
        f"end={format_timestamp(last.get('timestamp', ''))}"
    )
    print("")

    for event in session_events:
        global_seq = event.get("sequence", 0)
        session_seq = event.get("sessionSequence")
        timestamp = format_timestamp(event.get("timestamp", ""))
        component = event.get("component", "?")
        name = event.get("name", "?")
        level = event.get("level", "?")
        metadata = summarize_metadata(event)
        prefix = f"[g{global_seq:05d}"
        if session_seq is not None:
            prefix += f"/s{int(session_seq):04d}"
        prefix += "]"
        line = f"{prefix} {timestamp} {level:<7} {component}.{name}"
        if metadata:
            line += f"  {metadata}"
        print(line)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
