# AutoTradeSand

World of Warcraft **1.12 (vanilla)** addon that automatically puts Hourglass Sand in the trade window when someone trades you. Made to run with or without ClassicAPI.

Adapted from the Classic Era `autoTradeSand` / WaterDispenser idea (originally by GPI / Junsa, Feraline@Spineshatter), rewritten for the 1.12 API.

## Install
Copy this folder to `Interface\AddOns\AutoTradeSand\` (the folder name must be `AutoTradeSand`).

## Usage
- **Minimap button:** left click = enable / disable auto trade, right click = config window, drag = move.
- The stack is split in your bags first (vanilla trades always move a whole stack), so you need one free bag slot.

| Command | Effect |
|---|---|
| `/ats config` | open the config window |
| `/ats toggle` | enable / disable auto trade |
| `/ats fill` / `/ats clear` | fill / clear the open trade window |
| `/ats <n>` | sand per trade (e.g. `/ats 2`) |
| `/ats id <itemID>` | item to trade (default 19183) |
| `/ats status` | show settings |
| `/ats debug` | toggle debug messages |
