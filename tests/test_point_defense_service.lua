local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("entities.Entities")
require("entities.Battery")
require("entities.Track")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.TrackStore")
require("services.BatteryActivationService")
require("services.SpatialQuery")
require("services.PointDefenseService")

local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BR = Medusa.Constants.BatteryRole
local BUR = Medusa.Constants.BatteryUnitRole
local LS = Medusa.Constants.TrackLifecycleState
local PDS = Medusa.Services.PointDefenseService

local ulidCounter = 0
local groupIdCounter = 0

local function setupMocks()
	ulidCounter = 0
	groupIdCounter = 0
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()

	GetTime = function()
		return 1000
	end
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	GetGroupController = function(name)
		return { name = name }
	end
	SetControllerOnOff = function() end
	ControllerSetROE = function() end
	ControllerSetAlarmState = function() end
	Distance2D = function(a, b)
		local dx = a.x - b.x
		local dz = a.z - b.z
		return math.sqrt(dx * dx + dz * dz)
	end
end

local function makeBattery(overrides)
	groupIdCounter = groupIdCounter + 1
	local data = {
		NetworkId = "net-1",
		GroupId = groupIdCounter,
		GroupName = string.format("SAM-%d", groupIdCounter),
		OperationalStatus = BOS.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		Role = BR.GENERIC_SAM,
		StateChangeHoldDownSec = 0,
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	return Medusa.Entities.Battery.new(data)
end

local function makeRadarDirectedAaa(overrides)
	local aaaOverrides = {}
	for key, value in pairs(overrides or {}) do
		aaaOverrides[key] = value
	end
	aaaOverrides.Role = BR.AAA
	aaaOverrides.DetectionRangeMax = aaaOverrides.DetectionRangeMax or 10000
	local aaa = makeBattery(aaaOverrides)
	aaa.Units = {
		Medusa.Entities.Battery.newUnit({ UnitId = 1, Roles = { BUR.AAA } }),
		Medusa.Entities.Battery.newUnit({ UnitId = 2, Roles = { BUR.SEARCH_RADAR } }),
	}
	return aaa
end

local function makeTrack(overrides)
	local data = {
		NetworkId = "net-1",
		Position = { x = 1000, y = 500, z = 2000 },
		Velocity = { x = 100, y = 0, z = 50 },
		LifecycleState = LS.ACTIVE,
		TrackIdentification = "HOSTILE",
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	return Medusa.Entities.Track.new(data)
end

local function makeCtx(fields)
	return {
		trackStore = fields.trackStore,
		batteryStore = fields.batteryStore,
		geoGrid = fields.geoGrid,
		now = fields.now or 1000,
		pointDefenseTies = fields.pointDefenseTies,
	}
end

-- == TestSetAssignment ==

TestSetAssignment = {}

function TestSetAssignment:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
end

function TestSetAssignment:test_links_batteries_correctly()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	local hva = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM })
	self.batteryStore:add(pd)
	self.batteryStore:add(hva)

	local ok = PDS.setAssignment("PD-1", "HVA-1", self.batteryStore)
	lu.assertTrue(ok)
	lu.assertTrue(pd.IsPointDefense)
	lu.assertEquals(pd.PointDefenseTargetId, "HVA-1")
	lu.assertEquals(hva.PointDefenseProviderId, "PD-1")
end

function TestSetAssignment:test_rejects_self_assignment()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	self.batteryStore:add(pd)

	local ok = PDS.setAssignment("PD-1", "PD-1", self.batteryStore)
	lu.assertFalse(ok)
end

function TestSetAssignment:test_rejects_missing_battery()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	self.batteryStore:add(pd)

	local ok = PDS.setAssignment("PD-1", "NONEXISTENT", self.batteryStore)
	lu.assertFalse(ok)
end

function TestSetAssignment:test_crew_suppressed_provider_is_not_viable()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM, TotalAmmoStatus = 4 })
	pd.CrewSuppressionState = Medusa.Constants.CrewSuppressionState.SUPPRESSED
	pd.CrewSuppressionUntil = 1100
	local target = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM })
	self.batteryStore:add(pd)
	self.batteryStore:add(target)

	lu.assertFalse(PDS.isProviderViable(pd))
	lu.assertFalse(PDS.setAssignment(pd.BatteryId, target.BatteryId, self.batteryStore))
