local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Config")
require("core.IadsNetwork")
require("entities.SensorUnit")
require("entities.Battery")

-- == Helpers ==

local function makeIads()
	return Medusa.Core.IadsNetwork:new({
		id = "T",
		coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
		prefix = "iads",
	})
end

local function injectProvider(iads, groups)
	iads._discovery._provider = {
		list = function()
			return groups
		end,
	}
end

local COAL_RED = (coalition and coalition.side and coalition.side.RED) or 1
local origGetUnitDesc

-- == Tests ==

TestIadsNetwork = {}

function TestIadsNetwork:setUp()
	origGetUnitDesc = GetUnitDesc
	GetUnitDesc = function(unit)
		local name = unit and unit.getName and unit:getName() or ""
		if string.find(name, ".gci.", 1, true) or string.find(name, ".ewr.", 1, true) then
			return { attributes = { ["SAM SR"] = true } }
		end
		return { attributes = { ["SAM LL"] = true } }
	end
end

function TestIadsNetwork:tearDown()
	GetUnitDesc = origGetUnitDesc
end

function TestIadsNetwork:test_initialize_registers_barrage_limit_before_start()
	local barrageState = Medusa.Services.AaaService.newBarrageState()
	local iads = Medusa.Core.IadsNetwork:new({
		id = "limit-net",
		coalitionId = COAL_RED,
		prefix = "iads",
		doctrine = { AAA = { MaxBarrageGroups = 7 } },
		aaaBarrageState = barrageState,
	})

	iads:initialize()

	lu.assertEquals(barrageState.limitsByNetwork["limit-net"], 7)
end

function TestIadsNetwork:test_doctrine_switches_evidence_reacquisition_for_its_tracks()
	local stock = Medusa.Core.IadsNetwork:new({
		id = "reacq-off",
		coalitionId = COAL_RED,
		prefix = "iads",
		doctrine = { EvidenceReacquisition = false },
	})
	stock:initialize()
	lu.assertFalse(stock._trackManager._evidenceReacquisition)
	local default = makeIads()
	default:initialize()
	lu.assertTrue(default._trackManager._evidenceReacquisition)
end

function TestIadsNetwork:test_tracksAskTheNetworksPollsHowLongARadarStillCoversThem()
	local iads = makeIads()
	iads:initialize()
	lu.assertIs(iads._trackManager._coverSource, iads._sensorPollingService)
end

-- A SHORAD spawned (or hit) into crew suppression is skipped by point-defense assignment; when it recovers, the links
-- must be made again.
function TestIadsNetwork:test_crew_suppression_recovery_requests_point_defense_assignment()
	local iads = makeIads()
	iads:initialize()
	iads._pdReassignNeeded = false
	local ctx = iads:_updateCrewSuppressionContext(GetTime())
	lu.assertNotNil(ctx.onRecovered)
	ctx.onRecovered({ BatteryId = "b1" })
	lu.assertTrue(iads._pdReassignNeeded)
end

-- A failure in the decoy assessment must not skip HARM response and point defense in the same phase.
function TestIadsNetwork:test_a_decoy_pass_failure_does_not_skip_harm_response_or_point_defence()
	local iads = makeIads()
	iads:initialize()
	local Assess, HRS, PDS =
		Medusa.Services.DecoyAssessmentService, Medusa.Services.HarmResponseService, Medusa.Services.PointDefenseService
	local origAssess, origResponse, origEngage = Assess.assess, HRS.executeResponse, PDS.engageThreats
	local called = {}
	Assess.assess = function()
		error("decoy pass failed")
	end
	HRS.executeResponse = function()
		called.response = true
	end
	PDS.engageThreats = function()
		called.pd = true
	end
	local ctx = {
		trackStore = iads._trackManager:getStore(),
		batteryStore = iads._assetIndex:batteries(),
		geoGrid = iads._assetIndex:networkedGeoGrid(),
		doctrine = iads._doctrine,
		now = GetTime(),
		hpt = Medusa.hpTimer,
		MS = Medusa.Services.MetricsService,
	}
	local ok, err = pcall(iads._phaseHarmAndPD, iads, ctx)
	Assess.assess, HRS.executeResponse, PDS.engageThreats = origAssess, origResponse, origEngage
	lu.assertTrue(ok, tostring(err))
	lu.assertTrue(called.response)
	lu.assertTrue(called.pd)
end

function TestIadsNetwork:test_the_harm_pass_feeds_the_decoy_assessment_every_track_it_visits()
	local iads = makeIads()
	iads:initialize()
	local tm = iads._trackManager
	for i = 1, 6 do
		tm:processReport({
			NetworkId = "c" .. i,
			SourceType = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR,
			Position = { x = 1000 * i, y = 6000, z = 0 },
			Velocity = { x = 0, y = 0, z = -200 },
		}, GetTime())
	end
	local ctx = {
		trackStore = tm:getStore(),
		batteryStore = iads._assetIndex:batteries(),
		geoGrid = iads._assetIndex:networkedGeoGrid(),
		doctrine = iads._doctrine,
		now = GetTime(),
		hpt = Medusa.hpTimer,
		MS = Medusa.Services.MetricsService,
	}
	iads:_phaseHarmAndPD(ctx)
	local tracks = tm:getStore():getAll()
	lu.assertEquals(#tracks, 6)
	for _, t in ipairs(tracks) do
		lu.assertEquals(t.DecoyCheckedAt, GetTime(), t.TrackId)
	end
end

function TestIadsNetwork:test_the_harm_pass_counts_aircraft_tracks_for_the_net_load_not_arms_or_decoys()
	local iads = makeIads()
	iads:initialize()
	local tm = iads._trackManager
	for i = 1, 6 do
		tm:processReport({
			NetworkId = "c" .. i,
			SourceType = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR,
			Position = { x = 1000 * i, y = 6000, z = 0 },
			Velocity = { x = 0, y = 0, z = -200 },
		}, GetTime())
	end
	local tracks = tm:getStore():getAll()
	local ids = { "HOSTILE", "HOSTILE", "BANDIT", "HOSTILE", "HOSTILE", "UNKNOWN" }
	for i, t in ipairs(tracks) do
		t.TrackIdentification = ids[i]
	end
	tracks[4].AssessedAircraftType = Medusa.Constants.AssessedAircraftType.HARM -- an ARM
	tracks[5].DecoyAssessment = { label = "PROBABLE" } -- a probable decoy
	local ctx = {
		trackStore = tm:getStore(),
		batteryStore = iads._assetIndex:batteries(),
		geoGrid = iads._assetIndex:networkedGeoGrid(),
		doctrine = iads._doctrine,
		now = GetTime(),
		hpt = Medusa.hpTimer,
		MS = Medusa.Services.MetricsService,
	}
	iads:_phaseHarmAndPD(ctx)
	lu.assertEquals(iads._aircraftTracks, 3)
	lu.assertEquals(iads._armsInbound, 1)
end

function TestIadsNetwork:test_crew_factors_size_the_net_from_the_networks_sites()
	local iads = makeIads()
	iads:initialize()
	local CF = Medusa.Constants.CrewFactors
	local BR = Medusa.Constants.BatteryRole
	for i = 1, 24 do
		iads:getAssetIndex():batteries():add(Medusa.Entities.Battery.new({
			NetworkId = "T",
			GroupId = 100 + i,
			GroupName = "site-" .. i,
			GroupCategory = Group.Category.GROUND,
			Role = i <= 22 and BR.MR_SAM or BR.AAA,
			Position = { x = i, y = 0, z = 0 },
		}))
	end
	iads:getAssetIndex():sensors():add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 1,
		UnitName = "ewr",
		GroupId = 1,
		GroupName = "ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
		GroupCategory = Group.Category.GROUND,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = 200000,
	}))
	-- not sites: a destroyed SAM battery, an AWACS and a ship's radar group
	iads:getAssetIndex():batteries():add(Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 200,
		GroupName = "site-dead",
		GroupCategory = Group.Category.GROUND,
		Role = BR.MR_SAM,
		Position = { x = 0, y = 0, z = 0 },
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.DESTROYED,
	}))
	local function sensor(id, name, category, airborne)
		iads:getAssetIndex():sensors():add(Medusa.Entities.SensorUnit.new({
			NetworkId = "T",
			UnitId = id,
			UnitName = name,
			GroupId = id,
			GroupName = name,
			SensorType = airborne and Medusa.Constants.SensorType.AWACS or Medusa.Constants.SensorType.EWR,
			GroupCategory = category,
			IsAirborne = airborne,
			Position = { x = 0, y = 0, z = 0 },
			DetectionRangeMax = 200000,
		}))
	end
	sensor(2, "awacs", Group.Category.AIRPLANE, true)
	sensor(3, "frigate", Group.Category.SHIP, false)
	iads._aircraftTracks = 5
	iads:_updateCrewFactors(GetTime())
	local crew = iads._crew
	lu.assertEquals(crew.fullTracks, 25 * CF.LOAD_FULL_TRACKS_PER_SITE) -- 24 groups and one radar site
	lu.assertEquals(crew.fullMissiles, 22)
	lu.assertEquals(crew.fullArms, 11)
	lu.assertAlmostEquals(crew.load, 5 / crew.fullTracks, 1e-9)
