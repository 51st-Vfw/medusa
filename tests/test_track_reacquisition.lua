local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Config")
require("entities.Entities")
require("entities.Track")
require("entities.Doctrine")
require("services.Services")
require("services.stores.TrackStore")
require("services.TrackDisplayIdAllocator")
require("services.MetricsService")
require("services.TrackManager")
require("services.TrackReacquisition")
require("entities.Battery")
require("services.stores.BatteryStore")
require("services.SpatialQuery")
require("services.HarmDetectionService")
require("services.DecoyAssessmentService")
require("services.BlackBoxService")
require("services.SensorPollingService")

-- Evidence-based re-acquisition: a lost track is matched to a new contact by where it should be and how
-- fast it should be going, never by DCS object id; what it carries depends on the fit, the gap and the class.

local mockTime = 1000
local ulidCounter = 0
local HAS = Medusa.Constants.HarmAssessmentState
local DS = Medusa.Constants.DecoyState
local AAT = Medusa.Constants.AssessedAircraftType

local function setupMocks()
	mockTime = 1000
	ulidCounter = 0
	GetTime = function()
		return mockTime
	end
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
end

local function newManager(on)
	local mgr = Medusa.Services.TrackManager:new({
		geoGrid = GeoGrid(10000, { "Battery", "Track" }),
		displayIdAllocator = Medusa.Services.TrackDisplayIdAllocator:new(),
		evidenceReacquisition = on,
	})
	mgr._trackMemoryDurationSec = 1 -- lose tracks after 1 s so the gaps under test are the gaps that matter
	return mgr
end

local function report(id, pos, vel)
	return {
		NetworkId = id,
		SourceType = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR,
		Position = { x = pos.x, y = pos.y, z = pos.z },
		Velocity = { x = vel.x, y = vel.y, z = vel.z },
	}
end

--- Fly a contact straight for `sec` seconds (1 s looks) ending at mockTime; returns its track.
local function fly(mgr, id, pos, vel, sec)
	local track
	for i = sec, 0, -1 do
		local t = mockTime - i
		track = mgr:processReport(
			report(id, { x = pos.x - vel.x * i, y = pos.y - vel.y * i, z = pos.z - vel.z * i }, vel),
			t
		)
	end
	return track
end

--- Lose every track: two prunes after the memory window.
local function loseAll(mgr)
	mgr:pruneStale(mockTime + 1.5)
	mgr:pruneStale(mockTime + 1.5)
end

local function after(pos, vel, sec)
	return { x = pos.x + vel.x * sec, y = pos.y + vel.y * sec, z = pos.z + vel.z * sec }
end

local JET_V = { x = 250, y = 0, z = 0 }
local TALD_V = { x = 200, y = -20, z = 0 } -- a 1:10 glide
local ARM_V = { x = 600, y = -40, z = 0 }

local function confirmArm(track, confirmedAt)
	track.HarmAssessment = {
		label = HAS.CONFIRMED,
		llr = 9,
		scanCount = 12,
		confirmedAt = confirmedAt,
		disproofSince = confirmedAt + 1,
		disproofScans = 1,
		previousAircraftType = AAT.UNKNOWN,
		previousIsSeadThreat = false,
		emitterPosition = { x = 50000, y = 0, z = 0 },
	}
	track.AssessedAircraftType = AAT.HARM
	track.IsSeadThreat = true
	track.HarmLikelihoodScore = 1
end

-- == Matching ==

TestTrackReacquisitionMatch = {}

function TestTrackReacquisitionMatch:setUp()
	setupMocks()
	self.mgr = newManager(true)
end

function TestTrackReacquisitionMatch:test_aDifferentObjectWhereTheLostTrackShouldBe_reacquiresIt()
	local p = { x = 0, y = 6000, z = 0 }
	local jet = fly(self.mgr, "jet", p, JET_V, 8)
	local display = jet.DisplayTrackId
	jet.TrackIdentification = Medusa.Constants.TrackIdentification.BANDIT
	loseAll(self.mgr)
	mockTime = mockTime + 10
	local again = self.mgr:processReport(report("other-object", after(p, JET_V, 10), JET_V), mockTime)
	lu.assertEquals(again.DisplayTrackId, display)
	lu.assertEquals(again.TrackIdentification, Medusa.Constants.TrackIdentification.BANDIT)
	lu.assertEquals(again.FirstDetectionTime, jet.FirstDetectionTime)
end

