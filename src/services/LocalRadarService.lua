require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Battery")
require("services.BatteryActivationService")
require("services.EmconService")
require("services.ManpadService")
require("services.AaaService")
require("core.Chance")
require("core.Debrief")

--[[
    LOCAL RADAR SERVICE

    What this service does
    - Finds local cueing radars once their reach is probed (doctrine LocalCueingRadars): a search radar in a group
      without missile launchers whose reach against a 5 m2 target is under LocalRadar.MAX_REACH_M (a Dog Ear-style
      local warning radar). A radar-only group stays a sensor group, a group with guns is an AAA battery directed by
      its radar, a group with MANPADs a MANPAD battery; in each case the radar is managed here, not by EMCON.
    - Keeps each local radar dark unless it has a reason to be up: a hostile in the network picture within its reach
      plus a margin, an alerted MANPAD or AAA crew it supports (its own included), an observer report it covers, or
      its own crew's sighting (local initiative). Once up it stays up LocalRadar.HOLD_SEC after its last reason.
    - A local radar no ground radar of the network covers (and no airborne one exists) sweeps on its own for
      LocalRadar.SWEEP_MIN..MAX_SEC every SWEEP_EVERY_MIN..MAX_SEC, at random, so a low flyer cannot slip past a
      blind network unseen (doctrine LocalRadarSweeps; never when the mission sets EMCON MINIMIZE for its role, EWR
      for a radar-only group).
      Up means WARM (radar on, weapons hold); a battery's weapons are still released only by the network or by its
      own crew logic.
    - Cues MANPAD and AAA crews in a lit radar's reach from the contacts it reports: sleeping MANPAD crews near the
      nearest aircraft are woken, independent gun crews near it scan all round (AaaService.cue).

    How others use it
    - IadsNetwork calls classify after sensor probing, update once a second (a few radars per pass), onRadarContacts
      after polling a lit local radar, and cueFromReport when an observer report or a crew's own sighting arrives.
    - Logs (INFO): "local radar <group>: reach <n> km", "local radar <group> on (<reason>)", "... off (<reason>)".
--]]

Medusa.Services.LocalRadarService = {}

local C = Medusa.Constants
local LR = C.LocalRadar
local AS = C.ActivationState
local BR = C.BatteryRole
local BUR = C.BatteryUnitRole
local BOS = C.BatteryOperationalStatus
local MSWS = C.Manpad.SleepWakeState
local MWR = C.Manpad.WakeReason
local ARS = C.Aaa.ResponseState
local TI = C.TrackIdentification
local AAT = C.AssessedAircraftType
local LS = C.TrackLifecycleState
local ECP = C.EmissionControlPolicy
local Battery = Medusa.Entities.Battery
local BAS = Medusa.Services.BatteryActivationService
local logger = Medusa.Logger:ns("LocalRadarService")

local KIND = { SENSOR = "SENSOR", BATTERY = "BATTERY", MANPAD = "MANPAD" }
local FILTER_TRACK = { "Track" }
local FILTER_LOCAL = { "Manpad", "Aaa" }
local EMPTY = {}
local NOT_THREAT_ID = { [TI.FRIENDLY] = true, [TI.WHITEAIR] = true, [TI.ARM] = true }
local NOT_THREAT_TYPE = { [AAT.MISSILE] = true, [AAT.HARM] = true }
local AIRCRAFT_TYPES = {
	[AAT.FIXED_WING] = true,
	[AAT.ROTARY_WING] = true,
	[AAT.FIGHTER] = true,
	[AAT.SEAD_AIRCRAFT] = true,
}
local ALERTED_MANPAD = { [MSWS.ALERTING] = true, [MSWS.ALERT] = true, [MSWS.HOT] = true }
local BLOCKED_STATUS = { [BOS.DESTROYED] = true, [BOS.INOPERATIVE] = true }
local sensorBuffer = {}
local batteryBuffer = {}

Medusa.Services.LocalRadarService.Kind = KIND

--- `random` (optional, [0,1)) times the sweeps; math.random by default.
function Medusa.Services.LocalRadarService.newState(random)
	return { records = {}, byGroup = {}, cursor = 0, pass = 0, random = random or math.random }
end

local function clear(values)
	for i = #values, 1, -1 do
		values[i] = nil
	end
end

local function reachOf(range)
	if type(range) ~= "number" or range <= 0 then
		return nil
	end
	return range / C.ContactEvidence.REACH_RATIO
end

local function isLocalReach(reach)
	return reach ~= nil and reach < LR.MAX_REACH_M
end

