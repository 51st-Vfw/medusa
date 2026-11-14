-- [BKE] Medusa IADS - Black Knight Edition: every BKE setting, shown at its default.
-- Put this in a DO SCRIPT action that runs before the DO SCRIPT FILE that loads medusa-bke.lua.
-- You only need the fields you change: leaving a field out keeps its default. Every field is described in
-- docs/doctrine-fields.md and docs/configuration.md.
MEDUSA_CONFIG = {
	-- Group-name tokens. OBSERVER marks observer posts ("observer" always works too). The stock tokens are shown for
	-- completeness.
	Roles = { HQ = "hq", GCI = "gci", EWR = "ewr", AWACS = "awacs", OBSERVER = "obs" },
	Networks = {
		{
			name = "BKE_EXAMPLE",
			coalition = "red",
			prefix = "iads",
			doctrine = {
				Name = "BKE Example",
				-- Track refresh per radar kind, in seconds: early-warning/GCI radar, SAM search radar, HOT
				-- multi-target engagement radar. Each is capped at half of TrackMemorySec.
				ScanUpdateRateSec = { EWR = 10, SAM_SEARCH = 5, SAM_TRACK = 2 },
				-- Decoys: recognize gliding decoys (TALD) and keep long/medium-range SAMs from wasting missiles on
				-- them. DecoyAssessment off also turns the other three off; DecoyFireDiscipline needs
				-- ManageEngageAirWeapons.
				DecoyAssessment = true,
				ManageEngageAirWeapons = true,
				DecoyTestShots = true,
				DecoyFireDiscipline = true,
				-- Pick lost tracks back up from where they should be and how they fly, not from the DCS object.
				EvidenceReacquisition = true,
				-- Short-range search radars without missiles (Dog Ear) are dark until needed and cue their guns and
				-- MANPADs, instead of running as always-on early-warning radars ("ewr" in the group name keeps one
				-- always on), and sweep now and then when nothing else covers them.
				LocalCueingRadars = true,
				LocalRadarSweeps = true,
				-- Ground crews and observer posts ("obs" / "observer" in the group name) report what they see and
				-- hear. ObserverReports off also turns LocalInitiative off.
				ObserverReports = true,
				-- A crew that sees an aircraft itself brings its own radar up without waiting for the network.
				LocalInitiative = true,
				-- Starting readiness: SURPRISED, ALERTED or ENGAGED. It has no default of its own: leave it out to
				-- follow Posture (HOT_WAR = ENGAGED, WARM_WAR = ALERTED, COLD_WAR = SURPRISED). It rises during the
				-- mission on its own; a script can set it with Medusa.API.setReadiness("BKE_EXAMPLE", "ALERTED").
				-- Readiness = "ENGAGED",
				-- Crew skill, readiness and net load shape crew reports, how often surprised crews look, and how
				-- fast a busy network identifies tracks. Off: fixed report timings, no readiness effects.
				CrewFactors = true,
				-- The skill of units the mission gives none (spawned during the mission, or Random/Player skill):
				-- their crew-suppression resistance and, unless CrewFactorsDefaultSkill is set, their reporting
				-- skill. An Average crew reports about one time in four: set your ground crews' and observer posts'
				-- skill in the editor.
				CrewSuppression = { DefaultCrewSkill = "AVERAGE" },
				-- The reporting skill of those units alone; leave it out to follow CrewSuppression.DefaultCrewSkill.
				CrewFactorsDefaultSkill = "AVERAGE",
				-- Training: no luck in Medusa's own detection, identification and reports (typical values, no lost
				-- reports, fixed typical errors). DCS's own randomness stays.
				TrainingMode = false,
			},
		},
	},
}