function TestTrackReacquisitionMatch:test_aReacquiredTrackKeepsTheSensorThatFirstMadeIt()
	-- (the network's FIRST_DETECTION line is made only for a track no sensor has made yet)
	local p = { x = 0, y = 6000, z = 0 }
	local jet = fly(self.mgr, "jet", p, JET_V, 8)
	jet.FirstSeenBy, jet.FirstSeenKind, jet.FirstSeenRangeM = "ewr-north", "EWR", 50000
	loseAll(self.mgr)
	mockTime = mockTime + 10
	local again = self.mgr:processReport(report("other-object", after(p, JET_V, 10), JET_V), mockTime)
	lu.assertEquals(again.DisplayTrackId, jet.DisplayTrackId)
	lu.assertEquals(again.FirstSeenBy, "ewr-north")
	lu.assertEquals(again.FirstSeenKind, "EWR")
	lu.assertEquals(again.FirstSeenRangeM, 50000)
end

function TestTrackReacquisitionMatch:test_theSameObjectFarFromItsPrediction_isANewTrack()
	local p = { x = 0, y = 6000, z = 0 }
	local jet = fly(self.mgr, "jet", p, JET_V, 8)
	loseAll(self.mgr)
	mockTime = mockTime + 10
	local again = self.mgr:processReport(report("jet", { x = 40000, y = 6000, z = 30000 }, JET_V), mockTime)
	lu.assertNotEquals(again.DisplayTrackId, jet.DisplayTrackId)
end

function TestTrackReacquisitionMatch:test_aContactFlyingTheOtherWay_isANewTrack()
	local p = { x = 0, y = 6000, z = 0 }
	local jet = fly(self.mgr, "jet", p, JET_V, 8)
	loseAll(self.mgr)
	mockTime = mockTime + 10
	local again = self.mgr:processReport(report("x", after(p, JET_V, 10), { x = -250, y = 0, z = 0 }), mockTime)
	lu.assertNotEquals(again.DisplayTrackId, jet.DisplayTrackId)
end

function TestTrackReacquisitionMatch:test_aTurningJet_isFoundByItsTrend()
	-- A 3 g turn at 250 m/s (0.12 rad/s): lost after 8 s of it, seen again 5 s later still turning. The straight-line
	-- prediction no longer fits (score 0.13); the trend of the last 6 s does (0.43).
	local w, R, t0 = 0.12, 250 / 0.12, mockTime
	local function state(t)
		local a = w * t
		return { x = R * math.sin(a), y = 6000, z = R * (1 - math.cos(a)) }, {
			x = 250 * math.cos(a),
			y = 0,
			z = 250 * math.sin(a),
		}
	end
	local track
	for t = 0, 8 do
		local p, v = state(t)
		track = self.mgr:processReport(report("jet", p, v), t0 - 8 + t)
	end
	loseAll(self.mgr)
	mockTime = t0 + 5
	local p, v = state(13)
	local again = self.mgr:processReport(report("y", p, v), mockTime)
	lu.assertEquals(again.DisplayTrackId, track.DisplayTrackId)
end

function TestTrackReacquisitionMatch:test_aLostTrackIsMatchedOnce()
	local p = { x = 0, y = 6000, z = 0 }
	local jet = fly(self.mgr, "jet", p, JET_V, 8)
	loseAll(self.mgr)
	mockTime = mockTime + 10
	local a = self.mgr:processReport(report("a", after(p, JET_V, 10), JET_V), mockTime)
	local b = self.mgr:processReport(report("b", after(p, JET_V, 10), JET_V), mockTime)
	lu.assertEquals(a.DisplayTrackId, jet.DisplayTrackId)
	lu.assertNotEquals(b.DisplayTrackId, jet.DisplayTrackId)
end

function TestTrackReacquisitionMatch:test_lostTracksAreForgottenAfterTwoMinutes()
	local p = { x = 0, y = 6000, z = 0 }
	local jet = fly(self.mgr, "jet", p, { x = 0, y = 0, z = 0 }, 8)
	loseAll(self.mgr)
	mockTime = mockTime + 1.5 + Medusa.Constants.TRACK_REASSOC_TTL_SEC + 1
	self.mgr:pruneStale(mockTime)
	local again = self.mgr:processReport(report("x", p, { x = 0, y = 0, z = 0 }), mockTime)
	lu.assertNotEquals(again.DisplayTrackId, jet.DisplayTrackId)
end

function TestTrackReacquisitionMatch:test_eachLostTrackIsScoredOnlyWithinItsOwnGate()
	-- One lost missile must not widen every lost track's gate: a jet lost half a minute ago cannot be farther from
	-- where it was than its own gate.
	local Svc = Medusa.Services.TrackReacquisition
	local jetV = { x = 200, y = 0, z = 0 }
	local jet = fly(self.mgr, "jet", { x = 0, y = 6000, z = 0 }, jetV, 8)
	fly(self.mgr, "arm", { x = 0, y = 6000, z = 30000 }, { x = 700, y = 0, z = 0 }, 8)
	loseAll(self.mgr)
	mockTime = mockTime + 30
	local gate = Svc.gateRadius(200, 30)
	lu.assertTrue(gate + 2000 < Medusa.Constants.Reacquisition.GATE_MAX_M)
	local scored = {}
	local orig = Svc.score
	Svc.score = function(e, ...)
		scored[e.TrackId] = true
		return orig(e, ...)
	end
	local ok, err = pcall(function()
		self.mgr:processReport(report("x", { x = gate + 2000, y = 6000, z = 0 }, jetV), mockTime)
	end)
	Svc.score = orig
	lu.assertTrue(ok, tostring(err))
	lu.assertNil(scored[jet.TrackId])
end

function TestTrackReacquisitionMatch:test_lostTracksAreSweptOncePerSecond()
	fly(self.mgr, "jet", { x = 0, y = 6000, z = 0 }, JET_V, 8)
	loseAll(self.mgr)
	local sweeps = 0
	local orig = self.mgr._evictLost
	self.mgr._evictLost = function(mgr, now)
		sweeps = sweeps + 1
		return orig(mgr, now)
	end
	for k = 1, 20 do
		self.mgr:pruneStale(mockTime + 2 + k * 0.1)
	end
	lu.assertTrue(sweeps <= 3, tostring(sweeps))
end

function TestTrackReacquisitionMatch:test_twoLostJetsEquallyClose_areATieAndNeitherIsReacquired()
	local p1, p2 = { x = 0, y = 6000, z = 0 }, { x = 0, y = 6000, z = 600 }
	local a = fly(self.mgr, "a", p1, JET_V, 8)
	local b = fly(self.mgr, "b", p2, JET_V, 8)
	loseAll(self.mgr)
	mockTime = mockTime + 10
	local mid = after({ x = 0, y = 6000, z = 300 }, JET_V, 10)
	local again = self.mgr:processReport(report("c", mid, JET_V), mockTime)
	lu.assertNotEquals(again.DisplayTrackId, a.DisplayTrackId)
	lu.assertNotEquals(again.DisplayTrackId, b.DisplayTrackId)
end

function TestTrackReacquisitionMatch:test_offSwitch_keepsStockObjectIdReassociation()
	local mgr = newManager(false)
	local p = { x = 0, y = 6000, z = 0 }
	local jet = fly(mgr, "jet", p, JET_V, 8)
	loseAll(mgr)
	mockTime = mockTime + 10
	local other = mgr:processReport(report("other-object", after(p, JET_V, 10), JET_V), mockTime)
	lu.assertNotEquals(other.DisplayTrackId, jet.DisplayTrackId)
	local same = mgr:processReport(report("jet", after(p, JET_V, 10), JET_V), mockTime)
	lu.assertEquals(same.DisplayTrackId, jet.DisplayTrackId)
end

function TestTrackReacquisitionMatch:test_switchCanBeSetAfterConstruction()
	local mgr = newManager(true)
	mgr:setEvidenceReacquisition(false)
	local p = { x = 0, y = 6000, z = 0 }
	local jet = fly(mgr, "jet", p, JET_V, 8)
	loseAll(mgr)
	mockTime = mockTime + 10
	local other = mgr:processReport(report("other-object", after(p, JET_V, 10), JET_V), mockTime)
	lu.assertNotEquals(other.DisplayTrackId, jet.DisplayTrackId)
end

function TestTrackReacquisitionMatch:test_doctrineSwitchDefaultsOn()
	lu.assertTrue(Medusa.Entities.Doctrine.new({}).EvidenceReacquisition)
	lu.assertFalse(Medusa.Entities.Doctrine.new({ EvidenceReacquisition = false }).EvidenceReacquisition)
end

-- == Carried evidence ==

TestTrackReacquisitionCarry = {}

function TestTrackReacquisitionCarry:setUp()
	setupMocks()
	self.mgr = newManager(true)
	self.p = { x = 0, y = 6000, z = 0 }
end

function TestTrackReacquisitionCarry:_lostArm(gap)
	local arm = fly(self.mgr, "arm", self.p, ARM_V, 8)
	confirmArm(arm, mockTime - 30)
	loseAll(self.mgr)
	mockTime = mockTime + gap
	return arm, self.mgr:processReport(report("arm2", after(self.p, ARM_V, gap), ARM_V), mockTime)
end

function TestTrackReacquisitionCarry:test_armLabel_carriedAcrossAShortGap_withItsTimersButNotItsScore()
	local arm, again = self:_lostArm(10)
	lu.assertEquals(again.DisplayTrackId, arm.DisplayTrackId)
	local s = again.HarmAssessment
	lu.assertEquals(s.label, HAS.CONFIRMED)
	lu.assertEquals(s.llr, 0)
	lu.assertEquals(s.scanCount, 0)
	lu.assertEquals(s.confirmedAt, arm.HarmAssessment.confirmedAt)
	lu.assertEquals(s.disproofSince, arm.HarmAssessment.disproofSince + 10) -- paused over the 10 s gap
	lu.assertEquals(s.disproofScans, 1)
	lu.assertNotIs(s, arm.HarmAssessment)
	lu.assertEquals(again.AssessedAircraftType, AAT.HARM)
	lu.assertTrue(again.IsSeadThreat)
end

function TestTrackReacquisitionCarry:test_armLabel_notCarriedAcrossALongGap_andTheTrackIsNoLongerAHarm()
	local arm, again = self:_lostArm(25)
	lu.assertEquals(again.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(again.HarmAssessment)
	lu.assertEquals(again.AssessedAircraftType, AAT.UNKNOWN)
	lu.assertFalse(again.IsSeadThreat)
	lu.assertNil(again.HarmLikelihoodScore)
end

function TestTrackReacquisitionCarry:_lostStraightArm()
	local v = { x = 600, y = 0, z = 0 }
	local arm = fly(self.mgr, "arm", self.p, v, 8)
	confirmArm(arm, mockTime - 30)
	loseAll(self.mgr)
	return arm, v
end

function TestTrackReacquisitionCarry:test_aContactTooSlowToBeTheArm_doesNotInheritItsTrack()
	-- A jet at 250 m/s right on a lost 600 m/s ARM's prediction 10 s later: an ARM keeps at least 70% of its speed
	-- over 10 s, so this is not it (position and velocity alone would still call it a fit).
	local arm, v = self:_lostStraightArm()
	mockTime = mockTime + 10
	local jet = self.mgr:processReport(report("jet", after(self.p, v, 10), { x = 250, y = 0, z = 0 }), mockTime)
	lu.assertNotEquals(jet.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(jet.HarmAssessment)
end

function TestTrackReacquisitionCarry:test_theArmSpeedTest_neverAllowsLessThan60PercentOfItsSpeed()
	-- 18 s on, half the ARM's speed: within 1 - 0.03 x 18 = 46%, but below the 60% floor.
	local arm, v = self:_lostStraightArm()
	mockTime = mockTime + 18
	local slow = self.mgr:processReport(report("slow", after(self.p, v, 18), { x = 300, y = 0, z = 0 }), mockTime)
	lu.assertNotEquals(slow.DisplayTrackId, arm.DisplayTrackId)
end

function TestTrackReacquisitionCarry:test_aSlowingArmStillFastEnough_keepsItsLabel()
	local arm, v = self:_lostStraightArm()
	mockTime = mockTime + 10
	local again = self.mgr:processReport(report("arm2", after(self.p, v, 10), { x = 450, y = 0, z = 0 }), mockTime)
	lu.assertEquals(again.DisplayTrackId, arm.DisplayTrackId)
	lu.assertEquals(again.HarmAssessment.label, HAS.CONFIRMED)
end

function TestTrackReacquisitionCarry:test_theNotAttackingWindowPausesOverTheGap()
	-- Not attacking anything for 1 s before it was lost, 10 s unseen, then two scans 2 s apart: the window (8 s)
	-- counts the 1 + 4 s it was seen to fly, not the 10 s nobody saw.
	local arm, v = self:_lostStraightArm()
	local lostAt = arm.LastDetectionTime
	arm.HarmAssessment.disproofSince = lostAt - 1
	mockTime = lostAt + 10
	local p = after(self.p, v, 10)
	local again = self.mgr:processReport(report("arm2", p, v), mockTime)
	lu.assertEquals(again.HarmAssessment.disproofSince, lostAt + 9)
	local batteries = Medusa.Services.BatteryStore:new()
	for i = 1, 2 do
		mockTime = mockTime + 2
		self.mgr:processReport(report("arm2", after(p, v, 2 * i), v), mockTime)
		Medusa.Services.HarmDetectionService.assessSingleTrack(again, { again }, nil, batteries, 1, 120)
	end
	lu.assertEquals(again.HarmAssessment.label, HAS.CONFIRMED)
end

function TestTrackReacquisitionCarry:test_unconfirmedArmScore_isNeverCarried()
	local jet = fly(self.mgr, "jet", self.p, JET_V, 8)
	jet.HarmAssessment = { label = HAS.PROBABLE, llr = 3, scanCount = 6 }
	jet.HarmLikelihoodScore = 0.6
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local again = self.mgr:processReport(report("x", after(self.p, JET_V, 5), JET_V), mockTime)
	lu.assertEquals(again.DisplayTrackId, jet.DisplayTrackId)
	lu.assertNil(again.HarmAssessment)
	lu.assertNil(again.HarmLikelihoodScore)
end

function TestTrackReacquisitionCarry:test_aStrongMatch_carriesDecoyLabelSeenAsAndLaunchCue()
	local tald = fly(self.mgr, "tald", self.p, TALD_V, 8)
	tald.DecoyAssessment = { label = DS.PROBABLE, runSince = 900, runSec = 100, launchEvidence = 30, disproofScans = 1 }
	tald.SeenAs = Medusa.Constants.SeenAs.MUNITION
	tald.SeenAsTime = 990
	tald.LaunchCue = { FromTrackId = "x", Time = 900 }
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local v = TALD_V
	local again = self.mgr:processReport(report("t2", after(self.p, v, 5), v), mockTime)
	local da = again.DecoyAssessment
	lu.assertEquals(da.label, DS.PROBABLE)
	lu.assertNil(da.runSince)
	lu.assertEquals(da.runSec, 0)
	lu.assertEquals(da.disproofScans, 0)
	lu.assertTrue(da.launchEvidence > 20 and da.launchEvidence < 30)
	lu.assertNotIs(da, tald.DecoyAssessment)
	lu.assertEquals(again.SeenAs, Medusa.Constants.SeenAs.MUNITION)
	lu.assertEquals(again.SeenAsTime, 990)
	lu.assertEquals(again.LaunchCue, tald.LaunchCue)
end

function TestTrackReacquisitionCarry:test_aWeakMatch_carriesNoDecoyLabelAndNoSightings()
	local v = TALD_V
	local tald = fly(self.mgr, "tald", self.p, v, 8)
	tald.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 30, aircraftEvidence = nil }
	tald.SeenAs = Medusa.Constants.SeenAs.MUNITION
	tald.SeenAsTime = 990
	loseAll(self.mgr)
	mockTime = mockTime + 60
	-- A minute later, 12 km off the straight-line prediction and 60 m/s off its speed: a match, but a loose one.
	local pos = after(self.p, v, 60)
	pos.z = pos.z + 12000
	local again = self.mgr:processReport(report("t2", pos, { x = 260, y = -20, z = 0 }), mockTime)
	lu.assertEquals(again.DisplayTrackId, tald.DisplayTrackId)
	lu.assertEquals(again.DecoyAssessment.label, DS.AIRCRAFT)
	lu.assertNil(again.SeenAs)
end

function TestTrackReacquisitionCarry:test_aContactThatHasNotLostAGlidersEnergy_getsNoDecoyLabel()
	-- A strong fit in position and velocity, but level at the lost decoy's height and speed after 20 s: a glider
	-- would have lost at least speed / 14 every second.
	local tald = fly(self.mgr, "tald", self.p, TALD_V, 8)
	tald.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 30 }
	loseAll(self.mgr)
	mockTime = mockTime + 20
	local pos = after(self.p, { x = 200, y = 0, z = 0 }, 20)
	local again = self.mgr:processReport(report("t2", pos, { x = 200, y = 0, z = 0 }), mockTime)
	lu.assertEquals(again.DisplayTrackId, tald.DisplayTrackId)
	lu.assertEquals(again.DecoyAssessment.label, DS.AIRCRAFT)
	lu.assertEquals(again.DecoyAssessment.launchEvidence, 0)
end

function TestTrackReacquisitionCarry:test_aGapLongerThanTheDecoysRemainingGlide_carriesNoDecoyLabel()
	local tald = fly(self.mgr, "tald", self.p, TALD_V, 8)
	tald.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 30, glideEndsAt = mockTime + 10 }
	loseAll(self.mgr)
	mockTime = mockTime + 20
	local again = self.mgr:processReport(report("t2", after(self.p, TALD_V, 20), TALD_V), mockTime)
	lu.assertEquals(again.DisplayTrackId, tald.DisplayTrackId)
	lu.assertEquals(again.DecoyAssessment.label, DS.AIRCRAFT)
