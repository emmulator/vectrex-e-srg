# Changelist

## 1.1.0

- **New: slower missiles on EASY.** A player found the game too hard, so EASY's
  missiles now fly at 0.75x the speed at every step of the score ramp (the
  steps still come at the same scores). NORMAL and HARD are unchanged. 13 bytes
  of ROM are left.

## 1.0.2

- **Fixed: the dome reappeared, fully cracked, under GAME OVER** ([#2](https://github.com/emmulator/vectrex-e-srg/issues/2)).
  When a dome death ended the game (every dome death on HARD, or one that took
  your last life on NORMAL), the dome collapsed, then came back with every tile
  cracked until the game returned to the title screen. It now stays gone under
  GAME OVER. A last-life death on a cracked tile still shows the dome's real
  cracks. ROM +17 bytes.

## 1.0.1

- **Fixed: missiles could stop coming** ([#1](https://github.com/emmulator/vectrex-e-srg/issues/1)).
  Until you'd shot down 6 missiles, missiles only targeted the top five rings
  (26 cells). If those all broke first (for example by not firing), nothing
  could launch again and the game never ended. Missiles now target every ring
  once you've shot down 6 **or** 6 have hit the dome, so the lockout can't
  persist. Same ROM size.

## 1.0.0

First release.
