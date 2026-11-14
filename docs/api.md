# Runtime API

Other mission scripts can control a running network through `Medusa.API`, available once `medusa-bke.lua` has loaded.
No call ever throws: a bad argument returns `false` (setters) or `nil` (getters) and writes the reason to dcs.log.
`networkName` is the `name` of an entry in `MEDUSA_CONFIG.Networks`.

The stock functions are documented on the official [Runtime API](https://medusa.airdefense.systems/reference/api/)
page; BKE leaves them as they are and adds two.

| Function | Returns | Effect |
|---|---|---|
| `setROE(networkName, roe)` | boolean | `FREE`, `TIGHT` or `HOLD` |
| `getROE(networkName)` | string or nil | |
| `setPosture(networkName, posture)` | boolean | `HOT_WAR`, `WARM_WAR` or `COLD_WAR`. **[BKE]** Does not change readiness |
| `getPosture(networkName)` | string or nil | |
| `setReadiness(networkName, readiness)` | boolean | **[BKE]** `SURPRISED`, `ALERTED` or `ENGAGED` |
| `getReadiness(networkName)` | string or nil | **[BKE]** |
| `setEMCON(networkName, policy, role)` | boolean | An EMCON policy for one role, a role group (`SAM`, `RADAR`) or, with `role` left out, every role |
| `getEMCON(networkName, role)` | string or nil | |
| `setScanTiming(networkName, scanSec, quietSec)` | boolean | `ScanSec` and `QuietPeriodSec` |
| `getScanTiming(networkName)` | number, number | |
| `setRotationGroups(networkName, count)` | boolean | `EmconRotateGroups` |
| `getRotationGroups(networkName)` | number or nil | |

## [BKE] Readiness

### `Medusa.API.setReadiness(networkName, readiness)`

Sets the network's [readiness](crews-and-readiness.md#readiness) now.

- **Parameters:** `networkName` (string); `readiness` (`"SURPRISED"`, `"ALERTED"` or `"ENGAGED"`).
- **Returns:** `true` when set; `false` for an unknown network or value (the reason is in dcs.log).
- Unlike the network's own changes, this may also **lower** readiness: a new phase of the mission, a ceasefire. From
  there it rises again on its own as events happen.
- It writes an INFO line and a `READINESS` [debrief](debrief-log.md) line with `why=api`.
- Readiness has an effect only with doctrine `CrewFactors` on.

### `Medusa.API.getReadiness(networkName)`

- **Returns:** the network's readiness now (`"SURPRISED"`, `"ALERTED"` or `"ENGAGED"`), or `nil` for an unknown
  network.

### Example

A quiet border at the start; the network goes on alert when the strike package pushes, whatever its crews have seen.

```lua
-- DO SCRIPT, run by a trigger when flag "push" is set
Medusa.API.setReadiness("NORTH", "ALERTED")
```

```lua
-- Read it, for example to drive a message
local readiness = Medusa.API.getReadiness("NORTH")
if readiness == "SURPRISED" then
	trigger.action.outText("The northern air defenses have not noticed you yet.", 10)
end
```

See [examples/bke-surprised-network-config.lua](../examples/bke-surprised-network-config.lua).

## [BKE] Version and edition

Scripts can read which Medusa is running:

| Field | Value in this release | Meaning |
|---|---|---|
| `Medusa.version` | `"BKEv0.1.0"` | The BKE version, with a `BKE` prefix so it is never mistaken for a stock Medusa version (a local development build reads `"BKEv0.1.0-dev-<branch>"`). In stock Medusa this field holds the Medusa version |
| `Medusa.baseVersion` | `"1.6.0"` | The Medusa release this edition is based on. A script that compares `Medusa.version` with a stock Medusa version number should read this instead |
| `Medusa.edition` | `"Black Knight Edition (BKE)"` | The edition. Not set in stock Medusa |
| `Medusa.displayName` | `"Medusa IADS - Black Knight Edition (BKE) v0.1.0 (based on Medusa v1.6.0)"` | The name written to dcs.log at start |

```lua
if Medusa and Medusa.edition then
	env.info("Running " .. Medusa.displayName)
end
```
