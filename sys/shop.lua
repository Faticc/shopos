-- shop - магазин: витрина из МЭ, цены из выгрузки, счёт монетами.
--
-- Как это работает для игрока:
--   1. встал на PIM - магазин узнал ник и показал его счёт;
--   2. положил в инвентарь монеты customnpcs:npcMoney и нажал «Пополнить» -
--      монеты ушли в МЭ, на счёт легла их стоимость;
--   3. выбрал предмет на витрине, количество, «Купить» - предмет пришёл из
--      МЭ в инвентарь, со счёта списана цена.
--
-- На витрине только то, что есть в МЭ и имеет цену в каталоге. Цена - поле
-- "min" выгрузки цен клиента, переведённое в монеты по курсу из конфига.

local computer, unicode = computer, unicode
local root = require("root")
local gfx = require("gfx")
local catalog = require("catalog")
local storage = require("storage")
local wallet = require("wallet")

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local fill, text, pad, clip, button = gfx.fill, gfx.text, gfx.pad, gfx.clip, gfx.button

local shop = {}

-- ------------------------------------------------------------------ настройки

local cfg = root:table("/cfg/shop.cfg") or {}
local TITLE = cfg.title or "МАГАЗИН"
-- конфиг от прежнего ShopOS давал валюту списком номиналов: берём первый
local COIN = cfg.currency or {}
if COIN[1] then COIN = COIN[1] end
if not COIN.id then COIN = { id = "customnpcs:npcMoney", dmg = 0 } end
local COIN_VALUE = cfg.coinValue or COIN.value or 1   -- монет счёта за штуку
local RATE = (cfg.rate or 1) * (cfg.markup or 1)      -- монет за единицу цены
local MODS = cfg.modNames or {}
local SIGN = cfg.sign or "$"

local W, H = gfx.W, gfx.H

-- цвета подобраны из палитры монитора 3-го уровня: чужие он всё равно
-- округлил бы до ближайших
local C = {
	bg     = 0x0F0F0F,
	panel  = 0x1E1E1E,
	card   = 0x2D2D2D,
	line   = 0x3C3C3C,
	text   = 0xE1E1E1,
	dim    = 0x878787,
	faint  = 0x5A5A5A,
	gold   = 0xFFDB00,
	green  = 0x33B640,
	red    = 0xCC2400,
	blue   = 0x334980,
	accent = 0x3392BF,
	black  = 0x000000,
}

-- ------------------------------------------------------------------ состояние

local store = storage.new(cfg)
-- в старом конфиге путь смотрит на каталог прежнего формата
local cat, catErr = catalog.open(cfg.catalog or "/data/catalog.bin")
if not cat and cfg.catalog then cat, catErr = catalog.open("/data/catalog.bin") end

local nick                -- кто стоит на PIM
local balance = 0         -- его счёт, в сотых монеты
local stock = {}          -- товары в наличии
local stockErr            -- почему витрина пуста
local sections = {}       -- { id, name, n }
local view = {
	screen = "idle",       -- idle | grid | item
	section = nil,         -- мод или nil - все
	query = "",
	sort = "name",         -- name | cheap | dear
	page = 1,
	sideTop = 1,
	item = nil,
	qty = 1,
}
local shown = {}          -- товары текущей выборки
local hits = {}           -- кликабельные области кадра
local toast = { text = nil, colour = C.dim, till = 0 }

-- ------------------------------------------------------------------ деньги

--- Цена штуки в сотых монеты, дробная: дёшевое стоит доли сотой, и
--- округляется только итог.
local function unitOf(rec) return rec.price * RATE * 100 end

--- Итог в сотых: до ближайшей сотой, но не меньше одной - иначе кирка за
--- 1.50028 стоила бы 1.51, а горсть земли - ноль.
local function totalOf(e, n)
	if n <= 0 then return 0 end
	return max(1, floor(n * e.unit + 0.5))
end

local function money(cents) return wallet.format(cents) .. " " .. SIGN end

