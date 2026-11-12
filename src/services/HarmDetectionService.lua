require("_header")
require("services.Services")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")
require("entities.Battery")
require("entities.Track")
require("core.Debrief")

--[[
            ██╗  ██╗ █████╗ ██████╗ ███╗   ███╗    ██████╗ ███████╗████████╗███████╗ ██████╗████████╗██╗ ██████╗ ███╗   ██╗
            ██║  ██║██╔══██╗██╔══██╗████╗ ████║    ██╔══██╗██╔════╝╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝██║██╔═══██╗████╗  ██║
            ███████║███████║██████╔╝██╔████╔██║    ██║  ██║█████╗     ██║   █████╗  ██║        ██║   ██║██║   ██║██╔██╗ ██║
            ██╔══██║██╔══██║██╔══██╗██║╚██╔╝██║    ██║  ██║██╔══╝     ██║   ██╔══╝  ██║        ██║   ██║██║   ██║██║╚██╗██║
            ██║  ██║██║  ██║██║  ██║██║ ╚═╝ ██║    ██████╔╝███████╗   ██║   ███████╗╚██████╗   ██║   ██║╚██████╔╝██║ ╚████║
            ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝    ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝ ╚═════╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

    What this service does
    - Scores each track against an 8-feature kinematic model to detect anti-radiation missiles.
    - Uses a sequential probability ratio test (SPRT) to classify tracks as HARM, suspect, or clear.
    - Computes closest-point-of-approach to nearby battery radars for threat assessment.

    How others use it
    - IadsNetwork calls evaluate each tick to update HARM likelihood scores on active tracks.
    - HarmResponseService reads those scores to decide shutdown or defense actions.

    References
    - https://en.wikipedia.org/wiki/Sequential_probability_ratio_test
--]]

Medusa.Services.HarmDetectionService = {}

local _logger = Medusa.Logger:ns("HarmDetectionService")
--- @type table Alias for Medusa.Constants
local C = Medusa.Constants
--- @type table Enum mapping for assessed aircraft types (e.g. AAT.HARM)
local AAT = Medusa.Constants.AssessedAircraftType
local HAS = Medusa.Constants.HarmAssessmentState
--- @type table Reusable buffer for track iteration
Medusa.Services.HarmDetectionService._trackBuffer = {}
local _trackBuffer = Medusa.Services.HarmDetectionService._trackBuffer
--- @type number[] Pre-allocated 8-element feature vector reused each extraction call
Medusa.Services.HarmDetectionService._feat = { 0, 0, 0, 0, 0, 0, 0, 0 }
local _feat = Medusa.Services.HarmDetectionService._feat

--- Feature vector indices for SPRT kinematic classifier.
--- Each maps to a slot in the _feat array extracted per scan.
local F_SPEED = 1 -- ground speed (m/s)
local F_DIVE = 2 -- dive angle (rad, positive = diving)
local F_HDGRATE = 3 -- heading rate of change (rad/s)
local F_ACCEL = 4 -- longitudinal acceleration (m/s²)
local F_CPA = 5 -- closest point of approach to nearest emitter (m)
local F_CPARATE = 6 -- rate of CPA change (m/s, negative = closing)
local F_RNGRATE = 7 -- range rate to emitter (m/s, negative = closing)
local F_ALTRATE = 8 -- vertical velocity (m/s)
local NUM_FEAT = 8

-- Pre-compute SPRT arrays from model (once at load).
-- Each array is indexed [1..NUM_FEAT] and derived from HARM_SPRT_MODEL Gaussians.
--- @type number[] 1/(2·σ²) for ARM distribution, used in log-likelihood exponent
Medusa.Services.HarmDetectionService._inv2vArm = {}
local _inv2vArm = Medusa.Services.HarmDetectionService._inv2vArm
--- @type number[] 1/(2·σ²) for non-ARM distribution
Medusa.Services.HarmDetectionService._inv2vNon = {}
local _inv2vNon = Medusa.Services.HarmDetectionService._inv2vNon
--- @type number[] log(σ_non / σ_arm), normalisation term in LLR
Medusa.Services.HarmDetectionService._lsigRatio = {}
local _lsigRatio = Medusa.Services.HarmDetectionService._lsigRatio
--- @type number[] Mean of ARM distribution per feature
Medusa.Services.HarmDetectionService._muArm = {}
local _muArm = Medusa.Services.HarmDetectionService._muArm
--- @type number[] Mean of non-ARM distribution per feature
Medusa.Services.HarmDetectionService._muNon = {}
local _muNon = Medusa.Services.HarmDetectionService._muNon

local MODEL = Medusa.Constants.HARM_SPRT_MODEL
for i = 1, NUM_FEAT do
	local m = MODEL[i]
	local sa, sn = m[2], m[4]
	_inv2vArm[i] = 1.0 / (2.0 * sa * sa)
	_inv2vNon[i] = 1.0 / (2.0 * sn * sn)
	_lsigRatio[i] = math.log(sn / sa)
	_muArm[i] = m[1]
	_muNon[i] = m[3]
end

