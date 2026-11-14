-- [BKE] A network that starts surprised: peacetime routine, nobody expects an attack. See
-- docs/crews-and-readiness.md#readiness.
-- Put this in a DO SCRIPT action that runs before the DO SCRIPT FILE that loads medusa-bke.lua.
--
-- While SURPRISED, crews look for aircraft less often (observer posts keep watching), make fewer and slower reports,
-- 40% of reports reach nobody who acts on them (20% for observer posts), and sleeping MANPAD teams do not watch the
-- sky. The network turns ALERTED 2-5 minutes after word first spreads (a hostile track or a hostile report), and
-- ENGAGED at its first missile launch or 30-90 s after its first loss. Skilled crews shrug surprise off faster: set
-- your ground crews' and observer posts' skill above Average. Readiness needs CrewFactors (on by default).
--
-- A mission script can change readiness at any time (DO SCRIPT actions run by triggers, after medusa-bke.lua):
--
--   Medusa.API.setReadiness("WEST", "ALERTED")  -- intelligence warns of a strike
--   Medusa.API.setReadiness("WEST", "SURPRISED") -- a ceasefire: back to routine (setting may also lower it)
--   local readiness = Medusa.API.getReadiness("WEST")
MEDUSA_CONFIG = {
	Networks = {
		{
			name = "WEST",
			coalition = "red",
			prefix = "west",
			doctrine = {
				Name = "Western district",
				-- A war footing politically (fast identification, borders do not matter) but crews caught napping.
				-- Leave Readiness out and set Posture = "COLD_WAR" to get SURPRISED with cold-war identification.
				Posture = "HOT_WAR",
				Readiness = "SURPRISED",
				CrewFactors = true,
			},
		},
	},
}
