require("_header")
require("entities.Entities")

--[[
    OBSERVER POST

    What this entity does
    - Holds a managed group named with the observer role token that is nothing else Medusa manages (infantry, a
      lookout post, a vehicle): its name, its unit names (to find a living member) and its last known position.
    - Also holds a listening station (named with the esm/elint token, Esm = true; EsmService takes its bearings).
      Its crew looks out like any ground crew, but only a group also named as an observer post (Watch) gets the
      trained watcher's bonuses.

    How others use it
    - EntityFactory creates it from a discovered group; ObserverReportService reads it as one of the observers whose
      crews report aircraft they see or hear.
--]]

Medusa.Entities.ObserverPost = {}

function Medusa.Entities.ObserverPost.new(data)
	if not data then
		error("data table is required")
	end
	if data.NetworkId == nil then
		error("missing required field: NetworkId")
	end
	if data.GroupName == nil then
		error("missing required field: GroupName")
	end
	return {
		ObserverPostId = data.ObserverPostId or NewULID(),
		NetworkId = data.NetworkId,
		GroupId = data.GroupId,
		GroupName = data.GroupName,
		UnitNames = data.UnitNames or {},
		Position = data.Position,
		HierarchyPath = data.HierarchyPath,
		-- Watch: named as an observer post (a trained watcher); Esm: named as a listening station.
		Watch = data.Watch ~= false,
		Esm = data.Esm == true,
	}
end
