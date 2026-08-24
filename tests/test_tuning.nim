## The grid harness for the two scripted baselines.
##
## Checklist item 7 asks that the baseline's parameters be TUNED WITH A GRID
## HARNESS, NOT GUESSED. This file is that harness, and it runs in CI like any
## other test: it sweeps every point of the grid below, plays a full
## all-scripted episode of the shipped seat mix on eight seeds for each point,
## scores the seats playing the baseline under test, and re-derives the winner.
## `docs/tuning/baseline-grid.md` is the surface it printed, committed so the
## numbers can be read without running anything; this test regenerates it and
## fails if it has drifted.
##
##   objective   the mean score of the seats playing the baseline under test,
##               in the MIXED table (three `factor`, three `magpie` — the seat
##               shape the certification fixture and test_bot use), averaged
##               over the seeds. Score is the game's own
##               (wealth + 3 x questPoints - 40) / 40, derived from the settled
##               town, so the objective is the thing the league ranks on.
##   feasible    the properties each baseline exists to have, checked per seed,
##               because a higher-scoring configuration that stops robbing or
##               stops filling commissions is not the baseline the game ships:
##                 factor   every factor seat fills a commission (>= 2 units
##                          delivered) on every seed, and it never robs, hires
##                          or trades. (That it lands one by turn 12 is
##                          test_bot's assertion, on the all-factor table.)
##                 magpie   at least one successful robbery every seed, at
##                          least one posted offer per episode on average, no
##                          commission ever delivered, a mean below `factor`'s,
##                          and a theft in the 8-turn certification fixture.
##   winner      the highest-scoring feasible point; ties keep the incumbent.
##
## The assertion is not "the shipped point is somewhere on the grid": it is
## that the shipped point is feasible and that NO point of the grid beats it by
## more than one standard error of its own seed mean — i.e. the sweep cannot
## tell any grid point apart from the shipped one, upward. `factor`'s shipped
## point is stronger still: nothing on its grid outscores it at all (two
## neighbours tie it to the last digit, which is why ties keep the incumbent
## rather than churning a parameter the sweep cannot separate).
##
## To reproduce the report by hand:
##   COGMUD_TUNING_WRITE=1 nim r --path:src tests/test_tuning.nim

import std/[math, os, stats, strformat, strutils, unittest]
import cogmud/sim
import cogmud/llm

const
  Seeds = [1, 3, 7, 11, 19, 23, 31, 42]
  Turns = 14
  ReportPath = "docs/tuning/baseline-grid.md"
  ## The grid, centred on the design note's numbers and wide enough on both
  ## sides that the note's value is never the only candidate.
  FactorSellMargins = [-2, -1, 0, 1, 2]
  FactorPickupValues = [6, 7, 8, 9, 11, 14]     ## every item baseValue
  MagpieHawkPeriods = [2, 3, 4, 5]
  MagpieSellMargins = [0, 1, 2, 3]
  MagpieBuyMargins = [-3, -2, -1, 0]

type Table6 = array[Seats, ScriptKind]

## The shipped mixed table, seat for seat as tests/test_bot.nim plays it, and
## the certification fixture's offline mix.
const Mixed: Table6 = [skMagpie, skFactor, skFactor, skMagpie, skFactor,
  skMagpie]
const CertMix: Table6 = [skFactor, skFactor, skFactor, skMagpie, skFactor,
  skFactor]

proc fixtureConfig(seed, turns: int): GameConfig =
  result = defaultGameConfig()
  result.turns = turns
  result.seed = seed
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

type Episode = object
  score: float          ## mean over the seats playing `only`
  delivered: int
  seats: int
  robs: int             ## successful
  offers: int           ## posted trade offers that stuck
  hires: int

proc play(seed: int, kinds: Table6, only: ScriptKind, params: BaselineParams,
    turns = Turns): Episode =
  ## One all-scripted episode: `only`'s seats play `params`, the rest play the
  ## shipped constants, and every sentence goes through the same parser the
  ## server uses.
  var sim = initSim(fixtureConfig(seed, turns))
  while not sim.done:
    for seat in sim.pendingSeats():
      let mine = kinds[seat] == only
      sim.applyAction(seat, scriptedSentence(sim, seat, kinds[seat],
        (if mine: params else: TunedParams)), "", "", true)
  for seat in 0 ..< Seats:
    if kinds[seat] != only:
      continue
    inc result.seats
    result.score += sim.score(seat)
    result.delivered += sim.deliveredTotal(seat)
  result.score = result.score / result.seats.float
  for event in sim.events:
    if event.kind != evAct or event.reason != oOk or kinds[event.seat] != only:
      continue
    case event.intent
    of iRob: inc result.robs
    of iTrade: inc result.offers
    of iHire: inc result.hires
    else: discard

