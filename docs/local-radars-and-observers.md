# [BKE] Local cueing radars and observer posts

Two layers of the air defense below the SAM network: small search radars that warn the guns and MANPADs around them,
and the crews of every ground group, who radio what they see or hear. Both are on by default and need nothing from the
mission maker beyond placing the units; observer posts need one name token.

## Local cueing radars

A search radar in a group without missile launchers whose reach is short (under 50 km against a fighter-sized target,
judged from the range DCS reports for the radar when Medusa probes it at start, not from a type list) is a **local
cueing radar**. The Dog Ear (DCS reports 23.4 km, a reach of about 35 km) is the typical one; the 1L13 or 55G6
early-warning radars are far beyond it and stay early-warning radars.

What it does:

- It is **dark** (radar off) unless it has a reason to be up:
  - a hostile aircraft in the network's picture within its reach plus 15 km;
  - a MANPAD or AAA crew it supports (the groups within its reach, its own included) is alerted;
  - an observer report it covers (below), for two minutes;
  - its own crew saw or heard an aircraft (local initiative, below), for two minutes.

  It stays up 60 s after its last reason (up to 70 s after a hostile leaves: a hostile found near a lit radar is
  looked for again only every 10 s). Up means WARM: radar on, weapons hold. A gun group's weapons are still
  released only by the network or by its own crew logic.
- When no other ground radar of the network reaches it (and the side has no airborne radar), it also **sweeps** on
  its own: 10-20 s every 3-5 minutes, at random, so a low flyer cannot cross a blind network unseen. A sweep is not
  held the extra 60 s. No sweeps under a mission EMCON of `MINIMIZE` for its role (`EWR` for a radar-only group,
  `AAA` for a gun group) or with doctrine `LocalRadarSweeps = false`.
- When up, it is polled at the SAM search rate (every 5 s), on its radar only: a MANPAD crew's eyes in the same group
  never become a radar track.
- Its detections cue the MANPAD and AAA crews in its reach: sleeping MANPAD crews within 10 km of the nearest aircraft
  it sees are woken, and independent gun crews there scan all round with better hearing for two minutes.

**Existing missions.** In Medusa 1.6.0 an unnamed lone Dog Ear was an always-on early-warning radar. In BKE it is dark
until needed, so with no other radar in the network it comes up only on a crew's sighting, an alerted crew it
supports, an observer report or its own periodic sweep. To keep it an always-on early-warning radar, put the `ewr`
token in its group name (for example `iads.north.ewr.dogear-1`). This is the one BKE change that can alter an existing
mission ([Differences from Medusa 1.6.0](differences-from-medusa-1.6.0.md)).

A cueing radar is not an early-warning radar. Doctrine `SAMAsEWR = "WHEN_NO_EWR"` (the default) turns long- and
medium-range SAM search radars into early-warning radars when the network has no early-warning radar, so a network
whose only radar is a lone, unnamed Dog Ear uses its SAMs as early-warning radars, as stock Medusa does for a network
without one. A Dog Ear named `ewr`, an early-warning or GCI radar, or an AWACS keeps the SAMs as SAMs.

Group set-ups (any group Medusa manages; no role token needed):

| Group | What Medusa makes of it |
|---|---|
| Dog Ear alone | a local cueing radar (a sensor group that is dark until needed) |
| Dog Ear + Shilka (or other guns) | an AAA battery directed by its radar; the radar is the local cueing radar. In Medusa 1.6.0 the Shilka was left unmanaged when there were fewer than two guns per radar |
| Dog Ear + Igla (MANPAD teams) | a MANPAD battery; the radar is the local cueing radar and cues the teams. In Medusa 1.6.0 the teams were never cued by it and the radar was never polled |
| 1L13 / 55G6 alone | an early-warning radar, as in Medusa 1.6.0 |
| A radar named with the `ewr` or `gci` token | an early-warning radar, as in Medusa 1.6.0, whatever its reach |

A group with a radar and guns waits for the radar's reach before it is classified (a few seconds after start). If the
reach cannot be probed, the group is classified as in Medusa 1.6.0.

Doctrine `LocalCueingRadars = false` turns this off: short-reach radars are always-on early-warning radars again and
radar + gun groups are classified by unit count, as in Medusa 1.6.0.

## Observer reports

The crews of managed ground groups (SAM batteries, AAA and MANPAD groups, ground radar groups) and **observer posts**
look for aircraft and radio what they see or hear.

An observer post is any ground group (infantry, a lookout vehicle) named with the observer role token after the
network prefix, like other role tokens: `obs` or `observer`, for example `iads.north.obs.hill-412`. A post leaves the
network when its last unit dies. A further token can be added with the `Roles.OBSERVER` setting.

What a crew can do:

