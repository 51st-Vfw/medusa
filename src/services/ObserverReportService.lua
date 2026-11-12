require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Battery")
require("services.BatteryActivationService")
require("services.EmconService")
require("services.SensorPollingService")
require("services.LocalRadarService")
require("core.Chance")
require("core.Debrief")
require("services.CrewFactorsService")

--[[
    OBSERVER REPORT SERVICE

    What this service does
    - Lets the crews of managed ground groups (SAM batteries, MANPAD and AAA groups, ground sensor groups) and
      observer posts (groups named with the "obs"/"observer" role token) look for aircraft, a few looks a second
      for the whole network, round-robin, at most one per tick (doctrine ObserverReports). A look is
      SensorPollingService.observeAirspace: sight (scaled by night and weather) with terrain line of sight, or hearing
      a low aircraft a few km away.
    - Radios what a crew saw or heard as a coarse report (position to a km or two, 8-point heading, low/medium/high,
      fast/slow, jet or helicopter, one/two/several, hostile only when seen close enough to tell, else unidentified,
      a type only when DCS flags it known). Reports arrive after a radio delay (30 s to minutes, longer at night or
      when the net is busy) and some are lost (Constants.Observer).
    - A delivered report cues MANPAD and AAA crews near it and keeps local cueing radars that cover it up. A report
      of a hostile also wakes a dark short- or medium-range SAM battery whose engagement range covers it to WARM
      (radar on, weapons hold) for a while, unless the network already holds a track there or the mission sets an
      EMCON policy for the battery's role. It never makes a track, a firing solution or a HOT battery, and alert
      zones do not count it: it is its own low-confidence report type, kept here.
    - Local initiative (doctrine LocalInitiative): a crew that sees or hears an aircraft itself brings its local
      cueing radar up at once; a dark SAM battery whose crew sees a hostile comes up WARM under the same rules as a
      report. Never under ROE HOLD, HARM shutdown or crew suppression.
    - Crew factors (doctrine CrewFactors, on by default; Constants.CrewFactors): the reporting group's crew skill
      (the best mission-editor skill among its units; the doctrine's CrewSuppression.DefaultCrewSkill for units the
      mission file does not list, such as groups spawned during the mission) and the network's readiness decide
      whether the crew calls it in at all, how fast and how precisely; readiness and net load decide whether the
      call reaches the right people (best when ALERTED with a calm net). Observer posts are trained watchers: they
      count one skill level higher (EXCELLENT stays), keep their full look rate when SURPRISED (other crews look half
      as often, skilled crews less so) and get more reports through under surprise (CrewFactors.OBSERVER_*). The
      crew-side SURPRISED penalties shrink with skill (CrewFactors.SURPRISE_SHARE); delivery does not. Off: reports
      and looks use Constants.Observer alone, ignoring skill, readiness and load.
    - Training mode: a report's position error is its expected size in a fixed direction per group and report
      (SensorPollingService.observeAirspace with a seed), so reports are deterministic but not perfect.

    How others use it
    - IadsNetwork calls update once a second (radio, roster) and look every tick with the local-picture context.
    - Logs (INFO): "observer report sent: ...", "observer report received: ...", "observer report lost: ...",
      "observer report not made: ...", "observer report wakes <group> WARM ...", "local initiative: <group> ...",
      once per network "crew roster: ..." (crew factors on); DEBRIEF REPORT_NOT_MADE, REPORT_LOST and
      REPORT_DELIVERED (with what it caused and the net load), CREW_ROSTER.
--]]

Medusa.Services.ObserverReportService = {}

local C = Medusa.Constants
local OBS = C.Observer
local ORS = C.ObserverReportState
local AS = C.ActivationState
local BR = C.BatteryRole
local BOS = C.BatteryOperationalStatus
local MWR = C.Manpad.WakeReason
local Battery = Medusa.Entities.Battery
local BAS = Medusa.Services.BatteryActivationService
local LocalRadarService = Medusa.Services.LocalRadarService
local Chance = Medusa.Chance
local Debrief = Medusa.Debrief
local CF = C.CrewFactors
local CS = C.CrewSkill
local SKILL_LEVEL = C.CrewSkillLevel
local logger = Medusa.Logger:ns("ObserverReportService")

