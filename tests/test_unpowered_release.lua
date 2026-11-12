local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Config")
require("entities.Entities")
require("entities.Track")
require("entities.Battery")
require("services.Services")
require("services.MetricsService")
require("services.stores.TrackStore")
require("services.stores.BatteryStore")
require("services.TrackDisplayIdAllocator")
require("services.TrackManager")
require("services.TrackReacquisition")
require("services.HarmDetectionService")

-- A bomb is not a missile: a contact first seen just below an aircraft, launch cue or not, is not confirmed as an
-- ARM while it is watched for a motor, nor once it has shown none, unless a motor shows later
-- (Medusa.Constants.Release). End to end through the real TrackManager (grid, re-acquisition) and
-- HarmDetectionService.

local G = Medusa.Constants.GRAVITY_MPS2
local R = Medusa.Constants.Release
local HDS = Medusa.Services.HarmDetectionService
local mockTime = 1000
local ulid = 0

local SAM = { x = 0, y = 0, z = 0 }

local function setupMocks()
	mockTime = 1000
	ulid = 0
	GetTime = function()
		return mockTime
	end
	NewULID = function()
		ulid = ulid + 1
		return string.format("ULID-%05d", ulid)
	end
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
end

--- `o` (optional): the object's evidence, { sizeDb = a radar size per look (dBsm, 2 dB noise), seenAs = a sighting }.
local function report(id, p, v, o)
	return {
		NetworkId = id,
		SourceType = Medusa.Constants.TrackSource.SAM_BATTERY,
		Position = { x = p.x, y = p.y, z = p.z },
		Velocity = { x = v.x, y = v.y, z = v.z },
		SizeDb = o and o.sizeDb,
		SizeVarDb = o and o.sizeDb and 4,
		SeenAs = o and o.seenAs,
	}
end

-- A jet's evidence: an aircraft-sized return (5 m2), confident after two looks.
local JET_SIZE_DB = 7

--- A world: a HOT SAM at the origin, a TrackManager on a real grid, and objects flown in steps of `dt`.
local World = {}
World.__index = World

local function newWorld(opts)
	local w = setmetatable({}, World)
	w.mgr = Medusa.Services.TrackManager:new({
		geoGrid = GeoGrid(5000, { "Track" }),
		evidenceReacquisition = not (opts and opts.stock),
	})
	w.batteries = Medusa.Services.BatteryStore:new()
	w.batteries:add(Medusa.Entities.Battery.new({
		NetworkId = 1,
		GroupId = 1,
		GroupName = "SAM-1",
		OperationalStatus = "ACTIVE",
		ActivationState = "STATE_HOT",
		Position = SAM,
		EngagementRangeMax = 50000,
	}))
	w.objects = {}
	w.lines = {}
	return w
end