--- Compute the 3D closest point of approach (CPA) between a moving object and a
--- stationary emitter. Returns the minimum distance the object will reach along
--- its current linear velocity vector, plus the time until that point.
--- The SPRT classifier uses CPA to distinguish ARMs from transiting aircraft.
--- ARMs converge on the emitter (CPA near zero), while passing aircraft have
--- a large CPA that stays roughly constant.
--- @param px number Track position X (DCS world coords)
--- @param py number Track position Y (altitude)
--- @param pz number Track position Z
--- @param vx number Track velocity X (m/s)
--- @param vy number Track velocity Y (m/s)
--- @param vz number Track velocity Z (m/s)
--- @param ex number Emitter position X
--- @param ey number Emitter position Y
--- @param ez number Emitter position Z
--- @return number cpaDistance Closest approach distance in meters
--- @return number tCpa Time in seconds until closest approach (0 if already past)
function Medusa.Services.HarmDetectionService.computeCPA3D(px, py, pz, vx, vy, vz, ex, ey, ez)
	local rx, ry, rz = px - ex, py - ey, pz - ez
	local vdotv = vx * vx + vy * vy + vz * vz
	if vdotv < 1e-6 then
		return math.sqrt(rx * rx + ry * ry + rz * rz), 0
	end
	local tCpa = math.max(0, -(rx * vx + ry * vy + rz * vz) / vdotv)
	local cx, cy, cz = rx + vx * tCpa, ry + vy * tCpa, rz + vz * tCpa
	return math.sqrt(cx * cx + cy * cy + cz * cz), tCpa
end

--- Returns the closest point of approach distance between a track and a position.
function Medusa.Services.HarmDetectionService.computeTrackCPA(track, targetPos)
	local vel = track.SmoothedVelocity or track.Velocity
	if not vel then
		return math.huge
	end
	return Medusa.Services.HarmDetectionService.computeCPA3D(
		track.Position.x,
		track.Position.y,
		track.Position.z,
		vel.x,
		vel.y,
		vel.z,
		targetPos.x,
		targetPos.y,
		targetPos.z
	)
end

--- @type fun(px:number,py:number,pz:number,vx:number,vy:number,vz:number,ex:number,ey:number,ez:number):number,number Local alias for CPA computation
local computeCPA3D = Medusa.Services.HarmDetectionService.computeCPA3D

local G = Medusa.Constants.GRAVITY_MPS2

--- Compute CPA using a ballistic (gravity-only) trajectory simulation.
--- Linear CPA assumes constant velocity, but ARMs in their terminal dive arc
--- downward under gravity after motor burnout. This function forward-integrates
--- position with gravity each step and returns the smallest distance encountered.
--- The feature extractor takes the smaller of linear and ballistic CPA, so a
--- diving missile's true closest approach is not underestimated.
--- @param px number Track position X
--- @param py number Track position Y (altitude)
--- @param pz number Track position Z
--- @param vx number Track velocity X (m/s)
--- @param vy number Track velocity Y (m/s)
--- @param vz number Track velocity Z (m/s)
--- @param ex number Emitter position X
--- @param ey number Emitter position Y
--- @param ez number Emitter position Z
--- @param dt number Simulation time step in seconds
--- @param maxT number Maximum simulation time in seconds
--- @return number bestDist Closest approach distance in meters along the ballistic arc
local function computeBallisticCPA(px, py, pz, vx, vy, vz, ex, ey, ez, dt, maxT)
	local bestDist = math.huge
	local x, y, z = px, py, pz
	local bvx, bvy, bvz = vx, vy, vz
	for _ = 1, math.ceil(maxT / dt) do
		bvy = bvy - G * dt
		x = x + bvx * dt
		y = y + bvy * dt
		z = z + bvz * dt
		if y < 0 then
			break
		end
		local dx, dy, dz = x - ex, y - ey, z - ez
		local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
		if dist < bestDist then
			bestDist = dist
		elseif dist > bestDist * 1.5 then
			break
		end
	end
	return bestDist
end

--- Find the position of the nearest WARM or HOT battery to a track.
--- SPRT features (CPA, range rate, CPA rate) are measured relative to the closest
--- active emitter because an ARM homes on the strongest signal, which correlates
--- with proximity. Cold batteries are excluded because they are not radiating and
--- cannot be targeted by an ARM.
--- @param track table Track entity with .Position
--- @param emitters table Index from buildEmitterIndex
--- @return table|nil emitterPos Position {x,y,z} of the closest active emitter, or nil if none in range
local function findClosestEmitter(track, emitters)
	local n = emitters.activeCount
	if n == 0 then
		return nil
	end
	local active = emitters.active
	local tx, tz = track.Position.x, track.Position.z
	local maxRange = C.HARM_MAX_RANGE_M
	local best, bestSq = nil, maxRange * maxRange
	for i = 1, n do
		local p = active[i]
		local dx, dz = p.x - tx, p.z - tz
		local dSq = dx * dx + dz * dz
		if dSq <= bestSq then
			best = p
			bestSq = dSq
		end
	end
	return best
end

