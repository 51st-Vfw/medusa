local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("entities.SensorUnit")
require("entities.C2Node")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.SensorUnitStore")
require("services.stores.C2NodeStore")
require("services.stores.ObserverPostStore")
require("services.EntityFactory")

-- Group make-up as DCS reports it (unit attributes): Dog Ear radar "SAM SR",
-- ZSU-23-4 Shilka "SAM TR" + "AAA", SA-18 Igla "MANPADS", 1L13 "EWR", infantry none of these.
local DOG_EAR = { ["SAM SR"] = true }
local SHILKA = { ["SAM TR"] = true, AAA = true }
local IGLA = { MANPADS = true }
local EWR_1L13 = { EWR = true }
local INFANTRY = { Infantry = true }

local saved = {}
local GLOBALS = { "GetGroupUnits", "GetUnitDesc", "GetUnitID", "GetUnitType", "GetUnitPosition", "GetUnitHeading" }
local GLOBALS2 = { "GetUnitAmmo", "GetUnitHealth", "NewULID" }

local function setupGroup(attributeSets, typeNames)
	local units = {}
	local attributesByUnit, typeByName = {}, {}
	for i = 1, #attributeSets do
		local name = "unit-" .. i
		local unit = {
			getID = function()
				return i
			end,
			getName = function()
				return name
			end,
		}
		units[i] = unit
		attributesByUnit[unit] = attributeSets[i]
		typeByName[name] = typeNames and typeNames[i] or ("type-" .. i)
	end
	GetGroupUnits = function()
		return units
	end
	GetUnitID = function(unit)
		return unit:getID()
	end
	GetUnitType = function(value)
		local name = type(value) == "table" and value:getName() or value
		return typeByName[name]
	end
	GetUnitPosition = function()
		return { x = 100, y = 0, z = 200 }
	end
	GetUnitHeading = function()
		return 0
	end
	GetUnitAmmo = function()
		return {}
	end
	GetUnitDesc = function(unit)
		return { displayName = unit:getName(), attributes = attributesByUnit[unit] }
	end
end

local function makeStores()
	local repository = Medusa.Services.BatteryStore:new()
	return {
		batteries = repository:batteries(),
		manpads = repository:manpads(),
		sensors = Medusa.Services.SensorUnitStore:new(),
		c2Nodes = Medusa.Services.C2NodeStore:new(),
		observers = Medusa.Services.ObserverPostStore:new(),
	}
end

local function makeDTO(roles, reach)
	return {
		groupId = 7,
		groupName = "iads.1bn.site",
		parsed = { roles = roles or {}, echelonPath = { "1bn" }, isHQ = false },
		localRadarReachM = reach,
	}
end

local ON = { LocalCueingRadars = true }
local OFF = { LocalCueingRadars = false }

local function create(dto, doctrine)
	local stores = makeStores()
	local kind, extra = Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net1", nil, doctrine)
	return kind, extra, stores
end

TestLocalRadarClassification = {}

function TestLocalRadarClassification:setUp()
	for _, name in ipairs(GLOBALS) do
		saved[name] = _G[name]
	end
	for _, name in ipairs(GLOBALS2) do
		saved[name] = _G[name]
	end
	local n = 0
	NewULID = function()
		n = n + 1
		return "ULID-" .. n
	end
end

function TestLocalRadarClassification:tearDown()
	for name, value in pairs(saved) do
		_G[name] = value
	end
end

function TestLocalRadarClassification:test_dog_ear_with_shilka_waits_for_the_radar_reach()
	setupGroup({ DOG_EAR, SHILKA }, { "Dog Ear radar", "ZSU-23-4 Shilka" })
	local kind, radarTypes, stores = create(makeDTO(), ON)
	lu.assertEquals(kind, "deferred")
	lu.assertEquals(radarTypes["Dog Ear radar"].x, 100)
	lu.assertNil(radarTypes["ZSU-23-4 Shilka"])
	lu.assertEquals(stores.sensors:count(), 0)
	lu.assertEquals(stores.batteries:count(), 0)
end

