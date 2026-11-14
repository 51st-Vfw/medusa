local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Config")
require("core.IadsNetwork")
require("entities.SensorUnit")
require("entities.Battery")

-- Local cueing radars inside the network: a radar+guns group waits for its radar's reach before it is classified,
-- lit local radars are polled on their radar channel, dark ones are not, and their contacts cue the crews in reach.

local COAL_RED = (coalition and coalition.side and coalition.side.RED) or 1
local AS = Medusa.Constants.ActivationState
local BR = Medusa.Constants.BatteryRole
local BUR = Medusa.Constants.BatteryUnitRole
local TS = Medusa.Constants.TrackSource
local RADAR = 4

local DOG_EAR = { ["SAM SR"] = true }
local SHILKA = { ["SAM TR"] = true, AAA = true }
local IGLA = { MANPADS = true }

local saved = {}
local GLOBALS = {
	"GetGroupUnits",
	"GetUnitDesc",
	"GetUnitID",
	"GetUnitType",
	"GetUnitPosition",
	"GetUnitHeading",
	"GetUnitAmmo",
}

local function setupGroup(attributeSets, typeNames)
	local units = {}
	local attributesByUnit, typeByName = {}, {}
	for i = 1, #attributeSets do
		local name = "unit-" .. i
		local unit = {
			getID = function()
				return i
			end,
			getName = function()
				return name
			end,
		}
		units[i] = unit
		attributesByUnit[unit] = attributeSets[i]
		typeByName[name] = typeNames[i]
	end
	GetGroupUnits = function()
		return units
	end
	GetUnitID = function(unit)
		return unit:getID()
	end
	GetUnitType = function(value)
		local name = type(value) == "table" and value:getName() or value
		return typeByName[name]
	end
	GetUnitPosition = function()
		return { x = 100, y = 0, z = 200 }
	end
	GetUnitHeading = function()
		return 0
	end
	GetUnitAmmo = function()
		return {}
	end
	GetUnitDesc = function(unit)
		return { displayName = unit:getName(), attributes = attributesByUnit[unit] }
	end
end

local function makeIads()
	local iads = Medusa.Core.IadsNetwork:new({ id = "T", coalitionId = COAL_RED, prefix = "iads" })
	iads:initialize()
	iads._running = true
	return iads
end

local function addGroup(iads, groupId, groupName)
	iads._discovery._listener.onAdded({
		groupId = groupId,
		groupName = groupName,
		coalitionId = COAL_RED,
		category = "ground",
		parsed = Medusa.Services.GroupNameParser:parse(groupName, "iads"),
	})
end

TestLocalRadarNetwork = {}

function TestLocalRadarNetwork:setUp()
	for i = 1, #GLOBALS do
		saved[GLOBALS[i]] = _G[GLOBALS[i]]
	end
	saved.Detection = Controller.Detection
	Controller.Detection = { VISUAL = 1, RADAR = RADAR }
end

function TestLocalRadarNetwork:tearDown()
	for i = 1, #GLOBALS do
		_G[GLOBALS[i]] = saved[GLOBALS[i]]
	end
	Controller.Detection = saved.Detection
end

