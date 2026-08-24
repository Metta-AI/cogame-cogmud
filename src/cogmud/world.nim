## The authored constant world of Coppermarch: nine rooms, six item kinds and
## five shopkeepers. Nothing here is random and nothing here is configurable —
## the server, the tests and the wasm replay viewer all read the same tables, so
## a replay re-derives the whole town from the seed plus the recorded actions.
##
## Pure data plus two derived things: `Adjacency` (an exit-membership matrix)
## and `Dist` (an all-pairs BFS distance matrix), both built at module init from
## the tables below so a change to an exit cannot leave them stale.

import std/json

const
  RoomCount* = 9
  ItemKinds* = 6
  NpcCount* = 5

type
  RoomSpec* = object
    id*: int
    name*: string
    desc*: string
    keywords*: seq[string]
    x*, y*: int          ## parchment-map coordinates on a 0..100 grid
    dark*: bool          ## the only rooms where robbery can succeed
    exits*: seq[int]

  ItemSpec* = object
    id*: int
    name*: string
    plural*: string
    keywords*: seq[string]
    baseValue*: int      ## the fixed reference valuation scoring uses

  NpcSpec* = object
    id*: int
    name*: string
    keywords*: seq[string]
    room*: int
    tradeList*: seq[int]      ## item ids it deals in, in restock order
    initialStock*: seq[int]   ## parallel to tradeList

const Rooms*: array[RoomCount, RoomSpec] = [
  RoomSpec(id: 0, name: "Market Square",
    desc: "A cobbled plaza around a dry well, loud with barrow traffic",
    keywords: @["market", "square", "well", "plaza"],
    x: 50, y: 50, dark: false, exits: @[1, 3, 5, 7]),
  RoomSpec(id: 1, name: "The Copper Kettle",
    desc: "A low tavern with a bar of hammered copper and too much lamp oil",
    keywords: @["kettle", "tavern", "inn", "copper"],
    x: 22, y: 26, dark: false, exits: @[0, 2, 8]),
  RoomSpec(id: 2, name: "Tanner's Row",
    desc: "Racks of drying hide from end to end; the smell arrives first",
    keywords: @["tanner", "tannery", "row", "tanners"],
    x: 50, y: 14, dark: false, exits: @[1, 3]),
  RoomSpec(id: 3, name: "The Smithy",
    desc: "One forge, one anvil, and iron cooling in barrels of black water",
    keywords: @["smithy", "smith", "forge", "anvil"],
    x: 78, y: 26, dark: false, exits: @[0, 2, 4]),
  RoomSpec(id: 4, name: "Warehouse Yard",
    desc: "Stacked crates under a leaking roof, half of them unclaimed",
    keywords: @["warehouse", "yard", "store", "stores"],
    x: 88, y: 52, dark: false, exits: @[3, 5]),
  RoomSpec(id: 5, name: "The Docks",
    desc: "Rotting quayside boards, unlit after the last barge is unloaded",
    keywords: @["docks", "dock", "quay", "harbour", "harbor", "wharf"],
    x: 78, y: 78, dark: true, exits: @[0, 4, 6]),
  RoomSpec(id: 6, name: "Cutpurse Alley",
    desc: "A black lane between two blind walls; the watch does not come here",
    keywords: @["alley", "cutpurse", "backstreet", "lane"],
    x: 50, y: 90, dark: true, exits: @[5, 7]),
  RoomSpec(id: 7, name: "The Chapel",
    desc: "A cold shrine to nobody in particular, kept swept and empty",
    keywords: @["chapel", "church", "shrine"],
    x: 22, y: 78, dark: false, exits: @[0, 6, 8]),
  RoomSpec(id: 8, name: "The Guildhall",
    desc: "A hall of ledgers where Guildmaster Vell settles every commission",
    keywords: @["guildhall", "guild", "hall", "board"],
    x: 12, y: 52, dark: false, exits: @[1, 7])
]

const Items*: array[ItemKinds, ItemSpec] = [
  ItemSpec(id: 0, name: "hide", plural: "hides",
    keywords: @["hide", "hides", "skin", "skins", "leather"], baseValue: 6),
  ItemSpec(id: 1, name: "nails", plural: "nails",
    keywords: @["nails", "nail", "iron"], baseValue: 7),
  ItemSpec(id: 2, name: "rope", plural: "rope",
    keywords: @["rope", "ropes", "coil", "cord"], baseValue: 8),
  ItemSpec(id: 3, name: "salt", plural: "salt",
    keywords: @["salt", "salts", "brine"], baseValue: 9),
  ItemSpec(id: 4, name: "lamp", plural: "lamps",
    keywords: @["lamp", "lamps", "lantern", "oil"], baseValue: 11),
  ItemSpec(id: 5, name: "relic", plural: "relics",
    keywords: @["relic", "relics", "idol", "icon"], baseValue: 14)
]

