require("_header")
require("core.Logger")

--[[
            ██████╗ ███████╗██████╗ ██████╗ ██╗███████╗███████╗
            ██╔══██╗██╔════╝██╔══██╗██╔══██╗██║██╔════╝██╔════╝
            ██║  ██║█████╗  ██████╔╝██████╔╝██║█████╗  █████╗
            ██║  ██║██╔══╝  ██╔══██╗██╔══██╗██║██╔══╝  ██╔══╝
            ██████╔╝███████╗██████╔╝██║  ██║██║███████╗██║
            ╚═════╝ ╚══════╝╚═════╝ ╚═╝  ╚═╝╚═╝╚══════╝╚═╝

    What this module does
    - Writes one-line debrief events at INFO (the live log level), for after-action review of what the IADS saw,
      heard, decided and why: DEBRIEF|t=<s>|clock=<HH:MM:SS>|net=<network>|ev=<EVENT>|key=value|...
      t is seconds since mission start (timer.getTime, one decimal); clock is the mission time of day
      (timer.getAbsTime, the clock Tacview and the F10 map show; past midnight it wraps to 00:00:00), so events can
      be lined up with a Tacview recording.
    - Values are written with tostring; '|' becomes '/' and line breaks become spaces, so a line always splits on
      '|' into key=value fields. A nil value drops its key. With INFO logging off nothing is formatted.

    How others use it
    - Services call Medusa.Debrief.emit(network, now, event, key1, value1, key2, value2, ...) at points where they
      already log, naming their network; IadsNetwork also sets the network being ticked (setNetwork), the fallback
      when an event names none.
    - Events: FIRST_DETECTION (a non-friendly track first made), IDENTIFIED (first called BANDIT or HOSTILE),
      REPORT_NOT_MADE, REPORT_LOST, REPORT_DELIVERED, READINESS, WAKE, ARM_CONFIRMED, DECOY_PROBABLE, DECOY_FIRE_HOLD, SITE_LOST,
      LOCAL_RADAR_UP, TRAINING_MODE, CREW_ROSTER, ESM_INTERCEPT, ESM_FIX, ESM_AMBIGUOUS (listening stations),
      ARM_BLOCKED (an ARM-like track not confirmed, once per track and why: unpowered, window or size).
--]]

Medusa.Debrief = { _network = nil }

local parts = {}

local function clean(value)
	local text = tostring(value)
	if string.find(text, "[|\r\n]") then
		text = string.gsub(text, "|", "/")
		text = string.gsub(text, "[\r\n]", " ")
	end
	return text
end

--- Mission time of day as HH:MM:SS from absolute seconds (days past midnight wrap).
function Medusa.Debrief.clock(absSec)
	local s = math.floor(tonumber(absSec) or 0) % 86400
	return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
end

local function absTime()
	if GetAbsTime then
		return GetAbsTime()
	end
	if timer and timer.getAbsTime then
		local ok, value = pcall(timer.getAbsTime)
		return ok and value or 0
	end
	return 0
end

--- The network whose tick is running (used when an event names none).
function Medusa.Debrief.setNetwork(name)
	Medusa.Debrief._network = name
end

--- Writes one debrief line. `network` nil: the network being ticked; `now` nil: GetTime().
function Medusa.Debrief.emit(network, now, event, ...)
	if not Medusa.Logger:isEnabled("INFO") then
		return
	end
	local n = select("#", ...)
	local t = now or (GetTime and GetTime()) or 0
	parts[1] = string.format(
		"DEBRIEF|t=%.1f|clock=%s|net=%s|ev=%s",
		t,
		Medusa.Debrief.clock(absTime()),
		clean(network or Medusa.Debrief._network),
		event
	)
	local count = 1
	for i = 1, n - 1, 2 do
		local key, value = select(i, ...)
		if value ~= nil then
			count = count + 1
			parts[count] = key .. "=" .. clean(value)
		end
	end
	for i = count + 1, #parts do
		parts[i] = nil
	end
	Medusa.Logger:info(table.concat(parts, "|"))
end
