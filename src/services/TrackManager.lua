require("_header")
require("services.Services")
require("services.stores.TrackStore")
require("services.TrackDisplayIdAllocator")
require("services.TrackReacquisition")
require("entities.Track")
require("core.Constants")
require("core.Config")
require("core.Logger")

--[[
            ████████╗██████╗  █████╗  ██████╗██╗  ██╗    ███╗   ███╗ █████╗ ███╗   ██╗ █████╗  ██████╗ ███████╗██████╗
            ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝    ████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔════╝ ██╔════╝██╔══██╗
               ██║   ██████╔╝███████║██║     █████╔╝     ██╔████╔██║███████║██╔██╗ ██║███████║██║  ███╗█████╗  ██████╔╝
               ██║   ██╔══██╗██╔══██║██║     ██╔═██╗     ██║╚██╔╝██║██╔══██║██║╚██╗██║██╔══██║██║   ██║██╔══╝  ██╔══██╗
               ██║   ██║  ██║██║  ██║╚██████╗██║  ██╗    ██║ ╚═╝ ██║██║  ██║██║ ╚████║██║  ██║╚██████╔╝███████╗██║  ██║
               ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝

    What this service does
    - Creates new tracks from sensor reports and updates existing tracks with fresh position and velocity.
    - Manages track lifecycle: marks tracks as stale after a timeout and expires them after the memory window.
    - Re-acquires lost tracks: with doctrine EvidenceReacquisition (default) a new contact continues a recently
      dropped track when it is where that track should be and flies as it should (TrackReacquisition), whatever DCS
      object it is; off, a dropped track comes back only for the same DCS object near its old position.

    How others use it
    - SensorPollingService feeds track reports into processReport; IadsNetwork calls expireTracks each tick.
    - TrackStore and the GeoGrid are updated automatically as tracks are created, moved, or removed.
--]]

Medusa.Services.TrackManager = {}

function Medusa.Services.TrackManager:new(opts)
	local o = {
		_store = (opts and opts.store) or Medusa.Services.TrackStore:new(),
		_eventBus = (opts and opts.eventBus) or EventBus(),
		_geoGrid = (opts and opts.geoGrid) or nil,
		_byNetworkId = {},
		_dormant = {},
		-- Evidence-based re-acquisition: dropped tracks by their TrackId, on their own grid at their last position.
		_evidenceReacquisition = not (opts and opts.evidenceReacquisition == false),
		_lost = {},
		_lostGrid = GeoGrid(Medusa.Constants.Reacquisition.GRID_CELL_M, { "Lost" }),
		_lostMaxSpeed = 0,
		_lostOldestTime = nil,
		_candidates = {},
		_candidateScores = {},
		_tied = {},
		_logger = Medusa.Logger:ns("TrackManager"),
		_pruneBuffer = {},
		_staleBuffer = {},
		_expiredBuffer = {},
		_displayIdAllocator = (opts and opts.displayIdAllocator) or Medusa.Services.TrackDisplayIdAllocator:new(),
		_trackMemoryDurationSec = Medusa.Config:getTrackMemoryDurationSec(),
		_smoothedVelocityWindowSec = Medusa.Config:getSmoothedVelocityWindowSec(),
	}
	setmetatable(o, { __index = self })
	return o
end

--- Doctrine EvidenceReacquisition: true = re-acquire lost tracks by evidence, false = by DCS object id (stock).
function Medusa.Services.TrackManager:setEvidenceReacquisition(on)
	self._evidenceReacquisition = on ~= false
end

function Medusa.Services.TrackManager:_releaseDisplayIds(track)
	if track.DisplayTrackId then
		self._displayIdAllocator:release(track.DisplayTrackId)
	end
	local aliases = track.DisplayTrackIdAliases or {}
	for i = 1, #aliases do
		self._displayIdAllocator:release(aliases[i])
	end
end

