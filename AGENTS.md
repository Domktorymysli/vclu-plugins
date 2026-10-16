# vclu-plugins

Plugins for vCLU, one directory per plugin under `plugins/`. Read `README.md`
before writing one, especially:

- **Factory Plugins**: a device plugin is `create(opts)`, not `config`; the
  pitfalls list (no `setmetatable`, methods and state in one table, flat ids,
  KV per plugin) cost real debugging time on the runtime.
- **Making an instance exposable**: `onChange(cb)` returns an unsubscribe
  function; skip `expose` for devices HA supports natively.
- **HTTP Requests**: `resp.err` is set for a status outside 2xx too.
- **Testing**: `lua plugins/<name>/test.lua` on `test/harness.lua`.

A new plugin needs its own entry in `plugins.json` (id, name, version, path,
tags). After a merge, `.github/workflows/tag-plugins.yml` tags every version
bump and syncs `version` and `tag` into the existing entries, so leave those
two fields to it.
