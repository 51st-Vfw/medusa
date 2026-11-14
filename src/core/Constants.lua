require("_header")

--[[
             ██████╗ ██████╗ ███╗   ██╗███████╗████████╗ █████╗ ███╗   ██╗████████╗███████╗
            ██╔════╝██╔═══██╗████╗  ██║██╔════╝╚══██╔══╝██╔══██╗████╗  ██║╚══██╔══╝██╔════╝
            ██║     ██║   ██║██╔██╗ ██║███████╗   ██║   ███████║██╔██╗ ██║   ██║   ███████╗
            ██║     ██║   ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║╚██╗██║   ██║   ╚════██║
            ╚██████╗╚██████╔╝██║ ╚████║███████║   ██║   ██║  ██║██║ ╚████║   ██║   ███████║
             ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝

    What this module does
    - Defines every enum, threshold, and named constant used across Medusa.
    - Groups values by domain: network, battery state, tracks, engagement, EMCON, HARM, physics, and zones.

    How others use it
    - Nearly every service and entity references these constants for state comparisons and configuration defaults.
--]]

Medusa.Constants = {}

Medusa.Constants.LogLevel = {
	NONE = "NONE",
	ERROR = "ERROR",
	INFO = "INFO",
	DEBUG = "DEBUG",
	TRACE = "TRACE",
}

-- ── Network & C2 ──────────────────────────────────────────────────

Medusa.Constants.Role = {
	GCI = "GCI",
	EWR = "EWR",
	AWACS = "AWACS",
	HQ = "HQ",
	OBSERVER = "OBSERVER",
	-- A group named with the esm/elint token. Listening stations were removed (DCS gives scripts no radar state for
	-- player-flown aircraft); such a group is an untrained lookout post.
	ESM = "ESM",
}

Medusa.Constants.NetworkConnectivity = {
	CONNECTED = "CONNECTED",
	DEGRADED = "DEGRADED",
	DISCONNECTED = "DISCONNECTED",
}

Medusa.Constants.NetworkDegradationPolicy = {
	REVERT_TO_AUTONOMOUS = "REVERT_TO_AUTONOMOUS",
	GO_DARK = "GO_DARK",
	REVERT_TO_SELF_DEFENSE = "REVERT_TO_SELF_DEFENSE",
}

-- ── Battery & Unit State ──────────────────────────────────────────

Medusa.Constants.ActivationState = {
	INITIALIZING = "INITIALIZING",
	STATE_COLD = "STATE_COLD",
	STATE_WARM = "STATE_WARM",
	STATE_HOT = "STATE_HOT",
}

Medusa.Constants.BatteryOperationalStatus = {
	ACTIVE = "ACTIVE",
	DESTROYED = "DESTROYED",
	SEARCH_ONLY = "SEARCH_ONLY",
	ENGAGEMENT_IMPAIRED = "ENGAGEMENT_IMPAIRED",
	INOPERATIVE = "INOPERATIVE",
	MOVING = "MOVING",
	REARMING = "REARMING",
}

Medusa.Constants.BatteryUnitRole = {
	LAUNCHER = "LAUNCHER",
	SEARCH_RADAR = "SEARCH_RADAR",
	TRACK_RADAR = "TRACK_RADAR",
	COMMAND_POST = "COMMAND_POST",
	TELAR = "TELAR",
	TLAR = "TLAR",
	MANPAD = "MANPAD",
	AAA = "AAA",
	OTHER = "OTHER",
}

Medusa.Constants.BatteryRole = {
	VLR_SAM = "VLR_SAM",
	LR_SAM = "LR_SAM",
	MR_SAM = "MR_SAM",
	SR_SAM = "SR_SAM",
	AAA = "AAA",
	GENERIC_SAM = "GENERIC_SAM",
	MANPAD = "MANPAD",
}

Medusa.Constants.VLR_THRESHOLD_M = 250000

Medusa.Constants.LAUNCHER_ROLES = {
	[Medusa.Constants.BatteryUnitRole.LAUNCHER] = true,
	[Medusa.Constants.BatteryUnitRole.TELAR] = true,
	[Medusa.Constants.BatteryUnitRole.TLAR] = true,
}

Medusa.Constants.CLUSTER_THRESHOLD_M = 1852 -- 1 NM

Medusa.Constants.SystemTypeDefaults = {
	VLR_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "SEARCH_ONLY" },
	LR_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "SEARCH_ONLY" },
	MR_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "INOPERATIVE" },
	SR_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "INOPERATIVE" },
	AAA = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "INOPERATIVE" },
	GENERIC_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "INOPERATIVE" },
	MANPAD = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "REARMING" },
}

Medusa.Constants.RadarStatus = {
	ACTIVE = "ACTIVE",
	STANDBY = "STANDBY",
	DARK = "DARK",
	DAMAGED = "DAMAGED",
	NA = "NA",
}

Medusa.Constants.BatteryRadarConfiguration = {
	NONE = "NONE",
	SEARCH_ONLY = "SEARCH_ONLY",
	TRACK_ONLY = "TRACK_ONLY",
	COMBINED = "COMBINED",
}

Medusa.Constants.BatteryRadarDependencyPolicy = {
	REQUIRED = "REQUIRED",
	OPTIONAL_DEGRADED = "OPTIONAL_DEGRADED",
}

Medusa.Constants.UnitOperationalStatus = {
	ACTIVE = "ACTIVE",
	DAMAGED = "DAMAGED",
	DESTROYED = "DESTROYED",
}

Medusa.Constants.CrewSuppressionState = {
	CLEAR = "CLEAR",
	SUPPRESSED = "SUPPRESSED",
}

Medusa.Constants.CrewSuppressionCause = {
	DAMAGE = "DAMAGE",
	EXPLOSIVE = "EXPLOSIVE",
	CANNON = "CANNON",
}

Medusa.Constants.CrewSkill = {
	AVERAGE = "AVERAGE",
	GOOD = "GOOD",
	HIGH = "HIGH",
	EXCELLENT = "EXCELLENT",
}

Medusa.Constants.CrewSkillLevel = {
	[Medusa.Constants.CrewSkill.AVERAGE] = 0,
	[Medusa.Constants.CrewSkill.GOOD] = 1,
	[Medusa.Constants.CrewSkill.HIGH] = 2,
	[Medusa.Constants.CrewSkill.EXCELLENT] = 3,
}

Medusa.Constants.CrewSuppressionTerminalKind = {
	EXPLOSIVE = "EXPLOSIVE",
	CANNON = "CANNON",
}

Medusa.Constants.CrewSuppressionTerminalSource = {
	HIT = "HIT",
	TERRAIN = "TERRAIN",
	FORWARD_VECTOR = "FORWARD_VECTOR",
}
Medusa.Constants.CrewSuppressionTerminalKindBySource = {
	[Medusa.Constants.CrewSuppressionTerminalSource.HIT] = Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE,
	[Medusa.Constants.CrewSuppressionTerminalSource.TERRAIN] = Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE,
	[Medusa.Constants.CrewSuppressionTerminalSource.FORWARD_VECTOR] = Medusa.Constants.CrewSuppressionTerminalKind.CANNON,
}
Medusa.Constants.CrewSuppressionImpactSource = Medusa.Constants.CrewSuppressionTerminalSource

Medusa.Constants.CrewSuppressionWeaponOutcome = {
	TRACKED = "TRACKED",
	TRACKER_FULL = "TRACKER_FULL",
	UNTRACKABLE = "UNTRACKABLE",
	EXPIRED = "EXPIRED",
	IMPACT_HIT = "IMPACT_HIT",
	IMPACT_TERRAIN = "IMPACT_TERRAIN",
	NO_TERRAIN_INTERSECTION = "NO_TERRAIN_INTERSECTION",
}

Medusa.Constants.CrewSuppressionCannonOutcome = {
	QUEUED = "QUEUED",
	QUEUE_FULL = "QUEUE_FULL",
	EXPIRED = "EXPIRED",
	UNTRACKABLE = "UNTRACKABLE",
	NO_TERRAIN_INTERSECTION = "NO_TERRAIN_INTERSECTION",
	ESTIMATED_FORWARD = "ESTIMATED_FORWARD",
}

Medusa.Constants.CrewSuppressionDropReason = {
	INVALID_EVENT = "INVALID_EVENT",
	UNMANAGED_TARGET = "UNMANAGED_TARGET",
	GROUP_DIAMETER_UNAVAILABLE = "GROUP_DIAMETER_UNAVAILABLE",
	GROUP_DIAMETER_EXCEEDED = "GROUP_DIAMETER_EXCEEDED",
	INVALID_HEALTH = "INVALID_HEALTH",
	EXPIRED_EVENT = "EXPIRED_EVENT",
	QUEUE_OVERFLOW = "QUEUE_OVERFLOW",
	RECOVERY_TIMER = "RECOVERY_TIMER",
	CONTROLLER_UNAVAILABLE = "CONTROLLER_UNAVAILABLE",
	IMPACT_EXPIRED = "IMPACT_EXPIRED",
}

