## JSONL numeric bridge over the native Cogmud simulator.

import std/[hashes, json, os]
import cogmud/[sim, llm]

var
  game: Sim
  seats: seq[int]
  cursor: int
  decisionId: int
  choices: array[Seats, int]
  manifestPath: string
  variant: string

proc itemIndex(name: string): int =
  for index in 0 ..< ItemKinds:
    if Items[index].name == name: return index
  raise newException(ValueError, "unknown item " & name)

proc currentDecision(): JsonNode =
  let seat = seats[cursor]
  let system = systemPrompt(game, seat)
  let user = userPrompt(game, seat, "")
  %*{"kind": "decision", "game": "cogmud",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.turn,
    "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %(hash(command["seed"].getStr()) and 0x7FFFFFFF)
  var config = defaultGameConfig()
  config.update($variantConfig)
  config = config.sampleEpisode()
  game = initSim(config)
  seats = game.pendingSeats()
  cursor = 0
  decisionId = 0
  choices = [0, 0, 0, 0, 0, 0]
  currentDecision()

proc encode(): JsonNode =
  let seat = seats[cursor]
  let view = game.playerStateJson(seat)
  var values = newJArray()
  for name in ["standard", "honest-town"]:
    values.add(%(if variant == name: 1 else: 0))
  for player in 0 ..< Seats:
    values.add(%(if seat == player: 1 else: 0))
  values.add(%(float(view["turn"].getInt()) / float(view["turns"].getInt())))
  values.add(%(if game.config.speech: 1 else: 0))
  values.add(%(if game.config.thievery: 1 else: 0))
  values.add(%(float(view["coin"].getInt()) / 200.0))
  values.add(%(float(view["carried"].getInt()) / float(CarryLimit)))
  let room = view["room"]
  for index in 0 ..< RoomCount:
    values.add(%(if room["id"].getInt() == index: 1 else: 0))
  var pack: array[ItemKinds, int]
  for entry in view["items"]:
    pack[itemIndex(entry["item"].getStr())] = entry["count"].getInt()
  for count in pack: values.add(%(float(count) / float(CarryLimit)))
  for quest in view["quests"]:
    values.add(%(float(itemIndex(quest["item"].getStr())) /
      float(ItemKinds)))
    values.add(%(float(quest["count"].getInt()) / 5.0))
    values.add(%(float(quest["delivered"].getInt()) / 5.0))
  var ground: array[ItemKinds, int]
  for entry in room["ground"]:
    ground[itemIndex(entry["item"].getStr())] = entry["count"].getInt()
  for count in ground: values.add(%(float(count) / 12.0))
  var ask, bid, stock: array[ItemKinds, int]
  if room.hasKey("npc"):
    for entry in room["npc"]["goods"]:
      let item = itemIndex(entry["item"].getStr())
      ask[item] = entry["ask"].getInt()
      bid[item] = entry["bid"].getInt()
      stock[item] = entry["stock"].getInt()
  for item in 0 ..< ItemKinds:
    values.add(%(float(ask[item]) / 50.0))
    values.add(%(float(bid[item]) / 50.0))
    values.add(%(float(stock[item]) / float(StockCap)))
  var exits: array[RoomCount, bool]
  for entry in room["exits"]:
    exits[entry["id"].getInt()] = true
  for exists in exits: values.add(%(if exists: 1 else: 0))
  values.add(%(float(room["cogs"].len) / float(Seats - 1)))
  values.add(%(if room["dark"].getBool(): 1 else: 0))
  values.add(%(float(view["standing"]["hiredToTurns"].getInt()) /
    float(RetainerTurns)))
  values.add(%(float(view["offers"].len) / float(Seats)))
  doAssert values.len == 71
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 1
  choices[seats[cursor]] = choice
  inc decisionId
  inc cursor
  if cursor == seats.len:
    var decisions: array[Seats, Decision]
    for seat in seats:
      let kind = if choices[seat] == 0: skFactor else: skMagpie
      decisions[seat] = scriptedAction(game, seat, kind)
    for seat in seats:
      let decision = decisions[seat]
      game.applyAction(seat, decision.sentence, decision.say,
        decision.notes, true)
    seats = game.pendingSeats()
    cursor = 0
  let observation = if game.done:
    var scores = newJObject()
    var utilities = newJObject()
    for player in 0 ..< Seats:
      let score = game.score(player)
      scores[$player] = %score
      utilities[$player] = %(score / (abs(score) + 1.0))
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: cogmud-train-bridge MANIFEST VARIANT", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "honest-town"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
