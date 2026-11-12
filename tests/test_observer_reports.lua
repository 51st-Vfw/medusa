local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("entities.SensorUnit")
require("entities.Track")
require("entities.ObserverPost")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.SensorUnitStore")
require("services.stores.TrackStore")
require("services.stores.ObserverPostStore")
require("services.BatteryActivationService")
require("services.SensorPollingService")
require("services.LocalRadarService")
require("services.ObserverReportService")
require("services.CrewFactorsService")

-- Observer reports (HUMINT): crews look a few times a second network-wide, radio coarse reports that arrive late or
-- not at all, and a delivered report cues local defences and wakes a dark SAM to WARM, never HOT, never a track.

local C = Medusa.Constants
local OBS = C.Observer
local ORS = Medusa.Services.ObserverReportService
local LRS = Medusa.Services.LocalRadarService
local SPS = Medusa.Services.SensorPollingService
local AS = C.ActivationState
local BUR = C.BatteryUnitRole
local MSWS = C.Manpad.SleepWakeState

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
local logLines, originalInfo, originalObserve, originalPosition, sightings, looks, lookArgs

local function logged(fragment)
	for i = 1, #logLines do
		if string.find(logLines[i], fragment, 1, true) then
			return true
		end
	end
	return false
end

local function unit(id, roles)
	return Medusa.Entities.Battery.newUnit({ UnitId = id, UnitName = "u" .. id, Roles = roles, AmmoCount = 10 })
end

local function sam(id, pos, overrides)
	local b = Medusa.Entities.Battery.new({
		BatteryId = id,
		NetworkId = "net",
		GroupId = id,
		GroupName = "sam-" .. id,
		Role = C.BatteryRole.SR_SAM,
		Position = pos,
		ActivationState = AS.STATE_COLD,
		EngagementRangeMax = 15000,
		DetectionRangeMax = 20000,
		TotalAmmoStatus = 4,
	})
	b.Units = { unit(id .. "1", { BUR.SEARCH_RADAR }), unit(id .. "2", { BUR.LAUNCHER }) }
	for k, v in pairs(overrides or {}) do
		b[k] = v
	end
	return b
end