const Npcs*: array[NpcCount, NpcSpec] = [
  NpcSpec(id: 0, name: "Tanner Oda", keywords: @["tanner", "oda"], room: 2,
    tradeList: @[0, 3], initialStock: @[8, 5]),
  NpcSpec(id: 1, name: "Smith Bram", keywords: @["smith", "bram", "blacksmith"],
    room: 3, tradeList: @[1, 2], initialStock: @[8, 6]),
  NpcSpec(id: 2, name: "Keeper Nesh",
    keywords: @["keeper", "nesh", "innkeeper"], room: 1,
    tradeList: @[4, 3, 2], initialStock: @[4, 6, 4]),
  NpcSpec(id: 3, name: "Dockmaster Fen",
    keywords: @["dockmaster", "fen"], room: 5,
    tradeList: @[5, 0, 1], initialStock: @[3, 5, 6]),
  NpcSpec(id: 4, name: "Guildmaster Vell",
    keywords: @["guildmaster", "vell", "guildmistress"], room: 8,
    tradeList: @[2, 4], initialStock: @[4, 3])
]

const
  QuestItems* = [0, 1, 2, 3]
    ## Commissions are drawn only from these: lamp and relic are pure trade
    ## goods, so a commission can never demand the two most valuable items.
  GuildNpc* = 4
    ## Guildmaster Vell posts and settles EVERY commission in the game.

proc buildAdjacency(): array[RoomCount, array[RoomCount, bool]] =
  for room in Rooms:
    for exit in room.exits:
      result[room.id][exit] = true

let Adjacency* = buildAdjacency()

proc buildDist(): array[RoomCount, array[RoomCount, int]] =
  ## All-pairs BFS over the exit graph. -1 would mean unreachable; the world
  ## integrity test asserts nothing is.
  for source in 0 ..< RoomCount:
    for target in 0 ..< RoomCount:
      result[source][target] = -1
    result[source][source] = 0
    var frontier = @[source]
    while frontier.len > 0:
      var next: seq[int]
      for room in frontier:
        for exit in Rooms[room].exits:
          if result[source][exit] < 0:
            result[source][exit] = result[source][room] + 1
            next.add(exit)
      frontier = next

let Dist* = buildDist()

proc stepToward*(fromRoom, toRoom: int): int =
  ## The first room on a BFS shortest path, ties broken by lowest room id.
  ## -1 when already there or unreachable.
  if fromRoom == toRoom or Dist[fromRoom][toRoom] < 0:
    return -1
  let need = Dist[fromRoom][toRoom] - 1
  for exit in Rooms[fromRoom].exits:
    if Dist[exit][toRoom] == need:
      return exit
  -1

proc itemName*(item, count: int): string =
  ## "1 hide" / "2 hides" — words and numerals, never notation.
  $count & " " & (if count == 1: Items[item].name else: Items[item].plural)

proc worldJson*(): JsonNode =
  ## The map the viewer draws. Nothing about the parchment map is hardcoded in
  ## JS: rooms, roads, item values and shop locations all come from here, and
  ## the replay payload carries a copy so the bytes are self-sufficient.
  var rooms = newJArray()
  for room in Rooms:
    var exits = newJArray()
    for exit in room.exits:
      exits.add(%exit)
    rooms.add(%*{
      "id": room.id, "name": room.name, "desc": room.desc,
      "x": room.x, "y": room.y, "dark": room.dark, "exits": exits
    })
  var items = newJArray()
  for item in Items:
    items.add(%*{
      "id": item.id, "name": item.name, "plural": item.plural,
      "value": item.baseValue
    })
  var npcs = newJArray()
  for npc in Npcs:
    var trade = newJArray()
    for item in npc.tradeList:
      trade.add(%item)
    npcs.add(%*{
      "id": npc.id, "name": npc.name, "room": npc.room, "trade": trade
    })
  %*{"rooms": rooms, "items": items, "npcs": npcs}
