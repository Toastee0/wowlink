"""WowLink bridge between your AI and the WowLink addon. Python 3.9+, standard library only.

  python tools/wl.py setup [PATH] [--copy]              find WoW, pick the game version, install the addon
  python tools/wl.py brief [CHAR]                       a paste-ready prompt + status for chat-only AIs
  python tools/wl.py prompt                             just the coaching prompt (same as PROMPT.md)
  python tools/wl.py status [CHAR] [--full] [--json]   what the character is up to
  python tools/wl.py chars                              characters with snapshots
  python tools/wl.py done QUESTID... [--char CHAR]      has the character turned these in?
  python tools/wl.py goal CHAR FILE|- [--keep-id]       set the current goal (validates, writes Inbox.lua);
                                                        FILE may be a whole AI reply containing a ```json block
  python tools/wl.py show CHAR                          print the current goal JSON
  python tools/wl.py clear CHAR                         remove the goal
  python tools/wl.py loot [CHAR] [--all]                recent drops with stats vs. equipped, plus live chat-log loot
  python tools/wl.py chat [N] [--grep REGEX]            tail the game's chat log (Logs/WoWChatLog.txt, live)
  python tools/wl.py combat [MINUTES] [CHAR]            kills, damage taken, deaths from the live combat log
  python tools/wl.py verdict CHAR ITEMID "text"|--clear  the AI's one-line verdict, shown in that item's tooltip
  python tools/wl.py render                             rebuild Inbox.lua from goals/ and verdicts/
  python tools/wl.py check                              syntax-check the addon's Lua (needs: pip install lupa)

The game writes SavedVariables only on /reload or logout, and reads Inbox.lua only
on /reload or login, so the player types /wl sync to exchange in both directions.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "WowLink"
GOALS = ROOT / "goals"
VERDICTS = ROOT / "verdicts"
CONFIG = ROOT / "wowlink.json"

sys.stdout.reconfigure(encoding="utf-8")

WOW_ROOTS = [r"C:\Program Files (x86)\World of Warcraft", r"C:\Program Files\World of Warcraft",
             r"C:\Games\World of Warcraft", r"D:\World of Warcraft", r"D:\Games\World of Warcraft",
             r"E:\World of Warcraft", "/Applications/World of Warcraft"]


def find_flavors(root):
    """Game-version folders (_retail_, _classic_era_, ...) under a WoW install."""
    root = Path(root)
    if (root / "WTF").is_dir() or (root / "Interface").is_dir():
        return [root]
    if not root.is_dir():
        return []
    return sorted(d for d in root.iterdir() if d.is_dir() and d.name.startswith("_") and d.name.endswith("_"))


def wow_dir():
    if os.environ.get("WOWLINK_WOW_DIR"):
        return Path(os.environ["WOWLINK_WOW_DIR"])
    if CONFIG.exists():
        return Path(json.loads(CONFIG.read_text(encoding="utf-8"))["wow_dir"])
    found = [f for r in WOW_ROOTS for f in find_flavors(r)]
    if len(found) == 1:
        return found[0]
    die("WoW folder not set up yet: run  python tools/wl.py setup"
        + (f"  (found {len(found)} game versions: {', '.join(str(f) for f in found)})" if found else ""))


class _LazyWow:
    """Path-like stand-in so WOW / "Logs" resolves the WoW folder only when first used."""
    def __truediv__(self, other):
        return wow_dir() / other

    def __str__(self):
        return str(wow_dir())


WOW = _LazyWow()


def inbox_path():
    """Inbox.lua inside the installed addon (a link back here, or a copy), else this repo's copy."""
    try:
        installed = WOW / "Interface" / "AddOns" / "WowLink"
        if (installed / "WowLink.toc").exists():
            return installed / "Inbox.lua"
    except SystemExit:
        pass
    return ADDON / "Inbox.lua"


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- Lua reading

