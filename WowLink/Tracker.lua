-- WowLink tracker panel: one goal, styled like a quest in the objective tracker.

local WL = WowLink
local WIDTH = 250
local TEXT_W = WIDTH - 20

local f = CreateFrame("Frame", "WowLinkTracker", UIParent)
f:SetSize(WIDTH, 40)
f:SetClampedToScreen(true)
f:SetMovable(true)
f:SetFrameStrata("LOW")
f:Hide()

local bg = f:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.30)

-- Header: goal title, click to collapse, drag to move
local header = CreateFrame("Button", nil, f)
header:SetPoint("TOPLEFT", 0, 0)
header:SetPoint("TOPRIGHT", 0, 0)
header:SetHeight(22)
header:RegisterForDrag("LeftButton")
header:RegisterForClicks("LeftButtonUp")

local tag = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
tag:SetPoint("TOPRIGHT", -6, -5)

local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 6, -5)
title:SetPoint("RIGHT", tag, "LEFT", -4, 0)
title:SetJustifyH("LEFT")
title:SetWordWrap(false)

local line = header:CreateTexture(nil, "ARTWORK")
line:SetColorTexture(1, 0.82, 0, 0.4)
line:SetHeight(1)
line:SetPoint("BOTTOMLEFT", 4, 0)
line:SetPoint("BOTTOMRIGHT", -4, 0)

function WL:SavePos()
	local p, _, rp, x, y = f:GetPoint()
	WowLinkDB.ui.pos = { p, rp, x, y }
end

function WL:PlaceFrame()
	f:ClearAllPoints()
	local pos = WowLinkDB.ui.pos
	if pos then
		f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		f:SetPoint("RIGHT", UIParent, "RIGHT", -60, 60)
	end
end

header:SetScript("OnDragStart", function() if not WowLinkDB.ui.locked then f:StartMoving() end end)
header:SetScript("OnDragStop", function() f:StopMovingOrSizing(); WL:SavePos() end)
header:SetScript("OnClick", function()
	WowLinkDB.ui.collapsed = not WowLinkDB.ui.collapsed
	WL:Render()
end)
header:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("WowLink", 0.31, 0.76, 0.97)
	GameTooltip:AddLine("Click to collapse or expand. Drag to move.", 0.8, 0.8, 0.8, true)
	GameTooltip:AddLine("/wl help for commands", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end)
header:SetScript("OnLeave", GameTooltip_Hide)

-- Free text blocks
local function Block(font)
	local fs = f:CreateFontString(nil, "OVERLAY", font)
	fs:SetWidth(TEXT_W + 8)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(true)
	return fs
end
local summary = Block("GameFontHighlightSmall")
summary:SetTextColor(0.85, 0.85, 0.85)
local tips = Block("GameFontHighlightSmall")
tips:SetTextColor(0.55, 0.8, 1)

-- Footer: goal number and age, then links: copy / paste (any AI chat) and sync (AI agents)
local footer = CreateFrame("Frame", nil, f)
footer:SetHeight(14)
local footText = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
footText:SetPoint("LEFT", 0, 0)
footText:SetJustifyH("LEFT")