end

-- == TestClearAssignment ==

TestClearAssignment = {}

function TestClearAssignment:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
end

function TestClearAssignment:test_clears_both_sides()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	local hva = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM })
	self.batteryStore:add(pd)
	self.batteryStore:add(hva)

	PDS.setAssignment("PD-1", "HVA-1", self.batteryStore)
	PDS.clearAssignment("PD-1", self.batteryStore)

	lu.assertFalse(pd.IsPointDefense)
	lu.assertNil(pd.PointDefenseTargetId)
	lu.assertNil(hva.PointDefenseProviderId)
end

function TestClearAssignment:test_handles_missing_target_gracefully()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	self.batteryStore:add(pd)
	pd.IsPointDefense = true
	pd.PointDefenseTargetId = "REMOVED-TARGET"

	local ok = PDS.clearAssignment("PD-1", self.batteryStore)
	lu.assertTrue(ok)
	lu.assertFalse(pd.IsPointDefense)
	lu.assertNil(pd.PointDefenseTargetId)
end

-- == TestAutoAssignShorad ==

TestAutoAssignShorad = {}

function TestAutoAssignShorad:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = GeoGrid(10000, { "Battery", "Track" })
end

function TestAutoAssignShorad:test_assigns_sr_sam_to_nearby_lr_sam()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 5000, y = 0, z = 5000 },
	})
	self.batteryStore:add(sr)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 1)
	lu.assertTrue(sr.IsPointDefense)
	lu.assertEquals(sr.PointDefenseTargetId, "LR-1")
	lu.assertEquals(lr.PointDefenseProviderId, "SR-1")
end

function TestAutoAssignShorad:test_assigns_sr_sam_to_nearby_vlr_sam()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
	})
	local vlr = makeBattery({
		BatteryId = "VLR-1",
		Role = BR.VLR_SAM,
		Position = { x = 2000, y = 0, z = 2000 },
	})
	self.batteryStore:add(sr)
	self.batteryStore:add(vlr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)
	self.geoGrid:add("Battery", vlr.BatteryId, vlr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 1)
	lu.assertEquals(sr.PointDefenseTargetId, "VLR-1")
	lu.assertEquals(vlr.PointDefenseProviderId, "SR-1")
end

function TestAutoAssignShorad:test_skips_independent_aaa()
	local aaa = makeBattery({
		BatteryId = "AAA-1",
		Role = BR.AAA,
		Position = { x = 1000, y = 0, z = 1000 },
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 5000, y = 0, z = 5000 },
	})
	self.batteryStore:add(aaa)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", aaa.BatteryId, aaa.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))

	lu.assertEquals(count, 0)
	lu.assertFalse(aaa.IsPointDefense)
end

function TestAutoAssignShorad:test_assigns_radar_directed_aaa()
	local aaa = makeRadarDirectedAaa({
		BatteryId = "AAA-1",
		Position = { x = 1000, y = 0, z = 1000 },
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 5000, y = 0, z = 5000 },
	})
	self.batteryStore:add(aaa)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", aaa.BatteryId, aaa.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))

	lu.assertEquals(count, 1)
	lu.assertTrue(aaa.IsPointDefense)
end

function TestAutoAssignShorad:test_releases_aaa_point_defense_after_radar_loss()
	local aaa = makeRadarDirectedAaa({
		BatteryId = "AAA-1",
		TotalAmmoStatus = 10,
	})
	local lr = makeBattery({ BatteryId = "LR-1", Role = BR.LR_SAM, TotalAmmoStatus = 10 })
	self.batteryStore:add(aaa)
	self.batteryStore:add(lr)
	PDS.setAssignment(aaa.BatteryId, lr.BatteryId, self.batteryStore)
	table.remove(aaa.Units, 2)

	local released = PDS.releaseOrphanedDefenders(makeCtx({ batteryStore = self.batteryStore }))

	lu.assertEquals(released, 1)
	lu.assertFalse(aaa.IsPointDefense)
	lu.assertNil(lr.PointDefenseProviderId)
