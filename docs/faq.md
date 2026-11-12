# FAQ

Questions about Black Knight Edition. For questions about Medusa itself (modded SAMs, both coalitions, performance,
how point defence is assigned and more), see the official [FAQ](https://medusa.airdefense.systems/getting-started/faq/).

## For mission makers

### Is BKE the official Medusa?

No. The official Medusa is Zach Shepard's, at [github.com/medusa-iads/medusa](https://github.com/medusa-iads/medusa)
and [medusa.airdefense.systems](https://medusa.airdefense.systems). BKE is a customised version for the 667th Black
Knights and the 51st VFW, based on Medusa 1.6.0.

### Will my Medusa mission work with BKE?

Yes, without changes, with one exception: a lone Dog Ear (a short-range radar in a group with no missiles and no
`ewr` token) is now a dark local cueing radar instead of an always-on early-warning radar. Put `ewr` in its group name
to keep it on. See [Differences from Medusa 1.6.0](differences-from-medusa-1.6.0.md).

### Can I load BKE and stock Medusa in the same mission?

No. Load one of them: `medusa-bke.lua` or stock Medusa's `medusa.lua`, not both.

### Do I have to configure anything to get the BKE features?

No. Every BKE feature is on by default except training mode. Observer posts and listening stations need a token in
their group name (`obs`, `esm`); alert zones need properties on a trigger zone. Everything else works on the groups you
already have.

### My observer posts never report. Why?

Most often their skill. An Average crew, the Mission Editor's default for ground units, gets a report out about one
time in four; spawned units and units set to Random or Player skill count as Average too. Set your posts to Good, High
or Excellent. Also check that the aircraft is within sight (8 km by day, 2 km at night, less in fog or haze, with a
clear line of sight) or low and close enough to hear (3 km, under 1000 m), and that the network is not `SURPRISED` with
nobody listening. The `crew roster` line in dcs.log lists each crew's skill; the [debrief log](debrief-log.md) has a
`REPORT_NOT_MADE` or `REPORT_LOST` line for each report that did not get through.

### Why does my SAM come up WARM when nothing is on its radar?

A crew report, a crew's own sighting (local initiative) or a listening-station fix put a hostile within its reach. It
comes up WARM (radar on, weapons hold) for two minutes so its own radar can find the aircraft. The `WAKE` line in the
debrief log gives the reason. To keep an ambush site dark whatever the crews see, give its role an EMCON policy in the
doctrine (for example `EMCON = { SR_SAM = "MINIMIZE" }`): a role the mission sets is never woken this way.

### How do I make a network that starts unaware?

Set doctrine `Readiness = "SURPRISED"` (or `Posture = "COLD_WAR"` and leave `Readiness` out). The crews wake up as the
raid develops: alerted 2-5 minutes after the first hostile is seen, engaged at the first launch or loss. A script can
also raise it with `Medusa.API.setReadiness`. See [Crews, readiness and training mode](crews-and-readiness.md).

### Can I trigger things from what the IADS sees?

Yes: [alert zones](alert-zones.md). A trigger zone with a `MedusaFlag` property gets a flag holding how many hostiles
the radars track inside it; use it in ordinary editor triggers.

### How do I compare BKE with stock Medusa in the same mission file?

Use [examples/bke-stock-behaviour-config.lua](../examples/bke-stock-behaviour-config.lua): it turns off everything BKE
has a switch for. What remains (faster HARM calls, contact evidence, the released-store hold, the fixes) is always on.

### Where do I find what happened after a mission?

In dcs.log: search for `DEBRIEF|`. See [Debrief log](debrief-log.md).

## For pilots

### Does the IADS know my aircraft type?

Not from DCS. The network judges a contact from how it flies and how big it looks on radar. A crew that sees you within
about 2 km by day may name your type in a report, as a real lookout could.

### Will my HARM be noticed?

Faster than with stock Medusa. A HARM inbound on a HOT S-300 or Tor is usually called within about 10 s; one seen only
by early-warning radars within about 50 s. The threatened batteries then shut down or defend themselves, as the
network's doctrine says. Your aircraft becomes hostile when the network finds that it fired the missile.

### Do bombs make the SAMs shut down?

No. A store that falls off a known aircraft and never speeds up on its own has no motor, so it is not called an ARM.
Point defence still shoots at one falling on the site it protects. See [Released stores](released-stores.md).

### Do TALDs still work?

For a while. A TALD looks like a fighter on radar, and the network engages it like one at first. After about 90 s of
straight, steadily falling energy (sooner if missiles fired at it draw no reaction) it is called a probable decoy, and
long- and medium-range SAMs stop engaging it. Turning hard, climbing or accelerating proves you are not a decoy. See
[Decoys and fire discipline](decoys.md).

### Can the ground hear my radar?

Yes, if the network has listening stations. A station hears your radar in its main beam out to about 250 km and its
sidelobes close in, and takes a bearing. Several stations crossing their bearings can put the defences on alert
around you. They cannot hear a radar that is off, and they cannot hear jammers. Radar silence pays. Whether DCS reports
a player aircraft's radar to the stations has not been confirmed yet. See [ESM listening stations](esm-listening-stations.md).

### Can the ground see or hear me if I fly low?

Yes. Ground crews and observer posts see aircraft within about 8 km by day (2 km at night, less in poor weather, never
through terrain) and hear low aircraft within about 3 km. Their reports are coarse and arrive late, and some never
arrive, but they wake MANPAD teams and gun crews, bring up local radars and can bring a short-range SAM up WARM ahead
of you.

### Is there a way to practise without luck deciding the outcome?

Ask your mission maker for training mode (doctrine `TrainingMode = true`). Medusa's own delays and detection ranges
then take their typical values, no crew report is lost, and size estimates carry no noise, so a good run and a lucky
run can be told apart. DCS's own detection and missile hits are unchanged.

## Contributing

### I want to suggest or contribute a change. Where?

To official Medusa: please contribute at [github.com/medusa-iads/medusa](https://github.com/medusa-iads/medusa).
Members of the 51st VFW and the 667th with BKE requests or contributions: contact Blackdog of the 667th.
[CONTRIBUTING.md](../CONTRIBUTING.md) describes the development workflow.