local FILTER_BATTERY = { "Battery" }
local FILTER_TRACK = { "Track" }
local LS_ACTIVE = C.TrackLifecycleState.ACTIVE
local EMPTY = {}
local sensorBuffer = {}

function Medusa.Services.ObserverReportService.newState(random)
	return {
		roster = {},
		rosterCount = 0,
		rosterTime = nil,
		cursor = 0,
		tokens = 0,
		tokenTime = nil,
		lastReport = {},
		reportCount = {},
		nameHash = {},
		rosterLogged = false,
		reports = {},
		pending = 0,
		woken = {},
		look = { Position = nil, CoalitionId = nil, GroupName = nil, Random = random },
		seen = { Position = { x = 0, y = 0, z = 0 } },
		random = random or math.random,
	}
end

local function isShip(groupCategory)
	return groupCategory == Group.Category.SHIP or groupCategory == "SHIP" or groupCategory == "ship"
end

local function rosterEntry(state, groupName, position, battery)
	state.rosterCount = state.rosterCount + 1
	local entry = state.roster[state.rosterCount]
	if not entry then
		entry = {}
		state.roster[state.rosterCount] = entry
	end
	if entry.GroupName ~= groupName then
		entry.LookCredit = nil -- a pooled slot: the surprised look credit belongs to the group that held it
	end
	entry.GroupName = groupName
	entry.Position = position
	entry.Battery = battery
	entry.Skill = nil
	entry.MissionSkill = nil
	entry.Defaulted = false
	entry.Observer = false
	return entry
end

--- The skill a crew falls back to: the doctrine's CrewSuppression.DefaultCrewSkill (AVERAGE by default).
function Medusa.Services.ObserverReportService.defaultSkill(doctrine)
	local cs = doctrine and doctrine.CrewSuppression
	local skill = cs and cs.DefaultCrewSkill
	return SKILL_LEVEL[skill] and skill or C.CrewSuppression.DEFAULT_CREW_SKILL
end

local function better(best, skill)
	if SKILL_LEVEL[skill] and (not best or SKILL_LEVEL[skill] > SKILL_LEVEL[best]) then
		return skill
	end
	return best
end

--- The skill of the crew that calls a report in: the best skill among the group's units. Battery units carry the
--- skill resolved when the battery was built; other groups look their unit names up in the mission's skill index
--- (Medusa.Services.MissionUnitSkillIndex, read once from the mission file at load). A unit the index does not
--- list (spawned during the mission, or a skill such as Random or Player) counts as the doctrine's default.
--- Returns the skill and true when no unit's skill was known (the group took the default).
function Medusa.Services.ObserverReportService.groupSkill(doctrine, skillIndex, battery, unitNames)
	local best = nil
	local defaulted = nil
	if battery and battery.Units then
		for i = 1, #battery.Units do
			local u = battery.Units[i]
			if u.CrewSkillDefaulted then
				defaulted = defaulted or u.CrewSkill
			else
				best = better(best, u.CrewSkill)
			end
		end
	end
	if skillIndex and unitNames then
		for i = 1, #unitNames do
			best = better(best, skillIndex:get(unitNames[i]))
		end
	end
	if best then
		return best, false
	end
	return better(nil, defaulted) or Medusa.Services.ObserverReportService.defaultSkill(doctrine), true
end
local groupSkill = Medusa.Services.ObserverReportService.groupSkill

local unitNameBuffer = {}

local function addBatteries(ctx, state, batteries)
	for i = 1, #batteries do
		local b = batteries[i]
		if b.Position and not isShip(b.GroupCategory) and b.OperationalStatus ~= BOS.DESTROYED then
			local entry = rosterEntry(state, b.GroupName, b.Position, b)
			if ctx.crew then
				entry.MissionSkill, entry.Defaulted = groupSkill(ctx.doctrine, nil, b, nil)
				entry.Skill = entry.MissionSkill
			end
		end
	end
end

