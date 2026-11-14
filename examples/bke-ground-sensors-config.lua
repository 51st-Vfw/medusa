-- [BKE] Ground sensors: observer posts and local cueing radars.
-- Put this in a DO SCRIPT action that runs before the DO SCRIPT FILE that loads medusa-bke.lua.
-- See docs/local-radars-and-observers.md.
--
-- Group names to use in the Mission Editor (prefix "north" below):
--
--   north.obs.hill-412          observer post: two or three infantry or a lookout vehicle on high ground.
--                               Set the units' skill to Good or better: an Average crew reports about one time in
--                               four, and so do spawned units and Random/Player skill.
--   north.observer.bridge       observer post ("observer" works as well as "obs")
--   north.lookout.ridge         observer post through the extra token set in Roles.OBSERVER below
--   north.dogear-1              a Dog Ear on its own: a local cueing radar, dark until needed
--   north.zsu.dogear-shilka     a Dog Ear with Shilkas: an AAA battery directed by its radar
--   north.igla.dogear           a Dog Ear with Igla teams: MANPAD teams cued by their radar
--   north.ewr.dogear-west       a Dog Ear with the ewr token: an always-on early-warning radar, as in stock Medusa
--
-- A cueing Dog Ear is not an early-warning radar: with SAMAsEWR = "WHEN_NO_EWR" (the default) a network whose only
-- radar is a lone, unnamed Dog Ear uses its long- and medium-range SAMs as early-warning radars. SAMAsEWR = "ALWAYS"
-- (below) keeps them on as early-warning radars whatever other radars the network has.
MEDUSA_CONFIG = {
	-- Extra name tokens; obs/observer always work.
	Roles = { OBSERVER = "lookout" },
	Networks = {
		{
			name = "NORTH",
			coalition = "red",
			prefix = "north",
			doctrine = {
				Name = "Northern sector",
				-- Long/medium-range SAM radars act as early-warning radars all the time.
				SAMAsEWR = "ALWAYS",
				-- Local cueing radars and their sweeps when nothing else covers them.
				LocalCueingRadars = true,
				LocalRadarSweeps = true,
				-- Crew and observer-post reports, and crews bringing their own radar up on a sighting.
				ObserverReports = true,
				LocalInitiative = true,
				-- An ambush site: short-range SAMs stay dark whatever the crews report, and a local radar whose role
				-- is set to MINIMIZE (AAA for a Dog Ear with guns) makes no periodic sweeps.
				EMCON = { SR_SAM = "MINIMIZE", AAA = "MINIMIZE" },
				-- Units with no skill in the mission file (spawned, Random, Player) report as Good crews; their
				-- suppression resistance stays at CrewSuppression.DefaultCrewSkill (Average).
				CrewFactorsDefaultSkill = "GOOD",
			},
		},
	},
}