end

function TestIadsNetwork:test_a_decoy_launch_records_the_launchers_type()
	-- The network learns "hold breaks guidance" by the launcher's DCS type name.
	local iads = makeIads()
	iads:initialize()
	local DRS = Medusa.Services.DecoyResponseService
	local saved = { DRS.recordLaunch, GetWeaponTarget }
	local flight, ctxSeen
	DRS.recordLaunch = function(ctx, _, f)
		ctxSeen, flight = ctx, f
	end
	GetWeaponTarget = function()
		return nil
	end
	local desc = { category = Weapon.Category.MISSILE, guidance = 4 }
	local ok, err = pcall(iads._recordDecoyLaunch, iads, { GroupName = "sa11" }, {}, desc, 500, {
		UnitTypeName = "SA-11 Buk LN 9A310M1",
	})
	DRS.recordLaunch, GetWeaponTarget = saved[1], saved[2]
	assert(ok, err)
	lu.assertEquals(flight.LauncherType, "SA-11 Buk LN 9A310M1")
	lu.assertEquals(flight.LaunchTime, 500)
	lu.assertIs(ctxSeen.holdBreaksTypes, iads._holdBreaksTypes)
end

function TestIadsNetwork:test_locked_tracks_are_read_from_the_batterys_fire_control_units()
	-- Unit.getRadar's tracked object on tracking radars, TELARs and TLARs, mapped to the network's active track of it.
	local iads = makeIads()
	iads:initialize()
	local store = iads._trackManager:getStore()
	for id, state in pairs({ TRK77 = "ACTIVE", TRK79 = "STALE" }) do
		store:add(Medusa.Entities.Track.new({
			TrackId = id,
			NetworkId = id,
			Position = { x = 0, y = 0, z = 0 },
			Velocity = { x = 0, y = 0, z = 0 },
			LifecycleState = state,
		}))
	end
	local saved = { GetUnit, GetUnitRadar }
	local asked = {}
	GetUnit = function(name)
		asked[#asked + 1] = name
		return { name = name }
	end
	local locks = { tr = { id_ = 77 }, telar = { id_ = 78 }, tlar = { id_ = 79 }, dead = { id_ = 77 } }
	GetUnitRadar = function(unit)
		return true, locks[unit.name]
	end
	iads._trackManager._byNetworkId[77] = "TRK77"
	iads._trackManager._byNetworkId[79] = "TRK79"
	local BUR = Medusa.Constants.BatteryUnitRole
	local battery = {
		Units = {
			{ UnitName = "sr", Roles = { BUR.SEARCH_RADAR } },
			{ UnitName = "tr", Roles = { BUR.TRACK_RADAR } },
			{ UnitName = "telar", Roles = { BUR.TELAR } },
			{ UnitName = "tlar", Roles = { BUR.TLAR } }, -- locked on a track no longer active
			{ UnitName = "dead", Roles = { BUR.TRACK_RADAR }, OperationalStatus = "DESTROYED" },
		},
	}
	local out = { "stale", "stale", "stale" }
	local ok, n = pcall(iads._lockedTracksOf, iads, battery, out)
	GetUnit, GetUnitRadar = saved[1], saved[2]
	assert(ok, n)
	lu.assertEquals(n, 1)
	lu.assertEquals(out, { "TRK77" })
	lu.assertEquals(asked, { "tr", "telar", "tlar" })
end

function TestIadsNetwork:test_networks_running_together_offset_their_phases()
	local a = makeIads()
	local b = Medusa.Core.IadsNetwork:new({ id = "T2", coalitionId = 1, prefix = "iads2" })
	a:start()
	b:start()
	lu.assertEquals(b._phaseOffset - a._phaseOffset, 1)
	b:stop()
	a:stop()
	local c = Medusa.Core.IadsNetwork:new({ id = "T3", coalitionId = 1, prefix = "iads3" })
	c:start()
	lu.assertEquals(c._phaseOffset, a._phaseOffset)
	c:stop()
end

function TestIadsNetwork:test_initialize_and_tick_wires_discovery_to_hierarchy()
	local iads = makeIads()
	lu.assertTrue(iads:initialize())
	lu.assertTrue(iads:start())

	injectProvider(iads, {
		{
			groupId = 42,
			groupName = "iads.1bn.gci.alpha",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()
	local node = iads:getHierarchy():getNode({ "1bn" })
	lu.assertNotNil(node)
	lu.assertTrue(node.groupsSet and node.groupsSet:contains(42))
end

function TestIadsNetwork:test_discovery_creates_battery_for_non_role_group()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 100,
			groupName = "iads.alpha.sa6",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	local store = iads:getAssetIndex():batteries()
	lu.assertEquals(store:count(), 1)
	local battery = store:getByGroupId(100)
	lu.assertNotNil(battery)
	lu.assertEquals(battery.GroupName, "iads.alpha.sa6")
	lu.assertEquals(battery.NetworkId, "T")
end

function TestIadsNetwork:test_discovery_routes_gci_to_sensors()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 200,
			groupName = "iads.alpha.gci.site1",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	local sensorNames = iads:getAssetIndex():sensors():getUniqueGroupNames()
	lu.assertEquals(#sensorNames, 1)
	lu.assertEquals(sensorNames[1], "iads.alpha.gci.site1")
end

function TestIadsNetwork:test_discovery_routes_ewr_to_sensors()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 201,
			groupName = "iads.alpha.ewr.bigbird",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	local sensorNames = iads:getAssetIndex():sensors():getUniqueGroupNames()
	lu.assertEquals(#sensorNames, 1)
	lu.assertEquals(sensorNames[1], "iads.alpha.ewr.bigbird")
end

function TestIadsNetwork:test_battery_datalink_excludes_independent_aaa()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true }
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 202,
		GroupName = "iads.alpha.aaa.site1",
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	})
	iads:getAssetIndex():batteries():add(battery)

	lu.assertEquals(iads:_buildPollList(), {})
end

function TestIadsNetwork:test_battery_datalink_polls_warm_radar_directed_aaa()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true }
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 203,
		GroupName = "iads.alpha.aaa.radar",
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_WARM,
		DetectionRangeMax = 20000,
	})
	battery.Units = {
		{ Roles = { Medusa.Constants.BatteryUnitRole.AAA } },
		{ Roles = { Medusa.Constants.BatteryUnitRole.SEARCH_RADAR } },
	}
	iads:getAssetIndex():batteries():add(battery)

	local pollList = iads:_buildPollList()

	lu.assertEquals(#pollList, 1)
	lu.assertEquals(pollList[1].groupName, battery.GroupName)
	lu.assertEquals(pollList[1].sourceType, Medusa.Constants.TrackSource.SAM_BATTERY)
end

function TestIadsNetwork:test_poll_list_classifies_track_origin_sources()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true }
	local sensors = iads:getAssetIndex():sensors()
	local batteries = iads:getAssetIndex():batteries()
	local sensorType = Medusa.Constants.SensorType

	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 1,
		UnitName = "awacs",
		GroupId = 1,
		GroupName = "awacs-group",
		SensorType = sensorType.AWACS,
		IsAirborne = true,
		GroupCategory = Group.Category.AIRPLANE,
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 2,
		UnitName = "ewr",
		GroupId = 2,
		GroupName = "ewr-group",
		SensorType = sensorType.EWR,
		GroupCategory = Group.Category.GROUND,
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 3,
		UnitName = "ship",
		GroupId = 3,
		GroupName = "ship-group",
		SensorType = sensorType.EWR,
		GroupCategory = Group.Category.SHIP,
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 4,
		UnitName = "fighter",
		GroupId = 4,
		GroupName = "fighter-group",
		SensorType = sensorType.GCI,
		IsAirborne = true,
		GroupCategory = Group.Category.AIRPLANE,
	}))
	batteries:add(Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 5,
		GroupName = "sam-group",
		GroupCategory = Group.Category.GROUND,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	}))
	batteries:add(Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 6,
		GroupName = "sam-ship-group",
		GroupCategory = Group.Category.SHIP,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	}))

	local byName = {}
	for _, source in ipairs(iads:_buildPollList()) do
		byName[source.groupName] = source.sourceType
	end

	local trackSource = Medusa.Constants.TrackSource
	lu.assertEquals(byName["awacs-group"], trackSource.AWACS)
	lu.assertEquals(byName["ewr-group"], trackSource.EARLY_WARNING_RADAR)
	lu.assertEquals(byName["ship-group"], trackSource.SHIPBORNE_RADAR)
	lu.assertEquals(byName["fighter-group"], trackSource.AIRBORNE_DATALINK)
	lu.assertEquals(byName["sam-group"], trackSource.SAM_BATTERY)
	lu.assertEquals(byName["sam-ship-group"], trackSource.SHIPBORNE_RADAR)
