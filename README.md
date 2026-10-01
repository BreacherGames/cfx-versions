# CFX Versions

Public catalog of CFX / FXServer runtime builds (**Legacy** + **Enhanced**).
Metadata and download URLs only — no binaries.

## Consume

Start at `versions/index.json`, follow `channels.*.path`, then resolve a pin:

```bash
chan=$(jq -r '.channels["legacy/win32"].path' versions/index.json)
jq -r '.builds[.latest].url' "$chan"
jq -r '.builds[.stable].url' "$chan"   # null if unset
```

| Pin | Meaning |
| --- | --- |
| `latest` | Newest build from sync |
| `stable` | Manually pinned known-good (`null` until set) |

## Layout

```text
versions/
  policy.json                 # retention floors (minBuild)
  index.json                  # derived channel pins
  legacy/{win32,linux}.json
  enhanced/{win32,linux}.json
```

## Contract (`schemaVersion: 1`)

- Paths and field names are stable; breaking changes bump `schemaVersion`.
- Legacy builds are master-only (`…/master/…`).
- Sync prunes builds below `policy.json` floors; `latest` / `stable` pins are kept.

```bash
./.github/scripts/validate.sh   # needs jq
```

## Automation

| Workflow | Trigger |
| --- | --- |
| `sync-versions` | Daily + manual |
| `set-stable` | Manual |
| `validate` | PR / push |

## License

Public domain — [Unlicense](LICENSE).
