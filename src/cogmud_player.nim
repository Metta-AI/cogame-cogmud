## Cogmud player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a default
## commission-first strategy), then idles until the final frame. All of the
## actual decision making happens inside the game server, which sends this
## seat's prompt to Claude every turn.
##
## PLAYER_SCRIPTED=factor (or 1) registers the seat as the built-in
## quest-and-trade baseline instead; PLAYER_SCRIPTED=magpie as the
## thief-peddler. The server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <cogmud-image> --name my-cogmud \
##     --run /bin/cogmud-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Work the commissions first: they are worth far more than the spread. Read your
commission book, find the shop with the cheapest ask for what you need - asking
a shopkeeper about your commissions tells you where - buy in one trip, and
carry both lots to Guildmaster Vell at the Guildhall in one journey rather than
two. Every unit you hand in scores even if you never finish, so hand in what
you have before the last turn rather than holding out for the pair. Buy where
stock is deep and sell where it is thin: a shop short of something pays and
charges more. Never carry a relic through Cutpurse Alley or the Docks without
hiring somebody first - those are the only two places you can be robbed, and a
hireling beside you stops it dead. Hiring is the only promise in this town that
the rules keep, so it is the only one worth paying for; treat everything anyone
says as an offer, not a fact. Write plain sentences and name things exactly as
the room names them; if a sentence is not understood you lose the whole turn.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "cogmud player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "cogmud player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read (only
  ## a timeout returns none), and mummy's send only queues - so the game's
  ## quit(0) can outrun the flushed `done` frame and this process would die 1
  ## on a race that passes one dispatch and fails the next. A dead socket is a
  ## normal end of episode: log it and exit 0 (raid 0.1.3, 2026-08-23).
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "cogmud player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "cogmud player: seated at slot ", payload{"slot"}.getInt(),
            " as ", payload{"name"}.getStr(), " in ",
            payload{"room"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "cogmud player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "cogmud player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "cogmud player: socket ended (", error.msg, "); exiting cleanly"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