local function rebuildRoster(ctx, state)
	state.rosterCount = 0
	if ctx.batteryStore then
		addBatteries(ctx, state, ctx.batteryStore:getAll())
	end
	if ctx.manpadStore then
		addBatteries(ctx, state, ctx.manpadStore:getAll())
	end
	if ctx.sensorStore then
		local names = ctx.sensorStore:getUniqueGroupNames()
		for i = 1, #names do
			local sensors = ctx.sensorStore:getByGroupName(names[i], sensorBuffer)
			local first = sensors[1]
			if first and first.Position and not first.IsAirborne and not isShip(first.GroupCategory) then
				local entry = rosterEntry(state, names[i], first.Position, nil)
				if ctx.crew then
					for j = 1, #sensors do
						unitNameBuffer[j] = sensors[j].UnitName
					end
					for j = #sensors + 1, #unitNameBuffer do
						unitNameBuffer[j] = nil
					end
					entry.MissionSkill, entry.Defaulted =
						groupSkill(ctx.doctrine, ctx.crewSkillIndex, nil, unitNameBuffer)
					entry.Skill = entry.MissionSkill
				end
			end
		end
	end
	if ctx.observerStore then
		local posts = ctx.observerStore:getAll()
		local i = 1
		while i <= #posts do
			local post = posts[i]
			local position = Medusa.Services.SensorPollingService.observerPosition(post.UnitNames)
			if position then
				post.Position = position
				local entry = rosterEntry(state, post.GroupName, position, nil)
				-- A listening station's crew looks out too, but only a named observer post is a trained watcher.
				entry.Observer = post.Watch ~= false
				if ctx.crew then
					entry.MissionSkill, entry.Defaulted =
						groupSkill(ctx.doctrine, ctx.crewSkillIndex, nil, post.UnitNames)
					entry.Skill = entry.Observer and CF.OBSERVER_SKILL_UP[entry.MissionSkill] or entry.MissionSkill
				end
				i = i + 1
			else
				local what = (post.Esm and post.Watch == false) and "listening station" or "observer post"
				logger:info(string.format("%s %s: no crew left", what, post.GroupName))
				ctx.observerStore:removeByGroupName(post.GroupName)
			end
		end
	end
	local roster = state.roster
	for i = state.rosterCount + 1, #roster do
		roster[i] = nil
	end
	if state.cursor > state.rosterCount then
		state.cursor = 0
	end
	state.rosterTime = ctx.now
	if ctx.crew and not state.rosterLogged then
		state.rosterLogged = true
		Medusa.Services.ObserverReportService.logRoster(ctx, state)
	end
end

local SKILL_ORDER = { CS.AVERAGE, CS.GOOD, CS.HIGH, CS.EXCELLENT }

