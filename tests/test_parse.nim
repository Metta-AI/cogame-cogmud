## The intent grammar. A table of sentences to expected (intent, slots) that
## covers every verb synonym at least once, the whole phrasebook, paraphrases
## the phrasebook does not contain, the slot rules, verb precedence, speech
## lifting, the failure vocabulary and robustness against junk.

import std/[strutils, unittest]
import cogmud/sim
import cogmud/llm

proc fixtureConfig(seed = 0): GameConfig =
  result = defaultGameConfig()
  result.turns = 14
  result.seed = seed
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

## A fixed table so the tests read the same aliases every run: seat 0 is
## renamed to a known set by hand.
proc table0(): Sim =
  result = initSim(fixtureConfig(seed = 101))
  result.names = @["Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt", "Piston"]
  ## Seat 0 stands in Market Square with everyone else beside it, so every
  ## cog alias resolves and no NPC is defaulted in by the room.
  for seat in 0 ..< Seats:
    result.cogs[seat].room = 0

proc atShop(npc: int): Sim =
  result = table0()
  for seat in 0 ..< Seats:
    result.cogs[seat].room = Npcs[npc].room

const RoomMarket = 0
const RoomKettle = 1
const RoomRow = 2
const RoomSmithy = 3
const RoomYard = 4
const RoomDocks = 5
const RoomAlley = 6
const RoomChapel = 7
const RoomGuild = 8

const ItemHide = 0
const ItemNails = 1
const ItemRope = 2
const ItemSalt = 3
const ItemLamp = 4
const ItemRelic = 5

