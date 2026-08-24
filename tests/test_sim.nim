## Sim unit tests: the world tables, the seeded setup, the price curve, the
## resolution order and its contention rules, robbery in all four cases, the
## retainer, rune-safe truncation, the wasm integer width, the observation
## split, replay re-derivation and its tamper check, and the two endings.

import std/[json, sets, strutils, unicode, unittest]
import cogmud/sim
import cogmud/llm

proc fixtureConfig(turns = 14, seed = 0, speech = true,
    thievery = true): GameConfig =
  result = defaultGameConfig()
  result.turns = turns
  result.seed = seed
  result.speech = speech
  result.thievery = thievery
  result.turnDelayMs = 0
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc actAll(sim: var Sim, sentences: array[Seats, string]) =
  ## Every seat writes its sentence; the sixth resolves the turn.
  for seat in sim.pendingSeats():
    sim.applyAction(seat, sentences[seat], "", "", true)

proc waitAll(sim: var Sim) =
  for seat in sim.pendingSeats():
    sim.applyAction(seat, "I wait and watch the road.", "", "", true)

proc place(sim: var Sim, seat, room: int) =
  sim.cogs[seat].room = room

proc lastAct(sim: Sim, seat: int): GameEvent =
  for index in countdown(sim.events.high, 0):
    if sim.events[index].kind == evAct and sim.events[index].seat == seat:
      return sim.events[index]
  raise newException(ValueError, "no act event for seat " & $seat)

proc questNodes(node: JsonNode, found: var seq[JsonNode]) =
  ## Every object anywhere in a frame that carries a commission's shape. Used
  ## to prove a player frame discloses NO commission book but its own.
  case node.kind
  of JObject:
    if node.hasKey("item") and node.hasKey("count") and
        node.hasKey("delivered"):
      found.add(node)
    for _, child in node:
      questNodes(child, found)
  of JArray:
    for child in node:
      questNodes(child, found)
  else:
    discard

proc bfs(source: int): array[RoomCount, int] =
  for room in 0 ..< RoomCount:
    result[room] = -1
  result[source] = 0
  var frontier = @[source]
  while frontier.len > 0:
    var next: seq[int]
    for room in frontier:
      for exit in Rooms[room].exits:
        if result[exit] < 0:
          result[exit] = result[room] + 1
          next.add(exit)
    frontier = next

# 1 -------------------------------------------------------------------------
suite "world integrity":
  test "every room is reachable, every exit is symmetric and real":
    for room in Rooms:
      check room.exits.len > 0
      check room.id notin room.exits
      var seen = initHashSet[int]()
      for exit in room.exits:
        check exit >= 0 and exit < RoomCount
        check not seen.containsOrIncl(exit)
        check room.id in Rooms[exit].exits      # symmetric
    for source in 0 ..< RoomCount:
      let distances = bfs(source)
      for target in 0 ..< RoomCount:
        check distances[target] >= 0            # reachable
        check distances[target] == Dist[source][target]

  test "every room is within 2 of Market Square and the diameter is 4":
    var diameter = 0
    for source in 0 ..< RoomCount:
      check Dist[0][source] <= 2
      for target in 0 ..< RoomCount:
        diameter = max(diameter, Dist[source][target])
    check diameter == 4

  test "the world payload publishes what the viewer must not hardcode":
    ## client/renderer.js reads the item values, the Guildhall's id and the
    ## commission's per-unit points out of this, so none of them is a literal
    ## in the browser.
    let world = worldJson()
    check world["guild"].getInt() == GuildNpc
    check world["pointsPerUnit"].getInt() == PointsPerUnit
    for item in 0 ..< ItemKinds:
      check world["items"][item]["value"].getInt() == Items[item].baseValue

  test "the five shops stand in distinct rooms and deal in real goods":
    var rooms = initHashSet[int]()
    for npc in Npcs:
      check not rooms.containsOrIncl(npc.room)
      check npc.tradeList.len > 0
      check npc.tradeList.len == npc.initialStock.len
      for item in npc.tradeList:
        check item >= 0 and item < ItemKinds
      check npc.keywords.len > 0

  test "stepToward walks a shortest path":
    for source in 0 ..< RoomCount:
      for target in 0 ..< RoomCount:
        if source == target:
          check stepToward(source, target) == -1
        else:
          let step = stepToward(source, target)
          check step >= 0
          check Adjacency[source][step]
          check Dist[step][target] == Dist[source][target] - 1

