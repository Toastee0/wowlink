-- WowLink core: snapshots your progress for your AI coach, reads the goal it wrote
-- (Inbox.lua), and tracks which steps are done. Display and record only.

local WL = {}
_G.WowLink = WL

local JOURNAL_MAX = 200
local NOTES_MAX = 50

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7WowLink|r: " .. tostring(msg))
end
WL.Print = Print

------------------------------------------------------------------------
-- API shims (Forever runs classic content on the modern client; keep both paths)
------------------------------------------------------------------------

local function QuestDone(id)
	if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
		return C_QuestLog.IsQuestFlaggedCompleted(id) and true or false
	elseif IsQuestFlaggedCompleted then
		return IsQuestFlaggedCompleted(id) and true or false
	end
	return false
end

local function ItemCount(id)
	if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id) or 0 end
	if GetItemCount then return GetItemCount(id) or 0 end
	return 0
end

local function LinkName(link)
	return link and link:match("%[(.-)%]") or nil
end

local function ItemInfo(link)
	if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(link) end
	return GetItemInfo(link)
end

-- Item level, slot and stats, so your AI can judge upgrades.
local function ItemDetail(link)
	local name, _, quality, ilvl, reqLevel, itype, sub, _, equipLoc, _, sellPrice, _, _, bindType = ItemInfo(link)
	local d = { id = tonumber(link:match("item:(%d+)")), name = name or LinkName(link), q = quality,
		ilvl = ilvl, req = reqLevel, type = itype, sub = sub,
		vendor = (sellPrice and sellPrice > 0) and sellPrice or nil, -- copper, per item
		bind = ({ [1] = "BoP", [2] = "BoE", [3] = "BoU", [4] = "Quest" })[bindType or 0] }
	if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" then
		d.slot = equipLoc:gsub("^INVTYPE_", "")
		local getStats = (C_Item and C_Item.GetItemStats) or GetItemStats
		local ok, stats = pcall(getStats, link)
		if ok and type(stats) == "table" then
			d.stats = {}
			for k, v in pairs(stats) do
				if k == "RESISTANCE0_NAME" then k = "ARMOR" end
				-- RESISTANCE1-6_NAME duplicate the named resistance stats; skip them
				if not k:find("^RESISTANCE%d_NAME$") then
					d.stats[(k:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""))] = v
				end
			end
		end
	end
	return d
end
WL.ItemDetail = ItemDetail

local function MapInfo(mapID)
	if mapID and C_Map and C_Map.GetMapInfo then return C_Map.GetMapInfo(mapID) end
end

local function QuestTitle(id)
	if C_QuestLog and C_QuestLog.GetTitleForQuestID then
		local t = C_QuestLog.GetTitleForQuestID(id)
		if t then return t end
	end
	return WL.titles and WL.titles[id] or ("quest " .. tostring(id))
end

