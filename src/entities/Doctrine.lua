require("_header")
require("entities.Entities")
require("core.Constants")

--[[
            ██████╗  ██████╗  ██████╗████████╗██████╗ ██╗███╗   ██╗███████╗
            ██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝██╔══██╗██║████╗  ██║██╔════╝
            ██║  ██║██║   ██║██║        ██║   ██████╔╝██║██╔██╗ ██║█████╗
            ██║  ██║██║   ██║██║        ██║   ██╔══██╗██║██║╚██╗██║██╔══╝
            ██████╔╝╚██████╔╝╚██████╗   ██║   ██║  ██║██║██║ ╚████║███████╗
            ╚═════╝  ╚═════╝  ╚═════╝   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝

    What this entity does
    - Defines a doctrine configuration table with defaults for every tactical setting.
    - Validates enum, boolean and number fields (a wrong value is an error and takes the default), clamps numeric
      fields, fills missing values from defaults, and reports each top-level key it does not know (a misspelled field
      would otherwise silently take its default).

    How others use it
    - Config:getDoctrine merges mission-maker overrides with this template to produce the active doctrine.
    - IadsNetwork, TargetAssigner, EmconService, and HarmResponseService read doctrine fields each tick.
--]]

Medusa.Entities.Doctrine = {}

local DOCTRINE_SCHEMA = {
	-- Enum fields
	{ name = "ROE", type = "enum", default = "TIGHT", enum = "ROEState" },
	{ name = "HARMResponse", type = "enum", default = "AUTO_DEFENSE", enum = "HarmResponseStrategy" },
	{
		name = "EngageTactics",
		type = "enum",
		default = "SHOOT_IN_DEPTH",
		enum = "CoordinatedEngagementTactics",
	},
	{ name = "Posture", type = "enum", default = "HOT_WAR", enum = "Posture" },
	-- Starting readiness (SURPRISED / ALERTED / ENGAGED); rises during the mission. Unset: from Posture.
	{ name = "Readiness", type = "enum", enum = "Readiness" },
	-- Report skill (crew factors) of a crew whose skill the mission file does not give (spawned during the mission,
	-- or set to Random or Player). Unset: CrewSuppression.DefaultCrewSkill, which sets their suppression resistance.
	{
		name = "CrewFactorsDefaultSkill",
		type = "enum",
		enum = "CrewSkill",
		defaultText = "CrewSuppression.DefaultCrewSkill",
	},
	{ name = "ShootScoot", type = "enum", default = "NONE", enum = "ShootAndScootPolicy" },
	{ name = "SAMAsEWR", type = "enum", default = "WHEN_NO_EWR", enum = "SAMAsEWRPolicy" },
	{
		name = "DegradedMode",
		type = "enum",
		default = "REVERT_TO_AUTONOMOUS",
		enum = "NetworkDegradationPolicy",
	},
	{
		name = "LaunchAuthority",
		type = "enum",
		default = "LOCAL_AUTONOMY",
		enum = "InterceptorLaunchAuthorityPolicy",
	},
	{ name = "GCIPolicy", type = "enum", default = "CLOSEST_AIRBASE", enum = "GciServicePolicy" },
	-- Clamped numbers
	{ name = "PkFloor", type = "number", default = 0.25, min = 0, max = 1 },
	{ name = "DefendPk", type = "number", default = 0.30, min = 0, max = 1 },
	{ name = "TargetKillRate", type = "number", default = 0.50, min = 0, max = 1 },
	{ name = "HoldDownSec", type = "number", default = 15, min = 0, max = 300 },
	{ name = "EngageTimeoutSec", type = "number", default = 45, min = 0, max = 300 },
	{ name = "LookaheadSec", type = "number", default = 8, min = 0, max = 30 },
	{ name = "ADIZBufferNm", type = "number", default = 12, min = 0, max = 200 },
	{ name = "C2DelaySec", type = "number", default = 2, min = 0, max = 60 },
	{ name = "ThreatSpeedScaling", type = "number", default = 30, min = 0, max = 100 },
	{ name = "PerTrackScanUpdateRate", type = "number", default = 5, min = 1, max = 60 },
	{ name = "SensorCleanupSec", type = "number", default = 30, min = 5, max = 300 },
	{ name = "BallisticSimStepSec", type = "number", default = 1.0, min = 0.1, max = 5 },
	{ name = "BallisticSimMaxSec", type = "number", default = 120, min = 10, max = 600 },
	-- Optional clamped numbers (nil if not set)
	{ name = "ScanSec", type = "number_opt", min = 0, max = 86400 },
	{ name = "QuietPeriodSec", type = "number_opt", min = 0, max = 86400 },
	{ name = "HARMShutdownM", type = "number_opt", min = 0, max = 300000 },
	{ name = "PoolDefensePointsRadius", type = "number_opt", min = 1000, max = 100000 },
	-- Unclamped numbers with defaults
	{ name = "EmconRotateGroups", type = "number", default = 2 },
	{ name = "FlightSize", type = "number", default = 1 },
	{ name = "MaxTargets", type = "number", default = 1 },
	{ name = "StickyRangePct", type = "number", default = 15 },
	{ name = "SkillFactor", type = "number", default = 0.1 },
	-- Optional unclamped numbers (nil if not set)
	{ name = "GCIRangeKm", type = "number_opt" },
	{ name = "RelocateMinM", type = "number_opt" },
	{ name = "RelocateMaxM", type = "number_opt" },
	-- Booleans (default true)
	{ name = "GuiltByAssociation", type = "boolean", default = true },
	{ name = "ADIZEnabled", type = "boolean", default = true },
	{ name = "AutoDiscoverEwrs", type = "boolean", default = true },
	{ name = "BatteryTargetDatalink", type = "boolean", default = true },
	{ name = "RollingPkEnabled", type = "boolean", default = true },
	{ name = "HARMSaturateOnAmmo", type = "boolean", default = false },
	{ name = "PoolDefensePoints", type = "boolean", default = false },
	-- Decoy assessment: judge unpowered decoys from how they fly; off = no decoy labels at all.
	{ name = "DecoyAssessment", type = "boolean", default = true },
	-- Long/medium-range batteries turn engage-air-weapons off while only probable decoys and known aircraft are
	-- in reach; off = Medusa leaves engage-air-weapons as the mission set it.
	{ name = "ManageEngageAirWeapons", type = "boolean", default = true },
	-- A HOT long/medium-range battery holds fire after one shot at a lone suspect decoy group until the missile's
	-- flight ends (reconnaissance by fire); off = no test-shot holds.
	{ name = "DecoyTestShots", type = "boolean", default = true },
	-- A HOT long/medium-range battery whose own fire-control radar locks a probable decoy, or that fires at one,
	-- turns engage-air-weapons off for a while (aircraft are still engaged); needs ManageEngageAirWeapons. Off = no
	-- fire holds.
	{ name = "DecoyFireDiscipline", type = "boolean", default = true },
	-- A dropped track is re-acquired by a new contact that is where it should be and flies as it should, whatever DCS
	-- object it is, carrying labels as the fit allows; off = only the same DCS object near its old position (stock).
	{ name = "EvidenceReacquisition", type = "boolean", default = true },
	-- A launcher-less search radar with a short reach (Dog Ear-style) is a local cueing radar: dark unless a threat is
	-- near the units it supports, cueing MANPAD and AAA crews when up; a group of such a radar with guns is an AAA
	-- battery. Off = groups are classified as in stock Medusa: a radar-only group is an early-warning radar that
	-- follows the EWR EMCON policy (on by default), and a radar with guns goes by unit count.
	{ name = "LocalCueingRadars", type = "boolean", default = true },
	-- A dark group whose own crew sees or hears a threat brings its radar up WARM (radar on, weapons hold) on its own;
	-- not under ROE HOLD, HARM shutdown or crew suppression. Off = only the network wakes it.
	{ name = "LocalInitiative", type = "boolean", default = true },
	-- Crews of managed ground groups (and observer-named groups) radio coarse reports of aircraft they see or hear.
	-- Off = no observer looks and no reports.
	{ name = "ObserverReports", type = "boolean", default = true },
	-- A local cueing radar that no other ground radar of the network covers sweeps briefly every few minutes (random
	-- times) instead of staying blind until a crew reports. Off = it comes up only for a reason (threat near, alerted
	-- crew, report).
	{ name = "LocalRadarSweeps", type = "boolean", default = true },
	-- Crew skill, readiness and net load shape observer reports (made at all, delay, precision, delivery) and how
	-- often a surprised network's crews look. Off = reports and looks ignore skill, readiness and load.
	{ name = "CrewFactors", type = "boolean", default = true },
	-- Training: the sensing, identification and report chain is deterministic and luck never favors the attacker
	-- (ranges at their midpoint or a fixed per-object point, no return-size noise, report position errors at their
	-- typical size in a fixed direction, no report unmade or lost). DCS's own randomness stays.
	{ name = "TrainingMode", type = "boolean", default = false },
	-- Tables (pass through)
	{ name = "EMCON", type = "table" },
	{ name = "ScanUpdateRateSec", type = "table" },
	{ name = "MaxEngageRangePct", type = "table" },
	{ name = "FlightSizeOverrides", type = "table" },
	{ name = "LaunchCriteria", type = "table" },
	{ name = "AllowedAirbases", type = "table" },
	-- Strings
	{ name = "Name", type = "string", default = "Passive Defense" },
}

