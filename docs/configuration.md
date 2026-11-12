# Configuration reference

`MEDUSA_CONFIG` is a global Lua table that a mission sets in a **DO SCRIPT** action before `medusa-bke.lua` loads.
Every field is optional. Medusa reads it once, at start. This page lists every field BKE reads; the stock fields work
exactly as on the official [Configuration](https://medusa.airdefense.systems/reference/configuration/) page.

```lua
MEDUSA_CONFIG = {
	LogLevel = "INFO",
	TrackMemorySec = 30,
	Roles = { HQ = "hq", GCI = "gci", EWR = "ewr", AWACS = "awacs", OBSERVER = "obs", ESM = "esm" },
	Networks = {
		{ name = "NORTH", coalition = "red", prefix = "iads", doctrine = { ROE = "FREE" } },
	},
}
```

## Fields

| Field | Type | Default | Range / values | Effect |
|---|---|---|---|---|
| `LogLevel` | string | `"INFO"` | `NONE`, `ERROR`, `INFO`, `DEBUG`, `TRACE` | How much Medusa writes to dcs.log. **[BKE]** The [debrief log](debrief-log.md) and BKE's mission-maker lines are written at `INFO`; `ERROR` or `NONE` turns them off |
| `Roles` | table | see [Roles](#roles) | | Name tokens for group roles |
| `Networks` | array | one red network `DEFAULT`, prefix `iads` | see [Networks](#networks) | One IADS per entry |
| `TrackMemorySec` | number | 30 | 0-86400 | Seconds without a radar look before a track is dropped. **[BKE]** Also caps each per-radar refresh rate at half of it (see [`ScanUpdateRateSec`](doctrine-fields.md#sensors-and-track-refresh)), and is when a silent track counts as lost for [track re-acquisition](track-reacquisition.md) |
| `VelocityWindowSec` | number | 60 | 1-600 | Window of the smoothed velocity estimate |
| `ChunkBudgetTracks` | number | 20 | 1-200 | Tracks classified per chunk (spreads the work over frames) |
| `ChunkBudgetHarm` | number | 15 | 1-200 | Tracks checked for HARMs per chunk |
| `ChunkBudgetBatteries` | number | 20 | 1-200 | Batteries checked per chunk for hand-off and deactivation |
| `HarmCapableSystems` | array of strings | none | DCS unit type names or parts of them | Added to the built-in list of systems that can shoot down HARMs (`S-300`, `Tor`, `Pantsir`, `Patriot`, `NASAMS`). **[BKE]** HOT radars of these systems also refresh tracks at the `SAM_TRACK` rate |
| `WeaponRangeOverrides` | table | none | `{ ["<part of a missile type name>"] = metres }` | Replaces the maximum range DCS reports for a SAM's missile; the key is matched as plain text anywhere in the missile's type name, the value is a range in metres |
| `AllowDynamicProbing` | boolean | `false` | | Probe unit types first seen after start by spawning and removing a temporary unit. Can stall or desynchronise multiplayer; leave off unless you need it |
| `PrometheusEnabled` | boolean | `false` | | Write metrics for Prometheus ([official page](https://medusa.airdefense.systems/monitoring/prometheus-and-grafana/)) |
| `PrometheusExtendEnabled` | boolean | `false` | | Extra per-battery and per-track metrics; needed for the tactical display |

Numbers outside their range are clamped to it. An unknown `LogLevel` is an error in the log and `INFO` is used.

## Roles

| Key | Default | Marks |
|---|---|---|
| `HQ` | `"hq"` | command posts |
| `GCI` | `"gci"` | GCI radars |
| `EWR` | `"ewr"` | early-warning radars (the aliases `radar` and `sensor` always work too) |
| `AWACS` | `"awacs"` | airborne early warning |
| `OBSERVER` | `"obs"` | **[BKE]** [observer posts](local-radars-and-observers.md#observer-reports) (the alias `observer` always works too) |
| `ESM` | `"esm"` | **[BKE]** [listening stations](esm-listening-stations.md) (the alias `elint` always works too) |

Tokens are matched case-insensitively at the start of a name segment ([Naming conventions](naming-conventions.md)).
`HQ`, `GCI` and `EWR` must be strings, or role detection is turned off with an error in the log.

## Networks

| Key | Type | Required | Effect |
|---|---|---|---|
| `name` | string | yes | The network's name: in the log, in `Medusa.API` calls and on [debrief](debrief-log.md) lines (`net=`) |
| `coalition` | string or number | yes | `"red"`, `"blue"`, `"neutral"`, or 1, 2, 0 |
| `prefix` | string | yes | Group-name prefix the network manages |
| `doctrine` | table or string | no | The network's doctrine, inline or the name of a global table. Merged over `Medusa_MM_Doctrine` ([Doctrine fields](doctrine-fields.md#how-doctrine-is-resolved)) |
| `borderZones` | array of strings | no | Names of trigger zones or drawings that form the network's border ([official guide](https://medusa.airdefense.systems/guides/border-zones/)) |

An entry without `name`, `coalition` or `prefix` is skipped.

## [BKE] Settings that are not in `MEDUSA_CONFIG`

- **Trigger-zone properties** for [alert zones](alert-zones.md) (`MedusaFlag`, `MedusaLosses`, `MedusaThreats`,
  `MedusaAlt`, `MedusaLinger`, `MedusaSide`) are set on each zone in the Mission Editor.
- **Group names** with the `obs` / `observer` and `esm` / `elint` tokens make observer posts and listening stations.
- **Unit skill** in the Mission Editor sets each crew's reporting skill ([Crews](crews-and-readiness.md)).
