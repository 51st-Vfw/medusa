local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Config")
require("entities.Entities")
require("entities.Track")
require("services.Services")
require("services.stores.TrackStore")
require("services.TrackDisplayIdAllocator")
require("services.TrackManager")

-- == Helpers ==

local mockTime = 1000
local ulidCounter = 0

local function setupMocks()
	mockTime = 1000
	ulidCounter = 0
	GetTime = function()
		return mockTime
	end
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	-- Config needs to be initialized for getSmoothedVelocityWindowSec / getTrackMemoryDurationSec
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
end

local function makeReport(overrides)
	local base = {
		NetworkId = "net-1",
		SourceType = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR,
		Position = { x = 1000, y = 500, z = 2000 },
		Velocity = { x = 100, y = 0, z = 50 },
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

-- == TestTrackManagerProcessReport ==

TestTrackManagerProcessReport = {}

function TestTrackManagerProcessReport:setUp()
	setupMocks()
	self.mgr = Medusa.Services.TrackManager:new()
end

function TestTrackManagerProcessReport:test_processReport_doesNotPersistDcsObjectMetadata()
	local track = self.mgr:processReport(makeReport({
		ObjectCategory = Object.Category.UNIT,
		UnitCategory = Unit.Category.AIRPLANE,
	}))

	lu.assertNotNil(track)
	lu.assertNotNil(track.TrackId)
	lu.assertEquals(track.NetworkId, "net-1")
	lu.assertIsNil(track.ObjectCategory)
	lu.assertIsNil(track.UnitCategory)
	lu.assertEquals(self.mgr:getStore():count(), 1)
end

function TestTrackManagerProcessReport:test_processReport_updatesExistingTrack()
	self.mgr:processReport(makeReport())

	mockTime = 1010
	local track = self.mgr:processReport(makeReport({
		Position = { x = 2000, y = 600, z = 3000 },
		Velocity = { x = 200, y = 10, z = 100 },
	}))

	lu.assertEquals(track.Position.x, 2000)
	lu.assertEquals(track.Velocity.x, 200)
	lu.assertEquals(self.mgr:getStore():count(), 1)
end

function TestTrackManagerProcessReport:test_processReport_calculatesSmoothedVelocity()
	self.mgr:processReport(makeReport())

	mockTime = 1010
	local track = self.mgr:processReport(makeReport({
		Velocity = { x = 200, y = 0, z = 100 },
	}))

	lu.assertNotNil(track.SmoothedVelocity)
end

function TestTrackManagerProcessReport:test_processReport_derivesManeuverState()
	self.mgr:processReport(makeReport())

	mockTime = 1010
	local track = self.mgr:processReport(makeReport({
		Velocity = { x = 200, y = 0, z = 100 },
	}))

	lu.assertNotNil(track.ManeuverState)
end

function TestTrackManagerProcessReport:test_processReport_returnsTrack()
	local track = self.mgr:processReport(makeReport())

	lu.assertNotNil(track)
	lu.assertEquals(track.NetworkId, "net-1")
	lu.assertEquals(track.DisplayTrackId, "AE0001")
end

function TestTrackManagerProcessReport:test_processReport_uses_originating_source_prefix()
	local track = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.AWACS }))

	lu.assertEquals(track.DisplayTrackId, "AW0001")
	lu.assertEquals(track.OriginSourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestTrackManagerProcessReport:test_source_handoff_retains_originating_display_id()
	local track = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.AWACS }))
	local displayId = track.DisplayTrackId

	local updated = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.SAM_BATTERY }))

	lu.assertEquals(updated.DisplayTrackId, displayId)
	lu.assertEquals(updated.OriginSourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestTrackManagerProcessReport:test_classification_change_retains_display_id()
	local track = self.mgr:processReport(makeReport())

	self.mgr:getStore():updateIdentification(track.TrackId, Medusa.Constants.TrackIdentification.BOGEY)

	lu.assertEquals(track.DisplayTrackId, "AE0001")
end

function TestTrackManagerProcessReport:test_new_track_records_its_first_sighting()
	local track = self.mgr:processReport(makeReport(), mockTime)

	lu.assertEquals(track.PositionHistory:size(), 1)
	local first = track.PositionHistory:get(1)
	lu.assertEquals(first.timestamp, mockTime)
	lu.assertEquals(first.position, { x = 1000, y = 500, z = 2000 })
	lu.assertEquals(first.velocity, { x = 100, y = 0, z = 50 })
end

function TestTrackManagerProcessReport:test_second_sighting_gives_two_history_entries()
	self.mgr:processReport(makeReport(), mockTime)
	mockTime = mockTime + 5
	local track = self.mgr:processReport(makeReport({ Position = { x = 1500, y = 500, z = 2250 } }), mockTime)

	lu.assertEquals(track.PositionHistory:size(), 2)
end

function TestTrackManagerProcessReport:test_processReport_nilReport()
	local result = self.mgr:processReport(nil)
	lu.assertNil(result)
end

function TestTrackManagerProcessReport:test_processReport_missingFields()
	lu.assertNil(self.mgr:processReport({ NetworkId = "n" }))
	lu.assertNil(self.mgr:processReport({ Position = { x = 0, y = 0, z = 0 } }))
	lu.assertNil(self.mgr:processReport({ Velocity = { x = 0, y = 0, z = 0 } }))
end

-- == TestTrackManagerPruneStale ==

TestTrackManagerPruneStale = {}

function TestTrackManagerPruneStale:setUp()
	setupMocks()
	-- The re-association tests here pin the stock behaviour (doctrine EvidenceReacquisition off: the same DCS object
	-- near its old position). Evidence-based re-acquisition is tested in test_track_reacquisition.lua.
	self.mgr = Medusa.Services.TrackManager:new({ evidenceReacquisition = false })
end

function TestTrackManagerPruneStale:test_pruneStale_activeBecomeStale()
	self.mgr:processReport(makeReport())

	-- Advance past the track memory duration (default 60s)
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)

	local track = self.mgr:getStore():get(self.mgr:getStore():getAll()[1].TrackId)
	lu.assertEquals(track.LifecycleState, Medusa.Constants.TrackLifecycleState.STALE)