local MANPAD_SCHEMA = {
	{
		name = "AlertnessDecaySec",
		legacyName = "MANPADAlertnessDecaySec",
		default = 14400,
		min = 0,
	},
	{
		name = "FieldRadioRangeM",
		legacyName = "MANPADFieldRadioRangeM",
		default = Medusa.Constants.Manpad.DEFAULT_FIELD_RADIO_RANGE_M,
		min = 0,
		max = Medusa.Constants.Manpad.MAX_FIELD_RADIO_RANGE_M,
	},
	{
		name = "AudioRangeM",
		default = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
		min = Medusa.Constants.Manpad.AUDIO_RANGE_MIN_M,
		max = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
	},
}

local AAA_SCHEMA = {
	{
		name = "AudioRangeM",
		default = Medusa.Constants.Aaa.DEFAULT_AUDIO_RANGE_M,
		min = 0,
		max = Medusa.Constants.Aaa.MAX_AUDIO_RANGE_M,
	},
	{
		name = "AreaFireChance",
		default = Medusa.Constants.Aaa.DEFAULT_AREA_FIRE_CHANCE,
		min = 0,
		max = 0.5,
	},
	{
		name = "BarrageChance",
		default = Medusa.Constants.Aaa.DEFAULT_BARRAGE_CHANCE,
		min = 0,
		max = 1,
	},
	{
		name = "MaxBarrageGroups",
		default = Medusa.Constants.Aaa.DEFAULT_MAX_BARRAGE_GROUPS,
		min = 0,
		max = Medusa.Constants.Aaa.MAX_BARRAGE_GROUPS,
		integer = true,
	},
}

