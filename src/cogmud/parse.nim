## The bounded intent grammar: one sentence of plain English in, one `Intent`
## out. Pure — a function of the sentence and the sim only — so the server, the
## tests and the wasm replay viewer all read a recorded sentence identically and
## a replay's parses are reproducible.
##
## The parser decides only WHAT WAS MEANT. Legality against the world (the exit
## exists, the item is present, the coin is sufficient) belongs to the
## resolution step in `sim.nim`, which is where the outcome reason is recorded.
##
## Three deliberate additions to the design note's verb table, each needed by a
## paraphrase the note's own test list requires and each documented in
## `sentences.md`:
##   * `off` joins the movement verbs under the same room-slot guard as `slip`
##     ("Off to the harbour with me.");
##   * `have` / `has` join the giving verbs under a target-slot guard
##     ("Vell can have these hides.");
##   * a sentence with no verb at all that names both a shopkeeper and a good is
##     read as a purchase ("Two hides, tanner, and be quick."). Every other
##     verbless sentence is still `no_verb`.

import std/[strutils, unicode], types

export types

const
  QtyAll* = 999
    ## "all" / "every": the resolvers clamp it against stock, holdings and
    ## carry slots, so it is always the maximum legal quantity.

const
  NumberWords = [
    ("a", 1), ("an", 1), ("one", 1), ("two", 2), ("three", 3), ("four", 4),
    ("five", 5), ("six", 6), ("seven", 7), ("eight", 8), ("nine", 9),
    ("ten", 10), ("eleven", 11), ("twelve", 12),
    # The design note's own phrasebook says "hire Bolt for FIFTEEN coins", so
    # the number words run past twelve; coin amounts reach further than
    # quantities ever do.
    ("thirteen", 13), ("fourteen", 14), ("fifteen", 15), ("sixteen", 16),
    ("seventeen", 17), ("eighteen", 18), ("nineteen", 19), ("twenty", 20),
    ("thirty", 30), ("forty", 40), ("fifty", 50), ("hundred", 100),
    ("both", 2), ("couple", 2), ("dozen", 12)
  ]
  CoinWords = ["coin", "coins", "gp", "silver", "piece", "pieces", "crown",
    "crowns"]
  SelfWords = ["myself", "me", "self", "himself", "herself", "itself",
    "yourself"]
  OfferWords = ["offer", "offers", "deal", "bargain", "terms", "proposal"]

type
  Slot = object
    id: int          ## -1 when nothing matched
    span: int        ## tokens the winning phrase covered; 0 when none
    ambiguous: bool
    pos: int         ## first token index of the match, -1 when none

  Phrase = object
    id: int
    words: seq[string]

  VerbGuard = enum
    vgAlways
    vgRoomSlot        ## only a verb when a room is named
    vgItemNoRoom      ## "leave the rope" is a drop; "leave for the docks" a move
    vgCogSlot
    vgNoCogSlot
    vgNpcSlot
    vgNoNpcSlot
    vgTargetSlot      ## a cog or an NPC
    vgOfferWord
    vgNoOfferWord
    vgFollowedByIn    ## turn IN / turn OVER
    vgFollowedByFor   ## make FOR
    vgFollowedByDown  ## set DOWN
    vgFollowedByNothing
    vgFollowedByPocket
    vgFollowedByPurse

  VerbEntry = object
    token: string
    kind: IntentKind
    guard: VerbGuard

