## Export complete engine-resolved episodes as private candidate evidence.
import std/[json, options, os, osproc, strutils]
import bitworld/decision_trajectory
import cogmud/[sim, llm, prompts]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: cogmud-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let selection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  doAssert episodes >= 10
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  var
    runs = newJArray()
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  try:
    for seed in 1 .. episodes:
      variantConfig["seed"] = %seed
      var config = defaultGameConfig()
      config.update($variantConfig)
      config = sampleEpisode(config)
      var game = initSim(config)
      let family = "cogmud-" & $seed
      let episodeId = family & "-" & variant & "-" &
        $selection.selectedVariant & "-" & $selection.seed
      let trajectory = newDecisionTrajectory(episodeId, family, "cogmud",
        "source-" & revision, revision)
      var decisionId = 0
      while not game.done:
        let snapshot = game
        let seats = game.pendingSeats()
        var decisions: array[Seats, Decision]
        var kinds: array[Seats, ScriptKind]
        for seat in seats:
          kinds[seat] = if (seed + game.turn + seat) mod 2 == 0: skFactor else: skMagpie
          decisions[seat] = parseDecision(scriptedAction(snapshot, seat, kinds[seat]).decisionReply())
          doAssert parseSentence(snapshot, seat, decisions[seat].sentence).kind != iNone
        let firstEvent = game.events.len
        for seat in seats:
          let decision = decisions[seat]
          game.applyAction(seat, decision.sentence, decision.say, decision.notes, true)
        var recorded = 0
        for eventIndex in firstEvent ..< game.events.len:
          let event = game.events[eventIndex]
          if event.kind != evAct:
            continue
          let seat = event.seat
          let reply = decisions[seat].decisionReply()
          let executed = executedReply(event)
          let system = systemPrompt(snapshot, seat, selection)
          let user = userPrompt(snapshot, seat, "")
          var observation = snapshot.playerStateJson(seat)
          observation["prompt_template"] = selection.promptMetadata(system, user)
          var attempt = newDecisionAttempt($decisionId & "-teacher",
            "scripted-" & $kinds[seat], aoTeacher)
          attempt.prompt = %*[{"role": "system", "content": system},
            {"role": "user", "content": user}]
          attempt.parsedAction = reply
          attempt.response = %($reply)
          attempt.accepted = event.reason in {oOk, oWaited} and reply == executed
          let rejection = if event.reason notin {oOk, oWaited}: "town-" & $event.reason
            else: "engine-normalized-submission"
          if not attempt.accepted:
            attempt.rejectionReason = some(rejection)
          trajectory.recordDecision($decisionId, $seat, observation, @[attempt],
            if attempt.accepted: some(attempt.attemptId) else: none(string),
            executed, if attempt.accepted: asAccepted else: asFallback,
            game.done and recorded == seats.high,
            if attempt.accepted: none(string) else: some(rejection))
          inc recorded
          inc decisionId
        doAssert recorded == seats.len
      doAssert game.reason == "complete" and game.turnsPlayed == config.turns
      let results = game.resultsJson()
      var participants = newJObject()
      for seat in 0 ..< config.players.len:
        participants[$seat] = %*{"score": results["scores"][seat]}
      trajectory.finish(esCompleted, results, participants)
      stream.write(trajectory.eventsJsonl())
      runs.add(%*{"seed": seed, "turns": game.turnsPlayed, "reason": game.reason,
        "decisions": decisionId, "scores": results["scores"]})
  finally:
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cogmud", "variant": variant,
    "source_revision": revision, "teacher": "factor-and-magpie",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs}) & "\n")
  echo "complete games=", episodes