Medusa.Constants.CrewSuppression = {
	DEFAULT_ENABLED = true,
	DEFAULT_DURATION_MIN_SEC = 30,
	DEFAULT_DURATION_MAX_SEC = 120,
	MAX_DURATION_SEC = 3600,
	DEFAULT_MAX_GROUP_DIAMETER_M = 609.6,
	MAX_GROUP_DIAMETER_M = 100000,
	HIT_EVENT_QUEUE_CAPACITY = 128,
	HIT_EVENT_PROCESSING_BUDGET = 2,
	HIT_EVENT_MAX_AGE_SEC = 30,
	WEAPON_TRACK_CAPACITY = 128,
	WEAPON_SAMPLES_PER_UPDATE = 5,
	WEAPON_UPDATE_INTERVAL_SEC = 0.1,
	WEAPON_MAX_AGE_SEC = 7200,
	IMPACT_QUEUE_CAPACITY = 128,
	IMPACT_PROCESSING_BUDGET = 5,
	IMPACT_UNIT_VISIT_BUDGET = 32,
	IMPACT_MAX_AGE_SEC = 30,
	UNIT_POSITION_REFRESH_BUDGET = 4,
	DEFAULT_EXPLOSIVE_RADIUS_SCALE_M = 10,
	EXPLOSIVE_RADIUS_MAX_M = 500,
	DEFAULT_EXPLOSIVE_EFFECTIVENESS = 1,
	DEFAULT_CREW_SKILL = Medusa.Constants.CrewSkill.AVERAGE,
	DEFAULT_SKILL_RESISTANCE_PER_LEVEL = 0.1,
	MAX_SKILL_RESISTANCE_PER_LEVEL = 0.3,
	DEFAULT_CANNON_RADIUS_M = 150,
	CANNON_RADIUS_MAX_M = 500,
	DEFAULT_CANNON_EFFECTIVENESS = 0.5,
	CANNON_CANDIDATE_CAPACITY = 128,
	CANNON_ESTIMATES_PER_UPDATE = 5,
	CANNON_CANDIDATE_MAX_AGE_SEC = 5,
	CANNON_MAX_PROJECTION_M = 5000,
	CANNON_EFFECTIVE_MUZZLE_VELOCITY_MPS = 900,
	CANNON_GRAVITY_MPS2 = 9.81,
	CANNON_TRAJECTORY_SEGMENTS = 4,
}

Medusa.Constants.TacticalState = {
	IDLE = "IDLE",
	STANDARD_ENGAGING = "STANDARD_ENGAGING",
	LURING_TARGET = "LURING_TARGET",
	LINGERING_ALERT_MONITORING = "LINGERING_ALERT_MONITORING",
	ASSISTING_ENGAGEMENT = "ASSISTING_ENGAGEMENT",
}

Medusa.Constants.AutonomousBehavior = {
	STATE_DARK = "STATE_DARK",
	STATE_WARM = "STATE_WARM",
	STATE_HOT = "STATE_HOT",
	RANDOM_STATE = "RANDOM_STATE",
}

Medusa.Constants.ShootAndScootPolicy = {
	NONE = "NONE",
	AFTER_ENGAGEMENT = "AFTER_ENGAGEMENT",
	TIMED_RELOCATION = "TIMED_RELOCATION",
}

-- ── Track Management ──────────────────────────────────────────────

Medusa.Constants.TrackLifecycleState = {
	ACTIVE = "ACTIVE",
	STALE = "STALE",
	EXPIRED = "EXPIRED",
}

Medusa.Constants.TrackSource = {
	AWACS = "AWACS",
	EARLY_WARNING_RADAR = "EARLY_WARNING_RADAR",
	SAM_BATTERY = "SAM_BATTERY",
	SHIPBORNE_RADAR = "SHIPBORNE_RADAR",
	AIRBORNE_DATALINK = "AIRBORNE_DATALINK",
}

Medusa.Constants.TrackSourcePrefix = {
	[Medusa.Constants.TrackSource.AWACS] = "AW",
	[Medusa.Constants.TrackSource.EARLY_WARNING_RADAR] = "AE",
	[Medusa.Constants.TrackSource.SAM_BATTERY] = "AB",
	[Medusa.Constants.TrackSource.SHIPBORNE_RADAR] = "AS",
	[Medusa.Constants.TrackSource.AIRBORNE_DATALINK] = "AC",
}

Medusa.Constants.TrackDisplayId = {
	UNSET = "UNSET",
}

Medusa.Constants.TrackIdentification = {
	UNKNOWN = "UNKNOWN",
	BOGEY = "BOGEY",
	BANDIT = "BANDIT",
	HOSTILE = "HOSTILE",
	FRIENDLY = "FRIENDLY",
	WHITEAIR = "WHITEAIR",
	ARM = "ARM",
}

Medusa.Constants.AssessedAircraftType = {
	UNKNOWN = "UNKNOWN",
	FIXED_WING = "FIXED_WING",
	ROTARY_WING = "ROTARY_WING",
	MISSILE = "MISSILE",
	FIGHTER = "FIGHTER",
	SEAD_AIRCRAFT = "SEAD_AIRCRAFT",
	HARM = "HARM",
}

Medusa.Constants.HarmAssessmentState = {
	EVALUATING = "EVALUATING",
	SUSPECT = "SUSPECT",
	PROBABLE = "PROBABLE",
	CLEARED = "CLEARED",
	CONFIRMED = "CONFIRMED",
}

Medusa.Constants.ManeuverState = {
	STRAIGHT = "STRAIGHT",
	TURNING_LEFT = "TURNING_LEFT",
	TURNING_RIGHT = "TURNING_RIGHT",
	ORBITING = "ORBITING",
	MANEUVERING = "MANEUVERING",
	UNKNOWN = "UNKNOWN",
}

Medusa.Constants.AircraftTypeThreatScore = {
	UNKNOWN = 30,
	FIXED_WING = 50,
	ROTARY_WING = 40,
	MISSILE = 90,
	FIGHTER = 60,
	SEAD_AIRCRAFT = 95,
	HARM = 95,
}

Medusa.Constants.HarmDefenseState = {
	SUPPRESSED = "SUPPRESSED",
	SELF_DEFENDING = "SELF_DEFENDING",
	PD_PROTECTED = "PD_PROTECTED",
	INTERCEPTING = "INTERCEPTING",
}

Medusa.Constants.TRACK_REASSOC_MAX_DIST_M = 5000
Medusa.Constants.TRACK_REASSOC_TTL_SEC = 120

-- Evidence-based re-acquisition (doctrine EvidenceReacquisition): a lost track is matched to a new contact by where it
-- should be and how it should be flying, never by DCS object id. Numbers from an offline replay of recorded DCS
-- flights (ARMs, jets, TALDs; every contact dropped together for 5-60 s), generic kinematics, no type table.
Medusa.Constants.Reacquisition = {
	-- Trend prediction: the acceleration over the last HISTORY_SEC of the track (at least TREND_MIN_SAMPLES looks
	-- spanning more than TREND_MIN_SPAN_SEC), capped at 3 g and extrapolated for at most TREND_MAX_SEC.
	HISTORY_SEC = 6,
	TREND_MIN_SAMPLES = 3,
	TREND_MIN_SPAN_SEC = 1.5,
	TREND_MAX_ACCEL_MPS2 = 30,
	TREND_MAX_SEC = 20,
	-- Uncertainty after a gap of g seconds at speed s: position POS_BASE_M + POS_PER_SPEED * s * g + POS_PER_GAP2 *
	-- g^2 (altitude error counts ALT_WEIGHT times: radars measure height worst, aircraft change it least);
	-- velocity VEL_BASE_MPS + (VEL_PER_GAP + VEL_PER_SPEED_GAP * s) * g.
	POS_BASE_M = 500,
	POS_PER_SPEED = 0.15,
	POS_PER_GAP2 = 2,
	ALT_WEIGHT = 2,
	VEL_BASE_MPS = 30,
	VEL_PER_GAP = 4,
	VEL_PER_SPEED_GAP = 0.02,
	-- Score exp(-(d_pos^2 + d_vel^2) / 2), best over the predictions; a match needs SCORE_THRESHOLD and MARGIN times
	-- the runner-up's score.
	SCORE_THRESHOLD = 0.15,
	MARGIN = 2,
	-- Lost tracks are kept on a grid of GRID_CELL_M cells; a new contact looks no farther than GATE_MAX_M (a fast
	-- mover lost for a minute or more is too vague to carry anything).
	GRID_CELL_M = 10000,
	GATE_MAX_M = 50000,
	-- A confirmed ARM still held (within the track memory) is already lost to new contacts once it has been silent
	-- for SILENT_LOOKS of its own refresh intervals (the time between its last two looks), and at least
	-- SILENT_MIN_SEC: two looks missed in a row is a lost contact to an operator, one is not. The DCS object it holds
	-- still resumes it until the memory runs out. Other held tracks wait for the memory to run out
	-- (TrackReacquisition.mayBeTakenWhileHeld).
	-- Looks come at the fastest covering radar's rate, so the slowest radar still covering it must have missed
	-- SILENT_LOOKS of its own looks too (SensorPollingService.coveredUntil): when the fast radar shuts down, a slower
	-- one's look may still be due. A radar covers a contact while it has detected it within COVER_FRESH_LOOKS of its
	-- own intervals, throttled looks included.
	SILENT_LOOKS = 2,
	SILENT_MIN_SEC = 4,
	COVER_FRESH_LOOKS = 2,
	-- An ARM label crosses gaps up to this long (in recorded flights no jet ever took an ARM's track within 20 s).
	ARM_LABEL_MAX_GAP_SEC = 20,
	-- ...and only to a contact that keeps at least max(1 - ARM_MAX_SLOWDOWN_PER_SEC x gap, ARM_MIN_SPEED_KEPT) of the
	-- ARM's speed (recorded ARMs: 99% keep 85% / 74% / 62% of it after 5 / 10 / 20 s; a jet turning away from its
	-- own lost ARM does not).
	ARM_MAX_SLOWDOWN_PER_SEC = 0.03,
	ARM_MIN_SPEED_KEPT = 0.6,
	-- Match quality = score x exp(-gap / EVIDENCE_FADE_SEC). At STRONG_QUALITY or more, labels, sightings and the
	-- launch cue carry as they were; below it a probable decoy comes back suspect, a suspect as an aircraft, and
	-- sightings and the launch cue are dropped.
	EVIDENCE_FADE_SEC = 120,
	STRONG_QUALITY = 0.4,
	-- A contact this much faster than a lost aircraft (heading within 90 deg) is a weapon leaving it, not the
	-- aircraft: the same opening speed as the launch cue.
	LAUNCH_SPEED_GAIN_MPS = 120,
}
Medusa.Constants.TRACK_UPDATE_EXPIRY_BUCKETS = { 1, 2, 3, 5, 10, 20, 50 }
Medusa.Constants.TRACK_TURN_THRESHOLD_RAD = 0.15
Medusa.Constants.TRACK_ORBIT_THRESHOLD_RAD = 2.5
Medusa.Constants.BANDIT_DWELL_SEC = 30
Medusa.Constants.ROTARY_WING_SPEED_THRESHOLD = 100
Medusa.Constants.MISSILE_SPEED_THRESHOLD = 1000
Medusa.Constants.FIGHTER_MANEUVER_SPEED_THRESHOLD = 200
Medusa.Constants.MANEUVER_SPEED_RATIO_THRESHOLD = 0.3