end

function TestTrackManagerPruneStale:test_pruneStale_staleBecomesExpired()
	self.mgr:processReport(makeReport())

	-- First prune: ACTIVE -> STALE
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)

	-- Second prune: STALE -> removed (track is still old)
	self.mgr:pruneStale(pruneTime)

	lu.assertEquals(self.mgr:getStore():count(), 0)
end

function TestTrackManagerPruneStale:test_pruneStale_activeStaysActive()
	self.mgr:processReport(makeReport())

	-- Prune within the threshold: track should remain ACTIVE
	local pruneTime = mockTime + 30
	self.mgr:pruneStale(pruneTime)

	local tracks = self.mgr:getStore():getAll()
	lu.assertEquals(tracks[1].LifecycleState, Medusa.Constants.TrackLifecycleState.ACTIVE)
end

function TestTrackManagerPruneStale:test_pruneStale_emitsTrackBecameStale()
	local receivedEvents = Queue()
	self.mgr:getEventBus():subscribe("TrackBecameStale", receivedEvents)

	self.mgr:processReport(makeReport())

	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackBecameStale")
end

function TestTrackManagerPruneStale:test_pruneStale_emitsTrackRemoved()
	local receivedEvents = Queue()
	self.mgr:getEventBus():subscribe("TrackRemoved", receivedEvents)

	self.mgr:processReport(makeReport())

	-- Two prunes: first makes STALE, second removes
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackRemoved")
end

function TestTrackManagerPruneStale:test_pruneStale_removesFromNetworkIdIndex()
	self.mgr:processReport(makeReport({ NetworkId = "net-reuse" }))

	-- Expire the track
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)
	lu.assertEquals(self.mgr:getStore():count(), 0)

	-- Same NetworkId should create a new track
	mockTime = pruneTime + 10
	local track = self.mgr:processReport(makeReport({ NetworkId = "net-reuse" }))
	lu.assertNotNil(track)
	lu.assertEquals(self.mgr:getStore():count(), 1)
end

