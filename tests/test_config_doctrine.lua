local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Config")
require("entities.Entities")
require("entities.Doctrine")

-- == Config.getDoctrine Resolution Tests ==

TestGetDoctrine = {}

local ulidCounter = 0

function TestGetDoctrine:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	Medusa.Config.Current = nil
	-- Clear legacy global
	Medusa_MM_Doctrine = nil
end

function TestGetDoctrine:test_inline_table_applies_overrides()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({ ROE = "FREE", PkFloor = 0.25 })
	lu.assertEquals(d.ROE, "FREE")
	lu.assertAlmostEquals(d.PkFloor, 0.25, 0.001)
end

function TestGetDoctrine:test_inline_table_emcon_preserved()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({
		EMCON = { LR_SAM = "MINIMIZE", MR_SAM = "PERIODIC_SCAN" },
	})
	lu.assertEquals(d.EMCON.LR_SAM, "MINIMIZE")
	lu.assertEquals(d.EMCON.MR_SAM, "PERIODIC_SCAN")
end

function TestGetDoctrine:test_inline_table_all_fields_reach_doctrine()
	Medusa.Config:initialize()
	local input = {
		Name = "Test Doctrine",
		ROE = "FREE",
		HARMResponse = "SHUTDOWN",
		PkFloor = 0.30,
		DefendPk = 0.50,
		LookaheadSec = 15,
		C2DelaySec = 5,
		HoldDownSec = 10,
		EngageTimeoutSec = 120,
		SAMAsEWR = "ALWAYS",
		BatteryTargetDatalink = false,
		AutoDiscoverEwrs = false,
		ShootScoot = "AFTER_ENGAGEMENT",
		EMCON = { LR_SAM = "MINIMIZE" },
		ScanSec = 45,
		QuietPeriodSec = 20,
		MANPAD = {
			AlertnessDecaySec = 3600,
			FieldRadioRangeM = 9000,
			AudioRangeM = 4500,
		},
	}
	local d = Medusa.Config:getDoctrine(input)
	lu.assertEquals(d.Name, "Test Doctrine")
	lu.assertEquals(d.ROE, "FREE")
	lu.assertEquals(d.HARMResponse, "SHUTDOWN")
	lu.assertAlmostEquals(d.PkFloor, 0.30, 0.001)
	lu.assertAlmostEquals(d.DefendPk, 0.50, 0.001)
	lu.assertEquals(d.LookaheadSec, 15)
	lu.assertEquals(d.C2DelaySec, 5)
	lu.assertEquals(d.HoldDownSec, 10)
	lu.assertEquals(d.EngageTimeoutSec, 120)
	lu.assertEquals(d.SAMAsEWR, "ALWAYS")
	lu.assertFalse(d.BatteryTargetDatalink)
	lu.assertFalse(d.AutoDiscoverEwrs)
	lu.assertEquals(d.ShootScoot, "AFTER_ENGAGEMENT")
	lu.assertEquals(d.EMCON.LR_SAM, "MINIMIZE")
	lu.assertEquals(d.ScanSec, 45)
	lu.assertEquals(d.QuietPeriodSec, 20)
	lu.assertEquals(d.MANPAD.AlertnessDecaySec, 3600)
	lu.assertEquals(d.MANPAD.FieldRadioRangeM, 9000)
	lu.assertEquals(d.MANPAD.AudioRangeM, 4500)
end

function TestGetDoctrine:test_nil_input_uses_defaults()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine(nil)
	lu.assertEquals(d.ROE, "TIGHT")
	lu.assertEquals(d.HARMResponse, "AUTO_DEFENSE")
	lu.assertAlmostEquals(d.PkFloor, 0.25, 0.001)
	lu.assertEquals(d.MANPAD.AlertnessDecaySec, 14400)
	lu.assertEquals(d.MANPAD.FieldRadioRangeM, 5000)
	lu.assertEquals(d.MANPAD.AudioRangeM, 6000)
	lu.assertEquals(d.AAA.AudioRangeM, 6000)
	lu.assertAlmostEquals(d.AAA.AreaFireChance, 0.20, 0.001)
	lu.assertAlmostEquals(d.AAA.BarrageChance, 0.25, 0.001)
	lu.assertEquals(d.AAA.MaxBarrageGroups, 15)
	lu.assertTrue(d.CrewSuppression.Enabled)
	lu.assertEquals(d.CrewSuppression.DurationMinSec, 30)
	lu.assertEquals(d.CrewSuppression.DurationMaxSec, 120)
	lu.assertAlmostEquals(d.CrewSuppression.MaxGroupDiameterM, 609.6, 0.001)
	lu.assertEquals(d.CrewSuppression.ExplosiveRadiusScaleM, 10)
	lu.assertEquals(d.CrewSuppression.ExplosiveRadiusMaxM, 500)
	lu.assertEquals(d.CrewSuppression.ExplosiveEffectiveness, 1)
	lu.assertEquals(d.CrewSuppression.DefaultCrewSkill, Medusa.Constants.CrewSkill.AVERAGE)
	lu.assertEquals(d.CrewSuppression.SkillResistancePerLevel, 0.1)
	lu.assertEquals(d.CrewSuppression.CannonRadiusM, 150)
	lu.assertEquals(d.CrewSuppression.CannonEffectiveness, 0.5)
