# WowLink

**Talk your World of Warcraft progress over with ChatGPT, Claude or any AI, and get one clear goal in your quest tracker.**

WowLink is an addon. Click **[copy]** in game and paste the report into your AI chat: your
level, zone, quest log and objectives, gear with stats, recent loot, and notes you left. Talk it
through. When the AI gives you a goal, click **[paste]** and paste its reply. The goal shows up
in game styled like a quest, with steps that tick themselves off (level reached, quest turned in,
items collected), waypoints, and tips. The AI can also put a short verdict on items, like
*"Upgrade: replaces your belt"*, right in the item tooltip.

No extra software: just the addon and the AI account you already have.

**Guidance only.** WowLink displays and records. It never presses a button, moves your
character, or does anything for you.

## Install

1. Download `WowLink-addon-x.y.z.zip` from [Releases](../../releases).
2. Extract it into your AddOns folder, so you end up with `...\World of Warcraft\_retail_\Interface\AddOns\WowLink`.
   Use the folder for the game version you play (`_retail_`, `_classic_era_`, `_classic_`, ...).
3. Start WoW. At character select, open **AddOns** and make sure **WowLink** is ticked (tick
   *Load out of date AddOns* if it says out of date).

Works with retail and the Classic versions. So far it's been played on WoW Forever 1.60; if
something breaks on your version, please [open an issue](../../issues).

## Use it with ChatGPT, Claude, Gemini, ...

1. In game, click **[copy]** on the WowLink panel (or type `/wl copy`). The report is already
   selected: press **Ctrl+C**.
2. Paste it into a new chat with your AI and talk: *"What should I do next session?"*
3. When you've agreed on a goal, the AI writes it as a ```` ```json ```` block. Copy the AI's reply
   (the whole message is fine).
4. In game, click **[paste]** (or `/wl paste`), press **Ctrl+V**, and click **Load goal**.

Later, click **[copy]** again for a *Short update* and paste it into the same chat. The AI sees what
you've done since and can adjust the goal or give you the next one.

**Tip:** to skip the long instructions at the start of each chat, paste [PROMPT.md](PROMPT.md)
once into a ChatGPT Project (or custom GPT) or a Claude Project's instructions, and start your chats there.

## In game

| | |
|---|---|
| **[copy]** / `/wl copy` | Report of your progress to paste into your AI chat. Switch between *Full report* (new chat) and *Short update*. |
| **[paste]** / `/wl paste` | Paste the AI's reply to load its goal and item verdicts. |
| `/wl note <text>` | Leave a note for your AI, like "stuck finding the Defias hideout". It goes into the next report. `/wl note` lists notes, `/wl note clear` wipes them. |
| `/wl way` | Set the waypoint for the current step. `/wl autoway` turns automatic waypoints off or on. |
| `/wl tomtom` | With [TomTom](https://www.curseforge.com/wow/addons/tomtom) installed, waypoints use its GPS-style arrow (on by default). This switches between TomTom and the game's own map pin. |
| `/wl` | Show or hide the panel. `/wl lock`, `/wl unlock`, `/wl reset` for its position. |

On the panel: **click** a step to tick or untick it, **right-click** it for its waypoint,
**hover** it for details, **drag** the title to move it, **click** the title to collapse it.

## Power mode: an AI agent on your PC (optional)

If you use an agent that can run commands (Claude Code, Codex CLI, Cursor, Aider, ...), it can
read your progress directly and write goals itself, with no copy and paste. It can also read the
game's **live chat and combat logs**: loot as it drops, and what killed you.

1. Install [Python 3.9+](https://www.python.org/downloads/). Download `WowLink-x.y.z.zip` (the full
   one) from Releases and extract it somewhere permanent, like `Documents\WowLink`.
2. In that folder, run `python tools/wl.py setup`. It finds WoW, asks which version you play,
   and links the addon into AddOns. (If you already installed the addon-only zip, it updates that
   copy instead.)
3. Open the folder in your agent and talk. It follows `AGENTS.md`.
   In game, **[sync]** (`/wl sync`) reloads the UI to swap data with the agent.

## What gets shared

Nothing leaves your computer unless you paste it somewhere. The **[copy]** report shows
exactly what your AI gets: your character's level, gold, location, quests, professions, gear,
recent loot, recent events and your notes. Read it before you paste if you like.

In power mode the addon also turns on the game's own chat log (`Logs/WoWChatLog.txt`), which
holds **all your chat, whispers included**, and an agent in the WowLink folder can read it.
Type `/wl chatlog` to turn that off (and `/wl combatlog` for the combat log).

## Is this allowed?

As far as we know, yes. WowLink only uses the standard addon API that every quest helper uses.
The optional logs are Blizzard's own `/chatlog` and `/combatlog` features, the same ones log-analysis
sites use. Nothing automates play. Your AI's advice is still advice: follow the game's rules.

## For developers

- `AGENTS.md`: instructions for AI agents, including the goal format.
- `python tools/wl.py check` and `python tests/harness.py` (both need `pip install lupa`) run the
  real addon Lua in Lua 5.1 against a stubbed WoW API, end to end through the Python side.

MIT licensed. Not affiliated with or endorsed by Blizzard Entertainment.
