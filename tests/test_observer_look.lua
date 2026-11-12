local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("services.SensorPollingService")

-- One observer look (SensorPollingService.observeAirspace): the only DCS truth an observer report is built from.

local OBS = Medusa.Constants.Observer
local RED, BLUE = 1, 2
local observe = Medusa.Services.SensorPollingService.observeAirspace

local GLOBALS = {
	"SearchWorldObjects",
	"IsUnitActive",
	"GetUnitCoalition",
	"GetUnitCategoryEx",
	"GetUnitPosition",
	"GetUnitVelocity",
	"HasLOS",
	"IsNightTime",
	"GetGroupController",
	"GetControllerDetectedTargets",
	"GetUnitType",
}
local saved = {}
local world_units, los, night, detected, losChecks, detectedQueries, visited, savedMission

local function aircraft(id, x, y, z, opts)
	opts = opts or {}
	local u = {
		id_ = id,
		coal = opts.coalition or BLUE,
		cat = opts.category or Unit.Category.AIRPLANE,
		pos = { x = x, y = y, z = z },
		vel = opts.velocity or { x = 200, y = 0, z = 0 },
		airborne = opts.inAir ~= false,
		calls = 0,
		getName = function()
			return "air-" .. id
		end,
	}
	u.getCategoryEx = function(self)
		self.calls = self.calls + 1
		return self.cat
	end
	u.getCoalition = function(self)
		self.calls = self.calls + 1
		return self.coal
	end
	u.isActive = function(self)
		self.calls = self.calls + 1
		return true
	end
	u.inAir = function(self)
		self.calls = self.calls + 1
		return self.airborne
	end
	return u
end

local function groundUnit(id, x, z)
	return aircraft(id, x, 100, z, { category = Unit.Category.GROUND_UNIT, coalition = RED, inAir = false })
end

TestObserverLook = {}

function TestObserverLook:setUp()
	for i = 1, #GLOBALS do
		saved[GLOBALS[i]] = _G[GLOBALS[i]]
	end
	world_units, los, night, detected, losChecks, detectedQueries, visited = {}, true, false, nil, 0, 0, 0
	savedMission = env.mission
	env.mission = nil
	Medusa.Services.SensorPollingService._resetSight()
	SearchWorldObjects = function(_, volume, callback)
		local r = volume.params.radius
		local c = volume.params.point
		for i = 1, #world_units do
			local u = world_units[i]
			local dx, dy, dz = u.pos.x - c.x, u.pos.y - c.y, u.pos.z - c.z
			if dx * dx + dy * dy + dz * dz <= r * r then
				visited = visited + 1
				if callback(u) == false then
					break
				end
			end
		end
	end
	IsUnitActive = function()
		return true
	end
	GetUnitCoalition = function(u)
		return u.coal
	end
	GetUnitCategoryEx = function(u)
		return u.cat
	end
	GetUnitPosition = function(u)
		return { x = u.pos.x, y = u.pos.y, z = u.pos.z }
	end
	GetUnitVelocity = function(u)
		return u.vel
	end
	HasLOS = function()
		losChecks = losChecks + 1
		return los
	end
	IsNightTime = function()
		return night
	end
	GetGroupController = function()
		return {}
	end
	GetControllerDetectedTargets = function()
		detectedQueries = detectedQueries + 1
		return detected
	end
	GetUnitType = function(name)
		return name == "air-7" and "Su-25T" or nil
	end
end

function TestObserverLook:tearDown()
	for i = 1, #GLOBALS do
		_G[GLOBALS[i]] = saved[GLOBALS[i]]
	end
	env.mission = savedMission
	Medusa.Services.SensorPollingService._resetSight()
end

local function look()
	return {
		Position = { x = 0, y = 100, z = 0 },
		CoalitionId = RED,
		GroupName = "obs-1",
		Random = function()
			return 0.5
		end,
	}
end

function TestObserverLook:test_crew_sees_a_hostile_jet_and_reports_only_coarse_fields()
	world_units[1] = aircraft(7, 4100, 400, 2200, { velocity = { x = 200, y = 0, z = 200 } })
	local out = {}

	lu.assertTrue(observe(look(), out))

	lu.assertFalse(out.Heard)
	lu.assertEquals(out.Kind, "jet")
	lu.assertEquals(out.Heading8, "NE")
	lu.assertEquals(out.Speed, "fast")
	lu.assertEquals(out.Height, "low")
	lu.assertEquals(out.Count, "one")
	lu.assertEquals(out.Identity, "unidentified") -- 4.7 km: seen, but too far to tell friend from foe
	lu.assertNil(out.TypeName)
	lu.assertEquals(out.ErrorM, OBS.POSITION_ERROR_SEEN_M)
	lu.assertEquals(out.Position.x % OBS.POSITION_ROUND_M, 0)
	lu.assertEquals(out.Position.z % OBS.POSITION_ROUND_M, 0)
	lu.assertTrue(math.abs(out.Position.x - 4100) <= OBS.POSITION_ROUND_M)
	lu.assertNil(out.Velocity)
	lu.assertNil(out.UnitName)
