## Chrome provenance and scope.
##
## The viewer chrome is cogame-bullwhip's, not a lookalike (cogame-gridlock,
## 2026-08-23), so these tests are about PROVENANCE, not presence:
##   * `client/chrome.css` must byte-match the starter's file up to the
##     appended Cogmud banner — `tests/fixtures/starter_chrome.css` is that
##     file, committed so CI can diff against it without the starter checkout;
##   * both pages must still carry every element id the starter ships;
##   * no top-level name in the appended game block may collide with a name the
##     chrome defines above it (tandem, 2026-08-23);
##   * the appended CSS must define a rule for every beat kind the scrubber can
##     emit, or a beat renders invisible;
##   * and the emscripten link flags and the JS bootstrap that starts the
##     module must name the SAME factory and the SAME exports — they are a
##     matched pair and a mixture hangs on "Loading replay..." forever with
##     every asset returning 200 (cogame-lantern, 2026-08-23).

import std/[os, sets, strutils, unittest]

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc readRepo(relative: string): string =
  readFile(repoRoot() / relative)

proc topLevelNames(script: string): HashSet[string] =
  ## Every `function NAME` and `var NAME` declared at the start of a line
  ## (indented or not) in a page's inline script.
  for rawLine in script.splitLines():
    let line = rawLine.strip()
    for keyword in ["function ", "var "]:
      if not line.startsWith(keyword):
        continue
      var name = line[keyword.len .. ^1].strip()
      var cut = name.len
      for index, character in name:
        if character notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '$'}:
          cut = index
          break
      name = name[0 ..< cut]
      if name.len > 0:
        result.incl(name)

proc inlineScripts(page: string): string =
  ## Everything between <script> and </script> that is not a src= include.
  var rest = page
  while true:
    let open = rest.find("<script")
    if open < 0:
      break
    let openEnd = rest.find('>', open)
    if openEnd < 0:
      break
    let close = rest.find("</script>", openEnd)
    if close < 0:
      break
    let tag = rest[open .. openEnd]
    if "src=" notin tag:
      result.add(rest[openEnd + 1 ..< close])
      result.add("\n")
    rest = rest[close + 9 .. ^1]

const StarterIds = [
  "layout", "stage", "topband", "wordmark", "clock", "topright", "statuschip",
  "feedtoggle", "scorebug", "board-wrap", "table", "lightpool", "grain",
  "endscreen", "transport", "scrub", "play", "pos", "feed", "loading"
]

const BeatKinds = ["rob", "commission", "deal", "market", "end"]

const Banner = "/* ---------- Cogmud ---------- */"
const PageBanner = "COGMUD additions to the inherited cogame-bullwhip chrome"

suite "chrome provenance":
  test "chrome.css is the starter's file byte-for-byte up to the banner":
    let starter = readRepo("tests/fixtures/starter_chrome.css")
    let ours = readRepo("client/chrome.css")
    let at = ours.find(Banner)
    check at > 0
    ## The banner is appended after the starter's trailing newline.
    check ours[0 ..< at].strip(leading = false, trailing = true) ==
      starter.strip(leading = false, trailing = true)
    check ours.len > starter.len       # something really was appended

  test "the appended block defines a rule for every beat kind":
    let ours = readRepo("client/chrome.css")
    let appended = ours[ours.find(Banner) .. ^1]
    for kind in BeatKinds:
      checkpoint("beat kind " & kind)
      check (".beat-marker." & kind) in appended
      check (".treel button." & kind) in appended

  test "the scorebug survives 360 px":
    let ours = readRepo("client/chrome.css")
    ## The starter's own rule, kept: the name shrinks last and never below a
    ## few characters in the ~360 px featured-match iframe.
    check "min-width: 3.2em" in ours
    check "flex: 1 1 auto" in ours
    ## Labels go under 640 px; the scorebug halves under 480 px.
    check "@media (max-width: 640px)" in ours
    check "@media (max-width: 480px)" in ours
    let appended = ours[ours.find(Banner) .. ^1]
    check "#scorebug { grid-template-columns: repeat(6, 1fr); }" in appended
    check "grid-template-columns: repeat(2, 1fr)" in appended

  test "the loading caption never sits over the transport band":
    let appended = readRepo("client/chrome.css")
    check "#loading { bottom: var(--band); }" in appended

suite "the pages keep every element the starter ships":
  test "both pages carry every starter id and the two appended elements":
    for page in ["client/replay.html", "replay-viewer/index.html"]:
      let text = readRepo(page)
      checkpoint(page)
      for id in StarterIds:
        check ("id=\"" & id & "\"") in text
      ## Appended, not substituted.
      check "id=\"townbar\"" in text
      check "class=\"treel\" id=\"reel\"" in text
      ## The reel is a child of #transport, so --band includes it.
      let transportAt = text.find("id=\"transport\"")
      let reelAt = text.find("id=\"reel\"")
      let feedAt = text.find("id=\"feed\"")
      check transportAt > 0 and reelAt > transportAt and reelAt < feedAt
      ## #townbar sits between #scorebug and #board-wrap.
      check text.find("id=\"scorebug\"") < text.find("id=\"townbar\"")
      check text.find("id=\"townbar\"") < text.find("id=\"board-wrap\"")
      ## Nothing was removed, and there is no zoom bar / minimap: the map is a
      ## fixed arena that is always wholly in frame.
      check "viewpanel" notin text
      check "BULLWHIP" notin text
      check "COG<span>MUD</span>" in text
      check PageBanner in text

  test "relayout sets --band and --hudscale on the document element":
    for page in ["client/replay.html", "replay-viewer/index.html"]:
      let text = readRepo(page)
      checkpoint(page)
      check "function relayout()" in text
      check "document.documentElement" in text
      check "setProperty(\"--band\"" in text
      check "setProperty(\"--hudscale\"" in text
      check "getElementById(\"transport\").offsetHeight" in text or
        "transport.offsetHeight" in text
      check "addEventListener(\"resize\", relayout)" in text
      check "addEventListener(\"load\", relayout)" in text

  test "no name in the appended block collides with the chrome above it":
    for page in ["client/replay.html", "replay-viewer/index.html",
        "client/global.html", "client/player.html"]:
      let text = readRepo(page)
      let at = text.find(PageBanner)
      checkpoint(page)
      check at > 0
      let chrome = topLevelNames(inlineScripts(text[0 ..< at]))
      let game = topLevelNames(inlineScripts(text[at .. ^1]))
      check chrome.len > 0
      check game.len > 0
      let collisions = chrome * game
      checkpoint("chrome " & $chrome & " game " & $game)
      check collisions.len == 0
      ## The game block's builders are never named after a chrome function.
      check "markBeat" notin game
      check "buildScrub" notin game

