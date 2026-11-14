local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Track")
require("entities.Battery")
require("services.Services")
require("services.stores.TrackStore")
require("services.stores.BatteryStore")
require("services.SpatialQuery")
require("services.HarmDetectionService")

local mockTime = 1000

local ulidCounter = 0
local uniqueCounter = 0

local function nextUnique()
	uniqueCounter = uniqueCounter + 1
	return uniqueCounter
end

local function setupMocks()
	mockTime = 1000
	GetTime = function()
		return mockTime
	end
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
end

local function makeMockGeoGrid(batteryStore)
	return {
		queryRadius = function(_, _, _, _)
			local ids = {}
			local all = batteryStore:getAll({})
			for i = 1, #all do
				ids[all[i].BatteryId] = true
			end
			return { BatteryIds = ids }
		end,
	}
end

local function makeTrack(overrides)
	local base = {
		Position = { x = 1000, y = 5000, z = 2000 },
		Velocity = { x = 300, y = -30, z = 150 },
		NetworkId = overrides and overrides.NetworkId or string.format("net-%d", nextUnique()),
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return Medusa.Entities.Track.new(base)
end

local function makeBattery(overrides)
	local base = {
		NetworkId = 1,
		GroupId = overrides and overrides.GroupId or nextUnique(),
		GroupName = overrides and overrides.GroupName or string.format("SAM-%d", nextUnique()),
		OperationalStatus = "ACTIVE",
		ActivationState = "STATE_WARM",
		Position = { x = 5000, y = 0, z = 5000 },
		EngagementRangeMax = 50000,
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return Medusa.Entities.Battery.new(base)
end

local function makeBatteryStoreAndGrid(batteries)
	local store = Medusa.Services.BatteryStore:new()
	for i = 1, #batteries do
		store:add(batteries[i])
	end
	return store, makeMockGeoGrid(store)
end

-- ARM-like kinematics: velocity vector aims directly at emitter in 3D for low CPA
local function populateArmHistory(track, count, startTime, emitterPos)
	local ex = emitterPos and emitterPos.x or 10000
	local ey = emitterPos and emitterPos.y or 0
	local ez = emitterPos and emitterPos.z or 6000
	-- Start position: offset from emitter so velocity vector can aim at it
	local startX, startY, startZ = ex - 6000, ey + 4000, ez - 3000
	for i = 1, count do
		local t = startTime + i
		local speed = 700 - i * 10
		-- Current position progresses toward emitter
		local frac = i / (count + 5)
		local px = startX + (ex - startX) * frac
		local py = startY + (ey - startY) * frac
		local pz = startZ + (ez - startZ) * frac
		-- Velocity points from current pos toward emitter
		local dx = ex - px
		local dy = ey - py
		local dz = ez - pz
		local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
		local vx = dx / dist * speed
		local vy = dy / dist * speed
		local vz = dz / dist * speed
		Medusa.Entities.Track.update(track, { x = px, y = py, z = pz }, { x = vx, y = vy, z = vz }, t)
	end
end

-- Non-ARM kinematics: slow, level, wandering
local function populateNonArmHistory(track, count, startTime)
	for i = 1, count do
		local t = startTime + i
		local angle = i * 0.3
		Medusa.Entities.Track.update(
			track,
			{ x = 1000 + i * 200, y = 5000, z = 2000 + i * 100 },
			{ x = 200 * math.cos(angle), y = 0, z = 200 * math.sin(angle) },
			t
		)
	end
end

-- Straight, level flight at a given speed along a unit heading (dx, dz), one second per sample.
local function populateStraightHistory(track, count, startTime, from, dir, speed)
	for i = 1, count do
		local t = startTime + i
		Medusa.Entities.Track.update(
			track,
			{ x = from.x + dir.x * speed * i, y = from.y, z = from.z + dir.z * speed * i },
			{ x = dir.x * speed, y = 0, z = dir.z * speed },
			t
		)
	end
end

local HDS_ = Medusa.Services.HarmDetectionService

-- Fly a 700 m/s diving missile straight at `target` from `from`, one scan per `scanSec`, until the real SPRT path
-- confirms it. Returns the track's state and the time and position after the last scan.
local function confirmByFlight(track, grid, store, from, target, scanSec)
	local dx, dy, dz = target.x - from.x, target.y - from.y, target.z - from.z
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	local v = { x = dx / d * 700, y = dy / d * 700, z = dz / d * 700 }
	local t = mockTime
	local p = { x = from.x, y = from.y, z = from.z }
	for _ = 1, 20 do
		t = t + scanSec
		p = { x = p.x + v.x * scanSec, y = p.y + v.y * scanSec, z = p.z + v.z * scanSec }
		Medusa.Entities.Track.update(track, p, v, t)
		local label = HDS_._evaluateTrack(track, grid, store)
		if label == "CONFIRMED" then
			return track.HarmAssessment, t, p
		end
	end
	error("test missile was never confirmed")
end

-- After confirmation, fly level at `speed` along heading `dir` for `scans` scans `scanSec` apart. Returns labels.
local function flyOn(track, grid, store, t, p, dir, speed, scans, scanSec, alt)
	local labels = {}
	for i = 1, scans do
		t = t + scanSec
		p = { x = p.x + dir.x * speed * scanSec, y = alt or p.y, z = p.z + dir.z * speed * scanSec }
		Medusa.Entities.Track.update(track, p, { x = dir.x * speed, y = 0, z = dir.z * speed }, t)
		labels[i] = HDS_._evaluateTrack(track, grid, store)
	end
	return labels, t, p
end

local function makeCtx(fields)
	return {
		trackStore = fields.trackStore,
		batteryStore = fields.batteryStore,
		geoGrid = fields.geoGrid,
		doctrine = fields.doctrine,
		now = fields.now or 1000,
		networkId = fields.networkId,
	}
end

-- == computeScanLLR tests ==

TestComputeScanLLR = {}

function TestComputeScanLLR:setUp()
	setupMocks()
end

function TestComputeScanLLR:test_arm_like_features_positive_llr()
	-- Features matching ARM class means: high speed, diving, straight, decelerating, low CPA, converging
	local feat = { 650, 0.5236, 0.005, -15, 25, -50, -600, -300 }
	local llr = Medusa.Services.HarmDetectionService._computeScanLLR(feat)
	lu.assertTrue(llr > 0)
end

function TestComputeScanLLR:test_non_arm_features_negative_llr()
	-- Features matching non-ARM class: slow, level, turning, no accel, far CPA, no closure
	local feat = { 280, 0.087, 0.035, 0, 3000, -5, -150, -10 }
	local llr = Medusa.Services.HarmDetectionService._computeScanLLR(feat)
	lu.assertTrue(llr < 0)
end

function TestComputeScanLLR:test_mixed_features_between_extremes()
	-- Some ARM-like, some non-ARM-like features
	local armFeat = { 650, 0.5236, 0.005, -15, 25, -50, -600, -300 }
	local nonFeat = { 280, 0.087, 0.035, 0, 3000, -5, -150, -10 }
	local mixFeat = { 650, 0.087, 0.005, 0, 25, -5, -150, -300 }
	local armLlr = Medusa.Services.HarmDetectionService._computeScanLLR(armFeat)
	local nonLlr = Medusa.Services.HarmDetectionService._computeScanLLR(nonFeat)
	local mixLlr = Medusa.Services.HarmDetectionService._computeScanLLR(mixFeat)
	lu.assertTrue(mixLlr > nonLlr)
	lu.assertTrue(mixLlr < armLlr)
end

-- == evaluateTrack tests ==

TestEvaluateTrack = {}

function TestEvaluateTrack:setUp()
	setupMocks()
end

function TestEvaluateTrack:test_returns_evaluating_with_one_history_entry()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = { x = 10000, y = 0, z = 6000 } })
	local store, grid = makeBatteryStoreAndGrid({ battery })
	local label, state = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	lu.assertEquals(label, "EVALUATING")
	lu.assertNil(state)
