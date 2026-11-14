require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Track")
require("services.BatteryActivationService")
require("services.DecoyAssessmentService")
require("core.Debrief")

--[[
            ██████╗ ███████╗ ██████╗ ██████╗ ██╗   ██╗    ██████╗ ███████╗███████╗██████╗  ██████╗ ███╗   ██╗███████╗███████╗
            ██╔══██╗██╔════╝██╔════╝██╔═══██╗╚██╗ ██╔╝    ██╔══██╗██╔════╝██╔════╝██╔══██╗██╔═══██╗████╗  ██║██╔════╝██╔════╝
            ██║  ██║█████╗  ██║     ██║   ██║ ╚████╔╝     ██████╔╝█████╗  ███████╗██████╔╝██║   ██║██╔██╗ ██║███████╗█████╗
            ██║  ██║██╔══╝  ██║     ██║   ██║  ╚██╔╝      ██╔══██╗██╔══╝  ╚════██║██╔═══╝ ██║   ██║██║╚██╗██║╚════██║██╔══╝
            ██████╔╝███████╗╚██████╗╚██████╔╝   ██║       ██║  ██║███████╗███████║██║     ╚██████╔╝██║ ╚████║███████║███████╗
            ╚═════╝ ╚══════╝ ╚═════╝ ╚═════╝    ╚═╝       ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝      ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚══════╝

    What this service does
    - Follows each battery's own missiles in flight (the crew knows what it fired and at what) and, when a crew-guided
      flight ends, has DecoyAssessmentService judge whether its target and neighbours reacted.
    - Engage-air-weapons for long/medium-range batteries: off while everything in the battery's reach is a PROBABLE
      decoy or a known aircraft (at least one decoy), or during a fire hold, unless one of its missiles is in flight
      at a contact that may be a weapon (measured in DCS: switching it off ends missiles guiding on weapons, not on
      aircraft; a missile fired while it was off was fired at an aircraft). Not written within EAW_WRITE_SETTLE_SEC
      of the battery's last launch (measured: an SA-11 missile ended when the write came right after its launch).
      Point defence and SHORAD keep it on.
    - Fire discipline (DecoyFireDiscipline): a battery whose own fire-control radar locks a probable decoy, or that
      fires at one, turns engage-air-weapons off for FIRE_HOLD_SEC (a fire hold). Measured in DCS: the lock drops,
      the crew stops engaging weapons and still engages aircraft; the radar re-locks the same decoy 10 to 22 s after
      the option is back on, so a battery holds at most FIRE_HOLDS_PER_TRACK times per decoy (counted by its
      lineage across re-acquisitions). A hold's time and count start when the option actually goes off; it waits
      while the write must (own missile at a possible weapon, a launch just made). No hold, and an early end, when
      the decoy is no longer held against or during a test shot; at most FIRE_HOLD_BUDGET_SEC of holds in any FIRE_HOLD_BUDGET_WINDOW_SEC.
      A decoy whose glide is predicted to end at the battery is never held against. Anti-radiation missiles do not
      stop a hold: they are left to the HARM shutdown response and point defence (measured in DCS: with holds
      stopped in an ARM's last 30 s, the SA-10 fired 10 missiles at decoys in that time and none at the ARMs).
    - A missile in flight when the option goes off is marked cut (EawCut): its end proves nothing (no test-shot
      verdict, no unanswered-launch evidence).
    - Test shot (reconnaissance by fire): when a HOT long/medium-range battery fires at a SUSPECT decoy group that
      is alone in its reach, it holds fire until that missile's flight is over (measured: SA-2, SA-10 and Hawk
      missiles keep guiding under weapons hold), so one missile, not a salvo, tests the group. A test-shot missile
      (held at launch, even if the hold ended early) ending far from its live target, which the network still saw,
      while not about to reach it, lost guidance under the hold (measured: SA-11): no evidence, the group may be
      tested by another battery, and no battery of the network with that launcher type (DCS type name, learned at
      run time) makes test shots again. When the verdict is not sound (target not seen near the missile's last
      sample, missile about to arrive, or only followed past its longest flight) the flight is judged neither way.
    - State lives on the battery (MissilesInFlight, LastLaunchAt, EngageAirWeapons, EawWaitSince, TestShotHold,
      HoldBreaksGuidance, FireHold, FireHoldCounts, FireHoldCountAt, FireHoldSpans, LockReadAt) and the network
      (ctx.holdBreaksTypes: launcher type names learned); controller writes go through BatteryActivationService; what a battery's radars are locked on comes from ctx.lockedTracksOf.

    How others use it
    - IadsNetwork calls recordLaunch from its shot handler and update in the HARM phase, after the decoy pass, with
      ctx.lockedTracksOf (the DCS boundary: Unit.getRadar on the battery's fire-control units, mapped to tracks).
--]]

Medusa.Services.DecoyResponseService = {}

do
	local R = Medusa.Services.DecoyResponseService
	local C = Medusa.Constants
	local D = C.Decoy
	local DS = C.DecoyState
	local AS = C.ActivationState
	local LS = C.TrackLifecycleState
	local Assess = Medusa.Services.DecoyAssessmentService
	local BAS = Medusa.Services.BatteryActivationService
	local Track = Medusa.Entities.Track
	local logger = Medusa.Logger:ns("DecoyResponseService")
	local FILTER_TRACK = { "Track" }
	local _batteryBuffer = {}
	local missileAtWeapon -- defined with engage-air-weapons below

	local function managed(b)
		return D.MANAGED_ROLES[b.Role] == true and not b.IsPointDefense
	end

	local function switchedOn(doctrine, field)
		return not doctrine or (doctrine.DecoyAssessment ~= false and doctrine[field] ~= false)
	end

	-- ── Test shot ──────────────────────────────────────────────────

	--- Why a launch at a SUSPECT target cannot be a test shot from the battery's position and state (nil if it can).
	--- The contact must not reach the battery's inner engagement edge (its minimum range; the battery itself when
	--- unknown) before the missile's flight plus TEST_SHOT_MARGIN_SEC is over: when the hold ends the battery can
	--- still engage it.
	local function batteryBlocks(ctx, b, target, flight)
		local learned = ctx.holdBreaksTypes
		if not switchedOn(ctx.doctrine, "DecoyTestShots") then
			return "switched off"
		elseif not managed(b) or b.ActivationState ~= AS.STATE_HOT then
			return "not a HOT long/medium-range battery"
		elseif b.TestShotHold then
			return "already holding"
		elseif b.HoldBreaksGuidance then
			return "hold breaks guidance"
		elseif learned and flight.LauncherType and learned[flight.LauncherType] then
			return "hold breaks guidance for " .. flight.LauncherType
		elseif (b.TotalAmmoStatus or 0) < D.TEST_SHOT_MIN_AMMO then
			return "missile reserve"
		end
		local p, v, bp = target.Position, target.SmoothedVelocity or target.Velocity, b.Position
		local rx, rz = bp.x - p.x, bp.z - p.z
		local dist = math.sqrt(rx * rx + rz * rz)
		local closing = dist > 1 and v and (rx * v.x + rz * v.z) / dist or 0
		local toEdge = dist - (b.EngagementRangeMin or 0)
		if closing > 0 and toEdge / closing < dist / C.SAM_AVG_MISSILE_SPEED_MPS + D.TEST_SHOT_MARGIN_SEC then
			return "arrives before the flight ends"
		end
		return nil
	end

	--- Why the battery's reach does not hold only the target's untested group (nil if it does).
	local function reachBlocks(ctx, b, target)
		local reach = Assess.reachOf(b, ctx.doctrine)
		local ids = ctx.geoGrid:queryRadius(b.Position, reach, FILTER_TRACK).TrackIds or {}
		for id in pairs(ids) do
			local t = ctx.trackStore:get(id)
			if t and t.LifecycleState == LS.ACTIVE and t.Position then
				if not Assess.inGroupOf(t, target) then
					return "other contacts in reach"
				end
				local tested = t.DecoyAssessment and t.DecoyAssessment.testedAt
				if tested and ctx.now - tested < D.TEST_SHOT_COOLDOWN_SEC then
					return "group already tested"
				end
			end
		end
		return nil
	end

	--- Marks the group's members as tested (DCS's own launch at the group counts as its one shot).
	local function markTested(ctx, target)
		local ids = ctx.geoGrid:queryRadius(target.Position, D.NEIGHBOUR_RADIUS_M, FILTER_TRACK).TrackIds or {}
		ids[target.TrackId] = true
		local count = 0
		for id in pairs(ids) do
			local t = ctx.trackStore:get(id)
			local da = t and t.DecoyAssessment
			if da and Assess.inGroupOf(t, target) then
				local tested = da.testedAt
				if not tested or ctx.now - tested >= D.TEST_SHOT_COOLDOWN_SEC then
					da.testedAt = ctx.now
				end
				count = count + 1
			end
		end
		return count
	end

	--- Clears the group's tested mark (its test shot was lost): another battery may test it.
	local function clearTested(ctx, target)
		local ids = ctx.geoGrid:queryRadius(target.Position, D.NEIGHBOUR_RADIUS_M, FILTER_TRACK).TrackIds or {}
		ids[target.TrackId] = true
		for id in pairs(ids) do
			local t = ctx.trackStore:get(id)
			local da = t and t.DecoyAssessment
			if da and Assess.inGroupOf(t, target) then
				da.testedAt = nil
			end
		end
	end

	local function startTestShot(ctx, b, flight, target)
		local blocked = batteryBlocks(ctx, b, target, flight) or reachBlocks(ctx, b, target)
		local members = markTested(ctx, target)
		if blocked then
			logger:debug(
				string.format("no test shot by %s at track %s: %s", b.GroupName, Track.displayId(target), blocked)
			)
			return
		end
		if BAS.holdFire(b) then
			b.TestShotHold = { TargetTrackId = target.TrackId, Weapon = flight.Weapon, Since = ctx.now }
			-- The flight stays a test shot after the hold ends: its missile may have lost guidance under it.
			flight.TestShot = true
			logger:info(
				string.format(
					"test shot by battery %s at track %s (group of %d): weapons hold until its flight ends",
					b.GroupName,
					Track.displayId(target),
					members
				)
			)
		end
	end

	local function endHold(b, reason)
		BAS.resumeFire(b)
		logger:info(string.format("test shot end for battery %s (%s)", b.GroupName, reason))
	end

	--- A flight no longer followed (the list is full) while its missile may still fly: not judged (its end is not
	--- seen), but a test-shot hold waiting for it ends.
	local function flightDropped(b, f)
		local hold = b.TestShotHold
		if hold and hold.Weapon == f.Weapon then
			endHold(b, "missile no longer followed")
		end
	end

	-- ── Fire discipline ────────────────────────────────────────────

	local function fireDisciplineOn(doctrine)
		return switchedOn(doctrine, "ManageEngageAirWeapons") and switchedOn(doctrine, "DecoyFireDiscipline")
	end

	--- A contact the battery holds its fire against: an active probable decoy whose glide is not predicted to end at
	--- the battery (that one it defends itself against, as point defense would).
	local function holdWorthy(b, t)
		if not t or not t.Position or t.LifecycleState ~= LS.ACTIVE then
			return false
		end
		return Assess.isProbable(t) and not Assess.glideThreatens(t, b.Position)
	end

	local function holdsUsed(b, t)
		local counts = b.FireHoldCounts
		return counts and counts[Assess.holdKey(t)] or 0
	end

	--- Whether a hold of FIRE_HOLD_SEC starting now keeps the battery's holds within FIRE_HOLD_BUDGET_SEC in any
	--- FIRE_HOLD_BUDGET_WINDOW_SEC (spans that ended before the window are dropped).
	local function budgetAllows(b, now)
		local spans = b.FireHoldSpans
		if not spans then
			return true
		end
		local from = now + D.FIRE_HOLD_SEC - D.FIRE_HOLD_BUDGET_WINDOW_SEC
		local used = D.FIRE_HOLD_SEC
		for i = #spans, 1, -1 do
			local s = spans[i]
			local e = s.e or now
			if e <= from then
				table.remove(spans, i)
			else
				used = used + e - math.max(s.s, from)
			end
		end
		return used <= D.FIRE_HOLD_BUDGET_SEC
	end

	--- Why the battery may not hold against `t` now (nil if it may).
	local function holdBlocked(ctx, b, t)
		if b.FireHold then
			return "already holding"
		elseif b.TestShotHold then
			return "test shot"
		elseif not holdWorthy(b, t) then
			return "not a probable decoy held against"
		elseif holdsUsed(b, t) >= D.FIRE_HOLDS_PER_TRACK then
			return "holds used"
		elseif not budgetAllows(b, ctx.now) then
			return "hold budget"
		end
		return nil
	end

	--- Asks for a fire hold against probable decoy `t`. It starts (time and count) when engage-air-weapons actually
	--- goes off, in updateEngageAirWeapons; until then it waits (an own missile at a possible weapon, a launch just
	--- made). Returns true when asked.
	local function requestFireHold(ctx, b, t, trigger)
		local blocked = holdBlocked(ctx, b, t)
		if blocked then
			logger:debug(
				string.format(
					"no fire hold by %s against %s (%s): %s",
					b.GroupName,
					Track.displayId(t),
					trigger,
					blocked
				)
			)
			return false
		end
		b.FireHold = { TrackId = t.TrackId, Trigger = trigger, Since = ctx.now }
		return true
	end

	local function forgetCounts(b, now)
		local at = b.FireHoldCountAt
		for key, last in pairs(at) do
			if now - last > D.FIRE_HOLD_COUNT_FORGET_SEC then
				at[key] = nil
				b.FireHoldCounts[key] = nil
			end
		end
	end

	--- The decoy a waiting hold may start against now, or nil (the hold is dropped: decoy gone, holds used or budget).
	local function startableHold(ctx, b, hold)
		local t = ctx.trackStore:get(hold.TrackId)
		if not t or holdsUsed(b, t) >= D.FIRE_HOLDS_PER_TRACK or not budgetAllows(b, ctx.now) then
			b.FireHold = nil
			return nil
		end
		return t
	end

	--- Starts hold `hold` against decoy `t` (startableHold): engage-air-weapons is off from now for FIRE_HOLD_SEC (the
	--- crew's system stops engaging weapons and drops its lock while aircraft are still engaged), counted against the
	--- decoy (at most FIRE_HOLDS_PER_TRACK per decoy and battery: the radar re-locks the same decoy after a hold) and
	--- the budget, with a debrief line and a log line.
	local function startFireHold(ctx, b, hold, t)
		local da = t.DecoyAssessment
		da.holdLineage = da.holdLineage or t.TrackId
		local key = da.holdLineage
		local counts, at = b.FireHoldCounts, b.FireHoldCountAt
		if not counts then
			counts, at = {}, {}
			b.FireHoldCounts, b.FireHoldCountAt = counts, at
		else
			forgetCounts(b, ctx.now)
		end
		local n = (counts[key] or 0) + 1
		counts[key], at[key] = n, ctx.now
		hold.Until = ctx.now + D.FIRE_HOLD_SEC
		local span = { s = ctx.now }
		hold.Span = span
		local spans = b.FireHoldSpans
		if not spans then
			spans = {}
			b.FireHoldSpans = spans
		end
		spans[#spans + 1] = span
		local waited = ctx.now - hold.Since
		Medusa.Debrief.emit(
			ctx.networkId,
			ctx.now,
			"DECOY_FIRE_HOLD",
			"battery",
			b.GroupName,
			"track",
			Track.displayId(t),
			"trigger",
			hold.Trigger,
			"sec",
			D.FIRE_HOLD_SEC,
			"n",
			n,
			"waited",
			waited >= 0.5 and string.format("%.0f", waited) or nil
		)
		logger:info(
			string.format(
				"fire hold %d/%d for battery %s against probable decoy %s (%s)%s",
				n,
				D.FIRE_HOLDS_PER_TRACK,
				b.GroupName,
				Track.displayId(t),
				hold.Trigger == "lock" and "its radar locked it" or "it fired at it",
				waited >= 0.5 and string.format(", after waiting %.0f s", waited) or ""
			)
		)
	end

	--- Ends the hold (its span stays on the hold budget up to now).
	local function endFireHold(ctx, b, reason)
		local hold = b.FireHold
		b.FireHold = nil
		if hold.Until then
			hold.Span.e = ctx.now
			logger:info(string.format("fire hold end for battery %s (%s)", b.GroupName, reason))
		else
			logger:debug(string.format("fire hold by %s not started: %s", b.GroupName, reason))
		end
	end

	--- Why a hold (started or waiting) ends now (nil if it goes on).
	local function holdEnds(ctx, b, hold)
		if b.ActivationState ~= AS.STATE_HOT then
			return "left HOT"
		elseif hold.Until and ctx.now >= hold.Until then
			return "time up"
		elseif not holdWorthy(b, ctx.trackStore:get(hold.TrackId)) then
			return "decoy no longer held against"
		elseif b.TestShotHold then
			return "test shot"
		end
		return nil
	end

	local _locked = {}

	--- Ends a fire hold that is over; with a probable decoy the battery may still hold against in reach and no hold,
	--- reads what its own fire-control radars are locked on (ctx.lockedTracksOf, at most every
	--- FIRE_HOLD_LOCK_READ_SEC) and asks for a hold against a probable decoy among them: measured, the lock shows 5 to
	--- 20 s before the launch on an SA-11 TELAR. Only for a HOT battery.
	local function updateFireDiscipline(ctx, b)
		local hold = b.FireHold
		if hold then
			local reason = holdEnds(ctx, b, hold)
			if not reason then
				return
			end
			endFireHold(ctx, b, reason)
		end
		local reach = b.DecoyReach
		if
			b.ActivationState ~= AS.STATE_HOT
			or b.TestShotHold
			or not ctx.lockedTracksOf
			or not reach
			or reach.time ~= ctx.now
			or reach.holdable == 0
			or (b.LockReadAt and ctx.now - b.LockReadAt < D.FIRE_HOLD_LOCK_READ_SEC)
		then
			return
		end
		b.LockReadAt = ctx.now
		local n = ctx.lockedTracksOf(b, _locked)
		for i = 1, n do
			local t = ctx.trackStore:get(_locked[i])
			if t and holdWorthy(b, t) and holdsUsed(b, t) < D.FIRE_HOLDS_PER_TRACK then
				if requestFireHold(ctx, b, t, "lock") then
					return
				end
			end
		end
	end

	--- A probable decoy the battery treats as a decoy, not as a weapon: one whose glide is predicted to end at the
	--- battery is a weapon (it defends itself against it).
	local function decoyNotWeapon(t, b)
		return Assess.isProbable(t) and not Assess.glideThreatens(t, b.Position)
	end

	--- Which flight a full list drops: the oldest at an aircraft or a probable decoy that is not gliding onto the
	--- battery (switching engage-air-weapons off cannot end it, so the guard does not need it), else the oldest;
	--- never a test shot while another can go.
	local function droppable(ctx, b, list)
		local fallback
		for i = 1, #list do
			local f = list[i]
			if not f.TestShot then
				local t = f.TargetTrackId and ctx.trackStore:get(f.TargetTrackId)
				if f.AtAircraft or (t and (decoyNotWeapon(t, b) or Assess.hasAircraftEvidence(t))) then
					return i
				end
				fallback = fallback or i
			end
		end
		return fallback or 1
	end

	--- A battery fired a missile: follow its flight; a launch at a SUSPECT group may be its test shot, one at a
	--- probable decoy asks for a fire hold (not while one is asked or on: a salvo counts once).
	--- @param ctx table { trackStore, geoGrid, doctrine, now, networkId }
	--- @param b table Battery
	--- @param flight table { Weapon, LaunchTime, TargetTrackId|nil, Guided, LauncherType|nil (DCS type name) }
	function R.recordLaunch(ctx, b, flight)
		if ctx.doctrine and ctx.doctrine.DecoyAssessment == false then
			return
		end
		local list = b.MissilesInFlight
		if not list then
			list = {}
			b.MissilesInFlight = list
		end
		local target = flight.TargetTrackId and ctx.trackStore:get(flight.TargetTrackId)
		-- Fired while engage-air-weapons was off: the crew's system could only engage an aircraft.
		flight.AtAircraft = b.EngageAirWeapons == false
		if #list >= D.MAX_MISSILES_IN_FLIGHT then
			flightDropped(b, table.remove(list, droppable(ctx, b, list)))
		end
		list[#list + 1] = flight
		b.LastLaunchAt = flight.LaunchTime
		if target and target.Position and Assess.label(target) == DS.SUSPECT then
			startTestShot(ctx, b, flight, target)
		elseif
			target
			and not b.FireHold
			and Assess.isProbable(target)
			and fireDisciplineOn(ctx.doctrine)
			and managed(b)
			and b.ActivationState == AS.STATE_HOT
		then
			requestFireHold(ctx, b, target, "shot")
		end
	end

	-- ── Flights and holds ──────────────────────────────────────────

	local function speedOf(v)
		return v and math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) or 0
	end

	--- Did the test-shot missile lose guidance under the hold? "lost", "kept" (ended near its target, or no sample: a
	--- normal flight) or nil (no verdict). Far: its last sample, less what it and its target can have moved since, is
	--- still farther than TEST_SHOT_LOST_MISS_M from its still active target. A far missile is "lost" only when the
	--- network saw the target near the missile's last sample (TEST_SHOT_FRESH_SEC), the missile really ended, and it
	--- was not about to arrive (range not decreasing, or more than TEST_SHOT_LOST_MIN_TO_GO_SEC to go). A target that
	--- showed aircraft evidence gives no verdict: a jet may have defeated the missile.
	local function testShotVerdict(ctx, f, ended)
		local target = f.LastPoint and f.TargetTrackId and ctx.trackStore:get(f.TargetTrackId)
		local p = target and target.LifecycleState == LS.ACTIVE and target.Position
		if not p then
			return "kept"
		end
		local m = f.LastPoint
		local seenAt = target.LastDetectionTime or ctx.now
		local tv = target.SmoothedVelocity or target.Velocity
		local dx, dy, dz = m.x - p.x, m.y - p.y, m.z - p.z
		local moved = f.LastSpeed * (ctx.now - f.LastPointAt) + speedOf(tv) * math.abs(ctx.now - seenAt)
		if math.sqrt(dx * dx + dy * dy + dz * dz) - moved <= D.TEST_SHOT_LOST_MISS_M then
			return "kept"
		end
		if not ended or seenAt < f.LastPointAt - D.TEST_SHOT_FRESH_SEC or Assess.hasAircraftEvidence(target) then
			return nil
		end
		-- Range and its rate at the missile's last sample (the target moved to that time).
		local lag = f.LastPointAt - seenAt
		local rx = p.x + (tv and tv.x or 0) * lag - m.x
		local ry = p.y + (tv and tv.y or 0) * lag - m.y
		local rz = p.z + (tv and tv.z or 0) * lag - m.z
		local range = math.sqrt(rx * rx + ry * ry + rz * rz)
		local mv = f.LastVelocity
		local rate = 0
		if range > 1 then
			rate = (
				rx * ((tv and tv.x or 0) - mv.x)
				+ ry * ((tv and tv.y or 0) - mv.y)
				+ rz * ((tv and tv.z or 0) - mv.z)
			) / range
		end
		if rate < 0 and range / -rate <= D.TEST_SHOT_LOST_MIN_TO_GO_SEC then
			return nil
		end
		return "lost"
	end

	local function flightEnded(ctx, b, f, ended)
		local hold = b.TestShotHold
		local held = hold and hold.Weapon == f.Weapon
		local verdict = "kept"
		if f.EawCut then
			-- Medusa's own engage-air-weapons write may have ended it: proves nothing either way.
			verdict = nil
			if not f.TestShot then
				verdict = "cut"
			end
		elseif f.TestShot then
			verdict = testShotVerdict(ctx, f, ended)
		end
		if verdict == "lost" then
			b.HoldBreaksGuidance = true
			local launcher = f.LauncherType
			if launcher and ctx.holdBreaksTypes then
				ctx.holdBreaksTypes[launcher] = true
			end
			local target = ctx.trackStore:get(f.TargetTrackId)
			if target and target.Position then
				clearTested(ctx, target)
			end
			logger:info(
				string.format(
					"test shot by battery %s lost its missile under weapons hold; no more test shots %s",
					b.GroupName,
					launcher and ("with launcher " .. launcher .. " in the network") or "for this battery"
				)
			)
		elseif verdict == nil then
			logger:info(
				string.format(
					"test shot by battery %s: %s, no verdict",
					b.GroupName,
					f.EawCut and "engage-air-weapons went off during its flight" or "missile ended far from its target"
				)
			)
		elseif verdict == "kept" and f.Guided then
			Assess.judgeLaunch(f, ctx.now, ctx.trackStore, ctx.geoGrid, ctx.networkId)
		end
		if held then
			endHold(b, "missile flight over")
		end
	end

	--- Remembers where the test-shot missile is and how it flies (only test-shot weapons; tables reused).
	local function sampleHeld(ctx, f)
		local point = GetWeaponPoint(f.Weapon)
		if point then
			local last = f.LastPoint
			if not last then
				last = {}
				f.LastPoint = last
			end
			last.x, last.y, last.z = point.x, point.y, point.z
			local v = GetWeaponVelocity(f.Weapon)
			local lv = f.LastVelocity
			if not lv then
				lv = {}
				f.LastVelocity = lv
			end
			lv.x, lv.y, lv.z = v and v.x or 0, v and v.y or 0, v and v.z or 0
			f.LastSpeed = speedOf(v)
			f.LastPointAt = ctx.now
		end
	end

	local function updateFlights(ctx, b)
		local list = b.MissilesInFlight
		for i = #list, 1, -1 do
			local f = list[i]
			local exists = IsWeaponExist(f.Weapon)
			if exists == false or ctx.now - f.LaunchTime > D.MAX_FLIGHT_SEC then
				table.remove(list, i)
				flightEnded(ctx, b, f, exists == false)
			elseif exists and f.TestShot then
				sampleHeld(ctx, f)
			end
		end
	end

	local function updateHold(ctx, b)
		if b.ActivationState ~= AS.STATE_HOT then
			b.TestShotHold = nil
			logger:info(string.format("test shot end for battery %s (left HOT)", b.GroupName))
			return
		end
		local reach = b.DecoyReach
		local target = ctx.trackStore:get(b.TestShotHold.TargetTrackId)
		if ctx.now - b.TestShotHold.Since >= D.TEST_SHOT_MAX_HOLD_SEC then
			endHold(b, "time limit")
		elseif target and (Assess.label(target) ~= DS.SUSPECT or Assess.hasAircraftEvidence(target)) then
			endHold(b, "target no longer a suspect decoy")
		elseif reach and reach.time == ctx.now and reach.outsiders > 0 then
			endHold(b, "another contact in reach")
		end
	end

	-- ── Engage-air-weapons ─────────────────────────────────────────

	--- A missile of the battery in flight at a contact that is neither a probable decoy (one not gliding onto the
	--- battery) nor a known aircraft (or at no track): switching engage-air-weapons off could end it (measured: the
	--- switch ends missiles guiding on weapons, not on aircraft). Returns that flight, or nil.
	function missileAtWeapon(ctx, b)
		local list = b.MissilesInFlight
		if not list then
			return nil
		end
		for i = 1, #list do
			local f = list[i]
			local target = not f.AtAircraft and f.TargetTrackId and ctx.trackStore:get(f.TargetTrackId)
			if
				not f.AtAircraft
				and not (target and (decoyNotWeapon(target, b) or Assess.hasAircraftEvidence(target)))
			then
				return f
			end
		end
		return nil
	end
	R._missileAtWeapon = missileAtWeapon

	local function onReason(reach, fresh, guarded)
		if not fresh then
			return "not assessed"
		elseif guarded then
			return "own missile in flight at a contact that may be a weapon"
		elseif reach.probable == 0 then
			return "no probable decoy in reach"
		elseif reach.other > 0 then
			return string.format("%d contacts in reach neither probable decoys nor known aircraft", reach.other)
		end
		return "fire hold over"
	end

	--- Engage-air-weapons goes off: a missile of the battery still in flight not known to be at an aircraft may end
	--- under the write (measured: weapons-guided missiles do), so its end proves nothing (no test-shot verdict, no
	--- unanswered-launch evidence).
	local function markCut(b)
		local list = b.MissilesInFlight
		for i = 1, list and #list or 0 do
			if not list[i].AtAircraft then
				list[i].EawCut = true
			end
		end
	end

	--- Launches less than EAW_WRITE_SETTLE_SEC apart keep a write waiting: logged once when it has waited
	--- EAW_WRITE_STARVED_SEC (ripple fire).
	local function writeWaits(ctx, b, off)
		local since = b.EawWaitSince
		if not since then
			b.EawWaitSince = ctx.now
		elseif not b.EawWaitLogged and ctx.now - since >= D.EAW_WRITE_STARVED_SEC then
			b.EawWaitLogged = true
			logger:info(
				string.format(
					"engage-air-weapons %s for battery %s waits: it has launched less than %d s apart for %.0f s",
					off and "off" or "on",
					b.GroupName,
					D.EAW_WRITE_SETTLE_SEC,
					ctx.now - since
				)
			)
		end
	end

	local function updateEngageAirWeapons(ctx, b)
		if b.ActivationState ~= AS.STATE_HOT then
			return
		end
		local reach = b.DecoyReach
		local fresh = reach ~= nil and reach.time == ctx.now
		local alone = fresh and reach.probable > 0 and reach.other == 0
		local hold = b.FireHold
		local guard = (alone or hold ~= nil) and missileAtWeapon(ctx, b) ~= nil
		local off = (alone or hold ~= nil) and not guard
		if (b.EngageAirWeapons ~= false) == not off then
			b.EawWaitSince, b.EawWaitLogged = nil, nil
			if off and hold and not hold.Until then
				local t = startableHold(ctx, b, hold)
				if t then
					startFireHold(ctx, b, hold, t) -- already off (decoys alone): the hold starts now
				end
			end
			return
		end
		-- Measured (SA-11): a write a few hundredths of a second after a launch ended that missile, even one at an
		-- aircraft; writes 0.7 s or more after it did not. The write waits.
		if b.LastLaunchAt and ctx.now - b.LastLaunchAt < D.EAW_WRITE_SETTLE_SEC then
			writeWaits(ctx, b, off)
			return
		end
		b.EawWaitSince, b.EawWaitLogged = nil, nil
		local holdTarget
		if off and hold and not hold.Until then
			holdTarget = startableHold(ctx, b, hold)
			if not holdTarget then
				hold = nil
				off = alone
				if (b.EngageAirWeapons ~= false) == not off then
					return
				end
			end
		end
		if not BAS.setEngageAirWeapons(b, not off) then
			return -- not written: a waiting hold stays waiting, uncounted
		end
		if holdTarget then
			startFireHold(ctx, b, hold, holdTarget)
		end
		if off then
			markCut(b)
		end
		if off and hold then
			local t = ctx.trackStore:get(hold.TrackId)
			logger:info(
				string.format(
					"engage-air-weapons off for battery %s (fire hold against probable decoy %s, %s)",
					b.GroupName,
					t and Track.displayId(t) or tostring(hold.TrackId),
					hold.Trigger
				)
			)
		elseif off then
			logger:info(
				string.format(
					"engage-air-weapons off for battery %s (%d probable decoys, %d known aircraft in reach)",
					b.GroupName,
					reach.probable,
					reach.aircraft
				)
			)
		else
			logger:info(
				string.format("engage-air-weapons on for battery %s (%s)", b.GroupName, onReason(reach, fresh, guard))
			)
		end
	end

	--- The HARM phase's decoy response, after DecoyAssessmentService.assess: ends flights, test-shot holds and sets
	--- engage-air-weapons. Does nothing when decoy assessment is switched off.
	--- @param ctx table { trackStore, batteryStore, geoGrid, doctrine, now }
	function R.update(ctx)
		if ctx.doctrine and ctx.doctrine.DecoyAssessment == false then
			return
		end
		local manageEaw = switchedOn(ctx.doctrine, "ManageEngageAirWeapons")
		local fireDiscipline = fireDisciplineOn(ctx.doctrine)
		local batteries = ctx.batteryStore:getAll(_batteryBuffer)
		for i = 1, #batteries do
			local b = batteries[i]
			if b.MissilesInFlight then
				updateFlights(ctx, b)
			end
			if b.TestShotHold then
				updateHold(ctx, b)
			end
			if manageEaw and managed(b) then
				if fireDiscipline or b.FireHold then
					updateFireDiscipline(ctx, b)
				end
				updateEngageAirWeapons(ctx, b)
			end
		end
	end
end
