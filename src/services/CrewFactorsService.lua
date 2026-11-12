require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("core.Chance")
require("core.Debrief")

--[[
    CREW FACTORS SERVICE

    What this service does
    - Keeps a network's readiness (doctrine Readiness: SURPRISED / ALERTED / ENGAGED). It starts at the doctrine
      value and only rises: a SURPRISED network turns ALERTED a few minutes (CrewFactors.WORD_SPREADS_MIN..MAX_SEC)
      after word first spreads (it first holds a HOSTILE track or a hostile observer report gets through); any
      network turns ENGAGED at its first missile launch, or once word of its first loss arrives (30-90 s,
      CrewFactors.WORD_OF_LOSS_MIN..MAX_SEC). The mission may set it through the API (Medusa.API.setReadiness), lower
      too.
    - Keeps the network's load (0..1, "chaos"): aircraft tracks held, observer reports waiting on the radio, ARMs
      inbound, own missiles in flight and sites lost in the last five minutes, each over the count that alone fills
      the net (the track, missile and ARM counts grow with the network: setNetworkSize). It rises at once and falls
      back over two minutes. O(1) a second (two fixed rings of event times).
    - Only used with doctrine CrewFactors on; off, nothing here runs and readiness stays at the doctrine value.

    How others use it
    - IadsNetwork calls update once a second with the counts, setNetworkSize as its sites change, onLaunch on a
      missile launch and onLoss on a site lost;
      ObserverReportService reads readiness and load (ctx.crew) and calls wordSpreads for a delivered hostile report.
    - Logs (INFO): "readiness <from> -> <to> (<why>)" and DEBRIEF READINESS lines.
--]]

Medusa.Services.CrewFactorsService = {}

local C = Medusa.Constants
local R = C.Readiness
local LEVEL = C.ReadinessLevel
local CF = C.CrewFactors
local Chance = Medusa.Chance
local logger = Medusa.Logger:ns("CrewFactorsService")

--- True when the doctrine has crew factors on (nil field = on, as for the other switches).
function Medusa.Services.CrewFactorsService.isOn(doctrine)
	return doctrine ~= nil and doctrine.CrewFactors ~= false
end

--- @param doctrine table Network doctrine (Readiness: starting readiness)
--- @param random function|nil [0,1) source (tests); math.random by default
function Medusa.Services.CrewFactorsService.newState(doctrine, random)
	local start = doctrine and doctrine.Readiness
	if not LEVEL[start] then
		start = R.ENGAGED
	end
	return {
		readiness = start,
		alertDueAt = nil,
		alertWhy = nil,
		engageDueAt = nil,
		load = 0,
		fullTracks = CF.LOAD_FULL_TRACKS_MIN,
		fullMissiles = CF.LOAD_FULL_MISSILES_MIN,
		fullArms = CF.LOAD_FULL_ARMS_MIN,
		fullPending = CF.LOAD_FULL_PENDING_REPORTS,
		fullLosses = CF.LOAD_FULL_LOSSES,
		loadAt = nil,
		launches = {},
		losses = {},
		lossNext = 1,
		random = random,
	}
end

local function change(state, to, now, network, why)
	local from = state.readiness
	state.readiness = to
	if LEVEL[to] >= LEVEL[R.ALERTED] then
		state.alertDueAt, state.alertWhy = nil, nil
	end
	if LEVEL[to] >= LEVEL[R.ENGAGED] then
		state.engageDueAt = nil
	end
	logger:info(string.format("network %s readiness %s -> %s (%s)", tostring(network), from, to, why))
	Medusa.Debrief.emit(network, now, "READINESS", "from", from, "to", to, "why", why)
end

--- Raises readiness to `to` (never lowers it). Returns true when it rose.
function Medusa.Services.CrewFactorsService.raise(state, to, now, network, why)
	if LEVEL[to] <= LEVEL[state.readiness] then
		return false
	end
	change(state, to, now, network, why)
	return true
end