--- obj: { id, p, v, accel = function(obj, t) -> ax, ay, az (default: none), guide = function(obj) (steers obj.v),
--- born = time first reported }
function World:add(obj)
	obj.p = { x = obj.p.x, y = obj.p.y, z = obj.p.z }
	obj.v = { x = obj.v.x, y = obj.v.y, z = obj.v.z }
	self.objects[#self.objects + 1] = obj
	return obj
end

--- Advance to time `untilT` in 0.5 s steps, reporting every object at each look (every `look` s) and running the
--- HARM pass after each look. Stops an object at the ground.
function World:run(untilT, look)
	local step = 0.5
	while mockTime < untilT - 1e-9 do
		mockTime = mockTime + step
		for _, o in ipairs(self.objects) do
			if not o.gone then
				local ax, ay, az = 0, 0, 0
				if o.accel then
					ax, ay, az = o.accel(o, mockTime)
				end
				o.v.x, o.v.y, o.v.z = o.v.x + ax * step, o.v.y + ay * step, o.v.z + az * step
				if o.guide then
					o.guide(o)
				end
				o.p.x, o.p.y, o.p.z = o.p.x + o.v.x * step, o.p.y + o.v.y * step, o.p.z + o.v.z * step
				if o.p.y <= 0 then
					o.gone = true
				end
			end
		end
		if math.abs(mockTime / look - math.floor(mockTime / look + 0.5)) < 1e-6 then
			for _, o in ipairs(self.objects) do
				if not o.gone and mockTime >= (o.born or 0) then
					o.track = self.mgr:processReport(report(o.id, o.p, o.v, o), mockTime)
				end
			end
			local all = self.mgr:getStore():getAll({})
			for _, o in ipairs(self.objects) do
				if o.track and not o.gone then
					HDS.assessSingleTrack(o.track, all, nil, self.batteries, 1.0, 120, nil, "red-net")
					if o.track.HarmAssessment and o.track.HarmAssessment.label == "CONFIRMED" and not o.confirmedAt then
						o.confirmedAt = mockTime
					end
					local h = o.track.HarmAssessment
					local rel = o.track.Release
					if rel then
						o.linked = true
						o.everUnpowered = o.everUnpowered or rel.Unpowered
					end
					if h and (h.label == "PROBABLE" or h.label == "SUSPECT") then
						o.suspected = true
					end
				end
			end
		end
	end
end

local function gravity()
	return 0, -G, 0
end

--- A jet at `alt` m flying at `speed` m/s along +z toward the SAM, tracked from t = 1000; at `releaseT` it drops a
--- bomb (its own velocity, `below` m under it) whose free fall ends at the SAM.
local function bombRun(w, opts)
	local alt, speed = opts.alt or 6000, opts.speed or 300
	local fall = math.sqrt(2 * alt / G)
	local releaseT = opts.releaseT or 1030
	local zAtRelease = -speed * fall
	local jet = w:add({
		id = "jet",
		p = { x = 0, y = alt, z = zAtRelease - speed * (releaseT - 1000) },
		v = { x = 0, y = 0, z = speed },
		sizeDb = JET_SIZE_DB,
	})
	return jet, releaseT, zAtRelease
end

local function dropBomb(w, jet, below)
	return w:add({
		id = "bomb",
		p = { x = jet.p.x, y = jet.p.y - (below or 100), z = jet.p.z },
		v = { x = jet.v.x, y = jet.v.y, z = jet.v.z },
		accel = gravity,
	})
end

local function captureInfo()
	local lines, info = {}, env.info
	env.info = function(msg)
		lines[#lines + 1] = msg
	end
	return lines, function()
		env.info = info
	end
end

local function count(lines, needle)
	local n = 0
	for i = 1, #lines do
		if string.find(lines[i], needle, 1, true) then
			n = n + 1
		end
	end
	return n
end

--- Fly a bomb run with looks every `look` s; `disable` turns the release rule off (control).
--- A wingman that will be 3 km to the jet's left at time `t`, flying 27 degrees away from it: a contact beside the
--- jet then opens from the wingman at 150 m/s (a launch cue from the wrong track).
local function addWingman(w, jet, t)
	return w:add({
		id = "wing",
		p = { x = jet.p.x - 3000 + 150 * (t - mockTime), y = jet.p.y - 100, z = jet.p.z },
		v = { x = -150, y = 0, z = jet.v.z },
	})
end

local function flyBombRun(look, disable, escort)
	setupMocks()
	local radius = R.PARENT_RADIUS_M
	if disable then
		R.PARENT_RADIUS_M = 0
	end
	local w = newWorld()
	local jet, releaseT = bombRun(w, {})
	if escort then
		-- a wingman 3 km to the side, turned 27 degrees away: the bomb opens from it at 150 m/s (a launch cue)
		addWingman(w, jet, releaseT + look)
	end
	w:run(releaseT, look)
	local bomb = dropBomb(w, jet)
	-- the jet turns gently away after the release (a harder turn, seen 10 s later, gives the bomb a launch cue)
	jet.accel = function()
		return 3, 0, 0
	end
	local lines, restore = captureInfo()
	local ok, err = pcall(World.run, w, releaseT + 40, look)
	restore()
	R.PARENT_RADIUS_M = radius
	if not ok then
		error(err)
	end
	return bomb, lines
end

-- == Released stores ==

TestUnpoweredRelease = {}

function TestUnpoweredRelease:setUp()
	setupMocks()
end

function TestUnpoweredRelease:test_control_aBombFallingOnTheSam_isConfirmedWithoutTheRule()
	-- Without the rule the scenario is a real false confirmation: a free-falling bomb aimed at the SAM flies like an
	-- ARM.
	local bomb = flyBombRun(2, true)
	lu.assertNotNil(bomb.confirmedAt)
	lu.assertNil(bomb.track.Release)
end

function TestUnpoweredRelease:test_aBombDroppedByAJet_isNeverConfirmed_atAnyLookRate()
	for _, look in ipairs({ 2, 5, 10 }) do
		local bomb, lines = flyBombRun(look)
		lu.assertNil(bomb.confirmedAt, "look " .. look)
		lu.assertNotNil(bomb.track.Release, "look " .. look)
		lu.assertTrue(bomb.track.Release.Unpowered, "look " .. look)
		lu.assertTrue(bomb.track.AssessedAircraftType ~= "HARM", "look " .. look)
		if look == 2 then
			-- still SUSPECT/PROBABLE: alerts and point defence see it; the debrief says why it was not confirmed
			lu.assertTrue(bomb.suspected)
			lu.assertEquals(count(lines, "|ev=ARM_BLOCKED|"), 1)
			lu.assertEquals(count(lines, "|net=red-net|ev=ARM_BLOCKED|track=AB0002|why=unpowered|"), 1)
			lu.assertEquals(count(lines, "ev=ARM_CONFIRMED"), 0)
		end
	end
end

function TestUnpoweredRelease:test_aBombWithALaunchCue_isStillWatchedForAMotor_andNeverConfirmed()
	-- A launch cue (here from a wingman the bomb opens from) does not make a bomb powered.
	local control = flyBombRun(2, true, true)
	lu.assertNotNil(control.track.LaunchCue)
	lu.assertNotNil(control.confirmedAt)
	local bomb = flyBombRun(2, false, true)
	lu.assertNotNil(bomb.track.LaunchCue)
	lu.assertTrue(bomb.track.Release.Unpowered)
	lu.assertNil(bomb.confirmedAt)
end

function TestUnpoweredRelease:test_unpoweredNeedsThreeLooksOverTenSeconds()
	local track = Medusa.Entities.Track.new({
		NetworkId = "x",
		Position = { x = 0, y = 5000, z = 0 },
		Velocity = { x = 0, y = 0, z = 300 },
	})
	local e0 = Medusa.Entities.Track.energyHeight(track.Position, track.Velocity)
	track.Release = { RefE = e0, Since = 1000, LastTime = 1000, Looks = 1, Unpowered = false }
	-- 2 s looks: the sixth look (10 s) decides; a second report at a counted time is not a look
	for t = 1002, 1008, 2 do
		lu.assertNil(Medusa.Entities.Track.observeRelease(track, t))
		lu.assertNil(Medusa.Entities.Track.observeRelease(track, t))
	end
	lu.assertEquals(Medusa.Entities.Track.observeRelease(track, 1010), "unpowered")
	lu.assertTrue(track.Release.Unpowered)
	-- 10 s looks: the third look, 20 s after the first
	track.Release = { RefE = e0, Since = 1000, LastTime = 1000, Looks = 1, Unpowered = false }
	lu.assertNil(Medusa.Entities.Track.observeRelease(track, 1010))
	lu.assertEquals(Medusa.Entities.Track.observeRelease(track, 1020), "unpowered")
end

function TestUnpoweredRelease:test_whileTheWindowIsOpen_aConfirmationIsHeldBack()
	-- A track whose ARM evidence is already complete (here: carried by the stock re-association) but that has only
	-- just appeared beside an aircraft: not confirmed while it is watched for a motor.
	local track = Medusa.Entities.Track.new({
		NetworkId = "x",
		Position = { x = 0, y = 4000, z = -9000 },
		Velocity = { x = 0, y = -250, z = 600 },
	})
	track.PositionHistory:push({
		timestamp = 1000,
		position = { x = 0, y = 4250, z = -9600 },
		velocity = { x = 0, y = -250, z = 600 },
	})
	track.PositionHistory:push({
		timestamp = 1001,
		position = { x = 0, y = 4000, z = -9000 },
		velocity = { x = 0, y = -250, z = 600 },
	})
	track.HarmAssessment = {
		llr = 20,
		scanCount = 10,
		label = "PROBABLE",
		emitterPosition = { x = 0, y = 0, z = 0 },
	}
	track.Release = { RefE = 1e9, Since = 1000, LastTime = 1001, Looks = 2, Unpowered = false }
	local w = newWorld()
	local lines, restore = captureInfo()
	HDS.assessSingleTrack(track, { track }, nil, w.batteries, 1.0, 120, nil, "red-net")
	restore()
	lu.assertEquals(track.HarmAssessment.label, "PROBABLE")
	lu.assertEquals(count(lines, "|ev=ARM_BLOCKED|"), 1)
	lu.assertEquals(count(lines, "|why=window|"), 1)
	-- the link dropped (a motor): the next evaluation confirms
	track.Release = nil
	Medusa.Entities.Track.update(track, { x = 0, y = 3750, z = -8400 }, { x = 0, y = -250, z = 600 }, 1002)
	HDS.assessSingleTrack(track, { track }, nil, w.batteries, 1.0, 120, nil, "red-net")
	lu.assertEquals(track.HarmAssessment.label, "CONFIRMED")
end

function TestUnpoweredRelease:test_aClearedTrackHeldBackFromConfirmation_becomesProbable()
	-- A cleared track leaves CLEARED only by being confirmed; held back, it is PROBABLE (alerts see it), not CLEARED.
	local track = Medusa.Entities.Track.new({
		NetworkId = "x",
		Position = { x = 0, y = 4000, z = -9000 },
		Velocity = { x = 0, y = -250, z = 600 },
	})
	track.PositionHistory:push({
		timestamp = 1000,
		position = { x = 0, y = 4250, z = -9600 },
		velocity = { x = 0, y = -250, z = 600 },
	})
	track.PositionHistory:push({
		timestamp = 1001,
		position = { x = 0, y = 4000, z = -9000 },
		velocity = { x = 0, y = -250, z = 600 },
	})
	track.HarmAssessment = { llr = 20, scanCount = 10, label = "CLEARED", emitterPosition = { x = 0, y = 0, z = 0 } }
	track.Release = { RefE = 1e9, Since = 990, LastTime = 1001, Looks = 4, Unpowered = true }
	local w = newWorld()
	local lines, restore = captureInfo()
	HDS.assessSingleTrack(track, { track }, nil, w.batteries, 1.0, 120, nil, "red-net")
	restore()
	lu.assertEquals(track.HarmAssessment.label, "PROBABLE")
	lu.assertEquals(count(lines, "|why=unpowered|"), 1)
	-- an aircraft-sized return held back stays CLEARED
	track.Release = nil
	track.HarmAssessment.label = "CLEARED"
	track.SizeDb, track.SizeWeight, track.SizeSpreadDb = 7, 4, 1.8
	Medusa.Entities.Track.update(track, { x = 0, y = 3750, z = -8400 }, { x = 0, y = -250, z = 600 }, 1002)
	lines, restore = captureInfo()
	HDS.assessSingleTrack(track, { track }, nil, w.batteries, 1.0, 120, nil, "red-net")
	restore()
	lu.assertEquals(track.HarmAssessment.label, "CLEARED")
	lu.assertEquals(count(lines, "|why=size|"), 1)
end

function TestUnpoweredRelease:test_anArmLaunchedFromAJet_hasALaunchCueAndIsConfirmed()
	local w = newWorld()
	local jet = w:add({
		id = "jet",
		p = { x = 0, y = 6000, z = -60000 },
		v = { x = 0, y = 0, z = 250 },
		sizeDb = JET_SIZE_DB,
	})
	w:run(1030, 2)
	-- motor: 25 m/s^2 for 8 s, aimed down at the SAM
	local arm = w:add({
		id = "arm",
		p = { x = jet.p.x, y = jet.p.y - 50, z = jet.p.z },
		v = { x = 0, y = 0, z = 250 },
		born = 1034,
		accel = function(o, t)
			local dx, dy, dz = SAM.x - o.p.x, SAM.y - o.p.y, SAM.z - o.p.z
			local d = math.sqrt(dx * dx + dy * dy + dz * dz)
			local a = t <= 1036 and 80 or -2
			return dx / d * a, dy / d * a, dz / d * a
		end,
	})
	w:run(1200, 2)
	lu.assertNotNil(arm.track.LaunchCue)
	lu.assertNil(arm.track.Release)
	lu.assertNotNil(arm.confirmedAt)
end

--- An ARM seen 1 s after launch beside its jet (within 150 m/s and 3 km of energy of it: linked), with a launch cue
--- from a wingman; its motor then burns.
local function flyCuedArm(disable)
	setupMocks()
	local radius = R.PARENT_RADIUS_M
	if disable then
		R.PARENT_RADIUS_M = 0
	end
	local w = newWorld()
	local jet = w:add({
		id = "jet",
		p = { x = 0, y = 6000, z = -60000 },
		v = { x = 0, y = 0, z = 250 },
		sizeDb = JET_SIZE_DB,
	})
	addWingman(w, jet, 1032)
	w:run(1031, 1)
	local arm = w:add({
		id = "arm",
		p = { x = jet.p.x, y = jet.p.y - 50, z = jet.p.z },
		v = { x = 0, y = 0, z = 250 },
		born = 1032,
		accel = function(o, t)
			local dx, dy, dz = SAM.x - o.p.x, SAM.y - o.p.y, SAM.z - o.p.z
			local d = math.sqrt(dx * dx + dy * dy + dz * dz)
			local a = t <= 1038 and 70 or -2
			return dx / d * a, dy / d * a, dz / d * a
		end,
	})
	local ok, err = pcall(function()
		w:run(1032, 2)
		arm.linkedAtBirth = arm.track.Release ~= nil
		w:run(1200, 2)
	end)
	R.PARENT_RADIUS_M = radius
	if not ok then
		error(err)
	end
	return arm
end

function TestUnpoweredRelease:test_aCuedArmLinkedBesideItsJet_dropsTheLinkAsPowered_andIsConfirmedOnTime()
	local before = flyCuedArm(true)
	local arm = flyCuedArm(false)
	lu.assertNotNil(arm.track.LaunchCue)
	lu.assertTrue(arm.linkedAtBirth)
	lu.assertFalse(arm.everUnpowered)
	lu.assertNil(arm.track.Release)
	lu.assertNotNil(before.confirmedAt)
	lu.assertEquals(arm.confirmedAt, before.confirmedAt)
end

function TestUnpoweredRelease:test_aPoweredWeaponBornBesideAJetWithoutACue_dropsTheLinkAndIsConfirmed()
	-- First seen beside the jet at its speed (no cue: not pulling away yet), then its motor burns.
	local w = newWorld()
	local jet = w:add({
		id = "jet",
		p = { x = 0, y = 6000, z = -60000 },
		v = { x = 0, y = 0, z = 250 },
		sizeDb = JET_SIZE_DB,
	})
	w:run(1030, 2)
	local missile = w:add({
		id = "missile",
		p = { x = jet.p.x + 150, y = jet.p.y - 50, z = jet.p.z },
		v = { x = 0, y = 0, z = 250 },
		born = 1032,
		accel = function(o, t)
			if t <= 1032 then
				return 0, 0, 0
			end
			local dx, dy, dz = SAM.x - o.p.x, SAM.y - o.p.y, SAM.z - o.p.z
			local d = math.sqrt(dx * dx + dy * dy + dz * dz)
			local a = t < 1042 and 40 or -2
			return dx / d * a, dy / d * a, dz / d * a
		end,
	})
	w:run(1032, 2)
	lu.assertNil(missile.track.LaunchCue)
	lu.assertNotNil(missile.track.Release)
	w:run(1150, 2)
	lu.assertNil(missile.track.Release)
	lu.assertNotNil(missile.confirmedAt)
end

function TestUnpoweredRelease:test_armFirstSeenLateBesideASalvoMate_isNotLinked_andIsConfirmed()
	-- Two ARMs fired together, seen only by an early-warning radar (10 s looks). The first is picked up late and is
	-- still EVALUATING (1-2 scans) when the second is first seen 300 m from it at the same speed. The first is no
	-- carrier (nothing says it is an aircraft): the second is judged on its own flight.
	local w = newWorld()
	local function homing(o) -- pure pursuit of the SAM at 600 m/s
		local dx, dy, dz = SAM.x - o.p.x, SAM.y - o.p.y, SAM.z - o.p.z
		local d = math.sqrt(dx * dx + dy * dy + dz * dz)
		o.v.x, o.v.y, o.v.z = dx / d * 600, dy / d * 600, dz / d * 600
	end
	local a = w:add({ id = "armA", p = { x = 0, y = 9000, z = -70000 }, v = { x = 0, y = 0, z = 600 }, guide = homing })
	w:run(1020, 10)
	lu.assertEquals(a.track.HarmAssessment.label, "EVALUATING")
	local b = w:add({
		id = "armB",
		p = { x = a.p.x + 300, y = a.p.y, z = a.p.z - 50 },
		v = { x = a.v.x, y = a.v.y, z = a.v.z },
		guide = homing,
	})
	w:run(1200, 10)
	lu.assertNil(b.linked)
	lu.assertNotNil(a.confirmedAt)
	lu.assertNotNil(b.confirmedAt)
end

--- A contact born beside a jet (evidence `jetEvidence`) at `born`, held unpowered; the jet is then made PROBABLE, then
--- (its aircraft evidence withdrawn when `withdraw`) typed HARM. Returns the contact's Release after each step.
local function carrierTurnsArm(jetEvidence, born, withdraw)
	setupMocks()
	local w = newWorld()
	local jet = w:add({
		id = "jet",
		p = { x = 0, y = 6000, z = -60000 },
		v = { x = 0, y = 0, z = 250 },
		sizeDb = jetEvidence.sizeDb,
		seenAs = jetEvidence.seenAs,
	})
	w:run(born, 2)
	local c = w:add({ id = "c", p = { x = jet.p.x + 100, y = jet.p.y - 100, z = jet.p.z }, v = jet.v })
	w:run(born + 20, 2)
	lu.assertTrue(c.track.Release.Unpowered)
	jet.track.HarmAssessment = { label = "PROBABLE", llr = 3, scanCount = 9 }
	w:run(born + 22, 2)
	local afterProbable = c.track.Release
	jet.track.HarmAssessment = { label = "CLEARED", llr = -20, scanCount = 9 }
	jet.track.AssessedAircraftType = "HARM"
	if withdraw then
		jet.seenAs, jet.track.SeenAs = "MUNITION", "MUNITION"
	end
	w:run(born + 24, 2)
	return afterProbable, c.track.Release
end

function TestUnpoweredRelease:test_aYoungCarrierTypedHarm_freesItsChild_butAProbableCarrierDoesNot()
	-- linked 20 s after it was first seen, then typed HARM and seen as a munition: it was an ARM
	local afterProbable, afterHarm = carrierTurnsArm({ seenAs = "AIRCRAFT" }, 1020, true)
	lu.assertNotNil(afterProbable) -- a falling bomb flies ARM-like too: not enough to free its stick
	lu.assertNil(afterHarm)
end

function TestUnpoweredRelease:test_aYoungCarrierConfirmedAsAnArm_freesItsChild()
	-- confirmed by the HARM pass (its label), not typed HARM
	local TM = Medusa.Services.TrackManager
	local carrier =
		{ AssessedAircraftType = "FIXED_WING", HarmAssessment = { label = "CONFIRMED" }, SeenAs = "MUNITION" }
	local young = { CarrierAge = 5 }
	lu.assertTrue(TM._carrierFrees(carrier, young))
	carrier.HarmAssessment.label = "PROBABLE"
	lu.assertFalse(TM._carrierFrees(carrier, young))
	carrier.HarmAssessment.label = "CONFIRMED"
	lu.assertFalse(TM._carrierFrees(carrier, { CarrierAge = Medusa.Constants.Release.FREE_MAX_CARRIER_AGE_SEC }))
	carrier.SeenAs = "AIRCRAFT"
	lu.assertFalse(TM._carrierFrees(carrier, young))
end

function TestUnpoweredRelease:test_anOldCarrierOrOneStillAnAircraft_typedHarm_freesNothing()
	-- linked 70 s after the carrier was first seen: no ARM flies beside its own stores that long
	local _, afterHarm = carrierTurnsArm({ seenAs = "AIRCRAFT" }, 1070, true)
	lu.assertNotNil(afterHarm)
	lu.assertTrue(afterHarm.Unpowered)
	-- still aircraft-sized, or still seen as an aircraft: a diving jet called an ARM in error
	_, afterHarm = carrierTurnsArm({ sizeDb = JET_SIZE_DB }, 1020)
	lu.assertNotNil(afterHarm)
	_, afterHarm = carrierTurnsArm({ seenAs = "AIRCRAFT" }, 1020)
	lu.assertNotNil(afterHarm)
end

function TestUnpoweredRelease:test_anUnpoweredMark_isDroppedByALaterMotor()
	local track = Medusa.Entities.Track.new({
		NetworkId = "x",
		Position = { x = 0, y = 5000, z = 0 },
		Velocity = { x = 0, y = 0, z = 300 },
	})
	local e0 = Medusa.Entities.Track.energyHeight(track.Position, track.Velocity)
	track.Release = { RefE = e0, Since = 1000, LastTime = 1010, Looks = 3, Unpowered = true }
	lu.assertNil(Medusa.Entities.Track.observeRelease(track, 1012))
	lu.assertTrue(track.Release.Unpowered)
	track.Velocity = { x = 0, y = 0, z = 450 } -- +5.7 km of energy
	lu.assertEquals(Medusa.Entities.Track.observeRelease(track, 1014), "powered")
	lu.assertNil(track.Release)
end

--- A burnt-out ARM coasting at 355 m/s down onto the SAM, first seen (late) at offset `off` from a SEAD jet 20 km out
--- flying the same way at 300 m/s.
local function coastingArmBesideJet(off)
	setupMocks()
	local w = newWorld()
	local jet = w:add({
		id = "jet",
		p = { x = 0, y = 6000, z = -29000 },
		v = { x = 0, y = 0, z = 300 },
		sizeDb = JET_SIZE_DB,
		seenAs = "AIRCRAFT",
	})
	w:run(1030, 2)
	local arm = w:add({
		id = "arm",
		p = { x = jet.p.x + off.x, y = jet.p.y + off.y, z = jet.p.z + off.z },
		v = { x = 0, y = 0, z = 355 },
		born = 1032,
		guide = function(o)
			local dx, dy, dz = SAM.x - o.p.x, SAM.y - o.p.y, SAM.z - o.p.z
			local d = math.sqrt(dx * dx + dy * dy + dz * dz)
			o.v.x, o.v.y, o.v.z = dx / d * 355, dy / d * 355, dz / d * 355
		end,
	})
	w:run(1300, 2)
	return arm
end

function TestUnpoweredRelease:test_aCoastingArmFirstSeenBesideARealJet_isNotHeldAsAStore()
	-- Where a store released in the last few seconds cannot be: 1.5 km from the jet, or 400 m above it.
	for _, off in ipairs({ { x = 1500, y = -100, z = 0 }, { x = 300, y = 400, z = 0 } }) do
		local arm = coastingArmBesideJet(off)
		lu.assertNil(arm.linked)
		lu.assertNotNil(arm.confirmedAt)
	end
	-- control: with a wider reach (2 km, any height) it would be held as a store for good and never confirmed
	local radius, rise = R.PARENT_RADIUS_M, R.PARENT_MAX_RISE_M
	R.PARENT_RADIUS_M, R.PARENT_MAX_RISE_M = 2000, 1e9
	local ok, arm = pcall(coastingArmBesideJet, { x = 300, y = 400, z = 0 })
	R.PARENT_RADIUS_M, R.PARENT_MAX_RISE_M = radius, rise
	lu.assertTrue(ok, arm)
	lu.assertTrue(arm.everUnpowered)
	lu.assertNil(arm.confirmedAt)
end

-- == The carrier ==

TestReleaseCarrier = {}

function TestReleaseCarrier:setUp()
	setupMocks()
	self.w = newWorld()
	self.jet = self.w:add({
		id = "jet",
		p = { x = 0, y = 6000, z = -60000 },
		v = { x = 0, y = 0, z = 250 },
		seenAs = "AIRCRAFT",
	})
end

function TestReleaseCarrier:contactBesideJet(dx, dv, id)
	local j = self.jet
	return self.w.mgr:processReport(
		report(id or "c", { x = j.p.x + dx, y = j.p.y - 100, z = j.p.z }, { x = 0, y = 0, z = j.v.z + (dv or 0) }),
		mockTime
	)
end

function TestReleaseCarrier:test_aContactBesideAJetTrackedTenSeconds_isLinked()
	self.w:run(1012, 2) -- first seen at 1002
	local c = self:contactBesideJet(100)
	lu.assertNotNil(c.Release)
	lu.assertFalse(c.Release.Unpowered)
	local jetE = Medusa.Entities.Track.energyHeight(self.jet.p, self.jet.v)
	lu.assertAlmostEquals(c.Release.RefE, jetE, 1)
end

function TestReleaseCarrier:test_aJetTrackedUnderTenSeconds_isNoCarrier()
	self.w:run(1008, 2)
	lu.assertNil(self:contactBesideJet(100).Release)
end

function TestReleaseCarrier:test_tooFarOrTooDifferentInVelocity_isNoCarrier()
	self.w:run(1020, 2)
	lu.assertNil(self:contactBesideJet(1000, 0, "far").Release)
	lu.assertNil(self:contactBesideJet(100, 160, "fast").Release)
	lu.assertNotNil(self:contactBesideJet(800, 0, "near").Release)
end

function TestReleaseCarrier:test_aContactAboveItsCarrier_isNoStore()
	-- a store falls: never well above the aircraft it left
	self.w:run(1020, 2)
	local j = self.jet
	local function at(dy, id)
		return self.w.mgr:processReport(report(id, { x = j.p.x + 100, y = j.p.y + dy, z = j.p.z }, j.v), mockTime)
	end
	lu.assertNil(at(200, "above").Release)
	lu.assertNotNil(at(100, "a little above").Release)
end

function TestReleaseCarrier:test_aCarrierLookSecondsOld_isDeadReckonedToNow()
	-- The jet was last seen 8 s ago, 2 km back from where it is now; the contact is beside where it is now.
	self.w:run(1020, 2)
	mockTime = mockTime + 8
	local j = self.jet
	local c =
		self.w.mgr:processReport(report("c", { x = j.p.x + 100, y = j.p.y - 100, z = j.p.z + 250 * 8 }, j.v), mockTime)
	lu.assertNotNil(c.Release)
end

function TestReleaseCarrier:test_onlyATrackWithAircraftEvidence_isACarrier()
	self.w:run(1020, 2)
	local jt = self.jet.track
	-- nothing says it is an aircraft (a weapon track 10 s old has no confident size and no sighting)
	jt.SeenAs = nil
	lu.assertNil(self:contactBesideJet(100, 0, "c0").Release)
	jt.SizeDb, jt.SizeWeight, jt.SizeSpreadDb = -12, 4, 1.8
	lu.assertNil(self:contactBesideJet(100, 0, "c1").Release)
	jt.SizeDb = 7 -- a confident aircraft-sized return
	lu.assertNotNil(self:contactBesideJet(100, 0, "c2").Release)
	jt.SizeDb, jt.SizeWeight, jt.SizeSpreadDb = nil, nil, nil
	jt.SeenAs = "HELICOPTER"
	lu.assertNotNil(self:contactBesideJet(100, 0, "c3").Release)
	jt.SeenAs = "AIRCRAFT"
	lu.assertNotNil(self:contactBesideJet(100, 0, "c4").Release)
end

function TestReleaseCarrier:test_anArmLikeOrLaunchedTrack_isNoCarrier()
	self.w:run(1020, 2)
	local jt = self.jet.track
	jt.HarmAssessment = { label = "SUSPECT", llr = 2, scanCount = 5 }
	lu.assertNil(self:contactBesideJet(100, 0, "c2").Release)
	jt.HarmAssessment = nil
	jt.LaunchCue = { FromTrackId = "x", Time = 900 }
	lu.assertNil(self:contactBesideJet(100, 0, "c3").Release)
	jt.LaunchCue = nil
	local c = self:contactBesideJet(100, 0, "c4")
	lu.assertNotNil(c.Release)
	lu.assertEquals(c.Release.CarrierAge, 1020 - 1002)
end

function TestReleaseCarrier:test_aContactAlreadyFarAboveItsCarriersEnergy_isNotLinked()
	self.w:run(1020, 2)
	-- 150 m/s faster than the jet beside it (no cue: not pulling away from it): 4.9 km more energy, a motor at work
	lu.assertNil(self:contactBesideJet(100, 150).Release)
	lu.assertNotNil(self:contactBesideJet(100, 50, "slower").Release)
end

-- == Re-acquisition: a sure one carries the unpowered mark; a contact is otherwise judged afresh ==

TestReleaseReacquisition = {}

function TestReleaseReacquisition:setUp()
	setupMocks()
end

local function lose(mgr, track)
	-- not seen for longer than the track memory: stale, then dropped
	local t = track.LastDetectionTime + Medusa.Config:getTrackMemoryDurationSec() + 1
	mgr:pruneStale(t)
	mgr:pruneStale(t)
	return t
end

function TestReleaseReacquisition:test_aMarkedTrackReacquired_awayFromAnyCarrier_keepsItsMark()
	for _, stock in ipairs({ false, true }) do
		setupMocks()
		local w = newWorld({ stock = stock })
		local bomb = w:add({ id = "bomb", p = { x = 0, y = 9000, z = -60000 }, v = { x = 0, y = 0, z = 250 } })
		local jet = w:add({
			id = "jet",
			p = { x = 100, y = 9100, z = -60000 },
			v = { x = 0, y = 0, z = 250 },
			sizeDb = JET_SIZE_DB,
		})
		bomb.born = 1012
		w:run(1030, 2)
		lu.assertTrue(bomb.track.Release.Unpowered)
		-- the jet turns away (so the two lost tracks do not tie), then both drop out of cover
		jet.v = { x = 250, y = 0, z = 0 }
		w:run(1050, 2)
		jet.gone, bomb.gone = true, true
		mockTime = lose(w.mgr, bomb.track) + 1
		-- the same object (stock) or a contact where it should be (evidence); the jet is gone
		local p = { x = 0, y = 9000, z = bomb.p.z + 250 * (mockTime - bomb.track.LastDetectionTime) }
		local again = w.mgr:processReport(report("bomb", p, bomb.v), mockTime)
		local how = stock and "stock" or "evidence"
		lu.assertEquals(again.DisplayTrackId, bomb.track.DisplayTrackId, how)
		lu.assertNotNil(again.Release, how)
		lu.assertTrue(again.Release.Unpowered, how)
		lu.assertEquals(again.Release.RefE, bomb.track.Release.RefE, how)
		lu.assertFalse(again.Release == bomb.track.Release, how) -- a copy
	end
end

function TestReleaseReacquisition:test_anUnmarkedTrackReacquiredBesideAJet_isJudgedAfresh_andAConfirmedArmStaysConfirmed()
	local w = newWorld()
	local jet = w:add({
		id = "jet",
		p = { x = 0, y = 6000, z = -60000 },
		v = { x = 0, y = 0, z = 250 },
		sizeDb = JET_SIZE_DB,
	})
	w:run(1020, 2)
	-- a confirmed ARM lost a moment ago, picked up again beside the jet (its label carries across the short gap)
	local arm = Medusa.Entities.Track.new({
		NetworkId = "arm",
		DisplayTrackId = "AB0099",
		Position = { x = 150, y = 5900, z = jet.p.z },
		Velocity = { x = 0, y = 0, z = 300 },
		FirstDetectionTime = 990,
		LastDetectionTime = 1019,
	})
	arm.HarmAssessment = { label = "CONFIRMED", llr = 20, scanCount = 10, confirmedAt = 1015 }
	arm.AssessedAircraftType = "HARM"
	w.mgr:_addLost(Medusa.Services.TrackReacquisition.snapshot(arm, 1019))
	local again = w.mgr:processReport(report("arm2", { x = 150, y = 5900, z = jet.p.z + 300 }, arm.Velocity), 1020)
	lu.assertEquals(again.DisplayTrackId, "AB0099")
	lu.assertNotNil(again.Release) -- beside the jet, no cue: watched afresh
	lu.assertEquals(again.HarmAssessment.label, "CONFIRMED")
	HDS.assessSingleTrack(again, { again }, nil, w.batteries, 1.0, 120, nil, "red-net")
	lu.assertEquals(again.HarmAssessment.label, "CONFIRMED")
end
