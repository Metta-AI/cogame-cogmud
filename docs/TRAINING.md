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
