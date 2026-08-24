## Claude-backed decision making for Cogmud. Each seat's policy is just a
## prompt: the game server composes the seat's view (its purse and pack, its
## commission book, the room it is standing in with every referent named, what
## happened there last turn, the open offers, the town map) plus that seat's
## prompt, and asks Claude for ONE SENTENCE of plain English.
##
## Decisions inside a turn are simultaneous by rule, so all six requests go out
## as ONE parallel batch (curly.makeRequests); replies that are not a JSON
## object with an `action` are retried once as a smaller batch with a hint, and
## anything still failing falls back to the scripted baseline. A sentence that
## IS well-formed JSON but whose prose the grammar cannot read is NOT a failure
## — it resolves as a legal no-op with a recorded reason the seat is told next
## turn, and retrying it would burn the budget teaching a grammar the next
## observation teaches for free.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits, no rate floor) so
## offline certification still completes — this fallback is load-bearing. The
## same scripted bots are also fieldable policies.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  MaxPromptLen* = 4000

  Phrasebook* = [
    "I walk down to the Docks.",
    "I pick up the coil of rope.",
    "I drop the relic here.",
    "I buy two hides from Tanner Oda.",
    "I sell three nails to Dockmaster Fen.",
    "I hand Guildmaster Vell two hides for my commission.",
    "I offer Gizmo one lamp for twelve coins.",
    "I accept Gizmo's offer.",
    "I hire Bolt for fifteen coins to walk the road with me.",
    "I jump Ratchet here in the dark and take what he is carrying.",
    "I ask Guildmaster Vell about my commissions.",
    "I wait by the well and listen."
  ]

type
  ScriptKind* = enum
    skNone = "none"
    skFactor = "factor"
    skMagpie = "magpie"

  BaselineParams* = object
    ## The five numeric thresholds the two baselines turn on. They are a
    ## parameter object rather than literals in the rules because they were
    ## SEARCHED, not chosen: `tests/test_tuning.nim` is a grid harness that
    ## plays all-scripted episodes over a seed set for every point of the grid
    ## below and re-derives the winner in CI, and `docs/tuning/baseline-grid.md`
    ## is that harness's recorded surface. Change a value here and the harness
    ## reddens unless the new value is the one the sweep picks.
    factorSellMargin*: int    ## sell when a shop's bid >= baseValue + this
    factorPickupValue*: int   ## take loose goods worth at least this
    magpieHawkPeriod*: int    ## hawk the pack every Nth turn
    magpieSellMargin*: int    ## sell when a shop's bid >= baseValue + this
    magpieBuyMargin*: int     ## buy when a shop's ask <= baseValue + this

  Decision* = object
    sentence*: string
    say*: string
    notes*: string      ## "" when the reply carried none

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string         ## direct-Anthropic transport only; Bedrock picks
                          ## from bedrockModels instead
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool
    fellBack*: array[Seats, bool]
      ## Seats whose LLM decision failed twice on the LAST batch and were
      ## played by the scripted baseline instead. The server stamps this onto
      ## the act event's `scripted` flag, so a fallback is visible in the
      ## replay and the results, not only in the stdout log.

const TunedParams* = BaselineParams(
  ## The winning point of the sweep recorded in docs/tuning/baseline-grid.md.
  factorSellMargin: 0,
  factorPickupValue: 8,
  magpieHawkPeriod: 3,
  magpieSellMargin: 1,
  magpieBuyMargin: -1)

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "factor"/"1"/"true"/"yes" play the competent
  ## quest-and-trade baseline, "magpie"/"thief" the thief-peddler.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "factor": skFactor
  of "magpie", "thief": skMagpie
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "cogmud llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins a
  ## single id; without it, fall through this list — model access is a
  ## per-account Marketplace subscription, so an id that works in one account
  ## 403s in another. The config "model" field is NOT consulted here: it
  ## applies to the direct-Anthropic transport only, and the haiku-first
  ## ordering is a shared-capacity decision that trumps per-game preference.
  ## `us.anthropic.claude-sonnet-4-6` is deliberately absent: it times out on
  ## every sidecar call and turns one throttle into a fallback cascade (raid,
  ## 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "cogmud llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    ## Log the model actually invoked, never config.model — the config field is
    ## direct-Anthropic only and printing it here reads as a routing mismatch
    ## (bullwhip family, 2026-08-23).
    echo "cogmud llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel],
      ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "cogmud llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "cogmud llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc npcHere(sim: Sim, seat: int): int =
  npcInRoom(sim.cogs[seat].room)