-- ── Engagement & Targeting ────────────────────────────────────────

Medusa.Constants.ROEState = {
	FREE = "FREE",
	TIGHT = "TIGHT",
	HOLD = "HOLD",
}

Medusa.Constants.CoordinatedEngagementTactics = {
	SHOOT_LOOK_SHOOT = "SHOOT_LOOK_SHOOT",
	SHOOT_IN_DEPTH = "SHOOT_IN_DEPTH",
	SHOOT_SHOOT = "SHOOT_SHOOT",
	SHOOT_SHOOT_FLOOD = "SHOOT_SHOOT_FLOOD",
}

Medusa.Constants.MAX_ASSIGNMENT_BUDGET = 10
Medusa.Constants.PK_MAX_DEFAULT = 0.90
Medusa.Constants.PK_FLOOR = 0.25
Medusa.Constants.PK_ASPECT_BEAM_FLOOR = 0.30
Medusa.Constants.PK_ALTITUDE_TAPER_M = 500
Medusa.Constants.PK_RANGE_DECAY_RATE = 2
Medusa.Constants.SPEED_OF_SOUND_MPS = 340
Medusa.Constants.PK_SIGMA_CAP_M = 40000
Medusa.Constants.PK_FLOOR_ANCHOR_RANGE_M = 20000
Medusa.Constants.PK_OPTIMAL_REFERENCE_M = 80000
Medusa.Constants.PK_OPTIMAL_FRACTION = 0.45
Medusa.Constants.LOOKAHEAD_DEFAULT_SEC = 8
Medusa.Constants.HANDOFF_DWELL_SEC = 20
Medusa.Constants.HANDOFF_PK_IMPROVEMENT = 1.5
Medusa.Constants.SATURATION_PENALTY_ALPHA = 0.3
Medusa.Constants.REASSIGNMENT_EVAL_SEC = 45
Medusa.Constants.LAST_CHANCE_SALVO_COUNT = 2
Medusa.Constants.ROLLING_PK_WINDOW = 10
Medusa.Constants.ROLLING_PK_STEP = 0.02
Medusa.Constants.ROLLING_PK_CEILING = 0.60
Medusa.Constants.ROLLING_PK_DECAY_TAU = 65.1 -- exponential decay time constant: 99% decay in ~300s (5 min)
Medusa.Constants.SAM_AVG_MISSILE_SPEED_MPS = 800
-- DCS names its gun shells weapons.shells.<name> (Weapon.getTypeName).
Medusa.Constants.SHELL_TYPE_PREFIX = "weapons.shells."
Medusa.Constants.TTK_ALT_FLOOR_M = 1524
Medusa.Constants.TTK_ALT_CEIL_M = 9144
Medusa.Constants.REARM_CHECK_INTERVAL_SEC = 600

-- ── EMCON & Sensors ───────────────────────────────────────────────

Medusa.Constants.SensorType = {
	EWR = "EWR",
	GCI = "GCI",
	AWACS = "AWACS",
	SAM_SEARCH = "SAM_SEARCH",
	SAM_TRACK = "SAM_TRACK",
}

Medusa.Constants.EmissionControlPolicy = {
	MINIMIZE = "MINIMIZE",
	PERIODIC_SCAN = "PERIODIC_SCAN",
	COORDINATED_ROTATION = "COORDINATED_ROTATION",
	ALWAYS_ON = "ALWAYS_ON",
	INTELLIGENT_EMCON = "INTELLIGENT_EMCON",
}

Medusa.Constants.SAMAsEWRPolicy = {
	DISABLED = "DISABLED",
	WHEN_NO_EWR = "WHEN_NO_EWR",
	ALWAYS = "ALWAYS",
}

Medusa.Constants.SAM_AS_EWR_ELIGIBLE_ROLES = { LR_SAM = true, MR_SAM = true }

Medusa.Constants.EMCON_DEFAULT_SCAN_DURATION_SEC = 30

-- How often a radar refreshes a track it holds, by kind of radar (seconds); doctrine ScanUpdateRateSec overrides.
-- EWR: a rotating early-warning or GCI radar, one look per antenna turn (about 6-12 s for 1L13/55G6-class radars).
-- SAM_SEARCH: a SAM battery's acquisition radar (faster-turning), and any engagement radar that tracks one target.
-- SAM_TRACK: a HOT multi-target engagement radar (the systems listed in HARM_CAPABLE_SYSTEMS), which keeps every
-- track in its coverage updated; 2 s rather than the 1 s some of these radars manage on a few targets, since one
-- refresh rate stands for the whole picture. Other sources (AWACS, airborne datalink, ships) use
-- PerTrackScanUpdateRate. A mission that sets PerTrackScanUpdateRate gets it for every kind not named in
-- ScanUpdateRateSec. Every per-kind rate is capped at half of TrackMemorySec (a track must be refreshed at least
-- twice before it is dropped as stale).
Medusa.Constants.SCAN_UPDATE_RATE_DEFAULTS = { EWR = 10, SAM_SEARCH = 5, SAM_TRACK = 2 }
Medusa.Constants.SCAN_UPDATE_RATE_MIN_SEC = 1
Medusa.Constants.SCAN_UPDATE_RATE_MAX_SEC = 60
Medusa.Constants.EMCON_DEFAULT_QUIET_PERIOD_SEC = 0
Medusa.Constants.EMCON_DEFAULT_ROTATION_GROUPS = 2

Medusa.Constants.EMCON_DEFAULT_POLICY_BY_ROLE = {
	EWR = "ALWAYS_ON",
	GCI = "ALWAYS_ON",
	VLR_SAM = "MINIMIZE",
	LR_SAM = "MINIMIZE",
	MR_SAM = "MINIMIZE",
	SR_SAM = "MINIMIZE",
	AAA = "MINIMIZE",
	GENERIC_SAM = "MINIMIZE",
}

-- ── Physics ──────────────────────────────────────────────────────
Medusa.Constants.GRAVITY_MPS2 = 9.81
Medusa.Constants.PK_INNER_SIGMA_FACTOR = 0.759

-- ── HARM Detection & Response ─────────────────────────────────────

Medusa.Constants.HarmResponseStrategy = {
	IGNORE = "IGNORE",
	SHUTDOWN = "SHUTDOWN",
	SHUTDOWN_UNLESS_PD = "SHUTDOWN_UNLESS_PD",
	SELF_DEFEND = "SELF_DEFEND",
	AUTO_DEFENSE = "AUTO_DEFENSE",
}

Medusa.Constants.HARM_CAPABLE_SYSTEMS = {
	"S-300",
	"Tor",
	"Pantsir",
	"Patriot",
	"NASAMS",
}

Medusa.Constants.HARM_DEFEND_WEIGHT_TLAR = 4
Medusa.Constants.HARM_DEFEND_WEIGHT_LAUNCHER = 1.5

Medusa.Constants.POINT_DEFENSE_SEARCH_RADIUS_M = 15000

Medusa.Constants.HARM_DEFAULT_THREAT_RADIUS_M = 15000
Medusa.Constants.HARM_SHUTDOWN_SAFETY_MARGIN_SEC = 20
Medusa.Constants.HARM_MAX_RANGE_M = 130000
-- Launcher backtrack: a candidate's history entry nearest the HARM's first sighting is used if it lies within this
-- many seconds (a 10 s early-warning refresh with one missed look), dead-reckoned to that moment with its velocity.
Medusa.Constants.HARM_BACKTRACK_WINDOW_SEC = 12
Medusa.Constants.HARM_DEFAULT_SPEED_MPS = 300

Medusa.Constants.HARM_SPRT_MIN_SCANS = 5
Medusa.Constants.HARM_SPRT_MIN_DT_SEC = 0.01
Medusa.Constants.HARM_SPRT_SPEED_GATE = 50
Medusa.Constants.HARM_SPRT_MAX_FEAT_LLR = 3
Medusa.Constants.HARM_SPRT_MAX_SCAN_LLR = 4
-- Bound on the accumulated score: a jet tracked for minutes cannot bank so much
-- aircraft evidence that a real ARM-like run can never confirm it, nor can a missile bank unbounded ARM evidence.
Medusa.Constants.HARM_SPRT_ACCUMULATED_LLR_LIMIT = 20
Medusa.Constants.HARM_SPRT_THRESH_CONFIRM = 4.554
Medusa.Constants.HARM_SPRT_THRESH_CLEAR = -20
Medusa.Constants.HARM_SPRT_THRESH_SUSPECT = 1.139
Medusa.Constants.HARM_SPRT_THRESH_PROBABLE = 2.733

