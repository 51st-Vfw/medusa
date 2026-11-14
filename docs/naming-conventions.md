# Naming conventions

Medusa finds its groups by name. BKE keeps stock Medusa's naming as it is and adds two role tokens. The official
[Naming Conventions](https://medusa.airdefense.systems/guides/naming-conventions/) page explains the dot-echelon
format in full; this page summarizes it and covers the BKE additions.

## Format (stock)

A managed group's name starts with the network's prefix (`iads` by default), followed by any number of segments
separated by dots or spaces: echelons from highest to lowest, role tokens, and a label.

```
iads.1bde.2bn.sa10          prefix, echelons, label
iads SA-6 Hama              flat naming: prefix and label
iads.north.ewr.west         a role token (ewr) makes this group an early-warning radar
```

SAM, AAA and MANPAD groups need no role token: Medusa classifies each group from the DCS attributes of its units
(long, medium or short range SAM, AAA, MANPAD) and reads its ranges from DCS.

## Role tokens

A role token is matched at the start of a segment, case-insensitively, and must be followed by a non-alphanumeric
character or the end of the segment: `ewr`, `ewr-1` and `ewr north` match; `ewrything` and `newer` do not.

| Token | Role | Notes |
|---|---|---|
| `ewr` (also `radar`, `sensor`) | Early-warning radar | Always on, a sensor for the network. **[BKE]** Also keeps a short-range radar (a Dog Ear) an always-on early-warning radar instead of a [local cueing radar](local-radars-and-observers.md#local-cueing-radars) |
| `gci` | GCI radar | A sensor, like `ewr` |
| `awacs` | Airborne early warning | One aircraft with the DCS AWACS attribute per group; exempt from EMCON |
| `hq` | Command post | A C2 node |
| `obs`, `observer` | **[BKE]** Observer post | A ground group (soldiers, a lookout vehicle) whose crew watches for aircraft and radios reports; a trained observer ([page](local-radars-and-observers.md#observer-reports)) |
| `esm`, `elint` | **[BKE]** Former listening station | Listening stations were removed in BKE 0.1.0 (DCS gives mission scripts no radar state for player-flown aircraft). A group named this way is an untrained lookout post: its crew looks and reports like any ground crew, without an observer post's training. dcs.log gets an error line for it |

The tokens `hq`, `gci`, `ewr`, `awacs` and, **[BKE]**, `obs` can be changed or extended with
[`MEDUSA_CONFIG.Roles`](configuration.md#roles). The aliases `radar`, `sensor` and `observer` always work.

## [BKE] Groups whose role BKE decides differently

| Group | Medusa 1.6.0 | BKE (default) |
|---|---|---|
| A short-range search radar (reach under 50 km, for example a Dog Ear) alone, no role token | Always-on early-warning radar | Local cueing radar: dark until needed |
| The same radar with guns (Dog Ear + Shilka) | AAA battery if there are at least two guns per radar, otherwise the guns are unmanaged | AAA battery directed by its radar |
| The same radar with MANPADs (Dog Ear + Igla) | MANPAD group; the radar is never polled | MANPAD group cued by its radar |
| Any group with a segment starting `obs`, `observer`, `esm` or `elint` | No special meaning | Observer post (`esm`, `elint`: an untrained lookout post) |

To keep the stock behavior for one radar, put `ewr` in its name; for every radar of a network, set doctrine
`LocalCueingRadars = false`. If an existing mission uses `obs...` or `esm...` as a label segment of a managed group,
rename that segment.

## Changing tokens

```lua
MEDUSA_CONFIG = {
	Roles = { HQ = "command", OBSERVER = "lookout" },
}
```

`lookout` now marks observer posts as well as `obs` and `observer`.