end

function TestEvaluateTrack:test_below_speed_gate_returns_cleared()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	Medusa.Entities.Track.update(track, { x = 100, y = 100, z = 100 }, { x = 10, y = 0, z = 10 }, mockTime + 1)
	Medusa.Entities.Track.update(track, { x = 120, y = 100, z = 120 }, { x = 10, y = 0, z = 10 }, mockTime + 2)
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = { x = 10000, y = 0, z = 6000 } })
	local store, grid = makeBatteryStoreAndGrid({ battery })
	local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	lu.assertEquals(label, "CLEARED")
end

-- Level flight for `scans` seconds then a straight 700 m/s dive at the emitter; returns the first ARM-like scan
-- index at which the track confirmed (nil if never) and the extreme scores seen.
local function levelThenDive(levelScans, emitterPos)
	local track = makeTrack({ AssessedAircraftType = "FIXED_WING" })
	local battery = makeBattery({ ActivationState = "STATE_HOT", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })
	local t = mockTime
	local p = { x = emitterPos.x - 80000, y = 8000, z = emitterPos.z + 30000 }
	local minLlr, maxLlr = 0, 0
	for _ = 1, levelScans do
		t = t + 1
		p = { x = p.x, y = 8000, z = p.z - 250 }
		Medusa.Entities.Track.update(track, p, { x = 0, y = 0, z = -250 }, t)
		Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
		local st = track.HarmAssessment
		if st then
			minLlr = math.min(minLlr, st.llr)
		end
	end
	local dx, dy, dz = emitterPos.x - p.x, emitterPos.y - p.y, emitterPos.z - p.z
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	local v = { x = dx / d * 700, y = dy / d * 700, z = dz / d * 700 }
	for i = 1, 30 do
		t = t + 1
		p = { x = p.x + v.x, y = p.y + v.y, z = p.z + v.z }
		Medusa.Entities.Track.update(track, p, v, t)
		local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
		maxLlr = math.max(maxLlr, track.HarmAssessment.llr)
		if label == "CONFIRMED" then
			return i, minLlr, maxLlr
		end
	end
	return nil, minLlr, maxLlr
end

function TestEvaluateTrack:test_jet_tracked_level_for_minutes_can_still_confirm_on_an_arm_like_run()
	local confirmedAt, minLlr = levelThenDive(300, { x = 0, y = 0, z = 0 })
	lu.assertEquals(minLlr, -Medusa.Constants.HARM_SPRT_ACCUMULATED_LLR_LIMIT)
	lu.assertNotNil(confirmedAt)
	lu.assertTrue(confirmedAt <= 8)
end

function TestEvaluateTrack:test_score_stays_within_its_bound()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 0, y = 0, z = 0 }
	local store, grid =
		makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_HOT", Position = emitterPos }) })
	local p = { x = -60000, y = 12000, z = 0 }
	local v = { x = 700 * 60000 / math.sqrt(60000 * 60000 + 12000 * 12000), y = 0, z = 0 }
	v.y = -v.x * 12000 / 60000
	for i = 1, 60 do
		p = { x = p.x + v.x, y = p.y + v.y, z = p.z }
		Medusa.Entities.Track.update(track, p, v, mockTime + i)
		Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
		local st = track.HarmAssessment
		lu.assertTrue(st == nil or st.llr <= Medusa.Constants.HARM_SPRT_ACCUMULATED_LLR_LIMIT)
	end
	lu.assertEquals(track.HarmAssessment.llr, Medusa.Constants.HARM_SPRT_ACCUMULATED_LLR_LIMIT)
end

function TestEvaluateTrack:test_emitter_beyond_max_arm_range_is_ignored()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	Medusa.Entities.Track.update(track, { x = 2000, y = 5000, z = 3000 }, { x = 600, y = -100, z = 0 }, mockTime + 1)
	Medusa.Entities.Track.update(track, { x = 2600, y = 4900, z = 3000 }, { x = 600, y = -100, z = 0 }, mockTime + 2)
	local far = Medusa.Constants.HARM_MAX_RANGE_M + 5000
	local battery = makeBattery({ ActivationState = "STATE_HOT", Position = { x = 2600 + far, y = 0, z = 3000 } })
	local store, grid = makeBatteryStoreAndGrid({ battery })
	local label, state = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	lu.assertEquals(label, "EVALUATING")
	lu.assertNil(state)
end

function TestEvaluateTrack:test_emitter_index_holds_only_warm_or_hot_non_aaa_batteries()
	local warm = makeBattery({ ActivationState = "STATE_WARM", Position = { x = 1, y = 0, z = 1 } })
	local hot = makeBattery({ ActivationState = "STATE_HOT", Position = { x = 2, y = 0, z = 2 } })
	local cold = makeBattery({ ActivationState = "STATE_COLD", Position = { x = 3, y = 0, z = 3 } })
	local aaa = makeBattery({ ActivationState = "STATE_HOT", Role = "AAA", Position = { x = 4, y = 0, z = 4 } })
	local store = makeBatteryStoreAndGrid({ warm, hot, cold, aaa })
	local index = Medusa.Services.HarmDetectionService.buildEmitterIndex(store)
	lu.assertEquals(index.activeCount, 2)
	local xs = { [index.active[1].x] = true, [index.active[2].x] = true }
	lu.assertTrue(xs[1] and xs[2])
	local empty = Medusa.Services.HarmDetectionService.buildEmitterIndex(makeBatteryStoreAndGrid({ cold }))
	lu.assertEquals(empty.activeCount, 0)
	lu.assertNil(empty.active[1])
end

function TestEvaluateTrack:test_no_emitting_battery_returns_evaluating()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	Medusa.Entities.Track.update(track, { x = 2000, y = 5000, z = 3000 }, { x = 600, y = -100, z = 300 }, mockTime + 1)
	Medusa.Entities.Track.update(track, { x = 2600, y = 4900, z = 3300 }, { x = 600, y = -100, z = 300 }, mockTime + 2)
	local battery = makeBattery({ ActivationState = "STATE_COLD", Position = { x = 10000, y = 0, z = 6000 } })
	local store, grid = makeBatteryStoreAndGrid({ battery })
	local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	lu.assertEquals(label, "EVALUATING")