end

function TestAutoAssignShorad:test_ignores_distant_shorad()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 100000, y = 0, z = 100000 },
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	self.batteryStore:add(sr)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 0)
end

function TestAutoAssignShorad:test_skips_already_assigned_shorad()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		IsPointDefense = true,
		PointDefenseTargetId = "SOME-OTHER",
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 5000, y = 0, z = 5000 },
	})
	self.batteryStore:add(sr)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 0)
end

function TestAutoAssignShorad:test_skips_hva_with_existing_provider()
	local sr1 = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
	})
	local sr2 = makeBattery({
		BatteryId = "SR-2",
		Role = BR.SR_SAM,
		Position = { x = 2000, y = 0, z = 2000 },
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 5000, y = 0, z = 5000 },
		PointDefenseProviderId = "SR-EXISTING",
	})
	self.batteryStore:add(sr1)
	self.batteryStore:add(sr2)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", sr1.BatteryId, sr1.Position)
	self.geoGrid:add("Battery", sr2.BatteryId, sr2.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 0)
end

TestActivateForHarm = {}

function TestActivateForHarm:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = GeoGrid(10000, { "Battery", "Track" })
	self.doctrine = {
		DefendPk = 0,
		MaxEngageRangePct = { [BR.SR_SAM] = 25 },
	}
end

function TestActivateForHarm:test_assigned_provider_uses_full_engagement_range()
	local protected = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local provider = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 0, y = 0, z = 10000 },
		EngagementRangeMax = 20000,
		TotalAmmoStatus = 8,
		ActivationState = AS.STATE_WARM,
	})
	self.batteryStore:add(protected)
	self.batteryStore:add(provider)
	PDS.setAssignment(provider.BatteryId, protected.BatteryId, self.batteryStore)
	self.geoGrid:add("Battery", protected.BatteryId, protected.Position)
	self.geoGrid:add("Battery", provider.BatteryId, provider.Position)

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 10000, y = 0, z = 0 },
		Velocity = { x = -300, y = 0, z = 0 },
	})

	local count = PDS.activateForHarm(harm, self.geoGrid, self.batteryStore, 1000, self.doctrine)

	lu.assertEquals(count, 1)
	lu.assertEquals(provider.CurrentTargetTrackId, harm.TrackId)
	lu.assertEquals(provider.ActivationState, AS.STATE_HOT)
end

function TestActivateForHarm:test_pd_beside_vlr_sam_goes_hot_for_harm_aimed_at_it()
	local vlr = makeBattery({
		BatteryId = "VLR-1",
		Role = BR.VLR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local gunPd = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 0, y = 0, z = 1000 },
		EngagementRangeMax = 8000,
		TotalAmmoStatus = 8,
		ActivationState = AS.STATE_WARM,
	})
	self.batteryStore:add(vlr)
	self.batteryStore:add(gunPd)
	self.geoGrid:add("Battery", vlr.BatteryId, vlr.Position)
	self.geoGrid:add("Battery", gunPd.BatteryId, gunPd.Position)
	PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 10000, y = 0, z = 0 },
		Velocity = { x = -600, y = 0, z = 0 },
	})

	local count = PDS.activateForHarm(harm, self.geoGrid, self.batteryStore, 1000, self.doctrine)

	lu.assertEquals(count, 1)
	lu.assertEquals(gunPd.CurrentTargetTrackId, harm.TrackId)
	lu.assertEquals(gunPd.ActivationState, AS.STATE_HOT)
end

function TestActivateForHarm:test_opportunistic_provider_uses_full_engagement_range()
	local provider = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 20000,
		TotalAmmoStatus = 8,
		ActivationState = AS.STATE_WARM,
		IsPointDefense = true,
	})
	self.batteryStore:add(provider)
	self.geoGrid:add("Battery", provider.BatteryId, provider.Position)

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 10000, y = 0, z = 10000 },
		Velocity = { x = -300, y = 0, z = 0 },
	})

	local count = PDS.activateForHarm(harm, self.geoGrid, self.batteryStore, 1000, self.doctrine)

	lu.assertEquals(count, 1)
	lu.assertEquals(provider.CurrentTargetTrackId, harm.TrackId)
	lu.assertEquals(provider.ActivationState, AS.STATE_HOT)