function TestLocalRadarNetwork:test_dog_ear_with_shilka_waits_for_its_reach_then_becomes_radar_directed_aaa()
	local iads = makeIads()
	setupGroup({ DOG_EAR, SHILKA }, { "Dog Ear radar", "ZSU-23-4 Shilka" })
	addGroup(iads, 700, "dogear-shilka")

	lu.assertNil(iads:getAssetIndex():batteries():getByGroupId(700))
	lu.assertEquals(#iads:getAssetIndex():sensors():getUniqueGroupNames(), 0)
	lu.assertNotNil(iads:_collectProbeTargets()["Dog Ear radar"])

	iads._probingService._cache["Dog Ear radar"] = { detectionRangeMax = 23400 }
	iads:_onProbingComplete()

	local battery = iads:getAssetIndex():batteries():getByGroupId(700)
	lu.assertNotNil(battery)
	lu.assertEquals(battery.Role, BR.AAA)
	lu.assertEquals(battery.DetectionRangeMax, 23400)
	lu.assertTrue(Medusa.Entities.Battery.isRadarDirectedAaa(battery))
	lu.assertEquals(#iads._localRadars.records, 1)
	lu.assertIs(iads._localRadars.records[1].Battery, battery)
end

function TestLocalRadarNetwork:test_unprobed_radar_with_guns_stays_a_sensor_group()
	local iads = makeIads()
	setupGroup({ DOG_EAR, SHILKA }, { "Dog Ear radar", "ZSU-23-4 Shilka" })
	addGroup(iads, 701, "dogear-shilka")

	iads:_onProbingComplete()

	lu.assertNil(iads:getAssetIndex():batteries():getByGroupId(701))
	lu.assertEquals(#iads:getAssetIndex():sensors():getUniqueGroupNames(), 1)
end

function TestLocalRadarNetwork:test_dynamic_radar_with_guns_after_probing_uses_the_probe_cache()
	local iads = makeIads()
	iads._probingService._cache["Dog Ear radar"] = { detectionRangeMax = 23400 }
	iads._probeComplete = true
	setupGroup({ DOG_EAR, SHILKA }, { "Dog Ear radar", "ZSU-23-4 Shilka" })

	addGroup(iads, 702, "dogear-shilka")

	local battery = iads:getAssetIndex():batteries():getByGroupId(702)
	lu.assertNotNil(battery)
	lu.assertEquals(battery.Role, BR.AAA)
	lu.assertEquals(#iads._localRadars.records, 1)
end

function TestLocalRadarNetwork:test_dog_ear_with_igla_gets_its_reach_and_a_local_radar()
	local iads = makeIads()
	setupGroup({ DOG_EAR, IGLA, IGLA }, { "Dog Ear radar", "SA-18 Igla manpad", "SA-18 Igla manpad" })
	addGroup(iads, 703, "dogear-igla")
	lu.assertNotNil(iads:getAssetIndex():manpads():getByGroupId(703))
	lu.assertNotNil(iads:_collectProbeTargets()["Dog Ear radar"])

	iads._probingService._cache["Dog Ear radar"] = { detectionRangeMax = 23400 }
	iads:_onProbingComplete()

	local manpad = iads:getAssetIndex():manpads():getByGroupId(703)
	lu.assertEquals(manpad.DetectionRangeMax, 23400)
	lu.assertEquals(#iads._localRadars.records, 1)
	lu.assertEquals(iads._localRadars.records[1].Kind, "MANPAD")
end

local function localSensor(iads)
	iads:getAssetIndex():sensors():add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 1,
		UnitName = "dogear-1",
		GroupId = 1,
		GroupName = "dogear",
		SensorType = Medusa.Constants.SensorType.EWR,
		GroupCategory = Group.Category.GROUND,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = 23400,
	}))
end

local nextGroupId = 20
local function localBattery(iads, role, groupName, state)
	nextGroupId = nextGroupId + 1
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = nextGroupId,
		GroupName = groupName,
		Role = role,
		ActivationState = state,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = 23400,
		Manpad = role == BR.MANPAD and {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.ASLEEP,
			WakeReason = Medusa.Constants.Manpad.WakeReason.NONE,
			AlertCycleCount = 0,
			AudioCueRangeM = 3000,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		} or nil,
	})
	local gun = role == BR.MANPAD and BUR.MANPAD or BUR.AAA
	battery.Units = { { Roles = { BUR.SEARCH_RADAR } }, { Roles = { gun } } }
	if role == BR.MANPAD then
		iads:getAssetIndex():manpads():add(battery)
	else
		iads:getAssetIndex():batteries():add(battery)
	end
	return battery
end

local function classify(iads)
	local ctx = iads:_localPictureCtx()
	Medusa.Services.LocalRadarService.classify(ctx)
end

