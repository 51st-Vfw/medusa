local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Track")
require("services.Services")
require("services.DecoyAssessmentService")

local Svc = Medusa.Services.DecoyAssessmentService
local Track = Medusa.Entities.Track
local D = Medusa.Constants.Decoy
local flights = require("decoy_dcs_trajectories")

local BASE = 5000
local mockTime = BASE

-- Return sizes from the weapons' DCS RCS (TALD and jets 5 m2: +7 dBsm; JSOW, SLAM-ER, ARMs about 0.05-0.1 m2),
-- as a confident fused estimate (what the report boundary's looks fuse to after many looks).
local LARGE_DB, SMALL_DB = 7, -11

local function newTrack(row, sizeDb)
	local t = Track.new({
		NetworkId = 1,
		Position = { x = row[2], y = row[3], z = row[4] },
		Velocity = { x = row[5], y = row[6], z = row[7] },
		AssessedAircraftType = "FIXED_WING",
		DisplayTrackId = "T1",
	})
	if sizeDb then
		t.SizeDb = sizeDb
		t.SizeWeight = Medusa.Constants.ContactEvidence.SIZE_MAX_WEIGHT
		t.SizeSpreadDb = math.sqrt(0.25 + Medusa.Constants.ContactEvidence.SIZE_SPREAD_FLOOR_DB ^ 2)
	end
	return t
end

local function feed(track, row, t)
	mockTime = BASE + (t or row[1])
	Track.update(track, { x = row[2], y = row[3], z = row[4] }, { x = row[5], y = row[6], z = row[7] }, mockTime)
	return Svc.evaluate(track)
end

--- Replays a recorded flight scan by scan. Returns the track and the flight times at which it first became SUSPECT
--- and PROBABLE (nil if never).
local function replay(flight, sizeDb)
	local pts = flight.pts
	local track = newTrack(pts[1], sizeDb)
	local suspectAt, probableAt
	for i = 1, #pts do
		local label = feed(track, pts[i])
		if label == "SUSPECT" and not suspectAt then
			suspectAt = pts[i][1]
		elseif label == "PROBABLE" and not probableAt then
			suspectAt = suspectAt or pts[i][1]
			probableAt = pts[i][1]
		end
	end
	return track, suspectAt, probableAt
end

--- A synthetic straight glide: level at `alt`, slowing by `decel` m/s each second from `speed`, heading north.
local function glide(n, alt, speed, decel, dt)
	local rows, z = {}, 0
	for i = 0, n - 1 do
		local v = speed - decel * i * dt
		rows[#rows + 1] = { i * dt, 0, alt, z, 0, 0, v }
		z = z + v * dt
	end
	return rows
end

local function setup()
	mockTime = BASE
	GetTime = function()
		return mockTime
	end
end

-- == Recorded DCS flights ==

TestDecoyRecordedFlights = {}

function TestDecoyRecordedFlights:setUp()
	setup()
end

function TestDecoyRecordedFlights:test_every_recorded_tald_becomes_probable_within_two_and_a_half_minutes()
	for _, f in ipairs(flights.tald) do
		local _, suspectAt, probableAt = replay(f, LARGE_DB)
		lu.assertNotNil(suspectAt, f.name)
		lu.assertNotNil(probableAt, f.name)
		lu.assertTrue(suspectAt >= D.SUSPECT_SEC, f.name)
		lu.assertTrue(probableAt > suspectAt, f.name)
		lu.assertTrue(probableAt <= 150, f.name)
	end
end

function TestDecoyRecordedFlights:test_no_recorded_jet_becomes_suspect()
	for _, f in ipairs(flights.jet) do
		local track, suspectAt = replay(f, LARGE_DB)
		lu.assertNil(suspectAt, f.name)
		lu.assertNotNil(track.DecoyAssessment.aircraftEvidence, f.name)
	end
end

function TestDecoyRecordedFlights:test_jet_first_seen_while_gliding_is_never_labelled()
	-- The first recorded jet glides with its energy falling 60 m/s for over 60 s late in its flight; seen only
	-- from 600 s on, its hard turns still come before a minute of straight loss.
	local f = flights.jet[1]
	local pts = {}
	for _, p in ipairs(f.pts) do
		if p[1] >= 600 then
			pts[#pts + 1] = p
		end
	end
	local _, suspectAt = replay({ name = f.name, pts = pts }, LARGE_DB)
	lu.assertNil(suspectAt)
end

function TestDecoyRecordedFlights:test_glide_weapons_and_arms_with_small_returns_are_never_decoys()
	for _, set in ipairs({ flights.jsow, flights.slamer, flights.arm }) do
		for _, f in ipairs(set) do
			local track, suspectAt = replay(f, SMALL_DB)
			lu.assertNil(suspectAt, f.name)
			lu.assertFalse(Svc.hasAircraftEvidence(track), f.name)
		end
	end
end

function TestDecoyRecordedFlights:test_cruise_missiles_never_give_aircraft_evidence_even_when_they_climb()
	-- SLAM-ERs and JSOWs climb and gain energy; without an aircraft-sized return that is no aircraft evidence, so
	-- they can never let a battery switch engage-air-weapons off.
	for _, set in ipairs({ flights.jsow, flights.slamer }) do
		for _, f in ipairs(set) do
			local track = replay(f, nil)
			lu.assertFalse(Svc.hasAircraftEvidence(track), f.name)
		end
	end
end

function TestDecoyRecordedFlights:test_tald_without_a_confident_size_is_not_labelled()
	local _, suspectAt = replay(flights.tald[1], nil)
	lu.assertNil(suspectAt)
end

-- == Behavior ==

TestDecoyBehaviour = {}

function TestDecoyBehaviour:setUp()
	setup()
end

function TestDecoyBehaviour:test_sustained_loss_is_measured_in_track_time_not_evaluations()
	local rows = glide(14, 6000, 230, 1.0, 5) -- 65 s of loss, scans every 5 s
	local track = newTrack(rows[1], LARGE_DB)
	for i = 1, #rows do
		feed(track, rows[i])
		Svc.evaluate(track) -- a second evaluation of the same scan adds nothing
		Svc.evaluate(track)
	end
	lu.assertTrue(track.DecoyAssessment.runSec < D.SUSPECT_SEC)
	lu.assertEquals(track.DecoyAssessment.label, "AIRCRAFT")
end

function TestDecoyBehaviour:test_straight_glide_goes_suspect_then_probable()
	local rows = glide(26, 6000, 230, 1.0, 5)
	local track = newTrack(rows[1], LARGE_DB)
	local labels = {}
	for i = 1, #rows do
		labels[i] = feed(track, rows[i])
	end
	-- The first full 20 s window (and so the first loss scan) is at 20 s: SUSPECT 60 s later, PROBABLE 90 s later.
	lu.assertEquals(labels[16], "AIRCRAFT") -- 75 s
	lu.assertEquals(labels[17], "SUSPECT") -- 80 s
	lu.assertEquals(labels[22], "SUSPECT") -- 105 s
	lu.assertEquals(labels[23], "PROBABLE") -- 110 s
end

function TestDecoyBehaviour:test_a_step_turn_restarts_the_leg()
	local rows = glide(26, 6000, 230, 1.0, 5)
	for i = 12, #rows do -- turn 20 degrees after 55 s
		local v = rows[i][7]
		rows[i][5] = v * math.sin(math.rad(20))
		rows[i][7] = v * math.cos(math.rad(20))
	end
	local track = newTrack(rows[1], LARGE_DB)
	for i = 1, 20 do
		feed(track, rows[i])
	end
	lu.assertEquals(track.DecoyAssessment.label, "AIRCRAFT")
end

local function probableTald()
	local rows = glide(30, 6000, 230, 1.0, 5)
	local track = newTrack(rows[1], LARGE_DB)
	for i = 1, #rows do
		feed(track, rows[i])
	end
	lu.assertEquals(track.DecoyAssessment.label, "PROBABLE")
	return track, rows[#rows]
end

function TestDecoyBehaviour:test_a_probable_decoy_is_a_debrief_line()
	local lines, info = {}, env.info
	env.info = function(msg)
		lines[#lines + 1] = msg
	end
	local ok, err = pcall(probableTald)
	env.info = info
	lu.assertTrue(ok, tostring(err))
	local n = 0
	for i = 1, #lines do
		if string.find(lines[i], "|ev=DECOY_PROBABLE|track=", 1, true) then
			n = n + 1
		end
	end
	lu.assertEquals(n, 1)
end

function TestDecoyBehaviour:test_a_probable_decoy_line_names_the_network_that_judged_it()
	local lines, info = {}, env.info
	env.info = function(msg)
		lines[#lines + 1] = msg
	end
	Medusa.Debrief.setNetwork("another-net")
	local ok, err = pcall(function()
		local rows = glide(30, 6000, 230, 1.0, 5)
		local track = newTrack(rows[1], LARGE_DB)
		for i = 1, #rows do
			mockTime = BASE + rows[i][1]
			Track.update(
				track,
				{ x = rows[i][2], y = rows[i][3], z = rows[i][4] },
				{ x = rows[i][5], y = rows[i][6], z = rows[i][7] },
				mockTime
			)
			Svc.evaluate(track, "red-net")
		end
	end)
	env.info = info
	Medusa.Debrief.setNetwork(nil)
	lu.assertTrue(ok, tostring(err))
	local n = 0
	for i = 1, #lines do
		if string.find(lines[i], "|net=red-net|ev=DECOY_PROBABLE|track=", 1, true) then
			n = n + 1
		end
	end
	lu.assertEquals(n, 1)
end

function TestDecoyBehaviour:test_labels_are_sticky_through_a_short_pause_in_the_loss()
	local track, last = probableTald()
	for k = 1, 6 do -- level, constant speed for 30 s: less than two windows of held energy
		feed(track, { 0, last[2], last[3], last[4] + k * last[7] * 5, 0, 0, last[7] }, last[1] + 5 * k)
	end
	lu.assertEquals(track.DecoyAssessment.label, "PROBABLE")
end

function TestDecoyBehaviour:test_a_straight_glide_is_assessed_at_jittered_5_and_10_second_scans()
	-- Timer jitter stretches 5 s and 10 s refreshes to 5.1 s and 10.3 s: a 20 s window then holds too few looks or
	-- too short a span, which must not stop the assessment.
	for _, dt in ipairs({ 5.1, 10.3 }) do
		local rows = glide(math.floor(160 / dt), 6000, 230, 0.9, dt)
		local track = newTrack(rows[1], LARGE_DB)
		local label
		for i = 1, #rows do
			label = feed(track, rows[i])
		end
		lu.assertEquals(label, "PROBABLE", "scans every " .. dt .. " s")
	end
end

--- A jet in an ordinary straight descent: 1,500 ft/min at constant speed for two minutes, then level for two.
local function descentThenLevel(speed)
	local rows, y, z = {}, 6000, 0
	local vy = -1500 * 0.3048 / 60
	for i = 0, 48 do
		local level = i * 5 > 120
		rows[#rows + 1] = { i * 5, 0, y, z, 0, level and 0 or vy, speed }
		z = z + speed * 5
		if not level then
			y = y + vy * 5
		end
	end
	return rows
end

function TestDecoyBehaviour:test_a_jet_in_a_straight_descent_then_level_flight_ends_an_aircraft()
	for _, speed in ipairs({ 100, 150, 250 }) do
		local rows = descentThenLevel(speed)
		local track = newTrack(rows[1], LARGE_DB)
		local labels = {}
		for i = 1, #rows do
			labels[feed(track, rows[i]) or "none"] = true
		end
		lu.assertEquals(track.DecoyAssessment.label, "AIRCRAFT", speed .. " m/s")
		lu.assertTrue(Svc.hasAircraftEvidence(track), speed .. " m/s")
		if speed >= 150 then -- a 1:20 or flatter descent is no decoy's glide at all
			lu.assertNil(labels.SUSPECT, speed .. " m/s")
			lu.assertNil(labels.PROBABLE, speed .. " m/s")
		end
	end
end

function TestDecoyBehaviour:test_a_contact_that_outlives_any_plausible_glide_is_an_aircraft()
	-- Short level stretches between steep steps never hold energy for two windows, but the contact is still flying
	-- long after a glider from its height would have landed.
	local track, last = probableTald()
	local t, y, z, v = last[1], last[3], last[4], last[7]
	local label
	while t < last[1] + 1200 and y > 100 do
		for k = 1, 7 do -- 35 s level
			t, z = t + 5, z + v * 5
			label = feed(track, { t, 0, y, z, 0, 0, v }, t)
		end
		for _ = 1, 2 do -- 10 s at 20 m/s down
			t, z, y = t + 5, z + v * 5, y - 100
			label = feed(track, { t, 0, y, z, 0, -20, v }, t)
		end
		if label == "AIRCRAFT" then
			break
		end
	end
	lu.assertEquals(label, "AIRCRAFT")
	lu.assertEquals(track.DecoyAssessment.aircraftEvidence, "outlived its glide")
end

function TestDecoyBehaviour:test_power_drops_the_label_after_two_scans_not_one()
	local track, last = probableTald()
	local t, z = last[1], last[4]
	local function poweredScan()
		t = t + 5
		z = z + 120 * 5
		return feed(track, { t, 0, last[3], z, 0, 0, 120 }, t)
	end
	lu.assertEquals(poweredScan(), "PROBABLE")
	lu.assertEquals(poweredScan(), "AIRCRAFT")
	lu.assertEquals(track.DecoyAssessment.aircraftEvidence, "energy gain")
	lu.assertTrue(Svc.hasAircraftEvidence(track))
	for _ = 1, 30 do -- aircraft evidence is for good: a later glide is not a decoy
		t = t + 5
		z = z + 100 * 5
		feed(track, { t, 0, last[3] - (t - last[1]) * 20, z, 0, -20, 100 }, t)
	end
	lu.assertEquals(track.DecoyAssessment.label, "AIRCRAFT")
end

function TestDecoyBehaviour:test_one_scan_evaluated_twice_is_still_one_scan()
	local track, last = probableTald()
	local t = last[1] + 5
	feed(track, { t, 0, last[3], last[4] + 600, 0, 0, 120 }, t)
	Svc.evaluate(track)
	Svc.evaluate(track)
	lu.assertEquals(track.DecoyAssessment.label, "PROBABLE")
end

function TestDecoyBehaviour:test_seen_as_aircraft_disproves()
	local track = probableTald()
	track.SeenAs = "AIRCRAFT"
	local p, v = track.Position, track.Velocity
	feed(track, { 0, p.x, p.y, p.z + v.z * 5, v.x, v.y, v.z }, mockTime - BASE + 5)
	lu.assertEquals(track.DecoyAssessment.label, "AIRCRAFT")
	lu.assertTrue(Svc.hasAircraftEvidence(track))
end

function TestDecoyBehaviour:test_seen_as_munition_with_aircraft_size_brings_probable_sooner()
	local rows = glide(20, 6000, 230, 1.0, 5) -- 95 s seen: SUSPECT, short of 90 s of loss
	local plain = newTrack(rows[1], LARGE_DB)
	local seen = newTrack(rows[1], LARGE_DB)
	seen.SeenAs = "MUNITION"
	for i = 1, #rows do
		feed(plain, rows[i])
		feed(seen, rows[i])
	end
	lu.assertEquals(plain.DecoyAssessment.label, "SUSPECT")
	lu.assertEquals(seen.DecoyAssessment.label, "PROBABLE")
end

function TestDecoyBehaviour:test_small_return_is_never_a_decoy()
	local rows = glide(30, 6000, 230, 1.0, 5)
	local track = newTrack(rows[1], SMALL_DB)
	for i = 1, #rows do
		feed(track, rows[i])
	end
	lu.assertEquals(track.DecoyAssessment.label, "AIRCRAFT")
end

function TestDecoyBehaviour:test_arm_under_evaluation_is_not_assessed()
	local rows = glide(30, 6000, 230, 1.0, 5)
	local track = newTrack(rows[1], LARGE_DB)
	track.HarmAssessment = { label = "SUSPECT" }
	for i = 1, #rows do
		feed(track, rows[i])
	end
	lu.assertNil(track.DecoyAssessment)
end

-- == Unanswered launches ==

TestDecoyLaunches = {}

local function storeOf(tracks)
	local byId = {}
	for _, t in ipairs(tracks) do
		byId[t.TrackId] = t
	end
	return {
		get = function(_, id)
			return byId[id]
		end,
	}
end

local function gridOf(tracks)
	return {
		queryRadius = function(_, pos, r)
			local ids = {}
			for _, t in ipairs(tracks) do
				local dx, dz = t.Position.x - pos.x, t.Position.z - pos.z
				if dx * dx + dz * dz <= r * r then
					ids[t.TrackId] = true
				end
			end
			return { TrackIds = ids }
		end,
	}
end

function TestDecoyLaunches:setUp()
	setup()
end

local function suspectPair()
	local rows = glide(18, 6000, 230, 1.0, 5) -- 85 s seen, 65 s of loss: SUSPECT
	local a, b = newTrack(rows[1], LARGE_DB), newTrack(rows[1], LARGE_DB)
	a.TrackId, b.TrackId = "A", "B"
	for i = 1, #rows do
		feed(a, rows[i])
		local r = rows[i]
		feed(b, { r[1], r[2] + 1000, r[3], r[4], r[5], r[6], r[7] }, r[1])
	end
	lu.assertEquals(a.DecoyAssessment.label, "SUSPECT")
	return a, b, rows
end

function TestDecoyLaunches:test_unanswered_launch_raises_target_full_and_bystander_half()
	local a, b, rows = suspectPair()
	local now = BASE + rows[#rows][1]
	Svc.judgeLaunch({ TargetTrackId = "A", LaunchTime = now - 30 }, now, storeOf({ a, b }), gridOf({ a, b }))
	lu.assertEquals(a.DecoyAssessment.launchEvidence, D.LAUNCH_EVIDENCE_TARGET_SEC)
	lu.assertEquals(b.DecoyAssessment.launchEvidence, D.LAUNCH_EVIDENCE_BYSTANDER_SEC)
	lu.assertEquals(a.DecoyAssessment.label, "PROBABLE") -- 65 s of loss + 30 s >= 90
	lu.assertEquals(b.DecoyAssessment.label, "SUSPECT")
end

function TestDecoyLaunches:test_a_probable_decoy_from_a_launch_names_the_judging_network()
	local a, b, rows = suspectPair()
	Svc.evaluate(b, "blue-net") -- another network evaluated last
	local lines, info = {}, env.info
	env.info = function(msg)
		lines[#lines + 1] = msg
	end
	local now = BASE + rows[#rows][1]
	local ok, err = pcall(
		Svc.judgeLaunch,
		{ TargetTrackId = "A", LaunchTime = now - 30 },
		now,
		storeOf({ a, b }),
		gridOf({ a, b }),
		"red-net"
	)
	env.info = info
	lu.assertTrue(ok, tostring(err))
	lu.assertEquals(a.DecoyAssessment.label, "PROBABLE")
	local n = 0
	for i = 1, #lines do
		if string.find(lines[i], "|net=red-net|ev=DECOY_PROBABLE|track=", 1, true) then
			n = n + 1
		end
	end
	lu.assertEquals(n, 1)
end

function TestDecoyLaunches:test_short_flight_proves_nothing()
	local a, b, rows = suspectPair()
	local now = BASE + rows[#rows][1]
	Svc.judgeLaunch({ TargetTrackId = "A", LaunchTime = now - 15 }, now, storeOf({ a, b }), gridOf({ a, b }))
	lu.assertEquals(a.DecoyAssessment.launchEvidence, 0)
end

function TestDecoyLaunches:test_a_flight_seen_on_one_scan_proves_nothing()
	local a, b, rows = suspectPair()
	local now = BASE + rows[#rows][1] + 22 -- the last scan is the only one during the 25 s flight
	Svc.judgeLaunch({ TargetTrackId = "A", LaunchTime = now - 25 }, now, storeOf({ a, b }), gridOf({ a, b }))
	lu.assertEquals(a.DecoyAssessment.launchEvidence, 0)
end

function TestDecoyLaunches:test_a_reaction_during_the_flight_is_aircraft_evidence()
	local a, b, rows = suspectPair()
	local last = rows[#rows]
	local t = last[1]
	for k = 1, 3 do -- turns 30 degrees
		local v = last[7]
		feed(a, { t + 5 * k, last[2] + 500 * k, 6000, last[4] + 900 * k, v * 0.5, 0, v * 0.87 }, t + 5 * k)
	end
	local flight = { TargetTrackId = "A", LaunchTime = BASE + t - 10 }
	Svc.judgeLaunch(flight, BASE + t + 15, storeOf({ a, b }), gridOf({ a, b }))
	lu.assertEquals(a.DecoyAssessment.label, "AIRCRAFT")
	lu.assertStrContains(a.DecoyAssessment.aircraftEvidence, "reacted")
end

function TestDecoyLaunches:test_a_slow_drift_over_a_long_flight_is_no_reaction()
	-- Recorded TALDs drift up to 0.9 deg/s: over a minute that is 54 degrees, but never the turn rate of a reaction.
	local a, b, rows = suspectPair()
	local last = rows[#rows]
	local t, x, z, h, v = last[1], last[2], last[4], 0, last[7]
	for k = 1, 12 do
		h = h + math.rad(0.9) * 5
		v = v - 5
		x, z = x + v * math.sin(h) * 5, z + v * math.cos(h) * 5
		feed(a, { t + 5 * k, x, 6000, z, v * math.sin(h), 0, v * math.cos(h) }, t + 5 * k)
	end
	Svc.judgeLaunch(
		{ TargetTrackId = "A", LaunchTime = BASE + t + 1 },
		BASE + t + 60,
		storeOf({ a, b }),
		gridOf({ a, b })
	)
	lu.assertNil(a.DecoyAssessment.aircraftEvidence)
	lu.assertEquals(a.DecoyAssessment.launchEvidence, D.LAUNCH_EVIDENCE_TARGET_SEC)
end

function TestDecoyLaunches:test_a_turn_seen_on_one_10_second_scan_is_a_reaction()
	local a, b, rows = suspectPair()
	local last = rows[#rows]
	local t, v = last[1], last[7]
	feed(a, { t + 10, last[2] + 0.87 * v * 10, 6000, last[4] + 0.5 * v * 10, v * 0.87, 0, v * 0.5 }, t + 10) -- 60 deg
	Svc.judgeLaunch(
		{ TargetTrackId = "A", LaunchTime = BASE + t - 15 },
		BASE + t + 12,
		storeOf({ a, b }),
		gridOf({ a, b })
	)
	lu.assertStrContains(a.DecoyAssessment.aircraftEvidence or "", "turned")
end

-- == Glide threat ==

TestDecoyGlideThreat = {}

function TestDecoyGlideThreat:setUp()
	setup()
end

function TestDecoyGlideThreat:test_a_probable_decoy_threatens_where_its_glide_is_predicted_to_end_not_what_it_overflies()
	local track = probableTald() -- heading +z at 6000 m
	local p = track.Position
	local x, z = Svc.glideImpact(track)
	lu.assertAlmostEquals(x, p.x, 1)
	lu.assertTrue(z > p.z + 20000, "a glide from 6000 m goes tens of km")
	lu.assertTrue(Svc.glideThreatens(track, { x = x + 500, y = 0, z = z - 2000 }))
	-- flies over a battery on its way to something behind it: 2.6 km abeam of the path, halfway along
	lu.assertFalse(Svc.glideThreatens(track, { x = p.x + 2600, y = 0, z = (p.z + z) / 2 }))
	lu.assertFalse(Svc.glideThreatens(track, { x = p.x, y = 0, z = (p.z + z) / 2 }))
	lu.assertFalse(Svc.glideThreatens(track, { x = p.x, y = 0, z = p.z - 20000 }))
	lu.assertFalse(Svc.glideThreatens(track, { x = x, y = 0, z = z + 10000 }))
end

function TestDecoyGlideThreat:test_the_threat_radius_edge()
	local track = probableTald()
	local p = track.Position
	track.AltitudeAGL = p.y
	track.Velocity = { x = 0, y = -100, z = 200 }
	local x, z = Svc.glideImpact(track)
	local r = D.GLIDE_THREAT_RADIUS_M
	lu.assertEquals(r, 3000)
	lu.assertTrue(Svc.glideThreatens(track, { x = x + 2900, y = 0, z = z }))
	lu.assertFalse(Svc.glideThreatens(track, { x = x + 3100, y = 0, z = z }))
	lu.assertTrue(Svc.glideThreatens(track, { x = x, y = 0, z = z - 2900 }))
	lu.assertFalse(Svc.glideThreatens(track, { x = x, y = 0, z = z - 3100 }))
end

function TestDecoyGlideThreat:test_a_store_without_a_decoy_assessment_falls_along_its_dive()
	local track = probableTald()
	track.DecoyAssessment = nil
	local p = track.Position
	track.AltitudeAGL = p.y
	track.Velocity = { x = 0, y = -100, z = 200 }
	lu.assertNil(Svc.glideImpact(track), "the glide is a decoy's")
	local x, z = Svc.impactOf(track)
	lu.assertAlmostEquals(x, p.x, 1)
	lu.assertAlmostEquals(z, p.z + 2 * p.y, 1)
	lu.assertTrue(Svc.impactThreatens(track, { x = p.x, y = 0, z = p.z + 2 * p.y }))
	lu.assertFalse(Svc.glideThreatens(track, { x = p.x, y = 0, z = p.z + 2 * p.y }), "no decoy label")
end

function TestDecoyGlideThreat:test_a_diving_decoy_is_predicted_to_hit_short_along_its_dive()
	local track = probableTald()
	local p = track.Position
	local agl = p.y - 0
	track.AltitudeAGL = agl
	track.Velocity = { x = 0, y = -100, z = 200 }
	local x, z = Svc.glideImpact(track)
	lu.assertAlmostEquals(x, p.x, 1)
	lu.assertAlmostEquals(z, p.z + 2 * agl, 1)
	lu.assertTrue(Svc.glideThreatens(track, { x = p.x, y = 0, z = p.z + 2 * agl }))
	lu.assertFalse(Svc.glideThreatens(track, { x = p.x, y = 0, z = p.z + 2 * agl + 10000 }))
	-- a contact that is not a probable decoy threatens nothing
	track.DecoyAssessment.label = "SUSPECT"
	lu.assertFalse(Svc.glideThreatens(track, { x = p.x, y = 0, z = p.z + 2 * agl }))
end