function TestTrackManagerPruneStale:test_reassociation_retains_display_id_with_new_canonical_id()
	local original = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.AWACS }))
	local originalCanonicalId = original.TrackId
	local originalDisplayId = original.DisplayTrackId
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		SourceType = Medusa.Constants.TrackSource.SAM_BATTERY,
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertNotEquals(reacquired.TrackId, originalCanonicalId)
	lu.assertEquals(reacquired.DisplayTrackId, originalDisplayId)
	lu.assertEquals(reacquired.OriginSourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestTrackManagerPruneStale:test_reassociation_uses_projected_position()
	local original = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.AWACS }))
	original.TrackIdentification = Medusa.Constants.TrackIdentification.BANDIT
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		SourceType = Medusa.Constants.TrackSource.SAM_BATTERY,
		Position = { x = 8200, y = 500, z = 5600 },
	}))

	lu.assertEquals(reacquired.TrackIdentification, Medusa.Constants.TrackIdentification.BANDIT)
	lu.assertEquals(reacquired.OriginSourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestTrackManagerPruneStale:test_reassociation_preserves_identification_transition_time()
	local original = self.mgr:processReport(makeReport())
	original.TrackIdentification = Medusa.Constants.TrackIdentification.BANDIT
	original.LastIdentificationTime = mockTime
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertEquals(reacquired.TrackIdentification, Medusa.Constants.TrackIdentification.BANDIT)
	lu.assertEquals(reacquired.LastIdentificationTime, 1000)
end

function TestTrackManagerPruneStale:test_reassociation_keeps_the_sensor_that_first_made_the_track()
	local original = self.mgr:processReport(makeReport())
	original.FirstSeenBy, original.FirstSeenKind, original.FirstSeenRangeM = "ewr-north", "EWR", 50000
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertEquals(reacquired.FirstSeenBy, "ewr-north")
	lu.assertEquals(reacquired.FirstSeenKind, "EWR")
	lu.assertEquals(reacquired.FirstSeenRangeM, 50000)
end

function TestTrackManagerPruneStale:test_reassociation_preserves_harm_evidence()
	local original = self.mgr:processReport(makeReport())
	original.HarmAssessment = {
		label = "CLEARED",
		llr = -24.82,
		scanCount = 21,
	}
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertEquals(reacquired.HarmAssessment.label, "CLEARED")
	lu.assertEquals(reacquired.HarmAssessment.llr, -24.82)
	lu.assertEquals(reacquired.HarmAssessment.scanCount, 21)
end

function TestTrackManagerPruneStale:test_reassociation_keeps_a_decoy_label_and_restarts_its_leg()
	local original = self.mgr:processReport(makeReport())
	original.DecoyAssessment = { label = "PROBABLE", runSince = 900, runSec = 100, launchEvidence = 30 }
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertEquals(reacquired.DecoyAssessment.label, "PROBABLE")
	lu.assertEquals(reacquired.DecoyAssessment.launchEvidence, 30)
	lu.assertNil(reacquired.DecoyAssessment.runSince)
	lu.assertEquals(reacquired.DecoyAssessment.runSec, 0)
end

function TestTrackManagerPruneStale:test_reassociation_records_its_first_sighting()
	self.mgr:processReport(makeReport())
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertEquals(reacquired.PositionHistory:size(), 1)
	local first = reacquired.PositionHistory:get(1)
	lu.assertEquals(first.timestamp, mockTime)
	lu.assertEquals(first.position, { x = 1100, y = 500, z = 2100 })
end

function TestTrackManagerPruneStale:test_reassociation_restarts_a_confirmed_arms_not_attacking_window()
	local original = self.mgr:processReport(makeReport())
	original.HarmAssessment = {
		label = "CONFIRMED",
		llr = 6,
		scanCount = 9,
		confirmedAt = mockTime,
		disproofSince = mockTime,
		disproofScans = 1,
	}
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	local state = reacquired.HarmAssessment
	lu.assertEquals(state.label, "CONFIRMED")
	lu.assertNil(state.disproofSince)
	lu.assertEquals(state.disproofScans, 0)
	lu.assertEquals(state.confirmedAt, 1000)
end

-- == TestTrackManagerMergeSplit ==

TestTrackManagerMergeSplit = {}

function TestTrackManagerMergeSplit:setUp()
	setupMocks()
	self.allocator = Medusa.Services.TrackDisplayIdAllocator:new()
	self.mgr = Medusa.Services.TrackManager:new({
		displayIdAllocator = self.allocator,
	})
end

function TestTrackManagerMergeSplit:test_merge_retains_survivor_id_and_absorbed_alias()
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))

	local merged = self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)

	lu.assertEquals(merged.DisplayTrackId, survivor.DisplayTrackId)
	lu.assertEquals(merged.DisplayTrackIdAliases, { absorbed.DisplayTrackId })
	lu.assertNil(self.mgr:getStore():get(absorbed.TrackId))
end

function TestTrackManagerMergeSplit:test_merge_alias_remains_reserved_until_survivor_is_dropped()
	local sourceType = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))
	self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)
	for _ = 3, Medusa.Services.TrackDisplayIdAllocator.MAX_NUMBER do
		self.allocator:allocate(sourceType)
	end

	lu.assertErrorMsgContains("display ID pool exhausted", function()
		self.allocator:allocate(sourceType)
	end)

	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime + Medusa.Constants.TRACK_REASSOC_TTL_SEC + 1)

	lu.assertEquals(self.allocator:allocate(sourceType), survivor.DisplayTrackId)
	lu.assertEquals(self.allocator:allocate(sourceType), absorbed.DisplayTrackId)
