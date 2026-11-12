# [BKE] Crews, readiness and training mode

An IADS is only as good as the people in it. BKE lets the crews' experience and state of mind shape what the network
learns and how fast, on top of (not instead of) what DCS's own unit skill does to how its units detect and shoot.

Three doctrine fields:

| Field | Default | What it does |
|---|---|---|
| `CrewFactors` | `true` | Crew skill, readiness and net load shape crew reports, how often surprised crews look, and identification times |
| `Readiness` | follows `Posture` | How ready the crews are at mission start: `SURPRISED`, `ALERTED` or `ENGAGED` |
| `TrainingMode` | `false` | Takes the luck out of Medusa's own detection, identification and reports |

## Set your crews' skill

**Ground crews and observer posts report what they see according to their Mission Editor skill.** A crew of Average
skill, the Mission Editor's default for ground units, gets a report out about **one time in four**. So do units
spawned during the mission and units set to Random or Player skill: they count as the doctrine's
`CrewSuppression.DefaultCrewSkill` (Average unless you change it). Give your observer posts, and the crews whose reports
matter, Good, High or Excellent skill.

A group's skill is the best skill among its units. Each network writes one `crew roster` line to dcs.log at start: its
observer posts and other crews by skill, and how many fell back to the default skill.

## Crew skill in reports

With `CrewFactors` on, a crew's skill decides whether it calls in what it saw at all, how fast and how precisely:

| Skill | Report made | Radio delay | Position error |
|---|---|---|---|
| Average | 25% | 1-4 min | ×1.4 |
| Good | 50% | 45-150 s | ×1.0 |
| High | 75% | 30-90 s | ×0.8 |
| Excellent | 95% | 20-40 s | ×0.6 |

