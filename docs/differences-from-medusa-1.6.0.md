# Differences from Medusa 1.6.0

Medusa IADS - Black Knight Edition (BKE) v0.1.0 is Medusa v1.6.0 with the changes below. A mission made for Medusa
1.6.0 loads in BKE unchanged; one change can alter how such a mission plays (see [the breaking
change](#the-breaking-change)).

## The breaking change

**A lone Dog Ear is no longer an always-on early-warning radar.** In Medusa 1.6.0 a short-range search radar alone in
a group without a role token (typically a Dog Ear) is an always-on early-warning radar. In BKE it is a
[local cueing radar](local-radars-and-observers.md#local-cueing-radars): dark until a hostile comes near, a crew it
supports is alerted, a crew report covers it, or its own sweep every 3-5 minutes.

A cueing radar is not an early-warning radar, so for `SAMAsEWR = "WHEN_NO_EWR"` (the default) a network whose only
radar is a lone, unnamed Dog Ear has no early-warning radar: its long- and medium-range SAMs act as early-warning
radars, as in Medusa 1.6.0 for a network without one. Such a mission therefore plays differently from 1.6.0, where
the Dog Ear was the always-on radar and the SAMs stayed dark: here the SAM search radars radiate and the Dog Ear is
dark. Set `SAMAsEWR = "DISABLED"` to keep the SAMs dark (the network then sees only what the Dog Ear sees when it
comes up). A network that also has an early-warning or GCI radar, or an AWACS, keeps its SAMs as SAMs.

**Remedy:** put the `ewr` token in the Dog Ear's group name (for example `iads.north.ewr.dogear-1`) to keep it an
always-on early-warning radar (a network whose only radar it is then keeps its SAMs as SAMs, as in Medusa 1.6.0), or
set doctrine `LocalCueingRadars = false` to keep every such radar as in Medusa 1.6.0.

## Other changes an existing mission may notice

| Change | Medusa 1.6.0 | BKE | To get 1.6.0 behavior |
|---|---|---|---|
| HARM classification | 25 looks and a 10 s wait | 5 looks, no wait | none (always on) |
| Track refresh | 5 s for every radar | 10 s early-warning, 5 s SAM search, 2 s HOT engagement radar | `ScanUpdateRateSec = { EWR = 5, SAM_SEARCH = 5, SAM_TRACK = 5 }` |
| Engage-air-weapons when a battery goes HOT | Turned on every time | Left as the mission set it; BKE turns it off only for its decoy responses and back on afterwards | none; only matters if the mission set it off in the editor |
| Dog Ear + guns | AAA battery only with two or more guns per radar, otherwise the guns are unmanaged | AAA battery directed by its radar | `LocalCueingRadars = false` |
| Group-name segments starting `obs`, `observer`, `esm`, `elint` | No meaning | Observer post (`esm`, `elint`: an untrained lookout post) | Rename the segment |
| A doctrine switch set to a non-boolean (`"true"`, `1`) | Read as on | Error in the log, default used | Use `true` or `false` |
| A top-level doctrine field Medusa does not know, or a number field set to a non-number | An unknown key is ignored without a word | Error in the log naming the key (and the field it resembles when only the case differs); a non-number takes the default | Fix the spelling or the value |
| `medusa_*_duration_seconds` metrics inside DCS | Record 0 for every measurement (mission scripts have no wall clock) | Record nothing unless the server restores `os` | none |
| `Medusa.version` | The Medusa version | The BKE version, `"BKEv0.1.0"`; the Medusa version is `Medusa.baseVersion` (`"1.6.0"`) | Read `Medusa.baseVersion` |
| dcs.log at `INFO` | Stock lines | Also `DEBRIEF` lines and BKE's mission-maker lines | `LogLevel = "ERROR"` (also hides stock INFO lines) |

## Everything BKE adds or changes

| Area | What | Switch (doctrine unless noted) | Page |
|---|---|---|---|
| HARM | Faster classification (5 looks, no age wait), bounded score, sticky ARM labels, shooter found at any refresh rate | always on | [HARM detection](harm-detection.md) |
| HARM | Per-radar track refresh rates | `ScanUpdateRateSec` | [HARM detection](harm-detection.md#radars-refresh-at-their-own-pace) |
| Contact evidence | Return size, launch cues, crews naming what they see within 10 km | always on | [HARM detection](harm-detection.md#contact-evidence) |
| Released stores | A bomb or glide bomb dropped near a radar is not confirmed as an ARM, nor a bomb seen too late that falls away from every battery | always on | [Released stores](released-stores.md) |
| Decoys | Decoy labels; engage-air-weapons management; fire holds; test shots | `DecoyAssessment`, `ManageEngageAirWeapons`, `DecoyFireDiscipline`, `DecoyTestShots` | [Decoys](decoys.md) |
| Tracks | Re-acquisition from where a lost track should be, not from its DCS object | `EvidenceReacquisition` | [Track re-acquisition](track-reacquisition.md) |
| Ground sensors | Local cueing radars and their sweeps | `LocalCueingRadars`, `LocalRadarSweeps` | [Local radars and observers](local-radars-and-observers.md) |
| Ground sensors | Crew and observer-post reports; local initiative | `ObserverReports`, `LocalInitiative`; name token `obs` / `observer` (`Roles.OBSERVER`) | [Local radars and observers](local-radars-and-observers.md#observer-reports) |
| Crews | Crew skill, readiness, net load | `CrewFactors`, `Readiness`, `CrewFactorsDefaultSkill` (the reporting skill of spawned, Random and Player units; unset, `CrewSuppression.DefaultCrewSkill`) | [Crews and readiness](crews-and-readiness.md) |
| Crews | Training mode | `TrainingMode` (off by default) | [Training mode](crews-and-readiness.md#training-mode) |
| Mission makers | Point defense tied to the SAM it protects; several providers per SAM | `MEDUSA_CONFIG.PointDefense` | [Configuration](configuration.md#bke-point-defense) |
| Mission makers | Alert zones: editor flags from the radar picture | trigger-zone properties | [Alert zones](alert-zones.md) |
| After-action | Debrief log | `LogLevel` `INFO` | [Debrief log](debrief-log.md) |
| API | `Medusa.API.getReadiness` / `setReadiness`; `Medusa.edition`, `Medusa.baseVersion`, `Medusa.displayName` | | [Runtime API](api.md) |
| Fixes | Point defense for very-long-range SAMs, and for a SAM whose point-defense group was destroyed; point defense for SHORAD and SAM batteries spawned after start ([medusa#9](https://github.com/medusa-iads/medusa/issues/9)); HARMs classified within their flight time ([medusa#41](https://github.com/medusa-iads/medusa/issues/41)); point-defense links after crew suppression; no harness ERROR lines from scenery, weapons or crews killed in one blast, or from gun shells; gun shells take no crew-suppression tracker slot; gun fire leaves the rolling Pk alone; lighter server load | always on | [Changelog](../CHANGELOG.md) |

Defaults: every BKE switch is on except `TrainingMode`. `Readiness` follows `Posture`, so with the default
`HOT_WAR` the crews start `ENGAGED`.

To compare with stock Medusa, [examples/bke-stock-behaviour-config.lua](../examples/bke-stock-behaviour-config.lua)
turns off everything BKE has a switch for.