# 2 -------------------------------------------------------------------------
suite "setup":
  test "starting rooms are distinct and commissions are legal":
    for seed in [0, 1, 7, 11, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var rooms = initHashSet[int]()
      for seat in 0 ..< Seats:
        check not rooms.containsOrIncl(sim.cogs[seat].room)
        check sim.cogs[seat].coin == StartCoin
        check sim.carried(seat) == 0
        check sim.cogs[seat].retainerOf == -1
        check sim.cogs[seat].retainerTurns == 0
        check sim.quests[seat][0].item != sim.quests[seat][1].item
        for quest in 0 ..< Quests:
          check sim.quests[seat][quest].item in QuestItems
          check sim.quests[seat][quest].count == 2
          check sim.quests[seat][quest].delivered == 0

  test "six ground items lie in rooms 0, 4, 5, 6 and 7, one of them a relic":
    for seed in [0, 1, 7, 11, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var total = 0
      for room in 0 ..< RoomCount:
        var here = 0
        for item in 0 ..< ItemKinds:
          here += sim.rooms[room].items[item]
        total += here
        if room in [0, 5, 6, 7]:
          check here == 1
        elif room == 4:
          check here == 2
        else:
          check here == 0
      check total == 6
      check sim.rooms[4].items[5] >= 1     # the extra relic in the Yard

  test "the log opens with start then turn, and all six seats are pending":
    let sim = initSim(fixtureConfig(seed = 3))
    check sim.events.len == 2
    check sim.events[0].kind == evStart
    check sim.events[1].kind == evTurn
    check sim.pendingSeats().len == Seats
    check sim.phase == phTurn

  test "shops open on the world table's stock and 120 coin":
    let sim = initSim(fixtureConfig(seed = 5))
    for npc in 0 ..< NpcCount:
      check sim.npcs[npc].coin == NpcStartCoin
      for index, item in Npcs[npc].tradeList:
        check sim.npcs[npc].stock[item] == Npcs[npc].initialStock[index]

# 3 -------------------------------------------------------------------------
suite "determinism":
  test "the same seed reproduces the town, a different seed does not":
    let a = initSim(fixtureConfig(seed = 11))
    let b = initSim(fixtureConfig(seed = 11))
    let c = initSim(fixtureConfig(seed = 12))
    check a.names == b.names
    var differs = a.names != c.names
    for seat in 0 ..< Seats:
      check a.cogs[seat].room == b.cogs[seat].room
      check a.quests[seat] == b.quests[seat]
      if a.cogs[seat].room != c.cogs[seat].room or
          a.quests[seat] != c.quests[seat]:
        differs = true
    check a.rooms == b.rooms
    check differs

  test "commission pairs vary across seeds":
    var pairs = initHashSet[string]()
    for seed in 0 ..< 20:
      let sim = initSim(fixtureConfig(seed = seed))
      for seat in 0 ..< Seats:
        pairs.incl($sim.quests[seat][0].item & "-" & $sim.quests[seat][1].item)
    check pairs.len > 1

# 4 -------------------------------------------------------------------------
suite "initiative":
  test "the rotation is a permutation and every seat leads its share":
    var leads: array[Seats, int]
    for turn in 0 ..< 12:
      let order = initiativeOrder(turn)
      var seen = initHashSet[int]()
      for k in 0 ..< Seats:
        check order[k] == (k + turn) mod Seats
        check not seen.containsOrIncl(order[k])
      check seen.len == Seats
      leads[order[0]] += 1
    for seat in 0 ..< Seats:
      check leads[seat] == 2

# 5 -------------------------------------------------------------------------
suite "prices, by hand":
  test "the ask curve and its clamps":
    for item in 0 ..< ItemKinds:
      let base = Items[item].baseValue
      check askAt(item, RefStock) == base
      check askAt(item, 0) == min(base + 6, base * 3)
      check askAt(item, 12) == max(base - 6, max(2, base div 2))
      for stock in 0 .. StockCap:
        check bidAt(item, stock) == max(1, askAt(item, stock) * 2 div 3)
        check bidAt(item, stock) < askAt(item, stock) or askAt(item, stock) <= 2

  test "two hides from stock 8 cost 4 + 5 and leave stock 6":
    check askAt(0, 8) == 4
    check askAt(0, 7) == 5
    var sim = initSim(fixtureConfig(seed = 4))
    sim.place(0, Npcs[0].room)
    let before = sim.cogs[0].coin
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I buy two hides from Tanner Oda."
    sim.actAll(sentences)
    check sim.cogs[0].coin == before - 9
    check sim.cogs[0].items[0] == 2
    check sim.npcs[0].stock[0] == 6
    let event = sim.lastAct(0)
    check event.reason == oOk
    check event.qty == 2
    check event.coin == 9

  test "two rope into stock 6 pay bid@6 + bid@7 = 5 + 4":
    check bidAt(2, 6) == 5
    check bidAt(2, 7) == 4
    var sim = initSim(fixtureConfig(seed = 4))
    sim.place(0, Npcs[1].room)
    sim.cogs[0].items[2] = 2
    let before = sim.cogs[0].coin
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I sell two rope to Smith Bram."
    sim.actAll(sentences)
    check sim.cogs[0].coin == before + 9
    check sim.cogs[0].items[2] == 0

  test "a purchase that outruns coin fills partially and never overdraws":
    var sim = initSim(fixtureConfig(seed = 4))
    sim.place(0, Npcs[0].room)
    sim.cogs[0].coin = 9      # exactly two hides at 4 + 5
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I buy all the hides from Tanner Oda."
    sim.actAll(sentences)
    check sim.cogs[0].coin == 0
    check sim.cogs[0].items[0] == 2
    check sim.lastAct(0).reason == oOk

  test "no coin at all is cannot_afford, and a broke shop is npc_broke":
    var sim = initSim(fixtureConfig(seed = 4))
    sim.place(0, Npcs[0].room)
    sim.cogs[0].coin = 0
    sim.place(1, Npcs[1].room)
    sim.cogs[1].items[2] = 2
    sim.npcs[1].coin = 3      # rope bids 5 at stock 6
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I buy one hide from Tanner Oda."
    sentences[1] = "I sell two rope to Smith Bram."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oCannotAfford
    check sim.lastAct(1).reason == oNpcBroke
    check sim.cogs[1].items[2] == 2

  test "a shop will not deal in goods it does not stock":
    var sim = initSim(fixtureConfig(seed = 4))
    sim.place(0, Npcs[0].room)      # Tanner Oda: hide, salt
    sim.cogs[0].items[5] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I sell one relic to Tanner Oda."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oNotWanted

# 6 -------------------------------------------------------------------------
suite "restock":
  test "each shop's trade list gains its round-robin share, capped":
    var sim = initSim(fixtureConfig(turns = 14, seed = 6))
    var opening: array[NpcCount, array[ItemKinds, int]]
    for npc in 0 ..< NpcCount:
      opening[npc] = sim.npcs[npc].stock
    for turn in 0 ..< 12:
      sim.waitAll()
    ## Turns 1..12 restocked (the world table is what the shops hold at 0).
    for npc in 0 ..< NpcCount:
      let trade = Npcs[npc].tradeList
      var expected: array[ItemKinds, int]
      expected = opening[npc]
      for turn in 1 .. 12:
        let item = trade[turn mod trade.len]
        if expected[item] < StockCap:
          expected[item] += 1
      for item in 0 ..< ItemKinds:
        ## The exact gain, not merely a bound: each trade-list item gained
        ## 12 div trade.len restocks plus the round-robin remainder, capped.
        checkpoint("npc " & $npc & " item " & $item)
        check sim.npcs[npc].stock[item] == expected[item]
        check sim.npcs[npc].stock[item] <= StockCap
        if item in trade:
          check sim.npcs[npc].stock[item] >= opening[npc][item]
      ## Sanity: nothing outside the trade list ever appears.
      for item in 0 ..< ItemKinds:
        if item notin trade:
          check sim.npcs[npc].stock[item] == 0

# 7 -------------------------------------------------------------------------
suite "commissions and partial credit":
  test "one of two banks 4 points, the second banks 4 + 8, a third banks 0":
    var sim = initSim(fixtureConfig(seed = 8))
    let item = sim.quests[0][0].item
    sim.place(0, Npcs[GuildNpc].room)
    sim.cogs[0].items[item] = 3
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."

    sentences[0] = "I hand Guildmaster Vell one " & Items[item].name &
      " for my commission."
    sim.actAll(sentences)
    check sim.quests[0][0].delivered == 1
    check sim.cogs[0].delivered[0] == 1
    check sim.lastAct(0).coin == PointsPerUnit
    let afterFirst = sim.questPoints(0)
    check afterFirst == PointsPerUnit

    sentences[0] = "I hand Guildmaster Vell one " & Items[item].name &
      " for my commission."
    sim.actAll(sentences)
    check sim.quests[0][0].delivered == 2
    check sim.lastAct(0).coin == PointsPerUnit + CompletionBonus
    check sim.questPoints(0) == 2 * PointsPerUnit + CompletionBonus

    sentences[0] = "I hand Guildmaster Vell one " & Items[item].name &
      " for my commission."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oNoMatchingCommission
    check sim.cogs[0].items[item] == 0          # the goods are gone anyway
    check sim.questPoints(0) == 2 * PointsPerUnit + CompletionBonus

  test "a non-commission item to Vell, and a commission item to anyone else":
    var sim = initSim(fixtureConfig(seed = 9))
    sim.place(0, Npcs[GuildNpc].room)
    sim.cogs[0].items[5] = 1                    # relic: never a commission
    let item = sim.quests[1][0].item
    sim.place(1, Npcs[0].room)                  # Tanner Oda, not Vell
    sim.cogs[1].items[item] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I hand Guildmaster Vell one relic."
    sentences[1] = "I hand Tanner Oda one " & Items[item].name & "."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oNoMatchingCommission
    check sim.cogs[0].items[5] == 0
    check sim.questPoints(0) == 0
    check sim.lastAct(1).reason == oNoMatchingCommission
    check sim.cogs[1].items[item] == 0
    check sim.questPoints(1) == 0
    ## Neither is a delivery, so neither is a highlight: a handover that banks
    ## no commission scores the failed-act 5, and no salience branch anywhere
    ## can be reached by a non-Guild keeper.
    check sim.lastAct(0).salience == 5
    check sim.lastAct(1).salience == 5

# 8 -------------------------------------------------------------------------
suite "contention resolves by initiative":
  test "the earlier initiative gets the last unit of stock":
    var sim = initSim(fixtureConfig(seed = 2))
    ## Turn 0: initiative is 0, 1, 2, 3, 4, 5.
    check initiativeOrder(sim.turn)[0] == 0
    sim.place(0, Npcs[0].room)
    sim.place(1, Npcs[0].room)
    sim.npcs[0].stock[0] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I buy one hide from Tanner Oda."
    sentences[1] = "I buy one hide from Tanner Oda."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oOk
    check sim.lastAct(1).reason == oOutOfStock

  test "the earlier initiative gets a contested ground item":
    var sim = initSim(fixtureConfig(seed = 2))
    sim.place(0, 3)
    sim.place(1, 3)
    sim.rooms[3].items[4] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I pick up the lamp."
    sentences[1] = "I pick up the lamp."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oOk
    check sim.cogs[0].items[4] == 1
    check sim.lastAct(1).reason == oNoSuchItem

  test "the first accept consumes an offer; a second gets no_such_offer":
    var sim = initSim(fixtureConfig(seed = 2))
    sim.place(0, 0)
    sim.place(2, 0)
    sim.cogs[2].items[4] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[2] = "I offer " & sim.names[0] & " one lamp for 5 coins."
    sim.actAll(sentences)
    check sim.lastAct(2).reason == oOk
    check sim.offers.len == 1

    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I accept " & sim.names[2] & "'s offer."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oOk
    check sim.cogs[0].items[4] == 1
    check sim.cogs[0].coin == StartCoin - 5
    check sim.cogs[2].coin == StartCoin + 5
    check sim.offers.len == 0

    ## The same offer cannot be taken twice.
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I accept " & sim.names[2] & "'s offer."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oNoSuchOffer

  test "two open offers and no name named is no_such_offer":
    var sim = initSim(fixtureConfig(seed = 25))
    for seat in 0 ..< 3:
      sim.place(seat, 0)
    sim.cogs[1].items[4] = 1
    sim.cogs[2].items[0] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[1] = "I offer " & sim.names[0] & " one lamp for 5 coins."
    sentences[2] = "I offer " & sim.names[0] & " one hide for 3 coins."
    sim.actAll(sentences)
    check sim.offers.len == 2
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I accept the offer."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oNoSuchOffer

  test "a trade fails as offer_expired when the offerer can no longer deliver":
    var sim = initSim(fixtureConfig(seed = 26))
    sim.place(0, 0)
    sim.place(1, 0)
    sim.cogs[1].items[4] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[1] = "I offer " & sim.names[0] & " one lamp for 5 coins."
    sim.actAll(sentences)
    check sim.offers.len == 1
    sim.cogs[1].items[4] = 0        # the lamp is gone before the acceptance
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I accept " & sim.names[1] & "'s offer."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oOfferExpired
    check sim.cogs[0].coin == StartCoin

# 9 -------------------------------------------------------------------------
suite "robbery":
  proc robFixture(seed = 13, thievery = true): Sim =
    result = initSim(fixtureConfig(seed = seed, thievery = thievery))
    for seat in 0 ..< Seats:
      result.place(seat, 0)          # Market Square, lit, everyone apart

  proc rob(sim: var Sim, robber, victim: int) =
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[robber] = "I jump " & sim.names[victim] &
      " here in the dark and take what he is carrying."
    sim.actAll(sentences)

  test "a lit room: the watch always stops you and you pay the fine":
    var sim = robFixture()
    sim.place(0, 0)
    sim.place(1, 0)
    sim.cogs[1].items[5] = 1
    let robberCoin = sim.cogs[0].coin
    let victimCoin = sim.cogs[1].coin
    sim.rob(0, 1)
    check sim.lastAct(0).reason == oRobberyFailed
    check sim.cogs[0].coin == robberCoin - FineCoin
    check sim.cogs[1].coin == victimCoin + FineCoin
    check sim.cogs[1].items[5] == 1
    check sim.cogs[0].robberies == 0

  test "a dark room with no hirelings: the highest-value item changes hands":
    var sim = robFixture()
    sim.place(0, 6)
    sim.place(1, 6)
    sim.cogs[1].items[0] = 1      # hide, 6
    sim.cogs[1].items[5] = 1      # relic, 14 - the loot
    sim.rob(0, 1)
    check sim.lastAct(0).reason == oOk
    check sim.cogs[0].items[5] == 1
    check sim.cogs[1].items[5] == 0
    check sim.cogs[1].items[0] == 1
    check sim.cogs[0].robberies == 1
    check sim.cogs[1].robbed == 1

  test "a bodyguard is worth exactly one mugging":
    var sim = robFixture()
    sim.place(0, 6)
    sim.place(1, 6)
    sim.place(2, 6)
    sim.cogs[1].items[5] = 1
    sim.cogs[2].retainerOf = 1                 # seat 2 guards the victim
    sim.cogs[2].retainerTurns = 3
    sim.rob(0, 1)
    check sim.lastAct(0).reason == oRobberyFailed
    check sim.cogs[1].items[5] == 1

  test "bringing muscle beats hiring muscle":
    var sim = robFixture()
    for seat in 0 ..< 4:
      sim.place(seat, 6)
    sim.cogs[1].items[5] = 1
    sim.cogs[2].retainerOf = 1
    sim.cogs[2].retainerTurns = 3
    sim.cogs[3].retainerOf = 0
    sim.cogs[3].retainerTurns = 3
    sim.rob(0, 1)
    check sim.lastAct(0).reason == oOk
    check sim.cogs[0].items[5] == 1

  test "an empty pack yields coin; an empty purse yields nothing_to_take":
    var sim = robFixture()
    sim.place(0, 5)
    sim.place(1, 5)
    sim.cogs[1].coin = 4
    sim.rob(0, 1)
    check sim.lastAct(0).reason == oOk
    check sim.lastAct(0).coin == 4
    check sim.cogs[1].coin == 0

    var empty = robFixture(seed = 14)
    empty.place(0, 5)
    empty.place(1, 5)
    empty.cogs[1].coin = 0
    empty.rob(0, 1)
    check empty.lastAct(0).reason == oNothingToTake
    check empty.cogs[0].robberies == 0

  test "a retainer cannot rob its employer, and nobody robs itself":
    var sim = robFixture()
    sim.place(0, 6)
    sim.place(1, 6)
    sim.cogs[1].items[5] = 1
    sim.cogs[0].retainerOf = 1
    sim.cogs[0].retainerTurns = 2
    sim.rob(0, 1)
    check sim.lastAct(0).reason == oBoundByContract
    check sim.cogs[1].items[5] == 1

    var self = robFixture(seed = 15)
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I rob myself."
    self.actAll(sentences)
    check self.lastAct(0).reason == oSelfTarget

  test "the honest-town variant forbids thievery outright":
    var sim = robFixture(seed = 16, thievery = false)
    sim.place(0, 6)
    sim.place(1, 6)
    sim.cogs[1].items[5] = 1
    let robberCoin = sim.cogs[0].coin
    sim.rob(0, 1)
    check sim.lastAct(0).reason == oThieveryForbidden
    check sim.cogs[1].items[5] == 1
    check sim.cogs[0].coin == robberCoin

  test "you cannot dodge an ambush by walking away":
    var sim = robFixture(seed = 17)
    sim.place(0, 6)
    sim.place(1, 6)
    sim.cogs[1].items[5] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I jump " & sim.names[1] & " here in the dark."
    sentences[1] = "I walk to The Chapel."          # room 6 -> room 7
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oOk
    check sim.cogs[0].items[5] == 1
    check sim.cogs[1].room == 7                     # the move still happened

  test "the spectator frame names this turn's victims for the ROBBED chip":
    ## The scorebug draws its red ROBBED chip from state.recentRobbed, so the
    ## spectator projection has to carry it (client/renderer.js's
    ## updateScorebug).
    var sim = robFixture(seed = 18)
    sim.place(0, 6)
    sim.place(1, 6)
    sim.cogs[1].items[5] = 1
    check sim.tableStateJson()["recentRobbed"].len == 0
    sim.rob(0, 1)
    check sim.lastAct(0).reason == oOk
    var marked: seq[int]
    for node in sim.tableStateJson()["recentRobbed"]:
      marked.add(node.getInt())
    check marked == @[1]
    ## Up for the turn after the theft, down on the one after that.
    sim.waitAll()
    check sim.tableStateJson()["recentRobbed"].len == 0

# 10 ------------------------------------------------------------------------
suite "hire and the retainer":
  test "an accepted hire moves the fee atomically and binds for three turns":
    var sim = initSim(fixtureConfig(seed = 21))
    sim.place(0, 0)
    sim.place(1, 0)
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I hire " & sim.names[1] & " for 15 coins."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oOk
    check sim.offers.len == 1
    check sim.offers[0].kind == okHire
    check sim.offers[0].coin == 15

    ## Step the resolving turn so the state AT THE MOMENT OF ACCEPTANCE is
    ## observable: the counter is set to RetainerTurns there, and the very
    ## next turn's open takes the first tick off it.
    var steps: seq[Sim]
    for seat in sim.pendingSeats():
      let sentence =
        if seat == 1: "I accept " & sim.names[0] & "'s offer."
        else: "I wait and watch the road."
      let produced = sim.applyActionSteps(seat, sentence, "", "", true)
      if produced.len > 0:
        steps = produced
    var atAcceptance = -1
    for index, frame in steps:
      if frame.events[^1].kind == evAct and frame.events[^1].seat == 1 and
          frame.events[^1].intent == iAccept:
        atAcceptance = index
    check atAcceptance >= 0
    check steps[atAcceptance].cogs[1].retainerTurns == RetainerTurns
    check steps[atAcceptance].cogs[1].retainerOf == 0
    check steps[atAcceptance].cogs[0].coin == StartCoin - 15
    check steps[atAcceptance].cogs[1].coin == StartCoin + 15

    check sim.lastAct(1).reason == oOk
    check sim.cogs[0].coin == StartCoin - 15
    check sim.cogs[1].coin == StartCoin + 15
    check sim.cogs[1].retainerOf == 0
    ## The bond ticks down at every turn open and clears at zero.
    check sim.cogs[1].retainerTurns == RetainerTurns - 1
    sim.waitAll()
    check sim.cogs[1].retainerTurns == RetainerTurns - 2
    check sim.cogs[1].retainerOf == 0
    sim.waitAll()
    check sim.cogs[1].retainerTurns == 0
    check sim.cogs[1].retainerOf == -1

  test "a hire offer above the employer's purse is never posted":
    var sim = initSim(fixtureConfig(seed = 22))
    sim.place(0, 0)
    sim.place(1, 0)
    sim.cogs[0].coin = 0
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I hire " & sim.names[1] & " for 15 coins."
    sim.actAll(sentences)
    check sim.lastAct(0).reason == oCannotAfford
    check sim.offers.len == 0

  test "a second accepted hire replaces the first":
    var sim = initSim(fixtureConfig(seed = 23))
    for seat in 0 ..< 3:
      sim.place(seat, 0)
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I hire " & sim.names[2] & " for 5 coins."
    sentences[1] = "I hire " & sim.names[2] & " for 6 coins."
    sim.actAll(sentences)
    check sim.offers.len == 2
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[2] = "I accept " & sim.names[0] & "'s offer."
    sim.actAll(sentences)
    check sim.cogs[2].retainerOf == 0
    ## Post another and take it: the newer employer wins.
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[1] = "I hire " & sim.names[2] & " for 7 coins."
    sim.actAll(sentences)
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[2] = "I accept " & sim.names[1] & "'s offer."
    sim.actAll(sentences)
    check sim.cogs[2].retainerOf == 1
    check sim.cogs[2].retainerTurns == RetainerTurns - 1

  test "an offer lives exactly one turn":
    var sim = initSim(fixtureConfig(seed = 24))
    sim.place(0, 0)
    sim.place(1, 0)
    sim.cogs[0].items[4] = 1
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I offer " & sim.names[1] & " one lamp for 12 coins."
    sim.actAll(sentences)
    ## Posted on turn t; live and acceptable through the open of t + 1.
    check sim.offers.len == 1
    sim.waitAll()               # the acceptable turn passes unused
    check sim.offers.len == 0

# 11 ------------------------------------------------------------------------
suite "rune truncation":
  test "sentence, say and notes are cut on rune boundaries":
    var sim = initSim(fixtureConfig(seed = 31))
    let long = "\u00E9".repeat(900)
    for seat in sim.pendingSeats():
      sim.applyAction(seat, long, long, long, true)
    for event in sim.events:
      if event.kind != evAct:
        continue
      check event.sentence.runeLen == MaxSentenceLen
      check event.say.runeLen == MaxSayLen
      check event.text.runeLen == MaxNotesLen
      check event.sentence.validateUtf8() == -1
      check event.say.validateUtf8() == -1
      check event.text.validateUtf8() == -1
    ## The whole replay must survive a strict UTF-8 JSON parse.
    let encoded = $ %*{"events": (block:
      var nodes = newJArray()
      for event in sim.events:
        nodes.add(event.eventToJson())
      nodes)}
    check encoded.validateUtf8() == -1
    discard parseJson(encoded)

  test "a spoken line lifted out of the sentence is what salience measures":
    ## The act's `say` field is the line the seat spoke, whichever channel it
    ## arrived on, so a long line scores 30 even when the reply carried no
    ## `say` field at all.
    var sim = initSim(fixtureConfig(seed = 33))
    let long = "the relic in the yard is mine and I will have it back today"
    check long.runeLen > 40
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I say \"" & long & "\""
    sentences[1] = "I say \"short\""
    sim.actAll(sentences)
    check sim.lastAct(0).intent == iSay
    check sim.lastAct(0).say == long
    check sim.lastAct(0).salience == 30
    check sim.lastAct(1).say == "short"
    check sim.lastAct(1).salience == 20
    ## The room heard it exactly once, not twice.
    var heard = 0
    for line in sim.heardLog[sim.cogs[0].room]:
      if long in line:
        inc heard
    check heard == 1

  test "speech off silences every say field":
    var sim = initSim(fixtureConfig(seed = 32, speech = false))
    for seat in sim.pendingSeats():
      sim.applyAction(seat, "I wait and watch the road.", "hello there", "",
        true)
    for event in sim.events:
      if event.kind == evAct:
        check event.say == ""

# 12 ------------------------------------------------------------------------
suite "wasm integer width":
  test "no value in a maximal episode approaches 2^31":
    var sim = initSim(fixtureConfig(turns = MaxTurns, seed = 41))
    while not sim.done:
      for seat in sim.pendingSeats():
        sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
          true)
    for event in sim.events:
      check abs(event.coin) <= 100_000
      check abs(event.salience) <= 100_000
      for npc in event.npcs:
        check abs(npc.coin) <= 100_000
        for count in npc.stock:
          check count in 0 .. StockCap
      for cog in event.cogs:
        check abs(cog.coin) <= 100_000
    for seat in 0 ..< Seats:
      check abs(sim.wealth(seat)) <= 100_000
      check abs(sim.questPoints(seat)) <= 100_000

# 13 ------------------------------------------------------------------------
suite "observation split":
  test "a seat sees its own room and nothing else, and every referent in it":
    var sim = initSim(fixtureConfig(turns = 8, seed = 51))
    var frames = 0
    while not sim.done and frames < 8:
      for seat in 0 ..< Seats:
        let view = sim.playerStateJson(seat)
        let text = $view
        let prompt = sim.userPrompt(seat, "")
        let room = sim.cogs[seat].room

        ## Nothing about another seat's purse, pack, commissions or notes.
        for other in 0 ..< Seats:
          if other == seat:
            continue
          if sim.notes[other].len > 0:
            check sim.notes[other] notin text
        ## Every commission book anywhere in the frame is this seat's own, in
        ## its own order: no other seat's item, count or delivered count is
        ## reachable from here.
        var books: seq[JsonNode]
        questNodes(view, books)
        check books.len == Quests
        for index, book in books:
          let mine = sim.quests[seat][index]
          check book["item"].getStr() == Items[mine.item].name
          check book["count"].getInt() == mine.count
          check book["delivered"].getInt() == mine.delivered
        check view{"room"}{"id"}.getInt() == room
        ## No shop's books but the one in this room.
        let here = npcInRoom(room)
        for npc in 0 ..< NpcCount:
          if npc == here:
            continue
          check Npcs[npc].name notin ($view{"room"})
        ## Every referent the grammar can resolve here is named verbatim.
        for exit in Rooms[room].exits:
          check Rooms[exit].name in text
          check Rooms[exit].name in prompt
        for item in 0 ..< ItemKinds:
          if sim.rooms[room].items[item] > 0:
            check Items[item].name in text
            check Items[item].name in prompt
        for other in 0 ..< Seats:
          if other != seat and sim.cogs[other].room == room:
            check sim.names[other] in text
            check sim.names[other] in prompt
        if here >= 0:
          check Npcs[here].name in text
          check Npcs[here].name in prompt
          for good in Npcs[here].tradeList:
            check Items[good].name in text
            check Items[good].name in prompt
      for seat in sim.pendingSeats():
        sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
          true)
      inc frames

  test "no other seat's score reaches a player frame":
    var sim = initSim(fixtureConfig(turns = 8, seed = 52))
    sim.waitAll()
    for seat in 0 ..< Seats:
      let view = sim.playerStateJson(seat)
      check view{"score"}.isNil
      check view{"seats"}.isNil
      check view{"npcs"}.isNil
      check view{"rooms"}.isNil