Delays are 1.5 times longer at night, 10% shorter when the network is `ENGAGED`, and up to 30 s longer on a busy net.
The position error is that of the [report](local-radars-and-observers.md#observer-reports): about 1 km for a sighting,
2.5 km for a sound.

**Observer posts** (groups named `obs` or `observer`) are trained observers: for making a report, its delay and its
precision they count one skill level higher (Average reports as Good, Good as High, High as Excellent; Excellent stays).
Gun and SAM crews keep their own skill.

## Readiness

Readiness is how ready the crews are, apart from the political `Posture`:

| Readiness | Meaning |
|---|---|
| `SURPRISED` | Peacetime routine: nobody expects anything |
| `ALERTED` | Intelligence says an attack may come at any time: crews at their stations, radios manned |
| `ENGAGED` | A shooting war |

Left out, it follows `Posture`: `HOT_WAR` (the default) gives `ENGAGED`, `WARM_WAR` `ALERTED`, `COLD_WAR`
`SURPRISED`. Changing `Posture` during the mission (`Medusa.API.setPosture`) does not change it.

**It only rises on its own:**

- A `SURPRISED` network turns `ALERTED` 2-5 minutes after word first spreads: it first holds a hostile track, a
  hostile [crew report](local-radars-and-observers.md#observer-reports) gets through, or its
  [listening stations](esm-listening-stations.md) fix a fire-control radar (or hear fire-control radars on three looks
  in two minutes).
- Any network turns `ENGAGED` at its first missile launch, or 30-90 s after it first loses a site (when word of the loss
  arrives).

A mission script can read and set it with `Medusa.API.getReadiness` and `Medusa.API.setReadiness`
([Runtime API](api.md)); setting may also lower it (a new phase, a ceasefire). From there it rises again on its own.

**Readiness has an effect only with `CrewFactors` on.** What it changes:

| | `SURPRISED` | `ALERTED` | `ENGAGED` |
|---|---|---|---|
| Report made | ×0.6 (Average) to ×0.9 (Excellent) | ×1 | ×1 |
| Radio delay | ×2 (Average) to ×1.25 (Excellent) | ×1 | ×0.9 |
| Report reaches someone who acts on it | 60% (observer posts 80%) | 97% | 97% |
| Crews look for aircraft | half their turns (Average) to 87.5% (Excellent); observer posts every turn | every turn | every turn |
| Sleeping MANPAD teams watch the sky | no (as under `WARM_WAR`) | yes, as `Posture` says | yes, as `Posture` says |

At night 10% fewer reports get through, whatever the readiness.

**Skilled crews shrug off surprise faster.** Under `SURPRISED` a crew's own penalties keep a share of their size by
its skill (an observer post's one level up): Average 100%, Good 75%, High 50%, Excellent 25%. That gives report made
×0.6 / 0.7 / 0.8 / 0.9, delay ×2 / 1.75 / 1.5 / 1.25, and looks on 50 / 62.5 / 75 / 87.5% of its turns (the same turns
every run). Getting the report through a surprised net (60%, observer posts 80%) does not depend on the crew's skill.

## Net load

Each network keeps a measure, from 0 to 1, of how busy its operators and radio net are. It adds up:

- hostile and bandit aircraft tracks held (ARMs and probable decoys not counted here);
- reports waiting on the radio;
- ARMs inbound;
- its own missiles in flight (each until its expected time to target, at most a minute);
- sites lost in the last 5 minutes.

A bigger network handles more before it is full: the aircraft, missile and ARM counts that fill it grow with its
number of sites and SAM batteries (at least 32 aircraft tracks, 20 missiles or 4 ARMs; 25 waiting reports or 3 losses
fill any network). A small network with a handful of aircraft and one SAM engaging sits around 0.3; a wing-scale raid
fills it. Load rises at once and calms down over two minutes.

A full net:

- delays crew reports by up to 30 s;
- loses up to 40% more of them;
- stretches track identification times by up to half: a busy network is slower to call a contact bandit or hostile.

So the best case is a network that knows something is coming (`ALERTED`) but is not yet overwhelmed.

## With `CrewFactors` off

Crew reports use fixed timings: a radio delay of 30-90 s (1.5 times longer at night) plus 10 s for each report already
waiting (at most 2 minutes more); 10% lost by day, 20% at night, plus 2% for each report waiting (at most half); every
crew looks on every turn. Readiness and net load have no effect, and identification times are not stretched.

## Training mode

Doctrine `TrainingMode = true` takes the luck out of Medusa's own detection, identification and reporting, so a pilot
practising against the network gets an honest measure of the run, never a lucky one:

- every random delay or range takes its typical value: identification timers, crew report delays, MANPAD wake times
  and hearing range, readiness delays, local radar sweep timing (each radar at its own fixed point of the 3-5 minute
  window, so they do not all sweep at once);
- return-size estimates carry no noise;
- every crew report is made and delivered;
- a report's position is off by its typical error in a fixed direction per post and report (deterministic, not
  perfect);
- listening stations catch every radar on every look, with each bearing off by its typical error in a fixed direction.

DCS's own randomness stays: whether DCS's radars detect a target, missile hits, and AAA fire. Medusa writes
`DEBRIEF|...|ev=TRAINING_MODE|on=true` at start so the debrief shows the run was a training run.

```lua
doctrine = { TrainingMode = true }
```

See [examples/bke-training-config.lua](../examples/bke-training-config.lua).

## In the logs

| Where | Line |
|---|---|
| INFO log | `crew roster of network <name>: ...` at start |
| INFO log | `network <name> readiness <from> -> <to> (<why>)` and `network <name>: word spreads (<why>), ALERTED in <n> s` |
| INFO log | `observer report not made: ...` when a crew does not get its report out |
| [Debrief log](debrief-log.md) | `ev=READINESS`, `ev=CREW_ROSTER`, `ev=REPORT_NOT_MADE`, `ev=REPORT_LOST`, `ev=REPORT_DELIVERED` (with `load=`), `ev=TRAINING_MODE` |