-- Once confirmed, an ARM stays confirmed until its flight shows it is not attacking a radar (crew bias): its score
-- no longer clears it. "Attacking" is judged on the ground track against every non-AAA battery, emitting or not
-- (ARMs keep flying at a radar that shut down and retarget to others): closing faster than CLOSING_MPS, passing
-- within MISS_M, and arriving within TIME_TO_GO_SEC (240 s covers an ARM confirmed at the 130 km limit flying 540 m/s
-- over the ground). Below SLOW_MPS over the ground an ARM is coasting near the end of its flight (recorded Kh-58U and
-- ALARM: at most 133 s left), so the limit is SLOW_TIME_TO_GO_SEC. The label clears after WINDOW_SEC (and at least
-- MIN_SCANS scans) of not attacking or flying under the speed gate, or after CONFIRMED_MAX_SEC. Chosen by replaying
-- 107 recorded DCS ARM flights (AGM-88 incl. lofted long-range shots, Kh-58U, Kh-31P, Kh-25MPU, ALARM, Shrike): none
-- is ever "not attacking" for more than 3.5 s before impact. Shooter aircraft clear a median 11 s after launch (29 s
-- among 80 extra batteries).
Medusa.Constants.HARM_DISPROOF_MISS_M = 2500
Medusa.Constants.HARM_DISPROOF_TIME_TO_GO_SEC = 240
Medusa.Constants.HARM_DISPROOF_SLOW_MPS = 400
Medusa.Constants.HARM_DISPROOF_SLOW_TIME_TO_GO_SEC = 150
Medusa.Constants.HARM_DISPROOF_CLOSING_MPS = 20
Medusa.Constants.HARM_DISPROOF_WINDOW_SEC = 8
Medusa.Constants.HARM_DISPROOF_MIN_SCANS = 2
Medusa.Constants.HARM_CONFIRMED_MAX_SEC = 360

-- Gaussian class-conditional model: {arm_mean, arm_sigma, nonArm_mean, nonArm_sigma}
-- Tuned for post-boost DCS HARM (Mach 1-4, ballistic/terminal flight)
Medusa.Constants.HARM_SPRT_MODEL = {
	{ 800, 300, 300, 120 }, -- Speed (m/s): ARM Mach 1-4, fighters up to Mach 1.4
	{ 0.25, 0.35, 0.02, 0.15 }, -- Dive angle (rad): post-apogee, increasingly steep
	{ 0.008, 0.015, 0.040, 0.050 }, -- Heading rate (rad/s): HARMs fly straight
	{ 10, 25, 0, 10 }, -- Accel (m/s^2): gravity-driven gain in dive, positive
	{ 500, 1350, 8000, 6000 }, -- CPA distance (m): tightened ARM σ for long-range sensitivity
	{ -30, 40, -5, 30 }, -- CPA rate (m/s): HARMs converge on emitter
	{ -600, 300, -50, 200 }, -- Range rate (m/s): Mach 1-4 closure, wide σ
	{ -150, 150, -5, 50 }, -- Altitude rate (m/s): post-apogee, consistently descending
}

-- ── Contact evidence (return size, sight recognition) ─────────────
-- What a radar crew can tell about a contact beyond its position and velocity. SensorPollingService builds it from
-- DCS truth in one place (the report boundary); tracks fuse it; HARM detection and alert zones read the fused value.
-- Generic physics only, no per-type table.

Medusa.Constants.SeenAs = {
	AIRCRAFT = "AIRCRAFT",
	HELICOPTER = "HELICOPTER",
	MUNITION = "MUNITION",
}

Medusa.Constants.ContactEvidence = {
	-- getSensors() detectionDistanceAir is this fraction of the range at which the radar first detects a 5 m2 target
	-- (measured on 11 DCS radars: 0.669-0.675).
	REACH_RATIO = 0.668,
	-- Detection range scales with (RCS / 5 m2)^(1/4) (radar equation; measured the same way), so echo strength relative
	-- to the detection threshold is (reach * (RCS/5)^(1/4) / range)^4.
	RCS_REF_M2 = 5,
	-- Fixed per-object shape offset, uniform within +/- this many dB (hashed from the object id): two airframes of
	-- one RCS figure do not return alike. Its standard deviation (3/sqrt(3) = 1.73 dB) is added in quadrature to a
	-- fused size estimate's spread (its floor): averaging looks cannot remove a fixed shape or aspect.
	SHAPE_OFFSET_DB = 3,
	SIZE_SPREAD_FLOOR_DB = 1.732,
	-- Generic aspect curve (smooth in the cosine of the angle between the target's velocity and the line of sight):
	-- nose 1x, beam 5x (7 dB), tail 2x (3 dB), the usual shape of a fighter's or a missile body's RCS pattern.
	ASPECT_BEAM_DB = 7,
	ASPECT_TAIL_DB = 3,
	-- Scan-to-scan fluctuation of one look (Swerling-type target flicker): standard deviation in dB.
	FLICKER_DB = 2.5,
	-- Amplitude measurement error: 10*log10(e) / sqrt(SNR) dB (power estimate with relative error 1/sqrt(SNR)), with
	-- SNR 13 dB (20) at the detection edge, a typical single-look threshold (Pd 0.9 at Pfa 1e-6). Capped.
	AMPLITUDE_ERROR_DB = 4.343,
	SNR_AT_REACH = 20,
	MEASUREMENT_ERROR_MAX_DB = 6,
	-- Amplitude resolution by radar kind, a stand-in for band and processing: long-wave early-warning radars coarse,
	-- SAM search radars medium, engagement radars fine (dB per step; a step adds step^2/12 to a look's variance).
	STEP_DB = { EWR = 6, SAM_SEARCH = 3, SAM_TRACK = 1 },
	-- A crew names a contact (aircraft, helicopter, munition) only when DCS reports its type known AND it is within
	-- this range: generic sight recognition. DCS's type flag belongs to the object (the same in every detection
	-- channel), so it arrives with the radar query and no visual query is made. Recognition through Kub/Buk search
	-- radars at 70 km and the Osa's 32 km is thereby ignored (measured in DCS against a low fighter: Kub/Buk VISUAL
	-- contacts at 8-10 km, the flag at 5.5 km on Tor/Osa/Dog Ear).
	SIGHT_RECOGNITION_RANGE_M = 10000,
	-- Fused estimates hold at most this weight (1/dB^2): a fading memory of roughly the last 20-40 looks. No size
	-- call before the looks' own noise has averaged down to the shape floor (weight 1/1.73^2, about 3 looks).
	SIZE_MAX_WEIGHT = 4,
	SIZE_CONFIDENT_WEIGHT = 1 / 3,
	-- "Small" vs "aircraft-sized": midway in dB between 0.1 m2 (an ARM, SLAM-ER) and 2 m2 (the smallest fighters),
	-- -10 and +3 dBsm. An estimate is confident when estimate +/- CONFIDENCE_K x spread lies on one side. Chosen
	-- by simulating 3,000 objects of each kind through the polling, fusion and call (10 looks each, ranges 20-90%
	-- of detection, every radar kind): an ARM seen only beam-on (-11 + 7 dB beam, +/-3 shape) is ever called
	-- aircraft-sized in 0.2-0.3% of runs; ARMs nose-on end "small" in 84-90%, fighters of
	-- 4-5 m2 "large" in 99.6-100%, 2 m2 fighters nose-on in 75-79% (beam-on 100%); no jet was ever called small.
	SIZE_SPLIT_DBSM = -3.5,
	CONFIDENCE_K = 2.5,
	-- HARM detection prior, in the SPRT's natural-log likelihood-ratio units (one kinematic feature caps at 3, a
	-- whole scan at 4, confirmation needs 4.554). It grows linearly with the distance from the split and reaches its
	-- caps at the reference sizes (0.1 and 2 m2: HARM_SIZE_PRIOR_REF_DB from the split). The positive (ARM-sized) cap is
	-- the SUSPECT threshold and it counts only while the kinematic score alone is at least SUSPECT, so return size
	-- never turns a contact flying like a jet into an ARM: a low-observable jet (smaller than an ARM) diving at a
	-- radar still needs three quarters of the confirm score from its flight. A confident aircraft-sized return counts
	-- as much as a crew's sighting (an ARM is never called aircraft-sized; see SIZE_SPLIT_DBSM) and blocks CONFIRMED
	-- outright (HarmDetectionService updateLabel).
	HARM_SIZE_PRIOR_MAX = Medusa.Constants.HARM_SPRT_THRESH_SUSPECT,
	HARM_SIZE_PRIOR_MIN = -6,
	HARM_SIZE_PRIOR_REF_DB = 6.5,
	HARM_SEEN_AIRCRAFT_PRIOR = -6,
}