end

local function scanRateTestNetwork(doctrine)
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = doctrine
	local sensors = iads:getAssetIndex():sensors()
	local batteries = iads:getAssetIndex():batteries()
	local ST = Medusa.Constants.SensorType
	local AS = Medusa.Constants.ActivationState
	local function sensor(id, name, sensorType, category, airborne)
		sensors:add(Medusa.Entities.SensorUnit.new({
			NetworkId = "T",
			UnitId = id,
			UnitName = name,
			GroupId = id,
			GroupName = name,
			SensorType = sensorType,
			IsAirborne = airborne,
			GroupCategory = category,
		}))
	end
	sensor(1, "ewr", ST.EWR, Group.Category.GROUND)
	sensor(2, "gci", ST.GCI, Group.Category.GROUND)
	sensor(3, "awacs", ST.AWACS, Group.Category.AIRPLANE, true)
	local function battery(id, name, state, harmCapable)
		batteries:add(Medusa.Entities.Battery.new({
			NetworkId = "T",
			GroupId = id,
			GroupName = name,
			GroupCategory = Group.Category.GROUND,
			ActivationState = state,
			HarmCapableUnitCount = harmCapable,
		}))
	end
	battery(10, "sa10-hot", AS.STATE_HOT, 2)
	battery(11, "sa6-hot", AS.STATE_HOT, 0)
	local rates = {}
	for _, source in ipairs(iads:_buildPollList()) do
		rates[source.groupName] = source.scanRateSec
	end
	return rates
end

function TestIadsNetwork:test_poll_list_sets_scan_rate_by_radar_kind()
	local rates = scanRateTestNetwork({ BatteryTargetDatalink = true, PerTrackScanUpdateRate = 5 })

	lu.assertEquals(rates["ewr"], 10)
	lu.assertEquals(rates["gci"], 10)
	lu.assertNil(rates["awacs"]) -- airborne radars keep the doctrine PerTrackScanUpdateRate
	lu.assertEquals(rates["sa10-hot"], 2) -- engagement radar on, multi-target (HARM-capable) system
	lu.assertEquals(rates["sa6-hot"], 5) -- single-target tracker: search-radar rate
end

