#!/usr/bin/env python3
"""permissions.internet.hosts of an official plugin: every internet host written in the plugin's
Lua on the list (check-manifest.py checks the entries)."""
import ipaddress
import json
import pathlib
import re
import sys

LABEL = re.compile(r"^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?$")


def valid_name(name):
    return 0 < len(name) <= 253 and all(len(l) <= 63 and LABEL.match(l) for l in name.split("."))


def check_entry(e):
    """None when vclu accepts the entry (pkg/plugins/internet.go), else why not."""
    if e == "*":
        return None
    if not isinstance(e, str) or not e.strip():
        return "empty"
    if "://" in e or any(c in e for c in "/?#@ "):
        return "a host only: no scheme, path, user or spaces"
    try:
        ip = ipaddress.ip_address(e)
        return None if "%" not in e else "no zone"
    except ValueError:
        pass
    if ":" in e:
        return "no port"
    name = e.lower().removesuffix(".")
    if name.startswith("*."):
        name = name[2:]
        if "." not in name:
            return "*. covers a domain's subdomains, not a top-level domain"
    if not valid_name(name):
        return "letters, digits, - and . only, * only as a leading *., a non-ASCII name in its xn-- form"
    return None


def allows(hosts, host):
    host = host.lower().removesuffix(".")
    return "*" in hosts or any(h == host or h.startswith("*.") and host.endswith(h[1:]) for h in hosts)


def is_ip(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def main(plugin_dir):
    d = pathlib.Path(plugin_dir)
    m = json.loads((d / "plugin.json").read_text())
    perms = m.get("permissions") or {}
    errors = []
    internet = perms.get("internet")
    hosts = internet.get("hosts", []) if isinstance(internet, dict) else []
    # a URL written in the code: its host must be on the list (local addresses need lan instead)
    for lua in sorted(d.glob("*.lua")):
        if lua.name == "test.lua":
            continue
        for n, line in enumerate(lua.read_text().splitlines(), 1):
            if line.lstrip().startswith("--"):
                continue
            for host in re.findall(r"https?://([A-Za-z0-9._-]+)", line):
                if is_ip(host) or host in ("localhost",) or "." not in host:
                    continue
                if not allows(hosts, host):
                    errors.append(f'{lua.name}:{n}: {host} is not in "internet" of plugin.json')
    for e in errors:
        print(f"ERROR: {d}: {e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(max(main(p) for p in sys.argv[1:]))