end

function TestTrackManagerMergeSplit:test_expiry_removes_all_merged_network_mappings()
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))
	self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)

	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	lu.assertNil(self.mgr._byNetworkId.survivor)
	lu.assertNil(self.mgr._byNetworkId.absorbed)
end

function TestTrackManagerMergeSplit:test_merged_alias_survives_dormant_reassociation()
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))
	local survivorDisplayId = survivor.DisplayTrackId
	local absorbedDisplayId = absorbed.DisplayTrackId
	self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)

	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)
	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		NetworkId = "survivor",
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertEquals(reacquired.DisplayTrackId, survivorDisplayId)
	lu.assertEquals(reacquired.DisplayTrackIdAliases, { absorbedDisplayId })
end

function TestTrackManagerMergeSplit:test_split_retains_continuing_id_and_allocates_new_id()
	local continuing = self.mgr:processReport(makeReport({ NetworkId = "continuing" }))

	local child = self.mgr:splitTrack(continuing.TrackId, makeReport({ NetworkId = "child" }), mockTime)

	lu.assertEquals(continuing.DisplayTrackId, "AE0001")
	lu.assertEquals(child.DisplayTrackId, "AE0002")
	lu.assertNotEquals(child.TrackId, continuing.TrackId)
end

TestTrackManagerDisplayLogging = {}

