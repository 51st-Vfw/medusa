# [BKE] ESM listening stations

A listening station is a passive radio direction finder: it hears an aircraft's radar and measures the direction it
comes from. Real systems of this kind (Kolchuga, Ramona, Tamara and their crews) are part of many air defences; they
give nothing away themselves. **A jet with its radar off is invisible to them: EMCON discipline pays.**

Doctrine `PassiveDetection` (default `true`) switches them; doctrine `ESM` holds their numbers. Off: the stations are
ordinary ground crews (they still look out and report like any crew).

## Setting one up

Name a ground group with the `esm` or `elint` role token after the network prefix, like other role
tokens, for example `iads.north.esm.ridge-1` or `iads.elint-2`. Put a vehicle or two in it (trucks, a command vehicle):
the group is one station, standing where its first living unit stands, and leaves the network when its last unit
dies. Give it nothing else to do: no missiles, no search radar (a group with those is a SAM site or a radar).
Its crew also looks out like any ground crew ([observer reports](local-radars-and-observers.md#observer-reports)); add
`obs` to the name too to make it a trained observer post as well. A further token can be added with the `Roles.ESM` setting.

## Where to put them

Bearings are only worth something when they cross: place at least three stations 30-60 km
apart, not in a line, with a clear view towards where the enemy flies, on high ground if you have it (the antenna is
10 m up; the radio horizon grows with height). Two stations give fixes only while one aircraft of a kind is radiating
in their sector; the third settles which crossing is real.

## What a station hears

- Only a hostile aircraft whose radar DCS reports as transmitting. An aircraft with its radar off, or held silent by
  its EMCON option, is not there for it. A jammer is not heard either: DCS does not tell a script that an aircraft is
  jamming. Whether DCS reports a player's aircraft radar to a script has not been checked yet: treat stations as
  hearing AI aircraft for certain and players possibly not.
- Within the radio horizon over a 4/3 earth, 4.12 km x (square root of the antenna height + square root of the
  aircraft's height, in metres): a 10 m mast hears an aircraft at 100 m out to 54 km, at 6000 m out to 330 km. Then
  terrain line of sight from the antenna.
- In the radar's main beam out to `ESM.MaxRangeKm` (250 km): ahead of a searching fighter (within 60 degrees of its
  nose); along the line to the target a fighter's radar is locked on (within 5 degrees); an early-warning aircraft
  (AWACS) all round, out to `ESM.AewMaxRangeKm` (400 km, the horizon usually ends it first). A locked radar still
  sweeps its sector part of the time (track-while-scan, short searches), so a station ahead of it but off the locked
  line hears it on 30% of looks. Outside the main beam only the sidelobes reach the station, a thousand times weaker,
  out to `ESM.SidelobeRangeKm` (40 km), caught on 40% of looks with half again the bearing error. The station hears a
  radar one way while the radar's own echo must go and come back, so a station hears a fighter far beyond the range
  at which that fighter's radar could see anything.
- A sweeping fighter's beam crosses the station on 70% of looks, an AWACS's rotating antenna on 95%, a beam held
  towards the station on every look.

## What a station measures

A station listens every `ESM.LookIntervalSec` (10 s). What it measures is a **bearing** with an error of
`ESM.BearingSigmaDeg` (2 degrees, one standard deviation), twice that when the aircraft is less than 1 degree above
the horizon (ground reflections; the elevation allows for the earth's curve), and a coarse class from the aircraft
type: early-warning radar (AWACS), fire-control radar (fighters, interceptors, attack aircraft, bombers, attack
helicopters) or other airborne radar (transports, tankers and anything else with a radar). Nothing names the aircraft.
Two radars of one class within two bearing errors of each other (a pair in formation) are one bearing. A station
sorts out at most 8 radars of one class at a time; more and that class is saturated there: the extra bearings are
lost, and the station's bearings of that class can no longer make two-station fixes.

## Matching bearings into fixes

The network matches bearings of one class from different stations taken in the same look, from the
bearings alone. A crossing must be in front of both stations (a bearing is a ray, not a line), within reach, and at an
angle of at least 15 degrees; its error grows with range and with a shallow crossing (range x bearing error / sine
of the crossing angle: two stations 100 km from a fighter, crossing at 90 degrees, about 5 km).

- A crossing is **confirmed** when a third station's bearing passes through it: the three bearings' least-squares
  point misses each bearing by little enough that the sum of the squared misses, each in its own bearing errors (the
  chi-square), is at most 6.6. That is the 99% point for three bearings fixing two coordinates, so a true crossing
  passes 99 times in 100 and a ghost only when the third bearing happens to lie within about 2.6 errors of it.
- Confirmed crossings become fixes best fit first, and only when no other explanation of their bearings is about as
  good: another plausible three-bearing crossing (chi-square up to 11) that gives one of the bearings to a different
  aircraft, or, when the fix itself fits only so-so (chi-square 2.4 or more, the cost of one station having missed a
  radar), a plain crossing of two of its bearings with another bearing. Every further station's bearing that fits
  joins the fix (six stations hearing one radar make one fix, not two), and a poor fit widens the reported error.
- A crossing of only two bearings is a fix when neither bearing could cross anything else (every other unused bearing
  of that class, at any station, counts against it, crossing or not, as does a saturated station). Even then it is
  trusted only when the next look gives a two-station fix of that class in the same place (within three combined
  errors plus the distance a jet flies in between); seen once, it is evidence only.
- Everything else stays **ambiguous**: with two fighters in a sector, two stations see four crossings, two of them
  where no aircraft is, and the network cannot tell which. It then knows a radar of that class is out there and roughly
  in which direction, but not where.

In test scenarios (a simulation of the matching), with three stations 60 km apart and fighters scattered ahead of them
(each heard on 70% of looks, 2-degree error), a fix good enough to cue lies more than 20 km from every fighter about 1%
of the time with one fighter, 4% with two, 7-8% with three or four: what remains are crossings that are geometrically
indistinguishable from a real aircraft. More stations, spread wider, lower it.

## What a fix does

A fix reaches the network 2-6 s after the look (data link; at most 8 wait at once, further ones are dropped and
logged). If its error is 10 km or less it is treated like a hostile observer report: MANPAD crews near it are woken,
gun crews cued, local cueing radars covering it come up, and a dark short- or medium-range SAM battery whose
engagement range plus 10 km plus twice the fix error covers it comes up WARM for two minutes, under the same rules (no
wake where the network already tracks something, under ROE HOLD, a HARM shutdown, crew suppression or a mission EMCON
policy for the role). The same 20 km area is not cued again for that class for 60 s (a coarser fix in the meantime does
not hold a good one back). A worse fix is evidence only. A fix is never a track, never a firing solution, never makes a
battery HOT.

**Readiness.** A fix on a fire-control radar, or fire-control radars heard on three looks within two minutes, is hostile
evidence: a SURPRISED network turns ALERTED after the usual word-spreads delay
([readiness](crews-and-readiness.md#readiness)). An early-warning radar alone never is
(an AWACS orbit is routine).

**Training mode.** In [training mode](crews-and-readiness.md#training-mode) every look catches the radar, and a
bearing is off by its typical error (0.8 of the standard deviation) in a direction fixed per station and 30-degree sector, so the same geometry gives the
same fix on every look.

## Server load

The work is spread over ticks so that no tick carries much of it: one tick reads the hostile radars (one DCS call per
hostile aircraft per look, shared by every station; only aircraft within reach of the stations' area count, at most
64 per look, taken in turn when there are more), then up to 32 radar checks per tick for each station, then the
crossings (up to 256 crossings and third-bearing fits per tick), then the fixes. The terrain check runs only for the
pairs that pass every cheaper test. The station list is refreshed between looks only. Ten stations and 64 radars take
about 60 ticks per look at well under 1 ms each on average.

## Doctrine

| Field | Default | Range | Effect |
|---|---|---|---|
| `PassiveDetection` | `true` | | Off: listening stations hear nothing (their crews still look out as ground crews). Turning it off mid-mission also drops a look in progress and the fixes waiting to arrive |
| `ESM.MastHeightM` | 10 | 1-60 | Antenna height, metres |
| `ESM.MaxRangeKm` | 250 | 10-600 | Main-beam reach |
| `ESM.SidelobeRangeKm` | 40 | 1-100 | Sidelobe reach |
| `ESM.AewMaxRangeKm` | 400 | 10-600 | AWACS reach |
| `ESM.BearingSigmaDeg` | 2 | 0.1-15 | Bearing error, one standard deviation |
| `ESM.LookIntervalSec` | 10 | 2-120 | Seconds between looks |

```lua
doctrine = {
	PassiveDetection = true,
	ESM = { MastHeightM = 20, LookIntervalSec = 15 },
}
```

The `Roles.ESM` setting in [`MEDUSA_CONFIG`](configuration.md#roles) adds a further name token. See also
[examples/bke-ground-sensors-config.lua](../examples/bke-ground-sensors-config.lua).

## Log lines (INFO)

| Prefix | When |
|---|---|
| `listening station <group>: <n> crew units` / `listening station <group>: no crew left` | a station joins or leaves |
| `listening stations: <n> (<names>)` / `listening stations: 0 (none left)` | the network's stations, whenever the list changes |
| `esm fix: <class word> near (x, z) +-<n> km from <stations> (<how>), <what it caused>` | a fix reaches the network; class words `early-warning radar`, `fire-control radar`, `airborne radar`; how `<n>_station`, `2_station_repeat`, or `2_station_single` (seen once, evidence only); a fix worse than 10 km says `too coarse to cue` (each at most once per 20 km cell and class a minute) |
| `esm fix dropped: <n> fixes already waiting (<how>)` | more fixes than the data link queue holds (at most once a minute) |
| `esm fix wakes <group> WARM (from listening stations ...)` | a fix wakes a dark SAM |
| `esm ambiguous: <n> <class> bearings cross <n> ways (<n> fixes this look)` | bearings of a class that could not be matched up (at most once a minute per class) |
| `esm summary: ...` | every 2 minutes: stations, looks, radars heard of, pairs in range, terrain checks, bearings, saturated, fixes, ambiguous, cued, rested (area still resting), dropped, CPU time and worst tick |

Debrief events: `ESM_INTERCEPT`, `ESM_FIX`, `ESM_AMBIGUOUS` (fields in [Debrief log](debrief-log.md#listening-stations)).
