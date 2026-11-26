"""Smoke test: run the real addon files in Lua 5.1 (lupa) against a stubbed WoW API,
then write SavedVariables the way WoW does and read them back with wl.py.

  python tests/harness.py            (uses a temp WoW dir; never touches the real install)
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import lupa.lua51 as lupa

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "WowLink"

STUBS = r"""
local calls = {}
_G.CALLS = calls
local function mock(name)
  local o = { _name = name, _shown = false, _scripts = {} }
  return setmetatable(o, { __index = function(t, k)
    return function(self, ...) calls[#calls+1] = (name or "?") .. ":" .. k; return nil end
  end })
end
local function frame(name)
  local f = mock(name or "frame")
  f.SetScript = function(self, k, fn) self._scripts[k] = fn end
  f.HookScript = f.SetScript
  f.RegisterEvent = function(self, e) EVENTS[e] = self end
  f.Show = function(self) self._shown = true end
  f.Hide = function(self) self._shown = false end
  f.IsShown = function(self) return self._shown end
  f.GetPoint = function() return "RIGHT", nil, "RIGHT", -60, 60 end
  f.CreateTexture = function() return mock("tex") end
  f.SetText = function(self, t) self.text = t end
  f.GetText = function(self) return self.text or "" end
  f.CreateFontString = function()
    local fs = mock("fs")
    fs.SetText = function(self, t) self.text = t end
    fs.GetStringHeight = function(self) return 12 end
    fs.GetStringWidth = function(self) return 30 end
    return fs
  end
  if name then _G[name] = f end
  return f
end
EVENTS = {}
UISpecialFrames = {}
tinsert = table.insert
ChatFontNormal = {}
GetBuildInfo = function() return "1.60.1", "71139", "Nov 1 2026", 16001 end
date = os.date
CreateFrame = function(_, name) return frame(name) end
UIParent = frame("UIParent")
GameTooltip = frame("GameTooltip")
GameTooltip_Hide = function() end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("[chat] " .. m) end }
C_Timer = { After = function(_, fn) fn() end, NewTicker = function() end }
SOUNDKIT = {}
PlaySound = function() end
time = os.time
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
GetCoinText = function(c) return c .. "c" end

STATE = { level = 12, money = 5000, zone = "Westfall", completed = { [64] = true }, log = { 65, 12 }, items = { [2589] = 4 } }
UnitName = function() return "Testchar" end
GetRealmName = function() return "Realm" end
GetNormalizedRealmName = function() return "Realm" end
UnitLevel = function() return STATE.level end
UnitClass = function() return "Priest", "PRIEST" end
UnitRace = function() return "Human", "Human" end
UnitSex = function() return 2 end
UnitXP = function() return 3000 end
UnitXPMax = function() return 8800 end
GetXPExhaustion = function() return 1200 end
GetMoney = function() return STATE.money end
GetZoneText = function() return STATE.zone end
GetSubZoneText = function() return "Sentinel Hill" end
GetMinimapZoneText = function() return "Sentinel Hill" end
GetBindLocation = function() return "Sentinel Hill" end
UnitCharacterPoints = function() return 1 end
UnitIsDeadOrGhost = function() return false end
IsInGroup = function() return false end
InCombatLockdown = function() return false end
ReloadUI = function() RELOADED = true end
GetInventoryItemLink = function(_, slot)
  if slot == 6 then return "|cffffffff|Hitem:4680:0|h[Cracked Leather Belt]|h|r" end