- **See** an aircraft within 8 km by day, a quarter of that at night (DCS's night), with terrain line of sight from
  eye height. The mission's visibility, fog (the fog in effect at the time) and dust shorten it further.
- **Tell friend from foe** only by sight within a quarter of the sight range (2 km by day, DCS's own recognition
  ratio). An aircraft seen closer is reported hostile, or not at all when it is the crew's own side; anything heard
  or seen further off is reported **unidentified**, own aircraft included.
- **Hear** a low aircraft (under 1000 m above the crew) within 3 km, whatever the terrain in between.
- Name its type only when it is identified and DCS itself has the group knowing the type.

The same night and weather scaling applies to the sight recognition a SAM crew uses on its own radar contacts.

The network spends 4 looks a second on its crews, at most one per tick, round-robin (50 crews: each looks every 12.5 s).
A crew that reported rests a minute (with crew factors on, so does a crew that did not get its report out).

A report is coarse: position to about 1 km (seen) or 2.5 km (heard), rounded to 500 m; an 8-point heading (seen only);
low, medium or high; fast or slow; jet or helicopter; one, two or several; hostile or unidentified; a type only as
above. With doctrine `CrewFactors = false` it arrives after a radio delay of
30-90 s, 1.5 times longer at night, plus 10 s for each report already waiting on the net (up to 2 more minutes). 10%
of reports are lost by day, 20% at night, plus 2% for each report waiting (at most half); with 32 waiting, new reports
are lost.

When a report arrives:

- MANPAD crews within 10 km of the reported position are woken, independent gun crews there scan all round;
- local cueing radars covering it come up for two minutes;
- if it reports a hostile, a dark short- or medium-range SAM battery with a search radar whose engagement range plus
  10 km covers it comes up WARM (radar on, weapons hold) for two minutes, unless the network already holds a track
  within 15 km of the reported position (the network engages what it tracks) or the mission sets an EMCON policy for
  the battery's role (an ambush site set to `MINIMIZE` stays dark; the built-in defaults do not count). Long-range
  batteries are never woken by a report. An unidentified report wakes no SAM. Its own radar must then find the aircraft
  before the network engages: a report is never a track, never a firing solution, never makes a battery HOT, and alert
  zones do not count reports. Its radar feeds the network picture while WARM only with doctrine `BatteryTargetDatalink`
  (default on).

No SAM is woken under ROE HOLD, a HARM shutdown or crew suppression.

**Local initiative:** a crew that sees or hears an aircraft itself does not wait for the radio: a group with a local
cueing radar brings it up; a dark SAM battery whose crew sees a hostile comes up WARM at once (two minutes), under the
same rules as a report. Not under ROE HOLD, a HARM shutdown
or crew suppression. Doctrine `LocalInitiative = false` turns this off (crews still report). The crews' looks are part
of observer reports, so with `ObserverReports = false` there is no local initiative either.

Doctrine `ObserverReports = false` turns observer looks and reports off.

**Crew factors** (doctrine `CrewFactors`, on by default) replace the fixed delay and losses above: the group's mission
editor skill and the network's readiness decide whether the crew calls it in at all, how fast and how precisely, and
readiness and the net load decide whether the call reaches the right people. The figures are in
[Crews, readiness and training mode](crews-and-readiness.md).

**Set your crews' skill.** A crew of Average skill, the Mission Editor's default for ground units, gets a report out
about one time in four. So do units spawned during the mission and units set to Random or Player skill (they count as
`CrewFactorsDefaultSkill`, which follows `CrewSuppression.DefaultCrewSkill`, Average, unless set). Excellent crews
report almost every time.

Observer posts are trained observers: they count one skill level higher (Average reports as Good; Excellent stays),
keep looking at their full rate when the network is SURPRISED, and get 80% of their reports through under surprise
(other crews 60%). Each network logs one `crew roster` line at start: posts and crews by skill, and how many took the
default skill.

In [training mode](crews-and-readiness.md#training-mode) (doctrine `TrainingMode`) a report's position is off by the
typical error, half its bound in each direction, in a fixed direction per post and report, never the exact position;
local radar sweeps keep their 3-5 minute rhythm at a fixed point per radar, so the network's radars do not all sweep
together.

## Doctrine

| Field | Default | Off means |
|---|---|---|
| `LocalCueingRadars` | `true` | short-reach radars are always-on early-warning radars; radar + gun groups classified by unit count, as in Medusa 1.6.0 |
| `ObserverReports` | `true` | no observer looks, no reports |
| `LocalInitiative` | `true` | a crew's own sighting brings nothing up; only the network or a report does (needs `ObserverReports` on) |
| `LocalRadarSweeps` | `true` | a local cueing radar no other radar covers stays dark until it has a reason, with no periodic sweep |

Full details of each field: [Doctrine fields](doctrine-fields.md#bke-ground-sensors).

## Log lines (INFO)

| Prefix | When |
|---|---|
| `local radar <group>: reach <n> km, ...` | a radar is found to be a local cueing radar |
| `local radar <group> on (<reason>)` / `off (<reason>)` | it comes up or goes dark; reasons: `threat near`, `supported units alerted`, `observer report`, `local initiative`, `periodic sweep`, `no threat near`, `held down`, `dark until a threat is near` |
| `deferred: '<group>' (radar with guns) waits for its radar's reach` | a radar + gun group waits for the probe |
| `observer post <group>: <n> crew units` / `observer post <group>: no crew left` | a post joins or leaves |
| `observer report sent: <group> saw\|heard ...` | a crew radios a report, with its delay (for example `saw one hostile jet`, `heard two unidentified helicopters`) |
| `observer report not made: <group> (<skill> crew, <readiness>) saw a ...` | with crew factors on, a crew did not get a report out |
| `observer report received: from <group> after <n> s: ...` | a report arrives |
| `observer report lost: from <group> (...)` | a report never arrives (`not heard on the net`, `radio net saturated`) |
| `observer report wakes <group> WARM (report from <group>)` | a report wakes a dark SAM |
| `local initiative: <group> comes up WARM (own crew saw\|heard a ...)` / `cues its local radar (...)` | a crew acts on its own sighting |

Debrief events: `REPORT_NOT_MADE`, `REPORT_LOST`, `REPORT_DELIVERED`, `LOCAL_RADAR_UP`, `CREW_ROSTER` and `WAKE`
(see [Debrief log](debrief-log.md)).