--- Battery positions the HARM checks need, built once per HARM phase so each track scans a short array with
--- squared distances instead of running a 130 km grid query. `active` holds WARM/HOT non-AAA emitters; `targets`
--- holds every non-AAA battery in any state (what a confirmed ARM may still be flying at).
--- The arrays are reused across calls; the result is valid until the next call.
--- @param batteryStore table BatteryStore
--- @return table emitters { active = Vec3[], activeCount = number, targets = Vec3[], targetCount = number }
local _emitterIndex = { active = {}, activeCount = 0, targets = {}, targetCount = 0 }
local _batteryBuffer = {}
function Medusa.Services.HarmDetectionService.buildEmitterIndex(batteryStore)
	local AS = Medusa.Constants.ActivationState
	local isIndependentAaa = Medusa.Entities.Battery.isIndependentAaa
	local active, targets = _emitterIndex.active, _emitterIndex.targets
	local count, targetCount = 0, 0
	local batteries = batteryStore:getAll(_batteryBuffer)
	for i = 1, #batteries do
		local b = batteries[i]
		if b.Position and not isIndependentAaa(b) then
			targetCount = targetCount + 1
			targets[targetCount] = b.Position
			local st = b.ActivationState
			if st == AS.STATE_WARM or st == AS.STATE_HOT then
				count = count + 1
				active[count] = b.Position
			end
		end
	end
	for i = count + 1, _emitterIndex.activeCount do
		active[i] = nil
	end
	for i = targetCount + 1, _emitterIndex.targetCount do
		targets[i] = nil
	end
	_emitterIndex.activeCount = count
	_emitterIndex.targetCount = targetCount
	return _emitterIndex
end

--- True when the ground track is attacking some battery: closing on it, passing within the miss limit, and
--- arriving within the time-to-go limit (shorter for a slow, coasting track). Height is ignored (a lofted ARM's 3D
--- closest approach stays kilometres off until its final dive).
local function isAttackingAnyBattery(pos, vel, emitters)
	local vx, vz = vel.x, vel.z
	local vhSq = vx * vx + vz * vz
	if vhSq < 1 then
		return false
	end
	local vh = math.sqrt(vhSq)
	local tgoLimit = vh < C.HARM_DISPROOF_SLOW_MPS and C.HARM_DISPROOF_SLOW_TIME_TO_GO_SEC
		or C.HARM_DISPROOF_TIME_TO_GO_SEC
	local maxRange = tgoLimit * vh
	local maxRangeSq = maxRange * maxRange
	local missLimit = C.HARM_DISPROOF_MISS_M * vh
	local minClosing = C.HARM_DISPROOF_CLOSING_MPS
	local px, pz = pos.x, pos.z
	local targets = emitters.targets
	for i = 1, emitters.targetCount do
		local t = targets[i]
		local rx, rz = t.x - px, t.z - pz
		local rSq = rx * rx + rz * rz
		if rSq <= maxRangeSq then
			if rSq < 1 then
				return true
			end
			local r = math.sqrt(rSq)
			local closing = (rx * vx + rz * vz) / r
			if closing > minClosing and math.abs(rx * vz - rz * vx) < missLimit and r < tgoLimit * closing then
				return true
			end
		end
	end
	return false
end

--- Track the evidence that a confirmed ARM is not one. Returns true once it has flown for the window (and the minimum
--- number of scans) without attacking any battery or under the speed gate, or has been confirmed too long.
local function confirmedArmDisproved(state, curr, emitters, slow)
	local now = curr.timestamp
	if state.confirmedAt and now - state.confirmedAt >= C.HARM_CONFIRMED_MAX_SEC then
		return true
	end
	if slow or not isAttackingAnyBattery(curr.position, curr.velocity, emitters) then
		if not state.disproofSince then
			state.disproofSince = now
			state.disproofScans = 1
		else
			state.disproofScans = state.disproofScans + 1
		end
		return state.disproofScans >= C.HARM_DISPROOF_MIN_SCANS
			and now - state.disproofSince >= C.HARM_DISPROOF_WINDOW_SEC
	end
	state.disproofSince = nil
	state.disproofScans = 0
	return false
end

--- Extract the 8-element kinematic feature vector from two consecutive position
--- history entries. These features capture the flight signature of an ARM:
--- high speed, steep dive, minimal heading change (ARMs fly straight once locked),
--- slight deceleration (coasting after motor burnout), small and shrinking CPA to
--- the nearest emitter, negative range rate (closing), and negative altitude rate
--- (descending). Non-ARM aircraft differ on most features because they maneuver,
--- climb, and do not converge on a specific ground point.
--- Writes into the module-level _feat buffer to avoid per-call allocation.
--- @param curr table Current position history entry {position, velocity, timestamp}
--- @param prev table Previous position history entry
--- @param dt number Time delta between curr and prev (seconds)
--- @param emitterPos table {x,y,z} position of the nearest active emitter
--- @param sprtState table Per-track SPRT state (carries prevCpa/prevTime for rate computation)
--- @param ballisticDt number|nil Ballistic sim time step (default 1.0s)
--- @param ballisticMaxT number|nil Ballistic sim max steps (default 120)
--- @return number[] feat 8-element feature vector (reused buffer, do not hold across calls)
local function extractFeatures(curr, prev, dt, emitterPos, sprtState, ballisticDt, ballisticMaxT)
	ballisticDt = ballisticDt or 1.0
	ballisticMaxT = ballisticMaxT or 120
	local cv = curr.velocity
	local pv = prev.velocity
	local cp = curr.position

	local cvxSq, cvySq, cvzSq = cv.x * cv.x, cv.y * cv.y, cv.z * cv.z
	local speed = math.sqrt(cvxSq + cvySq + cvzSq)
	_feat[F_SPEED] = speed

	local hSpeed = math.sqrt(cvxSq + cvzSq)
	_feat[F_DIVE] = (speed > 1.0) and math.atan2(-cv.y, hSpeed) or 0

	local pvxSq, pvySq, pvzSq = pv.x * pv.x, pv.y * pv.y, pv.z * pv.z
	local hSpeedPrev = math.sqrt(pvxSq + pvzSq)
	if hSpeed > 1.0 and hSpeedPrev > 1.0 then
		local hdgCurr = math.atan2(cv.z, cv.x)
		local hdgPrev = math.atan2(pv.z, pv.x)
		local dHdg = hdgCurr - hdgPrev
		-- Wrap heading difference to [-pi, pi]; Lua lacks a true modulo for negatives
		dHdg = dHdg - 2 * math.pi * math.floor((dHdg + math.pi) / (2 * math.pi))
		_feat[F_HDGRATE] = math.abs(dHdg) / dt
	else
		_feat[F_HDGRATE] = 0
	end

	local prevSpeed = math.sqrt(pvxSq + pvySq + pvzSq)
	_feat[F_ACCEL] = (speed - prevSpeed) / dt

	local linearCpa = computeCPA3D(cp.x, cp.y, cp.z, cv.x, cv.y, cv.z, emitterPos.x, emitterPos.y, emitterPos.z)
	local ballisticCpa = computeBallisticCPA(
		cp.x,
		cp.y,
		cp.z,
		cv.x,
		cv.y,
		cv.z,
		emitterPos.x,
		emitterPos.y,
		emitterPos.z,
		ballisticDt,
		ballisticMaxT
	)
	_feat[F_CPA] = math.min(linearCpa, ballisticCpa)

	if sprtState.prevCpa and sprtState.prevTime then
		local cpaDt = curr.timestamp - sprtState.prevTime
		local cpaDist = _feat[F_CPA]
		_feat[F_CPARATE] = (cpaDt > 0.001) and ((cpaDist - sprtState.prevCpa) / cpaDt) or 0
	else
		_feat[F_CPARATE] = 0
	end

	local rx = cp.x - emitterPos.x
	local ry = cp.y - emitterPos.y
	local rz = cp.z - emitterPos.z
	local rng = math.sqrt(rx * rx + ry * ry + rz * rz)
	_feat[F_RNGRATE] = (rng > 1.0) and ((rx * cv.x + ry * cv.y + rz * cv.z) / rng) or 0

	_feat[F_ALTRATE] = cv.y

	return _feat