local function FootLink(label, tipTitle, tipText, onClick)
	local b = CreateFrame("Button", nil, footer)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	fs:SetPoint("CENTER")
	fs:SetText("|cff4fc3f7[" .. label .. "]|r")
	b:SetSize(fs:GetStringWidth() + 4, 14)
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(tipTitle, 0.31, 0.76, 0.97)
		GameTooltip:AddLine(tipText, 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
end

local syncLink = FootLink("sync", "Sync (AI agents)",
	"Reloads the UI: saves your progress for an AI agent using tools/wl.py, and loads any goal it wrote.",
	function() WL:Sync() end)
syncLink:SetPoint("RIGHT", footer, "RIGHT", 0, 0)
local pasteLink = FootLink("paste", "Paste the AI's reply",
	"Paste your AI's reply here to load the goal it wrote.", function() WL:OpenImport() end)
pasteLink:SetPoint("RIGHT", syncLink, "LEFT", -2, 0)
local copyLink = FootLink("copy", "Copy for your AI",
	"Copies a report of your progress to paste into ChatGPT, Claude or any AI chat.", function() WL:OpenExport() end)
copyLink:SetPoint("RIGHT", pasteLink, "LEFT", -2, 0)

-- Step rows
local rows = {}

local function DescribeCheck(c)
	local parts = {}
	if c.level then parts[#parts + 1] = "reach level " .. c.level end
	if c.quest then parts[#parts + 1] = "turn in quest #" .. c.quest end
	if c.questInLog then parts[#parts + 1] = "pick up quest #" .. c.questInLog end
	if c.item then parts[#parts + 1] = ("have %d of item #%d"):format(c.count or 1, c.item) end
	if c.money then parts[#parts + 1] = "have " .. GetCoinText(c.money) end
	if c.skill then parts[#parts + 1] = ("%s %d"):format(c.skill, c.rank or 1) end
	if c.zone then parts[#parts + 1] = "be in " .. tostring(c.zone) end
	if c.flight then parts[#parts + 1] = "learn the " .. c.flight .. " flight path" end
	return table.concat(parts, ", ")
end

local function RowEnter(self)
	local s = WL.goal and WL.goal.steps[self.index]
	if not s then return end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine(s.text, 1, 1, 1, true)
	if s.detail then GameTooltip:AddLine(s.detail, 0.8, 0.8, 0.8, true) end
	if s.waypoint then
		GameTooltip:AddLine(("Waypoint: %.1f, %.1f%s"):format(s.waypoint.x, s.waypoint.y,
			s.waypoint.label and (" - " .. s.waypoint.label) or ""), 0.4, 0.8, 1, true)
	end
	if s.check then GameTooltip:AddLine("Ticks itself when you " .. DescribeCheck(s.check) .. ".", 0.5, 0.9, 0.5, true) end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Click: tick / untick" .. (s.waypoint and "    Right-click: waypoint" or ""), 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function RowClick(self, button)
	local s = WL.goal and WL.goal.steps[self.index]
	if not s then return end
	if button == "RightButton" then WL:SetWaypoint(s) else WL:ToggleStep(self.index) end
end

local function GetRow(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, f)
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	r.mark = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	r.mark:SetPoint("TOPLEFT", 0, 0)
	r.mark:SetWidth(14)
	r.mark:SetJustifyH("LEFT")
	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	r.text:SetPoint("TOPLEFT", 14, 0)
	r.text:SetWidth(TEXT_W - 8)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(true)
	r:SetScript("OnEnter", RowEnter)
	r:SetScript("OnLeave", GameTooltip_Hide)
	r:SetScript("OnClick", RowClick)
	rows[i] = r
	return r
end

local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"

local function Ago(t)
	if not t then return "" end
	local d = time() - t
	if d < 90 then return "just now" end
	if d < 5400 then return math.floor(d / 60 + 0.5) .. "m ago" end
	if d < 172800 then return math.floor(d / 3600 + 0.5) .. "h ago" end
	return math.floor(d / 86400 + 0.5) .. "d ago"
end

function WL:InitUI()
	self:PlaceFrame()
	-- footer age text goes stale; refresh it now and then
	C_Timer.NewTicker(60, function() if f:IsShown() then WL:Render() end end)
end

function WL:Render()
	local ui = WowLinkDB.ui
	if ui.hidden or not self.char then f:Hide(); return end
	f:Show()
	for _, r in ipairs(rows) do r:Hide() end
	summary:Hide(); tips:Hide(); footer:Hide()

	local g = self.goal
	local st = self.char.goalState
	local y = -26
	local function place(region, h, x)
		region:ClearAllPoints()
		region:SetPoint("TOPLEFT", f, "TOPLEFT", x or 6, y)
		region:Show()
		y = y - h
	end

	if not g then
		title:SetText("WowLink")
		tag:SetText("")
		summary:SetText("No goal yet. Click [copy] and paste it into ChatGPT, Claude or any AI chat. Talk it over, then click [paste] to load the goal it gives you.")
		place(summary, summary:GetStringHeight() + 6)
	else
		title:SetText(g.title or "Goal")
		local total, done = #g.steps, 0
		for i = 1, total do if st.done[i] then done = done + 1 end end
		tag:SetText(done .. "/" .. total .. (ui.collapsed and " +" or ""))

		local collapsed = ui.collapsed
		if g.summary and g.summary ~= "" and not collapsed then
			summary:SetText(g.summary)
			place(summary, summary:GetStringHeight() + 6)
		end
		for i, s in ipairs(g.steps) do
			local isDone, isCur = st.done[i] and true or false, (i == self.current)
			if not collapsed or isCur then
				local r = GetRow(i)
				r.index = i
				r.text:SetText(s.text or "")
				if isDone then
					r.mark:SetText(CHECK)
					r.text:SetTextColor(0.5, 0.5, 0.5)
				elseif isCur then
					r.mark:SetText("|cffffd100>|r")
					r.text:SetTextColor(1, 1, 1)
				else
					r.mark:SetText("|cff808080-|r")
					r.text:SetTextColor(0.72, 0.72, 0.72)
				end
				local h = r.text:GetStringHeight() + 3
				r:SetSize(TEXT_W, h)
				place(r, h, 10)
			end
		end
		if not self.current then
			summary:SetText("|cff40ff40Goal complete!|r Tell your AI how it went ([copy]) and get the next one.")
			place(summary, summary:GetStringHeight() + 6)
		end
		if g.tips and #g.tips > 0 and not collapsed then
			y = y - 3
			tips:SetText("Tip: " .. table.concat(g.tips, "\nTip: "))
			place(tips, tips:GetStringHeight() + 4)
		end
	end

	if not ui.collapsed then
		y = y - 2
		footText:SetText(g and ("Goal #" .. tostring(g.id) .. ", " .. Ago(g.updated)) or "")
		footer:SetWidth(TEXT_W)
		place(footer, 16)
	end
	f:SetHeight(-y + 4)
end
