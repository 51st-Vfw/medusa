require("_header")
require("services.Services")
require("core.Constants")
require("entities.Track")

--[[
            ██████╗ ███████╗      █████╗  ██████╗ ██████╗ ██╗   ██╗██╗██████╗ ███████╗
            ██╔══██╗██╔════╝     ██╔══██╗██╔════╝██╔═══██╗██║   ██║██║██╔══██╗██╔════╝
            ██████╔╝█████╗ █████╗███████║██║     ██║   ██║██║   ██║██║██████╔╝█████╗
            ██╔══██╗██╔══╝ ╚════╝██╔══██║██║     ██║▄▄ ██║██║   ██║██║██╔══██╗██╔══╝
            ██║  ██║███████╗     ██║  ██║╚██████╗╚██████╔╝╚██████╔╝██║██║  ██║███████╗
            ╚═╝  ╚═╝╚══════╝     ╚═╝  ╚═╝ ╚═════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝╚═╝  ╚═╝╚══════╝

    What this service does
    - Decides whether a new contact is a lost track seen again, from evidence an operator has: where the lost track
      should be by now and how it should be flying (last position, constant velocity, and the trend of its last
      seconds), each judged against an uncertainty that grows with the gap and the speed. Never by DCS object id.
    - Decides what a re-acquired track carries: identification; an ARM label (never its score) across short gaps;
      decoy labels, aircraft evidence and an unpowered mark only on a strong fit (a decoy label also only when the contact has lost a
      glider's energy over the gap and the gap is within the decoy's remaining glide); size, sightings and launch cue
      weakened when the fit is loose or the gap long. A tie among lost tracks of one class carries the label they
      share at the weakest confidence among them.
    - Stateless: TrackManager owns the lost tracks (snapshots made here) and their grid.

    How others use it
    - TrackManager snapshots a track when it is dropped, scores lost tracks near each new contact, and carries
      evidence onto the track it creates.
--]]

Medusa.Services.TrackReacquisition = {}

