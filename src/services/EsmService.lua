require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("core.Chance")
require("core.Debrief")
require("services.CrewFactorsService")
require("services.SensorPollingService")
require("services.ObserverReportService")

--[[
    ESM SERVICE (listening stations)

    What this service does
    - Lets listening stations (ground groups named with the "esm" or "elint" role token; ObserverPost with Esm) hear
      the radars of hostile aircraft and take bearings on them (doctrine PassiveDetection, numbers in doctrine ESM).
      A station hears only what a direction finder could: an aircraft whose radar DCS reports transmitting
      (Unit.getRadar), within the radio horizon of a 4/3 earth, in terrain line of sight, and within the reach of the
      part of the radar's pattern it sits in. Main beam to ESM.MaxRangeKm: a searching radar's +-60 degrees about the
      nose (caught on 70% of looks); a locked radar's beam within 5 degrees of the line to its target (every look)
      and its sector, swept less often (30%); an early-warning radar all round to ESM.AewMaxRangeKm (95%). Sidelobes
      all round to ESM.SidelobeRangeKm (40%, error x1.5). Jammers cannot be heard: DCS does not tell a script that an
      aircraft is jamming.
    - A bearing is the true direction plus a Gaussian error (ESM.BearingSigmaDeg, doubled below 1 degree of elevation
      on a 4/3 earth, for ground multipath) and a coarse class: early-warning (AEW: DCS attribute AWACS), fire-control
      (FCR: fighters, interceptors, attack aircraft, bombers, attack helicopters) or other airborne radar (OTHER).
      Nothing names the aircraft. Two radars of one class within two bearing errors of each other are one bearing; a
      station sorts out at most Esm.MAX_BEARINGS_PER_CLASS radars of a class, more saturate it.
    - Bearings are matched up from the measurements only, never from which aircraft made them: two bearings of one
      class from different stations cross into a candidate (crossing angle at least 15 degrees, in front of both
      stations, within reach). A candidate is confirmed when a third station's bearing fits it: the three-bearing
      weighted least-squares fit's chi-square (squared misses in bearing errors; a bearing is a ray, so a point behind
      a station misses it) at most Esm.CHI2_MAX. Confirmed candidates become fixes best fit first, unless a rival
      explanation of one of their bearings is about as good (another plausible triple, or a plain crossing when the
      fit is no better than one missed intercept costs, Esm.CHI2_MISS); each fix takes in every further station's
      bearing that fits, and its error (the error ellipse's semi-major axis) grows with a poor fit. A candidate whose two bearings have no other
      possible partner (no other bearing of the class at any other station, nor a saturated station) is a two-station
      fix, trusted only when the next look repeats it; anything else is ambiguous (ghost crossings).
    - A fix reaches the network a few seconds later (data link). A fix good to Esm.CUE_MAX_ERROR_M is treated like a
      hostile observer report (ObserverReportService.cueHostileArea: MANPAD and gun crews, local cueing radars, a dark
      short- or medium-range SAM WARM), at most once per area every Esm.CUE_REST_SEC; a coarser one, or a two-station
      fix seen once, is evidence only. It never makes a track or a firing solution. A fire-control radar fix, or
      fire-control radars heard on 3 looks within 2 minutes, is hostile evidence for readiness
      (CrewFactorsService.wordSpreads); an early-warning radar alone never is.
    - Work is spread over ticks: one tick reads the hostile radars (one getRadar per hostile aircraft per look, only
      those near enough to the stations kept, at most Esm.MAX_EMITTERS in turn), then Esm.LISTEN_PER_TICK radars per
      tick per station, Esm.MATCH_WORK_PER_TICK crossings and third-bearing fits per tick, then the fixes in three
      stages (Esm.RESOLVE_PER_TICK candidates per tick); the station list changes only between looks; every
      ESM.LookIntervalSec.
    - Training mode: every intercept happens and a bearing error is its expected size in a fixed direction per
      station and 30-degree sector (Chance.gaussError with a seed), so the same geometry gives the same fix.

    How others use it
    - IadsNetwork calls tick every tick with the local-picture context (ctx.esm is this service's state) and stop
      when the doctrine turns it off.
    - Logs (INFO): "listening stations: ...", "esm fix: ...", "esm ambiguous: ...", "esm fix dropped: ...",
      "esm summary: ..."; DEBRIEF ESM_INTERCEPT (rate-limited per station, class and 30-degree sector), ESM_FIX (per
      area), ESM_AMBIGUOUS (per class).
--]]

Medusa.Services.EsmService = {}

local EsmSvc = Medusa.Services.EsmService
local E = Medusa.Constants.Esm
local Chance = Medusa.Chance
local Debrief = Medusa.Debrief
local logger = Medusa.Logger:ns("EsmService")

local TWO_PI = 2 * math.pi
local RAD = math.pi / 180
local DEG = 180 / math.pi
local sqrt, abs, cos, sin, atan2, floor, max, min =
	math.sqrt, math.abs, math.cos, math.sin, math.atan2, math.floor, math.max, math.min
local COS_SCAN = cos(E.SCAN_HALF_DEG * RAD)
local COS_BEAM = cos(E.BEAM_HALF_DEG * RAD)
local SIN_MIN_CROSS = sin(E.MIN_CROSS_DEG * RAD)
local GRAZING_RAD = E.GRAZING_DEG * RAD

local IDLE, LISTEN, ASSOCIATE = 0, 1, 2
local CLASSES = { "AEW", "FCR", "OTHER" }
local CLASS_WORD = { AEW = "early-warning radar", FCR = "fire-control radar", OTHER = "airborne radar" }
local FCR_ATTRIBUTES = {
	"Fighters",
	"Multirole fighters",
	"Interceptors",
	"Battleplanes",
	"Bombers",
	"Strategic bombers",
	"Attack helicopters",
}

EsmSvc.CLASS_WORD = CLASS_WORD

local function perClass()
	return { AEW = 0, FCR = 0, OTHER = 0 }
end

function EsmSvc.newState(random)
	return {
		stations = {},
		stationCount = 0,
		stationByName = {},
		rosterTime = nil,
		rosterSignature = nil,
		centerX = 0,
		centerZ = 0,
		radius = 0,
		emitters = {},
		emitterCount = 0,
		seen = {},
		emitterStart = 0,
		classCache = {},
		bearings = {},
		bearingCount = 0,
		groups = {},
		groupCount = 0,
		groupByName = {},
		cands = {},
		candCount = 0,
		candOverflow = false,
		confirmed = {},
		trio = {},
		fitList = {},
		phase = IDLE,
		resolving = false,
		cycleAt = nil,
		cursor = 0,
		emCursor = 1,
		pairI = 1,
		pairJ = 2,
		rowA = 1,
		colB = 1,
		pending = {},
		pendingCount = 0,
		tentPrev = {},
		tentPrevCount = 0,
		tentNext = {},
		tentNextCount = 0,
		fcrLooks = {},
		interceptRest = {},
		ambiguousRest = {},
		cellRest = {},
		coarseRest = {},
		dropRest = nil,
		ambiguousCounts = perClass(),
		crossingCounts = perClass(),
		totalUnused = perClass(),
		bucketCounts = {},
		rstage = 0,
		rnc = 0,
		racc = 1,
		rfixes = 0,
		bcN = {},
		bcList = {},
		totalSat = perClass(),
		woken = {},
		eye = { x = 0, y = 0, z = 0 },
		target = { x = 0, y = 0, z = 0 },
		fixPos = { x = 0, y = 0, z = 0 },
		stats = {
			cycles = 0,
			emitters = 0,
			pairs = 0,
			los = 0,
			bearings = 0,
			saturated = 0,
			fixes = 0,
			ambiguous = 0,
			cued = 0,
			rested = 0,
			dropped = 0,
			cpu = 0,
			cpuMax = 0,
		},
		summaryAt = nil,
		random = random or math.random,
		-- Tests replace these: emitterSource(state, coalitionId) fills state.emitters; los(eye, target); ground(x, z).
		emitterSource = nil,
		los = nil,
		ground = nil,
	}
end

-- ── The physics (pure) ──────────────────────────────────────────

--- Radio horizon over a 4/3 earth, metres: 4.12 km x (sqrt(h1) + sqrt(h2)), heights in metres above the surface.
function EsmSvc.horizonM(hAntenna, hTarget)
	return E.HORIZON_K_M * (sqrt(max(0, hAntenna)) + sqrt(max(0, hTarget)))
end

--- Direction from (ax, az) to (bx, bz): radians clockwise from north (DCS x north, z east), in [0, 2 pi).
function EsmSvc.bearing(ax, az, bx, bz)
	local b = atan2(bz - az, bx - ax)
	if b < 0 then
		b = b + TWO_PI
	end
	return b
end

--- a - b wrapped to [-pi, pi).
local function angleDiff(a, b)
	return (a - b + math.pi) % TWO_PI - math.pi
end
EsmSvc.angleDiff = angleDiff

--- Elevation of a point `dy` metres above and `d` metres away, on a 4/3 earth (radians).
function EsmSvc.elevation(dy, d)
	return atan2(dy - d * d / (2 * E.EARTH_EFFECTIVE_RADIUS_M), d)
end

--- The class of a radar from what the station's analysis tells apart: "AEW", "FCR" or "OTHER".
local function classOf(em)
	return em.Class or (em.Aew and "AEW" or "FCR")
end

--- Which part of the radar's main beam a station at (sx, sy, sz) sits in, and the chance one look catches it.
--- `em`: X, Y, Z, NoseX, NoseZ (the aircraft's nose), Class (or Aew), and TgtX, TgtY, TgtZ when the radar is locked on
--- a target. Returns "aew" | "held" | "scan" | "side" and the main-beam chance (0 for "side": sidelobes only).
function EsmSvc.lobe(em, sx, sy, sz)
	if classOf(em) == "AEW" then
		return "aew", E.INTERCEPT_AEW
	end
	local dx, dy, dz = sx - em.X, sy - em.Y, sz - em.Z
	local nx, nz = em.NoseX or 1, em.NoseZ or 0
	local hnorm = sqrt((nx * nx + nz * nz) * (dx * dx + dz * dz))
	local inSector = hnorm <= 0 or (nx * dx + nz * dz) / hnorm >= COS_SCAN
	if em.TgtX then
		local tx, ty, tz = em.TgtX - em.X, em.TgtY - em.Y, em.TgtZ - em.Z
		local norm = sqrt((tx * tx + ty * ty + tz * tz) * (dx * dx + dy * dy + dz * dz))
		if norm > 0 and (tx * dx + ty * dy + tz * dz) / norm >= COS_BEAM then
			return "held", E.INTERCEPT_HELD
		end
		if inSector then
			return "scan", E.INTERCEPT_LOCKED_SCAN
		end
		return "side", 0
	end
	if inSector then
		return "scan", E.INTERCEPT_SCAN
	end
	return "side", 0
end

--- Where two bearings cross. `a`, `b`: SX, SZ (station), B (bearing, radians; C, S its cosine and sine when known).
--- Returns x, z, the ranges along each bearing and |sin| of the crossing angle, or nil when they cross too shallowly
--- or behind a station.
function EsmSvc.cross(a, b)
	local ax, az = a.C or cos(a.B), a.S or sin(a.B)
	local bx, bz = b.C or cos(b.B), b.S or sin(b.B)
	local den = ax * bz - az * bx
	if abs(den) < SIN_MIN_CROSS then
		return nil
	end
	local wx, wz = b.SX - a.SX, b.SZ - a.SZ
	local t = (wx * bz - wz * bx) / den
	local u = (wx * az - wz * ax) / den
	if t <= 0 or u <= 0 then
		return nil
	end
	return a.SX + t * ax, a.SZ + t * az, t, u, abs(den)
end

--- 1-sigma position error of a two-bearing crossing: sqrt((Ra sa)^2 + (Rb sb)^2) / sin(crossing angle).
function EsmSvc.crossErrorM(ra, sigmaA, rb, sigmaB, sinCross)
	local ea, eb = ra * sigmaA, rb * sigmaB
	return sqrt(ea * ea + eb * eb) / sinCross
end

--- Weighted least-squares point of `n` bearings in `list` (SX, SZ, B, Sigma; each weighted by 1 / (range x sigma)^2
--- about the guess x0, z0). Returns x, z, the 1-sigma semi-major axis of the error ellipse and the fit's chi-square
--- (the sum of each bearing's squared miss in its own error); nil error when the bearings do not fix a point.
function EsmSvc.solve(list, n, x0, z0)
	local a11, a12, a22, b1, b2 = 0, 0, 0, 0, 0
	for k = 1, n do
		local m = list[k]
		local dx, dz = x0 - m.SX, z0 - m.SZ
		local e = max(1000, sqrt(dx * dx + dz * dz)) * m.Sigma
		local w = 1 / (e * e)
		local nx, nz = -(m.S or sin(m.B)), m.C or cos(m.B)
		local c = nx * m.SX + nz * m.SZ
		a11, a12, a22 = a11 + w * nx * nx, a12 + w * nx * nz, a22 + w * nz * nz
		b1, b2 = b1 + w * nx * c, b2 + w * nz * c
	end
	local det = a11 * a22 - a12 * a12
	if det <= 0 then
		return x0, z0, nil, nil
	end
	local x = (a22 * b1 - a12 * b2) / det
	local z = (a11 * b2 - a12 * b1) / det
	local chi2 = 0
	for k = 1, n do
		local m = list[k]
		local dx, dz = x - m.SX, z - m.SZ
		local r = max(1000, sqrt(dx * dx + dz * dz))
		local cb, sb = m.C or cos(m.B), m.S or sin(m.B)
		local miss
		if dx * cb + dz * sb > 0 then
			miss = (dz * cb - dx * sb) / (r * m.Sigma)
		else
			-- behind the station: a bearing is a ray, not a line
			miss = angleDiff(atan2(dz, dx), m.B) / m.Sigma
		end
		chi2 = chi2 + miss * miss
	end
	-- covariance = inverse of A: its larger eigenvalue is the semi-major axis squared
	local c11, c12, c22 = a22 / det, -a12 / det, a11 / det
	local half = (c11 + c22) / 2
	local root = sqrt(max(0, half * half - (c11 * c22 - c12 * c12)))
	return x, z, sqrt(half + root), chi2
end

-- ── Matching bearings up (measurements only) ───────────────────

local function prep(m)
	m.C, m.S = cos(m.B), sin(m.B)
end

--- Starts matching the bearings in state.bearings[1..state.bearingCount]: groups them by station. `sat` (optional):
--- per station name, per class, how many bearings the saturated station could not take.
local function beginMatch(state, maxRangeM, sat)
	local bearings = state.bearings
	state.reach = maxRangeM * E.RANGE_SLACK
	state.groupCount = 0
	local byName = state.groupByName
	for name in pairs(byName) do
		byName[name] = nil
	end
	for i = 1, state.bearingCount do
		local m = bearings[i]
		if not m.C then
			prep(m)
		end
		m.Used, m.Partners = false, 0
		local g = byName[m.Station]
		if not g then
			state.groupCount = state.groupCount + 1
			g = state.groups[state.groupCount]
			if not g then
				g = { List = {}, Sat = perClass(), Unused = perClass() }
				state.groups[state.groupCount] = g
			end
			g.Name, g.SX, g.SZ, g.N, g.Stamp = m.Station, m.SX, m.SZ, 0, nil
			local s = sat and sat[m.Station]
			for c = 1, #CLASSES do
				local cls = CLASSES[c]
				g.Sat[cls] = s and s[cls] or 0
			end
			byName[m.Station] = g
		end
		g.N = g.N + 1
		g.List[g.N] = i
	end
	for g = 1, state.groupCount do
		local grp = state.groups[g]
		for i = grp.N + 1, #grp.List do
			grp.List[i] = nil
		end
	end
	state.candCount, state.candOverflow = 0, false
	state.pairI, state.pairJ, state.rowA, state.colB = 1, 2, 1, 1
end

--- A crossing of bearings ia and ib, and the best third bearing that confirms it.
local function crossAndConfirm(state, ia, ib)
	local bearings = state.bearings
	local a, b = bearings[ia], bearings[ib]
	local reach = state.reach
	local x, z, t, u, s = EsmSvc.cross(a, b)
	if not x or t > reach or u > reach then
		return 0
	end
	if state.candCount >= E.MAX_CANDIDATES then
		state.candOverflow = true
		return 0
	end
	state.candCount = state.candCount + 1
	local c = state.cands[state.candCount]
	if not c then
		c = {}
		state.cands[state.candCount] = c
	end
	local errM = EsmSvc.crossErrorM(t, a.Sigma, u, b.Sigma, s)
	c.I, c.J, c.X, c.Z, c.ErrM, c.K, c.Chi2 = ia, ib, x, z, errM, nil, nil
	local gateErr = min(errM, E.GATE_ERROR_CAP_M)
	local trio = state.trio
	trio[1], trio[2] = a, b
	local fits = 0
	for g = 1, state.groupCount do
		local grp = state.groups[g]
		if grp.Name ~= a.Station and grp.Name ~= b.Station then
			local vx, vz = x - grp.SX, z - grp.SZ
			local r = sqrt(vx * vx + vz * vz)
			if r > 0 and r <= reach then
				local toP = atan2(vz, vx)
				local spread = gateErr / r
				for k = 1, grp.N do
					local idx = grp.List[k]
					local m = bearings[idx]
					if m.Class == a.Class then
						local loose = 3 * sqrt(m.Sigma * m.Sigma + spread * spread)
						if abs(angleDiff(m.B, toP)) <= loose then
							trio[3] = m
							fits = fits + 1
							local _, _, _, chi2 = EsmSvc.solve(trio, 3, x, z)
							if chi2 and chi2 <= E.CHI2_PLAUSIBLE and (not c.Chi2 or chi2 < c.Chi2) then
								c.K, c.Chi2 = idx, chi2
							end
						end
					end
				end
			end
		end
	end
	trio[1], trio[2], trio[3] = nil, nil, nil
	return fits
end

--- Crosses bearing pairs, station pair by station pair, until `budget` work is done: one unit per crossing and
--- one per third-bearing fit tried. Returns true when every pair is done.
local function matchStep(state, budget)
	local bearings = state.bearings
	local groups, n = state.groups, state.groupCount
	local work = 0
	while work < budget do
		if state.pairI >= n then
			return true
		end
		local A, B = groups[state.pairI], groups[state.pairJ]
		if state.rowA > A.N then
			state.rowA, state.colB = 1, 1
			state.pairJ = state.pairJ + 1
			if state.pairJ > n then
				state.pairI = state.pairI + 1
				state.pairJ = state.pairI + 1
			end
		elseif state.colB > B.N then
			state.rowA, state.colB = state.rowA + 1, 1
		else
			local ia, ib = A.List[state.rowA], B.List[state.colB]
			if bearings[ib].Class == bearings[ia].Class then
				work = work + 1 + crossAndConfirm(state, ia, ib)
			end
			state.colB = state.colB + 1
		end
	end
	return state.pairI >= n
end

local function indexCand(bcN, bcList, idx, c)
	local list = bcList[idx]
	if not list then
		list = {}
		bcList[idx] = list
	end
	bcN[idx] = bcN[idx] + 1
	list[bcN[idx]] = c
end

--- True when confirmed crossing `d` explains a bearing of `c` differently: it takes another bearing from one of c's
--- stations (a different aircraft there), so c and d cannot both be true.
local function clashes(bearings, c, idx)
	if not idx then
		return false
	end
	local st = bearings[idx].Station
	return (st == bearings[c.I].Station and idx ~= c.I)
		or (st == bearings[c.J].Station and idx ~= c.J)
		or (st == bearings[c.K].Station and idx ~= c.K)
end

local function conflicts(bearings, c, d)
	return clashes(bearings, c, d.I) or clashes(bearings, c, d.J) or clashes(bearings, c, d.K)
end

--- True when bearing `idx` of confirmed crossing `c` has a rival explanation nearly as good whose bearings are all
--- still free, so the network cannot tell which is right: another plausible three-bearing crossing (chi-square
--- within Esm.CHI2_PLAUSIBLE), or a two-bearing crossing, which needs one station to have missed the radar (cost
--- Esm.CHI2_MISS = -2 ln(1 - 0.7)), when that costs no more than c's own misfit.
local function contested(state, c, idx)
	local bearings = state.bearings
	local list = state.bcList[idx]
	for k = 1, state.bcN[idx] do
		local d = list[k]
		if d ~= c and not bearings[d.I].Used and not bearings[d.J].Used then
			local triple = d.K and d.Chi2
			if triple then
				if not bearings[d.K].Used and conflicts(bearings, c, d) then
					return true
				end
			elseif E.CHI2_MISS <= c.Chi2 and conflicts(bearings, c, d) then
				return true
			end
		end
	end
	return false
end

--- A confirmed crossing becomes a fix: every further station's unused bearing of the class that fits joins it.
local function makeFix(state, c, stamp, onFix)
	local bearings = state.bearings
	local list = state.fitList
	local a, b, m = bearings[c.I], bearings[c.J], bearings[c.K]
	a.Used, b.Used, m.Used = true, true, true
	list[1], list[2], list[3] = a, b, m
	local n = 3
	local names = a.Station .. "," .. b.Station .. "," .. m.Station
	local x, z, semi, chi2 = EsmSvc.solve(list, 3, c.X, c.Z)
	local byName = state.groupByName
	byName[a.Station].Stamp, byName[b.Station].Stamp, byName[m.Station].Stamp = stamp, stamp, stamp
	for g = 1, state.groupCount do
		local grp = state.groups[g]
		if grp.Stamp ~= stamp then
			local best, bx, bz, bsemi, bchi2
			for k = 1, grp.N do
				local cand = bearings[grp.List[k]]
				if not cand.Used and cand.Class == a.Class then
					list[n + 1] = cand
					local px, pz, psemi, pchi2 = EsmSvc.solve(list, n + 1, x, z)
					if pchi2 and pchi2 - chi2 <= E.CHI2_MAX and (not best or pchi2 < bchi2) then
						best, bx, bz, bsemi, bchi2 = cand, px, pz, psemi, pchi2
					end
				end
			end
			if best then
				n = n + 1
				list[n] = best
				best.Used = true
				grp.Stamp = stamp
				names = names .. "," .. best.Station
				x, z, semi, chi2 = bx, bz, bsemi, bchi2
			end
			list[n + 1] = nil
		end
	end
	-- a poor fit is a less certain one
	local errM = (semi or c.ErrM) * max(1, sqrt(chi2 / (n - 2)))
	for i = 1, n do
		list[i] = nil
	end
	onFix(x, z, errM, a.Class, names, n, n .. "_station", chi2)
end

--- Resolves the crossings into fixes: confirmed ones best fit first, then lone two-station crossings. Calls
--- onFix(x, z, errM, class, stations, n, how, chi2) per fix; fills state.ambiguousCounts and state.crossingCounts per
--- class. Returns fixes, ambiguous bearings and unresolved crossings.
local CHI2_BUCKETS = 16

--- Resolving, stage 1: the fix-grade crossings in order of fit (a counting sort on chi-square, so the cost stays
--- linear), and every crossing indexed by its bearings, to find the rival explanations of each bearing.
local function resolveBegin(state)
	local conf, cands = state.confirmed, state.cands
	local counts = state.bucketCounts
	for b = 1, CHI2_BUCKETS + 1 do
		counts[b] = 0
	end
	local nc = 0
	for i = 1, state.candCount do
		local c = cands[i]
		if c.K and c.Chi2 <= E.CHI2_MAX then
			nc = nc + 1
			c.Bucket = min(CHI2_BUCKETS, floor(c.Chi2 / E.CHI2_MAX * CHI2_BUCKETS)) + 1
			counts[c.Bucket + 1] = counts[c.Bucket + 1] + 1
		end
	end
	for b = 2, CHI2_BUCKETS + 1 do
		counts[b] = counts[b] + counts[b - 1]
	end
	for i = 1, state.candCount do
		local c = cands[i]
		if c.K and c.Chi2 <= E.CHI2_MAX then
			counts[c.Bucket] = counts[c.Bucket] + 1
			conf[counts[c.Bucket]] = c
		end
	end
	for i = nc + 1, #conf do
		conf[i] = nil
	end
	local bcN, bcList = state.bcN, state.bcList
	for i = 1, state.bearingCount do
		bcN[i] = 0
	end
	for i = 1, state.candCount do
		local c = cands[i]
		indexCand(bcN, bcList, c.I, c)
		indexCand(bcN, bcList, c.J, c)
		if c.K then
			indexCand(bcN, bcList, c.K, c)
		end
	end
	state.rnc, state.racc, state.rfixes = nc, 1, 0
end

--- Resolving, stage 2: up to `budget` fix-grade crossings, best fit first, become fixes when their bearings are free
--- and no rival explanation is plausible.
local function resolveAccept(state, onFix, budget)
	local bearings, conf = state.bearings, state.confirmed
	local last = min(state.rnc, state.racc + budget - 1)
	for i = state.racc, last do
		local c = conf[i]
		if
			not bearings[c.I].Used
			and not bearings[c.J].Used
			and not bearings[c.K].Used
			and not contested(state, c, c.I)
			and not contested(state, c, c.J)
			and not contested(state, c, c.K)
		then
			state.rfixes = state.rfixes + 1
			makeFix(state, c, state.rfixes, onFix)
		end
	end
	state.racc = last + 1
	return state.racc > state.rnc
end

--- Resolving, stage 3: lone two-station crossings, and what stays ambiguous. Fills state.ambiguousCounts and
--- state.crossingCounts per class. Returns fixes, ambiguous bearings and unresolved crossings.
local function resolveFinish(state, onFix)
	local bearings = state.bearings
	local fixes = state.rfixes
	local bcN, bcList = state.bcN, state.bcList
	for i = 1, state.bearingCount do
		local list = bcList[i]
		if list then
			for k = 1, bcN[i] do
				list[k] = nil
			end
		end
	end
	for i = 1, state.rnc do
		state.confirmed[i] = nil
	end
	-- every unused bearing of the class at another station (or one a saturated station lost) is a possible partner
	local total, sat = state.totalUnused, state.totalSat
	for k = 1, #CLASSES do
		total[CLASSES[k]], sat[CLASSES[k]] = 0, 0
	end
	for g = 1, state.groupCount do
		local grp = state.groups[g]
		local unused = grp.Unused
		for k = 1, #CLASSES do
			unused[CLASSES[k]] = 0
		end
		for k = 1, grp.N do
			local m = bearings[grp.List[k]]
			if not m.Used then
				unused[m.Class] = unused[m.Class] + 1
			end
		end
		for k = 1, #CLASSES do
			local cls = CLASSES[k]
			total[cls] = total[cls] + unused[cls]
			sat[cls] = sat[cls] + grp.Sat[cls]
		end
	end
	for g = 1, state.groupCount do
		local grp = state.groups[g]
		for k = 1, grp.N do
			local m = bearings[grp.List[k]]
			if not m.Used then
				local cls = m.Class
				m.Partners = total[cls] - grp.Unused[cls] + sat[cls] - grp.Sat[cls]
			end
		end
	end
	local list = state.fitList
	local crossings = 0
	local crossingCounts = state.crossingCounts
	for k = 1, #CLASSES do
		crossingCounts[CLASSES[k]] = 0
	end
	for i = 1, state.candCount do
		local c = state.cands[i]
		local a, b = bearings[c.I], bearings[c.J]
		if not a.Used and not b.Used then
			if a.Partners == 1 and b.Partners == 1 then
				a.Used, b.Used = true, true
				list[1], list[2] = a, b
				local x, z, errM = EsmSvc.solve(list, 2, c.X, c.Z)
				list[1], list[2] = nil, nil
				fixes = fixes + 1
				onFix(x, z, errM or c.ErrM, a.Class, a.Station .. "," .. b.Station, 2, "2_station", 0)
			else
				crossings = crossings + 1
				crossingCounts[a.Class] = crossingCounts[a.Class] + 1
			end
		end
	end
	local ambiguousCounts = state.ambiguousCounts
	for k = 1, #CLASSES do
		ambiguousCounts[CLASSES[k]] = 0
	end
	local ambiguous = 0
	for i = 1, state.bearingCount do
		local m = bearings[i]
		if not m.Used and m.Partners > 0 then
			ambiguous = ambiguous + 1
			ambiguousCounts[m.Class] = ambiguousCounts[m.Class] + 1
		end
	end
	return fixes, ambiguous, crossings
end

--- Matches the bearings in state.bearings[1..state.bearingCount] into fixes in one go (the service spreads the
--- same work over ticks). Calls onFix(x, z, errM, class, stations, n, how, chi2) for each fix and returns fixes,
--- ambiguous bearings and unresolved crossings. `maxRangeM`: the stations' reach (crossings beyond are implausible).
--- `sat` (optional): per station name, per class, the bearings a saturated station could not take.
function EsmSvc.associate(state, maxRangeM, onFix, sat)
	beginMatch(state, maxRangeM, sat)
	matchStep(state, math.huge)
	resolveBegin(state)
	resolveAccept(state, onFix, math.huge)
	return resolveFinish(state, onFix)
end

-- ── DCS side ────────────────────────────────────────────────────

local AIR_CATEGORIES = nil

local function unitClass(state, unit)
	local key = unit.id_
	local cached = key and state.classCache[key]
	if cached then
		return cached
	end
	local class = "OTHER"
	local okAttr, aew = pcall(unit.hasAttribute, unit, "AWACS")
	if okAttr and aew == true then
		class = "AEW"
	else
		for i = 1, #FCR_ATTRIBUTES do
			local ok, has = pcall(unit.hasAttribute, unit, FCR_ATTRIBUTES[i])
			if ok and has == true then
				class = "FCR"
				break
			end
		end
	end
	if key then
		state.classCache[key] = class
	end
	return class
end

--- The radars transmitting on the hostile side's aircraft in flight near enough to the stations to matter, read
--- once per look for every station: position, nose, class, and the target a radar is locked on. More than
--- Esm.MAX_EMITTERS: a different window of them each look. Fills state.emitters; returns the count.
function EsmSvc.readEmitters(state, coalitionId, cfg)
	local side = coalition and coalition.side
	if not side or not Group or not Group.Category then
		return 0
	end
	local enemy = coalitionId == side.RED and side.BLUE or (coalitionId == side.BLUE and side.RED or nil)
	if not enemy then
		return 0
	end
	local farM = state.radius + max(cfg.MaxRangeKm, cfg.AewMaxRangeKm or 0) * 1000
	local farSq = farM * farM
	local cx, cz = state.centerX, state.centerZ
	local seen, count = state.seen, 0
	AIR_CATEGORIES = AIR_CATEGORIES or { Group.Category.AIRPLANE, Group.Category.HELICOPTER }
	for c = 1, #AIR_CATEGORIES do
		local groups = GetCoalitionGroups(enemy, AIR_CATEGORIES[c]) or {}
		for g = 1, #groups do
			local okUnits, units = pcall(groups[g].getUnits, groups[g])
			if okUnits and units then
				for k = 1, #units do
					local unit = units[k]
					local okRadar, on, tracked = pcall(unit.getRadar, unit)
					local okPos, pos = false, nil
					if okRadar and on == true and count < E.MAX_SEEN then
						okPos, pos = pcall(unit.getPosition, unit)
					end
					if okPos and pos and pos.p then
						local dx, dz = pos.p.x - cx, pos.p.z - cz
						local okAir, airborne = pcall(unit.inAir, unit)
						if dx * dx + dz * dz <= farSq and okAir and airborne == true then
							count = count + 1
							local em = seen[count]
							if not em then
								em = {}
								seen[count] = em
							end
							em.X, em.Y, em.Z = pos.p.x, pos.p.y, pos.p.z
							em.NoseX, em.NoseZ = pos.x and pos.x.x or 1, pos.x and pos.x.z or 0
							em.Class = unitClass(state, unit)
							em.Aew = em.Class == "AEW"
							em.TgtX, em.TgtY, em.TgtZ = nil, nil, nil
							if tracked then
								local okT, tp = pcall(tracked.getPoint, tracked)
								if okT and tp then
									em.TgtX, em.TgtY, em.TgtZ = tp.x, tp.y, tp.z
								end
							end
							em.GroundY = nil
						end
					end
				end
			end
		end
	end
	local emitters = state.emitters
	local n = min(count, E.MAX_EMITTERS)
	local start = 0
	if count > E.MAX_EMITTERS then
		start = state.emitterStart % count
		state.emitterStart = start + E.MAX_EMITTERS
	end
	for i = 1, n do
		emitters[i] = seen[(start + i - 1) % count + 1]
	end
	for i = n + 1, #emitters do
		emitters[i] = nil
	end
	return n
end

local function groundHeight(state, x, z)
	if state.ground then
		return state.ground(x, z)
	end
	local ok, h = pcall(land.getHeight, { x = x, y = z })
	return ok and h or 0
end

local function lineOfSight(state, eye, target)
	if state.los then
		return state.los(eye, target)
	end
	return HasLOS(eye, target) == true
end

local function rebuildStations(ctx, state)
	state.stationCount = 0
	local store = ctx.observerStore
	local posts = store and store:getAll() or {}
	local byName = state.stationByName
	for name in pairs(byName) do
		byName[name] = nil
	end
	local sx, sz = 0, 0
	for i = 1, #posts do
		local post = posts[i]
		if post.Esm then
			local p = Medusa.Services.SensorPollingService.observerPosition(post.UnitNames)
			if p then
				state.stationCount = state.stationCount + 1
				local s = state.stations[state.stationCount]
				if not s then
					s = { List = {}, Count = perClass(), Sat = perClass() }
					state.stations[state.stationCount] = s
				end
				s.Name, s.X, s.Z, s.GroundY = post.GroupName, p.x, p.z, p.y
				s.Hash = Chance.hash(post.GroupName)
				byName[s.Name] = s
				sx, sz = sx + p.x, sz + p.z
			end
		end
	end
	for i = state.stationCount + 1, #state.stations do
		state.stations[i] = nil
	end
	local n = state.stationCount
	state.centerX, state.centerZ, state.radius = 0, 0, 0
	if n > 0 then
		state.centerX, state.centerZ = sx / n, sz / n
		for i = 1, n do
			local s = state.stations[i]
			local dx, dz = s.X - state.centerX, s.Z - state.centerZ
			state.radius = max(state.radius, sqrt(dx * dx + dz * dz))
		end
	end
	state.rosterTime = ctx.now
	local names = {}
	for i = 1, n do
		names[i] = state.stations[i].Name
	end
	local signature = table.concat(names, ", ")
	if signature ~= (state.rosterSignature or "") then
		state.rosterSignature = signature
		logger:info(string.format("listening stations: %d (%s)", n, n > 0 and signature or "none left"))
	end
end

local function settings(doctrine)
	return doctrine.ESM
		or {
			MastHeightM = E.DEFAULT_MAST_HEIGHT_M,
			MaxRangeKm = E.DEFAULT_MAX_RANGE_KM,
			SidelobeRangeKm = E.DEFAULT_SIDELOBE_RANGE_KM,
			AewMaxRangeKm = E.DEFAULT_AEW_MAX_RANGE_KM,
			BearingSigmaDeg = E.DEFAULT_BEARING_SIGMA_DEG,
			LookIntervalSec = E.DEFAULT_LOOK_INTERVAL_SEC,
		}
end

local function startStationLook(s)
	s.N = 0
	for k = 1, #CLASSES do
		s.Count[CLASSES[k]], s.Sat[CLASSES[k]] = 0, 0
	end
end

--- Records a bearing at station `s`; a radar of the class within two bearing errors of one the station already has is
--- the same bearing to it; a station that already holds MAX_BEARINGS_PER_CLASS of the class is saturated.
local function addBearing(state, s, b, sigma, class, now)
	local list = s.List
	for i = 1, s.N do
		local m = state.bearings[list[i]]
		if m.Class == class and abs(angleDiff(b, m.B)) <= E.MERGE_SIGMAS * max(sigma, m.Sigma) then
			m.Count = m.Count + 1
			return m, false
		end
	end
	if s.Count[class] >= E.MAX_BEARINGS_PER_CLASS then
		s.Sat[class] = s.Sat[class] + 1
		state.stats.saturated = state.stats.saturated + 1
		return nil, false
	end
	s.Count[class] = s.Count[class] + 1
	state.bearingCount = state.bearingCount + 1
	local m = state.bearings[state.bearingCount]
	if not m then
		m = {}
		state.bearings[state.bearingCount] = m
	end
	m.Station, m.SX, m.SZ, m.B, m.Sigma, m.Class, m.T, m.Count = s.Name, s.X, s.Z, b, sigma, class, now, 1
	prep(m)
	s.N = s.N + 1
	list[s.N] = state.bearingCount
	return m, true
end

--- Station `s` listens to emitters [from, to] of the snapshot: cheap gates first (range, horizon, lobe reach),
--- terrain line of sight last, then the intercept chance and the bearing.
local function listen(ctx, state, s, cfg, from, to)
	local training = Chance.isTraining(ctx.doctrine)
	local random = state.random
	local maxR, sideR, aewR = cfg.MaxRangeKm * 1000, cfg.SidelobeRangeKm * 1000, cfg.AewMaxRangeKm * 1000
	local sigma0 = cfg.BearingSigmaDeg * RAD
	local sy = s.GroundY + cfg.MastHeightM
	local stats = state.stats
	for i = from, to do
		local em = state.emitters[i]
		local class = classOf(em)
		local mainR = class == "AEW" and aewR or maxR
		local dx, dz = em.X - s.X, em.Z - s.Z
		local d2 = dx * dx + dz * dz
		if d2 <= mainR * mainR then
			stats.pairs = stats.pairs + 1
			if not em.GroundY then
				em.GroundY = groundHeight(state, em.X, em.Z)
			end
			local ref = min(s.GroundY, em.GroundY)
			local horizon = EsmSvc.horizonM(sy - ref, em.Y - ref)
			local _, pMain = EsmSvc.lobe(em, s.X, sy, s.Z)
			local side = class ~= "AEW" and d2 <= sideR * sideR
			if d2 <= horizon * horizon and (pMain > 0 or side) then
				stats.los = stats.los + 1
				local eye, target = state.eye, state.target
				eye.x, eye.y, eye.z = s.X, sy, s.Z
				target.x, target.y, target.z = em.X, em.Y, em.Z
				if lineOfSight(state, eye, target) then
					local sigma
					if pMain > 0 and Chance.chance(training, pMain, random) then
						sigma = sigma0
					elseif side and Chance.chance(training, E.INTERCEPT_SIDELOBE, random) then
						sigma = sigma0 * E.SIDELOBE_SIGMA_FACTOR
					end
					if sigma then
						local dist = sqrt(d2)
						if EsmSvc.elevation(em.Y - sy, dist) < GRAZING_RAD then
							sigma = sigma * E.GRAZING_SIGMA_FACTOR
						end
						local truth = EsmSvc.bearing(s.X, s.Z, em.X, em.Z)
						-- training: the error's direction is fixed per station and 30-degree sector
						local seed = training and (s.Hash + floor(truth * DEG / E.SECTOR_DEG)) or nil
						local b = (truth + Chance.gaussError(training, random, seed) * sigma) % TWO_PI
						local m, new = addBearing(state, s, b, sigma, class, ctx.now)
						if new then
							stats.bearings = stats.bearings + 1
							local deg = m.B * DEG
							local key = s.Name .. "|" .. class .. "|" .. floor(deg / E.SECTOR_DEG)
							local last = state.interceptRest[key]
							if not last or ctx.now - last >= E.INTERCEPT_REST_SEC or ctx.now < last then
								state.interceptRest[key] = ctx.now
								Debrief.emit(
									ctx.networkId,
									ctx.now,
									"ESM_INTERCEPT",
									"station",
									s.Name,
									"brg",
									string.format("%.1f", deg),
									"sigma_deg",
									string.format("%.1f", sigma * DEG),
									"class",
									class
								)
							end
						end
					end
				end
			end
		end
	end
end

-- ── Fixes to the network ────────────────────────────────────────

local function readinessEvidence(ctx, why)
	if ctx.crew then
		Medusa.Services.CrewFactorsService.wordSpreads(
			ctx.crew,
			ctx.now,
			ctx.networkId,
			why,
			Chance.isTraining(ctx.doctrine)
		)
	end
end

local function cellKey(class, x, z)
	return class .. "|" .. floor(x / E.CUE_CELL_M) .. "|" .. floor(z / E.CUE_CELL_M)
end

local function resting(rest, key, now, sec)
	local last = rest[key]
	return last ~= nil and now >= last and now - last < sec
end

--- A fix that acts on nothing (too coarse, or two bearings seen once): logged and debriefed, once per area a minute.
local function evidenceOnly(ctx, state, x, z, errM, class, stations, how, lookT, why)
	local key = cellKey(class, x, z)
	if resting(state.coarseRest, key, ctx.now, E.CUE_REST_SEC) then
		return
	end
	state.coarseRest[key] = ctx.now
	logger:info(
		string.format(
			"esm fix: %s near (%.0f, %.0f) +-%.1f km from %s (%s), %s",
			CLASS_WORD[class],
			x,
			z,
			errM / 1000,
			stations,
			how,
			why
		)
	)
	Debrief.emit(
		ctx.networkId,
		ctx.now,
		"ESM_FIX",
		"class",
		class,
		"x",
		string.format("%.0f", x),
		"z",
		string.format("%.0f", z),
		"err_km",
		string.format("%.1f", errM / 1000),
		"how",
		how,
		"stations",
		stations,
		"look_t",
		string.format("%.1f", lookT),
		"caused",
		"evidence_only"
	)
end

local function queueFix(ctx, state, x, z, errM, class, stations, n, how)
	state.stats.fixes = state.stats.fixes + 1
	local pending = state.pending
	local slot
	for i = 1, E.MAX_PENDING do
		local f = pending[i]
		if not f then
			f = {}
			pending[i] = f
		end
		if not f.DueAt then
			slot = f
			break
		end
	end
	if not slot then
		state.stats.dropped = state.stats.dropped + 1
		local last = state.dropRest
		if not last or ctx.now < last or ctx.now - last >= E.CUE_REST_SEC then
			state.dropRest = ctx.now
			logger:info(string.format("esm fix dropped: %d fixes already waiting (%s)", E.MAX_PENDING, how))
		end
		return
	end
	slot.DueAt = ctx.now
		+ Chance.uniform(Chance.isTraining(ctx.doctrine), E.DELAY_MIN_SEC, E.DELAY_MAX_SEC, state.random)
	slot.MadeAt = state.cycleAt or ctx.now
	slot.X, slot.Z, slot.ErrM, slot.Class, slot.Stations, slot.N, slot.How = x, z, errM, class, stations, n, how
	state.pendingCount = state.pendingCount + 1
end

--- A fix found in a look: two-station fixes need the next look to repeat them; the rest go to the network.
local function onFix(ctx, state, x, z, errM, class, stations, n, how)
	if n == 2 then
		local now = state.cycleAt or ctx.now
		local repeated = false
		for i = 1, state.tentPrevCount do
			local t = state.tentPrev[i]
			if t.Class == class then
				local dx, dz = x - t.X, z - t.Z
				local gate = E.REPEAT_GATE_SIGMAS * sqrt(errM * errM + t.ErrM * t.ErrM) + E.MOVE_MPS * (now - t.T)
				if dx * dx + dz * dz <= gate * gate then
					repeated = true
					break
				end
			end
		end
		state.tentNextCount = state.tentNextCount + 1
		local t = state.tentNext[state.tentNextCount]
		if not t then
			t = {}
			state.tentNext[state.tentNextCount] = t
		end
		t.Class, t.X, t.Z, t.ErrM, t.T = class, x, z, errM, now
		if not repeated then
			evidenceOnly(ctx, state, x, z, errM, class, stations, "2_station_single", now, "seen once, evidence only")
			return
		end
		how = "2_station_repeat"
	end
	queueFix(ctx, state, x, z, errM, class, stations, n, how)
end

local function deliver(ctx, state, f)
	local now = ctx.now
	if f.Class == "FCR" then
		readinessEvidence(ctx, "radar_fix")
	end
	if f.ErrM > E.CUE_MAX_ERROR_M then
		evidenceOnly(ctx, state, f.X, f.Z, f.ErrM, f.Class, f.Stations, f.How, f.MadeAt, "too coarse to cue")
		return
	end
	local key = cellKey(f.Class, f.X, f.Z)
	if resting(state.cellRest, key, now, E.CUE_REST_SEC) then
		state.stats.rested = state.stats.rested + 1
		return
	end
	state.cellRest[key] = now
	local woken = state.woken
	local p = state.fixPos
	p.x, p.z = f.X, f.Z
	p.y = groundHeight(state, f.X, f.Z)
	local crews, radars, woke = Medusa.Services.ObserverReportService.cueHostileArea(
		ctx,
		p,
		"listening stations " .. f.Stations,
		"esm_fix",
		2 * f.ErrM,
		woken
	)
	if crews + radars + woke > 0 then
		state.stats.cued = state.stats.cued + 1
	end
	local caused = Medusa.Services.ObserverReportService.causedWord(woke, crews, radars)
	logger:info(
		string.format(
			"esm fix: %s near (%.0f, %.0f) +-%.1f km from %s (%s), %s",
			CLASS_WORD[f.Class],
			f.X,
			f.Z,
			f.ErrM / 1000,
			f.Stations,
			f.How,
			caused
		)
	)
	Debrief.emit(
		ctx.networkId,
		now,
		"ESM_FIX",
		"class",
		f.Class,
		"x",
		string.format("%.0f", f.X),
		"z",
		string.format("%.0f", f.Z),
		"err_km",
		string.format("%.1f", f.ErrM / 1000),
		"how",
		f.How,
		"stations",
		f.Stations,
		"look_t",
		string.format("%.1f", f.MadeAt),
		"caused",
		caused,
		"woke",
		woke > 0 and table.concat(woken, ",") or nil
	)
end

--- Delivers one fix (X, Z, ErrM, Class, Stations, How, MadeAt) now; the service calls it when the fix is due.
EsmSvc.deliverFix = deliver

local function deliverDue(ctx, state)
	if state.pendingCount == 0 then
		return
	end
	local pending = state.pending
	for i = 1, #pending do
		local f = pending[i]
		if f.DueAt and ctx.now >= f.DueAt then
			f.DueAt = nil
			state.pendingCount = state.pendingCount - 1
			deliver(ctx, state, f)
		end
	end
end

--- Fire-control radars heard on READINESS_LOOKS looks within READINESS_WINDOW_SEC: hostile evidence.
local function fcrHeard(ctx, state)
	local looks = state.fcrLooks
	looks[#looks + 1] = ctx.now
	while #looks > E.READINESS_LOOKS do
		table.remove(looks, 1)
	end
	if #looks >= E.READINESS_LOOKS and ctx.now - looks[1] <= E.READINESS_WINDOW_SEC then
		readinessEvidence(ctx, "radar_heard")
	end
end

local function swapTentative(state)
	state.tentPrev, state.tentNext = state.tentNext, state.tentPrev
	state.tentPrevCount, state.tentNextCount = state.tentNextCount, 0
end

local function startResolve(ctx, state)
	for i = 1, state.bearingCount do
		if state.bearings[i].Class == "FCR" then
			fcrHeard(ctx, state)
			break
		end
	end
	state.tentNextCount = 0
	resolveBegin(state)
end

local function finishLook(ctx, state, fixes, ambiguous)
	local now = ctx.now
	swapTentative(state)
	if ambiguous == 0 then
		return
	end
	state.stats.ambiguous = state.stats.ambiguous + ambiguous
	for k = 1, #CLASSES do
		local class = CLASSES[k]
		local count = state.ambiguousCounts[class]
		if count > 0 and not resting(state.ambiguousRest, class, now, E.AMBIGUOUS_REST_SEC) then
			state.ambiguousRest[class] = now
			local crossings = state.crossingCounts[class]
			logger:info(
				string.format(
					"esm ambiguous: %d %s bearings cross %d ways (%d fixes this look)",
					count,
					CLASS_WORD[class],
					crossings,
					fixes
				)
			)
			Debrief.emit(
				ctx.networkId,
				now,
				"ESM_AMBIGUOUS",
				"class",
				class,
				"bearings",
				count,
				"crossings",
				crossings,
				"fixes",
				fixes
			)
		end
	end
end

local function summary(ctx, state)
	local now = ctx.now
	if not state.summaryAt then
		state.summaryAt = now
		return
	end
	if now - state.summaryAt < E.SUMMARY_SEC and now >= state.summaryAt then
		return
	end
	state.summaryAt = now
	local s = state.stats
	logger:info(
		string.format(
			"esm summary: %d stations, %d looks, %d radars heard of, %d in range, %d sight checks, %d bearings, "
				.. "%d saturated, %d fixes, %d ambiguous, %d cued, %d rested, %d dropped, %.1f ms total, "
				.. "%.2f ms worst tick",
			state.stationCount,
			s.cycles,
			s.emitters,
			s.pairs,
			s.los,
			s.bearings,
			s.saturated,
			s.fixes,
			s.ambiguous,
			s.cued,
			s.rested,
			s.dropped,
			s.cpu * 1000,
			s.cpuMax * 1000
		)
	)
end

local satByName = {}

local function step(ctx, state, cfg)
	local now = ctx.now
	if state.phase == IDLE then
		if state.cycleAt and now >= state.cycleAt and now - state.cycleAt < cfg.LookIntervalSec then
			return 0
		end
		state.cycleAt = now
		state.stats.cycles = state.stats.cycles + 1
		state.bearingCount = 0
		state.cursor, state.emCursor = 1, 1
		for i = 1, state.stationCount do
			startStationLook(state.stations[i])
		end
		if state.emitterSource then
			state.emitterCount = state.emitterSource(state, ctx.coalitionId)
		else
			state.emitterCount = EsmSvc.readEmitters(state, ctx.coalitionId, cfg)
		end
		state.stats.emitters = state.stats.emitters + state.emitterCount
		if state.emitterCount > 0 then
			state.phase = LISTEN
		else
			-- nothing radiating: a two-station fix of the last look is not repeated
			state.tentNextCount = 0
			swapTentative(state)
		end
		return 1
	elseif state.phase == LISTEN then
		local s = state.stations[state.cursor]
		local to = min(state.emitterCount, state.emCursor + E.LISTEN_PER_TICK - 1)
		listen(ctx, state, s, cfg, state.emCursor, to)
		state.emCursor = to + 1
		if state.emCursor > state.emitterCount then
			state.cursor, state.emCursor = state.cursor + 1, 1
		end
		if state.cursor > state.stationCount then
			for name in pairs(satByName) do
				satByName[name] = nil
			end
			for i = 1, state.stationCount do
				local st = state.stations[i]
				satByName[st.Name] = st.Sat
			end
			beginMatch(state, max(cfg.MaxRangeKm, cfg.AewMaxRangeKm) * 1000, satByName)
			state.phase, state.resolving = ASSOCIATE, false
		end
		return 1
	end
	if not state.resolving then
		if matchStep(state, E.MATCH_WORK_PER_TICK) then
			state.resolving, state.rstage = true, 1
		end
		return 1
	end
	state.fixCtx = ctx
	if not state.fixFn then
		state.fixFn = function(x, z, errM, class, stations, n, how)
			onFix(state.fixCtx, state, x, z, errM, class, stations, n, how)
		end
	end
	if state.rstage == 1 then
		startResolve(ctx, state)
		state.rstage = 2
	elseif state.rstage == 2 then
		if resolveAccept(state, state.fixFn, E.RESOLVE_PER_TICK) then
			state.rstage = 3
		end
	else
		local fixes, ambiguous = resolveFinish(state, state.fixFn)
		state.phase, state.resolving, state.rstage = IDLE, false, 0
		finishLook(ctx, state, fixes, ambiguous)
	end
	state.fixCtx = nil
	return 1
end

--- Forgets the look in progress and the fixes waiting (the doctrine turned listening off).
function EsmSvc.stop(state)
	if state.phase == IDLE and state.pendingCount == 0 then
		return
	end
	state.phase, state.resolving, state.rstage, state.cycleAt = IDLE, false, 0, nil
	state.bearingCount, state.tentPrevCount, state.tentNextCount = 0, 0, 0
	for i = 1, #state.pending do
		state.pending[i].DueAt = nil
	end
	state.pendingCount = 0
end

--- Every tick: delivers fixes due, and does one step of the look (snapshot, part of a station's listening, part of
--- the matching, or resolving). Returns 1 when it did a step, else 0.
function EsmSvc.tick(ctx)
	local doctrine = ctx.doctrine
	local state = ctx.esm
	if not doctrine or doctrine.PassiveDetection == false then
		if state then
			EsmSvc.stop(state)
		end
		return 0
	end
	local now = ctx.now
	local hpt = Medusa.hpTimer
	local t0 = hpt and hpt() or 0
	deliverDue(ctx, state)
	local did = 0
	if
		state.phase == IDLE
		and (not state.rosterTime or now - state.rosterTime >= E.ROSTER_REFRESH_SEC or now < state.rosterTime)
	then
		rebuildStations(ctx, state)
	end
	if state.stationCount > 0 or state.phase ~= IDLE then
		did = step(ctx, state, settings(doctrine))
	end
	if hpt then
		local dt = hpt() - t0
		state.stats.cpu = state.stats.cpu + dt
		if dt > state.stats.cpuMax then
			state.stats.cpuMax = dt
		end
	end
	if state.stationCount > 0 then
		summary(ctx, state)
	end
	return did
end
