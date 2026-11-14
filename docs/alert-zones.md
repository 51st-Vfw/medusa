# [BKE] Alert zones: react to what the IADS sees, with editor triggers only

An alert zone is an ordinary mission-editor trigger zone (circle or quad) with a few properties. Every few seconds
Medusa writes to a flag how many hostile contacts the zone's side **tracks by radar** inside the zone. Use that flag in
normal editor triggers: activate a late-activated alert flight, push an AI task, play a message. Medusa itself never
tasks aircraft.

Unlike the editor's own "unit in zone" condition, which sees every aircraft, an alert zone only counts what Medusa's
radars actually hold: a flight hidden by terrain or flying below radar cover, or one that arrives after the
early-warning radar was destroyed, is not counted until a radar picks it up.

## Set-up

1. Draw a trigger zone.
2. In the zone's properties add `MedusaFlag` with a flag name or number, for example `north`.
3. Add triggers that read the flag, for example:
   - ONCE, FLAG IS MORE `north` 0 → GROUP ACTIVATE (alert pair)
   - ONCE, FLAG IS MORE `north` 3 → GROUP ACTIVATE (second alert flight)

## Properties

| Property | Values | Default | Meaning |
|---|---|---|---|
| `MedusaFlag` | flag name or number | (none) | The flag Medusa writes the contact count to. A zone needs `MedusaFlag`, `MedusaLosses` or both |
| `MedusaLosses` | flag name or number | (none) | A second flag: how many of this side's air-defense sites have been knocked out inside the zone so far (see below) |
| `MedusaThreats` | `aircraft`, `arms`, `munitions`, or a comma- or space-separated list | `aircraft` | What to count. `aircraft`: tracks judged aircraft (a contact must be tracked 10 s first, so a missile just fired is not counted as an aircraft). `arms`: tracks confirmed as anti-radiation missiles. `munitions`: other weapons as well: missiles the radars saw leave an aircraft, contacts with a clearly missile-sized radar return that the network also judges a possible anti-radiation missile, and contacts a crew saw as a weapon within sight range (10 km). A contact the radars saw leave an aircraft never counts as an aircraft, whatever its speed, unless its return is clearly aircraft-sized; a fast jet (a MiG-31 at Mach 2.3) still counts. Return size and speed never make a contact a weapon on their own: a stealthy aircraft returns less than a missile and still counts as an aircraft, even when supersonic. TALD decoys return like a fighter and count as aircraft until the network judges one a probable decoy (about 90 s of straight, steadily falling energy, sooner when missiles fired at it drew no reaction) or a crew sees one within 10 km; from then on they count as munitions |
| `MedusaAlt` | `low`, `medium`, `high`, `any` | `any` | Height above ground: low below 1000 m, high above 6000 m, medium between |
| `MedusaLinger` | seconds, `30` or `30s` | 30 | How long a contact keeps counting after it leaves the zone or after the network stops holding its track (a track is held while a radar has seen it in the last 15 s, so a slowly turning radar does not make the count flicker). Stops the flag flickering when a track drops out for a moment. `0` drops it at the next check |
| `MedusaSide` | `red`, `blue` | the side running Medusa | Whose radar picture to count. Needed only when both coalitions run Medusa |

## What the flag holds

- The number of contacts in the zone now, plus those still lingering. It is not a running total: it goes down again.
- Each zone is checked every 5 seconds (the zones are spread over those 5 seconds, and a crowded zone over several
  ticks); the flag is written only when the number changes.
- Several zones may name the same flag: the flag then holds their sum (one alert covering several areas).
- One aircraft held by two networks of the same side counts once. Each aircraft counts once, even in close formation.
- `MedusaLosses` is the one running total: it only goes up. Each early-warning radar destroyed counts one; each SAM
  site counts one when its first radar is destroyed, or when the whole site is (whichever comes first); AAA, MANPAD
  and IR SAM groups count one when their last unit dies. A group counts once, however its units are managed. Use it for
  "the IADS in the north has lost two sites" triggers, for example FLAG IS MORE `northlost` 1.
- A zone with a property Medusa does not understand is ignored and the reason is written to dcs.log
  (`alert zone '<name>' ignored: ...`).
- A track counts as held while a radar has seen it in the last 15 s. That covers the default early-warning refresh of
  10 s; with `ScanUpdateRateSec.EWR` above 10 s, contacts seen only by early-warning radars drop out of "held" between
  looks and count through `MedusaLinger` instead (30 s by default, so the flag does not flicker).

Alert zones need no doctrine switch: only trigger zones that carry `MedusaFlag` or `MedusaLosses` are used. See
[examples/bke-alert-zones.lua](../examples/bke-alert-zones.lua) for a worked set-up.
