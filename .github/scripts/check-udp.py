#!/usr/bin/env python3
"""Check plugin.json "udp" the way vclu reads it (pkg/plugins/udp.go).

{"udp": {"broadcastPorts": [7000]}}: whole ports 1-65535, at most 8, each once, never the
CLU ports 1234 and 69, and only with "udp": true in permissions. Otherwise vclu refuses the
whole manifest and the plugin does not load.
Usage: check-udp.py plugins/<name>/plugin.json
"""
import json
import sys

CLU_PORTS = {1234, 69}


def main(path):
    m = json.load(open(path))
    if "udp" not in m:
        return 0
    u = m["udp"]
    errors = []
    if (m.get("permissions") or {}).get("udp") is not True:
        errors.append('"udp" needs "udp": true in permissions')
    if not isinstance(u, dict) or set(u) - {"broadcastPorts"}:
        errors.append('"udp" is {"broadcastPorts": [...]}')
        u = {}
    ports = u.get("broadcastPorts", [])
    if not isinstance(ports, list):
        errors.append("udp.broadcastPorts is a list")
        ports = []
    if len(ports) > 8:
        errors.append("udp.broadcastPorts: at most 8 ports")
    seen = set()
    for p in ports:
        if type(p) is not int or not 1 <= p <= 65535:
            errors.append("udp.broadcastPorts: %r is not a port 1-65535" % (p,))
        elif p in CLU_PORTS:
            errors.append("udp.broadcastPorts: %d is a CLU port, reached only with grenton_raw or tftp" % p)
        elif p in seen:
            errors.append("udp.broadcastPorts: %d twice" % p)
        seen.add(p)
    for e in errors:
        print("ERROR: %s: %s" % (path, e))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
