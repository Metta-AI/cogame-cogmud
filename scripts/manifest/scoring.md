# scoring.md

Computed from state at the end of the episode. **Higher is better.** Nothing is
accumulated except commission deliveries.

```
wealth(seat)      = coin + sum over goods of baseValue[k] * held(seat, k)
questPoints(seat) = sum over the seat's 2 commissions of
                      ( 4 * delivered + (8 if delivered >= count else 0) )
score(seat)       = ( wealth(seat) + 3 * questPoints(seat) - 40 ) / 40.0
```

`results.scores[seat]` is the single number the league ranks by, and the ladder
ranks seats by **mean episode score**. There is exactly one ladder statistic.

## The constants, and why they are these

| constant | value |
|---|---|
| starting coin | 40 |
| carry limit | 8 items |
| points per unit delivered | 4 |
| completion bonus | 8 |
| score-weight of one commission point | 3 |
| score scale | 40 |
| retainer length | 3 turns |
| coin taken from an empty pack | 10 |
| fine for a failed robbery | 8 |

- **A seat that does nothing scores exactly 0.0** - 40 coin, no goods, no
  points. A seat that is robbed blind or buys badly scores NEGATIVE. The sign
  is unambiguous.
- Every commission point is worth **3 score-units of wealth**, so a delivered
  unit is worth **12** against a good that costs 6 to 9 coin: delivering is
  profitable but not free, and a completed commission pays a further **24**.
- A single successful robbery of a relic swings both seats by exactly
  14/40 = **0.35** - visible on a leaderboard without dominating it.

## A worked landmark

A competent seat starting at The Chapel:

- buys 2 hides from Tanner Oda at stock 8 and 7 (`4 + 5`) = **-9 coin**;
- buys 2 rope from Smith Bram at stock 6 and 5 (`8 + 9`) = **-17 coin**;
- walks to the Guildhall and hands over both pairs =
  `2 x (4 x 2 + 8)` = **32 points**;
- sells a relic lifted from the Warehouse Yard to Dockmaster Fen at stock 3
  (`bid = (14 + 3) * 2 div 3 = 11`) = **+11 coin**.

Coin = `40 - 9 - 17 + 11` = 25; wealth 25;
`score = (25 + 3 x 32 - 40) / 40 = 81/40` = **2.03**.

A pure trader who never touches a commission but works the spread for +40 coin
over fourteen turns scores **1.00**. A seat mugged twice in the Alley for a
lamp and a relic scores about **-0.6**. Commissions beat trade, trade funds
commissions, and theft moves real score between seats.

## The feasibility oracle

Both commissions must be completable inside the horizon by a competent seat, or
partial credit would be the only credit anyone ever saw. The worst case the
design considered - commissions for hide and nails starting at The Docks -
takes 11 turns and 24 coin by the obvious route, and 9 turns and 20 coin by the
best one, against a 14-turn horizon and a 40-coin purse. The repo's
`tests/test_feasibility.nim` asserts over 200 seeds x 6 seats that the greedy
plan `start -> cheapest shop for commission A -> buy -> shop for commission B
-> buy -> Guildhall -> hand -> hand` fits in `turns - 2` and inside the
starting purse. **That test is the enforcement, not this page**: any change to
a room, an exit, a stock level, a base value, the starting coin or the turn
count re-runs it and fails the build if the slack is gone.

## What the results carry

`names` (POLICY names - the league attributes by policy, while the replay's
`names` carries the anonymous table aliases), `scores`, `coin`, `wealth`,
`questPoints`, `delivered`, `robberies` (successful thefts committed), `robbed`
(times victimised), `turns`, `maxTurns` and `reason` (`complete` or
`deadline`).
