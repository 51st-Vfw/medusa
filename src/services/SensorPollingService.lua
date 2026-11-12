require("_header")
require("services.Services")
require("services.BlackBoxService")
require("core.Constants")
require("core.Chance")
require("core.Logger")

--[[
            ███████╗███████╗███╗   ██╗███████╗ ██████╗ ██████╗     ██████╗  ██████╗ ██╗     ██╗     ██╗███╗   ██╗ ██████╗
            ██╔════╝██╔════╝████╗  ██║██╔════╝██╔═══██╗██╔══██╗    ██╔══██╗██╔═══██╗██║     ██║     ██║████╗  ██║██╔════╝
            ███████╗█████╗  ██╔██╗ ██║███████╗██║   ██║██████╔╝    ██████╔╝██║   ██║██║     ██║     ██║██╔██╗ ██║██║  ███╗
            ╚════██║██╔══╝  ██║╚██╗██║╚════██║██║   ██║██╔══██╗    ██╔═══╝ ██║   ██║██║     ██║     ██║██║╚██╗██║██║   ██║
            ███████║███████╗██║ ╚████║███████║╚██████╔╝██║  ██║    ██║     ╚██████╔╝███████╗███████╗██║██║ ╚████║╚██████╔╝
            ╚══════╝╚══════╝╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝    ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝

    What this service does
    - Calls the DCS detection API on each sensor to get current contacts.
    - Converts raw detections into track reports with position, velocity, and coalition data.
    - Rate-limits per-track scans and cleans up stale scan entries based on doctrine settings.

    - Adds contact evidence a crew could have (when given the polling group's sensor context): one noisy look at the
      return size (`SizeDb`, `SizeVarDb`) and, at sight range, what the contact is (`SeenAs`). `_buildReport` is the
      only code that reads DCS truth beyond position and velocity (the object's descriptor RCS and category, and
      DCS's "type known" flag); everything downstream sees only these noisy, crew-plausible fields.

    How others use it
    - IadsNetwork calls pollSensor in a round-robin budget each tick to feed reports into TrackManager.
--]]

Medusa.Services.SensorPollingService = {}

--- @param doctrine table Network doctrine
--- @param opts table|nil { random = function() -> [0,1) } (injectable for tests; default math.random)
function Medusa.Services.SensorPollingService:new(doctrine, opts)
	local o = {
		_logger = Medusa.Logger:ns("SensorPollingService"),
		_lastScanned = {},
		_lastCleanup = 0,
		_doctrine = doctrine,
		_random = (opts and opts.random) or math.random,
		-- Per contact, from its descriptor on first sight (dropped with its _lastScanned entry):
		_sizeDb = {}, -- truth RCS in dBsm plus the fixed shape offset, or false (no RCS)
		_errScale = {}, -- measurement variance (dB^2) at the radar's reach; scales with (range / reach)^4
		_class = {}, -- coarse class (Medusa.Constants.SeenAs) or false
		_sightSq = 0, -- squared sight recognition range, set per poll (sightRange)
	}
	setmetatable(o, { __index = self })
	return o
end

local CE = Medusa.Constants.ContactEvidence
local SEEN = Medusa.Constants.SeenAs
local TWO_PI = 2 * math.pi
local LN10_DB = 10 / math.log(10)
local FLICKER_VAR = CE.FLICKER_DB * CE.FLICKER_DB
local MEAS_VAR_MAX = CE.MEASUREMENT_ERROR_MAX_DB * CE.MEASUREMENT_ERROR_MAX_DB
local ASPECT_BEAM, ASPECT_TAIL = CE.ASPECT_BEAM_DB, CE.ASPECT_TAIL_DB

--- Generic aspect gain (dB) for c = cos(angle between the target's velocity and its line of sight to the radar):
--- 0 nose-on (c = 1), ASPECT_BEAM_DB beam-on (c = 0), ASPECT_TAIL_DB tail-on (c = -1); smooth, no trig.
function Medusa.Services.SensorPollingService.aspectDb(c)
	local c2 = c * c
	return ASPECT_BEAM * (1 - c2) + 0.5 * ASPECT_TAIL * c2 * (1 - c)
end
local aspectDb = Medusa.Services.SensorPollingService.aspectDb

--- Fixed per-object shape offset in dB, uniform in +/- SHAPE_OFFSET_DB, hashed from the DCS object id (exact in
--- doubles for ids below 2^37).
function Medusa.Services.SensorPollingService.shapeOffsetDb(id)
	local h = ((tonumber(id) or 0) * 40503) % 65536
	return CE.SHAPE_OFFSET_DB * (2 * h / 65536 - 1)
end
local shapeOffsetDb = Medusa.Services.SensorPollingService.shapeOffsetDb

--- Read the contact's descriptor once: its RCS (an omniscient value standing in for the echo a real radar measures,
--- as CONTRIBUTING allows when DCS offers no measured return) and its coarse class (what a crew sees at sight range).
function Medusa.Services.SensorPollingService:_cacheTraits(networkId, obj, objectCategory)
	local ok, desc = pcall(obj.getDesc, obj)
	if not ok or type(desc) ~= "table" then
		desc = {}
	end
	local rcs = desc.RCS
	if type(rcs) == "number" and rcs > 0 then
		self._sizeDb[networkId] = LN10_DB * math.log(rcs) + shapeOffsetDb(networkId)
		local amp = CE.AMPLITUDE_ERROR_DB
		self._errScale[networkId] = amp * amp * CE.RCS_REF_M2 / (CE.SNR_AT_REACH * rcs)
	else
		self._sizeDb[networkId] = false
		self._errScale[networkId] = false
	end
	local cls = false
	if objectCategory == Object.Category.WEAPON then
		cls = SEEN.MUNITION
	elseif desc.category == Unit.Category.AIRPLANE then
		cls = SEEN.AIRCRAFT
	elseif desc.category == Unit.Category.HELICOPTER then
		cls = SEEN.HELICOPTER
	end
	self._class[networkId] = cls
end

--- Add the contact evidence to a report: one look at the return size and, at sight range, the coarse class.
--- @param report table The report being built (fields are added in place)
--- @param entry table DCS detection record
--- @param ctx table { Position, Reach (m, 5 m2 detection range), Kind (STEP_DB key) }
function Medusa.Services.SensorPollingService:_observe(report, entry, ctx, pos, vel)
	local id = report.NetworkId
	local sp = ctx.Position
	if not sp then
		return
	end
	local lx, ly, lz = sp.x - pos.x, sp.y - pos.y, sp.z - pos.z
	local rangeSq = lx * lx + ly * ly + lz * lz

	local cls = self._class[id]
	if cls and entry.type == true and rangeSq <= self._sightSq then
		report.SeenAs = cls
	end

	local base = self._sizeDb[id]
	local reach = ctx.Reach
	if not base or not reach or reach <= 0 then
		return
	end
	local vSq = vel.x * vel.x + vel.y * vel.y + vel.z * vel.z
	local c = 0
	if vSq > 1 and rangeSq > 1 then
		c = (vel.x * lx + vel.y * ly + vel.z * lz) / math.sqrt(vSq * rangeSq)
	end
	local rr = rangeSq / (reach * reach)
	local measVar = self._errScale[id] * rr * rr
	if measVar > MEAS_VAR_MAX then
		measVar = MEAS_VAR_MAX
	end
	local var = FLICKER_VAR + measVar
	-- Flicker and measurement error are independent Gaussians: one Box-Muller draw (two uniforms) covers both; none
	-- in training mode.
	local g = Medusa.Chance.gauss(Medusa.Chance.isTraining(self._doctrine), self._random)
	local look = base + aspectDb(c) + g * math.sqrt(var)
	local step = CE.STEP_DB[ctx.Kind] or CE.STEP_DB.EWR
	report.SizeDb = step * math.floor(look / step + 0.5)
	report.SizeVarDb = var + step * step / 12
end

--- Track refresh interval for one kind of radar (EWR, SAM_SEARCH, SAM_TRACK). A doctrine built by Doctrine.new
--- carries the rates resolved at load (`ScanRates`); otherwise: the doctrine's ScanUpdateRateSec entry when it is a
--- number, else the default, clamped to SCAN_UPDATE_RATE_MIN_SEC..MAX_SEC.
--- @param doctrine table|nil Network doctrine
--- @param kind string Key of Medusa.Constants.SCAN_UPDATE_RATE_DEFAULTS
--- @return number seconds
function Medusa.Services.SensorPollingService.scanRateFor(doctrine, kind)
	local resolved = doctrine and doctrine.ScanRates
	if resolved and resolved[kind] then
		return resolved[kind]
	end
	local C = Medusa.Constants
	local overrides = doctrine and doctrine.ScanUpdateRateSec
	local value = type(overrides) == "table" and overrides[kind]
	if type(value) ~= "number" then
		value = C.SCAN_UPDATE_RATE_DEFAULTS[kind]
	end
	return math.max(C.SCAN_UPDATE_RATE_MIN_SEC, math.min(C.SCAN_UPDATE_RATE_MAX_SEC, value))
end

function Medusa.Services.SensorPollingService:_buildReport(entry, now, sourceType, scanRateSec, sensorCtx)
	local obj = entry.object
	if not obj then
		return nil
	end

	local networkId = obj.id_
	if not networkId then
		return nil
	end

	if
		self._lastScanned[networkId]
		and (now - self._lastScanned[networkId]) < (scanRateSec or self._doctrine.PerTrackScanUpdateRate)
	then
		return nil
	end

	local okCat, cat = pcall(obj.getCategory, obj)
	if not okCat or (cat ~= Object.Category.UNIT and cat ~= Object.Category.WEAPON) then
		return nil
	end

	Medusa.Services.BlackBoxService.cacheFromObject(networkId, obj)

	local okPos, pos = pcall(obj.getPoint, obj)
	if not okPos or not pos then
		return nil
	end

	local okVel, vel = pcall(obj.getVelocity, obj)
	if not okVel or not vel then
		return nil
	end

	self._lastScanned[networkId] = now
	local report = {
		NetworkId = networkId,
		SourceType = sourceType,
		Position = { x = pos.x, y = pos.y, z = pos.z },
		Velocity = { x = vel.x, y = vel.y, z = vel.z },
		-- Contact evidence (set by _observe). Listed so the constructor sizes the table once: adding them later
		-- would regrow it on every report.
		SizeDb = nil,
		SizeVarDb = nil,
		SeenAs = nil,
	}
	if sensorCtx then
		if self._sizeDb[networkId] == nil then
			self:_cacheTraits(networkId, obj, cat)
		end
		self:_observe(report, entry, sensorCtx, pos, vel)
	end
	return report
end

--- @param sensorCtx table|nil The polling group's sensor context (see _observe); nil reports no contact evidence
--- @param detectionType number|nil Controller.Detection channel to read (a local cueing radar: RADAR only); nil all
function Medusa.Services.SensorPollingService:pollSensor(
	groupName,
	now,
	sourceType,
	scanRateSec,
	sensorCtx,
	detectionType
)
	sourceType = sourceType or Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
	if now - self._lastCleanup > self._doctrine.SensorCleanupSec then
		for id, ts in pairs(self._lastScanned) do
			if now - ts > self._doctrine.SensorCleanupSec then
				self._lastScanned[id] = nil
				self._sizeDb[id] = nil
				self._errScale[id] = nil
				self._class[id] = nil
			end
		end
		self._lastCleanup = now
	end

	local controller = GetGroupController(groupName)
	if not controller then
		return nil
	end
	-- Sight recognition range now (night, weather), the same scaling as observer sight.
	local sight = Medusa.Services.SensorPollingService.sightRange(CE.SIGHT_RECOGNITION_RANGE_M, now)
	self._sightSq = sight * sight

	local detections = GetControllerDetectedTargets(controller, detectionType)
	if not detections then
		return {}
	end

	local reports = {}
	for i = 1, #detections do
		local report = self:_buildReport(detections[i], now, sourceType, scanRateSec, sensorCtx)
		if report then
			reports[#reports + 1] = report
		end
	end

	return reports
end

--[[
    Observer looks (HUMINT). The one place that reads DCS truth for what a ground crew sees or hears: a budgeted
    sphere search for aircraft in flight around the observer, terrain line of sight from eye height for sight, a range
    and height check for hearing, and DCS's "type known" flag from the observer group's own detections. It returns
    only what a crew would radio: a noisy, rounded position, an 8-point heading, a height band, fast or slow, jet or
    helicopter, how many ("one", "two", "several"), whether it is hostile (only when seen within recognition range;
    otherwise "unidentified", own aircraft included) and a type only when also DCS says the group knows it.
--]]

local OBS = Medusa.Constants.Observer
local SIGHT = Medusa.Constants.Sight
local AIR_CATEGORY = { [Unit.Category.AIRPLANE] = "jet", [Unit.Category.HELICOPTER] = "helicopter" }
local HEADING_8 = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

-- Sight from the ground (Medusa.Constants.Sight): the light, read every LIGHT_REFRESH_SEC, and the mission's
-- weather (visibility, fog keys, dust), read once.
local sightState = { lightAt = nil, light = 1, weather = nil }

local function readWeather()
	local out = { visibility = math.huge, fog = nil, dust = nil }
	local mission = env and env.mission
	local weather = type(mission) == "table" and mission.weather or nil
	if type(weather) ~= "table" then
		return out
	end
	local vis = type(weather.visibility) == "table" and tonumber(weather.visibility.distance) or nil
	if vis and vis > 0 then
		out.visibility = vis
	end
	-- Fog: fog2 when present (manual keys: seconds after start, visibility); the old fields only before mission
	-- version 23.
	local fog2 = weather.fog2
	if type(fog2) == "table" then
		if fog2.mode == 4 and type(fog2.manual) == "table" and #fog2.manual > 0 then
			out.fog = fog2.manual
		end
	elseif weather.enable_fog == true and type(weather.fog) == "table" and (tonumber(mission.version) or 0) < 23 then
		local v = tonumber(weather.fog.visibility)
		if v and v > 0 then
			out.fog = { { time = 0, visibility = v } }
		end
	end
	local dust = weather.enable_dust == true and tonumber(weather.dust_density) or nil
	if dust and dust > 0 then
		out.dust = dust
	end
	return out
end

local function weatherLimit(now)
	local w = sightState.weather
	if not w then
		w = readWeather()
		sightState.weather = w
	end
	local limit = w.visibility
	if w.dust and w.dust < limit then
		limit = w.dust
	end
	local fog = w.fog
	if fog then
		local v = nil
		for i = 1, #fog do
			local key = fog[i]
			if type(key) == "table" and (v == nil or (tonumber(key.time) or 0) <= now) then
				v = tonumber(key.visibility)
			end
		end
		if v and v > 0 and v < limit then
			limit = v
		end
	end
	return limit
end

local function lightFactor(now)
	local at = sightState.lightAt
	if at == nil or now < at or now - at >= SIGHT.LIGHT_REFRESH_SEC then
		sightState.lightAt = now
		sightState.light = (IsNightTime and IsNightTime() == true) and SIGHT.NIGHT_FACTOR or 1
	end
	return sightState.light
end

--- How far a ground crew sees at `now` what it would see `dayRangeM` away in daylight and clear air: scaled at night,
--- capped by the mission's visibility, fog and dust.
function Medusa.Services.SensorPollingService.sightRange(dayRangeM, now)
	local range = dayRangeM * lightFactor(now)
	local limit = weatherLimit(now)
	return range < limit and range or limit
end
local sightRange = Medusa.Services.SensorPollingService.sightRange

--- Forget the light and weather read (tests; a new mission).
function Medusa.Services.SensorPollingService._resetSight()
	sightState.lightAt, sightState.light, sightState.weather = nil, 1, nil
end

local obsEye = { x = 0, y = 0, z = 0 }
local obsTarget = { x = 0, y = 0, z = 0 }
local candUnit, candKind, candOwn, candX, candY, candZ = {}, {}, {}, {}, {}, {}
local candCount, candVisited = 0, 0
local candCoalition = nil

-- world.searchObjects cannot be limited to aircraft: ground units cost one protected category check, and the search
-- stops after MAX_VISITED objects or MAX_CANDIDATES aircraft in flight.
local function collectCandidate(obj)
	candVisited = candVisited + 1
	if candVisited > OBS.MAX_VISITED then
		return false
	end
	local okCat, category = pcall(obj.getCategoryEx, obj)
	local kind = okCat and AIR_CATEGORY[category]
	if not kind then
		return true
	end
	local okSide, coalitionId = pcall(obj.getCoalition, obj)
	if not okSide or not coalitionId or coalitionId == 0 then
		return true
	end
	local okAir, airborne = pcall(obj.inAir, obj)
	if not okAir or airborne ~= true then
		return true
	end
	local okActive, active = pcall(obj.isActive, obj)
	if not okActive or active ~= true then
		return true
	end
	local pos = GetUnitPosition(obj)
	if not pos then
		return true
	end
	candCount = candCount + 1
	candUnit[candCount], candKind[candCount], candOwn[candCount] = obj, kind, coalitionId == candCoalition
	candX[candCount], candY[candCount], candZ[candCount] = pos.x, pos.y, pos.z
	return candCount < OBS.MAX_CANDIDATES
end

local function roundTo(value, step)
	return math.floor(value / step + 0.5) * step
end

--- True when the observer group's own detections carry DCS's "type known" flag for `unit`.
local function typeKnown(groupName, unit)
	local controller = groupName and GetGroupController(groupName)
	local targets = controller and GetControllerDetectedTargets(controller)
	if not targets then
		return false
	end
	local id = unit.id_
	for i = 1, #targets do
		local t = targets[i]
		if t.type == true and t.object and t.object.id_ == id then
			return true
		end
	end
	return false
end

local function clearCandidates()
	for i = 1, candCount do
		candUnit[i] = nil
	end
end

local COUNT_WORD = { "one", "two" }

--- One look by a ground crew. `look`: { Position (the crew's ground position), CoalitionId, GroupName, Now (optional,
--- mission time), Random (optional, [0,1)), Training (optional: the position error is half its bound per axis, signs
--- from Seed, a whole number, or the group name's hash), ErrorScale (optional, position error factor for the crew's
--- skill, default 1) }. Fills `out` (reused): Position {x, y, z} (noisy, rounded), ErrorM, Heading8 (nil when only
--- heard), Height ("low" | "medium" | "high"), Speed ("fast" | "slow"), Kind ("jet" |
--- "helicopter"), Identity ("hostile" | "unidentified"), TypeName (nil unless identified and DCS flags the type
--- known), Count ("one" | "two" | "several"), Heard (true when nothing was seen), Night. Returns false when the crew
--- saw and heard nothing it would report (own aircraft it recognised are not reported).
function Medusa.Services.SensorPollingService.observeAirspace(look, out)
	local p = look.Position
	if not p then
		return false
	end
	local now = look.Now or GetTime()
	local sight = sightRange(OBS.VISUAL_RANGE_DAY_M, now)
	local night = sightState.light < 1
	local radius = sight > OBS.HEARING_RANGE_M and sight or OBS.HEARING_RANGE_M
	local volume = CreateSphereVolume(p, radius)
	if not volume then
		return false
	end
	candCount, candVisited, candCoalition = 0, 0, look.CoalitionId
	SearchWorldObjects(Object.Category.UNIT, volume, collectCandidate)
	if candCount == 0 then
		return false
	end

	obsEye.x, obsEye.y, obsEye.z = p.x, p.y + OBS.EYE_HEIGHT_M, p.z
	local recognition = sight * SIGHT.RECOGNITION_RATIO
	local sightSq, hearSq = sight * sight, OBS.HEARING_RANGE_M * OBS.HEARING_RANGE_M
	local recognitionSq = recognition * recognition
	local sightChecks, count = 0, 0
	local best, bestSeen, bestSq = nil, false, nil
	for i = 1, candCount do
		local dx, dy, dz = candX[i] - p.x, candY[i] - p.y, candZ[i] - p.z
		local dSq = dx * dx + dy * dy + dz * dz
		local seen = false
		if dSq <= sightSq and sightChecks < OBS.MAX_SIGHT_CHECKS then
			sightChecks = sightChecks + 1
			obsTarget.x, obsTarget.y, obsTarget.z = candX[i], candY[i], candZ[i]
			seen = HasLOS(obsEye, obsTarget) == true
		end
		local heard = dSq <= hearSq and dy <= OBS.HEARING_MAX_HEIGHT_M
		-- An own aircraft seen close enough to recognise is not reported; anything else could be anyone's.
		if (seen or heard) and not (candOwn[i] and seen and dSq <= recognitionSq) then
			count = count + 1
			if not best or (seen and not bestSeen) or (seen == bestSeen and dSq < bestSq) then
				best, bestSeen, bestSq = i, seen, dSq
			end
		end
	end
	if not best then
		clearCandidates()
		return false
	end

	local unit = candUnit[best]
	clearCandidates()
	local random = look.Random or math.random
	local training = look.Training == true
	local errorM = (bestSeen and OBS.POSITION_ERROR_SEEN_M or OBS.POSITION_ERROR_HEARD_M) * (look.ErrorScale or 1)
	local position = out.Position
	if not position then
		position = {}
		out.Position = position
	end
	-- In training the error is its expected size in a fixed direction (the seed's bits), not zero.
	local seed = training and (look.Seed or Medusa.Chance.hash(look.GroupName or "")) or nil
	position.x = roundTo(candX[best] + Medusa.Chance.symmetric(training, errorM, random, seed), OBS.POSITION_ROUND_M)
	position.y = p.y
	position.z = roundTo(
		candZ[best] + Medusa.Chance.symmetric(training, errorM, random, seed and math.floor(seed / 2)),
		OBS.POSITION_ROUND_M
	)
	out.ErrorM = errorM
	local height = candY[best] - p.y
	out.Height = height <= OBS.LOW_MAX_M and "low" or (height >= OBS.HIGH_MIN_M and "high" or "medium")
	out.Kind = candKind[best]
	out.Speed, out.Heading8 = "slow", nil
	local v = GetUnitVelocity(unit)
	if v then
		local speedSq = v.x * v.x + v.z * v.z
		out.Speed = speedSq >= OBS.FAST_MIN_MPS * OBS.FAST_MIN_MPS and "fast" or "slow"
		if bestSeen and speedSq > 1 then
			-- DCS x is north, z is east.
			local bearing = math.atan2(v.z, v.x)
			if bearing < 0 then
				bearing = bearing + TWO_PI
			end
			out.Heading8 = HEADING_8[math.floor(bearing / (TWO_PI / 8) + 0.5) % 8 + 1]
		end
	end
	local identified = bestSeen and bestSq <= recognitionSq
	out.Identity = identified and "hostile" or "unidentified"
	out.TypeName = nil
	if identified and typeKnown(look.GroupName, unit) then
		local ok, name = pcall(unit.getName, unit)
		out.TypeName = ok and name and GetUnitType(name) or nil
	end
	out.Count = COUNT_WORD[count] or "several"
	out.Heard = not bestSeen
	out.Night = night
	return true
end

--- Ground position of an observer post: its first living unit's position (nil when none lives).
function Medusa.Services.SensorPollingService.observerPosition(unitNames)
	for i = 1, #(unitNames or {}) do
		local pos = GetUnitPosition(unitNames[i])
		if pos then
			return pos
		end
	end
	return nil
end
