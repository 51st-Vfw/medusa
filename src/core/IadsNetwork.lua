require("_header")
require("core.Core")
require("core.Config")
require("core.Logger")
require("services.DiscoveryService")
require("services.HierarchyService")
require("services.TrackManager")
require("services.TrackDisplayIdAllocator")
require("entities.Battery")
require("entities.Track")
require("services.stores.BatteryStore")
require("services.SensorPollingService")
require("services.TargetAssigner")
require("services.TrackClassifier")
require("services.BatteryActivationService")
require("services.EmconService")
require("services.ManpadService")
require("services.AaaService")
require("services.CrewSuppressionService")
require("services.CrewPerceptionService")
require("services.HarmDetectionService")
require("services.HarmResponseService")
require("services.DecoyAssessmentService")
require("services.DecoyResponseService")
require("services.LocalRadarService")
require("services.ObserverReportService")
require("entities.ObserverPost")
require("services.stores.ObserverPostStore")
require("services.EntityFactory")
require("services.AssetIndex")
require("services.GeospatialIndexService")
require("services.stores.SensorUnitStore")
require("services.SensorProbingService")
require("services.stores.C2NodeStore")
require("services.stores.AirspaceZoneStore")
require("services.stores.AirbaseStore")
require("services.stores.InterceptorGroupStore")
require("entities.Doctrine")
require("services.PointDefenseService")
require("services.MetricsService")
require("services.BlackBoxService")
require("services.MetricsSnapshotService")
require("core.Chance")
require("core.Debrief")
require("services.CrewFactorsService")
require("services.EsmService")

--[[
            ██╗ █████╗ ██████╗ ███████╗    ███╗   ██╗███████╗████████╗██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗
            ██║██╔══██╗██╔══██╗██╔════╝    ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝
            ██║███████║██║  ██║███████╗    ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║██║   ██║██████╔╝█████╔╝
            ██║██╔══██║██║  ██║╚════██║    ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██║   ██║██╔══██╗██╔═██╗
            ██║██║  ██║██████╔╝███████║    ██║ ╚████║███████╗   ██║   ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗
            ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝    ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝

    What this module does
    - Runs the main tick loop that drives every IADS service on a fixed interval.
    - Coordinates discovery, sensor polling, track management, target assignment, EMCON, and HARM response.
    - Manages world event subscriptions for unit death, weapon fire, and kill tracking.

    How others use it
    - The Entrypoint creates one IadsNetwork per configured network and calls initialize/start.
    - ApiService looks up network instances by ID to change doctrine at runtime.
]]

---@class Medusa.Core.IadsNetwork
---@field _logger table
---@field _discovery Medusa.Services.DiscoveryService
---@field _hierarchy Medusa.Services.HierarchyService
---@field _initialized boolean
---@field _running boolean
---@field _tickCounter number
---@field _lastScanTime number
---@field new fun(self: Medusa.Core.IadsNetwork): Medusa.Core.IadsNetwork
---@field initialize fun(self: Medusa.Core.IadsNetwork): boolean
---@field start fun(self: Medusa.Core.IadsNetwork): boolean
---@field stop fun(self: Medusa.Core.IadsNetwork): boolean
---@field tick fun(self: Medusa.Core.IadsNetwork)
---@field getHierarchy fun(self: Medusa.Core.IadsNetwork): Medusa.Services.HierarchyService

Medusa.Core.IadsNetwork = {}

Medusa.Core.IadsNetwork._assignBatteryBuffer = {}
local _assignBatteryBuffer = Medusa.Core.IadsNetwork._assignBatteryBuffer

local function isShipGroupCategory(groupCategory)
	local shipCategory = Group and Group.Category and Group.Category.SHIP
	return groupCategory == shipCategory or string.upper(tostring(groupCategory)) == "SHIP"
end

local function trackSourceForSensor(sensor)
	if isShipGroupCategory(sensor and sensor.GroupCategory) then
		return Medusa.Constants.TrackSource.SHIPBORNE_RADAR
	end
	if sensor and sensor.SensorType == Medusa.Constants.SensorType.AWACS then
		return Medusa.Constants.TrackSource.AWACS
	end
	if sensor and sensor.IsAirborne then
		return Medusa.Constants.TrackSource.AIRBORNE_DATALINK
	end
	return Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
end

--- Track refresh interval for a sensor group's reports; nil means doctrine PerTrackScanUpdateRate.
function Medusa.Core.IadsNetwork._scanRateForSensor(doctrine, sourceType)
	if sourceType == Medusa.Constants.TrackSource.EARLY_WARNING_RADAR then
		return Medusa.Services.SensorPollingService.scanRateFor(doctrine, "EWR")
	end
	return nil
end

--- Track refresh interval for a battery's reports: a HOT multi-target engagement radar keeps every track it holds
--- fresh; a search radar or a single-target tracker refreshes at the search rate. Ships use the doctrine default.
function Medusa.Core.IadsNetwork._scanRateForBattery(doctrine, battery, sourceType)
	if sourceType ~= Medusa.Constants.TrackSource.SAM_BATTERY then
		return nil
	end
	local hot = battery.ActivationState == Medusa.Constants.ActivationState.STATE_HOT
	if hot and (battery.HarmCapableUnitCount or 0) > 0 then
		return Medusa.Services.SensorPollingService.scanRateFor(doctrine, "SAM_TRACK")
	end
	return Medusa.Services.SensorPollingService.scanRateFor(doctrine, "SAM_SEARCH")
end

--- Radar kind of a battery for contact evidence (SCAN_UPDATE_RATE_DEFAULTS keys): a HOT multi-target engagement
--- radar is SAM_TRACK, any other SAM or ship radar SAM_SEARCH.
function Medusa.Core.IadsNetwork._radarKind(battery)
	local hot = battery.ActivationState == Medusa.Constants.ActivationState.STATE_HOT
	if hot and (battery.HarmCapableUnitCount or 0) > 0 then
		return "SAM_TRACK"
	end
	return "SAM_SEARCH"
end

local TS_EWR = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
local TS_SAM = Medusa.Constants.TrackSource.SAM_BATTERY

local function trackSourceForBattery(battery)
	if isShipGroupCategory(battery.GroupCategory) then
		return Medusa.Constants.TrackSource.SHIPBORNE_RADAR
	end
	return Medusa.Constants.TrackSource.SAM_BATTERY
end

--- ChunkStep: queue-based chunked work processor.
--- Fills from a snapshot when drained, processes up to budget items per tick.
--- Items that fail the isValid check are silently skipped on dequeue.
local ChunkStep = {}
ChunkStep.__index = ChunkStep

function ChunkStep.new(budget, isValid)
	return setmetatable({ _queue = Queue(), budget = budget, _isValid = isValid }, ChunkStep)
end

function ChunkStep:fill(items)
	if not self._queue:isEmpty() then
		return false
	end
	for i = 1, #items do
		self._queue:enqueue(items[i])
	end
	return true
end

function ChunkStep:next()
	while not self._queue:isEmpty() do
		local item = self._queue:dequeue()
		if not self._isValid or self._isValid(item) then
			return item
		end
	end
	return nil
end

function ChunkStep:isEmpty()
	return self._queue:isEmpty()
end

function ChunkStep:remaining()
	return self._queue:size()
end

local _chunkLabels = {
	classify = { phase = "classify" },
	harm_detect = { phase = "harm_detect" },
	handoff = { phase = "handoff" },
	deactivation = { phase = "deactivation" },
}

local _phaseLabels = {
	[0] = { phase = "classify" },
	{ phase = "harm" },
	{ phase = "assign" },
	{ phase = "maintain" },
	{ phase = "emcon" },
}

local _LS = Medusa.Constants.TrackLifecycleState
-- Networks started together tick in the same frames; each later one shifts its periodic phases by one tick so
-- their heavy phases do not land in the same frame.
local _runningNetworkCount = 0
local function _isTrackAlive(track)
	return track and track.LifecycleState == _LS.ACTIVE
end

local function logChunk(logger, MS, phaseName, processed, remaining)
	if Medusa.Logger._level == "DEBUG" or Medusa.Logger._level == "TRACE" then
		logger:debug(string.format("phase %s: processed %d, queued %d", phaseName, processed, remaining))
	end
	local labels = _chunkLabels[phaseName]
	MS.set("medusa_chunk_processed", processed, labels)
	MS.set("medusa_chunk_queued", remaining, labels)
end

function Medusa.Core.IadsNetwork:new(opts)
	local o = {
		_id = opts and opts.id or "IADS",
		_coalitionId = opts and opts.coalitionId,
		_prefix = opts and opts.prefix,
		_doctrineKey = opts and opts.doctrine,
		_logger = nil,
		_discovery = nil,
		_hierarchy = Medusa.Services.HierarchyService:new(),
		_initialized = false,
		_running = false,
		_trackManager = nil,
		_assetIndex = nil,
		_spatialIndex = nil,
		_doctrine = nil,
		_sensorPollingService = nil,
		_sensorPollIndex = 1,
		_sensorPollBudget = 3,
		_assignmentInterval = 2,
		_manpadInterval = 10,
		_manpadCtx = {},
		_aaaInterval = 10,
		-- Local cueing radars (LocalRadarService state) and the radar+guns groups waiting for their radar's reach.
		_localRadars = Medusa.Services.LocalRadarService.newState(),
		_observers = Medusa.Services.ObserverReportService.newState(),
		-- Listening stations' bearings and fixes (EsmService state).
		_esm = Medusa.Services.EsmService.newState(),
		-- Readiness and net load (CrewFactorsService state; made with the doctrine at initialize).
		_crew = nil,
		-- ARMs inbound (tracks assessed HARM) and aircraft tracks (HOSTILE or BANDIT, not ARMs, not probable decoys),
		-- counted by the HARM phase's priority pass for the net load.
		_armsInbound = 0,
		_aircraftTracks = 0,
		-- When the net load's capacities were last sized from the network's sites (CrewFactorsService.setNetworkSize).
		_crewSizedAt = nil,
		-- Launcher DCS type names whose test-shot missile lost guidance under weapons hold (learned at run time): no
		-- battery of the network makes test shots with such a launcher (DecoyResponseService).
		_holdBreaksTypes = {},
		_localPictureInterval = 10,
		_localCtx = {},
		_deferredGroups = {},
		_localRadarsDirty = false,
		_probeComplete = false,
		_fastErectDone = false,
		_unitPosRefreshInterval = Medusa.Constants.LocalAircraftDetection.POSITION_REFRESH_TICK_INTERVAL,
		-- IadsNetwork fills this table before each AaaService operation.
		_aaaCtx = {},
		_aaaBarrageState = opts and opts.aaaBarrageState or Medusa.Services.AaaService.newBarrageState(),
		_assignmentPhase = 0,
		_tickCounter = 0,
		_lastScanTime = 0,
		_pollDetectionAccum = {},
		_lastAssetLogTime = 0,
		_assetLogIntervalSec = 300,
		_timerId = nil,
		_tickIntervalSec = (opts and opts.tick) or 0.1,
		_probingService = nil,
		_deathQueue = nil,
		_shotQueue = nil,
		_killQueue = nil,
		_hitQueue = nil,
		_hitSubscriptionId = nil,
		_hitEventBus = nil,
		_terminalEventQueue = RingBuffer(Medusa.Constants.CrewSuppression.IMPACT_QUEUE_CAPACITY, false),
		_activeTerminalEvent = nil,
		_terminalUnitBuffer = {},
		_blackBoxWeaponStore = opts and opts.blackBoxWeaponStore,
		_blackBoxTerminalSink = opts and opts.blackBoxTerminalSink,
		_crewSkillIndex = opts and opts.crewSkillIndex,
		_crewSuppressionCtx = {},
		_networkedGeoGrid = nil,
		_maxEngagementRange = 0,
		_erectComplete = false,
		_classifyStep = nil,
		_harmDetectStep = nil,
		_handoffStep = nil,
		_deactivationStep = nil,
		_borderZoneNames = opts and opts.borderZones or {},
		_borderPolygons = {},
		_borderPolygonsLL = {},
		_adizPolygon = nil,
		_tickFailures = 0,
		_phaseFailures = {},
		_harmSortBuffer = {},
		_harmPriorityKeys = {},
		_phaseOffset = 0,
		_harmNormalBuffer = {},
		_ctx = {},
	}
	o._metricLabels = { network = o._id }
	o._logger = Medusa.Logger:ns(string.format("%s | Core.IadsNetwork", tostring(o._id)))
	o._discovery = Medusa.Services.DiscoveryService:new(nil, {
		id = o._id,
		coalitionId = o._coalitionId,
		prefix = o._prefix,
	})
	setmetatable(o, { __index = self })
	o._tickCallback = function()
		o:_onTick()
	end
	if o._coalitionId == nil then
		error("IadsNetwork:new requires coalitionId", 0)
	end
	if not o._prefix or #tostring(o._prefix) == 0 then
		error("IadsNetwork:new requires prefix", 0)
	end
	return o
end