end
GetInventoryItemID = function(_, slot) if slot == 6 then return 4680 end end
C_Item = {
  GetItemCount = function(id) return STATE.items[id] or 0 end,
  IsBound = function(loc) return false end,
  GetItemInfo = function(link)
    local id = tonumber(link:match("item:(%d+)"))
    if id == 4680 then return "Cracked Leather Belt", link, 1, 8, 3, "Armor", "Leather", 1, "INVTYPE_WAIST" end
    if id == 6087 then return "Chausses of Westfall", link, 2, 21, 16, "Armor", "Leather", 1, "INVTYPE_LEGS", 0, 1234, 4, 2, 2 end
    if id == 2589 then return "Linen Cloth", link, 1, 5, 0, "Trade Goods", "Cloth", 20, "" end
  end,
  GetItemStats = function(link)
    if link:find("6087") then return { ITEM_MOD_AGILITY_SHORT = 5, ITEM_MOD_STAMINA_SHORT = 4, RESISTANCE0_NAME = 74 } end
    return {}
  end,
}
C_Container = {
  GetContainerNumSlots = function(bag) if bag == 0 then return 2 elseif bag == -1 then return 1 end return 0 end,
  GetContainerItemInfo = function(bag, slot)
    if slot == 1 then return { itemID = 2589, stackCount = STATE.items[2589], hyperlink = "|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r" } end
    if slot == 2 and bag == 0 then return { itemID = 6087, stackCount = 1, hyperlink = "|cff1eff00|Hitem:6087::|h[Chausses of Westfall]|h|r" } end
  end,
}
C_QuestLog = {
  IsQuestFlaggedCompleted = function(id) return STATE.completed[id] or false end,
  GetAllCompletedQuestIDs = function() local t = {} for id in pairs(STATE.completed) do t[#t+1] = id end return t end,
  GetNumQuestLogEntries = function() return #STATE.log + 1 end,
  GetInfo = function(i)
    if i == 1 then return { isHeader = true, title = "Westfall" } end
    local id = STATE.log[i - 1]
    return { questID = id, title = "Quest " .. id, level = 12, isHeader = false }
  end,
  IsComplete = function(id) return id == 12 end,
  GetQuestObjectives = function(id) return { { text = "Defias Trapper slain: 7/15", finished = false } } end,
  GetTitleForQuestID = function(id) return "Quest " .. id end,
}
C_Map = {
  GetBestMapForUnit = function() return 1436 end,
  GetPlayerMapPosition = function() return { GetXY = function() return 0.5612, 0.4721 end } end,
  GetMapInfo = function(id) if id == 1436 then return { name = "Westfall", parentMapID = 1415 } end return { name = "Eastern Kingdoms" } end,
  SetUserWaypoint = function(p) WAYPOINT = p end,
  GetUserWaypoint = function() return WAYPOINT end,
  ClearUserWaypoint = function() WAYPOINT = nil end,
  CanSetUserWaypointOnMap = function() return true end,
}
ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { uiMapID = m, position = { x = x, y = y } } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
LoggingChat = function(on) CHATLOG = on end
LoggingCombat = function(on) COMBATLOG = on end
SlashCmdList = {}
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) TOOLTIP_FN = fn end }
Enum = { TooltipDataType = { Item = 0 } }

function FIRE(e, ...) local f = EVENTS[e]; if f then f._scripts.OnEvent(f, e, ...) end end