function Medusa.Services.TrackManager:processReport(report, now)
	if
		not report
		or not report.NetworkId
		or not Medusa.Constants.TrackSourcePrefix[report.SourceType]
		or not report.Position
		or not report.Velocity
	then
		self._logger:error("processReport: invalid report (missing required fields)")
		return nil
	end

	now = now or GetTime()
	local existingTrackId = self._byNetworkId[report.NetworkId]

	if existingTrackId then
		return self:_updateExistingTrack(existingTrackId, report, now)
	end
	if self._evidenceReacquisition then
		return self:_acquire(report, now)
	end

	-- Check dormant cache for re-association
	local dormant = self._dormant[report.NetworkId]
	if dormant and dormant.Position then
		local dx = report.Position.x - dormant.Position.x
		local dy = report.Position.y - dormant.Position.y
		local dz = report.Position.z - dormant.Position.z
		local lastPositionError = math.sqrt(dx * dx + dy * dy + dz * dz)
		local elapsed = now - dormant.LastDetectionTime
		local predictedX = dormant.Position.x + dormant.Velocity.x * elapsed
		local predictedY = dormant.Position.y + dormant.Velocity.y * elapsed
		local predictedZ = dormant.Position.z + dormant.Velocity.z * elapsed
		dx = report.Position.x - predictedX
		dy = report.Position.y - predictedY
		dz = report.Position.z - predictedZ
		local predictedPositionError = math.sqrt(dx * dx + dy * dy + dz * dz)
		if math.min(lastPositionError, predictedPositionError) < Medusa.Constants.TRACK_REASSOC_MAX_DIST_M then
			self._dormant[report.NetworkId] = nil
			return self:_reassociateTrack(report, dormant, now)
		end
		self:_releaseDisplayIds(dormant)
		self._logger:debug(
			string.format(
				"dormant re-association failed for network %s: lastError=%.0fm predictedError=%.0fm > %dm",
				tostring(report.NetworkId),
				lastPositionError,
				predictedPositionError,
				Medusa.Constants.TRACK_REASSOC_MAX_DIST_M
			)
		)
		self._dormant[report.NetworkId] = nil
	end

	return self:_createNewTrack(report, now, self:_launchCue(report.Position, report.Velocity, now))
end

function Medusa.Services.TrackManager:_registerTrack(track, networkId, now)
	-- Every track made here (new, re-acquired, re-associated) gets its own release check, unless it carried an
	-- unpowered mark across a sure re-acquisition.
	if not track.Release then
		self:_linkRelease(track, now)
	end
	self._store:add(track)
	if self._geoGrid and track.Position then
		self._geoGrid:add("Track", track.TrackId, track.Position)
	end
	self._byNetworkId[networkId] = track.TrackId
	self._eventBus:publish({ id = "TrackCreated", TrackId = track.TrackId, timestamp = now })
end

-- Launch cue: a new contact that appears close to an older one and is already pulling away from it fast (a rocket
-- motor) is what an operator sees when a missile leaves an aircraft. Generic physics, no weapon table. Measured on
-- recorded DCS launches: every ARM type flown (AGM-88, AGM-45, AGM-122, ALARM, Kh-25MP, Kh-31P, Kh-58; 125 shots)
-- shows it 2-3 s after launch and still 10 s after, within 4 km; gliding and jet-powered weapons (TALD, JSOW,
-- SLAM-ER, ALCM) never do, so they are left to the other evidence. Wingmen stay within ~50 m/s of each other. The
-- heading test only rules out opposite headings (crossing jets): launchers often turn away after the shot.
Medusa.Services.TrackManager.LAUNCH_CUE_RADIUS_M = 6000
Medusa.Services.TrackManager.LAUNCH_CUE_MIN_OPENING_MPS = 120
Medusa.Services.TrackManager.LAUNCH_CUE_MIN_PARENT_AGE_SEC = 10
Medusa.Services.TrackManager.LAUNCH_CUE_MIN_HEADING_COS = 0
local LAUNCH_CUE_FILTER = { "Track" }

function Medusa.Services.TrackManager:_launchCue(p, v, now)
	local grid = self._geoGrid
	if not grid or not p or not v then
		return nil
	end
	local TM = Medusa.Services.TrackManager
	local result = grid:queryRadius(p, TM.LAUNCH_CUE_RADIUS_M, LAUNCH_CUE_FILTER)
	local ids = result and result.TrackIds
	if not ids then
		return nil
	end
	local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	for id in pairs(ids) do
		local other = self._store:get(id)
		local op, ov = other and other.Position, other and other.Velocity
		if op and ov and now - (other.FirstDetectionTime or now) >= TM.LAUNCH_CUE_MIN_PARENT_AGE_SEC then
			local rx, ry, rz = p.x - op.x, p.y - op.y, p.z - op.z
			local dist = math.sqrt(rx * rx + ry * ry + rz * rz)
			local ospeed = math.sqrt(ov.x * ov.x + ov.y * ov.y + ov.z * ov.z)
			if dist > 1 and ospeed > 1 and speed > 1 then
				local opening = (rx * (v.x - ov.x) + ry * (v.y - ov.y) + rz * (v.z - ov.z)) / dist
				local cosHeading = (v.x * ov.x + v.y * ov.y + v.z * ov.z) / (speed * ospeed)
				if opening > TM.LAUNCH_CUE_MIN_OPENING_MPS and cosHeading > TM.LAUNCH_CUE_MIN_HEADING_COS then
					return { FromTrackId = other.TrackId, Time = now }
				end
			end
		end
	end
	return nil
