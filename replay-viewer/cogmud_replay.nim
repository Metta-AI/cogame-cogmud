## Cogmud static replay viewer, wasm side.
##
## JS hands the raw replay bytes to cm_load_replay; this module parses them
## with the SAME sim code the game server runs, re-derives the per-event town
## states, and exposes the enriched payload (identical shape to the game's
## /replay websocket message) for the shared renderer.js to draw. The parser,
## the price curve and the resolution order in the browser are the same Nim the
## server played the episode with, which is what makes a replay re-derivable
## from the seed plus the recorded sentences.

import
  std/json,
  cogmud/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc cmLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "cm_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    var config = defaultGameConfig()
    config.turns = replay["config"]{"turns"}.getInt(14)
    config.seed = replay["config"]{"seed"}.getInt(0)
    config.speech = replay["config"]{"speech"}.getBool(true)
    config.thievery = replay["config"]{"thievery"}.getBool(true)
    config.sampled = true
    for name in replay["names"]:
      config.players.add(PlayerConfig(name: name.getStr()))
    var events: seq[GameEvent]
    for node in replay["events"]:
      events.add(eventFromJson(node))
    var states = newJArray()
    for frame in replayMatch(config, events):
      states.add(frame.tableStateJson())
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("cogmud.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": replay{"results"},
      "states": states
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc cmPayloadPointer(): ptr uint8 {.exportc: "cm_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc cmPayloadLength(): cint {.exportc: "cm_payload_len", cdecl.} =
  cint(payload.len)

proc cmErrorPointer(): ptr uint8 {.exportc: "cm_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc cmErrorLength(): cint {.exportc: "cm_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals stay
  ## valid for the life of the page.
  emscriptenExitWithLiveRuntime()
