## Bounded-orders / legality assertion on the two scripted baselines, plus the
## no-credentials fallback and the reply parser.
##
## The baselines emit English that the SAME parseSentence reads, so a full
## scripted episode is a live, per-episode test of the parser: zero unreadable
## sentences is the assertion, not a hope.

import std/[json, monotimes, strutils, tables, times, unicode, unittest]
import cogmud/sim
import cogmud/llm

proc fixtureConfig(turns = 14, seed = 0, thievery = true): GameConfig =
  result = defaultGameConfig()
  result.turns = turns
  result.seed = seed
  result.thievery = thievery
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

type Table6 = array[Seats, ScriptKind]

proc allOf(kind: ScriptKind): Table6 =
  for seat in 0 ..< Seats:
    result[seat] = kind

const Mixed: Table6 = [skMagpie, skFactor, skFactor, skMagpie, skFactor,
  skMagpie]
## The certification fixture's offline seat mix: cogmud-player, cogmud-factor,
## cogmud-player, cogmud-magpie, cogmud-factor, cogmud-player. With no
## credentials every prompt seat plays `factor`.
const CertMix: Table6 = [skFactor, skFactor, skFactor, skMagpie, skFactor,
  skFactor]

proc play(seed: int, kinds: Table6, turns = 14,
    thievery = true): tuple[sim: Sim, unreadable: int] =
  var sim = initSim(fixtureConfig(turns = turns, seed = seed,
    thievery = thievery))
  var unreadable = 0
  while not sim.done:
    var sentences: array[Seats, string]
    for seat in sim.pendingSeats():
      sentences[seat] = scriptedSentence(sim, seat, kinds[seat])
      if parseSentence(sim, seat, sentences[seat]).kind == iNone:
        inc unreadable
    for seat in sim.pendingSeats():
      sim.applyAction(seat, sentences[seat], "", "", true)
  (sim, unreadable)

proc intentCounts(sim: Sim, kinds: Table6,
    only: ScriptKind): CountTable[string] =
  result = initCountTable[string]()
  for event in sim.events:
    if event.kind == evAct and kinds[event.seat] == only:
      result.inc($event.intent)

proc meanScore(sim: Sim): float =
  for seat in 0 ..< Seats:
    result += sim.score(seat)
  result / Seats.float

# 1 -------------------------------------------------------------------------
suite "legality and boundedness":
  test "every scripted episode completes, legally, with no unreadable line":
    for seed in [1, 7, 11, 42]:
      for kinds in [allOf(skFactor), allOf(skMagpie), Mixed]:
        let started = getMonoTime()
        let run = play(seed, kinds)
        let elapsed = (getMonoTime() - started).inMilliseconds
        checkpoint("seed " & $seed & " in " & $elapsed & "ms")
        check run.sim.done
        check run.sim.reason == "complete"
        check run.sim.turnsPlayed == 14
        ## The baselines are a live test of the parser.
        check run.unreadable == 0
        check elapsed < 2000
        for event in run.sim.events:
          if event.kind != evAct:
            continue
          check event.intent != iNone
          check event.sentence.runeLen <= MaxSentenceLen
          check event.say == ""
          check event.text == ""
          check event.scripted
          if event.reason == oOk and event.intent in
              [iBuy, iSell, iTake, iDrop, iGive]:
            check event.qty >= 1
          for cog in event.cogs:
            check cog.coin >= 0
        for seat in 0 ..< Seats:
          check run.sim.cogs[seat].coin >= 0
          check run.sim.carried(seat) <= CarryLimit

  test "no seat ever overdraws, overfills or holds a negative stack":
    for seed in [1, 7, 11, 42]:
      var sim = initSim(fixtureConfig(seed = seed))
      while not sim.done:
        for seat in sim.pendingSeats():
          sim.applyAction(seat, scriptedSentence(sim, seat, Mixed[seat]), "",
            "", true)
        for seat in 0 ..< Seats:
          check sim.cogs[seat].coin >= 0
          check sim.carried(seat) <= CarryLimit
          for item in 0 ..< ItemKinds:
            check sim.cogs[seat].items[item] >= 0
        for npc in 0 ..< NpcCount:
          check sim.npcs[npc].coin >= 0
          for item in 0 ..< ItemKinds:
            check sim.npcs[npc].stock[item] in 0 .. StockCap
        for room in 0 ..< RoomCount:
          for item in 0 ..< ItemKinds:
            check sim.rooms[room].items[item] >= 0

