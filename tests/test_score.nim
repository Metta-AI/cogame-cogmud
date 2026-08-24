## Scoring: its formula, its sign, the worked landmark from the design note,
## and what the league ranks by.
##
## PointValue and ScoreScale are chosen so that doing nothing is exactly zero,
## two completed commissions on a break-even purse land near +2, a good trading
## run lands near +1, and one stolen relic swings both seats by 0.35. THIS TEST
## IS THE ENFORCEMENT of those constants, not the prose in the design note: any
## change to them re-runs it.

import std/[json, math, unittest]
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

proc waitAll(sim: var Sim) =
  for seat in sim.pendingSeats():
    sim.applyAction(seat, "I wait and watch the road.", "", "", true)

suite "the scoring formula":
  test "score is (wealth + 3 x questPoints - 40) / 40 for every seat":
    var sim = initSim(fixtureConfig(seed = 201))
    ## A hand-built table: purses, packs and deliveries set directly.
    sim.cogs[0].coin = 25
    sim.cogs[1].coin = 54
    sim.cogs[1].items[0] = 2                 # 2 hides at 6
    sim.cogs[2].coin = 0
    sim.cogs[2].items[5] = 3                 # 3 relics at 14
    sim.quests[0][0].delivered = 2
    sim.cogs[0].delivered[0] = 2
    sim.quests[0][1].delivered = 2
    sim.cogs[0].delivered[1] = 2
    for seat in 0 ..< Seats:
      let expected = (sim.wealth(seat).float +
        (PointValue * sim.questPoints(seat)).float - StartCoin.float) /
        ScoreScale
      check abs(sim.score(seat) - expected) < 1e-9
    check sim.wealth(0) == 25
    check sim.wealth(1) == 54 + 12
    check sim.wealth(2) == 42
    ## Two completed commissions: 2 x (4 x 2 + 8) = 32 points.
    check sim.questPoints(0) == 32
    check abs(sim.score(0) - (25.0 + 96.0 - 40.0) / 40.0) < 1e-9

  test "a seat that does nothing scores exactly 0.0":
    var sim = initSim(fixtureConfig(turns = 6, seed = 202))
    while not sim.done:
      sim.waitAll()
    for seat in 0 ..< Seats:
      check sim.score(seat) == 0.0

  test "buying badly or being robbed blind scores negative":
    var sim = initSim(fixtureConfig(seed = 203))
    sim.cogs[0].coin = 10
    check sim.score(0) < 0.0
    sim.cogs[1].coin = 0
    sim.cogs[1].items[0] = 1               # 6 of wealth against 40 start
    check sim.score(1) < 0.0

  test "one stolen relic swings both seats by exactly 14/40":
    var sim = initSim(fixtureConfig(seed = 204))
    for seat in 0 ..< Seats:
      sim.cogs[seat].room = 6              # Cutpurse Alley: unlit
    sim.cogs[1].items[5] = 1
    let robberBefore = sim.score(0)
    let victimBefore = sim.score(1)
    var sentences: array[Seats, string]
    for seat in 0 ..< Seats:
      sentences[seat] = "I wait and watch the road."
    sentences[0] = "I jump " & sim.names[1] & " here in the dark."
    for seat in sim.pendingSeats():
      sim.applyAction(seat, sentences[seat], "", "", true)
    check abs((sim.score(0) - robberBefore) - 14.0 / 40.0) < 1e-9
    check abs((victimBefore - sim.score(1)) - 14.0 / 40.0) < 1e-9

  test "the worked landmark in the design note reproduces 2.03":
    ## Buys 2 hides from Tanner Oda at stock 8 and 7 (4 + 5 = 9 coin), 2 rope
    ## from Smith Bram at stock 6 and 5 (8 + 9 = 17 coin), hands both pairs to
    ## Guildmaster Vell (2 x (4 x 2 + 8) = 32 points), and sells a relic
    ## lifted from the Warehouse Yard to Dockmaster Fen at stock 3 for 11.
    check askAt(0, 8) + askAt(0, 7) == 9
    check askAt(2, 6) + askAt(2, 5) == 17
    check bidAt(5, 3) == 11
    var sim = initSim(fixtureConfig(seed = 205))
    sim.cogs[0].coin = StartCoin - 9 - 17 + 11
    sim.quests[0][0] = Quest(item: 0, count: 2, delivered: 2)
    sim.quests[0][1] = Quest(item: 2, count: 2, delivered: 2)
    sim.cogs[0].delivered = [2, 2]
    check sim.cogs[0].coin == 25
    check sim.wealth(0) == 25
    check sim.questPoints(0) == 32
    check abs(sim.score(0) - 81.0 / 40.0) < 1e-9
    check abs(sim.score(0) - 2.025) < 1e-9

  test "a pure trader who works the spread for +40 coin scores 1.00":
    var sim = initSim(fixtureConfig(seed = 206))
    sim.cogs[0].coin = StartCoin + 40
    check abs(sim.score(0) - 1.0) < 1e-9

  test "a delivered unit is worth 12 wealth, a completion 24 more":
    ## PointsPerUnit x PointValue = 12; CompletionBonus x PointValue = 24.
    check PointsPerUnit * PointValue == 12
    check CompletionBonus * PointValue == 24
    ## Delivering is profitable but not free against a 6..9 coin good.
    for item in QuestItems:
      check Items[item].baseValue < PointsPerUnit * PointValue

suite "results are what the league ranks by":
  test "resultsJson carries six of everything and wealth never trails coin":
    var sim = initSim(fixtureConfig(turns = 8, seed = 207))
    while not sim.done:
      for seat in sim.pendingSeats():
        sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
          true)
    let results = sim.resultsJson()
    for key in ["names", "scores", "coin", "wealth", "questPoints",
        "delivered", "robberies", "robbed"]:
      check results[key].len == Seats
    for seat in 0 ..< Seats:
      check results["wealth"][seat].getInt() >= results["coin"][seat].getInt()
      check results["names"][seat].getStr() == sim.config.players[seat].name
      check abs(results["scores"][seat].getFloat() - sim.score(seat)) < 1e-9
    check results["reason"].getStr() == "complete"

  test "results attribute by POLICY name while the replay keeps the alias":
    var sim = initSim(fixtureConfig(turns = 6, seed = 208))
    while not sim.done:
      sim.waitAll()
    let results = sim.resultsJson()
    for seat in 0 ..< Seats:
      check results["names"][seat].getStr() == "P" & $(seat + 1)
      check sim.names[seat] != results["names"][seat].getStr()
