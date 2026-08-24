## Pure game rules for Cogmud. No IO, no networking, no LLM — the server, the
## tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded starting rooms, commissions and
## ground items, the nine room floors, the five shops' books, the six cogs, the
## live offers, each seat's private notes, and the append-only event log.
## Everything random is drawn from the seed at `initSim`, so a replay
## re-derives the episode from the recorded `act` events alone.
##
## Every integer here stays far below 2^31 — coin is a few hundred, points at
## most 40, stock at most 12 — so plain `int` is safe on wasm32, where Nim's
## `int` is 32 bits (contagion, 2026-08-23). `tests/test_sim.nim` item 12
## asserts it over a maximal episode.

import std/[json, random, strutils, unicode], types, parse

export types, parse

const
  StartCoin* = 40
  CarryLimit* = 8
  RefStock* = 6
  PriceStep* = 1
  StockCap* = 12
  NpcStartCoin* = 120
  PointsPerUnit* = 4
  CompletionBonus* = 8
  PointValue* = 3
  ScoreScale* = 40.0
  RetainerTurns* = 3
  RobCoin* = 10
  FineCoin* = 8
  MinTurns* = 6
  MaxTurns* = 40
  PlayBudgetFraction* = 0.6
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 20_000
  ## Wall-clock floor between LLM batches. Six seats at one request each is 30
  ## requests a minute exactly at 12 s, which is the hosted Bedrock sidecar's
  ## per-episode cap (raid, 2026-08-23).
  MinBatchSpacingMs* = 12_000
  MaxSentenceLen* = 240
  MaxSayLen* = 160
  MaxNotesLen* = 600
  MaxRoomLog* = 12
  MaxRoomLogLen* = 200
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the town: every seat plays under an
  ## anonymous cog alias, drawn deterministically from the seed so replays and
  ## the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc turnBudgetSeconds*(config: GameConfig): int =
  ## Worst case wall clock for one turn: the batch plus the one retry batch.
  ## The six requests inside a batch are parallel, so six seats cost the same
  ## wall clock as one.
  config.llmTimeoutSeconds + max(8, config.llmTimeoutSeconds div 2)

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the turn count into the episode's clock. Idempotent: a config that
  ## already carries the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  let budget = PlayBudgetFraction * config.episodeTimeoutSeconds.float -
    config.playerConnectTimeoutSeconds - (PacingBudgetMs / 1000).float
  let fitted = int(budget / turnBudgetSeconds(config).float)
  let hi = max(MinTurns, min(MaxTurns, fitted))
  result.turns = max(MinTurns, min(config.turns, hi))
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.turns, 1))
  result.sampled = true

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, turn: -1, seat: -1, order: -1, intent: iNone,
    room: -1, toRoom: -1, item: -1, qty: 0, npc: -1, other: -1, coin: 0,
    reason: oOk, salience: 0)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

# ---- Prices -----------------------------------------------------------------

proc askAt*(item, stock: int): int =
  ## What a shopkeeper charges for one unit at that stock level. At RefStock an
  ## item sells for exactly its base value; short stock costs more, deep stock
  ## less, both clamped.
  let base = Items[item].baseValue
  let raw = base + PriceStep * (RefStock - stock)
  max(max(2, base div 2), min(raw, base * 3))

proc bidAt*(item, stock: int): int =
  ## Two thirds of the ask: the spread is the shopkeeper's living.
  max(1, askAt(item, stock) * 2 div 3)

proc ask*(sim: Sim, npc, item: int): int =
  askAt(item, sim.npcs[npc].stock[item])

proc bid*(sim: Sim, npc, item: int): int =
  bidAt(item, sim.npcs[npc].stock[item])

proc dealsIn*(npc, item: int): bool =
  item in Npcs[npc].tradeList

# ---- Queries ----------------------------------------------------------------

proc carried*(sim: Sim, seat: int): int =
  for count in sim.cogs[seat].items:
    result += count

proc wealth*(sim: Sim, seat: int): int =
  result = sim.cogs[seat].coin
  for item in 0 ..< ItemKinds:
    result += Items[item].baseValue * sim.cogs[seat].items[item]

proc questPoints*(sim: Sim, seat: int): int =
  for quest in sim.quests[seat]:
    result += PointsPerUnit * quest.delivered
    if quest.delivered >= quest.count:
      result += CompletionBonus

proc score*(sim: Sim, seat: int): float =
  (sim.wealth(seat) + PointValue * sim.questPoints(seat) - StartCoin).float /
    ScoreScale

proc deliveredTotal*(sim: Sim, seat: int): int =
  for quest in sim.quests[seat]:
    result += quest.delivered

proc initiativeOrder*(turn: int): array[Seats, int] =
  ## A deterministic rotation, no rng: on turn t the seats resolve in the order
  ## (k + t) mod 6. Every seat leads exactly turns/6 times and nothing depends
  ## on a slot number.
  for k in 0 ..< Seats:
    result[k] = (k + turn) mod Seats

proc pendingSeats*(sim: Sim): seq[int] =
  ## Every seat that has not acted this turn, in seat order. Empty once the
  ## episode is over.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if not sim.acts[seat].acted:
      result.add(seat)

proc outstanding*(sim: Sim, seat, quest: int): int =
  max(0, sim.quests[seat][quest].count - sim.quests[seat][quest].delivered)

proc needs*(sim: Sim, seat, item: int): int =
  ## How many more units of `item` this seat's open commissions still want.
  for index in 0 ..< Quests:
    if sim.quests[seat][index].item == item:
      result += sim.outstanding(seat, index)

# ---- Text -------------------------------------------------------------------

proc cutRunes*(text: string, limit: int): string =
  ## Cut on a rune boundary: a byte slice through a multi-byte character would
  ## leave invalid UTF-8 in the replay and break its strict JSON parse.
  result = text
  if result.runeLen > limit:
    result = result.runeSubStr(0, limit)

proc oneLine(text: string): string =
  text.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip()

proc logRoom(sim: var Sim, room: int, line: string) =
  ## One public act line, capped so a long sentence cannot flood the twelve
  ## lines a seat reads next turn.
  if room < 0 or room >= RoomCount:
    return
  sim.roomLog[room].add(cutRunes(oneLine(line), MaxRoomLogLen))
  if sim.roomLog[room].len > MaxRoomLog:
    sim.roomLog[room].delete(0)

# ---- Turn open --------------------------------------------------------------

proc logTurn(sim: var Sim) =
  var event = blankEvent(evTurn)
  event.turn = sim.turn
  for room in sim.rooms:
    event.rooms.add(room)
  for npc in sim.npcs:
    event.npcs.add(npc)
  for cog in sim.cogs:
    event.cogs.add(cog)
  sim.addEvent(event)