function Medusa.Core.IadsNetwork:initialize()
	if self._initialized then
		return true
	end
	self._logger:info(
		string.format("config: coalitionId=%s, prefix='%s'", tostring(self._coalitionId), tostring(self._prefix))
	)

	local batteryRepository = Medusa.Services.BatteryStore:new()
	local batteryStore = batteryRepository:batteries()
	local manpadStore = batteryRepository:manpads()
	local sensorStore = Medusa.Services.SensorUnitStore:new()
	local c2NodeStore = Medusa.Services.C2NodeStore:new()
	local zoneStore = Medusa.Services.AirspaceZoneStore:new()
	local airbaseStore = Medusa.Services.AirbaseStore:new()
	local interceptorStore = Medusa.Services.InterceptorGroupStore:new()
	local observerStore = Medusa.Services.ObserverPostStore:new()

	self._spatialIndex = Medusa.Services.GeospatialIndexService:new(10000)
	self._networkedGeoGrid = self._spatialIndex:networkedGeoGrid()
	self._trackManager = Medusa.Services.TrackManager:new({
		geoGrid = self._networkedGeoGrid,
		displayIdAllocator = Medusa.Services.TrackDisplayIdAllocator.shared(),
	})

	self._assetIndex = Medusa.Services.AssetIndex.new({
		batteryRepository = batteryRepository,
		sensors = sensorStore,
		batteries = batteryStore,
		manpads = manpadStore,
		c2Nodes = c2NodeStore,
		zones = zoneStore,
		airbases = airbaseStore,
		interceptors = interceptorStore,
		observers = observerStore,
		tracks = self._trackManager:getStore(),
		networkedGeoGrid = self._networkedGeoGrid,
		localGeoGrid = self._spatialIndex:localGeoGrid(),
		suppressibleUnitGeoGrid = self._spatialIndex:suppressibleUnitGeoGrid(),
		spatialIndex = self._spatialIndex,
	})

	self._probingService = Medusa.Services.SensorProbingService:new(self._coalitionId)
	self._doctrine = Medusa.Config:getDoctrine(self._doctrineKey)
	self._trackManager:setEvidenceReacquisition(self._doctrine.EvidenceReacquisition ~= false)
	self._crew = Medusa.Services.CrewFactorsService.newState(self._doctrine)
	local network = self
	self._trackManager:getStore().onIdentified = function(track, from, to)
		network:_onTrackIdentified(track, from, to)
	end
	if Medusa.Chance.isTraining(self._doctrine) then
		self._logger:info("training mode: sensing, identification and reports are deterministic")
		Medusa.Debrief.emit(self._id, GetTime(), "TRAINING_MODE", "on", "true")
	end
	self._aaaCtx.onModeChanged = function(battery, mode)
		if mode == Medusa.Constants.Aaa.Mode.RADAR_DIRECTED then
			network:_updateMaxEngagementRange(battery)
		end
		network._pdReassignNeeded = true
	end
	-- Point-defence assignment skips crew-suppressed batteries; relink when one recovers.
	self._crewSuppressionCtx.onRecovered = function()
		network._pdReassignNeeded = true
	end
	Medusa.Services.AaaService.setBarrageLimit(self._aaaBarrageState, self._id, self._doctrine.AAA.MaxBarrageGroups)

	local cfg = Medusa.Config:get()
	self._classifyStep = ChunkStep.new(cfg.ChunkBudgetTracks, _isTrackAlive)
	self._harmDetectStep = ChunkStep.new(cfg.ChunkBudgetHarm, _isTrackAlive)
	self._handoffStep = ChunkStep.new(cfg.ChunkBudgetBatteries)
	self._deactivationStep = ChunkStep.new(cfg.ChunkBudgetBatteries)
	self._rollingPkBuffer = {}
	self._rollingPkIndex = 0
	self._rollingPkCount = 0
	self._effectivePkFloor = self._doctrine.PkFloor
	self._lastRollingPkEventTime = 0
	self._sensorPollingService = Medusa.Services.SensorPollingService:new(self._doctrine)
	self:_logDoctrine()

	local harmSystems = {}
	for i = 1, #Medusa.Constants.HARM_CAPABLE_SYSTEMS do
		harmSystems[i] = Medusa.Constants.HARM_CAPABLE_SYSTEMS[i]
	end
	-- selene: allow(undefined_variable)
	local userConfig = (type(MEDUSA_CONFIG) == "table") and MEDUSA_CONFIG or {}
	if userConfig.HarmCapableSystems then
		for i = 1, #userConfig.HarmCapableSystems do
			harmSystems[#harmSystems + 1] = userConfig.HarmCapableSystems[i]
		end
	end
	self._harmCapableSystems = harmSystems

	self:_attachDiscoveryListener()
	self:_subscribeWorldEvents()

	if #self._borderZoneNames > 0 then
		local AirspaceService = Medusa.Services.AirspaceService
		self._borderPolygons = AirspaceService.discover(self._borderZoneNames)
		self._logger:info(
			string.format("border zones: %d configured, %d discovered", #self._borderZoneNames, #self._borderPolygons)
		)
		if #self._borderPolygons > 0 then
			self._borderPolygonsLL = AirspaceService.convertToLatLon(self._borderPolygons)
			if self._doctrine.ADIZEnabled then
				self._adizPolygon = AirspaceService.computeADIZ(self._borderPolygons, self._doctrine.ADIZBufferNm)
				if self._adizPolygon then
					self._logger:info(
						string.format(
							"ADIZ: %d vertices, buffer=%.0fnm",
							#self._adizPolygon,
							self._doctrine.ADIZBufferNm
						)
					)
				end
			end
		end
	end

	self._initialized = true

	local netLabel = { "network" }
	Medusa.Services.MetricsSnapshotService.register(netLabel)

	local initTime = GetTime()
	self._lastScanTime = initTime - 1
	self._lastAssetLogTime = initTime - self._assetLogIntervalSec + 30
	self._logger:info("initialized")
	return true
end

function Medusa.Core.IadsNetwork:start()
	if not self._initialized then
		self:initialize()
	end
	if self._running then
		return true
	end
	self:_subscribeSuppressionEvents()
	self._running = true
	self._phaseOffset = _runningNetworkCount
	_runningNetworkCount = _runningNetworkCount + 1
	Medusa.Services.CrewSuppressionService.resume(self:_updateCrewSuppressionContext(GetTime()))
	self._logger:info("started")
	self._discovery:enableDynamicAdds()
	self:_onTick()
	return true
end

function Medusa.Core.IadsNetwork:_releaseLocalDefenses()
	if not self._assetIndex then
		return
	end
	Medusa.Services.ManpadService.cancelPendingWakes(self._assetIndex:manpads())
	Medusa.Services.AaaService.cleanup({
		networkId = self._id,
		barrageState = self._aaaBarrageState,
		batteryStore = self._assetIndex:batteries(),
		trackStore = self._trackManager and self._trackManager:getStore() or nil,
		now = GetTime(),
	})
end

function Medusa.Core.IadsNetwork:stop()
	if self._running then
		_runningNetworkCount = math.max(0, _runningNetworkCount - 1)
	end
	self._running = false
	self._logger:info("stopped")
	if self._initialized then
		Medusa.Services.CrewSuppressionService.stop(self:_updateCrewSuppressionContext(GetTime()))
	end
	self:_unsubscribeSuppressionEvents()
	self:_releaseLocalDefenses()
	self:_releaseDecoyResponse()
	if self._timerId then
		CancelSchedule(self._timerId)
		self._timerId = nil
	end
	return true
end

--- On stop: no battery is left holding fire for a test shot or with engage-air-weapons off by the decoy response.
function Medusa.Core.IadsNetwork:_releaseDecoyResponse()
	if not self._initialized then
		return
	end
	local BAS = Medusa.Services.BatteryActivationService
	local batteries = self._assetIndex:batteryRepository():getAll()
	for i = 1, #batteries do
		local b = batteries[i]
		if b.TestShotHold then
			pcall(BAS.resumeFire, b)
		end
		pcall(BAS.releaseDecoyResponse, b)
	end
end

function Medusa.Core.IadsNetwork:_updateCrewSuppressionContext(now)
	local ctx = self._crewSuppressionCtx
	ctx.networkId = self._id
	ctx.batteryRepository = self._assetIndex:batteryRepository()
	ctx.trackStore = self._trackManager:getStore()
	ctx.barrageState = self._aaaBarrageState
	ctx.doctrine = self._doctrine
	ctx.suppressibleUnitGeoGrid = self._assetIndex:suppressibleUnitGeoGrid()
	ctx.now = now
	return ctx
end

function Medusa.Core.IadsNetwork:_logDoctrine()
	local d = self._doctrine
	if not d then
		return
	end
	self._logger:info("doctrine = " .. TableToString(d))
end

function Medusa.Core.IadsNetwork:_attachDiscoveryListener()
	local stores = {
		sensors = self._assetIndex:sensors(),
		batteries = self._assetIndex:batteries(),
		c2Nodes = self._assetIndex:c2Nodes(),
		manpads = self._assetIndex:manpads(),
		observers = self._assetIndex:observers(),
	}
	self._discoveryStores = stores
	local hierarchy = self._hierarchy
	local networkId = self._id
	local logger = self._logger
	local batteryRepository = self._assetIndex:batteryRepository()
	local harmSystems = self._harmCapableSystems
	local doctrine = self._doctrine
	local crewSkillIndex = self._crewSkillIndex

	local iads = self
	self._discovery:setListener({
		onAdded = function(dto)
			-- Skip if this group already has a battery or sensor
			if batteryRepository:getByGroupId(dto.groupId) then
				return
			end
			hierarchy:upsertGroup(dto)
			local roles = (dto.parsed and dto.parsed.roles) and table.concat(dto.parsed.roles, ",") or ""
			local path = (dto.parsed and dto.parsed.echelonPath) and table.concat(dto.parsed.echelonPath, ".") or ""
			logger:info(string.format("added: '%s' roles=[%s] path='%s'", tostring(dto.groupName), roles, path))

			local classification, radarTypes = Medusa.Services.EntityFactory.createFromDTO(
				dto,
				stores,
				networkId,
				harmSystems,
				doctrine,
				crewSkillIndex
			)
			if classification == "deferred" then
				iads:_deferGroup(dto, radarTypes)
			else
				iads:_adoptClassifiedGroup(dto, classification)
			end
		end,
	})
end

--- Search radar types (with a unit position) of a MANPAD group or a ground sensor group added after start.
local function radarTypesOf(units, isRadar, out)
	for i = 1, #units do
		local u = units[i]
		if u.UnitTypeName and u.Position and not out[u.UnitTypeName] and isRadar(u) then
			out[u.UnitTypeName] = u.Position
		end
	end
	return out
end

local function isSearchRadarUnit(unit)
	return Medusa.Entities.Battery.unitHasRole(unit, Medusa.Constants.BatteryUnitRole.SEARCH_RADAR)
end

local function isGroundSensor(sensor)
	return not sensor.IsAirborne
end

--- Puts a newly classified group into service: indexes it and, once the network is up, erects it and applies its
--- default state (a battery), or puts its crew to rest (a MANPAD group). A radar+guns group classified after the
--- first erect pass (it waited for its radar's reach) is erected here too.
function Medusa.Core.IadsNetwork:_adoptClassifiedGroup(dto, classification)
	local stores = self._discoveryStores
	local spatialIndex = self._spatialIndex
	if classification == "battery" then
		local battery = stores.batteries:getByGroupId(dto.groupId)
		if not battery then
			return
		end
		spatialIndex:syncBattery(battery)
		spatialIndex:syncSuppressibleUnits(battery)
		self:_updateMaxEngagementRange(battery)
		local BatteryActivationService = Medusa.Services.BatteryActivationService
		if self._erectComplete then
			BatteryActivationService.erectGroup(battery.GroupName)
			local STD = Medusa.Constants.SystemTypeDefaults
			local defaults = STD[battery.Role]
			local defaultState = defaults and defaults.DefaultActivationState or "STATE_COLD"
			local now = GetTime()
			if defaultState == Medusa.Constants.ActivationState.STATE_WARM then
				BatteryActivationService.goWarm(battery, now)
			else
				BatteryActivationService.goCold(battery, now)
			end
			self._logger:info(string.format("initialized dynamic battery %s as %s", battery.GroupName, defaultState))
			self:_applyDynamicBatteryRanges(battery)
			Medusa.Services.CrewSuppressionService.applyInitialDamage(self:_updateCrewSuppressionContext(now), battery)
			-- Point-defense links are made once at erect; a battery added later must
			-- get them too, as a SHORAD provider or as a SAM that needs one.
			self._pdReassignNeeded = true
		elseif self._fastErectDone then
			-- Classified after the first erect pass but before doctrine states: erect now, the doctrine pass sets it.
			BatteryActivationService.erectGroup(battery.GroupName)
			Medusa.Services.CrewSuppressionService.applyInitialDamage(
				self:_updateCrewSuppressionContext(GetTime()),
				battery
			)
		end
		if self._probeComplete then
			self:_classifyLocalRadars()
		end
	elseif classification == "manpad" then
		local battery = stores.manpads:getByGroupId(dto.groupId)
		if not battery then
			return
		end
		spatialIndex:syncBattery(battery)
		spatialIndex:syncSuppressibleUnits(battery)
		local now = GetTime()
		Medusa.Services.BatteryActivationService.goCold(battery, now, self._trackManager:getStore())
		if battery.TotalAmmoStatus <= 0 then
			battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
		end
		Medusa.Services.CrewSuppressionService.applyInitialDamage(self:_updateCrewSuppressionContext(now), battery)
		if
			self._probeComplete
			and not self:_probeUncachedTypes(radarTypesOf(battery.Units or {}, isSearchRadarUnit, {}))
		then
			self:_applyManpadRadarRanges()
			self:_classifyLocalRadars()
		end
	elseif classification == "sensor" or classification == "sensors" then
		local sensors = stores.sensors:getByGroupName(dto.groupName) or {}
		if self._probeComplete and not self:_probeUncachedTypes(radarTypesOf(sensors, isGroundSensor, {})) then
			self._probingService:applySensorRanges(stores.sensors)
			self:_classifyLocalRadars()
		end
	end
end

--- A radar+guns group whose radar reach is not known yet (doctrine LocalCueingRadars): it is classified once its
--- radar is probed. After the first probe pass it is resolved at once from the probe cache, probing new types when
--- AllowDynamicProbing is set; an unknown reach leaves it a sensor group.
function Medusa.Core.IadsNetwork:_deferGroup(dto, radarTypes)
	radarTypes = radarTypes or {}
	self._deferredGroups[#self._deferredGroups + 1] = { dto = dto, radarTypes = radarTypes }
	self._logger:info(string.format("deferred: '%s' (radar with guns) waits for its radar's reach", dto.groupName))
	if not self._probeComplete or self:_probeUncachedTypes(radarTypes) then
		return
	end
	self:_resolveDeferredGroups()
end

--- After the first probe pass: probes the radar types of `typePositions` the cache lacks when AllowDynamicProbing is
--- set (its completion applies the ranges and classifies local radars). Returns true when a probe was started.
function Medusa.Core.IadsNetwork:_probeUncachedTypes(typePositions)
	local uncached = nil
	for typeName, position in pairs(typePositions) do
		if self._probingService:getCapabilities(typeName) == nil then
			uncached = uncached or {}
			uncached[typeName] = position
		end
	end
	if not uncached or not Medusa.Config:get().AllowDynamicProbing then
		return false
	end
	local iads = self
	self._probingService:probeAll(uncached, function()
		iads:_onProbingComplete()
	end)
	return true
end

--- Classifies the waiting radar+guns groups with their probed reach (false when unknown: a sensor group).
function Medusa.Core.IadsNetwork:_resolveDeferredGroups()
	local deferred = self._deferredGroups
	if #deferred == 0 then
		return
	end
	self._deferredGroups = {}
	local ratio = Medusa.Constants.ContactEvidence.REACH_RATIO
	local probing = self._probingService
	for i = 1, #deferred do
		local item = deferred[i]
		local range = nil
		for typeName in pairs(item.radarTypes) do
			local caps = probing:getCapabilities(typeName)
			if caps and caps.detectionRangeMax and (not range or caps.detectionRangeMax > range) then
				range = caps.detectionRangeMax
			end
		end
		item.dto.localRadarReachM = range and range / ratio or false
		local classification = Medusa.Services.EntityFactory.createFromDTO(
			item.dto,
			self._discoveryStores,
			self._id,
			self._harmCapableSystems,
			self._doctrine,
			self._crewSkillIndex
		)
		probing:applySensorRanges(self._assetIndex:sensors())
		probing:applyBatteryRanges(self._assetIndex:batteries())
		self:_adoptClassifiedGroup(item.dto, classification)
	end
end

--- Search radars of MANPAD groups and of radar+guns groups waiting for their reach: their reach decides whether
--- they are local cueing radars.
function Medusa.Core.IadsNetwork:_collectLocalRadarProbeTargets(typePositions)
	local manpads = self._assetIndex:manpads():getAll()
	local BUR = Medusa.Constants.BatteryUnitRole
	for i = 1, #manpads do
		local b = manpads[i]
		local units = b.Units or {}
		for j = 1, #units do
			local unit = units[j]
			if
				unit.UnitTypeName
				and b.Position
				and not typePositions[unit.UnitTypeName]
				and Medusa.Entities.Battery.unitHasRole(unit, BUR.SEARCH_RADAR)
			then
				typePositions[unit.UnitTypeName] = b.Position
			end
		end
	end
	local deferred = self._deferredGroups
	for i = 1, #deferred do
		for typeName, position in pairs(deferred[i].radarTypes) do
			if not typePositions[typeName] then
				typePositions[typeName] = position
			end
		end
	end
end

--- MANPAD groups with their own search radar (a Dog Ear beside Igla teams) get its probed range, so the radar can
--- be managed as a local cueing radar. Their engagement range stays the missiles'.
function Medusa.Core.IadsNetwork:_applyManpadRadarRanges()
	local manpads = self._assetIndex:manpads():getAll()
	local BUR = Medusa.Constants.BatteryUnitRole
	for i = 1, #manpads do
		local b = manpads[i]
		local units = b.Units or {}
		local range = nil
		for j = 1, #units do
			local unit = units[j]
			if unit.UnitTypeName and Medusa.Entities.Battery.unitHasRole(unit, BUR.SEARCH_RADAR) then
				local caps = self._probingService:getCapabilities(unit.UnitTypeName)
				if caps and caps.detectionRangeMax and (not range or caps.detectionRangeMax > range) then
					range = caps.detectionRangeMax
				end
			end
		end
		if range then
			b.DetectionRangeMax = range
		end
	end
end

--- The reused context of the local picture (local radars and observer reports).
function Medusa.Core.IadsNetwork:_localPictureCtx()
	local ctx = self._localCtx
	ctx.localRadars = self._localRadars
	ctx.observers = self._observers
	ctx.esm = self._esm
	-- Readiness and net load for the crews' reports (nil with crew factors off: reports ignore them).
	ctx.crew = Medusa.Services.CrewFactorsService.isOn(self._doctrine) and self._crew or nil
	ctx.crewSkillIndex = self._crewSkillIndex
	ctx.maxEngagementRange = self._maxEngagementRange
	ctx.sensorStore = self._assetIndex:sensors()
	ctx.batteryStore = self._assetIndex:batteries()
	ctx.manpadStore = self._assetIndex:manpads()
	ctx.observerStore = self._assetIndex:observers()
	ctx.trackStore = self._trackManager:getStore()
	ctx.networkedGeoGrid = self._assetIndex:networkedGeoGrid()
	ctx.localGeoGrid = self._assetIndex:localGeoGrid()
	ctx.doctrine = self._doctrine
	ctx.coalitionId = self._coalitionId
	ctx.networkId = self._id
	ctx.now = GetTime()
	return ctx
end

function Medusa.Core.IadsNetwork:_classifyLocalRadars()
	return Medusa.Services.LocalRadarService.classify(self:_localPictureCtx())
end

--- Once a second: local radars come up or go dark (LocalRadarService.update), then observer radio reports arrive
--- (ObserverReportService.update). The observers' looks run one per tick (_runObserverLook).
function Medusa.Core.IadsNetwork:_runLocalPicturePhase()
	local ctx = self:_localPictureCtx()
	local MS = Medusa.Services.MetricsService
	local hpt = Medusa.hpTimer
	local t1 = hpt()
	if self._localRadarsDirty then
		-- A group died or lost a unit: forget dead radars and dead supported crews.
		self._localRadarsDirty = false
		local okClassify, errClassify = pcall(Medusa.Services.LocalRadarService.classify, ctx)
		if not okClassify then
			self._logger:error(string.format("local picture phase failed (classify): %s", tostring(errClassify)))
		end
	end
	if ctx.crew then
		local okCrew, errCrew = pcall(self._updateCrewFactors, self, ctx.now)
		if not okCrew then
			self._logger:error(string.format("local picture phase failed (crew factors): %s", tostring(errCrew)))
		end
	end
	local ok, err = pcall(Medusa.Services.LocalRadarService.update, ctx)
	if not ok then
		self._logger:error(string.format("local picture phase failed (local radars): %s", tostring(err)))
	end
	ok, err = pcall(Medusa.Services.ObserverReportService.update, ctx)
	if not ok then
		self._logger:error(string.format("local picture phase failed (observer reports): %s", tostring(err)))
	end
	MS.observe("medusa_local_picture_duration_seconds", hpt() - t1)
end

local crewCounts = { hostile = 0, tracks = 0, pending = 0, arms = 0 }

--- Sizes the net load's capacities from the network's sites (SAM, AAA and MANPAD groups and sensor groups) and SAM
--- batteries.
local sizeSensors, sizeGroups = {}, {}

--- Sites (living battery and MANPAD groups and ground radar groups; not AWACS or ships' radars) and SAM batteries,
--- for the counts that fill the crew net.
function Medusa.Core.IadsNetwork:_sizeCrewNet()
	local BR = Medusa.Constants.BatteryRole
	local DESTROYED = Medusa.Constants.BatteryOperationalStatus.DESTROYED
	local sites, sams = 0, 0
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		local b = batteries[i]
		if b.OperationalStatus ~= DESTROYED then
			sites = sites + 1
			if b.Role ~= BR.AAA and b.Role ~= BR.MANPAD then
				sams = sams + 1
			end
		end
	end
	local manpads = self._assetIndex:manpads():getAll()
	for i = 1, #manpads do
		if manpads[i].OperationalStatus ~= DESTROYED then
			sites = sites + 1
		end
	end
	local ship = Group and Group.Category and Group.Category.SHIP
	local sensors = self._assetIndex:sensors():getAll(sizeSensors)
	for i = 1, #sensors do
		local s = sensors[i]
		if not s.IsAirborne and s.GroupCategory ~= ship and s.GroupName and not sizeGroups[s.GroupName] then
			sizeGroups[s.GroupName] = true
			sites = sites + 1
		end
	end
	for name in pairs(sizeGroups) do
		sizeGroups[name] = nil
	end
	Medusa.Services.CrewFactorsService.setNetworkSize(self._crew, sites, sams)
end

--- Once a second (crew factors on): readiness (word spreads) and net load from the counts the network keeps.
function Medusa.Core.IadsNetwork:_updateCrewFactors(now)
	local TI = Medusa.Constants.TrackIdentification
	local store = self._trackManager:getStore()
	if not self._crewSizedAt or now - self._crewSizedAt >= Medusa.Constants.Observer.ROSTER_REFRESH_SEC then
		self._crewSizedAt = now
		self:_sizeCrewNet()
	end
	crewCounts.hostile = store:countByIdentification(TI.HOSTILE)
	-- Aircraft only: ARMs load the net through their own term, probable decoys not at all.
	crewCounts.tracks = self._aircraftTracks or 0
	crewCounts.pending = Medusa.Services.ObserverReportService.pendingCount(self._observers)
	crewCounts.arms = self._armsInbound or 0
	Medusa.Services.CrewFactorsService.update(
		self._crew,
		now,
		self._id,
		crewCounts,
		Medusa.Chance.isTraining(self._doctrine)
	)
end

--- The network's readiness now (the doctrine's starting value with crew factors off).
function Medusa.Core.IadsNetwork:getReadiness()
	if self._crew then
		return self._crew.readiness
	end
	return self._doctrine and self._doctrine.Readiness or Medusa.Constants.Readiness.ENGAGED
end

--- Sets the network's readiness (the mission's call: Medusa.API.setReadiness).
function Medusa.Core.IadsNetwork:setReadiness(value, why)
	if self._doctrine then
		self._doctrine.Readiness = value
	end
	if self._crew then
		return Medusa.Services.CrewFactorsService.set(self._crew, value, GetTime(), self._id, why or "api")
	end
	return true
end

--- Every tick: at most one observer look (ObserverReportService.look), so a second's looks are spread over ticks.
function Medusa.Core.IadsNetwork:_runObserverLook()
	local doctrine = self._doctrine
	local observers = self._observers
	if not doctrine or doctrine.ObserverReports == false or (observers.rosterTime and observers.rosterCount == 0) then
		return
	end
	local ok, err = pcall(Medusa.Services.ObserverReportService.look, self:_localPictureCtx())
	if not ok then
		self._logger:error(string.format("observer look failed: %s", tostring(err)))
	end
end

--- Every tick: at most one step of the listening stations' look (EsmService.tick).
function Medusa.Core.IadsNetwork:_runEsmLook()
	local doctrine = self._doctrine
	local esm = self._esm
	if not doctrine or doctrine.PassiveDetection == false then
		Medusa.Services.EsmService.stop(esm)
		return
	end
	-- no stations and nothing waiting: only the periodic roster refresh, without building the context every tick
	if
		esm.rosterTime
		and esm.stationCount == 0
		and esm.pendingCount == 0
		and esm.phase == 0
		and GetTime() - esm.rosterTime < Medusa.Constants.Esm.ROSTER_REFRESH_SEC
	then
		return
	end
	local ok, err = pcall(Medusa.Services.EsmService.tick, self:_localPictureCtx())
	if not ok then
		self._logger:error(string.format("listening station look failed: %s", tostring(err)))
	end
end

-- Event initiators and targets may be weapons, statics or scenery; the harness unit getters log an error for
-- anything but a unit, so ask DCS for the object category first. An object whose category cannot be read is
-- treated as a unit.
local function isUnitObject(obj)
	local ok, category = pcall(Object.getCategory, obj)
	if not ok or category == nil then
		return true
	end
	return category == Object.Category.UNIT
end
Medusa.Core.IadsNetwork._isUnitObject = isUnitObject

function Medusa.Core.IadsNetwork:_subscribeWorldEvents()
	local bus = HarnessWorldEventBus
	local coalitionId = self._coalitionId

	local function validateEventInitiator(event, cId)
		if not event or not event.initiator then
			return false
		end
		if type(event.initiator.getCoalition) ~= "function" then
			return false
		end
		local ok, coal = pcall(event.initiator.getCoalition, event.initiator)
		if not ok or coal ~= cId then
			return false
		end
		if isUnitObject(event.initiator) then
			local uid = GetUnitID(event.initiator)
			if uid then
				event._unitId = uid
			end
		end
		return true
	end

	local function deathPredicate(event)
		local accepted = validateEventInitiator(event, coalitionId)
		if accepted then
			self._logger:debug(string.format("death event accepted: unitId=%s", tostring(event._unitId)))
		else
			self._logger:debug("death event rejected: invalid initiator or coalition mismatch")
		end
		return accepted
	end
	self._deathQueue = Queue()
	bus:sub(world.event.S_EVENT_DEAD, self._deathQueue, deathPredicate)
	bus:sub(world.event.S_EVENT_CRASH, self._deathQueue, deathPredicate)

	local network = self
	local function shotPredicate(event)
		if not validateEventInitiator(event, coalitionId) then
			return false
		end
		-- The launch time now, not when the queue (a few events per tick) gets to it: no engage-air-weapons write may
		-- come right after a launch (DecoyResponseService).
		local repo = event._unitId and network._assetIndex and network._assetIndex:batteryRepository()
		local battery = repo and repo:getByUnitId(event._unitId)
		if battery then
			battery.LastLaunchAt = GetTime()
		end
		if event.weapon then
			local wtOk, wtn = pcall(event.weapon.getTypeName, event.weapon)
			if wtOk and wtn then
				event._weaponTypeName = wtn
			end
		end
		return true
	end
	self._shotQueue = Queue()
	bus:sub(world.event.S_EVENT_SHOT, self._shotQueue, shotPredicate)

	local function killPredicate(event)
		return validateEventInitiator(event, coalitionId)
	end
	self._killQueue = Queue()
	bus:sub(world.event.S_EVENT_KILL, self._killQueue, killPredicate)
	self:_subscribeSuppressionEvents()

	self._logger:info("world event subscriptions active")
end

function Medusa.Core.IadsNetwork:_subscribeSuppressionEvents()
	if self._hitSubscriptionId then
		self._logger:debug(
			string.format("crew suppression HIT subscription already active: id=%s", tostring(self._hitSubscriptionId))
		)
		return true
	end
	if not self._doctrine.CrewSuppression.Enabled then
		self._logger:debug("crew suppression HIT subscription skipped: doctrine disabled")
		return true
	end
	local network = self
	local dropReason = Medusa.Constants.CrewSuppressionDropReason
	if not self._hitQueue then
		local queue = RingBuffer(Medusa.Constants.CrewSuppression.HIT_EVENT_QUEUE_CAPACITY, true)
		function queue:enqueue(event)
			if type(event) ~= "table" or not event.initiator or not event.target then
				network:_recordCrewSuppressionDrop(dropReason.INVALID_EVENT)
				network._logger:debug("crew suppression HIT rejected: missing initiator or target")
				return false
			end
			if not isUnitObject(event.target) then
				network:_recordCrewSuppressionDrop(dropReason.INVALID_EVENT)
				network._logger:debug("crew suppression HIT rejected: target is not a unit")
				return false
			end
			local targetCoalition = GetUnitCoalition(event.target)
			if targetCoalition ~= network._coalitionId then
				network:_recordCrewSuppressionDrop(dropReason.INVALID_EVENT)
				network._logger:debug(
					string.format(
						"crew suppression HIT rejected: target coalition=%s expected=%s targetType=%s",
						tostring(targetCoalition),
						tostring(network._coalitionId),
						type(event.target)
					)
				)
				return false
			end
			local targetUnitId = GetUnitID(event.target)
			if not targetUnitId then
				network:_recordCrewSuppressionDrop(dropReason.INVALID_EVENT)
				network._logger:debug("crew suppression HIT rejected: target unit ID unavailable")
				return false
			end
			local _, evicted = self:push({ TargetUnitId = targetUnitId, ObservedAt = GetTime() })
			if evicted then
				network:_recordCrewSuppressionDrop(dropReason.QUEUE_OVERFLOW)
				network._logger:debug("crew suppression HIT queue overflow: oldest record evicted")
			end
			network._logger:debug(
				string.format("crew suppression HIT queued: targetUnitId=%d depth=%d", targetUnitId, self:size())
			)
			return true
		end
		self._hitQueue = queue
	end
	self._hitEventBus = HarnessWorldEventBus
	self._hitSubscriptionId = self._hitEventBus:sub(world.event.S_EVENT_HIT, self._hitQueue)
	self._logger:debug(
		string.format("crew suppression HIT subscription result: id=%s", tostring(self._hitSubscriptionId))
	)
	return self._hitSubscriptionId ~= nil
end

function Medusa.Core.IadsNetwork:_recordCrewSuppressionDrop(reason)
	Medusa.Services.MetricsService.inc("medusa_crew_suppression_dropped_events_total", nil, {
		network = self._id,
		reason = reason,
	})
end

local function validFiniteNumber(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function validPosition(position)
	return type(position) == "table"
		and validFiniteNumber(position.x)
		and validFiniteNumber(position.y)
		and validFiniteNumber(position.z)
end

local function validTerminalKindPayload(terminalEvent, kind, source)
	if Medusa.Constants.CrewSuppressionTerminalKindBySource[source] ~= kind then
		return false
	end
	return kind ~= Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE
		or (validFiniteNumber(terminalEvent.EffectiveExplosiveMassKg) and terminalEvent.EffectiveExplosiveMassKg > 0)
end

function Medusa.Core.IadsNetwork:enqueueTerminalEvent(terminalEvent)
	local source = terminalEvent and terminalEvent.Source
	local kind = terminalEvent and terminalEvent.Kind
	if not self._running or not self._doctrine or not self._doctrine.CrewSuppression.Enabled then
		self._logger:debug("terminal event ignored: crew suppression inactive")
		return false
	end
	if
		type(terminalEvent) ~= "table"
		or not validFiniteNumber(terminalEvent.TerminalEventId)
		or terminalEvent.TerminalEventId <= 0
		or not validPosition(terminalEvent.Position)
		or not validFiniteNumber(terminalEvent.ObservedAt)
		or Medusa.Constants.CrewSuppressionTerminalKind[kind] ~= kind
		or Medusa.Constants.CrewSuppressionTerminalSource[source] ~= source
	then
		self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.INVALID_EVENT)
		self._logger:debug("terminal event rejected at IADS boundary")
		return false
	end
	if not validTerminalKindPayload(terminalEvent, kind, source) then
		self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.INVALID_EVENT)
		self._logger:debug("terminal event rejected: kind payload mismatch")
		return false
	end
	local accepted = self._terminalEventQueue:push({
		TerminalEventId = terminalEvent.TerminalEventId,
		Kind = kind,
		Position = { x = terminalEvent.Position.x, y = terminalEvent.Position.y, z = terminalEvent.Position.z },
		EffectiveExplosiveMassKg = kind == Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE
				and terminalEvent.EffectiveExplosiveMassKg
			or nil,
		ObservedAt = terminalEvent.ObservedAt,
		Source = source,
	})
	if not accepted then
		self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.QUEUE_OVERFLOW)
		self._logger:debug(
			string.format(
				"terminal-event queue full: rejected id=%s kind=%s depth=%d",
				tostring(terminalEvent.TerminalEventId),
				kind,
				self._terminalEventQueue:size()
			)
		)
		return false
	end
	self._logger:debug(
		string.format(
			"terminal event queued: id=%s kind=%s source=%s depth=%d",
			tostring(terminalEvent.TerminalEventId),
			kind,
			source,
			self._terminalEventQueue:size()
		)
	)
	return true
end

function Medusa.Core.IadsNetwork:_processTerminalEvents(taskBudget, visitBudget)
	local steps = 0
	local visits = 0
	local now = GetTime()
	local ctx = self:_updateCrewSuppressionContext(now)
	while steps < taskBudget and visits < visitBudget do
		if
			self._activeTerminalEvent
			and now - self._activeTerminalEvent.TerminalEvent.ObservedAt
				> Medusa.Constants.CrewSuppression.IMPACT_MAX_AGE_SEC
		then
			self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.IMPACT_EXPIRED)
			self._logger:debug(
				string.format(
					"active terminal event expired: id=%s",
					tostring(self._activeTerminalEvent.TerminalEvent.TerminalEventId)
				)
			)
			self._activeTerminalEvent = nil
			steps = steps + 1
		end
		if steps >= taskBudget then
			break
		end
		if not self._activeTerminalEvent then
			local terminalEvent = self._terminalEventQueue:pop()
			if not terminalEvent then
				break
			end
			if now - terminalEvent.ObservedAt > Medusa.Constants.CrewSuppression.IMPACT_MAX_AGE_SEC then
				self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.IMPACT_EXPIRED)
				self._logger:debug(
					string.format("terminal event expired: id=%s", tostring(terminalEvent.TerminalEventId))
				)
				steps = steps + 1
			else
				local work = Medusa.Services.CrewSuppressionService.beginTerminalEvent(ctx, terminalEvent)
				if work then
					self._activeTerminalEvent = work
				else
					self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.INVALID_EVENT)
					self._logger:debug(
						string.format(
							"terminal event evaluation rejected: id=%s",
							tostring(terminalEvent.TerminalEventId)
						)
					)
					steps = steps + 1
				end
			end
		end
		if self._activeTerminalEvent then
			local visited, complete = Medusa.Services.CrewSuppressionService.continueTerminalEvent(
				ctx,
				self._activeTerminalEvent,
				visitBudget - visits,
				self._terminalUnitBuffer
			)
			visits = visits + visited
			steps = steps + 1
			if complete then
				self._activeTerminalEvent = nil
			end
		end
	end
	Medusa.Services.MetricsService.set(
		"medusa_crew_suppression_impact_queue_depth",
		self._terminalEventQueue:size(),
		self._metricLabels
	)
	return steps, visits
