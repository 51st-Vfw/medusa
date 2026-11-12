require("_header")
require("services.Services")

--[[
    OBSERVER POST STORE

    What this store does
    - Keeps the observer posts of one network (groups named with the observer role token that are nothing else).

    How others use it
    - EntityFactory adds posts; ObserverReportService reads them when it rebuilds its roster of observers.
--]]

Medusa.Services.ObserverPostStore = {}

function Medusa.Services.ObserverPostStore:new()
	local o = { _list = {}, _byGroupName = {} }
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.ObserverPostStore:add(post)
	if self._byGroupName[post.GroupName] then
		error(string.format("duplicate observer post: %s", post.GroupName))
	end
	self._list[#self._list + 1] = post
	self._byGroupName[post.GroupName] = post
end

function Medusa.Services.ObserverPostStore:getByGroupName(groupName)
	return self._byGroupName[groupName]
end

function Medusa.Services.ObserverPostStore:removeByGroupName(groupName)
	local post = self._byGroupName[groupName]
	if not post then
		return false
	end
	self._byGroupName[groupName] = nil
	for i = #self._list, 1, -1 do
		if self._list[i] == post then
			table.remove(self._list, i)
		end
	end
	return true
end

--- All posts; the returned list is the store's own and must not be changed.
function Medusa.Services.ObserverPostStore:getAll()
	return self._list
end

function Medusa.Services.ObserverPostStore:count()
	return #self._list
end
