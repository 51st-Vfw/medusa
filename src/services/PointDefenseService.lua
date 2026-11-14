require("_header")
require("services.Services")
require("services.PkModel")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")
require("services.BatteryActivationService")
require("services.HarmDetectionService")
require("services.DecoyAssessmentService")
require("entities.Battery")
require("entities.Track")

--[[
            ██████╗  ██████╗ ██╗███╗   ██╗████████╗    ██████╗ ███████╗███████╗███████╗███╗   ██╗███████╗███████╗
            ██╔══██╗██╔═══██╗██║████╗  ██║╚══██╔══╝    ██╔══██╗██╔════╝██╔════╝██╔════╝████╗  ██║██╔════╝██╔════╝
            ██████╔╝██║   ██║██║██╔██╗ ██║   ██║       ██║  ██║█████╗  █████╗  █████╗  ██╔██╗ ██║███████╗█████╗
            ██╔═══╝ ██║   ██║██║██║╚██╗██║   ██║       ██║  ██║██╔══╝  ██╔══╝  ██╔══╝  ██║╚██╗██║╚════██║██╔══╝
            ██║     ╚██████╔╝██║██║ ╚████║   ██║       ██████╔╝███████╗██║     ███████╗██║ ╚████║███████║███████╗
            ╚═╝      ╚═════╝ ╚═╝╚═╝  ╚═══╝   ╚═╝       ╚═════╝ ╚══════╝╚═╝     ╚══════╝╚═╝  ╚═══╝╚══════╝╚══════╝

    What this service does
    - Finds SHORAD and HARM-capable batteries near a threatened battery using spatial queries.
    - Activates nearby point-defense batteries to engage inbound HARMs that threaten high-value SAMs.

    How others use it
    - HarmResponseService calls activate when a battery's doctrine says to use point defense.
    - IadsNetwork includes point-defense evaluation as part of the HARM response tick.
--]]

Medusa.Services.PointDefenseService = {}

local _logger = Medusa.Logger:ns("PointDefenseService")
local AAT = Medusa.Constants.AssessedAircraftType
Medusa.Services.PointDefenseService._batteryBuffer = {}
local _pdBatteryBuffer = Medusa.Services.PointDefenseService._batteryBuffer
Medusa.Services.PointDefenseService._harmActivationBuffer = {}
local _harmActivationBuffer = Medusa.Services.PointDefenseService._harmActivationBuffer
local _providerBuffer = {}
local _noProviders = {}
local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BR = Medusa.Constants.BatteryRole
local LS = Medusa.Constants.TrackLifecycleState
local BatteryActivationService = Medusa.Services.BatteryActivationService
local C = Medusa.Constants
local Battery = Medusa.Entities.Battery

local function clearTable(t)
	for k in pairs(t) do
		t[k] = nil
	end
end

-- [BKE] Very-long-range SAMs are the sites most worth protecting, so they take point defense like the others.
local HVA_ROLES = { [BR.VLR_SAM] = true, [BR.LR_SAM] = true, [BR.MR_SAM] = true }
local PD_ROLES = { [BR.SR_SAM] = true, [BR.AAA] = true }