end

local _FEAT_NAMES = { "SPD", "DIV", "HDG", "ACC", "CPA", "CPR", "RNG", "ALT" }

--- Compute the per-scan log-likelihood ratio (LLR) across all 8 features.
--- For each feature, this computes how much more likely the observed value is
--- under the "ARM" distribution vs the "non-ARM" distribution, using the Gaussian
--- parameters from HARM_SPRT_MODEL. We work in log space because SPRT accumulates
--- evidence by summing across scans. Multiplying raw probabilities would quickly
--- underflow to zero, but adding logs is stable.
--- Per-feature contributions are clamped to ±HARM_SPRT_MAX_FEAT_LLR so one bad
--- reading (e.g. a position glitch spiking CPA) cannot dominate the total.
--- Positive LLR = looks like an ARM. Negative = looks like something else.
--- See: https://en.wikipedia.org/wiki/Likelihood-ratio_test
--- @param feat number[] 8-element feature vector from extractFeatures
--- @return number scanLlr Total clamped log-likelihood ratio for this scan
local function computeScanLLR(feat)
	local llr = 0
	local featCap = Medusa.Constants.HARM_SPRT_MAX_FEAT_LLR
	for i = 1, NUM_FEAT do
		local x = feat[i]
		local dArm = x - _muArm[i]
		local dNon = x - _muNon[i]
		-- SPRT log-likelihood ratio: positive = more ARM-like, negative = more non-ARM
		local contribution = _lsigRatio[i] - dArm * dArm * _inv2vArm[i] + dNon * dNon * _inv2vNon[i]
		llr = llr + math.max(-featCap, math.min(featCap, contribution))
	end
	return llr
end

local function formatFeatureLLRs(feat)
	local parts = {}
	local featCap = Medusa.Constants.HARM_SPRT_MAX_FEAT_LLR
	for i = 1, NUM_FEAT do
		local x = feat[i]
		local dArm = x - _muArm[i]
		local dNon = x - _muNon[i]
		local raw = _lsigRatio[i] - dArm * dArm * _inv2vArm[i] + dNon * dNon * _inv2vNon[i]
		local clamped = math.max(-featCap, math.min(featCap, raw))
		parts[i] = string.format("%s=%.1f(%.2f)", _FEAT_NAMES[i], x, clamped)
	end
	return table.concat(parts, " ")
end

local function markConfirmed(state, now)
	state.label = HAS.CONFIRMED
	state.confirmedAt = now
	state.disproofSince = nil
	state.disproofScans = 0
end

local CE = Medusa.Constants.ContactEvidence
local SEEN = Medusa.Constants.SeenAs