function TestLocalRadarNetwork:test_dark_local_radar_is_not_polled()
	local iads = makeIads()
	iads._doctrine.BatteryTargetDatalink = true
	localSensor(iads)
	localBattery(iads, BR.AAA, "dogear-shilka", AS.STATE_COLD)
	classify(iads)

	lu.assertEquals(#iads:_buildPollList(), 0)
end

function TestLocalRadarNetwork:test_lit_local_radars_are_polled_once_on_the_radar_channel_at_search_rate()
	local iads = makeIads()
	iads._doctrine.BatteryTargetDatalink = false
	localSensor(iads)
	localBattery(iads, BR.AAA, "dogear-shilka", AS.STATE_WARM)
	localBattery(iads, BR.MANPAD, "dogear-igla", AS.STATE_WARM)
	classify(iads)
	for _, record in ipairs(iads._localRadars.records) do
		if record.Kind == "SENSOR" then
			record.Applied = true
		end
	end

	local byName, count = {}, 0
	for _, entry in ipairs(iads:_buildPollList()) do
		byName[entry.groupName] = entry
		count = count + 1
	end

	lu.assertEquals(count, 3)
	local rate = Medusa.Services.SensorPollingService.scanRateFor(iads._doctrine, "SAM_SEARCH")
	for _, name in ipairs({ "dogear", "dogear-shilka", "dogear-igla" }) do
		local entry = byName[name]
		lu.assertNotNil(entry, name)
		lu.assertEquals(entry.detectionType, RADAR)
		lu.assertEquals(entry.scanRateSec, rate)
		lu.assertNotNil(entry.localRadar)
	end
	lu.assertEquals(byName.dogear.sourceType, TS.EARLY_WARNING_RADAR)
	lu.assertEquals(byName["dogear-shilka"].sourceType, TS.SAM_BATTERY)
end

function TestLocalRadarNetwork:test_reused_entries_forget_the_radar_channel()
	local iads = makeIads()
	localSensor(iads)
	classify(iads)
	iads._localRadars.records[1].Applied = true
	iads:_buildPollList()
	iads._localRadars.records[1].Applied = false
	localBattery(iads, BR.SR_SAM, "sa6", AS.STATE_HOT)
	iads._doctrine.BatteryTargetDatalink = true

	local list = iads:_buildPollList()

	lu.assertEquals(#list, 1)
	lu.assertEquals(list[1].groupName, "sa6")
	lu.assertNil(list[1].detectionType)
	lu.assertNil(list[1].localRadar)
end

function TestLocalRadarNetwork:test_polling_a_lit_local_radar_reads_its_radar_and_cues_crews()
	local iads = makeIads()
	localSensor(iads)
	classify(iads)
	iads._localRadars.records[1].Applied = true
	local seenType, cued = nil, nil
	iads._sensorPollingService.pollSensor = function(_, _, _, _, _, _, detectionType)
		seenType = detectionType
		return { { NetworkId = 9 } }
	end
	iads._trackManager.processReport = function() end
	local original = Medusa.Services.LocalRadarService.onRadarContacts
	Medusa.Services.LocalRadarService.onRadarContacts = function(_, record, reports)
		cued = { record = record, count = #reports }
		return 0
	end

	local ok, err = pcall(iads._pollSensors, iads)
	Medusa.Services.LocalRadarService.onRadarContacts = original

	lu.assertTrue(ok, err)
	lu.assertEquals(seenType, RADAR)
	lu.assertNotNil(cued)
	lu.assertIs(cued.record, iads._localRadars.records[1])
	lu.assertEquals(cued.count, 1)
end

function TestLocalRadarNetwork:test_local_picture_phase_runs_the_local_radars()
	local iads = makeIads()
	localSensor(iads)
	classify(iads)
	local original = Medusa.Services.LocalRadarService.update
	local called = nil
	Medusa.Services.LocalRadarService.update = function(ctx)
		called = ctx
		return 0
	end

	iads:_runLocalPicturePhase()
	Medusa.Services.LocalRadarService.update = original

	lu.assertNotNil(called)
	lu.assertIs(called.localRadars, iads._localRadars)
end

function TestLocalRadarNetwork:test_switch_off_leaves_radar_with_guns_a_sensor_group()
	local iads = makeIads()
	iads._doctrine.LocalCueingRadars = false
	setupGroup({ DOG_EAR, SHILKA }, { "Dog Ear radar", "ZSU-23-4 Shilka" })
	addGroup(iads, 704, "dogear-shilka")

	lu.assertEquals(#iads:getAssetIndex():sensors():getUniqueGroupNames(), 1)
	iads:_onProbingComplete()
	lu.assertEquals(#iads._localRadars.records, 0)
end

function TestLocalRadarNetwork:test_local_picture_phase_runs_observer_reports_with_the_network_picture()
	local iads = makeIads()
	local original = Medusa.Services.ObserverReportService.update
	local called = nil
	Medusa.Services.ObserverReportService.update = function(ctx)
		called = ctx
		return 0
	end

	iads:_runLocalPicturePhase()
	Medusa.Services.ObserverReportService.update = original

	lu.assertNotNil(called)
	lu.assertIs(called.observers, iads._observers)
	lu.assertIs(called.observerStore, iads:getAssetIndex():observers())
	lu.assertEquals(called.maxEngagementRange, iads._maxEngagementRange)
	lu.assertEquals(called.coalitionId, COAL_RED)
end

local function supportedManpad(iads, unitId)
	local b = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 900 + unitId,
		GroupName = "igla-" .. unitId,
		Role = BR.MANPAD,
		ActivationState = AS.STATE_COLD,
		Position = { x = 5000, y = 0, z = 0 },
		TotalAmmoStatus = 1,
		Manpad = {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.ALERT,
			WakeReason = Medusa.Constants.Manpad.WakeReason.NONE,
			AlertCycleCount = 0,
			AudioCueRangeM = 3000,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	b.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = unitId,
			UnitName = "igla-u" .. unitId,
			Roles = { BUR.MANPAD },
			AmmoCount = 1,
		}),
	}
	iads:getAssetIndex():manpads():add(b)
	iads._spatialIndex:syncBattery(b)
	return b
end

function TestLocalRadarNetwork:test_a_destroyed_local_radar_is_dropped_and_no_longer_polled()
	local iads = makeIads()
	iads._probeComplete = true
	localSensor(iads)
	classify(iads)
	iads._localRadars.records[1].Applied = true
	lu.assertEquals(#iads:_buildPollList(), 1)

	iads:_handleUnitDeath(1)
	iads:_runLocalPicturePhase()

	lu.assertEquals(#iads._localRadars.records, 0)
	lu.assertEquals(#iads:_buildPollList(), 0)
end

function TestLocalRadarNetwork:test_a_dead_supported_crew_no_longer_holds_the_radar_up()
	local iads = makeIads()
	iads._probeComplete = true
	localSensor(iads)
	local crew = supportedManpad(iads, 77)
	classify(iads)
	local record = iads._localRadars.records[1]
	lu.assertIs(record.Supported[1], crew)

	iads:_handleUnitDeath(77)
	iads:_runLocalPicturePhase()

	lu.assertEquals(#record.Supported, 0)
end

-- == Probing that finds nothing to probe still completes, and radar groups added later are classified ==

local function probeAtOnce(iads, range)
	iads._probingService.probeAll = function(svc, typePositions, onComplete)
		for typeName in pairs(typePositions) do
			svc._cache[typeName] = { detectionRangeMax = range }
		end
		onComplete()
	end
end

local function withDynamicProbing(fn)
	local cfg = Medusa.Config:get()
	local was = cfg.AllowDynamicProbing
	cfg.AllowDynamicProbing = true
	local ok, err = pcall(fn)
	cfg.AllowDynamicProbing = was
	if not ok then
		error(err, 0)
	end
end

function TestLocalRadarNetwork:test_a_network_with_nothing_to_probe_classifies_a_radar_with_guns_added_later()
	local iads = makeIads()
	iads:_startProbing() -- everything late-activated: nothing to probe at start

	iads._probingService._cache["Dog Ear radar"] = { detectionRangeMax = 23400 }
	setupGroup({ DOG_EAR, SHILKA }, { "Dog Ear radar", "ZSU-23-4 Shilka" })
	addGroup(iads, 710, "dogear-shilka")

	local battery = iads:getAssetIndex():batteries():getByGroupId(710)
	lu.assertNotNil(battery)
	lu.assertEquals(battery.Role, BR.AAA)
	lu.assertEquals(#iads._deferredGroups, 0)
	lu.assertEquals(#iads._localRadars.records, 1)
end

function TestLocalRadarNetwork:test_a_lone_dog_ear_added_later_is_probed_and_becomes_a_local_radar()
	local iads = makeIads()
	iads:_startProbing()
	probeAtOnce(iads, 23400)
	setupGroup({ DOG_EAR }, { "Dog Ear radar" })

	withDynamicProbing(function()
		addGroup(iads, 711, "dogear")
	end)

	lu.assertEquals(#iads._localRadars.records, 1)
	lu.assertEquals(iads._localRadars.records[1].Kind, "SENSOR")
end

function TestLocalRadarNetwork:test_a_dog_ear_with_igla_added_later_is_probed_and_cues_its_teams()
	local iads = makeIads()
	iads:_startProbing()
	probeAtOnce(iads, 23400)
	setupGroup({ DOG_EAR, IGLA, IGLA }, { "Dog Ear radar", "SA-18 Igla manpad", "SA-18 Igla manpad" })

	withDynamicProbing(function()
		addGroup(iads, 712, "dogear-igla")
	end)

	lu.assertEquals(iads:getAssetIndex():manpads():getByGroupId(712).DetectionRangeMax, 23400)
	lu.assertEquals(#iads._localRadars.records, 1)
	lu.assertEquals(iads._localRadars.records[1].Kind, "MANPAD")
end

function TestLocalRadarNetwork:test_observer_looks_run_one_per_tick_with_the_network_picture()
	local iads = makeIads()
	iads._doctrine = { ObserverReports = true }
	local original = Medusa.Services.ObserverReportService.look
	local calls, seen = 0, nil
	Medusa.Services.ObserverReportService.look = function(ctx)
		calls = calls + 1
		seen = ctx
		return 1
	end
	iads:_runObserverLook()
	iads:_runObserverLook()
	Medusa.Services.ObserverReportService.look = original

	lu.assertEquals(calls, 2)
	lu.assertIs(seen.observers, iads._observers)
	lu.assertEquals(seen.coalitionId, COAL_RED)
end

function TestLocalRadarNetwork:test_a_sweep_lights_an_uncovered_radar_and_what_it_finds_keeps_it_up()
	local getTime = GetTime
	local now = 0
	GetTime = function()
		return now
	end
	local ok, err = pcall(function()
		local iads = makeIads()
		iads._localRadars.random = function()
			return 0
		end
		localSensor(iads)
		classify(iads)
		local record = iads._localRadars.records[1]

		now = 180
		iads:_runLocalPicturePhase()
		local polled = false
		for _, entry in ipairs(iads:_buildPollList()) do
			polled = polled or entry.groupName == "dogear"
		end
		lu.assertTrue(polled)

		-- What the sweep's first look reports: a new track, not yet identified.
		local t = Medusa.Entities.Track.new({
			TrackId = "t1",
			NetworkId = "t1",
			Position = { x = 20000, y = 300, z = 0 },
			Velocity = { x = 200, y = 0, z = 0 },
		})
		iads._trackManager:getStore():add(t)
		iads:getAssetIndex():networkedGeoGrid():add("Track", "t1", t.Position)
		now = 191
		iads:_runLocalPicturePhase()
		lu.assertTrue(record.Applied)
		lu.assertEquals(record.Reason, "threat near")
	end)
	GetTime = getTime
	assert(ok, err)
end

-- The poll list is rebuilt every tick (10 Hz) over every battery of the network, so a rebuild that allocates feeds the
-- garbage collector of the shared mission Lua state on every tick.
function TestLocalRadarNetwork:test_poll_list_rebuild_allocates_nothing_once_warm()
	local iads = makeIads()
	iads._doctrine.BatteryTargetDatalink = true
	localSensor(iads)
	for i = 1, 40 do
		localBattery(iads, BR.SR_SAM, "sam-" .. i, i % 2 == 0 and AS.STATE_HOT or AS.STATE_COLD)
	end
	iads:_buildPollList()
	iads:_buildPollList()

	collectgarbage("collect")
	collectgarbage("stop")
	local before = collectgarbage("count")
	local list = iads:_buildPollList()
	local allocatedKb = collectgarbage("count") - before
	collectgarbage("restart")

	lu.assertEquals(#list, 21)
	lu.assertEquals(allocatedKb, 0)
end
