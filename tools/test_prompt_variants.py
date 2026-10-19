"""Complete six-seat town games preserve local observations and sentence resolution."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

BINARY = str(Path(sys.argv[1]).resolve())
MANIFEST = str(Path(__file__).resolve().parents[1] / "coworld_manifest_template.json")
TRAIN = ["canonical", "plain", "numbered", "questions", "reordered"]
DIRECT = TRAIN + ["heldout-briefing", "heldout-reference"]


def request(process, command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


for game, maximum in (("standard", 84), ("honest-town", 84)):
    with subprocess.Popen(
        [BINARY, MANIFEST, game, "--language"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        for seed in ("17",):
            canonical = None
            direct = []
            for choice, prompt_seed in [(v, 0) for v in DIRECT] + [("mixed", 4)]:
                obs = request(
                    process,
                    {
                        "kind": "reset",
                        "seed": seed,
                        "players": 6,
                        "split": "validation" if seed == "17" else "test",
                        "promptVariant": choice,
                        "promptSeed": prompt_seed,
                    },
                )
                trace, systems = [], {}
                while obs["kind"] == "decision":
                    view = obs["semantic_view"]
                    metadata = view.pop("prompt_template")
                    selected = TRAIN[prompt_seed] if choice == "mixed" else choice
                    assert metadata == {
                        "bank": "cogmud-rules-v2",
                        "variant": selected,
                        "selection": choice,
                        "seed": prompt_seed,
                        "system_sha256": hashlib.sha256(
                            obs["messages"][0]["content"].encode()
                        ).hexdigest(),
                        "user_sha256": hashlib.sha256(
                            obs["messages"][1]["content"].encode()
                        ).hexdigest(),
                    }
                    system, user = [message["content"] for message in obs["messages"]]
                    assert systems.setdefault(obs["seat"], system) == system
                    assert (
                        "prompt_template" not in user and "prompt_selection" not in user
                    )
                    seat = obs["seat"]
                    for other in range(6):
                        if other != seat:
                            assert f"PRIVATE-{other}" not in user
                            assert f"PRIVATE-{other}" not in json.dumps(view)
                    assert all(isinstance(name, str) for name in view["room"]["cogs"])
                    assert "cogs" not in view and "scores" not in view
                    action = json.loads(
                        request(process, {"kind": "teacher"})["response"]
                    )
                    action["notes"] = f"PRIVATE-{seat}"
                    if obs["decision_id"] == 0:
                        action["action"] = "zzinvalidzz"
                    response = request(
                        process,
                        {
                            "kind": "step",
                            "decision_id": obs["decision_id"],
                            "response": json.dumps(action),
                        },
                    )
                    assert response["kind"] == "accepted"
                    assert response["action"]["notes"] == action["notes"]
                    assert response["action"] == action
                    trace.append((view, user, response["action"]))
                    assert len(trace) <= maximum
                    obs = response["observation"]
                assert (
                    obs["kind"] == "terminal" and len(trace) == 84 and len(systems) == 6
                )
                outcome = trace, obs
                if choice == "canonical":
                    canonical = outcome
                else:
                    assert outcome == canonical
                if choice == "mixed":
                    assert systems == direct[prompt_seed]
                else:
                    assert systems not in direct
                    direct.append(systems)
                print(
                    game,
                    seed,
                    choice,
                    prompt_seed,
                    len(trace),
                    "complete-game decisions; private view/hash/action/outcome parity PASS",
                    obs["scores"],
                    flush=True,
                )
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0

for language in (False, True):
    invalids = [
        {"promptVariant": value}
        for value in ("heldout-briefing", "heldout-reference", "unknown", "mixed")
    ]
    invalids += [
        {"promptVariant": "mixed", "promptSeed": value} for value in (-1, True, 1.5)
    ]
    invalids += [{"split": "unknown"}]
    if not language:
        invalids.append({"promptVariant": "plain"})
    for invalid in invalids:
        result = subprocess.run(
            [BINARY, MANIFEST, "standard"] + (["--language"] if language else []),
            input=json.dumps({"kind": "reset", "seed": "17", "players": 6} | invalid)
            + "\n",
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode != 0 and not result.stdout