function TestIadsNetwork:test_explicit_per_track_rate_applies_to_every_radar_kind()
	local rates =
		scanRateTestNetwork(Medusa.Entities.Doctrine.new({ BatteryTargetDatalink = true, PerTrackScanUpdateRate = 3 }))

	lu.assertEquals(rates["ewr"], 3)
	lu.assertEquals(rates["sa10-hot"], 3)
	lu.assertEquals(rates["sa6-hot"], 3)
end

function TestIadsNetwork:test_poll_list_reuses_its_entries()
	local iads = makeIads()
	iads:initialize()
	local first = iads:_buildPollList()
	local second = iads:_buildPollList()
	lu.assertIs(first, second)
end

function TestIadsNetwork:test_doctrine_overrides_scan_rates_within_limits()
	local rates = scanRateTestNetwork({
		BatteryTargetDatalink = true,
		PerTrackScanUpdateRate = 5,
		ScanUpdateRateSec = { EWR = 12, SAM_SEARCH = "fast", SAM_TRACK = 0.2 },
	})

	lu.assertEquals(rates["ewr"], 12)
	lu.assertEquals(rates["sa6-hot"], 5)
	lu.assertEquals(rates["sa10-hot"], 1)
end

function TestIadsNetwork:test_discovery_routes_hq_to_c2nodes()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 300,
			groupName = "iads.alpha.hq.cmd",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	lu.assertEquals(iads:getAssetIndex():sensors():count(), 0)
	lu.assertEquals(iads:getAssetIndex():c2Nodes():count(), 1)
end

function TestIadsNetwork:test_first_tick_initializes_batteries_cold()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 400,
			groupName = "iads.alpha.sa10",
			coalitionId = COAL_RED,
			category = "ground",
		},
		{
			groupId = 401,
			groupName = "iads.alpha.sa11",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	local store = iads:getAssetIndex():batteries()
	lu.assertEquals(store:count(), 2)
	local all = store:getAll()
	-- Batteries stay INITIALIZING after tick 1 (doctrine states deferred 60s for fast erect)
	for i = 1, #all do
		lu.assertEquals(all[i].ActivationState, Medusa.Constants.ActivationState.INITIALIZING)
	end
end

local function addDynamicBattery(iads, groupId, groupName)
	iads._discovery._listener.onAdded({
		groupId = groupId,
		groupName = groupName,
		coalitionId = COAL_RED,
		category = "ground",
		parsed = Medusa.Services.GroupNameParser:parse(groupName, "iads"),
	})
end

function TestIadsNetwork:test_dynamic_battery_after_erect_requests_point_defense_assignment()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	iads._erectComplete = true
	iads._pdReassignNeeded = false

	addDynamicBattery(iads, 600, "iads.alpha.sa15")

	lu.assertNotNil(iads:getAssetIndex():batteries():getByGroupId(600))
	lu.assertTrue(iads._pdReassignNeeded)
end

function TestIadsNetwork:test_battery_added_before_erect_leaves_assignment_to_init()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	iads._erectComplete = false
	iads._pdReassignNeeded = false

	addDynamicBattery(iads, 601, "iads.alpha.sa15")

	lu.assertNotNil(iads:getAssetIndex():batteries():getByGroupId(601))
	lu.assertFalse(iads._pdReassignNeeded == true)
end

function TestIadsNetwork:test_mixed_groups_route_correctly()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{ groupId = 500, groupName = "iads.alpha.sa6", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 501, groupName = "iads.alpha.gci.site1", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 502, groupName = "iads.alpha.hq.cmd", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 503, groupName = "iads.alpha.sa11", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 504, groupName = "iads.alpha.ewr.bigbird", coalitionId = COAL_RED, category = "ground" },
	})

	iads._tickCounter = 0
	iads:tick()

	-- 2 batteries (sa6, sa11), 2 sensor groups (gci, ewr), 1 HQ -> c2node
	lu.assertEquals(iads:getAssetIndex():batteries():count(), 2)
	lu.assertEquals(#iads:getAssetIndex():sensors():getUniqueGroupNames(), 2)
	lu.assertEquals(iads:getAssetIndex():c2Nodes():count(), 1)
end

-- == Death Event Tests ==

local function localDefenseUnit(unitId, role)
	return Medusa.Entities.Battery.newUnit({
		UnitId = unitId,
		UnitName = "local-defense-" .. tostring(unitId),
		Roles = { role },
		AmmoCount = 10,
		AmmoTypes = {
			{
				Count = 10,
				RangeMax = 5000,
			},
		},
	})
end

function TestIadsNetwork:test_death_removes_sensor()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local sensorStore = iads:getAssetIndex():sensors()
	sensorStore:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 50,
		UnitName = "ewr-1",
		GroupId = 600,
		GroupName = "iads.alpha.ewr.site1",
		SensorType = "EWR",
	}))
	lu.assertEquals(sensorStore:count(), 1)

	iads._deathQueue:enqueue({
		_unitId = 50,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(sensorStore:count(), 0)
end

function TestIadsNetwork:test_death_removes_battery_unit()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 700,
		GroupName = "iads.alpha.sa10",
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({ UnitId = 60 }),
		Medusa.Entities.Battery.newUnit({ UnitId = 61 }),
	}
	batteryStore:add(battery)
	lu.assertEquals(batteryStore:count(), 1)
	lu.assertEquals(#battery.Units, 2)

	iads._deathQueue:enqueue({
		_unitId = 60,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(batteryStore:count(), 1)
	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.Units[1].UnitId, 61)
end

function TestIadsNetwork:test_destroyed_aaa_member_suppresses_surviving_battery()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 750,
		GroupName = "iads.alpha.aaa.site1",
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		GroupDiameterM = 0,
	})
	battery.Units = {
		localDefenseUnit(65, Medusa.Constants.BatteryUnitRole.AAA),
		localDefenseUnit(66, Medusa.Constants.BatteryUnitRole.AAA),
	}
	batteryStore:add(battery)

	iads._deathQueue:enqueue({ _unitId = 65 })
	iads:_processDeathEvents(2)

	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.ACTIVE)
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(battery.CrewSuppressionCause, Medusa.Constants.CrewSuppressionCause.DAMAGE)
	lu.assertNotNil(battery.CrewSuppressionTimerId)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestIadsNetwork:test_destroyed_manpad_member_suppresses_surviving_group()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 760,
		GroupName = "iads.alpha.manpad.team1",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		GroupDiameterM = 0,
		Manpad = {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.HOT,
			WakeReason = Medusa.Constants.Manpad.WakeReason.IADS,
			AlertCycleCount = 0,
			AudioCueRangeM = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	battery.Units = {
		localDefenseUnit(67, Medusa.Constants.BatteryUnitRole.MANPAD),
		localDefenseUnit(68, Medusa.Constants.BatteryUnitRole.MANPAD),
	}
	iads:getAssetIndex():manpads():add(battery)

	iads._deathQueue:enqueue({ _unitId = 67 })
	iads:_processDeathEvents(2)

	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.ACTIVE)
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(battery.CrewSuppressionCause, Medusa.Constants.CrewSuppressionCause.DAMAGE)
	lu.assertNotNil(battery.CrewSuppressionTimerId)
	lu.assertEquals(battery.Manpad.SleepWakeState, Medusa.Constants.Manpad.SleepWakeState.ALERT)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestIadsNetwork:test_death_removes_battery_when_all_dead()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 800,
		GroupName = "iads.alpha.aaa.last",
		Role = Medusa.Constants.BatteryRole.AAA,
		GroupDiameterM = 0,
	})
	battery.Units = {
		localDefenseUnit(70, Medusa.Constants.BatteryUnitRole.AAA),
	}
	batteryStore:add(battery)

	iads._deathQueue:enqueue({
		_unitId = 70,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(batteryStore:count(), 0)
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.CLEAR)
	lu.assertNil(battery.CrewSuppressionTimerId)
end

function TestIadsNetwork:test_death_ignores_unknown_unit()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local sensorStore = iads:getAssetIndex():sensors()
	local batteryStore = iads:getAssetIndex():batteries()

	iads._deathQueue:enqueue({
		_unitId = 999,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(sensorStore:count(), 0)
	lu.assertEquals(batteryStore:count(), 0)
end

TestIadsSuppressionEvents = {}

function TestIadsSuppressionEvents:setUp()
	self.originalBus = HarnessWorldEventBus
	self.originalGetTime = GetTime
	self.originalInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	self.messages = {}
	env.info = function(message)
		self.messages[#self.messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	self.now = 1000
	GetTime = function()
		return self.now
	end
	HarnessWorldEventBus = CreateHarnessWorldEventBus()
end

function TestIadsSuppressionEvents:tearDown()
	HarnessWorldEventBus:dispose()
	HarnessWorldEventBus = self.originalBus
	GetTime = self.originalGetTime
	env.info = self.originalInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
end

local function hitEvent(unitId, coalitionId)
	return {
		initiator = {},
		target = {
			getCoalition = function()
				return coalitionId or COAL_RED
			end,
			getID = function()
				return unitId
			end,
		},
	}
end

function TestIadsSuppressionEvents:test_hit_boundary_rejects_missing_or_invalid_fields()
	local iads = makeIads()
	iads:initialize()

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_HIT })
	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_HIT, initiator = {} })
	HarnessWorldEventBus:publish(hitEvent(10, coalition.side.BLUE))
	HarnessWorldEventBus:publish({
		id = world.event.S_EVENT_HIT,
		initiator = {},
		target = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})

	lu.assertTrue(iads._hitQueue:isEmpty())