--- Contact evidence as one bounded prior on the ARM score, in the SPRT's natural-log likelihood-ratio units,
--- recomputed from the track's current estimates at every evaluation (replaced, never accumulated into the score):
--- - Return size, only once the fused estimate is confident (Track.sizeClass): linear in (split - estimate), reaching
---   HARM_SIZE_PRIOR_MAX (the SUSPECT threshold) at an ARM's size and HARM_SIZE_PRIOR_MIN (a sighting's -6) at the
---   smallest fighter's. A positive (small, ARM-like) term counts only while the kinematic score alone is at least
---   SUSPECT and never exceeds it: return size never turns a contact that flies like a jet into an ARM. Low-observable
---   aircraft (0.001-0.005 m2, smaller than an ARM) are therefore harder to classify, as they should be, but are
---   never confirmed on size. A confident aircraft-sized ("large") return also blocks CONFIRMED outright (updateLabel).
--- - Seen as an aircraft or helicopter at sight range: HARM_SEEN_AIRCRAFT_PRIOR. Seen as a munition is no ARM
---   evidence (a TALD or a JSOW is a munition too).
--- @param track table
--- @param kinematicLlr number The accumulated kinematic score
--- @return number prior
function Medusa.Services.HarmDetectionService.evidencePrior(track, kinematicLlr)
	local prior = 0
	if Medusa.Entities.Track.sizeClass(track) then
		local x = (CE.SIZE_SPLIT_DBSM - track.SizeDb) / CE.HARM_SIZE_PRIOR_REF_DB
		if x > 0 then
			prior = math.min(x, 1) * CE.HARM_SIZE_PRIOR_MAX
		else
			prior = math.min(-x, 1) * CE.HARM_SIZE_PRIOR_MIN
		end
		if prior > 0 then
			if kinematicLlr < C.HARM_SPRT_THRESH_SUSPECT then
				prior = 0
			elseif prior > kinematicLlr then
				prior = kinematicLlr
			end
		end
	end
	local seen = track.SeenAs
	if seen == SEEN.AIRCRAFT or seen == SEEN.HELICOPTER then
		prior = prior + CE.HARM_SEEN_AIRCRAFT_PRIOR
	end
	return prior
end
local evidencePrior = Medusa.Services.HarmDetectionService.evidencePrior

--- What stops a track being confirmed as an ARM now, or nil. A crew does not call a confident 5 m2 return an ARM
--- (about 0.08 m2), however ARM-like it flies ("size", Track.sizeClass "large"); nor a contact that appeared beside an
--- aircraft and has shown no motor ("unpowered", a released store), nor one still being watched for a motor
--- ("window"; Track.Release, Medusa.Constants.Release).
local function confirmBlock(track)
	local r = track.Release
	if r and r.Unpowered then
		return "unpowered"
	end
	if Medusa.Entities.Track.sizeClass(track) == "large" then
		return "size"
	end
	return r and "window" or nil
end
Medusa.Services.HarmDetectionService.confirmBlock = confirmBlock

--- A confirmed ARM keeps its label whatever its score says (the score is held at the clear threshold) until
--- `disproved` is set by its flight; then it clears with its score at or below the clear threshold. Other labels
--- are judged on the kinematic score plus the evidence prior (`state.prior`). A track with a confirm block
--- (`blockedBy`, confirmBlock) is never confirmed: it may still be SUSPECT or PROBABLE (alert zones see it; point
--- defence engages a released store predicted to fall on the site it protects, PointDefenseService.storeFallsOn; a
--- CLEARED track that would have been confirmed becomes PROBABLE, unless it is aircraft-sized), and an ARM already
--- confirmed stays so. A block that held back a confirmation is noted in state.blockedBy.
local function updateLabel(state, now, disproved, blockedBy)
	if state.label == HAS.CONFIRMED then
		if disproved then
			state.label = HAS.CLEARED
			state.llr = math.min(state.llr, C.HARM_SPRT_THRESH_CLEAR)
			state.confirmedAt = nil
			state.disproofSince = nil
			state.disproofScans = 0
		elseif state.llr < C.HARM_SPRT_THRESH_CLEAR then
			state.llr = C.HARM_SPRT_THRESH_CLEAR
		end
		return state.label
	end
	local score = state.llr + (state.prior or 0)
	if state.label == HAS.CLEARED then
		if score >= C.HARM_SPRT_THRESH_CONFIRM then
			if blockedBy then
				state.blockedBy = blockedBy
				if blockedBy ~= "size" then
					state.label = HAS.PROBABLE
				end
			else
				markConfirmed(state, now)
			end
		end
		return state.label
	end
	if score >= C.HARM_SPRT_THRESH_CONFIRM and not blockedBy then
		markConfirmed(state, now)
	elseif score >= C.HARM_SPRT_THRESH_CONFIRM then
		state.blockedBy = blockedBy
		state.label = HAS.PROBABLE
	elseif score <= C.HARM_SPRT_THRESH_CLEAR then
		state.label = HAS.CLEARED
	elseif score >= C.HARM_SPRT_THRESH_PROBABLE then
		state.label = HAS.PROBABLE
	elseif score >= C.HARM_SPRT_THRESH_SUSPECT then
		state.label = HAS.SUSPECT
	else
		state.label = HAS.EVALUATING
	end
	return state.label
end

local function createAssessment(track, emitterPos, now)
	local confirmed = track.AssessedAircraftType == AAT.HARM
	local state = {
		llr = confirmed and C.HARM_SPRT_THRESH_CONFIRM or 0,
		scanCount = 0,
		label = confirmed and HAS.CONFIRMED or HAS.EVALUATING,
		prevCpa = nil,
		prevTime = nil,
		emitterPosition = { x = emitterPos.x, y = emitterPos.y, z = emitterPos.z },
	}
	if confirmed then
		state.previousAircraftType = AAT.UNKNOWN
		state.previousIsSeadThreat = false
		state.confirmedAt = now
		state.disproofScans = 0
	end
	track.HarmAssessment = state
	_logger:info(string.format("track %s entered ARM evaluation", Medusa.Entities.Track.displayId(track)))
	return state
end

