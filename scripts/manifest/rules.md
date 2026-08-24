# Cogmud rules

Six cogs, one town, fourteen turns. Every action is ONE SENTENCE of plain
English; there is no menu of moves anywhere.

## The nine rooms

Exits are symmetric and complete: a ring 1-2-3-4-5-6-7-8-1 plus spokes from
Market Square to 1, 3, 5 and 7. Every room is within 2 moves of Market Square
and the graph diameter is 4. `dark` rooms are the only rooms where robbery can
succeed.

| id | room | keywords | dark | roads to |
|---|---|---|---|---|
| 0 | Market Square | market, square, well, plaza | no | The Copper Kettle, The Smithy, The Docks, The Chapel |
| 1 | The Copper Kettle | kettle, tavern, inn, copper | no | Market Square, Tanner's Row, The Guildhall |
| 2 | Tanner's Row | tanner, tannery, row, tanners | no | The Copper Kettle, The Smithy |
| 3 | The Smithy | smithy, smith, forge, anvil | no | Market Square, Tanner's Row, Warehouse Yard |
| 4 | Warehouse Yard | warehouse, yard, store, stores | no | The Smithy, The Docks |
| 5 | The Docks | docks, dock, quay, harbour, harbor, wharf | **yes** | Market Square, Warehouse Yard, Cutpurse Alley |
| 6 | Cutpurse Alley | alley, cutpurse, backstreet, lane | **yes** | The Docks, The Chapel |
| 7 | The Chapel | chapel, church, shrine | no | Market Square, Cutpurse Alley, The Guildhall |
| 8 | The Guildhall | guildhall, guild, hall, board | no | The Copper Kettle, The Chapel |

## The six goods

`base value` is the fixed reference valuation SCORING uses. It never moves with
the market, so a seat's score never depends on which shop it happens to be
standing next to.

| id | good | keywords | base value |
|---|---|---|---|
| 0 | hide | hide, hides, skin, skins, leather | 6 |
| 1 | nails | nails, nail, iron | 7 |
| 2 | rope | rope, ropes, coil, cord | 8 |
| 3 | salt | salt, salts, brine | 9 |
| 4 | lamp | lamp, lamps, lantern, oil | 11 |
| 5 | relic | relic, relics, idol, icon | 14 |

## The five shopkeepers

Each stands in one room forever, deals only in the goods on its list, and
starts with 120 coin.

| shopkeeper | room | deals in (opening stock) |
|---|---|---|
| Tanner Oda | Tanner's Row | hide 8, salt 5 |
| Smith Bram | The Smithy | nails 8, rope 6 |
| Keeper Nesh | The Copper Kettle | lamp 4, salt 6, rope 4 |
| Dockmaster Fen | The Docks | relic 3, hide 5, nails 6 |
| Guildmaster Vell | The Guildhall | rope 4, lamp 3 |

## Prices move with stock

Integer arithmetic only, per shopkeeper per good:

```
ask(n, k) = clamp(base[k] + 1 * (6 - stock(n, k)), max(2, base[k] div 2), base[k] * 3)
bid(n, k) = max(1, ask(n, k) * 2 div 3)
```

At stock 6 a good sells for exactly its base value; at stock 0 it costs base +
6 (capped at three times base); at stock 12 it costs base - 6 (floored at half
base, minimum 2). The bid is two thirds of the ask: the spread is the
shopkeeper's living. **Each unit of a multi-unit purchase is priced from the
stock at the moment THAT unit changes hands** - buying two hides from a shop
holding 8 costs `ask@8 + ask@7` = 4 + 5 = 9. That is the whole supply curve,
and it is why cornering a shop's stock is a real strategy. At each turn's open
after the first, every shopkeeper adds +1 to exactly one good on its list -
index `turn mod list length` - up to a cap of 12. Supply is slow, finite and
predictable.

## Commissions

Guildmaster Vell at the Guildhall posts and settles EVERY commission in the
game. Each seat holds exactly two, private to it, drawn from the seed from
{hide, nails, rope, salt} (never lamp or relic - those are pure trade goods),
each for 2 units. Handing goods to a shopkeeper is how a commission is filled:
give Vell a good one of your open commissions names and each unit banks 4
points, with a further 8 when the commission is finished. PART OF A COMMISSION
COUNTS. Goods handed to any other shopkeeper, or to Vell without a matching
open commission, enter its stock and score nothing - the goods are gone.

## The turn

An episode is `turns` turns (default 14). Decisions inside a turn are
SIMULTANEOUS: all six sentences go out in one parallel batch and nothing a seat
writes in turn t is visible to any other seat before turn t + 1.

**Initiative** is a deterministic rotation with no randomness: on turn t the
seats resolve in the order `(k + t) mod 6` for k = 0..5. Every seat stands at
the front of the queue exactly `turns / 6` times. Where two seats contend for
the same stock, the same item on the floor, the same offer or the same victim,
THE EARLIER INITIATIVE WINS and the loser's action resolves against what is
left, or fails with a named reason.

For each turn, in this exact order:

1. **Open.** Offers posted two or more turns ago expire (an offer lives exactly
   one turn: posted on t, acceptable only on t + 1). Every retainer's counter
   ticks down; at zero the bond clears. Every shopkeeper restocks one good -
   at the open of every turn *after the first*, since the opening stock in the
   table above is what the shops hold on turn 1.
   Last turn's public acts become what each seat reads as *what happened here*.
