local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.SensorPollingService")

-- == Helpers ==

local mockIdCounter = 0

local function makeDcsObject(name, pos, vel, category)
	mockIdCounter = mockIdCounter + 1
	return {
		id_ = mockIdCounter,
		getCategory = function(self)
			return category or Object.Category.UNIT
		end,
		getPoint = function(self)
			return pos
		end,
		getVelocity = function(self)
			return vel
		end,
		getName = function(self)
			return name
		end,
	}
end

local function setupMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

-- == TestSensorPollingServicePollSensor ==

TestSensorPollingServicePollSensor = {}

function TestSensorPollingServicePollSensor:setUp()
	setupMocks()
	mockIdCounter = 0
	self.svc = Medusa.Services.SensorPollingService:new({
		PerTrackScanUpdateRate = 5,
		SensorCleanupSec = 30,
	})
end

function TestSensorPollingServicePollSensor:test_returnsNilWhenNoController()
	GetGroupController = function(_)
		return nil
	end

	local reports = self.svc:pollSensor("missing-group", 100)
	lu.assertNil(reports)
end

function TestSensorPollingServicePollSensor:test_returnsEmptyWhenNoDetections()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return nil
	end

	local reports = self.svc:pollSensor("empty-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_returnsEmptyWhenDetectionsEmpty()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {}
	end

	local reports = self.svc:pollSensor("empty-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_buildsReportFromDetection()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject("target-1", { x = 100, y = 500, z = 200 }, { x = 10, y = 0, z = 5 }),
				visible = true,
				type = true,
				distance = true,
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)

	lu.assertEquals(#reports, 1)
	lu.assertEquals(reports[1].NetworkId, 1)
	lu.assertEquals(reports[1].SourceType, Medusa.Constants.TrackSource.EARLY_WARNING_RADAR)
	lu.assertIsNil(reports[1].ObjectCategory)
	lu.assertIsNil(reports[1].UnitCategory)
	lu.assertEquals(reports[1].Position.x, 100)
	lu.assertEquals(reports[1].Position.y, 500)
	lu.assertEquals(reports[1].Position.z, 200)
	lu.assertEquals(reports[1].Velocity.x, 10)
	lu.assertEquals(reports[1].Velocity.y, 0)
	lu.assertEquals(reports[1].Velocity.z, 5)
end

function TestSensorPollingServicePollSensor:test_includes_supplied_originating_source()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject("target-1", { x = 100, y = 500, z = 200 }, { x = 10, y = 0, z = 5 }),
			},
		}
	end

	local reports = self.svc:pollSensor("awacs-group", 100, Medusa.Constants.TrackSource.AWACS)

	lu.assertEquals(reports[1].SourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestSensorPollingServicePollSensor:test_multipleDetections()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject("t1", { x = 1, y = 2, z = 3 }, { x = 4, y = 5, z = 6 }),
				visible = true,
			},
			{
				object = makeDcsObject("t2", { x = 7, y = 8, z = 9 }, { x = 10, y = 11, z = 12 }),
				visible = true,
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)

	lu.assertEquals(#reports, 2)
	lu.assertEquals(reports[1].NetworkId, 1)
	lu.assertEquals(reports[2].NetworkId, 2)
end

function TestSensorPollingServicePollSensor:test_skipsDetectionWithNoObject()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{ object = nil, visible = true },
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_skipsDetectionWhenGetPointFails()
	local badObj = {
		id_ = 1,
		getCategory = function(self)
			return Object.Category.UNIT
		end,
		getPoint = function(self)
			error("destroyed")
		end,
		getVelocity = function(self)
			return { x = 0, y = 0, z = 0 }
		end,
	}

	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = badObj } }
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_skipsDetectionWhenGetVelocityFails()
	local badObj = {
		id_ = 1,
		getCategory = function(self)
			return Object.Category.UNIT
		end,
		getPoint = function(self)
			return { x = 1, y = 2, z = 3 }
		end,
		getVelocity = function(self)
			error("destroyed")
		end,
	}

	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = badObj } }
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_rejectsNilObjectId()
	local obj = {
		id_ = nil,
		getCategory = function(self)
			return Object.Category.UNIT
		end,
		getPoint = function(self)
			return { x = 1, y = 2, z = 3 }
		end,
		getVelocity = function(self)
			return { x = 0, y = 0, z = 0 }
		end,
	}

	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = obj } }
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_partialFailuresStillReturnGood()
	local badObj = {
		id_ = 1,
		getCategory = function(self)
			return Object.Category.UNIT
		end,
		getPoint = function(self)
			error("boom")
		end,
		getVelocity = function(self)
			return { x = 0, y = 0, z = 0 }
		end,
	}

	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{ object = badObj },
			{
				object = makeDcsObject("good", { x = 50, y = 100, z = 150 }, { x = 1, y = 2, z = 3 }),
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)

	lu.assertEquals(#reports, 1)
	lu.assertEquals(reports[1].NetworkId, 1)
	lu.assertEquals(reports[1].Position.x, 50)
end

function TestSensorPollingServicePollSensor:test_acceptsWeaponObjects()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject(
					"AGM-88C #001",
					{ x = 1, y = 500, z = 2 },
					{ x = 300, y = -50, z = 0 },
					Object.Category.WEAPON
				),
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 1)
	lu.assertEquals(reports[1].NetworkId, 1)
	lu.assertIsNil(reports[1].ObjectCategory)
	lu.assertIsNil(reports[1].UnitCategory)
	lu.assertEquals(reports[1].Position.x, 1)
	lu.assertEquals(reports[1].Velocity.x, 300)
