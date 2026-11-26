<!--
CurseForge project setup (paste these into the project form):
  Name:     WowLink
  Summary:  Plan your play with ChatGPT, Claude or any AI: one goal at a time, shown like a quest in your tracker.
  Category: Quests & Leveling (secondary: Chat & Communication)
  License:  MIT License
  Source:   https://github.com/Toastee0/wowlink
  Issues:   https://github.com/Toastee0/wowlink/issues
  Avatar:   media/logo-400.png
Description: everything below the line.
-->

# WowLink

**Talk your progress over with ChatGPT, Claude or any AI, and get one clear goal in your quest tracker.**

Not sure what to do next? Too many quests in your log, upgrades rotting in your bags, a mount to save up for?
WowLink gives your AI a full picture of your character, then puts the plan you agree on right in your UI.

## How it works

1. Click **[copy]** on the WowLink panel. A report of your character is ready to copy: level, zone, quest log
   with objectives, gear and bag items with stats, recent loot, recent events, and notes you've left.
2. Paste it into **ChatGPT, Claude, Gemini**, or whatever AI chat you use, and talk it over.
3. When the AI gives you a goal, copy its reply, click **[paste]**, paste, and click **Load goal**.

Your goal appears like a quest in the tracker:

- **Steps that tick themselves** when you reach a level, turn in a quest, collect items, earn gold, raise a
  profession, or arrive in a zone. Click any step to tick it yourself.
- **Waypoints** for the current step: the game's map pin, or **TomTom**'s GPS arrow if you have it installed.
  The arrow moves on as you finish steps and clears when the goal is done.
- **Item verdicts in tooltips**: your AI can tag items in your bags, like *"Coach: Upgrade: replaces your belt"*
  or *"Coach: Vendor: weaker than what you wear"*.
- **Short updates**: click [copy] again later and paste it into the same chat. Your AI sees what you've done since.

No extra software and no account linking: just the addon and the AI chat you already use.

## Guidance only

WowLink shows and records. It never presses a button, moves your character, or plays for you. Nothing leaves your
computer unless you paste it somewhere, and the [copy] window shows exactly what you'd share.

## Commands

- `/wl copy`: report to paste into your AI chat (full report for a new chat, or a short update)
- `/wl paste`: load the goal and item verdicts from your AI's reply
- `/wl note <text>`: leave a note for your AI in the next report
- `/wl way`: waypoint for the current step; `/wl autoway` toggles automatic waypoints
- `/wl tomtom`: use TomTom's arrow (default when installed) or the game's map pin
- `/wl`: show or hide the panel; `/wl lock`, `/wl unlock`, `/wl reset`

## Power mode

Using an AI agent on your PC (Claude Code, Codex, Cursor, ...)? The full kit on
[GitHub](https://github.com/Toastee0/wowlink) lets it read your progress and the game's live chat and combat logs
directly, and write goals without copy and paste.

## Game versions

Retail and the Classic versions. Tested end to end on WoW Forever. If something breaks on your version, please
[open an issue](https://github.com/Toastee0/wowlink/issues).

*Not affiliated with or endorsed by Blizzard Entertainment, OpenAI or Anthropic.*