end

function TestGetDoctrine:test_crew_suppression_skill_and_cannon_settings_are_validated()
	Medusa.Config:initialize()
	local bounded = Medusa.Config:getDoctrine({
		CrewSuppression = {
			DefaultCrewSkill = Medusa.Constants.CrewSkill.EXCELLENT,
			SkillResistancePerLevel = 1,
			CannonRadiusM = 1000,
			CannonEffectiveness = -1,
		},
	})
	local invalid = Medusa.Config:getDoctrine({ CrewSuppression = { DefaultCrewSkill = "Random" } })

	lu.assertEquals(bounded.CrewSuppression.DefaultCrewSkill, Medusa.Constants.CrewSkill.EXCELLENT)
	lu.assertEquals(bounded.CrewSuppression.SkillResistancePerLevel, 0.3)
	lu.assertEquals(bounded.CrewSuppression.CannonRadiusM, 500)
	lu.assertEquals(bounded.CrewSuppression.CannonEffectiveness, 0)
	lu.assertEquals(invalid.CrewSuppression.DefaultCrewSkill, Medusa.Constants.CrewSkill.AVERAGE)
end

function TestGetDoctrine:test_crew_suppression_explosive_settings_are_bounded()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({
		CrewSuppression = {
			ExplosiveRadiusScaleM = 1000,
			ExplosiveRadiusMaxM = -1,
			ExplosiveEffectiveness = 2,
		},
	})

	lu.assertEquals(d.CrewSuppression.ExplosiveRadiusScaleM, 500)
	lu.assertEquals(d.CrewSuppression.ExplosiveRadiusMaxM, 1)
	lu.assertEquals(d.CrewSuppression.ExplosiveEffectiveness, 1)
end

function TestGetDoctrine:test_crew_suppression_non_finite_settings_use_defaults()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({
		CrewSuppression = {
			DurationMinSec = 0 / 0,
			DurationMaxSec = math.huge,
			ExplosiveRadiusScaleM = math.huge,
			ExplosiveRadiusMaxM = -math.huge,
			ExplosiveEffectiveness = 0 / 0,
		},
	})

	lu.assertEquals(d.CrewSuppression.DurationMinSec, 30)
	lu.assertEquals(d.CrewSuppression.DurationMaxSec, 120)
	lu.assertEquals(d.CrewSuppression.ExplosiveRadiusScaleM, 10)
	lu.assertEquals(d.CrewSuppression.ExplosiveRadiusMaxM, 500)
	lu.assertEquals(d.CrewSuppression.ExplosiveEffectiveness, 1)
end

function TestGetDoctrine:test_crew_suppression_enabled_requires_boolean()
	Medusa.Config:initialize()
	local disabled = Medusa.Config:getDoctrine({ CrewSuppression = { Enabled = false } })
	local invalid = Medusa.Config:getDoctrine({ CrewSuppression = { Enabled = "false" } })

	lu.assertFalse(disabled.CrewSuppression.Enabled)
	lu.assertTrue(invalid.CrewSuppression.Enabled)
end

