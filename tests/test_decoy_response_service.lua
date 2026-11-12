local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Track")
require("entities.Battery")
require("entities.Doctrine")
require("services.Services")
require("services.stores.TrackStore")
require("services.stores.BatteryStore")
require("services.SpatialQuery")
require("services.MetricsService")
require("services.BatteryActivationService")
require("services.DecoyAssessmentService")
require("services.DecoyResponseService")
require("services.PkModel")
require("services.TargetAssigner")
require("services.PointDefenseService")

local Assess = Medusa.Services.DecoyAssessmentService
local Response = Medusa.Services.DecoyResponseService
local D = Medusa.Constants.Decoy
local EAW_ID = 20

local calls
local weaponAlive
local weaponPoint
local weaponVelocity

local MOCKED = {
	"GetTime",
	"GetGroupController",
	"SetControllerOption",
	"ControllerSetROE",
	"ControllerSetAlarmState",
	"SetControllerOnOff",
	"EnableGroupEmissions",
	"GetGroup",
	"IsWeaponExist",
	"GetWeaponPoint",
	"GetWeaponVelocity",
}
local saved = {}
for _, name in ipairs(MOCKED) do
	saved[name] = _G[name]
end

local function restoreMocks()
	for _, name in ipairs(MOCKED) do
		_G[name] = saved[name]
	end
end

local function setupMocks()
	calls = { option = {}, roe = {} }
	weaponAlive = {}
	GetTime = function()
		return 1000
	end
	GetGroupController = function(name)
		return { name = name }
	end
	SetControllerOption = function(controller, id, value)
		calls.option[#calls.option + 1] = { group = controller.name, id = id, value = value }
		return true
	end
	ControllerSetROE = function(controller, value)
		calls.roe[#calls.roe + 1] = { group = controller.name, value = value }
		return true
	end
	ControllerSetAlarmState = function() end
	SetControllerOnOff = function() end
	EnableGroupEmissions = function() end
	GetGroup = function()
		return nil
	end
	IsWeaponExist = function(weapon)
		return weaponAlive[weapon] == true
	end
	weaponPoint = {}
	weaponVelocity = {}
	GetWeaponPoint = function(weapon)
		return weaponPoint[weapon]
	end
	GetWeaponVelocity = function(weapon)
		return weaponVelocity[weapon]
	end
end

local groupIdCounter = 0

local function newWorld(doctrine)
	local w = {
		trackStore = Medusa.Services.TrackStore:new(),
		batteryStore = Medusa.Services.BatteryStore:new(),
		geoGrid = GeoGrid(10000, { "Battery", "Track" }),
		doctrine = Medusa.Entities.Doctrine.new(doctrine or {}),
		now = 1000,
		holdBreaksTypes = {},
	}
	return w
end

local function addBattery(w, overrides)
	groupIdCounter = groupIdCounter + 1
	local data = {
		NetworkId = "net-1",
		GroupId = groupIdCounter,
		GroupName = string.format("SAM-%d", groupIdCounter),
		OperationalStatus = "ACTIVE",
		ActivationState = "STATE_HOT",
		Position = { x = 0, y = 0, z = 0 },
		Role = "LR_SAM",
		EngagementRangeMax = 60000,
		TotalAmmoStatus = 12,
		StateChangeHoldDownSec = 0,
	}
	for k, v in pairs(overrides or {}) do
		data[k] = v
	end
	local b = Medusa.Entities.Battery.new(data)
	b.EngageAirWeapons = true
	w.batteryStore:add(b)
	w.geoGrid:add("Battery", b.BatteryId, b.Position)
	return b
end

local trackCounter = 0

--- A contact 54 km north-north-east of the origin (20 km abeam of it) flying south at 200 m/s at 6000 m, with an
--- aircraft-sized return.
--- kind: "probable", "suspect", "aircraft" (seen as one), "unknown".
local function addTrack(w, kind, overrides)
	trackCounter = trackCounter + 1
	local data = {
		TrackId = "T" .. trackCounter,
		DisplayTrackId = "T" .. trackCounter,
		NetworkId = trackCounter,
		Position = { x = 20000, y = 6000, z = 50000 },
		Velocity = { x = 0, y = 0, z = -200 },
		AssessedAircraftType = "FIXED_WING",
		TrackIdentification = "HOSTILE",
		SizeDb = 7,
		SizeWeight = 4,
		SizeSpreadDb = 1.8,
	}
	for k, v in pairs(overrides or {}) do
		data[k] = v
	end
	local t = Medusa.Entities.Track.new(data)
	if kind == "probable" or kind == "suspect" then
		t.DecoyAssessment = {
			label = kind == "probable" and "PROBABLE" or "SUSPECT",
			runSec = 100,
			runHeading = 0,
			launchEvidence = 0,
			disproofScans = 0,
			slope = -10,
		}
	elseif kind == "aircraft" then
		t.SeenAs = "AIRCRAFT"
	end
	w.trackStore:add(t)
	w.geoGrid:add("Track", t.TrackId, t.Position)
	return t
end

--- A probable decoy diving onto the battery at the origin (its glide is predicted to end there).
local function divingAtOrigin(w)
	return addTrack(
		w,
		"probable",
		{ Position = { x = 0, y = 5000, z = 10000 }, Velocity = { x = 0, y = -100, z = -200 } }
	)
end

local function ctxOf(w)
	return {
		trackStore = w.trackStore,
		batteryStore = w.batteryStore,
		geoGrid = w.geoGrid,
		doctrine = w.doctrine,
		now = w.now,
		maxRange = 200000,
		holdBreaksTypes = w.holdBreaksTypes,
	}
end

local function pass(w)
	local ctx = ctxOf(w)
	local tracks = w.trackStore:getAll()
	Assess.assess(ctx, tracks, #tracks)
	Response.update(ctx)
end

local function eawWrites(group)
	local out = {}
	for _, c in ipairs(calls.option) do
		if c.id == EAW_ID and (not group or c.group == group) then
			out[#out + 1] = c.value
		end
	end
	return out
end

-- == Per-battery reach tally ==

TestDecoyReach = {}

function TestDecoyReach:setUp()
	setupMocks()
end

function TestDecoyReach:tearDown()
	restoreMocks()
end

function TestDecoyReach:test_tally_counts_what_is_in_engagement_reach_only()
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "probable")
	addTrack(w, "aircraft")
	addTrack(w, "unknown", { Position = { x = 0, y = 6000, z = 100000 } }) -- beyond 60 + 10 km
	Assess.assess(ctxOf(w))
	lu.assertEquals(b.DecoyReach.probable, 1)
	lu.assertEquals(b.DecoyReach.aircraft, 1)
	lu.assertEquals(b.DecoyReach.other, 0)
end

function TestDecoyReach:test_only_batteries_the_response_decides_for_are_tallied()
	local w = newWorld()
	local warm = addBattery(w, { ActivationState = "STATE_WARM" })
	local shorad = addBattery(w, { Role = "SR_SAM" })
	local pd = addBattery(w, { IsPointDefense = true })
	local holding = addBattery(w, { ActivationState = "STATE_WARM" })
	holding.TestShotHold = { Since = 1000 }
	addTrack(w, "probable")
	Assess.assess(ctxOf(w))
	lu.assertNil(warm.DecoyReach)
	lu.assertNil(shorad.DecoyReach)
	lu.assertNil(pd.DecoyReach)
	lu.assertEquals(holding.DecoyReach.probable, 1)
end

function TestDecoyReach:test_switch_off_creates_no_state()
	local w = newWorld({ DecoyAssessment = false })
	local b = addBattery(w)
	local rows = {}
	local t = addTrack(w, "unknown")
	for i = 0, 30 do
		rows[i] = i
		Medusa.Entities.Track.update(
			t,
			{ x = 0, y = 6000, z = 50000 - i * 1000 },
			{ x = 0, y = 0, z = -200 + i },
			i * 5
		)
	end
	pass(w)
	lu.assertNil(t.DecoyAssessment)
	lu.assertNil(b.DecoyReach)
	lu.assertEquals(#calls.option, 0)
	lu.assertEquals(#calls.roe, 0)
end

-- == Engage-air-weapons ==

TestEngageAirWeapons = {}

function TestEngageAirWeapons:setUp()
	setupMocks()
end

function TestEngageAirWeapons:tearDown()
	restoreMocks()
end

function TestEngageAirWeapons:test_off_when_only_probable_decoys_and_known_aircraft_are_in_reach_written_once()
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "probable")
	addTrack(w, "aircraft")
	pass(w)
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), { false })
	lu.assertFalse(b.EngageAirWeapons)
end

function TestEngageAirWeapons:test_back_on_when_an_unidentified_contact_comes_into_reach()
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "probable")
	pass(w)
	addTrack(w, "unknown")
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), { false, true })
end