class LuaReader:
    """Reads the subset of Lua that WoW writes to SavedVariables files."""

    NUM = re.compile(r"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)")
    NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
    ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
           "\\": "\\", '"': '"', "'": "'", "\n": "\n"}

    def __init__(self, text):
        self.s, self.i = text, 0

    def ws(self):
        s = self.s
        while self.i < len(s):
            if s[self.i] in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                if s.startswith("--[[", self.i):
                    j = s.find("]]", self.i)
                    self.i = len(s) if j < 0 else j + 2
                else:
                    j = s.find("\n", self.i)
                    self.i = len(s) if j < 0 else j + 1
            else:
                break

    def expect(self, ch):
        self.ws()
        if self.s[self.i] != ch:
            raise ValueError(f"expected {ch!r} at {self.i}")
        self.i += 1

    def string(self):
        q = self.s[self.i]
        self.i += 1
        out = []
        while True:
            c = self.s[self.i]
            if c == q:
                self.i += 1
                return "".join(out)
            if c == "\\":
                n = self.s[self.i + 1]
                if n.isdigit():
                    m = re.match(r"\d{1,3}", self.s[self.i + 1:])
                    out.append(chr(int(m.group())))
                    self.i += 1 + len(m.group())
                    continue
                out.append(self.ESC.get(n, n))
                self.i += 2
                continue
            out.append(c)
            self.i += 1

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.table()
        if c in "\"'":
            return self.string()
        m = self.NUM.match(self.s, self.i)
        if m:
            self.i = m.end()
            t = m.group()
            if "x" in t.lower():
                return int(t, 16)
            return float(t) if any(ch in t for ch in ".eE") else int(t)
        m = self.NAME.match(self.s, self.i)
        if m:
            self.i = m.end()
            return {"true": True, "false": False, "nil": None, "inf": float("inf"), "nan": None}.get(m.group(), m.group())
        if self.s.startswith("-inf", self.i):
            self.i += 4
            return float("-inf")
        raise ValueError(f"unexpected {c!r} at {self.i}")

    def table(self):
        self.i += 1
        d, n = {}, 0
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                break
            if self.s[self.i] == "[":
                self.i += 1
                k = self.value()
                self.expect("]")
                self.expect("=")
                d[k] = self.value()
            else:
                m = self.NAME.match(self.s, self.i)
                j = m and m.end()
                if m and re.match(r"\s*=(?!=)", self.s[j:]):
                    self.i = j
                    self.expect("=")
                    d[m.group()] = self.value()
                else:
                    n += 1
                    d[n] = self.value()
            self.ws()
            if self.s[self.i] in ",;":
                self.i += 1
        if d and all(isinstance(k, int) for k in d) and sorted(d) == list(range(1, len(d) + 1)):
            return [d[k] for k in range(1, len(d) + 1)]
        if not d:
            return []
        return {str(k): v for k, v in d.items()}

    def chunk(self):
        out = {}
        while True:
            self.ws()
            if self.i >= len(self.s):
                return out
            m = self.NAME.match(self.s, self.i)
            if not m:
                raise ValueError(f"expected name at {self.i}")
            self.i = m.end()
            self.expect("=")
            out[m.group()] = self.value()


# ---------------------------------------------------------------- Lua writing

LUA_KEYWORDS = set("and break do else elseif end false for function if in local nil not or repeat return then true until while".split())
ASCII_FIX = {"\u2014": "-", "\u2013": "-", "\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"',
             "\u2026": "...", "\u00a0": " ", "\u2192": "->", "\u2022": "*"}


def ascii_fix(v):
    """Typographic punctuation -> plain ASCII (WoW's default fonts render it more reliably)."""
    if isinstance(v, str):
        for a, b in ASCII_FIX.items():
            v = v.replace(a, b)
        return v
    if isinstance(v, list):
        return [ascii_fix(x) for x in v]
    if isinstance(v, dict):
        return {k: ascii_fix(x) for k, x in v.items()}
    return v


def lua_str(s):
    s = ascii_fix(s)
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ord(ch) < 32:
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def to_lua(v, ind=1):
    pad = "\t" * ind
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "nil"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(round(v, 4))
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, list):
        if not v:
            return "{}"
        return "{\n" + "".join(f"{pad}{to_lua(x, ind + 1)},\n" for x in v) + "\t" * (ind - 1) + "}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        lines = []
        for k, x in v.items():
            key = k if re.fullmatch(r"[A-Za-z_]\w*", k) and k not in LUA_KEYWORDS else "[" + lua_str(k) + "]"
            lines.append(f"{pad}{key} = {to_lua(x, ind + 1)},\n")
        return "{\n" + "".join(lines) + "\t" * (ind - 1) + "}"
    raise TypeError(type(v))


# ---------------------------------------------------------------- game files

def account_dirs():
    base = WOW / "WTF" / "Account"
    if not base.is_dir():
        return []  # fresh install: nobody has logged in yet
    return [d for d in base.iterdir() if d.is_dir() and d.name != "SavedVariables"]


def saved_vars_path():
    accts = account_dirs()
    hits = [a / "SavedVariables" / "WowLink.lua" for a in accts if (a / "SavedVariables" / "WowLink.lua").exists()]
    if hits:
        return max(hits, key=lambda p: p.stat().st_mtime)
    return None


def load_db():
    p = saved_vars_path()
    if not p:
        return None, None
    data = LuaReader(p.read_text(encoding="utf-8", errors="replace")).chunk()
    db = data.get("WowLinkDB") or {}
    if isinstance(db.get("chars"), list):
        db["chars"] = {}
    # early addon versions keyed "Name-" when the client gave no realm
    db["chars"] = {k.rstrip("-"): v for k, v in (db.get("chars") or {}).items()}
    return db, p


def resolve_char(name, db, allow_new=False):
    keys = set((db or {}).get("chars", {}) or {}) | {p.stem for p in GOALS.glob("*.json")}
    if not name:
        chars = (db or {}).get("chars") or {}
        dated = [(c.get("snapshot", {}).get("t", 0), k) for k, c in chars.items() if isinstance(c, dict)]
        if not dated:
            die("no characters yet: log in with the addon enabled, then /wl sync")
        return max(dated)[1]
    low = name.lower()
    exact = [k for k in keys if k.lower() == low]
    if exact:
        return exact[0]
    part = [k for k in keys if k.lower().split("-")[0] == low]
    if len(part) == 1:
        return part[0]
    if len(part) > 1:
        die(f"{name!r} is ambiguous: {', '.join(sorted(part))}")
    if allow_new:
        return name
    die(f"unknown character {name!r}; known: {', '.join(sorted(keys)) or 'none'}")


