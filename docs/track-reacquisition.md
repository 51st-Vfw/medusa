# [BKE] Track re-acquisition

Radars lose contacts: terrain masks a low flyer, a radar shuts down, a jammer or a notch hides an aircraft for a
while. When the contact shows up again, the network has to decide whether it is the same aircraft (or missile, or
decoy) it lost, and so whether it keeps what it already knew about it.

Medusa 1.6.0 decides by DCS object: a lost track is picked back up when the *same DCS object* is seen again near its
old position (within 5 km, within 120 s). That is knowledge no radar has. BKE decides from evidence, the way an
operator would: a new contact that is **where the lost track should be by now, flying as it should**, continues that
track, whatever DCS object it is. A contact that comes back somewhere else is a new track.

Doctrine `EvidenceReacquisition` (default `true`). Off: re-association by DCS object, as in Medusa 1.6.0.

## When a track counts as lost

A track counts as lost to new contacts in two ways:

- **A confirmed ARM silent for two looks.** A confirmed anti-radiation missile (ARM) track (with no aircraft evidence)
  that has missed two of its radar looks in a row (twice the time between its last two looks, and at least 4 s) is lost
  to new contacts while it is still in the picture: after 4 s on a HOT engagement radar refreshing every 2 s, 10 s on a
  SAM acquisition radar (5 s). Looks come at the fastest covering radar's rate, so the slowest radar still covering the
  contact must have missed two of its own looks too: an ARM whose SAM radar shuts down while an early-warning radar (10
  s) still detects it waits until that radar has missed two looks (20 s), and a second ARM of the salvo first seen
  beside it is a new track. Every detection counts, also one that brought no report because another radar had just
  looked, and one made after the ARM was lost: a radar that detects it again keeps it from new contacts first reported
  after that detection (radars are polled in turn, so within one poll cycle, about 1 s with 30 radar groups, a contact
  reported first can still take it). A radar that has not detected the contact for two of its intervals no longer
  covers it. The ARM stays in the picture until `TrackMemorySec` runs out, and when the radars report the contact they
  were holding again it carries on as before.
  When a new contact continues it, the old track leaves the picture. Past the longest gap its label crosses (20 s), a
  held ARM is no longer offered and waits for its own object: a contact continuing it would take its track without the
  label. So an ARM an early-warning radar covered is not handed on while held, and when twice the slowest covering
  radar's interval reaches `TrackMemorySec` it waits to be dropped. Any other track (a jet, a decoy) waits to be
  dropped. A jet comes back as itself at its radars' next look, and a store it releases meanwhile is linked to it as its
  carrier or cued from it, never taken for the jet.
- **Dropped.** A track the radars have not seen for `TrackMemorySec` (a [configuration](configuration.md) field,
  default 30 s) is dropped from the picture and kept as a lost track for two minutes.

Lost tracks are searched within 50 km of a new contact; a fast mover lost for a minute or more is too vague to carry
anything.

## The fit

For each lost track, the network predicts where it should be now from its last position, speed and heading, and how
it was turning or accelerating in its last seconds (at most 3 g, carried forward at most 20 s). The allowance grows
with the length of the gap and the speed of the contact (height counts double: radars measure it worst and aircraft
change it least). The new contact is scored against each prediction; it continues the best-fitting lost track when
that fit is good enough and clearly better (twice the score) than the next one.

A contact much faster than a lost aircraft it fits (120 m/s or more, heading within 90 degrees) is a weapon leaving
that aircraft, not the aircraft: a missile coming off a jet never takes over the jet's track.

## What carries over

The continued track keeps its id (the same display id in logs, metrics and the tactical display), its
identification (bandit, hostile) and what it already knew, as far as the fit allows:

| Knowledge | Carries over |
|---|---|
| Identification (bandit, hostile) | Always |
| Decoy label | On a close fit, and only when the contact has lost at least a glider's energy over the gap and the gap is within the decoy's remaining glide. On a looser fit a probable decoy comes back suspected, and a suspected decoy as an aircraft |
| Proof that it is an aircraft | On a close fit |
| Return size, launch cue, a crew's sighting of a weapon | Weakened when the fit is loose or the gap long. A crew's sighting of an aircraft does not carry over: a weapon that comes into view where a jet was lost must not inherit it |
| Confirmed ARM label | Only across gaps of 20 s or less, and only while the contact is still fast enough to be that ARM (it keeps at least 60% of its speed). Its HARM score starts again from zero, its "not attacking" window is paused over the gap, and it is not counted as a new ARM. An ARM held only by early-warning radars (10 s looks) is lost to new contacts after 20 s of silence, so its label does not carry over; across a longer gap the new track is judged on its own flight |
| A [released store](released-stores.md)'s hold | On a sure re-acquisition. The hold on a store seen too late to link (it falls like a bomb) is not carried: the new track rebuilds it from its own looks, as it does its HARM score |
| [Fire-hold](decoys.md#fire-discipline) count of a decoy | Always |

A small return alone does not make a lost track a weapon's: a stealthy jet returns less than an ARM. Nothing is seen
leaving a confirmed ARM that is silent for two looks (its last position is stale), so it gives no
[launch cue](harm-detection.md#launch-cues).

When several lost tracks fit about equally well, the contact gets only the label they all share, at its weakest (all
probable decoys, or all confirmed ARMs; a suspected-decoy label only when a lost track of another kind fits nearly as
well), and otherwise starts fresh.

## How well it works

In test scenarios (replays of recorded DCS flights) with every contact dropped at once, no jet took an ARM's label and
98% of decoys came back as probable decoys. With the default track memory and every contact coming back as another
DCS object after 5, 10 and 20 s of silence (2 s looks), 93%, 90% and 85% of confirmed ARMs came back confirmed (none
did before) and no jet or decoy took an ARM's label. No weapon first seen during the silence (87 new ARMs among them)
took a held jet's track, and 51 of those weapons got a launch cue from a jet that was still silent.

## In the logs

INFO lines `re-acquired track <id> as new contact <id> (gap, score, carried: ...)` when a lost track is continued,
and `re-acquisition refused ...` or `re-acquisition tie ...` when several lost tracks fit about equally well. A
re-acquired track keeps its first sensor, so no second `FIRST_DETECTION` or `IDENTIFIED` line is written to the
[debrief log](debrief-log.md).