end

-- Released store: a contact first seen just below an aircraft, close to it and moving with it, may be something that
-- aircraft has just dropped (Medusa.Constants.Release), launch cue or not (a cue does not make a bomb powered; a
-- missile's motor shows in its energy within a few looks). The carrier needs positive aircraft evidence (a confident
-- aircraft-sized return or a crew sighting), so a weapon track is no carrier, and the contact must sit where a store
-- released in the last few seconds would be, so a burnt-out ARM coasting past a jet is rarely linked. Link it to the
-- nearest such carrier with the carrier's reference energy (the most it had over its recent history); the track's own
-- looks then show whether it has a motor (Track.observeRelease). HarmDetectionService does not confirm a linked or
-- unpowered track as an ARM. Searched once, when the track is made; carriers' last looks are dead-reckoned to now.
-- A carrier later confirmed as an ARM (or typed HARM) that was young when the link was made and has since lost its
-- aircraft evidence may have been an ARM all along: its children's links and marks are dropped. An old carrier, or
-- one still with aircraft evidence, frees nothing (a diving jet or the first bomb of a stick confirmed in error).
-- SUSPECT or PROBABLE is not enough: a falling bomb routinely flies like that. A carrier that was dropped and
-- re-acquired under a new TrackId frees nothing either; its children stay held (fails safe: they can still be
-- PROBABLE).
local ARM_LIKE_LABELS = {
	[Medusa.Constants.HarmAssessmentState.SUSPECT] = true,
	[Medusa.Constants.HarmAssessmentState.PROBABLE] = true,
	[Medusa.Constants.HarmAssessmentState.CONFIRMED] = true,
}

--- An ARM-like track (SUSPECT or more, or typed HARM) can be no carrier.
function Medusa.Services.TrackManager._carrierArmLike(o)
	local h = o.HarmAssessment
	return o.AssessedAircraftType == Medusa.Constants.AssessedAircraftType.HARM
		or (h ~= nil and ARM_LIKE_LABELS[h.label] == true)
end

--- A carrier confirmed as an ARM (or typed HARM).
function Medusa.Services.TrackManager._carrierIsArm(o)
	local h = o.HarmAssessment
	return o.AssessedAircraftType == Medusa.Constants.AssessedAircraftType.HARM
		or (h ~= nil and h.label == Medusa.Constants.HarmAssessmentState.CONFIRMED)
end

--- Positive aircraft evidence: a confident aircraft-sized return, or a crew saw an aircraft or helicopter.
local function looksLikeAircraft(o)
	local seen = o.SeenAs
	return seen == Medusa.Constants.SeenAs.AIRCRAFT
		or seen == Medusa.Constants.SeenAs.HELICOPTER
		or Medusa.Entities.Track.sizeClass(o) == "large"
end

--- The carrier of `release` may have been an ARM all along, so its child is freed: it is one now, was young when the
--- link was made, and has lost the aircraft evidence it was linked on (its size estimate no longer aircraft-sized, or
--- a crew has since seen it as a munition).
function Medusa.Services.TrackManager._carrierFrees(carrier, release)
	return (release.CarrierAge or 0) < Medusa.Constants.Release.FREE_MAX_CARRIER_AGE_SEC
		and not looksLikeAircraft(carrier)
		and Medusa.Services.TrackManager._carrierIsArm(carrier)
end