end

function Medusa.Core.IadsNetwork:_runBlackBoxWeaponObservations(now)
	if not self._blackBoxWeaponStore or not self._blackBoxWeaponStore:isStarted() or not self._blackBoxTerminalSink then
		return 0
	end
	return Medusa.Services.BlackBoxService.updateDue(self._blackBoxWeaponStore, now, self._blackBoxTerminalSink)
end

function Medusa.Core.IadsNetwork:_unsubscribeSuppressionEvents()
	if self._hitSubscriptionId and self._hitEventBus then
		self._hitEventBus:unsub(self._hitSubscriptionId)
	end
	self._hitSubscriptionId = nil
	self._hitEventBus = nil
	if self._hitQueue then
		self._hitQueue:clear()
	end
	self._terminalEventQueue:clear()
	self._activeTerminalEvent = nil
	self._logger:debug("crew suppression HIT subscription removed and queue cleared")
end

function Medusa.Core.IadsNetwork:_processHitEvents(limit)
	if not self._hitQueue or self._hitQueue:isEmpty() then
		Medusa.Services.MetricsService.set("medusa_crew_suppression_event_queue_depth", 0, self._metricLabels)
		return 0
	end
	local processed = 0
	local now = GetTime()
	local ctx = self:_updateCrewSuppressionContext(now)
	while processed < limit and not self._hitQueue:isEmpty() do
		local record = self._hitQueue:pop()
		local age = now - record.ObservedAt
		if age <= Medusa.Constants.CrewSuppression.HIT_EVENT_MAX_AGE_SEC then
			self._logger:debug(
				string.format("processing crew suppression HIT: targetUnitId=%d age=%.3fs", record.TargetUnitId, age)
			)
			local applied = Medusa.Services.CrewSuppressionService.processDamage(ctx, record.TargetUnitId)
			self._logger:debug(
				string.format(
					"crew suppression HIT processed: targetUnitId=%d applied=%s",
					record.TargetUnitId,
					tostring(applied)
				)
			)
		else
			self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.EXPIRED_EVENT)
			self._logger:debug(
				string.format("crew suppression HIT expired: targetUnitId=%d age=%.3fs", record.TargetUnitId, age)
			)
		end
		processed = processed + 1
	end
	Medusa.Services.MetricsService.set(
		"medusa_crew_suppression_event_queue_depth",
		self._hitQueue:size(),
		self._metricLabels
	)
	return processed
