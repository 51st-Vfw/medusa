require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.AlertZone")
require("entities.Track")

--[[
    What this service does
    - Finds mission-editor trigger zones that carry a `MedusaFlag` property and, every few seconds, writes to that flag
      the number of hostile contacts the zone's side currently tracks inside the zone. Mission makers then use plain
      editor triggers (FLAG IS MORE, TIME SINCE FLAG) to scramble fighters or play messages; Medusa tasks nothing.
    - Counts come from network tracks only, so terrain masking, low flying and lost radars delay or prevent an alert.
    - A contact keeps counting for `MedusaLinger` seconds after it leaves the zone or drops off radar. Contacts are
      kept by position and velocity (not DCS object ids), which also merges one aircraft seen by two networks.

    How others use it
    - The entrypoint calls start() once after the networks start. A one-second step updates a share of the zones,
      so each zone is checked every CHECK_INTERVAL_SEC and the work is spread evenly.
--]]

Medusa.Services.AlertZoneService = {}

do
	local Svc = Medusa.Services.AlertZoneService
	local _logger = Medusa.Logger:ns("AlertZoneService")
	local AAT = Medusa.Constants.AssessedAircraftType
	local HAS = Medusa.Constants.HarmAssessmentState
	local TID = Medusa.Constants.TrackIdentification
	local LS = Medusa.Constants.TrackLifecycleState
	local SEEN = Medusa.Constants.SeenAs
	local DECOY_PROBABLE = Medusa.Constants.DecoyState.PROBABLE

	Svc.CHECK_INTERVAL_SEC = 5
	Svc.DEFAULT_LINGER_SEC = 30
	-- A weapon just fired near its aircraft gets this long to be classified before it can count as an aircraft.
	Svc.MIN_TRACK_AGE_SEC = 10
	-- A remembered contact matches a track within this distance of where it should be now.
	Svc.MATCH_GATE_M = 1500
	-- Two networks' tracks this close, at this similar a velocity, are one aircraft.
	Svc.DUPLICATE_GATE_M = 1000
	Svc.DUPLICATE_SPEED_GATE_MPS = 50
	Svc.LOW_AGL_M = 1000
	Svc.HIGH_AGL_M = 6000
	-- A track refreshed within this long is held now (the slowest default radar refresh is 10 s; zones are checked
	-- every 5 s): MedusaLinger counts from when the network stopped holding a contact.
	Svc.HELD_SEC = 15
	-- Track visits per one-second step over all zones; a crowded zone's check carries on at the next steps.
	Svc.MAX_VISITS_PER_STEP = 150

	local FILTER_TRACK = { "Track" }
	local EMPTY = {}
	local ZERO_VEL = { x = 0, y = 0, z = 0 }
	local SIDES = { red = 1, blue = 2 }
	local THREATS = { aircraft = true, arms = true, munitions = true }
	local ALT_BANDS = { any = true, low = true, medium = true, high = true }

	local function trim(s)
		return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
	end

	local function readProperties(zone)
		local out = {}
		local props = zone.properties
		if type(props) ~= "table" then
			return out
		end
		for _, p in ipairs(props) do
			if type(p) == "table" and p.key ~= nil and p.value ~= nil then
				out[string.lower(trim(tostring(p.key)))] = trim(tostring(p.value))
			end
		end
		return out
	end

	local function parseThreats(text)
		if not text or text == "" then
			return { aircraft = true }
		end
		local set = {}
		for word in string.gmatch(string.lower(text), "[^,%s]+") do
			if not THREATS[word] then
				return nil, word
			end
			set[word] = true
		end
		return set
	end

	local function parseLinger(text)
		if not text or text == "" then
			return Svc.DEFAULT_LINGER_SEC
		end
		local n = tonumber((string.gsub(string.lower(text), "%s*s$", "")))
		if not n or n < 0 then
			return nil
		end
		return n
	end

	local function polygonShape(verts)
		local poly, sx, sz = {}, 0, 0
		for i = 1, #verts do
			poly[i] = { x = verts[i].x, y = 0, z = verts[i].y }
			sx, sz = sx + verts[i].x, sz + verts[i].y
		end
		local center = { x = sx / #verts, y = 0, z = sz / #verts }
		local r = 0
		for i = 1, #poly do
			r = math.max(r, math.sqrt((poly[i].x - center.x) ^ 2 + (poly[i].z - center.z) ^ 2))
		end
		return center, r, poly
	end

	local function shape(zone)
		if zone.type == 2 and type(zone.verticies) == "table" and #zone.verticies >= 3 then
			return polygonShape(zone.verticies)
		end
		if type(zone.radius) == "number" and zone.radius > 0 and zone.x and zone.y then
			return { x = zone.x, y = 0, z = zone.y }, zone.radius, nil
		end
		return nil
	end

	local function resolveSide(text, runningSides)
		if text and text ~= "" then
			local side = SIDES[string.lower(text)]
			if not side then
				return nil, "MedusaSide must be red or blue"
			end
			if not runningSides[side] then
				return nil, "no Medusa network runs on side " .. text
			end
			return side
		end
		local only, n = nil, 0
		for side in pairs(runningSides) do
			only, n = side, n + 1
		end
		if n ~= 1 then
			return nil, "MedusaSide (red or blue) is required when both coalitions run Medusa"
		end
		return only
	end

	--- Build an AlertZone from one ME trigger zone, or nil when it is not an alert zone.
	--- @return table|nil zone, string|nil problem (a problem means the zone was meant as an alert zone but is invalid)
	function Svc.parseZone(meZone, runningSides)
		local props = readProperties(meZone)
		local flag = props.medusaflag
		local lossesFlag = props.medusalosses
		if flag == "" then
			flag = nil
		end
		if lossesFlag == "" then
			lossesFlag = nil
		end
		if not flag and not lossesFlag then
			return nil
		end
		local side, sideErr = resolveSide(props.medusaside, runningSides)
		if not side then
			return nil, sideErr
		end
		local threats, badWord = parseThreats(props.medusathreats)
		if not threats then
			return nil, string.format("unknown MedusaThreats value '%s' (use aircraft, arms, munitions)", badWord)
		end
		local band = string.lower(props.medusaalt or "any")
		if not ALT_BANDS[band] then
			return nil, string.format("unknown MedusaAlt value '%s' (use low, medium, high, any)", band)
		end
		local linger = parseLinger(props.medusalinger)
		if not linger then
			return nil, string.format("MedusaLinger '%s' is not a number of seconds", tostring(props.medusalinger))
		end
		local center, radius, polygon = shape(meZone)
		if not center then
			return nil, "zone has no usable circle or quad shape"
		end
		return Medusa.Entities.AlertZone.new({
			ZoneName = meZone.name or "?",
			FlagName = flag,
			LossesFlag = lossesFlag,
			CoalitionId = side,
			Threats = threats,
			AltBand = band,
			LingerSec = linger,
			Center = center,
			Radius = radius,
			Polygon = polygon,
		})
	end

	local function logSharedFlags(zones)
		local byFlag = {}
		for i = 1, #zones do
			for _, flag in ipairs({ zones[i].FlagName or false, zones[i].LossesFlag or false }) do
				if flag then
					local list = byFlag[flag] or {}
					list[#list + 1] = zones[i].ZoneName
					byFlag[flag] = list
				end
			end
		end
		for flag, names in pairs(byFlag) do
			if #names > 1 then
				_logger:info(string.format("flag '%s' holds the sum of zones %s", flag, table.concat(names, ", ")))
			end
		end
	end

	--- Find alert zones in the mission.
	--- @param meZones table|nil env.mission.triggers.zones
	--- @param runningSides table set of coalition ids that run a Medusa network
	--- @return table state { zones = AlertZone[], written = { [flag] = value } }
	function Svc.discover(meZones, runningSides)
		local zones = {}
		for _, z in pairs(meZones or {}) do
			local zone, problem = Svc.parseZone(z, runningSides)
			if zone then
				zones[#zones + 1] = zone
				_logger:info(
					string.format(
						"alert zone '%s' -> flag '%s', losses flag '%s' (side %d, alt %s, linger %ss)",
						zone.ZoneName,
						tostring(zone.FlagName),
						tostring(zone.LossesFlag),
						zone.CoalitionId,
						zone.AltBand,
						tostring(zone.LingerSec)
					)
				)
			elseif problem then
				_logger:error(string.format("alert zone '%s' ignored: %s", tostring(z.name), problem))
			end
		end
		logSharedFlags(zones)
		return { zones = zones, written = {} }
	end

	-- What a crew would call the track: "aircraft", "arm", "munition", or "unsure" (not yet judged).
	local function trackClass(track, now)
		local aat = track.AssessedAircraftType
		local label = track.HarmAssessment and track.HarmAssessment.label
		if aat == AAT.HARM or label == HAS.CONFIRMED then
			return "arm"
		end
		-- A probable decoy (DecoyAssessmentService) is a weapon, not an aircraft; a suspect still counts as one.
		local decoy = track.DecoyAssessment
		if decoy and decoy.label == DECOY_PROBABLE then
			return "munition"
		end
		-- A contact seen leaving an aircraft is a weapon for its whole life, whatever the ARM check later says (in
		-- DCS, HARMs not yet judged, or cleared after their target died, otherwise read as jets), unless its return
		-- is confidently aircraft-sized (a false cue: a wingman pulling away). A crew that saw it as a weapon within
		-- sight range never calls it an aircraft (a TALD returns like a fighter but is recognised close up).
		local size = Medusa.Entities.Track.sizeClass(track)
		if aat == AAT.MISSILE or (track.LaunchCue and size ~= "large") or track.SeenAs == SEEN.MUNITION then
			return "munition"
		end
		-- A confidently small return (ARM- or JSOW-sized, well below a fighter) is a munition only when the ARM check
		-- holds it a suspect or more (it flies like an ARM; a launch cue is handled above). Size alone never decides:
		-- low-observable aircraft return less than an ARM and are harder to classify, as they should be. Speed is no
		-- cue: a low-observable jet in supersonic cruise, or a MiG-31 at Mach 2.3, flies as fast as a HARM.
		if size == "small" and (label == HAS.SUSPECT or label == HAS.PROBABLE) then
			return "munition"
		end
		if label == HAS.SUSPECT or label == HAS.PROBABLE or aat == AAT.UNKNOWN or aat == nil then
			return "unsure"
		end
		if now - (track.FirstDetectionTime or now) < Svc.MIN_TRACK_AGE_SEC then
			return "unsure"
		end
		return "aircraft"
	end
	Svc._trackClass = trackClass

	local function wanted(zone, cls)
		local t = zone.Threats
		if cls == "aircraft" then
			return t.aircraft == true
		end
		if cls == "arm" then
			return t.arms == true or t.munitions == true
		end
		return cls == "munition" and t.munitions == true
	end

	local function hostile(track)
		local id = track.TrackIdentification
		return track.LifecycleState == LS.ACTIVE and id ~= TID.FRIENDLY and id ~= TID.WHITEAIR and track.Position ~= nil
	end

	local function inside(zone, pos)
		local dx, dz = pos.x - zone.Center.x, pos.z - zone.Center.z
		if dx * dx + dz * dz > zone.Radius * zone.Radius then
			return false
		end
		return zone.Polygon == nil or PointInPolygon2D(pos, zone.Polygon) == true
	end

	-- Ground height under each track's last position, read once per position for every banded zone and pass.
	local groundCache = setmetatable({}, { __mode = "k" })

	local function heightAboveGround(track, pos)
		if track.AltitudeAGL then
			return track.AltitudeAGL
		end
		local g = groundCache[track]
		if not g then
			g = {}
			groundCache[track] = g
		end
		if g.x ~= pos.x or g.z ~= pos.z then
			g.x, g.z, g.h = pos.x, pos.z, GetTerrainHeight(pos) or 0
		end
		return pos.y - g.h
	end

	local function inBand(zone, track)
		if zone.AltBand == "any" then
			return true
		end
		local agl = heightAboveGround(track, track.Position)
		if zone.AltBand == "low" then
			return agl < Svc.LOW_AGL_M
		end
		if zone.AltBand == "high" then
			return agl > Svc.HIGH_AGL_M
		end
		return agl >= Svc.LOW_AGL_M and agl <= Svc.HIGH_AGL_M
	end

	-- Distance between a remembered contact, projected to time `at`, and a track position measured at `at`.
	local function distanceAt(c, pos, at)
		local dt = at - c.detT
		local dx = c.pos.x + c.vel.x * dt - pos.x
		local dz = c.pos.z + c.vel.z * dt - pos.z
		return math.sqrt(dx * dx + dz * dz)
	end

	local function speedDiff(c, vel)
		local dx, dz = c.vel.x - vel.x, c.vel.z - vel.z
		return math.sqrt(dx * dx + dz * dz)
	end

	-- Contacts remember which track of each network fed them (zone.Index[sourceId][trackId] = contact), so a track
	-- finds its contact at once; only a track no contact knows (new, or re-acquired under a new id) is matched by
	-- position.
	local function link(zone, c, sourceId, trackId)
		local keys = c.keys
		local old = keys[sourceId]
		local index = zone.Index[sourceId]
		if not index then
			index = {}
			zone.Index[sourceId] = index
		end
		if old ~= nil and old ~= trackId and index[old] == c then
			index[old] = nil
		end
		keys[sourceId] = trackId
		index[trackId] = c
	end

	local function unlinkAll(zone, c)
		for sourceId, trackId in pairs(c.keys) do
			local index = zone.Index[sourceId]
			if index and index[trackId] == c then
				index[trackId] = nil
			end
		end
	end

	local function removeAt(zone, i)
		local contacts = zone.Contacts
		local n = #contacts
		unlinkAll(zone, contacts[i])
		contacts[i] = contacts[n]
		contacts[n] = nil
	end

	-- Another network's track of an aircraft already matched this pass. Each contact absorbs at most one track per
	-- other network, so a wingman that only the second network holds still gets its own contact.
	local function claimDuplicate(c, pos, vel, sourceId, at, pass)
		local claims = c.claims
		if
			c.pass ~= pass
			or c.source == sourceId
			or (claims and claims[sourceId] == pass)
			or distanceAt(c, pos, at) >= Svc.DUPLICATE_GATE_M
			or speedDiff(c, vel) >= Svc.DUPLICATE_SPEED_GATE_MPS
		then
			return false
		end
		c.claims = claims or {}
		c.claims[sourceId] = pass
		return true
	end

	local function refresh(c, pos, vel, sourceId, at, pass, seenT)
		local bp, bv = c.pos, c.vel
		bp.x, bp.y, bp.z = pos.x, pos.y, pos.z
		bv.x, bv.y, bv.z = vel.x, vel.y or 0, vel.z
		c.detT, c.pass, c.source, c.seenT = at, pass, sourceId, seenT
	end

	-- Refresh the remembered contact this track continues, or remember a new one. `seenT`: when the contact was last
	-- held (now while the track is refreshed, else its last detection).
	local function observe(zone, track, sourceId, at, pass, seenT)
		local pos = track.Position
		local vel = track.Velocity or ZERO_VEL
		local trackId = track.TrackId
		local index = zone.Index[sourceId]
		local known = index and index[trackId]
		if known then
			if known.pass ~= pass then
				if distanceAt(known, pos, at) < Svc.MATCH_GATE_M then
					refresh(known, pos, vel, sourceId, at, pass, seenT)
					return
				end
			elseif claimDuplicate(known, pos, vel, sourceId, at, pass) then
				return
			end
			index[trackId] = nil
			if known.keys[sourceId] == trackId then
				known.keys[sourceId] = nil
			end
		end
		local contacts = zone.Contacts
		local best, bestD = nil, Svc.MATCH_GATE_M
		for i = 1, #contacts do
			local c = contacts[i]
			if claimDuplicate(c, pos, vel, sourceId, at, pass) then
				link(zone, c, sourceId, trackId)
				return
			end
			if c.pass ~= pass then
				local d = distanceAt(c, pos, at)
				if d < bestD then
					best, bestD = c, d
				end
			end
		end
		if not best then
			best = { pos = {}, vel = {}, keys = {} }
			contacts[#contacts + 1] = best
		end
		refresh(best, pos, vel, sourceId, at, pass, seenT)
		link(zone, best, sourceId, trackId)
	end

	-- A track now judged something this zone does not count (an aircraft that turned out to be an ARM): drop the
	-- contact it fed, or else the nearest one not yet refreshed this pass.
	local function forget(zone, track, sourceId, at, pass)
		local contacts = zone.Contacts
		local index = zone.Index[sourceId]
		local known = index and index[track.TrackId]
		local nearest, nearestD = nil, Svc.MATCH_GATE_M
		for i = 1, #contacts do
			local c = contacts[i]
			if c.pass ~= pass then
				if c == known then
					nearest = i
					break
				end
				local d = distanceAt(c, track.Position, at)
				if d < nearestD then
					nearest, nearestD = i, d
				end
			end
		end
		if nearest then
			removeAt(zone, nearest)
		end
	end

	local function expire(zone, now)
		local contacts = zone.Contacts
		for i = #contacts, 1, -1 do
			if now - contacts[i].seenT > zone.LingerSec then
				removeAt(zone, i)
			end
		end
	end

	local function visitTrack(zone, track, sourceId, now, pass)
		if not (track and hostile(track) and inside(zone, track.Position)) then
			return
		end
		-- A track refreshed within HELD_SEC is held now; one the radars stopped refreshing lingers from its last
		-- detection (its position is as of then) and is gone once that is longer ago than the linger.
		local at = track.LastDetectionTime or now
		local seenT = now
		if now - at > Svc.HELD_SEC then
			if now - at > zone.LingerSec then
				return
			end
			seenT = at
		end
		if not inBand(zone, track) then
			return
		end
		local cls = trackClass(track, now)
		if wanted(zone, cls) then
			observe(zone, track, sourceId, at, pass, seenT)
		elseif cls ~= "unsure" then
			forget(zone, track, sourceId, at, pass)
		end
	end

	-- A zone's check is one pass over the tracks in its circle, possibly spread over steps (MAX_VISITS_PER_STEP).
	local function beginPass(zone, sources)
		zone._pass = (zone._pass or 0) + 1
		local work, workSrc = zone._work, zone._workSrc
		if not work then
			work, workSrc = {}, {}
			zone._work, zone._workSrc = work, workSrc
		end
		local n = 0
		for s = 1, #sources do
			local ids = sources[s].geoGrid:queryRadius(zone.Center, zone.Radius, FILTER_TRACK).TrackIds
			for id in pairs(ids or EMPTY) do
				n = n + 1
				work[n], workSrc[n] = id, s
			end
		end
		for i = #work, n + 1, -1 do
			work[i], workSrc[i] = nil, nil
		end
		zone._workN, zone._workPos = n, 0
	end

	-- Visits up to `budget` tracks of the pass in progress. Returns the visits made and whether the pass is done.
	local function continuePass(zone, sources, now, budget)
		local pass, n, i = zone._pass, zone._workN, zone._workPos
		local work, workSrc = zone._work, zone._workSrc
		local used = 0
		while i < n and used < budget do
			i = i + 1
			used = used + 1
			local src = sources[workSrc[i]]
			visitTrack(zone, src.trackStore:get(work[i]), src.id, now, pass)
		end
		zone._workPos = i
		if i < n then
			return used, false
		end
		expire(zone, now)
		zone.Count = #zone.Contacts
		zone._workN = nil
		if Svc._onPassDone then
			Svc._onPassDone(zone)
		end
		return used, true
	end

	--- Update one zone's remembered contacts from its side's networks (a whole pass at once).
	--- @param sources table[] { id, geoGrid, trackStore } for each network of the zone's side
	function Svc.updateZone(zone, sources, now)
		beginPass(zone, sources)
		continuePass(zone, sources, now, math.huge)
	end

	-- Zones naming the same flag write their sum. field: "FlagName" (counts) or "LossesFlag" (losses).
	local function writeFlag(state, flag, field)
		local sum = 0
		local value = field == "LossesFlag" and "Losses" or "Count"
		for i = 1, #state.zones do
			local z = state.zones[i]
			if z[field] == flag then
				sum = sum + z[value]
			end
		end
		if state.written[flag] ~= sum then
			SetFlag(flag, sum)
			state.written[flag] = sum
		end
	end

	local function failed(zone, err)
		zone._workN = nil
		_logger:error(string.format("alert zone '%s' update failed: %s", zone.ZoneName, tostring(err)))
	end

	local function updateOne(state, zone, sourcesBySide, now)
		if not zone.FlagName then
			return
		end
		local ok, err = pcall(Svc.updateZone, zone, sourcesBySide[zone.CoalitionId] or EMPTY, now)
		if not ok then
			failed(zone, err)
		end
		writeFlag(state, zone.FlagName, "FlagName")
	end

	--- Update every zone and write each flag whose total changed.
	--- @param sourcesBySide table [coalitionId] = sources list
	function Svc.evaluate(state, sourcesBySide, now)
		for i = 1, #state.zones do
			updateOne(state, state.zones[i], sourcesBySide, now)
		end
	end

	local function work(zone, sources, now, budget)
		if not zone._workN then
			beginPass(zone, sources)
		end
		return continuePass(zone, sources, now, budget)
	end

	--- One step a second: queues the next zones so that each is checked once per CHECK_INTERVAL_SEC (n zones per
	--- interval, the share carried over between steps), then works through the queue visiting at most
	--- MAX_VISITS_PER_STEP tracks; a zone whose check is not finished continues at the next step.
	function Svc.step(state, sourcesBySide, now)
		local zones = state.zones
		local n = #zones
		if n == 0 then
			return
		end
		local queue = state.queue
		if not queue then
			queue = {}
			state.queue = queue
			state.share = Svc.CHECK_INTERVAL_SEC - 1
		end
		state.share = state.share + n
		while state.share >= Svc.CHECK_INTERVAL_SEC do
			state.share = state.share - Svc.CHECK_INTERVAL_SEC
			state.cursor = (state.cursor or 0) % n + 1
			local zone = zones[state.cursor]
			if zone.FlagName and not zone._queued then
				zone._queued = true
				queue[#queue + 1] = zone
			end
		end
		local budget = Svc.MAX_VISITS_PER_STEP
		while queue[1] and budget > 0 do
			local zone = queue[1]
			local ok, used, done = pcall(work, zone, sourcesBySide[zone.CoalitionId] or EMPTY, now, budget)
			if not ok then
				failed(zone, used)
				used, done = 0, true
			end
			budget = budget - used
			if not done then
				break
			end
			zone._queued = nil
			table.remove(queue, 1)
			writeFlag(state, zone.FlagName, "FlagName")
		end
	end

	--- A Medusa site was knocked out at pos: add one to the losses of every zone of that side containing it.
	function Svc.recordLoss(state, coalitionId, pos)
		if not state or not pos then
			return
		end
		for i = 1, #state.zones do
			local z = state.zones[i]
			if z.LossesFlag and z.CoalitionId == coalitionId and inside(z, pos) then
				z.Losses = z.Losses + 1
				writeFlag(state, z.LossesFlag, "LossesFlag")
			end
		end
	end

	--- Called by the network when one of its sites is knocked out; no-op when the mission has no alert zones.
	function Svc.reportLoss(coalitionId, pos)
		local ok, err = pcall(Svc.recordLoss, Svc._active, coalitionId, pos)
		if not ok then
			_logger:error("alert zone loss update failed: " .. tostring(err))
		end
	end

	--- Find alert zones and start the periodic check. Returns the state, or nil when the mission has none.
	--- @param networks table[] { id, coalitionId, iads }
	function Svc.start(meZones, networks)
		local sourcesBySide, runningSides = {}, {}
		for i = 1, #networks do
			local n = networks[i]
			runningSides[n.coalitionId] = true
			local list = sourcesBySide[n.coalitionId] or {}
			list[#list + 1] = {
				id = n.id,
				geoGrid = n.iads:getAssetIndex():networkedGeoGrid(),
				trackStore = n.iads:getTrackManager():getStore(),
			}
			sourcesBySide[n.coalitionId] = list
		end
		local state = Svc.discover(meZones, runningSides)
		if #state.zones == 0 then
			return nil
		end
		Svc._active = state
		local function tick()
			local ok, err = pcall(Svc.step, state, sourcesBySide, GetTime())
			if not ok then
				_logger:error("alert zone check failed: " .. tostring(err))
			end
			ScheduleOnce(tick, nil, 1)
		end
		ScheduleOnce(tick, nil, 1)
		return state
	end
end
