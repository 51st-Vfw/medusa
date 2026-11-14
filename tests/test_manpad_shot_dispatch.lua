local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("services.Services")
require("services.stores.BatteryStore")
require("services.AssetIndex")
require("services.ManpadService")
require("services.MetricsService")
require("services.BatteryActivationService")
require("core.IadsNetwork")
local ManpadTest = require("manpad_test_support")

-- ============================================================
-- Shared mock infrastructure
-- ============================================================

local _origGetTime
local _origScheduleOnce
local _origCancelSchedule
local _mockTime

local function installMocks()
	_mockTime = 1000
	_origGetTime = GetTime
	_origScheduleOnce = ScheduleOnce
	_origCancelSchedule = CancelSchedule

	GetTime = function()
		return _mockTime
	end
	ScheduleOnce = function(fn, args, delay)
		return "mock-timer"
	end
	CancelSchedule = function(id)
		return true
	end
end

local function restoreMocks()
	GetTime = _origGetTime
	ScheduleOnce = _origScheduleOnce
	CancelSchedule = _origCancelSchedule
end

-- ============================================================
-- Battery / MANPAD builders
-- ============================================================

local _seq = 0
local function nextSeq()
	_seq = _seq + 1
	return _seq
end

local function makeManpadBattery(overrides)
	local id = nextSeq()
	local bat = {
		BatteryId = string.format("mpbat-%d", id),
		GroupId = id * 100,
		GroupName = string.format("manpad-group-%d", id),
		NetworkId = "test-net",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Units = {},
		MissileInFlightUntil = nil,
		ShotsFired = 0,
		LastShotTime = nil,
		TotalAmmoStatus = 2,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		AmmoDepletedBehavior = Medusa.Constants.BatteryOperationalStatus.REARMING,
		Manpad = {
			SleepWakeState = "ASLEEP",
			WakeReason = "NONE",
			WakeTimerId = nil,
			AlertCycleCount = 0,
			LastAlertedTime = nil,
			AudioCueRangeM = 3000,
			HotUntil = nil,
			CooldownUntil = nil,
			AlertStartTime = nil,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	}
	return ManpadTest.applyManpadOverrides(bat, overrides)
end

local function makeRegularBattery(overrides)
	local id = nextSeq()
	local bat = Medusa.Entities.Battery.new({
		NetworkId = "test-net",
		GroupId = id * 100,
		GroupName = string.format("sa6-group-%d", id),
	})
	bat.Units = {}
	if overrides then
		for k, v in pairs(overrides) do
			bat[k] = v
		end
	end
	return bat
end

local function makeUnit(unitId, role, weaponTypeName)
	return Medusa.Entities.Battery.newUnit({
		UnitId = unitId,
		UnitName = string.format("unit-%d", unitId),
		Roles = { role },
		AmmoCount = 2,
		AmmoTypes = {
			{
				WeaponTypeName = weaponTypeName,
				Count = 2,
				RangeMax = 5000,
			},
		},
	})
end

-- ============================================================
-- Minimal IadsNetwork fixture
-- ============================================================

local COAL_RED = (coalition and coalition.side and coalition.side.RED) or 1

local function makeIads()
	local iads = Medusa.Core.IadsNetwork:new({
		id = "T",
		coalitionId = COAL_RED,
		prefix = "iads",
	})
	iads:initialize()
	iads._running = true
	return iads
end

local function injectManpad(iads, unitIds, sleepWakeState)
	local manpadStore = iads:getAssetIndex():manpads()
	local bat = makeManpadBattery({
		Manpad = { SleepWakeState = sleepWakeState or "HOT" },
	})
	bat.Units = {}
	for i, uid in ipairs(unitIds) do
		local u = makeUnit(uid, Medusa.Constants.BatteryUnitRole.MANPAD, "SA-18 Grouse")
		table.insert(bat.Units, u)
	end
	Medusa.Entities.Battery.recomputeState(bat)
	manpadStore:add(bat)
	return bat
end

local function injectBattery(iads, unitIds)
	local batteryStore = iads:getAssetIndex():batteries()
	local bat = makeRegularBattery()
	bat.Role = Medusa.Constants.BatteryRole.SR_SAM
	bat.Units = {}
	bat.ShotsFired = 0
	for i, uid in ipairs(unitIds) do
		local u = makeUnit(uid, Medusa.Constants.BatteryUnitRole.LAUNCHER, "SA-6")
		table.insert(bat.Units, u)
	end
	Medusa.Entities.Battery.recomputeState(bat)
	batteryStore:add(bat)
	return bat
end

local function injectIndependentAaa(iads, unitId)
	local batteryStore = iads:getAssetIndex():batteries()
	local id = nextSeq()
	local bat = Medusa.Entities.Battery.new({
		NetworkId = "test-net",
		GroupId = id * 100,
		GroupName = string.format("aaa-group-%d", id),
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	})
	bat.Units = { makeUnit(unitId, Medusa.Constants.BatteryUnitRole.AAA, "ZU-23") }
	Medusa.Entities.Battery.recomputeState(bat)
	batteryStore:add(bat)
	return bat
end

-- ============================================================
-- 1. ManpadService.onShot — MANPAD policy hook
-- ============================================================

TestManpadServiceOnShot = {}

function TestManpadServiceOnShot:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestManpadServiceOnShot:tearDown()
	restoreMocks()
end

function TestManpadServiceOnShot:test_onShot_doesNotOwnSharedBatteryFields()
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "ASLEEP" } })
	bat.ShotsFired = 2
	Medusa.Services.ManpadService.onShot(bat, 500)
	lu.assertIsNil(bat.LastShotTime)
	lu.assertIsNil(bat.MissileInFlightUntil)
	lu.assertEquals(bat.ShotsFired, 2)
end