const Verbs: seq[VerbEntry] = @[
  # --- movement ---
  VerbEntry(token: "go", kind: iMove, guard: vgAlways),
  VerbEntry(token: "goes", kind: iMove, guard: vgAlways),
  VerbEntry(token: "going", kind: iMove, guard: vgAlways),
  VerbEntry(token: "walk", kind: iMove, guard: vgAlways),
  VerbEntry(token: "walks", kind: iMove, guard: vgAlways),
  VerbEntry(token: "head", kind: iMove, guard: vgAlways),
  VerbEntry(token: "heads", kind: iMove, guard: vgAlways),
  VerbEntry(token: "move", kind: iMove, guard: vgAlways),
  VerbEntry(token: "travel", kind: iMove, guard: vgAlways),
  VerbEntry(token: "run", kind: iMove, guard: vgAlways),
  VerbEntry(token: "ride", kind: iMove, guard: vgAlways),
  VerbEntry(token: "enter", kind: iMove, guard: vgAlways),
  VerbEntry(token: "cross", kind: iMove, guard: vgAlways),
  VerbEntry(token: "return", kind: iMove, guard: vgAlways),
  VerbEntry(token: "wander", kind: iMove, guard: vgAlways),
  VerbEntry(token: "slip", kind: iMove, guard: vgRoomSlot),
  VerbEntry(token: "off", kind: iMove, guard: vgRoomSlot),
  VerbEntry(token: "make", kind: iMove, guard: vgFollowedByFor),
  # `leave` is a move unless an item is named and no room is
  VerbEntry(token: "leave", kind: iDrop, guard: vgItemNoRoom),
  VerbEntry(token: "leave", kind: iMove, guard: vgAlways),
  # --- taking and dropping ---
  VerbEntry(token: "take", kind: iAccept, guard: vgOfferWord),
  VerbEntry(token: "takes", kind: iAccept, guard: vgOfferWord),
  VerbEntry(token: "take", kind: iTake, guard: vgAlways),
  VerbEntry(token: "takes", kind: iTake, guard: vgAlways),
  VerbEntry(token: "pick", kind: iRob, guard: vgFollowedByPocket),
  VerbEntry(token: "pick", kind: iTake, guard: vgAlways),
  VerbEntry(token: "picks", kind: iTake, guard: vgAlways),
  VerbEntry(token: "grab", kind: iTake, guard: vgAlways),
  VerbEntry(token: "lift", kind: iRob, guard: vgCogSlot),
  VerbEntry(token: "lift", kind: iTake, guard: vgAlways),
  VerbEntry(token: "collect", kind: iTake, guard: vgAlways),
  VerbEntry(token: "scoop", kind: iTake, guard: vgAlways),
  VerbEntry(token: "pocket", kind: iTake, guard: vgAlways),
  VerbEntry(token: "drop", kind: iDrop, guard: vgAlways),
  VerbEntry(token: "drops", kind: iDrop, guard: vgAlways),
  VerbEntry(token: "put", kind: iDrop, guard: vgAlways),
  VerbEntry(token: "discard", kind: iDrop, guard: vgAlways),
  VerbEntry(token: "set", kind: iDrop, guard: vgFollowedByDown),
  # --- shop ---
  VerbEntry(token: "buy", kind: iBuy, guard: vgAlways),
  VerbEntry(token: "buys", kind: iBuy, guard: vgAlways),
  VerbEntry(token: "purchase", kind: iBuy, guard: vgAlways),
  VerbEntry(token: "acquire", kind: iBuy, guard: vgAlways),
  VerbEntry(token: "pay", kind: iGive, guard: vgCogSlot),
  VerbEntry(token: "pay", kind: iBuy, guard: vgAlways),
  VerbEntry(token: "sell", kind: iSell, guard: vgAlways),
  VerbEntry(token: "sells", kind: iSell, guard: vgAlways),
  VerbEntry(token: "offload", kind: iSell, guard: vgAlways),
  VerbEntry(token: "unload", kind: iSell, guard: vgAlways),
  VerbEntry(token: "flog", kind: iSell, guard: vgAlways),
  # --- giving ---
  VerbEntry(token: "give", kind: iGive, guard: vgAlways),
  VerbEntry(token: "gives", kind: iGive, guard: vgAlways),
  VerbEntry(token: "hand", kind: iGive, guard: vgAlways),
  VerbEntry(token: "hands", kind: iGive, guard: vgAlways),
  VerbEntry(token: "deliver", kind: iGive, guard: vgAlways),
  VerbEntry(token: "delivers", kind: iGive, guard: vgAlways),
  VerbEntry(token: "present", kind: iGive, guard: vgAlways),
  VerbEntry(token: "donate", kind: iGive, guard: vgAlways),
  VerbEntry(token: "turn", kind: iGive, guard: vgFollowedByIn),
  VerbEntry(token: "have", kind: iGive, guard: vgTargetSlot),
  VerbEntry(token: "has", kind: iGive, guard: vgTargetSlot),
  # --- offers ---
  VerbEntry(token: "offer", kind: iTrade, guard: vgAlways),
  VerbEntry(token: "offers", kind: iTrade, guard: vgAlways),
  VerbEntry(token: "propose", kind: iTrade, guard: vgAlways),
  VerbEntry(token: "trade", kind: iTrade, guard: vgAlways),
  VerbEntry(token: "swap", kind: iTrade, guard: vgAlways),
  VerbEntry(token: "barter", kind: iTrade, guard: vgAlways),
  VerbEntry(token: "accept", kind: iAccept, guard: vgAlways),
  VerbEntry(token: "accepts", kind: iAccept, guard: vgAlways),
  VerbEntry(token: "agree", kind: iAccept, guard: vgAlways),
  VerbEntry(token: "deal", kind: iAccept, guard: vgAlways),
  VerbEntry(token: "shake", kind: iAccept, guard: vgAlways),
  # --- hiring ---
  VerbEntry(token: "hire", kind: iHire, guard: vgAlways),
  VerbEntry(token: "hires", kind: iHire, guard: vgAlways),
  VerbEntry(token: "employ", kind: iHire, guard: vgAlways),
  VerbEntry(token: "retain", kind: iHire, guard: vgAlways),
  VerbEntry(token: "engage", kind: iHire, guard: vgAlways),
  # --- robbery ---
  VerbEntry(token: "rob", kind: iRob, guard: vgAlways),
  VerbEntry(token: "robs", kind: iRob, guard: vgAlways),
  VerbEntry(token: "steal", kind: iRob, guard: vgAlways),
  VerbEntry(token: "stealing", kind: iRob, guard: vgAlways),
  VerbEntry(token: "mug", kind: iRob, guard: vgAlways),
  VerbEntry(token: "jump", kind: iRob, guard: vgAlways),
  VerbEntry(token: "ambush", kind: iRob, guard: vgAlways),
  VerbEntry(token: "waylay", kind: iRob, guard: vgAlways),
  VerbEntry(token: "cut", kind: iRob, guard: vgFollowedByPurse),
  # --- speech and asking ---
  VerbEntry(token: "ask", kind: iQuest, guard: vgNpcSlot),
  VerbEntry(token: "ask", kind: iSay, guard: vgAlways),
  VerbEntry(token: "asks", kind: iQuest, guard: vgNpcSlot),
  VerbEntry(token: "asks", kind: iSay, guard: vgAlways),
  VerbEntry(token: "say", kind: iSay, guard: vgAlways),
  VerbEntry(token: "says", kind: iSay, guard: vgAlways),
  VerbEntry(token: "tell", kind: iSay, guard: vgAlways),
  VerbEntry(token: "tells", kind: iSay, guard: vgAlways),
  VerbEntry(token: "shout", kind: iSay, guard: vgAlways),
  VerbEntry(token: "call", kind: iSay, guard: vgAlways),
  VerbEntry(token: "announce", kind: iSay, guard: vgAlways),
  VerbEntry(token: "whisper", kind: iSay, guard: vgAlways),
  VerbEntry(token: "enquire", kind: iQuest, guard: vgAlways),
  VerbEntry(token: "inquire", kind: iQuest, guard: vgAlways),
  VerbEntry(token: "check", kind: iQuest, guard: vgAlways),
  VerbEntry(token: "consult", kind: iQuest, guard: vgAlways),
  VerbEntry(token: "read", kind: iQuest, guard: vgAlways),
  # --- waiting ---
  VerbEntry(token: "wait", kind: iWait, guard: vgAlways),
  VerbEntry(token: "waits", kind: iWait, guard: vgAlways),
  VerbEntry(token: "rest", kind: iWait, guard: vgAlways),
  VerbEntry(token: "linger", kind: iWait, guard: vgAlways),
  VerbEntry(token: "idle", kind: iWait, guard: vgAlways),
  VerbEntry(token: "listen", kind: iWait, guard: vgAlways),
  VerbEntry(token: "watch", kind: iWait, guard: vgAlways),
  VerbEntry(token: "stay", kind: iWait, guard: vgAlways),
  VerbEntry(token: "look", kind: iWait, guard: vgAlways),
  VerbEntry(token: "do", kind: iWait, guard: vgFollowedByNothing)
]