end

function Medusa.Core.IadsNetwork:_processDeathEvents(limit)
	if not self._deathQueue or self._deathQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._deathQueue:isEmpty() do
		local event = self._deathQueue:dequeue()
		if event and event._unitId then
			self._logger:debug(string.format("processing death event: unitId=%s", tostring(event._unitId)))
			self:_handleUnitDeath(event._unitId)
		else
			self._logger:debug("death event ignored: unit ID unavailable")
		end
		processed = processed + 1
	end
	return processed
end

local LOSS_RADAR_ROLES = {
	[Medusa.Constants.BatteryUnitRole.SEARCH_RADAR] = true,
	[Medusa.Constants.BatteryUnitRole.TRACK_RADAR] = true,
	[Medusa.Constants.BatteryUnitRole.TELAR] = true,
	[Medusa.Constants.BatteryUnitRole.TLAR] = true,
}

-- Alert-zone losses: a site counts once, when its first radar dies or, for groups without radars (AAA, MANPADs,
-- IR SAMs), when its last unit dies. Called before the dead unit is removed from the battery.
local function reportLoss(coalitionId, pos)
	local alerts = Medusa.Services.AlertZoneService
	if alerts and pos then
		alerts.reportLoss(coalitionId, pos)
	end
end

-- A group is one site whatever its units are filed as (sensors, a battery): it counts once.
local function groupLossReported(net, groupName)
	return groupName ~= nil and net._lossReportedGroups ~= nil and net._lossReportedGroups[groupName] == true
end

local function markGroupLoss(net, groupName)
	if groupName ~= nil then
		net._lossReportedGroups = net._lossReportedGroups or {}
		net._lossReportedGroups[groupName] = true
	end
end

--- A site of the network is lost (counted once per group): debrief line, and with crew factors on the network
--- turns ENGAGED and the loss loads the net for a while.
local function noteSiteLost(net, groupName, what)
	local now = GetTime()
	Medusa.Debrief.emit(net._id, now, "SITE_LOST", "site", groupName, "kind", what)
	if net._crew and Medusa.Services.CrewFactorsService.isOn(net._doctrine) then
		Medusa.Services.CrewFactorsService.onLoss(net._crew, now, net._id, Medusa.Chance.isTraining(net._doctrine))
	end
end

--- A ground sensor (an early-warning radar) died: its site counts once, when its first radar dies.
function Medusa.Core.IadsNetwork:_reportSensorLoss(sensor)
	if groupLossReported(self, sensor.GroupName) then
		return
	end
	markGroupLoss(self, sensor.GroupName)
	reportLoss(self._coalitionId, sensor.Position)
	noteSiteLost(self, sensor.GroupName, "sensor")
end

function Medusa.Core.IadsNetwork:_reportSiteLoss(battery, destroyedUnit, destroyed)
	if battery.LossReported or not destroyedUnit or groupLossReported(self, battery.GroupName) then
		return
	end
	local isRadar = false
	for _, role in ipairs(destroyedUnit.Roles or {}) do
		if LOSS_RADAR_ROLES[role] then
			isRadar = true
		end
	end
	local last = #(battery.Units or {}) <= 1
	if isRadar or last or destroyed then
		battery.LossReported = true
		markGroupLoss(self, battery.GroupName)
		reportLoss(self._coalitionId, destroyedUnit.Position or battery.Position)
		noteSiteLost(self, battery.GroupName, battery.Role)
	end
end

