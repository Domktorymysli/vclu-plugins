#!/usr/bin/env python3
"""Check plugin.json "tcp" the way vclu reads it (pkg/plugins/tcp.go).

{"tcp": {"ports": [23]}}: whole ports 1-65535, at most 8, each once, none of another
permission (1234, 69, 502, 1883, 8883), only with "tcp": true in permissions, and that
permission needs at least one port. Otherwise vclu refuses the whole manifest and the plugin
does not load.
Usage: check-tcp.py plugins/<name>/plugin.json
"""
import json
import sys

OTHER = {1234: "grenton_raw", 69: "tftp", 502: "modbus", 1883: "mqtt", 8883: "mqtt"}


def main(path):
    m = json.load(open(path))
    asks = (m.get("permissions") or {}).get("tcp") is True
    if "tcp" not in m:
        if asks:
            print('ERROR: %s: the tcp permission needs the ports it connects to: "tcp": {"ports": [23]}' % path)
            return 1
        return 0
    t = m["tcp"]
    errors = []
    if not asks:
        errors.append('"tcp" needs "tcp": true in permissions')
    if not isinstance(t, dict) or set(t) - {"ports"}:
        errors.append('"tcp" is {"ports": [...]}')
        t = {}
    ports = t.get("ports", [])
    if not isinstance(ports, list):
        errors.append("tcp.ports is a list")
        ports = []
    if asks and not ports:
        errors.append('the tcp permission needs the ports it connects to: "tcp": {"ports": [23]}')
    if len(ports) > 8:
        errors.append("tcp.ports: at most 8 ports")
    seen = set()
    for p in ports:
        if type(p) is not int or not 1 <= p <= 65535:
            errors.append("tcp.ports: %r is not a port 1-65535" % (p,))
        elif p in OTHER:
            errors.append("tcp.ports: port %d belongs to the %s permission" % (p, OTHER[p]))
        elif p in seen:
            errors.append("tcp.ports: %d twice" % p)
        seen.add(p)
    for e in errors:
        print("ERROR: %s: %s" % (path, e))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