# 14 ------------------------------------------------------------------------
suite "replay":
  proc playOut(seed: int, turns: int): Sim =
    result = initSim(fixtureConfig(turns = turns, seed = seed))
    while not result.done:
      for seat in result.pendingSeats():
        result.applyAction(seat, scriptedSentence(result, seat, skFactor),
          "a line", "some notes", true)

  proc roundTrip(events: seq[GameEvent]): seq[GameEvent] =
    for event in events:
      result.add(eventFromJson(event.eventToJson()))

  test "frames line up and the final frame equals the live one":
    let live = playOut(61, 8)
    let events = roundTrip(live.events)
    let frames = replayMatch(fixtureConfig(turns = 8, seed = 61), events)
    check frames.len == events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check $frames[^1].resultsJson() == $live.resultsJson()

  test "the replay carries the world table the viewer draws":
    let live = playOut(62, 8)
    check $live.tableStateJson()["world"] == $worldJson()

  test "every event kind round-trips through JSON field by field":
    let live = playOut(63, 8)
    var seen: set[EventKind]
    for event in live.events:
      seen.incl(event.kind)
      let back = eventFromJson(event.eventToJson())
      check back.kind == event.kind
      check back.turn == event.turn
      check back.seat == event.seat
      check back.order == event.order
      check back.intent == event.intent
      check back.room == event.room
      check back.toRoom == event.toRoom
      check back.item == event.item
      check back.qty == event.qty
      check back.npc == event.npc
      check back.other == event.other
      check back.coin == event.coin
      check back.reason == event.reason
      check back.salience == event.salience
      check back.sentence == event.sentence
      check back.say == event.say
      check back.text == event.text
      check back.scripted == event.scripted
      check back.rooms == event.rooms
      check back.npcs == event.npcs
      check back.cogs == event.cogs
    check seen == {evStart, evTurn, evAct, evEnd}

  test "a tampered turn event is rejected":
    let live = playOut(64, 8)
    var events = roundTrip(live.events)
    var tampered = -1
    for index, event in events:
      if event.kind == evTurn and event.turn > 0:
        tampered = index
        break
    check tampered >= 0
    events[tampered].npcs[0].coin += 1
    expect CogmudError:
      discard replayMatch(fixtureConfig(turns = 8, seed = 64), events)

  test "a deadline ending re-derives as deadline, at either point it can fall":
    ## (a) at a turn open.
    var atOpen = initSim(fixtureConfig(turns = 8, seed = 65))
    for turn in 0 ..< 3:
      for seat in atOpen.pendingSeats():
        atOpen.applyAction(seat, scriptedSentence(atOpen, seat, skFactor), "",
          "", true)
    atOpen.endEarly()
    check atOpen.reason == "deadline"
    let openFrames = replayMatch(fixtureConfig(turns = 8, seed = 65),
      roundTrip(atOpen.events))
    check openFrames[^1].reason == "deadline"
    check openFrames.len == atOpen.events.len + 1

    ## (b) immediately after the sixth act of a turn: the turn resolved and
    ## opened the next one, and the clock stopped before that batch went out.
    var afterSixth = initSim(fixtureConfig(turns = 8, seed = 66))
    for turn in 0 ..< 5:
      for seat in afterSixth.pendingSeats():
        afterSixth.applyAction(seat,
          scriptedSentence(afterSixth, seat, skFactor), "", "", true)
    check afterSixth.pendingSeats().len == Seats   # the next turn is open
    afterSixth.endEarly()
    let sixthFrames = replayMatch(fixtureConfig(turns = 8, seed = 66),
      roundTrip(afterSixth.events))
    check sixthFrames[^1].reason == "deadline"
    check sixthFrames[^1].turnsPlayed == 5