end

function TestTrackReacquisitionCarry:test_anAircraftSighting_isNotCarried()
	-- It would hold back the ARM evaluation of a missile that took its lost launcher's track, with no expiry.
	local jet = fly(self.mgr, "jet", self.p, JET_V, 8)
	jet.SeenAs = Medusa.Constants.SeenAs.AIRCRAFT
	jet.SeenAsTime = 995
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local again = self.mgr:processReport(report("x", after(self.p, JET_V, 5), JET_V), mockTime)
	lu.assertEquals(again.DisplayTrackId, jet.DisplayTrackId)
	lu.assertNil(again.SeenAs)
end

function TestTrackReacquisitionCarry:test_carriedSize_isNoMoreThanJustConfident()
	local jet = fly(self.mgr, "jet", self.p, JET_V, 8)
	jet.SizeDb, jet.SizeWeight, jet.SizeSpreadDb = 7, 4, 1.8
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local again = self.mgr:processReport(report("x", after(self.p, JET_V, 5), JET_V), mockTime)
	lu.assertEquals(again.SizeDb, 7)
	lu.assertTrue(again.SizeWeight <= Medusa.Constants.ContactEvidence.SIZE_CONFIDENT_WEIGHT + 1e-9)
	lu.assertTrue(again.SizeWeight > 0)
	lu.assertEquals(Medusa.Entities.Track.sizeClass(again), "large")