local CREW_SUPPRESSION_SCHEMA = {
	{
		name = "DurationMinSec",
		default = Medusa.Constants.CrewSuppression.DEFAULT_DURATION_MIN_SEC,
		min = 1,
		max = Medusa.Constants.CrewSuppression.MAX_DURATION_SEC,
	},
	{
		name = "DurationMaxSec",
		default = Medusa.Constants.CrewSuppression.DEFAULT_DURATION_MAX_SEC,
		min = 1,
		max = Medusa.Constants.CrewSuppression.MAX_DURATION_SEC,
	},
	{
		name = "MaxGroupDiameterM",
		default = Medusa.Constants.CrewSuppression.DEFAULT_MAX_GROUP_DIAMETER_M,
		min = 1,
		max = Medusa.Constants.CrewSuppression.MAX_GROUP_DIAMETER_M,
	},
	{
		name = "ExplosiveRadiusScaleM",
		default = Medusa.Constants.CrewSuppression.DEFAULT_EXPLOSIVE_RADIUS_SCALE_M,
		min = 0.1,
		max = Medusa.Constants.CrewSuppression.EXPLOSIVE_RADIUS_MAX_M,
	},
	{
		name = "ExplosiveRadiusMaxM",
		default = Medusa.Constants.CrewSuppression.EXPLOSIVE_RADIUS_MAX_M,
		min = 1,
		max = Medusa.Constants.CrewSuppression.EXPLOSIVE_RADIUS_MAX_M,
	},
	{
		name = "ExplosiveEffectiveness",
		default = Medusa.Constants.CrewSuppression.DEFAULT_EXPLOSIVE_EFFECTIVENESS,
		min = 0,
		max = 1,
	},
	{
		name = "SkillResistancePerLevel",
		default = Medusa.Constants.CrewSuppression.DEFAULT_SKILL_RESISTANCE_PER_LEVEL,
		min = 0,
		max = Medusa.Constants.CrewSuppression.MAX_SKILL_RESISTANCE_PER_LEVEL,
	},
	{
		name = "CannonRadiusM",
		default = Medusa.Constants.CrewSuppression.DEFAULT_CANNON_RADIUS_M,
		min = 1,
		max = Medusa.Constants.CrewSuppression.CANNON_RADIUS_MAX_M,
	},
	{
		name = "CannonEffectiveness",
		default = Medusa.Constants.CrewSuppression.DEFAULT_CANNON_EFFECTIVENESS,
		min = 0,
		max = 1,
	},
}

