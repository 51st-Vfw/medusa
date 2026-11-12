local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Config")
require("core.Chance")
require("entities.Entities")
require("entities.Doctrine")
require("entities.Battery")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.TrackStore")
require("services.GroupNameParser")
require("services.BatteryActivationService")
require("services.SensorPollingService")
require("services.LocalRadarService")
require("services.CrewFactorsService")
require("services.ObserverReportService")
require("services.EsmService")

-- Listening stations (ESM): bearings on transmitting aircraft radars, limited by the radio horizon, terrain,
-- the radar's beam and sidelobes; bearings matched up into fixes from the measurements only, ghosts left ambiguous.

local C = Medusa.Constants
local E = C.Esm
local ESM = Medusa.Services.EsmService
local ORS = Medusa.Services.ObserverReportService
local SPS = Medusa.Services.SensorPollingService
local CFS = Medusa.Services.CrewFactorsService
local RAD = math.pi / 180

local function near(actual, expected, tolerance, what)
	lu.assertTrue(
		math.abs(actual - expected) <= tolerance,
		string.format("%s: %s, expected %s +- %s", what or "value", tostring(actual), tostring(expected), tolerance)
	)
end

local function dist(ax, az, bx, bz)
	return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

-- a bearing measurement from station (sx, sz) towards (tx, tz), plus `errDeg`
local function bearingRec(station, sx, sz, tx, tz, class, errDeg, sigmaDeg)
	return {
		Station = station,
		SX = sx,
		SZ = sz,
		B = ESM.bearing(sx, sz, tx, tz) + (errDeg or 0) * RAD,
		Sigma = (sigmaDeg or 2) * RAD,
		Class = class or "FCR",
		Count = 1,
	}
end

