require("_header")
require("entities.Entities")
require("core.Constants")
require("core.Logger")

--[[
            ████████╗██████╗  █████╗  ██████╗██╗  ██╗
            ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝
               ██║   ██████╔╝███████║██║     █████╔╝
               ██║   ██╔══██╗██╔══██║██║     ██╔═██╗
               ██║   ██║  ██║██║  ██║╚██████╗██║  ██╗
               ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝

    What this entity does
    - Holds a radar contact's position, velocity, identification level, and a ring buffer of position history.
    - Computes smoothed velocity over a time window and derives maneuver state from heading changes.

    How others use it
    - TrackManager creates and updates Track instances from sensor polling reports.
    - TrackClassifier promotes identification; HarmDetectionService reads kinematic history for HARM scoring.
--]]

Medusa.Entities.Track = {}
Medusa.Entities.Track._logger = Medusa.Logger:ns("Track")

Medusa.Entities.Track._REQUIRED_FIELDS = { "Position", "Velocity", "NetworkId" }

-- 3 minutes of history at max update rate (1s interval = 180 entries)
Medusa.Entities.Track.MAX_POSITION_HISTORY = 180

function Medusa.Entities.Track.new(data)
	if not data then
		error("data table is required")
	end

	for _, field in ipairs(Medusa.Entities.Track._REQUIRED_FIELDS) do
		if data[field] == nil then
			error(string.format("missing required field: %s", field))
		end
	end

	local now = GetTime()

	local o = {
		TrackId = data.TrackId or NewULID(),
		DisplayTrackId = data.DisplayTrackId,
		DisplayTrackIdAliases = data.DisplayTrackIdAliases or {},
		OriginSourceType = data.OriginSourceType,
		NetworkId = data.NetworkId,
		Position = data.Position,
		Velocity = data.Velocity,
		TrackIdentification = data.TrackIdentification or "UNKNOWN",
		AssessedAircraftType = data.AssessedAircraftType or "UNKNOWN",
		UpdateCount = data.UpdateCount or 0,
		LifecycleState = data.LifecycleState or Medusa.Constants.TrackLifecycleState.ACTIVE,
		FirstDetectionTime = data.FirstDetectionTime or now,
		LastDetectionTime = data.LastDetectionTime or now,
		LastClassificationObservationTime = data.LastClassificationObservationTime,
		AssignedBatteryIds = data.AssignedBatteryIds or Set(),
		DetectingSensorIds = data.DetectingSensorIds or Set(),
		PositionHistory = RingBuffer(Medusa.Entities.Track.MAX_POSITION_HISTORY),

		SmoothedVelocity = data.SmoothedVelocity,
		ManeuverState = data.ManeuverState,
		HarmAssessment = data.HarmAssessment,
		-- Decoy assessment state (DecoyAssessmentService): label, evidence, sticky aircraft evidence.
		DecoyAssessment = data.DecoyAssessment,
		HarmLikelihoodScore = data.HarmLikelihoodScore,
		IdentityConfidence = data.IdentityConfidence,
		LastIdentificationTime = data.LastIdentificationTime,
		IffAmbiguityState = data.IffAmbiguityState,
		AltitudeAGL = data.AltitudeAGL,
		AltitudeMSL = data.AltitudeMSL,
		CoalitionId = data.CoalitionId,
		ConfidenceLevel = data.ConfidenceLevel,
		RaidId = data.RaidId,
		IsSeadThreat = data.IsSeadThreat,
		AssignmentTime = data.AssignmentTime,
		-- Seen leaving an older contact fast (a launch): { FromTrackId, Time }. Kept for the track's life.
		LaunchCue = data.LaunchCue,
		-- Fused return size (see observeEvidence): mean in dBsm, its weight (1/dB^2) and spread (dB).
		SizeDb = data.SizeDb,
		SizeWeight = data.SizeWeight,
		SizeSpreadDb = data.SizeSpreadDb,
		-- What a crew saw the contact as at sight range (Medusa.Constants.SeenAs) and when.
		SeenAs = data.SeenAs,
		SeenAsTime = data.SeenAsTime,
		-- Release (a store dropped by an aircraft?): set by TrackManager when the track is made (an unpowered mark also
		-- carries across a sure re-acquisition), never taken from data. See observeRelease.

		-- ROE identification ladder fields
		InsideBorder = false,
		InsideADIZ = false,
		BorderCrossingTime = nil,
		IffConfirmTime = nil,
		IntelIdentifyTime = nil,
		VIDIdentifyTime = nil,
		RWRIlluminationStart = nil,
		HostileActionConfirmed = false,
		HostileIntentStart = nil,
		BorderHostileDwellSec = nil,
	}

	Medusa.Entities.Track._logger:debug(
		string.format("created track %s for network %s", Medusa.Entities.Track.displayId(o), tostring(o.NetworkId))
	)
	return o
end

function Medusa.Entities.Track.displayId(track)
	return (track and track.DisplayTrackId) or Medusa.Constants.TrackDisplayId.UNSET
end

