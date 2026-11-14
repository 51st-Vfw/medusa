-- [BKE] Turn off every Black Knight Edition behavior that has a switch, to compare with stock Medusa 1.6.0
-- or keep an existing mission's ground defenses as they were.
-- Put this in a DO SCRIPT action that runs before the DO SCRIPT FILE that loads medusa-bke.lua.
--
-- Still on, as corrections rather than options (no switch):
-- - HARM classification after 5 looks with no age wait (stock: 25 looks and 10 s), and a bounded HARM score;
-- - a confirmed ARM stays an ARM while it attacks a site; the shooter is found at any radar refresh rate;
-- - a new or re-acquired track keeps its first sighting in its history;
-- - contact evidence: return size, launch cues, crews naming what they see within 10 km;
-- - the released-store hold: a bomb dropped by a known aircraft is not confirmed as an ARM;
-- - engage-air-weapons is not turned on when a battery goes HOT (stock turned it on every time);
-- - the stock fixes (point defense for batteries spawned after start, re-linking after crew suppression, quieter
--   event handlers, spreading heavy work over frames), the debrief log and BKE's INFO lines.
-- Alert zones act only on trigger zones that carry a MedusaFlag or MedusaLosses property, so they need no switch.
-- Observer-post name tokens (obs, observer) still mark those groups; with the switches below they behave as ordinary
-- ground groups.
MEDUSA_CONFIG = {
	Networks = {
		{
			name = "STOCK_COMPARE",
			coalition = "red",
			prefix = "iads",
			doctrine = {
				Name = "Stock behaviour",
				-- One refresh rate for every radar kind, as 1.6.0 had.
				ScanUpdateRateSec = { EWR = 5, SAM_SEARCH = 5, SAM_TRACK = 5 },
				DecoyAssessment = false,
				ManageEngageAirWeapons = false,
				DecoyTestShots = false,
				DecoyFireDiscipline = false,
				EvidenceReacquisition = false,
				LocalCueingRadars = false,
				LocalRadarSweeps = false,
				ObserverReports = false,
				LocalInitiative = false,
				-- With crew factors off, readiness and net load have no effect.
				CrewFactors = false,
				TrainingMode = false,
			},
		},
	},
}
