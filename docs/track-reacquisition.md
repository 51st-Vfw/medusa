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

A track the radars have not seen for `TrackMemorySec` (a [configuration](configuration.md) field, default 30 s) is
dropped from the picture and kept as a lost track for re-acquisition. Lost tracks are searched within 50 km of a new
contact; a fast mover lost for a minute or more is too vague to carry anything.

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
| Confirmed ARM label | Only across gaps of 20 s or less, and only while the contact is still fast enough to be that ARM (it keeps at least 60% of its speed). With the default `TrackMemorySec` of 30 s a track is not lost until 30 s have passed, so **a confirmed ARM's label does not carry over to a re-acquired track**. Its HARM score starts again from zero and the new track is judged on its own flight |
| A [released store](released-stores.md)'s hold | On a sure re-acquisition |
| [Fire-hold](decoys.md#fire-discipline) count of a decoy | Always |

A small return alone does not make a lost track a weapon's: a stealthy jet returns less than an ARM.

When several lost tracks fit about equally well, the contact gets only the label they all share, at its weakest (all
probable decoys, or all confirmed ARMs; a suspected-decoy label only when a lost track of another kind fits nearly as
well), and otherwise starts fresh.

## How well it works

In test scenarios (replays of recorded DCS flights) with every contact dropped at once, no jet took an ARM's label and
98% of decoys came back as probable decoys.

## In the logs

INFO lines `re-acquired track <id> as new contact <id> (gap, score, carried: ...)` when a lost track is continued,
and `re-acquisition refused ...` or `re-acquisition tie ...` when several lost tracks fit about equally well. A
re-acquired track keeps its first sensor, so no second `FIRST_DETECTION` or `IDENTIFIED` line is written to the
[debrief log](debrief-log.md).
