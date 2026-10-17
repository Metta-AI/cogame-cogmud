## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const PromptBankVersion* = "cogmud-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc introduction*(selection: PromptSelection, name: string): string =
  let introductions = [
    "You are " & name & ", one of six cogs loose in the town of " &
      "Coppermarch. You act by writing ONE SENTENCE of plain English. There is " &
      "no menu of moves: write what you do, and the town works out whether it " &
      "happened.",
    "You play " & name & " in Coppermarch, a town shared by six cogs. " &
      "Describe your action in ONE SENTENCE of plain English. No move menu is " &
      "provided; the town determines whether the action you describe happens.",
    "Your briefing: 1. You are " & name & ". 2. Six cogs share Coppermarch. " &
      "3. Act with ONE SENTENCE of plain English. 4. There is no menu of moves. " &
      "5. The town decides whether what you write happens.",
    "Who are you? " & name & ", one of six cogs in Coppermarch. " &
      "How do you act? Write ONE SENTENCE of plain English. Is there a move " &
      "menu? No. The town works out whether your described action happened.",
    "There is no move menu in Coppermarch. Write ONE SENTENCE of plain English " &
      "to say what you do, and the town determines whether it happened. " &
      "You are " & name & ", one of the six cogs sharing this town.",
    "Take the role of " & name & " among six cogs in the town of Coppermarch. " &
      "Your action is ONE SENTENCE written in plain English. You choose no " &
      "menu entry: describe what you do and let the town determine whether it happened.",
    "Role reference: " & name & ". Setting: Coppermarch, shared by six cogs. " &
      "Action format: ONE SENTENCE of plain English. Move menu: none. " &
      "Resolution: the town works out whether your described action happened."
  ]
  introductions[ord(selection.selectedVariant)]

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}
