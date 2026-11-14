local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("services.MetricsService")

local MS = Medusa.Services.MetricsService

-- == Durations when the timer is mission model time ==

TestHpTimer = {}

local savedWallClock
local savedRegistry

function TestHpTimer:setUp()
	savedWallClock = Medusa.hpTimerIsWallClock
	savedRegistry = MS._registry
	MS._registry = {}
end

function TestHpTimer:tearDown()
	Medusa.hpTimerIsWallClock = savedWallClock
	MS._registry = savedRegistry
end

function TestHpTimer:test_the_test_environment_has_a_wall_clock_timer()
	lu.assertEquals(Medusa.hpTimerSource, "os.clock")
	lu.assertTrue(Medusa.hpTimerIsWallClock)
end

function TestHpTimer:test_observe_duration_records_with_a_wall_clock()
	Medusa.hpTimerIsWallClock = true
	MS.summary("medusa_test_duration_seconds", "test")
	MS.observeDuration("medusa_test_duration_seconds", 0.01)
	lu.assertEquals(MS._registry.medusa_test_duration_seconds.count, 1)
end

function TestHpTimer:test_observe_duration_skips_when_the_timer_is_model_time()
	Medusa.hpTimerIsWallClock = false
	MS.summary("medusa_test_duration_seconds", "test")
	MS.observeDuration("medusa_test_duration_seconds", 0)
	lu.assertEquals(MS._registry.medusa_test_duration_seconds.count, 0)
	-- the plain observe is unaffected: it is for values that are not timer readings
	MS.observe("medusa_test_duration_seconds", 5)
	lu.assertEquals(MS._registry.medusa_test_duration_seconds.count, 1)
end

function TestHpTimer:test_timer_note_names_the_timer()
	Medusa.hpTimerIsWallClock = true
	lu.assertStrContains(Medusa.timerNote(), "os.clock")
	Medusa.hpTimerIsWallClock = false
	local note = Medusa.timerNote()
	lu.assertStrContains(note, "model time")
	lu.assertStrContains(note, "duration metrics are not recorded")
	-- no log line prints a duration, so the note promises none
	lu.assertNotStrContains(note, "logs")
	Medusa.hpTimerIsWallClock = true
	lu.assertNotStrContains(Medusa.timerNote(), "logs")
end