# 15 ------------------------------------------------------------------------
suite "endings":
  test "a full episode completes and refuses further actions":
    var sim = initSim(fixtureConfig(turns = 6, seed = 71))
    while not sim.done:
      sim.waitAll()
    check sim.reason == "complete"
    check sim.turnsPlayed == 6
    check sim.events[^1].kind == evEnd
    check sim.events[^2].kind == evTurn
    check sim.events[^1].turn == 6
    check sim.pendingSeats().len == 0
    expect CogmudError:
      sim.applyAction(0, "I wait and watch the road.", "", "", true)

  test "endEarly is a deadline, is idempotent, and scores a dead-cold table":
    var sim = initSim(fixtureConfig(turns = 14, seed = 72))
    sim.waitAll()
    sim.endEarly()
    check sim.reason == "deadline"
    let events = sim.events.len
    sim.endEarly()
    check sim.events.len == events

    var cold = initSim(fixtureConfig(turns = 14, seed = 73))
    cold.endEarly()
    for seat in 0 ..< Seats:
      check cold.score(seat) == 0.0

  test "a seat that only waits scores exactly zero":
    var sim = initSim(fixtureConfig(turns = 6, seed = 74))
    while not sim.done:
      sim.waitAll()
    for seat in 0 ..< Seats:
      check sim.score(seat) == 0.0
      check sim.wealth(seat) == StartCoin

