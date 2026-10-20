#!/usr/bin/env python3
"""Turns a macOS `sample` report into GitHub annotations: for every thread, the deepest frames
(most samples first), keeping the main thread and threads that run WizRec code or wait.
Usage: annotate-sample.py sample.txt"""
import re
import sys

OURS = re.compile(r"TSCProjKit|MediaEngine|RenderEngine|TimelineEngine|TimelineUI|PlayerKit|AudioEngine|"
                  r"Exporter|Captions|CaptionLayout|Recorder|WizRec|TestGenKit|Tests\b|Tests\.")
WAITS = re.compile(r"semaphore_wait|__psynch_cvwait|__ulock_wait|mach_msg|_dispatch_sync|"
                   r"_dispatch_group_wait|swift_task_|waitUntilCompleted|CFRunLoopRun")
THREAD = re.compile(r"^\s*\d+\s+Thread_\d+(.*)$")
FRAME = re.compile(r"^([\s+!:|]*)(\d+)\s+(.+?)\s+\(in ([^)]+)\)")


def esc(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


text = open(sys.argv[1], errors="replace").read()
graph = text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
threads: list[tuple[str, list[str]]] = []
for line in graph.splitlines():
    if m := THREAD.match(line):
        threads.append((m.group(1).strip() or "thread", []))
    elif threads and (m := FRAME.match(line)):
        depth = len(m.group(1))
        threads[-1][1].append("%s%s  [%s]" % (" " * (depth // 2), m.group(3)[:140], m.group(4)))

reported = 0
for name, frames in threads:
    joined = "\n".join(frames)
    if not frames or not ("main-thread" in name or OURS.search(joined)):
        continue
    if "main-thread" not in name and not WAITS.search(joined):
        continue
    keep = [f for f in frames if OURS.search(f) or WAITS.search(f)]
    tail = frames[-6:]
    body = "\n".join(keep[:30] + ["…"] + tail)
    # GitHub keeps 10 errors and 10 warnings per step: the main thread is the error.
    main = "main-thread" in name
    if not main and reported >= 6:
        continue
    print("::%s title=Stuck thread: %s::%s" % ("error" if main else "warning", esc(name[:80]), esc(body)))
    reported += 0 if main else 1
if reported == 0:
    print("::warning title=sample::no main/WizRec thread found in %s" % sys.argv[1])
