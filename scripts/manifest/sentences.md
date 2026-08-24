# sentences.md - how the town reads a sentence

This is the page to read before writing a policy prompt. The parser is a pure
function of the sentence and the world: the same code runs in the game server,
in the tests and in the wasm replay viewer, so a replay's parses are exactly
reproducible. It decides only WHAT WAS MEANT - whether the exit exists, the
good is present or the coin is sufficient is the resolution step's job, and
that is where the outcome reason comes from.

## Normalisation

1. Lowercase, rune-aware. Curly quotes become straight ones.
2. Text inside the FIRST pair of double quotes is lifted out of the parse and
   spoken into the room, exactly like the `say` field. So
   `I hand Vell two hides and tell Bolt, "the alley is clear."` both acts and
   talks. An unterminated quote lifts nothing.
3. Everything that is not a letter, digit, quote or space is dropped and runs
   of whitespace collapse.
4. Possessives keep the stem: `Gizmo's` reads as `Gizmo`.

## The verb table

Scan left to right; **the FIRST token in the table decides the intent**. Two
verbs in one sentence and the first wins - `I walk to the docks and buy a rope`
is a MOVE.

| intent | verb tokens |
|---|---|
| go | go, goes, going, walk, walks, head, heads, move, travel, run, ride, leave, enter, cross, return, wander, slip (with a room named), off (with a room named), make (for) |
| take | take, takes, pick, picks, grab, lift (with no cog named), collect, scoop, pocket |
| drop | drop, drops, leave (with a good named and no room), put, discard, set (down) |
| buy | buy, buys, purchase, acquire, pay (for) |
| sell | sell, sells, offload, unload, flog |
| hand over | give, gives, hand, hands, deliver, delivers, turn (in/over), present, donate, pay (with a cog named), have/has (with a target named) |
| offer | offer, offers, propose, trade, swap, barter |
| accept | accept, accepts, agree, take (with "offer"/"deal"/"terms" in the sentence), deal, shake |
| hire | hire, hires, employ, retain, engage |
| rob | rob, robs, steal, stealing, mug, jump, ambush, waylay, lift (with a cog named), pick (... pocket), cut (... purse) |
| speak | say, says, tell, tells, shout, call, announce, whisper, ask (with no shopkeeper named) |
| ask | ask (with a shopkeeper named), asks, enquire, inquire, check, consult, read |
| wait | wait, waits, rest, linger, idle, listen, watch, stay, look, do (nothing) |

No verb found is `no_verb` - with ONE exception: a verbless sentence that names
both a shopkeeper and a good is read as a purchase, because
`Two hides, tanner, and be quick.` is a thing a cog says in a shop.

## The slots

Each is filled by a longest-phrase-wins scan (measured in TOKENS) over the
words after the verb, falling back to the whole sentence:

- **room** - any room's keywords or its full name. `the copper kettle` beats
  `copper`.
- **good** - any good's keywords, singular or plural.
- **shopkeeper** - any keeper's keywords or full name.
- **cog** - an exact match on any seat alias, including your own; the reflexive
  words (myself, me, self, yourself, itself, himself, herself) resolve to you,
  but only when no alias matched, so `hire Bolt ... with me` names Bolt.
- **quantity** - the first integer or number word (`a`, `an`, `one` ...
  `twenty`, `thirty`, `forty`, `fifty`, `hundred`, `both`, `couple`, `dozen`)
  appearing before the good; `all`/`every`/`everything` means the maximum legal
  quantity; the default is 1.
- **coin** - an integer next to `coin`/`coins`/`gp`/`silver`/`piece`/`pieces`/
  `crown`/`crowns`, or the integer following `for`. The default is 0.

Two different rooms, goods, keepers or cogs matching at the SAME token length
is `ambiguous_target`. A required slot missing is `no_target`, except that a
cog-targeting intent with no cog named is `no_such_cog` - you named somebody
this town does not have. A buy or sell with no keeper named defaults to the one
keeping shop in your room, and is `no_target` when there is none. An accept
with no cog named takes the single open offer addressed to you, and is
`no_such_offer` when there are two.

## Every outcome the town can report

`ok`, `waited`, `unparsed`, `no_verb`, `no_target`, `ambiguous_target`,
`no_such_exit`, `no_such_item`, `not_carrying`, `carry_limit`, `no_npc_here`,
`not_wanted`, `out_of_stock`, `cannot_afford`, `npc_broke`,
`no_matching_commission`, `no_such_cog`, `not_in_room`, `self_target`,
`no_such_offer`, `offer_expired`, `bound_by_contract`, `robbery_failed`,
`nothing_to_take`, `thievery_forbidden`, `rejected`.

Every one of them is explained back to the seat in plain English in its next
observation, quoted against the sentence that caused it. Nothing else punishes
an unreadable sentence: you simply lose the turn.

## The phrasebook

Every seat is shown these twelve lines every turn, as EXAMPLES and never as a
legal-move list:

```
I walk down to the Docks.
I pick up the coil of rope.
I drop the relic here.
I buy two hides from Tanner Oda.
I sell three nails to Dockmaster Fen.
I hand Guildmaster Vell two hides for my commission.
I offer Gizmo one lamp for twelve coins.
I accept Gizmo's offer.
I hire Bolt for fifteen coins to walk the road with me.
I jump Ratchet here in the dark and take what he is carrying.
I ask Guildmaster Vell about my commissions.
I wait by the well and listen.
```

## Writing a prompt

Name things exactly as the room names them - the observation spells out every
exit by destination name, every good on the floor, every cog present and every
good the keeper deals in, so a model never has to guess a noun. Tell your
policy to write ONE plain sentence and to read the outcome of its last one; a
sentence the town cannot read costs the whole turn, and the town always says
why.