local function hasUnitRole(battery, role)
	local units = battery.Units or EMPTY
	for i = 1, #units do
		if Battery.unitHasRole(units[i], role) then
			return true
		end
	end
	return false
end

local function hasLauncherUnit(battery)
	local units = battery.Units or EMPTY
	for i = 1, #units do
		if Battery.hasLauncherRole(units[i], C.LAUNCHER_ROLES) then
			return true
		end
	end
	return false
end

local function distance2DSquared(a, b)
	local dx = a.x - b.x
	local dz = a.z - b.z
	return dx * dx + dz * dz
end

local function register(state, groupName, kind, position, reach)
	local record = state.byGroup[groupName]
	local isNew = record == nil
	if isNew then
		record = {
			GroupName = groupName,
			Kind = kind,
			Battery = nil,
			Position = position,
			ReachM = reach,
			Supported = {},
			UpUntil = 0,
			Reason = nil,
			CueUntil = nil,
			CueReason = nil,
			Applied = nil,
			LastCueTime = nil,
			ThreatSeenAt = nil,
			Uncovered = false,
			NextSweepAt = nil,
		}
		state.byGroup[groupName] = record
	end
	record.Kind = kind
	record.Position = position
	record.ReachM = reach
	record.Pass = state.pass
	state.records[#state.records + 1] = record
	return record, isNew
end

local function classifySensorGroups(ctx, state, fresh)
	local names = ctx.sensorStore:getUniqueGroupNames()
	for i = 1, #names do
		local sensors = ctx.sensorStore:getByGroupName(names[i], sensorBuffer)
		local first = sensors[1]
		local range, named = nil, false
		for j = 1, #sensors do
			named = named or sensors[j].NamedRole == true or sensors[j].IsAirborne == true
			local r = sensors[j].DetectionRangeMax
			if r and (not range or r > range) then
				range = r
			end
		end
		local reach = reachOf(range)
		if first and first.Position and not named and isLocalReach(reach) then
			for j = 1, #sensors do
				sensors[j].IsLocalRadar = true
			end
			local record, isNew = register(state, names[i], KIND.SENSOR, first.Position, reach)
			if isNew then
				fresh[#fresh + 1] = record
			end
		end
	end
end

local function classifyBatteries(state, batteries, kind, fresh)
	for i = 1, #batteries do
		local b = batteries[i]
		local reach = reachOf(b.DetectionRangeMax)
		if
			b.Position
			and (kind == KIND.MANPAD or b.Role == BR.AAA)
			and hasUnitRole(b, BUR.SEARCH_RADAR)
			and not hasLauncherUnit(b)
			and isLocalReach(reach)
		then
			local record, isNew = register(state, b.GroupName, kind, b.Position, reach)
			record.Battery = b
			b.LocalRadar = record
			if isNew then
				fresh[#fresh + 1] = record
			end
		end
	end
end

local function findSupported(ctx, record)
	local supported = record.Supported
	clear(supported)
	if not ctx.localGeoGrid then
		return
	end
	local results = ctx.localGeoGrid:queryRadius(record.Position, record.ReachM, FILTER_LOCAL)
	for id in pairs(results.ManpadIds or EMPTY) do
		local b = ctx.manpadStore and ctx.manpadStore:get(id)
		if b then
			supported[#supported + 1] = b
		end
	end
	for id in pairs(results.AaaIds or EMPTY) do
		local b = ctx.batteryStore and ctx.batteryStore:get(id)
		if b then
			supported[#supported + 1] = b
		end
	end
end

--- Radars not found again (destroyed, or their group lost its radar) are forgotten; a battery that kept its guns is
--- handed back to the network and EMCON.
local function forgetGone(state)
	for groupName, record in pairs(state.byGroup) do
		if record.Pass ~= state.pass then
			state.byGroup[groupName] = nil
			local b = record.Battery
			if b and b.LocalRadar == record then
				b.LocalRadar = nil
				b.CueWarmUntil = nil
			end
		end
	end
end

--- True when a ground radar of the network that is not a local radar reaches `position`, or an airborne radar exists.
local function coveredByNetwork(ctx, position)
	local names = ctx.sensorStore:getUniqueGroupNames()
	for i = 1, #names do
		local sensors = ctx.sensorStore:getByGroupName(names[i], sensorBuffer)
		for j = 1, #sensors do
			local s = sensors[j]
			if s.IsAirborne == true then
				return true
			end
			local r = s.DetectionRangeMax
			if not s.IsLocalRadar and r and s.Position and distance2DSquared(s.Position, position) <= r * r then
				return true
			end
		end
	end
	return false
end

--- A random time in [low, high); in training its midpoint, or the point `phase` (0..1) of the window when given.
local function randomBetween(ctx, state, low, high, phase)
	return Medusa.Chance.uniform(Medusa.Chance.isTraining(ctx.doctrine), low, high, state.random, phase)
end

--- (Re)builds the list of local radars from the stores, keeping the state of radars already known. Call after the
--- radars' reach is known (sensor probing). Returns the number of local radars.
function Medusa.Services.LocalRadarService.classify(ctx)
	local state = ctx.localRadars
	clear(state.records)
	if not ctx.doctrine or ctx.doctrine.LocalCueingRadars == false then
		return 0
	end
	state.pass = (state.pass or 0) + 1
	local fresh = {}
	classifySensorGroups(ctx, state, fresh)
	if ctx.batteryStore then
		classifyBatteries(state, ctx.batteryStore:getAll(batteryBuffer), KIND.BATTERY, fresh)
	end
	if ctx.manpadStore then
		classifyBatteries(state, ctx.manpadStore:getAll(batteryBuffer), KIND.MANPAD, fresh)
	end
	forgetGone(state)
	for i = 1, #state.records do
		local record = state.records[i]
		findSupported(ctx, record)
		record.Uncovered = not coveredByNetwork(ctx, record.Position)
	end
	for i = 1, #fresh do
		local record = fresh[i]
		-- In training each radar's first sweep falls at its own fixed point of the window (a hash of its name), so
		-- the network's sweeps are not all at once.
		record.NextSweepAt = ctx.now
			+ randomBetween(
				ctx,
				state,
				LR.SWEEP_EVERY_MIN_SEC,
				LR.SWEEP_EVERY_MAX_SEC,
				Medusa.Chance.fraction(record.GroupName)
			)
		logger:info(
			string.format(
				"local radar %s: reach %.0f km, %s group, supports %d local defence groups",
				record.GroupName,
				record.ReachM / 1000,
				string.lower(record.Kind),
				#record.Supported
			)
		)
	end
	if state.cursor > #state.records then
		state.cursor = 0
	end
	return #state.records
end

local function isThreatTrack(track)
	return track ~= nil
		and track.LifecycleState == LS.ACTIVE
		and not NOT_THREAT_ID[track.TrackIdentification]
		and not NOT_THREAT_TYPE[track.AssessedAircraftType]
end

local function threatNear(ctx, record)
	if not ctx.networkedGeoGrid then
		return false
	end
	local results = ctx.networkedGeoGrid:queryRadius(record.Position, record.ReachM + LR.THREAT_MARGIN_M, FILTER_TRACK)
	for id in pairs(results.TrackIds or EMPTY) do
		if isThreatTrack(ctx.trackStore:get(id)) then
			return true
		end
	end
	return false
end

local function crewAlerted(battery, now)
	if battery.Manpad then
		return ALERTED_MANPAD[battery.Manpad.SleepWakeState] == true
	end
	local aaa = battery.Aaa
	if aaa and Battery.isIndependentAaa(battery) then
		return aaa.ResponseState ~= ARS.IDLE or (aaa.CuedUntil ~= nil and now < aaa.CuedUntil)
	end
	return false
end

local function supportedAlerted(record, now)
	if record.Battery and crewAlerted(record.Battery, now) then
		return true
	end
	local supported = record.Supported
	for i = 1, #supported do
		if crewAlerted(supported[i], now) then
			return true
		end
	end
	return false
end

local function reasonFor(ctx, record)
	if record.CueUntil and ctx.now < record.CueUntil then
		return record.CueReason
	end
	if supportedAlerted(record, ctx.now) then
		return "supported units alerted"
	end
	if
		record.ThreatSeenAt
		and ctx.now - record.ThreatSeenAt < LR.THREAT_RECHECK_SEC
		and ctx.now >= record.ThreatSeenAt
	then
		return "threat near"
	end
	if threatNear(ctx, record) then
		record.ThreatSeenAt = ctx.now
		return "threat near"
	end
	return nil
end

local function isBlocked(record)
	local b = record.Battery
	if not b then
		return false
	end
	return Battery.isCrewSuppressed(b)
		or b.HarmShutdownUntil ~= nil
		or BLOCKED_STATUS[b.OperationalStatus] == true
		or b.ActivationState == AS.INITIALIZING
end

local function logTransition(ctx, record, up, reason)
	logger:info(string.format("local radar %s %s (%s)", record.GroupName, up and "on" or "off", reason))
	if up then
		Medusa.Debrief.emit(ctx.networkId, ctx.now, "LOCAL_RADAR_UP", "radar", record.GroupName, "reason", reason)
	end
end

local function applySensor(ctx, record, up, reason)
	local sensors = ctx.sensorStore:getByGroupName(record.GroupName, sensorBuffer)
	if #sensors == 0 then
		return
	end
	local was = record.Applied
	Medusa.Services.EmconService.setSensorGroupState(record.GroupName, sensors, up and AS.STATE_WARM or AS.STATE_COLD)
	local nowUp = sensors[1].RadarStatus == "ACTIVE"
	if nowUp ~= was then
		record.Applied = nowUp
		logTransition(ctx, record, nowUp, nowUp and reason or (was == nil and "dark until a threat is near" or reason))
	end
end

local function emconWantsCold(ctx, battery)
	local doctrine = ctx.doctrine
	local policy = doctrine and doctrine.EMCON and doctrine.EMCON[battery.Role]
		or C.EMCON_DEFAULT_POLICY_BY_ROLE[battery.Role]
	return policy == nil or policy == ECP.MINIMIZE
end

local function applyBattery(ctx, record, up, reason)
	local b = record.Battery
	local now = ctx.now
	if up then
		b.CueWarmUntil = record.UpUntil
		if b.ActivationState == AS.STATE_COLD and BAS.goWarm(b, now, "local_radar: " .. tostring(reason)) then
			logTransition(ctx, record, true, reason)
		end
		return
	end
	b.CueWarmUntil = nil
	if
		b.ActivationState == AS.STATE_WARM
		and not b.CurrentTargetTrackId
		and emconWantsCold(ctx, b)
		and BAS.goCold(b, now, ctx.trackStore)
	then
		logTransition(ctx, record, false, reason)
	end
end

local function applyManpad(ctx, record, up, reason)
	local b = record.Battery
	if b.Manpad and b.Manpad.SleepWakeState == MSWS.HOT then
		return
	end
	if up then
		if b.ActivationState == AS.STATE_COLD and BAS.goWarm(b, ctx.now, "local_radar: " .. tostring(reason)) then
			logTransition(ctx, record, true, reason)
		end
	elseif b.ActivationState == AS.STATE_WARM and BAS.goCold(b, ctx.now, ctx.trackStore) then
		logTransition(ctx, record, false, reason)
	end
end

--- A sweep may run when the switch is on and the mission sets no EMCON MINIMIZE for the radar's role.
local function sweepsAllowed(ctx, record)
	local doctrine = ctx.doctrine
	if not doctrine or doctrine.LocalRadarSweeps == false then
		return false
	end
	local role = record.Battery and record.Battery.Role or "EWR"
	return Medusa.Services.EmconService.missionPolicy(doctrine, role) ~= ECP.MINIMIZE
end

--- When a sweep falls due: an uncovered radar that is dark and free comes up for a short sweep; in any case the next
--- one is scheduled.
local function sweepIfDue(ctx, record, blocked)
	local now = ctx.now
	local due = record.NextSweepAt
	if not due or now < due then
		return
	end
	local state = ctx.localRadars
	local from = now
	if record.Uncovered and not blocked and now >= record.UpUntil and sweepsAllowed(ctx, record) then
		record.UpUntil = now + randomBetween(ctx, state, LR.SWEEP_MIN_SEC, LR.SWEEP_MAX_SEC)
		record.Reason = "periodic sweep"
		from = record.UpUntil
	end
	record.NextSweepAt = from + randomBetween(ctx, state, LR.SWEEP_EVERY_MIN_SEC, LR.SWEEP_EVERY_MAX_SEC)
end

local function evaluate(ctx, record)
	local now = ctx.now
	local blocked = isBlocked(record)
	local reason = not blocked and reasonFor(ctx, record) or nil
	if reason then
		if now + LR.HOLD_SEC > record.UpUntil then
			record.UpUntil = now + LR.HOLD_SEC
		end
		record.Reason = reason
	else
		sweepIfDue(ctx, record, blocked)
	end
	local up = not blocked and now < record.UpUntil
	local why = up and record.Reason or (blocked and "held down" or "no threat near")
	if record.Kind == KIND.SENSOR then
		applySensor(ctx, record, up, why)
	elseif record.Kind == KIND.BATTERY then
		applyBattery(ctx, record, up, why)
	else
		applyManpad(ctx, record, up, why)
	end
end

--- Evaluates up to LocalRadar.EVALS_PER_PASS local radars, round-robin. Returns the number evaluated.
function Medusa.Services.LocalRadarService.update(ctx)
	local state = ctx.localRadars
	local records = state.records
	local n = #records
	if n == 0 then
		return 0
	end
	local budget = math.min(n, LR.EVALS_PER_PASS)
	local cursor = state.cursor
	for _ = 1, budget do
		cursor = cursor % n + 1
		evaluate(ctx, records[cursor])
	end
	state.cursor = cursor
	return budget
end

--- True when the radar's emissions are on (a battery's: WARM or HOT).
function Medusa.Services.LocalRadarService.isUp(record)
	if record.Kind == KIND.SENSOR then
		return record.Applied == true
	end
	local state = record.Battery and record.Battery.ActivationState
	return state == AS.STATE_WARM or state == AS.STATE_HOT
end

--- Gives one local radar a reason to be up until `untilTime` (default now + LocalRadar.CUE_HOLD_SEC): an observer
--- report it covers, or its own crew's sighting (local initiative).
function Medusa.Services.LocalRadarService.cueRadar(ctx, record, reason, untilTime)
	untilTime = untilTime or ctx.now + LR.CUE_HOLD_SEC
	if not record.CueUntil or record.CueUntil < untilTime then
		record.CueUntil = untilTime
	end
	record.CueReason = reason
end

--- An observer report or a crew's own sighting at `position`: every local radar whose reach plus margin covers it
--- gets a reason to be up for LocalRadar.CUE_HOLD_SEC. Returns the number of radars cued.
function Medusa.Services.LocalRadarService.cueFromReport(ctx, position, reason)
	local records = ctx.localRadars.records
	local count = 0
	local untilTime = ctx.now + LR.CUE_HOLD_SEC
	for i = 1, #records do
		local record = records[i]
		local radius = record.ReachM + LR.THREAT_MARGIN_M
		if distance2DSquared(record.Position, position) <= radius * radius then
			Medusa.Services.LocalRadarService.cueRadar(ctx, record, reason, untilTime)
			count = count + 1
		end
	end
	return count
end

--- Wakes sleeping MANPAD crews and cues independent gun crews within LocalRadar.CUE_RADIUS_M of `threatPosition`;
--- with `filterPosition`, only crews within `filterRadius` of it (the cueing radar's reach). Returns crews cued.
function Medusa.Services.LocalRadarService.cueLocalDefences(
	ctx,
	threatPosition,
	wakeReason,
	filterPosition,
	filterRadius
)
	if not ctx.localGeoGrid then
		return 0
	end
	local results = ctx.localGeoGrid:queryRadius(threatPosition, LR.CUE_RADIUS_M, FILTER_LOCAL)
	local limit = filterRadius and filterRadius * filterRadius or nil
	local count = 0
	for id in pairs(results.ManpadIds or EMPTY) do
		local b = ctx.manpadStore and ctx.manpadStore:get(id)
		if
			b
			and b.Position
			and (not limit or distance2DSquared(b.Position, filterPosition) <= limit)
			and Medusa.Services.ManpadService.cueBattery(ctx, b, wakeReason)
		then
			count = count + 1
		end
	end
	local untilTime = ctx.now + LR.AAA_CUE_SEC
	for id in pairs(results.AaaIds or EMPTY) do
		local b = ctx.batteryStore and ctx.batteryStore:get(id)
		if
			b
			and b.Position
			and (not limit or distance2DSquared(b.Position, filterPosition) <= limit)
			and Medusa.Services.AaaService.cue(b, untilTime)
		then
			count = count + 1
		end
	end
	return count
end

--- After a lit local radar was polled: cue the MANPAD and AAA crews in its reach around the nearest aircraft it
--- reported (an identified aircraft, not a friendly or a weapon), at most every LocalRadar.CUE_INTERVAL_SEC.
--- Returns the number of crews cued.
function Medusa.Services.LocalRadarService.onRadarContacts(ctx, record, reports, trackManager)
	local now = ctx.now
	if record.LastCueTime and now - record.LastCueTime < LR.CUE_INTERVAL_SEC then
		return 0
	end
	local reachSq = record.ReachM * record.ReachM
	local best, bestSq = nil, nil
	for i = 1, #reports do
		local trackId = trackManager:getTrackIdByNetworkId(reports[i].NetworkId)
		local track = trackId and ctx.trackStore:get(trackId)
		if isThreatTrack(track) and AIRCRAFT_TYPES[track.AssessedAircraftType] and track.Position then
			local dSq = distance2DSquared(track.Position, record.Position)
			if dSq <= reachSq and (not bestSq or dSq < bestSq) then
				best, bestSq = track, dSq
			end
		end
	end
	if not best then
		return 0
	end
	record.LastCueTime = now
	return Medusa.Services.LocalRadarService.cueLocalDefences(
		ctx,
		best.Position,
		MWR.LOCAL_RADAR,
		record.Position,
		record.ReachM
	)
end