function Medusa.Services.TrackManager:_linkRelease(track, now)
	track.Release = nil
	local grid = self._geoGrid
	local p, v = track.Position, track.Velocity
	if not grid or not p or not v then
		return
	end
	local armLike = Medusa.Services.TrackManager._carrierArmLike
	local R = Medusa.Constants.Release
	local LS = Medusa.Constants.TrackLifecycleState
	local Track = Medusa.Entities.Track
	local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	-- A carrier within reach now was at most its look age of travel (its speed: within PARENT_MAX_DV_MPS of ours)
	-- from where the grid holds it.
	local reach = R.PARENT_RADIUS_M + (speed + R.PARENT_MAX_DV_MPS) * R.PARENT_MAX_LOOK_AGE_SEC
	local result = grid:queryRadius(p, reach, LAUNCH_CUE_FILTER)
	local ids = result and result.TrackIds
	if not ids then
		return
	end
	local best, bestSq = nil, R.PARENT_RADIUS_M * R.PARENT_RADIUS_M
	local maxDvSq = R.PARENT_MAX_DV_MPS * R.PARENT_MAX_DV_MPS
	for id in pairs(ids) do
		local o = id ~= track.TrackId and self._store:get(id)
		local op, ov = o and o.Position, o and o.Velocity
		local age = o and now - o.LastDetectionTime
		if
			op
			and ov
			and o.LifecycleState == LS.ACTIVE
			and now - (o.FirstDetectionTime or now) >= R.PARENT_MIN_AGE_SEC
			and age >= 0
			and age <= R.PARENT_MAX_LOOK_AGE_SEC
			and not o.LaunchCue
			and not armLike(o)
			and looksLikeAircraft(o)
		then
			local dvx, dvy, dvz = v.x - ov.x, v.y - ov.y, v.z - ov.z
			local rx, ry, rz = p.x - (op.x + ov.x * age), p.y - (op.y + ov.y * age), p.z - (op.z + ov.z * age)
			-- A store falls: never well above its carrier.
			if dvx * dvx + dvy * dvy + dvz * dvz <= maxDvSq and ry <= R.PARENT_MAX_RISE_M then
				local dSq = rx * rx + ry * ry + rz * rz
				if dSq < bestSq then
					best, bestSq = o, dSq
				end
			end
		end
	end
	if not best then
		return
	end
	local refE = Track.maxEnergyHeight(best, R.PARENT_ENERGY_WINDOW_SEC, now)
		or Track.energyHeight(best.Position, best.Velocity)
	if Track.energyHeight(p, v) - refE > R.POWERED_GAIN_M then
		return -- already well above anything its carrier had: a motor
	end
	track.Release = {
		RefE = refE,
		Since = now,
		LastTime = now,
		Looks = 1,
		Unpowered = false,
		CarrierId = best.TrackId,
		CarrierAge = now - best.FirstDetectionTime,
	}
	self._logger:info(
		string.format(
			"track %s appeared beside track %s (%.0f m): no ARM confirmation until it shows a motor",
			Track.displayId(track),
			Track.displayId(best),
			math.sqrt(bestSq)
		)
	)
end

function Medusa.Services.TrackManager:_createNewTrack(report, now, launchCue)
	local displayTrackId = self._displayIdAllocator:allocate(report.SourceType)
	local track = Medusa.Entities.Track.new({
		NetworkId = report.NetworkId,
		DisplayTrackId = displayTrackId,
		OriginSourceType = report.SourceType,
		Position = report.Position,
		Velocity = report.Velocity,
	})
	-- The first sighting is history too: rate checks (HARM detection, smoothing) can start on the second.
	track.PositionHistory:push({
		timestamp = now,
		position = { x = report.Position.x, y = report.Position.y, z = report.Position.z },
		velocity = { x = report.Velocity.x, y = report.Velocity.y, z = report.Velocity.z },
	})
	track.LaunchCue = launchCue
	Medusa.Entities.Track.observeEvidence(track, report, now)
	self:_registerTrack(track, report.NetworkId, now)
	Medusa.Services.MetricsService.inc("medusa_tracks_created_total")
	self._logger:debug(
		string.format(
			"created track %s for network %s",
			Medusa.Entities.Track.displayId(track),
			tostring(report.NetworkId)
		)
	)
	return track
end

--- The sensor that first made a track stays with it when it is re-acquired or re-associated: the network
--- detected it before (no new FIRST_DETECTION debrief line), and its IDENTIFIED line names that first sensor.
local function carryFirstSeen(track, from)
	track.FirstSeenBy = from.FirstSeenBy
	track.FirstSeenKind = from.FirstSeenKind
	track.FirstSeenRangeM = from.FirstSeenRangeM
end