# episode budget ------------------------------------------------------------
suite "episode budget":
  test "sampleEpisode fits fourteen turns into 60% of 1200 seconds":
    var config = defaultGameConfig()
    for index in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "P" & $index))
      config.tokens.add("t")
    check turnBudgetSeconds(config) == 36
    let fitted = sampleEpisode(config)
    check fitted.turns == 14
    check fitted.sampled
    ## 14 turns x 36 s + 180 s connect + 20 s pacing = 704 s < 720 s.
    check fitted.turns * turnBudgetSeconds(fitted) +
      int(fitted.playerConnectTimeoutSeconds) + PacingBudgetMs div 1000 <
      int(PlayBudgetFraction * fitted.episodeTimeoutSeconds.float)
    ## Idempotent: a replay being re-read is never re-fitted.
    check sampleEpisode(fitted).turns == fitted.turns

  test "the fitted turn count is clamped into MinTurns..MaxTurns":
    var config = defaultGameConfig()
    for index in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "P" & $index))
      config.tokens.add("t")
    config.turns = 400
    check sampleEpisode(config).turns <= MaxTurns
    var small = defaultGameConfig()
    for index in 0 ..< Seats:
      small.players.add(PlayerConfig(name: "P" & $index))
      small.tokens.add("t")
    small.turns = 1
    check sampleEpisode(small).turns == MinTurns

  test "the cert fixture is 59 events, comfortably longer than the soak":
    var config = fixtureConfig(turns = 8, seed = 11)
    var sim = initSim(config)
    while not sim.done:
      for seat in sim.pendingSeats():
        sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
          true)
    ## 1 start + 8 turn + 48 act + 1 closing turn + 1 end.
    check sim.events.len == 59

# results -------------------------------------------------------------------
suite "results":
  test "config rejects a table that is not six seats or too few turns":
    var config = defaultGameConfig()
    expect CogmudError:
      config.update("""{"turns": 3}""")
    var seats = defaultGameConfig()
    expect CogmudError:
      seats.update("""{"players": [{"name":"a"},{"name":"b"}]}""")

  test "resultsJson reports six of everything":
    var sim = initSim(fixtureConfig(turns = 6, seed = 81))
    while not sim.done:
      for seat in sim.pendingSeats():
        sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
          true)
    let results = sim.resultsJson()
    for key in ["names", "scores", "coin", "wealth", "questPoints",
        "delivered", "robberies", "robbed"]:
      check results[key].len == Seats
    check results["reason"].getStr() == "complete"
    check results["turns"].getInt() == 6
    check results["maxTurns"].getInt() == 6
