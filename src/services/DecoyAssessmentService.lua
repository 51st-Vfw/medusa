require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Track")
require("core.Debrief")

--[[
            ██████╗ ███████╗ ██████╗ ██████╗ ██╗   ██╗
            ██╔══██╗██╔════╝██╔════╝██╔═══██╗╚██╗ ██╔╝
            ██║  ██║█████╗  ██║     ██║   ██║ ╚████╔╝
            ██║  ██║██╔══╝  ██║     ██║   ██║  ╚██╔╝
            ██████╔╝███████╗╚██████╗╚██████╔╝   ██║
            ╚═════╝ ╚══════╝ ╚═════╝ ╚═════╝    ╚═╝

    What this service does
    - Judges whether an aircraft-sized contact is an unpowered decoy (TALD-like) from how it flies: a sustained,
      straight loss of specific energy (h + v^2/2g), an aircraft-sized return, what a crew saw at sight range, and
      whether it ever reacted to Medusa's own missiles. Labels AIRCRAFT -> SUSPECT -> PROBABLE are sticky; behaviour
      only a powered aircraft shows (energy gained or held, a sustained climb, a hard turn, a reaction, a flight
      longer than any glide) drops a contact back.
    - Keeps its evidence on the track (track.DecoyAssessment); the service itself holds no state.

    How others use it
    - IadsNetwork runs assess() in the HARM phase on the tracks the HARM pass visited this tick (chunked; each is
      evaluated at most once per new scan), then tallies what is in the engagement reach of each HOT long/medium-range
      battery and each battery holding a test shot (DecoyResponseService reads it).
    - IadsNetwork calls judgeLaunch() when a crew-guided missile's flight ends (unanswered launches).
    - TargetAssigner halves a SUSPECT's threat value and keeps PROBABLE decoys from long/medium-range SAMs;
      PointDefenseService engages a PROBABLE decoy whose glide is predicted to end at a defended battery (the reach
      tally exempts such a decoy from the decoy response the same way); alert zones count PROBABLE
      decoys as munitions.
--]]

Medusa.Services.DecoyAssessmentService = {}