function Medusa.Services.TrackManager:_reassociateTrack(report, dormant, now)
	local track = Medusa.Entities.Track.new({
		NetworkId = report.NetworkId,
		DisplayTrackId = dormant.DisplayTrackId,
		DisplayTrackIdAliases = dormant.DisplayTrackIdAliases,
		OriginSourceType = dormant.OriginSourceType,
		Position = report.Position,
		Velocity = report.Velocity,
		TrackIdentification = dormant.TrackIdentification,
		AssessedAircraftType = dormant.AssessedAircraftType,
		LastIdentificationTime = dormant.LastIdentificationTime,
		HarmAssessment = dormant.HarmAssessment,
		HarmLikelihoodScore = dormant.HarmLikelihoodScore,
		IsSeadThreat = dormant.IsSeadThreat,
		LaunchCue = dormant.LaunchCue,
		DecoyAssessment = dormant.DecoyAssessment,
		SizeDb = dormant.SizeDb,
		SizeWeight = dormant.SizeWeight,
		SizeSpreadDb = dormant.SizeSpreadDb,
		SeenAs = dormant.SeenAs,
		SeenAsTime = dormant.SeenAsTime,
	})
	carryFirstSeen(track, dormant)
	Medusa.Entities.Track.carryUnpowered(track, dormant.Release)
	track.PositionHistory:push({
		timestamp = now,
		position = { x = report.Position.x, y = report.Position.y, z = report.Position.z },
		velocity = { x = report.Velocity.x, y = report.Velocity.y, z = report.Velocity.z },
	})
	Medusa.Entities.Track.observeEvidence(track, report, now)
	local harm = track.HarmAssessment
	if harm then
		-- A confirmed ARM's "not attacking" window must not span the time the track was lost.
		harm.disproofSince = nil
		harm.disproofScans = 0
	end
	local decoy = track.DecoyAssessment
	if decoy then
		-- A decoy's straight leg must not span the gap either; its label and launch evidence stay (sticky).
		decoy.runSince = nil
		decoy.runSec = 0
		decoy.disproofScans = 0
	end
	self:_registerTrack(track, report.NetworkId, now)
	self._logger:info(
		string.format(
			"re-associated track %s for network %s (was %s/%s)",
			Medusa.Entities.Track.displayId(track),
			tostring(report.NetworkId),
			tostring(dormant.TrackIdentification),
			tostring(dormant.AssessedAircraftType)
		)
	)
	return track
end

-- ── Evidence-based re-acquisition ─────────────────────────────────

local LOST_FILTER = { "Lost" }

function Medusa.Services.TrackManager:_addLost(e)
	self._lost[e.TrackId] = e
	self._lostGrid:add("Lost", e.TrackId, e.Position)
	if e.Speed > self._lostMaxSpeed then
		self._lostMaxSpeed = e.Speed
	end
	if not self._lostOldestTime or e.Time < self._lostOldestTime then
		self._lostOldestTime = e.Time
	end
end

function Medusa.Services.TrackManager:_removeLost(e)
	self._lost[e.TrackId] = nil
	self._lostGrid:remove(e.TrackId)
end

--- Forget lost tracks older than TRACK_REASSOC_TTL_SEC and refresh the query's bounds (fastest speed, oldest look).
--- Run once a second (pruneStale); _scoreLost skips an entry past its time in between.
function Medusa.Services.TrackManager:_evictLost(now)
	self._lostSweptAt = now
	local maxSpeed, oldest = 0, nil
	for id, e in pairs(self._lost) do
		if now - e.expiredAt > Medusa.Constants.TRACK_REASSOC_TTL_SEC then
			self:_releaseDisplayIds(e)
			self._lost[id] = nil
			self._lostGrid:remove(id)
		else
			if e.Speed > maxSpeed then
				maxSpeed = e.Speed
			end
			if not oldest or e.Time < oldest then
				oldest = e.Time
			end
		end
	end
	self._lostMaxSpeed, self._lostOldestTime = maxSpeed, oldest
end