# ---------------------------------------------------------------- formatting

def ago(t):
    if not t:
        return "never"
    d = time.time() - t
    if d < 90:
        return "just now"
    if d < 5400:
        return f"{round(d / 60)}m ago"
    if d < 172800:
        return f"{round(d / 3600)}h ago"
    return f"{round(d / 86400)}d ago"


def coins(c):
    c = int(c or 0)
    g, s, cp = c // 10000, (c // 100) % 100, c % 100
    return " ".join(x for x in [f"{g}g" if g else "", f"{s}s" if s else "", f"{cp}c"] if x)


def load_goal(key):
    p = GOALS / f"{key}.json"
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def cmd_status(args):
    full, as_json = "--full" in args, "--json" in args
    args = [a for a in args if not a.startswith("--")]
    db, path = load_db()
    if db is None:
        die("no WowLink SavedVariables yet: enable the addon, log in, then /wl sync")
    key = resolve_char(args[0] if args else None, db)
    c = db["chars"].get(key)
    if not isinstance(c, dict):
        die(f"no snapshot for {key} yet")
    if as_json:
        print(json.dumps(c, indent=1, ensure_ascii=False))
        return
    s = c.get("snapshot") or {}
    out = []
    w = out.append
    age = time.time() - s.get("t", 0)
    w(f"# {key}: level {s.get('level')} {s.get('race', '')} {s.get('class', '')}  (snapshot {ago(s.get('t'))})")
    if age > 1800:
        w(f"!! Snapshot is {ago(s.get('t'))} old. If they're playing now, ask them to /wl sync first.")
    xp, xpmax = s.get("xp") or 0, s.get("xpMax") or 1
    w(f"XP {xp}/{xpmax} ({100 * xp // max(xpmax, 1)}%), rested {s.get('rested') or 0}  |  money {coins(s.get('money'))}  |  hearth {s.get('hearth')}")
    loc = s.get("zone", "?") + (f" > {s['subzone']}" if s.get("subzone") else "")
    if s.get("mapID"):
        loc += f"  [map {s['mapID']} {s.get('mapName', '')}" + (f", in {s['parentMap']}" if s.get("parentMap") else "") + "]"
    if s.get("x") is not None:
        loc += f" @ {s['x']}, {s['y']}"
    w("Location: " + loc + ("  (DEAD/GHOST)" if s.get("dead") else ""))
    if s.get("talentPoints"):
        w(f"Unspent talent points: {s['talentPoints']}")

    goal, st = load_goal(key), c.get("goalState") or {}
    imp = c.get("imported")  # pasted in game with /wl paste; newest goal wins, as in the addon
    if isinstance(imp, dict) and (not goal or imp.get("updated", 0) >= goal.get("updated", 0)):
        goal = imp
    w("")
    if goal:
        synced = st.get("id") == goal.get("id")
        w(f"## Current goal #{goal['id']}: {goal['title']}  (written {ago(goal.get('updated'))}"
          + (f", in game since {ago(st.get('received'))})" if synced else ", NOT in game yet: player needs /wl sync)"))
        done = st.get("done") or {}
        if isinstance(done, list):
            done = {str(i + 1): v for i, v in enumerate(done)}
        first = True
        for i, step in enumerate(goal["steps"], 1):
            d = done.get(str(i)) if synced else None
            if d:
                mark = f"[x] (auto {ago(d.get('t'))})" if d.get("how") == "auto" else f"[x] (ticked by player {ago(d.get('t'))})"
            elif d is False:
                mark = "[>] current (player unticked)" if first else "[ ] (player unticked)"
                first = False
            elif first:
                mark, first = "[>] current", False
            else:
                mark = "[ ]"
            w(f"  {i}. {mark} {step['text']}")
        if synced and st.get("completed"):
            w(f"  GOAL COMPLETE {ago(st['completed'])}")
    else:
        w("## No current goal")

    notes = c.get("notes") or []
    if notes:
        since = (goal or {}).get("updated", 0)
        w("\n## Notes from the player (/wl note)")
        for n in notes[-15:]:
            w(f"- {'NEW ' if n.get('t', 0) >= since else ''}{ago(n.get('t'))}: {n.get('text')}")

    j = c.get("journal") or []
    if j:
        w(f"\n## Journal (last {min(len(j), 25)} of {len(j)})")
        for e in j[-25:]:
            w(f"- {ago(e.get('t'))} [L{e.get('lvl')} {e.get('zone', '')}] {e.get('e')}")

    qs = s.get("quests") or []
    w(f"\n## Quest log ({len(qs)})")
    for q in qs:
        flag = " COMPLETE" if q.get("complete") else (" FAILED" if q.get("failed") else "")
        w(f"- [{q.get('level')}] {q.get('title')} (#{q.get('id')}){flag}")
        for o in q.get("obj") or []:
            w(f"    {o}")

    sk = s.get("skills") or []
    prof = [x for x in sk if x.get("cat") in ("Professions", "Secondary Skills")]
    if prof:
        w("\n## Professions: " + ", ".join(f"{x['name']} {x.get('rank')}/{x.get('max')}" for x in prof))
    eq = s.get("equipment") or []
    if eq:
        w("\n## Equipped (ilvl)")
        w("; ".join(f"{e.get('equipSlot')}: {e.get('name')} ({e.get('ilvl')})" for e in eq))
    loot = [x for x in (c.get("loot") or []) if x.get("slot")]
    if loot:
        w(f"\n## Recent gear drops (details: wl.py loot)")
        for x in loot[-8:]:
            w(f"- {ago(x.get('t'))}: {x.get('name')} ({QUALITY.get(x.get('q'), '?')}, {x.get('slot')}, ilvl {x.get('ilvl')}, req {x.get('req')}) #{x.get('id')}")
    comp = s.get("completedQuests") or []
    w(f"\nCompleted quests: {len(comp)} (check specific ones with: wl.py done ID...)")
    if full:
        other = [x for x in sk if x not in prof]
        if other:
            w("\n## Other skills: " + ", ".join(f"{x['name']} {x.get('rank')}/{x.get('max')}" for x in other))
        bags = s.get("bags") or []
        w(f"\n## Bags ({len(bags)} kinds)")
        w("; ".join(f"{b.get('name')} x{b.get('n')} (#{b.get('id')})" for b in bags))
        bank = c.get("bank") or {}
        if bank:
            items = bank.get("items") or []
            w(f"\n## Bank ({len(items)} kinds, as of {ago(bank.get('t'))})")
            w("; ".join(f"{b.get('name')} x{b.get('n')} (#{b.get('id')})" for b in items))
        else:
            w("\nBank: not seen yet (recorded when the player opens their bank).")
    print("\n".join(out))