function Medusa.Entities.Track.addDisplayIdAlias(track, displayId)
	if not displayId or displayId == track.DisplayTrackId then
		return false
	end
	local aliases = track.DisplayTrackIdAliases
	for i = 1, #aliases do
		if aliases[i] == displayId then
			return false
		end
	end
	aliases[#aliases + 1] = displayId
	return true
end

function Medusa.Entities.Track.update(track, position, velocity, timestamp)
	track.Position = position
	track.Velocity = velocity
	track.LastDetectionTime = timestamp
	track.UpdateCount = track.UpdateCount + 1

	track.PositionHistory:push({
		timestamp = timestamp,
		position = { x = position.x, y = position.y, z = position.z },
		velocity = { x = velocity.x, y = velocity.y, z = velocity.z },
	})

	if track.LifecycleState == Medusa.Constants.TrackLifecycleState.STALE then
		track.LifecycleState = Medusa.Constants.TrackLifecycleState.ACTIVE
	end
end

local CE = Medusa.Constants.ContactEvidence
local SHAPE_VAR = CE.SIZE_SPREAD_FLOOR_DB * CE.SIZE_SPREAD_FLOOR_DB

--- Fold one report's contact evidence into the track. Return size: inverse-variance mean in dB, its weight capped
--- at SIZE_MAX_WEIGHT (a fading memory), spread = sqrt(1/weight + SIZE_SPREAD_FLOOR_DB^2): the looks' own noise plus
--- the unknown fixed shape and aspect of the object, which no number of looks averages away. SeenAs: the latest
--- sighting's class, with its time. No allocation.
--- @param track table
--- @param report table Report with optional SizeDb, SizeVarDb, SeenAs
--- @param now number
function Medusa.Entities.Track.observeEvidence(track, report, now)
	local x, var = report.SizeDb, report.SizeVarDb
	if x and var and var > 0 then
		local w = 1 / var
		local W = track.SizeWeight or 0
		local mean = track.SizeDb or 0
		local total = W + w
		track.SizeDb = (mean * W + x * w) / total
		if total > CE.SIZE_MAX_WEIGHT then
			total = CE.SIZE_MAX_WEIGHT
		end
		track.SizeWeight = total
		track.SizeSpreadDb = math.sqrt(1 / total + SHAPE_VAR)
	end
	local seen = report.SeenAs
	if seen then
		track.SeenAs = seen
		track.SeenAsTime = now
	end
end

--- "small" when the fused return is confidently below the size split (an ARM- or JSOW-sized return, well below a
--- fighter's), "large" when confidently above it (aircraft-sized), nil otherwise: confident means the looks' noise
--- has averaged down to the shape floor (weight >= SIZE_CONFIDENT_WEIGHT, about 3 looks) and the estimate
--- +/- CONFIDENCE_K x spread lies wholly on one side of SIZE_SPLIT_DBSM.
--- @param track table
--- @return string|nil
function Medusa.Entities.Track.sizeClass(track)
	local mean, spread = track.SizeDb, track.SizeSpreadDb
	if not mean or not spread or (track.SizeWeight or 0) < CE.SIZE_CONFIDENT_WEIGHT then
		return nil
	end
	local margin = CE.CONFIDENCE_K * spread
	if mean + margin < CE.SIZE_SPLIT_DBSM then
		return "small"
	end
	if mean - margin > CE.SIZE_SPLIT_DBSM then
		return "large"
	end
	return nil
end

local G2 = 2 * Medusa.Constants.GRAVITY_MPS2

--- Specific energy as a height: altitude + v^2/2g (m). Only a motor (or a thrusting engine) raises it.
function Medusa.Entities.Track.energyHeight(p, v)
	return p.y + (v.x * v.x + v.y * v.y + v.z * v.z) / G2
end
local energyHeight = Medusa.Entities.Track.energyHeight

--- The most energy height the track had in its history over the `windowSec` before `now` (walked in place).
--- @return number|nil nil when the track has no history in the window
function Medusa.Entities.Track.maxEnergyHeight(track, windowSec, now)
	local ring = track.PositionHistory
	local n = ring:size()
	local items, cap, pos = ring._items, ring._capacity, ring._tail
	local cutoff = now - windowSec
	local best = nil
	for _ = 1, n do
		local e = items[pos]
		if e.timestamp < cutoff then
			break
		end
		local h = energyHeight(e.position, e.velocity)
		if not best or h > best then
			best = h
		end
		pos = pos - 1
		if pos < 1 then
			pos = cap
		end
	end
	return best
end

--- One look at a possible released store (track.Release = { RefE, Since, LastTime, Looks, Unpowered, CarrierId,
--- CarrierAge }, made by TrackManager at birth with the carrier's reference energy; TrackManager drops it if the
--- carrier turns out to have been an ARM). Rising more than Release.POWERED_GAIN_M above RefE is a motor: the link,
--- or the unpowered mark, is dropped for good (track.Release = nil). Release.MIN_LOOKS looks spanning
--- Release.MIN_SPAN_SEC without that rise mark the track unpowered; later looks still check for the rise. Looks at the
--- time already counted (another sensor's report in the same poll) are skipped. No allocation.
--- @return string|nil "powered" or "unpowered" when this look decided it
function Medusa.Entities.Track.observeRelease(track, now)
	local r = track.Release
	if not r or now <= r.LastTime then
		return nil
	end
	local R = Medusa.Constants.Release
	if energyHeight(track.Position, track.Velocity) - r.RefE > R.POWERED_GAIN_M then
		track.Release = nil
		return "powered"
	end
	r.LastTime = now
	if r.Unpowered then
		return nil
	end
	r.Looks = r.Looks + 1
	if r.Looks >= R.MIN_LOOKS and now - r.Since >= R.MIN_SPAN_SEC then
		r.Unpowered = true
		return "unpowered"
	end
	return nil
end

--- Hands an unpowered mark `r` (a lost track's Release) on to the track that continues the same store: re-associated
--- by object id, or re-acquired by a strong, unique fit. A link still open, or no mark, hands on nothing.
function Medusa.Entities.Track.carryUnpowered(track, r)
	if r and r.Unpowered then
		track.Release = {
			RefE = r.RefE,
			Since = r.Since,
			LastTime = r.LastTime,
			Looks = r.Looks,
			Unpowered = true,
			CarrierId = r.CarrierId,
			CarrierAge = r.CarrierAge,
		}
	end
end

function Medusa.Entities.Track.computeSmoothedVelocity(track, windowSec)
	local ring = track.PositionHistory
	local sz = ring:size()
	if sz < 2 then
		local v = track.Velocity
		if not v then
			track.SmoothedVelocity = nil
			return
		end
		track.SmoothedVelocity = { x = v.x, y = v.y, z = v.z }
		return
	end

	-- Walk ring buffer in-place from tail (newest) to head (oldest)
	local items = ring._items
	local cap = ring._capacity
	local tail = ring._tail
	local newest = items[tail]
	local cutoff = newest.timestamp - windowSec
	local sumVx, sumVy, sumVz, count = 0, 0, 0, 0
	local pos = tail
	for _ = 1, sz do
		local entry = items[pos]
		if entry.timestamp < cutoff then
			break
		end
		local v = entry.velocity
		sumVx = sumVx + v.x
		sumVy = sumVy + v.y
		sumVz = sumVz + v.z
		count = count + 1
		pos = pos - 1
		if pos < 1 then
			pos = cap
		end
	end

	if count == 0 then
		track.SmoothedVelocity = {
			x = track.Velocity.x,
			y = track.Velocity.y,
			z = track.Velocity.z,
		}
		return
	end

	if track.SmoothedVelocity then
		track.SmoothedVelocity.x = sumVx / count
		track.SmoothedVelocity.y = sumVy / count
		track.SmoothedVelocity.z = sumVz / count
	else
		track.SmoothedVelocity = {
			x = sumVx / count,
			y = sumVy / count,
			z = sumVz / count,
		}
	end
end

local C = Medusa.Constants
local TURN_THRESHOLD = C.TRACK_TURN_THRESHOLD_RAD
local ORBIT_THRESHOLD = C.TRACK_ORBIT_THRESHOLD_RAD

function Medusa.Entities.Track.deriveManeuverState(track)
	local ManeuverState = Medusa.Constants.ManeuverState

	if not track.SmoothedVelocity then
		track.ManeuverState = ManeuverState.UNKNOWN
		return
	end

	local vel = track.Velocity
	if not vel then
		track.ManeuverState = ManeuverState.UNKNOWN
		return
	end
	local speed = VecLength(vel)
	if speed < 1.0 then
		track.ManeuverState = ManeuverState.UNKNOWN
		return
	end

	local sv = track.SmoothedVelocity
	local smoothedSpeed = VecLength(sv)
	if smoothedSpeed < 1.0 then
		track.ManeuverState = ManeuverState.UNKNOWN
		return
	end

	local heading = math.atan2(vel.z, vel.x)
	local smoothedHeading = math.atan2(sv.z, sv.x)
	local headingDelta = heading - smoothedHeading

	-- Normalize to [-pi, pi]
	if headingDelta > math.pi then
		headingDelta = headingDelta - 2 * math.pi
	elseif headingDelta < -math.pi then
		headingDelta = headingDelta + 2 * math.pi
	end

	if math.abs(headingDelta) > ORBIT_THRESHOLD then
		track.ManeuverState = ManeuverState.ORBITING
		return
	end
	if headingDelta > TURN_THRESHOLD then
		track.ManeuverState = ManeuverState.TURNING_RIGHT
		return
	end
	if headingDelta < -TURN_THRESHOLD then
		track.ManeuverState = ManeuverState.TURNING_LEFT
		return
	end

	local speedRatio = math.abs(speed - smoothedSpeed) / smoothedSpeed
	if speedRatio > C.MANEUVER_SPEED_RATIO_THRESHOLD then
		track.ManeuverState = ManeuverState.MANEUVERING
		return
	end

	track.ManeuverState = ManeuverState.STRAIGHT
end