local function associate(list, sat)
	local state = ESM.newState()
	for i = 1, #list do
		state.bearings[i] = list[i]
	end
	state.bearingCount = #list
	local fixes = {}
	local n, ambiguous = ESM.associate(state, 250000, function(x, z, errM, class, stations, count, how, chi2)
		fixes[#fixes + 1] =
			{ x = x, z = z, errM = errM, class = class, stations = stations, n = count, how = how, chi2 = chi2 }
	end, sat)
	lu.assertEquals(n, #fixes)
	return fixes, ambiguous, state
end

-- a fixed random source (a linear congruential generator), so statistical tests give the same numbers every run
local function lcg(seed)
	local s = seed
	return function()
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648
	end
end

TestEsmPhysics = {}

function TestEsmPhysics:test_radio_horizon_over_a_four_thirds_earth()
	-- 4.12 km x (sqrt(10) + sqrt(100)) = 54.2 km; a 10 m mast sees a sea-level target 13 km off
	near(ESM.horizonM(10, 100), 54229, 5, "10 m mast, 100 m target")
	near(ESM.horizonM(10, 0), 13029, 5, "10 m mast, ground target")
	near(ESM.horizonM(10, 8000), 381533, 5, "10 m mast, 8 km target")
end

function TestEsmPhysics:test_elevation_bends_down_with_the_earth()
	-- 100 km out at the same height the earth's curve puts it 0.34 degrees below the horizontal
	near(ESM.elevation(0, 100000) / RAD, -0.337, 0.005, "elevation")
	near(ESM.elevation(1000, 10000) / RAD, 5.677, 0.005, "close in")
end

function TestEsmPhysics:test_a_searching_radar_sweeps_its_nose_sector_and_only_sidelobes_reach_behind()
	local em = { X = 0, Y = 8000, Z = 0, NoseX = 1, NoseZ = 0 }
	local lobe, p = ESM.lobe(em, 100000, 10, 0)
	lu.assertEquals(lobe, "scan")
	lu.assertEquals(p, E.INTERCEPT_SCAN)
	lu.assertEquals((ESM.lobe(em, 100000, 10, 100000 * math.tan(55 * RAD))), "scan")
	lobe, p = ESM.lobe(em, 100000, 10, 100000 * math.tan(65 * RAD))
	lu.assertEquals(lobe, "side")
	lu.assertEquals(p, 0)
	lu.assertEquals((ESM.lobe(em, -50000, 10, 0)), "side")
end

function TestEsmPhysics:test_a_locked_radar_holds_its_beam_and_still_sweeps_its_sector_now_and_then()
	local em = { X = 0, Y = 8000, Z = 0, NoseX = 1, NoseZ = 0, TgtX = 50000, TgtY = 8000, TgtZ = 0 }
	local lobe, p = ESM.lobe(em, 100000, 0, 0) -- 4.6 degrees below the beam
	lu.assertEquals(lobe, "held")
	lu.assertEquals(p, E.INTERCEPT_HELD)
	lobe, p = ESM.lobe(em, 100000, 0, 30000) -- in the sector, off the beam: track-while-scan sweeps
	lu.assertEquals(lobe, "scan")
	lu.assertEquals(p, E.INTERCEPT_LOCKED_SCAN)
	lu.assertEquals((ESM.lobe(em, -100000, 0, 0)), "side")
end

function TestEsmPhysics:test_an_early_warning_radar_is_heard_all_round()
	local lobe, p = ESM.lobe({ X = 0, Y = 9000, Z = 0, NoseX = 1, NoseZ = 0, Class = "AEW" }, -200000, 0, 0)
	lu.assertEquals(lobe, "aew")
	lu.assertEquals(p, E.INTERCEPT_AEW)
end

function TestEsmPhysics:test_angles_wrap_through_north()
	near(ESM.angleDiff(359.5 * RAD, 0.5 * RAD) / RAD, -1, 1e-9, "359.5 - 0.5")
	near(ESM.angleDiff(0.5 * RAD, 359.5 * RAD) / RAD, 1, 1e-9, "0.5 - 359.5")
end

function TestEsmPhysics:test_two_bearings_cross_where_they_meet_with_the_triangulation_error()
	local a = bearingRec("A", 0, 0, 10000, 10000)
	local b = bearingRec("B", 0, 20000, 10000, 10000)
	local x, z, ra, rb, s = ESM.cross(a, b)
	near(x, 10000, 0.01, "x")
	near(z, 10000, 0.01, "z")
	near(ra, math.sqrt(2) * 10000, 0.01, "range a")
	near(rb, math.sqrt(2) * 10000, 0.01, "range b")
	near(s, 1, 1e-9, "sin crossing")
	-- 100 km out, 2 degrees each, crossing at 90 degrees: sqrt(2) x 3.49 km; at 30 degrees twice that
	near(ESM.crossErrorM(100000, 2 * RAD, 100000, 2 * RAD, 1), 4936, 2, "error")
	near(ESM.crossErrorM(100000, 2 * RAD, 100000, 2 * RAD, 0.5), 9873, 3, "error at 30 degrees")
end

function TestEsmPhysics:test_shallow_or_backward_crossings_are_rejected()
	-- two stations 20 km apart looking at a point 200 km away: about 6 degrees apart
	lu.assertNil(ESM.cross(bearingRec("A", 0, 0, 200000, 10000), bearingRec("B", 0, 20000, 200000, 10000)))
	local a = bearingRec("A", 0, 0, 10000, 10000)
	local b = { Station = "B", SX = 0, SZ = 20000, B = ESM.bearing(0, 20000, -10000, 30000), Sigma = 2 * RAD }
	lu.assertNil(ESM.cross(a, b))
end

function TestEsmPhysics:test_least_squares_fix_and_its_misfit()
	local list = { bearingRec("A", 0, 0, 60000, 40000), bearingRec("B", 0, 80000, 60000, 40000) }
	local x, z, err, chi2 = ESM.solve(list, 2, 60000, 40000)
	near(x, 60000, 1, "x")
	near(z, 40000, 1, "z")
	near(chi2, 0, 1e-6, "two bearings always meet")
	local r = math.sqrt(60000 ^ 2 + 40000 ^ 2)
	local _, _, _, _, s = ESM.cross(list[1], list[2])
	lu.assertTrue(err >= r * 2 * RAD and err <= ESM.crossErrorM(r, 2 * RAD, r, 2 * RAD, s) + 1)
	-- a third bearing 2 degrees (one error) off: chi-square about 1/3 to 1; 10 degrees off: far beyond the gate
	list[3] = bearingRec("C", -30000, 40000, 60000, 40000, "FCR", 2)
	local _, _, _, chi2b = ESM.solve(list, 3, 60000, 40000)
	lu.assertTrue(chi2b > 0.2 and chi2b < 1.2, tostring(chi2b))
	list[3] = bearingRec("C", -30000, 40000, 60000, 40000, "FCR", 10)
	local _, _, _, chi2c = ESM.solve(list, 3, 60000, 40000)
	lu.assertTrue(chi2c > E.CHI2_MAX, tostring(chi2c))
end

TestEsmAssociation = {}

function TestEsmAssociation:test_one_radar_three_stations_gives_a_three_station_fix_near_the_truth()
	local tx, tz = 120000, 30000
	local fixes, ambiguous = associate({
		bearingRec("A", 0, 0, tx, tz, "FCR", 1.5),
		bearingRec("B", 0, 50000, tx, tz, "FCR", -1),
		bearingRec("C", 30000, -40000, tx, tz, "FCR", 0.5),
	})
	lu.assertEquals(#fixes, 1)
	lu.assertEquals(ambiguous, 0)
	lu.assertEquals(fixes[1].how, "3_station")
	lu.assertTrue(fixes[1].chi2 <= E.CHI2_MAX)
	lu.assertTrue(dist(fixes[1].x, fixes[1].z, tx, tz) <= 3 * fixes[1].errM)
	lu.assertTrue(fixes[1].errM > 500 and fixes[1].errM < 10000)
end

function TestEsmAssociation:test_six_stations_one_radar_give_one_fix_from_all_six()
	local tx, tz = 90000, 20000
	local list = {}
	for i = 1, 6 do
		local a = (i - 1) / 6 * 2 * math.pi
		list[i] = bearingRec("S" .. i, math.cos(a) * 50000, math.sin(a) * 50000, tx, tz, "FCR", (i % 3 - 1) * 0.8)
	end
	local fixes = associate(list)
	lu.assertEquals(#fixes, 1)
	lu.assertEquals(fixes[1].n, 6)
	lu.assertEquals(fixes[1].how, "6_station")
end

function TestEsmAssociation:test_one_radar_two_stations_gives_a_two_station_fix()
	local fixes, ambiguous = associate({
		bearingRec("A", 0, 0, 100000, 40000),
		bearingRec("B", 0, 80000, 100000, 40000),
	})
	lu.assertEquals(#fixes, 1)
	lu.assertEquals(ambiguous, 0)
	lu.assertEquals(fixes[1].how, "2_station")
	near(fixes[1].x, 100000, 1, "x")
	near(fixes[1].z, 40000, 1, "z")
end

function TestEsmAssociation:test_a_shallow_crossing_still_competes_for_a_two_station_fix()
	-- A hears one radar; B hears two, one of them almost on A's line (a crossing too shallow to use): A's bearing
	-- could belong to either, so no fix
	local fixes, ambiguous = associate({
		bearingRec("A", 0, 0, 100000, 40000),
		bearingRec("B", 0, 80000, 100000, 40000),
		bearingRec("B", 0, 80000, 300000, 120000),
	})
	lu.assertEquals(#fixes, 0)
	lu.assertEquals(ambiguous, 3)
end

function TestEsmAssociation:test_a_saturated_station_makes_two_station_crossings_ambiguous()
	local fixes = associate({
		bearingRec("A", 0, 0, 100000, 40000),
		bearingRec("B", 0, 80000, 100000, 40000),
	}, { B = { AEW = 0, FCR = 1, OTHER = 0 } })
	lu.assertEquals(#fixes, 0)
end

function TestEsmAssociation:test_two_radars_of_one_class_and_two_stations_are_ambiguous_ghosts()
	-- four crossings, two of them ghosts: the stations cannot tell which bearing goes with which
	local p1x, p1z, p2x, p2z = 100000, 20000, 110000, 60000
	local fixes, ambiguous = associate({
		bearingRec("A", 0, 0, p1x, p1z),
		bearingRec("A", 0, 0, p2x, p2z),
		bearingRec("B", 0, 80000, p1x, p1z),
		bearingRec("B", 0, 80000, p2x, p2z),
	})
	lu.assertEquals(#fixes, 0)
	lu.assertEquals(ambiguous, 4)
end

function TestEsmAssociation:test_a_third_station_resolves_the_ghosts_by_the_residual_gate()
	local p1x, p1z, p2x, p2z = 100000, 20000, 110000, 60000
	-- station C, east of the two radars, sees them 30 degrees apart (the A x B ghost far east lies behind C: a bearing
	-- is a ray, so it does not confirm it)
	local fixes, ambiguous = associate({
		bearingRec("A", 0, 0, p1x, p1z, "FCR", 0.5),
		bearingRec("A", 0, 0, p2x, p2z, "FCR", -0.5),
		bearingRec("B", 0, 80000, p1x, p1z, "FCR", 1),
		bearingRec("B", 0, 80000, p2x, p2z, "FCR", -1),
		bearingRec("C", 180000, 40000, p1x, p1z, "FCR", 0.7),
		bearingRec("C", 180000, 40000, p2x, p2z, "FCR", -0.3),
	})
	lu.assertEquals(#fixes, 2)
	lu.assertEquals(ambiguous, 0)
	for i = 1, 2 do
		local f = fixes[i]
		lu.assertTrue(f.chi2 <= E.CHI2_MAX, "the three bearings fit")
		local d = math.min(dist(f.x, f.z, p1x, p1z), dist(f.x, f.z, p2x, p2z))
		lu.assertTrue(d < 6000, string.format("on a real radar, %.0f m off", d))
	end
end

function TestEsmAssociation:test_radars_of_different_classes_are_never_crossed_with_each_other()
	local fixes, ambiguous = associate({
		bearingRec("A", 0, 0, 100000, 20000, "AEW"),
		bearingRec("A", 0, 0, 110000, 60000, "FCR"),
		bearingRec("B", 0, 80000, 100000, 20000, "AEW"),
		bearingRec("B", 0, 80000, 110000, 60000, "FCR"),
	})
	lu.assertEquals(#fixes, 2)
	lu.assertEquals(ambiguous, 0)
end

function TestEsmAssociation:test_confident_ghosts_stay_rare_with_several_jets()
	-- three stations, three fire-control radars somewhere ahead, each heard on 70% of looks with a
	-- 2-degree error; a cue-grade fix (under 10 km) more than 20 km from every radar is a confident ghost
	local random = lcg(4242)
	local stations = { { "A", 0, 0 }, { "B", 0, 60000 }, { "C", -40000, 30000 } }
	local cueable, ghosts = 0, 0
	for _ = 1, 400 do
		local jets = {}
		for k = 1, 3 do
			jets[k] = { 40000 + random() * 110000, -40000 + random() * 140000 }
		end
		local list = {}
		for _, s in ipairs(stations) do
			for _, j in ipairs(jets) do
				if random() < 0.7 then
					local u1 = 1 - random()
					local g = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * random())
					list[#list + 1] = bearingRec(s[1], s[2], s[3], j[1], j[2], "FCR", 2 * g)
				end
			end
		end
		local fixes = associate(list)
		for _, f in ipairs(fixes) do
			if f.n >= 3 and f.errM <= E.CUE_MAX_ERROR_M then
				cueable = cueable + 1
				local best = math.huge
				for _, j in ipairs(jets) do
					best = math.min(best, dist(f.x, f.z, j[1], j[2]))
				end
				if best > 20000 then
					ghosts = ghosts + 1
				end
			end
		end
	end
	lu.assertTrue(cueable >= 20, "fixes still happen: " .. cueable)
	lu.assertTrue(ghosts / cueable <= 0.10, string.format("%d confident ghosts of %d", ghosts, cueable))
end

-- ── The service: stations listen to a snapshot of hostile radars ──

local posts, emitters, losCalls, logLines, originalInfo, originalPosition, originalCue, cues

local function station(name, x, z)
	posts[#posts + 1] = { GroupName = name, UnitNames = { name .. "-1" }, Esm = true, X = x, Z = z }
end

local function logged(fragment)
	for i = 1, #logLines do
		if string.find(logLines[i], fragment, 1, true) then
			return logLines[i]
		end
	end
	return nil
end

local function makeCtx(overrides, random)
	local doctrine = Medusa.Entities.Doctrine.new(overrides or {})
	local state = ESM.newState(random)
	state.emitterSource = function(st)
		for i = 1, #emitters do
			st.emitters[i] = emitters[i]
			emitters[i].GroundY = nil
		end
		for i = #emitters + 1, #st.emitters do
			st.emitters[i] = nil
		end
		return #emitters
	end
	state.los = function()
		losCalls = losCalls + 1
		return true
	end
	state.ground = function()
		return 0
	end
	return {
		doctrine = doctrine,
		esm = state,
		observerStore = {
			getAll = function()
				return posts
			end,
		},
		localRadars = { records = {} },
		coalitionId = 1,
		networkId = "net",
		now = 0,
	}
end

-- runs ticks every 0.1 s from ctx.now for `seconds`
local function run(ctx, seconds)
	local stop = ctx.now + seconds - 1e-9
	while ctx.now < stop do
		ESM.tick(ctx)
		ctx.now = ctx.now + 0.1
	end
end

TestEsmService = {}

function TestEsmService:setUp()
	posts, emitters, losCalls, logLines, cues = {}, {}, 0, {}, {}
	originalInfo = env.info
	env.info = function(msg)
		logLines[#logLines + 1] = msg
	end
	originalPosition = SPS.observerPosition
	SPS.observerPosition = function(unitNames)
		for i = 1, #posts do
			if posts[i].UnitNames == unitNames and not posts[i].Dead then
				return { x = posts[i].X, y = 0, z = posts[i].Z }
			end
		end
		return nil
	end
	originalCue = ORS.cueHostileArea
	ORS.cueHostileArea = function(_, position, from, reason, errorM)
		cues[#cues + 1] = { x = position.x, z = position.z, from = from, reason = reason, errorM = errorM }
		return 1, 0, 0
	end
	station("net.esm.A", 0, 0)
	station("net.esm.B", 0, 60000)
	station("net.elint.C", -40000, 30000)
end

function TestEsmService:tearDown()
	env.info = originalInfo
	SPS.observerPosition = originalPosition
	ORS.cueHostileArea = originalCue
end

local function fighter(x, z, alt, noseX, noseZ)
	local em = { X = x, Y = alt, Z = z, NoseX = noseX or -1, NoseZ = noseZ or 0, Class = "FCR" }
	emitters[#emitters + 1] = em
	return em
end

function TestEsmService:test_switch_off_hears_nothing()
	fighter(80000, 30000, 6000)
	local ctx = makeCtx({ PassiveDetection = false, TrainingMode = true })
	run(ctx, 30)
	lu.assertEquals(ctx.esm.stats.cycles, 0)
	lu.assertNil(logged("ESM_"))
	lu.assertNil(logged("listening stations"))
	lu.assertEquals(#cues, 0)
end

function TestEsmService:test_switching_off_mid_look_forgets_the_look_and_the_waiting_fixes()
	fighter(80000, 30000, 6000)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 1) -- the look is done, its fix waits for the data link
	lu.assertEquals(ctx.esm.pendingCount, 1)
	ctx.doctrine.PassiveDetection = false
	run(ctx, 10)
	lu.assertEquals(ctx.esm.pendingCount, 0)
	lu.assertEquals(ctx.esm.phase, 0)
	lu.assertEquals(#cues, 0)
end

function TestEsmService:test_training_mode_fix_is_the_same_every_look_cued_and_not_perfect()
	fighter(80000, 30000, 6000)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 12)
	lu.assertNotNil(logged("listening stations: 3"))
	lu.assertNotNil(logged("ev=ESM_INTERCEPT|station=net.esm.A"))
	local fix = logged("ev=ESM_FIX")
	lu.assertNotNil(fix)
	lu.assertStrContains(fix, "how=3_station")
	lu.assertEquals(#cues, 1)
	lu.assertEquals(cues[1].reason, "esm_fix")
	local miss = dist(cues[1].x, cues[1].z, 80000, 30000)
	lu.assertTrue(miss > 10, "training bearings carry their typical error")
	lu.assertTrue(miss < 3 * cues[1].errorM, "and the fix is still near the radar")
	-- the next look, same geometry: the same fix (the cell rests, so read it from the queue)
	local first = { x = cues[1].x, z = cues[1].z }
	run(ctx, 1)
	lu.assertEquals(ctx.esm.stats.fixes, 2)
	lu.assertEquals(ctx.esm.pendingCount, 1)
	local f = ctx.esm.pending[1]
	lu.assertNotNil(f.DueAt)
	lu.assertEquals(f.X, first.x)
	lu.assertEquals(f.Z, first.z)
end

function TestEsmService:test_the_fix_arrives_a_few_seconds_after_the_look()
	fighter(80000, 30000, 6000)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 1) -- snapshot, three stations, matching, resolving
	lu.assertEquals(#cues, 0)
	run(ctx, (E.DELAY_MIN_SEC + E.DELAY_MAX_SEC) / 2)
	lu.assertEquals(#cues, 1)
end

function TestEsmService:test_a_radar_below_the_radio_horizon_is_not_heard()
	-- 120 km away at 100 m: the horizon of a 10 m mast and a 100 m target is 54 km
	fighter(120000, 30000, 100)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 12)
	lu.assertEquals(ctx.esm.stats.bearings, 0)
	lu.assertEquals(losCalls, 0, "terrain is checked only for pairs that pass the cheap gates")
	lu.assertNil(logged("ESM_INTERCEPT"))
end

function TestEsmService:test_sidelobes_carry_to_their_own_range_with_a_wider_error()
	-- nose north, every station behind it: only sidelobes; 30 km from A is inside the 40 km sidelobe range
	posts[2], posts[3] = nil, nil
	fighter(30000, 0, 3000, 1, 0)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 1)
	lu.assertEquals(ctx.esm.stats.bearings, 1)
	near(ctx.esm.bearings[1].Sigma, 2 * E.SIDELOBE_SIGMA_FACTOR * RAD, 1e-9, "sidelobe sigma")
	emitters[1].X = 50000
	local far = makeCtx({ TrainingMode = true })
	run(far, 1)
	lu.assertEquals(far.esm.stats.bearings, 0)
end

function TestEsmService:test_a_locked_radar_sweeping_its_sector_is_caught_less_often()
	posts[2], posts[3] = nil, nil
	local em = fighter(80000, 0, 6000, -1, 0)
	em.TgtX, em.TgtY, em.TgtZ = 60000, 6000, 30000 -- beam held well away from A
	local function heard(draw)
		local ctx = makeCtx({}, function()
			return draw
		end)
		run(ctx, 1)
		return ctx.esm.stats.bearings
	end
	lu.assertEquals(heard(0.2), 1)
	lu.assertEquals(heard(0.5), 0)
end

function TestEsmService:test_a_low_jet_near_the_horizon_gives_a_doubled_bearing_error()
	posts[2], posts[3] = nil, nil
	fighter(60000, 0, 300)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 1)
	near(ctx.esm.bearings[1].Sigma, 2 * E.GRAZING_SIGMA_FACTOR * RAD, 1e-9, "grazing sigma")
end

function TestEsmService:test_two_jets_close_together_are_one_bearing_even_across_north()
	fighter(150000, 30000, 6000)
	fighter(150000, 31000, 6000) -- 0.4 degrees apart from every station
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 1)
	lu.assertEquals(ctx.esm.stats.bearings, 3)
	lu.assertEquals(ctx.esm.bearings[1].Count, 2)
	-- due north of A, one just west and one just east of north
	emitters = {}
	posts[2], posts[3] = nil, nil
	fighter(150000, -1000, 6000)
	fighter(150000, 1000, 6000)
	local north = makeCtx({ TrainingMode = true })
	run(north, 1)
	lu.assertEquals(north.esm.stats.bearings, 1)
end

function TestEsmService:test_two_jets_apart_with_two_stations_stay_ambiguous()
	posts[3] = nil
	fighter(100000, 10000, 6000)
	fighter(110000, 60000, 6000)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 12)
	lu.assertEquals(#cues, 0)
	lu.assertNil(logged("ev=ESM_FIX"))
	lu.assertNotNil(logged("ev=ESM_AMBIGUOUS|class=FCR|bearings=4"))
end

function TestEsmService:test_a_two_station_fix_cues_only_when_the_next_look_repeats_it()
	posts[3] = nil
	fighter(80000, 30000, 6000)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 9)
	lu.assertEquals(#cues, 0)
	lu.assertStrContains(logged("ev=ESM_FIX"), "how=2_station_single")
	lu.assertStrContains(logged("ev=ESM_FIX"), "caused=evidence_only")
	run(ctx, 10)
	lu.assertEquals(#cues, 1)
	lu.assertNotNil(logged("how=2_station_repeat"))
end

function TestEsmService:test_a_scanning_beam_is_missed_on_some_looks()
	fighter(80000, 30000, 6000)
	local draws = { 0.9, 0.1, 0.1 } -- station A's look misses (0.9 >= 0.7), B and C catch it
	local i = 0
	local ctx = makeCtx({}, function()
		i = i + 1
		return draws[i] or 0.5
	end)
	run(ctx, 1)
	lu.assertEquals(ctx.esm.stats.bearings, 2)
end

function TestEsmService:test_fixes_beyond_the_queue_are_dropped_and_logged()
	local saved = E.MAX_PENDING
	E.MAX_PENDING = 0
	fighter(80000, 30000, 6000)
	local ctx = makeCtx({ TrainingMode = true })
	local ok, err = pcall(run, ctx, 1)
	E.MAX_PENDING = saved
	lu.assertTrue(ok, tostring(err))
	lu.assertNotNil(logged("esm fix dropped"))
	lu.assertEquals(ctx.esm.stats.dropped, 1)
end

function TestEsmService:test_the_roster_changes_only_between_looks_and_a_dead_station_leaves()
	fighter(80000, 30000, 6000)
	local ctx = makeCtx({ TrainingMode = true })
	run(ctx, 0.15) -- the look has started
	lu.assertEquals(ctx.esm.phase, 1)
	station("net.esm.D", 30000, 60000)
	posts[1].Dead = true
	ctx.esm.rosterTime = -100 -- due for a refresh
	run(ctx, 0.5)
	lu.assertEquals(ctx.esm.stationCount, 3, "not in the middle of a look")
	run(ctx, 1)
	lu.assertEquals(ctx.esm.stationCount, 3)
	lu.assertNotNil(logged("listening stations: 3 (net.esm.B, net.elint.C, net.esm.D)"))
end

function TestEsmService:test_doctrine_numbers_are_validated()
	local d = Medusa.Entities.Doctrine.new({ ESM = { MastHeightM = 500, BearingSigmaDeg = "x", SidelobeRangeKm = 0 } })
	lu.assertEquals(d.ESM.MastHeightM, 60)
	lu.assertEquals(d.ESM.BearingSigmaDeg, E.DEFAULT_BEARING_SIGMA_DEG)
	lu.assertEquals(d.ESM.MaxRangeKm, E.DEFAULT_MAX_RANGE_KM)
	lu.assertEquals(d.ESM.SidelobeRangeKm, 1)
	lu.assertEquals(d.ESM.AewMaxRangeKm, E.DEFAULT_AEW_MAX_RANGE_KM)
	lu.assertTrue(Medusa.Entities.Doctrine.new({}).PassiveDetection)
end

function TestEsmService:test_esm_and_elint_tokens_name_a_listening_station()
	local r = Medusa.Services.GroupNameParser:parse("iads.1bn.esm.ridge", "iads")
	lu.assertEquals(r.roles[1], Medusa.Constants.Role.ESM)
	lu.assertEquals(r.unitLabel, "ridge")
	lu.assertEquals(Medusa.Services.GroupNameParser:parse("iads.elint-2", "iads").roles[1], "ESM")
	lu.assertEquals(#Medusa.Services.GroupNameParser:parse("iads.2bn.esmeralda", "iads").roles, 0)
end

function TestEsmService:test_matching_work_per_tick_is_bounded()
	-- ten stations, 64 radars of one class all round: stations saturate, the crossings are spread over ticks
	posts = {}
	for i = 1, 10 do
		local a = (i - 1) / 10 * 2 * math.pi
		station("s" .. i, math.cos(a) * 60000, math.sin(a) * 60000)
	end
	local random = lcg(7)
	for _ = 1, 64 do
		emitters[#emitters + 1] =
			{ X = (random() - 0.5) * 300000, Y = 8000, Z = (random() - 0.5) * 300000, Class = "AEW" }
	end
	local ctx = makeCtx({}, random)
	-- matching work: crossings plus third-bearing fits, counted on the ticks that match
	local originalCross, originalSolve = ESM.cross, ESM.solve
	local work, worst, ticks, matchTicks = 0, 0, 0, 0
	ESM.cross = function(a, b)
		work = work + 1
		return originalCross(a, b)
	end
	ESM.solve = function(...)
		work = work + 1
		return originalSolve(...)
	end
	local ok, err = pcall(function()
		repeat
			local matching = ctx.esm.phase == 2 and not ctx.esm.resolving
			work = 0
			ESM.tick(ctx)
			ctx.now = ctx.now + 0.1
			ticks = ticks + 1
			if matching then
				matchTicks = matchTicks + 1
				worst = math.max(worst, work)
			end
		until ctx.esm.stats.cycles >= 1 and ctx.esm.phase == 0
	end)
	ESM.cross, ESM.solve = originalCross, originalSolve
	lu.assertTrue(ok, tostring(err))
	lu.assertTrue(matchTicks > 1, "matching is spread over ticks")
	lu.assertTrue(ctx.esm.stats.saturated > 0)
	lu.assertTrue(ctx.esm.bearingCount <= 10 * E.MAX_BEARINGS_PER_CLASS)
	lu.assertTrue(ctx.esm.candCount <= E.MAX_CANDIDATES)
	-- the budget, plus at most one crossing's own work (its fits at the eight other stations)
	local overshoot = 1 + 8 * E.MAX_BEARINGS_PER_CLASS
	lu.assertTrue(worst <= E.MATCH_WORK_PER_TICK + overshoot, "matching work in one tick: " .. worst)
	lu.assertTrue(ticks * 0.1 <= 10, "the look ends within its interval: " .. ticks .. " ticks")
end

-- ── Delivering fixes ──

local function fix(x, z, errM, class)
	return { X = x, Z = z, ErrM = errM, Class = class or "FCR", Stations = "A,B,C", How = "3_station", MadeAt = 0 }
end

function TestEsmService:test_a_coarse_fix_does_not_block_a_good_one_in_the_same_area()
	local ctx = makeCtx({})
	ESM.deliverFix(ctx, ctx.esm, fix(100000, 30000, 15000))
	lu.assertEquals(#cues, 0)
	lu.assertStrContains(logged("ev=ESM_FIX"), "caused=evidence_only")
	ESM.deliverFix(ctx, ctx.esm, fix(101000, 31000, 4000))
	lu.assertEquals(#cues, 1)
	ctx.now = 30
	ESM.deliverFix(ctx, ctx.esm, fix(102000, 32000, 4000))
	lu.assertEquals(#cues, 1, "the area rests")
	lu.assertEquals(ctx.esm.stats.rested, 1)
	ctx.now = 61
	ESM.deliverFix(ctx, ctx.esm, fix(102000, 32000, 4000))
	lu.assertEquals(#cues, 2)
end

function TestEsmService:test_ten_km_is_the_cue_threshold()
	local ctx = makeCtx({})
	ESM.deliverFix(ctx, ctx.esm, fix(100000, 30000, E.CUE_MAX_ERROR_M + 1))
	lu.assertEquals(#cues, 0)
	ESM.deliverFix(ctx, ctx.esm, fix(100000, 30000, E.CUE_MAX_ERROR_M))
	lu.assertEquals(#cues, 1)
end

function TestEsmService:test_readiness_rises_on_a_fire_control_fix_not_on_an_awacs()
	local ctx = makeCtx({ Readiness = "SURPRISED" })
	ctx.crew = CFS.newState(ctx.doctrine)
	ESM.deliverFix(ctx, ctx.esm, fix(100000, 30000, 4000, "AEW"))
	lu.assertNil(ctx.crew.alertDueAt, "an AWACS orbit is routine")
	ESM.deliverFix(ctx, ctx.esm, fix(200000, 30000, 4000, "FCR"))
	lu.assertNotNil(ctx.crew.alertDueAt)
end

function TestEsmService:test_readiness_rises_after_fire_control_radars_on_three_looks()
	posts[2], posts[3] = nil, nil -- one station: bearings only, no fix
	fighter(80000, 30000, 6000)
	local ctx = makeCtx({ Readiness = "SURPRISED", TrainingMode = true })
	ctx.crew = CFS.newState(ctx.doctrine)
	run(ctx, 20)
	lu.assertNil(ctx.crew.alertDueAt, "two looks")
	run(ctx, 10)
	lu.assertNotNil(ctx.crew.alertDueAt, "three looks within two minutes")
end

-- ── Reading the radars from DCS ──

local function fakeUnit(spec)
	local u = { id_ = spec.id }
	function u:getRadar()
		if spec.dead then
			error("dead")
		end
		return spec.on, spec.tracked
	end
	function u:inAir()
		return spec.air ~= false
	end
	function u:getPosition()
		return { p = { x = spec.x, y = 6000, z = spec.z }, x = { x = 1, y = 0, z = 0 } }
	end
	function u:hasAttribute(attr)
		return spec.attrs and spec.attrs[attr] == true or false
	end
	return u
end

function TestEsmService:test_read_emitters_keeps_radars_on_near_the_stations_and_takes_turns()
	local savedGroups = GetCoalitionGroups
	local target = {
		getPoint = function()
			return { x = 1, y = 2, z = 3 }
		end,
	}
	local units = {
		fakeUnit({ id = 1, dead = true, x = 0, z = 0 }),
		fakeUnit({ id = 2, on = nil, x = 0, z = 0 }),
		fakeUnit({ id = 3, on = true, tracked = target, x = 50000, z = 0, attrs = { Fighters = true } }),
		fakeUnit({ id = 4, on = true, x = 2000000, z = 0, attrs = { Fighters = true } }), -- far beyond any reach
		fakeUnit({ id = 5, on = true, air = false, x = 0, z = 0 }),
		fakeUnit({ id = 6, on = true, x = 90000, z = 0, attrs = { AWACS = true } }),
		fakeUnit({ id = 7, on = true, x = 70000, z = 0, attrs = {} }),
	}
	GetCoalitionGroups = function(_, category)
		if category ~= Group.Category.AIRPLANE then
			return {}
		end
		return {
			{
				getUnits = function()
					return units
				end,
			},
		}
	end
	local ctx = makeCtx({})
	ESM.tick(ctx) -- builds the station list
	local state = ctx.esm
	local cfg = ctx.doctrine.ESM
	local ok, err = pcall(function()
		lu.assertEquals(ESM.readEmitters(state, coalition.side.RED, cfg), 3)
		lu.assertEquals(state.emitters[1].Class, "FCR")
		lu.assertEquals(state.emitters[1].TgtZ, 3)
		lu.assertEquals(state.emitters[2].Class, "AEW")
		lu.assertEquals(state.emitters[3].Class, "OTHER")
		local saved = E.MAX_EMITTERS
		E.MAX_EMITTERS = 2
		local n1 = ESM.readEmitters(state, coalition.side.RED, cfg)
		local first = { state.emitters[1].X, state.emitters[2].X }
		ESM.readEmitters(state, coalition.side.RED, cfg)
		local second = { state.emitters[1].X, state.emitters[2].X }
		E.MAX_EMITTERS = saved
		lu.assertEquals(n1, 2)
		lu.assertEquals(first, { 50000, 90000 })
		lu.assertEquals(second, { 70000, 50000 })
	end)
	GetCoalitionGroups = savedGroups
	lu.assertTrue(ok, tostring(err))
end

-- ── The real cue path: a fix wakes a dark SAM WARM ──

local SAVED = { "GetGroupController", "GetGroup", "EnableGroupEmissions", "SetControllerOnOff", "ControllerSetROE" }
local SAVED2 = { "ControllerSetAlarmState", "SetControllerOption", "NewULID", "ScheduleOnce" }

function TestEsmService:test_a_good_fix_wakes_a_dark_sam_through_the_observer_cue_path()
	ORS.cueHostileArea = originalCue
	local saved = {}
	for _, list in ipairs({ SAVED, SAVED2 }) do
		for _, name in ipairs(list) do
			saved[name] = _G[name]
		end
	end
	local n = 0
	NewULID = function()
		n = n + 1
		return "ULID-esm-" .. n
	end
	GetGroupController = function()
		return {}
	end
	GetGroup = function(name)
		return { name = name }
	end
	EnableGroupEmissions = function()
		return true
	end
	SetControllerOnOff = function() end
	ControllerSetROE = function() end
	ControllerSetAlarmState = function() end
	SetControllerOption = function() end
	ScheduleOnce = function()
		return 1
	end
	local ok, err = pcall(function()
		local AS, BUR = C.ActivationState, C.BatteryUnitRole
		local repository = Medusa.Services.BatteryStore:new()
		local batteries = repository:batteries()
		local grid = GeoGrid(10000, { "Battery", "Track" })
		local b = Medusa.Entities.Battery.new({
			BatteryId = 20,
			NetworkId = "net",
			GroupId = 20,
			GroupName = "sam-20",
			Role = C.BatteryRole.SR_SAM,
			Position = { x = 100000, y = 0, z = 40000 },
			ActivationState = AS.STATE_COLD,
			EngagementRangeMax = 15000,
			DetectionRangeMax = 20000,
			TotalAmmoStatus = 4,
		})
		b.Units = {
			Medusa.Entities.Battery.newUnit({ UnitId = "201", UnitName = "u201", Roles = { BUR.SEARCH_RADAR } }),
			Medusa.Entities.Battery.newUnit({ UnitId = "202", UnitName = "u202", Roles = { BUR.LAUNCHER } }),
		}
		batteries:add(b)
		grid:add("Battery", b.BatteryId, b.Position)
		local ctx = makeCtx({ ROE = "FREE" })
		ctx.now = 500
		ctx.batteryStore = batteries
		ctx.trackStore = Medusa.Services.TrackStore:new()
		ctx.networkedGeoGrid = grid
		ctx.localGeoGrid = GeoGrid(10000, { "Manpad", "Aaa" })
		ctx.localRadars = Medusa.Services.LocalRadarService.newState()
		ctx.maxEngagementRange = 20000
		ESM.deliverFix(ctx, ctx.esm, fix(100000, 30000, 3000))
		lu.assertEquals(b.ActivationState, AS.STATE_WARM)
		lu.assertNotNil(logged("esm fix wakes sam-20 WARM (from listening stations A,B,C)"))
		lu.assertStrContains(logged("ev=ESM_FIX"), "woke=sam-20")
		lu.assertEquals(ctx.esm.stats.cued, 1)
	end)
	for name, value in pairs(saved) do
		_G[name] = value
	end
	lu.assertTrue(ok, tostring(err))
end