local function manpad(id, pos)
	local b = Medusa.Entities.Battery.new({
		BatteryId = id,
		NetworkId = "net",
		GroupId = id,
		GroupName = "manpad-" .. id,
		Role = C.BatteryRole.MANPAD,
		Position = pos,
		ActivationState = AS.STATE_COLD,
		TotalAmmoStatus = 2,
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
	return b
end

local function world(random)
	local repository = Medusa.Services.BatteryStore:new()
	return {
		batteries = repository:batteries(),
		manpads = repository:manpads(),
		sensors = Medusa.Services.SensorUnitStore:new(),
		observers = Medusa.Services.ObserverPostStore:new(),
		tracks = Medusa.Services.TrackStore:new(),
		networkedGeoGrid = GeoGrid(10000, { "Battery", "Track" }),
		localGeoGrid = GeoGrid(10000, { "Manpad", "Aaa" }),
		radars = LRS.newState(),
		state = ORS.newState(random or function()
			return 0.5
		end),
	}
end

local function addSam(w, b)
	w.batteries:add(b)
	w.networkedGeoGrid:add("Battery", b.BatteryId, b.Position)
	return b
end

local function addManpad(w, b)
	w.manpads:add(b)
	w.localGeoGrid:add("Manpad", b.BatteryId, b.Position)
	return b
end

local function addPost(w, name, pos)
	w.observers:add(Medusa.Entities.ObserverPost.new({
		NetworkId = "net",
		GroupName = name,
		UnitNames = { name .. "-1" },
		Position = pos,
	}))
end

local function ctx(w, now, doctrine)
	return {
		observers = w.state,
		localRadars = w.radars,
		sensorStore = w.sensors,
		batteryStore = w.batteries,
		manpadStore = w.manpads,
		observerStore = w.observers,
		trackStore = w.tracks,
		networkedGeoGrid = w.networkedGeoGrid,
		localGeoGrid = w.localGeoGrid,
		maxEngagementRange = 20000,
		coalitionId = 1,
		now = now,
		doctrine = doctrine or { ObserverReports = true, LocalInitiative = true, ROE = C.ROEState.FREE },
		-- Crew factors: set by the network only when doctrine CrewFactors is on (nil: reports ignore skill, readiness
		-- and load).
		crew = w.crew,
		crewSkillIndex = w.skillIndex,
		networkId = "net",
	}
end

-- A sighting the boundary returns for an observer group (only coarse fields, as observeAirspace fills them).
local function sighting(x, z, opts)
	opts = opts or {}
	return {
		x = x,
		z = z,
		Heard = opts.heard or false,
		Night = opts.night or false,
		Kind = opts.kind or "jet",
		TypeName = opts.typeName,
		Identity = opts.identity or "hostile",
	}
end

-- One second of a network: the radio and roster pass, then a look at each quarter second (one look per tick).
local function second(w, t, doctrine)
	ORS.update(ctx(w, t, doctrine))
	local n = 0
	for k = 0, 3 do
		n = n + ORS.look(ctx(w, t + k * 0.25, doctrine))
	end
	return n
end

TestObserverReports = {}

function TestObserverReports:setUp()
	for _, name in ipairs(SAVED_GLOBALS) do
		saved[name] = _G[name]
	end
	local n = 0
	NewULID = function()
		n = n + 1
		return "ULID-" .. n
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
	logLines = {}
	originalInfo = env.info
	env.info = function(msg)
		logLines[#logLines + 1] = msg
	end
	sightings, looks, lookArgs = {}, {}, {}
	originalObserve = SPS.observeAirspace
	originalPosition = SPS.observerPosition
	SPS.observeAirspace = function(look, out)
		looks[#looks + 1] = look.GroupName
		lookArgs[#lookArgs + 1] = { GroupName = look.GroupName, ErrorScale = look.ErrorScale, Seed = look.Seed }
		local s = sightings[look.GroupName]
		if not s then
			return false
		end
		out.Position.x, out.Position.y, out.Position.z = s.x, 0, s.z
		out.ErrorM = s.Heard and OBS.POSITION_ERROR_HEARD_M or OBS.POSITION_ERROR_SEEN_M
		out.Heading8 = not s.Heard and "N" or nil
		out.Height, out.Speed, out.Kind, out.TypeName = "low", "fast", s.Kind, s.TypeName
		out.Count, out.Heard, out.Night, out.Identity = "one", s.Heard, s.Night, s.Identity
		return true
	end
	SPS.observerPosition = function(unitNames)
		return unitNames[1] ~= "dead-post-1" and { x = 0, y = 0, z = 0 } or nil
	end
end

function TestObserverReports:tearDown()
	for name, value in pairs(saved) do
		_G[name] = value
	end
	env.info = originalInfo
	SPS.observeAirspace = originalObserve
	SPS.observerPosition = originalPosition
end

function TestObserverReports:test_what_a_report_caused_names_every_effect()
	lu.assertEquals(ORS.causedWord(0, 0, 0), "nothing")
	lu.assertEquals(ORS.causedWord(1, 0, 0), "wake_sam")
	lu.assertEquals(ORS.causedWord(0, 2, 0), "cue_crews")
	lu.assertEquals(ORS.causedWord(0, 0, 1), "cue_radar")
	lu.assertEquals(ORS.causedWord(1, 0, 1), "wake_sam+cue_radar")
	lu.assertEquals(ORS.causedWord(1, 3, 1), "wake_sam+cue_crews+cue_radar")
end

function TestObserverReports:test_observer_post_report_arrives_after_the_radio_delay()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0)

	second(w, 100)

	lu.assertTrue(logged("observer report sent: obs-hill saw one hostile jet"))
	lu.assertEquals(ORS.pendingCount(w.state), 1)
	sightings["obs-hill"] = nil
	-- Day delay at random 0.5: 30 + 0.5 * 60 = 60 s.
	second(w, 159)
	lu.assertFalse(logged("observer report received"))
	second(w, 160)
	lu.assertTrue(logged("observer report received: from obs-hill after 60 s"))
	lu.assertEquals(ORS.pendingCount(w.state), 0)
end

function TestObserverReports:test_night_and_a_busy_net_lengthen_the_delay()
	local w = world()
	addPost(w, "obs-a", { x = 0, y = 0, z = 0 })
	addPost(w, "obs-b", { x = 0, y = 0, z = 0 })
	sightings["obs-a"] = sighting(3000, 0, { night = true })
	sightings["obs-b"] = sighting(3000, 0, { night = true })

	second(w, 100)

	-- First: 60 s x 1.5 = 90 s. Second waits behind one report: 90 + 10 = 100 s.
	lu.assertTrue(logged("due in 90 s"))
	lu.assertTrue(logged("due in 100 s"))
end

function TestObserverReports:test_some_reports_are_lost()
	local rolls = { 0.5, 0.05 } -- delay roll, then loss roll under LOSS_DAY
	local i = 0
	local w = world(function()
		i = i + 1
		return rolls[(i - 1) % #rolls + 1]
	end)
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0)

	second(w, 100)
	second(w, 200)

	lu.assertTrue(logged("observer report lost: from obs-hill"))
	lu.assertFalse(logged("observer report received"))
end

function TestObserverReports:test_looks_are_budgeted_round_robin_and_reporters_rest()
	local w = world()
	for k = 1, 10 do
		addPost(w, "obs-" .. k, { x = 0, y = 0, z = 0 })
	end
	sightings["obs-1"] = sighting(3000, 0)

	lu.assertEquals(second(w, 100), OBS.LOOKS_PER_SEC)
	lu.assertEquals(second(w, 101), OBS.LOOKS_PER_SEC)
	lu.assertEquals(second(w, 102), OBS.LOOKS_PER_SEC)

	-- 12 looks over 10 posts: each looked once, then two more; obs-1 reported and rests a minute.
	local count = {}
	for _, name in ipairs(looks) do
		count[name] = (count[name] or 0) + 1
	end
	lu.assertEquals(count["obs-1"], 1)
	lu.assertEquals(count["obs-2"], 2)
	lu.assertEquals(count["obs-10"], 1)
end

function TestObserverReports:test_delivered_report_cues_manpads_and_wakes_a_dark_sam_to_warm_only()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	local crew = addManpad(w, manpad(10, { x = 4000, y = 0, z = 0 }))
	local battery = addSam(w, sam(20, { x = 15000, y = 0, z = 0 }))
	local far = addSam(w, sam(21, { x = 60000, y = 0, z = 0 }))
	sightings["obs-hill"] = sighting(3000, 0)

	second(w, 100)
	lu.assertEquals(battery.ActivationState, AS.STATE_COLD)
	second(w, 161)

	lu.assertNotEquals(crew.Manpad.SleepWakeState, MSWS.ASLEEP)
	lu.assertEquals(battery.ActivationState, AS.STATE_WARM)
	lu.assertEquals(battery.CueWarmUntil, 161 + OBS.WARM_HOLD_SEC)
	lu.assertTrue(logged("observer report wakes sam-20 WARM"))
	lu.assertEquals(far.ActivationState, AS.STATE_COLD)
	-- Never a track, never a target, never HOT.
	lu.assertEquals(w.tracks:count(), 0)
	lu.assertNil(battery.CurrentTargetTrackId)
end

function TestObserverReports:test_report_does_not_wake_a_sam_under_roe_hold_harm_shutdown_or_suppression()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	local held = addSam(w, sam(20, { x = 5000, y = 0, z = 0 }, { HarmShutdownUntil = 500 }))
	sightings["obs-hill"] = sighting(3000, 0)
	second(w, 100)
	second(w, 160)
	lu.assertEquals(held.ActivationState, AS.STATE_COLD)

	local w2 = world()
	addPost(w2, "obs-hill", { x = 0, y = 0, z = 0 })
	local quiet = addSam(w2, sam(22, { x = 5000, y = 0, z = 0 }))
	local hold = { ObserverReports = true, LocalInitiative = true, ROE = C.ROEState.HOLD }
	second(w2, 100, hold)
	second(w2, 160, hold)
	lu.assertEquals(quiet.ActivationState, AS.STATE_COLD)
end

function TestObserverReports:test_delivered_report_keeps_a_covering_local_radar_up()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	local record = { GroupName = "dogear", Position = { x = 10000, y = 0, z = 0 }, ReachM = 35000, UpUntil = 0 }
	w.radars.records[1] = record
	w.radars.byGroup.dogear = record
	sightings["obs-hill"] = sighting(3000, 0)

	second(w, 100)
	second(w, 160)

	lu.assertEquals(record.CueReason, "observer report")
	lu.assertEquals(record.CueUntil, 160 + C.LocalRadar.CUE_HOLD_SEC)
end

function TestObserverReports:test_a_crew_that_sees_a_jet_brings_its_own_radar_up_at_once()
	local w = world()
	local battery = addSam(w, sam(20, { x = 0, y = 0, z = 0 }))
	sightings["sam-20"] = sighting(3000, 0)

	second(w, 100)

	lu.assertEquals(battery.ActivationState, AS.STATE_WARM)
	lu.assertTrue(logged("local initiative: sam-20 comes up WARM (own crew saw a jet)"))
	lu.assertEquals(w.tracks:count(), 0)
end

function TestObserverReports:test_local_initiative_switch_off_waits_for_the_network()
	local w = world()
	local battery = addSam(w, sam(20, { x = 0, y = 0, z = 0 }))
	sightings["sam-20"] = sighting(3000, 0)

	second(w, 100, { ObserverReports = true, LocalInitiative = false, ROE = C.ROEState.FREE })

	lu.assertEquals(battery.ActivationState, AS.STATE_COLD)
	lu.assertFalse(logged("local initiative"))
end

function TestObserverReports:test_a_crew_with_a_local_radar_cues_its_own_radar()
	local w = world()
	local crew = addManpad(w, manpad(10, { x = 0, y = 0, z = 0 }))
	local record = { GroupName = crew.GroupName, Position = crew.Position, ReachM = 35000, UpUntil = 0 }
	w.radars.records[1] = record
	w.radars.byGroup[crew.GroupName] = record
	sightings[crew.GroupName] = sighting(2000, 0, { heard = true, kind = "helicopter" })

	second(w, 100)

	lu.assertEquals(record.CueReason, "local initiative")
	lu.assertTrue(logged("local initiative: manpad-10 cues its local radar (own crew heard a helicopter)"))
end

function TestObserverReports:test_switch_off_means_no_looks()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0)

	lu.assertEquals(second(w, 100, { ObserverReports = false }), 0)
	lu.assertEquals(#looks, 0)
end

function TestObserverReports:test_all_kinds_of_crew_look_and_dead_posts_leave()
	local w = world()
	addSam(w, sam(20, { x = 0, y = 0, z = 0 }))
	addManpad(w, manpad(10, { x = 0, y = 0, z = 0 }))
	w.sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "net",
		UnitId = 1,
		UnitName = "ewr-1",
		GroupId = 1,
		GroupName = "ewr",
		Position = { x = 0, y = 0, z = 0 },
	}))
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	addPost(w, "dead-post", { x = 0, y = 0, z = 0 })

	second(w, 100)

	table.sort(looks)
	lu.assertEquals(looks, { "ewr", "manpad-10", "obs-hill", "sam-20" })
	lu.assertNil(w.observers:getByGroupName("dead-post"))
	lu.assertTrue(logged("observer post dead-post: no crew left"))
end

function TestObserverReports:test_reports_never_reach_alert_zones()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0)
	second(w, 100)
	second(w, 160)

	-- Alert zones count tracks in the networked grid; a report adds none.
	local ids = w.networkedGeoGrid:queryRadius({ x = 3000, y = 0, z = 0 }, 20000, { "Track" }).TrackIds
	lu.assertNil(next(ids or {}))
	local delivered = 0
	ORS.eachDelivered(w.state, function(r)
		delivered = delivered + 1
		lu.assertNil(r.TrackId)
		lu.assertNil(r.Velocity)
	end)
	lu.assertEquals(delivered, 1)
