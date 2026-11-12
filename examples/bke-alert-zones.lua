-- [BKE] Alert zones: editor flags from what the IADS radars see. See docs/alert-zones.md.
--
-- Alert zones are set on trigger zones in the Mission Editor, not in Lua. Medusa reads every trigger zone that has a
-- MedusaFlag or MedusaLosses property when it starts. Three zones for this example:
--
--   Zone "North CAP box" (circle), properties:
--     MedusaFlag    = north          flag "north" = hostile aircraft the radars track inside the zone
--     MedusaThreats = aircraft       (the default)
--     MedusaAlt     = any            (the default; low < 1000 m, high > 6000 m above ground)
--     MedusaLinger  = 30             (the default, seconds)
--     MedusaSide    = red            needed here because both coalitions run Medusa (see Networks below)
--
--   Zone "North low" (quad), properties:
--     MedusaFlag    = northlow       flag "northlow" = low-flying hostile aircraft inside the zone
--     MedusaAlt     = low
--     MedusaSide    = red
--
--   Zone "SAM belt" (circle), properties:
--     MedusaFlag    = beltweapons    flag "beltweapons" = confirmed ARMs and other weapons inside the zone
--     MedusaThreats = arms,munitions
--     MedusaLosses  = beltlost       flag "beltlost" = red air-defence sites lost inside the zone (only goes up)
--     MedusaSide    = red
--
-- Triggers that read the flags (ordinary editor triggers):
--
--   ONCE    FLAG IS MORE "north" 0           -> GROUP ACTIVATE "Red alert pair"
--   ONCE    FLAG IS MORE "north" 3           -> GROUP ACTIVATE "Red alert flight 2"
--   ONCE    FLAG IS MORE "northlow" 0        -> MESSAGE TO COALITION red "Low flyers in the north"
--   SWITCHED FLAG IS MORE "beltweapons" 0    -> MESSAGE TO COALITION red "Weapons inbound on the SAM belt"
--   ONCE    FLAG IS MORE "beltlost" 1        -> GROUP ACTIVATE "Red reserve SA-6"
--
-- The flags count only contacts the radars actually hold: a flight masked by terrain or under radar cover is not
-- counted until a radar picks it up. A zone with a property Medusa does not understand is ignored, with the reason
-- in dcs.log ("alert zone '<name>' ignored: ...").
--
-- Put the configuration below in a DO SCRIPT action that runs before the DO SCRIPT FILE that loads medusa-bke.lua.
-- Alert zones need no doctrine setting; two networks of opposite sides are shown so that MedusaSide matters.
MEDUSA_CONFIG = {
	Networks = {
		{ name = "RED_IADS", coalition = "red", prefix = "red" },
		{ name = "BLUE_IADS", coalition = "blue", prefix = "blue" },
	},
}
