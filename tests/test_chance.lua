local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Chance")

-- The sensing, identification and report chain draws its luck through Medusa.Chance. Outside training a draw makes
-- the same random() calls, in the same order, as the plain expression it stands for; in training (doctrine
-- TrainingMode) it is deterministic and never lets luck favor the attacker.

local Chance = Medusa.Chance

local function sequence(values)
	local i = 0
	local source = {}
	source.draws = 0
	source.fn = function()
		i = i + 1
		source.draws = source.draws + 1
		return values[(i - 1) % #values + 1]
	end
	return source
end

TestChance = {}

function TestChance:test_is_training_reads_the_doctrine_switch()
	lu.assertTrue(Chance.isTraining({ TrainingMode = true }))
	lu.assertFalse(Chance.isTraining({ TrainingMode = false }))
	lu.assertFalse(Chance.isTraining({}))
	lu.assertFalse(Chance.isTraining(nil))
end

function TestChance:test_uniform_draws_once_outside_training_and_gives_the_midpoint_in_training()
	local r = sequence({ 0.25 })
	lu.assertEquals(Chance.uniform(false, 10, 30, r.fn), 10 + 0.25 * 20)
	lu.assertEquals(r.draws, 1)
	lu.assertEquals(Chance.uniform(true, 10, 30, r.fn), 20)
	lu.assertEquals(r.draws, 1)
end

function TestChance:test_symmetric_noise_is_zero_in_training()
	local r = sequence({ 0.75 })
	lu.assertEquals(Chance.symmetric(false, 1000, r.fn), (2 * 0.75 - 1) * 1000)
	lu.assertEquals(Chance.symmetric(true, 1000, r.fn), 0)
	lu.assertEquals(r.draws, 1)
end

function TestChance:test_gauss_is_box_muller_with_two_draws_and_zero_in_training()
	local r = sequence({ 0.3, 0.1 })
	local expected = math.sqrt(-2 * math.log(1 - 0.3)) * math.cos(2 * math.pi * 0.1)
	lu.assertAlmostEquals(Chance.gauss(false, r.fn), expected, 1e-12)
	lu.assertEquals(r.draws, 2)
	lu.assertEquals(Chance.gauss(true, r.fn), 0)
	lu.assertEquals(r.draws, 2)
end

function TestChance:test_chance_is_the_iads_step_succeeding_and_always_succeeds_in_training()
	local r = sequence({ 0.9 })
	lu.assertFalse(Chance.chance(false, 0.25, r.fn))
	lu.assertTrue(Chance.chance(false, 0.95, r.fn))
	lu.assertTrue(Chance.chance(true, 0.0, r.fn))
	lu.assertEquals(r.draws, 2)
end

function TestChance:test_mishap_never_happens_in_training()
	local r = sequence({ 0.05 })
	lu.assertTrue(Chance.mishap(false, 0.10, r.fn))
	lu.assertFalse(Chance.mishap(true, 1.0, r.fn))
	lu.assertEquals(r.draws, 1)
end

function TestChance:test_default_source_is_math_random_read_at_call_time()
	local saved = math.random
	math.random = function()
		return 0.5
	end
	local ok, value = pcall(Chance.uniform, false, 0, 100)
	math.random = saved
	lu.assertTrue(ok)
	lu.assertEquals(value, 50)
end

function TestChance:test_hash_is_deterministic_and_spreads_names()
	lu.assertEquals(Chance.hash("obs-hill"), Chance.hash("obs-hill"))
	lu.assertNotEquals(Chance.hash("obs-hill"), Chance.hash("obs-hilm"))
	local f = Chance.fraction("Dog Ear-1")
	lu.assertTrue(f >= 0 and f < 1)
	lu.assertEquals(Chance.fraction("Dog Ear-1"), f)
	lu.assertNotEquals(Chance.fraction("Dog Ear-2"), f)
end

function TestChance:test_uniform_takes_a_deterministic_phase_in_training_when_given_one()
	local r = sequence({ 0.25 })
	lu.assertEquals(Chance.uniform(true, 100, 300, r.fn, 0.1), 120)
	lu.assertEquals(r.draws, 0)
	-- outside training the phase is ignored: one plain draw
	lu.assertEquals(Chance.uniform(false, 100, 300, r.fn, 0.1), 150)
	lu.assertEquals(r.draws, 1)
end

function TestChance:test_symmetric_with_a_seed_in_training_is_half_the_error_never_zero()
	local r = sequence({ 0.75 })
	-- deterministic, the expected error size (half the bound), sign from the seed's bit
	lu.assertEquals(Chance.symmetric(true, 1000, r.fn, 0), 500)
	lu.assertEquals(Chance.symmetric(true, 1000, r.fn, 1), -500)
	lu.assertEquals(Chance.symmetric(true, 1000, r.fn, 6), 500)
	lu.assertEquals(r.draws, 0)
	-- outside training the seed changes nothing
	lu.assertEquals(Chance.symmetric(false, 1000, r.fn, 1), (2 * 0.75 - 1) * 1000)
	lu.assertEquals(r.draws, 1)
end