end

function TestObserverReports:test_a_full_net_loses_the_report()
	local w = world()
	for k = 1, OBS.MAX_PENDING + 1 do
		addPost(w, "obs-" .. k, { x = 0, y = 0, z = 0 })
		sightings["obs-" .. k] = sighting(3000, 0)
	end
	local t = 100
	for _ = 1, 10 do
		second(w, t)
		t = t + 1
	end

	lu.assertEquals(ORS.pendingCount(w.state), OBS.MAX_PENDING)
	lu.assertTrue(logged("observer report lost: from obs-33 (radio net saturated)"))
end

-- == Looks spread over ticks; emission control and the network picture decide what a report may wake ==

local function track(id, pos, ident)
	return Medusa.Entities.Track.new({
		TrackId = id,
		NetworkId = id,
		Position = pos,
		Velocity = { x = 200, y = 0, z = 0 },
		AssessedAircraftType = C.AssessedAircraftType.FIGHTER,
		TrackIdentification = ident or C.TrackIdentification.FRIENDLY,
	})
end

local FREE = { ObserverReports = true, LocalInitiative = true, ROE = C.ROEState.FREE }

function TestObserverReports:test_one_look_per_call_at_the_look_rate()
	local w = world()
	addPost(w, "obs-a", { x = 0, y = 0, z = 0 })
	addPost(w, "obs-b", { x = 0, y = 0, z = 0 })
	ORS.update(ctx(w, 100))
	lu.assertEquals(ORS.look(ctx(w, 100)), 1)
	lu.assertEquals(ORS.look(ctx(w, 100)), 0)
	lu.assertEquals(ORS.look(ctx(w, 100.25)), 1)