function TestGetDoctrine:test_crew_suppression_duration_range_is_bounded()
	Medusa.Config:initialize()
	local belowMinimum = Medusa.Config:getDoctrine({ CrewSuppression = { DurationMinSec = 0 } })
	local invalid = Medusa.Config:getDoctrine({ CrewSuppression = { DurationMinSec = "invalid" } })
	local numericText = Medusa.Config:getDoctrine({ CrewSuppression = { DurationMinSec = "15" } })
	local aboveMaximum = Medusa.Config:getDoctrine({ CrewSuppression = { DurationMaxSec = 3601 } })
	local valid = Medusa.Config:getDoctrine({ CrewSuppression = { DurationMinSec = 15, DurationMaxSec = 90 } })
	local reversed = Medusa.Config:getDoctrine({ CrewSuppression = { DurationMinSec = 120, DurationMaxSec = 30 } })

	lu.assertEquals(belowMinimum.CrewSuppression.DurationMinSec, 1)
	lu.assertEquals(invalid.CrewSuppression.DurationMinSec, 30)
	lu.assertEquals(numericText.CrewSuppression.DurationMinSec, 15)
	lu.assertEquals(aboveMaximum.CrewSuppression.DurationMaxSec, 3600)
	lu.assertEquals(valid.CrewSuppression.DurationMinSec, 15)
	lu.assertEquals(valid.CrewSuppression.DurationMaxSec, 90)
	lu.assertEquals(reversed.CrewSuppression.DurationMinSec, 30)
	lu.assertEquals(reversed.CrewSuppression.DurationMaxSec, 120)
end

function TestGetDoctrine:test_crew_suppression_group_diameter_is_bounded()
	Medusa.Config:initialize()
	local belowMinimum = Medusa.Config:getDoctrine({ CrewSuppression = { MaxGroupDiameterM = 0 } })
	local aboveMaximum = Medusa.Config:getDoctrine({ CrewSuppression = { MaxGroupDiameterM = 100001 } })
	local invalid = Medusa.Config:getDoctrine({ CrewSuppression = { MaxGroupDiameterM = "invalid" } })
	local valid = Medusa.Config:getDoctrine({ CrewSuppression = { MaxGroupDiameterM = 500 } })

	lu.assertEquals(belowMinimum.CrewSuppression.MaxGroupDiameterM, 1)
	lu.assertEquals(aboveMaximum.CrewSuppression.MaxGroupDiameterM, 100000)
	lu.assertAlmostEquals(invalid.CrewSuppression.MaxGroupDiameterM, 609.6, 0.001)
	lu.assertEquals(valid.CrewSuppression.MaxGroupDiameterM, 500)
end

function TestGetDoctrine:test_aaa_overrides_are_validated()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({
		AAA = { AudioRangeM = 25000, AreaFireChance = -0.5, BarrageChance = 1.5, MaxBarrageGroups = 101 },
	})
	lu.assertEquals(d.AAA.AudioRangeM, 20000)
	lu.assertEquals(d.AAA.AreaFireChance, 0)
	lu.assertEquals(d.AAA.BarrageChance, 1)
	lu.assertEquals(d.AAA.MaxBarrageGroups, 100)
	local noBarrage = Medusa.Config:getDoctrine({ AAA = { BarrageChance = -0.5 } })
	lu.assertEquals(noBarrage.AAA.BarrageChance, 0)
	local disabled = Medusa.Config:getDoctrine({ AAA = { MaxBarrageGroups = -1 } })
	lu.assertEquals(disabled.AAA.MaxBarrageGroups, 0)
	local fractional = Medusa.Config:getDoctrine({ AAA = { MaxBarrageGroups = 15.9 } })
	lu.assertEquals(fractional.AAA.MaxBarrageGroups, 15)
	local excessiveAreaFire = Medusa.Config:getDoctrine({ AAA = { AreaFireChance = 0.75 } })
	lu.assertEquals(excessiveAreaFire.AAA.AreaFireChance, 0.5)
end

function TestGetDoctrine:test_aaa_audio_range_zero_disables_audio_detection()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({ AAA = { AudioRangeM = 0 } })
	lu.assertEquals(d.AAA.AudioRangeM, 0)
	lu.assertAlmostEquals(d.AAA.AreaFireChance, 0.20, 0.001)
end

function TestGetDoctrine:test_manpad_field_radio_range_zero_disables_and_negative_clamps_to_zero()
	Medusa.Config:initialize()
	local disabled = Medusa.Config:getDoctrine({ MANPAD = { FieldRadioRangeM = 0 } })
	local negative = Medusa.Config:getDoctrine({ MANPAD = { FieldRadioRangeM = -1 } })
	lu.assertEquals(disabled.MANPAD.FieldRadioRangeM, 0)
	lu.assertEquals(negative.MANPAD.FieldRadioRangeM, 0)
end

