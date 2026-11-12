local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Track")
require("services.Services")
require("services.stores.TrackStore")

-- == Track Entity Tests ==

TestTrack = {}

local function makeTrackData(overrides)
	local base = {
		Position = { x = 1000, y = 500, z = 2000 },
		Velocity = { x = 100, y = 0, z = 50 },
		NetworkId = "net-1",
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

function TestTrack:test_track_creation_fails_without_position()
	lu.assertErrorMsgContains("missing required field: Position", function()
		Medusa.Entities.Track.new({ Velocity = { x = 0, y = 0, z = 0 }, NetworkId = "n" })
	end)
end

function TestTrack:test_track_creation_fails_without_velocity()
	lu.assertErrorMsgContains("missing required field: Velocity", function()
		Medusa.Entities.Track.new({ Position = { x = 0, y = 0, z = 0 }, NetworkId = "n" })
	end)
end

function TestTrack:test_track_creation_fails_without_network_id()
	lu.assertErrorMsgContains("missing required field: NetworkId", function()
		Medusa.Entities.Track.new({ Position = { x = 0, y = 0, z = 0 }, Velocity = { x = 0, y = 0, z = 0 } })
	end)
end

function TestTrack:test_track_creation_preserves_provided_track_id()
	local track = Medusa.Entities.Track.new(makeTrackData({ TrackId = "my-track-123" }))
	lu.assertEquals(track.TrackId, "my-track-123")
end

function TestTrack:test_display_id_does_not_expose_canonical_id_when_unset()
	local track = Medusa.Entities.Track.new(makeTrackData({ TrackId = "my-track-123" }))

	lu.assertEquals(Medusa.Entities.Track.displayId(track), Medusa.Constants.TrackDisplayId.UNSET)
end

-- == TrackStore Tests ==

TestTrackStore = {}

local function makeTrack(overrides)
	return Medusa.Entities.Track.new(makeTrackData(overrides))
end

function TestTrackStore:test_store_add_and_get()
	local store = Medusa.Services.TrackStore:new()
	local track = makeTrack({ TrackId = "t1" })
	store:add(track)

	local got = store:get("t1")
	lu.assertNotNil(got)
	lu.assertEquals(got.TrackId, "t1")
end

function TestTrackStore:test_store_get_returns_nil_for_unknown()
	local store = Medusa.Services.TrackStore:new()
	lu.assertNil(store:get("nonexistent"))
end

function TestTrackStore:test_store_remove()
	local store = Medusa.Services.TrackStore:new()
	local track = makeTrack({ TrackId = "t2" })
	store:add(track)
	local removed = store:remove("t2")

	lu.assertNotNil(removed)
	lu.assertEquals(removed.TrackId, "t2")
	lu.assertNil(store:get("t2"))
	lu.assertEquals(store:count(), 0)
end

function TestTrackStore:test_store_remove_returns_nil_for_unknown()
	local store = Medusa.Services.TrackStore:new()
	lu.assertNil(store:remove("nonexistent"))
end

function TestTrackStore:test_store_get_all()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "a1" }))
	store:add(makeTrack({ TrackId = "a2" }))
	store:add(makeTrack({ TrackId = "a3" }))

	local all = store:getAll()
	lu.assertEquals(#all, 3)
end

function TestTrackStore:test_store_get_by_identification()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "c1", TrackIdentification = "HOSTILE" }))
	store:add(makeTrack({ TrackId = "c2", TrackIdentification = "HOSTILE" }))
	store:add(makeTrack({ TrackId = "c3", TrackIdentification = "BANDIT" }))

	local hostiles = store:getByIdentification("HOSTILE")
	lu.assertEquals(#hostiles, 2)

	local bandits = store:getByIdentification("BANDIT")
	lu.assertEquals(#bandits, 1)
end

function TestTrackStore:test_store_get_by_identification_empty()
	local store = Medusa.Services.TrackStore:new()
	local result = store:getByIdentification("NONEXISTENT")
	lu.assertEquals(#result, 0)
end

function TestTrackStore:test_store_count()
	local store = Medusa.Services.TrackStore:new()
	lu.assertEquals(store:count(), 0)

	store:add(makeTrack({ TrackId = "n1" }))
	lu.assertEquals(store:count(), 1)

	store:add(makeTrack({ TrackId = "n2" }))
	lu.assertEquals(store:count(), 2)

	store:remove("n1")
	lu.assertEquals(store:count(), 1)
end

function TestTrackStore:test_store_update_identification()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "u1", TrackIdentification = "UNKNOWN" }))

	store:updateIdentification("u1", "HOSTILE")

	local track = store:get("u1")
	lu.assertEquals(track.TrackIdentification, "HOSTILE")

	local unknown = store:getByIdentification("UNKNOWN")
	lu.assertEquals(#unknown, 0)

	local hostiles = store:getByIdentification("HOSTILE")
	lu.assertEquals(#hostiles, 1)
	lu.assertEquals(hostiles[1].TrackId, "u1")
end

function TestTrackStore:test_store_add_duplicate_errors()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "dup1", DisplayTrackId = "AE0001" }))

	lu.assertErrorMsgContains("duplicate track: AE0001", function()
		store:add(makeTrack({ TrackId = "dup1", DisplayTrackId = "AE0001" }))
	end)