# ---- Normalisation ----------------------------------------------------------

proc liftSpeech*(sentence: string): tuple[rest, spoken: string] =
  ## Text inside the FIRST pair of straight or curly double quotes is removed
  ## from the parse string and broadcast into the room. An unterminated quote
  ## lifts nothing and the whole string is parsed.
  var text = sentence.replace("\u201C", "\"").replace("\u201D", "\"")
    .replace("\u201E", "\"").replace("\u00AB", "\"").replace("\u00BB", "\"")
  let open = text.find('"')
  if open < 0:
    return (text, "")
  let close = text.find('"', open + 1)
  if close < 0:
    return (text, "")
  result.spoken = text[open + 1 ..< close].strip()
  result.rest = text[0 ..< open] & " " & text[close + 1 .. ^1]

proc normalise*(text: string): string =
  ## Lowercase (rune-aware), then keep only letters, digits, quotes and spaces,
  ## collapsing runs of whitespace.
  var kept = newStringOfCap(text.len)
  for rune in toLower(text).runes:
    if rune.isAlpha() or (rune.int32 >= '0'.int32 and rune.int32 <= '9'.int32):
      kept.add($rune)
    elif rune.int32 == '\''.int32 or rune.int32 == 0x2019:
      kept.add('\'')
    else:
      kept.add(' ')
  strutils.splitWhitespace(kept).join(" ")