function TestLocalRadarClassification:test_short_reach_radar_with_guns_is_a_radar_directed_aaa_battery()
	setupGroup({ DOG_EAR, SHILKA })
	local kind, _, stores = create(makeDTO(nil, 35000), ON)
	lu.assertEquals(kind, "battery")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Role, Medusa.Constants.BatteryRole.AAA)
	lu.assertEquals(#battery.Units, 2)
	lu.assertEquals(stores.sensors:count(), 0)
end

function TestLocalRadarClassification:test_long_reach_radar_with_guns_stays_an_early_warning_radar()
	setupGroup({ EWR_1L13, SHILKA })
	local kind, _, stores = create(makeDTO(nil, 300000), ON)
	lu.assertEquals(kind, "sensor")
	lu.assertEquals(stores.sensors:count(), 1)
end

function TestLocalRadarClassification:test_unknown_reach_after_probing_leaves_a_sensor_group()
	setupGroup({ DOG_EAR, SHILKA })
	local kind, _, stores = create(makeDTO(nil, false), ON)
	lu.assertEquals(kind, "sensor")
	lu.assertEquals(stores.sensors:count(), 1)
end

function TestLocalRadarClassification:test_switch_off_classifies_the_measured_setups_as_stock_medusa()
	setupGroup({ DOG_EAR })
	lu.assertEquals((create(makeDTO(), OFF)), "sensor")
	setupGroup({ DOG_EAR, SHILKA })
	lu.assertEquals((create(makeDTO(), OFF)), "sensor")
	setupGroup({ DOG_EAR, IGLA, IGLA })
	lu.assertEquals((create(makeDTO(), OFF)), "manpad")
	-- No doctrine at all: classified as with the switch off.
	setupGroup({ DOG_EAR, SHILKA })
	lu.assertEquals((create(makeDTO(), nil)), "sensor")
end

function TestLocalRadarClassification:test_radar_alone_and_radar_with_manpads_keep_their_stock_classes_when_on()
	setupGroup({ DOG_EAR })
	lu.assertEquals((create(makeDTO(), ON)), "sensor")
	setupGroup({ DOG_EAR, IGLA, IGLA })
	lu.assertEquals((create(makeDTO(), ON)), "manpad")
end

function TestLocalRadarClassification:test_named_early_warning_group_with_guns_is_never_deferred()
	setupGroup({ DOG_EAR, SHILKA })
	local kind, _, stores = create(makeDTO({ Medusa.Constants.Role.EWR }), ON)
	lu.assertEquals(kind, "sensor")
	lu.assertTrue(stores.sensors:getAll()[1].NamedRole)
end

function TestLocalRadarClassification:test_auto_discovered_sensor_is_not_named()
	setupGroup({ DOG_EAR })
	local _, _, stores = create(makeDTO(), ON)
	lu.assertFalse(stores.sensors:getAll()[1].NamedRole)
end

function TestLocalRadarClassification:test_observer_named_group_without_weapons_is_an_observer_post()
	setupGroup({ INFANTRY, INFANTRY })
	local kind, count, stores = create(makeDTO({ Medusa.Constants.Role.OBSERVER }), ON)
	lu.assertEquals(kind, "observer")
	lu.assertEquals(count, 1)
	local post = stores.observers:getAll()[1]
	lu.assertEquals(post.GroupName, "iads.1bn.site")
	lu.assertEquals(post.UnitNames[1], "unit-1")
	lu.assertEquals(post.UnitNames[2], "unit-2")
	lu.assertEquals(post.Position.x, 100)
end

function TestLocalRadarClassification:test_observer_named_battery_is_still_a_battery()
	setupGroup({ { ["SAM LL"] = true, ["SR SAM"] = true }, DOG_EAR })
	local kind, _, stores = create(makeDTO({ Medusa.Constants.Role.OBSERVER }), ON)
	lu.assertEquals(kind, "battery")
	lu.assertEquals(stores.observers:count(), 0)
end

function TestLocalRadarClassification:test_unnamed_group_without_weapons_is_still_skipped()
	setupGroup({ INFANTRY })
	local kind, _, stores = create(makeDTO(), ON)
	lu.assertEquals(kind, "skipped")
	lu.assertEquals(stores.observers:count(), 0)
end