function TestTrackManagerDisplayLogging:setUp()
	setupMocks()
	self.originalInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	self.messages = {}
	env.info = function(message)
		self.messages[#self.messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.INFO)
	self.mgr = Medusa.Services.TrackManager:new()
end

function TestTrackManagerDisplayLogging:tearDown()
	env.info = self.originalInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
end

function TestTrackManagerDisplayLogging:test_merge_log_uses_display_id_and_retains_absorbed_alias()
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))

	self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)

	local message = self.messages[#self.messages]
	lu.assertStrContains(message, "merged track AE0002 into track AE0001; retained AE0002 as an alias")
	lu.assertNotStrContains(message, "ULID-")
end

-- == TestTrackManagerEventBus ==

TestTrackManagerEventBus = {}

function TestTrackManagerEventBus:setUp()
	setupMocks()
end

function TestTrackManagerEventBus:test_eventBus_subscriberReceivesTrackCreated()
	local mgr = Medusa.Services.TrackManager:new()
	local receivedEvents = Queue()
	mgr:getEventBus():subscribe("TrackCreated", receivedEvents)

	local track = mgr:processReport(makeReport())

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackCreated")
	lu.assertEquals(event.TrackId, track.TrackId)
	lu.assertNotEquals(event.TrackId, track.DisplayTrackId)
	lu.assertNotNil(event.timestamp)
end

function TestTrackManagerEventBus:test_eventBus_subscriberReceivesTrackUpdated()
	local mgr = Medusa.Services.TrackManager:new()
	local receivedEvents = Queue()
	mgr:getEventBus():subscribe("TrackUpdated", receivedEvents)

	mgr:processReport(makeReport())

	mockTime = 1010
	mgr:processReport(makeReport({ Velocity = { x = 200, y = 0, z = 100 } }))

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackUpdated")
	lu.assertNotNil(event.Position)
	lu.assertNotNil(event.Velocity)
end

function TestTrackManagerEventBus:test_track_update_builds_no_event_when_nothing_listens()
	local bus = EventBus()
	local published = 0
	local realPublish = bus.publish
	bus.publish = function(self, event)
		if event.id == "TrackUpdated" then
			published = published + 1
		end
		return realPublish(self, event)
	end
	local mgr = Medusa.Services.TrackManager:new({ eventBus = bus })

	mgr:processReport(makeReport())
	mockTime = 1010
	mgr:processReport(makeReport({ Velocity = { x = 200, y = 0, z = 100 } }))

	lu.assertEquals(published, 0)
end

function TestTrackManagerEventBus:test_eventBus_customEventBus()
	local customBus = EventBus()
	local mgr = Medusa.Services.TrackManager:new({ eventBus = customBus })

	lu.assertEquals(mgr:getEventBus(), customBus)

	local receivedEvents = Queue()
	customBus:subscribe("TrackCreated", receivedEvents)

	mgr:processReport(makeReport())

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackCreated")
end

-- == TestTrackManagerLaunchCue ==

TestTrackManagerLaunchCue = {}

function TestTrackManagerLaunchCue:setUp()
	setupMocks()
	self.mgr = Medusa.Services.TrackManager:new({ geoGrid = GeoGrid(5000, { "Track" }) })
	self.jet = self.mgr:processReport(
		makeReport({ NetworkId = "jet", Position = { x = 0, y = 6000, z = 0 }, Velocity = { x = 250, y = 0, z = 0 } }),
		mockTime
	)
	mockTime = mockTime + 30
end

local function newContact(self, id, pos, vel)
	return self.mgr:processReport(makeReport({ NetworkId = id, Position = pos, Velocity = vel }), mockTime)
end

function TestTrackManagerLaunchCue:test_weaponPullingAwayFromAnOlderContact_hasALaunchCue()
	-- A HARM 2 s after launch: 300 m ahead of its jet, 280 m/s faster.
	local harm = newContact(self, "harm", { x = 300, y = 6000, z = 0 }, { x = 530, y = -20, z = 0 })
	lu.assertNotNil(harm.LaunchCue)
	lu.assertEquals(harm.LaunchCue.FromTrackId, self.jet.TrackId)
end

function TestTrackManagerLaunchCue:test_wingmanAppearingNearItsLeader_hasNone()
	local wing = newContact(self, "wing", { x = -1500, y = 6000, z = 1500 }, { x = 280, y = 0, z = 0 })
	lu.assertNil(wing.LaunchCue)
end

function TestTrackManagerLaunchCue:test_fastJetCrossingHeadOn_hasNone()
	-- Mach 2 interceptor 2 km past the jet on an opposite heading: opening fast, but not leaving it.
	local mig = newContact(self, "mig", { x = -2000, y = 6000, z = 0 }, { x = -650, y = 0, z = 0 })
	lu.assertNil(mig.LaunchCue)
end

function TestTrackManagerLaunchCue:test_contactsFirstSeenTogether_giveNoCue()
	mockTime = mockTime - 25 -- the jet is only 5 s old: a formation coming into cover together
	local fast = newContact(self, "fast", { x = 300, y = 6000, z = 0 }, { x = 530, y = 0, z = 0 })
	lu.assertNil(fast.LaunchCue)
end

function TestTrackManagerLaunchCue:test_launchCue_survivesReassociation()
	self.mgr:setEvidenceReacquisition(false) -- stock re-association by object id
	local harm = newContact(self, "harm", { x = 300, y = 6000, z = 0 }, { x = 530, y = 0, z = 0 })
	lu.assertNotNil(harm.LaunchCue)
	mockTime = mockTime + 300
	self.mgr:pruneStale(mockTime)
	self.mgr:pruneStale(mockTime + 300)
	local again = newContact(self, "harm", harm.Position, harm.Velocity)
	lu.assertNotNil(again.LaunchCue)
end

-- == TestTrackManagerEvidence ==

TestTrackManagerEvidence = {}

function TestTrackManagerEvidence:setUp()
	setupMocks()
	self.mgr = Medusa.Services.TrackManager:new()
end

function TestTrackManagerEvidence:test_size_and_seen_as_fuse_from_the_first_report_on()
	local track = self.mgr:processReport(makeReport({ SizeDb = -11, SizeVarDb = 9 }), mockTime)
	lu.assertEquals(track.SizeDb, -11)
	mockTime = mockTime + 2
	self.mgr:processReport(makeReport({ SizeDb = -9, SizeVarDb = 9, SeenAs = "MUNITION" }), mockTime)
	lu.assertAlmostEquals(track.SizeDb, -10, 1e-9)
	lu.assertEquals(track.SeenAs, "MUNITION")
	lu.assertEquals(track.SeenAsTime, mockTime)
end

function TestTrackManagerEvidence:test_size_and_seen_as_survive_reassociation()
	self.mgr:setEvidenceReacquisition(false) -- stock re-association by object id
	local track = self.mgr:processReport(makeReport({ SizeDb = 6, SizeVarDb = 4, SeenAs = "AIRCRAFT" }), mockTime)
	for _ = 1, 3 do
		mockTime = mockTime + 2
		self.mgr:processReport(makeReport({ SizeDb = 6, SizeVarDb = 4 }), mockTime)
	end
	local weight = track.SizeWeight
	mockTime = mockTime + 61
	self.mgr:pruneStale(mockTime)
	self.mgr:pruneStale(mockTime)
	lu.assertEquals(self.mgr:getStore():count(), 0)
	mockTime = mockTime + 5
	local again = self.mgr:processReport(makeReport(), mockTime)
	lu.assertEquals(again.SizeDb, 6)
	lu.assertEquals(again.SizeWeight, weight)
	lu.assertEquals(again.SizeSpreadDb, track.SizeSpreadDb)
	lu.assertEquals(again.SeenAs, "AIRCRAFT")
	lu.assertEquals(again.SeenAsTime, 1000)
end