def cmd_chars(args):
    db, path = load_db()
    if not db:
        die("no WowLink SavedVariables yet")
    print(f"(from {path})")
    for k, c in sorted((db.get("chars") or {}).items()):
        s = c.get("snapshot") or {}
        g = load_goal(k)
        print(f"{k}: level {s.get('level')} {s.get('class')} in {s.get('zone')}, snapshot {ago(s.get('t'))}"
              + (f", goal #{g['id']}: {g['title']}" if g else ", no goal"))


def cmd_done(args):
    char = None
    if "--char" in args:
        i = args.index("--char")
        char = args[i + 1]
        args = args[:i] + args[i + 2:]
    db, _ = load_db()
    key = resolve_char(char, db)
    s = (db["chars"].get(key) or {}).get("snapshot") or {}
    comp = set(s.get("completedQuests") or [])
    inlog = {q.get("id"): q.get("title") for q in s.get("quests") or []}
    for a in args:
        qid = int(a)
        state = "turned in" if qid in comp else (f"in quest log ({inlog[qid]})" if qid in inlog else "not done, not in log")
        print(f"{qid}: {state}")


# ---------------------------------------------------------------- loot and logs

QUALITY = {0: "poor", 1: "common", 2: "uncommon", 3: "rare", 4: "epic", 5: "legendary", 6: "artifact", 7: "heirloom"}
SLOT_MAP = {"HEAD": ["Head"], "NECK": ["Neck"], "SHOULDER": ["Shoulder"], "BODY": ["Shirt"], "CHEST": ["Chest"],
            "ROBE": ["Chest"], "WAIST": ["Waist"], "LEGS": ["Legs"], "FEET": ["Feet"], "WRIST": ["Wrist"],
            "HAND": ["Hands"], "FINGER": ["Finger1", "Finger2"], "TRINKET": ["Trinket1", "Trinket2"],
            "CLOAK": ["Back"], "WEAPON": ["MainHand", "OffHand"], "2HWEAPON": ["MainHand", "OffHand"],
            "WEAPONMAINHAND": ["MainHand"], "WEAPONOFFHAND": ["OffHand"], "SHIELD": ["OffHand"],
            "HOLDABLE": ["OffHand"], "RANGED": ["Ranged"], "RANGEDRIGHT": ["Ranged"], "THROWN": ["Ranged"],
            "RELIC": ["Ranged"], "TABARD": ["Tabard"]}


def fmt_stats(st):
    if not st:
        return "no stats"
    st = {k: v for k, v in st.items() if not re.fullmatch(r"RESISTANCE[1-6]_NAME", k)}
    return ", ".join(f"{k.replace('_', ' ').title()} {round(v, 1):g}" if isinstance(v, (int, float)) else f"{k} {v}"
                     for k, v in sorted(st.items()))