function Medusa.Core.IadsNetwork:_handleUnitDeath(unitId)
	self._logger:debug(string.format("resolving death event: unitId=%s", tostring(unitId)))
	local sensorStore = self._assetIndex:sensors()
	local sensor = sensorStore:getByUnitId(unitId)
	if sensor then
		self._localRadarsDirty = true
		sensorStore:remove(sensor.SensorUnitId)
		self._logger:info(string.format("sensor destroyed: %s (unitId=%d)", sensor.UnitName, unitId))
		if not sensor.IsAirborne then
			self:_reportSensorLoss(sensor)
		end
		return
	end

	local batteryRepository = self._assetIndex:batteryRepository()
	local battery, destroyedUnit = batteryRepository:getByUnitId(unitId)
	if not battery then
		self._logger:debug(string.format("death event ignored: unitId=%s is not managed", tostring(unitId)))
		return
	end
	self._logger:debug(
		string.format(
			"death event matched battery %s: unitId=%s role=%s members=%d",
			battery.GroupName or battery.BatteryId,
			tostring(unitId),
			tostring(battery.Role),
			#(battery.Units or {})
		)
	)

	self._localRadarsDirty = true
	self:_reportSiteLoss(battery, destroyedUnit)
	local wasRadarDirectedAaa = Medusa.Entities.Battery.isRadarDirectedAaa(battery)
	self._spatialIndex:removeSuppressibleUnit(unitId)
	batteryRepository:removeUnit(unitId)
	if battery.PositionAnchorUnitId == unitId then
		local preferredRole = battery.Role == Medusa.Constants.BatteryRole.AAA and Medusa.Constants.BatteryUnitRole.AAA
			or battery.Role == Medusa.Constants.BatteryRole.MANPAD and Medusa.Constants.BatteryUnitRole.MANPAD
			or nil
		local anchor = Medusa.Entities.Battery.selectPositionAnchor(battery, preferredRole)
		battery.Position = anchor and anchor.Position or nil
	end
	if battery.Role == Medusa.Constants.BatteryRole.MANPAD then
		local newStatus = Medusa.Entities.Battery.recomputeState(battery)
		if newStatus == Medusa.Constants.BatteryOperationalStatus.DESTROYED then
			self:_reportSiteLoss(battery, destroyedUnit, true)
			Medusa.Services.ManpadService.cancelPendingWake(battery)
			Medusa.Services.CrewSuppressionService.cancelRecovery(battery)
			batteryRepository:remove(battery.BatteryId)
			self._spatialIndex:removeBattery(battery.BatteryId)
			self._logger:info(string.format("manpad destroyed: %s (all MANPAD soldiers dead)", battery.GroupName))
		else
			Medusa.Services.CrewSuppressionService.processMemberDestruction(
				self:_updateCrewSuppressionContext(GetTime()),
				battery,
				destroyedUnit
			)
			Medusa.Services.ManpadService.rebuildHeadings(battery)
			self._spatialIndex:syncBattery(battery)
			self._logger:info(
				string.format("manpad %s lost unit %d (%d remaining)", battery.GroupName, unitId, #battery.Units)
			)
		end
		return
	end

	if battery.HarmCapableUnitCount > 0 then
		battery.HarmCapableUnitCount =
			Medusa.Services.EntityFactory.computeHarmCapableCount(battery, self._harmCapableSystems)
	end

	local prevStatus = battery.OperationalStatus
	local newStatus = Medusa.Entities.Battery.recomputeState(battery)

	if newStatus == Medusa.Constants.BatteryOperationalStatus.DESTROYED then
		self:_reportSiteLoss(battery, destroyedUnit, true)
		Medusa.Services.CrewSuppressionService.cancelRecovery(battery)
		if battery.Role == Medusa.Constants.BatteryRole.AAA then
			Medusa.Services.AaaService.cleanupBattery({
				barrageState = self._aaaBarrageState,
				trackStore = self._trackManager:getStore(),
				now = GetTime(),
			}, battery)
		end
		Medusa.Services.MetricsService.inc("medusa_battery_destroyed_total")
		Medusa.Entities.Battery.releaseTrack(battery, self._trackManager:getStore())
		batteryRepository:remove(battery.BatteryId)
		self._spatialIndex:removeBattery(battery.BatteryId)
		self._logger:info(string.format("battery destroyed: %s (all units dead)", battery.GroupName))
	else
		if battery.Role == Medusa.Constants.BatteryRole.AAA then
			Medusa.Services.CrewSuppressionService.processMemberDestruction(
				self:_updateCrewSuppressionContext(GetTime()),
				battery,
				destroyedUnit
			)
			Medusa.Services.AaaService.rebuildHeadings(battery)
			if wasRadarDirectedAaa and Medusa.Entities.Battery.isIndependentAaa(battery) then
				Medusa.Entities.Battery.releaseTrack(battery, self._trackManager:getStore())
				if battery.IsPointDefense then
					Medusa.Services.PointDefenseService.clearAssignment(battery.BatteryId, self._assetIndex:batteries())
					self._pdReassignNeeded = true
				end
			end
		end
		self._spatialIndex:syncBattery(battery)
		self._logger:info(
			string.format("battery %s lost unit %d (%d remaining)", battery.GroupName, unitId, #battery.Units)
		)
		if newStatus ~= prevStatus then
			self._logger:info(string.format("battery %s status: %s -> %s", battery.GroupName, prevStatus, newStatus))
		end
		local degradation = Medusa.Entities.Battery.classifyDegradation(battery)
		if degradation then
			local context = {
				batteryRepository = batteryRepository,
				geoGrid = self._networkedGeoGrid,
				trackStore = self._trackManager:getStore(),
			}
			local result = Medusa.Entities.Battery.applyDegradedBehavior(battery, degradation, context)
			if result == "weapons_free" then
				self._logger:info(
					string.format("battery %s TELARs weapons free (CP still coordinating)", battery.GroupName)
				)
			end
		end
	end
end

function Medusa.Core.IadsNetwork:_processShotEvents(limit)
	if not self._shotQueue or self._shotQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._shotQueue:isEmpty() do
		local event = self._shotQueue:dequeue()
		if event and event._unitId then
			self:_handleShot(event._unitId, event._weaponTypeName, event.weapon)
		end
		processed = processed + 1
	end
	return processed
end

function Medusa.Core.IadsNetwork:_processKillEvents(limit)
	if not self._killQueue or self._killQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._killQueue:isEmpty() do
		local event = self._killQueue:dequeue()
		if event and event._unitId then
			local battery = self._assetIndex:batteryRepository():getByUnitId(event._unitId)
			if battery then
				Medusa.Services.MetricsService.inc("medusa_kills_total")
				if
					battery.Role ~= Medusa.Constants.BatteryRole.MANPAD
					and not Medusa.Entities.Battery.isIndependentAaa(battery)
				then
					self:_recordKillOutcome()
				end
				self._logger:info(string.format("battery %s scored a kill", battery.GroupName))
			end
		end
		processed = processed + 1
	end
	return processed
end

local function estimateTTK(rangeMax, targetAlt)
	local C = Medusa.Constants
	local range = rangeMax or 0
	if targetAlt and targetAlt < C.TTK_ALT_CEIL_M then
		local frac
		if targetAlt <= C.TTK_ALT_FLOOR_M then
			frac = 0.5
		else
			frac = 0.5 + 0.5 * (targetAlt - C.TTK_ALT_FLOOR_M) / (C.TTK_ALT_CEIL_M - C.TTK_ALT_FLOOR_M)
		end
		range = range * frac
	end
	return range / C.SAM_AVG_MISSILE_SPEED_MPS
end

local function hasMatchingAmmo(unit, weaponTypeName)
	for i = 1, #unit.AmmoTypes do
		local ammo = unit.AmmoTypes[i]
		if ammo.Count > 0 and ammo.WeaponTypeName == weaponTypeName then
			return true
		end
	end
	return false
end

--- The DCS boundary of a battery's own launch for the decoy response: whether the crew follows the missile (radar
--- or command guidance, from the weapon's descriptor) and which contact it was fired at (the weapon's target, which
--- the crew's fire-control radar holds; mapped to the network track of that object, else unknown: the battery's
--- assignment is not what DCS fired at). Then DecoyResponseService.
function Medusa.Core.IadsNetwork:_recordDecoyLaunch(battery, weapon, now, unit)
	if not weapon or (self._doctrine and self._doctrine.DecoyAssessment == false) then
		return
	end
	local desc = GetWeaponDesc(weapon)
	local target = GetWeaponTarget(weapon)
	local targetTrackId = target and target.id_ and self._trackManager:getTrackIdByNetworkId(target.id_)
	local ctx = self._decoyLaunchCtx
	if not ctx then
		ctx = {}
		self._decoyLaunchCtx = ctx
	end
	ctx.trackStore = self._trackManager:getStore()
	ctx.geoGrid = self._assetIndex:networkedGeoGrid()
	ctx.doctrine = self._doctrine
	ctx.now = now
	ctx.networkId = self._id
	ctx.holdBreaksTypes = self._holdBreaksTypes
	Medusa.Services.DecoyResponseService.recordLaunch(ctx, battery, {
		Weapon = weapon,
		LaunchTime = now,
		TargetTrackId = targetTrackId or nil,
		Guided = desc ~= nil and Medusa.Constants.Decoy.CREW_GUIDED[desc.guidance] == true,
		LauncherType = unit and unit.UnitTypeName or nil,
	})
end

local LOCK_ROLES = {
	[Medusa.Constants.BatteryUnitRole.TRACK_RADAR] = true,
	[Medusa.Constants.BatteryUnitRole.TELAR] = true,
	[Medusa.Constants.BatteryUnitRole.TLAR] = true,
}

--- The DCS boundary of what a battery's own fire-control radars are locked on (Unit.getRadar's tracked object on its
--- tracking radars, TELARs and TLARs), each mapped to the network track of that object (active tracks only). Fills
--- `out` with track ids (no allocation) and returns their count. DecoyResponseService reads it at most every
--- FIRE_HOLD_LOCK_READ_SEC per battery, only with a decoy in reach it may still hold against.
function Medusa.Core.IadsNetwork:_lockedTracksOf(battery, out)
	local n = 0
	local units = battery.Units
	for i = 1, units and #units or 0 do
		local u = units[i]
		local roles = u.Roles
		local fcr = false
		for j = 1, roles and #roles or 0 do
			if LOCK_ROLES[roles[j]] then
				fcr = true
				break
			end
		end
		if fcr and u.UnitName and u.OperationalStatus ~= Medusa.Constants.UnitOperationalStatus.DESTROYED then
			local unit = GetUnit(u.UnitName)
			if unit then
				local _, tracked = GetUnitRadar(unit)
				local trackId = tracked and tracked.id_ and self._trackManager:getTrackIdByNetworkId(tracked.id_)
				local track = trackId and self._trackManager:getStore():get(trackId)
				if track and track.LifecycleState == Medusa.Constants.TrackLifecycleState.ACTIVE then
					n = n + 1
					out[n] = trackId
				end
			end
		end
	end
	for i = n + 1, #out do
		out[i] = nil
	end
	return n
end

function Medusa.Core.IadsNetwork:_handleShot(unitId, weaponTypeName, weapon)
	local battery, unit = self._assetIndex:batteryRepository():getByUnitId(unitId)
	if not battery then
		self._logger:debug(string.format("shot ignored: no battery for unitId=%s", tostring(unitId)))
		return
	end
	local isManpad = battery.Role == Medusa.Constants.BatteryRole.MANPAD
	local isIndependentAaa = Medusa.Entities.Battery.isIndependentAaa(battery)
	local isLocallyManaged = isManpad or isIndependentAaa
	if isLocallyManaged and not Medusa.Entities.Battery.isAmmoBearingUnit(battery, unit) then
		return
	end
	if not unit.AmmoTypes or #unit.AmmoTypes == 0 then
		return
	end
	if isLocallyManaged and not hasMatchingAmmo(unit, weaponTypeName) then
		return
	end

	local previousAmmo = battery.TotalAmmoStatus or 0
	local engagementRange = battery.EngagementRangeMax
	self:_decrementAmmo(unit, weaponTypeName)
	local now = GetTime()
	Medusa.Services.MetricsService.inc("medusa_shots_fired_total")
	battery.ShotsFired = battery.ShotsFired + 1
	battery.LastShotTime = now
	if not isLocallyManaged then
		self:_recordShotOutcome(0)
	end
	if
		not isLocallyManaged
		and battery.LastChanceTrackId
		and battery.LastChanceShotsRemaining
		and battery.LastChanceShotsRemaining > 0
	then
		battery.LastChanceShotsRemaining = battery.LastChanceShotsRemaining - 1
		Medusa.Services.MetricsService.inc("medusa_last_chance_fired_total")
	end

	local targetAlt = nil
	if not isLocallyManaged and battery.CurrentTargetTrackId then
		local track = self._trackManager:getStore():get(battery.CurrentTargetTrackId)
		if track and track.Position then
			targetAlt = track.Position.y
		end
	end
	local ttk = estimateTTK(engagementRange, targetAlt)
	battery.MissileInFlightUntil = now + ttk
	-- A missile launch (SAM or MANPAD; guns are not counted) means a war and loads the net while it flies.
	if
		battery.Role ~= Medusa.Constants.BatteryRole.AAA
		and self._crew
		and Medusa.Services.CrewFactorsService.isOn(self._doctrine)
	then
		Medusa.Services.CrewFactorsService.onLaunch(self._crew, now, self._id, ttk)
	end
	if not isLocallyManaged then
		self:_recordDecoyLaunch(battery, weapon, now, unit)
	end

	local prevStatus = battery.OperationalStatus
	local newStatus = Medusa.Entities.Battery.recomputeState(battery)
	if isManpad then
		Medusa.Services.ManpadService.onShot(battery, now, Medusa.Chance.isTraining(self._doctrine))
	elseif battery.Role == Medusa.Constants.BatteryRole.AAA then
		Medusa.Services.AaaService.onShot({
			networkId = self._id,
			barrageState = self._aaaBarrageState,
			batteryStore = self._assetIndex:batteries(),
			trackStore = self._trackManager:getStore(),
			localGeoGrid = self._assetIndex:localGeoGrid(),
			doctrine = self._doctrine,
		}, battery, unit, now)
	end
	if previousAmmo > 0 and battery.TotalAmmoStatus <= 0 then
		battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
		if isManpad then
			Medusa.Services.MetricsService.inc("medusa_manpad_winchester_total")
		end
	end

	self._logger:info(
		string.format(
			"battery %s fired %s (%d remaining)",
			battery.GroupName,
			weaponTypeName or "unknown",
			battery.TotalAmmoStatus
		)
	)
	if newStatus ~= prevStatus then
		self._logger:info(string.format("battery %s status: %s -> %s", battery.GroupName, prevStatus, newStatus))
		if not isManpad and battery.TotalAmmoStatus <= 0 then
			if Medusa.Services.BatteryActivationService.goGreen(battery, now, self._trackManager:getStore()) then
				battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
			end
		end
	end
end

function Medusa.Core.IadsNetwork:_recordShotOutcome(outcome)
	local C = Medusa.Constants
	local buf = self._rollingPkBuffer
	self._rollingPkIndex = (self._rollingPkIndex % C.ROLLING_PK_WINDOW) + 1
	buf[self._rollingPkIndex] = outcome
	if self._rollingPkCount < C.ROLLING_PK_WINDOW then
		self._rollingPkCount = self._rollingPkCount + 1
	end
	self._lastRollingPkEventTime = GetTime()
	if self._rollingPkCount >= C.ROLLING_PK_WINDOW and self._doctrine.RollingPkEnabled then
		self:_updateEffectivePkFloor()
	end
end

function Medusa.Core.IadsNetwork:_recordKillOutcome()
	local buf = self._rollingPkBuffer
	local idx = self._rollingPkIndex
	local C = Medusa.Constants
	for _ = 1, self._rollingPkCount do
		if buf[idx] == 0 then
			buf[idx] = 1
			if self._rollingPkCount >= C.ROLLING_PK_WINDOW and self._doctrine.RollingPkEnabled then
				self:_updateEffectivePkFloor()
			end
			return
		end
		idx = idx - 1
		if idx < 1 then
			idx = C.ROLLING_PK_WINDOW
		end
	end
end

function Medusa.Core.IadsNetwork:_updateEffectivePkFloor()
	local C = Medusa.Constants
	local sum = 0
	for i = 1, self._rollingPkCount do
		sum = sum + self._rollingPkBuffer[i]
	end
	local rollingPk = sum / self._rollingPkCount
	local target = self._doctrine.TargetKillRate
	local floor = self._doctrine.PkFloor
	local current = self._effectivePkFloor
	if rollingPk > target then
		current = math.max(floor, current - C.ROLLING_PK_STEP)
	elseif rollingPk < target then
		current = math.min(C.ROLLING_PK_CEILING, current + C.ROLLING_PK_STEP)
	end
	self._effectivePkFloor = current
	self._doctrine.EffectivePkFloor = current
end

function Medusa.Core.IadsNetwork:_decayEffectivePkFloor(now)
	if not self._doctrine.RollingPkEnabled then
		return
	end
	if self._lastRollingPkEventTime == 0 then
		return
	end
	local floor = self._doctrine.PkFloor
	local current = self._effectivePkFloor
	if current <= floor then
		return
	end
	local dt = now - self._lastRollingPkEventTime
	if dt <= 0 then
		return
	end
	local decayed = floor + (current - floor) * math.exp(-dt / Medusa.Constants.ROLLING_PK_DECAY_TAU)
	self._effectivePkFloor = math.max(floor, decayed)
	self._doctrine.EffectivePkFloor = self._effectivePkFloor
end

function Medusa.Core.IadsNetwork:_decrementAmmo(unit, weaponTypeName)
	for i = 1, #unit.AmmoTypes do
		local at = unit.AmmoTypes[i]
		if at.Count > 0 and at.WeaponTypeName == weaponTypeName then
			at.Count = at.Count - 1
			unit.AmmoCount = unit.AmmoCount - 1
			return
		end
	end
	self._logger:error(
		string.format("ammo type '%s' not found on unit, using fallback decrement", weaponTypeName or "unknown")
	)
	for i = 1, #unit.AmmoTypes do
		local at = unit.AmmoTypes[i]
		if at.Count > 0 then
			at.Count = at.Count - 1
			unit.AmmoCount = unit.AmmoCount - 1
			return
		end
	end
end

Medusa.Core.IadsNetwork._rearmBuffer = {}

function Medusa.Core.IadsNetwork:_checkRearming(now)
	local batteries = self._assetIndex:batteryRepository():getAll(Medusa.Core.IadsNetwork._rearmBuffer)
	local STD = Medusa.Constants.SystemTypeDefaults
	local BatteryActivationService = Medusa.Services.BatteryActivationService
	local checked = 0
	for i = 1, #batteries do
		if checked >= 2 then
			break
		end
		local battery = batteries[i]
		if battery.RearmCheckTime and now >= battery.RearmCheckTime then
			checked = checked + 1
			local rearmed = false
			if battery.Units then
				for j = 1, #battery.Units do
					local unit = battery.Units[j]
					if unit.UnitName and Medusa.Entities.Battery.isAmmoBearingUnit(battery, unit) then
						local newAmmo, newCount = Medusa.Services.EntityFactory.extractAmmo(unit.UnitName, battery.Role)
						if newCount > 0 then
							rearmed = true
							unit.AmmoTypes = newAmmo
							unit.AmmoCount = newCount
						end
					end
				end
			end
			if rearmed then
				Medusa.Entities.Battery.recomputeState(battery)
				local returnedToService = true
				if battery.Role == Medusa.Constants.BatteryRole.MANPAD then
					if battery.ActivationState ~= Medusa.Constants.ActivationState.STATE_COLD then
						returnedToService = BatteryActivationService.goCold(battery, now, self._trackManager:getStore())
					end
					if returnedToService then
						Medusa.Services.ManpadService.onRearmed(battery, now)
					end
				else
					battery.HarmCapableUnitCount =
						Medusa.Services.EntityFactory.computeHarmCapableCount(battery, self._harmCapableSystems)
					local defaults = STD[battery.Role]
					local defaultState = defaults and defaults.DefaultActivationState or "STATE_COLD"
					if defaultState == Medusa.Constants.ActivationState.STATE_WARM then
						BatteryActivationService.goWarm(battery, now)
					else
						BatteryActivationService.goCold(battery, now)
					end
				end
				if returnedToService then
					battery.RearmCheckTime = nil
					self._pdReassignNeeded = true
					self._logger:info(
						string.format(
							"battery %s rearmed (%d rounds), returning to service",
							battery.GroupName,
							battery.TotalAmmoStatus
						)
					)
				else
					battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
				end
			else
				battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
			end
		end
	end