type Point = object
  label: string
  params: BaselineParams
  mean: float
  stderr: float
  feasible: bool
  note: string          ## why it is infeasible, or the counts that matter

proc evalFactor(params: BaselineParams): Point =
  result.params = params
  result.label = &"sell {params.factorSellMargin:>2} · pickup " &
    &"{params.factorPickupValue:>2}"
  var stat: RunningStat
  var fills = 0
  var seats = 0
  var strays = 0
  result.feasible = true
  for seed in Seeds:
    let episode = play(seed, Mixed, skFactor, params)
    stat.push(episode.score)
    seats += episode.seats
    fills += (if episode.delivered >= 2 * episode.seats: episode.seats else: 0)
    strays += episode.robs + episode.hires + episode.offers
    if episode.delivered < 2 * episode.seats:
      result.feasible = false
  if strays > 0:
    result.feasible = false
  result.mean = stat.mean
  result.stderr = stat.standardDeviation / sqrt(Seeds.len.float)
  result.note = &"fills {fills}/{seats}, never robs/hires/trades: " &
    $(strays == 0)

proc evalMagpie(params: BaselineParams, factorMean: float): Point =
  result.params = params
  result.label = &"period {params.magpieHawkPeriod} · sell " &
    &"{params.magpieSellMargin:>2} · buy {params.magpieBuyMargin:>2}"
  var stat: RunningStat
  var robs = 0
  var offers = 0
  var delivered = 0
  result.feasible = true
  for seed in Seeds:
    let episode = play(seed, Mixed, skMagpie, params)
    stat.push(episode.score)
    robs += episode.robs
    offers += episode.offers
    delivered += episode.delivered
    if episode.robs < 1 or episode.delivered != 0:
      result.feasible = false
  let cert = play(11, CertMix, skMagpie, params, turns = 8)
  if cert.robs < 1 or offers < Seeds.len or stat.mean >= factorMean:
    result.feasible = false
  result.mean = stat.mean
  result.stderr = stat.standardDeviation / sqrt(Seeds.len.float)
  result.note = &"robs {robs}, offers {offers}, delivered {delivered}, " &
    &"cert thefts {cert.robs}"

proc bestOf(points: seq[Point], shipped: string): Point =
  ## The highest-scoring feasible point; an exact tie keeps the incumbent, so a
  ## parameter the sweep cannot separate is not churned.
  var best = -1e9
  for point in points:
    if not point.feasible:
      continue
    if point.mean > best or (point.mean == best and point.label == shipped):
      best = point.mean
      result = point

proc factorGrid(): seq[Point] =
  for sell in FactorSellMargins:
    for pickup in FactorPickupValues:
      var params = TunedParams
      params.factorSellMargin = sell
      params.factorPickupValue = pickup
      result.add(evalFactor(params))

proc magpieGrid(factorMean: float): seq[Point] =
  for period in MagpieHawkPeriods:
    for sell in MagpieSellMargins:
      for buy in MagpieBuyMargins:
        var params = TunedParams
        params.magpieHawkPeriod = period
        params.magpieSellMargin = sell
        params.magpieBuyMargin = buy
        result.add(evalMagpie(params, factorMean))

proc row(point: Point, shipped: string): string =
  &"| `{point.label}` | {point.mean.formatFloat(ffDecimal, 4)} | " &
    &"{point.stderr.formatFloat(ffDecimal, 4)} | " &
    (if point.feasible: "yes" else: "**no**") & " | " & point.note & " |" &
    (if point.label == shipped: "   <!-- shipped -->" else: "")

proc find(points: seq[Point], label: string): Point =
  for point in points:
    if point.label == label:
      return point
  raise newException(ValueError, "no grid point labelled " & label)

