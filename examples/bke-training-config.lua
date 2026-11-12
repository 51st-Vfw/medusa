-- [BKE] Training mode: practise against the network without luck deciding the outcome. See
-- docs/crews-and-readiness.md#training-mode.
-- Put this in a DO SCRIPT action that runs before the DO SCRIPT FILE that loads medusa-bke.lua.
--
-- Medusa's own random draws take their typical value: identification timers, crew report delays, MANPAD wake times
-- and hearing range, readiness delays, local radar sweeps (each radar at its own fixed point), listening-station
-- intercepts (every look catches the radar). Return-size estimates carry no noise, and every crew report is made and
-- delivered, off by its typical error in a fixed direction. DCS's own detection and missile hits, and AAA fire,
-- stay random. The debrief log starts with an ev=TRAINING_MODE line.
MEDUSA_CONFIG = {
	-- INFO (the default) writes the debrief log for the after-action review.
	LogLevel = "INFO",
	Networks = {
		{
			name = "TRAINING",
			coalition = "red",
			prefix = "iads",
			doctrine = {
				Name = "Training range",
				TrainingMode = true,
				-- The crews know an attack is coming; set SURPRISED to practise against an unaware network.
				Readiness = "ALERTED",
				ROE = "FREE",
			},
		},
	},
}