end

function TestEvaluateTrack:test_hot_independent_aaa_is_not_an_emitter()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	populateArmHistory(track, 2, mockTime, emitterPos)
	local battery = makeBattery({
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		Position = emitterPos,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 1,
			UnitName = "gun",
			Roles = { Medusa.Constants.BatteryUnitRole.AAA },
		}),
	}
	local store, grid = makeBatteryStoreAndGrid({ battery })

	local label, state = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)

	lu.assertEquals(label, "EVALUATING")
	lu.assertNil(state)
end

function TestEvaluateTrack:test_evaluating_during_min_scans()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	populateArmHistory(track, 2, mockTime, emitterPos)
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	local label, state = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	lu.assertEquals(label, "EVALUATING")
	lu.assertNotNil(state)
	lu.assertEquals(state.scanCount, 1)
	lu.assertTrue(state.llr > 0)
end

function TestEvaluateTrack:test_predecision_non_arm_evidence_prevents_single_popup_scan_from_confirming()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	populateNonArmHistory(track, 2, mockTime)
	local label, state = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, nil, nil, 2)
	lu.assertEquals(label, "EVALUATING")
	lu.assertTrue(state.llr < 0)

	populateArmHistory(track, 2, mockTime + 100, emitterPos)
	label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, nil, nil, 2)

	lu.assertNotEquals(label, "CONFIRMED")
end

function TestEvaluateTrack:test_observation_contributes_evidence_once()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	populateNonArmHistory(track, 2, mockTime)
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	local _, state = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, nil, nil, 1)
	local llr = state.llr
	local scanCount = state.scanCount

	Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, nil, nil, 1)

	lu.assertEquals(state.llr, llr)
	lu.assertEquals(state.scanCount, scanCount)
end

function TestEvaluateTrack:test_arm_track_reaches_confirmed()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	populateArmHistory(track, 2, mockTime, emitterPos)
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	local label
	for j = 1, Medusa.Constants.HARM_SPRT_MIN_SCANS - 1 do
		populateArmHistory(track, 2, mockTime + j * 100, emitterPos)
		label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	end
	lu.assertEquals(label, "EVALUATING")

	populateArmHistory(track, 2, mockTime + Medusa.Constants.HARM_SPRT_MIN_SCANS * 100, emitterPos)
	label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)

	lu.assertEquals(label, "CONFIRMED")
end

function TestEvaluateTrack:test_non_arm_track_does_not_confirm()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	local label
	for j = 1, 15 do
		populateNonArmHistory(track, 2, mockTime + j * 100)
		label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	end
	lu.assertNotEquals(label, "CONFIRMED")
end

function TestEvaluateTrack:test_confirmed_clears_when_it_flies_away_scoring_like_an_aircraft()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	populateArmHistory(track, 2, mockTime, emitterPos)
	Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	local state = track.HarmAssessment
	state.label = "CONFIRMED"
	state.llr = Medusa.Constants.HARM_SPRT_THRESH_CONFIRM
	state.scanCount = Medusa.Constants.HARM_SPRT_MIN_SCANS

	local label
	for j = 1, 10 do
		populateStraightHistory(
			track,
			2,
			mockTime + j * 100,
			{ x = 1000 - j * 400, y = 5000, z = 2000 },
			{ x = -1, z = 0 },
			200
		)
		label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, nil, nil, 1)
	end

	lu.assertEquals(label, "CLEARED")
	lu.assertTrue(state.llr <= Medusa.Constants.HARM_SPRT_THRESH_CLEAR)
end

-- A Kh-58 in DCS slows to ~290 m/s in level flight about 30 km (110 s) from its radar and scores like an aircraft,
-- but it is still flying at the radar.
function TestEvaluateTrack:test_confirmed_arm_that_slows_but_keeps_flying_at_the_radar_stays_confirmed()
	local target = { x = 35000, y = 0, z = 6000 }
	local store, grid = makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_HOT", Position = target }) })
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local state, t, p = confirmByFlight(track, grid, store, { x = 0, y = 9000, z = 6000 }, target, 1)
	local labels = flyOn(track, grid, store, t, p, { x = 1, z = 0 }, 290, 20, 2, 3000)
	for i = 1, #labels do
		lu.assertEquals(labels[i], "CONFIRMED")
	end
	lu.assertTrue(state.llr >= Medusa.Constants.HARM_SPRT_THRESH_CLEAR)
end

-- A pop-up jet confirmed in its dive pulls off and egresses: cleared once the window has passed, not before.
function TestEvaluateTrack:test_confirmed_track_that_turns_away_clears_after_the_window()
	local target = { x = 40000, y = 0, z = 0 }
	local store, grid = makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_HOT", Position = target }) })
	local track = makeTrack({ AssessedAircraftType = "FIXED_WING" })
	local _, t, p = confirmByFlight(track, grid, store, { x = 0, y = 9000, z = 0 }, target, 5)
	local labels = flyOn(track, grid, store, t, p, { x = 0, z = 1 }, 280, 3, 5)
	lu.assertEquals(labels[1], "CONFIRMED")
	lu.assertEquals(labels[2], "CONFIRMED") -- 5 s of not attacking: under the 8 s window
	lu.assertEquals(labels[3], "CLEARED")
end

function TestEvaluateTrack:test_turning_away_must_be_sustained_to_clear()
	local target = { x = 40000, y = 0, z = 0 }
	local store, grid = makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_HOT", Position = target }) })
	local track = makeTrack({ AssessedAircraftType = "FIXED_WING" })
	local _, t, p = confirmByFlight(track, grid, store, { x = 0, y = 9000, z = 0 }, target, 1)
	local label
	for i = 1, 12 do
		-- seven seconds weaving away, then one second back at the radar
		local toward = i % 8 == 0
		local dir = toward and { x = (target.x - p.x), z = (target.z - p.z) } or { x = 0, z = 1 }
		local len = math.sqrt(dir.x * dir.x + dir.z * dir.z)
		local labels
		labels, t, p = flyOn(track, grid, store, t, p, { x = dir.x / len, z = dir.z / len }, 300, 1, 1)
		label = labels[1]
	end
	lu.assertEquals(label, "CONFIRMED")
end

-- DCS ARMs retarget: one confirmed near one radar may fly on at another.
function TestEvaluateTrack:test_confirmed_arm_flying_at_another_radar_stays_confirmed()
	local first = { x = 40000, y = 0, z = 0 }
	local second = { x = 40000, y = 0, z = 80000 }
	local store, grid = makeBatteryStoreAndGrid({
		makeBattery({ ActivationState = "STATE_HOT", Position = first }),
		makeBattery({ ActivationState = "STATE_WARM", Position = second }),
	})
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local _, t, p = confirmByFlight(track, grid, store, { x = 0, y = 12000, z = 0 }, first, 1)
	local dx, dz = second.x - p.x, second.z - p.z
	local len = math.sqrt(dx * dx + dz * dz)
	local labels = flyOn(track, grid, store, t, p, { x = dx / len, z = dz / len }, 600, 15, 2)
	for i = 1, #labels do
		lu.assertEquals(labels[i], "CONFIRMED")
	end