end

-- == TestEngageThreats ==

TestEngageThreats = {}

function TestEngageThreats:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.geoGrid = GeoGrid(10000, { "Battery", "Track" })
end

function TestEngageThreats:test_pd_goes_hot_for_harm_near_protected_battery()
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
		TotalAmmoStatus = 8,
	})
	-- Manually set activation state to bypass holddown
	sr.ActivationState = AS.STATE_WARM

	self.batteryStore:add(lr)
	self.batteryStore:add(sr)
	PDS.setAssignment("SR-1", "LR-1", self.batteryStore)

	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 5000, y = 3000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	self.trackStore:add(harm)
	self.geoGrid:add("Track", harm.TrackId, harm.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 1)
	lu.assertEquals(sr.CurrentTargetTrackId, "HARM-1")
	lu.assertEquals(sr.ActivationState, AS.STATE_HOT)
end

function TestEngageThreats:test_skips_non_harm_tracks()
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
	})
	sr.ActivationState = AS.STATE_WARM

	self.batteryStore:add(lr)
	self.batteryStore:add(sr)
	PDS.setAssignment("SR-1", "LR-1", self.batteryStore)

	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local track = makeTrack({
		TrackId = "FW-1",
		AssessedAircraftType = "FIXED_WING",
		Position = { x = 5000, y = 3000, z = 0 },
	})
	self.trackStore:add(track)
	self.geoGrid:add("Track", track.TrackId, track.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
	lu.assertNil(sr.CurrentTargetTrackId)
end

function TestEngageThreats:test_skips_destroyed_pd_battery()
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
		OperationalStatus = BOS.ACTIVE,
	})
	sr.ActivationState = AS.STATE_WARM

	self.batteryStore:add(lr)
	self.batteryStore:add(sr)
	PDS.setAssignment("SR-1", "LR-1", self.batteryStore)

	-- Destroy the PD provider after assignment
	sr.OperationalStatus = BOS.DESTROYED

	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 5000, y = 3000, z = 0 },
	})
	self.trackStore:add(harm)
	self.geoGrid:add("Track", harm.TrackId, harm.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

function TestEngageThreats:test_skips_already_engaged_pd()
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
		CurrentTargetTrackId = "EXISTING-TARGET",
	})
	sr.ActivationState = AS.STATE_HOT

	self.batteryStore:add(lr)
	self.batteryStore:add(sr)
	PDS.setAssignment("SR-1", "LR-1", self.batteryStore)

	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 5000, y = 3000, z = 0 },
	})
	self.trackStore:add(harm)
	self.geoGrid:add("Track", harm.TrackId, harm.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
	lu.assertEquals(sr.CurrentTargetTrackId, "EXISTING-TARGET")
end

function TestEngageThreats:test_returns_zero_with_no_protected_batteries()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
	})
	sr.ActivationState = AS.STATE_WARM

	self.batteryStore:add(sr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

-- == [BKE] Several providers per protected battery ==

TestSeveralProviders = {}

function TestSeveralProviders:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
end

function TestSeveralProviders:test_two_providers_both_linked()
	local pd1 = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	local pd2 = makeBattery({ BatteryId = "PD-2", Role = BR.SR_SAM })
	local hva = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM })
	self.batteryStore:add(pd1)
	self.batteryStore:add(pd2)
	self.batteryStore:add(hva)

	lu.assertTrue(PDS.setAssignment("PD-1", "HVA-1", self.batteryStore))
	lu.assertTrue(PDS.setAssignment("PD-2", "HVA-1", self.batteryStore))
	lu.assertEquals(hva.PointDefenseProviderIds, { "PD-1", "PD-2" })
	lu.assertEquals(hva.PointDefenseProviderId, "PD-1")
	lu.assertEquals(pd2.PointDefenseTargetId, "HVA-1")