-- ── Released stores: no motor, no missile ─────────────────────────
-- A contact first seen just below an aircraft, close to it and moving with it (launch cue or not), may be a store it
-- has just dropped or a missile it has just fired. Specific energy, height + v^2/2g, tells them apart: every ARM in
-- the recorded DCS runs (AGM-88, AGM-45, AGM-122, ALARM, Kh-25MP, Kh-31P, Kh-58) gained at least 15 km of it within
-- 10 s of launch (its motor); no bomb or glide weapon (FAB-250, GBU-31, JSOW, TALD) ever rose more than 60 m above its
-- carrier's energy at separation. TrackManager links such a contact to its carrier when the track is made
-- (Track.Release); while the link is open, and once the contact has shown no motor, HarmDetectionService does not
-- confirm it as an ARM (it may still be SUSPECT or PROBABLE). A later rise in energy still drops the mark. A carrier
-- later confirmed as an ARM frees its children only if it was young when they were linked and has since lost its
-- aircraft evidence. Physics only: no weapon table.
Medusa.Constants.Release = {
	-- The carrier: positive aircraft evidence (a confident aircraft-sized return, or a crew saw an aircraft or
	-- helicopter), no launch cue, not SUSPECT or more, not typed HARM, tracked at least PARENT_MIN_AGE_SEC, its last
	-- look no older than PARENT_MAX_LOOK_AGE_SEC (dead-reckoned to now).
	PARENT_MIN_AGE_SEC = 10,
	PARENT_MAX_LOOK_AGE_SEC = 15,
	-- Released just now: within PARENT_RADIUS_M of the carrier (a fall from rest covers 700 m in 12 s, plus 200 m),
	-- no more than PARENT_MAX_RISE_M above it (a store falls; a jet diving away after a loft release can drop a little
	-- below it), and within PARENT_MAX_DV_MPS of its velocity. Recorded FAB-250s and GBU-31s pass every time 1-4 s
	-- after release and 90-93% at 5-9 s; JSOW and TALD always. Burnt-out ARMs coasting past aircraft late in their
	-- flight (58 samples, 7 flights) passed in 7 samples of 2 flights.
	PARENT_RADIUS_M = 900,
	PARENT_MAX_RISE_M = 150,
	PARENT_MAX_DV_MPS = 150,
	-- The carrier's reference energy: the most it had over its last this-many seconds of history.
	PARENT_ENERGY_WINDOW_SEC = 30,
	-- Rising more than this above the reference is a motor: the link (or the unpowered mark) is dropped for good.
	POWERED_GAIN_M = 3000,
	-- No such rise over at least this many looks spanning at least this long marks the contact unpowered (at 10 s
	-- looks the third look comes 20 s after the first).
	MIN_LOOKS = 3,
	MIN_SPAN_SEC = 10,
	-- A carrier confirmed as an ARM frees its children only when it had been tracked less than this when they were
	-- linked (an ARM's flight) and has since lost its aircraft evidence.
	FREE_MAX_CARRIER_AGE_SEC = 60,
	-- A store first seen too late to link to its aircraft is still not confirmed as an ARM while it falls like a bomb
	-- that cannot reach a radar (HarmDetectionService.observeFall, confirm block "ballistic"). Between two looks, its
	-- acceleration less gravity splits into thrust less drag (along the velocity) and lift (across it). A look counts
	-- when lift is at most BALLISTIC_MAX_LIFT_MPS2 and the along part at most BALLISTIC_MAX_THRUST_MPS2 (a bomb's drag
	-- only slows it), and only while gravity across the velocity (g cos of the flight-path angle) is at least
	-- BALLISTIC_MIN_GCOS_MPS2: a steep dive needs no lift to fly straight, so it cannot tell a bomb from a guided
	-- weapon. An along gain of BALLISTIC_MOTOR_MPS2 is a motor: never ballistic again. BALLISTIC_MIN_LOOKS such looks
	-- in a row, a predicted landing (gravity and the drag seen) at least BALLISTIC_MIN_MISS_M from every battery (one
	-- shut down included), and an aircraft within BALLISTIC_CARRIER_RADIUS_M that had at least the store's energy
	-- height less BALLISTIC_CARRIER_MARGIN_M in its last PARENT_ENERGY_WINDOW_SEC block the confirmation. In DCS an ARM
	-- can coast without lift after its motor burns out: its predicted landing still lies near its radar (an AGM-45),
	-- and a lofted one (a Kh-58) has far more energy than the aircraft near it. A guided bomb's lift (about 8 m/s2 for
	-- a GBU-31) is not ballistic.
	BALLISTIC_MAX_LIFT_MPS2 = 0.75,
	BALLISTIC_MAX_THRUST_MPS2 = 0.5,
	BALLISTIC_MIN_GCOS_MPS2 = 3,
	BALLISTIC_MOTOR_MPS2 = 5,
	BALLISTIC_MIN_LOOKS = 3,
	BALLISTIC_MIN_MISS_M = 3000,
	BALLISTIC_CARRIER_RADIUS_M = 40000,
	BALLISTIC_CARRIER_MARGIN_M = 3000,
}

-- ── Decoy assessment, engage-air-weapons, test shot ──────────────
-- An unpowered decoy (TALD-like) returns like a fighter, so it is told by how it flies: it only loses energy, flies
-- straight legs and never reacts. DecoyAssessmentService keeps the evidence on the track (Track.DecoyAssessment);
-- TargetAssigner, PointDefenseService, alert zones and the engage-air-weapons switch read the label. Numbers are
-- generic glide physics, checked by replaying recorded DCS flights (tests/decoy_dcs_trajectories.lua).

Medusa.Constants.DecoyState = {
	AIRCRAFT = "AIRCRAFT",
	SUSPECT = "SUSPECT",
	PROBABLE = "PROBABLE",
}

Medusa.Constants.Decoy = {
	-- Specific energy h + v^2/2g (m) is regressed over this window; a window needs this span and sample count. When
	-- the newest WINDOW_SEC hold too few looks or too short a span (timer jitter stretches 5 s and 10 s refreshes to
	-- 5.1 s and 10.3 s), older looks are taken back to WINDOW_MAX_SEC (three looks of a 15 s refresh).
	WINDOW_SEC = 20,
	WINDOW_MIN_SPAN_SEC = 16,
	WINDOW_MIN_SAMPLES = 3,
	WINDOW_MAX_SEC = 32,
	-- Sustained loss: the regression slope below -max(LOSS_MPS, speed / GLIDE_RATIO_MAX) (m of energy height per s)
	-- on every scan of a leg whose heading stays within STRAIGHT_LEG_RAD (10 deg) of its first scan. An unpowered
	-- body loses energy height at speed / (lift-to-drag ratio) at least; 14 is a generous best glide for a fighter-
	-- sized body at these speeds (recorded TALDs fly at about 8-10), so a jet in an ordinary descent (1,500 ft/min at
	-- 150 m/s is 1:20) never counts. Recorded DCS flights: no jet held it 90 s; 85% of TALDs did.
	LOSS_MPS = 5,
	GLIDE_RATIO_MAX = 14,
	STRAIGHT_LEG_RAD = math.rad(10),
	SUSPECT_SEC = 60,
	PROBABLE_SEC = 90,
	-- Behavior an unpowered decoy cannot show, judged on two scans in a row (never one): an energy gain (thrust),
	-- a sustained climb (mean vertical speed over the window) or a hard turn (heading rate between scans; recorded
	-- TALDs never exceeded 0.9 deg/s, jets reach 10-20 deg/s).
	GAIN_MPS = 5,
	CLIMB_MPS = 10,
	HARD_TURN_RAD_PER_SEC = math.rad(3),
	DISPROOF_SCANS = 2,
	-- Holding energy is proof of power too: a loss under speed / HOLD_GLIDE_RATIO (flatter than any glide) on every
	-- scan for HOLD_SEC of track time (two windows). And a SUSPECT or PROBABLE contact still flying when any glide
	-- from where it was labeled would be over (its energy height above GLIDE_MIN_SPEED_MPS at ground level, at
	-- GLIDE_RATIO_MAX and that slowest speed) is no glider.
	HOLD_GLIDE_RATIO = 30,
	HOLD_SEC = 40,
	-- Unanswered launches (Medusa's own radar- or command-guided missiles): when a missile's flight of at least
	-- MIN_FLIGHT_SEC ends (AI aircraft react about 18 s before arrival, so a shorter flight proves nothing), its
	-- target and every contact within NEIGHBOUR_RADIUS_M (2 NM) that was scanned at least twice during the flight
	-- and never turned (a turn faster than HARD_TURN_RAD_PER_SEC, the standard-rate turn, between consecutive scans,
	-- adding up to more than STRAIGHT_LEG_RAD: a decoy's slow drift never is one), climbed (REACTION_CLIMB_M) or gained
	-- energy height (REACTION_GAIN_M) gain evidence in seconds of sustained loss: the target full weight, bystanders
	-- half. A reaction is positive aircraft evidence.
	MIN_FLIGHT_SEC = 20,
	MIN_FLIGHT_SCANS = 2,
	NEIGHBOUR_RADIUS_M = 3704,
	REACTION_CLIMB_M = 100,
	REACTION_GAIN_M = 100,
	LAUNCH_EVIDENCE_TARGET_SEC = 30,
	LAUNCH_EVIDENCE_BYSTANDER_SEC = 15,
	LAUNCH_EVIDENCE_MAX_SEC = 60,
	-- Seen as a munition at sight range while returning like an aircraft: strong support, in seconds.
	SEEN_MUNITION_SEC = 30,
	-- Guidance types (Weapon.GuidanceType) whose flight the firing crew follows: active, semi-active radar, command.
	CREW_GUIDED = { [3] = true, [4] = true, [8] = true },
	-- Engage-air-weapons and test-shot decisions look at the battery's capped engagement range plus this margin.
	REACH_MARGIN_M = 10000,
	-- A PROBABLE decoy whose glide is predicted to end within this distance of a battery is a munition threat to it
	-- (one flying over it toward something else is not). Predicted end: along its ground track, the shorter of its
	-- energy glide (energy height above GLIDE_MIN_SPEED_MPS at ground level, at the measured loss rate) and its
	-- present descent carried to the ground.
	GLIDE_THREAT_RADIUS_M = 3000,
	GLIDE_MIN_SPEED_MPS = 100,
	-- Missiles followed per battery, and the longest flight followed before it is taken as over. A full list drops a
	-- flight at an aircraft or a probable decoy first (the engage-air-weapons guard must not forget one at a weapon).
	MAX_MISSILES_IN_FLIGHT = 16,
	MAX_FLIGHT_SEC = 180,
	-- Test shot: one per suspect group (contacts within NEIGHBOUR_RADIUS_M of the target), the battery holds at least
	-- TEST_SHOT_MIN_AMMO, the contact cannot reach the battery's inner engagement edge (its minimum range, else the
	-- battery) before the missile's flight plus margin ends, and a group is not tested again within the cooldown. The
	-- hold is lifted when the flight ends or is no longer followed, when the target is no longer a SUSPECT without
	-- aircraft evidence, when anything else comes within reach, or after TEST_SHOT_MAX_HOLD_SEC at the latest.
	TEST_SHOT_MIN_AMMO = 4,
	TEST_SHOT_MARGIN_SEC = 30,
	TEST_SHOT_COOLDOWN_SEC = 300,
	TEST_SHOT_MAX_HOLD_SEC = 90,
	-- A test-shot missile (held at launch, even if the hold ended early) whose flight ends farther than this from its
	-- live target lost guidance under the hold: no evidence, and no battery of the network with that launcher type
	-- makes test shots again. Proximity-fused SAMs detonate within a few hundred meters of a target they guide on;
	-- measured in DCS, unheld SA-11 misses 126-201 m, held 0.5 s after launch 17.9 km.
	TEST_SHOT_LOST_MISS_M = 2000,
	-- ... but only when the verdict is sound; otherwise no verdict (no evidence, nothing learned): the target was
	-- detected within TEST_SHOT_FRESH_SEC before the missile's last sample (or later), the missile really ended (not
	-- just followed past MAX_FLIGHT_SEC), and it was not about to reach its target: range not decreasing, or still
	-- more than TEST_SHOT_LOST_MIN_TO_GO_SEC to go at its closing speed. Measured in DCS (SA-11): the held missile
	-- lost guidance 17.9 km out still closing at 1134 m/s (15.7 s to go); missiles whose target died first ended
	-- 3.1-4.5 km out with 2.0-3.5 s to go. The freshness window is one SAM_SEARCH refresh (5 s: an SA-11 is no
	-- multi-target engagement radar) plus a pass.
	TEST_SHOT_FRESH_SEC = 6,
	TEST_SHOT_LOST_MIN_TO_GO_SEC = 8,
	-- Batteries whose engage-air-weapons switch is managed (point defense and SHORAD keep it on).
	MANAGED_ROLES = { VLR_SAM = true, LR_SAM = true, MR_SAM = true },
	-- Fire discipline (DecoyFireDiscipline): a HOT long/medium-range battery whose own fire-control radar locks a
	-- probable decoy, or that fires at one, turns engage-air-weapons off for FIRE_HOLD_SEC. Measured in DCS: with
	-- the option off an SA-10 or SA-11 never launched at a TALD, dropped its lock, and kept engaging
	-- an F-16 (11 of 11 hits); the lock came back 10 s (SA-10) to 22 s (SA-11) after the option was back on, often on
	-- the same decoy, so a battery holds at most FIRE_HOLDS_PER_TRACK times per decoy, then engages it.
	-- A hold's time and count start when the option actually goes off (not while its write waits). None past
	-- FIRE_HOLD_BUDGET_SEC of holds in any FIRE_HOLD_BUDGET_WINDOW_SEC, enough to cover a battery under HARM attack
	-- with decoys in the raid. Anti-radiation missiles do not end a hold: the HARM shutdown response and point
	-- defense handle them, and a battery whose holds end when an ARM inbound appears goes back to firing at the
	-- decoys rather than the ARMs (measured in DCS). The fire-control radars are read at most every
	-- FIRE_HOLD_LOCK_READ_SEC; a
	-- decoy's count is forgotten FIRE_HOLD_COUNT_FORGET_SEC after its last hold (longer than any glide).
	FIRE_HOLD_SEC = 20,
	FIRE_HOLDS_PER_TRACK = 3,
	FIRE_HOLD_BUDGET_SEC = 80,
	FIRE_HOLD_BUDGET_WINDOW_SEC = 120,
	FIRE_HOLD_LOCK_READ_SEC = 2,
	FIRE_HOLD_COUNT_FORGET_SEC = 600,
	-- No engage-air-weapons write within this time after the battery's last launch: measured, an SA-11 missile ended
	-- about 2 s after launch when the option was written 0.01-0.03 s after it (twice, at an F-16), and flew on when
	-- the write came 0.7 s or more after it (seven times).
	EAW_WRITE_SETTLE_SEC = 2,
	-- A write kept waiting this long by launches less than EAW_WRITE_SETTLE_SEC apart is logged (ripple fire).
	EAW_WRITE_STARVED_SEC = 10,
}