end

function TestTrackReacquisitionCarry:test_aircraftEvidence_isCarriedOnlyOnAStrongFit()
	-- Aircraft evidence is for good on its track: a loose match (it may be a decoy where the jet was) must not
	-- hand it on.
	local jet = fly(self.mgr, "jet", self.p, JET_V, 8)
	jet.DecoyAssessment = { label = DS.AIRCRAFT, launchEvidence = 0, aircraftEvidence = "climb" }
	loseAll(self.mgr)
	mockTime = mockTime + 60
	local pos = after(self.p, JET_V, 60)
	pos.z = pos.z + 12000
	local again = self.mgr:processReport(report("x", pos, { x = 310, y = 0, z = 0 }), mockTime)
	lu.assertEquals(again.DisplayTrackId, jet.DisplayTrackId)
	lu.assertNil(again.DecoyAssessment.aircraftEvidence)
	local q = { x = 0, y = 6000, z = 50000 }
	local jet2 = fly(self.mgr, "jet2", q, JET_V, 8)
	jet2.DecoyAssessment = { label = DS.AIRCRAFT, launchEvidence = 0, aircraftEvidence = "climb" }
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local close = self.mgr:processReport(report("y", after(q, JET_V, 5), JET_V), mockTime)
	lu.assertEquals(close.DisplayTrackId, jet2.DisplayTrackId)
	lu.assertEquals(close.DecoyAssessment.aircraftEvidence, "climb")
end

-- == Ties ==

TestTrackReacquisitionTies = {}

function TestTrackReacquisitionTies:setUp()
	setupMocks()
	self.mgr = newManager(true)
end

function TestTrackReacquisitionTies:test_aTieOfConfirmedArms_carriesTheLabelAtTheWeakestConfidence()
	local a = fly(self.mgr, "a", { x = 0, y = 6000, z = 0 }, ARM_V, 8)
	local b = fly(self.mgr, "b", { x = 0, y = 6000, z = 500 }, ARM_V, 8)
	confirmArm(a, mockTime - 20)
	confirmArm(b, mockTime - 40)
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local c = self.mgr:processReport(report("c", after({ x = 0, y = 6000, z = 250 }, ARM_V, 5), ARM_V), mockTime)
	lu.assertNotEquals(c.DisplayTrackId, a.DisplayTrackId)
	lu.assertNotEquals(c.DisplayTrackId, b.DisplayTrackId)
	lu.assertEquals(c.HarmAssessment.label, HAS.CONFIRMED)
	lu.assertEquals(c.HarmAssessment.confirmedAt, b.HarmAssessment.confirmedAt)
	lu.assertEquals(c.AssessedAircraftType, AAT.HARM)
	-- The tie used up one lost ARM (the best fit); the other is still there for its own contact.
	local d = self.mgr:processReport(report("d", after({ x = 0, y = 6000, z = 250 }, ARM_V, 5), ARM_V), mockTime)
	lu.assertTrue(d.DisplayTrackId == a.DisplayTrackId or d.DisplayTrackId == b.DisplayTrackId)
end

function TestTrackReacquisitionTies:test_aTieOfProbableDecoys_carriesTheLabelWithTheLeastLaunchEvidence()
	local v = TALD_V
	local a = fly(self.mgr, "a", { x = 0, y = 6000, z = 0 }, v, 8)
	local b = fly(self.mgr, "b", { x = 0, y = 6000, z = 500 }, v, 8)
	a.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 30 }
	b.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 10 }
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local c = self.mgr:processReport(report("c", after({ x = 0, y = 6000, z = 250 }, v, 5), v), mockTime)
	lu.assertNotEquals(c.DisplayTrackId, a.DisplayTrackId)
	lu.assertEquals(c.DecoyAssessment.label, DS.PROBABLE)
	lu.assertEquals(c.DecoyAssessment.launchEvidence, 10)
end

function TestTrackReacquisitionTies:test_aTieOfProbableDecoys_isNotHandedToAContactHoldingItsEnergy()
	local v = TALD_V
	local a = fly(self.mgr, "a", { x = 0, y = 6000, z = 0 }, v, 8)
	local b = fly(self.mgr, "b", { x = 0, y = 6000, z = 500 }, v, 8)
	a.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 30 }
	b.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 10 }
	loseAll(self.mgr)
	mockTime = mockTime + 20
	local level = { x = 200, y = 0, z = 0 }
	local c = self.mgr:processReport(report("c", after({ x = 0, y = 6000, z = 250 }, level, 20), level), mockTime)
	lu.assertNotEquals(c.DisplayTrackId, a.DisplayTrackId)
	lu.assertTrue(c.DecoyAssessment == nil or c.DecoyAssessment.label == DS.AIRCRAFT)
end

function TestTrackReacquisitionTies:test_aDecoyTieWithAJetNearlyAsClose_carriesOnlyASuspectLabel()
	-- A jet flying among the decoys may be the contact (recorded mixed flock, 30 s gap): its lost track fits about
	-- a third as well as the tied decoys, too little to tie but enough that a probable-decoy label, which long-range
	-- SAMs ignore, would be a gamble.
	local v = TALD_V
	local a = fly(self.mgr, "a", { x = 0, y = 6000, z = 0 }, v, 8)
	local b = fly(self.mgr, "b", { x = 0, y = 6000, z = 500 }, v, 8)
	fly(self.mgr, "jet", { x = 0, y = 6000, z = 1300 }, v, 8)
	a.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 30 }
	b.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 10 }
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local c = self.mgr:processReport(report("c", after({ x = 0, y = 6000, z = 250 }, v, 5), v), mockTime)
	lu.assertEquals(c.DecoyAssessment.label, DS.SUSPECT)
end

function TestTrackReacquisitionTies:test_aDecoyTieWithAJetNearlyAsClose_carriesNoLaunchEvidenceToRePromoteIt()
	-- The flock's unanswered launches would lift the weakened label straight back to PROBABLE on the contact's
	-- next look (SUSPECT plus enough launch evidence is PROBABLE): only the contact's own flight may do that.
	local v = TALD_V
	local a = fly(self.mgr, "a", { x = 0, y = 6000, z = 0 }, v, 8)
	local b = fly(self.mgr, "b", { x = 0, y = 6000, z = 500 }, v, 8)
	fly(self.mgr, "jet", { x = 0, y = 6000, z = 1300 }, v, 8)
	local D = Medusa.Constants.Decoy
	a.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = D.PROBABLE_SEC, runSec = 0, slope = 0 }
	b.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = D.PROBABLE_SEC, runSec = 0, slope = 0 }
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local c = self.mgr:processReport(report("c", after({ x = 0, y = 6000, z = 250 }, v, 5), v), mockTime)
	c.SizeDb, c.SizeSpreadDb = 20, 0.5
	c.SizeWeight = Medusa.Constants.ContactEvidence.SIZE_MAX_WEIGHT
	lu.assertEquals(Medusa.Entities.Track.sizeClass(c), "large")
	Medusa.Services.DecoyAssessmentService._promote(c, c.DecoyAssessment)
	lu.assertEquals(c.DecoyAssessment.label, DS.SUSPECT)
end

