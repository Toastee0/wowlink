# WowLink

**Talk your World of Warcraft progress over with an AI, and get one clear goal in your quest tracker.**

WowLink is an addon plus a small helper script. The addon records where your character is at:
level, zone, quest log and objectives, gear with stats, recent loot, a journal of what happened,
and notes you leave. Your AI reads that, talks it through with you, and writes back **one current
goal**. The goal shows up in game styled like a quest, with steps that tick themselves off
(level reached, quest turned in, items collected), waypoints, and tips. The AI can also put a
short verdict on items, like *"Upgrade: replaces your belt"*, right in the item tooltip.

**Guidance only.** WowLink displays and records. It never presses a button, moves your
character, or does anything for you. It uses the normal addon API and the game's own
chat and combat logs.

## What you need

- World of Warcraft: retail or any Classic flavor. (So far it has been played on WoW Forever 1.60;
  the code checks every API it uses, but [report problems](../../issues) on other versions.)
- Python 3.9 or newer ([python.org](https://www.python.org/downloads/)). No extra packages.
- An AI. Either kind works:
  - **An agent that can run commands in a folder** (Claude Code, Codex CLI, Cursor, Aider, ...).
    Best experience: it reads your progress itself and writes the goal for you.
  - **A plain chat AI** (ChatGPT, Claude.ai, Gemini, ...). You copy a summary in and paste its reply back.

## Install

1. Download the latest `WowLink-x.y.z.zip` from [Releases](../../releases) and extract it
   somewhere permanent, like `Documents\WowLink`. (Not inside the WoW folder.)
2. In that folder, run:
   ```
   python tools/wl.py setup
   ```
   It finds your WoW install, asks which game version you play if you have several, and links
   the addon into `Interface/AddOns`. If it can't find WoW, give it the folder:
   `python tools/wl.py setup "D:\Games\World of Warcraft"`.
   If linking isn't allowed on your system, add `--copy`.
3. Start WoW, make sure **WowLink** is ticked in the AddOns list at character select (tick
   *Load out of date AddOns* if it says out of date), log in, and type **`/wl sync`**.

## Use it

The rhythm is always the same: **`/wl sync` in game → talk to your AI → `/wl sync` again.**
A sync is a UI reload. It saves your progress for the AI and loads whatever goal it wrote.

### With an agent (Claude Code, Codex, Cursor, ...)

Open the WowLink folder in your agent and just talk: *"Look at my character and help me plan
the next session."* The agent picks up its instructions from `AGENTS.md` (Claude Code reads it via `CLAUDE.md`).
It runs `tools/wl.py` to read your snapshot, loot and combat log, and writes the goal itself.

### With a chat AI

1. Run `python tools/wl.py brief > brief.txt` and paste the contents of `brief.txt` into the chat.
   It has the instructions and your character's current state.
2. Talk it through. When you've settled on a goal, the AI replies with a ```` ```json ```` block.
3. Save the whole reply (or just that block) as `reply.txt` and run
   `python tools/wl.py goal YourCharacterName reply.txt`.
4. `/wl sync` in game.

## In game

| Command | What it does |
|---|---|
| `/wl sync` | Save progress for your AI and load new guidance (reloads the UI). The **[sync]** link on the panel does the same. |
| `/wl note <text>` | Leave a note for your AI, like "stuck finding the Defias hideout". `/wl note` lists them, `/wl note clear` wipes them. |
| `/wl way` | Set the waypoint for the current step. |
| `/wl` | Show or hide the panel. `/wl lock`, `/wl unlock`, `/wl reset` for its position. |
| `/wl autoway` | Turn automatic waypoints off or on. |
| `/wl chatlog`, `/wl combatlog` | Turn the game's chat or combat logging off or on. |

On the panel: **click** a step to tick or untick it, **right-click** it for its waypoint,
**hover** it for details, **drag** the title to move it, **click** the title to collapse it.

## What your AI gets to see

Everything stays on your computer until you share it.

- The snapshot (`WTF/Account/<account>/SavedVariables/WowLink.lua`): your characters' level, gold,
  location, quests, completed quest IDs, professions, gear, bags, loot, journal and notes.
- The game's chat log (`Logs/WoWChatLog.txt`) and combat log. **The chat log has all your chat,
  whispers included.** `brief` only uses the snapshot and the loot lines from the chat log, but an agent
  running in this folder can read the full chat log. If you don't want that, type `/wl chatlog` to turn it off.

## Is this allowed?

As far as we know, yes. WowLink only uses the standard addon API that every quest helper uses,
and the chat and combat logs are Blizzard's own `/chatlog` and `/combatlog` features
(the same ones log-analysis sites use). Nothing automates play. Your AI's advice is still advice:
follow the game's rules.

## For developers

- `AGENTS.md`: instructions for AI agents, including the goal format.
- `python tools/wl.py check` and `python tests/harness.py` (both need `pip install lupa`) run the
  real addon Lua in Lua 5.1 against a stubbed WoW API, end to end through the Python side.

MIT licensed. Not affiliated with or endorsed by Blizzard Entertainment.
