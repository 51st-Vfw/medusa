require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Battery")
require("core.Debrief")

--[[
            ██████╗  █████╗ ████████╗████████╗███████╗██████╗ ██╗   ██╗     █████╗  ██████╗████████╗██╗██╗   ██╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗
            ██╔══██╗██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗╚██╗ ██╔╝    ██╔══██╗██╔════╝╚══██╔══╝██║██║   ██║██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║
            ██████╔╝███████║   ██║      ██║   █████╗  ██████╔╝ ╚████╔╝     ███████║██║        ██║   ██║╚██╗ ██╔╝███████║   ██║   ██║██║   ██║██╔██╗ ██║
            ██╔══██╗██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗  ╚██╔╝      ██╔══██║██║        ██║   ██║ ╚████╔╝ ██╔══██║   ██║   ██║██║   ██║██║╚██╗██║
            ██████╔╝██║  ██║   ██║      ██║   ███████╗██║  ██║   ██║       ██║  ██║╚██████╗   ██║   ██║  ╚██╔╝  ██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║
            ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝   ╚═╝       ╚═╝  ╚═╝ ╚═════╝   ╚═╝   ╚═╝   ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

    What this service does
    - Issues DCS controller commands to set battery radar on/off, ROE, alarm state, emission control and
      engage-air-weapons (the decoy response's switch; never written within EAW_WRITE_SETTLE_SEC of the battery's
      last launch: measured, a write right after a launch ended that missile).
    - Provides goHot, goCold, goWarm, goGreen, and goHarmShutdown transitions with hold-down enforcement.
    - This is the only code path that sends controller commands to SAM groups.

    How others use it
    - TargetAssigner calls goHot when assigning a battery to a track.
    - EmconService calls goWarm/goCold to enforce EMCON policy; HarmResponseService calls goHarmShutdown.
--]]

Medusa.Services.BatteryActivationService = {}

local _logger = Medusa.Logger:ns("BatteryActivationService")
local Battery = Medusa.Entities.Battery
local AS = Medusa.Constants.ActivationState

local STATE_WORD = {
	[AS.INITIALIZING] = "INITIALIZING",
	[AS.STATE_COLD] = "COLD",
	[AS.STATE_WARM] = "WARM",
	[AS.STATE_HOT] = "HOT",
}

--- DEBRIEF WAKE line for a battery brought up for a reason (callers that pass none, such as initial states, EMCON
--- rotation and rearming, log no WAKE line). `track`, when given, is the track it came up for.
local function debriefWake(battery, from, to, now, reason, track)
	if reason == nil then
		return
	end
	Medusa.Debrief.emit(
		battery.NetworkId,
		now,
		"WAKE",
		"battery",
		battery.GroupName,
		"from",
		STATE_WORD[from] or from,
		"to",
		to,
		"reason",
		reason,
		"track",
		track and track.DisplayTrackId
	)
end

--- One-time DCS erect: forces the deploy animation so subsequent transitions are instant.
function Medusa.Services.BatteryActivationService.erectGroup(groupName)
	local controller = GetGroupController(groupName)
	if not controller then
		return false
	end
	SetControllerOnOff(controller, true)
	ControllerSetROE(controller, "OPEN_FIRE")
	ControllerSetAlarmState(controller, "RED")
	ControllerSetDisperseOnAttack(controller, 0)
	return true
end

--- Releases a battery from IADS control entirely. Sets it weapons free and removes it from all stores.
function Medusa.Services.BatteryActivationService.goAutonomous(battery, batteryRepository, geoGrid, trackStore)
	Medusa.Services.BatteryActivationService.erectGroup(battery.GroupName)
	Medusa.Services.BatteryActivationService.releaseDecoyResponse(battery)
	Battery.releaseTrack(battery, trackStore)
	if geoGrid then
		geoGrid:remove(battery.BatteryId)
	end
	if batteryRepository then
		batteryRepository:remove(battery.BatteryId)
	end
	_logger:info(string.format("battery %s released to autonomous DCS AI control", battery.GroupName))
	return true
end

--- @param reason string|nil Why (for the DEBRIEF WAKE line; nil logs none)
--- @param track table|nil The track it comes up for (named on the WAKE line)
function Medusa.Services.BatteryActivationService.goHot(battery, now, reason, track)
	if Battery.isCrewSuppressed(battery) then
		Medusa.Services.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	if not Battery.canTransition(battery, AS.STATE_HOT, now) then
		Medusa.Services.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	return Medusa.Services.BatteryActivationService._activateHot(battery, now, reason, track)
end

-- Skips StateChangeHoldDownSec: emergency HARM/MANPAD response requires instant activation.
function Medusa.Services.BatteryActivationService.forceGoHot(battery, now, reason)
	if Battery.isCrewSuppressed(battery) then
		Medusa.Services.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	if battery.ActivationState == AS.STATE_HOT then
		return false
	end
	return Medusa.Services.BatteryActivationService._activateHot(battery, now, reason)
end