local _logger

-- Top-level keys a doctrine table may carry: every DOCTRINE_SCHEMA field, the sub-tables resolved below, the flat
-- MANPAD fields older missions use, and DoctrineId. Built once at load; KNOWN_BY_LOWER maps a lower-case spelling
-- to the field so a key that differs only in case can name it.
local KNOWN_TOP_LEVEL = { DoctrineId = true, MANPAD = true, AAA = true, CrewSuppression = true }
for i = 1, #DOCTRINE_SCHEMA do
	KNOWN_TOP_LEVEL[DOCTRINE_SCHEMA[i].name] = true
end
for i = 1, #MANPAD_SCHEMA do
	if MANPAD_SCHEMA[i].legacyName then
		KNOWN_TOP_LEVEL[MANPAD_SCHEMA[i].legacyName] = true
	end
end
local KNOWN_BY_LOWER = {}
for key in pairs(KNOWN_TOP_LEVEL) do
	KNOWN_BY_LOWER[string.lower(key)] = key
end
-- Fields of removed features: accepted (an older mission still loads without an unknown-field error), ignored, and
-- named once per doctrine in one notice. Not offered as the field a misspelled key resembles.
local REMOVED_FIELDS = { "PassiveDetection", "ESM" }
for i = 1, #REMOVED_FIELDS do
	KNOWN_TOP_LEVEL[REMOVED_FIELDS[i]] = true
end

--- Per-kind track refresh rates for a doctrine, fixed at load. An explicit ScanUpdateRateSec entry wins, then an
--- explicitly set PerTrackScanUpdateRate, then the default; each is clamped to the global limits and to half of
--- TrackMemorySec (1 s floor). Logs an error for each rate it caps and when SensorCleanupSec is below the slowest
--- rate (the refresh gate would be cleared before the radar looks again).
--- @param doctrine table Doctrine being built (needs ExplicitFields, PerTrackScanUpdateRate, SensorCleanupSec)
--- @return table rates { EWR = number, SAM_SEARCH = number, SAM_TRACK = number }
function Medusa.Entities.Doctrine.resolveScanRates(doctrine)
	local C = Medusa.Constants
	local memory = Medusa.Config
			and Medusa.Config.getTrackMemoryDurationSec
			and Medusa.Config:getTrackMemoryDurationSec()
		or 30
	local cap = math.max(C.SCAN_UPDATE_RATE_MIN_SEC, memory / 2)
	local overrides = type(doctrine.ScanUpdateRateSec) == "table" and doctrine.ScanUpdateRateSec or {}
	local base = doctrine.ExplicitFields
		and doctrine.ExplicitFields.PerTrackScanUpdateRate
		and doctrine.PerTrackScanUpdateRate
	local rates, slowest = {}, 0
	for kind, default in pairs(C.SCAN_UPDATE_RATE_DEFAULTS) do
		local value = overrides[kind]
		if type(value) ~= "number" then
			value = base or default
		end
		value = math.max(C.SCAN_UPDATE_RATE_MIN_SEC, math.min(C.SCAN_UPDATE_RATE_MAX_SEC, value))
		if value > cap then
			if _logger then
				_logger:error(
					string.format(
						"%s scan rate %ss exceeds half of TrackMemorySec (%ss), using %ss",
						kind,
						tostring(value),
						tostring(memory),
						tostring(cap)
					)
				)
			end
			value = cap
		end
		rates[kind] = value
		slowest = math.max(slowest, value)
	end
	local cleanup = doctrine.SensorCleanupSec
	if _logger and type(cleanup) == "number" and cleanup < slowest then
		_logger:error(
			string.format(
				"SensorCleanupSec %ss is below the slowest scan rate (%ss): tracks from that radar refresh every poll",
				tostring(cleanup),
				tostring(slowest)
			)
		)
	end
	return rates
