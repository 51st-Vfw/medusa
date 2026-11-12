# [BKE] Released stores: a bomb is not a missile

A bomb or glide bomb released at a SAM site falls fast and steeply towards a radar, which is what an anti-radiation
missile does too. In Medusa 1.6.0 such stores were sometimes confirmed as ARMs: FAB-250s from bomb sticks and GBU-31s
were. The network then shut down radars or spent point-defence missiles on bombs. BKE tells the two apart by physics:
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

- **Point defence** still engages an unpowered store whose predicted impact is within 3 km of the site it protects.
- **Alert zones** with `MedusaThreats = "munitions"` still count it as a munition (it is suspect or probable).
- The hold carries across a sure [re-acquisition](track-reacquisition.md) of the store.

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
missed, also with every ARM first seen 20 or 40 s late.

The hold needs two things: the network must know the aircraft is an aircraft, and it must see the store within about
10 s of its release. A store first seen long after release is judged by its flight alone, as in Medusa 1.6.0.

## In the logs

| Where | Line |
|---|---|
| INFO log | `track <id> flies like an ARM (LLR=<score>) but is not confirmed: it dropped off an aircraft and has no motor` (or `it appeared beside an aircraft; watching for a motor`) |
| [Debrief log](debrief-log.md) | `ev=ARM_BLOCKED` with `why=unpowered` or `why=window` (and `why=size` for an aircraft-sized return), once per track and reason |