function Medusa.Services.PointDefenseService.setAssignment(pdBatteryId, targetBatteryId, batteryStore)
	if pdBatteryId == targetBatteryId then
		return false
	end
	local pdBattery = batteryStore:get(pdBatteryId)
	local targetBattery = batteryStore:get(targetBatteryId)
	if not pdBattery or not targetBattery then
		return false
	end
	if Battery.isCrewSuppressed(pdBattery) then
		return false
	end
	if pdBattery.PointDefenseTargetId == targetBatteryId then
		return true
	end
	if pdBattery.PointDefenseTargetId then
		Medusa.Services.PointDefenseService.clearAssignment(pdBatteryId, batteryStore)
	end
	-- [BKE] A battery may have several providers (PointDefenseProviderIds, in assignment order);
	-- PointDefenseProviderId is the first of them.
	local ids = targetBattery.PointDefenseProviderIds
	if not ids then
		ids = {}
		targetBattery.PointDefenseProviderIds = ids
	end
	if #ids == 0 and targetBattery.PointDefenseProviderId and targetBattery.PointDefenseProviderId ~= pdBatteryId then
		ids[1] = targetBattery.PointDefenseProviderId
	end
	ids[#ids + 1] = pdBatteryId
	pdBattery.IsPointDefense = true
	pdBattery.PointDefenseTargetId = targetBatteryId
	targetBattery.PointDefenseProviderId = ids[1]
	_logger:info(string.format("assigned PD %s -> target %s", pdBatteryId, targetBatteryId))
	return true
end

function Medusa.Services.PointDefenseService.clearAssignment(pdBatteryId, batteryStore)
	local pdBattery = batteryStore:get(pdBatteryId)
	if not pdBattery then
		return true
	end
	if pdBattery.PointDefenseTargetId then
		local targetBattery = batteryStore:get(pdBattery.PointDefenseTargetId)
		if targetBattery then
			local ids = targetBattery.PointDefenseProviderIds
			if ids then
				for i = #ids, 1, -1 do
					if ids[i] == pdBatteryId then
						table.remove(ids, i)
					end
				end
				targetBattery.PointDefenseProviderId = ids[1]
			elseif targetBattery.PointDefenseProviderId == pdBatteryId then
				targetBattery.PointDefenseProviderId = nil
			end
		end
	end
	pdBattery.IsPointDefense = false
	pdBattery.PointDefenseTargetId = nil
	return true
end

--- [BKE] Drops provider ids whose battery is gone from the store or no longer points at `battery`. True if any went.
local function pruneMissingProviders(battery, batteryStore)
	local ids = battery.PointDefenseProviderIds
	if not ids or #ids == 0 then
		ids = { battery.PointDefenseProviderId }
		battery.PointDefenseProviderIds = ids
	end
	local pruned = false
	for i = #ids, 1, -1 do
		local provider = batteryStore:get(ids[i])
		if not provider or provider.PointDefenseTargetId ~= battery.BatteryId then
			table.remove(ids, i)
			pruned = true
		end
	end
	battery.PointDefenseProviderId = ids[1]
	return pruned
end

--- [BKE] The batteries assigned as point defense of `battery`, in assignment order. Fills and returns `out`.
function Medusa.Services.PointDefenseService.providersOf(battery, batteryStore, out)
	clearTable(out)
	local ids = battery.PointDefenseProviderIds
	if ids and #ids > 0 then
		for i = 1, #ids do
			local provider = batteryStore:get(ids[i])
			if provider then
				out[#out + 1] = provider
			end
		end
	elseif battery.PointDefenseProviderId then
		local provider = batteryStore:get(battery.PointDefenseProviderId)
		if provider then
			out[1] = provider
		end
	end
	return out
end

function Medusa.Services.PointDefenseService.isProviderViable(provider)
	if not provider then
		return false
	end
	if Battery.isIndependentAaa(provider) then
		return false
	end
	if Battery.isCrewSuppressed(provider) then
		return false
	end
	if provider.OperationalStatus ~= BOS.ACTIVE and provider.OperationalStatus ~= BOS.ENGAGEMENT_IMPAIRED then
		return false
	end
	if provider.TotalAmmoStatus <= 0 then
		return false
	end
	return true
end

function Medusa.Services.PointDefenseService.releaseOrphanedDefenders(ctx)
	local batteryStore = ctx.batteryStore
	local batteries = batteryStore:getAll(_pdBatteryBuffer)
	local released = 0
	for i = 1, #batteries do
		local pd = batteries[i]
		-- [BKE] A provider destroyed and removed from the store leaves its id behind: drop it, so the battery it
		-- protected can be given another one.
		if pd.PointDefenseProviderId and pruneMissingProviders(pd, batteryStore) then
			released = released + 1
		end
		if pd.IsPointDefense and pd.PointDefenseTargetId then
			local liege = batteryStore:get(pd.PointDefenseTargetId)
			if
				not Medusa.Services.PointDefenseService.isProviderViable(pd)
				or not Medusa.Services.PointDefenseService.isProviderViable(liege)
			then
				_logger:info(
					string.format(
						"PD %s released: assignment to %s no longer viable",
						pd.GroupName or pd.BatteryId,
						pd.PointDefenseTargetId
					)
				)
				Medusa.Services.PointDefenseService.clearAssignment(pd.BatteryId, batteryStore)
				released = released + 1
			end
		end
	end
	return released
end

-- [BKE] Ties the mission maker set in MEDUSA_CONFIG.PointDefense: { ["<PD group name>"] = "<protected group name>" }.
local _batteryByName = {}
local _tieWarned = {}

--- Reports a tie that cannot be applied, once per group and reason. `isMistake` (a mission-file error) logs at
--- error level; a group not found (destroyed, or not spawned yet) logs at info.
local function reportTieOnce(pdName, message, isMistake)
	local key = pdName .. "|" .. message
	if _tieWarned[key] then
		return
	end
	_tieWarned[key] = true
	local line = string.format("point defense tie for %s ignored: %s", pdName, message)
	if isMistake then
		_logger:error(line)
	else
		_logger:info(line)
	end
end

--- Why the tie cannot be applied now: "warn" with a message for a mission-file mistake, "wait" while either side is
--- down for the moment, nil when it can be applied.
local function tieProblem(pd, target)
	if not PD_ROLES[pd.Role] or Battery.isIndependentAaa(pd) then
		return "warn", "the group is not a short-range SAM or radar-directed AAA"
	end
	if not HVA_ROLES[target.Role] then
		return "warn", string.format("%s is not a medium-, long- or very-long-range SAM", target.GroupName)
	end
	if not pd.Position or not target.Position then
		return "wait"
	end
	if Distance2D(pd.Position, target.Position) > C.POINT_DEFENSE_SEARCH_RADIUS_M then
		return "warn",
			string.format("%s is more than %.0f km away", target.GroupName, C.POINT_DEFENSE_SEARCH_RADIUS_M / 1000)
	end
	-- A battery that lost its search radar can still shoot, and keeps a provider it already has (isProviderViable),
	-- so it can be given its tied one too.
	if
		Battery.isCrewSuppressed(pd)
		or pd.OperationalStatus ~= BOS.ACTIVE
		or (target.OperationalStatus ~= BOS.ACTIVE and target.OperationalStatus ~= BOS.ENGAGEMENT_IMPAIRED)
	then
		return "wait"
	end
	return nil
end

--- Applies the mission maker's ties before nearest-first assignment. A tie wins over an automatic assignment; while
--- either side is down the PD is left to nearest-first, and the tie is applied again on the next reassignment.
local function applyTies(ties, batteries, batteryStore)
	if type(ties) ~= "table" or next(ties) == nil then
		return 0
	end
	clearTable(_batteryByName)
	for i = 1, #batteries do
		local b = batteries[i]
		if b.GroupName then
			_batteryByName[b.GroupName] = b
		end
	end
	local count = 0
	for i = 1, #batteries do
		local pd = batteries[i]
		local targetName = pd.GroupName and ties[pd.GroupName]
		if targetName then
			local target = _batteryByName[targetName]
			if not target then
				reportTieOnce(pd.GroupName, string.format("no battery named %s", tostring(targetName)), false)
			elseif target ~= pd and pd.PointDefenseTargetId ~= target.BatteryId then
				local problem, message = tieProblem(pd, target)
				if problem == "warn" then
					reportTieOnce(pd.GroupName, message, true)
				elseif problem == nil then
					if
						Medusa.Services.PointDefenseService.setAssignment(pd.BatteryId, target.BatteryId, batteryStore)
					then
						count = count + 1
					end
				end
			end
		end
	end
	-- A PD group named in a tie that is not a battery (misspelled, destroyed, or not spawned yet).
	for pdName in pairs(ties) do
		if not _batteryByName[pdName] then
			reportTieOnce(pdName, "no battery with that name", false)
		end
	end
	clearTable(_batteryByName)
	return count
end

function Medusa.Services.PointDefenseService.autoAssignShorad(ctx)
	local batteryStore = ctx.batteryStore
	local geoGrid = ctx.geoGrid
	local batteries = batteryStore:getAll(_pdBatteryBuffer)
	local ties = ctx.pointDefenseTies
	if ties == nil and Medusa.Config and Medusa.Config.getPointDefenseTies then
		ties = Medusa.Config:getPointDefenseTies()
	end
	local assignCount = applyTies(ties, batteries, batteryStore)
	for i = 1, #batteries do
		local pd = batteries[i]
		if
			PD_ROLES[pd.Role]
			and not Battery.isIndependentAaa(pd)
			and not Battery.isCrewSuppressed(pd)
			and pd.OperationalStatus == BOS.ACTIVE
			and pd.Position
			and not pd.IsPointDefense
		then
			local nearby = Medusa.Services.SpatialQuery.batteriesInRadius(
				geoGrid,
				batteryStore,
				pd.Position,
				C.POINT_DEFENSE_SEARCH_RADIUS_M
			)
			local bestDist = math.huge
			local bestId = nil
			for j = 1, #nearby do
				local hva = nearby[j]
				if
					HVA_ROLES[hva.Role]
					and hva.OperationalStatus == BOS.ACTIVE
					and hva.Position
					and not hva.PointDefenseProviderId
				then
					local dist = Distance2D(pd.Position, hva.Position)
					if dist < bestDist then
						bestDist = dist
						bestId = hva.BatteryId
					end
				end
			end
			if bestId then
				Medusa.Services.PointDefenseService.setAssignment(pd.BatteryId, bestId, batteryStore)
				assignCount = assignCount + 1
			end
		end
	end
	return assignCount
end

local computeTrackCPA = Medusa.Services.HarmDetectionService.computeTrackCPA

local function tryActivatePd(provider, harmTrack, protectedLabel, now)
	if not Medusa.Services.PointDefenseService.isProviderViable(provider) then
		return false
	end
	if provider.ActivationState == AS.STATE_HOT then
		return false
	end
	if provider.CurrentTargetTrackId then
		return false
	end
	if not provider.Position or not provider.EngagementRangeMax then
		return false
	end
	local cpaDist = computeTrackCPA(harmTrack, provider.Position)
	if cpaDist > provider.EngagementRangeMax then
		return false
	end
	Medusa.Entities.Battery.assignTrack(provider, harmTrack, now)
	BatteryActivationService.forceGoHot(provider, now, "point_defence_vs_arm")
	_logger:info(
		string.format(
			"PD %s activated for HARM track %s (protecting %s)",
			provider.GroupName or provider.BatteryId,
			Medusa.Entities.Track.displayId(harmTrack),
			protectedLabel
		)
	)
	return true
end

function Medusa.Services.PointDefenseService.activateForHarm(harmTrack, geoGrid, batteryStore, now, doctrine)
	if not harmTrack.Position then
		return 0
	end
	local vel = harmTrack.SmoothedVelocity or harmTrack.Velocity
	if not vel then
		return 0
	end

	local defendPk = (doctrine and doctrine.DefendPk) or 0.30
	local activated = 0
	clearTable(_harmActivationBuffer)

	-- Pass 1: activate assigned PD for batteries directly threatened by the HARM (no Pk gate)
	local batteries = batteryStore:getAll(_pdBatteryBuffer)
	for i = 1, #batteries do
		local battery = batteries[i]
		if battery.PointDefenseProviderId and battery.Position then
			local cpaDist = computeTrackCPA(harmTrack, battery.Position)
			if cpaDist < C.HARM_DEFAULT_THREAT_RADIUS_M then
				local providers =
					Medusa.Services.PointDefenseService.providersOf(battery, batteryStore, _providerBuffer)
				for p = 1, #providers do
					local provider = providers[p]
					if not _harmActivationBuffer[provider.BatteryId] then
						if tryActivatePd(provider, harmTrack, battery.GroupName or battery.BatteryId, now) then
							_harmActivationBuffer[provider.BatteryId] = true
							activated = activated + 1
						end
					end
				end
			end
		end
	end

	-- Pass 2: any battery along the flight path that can intercept with Pk >= DefendPk
	local searchRadius = C.POINT_DEFENSE_SEARCH_RADIUS_M
	local nearby =
		Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, harmTrack.Position, searchRadius)
	for i = 1, #nearby do
		local battery = nearby[i]
		if
			battery.EngagementRangeMax
			and battery.EngagementRangeMax > 0
			and battery.Position
			and not _harmActivationBuffer[battery.BatteryId]
			and not battery.CurrentTargetTrackId
			and not battery.HarmShutdownUntil
			and battery.ActivationState ~= AS.STATE_HOT
			and Medusa.Services.PointDefenseService.isProviderViable(battery)
			and (battery.IsPointDefense or battery.HarmCapableUnitCount > 0)
		then
			local cpaDist = computeTrackCPA(harmTrack, battery.Position)
			if cpaDist < battery.EngagementRangeMax then
				local pk = Medusa.Services.PkModel.computePk(battery, harmTrack, cpaDist)
				if pk < defendPk then
					_logger:debug(
						string.format(
							"battery %s skipped HARM intercept (Pk=%.2f < %.2f, CPA=%.0fm)",
							battery.GroupName or battery.BatteryId,
							pk,
							defendPk,
							cpaDist
						)
					)
				else
					Medusa.Entities.Battery.assignTrack(battery, harmTrack, now)
					if BatteryActivationService.forceGoHot(battery, now, "self_defence_vs_arm") then
						_harmActivationBuffer[battery.BatteryId] = true
						activated = activated + 1
						_logger:info(
							string.format(
								"battery %s HOT for HARM intercept (Pk=%.2f, CPA=%.0fm)",
								battery.GroupName or battery.BatteryId,
								pk,
								cpaDist
							)
						)
					else
						battery.CurrentTargetTrackId = nil
						harmTrack.AssignedBatteryIds:remove(battery.BatteryId)
					end
				end
			end
		end
	end

	return activated
end

--- A released store whose ARM confirmation is held back (unpowered, or still watched for a motor:
--- HarmDetectionService.confirmBlock) that is predicted to reach the ground within GLIDE_THREAT_RADIUS_M of `pos`
--- (the site point defense protects): it is a munition falling on the site, so point defense still engages it.
function Medusa.Services.PointDefenseService.storeFallsOn(track, pos)
	if not track.Release then
		return false
	end
	local block = Medusa.Services.HarmDetectionService.confirmBlock(track)
	return (block == "unpowered" or block == "window")
		and Medusa.Services.DecoyAssessmentService.impactThreatens(track, pos)
end

function Medusa.Services.PointDefenseService.engageThreats(ctx)
	local trackStore = ctx.trackStore
	local batteryStore = ctx.batteryStore
	local geoGrid = ctx.geoGrid
	local now = ctx.now
	local batteries = batteryStore:getAll(_pdBatteryBuffer)
	local engageCount = 0
	for i = 1, #batteries do
		local protected = batteries[i]
		local providers = protected.PointDefenseProviderId
				and Medusa.Services.PointDefenseService.providersOf(protected, batteryStore, _providerBuffer)
			or _noProviders
		for p = 1, #providers do
			local provider = providers[p]
			if
				Medusa.Services.PointDefenseService.isProviderViable(provider)
				and not provider.CurrentTargetTrackId
				and provider.EngagementRangeMax
			then
				local results = geoGrid:queryRadius(provider.Position, provider.EngagementRangeMax, { "Track" })
				local trackIds = results.TrackIds
				if trackIds then
					local bestDist = math.huge
					local bestTrack = nil
					for trackId in pairs(trackIds) do
						local track = trackStore:get(trackId)
						if
							track
							and track.LifecycleState == LS.ACTIVE
							and (
								track.AssessedAircraftType == AAT.HARM
								or track.IsSeadThreat
								or Medusa.Services.DecoyAssessmentService.glideThreatens(track, protected.Position)
								or Medusa.Services.PointDefenseService.storeFallsOn(track, protected.Position)
							)
						then
							local dist = Distance2D(track.Position, provider.Position)
							if dist <= provider.EngagementRangeMax and dist < bestDist then
								bestDist = dist
								bestTrack = track
							end
						end
					end
					if bestTrack then
						Medusa.Entities.Battery.assignTrack(provider, bestTrack, now)
						BatteryActivationService.forceGoHot(provider, now, "point_defence")
						_logger:info(
							string.format(
								"PD %s engaging %s to defend %s",
								provider.BatteryId,
								Medusa.Entities.Track.displayId(bestTrack),
								protected.BatteryId
							)
						)
						engageCount = engageCount + 1
					end
				end
			end
		end
	end
	return engageCount
end