end

function TestIadsSuppressionEvents:test_hit_on_scenery_or_weapon_isDropped_withoutAskingTheHarness()
	local iads = makeIads()
	iads:initialize()
	local origGetCategory, origGetCoalition = Object.getCategory, GetUnitCoalition
	local harnessCalls = 0
	Object.getCategory = function(obj)
		return obj.category
	end
	GetUnitCoalition = function()
		harnessCalls = harnessCalls + 1
		return COAL_RED
	end
	local tree = hitEvent(10, COAL_RED)
	tree.target.category = Object.Category.SCENERY
	local missile = hitEvent(11, COAL_RED)
	missile.target.category = Object.Category.WEAPON
	HarnessWorldEventBus:publish(tree)
	HarnessWorldEventBus:publish(missile)
	Object.getCategory, GetUnitCoalition = origGetCategory, origGetCoalition
	lu.assertTrue(iads._hitQueue:isEmpty())
	lu.assertEquals(harnessCalls, 0)
end

function TestIadsSuppressionEvents:test_a_shot_stamps_its_batterys_launch_time_when_the_event_arrives()
	local iads = makeIads()
	iads:initialize()
	local battery = {}
	iads._assetIndex.batteryRepository = function()
		return {
			getByUnitId = function(_, uid)
				return uid == 42 and battery or nil
			end,
		}
	end
	local origGetUnitID = GetUnitID
	GetUnitID = function(u)
		return u.uid
	end
	local function shot(uid, coal)
		return {
			id = world.event.S_EVENT_SHOT,
			initiator = {
				uid = uid,
				getCoalition = function()
					return coal
				end,
			},
		}
	end
	self.now = 1234.5
	HarnessWorldEventBus:publish(shot(42, COAL_RED))
	self.now = 1300
	HarnessWorldEventBus:publish(shot(43, COAL_RED))
	HarnessWorldEventBus:publish(shot(42, coalition.side.BLUE))
	GetUnitID = origGetUnitID
	iads._assetIndex.batteryRepository = nil
	lu.assertEquals(battery.LastLaunchAt, 1234.5, "stamped at the event, by its own battery only")
	lu.assertEquals(iads._shotQueue:size(), 2)
end

function TestIadsSuppressionEvents:test_a_gun_shell_leaves_its_batterys_launch_time_alone()
	-- A gun-missile unit's cannon burst must not hold off the decoy response's writes as a missile launch does.
	local iads = makeIads()
	iads:initialize()
	local battery = {}
	iads._assetIndex.batteryRepository = function()
		return {
			getByUnitId = function()
				return battery
			end,
		}
	end
	local origGetUnitID = GetUnitID
	GetUnitID = function(u)
		return u.uid
	end
	local function shot(typeName, desc)
		return {
			id = world.event.S_EVENT_SHOT,
			initiator = {
				uid = 42,
				getCoalition = function()
					return COAL_RED
				end,
			},
			weapon = {
				getTypeName = function()
					return typeName
				end,
				getDesc = function()
					return desc
				end,
			},
		}
	end
	self.now = 1000
	HarnessWorldEventBus:publish(shot("SA9M311", { category = Weapon.Category.MISSILE }))
	self.now = 1100
	HarnessWorldEventBus:publish(shot("weapons.shells.2A38_30_HE"))
	HarnessWorldEventBus:publish(shot("GSh_30", { category = Weapon.Category.SHELL }))
	GetUnitID = origGetUnitID
	iads._assetIndex.batteryRepository = nil
	lu.assertEquals(battery.LastLaunchAt, 1000)
	lu.assertEquals(iads._shotQueue:size(), 3)
end

TestIadsNetworkEventObjects = {}

function TestIadsNetworkEventObjects:test_isUnitObject_readsTheObjectCategory()
	local orig = Object.getCategory
	Object.getCategory = function(obj)
		return obj.category
	end
	local isUnit = Medusa.Core.IadsNetwork._isUnitObject
	lu.assertTrue(isUnit({ category = Object.Category.UNIT }))
	lu.assertFalse(isUnit({ category = Object.Category.WEAPON }))
	lu.assertFalse(isUnit({ category = Object.Category.SCENERY }))
	Object.getCategory = orig
	lu.assertTrue(isUnit({})) -- category unreadable: treated as a unit
