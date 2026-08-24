import std/[json, strutils], world

export world

const
  Seats* = 6
  Quests* = 2

type
  CogmudError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    turns*: int           ## turns of sentences in the episode
    speech*: bool         ## seats may speak a line into their room
    thievery*: bool       ## robbery can succeed at all (honest-town: false)
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int
    shutdownGraceSeconds*: int

  RoomState* = object
    ## What lies loose on one room's floor.
    items*: array[ItemKinds, int]

  NpcState* = object
    stock*: array[ItemKinds, int]
    coin*: int

  CogState* = object
    room*: int
    prevRoom*: int        ## the room it walked in from, -1 before its first
                          ## move; the `magpie` baseline's ramble needs it and
                          ## it keeps the ramble a pure function of the state
    coin*: int
    items*: array[ItemKinds, int]
    delivered*: array[Quests, int] ## mirrors quests[seat][q].delivered, so a
                                   ## recorded `turn` event carries commission
                                   ## progress for the tamper check
    retainerOf*: int      ## the seat this cog is hired to, or -1
    retainerTurns*: int
    robberies*: int       ## successful thefts committed
    robbed*: int          ## times victimised

  Quest* = object
    item*: int
    count*: int
    delivered*: int

  OfferKind* = enum
    okTrade = "trade"
    okHire = "hire"

  Offer* = object
    kind*: OfferKind
    fromSeat*: int
    toSeat*: int
    item*: int
    qty*: int
    coin*: int
    postedTurn*: int

  IntentKind* = enum
    iNone = "none"
    iMove = "move"
    iTake = "take"
    iDrop = "drop"
    iBuy = "buy"
    iSell = "sell"
    iGive = "give"
    iTrade = "trade"
    iAccept = "accept"
    iHire = "hire"
    iRob = "rob"
    iSay = "say"
    iQuest = "quest"
    iWait = "wait"

  Outcome* = enum
    ## The complete outcome vocabulary. Every value is legal and every value
    ## is produced by at least one case in tests/test_sim.nim or test_parse.nim.
    oOk = "ok"
    oWaited = "waited"
    oUnparsed = "unparsed"
    oNoVerb = "no_verb"
    oNoTarget = "no_target"
    oAmbiguousTarget = "ambiguous_target"
    oNoSuchExit = "no_such_exit"
    oNoSuchItem = "no_such_item"
    oNotCarrying = "not_carrying"
    oCarryLimit = "carry_limit"
    oNoNpcHere = "no_npc_here"
    oNotWanted = "not_wanted"
    oOutOfStock = "out_of_stock"
    oCannotAfford = "cannot_afford"
    oNpcBroke = "npc_broke"
    oNoMatchingCommission = "no_matching_commission"
    oNoSuchCog = "no_such_cog"
    oNotInRoom = "not_in_room"
    oSelfTarget = "self_target"
    oNoSuchOffer = "no_such_offer"
    oOfferExpired = "offer_expired"
    oBoundByContract = "bound_by_contract"
    oRobberyFailed = "robbery_failed"
    oNothingToTake = "nothing_to_take"
    oThieveryForbidden = "thievery_forbidden"
    oRejected = "rejected"

  Intent* = object
    kind*: IntentKind
    room*: int            ## the seat's room when the sentence was written
    toRoom*: int          ## move destination
    item*: int
    qty*: int
    npc*: int
    other*: int           ## the other cog's seat
    coin*: int
    reason*: Outcome
    spoken*: string       ## text lifted out of quotes in the sentence

  EventKind* = enum
    evStart = "start"
    evTurn = "turn"
    evAct = "act"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    turn*: int            ## turn/act: the open turn; end: turns played; start: -1
    seat*: int            ## act: the acting seat; -1 otherwise
    order*: int           ## act: initiative 0..5; -1 otherwise
    intent*: IntentKind   ## act
    room*: int            ## act: where it resolved; -1 otherwise
    toRoom*: int
    item*: int
    qty*: int
    npc*: int
    other*: int
    coin*: int
    reason*: Outcome      ## act: the outcome
    salience*: int        ## act: 0..100, drives the highlight reel
    sentence*: string     ## act: the seat's verbatim sentence (<= 240 runes)
    say*: string          ## act: the spoken line (<= 160 runes)
    text*: string         ## act: the seat's notes; end: the reason string
    scripted*: bool       ## act: decided by a scripted baseline
    rooms*: seq[RoomState]  ## turn: the nine room floors
    npcs*: seq[NpcState]    ## turn: the five shops
    cogs*: seq[CogState]    ## turn: the six cogs

  Phase* = enum
    phTurn = "turn"     ## the open turn is waiting for its six sentences
    phDone = "done"

  PendingAct* = object
    ## One seat's reply, buffered until all six have landed. Decisions inside a
    ## turn are simultaneous by rule, so nothing resolves until the sixth
    ## sentence is in.
    acted*: bool
    sentence*: string
    say*: string
    notes*: string
    scripted*: bool

  Sim* = object
    ## One whole episode. The object lives here rather than in `sim.nim` so the
    ## pure parser (`parse.nim`) can read a seat's room, the table aliases and
    ## the live offers without an import cycle; `sim.nim` re-exports it, so
    ## `sim.Sim` is the name everything else uses.
    config*: GameConfig
    names*: seq[string]                       ## anonymous cog aliases per seat
    rooms*: array[RoomCount, RoomState]
    npcs*: array[NpcCount, NpcState]
    cogs*: array[Seats, CogState]
    quests*: array[Seats, array[Quests, Quest]]
    offers*: seq[Offer]                       ## live offers, oldest first
    roomLog*: array[RoomCount, seq[string]]   ## this turn's public lines
    heardLog*: array[RoomCount, seq[string]]  ## last turn's, read by seats
    lastOutcome*: array[Seats, string]        ## the reason its last sentence got
    lastSentence*: array[Seats, string]       ## quoted back in the observation
    hint*: array[Seats, bool]                 ## an iQuest bought a price hint
    notes*: seq[string]                       ## latest private notes per seat
    acts*: array[Seats, PendingAct]
    turn*, turnsPlayed*: int
    phase*: Phase
    done*: bool
    reason*: string                           ## "complete" | "deadline"
    recordedReason*: string                   ## replay only; see replayMatch
    events*: seq[GameEvent]

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    turns: 14,
    speech: true,
    thievery: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 400,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 24,
    shutdownGraceSeconds: 20
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(CogmudError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("turns"):
    config.turns = node["turns"].getInt()
  if node.hasKey("speech"):
    config.speech = node["speech"].getBool()
  if node.hasKey("thievery"):
    config.thievery = node["thievery"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if node.hasKey("shutdownGraceSeconds"):
    config.shutdownGraceSeconds = node["shutdownGraceSeconds"].getInt()
  if config.turns < 6:
    raise newException(CogmudError, "turns must be at least 6")
  if config.players.len > 0 and config.players.len != 6:
    raise newException(CogmudError, "cogmud needs exactly 6 players")
