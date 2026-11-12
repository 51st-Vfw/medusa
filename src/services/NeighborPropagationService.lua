require("_header")
require("services.Services")
require("core.Chance")

Medusa.Services.NeighborPropagationService = {}

local recipientBuffer = {}

local function clear(values)
	for i = #values, 1, -1 do
		values[i] = nil
	end
end

function Medusa.Services.NeighborPropagationService.findRecipients(
	geoGrid,
	repository,
	center,
	rangeM,
	gridType,
	excludeId
)
	clear(recipientBuffer)
	local results = geoGrid:queryRadius(center, rangeM, { gridType })
	local ids = results[gridType .. "Ids"]
	if not ids then
		return recipientBuffer
	end
	for id in pairs(ids) do
		if id ~= excludeId then
			local recipient = repository:get(id)
			if recipient then
				recipientBuffer[#recipientBuffer + 1] = recipient
			end
		end
	end
	return recipientBuffer
end

function Medusa.Services.NeighborPropagationService.scheduleDelivery(delivery)
	local state = delivery.recipient[delivery.recipientStateField]
	if state[delivery.pendingTimerField] then
		return false
	end
	local delay = delivery.delayMinSec
	if delivery.delayMaxSec > delivery.delayMinSec then
		-- delivery.training (MANPAD wakes of a training network only): the middle of the window.
		delay = Medusa.Chance.uniform(delivery.training == true, delivery.delayMinSec, delivery.delayMaxSec)
	end
	local recipientId = delivery.recipient.BatteryId
	local timerId
	timerId = ScheduleOnce(function()
		local recipient = delivery.recipientStore:get(recipientId)
		local currentState = recipient and recipient[delivery.recipientStateField]
		if not currentState or currentState[delivery.pendingTimerField] ~= timerId then
			return
		end
		currentState[delivery.pendingTimerField] = nil
		delivery.onDelivery(recipient, delivery.message, GetTime())
	end, nil, delay)
	if not timerId then
		return false
	end
	state[delivery.pendingTimerField] = timerId
	return true
end

function Medusa.Services.NeighborPropagationService.cancelDelivery(recipient, recipientStateField, pendingTimerField)
	local state = recipient[recipientStateField]
	local timerId = state and state[pendingTimerField]
	if not timerId then
		return false
	end
	CancelSchedule(timerId)
	state[pendingTimerField] = nil
	return true
end
