## Complete native town episodes with hosted prompts and parsed sentences.

import std/[json, os, osproc, strutils]
import cogmud/[sim, llm]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: cogmud-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
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
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    var rows: seq[string]
    while not game.done:
      var decisions: array[Seats, Decision]
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
        rows.add($(%*{
          "episode_id": "cogmud-" & variant & "-" & $seed,
          "seed": "cogmud-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(game, seat)},
            {"role": "user", "content": userPrompt(game, seat, "")}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "cogmud",
          "action_schema_revision": "cogmud-sentence-v1"
        }))
      for seat in seats:
        let decision = decisions[seat]
        game.applyAction(seat, decision.sentence, decision.say,
          decision.notes, true)
    let results = game.resultsJson()
    doAssert game.turnsPlayed == config.turns
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "turns": game.turnsPlayed,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cogmud", "variant": variant,
    "source_revision": revision, "teacher": "factor-and-magpie",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