proc affordableUnits(sim: Sim, seat, npc, item, want: int): int =
  ## How many units the seat could actually pay for, walking the rising ask.
  var coin = sim.cogs[seat].coin
  var stock = sim.npcs[npc].stock[item]
  while result < want and stock > 0:
    let price = askAt(item, stock)
    if coin < price:
      break
    coin -= price
    dec stock
    inc result

proc nearestShopFor(sim: Sim, seat, item: int): int =
  ## The room of the closest shop that has any of `item` in stock; -1 if none.
  result = -1
  var best = high(int)
  let here = sim.cogs[seat].room
  for npc in 0 ..< NpcCount:
    if not dealsIn(npc, item) or sim.npcs[npc].stock[item] <= 0:
      continue
    let distance = Dist[here][Npcs[npc].room]
    if distance >= 0 and distance < best:
      best = distance
      result = Npcs[npc].room

proc factorSentence(sim: Sim, seat: int, params: BaselineParams): string =
  ## The competent baseline and the universal fallback for a failed LLM
  ## decision: a greedy quest-and-trade agent. The first rule that applies
  ## wins, and every quantity is clamped against stock, coin, holdings and
  ## carry slots before the sentence is written, so it is legal by
  ## construction and every noun comes from the sim's own name tables.
  let here = sim.cogs[seat].room
  let npc = npcHere(sim, seat)
  let free = CarryLimit - sim.carried(seat)

  ## 1. Standing with Vell holding units an open commission still needs.
  if npc == GuildNpc:
    for quest in 0 ..< Quests:
      let want = sim.outstanding(seat, quest)
      let item = sim.quests[seat][quest].item
      let units = min(want, sim.cogs[seat].items[item])
      if units > 0:
        return "I hand " & Npcs[GuildNpc].name & " " & itemName(item, units) &
          " for my commission."

  ## 2. A shop here stocks something a commission still needs.
  if npc >= 0:
    for quest in 0 ..< Quests:
      let item = sim.quests[seat][quest].item
      let want = sim.outstanding(seat, quest) - sim.cogs[seat].items[item]
      if want <= 0 or not dealsIn(npc, item) or free <= 0:
        continue
      let units = min(min(want, sim.npcs[npc].stock[item]),
        min(free, affordableUnits(sim, seat, npc, item, want)))
      if units > 0:
        return "I buy " & itemName(item, units) & " from " & Npcs[npc].name & "."

    ## 3. A shop here pays well for something no commission of ours needs.
    for item in 0 ..< ItemKinds:
      let held = sim.cogs[seat].items[item]
      if held <= 0 or sim.needs(seat, item) > 0 or not dealsIn(npc, item):
        continue
      if sim.bid(npc, item) >= Items[item].baseValue + params.factorSellMargin and
          sim.npcs[npc].coin >= sim.bid(npc, item):
        return "I sell " & itemName(item, held) & " to " & Npcs[npc].name & "."

  ## 4. Something worth picking up is lying here.
  if free > 0:
    for item in 0 ..< ItemKinds:
      if sim.rooms[here].items[item] <= 0:
        continue
      if sim.needs(seat, item) > 0 or
          Items[item].baseValue >= params.factorPickupValue:
        return "I pick up the " & Items[item].name & "."

  ## 5. Walk one room along the BFS shortest path toward what we need next.
  var needsMore = false
  var canDeliver = false
  var target = -1
  for quest in 0 ..< Quests:
    let item = sim.quests[seat][quest].item
    let want = sim.outstanding(seat, quest)
    if want <= 0:
      continue
    if sim.cogs[seat].items[item] > 0:
      canDeliver = true
    if sim.cogs[seat].items[item] < want:
      needsMore = true
      if target < 0:
        target = nearestShopFor(sim, seat, item)
  if target < 0:
    target =
      if canDeliver or needsMore: Npcs[GuildNpc].room
      else: 0
  let step = stepToward(here, target)
  if step >= 0:
    return "I walk to " & Rooms[step].name & "."

  ## 6. Nothing applies.
  "I wait and watch the road."

