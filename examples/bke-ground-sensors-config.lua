-- [BKE] Ground sensors: observer posts, local cueing radars and ESM listening stations.
-- Put this in a DO SCRIPT action that runs before the DO SCRIPT FILE that loads medusa-bke.lua.
-- See docs/local-radars-and-observers.md and docs/esm-listening-stations.md.
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
--   north.esm.ridge-1           listening station: one or two trucks or a command vehicle, nothing else.
--   north.esm.ridge-2           Place at least three stations 30-60 km apart, not in a line, on high ground,
--   north.elint.valley-3        with a clear view towards where the enemy flies.
--   north.esm.obs.ridge-4       a listening station whose crew is also a trained observer post
--
-- A network whose only radar is a lone Dog Ear is blind until the Dog Ear comes up: SAMAsEWR = "WHEN_NO_EWR" still
-- counts the dark Dog Ear as its radar. Add an early-warning radar, name the Dog Ear with ewr, or set SAMAsEWR =
-- "ALWAYS" (below).
MEDUSA_CONFIG = {
	-- Extra name tokens; obs/observer and esm/elint always work.
	Roles = { OBSERVER = "lookout", ESM = "df" },
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
				-- Listening stations with taller masts, listening every 15 s.
				PassiveDetection = true,
				ESM = {
					MastHeightM = 20,
					MaxRangeKm = 250,
					SidelobeRangeKm = 40,
					AewMaxRangeKm = 400,
					BearingSigmaDeg = 2,
					LookIntervalSec = 15,
				},
				-- Units with no skill in the mission file (spawned, Random, Player) report as Good crews.
				CrewSuppression = { DefaultCrewSkill = "GOOD" },
			},
		},
	},
}