function TestGetDoctrine:test_manpad_field_radio_range_is_bounded()
	Medusa.Config:initialize()
	local maximum = Medusa.Constants.Manpad.MAX_FIELD_RADIO_RANGE_M
	local atMaximum = Medusa.Config:getDoctrine({ MANPAD = { FieldRadioRangeM = maximum } })
	local aboveMaximum = Medusa.Config:getDoctrine({ MANPAD = { FieldRadioRangeM = maximum + 1 } })

	lu.assertEquals(atMaximum.MANPAD.FieldRadioRangeM, maximum)
	lu.assertEquals(aboveMaximum.MANPAD.FieldRadioRangeM, maximum)
end

function TestGetDoctrine:test_manpad_alertness_decay_zero_disables_and_negative_clamps_to_zero()
	Medusa.Config:initialize()
	local disabled = Medusa.Config:getDoctrine({ MANPAD = { AlertnessDecaySec = 0 } })
	local negative = Medusa.Config:getDoctrine({ MANPAD = { AlertnessDecaySec = -1 } })
	lu.assertEquals(disabled.MANPAD.AlertnessDecaySec, 0)
	lu.assertEquals(negative.MANPAD.AlertnessDecaySec, 0)
end

function TestGetDoctrine:test_manpad_audio_range_zero_disables_and_above_maximum_clamps()
	Medusa.Config:initialize()
	local disabled = Medusa.Config:getDoctrine({ MANPAD = { AudioRangeM = 0 } })
	local aboveMaximum = Medusa.Config:getDoctrine({
		MANPAD = { AudioRangeM = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M + 1 },
	})
	lu.assertEquals(disabled.MANPAD.AudioRangeM, 0)
	lu.assertEquals(aboveMaximum.MANPAD.AudioRangeM, Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M)
end

function TestGetDoctrine:test_flat_manpad_fields_are_accepted_as_compatibility_aliases()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({
		MANPADAlertnessDecaySec = 3600,
		MANPADFieldRadioRangeM = 9000,
	})
	lu.assertEquals(d.MANPAD.AlertnessDecaySec, 3600)
	lu.assertEquals(d.MANPAD.FieldRadioRangeM, 9000)
	lu.assertIsNil(d.MANPADAlertnessDecaySec)
	lu.assertIsNil(d.MANPADFieldRadioRangeM)
end

function TestGetDoctrine:test_string_input_resolves_global()
	Medusa.Config:initialize()
	_G["MyDoctrine"] = { ROE = "HOLD", Name = "Global Doctrine" }
	local d = Medusa.Config:getDoctrine("MyDoctrine")
	lu.assertEquals(d.ROE, "HOLD")
	lu.assertEquals(d.Name, "Global Doctrine")
	_G["MyDoctrine"] = nil
end

function TestGetDoctrine:test_string_input_missing_global_uses_defaults()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine("NonExistentGlobal")
	lu.assertEquals(d.ROE, "TIGHT")
end

function TestGetDoctrine:test_legacy_global_fallback()
	Medusa.Config:initialize()
	Medusa_MM_Doctrine = {
		ROE = "FREE",
		ScanSec = 99,
		MANPAD = { AlertnessDecaySec = 7200, FieldRadioRangeM = 6400, AudioRangeM = 3200 },
	}
	local d = Medusa.Config:getDoctrine(nil)
	lu.assertEquals(d.ROE, "FREE")
	lu.assertEquals(d.ScanSec, 99)
	lu.assertEquals(d.MANPAD.AlertnessDecaySec, 7200)
	lu.assertEquals(d.MANPAD.FieldRadioRangeM, 6400)
	lu.assertEquals(d.MANPAD.AudioRangeM, 3200)
	Medusa_MM_Doctrine = nil
end

function TestGetDoctrine:test_inline_table_takes_priority_over_legacy_global()
	Medusa.Config:initialize()
	Medusa_MM_Doctrine = { ROE = "HOLD" }
	local d = Medusa.Config:getDoctrine({ ROE = "FREE" })
	lu.assertEquals(d.ROE, "FREE")
	Medusa_MM_Doctrine = nil
end

-- == Config.getNetworks Doctrine Passthrough Tests ==

TestGetNetworksDoctrine = {}

function TestGetNetworksDoctrine:setUp()
	Medusa.Config.Current = nil
	Medusa_MM_Doctrine = nil
end

