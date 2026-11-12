local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("entities.SensorUnit")
require("entities.Track")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.SensorUnitStore")
require("services.stores.TrackStore")
require("services.BatteryActivationService")
require("services.EmconService")
require("services.ManpadService")
require("services.AaaService")
require("services.LocalRadarService")

local C = Medusa.Constants
local LRS = Medusa.Services.LocalRadarService
local BUR = C.BatteryUnitRole
local AS = C.ActivationState
local MSWS = C.Manpad.SleepWakeState

-- Dog Ear: getSensors range 23.4 km, reach against 5 m2 about 35 km. 1L13: 200.6 km.
local DOG_EAR_RANGE = 23400
local EWR_RANGE = 200600

local saved = {}
local SAVED_GLOBALS = {
	"GetGroupController",
	"GetGroup",
	"EnableGroupEmissions",
	"SetControllerOnOff",
	"ControllerSetROE",
	"ControllerSetAlarmState",
	"SetControllerOption",
	"NewULID",
	"ScheduleOnce",
}
local logLines, emissions
local originalInfo

local function captureLogs()
	logLines = {}
	originalInfo = env.info
	env.info = function(msg)
		logLines[#logLines + 1] = msg
	end
end

local function logged(fragment)
	for i = 1, #logLines do
		if string.find(logLines[i], fragment, 1, true) then
			return true
		end
	end
	return false
end

local function sensor(groupName, range, overrides)
	local s = Medusa.Entities.SensorUnit.new({
		NetworkId = "net",
		UnitId = groupName .. "-u",
		UnitName = groupName .. "-u",
		GroupId = 1,
		GroupName = groupName,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = range,
	})
	for k, v in pairs(overrides or {}) do
		s[k] = v
	end
	return s
end

local function unit(id, roles)
	return Medusa.Entities.Battery.newUnit({ UnitId = id, UnitName = "u" .. id, Roles = roles, AmmoCount = 10 })
end

local function aaaBattery(id, pos, withRadar)
	local b = Medusa.Entities.Battery.new({
		BatteryId = id,
		NetworkId = "net",
		GroupId = id,
		GroupName = "grp-" .. id,
		Role = C.BatteryRole.AAA,
		Position = pos,
		ActivationState = AS.STATE_COLD,
		WeaponRangeMax = 2500,
		TotalAmmoStatus = 100,
		DetectionRangeMax = withRadar and DOG_EAR_RANGE or nil,
	})
	b.Units = { unit(id .. "1", { BUR.AAA }) }
	if withRadar then
		b.Units[2] = unit(id .. "2", { BUR.SEARCH_RADAR })
	end
	b.Aaa.Mode = withRadar and C.Aaa.Mode.RADAR_DIRECTED or C.Aaa.Mode.INDEPENDENT
	return b
end

local function manpad(id, pos, withRadar)
	local b = Medusa.Entities.Battery.new({
		BatteryId = id,
		NetworkId = "net",
		GroupId = id,
		GroupName = "grp-" .. id,
		Role = C.BatteryRole.MANPAD,
		Position = pos,
		ActivationState = AS.STATE_COLD,
		TotalAmmoStatus = 2,
		DetectionRangeMax = withRadar and DOG_EAR_RANGE or nil,
		Manpad = {
			SleepWakeState = MSWS.ASLEEP,
			WakeReason = C.Manpad.WakeReason.NONE,
			AlertCycleCount = 0,
			AudioCueRangeM = 3000,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	b.Units = { unit(id .. "1", { BUR.MANPAD }) }
	if withRadar then
		b.Units[2] = unit(id .. "2", { BUR.SEARCH_RADAR })
	end
	return b
end

local function track(id, pos, overrides)
	local t = Medusa.Entities.Track.new({
		TrackId = id,
		NetworkId = id,
		Position = pos,
		Velocity = { x = 200, y = 0, z = 0 },
		AssessedAircraftType = C.AssessedAircraftType.FIGHTER,
		TrackIdentification = C.TrackIdentification.HOSTILE,
	})
	for k, v in pairs(overrides or {}) do
		t[k] = v
	end
	return t
end

local function world()
	local repository = Medusa.Services.BatteryStore:new()
	local w = {
		repository = repository,
		batteries = repository:batteries(),
		manpads = repository:manpads(),
		sensors = Medusa.Services.SensorUnitStore:new(),
		tracks = Medusa.Services.TrackStore:new(),
		networkedGeoGrid = GeoGrid(10000, { "Battery", "Track" }),
		localGeoGrid = GeoGrid(10000, { "Manpad", "Aaa" }),
		state = LRS.newState(),
	}
	return w
end

local function addTrack(w, t)
	w.tracks:add(t)
	w.networkedGeoGrid:add("Track", t.TrackId, t.Position)
	return t
end

local function addManpad(w, b)
	w.manpads:add(b)
	w.localGeoGrid:add("Manpad", b.BatteryId, b.Position)
	return b
end

local function addAaa(w, b)
	w.batteries:add(b)
	if b.Aaa.Mode == C.Aaa.Mode.INDEPENDENT then
		w.localGeoGrid:add("Aaa", b.BatteryId, b.Position)
	else
		w.networkedGeoGrid:add("Battery", b.BatteryId, b.Position)
	end
	return b
end

local function ctx(w, now, doctrine)
	return {
		localRadars = w.state,
		sensorStore = w.sensors,
		batteryStore = w.batteries,
		manpadStore = w.manpads,
		trackStore = w.tracks,
		networkedGeoGrid = w.networkedGeoGrid,
		localGeoGrid = w.localGeoGrid,
		now = now,
		doctrine = doctrine or { LocalCueingRadars = true, EMCON = {} },
		networkId = "red-net",
	}
end

TestLocalRadarService = {}

function TestLocalRadarService:setUp()
	for _, name in ipairs(SAVED_GLOBALS) do
		saved[name] = _G[name]
	end
	local n = 0
	NewULID = function()
		n = n + 1
		return "ULID-" .. n
	end
	emissions = {}
	GetGroupController = function()
		return {}
	end
	GetGroup = function(name)
		return { name = name }
	end
	EnableGroupEmissions = function(group, on)
		emissions[#emissions + 1] = { group = group.name, on = on }
		return true
	end
	SetControllerOnOff = function() end
	ControllerSetROE = function() end
	ControllerSetAlarmState = function() end
	SetControllerOption = function() end
	ScheduleOnce = function()
		return 1
	end
	Medusa.Services.EmconService._sensorGroupState["dogear"] = nil
	captureLogs()
end

function TestLocalRadarService:tearDown()
	for name, value in pairs(saved) do
		_G[name] = value
	end
	env.info = originalInfo
end

function TestLocalRadarService:test_classify_marks_short_reach_sensor_groups_only()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	w.sensors:add(sensor("ewr", EWR_RANGE))
	w.sensors:add(sensor("named", DOG_EAR_RANGE, { NamedRole = true }))
	w.sensors:add(sensor("awacs", DOG_EAR_RANGE, { IsAirborne = true }))
	w.sensors:add(sensor("unprobed", nil))
	LRS.classify(ctx(w, 0))
	local records = w.state.records
	lu.assertEquals(#records, 1)
	lu.assertEquals(records[1].GroupName, "dogear")
	lu.assertEquals(records[1].Kind, "SENSOR")
	lu.assertAlmostEquals(records[1].ReachM, DOG_EAR_RANGE / C.ContactEvidence.REACH_RATIO, 1)
	lu.assertTrue(w.sensors:getByGroupName("dogear")[1].IsLocalRadar)
	lu.assertFalse(w.sensors:getByGroupName("ewr")[1].IsLocalRadar)
	lu.assertTrue(logged("local radar dogear: reach 35 km"))
end

function TestLocalRadarService:test_classify_is_off_with_the_doctrine_switch()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	LRS.classify(ctx(w, 0, { LocalCueingRadars = false }))
	lu.assertEquals(#w.state.records, 0)
	lu.assertFalse(w.sensors:getAll()[1].IsLocalRadar)
end

function TestLocalRadarService:test_classify_takes_aaa_and_manpad_groups_with_a_short_reach_radar()
	local w = world()
	local guns = addAaa(w, aaaBattery("a1", { x = 0, y = 0, z = 0 }, true))
	local plainGuns = addAaa(w, aaaBattery("a2", { x = 0, y = 0, z = 5000 }, false))
	local igla = addManpad(w, manpad("m1", { x = 2000, y = 0, z = 0 }, true))
	local plainIgla = addManpad(w, manpad("m2", { x = 3000, y = 0, z = 0 }, false))
	LRS.classify(ctx(w, 0))
	lu.assertEquals(#w.state.records, 2)
	lu.assertEquals(guns.LocalRadar.Kind, "BATTERY")
	lu.assertEquals(igla.LocalRadar.Kind, "MANPAD")
	lu.assertNil(plainGuns.LocalRadar)
	lu.assertNil(plainIgla.LocalRadar)
	-- The radar supports the independent guns and both MANPAD groups in its reach.
	lu.assertEquals(#guns.LocalRadar.Supported, 3)
end

function TestLocalRadarService:test_classify_keeps_state_when_run_again()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	LRS.classify(ctx(w, 0))
	local record = w.state.records[1]
	record.UpUntil = 99
	LRS.classify(ctx(w, 5))
	lu.assertEquals(#w.state.records, 1)
	lu.assertIs(w.state.records[1], record)
	lu.assertEquals(record.UpUntil, 99)
end

function TestLocalRadarService:test_classify_forgets_radars_that_are_gone_and_frees_their_battery()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	local guns = addAaa(w, aaaBattery("aaa1", { x = 0, y = 0, z = 0 }, true))
	LRS.classify(ctx(w, 0))
	lu.assertEquals(#w.state.records, 2)
	guns.CueWarmUntil = 50

	w.sensors:removeByGroupName("dogear")
	table.remove(guns.Units, 2) -- the radar is destroyed, the guns live on
	LRS.classify(ctx(w, 10))

	lu.assertEquals(#w.state.records, 0)
	lu.assertNil(w.state.byGroup.dogear)
	lu.assertNil(w.state.byGroup[guns.GroupName])
	lu.assertNil(guns.LocalRadar)
	lu.assertNil(guns.CueWarmUntil)
end

function TestLocalRadarService:test_sensor_radar_is_dark_until_a_hostile_is_near_then_holds()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	LRS.classify(ctx(w, 0))
	LRS.update(ctx(w, 0))
	lu.assertEquals(#emissions, 1)
	lu.assertFalse(emissions[1].on)
	lu.assertEquals(w.sensors:getAll()[1].RadarStatus, "DARK")
	LRS.update(ctx(w, 1))
	lu.assertEquals(#emissions, 1, "dark is written once")

	-- A hostile 45 km out: beyond the 35 km reach but inside reach + 15 km margin.
	addTrack(w, track("t1", { x = 45000, y = 3000, z = 0 }))
	LRS.update(ctx(w, 2))
	lu.assertTrue(emissions[2].on)
	lu.assertEquals(w.sensors:getAll()[1].RadarStatus, "ACTIVE")
	lu.assertTrue(logged("local radar dogear on (threat near)"))

	w.tracks:remove("t1")
	w.networkedGeoGrid:remove("t1")
	LRS.update(ctx(w, 2 + C.LocalRadar.HOLD_SEC - 1))
	lu.assertEquals(#emissions, 2, "held up after the threat leaves")
	LRS.update(ctx(w, 2 + C.LocalRadar.HOLD_SEC))
	lu.assertFalse(emissions[3].on)
	lu.assertTrue(logged("local radar dogear off (no threat near)"))
end

function TestLocalRadarService:test_a_threat_found_is_rechecked_only_every_few_seconds()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	addTrack(w, track("t1", { x = 20000, y = 3000, z = 0 }))
	LRS.classify(ctx(w, 0))
	local queries = 0
	local grid = w.networkedGeoGrid
	local query = grid.queryRadius
	grid.queryRadius = function(...)
		queries = queries + 1
		return query(...)
	end

	LRS.update(ctx(w, 100))
	lu.assertEquals(queries, 1)
	for t = 101, 100 + C.LocalRadar.THREAT_RECHECK_SEC - 1 do
		LRS.update(ctx(w, t))
	end
	lu.assertEquals(queries, 1, "a threat near keeps the radar up without a grid query each pass")
	LRS.update(ctx(w, 100 + C.LocalRadar.THREAT_RECHECK_SEC))
	lu.assertEquals(queries, 2)
	lu.assertEquals(w.state.records[1].UpUntil, 100 + C.LocalRadar.THREAT_RECHECK_SEC + C.LocalRadar.HOLD_SEC)
end

function TestLocalRadarService:test_far_friendly_and_missile_tracks_do_not_wake_it()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	addTrack(w, track("far", { x = 60000, y = 3000, z = 0 }))
	addTrack(w, track("friend", { x = 10000, y = 3000, z = 0 }, { TrackIdentification = "FRIENDLY" }))
	addTrack(w, track("arm", { x = 10000, y = 3000, z = 0 }, { AssessedAircraftType = "HARM" }))
	addTrack(w, track("old", { x = 10000, y = 3000, z = 0 }, { LifecycleState = "STALE" }))
	LRS.classify(ctx(w, 0))
	LRS.update(ctx(w, 0))
	lu.assertFalse(emissions[#emissions].on)
end

function TestLocalRadarService:test_alerted_supported_unit_brings_it_up()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	local igla = addManpad(w, manpad("m1", { x = 2000, y = 0, z = 0 }, false))
	LRS.classify(ctx(w, 0))
	igla.Manpad.SleepWakeState = MSWS.ALERT
	LRS.update(ctx(w, 0))
	lu.assertTrue(emissions[#emissions].on)
	lu.assertTrue(logged("local radar dogear on (supported units alerted)"))
end

function TestLocalRadarService:test_observer_cue_brings_covering_radars_up_only()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	LRS.classify(ctx(w, 0))
	lu.assertEquals(LRS.cueFromReport(ctx(w, 0), { x = 90000, y = 0, z = 0 }, "observer report"), 0)
	lu.assertEquals(LRS.cueFromReport(ctx(w, 0), { x = 40000, y = 0, z = 0 }, "observer report"), 1)
	LRS.update(ctx(w, 1))
	lu.assertTrue(emissions[#emissions].on)
	lu.assertTrue(logged("local radar dogear on (observer report)"))
end

function TestLocalRadarService:test_battery_radar_goes_warm_and_emcon_keeps_it_there()
	local w = world()
	local guns = addAaa(w, aaaBattery("a1", { x = 0, y = 0, z = 0 }, true))
	guns.OperationalStatus = C.BatteryOperationalStatus.ACTIVE
	LRS.classify(ctx(w, 0))
	addTrack(w, track("t1", { x = 20000, y = 2000, z = 0 }))
	LRS.update(ctx(w, 10))
	lu.assertEquals(guns.ActivationState, AS.STATE_WARM)
	lu.assertTrue(logged("local radar grp-a1 on (threat near)"))
	-- EMCON (AAA: MINIMIZE, i.e. COLD) does not take it down while the local radar wants it up.
	Medusa.Services.EmconService.applyPolicy(
		{ batteryStore = w.batteries, sensorStore = w.sensors, doctrine = { EMCON = {} }, now = 20 },
		nil
	)
	lu.assertEquals(guns.ActivationState, AS.STATE_WARM)
	w.tracks:remove("t1")
	w.networkedGeoGrid:remove("t1")
	LRS.update(ctx(w, 10 + C.LocalRadar.HOLD_SEC))
	lu.assertEquals(guns.ActivationState, AS.STATE_COLD)
	lu.assertTrue(logged("local radar grp-a1 off (no threat near)"))
end

function TestLocalRadarService:test_battery_radar_left_alone_while_hot_or_in_harm_shutdown()
	local w = world()
	local guns = addAaa(w, aaaBattery("a1", { x = 0, y = 0, z = 0 }, true))
	LRS.classify(ctx(w, 0))
	guns.HarmShutdownUntil = 100
	addTrack(w, track("t1", { x = 20000, y = 2000, z = 0 }))
	LRS.update(ctx(w, 10))
	lu.assertEquals(guns.ActivationState, AS.STATE_COLD)
	guns.HarmShutdownUntil = nil
	guns.ActivationState = AS.STATE_HOT
	w.tracks:remove("t1")
	w.networkedGeoGrid:remove("t1")
	LRS.update(ctx(w, 200))
	lu.assertEquals(guns.ActivationState, AS.STATE_HOT)
end

function TestLocalRadarService:test_manpad_group_radar_goes_warm_but_never_touches_a_firing_crew()
	local w = world()
	local igla = addManpad(w, manpad("m1", { x = 0, y = 0, z = 0 }, true))
	LRS.classify(ctx(w, 0))
	addTrack(w, track("t1", { x = 20000, y = 2000, z = 0 }))
	LRS.update(ctx(w, 10))
	lu.assertEquals(igla.ActivationState, AS.STATE_WARM)
	igla.ActivationState = AS.STATE_HOT
	igla.Manpad.SleepWakeState = MSWS.HOT
	w.tracks:remove("t1")
	w.networkedGeoGrid:remove("t1")
	LRS.update(ctx(w, 10 + C.LocalRadar.HOLD_SEC))
	lu.assertEquals(igla.ActivationState, AS.STATE_HOT)
	igla.ActivationState = AS.STATE_WARM
	igla.Manpad.SleepWakeState = MSWS.ALERT
	LRS.update(ctx(w, 10 + C.LocalRadar.HOLD_SEC + 1))
	-- An alerted crew of its own keeps the radar up; once it sleeps again the radar goes dark.
	lu.assertEquals(igla.ActivationState, AS.STATE_WARM)
	igla.Manpad.SleepWakeState = MSWS.ASLEEP
	LRS.update(ctx(w, 10 + 2 * C.LocalRadar.HOLD_SEC + 2))
	lu.assertEquals(igla.ActivationState, AS.STATE_COLD)
end

function TestLocalRadarService:test_contacts_cue_sleeping_manpads_and_independent_guns_in_reach()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	local near = addManpad(w, manpad("m1", { x = 20000, y = 0, z = 0 }, false))
	local beyond = addManpad(w, manpad("m2", { x = 41000, y = 0, z = 0 }, false))
	local guns = addAaa(w, aaaBattery("a1", { x = 22000, y = 0, z = 3000 }, false))
	LRS.classify(ctx(w, 0))
	local record = w.state.records[1]
	local jet = addTrack(w, track("t1", { x = 28000, y = 500, z = 0 }))
	local trackManager = {
		getTrackIdByNetworkId = function(_, id)
			return id == "obj-jet" and "t1" or nil
		end,
	}
	local reports = { { NetworkId = "obj-jet", Position = jet.Position } }
	local cued = LRS.onRadarContacts(ctx(w, 30), record, reports, trackManager)
	lu.assertEquals(cued, 2)
	lu.assertEquals(near.Manpad.SleepWakeState, MSWS.ALERTING)
	lu.assertEquals(near.Manpad.WakeReason, C.Manpad.WakeReason.LOCAL_RADAR)
	lu.assertEquals(beyond.Manpad.SleepWakeState, MSWS.ASLEEP, "outside the radar's reach")
	lu.assertEquals(guns.Aaa.CuedUntil, 30 + C.LocalRadar.AAA_CUE_SEC)
	-- Rate-limited.
	lu.assertEquals(LRS.onRadarContacts(ctx(w, 32), record, reports, trackManager), 0)
end

function TestLocalRadarService:test_missile_and_unclassified_contacts_do_not_cue()
	local w = world()
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	local near = addManpad(w, manpad("m1", { x = 20000, y = 0, z = 0 }, false))
	LRS.classify(ctx(w, 0))
	local record = w.state.records[1]
	addTrack(w, track("t1", { x = 22000, y = 500, z = 0 }, { AssessedAircraftType = "MISSILE" }))
	addTrack(w, track("t2", { x = 22000, y = 500, z = 0 }, { AssessedAircraftType = "UNKNOWN" }))
	local ids = { a = "t1", b = "t2" }
	local trackManager = {
		getTrackIdByNetworkId = function(_, id)
			return ids[id]
		end,
	}
	local cued = LRS.onRadarContacts(ctx(w, 30), record, { { NetworkId = "a" }, { NetworkId = "b" } }, trackManager)
	lu.assertEquals(cued, 0)
	lu.assertEquals(near.Manpad.SleepWakeState, MSWS.ASLEEP)
end

-- == A local radar no other ground radar covers sweeps briefly every few minutes ==

local function lit(w, groupName)
	return w.sensors:getByGroupName(groupName)[1].RadarStatus == "ACTIVE"
end

function TestLocalRadarService:test_an_uncovered_local_radar_sweeps_briefly_every_few_minutes()
	local w = world()
	w.state = LRS.newState(function()
		return 0
	end)
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	LRS.classify(ctx(w, 0))
	LRS.update(ctx(w, 0))
	LRS.update(ctx(w, 179))
	lu.assertFalse(lit(w, "dogear"))

	LRS.update(ctx(w, 180))
	lu.assertTrue(lit(w, "dogear"))
	lu.assertTrue(logged("local radar dogear on (periodic sweep)"))
	LRS.update(ctx(w, 189))
	lu.assertTrue(lit(w, "dogear"))
	LRS.update(ctx(w, 190)) -- 10 s, not 10 s plus the 60 s hold of a threat
	lu.assertFalse(lit(w, "dogear"))
	LRS.update(ctx(w, 369))
	lu.assertFalse(lit(w, "dogear"))
	LRS.update(ctx(w, 370))
	lu.assertTrue(lit(w, "dogear"))
end

function TestLocalRadarService:test_a_local_radar_an_early_warning_radar_covers_does_not_sweep()
	local w = world()
	w.state = LRS.newState(function()
		return 0
	end)
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	w.sensors:add(sensor("ewr", EWR_RANGE, { Position = { x = 150000, y = 0, z = 0 } }))
	LRS.classify(ctx(w, 0))
	for _, t in ipairs({ 0, 180, 185, 400, 600 }) do
		LRS.update(ctx(w, t))
		lu.assertFalse(lit(w, "dogear"))
	end
end

function TestLocalRadarService:test_sweeps_follow_the_switch_and_a_mission_emcon_of_minimize()
	local doctrines = {
		{ LocalCueingRadars = true, LocalRadarSweeps = false },
		{ LocalCueingRadars = true, EMCON = { EWR = "MINIMIZE" } },
	}
	for _, doctrine in ipairs(doctrines) do
		local w = world()
		w.state = LRS.newState(function()
			return 0
		end)
		w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
		LRS.classify(ctx(w, 0, doctrine))
		for _, t in ipairs({ 0, 180, 185 }) do
			LRS.update(ctx(w, t, doctrine))
			lu.assertFalse(lit(w, "dogear"))
		end
	end
	local w = world()
	w.state = LRS.newState(function()
		return 0
	end)
	local guns = addAaa(w, aaaBattery("a1", { x = 0, y = 0, z = 0 }, true))
	local doctrine = { LocalCueingRadars = true, EMCON = { AAA = "MINIMIZE" } }
	LRS.classify(ctx(w, 0, doctrine))
	LRS.update(ctx(w, 0, doctrine))
	LRS.update(ctx(w, 180, doctrine))
	lu.assertEquals(guns.ActivationState, AS.STATE_COLD)
end

function TestLocalRadarService:test_a_sweeping_gun_radar_is_held_warm_against_emcon_for_the_sweep_only()
	local w = world()
	w.state = LRS.newState(function()
		return 0
	end)
	local guns = addAaa(w, aaaBattery("a1", { x = 0, y = 0, z = 0 }, true))
	LRS.classify(ctx(w, 0))
	LRS.update(ctx(w, 0))
	LRS.update(ctx(w, 180))
	lu.assertEquals(guns.ActivationState, AS.STATE_WARM)
	lu.assertEquals(guns.CueWarmUntil, 190)
	LRS.update(ctx(w, 190))
	lu.assertEquals(guns.ActivationState, AS.STATE_COLD)
end

function TestLocalRadarService:test_a_local_radar_starts_sweeping_once_the_radar_that_covered_it_is_gone()
	local w = world()
	w.state = LRS.newState(function()
		return 0
	end)
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	w.sensors:add(sensor("ewr", EWR_RANGE, { Position = { x = 150000, y = 0, z = 0 } }))
	LRS.classify(ctx(w, 0))
	LRS.update(ctx(w, 0))
	LRS.update(ctx(w, 180)) -- covered: no sweep, the next one falls due at 360
	lu.assertFalse(lit(w, "dogear"))

	w.sensors:removeByGroupName("ewr") -- destroyed: the network reclassifies its local radars
	LRS.classify(ctx(w, 200))
	LRS.update(ctx(w, 359))
	lu.assertFalse(lit(w, "dogear"))
	LRS.update(ctx(w, 360))
	lu.assertTrue(lit(w, "dogear"))
end

function TestLocalRadarService:test_training_mode_sweeps_on_a_fixed_per_radar_phase_then_mid_window()
	local w = world()
	w.state = LRS.newState(function()
		return 0
	end)
	local doctrine = { LocalCueingRadars = true, EMCON = {}, TrainingMode = true }
	w.sensors:add(sensor("dogear", DOG_EAR_RANGE))
	w.sensors:add(sensor("dogear-2", DOG_EAR_RANGE, { Position = { x = 0, y = 0, z = 60000 } }))
	LRS.classify(ctx(w, 0, doctrine))
	-- the first sweep of each radar falls at its own fixed point of the window (a hash of its group name), so the
	-- network's sweeps are not all at once
	local first = 180 + Medusa.Chance.fraction("dogear") * 120
	local first2 = 180 + Medusa.Chance.fraction("dogear-2") * 120
	lu.assertNotEquals(math.floor(first), math.floor(first2))
	-- names that differ only in their last character still land seconds apart
	lu.assertTrue(
		math.abs(Medusa.Chance.fraction("dogear-1") - Medusa.Chance.fraction("dogear-2")) * 120 >= 5,
		"dogear-1 and dogear-2 sweep close together"
	)
	lu.assertEquals(w.state.byGroup["dogear"].NextSweepAt, first)
	lu.assertEquals(w.state.byGroup["dogear-2"].NextSweepAt, first2)
	LRS.update(ctx(w, first - 0.5, doctrine))
	lu.assertFalse(lit(w, "dogear"))
	LRS.update(ctx(w, first, doctrine))
	lu.assertTrue(lit(w, "dogear"))
	lu.assertTrue(logged("|net=red-net|ev=LOCAL_RADAR_UP|radar=dogear|reason=periodic sweep"))
	LRS.update(ctx(w, first + 14.5, doctrine))
	lu.assertTrue(lit(w, "dogear"))
	LRS.update(ctx(w, first + 15, doctrine)) -- (10 + 20) / 2
	lu.assertFalse(lit(w, "dogear"))
	-- then every mid-window period after the sweep
	lu.assertEquals(w.state.byGroup["dogear"].NextSweepAt, first + 15 + 240)
end