local function updateEmitterPosition(state, emitterPos)
	local saved = state.emitterPosition
	if not saved then
		saved = {}
		state.emitterPosition = saved
	end
	saved.x = emitterPos.x
	saved.y = emitterPos.y
	saved.z = emitterPos.z
end

local function accumulateEvidence(state, scanLlr)
	local contribution = math.max(-C.HARM_SPRT_MAX_SCAN_LLR, math.min(C.HARM_SPRT_MAX_SCAN_LLR, scanLlr))
	local limit = C.HARM_SPRT_ACCUMULATED_LLR_LIMIT
	state.llr = math.max(-limit, math.min(limit, state.llr + contribution))
end

local function logStateChange(track, previousLabel, state, feat)
	if state.label == previousLabel then
		return
	end
	local detail = feat and (" [" .. formatFeatureLLRs(feat) .. "]") or ""
	_logger:info(
		string.format(
			"track %s ARM %s -> %s (LLR=%.2f, scans=%d)%s",
			Medusa.Entities.Track.displayId(track),
			previousLabel,
			state.label,
			state.llr,
			state.scanCount,
			detail
		)
	)
end

--- Run one SPRT evaluation cycle for a single track.
--- This is the per-track workhorse called each tick. It manages the full
--- lifecycle: creating SPRT state on first sight, gating on minimum scans and
--- speed, extracting features, accumulating the LLR, and updating the label.
--- Decision evidence persists after confirmation or clearance. A decision changes
--- only after cumulative evidence crosses the opposite threshold.
--- @param track table Track entity with PositionHistory, TrackId, FirstDetectionTime
--- @param geoGrid table GeoGrid spatial index
--- @param batteryStore table BatteryStore for emitter lookup
--- @param ballisticDt number|nil Ballistic sim step size
--- @param ballisticMaxT number|nil Ballistic sim max steps
--- @param effectiveMinScans number|nil Minimum scans before an SPRT decision (defaults to HARM_SPRT_MIN_SCANS)
--- @return string label Current SPRT label for this track
--- @return table|nil state The SPRT state table, or nil if track has insufficient data
local function evaluateTrack(track, emitters, ballisticDt, ballisticMaxT, effectiveMinScans)
	local n = track.PositionHistory:size()
	if n < 2 then
		local state = track.HarmAssessment
		return state and state.label or HAS.EVALUATING, state
	end

	local curr = track.PositionHistory:get(n)
	local prev = track.PositionHistory:get(n - 1)
	local dt = curr.timestamp - prev.timestamp
	if dt < C.HARM_SPRT_MIN_DT_SEC then
		local state = track.HarmAssessment
		return state and state.label or HAS.EVALUATING, state
	end

	local state = track.HarmAssessment
	if state and state.prevTime and curr.timestamp <= state.prevTime then
		return state.label, state
	end
	local cv = curr.velocity
	local speedSq = cv.x * cv.x + cv.y * cv.y + cv.z * cv.z
	if speedSq < C.HARM_SPRT_SPEED_GATE * C.HARM_SPRT_SPEED_GATE then
		if not state then
			return HAS.CLEARED, nil
		end
		state.prevTime = curr.timestamp
		state.scanCount = state.scanCount + 1
		state.prior = 0
		local previousLabel = state.label
		local disproved = false
		if state.label == HAS.EVALUATING or state.label == HAS.SUSPECT or state.label == HAS.PROBABLE then
			state.llr = math.min(state.llr - C.HARM_SPRT_MAX_SCAN_LLR, C.HARM_SPRT_THRESH_CLEAR)
		else
			accumulateEvidence(state, -C.HARM_SPRT_MAX_SCAN_LLR)
			if state.label == HAS.CONFIRMED then
				disproved = confirmedArmDisproved(state, curr, emitters, true)
			end
		end
		updateLabel(state, curr.timestamp, disproved, confirmBlock(track))
		logStateChange(track, previousLabel, state)
		return state.label, state
	end

	local emitterPos = findClosestEmitter(track, emitters)
	if emitterPos then
		if not state then
			state = createAssessment(track, emitterPos, curr.timestamp)
		else
			updateEmitterPosition(state, emitterPos)
		end
	elseif state then
		emitterPos = state.emitterPosition
	end
	if not state or not emitterPos then
		return state and state.label or HAS.EVALUATING, state
	end

	state.scanCount = state.scanCount + 1
	local previousLabel = state.label

	local feat = extractFeatures(curr, prev, dt, emitterPos, state, ballisticDt, ballisticMaxT)

	state.prevCpa = feat[F_CPA]
	state.prevTime = curr.timestamp
	if not state.lastFeat then
		state.lastFeat = { false, false, false, false, false, false, false, false }
	end
	local lf = state.lastFeat
	lf[1] = feat[1]
	lf[2] = feat[2]
	lf[3] = feat[3]
	lf[4] = feat[4]
	lf[5] = feat[5]
	lf[6] = feat[6]
	lf[7] = feat[7]
	lf[8] = feat[8]

	local disproved = false
	if state.label == HAS.CONFIRMED then
		disproved = confirmedArmDisproved(state, curr, emitters, false)
	end

	local minScans = effectiveMinScans or C.HARM_SPRT_MIN_SCANS
	local scanLlr = computeScanLLR(feat)
	accumulateEvidence(state, scanLlr)
	state.prior = evidencePrior(track, state.llr)
	if state.scanCount < minScans and not disproved then
		return state.label, state
	end

	updateLabel(state, curr.timestamp, disproved, confirmBlock(track))
	logStateChange(track, previousLabel, state, feat)

	return state.label, state
