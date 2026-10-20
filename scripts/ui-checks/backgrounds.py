"""Lists the shader background clips of a saved project, for scripts/ui-checks (read-only).

    python3 -I backgrounds.py <project.tscproj>

One line per clip whose source is a .tscshadervid:
    clip=<id> src=<file name> group=<enclosing group id|-> svs=<metadata.ShaderVidSource|->
    rev=<enclosing group's metadata.RevBackground|-> speed=<sourceEffect Speed defaultValue|->
"""
import json
import os
import sys


def main(path):
    with open(path, encoding="utf-8") as f:
        project = json.load(f)
    sources = {s.get("id"): os.path.basename(s.get("src", "")) for s in project.get("sourceBin", [])}

    def walk(medias, group):
        for m in medias:
            if m.get("_type") == "Group":
                for t in m.get("tracks", []):
                    walk(t.get("medias", []), m)
                continue
            name = sources.get(m.get("src"), "")
            if not name.lower().endswith(".tscshadervid"):
                continue
            md = m.get("metadata", {})
            speed = m.get("sourceEffect", {}).get("parameters", {}).get("Speed")
            if isinstance(speed, dict):
                speed = speed.get("defaultValue")
            gmd = group.get("metadata", {}) if group else {}
            print("clip=%s src=%s group=%s svs=%s rev=%s speed=%s" % (
                m.get("id"), name, group.get("id") if group else "-", md.get("ShaderVidSource", "-"),
                gmd.get("RevBackground", "-"), "-" if speed is None else speed))

    for scene in project.get("timeline", {}).get("sceneTrack", {}).get("scenes", []):
        for t in scene.get("csml", {}).get("tracks", []):
            walk(t.get("medias", []), None)


if __name__ == "__main__":
    main(sys.argv[1])
