local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Debrief")
require("services.Services")
require("services.CrewFactorsService")

-- Readiness (starts at the doctrine value, only rises: word spreads after a delay, the first launch or loss means a
-- war), net load (rises at once, decays over two minutes) and the debrief log line format.

local C = Medusa.Constants
local R = C.Readiness
local CF = C.CrewFactors
local CFS = Medusa.Services.CrewFactorsService

local logLines, originalInfo

local function logged(fragment)
	for i = 1, #logLines do
		if string.find(logLines[i], fragment, 1, true) then
			return true
		end
	end
	return false
end

local function counts(hostile, pending, arms, bandits)
	return {
		hostile = hostile or 0,
		tracks = (hostile or 0) + (bandits or 0),
		pending = pending or 0,
		arms = arms or 0,
	}
end

TestCrewFactors = {}

function TestCrewFactors:setUp()
	logLines = {}
	originalInfo = env.info
	self.savedAbs = GetAbsTime
	env.info = function(msg)
		logLines[#logLines + 1] = msg
	end
end

function TestCrewFactors:tearDown()
	env.info = originalInfo
	GetAbsTime = self.savedAbs
end

-- == Debrief line format ==

function TestCrewFactors:test_debrief_line_format()
	GetAbsTime = function()
		return 8 * 3600 + 3 * 60 + 7.9
	end
	Medusa.Debrief.emit("Red IADS", 123.456, "REPORT_LOST", "from", "obs|hill", "why", "net", "skip", nil)
	lu.assertEquals(
		logLines[#logLines],
		"DEBRIEF|t=123.5|clock=08:03:07|net=Red IADS|ev=REPORT_LOST|from=obs/hill|why=net"
	)
end

function TestCrewFactors:test_debrief_clock_wraps_past_midnight()
	lu.assertEquals(Medusa.Debrief.clock(0), "00:00:00")
	lu.assertEquals(Medusa.Debrief.clock(86399.9), "23:59:59")
	lu.assertEquals(Medusa.Debrief.clock(86400 + 3725), "01:02:05")
	lu.assertEquals(Medusa.Debrief.clock(3 * 86400 + 45296), "12:34:56")
end

function TestCrewFactors:test_debrief_uses_the_current_network_when_none_is_given()
	GetAbsTime = function()
		return 86400 + 30
	end
	Medusa.Debrief.setNetwork("blue")
	Medusa.Debrief.emit(nil, 5, "SITE_LOST", "site", "sam-1")
	lu.assertEquals(logLines[#logLines], "DEBRIEF|t=5.0|clock=00:00:30|net=blue|ev=SITE_LOST|site=sam-1")
end

function TestCrewFactors:test_debrief_formats_nothing_when_info_logging_is_off()
	local calls = 0
	GetAbsTime = function()
		calls = calls + 1
		return 0
	end
	local level = Medusa.Logger:getLevel()
	-- control: at INFO the line is formatted (the clock read) and written
	Medusa.Logger:setLevel("INFO")
	local ok, err = pcall(Medusa.Debrief.emit, "net", 5, "SITE_LOST", "site", "sam-1")
	assert(ok, err)
	local onLines, onCalls = #logLines, calls
	-- above INFO: nothing formatted, nothing written
	Medusa.Logger:setLevel("ERROR")
	ok, err = pcall(Medusa.Debrief.emit, "net", 6, "SITE_LOST", "site", "sam-2")
	Medusa.Logger:setLevel(level)
	assert(ok, err)
	lu.assertEquals(onLines, 1)
	lu.assertEquals(onCalls, 1)
	lu.assertEquals(#logLines, 1)
	lu.assertEquals(calls, 1)
end

-- == Readiness ==

function TestCrewFactors:test_readiness_starts_at_the_doctrine_value()
	lu.assertEquals(CFS.newState({ Readiness = R.SURPRISED }).readiness, R.SURPRISED)
	lu.assertEquals(CFS.newState({ Readiness = R.ALERTED }).readiness, R.ALERTED)
	lu.assertEquals(CFS.newState({}).readiness, R.ENGAGED)
end

function TestCrewFactors:test_bandit_tracks_load_the_net_but_do_not_spread_the_word()
	local s = CFS.newState({ Readiness = R.SURPRISED })
	CFS.update(s, 100, "net", counts(0, 0, 0, 6), true)
	lu.assertNil(s.alertDueAt)
	lu.assertTrue(s.load > 0)
	CFS.update(s, 1000, "net", counts(0, 0, 0, 6), true)
	lu.assertEquals(s.readiness, R.SURPRISED)
end

function TestCrewFactors:test_word_spreads_after_a_delay_once_the_network_holds_a_hostile_track()
	local s = CFS.newState({ Readiness = R.SURPRISED })
	CFS.update(s, 100, "net", counts(1), true)
	lu.assertEquals(s.readiness, R.SURPRISED)
	local median = (CF.WORD_SPREADS_MIN_SEC + CF.WORD_SPREADS_MAX_SEC) / 2
	CFS.update(s, 100 + median - 1, "net", counts(0), true)
	lu.assertEquals(s.readiness, R.SURPRISED)
	CFS.update(s, 100 + median, "net", counts(0), true)
	lu.assertEquals(s.readiness, R.ALERTED)
	lu.assertTrue(logged("DEBRIEF|t=310.0|clock="))
	lu.assertTrue(logged("|net=net|ev=READINESS|from=SURPRISED|to=ALERTED|why=hostile_track"))
end

function TestCrewFactors:test_word_spread_delay_is_random_outside_training()
	local s = CFS.newState({ Readiness = R.SURPRISED }, function()
		return 0
	end)
	CFS.wordSpreads(s, 100, "net", "hostile_report", false)
	lu.assertEquals(s.alertDueAt, 100 + CF.WORD_SPREADS_MIN_SEC)
	-- Only the first word counts.
	CFS.wordSpreads(s, 150, "net", "hostile_track", false)
	lu.assertEquals(s.alertDueAt, 100 + CF.WORD_SPREADS_MIN_SEC)
end

function TestCrewFactors:test_first_launch_means_engaged_at_once()
	local a = CFS.newState({ Readiness = R.SURPRISED })
	CFS.onLaunch(a, 50, "net", 12)
	lu.assertEquals(a.readiness, R.ENGAGED)
	lu.assertTrue(logged("ev=READINESS|from=SURPRISED|to=ENGAGED|why=first_launch"))
end

function TestCrewFactors:test_a_loss_means_engaged_once_word_of_it_arrives()
	-- Training: the word-of-loss delay at its midpoint.
	local median = (CF.WORD_OF_LOSS_MIN_SEC + CF.WORD_OF_LOSS_MAX_SEC) / 2
	local b = CFS.newState({ Readiness = R.ALERTED })
	CFS.onLoss(b, 60, "net", true)
	lu.assertEquals(b.readiness, R.ALERTED)
	CFS.update(b, 60 + median - 1, "net", counts(), true)
	lu.assertEquals(b.readiness, R.ALERTED)
	-- the loss loads the net at once
	lu.assertAlmostEquals(b.load, 1 / b.fullLosses, 1e-9)
	CFS.update(b, 60 + median, "net", counts(), true)
	lu.assertEquals(b.readiness, R.ENGAGED)
	lu.assertTrue(logged("ev=READINESS|from=ALERTED|to=ENGAGED|why=first_loss"))
	-- outside training the delay is drawn in the window; a second loss does not move it
	local c = CFS.newState({ Readiness = R.SURPRISED }, function()
		return 0
	end)
	CFS.onLoss(c, 100, "net", false)
	CFS.onLoss(c, 110, "net", false)
	lu.assertEquals(c.engageDueAt, 100 + CF.WORD_OF_LOSS_MIN_SEC)
	-- a launch before the word arrives makes it ENGAGED at once and the pending word is dropped
	CFS.onLaunch(c, 105, "net")
	lu.assertEquals(c.readiness, R.ENGAGED)
	lu.assertNil(c.engageDueAt)
end

function TestCrewFactors:test_readiness_never_falls_on_its_own()
	local s = CFS.newState({ Readiness = R.SURPRISED })
	CFS.wordSpreads(s, 100, "net", "hostile_track", true)
	CFS.onLaunch(s, 120, "net")
	lu.assertEquals(s.readiness, R.ENGAGED)
	-- The pending word arrives after the war started: no step down to ALERTED.
	CFS.update(s, 1000, "net", counts(1), true)
	lu.assertEquals(s.readiness, R.ENGAGED)
	local lines = #logLines
	CFS.wordSpreads(s, 1100, "net", "hostile_report", true)
	CFS.update(s, 2000, "net", counts(1), true)
	lu.assertEquals(s.readiness, R.ENGAGED)
	lu.assertEquals(#logLines, lines)
end

function TestCrewFactors:test_set_readiness_is_the_mission_call_and_may_lower_it()
	local s = CFS.newState({ Readiness = R.ENGAGED })
	CFS.set(s, R.SURPRISED, 10, "net", "api")
	lu.assertEquals(s.readiness, R.SURPRISED)
	lu.assertTrue(logged("ev=READINESS|from=ENGAGED|to=SURPRISED|why=api"))
	CFS.update(s, 20, "net", counts(1), true)
	CFS.update(s, 20 + 210, "net", counts(1), true)
	lu.assertEquals(s.readiness, R.ALERTED)
end

-- == Net load ==

function TestCrewFactors:test_raw_load_sums_the_terms_and_caps_at_one()
	local s = CFS.newState({})
	lu.assertEquals(CFS.rawLoad(s, 0, 0, 0, 0, 0), 0)
	lu.assertAlmostEquals(CFS.rawLoad(s, 6, 0, 0, 0, 0), 6 / CF.LOAD_FULL_TRACKS_MIN, 1e-9)
	lu.assertAlmostEquals(
		CFS.rawLoad(s, 3, 2, 1, 1, 0),
		3 / CF.LOAD_FULL_TRACKS_MIN
			+ 2 / CF.LOAD_FULL_PENDING_REPORTS
			+ 1 / CF.LOAD_FULL_ARMS_MIN
			+ 1 / CF.LOAD_FULL_MISSILES_MIN,
		1e-9
	)
	lu.assertEquals(CFS.rawLoad(s, 100, 100, 100, 100, 100), 1)
end

function TestCrewFactors:test_capacities_scale_with_the_network()
	local s = CFS.newState({})
	CFS.setNetworkSize(s, 2, 1)
	lu.assertEquals({ s.fullTracks, s.fullMissiles, s.fullArms }, {
		CF.LOAD_FULL_TRACKS_MIN,
		CF.LOAD_FULL_MISSILES_MIN,
		CF.LOAD_FULL_ARMS_MIN,
	})
	CFS.setNetworkSize(s, 60, 31)
	lu.assertEquals(s.fullTracks, 60 * CF.LOAD_FULL_TRACKS_PER_SITE)
	lu.assertEquals(s.fullMissiles, 31 * CF.LOAD_FULL_MISSILES_PER_SAM)
	lu.assertEquals(s.fullArms, math.ceil(31 * CF.LOAD_FULL_ARMS_PER_SAM))
end

function TestCrewFactors:test_load_calibration_small_net_in_the_sweet_spot_wing_raid_saturates()
	-- A small network measured in DCS: 4 observer posts, a Dog Ear + Shilka and an SA-8 (two sites, one SAM), five
	-- low aircraft, the SA-8 with two missiles up, two reports on the radio.
	local small = CFS.newState({})
	CFS.setNetworkSize(small, 2, 1)
	local load = CFS.rawLoad(small, 5, 2, 0, 2, 0)
	lu.assertTrue(load >= 0.2 and load <= 0.4, "small network: " .. load)
	-- The same handful against a big network: calmer still.
	local big = CFS.newState({})
	CFS.setNetworkSize(big, 40, 24)
	lu.assertTrue(CFS.rawLoad(big, 5, 2, 0, 2, 0) < load)
	-- A wing-scale raid (30 aircraft, 6 ARMs, a dozen missiles up, 8 reports waiting, a site lost) on a 20-site,
	-- 12-SAM network: swamped.
	local wing = CFS.newState({})
	CFS.setNetworkSize(wing, 20, 12)
	lu.assertTrue(CFS.rawLoad(wing, 30, 8, 6, 12, 1) >= 0.8)
	-- ... and on the big network.
	lu.assertTrue(CFS.rawLoad(big, 30, 8, 6, 12, 1) >= 0.8)
end

function TestCrewFactors:test_load_rises_at_once_and_decays_over_two_minutes()
	local s = CFS.newState({ Readiness = R.ENGAGED })
	CFS.update(s, 100, "net", counts(CF.LOAD_FULL_TRACKS_MIN / 2), false)
	lu.assertAlmostEquals(s.load, 0.5, 1e-9)
	CFS.update(s, 130, "net", counts(0), false)
	lu.assertAlmostEquals(s.load, 0.5 - 30 * CF.LOAD_DECAY_PER_SEC, 1e-9)
	CFS.update(s, 160, "net", counts(0), false)
	lu.assertAlmostEquals(s.load, 0, 1e-9)
	CFS.update(s, 161, "net", counts(CF.LOAD_FULL_TRACKS_MIN, CF.LOAD_FULL_PENDING_REPORTS), false)
	lu.assertEquals(s.load, 1)
	CFS.update(s, 161 + 120, "net", counts(0), false)
	lu.assertAlmostEquals(s.load, 0, 1e-9)
end

function TestCrewFactors:test_launches_count_while_in_flight_and_losses_for_five_minutes()
	local s = CFS.newState({ Readiness = R.ENGAGED })
	CFS.onLaunch(s, 100, "net")
	CFS.onLaunch(s, 101, "net")
	CFS.onLoss(s, 102, "net", false)
	CFS.update(s, 110, "net", counts(), false)
	lu.assertAlmostEquals(s.load, 2 / CF.LOAD_FULL_MISSILES_MIN + 1 / CF.LOAD_FULL_LOSSES, 1e-9)
	lu.assertEquals(CFS.missilesInFlight(s, 100 + CF.MISSILE_FLIGHT_SEC + 2), 0)
	lu.assertEquals(CFS.recentLosses(s, 102 + CF.LOSS_WINDOW_SEC - 1), 1)
	lu.assertEquals(CFS.recentLosses(s, 102 + CF.LOSS_WINDOW_SEC + 1), 0)
end

function TestCrewFactors:test_a_missile_loads_the_net_only_for_its_own_flight_time()
	local s = CFS.newState({ Readiness = R.ENGAGED })
	CFS.onLaunch(s, 100, "net", 12.5)
	lu.assertEquals(CFS.missilesInFlight(s, 112), 1)
	lu.assertEquals(CFS.missilesInFlight(s, 113), 0)
	-- no flight time given: MISSILE_FLIGHT_SEC
	CFS.onLaunch(s, 200, "net")
	lu.assertEquals(CFS.missilesInFlight(s, 200 + CF.MISSILE_FLIGHT_SEC - 1), 1)
	lu.assertEquals(CFS.missilesInFlight(s, 200 + CF.MISSILE_FLIGHT_SEC + 1), 0)
end

function TestCrewFactors:test_a_big_salvo_counts_every_missile_in_flight()
	local s = CFS.newState({ Readiness = R.ENGAGED })
	CFS.setNetworkSize(s, 2, 1)
	for i = 1, 25 do
		CFS.onLaunch(s, 100 + i * 0.1, "net", 30)
	end
	lu.assertEquals(CFS.missilesInFlight(s, 110), 25)
	CFS.update(s, 110, "net", counts(), false)
	lu.assertEquals(s.load, 1)
	-- spent missiles' slots are reused
	for i = 1, 25 do
		CFS.onLaunch(s, 200 + i * 0.1, "net", 30)
	end
	lu.assertEquals(CFS.missilesInFlight(s, 210), 25)
	lu.assertEquals(#s.launches, 25)
end

function TestCrewFactors:test_a_long_flight_loads_the_net_no_longer_than_missile_flight_sec()
	local s = CFS.newState({ Readiness = R.ENGAGED })
	CFS.onLaunch(s, 100, "net", 190) -- an S-300 estimate at full range
	lu.assertEquals(CFS.missilesInFlight(s, 100 + CF.MISSILE_FLIGHT_SEC - 1), 1)
	lu.assertEquals(CFS.missilesInFlight(s, 100 + CF.MISSILE_FLIGHT_SEC + 1), 0)
end

function TestCrewFactors:test_measured_sa8_salvo_keeps_the_small_net_in_the_sweet_spot()
	-- Measured in DCS: the SA-8 (10.3 km weapon range) fired these missiles at low aircraft while the network held
	-- five of them and two reports waited on the radio. Each counts for its estimated time to target (half the range
	-- below TTK_ALT_FLOOR_M at SAM_AVG_MISSILE_SPEED_MPS, 6.4 s); no target track would double it.
	local s = CFS.newState({ Readiness = R.ENGAGED })
	CFS.setNetworkSize(s, 2, 1)
	local launches = { 305.3, 310.8, 322.0, 327.6, 335.2, 341.2, 345.9, 352.8, 363.2, 374.7, 383.4 }
	local ttk = 10300 * 0.5 / Medusa.Constants.SAM_AVG_MISSILE_SPEED_MPS
	local k, peak = 1, 0
	for t = 300, 400, 0.5 do
		while launches[k] and launches[k] <= t do
			CFS.onLaunch(s, launches[k], "net", ttk)
			k = k + 1
		end
		CFS.update(s, t, "net", counts(5, 2), false)
		peak = math.max(peak, s.load)
	end
	lu.assertTrue(peak >= 0.2 and peak <= 0.4, "peak load " .. peak)
	-- ... and the same with the doubled flight time
	local s2 = CFS.newState({ Readiness = R.ENGAGED })
	CFS.setNetworkSize(s2, 2, 1)
	k, peak = 1, 0
	for t = 300, 400, 0.5 do
		while launches[k] and launches[k] <= t do
			CFS.onLaunch(s2, launches[k], "net", 2 * ttk)
			k = k + 1
		end
		CFS.update(s2, t, "net", counts(5, 2), false)
		peak = math.max(peak, s2.load)
	end
	lu.assertTrue(peak >= 0.2 and peak <= 0.4, "peak load, no target track " .. peak)
end

function TestCrewFactors:test_crew_factors_switch()
	lu.assertTrue(CFS.isOn({}))
	lu.assertTrue(CFS.isOn({ CrewFactors = true }))
	lu.assertFalse(CFS.isOn({ CrewFactors = false }))
	lu.assertFalse(CFS.isOn(nil))
end
