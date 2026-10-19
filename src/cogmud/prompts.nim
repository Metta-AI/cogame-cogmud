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

const PromptBankVersion* = "cogmud-rules-v2"

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

const ActionBriefings = [
  "- Each turn you do exactly ONE thing. The town understands: going somewhere,\n  taking or dropping something lying on the ground, buying from or selling to a\n  shopkeeper standing in your room, handing goods to a shopkeeper, offering\n  another cog a trade, accepting an offer made to you last turn, hiring another\n  cog, robbing another cog, asking a shopkeeper about your commissions,\n  speaking, or waiting. Write it however you like; name the thing, the place or\n  the cog plainly.\n- If the town cannot read your sentence, you lose the turn and are told exactly\n  why. Nothing else punishes you for it.\n- You may act only on what is in the room you are standing in. You never see\n  any other room, and you never see what another cog is carrying or how much\n  coin it has.\n",
  "Do one thing each turn. You can go somewhere, take or drop an item on the ground, buy from or sell to a shopkeeper in your room, hand goods to a shopkeeper, offer another cog a trade, accept last turn's offer to you, hire or rob a cog, ask a shopkeeper about commissions, speak, or wait. Describe it freely, naming the item, place or cog clearly. An unreadable sentence costs the turn; you receive the exact reason and no further punishment. Act only on things in your current room. You cannot see other rooms or another cog's carried goods or coin balance.\n",
  "Action rules:\n1. Do exactly one thing per turn: go, take or drop a ground item, buy or sell with a shopkeeper in your room, hand goods to a shopkeeper, offer a cog a trade, accept an offer made to you last turn, hire, rob, ask a shopkeeper about commissions, speak, or wait.\n2. Use your own wording and name the item, place or cog plainly.\n3. An unreadable sentence loses the turn, with the exact reason explained and no other punishment.\n4. Act only on your current room's contents. Other rooms, other cogs' carried items and their coin balances are hidden.\n",
  "What can a turn do? Exactly one thing: go somewhere; take or drop a ground item; buy or sell with a shopkeeper in your room; hand goods to a shopkeeper; offer a cog a trade; accept last turn's offer to you; hire or rob a cog; ask a shopkeeper about commissions; speak; or wait. How should you write it? In your own words, naming the item, place or cog clearly. What if it cannot be read? Lose the turn, receive the exact reason, and incur no other punishment. Where can you act? Only in your current room. What is hidden? Other rooms and other cogs' carried goods and coin balances.\n",
  "You see only your current room, never another cog's carried goods or coin balance. Actions apply only to things in that room. An unreadable sentence loses your turn and gives an exact explanation, without another punishment. Describe one thing per turn in your own words, clearly naming the item, place or cog: go somewhere, take or drop a ground item, buy or sell with a local shopkeeper, hand goods to a shopkeeper, offer a trade, accept an offer made to you last turn, hire or rob another cog, ask a shopkeeper about commissions, speak, or wait.\n",
  "Action briefing: describe exactly one activity each turn, clearly naming the item, location or cog. You may go somewhere, take or drop a ground item, buy from or sell to a shopkeeper in your room, hand goods to a shopkeeper, offer another cog a trade, accept their offer from last turn, hire or rob a cog, ask a shopkeeper about commissions, speak, or wait. If the town cannot read the sentence, it explains exactly why and consumes the turn, with no other punishment. Your action must concern your current room; other rooms and other cogs' possessions and coin balances are unseen.\n",
  "Action reference\nBudget: exactly one activity per turn.\nActivities: go; take/drop ground items; buy/sell with a shopkeeper in your room; hand goods to a shopkeeper; offer a cog a trade; accept last turn's offer to you; hire; rob; ask a shopkeeper about commissions; speak; wait.\nWording: free phrasing with clear item, place or cog names.\nUnreadable sentence: lose the turn, receive an exact reason, no other punishment.\nScope: current room only. Other rooms and other cogs' carried items and coin balances are hidden.\n"
]

const MemoryBriefings = [
  "- Anything you say aloud is heard by every cog in your room, next turn. It need\n  not be true.\n- Your notes are private to you and fed back to you every turn.\n\n",
  "Every cog in your room hears what you say aloud on the next turn; you do not have to tell the truth. Notes are private and return to you each turn.\n\n",
  "Communication:\n1. All cogs in your room hear your spoken words next turn.\n2. Speech need not be truthful.\n3. Notes return privately to you every turn.\n\n",
  "Who hears your speech? Every cog in your room, next turn. Must it be true? No. Who receives your notes? Only you, each turn.\n\n",
  "Your private notes come back each turn. Spoken words, which need not be true, reach every cog in your room on the next turn.\n\n",
  "Communication briefing: speech reaches all cogs in your room next turn, and it may be false. Your notes stay private and are returned every turn.\n\n",
  "Communication reference: speech reaches every cog in your room next turn; truth is optional. Notes are private and returned to you each turn.\n\n"
]

proc actionBriefing*(selection: PromptSelection): string =
  ActionBriefings[ord(selection.selectedVariant)]

proc memoryBriefing*(selection: PromptSelection): string =
  MemoryBriefings[ord(selection.selectedVariant)]
