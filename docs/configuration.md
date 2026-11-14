# Configuration reference

`MEDUSA_CONFIG` is a global Lua table that a mission sets in a **DO SCRIPT** action before `medusa-bke.lua` loads.
Every field is optional. Medusa reads it once, at start. This page lists every field BKE reads; the stock fields work
exactly as on the official [Configuration](https://medusa.airdefense.systems/reference/configuration/) page.

```lua
MEDUSA_CONFIG = {
	LogLevel = "INFO",
	TrackMemorySec = 30,
	Roles = { HQ = "hq", GCI = "gci", EWR = "ewr", AWACS = "awacs", OBSERVER = "obs" },
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
| `TrackMemorySec` | number | 30 | 0-86400 | Seconds without a radar look before a track is dropped. **[BKE]** Also caps each per-radar refresh rate at half of it (see [`ScanUpdateRateSec`](doctrine-fields.md#sensors-and-track-refresh)), and is when a silent track is dropped and kept as lost for [track re-acquisition](track-reacquisition.md) (a held confirmed ARM missing two of its looks is already lost to new contacts) |
| `VelocityWindowSec` | number | 60 | 1-600 | Window of the smoothed velocity estimate |
| `ChunkBudgetTracks` | number | 20 | 1-200 | Tracks classified per chunk (spreads the work over frames) |
| `ChunkBudgetHarm` | number | 15 | 1-200 | Tracks checked for HARMs per chunk |
| `ChunkBudgetBatteries` | number | 20 | 1-200 | Batteries checked per chunk for hand-off and deactivation |
| `HarmCapableSystems` | array of strings | none | DCS unit type names or parts of them | Added to the built-in list of systems that can shoot down HARMs (`S-300`, `Tor`, `Pantsir`, `Patriot`, `NASAMS`). **[BKE]** HOT radars of these systems also refresh tracks at the `SAM_TRACK` rate |
| `WeaponRangeOverrides` | table | none | `{ ["<part of a missile type name>"] = meters }` | Replaces the maximum range DCS reports for a SAM's missile; the key is matched as plain text anywhere in the missile's type name, the value is a range in meters |
| `PointDefense` | table | none | `{ ["<PD group name>"] = "<protected group name>" }` | **[BKE]** Ties a point-defense group to the SAM it protects, over the automatic choice. See [Point defense](#bke-point-defense) |
| `AllowDynamicProbing` | boolean | `false` | | Probe unit types first seen after start by spawning and removing a temporary unit. Can stall or desynchronize multiplayer; leave off unless you need it |
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
| `ESM` | `"esm"` | **[BKE]** Former listening stations (the alias `elint` always works too): listening stations were removed in BKE 0.1.0, and a group with this token is an untrained lookout post ([naming](naming-conventions.md#bke-groups-whose-role-bke-decides-differently)) |

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

## [BKE] Point defense

Medusa gives each medium-, long- and very-long-range SAM battery a point-defense (PD) provider: a short-range SAM or
radar-directed AAA group within 15 km. When a HARM's path comes within 15 km of the protected battery, its providers
go HOT at it, and they engage HARMs and munitions falling on it. Automatically, each provider takes the **nearest**
battery that has no provider yet; an automatic assignment never gives a battery a second provider.

`PointDefense` lets the mission maker decide instead. Each entry ties one PD group to the battery it protects, by
their group names in the Mission Editor:

```lua
MEDUSA_CONFIG = {
	PointDefense = {
		["iads.qalamoun.SA-10 1 Pantsir"] = "iads.qalamoun.SA-10 1",
		["iads.qalamoun.SA-10 1 Tor"] = "iads.qalamoun.SA-10 1",
		["iads.homs.SA-5 Tor"] = "iads.homs.SA-5",
	},
}
```

- Several groups may protect one battery; each of them goes HOT for a HARM aimed at it. Tied providers count for the
  battery's HARM response (`SHUTDOWN_UNLESS_PD`, `AUTO_DEFENSE`) like an automatic one.
- A tie wins over an automatic assignment, including one the PD group already holds.
- While the protected battery is down (destroyed, out of ammunition), the PD group is assigned automatically
  meanwhile; while the PD group itself is down it protects nothing. The tie is applied again when the network next
  reassigns point defense (a battery rearmed, a crew recovered, a battery added). A protected battery that has lost
  its search radar but can still shoot keeps its tied provider.
- Batteries without a tie are assigned as before.
- A tie that cannot work is reported once in dcs.log as an error and ignored: a PD group that is not a short-range SAM
  or radar-directed AAA, a protected group that is not a medium-, long- or very-long-range SAM, or one more than 15 km
  away. An entry that is not a pair of group names is reported at start. A group name that matches no battery
  (misspelled, destroyed, or not spawned yet) is reported once at `INFO`.

Tor and Pantsir groups (and anything in `HarmCapableSystems`) also engage a HARM passing within their reach whether or
not they are assigned, when their kill chance is at least [`DefendPk`](doctrine-fields.md#harm-defense). Gun-only PD defends only
the battery it is assigned to.

## [BKE] Settings that are not in `MEDUSA_CONFIG`

- **Trigger-zone properties** for [alert zones](alert-zones.md) (`MedusaFlag`, `MedusaLosses`, `MedusaThreats`,
  `MedusaAlt`, `MedusaLinger`, `MedusaSide`) are set on each zone in the Mission Editor.
- **Group names** with the `obs` / `observer` tokens make observer posts.
- **Unit skill** in the Mission Editor sets each crew's reporting skill ([Crews](crews-and-readiness.md)).
