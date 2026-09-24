# Cogmud training

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

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/cogmud-data --output /tmp/cogmud-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

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