end

-- Its target shut down: the missile flies on at the dark site, away from the radars still emitting.
function TestEvaluateTrack:test_confirmed_arm_flying_at_a_radar_that_shut_down_stays_confirmed()
	local targetPos = { x = 80000, y = 0, z = 6000 }
	local target = makeBattery({ ActivationState = "STATE_HOT", Position = targetPos })
	local store, grid = makeBatteryStoreAndGrid({
		target,
		makeBattery({ ActivationState = "STATE_WARM", Position = { x = 0, y = 0, z = 6000 } }),
	})
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local _, t, p = confirmByFlight(track, grid, store, { x = 10000, y = 12000, z = 6000 }, targetPos, 1)
	target.ActivationState = "STATE_COLD"
	local labels = flyOn(track, grid, store, t, p, { x = 1, z = 0 }, 600, 20, 2)
	for i = 1, #labels do
		lu.assertEquals(labels[i], "CONFIRMED")
	end
end

-- A lofted ARM high above its ground track toward the radar is attacking it (3D closest approach is kilometers off).
function TestEvaluateTrack:test_lofted_arm_over_its_ground_track_is_attacking()
	local store = makeBatteryStoreAndGrid({
		makeBattery({ ActivationState = "STATE_HOT", Position = { x = 60000, y = 0, z = 0 } }),
	})
	local emitters = HDS_.buildEmitterIndex(store)
	lu.assertTrue(HDS_._isAttackingAnyBattery({ x = 0, y = 15000, z = 0 }, { x = 650, y = 0, z = 0 }, emitters))
	-- passes 3 km abeam: not attacking
	lu.assertFalse(HDS_._isAttackingAnyBattery({ x = 0, y = 15000, z = 3000 }, { x = 650, y = 0, z = 0 }, emitters))
	-- flying away: not attacking
	lu.assertFalse(HDS_._isAttackingAnyBattery({ x = 0, y = 15000, z = 0 }, { x = -650, y = 0, z = 0 }, emitters))
end

function TestEvaluateTrack:test_far_site_is_not_attacked_by_a_slow_track()
	local store = makeBatteryStoreAndGrid({
		makeBattery({ ActivationState = "STATE_HOT", Position = { x = 60000, y = 0, z = 0 } }),
	})
	local emitters = HDS_.buildEmitterIndex(store)
	-- 280 m/s over the ground, 60 km out: 214 s to go is beyond the slow-track limit
	lu.assertFalse(HDS_._isAttackingAnyBattery({ x = 0, y = 3000, z = 0 }, { x = 280, y = 0, z = 0 }, emitters))
	-- the same track 30 km out (107 s) is attacking
	lu.assertTrue(HDS_._isAttackingAnyBattery({ x = 30000, y = 3000, z = 0 }, { x = 280, y = 0, z = 0 }, emitters))
	-- a fast track 60 km out (100 s at 600 m/s) is attacking
	lu.assertTrue(HDS_._isAttackingAnyBattery({ x = 0, y = 3000, z = 0 }, { x = 600, y = 0, z = 0 }, emitters))
end

function TestEvaluateTrack:test_confirmed_track_under_the_speed_gate_clears_after_the_window()
	local target = { x = 40000, y = 0, z = 0 }
	local store, grid = makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_HOT", Position = target }) })
	local track = makeTrack({ AssessedAircraftType = "FIXED_WING" })
	local _, t, p = confirmByFlight(track, grid, store, { x = 0, y = 9000, z = 0 }, target, 1)
	-- hovering toward the radar at 30 m/s
	local labels = flyOn(track, grid, store, t, p, { x = 1, z = 0 }, 30, 10, 1)
	lu.assertEquals(labels[1], "CONFIRMED")
	lu.assertEquals(labels[10], "CLEARED")
end

-- 80 batteries scattered over 300 x 300 km around a defended site: an ARM flying at its target stays confirmed all the
-- way, and a pop-up jet that pulls off its dive and egresses through the field clears well before the time cap.
local function denseField(centre)
	local batteries = { makeBattery({ ActivationState = "STATE_HOT", Position = centre }) }
	local seed = 12345
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for i = 2, 81 do
		batteries[i] = makeBattery({
			BatteryId = "dense-" .. i, -- fixed ids: 80 random ones collide now and then (math.random has 32768 values)
			GroupId = 9000000 + i,
			ActivationState = (i % 3 == 0) and "STATE_COLD" or "STATE_WARM",
			Position = { x = centre.x + (rnd() - 0.5) * 300000, y = 0, z = centre.z + (rnd() - 0.5) * 300000 },
		})
	end
	return makeBatteryStoreAndGrid(batteries)
end

function TestEvaluateTrack:test_dense_field_arm_stays_confirmed_and_egressing_jet_clears()
	local target = { x = 40000, y = 0, z = 0 }
	local store, grid = denseField(target)
	local arm = makeTrack({ AssessedAircraftType = "MISSILE" })
	local _, t, p = confirmByFlight(arm, grid, store, { x = 0, y = 12000, z = 0 }, target, 5)
	local labels = flyOn(arm, grid, store, t, p, { x = 1, z = 0 }, 600, 10, 5)
	for i = 1, #labels do
		lu.assertEquals(labels[i], "CONFIRMED")
	end

	mockTime = 1000
	local jet = makeTrack({ AssessedAircraftType = "FIXED_WING" })
	_, t, p = confirmByFlight(jet, grid, store, { x = 0, y = 9000, z = 0 }, target, 5)
	labels = flyOn(jet, grid, store, t, p, { x = 0, z = -1 }, 280, 24, 5)
	local clearedAfter
	for i = 1, #labels do
		if labels[i] == "CLEARED" then
			clearedAfter = i * 5
			break
		end
	end
	lu.assertNotNil(clearedAfter)
	lu.assertTrue(clearedAfter <= 120)
end

function TestEvaluateTrack:test_confirmation_lapses_after_the_maximum_time()
	local target = { x = 40000, y = 0, z = 0 }
	local store, grid = makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_HOT", Position = target }) })
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local _, t, p = confirmByFlight(track, grid, store, { x = 0, y = 9000, z = 0 }, target, 1)
	local labels =
		flyOn(track, grid, store, t + Medusa.Constants.HARM_CONFIRMED_MAX_SEC, p, { x = 1, z = 0 }, 400, 1, 1)
	lu.assertEquals(labels[1], "CLEARED")
end

