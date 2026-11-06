# Spell Efficiency

WoW: Forever addon. Adds three lines to every damage or healing spell tooltip:

```
Avg damage: 138 (53.0 direct + 85.0 over 15 s) (+115.6% vs. Rank 2)
Damage per mana: 1.53 (+7.8% vs. Rank 2)
Damage per sec of cast time: 69.0 (2 s) (+115.6% vs. Rank 2)
```

- **Average amount**: the middle of the tooltip range ("13 to 18" → 15.5). Damage over time counts as the full amount over the whole duration, including per-tick wording such as "every 3 sec for 15 sec".
- **Per mana**: average amount divided by the mana cost.
- **Per second of cast time**: shown only for spells with a cast time. For channelled spells the channel duration counts.
- **Compared with the previous rank**: the percentage in brackets compares with the next lower rank you know (green is better, red is worse).
- Heals show the same values as healing. Shields are skipped.

The values come from the tooltip text (enUS client) plus mana cost and cast time from the spell API, so talents and
gear show up wherever the tooltip itself reflects them.

## Commands

- `/se` or `/spelleff`: tooltip lines on/off
- `/se debug`: prints the parsed values to chat

## Install

Copy the `SpellEfficiency` folder into `_forever_\Interface\AddOns`, or install it from CurseForge.

## License

MIT
