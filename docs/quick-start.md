# Quick start

From an empty mission to a working Black Knight Edition IADS in a few minutes. The steps are those of stock Medusa
(official [Quick Start](https://medusa.airdefense.systems/getting-started/quick-start/)); the BKE parts are marked.

## Minimal set-up

1. Place your air defence groups in the Mission Editor and give each group a name that starts with `iads` (the default
   prefix), for example `iads.north.sa10` or `iads SA-6 Hama`. No role token is needed for SAM, AAA or MANPAD groups:
   Medusa works out what each group is from its units. Early-warning radars are found the same way (or name them with
   `ewr`). See [Naming conventions](naming-conventions.md).
2. Add a **MISSION START** trigger with a **DO SCRIPT FILE** action that loads `medusa-bke.lua`
   ([Installation](installation.md)).
3. Fly. With no configuration, BKE runs one red network (`DEFAULT`) on the `iads` prefix with the default doctrine.

That is all a mission needs. Everything below is optional.

## [BKE] Ground sensors in two names

BKE adds two kinds of ground group you can place, each marked by a token in its name:

| Name | What it is |
|---|---|
| `iads.north.obs.hill-412` | An **observer post** (`obs` or `observer`): a few soldiers or a lookout vehicle that watch for aircraft and radio coarse reports ([page](local-radars-and-observers.md#observer-reports)) |
| `iads.north.esm.ridge-1` | A **listening station** (`esm` or `elint`): a vehicle or two that take bearings on hostile aircraft radars ([page](esm-listening-stations.md)) |

Give observer posts a skill above Average in the editor: an Average crew gets a report out about one time in four
([Crews, readiness and training mode](crews-and-readiness.md)).

A Dog Ear (or any short-range search radar) placed without missiles is now a **local cueing radar**, dark until it is
needed ([page](local-radars-and-observers.md#local-cueing-radars)). If you want it as an always-on early-warning radar
instead, put `ewr` in its group name.

## Blue coalition, own prefix

Put a configuration in a **DO SCRIPT** action that runs before `medusa-bke.lua`:

```lua
MEDUSA_CONFIG = {
	Networks = {
		{ name = "BLUE_IADS", coalition = "blue", prefix = "blue" },
	},
}
```

Groups named `blue...` on the blue side now form the network `BLUE_IADS`. Each entry in `Networks` is its own IADS;
see the official [Multi-Network Setup](https://medusa.airdefense.systems/guides/multi-network/).

## Adding doctrine

Doctrine sets how a network fights. Give a network a `doctrine` table, or set `Medusa_MM_Doctrine` for every network:

```lua
MEDUSA_CONFIG = {
	Networks = {
		{
			name = "NORTH",
			coalition = "red",
			prefix = "iads",
			doctrine = {
				ROE = "FREE",
				Posture = "WARM_WAR",
				-- [BKE] crews start the mission surprised; they wake up as the raid develops
				Readiness = "SURPRISED",
			},
		},
	},
}
```

Every field is in [Doctrine fields](doctrine-fields.md). The BKE features are all on by default except training mode;
[examples/bke-doctrine-config.lua](../examples/bke-doctrine-config.lua) lists them with their defaults.

## Quick checks

After the first run, look in `dcs.log`:

| Look for | It means |
|---|---|
| `Medusa IADS - Black Knight Edition (BKE) v0.0.1 (based on Medusa v1.6.0)` | BKE loaded |
| `ERROR` lines from `Doctrine` or `Config` | A value in your configuration was rejected; the line says what was used instead |
| `crew roster of network ...` | **[BKE]** Your observer posts and crews, with their skill and how many fell back to the default skill |
| `local radar <group>: reach ...` | **[BKE]** A radar became a local cueing radar. If it was meant to be your early-warning radar, add `ewr` to its name |
| `listening stations: <n> (...)` | **[BKE]** Your listening stations were found |
| `DEBRIEF\|...` | **[BKE]** The after-action log of what the network saw and did ([Debrief log](debrief-log.md)) |

## Next steps

- [Differences from Medusa 1.6.0](differences-from-medusa-1.6.0.md) if you are moving an existing Medusa mission.
- [Alert zones](alert-zones.md) to trigger alert fighters or messages from what the radars see.
- [FAQ](faq.md).
