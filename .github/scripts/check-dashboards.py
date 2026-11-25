#!/usr/bin/env python3
"""Check plugin.json "dashboards" the way vclu reads it (pkg/plugins/dashboards.go).

A malformed list makes vclu refuse the whole manifest, so the plugin would not load.
Usage: check-dashboards.py plugins/<name>/plugin.json
"""
import json
import re
import sys
import unicodedata

ID = re.compile(r"^[a-z0-9_]{1,64}$")


def plain(s, n):
    return isinstance(s, str) and len(s) <= n and not any(unicodedata.category(c) == "Cc" for c in s)


def text_ok(v, n, required):
    if isinstance(v, str):
        return plain(v, n) and (v != "" or not required)
    if isinstance(v, dict):
        if set(v) - {"pl", "en"} or not all(plain(x, n) for x in v.values()):
            return False
        return not required or bool(v.get("pl") or v.get("en"))
    return False


def main(path):
    m = json.load(open(path))
    if "dashboards" not in m:
        return 0
    d = m["dashboards"]
    errors = []
    if not isinstance(d, list):
        errors.append("dashboards is a list")
        d = []
    if len(d) > 8:
        errors.append("at most 8 dashboards")
    seen = set()
    for i, e in enumerate(d):
        at = "dashboards[%d]" % i
        if not isinstance(e, dict):
            errors.append(at + ": an object {id, name, description}")
            continue
        if not isinstance(e.get("id"), str) or not ID.match(e["id"]):
            errors.append(at + ": id is 1 to 64 lower-case letters, digits and _")
        elif e["id"] in seen:
            errors.append(at + ": id %r twice" % e["id"])
        else:
            seen.add(e["id"])
        if not text_ok(e.get("name"), 60, True):
            errors.append(at + ': name is a text or {"pl", "en"}, up to 60 characters on one line')
        if "description" in e and not text_ok(e["description"], 300, False):
            errors.append(at + ': description is a text or {"pl", "en"}, up to 300 characters on one line')
    for err in errors:
        print("ERROR: %s: %s" % (path, err))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