# 2 -------------------------------------------------------------------------
suite "baseline behaviour":
  test "factor fills a commission on every seed and never robs, hires or trades":
    for seed in [1, 7, 11, 42]:
      let run = play(seed, allOf(skFactor))
      let counts = intentCounts(run.sim, allOf(skFactor), skFactor)
      checkpoint("seed " & $seed & " " & $counts)
      check counts.getOrDefault($iRob) == 0
      check counts.getOrDefault($iHire) == 0
      check counts.getOrDefault($iTrade) == 0
      for seat in 0 ..< Seats:
        check run.sim.deliveredTotal(seat) >= 2      # at least one filled
        check run.sim.questPoints(seat) > 0

  test "factor lands a commission by turn 12":
    for seed in [1, 7, 11, 42]:
      var sim = initSim(fixtureConfig(seed = seed))
      var landed: array[Seats, bool]
      var turns = 0
      while not sim.done and turns < 12:
        for seat in sim.pendingSeats():
          sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
            true)
        inc turns
      for seat in 0 ..< Seats:
        landed[seat] = sim.deliveredTotal(seat) > 0
        check landed[seat]

  test "magpie robs, trades and fills nothing":
    for seed in [1, 7, 11, 42]:
      let run = play(seed, Mixed)
      let counts = intentCounts(run.sim, Mixed, skMagpie)
      checkpoint("seed " & $seed & " magpie " & $counts)
      check counts.getOrDefault($iRob) >= 1
      check counts.getOrDefault($iTrade) >= 1
      check counts.getOrDefault($iGive) == 0
      for seat in 0 ..< Seats:
        if Mixed[seat] == skMagpie:
          check run.sim.deliveredTotal(seat) == 0
          check run.sim.questPoints(seat) == 0

  test "the competent baseline is the one a prompt has to beat":
    for seed in [1, 7, 11, 42]:
      let factor = play(seed, allOf(skFactor)).sim
      let magpie = play(seed, allOf(skMagpie)).sim
      ## The log echoes both numbers so tuning drift is visible.
      checkpoint("seed " & $seed & ": factor " & $meanScore(factor) &
        " magpie " & $meanScore(magpie))
      check meanScore(factor) > meanScore(magpie)

  test "the certification fixture's offline mix contains a theft":
    ## The cert replay is what the viewer smoke loads, and the rob FX are part
    ## of what it proves. seed 11 / 8 turns is the manifest fixture.
    let run = play(11, CertMix, turns = 8)
    var thefts = 0
    for event in run.sim.events:
      if event.kind == evAct and event.intent == iRob and event.reason == oOk:
        inc thefts
    check thefts >= 1
    check run.sim.events.len == 59

  test "honest-town turns every robbery into thievery_forbidden":
    let run = play(11, allOf(skMagpie), thievery = false)
    var forbidden = 0
    for event in run.sim.events:
      if event.kind == evAct and event.intent == iRob:
        check event.reason == oThieveryForbidden
        inc forbidden
      check event.reason != oRobberyFailed
    for seat in 0 ..< Seats:
      check run.sim.cogs[seat].robberies == 0
      check run.sim.cogs[seat].robbed == 0

