# Cogmud

Six cogs loose in a town, and every move is a sentence.

Six LLM-piloted cogs share the nine-room town of Coppermarch for fourteen
turns. **There is no action menu anywhere in the stack**: a seat's whole output
is one sentence of plain English, which the server parses with a bounded intent
grammar into exactly one of thirteen intents — go, take, drop, buy, sell, hand
over, offer, accept, hire, rob, ask, speak, wait. Five shopkeepers hold stock
whose prices move with it, Guildmaster Vell posts two private commissions per
seat that pay partial credit per unit delivered, robbery works only in the two
unlit rooms and only against a cog without a bodyguard, and hiring is the one
promise the rules actually enforce. Score is wealth plus commission points at
the horizon. Everything else — alliances, price-fixing, protection rackets,
honest freight — is emergent, and is the point.

**A policy is just a prompt.** Field one by reusing the published
`cogmud-player` runnable with `PLAYER_PROMPT` set to your strategy:

```bash
coworld upload-policy coworld-cogmud:latest --name my-cogmud \
  --run /bin/cogmud-player \
  --secret-env PLAYER_PROMPT="Work the commissions first: they are worth far
    more than the spread..."
```

Full rules, the parser and the scoring live in the coworld's own docs pages
(`rules.md`, `sentences.md`, `scoring.md` in
`coworld_manifest_template.json`).

## Layout

| path | what it is |
|---|---|
| `src/cogmud/world.nim` | the authored constant town: nine rooms, six goods, five shopkeepers, the BFS distance matrix, and the `worldJson()` the viewer draws |
| `src/cogmud/types.nim` | the config, the state records, the intent and outcome enums, the event record and the `Sim` object |
| `src/cogmud/parse.nim` | the bounded intent grammar — a pure function of the sentence and the sim, run identically by the server, the tests and the wasm viewer |
| `src/cogmud/sim.nim` | the pure rules: setup from the seed, the price curve, the class-then-initiative resolution, scoring, the JSON projections and `replayMatch` |
| `src/cogmud/llm.nim` | prompts, the one-parallel-batch-per-turn Claude client, the reply parser, and the two scripted baselines |
| `src/cogmud/server.nim` | the Coworld game contract: HTTP routes, the player/global/replay websockets, the game loop, the deadline and the artifacts |
| `src/cogmud.nim` | the game entrypoint (`/bin/cogmud`) |
| `src/cogmud_player.nim` | the player entrypoint (`/bin/cogmud-player`) — delivers a prompt and spectates |
| `client/` | the broadcast chrome, inherited from `Metta-AI/cogame-bullwhip`: `chrome.css` byte-for-byte plus one appended block, the three pages plus one appended game block each, and `renderer.js` |
| `replay-viewer/` | the static wasm replay viewer — the same sim compiled to WebAssembly, re-deriving every frame in the browser |
| `data/` | board art: six seat sprites and the parchment floor |
| `scripts/art/` | the nano-banana source render and the script that tints it into the six sprites |
| `scripts/manifest/` | the docs prose and the script that assembles `coworld_manifest_template.json` from it |
| `tests/` | sim, parser, baselines, scoring, the feasibility oracle and the viewer's chrome provenance |
| `tools/` | the replay-viewer build hook and the CI smokes |

## Board art

The six seat sprites are one **nano-banana** render of the Softmax cog —
redrawn as a market-town trader with a leather satchel and a travelling cloak,
on deliberately neutral grey plating — keyed, cropped and tinted into six seat
colours. Cogmud's seats are symmetric (there are no roles), so one cog kit in
six tints is the whole cast, and the tint is what a spectator reads at board
scale. The source render is committed at
`scripts/art/source/cog_sheet.png` and the split/tint script at
`scripts/art/make_cog_colors.py`:

```bash
python3 scripts/art/make_cog_colors.py     # rewrites data/soldier_*_front.png
```

## Building

The repo builds with [nimby](https://github.com/treeform/nimby) and Nim 2.2.4.
The committed `nim.cfg` is gitignored because it pins the author's machine's
package paths; regenerate it per machine exactly as the Dockerfile and CI do:

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
rm -f nim.cfg
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim c -d:release --out:cogmud src/cogmud.nim
nim c -d:release --out:cogmud-player src/cogmud_player.nim
```

## Tests

Every file runs twice in CI, debug and `-d:release`:

```bash
for t in tests/*.nim; do nim r --path:src "$t"; done
```

| file | what it holds the line on |
|---|---|
| `tests/test_sim.nim` | world integrity, the seeded setup, determinism, the initiative rotation, the price curve by hand, restock, partial credit, contention, robbery in all four cases, the retainer, rune-safe truncation, the wasm integer width, the observation split, replay re-derivation and its tamper check, and the two endings |
| `tests/test_parse.nim` | a table of sentences to expected intents and slots covering every verb synonym, the whole phrasebook, verb precedence, speech lifting, the failure vocabulary and robustness against junk |
| `tests/test_bot.nim` | the baselines are legal and bounded by construction, emit **zero** unreadable sentences across a full episode, and the no-credentials client decides scripted with no network wait |
| `tests/test_score.nim` | the scoring formula, its sign, the worked landmark, and what the league ranks by |
| `tests/test_feasibility.nim` | the greedy commission plan fits inside `turns - 2` and the starting purse over 200 seeds × 6 seats |
| `tests/test_viewer.nim` | chrome provenance (byte-for-byte against the starter), the element inventory, the scope-collision guard, and that the emscripten link flags and the JS bootstrap are a matched pair |

## The replay viewer

Replays are a **static file plus a browser wasm viewer**, never a pod. The
manifest declares `"replay_viewer": {"bundle": "static-replay-viewer"}` and
`tools/build_replay_viewer.sh` compiles the same `sim` module to WebAssembly
with emscripten and bundles it with the chrome and the assets. Everything the
viewer needs — the aliases, the policy names, the seed, the whole room/item/NPC
table and the complete event log — lives in the replay bytes, so nothing is
contacted but S3 for the `.replay` file itself.

```bash
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90 --soak 15
```

## Licence

MIT, see `LICENSE`.
