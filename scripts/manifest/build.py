#!/usr/bin/env python3
"""Dev helper that assembles coworld_manifest_template.json from the prose
files in this directory, so the long docs pages stay editable as markdown."""
import json, pathlib, sys
HERE = pathlib.Path(__file__).parent
ROOT = HERE.parent.parent
def text(name): return (HERE / name).read_text(encoding="utf-8").rstrip("\n")
manifest = json.loads(text("skeleton.json"))
g = manifest["game"]
g["description"] = text("description.txt")
g["protocols"]["player"]["value"] = text("protocol_player.txt")
g["protocols"]["global"]["value"] = text("protocol_global.txt")
g["docs"]["readme"]["value"] = text("readme.txt")
for page in g["docs"]["pages"]:
    page["content"]["value"] = text(page["id"].replace(".md", "") + ".md")
(ROOT / "coworld_manifest_template.json").write_text(
    json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print("wrote coworld_manifest_template.json")