end

function TestTrackStore:test_store_get_stale_ids()
	local store = Medusa.Services.TrackStore:new()
	store:add(Medusa.Entities.Track.new(makeTrackData({ TrackId = "s1", LastDetectionTime = 100 })))
	store:add(Medusa.Entities.Track.new(makeTrackData({ TrackId = "s2", LastDetectionTime = 200 })))
	store:add(Medusa.Entities.Track.new(makeTrackData({ TrackId = "s3", LastDetectionTime = 300 })))

	local stale = store:getStaleIds(250)
	lu.assertEquals(#stale, 2)
end

function TestTrackStore:test_store_get_all_reuses_output_table()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "r1" }))
	store:add(makeTrack({ TrackId = "r2" }))

	local buf = {}
	local result = store:getAll(buf)
	lu.assertEquals(result, buf)
	lu.assertEquals(#buf, 2)
end

-- == Track Update Tests ==

TestTrackUpdate = {}

function TestTrackUpdate:test_update_sets_position_velocity_timestamp()
	local track = makeTrack()
	local newPos = { x = 2000, y = 600, z = 3000 }
	local newVel = { x = 200, y = 10, z = 100 }

	Medusa.Entities.Track.update(track, newPos, newVel, 5000)

	lu.assertEquals(track.Position, newPos)
	lu.assertEquals(track.Velocity, newVel)
	lu.assertEquals(track.LastDetectionTime, 5000)
end

function TestTrackUpdate:test_update_appends_to_position_history()
	local track = makeTrack()
	lu.assertEquals(track.PositionHistory:size(), 0)

	Medusa.Entities.Track.update(track, { x = 1, y = 2, z = 3 }, { x = 10, y = 0, z = 5 }, 100)
	lu.assertEquals(track.PositionHistory:size(), 1)
	local arr = track.PositionHistory:toArray()
	lu.assertEquals(arr[1].timestamp, 100)
	lu.assertEquals(arr[1].position.x, 1)
	lu.assertEquals(arr[1].velocity.x, 10)

	Medusa.Entities.Track.update(track, { x = 2, y = 3, z = 4 }, { x = 20, y = 0, z = 10 }, 200)
	lu.assertEquals(track.PositionHistory:size(), 2)
end

function TestTrackUpdate:test_update_bounds_position_history()
	local track = makeTrack()
	local max = Medusa.Entities.Track.MAX_POSITION_HISTORY

	for i = 1, max + 5 do
		Medusa.Entities.Track.update(track, { x = i, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, i)
	end

	lu.assertEquals(track.PositionHistory:size(), max)
	-- Oldest entries should have been removed; first entry should be timestamp 6
	local arr = track.PositionHistory:toArray()
	lu.assertEquals(arr[1].timestamp, 6)
end

function TestTrackUpdate:test_update_resets_stale_to_active()
	local track = makeTrack({ LifecycleState = "STALE" })
	lu.assertEquals(track.LifecycleState, "STALE")

	Medusa.Entities.Track.update(track, { x = 1, y = 2, z = 3 }, { x = 10, y = 0, z = 5 }, 100)
	lu.assertEquals(track.LifecycleState, "ACTIVE")
end

-- == Smoothed Velocity Tests ==

TestSmoothedVelocity = {}

function TestSmoothedVelocity:test_single_entry_uses_current_velocity()
	local track = makeTrack()
	Medusa.Entities.Track.update(track, { x = 1, y = 0, z = 0 }, { x = 50, y = 5, z = 25 }, 100)

	Medusa.Entities.Track.computeSmoothedVelocity(track, 60)

	lu.assertAlmostEquals(track.SmoothedVelocity.x, 50, 0.001)
	lu.assertAlmostEquals(track.SmoothedVelocity.y, 5, 0.001)
	lu.assertAlmostEquals(track.SmoothedVelocity.z, 25, 0.001)
end

function TestSmoothedVelocity:test_averages_over_window()
	local track = makeTrack()

	Medusa.Entities.Track.update(track, { x = 1, y = 0, z = 0 }, { x = 100, y = 0, z = 0 }, 10)
	Medusa.Entities.Track.update(track, { x = 2, y = 0, z = 0 }, { x = 200, y = 0, z = 0 }, 20)
	Medusa.Entities.Track.update(track, { x = 3, y = 0, z = 0 }, { x = 300, y = 0, z = 0 }, 30)

	Medusa.Entities.Track.computeSmoothedVelocity(track, 60)

	-- Average of 100, 200, 300 = 200
	lu.assertAlmostEquals(track.SmoothedVelocity.x, 200, 0.001)
end

function TestSmoothedVelocity:test_window_excludes_old_entries()
	local track = makeTrack()

	Medusa.Entities.Track.update(track, { x = 1, y = 0, z = 0 }, { x = 100, y = 0, z = 0 }, 10)
	Medusa.Entities.Track.update(track, { x = 2, y = 0, z = 0 }, { x = 200, y = 0, z = 0 }, 50)
	Medusa.Entities.Track.update(track, { x = 3, y = 0, z = 0 }, { x = 300, y = 0, z = 0 }, 80)

	-- Window of 40 sec from latest (80): cutoff at 40, so entry at t=10 excluded
	Medusa.Entities.Track.computeSmoothedVelocity(track, 40)

	-- Average of 200, 300 = 250
	lu.assertAlmostEquals(track.SmoothedVelocity.x, 250, 0.001)
end

-- == Maneuver State Tests ==

TestManeuverState = {}

function TestManeuverState:test_straight_for_same_heading()
	local track = makeTrack()
	track.Velocity = { x = 100, y = 0, z = 0 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 0 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "STRAIGHT")
end

function TestManeuverState:test_turning_right_for_positive_heading_change()
	-- Current heading: 45 deg (vx=100, vz=100) -> atan2(100,100) = pi/4
	-- Smoothed heading: 0 deg (vx=100, vz=0) -> atan2(0,100) = 0
	-- Delta = pi/4 - 0 = pi/4 ~ 0.785 > 0.15 -> TURNING_RIGHT
	local track = makeTrack()
	track.Velocity = { x = 100, y = 0, z = 100 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 0 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "TURNING_RIGHT")
end

function TestManeuverState:test_turning_left_for_negative_heading_change()
	-- Current heading: 0 deg (vx=100, vz=0) -> atan2(0,100) = 0
	-- Smoothed heading: 45 deg (vx=100, vz=100) -> atan2(100,100) = pi/4
	-- Delta = 0 - pi/4 = -pi/4 ~ -0.785 < -0.15 -> TURNING_LEFT
	local track = makeTrack()
	track.Velocity = { x = 100, y = 0, z = 0 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 100 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "TURNING_LEFT")
end

function TestManeuverState:test_unknown_when_no_smoothed_velocity()
	local track = makeTrack()
	track.SmoothedVelocity = nil

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "UNKNOWN")
end

function TestManeuverState:test_unknown_when_stationary()
	local track = makeTrack()
	track.Velocity = { x = 0.1, y = 0, z = 0.1 }
	track.SmoothedVelocity = { x = 0.1, y = 0, z = 0.1 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "UNKNOWN")
end

function TestManeuverState:test_maneuvering_for_large_speed_change()
	-- Same heading but very different speeds (>30% change)
	local track = makeTrack()
	track.Velocity = { x = 200, y = 0, z = 0 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 0 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "MANEUVERING")
end

function TestManeuverState:test_orbiting_for_reversed_heading()
	-- Current heading ~= pi, smoothed heading ~= 0 -> delta ~= pi > 2.5
	local track = makeTrack()
	track.Velocity = { x = -100, y = 0, z = 0 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 0 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "ORBITING")
end

-- == Contact evidence on the track ==

TestTrackEvidence = {}

local CE = Medusa.Constants.ContactEvidence
local SeenAs = Medusa.Constants.SeenAs

local function look(track, db, var, seen, now)
	Medusa.Entities.Track.observeEvidence(track, { SizeDb = db, SizeVarDb = var, SeenAs = seen }, now or 0)
end

function TestTrackEvidence:test_new_track_has_no_size_estimate()
	local track = Medusa.Entities.Track.new(makeTrackData())
	lu.assertNil(track.SizeDb)
	lu.assertNil(Medusa.Entities.Track.sizeClass(track))
end

function TestTrackEvidence:test_looks_fuse_by_inverse_variance()
	local track = Medusa.Entities.Track.new(makeTrackData())
	look(track, 0, 1)
	look(track, 10, 4)
	lu.assertAlmostEquals(track.SizeDb, 2, 1e-9)
	lu.assertAlmostEquals(track.SizeWeight, 1.25, 1e-9)
end

function TestTrackEvidence:test_spread_adds_the_unknown_shape_to_the_looks_own_noise()
	local F = CE.SIZE_SPREAD_FLOOR_DB
	local track = Medusa.Entities.Track.new(makeTrackData())
	look(track, 6, 9)
	lu.assertAlmostEquals(track.SizeSpreadDb, math.sqrt(9 + F * F), 1e-9)
	for _ = 1, 50 do
		look(track, 6, 9)
	end
	lu.assertAlmostEquals(track.SizeSpreadDb, math.sqrt(1 / CE.SIZE_MAX_WEIGHT + F * F), 1e-9)
	lu.assertTrue(track.SizeSpreadDb > F)
end

function TestTrackEvidence:test_a_few_looks_are_needed_before_any_size_call()
	-- One look far below the split is still no call: a look's noise must first average down to the shape floor.
	local track = Medusa.Entities.Track.new(makeTrackData())
	look(track, -25, 9)
	lu.assertNil(Medusa.Entities.Track.sizeClass(track))
	look(track, -25, 9)
	look(track, -25, 9)
	lu.assertEquals(Medusa.Entities.Track.sizeClass(track), "small")
end

function TestTrackEvidence:test_memory_fades_so_a_changed_return_shows()
	local track = Medusa.Entities.Track.new(makeTrackData())
	for _ = 1, 200 do
		look(track, 0, 4)
	end
	for _ = 1, 40 do
		look(track, 10, 4)
	end
	lu.assertTrue(track.SizeDb > 5)
end

function TestTrackEvidence:test_report_without_size_leaves_the_estimate()
	local track = Medusa.Entities.Track.new(makeTrackData())
	look(track, 3, 4)
	Medusa.Entities.Track.observeEvidence(track, {}, 1)
	lu.assertEquals(track.SizeDb, 3)
end

function TestTrackEvidence:test_arm_sized_looks_read_small_and_jet_sized_looks_read_large()
	local arm = Medusa.Entities.Track.new(makeTrackData())
	local jet = Medusa.Entities.Track.new(makeTrackData())
	-- Returns 5.5 dB either side of the split: one 3 dB look is not yet confident, five are.
	look(arm, -9, 9)
	look(jet, 2, 9)
	lu.assertNil(Medusa.Entities.Track.sizeClass(arm))
	lu.assertNil(Medusa.Entities.Track.sizeClass(jet))
	for _ = 1, 4 do
		look(arm, -9, 9)
		look(jet, 2, 9)
	end
	lu.assertEquals(Medusa.Entities.Track.sizeClass(arm), "small")
	lu.assertEquals(Medusa.Entities.Track.sizeClass(jet), "large")
end

function TestTrackEvidence:test_beam_on_arm_with_the_largest_shape_offset_never_reads_large()
	-- 0.08 m2 (-11 dBsm) + 7 dB beam + 3 dB shape: -1 dBsm, looked at for as long as you like.
	local arm = Medusa.Entities.Track.new(makeTrackData())
	for _ = 1, 100 do
		look(arm, -1, 6.25)
	end
	lu.assertNil(Medusa.Entities.Track.sizeClass(arm))
end

function TestTrackEvidence:test_small_fighter_nose_on_with_the_smallest_offset_never_reads_small()
	-- 2 m2 (+3 dBsm) - 3 dB shape, nose-on: 0 dBsm.
	local jet = Medusa.Entities.Track.new(makeTrackData())
	for _ = 1, 100 do
		look(jet, 0, 6.25)
	end
	lu.assertNotEquals(Medusa.Entities.Track.sizeClass(jet), "small")
end

function TestTrackEvidence:test_seen_as_is_kept_with_its_time()
	local track = Medusa.Entities.Track.new(makeTrackData())
	look(track, nil, nil, SeenAs.AIRCRAFT, 50)
	lu.assertEquals(track.SeenAs, SeenAs.AIRCRAFT)
	lu.assertEquals(track.SeenAsTime, 50)
	look(track, nil, nil, nil, 60)
	lu.assertEquals(track.SeenAs, SeenAs.AIRCRAFT)
	lu.assertEquals(track.SeenAsTime, 50)
end

function TestTrackEvidence:test_latest_sighting_replaces_an_earlier_one()
	local track = Medusa.Entities.Track.new(makeTrackData())
	look(track, nil, nil, SeenAs.MUNITION, 55)
	lu.assertEquals(track.SeenAs, SeenAs.MUNITION)
	look(track, nil, nil, SeenAs.AIRCRAFT, 60)
	lu.assertEquals(track.SeenAs, SeenAs.AIRCRAFT)
	lu.assertEquals(track.SeenAsTime, 60)
end