end

local function _applyDefaultState(battery, BatteryActivationService, defaultState, now)
	if defaultState == Medusa.Constants.ActivationState.STATE_WARM then
		return BatteryActivationService.goWarm(battery, now), "warm"
	end
	return BatteryActivationService.goCold(battery, now), "cold"
end

--- Triggers the DCS erect animation on all batteries so subsequent state transitions are instant.
function Medusa.Core.IadsNetwork:_fastErectBatteries()
	local BatteryActivationService = Medusa.Services.BatteryActivationService
	local batteries = self._assetIndex:batteries():getAll()
	local erected = 0
	for i = 1, #batteries do
		if BatteryActivationService.erectGroup(batteries[i].GroupName) then
			erected = erected + 1
		end
	end
	self._fastErectDone = true
	self._logger:info(string.format("fast erect: %d batteries pre-activated", erected))
end

function Medusa.Core.IadsNetwork:_applyInitialCrewSuppression(now)
	local batteries = self._assetIndex:batteryRepository():getAll()
	local ctx = self:_updateCrewSuppressionContext(now)
	for i = 1, #batteries do
		Medusa.Services.CrewSuppressionService.applyInitialDamage(ctx, batteries[i])
	end
end

function Medusa.Core.IadsNetwork:_initializeBatteryStates()
	local batteries = self._assetIndex:batteries():getAll()
	local BatteryActivationService = Medusa.Services.BatteryActivationService
	local STD = Medusa.Constants.SystemTypeDefaults
	local now = GetTime()
	local coldCount = 0
	local warmCount = 0
	local skipped = 0

	for i = 1, #batteries do
		local battery = batteries[i]
		local defaults = STD[battery.Role]
		local defaultState = defaults and defaults.DefaultActivationState or "STATE_COLD"
		local ok, label = _applyDefaultState(battery, BatteryActivationService, defaultState, now)
		if ok then
			if label == "warm" then
				warmCount = warmCount + 1
			else
				coldCount = coldCount + 1
			end
		else
			skipped = skipped + 1
		end
	end
	self._logger:info(
		string.format(
			"initialized %d batteries (%d COLD, %d WARM), skipped %d",
			coldCount + warmCount,
			coldCount,
			warmCount,
			skipped
		)
	)
end

local function _collectBatteryUnitPositions(battery, typePositions)
	if not battery.Units then
		return
	end
	for j = 1, #battery.Units do
		local unit = battery.Units[j]
		if unit.UnitTypeName and not typePositions[unit.UnitTypeName] and battery.Position then
			typePositions[unit.UnitTypeName] = battery.Position
		end
	end
end

function Medusa.Core.IadsNetwork:_probeAirborneSensors()
	local sensors = self._assetIndex:sensors():getAll()
	for i = 1, #sensors do
		local sensor = sensors[i]
		if sensor.IsAirborne and sensor.UnitName and not sensor.DetectionRangeMax then
			local unit = GetUnit(sensor.UnitName)
			local sensorsTable = unit and GetUnitSensors(unit)
			if sensorsTable then
				local caps = self._probingService:_parseSensors(sensorsTable)
				if caps and caps.detectionRangeMax then
					sensor.DetectionRangeMax = caps.detectionRangeMax
					self._logger:info(
						string.format(
							"airborne sensor '%s' detection range: %.0fm (%.1fnm)",
							sensor.GroupName,
							caps.detectionRangeMax,
							caps.detectionRangeMax / 1852
						)
					)
				end
			end
		end
	end
end

function Medusa.Core.IadsNetwork:_collectProbeTargets()
	local typePositions = {}
	local sensors = self._assetIndex:sensors():getAll()
	for i = 1, #sensors do
		local sensor = sensors[i]
		if
			not sensor.IsAirborne
			and sensor.UnitTypeName
			and sensor.Position
			and not typePositions[sensor.UnitTypeName]
		then
			typePositions[sensor.UnitTypeName] = sensor.Position
		end
	end
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		_collectBatteryUnitPositions(batteries[i], typePositions)
	end
	self:_collectLocalRadarProbeTargets(typePositions)
	return typePositions
end

function Medusa.Core.IadsNetwork:_populateGeoGrid()
	local batteries = self._assetIndex:batteries():getAll()
	local maxRange = 0
	local maxSpread = 0
	local networkedCount = 0
	local localCount = 0
	for i = 1, #batteries do
		local b = batteries[i]
		self._spatialIndex:syncBattery(b)
		self._spatialIndex:syncSuppressibleUnits(b)
		if self._spatialIndex:isNetworkedBattery(b) then
			networkedCount = networkedCount + 1
			local r = b.EngagementRangeMax or 0
			if r > maxRange then
				maxRange = r
			end
			local s = b.ClusterSpreadRadius or 0
			if s > maxSpread then
				maxSpread = s
			end
		else
			localCount = localCount + 1
		end
	end
	self._maxEngagementRange = math.max(math.ceil((maxRange + maxSpread) / 10000) * 10000, 10000)

	local manpads = self._assetIndex:manpads():getAll()
	for i = 1, #manpads do
		self._spatialIndex:syncBattery(manpads[i])
		self._spatialIndex:syncSuppressibleUnits(manpads[i])
	end
	localCount = localCount + #manpads

	self._logger:info(
		string.format(
			"geogrid: %d networked, %d local defenses indexed, maxEngagementRange=%dm",
			networkedCount,
			localCount,
			self._maxEngagementRange
		)
	)
end

function Medusa.Core.IadsNetwork:_updateMaxEngagementRange(battery)
	if not self._spatialIndex:isNetworkedBattery(battery) then
		return
	end
	local r = battery.EngagementRangeMax or 0
	local s = battery.ClusterSpreadRadius or 0
	local effective = math.max(math.ceil((r + s) / 10000) * 10000, 10000)
	if effective > self._maxEngagementRange then
		self._maxEngagementRange = effective
		self._logger:info(string.format("maxEngagementRange updated to %dm", effective))
	end
end

function Medusa.Core.IadsNetwork:_runScanAndLog()
	local added = self._discovery:scanOnce()
	if (added or 0) > 0 then
		self._logger:info(string.format("discovery: added=%d", added))
		self._logger:debug(string.format("hierarchy tree:\n%s", self._hierarchy:renderTree()))
	end
end

function Medusa.Core.IadsNetwork:_logAssetSummary(now)
	if (now - self._lastAssetLogTime) < self._assetLogIntervalSec then
		return
	end
	self._lastAssetLogTime = now
	local trackCount = self._trackManager and self._trackManager:getStore():count() or 0
	local sensorNames = self._assetIndex:sensors():getUniqueGroupNames()
	local accum = self._pollDetectionAccum
	local sensorParts = {}
	for i = 1, #sensorNames do
		local n = sensorNames[i]
		sensorParts[i] = string.format("  %s: %d detections", n, accum[n] or 0)
		accum[n] = 0
	end
	local sensorDetail = #sensorParts > 0 and ("\n" .. table.concat(sensorParts, "\n")) or ""
	self._logger:info(
		string.format(
			"status: batteries=%d, sensors=%d, c2nodes=%d, tracks=%d%s",
			self._assetIndex:batteries():count(),
			self._assetIndex:sensors():count(),
			self._assetIndex:c2Nodes():count(),
			trackCount,
			sensorDetail
		)
	)
end

--- Contact-evidence context for a polled group (see SensorPollingService:_observe), written into the poll entry's
--- reused table: where the radar is, its reach against a 5 m2 target (probed detectionDistanceAir / REACH_RATIO;
--- nil until probed) and its kind (amplitude resolution).
local function setSensorCtx(entry, position, detectionRange, kind)
	local ctx = entry.sensorCtx
	if not ctx then
		ctx = {}
		entry.sensorCtx = ctx
	end
	ctx.Position = position
	ctx.Reach = detectionRange and detectionRange > 0 and detectionRange / Medusa.Constants.ContactEvidence.REACH_RATIO
		or nil
	ctx.Kind = kind
end