# 1 -------------------------------------------------------------------------
suite "the sentence table":
  ## (sentence, expected intent, expected room|-1, expected item|-1,
  ##  expected qty|-1 to skip, expected npc|-1, expected other cog|-1,
  ##  expected coin|-1 to skip)
  const Cases = [
    # --- iMove: every synonym in the table ---
    ("I go to the Docks.", iMove, RoomDocks, -1, -1, -1, -1, -1),
    ("She goes to the Chapel.", iMove, RoomChapel, -1, -1, -1, -1, -1),
    ("I am going to the Guildhall.", iMove, RoomGuild, -1, -1, -1, -1, -1),
    ("I walk down to the Docks.", iMove, RoomDocks, -1, -1, -1, -1, -1),
    ("He walks to Tanner's Row.", iMove, RoomRow, -1, -1, -1, -1, -1),
    ("I head for the Warehouse Yard.", iMove, RoomYard, -1, -1, -1, -1, -1),
    ("He heads to The Smithy.", iMove, RoomSmithy, -1, -1, -1, -1, -1),
    ("I move to Cutpurse Alley.", iMove, RoomAlley, -1, -1, -1, -1, -1),
    ("I travel to Market Square.", iMove, RoomMarket, -1, -1, -1, -1, -1),
    ("I run to The Copper Kettle.", iMove, RoomKettle, -1, -1, -1, -1, -1),
    ("I ride out to the harbour.", iMove, RoomDocks, -1, -1, -1, -1, -1),
    ("I leave for the Guildhall.", iMove, RoomGuild, -1, -1, -1, -1, -1),
    ("I enter the tavern.", iMove, RoomKettle, -1, -1, -1, -1, -1),
    ("I cross to the shrine.", iMove, RoomChapel, -1, -1, -1, -1, -1),
    ("I slip into the alley.", iMove, RoomAlley, -1, -1, -1, -1, -1),
    ("I return to the well.", iMove, RoomMarket, -1, -1, -1, -1, -1),
    ("I make for the stores.", iMove, RoomYard, -1, -1, -1, -1, -1),
    ("I wander over to the quay.", iMove, RoomDocks, -1, -1, -1, -1, -1),
    # a paraphrase the phrasebook does not contain
    ("Off to the harbour with me.", iMove, RoomDocks, -1, -1, -1, -1, -1),

    # --- iTake ---
    ("I take the rope.", iTake, -1, ItemRope, 1, -1, -1, -1),
    ("He takes two hides.", iTake, -1, ItemHide, 2, -1, -1, -1),
    ("I pick up the coil of rope.", iTake, -1, ItemRope, 1, -1, -1, -1),
    ("She picks up the salt.", iTake, -1, ItemSalt, 1, -1, -1, -1),
    ("I grab all the nails.", iTake, -1, ItemNails, QtyAll, -1, -1, -1),
    ("I lift the lamp.", iTake, -1, ItemLamp, 1, -1, -1, -1),
    ("I collect three hides.", iTake, -1, ItemHide, 3, -1, -1, -1),
    ("I scoop up the brine.", iTake, -1, ItemSalt, 1, -1, -1, -1),
    ("I pocket the idol.", iTake, -1, ItemRelic, 1, -1, -1, -1),

    # --- iDrop ---
    ("I drop the relic here.", iDrop, -1, ItemRelic, 1, -1, -1, -1),
    ("He drops two lamps.", iDrop, -1, ItemLamp, 2, -1, -1, -1),
    ("I leave the rope here.", iDrop, -1, ItemRope, 1, -1, -1, -1),
    ("I put the salt down.", iDrop, -1, ItemSalt, 1, -1, -1, -1),
    ("I discard the hide.", iDrop, -1, ItemHide, 1, -1, -1, -1),
    ("I set down the nails.", iDrop, -1, ItemNails, 1, -1, -1, -1),

    # --- iSell (at a shop, so the NPC may be named or defaulted) ---
    ("I sell three nails to Dockmaster Fen.", iSell, -1, ItemNails, 3, 3, -1,
      -1),
    ("He sells two hides to Tanner Oda.", iSell, -1, ItemHide, 2, 0, -1, -1),
    ("I offload four rope on Smith Bram.", iSell, -1, ItemRope, 4, 1, -1, -1),
    ("I unload the salt on Keeper Nesh.", iSell, -1, ItemSalt, 1, 2, -1, -1),
    ("I flog a relic to Dockmaster Fen.", iSell, -1, ItemRelic, 1, 3, -1, -1),

    # --- iGive ---
    ("I give Gizmo one lamp.", iGive, -1, ItemLamp, 1, -1, 1, -1),
    ("He gives Bolt two hides.", iGive, -1, ItemHide, 2, -1, 4, -1),
    ("I hand Guildmaster Vell two hides for my commission.", iGive, -1,
      ItemHide, 2, 4, -1, -1),
    ("She hands Ratchet the rope.", iGive, -1, ItemRope, 1, -1, 2, -1),
    ("I deliver two rope to Guildmaster Vell.", iGive, -1, ItemRope, 2, 4, -1,
      -1),
    ("He delivers the salt to Guildmaster Vell.", iGive, -1, ItemSalt, 1, 4,
      -1, -1),
    ("I turn in two nails to Guildmaster Vell.", iGive, -1, ItemNails, 2, 4,
      -1, -1),
    ("I present the relic to Guildmaster Vell.", iGive, -1, ItemRelic, 1, 4,
      -1, -1),
    ("I donate a lamp to Guildmaster Vell.", iGive, -1, ItemLamp, 1, 4, -1,
      -1),
    ("I pay Widget 12 coins.", iGive, -1, -1, -1, -1, 3, 12),
    # a paraphrase the phrasebook does not contain
    ("Vell can have these hides.", iGive, -1, ItemHide, -1, 4, -1, -1),

    # --- iTrade ---
    ("I offer Gizmo one lamp for twelve coins.", iTrade, -1, ItemLamp, 1, -1,
      1, 12),
    ("He offers Bolt two hides for 9 coins.", iTrade, -1, ItemHide, 2, -1, 4,
      9),
    ("I propose Ratchet a rope for 10 coin.", iTrade, -1, ItemRope, 1, -1, 2,
      10),
    ("I trade Widget one relic for 20 coins.", iTrade, -1, ItemRelic, 1, -1,
      3, 20),
    ("I swap Piston a lamp for twelve pieces.", iTrade, -1, ItemLamp, 1, -1,
      5, 12),
    ("I barter Gizmo three salt for 15 silver.", iTrade, -1, ItemSalt, 3, -1,
      1, 15),

    # --- iAccept ---
    ("I accept Gizmo's offer.", iAccept, -1, -1, -1, -1, 1, -1),
    ("He accepts Bolt's offer.", iAccept, -1, -1, -1, -1, 4, -1),
    ("I agree to Ratchet's terms.", iAccept, -1, -1, -1, -1, 2, -1),
    ("I take Widget's offer.", iAccept, -1, -1, -1, -1, 3, -1),
    ("I shake on Piston's deal.", iAccept, -1, -1, -1, -1, 5, -1),

    # --- iHire ---
    ("I hire Bolt for fifteen coins to walk the road with me.", iHire, -1, -1,
      -1, -1, 4, 15),
    ("He hires Gizmo for 8 coins.", iHire, -1, -1, -1, -1, 1, 8),
    ("I employ Ratchet for 6 coins.", iHire, -1, -1, -1, -1, 2, 6),
    ("I retain Widget for 20 coin.", iHire, -1, -1, -1, -1, 3, 20),
    ("I engage Piston for 5 coins.", iHire, -1, -1, -1, -1, 5, 5),

    # --- iRob ---
    ("I rob Gizmo.", iRob, -1, -1, -1, -1, 1, -1),
    ("He robs Bolt.", iRob, -1, -1, -1, -1, 4, -1),
    ("I steal from Ratchet.", iRob, -1, -1, -1, -1, 2, -1),
    ("I am stealing from Widget.", iRob, -1, -1, -1, -1, 3, -1),
    ("I mug Piston.", iRob, -1, -1, -1, -1, 5, -1),
    ("I jump Ratchet here in the dark and take what he is carrying.", iRob,
      -1, -1, -1, -1, 2, -1),
    ("I ambush Gizmo.", iRob, -1, -1, -1, -1, 1, -1),
    ("I lift what Bolt is carrying.", iRob, -1, -1, -1, -1, 4, -1),
    ("I pick Gizmo's pocket.", iRob, -1, -1, -1, -1, 1, -1),
    ("I cut Widget's purse.", iRob, -1, -1, -1, -1, 3, -1),
    ("I waylay Piston.", iRob, -1, -1, -1, -1, 5, -1),

    # --- iSay ---
    ("I say the tanner pays well.", iSay, -1, -1, -1, -1, -1, -1),
    ("He says nothing worth hearing.", iSay, -1, -1, -1, -1, -1, -1),
    ("I tell everyone the alley is clear.", iSay, -1, -1, -1, -1, -1, -1),
    ("She tells the room a lie.", iSay, -1, -1, -1, -1, -1, -1),
    ("I shout that prices are rising.", iSay, -1, -1, -1, -1, -1, -1),
    ("I call out a warning.", iSay, -1, -1, -1, -1, -1, -1),
    ("I announce my terms.", iSay, -1, -1, -1, -1, -1, -1),
    ("I whisper a rumour.", iSay, -1, -1, -1, -1, -1, -1),

    # --- iWait ---
    ("I wait by the well and listen.", iWait, -1, -1, -1, -1, -1, -1),
    ("He waits.", iWait, -1, -1, -1, -1, -1, -1),
    ("I rest a while.", iWait, -1, -1, -1, -1, -1, -1),
    ("I linger.", iWait, -1, -1, -1, -1, -1, -1),
    ("I idle.", iWait, -1, -1, -1, -1, -1, -1),
    ("I stay put.", iWait, -1, -1, -1, -1, -1, -1),
    ("I do nothing.", iWait, -1, -1, -1, -1, -1, -1),
    ("I look around.", iWait, -1, -1, -1, -1, -1, -1)
  ]

  test "every sentence in the table reads as its intent and slots":
    let sim = table0()
    for entry in Cases:
      let intent = parseSentence(sim, 0, entry[0])
      checkpoint(entry[0] & " -> " & $intent.kind & " reason " & $intent.reason)
      check intent.kind == entry[1]
      if entry[2] >= 0: check intent.toRoom == entry[2]
      if entry[3] >= 0: check intent.item == entry[3]
      if entry[4] >= 0: check intent.qty == entry[4]
      if entry[5] >= 0: check intent.npc == entry[5]
      if entry[6] >= 0: check intent.other == entry[6]
      if entry[7] >= 0: check intent.coin == entry[7]

  test "the twelve phrasebook lines all read":
    let sim = atShop(GuildNpc)
    for line in Phrasebook:
      let intent = parseSentence(sim, 0, line)
      checkpoint(line & " -> " & $intent.kind & " (" & $intent.reason & ")")
      check intent.kind != iNone

  test "the buy verbs need a shop in the room or a shop by name":
    let shop = atShop(0)              # Tanner Oda at Tanner's Row
    for line in ["I buy two hides from Tanner Oda.", "He buys a hide.",
        "I purchase three salt.", "I acquire two hides.",
        "I pay for one hide."]:
      let intent = parseSentence(shop, 0, line)
      checkpoint(line & " -> " & $intent.kind & " (" & $intent.reason & ")")
      check intent.kind == iBuy
      check intent.npc == 0
    # a paraphrase the phrasebook does not contain: verbless, at a shop
    let verbless = parseSentence(shop, 0, "Two hides, tanner, and be quick.")
    check verbless.kind == iBuy
    check verbless.item == ItemHide
    check verbless.qty == 2

  test "the quest verbs need a shopkeeper":
    let shop = atShop(GuildNpc)
    for line in ["I ask Guildmaster Vell about my commissions.",
        "I enquire about my commissions.", "I inquire after the goods.",
        "I check the board.", "I consult the board.", "I read the board."]:
      let intent = parseSentence(shop, 0, line)
      checkpoint(line & " -> " & $intent.kind & " (" & $intent.reason & ")")
      check intent.kind == iQuest
      check intent.npc == GuildNpc