do
	local Svc = Medusa.Services.TrackReacquisition
	local C = Medusa.Constants
	local R = C.Reacquisition
	local CE = C.ContactEvidence
	local HAS = C.HarmAssessmentState
	local DS = C.DecoyState
	local AAT = C.AssessedAircraftType
	local SEEN = C.SeenAs
	local sqrt, exp, min = math.sqrt, math.exp, math.min
	local G2 = 2 * C.GRAVITY_MPS2

	local function copy3(v)
		return { x = v.x, y = v.y, z = v.z }
	end

	--- The track's acceleration over its newest HISTORY_SEC (walked in place), capped at 3 g; nil when the window
	--- holds too few looks or too short a span (at 5-10 s radar refresh it usually does).
	local function trend(ring)
		local n = ring:size()
		if n < R.TREND_MIN_SAMPLES then
			return nil
		end
		local items, cap, pos = ring._items, ring._capacity, ring._tail
		local newest = items[pos]
		local cutoff = newest.timestamp - R.HISTORY_SEC
		local oldest, count = newest, 0
		for _ = 1, n do
			local e = items[pos]
			if e.timestamp < cutoff then
				break
			end
			oldest, count = e, count + 1
			pos = pos - 1
			if pos < 1 then
				pos = cap
			end
		end
		local span = newest.timestamp - oldest.timestamp
		if count < R.TREND_MIN_SAMPLES or span <= R.TREND_MIN_SPAN_SEC then
			return nil
		end
		local v1, v0 = newest.velocity, oldest.velocity
		local ax, ay, az = (v1.x - v0.x) / span, (v1.y - v0.y) / span, (v1.z - v0.z) / span
		local mag = sqrt(ax * ax + ay * ay + az * az)
		if mag > R.TREND_MAX_ACCEL_MPS2 then
			local k = R.TREND_MAX_ACCEL_MPS2 / mag
			ax, ay, az = ax * k, ay * k, az * k
		end
		return ax, ay, az
	end

	--- What is remembered of a dropped track: its last look, its trend and the evidence it may hand on.
	--- @param track table
	--- @param now number
	--- @return table
	function Svc.snapshot(track, now)
		local v = track.Velocity
		local ax, ay, az = trend(track.PositionHistory)
		return {
			TrackId = track.TrackId,
			Position = copy3(track.Position),
			Velocity = copy3(v),
			Time = track.LastDetectionTime,
			Speed = sqrt(v.x * v.x + v.y * v.y + v.z * v.z),
			Ax = ax,
			Ay = ay,
			Az = az,
			expiredAt = now,
			FirstDetectionTime = track.FirstDetectionTime,
			DisplayTrackId = track.DisplayTrackId,
			DisplayTrackIdAliases = track.DisplayTrackIdAliases,
			OriginSourceType = track.OriginSourceType,
			TrackIdentification = track.TrackIdentification,
			AssessedAircraftType = track.AssessedAircraftType,
			LastIdentificationTime = track.LastIdentificationTime,
			HarmAssessment = track.HarmAssessment,
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
		}
	end

	--- May a new contact continue this track while it is still held? Only a confirmed ARM with no aircraft evidence:
	--- what a new contact takes is its label. An aircraft keeps its DCS object and resumes its own track; a store it
	--- releases while it is unseen must find it a carrier and a launch-cue parent, not a lost track to continue. An
	--- ARM's label is what is worth carrying over at once, and a contact that inherits it must still be fast enough to
	--- be that ARM.
	--- No allocation.
	--- @param track table
	--- @return boolean
	function Svc.mayBeTakenWhileHeld(track)
		local h = track.HarmAssessment
		if not (h and h.label == HAS.CONFIRMED) then
			return false
		end
		local seen = track.SeenAs
		return seen ~= SEEN.AIRCRAFT and seen ~= SEEN.HELICOPTER and Medusa.Entities.Track.sizeClass(track) ~= "large"
	end

	--- Has a held track been silent long enough to count as lost to new contacts: SILENT_LOOKS of its own refresh
	--- intervals (between its last two looks), and at least SILENT_MIN_SEC? A track with one look has no interval
	--- yet and waits for the track memory. No allocation.
	--- @param track table
	--- @param now number
	--- @return boolean
	function Svc.isSilent(track, now)
		local silence = now - track.LastDetectionTime
		if silence <= R.SILENT_MIN_SEC then
			return false
		end
		local ring = track.PositionHistory
		if ring:size() < 2 then
			return false
		end
		local items, pos = ring._items, ring._tail
		local prevPos = pos > 1 and pos - 1 or ring._capacity
		local interval = items[pos].timestamp - items[prevPos].timestamp
		return silence > R.SILENT_LOOKS * interval
	end

	local function fit(px, py, pz, vx, vy, vz, p, v, r, rv)
		local dx, dy, dz = p.x - px, (p.y - py) * R.ALT_WEIGHT, p.z - pz
		local ex, ey, ez = v.x - vx, v.y - vy, v.z - vz
		return exp(-0.5 * ((dx * dx + dy * dy + dz * dz) / (r * r) + (ex * ex + ey * ey + ez * ez) / (rv * rv)))
	end

	--- How well a contact at p moving at v fits a lost track now: the best of its predictions (last known state,
	--- constant velocity, trend), in (0, 1].
	--- @return number score
	--- @return number gap seconds since the lost track's last look
	function Svc.score(e, p, v, now)
		local dt = now - e.Time
		if dt < 0 then
			dt = 0
		end
		local s = e.Speed
		local r = R.POS_BASE_M + R.POS_PER_SPEED * s * dt + R.POS_PER_GAP2 * dt * dt
		local rv = R.VEL_BASE_MPS + (R.VEL_PER_GAP + R.VEL_PER_SPEED_GAP * s) * dt
		local q, w = e.Position, e.Velocity
		local best = fit(q.x, q.y, q.z, w.x, w.y, w.z, p, v, r, rv)
		local cx, cy, cz = q.x + w.x * dt, q.y + w.y * dt, q.z + w.z * dt
		local cv = fit(cx, cy, cz, w.x, w.y, w.z, p, v, r, rv)
		if cv > best then
			best = cv
		end
		if e.Ax then
			local te = min(dt, R.TREND_MAX_SEC)
			local k = 0.5 * te * te + te * (dt - te)
			local ax, ay, az = e.Ax, e.Ay, e.Az
			local tr =
				fit(cx + ax * k, cy + ay * k, cz + az * k, w.x + ax * te, w.y + ay * te, w.z + az * te, p, v, r, rv)
			if tr > best then
				best = tr
			end
		end
		return best, dt
	end

	--- How far from a new contact a lost track that can still fit may be: its constant-velocity travel, the trend's
	--- extra travel at 3 g, and twice its position uncertainty (beyond that the score is below threshold), capped.
	function Svc.gateRadius(speed, gap)
		local te = min(gap, R.TREND_MAX_SEC)
		local trendM = R.TREND_MAX_ACCEL_MPS2 * (0.5 * te * te + te * (gap - te))
		local r = R.POS_BASE_M + R.POS_PER_SPEED * speed * gap + R.POS_PER_GAP2 * gap * gap
		return min(R.GATE_MAX_M, speed * gap + trendM + 2 * r)
	end

	--- A lost track that was a weapon: seen leaving an aircraft, ARM-like kinematics (SUSPECT or more), a missile,
	--- or seen as a munition. A small return alone is not: a low-observable jet returns smaller than an ARM.
	function Svc.isWeapon(e)
		local aat = e.AssessedAircraftType
		local h = e.HarmAssessment and e.HarmAssessment.label
		return e.LaunchCue ~= nil
			or aat == AAT.HARM
			or aat == AAT.MISSILE
			or h == HAS.CONFIRMED
			or h == HAS.PROBABLE
			or h == HAS.SUSPECT
			or e.SeenAs == SEEN.MUNITION
	end

	local function carriesArmLabel(e, now)
		local h = e.HarmAssessment
		return h ~= nil and h.label == HAS.CONFIRMED and now - e.Time <= R.ARM_LABEL_MAX_GAP_SEC
	end

	--- May a new contact (velocity v, launch cue `cue`) continue lost track e now? A weapon just seen leaving an
	--- aircraft never continues an aircraft's track, nor does a contact much faster than a lost aircraft on a
	--- similar heading (a weapon leaving it while both were unseen). A contact that would inherit an ARM label must
	--- be fast enough to be that ARM after the gap (a jet turning away from its own lost ARM is not). A track still
	--- held is offered only for its ARM label: past the longest gap the label crosses, a contact continuing it would
	--- take the track without the label and leave the ARM's own object to come back as a new, unlabeled track.
	function Svc.mayInherit(e, v, cue, now)
		local speed = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
		if carriesArmLabel(e, now) then
			local keep = 1 - R.ARM_MAX_SLOWDOWN_PER_SEC * (now - e.Time)
			return speed >= e.Speed * math.max(keep, R.ARM_MIN_SPEED_KEPT)
		end
		if e.Held then
			return false
		end
		if Svc.isWeapon(e) then
			return true
		end
		if cue then
			return false
		end
		local w = e.Velocity
		return speed - e.Speed <= R.LAUNCH_SPEED_GAIN_MPS or v.x * w.x + v.y * w.y + v.z * w.z <= 0
	end

	--- A confirmed label without its score. The sticky rule's timers are not reset by a match: confirmedAt (the
	--- label's lifetime cap) runs on through the gap; the not-attacking window is paused over it (unseen flight is
	--- no evidence either way), keeping what was seen before. The kinematic score restarts at 0.
	local function armLabel(h, gap)
		local ep = h.emitterPosition
		return {
			label = HAS.CONFIRMED,
			llr = 0,
			prior = 0,
			scanCount = 0,
			confirmedAt = h.confirmedAt,
			disproofSince = h.disproofSince and h.disproofSince + gap,
			disproofScans = h.disproofScans or 0,
			previousAircraftType = h.previousAircraftType,
			previousIsSeadThreat = h.previousIsSeadThreat,
			emitterPosition = ep and copy3(ep) or nil,
		}
	end

	local function setArmLabel(track, h, gap)
		track.HarmAssessment = armLabel(h, gap)
		track.AssessedAircraftType = AAT.HARM
		track.IsSeadThreat = true
	end

	--- The ARM label across a short gap; otherwise no ARM state at all, and a track that was typed HARM by its
	--- label goes back to what it was before.
	local function carryArm(track, e, now, parts)
		local h = e.HarmAssessment
		if carriesArmLabel(e, now) then
			setArmLabel(track, h, now - e.Time)
			parts[#parts + 1] = "ARM CONFIRMED"
			return
		end
		local aat, sead = e.AssessedAircraftType, e.IsSeadThreat
		if aat == AAT.HARM then
			aat = (h and h.previousAircraftType) or AAT.UNKNOWN
			sead = (h and h.previousIsSeadThreat) or false
		end
		track.AssessedAircraftType = aat or AAT.UNKNOWN
		track.IsSeadThreat = sead
	end

	--- A decoy assessment for a new track: the label and launch evidence, with the straight leg, the held-energy
	--- run and the disproof count restarted (they must not span the gap). Aircraft evidence, the glide's end and the
	--- test-shot time stay.
	local function decoyCopy(d, launchEvidence)
		local da = {}
		for k, val in pairs(d) do
			da[k] = val
		end
		da.runSince = nil
		da.runSec = 0
		da.holdSince = nil
		da.disproofScans = 0
		da.lastTime = nil
		da.launchEvidence = launchEvidence
		return da
	end

	local function energyHeight(p, v)
		return p.y + (v.x * v.x + v.y * v.y + v.z * v.z) / G2
	end

	--- Could the new contact be the lost decoy e after the gap? Not after the longest glide it had left, nor when it
	--- has lost less energy height than any glider would (speed / GLIDE_RATIO_MAX each second, at the slower of the
	--- two speeds).
	local function glideFits(track, e, d, now)
		if d.glideEndsAt and now > d.glideEndsAt then
			return false
		end
		local p, v = track.Position, track.Velocity
		if not p or not v then
			return false
		end
		local speed = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
		local lost = energyHeight(e.Position, e.Velocity) - energyHeight(p, v)
		return lost >= (now - e.Time) * min(speed, e.Speed) / C.Decoy.GLIDE_RATIO_MAX
	end
	Svc.glideFits = glideFits

	--- No decoy label on the new track (the launch evidence too, or the next look could lift it back).
	local function dropDecoyLabel(da)
		da.label = DS.AIRCRAFT
		da.launchEvidence = 0
		da.glideEndsAt = nil
	end

	local function carryDecoy(track, e, strong, quality, parts, now)
		local d = e.DecoyAssessment
		if not d then
			return
		end
		local da = decoyCopy(d, (d.launchEvidence or 0) * quality)
		if not strong then
			-- A loose fit may be another object where the lost one was: no decoy label, no aircraft evidence.
			dropDecoyLabel(da)
			da.aircraftEvidence = nil
		elseif da.label ~= DS.AIRCRAFT and not glideFits(track, e, d, now) then
			dropDecoyLabel(da)
			parts[#parts + 1] = "decoy label dropped (no glide fits)"
		end
		track.DecoyAssessment = da
		if da.label and da.label ~= DS.AIRCRAFT then
			parts[#parts + 1] = "decoy " .. da.label
		end
		if da.aircraftEvidence then
			parts[#parts + 1] = "aircraft evidence"
		end
	end

	--- Size: the old estimate as a prior worth at most just-confident weight (about three looks), scaled by the
	--- match quality, so a few new looks outweigh it (a weapon that claimed its launcher's track sheds the
	--- launcher's size within two scans).
	local function carrySize(track, e, quality, parts)
		local w = (e.SizeWeight or 0) * quality
		if not e.SizeDb or w <= 0 then
			return
		end
		if w > CE.SIZE_CONFIDENT_WEIGHT then
			w = CE.SIZE_CONFIDENT_WEIGHT
		end
		track.SizeDb = e.SizeDb
		track.SizeWeight = w
		track.SizeSpreadDb = sqrt(1 / w + CE.SIZE_SPREAD_FLOOR_DB * CE.SIZE_SPREAD_FLOOR_DB)
		parts[#parts + 1] = string.format("size %.0f dB", e.SizeDb)
	end

	--- Carry a lost track's evidence onto the track that continues it.
	--- @param track table the new track (display id already the lost track's)
	--- @param e table the lost track's snapshot
	--- @param score number the match score
	--- @param now number
	--- @return string what was carried, for the log
	function Svc.carry(track, e, score, now)
		local parts = {}
		local quality = score * exp(-(now - e.Time) / R.EVIDENCE_FADE_SEC)
		local strong = quality >= R.STRONG_QUALITY
		track.TrackIdentification = e.TrackIdentification
		track.LastIdentificationTime = e.LastIdentificationTime
		if e.TrackIdentification and e.TrackIdentification ~= C.TrackIdentification.UNKNOWN then
			parts[#parts + 1] = tostring(e.TrackIdentification)
		end
		carryArm(track, e, now, parts)
		carryDecoy(track, e, strong, quality, parts, now)
		carrySize(track, e, quality, parts)
		-- Only a munition sighting carries: an aircraft sighting would hold back, with no expiry, the ARM evaluation
		-- of a missile that took its lost launcher's track (replay: 12% of new ARMs 5 s after a loss).
		if strong and e.SeenAs == SEEN.MUNITION then
			track.SeenAs = e.SeenAs
			track.SeenAsTime = e.SeenAsTime
			parts[#parts + 1] = "seen " .. tostring(e.SeenAs)
		end
		-- A store that showed no motor is still one (later looks still check it for a motor).
		if strong and e.Release and e.Release.Unpowered then
			Medusa.Entities.Track.carryUnpowered(track, e.Release)
			parts[#parts + 1] = "unpowered"
		end
		if strong and e.LaunchCue and not track.LaunchCue then
			track.LaunchCue = e.LaunchCue
			parts[#parts + 1] = "launch cue"
		end
		if not strong then
			parts[#parts + 1] = "weak fit"
		end
		return #parts > 0 and table.concat(parts, ", ") or "nothing"
	end

	local function isProbableDecoy(e)
		local d = e.DecoyAssessment
		return d ~= nil and d.label == DS.PROBABLE
	end
	Svc.isProbableDecoy = isProbableDecoy

	--- The class a set of tied lost tracks shares: "ARM" (all confirmed ARMs lost no longer than the ARM label
	--- crosses), "DECOY" (all probable decoys), or nil (mixed: nothing is carried).
	function Svc.sharedClass(entries, n, now)
		local arm, decoy = true, true
		for i = 1, n do
			arm = arm and carriesArmLabel(entries[i], now)
			decoy = decoy and isProbableDecoy(entries[i])
		end
		return (arm and "ARM") or (decoy and "DECOY") or nil
	end

	--- Carry the label a tie shares, at the weakest confidence among the tied tracks: the ARM label whose sticky
	--- rule expires first (earliest confirmation), or the decoy label with the least launch evidence. When a lost
	--- track that is no probable decoy also fits nearly as well (`mixedNear`), the decoy label comes back one step
	--- down (SUSPECT) and without launch evidence: a jet flying among decoys (recorded mixed flock, 30 s gap) must
	--- not return as a decoy that long-range SAMs ignore.
	--- @return string what was carried, for the log
	function Svc.carryTie(track, entries, n, class, now, mixedNear)
		local weakest = entries[1]
		if class == "ARM" then
			for i = 2, n do
				local at = entries[i].HarmAssessment.confirmedAt
				local best = weakest.HarmAssessment.confirmedAt
				if at and (not best or at < best) then
					weakest = entries[i]
				end
			end
			setArmLabel(track, weakest.HarmAssessment, now - weakest.Time)
			return "ARM CONFIRMED (shared)"
		end
		for i = 2, n do
			if (entries[i].DecoyAssessment.launchEvidence or 0) < (weakest.DecoyAssessment.launchEvidence or 0) then
				weakest = entries[i]
			end
		end
		local d = weakest.DecoyAssessment
		local da = decoyCopy(d, d.launchEvidence or 0)
		if not glideFits(track, weakest, d, now) then
			return "nothing (shared PROBABLE, but no glide fits the contact)"
		end
		if mixedNear then
			-- No launch evidence either: with it, the next look would lift SUSPECT straight back to PROBABLE.
			da.label = DS.SUSPECT
			da.launchEvidence = 0
			track.DecoyAssessment = da
			return "decoy SUSPECT (shared PROBABLE, another track near)"
		end
		track.DecoyAssessment = da
		return "decoy PROBABLE (shared)"
	end
end
