## Complete native town episodes with hosted prompts and parsed sentences.

import std/[json, os, osproc, strutils]
import cogmud/[sim, llm, prompts]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: cogmud-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let initialSelection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  if initialSelection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  doAssert execProcess("git status --porcelain").strip().len == 0, "commit source before export"
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
    wordingCounts: array[2, int]
  for seed in 1 .. episodes:
    var selection = initialSelection
    let partition = ord(seed mod 5 == 0)
    if selection.variant == pvMixed:
      selection.seed += wordingCounts[partition]
    inc wordingCounts[partition]
    let episode = "cogmud-" & variant & "-" & $seed & "-" &
      $selection.variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    var rows: seq[string]
    var decisionId, rejected = 0
    while not game.done:
      var decisions: array[Seats, Decision]
      var proposals: array[Seats, string]
      let seats = game.pendingSeats()
      for seat in seats:
        let kind = if (seed + game.turn + seat) mod 2 == 0:
          skFactor else: skMagpie
        let decision = scriptedAction(game, seat, kind)
        let completion = %*{"action": decision.sentence,
          "say": decision.say, "notes": decision.notes}
        let accepted = parseDecision(completion)
        doAssert accepted.sentence == decision.sentence
        doAssert parseSentence(game, seat, accepted.sentence).kind != iNone
        decisions[seat] = accepted
        proposals[seat] = $(%*{
          "episode_id": episode,
          "seed": "cogmud-" & $seed,
          "decision_id": decisionId,
          "prompt": [
            {"role": "system", "content": systemPrompt(game, seat, selection)},
            {"role": "user", "content": userPrompt(game, seat, "")}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "cogmud",
          "action_schema_revision": "cogmud-sentence-v1"
        })
        inc decisionId
      let firstEvent = game.events.len
      for seat in seats:
        let decision = decisions[seat]
        game.applyAction(seat, decision.sentence, decision.say,
          decision.notes, true)
      var recorded = 0
      for eventIndex in firstEvent ..< game.events.len:
        let event = game.events[eventIndex]
        if event.kind != evAct: continue
        if event.reason in {oOk, oWaited} and
            executedReply(event) == decisions[event.seat].decisionReply():
          rows.add(proposals[event.seat])
        else:
          inc rejected
        inc recorded
      doAssert recorded == seats.len
    let results = game.resultsJson()
    doAssert game.turnsPlayed == config.turns
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "episode": episode, "turns": game.turnsPlayed,
      "prompt_selection": selection.selectionMetadata(),
      "rejected_proposals": rejected,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "prompt_selection": initialSelection.selectionMetadata(), "game": "cogmud", "variant": variant,
    "source_revision": revision, "teacher": "factor-and-magpie",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