function TestEvaluateTrack:test_cleared_retains_evidence_during_re_evaluation()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	populateNonArmHistory(track, 2, mockTime)
	Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	local state = track.HarmAssessment
	state.label = "CLEARED"
	state.llr = -24.82
	state.scanCount = Medusa.Constants.HARM_SPRT_MIN_SCANS

	populateArmHistory(track, 2, mockTime + 5000, emitterPos)
	local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, nil, nil, 1)

	lu.assertEquals(label, "CLEARED")
	lu.assertTrue(state.llr > -24.82)
	lu.assertTrue(state.llr < 0)
end

function TestEvaluateTrack:test_duplicate_timestamps_returns_current_label()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	Medusa.Entities.Track.update(track, { x = 2000, y = 5000, z = 3000 }, { x = 600, y = -100, z = 300 }, mockTime + 1)
	Medusa.Entities.Track.update(track, { x = 2600, y = 4900, z = 3300 }, { x = 600, y = -100, z = 300 }, mockTime + 1)
	local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store)
	lu.assertEquals(label, "EVALUATING")
end

-- == assessHarmThreats integration tests ==

TestAssessHarmThreats = {}

function TestAssessHarmThreats:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = makeMockGeoGrid(self.batteryStore)
end

function TestAssessHarmThreats:test_reclassifies_confirmed_arm()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local track = makeTrack({ AssessedAircraftType = "MISSILE", FirstDetectionTime = 0 })
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	self.trackStore:add(track)
	self.batteryStore:add(battery)

	local count = 0
	local lines, info = {}, env.info
	env.info = function(msg)
		lines[#lines + 1] = msg
	end
	for j = 1, 30 do
		populateArmHistory(track, 2, mockTime + j * 100, emitterPos)
		count = Medusa.Services.HarmDetectionService.assessHarmThreats(makeCtx({
			trackStore = self.trackStore,
			batteryStore = self.batteryStore,
			geoGrid = self.geoGrid,
			networkId = "red-net",
		}))
		if count > 0 then
			break
		end
	end
	env.info = info

	lu.assertEquals(track.AssessedAircraftType, "HARM")
	lu.assertTrue(track.IsSeadThreat)
	lu.assertTrue(track.HarmLikelihoodScore > 0)
	local debrief = 0
	for i = 1, #lines do
		if
			string.find(lines[i], "|net=red-net|ev=ARM_CONFIRMED|track=", 1, true)
			and string.find(lines[i], "|scans=", 1, true)
		then
			debrief = debrief + 1
		end
	end
	lu.assertEquals(debrief, 1)
end

function TestAssessHarmThreats:test_flying_away_clears_harm_classification()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local track = makeTrack({ AssessedAircraftType = "HARM", FirstDetectionTime = 0 })
	track.IsSeadThreat = true
	track.HarmAssessment = {
		label = "CONFIRMED",
		llr = Medusa.Constants.HARM_SPRT_THRESH_CONFIRM,
		scanCount = Medusa.Constants.HARM_SPRT_MIN_SCANS,
		emitterPosition = emitterPos,
		previousAircraftType = "FIGHTER",
		previousIsSeadThreat = false,
	}
	local battery = makeBattery({ ActivationState = "STATE_COLD", Position = emitterPos })
	self.trackStore:add(track)
	self.batteryStore:add(battery)

	for j = 1, 10 do
		populateStraightHistory(
			track,
			2,
			mockTime + j * 100,
			{ x = 1000 - j * 400, y = 5000, z = 2000 },
			{ x = -1, z = 0 },
			200
		)
		Medusa.Services.HarmDetectionService.assessHarmThreats(
			makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
		)
	end

	lu.assertEquals(track.HarmAssessment.label, "CLEARED")
	lu.assertEquals(track.AssessedAircraftType, "FIGHTER")
	lu.assertFalse(track.IsSeadThreat)
end

function TestAssessHarmThreats:test_does_not_reclassify_non_arm()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local track = makeTrack({ AssessedAircraftType = "MISSILE", FirstDetectionTime = 0 })
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	self.trackStore:add(track)
	self.batteryStore:add(battery)

	for j = 1, 15 do
		populateNonArmHistory(track, 2, mockTime + j * 100)
		Medusa.Services.HarmDetectionService.assessHarmThreats(
			makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
		)
	end

	lu.assertEquals(track.AssessedAircraftType, "MISSILE")
end

function TestAssessHarmThreats:test_skips_stale_tracks()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	populateArmHistory(track, 6, mockTime, { x = 10000, y = 0, z = 6000 })
	track.LifecycleState = "STALE"
	self.trackStore:add(track)

	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = { x = 10000, y = 0, z = 6000 } })
	self.batteryStore:add(battery)

	local count = Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

function TestAssessHarmThreats:test_skips_slow_tracks()
	local track = makeTrack({ Velocity = { x = 10, y = 0, z = 10 } })
	self.trackStore:add(track)

	local battery = makeBattery({ ActivationState = "STATE_WARM" })
	self.batteryStore:add(battery)

	local count = Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

function TestAssessHarmThreats:test_new_track_is_evaluated_without_waiting()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local track = makeTrack({ AssessedAircraftType = "MISSILE", FirstDetectionTime = mockTime })
	populateArmHistory(track, 2, mockTime, emitterPos)
	self.trackStore:add(track)
	self.batteryStore:add(makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos }))

	Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)

	lu.assertNotNil(track.HarmAssessment)
	lu.assertEquals(track.HarmAssessment.scanCount, 1)
end

function TestAssessHarmThreats:test_returns_zero_with_no_tracks()
	local battery = makeBattery({ ActivationState = "STATE_WARM" })
	self.batteryStore:add(battery)

	local count = Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

function TestAssessHarmThreats:test_cleared_track_gets_zero_score()
	local track = makeTrack({ AssessedAircraftType = "MISSILE", FirstDetectionTime = 0 })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	self.trackStore:add(track)
	self.batteryStore:add(battery)

	for j = 1, 20 do
		populateNonArmHistory(track, 2, mockTime + j * 100)
		Medusa.Services.HarmDetectionService.assessHarmThreats(
			makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
		)
	end

	local state = track.HarmAssessment
	if state and state.label == "CLEARED" then
		lu.assertEquals(track.HarmLikelihoodScore, 0)
	end
end

-- == Recorded DCS flights ==

TestHarmRecordedFlights = {}

function TestHarmRecordedFlights:setUp()
	setupMocks()
	self.flights = require("harm_dcs_trajectories")
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.batteryStore:add(makeBattery({ ActivationState = "STATE_HOT", Position = self.flights.sa10TrackRadar }))
	self.geoGrid = makeMockGeoGrid(self.batteryStore)
end

