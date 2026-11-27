#!/usr/bin/env python3
"""plugin.json of an official plugin as vclu reads it on plugin API 2 (pkg/plugins/manifest.go):
permissions as objects with their ports, topics and why, requires.vclu ">=X.Y.Z", actions, and
nothing vclu does not know (it would refuse the plugin as written for a newer vclu)."""
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from importlib import import_module

internet = import_module("check-internet")

KNOWN_TOP = {"id", "name", "version", "description", "author", "homepage", "license", "tags", "dependencies",
             "configSchema", "docs", "files", "api", "permissions", "requires", "form", "config", "dashboards",
             "actions", "exports", "factory", "profiles", "icon"}
MOVED = {"minVcluVersion"}  # API 1's key, "requires" on API 2
RESERVED_PORTS = {1234: "clu", 69: "tftp", 502: "modbus", 1883: "mqtt", 8883: "mqtt"}
UDP_RESERVED = {1234: "clu", 69: "tftp"}
ACTION = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
PARAM = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,63}$")


def text(v, limit):
    """None when v is a text or {pl, en} of one line up to limit characters."""
    if isinstance(v, str):
        vals = [v]
    elif isinstance(v, dict) and v and set(v) <= {"pl", "en"} and all(isinstance(x, str) for x in v.values()):
        vals = list(v.values())
    else:
        return 'a text or {"pl", "en"}'
    for s in vals:
        if not s or len(s) > limit or "\n" in s:
            return f"one line, 1 to {limit} characters"
    return None


def ports(where, v, reserved, errors, required=True):
    if not isinstance(v, list) or (required and not v):
        errors.append(f"{where}: a list of ports" + (", at least one" if required else ""))
        return []
    if len(v) > 8:
        errors.append(f"{where}: at most 8 ports")
    for i, p in enumerate(v):
        if type(p) is not int or not 1 <= p <= 65535:
            errors.append(f"{where}: {p!r} is not a port 1-65535")
        elif p in reserved:
            errors.append(f"{where}: port {p} belongs to the {reserved[p]} permission")
        elif p in v[:i]:
            errors.append(f"{where}: {p} twice")
    return v


def topic_filter(f):
    if not isinstance(f, str) or not f:
        return False
    levels = f.split("/")
    for i, l in enumerate(levels):
        if "#" in l and (l != "#" or i != len(levels) - 1):
            return False
        if "+" in l and l != "+":
            return False
    return True


def check_perm(name, v, errors):
    where = f"permissions.{name}"
    fields = {"internet": {"hosts", "why"}, "lan": {"ports", "why"}, "udp": {"ports", "broadcast", "why"},
              "tcp": {"ports", "why"}, "mqtt": {"subscribe", "publish", "why"}}.get(name, {"why"})
    if v is True and name in ("modbus", "lan", "mqtt"):
        v = {}
    if not isinstance(v, dict):
        errors.append(f"{where}: an object" + (" ({} or true)" if name == "modbus" else ""))
        return
    for k in v:
        if k not in fields:
            errors.append(f"{where}.{k}: unknown to vclu")
    why = v.get("why")
    if why is not None:
        bad = text(why, 200)
        if bad or any("<" in s or ">" in s for s in ([why] if isinstance(why, str) else why.values())):
            errors.append(f"{where}.why: {bad or 'without < or >'}")
    if name == "internet":
        hosts = v.get("hosts")
        if not isinstance(hosts, list) or not hosts or len(hosts) > 32:
            errors.append(f"{where}.hosts: 1 to 32 hosts")
            return
        for h in hosts:
            bad = internet.check_entry(h)
            if bad:
                errors.append(f"{where}.hosts: {h!r}: {bad}")
        if "*" in hosts and why is None:
            errors.append(f'{where}: any host ("*") needs "why"')
    elif name == "lan":
        if "ports" in v:
            ports(where + ".ports", v["ports"], RESERVED_PORTS, errors)
        elif why is None:
            errors.append(f'{where}: the ports it reaches, or "why" it needs any port')
    elif name == "udp":
        p = ports(where + ".ports", v.get("ports"), UDP_RESERVED, errors)
        b = ports(where + ".broadcast", v.get("broadcast", []), UDP_RESERVED, errors, required=False)
        for x in b:
            if x not in p:
                errors.append(f"{where}.broadcast: {x} is not among its ports")
    elif name == "tcp":
        ports(where + ".ports", v.get("ports"), RESERVED_PORTS, errors)
    elif name == "mqtt":
        if "subscribe" not in v and "publish" not in v:
            if why is None:
                errors.append(f'{where}: the topic filters it uses, or "why" it needs any topic')
        for k in ("subscribe", "publish"):
            if k in v:
                if not isinstance(v[k], list) or len(v[k]) > 32 or not all(topic_filter(f) for f in v[k]):
                    errors.append(f"{where}.{k}: up to 32 topic filters (+ a whole level, # only at the end)")
    elif name in ("clu", "tftp", "serial") and why is None:
        errors.append(f'{where}: {{"why": "..."}}: the user allows it in the panel and reads why')


