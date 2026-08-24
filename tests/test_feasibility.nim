## The feasibility oracle. Both commissions must be completable inside the
## horizon by a competent seat, or partial credit is the only credit anyone
## ever sees.
##
## THIS TEST IS THE ENFORCEMENT, not the table in the design note: any change
## to a room, an exit, a stock level, a base value, StartCoin or the turn count
## re-runs it, and the build fails if the greedy plan stops fitting.

import std/[unittest]
import cogmud/sim
import cogmud/llm

proc fixtureConfig(turns = 14, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.turns = turns
  result.seed = seed
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

type Plan = object
  turns: int
  cost: int
  feasible: bool

proc cheapestSource(sim: Sim, item, units: int): tuple[room, cost: int] =
  ## The shop that can supply `units` of `item` most cheaply from its opening
  ## stock, walking the rising ask one unit at a time.
  result = (-1, high(int))
  for npc in 0 ..< NpcCount:
    if not dealsIn(npc, item) or sim.npcs[npc].stock[item] < units:
      continue
    var cost = 0
    var stock = sim.npcs[npc].stock[item]
    for unit in 0 ..< units:
      cost += askAt(item, stock)
      dec stock
    if cost < result.cost:
      result = (Npcs[npc].room, cost)

proc greedyPlan(sim: Sim, seat: int): Plan =
  ## start -> cheapest shop stocking commission A -> buy -> shop stocking
  ## commission B -> buy -> Guildhall -> hand -> hand. Both orderings of the
  ## two commissions are tried and the shorter route wins, which is what a
  ## competent seat would do.
  let questA = sim.quests[seat][0]
  let questB = sim.quests[seat][1]
  let sourceA = cheapestSource(sim, questA.item, questA.count)
  let sourceB = cheapestSource(sim, questB.item, questB.count)
  if sourceA.room < 0 or sourceB.room < 0:
    return Plan(turns: high(int), cost: high(int), feasible: false)
  let guild = Npcs[GuildNpc].room
  let here = sim.cogs[seat].room
  let viaAB = Dist[here][sourceA.room] + 1 + Dist[sourceA.room][sourceB.room] +
    1 + Dist[sourceB.room][guild] + 2
  let viaBA = Dist[here][sourceB.room] + 1 + Dist[sourceB.room][sourceA.room] +
    1 + Dist[sourceA.room][guild] + 2
  Plan(turns: min(viaAB, viaBA), cost: sourceA.cost + sourceB.cost,
    feasible: true)

suite "the feasibility oracle":
  test "the greedy plan fits inside turns - 2 and inside the starting purse":
    var worstTurns = 0
    var worstCost = 0
    for seed in 0 ..< 200:
      let sim = initSim(fixtureConfig(seed = seed))
      for seat in 0 ..< Seats:
        let plan = greedyPlan(sim, seat)
        checkpoint("seed " & $seed & " seat " & $seat & ": " & $plan.turns &
          " turns, " & $plan.cost & " coin")
        check plan.feasible
        check plan.turns <= sim.config.turns - 2
        check plan.cost <= StartCoin
        worstTurns = max(worstTurns, plan.turns)
        worstCost = max(worstCost, plan.cost)
    ## Echo the worst case so a constant change that eats the slack is visible
    ## in the CI log before it is fatal.
    checkpoint("worst case over 200 seeds x 6 seats: " & $worstTurns &
      " turns, " & $worstCost & " coin (horizon 14, purse 40)")
    check worstTurns <= 12
    check worstCost <= StartCoin

  test "the design note's hand-worked worst case is an upper bound":
    ## The note walks hide (rooms 2 and 5) and nails (rooms 3 and 5) from The
    ## Docks as 5-0-1-2 (3 moves), buy (1), 2-3 (1), buy (1), 3-2-1-8 (3),
    ## hand (1), hand (1) = 11 turns and 4 + 5 + 7 + 8 = 24 coin. That route is
    ## valid but not optimal: visiting The Smithy first (5-4-3, 2 moves) is two
    ## turns shorter, so the oracle finds MORE slack than the note claims, not
    ## less. The note says the test is the enforcement, so the assertion is the
    ## note's numbers as an upper bound.
    var sim = initSim(fixtureConfig(seed = 3))
    sim.cogs[0].room = 5
    sim.quests[0][0] = Quest(item: 0, count: 2, delivered: 0)   # hide
    sim.quests[0][1] = Quest(item: 1, count: 2, delivered: 0)   # nails
    let plan = greedyPlan(sim, 0)
    checkpoint($plan.turns & " turns, " & $plan.cost & " coin (the note's " &
      "hand route is 11 turns and 24 coin)")
    check plan.turns <= 11
    check plan.cost <= 24
    check plan.turns <= 14 - 2
    check plan.cost <= StartCoin

  test "the room graph the oracle walks is the one the design note names":
    check Dist[8][2] == 2
    check Dist[8][3] == 3
    check Dist[2][3] == 1
    check Dist[8][1] == 1
    check Dist[8][5] == 3
    for source in 0 ..< RoomCount:
      for target in 0 ..< RoomCount:
        check Dist[source][target] <= 4

  test "every commission item is stocked by at least two shops":
    ## A single supplier would make one cornered stock a hard block.
    for item in QuestItems:
      var suppliers = 0
      for npc in 0 ..< NpcCount:
        if dealsIn(npc, item):
          inc suppliers
      checkpoint(Items[item].name & ": " & $suppliers & " suppliers")
      check suppliers >= 2

  test "a competent scripted table really does fill both commissions":
    ## The oracle is a route calculation; this is the measured consequence.
    for seed in [0, 1, 7, 11, 42, 1234]:
      var sim = initSim(fixtureConfig(seed = seed))
      while not sim.done:
        for seat in sim.pendingSeats():
          sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
            true)
      for seat in 0 ..< Seats:
        checkpoint("seed " & $seed & " seat " & $seat & " delivered " &
          $sim.deliveredTotal(seat))
        check sim.deliveredTotal(seat) >= 2