def fmt_item(x):
    trade = ""
    b = x.get("bound")
    if b is True:
        trade = ", soulbound"
    elif b == "some":
        trade = ", some soulbound"
    elif b is False:
        trade = ", Bind on Equip, tradeable" if x.get("bind") == "BoE" else ", tradeable"
    if x.get("vendor") and b is not None:
        trade += f", vendor {coins(x['vendor'])}"
    return (f"{x.get('name')} #{x.get('id')} [{QUALITY.get(x.get('q'), '?')} {x.get('sub') or x.get('type') or ''}"
            f" {x.get('slot') or ''}, ilvl {x.get('ilvl')}, req {x.get('req')}{trade}]: {fmt_stats(x.get('stats'))}")


def chat_log_path():
    p = WOW / "Logs" / "WoWChatLog.txt"
    return p if p.exists() else None


def tail_lines(path, max_bytes=2_000_000):
    with open(path, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - max_bytes))
        data = fh.read().decode("utf-8", errors="replace")
    lines = data.splitlines()
    return lines[1:] if size > max_bytes else lines


def chat_time(line):
    m = re.match(r"(\d+)/(\d+) (\d+):(\d+):(\d+)", line)
    if not m:
        return None
    mo, d, h, mi, s = map(int, m.groups())
    now = time.localtime()
    year = now.tm_year - (1 if (mo, d) > (now.tm_mon, now.tm_mday) else 0)
    return time.mktime((year, mo, d, h, mi, s, 0, 0, -1))


def cmd_loot(args):
    show_all = "--all" in args
    args = [a for a in args if not a.startswith("--")]
    db, _ = load_db()
    key = resolve_char(args[0] if args else None, db)
    c = db["chars"].get(key) or {}
    s = c.get("snapshot") or {}
    equipped = {e.get("equipSlot"): e for e in s.get("equipment") or []}
    print(f"# Loot for {key} (level {s.get('level')} {s.get('class')}), recorded by the addon up to {ago(s.get('t'))}")
    loot = c.get("loot") or []
    gear = loot if show_all else [x for x in loot if x.get("slot")]
    for x in gear[-25:]:
        print(f"\n- {ago(x.get('t'))} in {x.get('zone')}: {fmt_item(x)}" + (f" x{x['n']}" if (x.get('n') or 1) > 1 else ""))
        for slot in SLOT_MAP.get(x.get("slot") or "", []):
            e = equipped.get(slot)
            print(f"    vs {slot}: " + (fmt_item(e) if e else "(empty)"))
    bank = c.get("bank") or {}
    for label, items in (("bags", s.get("bags")), (f"bank (as of {ago(bank.get('t'))})", bank.get("items"))):
        gear = [b for b in items or [] if b.get("slot")]
        if gear:
            print(f"\n## Unequipped gear in {label}")
            for b in gear:
                print(f"- {fmt_item(b)}")
    p = chat_log_path()
    if p:
        since = s.get("t", 0)
        live = [l for l in tail_lines(p) if "You receive" in l or "You create" in l]
        live = [l for l in live if (chat_time(l) or 0) > since]
        if live:
            print(f"\n## Since that snapshot (live chat log, names only; /wl sync for stats)")
            for l in live[-30:]:
                print("- " + l)


def cmd_chat(args):
    n, pat = 60, None
    if "--grep" in args:
        i = args.index("--grep")
        pat = re.compile(args[i + 1], re.I)
        args = args[:i] + args[i + 2:]
    if args:
        n = int(args[0])
    p = chat_log_path()
    if not p:
        die("no Logs/WoWChatLog.txt yet: chat logging starts when the addon loads (or type /chatlog)")
    lines = tail_lines(p)
    if pat:
        lines = [l for l in lines if pat.search(l)]
    print(f"(from {p}, modified {ago(p.stat().st_mtime)})")
    print("\n".join(lines[-n:]))


DMG_EVENTS = ("SWING_DAMAGE", "RANGE_DAMAGE", "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE", "ENVIRONMENTAL_DAMAGE")


def parse_combat_line(line):
    import csv
    m = re.match(r"(\d+)/(\d+)/(\d+) (\d+):(\d+):(\d+)(?:\.\d+)?\s+(.*)", line)
    if not m:
        return None
    mo, d, y, h, mi, s = map(int, m.groups()[:6])
    t = time.mktime((y, mo, d, h, mi, s, 0, 0, -1))
    try:
        fields = next(csv.reader([m.group(7)]))
    except Exception:
        return None
    return t, fields