-- ── Airspace Zones ────────────────────────────────────────────────

Medusa.Constants.ZoneKind = {
	JEZ = "JEZ",
	FEZ = "FEZ",
	FAEZ = "FAEZ",
	MEZ = "MEZ",
	AMBUSH = "AMBUSH",
	PRIORITY_DEFENSE = "PRIORITY_DEFENSE",
	SERVICE_AREA = "SERVICE_AREA",
	FRIENDLY = "FRIENDLY",
}

Medusa.Constants.ZoneGeometryType = {
	CIRCLE = "CIRCLE",
	RECTANGLE = "RECTANGLE",
	POLYGON = "POLYGON",
	POLYLINE_CLOSED = "POLYLINE_CLOSED",
}

Medusa.Constants.Posture = {
	HOT_WAR = "HOT_WAR",
	WARM_WAR = "WARM_WAR",
	COLD_WAR = "COLD_WAR",
}

-- ── Readiness, crew factors and net load ──────────────────────────
-- Readiness (doctrine Readiness) is how ready the crews are, apart from the political Posture: SURPRISED (peacetime
-- routine, nobody expects anything), ALERTED (intel says an attack may come any time: crews at stations, radios
-- manned), ENGAGED (an ongoing conflict, attack more likely than not). It starts at the doctrine value and only rises
-- during the mission. Unset, it follows Posture (HOT_WAR -> ENGAGED, the default). With crew factors on, ENGAGED is
-- the best state of a busy war (fast, reliable reports); with doctrine CrewFactors off, reports and looks use the
-- Observer numbers alone, ignoring skill, readiness and net load.

Medusa.Constants.Readiness = {
	SURPRISED = "SURPRISED",
	ALERTED = "ALERTED",
	ENGAGED = "ENGAGED",
}

Medusa.Constants.ReadinessLevel = {
	[Medusa.Constants.Readiness.SURPRISED] = 0,
	[Medusa.Constants.Readiness.ALERTED] = 1,
	[Medusa.Constants.Readiness.ENGAGED] = 2,
}

Medusa.Constants.ReadinessFromPosture = {
	[Medusa.Constants.Posture.HOT_WAR] = Medusa.Constants.Readiness.ENGAGED,
	[Medusa.Constants.Posture.WARM_WAR] = Medusa.Constants.Readiness.ALERTED,
	[Medusa.Constants.Posture.COLD_WAR] = Medusa.Constants.Readiness.SURPRISED,
}

