// Cogmud shared renderer + drivers.
//
// One canvas scene — the town of Coppermarch as a parchment map. Nine rooms
// are ink-outlined cards laid out from their authored x/y coordinates, joined
// by dashed ink roads drawn from the room graph itself; nothing about the map
// is hardcoded here, it all arrives in the replay bytes under config.world.
// Each card carries the room name, a stack of crate glyphs for what is lying
// on its floor, a shop awning with the keeper's name and a price tag, and a
// lantern glyph that is UNLIT for the two dark rooms — which is how a
// spectator sees at a glance where a robbery can happen. Six cog tokens walk
// the roads, badged with alias, purse and pack; trades, thefts, hires and
// commission deliveries fire icon FX over the map. Under the map a strip
// charts all six seats' scores across the turns, ruled amber at every
// successful theft and paper at every commission filled.
//
// Fed by three drivers: the live /global websocket, the live /player
// websocket, and replay (from the game's /replay websocket or the static wasm
// bundle). All state derivation happens server-side / wasm-side; this file
// only draws state objects — see sim.nim's tableStateJson.
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CRATE = "#c9a46a";
  var CRATE_EDGE = "#6b4c22";
  var ROB = "#e0523a";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  // Timing: a token eases along its road, FX hang for a beat, bubbles pop.
  var SLIDE_MS = 700;
  var FX_MS = 1600;
  var BUBBLE_HOLD_MS = 6000;
  var ROBBED_HOLD_MS = 2600;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    // Six cog kits, one tint per seat, plus the parchment floor.
    var names = COLORS.map(function (color) {
      return "soldier_" + color + "_front.png";
    }).concat(["arena_floor.png"]);
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function coins(value) {
    return (value || 0) + "c";
  }

  function score(value) {
    return (Math.round((value || 0) * 100) / 100).toFixed(2);
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- World helpers -------------------------------------------------------

  function worldOf(view) {
    return (view && view.world) || { rooms: [], items: [], npcs: [] };
  }

  function itemName(world, id, count) {
    var item = (world.items || [])[id];
    if (!item) return count + " things";
    return count + " " + (count === 1 ? item.name : item.plural);
  }

  function npcName(world, id) {
    var npc = (world.npcs || [])[id];
    return npc ? npc.name : "the shopkeeper";
  }

  function roomName(world, id) {
    var room = (world.rooms || [])[id];
    return room ? room.name : "somewhere";
  }

  // ---- Layout --------------------------------------------------------------

  // The map is a FIXED arena: nine rooms on a 0..100 grid, always rescaled to
  // whatever canvas the viewer is embedded in, so the whole board is in frame
  // at every size and a zoom control would be dead weight.
  function computeLayout(width, height, world) {
    var margin = 8;
    var chartH = Math.max(64, Math.min(height * 0.24, 140));
    var mapTop = margin;
    var mapH = height - chartH - margin * 2;
    var mapW = width - margin * 2;
    var cardW = Math.max(80, Math.min(mapW * 0.215, 210));
    var cardH = Math.max(48, Math.min(mapH * 0.185, 112));
    var scale = Math.max(0.55, Math.min(1.25, cardW / 160));
    var x0 = margin + cardW / 2;
    var spanX = Math.max(1, mapW - cardW);
    var y0 = mapTop + cardH / 2;
    var spanY = Math.max(1, mapH - cardH);
    var cards = (world.rooms || []).map(function (room) {
      return {
        id: room.id,
        cx: x0 + spanX * (room.x || 0) / 100,
        cy: y0 + spanY * (room.y || 0) / 100
      };
    });
    return {
      width: width, height: height, margin: margin, scale: scale,
      mapTop: mapTop, mapH: mapH, cardW: cardW, cardH: cardH, cards: cards,
      compact: width < 560,
      chart: { x: margin, y: height - chartH - margin, w: mapW, h: chartH }
    };
  }

  function cardOf(L, id) {
    for (var i = 0; i < L.cards.length; i++) {
      if (L.cards[i].id === id) return L.cards[i];
    }
    return null;
  }

  // A room card is three zones and nothing overlaps: the header (room name and
  // lantern), the shop column on the right when a keeper is present, and the
  // token band that fills whatever is left. The ground crates sit along the
  // bottom of the token band.
  function cardZones(L, roomId, hasShop) {
    var card = cardOf(L, roomId);
    if (!card) return null;
    var x = card.cx - L.cardW / 2;
    var y = card.cy - L.cardH / 2;
    var scale = L.scale;
    var header = 15 * scale;
    var ground = 12 * scale;
    var shopW = hasShop ? Math.min(L.cardW * 0.44, 104 * scale) : 0;
    var tokenW = L.cardW - shopW - 8 * scale;
    return {
      x: x, y: y, scale: scale,
      headerBottom: y + header,
      shopX: x + L.cardW - shopW - 4 * scale,
      shopY: y + header + 2 * scale,
      shopW: shopW,
      shopH: L.cardH - header - 6 * scale,
      tokenLeft: x + 4 * scale,
      tokenWidth: tokenW,
      tokenCx: x + 4 * scale + tokenW / 2,
      tokenTop: y + header,
      tokenBottom: y + L.cardH - ground,
      groundY: y + L.cardH - 3 * scale
    };
  }

  function hasShopIn(view, roomId) {
    var npcs = view.npcs || [];
    for (var i = 0; i < npcs.length; i++) {
      if (npcs[i].room === roomId) return true;
    }
    return false;
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var world = worldOf(view);
    var L = computeLayout(w, h, world);
    var now = view.now || Date.now();
    var fx = view.effects || {};

    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    ctx.save();
    ctx.fillStyle = STRIP;
    roundRect(ctx, 4, L.mapTop - 2, w - 8, L.mapH + 4, 10 * L.scale);
    ctx.fill();
    ctx.restore();

    drawRoads(ctx, L, world);
    (world.rooms || []).forEach(function (room) {
      drawRoomCard(ctx, L, world, view, room, now, fx);
    });
    drawTokens(ctx, images, L, world, view, now, fx);
    drawEffects(ctx, L, world, view, now, fx);
    drawChart(ctx, L.chart, view, L.scale);
  }

  function drawRoads(ctx, L, world) {
    ctx.save();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.22)";
    ctx.lineWidth = Math.max(1.5, 2 * L.scale);
    ctx.setLineDash([6 * L.scale, 5 * L.scale]);
    (world.rooms || []).forEach(function (room) {
      var from = cardOf(L, room.id);
      if (!from) return;
      (room.exits || []).forEach(function (exit) {
        if (exit < room.id) return;   // each road once
        var to = cardOf(L, exit);
        if (!to) return;
        ctx.beginPath();
        ctx.moveTo(from.cx, from.cy);
        ctx.lineTo(to.cx, to.cy);
        ctx.stroke();
      });
    });
    ctx.restore();
  }

  function roomStateOf(view, id) {
    var rooms = view.rooms || [];
    for (var i = 0; i < rooms.length; i++) {
      if (rooms[i].id === id) return rooms[i];
    }
    return { id: id, items: [], cogs: [] };
  }

  function npcInRoom(view, world, id) {
    var npcs = view.npcs || [];
    for (var i = 0; i < npcs.length; i++) {
      if (npcs[i].room === id) return npcs[i];
    }
    return null;
  }

  function drawRoomCard(ctx, L, world, view, room, now, fx) {
    var Z = cardZones(L, room.id, hasShopIn(view, room.id));
    if (!Z) return;
    var scale = L.scale;
    var state = roomStateOf(view, room.id);
    var robbedAt = (fx.robbedRoomAt || {})[room.id];
    var flash = robbedAt && now - robbedAt < ROBBED_HOLD_MS ?
      1 - (now - robbedAt) / ROBBED_HOLD_MS : 0;

    ctx.save();
    // Parchment card with an ink border.
    ctx.fillStyle = room.dark ? "rgba(214, 199, 172, 0.80)" :
      "rgba(242, 232, 216, 0.96)";
    ctx.shadowColor = "rgba(0, 0, 0, 0.5)";
    ctx.shadowBlur = 6 * scale;
    roundRect(ctx, Z.x, Z.y, L.cardW, L.cardH, 5 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = flash > 0 ? rgba(ROB, 0.35 + 0.65 * flash) : INK;
    ctx.lineWidth = flash > 0 ? 3 * scale : 1.5 * scale;
    ctx.stroke();

    // Room name.
    ctx.fillStyle = INK;
    ctx.font = "700 " + Math.round(11.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText(
      ellipsize(ctx, room.name.toUpperCase(), L.cardW - 20 * scale),
      Z.x + 6 * scale, Z.y + 3 * scale);

    // Lantern: unlit in the two dark rooms, which is where robbery works.
    drawLantern(ctx, Z.x + L.cardW - 10 * scale, Z.y + 9 * scale, scale,
      !room.dark);

    // Ground items as crate glyphs with a count, along the token band's foot.
    var gx = Z.tokenLeft + 2 * scale;
    var total = 0;
    (state.items || []).forEach(function (count, id) {
      if (!count) return;
      total += count;
      drawCrate(ctx, gx, Z.groundY - 8 * scale, 7 * scale, CRATE, CRATE_EDGE);
      ctx.fillStyle = INK;
      ctx.font = "700 " + Math.round(8.5 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "alphabetic";
      ctx.fillText(String(count), gx + 9 * scale, Z.groundY);
      gx += 18 * scale;
      void id;
    });
    if (!total) {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(8 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "alphabetic";
      ctx.fillText("bare floor", Z.tokenLeft + 2 * scale, Z.groundY);
    }

    // Shop awning: the keeper's name and a price tag, in its own column.
    var npc = npcInRoom(view, world, room.id);
    if (npc) {
      drawAwning(ctx, L, Z, world, npc);
    }
    ctx.restore();
  }

  function drawLantern(ctx, x, y, scale, lit) {
    ctx.save();
    ctx.strokeStyle = INK;
    ctx.lineWidth = 1.2 * scale;
    ctx.fillStyle = lit ? AMBER : "rgba(42, 31, 22, 0.25)";
    ctx.beginPath();
    ctx.moveTo(x - 4 * scale, y + 4 * scale);
    ctx.lineTo(x - 3 * scale, y - 3 * scale);
    ctx.lineTo(x + 3 * scale, y - 3 * scale);
    ctx.lineTo(x + 4 * scale, y + 4 * scale);
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(x, y - 3 * scale);
    ctx.lineTo(x, y - 6 * scale);
    ctx.stroke();
    if (!lit) {
      ctx.strokeStyle = ROB;
      ctx.lineWidth = 1.6 * scale;
      ctx.beginPath();
      ctx.moveTo(x - 5 * scale, y + 5 * scale);
      ctx.lineTo(x + 5 * scale, y - 5 * scale);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawAwning(ctx, L, Z, world, npc) {
    var scale = Z.scale;
    var rows = [];
    (npc.stock || []).forEach(function (count, id) {
      if (!npc.ask || !npc.ask[id]) return;
      rows.push({ id: id, stock: count, ask: npc.ask[id], bid: npc.bid[id] });
    });
    rows.sort(function (a, b) { return a.ask - b.ask; });
    // Below 560 px the tag shrinks to the single cheapest ask; the lantern and
    // the tokens stay full size.
    var shown = L.compact ? rows.slice(0, 1) : rows.slice(0, 3);
    var h = Math.min(Z.shopH, 11 * scale + shown.length * 9 * scale);
    ctx.save();
    ctx.fillStyle = "rgba(42, 31, 22, 0.92)";
    roundRect(ctx, Z.shopX, Z.shopY, Z.shopW, h, 3 * scale);
    ctx.fill();
    ctx.fillStyle = AMBER;
    ctx.font = "700 " + Math.round(8.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText(ellipsize(ctx, npcName(world, npc.id), Z.shopW - 6 * scale),
      Z.shopX + 3 * scale, Z.shopY + 1.5 * scale);
    ctx.fillStyle = PAPER;
    ctx.font = "600 " + Math.round(8 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    shown.forEach(function (row, i) {
      var item = (world.items || [])[row.id];
      ctx.fillText(ellipsize(ctx,
        (item ? item.name : "?") + " " + row.ask + " / " + row.bid,
        Z.shopW - 6 * scale),
        Z.shopX + 3 * scale, Z.shopY + 11 * scale + i * 9 * scale);
    });
    ctx.restore();
  }

  function drawCrate(ctx, x, y, s, fill, edge) {
    ctx.fillStyle = fill;
    ctx.fillRect(x, y, s, s);
    ctx.strokeStyle = edge;
    ctx.lineWidth = 1;
    ctx.strokeRect(x + 0.5, y + 0.5, s - 1, s - 1);
    ctx.beginPath();
    ctx.moveTo(x + 1, y + s / 2);
    ctx.lineTo(x + s - 1, y + s / 2);
    ctx.stroke();
  }

  // Several tokens in one room fan out on a small arc so none is hidden, and
  // they stay inside the card's token band so nothing ever rides over the room
  // name or the shop's price tag.
  function tokenSpot(L, view, roomId, index, count) {
    var Z = cardZones(L, roomId, hasShopIn(view, roomId));
    if (!Z) return { x: L.width / 2, y: L.height / 2 };
    var cy = (Z.tokenTop + Z.tokenBottom) / 2 - 3 * L.scale;
    if (count <= 1) return { x: Z.tokenCx, y: cy };
    var spread = Math.min(Z.tokenWidth * 0.78, 20 * L.scale * (count - 1));
    var step = spread / Math.max(1, count - 1);
    return { x: Z.tokenCx - spread / 2 + step * index, y: cy };
  }

  function tokenSize(L, view, roomId) {
    var Z = cardZones(L, roomId, hasShopIn(view, roomId));
    if (!Z) return 24;
    return Math.max(20, Math.min((Z.tokenBottom - Z.tokenTop) * 0.62,
      Z.tokenWidth * 0.42, 46 * L.scale));
  }

  function drawTokens(ctx, images, L, world, view, now, fx) {
    var seats = view.seats || [];
    var byRoom = {};
    var byId = {};
    var spots = {};
    seats.forEach(function (seat) {
      var key = String(seat.room);
      byRoom[key] = byRoom[key] || [];
      byRoom[key].push(seat.seat);
      byId[String(seat.seat)] = seat;
    });
    seats.forEach(function (seat) {
      var group = byRoom[String(seat.room)] || [seat.seat];
      var here = tokenSpot(L, view, seat.room, group.indexOf(seat.seat),
        group.length);
      var from = (fx.moveFrom || {})[seat.seat];
      var at = (fx.moveAt || {})[seat.seat];
      var spot = here;
      if (typeof from === "number" && at && now - at < SLIDE_MS) {
        var t = (now - at) / SLIDE_MS;
        var eased = 1 - Math.pow(1 - t, 3);
        var start = tokenSpot(L, view, from, 0, 1);
        spot = {
          x: start.x + (here.x - start.x) * eased,
          y: start.y + (here.y - start.y) * eased
        };
      }
      spots[String(seat.seat)] = spot;
    });
    // The amber tether, under the tokens: a hireling is joined to its employer
    // while they share a room. The shield badge says only THAT a cog is hired;
    // the tether says to whom, which is what makes a bodyguard legible in a
    // crowded card.
    seats.forEach(function (seat) {
      if (!(seat.retainerTurns > 0) || !(seat.retainerOf >= 0)) return;
      var boss = byId[String(seat.retainerOf)];
      if (!boss || boss.room !== seat.room) return;
      drawTether(ctx, spots[String(seat.seat)], spots[String(boss.seat)],
        L.scale);
    });
    seats.forEach(function (seat) {
      var group = byRoom[String(seat.room)] || [seat.seat];
      var spot = spots[String(seat.seat)];
      var size = tokenSize(L, view, seat.room);
      drawToken(ctx, images, L, view, seat, spot, size,
        group.indexOf(seat.seat), group.length);
      var sayAt = (fx.sayAt || {})[seat.seat];
      var say = (fx.lastSay || {})[seat.seat];
      if (say && sayAt && now - sayAt < BUBBLE_HOLD_MS) {
        drawBubble(ctx, spot.x, spot.y - size * 0.52, say,
          L.cardW * 1.5, L.scale,
          Math.max(0.4, 1 - (now - sayAt) / BUBBLE_HOLD_MS));
      }
    });
    void world;
  }

  function drawTether(ctx, from, to, scale) {
    if (!from || !to) return;
    ctx.save();
    ctx.strokeStyle = rgba(AMBER, 0.8);
    ctx.lineWidth = Math.max(1, 1.2 * scale);
    ctx.setLineDash([4 * scale, 3 * scale]);
    ctx.beginPath();
    ctx.moveTo(from.x, from.y);
    ctx.lineTo(to.x, to.y);
    ctx.stroke();
    ctx.restore();
  }

  function drawToken(ctx, images, L, view, seat, spot, size, index, count) {
    var scale = L.scale;
    var color = seatColor(seat.seat);
    var sprite = images["soldier_" + color + "_front.png"];
    ctx.save();
    // Tint ring on the ground under the wheels: a ring around the body would
    // hide the satchel and the cloak that make the cog read as a trader.
    ctx.fillStyle = rgba(COLOR_HEX[color], 0.55);
    ctx.beginPath();
    ctx.ellipse(spot.x, spot.y + size * 0.40, size * 0.36, size * 0.13, 0, 0,
      Math.PI * 2);
    ctx.fill();
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, spot.x - size / 2, spot.y - size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(spot.x - size / 3, spot.y - size / 3, size / 1.5,
        size / 1.5);
    }
    if (seat.retainerTurns > 0) {
      drawShield(ctx, spot.x + size * 0.36, spot.y - size * 0.28, scale);
    }
    // Alias / policy name and purse on ONE chip pinned under the wheels, so a
    // token never rides over the room name or the shop's tag. A crowded room
    // drops the purse and staggers the chips into two rows, so six cogs in one
    // card still read.
    var crowded = (count || 1) > 1;
    var label = (seat.name || "") +
      (crowded ? "" : "  " + coins(seat.coin) +
        (seat.carried ? " \u00b7 " + seat.carried : ""));
    ctx.font = "700 " + Math.round((crowded ? 8.5 : 9.5) * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var maxW = crowded ? Math.max(30 * scale, size * 1.7) :
      Math.max(46 * scale, size * 3.0);
    var text = ellipsize(ctx, label, maxW);
    var pad = 3 * scale;
    var bw = ctx.measureText(text).width + pad * 2;
    var bh = 12 * scale;
    var by = spot.y + size * 0.46 +
      (crowded && (index % 2) ? bh + 1.5 * scale : 0);
    ctx.fillStyle = "rgba(42, 31, 22, 0.88)";
    roundRect(ctx, spot.x - bw / 2, by, bw, bh, 2 * scale);
    ctx.fill();
    ctx.fillStyle = COLOR_HEX[color];
    ctx.fillRect(spot.x - bw / 2, by, 2 * scale, bh);
    ctx.fillStyle = PAPER;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, spot.x + scale, by + bh / 2);
    ctx.restore();
    void view;
  }

  function drawShield(ctx, x, y, scale) {
    ctx.save();
    ctx.fillStyle = AMBER;
    ctx.strokeStyle = INK;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x, y - 6 * scale);
    ctx.lineTo(x + 5 * scale, y - 3 * scale);
    ctx.lineTo(x + 5 * scale, y + 2 * scale);
    ctx.lineTo(x, y + 7 * scale);
    ctx.lineTo(x - 5 * scale, y + 2 * scale);
    ctx.lineTo(x - 5 * scale, y - 3 * scale);
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
    ctx.restore();
  }

  // One icon per act class, all over the map, all fading out together.
  function drawEffects(ctx, L, world, view, now, fx) {
    var list = fx.pulses || [];
    var seats = view.seats || [];
    function spotOfSeat(id) {
      var seat = seats[id];
      if (!seat) return null;
      var group = [];
      seats.forEach(function (s) {
        if (s.room === seat.room) group.push(s.seat);
      });
      return tokenSpot(L, view, seat.room, group.indexOf(id), group.length);
    }
    list.forEach(function (pulse) {
      var age = now - pulse.at;
      if (age > FX_MS) return;
      var t = age / FX_MS;
      var alpha = 1 - t;
      var from = spotOfSeat(pulse.seat);
      if (!from) return;
      var card = cardOf(L, pulse.room);
      ctx.save();
      ctx.globalAlpha = Math.max(0, alpha);
      switch (pulse.kind) {
        case "market":
          drawFloatTag(ctx, from.x, from.y - 24 * L.scale - 22 * t * L.scale,
            pulse.label, pulse.sign > 0 ? "#45a85e" : ROB, L.scale);
          break;
        case "commission":
          if (card) {
            drawSeal(ctx, card.cx, card.cy - L.cardH * 0.05 - 20 * t * L.scale,
              pulse.label, L.scale);
          }
          break;
        case "deal":
          drawFloatTag(ctx, from.x, from.y - 24 * L.scale - 18 * t * L.scale,
            pulse.label, AMBER, L.scale);
          break;
        case "rob":
          drawFloatTag(ctx, from.x, from.y - 34 * L.scale - 24 * t * L.scale,
            pulse.label, ROB, L.scale);
          break;
        case "watch":
          drawFloatTag(ctx, from.x, from.y - 28 * L.scale - 22 * t * L.scale,
            pulse.label, PAPER_DIM, L.scale);
          break;
        case "puff":
          ctx.font = "700 " + Math.round(20 * L.scale) +
            "px 'rajdhani', system-ui, sans-serif";
          ctx.textAlign = "center";
          ctx.textBaseline = "middle";
          ctx.fillStyle = PAPER_DIM;
          ctx.fillText("?", from.x + 14 * L.scale,
            from.y - 22 * L.scale - 16 * t * L.scale);
          break;
        default:
          break;
      }
      ctx.restore();
    });
    void world;
  }

  function drawFloatTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var pad = 5 * scale;
    var bw = ctx.measureText(text).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = PAPER;
    ctx.fillRect(x - bw / 2, y - bh / 2, bw, bh);
    ctx.strokeStyle = accent;
    ctx.lineWidth = 1.5;
    ctx.strokeRect(x - bw / 2, y - bh / 2, bw, bh);
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, x, y + scale);
    ctx.restore();
  }

  function drawSeal(ctx, x, y, text, scale) {
    ctx.save();
    ctx.fillStyle = "#8d2f26";
    ctx.beginPath();
    ctx.arc(x, y, 15 * scale, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = AMBER;
    ctx.lineWidth = 1.5 * scale;
    ctx.stroke();
    ctx.fillStyle = PAPER;
    ctx.font = "700 " + Math.round(8 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, x, y + 24 * scale);
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function drawBubble(ctx, x, bottom, text, maxW, scale, alpha) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(10.5 * scale) +
      "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
    var pad = 6 * scale;
    var lineH = 13 * scale;
    var lines = wrapLines(ctx, text, maxW - pad * 2, 3);
    var bw = 0;
    lines.forEach(function (l) { bw = Math.max(bw, ctx.measureText(l).width); });
    bw += pad * 2;
    var bh = lines.length * lineH + pad * 2 - 2;
    var y = bottom - bh - 6 * scale;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 5;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x - bw / 2, y, bw, bh, 5 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.beginPath();
    ctx.moveTo(x - 5 * scale, y + bh);
    ctx.lineTo(x, y + bh + 6 * scale);
    ctx.lineTo(x + 5 * scale, y + bh);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (l, i) {
      ctx.fillText(l, x - bw / 2 + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  // The bottom strip: every seat's score across the turns, ruled amber at each
  // successful theft and paper at each commission filled. The picture of who
  // is winning and what changed it.
  function drawChart(ctx, rect, view, scale) {
    var series = view.scoreSeries || [];
    var turns = Math.max(view.turns || 0, 4);
    var padL = 30 * scale;
    var padR = 8 * scale;
    var padT = 14 * scale;
    var padB = 13 * scale;
    var x0 = rect.x + padL;
    var x1 = rect.x + rect.w - padR;
    var y0 = rect.y + padT;
    var y1 = rect.y + rect.h - padB;
    var lo = 0;
    var hi = 1;
    series.forEach(function (line) {
      line.forEach(function (v) {
        if (v > hi) hi = v;
        if (v < lo) lo = v;
      });
    });
    hi = Math.ceil((hi + 0.2) * 2) / 2;
    lo = Math.floor((lo - 0.2) * 2) / 2;
    if (hi - lo < 1) hi = lo + 1;
    function px(turn) { return x0 + (x1 - x0) * turn / turns; }
    function py(v) { return y1 - (y1 - y0) * (v - lo) / (hi - lo); }

    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.font = "700 " + Math.round(9.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("SCORE BY TURN", rect.x + 8 * scale, rect.y + 2 * scale);

    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    for (var g = 0; g <= 2; g++) {
      var gv = lo + (hi - lo) * g / 2;
      var gy = py(gv);
      ctx.beginPath();
      ctx.moveTo(x0, gy);
      ctx.lineTo(x1, gy);
      ctx.stroke();
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(8.5 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.textBaseline = "middle";
      ctx.fillText(gv.toFixed(1), x0 - 4 * scale, gy);
    }

    (view.chartRules || []).forEach(function (rule) {
      ctx.strokeStyle = rule.kind === "rob" ? rgba(ROB, 0.7) :
        "rgba(242, 232, 216, 0.4)";
      ctx.lineWidth = 1.5;
      ctx.setLineDash(rule.kind === "rob" ? [] : [3, 3]);
      ctx.beginPath();
      ctx.moveTo(px(rule.turn), y0);
      ctx.lineTo(px(rule.turn), y1);
      ctx.stroke();
      ctx.setLineDash([]);
      if (rule.kind === "rob") {
        ctx.fillStyle = rgba(ROB, 0.85);
        ctx.font = "700 " + Math.round(7.5 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.textAlign = "left";
        ctx.textBaseline = "top";
        ctx.fillText("ROBBERY", px(rule.turn) + 2 * scale, y0);
      }
    });

    series.forEach(function (line, seat) {
      if (!line.length) return;
      ctx.strokeStyle = COLOR_HEX[seatColor(seat)];
      ctx.lineWidth = 2;
      ctx.lineJoin = "round";
      ctx.beginPath();
      line.forEach(function (v, i) {
        var x = px(i);
        var y = py(v);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.stroke();
      var last = line.length - 1;
      ctx.fillStyle = COLOR_HEX[seatColor(seat)];
      ctx.beginPath();
      ctx.arc(px(last), py(line[last]), 2.5 * scale, 0, Math.PI * 2);
      ctx.fill();
    });

    var nowX = px(view.turn || 0);
    ctx.strokeStyle = rgba(AMBER, 0.8);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(nowX, y0 - 3 * scale);
    ctx.lineTo(nowX, y1);
    ctx.stroke();
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The cogs only ever hear anonymous aliases ("Sprocket", "Gizmo"); the
  // payload carries the policy names separately, spectator-side only. A name
  // map swaps them in wherever a name is RENDERED — including inside the
  // chronicle's verbatim sentences — while the recorded bytes keep the alias.
  // Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  var REASON_TEXT = {
    ok: "",
    waited: "waited and watched.",
    unparsed: "not understood.",
    no_verb: "not understood: it names no action the town knows.",
    no_target: "not understood: nothing to act on.",
    ambiguous_target: "not understood: two things named at once.",
    no_such_exit: "there is no road that way.",
    no_such_item: "nothing of that lying here.",
    not_carrying: "not carrying that.",
    carry_limit: "the pack is full.",
    no_npc_here: "no shopkeeper here.",
    not_wanted: "the shopkeeper does not deal in that.",
    out_of_stock: "the shopkeeper has none.",
    cannot_afford: "not enough coin.",
    npc_broke: "the shopkeeper has run out of coin.",
    no_matching_commission: "no commission wanted it — the goods are gone.",
    no_such_cog: "no cog of that name in this town.",
    not_in_room: "that cog is not here.",
    self_target: "you cannot do that to yourself.",
    no_such_offer: "no such offer is open.",
    offer_expired: "the offer could not be settled.",
    bound_by_contract: "bound by contract — a hireling cannot rob its employer.",
    robbery_failed: "the attempt failed.",
    nothing_to_take: "nothing worth taking.",
    thievery_forbidden: "the watch is everywhere; nobody robs.",
    rejected: "the town refused it."
  };

  // Kinds the scrubber and the reel classify beats by. Five, and the appended
  // chrome block defines a CSS rule for every one of them.
  function beatKind(event) {
    if (event.kind === "end") return "end";
    if (event.kind !== "act") return "";
    if (event.intent === "rob") return "rob";
    if (event.intent === "give" && event.npc === 4 && event.reason === "ok") {
      return "commission";
    }
    if (event.intent === "accept" || event.intent === "hire" ||
        event.intent === "trade" || event.intent === "give") {
      return "deal";
    }
    if (event.intent === "buy" || event.intent === "sell") return "market";
    return "";
  }

  function actLine(event, world, nameMap) {
    var who = clampName(nameMap.seat(event.seat));
    var qty = event.qty || 0;
    switch (event.intent) {
      case "move":
        return event.reason === "ok" ?
          who + " walks to " + roomName(world, event.toRoom) + "." : "";
      case "take":
        return who + " picks up " + itemName(world, event.item, qty) + ".";
      case "drop":
        return who + " drops " + itemName(world, event.item, qty) + ".";
      case "buy":
        return who + " buys " + itemName(world, event.item, qty) + " from " +
          npcName(world, event.npc) + " for " + event.coin + " coin.";
      case "sell":
        return who + " sells " + itemName(world, event.item, qty) + " to " +
          npcName(world, event.npc) + " for " + event.coin + " coin.";
      case "give":
        if (event.npc === 4 && event.reason === "ok") {
          return itemName(world, event.item, qty) + " delivered — " +
            event.coin + " commission points.";
        }
        if (event.npc >= 0) {
          return who + " hands " + itemName(world, event.item, qty) + " to " +
            npcName(world, event.npc) + ".";
        }
        return who + " gives " + itemName(world, event.item, qty) + " to " +
          clampName(nameMap.seat(event.other)) + ".";
      case "trade":
        return who + " offers " + clampName(nameMap.seat(event.other)) + " " +
          itemName(world, event.item, qty) + " for " + event.coin + " coin.";
      case "hire":
        return who + " offers to hire " + clampName(nameMap.seat(event.other)) +
          " for " + event.coin + " coin.";
      case "accept":
        if (event.item < 0 || event.item === undefined) {
          return who + " takes " + clampName(nameMap.seat(event.other)) +
            "'s coin and is hired for three turns.";
        }
        return who + " accepts " + clampName(nameMap.seat(event.other)) +
          "'s offer: " + itemName(world, event.item, qty) + " for " +
          event.coin + " coin.";
      case "rob":
        if (event.reason === "ok") {
          return "robbery succeeded — took " +
            (event.item >= 0 ? itemName(world, event.item, 1) :
              event.coin + " coin") + " from " +
            clampName(nameMap.seat(event.other)) + ".";
        }
        if (event.reason === "robbery_failed") {
          return "robbery failed — " + who + " pays " + event.coin +
            " coin to " + clampName(nameMap.seat(event.other)) + ".";
        }
        return "";
      case "quest":
        return who + " asks " + npcName(world, event.npc) +
          " where the goods are cheap.";
      default:
        return "";
    }
  }

  function beatLabel(event, world, nameMap) {
    if (event.kind === "end") return "Final";
    var body = actLine(event, world, nameMap);
    if (!body) {
      body = clampName(nameMap.seat(event.seat)) + " — " + event.intent;
    }
    return "Turn " + ((event.turn || 0) + 1) + " — " + body;
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "TURN " + (block + 1);
  }

  // Renders the full chronicle grouped into one section per turn. Each act
  // shows the VERBATIM sentence in the seat's colour, then a dim mechanical
  // outcome, then the spoken line and a dimmer notes line when they changed.
  // currentIndex (replay) marks how far playback has reached; omit it live.
  function renderFeed(element, events, nameMap, currentIndex, world) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var lastNotes = {};
    var w = world || { rooms: [], items: [], npcs: [] };
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.turn;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      var future = i >= limit ? " feed-future" : "";
      if (event.kind === "start") {
        html += '<div class="feed-line feed-turn-line' + future + '">' +
          "Six cogs loose in Coppermarch, forty coin each." + "</div>";
        continue;
      }
      if (event.kind === "turn") {
        var coin = 0;
        var filled = 0;
        (event.cogs || []).forEach(function (cog) {
          coin += cog.coin || 0;
          (cog.delivered || []).forEach(function (d) { filled += d || 0; });
        });
        html += '<div class="feed-line feed-turn-line' + future + '">' +
          escapeHtml("Turn " + ((event.turn || 0) + 1) + " opens — " + coin +
            " coin in play, " + filled + " commission units filled.") +
          "</div>";
        continue;
      }
      if (event.kind === "end") {
        html += '<div class="feed-line feed-end' + future + '">' +
          escapeHtml("Final — " + (event.turn || 0) + " turns played.") +
          "</div>";
        if (event.text === "deadline") {
          html += '<div class="feed-line feed-fail' + future + '">' +
            "Episode deadline — the town closed early." + "</div>";
        }
        continue;
      }
      // act
      var sentence = event.sentence || "";
      if (sentence) {
        html += '<div class="feed-line feed-sentence seat' +
          (event.seat % COLORS.length) + future + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + ': "' +
            nameMap.text(sentence) + '"') + "</div>";
      }
      var line = actLine(event, w, nameMap);
      var reasonText = event.reason === "ok" ? "" :
        (REASON_TEXT[event.reason] || event.reason);
      var body = line || reasonText;
      if (body) {
        var cls = event.intent === "rob" ? "feed-rob" :
          (event.intent === "give" && event.npc === 4) ? "feed-commission" :
          event.reason !== "ok" && event.reason !== "waited" ? "feed-fail" :
          "feed-outcome";
        var tail = line && reasonText ? line + " " + reasonText :
          (line || reasonText);
        html += '<div class="feed-line ' + cls + future + '">' +
          escapeHtml(nameMap.text(tail)) + "</div>";
      }
      if (event.say) {
        html += '<div class="feed-line feed-say' + future + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + ' says: "' +
            nameMap.text(event.say) + '"') + "</div>";
      }
      if (event.text && event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-notes' + future + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects: when
  // a token started walking, what it said, and which icon FX are still fading.
  function makeEffects(world) {
    var seen = 0;
    var moveFrom = {};
    var moveAt = {};
    var sayAt = {};
    var lastSay = {};
    var robbedRoomAt = {};
    var pulses = [];
    var w = world || { rooms: [], items: [], npcs: [] };
    function pulse(event, now, kind, label, sign) {
      pulses.push({
        seat: event.seat, room: event.room, kind: kind, label: label,
        sign: sign || 0, at: now
      });
      if (pulses.length > 40) pulses.splice(0, pulses.length - 40);
    }
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "turn") {
            continue;
          }
          if (event.kind !== "act") continue;
          if (event.say) {
            lastSay[event.seat] = event.say;
            sayAt[event.seat] = animate ? now : null;
          }
          if (!animate) continue;
          if (event.intent === "move" && event.reason === "ok") {
            moveFrom[event.seat] = event.room;
            moveAt[event.seat] = now;
          } else if (event.intent === "buy" && event.reason === "ok") {
            pulse(event, now, "market", "−" + event.coin + "c", -1);
          } else if (event.intent === "sell" && event.reason === "ok") {
            pulse(event, now, "market", "+" + event.coin + "c", 1);
          } else if (event.intent === "give" && event.reason === "ok") {
            if (event.npc === 4) {
              pulse(event, now, "commission",
                event.coin > 4 * Math.max(event.qty || 1, 1) ?
                  "COMMISSION FILLED +" + event.coin :
                  "COMMISSION +" + event.coin, 1);
            } else {
              pulse(event, now, "deal",
                itemName(w, event.item, event.qty || 1), 0);
            }
          } else if ((event.intent === "accept" || event.intent === "trade" ||
              event.intent === "hire") && event.reason === "ok") {
            pulse(event, now, "deal",
              event.intent === "hire" ? "HIRE " + event.coin + "c" :
              event.intent === "trade" ? "OFFER " + event.coin + "c" :
              "DEAL " + event.coin + "c", 0);
          } else if (event.intent === "rob") {
            if (event.reason === "ok") {
              pulse(event, now, "rob", "✦ ROBBED", 0);
              robbedRoomAt[event.room] = now;
            } else if (event.reason === "robbery_failed") {
              pulse(event, now, "watch", "WATCH −" + event.coin + "c", -1);
              robbedRoomAt[event.room] = now;
            }
          } else if (event.intent === "none") {
            pulse(event, now, "puff", "?", 0);
          }
        }
      },
      reset: function () {
        seen = 0;
        moveFrom = {}; moveAt = {}; sayAt = {}; lastSay = {};
        robbedRoomAt = {}; pulses = [];
      },
      view: function () {
        return {
          effects: {
            moveFrom: moveFrom, moveAt: moveAt, sayAt: sayAt,
            lastSay: lastSay, robbedRoomAt: robbedRoomAt, pulses: pulses
          }
        };
      }
    };
  }

  // Score-by-turn series and the rules under it, derived from the recorded
  // turn events up to the playhead.
  function chartFrom(events, limit) {
    var series = [[], [], [], [], [], []];
    var rules = [];
    var robbed = [0, 0, 0, 0, 0, 0];
    var filled = [0, 0, 0, 0, 0, 0];
    var stop = limit === undefined ? events.length : limit;
    for (var i = 0; i < stop && i < events.length; i++) {
      var event = events[i];
      if (event.kind === "turn") {
        (event.cogs || []).forEach(function (cog, seat) {
          if (seat >= 6) return;
          var wealth = cog.coin || 0;
          var values = [6, 7, 8, 9, 11, 14];
          (cog.items || []).forEach(function (count, id) {
            wealth += (values[id] || 0) * (count || 0);
          });
          var points = 0;
          (cog.delivered || []).forEach(function (d) {
            points += 4 * (d || 0) + (d >= 2 ? 8 : 0);
          });
          series[seat].push((wealth + 3 * points - 40) / 40);
        });
      } else if (event.kind === "act" && event.intent === "rob" &&
          event.reason === "ok") {
        rules.push({ turn: event.turn, kind: "rob" });
        robbed[event.seat] += 1;
      } else if (event.kind === "act" && event.intent === "give" &&
          event.npc === 4 && event.reason === "ok" &&
          event.coin > 4 * Math.max(event.qty || 1, 1)) {
        rules.push({ turn: event.turn, kind: "commission" });
        filled[event.seat] += 1;
      }
    }
    return { series: series, rules: rules };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config, results) {
    var parts = [];
    if (!state) return "";
    var total = state.turns || (config && config.turns) || 0;
    if ((state.gameDone || state.done) && results) {
      var names = results.names || [];
      var scores = results.scores || [];
      var best = 0;
      scores.forEach(function (v, i) { if (v > scores[best]) best = i; });
      return "FINAL · " + String(names[best] || "").toUpperCase() + " " +
        score(scores[best]);
    }
    // The closing snapshot carries turn == turnsPlayed, so clamp: a spectator
    // must never read "TURN 9 / 8".
    var shown = total ? Math.min((state.turn || 0) + 1, total) :
      (state.turn || 0) + 1;
    parts.push("TURN " + shown + (total ? " / " + total : ""));
    if (state.gameDone || state.done) {
      parts.push("FINAL");
    } else if (state.seats) {
      var waiting = state.seats.filter(function (s) { return s.pending; });
      parts.push(waiting.length ? "WAITING ON " + waiting.length : "SETTLED");
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap, world) {
    if (!container || !state || !state.seats) return;
    var html = "";
    var w = world || state.world || { rooms: [] };
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        '<span class="plate-room">' +
        escapeHtml(roomName(w, seat.room).toUpperCase()) + "</span>" +
        '<span class="plate-score">' + escapeHtml(score(seat.score)) +
        "</span>" +
        '<span class="plate-label">' + escapeHtml(coins(seat.coin)) +
        "</span>" +
        '<span class="plate-pack">' + (seat.carried || 0) +
        (seat.carried === 1 ? " item" : " items") + "</span>" +
        (seat.robbed && state.recentRobbed &&
          state.recentRobbed.indexOf(index) >= 0 ?
          '<span class="plate-robbed">ROBBED</span>' : "") +
        (seat.retainerTurns > 0 ?
          '<span class="plate-hired">HIRED</span>' : "") +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function updateTownbar(container, state) {
    if (!container || !state) return;
    var town = state.town || {};
    var total = state.turns || 0;
    var shown = total ? Math.min((state.turn || 0) + 1, total) :
      (state.turn || 0) + 1;
    var narrow = window.innerWidth < 480;
    var text = narrow ?
      "T" + shown + "/" + total + " · " +
        (town.coinInPlay || 0) + "c · " + (town.robberies || 0) + " ROBBED" :
      "TURN " + shown + "/" + total + " · " +
        (town.coinInPlay || 0) + " COIN IN PLAY · " + (town.delivered || 0) +
        " COMMISSION UNITS FILLED · " + (town.robberies || 0) +
        " ROBBERIES · " + (town.trades || 0) + " DEALS";
    if (container.textContent !== text) container.textContent = text;
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.turns || 0) +
          " of " + (results.maxTurns || results.turns || 0) + " turns";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " WALKED OUT RICHEST" : "ALL LEVEL";
    var reason = reasonLine(results);
    var filled = 0;
    (results.delivered || []).forEach(function (d) { filled += d || 0; });
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.turns || 0) + " TURN" +
      ((results.turns || 0) === 1 ? "" : "S") + " · " + filled +
      " COMMISSION UNITS FILLED</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">coin</span>' +
      '<span class="end-head">pack</span>' +
      '<span class="end-head">points</span>' +
      '<span class="end-head">robberies</span>' +
      '<span class="end-head">score</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      var pack = ((results.wealth || [])[i] || 0) -
        ((results.coin || [])[i] || 0);
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(escapeHtml(String((results.coin || [])[i] || 0))) +
        cell(escapeHtml(String(pack))) +
        cell(escapeHtml(String((results.questPoints || [])[i] || 0))) +
        cell(escapeHtml(String((results.robberies || [])[i] || 0))) +
        cell(escapeHtml(score(scores[i])));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.world = state.world || { rooms: [], items: [], npcs: [] };
    view.seats = applyNames(state.seats, nameMap);
    view.rooms = state.rooms || [];
    view.npcs = state.npcs || [];
    view.offers = state.offers || [];
    view.town = state.town || {};
    view.turn = state.turn || 0;
    view.turns = state.turns || 0;
    view.turnsPlayed = state.turnsPlayed || 0;
    view.phase = state.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, townbar, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects(null);
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state" && data.seats) latest = data;
            if (latest) {
              nameMap = makeNameMap(
                (latest.seats || []).map(function (s) { return s.name; }),
                latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined, latest.world);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest, null);
              }
              updateScorebug(options.scorebug, latest, nameMap, latest.world);
              updateTownbar(options.townbar ||
                document.getElementById("townbar"), latest);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var chart = chartFrom(latest.events || [], undefined);
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone),
            scoreSeries: chart.series,
            chartRules: chart.rules
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // A beat marker is a LABELLED, CLICKABLE button, never an inert div: the
  // scrubber's beats are how a spectator jumps to the moment that mattered.
  // Named markCogmudBeat, not markBeat, so no chrome alias assignment can
  // silently shadow it (tandem, 2026-08-23).
  function markCogmudBeat(container, index, total, kind, seat, label, onSeek) {
    var marker = document.createElement("button");
    marker.type = "button";
    marker.className = "beat-marker " + kind +
      (typeof seat === "number" && seat >= 0 ?
        " seat" + (seat % COLORS.length) : "");
    marker.style.left = ((index + 1) / Math.max(total, 1) * 100) + "%";
    marker.title = label;
    marker.setAttribute("aria-label", label);
    marker.onclick = function (evt) {
      evt.stopPropagation();
      onSeek(index + 1);
    };
    container.appendChild(marker);
    return marker;
  }

  // The highlight reel: up to eight buttons, the highest-SALIENCE act events of
  // the episode, ties broken by earlier event index, laid out in salience
  // order. The idea's "chosen by event salience, not tick order", made
  // mechanical. Named buildCogmudReel for the same shadowing reason.
  function buildCogmudReel(container, events, nameMap, world, onSeek) {
    if (!container) return;
    container.innerHTML = "";
    var ranked = [];
    events.forEach(function (event, i) {
      if (event.kind !== "act") return;
      ranked.push({ index: i, salience: event.salience || 0, event: event });
    });
    ranked.sort(function (a, b) {
      if (b.salience !== a.salience) return b.salience - a.salience;
      return a.index - b.index;
    });
    ranked.slice(0, 8).forEach(function (entry) {
      var kind = beatKind(entry.event) || "market";
      var button = document.createElement("button");
      button.type = "button";
      button.className = "treel-beat " + kind + " seat" +
        (entry.event.seat % COLORS.length);
      button.textContent = "T" + ((entry.event.turn || 0) + 1) + " · " +
        kind.toUpperCase() + " · " +
        clampName(nameMap.seat(entry.event.seat));
      button.title = beatLabel(entry.event, world, nameMap);
      button.onclick = function () { onSeek(entry.index + 1); };
      container.appendChild(button);
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per turn and a labelled
  // button per salient beat.
  function buildScrub(container, events, nameMap, world, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.turn;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0 && r % 4 === 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = beatKind(event);
      if (!kind) return;
      if (event.kind === "act" && (event.salience || 0) < 40) return;
      markCogmudBeat(container, i, events.length, kind,
        event.kind === "act" ? event.seat : -1,
        beatLabel(event, world, nameMap), onSeek);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) - rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      if (evt.target && evt.target.classList &&
          evt.target.classList.contains("beat-marker")) {
        return;               // the beat button owns its own click
      }
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, reel, playButton, label, clock, scorebug,
    //           townbar, endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var world = config.world || { rooms: [], items: [], npcs: [] };
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects(world);
      var reel = options.reel || document.getElementById("reel");
      var townbar = options.townbar || document.getElementById("townbar");
      var scrub = buildScrub(options.scrub, events, nameMap, world,
        function (next) {
          playing = false;
          setIndex(next, true);
        });
      buildCogmudReel(reel, events, nameMap, world, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", turn: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) {
          renderFeed(options.feed, events, nameMap, index, world);
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        var state = currentState();
        if (options.clock) {
          options.clock.textContent = matchHeader(state, config,
            index >= events.length && events.length > 0 ? payload.results :
              null);
        }
        updateScorebug(options.scorebug, state, nameMap, world);
        updateTownbar(townbar, state);
        // Every seek re-evaluates the endcard, so any scrub below the last
        // event takes it down.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is looking at: a turn opening gets read,
        // an act less so, a spoken line a little longer.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "turn" ? 1500 :
          shown && shown.kind === "act" ? (shown.say ? 900 : 450) :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var chart = chartFrom(events, index);
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0,
          scoreSeries: chart.series,
          chartRules: chart.rules
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      // The load signal the CI viewer smoke and the hosted theater read: set
      // on the FIRST DRAWN FRAME, never merely on a parsed payload.
      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.CogmudRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle,
    markCogmudBeat: markCogmudBeat,
    buildCogmudReel: buildCogmudReel
  };
})();