end

function TestSensorPollingServicePollSensor:test_skipsStaticObjects()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject(
					"building-1",
					{ x = 1, y = 0, z = 2 },
					{ x = 0, y = 0, z = 0 },
					Object.Category.STATIC
				),
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

-- == Per-source scan update rate ==

TestSensorPollingServiceScanRate = {}

function TestSensorPollingServiceScanRate:setUp()
	setupMocks()
	mockIdCounter = 0
	self.svc = Medusa.Services.SensorPollingService:new({
		PerTrackScanUpdateRate = 5,
		SensorCleanupSec = 30,
	})
	local target = makeDcsObject("target-1", { x = 100, y = 500, z = 200 }, { x = 10, y = 0, z = 5 })
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = target } }
	end
end

function TestSensorPollingServiceScanRate:test_supplied_rate_reports_the_track_again_after_that_interval()
	local source = Medusa.Constants.TrackSource.SAM_BATTERY
	lu.assertEquals(#self.svc:pollSensor("sam", 100, source, 1), 1)
	lu.assertEquals(#self.svc:pollSensor("sam", 100.5, source, 1), 0)
	lu.assertEquals(#self.svc:pollSensor("sam", 101, source, 1), 1)
end

function TestSensorPollingServiceScanRate:test_without_a_rate_the_doctrine_rate_applies()
	lu.assertEquals(#self.svc:pollSensor("ewr", 100), 1)
	lu.assertEquals(#self.svc:pollSensor("ewr", 101), 0)
	lu.assertEquals(#self.svc:pollSensor("ewr", 105), 1)
end

function TestSensorPollingServiceScanRate:test_fastest_sensor_seeing_a_track_sets_its_update_rate()
	local C = Medusa.Constants.TrackSource
	lu.assertEquals(#self.svc:pollSensor("ewr", 100, C.EARLY_WARNING_RADAR, 10), 1)
	lu.assertEquals(#self.svc:pollSensor("ewr", 101, C.EARLY_WARNING_RADAR, 10), 0)
	lu.assertEquals(#self.svc:pollSensor("sam", 101, C.SAM_BATTERY, 1), 1)
end

-- == TestContactEvidence: the report boundary's return size and sight recognition ==

TestContactEvidence = {}

local CE = Medusa.Constants.ContactEvidence
local SeenAs = Medusa.Constants.SeenAs

local function makeContact(opts)
	mockIdCounter = mockIdCounter + 1
	local o = {
		id_ = opts.id or mockIdCounter,
		descCalls = 0,
		getCategory = function(_)
			return opts.weapon and Object.Category.WEAPON or Object.Category.UNIT
		end,
		getPoint = function(_)
			return opts.pos
		end,
		getVelocity = function(_)
			return opts.vel
		end,
		getName = function(_)
			return "contact"
		end,
	}
	o.getDesc = function(self)
		self.descCalls = self.descCalls + 1
		return { RCS = opts.rcs, category = opts.unitCategory or Unit.Category.AIRPLANE }
	end
	return o
end

local SENSOR_POS = { x = 0, y = 0, z = 0 }

local function ctx(kind)
	return { Position = SENSOR_POS, Reach = 100000, Kind = kind or "SAM_TRACK" }
end

function TestContactEvidence:setUp()
	setupMocks()
	mockIdCounter = 0
	self.draws = 0
	self.svc = Medusa.Services.SensorPollingService:new({ PerTrackScanUpdateRate = 1, SensorCleanupSec = 30 }, {
		random = function()
			self.draws = self.draws + 1
			return 0 -- a zero-noise look
		end,
	})
	self.visualCalls = 0
	self.main = {}
	self.visual = {}
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_, detectionType)
		if detectionType ~= nil then -- any channel-filtered query (none is expected)
			self.visualCalls = self.visualCalls + 1
			return self.visual
		end
		return self.main
	end
end

function TestContactEvidence:poll(now, sensorCtx)
	return self.svc:pollSensor("sam", now or 100, Medusa.Constants.TrackSource.SAM_BATTERY, 1, sensorCtx)
end

local function db(x)
	return 10 * math.log10(x)
end

function TestContactEvidence:test_without_a_sensor_context_reports_carry_no_evidence()
	local jet = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = jet, type = true } }
	local r = self:poll(100)[1]
	lu.assertNil(r.SizeDb)
	lu.assertNil(r.SeenAs)
	lu.assertEquals(jet.descCalls, 0)
end

function TestContactEvidence:test_aspect_curve_is_one_nose_five_beam_two_tail()
	local aspectDb = Medusa.Services.SensorPollingService.aspectDb
	lu.assertAlmostEquals(aspectDb(1), 0, 1e-9)
	lu.assertAlmostEquals(aspectDb(0), CE.ASPECT_BEAM_DB, 1e-9)
	lu.assertAlmostEquals(aspectDb(-1), CE.ASPECT_TAIL_DB, 1e-9)
end

function TestContactEvidence:test_shape_offset_is_fixed_per_object_and_bounded()
	local shape = Medusa.Services.SensorPollingService.shapeOffsetDb
	local lo, hi = math.huge, -math.huge
	for id = 1, 2000 do
		local s = shape(id)
		lu.assertEquals(shape(id), s)
		lo, hi = math.min(lo, s), math.max(hi, s)
	end
	lu.assertTrue(lo >= -CE.SHAPE_OFFSET_DB and hi <= CE.SHAPE_OFFSET_DB)
	lu.assertTrue(lo < -2.5 and hi > 2.5)
end

function TestContactEvidence:test_size_look_is_rcs_plus_aspect_plus_shape_rounded_to_the_radar_step()
	local jet = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = jet } }
	local r = self:poll(100, ctx("SAM_TRACK"))[1]
	local truth = db(5) + Medusa.Services.SensorPollingService.shapeOffsetDb(jet.id_)
	lu.assertEquals(r.SizeDb, math.floor(truth + 0.5)) -- nose-on, 1 dB step
	lu.assertEquals(self.draws, 2) -- one Gaussian draw per look
	lu.assertTrue(r.SizeVarDb >= CE.FLICKER_DB ^ 2)
end

function TestContactEvidence:test_beam_look_reads_about_seven_db_more_than_nose()
	local nose = makeContact({ id = 7, pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = nose } }
	local a = self:poll(100, ctx("SAM_TRACK"))[1].SizeDb
	nose.getVelocity = function(_)
		return { x = 0, y = 0, z = 250 }
	end
	local b = self:poll(101, ctx("SAM_TRACK"))[1].SizeDb
	lu.assertTrue(math.abs(b - a - CE.ASPECT_BEAM_DB) <= 1)
end

function TestContactEvidence:test_look_variance_grows_with_range_and_with_a_coarser_radar()
	local near = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -600, y = 0, z = 0 }, rcs = 0.08 })
	local far = makeContact({ pos = { x = 34000, y = 0, z = 0 }, vel = { x = -600, y = 0, z = 0 }, rcs = 0.08 })
	self.main = { { object = near }, { object = far } }
	local track = self:poll(100, ctx("SAM_TRACK"))
	lu.assertTrue(track[2].SizeVarDb > track[1].SizeVarDb + 0.5)
	local ewr = self:poll(101, ctx("EWR"))
	lu.assertTrue(ewr[1].SizeVarDb > track[1].SizeVarDb + 2)
end

function TestContactEvidence:test_looks_vary_with_the_random_draws()
	local svc = Medusa.Services.SensorPollingService:new({ PerTrackScanUpdateRate = 1, SensorCleanupSec = 30 }, {
		random = function()
			return 0.5
		end,
	})
	local jet = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = jet } }
	local noisy = svc:pollSensor("sam", 100, Medusa.Constants.TrackSource.SAM_BATTERY, 1, ctx("SAM_TRACK"))[1]
	local clean = self:poll(100, ctx("SAM_TRACK"))[1]
	lu.assertTrue(noisy.SizeDb < clean.SizeDb) -- sqrt(-2 ln 0.5) * cos(pi) = -1.18 sigma