function TestGetNetworksDoctrine:test_inline_doctrine_passed_through()
	MEDUSA_CONFIG = {
		Networks = {
			{ name = "TEST", coalition = 1, prefix = "test", doctrine = { ROE = "FREE", PkFloor = 0.30 } },
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local nets = Medusa.Config:getNetworks()
	lu.assertEquals(#nets, 1)
	lu.assertNotNil(nets[1].doctrine)
	lu.assertEquals(nets[1].doctrine.ROE, "FREE")
	lu.assertAlmostEquals(nets[1].doctrine.PkFloor, 0.30, 0.001)
	MEDUSA_CONFIG = nil
end

function TestGetNetworksDoctrine:test_missing_doctrine_passes_nil()
	MEDUSA_CONFIG = {
		Networks = {
			{ name = "TEST", coalition = 1, prefix = "test" },
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local nets = Medusa.Config:getNetworks()
	lu.assertEquals(#nets, 1)
	lu.assertIsNil(nets[1].doctrine)
	MEDUSA_CONFIG = nil
end

function TestGetNetworksDoctrine:test_full_roundtrip_inline_to_resolved()
	MEDUSA_CONFIG = {
		Networks = {
			{
				name = "PVO",
				coalition = 1,
				prefix = "pvo",
				doctrine = {
					ROE = "TIGHT",
					EMCON = { LR_SAM = "MINIMIZE", MR_SAM = "MINIMIZE" },
					HARMResponse = "ACTIVE_DEFENSE",
					PkFloor = 0.15,
				},
			},
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local nets = Medusa.Config:getNetworks()
	local resolved = Medusa.Config:getDoctrine(nets[1].doctrine)
	lu.assertEquals(resolved.ROE, "TIGHT")
	lu.assertEquals(resolved.EMCON.LR_SAM, "MINIMIZE")
	lu.assertEquals(resolved.EMCON.MR_SAM, "MINIMIZE")
	lu.assertEquals(resolved.HARMResponse, "AUTO_DEFENSE")
	lu.assertAlmostEquals(resolved.PkFloor, 0.15, 0.001)
	-- Defaults still applied for unset fields
	lu.assertEquals(resolved.EngageTactics, "SHOOT_IN_DEPTH")
	lu.assertEquals(resolved.SAMAsEWR, "WHEN_NO_EWR")
	MEDUSA_CONFIG = nil
end

function TestGetNetworksDoctrine:test_invalid_enum_falls_back_to_default()
	local doctrine = Medusa.Entities.Doctrine.new({
		HARMResponse = "ACTIVE_DEFENSE",
		ROE = "BANANA",
		EngageTactics = "DISTRIBUTED",
	})
	lu.assertNotEquals(doctrine.HARMResponse, "ACTIVE_DEFENSE")
	lu.assertEquals(doctrine.HARMResponse, "AUTO_DEFENSE")
	lu.assertNotEquals(doctrine.ROE, "BANANA")
	lu.assertEquals(doctrine.ROE, "TIGHT")
	lu.assertNotEquals(doctrine.EngageTactics, "DISTRIBUTED")
	lu.assertEquals(doctrine.EngageTactics, "SHOOT_IN_DEPTH")
end

function TestGetNetworksDoctrine:test_multi_network_independent_doctrines()
	MEDUSA_CONFIG = {
		Networks = {
			{
				name = "A",
				coalition = 1,
				prefix = "a",
				doctrine = { ROE = "FREE", MANPAD = { AlertnessDecaySec = 1800, FieldRadioRangeM = 3500 } },
			},
			{
				name = "B",
				coalition = 1,
				prefix = "b",
				doctrine = { ROE = "HOLD", MANPAD = { AlertnessDecaySec = 28800, FieldRadioRangeM = 12000 } },
			},
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local nets = Medusa.Config:getNetworks()
	local dA = Medusa.Config:getDoctrine(nets[1].doctrine)
	local dB = Medusa.Config:getDoctrine(nets[2].doctrine)
	lu.assertEquals(dA.ROE, "FREE")
	lu.assertEquals(dB.ROE, "HOLD")
	lu.assertEquals(dA.MANPAD.AlertnessDecaySec, 1800)
	lu.assertEquals(dB.MANPAD.AlertnessDecaySec, 28800)
	lu.assertEquals(dA.MANPAD.FieldRadioRangeM, 3500)
	lu.assertEquals(dB.MANPAD.FieldRadioRangeM, 12000)
	MEDUSA_CONFIG = nil
end

-- == Per-kind scan rates resolved at doctrine load ==

TestDoctrineScanRates = {}

function TestDoctrineScanRates:setUp()
	self.origMemory = Medusa.Config.getTrackMemoryDurationSec
	self.origError = env.error
	self.errors = {}
	local errors = self.errors
	env.error = function(msg)
		errors[#errors + 1] = msg
	end
end

function TestDoctrineScanRates:tearDown()
	Medusa.Config.getTrackMemoryDurationSec = self.origMemory
	env.error = self.origError
end

local function withTrackMemory(sec)
	Medusa.Config.getTrackMemoryDurationSec = function()
		return sec
	end
end

function TestDoctrineScanRates:test_defaults()
	withTrackMemory(30)
	local rates = Medusa.Entities.Doctrine.new({}).ScanRates
	lu.assertEquals(rates.EWR, 10)
	lu.assertEquals(rates.SAM_SEARCH, 5)
	lu.assertEquals(rates.SAM_TRACK, 2)
end

function TestDoctrineScanRates:test_explicit_per_track_rate_applies_to_kinds_not_named()
	withTrackMemory(30)
	local rates =
		Medusa.Entities.Doctrine.new({ PerTrackScanUpdateRate = 3, ScanUpdateRateSec = { SAM_TRACK = 1 } }).ScanRates
	lu.assertEquals(rates.EWR, 3)
	lu.assertEquals(rates.SAM_SEARCH, 3)
	lu.assertEquals(rates.SAM_TRACK, 1)
end

function TestDoctrineScanRates:test_rates_are_capped_at_half_the_track_memory()
	withTrackMemory(8)
	local rates = Medusa.Entities.Doctrine.new({ SensorCleanupSec = 30 }).ScanRates
	lu.assertEquals(rates.EWR, 4)
	lu.assertEquals(rates.SAM_SEARCH, 4)
	lu.assertEquals(rates.SAM_TRACK, 2)
	lu.assertEquals(#self.errors, 2)

	withTrackMemory(0)
	rates = Medusa.Entities.Doctrine.new({}).ScanRates
	lu.assertEquals(rates.SAM_TRACK, 1)
end

function TestDoctrineScanRates:test_a_switch_that_is_not_a_boolean_is_an_error_and_takes_its_default()
	withTrackMemory(30)
	local d = Medusa.Entities.Doctrine.new({ TrainingMode = "true", CrewFactors = 0, DecoyTestShots = "no" })
	lu.assertFalse(d.TrainingMode) -- the string "true" does not switch training on
	lu.assertTrue(d.CrewFactors)
	lu.assertTrue(d.DecoyTestShots)
	lu.assertEquals(#self.errors, 3)
	lu.assertStrContains(self.errors[1] .. self.errors[2] .. self.errors[3], "TrainingMode")
	lu.assertStrContains(self.errors[1] .. self.errors[2] .. self.errors[3], "CrewFactors")
	-- real booleans pass unchanged, with no error
	local ok = Medusa.Entities.Doctrine.new({ TrainingMode = true, CrewFactors = false })
	lu.assertTrue(ok.TrainingMode)
	lu.assertFalse(ok.CrewFactors)
	lu.assertEquals(#self.errors, 3)
end

function TestDoctrineScanRates:test_cleanup_shorter_than_the_slowest_rate_is_reported()
	withTrackMemory(30)
	Medusa.Entities.Doctrine.new({ SensorCleanupSec = 5 })
	lu.assertEquals(#self.errors, 1)
	lu.assertStrContains(self.errors[1], "SensorCleanupSec")
end

function TestGetDoctrine:test_local_radar_sweeps_switch_and_an_ewr_emcon_reach_the_doctrine()
	Medusa.Config:initialize()
	lu.assertTrue(Medusa.Config:getDoctrine({}).LocalRadarSweeps)
	local d = Medusa.Config:getDoctrine({ LocalRadarSweeps = false, EMCON = { EWR = "MINIMIZE" } })
	lu.assertFalse(d.LocalRadarSweeps)
	lu.assertEquals(d.EMCON.EWR, "MINIMIZE")
end

function TestGetDoctrine:test_readiness_follows_posture_unless_set()
	Medusa.Config:initialize()
	local R = Medusa.Constants.Readiness
	lu.assertEquals(Medusa.Config:getDoctrine(nil).Readiness, R.ENGAGED)
	lu.assertEquals(Medusa.Config:getDoctrine({ Posture = "WARM_WAR" }).Readiness, R.ALERTED)
	lu.assertEquals(Medusa.Config:getDoctrine({ Posture = "COLD_WAR" }).Readiness, R.SURPRISED)
	lu.assertEquals(Medusa.Config:getDoctrine({ Posture = "HOT_WAR", Readiness = "SURPRISED" }).Readiness, R.SURPRISED)
	lu.assertEquals(Medusa.Config:getDoctrine({ Posture = "COLD_WAR", Readiness = "Sleepy" }).Readiness, R.SURPRISED)
end

function TestGetDoctrine:test_crew_factors_on_and_training_mode_off_by_default()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine(nil)
	lu.assertTrue(d.CrewFactors)
	lu.assertFalse(d.TrainingMode)
	local set = Medusa.Config:getDoctrine({ CrewFactors = false, TrainingMode = true })
	lu.assertFalse(set.CrewFactors)
	lu.assertTrue(set.TrainingMode)
end

function TestDoctrineScanRates:test_unknown_scan_rate_keys_are_reported()
	withTrackMemory(30)
	local d = Medusa.Entities.Doctrine.new({ ScanUpdateRateSec = { EWR = 8, SAM_TRAK = 1 } })
	lu.assertEquals(d.ScanRates.EWR, 8)
	lu.assertEquals(d.ScanRates.SAM_TRACK, 2) -- the misspelled key is ignored
	lu.assertEquals(#self.errors, 1)
	lu.assertStrContains(self.errors[1], "ScanUpdateRateSec.SAM_TRAK")
end

function TestDoctrineScanRates:test_the_removed_listening_station_fields_are_ignored_with_one_notice()
	withTrackMemory(30)
	local d = Medusa.Entities.Doctrine.new({ PassiveDetection = true, ESM = { MaxRangeKm = 200, Typo = 1 } })
	lu.assertNil(d.PassiveDetection)
	lu.assertNil(d.ESM)
	lu.assertEquals(#self.errors, 1)
	lu.assertStrContains(self.errors[1], "PassiveDetection")
	lu.assertStrContains(self.errors[1], "ESM")
	lu.assertStrContains(self.errors[1], "removed")
	lu.assertNotStrContains(self.errors[1], "unknown")
	Medusa.Entities.Doctrine.new({ ESM = {} })
	lu.assertEquals(#self.errors, 2)
	lu.assertStrContains(self.errors[2], "removed")
	Medusa.Entities.Doctrine.new({})
	lu.assertEquals(#self.errors, 2)
	-- a misspelled key is not pointed at a removed field
	Medusa.Entities.Doctrine.new({ esm = {} })
	lu.assertEquals(#self.errors, 3)
	lu.assertStrContains(self.errors[3], "'esm'")
	lu.assertNotStrContains(self.errors[3], "did you mean")
end

function TestDoctrineScanRates:test_fire_discipline_without_engage_air_weapons_management_is_reported()
	withTrackMemory(30)
	Medusa.Entities.Doctrine.new({ ManageEngageAirWeapons = false })
	lu.assertEquals(#self.errors, 1)
	lu.assertStrContains(self.errors[1], "DecoyFireDiscipline")
	Medusa.Entities.Doctrine.new({ ManageEngageAirWeapons = false, DecoyFireDiscipline = false })
	Medusa.Entities.Doctrine.new({})
	lu.assertEquals(#self.errors, 1)
end

function TestDoctrineScanRates:test_an_unknown_top_level_key_is_reported_by_name()
	withTrackMemory(30)
	local d = Medusa.Entities.Doctrine.new({ Readyness = "SURPRISED", ROE = "FREE", [1] = "HOLD" })
	lu.assertEquals(d.ROE, "FREE")
	lu.assertEquals(d.Readiness, Medusa.Constants.Readiness.ENGAGED) -- the misspelled field is ignored
	lu.assertEquals(#self.errors, 2)
	local all = self.errors[1] .. self.errors[2]
	lu.assertStrContains(all, "'Readyness'")
	lu.assertStrContains(all, "'1'")
end

function TestDoctrineScanRates:test_a_key_differing_only_in_case_names_the_field_it_resembles()
	withTrackMemory(30)
	Medusa.Entities.Doctrine.new({ roe = "FREE" })
	lu.assertEquals(#self.errors, 1)
	lu.assertStrContains(self.errors[1], "'roe'")
	lu.assertStrContains(self.errors[1], "'ROE'")
end

function TestDoctrineScanRates:test_known_sub_tables_aliases_and_the_doctrine_id_are_not_reported()
	withTrackMemory(30)
	local d = Medusa.Entities.Doctrine.new({
		DoctrineId = "fixed",
		MANPADAlertnessDecaySec = 600,
		MANPADFieldRadioRangeM = 2000,
		MANPAD = { AudioRangeM = Medusa.Constants.Manpad.AUDIO_RANGE_MIN_M },
		AAA = { BarrageChance = 0.5 },
		CrewSuppression = { Enabled = false },
		EMCON = { LR_SAM = "MINIMIZE" },
		AllowedAirbases = { "Kutaisi" },
		LaunchCriteria = {},
	})
	lu.assertEquals(d.DoctrineId, "fixed")
	lu.assertEquals(d.MANPAD.AlertnessDecaySec, 600)
	lu.assertEquals(#self.errors, 0)
end

function TestDoctrineScanRates:test_a_number_field_given_something_else_is_an_error_and_takes_its_default()
	withTrackMemory(30)
	local d =
		Medusa.Entities.Doctrine.new({ PkFloor = "high", FlightSize = true, GCIRangeKm = "far", HoldDownSec = "20" })
	lu.assertEquals(d.PkFloor, 0.25)
	lu.assertEquals(d.FlightSize, 1)
	lu.assertNil(d.GCIRangeKm)
	lu.assertEquals(d.HoldDownSec, 20) -- a numeric string still works and is not reported
	lu.assertEquals(#self.errors, 3)
	local all = self.errors[1] .. self.errors[2] .. self.errors[3]
	lu.assertStrContains(all, "'PkFloor' value 'high'")
	lu.assertStrContains(all, "'FlightSize' value 'true'")
	lu.assertStrContains(all, "'GCIRangeKm' value 'far'")
end

function TestDoctrineScanRates:test_a_nan_number_field_is_an_error_and_takes_its_default()
	withTrackMemory(30)
	local d = Medusa.Entities.Doctrine.new({ TargetKillRate = 0 / 0 })
	lu.assertEquals(d.TargetKillRate, 0.5)
	lu.assertEquals(#self.errors, 1)
	lu.assertStrContains(self.errors[1], "TargetKillRate")
end

function TestDoctrineScanRates:test_report_skill_follows_crew_suppression_skill_unless_set()
	withTrackMemory(30)
	local S = Medusa.Constants.CrewSkill
	lu.assertEquals(Medusa.Entities.Doctrine.new({}).CrewFactorsDefaultSkill, S.AVERAGE)
	local follows = Medusa.Entities.Doctrine.new({ CrewSuppression = { DefaultCrewSkill = "GOOD" } })
	lu.assertEquals(follows.CrewFactorsDefaultSkill, S.GOOD)
	local apart = Medusa.Entities.Doctrine.new({
		CrewFactorsDefaultSkill = "HIGH",
		CrewSuppression = { DefaultCrewSkill = "EXCELLENT" },
	})
	lu.assertEquals(apart.CrewFactorsDefaultSkill, S.HIGH)
	lu.assertEquals(apart.CrewSuppression.DefaultCrewSkill, S.EXCELLENT)
	lu.assertEquals(#self.errors, 0)
	-- a value that is not a skill is an error and follows the crew-suppression skill
	local invalid = Medusa.Entities.Doctrine.new({
		CrewFactorsDefaultSkill = "Random",
		CrewSuppression = { DefaultCrewSkill = "GOOD" },
	})
	lu.assertEquals(invalid.CrewFactorsDefaultSkill, S.GOOD)
	lu.assertEquals(#self.errors, 1)
	lu.assertStrContains(self.errors[1], "CrewFactorsDefaultSkill")
	lu.assertStrContains(self.errors[1], "CrewSuppression.DefaultCrewSkill")
end

-- == [BKE] MEDUSA_CONFIG.PointDefense ties ==

TestPointDefenseTiesConfig = {}

function TestPointDefenseTiesConfig:setUp()
	Medusa.Config.Current = nil
end

function TestPointDefenseTiesConfig:tearDown()
	MEDUSA_CONFIG = nil
	Medusa.Config.Current = nil
end

function TestPointDefenseTiesConfig:test_no_ties_by_default()
	MEDUSA_CONFIG = nil
	lu.assertEquals(Medusa.Config:getPointDefenseTies(), {})
end

function TestPointDefenseTiesConfig:test_keeps_name_pairs_and_drops_the_rest()
	MEDUSA_CONFIG = {
		PointDefense = { ["iads.pd tor"] = "iads.sa10", ["iads.pd 2"] = 5, [3] = "iads.sa11", [""] = "x" },
	}
	lu.assertEquals(Medusa.Config:getPointDefenseTies(), { ["iads.pd tor"] = "iads.sa10" })
end

function TestPointDefenseTiesConfig:test_not_a_table_gives_no_ties()
	MEDUSA_CONFIG = { PointDefense = "iads.sa10" }
	lu.assertEquals(Medusa.Config:getPointDefenseTies(), {})
end