--- Feeds one recorded flight to the detector scan by scan; returns the flight time at which it was
--- classified as a HARM, or nil. With sizeDb, the track carries a confident return-size estimate of that size.
function TestHarmRecordedFlights:replay(samples, sizeDb)
	local base = 5000
	local first = samples[1]
	local track = makeTrack({
		AssessedAircraftType = "FIXED_WING",
		Position = first.p,
		Velocity = first.v,
		FirstDetectionTime = base + first.t,
		SizeDb = sizeDb,
		SizeWeight = sizeDb and Medusa.Constants.ContactEvidence.SIZE_MAX_WEIGHT,
		SizeSpreadDb = sizeDb and math.sqrt(0.25 + Medusa.Constants.ContactEvidence.SIZE_SPREAD_FLOOR_DB ^ 2),
	})
	for i = 1, #samples do
		local s = samples[i]
		mockTime = base + s.t
		Medusa.Entities.Track.update(track, s.p, s.v, mockTime)
		Medusa.Services.HarmDetectionService.assessSingleTrack(
			track,
			{ track },
			self.geoGrid,
			self.batteryStore,
			1.0,
			120
		)
		if track.AssessedAircraftType == "HARM" then
			return s.t
		end
	end
	return nil
end

function TestHarmRecordedFlights:test_harm_is_confirmed_inside_the_shortest_recorded_flight_time()
	-- Recorded HARM flights lasted 35-65 s with a scan every 4.8 s.
	local confirmedAt = self:replay(self.flights.harm)
	lu.assertNotNil(confirmedAt)
	lu.assertTrue(confirmedAt <= 35)
end

function TestHarmRecordedFlights:test_sead_aircraft_run_in_is_not_confirmed()
	lu.assertNil(self:replay(self.flights.seadJet))
end

-- == extractFeatures tests ==

TestExtractFeatures = {}

function TestExtractFeatures:setUp()
	setupMocks()
end