end

function TestIadsSuppressionEvents:test_hit_boundary_translates_to_bounded_unit_record()
	local iads = makeIads()
	iads:initialize()
	local capacity = Medusa.Constants.CrewSuppression.HIT_EVENT_QUEUE_CAPACITY

	for unitId = 1, capacity + 1 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end

	lu.assertEquals(iads._hitQueue:size(), capacity)
	lu.assertEquals(iads._hitQueue:pop().TargetUnitId, 2)
end

function TestIadsSuppressionEvents:test_debug_trace_reports_hit_and_death_processing_paths()
	local iads = makeIads()
	iads:initialize()
	self.messages = {}

	local event = hitEvent(10)
	event.id = world.event.S_EVENT_HIT
	HarnessWorldEventBus:publish(event)
	iads:_processHitEvents(1)
	iads._deathQueue:enqueue({ _unitId = 10 })
	iads:_processDeathEvents(1)

	local output = table.concat(self.messages, "\n")
	lu.assertStrContains(output, "crew suppression HIT queued: targetUnitId=10")
	lu.assertStrContains(output, "processing crew suppression HIT: targetUnitId=10")
	lu.assertStrContains(output, "damage evaluation rejected: unitId=10 is not managed")
	lu.assertStrContains(output, "crew suppression HIT processed: targetUnitId=10 applied=false")
	lu.assertStrContains(output, "processing death event: unitId=10")
	lu.assertStrContains(output, "death event ignored: unitId=10 is not managed")
end

function TestIadsSuppressionEvents:test_hit_processing_obeys_budget_and_expiry()
	local iads = makeIads()
	iads:initialize()

	for unitId = 1, 3 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end
	lu.assertEquals(iads:_processHitEvents(2), 2)
	lu.assertEquals(iads._hitQueue:size(), 1)

	self.now = self.now + Medusa.Constants.CrewSuppression.HIT_EVENT_MAX_AGE_SEC + 1
	lu.assertEquals(iads:_processHitEvents(2), 1)
	lu.assertTrue(iads._hitQueue:isEmpty())
end

function TestIadsSuppressionEvents:test_stop_and_restart_replace_hit_subscription()
	local iads = makeIads()
	iads:initialize()
	lu.assertEquals(#HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT], 1)
	for unitId = 1, 2 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end
	lu.assertEquals(iads:_processHitEvents(1), 1)
	lu.assertStrContains(
		Medusa.Services.MetricsService.serialize(),
		'medusa_crew_suppression_event_queue_depth{network="T"} 1'
	)

	iads:stop()
	lu.assertIsNil(HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT])
	lu.assertTrue(iads._hitQueue:isEmpty())

	iads:start()
	iads:start()
	lu.assertEquals(#HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT], 1)
	iads:stop()
end

function TestIadsSuppressionEvents:test_disabled_doctrine_does_not_subscribe_to_hit_events()
	local iads = Medusa.Core.IadsNetwork:new({
		id = "T",
		coalitionId = COAL_RED,
		prefix = "iads",
		doctrine = { CrewSuppression = { Enabled = false } },
	})

	iads:initialize()

	lu.assertIsNil(HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT])
end

-- == Alert-zone losses: a site counts once ==

TestIadsNetworkSiteLoss = {}

function TestIadsNetworkSiteLoss:setUp()
	self._orig = Medusa.Services.AlertZoneService
	self.reports = {}
	Medusa.Services.AlertZoneService = {
		reportLoss = function(side, pos)
			self.reports[#self.reports + 1] = { side, pos.x }
		end,
	}
	self.net = { _coalitionId = 1 }
end

function TestIadsNetworkSiteLoss:tearDown()
	Medusa.Services.AlertZoneService = self._orig
end

local function unit(role, x)
	return { Roles = { role }, Position = { x = x, y = 0, z = 0 } }
end

function TestIadsNetworkSiteLoss:test_firstRadarKilled_countsTheSiteOnce()
	local R = Medusa.Constants.BatteryUnitRole
	local tr, sr, ln = unit(R.TRACK_RADAR, 1), unit(R.SEARCH_RADAR, 2), unit(R.LAUNCHER, 3)
	local site = { Units = { tr, sr, ln } }
	Medusa.Core.IadsNetwork._reportSiteLoss(self.net, site, ln) -- a launcher: not yet a loss
	Medusa.Core.IadsNetwork._reportSiteLoss(self.net, site, tr)
	Medusa.Core.IadsNetwork._reportSiteLoss(self.net, site, sr)
	lu.assertEquals(self.reports, { { 1, 1 } })
end

function TestIadsNetworkSiteLoss:test_groupWithoutRadar_countsWhenItsLastUnitDies()
	local R = Medusa.Constants.BatteryUnitRole
	local a, b = unit(R.AAA, 1), unit(R.AAA, 2)
	local guns = { Units = { a, b } }
	Medusa.Core.IadsNetwork._reportSiteLoss(self.net, guns, a)
	guns.Units = { b }
	Medusa.Core.IadsNetwork._reportSiteLoss(self.net, guns, b)
	lu.assertEquals(self.reports, { { 1, 2 } })
end

function TestIadsNetworkSiteLoss:test_siteDestroyedWithItsRadarStillStanding_counts()
	local R = Medusa.Constants.BatteryUnitRole
	local ln, sr = unit(R.LAUNCHER, 1), unit(R.SEARCH_RADAR, 2)
	Medusa.Core.IadsNetwork._reportSiteLoss(self.net, { Units = { ln, sr } }, ln, true)
	lu.assertEquals(self.reports, { { 1, 1 } })
end

function TestIadsNetworkSiteLoss:test_aGroupCountsOnce_whateverItsUnitsAreFiledAs()
	local R = Medusa.Constants.BatteryUnitRole
	-- A group whose radars are filed as sensors and whose other units as a battery is one site.
	local site = { GroupName = "site-1", Units = { unit(R.TRACK_RADAR, 1), unit(R.LAUNCHER, 2) } }
	Medusa.Core.IadsNetwork._reportSensorLoss(self.net, { GroupName = "site-1", Position = { x = 5, y = 0, z = 0 } })
	Medusa.Core.IadsNetwork._reportSiteLoss(self.net, site, site.Units[1])
	-- An early-warning site of two radars counts once.
	Medusa.Core.IadsNetwork._reportSensorLoss(self.net, { GroupName = "ewr-2", Position = { x = 6, y = 0, z = 0 } })
	Medusa.Core.IadsNetwork._reportSensorLoss(self.net, { GroupName = "ewr-2", Position = { x = 7, y = 0, z = 0 } })
	lu.assertEquals(self.reports, { { 1, 5 }, { 1, 6 } })
end

function TestIadsNetwork:test_poll_list_carries_each_group_sensor_context()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true, PerTrackScanUpdateRate = 5 }
	local AS = Medusa.Constants.ActivationState
	local ewrPos = { x = 1, y = 2, z = 3 }
	iads:getAssetIndex():sensors():add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 1,
		UnitName = "ewr",
		GroupId = 1,
		GroupName = "ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
		GroupCategory = Group.Category.GROUND,
		Position = ewrPos,
		DetectionRangeMax = 200000,
	}))
	local samPos = { x = 4, y = 5, z = 6 }
	iads:getAssetIndex():batteries():add(Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 10,
		GroupName = "sa10",
		GroupCategory = Group.Category.GROUND,
		ActivationState = AS.STATE_HOT,
		HarmCapableUnitCount = 2,
		Position = samPos,
		DetectionRangeMax = 107000,
	}))
	local buk = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 11,
		GroupName = "buk",
		GroupCategory = Group.Category.GROUND,
		ActivationState = AS.STATE_HOT,
		Position = samPos,
	})
	iads:getAssetIndex():batteries():add(buk)

	local byName = {}
	for _, source in ipairs(iads:_buildPollList()) do
		byName[source.groupName] = source.sensorCtx
	end
	local ratio = Medusa.Constants.ContactEvidence.REACH_RATIO
	lu.assertIs(byName.ewr.Position, ewrPos)
	lu.assertAlmostEquals(byName.ewr.Reach, 200000 / ratio, 1e-6)
	lu.assertEquals(byName.ewr.Kind, "EWR")
	lu.assertIs(byName.sa10.Position, samPos)
	lu.assertAlmostEquals(byName.sa10.Reach, 107000 / ratio, 1e-6)
	lu.assertEquals(byName.sa10.Kind, "SAM_TRACK")
	lu.assertNil(byName.buk.Reach) -- not probed yet: no size looks, sight recognition still works
	lu.assertEquals(byName.buk.Kind, "SAM_SEARCH")