--- Score the lost tracks within the gate of a new contact. Returns the best fit and its score, and the number of
--- lost tracks that tie with it (its score is under MARGIN times theirs), listed in
--- self._tied with the best first. 0 when no lost track fits. The grid query reaches as far as the widest gate
--- (fastest lost track, oldest look); each lost track is then scored only within its own gate.
function Medusa.Services.TrackManager:_scoreLost(report, now, cue)
	if not self._lostOldestTime then
		return nil, 0, 0
	end
	local RQ = Medusa.Constants.Reacquisition
	local Svc = Medusa.Services.TrackReacquisition
	local p, v = report.Position, report.Velocity
	local radius = Svc.gateRadius(self._lostMaxSpeed, now - self._lostOldestTime)
	local ids = self._lostGrid:queryRadius(p, radius, LOST_FILTER).LostIds
	local cands, scores, n = self._candidates, self._candidateScores, 0
	local best, bestScore = nil, 0
	local ttl = Medusa.Constants.TRACK_REASSOC_TTL_SEC
	for id in pairs(ids or {}) do
		local e = self._lost[id]
		local within = false
		if e and now - e.expiredAt <= ttl then
			local gate = Svc.gateRadius(e.Speed, now - e.Time)
			local dx, dz = p.x - e.Position.x, p.z - e.Position.z
			within = dx * dx + dz * dz <= gate * gate
		end
		if within and Svc.mayInherit(e, v, cue, now) then
			local s = Svc.score(e, p, v, now)
			n = n + 1
			cands[n], scores[n] = e, s
			if s > bestScore then
				best, bestScore = e, s
			end
		end
	end
	self._candidateCount = n
	if not best or bestScore < RQ.SCORE_THRESHOLD then
		return nil, 0, 0
	end
	local tiedList, tied = self._tied, 1
	tiedList[1] = best
	for i = 1, n do
		if cands[i] ~= best and scores[i] * RQ.MARGIN > bestScore then
			tied = tied + 1
			tiedList[tied] = cands[i]
		end
	end
	return best, bestScore, tied
end

--- A contact that is not a held track: continue a lost track that it fits clearly, carry a tie's shared label
--- onto a new track, or start a new track.
function Medusa.Services.TrackManager:_acquire(report, now)
	local cue = self:_launchCue(report.Position, report.Velocity, now)
	local best, score, tied = self:_scoreLost(report, now, cue)
	if tied == 1 then
		return self:_reacquireTrack(report, best, score, now, cue)
	end
	local track = self:_createNewTrack(report, now, cue)
	if tied > 1 then
		self:_resolveTie(track, report, best, score, tied, now)
	end
	return track
end

function Medusa.Services.TrackManager:_reacquireTrack(report, e, score, now, cue)
	self:_removeLost(e)
	local track = Medusa.Entities.Track.new({
		NetworkId = report.NetworkId,
		DisplayTrackId = e.DisplayTrackId,
		DisplayTrackIdAliases = e.DisplayTrackIdAliases,
		OriginSourceType = e.OriginSourceType,
		Position = report.Position,
		Velocity = report.Velocity,
		FirstDetectionTime = e.FirstDetectionTime,
		LaunchCue = cue,
	})
	track.PositionHistory:push({
		timestamp = now,
		position = { x = report.Position.x, y = report.Position.y, z = report.Position.z },
		velocity = { x = report.Velocity.x, y = report.Velocity.y, z = report.Velocity.z },
	})
	carryFirstSeen(track, e)
	local carried = Medusa.Services.TrackReacquisition.carry(track, e, score, now)
	Medusa.Entities.Track.observeEvidence(track, report, now)
	self:_registerTrack(track, report.NetworkId, now)
	self._logger:info(
		string.format(
			"re-acquired track %s as new contact %s (gap %.0fs, score %.2f, carried: %s)",
			Medusa.Entities.Track.displayId(track),
			tostring(report.NetworkId),
			now - e.Time,
			score,
			carried
		)
	)
	return track
end

--- Several lost tracks fit a new contact about equally well. Lost tracks of one class (all confirmed ARMs, all
--- probable decoys) hand on the label they share, at the weakest confidence among them, and the best fit is used
--- up (so a flock cannot label more contacts than it had members); a mixed tie hands on nothing.
function Medusa.Services.TrackManager:_resolveTie(track, report, best, score, tied, now)
	local Svc = Medusa.Services.TrackReacquisition
	local cands = self._tied
	local class = Svc.sharedClass(cands, tied, now)
	local names = {}
	for i = 1, tied do
		names[i] = Medusa.Entities.Track.displayId(cands[i])
	end
	if not class then
		self._logger:info(
			string.format(
				"re-acquisition refused for new contact %s: %d lost tracks fit within %gx (%s, best %.2f) and do not share a label; new track %s",
				tostring(report.NetworkId),
				tied,
				Medusa.Constants.Reacquisition.MARGIN,
				table.concat(names, " "),
				score,
				Medusa.Entities.Track.displayId(track)
			)
		)
		return
	end
	-- A lost track of another kind that fits within MARGIN squared (outside the tie, but near) weakens a decoy label.
	local mixedNear = false
	local margin2 = Medusa.Constants.Reacquisition.MARGIN ^ 2
	for i = 1, self._candidateCount do
		local e = self._candidates[i]
		if self._candidateScores[i] * margin2 > score and not Svc.isProbableDecoy(e) then
			mixedNear = true
		end
	end
	local carried = Svc.carryTie(track, cands, tied, class, now, mixedNear)
	self:_removeLost(best)
	self:_releaseDisplayIds(best)
	self._logger:info(
		string.format(
			"re-acquisition tie for new contact %s: %d lost tracks fit within %gx (%s, best %.2f); new track %s, carried: %s",
			tostring(report.NetworkId),
			tied,
			Medusa.Constants.Reacquisition.MARGIN,
			table.concat(names, " "),
			score,
			Medusa.Entities.Track.displayId(track),
			carried
		)
	)