end

function TestSeveralProviders:test_clearing_one_keeps_the_other()
	local pd1 = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	local pd2 = makeBattery({ BatteryId = "PD-2", Role = BR.SR_SAM })
	local hva = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM })
	self.batteryStore:add(pd1)
	self.batteryStore:add(pd2)
	self.batteryStore:add(hva)
	PDS.setAssignment("PD-1", "HVA-1", self.batteryStore)
	PDS.setAssignment("PD-2", "HVA-1", self.batteryStore)

	PDS.clearAssignment("PD-1", self.batteryStore)
	lu.assertEquals(hva.PointDefenseProviderIds, { "PD-2" })
	lu.assertEquals(hva.PointDefenseProviderId, "PD-2")
	lu.assertTrue(pd2.IsPointDefense)

	PDS.clearAssignment("PD-2", self.batteryStore)
	lu.assertNil(hva.PointDefenseProviderId)
	lu.assertEquals(#hva.PointDefenseProviderIds, 0)
end

function TestSeveralProviders:test_reassigning_a_provider_unlinks_its_old_target()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	local a = makeBattery({ BatteryId = "HVA-A", Role = BR.LR_SAM })
	local b = makeBattery({ BatteryId = "HVA-B", Role = BR.MR_SAM })
	self.batteryStore:add(pd)
	self.batteryStore:add(a)
	self.batteryStore:add(b)
	PDS.setAssignment("PD-1", "HVA-A", self.batteryStore)

	lu.assertTrue(PDS.setAssignment("PD-1", "HVA-B", self.batteryStore))
	lu.assertNil(a.PointDefenseProviderId)
	lu.assertEquals(b.PointDefenseProviderId, "PD-1")
	lu.assertEquals(pd.PointDefenseTargetId, "HVA-B")
end

function TestSeveralProviders:test_providers_of_reads_a_lone_provider_id()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	local hva = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM, PointDefenseProviderId = "PD-1" })
	self.batteryStore:add(pd)
	self.batteryStore:add(hva)

	local out = PDS.providersOf(hva, self.batteryStore, {})
	lu.assertEquals(#out, 1)
	lu.assertIs(out[1], pd)
end

function TestSeveralProviders:test_both_providers_engage_two_harms()
	local trackStore = Medusa.Services.TrackStore:new()
	local geoGrid = GeoGrid(10000, { "Battery", "Track" })
	local lr = makeBattery({ BatteryId = "LR-1", Role = BR.LR_SAM, Position = { x = 0, y = 0, z = 0 } })
	local pd1 = makeBattery({
		BatteryId = "PD-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 0 },
		EngagementRangeMax = 20000,
		TotalAmmoStatus = 8,
		ActivationState = AS.STATE_WARM,
	})
	local pd2 = makeBattery({
		BatteryId = "PD-2",
		Role = BR.SR_SAM,
		Position = { x = -1000, y = 0, z = 0 },
		EngagementRangeMax = 20000,
		TotalAmmoStatus = 8,
		ActivationState = AS.STATE_WARM,
	})
	for _, b in ipairs({ lr, pd1, pd2 }) do
		self.batteryStore:add(b)
		geoGrid:add("Battery", b.BatteryId, b.Position)
	end
	PDS.setAssignment("PD-1", "LR-1", self.batteryStore)
	PDS.setAssignment("PD-2", "LR-1", self.batteryStore)
	for i, x in ipairs({ 5000, -5000 }) do
		local harm = makeTrack({
			TrackId = "HARM-" .. i,
			AssessedAircraftType = "HARM",
			Position = { x = x, y = 3000, z = 0 },
			Velocity = { x = -x / 20, y = -50, z = 0 },
		})
		trackStore:add(harm)
		geoGrid:add("Track", harm.TrackId, harm.Position)
	end

	local count =
		PDS.engageThreats(makeCtx({ trackStore = trackStore, batteryStore = self.batteryStore, geoGrid = geoGrid }))
	lu.assertEquals(count, 2)
	lu.assertEquals(pd1.CurrentTargetTrackId, "HARM-1")
	lu.assertEquals(pd2.CurrentTargetTrackId, "HARM-2")
end

function TestSeveralProviders:test_harm_activates_every_provider()
	local geoGrid = GeoGrid(10000, { "Battery", "Track" })
	local lr = makeBattery({ BatteryId = "LR-1", Role = BR.LR_SAM, Position = { x = 0, y = 0, z = 0 } })
	local pd1 = makeBattery({
		BatteryId = "PD-1",
		Role = BR.SR_SAM,
		Position = { x = 0, y = 0, z = 1000 },
		EngagementRangeMax = 12000,
		TotalAmmoStatus = 8,
		ActivationState = AS.STATE_WARM,
	})
	local pd2 = makeRadarDirectedAaa({
		BatteryId = "PD-2",
		Position = { x = 0, y = 0, z = -1000 },
		EngagementRangeMax = 4000,
		TotalAmmoStatus = 8,
		ActivationState = AS.STATE_WARM,
	})
	for _, b in ipairs({ lr, pd1, pd2 }) do
		self.batteryStore:add(b)
		geoGrid:add("Battery", b.BatteryId, b.Position)
	end
	PDS.setAssignment("PD-1", "LR-1", self.batteryStore)
	PDS.setAssignment("PD-2", "LR-1", self.batteryStore)
	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		-- Beyond the 15 km search radius of the opportunistic pass: only the assignment can wake the providers.
		Position = { x = 20000, y = 0, z = 0 },
		Velocity = { x = -300, y = 0, z = 0 },
	})

	local count = PDS.activateForHarm(harm, geoGrid, self.batteryStore, 1000, { DefendPk = 0 })
	lu.assertEquals(count, 2)
	lu.assertEquals(pd1.ActivationState, AS.STATE_HOT)
	lu.assertEquals(pd2.ActivationState, AS.STATE_HOT)
