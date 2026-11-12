require("_header")
require("services.Services")
require("core.Logger")
require("entities.Track")

--[[
            ████████╗██████╗  █████╗  ██████╗██╗  ██╗    ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
               ██║   ██████╔╝███████║██║     █████╔╝     ███████╗   ██║   ██║   ██║██████╔╝█████╗
               ██║   ██╔══██╗██╔══██║██║     ██╔═██╗     ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
               ██║   ██║  ██║██║  ██║╚██████╗██║  ██╗    ███████║   ██║   ╚██████╔╝██║  ██║███████╗
               ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores Track entities indexed by TrackId and identification level for fast lookup.
    - Supports querying tracks by identification and finding stale entries by timestamp.

    How others use it
    - TrackManager adds, updates, and removes tracks as they flow through the lifecycle.
    - TargetAssigner and TrackClassifier read tracks via getAll or getByIdentification.
--]]

Medusa.Services.TrackStore = {}

function Medusa.Services.TrackStore:new()
	local o = {
		_byId = {},
		_byIdentification = {},
		-- Tracks per identification (O(1) counts for the net load).
		_idCount = {},
		_count = 0,
		_logger = Medusa.Logger:ns("TrackStore"),
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.TrackStore:add(track)
	if self._byId[track.TrackId] then
		error(string.format("duplicate track: %s", Medusa.Entities.Track.displayId(track)))
	end

	self._byId[track.TrackId] = track
	self._count = self._count + 1

	local identification = track.TrackIdentification
	if not self._byIdentification[identification] then
		self._byIdentification[identification] = {}
	end
	self._byIdentification[identification][track.TrackId] = track
	self._idCount[identification] = (self._idCount[identification] or 0) + 1

	self._logger:debug(
		string.format(
			"added track %s (identification=%s, count=%d)",
			Medusa.Entities.Track.displayId(track),
			identification,
			self._count
		)
	)
end

function Medusa.Services.TrackStore:get(trackId)
	return self._byId[trackId]
end

function Medusa.Services.TrackStore:remove(trackId)
	local track = self._byId[trackId]
	if not track then
		return nil
	end

	self._byId[trackId] = nil
	self._count = self._count - 1

	local identification = track.TrackIdentification
	self._idCount[identification] = (self._idCount[identification] or 1) - 1
	local identificationIndex = self._byIdentification[identification]
	if identificationIndex then
		identificationIndex[trackId] = nil
		if next(identificationIndex) == nil then
			self._byIdentification[identification] = nil
		end
	end

	self._logger:debug(
		string.format("removed track %s (count=%d)", Medusa.Entities.Track.displayId(track), self._count)
	)
	return track
end

function Medusa.Services.TrackStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, track in pairs(self._byId) do
		result[#result + 1] = track
	end
	return result
end

function Medusa.Services.TrackStore:getByIdentification(identification, outputTable)
	local identificationIndex = self._byIdentification[identification]
	if not identificationIndex then
		return outputTable or {}
	end
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, track in pairs(identificationIndex) do
		result[#result + 1] = track
	end
	return result
end

function Medusa.Services.TrackStore:count()
	return self._count
end

--- Number of tracks with this identification (O(1)).
function Medusa.Services.TrackStore:countByIdentification(identification)
	return self._idCount[identification] or 0
end

function Medusa.Services.TrackStore:getStaleIds(thresholdTime)
	local staleIds = {}
	for trackId, track in pairs(self._byId) do
		if track.LastDetectionTime < thresholdTime then
			staleIds[#staleIds + 1] = trackId
		end
	end
	return staleIds
end

function Medusa.Services.TrackStore:updateIdentification(trackId, newIdentification)
	local track = self._byId[trackId]
	if not track then
		error("track not found")
	end

	local oldIdentification = track.TrackIdentification
	if oldIdentification == newIdentification then
		return
	end

	local oldIndex = self._byIdentification[oldIdentification]
	if oldIndex then
		oldIndex[trackId] = nil
		if next(oldIndex) == nil then
			self._byIdentification[oldIdentification] = nil
		end
	end

	if not self._byIdentification[newIdentification] then
		self._byIdentification[newIdentification] = {}
	end
	self._byIdentification[newIdentification][trackId] = track
	self._idCount[oldIdentification] = (self._idCount[oldIdentification] or 1) - 1
	self._idCount[newIdentification] = (self._idCount[newIdentification] or 0) + 1

	track.TrackIdentification = newIdentification
	if self.onIdentified then
		self.onIdentified(track, oldIdentification, newIdentification)
	end
	self._logger:debug(
		string.format(
			"re-identified track %s: %s -> %s",
			Medusa.Entities.Track.displayId(track),
			oldIdentification,
			newIdentification
		)
	)
end
