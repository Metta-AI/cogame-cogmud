"""Exercise complete native server/player games and preserve all test artifacts."""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        user = body["messages"][0]["content"]
        turn = int(re.match(r"Turn (\d+) of", user).group(1))
        slot = self.headers["X-Coworld-Player-Slot"]
        assert "PRIVATE_OPERATOR_" + slot in user
        assert all("PRIVATE_OPERATOR_" + str(i) not in user for i in range(6) if str(i) != slot)
        assert "SPECTATOR_POLICY_" not in user and "SPECTATOR_POLICY_" not in body["system"]
        retry = "Your previous reply was invalid" in user
        if turn == 2 or (turn == 1 and not retry):
            text = "invalid fixture reply"
        else:
            notes = "PRIVATE_CAPTURE_" + slot
            if turn == 3:
                notes = "é" * 5000
            action = {
                "action": "flibbertigibbet" if turn == 4 else "I wait by the well and listen.",
                "say": f"PUBLIC_TURN_{turn}_{slot}",
                "notes": notes,
            }
            # Omitted optional fields keep their native empty defaults.
            if turn == 6:
                action.pop("say")
                action.pop("notes")
            text = json.dumps(action)
        response = json.dumps(
            {
                "model": body["model"],
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": None if turn == 5 else {"input_tokens": 100, "output_tokens": 20},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode())))
        self.end_headers()
        self.wfile.write(response)


def run(game, player, output, variant, capture, model_enabled=True):
    root = output / f"{variant['id']}-capture{capture}{'' if model_enabled else '-offline'}"
    root.mkdir(mode=0o700)
    config = dict(variant["game_config"])
    seats = 6
    config.update(
        seed=42,
        turnDelayMs=0,
        players=[{"name": f"SPECTATOR_POLICY_{i}"} for i in range(seats)],
        llmTimeoutSeconds=1,
        playerConnectTimeoutSeconds=5,
        episodeTimeoutSeconds=600,
        tokens=[f"fixture-{i}" for i in range(seats)],
    )
    (root / "config.json").write_text(json.dumps(config))
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    env = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "COWORLD_LLM_MODEL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "AWS_BEARER_TOKEN_BEDROCK",
    ):
        env.pop(key, None)
    episode = f"cogmud-native-capture-fixture-{variant['id']}"
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=episode,
        COWORLD_GAME_VERSION="identity-fixture",
        COWORLD_SOURCE_REVISION="a" * 40,
    )
    if not capture:
        env.pop("COGAME_SAVE_TRAJECTORY_URI")
    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    if model_enabled:
        env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{provider.server_port}"
        env["COWORLD_LLM_MODEL"] = "native-capture-fixture"
    children = []
    streams = []
    try:
        log = (root / "game.log").open("wb")
        streams.append(log)
        server = subprocess.Popen([str(game)], env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(server)
        for _ in range(100):
            assert server.poll() is None, "game exited before readiness; see retained game.log"
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
                    assert response.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        else:
            raise TimeoutError("native game did not become ready")
        for seat in range(seats):
            log = (root / f"player-{seat}.log").open("wb")
            streams.append(log)
            player_env = dict(env, PLAYER_PROMPT=f"PRIVATE_OPERATOR_{seat}", COWORLD_TIMEOUT_SECONDS="600")
            player_env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port}/player?slot={seat}&token=fixture-{seat}"
            children.append(subprocess.Popen([str(player)], env=player_env, stdout=log, stderr=subprocess.STDOUT))
        assert server.wait(timeout=360) == 0
        for child in children[1:]:
            assert child.wait(timeout=5) == 0
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert results["reason"] == "complete"
        assert results["turns"] == config["turns"] == 14
        if capture:
            trace = root / "trajectory.jsonl"
            rows = [json.loads(line) for line in trace.read_text().splitlines()]
            assert trace.stat().st_mode & 0o077 == 0
            assert rows[-1]["status"] == "completed" and rows[-1]["outcome"] == results
            assert rows[-1]["seed_family"] == "cogmud-42"
            events = [event for event in replay["events"] if event["kind"] == "act"]
            assert len(events) == len(rows) - 1 == 84
            assert {row["decision_id"] for row in rows[:-1]} == {
                f"event-{i}" for i, event in enumerate(replay["events"]) if event["kind"] == "act"
            }
            for event, row in zip(events, rows[:-1], strict=True):
                seat = event["seat"]
                turn = event["turn"] + 1
                assert seat == int(row["seat"]) == row["observation"]["slot"]
                assert event["turn"] == row["observation"]["turn"]
                assert row["observation"]["turnsPlayed"] == event["turn"]
                assert not row["observation"]["done"]
                action = {
                    "action": event["sentence"],
                    "say": event.get("say", ""),
                    "notes": event.get("text", ""),
                }
                assert action == row["executed_action"]
                view = json.dumps(row["observation"], ensure_ascii=False)
                assert all(f"PRIVATE_CAPTURE_{i}" not in view for i in range(6) if i != seat)
                assert f"PUBLIC_TURN_{turn}_" not in json.dumps(row["observation"]["heard"])
                if not model_enabled:
                    assert row["action_status"] == "fallback"
                    assert row["selected_attempt_id"] is None
                    assert len(row["attempts"]) == 1 and row["attempts"][0]["origin"] == "unknown"
                    assert row["attempts"][0]["platform_call_id"] is None
                    continue
                attempts = row["attempts"]
                if turn == 1:
                    assert len(attempts) == 2 and not attempts[0]["accepted"]
                    assert attempts[1]["accepted"]
                    assert row["selected_attempt_id"] == attempts[1]["attempt_id"]
                elif turn == 2:
                    assert row["action_status"] == "fallback"
                    assert row["selected_attempt_id"] is None and len(attempts) == 2
                    assert event["scripted"]
                elif turn == 3:
                    assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
                    assert not attempts[0]["accepted"]
                elif turn == 6:
                    # Empty notes retain the existing memory in the engine.
                    # Preserve the reply, but exclude this unequal action join.
                    assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
                    assert attempts[-1]["rejection_reason"] == "native engine normalized the proposal"
                else:
                    assert row["action_status"] == "accepted"
                    assert row["selected_attempt_id"] == attempts[-1]["attempt_id"]
                    if turn == 4:
                        assert event["reason"] == "no_verb"
                        assert len(attempts) == 1, "legal no-op must not trigger a retry"
                if turn == 5:
                    assert attempts[0]["input_tokens"] is None and attempts[0]["output_tokens"] is None
                for attempt in attempts:
                    assert attempt["prompt"][0]["content"] == attempt["request"]["system"]
                    assert attempt["platform_call_id"] is not None and attempt["behavior_logprobs"] is None
                    assert "SPECTATOR_POLICY_" not in json.dumps(attempt["prompt"])
                    assert "PRIVATE_OPERATOR_" + str(seat) in attempt["request"]["messages"][0]["content"]
        return results, replay
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=5)
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for stream in streams:
            stream.close()


def main():
    game, player, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
    destination.mkdir(mode=0o700, exist_ok=False)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [
            (
                pool.submit(run, game, player, destination, variant, True),
                pool.submit(run, game, player, destination, variant, False),
            )
            for variant in manifest["variants"]
        ]
        for captured, ordinary in futures:
            assert captured.result() == ordinary.result(), "capture changed the native outcome or replay"
    captured = run(game, player, destination, manifest["variants"][0], True, model_enabled=False)
    ordinary = run(game, player, destination, manifest["variants"][0], False, model_enabled=False)
    assert captured == ordinary, "capture changed the offline fallback game"
    print(
        "six complete native games: replay parity, resolution-order joins, retries, fallback, "
        "normalization, legal no-op, privacy, missing usage and offline fallback pass"
    )


if __name__ == "__main__":
    main()