end

function TestContactEvidence:test_descriptor_is_read_once_per_object_and_dropped_at_cleanup()
	local jet = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = jet } }
	self:poll(100, ctx())
	self:poll(105, ctx())
	lu.assertEquals(jet.descCalls, 1)
	self.main = {}
	self:poll(200, ctx()) -- past SensorCleanupSec: the contact's cache entry goes with its scan entry
	self.main = { { object = jet } }
	self:poll(201, ctx())
	lu.assertEquals(jet.descCalls, 2)
end

function TestContactEvidence:test_no_rcs_in_the_descriptor_gives_no_size()
	local thing = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 } })
	self.main = { { object = thing } }
	local r = self:poll(100, ctx())[1]
	lu.assertNil(r.SizeDb)
	lu.assertNil(r.SizeVarDb)
end

function TestContactEvidence:test_no_reach_gives_no_size()
	local jet = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = jet } }
	local r = self:poll(100, { Position = SENSOR_POS, Kind = "EWR" })[1]
	lu.assertNil(r.SizeDb)
end

function TestContactEvidence:test_type_known_inside_sight_range_names_the_coarse_class()
	local jet = makeContact({ pos = { x = 8000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	local helo = makeContact({
		pos = { x = 0, y = 0, z = 6000 },
		vel = { x = 60, y = 0, z = 0 },
		rcs = 5,
		unitCategory = Unit.Category.HELICOPTER,
	})
	local harm =
		makeContact({ pos = { x = 9000, y = 0, z = 0 }, vel = { x = -600, y = 0, z = 0 }, rcs = 0.08, weapon = true })
	self.main = { { object = jet, type = true }, { object = helo, type = true }, { object = harm, type = true } }
	local r = self:poll(100, ctx())
	lu.assertEquals(r[1].SeenAs, SeenAs.AIRCRAFT)
	lu.assertEquals(r[2].SeenAs, SeenAs.HELICOPTER)
	lu.assertEquals(r[3].SeenAs, SeenAs.MUNITION)
end

function TestContactEvidence:test_type_unknown_names_nothing()
	local jet = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = jet, type = false } }
	lu.assertNil(self:poll(100, ctx())[1].SeenAs)
end

function TestContactEvidence:test_radar_type_recognition_beyond_sight_range_is_ignored()
	-- A Kub or Buk search radar knows a TALD's type at 70 km: no crew could.
	local tald = makeContact({ pos = { x = 30000, y = 0, z = 0 }, vel = { x = -200, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = tald, type = true } }
	lu.assertNil(self:poll(100, ctx("SAM_SEARCH"))[1].SeenAs)
end

function TestContactEvidence:test_only_the_radar_query_is_made_and_sight_range_alone_decides()
	-- DCS's type flag belongs to the object (the same in every channel), so it arrives with the radar query; a
	-- separate visual query would add nothing a crew could plausibly know beyond sight range.
	local b52 = makeContact({ pos = { x = 15000, y = 0, z = 0 }, vel = { x = -200, y = 0, z = 0 }, rcs = 100 })
	local near = makeContact({ pos = { x = 0, y = 0, z = 9000 }, vel = { x = -200, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = b52, type = true }, { object = near, type = true } }
	self.visual = { { object = b52, type = true } }
	local r = self:poll(100, ctx("SAM_SEARCH"))
	lu.assertNil(r[1].SeenAs)
	lu.assertEquals(r[2].SeenAs, SeenAs.AIRCRAFT)
	lu.assertEquals(self.visualCalls, 0)
end

function TestContactEvidence:test_night_and_fog_shorten_sight_recognition_as_they_do_for_observers()
	local SPS = Medusa.Services.SensorPollingService
	local savedNight, savedMission = IsNightTime, env.mission
	local jet = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	local near = makeContact({ pos = { x = 0, y = 0, z = 2000 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = jet, type = true }, { object = near, type = true } }
	IsNightTime = function()
		return true
	end
	env.mission = nil
	SPS._resetSight()
	local r = self:poll(100, ctx())
	lu.assertNil(r[1].SeenAs) -- 5 km at night: a quarter of the 10 km day recognition range is 2.5 km
	lu.assertEquals(r[2].SeenAs, SeenAs.AIRCRAFT)

	IsNightTime = function()
		return false
	end
	env.mission = { weather = { visibility = { distance = 3000 } } }
	SPS._resetSight()
	r = self:poll(200, ctx())
	IsNightTime, env.mission = savedNight, savedMission
	SPS._resetSight()
	lu.assertNil(r[1].SeenAs)
	lu.assertEquals(r[2].SeenAs, SeenAs.AIRCRAFT)
end

function TestContactEvidence:test_training_mode_takes_no_noise_draw_and_reads_the_clean_size()
	local svc = Medusa.Services.SensorPollingService:new(
		{ PerTrackScanUpdateRate = 1, SensorCleanupSec = 30, TrainingMode = true },
		{
			random = function()
				self.draws = self.draws + 1
				return 0.5
			end,
		}
	)
	local jet = makeContact({ pos = { x = 5000, y = 0, z = 0 }, vel = { x = -250, y = 0, z = 0 }, rcs = 5 })
	self.main = { { object = jet } }
	local r = svc:pollSensor("sam", 100, Medusa.Constants.TrackSource.SAM_BATTERY, 1, ctx("SAM_TRACK"))[1]
	local truth = db(5) + Medusa.Services.SensorPollingService.shapeOffsetDb(jet.id_)
	lu.assertEquals(r.SizeDb, math.floor(truth + 0.5))
	lu.assertEquals(self.draws, 0)
end