-- HOT state resets HotUntil within [min, max] AND resets AlertStartTime
function TestManpadServiceOnShot:test_onShot_hot_resetsHotSubfields()
	local now = 1000
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "HOT" } })
	Medusa.Services.ManpadService.onShot(bat, now)
	local C = Medusa.Constants
	lu.assertNotNil(bat.Manpad.HotUntil, "HotUntil must not be nil after onShot while HOT")
	local delta = bat.Manpad.HotUntil - now
	lu.assertTrue(
		delta >= C.Manpad.HOT_MIN_SEC,
		string.format("HotUntil delta (%d) must be >= Manpad.HOT_MIN_SEC", delta)
	)
	lu.assertTrue(
		delta <= C.Manpad.HOT_MAX_SEC,
		string.format("HotUntil delta (%d) must be <= Manpad.HOT_MAX_SEC", delta)
	)
	lu.assertEquals(bat.Manpad.AlertStartTime, now, "AlertStartTime must be set to now when HOT")
end

-- Non-HOT state does NOT touch Manpad sub-table
function TestManpadServiceOnShot:test_onShot_nonHot_manpadSubtableUntouched()
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "ALERT", HotUntil = 99, AlertStartTime = 55 } })
	Medusa.Services.ManpadService.onShot(bat, 200)
	lu.assertEquals(bat.Manpad.HotUntil, 99, "HotUntil must be unchanged in ALERT")
	lu.assertEquals(bat.Manpad.AlertStartTime, 55, "AlertStartTime must be unchanged in ALERT")
	lu.assertIsNil(bat.LastShotTime)
end

function TestManpadServiceOnShot:test_onShot_winchester_expiresHotState()
	local bat = makeManpadBattery({
		TotalAmmoStatus = 0,
		Manpad = { SleepWakeState = "HOT", HotUntil = 9999 },
	})

	Medusa.Services.ManpadService.onShot(bat, 200)

	lu.assertEquals(bat.Manpad.HotUntil, 200)
end

-- ============================================================
-- 2. IadsNetwork._handleShot MANPAD dispatch
-- ============================================================

TestIadsNetworkHandleShot = {}

local _origGetUnitDesc

function TestIadsNetworkHandleShot:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	_origGetUnitDesc = GetUnitDesc
	GetUnitDesc = function()
		return { attributes = { ["SAM LL"] = true } }
	end
	if Medusa.Services.MetricsService._registry then
		Medusa.Services.MetricsService._registry = {}
	end
end

function TestIadsNetworkHandleShot:tearDown()
	restoreMocks()
	GetUnitDesc = _origGetUnitDesc
end

function TestIadsNetworkHandleShot:test_handleShot_manpad_usesSharedAmmoPathAndPolicyHook()
	local iads = makeIads()
	local bat = injectManpad(iads, { 200 }, "HOT")

	local capturedBattery = nil
	local origOnShot = Medusa.Services.ManpadService.onShot
	Medusa.Services.ManpadService.onShot = function(battery, now)
		capturedBattery = battery
	end

	local decrementCalled = false
	local origDecrement = iads._decrementAmmo
	iads._decrementAmmo = function(...)
		decrementCalled = true
		if origDecrement then
			return origDecrement(...)
		end
	end

	local origInc = Medusa.Services.MetricsService.inc
	Medusa.Services.MetricsService.inc = function() end

	iads:_handleShot(200, "SA-18 Grouse")

	Medusa.Services.ManpadService.onShot = origOnShot
	iads._decrementAmmo = origDecrement
	Medusa.Services.MetricsService.inc = origInc

	lu.assertNotNil(capturedBattery, "ManpadService.onShot must be called for a MANPAD unit")
	lu.assertIs(capturedBattery, bat, "onShot must receive the MANPAD battery record")
	lu.assertTrue(decrementCalled, "MANPAD shots must use shared ammo accounting")
	lu.assertEquals(bat.TotalAmmoStatus, 1)
	lu.assertEquals(bat.ShotsFired, 1)
	lu.assertEquals(bat.LastShotTime, 1000)
	lu.assertEquals(iads._rollingPkCount, 0)
end

-- Regular battery unit shot → ManpadService.onShot NOT called
function TestIadsNetworkHandleShot:test_handleShot_regularBattery_doesNotCallOnShot()
	local iads = makeIads()
	local bat = injectBattery(iads, { 300 })

	local onShotCalled = false
	local origOnShot = Medusa.Services.ManpadService.onShot
	Medusa.Services.ManpadService.onShot = function(...)
		onShotCalled = true
	end

	iads:_handleShot(300, "SA-6")

	Medusa.Services.ManpadService.onShot = origOnShot

	lu.assertFalse(onShotCalled, "ManpadService.onShot must NOT be called for a non-MANPAD unit")
	lu.assertEquals(bat.ShotsFired, 1)
	lu.assertEquals(iads._rollingPkCount, 1)
	lu.assertEquals(iads._rollingPkBuffer[1], 0)
end

local function withWeaponTarget(target, fn)
	local origTarget = GetWeaponTarget
	GetWeaponTarget = function()
		return target
	end
	local ok, err = pcall(fn)
	GetWeaponTarget = origTarget
	if not ok then
		error(err, 0)
	end
end

local function missileDesc(guidance)
	return { category = Weapon.Category.MISSILE, guidance = guidance }
end

function TestIadsNetworkHandleShot:test_missile_shot_is_followed_with_the_track_its_weapon_targets()
	local iads = makeIads()
	local bat = injectBattery(iads, { 330 })
	iads:getTrackManager()._byNetworkId[777] = "TRK-777"
	local weapon = { id_ = 9001 }
	withWeaponTarget({ id_ = 777 }, function()
		iads:_handleShot(330, "SA-6", weapon, missileDesc(4))
	end)
	lu.assertNotNil(bat.MissilesInFlight)
	local flight = bat.MissilesInFlight[1]
	lu.assertIs(flight.Weapon, weapon)
	lu.assertEquals(flight.TargetTrackId, "TRK-777")
	lu.assertEquals(flight.LaunchTime, 1000)
	lu.assertTrue(flight.Guided)
end