-- Crew factors (doctrine CrewFactors): crew skill, readiness and net load shape how well the crews' reports work.
-- Medusa's own crew work only (reports, radio, looks); DCS's unit skill already sets how DCS AI aims and detects.
Medusa.Constants.CrewFactors = {
	-- A SURPRISED network turns ALERTED this long after word first spreads (it first holds a HOSTILE track, a hostile
	-- observer report gets through, or it loses a site): the time for a phone call up the chain and back down.
	WORD_SPREADS_MIN_SEC = 120,
	WORD_SPREADS_MAX_SEC = 300,
	-- A loss makes the network ENGAGED once word of it arrives (who saw the site go, a call up the chain), this long
	-- after the loss; the network's own first launch makes it ENGAGED at once.
	WORD_OF_LOSS_MIN_SEC = 30,
	WORD_OF_LOSS_MAX_SEC = 90,
	-- Net load ("chaos", 0..1): the sum of these terms, each count over the count that alone fills the net, capped at
	-- 1. Aircraft tracks held (HOSTILE or BANDIT, not ARMs and not probable decoys), observer reports waiting on the
	-- radio, ARMs inbound, own missiles in flight (each until its expected time to target, at most MISSILE_FLIGHT_SEC,
	-- and MISSILE_FLIGHT_SEC when the launch gives none) and sites lost in the last
	-- LOSS_WINDOW_SEC. A bigger network has more operators and nets: the track, missile and ARM counts that fill it
	-- grow with its sites (SAM, AAA and MANPAD groups and early-warning radar groups) and SAM batteries, never below
	-- the minimums. Calibrated so a small network with a handful of aircraft and one SAM engaging sits near 0.3 and
	-- a wing-scale raid fills it.
	LOAD_FULL_TRACKS_MIN = 32,
	LOAD_FULL_TRACKS_PER_SITE = 1.5,
	LOAD_FULL_MISSILES_MIN = 20,
	LOAD_FULL_MISSILES_PER_SAM = 1,
	LOAD_FULL_ARMS_MIN = 4,
	LOAD_FULL_ARMS_PER_SAM = 0.5,
	LOAD_FULL_PENDING_REPORTS = 25,
	LOAD_FULL_LOSSES = 3,
	MISSILE_FLIGHT_SEC = 60,
	LOSS_WINDOW_SEC = 300,
	-- Loss times kept (oldest overwritten): enough for the window above at any rate that matters. (Missiles in flight
	-- are all kept, until each lands.)
	EVENT_RING_SIZE = 16,
	-- Load rises at once and falls back by this much per second (from full to calm in two minutes).
	LOAD_DECAY_PER_SEC = 1 / 120,
	-- Observer reports. Report made at all (the crew gets the radio working and calls it in), by the crew's skill,
	-- times READINESS_MADE (a surprised crew often never calls).
	REPORT_MADE = { AVERAGE = 0.25, GOOD = 0.5, HIGH = 0.75, EXCELLENT = 0.95 },
	READINESS_MADE = { SURPRISED = 0.6, ALERTED = 1, ENGAGED = 1 },
	-- Radio delay (s) by skill, uniform in { min, max }, times READINESS_DELAY, times Observer.NIGHT_DELAY_FACTOR at
	-- night, plus load x LOAD_DELAY_MAX_SEC (a busy net).
	REPORT_DELAY_SEC = {
		EXCELLENT = { 20, 40 },
		HIGH = { 30, 90 },
		GOOD = { 45, 150 },
		AVERAGE = { 60, 240 },
	},
	READINESS_DELAY = { SURPRISED = 2, ALERTED = 1, ENGAGED = 0.9 },
	LOAD_DELAY_MAX_SEC = 30,
	-- Position error of the report, times Observer.POSITION_ERROR_SEEN_M / HEARD_M, by skill.
	POSITION_ERROR_SCALE = { EXCELLENT = 0.6, HIGH = 0.8, GOOD = 1.0, AVERAGE = 1.4 },
	-- The report reaches the right people: by readiness (a surprised net has nobody listening), times
	-- (1 - LOAD_DELIVERY_PENALTY x load) (chaos), times NIGHT_DELIVERY_FACTOR at night (the extra night loss of the
	-- Observer numbers, LOSS_NIGHT - LOSS_DAY). Sweet spot: ALERTED with a calm net.
	READINESS_DELIVERED = { SURPRISED = 0.6, ALERTED = 0.97, ENGAGED = 0.97 },
	LOAD_DELIVERY_PENALTY = 0.4,
	NIGHT_DELIVERY_FACTOR = 0.9,
	-- A SURPRISED network's crews look for aircraft only one turn in this many (not watching the sky); observer posts
	-- keep every turn (watching is their task).
	SURPRISED_LOOK_EVERY = 2,
	-- Skilled crews shrug off surprise faster: the crew-side SURPRISED penalties (READINESS_MADE.SURPRISED,
	-- READINESS_DELAY.SURPRISED, SURPRISED_LOOK_EVERY) keep this share of their size by the crew's effective skill
	-- (an observer post's one level up). Report made x 0.6 / 0.7 / 0.8 / 0.9, delay x 2 / 1.75 / 1.5 / 1.25, looks
	-- at 50 / 62.5 / 75 / 87.5% of its turns. Delivery (the receiving net) is not scaled.
	SURPRISE_SHARE = { AVERAGE = 1, GOOD = 0.75, HIGH = 0.5, EXCELLENT = 0.25 },
	-- Observer posts (groups named with the "obs"/"observer" token) are trained, dedicated watchers with an assigned
	-- reporting chain: for making a report, its delay and its precision they count one skill level higher
	-- (EXCELLENT stays), and under surprise their reports reach the right people at OBSERVER_SURPRISED_DELIVERED
	-- (they know whom to call) instead of READINESS_DELIVERED.SURPRISED. Gun and SAM crews keep their own skill.
	OBSERVER_SKILL_UP = { AVERAGE = "GOOD", GOOD = "HIGH", HIGH = "EXCELLENT", EXCELLENT = "EXCELLENT" },
	OBSERVER_SURPRISED_DELIVERED = 0.8,
	-- Track identification takes longer on a busy net: dwell timers x (1 + ID_DWELL_LOAD_FACTOR x load).
	ID_DWELL_LOAD_FACTOR = 0.5,
}

-- ── Interceptor Operations ────────────────────────────────────────

Medusa.Constants.GciServicePolicy = {
	CLOSEST_AIRBASE = "CLOSEST_AIRBASE",
	MOST_LETHAL_INTERCEPTOR = "MOST_LETHAL_INTERCEPTOR",
	ROUND_ROBIN = "ROUND_ROBIN",
	AIRBASE_PRIORITY_ORDER = "AIRBASE_PRIORITY_ORDER",
}

Medusa.Constants.InterceptorLaunchAuthorityPolicy = {
	LOCAL_AUTONOMY = "LOCAL_AUTONOMY",
	REQUIRE_GCI_APPROVAL = "REQUIRE_GCI_APPROVAL",
	CENTRALIZED = "CENTRALIZED",
}

Medusa.Constants.InterceptorGroupTask = {
	INTERCEPT = "INTERCEPT",
}

Medusa.Constants.InterceptorGroupStatus = {
	SPAWNING = "SPAWNING",
	ACTIVE = "ACTIVE",
	ENGAGING = "ENGAGING",
	RTB_FUEL = "RTB_FUEL",
	RTB_WINCHESTER = "RTB_WINCHESTER",
	RTB_COMMANDED = "RTB_COMMANDED",
	LANDED = "LANDED",
	REARMING = "REARMING",
	AVAILABLE = "AVAILABLE",
	DESTROYED = "DESTROYED",
}

-- ── Local cueing radars ───────────────────────────────────────────
-- A search radar in a group without missile launchers whose reach is short (a Dog Ear-style local warning radar) is
-- managed as a local cueing radar (doctrine LocalCueingRadars): dark unless a threat is near the units it supports,
-- refreshed at the SAM search rate when up, and its contacts cue the MANPAD and AAA crews in its reach.

Medusa.Constants.LocalRadar = {
	-- Reach against a 5 m2 target (probed getSensors range / ContactEvidence.REACH_RATIO) below which a launcher-less
	-- search radar is local. Measured reaches: Dog Ear 35 km, Roland and NASAMS radars 35-40 km, P-19 80 km, 1L13
	-- 300 km.
	MAX_REACH_M = 50000,
	-- The radar comes up while a hostile in the network picture is within its reach plus this margin: what a jet at
	-- 250 m/s covers in the minute the radar needs to come up and see it.
	THREAT_MARGIN_M = 15000,
	-- Once up, it stays up at least this long after its last reason (no flicker on a contact at the margin).
	HOLD_SEC = 60,
	-- An observer report or the crew's own sighting keeps a reason alive this long.
	CUE_HOLD_SEC = 120,
	-- Its contacts cue MANPAD and AAA crews in its reach at most this often, around the nearest aircraft it holds.
	CUE_INTERVAL_SEC = 5,
	-- MANPAD and AAA crews within this distance of a cued contact are told to look for it (the MANPAD wake radius).
	CUE_RADIUS_M = 10000,
	-- A cued AAA crew scans all round with its full visual range and hears better for this long.
	AAA_CUE_SEC = 120,
	-- Local radars evaluated per pass (one pass a second; a radar is evaluated at most once a pass).
	EVALS_PER_PASS = 10,
	-- A hostile found near a lit radar is looked for again (a grid query) only after this long; the radar stays up.
	THREAT_RECHECK_SEC = 10,
	-- A local radar no other ground radar of the network covers (and no AWACS) would be blind until a crew reports:
	-- it sweeps briefly on its own, SWEEP_MIN..MAX_SEC every SWEEP_EVERY_MIN..MAX_SEC (random, so sweeps cannot be
	-- timed), unless doctrine LocalRadarSweeps is off or the mission's EMCON for its role is MINIMIZE. DCS radars
	-- report a target within 0.1 s of switching on, so 10 s gives
	-- at least two polls at the SAM search rate.
	SWEEP_MIN_SEC = 10,
	SWEEP_MAX_SEC = 20,
	SWEEP_EVERY_MIN_SEC = 180,
	SWEEP_EVERY_MAX_SEC = 300,
}

-- ── Observer reports ──────────────────────────────────────────────
-- Crews of managed ground groups, and groups named with the observer role token, report low aircraft they see or
-- hear by radio. A report is coarse, arrives after a radio delay and may be lost; it cues MANPAD and AAA crews, wakes
-- local radars and can bring a dark SAM battery up WARM (radar on, weapons hold). It is never a track: it gives no
-- firing solution and alert zones do not count it. Generic numbers, no per-type table.

-- Sight from the ground, shared by radar crews (ContactEvidence.SIGHT_RECOGNITION_RANGE_M) and observers
-- (Observer.VISUAL_RANGE_DAY_M): both are day figures, scaled by the light and capped by the mission's weather
-- (visibility, fog, dust), read once at load. Clouds are not modeled.
Medusa.Constants.Sight = {
	-- At night (IsNightTime: 19:00-07:00) unaided eyes see a dark aircraft at a quarter of the day distance.
	NIGHT_FACTOR = 0.25,
	-- A crew tells friend from foe, and the type, only within this fraction of its sight distance: DCS's own rule
	-- for AI eyes (Detection.lua recognition_distance_ratio_threshold).
	RECOGNITION_RATIO = 0.25,
	-- The time of day is read again this often.
	LIGHT_REFRESH_SEC = 60,
}

Medusa.Constants.Observer = {
	-- Day visual range for an aircraft: DCS's own reference distances (Scripts/AI/Detection.lua, excellent skill, sky
	-- background) are 7.5 km for fighters, 6.5 km for helicopters and 9.5 km for bombers; a crew that is not
	-- searching a known sector does no better. Scaled by Sight (2 km at night, less in fog); sight needs terrain line
	-- of sight from eye height. Friend or foe and the type are told within Sight.RECOGNITION_RATIO of it (2 km by
	-- day): an aircraft seen farther off, or only heard, is reported unidentified, own aircraft included.
	VISUAL_RANGE_DAY_M = 8000,
	EYE_HEIGHT_M = 2,
	-- Hearing: a low aircraft (jet or helicopter) is heard within a few km whatever the terrain in between.
	HEARING_RANGE_M = 3000,
	HEARING_MAX_HEIGHT_M = 1000,
	-- Coarse report fields: height above the observer (alert-zone bands), speed class, position error and rounding.
	LOW_MAX_M = 1000,
	HIGH_MIN_M = 6000,
	FAST_MIN_MPS = 150,
	POSITION_ERROR_SEEN_M = 1000,
	POSITION_ERROR_HEARD_M = 2500,
	POSITION_ROUND_M = 500,
	-- Budget: observer looks per second per network, round-robin, at most one per network tick. With 50 observers
	-- each looks every 12.5 s; a jet at 250 m/s crossing a day sight circle within 6 km of the observer is in view at
	-- least 42 s (3 looks), so it is missed only by geometry or terrain; at night (2 km) a crossing lasts about 16 s
	-- and with 100+ observers a revisit (25 s) can miss it. A look's world search stops after MAX_VISITED objects
	-- (ground units cost one category check each), MAX_CANDIDATES aircraft and MAX_SIGHT_CHECKS line-of-sight tests.
	LOOKS_PER_SEC = 4,
	MAX_VISITED = 200,
	MAX_CANDIDATES = 8,
	MAX_SIGHT_CHECKS = 4,
	-- An observer sends at most one report a minute (it names the nearest aircraft and how many it saw or heard).
	REPORT_INTERVAL_SEC = 60,
	-- Radio delay: uniform DELAY_MIN..MAX s by day, times NIGHT_DELAY_FACTOR at night, plus BUSY_DELAY_SEC for each
	-- report already waiting on the net (up to BUSY_DELAY_MAX_SEC): 30 s to about 4 minutes.
	DELAY_MIN_SEC = 30,
	DELAY_MAX_SEC = 90,
	NIGHT_DELAY_FACTOR = 1.5,
	BUSY_DELAY_SEC = 10,
	BUSY_DELAY_MAX_SEC = 120,
	-- Reports that never arrive: 10% by day, 20% at night, plus 2% for each report waiting (at most 50%); a report
	-- that finds the net full (MAX_PENDING waiting) is lost.
	LOSS_DAY = 0.10,
	LOSS_NIGHT = 0.20,
	LOSS_PER_PENDING = 0.02,
	LOSS_MAX = 0.5,
	MAX_PENDING = 32,
	-- A delivered report cues MANPAD and AAA crews within LocalRadar.CUE_RADIUS_M of the reported position and keeps
	-- local radars whose reach plus LocalRadar.THREAT_MARGIN_M covers it up. A report of a hostile (identified by
	-- sight) also brings a COLD SAM battery of a WAKE_ROLES role, with a search radar, whose engagement range plus
	-- WAKE_MARGIN_M covers it up WARM for WARM_HOLD_SEC, but only when the network holds no track within
	-- TRACK_NEAR_M of the report (what a jet covers in a minute, the usual radio delay) and the mission sets no EMCON
	-- policy for the battery's role (doctrine EMCON: an ambush site set to MINIMIZE stays dark). The crew's own
	-- sighting (local initiative) follows the same rules. Delivered reports are kept for KEEP_SEC (diagnostics),
	-- then their entries are reused.
	WAKE_MARGIN_M = 10000,
	WAKE_ROLES = { SR_SAM = true, MR_SAM = true },
	TRACK_NEAR_M = 15000,
	WARM_HOLD_SEC = 120,
	KEEP_SEC = 180,
	-- The roster of observing groups is rebuilt from the stores this often.
	ROSTER_REFRESH_SEC = 30,
}

