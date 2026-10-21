"""Lists the shader background clips of a saved project, for scripts/ui-checks (read-only).

    python3 -I backgrounds.py <project.tscproj>
    python3 -I backgrounds.py <project.tscproj> --group <id>   # "<RevBackground|-> <inner tracks>"

One line per clip whose source is a .tscshadervid:
    clip=<id> src=<file name> group=<enclosing group id|-> svs=<metadata.ShaderVidSource|->
    rev=<enclosing group's metadata.RevBackground|-> speed=<sourceEffect Speed defaultValue|->
    itrack=<inner track index>/<enclosing group's inner track count>|-
"""
import json
import os
import sys


def main(path):
    with open(path, encoding="utf-8") as f:
        project = json.load(f)
    sources = {s.get("id"): os.path.basename(s.get("src", "")) for s in project.get("sourceBin", [])}

    def walk(medias, group, itrack="-"):
        for m in medias:
            if m.get("_type") == "Group":
                tracks = m.get("tracks", [])
                for i, t in enumerate(tracks):
                    walk(t.get("medias", []), m, "%d/%d" % (i, len(tracks)))
                continue
            name = sources.get(m.get("src"), "")
            if not name.lower().endswith(".tscshadervid"):
                continue
            md = m.get("metadata", {})
            speed = m.get("sourceEffect", {}).get("parameters", {}).get("Speed")
            if isinstance(speed, dict):
                speed = speed.get("defaultValue")
            gmd = group.get("metadata", {}) if group else {}
            print("clip=%s src=%s group=%s svs=%s rev=%s speed=%s itrack=%s" % (
                m.get("id"), name, group.get("id") if group else "-", md.get("ShaderVidSource", "-"),
                gmd.get("RevBackground", "-"), "-" if speed is None else speed, itrack))

    for t in top_tracks(project):
        walk(t.get("medias", []), None)


def top_tracks(project):
    for scene in project.get("timeline", {}).get("sceneTrack", {}).get("scenes", []):
        yield from scene.get("csml", {}).get("tracks", [])


def group_info(path, gid):
    """Prints '<RevBackground|-> <inner track count>' of group `gid` ('- 0' when absent)."""
    with open(path, encoding="utf-8") as f:
        project = json.load(f)

    def find(medias):
        for m in medias:
            if m.get("_type") != "Group":
                continue
            if m.get("id") == gid:
                return m
            for t in m.get("tracks", []):
                found = find(t.get("medias", []))
                if found:
                    return found
        return None

    for t in top_tracks(project):
        g = find(t.get("medias", []))
        if g:
            print("%s %d" % (g.get("metadata", {}).get("RevBackground", "-"), len(g.get("tracks", []))))
            return
    print("- 0")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[2] == "--group":
        group_info(sys.argv[1], int(sys.argv[3]))
    else:
        main(sys.argv[1])
