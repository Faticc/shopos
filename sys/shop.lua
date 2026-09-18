-- shop - магазин: витрина из МЭ, цены из выгрузки, счёт монетами.
--
-- Как это работает для игрока:
--   1. встал на PIM - магазин узнал ник и показал его счёт;
--   2. положил в инвентарь монеты customnpcs:npcMoney и нажал «ПОПОЛНИТЬ» -
--      монеты ушли в МЭ, на счёт легла их стоимость;
--   3. нашёл предмет поиском или во вкладке мода, выбрал количество,
--      «КУПИТЬ» - предмет пришёл из МЭ в инвентарь, со счёта списана цена;
--   4. «СНЯТЬ» - деньги со счёта возвращаются монетами из МЭ.
--
-- Экран устроен как поиск картинок: сверху строка поиска, под ней вкладки
-- модов с числом найденного, ниже сетка карточек во всю ширину.
--
-- Деньги трогают три операции, и у всех один порядок: проверить, кто стоит
-- на PIM, записать изменение счёта на диск, двигать предметы, недоданное
-- вернуть на счёт. Пополнение зачисляет не то, что ушло из инвентаря, а то,
-- на сколько выросло число монет в МЭ.

local computer, unicode = computer, unicode
local root = require("root")
local gfx = require("gfx")
local catalog = require("catalog")
local storage = require("storage")
local wallet = require("wallet")

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local fill, text, pad, clip, button = gfx.fill, gfx.text, gfx.pad, gfx.clip, gfx.button
local ulen = unicode.len

local shop = {}

-- ------------------------------------------------------------------ настройки

local cfg = root:table("/cfg/shop.cfg") or {}
local TITLE = cfg.title or "SHOP"
-- конфиг от прежнего ShopOS давал валюту списком номиналов: берём первый
local COIN = cfg.currency or {}
if COIN[1] then COIN = COIN[1] end
if not COIN.id then COIN = { id = "customnpcs:npcMoney", dmg = 0 } end
COIN.dmg = COIN.dmg or 0
local COIN_VALUE = cfg.coinValue or COIN.value or 1   -- монет счёта за штуку
local RATE = (cfg.rate or 1) * (cfg.markup or 1)      -- монет за единицу цены
local MODS = cfg.modNames or {}
local SIGN = cfg.sign or "$"

local W, H = gfx.W, gfx.H