end

--- Returns the ballistic simulation parameters needed by assessSingleTrack.
--- @param ctx table Pipeline context with doctrine
--- @return number ballisticDt Ballistic sim time step
--- @return number ballisticMaxT Ballistic sim max steps
function Medusa.Services.HarmDetectionService.getAssessContext(ctx)
	local doctrine = ctx.doctrine
	local ballisticDt = doctrine and doctrine.BallisticSimStepSec or 1.0
	local ballisticMaxT = doctrine and doctrine.BallisticSimMaxSec or 120
	return ballisticDt, ballisticMaxT
end

--- Assesses a single track for HARM classification via SPRT.
--- @param track table Track entity
--- @param tracks table Array of all tracks (for launcher backtracking)
--- @param _geoGrid table Unused (kept for callers; emitters come from the battery store)
--- @param batteryStore table BatteryStore for emitter proximity lookups
--- @param ballisticDt number Ballistic sim time step
--- @param ballisticMaxT number Ballistic sim max steps
--- @param emitters table|nil Index from buildEmitterIndex (built here when nil)
--- @param networkId string|nil The assessing network (named on its DEBRIEF line; nil: the network being ticked)
--- @return boolean reclassified True if this track was newly classified as HARM
function Medusa.Services.HarmDetectionService.assessSingleTrack(
	track,
	tracks,
	_geoGrid,
	batteryStore,
	ballisticDt,
	ballisticMaxT,
	emitters,
	networkId
)
	local LS = Medusa.Constants.TrackLifecycleState
	local vel = track.Velocity
	local speedSq = vel and (vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) or 0
	if
		track.LifecycleState ~= LS.ACTIVE
		or not vel
		or (not track.HarmAssessment and speedSq < C.HARM_SPRT_SPEED_GATE * C.HARM_SPRT_SPEED_GATE)
	then
		return false
	end

	local previousLabel = track.HarmAssessment and track.HarmAssessment.label
	emitters = emitters or Medusa.Services.HarmDetectionService.buildEmitterIndex(batteryStore)
	local label, state = evaluateTrack(track, emitters, ballisticDt, ballisticMaxT)

	if state and state.blockedBy then
		Medusa.Services.HarmDetectionService._noteBlocked(track, state, networkId)
	end
	if state then
		local score = state.llr
		if state.label ~= HAS.CONFIRMED then
			score = score + (state.prior or 0)
		end
		track.HarmLikelihoodScore = math.max(0, math.min(1, score / math.max(0.001, C.HARM_SPRT_THRESH_CONFIRM)))
	end

	if label == HAS.CONFIRMED and previousLabel ~= HAS.CONFIRMED then
		if not state.previousAircraftType then
			state.previousAircraftType = track.AssessedAircraftType
			state.previousIsSeadThreat = track.IsSeadThreat == true
		end
		Medusa.Services.MetricsService.inc("medusa_harm_confirmed_total")
		track.AssessedAircraftType = AAT.HARM
		track.IsSeadThreat = true
		_logger:info(
			string.format(
				"track %s classified as HARM (ARM CONFIRMED, LLR=%.2f)",
				Medusa.Entities.Track.displayId(track),
				state.llr
			)
		)
		Medusa.Debrief.emit(
			networkId,
			nil,
			"ARM_CONFIRMED",
			"track",
			Medusa.Entities.Track.displayId(track),
			"llr",
			string.format("%.2f", state.llr),
			"scans",
			state.scanCount
		)
		Medusa.Services.HarmDetectionService._backtrackLauncher(track, tracks)
		return true
	elseif label == HAS.CLEARED then
		track.HarmLikelihoodScore = 0
		if previousLabel == HAS.CONFIRMED then
			local restoredType = state.previousAircraftType or AAT.UNKNOWN
			local restoredSeadThreat = state.previousIsSeadThreat == true
			track.AssessedAircraftType = restoredType
			track.IsSeadThreat = restoredSeadThreat
			state.previousAircraftType = nil
			state.previousIsSeadThreat = nil
			_logger:info(
				string.format(
					"track %s HARM classification cleared (LLR=%.2f)",
					Medusa.Entities.Track.displayId(track),
					state.llr
				)
			)
		end
	end
	return false
end

--- A confirm block held back a confirmation: say so once per track and reason (log and an ARM_BLOCKED debrief line),
--- so the battle log shows why the ARM-like contact was not called an ARM.
function Medusa.Services.HarmDetectionService._noteBlocked(track, state, networkId)
	local why = state.blockedBy
	state.blockedBy = nil
	local noted = state.blocksNoted
	if not noted then
		noted = {}
		state.blocksNoted = noted
	elseif noted[why] then
		return
	end
	noted[why] = true
	local id = Medusa.Entities.Track.displayId(track)
	_logger:info(
		string.format(
			"track %s flies like an ARM (LLR=%.2f) but is not confirmed: %s",
			id,
			state.llr,
			why == "unpowered" and "it dropped off an aircraft and has no motor"
				or why == "window" and "it appeared beside an aircraft; watching for a motor"
				or "its return is aircraft-sized"
		)
	)
	Medusa.Debrief.emit(
		networkId,
		nil,
		"ARM_BLOCKED",
		"track",
		id,
		"why",
		why,
		"llr",
		string.format("%.2f", state.llr),
		"scans",
		state.scanCount
	)
end