function TestExtractFeatures:test_extracts_eight_features()
	local curr = {
		timestamp = 1001,
		position = { x = 5000, y = 4000, z = 3000 },
		velocity = { x = 600, y = -200, z = 300 },
	}
	local prev = {
		timestamp = 1000,
		position = { x = 4400, y = 4200, z = 2700 },
		velocity = { x = 610, y = -190, z = 310 },
	}
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local sprtState = { prevCpa = nil, prevTime = nil }
	local feat = Medusa.Services.HarmDetectionService._extractFeatures(curr, prev, 1.0, emitterPos, sprtState)
	lu.assertEquals(#feat, 8)

	-- Speed should be ~700 m/s (sqrt(600^2 + 200^2 + 300^2))
	local expectedSpeed = math.sqrt(600 * 600 + 200 * 200 + 300 * 300)
	lu.assertAlmostEquals(feat[1], expectedSpeed, 1)

	-- Dive angle should be positive (descending)
	lu.assertTrue(feat[2] > 0)

	-- Altitude rate should be negative (descending)
	lu.assertEquals(feat[8], -200)
end

function TestExtractFeatures:test_cpa_rate_computed_on_second_call()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local sprtState = { prevCpa = 5000, prevTime = 1000 }
	local curr = {
		timestamp = 1001,
		position = { x = 6000, y = 3000, z = 4000 },
		velocity = { x = 600, y = -200, z = 300 },
	}
	local prev = {
		timestamp = 1000,
		position = { x = 5400, y = 3200, z = 3700 },
		velocity = { x = 610, y = -190, z = 310 },
	}
	local feat = Medusa.Services.HarmDetectionService._extractFeatures(curr, prev, 1.0, emitterPos, sprtState)
	-- CPA rate (feat[6]) should be non-zero since prevCpa was set
	lu.assertNotEquals(feat[6], 0)
end

-- == Launcher backtrack ==

TestBacktrackLauncher = {}

function TestBacktrackLauncher:setUp()
	setupMocks()
end

-- A jet at 250 m/s fires a 700 m/s HARM at T=5000; the HARM is tracked every 10 s from T=5000, the jet by a radar
-- refreshing every `spacing` s whose last look before the launch came `phase` s earlier.
local function launchScenario(spacing, phase)
	local harm = makeTrack({ Position = { x = 0, y = 8000, z = 0 }, Velocity = { x = 700, y = 0, z = 0 } })
	local jet = makeTrack({
		Position = { x = 0, y = 8000, z = 50 },
		Velocity = { x = 250, y = 0, z = 0 },
		AssessedAircraftType = "FIGHTER",
	})
	local decoy = makeTrack({
		Position = { x = 0, y = 8000, z = 6000 },
		Velocity = { x = 250, y = 0, z = 0 },
		AssessedAircraftType = "FIGHTER",
	})
	for k = -6, 12 do
		local ts = 5000 - phase + k * spacing
		Medusa.Entities.Track.update(jet, { x = 250 * (ts - 5000), y = 8000, z = 50 }, { x = 250, y = 0, z = 0 }, ts)
		Medusa.Entities.Track.update(
			decoy,
			{ x = 250 * (ts - 5000), y = 8000, z = 6000 },
			{ x = 250, y = 0, z = 0 },
			ts
		)
	end
	for k = 0, 5 do
		Medusa.Entities.Track.update(
			harm,
			{ x = 700 * k * 10, y = 8000, z = 0 },
			{ x = 700, y = 0, z = 0 },
			5000 + k * 10
		)
	end
	return harm, jet, decoy
end

function TestBacktrackLauncher:test_launcher_found_at_every_refresh_rate_and_phase()
	for _, spacing in ipairs({ 1, 5, 10 }) do
		for phase = 0, spacing - 1 do
			local harm, jet, decoy = launchScenario(spacing, phase)
			Medusa.Services.HarmDetectionService._backtrackLauncher(harm, { harm, jet, decoy })
			lu.assertTrue(jet.HostileActionConfirmed == true, string.format("spacing %d phase %d", spacing, phase))
			lu.assertFalse(decoy.HostileActionConfirmed == true)
		end
	end
end

function TestBacktrackLauncher:test_history_is_walked_in_place()
	local harm, jet, decoy = launchScenario(5, 2)
	local function noCopy()
		error("history copied")
	end
	jet.PositionHistory.toArray = noCopy
	decoy.PositionHistory.toArray = noCopy
	Medusa.Services.HarmDetectionService._backtrackLauncher(harm, { harm, jet, decoy })
	lu.assertTrue(jet.HostileActionConfirmed)
end

function TestBacktrackLauncher:test_track_last_seen_long_before_the_launch_is_not_blamed()
	local harm = makeTrack({ Position = { x = 0, y = 8000, z = 0 }, Velocity = { x = 700, y = 0, z = 0 } })
	local old = makeTrack({ Position = { x = 0, y = 8000, z = 0 }, Velocity = { x = 0, y = 0, z = 0 } })
	Medusa.Entities.Track.update(old, { x = 0, y = 8000, z = 0 }, { x = 0, y = 0, z = 0 }, 4900)
	for k = 0, 5 do
		Medusa.Entities.Track.update(harm, { x = 700 * k, y = 8000, z = 0 }, { x = 700, y = 0, z = 0 }, 5000 + k)
	end
	Medusa.Services.HarmDetectionService._backtrackLauncher(harm, { harm, old })
	lu.assertFalse(old.HostileActionConfirmed == true)
end

-- == Contact evidence as a bounded prior ==

TestHarmContactEvidence = {}

local CE = Medusa.Constants.ContactEvidence

local function withSize(track, db)
	track.SizeDb = db
	track.SizeWeight = Medusa.Constants.ContactEvidence.SIZE_MAX_WEIGHT
	track.SizeSpreadDb = math.sqrt(0.25 + Medusa.Constants.ContactEvidence.SIZE_SPREAD_FLOOR_DB ^ 2)
	return track
end

local DB_ARM = 10 * math.log10(0.08)
local DB_JET = 10 * math.log10(4)
local DB_STEALTH = 10 * math.log10(0.003)

function TestHarmContactEvidence:setUp()
	setupMocks()
end

function TestHarmContactEvidence:test_no_estimate_no_prior()
	lu.assertEquals(HDS_.evidencePrior(makeTrack(), 3), 0)
end

function TestHarmContactEvidence:test_unconfident_estimate_gives_no_prior()
	local track = makeTrack()
	track.SizeDb, track.SizeWeight, track.SizeSpreadDb = DB_ARM, 1 / 16, 4 -- one coarse look
	lu.assertEquals(HDS_.evidencePrior(track, 3), 0)
end

function TestHarmContactEvidence:test_arm_sized_return_adds_at_most_the_cap()
	lu.assertAlmostEquals(HDS_.evidencePrior(withSize(makeTrack(), DB_ARM), 4), CE.HARM_SIZE_PRIOR_MAX, 1e-9)
	lu.assertAlmostEquals(HDS_.evidencePrior(withSize(makeTrack(), DB_STEALTH), 4), CE.HARM_SIZE_PRIOR_MAX, 1e-9)
end

function TestHarmContactEvidence:test_small_return_counts_only_once_kinematics_alone_are_suspect()
	local track = withSize(makeTrack(), DB_STEALTH)
	lu.assertEquals(HDS_.evidencePrior(track, 0), 0)
	lu.assertEquals(HDS_.evidencePrior(track, Medusa.Constants.HARM_SPRT_THRESH_SUSPECT - 0.01), 0)
	lu.assertAlmostEquals(HDS_.evidencePrior(track, 1.5), CE.HARM_SIZE_PRIOR_MAX, 1e-9) -- never more than the cap
end

function TestHarmContactEvidence:test_a_low_observable_jet_needs_most_of_the_confirm_score_from_its_flight()
	-- Diving at a radar, a jet smaller than an ARM must not confirm at half the kinematic score: the positive prior
	-- is worth no more than the SUSPECT threshold.
	local track = withSize(makeTrack(), DB_STEALTH)
	local kinematic = Medusa.Constants.HARM_SPRT_THRESH_CONFIRM / 2 + 0.1
	local prior = HDS_.evidencePrior(track, kinematic)
	lu.assertTrue(prior <= Medusa.Constants.HARM_SPRT_THRESH_SUSPECT + 1e-9)
	lu.assertTrue(kinematic + prior < Medusa.Constants.HARM_SPRT_THRESH_CONFIRM)
end

function TestHarmContactEvidence:test_a_confident_aircraft_sized_return_counts_as_much_as_a_sighting()
	lu.assertAlmostEquals(HDS_.evidencePrior(withSize(makeTrack(), DB_JET), 0), CE.HARM_SIZE_PRIOR_MIN, 1e-9)
	lu.assertAlmostEquals(HDS_.evidencePrior(withSize(makeTrack(), 20), 0), CE.HARM_SIZE_PRIOR_MIN, 1e-9)
	lu.assertEquals(CE.HARM_SIZE_PRIOR_MIN, CE.HARM_SEEN_AIRCRAFT_PRIOR)
end

function TestHarmContactEvidence:test_a_mach_2_jet_passing_26_km_from_a_radar_is_never_confirmed()
	-- The case measured in DCS (Mach 2.2 F-15 level at 12,000 m, 26.6 km from the radar at its closest) flown past a
	-- HOT radar at 1, 2 and 5 s refresh with its confident 5 m2 return.
	for _, dt in ipairs({ 1, 2, 5 }) do
		local store = makeBatteryStoreAndGrid({
			makeBattery({ ActivationState = "STATE_HOT", Position = { x = 0, y = 0, z = 0 } }),
		})
		local track = withSize(
			makeTrack({ AssessedAircraftType = "FIGHTER", Position = { x = 26612, y = 12000, z = -150000 } }),
			10 * math.log10(5)
		)
		for t = 0, 460, dt do
			mockTime = 5000 + t
			Medusa.Entities.Track.update(
				track,
				{ x = 26612, y = 12000, z = -150000 + 650 * t },
				{ x = 0, y = 0, z = 650 },
				mockTime
			)
			HDS_.assessSingleTrack(track, { track }, nil, store, 1.0, 120)
			lu.assertNotEquals(track.HarmAssessment and track.HarmAssessment.label, "CONFIRMED", dt .. " s, t=" .. t)
		end
	end
end

function TestHarmContactEvidence:test_beam_on_arm_with_the_largest_shape_offset_is_never_counted_as_aircraft()
	lu.assertEquals(HDS_.evidencePrior(withSize(makeTrack(), DB_ARM + CE.ASPECT_BEAM_DB + CE.SHAPE_OFFSET_DB), 0), 0)
end

function TestHarmContactEvidence:test_seen_as_aircraft_counts_against_seen_as_munition_does_not_count()
	local seen = makeTrack({ SeenAs = "AIRCRAFT" })
	lu.assertEquals(HDS_.evidencePrior(seen, 3), CE.HARM_SEEN_AIRCRAFT_PRIOR)
	lu.assertEquals(HDS_.evidencePrior(makeTrack({ SeenAs = "HELICOPTER" }), 3), CE.HARM_SEEN_AIRCRAFT_PRIOR)
	lu.assertEquals(HDS_.evidencePrior(makeTrack({ SeenAs = "MUNITION" }), 3), 0)
end

function TestHarmContactEvidence:test_prior_is_replaced_each_scan_never_accumulated()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local store, grid =
		makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos }) })
	local plain = makeTrack({ AssessedAircraftType = "MISSILE" })
	local sized = withSize(makeTrack({ AssessedAircraftType = "MISSILE", SeenAs = "AIRCRAFT" }), DB_JET)
	for j = 1, 8 do
		populateArmHistory(plain, 2, mockTime + j * 100, emitterPos)
		populateArmHistory(sized, 2, mockTime + j * 100, emitterPos)
		HDS_._evaluateTrack(plain, grid, store)
		HDS_._evaluateTrack(sized, grid, store)
	end
	lu.assertAlmostEquals(sized.HarmAssessment.llr, plain.HarmAssessment.llr, 1e-9)
	lu.assertAlmostEquals(sized.HarmAssessment.prior, CE.HARM_SIZE_PRIOR_MIN + CE.HARM_SEEN_AIRCRAFT_PRIOR, 1e-9)