end

function TestIadsNetwork:test_poll_passes_each_group_sensor_context_to_the_report_boundary()
	local iads = makeIads()
	iads:initialize()
	iads:getAssetIndex():sensors():add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 1,
		UnitName = "ewr",
		GroupId = 1,
		GroupName = "ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
		GroupCategory = Group.Category.GROUND,
		Position = { x = 1, y = 2, z = 3 },
		DetectionRangeMax = 200000,
	}))
	local seen = {}
	iads._sensorPollingService.pollSensor = function(_, name, _, _, _, sensorCtx)
		seen[name] = sensorCtx
		return {}
	end
	iads:_pollSensors()
	lu.assertNotNil(seen.ewr)
	lu.assertEquals(seen.ewr.Kind, "EWR")
	lu.assertAlmostEquals(seen.ewr.Reach, 200000 / Medusa.Constants.ContactEvidence.REACH_RATIO, 1e-6)
end

-- == Debrief: site lost, first detection; crew factors: losses and launches ==

TestIadsNetworkDebrief = {}

function TestIadsNetworkDebrief:setUp()
	self._orig = Medusa.Services.AlertZoneService
	Medusa.Services.AlertZoneService = { reportLoss = function() end }
	self._info = env.info
	self.lines = {}
	env.info = function(msg)
		self.lines[#self.lines + 1] = msg
	end
end

function TestIadsNetworkDebrief:tearDown()
	Medusa.Services.AlertZoneService = self._orig
	env.info = self._info
end

function TestIadsNetworkDebrief:find(fragment)
	local n = 0
	for i = 1, #self.lines do
		if string.find(self.lines[i], fragment, 1, true) then
			n = n + 1
		end
	end
	return n
end

function TestIadsNetworkDebrief:test_a_site_lost_is_a_debrief_line_and_makes_a_surprised_network_engaged()
	local doctrine = { CrewFactors = true, Readiness = "SURPRISED", TrainingMode = true }
	local net = {
		_id = "red",
		_coalitionId = 1,
		_doctrine = doctrine,
		_crew = Medusa.Services.CrewFactorsService.newState(doctrine),
	}
	local R = Medusa.Constants.BatteryUnitRole
	local sr = { Roles = { R.SEARCH_RADAR }, Position = { x = 1, y = 0, z = 0 } }
	local random = math.random
	math.random = function()
		return 0.99 -- a late word, were the delay drawn: training must take the middle of the window
	end
	local ok, err = pcall(
		Medusa.Core.IadsNetwork._reportSiteLoss,
		net,
		{ GroupName = "sam-1", Role = "SR_SAM", Units = { sr } },
		sr
	)
	math.random = random
	assert(ok, err)
	lu.assertEquals(self:find("|net=red|ev=SITE_LOST|site=sam-1|kind=SR_SAM"), 1)
	-- ENGAGED once word of the loss arrives (training: the middle of the window), not at once
	lu.assertEquals(net._crew.readiness, "SURPRISED")
	local CF = Medusa.Constants.CrewFactors
	local counts = { hostile = 0, tracks = 0, pending = 0, arms = 0 }
	local due = GetTime() + (CF.WORD_OF_LOSS_MIN_SEC + CF.WORD_OF_LOSS_MAX_SEC) / 2
	Medusa.Services.CrewFactorsService.update(net._crew, due, "red", counts, true)
	lu.assertEquals(net._crew.readiness, "ENGAGED")
	lu.assertEquals(self:find("ev=READINESS|from=SURPRISED|to=ENGAGED|why=first_loss"), 1)
end

function TestIadsNetworkDebrief:test_a_site_lost_outside_training_draws_the_word_of_loss_delay()
	local doctrine = { CrewFactors = true, Readiness = "SURPRISED", TrainingMode = false }
	local net = {
		_id = "red",
		_coalitionId = 1,
		_doctrine = doctrine,
		_crew = Medusa.Services.CrewFactorsService.newState(doctrine, function()
			return 0.25
		end),
	}
	local R = Medusa.Constants.BatteryUnitRole
	local sr = { Roles = { R.SEARCH_RADAR }, Position = { x = 1, y = 0, z = 0 } }
	Medusa.Core.IadsNetwork._reportSiteLoss(net, { GroupName = "sam-1", Role = "SR_SAM", Units = { sr } }, sr)
	local CF = Medusa.Constants.CrewFactors
	-- a quarter of the way through the window, not its middle
	local due = GetTime() + CF.WORD_OF_LOSS_MIN_SEC + 0.25 * (CF.WORD_OF_LOSS_MAX_SEC - CF.WORD_OF_LOSS_MIN_SEC)
	lu.assertAlmostEquals(net._crew.engageDueAt, due, 1e-9)
	local counts = { hostile = 0, tracks = 0, pending = 0, arms = 0 }
	Medusa.Services.CrewFactorsService.update(net._crew, due - 1, "red", counts, false)
	lu.assertEquals(net._crew.readiness, "SURPRISED")
	Medusa.Services.CrewFactorsService.update(net._crew, due, "red", counts, false)
	lu.assertEquals(net._crew.readiness, "ENGAGED")
end

function TestIadsNetworkDebrief:test_crew_factors_off_keeps_readiness_on_a_loss()
	local doctrine = { CrewFactors = false, Readiness = "SURPRISED" }
	local net = {
		_id = "red",
		_coalitionId = 1,
		_doctrine = doctrine,
		_crew = Medusa.Services.CrewFactorsService.newState(doctrine),
	}
	local R = Medusa.Constants.BatteryUnitRole
	local sr = { Roles = { R.SEARCH_RADAR }, Position = { x = 1, y = 0, z = 0 } }
	Medusa.Core.IadsNetwork._reportSiteLoss(net, { GroupName = "sam-1", Units = { sr } }, sr)
	lu.assertEquals(net._crew.readiness, "SURPRISED")
	lu.assertEquals(self:find("ev=READINESS"), 0)
end

function TestIadsNetworkDebrief:test_first_detection_at_track_creation_then_identified_once_per_track()
	local net = { _id = "red" }
	local track = {
		DisplayTrackId = "EW-0042",
		TrackIdentification = "UNKNOWN",
		Position = { x = 30000, y = 200, z = 40000 },
		FirstDetectionTime = GetTime() - 25,
	}
	Medusa.Core.IadsNetwork._noteFirstSensor(net, track, {
		groupName = "ewr-north",
		sourceType = "EARLY_WARNING_RADAR",
		sensorCtx = { Position = { x = 0, y = 0, z = 0 }, Kind = "EWR" },
	}, { Position = { x = 30000, y = 200, z = 40000 } })
	lu.assertEquals(
		self:find(
			"|net=red|ev=FIRST_DETECTION|track=EW-0042|id=UNKNOWN|sensor=ewr-north|kind=EWR|range_km=50.0"
				.. "|alt_m=200|alt_band=low"
		),
		1
	)
	Medusa.Core.IadsNetwork._onTrackIdentified(net, track, "BOGEY", "BANDIT")
	Medusa.Core.IadsNetwork._onTrackIdentified(net, track, "BANDIT", "HOSTILE")
	lu.assertEquals(
		self:find(
			"|net=red|ev=IDENTIFIED|track=EW-0042|id=BANDIT|from_id=BOGEY|sensor=ewr-north|kind=EWR|range_km=50.0"
				.. "|alt_m=200|alt_band=low|held_s=25"
		),
		1
	)
	lu.assertEquals(self:find("ev=FIRST_DETECTION"), 1)
	lu.assertEquals(self:find("ev=IDENTIFIED"), 1)
end

function TestIadsNetworkDebrief:test_a_friendly_track_is_no_first_detection()
	local net = { _id = "red" }
	local track = { DisplayTrackId = "EW-0044", TrackIdentification = "FRIENDLY", Position = { x = 0, y = 500, z = 0 } }
	Medusa.Core.IadsNetwork._noteFirstSensor(
		net,
		track,
		{ groupName = "ewr-north", sourceType = "EARLY_WARNING_RADAR" },
		{
			Position = { x = 0, y = 500, z = 0 },
		}
	)
	lu.assertEquals(self:find("FIRST_DETECTION"), 0)
	lu.assertEquals(track.FirstSeenBy, "ewr-north")
end

function TestIadsNetworkDebrief:test_a_recycled_display_id_still_gets_its_first_detection()
	-- Display ids are recycled once a track is gone for good: a later track on the same id is a new detection.
	local net = { _id = "red" }
	local source = { groupName = "ewr-north", sourceType = "EARLY_WARNING_RADAR" }
	local first = { DisplayTrackId = "EW-0045", TrackIdentification = "UNKNOWN", Position = { x = 0, y = 500, z = 0 } }
	Medusa.Core.IadsNetwork._noteFirstSensor(net, first, source, { Position = first.Position })
	local later = { DisplayTrackId = "EW-0045", TrackIdentification = "UNKNOWN", Position = { x = 0, y = 500, z = 0 } }
	Medusa.Core.IadsNetwork._noteFirstSensor(net, later, source, { Position = later.Position })
	lu.assertEquals(self:find("ev=FIRST_DETECTION"), 2)
end

function TestIadsNetworkDebrief:test_a_reacquired_track_already_bandit_is_not_newly_identified()
	local net = { _id = "red" }
	local track = { DisplayTrackId = "EW-0043", Position = { x = 0, y = 5000, z = 0 } }
	Medusa.Core.IadsNetwork._onTrackIdentified(net, track, "BANDIT", "HOSTILE")
	Medusa.Core.IadsNetwork._onTrackIdentified(net, track, "HOSTILE", "BANDIT")
	lu.assertEquals(self:find("IDENTIFIED"), 0)
end

function TestIadsNetworkDebrief:test_track_store_counts_identifications_and_reports_changes()
	local store = Medusa.Services.TrackStore:new()
	local changes = {}
	store.onIdentified = function(_, from, to)
		changes[#changes + 1] = from .. ">" .. to
	end
	local track = Medusa.Entities.Track.new({
		NetworkId = 9,
		Position = { x = 0, y = 0, z = 0 },
		Velocity = { x = 0, y = 0, z = 0 },
	})
	store:add(track)
	lu.assertEquals(store:countByIdentification("UNKNOWN"), 1)
	store:updateIdentification(track.TrackId, "HOSTILE")
	lu.assertEquals(store:countByIdentification("UNKNOWN"), 0)
	lu.assertEquals(store:countByIdentification("HOSTILE"), 1)
	store:remove(track.TrackId)
	lu.assertEquals(store:countByIdentification("HOSTILE"), 0)
	lu.assertEquals(changes, { "UNKNOWN>HOSTILE" })
end

function TestIadsNetworkDebrief:test_crew_factors_off_gives_the_observers_no_crew_state()
	local stub = function()
		return {}
	end
	local function net(doctrine)
		return {
			_localCtx = {},
			_doctrine = doctrine,
			_crew = Medusa.Services.CrewFactorsService.newState(doctrine),
			_assetIndex = {
				sensors = stub,
				batteries = stub,
				manpads = stub,
				observers = stub,
				networkedGeoGrid = stub,
				localGeoGrid = stub,
			},
			_trackManager = { getStore = stub },
			_id = "red",
		}
	end
	local on = net({ CrewFactors = true })
	local off = net({ CrewFactors = false })
	lu.assertIs(Medusa.Core.IadsNetwork._localPictureCtx(on).crew, on._crew)
	lu.assertNil(Medusa.Core.IadsNetwork._localPictureCtx(off).crew)
end

function TestIadsNetwork:test_no_listening_station_service_is_loaded()
	lu.assertNil(Medusa.Services.EsmService)
	lu.assertNil(Medusa.Constants.Esm)
end