proc report(factor, magpie: seq[Point], factorShipped, magpieShipped: string,
    factorBest, magpieBest: Point): string =
  result = """<!-- GENERATED by tests/test_tuning.nim. Do not edit by hand:
     COGMUD_TUNING_WRITE=1 nim r --path:src tests/test_tuning.nim -->
# Baseline parameter sweep

The five numeric thresholds in `src/cogmud/llm.nim`'s two scripted baselines
(`BaselineParams`) were searched, not chosen. `tests/test_tuning.nim` plays a
full 14-turn all-scripted episode of the shipped mixed table
(`magpie factor factor magpie factor magpie`) on eight seeds for every point of
the grid, scores the seats playing the baseline under test with the game's own
score, and re-derives the winner. This file is that sweep's output; CI
regenerates it and fails on any drift.

Objective: mean seat score over seeds. `s.e.` is the standard error of that
mean over the eight seeds. A point is *feasible* only if it keeps the
properties the baseline exists to have (see the harness header). Exact ties
keep the incumbent, so a threshold the sweep cannot separate is never churned.

"""
  let factorRegret = factorBest.mean - find(factor, factorShipped).mean
  let magpieRegret = magpieBest.mean - find(magpie, magpieShipped).mean
  result.add(&"""## factor — {factor.len} points

Shipped `{factorShipped}` scores {find(factor, factorShipped).mean.formatFloat(ffDecimal, 4)};
the grid's best feasible point is `{factorBest.label}` at
{factorBest.mean.formatFloat(ffDecimal, 4)}, so the shipped point's regret is
{factorRegret.formatFloat(ffDecimal, 4)} against a standard error of
{find(factor, factorShipped).stderr.formatFloat(ffDecimal, 4)}.

| sellMargin · pickupValue | mean | s.e. | feasible | notes |
|---|---|---|---|---|
""")
  for point in factor:
    result.add(row(point, factorShipped) & "\n")
  result.add(&"""
## magpie — {magpie.len} points

Shipped `{magpieShipped}` scores {find(magpie, magpieShipped).mean.formatFloat(ffDecimal, 4)};
the grid's best feasible point is `{magpieBest.label}` at
{magpieBest.mean.formatFloat(ffDecimal, 4)}, so the shipped point's regret is
{magpieRegret.formatFloat(ffDecimal, 4)} against a standard error of
{find(magpie, magpieShipped).stderr.formatFloat(ffDecimal, 4)}.

| hawkPeriod · sellMargin · buyMargin | mean | s.e. | feasible | notes |
|---|---|---|---|---|
""")
  for point in magpie:
    result.add(row(point, magpieShipped) & "\n")

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

suite "baseline parameter sweep":
  ## One sweep, shared by every check below.
  let shippedFactor = evalFactor(TunedParams)
  let factor = factorGrid()
  let magpie = magpieGrid(shippedFactor.mean)
  let shippedMagpie = evalMagpie(TunedParams, shippedFactor.mean)
  let factorBest = bestOf(factor, shippedFactor.label)
  let magpieBest = bestOf(magpie, shippedMagpie.label)

  test "the shipped point of each baseline is on the grid and feasible":
    checkpoint("factor shipped " & shippedFactor.label & " " &
      shippedFactor.note)
    checkpoint("magpie shipped " & shippedMagpie.label & " " &
      shippedMagpie.note)
    check find(factor, shippedFactor.label).mean == shippedFactor.mean
    check find(magpie, shippedMagpie.label).mean == shippedMagpie.mean
    check shippedFactor.feasible
    check shippedMagpie.feasible

  test "nothing on the factor grid outscores the shipped point":
    checkpoint(&"winner {factorBest.label} " &
      &"{factorBest.mean.formatFloat(ffDecimal, 4)}, shipped " &
      &"{shippedFactor.mean.formatFloat(ffDecimal, 4)}")
    check factorBest.label == shippedFactor.label
    for point in factor:
      if point.feasible:
        check point.mean <= shippedFactor.mean

  test "no grid point beats magpie's shipped point by a standard error":
    ## `magpie` is the deliberately-worse filler, so the sweep is asked only
    ## whether any point is DISTINGUISHABLY better: the regret against the best
    ## feasible point must stay inside one standard error of the seed mean.
    let regret = magpieBest.mean - shippedMagpie.mean
    checkpoint(&"winner {magpieBest.label} " &
      &"{magpieBest.mean.formatFloat(ffDecimal, 4)}, shipped " &
      &"{shippedMagpie.mean.formatFloat(ffDecimal, 4)}, regret " &
      &"{regret.formatFloat(ffDecimal, 4)}, s.e. " &
      &"{shippedMagpie.stderr.formatFloat(ffDecimal, 4)}")
    check regret >= 0.0
    check regret <= shippedMagpie.stderr

  test "the committed sweep report is the one this harness just produced":
    let text = report(factor, magpie, shippedFactor.label,
      shippedMagpie.label, factorBest, magpieBest)
    let path = repoRoot() / ReportPath
    if getEnv("COGMUD_TUNING_WRITE").len > 0:
      createDir(path.parentDir())
      writeFile(path, text)
      checkpoint("wrote " & path)
    check fileExists(path)
    ## Byte-equal, so the committed surface can never drift from the code.
    check readFile(path) == text
