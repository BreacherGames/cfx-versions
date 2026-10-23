# CFX Versions

Machine-readable catalog of **FXServer** download URLs for **Legacy** and **Enhanced** (Windows + Linux).

No binaries — pins and HTTPS links only. Updated daily from [Cfx docs](https://docs.fivem.net/docs/server-download/).

## Quick start

```bash
BASE=https://raw.githubusercontent.com/BreacherGames/cfx-versions/main

# Resolve a pin → URL
chan=$(curl -fsSL "$BASE/versions/index.json" | jq -r '.channels["legacy/win32"].path')
curl -fsSL "$BASE/$chan" | jq -r '.builds[.latest].url'
```

| Channel | Product | Platform |
| --- | --- | --- |
| `legacy/win32` | Legacy | Windows |
| `legacy/linux` | Legacy | Linux |
| `enhanced/win32` | Enhanced | Windows |
| `enhanced/linux` | Enhanced | Linux |

| Pin | Meaning |
| --- | --- |
| `latest` | Current recommended build from Cfx |
| `stable` | Optional known-good pin (`null` until set) |

Each channel file contains **only** pinned builds (no history).

## Schema

`schemaVersion: 1` — field names and paths are stable. A bump means a breaking change.

```text
versions/index.json              → channel pins + paths
versions/{legacy,enhanced}/*.json → builds[id].{url,seenAt}
versions/policy.json             → retention floors (maintainers)
```

Legacy URLs are always `…/master/…`. Windows Legacy links use `server.zip` (docs may show `.7z`; same folder).

## Maintainers

```bash
./.github/scripts/validate.sh
./.github/scripts/sync.sh
./.github/scripts/discover.sh legacy win32
./.github/scripts/set-stable.sh legacy win32 <version>
```

| Workflow | Trigger |
| --- | --- |
| `sync-versions` | Daily + manual |
| `set-stable` | Manual |
| `validate` | PR / push |

## License

Public domain — [Unlicense](LICENSE).