end

function TestObserverReports:test_an_unidentified_report_cues_crews_but_wakes_no_sam()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	local crew = addManpad(w, manpad(10, { x = 4000, y = 0, z = 0 }))
	local battery = addSam(w, sam(20, { x = 15000, y = 0, z = 0 }))
	sightings["obs-hill"] = sighting(3000, 0, { heard = true, kind = "helicopter", identity = "unidentified" })

	second(w, 100)
	second(w, 161)
	lu.assertTrue(logged("observer report received"))

	lu.assertTrue(logged("observer report received"))
	lu.assertNotEquals(crew.Manpad.SleepWakeState, MSWS.ASLEEP)
	lu.assertEquals(battery.ActivationState, AS.STATE_COLD)
	lu.assertFalse(logged("wakes"))
end

function TestObserverReports:test_a_sam_whose_emcon_the_mission_sets_is_never_woken()
	local doctrine = {
		ObserverReports = true,
		LocalInitiative = true,
		ROE = C.ROEState.FREE,
		EMCON = { SR_SAM = "MINIMIZE" },
	}
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	local ambush = addSam(w, sam(20, { x = 15000, y = 0, z = 0 }))
	local own = addSam(w, sam(21, { x = 0, y = 0, z = 40000 }))
	sightings["obs-hill"] = sighting(3000, 0)
	sightings["sam-21"] = sighting(0, 41000)

	second(w, 100, doctrine)
	second(w, 161, doctrine)
	lu.assertTrue(logged("observer report received"))

	lu.assertEquals(ambush.ActivationState, AS.STATE_COLD)
	lu.assertEquals(own.ActivationState, AS.STATE_COLD)
	lu.assertNil(ambush.CueWarmUntil)
end

function TestObserverReports:test_a_long_range_sam_is_never_woken()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	local lr = addSam(w, sam(20, { x = 15000, y = 0, z = 0 }, { Role = C.BatteryRole.LR_SAM }))
	local own = addSam(w, sam(21, { x = 0, y = 0, z = 40000 }, { Role = C.BatteryRole.LR_SAM }))
	sightings["obs-hill"] = sighting(3000, 0)
	sightings["sam-21"] = sighting(0, 41000)

	second(w, 100)
	second(w, 161)
	lu.assertTrue(logged("observer report received"))

	lu.assertEquals(lr.ActivationState, AS.STATE_COLD)
	lu.assertEquals(own.ActivationState, AS.STATE_COLD)
end

function TestObserverReports:test_no_sam_is_woken_where_the_network_already_holds_a_track()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	local battery = addSam(w, sam(20, { x = 15000, y = 0, z = 0 }))
	local own = addSam(w, sam(21, { x = 0, y = 0, z = 40000 }))
	local t1 = track("t1", { x = 8000, y = 3000, z = 0 })
	local t2 = track("t2", { x = 0, y = 3000, z = 45000 }, C.TrackIdentification.HOSTILE)
	for _, t in ipairs({ t1, t2 }) do
		w.tracks:add(t)
		w.networkedGeoGrid:add("Track", t.TrackId, t.Position)
	end
	sightings["obs-hill"] = sighting(3000, 0)
	sightings["sam-21"] = sighting(0, 41000)

	second(w, 100)
	second(w, 161)
	lu.assertTrue(logged("observer report received"))

	lu.assertEquals(battery.ActivationState, AS.STATE_COLD)
	lu.assertEquals(own.ActivationState, AS.STATE_COLD)
end

function TestObserverReports:test_a_failed_wake_leaves_no_warm_hold()
	local w = world()
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	local battery = addSam(w, sam(20, { x = 15000, y = 0, z = 0 }))
	sightings["obs-hill"] = sighting(3000, 0)
	local BAS = Medusa.Services.BatteryActivationService
	local goWarm = BAS.goWarm
	BAS.goWarm = function()
		return false
	end
	second(w, 100, FREE)
	local ok, err = pcall(second, w, 161, FREE)
	BAS.goWarm = goWarm
	assert(ok, err)
	lu.assertNil(battery.CueWarmUntil)
end