end

function TestObserverLook:test_type_is_named_only_when_dcs_flags_it_known()
	world_units[1] = aircraft(7, 1500, 300, 0)
	detected = { { object = { id_ = 7 }, type = false } }
	local out = {}
	observe(look(), out)
	lu.assertNil(out.TypeName)

	detected = { { object = { id_ = 7 }, type = true } }
	observe(look(), out)
	lu.assertEquals(out.TypeName, "Su-25T")
end

function TestObserverLook:test_terrain_hides_a_distant_aircraft()
	world_units[1] = aircraft(7, 6000, 400, 0)
	los = false

	lu.assertFalse(observe(look(), {}))
end

function TestObserverLook:test_low_aircraft_behind_a_hill_is_heard_without_heading()
	world_units[1] = aircraft(7, 2000, 300, 1000)
	los = false
	local out = {}

	lu.assertTrue(observe(look(), out))

	lu.assertTrue(out.Heard)
	lu.assertNil(out.Heading8)
	lu.assertEquals(out.ErrorM, OBS.POSITION_ERROR_HEARD_M)
	lu.assertEquals(out.Height, "low")
end

function TestObserverLook:test_high_aircraft_is_not_heard()
	world_units[1] = aircraft(7, 500, 2500, 0)
	los = false

	lu.assertFalse(observe(look(), {}))
end

function TestObserverLook:test_night_shortens_sight()
	night = true
	world_units[1] = aircraft(7, 5000, 400, 0)
	lu.assertFalse(observe(look(), {}))

	world_units[1] = aircraft(7, 1200, 1200, 0)
	local out = {}
	lu.assertTrue(observe(look(), out))
	lu.assertFalse(out.Heard)
	lu.assertTrue(out.Night)
end

function TestObserverLook:test_friendly_and_neutral_aircraft_are_ignored()
	world_units[1] = aircraft(1, 1000, 300, 0, { coalition = RED })
	world_units[2] = aircraft(2, 1000, 300, 0, { coalition = 0 })

	lu.assertFalse(observe(look(), {}))
end

function TestObserverLook:test_helicopter_is_reported_as_a_slow_helicopter_and_height_bands()
	world_units[1] = aircraft(7, 2000, 150, 0, {
		category = Unit.Category.HELICOPTER,
		velocity = { x = 0, y = 0, z = -60 },
	})
	local out = {}
	observe(look(), out)
	lu.assertEquals(out.Kind, "helicopter")
	lu.assertEquals(out.Speed, "slow")
	lu.assertEquals(out.Heading8, "W")

	world_units[1] = aircraft(7, 3000, 7000, 0)
	observe(look(), out)
	lu.assertEquals(out.Height, "high")
	world_units[1] = aircraft(7, 3000, 3000, 0)
	observe(look(), out)
	lu.assertEquals(out.Height, "medium")
end

function TestObserverLook:test_counts_every_aircraft_but_checks_sight_within_budget()
	for i = 1, 12 do
		world_units[i] = aircraft(i, 5000 + i * 10, 400, 0)
	end
	local out = {}

	lu.assertTrue(observe(look(), out))

	lu.assertEquals(losChecks, OBS.MAX_SIGHT_CHECKS)
	lu.assertEquals(out.Count, "several")
end

function TestObserverLook:test_seen_aircraft_is_preferred_to_a_nearer_one_only_heard()
	world_units[1] = aircraft(1, 1000, 300, 0)
	world_units[2] = aircraft(7, 5000, 400, 0)
	HasLOS = function(_, to)
		return to.x > 2000
	end
	local out = {}

	observe(look(), out)

	lu.assertFalse(out.Heard)
	lu.assertEquals(out.Count, "two")
	lu.assertTrue(math.abs(out.Position.x - 5000) <= 1500)
end

-- == What a crew can plausibly tell, and what a look costs ==

function TestObserverLook:test_friend_or_foe_is_told_only_by_sight_close_by()
	local out = {}
	world_units[1] = aircraft(7, 1500, 300, 0)
	lu.assertTrue(observe(look(), out))
	lu.assertEquals(out.Identity, "hostile")

	world_units[1] = aircraft(7, 5000, 400, 0)
	lu.assertTrue(observe(look(), out))
	lu.assertEquals(out.Identity, "unidentified")

	-- An own aircraft seen close by is recognised and not reported...
	world_units[1] = aircraft(8, 1500, 300, 0, { coalition = RED })
	lu.assertFalse(observe(look(), {}))
	-- ...one only heard (behind a hill) or seen far off could be anyone's.
	los = false
	world_units[1] = aircraft(8, 2000, 300, 0, { coalition = RED })
	lu.assertTrue(observe(look(), out))
	lu.assertTrue(out.Heard)
	lu.assertEquals(out.Identity, "unidentified")
