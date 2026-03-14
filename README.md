# WGG Brewmaster Standalone

Brewmaster Monk rotation for WGG/Warden framework.

## Setup

1. Rename `Brewmaster_Standalone.lua` to `_Brewmaster.lua`
2. Drop into `C:\WGG\`
3. Requires `_wardengg.wgg`
4. Auto-loads on login

## Commands

| Command | Action |
|---------|--------|
| `/bm` | Toggle rotation |
| `/bm start` / `stop` | Start/stop |
| `/bm status` | Show state |
| `/bm burst` | Toggle burst (Niuzao) |
| `/bm intall` | Toggle interrupt all |
| `/bm log` / `log on` / `log off` | Logger control |

## Features

- Full combat rotation (Blackout Combo → Keg Smash / Tiger Palm sequencing)
- Auto defensives (Purifying Brew / Fortifying Brew / Celestial Infusion)
- Auto interrupt (interruptAll + Leg Sweep fallback)
- Auto taunt (protects healers/DPS, Black Ox Statue AoE taunt)
- Invoke Niuzao burst with Flurry Strikes stacking
- Exploding Keg smart ground placement
- Draw overlays (BoF cone, EK landing zone)
- Combat logging to `C:\WGG\logs\`

## Optional Modules

Place in `C:\WGG\standalone\` with `_init.lua` loader:

- `TankKnowledge_Standalone.lua` — interrupt whitelist + spike warnings
- `TankListEditor_Standalone.lua` — in-game list editor
- `BossAwareness_Standalone.lua` — boss cast detection
- `BossTimers_Standalone.lua` — boss ability timers

## Version

v2.0.0 — Updated Mar 13, 2026

⚠️ Not fully tested in dungeons and raids. Welcome to contribute or report issues!
