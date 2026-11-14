local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Config")
require("entities.Entities")
require("entities.Track")
require("services.Services")
require("services.MetricsService")
require("services.stores.TrackStore")
require("services.TrackDisplayIdAllocator")
require("services.TrackManager")

-- Evidence-based re-acquisition against recorded DCS scenes (tests/reacq_dcs_trajectories.lua): every 10 s, every
-- contact in view drops out together for G seconds (a worst case: siblings lost at once), then the real TrackManager
-- sees them again under the same DCS object ids, which it must not use. ARMs are held as confirmed and TALDs as
-- probable decoys when they drop out. `held` scenes keep the default track memory (30 s): the silent tracks are still
-- held, and the contacts come back as other DCS objects, so only the evidence can join them.

local scenes = require("reacq_dcs_trajectories")
local HAS = Medusa.Constants.HarmAssessmentState
local DS = Medusa.Constants.DecoyState
local SRC = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
local mockTime = 0

local function row(tr, t)
	local best
	for i = 1, #tr.pts do
		if tr.pts[i][1] <= t then
			best = tr.pts[i]
		else
			break
		end
	end
	return best
end

local function report(tr, r)
	return {
		NetworkId = tr.name,
		SourceType = SRC,
		Position = { x = r[2], y = r[3], z = r[4] },
		Velocity = { x = r[5], y = r[6], z = r[7] },
	}
end

local held = false

local function newManager()
	local mgr = Medusa.Services.TrackManager:new({
		geoGrid = GeoGrid(10000, { "Battery", "Track" }),
		displayIdAllocator = Medusa.Services.TrackDisplayIdAllocator:new(),
		evidenceReacquisition = true,
	})
	if not held then
		mgr._trackMemoryDurationSec = 1
	end
	return mgr
end

local function process(mgr, tr, r, rename)
	mockTime = r[1]
	local rep = report(tr, r)
	if rename then
		rep.NetworkId = tr.name .. "#2"
	end
	return mgr:processReport(rep, mockTime)
end