end

function Medusa.Services.TrackManager:_updateExistingTrack(trackId, report, now)
	local track = self._store:get(trackId)
	if not track then
		self._byNetworkId[report.NetworkId] = nil
		return self:_createNewTrack(report, now, self:_launchCue(report.Position, report.Velocity, now))
	end

	-- Order matters: update must precede smoothing, smoothing must precede maneuver derivation.
	-- SmoothedVelocity feeds Pk aspect calculation; ManeuverState feeds aircraft type classification.
	Medusa.Entities.Track.update(track, report.Position, report.Velocity, now)
	Medusa.Entities.Track.observeEvidence(track, report, now)
	local release = track.Release
	if release then
		local carrier = self._store:get(release.CarrierId)
		if carrier and Medusa.Services.TrackManager._carrierFrees(carrier, release) then
			track.Release = nil
			self._logger:info(
				string.format(
					"track %s: its carrier %s was an ARM, so it was no released store",
					Medusa.Entities.Track.displayId(track),
					Medusa.Entities.Track.displayId(carrier)
				)
			)
		end
	end
	if track.Release then
		local decided = Medusa.Entities.Track.observeRelease(track, now)
		if decided then
			self._logger:info(
				string.format(
					decided == "powered"
							and "track %s gained energy no carrier gave it: a motor, ARM confirmation allowed"
						or "track %s shows no motor: a released store, not confirmed as an ARM unless a motor shows",
					Medusa.Entities.Track.displayId(track)
				)
			)
		end
	end
	if self._geoGrid then
		self._geoGrid:updatePosition(track.TrackId, track.Position, "Track")
	end

	local windowSec = self._smoothedVelocityWindowSec
	Medusa.Entities.Track.computeSmoothedVelocity(track, windowSec)
	Medusa.Entities.Track.deriveManeuverState(track)

	-- One event per track update: build it only when something listens (the harness bus keeps `_subscribers`).
	local subscribers = self._eventBus._subscribers
	if subscribers and not subscribers.TrackUpdated then
		return track
	end
	self._eventBus:publish({
		id = "TrackUpdated",
		TrackId = track.TrackId,
		Position = track.Position,
		Velocity = track.Velocity,
		timestamp = now,
	})
	return track
end

function Medusa.Services.TrackManager:_remapNetworkIdMappings(fromTrackId, toTrackId)
	for networkId, mappedTrackId in pairs(self._byNetworkId) do
		if mappedTrackId == fromTrackId then
			self._byNetworkId[networkId] = toTrackId
		end
	end
end