proc tokenise*(text: string): seq[string] =
  ## Normalised words with possessives reduced to their stem: `gizmo's` reads
  ## as `gizmo`.
  for raw in strutils.splitWhitespace(normalise(text)):
    var word = raw
    if word.endsWith("'s"):
      word = word[0 ..< word.len - 2]
    word = word.strip(chars = {'\''})
    if word.len > 0:
      result.add(word)

# ---- Slot matching ----------------------------------------------------------

proc phrasesOf(id: int, names: openArray[string]): seq[Phrase] =
  for name in names:
    let words = tokenise(name)
    if words.len > 0:
      result.add(Phrase(id: id, words: words))

proc matchAt(tokens: seq[string], start: int, words: seq[string]): bool =
  if start + words.len > tokens.len:
    return false
  for offset, word in words:
    if tokens[start + offset] != word:
      return false
  true

proc bestSlot(tokens: seq[string], phrases: seq[Phrase]): Slot =
  ## Longest-phrase-wins, measured in TOKENS: "the copper kettle" beats
  ## "copper", and two one-token matches on different targets are ambiguous.
  result = Slot(id: -1, span: 0, ambiguous: false, pos: -1)
  for start in 0 ..< tokens.len:
    for phrase in phrases:
      if not matchAt(tokens, start, phrase.words):
        continue
      if phrase.words.len > result.span:
        result.id = phrase.id
        result.span = phrase.words.len
        result.pos = start
        result.ambiguous = false
      elif phrase.words.len == result.span and phrase.id != result.id:
        result.ambiguous = true

proc roomPhrases(): seq[Phrase] =
  for room in Rooms:
    result.add(phrasesOf(room.id, room.keywords))
    result.add(phrasesOf(room.id, [room.name]))

proc itemPhrases(): seq[Phrase] =
  for item in Items:
    result.add(phrasesOf(item.id, item.keywords))

proc npcPhrases(): seq[Phrase] =
  for npc in Npcs:
    result.add(phrasesOf(npc.id, npc.keywords))
    result.add(phrasesOf(npc.id, [npc.name]))

let
  RoomPhrases = roomPhrases()
  ItemPhrases = itemPhrases()
  NpcPhrases = npcPhrases()

proc cogPhrases(sim: Sim): seq[Phrase] =
  ## Every seat alias, INCLUDING the speaker's own, so that "I rob Sprocket"
  ## from Sprocket is reported as `self_target` rather than silently losing
  ## its target.
  for other in 0 ..< sim.names.len:
    result.add(phrasesOf(other, [sim.names[other]]))

proc selfPhrases(seat: int): seq[Phrase] =
  ## The reflexive words resolve to the speaker, but only when no alias
  ## matched: "hire Bolt ... with me" names Bolt, not a two-way ambiguity.
  for word in SelfWords:
    result.add(Phrase(id: seat, words: @[word]))

proc numberOf(token: string): int =
  ## The token's numeric value, or -1.
  if token.len > 0 and token.allCharsInSet({'0' .. '9'}):
    try:
      return parseInt(token)
    except ValueError:
      return -1
  for pair in NumberWords:
    if pair[0] == token:
      return pair[1]
  if token == "all" or token == "every" or token == "everything":
    return QtyAll
  -1

proc findQty(tokens: seq[string], limit: int): int =
  ## The first integer or number word before `limit` (the item slot's position,
  ## or the end of the sentence). Default 1.
  let stop = if limit < 0: tokens.len else: min(limit, tokens.len)
  for index in 0 ..< stop:
    let value = numberOf(tokens[index])
    if value >= 0:
      return value
  1