--- Цена за штуку для витрины. Дешевле сотой - столько знаков, сколько
--- нужно, чтобы стало видно цифру: земля 0.00004, а не 0.00.
local function unitText(e)
	local u = e.unit / 100
	if u >= 0.01 then return wallet.format(floor(e.unit + 0.5)) .. " " .. SIGN end
	local d = 3
	while d < 8 and u * 10 ^ d < 1 do d = d + 1 end
	return ("%." .. d .. "f %s"):format(u, SIGN)
end

local function num(n)
	local s = ("%.0f"):format(n):reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return (s:gsub("^ ", ""))
end

-- ------------------------------------------------------------------ склад

local function modOf(id) return id:match("^([^:]+)") or id end
local function modName(m) return MODS[m] or m end

--- Перечитать МЭ: что есть, почём, по разделам.
local function refresh()
	if not cat then
		stock, stockErr = {}, "каталог цен не загружен: " .. tostring(catErr)
		sections = {}
		return
	end
	local items, err = store:scan()
	if not items then
		stock, stockErr = {}, err
		sections = {}
		return
	end
	local keys = {}
	for i = 1, #items do
		items[i].key = catalog.key(items[i].id, items[i].dmg)
		keys[i] = items[i].key
	end
	cat:resolve(keys)
	local out, per = {}, {}
	for i = 1, #items do
		local it = items[i]
		local rec = cat:get(it.key)
		if rec and rec.price > 0 and not (it.id == COIN.id and it.dmg == (COIN.dmg or 0)) then
			it.rec, it.unit = rec, unitOf(rec)
			it.label = rec.label ~= "" and rec.label or it.key
			it.low = unicode.lower(it.label)
			it.mod = modOf(it.id)
			out[#out + 1] = it
			per[it.mod] = (per[it.mod] or 0) + 1
		end
	end
	local list = {}
	for m, n in pairs(per) do list[#list + 1] = { id = m, name = modName(m), n = n } end
	table.sort(list, function(a, b) return unicode.lower(a.name) < unicode.lower(b.name) end)
	stock, sections, stockErr = out, list, nil
	-- раздел раскупили целиком - назад ко всем товарам
	if view.section and not per[view.section] then view.section, view.page = nil, 1 end
	if #out == 0 then stockErr = "в МЭ нет товаров с ценой" end
end

--- Выборка витрины по разделу, поиску и сортировке.
local function choose()
	local q = unicode.lower(view.query)
	local out = {}
	for i = 1, #stock do
		local e = stock[i]
		if (not view.section or e.mod == view.section)
			and (q == "" or e.low:find(q, 1, true)) then
			out[#out + 1] = e
		end
	end
	local s = view.sort
	table.sort(out, function(a, b)
		if s == "cheap" and a.unit ~= b.unit then return a.unit < b.unit end
		if s == "dear" and a.unit ~= b.unit then return a.unit > b.unit end
		if a.low ~= b.low then return a.low < b.low end
		return a.key < b.key
	end)
	shown = out
end

local function findStock(key)
	for i = 1, #stock do if stock[i].key == key then return stock[i] end end
	return nil
end

-- ------------------------------------------------------------------ кадр

local function hit(x, y, w, h, fn) hits[#hits + 1] = { x, y, x + w - 1, y + h - 1, fn } end

--- Разбить подпись на две строки по словам.
local function wrap2(s, n)
	if unicode.len(s) <= n then return s, "" end
	local cut = n
	for i = n, floor(n / 2), -1 do
		if unicode.sub(s, i, i) == " " then cut = i break end
	end
	local a = unicode.sub(s, 1, cut):gsub(" +$", "")
	local b = unicode.sub(s, cut + 1):gsub("^ +", "")
	return a, clip(b, n)
end

local function drawIcon(e, x, y, back, scale)
	local cells = cat and cat:cells(e.rec)
	if cells then
		gfx.icon(cells, e.rec.braille and 1 or 0, cat.iw, cat.ih, x, y, back, scale)
	else
		local w, h = cat.iw * (scale or 1), cat.ih * (scale or 1)
		fill(x, y, w, h, back)
		text(x + floor((w - 1) / 2), y + floor(h / 2), "?", C.faint, back)
	end
end

local CW, CH = 20, 12     -- карточка товара

local function drawCard(e, x, y)
	fill(x, y, CW, CH, C.card)
	drawIcon(e, x + 2, y + 1, C.card)
	local a, b = wrap2(e.label, CW - 2)
	text(x + 1, y + 9, pad(a, CW - 2), C.text, C.card)
	text(x + 1, y + 10, pad(b, CW - 2), C.text, C.card)
	local price = unitText(e)
	local left = "×" .. num(e.size)
	text(x + 1, y + 11, pad(price, CW - 2), C.gold, C.card)
	local room = CW - 2 - unicode.len(price) - 1
	if room >= 2 then text(x + CW - 1 - min(room, unicode.len(left)), y + 11, clip(left, room), C.dim, C.card) end
end

local function drawHeader()
	fill(1, 1, W, 3, C.panel)
	if view.screen ~= "idle" then text(3, 2, TITLE, C.gold, C.panel) end
	if not nick then return end
	local bx = W - 17
	button(bx, 1, 17, 3, "ПОПОЛНИТЬ", C.black, C.green)
	hit(bx, 1, 17, 3, function() shop.deposit() end)
	local bal = money(balance)
	local x = bx - 2 - unicode.len(bal)
	text(x, 2, bal, C.gold, C.panel)
	text(x, 1, "счёт", C.dim, C.panel)
	local who = nick
	text(x - 3 - unicode.len(who), 2, who, C.text, C.panel)
	text(x - 3 - unicode.len(who), 1, "игрок", C.dim, C.panel)
end

local function footerText()
	if toast.text and computer.uptime() < toast.till then return toast.text, toast.colour end
	if not nick then return "", C.dim end
	return "Пополнение: положите монеты в инвентарь и нажмите «ПОПОЛНИТЬ»", C.dim
end

local pages = 1

local function drawFooter()
	fill(1, H, W, 1, C.panel)
	local s, col = footerText()
	text(3, H, clip(s, W - 30), col, C.panel)
	if view.screen == "grid" and pages > 1 then
		local label = ("%d / %d"):format(view.page, pages)
		local x = W - 4 - unicode.len(label) - 6
		text(x, H, " ◀ ", view.page > 1 and C.text or C.faint, C.line)
		text(x + 4, H, label, C.text, C.panel)
		text(x + 5 + unicode.len(label), H, " ▶ ", view.page < pages and C.text or C.faint, C.line)
		hit(x, H, 3, 1, function() shop.turn(-1) end)
		hit(x + 5 + unicode.len(label), H, 3, 1, function() shop.turn(1) end)
	end
end

local SW = 30             -- ширина боковой панели

local function drawSide()
	fill(1, 4, SW, H - 4, C.panel)
	-- поиск
	fill(2, 5, SW - 2, 1, C.card)
	if view.query == "" then
		text(3, 5, "поиск: печатайте название", C.faint, C.card)
	else
		text(3, 5, clip(view.query, SW - 7) .. "_", C.text, C.card)
		text(SW - 2, 5, "×", C.red, C.card)
		hit(SW - 3, 5, 3, 1, function() view.query = "" view.page = 1 shop.draw() end)
	end
	text(3, 7, "РАЗДЕЛЫ", C.dim, C.panel)
	local rows = { { id = nil, name = "Все товары", n = #stock } }
	for i = 1, #sections do rows[#rows + 1] = sections[i] end
	local top, room = 9, H - 10
	if view.sideTop > max(1, #rows - room + 1) then view.sideTop = max(1, #rows - room + 1) end
	for i = view.sideTop, min(#rows, view.sideTop + room - 1) do
		local r = rows[i]
		local y = top + i - view.sideTop
		local on = r.id == view.section
		local back = on and C.blue or C.panel
		local n = num(r.n)
		fill(1, y, SW, 1, back)
		text(3, y, pad(r.name, SW - 5 - #n), on and C.text or C.dim, back)
		text(SW - 1 - #n, y, n, on and C.text or C.faint, back)
		hit(1, y, SW, 1, function()
			view.section, view.page = r.id, 1
			shop.draw()
		end)
	end
	if #rows > room then
		text(SW - 1, 7, view.sideTop > 1 and "▲" or " ", C.dim, C.panel)
		text(SW - 1, H - 1, view.sideTop + room - 1 < #rows and "▼" or " ", C.dim, C.panel)
		hit(SW - 3, 7, 4, 1, function() view.sideTop = max(1, view.sideTop - room) shop.draw() end)
		hit(SW - 3, H - 1, 4, 1, function() view.sideTop = view.sideTop + room shop.draw() end)
	end
end

local function drawGrid()
	choose()
	local gx, gy = SW + 3, 7
	local cols = max(1, floor((W - gx + 1 + 1) / (CW + 1)))
	local rows = max(1, floor((H - 1 - gy + 1 + 1) / (CH + 1)))
	local per = cols * rows
	pages = max(1, ceil(#shown / per))
	if view.page > pages then view.page = pages end
	if view.page < 1 then view.page = 1 end

	fill(SW + 1, 4, W - SW, H - 4, C.bg)
	local head = view.section and modName(view.section) or "Все товары"
	if view.query ~= "" then head = head .. " · «" .. view.query .. "»" end
	text(gx, 5, clip(head, 60), C.text, C.bg)
	text(gx + min(60, unicode.len(head)) + 2, 5, num(#shown) .. " шт.", C.faint, C.bg)

	-- сортировка
	local sorts = { { "name", " А-Я " }, { "cheap", " дешевле " }, { "dear", " дороже " } }
	local x = W - 1
	for i = #sorts, 1, -1 do
		local id, label = sorts[i][1], sorts[i][2]
		x = x - unicode.len(label)
		local on = view.sort == id
		text(x, 5, label, on and C.text or C.dim, on and C.blue or C.panel)
		hit(x, 5, unicode.len(label), 1, function()
			view.sort, view.page = id, 1
			shop.draw()
		end)
		x = x - 1
	end

	if #shown == 0 then
		local msg = stockErr or (view.query ~= "" and "ничего не нашлось" or "в разделе пусто")
		text(gx, gy + 2, msg, C.dim, C.bg)
		return
	end

	local first = (view.page - 1) * per
	for n = 1, per do
		local e = shown[first + n]
		if not e then break end
		local cx = gx + ((n - 1) % cols) * (CW + 1)
		local cy = gy + floor((n - 1) / cols) * (CH + 1)
		drawCard(e, cx, cy)
		hit(cx, cy, CW, CH, function() shop.open(e) end)
	end
end

-- ------------------------------------------------------------------ товар

--- Сколько можно купить разом: хватает денег, есть в МЭ и влезет в
--- свободные слоты (по 64 - сколько на самом деле держит стопка, PIM про
--- предмет в МЭ не скажет; лишнее всё равно вернётся деньгами).
local function maxQty(e)
	local afford = floor(balance / e.unit)
	while afford > 0 and totalOf(e, afford) > balance do afford = afford - 1 end
	return max(0, min(e.size, afford, 64 * store:freeSlots()))
end

local function drawItem()
	local e = view.item
	fill(1, 4, W, H - 4, C.bg)
	button(3, 5, 14, 3, "◀ НАЗАД", C.text, C.line)
	hit(3, 5, 14, 3, function() shop.back() end)

	-- крупная иконка
	local iw, ih = cat.iw * 2, cat.ih * 2
	fill(5, 10, iw + 4, ih + 2, C.card)
	if e.rec.braille then
		-- брайль вдвое не растянуть: рисуем как есть, по центру рамки
		drawIcon(e, 7 + floor(cat.iw / 2), 11 + floor(cat.ih / 2), C.card)
	else
		drawIcon(e, 7, 11, C.card, 2)
	end

	local x = iw + 14
	local wtxt = W - x - 2
	text(x, 10, clip(e.label, wtxt), C.text, C.bg)
	text(x, 11, clip(modName(e.mod) .. "  ·  " .. e.key, wtxt), C.faint, C.bg)

	local col = floor(wtxt / 3)
	text(x, 14, "цена за штуку", C.dim, C.bg)
	text(x, 15, unitText(e), C.gold, C.bg)
	text(x + col, 14, "в наличии", C.dim, C.bg)
	text(x + col, 15, num(e.size) .. " шт.", C.text, C.bg)
	text(x + col * 2, 14, "на счету", C.dim, C.bg)
	text(x + col * 2, 15, money(balance), C.gold, C.bg)

	-- количество
	text(x, 18, "количество", C.dim, C.bg)
	local bx, by = x, 19
	local function step(label, d)
		button(bx, by, 7, 3, label, C.text, C.line)
		hit(bx, by, 7, 3, function() shop.setQty(view.qty + d) end)
		bx = bx + 8
	end
	step("-64", -64) step("-10", -10) step("-1", -1)
	button(bx, by, 14, 3, num(view.qty), C.black, C.text)
	bx = bx + 15
	step("+1", 1) step("+10", 10) step("+64", 64)
	button(bx, by, 9, 3, "МАКС", C.text, C.accent)
	hit(bx, by, 9, 3, function() shop.setQty(maxQty(e)) end)

	-- итог
	local total = totalOf(e, view.qty)
	text(x, 24, "итого", C.dim, C.bg)
	text(x, 25, money(total), C.gold, C.bg)
	local ok = view.qty >= 1 and view.qty <= e.size and total <= balance
	if total > balance then
		text(x, 26, "не хватает " .. money(total - balance) .. " - пополните счёт", C.red, C.bg)
	elseif view.qty > e.size then
		text(x, 26, "в наличии только " .. num(e.size) .. " шт.", C.red, C.bg)
	else
		text(x, 26, "останется " .. money(balance - total), C.dim, C.bg)
	end

	button(x, 29, 32, 5, "КУПИТЬ", ok and C.black or C.faint, ok and C.green or C.card)
	if ok then hit(x, 29, 32, 5, function() shop.buy() end) end
end

-- ------------------------------------------------------------------ ожидание

local teaser = {}

local function pickTeaser()
	teaser = {}
	local pool = {}
	for i = 1, #stock do if stock[i].rec.icon ~= 0 then pool[#pool + 1] = stock[i] end end
	for _ = 1, min(6, #pool) do
		local i = math.random(#pool)
		teaser[#teaser + 1] = table.remove(pool, i)
	end
end

local function drawIdle()
	fill(1, 4, W, H - 4, C.bg)
	local cy = floor(H / 2) - 12
	local title = unicode.upper(TITLE)
	local spaced = {}
	for i = 1, unicode.len(title) do spaced[#spaced + 1] = unicode.sub(title, i, i) end
	local t = table.concat(spaced, " ")
	fill(1, cy, W, 5, C.panel)
	text(floor((W - unicode.len(t)) / 2) + 1, cy + 2, t, C.gold, C.panel)
	local msg = "Встаньте на PIM, чтобы войти"
	text(floor((W - unicode.len(msg)) / 2) + 1, cy + 7, msg, C.text, C.bg)
	local sub = "оплата монетами " .. COIN.id
	text(floor((W - unicode.len(sub)) / 2) + 1, cy + 8, sub, C.faint, C.bg)

	if stockErr then
		text(floor((W - unicode.len(stockErr)) / 2) + 1, cy + 11, stockErr, C.red, C.bg)
	elseif #teaser > 0 then
		local n = #teaser
		local x0 = floor((W - (n * (CW + 1) - 1)) / 2) + 1
		for i = 1, n do drawCard(teaser[i], x0 + (i - 1) * (CW + 1), cy + 11) end
		local s = "в наличии " .. num(#stock) .. " товаров"
		text(floor((W - unicode.len(s)) / 2) + 1, cy + 11 + CH + 1, s, C.dim, C.bg)
	end
end

-- ------------------------------------------------------------------ отрисовка

function shop.draw()
	hits = {}
	gfx.begin()
	drawHeader()
	if view.screen == "idle" then drawIdle()
	elseif view.screen == "item" then drawItem()
	else
		drawSide()
		drawGrid()
	end
	drawFooter()
	gfx.show()
end

--- Сообщение в подвале. Весь кадр ради строки не перерисовывается.
function shop.say(s, colour, secs)
	if view.screen == "idle" and s then return end
	toast.text, toast.colour = s, colour or C.text
	toast.till = computer.uptime() + (secs or 6)
	gfx.begin()
	local keep = {}
	for i = 1, #hits do if hits[i][2] ~= H then keep[#keep + 1] = hits[i] end end
	hits = keep
	drawFooter()
	gfx.show(1, H, W, 1)
end

-- ------------------------------------------------------------------ действия

function shop.turn(d)
	local p = view.page + d
	if p >= 1 and p <= pages then
		view.page = p
		shop.draw()
	end
end

function shop.open(e)
	view.screen, view.item, view.qty = "item", e, 1
	shop.draw()
end

function shop.back()
	view.screen, view.item = "grid", nil
	shop.draw()
end

function shop.setQty(n)
	local e = view.item
	if not e then return end
	view.qty = max(1, min(floor(n), max(1, e.size)))
	shop.draw()
end

function shop.deposit()
	if not nick then return end
	shop.say("принимаю монеты…", C.dim)
	local coins = store:takeAll(COIN.id, COIN.dmg or 0)
	if coins <= 0 then
		shop.say("в инвентаре нет монет " .. COIN.id, C.red)
		return
	end
	local cents = coins * COIN_VALUE * 100
	balance = wallet.add(nick, cents) or wallet.get(nick)
	wallet.log(("%s +%d монет (%s), счёт %s"):format(nick, coins, wallet.format(cents), wallet.format(balance)))
	toast.text, toast.colour, toast.till = ("зачислено %s монет: +%s"):format(num(coins), money(cents)),
		C.green, computer.uptime() + 8
	shop.draw()
end

function shop.buy()
	local e = view.item
	if not (e and nick) then return end
	local qty = view.qty
	local cost = totalOf(e, qty)
	balance = wallet.get(nick)
	if cost > balance then shop.draw() return end
	if store:freeSlots() == 0 then
		shop.say("инвентарь полон - освободите место", C.red)
		return
	end
	-- сначала списать и записать на диск, потом выдавать: выключение посреди
	-- выдачи не должно оставить предмет бесплатным
	local left = wallet.add(nick, -cost)
	if not left then shop.say("не удалось списать деньги", C.red) return end
	balance = left
	shop.say("выдаю…", C.dim)
	local sent = store:give(e.id, e.dmg, qty)
	local paid = totalOf(e, sent)
	if paid < cost then balance = wallet.add(nick, cost - paid) or wallet.get(nick) end
	wallet.log(("%s купил %s x%d/%d за %s, счёт %s"):format(
		nick, e.key, sent, qty, wallet.format(paid), wallet.format(balance)))

	refresh()
	local now = findStock(e.key)
	if now then
		view.item = now
		view.qty = max(1, min(view.qty, now.size))
	else
		view.screen, view.item = "grid", nil
	end
	if sent == 0 then
		toast.text, toast.colour = "не выдано: нет места или товар кончился, деньги возвращены", C.red
	elseif sent < qty then
		toast.text, toast.colour = ("выдано %d из %d - на остальное не хватило места, разница возвращена")
			:format(sent, qty), C.gold
	else
		toast.text, toast.colour = ("куплено: %s × %s за %s"):format(e.label, num(sent), money(paid)), C.green
	end
	toast.till = computer.uptime() + 8
	shop.draw()
end

-- ------------------------------------------------------------------ вход

local function login(name)
	if not name or name == nick then return end
	nick = name
	balance = wallet.get(nick)
	view.screen, view.section, view.query, view.page, view.item = "grid", nil, "", 1, nil
	toast.text = nil
	wallet.log(nick .. " вошёл, счёт " .. wallet.format(balance))
	refresh()
	shop.draw()
end

local function logout()
	if nick then wallet.log(nick .. " вышел") end
	nick, balance = nil, 0
	view.screen, view.item, view.query = "idle", nil, ""
	toast.text = nil
	pickTeaser()
	shop.draw()
end

--- Ник из сигнала PIM: первый аргумент, похожий на ник Minecraft. Адрес
--- компонента и uuid под это не подходят - в них есть дефисы.
local function nickFrom(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if type(v) == "string" and #v >= 2 and #v <= 16 and v:match("^[%w_]+$") and v ~= "pim" then
			return v
		end
	end
end

--- Кто стоит на PIM прямо сейчас - на случай перезапуска посреди сессии.
local function standing()
	local pim = component.pim
	if not pim or not pim.getInventoryName then return nil end
	local ok, name = pcall(pim.getInventoryName)
	if ok then return nickFrom(name) end
end

-- ------------------------------------------------------------------ цикл

local function click(x, y)
	for i = #hits, 1, -1 do
		local h = hits[i]
		if x >= h[1] and x <= h[3] and y >= h[2] and y <= h[4] then
			h[5]()
			return
		end
	end
end

local handlers = {}

function handlers.player_on(...) login(nickFrom(...)) end
function handlers.player_off() logout() end

function handlers.touch(_, x, y, _, who)
	if nick and who and who ~= nick then
		shop.say(who .. ", магазин занят: сейчас обслуживается " .. nick, C.red, 4)
		return
	end
	if nick then click(floor(x), floor(y)) end
end

function handlers.scroll(_, x, _, dir, who)
	if not nick or (who and who ~= nick) or view.screen ~= "grid" then return end
	if x <= SW then
		view.sideTop = max(1, view.sideTop - dir)
		shop.draw()
	else
		shop.turn(dir > 0 and -1 or 1)
	end
end

function handlers.key_down(_, ch, code, who)
	if not nick or (who and who ~= nick) then return end
	if view.screen == "item" then
		if code == 1 or code == 14 then shop.back() end
		return
	end
	if view.screen ~= "grid" then return end
	if code == 14 then
		if view.query ~= "" then
			view.query = unicode.sub(view.query, 1, -2)
			view.page = 1
			shop.draw()
		end
	elseif code == 1 then
		view.query, view.page = "", 1
		shop.draw()
	elseif code == 201 then shop.turn(-1)
	elseif code == 209 then shop.turn(1)
	elseif ch and ch >= 32 and unicode.len(view.query) < 24 then
		view.query = view.query .. unicode.char(ch)
		view.page = 1
		shop.draw()
	end
end

function shop.run()
	math.randomseed(floor(computer.uptime() * 1000))
	refresh()
	pickTeaser()
	local who = standing()
	if who then login(who) else shop.draw() end

	local every = nick and 30 or 60
	local nextScan = computer.uptime() + every
	while true do
		local now = computer.uptime()
		local wake = nextScan
		if toast.text and toast.till < wake then wake = toast.till end
		local sig = table.pack(computer.pullSignal(max(0.05, wake - now)))
		local h = sig[1] and handlers[sig[1]]
		if h then h(table.unpack(sig, 2, sig.n)) end

		now = computer.uptime()
		if toast.text and now >= toast.till then shop.say(nil) end
		if now >= nextScan then
			-- пока игрок выбирает количество, витрину под ним не трогаем
			if view.screen ~= "item" then
				refresh()
				if view.screen == "idle" then pickTeaser() end
				shop.draw()
			end
			nextScan = now + (nick and 30 or 60)
		end
	end
end

return shop