-- WoW-style SavedVariables writer
function SERIALIZE(name, v)
  local out = {}
  local function w(s) out[#out+1] = s end
  local function val(x, ind)
    local t = type(x)
    if t == "table" then
      w("{\n")
      local n = #x
      for i = 1, n do w(ind .. "\t"); val(x[i], ind .. "\t"); w(", -- [" .. i .. "]\n") end
      for k, v in pairs(x) do
        if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
          w(ind .. "\t[" .. (type(k) == "string" and string.format("%q", k) or tostring(k)) .. "] = ")
          val(v, ind .. "\t"); w(",\n")
        end
      end
      w(ind .. "}")
    elseif t == "string" then w((string.format("%q", x):gsub("\\\n", "\\n")))
    else w(tostring(x)) end
  end
  w(name .. " = "); val(v, ""); w("\n")
  return table.concat(out)
end
"""


def run(cmd, env):
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "wl.py")] + cmd, capture_output=True, text=True,
                       encoding="utf-8", env=env)
    print(f"\n$ wl.py {' '.join(cmd)}\n{r.stdout}{r.stderr}")
    if r.returncode:
        raise SystemExit(f"wl.py {cmd[0]} failed")
    return r.stdout


def main():
    tmp = Path(tempfile.mkdtemp(prefix="wowlink-test-"))
    sv_dir = tmp / "WTF" / "Account" / "TEST" / "SavedVariables"
    sv_dir.mkdir(parents=True)
    (tmp / "Logs").mkdir()
    env = dict(os.environ, WOWLINK_WOW_DIR=str(tmp), PYTHONIOENCODING="utf-8")

    # Goal written through wl.py (with a temp project copy so real goals/ stays untouched)
    proj = tmp / "proj"
    (proj / "tools").mkdir(parents=True)
    (proj / "WowLink").mkdir()
    for f in ADDON.glob("*"):
        (proj / "WowLink" / f.name).write_bytes(f.read_bytes())
    (proj / "tools" / "wl.py").write_bytes((ROOT / "tools" / "wl.py").read_bytes())
    global run_wl

    def run_wl(cmd):
        r = subprocess.run([sys.executable, str(proj / "tools" / "wl.py")] + cmd, capture_output=True, text=True,
                           encoding="utf-8", env=env)
        print(f"\n$ wl.py {' '.join(cmd)}\n{r.stdout}{r.stderr}")
        if r.returncode:
            raise SystemExit(f"wl.py {cmd[0]} failed")
        return r.stdout

    goal = {
        "title": "Finish Westfall to level 14",
        "summary": "Clear the Defias quests around Sentinel Hill before heading to Redridge.",
        "steps": [
            {"text": "Pick up 'The Defias Brotherhood'", "check": {"questInLog": 65}},
            {"text": "Collect 10 Linen Cloth", "check": {"item": 2589, "count": 10}},
            {"text": "Turn in quest 12", "check": {"quest": 12},
             "waypoint": {"map": 1436, "x": 56.3, "y": 47.5, "label": "Gryan Stoutmantle"}},
            {"text": "Reach level 14", "check": {"level": 14}},
            {"text": "Train new spells in Stormwind — Cathedral"},
        ],
        "tips": ["Linen drops from Defias Trappers."],
    }
    bad = subprocess.run([sys.executable, str(proj / "tools" / "wl.py"), "goal", "Testchar-Realm", "-"],
                         input=json.dumps({"title": "x", "steps": [{"txt": "typo"}]}), capture_output=True,
                         text=True, env=env)
    assert bad.returncode != 0 and "unknown key 'txt'" in bad.stderr, bad.stderr
    print("validation rejects bad goal: ok")
    (tmp / "goal.json").write_text(json.dumps(goal), encoding="utf-8")
    run_wl(["goal", "Testchar-Realm", str(tmp / "goal.json")])
    run_wl(["verdict", "Testchar-Realm", "6087", "Upgrade: replaces nothing, equip over your empty legs"])
    run_wl(["check"])
    # a chat AI's whole reply, with the goal in a fenced block plus verdicts; revises in place
    reply = ("Sounds good! Here's your goal:\n\n```json\n" + json.dumps({**goal, "verdicts": {"4680": "Vendor: weaker than your drops"}})
             + "\n```\nGood luck!")
    (tmp / "reply.txt").write_text(reply, encoding="utf-8")
    out = run_wl(["goal", "Testchar-Realm", str(tmp / "reply.txt"), "--keep-id"])
    assert "Goal #1" in out and "1 item verdict" in out

    # --- session 1 in the game
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUBS)
    g = lua.globals()
    for name in ("Inbox.lua", "Core.lua", "Tracker.lua", "Chat.lua"):
        lua.execute((proj / "WowLink" / name).read_text(encoding="utf-8"))
    g.FIRE("ADDON_LOADED", "WowLink")
    g.FIRE("PLAYER_LOGIN")
    st = g.WowLinkDB.chars["Testchar-Realm"].goalState
    assert st.done[1] and not st.done[2], "step 1 should auto-tick (quest 65 in log)"
    assert g.CHATLOG and g.COMBATLOG, "logging should be on by default"
    assert g.WowLinkTracker._shown, "tracker should show"

    g.STATE["items"][2589] = 10
    g.FIRE("BAG_UPDATE_DELAYED")
    assert st.done[2], "step 2 should tick at 10 linen"
    assert g.WAYPOINT and abs(g.WAYPOINT.position.x - 0.563) < 1e-6, "waypoint for step 3 should be set"
    g.STATE.completed[12] = True
    g.FIRE("QUEST_TURNED_IN", 12, 0, 0)
    assert st.done[3]
    g.WowLink.ToggleStep(g.WowLink, 3)  # player unticks: must stay unticked
    assert st.done[3] is False
    g.FIRE("QUEST_LOG_UPDATE")
    assert st.done[3] is False, "auto-check must not re-tick a step the player unticked"
    g.WowLink.ToggleStep(g.WowLink, 3)
    g.FIRE("CHAT_MSG_LOOT", "You receive loot: |cff1eff00|Hitem:6087::::::::14:::::|h[Chausses of Westfall]|h|r.")
    g.FIRE("CHAT_MSG_LOOT", "Bob receives loot: |cff1eff00|Hitem:6087::|h[Chausses of Westfall]|h|r.")
    assert len(g.WowLinkDB.chars["Testchar-Realm"].loot) == 1, "only own loot recorded"
    g.SlashCmdList.WOWLINK("note stuck finding the Defias hideout")
    tt = g.GameTooltip
    lines = []
    tt.AddLine = lambda self, t, *a: lines.append(t)
    g.TOOLTIP_FN(tt, lua.table(id=6087))
    assert lines and lines[0].startswith("Coach: Upgrade"), lines
    g.STATE.level = 14
    g.FIRE("PLAYER_LEVEL_UP", 14)

    # --- chat-AI path: /wl copy builds a report, /wl paste loads a reply, no files involved
    g.SlashCmdList.WOWLINK("copy")
    report = g.WowLinkTextWindow.edit.text
    assert "You are my World of Warcraft coach" in report and "=== WOWLINK REPORT ===" in report
    assert "Chausses of Westfall #6087" in report and "Agility 5" in report and "|" not in report, report[-800:]
    assert "Classic-era rules" in report
    assert "Chausses of Westfall #6087 (Leather LEGS, ilvl 21, req 16) [Bind on Equip, tradeable] [vendor 12s 34c]" in report, report
    assert "Bank: not seen yet" in report
    assert g.WowLinkDB.chars["Testchar-Realm"].bank is None, "bank must not be read while closed"
    g.FIRE("BANKFRAME_OPENED")
    g.FIRE("BANKFRAME_CLOSED")
    g.WowLink.char.exportedOnce = False
    g.SlashCmdList.WOWLINK("copy")
    report = g.WowLinkTextWindow.edit.text
    assert "Other items in bank (as of" in report and "Linen Cloth x10" in report, report[-600:]
    g.SlashCmdList.WOWLINK("copy")
    assert "=== WOWLINK UPDATE ===" in g.WowLinkTextWindow.edit.text, "second copy defaults to short update"
    # TomTom shows up (as if installed): WowLink should use its arrow from now on
    lua.execute("""TomTom = { added = {}, removed = {},
      AddWaypoint = function(self, m, x, y, o) local u = { m, x, y, title = o.title, crazy = o.crazy, from = o.from }
        table.insert(self.added, u); return u end,
      RemoveWaypoint = function(self, u) table.insert(self.removed, u) end }""")
    g.SlashCmdList.WOWLINK("paste")
    win = g.WowLinkTextWindow
    win.edit.text = "this has no json"
    win.b2._scripts["OnClick"]()
    assert "Couldn't find the goal" in win.status.text
    reply = ("Great, here’s the plan:\n\n```json\n"
             '{"goal": {"title": "Redridge \u2014 hit 16", "summary": "Go.", "steps": ['
             '{"text": "Reach level 16", "check": {"level": 16}}, "Train at Stormwind", '
             '{"text": "Go there", "waypoint": {"map": 1433, "x": 0.3, "y": 0.45}}], '
             '"tips": ["Bring food"]}, "verdicts": {"4680": "Vendor: your new drop is better"}}\n```\nHave fun!')
    win.edit.text = reply
    win.b2._scripts["OnClick"]()
    wl = g.WowLink
    assert wl.goal.title == "Redridge - hit 16", wl.goal.title
    assert wl.goal.steps[2].text == "Train at Stormwind" and abs(wl.goal.steps[3].waypoint.x - 30) < 1e-9
    assert wl.goal.id == 2 and wl.current == 1
    lines.clear()
    g.TOOLTIP_FN(tt, lua.table(id=4680))
    assert lines and lines[0] == "Coach: Vendor: your new drop is better", lines
    lua.execute('WowLink_ItemsUpdated = { ["Testchar-Realm"] = os.time() + 100 }')  # wl.py verdicts written later
    lines.clear()
    g.TOOLTIP_FN(tt, lua.table(id=4680))
    assert lines == ["Coach: Vendor: weaker than your drops"], lines
    lua.execute('WowLink_ItemsUpdated = {}')
    g.STATE.level = 16
    g.FIRE("PLAYER_LEVEL_UP", 16)
    assert wl.char.goalState.done[1] and wl.current == 2
    tt_ = g.TomTom
    g.WAYPOINT = None
    wl.ToggleStep(wl, 2)  # current -> step 3, which has a waypoint
    assert len(tt_.added) == 1 and tt_.added[1].crazy and tt_.added[1]["from"] == "WowLink", "TomTom arrow set"
    assert abs(tt_.added[1][2] - 0.3) < 1e-9 and g.WAYPOINT is None, "TomTom used instead of the map pin"
    wl.ToggleStep(wl, 3)  # goal complete -> WowLink's waypoint removed
    assert len(tt_.removed) == 1 and lua.eval("rawequal")(tt_.removed[1], tt_.added[1]), "old TomTom waypoint removed"
    g.SlashCmdList.WOWLINK("tomtom")  # off -> map pin instead
    wl.ToggleStep(wl, 3)  # untick: step 3 current again
    assert len(tt_.added) == 1 and g.WAYPOINT and abs(g.WAYPOINT.position.x - 0.3) < 1e-9, "map pin when TomTom off"
    wl.ToggleStep(wl, 3)
    assert g.WAYPOINT is None, "our map pin cleared on completion"
    g.SlashCmdList.WOWLINK("tomtom")
    wl.ToggleStep(wl, 3)  # leave step 3 open (unticked by player) for the checks below
    g.SlashCmdList.WOWLINK("sync")
    assert g.RELOADED
    g.FIRE("PLAYER_LOGOUT")

    (sv_dir / "WowLink.lua").write_text(g.SERIALIZE("WowLinkDB", g.WowLinkDB), encoding="utf-8")
    (tmp / "Logs" / "WoWChatLog.txt").write_text(
        "11/26 23:59:58.000  You receive loot: [Linen Cloth]x2.\n", encoding="utf-8")

    out = run_wl(["status"])
    assert "level 16" in out and "Redridge - hit 16" in out and "NEW" in out and "[>] current" in out
    out = run_wl(["loot"])
    assert "Chausses of Westfall" in out and "Agility 5" in out and "vs Legs" in out
    assert "Bind on Equip, tradeable, vendor 12s 34c" in out, out
    out = run_wl(["status", "--full"])
    assert "## Bank (1 kinds" in out
    run_wl(["done", "12", "65", "999"])
    prompt = run_wl(["prompt"])
    assert prompt.strip() in (ROOT / "PROMPT.md").read_text(encoding="utf-8"), "PROMPT.md is out of date: python tools/wl.py prompt"
    out = run_wl(["brief"])
    assert "You are my World of Warcraft coach" in out and "Chausses of Westfall" in out
    run_wl(["chat", "5"])

    # --- session 2: reload picks the same goal up without resetting progress
    lua2 = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua2.execute(STUBS)
    lua2.execute((sv_dir / "WowLink.lua").read_text(encoding="utf-8"))
    for name in ("Inbox.lua", "Core.lua", "Tracker.lua", "Chat.lua"):
        lua2.execute((proj / "WowLink" / name).read_text(encoding="utf-8"))
    g2 = lua2.globals()
    g2.STATE.level, g2.STATE["items"][2589], g2.STATE.completed[12] = 16, 10, True
    g2.FIRE("ADDON_LOADED", "WowLink")
    g2.FIRE("PLAYER_LOGIN")
    st2 = g2.WowLinkDB.chars["Testchar-Realm"].goalState
    assert g2.WowLink.goal.title == "Redridge - hit 16" and st2.done[1] and st2.done[2] and g2.WowLink.current == 3, "pasted goal and progress survive reload"
    lines2 = []
    g2.GameTooltip.AddLine = lambda self, t, *a: lines2.append(t)
    g2.TOOLTIP_FN(g2.GameTooltip, lua2.table(id=4680))
    assert lines2 == ["Coach: Vendor: your new drop is better"], lines2
    print("\nALL OK")


if __name__ == "__main__":
    main()
