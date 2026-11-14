# [BKE] Released stores: a bomb is not a missile

A bomb or glide bomb released at a SAM site falls fast and steeply towards a radar, which is what an anti-radiation
missile does too. In Medusa 1.6.0 such stores were sometimes confirmed as ARMs: FAB-250s from bomb sticks and GBU-31s
were. The network then shut down radars or spent point-defense missiles on bombs. BKE tells the two apart by physics:
**an ARM has a motor, a bomb does not.** No weapon list is used.

This is always on; it has no doctrine switch.

## How it works

1. **Released just now.** When a new contact first appears, the network checks whether it is where a store released
   by an aircraft in the last few seconds would be: within 900 m of an aircraft, no more than 150 m above it, and
   within 150 m/s of its velocity. The aircraft must be known to be one (a confident aircraft-sized return or a crew
   sighting, see [contact evidence](harm-detection.md#contact-evidence)), tracked for at least 10 s and seen in the last
   15 s. A launch cue does not matter: a cue does not make a bomb powered.
2. **Watched for a motor.** The new contact's energy (height plus speed, as a height: h + v²/2g) is compared with the
   most the aircraft had in its last 30 s. Every ARM in DCS gains at least 15 km of it within 10 s of launch; no bomb or
   glide weapon gains more than 60 m.
   - If it rises more than 3 km above the aircraft's, it has a motor: it is judged like any other contact from then on.
   - After 3 looks over at least 10 s without such a rise, it has no motor: it is **unpowered** and is never confirmed
     as an ARM while it stays so.
3. **A later rise still counts.** An unpowered contact whose energy later rises by that much is powered after all,
   and is judged as in Medusa 1.6.0.

While a contact is watched or unpowered, its HARM score still runs: it can be a suspected or probable ARM, never a
confirmed one. A contact that would have been confirmed is held at probable.

## What still sees it

- **Point defense** still engages an unpowered store whose predicted impact is within 3 km of the site it protects.
- **Alert zones** with `MedusaThreats = "munitions"` still count it as a munition (it is suspect or probable).
- The hold carries across a sure [re-acquisition](track-reacquisition.md) of the store.

## A store seen too late to link

A store first seen long after its release (often 20 s or more, by then far below its aircraft) cannot be linked. It
is still not confirmed as an ARM while its own flight shows it falls like a bomb that cannot reach a radar:

1. **It falls like a bomb.** Between two looks, the network takes the contact's change of velocity less gravity and
   splits it into a part along its flight (thrust less drag) and a part across it (lift). A bomb has no lift (at most
   0.75 m/s²) and nothing pushes it forward (at most 0.5 m/s²). Three such looks in a row count. A look in a steep
   dive does not count either way (gravity across a near-vertical flight is under 3 m/s², too little to tell lift
   from none). A contact ever seen gaining 5 m/s² along its flight has a motor and is never held this way.
2. **It lands clear of every battery.** Its fall is carried on (gravity and the drag seen, in the doctrine's
   `BallisticSimStepSec` steps up to `BallisticSimMaxSec`) to the ground at the nearest active radar's height. It must
   land at least 3 km from every air-defense battery, including one whose radar has shut down (an ARM still lands
   there).
3. **An aircraft could have dropped it.** An aircraft (aircraft evidence as above, not an ARM) within 40 km had,
   in its last 30 s, at least the contact's energy height less 3 km. A store never has more energy than its carrier.

An ARM does not pass all three. After its motor burns out, an ARM in DCS can coast without lift (an AGM-45 Shrike
does), but it then lands near its radar; a lofted ARM (a Kh-58 climbing before its dive) also coasts, but has far more
energy than any aircraft near it. A guided bomb (a GBU-31, about 8 m/s² of lift) flies and is not held this way.

Like the hold above, this only stops a confirmation: the contact can still be a suspected or probable ARM. It lasts
only while the looks stay ballistic: one that shows lift or thrust ends it until three more such looks. It is judged
afresh after a re-acquisition, from the new track's own looks.

## When the aircraft was really an ARM

If the "aircraft" is itself later confirmed as an ARM, was tracked less than 60 s when the store appeared, and has since
lost its aircraft evidence (two ARMs fired together, one misjudged as an aircraft), the contacts linked to it are
judged on their own flight again. An older carrier, or one that still has aircraft evidence, frees nothing. A carrier
that was lost and re-acquired under a new track frees nothing either: its stores stay held (they can still be
probable ARMs).

## How well it works

In test scenarios, replaying recorded DCS flights through the network at 2, 5 and 10 s radar looks, false ARM
confirmations on FAB-250s and GBU-31s fell from 136, 86 and 22 to 12, 2 and 2; the ones left were stores first seen
13-40 s after release, too late to link to their aircraft. No ARM (351 flights of 7 types) was confirmed later or
missed, also with every ARM first seen 20 or 40 s late. These figures come from replays of recorded DCS test flights.

The hold needs two things: the network must know the aircraft is an aircraft, and it must see the store within about
10 s of its release. A store first seen long after release is judged by its flight alone: it is held only if it falls
like a bomb clear of every battery (above).

For stores seen too late, replays of the recorded DCS runs kept for this check (a smaller set: 284 ARM flights of 7
types, and the bombs, glide bombs and cruise missiles of the same runs) at 2, 5 and 10 s looks, every weapon first seen
1, 20 or 40 s after release: FAB-250s first seen 20 s late were confirmed as ARMs 40 and 8 times (2 and 5 s looks)
without the check and never with it. No ARM was confirmed later or missed. GBU-31s seen late are still sometimes
confirmed (7 to 23 times per setting): a guided bomb flies on its lift, as an ARM does, and nothing it shows a radar
crew sets it apart.

## In the logs

| Where | Line |
|---|---|
| INFO log | `track <id> flies like an ARM (LLR=<score>) but is not confirmed: it dropped off an aircraft and has no motor` (or `it appeared beside an aircraft; watching for a motor`, or `it falls like a bomb and will land clear of every battery`) |
| [Debrief log](debrief-log.md) | `ev=ARM_BLOCKED` with `why=unpowered`, `why=window` or `why=ballistic` (and `why=size` for an aircraft-sized return), once per track and reason |