function TestIadsNetworkHandleShot:test_ir_missile_is_not_crew_guided_and_an_unknown_target_stays_unknown()
	-- The battery's assignment is not what DCS fired at: guessing it would give a contact the crew never shot at
	-- unanswered-launch evidence, or start a test-shot hold on it.
	local iads = makeIads()
	local bat = injectBattery(iads, { 331 })
	bat.CurrentTargetTrackId = "ASSIGNED"
	withWeaponTarget(nil, function()
		iads:_handleShot(331, "SA-6", {}, missileDesc(2))
	end)
	lu.assertNil(bat.MissilesInFlight[1].TargetTrackId)
	lu.assertFalse(bat.MissilesInFlight[1].Guided)
	iads:getTrackManager()._byNetworkId[778] = nil
	withWeaponTarget({ id_ = 778 }, function() -- a weapon target the network holds no track of
		iads:_handleShot(331, "SA-6", {}, missileDesc(4))
	end)
	lu.assertNil(bat.MissilesInFlight[2].TargetTrackId)
end

local function injectNetworkedAaa(iads, gunUnitId, radarUnitId, shellTypeName)
	local batteryStore = iads:getAssetIndex():batteries()
	local id = nextSeq()
	local bat = Medusa.Entities.Battery.new({
		NetworkId = "test-net",
		GroupId = id * 100,
		GroupName = string.format("aaa-group-%d", id),
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	})
	bat.DetectionRangeMax = 20000
	local radar = makeUnit(radarUnitId, Medusa.Constants.BatteryUnitRole.SEARCH_RADAR, "none")
	radar.AmmoTypes = {}
	bat.Units = { makeUnit(gunUnitId, Medusa.Constants.BatteryUnitRole.AAA, shellTypeName), radar }
	Medusa.Entities.Battery.recomputeState(bat)
	batteryStore:add(bat)
	return bat
end

-- A DCS weapon object: reading it after the object has ended throws, as Weapon.getDesc does in DCS.
local function dcsWeapon(typeName, desc)
	local w = { gone = false, descReads = 0 }
	function w:getTypeName()
		return typeName
	end
	function w:getDesc()
		self.descReads = self.descReads + 1
		if self.gone then
			error("Weapon doesn't exist")
		end
		return desc
	end
	function w:getTarget()
		return nil
	end
	return w
end