function TestEngageAirWeapons:test_stays_on_without_a_probable_decoy_or_with_a_suspect()
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "aircraft")
	pass(w)
	addTrack(w, "probable")
	addTrack(w, "suspect")
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), {})
end

function TestEngageAirWeapons:test_waits_for_a_missile_in_flight_at_a_contact_that_may_be_a_weapon()
	local w = newWorld()
	local b = addBattery(w)
	local decoy = addTrack(w, "probable")
	-- out of reach, but the battery's missile is at it: an unknown may be a weapon (the switch would end that missile)
	local unknown = addTrack(w, "unknown", { Position = { x = 0, y = 6000, z = 150000 } })
	local weapon = {}
	weaponAlive[weapon] = true
	b.MissilesInFlight = { { Weapon = weapon, LaunchTime = 990, TargetTrackId = unknown.TrackId, Guided = true } }
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), {})
	weaponAlive[weapon] = false
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), { false })
	-- a missile at the probable decoy itself does not hold the switch
	local w2 = newWorld()
	local b2 = addBattery(w2)
	local d2 = addTrack(w2, "probable")
	local wp2 = {}
	weaponAlive[wp2] = true
	b2.MissilesInFlight = { { Weapon = wp2, LaunchTime = 990, TargetTrackId = d2.TrackId, Guided = true } }
	pass(w2)
	lu.assertEquals(eawWrites(b2.GroupName), { false })
	lu.assertNotNil(decoy)
end

function TestEngageAirWeapons:test_a_missile_at_a_known_aircraft_does_not_hold_the_switch_on()
	-- Measured in DCS: switching engage-air-weapons off does not end a missile guiding on an aircraft; an
	-- SA-10 whose missile at an F-16 held the switch on then fired at probable decoys.
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "probable")
	local jet = addTrack(w, "aircraft")
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), { false })
	local weapon = {}
	weaponAlive[weapon] = true
	Response.recordLaunch(
		ctxOf(w),
		b,
		{ Weapon = weapon, LaunchTime = 1000, TargetTrackId = jet.TrackId, Guided = true }
	)
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), { false })
end

function TestEngageAirWeapons:test_a_missile_fired_with_the_switch_off_was_fired_at_an_aircraft()
	-- With engage-air-weapons off the crew's system can only engage an aircraft, whatever the network's label.
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "probable")
	local unknown = addTrack(w, "unknown", { Position = { x = 0, y = 6000, z = 150000 } })
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), { false })
	local weapon = {}
	weaponAlive[weapon] = true
	Response.recordLaunch(
		ctxOf(w),
		b,
		{ Weapon = weapon, LaunchTime = 1000, TargetTrackId = unknown.TrackId, Guided = true }
	)
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), { false })
	lu.assertNil(Response._missileAtWeapon(ctxOf(w), b))
end

function TestEngageAirWeapons:test_point_defence_shorad_and_cold_batteries_are_never_switched()
	local w = newWorld()
	local sr = addBattery(w, { Role = "SR_SAM" })
	local pd = addBattery(w, { Role = "MR_SAM", IsPointDefense = true })
	local cold = addBattery(w, { ActivationState = "STATE_WARM" })
	addTrack(w, "probable")
	pass(w)
	lu.assertEquals(eawWrites(sr.GroupName), {})
	lu.assertEquals(eawWrites(pd.GroupName), {})
	lu.assertEquals(eawWrites(cold.GroupName), {})
end

function TestEngageAirWeapons:test_doctrine_switch_off_never_writes_the_switch()
	local w = newWorld({ ManageEngageAirWeapons = false })
	addBattery(w)
	addTrack(w, "probable")
	pass(w)
	lu.assertEquals(eawWrites(), {})
end

function TestEngageAirWeapons:test_a_probable_decoy_whose_glide_ends_at_the_battery_keeps_it_on()
	local w = newWorld()
	local b = addBattery(w)
	divingAtOrigin(w)
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), {})
end

function TestEngageAirWeapons:test_a_probable_decoy_flying_over_the_battery_to_something_behind_turns_it_off()
	-- TALDs homing on an early-warning radar 15 km behind a site pass 2.6 km from it
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "probable", { Position = { x = 2600, y = 6000, z = 30000 } })
	pass(w)
	lu.assertEquals(eawWrites(b.GroupName), { false })
end

function TestEngageAirWeapons:test_going_hot_leaves_a_switch_medusa_never_turned_off_alone()
	-- With the decoy switches off (or nothing ever switched) going HOT writes nothing: the mission's setting stays.
	for _, initial in ipairs({ "never written", true }) do
		setupMocks()
		local w = newWorld({ DecoyAssessment = false })
		local b = addBattery(w, { ActivationState = "STATE_WARM" })
		b.EngageAirWeapons = initial == true or nil
		Medusa.Services.BatteryActivationService.forceGoHot(b, 1000)
		lu.assertEquals(eawWrites(b.GroupName), {}, tostring(initial))
	end
end

function TestEngageAirWeapons:test_going_hot_resets_the_switch_to_on()
	local w = newWorld()
	local b = addBattery(w, { ActivationState = "STATE_WARM" })
	b.EngageAirWeapons = false
	Medusa.Services.BatteryActivationService.forceGoHot(b, 1000)
	lu.assertTrue(b.EngageAirWeapons)
	lu.assertEquals(eawWrites(b.GroupName), { true })
end

-- == Fire discipline ==

TestDecoyFireDiscipline = {}

local fdLog, fdInfo