--- Top-level entry point called by IadsNetwork each tick.
--- Iterates all active tracks in the network. For each eligible track, runs
--- evaluateTrack to accumulate SPRT evidence and update the label.
--- When a track reaches CONFIRMED, this function promotes it: sets
--- AssessedAircraftType to HARM, flags IsSeadThreat, and increments the
--- Prometheus counter. HarmResponseService reads these flags on its next
--- tick to decide whether batteries should shut down or defend.
--- @param ctx table Pipeline context with trackStore, batteryStore, geoGrid, doctrine
--- @return number reclassified Count of tracks newly classified as HARM this tick
function Medusa.Services.HarmDetectionService.assessHarmThreats(ctx)
	local trackStore = ctx.trackStore
	local batteryStore = ctx.batteryStore
	local geoGrid = ctx.geoGrid
	local tracks = trackStore:getAll(_trackBuffer)
	local reclassified = 0

	local ballisticDt, ballisticMaxT = Medusa.Services.HarmDetectionService.getAssessContext(ctx)
	local emitters = Medusa.Services.HarmDetectionService.buildEmitterIndex(batteryStore)

	for i = 1, #tracks do
		if
			Medusa.Services.HarmDetectionService.assessSingleTrack(
				tracks[i],
				tracks,
				geoGrid,
				batteryStore,
				ballisticDt,
				ballisticMaxT,
				emitters,
				ctx.networkId
			)
		then
			reclassified = reclassified + 1
		end
	end

	if reclassified > 0 then
		_logger:info(string.format("assessed %d new HARM threats", reclassified))
	end
	return reclassified
end

-- Scratch state for the backtrack's history walk (one callback, no per-candidate closure or copy).
local _bt = { originTime = 0, window = 0, bestEntry = nil, bestDt = 0 }
local function _backtrackVisit(entry)
	if not entry or not entry.position then
		return true
	end
	local dt = entry.timestamp - _bt.originTime
	if dt < -_bt.window then
		return false
	end
	local adt = dt < 0 and -dt or dt
	if adt < _bt.bestDt then
		_bt.bestDt = adt
		_bt.bestEntry = entry
	elseif dt < 0 then
		return false -- older entries only move further from the HARM's first sighting
	end
	return true
end

--- Find the aircraft that launched a confirmed HARM. At launch the HARM and its launcher are co-located, so each
--- candidate's position at the HARM's first sighting is estimated from its history entry nearest that time (within
--- HARM_BACKTRACK_WINDOW_SEC, walked newest first in place), dead-reckoned with that entry's velocity. Radars refresh
--- tracks every 1-10 s, so an exact time match is rare. The search radius is bounded by the total distance the HARM
--- has traveled since first detection.
function Medusa.Services.HarmDetectionService._backtrackLauncher(harmTrack, allTracks)
	local harmRing = harmTrack.PositionHistory
	local harmSize = harmRing:size()
	if harmSize < 2 then
		return
	end

	local oldest = harmRing:get(1)
	local newest = harmRing:get(harmSize)
	if not oldest or not oldest.position or not newest or not newest.position then
		return
	end

	local originX = oldest.position.x
	local originZ = oldest.position.z
	local originTime = oldest.timestamp

	local dx = newest.position.x - originX
	local dz = newest.position.z - originZ
	local searchRadiusSq = dx * dx + dz * dz

	local bestTrack = nil
	local bestDistSq = searchRadiusSq

	local window = C.HARM_BACKTRACK_WINDOW_SEC
	_bt.originTime = originTime
	_bt.window = window
	for i = 1, #allTracks do
		local candidate = allTracks[i]
		if
			candidate.TrackId ~= harmTrack.TrackId
			and candidate.AssessedAircraftType ~= AAT.HARM
			and candidate.PositionHistory
		then
			_bt.bestEntry = nil
			_bt.bestDt = window
			local oldestEntry = candidate.PositionHistory:peek()
			-- first seen well after the HARM was: it was not there to launch it
			if oldestEntry and oldestEntry.timestamp - originTime < window then
				candidate.PositionHistory:reverseIter(_backtrackVisit)
			end
			local entry = _bt.bestEntry
			if entry then
				local lag = originTime - entry.timestamp
				local v = entry.velocity
				local cx = entry.position.x + (v and v.x or 0) * lag
				local cz = entry.position.z + (v and v.z or 0) * lag
				local cdx = cx - originX
				local cdz = cz - originZ
				local distSq = cdx * cdx + cdz * cdz
				if distSq < bestDistSq then
					bestDistSq = distSq
					bestTrack = candidate
				end
			end
		end
	end
	_bt.bestEntry = nil

	if bestTrack then
		bestTrack.HostileActionConfirmed = true
		bestTrack.IsSeadThreat = true
		_logger:info(
			string.format(
				"track %s flagged hostile action (launched HARM %s, dist=%.0fm)",
				Medusa.Entities.Track.displayId(bestTrack),
				Medusa.Entities.Track.displayId(harmTrack),
				math.sqrt(bestDistSq)
			)
		)
	end
end

Medusa.Services.HarmDetectionService._isAttackingAnyBattery = isAttackingAnyBattery
Medusa.Services.HarmDetectionService._evaluateTrack = function(track, _, batteryStore, ...)
	return evaluateTrack(track, Medusa.Services.HarmDetectionService.buildEmitterIndex(batteryStore), ...)
end
Medusa.Services.HarmDetectionService._computeScanLLR = computeScanLLR
Medusa.Services.HarmDetectionService._extractFeatures = extractFeatures