--- Sets readiness (the mission's call through the API: may lower it).
function Medusa.Services.CrewFactorsService.set(state, to, now, network, why)
	if not LEVEL[to] or to == state.readiness then
		return false
	end
	state.alertDueAt, state.alertWhy, state.engageDueAt = nil, nil, nil
	change(state, to, now, network, why)
	return true
end

--- Word of an attack spreads in a SURPRISED network: it turns ALERTED after the word-spreads delay. Only the first
--- word counts.
function Medusa.Services.CrewFactorsService.wordSpreads(state, now, network, why, training)
	if state.readiness ~= R.SURPRISED or state.alertDueAt then
		return false
	end
	local delay = Chance.uniform(training, CF.WORD_SPREADS_MIN_SEC, CF.WORD_SPREADS_MAX_SEC, state.random)
	state.alertDueAt = now + delay
	state.alertWhy = why
	logger:info(string.format("network %s: word spreads (%s), ALERTED in %.0f s", tostring(network), why, delay))
	return true
end

local function push(ring, nextIndex, now)
	ring[nextIndex] = now
	return nextIndex % CF.EVENT_RING_SIZE + 1
end

local function countSince(ring, from)
	local n = 0
	for i = 1, #ring do
		if ring[i] >= from then
			n = n + 1
		end
	end
	return n
end

--- A missile left one of the network's launchers; it loads the net while it flies (`flightSec`, the launch's
--- expected time to target, at most MISSILE_FLIGHT_SEC; MISSILE_FLIGHT_SEC when not given or not positive). The list
--- keeps each missile's expected end time; a spent missile's slot is reused, so no missile in flight is overwritten.
function Medusa.Services.CrewFactorsService.onLaunch(state, now, network, flightSec)
	flightSec = tonumber(flightSec)
	if not flightSec or flightSec <= 0 or flightSec > CF.MISSILE_FLIGHT_SEC then
		flightSec = CF.MISSILE_FLIGHT_SEC
	end
	local launches = state.launches
	local slot = #launches + 1
	for i = 1, #launches do
		if launches[i] <= now then
			slot = i
			break
		end
	end
	launches[slot] = now + flightSec
	Medusa.Services.CrewFactorsService.raise(state, R.ENGAGED, now, network, "first_launch")
end

--- The network lost a site: it loads the net at once, and the network turns ENGAGED once word of the loss arrives
--- (WORD_OF_LOSS_MIN..MAX_SEC later; the first loss sets the time).
function Medusa.Services.CrewFactorsService.onLoss(state, now, network, training)
	state.lossNext = push(state.losses, state.lossNext, now)
	if state.readiness == R.ENGAGED or state.engageDueAt then
		return
	end
	local delay = Chance.uniform(training, CF.WORD_OF_LOSS_MIN_SEC, CF.WORD_OF_LOSS_MAX_SEC, state.random)
	state.engageDueAt = now + delay
	logger:info(
		string.format("network %s: a site is lost, ENGAGED in %.0f s (word of the loss)", tostring(network), delay)
	)
end

--- The counts that fill the net grow with the network: `sites` (SAM, AAA and MANPAD groups and early-warning radar
--- groups) and `sams` (SAM batteries), never below the CrewFactors minimums.
function Medusa.Services.CrewFactorsService.setNetworkSize(state, sites, sams)
	state.fullTracks = math.max(CF.LOAD_FULL_TRACKS_MIN, CF.LOAD_FULL_TRACKS_PER_SITE * (sites or 0))
	state.fullMissiles = math.max(CF.LOAD_FULL_MISSILES_MIN, CF.LOAD_FULL_MISSILES_PER_SAM * (sams or 0))
	state.fullArms = math.max(CF.LOAD_FULL_ARMS_MIN, math.ceil(CF.LOAD_FULL_ARMS_PER_SAM * (sams or 0)))
end

function Medusa.Services.CrewFactorsService.missilesInFlight(state, now)
	local n = 0
	for i = 1, #state.launches do
		if state.launches[i] > now then
			n = n + 1
		end
	end
	return n
end

function Medusa.Services.CrewFactorsService.recentLosses(state, now)
	return countSince(state.losses, now - CF.LOSS_WINDOW_SEC)
end

--- Load (0..1) from the counts: each over the count that alone fills the network's net (`state`), summed, capped
--- at 1.
function Medusa.Services.CrewFactorsService.rawLoad(state, tracks, pending, arms, missiles, losses)
	local load = tracks / state.fullTracks
		+ pending / state.fullPending
		+ arms / state.fullArms
		+ missiles / state.fullMissiles
		+ losses / state.fullLosses
	return load < 1 and load or 1
end

--- Once a second. `counts`: { hostile (tracks held HOSTILE: word spreads), tracks (aircraft tracks held HOSTILE or
--- BANDIT, not ARMs or probable decoys: load), pending (observer reports on the radio), arms (ARMs inbound) }.
function Medusa.Services.CrewFactorsService.update(state, now, network, counts, training)
	local CFS = Medusa.Services.CrewFactorsService
	if state.engageDueAt and now >= state.engageDueAt then
		CFS.raise(state, R.ENGAGED, now, network, "first_loss")
	end
	if state.alertDueAt and now >= state.alertDueAt then
		CFS.raise(state, R.ALERTED, now, network, state.alertWhy or "word_spreads")
	end
	if counts.hostile > 0 then
		CFS.wordSpreads(state, now, network, "hostile_track", training)
	end
	local raw = CFS.rawLoad(
		state,
		counts.tracks or counts.hostile,
		counts.pending,
		counts.arms,
		CFS.missilesInFlight(state, now),
		CFS.recentLosses(state, now)
	)
	local load = state.load
	if state.loadAt and now > state.loadAt then
		load = load - (now - state.loadAt) * CF.LOAD_DECAY_PER_SEC
	end
	if raw > load then
		load = raw
	end
	state.load = load > 0 and load or 0
	state.loadAt = now
end