proc openTurn(sim: var Sim) =
  ## The turn becomes live: stale offers expire, retainers tick down, the shops
  ## restock, and last turn's public lines become what each seat reads.
  var live: seq[Offer]
  for offer in sim.offers:
    ## An offer lives exactly one turn: posted on t, acceptable only on t + 1.
    if offer.postedTurn >= sim.turn - 1:
      live.add(offer)
  sim.offers = live

  for seat in 0 ..< Seats:
    if sim.cogs[seat].retainerTurns > 0:
      dec sim.cogs[seat].retainerTurns
      if sim.cogs[seat].retainerTurns == 0:
        sim.cogs[seat].retainerOf = -1
    sim.acts[seat] = PendingAct()

  ## Restock at the open of every turn after the first: the world table's
  ## stock is what the shops hold at turn 0.
  if sim.turn > 0:
    for npc in 0 ..< NpcCount:
      let trade = Npcs[npc].tradeList
      let item = trade[sim.turn mod trade.len]
      if sim.npcs[npc].stock[item] < StockCap:
        inc sim.npcs[npc].stock[item]

  for room in 0 ..< RoomCount:
    sim.heardLog[room] = sim.roomLog[room]
    sim.roomLog[room] = @[]

  sim.phase = phTurn
  sim.logTurn()

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(CogmudError,
      "cogmud needs exactly " & $Seats & " players")
  if config.turns < MinTurns:
    raise newException(CogmudError, "turns must be at least " & $MinTurns)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  result.notes = newSeq[string](Seats)

  for npc in 0 ..< NpcCount:
    result.npcs[npc].coin = NpcStartCoin
    for index, item in Npcs[npc].tradeList:
      result.npcs[npc].stock[item] = Npcs[npc].initialStock[index]

  ## ONE stream, in this fixed order: starting rooms, commissions, ground
  ## items. Aliases come from tableNames's own stream, keyed as bullwhip keys
  ## it, so a replay re-derives the whole town from the seed.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var rooms: seq[int]
  for room in 0 ..< RoomCount:
    rooms.add(room)
  rng.shuffle(rooms)
  for seat in 0 ..< Seats:
    result.cogs[seat] = CogState(room: rooms[seat], prevRoom: -1,
      coin: StartCoin, retainerOf: -1, retainerTurns: 0)
  for seat in 0 ..< Seats:
    var pool = @QuestItems
    rng.shuffle(pool)
    for index in 0 ..< Quests:
      result.quests[seat][index] =
        Quest(item: pool[index], count: 2, delivered: 0)
  for room in [0, 4, 5, 6, 7]:
    inc result.rooms[room].items[rng.rand(ItemKinds - 1)]
  inc result.rooms[4].items[5]

  result.turn = 0
  result.addEvent(blankEvent(evStart))
  result.openTurn()

# ---- Salience ---------------------------------------------------------------

proc salienceOf*(event: GameEvent): int =
  ## The highlight reel is chosen by this, not by tick order. A pure function
  ## of the recorded `act` event, so the viewer can recompute it in the browser.
  if event.kind != evAct:
    return 0
  case event.intent
  of iRob:
    if event.reason == oOk: 100
    elif event.reason == oRobberyFailed or event.reason == oNothingToTake: 80
    else: 5
  of iGive:
    if event.reason != oOk: 5
    elif event.npc == GuildNpc:
      ## `coin` on a delivery carries the points this delivery banked, so a
      ## completion (which adds the bonus) is visible from the event alone.
      if event.coin > PointsPerUnit * max(event.qty, 1): 90 else: 60
    elif event.npc >= 0: 25
    else: 35
  of iAccept:
    if event.reason != oOk: 5
    elif event.item < 0: 70      ## a hire: no goods move
    else: 65
  of iBuy, iSell:
    if event.reason != oOk: 5
    elif event.coin >= 20: 45
    else: 25
  of iTrade, iHire:
    if event.reason == oOk: 40 else: 5
  of iSay:
    if event.say.runeLen > 40: 30 else: 20
  of iTake, iDrop:
    if event.reason == oOk: 15 else: 5
  of iMove:
    if event.reason == oOk: 10 else: 5
  of iQuest:
    if event.reason == oOk: 15 else: 5
  of iWait, iNone:
    5

# ---- Outcome prose ----------------------------------------------------------

proc outcomeText*(sim: Sim, intent: Intent, reason: Outcome): string =
  ## The verbatim explanation a seat reads next turn. This is how a policy
  ## learns the grammar, and it is why no menu is needed.
  let here = Rooms[intent.room].name
  case reason
  of oOk: "understood."
  of oWaited: "you waited and watched."
  of oUnparsed: "not understood: the town could make nothing of it."
  of oNoVerb:
    "not understood: it names no action the town knows. Say what you DO."
  of oNoTarget:
    "not understood: it names an action but nothing to do it to."
  of oAmbiguousTarget:
    "not understood: it names two things at once and the town cannot tell " &
      "which you meant."
  of oNoSuchExit:
    "there is no road from " & here & " to that place."
  of oNoSuchItem: "there is none of that lying here."
  of oNotCarrying: "you are not carrying that."
  of oCarryLimit: "your pack is full: you can carry " & $CarryLimit & " things."
  of oNoNpcHere: "there is no shopkeeper in " & here & "."
  of oNotWanted: "that shopkeeper does not deal in that."
  of oOutOfStock: "that shopkeeper has none of that."
  of oCannotAfford: "you have not the coin for that."
  of oNpcBroke: "that shopkeeper has run out of coin."
  of oNoMatchingCommission:
    "no open commission of yours wanted that, and the goods are gone."
  of oNoSuchCog: "no cog of that name is in this town."
  of oNotInRoom: "that cog is not here in " & here & "."
  of oSelfTarget: "you cannot do that to yourself."
  of oNoSuchOffer: "no such offer is open to you this turn."
  of oOfferExpired:
    "the offer could not be settled: somebody could no longer pay or deliver."
  of oBoundByContract: "you are hired to that cog and cannot rob it."
  of oRobberyFailed: "the attempt failed."
  of oNothingToTake: "there was nothing on them worth taking."
  of oThieveryForbidden: "the watch is everywhere in this town; nobody robs."
  of oRejected: "the town refused the action; you waited instead."

# ---- Resolution helpers -----------------------------------------------------

proc credit(sim: var Sim, seat, quest, units: int): int =
  ## Bank `units` toward one commission and return the points it earned.
  sim.quests[seat][quest].delivered += units
  sim.cogs[seat].delivered[quest] = sim.quests[seat][quest].delivered
  result = PointsPerUnit * units
  if sim.quests[seat][quest].delivered >= sim.quests[seat][quest].count and
      sim.quests[seat][quest].delivered - units <
        sim.quests[seat][quest].count:
    result += CompletionBonus

proc retainersPresent(sim: Sim, employer, room: int): int =
  for seat in 0 ..< Seats:
    if sim.cogs[seat].retainerOf == employer and
        sim.cogs[seat].retainerTurns > 0 and sim.cogs[seat].room == room:
      inc result

