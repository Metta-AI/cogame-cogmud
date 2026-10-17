# Cogmud training

The exporter plays complete fourteen-turn town episodes with six seats. Both
published variants, `standard` and `honest-town`, use the shipped factor and
magpie teachers. Every seat proposes against one frozen turn state; the engine
then resolves all actions in class and initiative order.

```sh
nim c -d:release --path:src -o:/tmp/cogmud-posttrain tools/export_posttrain.nim
/tmp/cogmud-posttrain /tmp/cogmud-data 10 standard plain 0
```

The exporter requires clean committed source and a new output directory.
`trajectories.jsonl` contains private completed-episode events; `manifest.json`
records the source revision, wordings, seeds, turns, scores, and decision counts.
Output is written one episode at a time. Each decision retains the original
sentence proposal and the engine's resolved submission. Unsuccessful actions
and normalized submissions remain unselected evidence, not accepted teacher targets.
The game still treats unreadable sentences as legal no-ops without a model retry.

Convert private events through `coworld.decision_trajectory.read_trajectory_jsonl`
and `export_complete_episodes`. Conversion does not authorize training.
`metta_training.posttrain.hosted.export_hosted` requires external review bound to
the complete-episode SHA256 and source revision. Explicitly select the
`scripted-factor` and `scripted-magpie` policies. The family `cogmud-SEED` keeps
both game variants and every wording together when splitting data.

## Rule wording

`promptVariant` selects `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` selects one of these using an explicit nonnegative
`promptSeed`, independently of game randomness. Selection stays fixed for all
seats, turns, and retries. `heldout-briefing` and `heldout-reference` are reserved
for evaluation; training resets and candidate exports reject them.

Only the role and sentence-action introduction varies. Common rules, parser,
private observations, scoring, fourteen-turn horizon, twelve-second native batch
spacing, and published budgets remain unchanged. Canonical text matches the
original numeric bridge.

```sh
/tmp/cogmud-train-bridge coworld_manifest_template.json standard --language
python3 tools/test_prompt_variants.py /tmp/cogmud-train-bridge
```

The language bridge accepts production JSON replies containing `action`, `say`,
and `notes`. Acceptance means a parsed proposal was queued. All six proposals
resolve after the final seat submits; earlier observations remain frozen.
Use engine-resolved private episodes for authoritative training targets.
Private `semantic_view.prompt_template` contains the bank, wording, selection
seed, and exact system/user hashes. Model messages omit these metadata fields.

## Private native evidence

Set `COGAME_SAVE_TRAJECTORY_URI` to a private artifact destination, together with
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`.
Capture preserves actual request bodies, messages, responses, retries, proposed
sentences, and resolved submissions. Authorization headers are excluded.
Failed requests retain their rejection reason and consumed fallback. Explicit
scripted policies are teachers. Deadline episodes are truncated. Private events
are written before public results announce completion.

```sh
python3 tools/test_prompt_native_games.py GAME PLAYER OUTPUT SOURCE_REVISION
```

The panel launches six real players per game. A closed local endpoint exercises
actual failed requests and fallbacks; scripted cases exercise engine outcomes.
Checks compare private observations, request hashes, complete replays, and scores
under ordinary pacing and budgets. These checks do not establish model robustness
or learning improvement. The game-owned transport provides no authenticated
serving receipts or token probabilities for on-policy qualification.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes hosted prompts and 71 numeric values
derived from the game's redacted `playerStateJson`. They cover the acting
seat's coin, pack, commissions, local room, visible shop, and exits. They
exclude other seats' purses, packs, commissions, and remote rooms. Two
choices select the published factor and magpie policies. Scores use
`score / (abs(score) + 1)` for bounded (-1, 1) utilities. Post-training
above retains arbitrary legal English actions and speech.

```sh
nim c -d:release --path:src -o:/tmp/cogmud-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/cogmud-posttrain /tmp/cogmud-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=6` and choose `standard` or `honest-town`.

## Historical local training proof

The earlier row exporter produced ten complete episodes per variant and 672 train and 168 validation
prompt/action decisions. A one-step Metta post-training optimizer run with
a 4,096-token context reduced validation loss from 1.75452 to 1.74919
(standard) and 1.74913 (honest-town). All rows fit the context.

Metta RL ran 512 timesteps per variant through the numeric bridge.
Native PufferLib trained 4,096 CUDA timesteps per variant. Reloaded
checkpoints evaluated on held-out seeds 101 and 102 (four games per seed):

| Variant | Seed 101 score / performance | Seed 102 score / performance | Checkpoint SHA-256 |
| --- | --- | --- | --- |
| standard | 1.55625 / 0.755339 | 1.91875 / 0.827607 | `2945bfbe05eb034748e50c0677d01ca6bf08eb67d15cbb971fc4df062c1d6e23` |
| honest-town | 1.55625 / 0.755339 | 1.91875 / 0.827607 | `02a53cbf165c3e1df9a66311e87e51e85de5c56623c1256cff97070d6fd9dd02` |