local function skillCounts(state, observers)
	local counts, n = {}, 0
	for i = 1, state.rosterCount do
		local entry = state.roster[i]
		if entry.Observer == observers and entry.MissionSkill then
			counts[entry.MissionSkill] = (counts[entry.MissionSkill] or 0) + 1
			n = n + 1
		end
	end
	local parts = {}
	for i = 1, #SKILL_ORDER do
		local c = counts[SKILL_ORDER[i]]
		if c then
			parts[#parts + 1] = SKILL_ORDER[i] .. ":" .. c
		end
	end
	return n, table.concat(parts, ",")
end

--- One line per network (at its first roster, crew factors on): the observer posts and other crews by their mission
--- skill, and how many groups took the default skill (no unit's skill in the mission file).
function Medusa.Services.ObserverReportService.logRoster(ctx, state)
	local observers, observerSkills = skillCounts(state, true)
	local crews, crewSkills = skillCounts(state, false)
	local defaulted = 0
	for i = 1, state.rosterCount do
		if state.roster[i].Defaulted then
			defaulted = defaulted + 1
		end
	end
	local default = Medusa.Services.ObserverReportService.defaultSkill(ctx.doctrine)
	logger:info(
		string.format(
			"crew roster of network %s: %d observer posts (%s), %d other crews (%s); %d on the default skill %s",
			tostring(ctx.networkId),
			observers,
			observerSkills ~= "" and observerSkills or "none",
			crews,
			crewSkills ~= "" and crewSkills or "none",
			defaulted,
			default
		)
	)
	Debrief.emit(
		ctx.networkId,
		ctx.now,
		"CREW_ROSTER",
		"observers",
		observers,
		"observer_skills",
		observerSkills ~= "" and observerSkills or nil,
		"crews",
		crews,
		"crew_skills",
		crewSkills ~= "" and crewSkills or nil,
		"defaulted",
		defaulted,
		"default_skill",
		default
	)
end

local function describe(r)
	local what = string.format("%s %s %s%s", r.Count, r.Identity, r.Kind, r.Count == "one" and "" or "s")
	if r.TypeName then
		what = what .. " (" .. r.TypeName .. ")"
	end
	return string.format(
		"%s %s, %s %s%s near (%.0f, %.0f) +-%.1f km",
		r.Heard and "heard" or "saw",
		what,
		r.Height,
		r.Speed,
		r.Heading8 and (" heading " .. r.Heading8) or "",
		r.Position.x,
		r.Position.z,
		r.ErrorM / 1000
	)
end

--- A battery that may bring its radar up WARM without the network: a dark SAM battery with a search radar, not a
--- local cueing radar (those are cued instead), not in HARM shutdown, not suppressed, not destroyed.
local function canComeUp(ctx, b)
	return b.ActivationState == AS.STATE_COLD
		and b.Role ~= BR.MANPAD
		and b.Role ~= BR.AAA
		and not b.LocalRadar
		and b.HarmShutdownUntil == nil
		and b.OperationalStatus ~= BOS.DESTROYED
		and b.OperationalStatus ~= BOS.INOPERATIVE
		and Battery.hasSearchRadar(b)
		and not Battery.isCrewSuppressed(b)
		and not (ctx.doctrine and ctx.doctrine.ROE == C.ROEState.HOLD)
end

--- A SAM a hostile report (or its own crew's sighting) may bring up: a short- or medium-range role
--- (Observer.WAKE_ROLES) whose EMCON the mission does not set (an ambush site set to MINIMIZE stays dark).
local function mayWake(ctx, b)
	return OBS.WAKE_ROLES[b.Role] == true
		and Medusa.Services.EmconService.missionPolicy(ctx.doctrine, b.Role) == nil
		and canComeUp(ctx, b)
end

--- True when the network picture already holds a track within Observer.TRACK_NEAR_M of `position`: the network
--- engages what it tracks, so a report there wakes nothing.
local function trackNear(ctx, position)
	local grid, store = ctx.networkedGeoGrid, ctx.trackStore
	if not grid or not store then
		return false
	end
	local ids = grid:queryRadius(position, OBS.TRACK_NEAR_M, FILTER_TRACK).TrackIds or EMPTY
	for id in pairs(ids) do
		local t = store:get(id)
		if t and t.LifecycleState == LS_ACTIVE then
			return true
		end
	end
	return false
end

local function holdWarm(b, untilTime, now, reason)
	if not BAS.goWarm(b, now, reason) then
		return false
	end
	if not b.CueWarmUntil or b.CueWarmUntil < untilTime then
		b.CueWarmUntil = untilTime
	end
	return true
end

local function localInitiative(ctx, entry, seen)
	local doctrine = ctx.doctrine
	if doctrine and doctrine.LocalInitiative == false then
		return
	end
	if doctrine and doctrine.ROE == C.ROEState.HOLD then
		return
	end
	local how = seen.Heard and "heard" or "saw"
	local record = ctx.localRadars and ctx.localRadars.byGroup[entry.GroupName]
	if record then
		LocalRadarService.cueRadar(ctx, record, "local initiative")
		logger:info(
			string.format(
				"local initiative: %s cues its local radar (own crew %s a %s)",
				entry.GroupName,
				how,
				seen.Kind
			)
		)
		return
	end
	local b = entry.Battery
	if
		b
		and seen.Identity == "hostile"
		and mayWake(ctx, b)
		and not trackNear(ctx, seen.Position)
		and holdWarm(b, ctx.now + OBS.WARM_HOLD_SEC, ctx.now, "own_crew_" .. how)
	then
		logger:info(
			string.format("local initiative: %s comes up WARM (own crew %s a %s)", entry.GroupName, how, seen.Kind)
		)
	end
end

local function freeEntry(state)
	local reports = state.reports
	for i = 1, OBS.MAX_PENDING do
		local r = reports[i]
		if not r then
			r = { State = ORS.FREE, Position = { x = 0, y = 0, z = 0 } }
			reports[i] = r
		end
		if r.State == ORS.FREE then
			return r
		end
	end
	return nil
end

--- Crew factors: a readiness multiplier `factor` for a crew of `skill`: under surprise the penalty keeps only
--- CrewFactors.SURPRISE_SHARE of its size (skilled crews shrug surprise off faster); other readiness as is.
local function readinessFactor(factor, skill, readiness)
	factor = factor or 1
	if readiness ~= C.Readiness.SURPRISED then
		return factor
	end
	local share = CF.SURPRISE_SHARE[skill] or CF.SURPRISE_SHARE[CS.AVERAGE]
	return 1 + (factor - 1) * share
end

--- Crew factors: the chance a crew of `skill` calls a report in at all at `readiness`.
function Medusa.Services.ObserverReportService.reportMadeChance(skill, readiness)
	return (CF.REPORT_MADE[skill] or CF.REPORT_MADE[CS.AVERAGE])
		* readinessFactor(CF.READINESS_MADE[readiness], skill, readiness)
end

--- Crew factors: the share of its turns a crew of `skill` looks for aircraft at `readiness`.
function Medusa.Services.ObserverReportService.lookRate(skill, readiness)
	if readiness ~= C.Readiness.SURPRISED then
		return 1
	end
	return readinessFactor(1 / CF.SURPRISED_LOOK_EVERY, skill, readiness)
end

--- Crew factors: the radio delay window { lo, hi } (s) of a crew of `skill` at `readiness`, by night or day, on a
--- net at `load`.
function Medusa.Services.ObserverReportService.reportDelayRange(skill, readiness, night, load)
	local window = CF.REPORT_DELAY_SEC[skill] or CF.REPORT_DELAY_SEC[CS.AVERAGE]
	local factor = readinessFactor(CF.READINESS_DELAY[readiness], skill, readiness)
		* (night and OBS.NIGHT_DELAY_FACTOR or 1)
	local busy = (load or 0) * CF.LOAD_DELAY_MAX_SEC
	return window[1] * factor + busy, window[2] * factor + busy
end

--- Crew factors: the chance a report reaches the right people at `readiness` on a net at `load`, by night or day;
--- an observer post's under surprise is CrewFactors.OBSERVER_SURPRISED_DELIVERED (it knows whom to call).
function Medusa.Services.ObserverReportService.deliveryChance(readiness, load, night, observer)
	local base = CF.READINESS_DELIVERED[readiness] or CF.READINESS_DELIVERED[C.Readiness.ENGAGED]
	if observer and readiness == C.Readiness.SURPRISED then
		base = CF.OBSERVER_SURPRISED_DELIVERED
	end
	return base * (1 - CF.LOAD_DELIVERY_PENALTY * (load or 0)) * (night and CF.NIGHT_DELIVERY_FACTOR or 1)
end

--- Crew factors: the position error factor of a crew of `skill`.
function Medusa.Services.ObserverReportService.positionErrorScale(skill)
	return CF.POSITION_ERROR_SCALE[skill] or CF.POSITION_ERROR_SCALE[CS.AVERAGE]
end

local ORSvc = Medusa.Services.ObserverReportService

local function loadText(load)
	return load and string.format("%.2f", load) or nil
end

--- Crew factors: does the crew call it in at all? Logs a report not made.
local function reportMade(ctx, state, entry, seen, training)
	local crew = ctx.crew
	local skill = entry.Skill or ORSvc.defaultSkill(ctx.doctrine)
	if Chance.chance(training, ORSvc.reportMadeChance(skill, crew.readiness), state.random) then
		return true
	end
	local mission = entry.MissionSkill or skill
	logger:info(
		string.format(
			"observer report not made: %s (%s crew%s, %s) saw a %s %s",
			entry.GroupName,
			mission,
			entry.Observer and (", trained observer: " .. skill) or "",
			crew.readiness,
			seen.Identity,
			seen.Kind
		)
	)
	Debrief.emit(
		ctx.networkId,
		ctx.now,
		"REPORT_NOT_MADE",
		"from",
		entry.GroupName,
		"skill",
		mission,
		"skill_as",
		entry.Observer and skill or nil,
		"readiness",
		crew.readiness,
		"saw",
		seen.Identity .. "_" .. seen.Kind,
		"heard",
		seen.Heard and "true" or "false",
		"load",
		loadText(crew.load)
	)
	return false
end

--- Radios what the crew saw. Returns false when the crew did not get a report out at all (crew factors).
local function send(ctx, state, entry, seen)
	local now = ctx.now
	local crew = ctx.crew
	local training = Chance.isTraining(ctx.doctrine)
	if crew and not reportMade(ctx, state, entry, seen, training) then
		return false
	end
	local r = freeEntry(state)
	if not r then
		logger:info(string.format("observer report lost: from %s (radio net saturated)", entry.GroupName))
		Debrief.emit(
			ctx.networkId,
			now,
			"REPORT_LOST",
			"from",
			entry.GroupName,
			"why",
			"net_saturated",
			"load",
			loadText(crew and crew.load)
		)
		return true
	end
	local random = state.random
	local delay, lost
	if crew then
		local skill = entry.Skill or ORSvc.defaultSkill(ctx.doctrine)
		local lo, hi = ORSvc.reportDelayRange(skill, crew.readiness, seen.Night, crew.load)
		delay = Chance.uniform(training, lo, hi, random)
		lost = not Chance.chance(
			training,
			ORSvc.deliveryChance(crew.readiness, crew.load, seen.Night, entry.Observer),
			random
		)
	else
		delay = Chance.uniform(training, OBS.DELAY_MIN_SEC, OBS.DELAY_MAX_SEC, random)
		if seen.Night then
			delay = delay * OBS.NIGHT_DELAY_FACTOR
		end
		delay = delay + math.min(OBS.BUSY_DELAY_MAX_SEC, state.pending * OBS.BUSY_DELAY_SEC)
		local loss = (seen.Night and OBS.LOSS_NIGHT or OBS.LOSS_DAY) + state.pending * OBS.LOSS_PER_PENDING
		lost = Chance.mishap(training, math.min(OBS.LOSS_MAX, loss), random)
	end
	r.State = ORS.PENDING
	r.From = entry.GroupName
	r.SentAt = now
	r.DueAt = now + delay
	r.Lost = lost
	r.Position.x, r.Position.y, r.Position.z = seen.Position.x, seen.Position.y, seen.Position.z
	r.ErrorM = seen.ErrorM
	r.Heading8 = seen.Heading8
	r.Height = seen.Height
	r.Speed = seen.Speed
	r.Kind = seen.Kind
	r.TypeName = seen.TypeName
	r.Count = seen.Count
	r.Identity = seen.Identity
	r.Heard = seen.Heard
	r.Night = seen.Night
	r.Load = crew and crew.load or nil
	r.DeliveredAt = nil
	state.pending = state.pending + 1
	logger:info(string.format("observer report sent: %s %s, due in %.0f s", entry.GroupName, describe(r), delay))
	return true
end

--- Wakes the SAMs a hostile report brings up; their names go into `woken` (reused). Returns the count. `reason`
--- (default "observer_report") names the cause; `extraM` widens the reach by the report's own error.
local function wakeSams(ctx, r, woken, reason, extraM)
	local grid = ctx.networkedGeoGrid
	if not grid or not ctx.batteryStore or r.Identity ~= "hostile" or trackNear(ctx, r.Position) then
		return 0
	end
	reason = reason or "observer_report"
	local margin = OBS.WAKE_MARGIN_M + (extraM or 0)
	local radius = (ctx.maxEngagementRange or 0) + margin
	local ids = grid:queryRadius(r.Position, radius, FILTER_BATTERY).BatteryIds or EMPTY
	local count = 0
	for id in pairs(ids) do
		local b = ctx.batteryStore:get(id)
		if b and b.Position and mayWake(ctx, b) then
			local reach = (b.EngagementRangeMax or 0) + margin
			local dx, dz = b.Position.x - r.Position.x, b.Position.z - r.Position.z
			if dx * dx + dz * dz <= reach * reach and holdWarm(b, ctx.now + OBS.WARM_HOLD_SEC, ctx.now, reason) then
				count = count + 1
				woken[count] = b.GroupName
				logger:info(
					string.format(
						"%s wakes %s WARM (%s%s)",
						(string.gsub(reason, "_", " ")),
						b.GroupName,
						reason == "observer_report" and "report from " or "from ",
						r.From
					)
				)
			end
		end
	end
	return count
end

--- What a delivered report caused, for the DEBRIEF line: "wake_sam", "cue_crews", "cue_radar" joined by "+", or
--- "nothing".
function Medusa.Services.ObserverReportService.causedWord(woke, crews, radars)
	local word = woke > 0 and "wake_sam" or nil
	if crews > 0 then
		word = word and (word .. "+cue_crews") or "cue_crews"
	end
	if radars > 0 then
		word = word and (word .. "+cue_radar") or "cue_radar"
	end
	return word or "nothing"
end

local function deliver(ctx, state, r)
	local now = ctx.now
	state.pending = state.pending - 1
	if r.Lost then
		r.State = ORS.FREE
		logger:info(string.format("observer report lost: from %s (not heard on the net)", r.From))
		Debrief.emit(
			ctx.networkId,
			now,
			"REPORT_LOST",
			"from",
			r.From,
			"why",
			"not_heard",
			"after_s",
			string.format("%.0f", now - r.SentAt),
			"saw",
			r.Identity .. "_" .. r.Kind,
			"load",
			loadText(r.Load)
		)
		return
	end
	r.State = ORS.DELIVERED
	r.DeliveredAt = now
	logger:info(
		string.format("observer report received: from %s after %.0f s: %s", r.From, now - r.SentAt, describe(r))
	)
	local crews = LocalRadarService.cueLocalDefences(ctx, r.Position, MWR.OBSERVER)
	local radars = LocalRadarService.cueFromReport(ctx, r.Position, "observer report")
	local woken = state.woken
	local woke = wakeSams(ctx, r, woken)
	for i = woke + 1, #woken do
		woken[i] = nil
	end
	Debrief.emit(
		ctx.networkId,
		now,
		"REPORT_DELIVERED",
		"from",
		r.From,
		"after_s",
		string.format("%.0f", now - r.SentAt),
		"saw",
		r.Identity .. "_" .. r.Kind,
		"x",
		string.format("%.0f", r.Position.x),
		"z",
		string.format("%.0f", r.Position.z),
		"err_m",
		string.format("%.0f", r.ErrorM or 0),
		"caused",
		Medusa.Services.ObserverReportService.causedWord(woke, crews, radars),
		"woke",
		woke > 0 and table.concat(woken, ",") or nil,
		"crews_cued",
		crews,
		"radars_cued",
		radars,
		"load",
		loadText(r.Load)
	)
	if ctx.crew and r.Identity == "hostile" then
		Medusa.Services.CrewFactorsService.wordSpreads(
			ctx.crew,
			now,
			ctx.networkId,
			"hostile_report",
			Chance.isTraining(ctx.doctrine)
		)
	end
end

local cueReport = { Identity = "hostile", Position = nil, From = nil }

--- Cues the defences around a hostile `position` the network learned without a track (a listening-station fix):
--- MANPAD and gun crews near it, local cueing radars that cover it, and dark short- or medium-range SAMs whose reach
--- plus `errorM` covers it come up WARM (the same rules as a hostile observer report). Fills `woken` (reused) with the
--- woken SAMs' names. Returns crews cued, radars cued, SAMs woken.
function Medusa.Services.ObserverReportService.cueHostileArea(ctx, position, from, reason, errorM, woken)
	local crews = LocalRadarService.cueLocalDefences(ctx, position, MWR.OBSERVER)
	local radars = LocalRadarService.cueFromReport(ctx, position, (string.gsub(reason, "_", " ")))
	cueReport.Position, cueReport.From = position, from
	local woke = wakeSams(ctx, cueReport, woken, reason, errorM)
	cueReport.Position = nil
	for i = woke + 1, #woken do
		woken[i] = nil
	end
	return crews, radars, woke
end

local function processRadio(ctx, state)
	local now = ctx.now
	local reports = state.reports
	for i = 1, #reports do
		local r = reports[i]
		if r.State == ORS.PENDING and now >= r.DueAt then
			deliver(ctx, state, r)
		elseif r.State == ORS.DELIVERED and now - r.DeliveredAt >= OBS.KEEP_SEC then
			r.State = ORS.FREE
		end
	end
end

local function lookFrom(ctx, state, entry)
	local look = state.look
	look.Position = entry.Position
	look.CoalitionId = ctx.coalitionId
	look.GroupName = entry.GroupName
	look.Now = ctx.now
	look.Training = Chance.isTraining(ctx.doctrine)
	look.ErrorScale = ctx.crew and ORSvc.positionErrorScale(entry.Skill or ORSvc.defaultSkill(ctx.doctrine)) or nil
	-- Training: the position error's direction is fixed per group and report (deterministic, not perfect).
	local name = entry.GroupName
	look.Seed = nil
	if look.Training then
		local hash = state.nameHash[name]
		if not hash then
			hash = Chance.hash(name)
			state.nameHash[name] = hash
		end
		look.Seed = hash + (state.reportCount[name] or 0)
	end
	local seen = state.seen
	if not Medusa.Services.SensorPollingService.observeAirspace(look, seen) then
		return
	end
	state.reportCount[name] = (state.reportCount[name] or 0) + 1
	state.lastReport[name] = ctx.now
	localInitiative(ctx, entry, seen)
	-- A call not made (radio flubbed) rests the full interval too: the chance to get a report out is per sighting.
	send(ctx, state, entry, seen)
end

local function isOff(ctx)
	local doctrine = ctx.doctrine
	return not doctrine or doctrine.ObserverReports == false
end

--- Once a second: delivers due reports and refreshes the roster of observing groups.
function Medusa.Services.ObserverReportService.update(ctx)
	if isOff(ctx) then
		return
	end
	local state = ctx.observers
	local now = ctx.now
	processRadio(ctx, state)
	if not state.rosterTime or now - state.rosterTime >= OBS.ROSTER_REFRESH_SEC or now < state.rosterTime then
		rebuildRoster(ctx, state)
	end
end

--- Every tick: at most one look, at Observer.LOOKS_PER_SEC on average, round-robin over the observers that have not
--- reported in the last Observer.REPORT_INTERVAL_SEC. Returns the number of looks (0 or 1).
function Medusa.Services.ObserverReportService.look(ctx)
	if isOff(ctx) then
		return 0
	end
	local state = ctx.observers
	local now = ctx.now
	if not state.rosterTime then
		rebuildRoster(ctx, state)
	end
	if state.tokenTime == nil or now < state.tokenTime then
		state.tokens = 1
	else
		state.tokens = math.min(1, state.tokens + (now - state.tokenTime) * OBS.LOOKS_PER_SEC)
	end
	state.tokenTime = now
	if state.tokens < 1 then
		return 0
	end
	-- A SURPRISED network's crews are not watching the sky: a crew other than an observer post looks at only part of
	-- its turns (lookRate: half for AVERAGE, more for skilled crews), by a per-crew credit, so every run is the same.
	-- A skipped turn spends its token, so the posts keep their full rate and the other crews still get their turns,
	-- at a lower rate.
	local surprised = ctx.crew ~= nil and ctx.crew.readiness == C.Readiness.SURPRISED
	local n = state.rosterCount
	local cursor = state.cursor
	for _ = 1, n do
		cursor = cursor % n + 1
		local entry = state.roster[cursor]
		local last = state.lastReport[entry.GroupName]
		if not last or now - last >= OBS.REPORT_INTERVAL_SEC then
			state.tokens = state.tokens - 1
			state.cursor = cursor
			if surprised and not entry.Observer then
				local credit = (entry.LookCredit or 0) + ORSvc.lookRate(entry.Skill, C.Readiness.SURPRISED)
				if credit < 1 then
					entry.LookCredit = credit
					return 0
				end
				entry.LookCredit = credit - 1
			end
			lookFrom(ctx, state, entry)
			return 1
		end
	end
	state.cursor = cursor
	return 0
end

--- Reports radioed and not yet delivered or lost.
function Medusa.Services.ObserverReportService.pendingCount(state)
	return state.pending
end

--- Calls fn(report) for each delivered report still kept (Observer.KEEP_SEC). Reports are reused: copy what you keep.
function Medusa.Services.ObserverReportService.eachDelivered(state, fn)
	local reports = state.reports
	for i = 1, #reports do
		if reports[i].State == ORS.DELIVERED then
			fn(reports[i])
		end
	end
end