2. **Deadline check**, before the batch and never mid-turn.
3. **Rate floor**: at least 12 seconds between LLM batches, skipped entirely
   when there are no credentials.
4. **Collect**: one parallel batch of six.
5. **Parse**: every sentence through the same pure grammar.
6. **Resolve**, in this class order, each class in initiative order, each
   sub-step appending its own event as it resolves:
   1. Speech - every `say` field and every spoken line is posted to the
      speaker's START-OF-TURN room.
   2. Shops - buy, sell, hand over, ask.
   3. Ground - take, drop.
   4. Cog to cog - give, offer a trade, offer a hire, accept.
   5. Robbery - against START-OF-TURN positions. You cannot dodge an ambush by
      walking away.
   6. Movement.
7. **Book-keeping.** Wealth and score are derived from state, never
   accumulated.

## The thirteen intents

| intent | rule |
|---|---|
| go | The room must be an exit of the room you stand in, else `no_such_exit`. |
| take | The good must be lying here; `min(qty, present, free slots)` units move to you. |
| drop | `min(qty, held)` units go on the floor. |
| buy | The keeper must be here and deal in it. Units are walked one at a time at the rising ask until your coin runs out; a partial fill is legal. |
| sell | The keeper must be here and deal in it. Units are priced one at a time at the falling bid as its stock grows, stopping when its coin runs out. |
| hand over | To a cog in your room: an unconditional transfer of goods and/or coin, no consent needed. To a shopkeeper: the goods enter its stock, and if it is Vell and the good matches an open commission it is credited. |
| offer | Posts a trade offer to one named cog, valid on the next turn only, while both of you are in the same room. Nothing is escrowed: the trade executes at acceptance or fails. |
| accept | Consumes one live offer addressed to you. A trade moves the goods and the coin atomically; a hire moves the fee and binds you for three turns. Two open offers and no name is `no_such_offer`. |
| hire | Posts a hire offer for a fee you can actually pay. |
| rob | See below. |
| ask | Your next observation gains, for each open commission, the shop with the cheapest current ask for that good, its room and that ask. Costs the turn; buys information. |
| speak | The sentence is spoken in your room and read by everyone there next turn. |
| wait | A legal no-op. |

A sentence the grammar cannot read is a legal no-op with a reason naming what
was missing, and **the seat is told the reason in its next observation**. That
is how a policy learns the grammar, and it is why no menu is needed.

## Robbery, deterministically

Let `retainersPresent(x)` be the number of seats hired to x, still bound, and
standing in the robbery's room at the turn's start.

```
A = 1 + retainersPresent(robber) + (1 if the room is dark else 0)
D = 1 + retainersPresent(victim) + (0 if the room is dark else 2)   # the watch
robbery succeeds iff A > D
```

- **Lit room, no hirelings:** A = 1, D = 3 - the watch always stops you.
  Robbery is possible ONLY in The Docks and Cutpurse Alley.
- **Dark room, no hirelings:** A = 2, D = 1 - it succeeds.
- **Dark room, the victim has one hireling beside it:** A = 2, D = 2 - it
  fails. A bodyguard is worth exactly one mugging.
- **Dark room, both sides have one hireling:** A = 3, D = 2 - it succeeds.
  Bringing muscle beats hiring muscle, so protection is a market, not a shield.

On success the robber takes ONE item - the victim's highest-base-value good,
ties broken by lowest id - or, if the victim carries nothing (or the robber has
no free slot), `min(victim's coin, 10)` coin; with neither, `nothing_to_take`.
On failure the robber pays `min(its coin, 8)` to the victim. Either way the
attempt is public in the room. A retainer can never rob its own employer.

## What a seat sees, and what it never sees

A seat sees the turn number, its alias, its purse and pack with each good's
reference value and its free slots, its commission book with points banked and
outstanding, the room it stands in (name, description, exits BY DESTINATION
NAME, the goods on the floor, the aliases of every other cog present, and the
shopkeeper here with its full trade list: good, stock, ask, bid and its
remaining coin), every public act and spoken line here last turn (at most 12
lines of at most 200 runes), the offers open to it, its retainer standing, the
town map (every room's name, its exits and which keeper shops there - but NOT
those keepers' stock or prices), the verbatim outcome of its own last sentence,
its private notes, and a twelve-line phrasebook of example sentences.

A seat NEVER sees any other seat's coin, pack, commissions, notes or score;
anything at all happening in another room; the stock or prices of a shopkeeper
it is not standing next to; the seed; or another seat's raw sentence except
through the public act lines of its own room.

*Every cog knows the map and nobody knows the town.* Every NOUN a sentence could
need is spelled out in the observation, so a model never has to guess a name -
and nothing tells it what it is allowed to DO.

## The two endings

- **complete** - all turns resolved. The expected value.
- **deadline** - the play deadline (60% of the episode timeout) was reached
  between turns, so the episode settled early. Scores come from the state as it
  stands; because score is derived from wealth and deliveries rather than
  averaged per turn, a short honest episode is on the same scale as a full one.

There is no other value. There is no bankruptcy (coin can never go negative), no
elimination and no walkout: a seat that never connects plays with an empty
operator prompt, and a seat whose decision fails plays the scripted baseline.