# 2 -------------------------------------------------------------------------
suite "slot resolution":
  test "number words, digits and all":
    let sim = table0()
    const Numbers = [("a hide", 1), ("an idol", 1), ("one hide", 1),
      ("two hides", 2), ("three hides", 3), ("four hides", 4),
      ("five hides", 5), ("six hides", 6), ("seven hides", 7),
      ("eight hides", 8), ("nine hides", 9), ("ten hides", 10),
      ("eleven hides", 11), ("twelve hides", 12), ("7 hides", 7)]
    for entry in Numbers:
      let intent = parseSentence(sim, 0, "I take " & entry[0] & ".")
      checkpoint(entry[0])
      check intent.kind == iTake
      check intent.qty == entry[1]
    check parseSentence(sim, 0, "I take all the hides.").qty == QtyAll
    check parseSentence(sim, 0, "I take every hide.").qty == QtyAll

  test "possessives keep the stem":
    let sim = table0()
    let intent = parseSentence(sim, 0, "I accept Gizmo's offer.")
    check intent.kind == iAccept
    check intent.other == 1

  test "plurals and keyword aliases for every room, item and shop":
    let sim = table0()
    for room in Rooms:
      for keyword in room.keywords:
        let intent = parseSentence(sim, 0, "I go to the " & keyword & ".")
        checkpoint(room.name & " via " & keyword)
        check intent.kind == iMove
        check intent.toRoom == room.id
      let byName = parseSentence(sim, 0, "I go to " & room.name & ".")
      check byName.kind == iMove
      check byName.toRoom == room.id
    for item in Items:
      for keyword in item.keywords:
        let intent = parseSentence(sim, 0, "I drop the " & keyword & ".")
        checkpoint(item.name & " via " & keyword)
        check intent.kind == iDrop
        check intent.item == item.id
    for npc in Npcs:
      let shop = atShop(npc.id)
      for keyword in npc.keywords:
        let intent = parseSentence(shop, 0, "I sell one hide to " & keyword &
          ".")
        checkpoint(npc.name & " via " & keyword)
        check intent.kind == iSell
        check intent.npc == npc.id
      let byName = parseSentence(shop, 0, "I sell one hide to " & npc.name &
        ".")
      check byName.kind == iSell
      check byName.npc == npc.id

  test "coin reads from a coin word or from the number after for":
    let sim = table0()
    check parseSentence(sim, 0,
      "I offer Gizmo one lamp for 12 coins.").coin == 12
    check parseSentence(sim, 0,
      "I offer Gizmo one lamp, 12 coin.").coin == 12
    check parseSentence(sim, 0,
      "I offer Gizmo one lamp for twelve pieces.").coin == 12
    check parseSentence(sim, 0,
      "I offer Gizmo one lamp for 12.").coin == 12

  test "a buy with no shop named defaults to the one in the room, or fails":
    let shop = atShop(1)              # Smith Bram at The Smithy
    let defaulted = parseSentence(shop, 0, "I buy two rope.")
    check defaulted.kind == iBuy
    check defaulted.npc == 1
    let bare = table0()               # Market Square keeps no shop
    let failed = parseSentence(bare, 0, "I buy two rope.")
    check failed.kind == iNone
    check failed.reason == oNoTarget

