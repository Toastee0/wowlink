-- WowLink copy/paste bridge: works with any AI chat (ChatGPT, Claude.ai, Gemini, ...) and
-- needs nothing outside the game. /wl copy builds a progress report to paste into the chat;
-- /wl paste reads the AI's reply and loads the goal (and item verdicts) it contains.

local WL = WowLink
local Print = WL.Print

------------------------------------------------------------------------
-- Text helpers
------------------------------------------------------------------------

local FIX = { ["\226\128\148"] = "-", ["\226\128\147"] = "-", ["\226\128\152"] = "'", ["\226\128\153"] = "'",
	["\226\128\156"] = '"', ["\226\128\157"] = '"', ["\226\128\166"] = "...", ["\194\160"] = " ", ["\226\134\146"] = "->" }

local function Fix(s)
	if type(s) ~= "string" then return nil end
	for a, b in pairs(FIX) do s = s:gsub(a, b) end
	s = s:gsub("|", "/") -- never let pasted text inject UI escape codes
	return s
end

local function Coins(c)
	c = c or 0
	return ("%dg %ds %dc"):format(math.floor(c / 10000), math.floor(c / 100) % 100, c % 100)
end

local function Stats(st)
	if type(st) ~= "table" then return "" end
	local parts = {}
	for k, v in pairs(st) do
		local name = k:lower():gsub("_", " "):gsub("^%l", string.upper)
		if type(v) == "number" and v % 1 ~= 0 then v = ("%.1f"):format(v) end
		parts[#parts + 1] = name .. " " .. tostring(v)
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function Item(d)
	if type(d) ~= "table" then return "?" end
	local s = ("%s #%s (%s%s, ilvl %s%s)"):format(d.name or "?", tostring(d.id), d.sub or d.type or "",
		d.slot and (" " .. d.slot) or "", tostring(d.ilvl), d.req and d.req > 1 and (", req " .. d.req) or "")
	-- bag/bank items only (bound is nil for equipped gear): can it go on the Auction House?
	if d.bound == true then s = s .. " [soulbound]"
	elseif d.bound == "some" then s = s .. " [some soulbound]"
	elseif d.bound == false then s = s .. (d.bind == "BoE" and " [Bind on Equip, tradeable]" or " [tradeable]") end
	if d.vendor and d.bound ~= nil then s = s .. " [vendor " .. Coins(d.vendor):gsub(" 0c$", ""):gsub("^0g ", "") .. "]" end
	local st = Stats(d.stats)
	if st ~= "" then s = s .. ": " .. st end
	return s
end

------------------------------------------------------------------------
-- JSON (just enough to read an AI's reply)
------------------------------------------------------------------------

local function Utf8(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
	if cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function JsonDecode(s)
	local i = 1
	local function fail(m) error({ msg = m .. " (at character " .. i .. ")" }, 0) end
	local function ws() i = s:find("[^ \t\r\n]", i) or (#s + 1) end
	local value

	local function str()
		i = i + 1
		local out = {}
		while true do
			local c = s:sub(i, i)
			if c == "" then fail("unfinished text") end
			if c == '"' then i = i + 1; break end
			if c == "\\" then
				local n = s:sub(i + 1, i + 1)
				if ESC[n] then
					out[#out + 1] = ESC[n]; i = i + 2
				elseif n == "u" then
					local cp = tonumber(s:sub(i + 2, i + 5), 16) or fail("bad \\u escape")
					i = i + 6
					if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
						local lo = tonumber(s:sub(i + 2, i + 5), 16)
						if lo then cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00); i = i + 6 end
					end
					out[#out + 1] = Utf8(cp)
				else
					fail("bad escape")
				end
			else
				local j = s:find('["\\]', i) or (#s + 1)
				out[#out + 1] = s:sub(i, j - 1)
				i = j
			end
		end
		return table.concat(out)
	end

	function value()
		ws()
		local c = s:sub(i, i)
		if c == "{" then
			i = i + 1
			local obj = {}
			ws()
			if s:sub(i, i) == "}" then i = i + 1; return obj end
			while true do
				ws()
				if s:sub(i, i) ~= '"' then fail("expected a quoted key") end
				local k = str()
				ws()
				if s:sub(i, i) ~= ":" then fail("expected ':'") end
				i = i + 1
				obj[k] = value()
				ws()
				local d = s:sub(i, i)
				i = i + 1
				if d == "}" then return obj end
				if d ~= "," then fail("expected ',' or '}'") end
			end
		elseif c == "[" then
			i = i + 1
			local arr, n = {}, 0
			ws()
			if s:sub(i, i) == "]" then i = i + 1; return arr end
			while true do
				n = n + 1
				arr[n] = value()
				ws()
				local d = s:sub(i, i)
				i = i + 1
				if d == "]" then return arr end
				if d ~= "," then fail("expected ',' or ']'") end
			end
		elseif c == '"' then
			return str()
		elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
		elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
		elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
		else
			local num = s:match("^-?%d+%.?%d*", i)
			if not num then fail("unexpected '" .. c .. "'") end
			i = i + #num
			local e = s:match("^[eE][-+]?%d+", i)
			if e then num = num .. e; i = i + #e end
			return tonumber(num)
		end
	end

	local ok, res = pcall(value)
	if not ok then return nil, type(res) == "table" and res.msg or tostring(res) end
	return res
end
WL.JsonDecode = JsonDecode

-- Pull the goal object out of a whole chat reply.
local function ExtractJson(text)
	text = text:gsub("||", "|"):gsub("\r", "")
	local block = text:match("```[Jj][Ss][Oo][Nn]%s*\n(.-)```") or text:match("```%s*\n(%s*{.-)```")
	local src = block or text
	local a = src:find("{", 1, true)
	local b
	for k = #src, 1, -1 do if src:sub(k, k) == "}" then b = k; break end end
	if not a or not b or b < a then return nil, "Couldn't find the goal in that text. Paste the AI's whole reply, or just its ```json block." end
	return JsonDecode(src:sub(a, b))
end

------------------------------------------------------------------------
-- Goal cleaning (lenient: keep what's usable, drop what isn't)
------------------------------------------------------------------------

local NUM_CHECKS = { "level", "quest", "questInLog", "item", "count", "money", "rank" }

local function CleanGoal(g)
	if type(g) ~= "table" then return nil, "That isn't a goal object." end
	if type(g.goal) == "table" then -- tolerate {"goal": {...}, "verdicts": {...}}
		g.goal.verdicts = g.goal.verdicts or g.verdicts
		g = g.goal
	end
	if type(g.title) ~= "string" or g.title == "" then return nil, "The goal has no title." end
	if type(g.steps) ~= "table" or #g.steps == 0 then return nil, "The goal has no steps." end
	local out = { title = Fix(g.title):sub(1, 60), steps = {} }
	if type(g.summary) == "string" then out.summary = Fix(g.summary) end
	for n, s in ipairs(g.steps) do
		if n > 12 then break end
		if type(s) == "string" then s = { text = s } end
		if type(s) == "table" and type(s.text) == "string" and s.text ~= "" then
			local st = { text = Fix(s.text) }
			if type(s.detail) == "string" then st.detail = Fix(s.detail) end
			if type(s.check) == "table" then
				local c, any = {}, false
				for _, k in ipairs(NUM_CHECKS) do
					if tonumber(s.check[k]) then c[k] = math.floor(tonumber(s.check[k])); any = true end
				end
				if tonumber(s.check.zone) then c.zone = tonumber(s.check.zone); any = true
				elseif type(s.check.zone) == "string" then c.zone = Fix(s.check.zone); any = true end
				if type(s.check.skill) == "string" then c.skill = Fix(s.check.skill); any = true end
				if c.count and not c.item then c.count = nil end
				if c.rank and not c.skill then c.rank = nil end
				if any then st.check = c end
			end
			local w = s.waypoint
			if type(w) == "table" and tonumber(w.map) and tonumber(w.x) and tonumber(w.y) then
				local x, y = tonumber(w.x), tonumber(w.y)
				if x <= 1 and y <= 1 then x, y = x * 100, y * 100 end -- accept 0-1 coordinates too
				if x >= 0 and x <= 100 and y >= 0 and y <= 100 then
					st.waypoint = { map = math.floor(tonumber(w.map)), x = x, y = y, label = Fix(w.label) }
				end
			end
			out.steps[#out.steps + 1] = st
		end
	end
	if #out.steps == 0 then return nil, "None of the steps have text." end
	if type(g.tips) == "table" then
		out.tips = {}
		for _, t in ipairs(g.tips) do if type(t) == "string" then out.tips[#out.tips + 1] = Fix(t) end end
	end
	local verdicts
	if type(g.verdicts) == "table" then
		verdicts = {}
		for k, v in pairs(g.verdicts) do
			if tonumber(k) and type(v) == "string" then verdicts[tonumber(k)] = Fix(v):sub(1, 90) end
		end
	end
	return out, nil, verdicts
end

function WL:ImportReply(text)
	local raw, err = ExtractJson(text or "")
	if not raw then return false, err end
	local g, err2, verdicts = CleanGoal(raw)
	if not g then return false, err2 end
	local c = self.char
	local cur = self:Goal()
	g.id = math.max(cur and cur.id or 0, c.goalState and c.goalState.id or 0) + 1
	g.updated = time()
	c.imported = g
	local nv = 0
	if verdicts then
		c.verdicts = c.verdicts or {}
		for id, v in pairs(verdicts) do c.verdicts[id] = v; nv = nv + 1 end
	end
	self.lastWaypoint = nil
	self:SyncGoalState()
	self:Refresh(true)
	return true, ("Loaded: %s (%d steps%s)"):format(g.title, #g.steps, nv > 0 and (", " .. nv .. " item verdicts") or "")
end

------------------------------------------------------------------------
-- The report you paste into the AI
------------------------------------------------------------------------

local PROMPT = [[You are my World of Warcraft coach, working through an addon called WowLink. I play; you advise.
Guidance only: never suggest automation, botting, exploits, or anything against Blizzard's terms.

Below is a report from the game. Talk it over with me, then set ONE current goal of 3-8 concrete
steps; WowLink shows it in my quest tracker. When we've agreed on a goal, or I ask for one,
put it in a single ```json block like this (I paste your whole reply back into the game):

```json
{
  "title": "Short header, max 48 chars",
  "summary": "Why this goal, one or two sentences.",
  "steps": [
    {"text": "What to do", "detail": "Optional tooltip: how and where.",
     "check": {"quest": 12345},
     "waypoint": {"map": 1436, "x": 56.3, "y": 47.5, "label": "NPC name"}},
    {"text": "Reach level 20", "check": {"level": 20}}
  ],
  "tips": ["Optional short tips."],
  "verdicts": {"6087": "Upgrade: replaces your current legs"}
}
```

Rules for the JSON:
- "check" ticks a step automatically once ALL its conditions are true: level, quest (turned in),
  questInLog (picked up or turned in), item + count, money (copper), skill + rank, zone (uiMapID or
  zone name). Leave "check" out and I'll tick the step myself.
- "waypoint": uiMapID with 0-100 coordinates. Leave it out unless you're sure.
- Only use quest and item IDs shown in my report or ones you are certain of. A wrong ID makes a
  step that never ticks.
- Same for directions: don't state travel routes (zeppelins, boats, flight paths), NPC or building
  locations as fact unless you're sure for my game version. Say you're unsure, or ask me.
- "verdicts" (optional): item ID -> one line, max 90 chars, shown in that item's tooltip. Start
  with Upgrade:, Equip:, Keep:, Sell:, Vendor: or Skip:. Judge gear against what I have equipped, my
  class and my goals, and say why in the chat.
- Items I don't need: if the report marks one tradeable (especially Bind on Equip greens and blues),
  say Sell: and suggest the Auction House; Vendor: is for soulbound items and junk.
- Later I'll send short "WOWLINK UPDATE" reports in this same chat; use them to check my progress.
]]
WL.PROMPT = PROMPT

function WL:ExportText(full)
	self:Snapshot()
	local c, s = self.char, self.char.snapshot
	local L = {}
	local function w(x) L[#L + 1] = x end
	if full then w(PROMPT); w("=== WOWLINK REPORT ===") else w("=== WOWLINK UPDATE ===") end
	local _, _, _, toc = GetBuildInfo()
	local ver = GetBuildInfo()
	w(("Character: %s, level %s %s %s. Game version %s (interface %s)%s."):format(self.key, tostring(s.level),
		s.race or "", s.class or "", tostring(ver), tostring(toc),
		(tonumber(toc) or 0) < 20000 and " (Classic-era rules: level cap 60, talent points)" or ""))
	w(("XP %d/%d, rested %d. Money %s. Hearthstone: %s."):format(s.xp or 0, s.xpMax or 0, s.rested or 0,
		Coins(s.money), tostring(s.hearth)))
	w(("Location: %s%s%s%s."):format(s.zone or "?", (s.subzone and s.subzone ~= "") and (" > " .. s.subzone) or "",
		s.mapID and (" [uiMapID " .. s.mapID .. "]") or "", s.x and (" at " .. s.x .. ", " .. s.y) or ""))
	if s.talentPoints and s.talentPoints > 0 then w("Unspent talent points: " .. s.talentPoints) end

	local g, st = self.goal, c.goalState
	if g and st then
		w(""); w(("Current goal: %s%s"):format(g.title, st.completed and " (COMPLETE)" or ""))
		for i, step in ipairs(g.steps) do
			local d = st.done[i]
			w(("  %d. [%s] %s"):format(i, d and "done" or (i == self.current and "current" or "todo"), step.text))
		end
	end
	if #c.notes > 0 then
		w(""); w("My notes:")
		for _, n in ipairs(c.notes) do w("- " .. n.text) end
	end
	local j = c.journal or {}
	if #j > 0 then
		w(""); w("Recent events (oldest first):")
		for k = math.max(1, #j - 14), #j do
			local e = j[k]
			w(("- %s [L%s %s] %s"):format(date("%m-%d %H:%M", e.t), tostring(e.lvl), e.zone or "", e.e))
		end
	end
	w(""); w(("Quest log (%d):"):format(#(s.quests or {})))
	for _, q in ipairs(s.quests or {}) do
		w(("- [%s] %s #%s%s"):format(tostring(q.level), q.title or "?", tostring(q.id), q.complete and " COMPLETE" or ""))
		if not q.complete then for _, o in ipairs(q.obj or {}) do w("    " .. o) end end
	end
	local prof = {}
	for _, k in ipairs(s.skills or {}) do
		if k.cat == "Professions" or k.cat == "Secondary Skills" then prof[#prof + 1] = ("%s %s/%s"):format(k.name, tostring(k.rank), tostring(k.max)) end
	end
	if #prof > 0 then w(""); w("Professions: " .. table.concat(prof, ", ")) end
	w(""); w("Equipped:")
	for _, e in ipairs(s.equipment or {}) do w(("- %s: %s"):format(e.equipSlot or "?", Item(e))) end
	local loot = {}
	for _, d in ipairs(c.loot or {}) do if d.slot then loot[#loot + 1] = d end end
	if #loot > 0 then
		w(""); w("Recent gear drops:")
		for k = math.max(1, #loot - 9), #loot do w("- " .. Item(loot[k])) end
	end
	local function Container(items, label)
		local gear, other = {}, {}
		for _, b in ipairs(items or {}) do
			if b.slot then gear[#gear + 1] = b
			elseif b.name then other[#other + 1] = b.name .. ((b.n or 1) > 1 and (" x" .. b.n) or "") end
		end
		if #gear > 0 then
			w(""); w("Unequipped gear in " .. label .. ":")
			for _, b in ipairs(gear) do w("- " .. Item(b)) end
		end
		if #other > 0 then w(""); w("Other items in " .. label .. ": " .. table.concat(other, ", ")) end
	end
	Container(s.bags, "bags")
	if c.bank then
		Container(c.bank.items, ("bank (as of %s)"):format(date("%m-%d %H:%M", c.bank.t)))
	else
		w(""); w("Bank: not seen yet (it's recorded next time I open my bank).")
	end
	w(""); w(("Quests completed so far: %d."):format(#(s.completedQuests or {})))
	w("=== END ===")
	return (table.concat(L, "\n"):gsub("|", "/"))
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------

local win

local function MakeWindow()
	local ok, f = pcall(CreateFrame, "Frame", "WowLinkTextWindow", UIParent, "BasicFrameTemplateWithInset")
	if not ok or not f then
		f = CreateFrame("Frame", "WowLinkTextWindow", UIParent)
		local bg = f:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.05, 0.05, 0.08, 0.95)
		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", 0, 0)
	end
	f:SetSize(600, 460)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	tinsert(UISpecialFrames, "WowLinkTextWindow") -- Escape closes it

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.title:SetPoint("TOP", 0, -6)

	f.help = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.help:SetPoint("TOPLEFT", 14, -32)
	f.help:SetPoint("TOPRIGHT", -14, -32)
	f.help:SetJustifyH("LEFT")

	local sf = CreateFrame("ScrollFrame", "WowLinkTextScroll", f, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 14, -72)
	sf:SetPoint("BOTTOMRIGHT", -34, 46)
	local eb = CreateFrame("EditBox", nil, sf)
	eb:SetMultiLine(true)
	eb:SetAutoFocus(false)
	eb:SetFontObject(ChatFontNormal)
	eb:SetWidth(540)
	eb:SetMaxLetters(0)
	if eb.SetMaxBytes then eb:SetMaxBytes(0) end
	eb:SetScript("OnEscapePressed", function() f:Hide() end)
	if ScrollingEdit_OnCursorChanged then
		eb:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
		eb:SetScript("OnUpdate", function(self, elapsed) ScrollingEdit_OnUpdate(self, elapsed, sf) end)
	end
	sf:SetScrollChild(eb)
	sf:EnableMouse(true)
	sf:SetScript("OnMouseDown", function() eb:SetFocus() end)
	f.edit = eb

	f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.status:SetPoint("BOTTOMLEFT", 16, 18)
	f.status:SetPoint("RIGHT", f, "RIGHT", -300, 0)
	f.status:SetJustifyH("LEFT")

	local function Button(text, x)
		local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		b:SetSize(130, 24)
		b:SetPoint("BOTTOMRIGHT", x, 12)
		b:SetText(text)
		return b
	end
	f.b1 = Button("", -150)
	f.b2 = Button("", -14)
	f:Hide()
	return f
end

local function Window()
	win = win or MakeWindow()
	return win
end

local function SetStatus(text, r, g, b)
	Window().status:SetText(text or "")
	Window().status:SetTextColor(r or 0.8, g or 0.8, b or 0.8)
end

function WL:OpenExport(full)
	if not self.char then return end
	local f = Window()
	if full == nil then full = not self.char.exportedOnce end
	f.title:SetText("WowLink: copy for your AI")
	f.help:SetText("Press |cffffffffCtrl+C|r to copy (it's already selected), then paste it into ChatGPT, Claude or any AI chat.\n"
		.. "When the AI gives you a goal, type |cffffffff/wl paste|r and paste its reply.")
	local text = self:ExportText(full)
	f.edit:SetText(text)
	f.edit:SetCursorPosition(0)
	f:Show()
	f.edit:SetFocus()
	f.edit:HighlightText()
	f.edit:SetScript("OnTextChanged", nil)
	SetStatus((full and "Full report with instructions (start of a new chat)." or "Short update (for a chat that already has the instructions).")
		.. (" %d characters."):format(#text))
	f.b1:SetText(full and "Short update" or "Full report")
	f.b1:SetScript("OnClick", function() WL:OpenExport(not full) end)
	f.b1:Show()
	f.b2:SetText("Select all")
	f.b2:SetScript("OnClick", function() f.edit:SetFocus(); f.edit:HighlightText() end)
	self.char.exportedOnce = true
end

function WL:OpenImport()
	if not self.char then return end
	local f = Window()
	f.title:SetText("WowLink: paste your AI's reply")
	f.help:SetText("Click below, press |cffffffffCtrl+V|r to paste the AI's reply (the whole message is fine), then click |cffffffffLoad goal|r.")
	f.edit:SetText("")
	f:Show()
	f.edit:SetFocus()
	SetStatus("")
	f.b1:Hide()
	f.b2:SetText("Load goal")
	f.b2:SetScript("OnClick", function()
		local ok, msg = WL:ImportReply(f.edit:GetText())
		if ok then
			f:Hide()
			Print("|cff40ff40" .. msg .. "|r")
		else
			SetStatus(msg, 1, 0.35, 0.35)
		end
	end)
end