def check_actions(actions, errors):
    if not isinstance(actions, list) or len(actions) > 32:
        errors.append("actions: a list of up to 32")
        return
    seen = set()
    for i, a in enumerate(actions):
        where = f"actions[{i}]"
        if not isinstance(a, dict):
            errors.append(f"{where}: an object")
            continue
        for k in a:
            if k not in ("name", "description", "params", "confirm"):
                errors.append(f"{where}.{k}: unknown to vclu")
        name = a.get("name")
        if not isinstance(name, str) or not ACTION.match(name):
            errors.append(f"{where}: name is a lower-case letter, then letters, digits and _")
        elif name in seen:
            errors.append(f"{where}: {name} twice")
        seen.add(name)
        bad = text(a.get("description"), 500)
        if bad:
            errors.append(f"{where}.description: {bad}")
        if "confirm" in a and type(a["confirm"]) is not bool:
            errors.append(f"{where}.confirm: true or false")
        params = a.get("params", {})
        if not isinstance(params, dict) or len(params) > 32:
            errors.append(f"{where}.params: an object of up to 32")
            continue
        for pn, p in params.items():
            pw = f"{where}.params.{pn}"
            if not PARAM.match(pn) or not isinstance(p, dict):
                errors.append(f"{pw}: a name is a letter, then letters, digits and _; the param an object")
                continue
            for k in p:
                if k not in ("type", "description", "required"):
                    errors.append(f"{pw}.{k}: unknown to vclu")
            if p.get("type") not in ("string", "number", "boolean"):
                errors.append(f'{pw}.type: "string", "number" or "boolean"')
            if "description" in p and text(p["description"], 500):
                errors.append(f"{pw}.description: {text(p['description'], 500)}")


def main(path):
    m = json.loads(pathlib.Path(path).read_text())
    errors = []
    if type(m.get("api")) is not int or m["api"] != 2:
        errors.append('"api": 2')
    for k in m:
        if k in MOVED:
            errors.append(f'"{k}" is "requires": {{"vclu": ">=X.Y.Z"}} on plugin API 2')
        elif k not in KNOWN_TOP and not k.startswith("x-"):
            errors.append(f'"{k}": not read by vclu (an author\'s own key starts with "x-")')
    if str(m.get("id", "")).startswith("@"):
        errors.append('"id" is the short id, without the namespace')
    perms = m.get("permissions")
    if not isinstance(perms, dict):
        errors.append('"permissions": an object, {} for none')
        perms = {}
    for name, v in perms.items():
        if name not in ("internet", "lan", "udp", "tcp", "mqtt", "modbus", "clu", "tftp", "serial"):
            errors.append(f"permissions.{name}: unknown to vclu")
        elif v not in (False, None):
            check_perm(name, v, errors)
    req = m.get("requires")
    if req is not None:
        if not isinstance(req, dict) or set(req) - {"vclu"} or not re.match(r"^>=\s*\d+\.\d+\.\d+$", str(req.get("vclu", ""))):
            errors.append('"requires": {"vclu": ">=X.Y.Z"}')
    for k in ("name", "description"):
        if k in m and text(m[k], 80 if k == "name" else 500):
            errors.append(f'"{k}": {text(m[k], 80 if k == "name" else 500)}')
    if "actions" in m:
        check_actions(m["actions"], errors)
    for e in errors:
        print(f"ERROR: {path}: {e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(max(main(p) for p in sys.argv[1:]))