end

--- Logs an error for each key in a settings table that Medusa does not know (a misspelled key is otherwise ignored).
--- @param label string Setting name used in the message, e.g. "ScanUpdateRateSec"
--- @param overrides any The mission's table; anything that is not a table is skipped
--- @param isKnown fun(key: any): boolean
local function reportUnknownKeys(label, overrides, isKnown)
	if type(overrides) ~= "table" then
		return
	end
	for key in pairs(overrides) do
		if not isKnown(key) then
			_logger:error(string.format("unknown setting '%s.%s' ignored", label, tostring(key)))
		end
	end
end

--- Logs an error for each top-level doctrine key Medusa does not know; a misspelled field would otherwise silently
--- take its default.
local function reportUnknownTopLevelKeys(overrides)
	for key in pairs(overrides) do
		if not KNOWN_TOP_LEVEL[key] then
			local resembles = type(key) == "string" and KNOWN_BY_LOWER[string.lower(key)]
			_logger:error(
				string.format(
					"unknown doctrine setting '%s' ignored%s",
					tostring(key),
					resembles and string.format(" (did you mean '%s'?)", resembles) or ""
				)
			)
		end
	end
end

--- A doctrine number as a usable value: a number or numeric string, not NaN. Anything else is logged as an error
--- and gives nil (the field then takes its default, or stays unset if it has none).
local function readNumber(s, raw)
	if raw == nil then
		return nil
	end
	local v = tonumber(raw)
	if v == nil or v ~= v then
		_logger:error(
			string.format(
				"invalid '%s' value '%s' (not a number), %s",
				s.name,
				tostring(raw),
				s.default ~= nil and string.format("using '%s'", tostring(s.default)) or "ignored"
			)
		)
		return nil
	end
	return v
end

local function resolveNumericSubtable(schema, overrides, legacyOverrides)
	local source = type(overrides) == "table" and overrides or {}
	local resolved = {}
	for i = 1, #schema do
		local setting = schema[i]
		local raw = source[setting.name]
		if raw == nil and setting.legacyName and legacyOverrides then
			raw = legacyOverrides[setting.legacyName]
		end
		local value = tonumber(raw)
		if not value or value ~= value or value == math.huge or value == -math.huge then
			value = setting.default
		end
		if setting.min and value < setting.min then
			value = setting.min
		elseif setting.max and value > setting.max then
			value = setting.max
		end
		if setting.integer then
			value = math.floor(value)
		end
		resolved[setting.name] = value
	end
	return resolved
end

