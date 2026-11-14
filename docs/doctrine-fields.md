# Doctrine fields

Doctrine is the set of rules a network fights by. This page lists every doctrine field BKE accepts: Medusa 1.6.0's
fields and the **[BKE]** additions, with type, default, range and effect. The official
[Doctrine Fields](https://medusa.airdefense.systems/reference/doctrine-fields/) page and
[Doctrine](https://medusa.airdefense.systems/guides/doctrine/) guide explain the stock fields at more length.

Every field is optional. A field left out takes its default.

## How doctrine is resolved

1. Built-in defaults (this page).
2. `Medusa_MM_Doctrine`, a global table, if the mission sets one: the base for every network.
3. The network's own `doctrine` (in `MEDUSA_CONFIG.Networks`), an inline table or the name of a global table, merged
   over the base. Sub-tables (`EMCON`, `MANPAD`, `AAA`, `CrewSuppression`, `ScanUpdateRateSec`,
   `MaxEngageRangePct`) merge key by key.

```lua
Medusa_MM_Doctrine = { ROE = "FREE", AAA = { BarrageChance = 0.5 } }
MEDUSA_CONFIG = {
	Networks = {
		{ name = "NORTH", coalition = "red", prefix = "north", doctrine = { Readiness = "SURPRISED" } },
		{ name = "SOUTH", coalition = "red", prefix = "south" },
	},
}
```

Both networks fight `ROE = "FREE"` with a 0.5 barrage chance; only `NORTH` starts surprised.

**Validation.** An enum field with an unknown value is an error in dcs.log and takes its default. **[BKE]** So is a
switch (a true/false field) set to anything other than `true` or `false`: `TrainingMode = "true"` logs an error and
stays `false`. (Medusa 1.6.0 read any value other than `nil` or `false` as on.) **[BKE]** A number field given
something that is not a number (`PkFloor = "high"`) is an error and takes its default; a number written as a string
(`HoldDownSec = "20"`) still works. A number outside its range is clamped to the range. A sub-table field that is not
a number takes its default.

**[BKE]** A top-level doctrine field Medusa does not know is an error in dcs.log that names it, for example `unknown
doctrine setting 'Readyness' ignored`; a key that differs from a field only in case adds the field it resembles (`'roe'`
... `did you mean 'ROE'?`). An unknown key inside `ScanUpdateRateSec` is reported the same way. The flat MANPAD fields
older missions use (`MANPADAlertnessDecaySec`, `MANPADFieldRadioRangeM`) are accepted and not reported. A field set in
`Medusa_MM_Doctrine` is checked for every network that uses it, so a misspelling there is reported once per network.

The settings Medusa uses are written to dcs.log at start (the doctrine summary of each network).

## Identification and rules of engagement

| Field | Type | Default | Range / values | Effect |
|---|---|---|---|---|
| `Name` | string | `"Passive Defense"` | | A label for the log |
| `Posture` | enum | `"HOT_WAR"` | `HOT_WAR`, `WARM_WAR`, `COLD_WAR` | How fast and on what evidence contacts are identified, and whether borders matter. **[BKE]** Also sets the starting `Readiness` when that is left out |
| `ROE` | enum | `"TIGHT"` | `FREE`, `TIGHT`, `HOLD` | Which tracks may be engaged: `FREE` bandits and hostiles, `TIGHT` hostiles only, `HOLD` none (the network still senses, tracks, runs EMCON and HARM defense). **[BKE]** Under `HOLD` no crew report or local initiative wakes a SAM |
| `ADIZEnabled` | boolean | `true` | | An identification zone outside the border zones (needs `borderZones` on the network) |
| `ADIZBufferNm` | number | 12 | 0-200 | How far the ADIZ reaches beyond the border, in nautical miles |
| `GuiltByAssociation` | boolean | `true` | | When a track is called bandit or hostile, aircraft flying with it get the same call |

## Sensors and track refresh

| Field | Type | Default | Range / values | Effect |
|---|---|---|---|---|
| `AutoDiscoverEwrs` | boolean | `true` | | Search-radar groups without a role token become sensors. **[BKE]** A short-reach radar in a group without missiles becomes a local cueing radar instead, unless `LocalCueingRadars = false` |
| `SAMAsEWR` | enum | `"WHEN_NO_EWR"` | `DISABLED`, `WHEN_NO_EWR`, `ALWAYS` | Whether long- and medium-range SAM search radars stay on as sensors: never, only once the network has no early-warning or GCI radar left, or always. **[BKE]** A local cueing radar (a lone, unnamed Dog Ear) is not an early-warning radar here, so a network whose only radar is one falls back to its SAMs; a Dog Ear named `ewr` is, and the SAMs stay SAMs |
| `BatteryTargetDatalink` | boolean | `true` | | WARM and HOT batteries feed what their radars see into the network's picture |
| `PerTrackScanUpdateRate` | number | 5 | 1-60 | Seconds between updates of one track. **[BKE]** Now the rate for AWACS, airborne datalink and ship radars only; ground radars use `ScanUpdateRateSec`. If a mission sets it explicitly, it also applies to every radar kind `ScanUpdateRateSec` does not name |
| `ScanUpdateRateSec` | table | `{ EWR = 10, SAM_SEARCH = 5, SAM_TRACK = 2 }` | each 1-60, and at most half of `TrackMemorySec` | **[BKE]** Seconds between updates of a track, by the kind of radar that holds it: `EWR` an early-warning or GCI radar, `SAM_SEARCH` a SAM's acquisition radar (or a single-target tracker), `SAM_TRACK` a HOT multi-target engagement radar (a `HarmCapableSystems` system). A rate above half of `TrackMemorySec` is capped, with an error in the log. Any other key is ignored and logged in dcs.log. `{ EWR = 5, SAM_SEARCH = 5, SAM_TRACK = 5 }` gives Medusa 1.6.0's single rate. See [HARM detection](harm-detection.md#radars-refresh-at-their-own-pace) |
| `SensorCleanupSec` | number | 30 | 5-300 | How often records of contacts that left a sensor's coverage are cleared. **[BKE]** An error is logged if it is below the slowest scan rate |
| `ThreatSpeedScaling` | number | 30 | 0-100 | Extra threat value for fast contacts when choosing targets (full at Mach 1) |

## Target assignment

| Field | Type | Default | Range / values | Effect |
|---|---|---|---|---|
| `EngageTactics` | enum | `"SHOOT_IN_DEPTH"` | `SHOOT_LOOK_SHOOT`, `SHOOT_IN_DEPTH`, `SHOOT_SHOOT`, `SHOOT_SHOOT_FLOOD` | How many batteries engage one track: one; one per range tier; the two best; or up to two plus every eligible short-range SAM |
| `PkFloor` | number | 0.25 | 0-1 | Lowest kill probability at which a battery is given a target |
| `RollingPkEnabled` | boolean | `true` | | Adjust the floor during the mission from the kill rate achieved. **[BKE]** Gun shells are not counted as shots, nor gun kills as hits |
| `TargetKillRate` | number | 0.50 | 0-1 | Kill rate the rolling floor aims for |
| `HoldDownSec` | number | 15 | 0-300 | Seconds a battery stays HOT after its target goes stale or is handed off; also the last-chance salvo window |
| `EngageTimeoutSec` | number | 45 | 0-300 | Seconds without a shot before a target is handed to an equal or better battery |
| `StickyRangePct` | number | 15 | | How far (percent) kill probability may fall below the floor before a battery lets its target go |
| `LookaheadSec` | number | 8 | 0-30 | Seconds ahead a target's position is projected for kill probability |
| `MaxEngageRangePct` | table | none | keys `VLR_SAM`, `LR_SAM`, `MR_SAM`, `SR_SAM`, `AAA`; percent | Caps each role's assignment range at a percentage of its weapons' range. **[BKE]** The decoy responses use the capped range too |

**[BKE]** A suspected decoy counts half as much when targets are ranked; a probable decoy is not assigned to long- and
medium-range SAMs ([Decoys](decoys.md)).

## Emission control

| Field | Type | Default | Range / values | Effect |
|---|---|---|---|---|
| `EMCON` | table | `EWR` and `GCI` `ALWAYS_ON`; SAM roles and `AAA` `MINIMIZE` | keys `EWR`, `GCI`, `VLR_SAM`, `LR_SAM`, `MR_SAM`, `SR_SAM`, `AAA`, `GENERIC_SAM`; values `MINIMIZE`, `PERIODIC_SCAN`, `COORDINATED_ROTATION`, `ALWAYS_ON` | When each role radiates while not engaging. `MINIMIZE` is not allowed for `EWR` and `GCI` (they are kept `ALWAYS_ON`). **[BKE]** A role the mission sets here is never woken by crew reports or local initiative (the built-in defaults do not count), and `MINIMIZE` for a local cueing radar's role (`EWR` alone, `AAA` with guns) stops its periodic sweeps |
| `ScanSec` | number | unset (30) | 0-86400 | Seconds a radar is on per cycle under `PERIODIC_SCAN` and `COORDINATED_ROTATION` |
| `QuietPeriodSec` | number | unset (0) | 0-86400 | Seconds off between cycles |
| `EmconRotateGroups` | number | 2 | | How many groups take turns under `COORDINATED_ROTATION` |

## HARM defense

| Field | Type | Default | Range / values | Effect |
|---|---|---|---|---|
| `HARMResponse` | enum | `"AUTO_DEFENSE"` | `AUTO_DEFENSE`, `SELF_DEFEND`, `SHUTDOWN_UNLESS_PD`, `SHUTDOWN`, `IGNORE` | What a battery does when a confirmed HARM is inbound: decide by its point defense and defense points; stay up if its own defense points outnumber the HARMs; shut down unless point defense covers it; always shut down; or nothing |
| `HARMShutdownM` | number | unset (15000) | 0-300000 | How close (meters) a HARM's predicted path must pass to threaten a battery |
| `HARMSaturateOnAmmo` | boolean | `false` | | Cap a battery's defense points at the missiles it has left |
| `PoolDefensePoints` | boolean | `false` | | Nearby HARM-capable batteries add their defense points together |
| `PoolDefensePointsRadius` | number | unset (no pooling) | 1000-100000 | Radius of the pool, in meters; pooling needs both this and `PoolDefensePoints` |
| `DefendPk` | number | 0.30 | 0-1 | Lowest kill probability at which point defense engages a HARM |
| `BallisticSimMaxSec` | number | 120 | 10-600 | How far ahead a contact's flight is simulated for the HARM check, in seconds |
| `BallisticSimStepSec` | number | 1.0 | 0.1-5 | Time step of that simulation |

**[BKE]** HARM classification itself (how many looks, the score bounds, sticky ARM labels, the released-store hold)
has no doctrine field: see [HARM detection and contact evidence](harm-detection.md) and
[Released stores](released-stores.md).

## MANPAD (`MANPAD = { ... }`)

| Field | Type | Default | Range | Effect |
|---|---|---|---|---|
| `MANPAD.AlertnessDecaySec` | number | 14400 | 0 or more | Seconds asleep before a team's alertness resets; 0 turns decay off. The flat name `MANPADAlertnessDecaySec` still works |
| `MANPAD.FieldRadioRangeM` | number | 5000 | 0-50000 | Range at which a HOT team wakes sleeping teams; 0 turns it off. The flat name `MANPADFieldRadioRangeM` still works |
| `MANPAD.AudioRangeM` | number | 6000 | 0-6000 | Most a team can hear; each team draws its own range up to this; 0 turns hearing off. **[BKE]** In training mode each team uses the middle of the range |

See the official [MANPAD Groups](https://medusa.airdefense.systems/guides/manpad-groups/) guide. **[BKE]** With
`CrewFactors` on and the network `SURPRISED`, sleeping teams do not watch the sky until the network is `ALERTED` (as
under `WARM_WAR` or `COLD_WAR` posture).

## AAA (`AAA = { ... }`)

| Field | Type | Default | Range | Effect |
|---|---|---|---|---|
| `AAA.AudioRangeM` | number | 6000 | 0-20000 | How far an independent gun crew hears aircraft; 0 turns hearing off |
| `AAA.AreaFireChance` | number | 0.20 | 0-0.5 | Chance by day that a crew answers with area fire; at night the chance is 1 minus this |
| `AAA.BarrageChance` | number | 0.25 | 0-1 | Chance that area fire becomes a barrage |
| `AAA.MaxBarrageGroups` | integer | 15 | 0-100 | Most gun groups in barrage at once, map-wide; 0 turns barrages off; the lowest value of any network wins |

See the official [AAA Groups](https://medusa.airdefense.systems/guides/aaa-groups/) guide.

## Crew suppression (`CrewSuppression = { ... }`)

Stock since Medusa 1.5.0: damage, nearby impacts and cannon bursts can suppress AAA and MANPAD crews for a while.

| Field | Type | Default | Range / values | Effect |
|---|---|---|---|---|
| `CrewSuppression.Enabled` | boolean | `true` | | Crew suppression on or off |
| `CrewSuppression.DurationMinSec` | number | 30 | 1-3600 | Shortest suppression |
| `CrewSuppression.DurationMaxSec` | number | 120 | 1-3600 | Longest suppression (if below the minimum, both take their defaults) |
| `CrewSuppression.MaxGroupDiameterM` | number | 609.6 | 1-100000 | Groups spread wider than this are not suppressed |
| `CrewSuppression.ExplosiveRadiusScaleM` | number | 10 | 0.1-500 | Suppression radius of a blast: this times the cube root of its explosive mass in kg |
| `CrewSuppression.ExplosiveRadiusMaxM` | number | 500 | 1-500 | Largest blast suppression radius |
| `CrewSuppression.ExplosiveEffectiveness` | number | 1 | 0-1 | Suppression chance at the center of a blast, falling to 0 at its radius |
| `CrewSuppression.SkillResistancePerLevel` | number | 0.1 | 0-0.3 | How much shorter suppression is for each skill level above Average |
| `CrewSuppression.CannonRadiusM` | number | 150 | 1-500 | Suppression radius of a cannon burst |
| `CrewSuppression.CannonEffectiveness` | number | 0.5 | 0-1 | Suppression chance at the center of a cannon burst |
| `CrewSuppression.DefaultCrewSkill` | enum | `"AVERAGE"` | `AVERAGE`, `GOOD`, `HIGH`, `EXCELLENT` | Skill of a unit the mission file gives none, for its suppression resistance. **[BKE]** Also its reporting skill for [crew reports](crews-and-readiness.md) unless `CrewFactorsDefaultSkill` is set |

## [BKE] Decoys

| Field | Type | Default | Effect when on | When off |
|---|---|---|---|---|
| `DecoyAssessment` | boolean | `true` | Contacts that glide like a TALD become suspected, then probable decoys; long- and medium-range SAMs stop engaging and waking for probable decoys | No decoy labels; the three switches below then do nothing either |
| `ManageEngageAirWeapons` | boolean | `true` | A HOT long- or medium-range battery's DCS "engage air weapons" option is turned off while only probable decoys and known aircraft are in its reach | Medusa never turns the option off |
| `DecoyTestShots` | boolean | `true` | Against a lone suspected-decoy group a battery fires one missile and watches the result | Normal salvoes |
| `DecoyFireDiscipline` | boolean | `true` | A battery whose own fire-control radar locks a probable decoy, or that fires at one, turns "engage air weapons" off for 20 s | No fire holds. Needs `ManageEngageAirWeapons` on: with that off it does nothing, and dcs.log says so |

Details: [Decoys and fire discipline](decoys.md).

## [BKE] Track re-acquisition

| Field | Type | Default | Effect when on | When off |
|---|---|---|---|---|
| `EvidenceReacquisition` | boolean | `true` | A lost track is picked back up by a new contact that is where it should be and flies as it should, whatever DCS object it is | Only the same DCS object near its old position is re-associated (Medusa 1.6.0) |

Details: [Track re-acquisition](track-reacquisition.md).

## [BKE] Ground sensors

| Field | Type | Default | Effect when on | When off |
|---|---|---|---|---|
| `LocalCueingRadars` | boolean | `true` | A short-reach search radar in a group without missiles (a Dog Ear) is dark until needed and cues the guns and MANPADs around it; a radar with guns is an AAA battery directed by its radar | Such a radar is an always-on early-warning radar; radar + gun groups are classified by unit count (Medusa 1.6.0) |
| `LocalRadarSweeps` | boolean | `true` | A local cueing radar no other ground radar (or AWACS) covers sweeps for 10-20 s every 3-5 minutes | It comes up only for a reason |
| `ObserverReports` | boolean | `true` | Crews of managed ground groups and observer posts look for aircraft and radio reports | No looks, no reports, and no local initiative |
| `LocalInitiative` | boolean | `true` | A crew that sees or hears an aircraft brings its own radar up without waiting for the network | Only the network or a report wakes it |
Removed in BKE 0.1.0: `PassiveDetection` and the `ESM` table (listening stations), because DCS gives mission
scripts no radar state for player-flown aircraft, so a station could not hear a player's jet. A doctrine that still
sets either loads; dcs.log gets one error line saying the field is ignored.

Details: [Local cueing radars and observer posts](local-radars-and-observers.md).

## [BKE] Crews, readiness and training

| Field | Type | Default | Range / values | Effect |
|---|---|---|---|---|
| `Readiness` | enum | none: follows `Posture` (`HOT_WAR` `ENGAGED`, `WARM_WAR` `ALERTED`, `COLD_WAR` `SURPRISED`) | `SURPRISED`, `ALERTED`, `ENGAGED` | How ready the crews are at mission start. It rises during the mission on its own. Has an effect only with `CrewFactors` on. Changing `Posture` during the mission does not change it; `Medusa.API.setReadiness` does |
| `CrewFactors` | boolean | `true` | | Crew skill, readiness and net load decide whether a crew's report is made, how fast and how precise it is, whether it gets through, how often a surprised network's crews look, and how much a busy network slows identification. Off: reports with fixed timings (30-90 s, 10% lost by day, 20% at night) and no readiness effects |
| `CrewFactorsDefaultSkill` | enum | none: follows `CrewSuppression.DefaultCrewSkill` (`AVERAGE`) | `AVERAGE`, `GOOD`, `HIGH`, `EXCELLENT` | **[BKE]** Reporting skill of a crew the mission file gives no skill (spawned during the mission, or set to Random or Player skill). Changes how often and how well such crews report, not how well they resist suppression. Has an effect only with `CrewFactors` on |
| `TrainingMode` | boolean | `false` | | Takes the luck out of Medusa's own detection, identification and reports: typical values instead of random ones, no lost reports. DCS's own randomness stays |

Details: [Crews, readiness and training mode](crews-and-readiness.md).

## Fields accepted but not used

These fields are accepted and validated, but no code in Medusa 1.6.0 or BKE 0.1.0 reads them. Setting them changes
nothing.

| Field | Type | Default | Values |
|---|---|---|---|
| `ShootScoot` | enum | `"NONE"` | `NONE`, `AFTER_ENGAGEMENT`, `TIMED_RELOCATION` |
| `DegradedMode` | enum | `"REVERT_TO_AUTONOMOUS"` | `REVERT_TO_AUTONOMOUS`, `GO_DARK`, `REVERT_TO_SELF_DEFENSE` |
| `LaunchAuthority` | enum | `"LOCAL_AUTONOMY"` | `LOCAL_AUTONOMY`, `REQUIRE_GCI_APPROVAL`, `CENTRALIZED` |
| `GCIPolicy` | enum | `"CLOSEST_AIRBASE"` | `CLOSEST_AIRBASE`, `MOST_LETHAL_INTERCEPTOR`, `ROUND_ROBIN`, `AIRBASE_PRIORITY_ORDER` |
| `C2DelaySec` | number | 2 | 0-60 |
| `FlightSize` | number | 1 | |
| `MaxTargets` | number | 1 | |
| `SkillFactor` | number | 0.1 | |
| `GCIRangeKm` | number | unset | |
| `RelocateMinM`, `RelocateMaxM` | number | unset | |
| `FlightSizeOverrides`, `LaunchCriteria`, `AllowedAirbases` | table | unset | |

The EMCON policy `INTELLIGENT_EMCON` is accepted too and behaves as a radar kept WARM.