function Medusa.Services.BatteryActivationService._activateHot(battery, now, reason, track)
	if Battery.isCrewSuppressed(battery) then
		Medusa.Services.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		Medusa.Services.MetricsService.inc("medusa_goHot_blocked_total")
		_logger:error(string.format("battery %s has no controller, cannot go HOT", battery.GroupName))
		return false
	end
	SetControllerOnOff(controller, true)
	ControllerSetROE(controller, "OPEN_FIRE")
	ControllerSetAlarmState(controller, "RED")
	-- Engage-air-weapons is not forced on: the mission's own setting stays. It is written back on only if the decoy
	-- response turned it off (with the decoy switches off nothing is written). Right after a launch the decoy
	-- response writes it once the launch has settled.
	if battery.EngageAirWeapons == false and not Medusa.Services.BatteryActivationService.eawSettling(battery, now) then
		Medusa.Services.BatteryActivationService.setEngageAirWeapons(battery, true)
	end
	battery.TestShotHold = nil
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, true)
	end
	local from = battery.ActivationState
	Battery.transitionTo(battery, AS.STATE_HOT, now)
	Medusa.Services.MetricsService.inc("medusa_battery_go_hot_total")
	_logger:info(string.format("battery %s going HOT", battery.GroupName))
	debriefWake(battery, from, "HOT", now, reason, track)
	return true
end

--- Whether an engage-air-weapons write must wait: the battery launched less than EAW_WRITE_SETTLE_SEC ago.
function Medusa.Services.BatteryActivationService.eawSettling(battery, now)
	local last = battery.LastLaunchAt
	return last ~= nil and (now or GetTime()) - last < Medusa.Constants.Decoy.EAW_WRITE_SETTLE_SEC
end

--- Writes the battery's engage-air-weapons option (fire at missiles and bombs in flight) when it differs from what
--- was last written. Returns true when written.
function Medusa.Services.BatteryActivationService.setEngageAirWeapons(battery, on)
	if battery.EngageAirWeapons == on or not (AI and AI.Option and AI.Option.Ground and AI.Option.Ground.id) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		return false
	end
	SetControllerOption(controller, AI.Option.Ground.id.ENGAGE_AIR_WEAPONS, on)
	battery.EngageAirWeapons = on
	return true
end

--- A battery handed to DCS's own AI: engage-air-weapons back on if the decoy response turned it off (only then,
--- so a mission's own setting is left alone), no test-shot hold (erectGroup has already opened fire) and no fire hold.
--- Right after a launch the write is scheduled for when the launch has settled.
function Medusa.Services.BatteryActivationService.releaseDecoyResponse(battery)
	battery.TestShotHold = nil
	local hold = battery.FireHold
	battery.FireHold = nil
	local now = GetTime()
	if hold and hold.Span and not hold.Span.e then
		hold.Span.e = now -- the hold ends here: its budget time stops
	end
	if battery.EngageAirWeapons ~= false then
		return
	end
	local BAS = Medusa.Services.BatteryActivationService
	if BAS.eawSettling(battery, now) then
		ScheduleOnce(function()
			if battery.EngageAirWeapons == false then
				BAS.setEngageAirWeapons(battery, true)
			end
		end, nil, battery.LastLaunchAt + Medusa.Constants.Decoy.EAW_WRITE_SETTLE_SEC - now)
		return
	end
	BAS.setEngageAirWeapons(battery, true)
end

--- Test shot: a HOT battery holds fire; its missile in flight keeps guiding (measured in DCS).
function Medusa.Services.BatteryActivationService.holdFire(battery)
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		return false
	end
	ControllerSetROE(controller, "WEAPON_HOLD")
	return true
end

--- Ends a test-shot hold. Only a battery still HOT is opened again; any other state set its own ROE when entered.
function Medusa.Services.BatteryActivationService.resumeFire(battery)
	battery.TestShotHold = nil
	if battery.ActivationState ~= AS.STATE_HOT then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		return false
	end
	ControllerSetROE(controller, "OPEN_FIRE")
	return true
end

function Medusa.Services.BatteryActivationService.goCrewSuppressed(battery, now, trackStore)
	Battery.releaseTrack(battery, trackStore)
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		return false
	end
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "RED")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, false)
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	return true
end

function Medusa.Services.BatteryActivationService.goCold(battery, now, trackStore)
	if not Battery.canTransition(battery, AS.STATE_COLD, now) then
		return false
	end
	if not Battery.canDeactivate(battery, now) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		_logger:error(string.format("battery %s has no controller, cannot go COLD", battery.GroupName))
		return false
	end
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "RED")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, false)
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Medusa.Services.MetricsService.inc("medusa_battery_go_cold_total")
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s going COLD", battery.GroupName))
	return true
end

function Medusa.Services.BatteryActivationService.goHarmShutdown(battery, now, trackStore)
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		_logger:error(string.format("battery %s has no controller, cannot HARM shutdown", battery.GroupName))
		return false
	end
	SetControllerOnOff(controller, false)
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "RED")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, false)
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Medusa.Services.MetricsService.inc("medusa_battery_go_cold_total")
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s HARM shutdown (AI off + emissions off)", battery.GroupName))
	return true
end

function Medusa.Services.BatteryActivationService.goGreen(battery, now, trackStore)
	if not Battery.canDeactivate(battery, now) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		return false
	end
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "GREEN")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, false)
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s going GREEN (ammo depleted)", battery.GroupName))
	return true
end

--- @param reason string|nil Why (for the DEBRIEF WAKE line; nil logs none)
function Medusa.Services.BatteryActivationService.goWarm(battery, now, reason)
	if Battery.isCrewSuppressed(battery) then
		return false
	end
	if not Battery.canTransition(battery, AS.STATE_WARM, now) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		_logger:error(string.format("battery %s has no controller, cannot go WARM", battery.GroupName))
		return false
	end
	SetControllerOnOff(controller, true)
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "RED")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, true)
	end
	local from = battery.ActivationState
	Battery.transitionTo(battery, AS.STATE_WARM, now)
	Medusa.Services.MetricsService.inc("medusa_battery_go_warm_total")
	_logger:info(string.format("battery %s going WARM", battery.GroupName))
	debriefWake(battery, from, "WARM", now, reason)
	return true
end