# 3 -------------------------------------------------------------------------
suite "verb precedence":
  test "the first verb in the sentence wins, and the rule cannot drift":
    let sim = table0()
    let intent = parseSentence(sim, 0, "I walk to the docks and buy a rope")
    check intent.kind == iMove
    check intent.toRoom == RoomDocks
    let shop = atShop(1)          # Smith Bram deals in rope
    let other = parseSentence(shop, 0, "I buy a rope then walk to the docks")
    check other.kind == iBuy
    check other.item == ItemRope

# 4 -------------------------------------------------------------------------
suite "speech lifting":
  test "quoted text is lifted out of the parse and spoken":
    let shop = atShop(GuildNpc)
    let intent = parseSentence(shop, 0,
      "I hand Vell two hides and tell Bolt, \"the alley is clear.\"")
    check intent.kind == iGive
    check intent.npc == GuildNpc
    check intent.item == ItemHide
    check intent.spoken == "the alley is clear."

  test "curly quotes work too":
    let shop = atShop(GuildNpc)
    let intent = parseSentence(shop, 0,
      "I hand Vell two hides and say \u201Cthe alley is clear\u201D.")
    check intent.kind == iGive
    check intent.spoken == "the alley is clear"

  test "an unterminated quote lifts nothing and the whole string parses":
    let sim = table0()
    let intent = parseSentence(sim, 0, "I go to the Docks \"and then")
    check intent.kind == iMove
    check intent.toRoom == RoomDocks
    check intent.spoken == ""

