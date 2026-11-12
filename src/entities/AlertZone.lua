require("_header")
require("entities.Entities")

--[[
    What this entity does
    - Holds one mission-editor alert zone: where it is, which flags it writes, what it counts, the contacts it
      currently remembers (each with its last position, velocity and time seen) and the losses inside it so far.

    How others use it
    - AlertZoneService builds these from ME trigger zones and updates their contacts every few seconds.
--]]

Medusa.Entities.AlertZone = {}

function Medusa.Entities.AlertZone.new(data)
	if not data then
		error("data table is required")
	end
	if data.ZoneName == nil then
		error("missing required field: ZoneName")
	end
	if data.FlagName == nil and data.LossesFlag == nil then
		error("missing required field: FlagName or LossesFlag")
	end
	if data.Center == nil or data.Radius == nil then
		error("missing required field: Center/Radius")
	end

	return {
		ZoneName = data.ZoneName,
		FlagName = data.FlagName,
		LossesFlag = data.LossesFlag,
		Losses = 0,
		CoalitionId = data.CoalitionId,
		Threats = data.Threats or { aircraft = true },
		AltBand = data.AltBand or "any",
		LingerSec = data.LingerSec or 30,
		Center = data.Center,
		Radius = data.Radius,
		Polygon = data.Polygon,
		Contacts = {},
		-- [network id][track id] = the contact that network's track feeds (AlertZoneService).
		Index = {},
		Count = 0,
	}
end