-- цвета из палитры монитора 3-го уровня: чужие он всё равно округлит
local C = {
	bg     = 0x0F0F0F,
	panel  = 0x1E1E1E,
	card   = 0x2D2D2D,
	line   = 0x3C3C3C,
	field  = 0x4B4B4B,
	text   = 0xE1E1E1,
	white  = 0xFFFFFF,
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
local coinsInMe = 0       -- монет в МЭ: столько можно снять
local view = {
	screen = "idle",       -- idle | grid | item | cash
	tab = nil,             -- мод или nil - все
	tabTop = 1,            -- первая видимая вкладка
	query = "",
	sort = "name",         -- name | cheap | dear
	page = 1,
	item = nil,
	qty = 1,
}
local shown, tabs = {}, {}
local hits = {}           -- кликабельные области кадра
local toast = { text = nil, colour = C.dim, till = 0 }
local pages = 1

-- ------------------------------------------------------------------ деньги

--- Цена штуки в сотых монеты, дробная: дешёвое стоит доли сотой, и
--- округляется только итог.
local function unitOf(rec) return rec.price * RATE * 100 end

--- Итог в сотых: вверх, но хвост меньше 0.05 сотой не считается. Вверх -
--- чтобы покупка по одной не давала скидку на округлении (штука за 0.014
--- иначе стоила бы 0.01). Допуск - чтобы кирка за 1.50028 стоила 1.50.
local function totalOf(e, n)
	if n <= 0 then return 0 end
	return max(1, ceil(n * e.unit - 0.05))
end

local function money(cents) return wallet.format(cents) .. " " .. SIGN end

--- Цена за штуку для витрины: то, что спишется за одну. Дешевле сотой -
--- столько знаков, чтобы стало видно цифру: земля 0.00004, а не 0.00.
local function unitText(e)
	local u = e.unit / 100
	if u >= 0.01 then return money(totalOf(e, 1)) end
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

--- Перечитать МЭ: что есть и почём.
local function refresh()
	if not cat then
		stock, stockErr = {}, "каталог цен не загружен: " .. tostring(catErr)
		return
	end
	local items, err = store:scan()
	if not items then
		stock, stockErr = {}, err
		return
	end
	local keys = {}
	for i = 1, #items do
		items[i].key = catalog.key(items[i].id, items[i].dmg)
		keys[i] = items[i].key
	end
	cat:resolve(keys)
	local out, coins = {}, 0
	for i = 1, #items do
		local it = items[i]
		if it.id == COIN.id and it.dmg == COIN.dmg then
			coins = coins + it.size
		else
			local rec = cat:get(it.key)
			if rec and rec.price > 0 then
				it.rec, it.unit = rec, unitOf(rec)
				it.label = rec.label ~= "" and rec.label or it.key
				it.low = unicode.lower(it.label)
				it.mod = modOf(it.id)
				out[#out + 1] = it
			end
		end
	end
	stock, coinsInMe, stockErr = out, coins, nil
	if #out == 0 then stockErr = "в МЭ нет товаров с ценой" end
end

--- Выборка: поиск по всему складу, по найденному - вкладки модов с
--- числами, потом отбор по открытой вкладке и сортировка.
local function choose()
	local q = unicode.lower(view.query)
	local found, per = {}, {}
	for i = 1, #stock do
		local e = stock[i]
		if q == "" or e.low:find(q, 1, true) then
			found[#found + 1] = e
			per[e.mod] = (per[e.mod] or 0) + 1
		end
	end
	tabs = { { id = nil, name = "Все", n = #found } }
	local list = {}
	for m, n in pairs(per) do list[#list + 1] = { id = m, name = modName(m), n = n } end
	-- самые наполненные моды впереди: их и ищут
	table.sort(list, function(a, b)
		if a.n ~= b.n then return a.n > b.n end
		return unicode.lower(a.name) < unicode.lower(b.name)
	end)
	for i = 1, #list do tabs[#tabs + 1] = list[i] end
	-- открытый мод в выдаче не нашёлся - вкладка остаётся, но пустая
	if view.tab and not per[view.tab] then
		tabs[#tabs + 1] = { id = view.tab, name = modName(view.tab), n = 0 }
	end

	local out = {}
	for i = 1, #found do
		if not view.tab or found[i].mod == view.tab then out[#out + 1] = found[i] end
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

local function drawIcon(e, x, y, back, scale)
	local cells = cat and cat:cells(e.rec)
	local w, h = cat.iw * (scale or 1), cat.ih * (scale or 1)
	if cells then
		gfx.icon(cells, e.rec.braille and 1 or 0, cat.iw, cat.ih, x, y, back, scale)
	else
		fill(x, y, w, h, back)
		text(x + floor((w - 1) / 2), y + floor(h / 2), "?", C.faint, back)
	end
end

-- Карточка подстраивается под размер иконок каталога: 32x32 во всю ширину
-- карточки, 16x16 - с полями по бокам.
local IW, IH = cat and cat.iw or 16, cat and cat.ih or 8
local CW = IW >= 32 and IW or IW + 4
local CH = IH + 3         -- иконка с полем сверху, название, цена и мод
local GAP = 3

--- Карточка как в поиске картинок: картинка, на ней плашка с количеством,
--- под ней название, ниже цена и откуда предмет.
local function drawCard(e, x, y)
	fill(x, y, CW, CH, C.card)
	drawIcon(e, x + floor((CW - IW) / 2), y + 1, C.card)
	local badge = " " .. num(e.size) .. " шт "
	text(x + CW - ulen(badge), y + IH, badge, C.white, C.bg)
	text(x + 1, y + IH + 1, pad(e.label, CW - 2), C.text, C.card)
	local price = unitText(e)
	local room = CW - 3 - ulen(price)
	text(x + 1, y + IH + 2, price, C.gold, C.card)
	if room >= 3 then
		text(x + CW - 1 - min(room, ulen(modName(e.mod))), y + IH + 2, clip(modName(e.mod), room), C.faint, C.card)
	end
end

-- ------------------------------------------------------------------ шапка

local SX = #TITLE + 6     -- где начинается строка поиска

local function drawSearch(x, w)
	fill(x, 1, w, 3, C.field)
	-- клик по строке с любого экрана ведёт к выдаче; крестик добавлен
	-- позже и потому перекрывает её (клик ищется с конца)
	hit(x, 1, w, 3, function() if view.screen ~= "grid" then shop.back() end end)
	text(x + 2, 2, "⌕", C.white, C.field)
	if view.query == "" then
		text(x + 5, 2, clip("Найти предмет - просто печатайте", w - 8), C.dim, C.field)
	else
		text(x + 5, 2, clip(view.query, w - 12) .. "▏", C.white, C.field)
		text(x + w - 4, 2, "×", C.white, C.field)
		hit(x + w - 6, 1, 6, 3, function() shop.search("") end)
	end
end

local function drawHeader()
	fill(1, 1, W, 3, C.panel)
	if view.screen == "idle" then return end    -- там название крупно
	text(3, 2, TITLE, C.gold, C.panel)
	if not nick then return end
	-- справа налево: ПОПОЛНИТЬ, СНЯТЬ, счёт, ник
	local bx = W - 14
	button(bx, 1, 15, 3, "ПОПОЛНИТЬ", C.black, C.green)
	hit(bx, 1, 15, 3, function() shop.deposit() end)
	bx = bx - 10
	button(bx, 1, 9, 3, "СНЯТЬ", C.text, C.line)
	hit(bx, 1, 9, 3, function() shop.openCash() end)
	local bal = money(balance)
	local x = bx - 2 - max(ulen(bal), 4)
	text(x, 1, "счёт", C.dim, C.panel)
	text(x, 2, bal, C.gold, C.panel)
	local nx = x - 2 - max(ulen(nick), 5)
	text(nx, 1, "игрок", C.dim, C.panel)
	text(nx, 2, nick, C.text, C.panel)
	drawSearch(SX, nx - 3 - SX)
end

local function footerText()
	if toast.text and computer.uptime() < toast.till then return toast.text, toast.colour end
	if cat and cat:missing() then
		return "нет второго диска с " .. cat.path2 .. " - часть иконок не видна", C.red
	end
	if not nick then return "", C.dim end
	return "Пополнение: положите монеты в инвентарь и нажмите «ПОПОЛНИТЬ»", C.dim
end

local function drawFooter()
	fill(1, H, W, 1, C.panel)
	local s, col = footerText()
	text(3, H, clip(s, W - 30), col, C.panel)
	if view.screen == "grid" and pages > 1 then
		local label = ("%d / %d"):format(view.page, pages)
		local x = W - 4 - ulen(label) - 6
		text(x, H, " ◀ ", view.page > 1 and C.text or C.faint, C.line)
		text(x + 4, H, label, C.text, C.panel)
		text(x + 5 + ulen(label), H, " ▶ ", view.page < pages and C.text or C.faint, C.line)
		hit(x, H, 3, 1, function() shop.turn(-1) end)
		hit(x + 5 + ulen(label), H, 3, 1, function() shop.turn(1) end)
	end
end

-- ------------------------------------------------------------------ выдача

--- Вкладки модов под поиском. Не влезают - листаются стрелками по краям.
local function drawTabs(y)
	fill(1, y, W, 2, C.bg)
	local x, left = 3, view.tabTop > 1
	if left then
		text(1, y, "◀", C.text, C.bg)
		hit(1, y, 2, 2, function() view.tabTop = max(1, view.tabTop - 3) shop.draw() end)
	end
	local last = view.tabTop - 1
	for i = view.tabTop, #tabs do
		local t = tabs[i]
		local label = t.name .. " " .. num(t.n)
		local w = ulen(label) + 2
		if x + w > W - 2 then break end
		local on = t.id == view.tab
		text(x + 1, y, t.name, on and C.white or C.dim, C.bg)
		text(x + 2 + ulen(t.name), y, num(t.n), on and C.accent or C.faint, C.bg)
		if on then fill(x, y + 1, w, 1, C.accent) end
		hit(x, y, w, 2, function() shop.setTab(t.id) end)
		x = x + w + 1
		last = i
	end
	if last < #tabs then
		text(W, y, "▶", C.text, C.bg)
		hit(W - 1, y, 2, 2, function() view.tabTop = min(#tabs, view.tabTop + 3) shop.draw() end)
	end
	fill(1, y + 2, W, 1, C.panel)
end

local function drawGrid()
	choose()
	fill(1, 4, W, H - 4, C.bg)
	drawTabs(5)

	-- строка над сеткой: что нашлось и сортировка
	local head
	if view.query ~= "" then
		head = ("Найдено %s по «%s»"):format(num(#shown), view.query)
	else
		head = (view.tab and modName(view.tab) or "Все товары") .. ": " .. num(#shown)
	end
	text(3, 8, clip(head, W - 40), C.text, C.bg)
	local sorts = { { "name", " А-Я " }, { "cheap", " дешевле " }, { "dear", " дороже " } }
	local x = W - 1
	for i = #sorts, 1, -1 do
		local id, label = sorts[i][1], sorts[i][2]
		x = x - ulen(label)
		local on = view.sort == id
		text(x, 8, label, on and C.white or C.dim, on and C.blue or C.panel)
		hit(x, 8, ulen(label), 1, function()
			view.sort, view.page = id, 1
			shop.draw()
		end)
		x = x - 1
	end

	local gy = 10
	local cols = max(1, floor((W - 2 + GAP) / (CW + GAP)))
	local rows = max(1, floor((H - gy + 1) / (CH + 1)))
	local per = cols * rows
	pages = max(1, ceil(#shown / per))
	if view.page > pages then view.page = pages end
	if view.page < 1 then view.page = 1 end

	if #shown == 0 then
		local msg = stockErr or (view.query ~= "" and ("по «" .. view.query .. "» ничего нет") or "здесь пусто")
		text(floor((W - ulen(msg)) / 2) + 1, gy + 8, msg, C.dim, C.bg)
		return
	end

	local gx = floor((W - (cols * (CW + GAP) - GAP)) / 2) + 1
	local first = (view.page - 1) * per
	for n = 1, per do
		local e = shown[first + n]
		if not e then break end
		local cx = gx + ((n - 1) % cols) * (CW + GAP)
		local cy = gy + floor((n - 1) / cols) * (CH + 1)
		drawCard(e, cx, cy)
		hit(cx, cy, CW, CH, function() shop.open(e) end)
	end
end

-- ------------------------------------------------------------------ количество

--- Выбор количества: шаги вниз, число, шаги вверх и «МАКС».
local function drawAmount(x, y, value, steps, set, maxFn)
	local bx = x
	for i = #steps, 1, -1 do
		local d = steps[i]
		button(bx, y, 7, 3, "-" .. d, C.text, C.line)
		hit(bx, y, 7, 3, function() set(value - d) end)
		bx = bx + 8
	end
	button(bx, y, 14, 3, num(value), C.black, C.text)
	bx = bx + 15
	for i = 1, #steps do
		local d = steps[i]
		button(bx, y, 7, 3, "+" .. d, C.text, C.line)
		hit(bx, y, 7, 3, function() set(value + d) end)
		bx = bx + 8
	end
	button(bx, y, 9, 3, "МАКС", C.text, C.accent)
	hit(bx, y, 9, 3, function() set(maxFn()) end)
end

local function backButton()
	button(3, 5, 14, 3, "◀ НАЗАД", C.text, C.line)
	hit(3, 5, 14, 3, function() shop.back() end)
end

-- ------------------------------------------------------------------ товар

--- Сколько можно купить разом: хватает денег, есть в МЭ и влезет в
--- свободные слоты (по 64: сколько держит стопка, PIM про предмет в МЭ не
--- скажет; лишнее всё равно вернётся деньгами).
local function maxQty(e)
	local afford = floor(balance / e.unit)
	while afford > 0 and totalOf(e, afford) > balance do afford = afford - 1 end
	return max(0, min(e.size, afford, 64 * store:freeSlots()))
end

local function drawItem()
	local e = view.item
	fill(1, 4, W, H - 4, C.bg)
	backButton()

	-- крупная иконка: мелкие растягиваются вдвое, 32x32 и так крупные
	local scale = IW < 24 and 2 or 1
	local iw, ih = IW * scale, IH * scale
	fill(5, 10, iw + 4, ih + 2, C.card)
	if scale == 2 and e.rec.braille then
		drawIcon(e, 7 + floor(IW / 2), 11 + floor(IH / 2), C.card)
	else
		drawIcon(e, 7, 11, C.card, scale)
	end

	local x = iw + 14
	local wtxt = W - x - 2
	text(x, 10, clip(e.label, wtxt), C.white, C.bg)
	text(x, 11, clip(modName(e.mod) .. "  ·  " .. e.key, wtxt), C.faint, C.bg)

	local col = floor(wtxt / 3)
	text(x, 14, "цена за штуку", C.dim, C.bg)
	text(x, 15, unitText(e), C.gold, C.bg)
	text(x + col, 14, "в наличии", C.dim, C.bg)
	text(x + col, 15, num(e.size) .. " шт.", C.text, C.bg)
	text(x + col * 2, 14, "на счету", C.dim, C.bg)
	text(x + col * 2, 15, money(balance), C.gold, C.bg)

	text(x, 18, "количество", C.dim, C.bg)
	drawAmount(x, 19, view.qty, { 1, 10, 64 }, shop.setQty, function() return maxQty(e) end)

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

-- ------------------------------------------------------------------ снятие

local function coinCents() return COIN_VALUE * 100 end

--- Сколько монет можно снять: хватает на счету, есть в МЭ, влезет.
local function maxCash()
	return max(0, min(floor(balance / coinCents()), coinsInMe, 64 * store:freeSlots()))
end

local function drawCash()
	fill(1, 4, W, H - 4, C.bg)
	backButton()
	local x = 22
	text(x, 10, "Снять деньги со счёта", C.white, C.bg)
	text(x, 11, "выдаются монетами " .. COIN.id .. ", одна монета - " .. money(coinCents()), C.faint, C.bg)

	text(x, 14, "на счету", C.dim, C.bg)
	text(x, 15, money(balance), C.gold, C.bg)
	text(x + 30, 14, "монет в магазине", C.dim, C.bg)
	text(x + 30, 15, num(coinsInMe), C.text, C.bg)

	text(x, 18, "сколько монет", C.dim, C.bg)
	drawAmount(x, 19, view.qty, { 1, 10, 64, 640 }, shop.setCash, maxCash)

	local cost = view.qty * coinCents()
	text(x, 24, "спишется", C.dim, C.bg)
	text(x, 25, money(cost), C.gold, C.bg)
	local ok = view.qty >= 1 and cost <= balance and view.qty <= coinsInMe
	if cost > balance then
		text(x, 26, "на счету столько нет", C.red, C.bg)
	elseif view.qty > coinsInMe then
		text(x, 26, "в магазине только " .. num(coinsInMe) .. " монет", C.red, C.bg)
	else
		text(x, 26, "останется " .. money(balance - cost), C.dim, C.bg)
	end
	button(x, 29, 32, 5, "СНЯТЬ", ok and C.black or C.faint, ok and C.green or C.card)
	if ok then hit(x, 29, 32, 5, function() shop.withdraw() end) end
end

-- ------------------------------------------------------------------ ожидание

local teaser = {}

local function pickTeaser()
	teaser = {}
	local pool = {}
	for i = 1, #stock do if stock[i].rec.icon ~= 0 then pool[#pool + 1] = stock[i] end end
	for _ = 1, min(6, floor((W + GAP) / (CW + GAP)), #pool) do
		teaser[#teaser + 1] = table.remove(pool, math.random(#pool))
	end
end

local function drawIdle()
	fill(1, 4, W, H - 4, C.bg)
	local cy = floor(H / 2) - 13
	local title = unicode.upper(TITLE)
	local spaced = {}
	for i = 1, ulen(title) do spaced[#spaced + 1] = unicode.sub(title, i, i) end
	local t = table.concat(spaced, " ")
	fill(1, cy, W, 5, C.panel)
	text(floor((W - ulen(t)) / 2) + 1, cy + 2, t, C.gold, C.panel)
	local msg = "Встаньте на PIM, чтобы войти"
	text(floor((W - ulen(msg)) / 2) + 1, cy + 7, msg, C.text, C.bg)
	local sub = "оплата монетами " .. COIN.id
	text(floor((W - ulen(sub)) / 2) + 1, cy + 8, sub, C.faint, C.bg)

	if stockErr then
		text(floor((W - ulen(stockErr)) / 2) + 1, cy + 11, stockErr, C.red, C.bg)
	elseif #teaser > 0 then
		local n = #teaser
		local x0 = floor((W - (n * (CW + GAP) - GAP)) / 2) + 1
		for i = 1, n do drawCard(teaser[i], x0 + (i - 1) * (CW + GAP), cy + 11) end
		local s = "в наличии " .. num(#stock) .. " товаров"
		text(floor((W - ulen(s)) / 2) + 1, cy + 11 + CH + 1, s, C.dim, C.bg)
	end
end

-- ------------------------------------------------------------------ отрисовка

function shop.draw()
	hits = {}
	gfx.begin()
	if view.screen == "idle" then drawIdle()
	elseif view.screen == "item" then drawItem()
	elseif view.screen == "cash" then drawCash()
	else drawGrid() end
	-- шапка последней: её кнопки поверх всего остального
	drawHeader()
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

local function note(s, colour)
	toast.text, toast.colour, toast.till = s, colour, computer.uptime() + 8
end

-- ------------------------------------------------------------------ действия

function shop.turn(d)
	local p = view.page + d
	if p >= 1 and p <= pages then
		view.page = p
		shop.draw()
	end
end

function shop.setTab(id)
	view.tab, view.page = id, 1
	shop.draw()
end

function shop.search(q)
	view.query, view.page, view.screen, view.item = q, 1, "grid", nil
	shop.draw()
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

function shop.openCash()
	balance = wallet.get(nick)
	refresh()
	view.screen, view.item, view.qty = "cash", nil, 1
	shop.draw()
end

function shop.setCash(n)
	view.qty = max(1, floor(n))
	shop.draw()
end

-- ------------------------------------------------------------------ вход

--- Кто стоит на PIM: ник, false - никто, nil - PIM не говорит.
local function occupant()
	local pim = component.pim
	if not pim or not pim.getInventoryName then return nil end
	local ok, name = pcall(pim.getInventoryName)
	if not ok or type(name) ~= "string" then return nil end
	if name == "" or name == "pim" then return false end
	return name
end

local logout

--- Перед любой операцией с деньгами: на PIM всё ещё тот, чей счёт открыт.
--- Сигнал ухода мог потеряться, и тогда покупку получил бы следующий.
local function present()
	local who = occupant()
	if who == nil or who == nick then return true end
	logout()
	return false
end

function shop.deposit()
	if not nick or not present() then return end
	shop.say("принимаю монеты…", C.dim)
	local before = store:count(COIN.id, COIN.dmg)
	if not before then shop.say("МЭ не отвечает, попробуйте ещё раз", C.red) return end
	local pushed = store:takeAll(COIN.id, COIN.dmg)
	if pushed <= 0 then
		shop.say("в инвентаре нет монет " .. COIN.id, C.red)
		return
	end
	-- зачисляем то, что пришло в МЭ, а не то, что ушло из слотов: между
	-- проверкой слота и сталкиванием игрок может подложить другой стак
	local after = store:count(COIN.id, COIN.dmg)
	local coins = after and min(pushed, max(0, after - before)) or pushed
	if coins < pushed then
		wallet.log(("%s: ушло из инвентаря %d, монет в МЭ прибавилось %d - зачислено %d")
			:format(nick, pushed, after - before, coins))
	end
	if coins <= 0 then
		note("монеты не дошли до МЭ - ничего не зачислено", C.red)
		refresh()
		shop.draw()
		return
	end
	local cents = coins * coinCents()
	balance = wallet.add(nick, cents) or wallet.get(nick)
	wallet.log(("%s +%d монет (%s), счёт %s"):format(nick, coins, wallet.format(cents), wallet.format(balance)))
	note(("зачислено %s монет: +%s"):format(num(coins), money(cents)), C.green)
	refresh()
	shop.draw()
end

function shop.buy()
	local e = view.item
	if not (e and nick) or not present() then return end
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
		note("не выдано: нет места или товар кончился, деньги возвращены", C.red)
	elseif sent < qty then
		note(("выдано %d из %d - на остальное не хватило места, разница возвращена"):format(sent, qty), C.gold)
	else
		note(("куплено: %s × %s за %s"):format(e.label, num(sent), money(paid)), C.green)
	end
	shop.draw()
end

function shop.withdraw()
	if not nick or not present() then return end
	local n = view.qty
	local cost = n * coinCents()
	balance = wallet.get(nick)
	if n < 1 or cost > balance then shop.draw() return end
	if store:freeSlots() == 0 then
		shop.say("инвентарь полон - освободите место", C.red)
		return
	end
	-- тот же порядок, что у покупки: списать, выдать, недоданное вернуть
	local left = wallet.add(nick, -cost)
	if not left then shop.say("не удалось списать деньги", C.red) return end
	balance = left
	shop.say("выдаю монеты…", C.dim)
	local sent = store:give(COIN.id, COIN.dmg, n)
	if sent < n then balance = wallet.add(nick, (n - sent) * coinCents()) or wallet.get(nick) end
	wallet.log(("%s снял %d/%d монет, счёт %s"):format(nick, sent, n, wallet.format(balance)))
	refresh()
	view.qty = max(1, min(view.qty, maxCash()))
	if sent == 0 then
		note("монеты не выданы: нет места или в магазине кончились, деньги на счету", C.red)
	elseif sent < n then
		note(("выдано %d из %d монет, остальное осталось на счету"):format(sent, n), C.gold)
	else
		note(("выдано %s монет, со счёта %s"):format(num(sent), money(sent * coinCents())), C.green)
	end
	shop.draw()
end

local function login(name)
	if not name or name == nick then return end
	nick = name
	balance = wallet.get(nick)
	view.screen, view.tab, view.tabTop, view.query, view.page, view.item = "grid", nil, 1, "", 1, nil
	toast.text = nil
	wallet.log(nick .. " вошёл, счёт " .. wallet.format(balance))
	refresh()
	shop.draw()
end

function logout()
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

function handlers.scroll(_, _, y, dir, who)
	if not nick or (who and who ~= nick) or view.screen ~= "grid" then return end
	if y >= 5 and y <= 6 then
		view.tabTop = max(1, min(#tabs, view.tabTop - dir))
		shop.draw()
	else
		shop.turn(dir > 0 and -1 or 1)
	end
end

--- Печатать можно с любого экрана: буквы сразу идут в поиск.
function handlers.key_down(_, ch, code, who)
	if not nick or (who and who ~= nick) or view.screen == "idle" then return end
	if code == 14 then                                     -- Backspace
		if view.screen ~= "grid" then shop.back()
		elseif view.query ~= "" then shop.search(unicode.sub(view.query, 1, -2)) end
	elseif code == 1 then                                  -- Esc
		if view.screen ~= "grid" then shop.back() else shop.search("") end
	elseif code == 201 then shop.turn(-1)                  -- PgUp
	elseif code == 209 then shop.turn(1)                   -- PgDn
	elseif ch and ch >= 32 and ulen(view.query) < 24 then
		shop.search(view.query .. unicode.char(ch))
	end
end

function shop.run()
	math.randomseed(floor(computer.uptime() * 1000))
	refresh()
	pickTeaser()
	local who = occupant()
	if who then login(who) else shop.draw() end

	local nextScan = computer.uptime() + (nick and 30 or 60)
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
			-- пока игрок выбирает количество, выдачу под ним не трогаем
			if view.screen == "grid" or view.screen == "idle" then
				refresh()
				if view.screen == "idle" then pickTeaser() end
				shop.draw()
			end
			nextScan = now + (nick and 30 or 60)
		end
	end
end

return shop
