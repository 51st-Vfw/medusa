-- MANPAD test set-up: debug logging, metrics for the tactical display, and the MANPAD doctrine settings.
-- [BKE] Put this in a DO SCRIPT action that runs before the DO SCRIPT FILE that loads medusa-bke.lua. With BKE,
-- MANPAD teams are also cued by crew reports and by a Dog Ear in their group, and a SURPRISED network's sleeping teams
-- do not watch the sky (see docs/local-radars-and-observers.md and docs/crews-and-readiness.md).
MEDUSA_CONFIG = {
	LogLevel = "DEBUG",
	PrometheusEnabled = true,
	PrometheusExtendEnabled = true,
	Networks = {
		{
			name = "MANPADS_TEST",
			coalition = "red",
			prefix = "manpad-test",
			doctrine = {
				Name = "MANPADS Test",
				Posture = "HOT_WAR",
				MANPAD = {
					AlertnessDecaySec = 14400,
					FieldRadioRangeM = 5000,
					AudioRangeM = 6000,
				},
			},
		},
	},
}