proc bestLoot(sim: Sim, seat: int): int =
  ## The victim's highest-BaseValue item, ties broken by lowest item id.
  result = -1
  for item in 0 ..< ItemKinds:
    if sim.cogs[seat].items[item] > 0:
      if result < 0 or Items[item].baseValue > Items[result].baseValue:
        result = item

proc cogHere(sim: Sim, seat, other: int): bool =
  other >= 0 and other < Seats and sim.cogs[other].room == sim.cogs[seat].room

# ---- The six resolution classes ---------------------------------------------

type ActResult = object
  reason: Outcome
  item: int
  qty: int
  npc: int
  other: int
  coin: int
  toRoom: int
  line: string        ## the public act line, "" when nothing is public

proc blankResult(intent: Intent): ActResult =
  ActResult(reason: oOk, item: intent.item, qty: 0, npc: intent.npc,
    other: intent.other, coin: 0, toRoom: intent.toRoom, line: "")

proc resolveBuy(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let me = sim.cogs[seat].room
  let npc = intent.npc
  if npc < 0 or Npcs[npc].room != me:
    result.reason = oNoNpcHere
    return
  if not dealsIn(npc, intent.item):
    result.reason = oOutOfStock
    return
  let free = CarryLimit - sim.carried(seat)
  if free <= 0:
    result.reason = oCarryLimit
    return
  if sim.npcs[npc].stock[intent.item] <= 0:
    result.reason = oOutOfStock
    return
  var want = min(min(intent.qty, sim.npcs[npc].stock[intent.item]), free)
  var spent = 0
  var got = 0
  ## Each unit is priced from the stock at the moment IT changes hands, which
  ## is why cornering a shop's stock is a real strategy.
  while got < want:
    let price = sim.ask(npc, intent.item)
    if sim.cogs[seat].coin < price:
      break
    sim.cogs[seat].coin -= price
    sim.npcs[npc].coin += price
    dec sim.npcs[npc].stock[intent.item]
    inc sim.cogs[seat].items[intent.item]
    spent += price
    inc got
  if got == 0:
    result.reason = oCannotAfford
    return
  result.qty = got
  result.coin = spent
  result.line = sim.names[seat] & " bought " & itemName(intent.item, got) &
    " from " & Npcs[npc].name & " for " & $spent & " coin."

proc resolveSell(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let me = sim.cogs[seat].room
  let npc = intent.npc
  if npc < 0 or Npcs[npc].room != me:
    result.reason = oNoNpcHere
    return
  if not dealsIn(npc, intent.item):
    result.reason = oNotWanted
    return
  let held = sim.cogs[seat].items[intent.item]
  if held <= 0:
    result.reason = oNotCarrying
    return
  var want = min(intent.qty, held)
  var earned = 0
  var sold = 0
  while sold < want:
    let price = sim.bid(npc, intent.item)
    if sim.npcs[npc].coin < price:
      break
    sim.npcs[npc].coin -= price
    sim.cogs[seat].coin += price
    dec sim.cogs[seat].items[intent.item]
    if sim.npcs[npc].stock[intent.item] < StockCap:
      inc sim.npcs[npc].stock[intent.item]
    earned += price
    inc sold
  if sold == 0:
    result.reason = oNpcBroke
    return
  result.qty = sold
  result.coin = earned
  result.line = sim.names[seat] & " sold " & itemName(intent.item, sold) &
    " to " & Npcs[npc].name & " for " & $earned & " coin."

proc resolveGiveNpc(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let npc = intent.npc
  if npc < 0 or Npcs[npc].room != sim.cogs[seat].room:
    result.reason = oNoNpcHere
    return
  if intent.item < 0:
    result.reason = oNoTarget
    return
  let held = sim.cogs[seat].items[intent.item]
  if held <= 0:
    result.reason = oNotCarrying
    return
  let units = min(intent.qty, held)
  ## The goods enter the shop's stock either way: handing something over is
  ## irrevocable, which is what makes a commission delivery a real commitment.
  sim.cogs[seat].items[intent.item] -= units
  sim.npcs[npc].stock[intent.item] =
    min(StockCap, sim.npcs[npc].stock[intent.item] + units)
  result.qty = units
  if npc != GuildNpc:
    result.reason = oNoMatchingCommission
    result.line = sim.names[seat] & " handed " & itemName(intent.item, units) &
      " to " & Npcs[npc].name & " for nothing."
    return
  var points = 0
  var credited = 0
  for quest in 0 ..< Quests:
    if sim.quests[seat][quest].item != intent.item:
      continue
    let room = min(units - credited, sim.outstanding(seat, quest))
    if room <= 0:
      continue
    points += sim.credit(seat, quest, room)
    credited += room
  if credited == 0:
    result.reason = oNoMatchingCommission
    result.line = sim.names[seat] & " handed " & itemName(intent.item, units) &
      " to " & Npcs[GuildNpc].name & ", who had no commission for it."
    return
  result.qty = credited
  ## `coin` on a delivery carries the POINTS banked, which is what the viewer
  ## stamps over the Guildhall and what salienceOf reads.
  result.coin = points
  result.line = sim.names[seat] & " delivered " &
    itemName(intent.item, credited) & " to " & Npcs[GuildNpc].name &
    " for " & $points & " commission points."

proc resolveGiveCog(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let other = intent.other
  if other < 0 or other >= Seats:
    result.reason = oNoSuchCog
    return
  if other == seat:
    result.reason = oSelfTarget
    return
  if not sim.cogHere(seat, other):
    result.reason = oNotInRoom
    return
  var moved = 0
  if intent.item >= 0:
    let free = CarryLimit - sim.carried(other)
    let units = min(min(intent.qty, sim.cogs[seat].items[intent.item]), free)
    if units > 0:
      sim.cogs[seat].items[intent.item] -= units
      sim.cogs[other].items[intent.item] += units
      moved = units
  var coin = min(intent.coin, sim.cogs[seat].coin)
  if coin > 0:
    sim.cogs[seat].coin -= coin
    sim.cogs[other].coin += coin
  if moved == 0 and coin == 0:
    result.reason =
      if intent.item >= 0 and sim.cogs[seat].items[intent.item] <= 0:
        oNotCarrying
      elif intent.item >= 0: oCarryLimit
      else: oNoTarget
    return
  result.qty = moved
  result.coin = coin
  var parts: seq[string]
  if moved > 0:
    parts.add(itemName(intent.item, moved))
  if coin > 0:
    parts.add($coin & " coin")
  result.line = sim.names[seat] & " gave " & parts.join(" and ") & " to " &
    sim.names[other] & "."

proc resolveTrade(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let other = intent.other
  if other < 0 or other >= Seats:
    result.reason = oNoSuchCog
    return
  if other == seat:
    result.reason = oSelfTarget
    return
  if not sim.cogHere(seat, other):
    result.reason = oNotInRoom
    return
  if intent.item < 0:
    result.reason = oNoTarget
    return
  let units = max(1, min(intent.qty, max(1, sim.cogs[seat].items[intent.item])))
  if sim.cogs[seat].items[intent.item] < units:
    result.reason = oNotCarrying
    return
  sim.offers.add(Offer(kind: okTrade, fromSeat: seat, toSeat: other,
    item: intent.item, qty: units, coin: max(0, intent.coin),
    postedTurn: sim.turn))
  result.qty = units
  result.coin = max(0, intent.coin)
  result.line = sim.names[seat] & " offered " & sim.names[other] & " " &
    itemName(intent.item, units) & " for " & $result.coin & " coin."

proc resolveHire(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let other = intent.other
  if other < 0 or other >= Seats:
    result.reason = oNoSuchCog
    return
  if other == seat:
    result.reason = oSelfTarget
    return
  if not sim.cogHere(seat, other):
    result.reason = oNotInRoom
    return
  let fee = min(max(1, intent.coin), sim.cogs[seat].coin)
  if fee < 1 or sim.cogs[seat].coin < fee:
    ## A hire offer above the employer's purse is never posted.
    result.reason = oCannotAfford
    return
  sim.offers.add(Offer(kind: okHire, fromSeat: seat, toSeat: other,
    item: -1, qty: 0, coin: fee, postedTurn: sim.turn))
  result.coin = fee
  result.item = -1
  result.line = sim.names[seat] & " offered to hire " & sim.names[other] &
    " for " & $fee & " coin."

proc resolveAccept(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  var found = -1
  for index, offer in sim.offers:
    if offer.toSeat != seat or offer.postedTurn != sim.turn - 1:
      continue
    if intent.other >= 0 and offer.fromSeat != intent.other:
      continue
    found = index
    break
  if found < 0:
    result.reason = oNoSuchOffer
    return
  let offer = sim.offers[found]
  ## The first accept consumes it; a second gets no_such_offer.
  sim.offers.delete(found)
  if sim.cogs[offer.fromSeat].room != sim.cogs[seat].room:
    result.reason = oOfferExpired
    result.other = offer.fromSeat
    return
  result.other = offer.fromSeat
  case offer.kind
  of okTrade:
    if sim.cogs[offer.fromSeat].items[offer.item] < offer.qty or
        sim.cogs[seat].coin < offer.coin or
        CarryLimit - sim.carried(seat) < offer.qty:
      result.reason = oOfferExpired
      return
    sim.cogs[offer.fromSeat].items[offer.item] -= offer.qty
    sim.cogs[seat].items[offer.item] += offer.qty
    sim.cogs[seat].coin -= offer.coin
    sim.cogs[offer.fromSeat].coin += offer.coin
    result.item = offer.item
    result.qty = offer.qty
    result.coin = offer.coin
    result.line = sim.names[seat] & " accepted " & sim.names[offer.fromSeat] &
      "'s offer: " & itemName(offer.item, offer.qty) & " for " &
      $offer.coin & " coin."
  of okHire:
    if sim.cogs[offer.fromSeat].coin < offer.coin:
      result.reason = oOfferExpired
      return
    sim.cogs[offer.fromSeat].coin -= offer.coin
    sim.cogs[seat].coin += offer.coin
    sim.cogs[seat].retainerOf = offer.fromSeat
    sim.cogs[seat].retainerTurns = RetainerTurns
    result.item = -1
    result.qty = 0
    result.coin = offer.coin
    result.line = sim.names[seat] & " took " & sim.names[offer.fromSeat] &
      "'s coin and is hired for " & $RetainerTurns & " turns."

proc resolveTake(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let room = sim.cogs[seat].room
  let present = sim.rooms[room].items[intent.item]
  if present <= 0:
    result.reason = oNoSuchItem
    return
  let free = CarryLimit - sim.carried(seat)
  if free <= 0:
    result.reason = oCarryLimit
    return
  let units = min(min(intent.qty, present), free)
  sim.rooms[room].items[intent.item] -= units
  sim.cogs[seat].items[intent.item] += units
  result.qty = units
  result.line = sim.names[seat] & " picked up " & itemName(intent.item, units) &
    "."

proc resolveDrop(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let held = sim.cogs[seat].items[intent.item]
  if held <= 0:
    result.reason = oNotCarrying
    return
  let units = min(intent.qty, held)
  sim.cogs[seat].items[intent.item] -= units
  sim.rooms[sim.cogs[seat].room].items[intent.item] += units
  result.qty = units
  result.line = sim.names[seat] & " dropped " & itemName(intent.item, units) &
    "."

proc resolveRob(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let other = intent.other
  if other == seat:
    result.reason = oSelfTarget
    return
  if other < 0 or other >= Seats:
    result.reason = oNoSuchCog
    return
  if not sim.cogHere(seat, other):
    result.reason = oNotInRoom
    return
  if not sim.config.thievery:
    result.reason = oThieveryForbidden
    return
  if sim.cogs[seat].retainerOf == other and sim.cogs[seat].retainerTurns > 0:
    result.reason = oBoundByContract
    return
  let room = sim.cogs[seat].room
  let dark = Rooms[room].dark
  ## Strengths are recomputed before each individual robbery, so an earlier
  ## theft in the same turn changes what a later one finds.
  let attack = 1 + sim.retainersPresent(seat, room) + (if dark: 1 else: 0)
  let defence = 1 + sim.retainersPresent(other, room) + (if dark: 0 else: 2)
  result.other = other
  if attack <= defence:
    let fine = min(sim.cogs[seat].coin, FineCoin)
    sim.cogs[seat].coin -= fine
    sim.cogs[other].coin += fine
    result.coin = fine
    result.reason = oRobberyFailed
    result.line = sim.names[seat] & " tried to rob " & sim.names[other] &
      (if dark: " and failed" else: " and the watch stopped him") &
      ", paying " & $fine & " coin."
    return
  let loot = sim.bestLoot(other)
  let free = CarryLimit - sim.carried(seat)
  if loot >= 0 and free > 0:
    dec sim.cogs[other].items[loot]
    inc sim.cogs[seat].items[loot]
    inc sim.cogs[seat].robberies
    inc sim.cogs[other].robbed
    result.item = loot
    result.qty = 1
    result.line = sim.names[seat] & " robbed " & sim.names[other] &
      " in the dark and took " & itemName(loot, 1) & "."
    return
  ## Either the victim carries nothing, or the robber has no hand free for it:
  ## the purse is what changes hands instead.
  let taken = min(sim.cogs[other].coin, RobCoin)
  if taken <= 0:
    result.reason = oNothingToTake
    result.line = sim.names[seat] & " jumped " & sim.names[other] &
      " and found nothing worth taking."
    return
  sim.cogs[other].coin -= taken
  sim.cogs[seat].coin += taken
  inc sim.cogs[seat].robberies
  inc sim.cogs[other].robbed
  result.coin = taken
  result.line = sim.names[seat] & " robbed " & sim.names[other] &
    " in the dark and took " & $taken & " coin."

proc resolveMove(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  let here = sim.cogs[seat].room
  if intent.toRoom < 0 or not Adjacency[here][intent.toRoom]:
    result.reason = oNoSuchExit
    return
  sim.cogs[seat].prevRoom = here
  sim.cogs[seat].room = intent.toRoom
  result.line = sim.names[seat] & " left for " & Rooms[intent.toRoom].name & "."

proc resolveQuest(sim: var Sim, seat: int, intent: Intent): ActResult =
  result = blankResult(intent)
  if intent.npc < 0 or Npcs[intent.npc].room != sim.cogs[seat].room:
    result.reason = oNoNpcHere
    return
  sim.hint[seat] = true
  result.line = sim.names[seat] & " asked " & Npcs[intent.npc].name &
    " about a commission."

# ---- Turn resolution --------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  ## A wall-clock ending is not derivable from the rules, so a replay pre-seeds
  ## the recorded reason before re-deriving (tribunal, 2026-08-23).
  sim.reason = if sim.recordedReason.len > 0: sim.recordedReason else: reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.turn = sim.turnsPlayed
  event.text = sim.reason
  sim.addEvent(event)

proc emitAct(sim: var Sim, seat, order: int, intent: Intent,
    res: ActResult): GameEvent =
  var event = blankEvent(evAct)
  event.turn = sim.turn
  event.seat = seat
  event.order = order
  event.intent = intent.kind
  event.room = intent.room
  event.toRoom = res.toRoom
  event.item = res.item
  event.qty = res.qty
  event.npc = res.npc
  event.other = res.other
  event.coin = res.coin
  event.reason = res.reason
  event.sentence = sim.acts[seat].sentence
  event.say = sim.acts[seat].say
  event.text = sim.notes[seat]
  event.scripted = sim.acts[seat].scripted
  event.salience = 0
  event.salience = salienceOf(event)
  if res.line.len > 0:
    sim.logRoom(intent.room, res.line)
  sim.lastOutcome[seat] = sim.outcomeText(intent, res.reason)
  sim.lastSentence[seat] = sim.acts[seat].sentence
  sim.addEvent(event)
  event

proc resolveTurn(sim: var Sim): seq[Sim] =
  ## All six sentences are in: parse them all against the start-of-turn world,
  ## then resolve class by class, each class in initiative order, appending one
  ## `act` event per seat AS it resolves — so the event log order IS the
  ## resolution order. Returns one snapshot per event this call emits, which is
  ## what `replayMatch` hands the viewer as frames.
  let order = initiativeOrder(sim.turn)
  var intents: array[Seats, Intent]
  for seat in 0 ..< Seats:
    sim.hint[seat] = false
    intents[seat] = parseSentence(sim, seat, sim.acts[seat].sentence)
    intents[seat].room = sim.cogs[seat].room

  var emitted: array[Seats, bool]

  proc act(sim: var Sim, seat, position: int, res: ActResult): Sim =
    emitted[seat] = true
    discard sim.emitAct(seat, position, intents[seat], res)
    sim

  ## 1. Speech. Every seat's `say` field and the text of every iSay is posted
  ##    to the seat's START-OF-TURN room; everyone there reads it next turn.
  for position, seat in order:
    let room = sim.cogs[seat].room
    if sim.acts[seat].say.len > 0:
      sim.logRoom(room, sim.names[seat] & " says: \"" & sim.acts[seat].say &
        "\"")
    if intents[seat].kind == iSay:
      var res = blankResult(intents[seat])
      let spoken = cutRunes(oneLine(intents[seat].spoken), MaxSayLen)
      if spoken.len > 0 and sim.config.speech:
        sim.logRoom(room, sim.names[seat] & " says: \"" & spoken & "\"")
      res.line = ""
      result.add(sim.act(seat, position, res))
    elif intents[seat].spoken.len > 0 and sim.config.speech:
      sim.logRoom(room, sim.names[seat] & " says: \"" &
        cutRunes(oneLine(intents[seat].spoken), MaxSayLen) & "\"")

  ## 2. Shop: stock and shop coin are consumed first-come, so the earlier
  ##    initiative gets the cheap units.
  for position, seat in order:
    if emitted[seat]:
      continue
    let intent = intents[seat]
    var res: ActResult
    case intent.kind
    of iBuy: res = sim.resolveBuy(seat, intent)
    of iSell: res = sim.resolveSell(seat, intent)
    of iQuest: res = sim.resolveQuest(seat, intent)
    of iGive:
      if intent.npc < 0:
        continue
      res = sim.resolveGiveNpc(seat, intent)
    else: continue
    result.add(sim.act(seat, position, res))

  ## 3. Ground: a contested item goes to the earlier initiative.
  for position, seat in order:
    if emitted[seat]:
      continue
    var res: ActResult
    case intents[seat].kind
    of iTake: res = sim.resolveTake(seat, intents[seat])
    of iDrop: res = sim.resolveDrop(seat, intents[seat])
    else: continue
    result.add(sim.act(seat, position, res))

  ## 4. Cog to cog: gifts, offers posted, offers consumed.
  for position, seat in order:
    if emitted[seat]:
      continue
    var res: ActResult
    case intents[seat].kind
    of iGive: res = sim.resolveGiveCog(seat, intents[seat])
    of iTrade: res = sim.resolveTrade(seat, intents[seat])
    of iHire: res = sim.resolveHire(seat, intents[seat])
    of iAccept: res = sim.resolveAccept(seat, intents[seat])
    else: continue
    result.add(sim.act(seat, position, res))

  ## 5. Robbery, against START-OF-TURN positions: you cannot dodge an ambush by
  ##    walking away, because movement is class 6.
  for position, seat in order:
    if emitted[seat] or intents[seat].kind != iRob:
      continue
    let res = sim.resolveRob(seat, intents[seat])
    result.add(sim.act(seat, position, res))

  ## 6. Movement.
  for position, seat in order:
    if emitted[seat] or intents[seat].kind != iMove:
      continue
    let res = sim.resolveMove(seat, intents[seat])
    result.add(sim.act(seat, position, res))

  ## 7. The no-ops: a waited turn and a sentence the town could not read. The
  ##    seat is told the reason in its next observation.
  for position, seat in order:
    if emitted[seat]:
      continue
    var res = blankResult(intents[seat])
    res.reason =
      if intents[seat].kind == iWait: oWaited
      else: intents[seat].reason
    if intents[seat].kind == iWait:
      res.line = sim.names[seat] & " waited and watched."
    result.add(sim.act(seat, position, res))

  ## Book-keeping. Wealth and score are DERIVED from state, never accumulated.
  inc sim.turnsPlayed
  inc sim.turn
  if sim.turnsPlayed < sim.config.turns:
    sim.openTurn()
    result.add(sim)
  else:
    ## One closing snapshot so the viewer's last frame shows the settled town.
    for seat in 0 ..< Seats:
      sim.acts[seat] = PendingAct()
    sim.logTurn()
    result.add(sim)
    sim.settle("complete")
    result.add(sim)

proc applyActionSteps*(sim: var Sim, seat: int, sentence, say, notes: string,
    scripted: bool): seq[Sim] =
  ## `seat` writes its sentence for the open turn. Nothing resolves until all
  ## six are in; the sixth resolves the turn and returns one snapshot per event
  ## it emitted. Raises only for an out-of-range seat, a seat that has already
  ## acted, or an episode that is over — an unreadable sentence NEVER raises,
  ## it is a legal no-op with a recorded reason.
  if sim.done:
    raise newException(CogmudError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(CogmudError, "bad seat: " & $seat)
  if sim.acts[seat].acted:
    raise newException(CogmudError,
      sim.names[seat] & " has already acted this turn")
  var line = cutRunes(oneLine(sentence), MaxSentenceLen)
  var spoken = cutRunes(oneLine(say), MaxSayLen)
  if not sim.config.speech:
    spoken = ""
  sim.acts[seat] = PendingAct(acted: true, sentence: line, say: spoken,
    notes: notes, scripted: scripted)
  if notes.len > 0:
    sim.notes[seat] = cutRunes(oneLine(notes), MaxNotesLen)
  if sim.pendingSeats().len == 0:
    return sim.resolveTurn()

proc applyAction*(sim: var Sim, seat: int, sentence, say, notes: string,
    scripted: bool) =
  discard sim.applyActionSteps(seat, sentence, say, notes, scripted)

proc endEarly*(sim: var Sim) =
  ## Stop now, between turns. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest episode always
  ## beats a long one that never lands. Scores come from the state as it
  ## stands. A no-op when the episode is already over.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var coin = newJArray()
  var wealthNode = newJArray()
  var points = newJArray()
  var delivered = newJArray()
  var robberies = newJArray()
  var robbed = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes by POLICY name, not
    ## by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    coin.add(%sim.cogs[seat].coin)
    wealthNode.add(%sim.wealth(seat))
    points.add(%sim.questPoints(seat))
    delivered.add(%sim.deliveredTotal(seat))
    robberies.add(%sim.cogs[seat].robberies)
    robbed.add(%sim.cogs[seat].robbed)
  %*{
    "names": names,
    "scores": scores,
    "coin": coin,
    "wealth": wealthNode,
    "questPoints": points,
    "delivered": delivered,
    "robberies": robberies,
    "robbed": robbed,
    "turns": sim.turnsPlayed,
    "maxTurns": sim.config.turns,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc chronicleJson(sim: Sim): JsonNode =
  ## This turn's acts so far, for the live spectator feed.
  result = newJArray()
  for event in sim.events:
    if event.kind != evAct or event.turn != sim.turn:
      continue
    result.add(%*{
      "seat": event.seat,
      "sentence": event.sentence,
      "intent": $event.intent,
      "reason": $event.reason,
      "salience": event.salience
    })

proc tableStateJson*(sim: Sim): JsonNode =
  ## The SPECTATOR projection: every room, every purse and every shop's books at
  ## once, because the replay is where the audience sees the whole town. The
  ## players' frames are the separate, redacted playerStateJson.
  var seats = newJArray()
  for seat in 0 ..< Seats:
    var items = newJArray()
    for item in 0 ..< ItemKinds:
      items.add(%sim.cogs[seat].items[item])
    var delivered = newJArray()
    var quests = newJArray()
    for quest in 0 ..< Quests:
      delivered.add(%sim.quests[seat][quest].delivered)
      quests.add(%*{
        "item": sim.quests[seat][quest].item,
        "count": sim.quests[seat][quest].count,
        "delivered": sim.quests[seat][quest].delivered
      })
    seats.add(%*{
      "seat": seat,
      "name": sim.names[seat],
      "room": sim.cogs[seat].room,
      "coin": sim.cogs[seat].coin,
      "items": items,
      "carried": sim.carried(seat),
      "questPoints": sim.questPoints(seat),
      "delivered": delivered,
      "quests": quests,
      "retainerOf": sim.cogs[seat].retainerOf,
      "retainerTurns": sim.cogs[seat].retainerTurns,
      "robberies": sim.cogs[seat].robberies,
      "robbed": sim.cogs[seat].robbed,
      "score": sim.score(seat),
      "pending": (not sim.acts[seat].acted) and not sim.done,
      "scripted": sim.acts[seat].scripted,
      "sentence": sim.acts[seat].sentence,
      "say": sim.acts[seat].say,
      "notes": sim.notes[seat]
    })
  var rooms = newJArray()
  for room in 0 ..< RoomCount:
    var items = newJArray()
    for item in 0 ..< ItemKinds:
      items.add(%sim.rooms[room].items[item])
    var cogs = newJArray()
    for seat in 0 ..< Seats:
      if sim.cogs[seat].room == room:
        cogs.add(%seat)
    var log = newJArray()
    for line in sim.roomLog[room]:
      log.add(%line)
    rooms.add(%*{"id": room, "items": items, "cogs": cogs, "log": log})
  var npcs = newJArray()
  for npc in 0 ..< NpcCount:
    var stock = newJArray()
    var asks = newJArray()
    var bids = newJArray()
    for item in 0 ..< ItemKinds:
      stock.add(%sim.npcs[npc].stock[item])
      asks.add(%(if dealsIn(npc, item): sim.ask(npc, item) else: 0))
      bids.add(%(if dealsIn(npc, item): sim.bid(npc, item) else: 0))
    npcs.add(%*{
      "id": npc, "room": Npcs[npc].room, "coin": sim.npcs[npc].coin,
      "stock": stock, "ask": asks, "bid": bids
    })
  var offers = newJArray()
  for offer in sim.offers:
    offers.add(%*{
      "kind": $offer.kind, "from": offer.fromSeat, "to": offer.toSeat,
      "item": offer.item, "qty": offer.qty, "coin": offer.coin,
      "postedTurn": offer.postedTurn
    })
  var coinInPlay = 0
  var deliveredUnits = 0
  var robberies = 0
  for seat in 0 ..< Seats:
    coinInPlay += sim.cogs[seat].coin
    deliveredUnits += sim.deliveredTotal(seat)
    robberies += sim.cogs[seat].robberies
  var trades = 0
  var wasRobbed: array[Seats, bool]
  for event in sim.events:
    if event.kind != evAct or event.reason != oOk:
      continue
    if event.intent == iAccept or event.intent == iTrade or
        event.intent == iHire:
      inc trades
    ## The scorebug's red ROBBED chip: a victim is marked for the turn the
    ## theft resolved on and the turn after it, which is the "turn after a seat
    ## is victimised" the readouts promise.
    if event.intent == iRob and event.other >= 0 and
        event.turn >= sim.turn - 1:
      wasRobbed[event.other] = true
  var recentRobbed = newJArray()
  for seat in 0 ..< Seats:
    if wasRobbed[seat]:
      recentRobbed.add(%seat)
  %*{
    "world": worldJson(),
    "seats": seats,
    "rooms": rooms,
    "npcs": npcs,
    "offers": offers,
    "chronicle": sim.chronicleJson(),
    "recentRobbed": recentRobbed,
    "town": {
      "coinInPlay": coinInPlay,
      "delivered": deliveredUnits,
      "robberies": robberies,
      "trades": trades
    },
    "turn": sim.turn,
    "turns": sim.config.turns,
    "turnsPlayed": sim.turnsPlayed,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Per-seat observation ---------------------------------------------------

proc cheapestFor*(sim: Sim, item: int): tuple[npc, price: int] =
  ## The shop with the cheapest current ask for `item`; (-1, 0) when nobody
  ## stocks it. This is what an `ask a shopkeeper about my commissions` turn
  ## buys.
  result = (-1, 0)
  for npc in 0 ..< NpcCount:
    if not dealsIn(npc, item) or sim.npcs[npc].stock[item] <= 0:
      continue
    let price = sim.ask(npc, item)
    if result.npc < 0 or price < result.price:
      result = (npc, price)

proc playerStateJson*(sim: Sim, seat: int): JsonNode =
  ## Strictly local: this seat's purse, pack, commission book and room, plus
  ## the public map. NO other seat's coin, pack, commissions, notes or score;
  ## nothing at all happening in another room; no shop's books but the one it
  ## is standing next to.
  let room = sim.cogs[seat].room
  var items = newJArray()
  for item in 0 ..< ItemKinds:
    if sim.cogs[seat].items[item] > 0:
      items.add(%*{"item": Items[item].name,
        "count": sim.cogs[seat].items[item], "value": Items[item].baseValue})
  var quests = newJArray()
  for quest in 0 ..< Quests:
    let q = sim.quests[seat][quest]
    var node = %*{
      "item": Items[q.item].name, "count": q.count, "delivered": q.delivered,
      "points": PointsPerUnit * q.delivered +
        (if q.delivered >= q.count: CompletionBonus else: 0),
      "outstanding": PointsPerUnit * (q.count - q.delivered) +
        (if q.delivered >= q.count: 0 else: CompletionBonus),
      "settledBy": Npcs[GuildNpc].name, "at": Rooms[Npcs[GuildNpc].room].name
    }
    if sim.hint[seat] and q.delivered < q.count:
      let cheap = sim.cheapestFor(q.item)
      if cheap.npc >= 0:
        node["cheapest"] = %*{"npc": Npcs[cheap.npc].name,
          "at": Rooms[Npcs[cheap.npc].room].name, "ask": cheap.price}
    quests.add(node)
  var exits = newJArray()
  for exit in Rooms[room].exits:
    exits.add(%*{"id": exit, "name": Rooms[exit].name})
  var ground = newJArray()
  for item in 0 ..< ItemKinds:
    if sim.rooms[room].items[item] > 0:
      ground.add(%*{"item": Items[item].name,
        "count": sim.rooms[room].items[item]})
  var cogsHere = newJArray()
  for other in 0 ..< Seats:
    if other != seat and sim.cogs[other].room == room:
      cogsHere.add(%sim.names[other])
  var roomNode = %*{
    "id": room, "name": Rooms[room].name, "desc": Rooms[room].desc,
    "dark": Rooms[room].dark, "exits": exits, "ground": ground,
    "cogs": cogsHere
  }
  let npc = npcInRoom(room)
  if npc >= 0:
    var goods = newJArray()
    for item in Npcs[npc].tradeList:
      goods.add(%*{"item": Items[item].name,
        "stock": sim.npcs[npc].stock[item], "ask": sim.ask(npc, item),
        "bid": sim.bid(npc, item)})
    roomNode["npc"] = %*{"name": Npcs[npc].name, "coin": sim.npcs[npc].coin,
      "goods": goods}
  var heard = newJArray()
  for line in sim.heardLog[room]:
    heard.add(%line)
  var offers = newJArray()
  for offer in sim.offers:
    if offer.toSeat != seat or offer.postedTurn != sim.turn - 1:
      continue
    var node = %*{"kind": $offer.kind, "from": sim.names[offer.fromSeat],
      "coin": offer.coin}
    if offer.kind == okTrade:
      node["item"] = %Items[offer.item].name
      node["qty"] = %offer.qty
    offers.add(node)
  var retainers = newJArray()
  for other in 0 ..< Seats:
    if other != seat and sim.cogs[other].retainerOf == seat and
        sim.cogs[other].retainerTurns > 0:
      retainers.add(%*{"name": sim.names[other],
        "turns": sim.cogs[other].retainerTurns})
  var map = newJArray()
  for spec in Rooms:
    var names = newJArray()
    for exit in spec.exits:
      names.add(%Rooms[exit].name)
    var keeper = ""
    let here = npcInRoom(spec.id)
    if here >= 0:
      keeper = Npcs[here].name
    map.add(%*{"name": spec.name, "exits": names, "npc": keeper})
  %*{
    "type": "state",
    "slot": seat,
    "name": sim.names[seat],
    "coin": sim.cogs[seat].coin,
    "items": items,
    "carried": sim.carried(seat),
    "carryLimit": CarryLimit,
    "quests": quests,
    "room": roomNode,
    "heard": heard,
    "offers": offers,
    "standing": {
      "hiredTo": (if sim.cogs[seat].retainerTurns > 0:
        sim.names[sim.cogs[seat].retainerOf] else: ""),
      "hiredToTurns": sim.cogs[seat].retainerTurns,
      "retainers": retainers
    },
    "map": map,
    "lastSentence": sim.lastSentence[seat],
    "lastOutcome": sim.lastOutcome[seat],
    "notes": sim.notes[seat],
    "turn": sim.turn,
    "turns": sim.config.turns,
    "turnsPlayed": sim.turnsPlayed,
    "started": true,
    "done": sim.done,
    "reason": sim.reason
  }

# ---- Replay -----------------------------------------------------------------

proc sameWorld(event: GameEvent, sim: Sim): bool =
  if event.turn != sim.turn or event.rooms.len != RoomCount or
      event.npcs.len != NpcCount or event.cogs.len != Seats:
    return false
  for room in 0 ..< RoomCount:
    if event.rooms[room].items != sim.rooms[room].items:
      return false
  for npc in 0 ..< NpcCount:
    if event.npcs[npc].coin != sim.npcs[npc].coin or
        event.npcs[npc].stock != sim.npcs[npc].stock:
      return false
  for seat in 0 ..< Seats:
    let a = event.cogs[seat]
    let b = sim.cogs[seat]
    if a.room != b.room or a.prevRoom != b.prevRoom or a.coin != b.coin or
        a.items != b.items or
        a.delivered != b.delivered or a.retainerOf != b.retainerOf or
        a.retainerTurns != b.retainerTurns or a.robberies != b.robberies or
        a.robbed != b.robbed:
      return false
  true

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying the
  ## `act` events through the rules; starting rooms, commissions, ground items
  ## and aliases come from the seed. frames[i] = state after events[0..<i].
  ## Raises CogmudError when a recorded `turn` event disagrees with the
  ## re-derivation — that is the tamper check.
  var recordedReason = ""
  for event in events:
    if event.kind == evEnd:
      recordedReason = event.text
  var sim = initSim(config)
  ## initSim already logged the start and the first turn event; the recorded
  ## log opens with those same two.
  sim.events = @[]
  sim.recordedReason = recordedReason
  result.add(sim)

  var queue: seq[Sim]     ## frames a resolution produced but nobody read yet
  var batch: seq[GameEvent]
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
      result.add(sim)
    of evTurn:
      if queue.len > 0:
        let frame = queue[0]
        queue.delete(0)
        if not sameWorld(event, frame):
          raise newException(CogmudError,
            "turn " & $event.turn & " does not match the seeded re-derivation")
        sim = frame
      else:
        if not sameWorld(event, sim):
          raise newException(CogmudError,
            "turn " & $event.turn & " does not match the seeded re-derivation")
        if sim.events.len == 0 or sim.events[^1].kind != evTurn:
          sim.events.add(event)
      result.add(sim)
    of evAct:
      batch.add(event)
      if batch.len < Seats:
        continue
      var steps: seq[Sim]
      for act in batch:
        let produced = sim.applyActionSteps(act.seat, act.sentence, act.say,
          act.text, act.scripted)
        if produced.len > 0:
          steps = produced
      if steps.len < Seats:
        raise newException(CogmudError,
          "turn " & $event.turn & " resolved into " & $steps.len &
            " events, expected at least " & $Seats)
      for index in 0 ..< Seats:
        result.add(steps[index])
      sim = steps[Seats - 1]
      queue = steps[Seats .. ^1]
      batch = @[]
    of evEnd:
      if queue.len > 0:
        sim = queue[0]
        queue.delete(0)
      elif not sim.done:
        sim.settle(event.text)
      result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc roomStateJson(state: RoomState): JsonNode =
  result = newJArray()
  for count in state.items:
    result.add(%count)

proc npcStateJson(state: NpcState): JsonNode =
  var stock = newJArray()
  for count in state.stock:
    stock.add(%count)
  %*{"stock": stock, "coin": state.coin}

proc cogStateJson(state: CogState): JsonNode =
  var items = newJArray()
  for count in state.items:
    items.add(%count)
  var delivered = newJArray()
  for count in state.delivered:
    delivered.add(%count)
  %*{
    "room": state.room, "prevRoom": state.prevRoom, "coin": state.coin,
    "items": items,
    "delivered": delivered, "retainerOf": state.retainerOf,
    "retainerTurns": state.retainerTurns, "robberies": state.robberies,
    "robbed": state.robbed
  }

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.turn >= 0:
    result["turn"] = %event.turn
  case event.kind
  of evStart:
    discard
  of evTurn:
    var rooms = newJArray()
    for room in event.rooms:
      rooms.add(roomStateJson(room))
    var npcs = newJArray()
    for npc in event.npcs:
      npcs.add(npcStateJson(npc))
    var cogs = newJArray()
    for cog in event.cogs:
      cogs.add(cogStateJson(cog))
    result["rooms"] = rooms
    result["npcs"] = npcs
    result["cogs"] = cogs
  of evAct:
    result["seat"] = %event.seat
    result["order"] = %event.order
    result["intent"] = %($event.intent)
    result["room"] = %event.room
    result["reason"] = %($event.reason)
    result["salience"] = %event.salience
    result["scripted"] = %event.scripted
    if event.toRoom >= 0: result["toRoom"] = %event.toRoom
    if event.item >= 0: result["item"] = %event.item
    if event.qty != 0: result["qty"] = %event.qty
    if event.npc >= 0: result["npc"] = %event.npc
    if event.other >= 0: result["other"] = %event.other
    if event.coin != 0: result["coin"] = %event.coin
    if event.sentence.len > 0: result["sentence"] = %event.sentence
    if event.say.len > 0: result["say"] = %event.say
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    turn: node{"turn"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    order: node{"order"}.getInt(-1),
    intent: parseEnum[IntentKind](node{"intent"}.getStr("none"), iNone),
    room: node{"room"}.getInt(-1),
    toRoom: node{"toRoom"}.getInt(-1),
    item: node{"item"}.getInt(-1),
    qty: node{"qty"}.getInt(0),
    npc: node{"npc"}.getInt(-1),
    other: node{"other"}.getInt(-1),
    coin: node{"coin"}.getInt(0),
    reason: parseEnum[Outcome](node{"reason"}.getStr("ok"), oOk),
    salience: node{"salience"}.getInt(0),
    sentence: node{"sentence"}.getStr(""),
    say: node{"say"}.getStr(""),
    text: node{"text"}.getStr(""),
    scripted: node{"scripted"}.getBool(false)
  )
  if node.hasKey("rooms"):
    for room in node["rooms"]:
      var state: RoomState
      for item in 0 ..< min(ItemKinds, room.len):
        state.items[item] = room[item].getInt()
      result.rooms.add(state)
  if node.hasKey("npcs"):
    for npc in node["npcs"]:
      var state = NpcState(coin: npc{"coin"}.getInt())
      let stock = npc{"stock"}
      if not stock.isNil:
        for item in 0 ..< min(ItemKinds, stock.len):
          state.stock[item] = stock[item].getInt()
      result.npcs.add(state)
  if node.hasKey("cogs"):
    for cog in node["cogs"]:
      var state = CogState(
        room: cog{"room"}.getInt(), prevRoom: cog{"prevRoom"}.getInt(-1),
        coin: cog{"coin"}.getInt(),
        retainerOf: cog{"retainerOf"}.getInt(-1),
        retainerTurns: cog{"retainerTurns"}.getInt(0),
        robberies: cog{"robberies"}.getInt(0),
        robbed: cog{"robbed"}.getInt(0))
      let items = cog{"items"}
      if not items.isNil:
        for item in 0 ..< min(ItemKinds, items.len):
          state.items[item] = items[item].getInt()
      let delivered = cog{"delivered"}
      if not delivered.isNil:
        for quest in 0 ..< min(Quests, delivered.len):
          state.delivered[quest] = delivered[quest].getInt()
      result.cogs.add(state)