proc magpieSentence(sim: Sim, seat: int, params: BaselineParams): string =
  ## The second filler: a thief-peddler that ignores commissions entirely.
  ## Deliberately worse and differently shaped, so a two-baseline table is not
  ## a mirror match — and its robbery means every offline smoke episode
  ## exercises the theft path, the fine path and the rob FX.
  let here = sim.cogs[seat].room
  let free = CarryLimit - sim.carried(seat)

  ## 1. A dark room, somebody carrying something, and no contract in the way.
  if Rooms[here].dark and sim.config.thievery:
    for other in 0 ..< Seats:
      if other == seat or sim.cogs[other].room != here:
        continue
      if sim.cogs[seat].retainerOf == other and
          sim.cogs[seat].retainerTurns > 0:
        continue
      if sim.carried(other) > 0:
        return "I jump " & sim.names[other] &
          " here in the dark and take what he is carrying."

  ## 2. Every third turn, hawk the cheapest thing in the pack at a markup.
  if sim.turn mod params.magpieHawkPeriod == 0 and sim.carried(seat) > 0:
    for other in 0 ..< Seats:
      if other == seat or sim.cogs[other].room != here:
        continue
      for item in 0 ..< ItemKinds:
        if sim.cogs[seat].items[item] > 0:
          return "I offer " & sim.names[other] & " " & itemName(item, 1) &
            " for " & $(Items[item].baseValue + 2) & " coins."
      break

  let npc = npcHere(sim, seat)
  if npc >= 0:
    ## 3. A shop paying over the odds.
    for item in 0 ..< ItemKinds:
      let held = sim.cogs[seat].items[item]
      if held <= 0 or not dealsIn(npc, item):
        continue
      if sim.bid(npc, item) >= Items[item].baseValue + params.magpieSellMargin and
          sim.npcs[npc].coin >= sim.bid(npc, item):
        return "I sell " & itemName(item, held) & " to " & Npcs[npc].name & "."
    ## 4. A shop selling under the odds.
    for item in 0 ..< ItemKinds:
      if not dealsIn(npc, item) or sim.npcs[npc].stock[item] <= 0 or free <= 0:
        continue
      let price = sim.ask(npc, item)
      if price <= Items[item].baseValue + params.magpieBuyMargin and
          sim.cogs[seat].coin >= price:
        return "I buy " & itemName(item, 1) & " from " & Npcs[npc].name & "."

  ## 5. Ramble. A thief-peddler alternates: empty-handed it walks toward the
  ##    dark (an unlit exit it did not just come from), and with goods in the
  ##    pack it works the lit rooms by the note's plain rule, the lowest-id
  ##    exit that is not the room it came from. The dark preference is what
  ##    makes rule 1 reachable at all — the lowest-id rule alone never leads to
  ##    the Docks or Cutpurse Alley, both high-id, so the baseline that is
  ##    supposed to exercise the robbery path would never rob.
  var step = -1
  if sim.carried(seat) == 0:
    for exit in Rooms[here].exits:
      if Rooms[exit].dark and exit != sim.cogs[seat].prevRoom:
        step = exit
        break
  if step < 0:
    for exit in Rooms[here].exits:
      if exit != sim.cogs[seat].prevRoom:
        step = exit
        break
  if step < 0:
    step = Rooms[here].exits[0]
  "I wander over to " & Rooms[step].name & "."