proc findCoin(tokens: seq[string]): int =
  ## An integer adjacent to a coin word, or the integer following `for`.
  for index, token in tokens:
    let value = numberOf(token)
    if value < 0 or value == QtyAll:
      continue
    let after = if index + 1 < tokens.len: tokens[index + 1] else: ""
    let before = if index > 0: tokens[index - 1] else: ""
    if after in CoinWords or before in CoinWords:
      return value
  for index, token in tokens:
    if token != "for" or index + 1 >= tokens.len:
      continue
    let value = numberOf(tokens[index + 1])
    if value >= 0 and value != QtyAll:
      return value
  0

# ---- The parser -------------------------------------------------------------

proc liveOffersTo(sim: Sim, seat: int): seq[int] =
  ## Indexes into sim.offers of the offers this seat may accept this turn.
  for index, offer in sim.offers:
    if offer.toSeat == seat and offer.postedTurn == sim.turn - 1:
      result.add(index)

proc npcInRoom*(room: int): int =
  for npc in Npcs:
    if npc.room == room:
      return npc.id
  -1

proc parseSentence*(sim: Sim, seat: int, sentence: string): Intent =
  ## One sentence in, one Intent out. Never raises.
  result = Intent(kind: iNone, room: sim.cogs[seat].room, toRoom: -1,
    item: -1, qty: 1, npc: -1, other: -1, coin: 0, reason: oUnparsed,
    spoken: "")
  let lifted = liftSpeech(sentence)
  result.spoken = lifted.spoken
  let tokens = tokenise(lifted.rest)
  if tokens.len == 0:
    result.reason = (if result.spoken.len > 0: oNoVerb else: oUnparsed)
    if result.spoken.len > 0:
      result.kind = iSay
      result.reason = oOk
    return

  let cogs = cogPhrases(sim)
  let selves = selfPhrases(seat)
  let wholeRoom = bestSlot(tokens, RoomPhrases)
  let wholeItem = bestSlot(tokens, ItemPhrases)
  let wholeNpc = bestSlot(tokens, NpcPhrases)
  var wholeCog = bestSlot(tokens, cogs)
  if wholeCog.id < 0:
    wholeCog = bestSlot(tokens, selves)
  var hasOfferWord = false
  for token in tokens:
    if token in OfferWords:
      hasOfferWord = true

  proc guardHolds(entry: VerbEntry, at: int): bool =
    ## `next` is the token right after the verb; `near` looks a little further
    ## for a particle ("turn the hides IN"), and `later` anywhere after it
    ## ("pick Gizmo's POCKET", "cut Widget's PURSE").
    proc near(words: openArray[string]): bool =
      for offset in 1 .. 3:
        if at + offset < tokens.len and tokens[at + offset] in words:
          return true
      false
    proc later(words: openArray[string]): bool =
      for index in at + 1 ..< tokens.len:
        if tokens[index] in words:
          return true
      false
    let next = if at + 1 < tokens.len: tokens[at + 1] else: ""
    case entry.guard
    of vgAlways: true
    of vgRoomSlot: wholeRoom.id >= 0
    of vgItemNoRoom: wholeItem.id >= 0 and wholeRoom.id < 0
    of vgCogSlot: wholeCog.id >= 0 and wholeCog.id != seat
    of vgNoCogSlot: wholeCog.id < 0
    of vgNpcSlot: wholeNpc.id >= 0
    of vgNoNpcSlot: wholeNpc.id < 0
    of vgTargetSlot: wholeNpc.id >= 0 or wholeCog.id >= 0
    of vgOfferWord: hasOfferWord
    of vgNoOfferWord: not hasOfferWord
    of vgFollowedByIn: near(["in", "over"])
    of vgFollowedByFor: next == "for"
    of vgFollowedByDown: near(["down"])
    of vgFollowedByNothing: near(["nothing"])
    of vgFollowedByPocket: later(["pocket", "pockets"])
    of vgFollowedByPurse: later(["purse", "purses"])

  ## The FIRST token in the verb table decides the intent; two verbs in one
  ## sentence and the first wins.
  var kind = iNone
  var verbAt = -1
  block scan:
    for index, token in tokens:
      for entry in Verbs:
        if entry.token == token and guardHolds(entry, index):
          kind = entry.kind
          verbAt = index
          break scan

  if kind == iNone:
    ## A verbless sentence naming both a shopkeeper and a good is a purchase;
    ## anything else the town simply cannot read.
    if wholeNpc.id >= 0 and wholeItem.id >= 0:
      kind = iBuy
      verbAt = -1
    else:
      result.reason = oNoVerb
      return

  ## Slots are filled from the tokens AFTER the verb, falling back to the whole
  ## sentence when nothing matched there.
  var tail: seq[string]
  if verbAt >= 0 and verbAt + 1 < tokens.len:
    tail = tokens[verbAt + 1 .. ^1]
  elif verbAt < 0:
    tail = tokens
  let tailOffset = if verbAt >= 0: verbAt + 1 else: 0

  template pick(tailSlot, wholeSlot: Slot): Slot =
    (if tailSlot.id >= 0: tailSlot else: wholeSlot)

  let roomSlot = pick(bestSlot(tail, RoomPhrases), wholeRoom)
  let itemSlot = pick(bestSlot(tail, ItemPhrases), wholeItem)
  let npcSlot = pick(bestSlot(tail, NpcPhrases), wholeNpc)
  var cogSlot = pick(bestSlot(tail, cogs), wholeCog)
  if cogSlot.id < 0:
    cogSlot = pick(bestSlot(tail, selves), wholeCog)

  result.kind = kind
  result.reason = oOk
  result.item = itemSlot.id
  result.npc = npcSlot.id
  result.other = cogSlot.id
  result.toRoom = roomSlot.id

  ## Quantity: the first number before the item slot. Coin: a number adjacent
  ## to a coin word, or the number following "for".
  let itemPos =
    if itemSlot.pos >= 0 and itemSlot.id == bestSlot(tail, ItemPhrases).id and
        tail.len > 0: itemSlot.pos + tailOffset
    elif wholeItem.pos >= 0: wholeItem.pos
    else: -1
  result.qty = findQty(tokens, itemPos)
  result.coin = findCoin(tokens)

  template fail(why: Outcome) =
    result.kind = iNone
    result.reason = why
    return

  case kind
  of iMove:
    if roomSlot.ambiguous: fail(oAmbiguousTarget)
    if roomSlot.id < 0: fail(oNoTarget)
  of iTake, iDrop:
    if itemSlot.ambiguous: fail(oAmbiguousTarget)
    if itemSlot.id < 0: fail(oNoTarget)
  of iBuy, iSell:
    if itemSlot.ambiguous: fail(oAmbiguousTarget)
    if itemSlot.id < 0: fail(oNoTarget)
    if npcSlot.ambiguous: fail(oAmbiguousTarget)
    if result.npc < 0:
      ## No shopkeeper named: default to the one keeping shop in this room.
      result.npc = npcInRoom(sim.cogs[seat].room)
    if result.npc < 0: fail(oNoTarget)
  of iGive:
    if itemSlot.ambiguous: fail(oAmbiguousTarget)
    if npcSlot.ambiguous or cogSlot.ambiguous: fail(oAmbiguousTarget)
    if result.other == seat:
      result.other = -1
    if result.npc < 0 and result.other < 0: fail(oNoTarget)
    if result.item < 0 and result.coin <= 0: fail(oNoTarget)
  of iTrade, iHire:
    if cogSlot.ambiguous: fail(oAmbiguousTarget)
    if result.other < 0: fail(oNoSuchCog)
    if result.other == seat: fail(oSelfTarget)
    if kind == iTrade and result.item < 0: fail(oNoTarget)
    if kind == iHire and result.coin <= 0:
      ## "I hire Bolt" with no fee named is a one-coin retainer offer, the
      ## smallest legal one, rather than an unreadable sentence.
      result.coin = 1
  of iRob:
    if cogSlot.ambiguous: fail(oAmbiguousTarget)
    if result.other < 0: fail(oNoSuchCog)
    if result.other == seat: fail(oSelfTarget)
  of iAccept:
    if cogSlot.ambiguous: fail(oAmbiguousTarget)
    if result.other == seat:
      result.other = -1
    if result.other < 0:
      let live = liveOffersTo(sim, seat)
      if live.len == 1:
        result.other = sim.offers[live[0]].fromSeat
      else:
        fail(oNoSuchOffer)
  of iQuest:
    if npcSlot.ambiguous: fail(oAmbiguousTarget)
    if result.npc < 0:
      result.npc = npcInRoom(sim.cogs[seat].room)
    if result.npc < 0: fail(oNoNpcHere)
  of iSay:
    if result.spoken.len == 0:
      result.spoken = sentence.strip()
  of iWait, iNone:
    discard