def cmd_combat(args):
    minutes = int(args[0]) if args else 30
    db, _ = load_db()
    key = resolve_char(args[1] if len(args) > 1 else None, db)
    me = key.split("-")[0]
    logs = sorted((WOW / "Logs").glob("WoWCombatLog*.txt"), key=lambda p: p.stat().st_mtime)
    if not logs:
        die("no combat log yet: combat logging starts when the addon loads (or type /combatlog)")
    p = logs[-1]
    cutoff = time.time() - minutes * 60
    is_me = lambda n: n == me or n.startswith(me + "-")
    kills, deaths, recent_hits = {}, [], []
    taken = 0
    for line in tail_lines(p, 20_000_000):
        r = parse_combat_line(line)
        if not r or r[0] < cutoff:
            continue
        t, f = r
        ev = f[0]
        if len(f) < 9:
            continue
        src, dst = f[2], f[6]
        if ev == "PARTY_KILL" and is_me(src):
            kills[dst] = kills.get(dst, 0) + 1
        elif ev in DMG_EVENTS and is_me(dst):
            spell = f[10] if ev.startswith(("SPELL", "RANGE")) and len(f) > 10 else ("melee" if ev == "SWING_DAMAGE" else f[9])
            base = 9 if ev == "SWING_DAMAGE" else (10 if ev == "ENVIRONMENTAL_DAMAGE" else 12)
            if len(f) > base + 17 and re.match(r"(Player|Creature|Pet|Vehicle|0000)", f[base] or ""):
                base += 17  # advanced combat logging inserts unit info before the amount
            amt = f[base] if len(f) > base else "?"
            try:
                taken += int(amt)
            except ValueError:
                pass
            recent_hits.append((t, f"{src or 'environment'}: {spell} for {amt}"))
            recent_hits = recent_hits[-10:]
        elif ev == "UNIT_DIED" and is_me(dst):
            deaths.append((t, list(recent_hits[-6:])))
    print(f"# Combat, last {minutes} min, {key} (from {p.name}, modified {ago(p.stat().st_mtime)})")
    print(f"Killing blows: {sum(kills.values())}" + (": " + ", ".join(f"{k} x{v}" for k, v in sorted(kills.items(), key=lambda kv: -kv[1])) if kills else ""))
    print(f"Damage taken (approx): {taken}")
    for t, hits in deaths:
        print(f"\nDIED {ago(t)}; last hits:")
        for ht, h in hits:
            print(f"  -{int(t - ht)}s {h}")
    if not deaths:
        print("No deaths.")


