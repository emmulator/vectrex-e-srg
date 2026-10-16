# Changelist

## 1.0.1

- **Fixed: missiles could stop coming** ([#1](https://github.com/emmulator/vectrex-e-srg/issues/1)).
  Until you'd shot down 6 missiles, missiles only targeted the top five rings
  (26 cells). If those all broke first (for example by not firing), nothing
  could launch again and the game never ended. Missiles now target every ring
  once you've shot down 6 **or** 6 have hit the dome, so the lockout can't
  persist. Same ROM size.

## 1.0.0

First release.
