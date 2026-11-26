#!/usr/bin/env python3
"""Check plugin.json "websocket" the way vclu reads it (pkg/plugins/websocket.go).

{"websocket": {"lanPorts": [80, 8123]}}: the local ports the plugin's WebSockets reach, whole
ports 1-65535, at most 8, each once, none of another permission (1234, 69, 502, 1883, 8883),
only with "lan" (API 1 asks for it). Otherwise vclu refuses the whole manifest and the plugin
does not load.
Usage: check-websocket.py plugins/<name>/plugin.json
"""
import json
import sys

OTHER = {1234: "grenton_raw", 69: "tftp", 502: "modbus", 1883: "mqtt", 8883: "mqtt"}


def main(path):
    m = json.load(open(path))
    if "websocket" not in m:
        return 0
    api2 = m.get("api") == 2
    lan = not api2 or (m.get("permissions") or {}).get("lan") is True
    w = m["websocket"]
    errors = []
    if not lan:
        errors.append('"websocket" needs "lan": true in permissions')
    if not isinstance(w, dict) or set(w) - {"lanPorts"}:
        errors.append('"websocket" is {"lanPorts": [...]}')
        w = {}
    ports = w.get("lanPorts", [])
    if not isinstance(ports, list):
        errors.append("websocket.lanPorts is a list")
        ports = []
    if len(ports) > 8:
        errors.append("websocket.lanPorts: at most 8 ports")
    seen = set()
    for p in ports:
        if type(p) is not int or not 1 <= p <= 65535:
            errors.append("websocket.lanPorts: %r is not a port 1-65535" % (p,))
        elif p in OTHER:
            errors.append("websocket.lanPorts: port %d belongs to the %s permission" % (p, OTHER[p]))
        elif p in seen:
            errors.append("websocket.lanPorts: %d twice" % p)
        seen.add(p)
    for e in errors:
        print("ERROR: %s: %s" % (path, e))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
