# [BKE] Decoys and fire discipline

An air-launched decoy such as the ADM-141 TALD returns like a fighter. Medusa 1.6.0 engages it like one, and the
decoy does its job: the SAMs empty their launchers into it. BKE gives the network a way to see through decoys over
time, using only what a radar operator could see, and keeps its long- and medium-range SAMs from wasting missiles on
them.

Four doctrine switches, all on by default:

| Switch | What it does |
|---|---|
| `DecoyAssessment` | Labels contacts that glide like a decoy. Off: no decoy labels, and the three switches below do nothing either |
| `ManageEngageAirWeapons` | Turns a battery's DCS "engage air weapons" option off while only decoys and known aircraft are in its reach |
| `DecoyFireDiscipline` | Turns that option off for 20 s when the battery's own radar locks a decoy or it fires at one. Needs `ManageEngageAirWeapons`: with that off it does nothing, and dcs.log says so |
| `DecoyTestShots` | Fires one missile at a lone suspected-decoy group and watches what it does |

The responses apply to very-long-, long- and medium-range SAM batteries. Short-range SAMs, SHORAD and point defence
keep engaging as in Medusa 1.6.0.

## Decoy assessment

The network watches every aircraft-sized contact in its picture for a **glide**: a straight leg (heading within
10 degrees) whose energy, height plus speed, keeps falling faster than any powered aircraft descends. The threshold is
a glide steeper than 1 in 14 at the contact's speed (and at least 5 m/s of energy height), so a jet descending at
1,500 ft/min never qualifies.

| Label | When | Effect |
|---|---|---|
| Suspected decoy | 60 s of such a glide | Counts half as much when targets are ranked |
| Probable decoy | 90 s of it, or sooner with the evidence below | Long- and medium-range SAMs no longer engage it or wake for it. Point defence still engages one whose glide is predicted to end at the site it protects. [Alert zones](alert-zones.md) count it as a munition, not an aircraft |

Evidence that brings the probable label sooner:

- **Unanswered launches.** When one of the network's own guided missiles ends a flight of at least 20 s, its target
  and every contact within 2 NM of it that did not react (no turn faster than standard rate, no climb or energy gain of
  100 m) gain 30 s (target) or 15 s (bystander) of glide evidence. An aircraft under fire reacts; a decoy cannot.
- **Seen as a weapon.** A crew that sees the contact within 10 km and DCS has it identified as a weapon adds 30 s.

The label clears **for good** on what no unpowered decoy can do: two looks in a row of an energy gain (thrust), a
sustained climb or a hard turn (over 3 degrees per second; decoys never turned more than about 1 degree per second in
the recorded flights, jets reach 10-20); 40 s of holding its energy; or still flying when any glide from where it was
labelled would be over. So a jet cannot fake it.

Radar refresh jitter (5.1 s or 10.3 s looks instead of 5 and 10) does not stop the assessment.

In test scenarios (replays of recorded DCS flights), 85% of TALDs became probable decoys, about 110 s after first sight,
and none of 95 jet flights, 12 JSOWs, 8 SLAM-ERs or 128 ARMs was labelled.

## Engage-air-weapons

DCS's "engage air weapons" option lets a SAM fire at missiles and bombs as well as aircraft. A decoy is a weapon to
DCS, so with the option on a SAM crew fires at decoys on its own, whatever Medusa assigns.

With `ManageEngageAirWeapons` on, while everything in a HOT battery's reach is a probable decoy or a known aircraft
(and at least one decoy), and none of its missiles is in flight at anything else, the battery's option is turned off.
It goes back on as soon as another contact appears, when the battery next goes HOT, or when the network stops.

- A missile the battery has in flight at a known aircraft does not keep the option on: in DCS turning it off only
  stops missiles guiding on weapons, not on aircraft.
- The option is never written within 2 s of the battery's last launch: in DCS a write a few hundredths of a second
  after a launch ended that missile, even one fired at an aircraft. A write kept waiting 10 s by ripple fire is logged.
- Up to 16 missiles in flight are followed per battery; when the list is full, one fired at an aircraft or a probable
  decoy is dropped first.