suite "the wasm bundle is a matched pair":
  test "the link flags and the JS bootstrap name the same factory":
    let flags = readRepo("replay-viewer/config.nims")
    let shell = readRepo("replay-viewer/static_replay.js")
    check "-s MODULARIZE=1" in flags
    check "-s EXPORT_NAME=CogmudReplayModule" in flags
    ## MODULARIZE=1 means the generated JS defines a FACTORY and does nothing
    ## until it is called. The shell must call it.
    check "CogmudReplayModule()" in shell
    check "onRuntimeInitialized" notin shell

  test "every exported symbol is exported, called and defined":
    let flags = readRepo("replay-viewer/config.nims")
    let shell = readRepo("replay-viewer/static_replay.js")
    let module = readRepo("replay-viewer/cogmud_replay.nim")
    for symbol in ["cm_load_replay", "cm_payload_ptr", "cm_payload_len",
        "cm_error_ptr", "cm_error_len"]:
      checkpoint(symbol)
      check ("_" & symbol) in flags          # emscripten EXPORTED_FUNCTIONS
      check ("module._" & symbol) in shell   # the shell calls it
      check ("exportc: \"" & symbol & "\"") in module   # Nim defines it
    check "-s EXPORTED_RUNTIME_METHODS=HEAPU8" in flags
    check "module.HEAPU8" in shell
    check "emscripten_exit_with_live_runtime" in module

  test "the shell sets both load signals the CI viewer smoke reads":
    let shell = readRepo("replay-viewer/static_replay.js")
    let renderer = readRepo("client/renderer.js")
    ## The renderer sets data-replay-loaded on its FIRST DRAWN FRAME.
    check "setAttribute(\"data-replay-loaded\", \"true\")" in renderer
    ## The shell reports failure the same way and clears it on a retry.
    check "setAttribute(\"data-replay-error\"" in shell
    check "removeAttribute(\"data-replay-error\")" in shell
    ## And `ready` is gated on the attribute, so it always means a picture
    ## (eleusis, 2026-08-23).
    check "getAttribute(\"data-replay-loaded\")" in shell
    check "renderer never drew a frame" in shell

  test "the build hook ships every asset the pages name":
    let hook = readRepo("tools/build_replay_viewer.sh")
    for asset in ["soldier_red_front.png", "soldier_blue_front.png",
        "soldier_green_front.png", "soldier_yellow_front.png",
        "soldier_violet_front.png", "soldier_orange_front.png",
        "arena_floor.png", "font.ttf"]:
      checkpoint(asset)
      check asset in hook
      check fileExists(repoRoot() / "data" / asset)
    check "index.html" in hook
    check "static_replay.js" in hook
    check "renderer.js" in hook
    check "chrome.css" in hook
    ## `coworld build` pre-creates the output parent; ci.yml does not.
    check "mkdir -p \"$(dirname \"${output_dir}\")\"" in hook

suite "the renderer draws what the readouts promise":
  test "the game-block builders are distinctly named":
    let renderer = readRepo("client/renderer.js")
    check "function markCogmudBeat(" in renderer
    check "function buildCogmudReel(" in renderer
    ## Beats are labelled, clickable buttons, never inert divs.
    check "createElement(\"button\")" in renderer
    check "aria-label" in renderer
    check "marker.onclick" in renderer

  test "a hireling is drawn tethered to the employer it is standing with":
    let renderer = readRepo("client/renderer.js")
    ## The shield badge says a cog is hired; the amber tether says to whom.
    check "function drawTether(" in renderer
    check "seat.retainerOf" in renderer
    check "boss.room !== seat.room" in renderer

  test "the endcard is dismissed by every seek":
    let renderer = readRepo("client/renderer.js")
    check "container.classList.toggle(\"show\", !!show)" in renderer
    ## updateEndscreen is called from setIndex, i.e. on EVERY index change.
    let setIndex = renderer[renderer.find("function setIndex(") .. ^1]
    check setIndex.find("updateEndscreen(") < setIndex.find("setIndex(0, true)")

  test "spectator-side names replace aliases wherever a name is rendered":
    let renderer = readRepo("client/renderer.js")
    check "function makeNameMap(" in renderer
    check "isBaselineFiller" in renderer
    ## Including inside the chronicle's verbatim sentences.
    check "nameMap.text(sentence)" in renderer

  test "the readouts are words and numerals, never internal notation":
    let renderer = readRepo("client/renderer.js")
    check "COIN IN PLAY" in renderer
    check "COMMISSION UNITS FILLED" in renderer
    check "ROBBERIES" in renderer
    check "WALKED OUT RICHEST" in renderer
    check "WAITING ON " in renderer
    check "SETTLED" in renderer