Medusa.Constants.ObserverReportState = {
	PENDING = "PENDING",
	DELIVERED = "DELIVERED",
	FREE = "FREE",
}

-- ── Local aircraft detection ──────────────────────────────────────

Medusa.Constants.LocalAircraftDetection = {
	PRIMARY_COS_HALF_ANGLE = 0.866,
	PRIMARY_RANGE_M = 8000,
	RELATIVE_ALTITUDE_CEILING_M = 3048,
	SCAN_QUOTA_PER_SEC = 2,
	TARGET_CACHE_TTL_SEC = 3,
	TARGET_CACHE_CAPACITY = 8,
	POSITION_REFRESH_MIN_INTERVAL_SEC = 60,
	POSITION_REFRESH_TICK_INTERVAL = 5,
}

-- ── MANPAD ────────────────────────────────────────────────────────

Medusa.Constants.Manpad = {
	SleepWakeState = {
		ASLEEP = "ASLEEP",
		ALERTING = "ALERTING",
		ALERT = "ALERT",
		HOT = "HOT",
		COOLDOWN = "COOLDOWN",
	},
	DetectionMode = {
		NONE = "NONE",
		NARROW = "NARROW",
		FULL = "FULL",
	},
	WakeReason = {
		NONE = "NONE",
		IADS = "IADS",
		AUDIO = "AUDIO",
		VISUAL = "VISUAL",
		NEIGHBOR = "NEIGHBOR",
		REARM = "REARM",
		RECOVERY = "RECOVERY",
		LOCAL_RADAR = "LOCAL_RADAR",
		OBSERVER = "OBSERVER",
	},

	COS_NARROW = Medusa.Constants.LocalAircraftDetection.PRIMARY_COS_HALF_ANGLE,
	COS_WIDE = 0.0,
	NARROW_RANGE_M = Medusa.Constants.LocalAircraftDetection.PRIMARY_RANGE_M,
	WIDE_RANGE_FACTOR = 0.5,

	AUDIO_RANGE_MIN_M = 0,
	AUDIO_RANGE_MAX_M = 6000,

	REL_ALT_CEIL_M = Medusa.Constants.LocalAircraftDetection.RELATIVE_ALTITUDE_CEILING_M,

	FIRST_WAKE_MIN_SEC = 30,
	FIRST_WAKE_MAX_SEC = 300,
	WAKE_MIN_SEC = 10,
	WAKE_MAX_SEC = 30,
	HOT_MIN_SEC = 300,
	HOT_MAX_SEC = 900,
	COOLDOWN_SEC = 900,
	ALERT_TIMEOUT_SEC = 900,

	DEFAULT_FIELD_RADIO_RANGE_M = 5000,
	MAX_FIELD_RADIO_RANGE_M = 50000,
	NEIGHBOR_WAKE_MIN_SEC = 15,
	NEIGHBOR_WAKE_MAX_SEC = 60,

	GEOGRID_QUERY_RADIUS_M = 10000,
	AUTONOMOUS_SCAN_QUOTA_PER_SEC = Medusa.Constants.LocalAircraftDetection.SCAN_QUOTA_PER_SEC,
	AUTONOMOUS_TARGET_CACHE_TTL_SEC = Medusa.Constants.LocalAircraftDetection.TARGET_CACHE_TTL_SEC,
	AUTONOMOUS_TARGET_CACHE_CAPACITY = Medusa.Constants.LocalAircraftDetection.TARGET_CACHE_CAPACITY,

	POS_REFRESH_MIN_INTERVAL_SEC = Medusa.Constants.LocalAircraftDetection.POSITION_REFRESH_MIN_INTERVAL_SEC,
	POS_REFRESH_TICK_INTERVAL = Medusa.Constants.LocalAircraftDetection.POSITION_REFRESH_TICK_INTERVAL,
}

-- ── AAA ───────────────────────────────────────────────────────────

Medusa.Constants.Aaa = {
	Mode = {
		INDEPENDENT = "INDEPENDENT",
		RADAR_DIRECTED = "RADAR_DIRECTED",
	},
	ResponseState = {
		IDLE = "IDLE",
		ALERT = "ALERT",
		AREA_FIRE = "AREA_FIRE",
		BARRAGE_FIRE = "BARRAGE_FIRE",
		BARRAGE_PAUSE = "BARRAGE_PAUSE",
		LOCAL_ACQUISITION = "LOCAL_ACQUISITION",
	},
	DEFAULT_AUDIO_RANGE_M = 6000,
	MAX_AUDIO_RANGE_M = 20000,
	DEFAULT_AREA_FIRE_CHANCE = 0.20,
	DEFAULT_BARRAGE_CHANCE = 0.25,
	AUDIO_DETECTION_CHANCE = 0.35,
	AUDIO_RETRY_SEC = 10,
	REACTION_DELAY_SEC = 15,
	AREA_FIRE_DURATION_SEC = 30,
	BARRAGE_DURATION_SEC = 600,
	BARRAGE_BURST_MIN_SEC = 10,
	BARRAGE_BURST_MAX_SEC = 15,
	BARRAGE_PAUSE_MIN_SEC = 10,
	BARRAGE_PAUSE_MAX_SEC = 15,
	BARRAGE_ERROR_M = 3000,
	BARRAGE_PROPAGATION_RANGE_M = 5 * 1852,
	BARRAGE_PROPAGATION_DELAY_MIN_SEC = 10,
	BARRAGE_PROPAGATION_DELAY_MAX_SEC = 20,
	BARRAGE_PROPAGATION_DEBOUNCE_SEC = 20,
	DEFAULT_MAX_BARRAGE_GROUPS = 15,
	MAX_BARRAGE_GROUPS = 100,
	LOCAL_ACQUISITION_DURATION_SEC = 180,
	AREA_FIRE_ERROR_M = 500,
	AREA_FIRE_RADIUS_M = 500,
	AREA_FIRE_LEAD_MIN_SEC = 5,
	AREA_FIRE_LEAD_MAX_SEC = 20,
	MIN_AIM_AGL_M = 100,
}