function Medusa.Entities.Doctrine.new(overrides)
	local d = overrides or {}
	local doctrine = { DoctrineId = d.DoctrineId or NewULID() }
	if not _logger then
		_logger = Medusa.Logger:ns("Doctrine")
	end
	local explicit = {}
	reportUnknownTopLevelKeys(d)

	for i = 1, #DOCTRINE_SCHEMA do
		local s = DOCTRINE_SCHEMA[i]
		local raw = d[s.name]
		if raw ~= nil then
			explicit[s.name] = true
		end

		if s.type == "enum" then
			local enumTable = Medusa.Constants[s.enum]
			if raw ~= nil and (not enumTable or not enumTable[raw]) then
				local valid = {}
				if enumTable then
					for k in pairs(enumTable) do
						valid[#valid + 1] = k
					end
				end
				_logger:error(
					string.format(
						"invalid '%s' value '%s' (valid: %s), using '%s'",
						s.name,
						tostring(raw),
						table.concat(valid, ", "),
						s.defaultText or (s.default and tostring(s.default)) or "the default"
					)
				)
				raw = nil
			end
			doctrine[s.name] = raw or s.default
		elseif s.type == "number" then
			local v = readNumber(s, raw) or s.default
			if v and s.min and v < s.min then
				v = s.min
			end
			if v and s.max and v > s.max then
				v = s.max
			end
			doctrine[s.name] = v
		elseif s.type == "number_opt" then
			if raw ~= nil then
				local v = readNumber(s, raw)
				if v then
					if s.min and v < s.min then
						v = s.min
					end
					if s.max and v > s.max then
						v = s.max
					end
					doctrine[s.name] = v
				end
			end
		elseif s.type == "boolean" then
			if raw ~= nil and type(raw) ~= "boolean" then
				_logger:error(
					string.format(
						"invalid '%s' value '%s' (valid: true, false), using '%s'",
						s.name,
						tostring(raw),
						tostring(s.default)
					)
				)
				raw = nil
			end
			if raw ~= nil then
				doctrine[s.name] = raw
			else
				doctrine[s.name] = s.default
			end
		elseif s.type == "table" then
			doctrine[s.name] = raw
		else
			doctrine[s.name] = raw or s.default
		end
	end

	if doctrine.Readiness == nil then
		doctrine.Readiness = Medusa.Constants.ReadinessFromPosture[doctrine.Posture]
			or Medusa.Constants.Readiness.ENGAGED
	end

	-- Fields the mission set itself (defaults filled in above are indistinguishable otherwise).
	doctrine.ExplicitFields = explicit
	doctrine.ScanRates = Medusa.Entities.Doctrine.resolveScanRates(doctrine)
	reportUnknownKeys("ScanUpdateRateSec", d.ScanUpdateRateSec, function(key)
		return Medusa.Constants.SCAN_UPDATE_RATE_DEFAULTS[key] ~= nil
	end)
	if doctrine.DecoyFireDiscipline and not doctrine.ManageEngageAirWeapons then
		_logger:error("DecoyFireDiscipline needs ManageEngageAirWeapons; no decoy fire holds will be made")
	end

	doctrine.MANPAD = resolveNumericSubtable(MANPAD_SCHEMA, d.MANPAD, d)
	doctrine.AAA = resolveNumericSubtable(AAA_SCHEMA, d.AAA)
	local removed = {}
	for i = 1, #REMOVED_FIELDS do
		if d[REMOVED_FIELDS[i]] ~= nil then
			removed[#removed + 1] = REMOVED_FIELDS[i]
		end
	end
	if #removed > 0 then
		_logger:error(
			string.format(
				"doctrine %s ignored: listening stations were removed (DCS gives scripts no radar state for "
					.. "player-flown aircraft)",
				table.concat(removed, " and ")
			)
		)
	end
	local crewSuppressionOverrides = type(d.CrewSuppression) == "table" and d.CrewSuppression or {}
	doctrine.CrewSuppression = resolveNumericSubtable(CREW_SUPPRESSION_SCHEMA, crewSuppressionOverrides)
	if doctrine.CrewSuppression.DurationMinSec > doctrine.CrewSuppression.DurationMaxSec then
		_logger:error(
			string.format(
				"CrewSuppression.DurationMinSec '%s' exceeds DurationMaxSec '%s', using defaults",
				tostring(doctrine.CrewSuppression.DurationMinSec),
				tostring(doctrine.CrewSuppression.DurationMaxSec)
			)
		)
		doctrine.CrewSuppression.DurationMinSec = Medusa.Constants.CrewSuppression.DEFAULT_DURATION_MIN_SEC
		doctrine.CrewSuppression.DurationMaxSec = Medusa.Constants.CrewSuppression.DEFAULT_DURATION_MAX_SEC
	end
	local enabled = crewSuppressionOverrides.Enabled
	if enabled ~= nil and type(enabled) ~= "boolean" then
		_logger:error(
			string.format(
				"invalid CrewSuppression.Enabled value '%s', using '%s'",
				tostring(enabled),
				tostring(Medusa.Constants.CrewSuppression.DEFAULT_ENABLED)
			)
		)
		enabled = nil
	end
	if enabled == nil then
		enabled = Medusa.Constants.CrewSuppression.DEFAULT_ENABLED
	end
	doctrine.CrewSuppression.Enabled = enabled
	local defaultCrewSkill = Medusa.Constants.CrewSuppression.DEFAULT_CREW_SKILL
	local crewSkill = crewSuppressionOverrides.DefaultCrewSkill
	if crewSkill ~= nil and Medusa.Constants.CrewSkill[crewSkill] ~= crewSkill then
		_logger:error(
			string.format(
				"invalid CrewSuppression.DefaultCrewSkill value '%s', using '%s'",
				tostring(crewSkill),
				defaultCrewSkill
			)
		)
		crewSkill = nil
	end
	doctrine.CrewSuppression.DefaultCrewSkill = crewSkill or defaultCrewSkill
	if doctrine.CrewFactorsDefaultSkill == nil then
		doctrine.CrewFactorsDefaultSkill = doctrine.CrewSuppression.DefaultCrewSkill
	end

	return doctrine
end