--- The sensor groups and batteries to poll this tick. The list and its entries are reused tick to tick; the result
--- is valid until the next call.
function Medusa.Core.IadsNetwork:_buildPollList()
	local list = self._pollListBuffer
	if not list then
		list = {}
		self._pollListBuffer = list
	end
	local n = 0
	local function put(groupName, sourceType, scanRateSec)
		n = n + 1
		local entry = list[n]
		if not entry then
			entry = {}
			list[n] = entry
		end
		entry.groupName = groupName
		entry.sourceType = sourceType
		entry.scanRateSec = scanRateSec
		entry.detectionType = nil
		entry.localRadar = nil
		return entry
	end
	local sensorNames = self._assetIndex:sensors():getUniqueGroupNames()
	for i = 1, #sensorNames do
		local groupName = sensorNames[i]
		local sensors = self._assetIndex:sensors():getByGroupName(groupName)
		local first = sensors[1]
		if first and first.IsLocalRadar then
			-- polled below while lit
		else
			local sourceType = trackSourceForSensor(first)
			local entry =
				put(groupName, sourceType, Medusa.Core.IadsNetwork._scanRateForSensor(self._doctrine, sourceType))
			local range = nil
			for j = 1, #sensors do
				local s = sensors[j]
				if s.DetectionRangeMax and (not range or s.DetectionRangeMax > range) then
					range = s.DetectionRangeMax
				end
			end
			setSensorCtx(entry, first and first.Position, range, "EWR")
		end
	end
	local AS = Medusa.Constants.ActivationState
	local datalink = self._doctrine and self._doctrine.BatteryTargetDatalink
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		local b = batteries[i]
		local canReport = b.ActivationState == AS.STATE_HOT
			or (b.ActivationState == AS.STATE_WARM and Medusa.Entities.Battery.hasSearchRadar(b))
		if
			not b.LocalRadar
			and (b.IsActingAsEWR or (datalink and canReport and not Medusa.Entities.Battery.isIndependentAaa(b)))
		then
			local sourceType = trackSourceForBattery(b)
			local entry =
				put(b.GroupName, sourceType, Medusa.Core.IadsNetwork._scanRateForBattery(self._doctrine, b, sourceType))
			setSensorCtx(entry, b.Position, b.DetectionRangeMax, Medusa.Core.IadsNetwork._radarKind(b))
		end
	end
	-- Lit local cueing radars, on their radar channel only (a MANPAD crew's eyes are not a radar track), at the
	-- search rate. Dark ones are not polled: DCS reports nothing from a radar that is off.
	local records = self._localRadars.records
	local LocalRadarService = Medusa.Services.LocalRadarService
	local radarChannel = Controller and Controller.Detection and Controller.Detection.RADAR or nil
	local searchRate = Medusa.Services.SensorPollingService.scanRateFor(self._doctrine, "SAM_SEARCH")
	for i = 1, #records do
		local record = records[i]
		if LocalRadarService.isUp(record) then
			local sourceType = record.Kind == LocalRadarService.Kind.SENSOR and TS_EWR or TS_SAM
			local entry = put(record.GroupName, sourceType, searchRate)
			entry.detectionType = radarChannel
			entry.localRadar = record
			setSensorCtx(
				entry,
				record.Position,
				record.ReachM * Medusa.Constants.ContactEvidence.REACH_RATIO,
				"SAM_SEARCH"
			)
		end
	end
	for i = n + 1, #list do
		list[i] = nil
	end
	return list
end

function Medusa.Core.IadsNetwork:_removeSensorGroup(groupName)
	local count = self._assetIndex:sensors():removeByGroupName(groupName)
	if count > 0 then
		self._localRadarsDirty = true
		self._logger:info(string.format("sensor group %s despawned, removed %d sensors", groupName, count))
	end
end

function Medusa.Core.IadsNetwork:_updateAirborneSensors()
	local sensors = self._assetIndex:sensors():getAll()
	for i = 1, #sensors do
		local s = sensors[i]
		if s.IsAirborne and s.UnitName then
			local pos = GetUnitPosition(s.UnitName)
			if pos then
				s.Position = pos
			else
				self:_removeSensorGroup(s.GroupName)
			end
		end
	end
end

local HEIGHT_LOW_MAX_M = Medusa.Constants.Observer.LOW_MAX_M
local HEIGHT_HIGH_MIN_M = Medusa.Constants.Observer.HIGH_MIN_M
local NOT_HOSTILE_ID = {
	[Medusa.Constants.TrackIdentification.FRIENDLY] = true,
	[Medusa.Constants.TrackIdentification.WHITEAIR] = true,
}

local function heightBand(alt)
	if not alt then
		return nil
	end
	return alt <= HEIGHT_LOW_MAX_M and "low" or (alt >= HEIGHT_HIGH_MIN_M and "high" or "medium")
end

--- The sensor that made a track (kept on the track for its IDENTIFIED debrief line): group, kind, range. A track
--- not known friendly is a FIRST_DETECTION debrief line (once per track, when it is made; a re-acquired track keeps
--- its FirstSeenBy, so none again).
function Medusa.Core.IadsNetwork:_noteFirstSensor(track, source, report)
	track.FirstSeenBy = source.groupName
	local sensorCtx = source.sensorCtx
	track.FirstSeenKind = (sensorCtx and sensorCtx.Kind) or source.sourceType
	local sp, rp = sensorCtx and sensorCtx.Position, report.Position
	if sp and rp then
		local dx, dz = rp.x - sp.x, rp.z - sp.z
		track.FirstSeenRangeM = math.sqrt(dx * dx + dz * dz)
	end
	local id = track.TrackIdentification or Medusa.Constants.TrackIdentification.UNKNOWN
	if NOT_HOSTILE_ID[id] then
		return
	end
	local display = Medusa.Entities.Track.displayId(track)
	local alt = track.Position and track.Position.y or nil
	Medusa.Debrief.emit(
		self._id,
		nil,
		"FIRST_DETECTION",
		"track",
		display,
		"id",
		id,
		"sensor",
		track.FirstSeenBy or "unknown",
		"kind",
		track.FirstSeenKind or track.OriginSourceType,
		"range_km",
		track.FirstSeenRangeM and string.format("%.1f", track.FirstSeenRangeM / 1000) or nil,
		"alt_m",
		alt and string.format("%.0f", alt) or nil,
		"alt_band",
		heightBand(alt)
	)
end

--- IDENTIFIED: the first time the network identifies a track BANDIT or HOSTILE (once per track), with the sensor
--- that first held it, its range from that sensor and how long the network held it before the call.
function Medusa.Core.IadsNetwork:_onTrackIdentified(track, from, to)
	local TI = Medusa.Constants.TrackIdentification
	if (to ~= TI.HOSTILE and to ~= TI.BANDIT) or track.DebriefIdentified then
		return
	end
	-- A re-acquired or re-associated track arrives already BANDIT/HOSTILE: the network identified it before.
	if from == TI.HOSTILE or from == TI.BANDIT then
		track.DebriefIdentified = true
		return
	end
	track.DebriefIdentified = true
	local now = GetTime()
	local alt = track.Position and track.Position.y or nil
	local band = heightBand(alt)
	Medusa.Debrief.emit(
		self._id,
		now,
		"IDENTIFIED",
		"track",
		Medusa.Entities.Track.displayId(track),
		"id",
		to,
		"from_id",
		from,
		"sensor",
		track.FirstSeenBy or "unknown",
		"kind",
		track.FirstSeenKind or track.OriginSourceType,
		"range_km",
		track.FirstSeenRangeM and string.format("%.1f", track.FirstSeenRangeM / 1000) or nil,
		"alt_m",
		alt and string.format("%.0f", alt) or nil,
		"alt_band",
		band,
		"held_s",
		track.FirstDetectionTime and string.format("%.0f", now - track.FirstDetectionTime) or nil
	)
end

function Medusa.Core.IadsNetwork:_pollSensors()
	local now = GetTime()
	self:_updateAirborneSensors()
	local pollList = self:_buildPollList()
	local count = #pollList
	if count == 0 then
		return
	end
	local budget = self._sensorPollBudget
	local polled = 0
	local idx = self._sensorPollIndex
	local accum = self._pollDetectionAccum
	local totalDetections = 0
	while polled < budget and polled < count do
		if idx > count then
			idx = 1
		end
		local source = pollList[idx]
		local name = source.groupName
		local reports = self._sensorPollingService:pollSensor(
			name,
			now,
			source.sourceType,
			source.scanRateSec,
			source.sensorCtx,
			source.detectionType
		)
		if not reports then
			self:_removeSensorGroup(name)
		else
			accum[name] = (accum[name] or 0) + #reports
			if #reports == 0 then
				Medusa.Services.MetricsService.inc("medusa_sensor_empty_polls_total")
			end
			totalDetections = totalDetections + #reports
			for i = 1, #reports do
				local track = self._trackManager:processReport(reports[i], now)
				if type(track) == "table" and track.FirstSeenBy == nil then
					self:_noteFirstSensor(track, source, reports[i])
				end
			end
			if source.localRadar and #reports > 0 then
				Medusa.Services.LocalRadarService.onRadarContacts(
					self:_localPictureCtx(),
					source.localRadar,
					reports,
					self._trackManager
				)
			end
		end
		idx = idx + 1
		polled = polled + 1
	end
	self._sensorPollIndex = idx
	if totalDetections > 0 then
		Medusa.Services.MetricsService.inc("medusa_detections_total", totalDetections)
	end
end

--[[
Assignment pipeline (distributed across 5 phases, one phase per assignment tick):
  Phase 0 - Classify:  track identification + aircraft type assessment (chunked)
  Phase 1 - HARM:      HARM detection (chunked) + response + point defense (full pass)
  Phase 2 - Assign:    EMCON self-assign + WTA + retry goHot (full pass, greedy)
  Phase 3 - Maintain:  handoff eval + deactivation checks (chunked) + HARM cleanup
  Phase 4 - EMCON:     emission control policy (chunked)

Each ChunkStep drains its queue up to budget items per tick.
When the queue empties, the next invocation refills from the current store snapshot.
Full pipeline cycle = 5 assignment ticks = 10 ticks = 1 second at 10 Hz.
]]

local _phaseNames = { [0] = "classify", "harm", "assign", "maintain", "emcon" }

function Medusa.Core.IadsNetwork:_runPhase()
	local ctx = self._ctx
	ctx.trackStore = self._trackManager:getStore()
	ctx.batteryStore = self._assetIndex:batteries()
	ctx.batteryRepository = self._assetIndex:batteryRepository()
	ctx.manpadStore = self._assetIndex:manpads()
	ctx.networkedGeoGrid = self._assetIndex:networkedGeoGrid()
	ctx.localGeoGrid = self._assetIndex:localGeoGrid()
	ctx.geoGrid = ctx.networkedGeoGrid
	ctx.spatialIndex = self._spatialIndex
	ctx.sensorStore = self._assetIndex:sensors()
	ctx.now = GetTime()
	ctx.maxRange = self._maxEngagementRange
	ctx.doctrine = self._doctrine
	ctx.networkId = self._id
	ctx.holdBreaksTypes = self._holdBreaksTypes
	if not self._lockReader then
		local network = self
		self._lockReader = function(battery, out)
			return network:_lockedTracksOf(battery, out)
		end
	end
	ctx.lockedTracksOf = self._lockReader
	-- Operators of a busy net take longer to identify (crew factors): identification timers x this.
	ctx.idDwellFactor = 1
	if self._crew and Medusa.Services.CrewFactorsService.isOn(self._doctrine) then
		ctx.idDwellFactor = 1 + Medusa.Constants.CrewFactors.ID_DWELL_LOAD_FACTOR * self._crew.load
	end
	ctx.borderPolygons = self._borderPolygons
	ctx.adizPolygon = self._adizPolygon
	ctx.coalitionId = self._coalitionId
	ctx.hpt = Medusa.hpTimer
	ctx.MS = Medusa.Services.MetricsService

	local phase = self._assignmentPhase
	local ok, err
	if phase == 0 then
		ok, err = pcall(self._phaseClassify, self, ctx)
	elseif phase == 1 then
		ok, err = pcall(self._phaseHarmAndPD, self, ctx)
	elseif phase == 2 then
		ok, err = pcall(self._phaseAssign, self, ctx)
	elseif phase == 3 then
		ok, err = pcall(self._phaseMaintain, self, ctx)
	elseif phase == 4 then
		ok, err = pcall(self._phaseEmcon, self, ctx)
	end

	if not ok then
		self._phaseFailures[phase] = (self._phaseFailures[phase] or 0) + 1
		local count = self._phaseFailures[phase]
		if count == 1 or count % 100 == 0 then
			self._logger:error(
				string.format("phase %s failed (%dx): %s", _phaseNames[phase] or phase, count, tostring(err))
			)
		end
	else
		self._phaseFailures[phase] = 0
	end
	ctx.MS.set("medusa_phase_failures_consecutive", self._phaseFailures[phase] or 0, _phaseLabels[phase])

	self._assignmentPhase = (phase + 1) % 5
end

-- Phase 0: Track classification + aircraft type (chunked by track)
function Medusa.Core.IadsNetwork:_phaseClassify(ctx)
	local TC = Medusa.Services.TrackClassifier
	local step = self._classifyStep
	local t1 = ctx.hpt()

	local guiltEnabled = not ctx.doctrine or ctx.doctrine.GuiltByAssociation ~= false

	local allTracks = ctx.trackStore:getAll(_assignBatteryBuffer)
	local freshCycle = step:fill(allTracks)
	if freshCycle then
		TC.clearPromotedBuffer()
	end

	local processed = 0
	for _ = 1, step.budget do
		local track = step:next()
		if not track then
			break
		end
		local promotion = TC.classifyTrack(track, ctx)
		if promotion then
			TC._promotedBuffer[#TC._promotedBuffer + 1] = promotion
		end
		TC.assessSingleAircraftType(track)
		processed = processed + 1
	end

	if step:isEmpty() and guiltEnabled then
		TC.flushGuiltByAssociation(allTracks, ctx)
	end

	logChunk(self._logger, ctx.MS, "classify", processed, step:remaining())
	ctx.MS.observe("medusa_classification_duration_seconds", ctx.hpt() - t1)
end

-- Phase 1: HARM detection (priority-sorted dual-pass) + response + point defense (full pass)
function Medusa.Core.IadsNetwork:_phaseHarmAndPD(ctx)
	local HDS = Medusa.Services.HarmDetectionService
	local step = self._harmDetectStep
	local t1 = ctx.hpt()

	local allTracks = ctx.trackStore:getAll(_assignBatteryBuffer)
	local trackCount = #allTracks
	local ballisticDt, ballisticMaxT = HDS.getAssessContext(ctx)
	local emitters = HDS.buildEmitterIndex(ctx.batteryStore)

	local totalBudget = math.max(step.budget, math.ceil(trackCount * 0.25))

	-- Build priority keys: confirmed HARMs first, then altitude times speed.
	local AAT = Medusa.Constants.AssessedAircraftType
	local keys = self._harmPriorityKeys
	local sortBuf = self._harmSortBuffer
	local TI = Medusa.Constants.TrackIdentification
	local isProbableDecoy = Medusa.Services.DecoyAssessmentService.isProbable
	local arms, aircraft = 0, 0
	for i = 1, trackCount do
		local track = allTracks[i]
		if track.AssessedAircraftType == AAT.HARM then
			keys[i] = math.huge
			arms = arms + 1
		else
			local vel = track.Velocity
			local alt = track.Position and track.Position.y or 0
			local speed = vel and VecLength2D(vel) or 0
			keys[i] = alt * speed
			local id = track.TrackIdentification
			if (id == TI.HOSTILE or id == TI.BANDIT) and not isProbableDecoy(track) then
				aircraft = aircraft + 1
			end
		end
		sortBuf[i] = i
	end
	self._armsInbound = arms
	self._aircraftTracks = aircraft
	-- Clear excess entries from previous tick
	for i = trackCount + 1, #sortBuf do
		sortBuf[i] = nil
	end
	for i = trackCount + 1, #keys do
		keys[i] = nil
	end

	-- Sort indices descending by priority key
	local byPriority = self._harmPriorityCompare
	if not byPriority then
		byPriority = function(a, b)
			return keys[a] > keys[b]
		end
		self._harmPriorityCompare = byPriority
	end
	table.sort(sortBuf, byPriority)

	-- The tracks this pass visits are the decoy assessment's too (each judged at most once per new scan).
	local visited = self._decoyVisited
	if not visited then
		visited = {}
		self._decoyVisited = visited
	end
	local visitedCount = 0

	-- Pass 1: Priority tier -- top 1/3, evaluated every tick
	local priorityCount = math.ceil(trackCount / 3)
	local priorityProcessed = 0
	for i = 1, priorityCount do
		local track = allTracks[sortBuf[i]]
		if track and track.LifecycleState == _LS.ACTIVE then
			HDS.assessSingleTrack(
				track,
				allTracks,
				ctx.geoGrid,
				ctx.batteryStore,
				ballisticDt,
				ballisticMaxT,
				emitters,
				ctx.networkId
			)
			priorityProcessed = priorityProcessed + 1
			visitedCount = visitedCount + 1
			visited[visitedCount] = track
		end
	end

	-- Pass 2: Normal tier -- remaining tracks, chunked
	local normalBuf = self._harmNormalBuffer
	local normalCount = 0
	for i = priorityCount + 1, trackCount do
		local track = allTracks[sortBuf[i]]
		if track then
			normalCount = normalCount + 1
			normalBuf[normalCount] = track
		end
	end
	for i = normalCount + 1, #normalBuf do
		normalBuf[i] = nil
	end
	step:fill(normalBuf)

	local minNormalBudget = math.floor(step.budget / 3)
	local remainingBudget = totalBudget - priorityProcessed
	local normalBudget = math.max(minNormalBudget, remainingBudget)
	local normalProcessed = 0
	for _ = 1, normalBudget do
		local track = step:next()
		if not track then
			break
		end
		HDS.assessSingleTrack(
			track,
			allTracks,
			ctx.geoGrid,
			ctx.batteryStore,
			ballisticDt,
			ballisticMaxT,
			emitters,
			ctx.networkId
		)
		normalProcessed = normalProcessed + 1
		visitedCount = visitedCount + 1
		visited[visitedCount] = track
	end
	for i = visitedCount + 1, #visited do
		visited[i] = nil
	end

	logChunk(self._logger, ctx.MS, "harm_detect", priorityProcessed + normalProcessed, step:remaining())

	-- Decoy assessment and response (after HARM labels, before point defence reads glide threats), in its own pcall
	-- so a failure there cannot skip HARM response and point defence.
	local decoyOk, decoyErr = pcall(self._phaseDecoy, self, ctx, visitedCount)
	if not decoyOk then
		self._logger:error(string.format("decoy pass failed: %s", tostring(decoyErr)))
	end

	-- Full-pass: HARM response + PD (usually few HARMs, not worth chunking)
	Medusa.Services.HarmResponseService.executeResponse(ctx)
	local pdReleased = Medusa.Services.PointDefenseService.releaseOrphanedDefenders(ctx)
	if pdReleased > 0 or self._pdReassignNeeded then
		Medusa.Services.PointDefenseService.autoAssignShorad(ctx)
		self._pdReassignNeeded = false
	end
	Medusa.Services.PointDefenseService.engageThreats(ctx)

	ctx.MS.observe("medusa_harm_eval_duration_seconds", ctx.hpt() - t1)
end

function Medusa.Core.IadsNetwork:_phaseDecoy(ctx, visitedCount)
	Medusa.Services.DecoyAssessmentService.assess(ctx, self._decoyVisited, visitedCount)
	Medusa.Services.DecoyResponseService.update(ctx)
end

-- Phase 2: EMCON self-assign + WTA assignment + retry goHot (full pass, greedy)
function Medusa.Core.IadsNetwork:_phaseAssign(ctx)
	local TargetAssigner = Medusa.Services.TargetAssigner
	local BAS = Medusa.Services.BatteryActivationService
	local t1 = ctx.hpt()

	local autoAssignments = TargetAssigner.emconSelfAssign(ctx)
	for i = 1, #autoAssignments do
		local a = autoAssignments[i]
		local battery = ctx.batteryStore:get(a.batteryId)
		local track = ctx.trackStore:get(a.trackId)
		if battery and BAS.goHot(battery, ctx.now, "emcon_self_assign", track) then
			self._logger:info(
				string.format(
					"battery %s HOT (EMCON self-assign) for track %s",
					battery.GroupName,
					Medusa.Entities.Track.displayId(track)
				)
			)
		end
	end

	local assignments = TargetAssigner.assignTargets(ctx)
	for i = 1, #assignments do
		local a = assignments[i]
		local track = ctx.trackStore:get(a.trackId)
		if track and track.Position then
			Medusa.Services.ManpadService.cueFromIADS(ctx, track.Position)
		end
		local battery = ctx.batteryStore:get(a.batteryId)
		if battery and BAS.goHot(battery, ctx.now, "assigned", track) then
			self._logger:info(
				string.format("battery %s HOT for track %s", a.batteryId, Medusa.Entities.Track.displayId(track))
			)
		end
	end

	local AS = Medusa.Constants.ActivationState
	local allBatteries = ctx.batteryStore:getAll(_assignBatteryBuffer)
	for i = 1, #allBatteries do
		local battery = allBatteries[i]
		if battery.CurrentTargetTrackId and battery.ActivationState ~= AS.STATE_HOT then
			local track = ctx.trackStore:get(battery.CurrentTargetTrackId)
			if BAS.goHot(battery, ctx.now, "assigned", track) then
				self._logger:info(
					string.format(
						"battery %s HOT for track %s (retry)",
						battery.BatteryId,
						Medusa.Entities.Track.displayId(track)
					)
				)
			end
		end
	end

	ctx.MS.observe("medusa_assignment_duration_seconds", ctx.hpt() - t1)
	ctx.MS.inc("medusa_engagements_assigned_total", #autoAssignments + #assignments)
end

-- Phase 3: Handoff evaluation + deactivation checks (chunked) + HARM cleanup
function Medusa.Core.IadsNetwork:_phaseMaintain(ctx)
	local TargetAssigner = Medusa.Services.TargetAssigner
	local BAS = Medusa.Services.BatteryActivationService
	local t1 = ctx.hpt()

	local allBatteries = ctx.batteryStore:getAll(_assignBatteryBuffer)

	-- Chunked handoff evaluation
	local handoffStep = self._handoffStep
	handoffStep:fill(allBatteries)
	local handoffProcessed = 0
	for _ = 1, handoffStep.budget do
		local battery = handoffStep:next()
		if not battery then
			break
		end
		local result = TargetAssigner.evaluateSingleHandoff(battery, ctx)
		if result then
			local bat = ctx.batteryStore:get(result.batteryId)
			if bat then
				local track = ctx.trackStore:get(result.trackId)
				Medusa.Entities.Battery.releaseTrack(bat, ctx.trackStore)
				bat.LastAssignmentChangeTime = ctx.now
				Medusa.Entities.Battery.beginLastChance(bat, result.trackId, ctx.doctrine.HoldDownSec or 15)
				ctx.MS.inc("medusa_last_chance_activated_total")
				self._logger:info(
					string.format(
						"battery %s released track %s (last-chance)",
						bat.GroupName,
						Medusa.Entities.Track.displayId(track)
					)
				)
			end
		end
		handoffProcessed = handoffProcessed + 1
	end
	logChunk(self._logger, ctx.MS, "handoff", handoffProcessed, handoffStep:remaining())

	-- Chunked deactivation checks
	local deactStep = self._deactivationStep
	deactStep:fill(allBatteries)
	local deactProcessed = 0
	for _ = 1, deactStep.budget do
		local battery = deactStep:next()
		if not battery then
			break
		end
		local result = TargetAssigner.checkSingleDeactivation(battery, ctx)
		if result then
			Medusa.Entities.Battery.releaseTrack(result.battery, ctx.trackStore)
			if BAS.goCold(result.battery, ctx.now, ctx.trackStore) then
				self._logger:info(string.format("battery %s deactivated (%s)", result.battery.GroupName, result.reason))
			end
		end
		deactProcessed = deactProcessed + 1
	end
	logChunk(self._logger, ctx.MS, "deactivation", deactProcessed, deactStep:remaining())

	-- Full-pass: clear expired HARM shutdowns
	for i = 1, #allBatteries do
		local battery = allBatteries[i]
		if battery.HarmShutdownUntil and ctx.now >= battery.HarmShutdownUntil then
			battery.HarmShutdownUntil = nil
		end
	end

	ctx.MS.observe("medusa_handoff_duration_seconds", ctx.hpt() - t1)
end

-- Phase 4: EMCON policy (full pass, index-dependent rotation math prevents chunking)
function Medusa.Core.IadsNetwork:_phaseEmcon(ctx)
	local t1 = ctx.hpt()
	Medusa.Services.EmconService.applyPolicy(ctx, self)
	self:_decayEffectivePkFloor(ctx.now)
	ctx.MS.observe("medusa_emcon_duration_seconds", ctx.hpt() - t1)
end

function Medusa.Core.IadsNetwork:_runManpadPhase()
	local ctx = self._manpadCtx
	ctx.manpadStore = self._assetIndex:manpads()
	ctx.trackStore = self._trackManager:getStore()
	ctx.networkedGeoGrid = self._assetIndex:networkedGeoGrid()
	ctx.localGeoGrid = self._assetIndex:localGeoGrid()
	ctx.now = GetTime()
	ctx.posture = self._doctrine and self._doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
	ctx.doctrine = self._doctrine
	ctx.coalitionId = self._coalitionId
	ctx.surprised = self._crew ~= nil
		and Medusa.Services.CrewFactorsService.isOn(self._doctrine)
		and self._crew.readiness == Medusa.Constants.Readiness.SURPRISED
	local MS = Medusa.Services.MetricsService
	local hpt = Medusa.hpTimer
	local t1 = hpt()

	local ok, err = pcall(Medusa.Services.ManpadService.evaluate, ctx)
	if not ok then
		self._logger:error(string.format("manpad phase failed: %s", tostring(err)))
	end
	MS.observe("medusa_manpad_eval_duration_seconds", hpt() - t1)
end

function Medusa.Core.IadsNetwork:_runAaaPhase()
	local ctx = self._aaaCtx
	ctx.networkId = self._id
	ctx.barrageState = self._aaaBarrageState
	ctx.batteryStore = self._assetIndex:batteries()
	ctx.trackStore = self._trackManager:getStore()
	ctx.localGeoGrid = self._assetIndex:localGeoGrid()
	ctx.spatialIndex = self._spatialIndex
	ctx.now = GetTime()
	ctx.posture = self._doctrine and self._doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
	ctx.doctrine = self._doctrine
	ctx.coalitionId = self._coalitionId
	local MS = Medusa.Services.MetricsService
	local hpt = Medusa.hpTimer
	local t1 = hpt()
	local ok, err = pcall(Medusa.Services.AaaService.evaluate, ctx)
	if not ok then
		self._logger:error(string.format("AAA phase failed: %s", tostring(err)))
	end
	MS.observe("medusa_aaa_eval_duration_seconds", hpt() - t1)
end

function Medusa.Core.IadsNetwork:_runUnitPositionRefreshPhase()
	local visited, refreshed, aaaRefreshed, manpadRefreshed =
		Medusa.Services.CrewPerceptionService.refreshUnitPositions({
			batteryRepository = self._assetIndex:batteryRepository(),
			spatialIndex = self._spatialIndex,
			now = GetTime(),
			budget = Medusa.Constants.CrewSuppression.UNIT_POSITION_REFRESH_BUDGET,
		})
	if refreshed > 0 then
		Medusa.Services.MetricsService.inc("medusa_battery_unit_position_refreshes_total", refreshed)
	end
	if aaaRefreshed > 0 then
		Medusa.Services.MetricsService.inc("medusa_aaa_position_refreshes_total", aaaRefreshed)
	end
	if manpadRefreshed > 0 then
		Medusa.Services.MetricsService.inc("medusa_manpad_position_refreshes_total", manpadRefreshed)
	end
	if Medusa.Logger._level == "DEBUG" or Medusa.Logger._level == "TRACE" then
		self._logger:debug(string.format("unit position refresh: visited=%d refreshed=%d", visited, refreshed))
	end
end

function Medusa.Core.IadsNetwork:_applyDynamicBatteryRanges(battery)
	local probing = self._probingService
	local iads = self
	local maxDetRange = nil
	local uncachedTypes = nil
	local uncachedCount = 0
	for i = 1, #battery.Units do
		local unit = battery.Units[i]
		local typeName = unit.UnitTypeName
		if Medusa.Entities.Battery.canSupplyDetectionRange(battery, unit) and typeName then
			local caps = probing:getCapabilities(typeName)
			if caps and caps.detectionRangeMax then
				if not maxDetRange or caps.detectionRangeMax > maxDetRange then
					maxDetRange = caps.detectionRangeMax
				end
			elseif caps == nil then
				uncachedCount = uncachedCount + 1
				if not uncachedTypes then
					uncachedTypes = {}
				end
				uncachedTypes[typeName] = true
			end
		end
	end

	if maxDetRange then
		battery.DetectionRangeMax = maxDetRange
		Medusa.Entities.Battery.computeEngagementRange(battery)
		self._spatialIndex:syncBattery(battery)
		self:_updateMaxEngagementRange(battery)
		self._logger:info(
			string.format("dynamic battery %s: applied cached detection range %.0fm", battery.GroupName, maxDetRange)
		)
	end

	if uncachedCount == 0 then
		return
	end

	if not Medusa.Config:get().AllowDynamicProbing then
		self._logger:info(
			string.format(
				"dynamic battery %s: %d unit types not in probe cache (AllowDynamicProbing=false)",
				battery.GroupName,
				uncachedCount
			)
		)
		return
	end

	local typePositions = {}
	for typeName in pairs(uncachedTypes) do
		typePositions[typeName] = battery.Position
	end

	probing:probeAll(typePositions, function()
		iads:_onProbingComplete()
	end)
end

--- Probes the reach of every radar type the network holds (once, at the first tick). With nothing to probe (every
--- group late-activated) probing is complete at once, so radar groups added later are classified.
function Medusa.Core.IadsNetwork:_startProbing()
	local iads = self
	self._probingService:probeAll(self:_collectProbeTargets(), function()
		iads:_onProbingComplete()
	end)
end

function Medusa.Core.IadsNetwork:_onProbingComplete()
	local probing = self._probingService
	self._probeComplete = true
	self:_resolveDeferredGroups()
	self:_applyManpadRadarRanges()
	local sensorCount = probing:applySensorRanges(self._assetIndex:sensors())
	local batteryCount = probing:applyBatteryRanges(self._assetIndex:batteries())
	self._logger:info(
		string.format("probing complete: applied ranges to %d sensors, %d batteries", sensorCount, batteryCount)
	)
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		self._spatialIndex:syncBattery(batteries[i])
		self:_updateMaxEngagementRange(batteries[i])
	end
	self:_classifyLocalRadars()
end

function Medusa.Core.IadsNetwork:tick()
	if not self._running then
		return
	end
	self._tickCounter = self._tickCounter + 1

	local MetricsService = Medusa.Services.MetricsService
	MetricsService.setContext(self._metricLabels)
	Medusa.Debrief.setNetwork(self._id)
	MetricsService.inc("medusa_ticks_total")

	local now = GetTime()
	local hpt = Medusa.hpTimer
	local t0 = hpt()
	local memBefore = collectgarbage("count")
	self:_runBlackBoxWeaponObservations(now)

	if self._tickCounter == 1 then
		self._lastScanTime = now
		self:_runScanAndLog()
		self:_populateGeoGrid()
		self:_fastErectBatteries()
		self:_applyInitialCrewSuppression(now)
		self:_probeAirborneSensors()
		self:_startProbing()
		-- Defer doctrine state application until erect animations complete
		local network = self
		ScheduleOnce(function()
			if not network._running then
				return
			end
			network:_initializeBatteryStates()
			local initCtx = {
				batteryStore = network._assetIndex:batteries(),
				sensorStore = network._assetIndex:sensors(),
				geoGrid = network._assetIndex:networkedGeoGrid(),
				doctrine = network._doctrine,
				now = GetTime(),
			}
			Medusa.Services.PointDefenseService.autoAssignShorad(initCtx)
			Medusa.Services.EmconService.applyPolicy(initCtx, network)
			Medusa.Services.EmconService.logSchedule(initCtx)
			network._erectComplete = true
			network._logger:info("erect complete: doctrine states applied")
		end, nil, 60)
		return
	end

	self._discovery:processDynamicAdds(2)
	self:_processDeathEvents(2)
	self:_processHitEvents(Medusa.Constants.CrewSuppression.HIT_EVENT_PROCESSING_BUDGET)
	self:_processTerminalEvents(
		Medusa.Constants.CrewSuppression.IMPACT_PROCESSING_BUDGET,
		Medusa.Constants.CrewSuppression.IMPACT_UNIT_VISIT_BUDGET
	)
	self:_processShotEvents(2)
	self:_processKillEvents(2)
	self:_checkRearming(now)

	local t1 = hpt()
	self:_pollSensors()
	MetricsService.observe("medusa_poll_sensors_duration_seconds", hpt() - t1)

	t1 = hpt()
	self._trackManager:pruneStale(now)
	MetricsService.observe("medusa_prune_stale_duration_seconds", hpt() - t1)

	if self._erectComplete and ((self._tickCounter + self._phaseOffset) % self._assignmentInterval) == 0 then
		self:_runPhase()
	end

	if self._erectComplete and ((self._tickCounter + self._phaseOffset) % self._manpadInterval) == 0 then
		self:_runManpadPhase()
	end

	if self._erectComplete and ((self._tickCounter + self._phaseOffset) % self._aaaInterval) == 0 then
		self:_runAaaPhase()
	end

	if self._erectComplete and ((self._tickCounter + self._phaseOffset) % self._localPictureInterval) == 5 then
		self:_runLocalPicturePhase()
	end

	if self._erectComplete then
		self:_runObserverLook()
		self:_runEsmLook()
	end

	if self._erectComplete and ((self._tickCounter + self._phaseOffset) % self._unitPosRefreshInterval) == 0 then
		self:_runUnitPositionRefreshPhase()
	end

	if (self._tickCounter % 4) ~= 0 then
		MetricsService.set("medusa_tick_memory_before_kb", memBefore)
		MetricsService.set("medusa_tick_memory_after_kb", collectgarbage("count"))
		MetricsService.observe("medusa_tick_duration_seconds", hpt() - t0)
		return
	end
	if (now - self._lastScanTime) < 1 then
		MetricsService.set("medusa_tick_memory_before_kb", memBefore)
		MetricsService.set("medusa_tick_memory_after_kb", collectgarbage("count"))
		MetricsService.observe("medusa_tick_duration_seconds", hpt() - t0)
		return
	end
	self._lastScanTime = now
	self:_runScanAndLog()

	self:_logAssetSummary(now)

	MetricsService.set("medusa_tick_memory_before_kb", memBefore)
	MetricsService.set("medusa_tick_memory_after_kb", collectgarbage("count"))
	MetricsService.observe("medusa_tick_duration_seconds", hpt() - t0)
end

function Medusa.Core.IadsNetwork:_scheduleNext()
	self._timerId = ScheduleOnce(self._tickCallback, nil, self._tickIntervalSec)
end

function Medusa.Core.IadsNetwork:_onTick()
	if not self._running then
		return
	end
	local ok, err = pcall(self.tick, self)
	if not ok then
		self._tickFailures = self._tickFailures + 1
		if self._tickFailures == 1 or self._tickFailures % 100 == 0 then
			self._logger:error(
				string.format("tick %d failed (%dx): %s", self._tickCounter, self._tickFailures, tostring(err))
			)
		end
		if self._tickFailures >= 1000 then
			self._logger:error(
				string.format(
					"Medusa has experienced an unrecoverable failure for the last %.0f seconds. Attempting to release all batteries to autonomous DCS AI control and shutting down.",
					1000 * self._tickIntervalSec
				)
			)
			local ok, batteries = pcall(function()
				return self._assetIndex:batteryRepository():getAll()
			end)
			if not ok then
				self._logger:error(string.format("getAll failed during shutdown: %s", tostring(batteries)))
				self._running = false
				return
			end
			for i = 1, #batteries do
				pcall(Medusa.Services.BatteryActivationService.erectGroup, batteries[i].GroupName)
				pcall(Medusa.Services.BatteryActivationService.releaseDecoyResponse, batteries[i])
			end
			self:_releaseLocalDefenses()
			self._running = false
			return
		end
	else
		self._tickFailures = 0
	end
	Medusa.Services.MetricsService.set("medusa_tick_failures_consecutive", self._tickFailures)
	self:_scheduleNext()
end

function Medusa.Core.IadsNetwork:getHierarchy()
	return self._hierarchy
end

function Medusa.Core.IadsNetwork:getTrackManager()
	return self._trackManager
end

function Medusa.Core.IadsNetwork:getAssetIndex()
	return self._assetIndex
end

function Medusa.Core.IadsNetwork:getDoctrine()
	return self._doctrine
end

function Medusa.Core.IadsNetwork:getBorderPolygons()
	return self._borderPolygons
end

function Medusa.Core.IadsNetwork:getBorderPolygonsLL()
	return self._borderPolygonsLL
end

function Medusa.Core.IadsNetwork:getPosture()
	return self._doctrine and self._doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
end