# 3 -------------------------------------------------------------------------
suite "the no-credentials fallback":
  test "a disabled client decides scripted for all six seats, with no wait":
    ## CI never sets ANTHROPIC_API_KEY and the sidecar env is absent, so this
    ## is exactly the path docker-smoke and offline certification take.
    var config = fixtureConfig(seed = 91)
    let client = newLlmClient(config)
    check client.disabled

    var sim = initSim(config)
    let started = getMonoTime()
    var turns = 0
    while not sim.done:
      let seats = sim.pendingSeats()
      var prompts = newSeq[string](Seats)
      var scripted = newSeq[ScriptKind](Seats)
      let decisions = client.decideAll(sim, seats, prompts, scripted)
      check decisions.len == Seats
      for index, seat in seats:
        check decisions[index].sentence.len > 0
        check decisions[index].say == ""
        sim.applyAction(seat, decisions[index].sentence, decisions[index].say,
          decisions[index].notes, true)
      inc turns
    let elapsed = (getMonoTime() - started).inMilliseconds
    checkpoint("14 disabled turns in " & $elapsed & "ms")
    check turns == 14
    ## No network call and no batch-spacing sleep: well under five seconds.
    check elapsed < 5000

# 4 -------------------------------------------------------------------------
suite "reply parsing":
  test "the documented shapes are accepted and every field is capped":
    let full = parseDecision(parseJson(
      """{"action":"I buy two hides from Tanner Oda.","say":"hello",
          "notes":"remember the tanner"}"""))
    check full.sentence == "I buy two hides from Tanner Oda."
    check full.say == "hello"
    check full.notes == "remember the tanner"

    let bare = parseDecision(parseJson("""{"action":"I wait."}"""))
    check bare.sentence == "I wait."
    check bare.say == ""
    check bare.notes == ""

    let extra = parseDecision(parseJson(
      """{"action":"I wait.","mood":"grim","plan":[1,2]}"""))
    check extra.sentence == "I wait."

    let long = "\u00E9".repeat(900)
    let capped = parseDecision(%*{"action": long, "say": long, "notes": long})
    check capped.sentence.runeLen == MaxSentenceLen
    check capped.say.runeLen == MaxSayLen
    check capped.notes.runeLen == MaxNotesLen
    check capped.sentence.validateUtf8() == -1

    let newlines = parseDecision(parseJson(
      """{"action":"I go\nto the Docks."}"""))
    check "\n" notin newlines.sentence

  test "a missing or empty action is invalid and therefore retryable":
    expect CogmudError:
      discard parseDecision(parseJson("""{"say":"hello"}"""))
    expect CogmudError:
      discard parseDecision(parseJson("""{"action":"   "}"""))
    expect CogmudError:
      discard parseDecision(parseJson("""{"action":12}"""))
    expect CogmudError:
      discard parseDecision(parseJson("""[1,2,3]"""))

  test "an unreadable but present action is VALID, never a retry":
    ## The seat said something; the town did not understand it. That is a legal
    ## no-op with a recorded reason, not a transport failure.
    let decision = parseDecision(parseJson(
      """{"action":"I contemplate the nature of commerce."}"""))
    check decision.sentence == "I contemplate the nature of commerce."
    let sim = initSim(fixtureConfig(seed = 92))
    check parseSentence(sim, 0, decision.sentence).kind == iNone

  test "JSON is extracted from fences and trailing prose":
    check parseDecision(extractJsonObject(
      "```json\n{\"action\": \"I wait.\"}\n```")).sentence == "I wait."
    check parseDecision(extractJsonObject(
      "Sure! {\"action\": \"I wait.\"} Hope that helps.")).sentence ==
      "I wait."
    expect CogmudError:
      discard extractJsonObject("no object here at all")

  test "cleanText cuts on a rune boundary and marks the cut":
    let cut = cleanText("\u00E9".repeat(50), 10)
    check cut.runeLen == 10
    check cut.validateUtf8() == -1
    check cut.endsWith("\u2026")

  test "PLAYER_SCRIPTED values map to the two baselines":
    check parseScriptKind("factor") == skFactor
    check parseScriptKind("1") == skFactor
    check parseScriptKind("true") == skFactor
    check parseScriptKind("yes") == skFactor
    check parseScriptKind("magpie") == skMagpie
    check parseScriptKind("thief") == skMagpie
    check parseScriptKind("") == skNone
    check parseScriptKind("nonsense") == skNone