function TestObserverReports:test_training_mode_never_loses_a_report_and_uses_the_median_delay()
	local w = world(function()
		return 0.01 -- a roll that would lose the report and give the shortest delay
	end)
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0)
	local doctrine = { ObserverReports = true, LocalInitiative = true, ROE = C.ROEState.FREE, TrainingMode = true }
	doctrine.CrewFactors = false

	second(w, 100, doctrine)
	sightings["obs-hill"] = nil
	second(w, 160, doctrine)

	lu.assertTrue(logged("due in 60 s"))
	lu.assertTrue(logged("observer report received: from obs-hill after 60 s"))
	lu.assertFalse(logged("observer report lost"))
end

-- == Crew factors: skill, readiness and net load ==

local R = C.Readiness
local CF = C.CrewFactors
local CFS = Medusa.Services.CrewFactorsService

local function crew(readiness, load)
	local s = CFS.newState({ Readiness = readiness })
	s.load = load or 0
	return s
end

local function rolls(values)
	local i = 0
	return function()
		i = i + 1
		return values[(i - 1) % #values + 1]
	end
end

local function skillIndex(skill)
	return {
		get = function()
			return skill
		end,
	}
end

local function count(fragment)
	local n = 0
	for i = 1, #logLines do
		if string.find(logLines[i], fragment, 1, true) then
			n = n + 1
		end
	end
	return n
end

function TestObserverReports:test_report_made_by_skill_and_readiness()
	lu.assertEquals(ORS.reportMadeChance("AVERAGE", R.ALERTED), 0.25)
	lu.assertEquals(ORS.reportMadeChance("GOOD", R.ENGAGED), 0.5)
	lu.assertEquals(ORS.reportMadeChance("HIGH", R.ALERTED), 0.75)
	lu.assertEquals(ORS.reportMadeChance("EXCELLENT", R.ENGAGED), 0.95)
	lu.assertAlmostEquals(ORS.reportMadeChance("AVERAGE", R.SURPRISED), 0.15, 1e-9)
	lu.assertAlmostEquals(ORS.reportMadeChance("EXCELLENT", R.SURPRISED), 0.95 * 0.9, 1e-9)
end

function TestObserverReports:test_skilled_crews_shrug_off_surprise_faster()
	-- The SURPRISED penalties keep this share of their size: AVERAGE 100%, GOOD 75%, HIGH 50%, EXCELLENT 25%.
	lu.assertAlmostEquals(ORS.reportMadeChance("AVERAGE", R.SURPRISED), 0.25 * 0.6, 1e-9)
	lu.assertAlmostEquals(ORS.reportMadeChance("GOOD", R.SURPRISED), 0.5 * 0.7, 1e-9)
	lu.assertAlmostEquals(ORS.reportMadeChance("HIGH", R.SURPRISED), 0.75 * 0.8, 1e-9)
	local expect = { AVERAGE = 2, GOOD = 1.75, HIGH = 1.5, EXCELLENT = 1.25 }
	for skill, factor in pairs(expect) do
		local lo, hi = ORS.reportDelayRange(skill, R.SURPRISED, false, 0)
		lu.assertAlmostEquals(lo, CF.REPORT_DELAY_SEC[skill][1] * factor, 1e-9)
		lu.assertAlmostEquals(hi, CF.REPORT_DELAY_SEC[skill][2] * factor, 1e-9)
	end
	-- not skill-scaled: delivery on the receiving net, and the other readiness levels
	lu.assertAlmostEquals(ORS.deliveryChance(R.SURPRISED, 0, false), 0.6, 1e-9)
	lu.assertEquals(ORS.reportMadeChance("EXCELLENT", R.ALERTED), 0.95)
	local lo = ORS.reportDelayRange("EXCELLENT", R.ENGAGED, false, 0)
	lu.assertAlmostEquals(lo, 20 * 0.9, 1e-9)
end

function TestObserverReports:test_delay_by_skill_readiness_night_and_load()
	local lo, hi = ORS.reportDelayRange("EXCELLENT", R.ALERTED, false, 0)
	lu.assertEquals({ lo, hi }, { 20, 40 })
	lo, hi = ORS.reportDelayRange("HIGH", R.ENGAGED, false, 0)
	lu.assertAlmostEquals(lo, 27, 1e-9)
	lu.assertAlmostEquals(hi, 81, 1e-9)
	lo, hi = ORS.reportDelayRange("GOOD", R.ALERTED, false, 0)
	lu.assertEquals({ lo, hi }, { 45, 150 })
	lo, hi = ORS.reportDelayRange("AVERAGE", R.SURPRISED, true, 0.5)
	lu.assertEquals(lo, 60 * 2 * OBS.NIGHT_DELAY_FACTOR + 0.5 * CF.LOAD_DELAY_MAX_SEC)
	lu.assertEquals(hi, 240 * 2 * OBS.NIGHT_DELAY_FACTOR + 0.5 * CF.LOAD_DELAY_MAX_SEC)
end

function TestObserverReports:test_position_error_by_skill()
	lu.assertEquals(ORS.positionErrorScale("EXCELLENT"), 0.6)
	lu.assertEquals(ORS.positionErrorScale("HIGH"), 0.8)
	lu.assertEquals(ORS.positionErrorScale("GOOD"), 1.0)
	lu.assertEquals(ORS.positionErrorScale("AVERAGE"), 1.4)
end

function TestObserverReports:test_delivery_sweet_spot_is_alerted_with_a_calm_net()
	local calm, busy = 0.1, 0.9
	local best = ORS.deliveryChance(R.ALERTED, calm, false)
	lu.assertAlmostEquals(best, 0.97 * (1 - CF.LOAD_DELIVERY_PENALTY * calm), 1e-9)
	lu.assertTrue(best > ORS.deliveryChance(R.SURPRISED, calm, false))
	lu.assertTrue(best > ORS.deliveryChance(R.ALERTED, busy, false))
	lu.assertTrue(best > ORS.deliveryChance(R.ENGAGED, busy, false))
	lu.assertAlmostEquals(ORS.deliveryChance(R.SURPRISED, 0, false), 0.6, 1e-9)
	lu.assertAlmostEquals(ORS.deliveryChance(R.ALERTED, 0, true), 0.97 * CF.NIGHT_DELIVERY_FACTOR, 1e-9)
	-- a full net loses 40 % more
	lu.assertAlmostEquals(ORS.deliveryChance(R.ALERTED, 1, false), 0.97 * 0.6, 1e-9)
end

function TestObserverReports:test_an_observer_post_knows_whom_to_call_under_surprise()
	lu.assertAlmostEquals(ORS.deliveryChance(R.SURPRISED, 0, false, true), CF.OBSERVER_SURPRISED_DELIVERED, 1e-9)
	lu.assertEquals(CF.OBSERVER_SURPRISED_DELIVERED, 0.8)
	lu.assertAlmostEquals(ORS.deliveryChance(R.SURPRISED, 0, false, false), 0.6, 1e-9)
	-- alerted or engaged it is as good as any crew
	lu.assertAlmostEquals(ORS.deliveryChance(R.ALERTED, 0, false, true), 0.97, 1e-9)
end

function TestObserverReports:test_skill_of_the_group_and_its_fallback()
	local doctrine = { CrewSuppression = { DefaultCrewSkill = "GOOD" } }
	local b = { Units = { { CrewSkill = "AVERAGE" }, { CrewSkill = "HIGH" } } }
	lu.assertEquals(ORS.groupSkill(doctrine, nil, b, nil), "HIGH")
	lu.assertEquals(ORS.groupSkill(doctrine, skillIndex("EXCELLENT"), nil, { "obs-1" }), "EXCELLENT")
	-- Not in the mission file index (spawned at run time): the doctrine default, else AVERAGE.
	lu.assertEquals(ORS.groupSkill(doctrine, skillIndex(nil), nil, { "spawned-1" }), "GOOD")
	lu.assertEquals(ORS.groupSkill(nil, skillIndex(nil), nil, { "spawned-1" }), "AVERAGE")
	lu.assertEquals(ORS.groupSkill({}, nil, { Units = {} }, nil), "AVERAGE")
	-- The second value says whether the group took the default.
	lu.assertEquals({ ORS.groupSkill(doctrine, nil, b, nil) }, { "HIGH", false })
	lu.assertEquals({ ORS.groupSkill(doctrine, skillIndex(nil), nil, { "spawned-1" }) }, { "GOOD", true })
	local defaulted = { Units = { { CrewSkill = "GOOD", CrewSkillDefaulted = true } } }
	lu.assertEquals({ ORS.groupSkill(doctrine, nil, defaulted, nil) }, { "GOOD", true })
	local mixed = { Units = { { CrewSkill = "GOOD", CrewSkillDefaulted = true }, { CrewSkill = "AVERAGE" } } }
	lu.assertEquals({ ORS.groupSkill(doctrine, nil, mixed, nil) }, { "AVERAGE", false })
end

function TestObserverReports:test_an_average_crew_often_never_calls_it_in_and_rests_the_full_interval()
	local w = world(function()
		return 0.5 -- above AVERAGE 0.25: not made
	end)
	w.crew = crew(R.ALERTED, 0.25)
	addSam(w, sam(20, { x = 0, y = 0, z = 0 }))
	sightings["sam-20"] = sighting(3000, 0)

	second(w, 100)
	second(w, 101)

	lu.assertEquals(count("observer report not made: sam-20 (AVERAGE crew, ALERTED)"), 1)
	lu.assertEquals(
		count(
			"|net=net|ev=REPORT_NOT_MADE|from=sam-20|skill=AVERAGE|readiness=ALERTED|saw=hostile_jet|heard=false"
				.. "|load=0.25"
		),
		1
	)
	lu.assertFalse(logged("observer report sent"))
	lu.assertEquals(ORS.pendingCount(w.state), 0)
	-- the chance to get a report out is per sighting: a flubbed call rests the full report interval, and the crew's
	-- local initiative does not fire again early either
	local initiative = count("local initiative: sam-20")
	second(w, 120)
	second(w, 100 + OBS.REPORT_INTERVAL_SEC - 1)
	lu.assertEquals(count("observer report not made: sam-20"), 1)
	lu.assertEquals(count("local initiative: sam-20"), initiative)
	second(w, 100 + OBS.REPORT_INTERVAL_SEC)
	lu.assertEquals(count("observer report not made: sam-20"), 2)
end

function TestObserverReports:test_an_observer_post_counts_one_skill_higher_gun_and_sam_crews_do_not()
	local w = world(function()
		return 0.4 -- under GOOD 0.5, over AVERAGE 0.25
	end)
	w.crew = crew(R.ALERTED)
	w.skillIndex = skillIndex("AVERAGE")
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	addSam(w, sam(20, { x = 0, y = 0, z = 0 }))
	sightings["obs-hill"] = sighting(3000, 0)
	sightings["sam-20"] = sighting(3000, 0)

	second(w, 100)

	lu.assertEquals(count("observer report not made: sam-20 (AVERAGE crew, ALERTED)"), 1)
	-- the post calls it in with a GOOD crew's delay (45 + 0.4 x 105 = 87 s) and precision
	lu.assertTrue(logged("observer report sent: obs-hill saw one hostile jet"))
	lu.assertTrue(logged("due in 87 s"))
	local scale = {}
	for _, a in ipairs(lookArgs) do
		scale[a.GroupName] = a.ErrorScale
	end
	lu.assertEquals(scale["obs-hill"], ORS.positionErrorScale("GOOD"))
	lu.assertEquals(scale["sam-20"], ORS.positionErrorScale("AVERAGE"))
	-- an EXCELLENT post stays EXCELLENT; a flubbed post names both skills
	lu.assertEquals(CF.OBSERVER_SKILL_UP.EXCELLENT, "EXCELLENT")
	local w2 = world(function()
		return 0.6
	end)
	w2.crew = crew(R.ALERTED)
	w2.skillIndex = skillIndex("AVERAGE")
	addPost(w2, "obs-ridge", { x = 0, y = 0, z = 0 })
	sightings["obs-ridge"] = sighting(3000, 0)
	second(w2, 100)
	lu.assertTrue(logged("observer report not made: obs-ridge (AVERAGE crew, trained observer: GOOD, ALERTED)"))
	lu.assertTrue(logged("|ev=REPORT_NOT_MADE|from=obs-ridge|skill=AVERAGE|skill_as=GOOD|readiness=ALERTED"))
end

function TestObserverReports:test_the_crew_roster_is_logged_once_per_network()
	local w = world(function()
		return 0.99
	end)
	w.crew = crew(R.ALERTED)
	w.skillIndex = skillIndex("EXCELLENT")
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	addPost(w, "obs-ridge", { x = 0, y = 0, z = 0 })
	addSam(w, sam(20, { x = 0, y = 0, z = 0 })) -- its units' skill is not in the mission file: the default

	second(w, 100)
	second(w, 100 + OBS.ROSTER_REFRESH_SEC + 1)

	lu.assertEquals(
		count(
			"crew roster of network net: 2 observer posts (EXCELLENT:2), 1 other crews (AVERAGE:1); 1 on the default skill AVERAGE"
		),
		1
	)
	lu.assertEquals(
		count(
			"|net=net|ev=CREW_ROSTER|observers=2|observer_skills=EXCELLENT:2|crews=1|crew_skills=AVERAGE:1|defaulted=1|default_skill=AVERAGE"
		),
		1
	)
	-- with crew factors off there is no roster line
	logLines = {}
	local w2 = world()
	addPost(w2, "obs-hill", { x = 0, y = 0, z = 0 })
	second(w2, 100)
	lu.assertFalse(logged("crew roster"))
end

function TestObserverReports:test_an_excellent_crew_calls_fast_and_the_report_says_what_it_caused()
	local w = world(function()
		return 0.5
	end)
	w.crew = crew(R.ALERTED)
	w.skillIndex = skillIndex("EXCELLENT")
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	addSam(w, sam(20, { x = 15000, y = 0, z = 0 }))
	sightings["obs-hill"] = sighting(3000, 0)

	second(w, 100)
	lu.assertTrue(logged("observer report sent: obs-hill saw one hostile jet"))
	lu.assertTrue(logged("due in 30 s")) -- 20 + 0.5 x 20
	sightings["obs-hill"] = nil
	second(w, 131) -- the SAM crew looked first, the post at 100.25: due at 130.25, heard at the next pass

	lu.assertTrue(logged("observer report received: from obs-hill after 31 s"))
	lu.assertTrue(logged("|ev=REPORT_DELIVERED|from=obs-hill|after_s=31|saw=hostile_jet|x=3000|z=0|err_m=1000"))
	lu.assertTrue(logged("|caused=wake_sam|woke=sam-20|crews_cued=0|radars_cued=0|load=0.00"))
	lu.assertTrue(logged("|ev=WAKE|battery=sam-20|from=COLD|to=WARM|reason=observer_report"))
end

function TestObserverReports:test_a_lost_report_is_a_debrief_line()
	local w = world(rolls({ 0.1, 0.5, 0.99 })) -- made, delay, then not heard
	w.crew = crew(R.ALERTED)
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0, { identity = "unidentified" })

	second(w, 100)
	sightings["obs-hill"] = nil
	second(w, 400)

	lu.assertTrue(logged("observer report lost: from obs-hill (not heard on the net)"))
	lu.assertTrue(logged("|ev=REPORT_LOST|from=obs-hill|why=not_heard|after_s=300|saw=unidentified_jet|load=0.00"))