--- The contacts in view at t0 that live on past t1, fed from their last 6 s, labeled, then all dropped.
local function loseScene(scene, t0, t1)
	local lost, rows = {}, {}
	for _, tr in ipairs(scene.tracks) do
		local last = row(tr, t0)
		if last and t0 - last[1] < 1.5 and tr.pts[#tr.pts][1] >= t1 + 1 then
			local L = { tr = tr }
			lost[#lost + 1] = L
			for _, r in ipairs(tr.pts) do
				if r[1] >= t0 - 6 and r[1] <= t0 then
					rows[#rows + 1] = { L = L, r = r }
				end
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.r[1] < b.r[1]
	end)
	local mgr = newManager()
	for _, e in ipairs(rows) do
		e.L.track = process(mgr, e.L.tr, e.r)
	end
	local byDisplay = {}
	for _, L in ipairs(lost) do
		byDisplay[L.track.DisplayTrackId] = L
		if L.tr.kind == "arm" then
			L.track.HarmAssessment = { label = HAS.CONFIRMED, llr = 9, scanCount = 10, confirmedAt = t0 - 10 }
			L.track.AssessedAircraftType = Medusa.Constants.AssessedAircraftType.HARM
		elseif L.tr.kind == "tald" then
			L.track.DecoyAssessment = { label = DS.PROBABLE, launchEvidence = 0, runSec = 0 }
		end
	end
	if held then
		-- The network prunes every tick while they are silent (here every second, and just before they reappear).
		for t = t0 + 1, t1 - 1 do
			mockTime = t
			mgr:pruneStale(t)
		end
		mockTime = t1 - 0.1
		mgr:pruneStale(mockTime)
	else
		mockTime = t0 + 1.6
		mgr:pruneStale(mockTime)
		mgr:pruneStale(mockTime)
	end
	return mgr, lost, byDisplay
end

local function reappear(mgr, lost, t1, visit)
	for _, L in ipairs(lost) do
		local r = row(L.tr, t1)
		if r and t1 - r[1] < 1.5 then
			visit(L, process(mgr, L.tr, r, held))
		end
	end
end

local function isArm(track)
	return track.HarmAssessment ~= nil and track.HarmAssessment.label == HAS.CONFIRMED
end

local function decoyLabel(track)
	local da = track.DecoyAssessment
	return da and da.label ~= DS.AIRCRAFT and da.label or nil
end

local function closedWorld(gap)
	local n = { arm = 0, armKept = 0, jetArm = 0, tald = 0, taldKept = 0, otherDecoy = 0, taken = 0, wrongTake = 0 }
	for _, scene in ipairs(scenes) do
		local stop = scene.tracks[1].pts[#scene.tracks[1].pts][1]
		for t0 = 10, stop, 10 do
			local mgr, lost, byDisplay = loseScene(scene, t0, t0 + gap)
			reappear(mgr, lost, t0 + gap, function(L, track)
				local kind = L.tr.kind
				n[kind] = (n[kind] or 0) + 1
				local who = byDisplay[track.DisplayTrackId]
				if who then
					n.taken = n.taken + 1
					n.wrongTake = n.wrongTake + (who ~= L and 1 or 0)
				end
				if kind == "arm" and isArm(track) then
					n.armKept = n.armKept + 1
				elseif kind ~= "arm" and isArm(track) then
					n.jetArm = n.jetArm + 1
				end
				if kind == "tald" and decoyLabel(track) then
					n.taldKept = n.taldKept + 1
				elseif kind ~= "tald" and decoyLabel(track) then
					n.otherDecoy = n.otherDecoy + 1
				end
			end)
		end
	end
	return n
end

local function bornBetween(scene, t0, t1)
	local out = {}
	for _, tr in ipairs(scene.tracks) do
		local first = tr.pts[1][1]
		if first > t0 and first <= t1 and tr.pts[#tr.pts][1] >= t1 + 1 then
			out[#out + 1] = tr
		end
	end
	return out
end

--- Open world: contacts first seen during the gap (weapons fired by jets that were out of view) also look for a lost
--- track. `newbornsFirst` is the worst case (every lost track still unclaimed, no launcher back in view).
local function openWorld(gap, newbornsFirst)
	local n = { cue = 0, cueInheritsJet = 0, arm = 0, armInheritsJet = 0 }
	for _, scene in ipairs(scenes) do
		local stop = scene.tracks[1].pts[#scene.tracks[1].pts][1]
		for t0 = 5, stop, 5 do
			local t1 = t0 + gap
			local born = bornBetween(scene, t0, t1)
			if #born > 0 then
				local mgr, lost, byDisplay = loseScene(scene, t0, t1)
				if not newbornsFirst then
					reappear(mgr, lost, t1, function() end)
				end
				for _, tr in ipairs(born) do
					local track = process(mgr, tr, row(tr, t1))
					local who = byDisplay[track.DisplayTrackId]
					local inheritsJet = who ~= nil and who.tr.kind == "jet"
					if track.LaunchCue then
						n.cue = n.cue + 1
						n.cueInheritsJet = n.cueInheritsJet + (inheritsJet and 1 or 0)
					end
					if tr.kind == "arm" then
						n.arm = n.arm + 1
						n.armInheritsJet = n.armInheritsJet + (inheritsJet and 1 or 0)
					end
				end
			end
		end
	end
	return n
end

TestTrackReacquisitionReplay = {}

function TestTrackReacquisitionReplay:setUp()
	GetTime = function()
		return mockTime
	end
	local ulid = 0
	NewULID = function()
		ulid = ulid + 1
		return "R" .. ulid
	end
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	self.info = env.info
	env.info = function() end
end

function TestTrackReacquisitionReplay:tearDown()
	env.info = self.info
	held = false
end

function TestTrackReacquisitionReplay:test_armsDroppingOutUpTo10s_stayConfirmed_andNoJetTakesTheLabel()
	for _, gap in ipairs({ 5, 10 }) do
		local n = closedWorld(gap)
		lu.assertTrue(n.arm >= 40, "too few ARM cases at " .. gap .. " s: " .. n.arm)
		lu.assertTrue(
			n.armKept / n.arm >= 0.85,
			string.format("%d/%d ARMs stayed confirmed at %d s", n.armKept, n.arm, gap)
		)
		lu.assertEquals(n.jetArm, 0, "jets or TALDs that inherited an ARM label at " .. gap .. " s")
	end
	-- The longest gap an ARM label crosses: still no jet takes it (here a jet turning away from its own lost ARM
	-- would, but for the speed test).
	lu.assertEquals(closedWorld(20).jetArm, 0)
end

function TestTrackReacquisitionReplay:test_aTaldFlockKeepsItsDecoyLabel_andNothingElseTakesIt()
	for _, gap in ipairs({ 5, 10 }) do
		local n = closedWorld(gap)
		lu.assertTrue(n.tald >= 30, "too few TALD cases: " .. n.tald)
		lu.assertTrue(n.taldKept / n.tald >= 0.9, string.format("%d/%d TALDs kept a decoy label", n.taldKept, n.tald))
		lu.assertEquals(n.otherDecoy, 0)
	end
end

function TestTrackReacquisitionReplay:test_openWorld_aContactWithALaunchCueNeverInheritsAJetsTrack()
	local cues = 0
	for _, gap in ipairs({ 5, 10, 20 }) do
		local n = openWorld(gap, false)
		cues = cues + n.cue
		lu.assertEquals(n.cueInheritsJet, 0, "launch-cued contacts that inherited a jet's track at " .. gap .. " s")
	end
	lu.assertTrue(cues >= 20, "too few launch-cued contacts to judge: " .. cues)
end

function TestTrackReacquisitionReplay:test_openWorld_worstCase_fewNewArmsInheritAJetsTrack()
	-- Every launcher still out of view: no launch cue is possible, only the speed test against the lost jets.
	local arms, wrong = 0, 0
	for _, gap in ipairs({ 5, 10, 20 }) do
		local n = openWorld(gap, true)
		arms, wrong = arms + n.arm, wrong + n.armInheritsJet
	end
	lu.assertTrue(arms >= 20, "too few new ARMs: " .. arms)
	-- 2 of 87 here (5 without the launch and ARM speed tests).
	lu.assertTrue(wrong / arms <= 0.03, string.format("%d/%d new ARMs inherited a jet's track", wrong, arms))
end

-- Tracks silent within the default track memory (30 s), the contacts back as other DCS objects: two looks missed
-- (here 2 s looks) list a track as lost, then the ARM window applies.
function TestTrackReacquisitionReplay:test_held_armsSilentUpTo10s_stayConfirmed_andNoJetTakesTheLabel()
	held = true
	for _, gap in ipairs({ 5, 10 }) do
		local n = closedWorld(gap)
		lu.assertTrue(n.arm >= 40, "too few ARM cases at " .. gap .. " s: " .. n.arm)
		lu.assertTrue(
			n.armKept / n.arm >= 0.85,
			string.format("%d/%d ARMs stayed confirmed at %d s", n.armKept, n.arm, gap)
		)
		lu.assertEquals(n.jetArm, 0, "jets or TALDs that inherited an ARM label at " .. gap .. " s")
	end
	lu.assertEquals(closedWorld(20).jetArm, 0)
end

function TestTrackReacquisitionReplay:test_held_onlyArmsAreContinued_aTaldOrJetWaitsForItsOwnObject()
	-- A held TALD or jet keeps its track for its own DCS object (TrackReacquisition.mayBeTakenWhileHeld): no other
	-- contact continues it or takes its decoy label.
	held = true
	for _, gap in ipairs({ 5, 10 }) do
		local n = closedWorld(gap)
		lu.assertTrue(n.tald >= 30, "too few TALD cases: " .. n.tald)
		lu.assertEquals(n.taldKept, 0)
		lu.assertEquals(n.otherDecoy, 0)
		lu.assertEquals(n.wrongTake, 0)
	end
end

function TestTrackReacquisitionReplay:test_held_openWorld_noNewContactTakesAHeldJetsTrack()
	held = true
	local cues, cueWrong, arms, armWrong = 0, 0, 0, 0
	for _, gap in ipairs({ 5, 10, 20 }) do
		for _, newbornsFirst in ipairs({ false, true }) do
			local n = openWorld(gap, newbornsFirst)
			cueWrong = cueWrong + n.cueInheritsJet
			arms, armWrong = arms + n.arm, armWrong + n.armInheritsJet
			if newbornsFirst then
				cues = cues + n.cue
			end
		end
	end
	-- Held jets stay launch-cue parents: weapons first seen with every launcher still silent are cued from them.
	lu.assertTrue(cues >= 20, "too few launch-cued contacts with the launchers silent: " .. cues)
	lu.assertEquals(cueWrong, 0)
	lu.assertTrue(arms >= 20, "too few new ARMs: " .. arms)
	lu.assertEquals(armWrong, 0)
end