proc scriptedSentence*(sim: Sim, seat: int, kind: ScriptKind,
    params: BaselineParams = TunedParams): string =
  ## Both baselines emit well-formed English that the SAME parseSentence
  ## reads: the server parses a baseline's sentence exactly as it parses an
  ## LLM's, so the baselines are a live, per-episode test of the parser.
  case kind
  of skMagpie: magpieSentence(sim, seat, params)
  else: factorSentence(sim, seat, params)

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind,
    params: BaselineParams = TunedParams): Decision =
  ## Rule-based baseline for `seat`. Never speaks, never writes notes.
  Decision(sentence: scriptedSentence(sim, seat, kind, params), say: "",
    notes: "")

# ---- Prompt building --------------------------------------------------------

proc systemPrompt*(sim: Sim, seat: int): string =
  "You are " & sim.names[seat] & ", one of six cogs loose in the town of " &
  "Coppermarch. You act by writing ONE SENTENCE of plain English. There is " &
  "no menu of moves: write what you do, and the town works out whether it " &
  "happened." & """

Rules:
- Each turn you do exactly ONE thing. The town understands: going somewhere,
  taking or dropping something lying on the ground, buying from or selling to a
  shopkeeper standing in your room, handing goods to a shopkeeper, offering
  another cog a trade, accepting an offer made to you last turn, hiring another
  cog, robbing another cog, asking a shopkeeper about your commissions,
  speaking, or waiting. Write it however you like; name the thing, the place or
  the cog plainly.
- If the town cannot read your sentence, you lose the turn and are told exactly
  why. Nothing else punishes you for it.
- You may act only on what is in the room you are standing in. You never see
  any other room, and you never see what another cog is carrying or how much
  coin it has.
- Prices move. A shopkeeper charges more for what it is short of and pays about
  two thirds of what it charges. It only buys goods it already deals in, and it
  runs out of coin.
- You hold two COMMISSIONS. Guildmaster Vell at the Guildhall settles every
  commission in this town. Hand Vell the goods a commission names and each unit
  scores; finishing one scores a bonus on top. Part of a commission counts -
  you are never all-or-nothing.
- Robbery works only in the dark: Cutpurse Alley and the Docks. Anywhere else
  the watch stops you and you pay the cog you tried to rob 8 coins. A cog with
  a hireling beside it is hard to rob; a cog with a hireling of its own is good
  at robbing. Success takes the single most valuable thing your victim is
  carrying.
- Hiring is the one promise this town enforces: the coins move the moment the
  offer is accepted, and for three turns the hireling cannot rob you and guards
  you while it stands beside you. What you asked it to actually DO is enforced
  by nothing. Neither is anything anyone says.
- Your SCORE at the end is your coins, plus the fixed value of everything you
  are carrying, plus 3 for every commission point. Nothing else scores you. You
  start on 40 coins and a score of zero.
- Anything you say aloud is heard by every cog in your room, next turn. It need
  not be true.
- Your notes are private to you and fed back to you every turn.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis, no
explanation, no markdown fences, no text before or after the object. Your reply
must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc packLine(sim: Sim, seat: int): string =
  var parts: seq[string]
  for item in 0 ..< ItemKinds:
    if sim.cogs[seat].items[item] > 0:
      parts.add(itemName(item, sim.cogs[seat].items[item]))
  let free = CarryLimit - sim.carried(seat)
  "YOU ARE " & sim.names[seat].toUpperAscii() & ". Purse: " &
    $sim.cogs[seat].coin & " coin. Pack: " &
    (if parts.len > 0: parts.join(", ") else: "empty") &
    " (" & $free & " of " & $CarryLimit & " slots free).\n"

proc commissionLines(sim: Sim, seat: int): string =
  result = "YOUR COMMISSIONS (settled by " & Npcs[GuildNpc].name & " at " &
    Rooms[Npcs[GuildNpc].room].name & "):\n"
  for quest in 0 ..< Quests:
    let q = sim.quests[seat][quest]
    let banked = PointsPerUnit * q.delivered +
      (if q.delivered >= q.count: CompletionBonus else: 0)
    let left = PointsPerUnit * (q.count - q.delivered) +
      (if q.delivered >= q.count: 0 else: CompletionBonus)
    result.add("- " & itemName(q.item, q.count) & " - " &
      (if q.delivered == 0: "none delivered"
       else: $q.delivered & " delivered, " & $(q.count - q.delivered) &
         " to go") &
      ", " & $banked & " points banked, " & $left & " outstanding")
    if sim.hint[seat] and q.delivered < q.count:
      let cheap = sim.cheapestFor(q.item)
      if cheap.npc >= 0:
        result.add(". Cheapest right now: " & Npcs[cheap.npc].name & " at " &
          Rooms[Npcs[cheap.npc].room].name & " asks " & $cheap.price)
    result.add(".\n")

proc roomBlock(sim: Sim, seat: int): string =
  let room = sim.cogs[seat].room
  var exits: seq[string]
  for exit in Rooms[room].exits:
    exits.add(Rooms[exit].name)
  result = "YOU ARE IN: " & Rooms[room].name & ". " & Rooms[room].desc &
    (if Rooms[room].dark: ". It is UNLIT here - robbery can succeed" else: "") &
    ". Exits lead to " & exits.join(" and ") & ".\n"
  var ground: seq[string]
  for item in 0 ..< ItemKinds:
    if sim.rooms[room].items[item] > 0:
      ground.add(itemName(item, sim.rooms[room].items[item]))
  result.add("ON THE GROUND HERE: " &
    (if ground.len > 0: ground.join(", ") else: "nothing") & ".\n")
  var cogs: seq[string]
  for other in 0 ..< Seats:
    if other != seat and sim.cogs[other].room == room:
      cogs.add(sim.names[other])
  result.add("COGS HERE: " &
    (if cogs.len > 0: cogs.join(", ") else: "nobody") & ".\n")
  let npc = npcInRoom(room)
  if npc >= 0:
    result.add("SHOPKEEPER HERE: " & Npcs[npc].name & " (" &
      $sim.npcs[npc].coin & " coin).\n")
    result.add("  goods | in stock | it sells for | it pays\n")
    for item in Npcs[npc].tradeList:
      result.add("  " & Items[item].name & " | " &
        $sim.npcs[npc].stock[item] & " | " & $sim.ask(npc, item) & " | " &
        $sim.bid(npc, item) & "\n")
  else:
    result.add("SHOPKEEPER HERE: none.\n")

proc heardBlock(sim: Sim, seat: int): string =
  let room = sim.cogs[seat].room
  result = "WHAT HAPPENED HERE LAST TURN:\n"
  if sim.heardLog[room].len == 0:
    result.add("(nothing)\n")
    return
  for line in sim.heardLog[room]:
    result.add("- " & line & "\n")

proc offersBlock(sim: Sim, seat: int): string =
  var lines: seq[string]
  for offer in sim.offers:
    if offer.toSeat != seat or offer.postedTurn != sim.turn - 1:
      continue
    if offer.kind == okTrade:
      lines.add(sim.names[offer.fromSeat] & " offers you " &
        itemName(offer.item, offer.qty) & " for " & $offer.coin &
        " coin - it expires at the end of this turn.")
    else:
      lines.add(sim.names[offer.fromSeat] & " offers to hire you for " &
        $offer.coin & " coin - it expires at the end of this turn.")
  if lines.len == 0:
    return ""
  "OPEN OFFERS TO YOU:\n- " & lines.join("\n- ") & "\n"

proc standingBlock(sim: Sim, seat: int): string =
  var lines: seq[string]
  if sim.cogs[seat].retainerTurns > 0:
    lines.add("you are hired to " & sim.names[sim.cogs[seat].retainerOf] &
      " for " & $sim.cogs[seat].retainerTurns & " more turns")
  for other in 0 ..< Seats:
    if other != seat and sim.cogs[other].retainerOf == seat and
        sim.cogs[other].retainerTurns > 0:
      lines.add(sim.names[other] & " is hired to you for " &
        $sim.cogs[other].retainerTurns & " more turns")
  if lines.len == 0:
    return ""
  "YOUR STANDING: " & lines.join("; ") & ".\n"

proc townBlock(): string =
  ## The map is public knowledge in any MUD — but never a shop's stock or
  ## prices, which are strictly local.
  result = "THE TOWN:\n"
  for room in Rooms:
    var exits: seq[string]
    for exit in room.exits:
      exits.add(Rooms[exit].name)
    result.add("- " & room.name & " (roads to " & exits.join(", ") & ")" &
      (if room.dark: " - UNLIT" else: "") & "\n")
  var keepers: seq[string]
  for npc in Npcs:
    keepers.add(npc.name & " at " & Rooms[npc.room].name)
  result.add("Shopkeepers: " & keepers.join("; ") & ".\n")

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  result.add("Turn " & $(sim.turn + 1) & " of " & $sim.config.turns & ".\n")
  result.add(packLine(sim, seat))
  result.add(commissionLines(sim, seat))
  result.add(roomBlock(sim, seat))
  result.add(heardBlock(sim, seat))
  result.add(offersBlock(sim, seat))
  result.add(standingBlock(sim, seat))
  result.add(townBlock())
  if sim.lastSentence[seat].len > 0:
    result.add("YOUR LAST SENTENCE: \"" & sim.lastSentence[seat] & "\" - " &
      sim.lastOutcome[seat] & "\n")
  result.add("\nSENTENCES THE TOWN HAS UNDERSTOOD BEFORE (write your own; " &
    "these are only examples):\n")
  for line in Phrasebook:
    result.add("  " & line & "\n")
  result.add("\nYOUR NOTES FROM EARLIER TURNS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"action\": \"one sentence of plain English\"" &
    (if sim.config.speech: ", \"say\": \"one line spoken aloud, or \\\"\\\"\""
     else: "") &
    ", \"notes\": \"...\"} - action at most " & $MaxSentenceLen &
    " characters" &
    (if sim.config.speech: "; say at most " & $MaxSayLen & " characters"
     else: "") &
    "; notes at most " & $MaxNotesLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(CogmudError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  if error.len > 0:
    raise newException(CogmudError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(CogmudError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(CogmudError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(CogmudError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(CogmudError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(CogmudError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(CogmudError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc cleanText*(text: string, limit: int): string =
  ## Newlines become spaces and text over the cap is cut at a RUNE boundary: a
  ## byte cut through a multi-byte character would put invalid UTF-8 into the
  ## replay and break its strict JSON parse.
  result = text.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "\u2026"

proc parseDecision*(payload: JsonNode): Decision =
  ## "Invalid" means: not a JSON object, or `action` missing, not a string, or
  ## empty after stripping. An unreadable-but-present action is VALID — it is a
  ## legal no-op the town explains back to the seat, never a retry.
  if payload.isNil or payload.kind != JObject:
    raise newException(CogmudError, "reply is not a JSON object")
  let node = payload{"action"}
  if node.isNil or node.kind != JString:
    raise newException(CogmudError, "no action string in response")
  let action = cleanText(node.getStr(), MaxSentenceLen)
  if action.len == 0:
    raise newException(CogmudError, "action is empty")
  result.sentence = action
  result.say = cleanText(payload{"say"}.getStr(), MaxSayLen)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the scripted baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT. All the live seats' requests
  ## go out as ONE parallel batch, because their decisions are simultaneous by
  ## rule — a default episode is 14 batched round trips, not 84.
  result = newSeq[Decision](seats.len)
  for seat in 0 ..< Seats:
    client.fellBack[seat] = false
  var open: seq[int]
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skFactor else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    ## The retry batch gets half the budget, floored at 8 s, so the worst case
    ## for a turn is llmTimeoutSeconds + max(8, llmTimeoutSeconds div 2).
    let budget =
      if attempt == 0: client.timeoutSeconds
      else: max(8, client.timeoutSeconds div 2)
    let responses = client.curl.makeRequests(batch, budget)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        result[index] = parseDecision(extractJsonObject(text))
      except CatchableError as error:
        echo "cogmud llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "cogmud llm: seat ", seat, " falling back to scripted decision"
    client.fellBack[seat] = true
    result[index] = scriptedAction(sim, seat, skFactor)
