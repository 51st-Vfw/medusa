# [BKE] HARM detection and contact evidence

Medusa recognizes anti-radiation missiles (ARMs, "HARMs") from how they fly, not from what DCS says they are, and lets
threatened batteries shut down or defend themselves. The official
[HARM Detection and Defense](https://medusa.airdefense.systems/guides/harm-detection-and-defense/) guide explains the
method and the defense strategies (`HARMResponse` and the other fields in [Doctrine
fields](doctrine-fields.md#harm-defense)). BKE keeps the method and the defenses, and changes how fast and on what
evidence a contact is called an ARM.

Everything on this page is always on, except the per-radar refresh rates, which doctrine `ScanUpdateRateSec` sets.

## In short

| | Medusa 1.6.0 | BKE |
|---|---|---|
| Looks before a contact can be called an ARM | ~~25~~ | 5 |
| Wait after a track is first seen | ~~10 s~~ | none |
| Time to call a HARM inbound on a HOT S-300 or Tor | about 125 s (25 looks at 5 s) | about 10 s (5 looks at 2 s) |
| Time to call a HARM seen only by early-warning radars | about 125 s | about 50 s (5 looks at 10 s) |
| Track refresh | ~~5 s for every radar~~ | 10 s early-warning, 5 s SAM search, 2 s HOT engagement radar |
| Score per look / in total | ~~at most 5~~ / ~~unbounded~~ | at most 4 / within ±20 |
| Return size, launch cues, crew sightings | not used | used as evidence |
| A confirmed ARM that slows down | can be relabeled an aircraft | stays an ARM while it attacks a site |
| Finding the aircraft that fired it | needs a track point within ~~3 s~~ | within 12 s, dead-reckoned |
| A bomb dropped near a radar | can be confirmed as an ARM | held back ([Released stores](released-stores.md)) |

## Faster classification

Each radar look at a contact faster than 50 m/s adds to a score from eight features of its flight (speed, dive,
turn, acceleration, how close it will pass a battery and how fast that closes, range rate, climb rate). A score above
the confirm threshold makes it a confirmed ARM; the network then shuts down or defends the batteries it threatens.

Medusa 1.6.0 needed 25 looks and a track at least 10 s old before it would decide. At 5 s looks that is about two
minutes, which is longer than most HARM flights: many were called after impact. BKE needs 5 looks and no age, so the
HARM response and point defense act while the missile is still in the air. A new or re-acquired track also keeps its
first sighting in its history, so its evaluation starts one look sooner.

The score is bounded: one look counts at most 4 (stock 5) and the total stays within ±20. A jet tracked for many
minutes can no longer bank so much "aircraft" evidence that a real ARM-like run never confirms, and a missile cannot
bank unlimited ARM evidence either.

## Radars refresh at their own pace

How often a track is refreshed now depends on the radar that holds it:

| Kind (`ScanUpdateRateSec` key) | Radar | Default |
|---|---|---|
| `EWR` | Early-warning and GCI radars (one look per antenna turn) | 10 s |
| `SAM_SEARCH` | A SAM's acquisition radar, and an engagement radar that tracks one target | 5 s |
| `SAM_TRACK` | A HOT multi-target engagement radar (a system in `HarmCapableSystems`: S-300, Tor, Pantsir, Patriot, NASAMS and any you add) | 2 s |

AWACS, airborne datalink and ship radars use `PerTrackScanUpdateRate` (5 s). A contact held by several radars is
refreshed at the pace of the fastest one, so a contact over a HOT S-300 is sharp while one seen only by a distant
early-warning radar is coarse, as it should be.

```lua
doctrine = {
	-- Stock Medusa 1.6.0 behavior: one rate for every radar
	ScanUpdateRateSec = { EWR = 5, SAM_SEARCH = 5, SAM_TRACK = 5 },
}
```

Each rate is capped at half of `TrackMemorySec` (15 s at the default 30 s): a track must be refreshed at least twice
before it is dropped as stale. A capped rate is logged as an error. A doctrine that sets `PerTrackScanUpdateRate`
explicitly gets that rate for every kind `ScanUpdateRateSec` does not name.

## Contact evidence

BKE gives the network three more kinds of evidence, each one something a real radar crew could have. None of them
uses DCS's own knowledge of what the object is.

### Size of the return

Each radar look gives a noisy estimate of how big the contact looks on radar: its radar cross-section from DCS, then
aspect (a contact seen side-on returns about five times more than nose-on), a fixed offset per airframe, scan-to-scan
flicker, and a measurement error that grows with range and is coarser on early-warning radars than on engagement
radars. The track averages its looks into a size estimate and calls it "small" (missile-sized) or "aircraft-sized"
only when it is confident.

- A small, ARM-like contact reaches the threshold sooner: a confident small return adds at most the "suspect"
  threshold to the score, and only once the flight alone already looks ARM-like. A contact flying like a jet never
  becomes an ARM on size alone.
- A contact the radars confidently see as aircraft-sized is never confirmed as an ARM, however it dives at a radar (at
  most a probable one). In test scenarios (simulated runs of 10 looks) an ARM seen only beam-on is called
  aircraft-sized in about 0.2-0.3% of runs. These figures come from simulated runs, not DCS flights.

**Stealth is meant to be hard.** A low-observable aircraft returns less than an ARM. Size alone never turns it into a
missile or confirms one; it has to fly like an ARM too. When stealth aircraft arrive in DCS they will be harder to
classify, as they should be.

### Launch cues

A new contact that appears within 6 km of a track at least 10 s old (and not a confirmed ARM silent for two of its looks) and pulls
away from it at more than 120 m/s is what an operator sees when a missile leaves an aircraft. The new track is marked as
launched from the older one. Every ARM in DCS that was tested shows this (AGM-88, AGM-45, AGM-122, ALARM, Kh-25MP,
Kh-31P, Kh-58); gliding and jet-powered weapons (TALD, JSOW, SLAM-ER, cruise missiles) do not, and are left to the other
evidence.

### Crews name what they see close up

Within 10 km by day (less at night and in poor visibility), a crew that DCS says has identified a contact reports it
as an aircraft, a helicopter or a weapon. A crew's sighting of an aircraft counts as strongly against an ARM call as a
confident aircraft-sized return. No extra query is made to DCS; long-range type recognition by search radars is not
used.

## An ARM stays an ARM

In Medusa 1.6.0 a confirmed ARM could lose its label as it slowed in its terminal dive; a Kh-58 or ALARM could be
relabeled an aircraft seconds before it hit. In BKE a confirmed ARM keeps its label until its flight shows it is not
attacking a SAM site:

- it is "attacking" while, over the ground, it closes on some battery (emitting or shut down) faster than 20 m/s, will
  pass within 2.5 km of it, and will arrive within 240 s (150 s once it is slower than 400 m/s over the ground);
- the label clears after about 8 s (and at least 2 looks) of not attacking any site, or of flying slower than 50 m/s,
  or 6 minutes after confirmation.

A jet that dived like an ARM and was confirmed in its dive clears 10-15 s after it pulls off.

## Finding the shooter

When an ARM is confirmed, the network looks for the aircraft that fired it: the track that was where the ARM was
first seen, at that moment. That aircraft is marked hostile. Medusa 1.6.0 needed a point in the aircraft's track
history within 3 s of the ARM's first sighting, which missed about half the launchers seen only by early-warning radars
(10 s looks). BKE uses the nearest history point within 12 s, carried forward to that moment with the aircraft's
velocity.

## What else sees the result

- [Alert zones](alert-zones.md) with `MedusaThreats = "arms"` count confirmed ARMs; `munitions` also counts contacts
  with a clearly small return that the HARM check judges a possible ARM.
- The [debrief log](debrief-log.md) has an `ARM_CONFIRMED` line for each confirmed ARM, and an `ARM_BLOCKED` line when
  an ARM-like contact was held back (by its aircraft-sized return, because it is a released store, or because it falls
  like a bomb that lands away from every battery).
- HARM checks scan one list of emitting batteries per phase instead of a grid search per track, about five times
  faster with 300 tracks.

## Log lines (INFO)

| Line | When |
|---|---|
| `track <id> classified as HARM (ARM CONFIRMED, LLR=<score>)` | A contact is confirmed as an ARM |
| `track <id> HARM classification cleared (LLR=<score>)` | A confirmed ARM's label clears |
| `track <id> flies like an ARM (LLR=<score>) but is not confirmed: <why>` | A confirmation was held back (once per track and reason) |
| `track <id> flagged hostile action (launched HARM <id>, dist=<m>m)` | The shooter was found |
