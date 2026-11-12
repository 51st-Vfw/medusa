# Differences from Medusa 1.6.0

Medusa IADS - Black Knight Edition (BKE) v0.0.1 is Medusa v1.6.0 with the changes below. A mission made for Medusa
1.6.0 loads in BKE unchanged; one change can alter how such a mission plays (see [the breaking change](#the-breaking-change)).

## The breaking change

**A lone Dog Ear is no longer an always-on early-warning radar.** In Medusa 1.6.0 a short-range search radar alone in
a group without a role token (typically a Dog Ear) is an always-on early-warning radar. In BKE it is a
[local cueing radar](local-radars-and-observers.md#local-cueing-radars): dark until a hostile comes near, a crew it
supports is alerted, a crew report covers it, or its own sweep every 3-5 minutes.

A dark cueing radar still counts as one of the network's radar groups, so `SAMAsEWR = "WHEN_NO_EWR"` (the default)
does not turn the long- and medium-range SAMs into early-warning radars for a network whose only radar is a lone Dog
Ear: that network is blind until the Dog Ear comes up.

**Remedy:** put the `ewr` token in the Dog Ear's group name (for example `iads.north.ewr.dogear-1`) to keep it an
always-on early-warning radar, or set doctrine `LocalCueingRadars = false` to keep every such radar as in Medusa
1.6.0.

## Other changes an existing mission may notice

| Change | Medusa 1.6.0 | BKE | To get 1.6.0 behaviour |
|---|---|---|---|
| HARM classification | 25 looks and a 10 s wait | 5 looks, no wait | none (always on) |
| Track refresh | 5 s for every radar | 10 s early-warning, 5 s SAM search, 2 s HOT engagement radar | `ScanUpdateRateSec = { EWR = 5, SAM_SEARCH = 5, SAM_TRACK = 5 }` |
| Engage-air-weapons when a battery goes HOT | Turned on every time | Left as the mission set it; BKE turns it off only for its decoy responses and back on afterwards | none; only matters if the mission set it off in the editor |
| Dog Ear + guns | AAA battery only with two or more guns per radar, otherwise the guns are unmanaged | AAA battery directed by its radar | `LocalCueingRadars = false` |
| Group-name segments starting `obs`, `observer`, `esm`, `elint` | No meaning | Observer post or listening station | Rename the segment |
| A doctrine switch set to a non-boolean (`"true"`, `1`) | Read as on | Error in the log, default used | Use `true` or `false` |
| `Medusa.version` | The Medusa version | The BKE version, `"BKEv0.0.1"`; the Medusa version is `Medusa.baseVersion` (`"1.6.0"`) | Read `Medusa.baseVersion` |
| dcs.log at `INFO` | Stock lines | Also `DEBRIEF` lines and BKE's mission-maker lines | `LogLevel = "ERROR"` (also hides stock INFO lines) |

## Everything BKE adds or changes

| Area | What | Switch (doctrine unless noted) | Page |
|---|---|---|---|
| HARM | Faster classification (5 looks, no age wait), bounded score, sticky ARM labels, shooter found at any refresh rate | always on | [HARM detection](harm-detection.md) |
| HARM | Per-radar track refresh rates | `ScanUpdateRateSec` | [HARM detection](harm-detection.md#radars-refresh-at-their-own-pace) |
| Contact evidence | Return size, launch cues, crews naming what they see within 10 km | always on | [HARM detection](harm-detection.md#contact-evidence) |
| Released stores | A bomb or glide bomb dropped near a radar is not confirmed as an ARM | always on | [Released stores](released-stores.md) |
| Decoys | Decoy labels; engage-air-weapons management; fire holds; test shots | `DecoyAssessment`, `ManageEngageAirWeapons`, `DecoyFireDiscipline`, `DecoyTestShots` | [Decoys](decoys.md) |
| Tracks | Re-acquisition from where a lost track should be, not from its DCS object | `EvidenceReacquisition` | [Track re-acquisition](track-reacquisition.md) |
| Ground sensors | Local cueing radars and their sweeps | `LocalCueingRadars`, `LocalRadarSweeps` | [Local radars and observers](local-radars-and-observers.md) |
| Ground sensors | Crew and observer-post reports; local initiative | `ObserverReports`, `LocalInitiative`; name token `obs` / `observer` (`Roles.OBSERVER`) | [Local radars and observers](local-radars-and-observers.md#observer-reports) |
| Ground sensors | ESM listening stations | `PassiveDetection`, `ESM`; name token `esm` / `elint` (`Roles.ESM`) | [ESM listening stations](esm-listening-stations.md) |
| Crews | Crew skill, readiness, net load | `CrewFactors`, `Readiness`; `CrewSuppression.DefaultCrewSkill` also sets the reporting skill of spawned, Random and Player units | [Crews and readiness](crews-and-readiness.md) |
| Crews | Training mode | `TrainingMode` (off by default) | [Training mode](crews-and-readiness.md#training-mode) |
| Mission makers | Alert zones: editor flags from the radar picture | trigger-zone properties | [Alert zones](alert-zones.md) |
| After-action | Debrief log | `LogLevel` `INFO` | [Debrief log](debrief-log.md) |
| API | `Medusa.API.getReadiness` / `setReadiness`; `Medusa.edition`, `Medusa.baseVersion`, `Medusa.displayName` | | [Runtime API](api.md) |
| Fixes | Point defence for SHORAD and SAM batteries spawned after start ([medusa#9](https://github.com/medusa-iads/medusa/issues/9)); HARMs classified within their flight time ([medusa#41](https://github.com/medusa-iads/medusa/issues/41)); point-defence links after crew suppression; no harness ERROR lines from scenery, weapons or crews killed in one blast; lighter server load | always on | [Changelog](../CHANGELOG.md) |

Defaults: every BKE switch is on except `TrainingMode`. `Readiness` follows `Posture`, so with the default
`HOT_WAR` the crews start `ENGAGED`.

To compare with stock Medusa, [examples/bke-stock-behaviour-config.lua](../examples/bke-stock-behaviour-config.lua)
turns off everything BKE has a switch for.