# 5 -------------------------------------------------------------------------
suite "the failure vocabulary":
  test "no verb, no target, ambiguity, an unknown cog, and self-targeting":
    let sim = table0()
    let noVerb = parseSentence(sim, 0, "The weather in this town.")
    check noVerb.kind == iNone
    check noVerb.reason == oNoVerb

    let noTarget = parseSentence(sim, 0, "I go.")
    check noTarget.kind == iNone
    check noTarget.reason == oNoTarget

    let ambiguous = parseSentence(sim, 0, "I go to the tanner or the smith")
    check ambiguous.kind == iNone
    check ambiguous.reason == oAmbiguousTarget

    let unknown = parseSentence(sim, 0, "I rob Zephyr.")
    check unknown.kind == iNone
    check unknown.reason == oNoSuchCog

    let self = parseSentence(sim, 0, "I rob myself.")
    check self.kind == iNone
    check self.reason == oSelfTarget

    let sameName = parseSentence(sim, 0, "I rob Sprocket.")
    check sameName.kind == iNone
    check sameName.reason == oSelfTarget

  test "accept with nothing open is no_such_offer":
    let sim = table0()
    let intent = parseSentence(sim, 0, "I accept the offer.")
    check intent.kind == iNone
    check intent.reason == oNoSuchOffer

  test "a quest with no shopkeeper anywhere is no_npc_here":
    let sim = table0()          # Market Square keeps no shop
    let intent = parseSentence(sim, 0, "I check the board.")
    check intent.kind == iNone
    check intent.reason == oNoNpcHere

  test "every outcome reason has prose a seat can read":
    ## Half of the design's claim: outcomeText names all 26. The other half -
    ## that the rules PRODUCE 25 of them, and why `rejected` is the exception -
    ## is driven case by case in test_sim.nim's outcome-vocabulary suite.
    var seen = 0
    for reason in Outcome:
      let text = table0().outcomeText(
        Intent(kind: iWait, room: 0, toRoom: -1, item: -1, qty: 1, npc: -1,
          other: -1, coin: 0, reason: reason, spoken: ""), reason)
      check text.len > 0
      inc seen
    check seen == 26