end

function TestObserverReports:test_a_delivered_hostile_report_spreads_the_word_in_a_surprised_network()
	local w = world(function()
		return 0.05
	end)
	w.crew = crew(R.SURPRISED)
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0)

	for t = 100, 104 do
		second(w, t)
	end
	lu.assertTrue(logged("observer report sent"))
	sightings["obs-hill"] = nil
	second(w, 600)

	lu.assertTrue(logged("ev=REPORT_DELIVERED"))
	lu.assertEquals(w.crew.alertWhy, "hostile_report")
	lu.assertNotNil(w.crew.alertDueAt)
end

function TestObserverReports:test_training_mode_makes_every_report_and_loses_none_whatever_the_crew()
	local w = world(function()
		return 0.99
	end)
	w.crew = crew(R.SURPRISED, 0.5)
	local doctrine = { ObserverReports = true, LocalInitiative = true, ROE = C.ROEState.FREE, TrainingMode = true }
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0)

	for t = 100, 101 do
		second(w, t, doctrine)
	end
	sightings["obs-hill"] = nil
	-- An AVERAGE observer post counts GOOD (a surprised GOOD crew's delay is x 1.75); day, load 0.5:
	-- 45 x 1.75 + 15 .. 150 x 1.75 + 15, midpoint 185.6 s.
	lu.assertTrue(logged("due in 186 s"))
	second(w, 2000, doctrine)

	lu.assertFalse(logged("not made"))
	lu.assertFalse(logged("observer report lost"))
	lu.assertTrue(logged("observer report received: from obs-hill"))
end

function TestObserverReports:test_a_surprised_networks_crews_look_half_as_often_but_every_crew_gets_its_turn()
	local w = world()
	w.crew = crew(R.SURPRISED)
	for k = 1, 4 do
		addSam(w, sam(20 + k, { x = 0, y = 0, z = 0 }))
	end
	local n = 0
	for t = 100, 103 do
		n = n + second(w, t)
	end

	lu.assertEquals(n, 2 * OBS.LOOKS_PER_SEC)
	local seen = {}
	for _, name in ipairs(looks) do
		seen[name] = (seen[name] or 0) + 1
	end
	for k = 1, 4 do
		lu.assertEquals(seen["sam-" .. (20 + k)], 2)
	end

	w.crew.readiness = R.ALERTED
	lu.assertEquals(second(w, 104), OBS.LOOKS_PER_SEC)
end

function TestObserverReports:test_a_surprised_crews_look_rate_rises_with_its_skill()
	-- 1 - 0.5 x share: GOOD 62.5%, HIGH 75%, EXCELLENT 87.5% of its turns, every run the same
	for skill, expected in pairs({ GOOD = 5, HIGH = 6, EXCELLENT = 7 }) do
		looks = {}
		local w = world()
		w.crew = crew(R.SURPRISED)
		for k = 1, 4 do
			local b = sam(20 + k, { x = 0, y = 0, z = 0 })
			for _, u in ipairs(b.Units) do
				u.CrewSkill = skill
			end
			addSam(w, b)
		end
		for t = 100, 107 do
			second(w, t)
		end
		local seen = {}
		for _, name in ipairs(looks) do
			seen[name] = (seen[name] or 0) + 1
		end
		for k = 1, 4 do
			lu.assertEquals(seen["sam-" .. (20 + k)], expected, skill)
		end
	end
end

function TestObserverReports:test_a_roster_slot_taken_by_another_group_starts_its_look_credit_afresh()
	local w = world()
	w.crew = crew(R.SURPRISED)
	local good = sam(21, { x = 0, y = 0, z = 0 })
	for _, u in ipairs(good.Units) do
		u.CrewSkill = "GOOD"
	end
	addSam(w, good)
	second(w, 100) -- four turns at 62.5%: two looks, half a look of credit left
	lu.assertEquals(w.state.roster[1].GroupName, "sam-21")
	lu.assertAlmostEquals(w.state.roster[1].LookCredit, 0.5, 1e-9)
	good.OperationalStatus = C.BatteryOperationalStatus.DESTROYED
	addSam(w, sam(22, { x = 0, y = 0, z = 0 })) -- the default skill, AVERAGE: every second turn
	second(w, 100 + OBS.ROSTER_REFRESH_SEC + 1)
	lu.assertEquals(w.state.roster[1].GroupName, "sam-22")
	lu.assertEquals(w.state.rosterCount, 1)
	lu.assertAlmostEquals(w.state.roster[1].LookCredit, 0, 1e-9)
end

function TestObserverReports:test_observer_posts_keep_their_full_look_rate_when_surprised()
	local w = world()
	w.crew = crew(R.SURPRISED)
	addPost(w, "obs-1", { x = 0, y = 0, z = 0 })
	addPost(w, "obs-2", { x = 0, y = 0, z = 0 })
	addSam(w, sam(21, { x = 0, y = 0, z = 0 }))
	addSam(w, sam(22, { x = 0, y = 0, z = 0 }))
	local n = 0
	for t = 100, 103 do
		n = n + second(w, t)
	end

	-- 16 turns, four each: the posts look at every turn, the SAM crews at every second one
	local seen = {}
	for _, name in ipairs(looks) do
		seen[name] = (seen[name] or 0) + 1
	end
	lu.assertEquals(seen["obs-1"], 4)
	lu.assertEquals(seen["obs-2"], 4)
	lu.assertEquals(seen["sam-21"], 2)
	lu.assertEquals(seen["sam-22"], 2)
	lu.assertEquals(n, 12)
end

function TestObserverReports:test_training_reports_of_a_group_take_a_new_fixed_error_direction_each_time()
	local w = world()
	w.crew = crew(R.ALERTED)
	w.skillIndex = skillIndex("EXCELLENT")
	local doctrine = { ObserverReports = true, LocalInitiative = true, ROE = C.ROEState.FREE, TrainingMode = true }
	addPost(w, "obs-hill", { x = 0, y = 0, z = 0 })
	sightings["obs-hill"] = sighting(3000, 0)

	second(w, 100, doctrine)
	second(w, 100 + OBS.REPORT_INTERVAL_SEC, doctrine)

	lu.assertEquals(#lookArgs, 2)
	local hash = Medusa.Chance.hash("obs-hill")
	lu.assertEquals(lookArgs[1].Seed, hash)
	lu.assertEquals(lookArgs[2].Seed, hash + 1)
	-- outside training no seed is passed
	local w2 = world()
	addPost(w2, "obs-hill", { x = 0, y = 0, z = 0 })
	second(w2, 100)
	lu.assertNil(lookArgs[3].Seed)
end