function TestTrackReacquisitionTies:test_aMixedTie_carriesNothing()
	local a = fly(self.mgr, "a", { x = 0, y = 6000, z = 0 }, ARM_V, 8)
	fly(self.mgr, "b", { x = 0, y = 6000, z = 1500 }, ARM_V, 8)
	confirmArm(a, mockTime - 20)
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local c = self.mgr:processReport(report("c", after({ x = 0, y = 6000, z = 750 }, ARM_V, 5), ARM_V), mockTime)
	lu.assertNil(c.HarmAssessment)
	lu.assertNotEquals(c.AssessedAircraftType, AAT.HARM)
	-- Nothing was used up: both lost tracks are still there.
	local d = self.mgr:processReport(report("d", after({ x = 0, y = 6000, z = 0 }, ARM_V, 5), ARM_V), mockTime)
	lu.assertEquals(d.DisplayTrackId, a.DisplayTrackId)
end

-- == Weapons leaving aircraft ==

TestTrackReacquisitionLaunch = {}

function TestTrackReacquisitionLaunch:setUp()
	setupMocks()
	self.mgr = newManager(true)
end

function TestTrackReacquisitionLaunch:test_aContactWithALaunchCue_neverInheritsAnAircraftsTrack()
	-- Two jets 1.5 km apart; one drops out. A missile leaves the other right where the lost one should be, flying
	-- almost as the lost jet did (so position and velocity alone would hand it the lost jet's track).
	local lostV, heldV = { x = 300, y = 0, z = -150 }, { x = 250, y = 0, z = 0 }
	local t0 = mockTime
	local lost, held
	for t = -30, 0 do
		mockTime = t0 + t
		lost = self.mgr:processReport(report("lost", after({ x = 0, y = 6000, z = 0 }, lostV, t), lostV), t0 + t)
		held = self.mgr:processReport(report("held", after({ x = 0, y = 6000, z = 1500 }, heldV, t), heldV), t0 + t)
	end
	for t = 1, 3 do
		mockTime = t0 + t
		held = self.mgr:processReport(report("held", after({ x = 0, y = 6000, z = 1500 }, heldV, t), heldV), t0 + t)
		self.mgr:pruneStale(t0 + t)
	end
	lu.assertNil(self.mgr:getTrackIdByNetworkId("lost"))
	mockTime = t0 + 3
	local missile = self.mgr:processReport(
		report("missile", after({ x = 0, y = 6000, z = 0 }, lostV, 3), { x = 330, y = 0, z = -170 }),
		mockTime
	)
	lu.assertNotNil(missile.LaunchCue)
	lu.assertEquals(missile.LaunchCue.FromTrackId, held.TrackId)
	lu.assertNotEquals(missile.DisplayTrackId, lost.DisplayTrackId)
end

function TestTrackReacquisitionLaunch:test_aContactPullingAwayFromALostAircraft_doesNotInheritIt()
	-- The launcher itself is lost: the missile flies on from where it should be, much faster.
	local p = { x = 0, y = 6000, z = 0 }
	-- 20 s after the loss, 300 m ahead of the jet's prediction and 170 m/s faster: a fit, but a launch.
	local jet = fly(self.mgr, "jet", p, JET_V, 8)
	loseAll(self.mgr)
	mockTime = mockTime + 20
	local missile = self.mgr:processReport(
		report("missile", after(after(p, JET_V, 20), { x = 1, y = 0, z = 0 }, 300), { x = 420, y = 0, z = 0 }),
		mockTime
	)
	lu.assertNotEquals(missile.DisplayTrackId, jet.DisplayTrackId)
	-- The jet itself is still there to be re-acquired.
	local again = self.mgr:processReport(report("jet", after(p, JET_V, 20), JET_V), mockTime)
	lu.assertEquals(again.DisplayTrackId, jet.DisplayTrackId)
end

function TestTrackReacquisitionLaunch:test_aSmallReturnAlone_isNoWeapon()
	-- A low-observable jet returns smaller than an ARM: only a launch cue, ARM-like kinematics (SUSPECT or more), a
	-- missile type or a sighting make a lost track a weapon's.
	local Svc = Medusa.Services.TrackReacquisition
	local e = { SizeDb = -11, SizeWeight = 4, SizeSpreadDb = 1.8 }
	lu.assertEquals(Medusa.Entities.Track.sizeClass(e), "small")
	lu.assertFalse(Svc.isWeapon(e))
	e.HarmAssessment = { label = HAS.SUSPECT }
	lu.assertTrue(Svc.isWeapon(e))
end

function TestTrackReacquisitionLaunch:test_aFastWeaponMayStillReacquireALostWeaponsTrack()
	local p = { x = 0, y = 6000, z = 0 }
	local arm = fly(self.mgr, "arm", p, { x = 500, y = 0, z = 0 }, 8)
	arm.LaunchCue = { FromTrackId = "x", Time = 900 }
	loseAll(self.mgr)
	mockTime = mockTime + 5
	local again = self.mgr:processReport(
		report("arm2", after(p, { x = 550, y = 0, z = 0 }, 5), { x = 650, y = 0, z = 0 }),
		mockTime
	)
	lu.assertEquals(again.DisplayTrackId, arm.DisplayTrackId)
end

-- == Log lines ==

TestTrackReacquisitionLog = {}

function TestTrackReacquisitionLog:setUp()
	setupMocks()
	self.mgr = newManager(true)
	self.lines = {}
	self.originalInfo = env.info
	local lines = self.lines
	env.info = function(message)
		lines[#lines + 1] = message
	end
end

function TestTrackReacquisitionLog:tearDown()
	env.info = self.originalInfo
end

local function find(lines, text)
	for i = 1, #lines do
		if lines[i]:find(text, 1, true) then
			return lines[i]
		end
	end
	return nil
end

function TestTrackReacquisitionLog:test_aMatch_logsOneReacquiredLine()
	local p = { x = 0, y = 6000, z = 0 }
	local arm = fly(self.mgr, "arm", p, ARM_V, 8)
	confirmArm(arm, mockTime - 30)
	loseAll(self.mgr)
	mockTime = mockTime + 10
	self.mgr:processReport(report("x", after(p, ARM_V, 10), ARM_V), mockTime)
	local line = find(self.lines, "re-acquired track " .. arm.DisplayTrackId)
	lu.assertNotNil(line)
	lu.assertStrContains(line, "gap 10s")
	lu.assertStrContains(line, "ARM CONFIRMED")
end

function TestTrackReacquisitionLog:test_aMixedTie_logsARefusal()
	local a = fly(self.mgr, "a", { x = 0, y = 6000, z = 0 }, ARM_V, 8)
	fly(self.mgr, "b", { x = 0, y = 6000, z = 500 }, ARM_V, 8)
	confirmArm(a, mockTime - 20)
	loseAll(self.mgr)
	mockTime = mockTime + 5
	self.mgr:processReport(report("c", after({ x = 0, y = 6000, z = 250 }, ARM_V, 5), ARM_V), mockTime)
	lu.assertNotNil(find(self.lines, "re-acquisition refused"))
end

-- == Silent tracks still held ==
-- With the default track memory (30 s) a confirmed ARM missing two looks in a row (its own refresh interval, from its
-- last two looks, and two of the slowest radar's still covering it: TestTrackReacquisitionCover) can already be
-- continued by a new contact; the DCS object it was holding resumes it as before.

TestTrackReacquisitionSilent = {}

function TestTrackReacquisitionSilent:setUp()
	setupMocks()
	self.mgr = Medusa.Services.TrackManager:new({
		geoGrid = GeoGrid(10000, { "Battery", "Track" }),
		displayIdAllocator = Medusa.Services.TrackDisplayIdAllocator:new(),
		evidenceReacquisition = true,
	})
	self.p = { x = 0, y = 6000, z = 0 }
end

--- Fly a contact straight for `sec` seconds with looks every `step` seconds, ending at mockTime.
function TestTrackReacquisitionSilent:fly(id, vel, sec, step)
	local track, t0 = nil, mockTime
	for i = sec, 0, -step do
		mockTime = t0 - i
		track = self.mgr:processReport(report(id, after(self.p, vel, -i), vel), mockTime)
	end
	return track
end

--- A confirmed ARM seen every 2 s, then silent for `gap` s (the network prunes every second meanwhile).
function TestTrackReacquisitionSilent:silentArm(gap)
	local arm = self:fly("arm", ARM_V, 8, 2)
	confirmArm(arm, mockTime - 30)
	local t0 = mockTime
	for t = t0 + 1, t0 + gap do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	return arm, t0
end

function TestTrackReacquisitionSilent:test_aNewContactWhereASilentArmShouldBe_continuesIt_withItsLabel()
	local arm = self:silentArm(6)
	local again = self.mgr:processReport(report("arm#2", after(self.p, ARM_V, 6), ARM_V), mockTime)
	lu.assertEquals(again.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNotEquals(again.TrackId, arm.TrackId)
	lu.assertEquals(again.HarmAssessment.label, HAS.CONFIRMED)
	lu.assertEquals(again.HarmAssessment.disproofSince, arm.HarmAssessment.disproofSince + 6)
	lu.assertEquals(again.AssessedAircraftType, AAT.HARM)
	-- The held track is gone: not in the store or the grid, and its DCS object no longer maps to anything.
	lu.assertNil(self.mgr:getStore():get(arm.TrackId))
	lu.assertNil(self.mgr:getTrackIdByNetworkId("arm"))
	lu.assertEquals(self.mgr:getTrackIdByNetworkId("arm#2"), again.TrackId)
	lu.assertNil(self.mgr._lost[arm.TrackId])
end

function TestTrackReacquisitionSilent:test_aTrackSilentForLessThanTwoOfItsLooks_isNoCandidate()
	local arm = self:silentArm(3)
	local other = self.mgr:processReport(report("arm#2", after(self.p, ARM_V, 3), ARM_V), mockTime)
	lu.assertNotEquals(other.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(other.HarmAssessment)
	lu.assertNotNil(self.mgr:getStore():get(arm.TrackId))
end

function TestTrackReacquisitionSilent:test_aSlowRadarsTrackWaitsForTwoOfItsLooks()
	local arm = self:fly("arm", ARM_V, 20, 5)
	confirmArm(arm, mockTime - 30)
	local t0 = mockTime
	for t = t0 + 1, t0 + 8 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	local other = self.mgr:processReport(report("x", after(self.p, ARM_V, 8), ARM_V), mockTime)
	lu.assertNotEquals(other.DisplayTrackId, arm.DisplayTrackId)
	for t = mockTime + 1, t0 + 11 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	local again = self.mgr:processReport(report("y", after(self.p, ARM_V, 11), ARM_V), mockTime)
	lu.assertEquals(again.DisplayTrackId, arm.DisplayTrackId)
	lu.assertEquals(again.HarmAssessment.label, HAS.CONFIRMED)
end

function TestTrackReacquisitionSilent:test_theSameObjectReturning_resumesItsHeldTrack_andItIsNoLongerACandidate()
	local arm = self:silentArm(6)
	lu.assertNotNil(self.mgr._lost[arm.TrackId])
	local same = self.mgr:processReport(report("arm", after(self.p, ARM_V, 6), ARM_V), mockTime)
	lu.assertIs(same, arm)
	lu.assertNil(self.mgr._lost[arm.TrackId])
	mockTime = mockTime + 1
	local other = self.mgr:processReport(report("arm#2", after(self.p, ARM_V, 7), ARM_V), mockTime)
	lu.assertNotEquals(other.DisplayTrackId, arm.DisplayTrackId)
end

function TestTrackReacquisitionSilent:test_aSilentTrackThatExpires_isListedOnce_asLostFromItsExpiry()
	local arm = self:silentArm(6)
	lu.assertTrue(self.mgr._lost[arm.TrackId].Held)
	local goneAt
	for t = mockTime + 1, mockTime + 40 do
		mockTime = t
		self.mgr:pruneStale(t)
		if not goneAt and not self.mgr:getStore():get(arm.TrackId) then
			goneAt = t
		end
	end
	lu.assertNotNil(goneAt)
	local n = 0
	for _ in pairs(self.mgr._lost) do
		n = n + 1
	end
	lu.assertEquals(n, 1)
	local e = self.mgr._lost[arm.TrackId]
	lu.assertNil(e.Held)
	lu.assertEquals(e.expiredAt, goneAt)
end

function TestTrackReacquisitionSilent:test_aHeldTrackClearedWhileSilent_isNoLongerOffered()
	local arm = self:silentArm(6)
	-- Cleared while silent (by whatever the network learned meanwhile): it is no ARM now, and like any other held
	-- track it waits for its own object. A contact where it should be is a new track with nothing ARM.
	arm.HarmAssessment.label = HAS.CLEARED
	arm.AssessedAircraftType = AAT.UNKNOWN
	arm.IsSeadThreat = false
	local again = self.mgr:processReport(report("arm#2", after(self.p, ARM_V, 6), ARM_V), mockTime)
	lu.assertNotEquals(again.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(again.HarmAssessment)
	lu.assertEquals(again.AssessedAircraftType, AAT.UNKNOWN)
end

function TestTrackReacquisitionSilent:test_aHeldCandidateNeverReleasesTheDisplayIdOfALiveTrack()
	self.mgr._trackMemoryDurationSec = 600
	local arm = self:silentArm(6)
	for t = mockTime + 1, mockTime + Medusa.Constants.TRACK_REASSOC_TTL_SEC + 10 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	lu.assertNotNil(self.mgr:getStore():get(arm.TrackId))
	-- Its display id is still taken: a new track gets another one.
	local other = self.mgr:processReport(report("z", { x = 900000, y = 6000, z = 0 }, JET_V), mockTime)
	lu.assertNotEquals(other.DisplayTrackId, arm.DisplayTrackId)
end

function TestTrackReacquisitionSilent:test_aTieOfSilentArms_retiresTheBestHeldTrack()
	local a = self:fly("a", ARM_V, 8, 2)
	self.p = { x = 0, y = 6000, z = 500 }
	local b = self:fly("b", ARM_V, 8, 2)
	confirmArm(a, mockTime - 20)
	confirmArm(b, mockTime - 25)
	for t = mockTime + 1, mockTime + 6 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	local c = self.mgr:processReport(report("c", after({ x = 0, y = 6000, z = 250 }, ARM_V, 6), ARM_V), mockTime)
	lu.assertEquals(c.HarmAssessment.label, HAS.CONFIRMED)
	local left = 0
	for _, t in ipairs({ a, b }) do
		if self.mgr:getStore():get(t.TrackId) then
			left = left + 1
			lu.assertNotNil(self.mgr._lost[t.TrackId])
		end
	end
	lu.assertEquals(left, 1)
end

function TestTrackReacquisitionSilent:test_anArmSilentForTwoLooks_isNoLaunchCueParent()
	-- Its last position is stale: a contact seen again ahead of it would seem to pull away from it.
	local arm = self:silentArm(6)
	lu.assertTrue(arm.HeldLost)
	local q = after(self.p, ARM_V, 6)
	local w = self.mgr:processReport(report("w", { x = q.x + 3000, y = q.y, z = q.z + 3000 }, ARM_V), mockTime)
	lu.assertNil(w.LaunchCue)
end

--- A jet with aircraft evidence (a confident 5 m2 return; none when `noSize`) seen every 2 s for 40 s, `setup(jet)`
--- applied, then silent for `gap` s while the network prunes every second.
function TestTrackReacquisitionSilent:silentJet(gap, setup, noSize)
	local jet, t0 = nil, mockTime
	for i = 40, 0, -2 do
		mockTime = t0 - i
		local r = report("jet", after(self.p, JET_V, -i), JET_V)
		if not noSize then
			r.SizeDb, r.SizeVarDb = 7, 4
		end
		jet = self.mgr:processReport(r, mockTime)
	end
	if setup then
		setup(jet)
	end
	for t = t0 + 1, t0 + gap do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	return jet, t0
end

function TestTrackReacquisitionSilent:test_aStoreSeenWhereASilentJetShouldBe_neverTakesItsTrack()
	-- A jet seen every 2 s by a SAM radar that then shuts down, still covered by a 10 s early-warning radar: its next
	-- look is not due yet. A store it releases meanwhile, seen first, is the jet's store, not the jet.
	local cases = {
		{ name = "plain" },
		{ name = "no size evidence", noSize = true, noCarrier = true }, -- not known as an aircraft: no carrier either
		{
			name = "probable ARM-like",
			noCarrier = true, -- an ARM-like track carries no released store (TrackManager._carrierArmLike)
			setup = function(j)
				j.HarmAssessment = { label = HAS.PROBABLE, llr = 5, scanCount = 12 }
			end,
		},
		{
			name = "launch-cued",
			noCarrier = true, -- nor does one with a launch cue of its own
			setup = function(j)
				j.LaunchCue = { FromTrackId = "elsewhere", Time = 970 }
			end,
		},
	}
	for _, case in ipairs(cases) do
		for _, dv in ipairs({ 0, 100, 200 }) do
			local how = case.name .. ", +" .. dv .. " m/s"
			self:setUp()
			local jet = self:silentJet(6, case.setup, case.noSize)
			lu.assertNil(jet.HeldLost, how)
			local q = after(self.p, JET_V, 6)
			local v = { x = JET_V.x + dv, y = 0, z = 0 }
			local store =
				self.mgr:processReport(report("store", { x = q.x - 300, y = q.y - 100, z = q.z }, v), mockTime)
			lu.assertNotEquals(store.DisplayTrackId, jet.DisplayTrackId, how)
			lu.assertIs(self.mgr:getStore():get(jet.TrackId), jet, how)
			if case.noCarrier then
				lu.assertNil(store.HarmAssessment, how)
			elseif dv <= 100 then
				-- moving with the jet: a store it released (Medusa.Constants.Release)
				lu.assertNotNil(store.Release, how)
				lu.assertEquals(store.Release.CarrierId, jet.TrackId, how)
			else
				-- pulling away from it: a launch cue from the jet
				lu.assertNotNil(store.LaunchCue, how)
				lu.assertEquals(store.LaunchCue.FromTrackId, jet.TrackId, how)
			end
			-- the jet's next look (its own DCS object) resumes its track
			mockTime = mockTime + 4
			local again = self.mgr:processReport(report("jet", after(self.p, JET_V, 10), JET_V), mockTime)
			lu.assertIs(again, jet, how)
		end
	end
end

function TestTrackReacquisitionSilent:test_onlyAConfirmedArmWithoutAircraftEvidence_isListedWhileHeld()
	local arm = self:silentArm(6)
	lu.assertTrue(arm.HeldLost)
	-- the same ARM flight with an aircraft-sized return: not listed
	self:setUp()
	local big = self:fly("big", ARM_V, 8, 2)
	big.SizeDb, big.SizeWeight, big.SizeSpreadDb = 7, 4, 1.8
	confirmArm(big, mockTime - 30)
	for t = mockTime + 1, mockTime + 6 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	lu.assertNil(big.HeldLost)
	-- typed HARM without a confirmed label: it has no label to hand on, and waits for its own object
	self:setUp()
	local typed = self:fly("typed", ARM_V, 8, 2)
	typed.AssessedAircraftType = AAT.HARM
	for t = mockTime + 1, mockTime + 6 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	lu.assertNil(typed.HeldLost)
end

function TestTrackReacquisitionSilent:test_aSalvoMateBesideAnArmWhoseOnlyRadarShutDown_takesItsLabel()
	-- The only radar covering the ARM (a SAM radar looking every 2 s) shut down; a second ARM of the salvo is then
	-- first seen beside the first (by a radar that did not cover the first). Nothing tells the two apart: the new
	-- contact continues the silent ARM's track, confirmed, and the first ARM, seen again later, comes back as a new
	-- track judged on its own flight. One of the two is confirmed either way, as when the second ARM is a new track.
	local arm = self:silentArm(6)
	local q = after(self.p, ARM_V, 6)
	local mate = self.mgr:processReport(report("mate", { x = q.x - 400, y = q.y, z = q.z + 300 }, ARM_V), mockTime)
	lu.assertEquals(mate.DisplayTrackId, arm.DisplayTrackId)
	lu.assertEquals(mate.HarmAssessment.label, HAS.CONFIRMED)
	for t = mockTime + 1, mockTime + 4 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	local again = self.mgr:processReport(report("arm", after(self.p, ARM_V, 10), ARM_V), mockTime)
	lu.assertNotEquals(again.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(again.HarmAssessment)
end

function TestTrackReacquisitionSilent:test_anArmStillCoveredByASlowerRadar_keepsItsTrackFromASalvoMate()
	-- A SAM radar looked every 2 s and shut down, while a 10 s early-warning radar that last detected the ARM at t0
	-- still covers it (the network's polls say so) until t0 + 20: the ARM is not lost before then, so a salvo mate
	-- first seen beside it is a new track, and the ARM's own next look resumes it, confirmed.
	local t0 = mockTime
	self.mgr:setCoverSource({
		coveredUntil = function(_, id)
			return id == "arm" and t0 + 20 or nil
		end,
	})
	local arm = self:silentArm(6)
	lu.assertNil(arm.HeldLost)
	local q = after(self.p, ARM_V, 6)
	local mate = self.mgr:processReport(report("mate", { x = q.x - 400, y = q.y, z = q.z + 300 }, ARM_V), mockTime)
	lu.assertNotEquals(mate.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(mate.HarmAssessment)
	for t = mockTime + 1, t0 + 10 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	local again = self.mgr:processReport(report("arm", after(self.p, ARM_V, 10), ARM_V), mockTime)
	lu.assertIs(again, arm)
	lu.assertEquals(again.HarmAssessment.label, HAS.CONFIRMED)
end

function TestTrackReacquisitionSilent:test_aHeldArmSilentLongerThanItsLabelCrosses_waitsForItsOwnObject()
	-- Past the longest gap its label crosses, a contact continuing the held ARM would take only its track, without the
	-- label, and the ARM's own object would come back as a new, unlabeled track: the ARM waits for its own object.
	local arm, t0 = self:silentArm(22)
	lu.assertTrue(arm.HeldLost)
	local q = after(self.p, ARM_V, 22)
	local mate = self.mgr:processReport(report("mate", { x = q.x - 400, y = q.y, z = q.z + 300 }, ARM_V), mockTime)
	lu.assertNotEquals(mate.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(mate.HarmAssessment)
	mockTime = t0 + 24
	local again = self.mgr:processReport(report("arm", after(self.p, ARM_V, 24), ARM_V), mockTime)
	lu.assertIs(again, arm)
	lu.assertEquals(again.HarmAssessment.label, HAS.CONFIRMED)
end

function TestTrackReacquisitionSilent:test_aJetSpeedContactBesideASilentArm_doesNotTakeItsLabel()
	-- The only radar covering the ARM (a SAM radar looking every 2 s) shut down, so the ARM is lost to new contacts. A
	-- jet-speed contact seen beside it is too slow to be it and does not take the label; the ARM's own next look
	-- resumes it, confirmed.
	local arm = self:silentArm(6)
	local q = after(self.p, ARM_V, 6)
	local jet = self.mgr:processReport(report("jet", { x = q.x - 500, y = q.y, z = q.z }, JET_V), mockTime)
	lu.assertNotEquals(jet.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(jet.HarmAssessment)
	for t = mockTime + 1, mockTime + 4 do
		mockTime = t
		self.mgr:pruneStale(t)
	end
	local again = self.mgr:processReport(report("arm", after(self.p, ARM_V, 10), ARM_V), mockTime)
	lu.assertIs(again, arm)
	lu.assertEquals(again.HarmAssessment.label, HAS.CONFIRMED)
	lu.assertNil(arm.HeldLost)
end

function TestTrackReacquisitionSilent:test_aSilentTrackMergedAway_leavesTheLostList()
	local arm = self:silentArm(6)
	self.p = { x = 0, y = 6000, z = 200000 }
	mockTime = mockTime + 1
	local other = self.mgr:processReport(report("other", self.p, ARM_V), mockTime)
	self.mgr:mergeTracks(other.TrackId, arm.TrackId, mockTime)
	lu.assertNil(self.mgr._lost[arm.TrackId])
end

-- == A held ARM and the radars covering it, from the polls to the track ==
-- An early-warning radar (10 s) and a SAM radar (2 s) are polled every 0.5 s; each look is throttled per object
-- network-wide, so the track's looks come at the fastest radar's rate. A silent confirmed ARM is lost to new contacts
-- only once the slowest radar still covering it has missed two of its looks too.

TestTrackReacquisitionCover = {}

function TestTrackReacquisitionCover:setUp()
	setupMocks()
	self.svc = Medusa.Services.SensorPollingService:new({ PerTrackScanUpdateRate = 5, SensorCleanupSec = 60 })
	self.mgr = Medusa.Services.TrackManager:new({
		geoGrid = GeoGrid(10000, { "Battery", "Track" }),
		displayIdAllocator = Medusa.Services.TrackDisplayIdAllocator:new(),
		evidenceReacquisition = true,
	})
	self.mgr:setCoverSource(self.svc)
	self.rate = { ewr = 10, sam = 2 }
	self.objs, self.sees = {}, {}
	local w = self
	GetGroupController = function(name)
		return name
	end
	GetControllerDetectedTargets = function(c)
		local out, f = {}, w.sees[c]
		for _, o in ipairs(w.objs) do
			if f and f(o.id_, mockTime) then
				out[#out + 1] = { object = o }
			end
		end
		return out
	end
end

--- An ARM flying ARM_V, at (dx, 9000, dz) at t = 1000.
function TestTrackReacquisitionCover:add(id, dx, dz)
	local o = { id_ = id }
	function o.getCategory()
		return Object.Category.WEAPON
	end
	function o.getPoint()
		return after({ x = dx, y = 9000, z = dz }, ARM_V, mockTime - 1000)
	end
	function o.getVelocity()
		return { x = ARM_V.x, y = ARM_V.y, z = ARM_V.z }
	end
	function o.getName()
		return id
	end
	self.objs[#self.objs + 1] = o
end

--- Poll both radars and prune every 0.5 s from t0 to t1.
function TestTrackReacquisitionCover:run(t0, t1)
	for t = t0, t1, 0.5 do
		mockTime = t
		for _, name in ipairs({ "ewr", "sam" }) do
			local reports = self.svc:pollSensor(name, t, nil, self.rate[name])
			for i = 1, #reports do
				self.mgr:processReport(reports[i], t)
			end
		end
		self.mgr:pruneStale(t)
	end
end

function TestTrackReacquisitionCover:track(id)
	return self.mgr:getStore():get(self.mgr:getTrackIdByNetworkId(id))
end

function TestTrackReacquisitionCover:test_aSlowRadarFirstSeeingTheArmAfterTheFastOneShutDown_keepsItsTrack()
	-- The SAM radar alone saw the ARM and shut down; the early-warning radar detects it a second later, but its look
	-- is throttled (the SAM reported it less than 10 s ago). A salvo mate seen beside it is a new track, and the
	-- early-warning radar's report resumes the ARM, confirmed.
	self:add("arm", 0, 0)
	self.sees.sam = function(id, t)
		return id == "arm" and t < 1010.2
	end
	self.sees.ewr = function(id, t)
		return (id == "arm" and t >= 1011) or id == "mate"
	end
	self:run(1000, 1010)
	local arm = self:track("arm")
	confirmArm(arm, 980)
	self:run(1010.5, 1015.5)
	lu.assertNil(arm.HeldLost)
	self:add("mate", -400, 300)
	self:run(1016, 1016)
	local mate = self:track("mate")
	lu.assertNotEquals(mate.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(mate.HarmAssessment)
	self:run(1016.5, 1021)
	lu.assertIs(self:track("arm"), arm)
	lu.assertTrue(arm.LastDetectionTime >= 1020)
	lu.assertEquals(arm.HarmAssessment.label, HAS.CONFIRMED)
end

function TestTrackReacquisitionCover:test_aSlowRadarFirstSeeingTheArmAfterItWasLost_stillKeepsItsTrack()
	-- The SAM radar alone saw the ARM and shut down; it is lost to new contacts after 4 s. The early-warning radar
	-- first detects it a second later (its look throttled until 10 s after the SAM's last report): the ARM may be seen
	-- again, so a salvo mate seen beside it does not take its track, and the early-warning radar's report resumes it.
	self:add("arm", 0, 0)
	self.sees.sam = function(id, t)
		return id == "arm" and t < 1010.2
	end
	self.sees.ewr = function(id, t)
		return (id == "arm" and t >= 1015) or id == "mate"
	end
	self:run(1000, 1010)
	local arm = self:track("arm")
	confirmArm(arm, 980)
	self:run(1010.5, 1015.5)
	lu.assertTrue(arm.HeldLost)
	self:add("mate", -400, 300)
	self:run(1016, 1016)
	local mate = self:track("mate")
	lu.assertNotEquals(mate.DisplayTrackId, arm.DisplayTrackId)
	lu.assertNil(mate.HarmAssessment)
	self:run(1016.5, 1021)
	lu.assertIs(self:track("arm"), arm)
	lu.assertTrue(arm.LastDetectionTime >= 1020)
	lu.assertEquals(arm.HarmAssessment.label, HAS.CONFIRMED)
end

function TestTrackReacquisitionCover:test_aRadarThatLostTheArmEarlier_doesNotHoldItLongerThanItsOwnLooks()
	-- The early-warning radar last detected the ARM at 1010 (diving under its horizon); the SAM radar tracked it on
	-- to 1025 and shut down. Two of the early-warning radar's looks are missed at 1030: the ARM is lost then.
	self:add("arm", 0, 0)
	self.sees.sam = function(_, t)
		return t < 1025.2
	end
	self.sees.ewr = function(_, t)
		return t < 1010.2
	end
	self:run(1000, 1025)
	local arm = self:track("arm")
	confirmArm(arm, 980)
	self:run(1025.5, 1030)
	lu.assertNil(arm.HeldLost)
	self:run(1030.5, 1031)
	lu.assertTrue(arm.HeldLost)
end

function TestTrackReacquisitionCover:test_aBatteryThatSpeedsUpAndShutsDown_losesTheArmAtItsNewRate()
	-- One battery searched every 5 s, then engaged (every 2 s) and shut down: no slower radar covers the ARM.
	self:add("arm", 0, 0)
	self.sees.sam = function(_, t)
		return t < 1012.2
	end
	self.rate.sam = 5
	self:run(1000, 1010)
	local arm = self:track("arm")
	confirmArm(arm, 980)
	self.rate.sam = 2
	self:run(1010.5, 1016)
	lu.assertNil(arm.HeldLost)
	self:run(1016.5, 1017)
	lu.assertTrue(arm.HeldLost)
end