end

function TestObserverLook:test_counts_are_coarse()
	local out = {}
	for i = 1, 3 do
		world_units[i] = aircraft(i, 3000 + 100 * i, 400, 0)
	end
	observe(look(), out)
	lu.assertEquals(out.Count, "several")
	world_units[3] = nil
	observe(look(), out)
	lu.assertEquals(out.Count, "two")
end

function TestObserverLook:test_aircraft_on_the_ground_are_not_reported()
	world_units[1] = aircraft(7, 1500, 100, 0, { inAir = false })
	lu.assertFalse(observe(look(), {}))
end

function TestObserverLook:test_ground_units_cost_one_category_check_and_the_search_stops_after_a_fixed_number()
	for i = 1, 50 do
		world_units[i] = groundUnit(100 + i, 500 + i, 0)
	end
	world_units[51] = aircraft(7, 3000, 400, 0)
	lu.assertTrue(observe(look(), {}))
	for i = 1, 50 do
		lu.assertEquals(world_units[i].calls, 1)
	end

	-- A crowded spot (a base, a town): the search stops after MAX_VISITED objects.
	world_units, visited = {}, 0
	for i = 1, OBS.MAX_VISITED + 100 do
		world_units[i] = groundUnit(100 + i, 500, 0)
	end
	world_units[#world_units + 1] = aircraft(7, 3000, 400, 0)
	lu.assertFalse(observe(look(), {}))
	lu.assertEquals(visited, OBS.MAX_VISITED + 1)
end

function TestObserverLook:test_the_type_known_flag_is_read_only_within_recognition_range()
	detected = { { object = { id_ = 7 }, type = true } }
	local out = {}
	world_units[1] = aircraft(7, 5000, 400, 0)
	observe(look(), out)
	lu.assertEquals(detectedQueries, 0)
	lu.assertNil(out.TypeName)

	world_units[1] = aircraft(7, 1500, 300, 0)
	observe(look(), out)
	lu.assertEquals(detectedQueries, 1)
	lu.assertEquals(out.TypeName, "Su-25T")
end

function TestObserverLook:test_fog_and_mission_visibility_limit_sight()
	-- 2000 m up: too high to be heard, so only sight counts.
	env.mission = {
		weather = {
			visibility = { distance = 80000 },
			fog2 = { mode = 4, manual = { { time = 0, visibility = 1500, thickness = 300 } } },
		},
	}
	Medusa.Services.SensorPollingService._resetSight()
	world_units[1] = aircraft(7, 1500, 1500, 0)
	lu.assertFalse(observe(look(), {}))
	world_units[1] = aircraft(7, 400, 1250, 0)
	lu.assertTrue(observe(look(), {}))

	env.mission = { weather = { visibility = { distance = 4000 } } }
	Medusa.Services.SensorPollingService._resetSight()
	world_units[1] = aircraft(7, 5000, 2000, 0)
	lu.assertFalse(observe(look(), {}))
	world_units[1] = aircraft(7, 3500, 2000, 0)
	lu.assertTrue(observe(look(), {}))
end

function TestObserverLook:test_training_mode_offsets_the_position_by_the_expected_error_in_a_fixed_direction()
	-- Deterministic must not mean perfect: half the error bound on each axis (the expected size of the random
	-- error), its signs from the report's seed, whatever the random source says.
	world_units[1] = aircraft(7, 4100, 400, 2200)
	local function at(seed)
		local l = look()
		l.Random = function()
			return 0.99
		end
		l.Training = true
		l.Seed = seed
		local out = {}
		lu.assertTrue(observe(l, out))
		return out.Position.x, out.Position.z
	end

	lu.assertEquals({ at(0) }, { 4500, 2500 }) -- 4100 + 500, 2200 + 500, rounded to 500 m
	lu.assertEquals({ at(1) }, { 3500, 2500 })
	lu.assertEquals({ at(2) }, { 4500, 1500 })
	lu.assertEquals({ at(2) }, { at(2) })
	-- without a seed the group's name gives one: still an offset, never the true position
	local x, z = at(nil)
	lu.assertTrue(x ~= 4000 or z ~= 2000)
end

function TestObserverLook:test_error_scale_widens_or_narrows_the_position_error()
	world_units[1] = aircraft(7, 4100, 400, 2200)
	local l = look()
	l.ErrorScale = 1.4
	local out = {}

	lu.assertTrue(observe(l, out))

	lu.assertEquals(out.ErrorM, OBS.POSITION_ERROR_SEEN_M * 1.4)
end
