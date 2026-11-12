# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog (https://keepachangelog.com/en/1.1.0/),
and this project adheres to Semantic Versioning (https://semver.org/spec/v2.0.0.html).

Medusa IADS - Black Knight Edition (BKE) is a fork of [Medusa IADS](https://github.com/medusa-iads/medusa) by Zach
Shepard. BKE versions count from 0.0.1, and each BKE release names the Medusa release it is based on. The releases
under [Medusa (upstream) history] are Medusa's own, as Medusa published them.

## [Unreleased]

## [0.0.1] - 2026-11-11

Based on Medusa 1.6.0. The first Black Knight Edition release. Medusa missions load in BKE as
they are, with one exception: a lone, unnamed Dog Ear (see Changed). Each new behaviour is on by default and has a
doctrine switch unless it says otherwise; [docs/differences-from-medusa-1.6.0.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/differences-from-medusa-1.6.0.md)
lists every difference and how to turn it off, and
[examples/bke-stock-behaviour-config.lua](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/examples/bke-stock-behaviour-config.lua) switches all of them off at once.

### Added

- Alert zones: give a trigger zone the property `MedusaFlag` and Medusa keeps that editor flag at the number of hostile
  aircraft its radars track inside the zone, for ordinary triggers to scramble fighters or play messages. Optional
  properties `MedusaThreats` (`aircraft`, `arms`, `munitions`), `MedusaAlt` (`low`, `medium`, `high`), `MedusaLinger`
  (seconds a contact keeps counting, default 30), `MedusaSide` (needed when both coalitions run Medusa) and
  `MedusaLosses` (a flag counting the side's air-defence sites lost inside the zone). Contacts the radars do not hold
  are not counted; probable decoys count as munitions, not aircraft. See [docs/alert-zones.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/alert-zones.md)
- Contact evidence: each radar look estimates the size of a contact's return (radar cross-section with aspect, flicker
  and a range-dependent error, coarser on early-warning radars), a weapon seen leaving an aircraft is a launch cue, and
  a crew within 10 km names what it sees (aircraft, helicopter or weapon). HARM detection uses them as bounded hints: a
  clearly aircraft-sized return is never confirmed as an ARM, and return size alone never makes an aircraft a missile.
  Always on. See [docs/harm-detection.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/harm-detection.md)
- Released stores: a contact first seen where a store just left an aircraft (within 900 m, no more than 150 m above
  it, within 150 m/s of its velocity) is watched for a motor. A rise in energy (height plus speed) of 3 km above the
  most the aircraft had in its last 30 s makes it powered; 3 looks over at least 10 s without one mean no motor, and
  it is not confirmed as an ARM (point defence still engages it when it is coming down on the site). Bombs and glide
  bombs released in sight of the network are no longer called HARMs. Always on. See
  [docs/released-stores.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/released-stores.md)
- Decoy assessment: a large, aircraft-sized contact that glides (its energy falls faster than a 1:14 glide on a
  straight leg) is a suspected decoy after 60 s, counting half when targets are chosen, and a probable decoy after
  90 s (sooner when a missile fired at it draws no reaction), which long- and medium-range SAMs no longer engage or
  wake for. Climbing, gaining energy, a hard turn or 40 s of holding energy clear the label. Doctrine
  `DecoyAssessment`. See [docs/decoys.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/decoys.md)
- Engage-air-weapons management: while everything in a HOT long- or medium-range battery's reach is a probable decoy
  or a known aircraft, its DCS "engage air weapons" option is turned off so its crew does not fire at the decoys on
  its own, and back on when anything else appears. The option is never written within 2 s of a launch. Doctrine
  `ManageEngageAirWeapons`
- Decoy fire discipline: a HOT long- or medium-range battery whose own fire-control radar locks a probable decoy, or
  that fires at one, turns "engage air weapons" off for 20 s, at most 3 times per decoy and 80 s in any 2 minutes;
  never against a decoy whose glide ends within 3 km of the battery. Aircraft are still engaged during a hold. DEBRIEF
  `DECOY_FIRE_HOLD`. Doctrine `DecoyFireDiscipline` (needs `ManageEngageAirWeapons`)
- Decoy test shots: a battery firing at a suspected decoy group alone in its reach fires one missile and holds fire
  until that missile's flight ends (at most 90 s; only with 4 or more missiles left; once per group in 5 minutes). A
  launcher type whose missile loses guidance while the option is off makes no more test shots. Doctrine
  `DecoyTestShots`
- Evidence re-acquisition: a lost track is continued under its old id when a new contact appears where it should be by
  now (within 50 km), flying as it should, whatever DCS object it is. Identification carries over; decoy labels and
  proof of an aircraft only on a close fit; a confirmed ARM's label only across a gap of up to 20 s while it keeps at
  least 60% of its speed, so with the default `TrackMemorySec` (30 s) a confirmed ARM's label does not carry over. A
  weapon seen leaving an aircraft never takes over the aircraft's track. Doctrine `EvidenceReacquisition`. See
  [docs/track-reacquisition.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/track-reacquisition.md)
- Local cueing radars: a search radar with no missile launchers in its group and a reach under 50 km (a Dog Ear reaches
  about 35 km) stays dark until a hostile comes within its reach plus 15 km, a crew it supports is alerted, a report
  covers it or its crew sees an aircraft; it then stays up for at least 60 s and wakes the MANPAD teams and cues the
  guns near it. A Dog Ear with Shilkas is an AAA battery directed by its radar; Igla teams with a Dog Ear are cued by
  it. Doctrine `LocalCueingRadars`; doctrine `LocalRadarSweeps` makes a radar nothing else covers sweep for 10-20 s
  every 3-5 minutes. See [docs/local-radars-and-observers.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/local-radars-and-observers.md)
- Observer posts and crew reports: ground crews and observer posts (groups named with the `obs` or `observer` token,
  or an extra token in config `Roles.OBSERVER`) look for aircraft (8 km by day, a quarter of that at night, terrain
  and weather permitting; low aircraft heard within 3 km) and radio coarse reports that wake MANPAD teams, cue guns
  and local radars, and can bring a dark short- or medium-range SAM up WARM for two minutes. A report never makes a
  track or a firing solution. Doctrine `ObserverReports`; doctrine `LocalInitiative` lets a crew that sees an aircraft
  bring its own radar up without waiting for the network
- ESM listening stations: a ground group named with the `esm` or `elint` token (or config `Roles.ESM`) takes bearings
  on hostile aircraft radars that DCS reports transmitting, within the radio horizon and terrain line of sight.
  Bearings from different stations make a fix (three stations agreeing, or two whose crossing repeats on the next
  look) that cues the area like a hostile report; it is never a track. Fire-control radars heard count as hostile
  evidence for readiness. Jammers are not heard. Doctrine `PassiveDetection` and `ESM` (`MastHeightM`, `MaxRangeKm`,
  `SidelobeRangeKm`, `AewMaxRangeKm`, `BearingSigmaDeg`, `LookIntervalSec`). See
  [docs/esm-listening-stations.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/esm-listening-stations.md)
- Crew skill: whether a crew reports at all, how fast and how precisely follows its Mission Editor skill: reports
  made 25% (Average), 50% (Good), 75% (High), 95% (Excellent). Set crews' skill: untouched Average crews, spawned units
  and Random or Player skill report about one time in four (the last two count as doctrine
  `CrewSuppression.DefaultCrewSkill`, Average by default). Observer posts count one skill level higher. See
  [docs/crews-and-readiness.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/crews-and-readiness.md)
- Readiness: doctrine `Readiness` (`SURPRISED`, `ALERTED`, `ENGAGED`) sets how ready the crews are at mission start,
  apart from `Posture`; left out, it follows `Posture` (`COLD_WAR` SURPRISED, `WARM_WAR` ALERTED, `HOT_WAR` ENGAGED).
  A surprised network looks less often, reports less and slower and loses more reports; it turns ALERTED 2-5 minutes
  after word first spreads and ENGAGED at its first launch or 30-90 s after its first loss. Mission scripts read and
  set it with `Medusa.API.getReadiness` and `Medusa.API.setReadiness`; changing `Posture` mid-mission does not change
  it. Needs `CrewFactors`
- Net load: each network measures how busy its operators and radio net are (tracks, waiting reports, ARMs, own
  missiles in flight, recent losses, scaled to the network's size); a busy net delays and loses more reports and
  slows identification. Doctrine `CrewFactors` switches crew skill, readiness and net load on and off together
- Training mode: doctrine `TrainingMode` (default off) makes Medusa's own random draws take their typical value and
  delivers every crew report, so practice runs are not decided by luck. DCS's own detection and missile hits stay
  random. See [docs/crews-and-readiness.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/crews-and-readiness.md#training-mode)
- Debrief log: one-line `DEBRIEF` INFO entries in dcs.log for the after-action review (`FIRST_DETECTION`,
  `IDENTIFIED`, `REPORT_NOT_MADE`, `REPORT_LOST`, `REPORT_DELIVERED`, `READINESS`, `WAKE`, `ARM_CONFIRMED`,
  `ARM_BLOCKED`, `DECOY_PROBABLE`, `DECOY_FIRE_HOLD`, `SITE_LOST`, `LOCAL_RADAR_UP`, `CREW_ROSTER`, `ESM_INTERCEPT`,
  `ESM_FIX`, `ESM_AMBIGUOUS`, `TRAINING_MODE`), each with mission time and time of day. See
  [docs/debrief-log.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/debrief-log.md)
- Per-kind radar refresh: doctrine `ScanUpdateRateSec` (`EWR` 10 s, `SAM_SEARCH` 5 s, `SAM_TRACK` 2 s for a HOT
  multi-target engagement radar), each capped at half of `TrackMemorySec`
- Runtime identity: `Medusa.baseVersion` (`"1.6.0"`), `Medusa.edition` (`"Black Knight Edition (BKE)"`) and
  `Medusa.displayName` (the name written to dcs.log at start). See [docs/api.md](https://github.com/51st-Vfw/medusa/blob/BKEv0.0.1/docs/api.md)

### Changed

- Breaking: a Dog Ear (or other short-reach search radar) alone in an unnamed group is no longer an always-on
  early-warning radar but a local cueing radar, dark until needed. Name it with the `ewr` token to keep it always on,
  or set doctrine `LocalCueingRadars = false`. A network whose only radar is such a Dog Ear stays blind until the Dog
  Ear comes up: `SAMAsEWR = "WHEN_NO_EWR"` counts the dark Dog Ear as its radar and does not fall back to the SAMs
- `Medusa.version` is the BKE version (`"BKEv0.0.1"`; development builds `"BKEv0.0.1-dev-<branch>"`). A script that
  compares Medusa version numbers should read `Medusa.baseVersion`
- The release files are `medusa-bke.lua` and `medusa-bke-thin.lua`, also zipped as `medusa-bke.zip` and
  `medusa-bke-thin.zip`, with `SHA256SUMS.txt` and `LICENSE`
- HARM classification needs 5 radar looks instead of 25 and no longer waits for the track to be 10 s old; each look
  counts at most 4 towards the score and the total stays within +/-20, so an aircraft tracked for minutes cannot bank
  enough evidence to hide an ARM-like run. A HARM inbound on a HOT S-300 or Tor is classified in about 10 s
- Tracks refresh at the pace of the radar that holds them (see `ScanUpdateRateSec` under Added). `PerTrackScanUpdateRate`
  now sets the rate for AWACS, airborne datalink and ships, and for every radar kind when it is set and
  `ScanUpdateRateSec` does not name that kind
- A confirmed ARM stays an ARM until its flight shows otherwise: it is no longer re-labelled an aircraft when it slows
  or its score turns. It clears once it has flown about 8 s without attacking any SAM site, drops under 50 m/s, or
  after 6 minutes
- The aircraft that fired a confirmed HARM is found from its nearest position within 12 s of the launch (was 3 s),
  so launchers seen only by early-warning radars are found too
- A new or re-acquired track keeps its first sighting in its position history, so its HARM evaluation starts one look
  sooner
- A battery going HOT no longer has DCS's "engage air weapons" option forced on: the mission's setting stays, and
  Medusa writes the option only to undo its own decoy holds. The editor default is on, so most missions see no
  difference
- With `CrewFactors` on, crew skill, readiness and net load decide whether and when crew reports arrive, instead of a
  fixed 30-90 s delay and a fixed 10% (day) or 20% (night) loss; `CrewFactors = false` keeps the fixed timing
- Less server work per tick: HARM checks scan a list of emitting batteries instead of a grid query per track, track
  updates build no event when nothing listens, and several networks started together run their heavy phases in
  different frames
- A doctrine switch set to something other than `true` or `false` (for example `TrainingMode = "true"`) is now an
  error in dcs.log and takes its default, instead of being read as on
- An unknown key inside `ScanUpdateRateSec` or `ESM` (a misspelt setting), and `DecoyFireDiscipline` on while
  `ManageEngageAirWeapons` is off (no fire holds can be made), are reported as errors in dcs.log

### Fixed

- HARMs are classified within their flight time, so the HARM response and point defence can act before impact
  (upstream Medusa issue 41)
- A SHORAD or SAM battery added after start gets point-defence assignment like the batteries present at start
  (upstream Medusa issue 9)
- A battery that recovers from crew suppression gets its point-defence links back
- A gun or MANPAD group that loses several crews in one blast no longer logs an error line for each crew that died
  before its event arrived (the unit is checked to exist before its heading is read)
- Event handlers no longer ask DCS for unit data of scenery and weapons (hits on trees, missile deaths), which logged
  an error line each time (the object's category is checked first)

## [Medusa (upstream) history]

Medusa's own releases, up to the one this edition is based on.

## [1.6.0] - 2026-09-24

### Fixed
- Normalize DCS event unit IDs so shots are recorded

## [1.5.0] - 2026-08-21
### Added

- Damage-based crew suppression for managed AAA and MANPAD groups, with doctrine controls, a configurable group-diameter eligibility limit, bounded HIT processing, group-level weapon hold, recovery, and Prometheus observability.
- Bomb- and missile-impact crew suppression with a mission-shared bounded weapon tracker, cube-root blast-radius policy, exact per-unit proximity, bounded spatial queries, and refreshed positions for all managed battery units.
- Aircraft cannon-burst crew suppression with bounded gravity-aware terrain-point estimation and shared terminal-event evaluation.
- Defender crew skill from mission ground-unit data, with doctrine-controlled fallback and resistance effects on suppression probability and duration.

### Changed

- Updated the vendored dcs-harness dependency to 1.0.1 for validated unit-health snapshots.
- Crew suppression now samples each damage, explosive, or cannon suppression duration from a doctrine-configured range that defaults to 30–120 seconds.
- Cannon suppression now defaults to a 150-metre uncertainty radius for forward-vector impact estimates.
- Cannon suppression DEBUG logs now identify subscription handles, the exact boundary or ballistic-projection rejection stage, and the estimate's distance from the nearest indexed defender visited by the bounded spatial query.

### Fixed

- Radar-capable batteries with `BatteryTargetDatalink` enabled now report detections while WARM, allowing their own periodic or continuous radar scans to produce tracks and trigger doctrine-controlled engagement.
- Re-associated tracks now preserve their identification dwell time, allowing `BANDIT` tracks observed during periodic scans to become `HOSTILE` under `TIGHT` rules of engagement.
- Track re-association now accounts for movement during sensor gaps by checking the last observed position and its constant-velocity projection.
- HARM assessment now retains cumulative evidence across decisions and track re-association, and reverses an existing classification only after evidence crosses the opposing decision threshold.
- HARM assessment now accumulates evidence during its 25-observation decision floor, preventing a short aircraft attack arc from discarding its preceding non-HARM evidence.
- HARM evidence and track-identification promotion now process each sensor observation once, preventing retained tracks from accumulating evidence or changing identification while unobserved.

## [1.4.0] - 2026-08-20
### Added

- Source-derived operator track IDs for tactical displays, Grafana, and human-readable logs while retaining ULIDs as internal identifiers.

## [1.3.1] - 2026-08-19
### Added

- `MANPAD.AudioRangeM` doctrine control for the maximum MANPAD audio-detection range.

### Changed

- MANPAD doctrine controls now use the `MANPAD` subtable, consistent with AAA doctrine controls.

### Fixed

- `AAA.AreaFireChance` is now limited to `0.5`, so the inverted nighttime chance cannot be lower than the daytime chance.

### Deprecated

- Flat `MANPADAlertnessDecaySec` and `MANPADFieldRadioRangeM` doctrine fields remain compatibility aliases for the nested MANPAD fields.

## [1.3.0] - 2026-08-18
### Added

- Managed AAA groups with local visual and audio detection, area and barrage fire, nearby barrage propagation, and radar-directed operation.
- AAA doctrine controls for audio range, area-fire and barrage chances, and the map-wide barrage group limit.
- AAA shell-ammunition tracking, with a 12 km fallback range when DCS omits shell range data.

### Changed

- Release archives now contain Lua artifacts with the Medusa version in their filenames.
- Updated the bundled dcs-harness dependency to 1.0.0 and migrated ground-plane geometry to its DCS Vec2 and Vec3 contracts.
- `EngageTactics` limits now count missile batteries only; AAA assignments do not consume or block missile-battery slots.
- Local MANPAD and independent AAA groups now use a separate spatial index so they do not enlarge long-range IADS candidate queries.
- Radar-directed AAA that loses its search radar now releases its target and point-defense assignments before switching to independent behavior.

### Fixed

- Release-tag builds now stamp the exact tag version in generated artifacts.
- HOT independent AAA is no longer considered an emitter during HARM classification.
- `SHOOT_LOOK_SHOOT` now permits one VLR and one standard missile battery to engage the same track.
- Ground sensor groups now receive their configured ROE, alarm, and emissions state on the first EMCON pass.

## [1.2.0] - 2026-08-12
### Added

- Managed MANPAD groups with autonomous detection and engagement, coordinated wake behavior, ammunition and rearm handling, and tactical-map and Prometheus observability.

### Changed

- Reduced per-tick memory allocation in HARM detection by reusing the feature-cache slot across evaluations

### Fixed

- `MaxEngageRangePct` doctrine cap now applies to ALWAYS_ON batteries self-assigning under EMCON, matching WTA and handoff behavior
- Guilt-by-association no longer promotes STALE tracks without fresh sensor evidence
- Unrecoverable-failure shutdown is now resilient to store corruption and completes the release-to-AI path instead of silently halting
- SEAD-priority assignment now respects the `MaxEngageRangePct` doctrine cap; out-of-range batteries can no longer be force-assigned to HARM/SEAD threats ahead of the greedy assignment loop

## [1.1.3] - 2026-04-09

### Changed

- Add priority-sorted HARM evaluation: tracks ordered by altitude * velocity hash, confirmed HARMs are deprioritized. The top 1/3rd of tracks are now guaranteed to be evaluated, with budget remainder (minimum 1/3rd of the total budget) being used to evaluate remaining tracks.
- Add adaptive SPRT min-scans that reduces the 15-scan floor proportionally to back pressure, so HARMs will be confirmed in fewer steps under high back pressure.
- Fix despawned airborne sensors not removed from store during position update
- Rename "SPRT" to "ARM" in HARM detection log messages

### Fixed

- Despawned airborne sensors (AWACS, EWR) no longer spam "Unit not found" log messages indefinitely

## [1.1.2] - 2026-04-08
### Added

- `AllowDynamicProbing` configuration option (default: off) enables spawning sensor probe groups at runtime to extract detection ranges for unit types not encountered at mission start

### Removed

- HEAVY aircraft type classification; unreliable heuristic based on sustained straight flight that misidentified transiting fighters as bombers

### Fixed

- Dynamically added batteries and probing results now update the maximum engagement range used for spatial queries
- Dynamically spawned batteries now receive detection range data from the probe cache, correcting engagement range calculations for late-spawned SAMs
- HARM ballistic CPA simulation now covers the configured duration regardless of time step size
- Point defense threat search centers on the SHORAD provider's position instead of the protected battery
- VLR_SAM batteries now receive target assignments under SHOOT_LOOK_SHOOT doctrine
- HARM detection no longer force-confirms tracks at the SUSPECT confidence level when scans are exhausted; requires PROBABLE or higher

## [1.1.1] - 2026-04-07
### Fixed

- Emergency shutdown on unrecoverable failure now correctly releases batteries to autonomous AI
- Destroyed or despawned sensor units (EWR, AWACS) are now removed from the sensor store instead of being polled indefinitely
- Batteries with no remaining ammo are now deactivated instead of staying HOT indefinitely
- Doctrine range cap (MaxEngageRangePct) now applied consistently in handoff evaluation and EMCON self-assign, preventing handoffs to out-of-range batteries

## [1.1.0] - 2026-04-07
### Added

- Runtime EMCON control API: `setEMCON`, `getEMCON`, `setScanTiming`, `getScanTiming`, `setRotationGroups`, `getRotationGroups`

### Fixed

- Hostile intent never promoted BANDIT to HOSTILE in WARM_WAR and COLD_WAR postures without border zones

## [1.0.2] - 2026-04-06

### Fixed

- Group names using underscores, hyphens, or other separators after the network prefix were not discovered (e.g., `RSAM_SA2` with prefix `RSAM`)

## [1.0.1] - 2026-04-06
### Added

- Medusa shuts itself down after prolonged unrecoverable failure and releases all batteries to autonomous DCS AI

### Changed

- HARM evaluator no longer copies the full position history buffer each tick, reducing per-tick memory allocation by ~39%

### Fixed

- Rare edge case where NaN kill probability could abort the assignment phase
- Missing position on a track during handoff evaluation silently aborted the maintain phase for that tick

## [1.0.0] - 2026-04-07

### Added
	- Initial Release

[Unreleased]: https://github.com/51st-Vfw/medusa/compare/BKEv0.0.1...HEAD
[0.0.1]: https://github.com/51st-Vfw/medusa/releases/tag/BKEv0.0.1
[Medusa (upstream) history]: https://github.com/medusa-iads/medusa/blob/main/CHANGELOG.md
[1.6.0]: https://github.com/medusa-iads/medusa/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/medusa-iads/medusa/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/medusa-iads/medusa/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/medusa-iads/medusa/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/medusa-iads/medusa/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/medusa-iads/medusa/compare/v1.1.3...v1.2.0
[1.1.3]: https://github.com/medusa-iads/medusa/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/medusa-iads/medusa/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/medusa-iads/medusa/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/medusa-iads/medusa/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/medusa-iads/medusa/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/medusa-iads/medusa/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/medusa-iads/medusa/releases/tag/v1.0.0
