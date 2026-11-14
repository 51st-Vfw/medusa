# [BKE] Debrief log

BKE writes one-line `DEBRIEF` entries to dcs.log for after-action review: what the network knew, when it knew it, and
what it did about it. Put them next to a Tacview recording to see why a SAM woke up, why a report never arrived, or
why a HARM was or was not called.

The lines are written at `INFO`, the default `LogLevel`; with `LogLevel = "ERROR"` or `"NONE"` nothing is written
(nor formatted). There is no switch of its own.

## Line format

```
DEBRIEF|t=<seconds>|clock=<HH:MM:SS>|net=<network>|ev=<EVENT>|key=value|key=value|...
```

| Field | Meaning |
|---|---|
| `t` | Seconds since mission start, one decimal |
| `clock` | Mission time of day, the clock Tacview and the F10 map show (past midnight it wraps to `00:00:00`) |
| `net` | The network's `name` from `MEDUSA_CONFIG.Networks` |
| `ev` | The event (below) |
| `key=value` | The event's fields. A field with no value is left out. A pipe character inside a value is written as `/` and line breaks as spaces, so a line always splits on pipes |

dcs.log prefixes each line with its own time stamp and the `Medusa` tag; search for `DEBRIEF|` to find them.

Example:

```
DEBRIEF|t=812.4|clock=10:13:32|net=NORTH|ev=REPORT_DELIVERED|from=iads.north.obs.hill-412|after_s=74|saw=hostile_jet|x=-281500|z=640200|err_m=1000|caused=wake_sam+cue_crews|woke=iads.north.sa6|crews_cued=2|radars_cued=0|load=0.12
```

## Events

Common fields: `track` is the track's display id (the id the tactical display and logs show); positions `x`, `z` are
DCS map coordinates in meters; `load` is the [net load](crews-and-readiness.md#net-load) from 0 to 1.

### Tracks

| Event | When | Fields |
|---|---|---|
| `FIRST_DETECTION` | A track that is not known friendly is first made (once per track; a re-acquired track writes none) | `track`; `id` its identification then; `sensor` the group that first held it; `kind` that sensor's kind (`EWR`, `SAM_SEARCH`, `SAM_TRACK`, or a source such as `AWACS`, `SHIPBORNE_RADAR`, `AIRBORNE_DATALINK`); `range_km` from that sensor; `alt_m` height above sea level; `alt_band` `low` (up to 1000 m), `medium` or `high` (6000 m and above) |
| `IDENTIFIED` | A track is first called `BANDIT` or `HOSTILE` (once per track) | `track`; `id` the new identification; `from_id` the one before; `sensor`, `kind`, `range_km` of the sensor that first held it; `alt_m`, `alt_band` now; `held_s` seconds the network held the track before the call |

### HARMs, released stores and decoys

| Event | When | Fields |
|---|---|---|
| `ARM_CONFIRMED` | A track is confirmed as an anti-radiation missile ([HARM detection](harm-detection.md)) | `track`; `llr` the score; `scans` looks used |
| `ARM_BLOCKED` | An ARM-like track was not confirmed (once per track and reason) | `track`; `why`: `unpowered` (a store dropped by an aircraft, no motor: [Released stores](released-stores.md)), `window` (it appeared beside an aircraft and is being watched for a motor), `ballistic` (a store seen too late to link that falls like a bomb and will land clear of every air-defense battery: [Released stores](released-stores.md#a-store-seen-too-late-to-link)) or `size` (its return is aircraft-sized); `llr`; `scans` |
| `DECOY_PROBABLE` | A track becomes a probable decoy ([Decoys](decoys.md)) | `track`; `from` its label before (`AIRCRAFT` or `SUSPECT`); `reason`: `sustained straight energy loss`, `unanswered launches` or `seen as a munition` |
| `DECOY_FIRE_HOLD` | A battery turns engage-air-weapons off against a probable decoy | `battery`; `track` the decoy; `trigger` `lock` (its fire-control radar locked the decoy) or `shot` (it fired at it); `sec` the hold's length (20); `n` which hold against this decoy (1-3); `waited` seconds the hold waited for a missile in flight, when 1 s or more |

### Crews and reports

| Event | When | Fields |
|---|---|---|
| `CREW_ROSTER` | Once per network at start | `observers` number of observer posts; `observer_skills` their skills; `crews` number of other crews; `crew_skills` their skills; `defaulted` units that took the default skill; `default_skill` |
| `REPORT_NOT_MADE` | A crew saw or heard an aircraft but did not get a report out ([crew factors](crews-and-readiness.md)) | `from` the crew's group; `skill` its mission skill; `skill_as` the skill it reports as (observer posts); `readiness`; `saw` what (`hostile_jet`, `unidentified_helicopter`, ...); `heard` `true` when only heard; `load` |
| `REPORT_LOST` | A report never arrived | `from`; `why` `not_heard` (lost on the net) or `net_saturated` (too many reports waiting); `load`. With `not_heard` only, also `after_s` (seconds after it was sent) and `saw` |
| `REPORT_DELIVERED` | A report arrived | `from`; `after_s`; `saw`; `x`, `z` the reported position; `err_m` its error; `caused`: `wake_sam`, `cue_crews`, `cue_radar` joined by `+`, or `nothing`; `woke` the SAM groups woken; `crews_cued`; `radars_cued`; `load` |
| `READINESS` | The network's readiness changes ([Readiness](crews-and-readiness.md#readiness)) | `from`; `to`; `why`: `hostile_track`, `hostile_report` (word spreads), `first_launch`, `first_loss`, or `api` (`Medusa.API.setReadiness`) |

### Batteries, radars and losses

| Event | When | Fields |
|---|---|---|
| `WAKE` | A battery is brought up WARM or HOT for a reason (start-up states, EMCON cycles and rearming write none) | `battery`; `from` its state before (`COLD`, `WARM`, ...); `to` `WARM` or `HOT`; `reason`: `assigned` (given a target), `emcon_self_assign`, `observer_report`, `own_crew_saw` / `own_crew_heard` (local initiative), `manpad_engages` (a MANPAD team fires), `point_defence_vs_arm` / `point_defence` (defending a site), `self_defence_vs_arm` (an ARM inbound on the battery itself), or `local_radar: <reason>`; `track` the track it came up for, when there is one |
| `LOCAL_RADAR_UP` | A [local cueing radar](local-radars-and-observers.md#local-cueing-radars) comes up | `radar` its group; `reason`: `threat near`, `supported units alerted`, `observer report`, `local initiative` or `periodic sweep` |
| `SITE_LOST` | A site of the network is lost (once per group) | `site` its group; `kind` `sensor` (an early-warning radar or other sensor group) or the battery's role (`VLR_SAM`, `LR_SAM`, `MR_SAM`, `SR_SAM`, `GENERIC_SAM`, `AAA`, `MANPAD`) |

### Run

| Event | When | Fields |
|---|---|---|
| `TRAINING_MODE` | At start, when the network runs in [training mode](crews-and-readiness.md#training-mode) | `on=true` |

## Reading it

- `grep "DEBRIEF|" dcs.log` gives the debrief alone; `grep "net=NORTH"` one network.
- Split a line on `|`, then each field on the first `=`: the first field is `DEBRIEF`, the rest are `key=value`.
- `t` lines up with Tacview's mission time when the recording starts with the mission; `clock` lines up with Tacview's
  time-of-day display.