def cmd_verdict(args):
    if len(args) < 2:
        die('usage: wl.py verdict CHAR ITEMID "text" | wl.py verdict CHAR ITEMID --clear')
    db, _ = load_db()
    key = resolve_char(args[0], db, allow_new=True)
    path = VERDICTS / f"{key}.json"
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    item = str(int(args[1]))
    if len(args) > 2 and args[2] == "--clear":
        data.pop(item, None)
    elif len(args) > 2:
        text = " ".join(args[2:])
        if len(text) > 90:
            die("keep verdicts under 90 chars; they show in a tooltip")
        data[item] = ascii_fix(text)
    else:
        die("give the verdict text or --clear")
    VERDICTS.mkdir(exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    render_inbox()
    print(f"{key}: {len(data)} item verdict(s). /wl sync to see them in tooltips.")


# ---------------------------------------------------------------- goals

CHECK_TYPES = {"level": int, "quest": int, "questInLog": int, "item": int, "count": int, "money": int,
               "zone": (int, str), "skill": str, "rank": int}


def validate(g):
    errs = []

    def keys(obj, allowed, where):
        if not isinstance(obj, dict):
            errs.append(f"{where} must be an object")
            return False
        for k in obj:
            if k not in allowed:
                errs.append(f"{where}: unknown key {k!r} (allowed: {', '.join(allowed)})")
        return True

    if not keys(g, ["title", "summary", "steps", "tips"], "goal"):
        return errs
    if not isinstance(g.get("title"), str) or not g["title"].strip():
        errs.append("goal.title is required")
    elif len(g["title"]) > 48:
        errs.append("goal.title over 48 chars (it's a one-line tracker header)")
    if "summary" in g and not isinstance(g["summary"], str):
        errs.append("goal.summary must be a string")
    if "tips" in g and not (isinstance(g["tips"], list) and all(isinstance(t, str) for t in g["tips"])):
        errs.append("goal.tips must be a list of strings")
    steps = g.get("steps")
    if not isinstance(steps, list) or not steps:
        errs.append("goal.steps must be a non-empty list")
        return errs
    if len(steps) > 12:
        errs.append("more than 12 steps: split it into a smaller goal")
    for i, s in enumerate(steps, 1):
        w = f"steps[{i}]"
        if not keys(s, ["text", "detail", "check", "waypoint"], w):
            continue
        if not isinstance(s.get("text"), str) or not s["text"].strip():
            errs.append(f"{w}.text is required")
        if "detail" in s and not isinstance(s["detail"], str):
            errs.append(f"{w}.detail must be a string")
        if "check" in s and keys(s["check"], list(CHECK_TYPES), f"{w}.check"):
            if not s["check"]:
                errs.append(f"{w}.check is empty")
            for k, v in s["check"].items():
                t = CHECK_TYPES.get(k)
                if t and (not isinstance(v, t) or isinstance(v, bool)):
                    errs.append(f"{w}.check.{k} has the wrong type")
            if "count" in s["check"] and "item" not in s["check"]:
                errs.append(f"{w}.check.count needs item")
            if "rank" in s["check"] and "skill" not in s["check"]:
                errs.append(f"{w}.check.rank needs skill")
        if "waypoint" in s and keys(s["waypoint"], ["map", "x", "y", "label"], f"{w}.waypoint"):
            wp = s["waypoint"]
            if not isinstance(wp.get("map"), int):
                errs.append(f"{w}.waypoint.map must be a uiMapID integer")
            for ax in ("x", "y"):
                v = wp.get(ax)
                if not isinstance(v, (int, float)) or isinstance(v, bool) or not 0 <= v <= 100:
                    errs.append(f"{w}.waypoint.{ax} must be 0-100 (map percent, like guide coords)")
    return errs


def render_inbox():
    entries = {}
    for p in sorted(GOALS.glob("*.json")):
        entries[p.stem] = json.loads(p.read_text(encoding="utf-8"))
    items, stamps = {}, {}
    for p in sorted(VERDICTS.glob("*.json")):
        v = json.loads(p.read_text(encoding="utf-8"))
        items[p.stem] = v
        stamps[p.stem] = int(p.stat().st_mtime)  # newest verdict source wins in game
    items_lua = "{\n" + "".join(
        f"\t[{lua_str(k)}] = {{\n" + "".join(f"\t\t[{int(i)}] = {lua_str(t)},\n" for i, t in v.items()) + "\t},\n"
        for k, v in items.items()) + "}"
    body = to_lua(entries) if entries else "{\n}"
    text = ("-- Generated by tools/wl.py from goals/*.json and verdicts/*.json. Do not edit by hand.\n"
            f"WowLink_Inbox = {body}\n\nWowLink_Items = {items_lua}\n\n"
            f"WowLink_ItemsUpdated = {to_lua(stamps) if stamps else '{}'}\n")
    inbox = inbox_path()
    inbox.write_text(text, encoding="utf-8", newline="\n")
    lua_ok = check_lua_file(inbox)
    if lua_ok is False:
        die("generated Inbox.lua failed the Lua syntax check (bug in wl.py)")
    return len(entries)


def extract_json(raw):
    """Accept bare JSON, or a whole chat reply with the goal in a ```json block."""
    raw = raw.strip().lstrip("﻿")
    blocks = re.findall(r"```(?:json)?\s*\n(.*?)```", raw, re.S)
    candidates = blocks + [raw]
    dec = json.JSONDecoder()
    for c in candidates:
        c = c.strip()
        start = c.find("{")
        if start < 0:
            continue
        try:
            obj, _ = dec.raw_decode(c[start:])
            return obj
        except json.JSONDecodeError as e:
            err = e
    die("no goal JSON found" + (f" ({err})" if "err" in locals() else "") +
        ". Paste the AI's reply or just its ```json block.")


def cmd_goal(args):
    keep = "--keep-id" in args
    args = [a for a in args if a != "--keep-id"]
    if len(args) != 2:
        die("usage: wl.py goal CHAR FILE.json|- [--keep-id]")
    db, _ = load_db()
    key = resolve_char(args[0], db, allow_new=True)
    raw = sys.stdin.read() if args[1] == "-" else Path(args[1]).read_text(encoding="utf-8")
    g = extract_json(raw)
    verdicts = g.pop("verdicts", None) if isinstance(g, dict) else None
    errs = validate(g)
    if verdicts is not None and not (isinstance(verdicts, dict) and all(isinstance(v, str) and len(v) <= 90 for v in verdicts.values())
                                     and all(str(k).isdigit() for k in verdicts)):
        errs.append('verdicts must be {"itemID": "text up to 90 chars", ...}')
    if errs:
        die("goal rejected:\n  " + "\n  ".join(errs))
    g = ascii_fix(g)
    old = load_goal(key)
    sv_id = (((db or {}).get("chars") or {}).get(key) or {}).get("goalState", {}).get("id") or 0
    if keep and old:
        gid = old["id"]
    else:
        gid = max(old["id"] if old else 0, sv_id) + 1
        if old:
            hist = GOALS / "history" / key
            hist.mkdir(parents=True, exist_ok=True)
            (hist / f"{old['id']:04d}.json").write_text(json.dumps(old, indent=2, ensure_ascii=False), encoding="utf-8")
    goal = {"id": gid, "updated": int(time.time()), **g}
    GOALS.mkdir(exist_ok=True)
    (GOALS / f"{key}.json").write_text(json.dumps(goal, indent=2, ensure_ascii=False), encoding="utf-8")
    if verdicts:
        path = VERDICTS / f"{key}.json"
        data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        data.update({str(int(k)): ascii_fix(v) for k, v in verdicts.items()})
        VERDICTS.mkdir(exist_ok=True)
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"{len(verdicts)} item verdict(s) saved.")
    render_inbox()
    print(f"Goal #{gid} for {key}: {goal['title']} ({len(goal['steps'])} steps)"
          + (" [revised in place, progress kept]" if keep and old else ""))
    print("Player: type /wl sync in game (or /reload) to load it.")


def cmd_show(args):
    db, _ = load_db()
    key = resolve_char(args[0] if args else None, db)
    g = load_goal(key)
    print(json.dumps(g, indent=2, ensure_ascii=False) if g else f"no goal for {key}")