function TestDecoyFireDiscipline:setUp()
	setupMocks()
	fdLog = {}
	fdInfo = env.info
	env.info = function(msg)
		fdLog[#fdLog + 1] = msg
	end
end

function TestDecoyFireDiscipline:tearDown()
	env.info = fdInfo
	restoreMocks()
end

local function fdLogged(text)
	for _, line in ipairs(fdLog) do
		if string.find(line, text, 1, true) then
			return true
		end
	end
	return false
end

--- A pass at time `now` where the battery's own fire-control radars are locked on `locked` (track ids).
local function lockPass(w, now, locked, polls)
	w.now = now
	local ctx = ctxOf(w)
	ctx.networkId = "RED"
	ctx.lockedTracksOf = function(b, out)
		if polls then
			polls[#polls + 1] = b.GroupName
		end
		local n = 0
		for _, id in ipairs(locked or {}) do
			n = n + 1
			out[n] = id
		end
		for i = n + 1, #out do
			out[i] = nil
		end
		return n
	end
	local tracks = w.trackStore:getAll()
	Assess.assess(ctx, tracks, #tracks)
	Response.update(ctx)
end

--- A probable decoy and an unidentified contact (a HARM, say) in reach: engage-air-weapons stays on.
local function harmAndDecoy(doctrine)
	local w = newWorld(doctrine)
	local b = addBattery(w)
	local decoy = addTrack(w, "probable")
	addTrack(w, "unknown", { Position = { x = -20000, y = 6000, z = 40000 } })
	return w, b, decoy
end

function TestDecoyFireDiscipline:test_a_lock_on_a_probable_decoy_holds_engage_air_weapons_off_for_the_hold()
	local w, b, decoy = harmAndDecoy()
	lockPass(w, 1000, {})
	lu.assertEquals(eawWrites(b.GroupName), {})
	local t0 = 1000 + D.FIRE_HOLD_LOCK_READ_SEC
	lockPass(w, t0, { decoy.TrackId })
	lu.assertEquals(eawWrites(b.GroupName), { false })
	lu.assertEquals(b.FireHold.Trigger, "lock")
	lu.assertTrue(fdLogged("ev=DECOY_FIRE_HOLD|battery=" .. b.GroupName .. "|track=" .. decoy.DisplayTrackId))
	lu.assertTrue(fdLogged("|trigger=lock|sec=" .. D.FIRE_HOLD_SEC .. "|n=1"))
	lockPass(w, t0 + D.FIRE_HOLD_SEC - 1, {})
	lu.assertEquals(eawWrites(b.GroupName), { false })
	lockPass(w, t0 + D.FIRE_HOLD_SEC, {})
	lu.assertEquals(eawWrites(b.GroupName), { false, true })
	lu.assertNil(b.FireHold)
end

function TestDecoyFireDiscipline:test_the_lock_is_read_at_most_every_few_seconds()
	local w, b, decoy = harmAndDecoy()
	local polls = {}
	lockPass(w, 1000, {}, polls)
	lockPass(w, 1000 + D.FIRE_HOLD_LOCK_READ_SEC - 1, { decoy.TrackId }, polls)
	lu.assertEquals(#polls, 1)
	lu.assertNil(b.FireHold)
	lockPass(w, 1000 + D.FIRE_HOLD_LOCK_READ_SEC, { decoy.TrackId }, polls)
	lu.assertEquals(#polls, 2)
	lu.assertNotNil(b.FireHold)
end

function TestDecoyFireDiscipline:test_holds_at_most_a_few_times_per_decoy_then_engages_it()
	local w, b, decoy = harmAndDecoy()
	local t = 1000
	for _ = 1, D.FIRE_HOLDS_PER_TRACK + 1 do
		lockPass(w, t, { decoy.TrackId })
		t = t + D.FIRE_HOLD_SEC
	end
	lockPass(w, t, { decoy.TrackId })
	lu.assertEquals(b.FireHoldCounts[decoy.TrackId], D.FIRE_HOLDS_PER_TRACK)
	lu.assertNil(b.FireHold)
	lu.assertTrue(b.EngageAirWeapons)
	-- another decoy still gets its holds (once the hold budget allows)
	local other = addTrack(w, "probable", { Position = { x = 25000, y = 6000, z = 48000 } })
	lockPass(w, t + D.FIRE_HOLD_BUDGET_WINDOW_SEC, { decoy.TrackId, other.TrackId })
	lu.assertEquals(b.FireHold.TrackId, other.TrackId)
end

function TestDecoyFireDiscipline:test_a_decoy_reacquired_under_a_new_track_keeps_its_hold_count()
	local w, b, decoy = harmAndDecoy()
	local t = 1000
	for _ = 1, D.FIRE_HOLDS_PER_TRACK do
		lockPass(w, t, { decoy.TrackId })
		t = t + D.FIRE_HOLD_SEC
	end
	-- TrackReacquisition copies the decoy assessment (lineage included) to the new track
	local again = addTrack(w, "probable", { Position = { x = 21000, y = 6000, z = 47000 } })
	for k, v in pairs(decoy.DecoyAssessment) do
		again.DecoyAssessment[k] = v
	end
	decoy.LifecycleState = "EXPIRED"
	local polls = {}
	lockPass(w, t + D.FIRE_HOLD_BUDGET_WINDOW_SEC, { again.TrackId }, polls)
	lu.assertNil(b.FireHold)
	lu.assertEquals(polls, {}, "no lock read with every decoy in reach out of holds")
	lu.assertEquals(b.DecoyReach.holdable, 0)
end

function TestDecoyFireDiscipline:test_holds_stay_within_their_budget()
	local w, b, decoy = harmAndDecoy()
	local decoys = { decoy }
	local t = 1000
	-- back-to-back holds up to the budget (each decoy at most its own count)
	for i = 1, D.FIRE_HOLD_BUDGET_SEC / D.FIRE_HOLD_SEC do
		local d = decoys[#decoys]
		if b.FireHoldCounts and b.FireHoldCounts[d.TrackId] == D.FIRE_HOLDS_PER_TRACK then
			d = addTrack(w, "probable", { Position = { x = 20000 + i * 500, y = 6000, z = 49000 } })
			decoys[#decoys + 1] = d
		end
		lockPass(w, t, { d.TrackId })
		lu.assertEquals(b.FireHold.TrackId, d.TrackId, "hold " .. i)
		t = t + D.FIRE_HOLD_SEC
	end
	local other = addTrack(w, "probable", { Position = { x = 25000, y = 6000, z = 48000 } })
	lockPass(w, t, { other.TrackId }) -- one more would pass the budget
	lu.assertNil(b.FireHold)
	-- free once the first hold has left the window that a new hold would close
	local free = 1000 + D.FIRE_HOLD_BUDGET_WINDOW_SEC
	lockPass(w, free - D.FIRE_HOLD_LOCK_READ_SEC, { other.TrackId })
	lu.assertNil(b.FireHold)
	lockPass(w, free, { other.TrackId })
	lu.assertEquals(b.FireHold.TrackId, other.TrackId)
end

function TestDecoyFireDiscipline:test_a_shot_at_a_probable_decoy_holds_after_the_write_settles()
	local w, b, decoy = harmAndDecoy()
	lockPass(w, 1000, {})
	local weapon = {}
	weaponAlive[weapon] = true
	local ctx = ctxOf(w)
	Response.recordLaunch(ctx, b, { Weapon = weapon, LaunchTime = 1000, TargetTrackId = decoy.TrackId, Guided = true })
	lu.assertEquals(b.FireHold.Trigger, "shot")
	lockPass(w, 1000 + D.EAW_WRITE_SETTLE_SEC - 1, {})
	lu.assertEquals(eawWrites(b.GroupName), {}, "no write right after a launch")
	lockPass(w, 1000 + D.EAW_WRITE_SETTLE_SEC, {})
	lu.assertEquals(eawWrites(b.GroupName), { false })
end

function TestDecoyFireDiscipline:test_waits_for_its_missile_at_a_contact_that_may_be_a_weapon()
	local w, b, decoy = harmAndDecoy()
	local harm = addTrack(w, "unknown", { Position = { x = -10000, y = 6000, z = 30000 } })
	local weapon = {}
	weaponAlive[weapon] = true
	b.MissilesInFlight = { { Weapon = weapon, LaunchTime = 900, TargetTrackId = harm.TrackId, Guided = true } }
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertNotNil(b.FireHold)
	lu.assertNil(b.FireHold.Until, "waiting: its time has not started")
	lu.assertFalse(fdLogged("ev=DECOY_FIRE_HOLD"))
	lu.assertEquals(eawWrites(b.GroupName), {})
	weaponAlive[weapon] = false
	lockPass(w, 1005, {})
	lu.assertEquals(eawWrites(b.GroupName), { false })
	lu.assertTrue(fdLogged("|n=1|waited=5"))
end

function TestDecoyFireDiscipline:test_a_hold_waiting_longer_than_its_time_starts_whole_when_the_option_goes_off()
	-- A deferred hold must not burn its time or count while engage-air-weapons stays on.
	local w, b, decoy = harmAndDecoy()
	local harm = addTrack(w, "unknown", { Position = { x = -10000, y = 6000, z = 30000 } })
	local weapon = {}
	weaponAlive[weapon] = true
	b.MissilesInFlight = { { Weapon = weapon, LaunchTime = 990, TargetTrackId = harm.TrackId, Guided = true } }
	lockPass(w, 1000, { decoy.TrackId })
	local wait = D.FIRE_HOLD_SEC + 5
	for t = 1001, 1000 + wait - 1 do
		lockPass(w, t, { decoy.TrackId })
	end
	lu.assertEquals(eawWrites(b.GroupName), {})
	lu.assertNil(b.FireHoldCounts, "no hold counted while waiting")
	lu.assertNil(b.FireHold.Until)
	weaponAlive[weapon] = false
	lockPass(w, 1000 + wait, {})
	lu.assertEquals(eawWrites(b.GroupName), { false })
	lu.assertEquals(b.FireHold.Until, 1000 + wait + D.FIRE_HOLD_SEC)
	lu.assertEquals(b.FireHoldCounts[decoy.TrackId], 1)
	lockPass(w, 1000 + wait + D.FIRE_HOLD_SEC - 1, {})
	lu.assertEquals(eawWrites(b.GroupName), { false })
	lockPass(w, 1000 + wait + D.FIRE_HOLD_SEC, {})
	lu.assertEquals(eawWrites(b.GroupName), { false, true })
end

function TestDecoyFireDiscipline:test_a_salvo_at_a_decoy_under_a_hold_counts_once()
	local w, b, decoy = harmAndDecoy()
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertEquals(b.FireHoldCounts[decoy.TrackId], 1)
	local hold = b.FireHold
	for i = 1, 3 do
		Response.recordLaunch(ctxOf(w), b, { Weapon = { i }, LaunchTime = 1000, TargetTrackId = decoy.TrackId })
	end
	lu.assertIs(b.FireHold, hold)
	lu.assertEquals(b.FireHoldCounts[decoy.TrackId], 1)
end

function TestDecoyFireDiscipline:test_an_anti_radiation_missile_in_its_last_run_neither_blocks_nor_ends_a_hold()
	-- HARMs are left to the HARM shutdown response and point defence: measured in DCS, stopping holds in an ARM's last
	-- 30 s let an SA-10 fire 10 missiles at decoys in that time and none at the ARMs.
	local w, b, decoy = harmAndDecoy()
	local arm = addTrack(w, "unknown", {
		Position = { x = 0, y = 6000, z = 600 * 25 },
		Velocity = { x = 0, y = 0, z = -600 },
		AssessedAircraftType = "HARM",
	})
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertNotNil(b.FireHold)
	lu.assertEquals(eawWrites(b.GroupName), { false })
	arm.Position = { x = 0, y = 6000, z = 600 * 5 }
	lockPass(w, 1001, {})
	lu.assertNotNil(b.FireHold)
	lockPass(w, 1000 + D.FIRE_HOLD_SEC, {})
	lu.assertNil(b.FireHold)
	lu.assertEquals(eawWrites(b.GroupName), { false, true })
	lu.assertEquals(#b.FireHoldSpans, 1, "a hold that ran its time stays on the budget")
end

function TestDecoyFireDiscipline:test_a_hold_ends_early_when_its_decoy_is_no_longer_held_against()
	local w, b, decoy = harmAndDecoy()
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertNotNil(b.FireHold)
	decoy.DecoyAssessment.label = "AIRCRAFT"
	lockPass(w, 1001, {})
	lu.assertNil(b.FireHold)
	lu.assertEquals(eawWrites(b.GroupName), { false, true })
	lu.assertTrue(fdLogged("decoy no longer held against"))
end

function TestDecoyFireDiscipline:test_no_hold_during_a_test_shot()
	local w, b, decoy = harmAndDecoy()
	b.TestShotHold = { Since = 1000, TargetTrackId = "X" }
	lockPass(w, 1000, { decoy.TrackId })
	Response.recordLaunch(ctxOf(w), b, { Weapon = {}, LaunchTime = 1000, TargetTrackId = decoy.TrackId })
	lu.assertNil(b.FireHold)
	lu.assertNil(b.FireHoldCounts)
end

function TestDecoyFireDiscipline:test_a_test_shot_missile_flying_when_the_option_goes_off_teaches_nothing()
	-- Medusa's own engage-air-weapons write may end a test-shot missile; that is no lost guidance.
	for _, manage in ipairs({ false, true }) do
		setupMocks()
		local w = newWorld({ ManageEngageAirWeapons = manage })
		local b = addBattery(w)
		local decoy = addTrack(w, "probable")
		local weapon = {}
		weaponAlive[weapon] = true
		weaponPoint[weapon] = { x = 20000, y = 6000, z = 0 } -- 50 km from the decoy
		weaponVelocity[weapon] = { x = 0, y = 0, z = -1000 } -- flying away from it
		b.MissilesInFlight = {
			{
				Weapon = weapon,
				LaunchTime = 990,
				TargetTrackId = decoy.TrackId,
				Guided = true,
				TestShot = true,
				LauncherType = "SA-11 Buk LN 9A310M1",
			},
		}
		decoy.LastDetectionTime = 1000
		lockPass(w, 1000, {})
		weaponAlive[weapon] = false
		decoy.LastDetectionTime = 1001
		lockPass(w, 1001, {})
		if manage then
			lu.assertEquals(eawWrites(b.GroupName), { false })
			lu.assertNil(b.HoldBreaksGuidance)
			lu.assertNil(w.holdBreaksTypes["SA-11 Buk LN 9A310M1"])
		else
			lu.assertTrue(b.HoldBreaksGuidance, "control: without the write the missile lost guidance")
		end
	end
end

function TestDecoyFireDiscipline:test_a_full_list_drops_a_flight_the_guard_does_not_need()
	-- The guard must not forget a missile at a contact that may be a weapon.
	local w = newWorld()
	local b = addBattery(w)
	local harm = addTrack(w, "unknown", { Position = { x = -10000, y = 6000, z = 30000 } })
	local jet = addTrack(w, "aircraft")
	local atHarm = { Weapon = {}, LaunchTime = 990, TargetTrackId = harm.TrackId, Guided = true }
	b.MissilesInFlight = { atHarm }
	for i = 1, D.MAX_MISSILES_IN_FLIGHT do
		Response.recordLaunch(ctxOf(w), b, { Weapon = { i }, LaunchTime = 1000, TargetTrackId = jet.TrackId })
	end
	lu.assertEquals(#b.MissilesInFlight, D.MAX_MISSILES_IN_FLIGHT)
	lu.assertIs(b.MissilesInFlight[1], atHarm)
	lu.assertIs(Response._missileAtWeapon(ctxOf(w), b), atHarm)
end

function TestDecoyFireDiscipline:test_a_missile_at_a_decoy_gliding_onto_the_battery_keeps_the_guard_and_its_place()
	-- A decoy whose glide ends at the battery is a weapon to it: switching engage-air-weapons off could end that missile.
	local w = newWorld()
	local b = addBattery(w)
	local diving = divingAtOrigin(w)
	local passing = addTrack(w, "probable")
	local atDiving = { Weapon = {}, LaunchTime = 990, TargetTrackId = diving.TrackId, Guided = true }
	b.MissilesInFlight = { atDiving }
	lu.assertIs(Response._missileAtWeapon(ctxOf(w), b), atDiving)
	b.MissilesInFlight = { { Weapon = {}, LaunchTime = 990, TargetTrackId = passing.TrackId, Guided = true } }
	lu.assertNil(Response._missileAtWeapon(ctxOf(w), b), "a decoy passing by is no weapon to the battery")
	b.MissilesInFlight = { atDiving }
	for i = 1, D.MAX_MISSILES_IN_FLIGHT do
		Response.recordLaunch(ctxOf(w), b, { Weapon = { i }, LaunchTime = 1000, TargetTrackId = passing.TrackId })
	end
	lu.assertIs(b.MissilesInFlight[1], atDiving, "a full list drops a flight at a decoy passing by first")
end

function TestDecoyFireDiscipline:test_a_hold_is_counted_only_once_engage_air_weapons_is_written()
	local w, b, decoy = harmAndDecoy()
	local controller = GetGroupController
	GetGroupController = function()
		return nil
	end
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertEquals(eawWrites(b.GroupName), {})
	lu.assertNotNil(b.FireHold)
	lu.assertNil(b.FireHold.Until, "not written: still waiting")
	lu.assertNil(b.FireHoldCounts)
	lu.assertNil(b.FireHoldSpans)
	lu.assertFalse(fdLogged("ev=DECOY_FIRE_HOLD"))
	GetGroupController = controller
	lockPass(w, 1001, {})
	lu.assertEquals(eawWrites(b.GroupName), { false })
	lu.assertEquals(b.FireHoldCounts[decoy.TrackId], 1)
	lu.assertEquals(b.FireHold.Until, 1001 + D.FIRE_HOLD_SEC)
end

function TestDecoyFireDiscipline:test_a_hold_released_to_dcs_stops_counting_against_the_budget()
	local w, b, decoy = harmAndDecoy()
	lockPass(w, 1000, { decoy.TrackId })
	local span = b.FireHold.Span
	lu.assertNil(span.e)
	GetTime = function()
		return 1005
	end
	Medusa.Services.BatteryActivationService.releaseDecoyResponse(b)
	lu.assertNil(b.FireHold)
	lu.assertEquals(span.e, 1005)
end

function TestDecoyFireDiscipline:test_a_write_kept_waiting_by_ripple_fire_is_logged_once()
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "probable")
	for t = 1000, 1000 + D.EAW_WRITE_STARVED_SEC + 2 do
		b.LastLaunchAt = t
		lockPass(w, t, {})
	end
	lu.assertEquals(eawWrites(b.GroupName), {})
	local n = 0
	for _, line in ipairs(fdLog) do
		if string.find(line, "waits: it has launched less than", 1, true) then
			n = n + 1
		end
	end
	lu.assertEquals(n, 1)
	lockPass(w, 1000 + D.EAW_WRITE_STARVED_SEC + 2 + D.EAW_WRITE_SETTLE_SEC, {})
	lu.assertEquals(eawWrites(b.GroupName), { false })
end

function TestDecoyFireDiscipline:test_going_hot_or_release_right_after_a_launch_waits_to_write()
	-- No engage-air-weapons write within the settle time of a launch, from any path.
	local BAS = Medusa.Services.BatteryActivationService
	local w = newWorld()
	local b = addBattery(w, { ActivationState = "STATE_WARM" })
	b.EngageAirWeapons = false
	b.LastLaunchAt = 1000 - D.EAW_WRITE_SETTLE_SEC / 2
	BAS.forceGoHot(b, 1000)
	lu.assertEquals(eawWrites(b.GroupName), {})
	local scheduled
	local savedSchedule = ScheduleOnce
	ScheduleOnce = function(fn, _, delay)
		scheduled = { fn = fn, delay = delay }
	end
	local ok, err = pcall(BAS.releaseDecoyResponse, b)
	ScheduleOnce = savedSchedule
	assert(ok, err)
	lu.assertEquals(eawWrites(b.GroupName), {})
	lu.assertAlmostEquals(scheduled.delay, D.EAW_WRITE_SETTLE_SEC / 2, 1e-6)
	scheduled.fn()
	lu.assertEquals(eawWrites(b.GroupName), { true })
end

function TestDecoyFireDiscipline:test_no_hold_against_a_decoy_whose_glide_ends_at_the_battery()
	local w = newWorld()
	local b = addBattery(w)
	local decoy = divingAtOrigin(w)
	addTrack(w, "unknown", { Position = { x = -20000, y = 6000, z = 40000 } })
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertNil(b.FireHold)
	lu.assertEquals(eawWrites(b.GroupName), {})
end

function TestDecoyFireDiscipline:test_a_decoy_flying_over_the_battery_to_something_behind_is_held_against()
	local w = newWorld()
	local b = addBattery(w)
	local decoy = addTrack(w, "probable", { Position = { x = 2600, y = 6000, z = 30000 } })
	addTrack(w, "unknown", { Position = { x = -20000, y = 6000, z = 40000 } })
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertEquals(b.FireHold.TrackId, decoy.TrackId)
	lu.assertEquals(eawWrites(b.GroupName), { false })
end

function TestDecoyFireDiscipline:test_switches_off_point_defence_and_shorad_make_no_holds()
	for _, doctrine in ipairs({ { DecoyFireDiscipline = false }, { ManageEngageAirWeapons = false } }) do
		setupMocks()
		local w, b, decoy = harmAndDecoy(doctrine)
		lockPass(w, 1000, { decoy.TrackId })
		Response.recordLaunch(ctxOf(w), b, { Weapon = {}, LaunchTime = 1000, TargetTrackId = decoy.TrackId })
		lu.assertNil(b.FireHold)
		lu.assertEquals(eawWrites(b.GroupName), {})
	end
	setupMocks()
	local w = newWorld()
	local sr = addBattery(w, { Role = "SR_SAM" })
	local pd = addBattery(w, { Role = "MR_SAM", IsPointDefense = true })
	local decoy = addTrack(w, "probable")
	addTrack(w, "unknown", { Position = { x = -20000, y = 6000, z = 40000 } })
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertNil(sr.FireHold)
	lu.assertNil(pd.FireHold)
end

function TestDecoyFireDiscipline:test_reads_the_lock_only_with_a_probable_decoy_in_reach_and_no_hold()
	local w = newWorld()
	local b = addBattery(w)
	addTrack(w, "unknown", { Position = { x = -20000, y = 6000, z = 40000 } })
	local polls = {}
	lockPass(w, 1000, {}, polls)
	lu.assertEquals(polls, {})
	local decoy = addTrack(w, "probable")
	lockPass(w, 1001, { decoy.TrackId }, polls)
	lockPass(w, 1002, { decoy.TrackId }, polls)
	lu.assertEquals(polls, { b.GroupName })
end

function TestDecoyFireDiscipline:test_a_hold_ends_when_the_battery_leaves_hot()
	local w, b, decoy = harmAndDecoy()
	lockPass(w, 1000, { decoy.TrackId })
	lu.assertNotNil(b.FireHold)
	b.ActivationState = "STATE_WARM"
	lockPass(w, 1001, {})
	lu.assertNil(b.FireHold)
end

-- == Test shot ==

TestDecoyTestShot = {}

function TestDecoyTestShot:setUp()
	setupMocks()
end

function TestDecoyTestShot:tearDown()
	restoreMocks()
end

local function launch(w, b, target, launcherType)
	local weapon = {}
	weaponAlive[weapon] = true
	Response.recordLaunch(ctxOf(w), b, {
		Weapon = weapon,
		LaunchTime = w.now,
		TargetTrackId = target and target.TrackId,
		Guided = true,
		LauncherType = launcherType,
	})
	return weapon
end

local function roeWrites(group)
	local out = {}
	for _, c in ipairs(calls.roe) do
		if c.group == group then
			out[#out + 1] = c.value
		end
	end
	return out
end

function TestDecoyTestShot:test_holds_fire_after_a_launch_at_a_lone_suspect_group_and_resumes_when_the_flight_ends()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = addTrack(w, "suspect")
	local s2 = addTrack(w, "suspect", { Position = { x = 21500, y = 6000, z = 50000 } })
	local weapon = launch(w, b, s1)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD" })
	lu.assertNotNil(b.TestShotHold)
	lu.assertEquals(s2.DecoyAssessment.testedAt, 1000)
	w.now = 1020
	pass(w)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD" })
	weaponAlive[weapon] = false
	w.now = 1040
	pass(w)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
	lu.assertNil(b.TestShotHold)
	-- one shot per group: a second launch at it is not a test shot
	launch(w, b, s2)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
end

function TestDecoyTestShot:test_no_hold_with_anything_else_in_reach()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = addTrack(w, "suspect")
	addTrack(w, "unknown", { Position = { x = 30000, y = 6000, z = 30000 } })
	launch(w, b, s1)
	lu.assertEquals(roeWrites(b.GroupName), {})
end

function TestDecoyTestShot:test_no_hold_at_a_probable_decoy_or_an_aircraft()
	local w = newWorld()
	local b = addBattery(w)
	launch(w, b, addTrack(w, "probable"))
	local w2 = newWorld()
	local b2 = addBattery(w2)
	launch(w2, b2, addTrack(w2, "unknown"))
	lu.assertEquals(roeWrites(b.GroupName), {})
	lu.assertEquals(roeWrites(b2.GroupName), {})
end

function TestDecoyTestShot:test_no_hold_when_the_contact_arrives_before_the_flight_plus_margin()
	local w = newWorld()
	local b = addBattery(w)
	-- 12 km out at 400 m/s: 30 s to arrive, missile flight 15 s + 30 s margin
	local s1 =
		addTrack(w, "suspect", { Position = { x = 0, y = 6000, z = 12000 }, Velocity = { x = 0, y = 0, z = -400 } })
	launch(w, b, s1)
	lu.assertEquals(roeWrites(b.GroupName), {})
end

function TestDecoyTestShot:test_no_hold_below_the_missile_reserve_or_when_switched_off()
	local w = newWorld()
	local b = addBattery(w, { TotalAmmoStatus = D.TEST_SHOT_MIN_AMMO - 1 })
	launch(w, b, addTrack(w, "suspect"))
	local w2 = newWorld({ DecoyTestShots = false })
	local b2 = addBattery(w2)
	launch(w2, b2, addTrack(w2, "suspect"))
	lu.assertEquals(roeWrites(b.GroupName), {})
	lu.assertEquals(roeWrites(b2.GroupName), {})
end

function TestDecoyTestShot:test_hold_ends_early_when_another_contact_comes_into_reach()
	local w = newWorld()
	local b = addBattery(w)
	launch(w, b, addTrack(w, "suspect"))
	addTrack(w, "aircraft", { Position = { x = 20000, y = 6000, z = 20000 } })
	w.now = 1005
	pass(w)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
end

function TestDecoyTestShot:test_hold_ends_when_the_target_is_no_longer_a_suspect_decoy()
	for _, change in ipairs({ "behaviour", "sighting" }) do
		setupMocks()
		local w = newWorld()
		local b = addBattery(w)
		local s1 = addTrack(w, "suspect")
		launch(w, b, s1)
		if change == "behaviour" then
			s1.DecoyAssessment.label = "AIRCRAFT"
			s1.DecoyAssessment.aircraftEvidence = "energy gain"
		else
			s1.SeenAs = "AIRCRAFT"
		end
		w.now = 1005
		pass(w)
		lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" }, change)
	end
end

function TestDecoyTestShot:test_no_hold_when_the_contact_passes_inside_minimum_range_before_the_flight_plus_margin()
	local w = newWorld()
	local b = addBattery(w, { EngagementRangeMin = 8000 })
	-- 20 km out at 300 m/s: 67 s to the battery but 40 s to its 8 km inner edge; missile flight 25 s + 30 s margin
	local s1 =
		addTrack(w, "suspect", { Position = { x = 0, y = 6000, z = 20000 }, Velocity = { x = 0, y = 0, z = -300 } })
	launch(w, b, s1)
	lu.assertEquals(roeWrites(b.GroupName), {})
end

function TestDecoyTestShot:test_a_full_list_keeps_the_test_shot_flight_and_its_hold()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = addTrack(w, "suspect")
	launch(w, b, s1)
	local first = b.MissilesInFlight[1]
	for _ = 1, D.MAX_MISSILES_IN_FLIGHT do
		launch(w, b, nil)
	end
	lu.assertNotNil(b.TestShotHold)
	lu.assertIs(b.MissilesInFlight[1], first)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD" })
	lu.assertEquals(#b.MissilesInFlight, D.MAX_MISSILES_IN_FLIGHT)
end

function TestDecoyTestShot:test_a_flight_dropped_from_a_full_list_of_test_shots_ends_its_hold_unjudged()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = addTrack(w, "suspect")
	launch(w, b, s1)
	for i = 2, D.MAX_MISSILES_IN_FLIGHT do
		b.MissilesInFlight[i] = { Weapon = { i }, LaunchTime = 1000, TestShot = true }
	end
	launch(w, b, nil)
	lu.assertNil(b.TestShotHold)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
	lu.assertEquals(#b.MissilesInFlight, D.MAX_MISSILES_IN_FLIGHT)
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, 0)
end

function TestDecoyTestShot:test_an_earlier_missile_ending_leaves_the_test_shot_hold_in_place()
	-- Timings measured in DCS: the battery's earlier missile (310.8, another target) ends at 317.5, during the hold for
	-- its test shot (315.7); only the test-shot missile's own end releases it. DCS weapon wrappers compare equal by
	-- id_ (Scripts/Common/LuaClass.lua __eq), so the mock ones do too.
	local dcsWeapon = {
		__eq = function(a, b)
			return a.id_ == b.id_
		end,
	}
	local function fire(w, b, id, target)
		local weapon = setmetatable({ id_ = id }, dcsWeapon)
		weaponAlive[weapon] = true
		Response.recordLaunch(
			ctxOf(w),
			b,
			{ Weapon = weapon, LaunchTime = w.now, TargetTrackId = target and target.TrackId, Guided = true }
		)
		return weapon
	end
	local w = newWorld()
	local b = addBattery(w)
	local s1 = addTrack(w, "suspect")
	w.now = 310.8
	local earlier = fire(w, b, 16868865, nil)
	w.now = 315.7
	local testShot = fire(w, b, 16870401, s1)
	lu.assertNotNil(b.TestShotHold)
	weaponAlive[earlier] = false
	w.now = 317.5
	pass(w)
	lu.assertNotNil(b.TestShotHold)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD" })
	weaponAlive[testShot] = false
	w.now = 318.5
	pass(w)
	lu.assertNil(b.TestShotHold)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
end

function TestDecoyTestShot:test_hold_never_outlasts_its_time_limit()
	local w = newWorld()
	local b = addBattery(w)
	launch(w, b, addTrack(w, "suspect"))
	w.now = 1000 + D.TEST_SHOT_MAX_HOLD_SEC + 1
	pass(w)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
end

function TestDecoyTestShot:test_a_battery_that_left_hot_is_not_reopened()
	local w = newWorld()
	local b = addBattery(w)
	local weapon = launch(w, b, addTrack(w, "suspect"))
	b.ActivationState = "STATE_COLD"
	w.now = 1010
	pass(w)
	lu.assertNil(b.TestShotHold) -- cleared at once, its missile still in flight
	weaponAlive[weapon] = false
	w.now = 1030
	pass(w)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD" })
end

function TestDecoyTestShot:test_a_battery_released_to_dcs_ai_gets_engage_air_weapons_back()
	local w = newWorld()
	local b = addBattery(w)
	local BAS = Medusa.Services.BatteryActivationService
	BAS.releaseDecoyResponse(b) -- never switched by Medusa: the mission's own setting stays
	lu.assertEquals(eawWrites(b.GroupName), {})
	BAS.setEngageAirWeapons(b, false)
	b.TestShotHold = { Since = 0 }
	Medusa.Entities.Battery.applyDegradedBehavior(b, "SEARCH_LOST_CP_ALIVE", { trackStore = w.trackStore })
	lu.assertEquals(eawWrites(b.GroupName), { false, true })
	lu.assertNil(b.TestShotHold)
	BAS.setEngageAirWeapons(b, false)
	BAS.goAutonomous(b, nil, nil, w.trackStore)
	lu.assertEquals(eawWrites(b.GroupName), { false, true, false, true })
end

-- == Missile lost under the test-shot hold ==

TestDecoyHoldBreaksGuidance = {}

function TestDecoyHoldBreaksGuidance:setUp()
	setupMocks()
end

function TestDecoyHoldBreaksGuidance:tearDown()
	restoreMocks()
end

--- A suspect flying south at 200 m/s, seen 970..1010, ending 42 km north of the origin; it never reacts.
local function straightSuspect(w)
	local s1 = addTrack(w, "suspect")
	for i = 0, 8 do
		Medusa.Entities.Track.update(
			s1,
			{ x = 0, y = 6000, z = 50000 - i * 1000 },
			{ x = 0, y = 0, z = -200 },
			970 + i * 5
		)
	end
	return s1
end

--- A test shot at 975; its missile is sampled at 1009 at point/velocity and its flight ends at 1010.
local function heldShotEndingAt(w, b, s1, point, velocity)
	w.now = 975
	local weapon = launch(w, b, s1)
	lu.assertNotNil(b.TestShotHold)
	weaponPoint[weapon] = point
	weaponVelocity[weapon] = velocity
	w.now = 1009
	pass(w)
	weaponAlive[weapon] = false
	w.now = 1010
	pass(w)
	return weapon
end

function TestDecoyHoldBreaksGuidance:test_a_held_missile_ending_far_from_its_live_target_is_no_evidence_and_ends_test_shots()
	-- Measured in DCS (SA-11): held 0.5 s after launch, the missile ended 22 s later 17.9 km from its target
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	heldShotEndingAt(w, b, s1, { x = 0, y = 3000, z = 24000 }, { x = 0, y = 0, z = 400 })
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, 0)
	lu.assertTrue(b.HoldBreaksGuidance)
	lu.assertNil(b.TestShotHold)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
	-- past the group's cooldown a launch at it is no test shot for this battery
	w.now = 1010 + D.TEST_SHOT_COOLDOWN_SEC + 1
	launch(w, b, s1)
	lu.assertNil(b.TestShotHold)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
	-- the same launch by an unmarked battery would be one
	b.HoldBreaksGuidance = nil
	w.now = w.now + D.TEST_SHOT_COOLDOWN_SEC + 1
	launch(w, b, s1)
	lu.assertNotNil(b.TestShotHold)
end

function TestDecoyHoldBreaksGuidance:test_a_held_missile_ending_at_its_target_gives_unanswered_launch_evidence()
	local cases = {
		close = { point = { x = 0, y = 6000, z = 41500 }, velocity = { x = 0, y = 0, z = 800 } },
		-- a fast missile still 2.6 km short at the last sample, one second before its flight ended
		fast = { point = { x = 0, y = 5000, z = 39500 }, velocity = { x = 0, y = 0, z = 1800 } },
		["not sampled"] = {},
	}
	for name, c in pairs(cases) do
		setupMocks()
		local w = newWorld()
		local b = addBattery(w)
		local s1 = straightSuspect(w)
		heldShotEndingAt(w, b, s1, c.point, c.velocity)
		lu.assertEquals(s1.DecoyAssessment.launchEvidence, D.LAUNCH_EVIDENCE_TARGET_SEC, name)
		lu.assertNil(b.HoldBreaksGuidance, name)
		lu.assertNil(b.TestShotHold, name)
		lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" }, name)
	end
end

function TestDecoyHoldBreaksGuidance:test_a_held_missile_ending_far_from_a_target_no_longer_tracked_marks_nothing()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	w.now = 975
	local weapon = launch(w, b, s1)
	weaponPoint[weapon] = { x = 0, y = 3000, z = 24000 }
	weaponVelocity[weapon] = { x = 0, y = 0, z = 400 }
	w.now = 1009
	pass(w)
	s1.LifecycleState = "STALE"
	weaponAlive[weapon] = false
	w.now = 1010
	pass(w)
	lu.assertNil(b.HoldBreaksGuidance)
	lu.assertNil(b.TestShotHold)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
end

function TestDecoyHoldBreaksGuidance:test_a_flight_not_under_a_hold_is_judged_wherever_its_missile_ends()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	local weapon = {}
	weaponAlive[weapon] = true
	weaponPoint[weapon] = { x = 0, y = 3000, z = 24000 }
	weaponVelocity[weapon] = { x = 0, y = 0, z = 400 }
	b.MissilesInFlight = { { Weapon = weapon, LaunchTime = 975, TargetTrackId = s1.TrackId, Guided = true } }
	w.now = 1009
	pass(w)
	weaponAlive[weapon] = false
	w.now = 1010
	pass(w)
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, D.LAUNCH_EVIDENCE_TARGET_SEC)
	lu.assertNil(b.HoldBreaksGuidance)
end

--- A suspect flying south at 200 m/s, seen every 5 s from 970 to `last`.
local function suspectSeenUntil(w, last)
	local s1 = addTrack(w, "suspect")
	for i = 0, 8 do
		local t = 970 + i * 5
		if t <= last then
			Medusa.Entities.Track.update(s1, { x = 0, y = 6000, z = 50000 - i * 1000 }, { x = 0, y = 0, z = -200 }, t)
		end
	end
	return s1
end

function TestDecoyHoldBreaksGuidance:test_a_hold_that_ended_early_still_judges_its_missile_as_a_test_shot()
	-- The hold ends when another contact comes into reach; the SA-11 missile it held is still lost under it.
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	w.now = 975
	local weapon = launch(w, b, s1)
	addTrack(w, "aircraft", { Position = { x = 20000, y = 6000, z = 20000 } })
	w.now = 980
	pass(w)
	lu.assertNil(b.TestShotHold)
	lu.assertEquals(roeWrites(b.GroupName), { "WEAPON_HOLD", "OPEN_FIRE" })
	weaponPoint[weapon] = { x = 0, y = 3000, z = 24000 }
	weaponVelocity[weapon] = { x = 0, y = 0, z = 400 }
	w.now = 1009
	pass(w)
	weaponAlive[weapon] = false
	w.now = 1010
	pass(w)
	lu.assertTrue(b.HoldBreaksGuidance)
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, 0)
end

function TestDecoyHoldBreaksGuidance:test_no_verdict_when_the_target_was_not_seen_near_the_missiles_last_sample()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = suspectSeenUntil(w, 1000) -- last seen 9 s before the missile's last sample
	heldShotEndingAt(w, b, s1, { x = 0, y = 3000, z = 24000 }, { x = 0, y = 0, z = 400 })
	lu.assertNil(b.HoldBreaksGuidance)
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, 0)
	lu.assertNil(b.TestShotHold)
end

function TestDecoyHoldBreaksGuidance:test_a_target_seen_one_search_scan_before_the_last_sample_still_gives_a_verdict()
	-- An SA-11 is no multi-target engagement radar: its acquisition radar refreshes tracks every 5 s (SAM_SEARCH).
	local w = newWorld()
	local b = addBattery(w)
	local s1 = suspectSeenUntil(w, 1005) -- last seen 4 s before the missile's last sample
	heldShotEndingAt(w, b, s1, { x = 0, y = 3000, z = 24000 }, { x = 0, y = 0, z = 400 })
	lu.assertTrue(b.HoldBreaksGuidance)
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, 0)
end

function TestDecoyHoldBreaksGuidance:test_no_verdict_when_the_target_proved_an_aircraft_during_the_flight()
	-- A jet may defeat the missile: a miss is then no proof the hold broke its guidance.
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	w.now = 975
	local weapon = launch(w, b, s1)
	s1.SeenAs = "AIRCRAFT"
	weaponPoint[weapon] = { x = 0, y = 3000, z = 24000 }
	weaponVelocity[weapon] = { x = 0, y = 0, z = 400 }
	w.now = 1009
	pass(w)
	weaponAlive[weapon] = false
	w.now = 1010
	pass(w)
	lu.assertNil(b.HoldBreaksGuidance)
	lu.assertNil(next(w.holdBreaksTypes))
end

function TestDecoyHoldBreaksGuidance:test_no_verdict_when_the_missile_was_about_to_reach_its_target()
	-- Measured in DCS (SA-11): missiles still 3-4.5 km out, 2-3.5 s to go, when their target died first: not a lost
	-- guidance.
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	heldShotEndingAt(w, b, s1, { x = 0, y = 6000, z = 38000 }, { x = 0, y = 0, z = 1000 })
	lu.assertNil(b.HoldBreaksGuidance)
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, 0)
end

function TestDecoyHoldBreaksGuidance:test_a_held_missile_flying_away_from_its_target_is_lost_under_the_hold()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	heldShotEndingAt(w, b, s1, { x = 0, y = 3000, z = 24000 }, { x = 0, y = -50, z = -300 })
	lu.assertTrue(b.HoldBreaksGuidance)
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, 0)
end

function TestDecoyHoldBreaksGuidance:test_a_test_shot_still_flying_at_the_flight_limit_is_no_lost_guidance()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	w.now = 975
	local weapon = launch(w, b, s1)
	weaponPoint[weapon] = { x = 0, y = 3000, z = 24000 }
	weaponVelocity[weapon] = { x = 0, y = 0, z = 400 }
	w.now = 1009
	pass(w)
	-- the weapon still exists; the flight is only taken as over
	w.now = 975 + D.MAX_FLIGHT_SEC + 1
	Medusa.Entities.Track.update(s1, { x = 0, y = 6000, z = 41500 }, { x = 0, y = 0, z = -200 }, w.now)
	weaponPoint[weapon] = nil
	pass(w)
	lu.assertNil(b.HoldBreaksGuidance)
end

function TestDecoyHoldBreaksGuidance:test_a_lost_shot_frees_the_group_for_another_batterys_test_shot()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	heldShotEndingAt(w, b, s1, { x = 0, y = 3000, z = 24000 }, { x = 0, y = 0, z = 400 })
	lu.assertTrue(b.HoldBreaksGuidance)
	lu.assertNil(s1.DecoyAssessment.testedAt)
	local other = addBattery(w, { Position = { x = 5000, y = 0, z = 0 } })
	launch(w, other, s1)
	lu.assertNotNil(other.TestShotHold)
end

function TestDecoyHoldBreaksGuidance:test_the_network_learns_hold_breaks_guidance_by_launcher_type()
	local SA11 = "SA-11 Buk LN 9A310M1"
	local w = newWorld()
	local b = addBattery(w)
	local s1 = straightSuspect(w)
	w.now = 975
	local weapon = launch(w, b, s1, SA11)
	weaponPoint[weapon] = { x = 0, y = 3000, z = 24000 }
	weaponVelocity[weapon] = { x = 0, y = 0, z = 400 }
	w.now = 1009
	pass(w)
	weaponAlive[weapon] = false
	w.now = 1010
	pass(w)
	lu.assertTrue(w.holdBreaksTypes[SA11])
	-- another battery of the network with the same launcher makes no test shot (its launch, judged as any unheld
	-- flight, counts as the group's test) ...
	local sameType = addBattery(w, { Position = { x = 5000, y = 0, z = 0 } })
	launch(w, sameType, s1, SA11)
	lu.assertNil(sameType.TestShotHold)
	lu.assertEquals(roeWrites(sameType.GroupName), {})
	-- ... one with another launcher still does (same network, a fresh suspect group)
	local w2 = newWorld()
	w2.holdBreaksTypes = w.holdBreaksTypes
	local otherType = addBattery(w2)
	launch(w2, otherType, addTrack(w2, "suspect"), "Hawk ln")
	lu.assertNotNil(otherType.TestShotHold)
end

-- == Unanswered launches through the flight bookkeeping ==

TestDecoyFlights = {}

function TestDecoyFlights:setUp()
	setupMocks()
end

function TestDecoyFlights:tearDown()
	restoreMocks()
end

function TestDecoyFlights:test_a_crew_guided_flight_ending_judges_its_target()
	local w = newWorld()
	local b = addBattery(w)
	local s1 = addTrack(w, "suspect")
	for i = 0, 8 do
		Medusa.Entities.Track.update(
			s1,
			{ x = 0, y = 6000, z = 50000 - i * 1000 },
			{ x = 0, y = 0, z = -200 },
			970 + i * 5
		)
	end
	local weapon = {}
	weaponAlive[weapon] = true
	b.MissilesInFlight = { { Weapon = weapon, LaunchTime = 975, TargetTrackId = s1.TrackId, Guided = true } }
	weaponAlive[weapon] = false
	w.now = 1010
	pass(w)
	lu.assertEquals(s1.DecoyAssessment.launchEvidence, D.LAUNCH_EVIDENCE_TARGET_SEC)
	lu.assertEquals(#b.MissilesInFlight, 0)
end

-- == Effects on assignment, point defence ==

TestDecoyEffects = {}

function TestDecoyEffects:setUp()
	setupMocks()
end

function TestDecoyEffects:tearDown()
	restoreMocks()
end

function TestDecoyEffects:test_suspect_threat_value_is_halved()
	local w = newWorld()
	local plain = addTrack(w, "unknown")
	local suspect = addTrack(w, "suspect")
	local TA = Medusa.Services.TargetAssigner
	lu.assertAlmostEquals(TA.computeThreatValue(suspect), TA.computeThreatValue(plain) / 2, 1e-9)
end

local function pairsFor(w)
	local ctx = ctxOf(w)
	local results = {}
	local assignments = Medusa.Services.TargetAssigner.assignTargets(ctx)
	for _, a in ipairs(assignments) do
		results[a.batteryId] = a.trackId
	end
	return results
end

function TestDecoyEffects:test_probable_decoy_is_not_assigned_to_long_range_sams_but_is_to_short_range()
	local w = newWorld({ ROE = "FREE" })
	local lr =
		addBattery(w, { ActivationState = "STATE_COLD", Role = "LR_SAM", PkRangeOptimal = 30000, PkRangeSigma = 20000 })
	local probable = addTrack(w, "probable", { Position = { x = 0, y = 6000, z = 30000 } })
	local assigned = pairsFor(w)
	lu.assertNil(assigned[lr.BatteryId])
	local w2 = newWorld({ ROE = "FREE" })
	local sr = addBattery(w2, {
		ActivationState = "STATE_COLD",
		Role = "SR_SAM",
		EngagementRangeMax = 40000,
		PkRangeOptimal = 30000,
		PkRangeSigma = 20000,
	})
	local p2 = addTrack(w2, "probable", { Position = { x = 0, y = 6000, z = 30000 } })
	lu.assertEquals(pairsFor(w2)[sr.BatteryId], p2.TrackId)
	lu.assertNotNil(probable)
end

function TestDecoyEffects:test_long_range_battery_engaging_a_track_that_turns_probable_is_released()
	local w = newWorld()
	local lr = addBattery(w)
	local t = addTrack(w, "probable")
	lr.CurrentTargetTrackId = t.TrackId
	local ctx = ctxOf(w)
	local result = Medusa.Services.TargetAssigner.checkSingleDeactivation(lr, ctx)
	lu.assertNotNil(result)
	lu.assertStrContains(result.reason, "probable decoy")
end

--- A battery protected by a point-defence battery, both cold, the provider forced viable; returns protected, pd.
local function pdPair(w)
	local protected = addBattery(w, { ActivationState = "STATE_COLD" })
	local pd = addBattery(w, { Role = "SR_SAM", ActivationState = "STATE_COLD", EngagementRangeMax = 25000 })
	pd.Units = {}
	protected.PointDefenseProviderId = pd.BatteryId
	pd.IsPointDefense = true
	pd.PointDefenseTargetId = protected.BatteryId
	return protected, pd
end

local function pdEngage(w)
	local PDS = Medusa.Services.PointDefenseService
	local viable = PDS.isProviderViable
	PDS.isProviderViable = function()
		return true
	end
	local n = PDS.engageThreats(ctxOf(w))
	PDS.isProviderViable = viable
	return n
end

--- A store held back from ARM confirmation (unpowered, or still watched for a motor), diving at 150 m/s down and
--- 300 m/s along from 3000 m: it reaches the ground 6 km on, at `x`, 0.
local function heldBackStore(w, x, unpowered)
	local t = addTrack(w, "unknown", {
		Position = { x = x, y = 3000, z = 6000 },
		Velocity = { x = 0, y = -150, z = -300 },
		AssessedAircraftType = "MISSILE",
		SizeWeight = 0,
	})
	t.Release = { RefE = 0, Since = 990, LastTime = 999, Looks = 3, Unpowered = unpowered, CarrierId = "J" }
	return t
end

function TestDecoyEffects:test_point_defence_engages_a_held_back_store_falling_on_the_site_it_protects()
	local w = newWorld()
	local _, pd = pdPair(w)
	local store = heldBackStore(w, 0, true)
	lu.assertEquals(Medusa.Services.HarmDetectionService.confirmBlock(store), "unpowered")
	lu.assertEquals(pdEngage(w), 1)
	lu.assertEquals(pd.CurrentTargetTrackId, store.TrackId)
	-- still watched for a motor: the same
	local w2 = newWorld()
	local _, pd2 = pdPair(w2)
	local watched = heldBackStore(w2, 0, nil)
	lu.assertEquals(Medusa.Services.HarmDetectionService.confirmBlock(watched), "window")
	lu.assertEquals(pdEngage(w2), 1)
	lu.assertEquals(pd2.CurrentTargetTrackId, watched.TrackId)
end

function TestDecoyEffects:test_point_defence_leaves_a_held_back_store_falling_elsewhere_or_an_unreleased_contact()
	local w = newWorld()
	local _, pd = pdPair(w)
	heldBackStore(w, D.GLIDE_THREAT_RADIUS_M + 2000, true)
	lu.assertEquals(pdEngage(w), 0)
	lu.assertNil(pd.CurrentTargetTrackId)
	local w2 = newWorld()
	local _, pd2 = pdPair(w2)
	local t = heldBackStore(w2, 0, true)
	t.Release = nil -- the same dive, but no released store: nothing held back
	lu.assertEquals(pdEngage(w2), 0)
	lu.assertNil(pd2.CurrentTargetTrackId)
end

function TestDecoyEffects:test_point_defence_engages_a_probable_decoy_gliding_into_its_battery()
	local w = newWorld()
	local protected = addBattery(w, { ActivationState = "STATE_COLD" })
	local pd = addBattery(w, { Role = "SR_SAM", ActivationState = "STATE_COLD", EngagementRangeMax = 25000 })
	pd.Units = {}
	protected.PointDefenseProviderId = pd.BatteryId
	pd.IsPointDefense = true
	pd.PointDefenseTargetId = protected.BatteryId
	local decoy = divingAtOrigin(w)
	local ctx = ctxOf(w)
	local PDS = Medusa.Services.PointDefenseService
	local viable = PDS.isProviderViable
	PDS.isProviderViable = function()
		return true
	end
	local n = PDS.engageThreats(ctx)
	PDS.isProviderViable = viable
	lu.assertEquals(n, 1)
	lu.assertEquals(pd.CurrentTargetTrackId, decoy.TrackId)
end