end

-- == [BKE] Point defense tied to a battery by the mission maker ==

TestPointDefenseTies = {}

function TestPointDefenseTies:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = GeoGrid(10000, { "Battery", "Track" })
end

function TestPointDefenseTies:add(id, name, role, x, extra)
	local data = { BatteryId = id, GroupName = name, Role = role, Position = { x = x, y = 0, z = 0 } }
	for k, v in pairs(extra or {}) do
		data[k] = v
	end
	local b = makeBattery(data)
	self.batteryStore:add(b)
	self.geoGrid:add("Battery", b.BatteryId, b.Position)
	return b
end

function TestPointDefenseTies:assign(ties)
	return PDS.autoAssignShorad(
		makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid, pointDefenseTies = ties })
	)
end

function TestPointDefenseTies:test_tie_wins_over_nearest()
	local pd = self:add("PD-1", "iads.pd tor", BR.SR_SAM, 0)
	local near = self:add("SA2", "iads.sa2", BR.MR_SAM, 1000)
	local tied = self:add("SA10", "iads.sa10", BR.LR_SAM, 8000)

	self:assign({ ["iads.pd tor"] = "iads.sa10" })
	lu.assertEquals(pd.PointDefenseTargetId, "SA10")
	lu.assertEquals(tied.PointDefenseProviderId, "PD-1")
	lu.assertNil(near.PointDefenseProviderId)
end

function TestPointDefenseTies:test_tie_replaces_an_automatic_assignment()
	local pd = self:add("PD-1", "pd", BR.SR_SAM, 0)
	local near = self:add("SA2", "sa2", BR.MR_SAM, 1000)
	local tied = self:add("SA10", "sa10", BR.LR_SAM, 8000, { OperationalStatus = BOS.INOPERATIVE })

	-- The tied battery is not up yet: the PD defends the nearest battery meanwhile.
	self:assign({ pd = "sa10" })
	lu.assertEquals(pd.PointDefenseTargetId, "SA2")

	tied.OperationalStatus = BOS.ACTIVE
	self:assign({ pd = "sa10" })
	lu.assertEquals(pd.PointDefenseTargetId, "SA10")
	lu.assertNil(near.PointDefenseProviderId)
	lu.assertEquals(tied.PointDefenseProviderId, "PD-1")