def cmd_clear(args):
    db, _ = load_db()
    key = resolve_char(args[0] if args else None, db)
    p = GOALS / f"{key}.json"
    if p.exists():
        old = json.loads(p.read_text(encoding="utf-8"))
        hist = GOALS / "history" / key
        hist.mkdir(parents=True, exist_ok=True)
        (hist / f"{old['id']:04d}.json").write_text(json.dumps(old, indent=2, ensure_ascii=False), encoding="utf-8")
        p.unlink()
    render_inbox()
    print(f"Cleared goal for {key}.")


# ---------------------------------------------------------------- lua checks / install

def check_lua_file(path):
    """True/False for syntax ok, None if lupa is not installed."""
    try:
        import lupa.lua51 as lupa
    except ImportError:
        return None
    rt = lupa.LuaRuntime()
    ok, err = rt.eval("function(src, name) local f, e = loadstring(src, name); return f ~= nil, e end")(
        Path(path).read_text(encoding="utf-8"), "@" + Path(path).name)
    if not ok:
        print(f"  {err}", file=sys.stderr)
    return bool(ok)


def cmd_check(args):
    bad = 0
    for p in sorted(ADDON.glob("*.lua")):
        r = check_lua_file(p)
        if r is None:
            die("lupa not installed: python -m pip install --user lupa")
        print(f"{'ok  ' if r else 'FAIL'} {p.name}")
        bad += not r
    sys.exit(1 if bad else 0)


def cmd_setup(args):
    copy = "--copy" in args
    args = [a for a in args if not a.startswith("--")]
    roots = [args[0]] if args else WOW_ROOTS
    found = [f for r in roots for f in find_flavors(r)]
    if not found:
        die("couldn't find World of Warcraft. Pass its folder, e.g.\n"
            '  python tools/wl.py setup "D:\\Games\\World of Warcraft"')
    if len(found) == 1:
        flavor = found[0]
    else:
        print("Which game version do you play?")
        for i, f in enumerate(found, 1):
            print(f"  {i}. {f.name}   ({f})")
        if not sys.stdin.isatty():
            die("several found; rerun with the one you want, e.g.  python tools/wl.py setup \"" + str(found[0]) + '"')
        try:
            pick = input("Number: ").strip()
        except EOFError:
            die("several found; rerun with the one you want, e.g.  python tools/wl.py setup \"" + str(found[0]) + '"')
        if not pick.isdigit() or not 1 <= int(pick) <= len(found):
            die("no choice made")
        flavor = found[int(pick) - 1]
    CONFIG.write_text(json.dumps({"wow_dir": str(flavor)}, indent=2), encoding="utf-8")
    print(f"WoW folder: {flavor}  (saved in {CONFIG.name})")

    dst = flavor / "Interface" / "AddOns" / "WowLink"
    dst.parent.mkdir(parents=True, exist_ok=True)
    linked = False
    try:
        linked = dst.exists() and dst.resolve() == ADDON.resolve()
    except OSError:
        pass
    if linked:
        print("Addon already linked to this folder.")
    elif copy or (dst.exists() and not dst.is_symlink()):
        import shutil
        dst.mkdir(exist_ok=True)
        for f in ADDON.iterdir():
            if f.name == "Inbox.lua" and (dst / "Inbox.lua").exists():
                continue  # keep the player's current goals
            shutil.copy2(f, dst / f.name)
        print(f"Addon copied to {dst}. Rerun setup after updating WowLink to copy the new version.")
    else:
        if os.name == "nt":
            r = subprocess.run(["cmd", "/c", "mklink", "/J", str(dst), str(ADDON)], capture_output=True, text=True)
            ok = r.returncode == 0
        else:
            try:
                os.symlink(ADDON, dst, target_is_directory=True)
                ok = True
            except OSError:
                ok = False
        if not ok:
            die(f"couldn't link {dst}; try:  python tools/wl.py setup --copy")
        print(f"Addon linked: {dst} -> {ADDON}")
    n = render_inbox()
    print(f"Inbox ready ({n} goal(s)). Start the game, enable WowLink in the AddOns list, log in, and type /wl sync.")


def coach_prompt():
    """The coaching prompt; WowLink/Chat.lua is the single source (the in-game /wl copy uses it too)."""
    src = (ADDON / "Chat.lua").read_text(encoding="utf-8")
    return re.search(r"local PROMPT = \[\[\n?(.*?)\]\]", src, re.S).group(1)


def cmd_brief(args):
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cmd_status(args)
        print()
        cmd_loot(args)
    print(coach_prompt())
    print("=== WOWLINK REPORT ===")
    print(buf.getvalue())


COMMANDS = {"status": cmd_status, "chars": cmd_chars, "done": cmd_done, "goal": cmd_goal, "show": cmd_show,
            "clear": cmd_clear, "render": lambda a: print(f"Inbox.lua: {render_inbox()} goal(s)"),
            "check": cmd_check, "setup": cmd_setup, "install": cmd_setup, "loot": cmd_loot, "chat": cmd_chat,
            "combat": cmd_combat, "verdict": cmd_verdict, "brief": cmd_brief,
            "prompt": lambda a: print(coach_prompt(), end="")}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(0 if len(sys.argv) < 2 else 1)
    COMMANDS[sys.argv[1]](sys.argv[2:])