end

function TestHarmContactEvidence:test_confirmed_arm_is_not_cleared_by_the_prior()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local store, grid =
		makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos }) })
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	for j = 1, Medusa.Constants.HARM_SPRT_MIN_SCANS + 1 do
		populateArmHistory(track, 2, mockTime + j * 100, emitterPos)
		HDS_._evaluateTrack(track, grid, store)
	end
	lu.assertEquals(track.HarmAssessment.label, "CONFIRMED")
	track.SeenAs = "AIRCRAFT"
	withSize(track, DB_JET)
	populateArmHistory(track, 2, mockTime + (Medusa.Constants.HARM_SPRT_MIN_SCANS + 2) * 100, emitterPos)
	lu.assertEquals(HDS_._evaluateTrack(track, grid, store), "CONFIRMED")
end

function TestHarmContactEvidence:test_stealth_jet_manoeuvring_at_250_mps_is_never_an_arm()
	-- A low-observable fighter (0.003 m2, smaller than an ARM) weaving toward a radar at 250 m/s for 4 minutes.
	local emitterPos = { x = 0, y = 0, z = 0 }
	local store = makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_HOT", Position = emitterPos }) })
	for _, scanSec in ipairs({ 1, 2, 5, 10 }) do
		for _, alt in ipairs({ 300, 6000 }) do
			local x, z = -40000, 0
			local track = withSize(
				makeTrack({ AssessedAircraftType = "FIGHTER", Position = { x = x, y = alt, z = z } }),
				DB_STEALTH
			)
			for i = 0, math.floor(240 / scanSec) do
				local t = 5000 + i * scanSec
				local hdg = 0.6 * math.sin(i * scanSec * 0.08)
				local v = { x = 250 * math.cos(hdg), y = 0, z = 250 * math.sin(hdg) }
				mockTime = t
				Medusa.Entities.Track.update(track, { x = x, y = alt, z = z }, v, t)
				HDS_.assessSingleTrack(track, { track }, nil, store, 1.0, 120)
				lu.assertNotEquals(track.AssessedAircraftType, "HARM")
				lu.assertNotEquals(track.HarmAssessment and track.HarmAssessment.label, "CONFIRMED")
				x, z = x + v.x * scanSec, z + v.z * scanSec
			end
		end
	end
end

function TestHarmRecordedFlights:test_arm_sized_return_never_delays_the_recorded_harm()
	local plain = self:replay(self.flights.harm)
	local sized = self:replay(self.flights.harm, DB_ARM)
	lu.assertNotNil(sized)
	lu.assertTrue(sized <= plain)
end

function TestHarmRecordedFlights:test_sead_aircraft_run_in_is_not_confirmed_with_any_return_size()
	lu.assertNil(self:replay(self.flights.seadJet, DB_JET))
	lu.assertNil(self:replay(self.flights.seadJet, DB_STEALTH))
	lu.assertNil(self:replay(self.flights.seadJet, DB_ARM))
end

-- Label-level checks: one ARM-like scan that leaves the kinematic score at `llrAfter`, with or without evidence.
local function labelWithKinematicScore(track, llrAfter)
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local store, grid =
		makeBatteryStoreAndGrid({ makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos }) })
	local function scan(t, llrBefore)
		populateArmHistory(t, 2, mockTime + 100, emitterPos)
		HDS_._evaluateTrack(t, grid, store) -- creates the assessment
		local st = t.HarmAssessment
		st.llr, st.scanCount, st.label = llrBefore, 10, "EVALUATING"
		populateArmHistory(t, 2, mockTime + 200, emitterPos)
		return HDS_._evaluateTrack(t, grid, store)
	end
	local probe = makeTrack({ AssessedAircraftType = "MISSILE" })
	scan(probe, 0)
	local scanLlr = probe.HarmAssessment.llr
	local label = scan(track, llrAfter - scanLlr)
	lu.assertAlmostEquals(track.HarmAssessment.llr, llrAfter, 1e-9)
	return label
end

function TestHarmContactEvidence:test_arm_sized_return_lifts_a_probable_track_to_confirmed()
	lu.assertEquals(labelWithKinematicScore(makeTrack({ AssessedAircraftType = "MISSILE" }), 3.5), "PROBABLE")
	local sized = withSize(makeTrack({ AssessedAircraftType = "MISSILE" }), DB_ARM)
	lu.assertEquals(labelWithKinematicScore(sized, 3.5), "CONFIRMED") -- 3.5 + 1.139 >= 4.554
	local half = withSize(makeTrack({ AssessedAircraftType = "MISSILE" }), DB_ARM)
	lu.assertNotEquals(labelWithKinematicScore(half, 2.3), "CONFIRMED") -- half the confirm score is not enough
end

function TestHarmContactEvidence:test_the_measured_mach_2_jet_is_not_confirmed_with_its_confident_5_m2_return()
	-- Measured in DCS: a Mach 2.2 F-15 level at 12,000 m, 26.6 km from every radar at its closest, scored SPD +3.00
	-- DIV -1.09 HDG +1.38 ACC -1.00 CPA -3.00 CPR +3.00 RNG +2.24 ALT -1.59: LLR 5.80 at scan 5 and 8.50 at scan 6,
	-- past the confirm threshold on its flight alone.
	for _, llr in ipairs({ 5.80, 8.50 }) do
		local jet = withSize(makeTrack({ AssessedAircraftType = "FIGHTER" }), 10 * math.log10(5))
		lu.assertNotEquals(labelWithKinematicScore(jet, llr), "CONFIRMED", tostring(llr))
	end
end

function TestHarmContactEvidence:test_a_confident_aircraft_sized_return_is_never_confirmed_but_may_be_probable()
	-- A crew does not call a confident 5 m2 return an ARM (an ARM, about 0.08 m2, is called aircraft-sized in
	-- 0.2-0.3% of beam-on looks): however ARM-like the flight, it stays PROBABLE.
	local jet = withSize(makeTrack({ AssessedAircraftType = "FIGHTER" }), 10 * math.log10(5))
	lu.assertEquals(labelWithKinematicScore(jet, 20), "PROBABLE")
end

function TestHarmContactEvidence:test_stealth_return_alone_does_not_make_a_suspect()
	local sized = withSize(makeTrack({ AssessedAircraftType = "FIGHTER" }), DB_STEALTH)
	lu.assertEquals(labelWithKinematicScore(sized, 1.0), "EVALUATING")
end

function TestHarmContactEvidence:test_seen_as_aircraft_holds_a_track_below_confirmed()
	lu.assertEquals(labelWithKinematicScore(makeTrack({ AssessedAircraftType = "MISSILE" }), 5), "CONFIRMED")
	local seen = makeTrack({ AssessedAircraftType = "MISSILE", SeenAs = "AIRCRAFT" })
	lu.assertEquals(labelWithKinematicScore(seen, 5), "EVALUATING") -- 5 - 6
end