do
	local Svc = Medusa.Services.DecoyAssessmentService
	local C = Medusa.Constants
	local D = C.Decoy
	local DS = C.DecoyState
	local SEEN = C.SeenAs
	local AAT = C.AssessedAircraftType
	local HAS = C.HarmAssessmentState
	local LS = C.TrackLifecycleState
	local G2 = 2 * C.GRAVITY_MPS2
	local atan2, abs, pi, sqrt = math.atan2, math.abs, math.pi, math.sqrt
	local logger = Medusa.Logger:ns("DecoyAssessmentService")
	local Track = Medusa.Entities.Track
	local FILTER_TRACK = { "Track" }

	local function wrapAngle(a)
		return a - 2 * pi * math.floor((a + pi) / (2 * pi))
	end

	local function energyHeight(entry)
		local v = entry.velocity
		return entry.position.y + (v.x * v.x + v.y * v.y + v.z * v.z) / G2
	end

	--- Statistics of the newest WINDOW_SEC of a track's history (taken back to WINDOW_MAX_SEC while that holds too
	--- few looks or too short a span), walked in place (no allocation): the newest sample's time, the least-squares
	--- slope of energy height (m/s), the mean vertical speed, the newest heading, the heading rate since the previous
	--- sample and the newest speed. nil when the window is too short to judge.
	local function windowStats(ring)
		local n = ring:size()
		if n < D.WINDOW_MIN_SAMPLES then
			return nil
		end
		local items, cap, pos = ring._items, ring._capacity, ring._tail
		local newest = items[pos]
		local t0 = newest.timestamp
		local cutoff, farthest = t0 - D.WINDOW_SEC - 1e-6, t0 - D.WINDOW_MAX_SEC - 1e-6
		local sumT, sumE, sumTT, sumTE, count = 0, 0, 0, 0, 0
		local oldest, prev = newest, nil
		for i = 1, n do
			local e = items[pos]
			local ts = e.timestamp
			if
				ts < farthest
				or (ts < cutoff and count >= D.WINDOW_MIN_SAMPLES and t0 - oldest.timestamp >= D.WINDOW_MIN_SPAN_SEC)
			then
				break
			end
			local dt = e.timestamp - t0
			local E = energyHeight(e)
			sumT, sumE, sumTT, sumTE, count = sumT + dt, sumE + E, sumTT + dt * dt, sumTE + dt * E, count + 1
			if i == 2 then
				prev = e
			end
			oldest = e
			pos = pos - 1
			if pos < 1 then
				pos = cap
			end
		end
		local span = t0 - oldest.timestamp
		local den = count * sumTT - sumT * sumT
		if count < D.WINDOW_MIN_SAMPLES or span < D.WINDOW_MIN_SPAN_SEC or den <= 0 then
			return nil
		end
		local nv = newest.velocity
		local heading = atan2(nv.z, nv.x)
		local turnRate = 0
		local pdt = prev and (t0 - prev.timestamp) or 0
		if pdt > 0.5 then
			local pv = prev.velocity
			turnRate = abs(wrapAngle(heading - atan2(pv.z, pv.x))) / pdt
		end
		return t0,
			(count * sumTE - sumT * sumE) / den,
			(newest.position.y - oldest.position.y) / span,
			heading,
			turnRate,
			sqrt(nv.x * nv.x + nv.y * nv.y + nv.z * nv.z)
	end
	Svc._windowStats = windowStats

	--- A contact the decoy assessment looks at: active, moving, and not already judged a weapon by other evidence
	--- (an ARM under evaluation, a missile, a contact seen leaving an aircraft under a rocket motor).
	local function eligible(track)
		if track.LifecycleState ~= LS.ACTIVE or not track.Velocity or track.LaunchCue then
			return false
		end
		local aat = track.AssessedAircraftType
		if aat == AAT.HARM or aat == AAT.MISSILE then
			return false
		end
		local harm = track.HarmAssessment and track.HarmAssessment.label
		return harm ~= HAS.CONFIRMED and harm ~= HAS.PROBABLE and harm ~= HAS.SUSPECT
	end
	Svc.isEligible = eligible

	local function newState()
		return {
			label = DS.AIRCRAFT,
			runSince = nil,
			runHeading = 0,
			runSec = 0,
			launchEvidence = 0,
			aircraftEvidence = nil,
			disproofScans = 0,
			holdSince = nil,
			glideEndsAt = nil,
			lastTime = nil,
			slope = 0,
			testedAt = nil,
		}
	end

	local function stateOf(track)
		local da = track.DecoyAssessment
		if not da then
			da = newState()
			track.DecoyAssessment = da
		end
		return da
	end

	-- The network whose evaluate or judgeLaunch call is running (named on its DEBRIEF lines).
	local _network = nil

	local function setLabel(track, da, label, reason)
		if da.label == label then
			return
		end
		if label == C.DecoyState.PROBABLE then
			Medusa.Debrief.emit(
				_network,
				nil,
				"DECOY_PROBABLE",
				"track",
				Track.displayId(track),
				"from",
				da.label,
				"reason",
				reason
			)
		end
		logger:info(
			string.format(
				"decoy track %s %s -> %s (%s; run %ds, loss %.1f m/s, launches +%ds, size %s, seen %s)",
				Track.displayId(track),
				da.label,
				label,
				reason,
				da.runSec,
				-da.slope,
				da.launchEvidence,
				tostring(Track.sizeClass(track)),
				tostring(track.SeenAs)
			)
		)
		da.label = label
		if label == DS.AIRCRAFT then
			da.glideEndsAt = nil
		elseif not da.glideEndsAt then
			da.glideEndsAt = Svc.glideEndsAt(track)
		end
	end

	--- Positive aircraft evidence: sticky, blocks every decoy label for the track's life.
	local function markAircraft(track, da, kind)
		da.aircraftEvidence = da.aircraftEvidence or kind
		da.runSince = nil
		da.runSec = 0
		da.holdSince = nil
		setLabel(track, da, DS.AIRCRAFT, kind)
	end

	local function promote(track, da)
		if da.aircraftEvidence or Track.sizeClass(track) ~= "large" then
			return
		end
		if da.label == DS.AIRCRAFT and da.runSec >= D.SUSPECT_SEC then
			setLabel(track, da, DS.SUSPECT, "sustained straight energy loss")
		end
		if da.label ~= DS.SUSPECT then
			return
		end
		local seen = track.SeenAs == SEEN.MUNITION and D.SEEN_MUNITION_SEC or 0
		if da.runSec >= D.PROBABLE_SEC then
			setLabel(track, da, DS.PROBABLE, "sustained straight energy loss")
		elseif da.runSec + da.launchEvidence + seen >= D.PROBABLE_SEC then
			setLabel(track, da, DS.PROBABLE, seen > 0 and "seen as a munition" or "unanswered launches")
		end
	end
	Svc._promote = promote

	local function disproofKind(slope, meanVy, turnRate)
		if slope > D.GAIN_MPS then
			return "energy gain"
		elseif meanVy > D.CLIMB_MPS then
			return "climb"
		elseif turnRate > D.HARD_TURN_RAD_PER_SEC then
			return "hard turn"
		end
		return nil
	end

	--- The loss of energy height (m/s) beyond which a contact at this speed may be gliding.
	local function lossFloor(speed)
		local glide = speed / D.GLIDE_RATIO_MAX
		return glide > D.LOSS_MPS and glide or D.LOSS_MPS
	end
	Svc.lossFloor = lossFloor

	--- Held energy (a loss flatter than any glide) on every scan for HOLD_SEC of track time is proof of power.
	local function holdsEnergy(da, t0, slope, speed)
		if slope < -speed / D.HOLD_GLIDE_RATIO then
			da.holdSince = nil
			return false
		end
		da.holdSince = da.holdSince or t0
		return t0 - da.holdSince >= D.HOLD_SEC
	end

	local function updateRun(da, t0, slope, heading, speed)
		if slope >= -lossFloor(speed) then
			da.runSince = nil
			da.runSec = 0
			return
		end
		if not da.runSince or abs(wrapAngle(heading - da.runHeading)) > D.STRAIGHT_LEG_RAD then
			da.runSince = t0
			da.runHeading = heading
		end
		da.runSec = t0 - da.runSince
	end

	--- Evidence a crew has without watching the flight: a confidently small return is a glide weapon or an ARM,
	--- not a decoy; a contact seen as an aircraft at sight range is one. Returns true when it settled the label.
	local function contactEvidence(track, da)
		local seen = track.SeenAs
		if seen == SEEN.AIRCRAFT or seen == SEEN.HELICOPTER then
			markAircraft(track, da, "seen as an aircraft")
			return true
		end
		if Track.sizeClass(track) == "small" then
			da.runSince = nil
			da.runSec = 0
			setLabel(track, da, DS.AIRCRAFT, "small return")
			return true
		end
		return false
	end

	--- One evaluation of a contact, at most once per new scan (track.DecoyCheckedAt, kept also while the window is
	--- too short to judge). Returns the label (nil when not assessed).
	--- @param track table
	--- @param network string|nil The judging network's id (its DEBRIEF lines); nil: the network being ticked
	--- @return string|nil
	function Svc.evaluate(track, network)
		_network = network
		local da = track.DecoyAssessment
		local ring = track.PositionHistory
		if not eligible(track) or ring:size() == 0 then
			return da and da.label
		end
		local newestTime = ring._items[ring._tail].timestamp
		local checked = track.DecoyCheckedAt
		if checked and newestTime <= checked then
			return da and da.label
		end
		track.DecoyCheckedAt = newestTime
		local t0, slope, meanVy, heading, turnRate, speed = windowStats(ring)
		if not t0 then
			return da and da.label
		end
		da = stateOf(track)
		da.lastTime = t0
		da.slope = slope
		if contactEvidence(track, da) then
			return da.label
		end
		local kind = disproofKind(slope, meanVy, turnRate)
		da.disproofScans = kind and da.disproofScans + 1 or 0
		if kind and da.disproofScans >= D.DISPROOF_SCANS then
			markAircraft(track, da, kind)
			return da.label
		end
		if holdsEnergy(da, t0, slope, speed) then
			markAircraft(track, da, "held its energy")
			return da.label
		end
		if da.glideEndsAt and t0 > da.glideEndsAt then
			markAircraft(track, da, "outlived its glide")
			return da.label
		end
		updateRun(da, t0, slope, heading, speed)
		promote(track, da)
		return da.label
	end

	function Svc.label(track)
		local da = track and track.DecoyAssessment
		return da and da.label
	end

	function Svc.isSuspect(track)
		local da = track and track.DecoyAssessment
		return da ~= nil and da.label == DS.SUSPECT
	end

	function Svc.isProbable(track)
		local da = track and track.DecoyAssessment
		return da ~= nil and da.label == DS.PROBABLE
	end

	--- Positive aircraft evidence a crew can stand on: seen as an aircraft at sight range, or an aircraft-sized
	--- return that once gained energy, climbed, turned hard or reacted to a launch. Behavior alone is not enough:
	--- a cruise missile (small return) climbs and gains energy too.
	function Svc.hasAircraftEvidence(track)
		local seen = track.SeenAs
		if seen == SEEN.AIRCRAFT or seen == SEEN.HELICOPTER then
			return true
		end
		local da = track.DecoyAssessment
		return da ~= nil and da.aircraftEvidence ~= nil and Track.sizeClass(track) == "large"
	end

	--- When the longest glide a contact could still fly from here would be over (track time): its energy height above
	--- GLIDE_MIN_SPEED_MPS at ground level, used up at GLIDE_RATIO_MAX at that slowest speed (generous: recorded TALDs
	--- lose it two to three times faster). nil without a position or history.
	function Svc.glideEndsAt(track)
		local p, v = track.Position, track.Velocity
		local ring = track.PositionHistory
		if not p or not v or not ring or ring:size() == 0 then
			return nil
		end
		local ground = p.y - (track.AltitudeAGL or p.y)
		local spare = p.y
			+ (v.x * v.x + v.y * v.y + v.z * v.z) / G2
			- (ground + D.GLIDE_MIN_SPEED_MPS * D.GLIDE_MIN_SPEED_MPS / G2)
		return ring._items[ring._tail].timestamp + math.max(spare, 0) * D.GLIDE_RATIO_MAX / D.GLIDE_MIN_SPEED_MPS
	end

	--- Where a decoy's glide is predicted to reach the ground (x, z), from its own position and velocity, along its
	--- ground track (straight: decoys fly straight legs): the shorter of its energy glide (energy height above the
	--- slowest glide speed at ground level, used up at the measured loss rate) and its present descent carried to the
	--- ground (a dive). nil without an assessment, a position or a velocity.
	function Svc.glideImpact(track)
		local da = track.DecoyAssessment
		if not da then
			return nil
		end
		return Svc.impactOf(track)
	end

	--- Where a contact is predicted to reach the ground (x, z), or nil without position or velocity: the glide above
	--- with its measured energy-loss slope if it has a decoy assessment, else the slowest loss (LOSS_MPS), so a
	--- falling store's dive line decides.
	function Svc.impactOf(track)
		local da = track.DecoyAssessment
		local p, v = track.Position, track.Velocity
		if not p or not v then
			return nil
		end
		local vh = sqrt(v.x * v.x + v.z * v.z)
		if vh < 1 then
			return p.x, p.z
		end
		local agl = math.max(track.AltitudeAGL or p.y, 0)
		local spare = agl
			+ (v.x * v.x + v.y * v.y + v.z * v.z) / G2
			- D.GLIDE_MIN_SPEED_MPS * D.GLIDE_MIN_SPEED_MPS / G2
		local dist = vh * math.max(spare, 0) / math.max(-(da and da.slope or 0), D.LOSS_MPS)
		if v.y < -1 then
			dist = math.min(dist, vh * agl / -v.y)
		end
		return p.x + v.x / vh * dist, p.z + v.z / vh * dist
	end

	--- True when a PROBABLE decoy's glide is predicted to end within GLIDE_THREAT_RADIUS_M of a position (a battery,
	--- or the site point defense protects): it is a munition threat there. A decoy flying over toward something else
	--- is not.
	function Svc.glideThreatens(track, pos)
		local da = track.DecoyAssessment
		if not da or da.label ~= DS.PROBABLE or not pos then
			return false
		end
		return Svc.impactThreatens(track, pos)
	end

	--- True when a contact's predicted impact (impactOf) is within GLIDE_THREAT_RADIUS_M of a position.
	function Svc.impactThreatens(track, pos)
		if not pos then
			return false
		end
		local x, z = Svc.impactOf(track)
		if not x then
			return false
		end
		local dx, dz, radius = x - pos.x, z - pos.z, D.GLIDE_THREAT_RADIUS_M
		return dx * dx + dz * dz <= radius * radius
	end

	--- The key a battery counts its fire holds against a decoy by: the decoy's lineage (set at its first hold and
	--- carried with its assessment when the track is re-acquired under a new id), else its track id.
	function Svc.holdKey(track)
		local da = track.DecoyAssessment
		return da and da.holdLineage or track.TrackId
	end

	-- ── The HARM phase's pass ──────────────────────────────────────

	local AS = C.ActivationState
	local DESTROYED = C.BatteryOperationalStatus.DESTROYED
	local _batteryBuffer = {}

	--- A battery whose reach is tallied: one DecoyResponseService decides for (a HOT long/medium-range battery that
	--- is not point defense, for engage-air-weapons; any battery holding a test shot).
	local function tallied(b)
		if not b.Position or (b.EngagementRangeMax or 0) <= 0 or b.OperationalStatus == DESTROYED then
			return false
		end
		return b.TestShotHold ~= nil
			or (b.ActivationState == AS.STATE_HOT and D.MANAGED_ROLES[b.Role] == true and not b.IsPointDefense)
	end

	--- Engagement reach for the engage-air-weapons and test-shot decisions: the capped engagement range plus margin.
	function Svc.reachOf(battery, doctrine)
		local r = battery.EngagementRangeMax or 0
		local pct = doctrine and doctrine.MaxEngageRangePct and doctrine.MaxEngageRangePct[battery.Role]
		if pct then
			r = r * pct / 100
		end
		return r + D.REACH_MARGIN_M
	end

	--- One of the group a test shot tests: the target, or a contact near it that could be a decoy (not a weapon by
	--- other evidence, no aircraft evidence).
	function Svc.inGroupOf(track, target)
		if track == target then
			return true
		end
		local p, q = track.Position, target.Position
		local dx, dz = p.x - q.x, p.z - q.z
		local r = D.NEIGHBOUR_RADIUS_M
		return dx * dx + dz * dz <= r * r and eligible(track) and not Svc.hasAircraftEvidence(track)
	end

	local function resetReach(b, now)
		local reach = b.DecoyReach
		if not reach then
			reach = {}
			b.DecoyReach = reach
		end
		reach.time = now
		reach.probable = 0
		reach.aircraft = 0
		reach.other = 0
		reach.outsiders = 0
		reach.holdable = 0
		return reach
	end

	local function tally(reach, track, b, holdTarget)
		if Svc.isProbable(track) and not Svc.glideThreatens(track, b.Position) then
			reach.probable = reach.probable + 1
			local counts = b.FireHoldCounts
			local n = counts and counts[Svc.holdKey(track)]
			if not n or n < D.FIRE_HOLDS_PER_TRACK then
				reach.holdable = reach.holdable + 1
			end
		elseif Svc.hasAircraftEvidence(track) then
			reach.aircraft = reach.aircraft + 1
		else
			reach.other = reach.other + 1
		end
		if holdTarget and not Svc.inGroupOf(track, holdTarget) then
			reach.outsiders = reach.outsiders + 1
		end
	end

	local _tallied, _reachSq, _holdTarget, _trackBuffer = {}, {}, {}, {}

	--- One pass over the picture for every tallied battery at once (inline squared distance, no grid query and no
	--- allocation: there are few such batteries, usually only the HOT ones).
	local function tallyAll(ctx, nb)
		local tracks = ctx.trackStore:getAll(_trackBuffer)
		for i = 1, #tracks do
			local t = tracks[i]
			local p = t.Position
			if p and t.LifecycleState == LS.ACTIVE then
				for j = 1, nb do
					local b = _tallied[j]
					local bp = b.Position
					local dx, dz = p.x - bp.x, p.z - bp.z
					if dx * dx + dz * dz <= _reachSq[j] then
						tally(b.DecoyReach, t, b, _holdTarget[j])
					end
				end
			end
		end
	end

	--- The HARM phase's decoy pass: evaluates the tracks the HARM pass visited this tick (tracks[1..n]; each at most
	--- once per new scan, so the chunking costs nothing but latency), then tallies, for each battery
	--- DecoyResponseService decides for, what is within its reach (battery.DecoyReach: probable decoys, those the
	--- battery may still hold against (holdable), known aircraft, others, and contacts outside a test shot's group).
	--- The network's whole picture is assessed (its command post judges every contact it holds). Does nothing when
	--- switched off.
	--- @param ctx table { trackStore, batteryStore, geoGrid, doctrine, now }
	--- @param tracks table|nil
	--- @param n number|nil
	function Svc.assess(ctx, tracks, n)
		if ctx.doctrine and ctx.doctrine.DecoyAssessment == false then
			return
		end
		for i = 1, n or 0 do
			Svc.evaluate(tracks[i], ctx.networkId)
		end
		local batteries = ctx.batteryStore:getAll(_batteryBuffer)
		local nb = 0
		for i = 1, #batteries do
			local b = batteries[i]
			if tallied(b) then
				nb = nb + 1
				resetReach(b, ctx.now)
				local reachM = Svc.reachOf(b, ctx.doctrine)
				local hold = b.TestShotHold
				_tallied[nb], _reachSq[nb] = b, reachM * reachM
				_holdTarget[nb] = hold and ctx.trackStore:get(hold.TargetTrackId) or false
			end
		end
		if nb > 0 then
			tallyAll(ctx, nb)
		end
		for j = nb + 1, #_tallied do
			_tallied[j], _holdTarget[j] = nil, nil
		end
	end

	-- ── Unanswered launches ────────────────────────────────────────

	--- Whether a contact reacted between two times, from its history (oldest scan in the window as reference for a
	--- climb or a gain). A turn is judged on consecutive scans: a heading rate above HARD_TURN_RAD_PER_SEC (the
	--- standard-rate turn) adding up to more than STRAIGHT_LEG_RAD; a decoy's slow drift (recorded TALDs up to 0.9
	--- deg/s) never is one, however long the flight. Returns the reaction ("turned", "climbed", "accelerated"), or
	--- false, and the number of scans in the window.
	local function reactionDuring(track, fromT, toT)
		local ring = track.PositionHistory
		local n = ring:size()
		local first = n + 1
		for i = n, 1, -1 do
			local t = ring:get(i).timestamp
			if t < fromT then
				break
			end
			if t <= toT then
				first = i
			end
		end
		local ref = first <= n and ring:get(first)
		if not ref then
			return false, 0
		end
		local hPrev, tPrev = atan2(ref.velocity.z, ref.velocity.x), ref.timestamp
		local y0, e0 = ref.position.y, energyHeight(ref)
		local scans, turned = 0, 0
		for i = first, n do
			local e = ring:get(i)
			if e.timestamp > toT then
				break
			end
			scans = scans + 1
			local h = atan2(e.velocity.z, e.velocity.x)
			local dh, dt = abs(wrapAngle(h - hPrev)), e.timestamp - tPrev
			if dt > 0 and dh > D.HARD_TURN_RAD_PER_SEC * dt then
				turned = turned + dh
			elseif dt > 0 then
				turned = 0
			end
			hPrev, tPrev = h, e.timestamp
			if turned > D.STRAIGHT_LEG_RAD then
				return "turned", scans
			elseif e.position.y - y0 > D.REACTION_CLIMB_M then
				return "climbed", scans
			elseif energyHeight(e) - e0 > D.REACTION_GAIN_M then
				return "accelerated", scans
			end
		end
		return false, scans
	end
	Svc._reactionDuring = reactionDuring

	local function judgeOne(track, launchTime, endTime, weight)
		if not eligible(track) then
			return
		end
		local reaction, scans = reactionDuring(track, launchTime, endTime)
		if scans < D.MIN_FLIGHT_SCANS then
			return
		end
		local da = stateOf(track)
		if reaction then
			markAircraft(track, da, "reacted to a launch (" .. reaction .. ")")
			return
		end
		da.launchEvidence = math.min(D.LAUNCH_EVIDENCE_MAX_SEC, da.launchEvidence + weight)
		logger:info(
			string.format(
				"decoy track %s unanswered launch (+%ds, total %ds)",
				Track.displayId(track),
				weight,
				da.launchEvidence
			)
		)
		promote(track, da)
	end

	--- A crew-guided missile's flight has ended: its target (full weight) and every contact within 2 NM of it
	--- (half weight) gain evidence if they never reacted during the flight; a reaction is aircraft evidence.
	--- @param flight table { TargetTrackId, LaunchTime }
	--- @param now number
	--- @param trackStore table
	--- @param geoGrid table
	--- @param network string|nil the judging network (named on its DEBRIEF lines)
	function Svc.judgeLaunch(flight, now, trackStore, geoGrid, network)
		_network = network
		local target = flight.TargetTrackId and trackStore:get(flight.TargetTrackId)
		if not target or not target.Position or now - flight.LaunchTime < D.MIN_FLIGHT_SEC then
			return
		end
		judgeOne(target, flight.LaunchTime, now, D.LAUNCH_EVIDENCE_TARGET_SEC)
		local ids = geoGrid:queryRadius(target.Position, D.NEIGHBOUR_RADIUS_M, FILTER_TRACK).TrackIds
		if not ids then
			return
		end
		for id in pairs(ids) do
			local t = id ~= target.TrackId and trackStore:get(id)
			if t then
				judgeOne(t, flight.LaunchTime, now, D.LAUNCH_EVIDENCE_BYSTANDER_SEC)
			end
		end
	end
end
