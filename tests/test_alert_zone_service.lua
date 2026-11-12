local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("services.Services")
require("services.AlertZoneService")

local Svc = Medusa.Services.AlertZoneService
local AAT = Medusa.Constants.AssessedAircraftType
local HAS = Medusa.Constants.HarmAssessmentState

local function props(t)
	local out = {}
	for k, v in pairs(t) do
		out[#out + 1] = { key = k, value = v }
	end
	return out
end

local function circle(name, p, x, z, r)
	return { name = name, type = 0, x = x or 0, y = z or 0, radius = r or 20000, properties = props(p) }
end

-- A network as the service sees it: a GeoGrid of track positions and a store to look tracks up.
local function newSource(id)
	local src = { id = id, geoGrid = GeoGrid(5000, { "Track" }), tracks = {} }
	src.trackStore = {
		get = function(_, tid)
			return src.tracks[tid]
		end,
	}
	return src
end

local nextId = 0
local function put(src, x, z, opts)
	opts = opts or {}
	nextId = nextId + 1
	local t = {
		TrackId = "t" .. nextId,
		Position = { x = x, y = opts.alt or 5000, z = z },
		Velocity = opts.vel or { x = 0, y = 0, z = 200 },
		LifecycleState = "ACTIVE",
		TrackIdentification = opts.ident or "HOSTILE",
		AssessedAircraftType = opts.type or AAT.FIGHTER,
		FirstDetectionTime = opts.born or 0,
		HarmAssessment = opts.harm and { label = opts.harm } or nil,
		LaunchCue = opts.launched and { FromTrackId = "parent", Time = 0 } or nil,
	}
	src.tracks[t.TrackId] = t
	src.geoGrid:add("Track", t.TrackId, t.Position)
	return t
end

local function move(src, t, x, z)
	t.Position = { x = x, y = t.Position.y, z = z }
	src.geoGrid:updatePosition(t.TrackId, t.Position, "Track")
end

local function drop(src, t)
	src.tracks[t.TrackId] = nil
	src.geoGrid:remove(t.TrackId)
end

local function flagWrites()
	local out = {}
	for i = 1, trigger.action._callCount do
		local c = trigger.action._called[i]
		if c.func == "setUserFlag" then
			out[#out + 1] = { c.args[1], c.args[2] }
		end
	end
	return out
end

local RED_ONLY = { [1] = true }

TestAlertZoneParsing = {}

function TestAlertZoneParsing:test_flagOnly_usesDefaults()
	local z = Svc.parseZone(circle("north", { MedusaFlag = "north" }), RED_ONLY)
	lu.assertEquals(z.FlagName, "north")
	lu.assertEquals(z.CoalitionId, 1)
	lu.assertEquals(z.Threats, { aircraft = true })
	lu.assertEquals(z.AltBand, "any")
	lu.assertEquals(z.LingerSec, 30)
end

function TestAlertZoneParsing:test_zoneWithoutFlag_isNotAnAlertZone()
	local z, problem = Svc.parseZone(circle("plain", {}), RED_ONLY)
	lu.assertNil(z)
	lu.assertNil(problem)
end

function TestAlertZoneParsing:test_bothSidesRunning_requiresSide()
	local z, problem = Svc.parseZone(circle("n", { MedusaFlag = "n" }), { [1] = true, [2] = true })
	lu.assertNil(z)
	lu.assertStrContains(problem, "MedusaSide")
	z = Svc.parseZone(circle("n", { MedusaFlag = "n", MedusaSide = "Blue" }), { [1] = true, [2] = true })
	lu.assertEquals(z.CoalitionId, 2)
end

function TestAlertZoneParsing:test_settingsAndTypos()
	local z = Svc.parseZone(
		circle("n", { MedusaFlag = "n", MedusaThreats = "arms, munitions", MedusaLinger = "45s", MedusaAlt = "LOW" }),
		RED_ONLY
	)
	lu.assertEquals(z.Threats, { arms = true, munitions = true })
	lu.assertEquals(z.LingerSec, 45)
	lu.assertEquals(z.AltBand, "low")
	local bad, problem = Svc.parseZone(circle("n", { MedusaFlag = "n", MedusaThreats = "fighters" }), RED_ONLY)
	lu.assertNil(bad)
	lu.assertStrContains(problem, "fighters")
end

function TestAlertZoneParsing:test_quadZone_countsOnlyInsideTheQuad()
	local quad = {
		name = "q",
		type = 2,
		verticies = { { x = 0, y = 0 }, { x = 10000, y = 0 }, { x = 10000, y = 2000 }, { x = 0, y = 2000 } },
		properties = props({ MedusaFlag = "q" }),
	}
	local z = Svc.parseZone(quad, RED_ONLY)
	local src = newSource("red")
	put(src, 5000, 1000) -- inside
	put(src, 5000, 4500) -- inside the bounding circle, outside the quad
	Svc.updateZone(z, { src }, 100)
	lu.assertEquals(z.Count, 1)
end

TestAlertZoneCounting = {}

function TestAlertZoneCounting:setUp()
	trigger.action._called = {}
	trigger.action._callCount = 0
	self.src = newSource("red")
	self.state = { zones = { Svc.parseZone(circle("north", { MedusaFlag = "north" }), RED_ONLY) }, written = {} }
	self.zone = self.state.zones[1]
	self.sides = { [1] = { self.src } }
end

function TestAlertZoneCounting:test_writesCurrentCount_onlyWhenItChanges()
	put(self.src, 0, 0)
	put(self.src, 3000, 3000)
	Svc.evaluate(self.state, self.sides, 100)
	Svc.evaluate(self.state, self.sides, 105)
	lu.assertEquals(flagWrites(), { { "north", 2 } })
end

function TestAlertZoneCounting:test_contactLingers_thenDrops()
	local t = put(self.src, 0, 0, { vel = { x = 0, y = 0, z = 0 } })
	Svc.evaluate(self.state, self.sides, 100)
	drop(self.src, t) -- masked by terrain
	Svc.evaluate(self.state, self.sides, 120)
	lu.assertEquals(self.zone.Count, 1)
	Svc.evaluate(self.state, self.sides, 131)
	lu.assertEquals(self.zone.Count, 0)
	lu.assertEquals(flagWrites(), { { "north", 1 }, { "north", 0 } })
end

function TestAlertZoneCounting:test_reacquiredContact_isNotCountedTwice()
	local t = put(self.src, 0, 0)
	Svc.evaluate(self.state, self.sides, 100)
	drop(self.src, t)
	Svc.evaluate(self.state, self.sides, 105)
	-- Back on radar as a new track, where the old one would be after 10 s at 200 m/s.
	put(self.src, 0, 2000)
	Svc.evaluate(self.state, self.sides, 110)
	lu.assertEquals(self.zone.Count, 1)
end

function TestAlertZoneCounting:test_fourJetsFiringFourHarms_countFour()
	local jets = {}
	for i = 1, 4 do
		jets[i] = put(self.src, i * 3000, 0)
	end
	Svc.evaluate(self.state, self.sides, 100)
	-- Each jet fires a HARM: new fast tracks next to the jets, first seen at 101.
	local harms = {}
	for i = 1, 4 do
		harms[i] = put(self.src, i * 3000 + 300, 0, { born = 101, vel = { x = 0, y = 0, z = 600 }, launched = true })
	end
	Svc.evaluate(self.state, self.sides, 105)
	lu.assertEquals(self.zone.Count, 4)
	-- Ten seconds on, the HARM evaluation has them as suspects; later they are confirmed ARMs.
	for i = 1, 4 do
		move(self.src, harms[i], i * 3000 + 300, 6000)
		harms[i].HarmAssessment = { label = HAS.SUSPECT }
	end
	Svc.evaluate(self.state, self.sides, 112)
	lu.assertEquals(self.zone.Count, 4)
	for i = 1, 4 do
		harms[i].AssessedAircraftType = AAT.HARM
		harms[i].HarmAssessment = { label = HAS.CONFIRMED }
	end
	Svc.evaluate(self.state, self.sides, 117)
	lu.assertEquals(self.zone.Count, 4)
end

function TestAlertZoneCounting:test_aircraftLaterJudgedArm_isDroppedAtOnce()
	local t = put(self.src, 0, 0, { vel = { x = 0, y = 0, z = 0 } })
	Svc.evaluate(self.state, self.sides, 100)
	t.AssessedAircraftType = AAT.HARM
	Svc.evaluate(self.state, self.sides, 105)
	lu.assertEquals(self.zone.Count, 0)
end

function TestAlertZoneCounting:test_friendlyAndNeutralTracks_areIgnored()
	put(self.src, 0, 0, { ident = "FRIENDLY" })
	put(self.src, 1000, 0, { ident = "WHITEAIR" })
	Svc.evaluate(self.state, self.sides, 100)
	lu.assertEquals(self.zone.Count, 0)
end

function TestAlertZoneCounting:test_oneJetSeenByTwoNetworks_countsOnce_butAPairCountsTwo()
	local other = newSource("red-2")
	self.sides[1][2] = other
	put(self.src, 0, 0)
	put(other, 200, 100)
	Svc.evaluate(self.state, self.sides, 100)
	lu.assertEquals(self.zone.Count, 1)
	put(self.src, 500, 0) -- wingman 500 m away, seen by the first network
	Svc.evaluate(self.state, self.sides, 105)
	lu.assertEquals(self.zone.Count, 2)
end

function TestAlertZoneCounting:test_lowBand_usesHeightAboveGround()
	self.zone.AltBand = "low" -- mock terrain is 100 m
	put(self.src, 0, 0, { alt = 1050 }) -- 950 m above ground: low, though above 1000 m sea level
	put(self.src, 4000, 0, { alt = 1300 })
	Svc.evaluate(self.state, self.sides, 100)
	lu.assertEquals(self.zone.Count, 1)
end

function TestAlertZoneCounting:test_zonesSharingAFlag_writeTheSum()
	local second = Svc.parseZone(circle("south", { MedusaFlag = "north" }, 0, 100000), RED_ONLY)
	self.state.zones[2] = second
	put(self.src, 0, 0)
	put(self.src, 0, 100000)
	put(self.src, 3000, 100000)
	Svc.evaluate(self.state, self.sides, 100)
	local writes = flagWrites()
	lu.assertEquals(writes[#writes], { "north", 3 })
end

function TestAlertZoneCounting:test_armsZone_countsConfirmedArmsOnly()
	self.zone.Threats = { arms = true }
	put(self.src, 0, 0)
	put(self.src, 3000, 0, { type = AAT.HARM, harm = HAS.CONFIRMED })
	Svc.evaluate(self.state, self.sides, 100)
	lu.assertEquals(self.zone.Count, 1)
end

function TestAlertZoneCounting:test_steps_checkEveryZoneOncePerInterval()
	for k = 2, 7 do
		self.state.zones[k] = Svc.parseZone(circle("z" .. k, { MedusaFlag = "z" .. k }, k * 100000, 0), RED_ONLY)
		put(self.src, k * 100000, 0)
	end
	local checks = {}
	Svc._onPassDone = function(zone)
		checks[zone.ZoneName] = (checks[zone.ZoneName] or 0) + 1
	end
	-- 7 zones over a 5 s interval: 1.4 zones per one-second step, every zone exactly once per interval.
	for s = 1, 5 do
		Svc.step(self.state, self.sides, 100 + s)
	end
	for k = 1, 7 do
		lu.assertEquals(checks[self.state.zones[k].ZoneName], 1)
	end
	for s = 6, 10 do
		Svc.step(self.state, self.sides, 100 + s)
	end
	Svc._onPassDone = nil
	for k = 1, 7 do
		lu.assertEquals(checks[self.state.zones[k].ZoneName], 2)
	end
	for k = 2, 7 do
		lu.assertEquals(self.state.written["z" .. k], 1)
	end
end

function TestAlertZoneCounting:test_oneZone_isCheckedOncePerInterval_notEverySecond()
	local checks = 0
	Svc._onPassDone = function()
		checks = checks + 1
	end
	for s = 1, 10 do
		Svc.step(self.state, self.sides, 100 + s)
	end
	Svc._onPassDone = nil
	lu.assertEquals(checks, 2)
end

function TestAlertZoneCounting:test_crowdedZone_capsTrackVisitsPerStep_andStillCountsEveryContact()
	local visits = 0
	local get = self.src.trackStore.get
	self.src.trackStore.get = function(store, id)
		visits = visits + 1
		return get(store, id)
	end
	local n = Svc.MAX_VISITS_PER_STEP + 50
	for i = 1, n do
		put(self.src, (i % 15) * 1600 - 11200, math.floor(i / 15) * 1600 - 10400)
	end
	Svc.step(self.state, self.sides, 101)
	lu.assertTrue(visits <= Svc.MAX_VISITS_PER_STEP)
	lu.assertNil(self.state.written.north)
	Svc.step(self.state, self.sides, 102)
	lu.assertEquals(self.state.written.north, n)
end

function TestAlertZoneCounting:test_heightBand_readsTheTerrainOncePerTrackPosition()
	self.zone.AltBand = "low"
	local second = Svc.parseZone(circle("south", { MedusaFlag = "s", MedusaAlt = "low" }), RED_ONLY)
	self.state.zones[2] = second
	local reads = 0
	local original = GetTerrainHeight
	GetTerrainHeight = function(p)
		reads = reads + 1
		return original(p)
	end
	local t = put(self.src, 0, 0, { alt = 600 })
	Svc.evaluate(self.state, self.sides, 100)
	Svc.evaluate(self.state, self.sides, 105)
	lu.assertEquals(reads, 1)
	move(self.src, t, 0, 1000)
	Svc.evaluate(self.state, self.sides, 110)
	lu.assertEquals(reads, 2)
	t.AltitudeAGL = 300 -- a height above ground carried by the track is used as it is
	move(self.src, t, 0, 2000)
	Svc.evaluate(self.state, self.sides, 115)
	GetTerrainHeight = original
	lu.assertEquals(reads, 2)
	lu.assertEquals(self.zone.Count, 1)
end

-- MedusaLinger counts from when the network stopped holding the contact, not from its last radar refresh.
function TestAlertZoneCounting:test_lingerZero_countsAHeldTrack_andDropsItAtTheNextCheck()
	self.zone.LingerSec = 0
	local t = put(self.src, 0, -10000)
	-- An early-warning radar refreshing every 10 s; the zone is checked every 5 s from 103.
	for now = 103, 143, 5 do
		t.LastDetectionTime = 100 + 10 * math.floor((now - 100) / 10)
		move(self.src, t, 0, -10000 + 200 * (t.LastDetectionTime - 100))
		Svc.evaluate(self.state, self.sides, now)
		lu.assertEquals(self.zone.Count, 1)
	end
	drop(self.src, t)
	Svc.evaluate(self.state, self.sides, 148)
	lu.assertEquals(self.zone.Count, 0)
end

function TestAlertZoneCounting:test_shortLinger_doesNotFlickerOnASlowRadar()
	self.zone.LingerSec = 5
	local t = put(self.src, 0, -10000)
	for now = 103, 143, 5 do
		t.LastDetectionTime = 100 + 10 * math.floor((now - 100) / 10)
		move(self.src, t, 0, -10000 + 200 * (t.LastDetectionTime - 100))
		Svc.evaluate(self.state, self.sides, now)
		lu.assertEquals(self.zone.Count, 1)
	end
end

-- A track whose position is not refreshed (masked, or a slow radar) stays ACTIVE with its last detection.
function TestAlertZoneCounting:test_frozenTrack_isOneContact_andLingersFromItsLastDetection()
	local t = put(self.src, 0, -10000, { vel = { x = 0, y = 0, z = 320 } })
	t.LastDetectionTime = 100
	for k = 0, 5 do
		Svc.evaluate(self.state, self.sides, 100 + 5 * k)
		lu.assertEquals(self.zone.Count, 1)
	end
	Svc.evaluate(self.state, self.sides, 131)
	lu.assertEquals(self.zone.Count, 0)
end

function TestAlertZoneCounting:test_slowRadarUpdates_doNotDuplicateAFastJet()
	local t = put(self.src, 0, -15000, { vel = { x = 0, y = 0, z = 300 } })
	for k = 0, 8 do
		local now = 100 + 5 * k
		if k % 2 == 0 then -- radar refresh every 10 s
			move(self.src, t, 0, -15000 + 300 * (now - 100))
			t.LastDetectionTime = now
		end
		Svc.evaluate(self.state, self.sides, now)
		lu.assertEquals(self.zone.Count, 1)
	end
end

function TestAlertZoneCounting:test_twoNetworksWithPartialCoverage_keepAFormationAtTwo()
	local other = newSource("red-2")
	self.sides[1][2] = other
	put(self.src, 0, 0) -- network 1 holds the leader only
	put(other, 100, 0) -- network 2 holds the leader...
	put(other, 600, 0) -- ...and the wingman 500 m away
	for k = 0, 8 do
		Svc.evaluate(self.state, self.sides, 100 + 5 * k)
	end
	lu.assertEquals(self.zone.Count, 2)
end

function TestAlertZoneCounting:test_weaponSeenLeavingAnAircraft_neverCountsAsOne()
	local fast = { x = 0, y = 0, z = 600 }
	put(self.src, 0, 0, { vel = fast, harm = HAS.EVALUATING, launched = true })
	put(self.src, 0, 3000, { vel = fast, launched = true }) -- not yet in ARM evaluation
	put(self.src, 0, -3000, { vel = fast, harm = HAS.CLEARED, launched = true }) -- ARM cleared after its target died
	put(self.src, 3000, 0, { vel = { x = 0, y = 0, z = 300 }, launched = true }) -- slowed late in its flight
	put(self.src, 5000, 0, { vel = { x = 0, y = 0, z = 250 }, harm = HAS.EVALUATING })
	Svc.evaluate(self.state, self.sides, 100)
	lu.assertEquals(self.zone.Count, 1)
end

function TestAlertZoneCounting:test_munitionsZone_countsWeaponsSeenLeavingAnAircraft()
	self.zone.Threats = { munitions = true }
	put(self.src, 0, 0, { vel = { x = 0, y = 0, z = 600 }, launched = true })
	put(self.src, 5000, 0, { vel = { x = 0, y = 0, z = 700 } }) -- fast jet: not a munition
	Svc.evaluate(self.state, self.sides, 100)
	lu.assertEquals(self.zone.Count, 1)
end

function TestAlertZoneCounting:test_mach2Interceptors_countAsAircraft()
	-- A MiG-31 pair at Mach 2.3 (700 m/s ground speed), one still in ARM evaluation, one cleared.
	put(self.src, 0, 0, { vel = { x = 0, y = 0, z = 700 }, harm = HAS.EVALUATING })
	put(self.src, 0, 2000, { vel = { x = 0, y = 0, z = 700 }, harm = HAS.CLEARED })
	put(self.src, 0, 4000, { vel = { x = 0, y = 0, z = 700 } })
	Svc.evaluate(self.state, self.sides, 100)
	lu.assertEquals(self.zone.Count, 3)
end

function TestAlertZoneCounting:test_confirmedArm_dropsTheNearestLingeringContact()
	local still = { vel = { x = 0, y = 0, z = 0 } }
	local far = put(self.src, 1400, 0, still)
	Svc.evaluate(self.state, self.sides, 95) -- remembered first: within reach of the ARM, not the nearest
	local near = put(self.src, -200, 0, still) -- 1600 m from the first: its own contact
	Svc.evaluate(self.state, self.sides, 100)
	local outside = put(self.src, 5000, 0, still) -- remembered last: beyond the matching distance
	Svc.evaluate(self.state, self.sides, 102)
	drop(self.src, far)
	drop(self.src, near)
	drop(self.src, outside)
	put(self.src, 0, 0, { vel = still.vel, type = AAT.HARM, harm = HAS.CONFIRMED }) -- 1400 m and 200 m away
	Svc.evaluate(self.state, self.sides, 105)
	lu.assertEquals(self.zone.Count, 2)
	local xs = { self.zone.Contacts[1].pos.x, self.zone.Contacts[2].pos.x }
	table.sort(xs)
	lu.assertEquals(xs, { 1400, 5000 })
end

TestAlertZoneLosses = {}

function TestAlertZoneLosses:setUp()
	trigger.action._called = {}
	trigger.action._callCount = 0
	local both = { [1] = true, [2] = true }
	self.state = {
		zones = {
			Svc.parseZone(circle("west", { MedusaLosses = "lost", MedusaSide = "red" }), both),
			Svc.parseZone(circle("east", { MedusaFlag = "e", MedusaLosses = "lost", MedusaSide = "red" }, 50000), both),
			Svc.parseZone(circle("blue", { MedusaLosses = "bluelost", MedusaSide = "blue" }), both),
		},
		written = {},
	}
end

function TestAlertZoneLosses:test_lossesOnlyZone_isAnAlertZoneThatCountsNoContacts()
	local z = self.state.zones[1]
	lu.assertNotNil(z)
	lu.assertNil(z.FlagName)
	Svc.evaluate(self.state, { [1] = { newSource("red") } }, 100)
	lu.assertEquals(flagWrites(), { { "e", 0 } })
end

function TestAlertZoneLosses:test_lossesAccumulate_perSide_andZonesSharingAFlagSum()
	Svc.recordLoss(self.state, 1, { x = 1000, y = 0, z = 0 }) -- west
	Svc.recordLoss(self.state, 1, { x = 50000, y = 0, z = 2000 }) -- east
	Svc.recordLoss(self.state, 1, { x = 1000, y = 0, z = 500 }) -- west again
	Svc.recordLoss(self.state, 2, { x = 1000, y = 0, z = 0 }) -- a blue site: not red's loss
	Svc.recordLoss(self.state, 1, { x = 0, y = 0, z = 90000 }) -- outside every zone
	local w = flagWrites()
	lu.assertEquals(w[#w - 1], { "lost", 3 })
	lu.assertEquals(w[#w], { "bluelost", 1 })
end

-- == TestAlertZoneContactEvidence: return size and sight recognition in the crew's call ==

TestAlertZoneContactEvidence = {}

local CE = Medusa.Constants.ContactEvidence

local function contact(opts)
	local t = {
		TrackId = "c",
		Position = { x = 0, y = 5000, z = 0 },
		Velocity = opts.vel or { x = 0, y = 0, z = 250 },
		LifecycleState = "ACTIVE",
		TrackIdentification = "HOSTILE",
		AssessedAircraftType = opts.type or AAT.FIGHTER,
		FirstDetectionTime = 0,
		HarmAssessment = opts.harm and { label = opts.harm } or nil,
		LaunchCue = opts.launched and { FromTrackId = "parent", Time = 0 } or nil,
		SeenAs = opts.seen,
	}
	if opts.rcs then
		t.SizeDb = 10 * math.log10(opts.rcs)
		t.SizeWeight = CE.SIZE_MAX_WEIGHT
		t.SizeSpreadDb = math.sqrt(1 / CE.SIZE_MAX_WEIGHT + CE.SIZE_SPREAD_FLOOR_DB ^ 2)
	end
	return t
end

local function class(opts)
	return Svc._trackClass(contact(opts), 100)
end

function TestAlertZoneContactEvidence:test_launch_cue_with_a_confident_aircraft_sized_return_is_an_aircraft()
	lu.assertEquals(class({ launched = true, rcs = 5 }), "aircraft")
	lu.assertEquals(class({ launched = true }), "munition") -- no size estimate: the cue stands
	lu.assertEquals(class({ launched = true, rcs = 0.08 }), "munition")
end

function TestAlertZoneContactEvidence:test_small_fast_return_without_a_launch_cue_or_arm_kinematics_is_an_aircraft()
	-- Speed is no cue: a low-observable jet in supersonic cruise returns less than an ARM. A weapon the launch cue
	-- missed counts as a munition once the ARM check holds it a suspect (below).
	lu.assertEquals(class({ rcs = 0.003, vel = { x = 0, y = 0, z = 520 } }), "aircraft")
	lu.assertEquals(class({ rcs = 0.08, vel = { x = 0, y = -50, z = 600 } }), "aircraft")
end

function TestAlertZoneContactEvidence:test_supersonic_low_observable_jet_counts_in_an_aircraft_zone()
	local src = newSource("red")
	local zone = Svc.parseZone(circle("z", { MedusaFlag = "a" }), RED_ONLY)
	local t = contact({ rcs = 0.003, vel = { x = 0, y = 0, z = 520 } })
	t.TrackId = "lo"
	src.tracks[t.TrackId] = t
	src.geoGrid:add("Track", t.TrackId, t.Position)
	Svc.updateZone(zone, { src }, 100)
	lu.assertEquals(zone.Count, 1)
end

function TestAlertZoneContactEvidence:test_small_return_judged_arm_suspect_is_a_munition()
	lu.assertEquals(class({ rcs = 0.05, harm = HAS.SUSPECT }), "munition")
	lu.assertEquals(class({ rcs = 0.05, harm = HAS.PROBABLE }), "munition")
end

function TestAlertZoneContactEvidence:test_stealth_jet_flying_like_a_jet_stays_an_aircraft()
	-- Low-observable aircraft (0.003 m2, smaller than an ARM) are harder to classify, but size alone never
	-- makes one a munition.
	lu.assertEquals(class({ rcs = 0.003 }), "aircraft")
	lu.assertEquals(class({ rcs = 0.003, vel = { x = 180, y = 30, z = 170 } }), "aircraft")
end

function TestAlertZoneContactEvidence:test_small_fast_contact_seen_as_an_aircraft_stays_an_aircraft()
	lu.assertEquals(class({ rcs = 0.003, vel = { x = 0, y = 0, z = 450 }, seen = "AIRCRAFT" }), "aircraft")
end

function TestAlertZoneContactEvidence:test_fast_jet_sized_contact_stays_an_aircraft()
	-- A MiG-31 at Mach 2.3 flies as fast as a HARM: speed alone is no cue.
	lu.assertEquals(class({ rcs = 10, vel = { x = 0, y = 0, z = 700 } }), "aircraft")
end

function TestAlertZoneContactEvidence:test_tald_returns_like_a_jet_and_stays_an_aircraft()
	lu.assertEquals(class({ rcs = 5, vel = { x = 0, y = -10, z = 200 } }), "aircraft")
end

function TestAlertZoneContactEvidence:test_tald_seen_within_sight_range_stops_counting_as_an_aircraft()
	-- A TALD returns like a fighter; a crew that sees it within 10 km knows it is a weapon.
	lu.assertEquals(class({ rcs = 5 }), "aircraft")
	lu.assertEquals(class({ seen = "MUNITION", rcs = 5 }), "munition")
	lu.assertEquals(class({ seen = "MUNITION" }), "munition")
	lu.assertEquals(class({ seen = "AIRCRAFT", rcs = 5 }), "aircraft")
end

function TestAlertZoneContactEvidence:test_crew_sighted_weapon_counts_in_a_munitions_zone()
	local src = newSource("red")
	local zone = Svc.parseZone(circle("z", { MedusaFlag = "m", MedusaThreats = "munitions" }), RED_ONLY)
	local t = contact({ seen = "MUNITION", rcs = 5 })
	t.TrackId = "tald"
	src.tracks[t.TrackId] = t
	src.geoGrid:add("Track", t.TrackId, t.Position)
	Svc.updateZone(zone, { src }, 100)
	lu.assertEquals(zone.Count, 1)
end

function TestAlertZoneContactEvidence:test_probable_decoy_is_a_munition_and_a_suspect_still_an_aircraft()
	local probable = contact({ rcs = 5 })
	probable.DecoyAssessment = { label = "PROBABLE" }
	local suspect = contact({ rcs = 5 })
	suspect.DecoyAssessment = { label = "SUSPECT" }
	lu.assertEquals(Svc._trackClass(probable, 100), "munition")
	lu.assertEquals(Svc._trackClass(suspect, 100), "aircraft")
end
