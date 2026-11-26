#!/usr/bin/env python3
"""Writes into plugins.json the sha256 of each file a tagged plugin version downloads,
read from the tag, so vclu installs only the files of that tag.

The files are those vclu downloads: plugin.json, its "files" (else init.lua) and its "form".
A listing without a tag, or whose files cannot be read at it, keeps what it had; it is
reported and the script exits 1 (vclu installs no official plugin without digests).
"""
import hashlib
import json
import subprocess
import sys


def show(tag, path):
    return subprocess.run(["git", "show", f"{tag}:{path}"], capture_output=True, check=True).stdout


def tagged(tag):
    return subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"],
                          capture_output=True).returncode == 0


def sums(tag, base):
    at = lambda name: f"{base}/{name}" if base else name
    manifest = show(tag, at("plugin.json"))
    m = json.loads(manifest)
    files = list(m.get("files") or ["init.lua"])
    if m.get("form") and m["form"] not in files:
        files.append(m["form"])
    out = {"plugin.json": hashlib.sha256(manifest).hexdigest()}
    for name in files:
        out[name] = hashlib.sha256(show(tag, at(name))).hexdigest()
    return out


def main(path="plugins.json"):
    with open(path, encoding="utf-8") as f:
        index = json.load(f)
    problems = []
    for p in index["plugins"]:
        tag = p.get("tag")
        if not tag or not tagged(tag):
            problems.append(f"{p['id']}: no tag {tag or ''}".rstrip())
            continue
        try:
            p["sha256"] = sums(tag, p.get("path", "").strip("/"))
        except (subprocess.CalledProcessError, ValueError) as e:
            problems.append(f"{p['id']}: {tag}: {e}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(index, indent=2, ensure_ascii=False) + "\n")
    for line in problems:
        print("::error::no sha256 for " + line)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