function Medusa.Services.TrackManager:pruneStale(now)
	local thresholdSec = self._trackMemoryDurationSec
	local cutoff = now - thresholdSec
	local tracks = self._store:getAll(self._pruneBuffer)

	local staleIds = self._staleBuffer
	for i = #staleIds, 1, -1 do
		staleIds[i] = nil
	end
	local expiredIds = self._expiredBuffer
	for i = #expiredIds, 1, -1 do
		expiredIds[i] = nil
	end
	local LS = Medusa.Constants.TrackLifecycleState

	for i = 1, #tracks do
		local track = tracks[i]
		if track.LastDetectionTime < cutoff then
			if track.LifecycleState == LS.ACTIVE then
				staleIds[#staleIds + 1] = track.TrackId
			elseif track.LifecycleState == LS.STALE then
				expiredIds[#expiredIds + 1] = track.TrackId
			end
		end
	end

	for i = 1, #staleIds do
		local track = self._store:get(staleIds[i])
		if track then
			track.LifecycleState = LS.STALE
			self._eventBus:publish({ id = "TrackBecameStale", TrackId = staleIds[i], timestamp = now })
		end
	end

	for i = 1, #expiredIds do
		local track = self._store:get(expiredIds[i])
		if track then
			local age = now - track.FirstDetectionTime
			Medusa.Services.MetricsService.observe("medusa_track_age_at_expiry_seconds", age)
			Medusa.Services.MetricsService.observe("medusa_track_updates_at_expiry", track.UpdateCount or 0)
			Medusa.Services.MetricsService.inc("medusa_tracks_expired_total")
			-- Save classification state for re-association
			if self._evidenceReacquisition then
				self:_addLost(Medusa.Services.TrackReacquisition.snapshot(track, now))
			elseif track.NetworkId then
				self._dormant[track.NetworkId] = {
					Position = track.Position,
					Velocity = track.Velocity,
					LastDetectionTime = track.LastDetectionTime,
					DisplayTrackId = track.DisplayTrackId,
					DisplayTrackIdAliases = track.DisplayTrackIdAliases,
					OriginSourceType = track.OriginSourceType,
					TrackIdentification = track.TrackIdentification,
					AssessedAircraftType = track.AssessedAircraftType,
					LastIdentificationTime = track.LastIdentificationTime,
					HarmAssessment = track.HarmAssessment,
					HarmLikelihoodScore = track.HarmLikelihoodScore,
					IsSeadThreat = track.IsSeadThreat,
					LaunchCue = track.LaunchCue,
					DecoyAssessment = track.DecoyAssessment,
					SizeDb = track.SizeDb,
					SizeWeight = track.SizeWeight,
					SizeSpreadDb = track.SizeSpreadDb,
					SeenAs = track.SeenAs,
					SeenAsTime = track.SeenAsTime,
					FirstSeenBy = track.FirstSeenBy,
					FirstSeenKind = track.FirstSeenKind,
					FirstSeenRangeM = track.FirstSeenRangeM,
					Release = track.Release,
					expiredAt = now,
				}
			else
				self:_releaseDisplayIds(track)
			end
		end
		local removed = self._store:remove(expiredIds[i])
		if removed then
			if self._geoGrid then
				self._geoGrid:remove(expiredIds[i])
			end
			self:_remapNetworkIdMappings(removed.TrackId, nil)
			self._eventBus:publish({ id = "TrackRemoved", TrackId = expiredIds[i], timestamp = now })
		end
	end

	-- Evict stale dormant entries
	for nid, d in pairs(self._dormant) do
		if now - d.expiredAt > Medusa.Constants.TRACK_REASSOC_TTL_SEC then
			self:_releaseDisplayIds(d)
			self._dormant[nid] = nil
		end
	end
	if not self._lostSweptAt or now - self._lostSweptAt >= 1 then
		self:_evictLost(now)
	end
end

function Medusa.Services.TrackManager:mergeTracks(survivingTrackId, absorbedTrackId, now)
	if survivingTrackId == absorbedTrackId then
		error("cannot merge a track into itself")
	end
	local survivor = self._store:get(survivingTrackId)
	local absorbed = self._store:get(absorbedTrackId)
	if not survivor or not absorbed then
		error("merge requires two existing tracks")
	end
	local absorbedDisplayId = Medusa.Entities.Track.displayId(absorbed)

	Medusa.Entities.Track.addDisplayIdAlias(survivor, absorbed.DisplayTrackId)
	for i = 1, #absorbed.DisplayTrackIdAliases do
		Medusa.Entities.Track.addDisplayIdAlias(survivor, absorbed.DisplayTrackIdAliases[i])
	end
	self:_remapNetworkIdMappings(absorbedTrackId, survivingTrackId)
	self._store:remove(absorbedTrackId)
	if self._geoGrid then
		self._geoGrid:remove(absorbedTrackId)
	end
	self._eventBus:publish({
		id = "TracksMerged",
		TrackId = survivingTrackId,
		MergedTrackId = absorbedTrackId,
		timestamp = now or GetTime(),
	})
	self._logger:info(
		string.format(
			"merged track %s into track %s; retained %s as an alias",
			absorbedDisplayId,
			Medusa.Entities.Track.displayId(survivor),
			absorbedDisplayId
		)
	)
	return survivor
end

function Medusa.Services.TrackManager:splitTrack(continuingTrackId, report, now)
	if not self._store:get(continuingTrackId) then
		error("split requires an existing continuing track")
	end
	if report and self._byNetworkId[report.NetworkId] then
		error("split report requires a new network ID")
	end
	return self:processReport(report, now)
end

--- The track that holds a DCS object, or nil.
function Medusa.Services.TrackManager:getTrackIdByNetworkId(networkId)
	return self._byNetworkId[networkId]
end

function Medusa.Services.TrackManager:getStore()
	return self._store
end

function Medusa.Services.TrackManager:getEventBus()
	return self._eventBus
end