local function ReadQuestLog()
	local out = {}
	WL.titles = WL.titles or {}
	if C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries then
		for i = 1, C_QuestLog.GetNumQuestLogEntries() do
			local info = C_QuestLog.GetInfo(i)
			if info and not info.isHeader and not info.isHidden and info.questID then
				local q = { id = info.questID, title = info.title, level = info.level,
					complete = (C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)) and true or false, obj = {} }
				local objs = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(info.questID)
				for _, o in ipairs(objs or {}) do
					q.obj[#q.obj + 1] = (o.finished and "[x] " or "[ ] ") .. (o.text or "")
				end
				WL.titles[q.id] = q.title
				out[#out + 1] = q
			end
		end
	elseif GetNumQuestLogEntries and GetQuestLogTitle then
		for i = 1, (GetNumQuestLogEntries()) do
			local title, level, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
			if title and not isHeader then
				local q = { id = questID, title = title, level = level,
					complete = (isComplete == 1 or isComplete == true), failed = (isComplete == -1), obj = {} }
				for j = 1, (GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i) or 0) do
					local text, _, finished = GetQuestLogLeaderBoard(j, i)
					q.obj[#q.obj + 1] = (finished and "[x] " or "[ ] ") .. (text or "")
				end
				if questID then WL.titles[questID] = title end
				out[#out + 1] = q
			end
		end
	end
	return out
end

local function ReadSkills()
	local out = {}
	if GetNumSkillLines and GetSkillLineInfo then
		local header
		for i = 1, GetNumSkillLines() do
			local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
			if isHeader then
				header = name
			elseif name then
				out[#out + 1] = { name = name, rank = rank, max = maxRank, cat = header }
			end
		end
	elseif GetProfessions and GetProfessionInfo then
		local p = { GetProfessions() }
		for k = 1, 6 do
			if p[k] then
				local name, _, rank, maxRank = GetProfessionInfo(p[k])
				if name then out[#out + 1] = { name = name, rank = rank, max = maxRank, cat = "Professions" } end
			end
		end
	end
	return out
end

local function SkillRank(name)
	name = name:lower()
	for _, s in ipairs(ReadSkills()) do
		if s.name and s.name:lower() == name then return s.rank or 0 end
	end
	return 0
end

-- Container IDs differ by client: classic bank = -1 plus bags 5-11; modern clients name them
-- in Enum.BagIndex (bank tabs, reagent bag). Collect whatever this client defines.
local function BagIDs(which)
	local ids, seen = {}, {}
	local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
	local E = Enum and Enum.BagIndex
	if which == "bags" then
		for b = 0, 4 do add(b) end
		if E then add(E.ReagentBag) end
	else
		add(E and E.Bank or -1)
		local tabs = false
		if E then
			for k = 1, 8 do
				if E["CharacterBankTab_" .. k] then add(E["CharacterBankTab_" .. k]); tabs = true end
				if E["BankBag_" .. k] then add(E["BankBag_" .. k]); tabs = true end
			end
		end
		if not tabs then
			local first = (NUM_BAG_SLOTS or 4) + 1
			for b = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do add(b) end
		end
	end
	return ids
end

-- Auction House prices from Auctionator (optional addon), via its public API.
-- Returns copper and the age of that price in days, or nil.
local function AHPrice(link, id)
	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	if not api then return nil end
	local price
	if link and api.GetAuctionPriceByItemLink then
		local ok, v = pcall(api.GetAuctionPriceByItemLink, "WowLink", link)
		if ok then price = v end
	end
	if not price and id and api.GetAuctionPriceByItemID then
		local ok, v = pcall(api.GetAuctionPriceByItemID, "WowLink", id)
		if ok then price = v end
	end
	if type(price) ~= "number" or price <= 0 then return nil end
	local age
	if link and api.GetAuctionAgeByItemLink then
		local ok, v = pcall(api.GetAuctionAgeByItemLink, "WowLink", link)
		if ok and type(v) == "number" then age = v end
	end
	if age == nil and id and api.GetAuctionAgeByItemID then
		local ok, v = pcall(api.GetAuctionAgeByItemID, "WowLink", id)
		if ok and type(v) == "number" then age = v end
	end
	return price, age
end
WL.AHPrice = AHPrice

local function ReadContainers(bagIDs)
	local counts, names, order, bound = {}, {}, {}, {}
	local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
	if not numSlots then return {} end
	for _, bag in ipairs(bagIDs) do
		local okN, n = pcall(numSlots, bag)
		for slot = 1, (okN and n or 0) do
			local id, count, link
			if C_Container and C_Container.GetContainerItemInfo then
				local info = C_Container.GetContainerItemInfo(bag, slot)
				if info then id, count, link = info.itemID, info.stackCount, info.hyperlink end
			elseif GetContainerItemInfo then
				local _, c, _, _, _, _, l, _, _, iid = GetContainerItemInfo(bag, slot)
				id, count, link = iid, c, l
			end
			if id then
				if not counts[id] then order[#order + 1] = id end
				-- soulbound or still tradeable? (decides Auction House vs. vendor)
				if C_Item and C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot then
					local okB, b = pcall(C_Item.IsBound, ItemLocation:CreateFromBagAndSlot(bag, slot))
					if okB and b ~= nil then
						bound[id] = bound[id] or {}
						bound[id][b and "yes" or "no"] = true
					end
				end
				counts[id] = (counts[id] or 0) + (count or 1)
				names[id] = names[id] or link
			end
		end
	end
	local out = {}
	for _, id in ipairs(order) do
		local d = names[id] and ItemDetail(names[id]) or { id = id }
		d.n = counts[id]
		if bound[id] then d.bound = bound[id].yes and (bound[id].no and "some" or true) or false end
		if d.bound ~= true then d.ah, d.ahAge = AHPrice(names[id], id) end -- only matters if it can be sold
		if not d.slot then d.stats, d.req, d.sub = nil, nil, nil end -- keep non-gear entries small
		out[#out + 1] = d
	end
	return out
end

local function ReadBags() return ReadContainers(BagIDs("bags")) end

-- The bank can only be read while it's open, so keep the last copy we saw.
-- Flight paths: like the bank, the game only shows them while a flight master's map is open.
local function ContinentName()
	local CONT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
	local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local last
	for _ = 1, 8 do
		local mi = id and MapInfo(id)
		if not mi then break end
		last = mi.name
		if mi.mapType == CONT then return mi.name end
		id = mi.parentMapID
	end
	return last or GetZoneText() or "?"
end

local function ReadTaxi()
	local nodes = {}
	if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID then
		local ok, list = pcall(C_TaxiMap.GetAllTaxiNodes, GetTaxiMapID())
		if ok and type(list) == "table" then
			local S = Enum and Enum.FlightPathState
			for _, n in ipairs(list) do
				if n.name then
					local pos = n.position
					nodes[#nodes + 1] = { name = n.name, known = not (S and n.state == S.Unreachable),
						x = pos and pos.x, y = pos and pos.y }
				end
			end
		end
	end
	if #nodes == 0 and NumTaxiNodes and TaxiNodeName then
		for i = 1, NumTaxiNodes() do
			local t = TaxiNodeGetType and TaxiNodeGetType(i)
			local x, y
			if TaxiNodePosition then x, y = TaxiNodePosition(i) end
			nodes[#nodes + 1] = { name = TaxiNodeName(i), known = (t == "CURRENT" or t == "REACHABLE" or t == nil), x = x, y = y }
		end
	end
	return nodes
end

function WL:SaveFlightPaths()
	if not self.char then return end
	local ok, nodes = pcall(ReadTaxi)
	if not ok or #nodes == 0 then return end
	local cont = ContinentName()
	self.char.flight = self.char.flight or {}
	local old = self.char.flight[cont]
	local had = {}
	for _, n in ipairs(old and old.known or {}) do had[n] = true end
	local known, unknown = {}, {}
	for _, n in ipairs(nodes) do
		if n.known then
			known[#known + 1] = n.name
			if old and not had[n.name] then self:Log("Learned flight path: " .. n.name) end
		else
			unknown[#unknown + 1] = n.name
		end
	end
	table.sort(known); table.sort(unknown)
	-- where each flight master is (on the flight map's own map), for automatic waypoints
	local mapID = GetTaxiMapID and GetTaxiMapID()
	local pos = {}
	if mapID then
		for _, n in ipairs(nodes) do
			if n.x and n.y and n.x > 0 and n.y > 0 then
				pos[n.name] = { map = mapID, x = math.floor(n.x * 1000 + 0.5) / 10, y = math.floor(n.y * 1000 + 0.5) / 10 }
			end
		end
	end
	self.char.flight[cont] = { t = time(), known = known, unknown = unknown, pos = pos }
	-- new positions may give the current step a waypoint it didn't have
	if not (self.ttUID or self.mapPin) then self.lastWaypoint = nil end
	self:Refresh(true)
end

-- Flight maps can use their own map ID (Forever's Eastern Kingdoms flight map is 1463), which the
-- world map never shows. Convert through world coordinates to the zone map (or at least the
-- continent) so pins appear on the world map. x, y are 0-1; returns map, x, y (0-1) or nil.
local function ToZoneMap(map, x, y)
	if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
	local ok, inst, world = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
	if not (ok and inst and world) then return nil end
	local ok2, cmap, cpos = pcall(C_Map.GetMapPosFromWorldPos, inst, world)
	if not (ok2 and cmap and cpos) then return nil end
	if C_Map.GetMapInfoAtPosition then
		local ok3, zi = pcall(C_Map.GetMapInfoAtPosition, cmap, cpos.x, cpos.y)
		if ok3 and zi and zi.mapID and zi.mapID ~= cmap then
			local ok4, _, zpos = pcall(C_Map.GetMapPosFromWorldPos, inst, world, zi.mapID)
			if ok4 and zpos and zpos.x >= 0 and zpos.x <= 1 and zpos.y >= 0 and zpos.y <= 1 then
				return zi.mapID, zpos.x, zpos.y
			end
		end
	end
	return cmap, cpos.x, cpos.y
end
WL.ToZoneMap = ToZoneMap

-- A step's waypoint: its own, or for "learn the X flight path" steps, that flight master's
-- position as last seen on a flight map (converted to its zone map).
function WL:StepWaypoint(step)
	if not step then return nil end
	if step.waypoint then return step.waypoint end
	local want = step.check and step.check.flight
	if not want then return nil end
	want = want:lower()
	for _, cont in pairs(self.char and self.char.flight or {}) do
		for name, p in pairs(cont.pos or {}) do
			if name:lower():find(want, 1, true) then
				local m, x, y = ToZoneMap(p.map, p.x / 100, p.y / 100)
				if m then
					return { map = m, x = math.floor(x * 1000 + 0.5) / 10, y = math.floor(y * 1000 + 0.5) / 10,
						label = name .. " (flight master)" }
				end
				return { map = p.map, x = p.x, y = p.y, label = name .. " (flight master)" }
			end
		end
	end
end

function WL:KnowsFlight(name)
	name = name:lower()
	for _, cont in pairs(self.char and self.char.flight or {}) do
		for _, n in ipairs(cont.known or {}) do
			if n:lower():find(name, 1, true) then return true end
		end
	end
	return false
end

function WL:SaveBank()
	if not (self.char and self.bankOpen) then return end
	local ok, items = pcall(ReadContainers, BagIDs("bank"))
	if ok and items then self.char.bank = { t = time(), items = items } end
end

-- Recipes in the open profession window, with reagents, so the AI can plan skill-ups.
-- Classic clients use the GetTradeSkill* API; modern clients use C_TradeSkillUI.
local DIFF = { optimal = "orange", medium = "yellow", easy = "green", trivial = "gray" }
local DIFF_ENUM = { [0] = "orange", [1] = "yellow", [2] = "green", [3] = "gray" }

local function ItemIDFromLink(link)
	return link and tonumber(link:match("item:(%d+)")) or nil
end

local function ReadRecipesClassic()
	if not (GetNumTradeSkills and GetTradeSkillInfo and GetTradeSkillLine) then return nil end
	local prof, rank, max = GetTradeSkillLine()
	if not prof or prof == "" or prof == "UNKNOWN" then return nil end
	local list = {}
	for i = 1, GetNumTradeSkills() or 0 do
		local name, kind, avail = GetTradeSkillInfo(i)
		if name and kind ~= "header" and kind ~= "subheader" then
			local r = { name = name, diff = DIFF[kind] or kind, n = avail or 0, reagents = {} }
			if GetTradeSkillItemLink then r.id = ItemIDFromLink(GetTradeSkillItemLink(i)) end
			for j = 1, (GetTradeSkillNumReagents and GetTradeSkillNumReagents(i)) or 0 do
				local rn, _, count, have = GetTradeSkillReagentInfo(i, j)
				local rid = GetTradeSkillReagentItemLink and ItemIDFromLink(GetTradeSkillReagentItemLink(i, j))
				r.reagents[#r.reagents + 1] = { name = rn, id = rid, count = count, have = have }
			end
			list[#list + 1] = r
		end
	end
	return prof, rank, max, list
end

local function ReadRecipesModern()
	local T = C_TradeSkillUI
	if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return nil end
	local prof, rank, max
	if T.GetBaseProfessionInfo then
		local p = T.GetBaseProfessionInfo()
		if p then prof, rank, max = p.professionName, p.skillLevel, p.maxSkillLevel end
	end
	if not prof or prof == "" then return nil end
	local list = {}
	for _, rid in ipairs(T.GetAllRecipeIDs() or {}) do
		local info = T.GetRecipeInfo(rid)
		if info and info.learned then
			local r = { name = info.name, diff = DIFF_ENUM[info.relativeDifficulty] or info.relativeDifficulty,
				n = info.numAvailable or 0, reagents = {} }
			local sch = T.GetRecipeSchematic and T.GetRecipeSchematic(rid, false)
			if sch then
				r.id = sch.outputItemID
				for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
					local rg = slot.reagents and slot.reagents[1]
					if rg and rg.itemID then
						local nm = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(rg.itemID))
							or (GetItemInfo and GetItemInfo(rg.itemID))
						r.reagents[#r.reagents + 1] = { name = nm, id = rg.itemID, count = slot.quantityRequired,
							have = ItemCount(rg.itemID) }
					end
				end
			end
			list[#list + 1] = r
		end
	end
	return prof, rank, max, list
end

function WL:SaveRecipes()
	if not self.char then return end
	local ok, prof, rank, max, list = pcall(ReadRecipesClassic)
	if not (ok and prof) then ok, prof, rank, max, list = pcall(ReadRecipesModern) end
	if not (ok and prof and list and #list > 0) then return end
	self.char.recipes = self.char.recipes or {}
	local old = self.char.recipes[prof]
	self.char.recipes[prof] = { t = time(), rank = rank, max = max, list = list }
	if not old then Print("Recorded " .. #list .. " " .. prof .. " recipes for your AI.") end
end

-- Talents (classic-style trees): tab name, points spent, and every talent with a point in it.
local function ReadTalents()
	if not (GetNumTalentTabs and GetNumTalents and GetTalentInfo) then return nil end
	local out = {}
	for tab = 1, GetNumTalentTabs() or 0 do
		local tname
		if GetTalentTabInfo then
			for _, v in ipairs({ GetTalentTabInfo(tab) }) do
				if type(v) == "string" and not v:find("[/\]") then tname = v; break end -- skip ids and icon paths
			end
		end
		local t = { name = tname or ("Tree " .. tab), spent = 0, list = {} }
		for i = 1, GetNumTalents(tab) or 0 do
			local name, _, tier, col, rank, max = GetTalentInfo(tab, i)
			if name and (rank or 0) > 0 then
				t.spent = t.spent + rank
				t.list[#t.list + 1] = { name = name, rank = rank, max = max, tier = tier, col = col }
			end
		end
		out[#out + 1] = t
	end
	return #out > 0 and out or nil
end

-- Modern clients (and WoW Forever) keep talents in the trait system, even when the window looks classic.
-- Nodes are split into the class's specialization trees by horizontal position (trees sit side by side).
local function SpellName(id)
	if not id then return nil end
	if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
	if GetSpellInfo then return (GetSpellInfo(id)) end
end

local function ReadTalentsTraits()
	local CT, T = C_ClassTalents, C_Traits
	if not (CT and CT.GetActiveConfigID and T and T.GetConfigInfo and T.GetTreeNodes and T.GetNodeInfo) then return nil end
	local config = CT.GetActiveConfigID()
	local ci = config and T.GetConfigInfo(config)
	if not (ci and ci.treeIDs and ci.treeIDs[1]) then return nil end
	local nodes, minX, maxX = {}, math.huge, -math.huge
	for _, tree in ipairs(ci.treeIDs) do
		for _, nodeID in ipairs(T.GetTreeNodes(tree) or {}) do
			local n = T.GetNodeInfo(config, nodeID)
			if n and n.ID and n.ID ~= 0 and (n.isVisible ~= false) then
				local x = n.posX or 0
				if x < minX then minX = x end
				if x > maxX then maxX = x end
				local rank = n.ranksPurchased or n.currentRank or 0
				do
					local entry = (n.activeEntry and n.activeEntry.entryID) or (n.entryIDs and n.entryIDs[1])
					local name
					if entry and T.GetEntryInfo and T.GetDefinitionInfo then
						local e = T.GetEntryInfo(config, entry)
						local d = e and e.definitionID and T.GetDefinitionInfo(e.definitionID)
						name = d and (d.overrideName or SpellName(d.spellID))
					end
					nodes[#nodes + 1] = { name = name or ("node " .. nodeID), rank = rank, max = n.maxRanks, x = x, y = n.posY,
						sub = n.subTreeID }
				end
			end
		end
	end
	-- tree names: the class's specializations in order (Arms, Fury, Protection for a Warrior)
	local specs = {}
	local SI = C_SpecializationInfo
	local count = (GetNumSpecializations and GetNumSpecializations()) or 0
	local getSpec = (SI and SI.GetSpecializationInfo) or GetSpecializationInfo
	for i = 1, getSpec and count or 0 do
		local ok, _, name = pcall(getSpec, i)
		if ok and type(name) == "string" then specs[#specs + 1] = name end
	end
	local nTrees = (#specs >= 2 and #specs) or 3 -- classic-style classes have three trees
	local out = {}
	for i = 1, nTrees do out[i] = { name = specs[i] or ("Tree " .. i .. " (left to right)"), spent = 0, list = {} } end
	local width = (maxX > minX) and (maxX - minX) or 1
	table.sort(nodes, function(a, b) if a.y ~= b.y then return (a.y or 0) < (b.y or 0) end return a.x < b.x end)
	-- row number (1 = top) from distinct vertical positions
	local ys, rowOf = {}, {}
	for _, n in ipairs(nodes) do if n.y and not rowOf[n.y] then rowOf[n.y] = true; ys[#ys + 1] = n.y end end
	table.sort(ys)
	for i, y in ipairs(ys) do rowOf[y] = i end
	for _, n in ipairs(nodes) do
		local i = math.min(nTrees, math.floor((n.x - minX) / width * nTrees) + 1)
		local t = out[i]
		local row = n.y and rowOf[n.y]
		if n.rank > 0 then
			t.spent = t.spent + n.rank
			t.list[#t.list + 1] = { name = n.name, rank = n.rank, max = n.max, row = row }
		else
			t.open = t.open or {}
			t.open[#t.open + 1] = { name = n.name, max = n.max, row = row }
		end
	end
	return out
end

-- When ReadTalents finds nothing: record which talent functions this client has, so support can be added.
local function ProbeTalentAPI()
	local out = { globals = {}, namespaces = {} }
	for _, n in ipairs({ "GetNumTalentTabs", "GetTalentTabInfo", "GetNumTalents", "GetTalentInfo", "GetActiveTalentGroup",
		"GetNumTalentGroups", "UnitCharacterPoints", "GetUnspentTalentPoints", "GetTalentInfoByID", "GetTalentTierInfo" }) do
		if _G[n] ~= nil then out.globals[#out.globals + 1] = n .. ":" .. type(_G[n]) end
	end
	if GetNumTalentTabs then out.numTabs = GetNumTalentTabs() end
	for k, v in pairs(_G) do
		if type(k) == "string" and type(v) == "table" and k:match("^C_") and (k:find("Talent") or k:find("Spec") or k:find("Trait")) then
			local fns = {}
			for fk, fv in pairs(v) do if type(fv) == "function" then fns[#fns + 1] = fk end end
			table.sort(fns)
			out.namespaces[k] = table.concat(fns, ",")
		end
	end
	return out
end

-- Guild roster, for planning group runs: who's in the guild, level, class, rank, zone, last seen.
-- Kept in SavedVariables for the player's own agent; never added to the [copy] report.
local function RequestGuildRoster()
	if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster)
	elseif GuildRoster then pcall(GuildRoster) end
end

function WL:SaveGuild()
	if not (self.char and IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo) then return end
	local total = GetNumGuildMembers() or 0
	if total == 0 then return end
	local members = {}
	for i = 1, total do
		local name, rank, _, level, class, zone, note, _, online = GetGuildRosterInfo(i)
		if name then
			local m = { name = name:gsub("%-$", ""), rank = rank, level = level, class = class, zone = zone,
				online = online and true or false }
			if note and note ~= "" then m.note = note end
			if not online and GetGuildRosterLastOnline then
				local y, mo, d, h = GetGuildRosterLastOnline(i)
				if y then m.lastDays = (y or 0) * 365 + (mo or 0) * 30 + (d or 0) + ((h or 0) >= 12 and 1 or 0) end
			end
			members[#members + 1] = m
		end
	end
	self.char.guild = { t = time(), name = GetGuildInfo and GetGuildInfo("player") or nil, members = members }
end

local SLOT_NAMES = { "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrist", "Hands",
	"Finger1", "Finger2", "Trinket1", "Trinket2", "Back", "MainHand", "OffHand", "Ranged", "Tabard" }

local function ReadEquipment()
	local out = {}
	for slot = 1, 19 do
		local link = GetInventoryItemLink("player", slot)
		if link then
			local d = ItemDetail(link)
			d.equipSlot = SLOT_NAMES[slot]
			out[#out + 1] = d
		end
	end
	return out
end

local function ReadCompleted()
	local ids = {}
	if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
		ids = C_QuestLog.GetAllCompletedQuestIDs() or {}
	elseif GetQuestsCompleted then
		for id in pairs(GetQuestsCompleted() or {}) do ids[#ids + 1] = id end
	end
	table.sort(ids)
	return ids
end

local function PlayerMap()
	if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
	local mapID = C_Map.GetBestMapForUnit("player")
	local x, y
	if mapID and C_Map.GetPlayerMapPosition then
		local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
		if ok and pos then x, y = pos:GetXY() end
	end
	return mapID, x, y
end

local function QuestIDsInLog()
	local set = {}
	for _, q in ipairs(ReadQuestLog()) do if q.id then set[q.id] = true end end
	return set
end

------------------------------------------------------------------------
-- Snapshot (written to SavedVariables on /reload and logout)
------------------------------------------------------------------------

function WL:Snapshot()
	if not self.char then return end
	local s = {}
	s.t = time()
	s.name = UnitName("player")
	s.realm = GetRealmName()
	s.level = UnitLevel("player")
	s.class = UnitClass("player")
	s.race = UnitRace("player")
	s.sex = ({ "unknown", "male", "female" })[UnitSex("player") or 1]
	s.xp, s.xpMax = UnitXP("player"), UnitXPMax("player")
	s.rested = GetXPExhaustion and GetXPExhaustion() or 0
	s.money = GetMoney()
	s.zone, s.subzone = GetZoneText(), GetSubZoneText()
	s.hearth = GetBindLocation and GetBindLocation() or nil
	if UnitCharacterPoints then s.talentPoints = UnitCharacterPoints("player") end
	local mapID, x, y = PlayerMap()
	if mapID then
		s.mapID = mapID
		local mi = MapInfo(mapID)
		s.mapName = mi and mi.name
		local parent = mi and mi.parentMapID and MapInfo(mi.parentMapID)
		s.parentMap = parent and parent.name
		if x then s.x, s.y = math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10 end
	end
	s.dead = UnitIsDeadOrGhost("player") and true or false
	s.inGroup = IsInGroup and IsInGroup() or false
	local function safe(fn) local ok, v = pcall(fn); if ok then return v end; return nil end
	s.quests = safe(ReadQuestLog)
	s.skills = safe(ReadSkills)
	s.equipment = safe(ReadEquipment)
	s.talents = safe(ReadTalents) or safe(ReadTalentsTraits)
	if not s.talents then s.talentAPI = safe(ProbeTalentAPI) end
	pcall(self.SaveGuild, self)
	s.bags = safe(ReadBags)
	s.completedQuests = safe(ReadCompleted)
	self.char.snapshot = s
end

------------------------------------------------------------------------
-- Journal and notes
------------------------------------------------------------------------

function WL:Log(text)
	local c = self.char
	if not c then return end
	c.journal = c.journal or {}
	table.insert(c.journal, { t = time(), lvl = UnitLevel("player"), zone = GetZoneText(), e = text })
	while #c.journal > JOURNAL_MAX do table.remove(c.journal, 1) end
end

local LOOT_MAX = 150

function WL:RecordLoot(msg)
	-- enUS self-loot lines: "You receive loot: ...", "You receive item: ...", "You create: ..."
	if type(msg) ~= "string" or not msg:find("^You ") then return end
	local link = msg:match("|c%x+|Hitem:.-|h%[.-%]|h|r") or msg:match("|Hitem:.-|h%[.-%]|h")
	if not link then return end
	local d = ItemDetail(link)
	d.n = tonumber(msg:match("|rx(%d+)") or msg:match("x(%d+)%.?$")) or 1
	d.t = time()
	d.zone = GetZoneText()
	d.ah, d.ahAge = AHPrice(link, d.id)
	local c = self.char
	c.loot = c.loot or {}
	table.insert(c.loot, d)
	while #c.loot > LOOT_MAX do table.remove(c.loot, 1) end
	if d.slot and (d.q or 0) >= 2 then self:Log("Looted " .. (d.name or "?") .. " (ilvl " .. tostring(d.ilvl) .. ")") end
end

function WL:ApplyLogging()
	-- Blizzard's own /chatlog and /combatlog: the game streams these to Logs\ itself.
	if LoggingChat then pcall(LoggingChat, WowLinkDB.chatlog ~= false) end
	if LoggingCombat then pcall(LoggingCombat, WowLinkDB.combatlog ~= false) end
end

function WL:AddNote(text)
	local c = self.char
	c.notes = c.notes or {}
	table.insert(c.notes, { t = time(), text = text })
	while #c.notes > NOTES_MAX do table.remove(c.notes, 1) end
	Print("Note saved for your AI (sends on next /wl sync).")
end

------------------------------------------------------------------------
-- Goal
------------------------------------------------------------------------

-- Find this character's entry in a table keyed "Name-Realm" or "Name".
function WL:MyEntry(t)
	if type(t) ~= "table" or not self.key then return nil end
	if t[self.key] then return t[self.key] end
	local lkey, lname = self.key:lower(), (UnitName("player") or ""):lower()
	for k, v in pairs(t) do
		if type(k) == "string" then
			local lk = k:lower()
			if lk == lkey or lk == lname or lk:match("^[^-]+") == lname then return v end
		end
	end
end

-- Two sources: Inbox.lua (written by tools/wl.py) and goals pasted in game (/wl paste).
-- Whichever was set most recently wins.
function WL:Goal()
	local g = self:MyEntry(_G.WowLink_Inbox)
	if type(g) ~= "table" or type(g.steps) ~= "table" then g = nil end
	local imp = self.char and self.char.imported
	if type(imp) == "table" and type(imp.steps) == "table" and (not g or (imp.updated or 0) >= (g.updated or 0)) then
		return imp
	end
	return g
end

-- c = { level, quest, questInLog, item, count, money, zone, skill, rank, flight }; all given must hold.
function WL:CheckMet(c)
	if type(c) ~= "table" then return false end
	if c.level and UnitLevel("player") < c.level then return false end
	if c.quest and not QuestDone(c.quest) then return false end
	if c.questInLog and not (self.inLog[c.questInLog] or QuestDone(c.questInLog)) then return false end
	if c.item and ItemCount(c.item) < (c.count or 1) then return false end
	if c.money and GetMoney() < c.money then return false end
	if c.skill and SkillRank(c.skill) < (c.rank or 1) then return false end
	if c.flight and not self:KnowsFlight(c.flight) then return false end
	if c.zone then
		if type(c.zone) == "number" then
			local id, hit = (PlayerMap()), false
			for _ = 1, 6 do
				if not id then break end
				if id == c.zone then hit = true; break end
				local mi = MapInfo(id)
				id = mi and mi.parentMapID
			end
			if not hit then return false end
		else
			local z = c.zone:lower()
			local names = { GetZoneText(), GetSubZoneText(), GetMinimapZoneText and GetMinimapZoneText() or "" }
			local hit = false
			for _, n in ipairs(names) do if n and n:lower() == z then hit = true end end
			if not hit then return false end
		end
	end
	return true
end

function WL:SyncGoalState()
	local g = self:Goal()
	self.goal = g
	if not g then return end
	local st = self.char.goalState
	if not st or st.id ~= g.id then
		self.char.goalState = { id = g.id, title = g.title, done = {}, received = time() }
		self:Log("New goal received: " .. tostring(g.title))
		Print("New goal: |cffffd100" .. tostring(g.title) .. "|r")
		if PlaySound and SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN then pcall(PlaySound, SOUNDKIT.IG_QUEST_LIST_OPEN) end
	end
	self.char.goalState.title = g.title
end

function WL:Evaluate()
	local g = self.goal
	if not g then self.current = nil; return end
	local st = self.char.goalState
	self.inLog = QuestIDsInLog()
	for i, s in ipairs(g.steps) do
		-- done[i]: nil = open (auto allowed), table = done, false = unticked by player (auto off)
		if st.done[i] == nil and s.check and self:CheckMet(s.check) then
			st.done[i] = { how = "auto", t = time() }
			self:Log(("Step %d done: %s"):format(i, s.text or ""))
			Print("|cff40ff40Step done:|r " .. (s.text or ""))
		end
	end
	local cur
	for i = 1, #g.steps do
		if not st.done[i] then cur = i; break end
	end
	self.current = cur
	if cur then
		st.completed = nil
	elseif not st.completed then
		st.completed = time()
		self:Log("Goal complete: " .. tostring(g.title))
		Print("|cffffd100Goal complete:|r " .. tostring(g.title) .. ". Tell your AI, then /wl sync for the next one.")
		if PlaySound and SOUNDKIT and SOUNDKIT.UI_QUEST_ROLLING_FORWARD_01 then pcall(PlaySound, SOUNDKIT.UI_QUEST_ROLLING_FORWARD_01) end
	end
	-- When the current step changes, point at its waypoint, or take down the old one
	-- so the arrow never leads to a finished step.
	local wpKey = (cur and (tostring(g.id) .. ":" .. cur)) or "none"
	if wpKey ~= self.lastWaypoint then
		self.lastWaypoint = wpKey
		if cur and WowLinkDB.autoWaypoint ~= false and self:StepWaypoint(g.steps[cur]) then
			self:SetWaypoint(g.steps[cur])
		else
			self:ClearWaypoint()
		end
	end
end

function WL:ToggleStep(i)
	local g, st = self.goal, self.char and self.char.goalState
	if not (g and st and g.steps[i]) then return end
	if st.done[i] then
		st.done[i] = false
		self:Log(("Step %d unticked by player: %s"):format(i, g.steps[i].text or ""))
	else
		st.done[i] = { how = "manual", t = time() }
		self:Log(("Step %d ticked by player: %s"):format(i, g.steps[i].text or ""))
	end
	self:Refresh(true)
end

-- TomTom (optional addon): a GPS-style arrow. Used when it's loaded, unless /wl tomtom turns it off.
function WL:UseTomTom()
	return TomTom and TomTom.AddWaypoint and WowLinkDB.tomtom ~= false
end

-- Remove only the waypoints WowLink placed; never touch the player's own.
function WL:ClearWaypoint()
	if self.ttUID and TomTom and TomTom.RemoveWaypoint then pcall(TomTom.RemoveWaypoint, TomTom, self.ttUID) end
	self.ttUID = nil
	if self.mapPin and C_Map and C_Map.ClearUserWaypoint then
		local cur = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
		local p = self.mapPin
		if not cur or (cur.uiMapID == p.map and cur.position and math.abs(cur.position.x - p.x) < 1e-4
			and math.abs(cur.position.y - p.y) < 1e-4) then
			pcall(C_Map.ClearUserWaypoint)
		end
	end
	self.mapPin = nil
end

function WL:SetWaypoint(step)
	local w = self:StepWaypoint(step)
	if not w then Print("That step has no waypoint."); return end
	self:ClearWaypoint()
	local x, y = w.x / 100, w.y / 100
	local label = w.label or step.text or "WowLink"
	local how
	if self:UseTomTom() then
		local ok, uid = pcall(TomTom.AddWaypoint, TomTom, w.map, x, y, { title = label, from = "WowLink",
			persistent = false, minimap = true, world = true, crazy = true, silent = true })
		if ok and uid then self.ttUID = uid; how = "TomTom arrow" end
	end
	if not how and C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
		local ok = pcall(function()
			if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(w.map) then error("no pins here") end
			C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(w.map, x, y))
			if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
		end)
		if ok then self.mapPin = { map = w.map, x = x, y = y }; how = "map pin" end
	end
	local mi = MapInfo(w.map)
	Print(("Waypoint: %s (%.1f, %.1f in %s)%s"):format(label, w.x, w.y, mi and mi.name or ("map " .. w.map),
		how and (" - " .. how) or ""))
end

------------------------------------------------------------------------
-- Refresh / sync
------------------------------------------------------------------------

function WL:Refresh(now)
	if not self.char then return end
	if now then
		self.pending = false
		self:Evaluate()
		if self.Render then self:Render() end
		return
	end
	if self.pending then return end
	self.pending = true
	C_Timer.After(0.4, function() if WL.pending then WL:Refresh(true) end end)
end

function WL:Sync()
	if InCombatLockdown() then Print("Can't sync in combat."); return end
	self:Snapshot()
	ReloadUI()
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local ev = CreateFrame("Frame")
local function Reg(e) pcall(ev.RegisterEvent, ev, e) end
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN",
	"QUEST_ACCEPTED", "PLAYER_LEVEL_UP", "BAG_UPDATE_DELAYED", "PLAYER_MONEY", "ZONE_CHANGED_NEW_AREA",
	"ZONE_CHANGED", "SKILL_LINES_CHANGED", "PLAYER_DEAD", "CHAT_MSG_LOOT", "BANKFRAME_OPENED",
	"BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED", "TAXIMAP_OPENED", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE",
	"TRADE_SKILL_LIST_UPDATE", "GUILD_ROSTER_UPDATE" }) do Reg(e) end

ev:SetScript("OnEvent", function(_, event, a1, a2)
	if event == "ADDON_LOADED" then
		if a1 ~= "WowLink" then return end
		WowLinkDB = WowLinkDB or {}
		WowLinkDB.version = 1
		WowLinkDB.chars = WowLinkDB.chars or {}
		WowLinkDB.ui = WowLinkDB.ui or {}
		return
	end
	if event == "PLAYER_LOGIN" then
		-- Forever returns no realm name; fall back to the bare character name.
		local name = UnitName("player")
		local realm = GetNormalizedRealmName and GetNormalizedRealmName()
		if not realm or realm == "" then realm = ((GetRealmName and GetRealmName()) or ""):gsub("%s", "") end
		WL.key = (realm ~= "" and (name .. "-" .. realm)) or name
		for _, old in ipairs({ name .. "-", name }) do -- migrate keys from earlier versions
			if old ~= WL.key and WowLinkDB.chars[old] and not WowLinkDB.chars[WL.key] then
				WowLinkDB.chars[WL.key], WowLinkDB.chars[old] = WowLinkDB.chars[old], nil
			end
		end
		WowLinkDB.chars[WL.key] = WowLinkDB.chars[WL.key] or {}
		WL.char = WL.char or WowLinkDB.chars[WL.key]
		WL.char.notes = WL.char.notes or {}
		WL.char.journal = WL.char.journal or {}
		WL.lastZone = GetZoneText()
		ReadQuestLog() -- fill title cache
		WL:SyncGoalState()
		WL:ApplyLogging()
		RequestGuildRoster()
		if WL.InitUI then WL:InitUI() end
		if not WL.goal then
			Print("No goal yet for " .. WL.key .. ". Type |cffffd100/wl copy|r to ask your AI for one.")
		end
		WL:Refresh(true)
		return
	end
	if not WL.char then return end
	if event == "PLAYER_LOGOUT" then
		pcall(WL.Snapshot, WL)
		return
	elseif event == "TAXIMAP_OPENED" then
		C_Timer.After(0.2, function() WL:SaveFlightPaths() end)
		return
	elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_LIST_UPDATE" then
		-- coalesce bursts of updates into one read
		if not WL.recipeTimer then
			WL.recipeTimer = true
			C_Timer.After(0.5, function() WL.recipeTimer = nil; WL:SaveRecipes() end)
		end
		return
	elseif event == "GUILD_ROSTER_UPDATE" then
		if not WL.guildTimer then -- fires often; read at most every 30s
			WL.guildTimer = true
			C_Timer.After(30, function() WL.guildTimer = nil end)
			pcall(WL.SaveGuild, WL)
		end
		return
	elseif event == "BANKFRAME_OPENED" then
		WL.bankOpen = true
		C_Timer.After(0.3, function() WL:SaveBank() end) -- give the client a moment to fill the bank
		return
	elseif event == "BANKFRAME_CLOSED" then
		WL:SaveBank()
		WL.bankOpen = false
		return
	elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED" then
		WL:SaveBank()
		return
	elseif event == "CHAT_MSG_LOOT" then
		pcall(WL.RecordLoot, WL, a1)
	elseif event == "PLAYER_LEVEL_UP" then
		WL:Log("Reached level " .. tostring(a1))
	elseif event == "QUEST_TURNED_IN" then
		WL:Log(("Turned in: %s (#%s)"):format(QuestTitle(a1), tostring(a1)))
	elseif event == "QUEST_ACCEPTED" then
		local id = a2 or a1 -- classic: (logIndex, questID); modern: (questID)
		if id then WL:Log(("Accepted: %s (#%s)"):format(QuestTitle(id), tostring(id))) end
	elseif event == "PLAYER_DEAD" then
		WL:Log("Died in " .. (GetSubZoneText() ~= "" and (GetSubZoneText() .. ", ") or "") .. GetZoneText())
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		local z = GetZoneText()
		if z and z ~= "" and z ~= WL.lastZone then WL.lastZone = z; WL:Log("Entered " .. z) end
	elseif event == "BAG_UPDATE_DELAYED" and WL.bankOpen then
		WL:SaveBank() -- items moved between bags and bank bags
	end
	WL:Refresh()
end)

------------------------------------------------------------------------
-- Item tooltips: your AI's verdict on items it has looked at (WowLink_Items in Inbox.lua)
------------------------------------------------------------------------

local function AddVerdict(tt, id)
	if not id then return end
	local pasted = WL.char and WL.char.verdicts
	local mine = WL:MyEntry(_G.WowLink_Items)
	local pv = type(pasted) == "table" and pasted[id] or nil
	local mv = type(mine) == "table" and mine[id] or nil
	local v = pv or mv
	if pv and mv then -- both sources rate this item: the more recently written one wins
		local mt = WL:MyEntry(_G.WowLink_ItemsUpdated)
		if (tonumber(mt) or 0) > (WL.char.verdictsUpdated or 0) then v = mv end
	end
	if type(v) ~= "string" then return end
	local low = v:lower()
	local r, g, b = 0.31, 0.76, 0.97
	if low:find("^upgrade") or low:find("^equip") then r, g, b = 0.25, 1, 0.25
	elseif low:find("^sell") then r, g, b = 1, 0.82, 0 -- Auction House: worth money
	elseif low:find("^vendor") or low:find("^skip") then r, g, b = 0.65, 0.65, 0.65 end
	tt:AddLine("Coach: " .. v, r, g, b, true)
	tt:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
		if data and data.id then AddVerdict(tt, data.id) end
	end)
else
	local function hook(tt)
		local _, link = tt:GetItem()
		if link then AddVerdict(tt, tonumber(link:match("item:(%d+)"))) end
	end
	GameTooltip:HookScript("OnTooltipSetItem", hook)
	if ItemRefTooltip then ItemRefTooltip:HookScript("OnTooltipSetItem", hook) end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local HELP = {
	"|cffffd100/wl copy|r - copy your progress to paste into ChatGPT, Claude or any AI chat",
	"|cffffd100/wl paste|r - paste the AI's reply to load its goal",
	"|cffffd100/wl sync|r - for AI agents using tools/wl.py: save progress and load new guidance (reloads UI)",
	"|cffffd100/wl note <text>|r - leave a note for your AI (|cffffd100/wl note|r lists, |cffffd100/wl note clear|r wipes)",
	"|cffffd100/wl way|r - set the waypoint for the current step",
	"|cffffd100/wl autoway|r - toggle setting waypoints automatically",
	"|cffffd100/wl tomtom|r - use TomTom's arrow when installed (on by default) or the game's map pin",
	"|cffffd100/wl chatlog|r, |cffffd100/wl combatlog|r - toggle the game's own chat / combat logging to disk",
	"|cffffd100/wl show|r, |cffffd100hide|r, |cffffd100lock|r, |cffffd100unlock|r, |cffffd100reset|r - tracker panel",
	"Click a step to tick or untick it; right-click it for its waypoint.",
}

SLASH_WOWLINK1, SLASH_WOWLINK2 = "/wl", "/wowlink"
SlashCmdList.WOWLINK = function(msg)
	local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	local ui = WowLinkDB.ui
	if cmd == "sync" then
		WL:Sync()
	elseif cmd == "copy" or cmd == "export" then
		WL:OpenExport()
	elseif cmd == "paste" or cmd == "import" then
		WL:OpenImport()
	elseif cmd == "note" then
		if rest == "" then
			if #WL.char.notes == 0 then Print("No notes.") end
			for i, n in ipairs(WL.char.notes) do Print(i .. ". " .. n.text) end
		elseif rest:lower() == "clear" then
			wipe(WL.char.notes); Print("Notes cleared.")
		else
			WL:AddNote(rest)
		end
	elseif cmd == "way" then
		if WL.goal and WL.current then WL:SetWaypoint(WL.goal.steps[WL.current]) else Print("No current step.") end
	elseif cmd == "chatlog" or cmd == "combatlog" then
		WowLinkDB[cmd] = (WowLinkDB[cmd] == false)
		WL:ApplyLogging()
		Print((cmd == "chatlog" and "Chat" or "Combat") .. " logging to disk " .. (WowLinkDB[cmd] and "on" or "off") .. ".")
	elseif cmd == "tomtom" then
		WowLinkDB.tomtom = (WowLinkDB.tomtom == false)
		if not (TomTom and TomTom.AddWaypoint) then
			Print("TomTom isn't loaded. Install it to get a GPS-style arrow; WowLink uses the game's map pin meanwhile.")
		else
			Print("TomTom arrow " .. (WowLinkDB.tomtom and "on" or "off (using the game's map pin)") .. ".")
			WL.lastWaypoint = nil; WL:ClearWaypoint(); WL:Refresh(true)
		end
	elseif cmd == "autoway" then
		WowLinkDB.autoWaypoint = (WowLinkDB.autoWaypoint == false)
		Print("Auto waypoints " .. (WowLinkDB.autoWaypoint and "on" or "off") .. ".")
	elseif cmd == "show" or cmd == "hide" then
		ui.hidden = (cmd == "hide"); WL:Refresh(true)
	elseif cmd == "lock" or cmd == "unlock" then
		ui.locked = (cmd == "lock"); Print("Tracker " .. cmd .. "ed.")
	elseif cmd == "reset" then
		ui.pos = nil; ui.hidden = false; ui.collapsed = false
		if WL.PlaceFrame then WL:PlaceFrame() end
		WL:Refresh(true)
	elseif cmd == "" then
		ui.hidden = not ui.hidden; WL:Refresh(true)
	else
		for _, l in ipairs(HELP) do Print(l) end
	end
end
