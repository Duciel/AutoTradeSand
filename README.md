# AutoTradeSand

World of Warcraft **1.12 (vanilla)** addon that automatically puts Hourglass Sand in the trade window when someone trades you. Made to run with or without ClassicAPI.

Adapted from the Classic Era `autoTradeSand` / WaterDispenser idea (originally by GPI / Junsa, Feraline@Spineshatter), rewritten for the 1.12 API.

## Install
Copy this folder to `Interface\AddOns\AutoTradeSand\` (the folder name must be `AutoTradeSand`).

## Usage
- **Minimap button:** left click = enable / disable auto trade, right click = config window, drag = move.
- **History tab** (config window): for each player, the sand you **sent**, how many they **used** (seen in the combat log, only while they still hold some of yours), how many they traded **back**, and how many are **left** with them. 40 players at a glance. Only completed trades are counted. It is saved with your character.
- **Reset prompt:** entering Blackwing Lair asks whether to reset the history (once per entry; can be disabled in Settings). A reset can be undone with `/ats undo`. Shift-click "Reset history" to reset it by hand.
- **Trading sand back:** if the other player puts the sand in their own side of the trade, the addon takes yours back out (other items stay) and does not add any when they are already offering it. The sand they give you is counted as "Back" in the history.
- The stack is split in your bags first (vanilla trades always move a whole stack), so you need one free bag slot.

| Command | Effect |
|---|---|
| `/ats config` | open the config window |
| `/ats history` | open the history tab |
| `/ats undo` | restore the history after a reset |
| `/ats zone <name>` | zone that asks to reset the history |
| `/ats spell <name>` | spell name looked for in the combat log (default Hourglass Sand) |
| `/ats toggle` | enable / disable auto trade |
| `/ats fill` / `/ats clear` | fill / clear the open trade window |
| `/ats <n>` | sand per trade (e.g. `/ats 2`) |
| `/ats id <itemID>` | item to trade (default 19183) |
| `/ats status` | show settings |
| `/ats debug` | toggle debug messages |
