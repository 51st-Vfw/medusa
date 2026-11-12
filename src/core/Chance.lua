require("_header")

--[[
             ██████╗██╗  ██╗ █████╗ ███╗   ██╗ ██████╗███████╗
            ██╔════╝██║  ██║██╔══██╗████╗  ██║██╔════╝██╔════╝
            ██║     ███████║███████║██╔██╗ ██║██║     █████╗
            ██║     ██╔══██║██╔══██║██║╚██╗██║██║     ██╔══╝
            ╚██████╗██║  ██║██║  ██║██║ ╚████║╚██████╗███████╗
             ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝╚══════╝

    What this module does
    - The one place the sensing, identification and report chain draws its luck: return-size noise, observer looks,
      reports, delays, losses and position error, identification timers, MANPAD wake timing and hearing range, local
      radar sweep timing and readiness delays, listening-station intercepts and bearing errors. AAA fire, crew
      suppression and probe names draw their own.
    - Every draw takes the network's training flag (doctrine TrainingMode) and an optional random source ([0,1),
      injectable for tests; math.random, read at call time, by default).
    - Outside training a draw makes the same random() calls, in the same order, as the plain expression it stands
      for (lo + random() * (hi - lo) for a range, as stock Medusa's timers use). In training a draw is
      deterministic and luck never favours the attacker: a range gives its midpoint (or a fixed per-object phase,
      so timers of many objects do not all line up), noise is zero, a position error is its expected size in a
      fixed per-report direction (deterministic, not perfect), an IADS step that may fail succeeds (chance) and a
      mishap that would help the attacker never happens (mishap). DCS's own randomness (its detection, missile hits)
      is outside Medusa and stays.

    How others use it
    - Services call Medusa.Chance.uniform / symmetric / gauss / gaussError / chance / mishap with
      isTraining(doctrine); hash and fraction turn a name into a fixed number for the training phase and direction.
--]]

Medusa.Chance = {}

local TWO_PI = 2 * math.pi

--- True when the doctrine asks for training mode.
function Medusa.Chance.isTraining(doctrine)
	return doctrine ~= nil and doctrine.TrainingMode == true
end

local HASH_MOD = 16777213 -- a prime below 2^24: every step stays exact in a double
local HASH_SPREAD = 10368889 -- about 0.618 x HASH_MOD; hash x spread stays below 2^53, exact in a double

--- A fixed number in [0, HASH_MOD) from a text (the same text, the same number, on every run).
function Medusa.Chance.hash(text)
	local h = 5381
	local s = tostring(text)
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % HASH_MOD
	end
	return h
end

--- A fixed fraction in [0, 1) from a text: a per-object phase for training mode.
function Medusa.Chance.fraction(text)
	-- spread by a multiplier near 0.618 x HASH_MOD (Fibonacci hashing): names differing in their last character
	-- would otherwise land within a few thousandths of each other
	return (Medusa.Chance.hash(text) * HASH_SPREAD) % HASH_MOD / HASH_MOD
end

--- A value in [lo, hi): lo + random() * (hi - lo). In training the midpoint, or lo + phase * (hi - lo) when a fixed
--- phase in [0, 1) is given (so the timers of many objects do not line up).
function Medusa.Chance.uniform(training, lo, hi, random, phase)
	if training then
		if phase then
			return lo + phase * (hi - lo)
		end
		return (lo + hi) / 2
	end
	return lo + (random or math.random)() * (hi - lo)
end

--- Noise in (-half, half): (2 * random() - 1) * half. In training zero, or, with a whole-number `seed`, the noise's
--- expected size (half / 2) with the sign of the seed's lowest bit: a position error that is deterministic but not
--- perfect.
function Medusa.Chance.symmetric(training, half, random, seed)
	if training then
		if seed then
			return (seed % 2 == 0 and 0.5 or -0.5) * half
		end
		return 0
	end
	return (2 * (random or math.random)() - 1) * half
end

--- A standard Gaussian (Box-Muller, two draws); zero in training.
function Medusa.Chance.gauss(training, random)
	if training then
		return 0
	end
	random = random or math.random
	local u1 = 1 - random()
	return math.sqrt(-2 * math.log(u1)) * math.cos(TWO_PI * random())
end

local MEAN_ABS_GAUSS = math.sqrt(2 / math.pi) -- E|N(0,1)|, about 0.8

--- A standard Gaussian measurement error (a listening station's bearing). Outside training the same draws as
--- gauss; in training, with a whole-number `seed`, its expected size (E|N(0,1)| = 0.8) with the sign of the seed's
--- lowest bit, so the error is deterministic but not perfect; without a seed zero.
function Medusa.Chance.gaussError(training, random, seed)
	if training then
		if seed then
			return seed % 2 == 0 and MEAN_ABS_GAUSS or -MEAN_ABS_GAUSS
		end
		return 0
	end
	return Medusa.Chance.gauss(false, random)
end

--- An IADS step that succeeds with probability p (a report is made, a report gets through): random() < p; always
--- true in training.
function Medusa.Chance.chance(training, p, random)
	if training then
		return true
	end
	return (random or math.random)() < p
end

--- A mishap that helps the attacker, with probability p (a report is lost): random() < p; never in training.
function Medusa.Chance.mishap(training, p, random)
	if training then
		return false
	end
	return (random or math.random)() < p
end
