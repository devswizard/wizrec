#!/usr/bin/env python3
"""Annotations for a stuck `swift test` log: tests that started but never finished (in start
order, so the earliest stuck ones come first) and the log tail. Usage: annotate-tests.py test.log"""
import re
import sys

STARTED = re.compile(r"Test (?:Case '-\[(.+?)\]'|(\S+\)?)) started")
FINISHED = re.compile(r"Test (?:Case '-\[(.+?)\]'|(\S+\)?)) (?:passed|failed|skipped)")


def esc(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


lines = open(sys.argv[1], errors="replace").read().splitlines()
started: dict[str, int] = {}
finished: set[str] = set()
for n, line in enumerate(lines):
    if m := STARTED.search(line):
        started.setdefault(m.group(1) or m.group(2), n)
    elif m := FINISHED.search(line):
        finished.add(m.group(1) or m.group(2))
pending = [t for t, _ in sorted(started.items(), key=lambda kv: kv[1]) if t not in finished]
print("::error title=Unfinished tests (%d of %d started), earliest first::%s"
      % (len(pending), len(started), esc("\n".join(pending[:80]))))
print("::warning title=Test log tail::%s" % esc("\n".join(lines[-30:])))