# 6 -------------------------------------------------------------------------
suite "robustness":
  test "junk never raises and always yields a legal intent":
    let sim = table0()
    let junk = [
      "",
      "   ",
      "!!!???,,,...;;;---''''\"\"\"\"" & "!".repeat(240),
      "Gizmo",
      "{\"action\": \"I go to the Docks\", \"say\": \"\"}",
      "market square kettle tanner smithy warehouse docks alley chapel " &
        "guildhall",
      "\u00E9\u00E9\u00E9\u00E9\u00E9",
      "I",
      "I I I I I I I I",
      "buy buy buy",
      "\u201C\u201D"
    ]
    for line in junk:
      let intent = parseSentence(sim, 0, line)
      checkpoint("[" & line[0 ..< min(line.len, 40)] & "] -> " &
        $intent.kind & " / " & $intent.reason)
      check intent.qty >= 1
      check intent.room >= 0 and intent.room < RoomCount
      if intent.kind == iNone:
        check intent.reason != oOk

  test "a sentence naming every room keyword at once is ambiguous, not fatal":
    let sim = table0()
    let intent = parseSentence(sim, 0,
      "I go to the market, the tavern, the tannery, the forge, the yard, " &
      "the quay, the lane, the shrine and the guild.")
    check intent.kind == iNone
    check intent.reason == oAmbiguousTarget

  test "a 240-rune sentence of punctuation parses without raising":
    let sim = table0()
    let intent = parseSentence(sim, 0, "?.,;:!".repeat(40))
    check intent.kind == iNone
    check intent.reason in [oNoVerb, oUnparsed]

# the observation names every referent the grammar can resolve ---------------
suite "the observation enumerates every noun and no verb":
  test "each room's exits, floor, cogs and goods are named in the prompt":
    var sim = initSim(fixtureConfig(seed = 111))
    for turn in 0 ..< 3:
      for seat in 0 ..< Seats:
        let prompt = sim.userPrompt(seat, "")
        let room = sim.cogs[seat].room
        for exit in Rooms[room].exits:
          check Rooms[exit].name in prompt
        for item in 0 ..< ItemKinds:
          if sim.rooms[room].items[item] > 0:
            check Items[item].name in prompt
        let npc = npcInRoom(room)
        if npc >= 0:
          check Npcs[npc].name in prompt
      for seat in sim.pendingSeats():
        sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
          true)