- **[BKE] change from Medusa 1.6.0:** stock Medusa turned the option on every time a battery went HOT, overriding the
  mission. BKE does not write it when a battery goes HOT. It turns it off only for its own decoy responses and back
  on afterwards, so a mission that set it off in the editor keeps it off until that battery's first decoy response.

## Fire discipline

When HARMs or other contacts that may be weapons are in reach, the option has to stay on, and then DCS's crews pick
the decoys too. Fire discipline handles that case:

- A HOT long- or medium-range battery whose own fire-control radar (tracking radar, TELAR or TLAR) is locked on a
  probable decoy, or that fires at one, turns the option off for **20 s**. In DCS an SA-11 then drops the lock and
  fires no missile at the decoy, and aircraft are still engaged. An SA-10's tracking radar does not show what the site
  will fire at next, so an SA-10's holds mostly start at its first shot at a decoy and some decoy shots remain.
- The radar comes back to the same decoy 10-22 s after the option is back on, so a battery holds **at most 3 times per
  decoy** (also after the decoy is re-acquired), then engages it.
- A hold starts when the option actually goes off: it waits while the battery has a missile in flight at a contact
  that may be a weapon, or has just launched. A salvo at a decoy counts once.
- A hold ends early once its decoy is no longer one. None during a test shot. At most **80 s of holds in any 2
  minutes** per battery.
- Anti-radiation missiles do not stop a hold: the HARM shutdown response and point defence deal with them.
- **Self-defence comes first.** A decoy whose glide is predicted to end within **3 km** of the battery (diving at it or
  gliding down onto it) is never held against, and keeps the option on: the battery defends itself as against a glide
  weapon. The predicted end is along its ground track, at the shorter of its energy glide and its present descent
  carried to the ground. A decoy that flies over the battery towards something behind it is held against.
- The fire-control radars are read at most every 2 s, and not when every decoy in reach has had its holds.

## Test shots

A HOT long- or medium-range battery that fires at a suspected-decoy group alone in its reach holds fire until that
missile's flight ends, so one missile tests the group instead of a salvo. A decoy cannot react; an aircraft that turns,
climbs or accelerates gives itself away, and an unanswered missile is evidence for the decoy label.

- No test shot when the group would pass inside the battery's minimum range before the flight ends plus 30 s, when the
  network holds no track of the target, with fewer than 4 missiles left, or at a group tested in the last 5 minutes.
- The hold ends early when another contact enters the battery's reach, when the target is no longer a suspected decoy,
  when its missile can no longer be followed, after 90 s, when the battery leaves HOT, or when the network stops.
- **Missiles lost under a hold.** Some SAMs lose guidance while their fire is held (in DCS the SA-11 does; SA-2, SA-10
  and Hawk missiles keep guiding). A test-shot missile that ends more than 2 km from a target the network still sees,
  and was not about to reach it (more than 8 s to go, or flying away), lost guidance. It gives no evidence, the group
  may be tested again by another battery, and no battery of the network with that launcher type makes test shots from
  then on: they engage normally. This is learned during the mission; there is no type list. A missile that ended far
  away but was about to arrive, whose target was not seen within 6 s of its last position, or whose target proved to be
  an aircraft, is judged neither way.

## In the logs

| Where | Line |
|---|---|
| INFO log | `decoy track <id> <from> -> <to> (<reason>; ...)` when a label changes |
| INFO log | lines starting `engage-air-weapons`, `fire hold` and `test shot` for each response |
| [Debrief log](debrief-log.md) | `ev=DECOY_PROBABLE` when a contact becomes a probable decoy; `ev=DECOY_FIRE_HOLD` for each fire hold |

## Turning it off

```lua
doctrine = {
	DecoyAssessment = false, -- no decoy labels and none of the responses (Medusa 1.6.0)
}
```

Or keep the labels and turn off single responses: `ManageEngageAirWeapons = false` (the option is never turned off,
so fire discipline does nothing either), `DecoyFireDiscipline = false`, `DecoyTestShots = false`.