end

function TestPointDefenseTies:test_two_tied_providers_and_automatic_goes_elsewhere()
	local pd1 = self:add("PD-1", "pd1", BR.SR_SAM, 0, { Position = { x = 0, y = 0, z = 500 } })
	local pd2 = self:add("PD-2", "pd2", BR.SR_SAM, 0, { Position = { x = 0, y = 0, z = -500 } })
	local free = self:add("PD-3", "pd3", BR.SR_SAM, 200)
	local sa10 = self:add("SA10", "sa10", BR.LR_SAM, 0)
	local sa11 = self:add("SA11", "sa11", BR.MR_SAM, 6000)

	self:assign({ pd1 = "sa10", pd2 = "sa10" })
	lu.assertItemsEquals(sa10.PointDefenseProviderIds, { "PD-1", "PD-2" })
	lu.assertEquals(free.PointDefenseTargetId, "SA11")
	lu.assertEquals(sa11.PointDefenseProviderId, "PD-3")
	lu.assertTrue(pd1.IsPointDefense and pd2.IsPointDefense)
end

function TestPointDefenseTies:test_bad_ties_fall_back_to_nearest()
	local pd = self:add("PD-1", "pd", BR.SR_SAM, 0)
	local near = self:add("SA2", "sa2", BR.MR_SAM, 1000)
	self:add("FAR", "far", BR.LR_SAM, 40000)
	self:add("GUNS", "guns", BR.AAA, 2000)

	for _, target in ipairs({ "no such group", "far", "guns" }) do
		PDS.clearAssignment("PD-1", self.batteryStore)
		self:assign({ pd = target })
		lu.assertEquals(pd.PointDefenseTargetId, "SA2", target)
	end
	lu.assertEquals(near.PointDefenseProviderId, "PD-1")
end

function TestPointDefenseTies:test_tie_from_a_battery_that_cannot_be_point_defence_is_ignored()
	local lr = self:add("LR-2", "lr2", BR.LR_SAM, 0)
	local sa10 = self:add("SA10", "sa10", BR.LR_SAM, 1000)

	self:assign({ lr2 = "sa10" })
	lu.assertFalse(lr.IsPointDefense)
	lu.assertNil(sa10.PointDefenseProviderId)
end

function TestSeveralProviders:test_removed_provider_is_pruned_and_replaced()
	local geoGrid = GeoGrid(10000, { "Battery", "Track" })
	local hva = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM, Position = { x = 0, y = 0, z = 0 } })
	local dead = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM, Position = { x = 500, y = 0, z = 0 } })
	local spare = makeBattery({ BatteryId = "PD-2", Role = BR.SR_SAM, Position = { x = 900, y = 0, z = 0 } })
	for _, b in ipairs({ hva, dead }) do
		self.batteryStore:add(b)
		geoGrid:add("Battery", b.BatteryId, b.Position)
	end
	PDS.setAssignment("PD-1", "HVA-1", self.batteryStore)
	-- The provider is destroyed: the network removes it from the store without unlinking it.
	self.batteryStore:remove("PD-1")
	self.batteryStore:add(spare)
	geoGrid:add("Battery", spare.BatteryId, spare.Position)

	local ctx = makeCtx({ batteryStore = self.batteryStore, geoGrid = geoGrid })
	lu.assertEquals(PDS.releaseOrphanedDefenders(ctx), 1)
	lu.assertNil(hva.PointDefenseProviderId)
	PDS.autoAssignShorad(ctx)
	lu.assertEquals(hva.PointDefenseProviderId, "PD-2")
end

function TestPointDefenseTies:test_tie_applies_to_an_engagement_impaired_battery()
	local pd = self:add("PD-1", "pd", BR.SR_SAM, 0)
	local tied = self:add("SA10", "sa10", BR.LR_SAM, 3000, { OperationalStatus = BOS.ENGAGEMENT_IMPAIRED })

	self:assign({ pd = "sa10" })
	lu.assertEquals(pd.PointDefenseTargetId, "SA10")
	lu.assertEquals(tied.PointDefenseProviderId, "PD-1")
end