local function publishShot(unitId, weapon)
	HarnessWorldEventBus:publish({
		id = world.event.S_EVENT_SHOT,
		weapon = weapon,
		initiator = {
			uid = unitId,
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
end

local function withUnitIds(fn)
	local origGetUnitID = GetUnitID
	GetUnitID = function(u)
		return u.uid
	end
	local ok, err = pcall(fn)
	GetUnitID = origGetUnitID
	if not ok then
		error(err, 0)
	end
end

function TestIadsNetworkHandleShot:test_networked_aaa_shell_is_not_a_decoy_response_launch()
	-- A gun shell is no missile the crew follows; it may already have ended when the shot queue is handled.
	local iads = makeIads()
	local bat = injectNetworkedAaa(iads, 340, 341, "weapons.shells.53-UOR-281U")
	lu.assertFalse(Medusa.Entities.Battery.isIndependentAaa(bat), "fixture: a network-run AAA battery")
	local shell = dcsWeapon("weapons.shells.53-UOR-281U", { category = Weapon.Category.SHELL })
	withUnitIds(function()
		publishShot(340, shell)
		shell.gone = true
		local reads = shell.descReads
		iads:_processShotEvents(10)
		lu.assertEquals(shell.descReads, reads, "no descriptor read once the shell may be gone")
	end)
	lu.assertEquals(bat.ShotsFired, 1)
	lu.assertTrue(bat.MissilesInFlight == nil or #bat.MissilesInFlight == 0)
end

function TestIadsNetworkHandleShot:test_a_shell_known_only_by_its_descriptor_is_not_a_decoy_response_launch()
	local iads = makeIads()
	local bat = injectNetworkedAaa(iads, 343, 344, "KS-19 shell")
	local shell = dcsWeapon("KS-19 shell", { category = Weapon.Category.SHELL })
	withUnitIds(function()
		publishShot(343, shell)
		iads:_processShotEvents(10)
	end)
	lu.assertEquals(shell.descReads, 1, "read once, at the event")
	lu.assertEquals(bat.ShotsFired, 1)
	lu.assertTrue(bat.MissilesInFlight == nil or #bat.MissilesInFlight == 0)
end

function TestIadsNetworkHandleShot:test_missile_descriptor_is_read_when_the_shot_event_arrives()
	local iads = makeIads()
	local bat = injectBattery(iads, { 342 })
	local missile = dcsWeapon("SA-6", { category = Weapon.Category.MISSILE, guidance = 4 })
	withUnitIds(function()
		publishShot(342, missile)
		lu.assertEquals(missile.descReads, 1, "read at the event")
		iads:_processShotEvents(10)
	end)
	lu.assertEquals(missile.descReads, 1, "not read again when the queue is handled")
	lu.assertEquals(#bat.MissilesInFlight, 1)
	lu.assertIs(bat.MissilesInFlight[1].Weapon, missile)
	lu.assertTrue(bat.MissilesInFlight[1].Guided)
end

function TestIadsNetworkHandleShot:test_stopping_the_network_releases_the_decoy_response()
	local iads = makeIads()
	local bat = injectBattery(iads, { 334 })
	bat.ActivationState = "STATE_HOT"
	bat.EngageAirWeapons = false
	bat.TestShotHold = { Since = 990 }
	local options, roe = {}, {}
	local origOption, origRoe = SetControllerOption, ControllerSetROE
	SetControllerOption = function(_, id, value)
		options[#options + 1] = { id = id, value = value }
	end
	ControllerSetROE = function(_, value)
		roe[#roe + 1] = value
	end
	local ok, err = pcall(iads.stop, iads)
	SetControllerOption, ControllerSetROE = origOption, origRoe
	lu.assertTrue(ok, tostring(err))
	lu.assertNil(bat.TestShotHold)
	lu.assertTrue(bat.EngageAirWeapons)
	lu.assertEquals(options, { { id = AI.Option.Ground.id.ENGAGE_AIR_WEAPONS, value = true } })
	lu.assertEquals(roe, { "OPEN_FIRE" })
end

function TestIadsNetworkHandleShot:test_no_flight_bookkeeping_when_decoy_assessment_is_off()
	local iads = makeIads()
	iads._doctrine.DecoyAssessment = false
	local bat = injectBattery(iads, { 332 })
	withWeaponTarget({ id_ = 777 }, function()
		iads:_handleShot(332, "SA-6", {}, missileDesc(4))
	end)
	lu.assertNil(bat.MissilesInFlight)
end

function TestIadsNetworkHandleShot:test_independentAaaShotDoesNotAffectRollingPk()
	local iads = makeIads()
	local bat = injectIndependentAaa(iads, 305)

	iads:_handleShot(305, "ZU-23")

	lu.assertEquals(bat.ShotsFired, 1)
	lu.assertEquals(bat.TotalAmmoStatus, 1)
	lu.assertEquals(iads._rollingPkCount, 0)
end

function TestIadsNetworkHandleShot:test_networked_aaa_gunfire_leaves_the_rolling_pk_alone()
	-- The rolling Pk is a kill rate per missile; a gun burst is many shells and no missile.
	local iads = makeIads()
	iads._doctrine.RollingPkEnabled = true
	local bat = injectNetworkedAaa(iads, 350, 351, "weapons.shells.53-UOR-281U")
	local gun = bat.Units[1]
	gun.AmmoCount, gun.AmmoTypes[1].Count = 40, 40
	Medusa.Entities.Battery.recomputeState(bat)
	local floorBefore = iads._effectivePkFloor
	local shots = Medusa.Constants.ROLLING_PK_WINDOW + 2
	for _ = 1, shots do
		iads:_handleShot(350, "weapons.shells.53-UOR-281U")
	end
	lu.assertEquals(bat.ShotsFired, shots)
	lu.assertEquals(bat.LastShotTime, 1000)
	lu.assertEquals(iads._rollingPkCount, 0)
	lu.assertEquals(iads._effectivePkFloor, floorBefore)
	lu.assertNil(bat.MissileInFlightUntil, "a shell needs no guidance once fired")
end

function TestIadsNetworkHandleShot:test_gun_shells_do_not_spend_a_last_chance_salvo()
	-- The salvo counts missiles; a gun's last chance runs on its hold-down window instead.
	local iads = makeIads()
	local bat = injectNetworkedAaa(iads, 355, 356, "weapons.shells.53-UOR-281U")
	local gun = bat.Units[1]
	gun.AmmoCount, gun.AmmoTypes[1].Count = 40, 40
	Medusa.Entities.Battery.recomputeState(bat)
	Medusa.Entities.Battery.beginLastChance(bat, "TRK-1", 15)
	for _ = 1, Medusa.Constants.LAST_CHANCE_SALVO_COUNT + 1 do
		iads:_handleShot(355, "weapons.shells.53-UOR-281U")
	end
	lu.assertEquals(bat.LastChanceShotsRemaining, Medusa.Constants.LAST_CHANCE_SALVO_COUNT)
	lu.assertEquals(bat.LastChanceTrackId, "TRK-1")
end

function TestIadsNetworkHandleShot:test_networkedAaaKillDoesNotCompleteRegularBatteryShot()
	local iads = makeIads()
	injectBattery(iads, { 352 })
	injectNetworkedAaa(iads, 353, 354, "weapons.shells.53-UOR-281U")
	iads:_handleShot(352, "SA-6")

	iads._killQueue:enqueue({ _unitId = 353 })
	iads:_processKillEvents(1)

	lu.assertEquals(iads._rollingPkCount, 1)
	lu.assertEquals(iads._rollingPkBuffer[1], 0)
end

function TestIadsNetworkHandleShot:test_a_missile_launch_makes_a_surprised_network_engaged_but_gunfire_does_not()
	local R = Medusa.Constants.Readiness
	local iads = makeIads()
	injectIndependentAaa(iads, 307)
	injectBattery(iads, { 308 })
	iads._crew.readiness = R.SURPRISED

	iads:_handleShot(307, "ZU-23")
	lu.assertEquals(iads:getReadiness(), R.SURPRISED)
	lu.assertEquals(Medusa.Services.CrewFactorsService.missilesInFlight(iads._crew, 1000), 0)

	iads:_handleShot(308, "SA-6")
	lu.assertEquals(iads:getReadiness(), R.ENGAGED)
	lu.assertEquals(Medusa.Services.CrewFactorsService.missilesInFlight(iads._crew, 1000), 1)
end

function TestIadsNetworkHandleShot:test_a_missile_loads_the_net_until_its_estimated_time_to_target()
	local iads = makeIads()
	local bat = injectBattery(iads, { 309 })
	bat.EngagementRangeMax = 10300 -- SA-8, no target track: the whole range at SAM_AVG_MISSILE_SPEED_MPS
	local ttk = 10300 / Medusa.Constants.SAM_AVG_MISSILE_SPEED_MPS
	iads:_handleShot(309, "SA-6")
	local CFS = Medusa.Services.CrewFactorsService
	lu.assertEquals(CFS.missilesInFlight(iads._crew, 1000 + ttk - 0.5), 1)
	lu.assertEquals(CFS.missilesInFlight(iads._crew, 1000 + ttk + 0.5), 0)
end

function TestIadsNetworkHandleShot:test_aaaShotDispatchesNeighborPropagation()
	local iads = makeIads()
	local bat = injectIndependentAaa(iads, 306)
	local received
	local originalOnShot = Medusa.Services.AaaService.onShot
	Medusa.Services.AaaService.onShot = function(ctx, battery, unit, now)
		received = { ctx = ctx, battery = battery, unit = unit, now = now }
	end

	iads:_handleShot(306, "ZU-23")

	Medusa.Services.AaaService.onShot = originalOnShot
	lu.assertEquals(received.battery, bat)
	lu.assertEquals(received.unit, bat.Units[1])
	lu.assertEquals(received.now, 1000)
	lu.assertEquals(received.ctx.batteryStore, iads:getAssetIndex():batteries())
	lu.assertEquals(received.ctx.localGeoGrid, iads:getAssetIndex():localGeoGrid())
end

function TestIadsNetworkHandleShot:test_handleShot_nonManpadCompanionDoesNotTriggerMissilePolicy()
	local iads = makeIads()
	local store = iads:getAssetIndex():manpads()
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "HOT", HotUntil = 1400 } })
	bat.Units = {
		makeUnit(310, Medusa.Constants.BatteryUnitRole.MANPAD, "SA-18 Grouse"),
		makeUnit(311, Medusa.Constants.BatteryUnitRole.OTHER, "Rifle"),
	}
	Medusa.Entities.Battery.recomputeState(bat)
	store:add(bat)
	local ammoBefore = bat.TotalAmmoStatus

	iads:_handleShot(311, "Rifle")

	lu.assertEquals(bat.TotalAmmoStatus, ammoBefore)
	lu.assertEquals(bat.ShotsFired, 0)
	lu.assertIsNil(bat.LastShotTime)
	lu.assertIsNil(bat.MissileInFlightUntil)
	lu.assertEquals(bat.Manpad.HotUntil, 1400)
end

function TestIadsNetworkHandleShot:test_handleShot_manpadRifleShotDoesNotConsumeMissile()
	local iads = makeIads()
	local bat = injectManpad(iads, { 312 }, "HOT")
	local ammoBefore = bat.TotalAmmoStatus

	iads:_handleShot(312, "Rifle")

	lu.assertEquals(bat.TotalAmmoStatus, ammoBefore)
	lu.assertEquals(bat.ShotsFired, 0)
	lu.assertIsNil(bat.LastShotTime)
	lu.assertIsNil(bat.MissileInFlightUntil)
	lu.assertEquals(iads._rollingPkCount, 0)
end

function TestIadsNetworkHandleShot:test_manpad_winchester_rearms_and_returns_alert()
	local iads = makeIads()
	local bat = injectManpad(iads, { 301 }, "HOT")
	local unit = bat.Units[1]
	unit.AmmoCount = 1
	unit.AmmoTypes[1].Count = 1
	Medusa.Entities.Battery.recomputeState(bat)

	local originalInc = Medusa.Services.MetricsService.inc
	local originalGetUnitAmmo = GetUnitAmmo
	local originalGoCold = Medusa.Services.BatteryActivationService.goCold
	local winchesterCount = 0
	Medusa.Services.MetricsService.inc = function(metricName)
		if metricName == "medusa_manpad_winchester_total" then
			winchesterCount = winchesterCount + 1
		end
	end

	local ok, err = pcall(function()
		iads:_handleShot(301, "SA-18 Grouse")
		lu.assertEquals(bat.TotalAmmoStatus, 0)
		lu.assertEquals(bat.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.REARMING)
		lu.assertEquals(bat.Manpad.HotUntil, 1000)
		lu.assertEquals(bat.RearmCheckTime, 1000 + Medusa.Constants.REARM_CHECK_INTERVAL_SEC)

		GetUnitAmmo = function(unitName)
			return {
				{
					count = 2,
					desc = {
						typeName = "SA-18 Grouse",
						displayName = "SA-18 Grouse",
						missileCategory = 1,
						rangeMaxAltMax = 5000,
						rangeMaxAltMin = 5000,
						rangeMin = 100,
						altMax = 3500,
						altMin = 0,
						Nmax = 8,
					},
				},
			}
		end
		Medusa.Services.BatteryActivationService.goCold = function()
			return true
		end
		iads:_checkRearming(bat.RearmCheckTime)
	end)

	Medusa.Services.MetricsService.inc = originalInc
	GetUnitAmmo = originalGetUnitAmmo
	Medusa.Services.BatteryActivationService.goCold = originalGoCold

	lu.assertTrue(ok, tostring(err))
	lu.assertEquals(winchesterCount, 1)
	lu.assertEquals(bat.TotalAmmoStatus, 2)
	lu.assertEquals(bat.Manpad.SleepWakeState, Medusa.Constants.Manpad.SleepWakeState.ALERT)
	lu.assertIsNil(bat.RearmCheckTime)
end

function TestIadsNetworkHandleShot:test_manpad_gunAmmoDoesNotCompleteRearm()
	local iads = makeIads()
	local bat = injectManpad(iads, { 302 }, "HOT")
	local unit = bat.Units[1]
	unit.AmmoCount = 0
	unit.AmmoTypes[1].Count = 0
	Medusa.Entities.Battery.recomputeState(bat)
	bat.RearmCheckTime = 1000

	local originalGetUnitAmmo = GetUnitAmmo
	GetUnitAmmo = function()
		return {
			{
				count = 30,
				desc = {
					typeName = "Rifle",
					displayName = "Rifle",
					rangeMaxAltMax = 500,
					rangeMaxAltMin = 500,
				},
			},
		}
	end

	iads:_checkRearming(1000)
	GetUnitAmmo = originalGetUnitAmmo

	lu.assertEquals(bat.TotalAmmoStatus, 0)
	lu.assertEquals(bat.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.REARMING)
	lu.assertEquals(bat.RearmCheckTime, 1000 + Medusa.Constants.REARM_CHECK_INTERVAL_SEC)
end

function TestIadsNetworkHandleShot:test_manpadKillDoesNotCompleteRegularBatteryShot()
	local iads = makeIads()
	injectBattery(iads, { 320 })
	injectManpad(iads, { 321 }, "HOT")
	iads:_handleShot(320, "SA-6")

	iads._killQueue:enqueue({ _unitId = 321 })
	iads:_processKillEvents(1)

	lu.assertEquals(iads._rollingPkCount, 1)
	lu.assertEquals(iads._rollingPkBuffer[1], 0)

	iads._killQueue:enqueue({ _unitId = 320 })
	iads:_processKillEvents(1)

	lu.assertEquals(iads._rollingPkBuffer[1], 1)
end

function TestIadsNetworkHandleShot:test_independentAaaKillDoesNotCompleteRegularBatteryShot()
	local iads = makeIads()
	injectBattery(iads, { 322 })
	injectIndependentAaa(iads, 323)
	iads:_handleShot(322, "SA-6")

	iads._killQueue:enqueue({ _unitId = 323 })
	iads:_processKillEvents(1)

	lu.assertEquals(iads._rollingPkCount, 1)
	lu.assertEquals(iads._rollingPkBuffer[1], 0)
end

-- An SA-6 site with a Shilka and its tracking radar: a SAM-role battery that also carries a gun. The shell names
-- stand in for whatever the gun's ammunition descriptors give.
local KUB_TYPE, KUB_NAME = "SA3M9M", "3M9M Kub (SA-6 Gainful)"
local GUN_SHELL_TYPE, GUN_SHELL_NAME = "weapons.shells.2A7_23_HE", "23mm HE"

local function injectSamSiteWithGun(iads, launcherId, gunId, radarId)
	local BUR = Medusa.Constants.BatteryUnitRole
	local bat = makeRegularBattery()
	bat.Role = Medusa.Constants.BatteryRole.SR_SAM
	bat.ShotsFired = 0
	local launcher = makeUnit(launcherId, BUR.LAUNCHER, KUB_TYPE)
	launcher.AmmoTypes[1].WeaponDisplayName = KUB_NAME
	local gun = Medusa.Entities.Battery.newUnit({
		UnitId = gunId,
		Roles = { BUR.AAA },
		GunNames = { [GUN_SHELL_TYPE] = true, [GUN_SHELL_NAME] = true },
	})
	local radar = Medusa.Entities.Battery.newUnit({ UnitId = radarId, Roles = { BUR.TRACK_RADAR } })
	bat.Units = { launcher, gun, radar }
	Medusa.Entities.Battery.recomputeState(bat)
	iads:getAssetIndex():batteries():add(bat)
	return bat
end

local function killBy(iads, unitId, weaponName)
	iads._killQueue:enqueue({ _unitId = unitId, weapon_name = weaponName })
	iads:_processKillEvents(1)
end

function TestIadsNetworkHandleShot:test_a_gun_kill_in_a_sam_site_is_not_a_missile_hit()
	local iads = makeIads()
	injectSamSiteWithGun(iads, 360, 361, 362)
	iads:_handleShot(360, KUB_TYPE)

	killBy(iads, 361, GUN_SHELL_NAME)

	lu.assertEquals(iads._rollingPkCount, 1)
	lu.assertEquals(iads._rollingPkBuffer[1], 0)
end

function TestIadsNetworkHandleShot:test_a_gun_kill_named_by_the_shell_type_is_not_a_missile_hit()
	local iads = makeIads()
	injectSamSiteWithGun(iads, 380, 381, 382)
	iads:_handleShot(380, KUB_TYPE)

	killBy(iads, 381, GUN_SHELL_TYPE)

	lu.assertEquals(iads._rollingPkBuffer[1], 0)
end

function TestIadsNetworkHandleShot:test_the_kill_line_names_the_weapon_only_when_dcs_gives_one()
	local iads = makeIads()
	local bat = injectSamSiteWithGun(iads, 386, 387, 388)
	local lines = {}
	local logger = iads._logger
	local original = logger.info
	logger.info = function(_, msg)
		lines[#lines + 1] = msg
	end
	local ok, err = pcall(function()
		killBy(iads, 386, KUB_NAME)
		killBy(iads, 386, nil)
	end)
	logger.info = original
	lu.assertTrue(ok, tostring(err))

	lu.assertEquals(lines[1], "battery " .. bat.GroupName .. " scored a kill (" .. KUB_NAME .. ")")
	lu.assertEquals(lines[2], "battery " .. bat.GroupName .. " scored a kill")
end

function TestIadsNetworkHandleShot:test_a_kill_by_a_name_the_site_does_not_know_is_a_hit()
	-- Only a name the battery's guns carry makes a gun kill: a missile named some other way still counts.
	local iads = makeIads()
	injectSamSiteWithGun(iads, 383, 384, 385)
	iads:_handleShot(383, KUB_TYPE)

	killBy(iads, 383, "a name neither the guns nor the missiles carry")

	lu.assertEquals(iads._rollingPkBuffer[1], 1)
end

function TestIadsNetworkHandleShot:test_a_kill_by_a_short_missile_name_is_a_hit()
	local iads = makeIads()
	injectSamSiteWithGun(iads, 386, 387, 388)
	iads:_handleShot(386, KUB_TYPE)

	killBy(iads, 388, "3M9M")

	lu.assertEquals(iads._rollingPkBuffer[1], 1)
end

function TestIadsNetworkHandleShot:test_a_missile_kill_reported_by_the_guiding_radar_is_a_hit()
	local iads = makeIads()
	injectSamSiteWithGun(iads, 363, 364, 365)
	iads:_handleShot(363, KUB_TYPE)

	killBy(iads, 365, KUB_NAME)

	lu.assertEquals(iads._rollingPkBuffer[1], 1)
end

function TestIadsNetworkHandleShot:test_the_last_missiles_kill_is_a_hit()
	-- The kill arrives after the launch spent the round, so the cached count is already zero.
	local iads = makeIads()
	local bat = injectSamSiteWithGun(iads, 366, 367, 368)
	iads:_handleShot(366, KUB_TYPE)
	iads:_handleShot(366, KUB_TYPE)
	lu.assertEquals(bat.Units[1].AmmoTypes[1].Count, 0)

	killBy(iads, 366, KUB_NAME)

	lu.assertEquals(iads._rollingPkBuffer[2], 1)
end

function TestIadsNetworkHandleShot:test_a_kill_named_by_the_missile_type_is_a_hit()
	local iads = makeIads()
	injectSamSiteWithGun(iads, 369, 370, 371)
	iads:_handleShot(369, KUB_TYPE)

	killBy(iads, 369, KUB_TYPE)

	lu.assertEquals(iads._rollingPkBuffer[1], 1)
end

function TestIadsNetworkHandleShot:test_an_unnamed_kill_in_a_site_with_a_gun_is_a_hit()
	local iads = makeIads()
	injectSamSiteWithGun(iads, 372, 373, 374)
	iads:_handleShot(372, KUB_TYPE)

	killBy(iads, 373, nil)

	lu.assertEquals(iads._rollingPkBuffer[1], 1)
end

function TestIadsNetworkHandleShot:test_any_kill_of_a_site_without_a_gun_is_a_hit()
	local iads = makeIads()
	injectBattery(iads, { 375 })
	iads:_handleShot(375, "SA-6")

	killBy(iads, 375, "a name the battery's ammo does not carry")

	lu.assertEquals(iads._rollingPkBuffer[1], 1)
end

-- A Tunguska: one launcher unit with missiles and guns, whose cached ammo holds only the missiles.
local TUNGUSKA_SHELL_TYPE, TUNGUSKA_SHELL_NAME = "weapons.shells.2A38_30_HE", "30mm HE"

local function injectGunMissileLauncher(iads, unitId)
	local bat = injectBattery(iads, { unitId })
	bat.Units[1].GunNames = { [TUNGUSKA_SHELL_TYPE] = true, [TUNGUSKA_SHELL_NAME] = true }
	return bat
end

function TestIadsNetworkHandleShot:test_a_gun_missile_units_cannon_kill_is_not_a_missile_hit()
	local iads = makeIads()
	injectGunMissileLauncher(iads, 389)
	iads:_handleShot(389, "SA-6")

	killBy(iads, 389, TUNGUSKA_SHELL_NAME)

	lu.assertEquals(iads._rollingPkBuffer[1], 0)
end

local function captureErrors(iads, fn)
	local errors = {}
	local logger = iads._logger
	local original = logger.error
	logger.error = function(_, msg)
		errors[#errors + 1] = msg
	end
	local ok, err = pcall(fn)
	logger.error = original
	lu.assertTrue(ok, tostring(err))
	return errors
end

function TestIadsNetworkHandleShot:test_a_gun_missile_units_shell_spends_no_missile_and_is_no_launch()
	local R = Medusa.Constants.Readiness
	local iads = makeIads()
	local bat = injectGunMissileLauncher(iads, 376)
	iads._crew.readiness = R.SURPRISED

	local errors = captureErrors(iads, function()
		iads:_handleShot(376, TUNGUSKA_SHELL_TYPE)
	end)

	lu.assertEquals(#errors, 0)
	lu.assertEquals(bat.Units[1].AmmoCount, 2)
	lu.assertEquals(bat.Units[1].AmmoTypes[1].Count, 2)
	lu.assertEquals(bat.ShotsFired, 0)
	lu.assertEquals(iads:getReadiness(), R.SURPRISED)
	lu.assertEquals(Medusa.Services.CrewFactorsService.missilesInFlight(iads._crew, 1000), 0)
end

function TestIadsNetworkHandleShot:test_a_shell_known_by_its_descriptor_spends_no_missile()
	local iads = makeIads()
	local bat = injectGunMissileLauncher(iads, 377)

	local errors = captureErrors(iads, function()
		iads:_handleShot(377, "GSh_30", nil, { category = Weapon.Category.SHELL })
	end)

	lu.assertEquals(#errors, 0)
	lu.assertEquals(bat.Units[1].AmmoCount, 2)
	lu.assertEquals(Medusa.Services.CrewFactorsService.missilesInFlight(iads._crew, 1000), 0)
end

function TestIadsNetworkHandleShot:test_a_shell_from_a_sam_units_ammo_is_no_crew_launch()
	local R = Medusa.Constants.Readiness
	local iads = makeIads()
	local bat = injectBattery(iads, { 378 })
	local shell = "weapons.shells.2A38_30_HE"
	table.insert(bat.Units[1].AmmoTypes, { WeaponTypeName = shell, Count = 10, RangeMax = 4000 })
	iads._crew.readiness = R.SURPRISED

	iads:_handleShot(378, shell)

	lu.assertEquals(iads:getReadiness(), R.SURPRISED)
	lu.assertEquals(Medusa.Services.CrewFactorsService.missilesInFlight(iads._crew, 1000), 0)
end

-- ============================================================
-- 3. IadsNetwork._handleUnitDeath MANPAD guard
-- ============================================================

TestIadsNetworkHandleUnitDeathManpad = {}

function TestIadsNetworkHandleUnitDeathManpad:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	_origGetUnitDesc = GetUnitDesc
	GetUnitDesc = function()
		return { attributes = { ["SAM LL"] = true } }
	end
end

function TestIadsNetworkHandleUnitDeathManpad:tearDown()
	restoreMocks()
	GetUnitDesc = _origGetUnitDesc
end

-- MANPAD unit dies, team still has remaining soldiers → unit removed from roster, manpad stays
function TestIadsNetworkHandleUnitDeathManpad:test_death_manpad_oneOfThree_manpadStaysInStore()
	local iads = makeIads()
	local bat = injectManpad(iads, { 210, 211, 212 }, "HOT")
	local manpadStore = iads:getAssetIndex():manpads()

	iads._deathQueue:enqueue({
		_unitId = 210,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(#bat.Units, 2, "2 units must remain after 1-of-3 soldier death")
	lu.assertEquals(manpadStore:count(), 1, "MANPAD must stay in store when soldiers remain")
end

-- Full MANPAD team dies → manpad removed from stores.manpads AND from GeoGrid
function TestIadsNetworkHandleUnitDeathManpad:test_death_manpad_lastSoldier_removedFromStoreAndGrid()
	local iads = makeIads()
	local bat = injectManpad(iads, { 220 }, "ALERT")
	local manpadStore = iads:getAssetIndex():manpads()

	local removedId = nil
	local originalSpatialIndex = iads._spatialIndex
	iads._spatialIndex = {
		removeSuppressibleUnit = function() end,
		removeBattery = function(self, id)
			removedId = id
		end,
	}

	iads._deathQueue:enqueue({
		_unitId = 220,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	iads._spatialIndex = originalSpatialIndex

	lu.assertEquals(manpadStore:count(), 0, "MANPAD view must be empty after last soldier dies")
	lu.assertNotNil(removedId, "spatial index removal must occur when the last MANPAD soldier dies")
	lu.assertEquals(removedId, bat.BatteryId)
end

function TestIadsNetworkHandleUnitDeathManpad:test_radar_loss_withdraws_aaa_until_local_mode_is_applied()
	local iads = makeIads()
	local site = Medusa.Entities.Battery.new({
		NetworkId = "test-net",
		GroupId = 230,
		GroupName = "radar-aaa",
		Role = Medusa.Constants.BatteryRole.AAA,
		Position = { x = 0, y = 0, z = 0 },
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	})
	local gun = makeUnit(230, Medusa.Constants.BatteryUnitRole.AAA, "ZU-23")
	local radar = makeUnit(231, Medusa.Constants.BatteryUnitRole.SEARCH_RADAR, "radar")
	radar.DetectionRangeMax = 20000
	site.Units = { gun, radar }
	Medusa.Entities.Battery.recomputeState(site)
	site.DetectionRangeMax = 20000
	site.Aaa.Mode = Medusa.Constants.Aaa.Mode.RADAR_DIRECTED
	iads:getAssetIndex():batteries():add(site)
	iads._spatialIndex:syncBattery(site)

	local protected = injectBattery(iads, { 232 })
	Medusa.Services.PointDefenseService.setAssignment(
		site.BatteryId,
		protected.BatteryId,
		iads:getAssetIndex():batteries()
	)
	site.CurrentTargetTrackId = "assigned-track"

	iads:_handleUnitDeath(231)

	local networked = iads:getAssetIndex():networkedGeoGrid():queryRadius(site.Position, 1000, { "Battery" })
	local localResult = iads:getAssetIndex():localGeoGrid():queryRadius(site.Position, 1000, { "Aaa" })
	lu.assertNil(networked.BatteryIds[site.BatteryId])
	lu.assertNil(localResult.AaaIds[site.BatteryId])
	lu.assertNil(site.CurrentTargetTrackId)
	lu.assertFalse(site.IsPointDefense)
	lu.assertNil(protected.PointDefenseProviderId)
	lu.assertTrue(iads._pdReassignNeeded)
end

-- ============================================================
-- 4. Repository unit index
-- ============================================================

TestIadsNetworkRepositoryUnitIndex = {}

function TestIadsNetworkRepositoryUnitIndex:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	_origGetUnitDesc = GetUnitDesc
	GetUnitDesc = function()
		return { attributes = { ["SAM LL"] = true } }
	end
end

function TestIadsNetworkRepositoryUnitIndex:tearDown()
	restoreMocks()
	GetUnitDesc = _origGetUnitDesc
end

function TestIadsNetworkRepositoryUnitIndex:test_manpadUnits_areIndexedOnAdd()
	local iads = makeIads()
	local manpadStore = iads:getAssetIndex():manpads()
	local repository = iads:getAssetIndex():batteryRepository()

	local bat = makeManpadBattery()
	bat.Units = {
		makeUnit(200, Medusa.Constants.BatteryUnitRole.MANPAD, "SA-18 Grouse"),
		makeUnit(201, Medusa.Constants.BatteryUnitRole.MANPAD, "SA-18 Grouse"),
	}
	manpadStore:add(bat)

	local firstBattery, firstUnit = repository:getByUnitId(200)
	local secondBattery, secondUnit = repository:getByUnitId(201)

	lu.assertIs(firstBattery, bat)
	lu.assertEquals(firstUnit.UnitId, 200)
	lu.assertIs(secondBattery, bat)
	lu.assertEquals(secondUnit.UnitId, 201)
end

TestIadsNetworkManpadAssignmentCue = {}

function TestIadsNetworkManpadAssignmentCue:test_every_target_assignment_cues_manpads()
	local iads = makeIads()
	local TargetAssigner = Medusa.Services.TargetAssigner
	local ManpadService = Medusa.Services.ManpadService
	local originalEmconSelfAssign = TargetAssigner.emconSelfAssign
	local originalAssignTargets = TargetAssigner.assignTargets
	local originalCue = ManpadService.cueFromIADS
	local cues = {}

	TargetAssigner.emconSelfAssign = function()
		return {}
	end
	TargetAssigner.assignTargets = function()
		return {
			{ batteryId = "sead-battery", trackId = "sead-track" },
			{ batteryId = "greedy-battery", trackId = "greedy-track" },
		}
	end
	ManpadService.cueFromIADS = function(ctx, position)
		cues[#cues + 1] = position
	end

	local tracks = {
		["sead-track"] = { Position = { x = 1, y = 2, z = 3 } },
		["greedy-track"] = { Position = { x = 4, y = 5, z = 6 } },
	}
	local ok, err = pcall(function()
		iads:_phaseAssign({
			now = 50,
			trackStore = {
				get = function(self, trackId)
					return tracks[trackId]
				end,
			},
			batteryStore = iads:getAssetIndex():batteries(),
			manpadStore = iads:getAssetIndex():manpads(),
			hpt = function()
				return 0
			end,
			MS = {
				observe = function() end,
				observeDuration = function() end,
				inc = function() end,
			},
		})
	end)

	TargetAssigner.emconSelfAssign = originalEmconSelfAssign
	TargetAssigner.assignTargets = originalAssignTargets
	ManpadService.cueFromIADS = originalCue

	lu.assertTrue(ok, tostring(err))
	lu.assertEquals(#cues, 2)
	lu.assertIs(cues[1], tracks["sead-track"].Position)
	lu.assertIs(cues[2], tracks["greedy-track"].Position)
end

TestIadsNetworkDecoyPhase = {}

function TestIadsNetworkDecoyPhase:setUp()
	installMocks()
end

function TestIadsNetworkDecoyPhase:tearDown()
	restoreMocks()
end

function TestIadsNetworkDecoyPhase:test_harm_phase_runs_decoy_pass_then_response_before_point_defence()
	local iads = makeIads()
	local order = {}
	local DAS, DRS = Medusa.Services.DecoyAssessmentService, Medusa.Services.DecoyResponseService
	local PDS = Medusa.Services.PointDefenseService
	local origAssess, origUpdate, origEngage = DAS.assess, DRS.update, PDS.engageThreats
	DAS.assess = function(ctx)
		order[#order + 1] = "assess"
		lu.assertNotNil(ctx.geoGrid)
	end
	DRS.update = function()
		order[#order + 1] = "update"
	end
	PDS.engageThreats = function()
		order[#order + 1] = "pd"
		return 0
	end
	iads._assignmentPhase = 1
	local ok, err = pcall(iads._runPhase, iads)
	DAS.assess, DRS.update, PDS.engageThreats = origAssess, origUpdate, origEngage
	lu.assertTrue(ok, tostring(err))
	lu.assertEquals(order, { "assess", "update", "pd" })
end
