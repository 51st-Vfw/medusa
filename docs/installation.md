# Installation

Medusa IADS - Black Knight Edition (BKE) installs the same way as Medusa: one Lua file, loaded by a mission trigger.
Nothing is installed in DCS itself. This page uses the BKE file names; the official
[Installation](https://medusa.airdefense.systems/getting-started/installation/) page covers the same steps for stock
Medusa's files.

## Download

Get the latest release from the fork's [GitHub Releases](https://github.com/51st-Vfw/medusa/releases). Each release has:

| File | What it is |
|---|---|
| `medusa-bke.lua` | The standard build: Medusa BKE with its runtime library (dcs-harness) bundled. Use this one unless you know you need the thin build |
| `medusa-bke-thin.lua` | The thin build: Medusa BKE without dcs-harness, for missions that already load dcs-harness |
| `medusa-bke.zip` | `medusa-bke.lua` in a zip, named with its version inside (`medusa-bke-0.0.1.lua`) |
| `medusa-bke-thin.zip` | `medusa-bke-thin.lua` in a zip, named with its version inside (`medusa-bke-thin-0.0.1.lua`) |
| `SHA256SUMS.txt` | SHA-256 checksums of the four files above |
| `LICENSE` | The license file, the same as Medusa's |

The `.lua` file and the file inside the matching zip are the same; the zip only keeps the version in the file name.

Use one Medusa per mission: load either BKE or stock Medusa, never both.

## Mission Editor set-up

### Standard set-up

1. Open the mission in the Mission Editor and go to **Triggers**.
2. Add a trigger: **MISSION START**, no conditions.
3. If you configure Medusa (a `MEDUSA_CONFIG` table or a `Medusa_MM_Doctrine` table), add a **DO SCRIPT** action
   with that table first. See [Quick start](quick-start.md) and [Configuration](configuration.md).
4. Add a **DO SCRIPT FILE** action and pick `medusa-bke.lua`.
5. Save the mission. The Mission Editor copies the file into the `.miz`, so after you update BKE, pick the new file
   again in every mission that uses it.

The order of the actions matters: the configuration must run before `medusa-bke.lua`, because Medusa reads it once
when it starts.

### Thin set-up (dcs-harness already loaded)

If the mission already loads dcs-harness for another script:

1. **MISSION START** trigger, first action: **DO SCRIPT FILE** `dcs-harness.lua` (if another script does not load it
   already).
2. Then your configuration (**DO SCRIPT**), if any.
3. Then **DO SCRIPT FILE** `medusa-bke-thin.lua`.

If the log shows errors about missing globals such as `GetGroup` or `SetControllerOnOff`, dcs-harness was not loaded
before `medusa-bke-thin.lua`. Use `medusa-bke.lua` instead, or fix the load order.

## Check that it runs

Start the mission and open `dcs.log` (in `Saved Games\DCS\Logs`). Medusa writes its lines with the `Medusa` tag. At
start you should see:

- a line naming the edition and version: `Medusa IADS - Black Knight Edition (BKE) v0.0.1 (based on Medusa v1.6.0)`;
- for each network, its configuration and a summary of its doctrine;
- **[BKE]** one `crew roster` line per network (its observer posts and crews by skill), a `listening stations:` line
  when the network has [listening stations](esm-listening-stations.md), and a `local radar ...` line for each
  [local cueing radar](local-radars-and-observers.md) found;
- **[BKE]** with `TrainingMode = true`, a `DEBRIEF|...|ev=TRAINING_MODE|on=true` line.

An `ERROR` line from `Doctrine` or `Config` means a value in your configuration was not valid. Medusa logs what it
used instead and carries on. Fix the value and run the mission again.

No Medusa lines at all means the trigger did not run: check that it is a MISSION START trigger and that the
DO SCRIPT FILE action points at `medusa-bke.lua`.

## Next steps

- [Quick start](quick-start.md): name your groups and set a first doctrine.
- [Naming conventions](naming-conventions.md): group names, role tokens and BKE's observer and listening-station
  tokens.
- [Differences from Medusa 1.6.0](differences-from-medusa-1.6.0.md): what changes when an existing Medusa mission
  loads BKE.
