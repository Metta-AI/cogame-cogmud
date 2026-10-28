# Cogmud training

## Authentic hosted model traces

The ordinary game server can write a private JSONL decision artifact when
`COGAME_SAVE_TRAJECTORY_URI` is set. Capture preserves the six-seat parallel
requests, native retry/fallback behavior, 12-second batch floor, and all fourteen
turns. Each request retains the exact prompt, decoder settings, received response,
platform call ID, and available usage/identity fields. Missing usage is unknown.

All six private observations are frozen before any submission. After the sixth
submission resolves the town, each actual act event is joined by seat to its
original observation and attempts, in the engine's class/initiative order.
Only unchanged model replies can be selected; optional omitted say/notes fields
use their native empty defaults for equality only. Parser or engine normalization
excludes selection without changing the stored response. Scripted and offline
fallbacks cannot become model teaching targets. Authenticate platform receipts
with the maintained research collector before training.

An unrecognized sentence is a legal no-op, not a failed JSON request: it is
recorded once with the native outcome and is not retried or mislabeled as a
parser rejection. Likewise a failed purchase is a resolved legal submission.
Outcome and teacher-quality filtering are separate from request acceptance;
receipt admission alone does not establish a useful strategy or learning.

To exercise the complete production server/player path, compile the ordinary
game and player, then run:

```sh
python3 tools/test_native_capture.py bin/cogmud bin/cogmud-player /path/to/retained-evidence
```

The destination must be new. This retains six complete standard/honest-town
games with capture on/off replay and outcome parity, resolution-order joins,
retries, fallback, normalization, privacy, legal no-ops, missing usage, and
credential-free fallback. The provider is synthetic system-test evidence;
real-model receipt admission and Qwen learning require separate measurements.
Scenario families group the actual seeded world across variants and wording.


The exporter plays ten complete native town episodes per certified
variant. It records each seat's exact hosted system and user prompts,
plus English sentences accepted by the production parser. Every seat
chooses against the same pre-turn state, then the native simulator
resolves all six actions. Train and validation sets split full episodes
by seed.

```sh
nim c -d:release --path:src -o:/tmp/cogmud-posttrain tools/export_posttrain.nim
/tmp/cogmud-posttrain /tmp/cogmud-data 10 standard
```

The other certified variant is `honest-town`. The output has
`train.jsonl`, `validation.jsonl`, and a manifest with source revision,
seeds, turns, scores, and row counts. Ten episodes yielded 672/168
train/validation decisions for each variant.

Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for current training and adapter-packaging workflows.


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

## Local training proof

Ten complete episodes per variant exported 672 train and 168 validation
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

## Prompt fuzzing

The v2 bank varies the role, sentence-based actions, visibility, communication and
memory briefings. Trade, hiring, robbery, commissions, scoring and JSON requirements
remain exact. Select `canonical`, `plain`, `numbered`, `questions`, or `reordered`
with `promptVariant`. `mixed` requires a nonnegative `promptSeed` and selects by
seed modulo five without consuming game randomness. One wording lasts a whole game.

Language bridge resets accept these fields with `--language`. Held-out briefing
and reference variants require an evaluation split; teacher export rejects them.
Exact private message hashes remain on bridge decisions.

Append `PROMPT_VARIANT PROMPT_SEED` to export arguments. Mixed export advances the
prompt seed separately within each split, recording each selection. This keeps
all five wordings available in training despite every-fifth-seed validation. Episode IDs distinguish wordings;
scenario-family IDs exclude wording and game variant. Keep families in one split.
Export from committed source. Original train/validation JSONL files remain the
dataset interface. Only successful, unchanged engine-resolved actions become teacher
examples; failed and normalized proposals are excluded and counted in the manifest.
The earlier row totals describe exports before this admission filter.

`tools/test_prompt_variants.py BRIDGE` plays 16 complete games across both variants,
seven direct wordings and one mixed selection. Existing export/numeric checks
cover 20 mixed games and verify admission counts and family separation. Scripted
invariance is not evidence of improved learned-policy robustness.

Episode IDs include requested selection, resolved wording, and prompt seed, so
matched explicit and mixed collections remain distinct. Scenario families stay unchanged.
