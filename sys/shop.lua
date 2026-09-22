-- shop - магазин: витрина из МЭ, цены из выгрузки, два счёта.
--
-- Как это работает для игрока:
--   1. встал на PIM - магазин узнал ник и показал его счета;
--   2. «ПОПОЛНИТЬ» - монеты customnpcs:npcMoney из инвентаря уходят в МЭ,
--      на денежный счёт ложится их стоимость;
--   3. «СКУПКА» - ресурсы из списка скупки (железо, золото…) уходят в МЭ,
--      на ресурсный счёт ложится их цена из выгрузки по курсу скупки;
--   4. нашёл предмет поиском или во вкладке мода, выбрал количество,
--      «КУПИТЬ ЗА ДЕНЬГИ» или «КУПИТЬ ЗА РЕСУРСЫ» - предмет пришёл из МЭ в
--      инвентарь, с выбранного счёта списана цена. Что-то (иридий) за
--      ресурсы не продаётся;
--   5. «СНЯТЬ» - деньги со счёта возвращаются монетами из МЭ. Ресурсный
--      счёт не снимается никак.
-- Владелец (admins в конфиге) попадает в свою панель, см. admin.lua.
--
-- Экран устроен как поиск картинок: сверху строка поиска, под ней вкладки
-- модов с числом найденного, ниже сетка карточек во всю ширину.
--
-- Деньги трогают четыре операции, и у всех один порядок: проверить, кто
-- стоит на PIM, записать изменение счёта на диск, двигать предметы,
-- недоданное вернуть на счёт. Приём (монеты, ресурсы) зачисляет не то, что
-- ушло из инвентаря, а то, на сколько выросло число этих предметов в МЭ, и
-- до приёма проверяет, что счёт вообще записывается.

local computer, unicode = computer, unicode
local root = require("root")
local gfx = require("gfx")
local catalog = require("catalog")
local storage = require("storage")
local wallet = require("wallet")
local rules = require("rules")
local admin = require("admin")

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
local BASE = cfg.rate or 1                            -- монет за единицу цены
local RATE = BASE * (cfg.markup or 1)                 -- то же с наценкой
local MODS = cfg.modNames or {}
local SIGN = cfg.sign or "$"
local RES_SIGN = cfg.resSign or "рес"
-- продавать ли стаки с NBT (броня и инструменты с зарядом, зачарованное) по
-- цене обычного предмета из выгрузки
local SELL_NBT = cfg.sellNbt ~= false
-- кто, встав на PIM, попадает в панель владельца
local ADMINS = {}
for _, n in ipairs(cfg.admins or { "Fatic" }) do ADMINS[n] = true end

rules.init(cfg)
wallet.zone(cfg.timeZone or 3)

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
local balM, balR = 0, 0   -- его счета в сотых: деньги и ресурсы
local stock = {}          -- товары в наличии
local stockErr            -- почему витрина пуста
local coinsInMe = 0       -- монет в МЭ: столько можно снять
local view = {
	screen = "idle",       -- idle | grid | item | cash | sell | admin
	tab = nil,             -- мод или nil - все
	tabTop = 1,            -- первая видимая вкладка
	query = "",
	sort = "name",         -- name | cheap | dear
	page = 1,
	item = nil,
	qty = 1,
	inv = nil,             -- слоты игрока на экране скупки
	sellPage = 1,
}
local shown, tabs = {}, {}
local hits = {}           -- кликабельные области кадра
local toast = { text = nil, colour = C.dim, till = 0 }
local pages = 1

-- ------------------------------------------------------------------ деньги

--- Цена штуки в сотых монеты, дробная: дешёвое стоит доли сотой, и
--- округляется только итог.
local function unitOf(rec) return rec.price * RATE * 100 end

--- Цена штуки в скупке, в сотых ресурсного счёта: цена выгрузки по курсу
--- скупки, без наценки магазина.
local function buyIn(rec) return rec.price * BASE * 100 * rules.rate() / 100 end

--- Итог в сотых: вверх, но хвост меньше 0.05 сотой не считается. Вверх -
--- чтобы покупка по одной не давала скидку на округлении (штука за 0.014
--- иначе стоила бы 0.01). Допуск - чтобы кирка за 1.50028 стоила 1.50.
local function totalOf(e, n)
	if n <= 0 then return 0 end
	return max(1, ceil(n * e.unit - 0.05))
end

local function money(cents) return wallet.format(cents) .. " " .. SIGN end
local function resm(cents) return wallet.format(cents) .. " " .. RES_SIGN end
local function accounts() return ("счёт %s · %s"):format(money(balM), resm(balR)) end

--- Меньше сотой - столько знаков, чтобы стало видно цифру: земля 0.00004,
--- а не 0.00.
local function tiny(u, sign)
	local d = 3
	while d < 8 and u * 10 ^ d < 1 do d = d + 1 end
	return ("%." .. d .. "f %s"):format(u, sign)
end

--- Цена за штуку для витрины: то, что спишется за одну.
local function unitText(e)
	local u = e.unit / 100
	if u >= 0.01 then return money(totalOf(e, 1)) end
	return tiny(u, SIGN)
end

--- Цена штуки в скупке.
local function buyInText(cents)
	local u = cents / 100
	if u >= 0.01 then return ("%.2f %s"):format(u, RES_SIGN) end
	return tiny(u, RES_SIGN)
end

local function num(n)
	local s = ("%.0f"):format(n):reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return (s:gsub("^ ", ""))
end

-- ------------------------------------------------------------------ склад

local function modOf(id) return id:match("^([^:]+)") or id end
local function modName(m) return MODS[m] or m end
local function labelOf(rec) return rec.label ~= "" and rec.label or rec.key end

--- Запись каталога для предмета. У вещей с износом запись без меты
--- главнее: у выгрузки есть свои записи и на крайние меты (разряженный
--- квант :27, сломанная кирка :1561), и по ним вышла бы вторая карточка
--- того же товара.
local function recOf(id, dmg)
	if dmg ~= 0 then
		local base = cat:get(id)
		if base and base.wear then return base end
	end
	return cat:get(catalog.key(id, dmg))
end

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
	-- ключи с метой и без: для вещей, где мета - заряд или износ, цена
	-- лежит на записи без меты
	local keys = {}
	for i = 1, #items do
		local it = items[i]
		keys[#keys + 1] = catalog.key(it.id, it.dmg)
		if it.dmg ~= 0 then keys[#keys + 1] = it.id end
	end
	cat:resolve(keys)

	-- Один товар - одна запись каталога. Экземпляры с разным NBT (энергия
	-- Draconic, заряд IC2) и, у вещей с износом, с разной метой (полоска
	-- заряда IC2, износ инструментов) складываются в одну карточку;
	-- каждый экземпляр помнит свой отпечаток, по нему и выдаётся.
	local out, byKey, coins = {}, {}, 0
	for i = 1, #items do
		local it = items[i]
		if it.id == COIN.id and it.dmg == COIN.dmg then
			if not it.nbt then coins = coins + it.size end
		elseif not it.nbt or SELL_NBT then
			local rec = recOf(it.id, it.dmg)
			if rec and rec.price > 0 then
				local e = byKey[rec.key]
				if not e then
					e = { key = rec.key, id = it.id, rec = rec, unit = unitOf(rec), size = 0,
					      variants = {}, mod = modOf(it.id) }
					e.label = labelOf(rec)
					e.low = unicode.lower(e.label)
					byKey[rec.key] = e
					out[#out + 1] = e
				end
				e.size = e.size + it.size
				e.variants[#e.variants + 1] = { id = it.id, dmg = it.dmg, nbt = it.nbt, size = it.size }
				if it.nbt or it.dmg ~= e.variants[1].dmg then e.mixed = true end
			end
		end
	end
	-- выдача по порядку: сначала без NBT, потом с меньшей метой - у IC2
	-- это заряженнее, у инструментов - целее
	for i = 1, #out do
		table.sort(out[i].variants, function(a, b)
			if (a.nbt == nil) ~= (b.nbt == nil) then return a.nbt == nil end
			if a.dmg ~= b.dmg then return a.dmg < b.dmg end
			return (a.nbt or "") < (b.nbt or "")
		end)
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
--- под ней название, ниже цена и откуда предмет. У товаров только за
--- деньги вместо мода - пометка об этом.
local function drawCard(e, x, y)
	fill(x, y, CW, CH, C.card)
	drawIcon(e, x + floor((CW - IW) / 2), y + 1, C.card)
	local badge = " " .. num(e.size) .. " шт "
	text(x + CW - ulen(badge), y + IH, badge, C.white, C.bg)
	text(x + 1, y + IH + 1, pad(e.label, CW - 2), C.text, C.card)
	local price = unitText(e)
	local room = CW - 3 - ulen(price)
	text(x + 1, y + IH + 2, price, C.gold, C.card)
	local only = rules.moneyOnly(e.key)
	local tag = only and ("только за " .. SIGN) or modName(e.mod)
	if room >= 3 then
		text(x + CW - 1 - min(room, ulen(tag)), y + IH + 2, clip(tag, room), only and C.gold or C.faint, C.card)
	end
end

-- ------------------------------------------------------------------ шапка

local SX = #TITLE + 6     -- где начинается строка поиска

--- Строка поиска. В админке она ищет игрока или запись журнала.
local function drawSearch(x, w)
	if w < 12 then return end
	local adm = view.screen == "admin"
	local q = adm and admin.query() or view.query
	fill(x, 1, w, 3, C.field)
	-- клик по строке с любого экрана ведёт к выдаче; крестик добавлен
	-- позже и потому перекрывает её (клик ищется с конца)
	if not adm then hit(x, 1, w, 3, function() if view.screen ~= "grid" then shop.back() end end) end
	text(x + 2, 2, "⌕", C.white, C.field)
	if q == "" then
		local hint = adm and "Игрок или запись журнала - просто печатайте" or "Найти предмет - просто печатайте"
		text(x + 5, 2, clip(hint, w - 8), C.dim, C.field)
	else
		text(x + 5, 2, clip(q, w - 12) .. "▏", C.white, C.field)
		text(x + w - 4, 2, "×", C.white, C.field)
		hit(x + w - 6, 1, 6, 3, function() if adm then admin.clear() else shop.search("") end end)
	end
end

local function drawHeader()
	fill(1, 1, W, 3, C.panel)
	if view.screen == "idle" then return end    -- там название крупно
	text(3, 2, TITLE, C.gold, C.panel)
	local sx = SX
	if rules.testMode() then
		local bx, bw = 3 + ulen(TITLE) + 1, 12
		button(bx, 1, bw, 3, "ТЕСТ-РЕЖИМ", C.black, C.gold)
		sx = max(SX, bx + bw + 2)
	end
	if not nick then return end
	-- справа налево: ПОПОЛНИТЬ, СКУПКА, СНЯТЬ, АДМИН, ресурсы, деньги, ник
	local bx = W - 14
	button(bx, 1, 15, 3, "ПОПОЛНИТЬ", C.black, C.green)
	hit(bx, 1, 15, 3, function() shop.deposit() end)
	bx = bx - 11
	button(bx, 1, 10, 3, "СКУПКА", C.black, C.accent)
	hit(bx, 1, 10, 3, function() shop.openSell() end)
	bx = bx - 10
	button(bx, 1, 9, 3, "СНЯТЬ", C.text, C.line)
	hit(bx, 1, 9, 3, function() shop.openCash() end)
	if ADMINS[nick] then
		bx = bx - 10
		local on = view.screen == "admin"
		button(bx, 1, 9, 3, "АДМИН", on and C.black or C.text, on and C.gold or C.blue)
		hit(bx, 1, 9, 3, function() shop.openAdmin() end)
	end
	local r = resm(balR)
	local x = bx - 2 - max(ulen(r), 7)
	text(x, 1, "ресурсы", C.dim, C.panel)
	text(x, 2, r, C.accent, C.panel)
	local m = money(balM)
	x = x - 2 - max(ulen(m), 6)
	text(x, 1, "деньги", C.dim, C.panel)
	text(x, 2, m, C.gold, C.panel)
	local nx = x - 2 - max(ulen(nick), 5)
	text(nx, 1, "игрок", C.dim, C.panel)
	text(nx, 2, nick, C.text, C.panel)
	drawSearch(sx, nx - 3 - sx)
end

local function footerText()
	if toast.text and computer.uptime() < toast.till then return toast.text, toast.colour end
	local ok, why = wallet.ok()
	if not ok then return why, C.red end
	if cat and cat:missing() then
		return "нет второго диска с " .. cat.path2 .. " - часть иконок не видна", C.red
	end
	if not nick then return "", C.dim end
	if rules.testMode() then
		return "ТЕСТ-РЕЖИМ: купить ничего нельзя; пополнение, скупка, снятие и поиск работают как обычно", C.gold
	end
	if view.screen == "admin" then return "Панель владельца: всё, что здесь меняется, пишется в журнал", C.dim end
	return "Монеты - «ПОПОЛНИТЬ»: деньги, их можно снять. Ресурсы - «СКУПКА»: ресурсный счёт, только на покупки", C.dim
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

--- Страницы списка: ◀ n / m ▶ с клика.
local function pager(x, y, page, count, set)
	if count <= 1 then return end
	local label = (" %d / %d "):format(page, count)
	text(x, y, " ◀ ", page > 1 and C.text or C.faint, C.line)
	text(x + 3, y, label, C.text, C.bg)
	text(x + 3 + ulen(label), y, " ▶ ", page < count and C.text or C.faint, C.line)
	hit(x, y, 3, 1, function() set(page - 1) end)
	hit(x + 3 + ulen(label), y, 3, 1, function() set(page + 1) end)
end

-- ------------------------------------------------------------------ товар

--- Сколько штук можно оплатить счётом have.
local function affordable(e, have)
	local n = floor(have / e.unit)
	while n > 0 and totalOf(e, n) > have do n = n - 1 end
	return n
end

--- Сколько можно купить разом: хватает денег или ресурсов, есть в МЭ и
--- влезет в свободные слоты (по 64: сколько держит стопка, PIM про предмет
--- в МЭ не скажет; лишнее всё равно вернётся на счёт).
local function maxQty(e)
	local best = affordable(e, balM)
	if not rules.moneyOnly(e.key) then best = max(best, affordable(e, balR)) end
	return max(0, min(e.size, best, 64 * store:freeSlots()))
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
	local only = rules.moneyOnly(e.key)
	text(x, 10, clip(e.label, wtxt), C.white, C.bg)
	text(x, 11, clip(modName(e.mod) .. "  ·  " .. e.key, wtxt), C.faint, C.bg)
	local ny = 12
	if e.mixed then
		text(x, ny, clip("экземпляры с разным зарядом или износом - один товар; выдаются начиная с самых целых", wtxt), C.accent, C.bg)
		ny = ny + 1
	end
	if only then text(x, ny, clip("продаётся только за деньги - за ресурсы нельзя", wtxt), C.gold, C.bg) end

	local col = floor(wtxt / 4)
	text(x, 14, "цена за штуку", C.dim, C.bg)
	text(x, 15, unitText(e), C.white, C.bg)
	text(x + col, 14, "в наличии", C.dim, C.bg)
	text(x + col, 15, num(e.size) .. " шт.", C.text, C.bg)
	text(x + col * 2, 14, "деньги", C.dim, C.bg)
	text(x + col * 2, 15, money(balM), C.gold, C.bg)
	text(x + col * 3, 14, "ресурсы", C.dim, C.bg)
	text(x + col * 3, 15, resm(balR), C.accent, C.bg)

	text(x, 18, "количество", C.dim, C.bg)
	drawAmount(x, 19, view.qty, { 1, 10, 64 }, shop.setQty, function() return maxQty(e) end)

	local total = totalOf(e, view.qty)
	text(x, 24, "итого", C.dim, C.bg)
	text(x, 25, only and money(total) or (money(total) .. "  или  " .. resm(total)), C.white, C.bg)
	local inStock = view.qty >= 1 and view.qty <= e.size
	if not inStock then text(x, 26, "в наличии только " .. num(e.size) .. " шт.", C.red, C.bg) end

	-- кнопка оплаты с одного счёта, под ней - хватает ли
	local testMode = rules.testMode()
	local function pay(bx, kind)
		local have = kind == "r" and balR or balM
		local fmt = kind == "r" and resm or money
		local ok = inStock and total <= have and not testMode
		local back = kind == "r" and C.accent or C.green
		button(bx, 28, 32, 5, kind == "r" and "КУПИТЬ ЗА РЕСУРСЫ" or "КУПИТЬ ЗА ДЕНЬГИ",
			ok and C.black or C.faint, ok and back or C.card)
		if ok then hit(bx, 28, 32, 5, function() shop.buy(kind) end) end
		if testMode then
			text(bx, 34, clip("тестовый режим - покупка отключена", 32), C.gold, C.bg)
		elseif total > have then
			text(bx, 34, clip("не хватает " .. fmt(total - have), 32), C.red, C.bg)
		else
			text(bx, 34, clip("останется " .. fmt(have - total), 32), C.dim, C.bg)
		end
	end
	pay(x, "m")
	if only then
		button(x + 34, 28, 32, 5, "ЗА РЕСУРСЫ НЕЛЬЗЯ", C.faint, C.card)
		text(x + 34, 34, "этот товар - только за деньги", C.dim, C.bg)
	else
		pay(x + 34, "r")
	end
end

-- ------------------------------------------------------------------ снятие

local function coinCents() return COIN_VALUE * 100 end

--- Сколько монет можно снять: хватает на счету, есть в МЭ, влезет.
local function maxCash()
	return max(0, min(floor(balM / coinCents()), coinsInMe, 64 * store:freeSlots()))
end

local function drawCash()
	fill(1, 4, W, H - 4, C.bg)
	backButton()
	local x = 22
	text(x, 10, "Снять деньги со счёта", C.white, C.bg)
	text(x, 11, "выдаются монетами " .. COIN.id .. ", одна монета - " .. money(coinCents()), C.faint, C.bg)
	text(x, 12, "ресурсный счёт не снимается - его можно только потратить на покупки", C.faint, C.bg)

	text(x, 14, "деньги на счету", C.dim, C.bg)
	text(x, 15, money(balM), C.gold, C.bg)
	text(x + 30, 14, "монет в магазине", C.dim, C.bg)
	text(x + 30, 15, num(coinsInMe), C.text, C.bg)

	text(x, 18, "сколько монет", C.dim, C.bg)
	drawAmount(x, 19, view.qty, { 1, 10, 64, 640 }, shop.setCash, maxCash)

	local cost = view.qty * coinCents()
	text(x, 24, "спишется", C.dim, C.bg)
	text(x, 25, money(cost), C.gold, C.bg)
	local ok = view.qty >= 1 and cost <= balM and view.qty <= coinsInMe
	if cost > balM then
		text(x, 26, "на счету столько нет", C.red, C.bg)
	elseif view.qty > coinsInMe then
		text(x, 26, "в магазине только " .. num(coinsInMe) .. " монет", C.red, C.bg)
	else
		text(x, 26, "останется " .. money(balM - cost), C.dim, C.bg)
	end
	button(x, 29, 32, 5, "СНЯТЬ", ok and C.black or C.faint, ok and C.green or C.card)
	if ok then hit(x, 29, 32, 5, function() shop.withdraw() end) end
end

-- ------------------------------------------------------------------ скупка

--- Что игрок может сдать сейчас: по предмету из инвентаря - сколько и
--- почём. Слоты читаются при входе на экран и после сдачи.
local function sellable()
	local by, out = {}, {}
	if not (cat and view.inv) then return out end
	for s = 1, store.slots do
		local it = view.inv[s]
		if it and not it.nbt then
			local rec = recOf(it.id, it.dmg)
			if rec and rec.price > 0 and rules.accepts(rec.key) then
				local g = by[rec.key]
				if not g then
					g = { label = labelOf(rec), qty = 0, unit = buyIn(rec) }
					by[rec.key] = g
					out[#out + 1] = g
				end
				g.qty = g.qty + it.qty
			end
		end
	end
	table.sort(out, function(a, b) return a.label < b.label end)
	return out
end

local function drawSell()
	fill(1, 4, W, H - 4, C.bg)
	backButton()
	local L, R = 22, 100
	text(L, 5, "Скупка ресурсов", C.white, C.bg)
	text(L, 6, clip(("сданное ложится на ресурсный счёт по %d%% цены: на него покупают, снять его нельзя")
		:format(rules.rate()), W - L - 1), C.faint, C.bg)

	-- слева: что игрок может сдать сейчас
	text(L, 9, "у вас в инвентаре", C.dim, C.bg)
	local have, total = sellable(), 0
	for i, g in ipairs(have) do
		local v = g.qty * g.unit
		total = total + v
		local y = 10 + i
		if y <= 38 then
			text(L, y, pad(g.label, 38), C.text, C.bg)
			text(L + 39, y, pad("×" .. num(g.qty), 9), C.dim, C.bg)
			text(L + 49, y, resm(floor(v + 1e-6)), C.accent, C.bg)
		end
	end
	if #have == 0 then
		text(L, 11, "сдавать нечего: положите в инвентарь что-то из списка справа", C.dim, C.bg)
	end
	total = floor(total + 1e-6)
	text(L, 40, "к зачислению", C.dim, C.bg)
	text(L, 41, resm(total), C.accent, C.bg)
	local ok = total > 0
	button(L, 43, 32, 5, "СДАТЬ ВСЁ", ok and C.black or C.faint, ok and C.accent or C.card)
	if ok then hit(L, 43, 32, 5, function() shop.sell() end) end

	-- справа: что скупаем и почём, по названию
	local list = {}
	for _, k in ipairs(rules.list("res")) do
		local rec = cat and cat:get(k)
		list[#list + 1] = { rec = rec and rec.price > 0 and rec or nil, label = rec and labelOf(rec) or k }
	end
	table.sort(list, function(a, b) return a.label < b.label end)
	text(R, 9, "скупаем: " .. #list, C.dim, C.bg)
	local rows = H - 13
	local count = max(1, ceil(#list / rows))
	view.sellPage = max(1, min(view.sellPage, count))
	for i = 1, rows do
		local it = list[(view.sellPage - 1) * rows + i]
		if not it then break end
		local y = 10 + i
		if it.rec then
			text(R, y, pad(it.label, 40), C.text, C.bg)
			text(R + 41, y, buyInText(buyIn(it.rec)) .. " за шт.", C.accent, C.bg)
		else
			text(R, y, pad(it.label, 40), C.faint, C.bg)
			text(R + 41, y, "нет цены - не берём", C.faint, C.bg)
		end
	end
	pager(R, H - 1, view.sellPage, count, function(p)
		view.sellPage = p
		shop.draw()
	end)
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
	if rules.testMode() then
		local tag = "ТЕСТ-РЕЖИМ - ПОКУПКИ ОТКЛЮЧЕНЫ"
		button(floor((W - ulen(tag)) / 2) - 1, cy + 4, ulen(tag) + 2, 1, tag, C.black, C.gold)
	end
	local msg = "Встаньте на PIM, чтобы войти"
	text(floor((W - ulen(msg)) / 2) + 1, cy + 7, msg, C.text, C.bg)
	local sub = "оплата монетами " .. COIN.id .. " или ресурсами из скупки"
	text(floor((W - ulen(sub)) / 2) + 1, cy + 8, sub, C.faint, C.bg)

	local _, why = wallet.ok()
	local err = why or stockErr
	if err then
		text(floor((W - ulen(err)) / 2) + 1, cy + 11, err, C.red, C.bg)
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
	elseif view.screen == "sell" then drawSell()
	elseif view.screen == "admin" then admin.draw()
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
	balM, balR = wallet.get(nick)
	refresh()
	view.screen, view.item, view.qty = "cash", nil, 1
	shop.draw()
end

function shop.setCash(n)
	view.qty = max(1, floor(n))
	shop.draw()
end

function shop.openSell()
	balM, balR = wallet.get(nick)
	view.inv = store:slotsOfPlayer()
	if cat then cat:resolve(rules.list("res")) end
	view.screen, view.item, view.sellPage = "sell", nil, 1
	shop.draw()
end

function shop.openAdmin()
	if not ADMINS[nick] then return end
	admin.open()
	view.screen, view.item = "admin", nil
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

--- Можно ли сейчас трогать деньги: игрок на месте и счета доступны.
local function ready()
	if not nick or not present() then return false end
	local ok, why = wallet.ok()
	if not ok then shop.say(why, C.red) return false end
	return true
end

--- Забрать у игрока стопки без NBT, которые выбирает pick(it) - он
--- возвращает цену штуки в сотых и название или nil. Возвращает по
--- каждому предмету, сколько ушло из инвентаря (pushed) и сколько из этого
--- действительно пришло в МЭ (n); зачислять можно только n.
local function intake(pick)
	local slots = store:slotsOfPlayer()
	local plan, list = {}, {}
	for s = 1, store.slots do
		local it = slots[s]
		if it and not it.nbt then
			local unit, label = pick(it)
			if unit then
				local k = storage.tag(it.id, it.dmg)
				local g = plan[k]
				if not g then
					g = { id = it.id, dmg = it.dmg, unit = unit, label = label, pushed = 0, n = 0, from = {} }
					plan[k] = g
					list[#list + 1] = g
				end
				g.from[#g.from + 1] = { s, it.qty }
			end
		end
	end
	if #list == 0 then return list end
	local before = store:counts()
	if not before then return nil, "МЭ не отвечает, попробуйте ещё раз" end
	for _, g in ipairs(list) do
		for _, sq in ipairs(g.from) do g.pushed = g.pushed + store:push(sq[1], sq[2]) end
	end
	-- МЭ-интерфейс переносит принятое в сеть на своём тике: не дошло сразу -
	-- ещё пара попыток. Сеть так и не ответила - как раньше, по ушедшему
	local answered = false
	for _ = 1, 3 do
		local after = store:counts()
		if after then
			answered = true
			local short = false
			for k, g in pairs(plan) do
				g.n = min(g.pushed, max(0, (after[k] or 0) - (before[k] or 0)))
				if g.n < g.pushed then short = true end
			end
			if not short then break end
		end
	end
	for _, g in ipairs(list) do
		if not answered then g.n = g.pushed end
		if g.n < g.pushed then
			wallet.log(("ВНИМАНИЕ %s: %s - из инвентаря ушло %d, в МЭ пришло %d, зачислено %d")
				:format(nick, g.label, g.pushed, g.n, g.n))
		end
	end
	return list
end

--- Зачислить принятое: деньги dm и ресурсы dr. Счёт не записался -
--- принятое уходит игроку обратно: иначе он остался бы и без вещей, и
--- без денег.
local function credit(dm, dr, got, what)
	local m, r = wallet.add(nick, dm, dr)
	if m then
		balM, balR = m, r
		return true
	end
	local back = 0
	for _, g in ipairs(got) do
		if g.n > 0 then back = back + store:give(g.id, g.dmg, g.n) end
	end
	wallet.log(("ВНИМАНИЕ %s: %s - счёт не записался, возвращено %d шт."):format(nick, what, back))
	note("счёт не записался - всё принятое возвращено", C.red)
	return false
end

function shop.deposit()
	if not ready() then return end
	if not wallet.writable(nick) then shop.say("счёт не записывается - приём остановлен", C.red) return end
	shop.say("принимаю монеты…", C.dim)
	local got, err = intake(function(it)
		if it.id == COIN.id and it.dmg == COIN.dmg then return coinCents(), "монеты" end
	end)
	if not got then shop.say(err, C.red) return end
	local g = got[1]
	if not g then shop.say("в инвентаре нет монет " .. COIN.id, C.red) return end
	if g.pushed <= 0 then
		note("МЭ не принимает монеты - нет места в сети?", C.red)
	elseif g.n <= 0 then
		note("монеты не дошли до МЭ - ничего не зачислено", C.red)
	else
		local cents = g.n * coinCents()
		if credit(cents, 0, got, "пополнение") then
			wallet.log(("%s пополнил: %s монет → +%s  %s"):format(nick, num(g.n), money(cents), accounts()))
			note(("зачислено %s монет: +%s"):format(num(g.n), money(cents)), C.green)
		end
	end
	refresh()
	shop.draw()
end

function shop.sell()
	if not ready() then return end
	if not wallet.writable(nick) then shop.say("счёт не записывается - скупка остановлена", C.red) return end
	shop.say("принимаю ресурсы…", C.dim)
	local got, err = intake(function(it)
		if not cat then return nil end
		local rec = recOf(it.id, it.dmg)
		if rec and rec.price > 0 and rules.accepts(rec.key) then return buyIn(rec), labelOf(rec) end
	end)
	if not got then shop.say(err, C.red) return end
	if #got == 0 then shop.say("в инвентаре нет ресурсов из списка скупки", C.red) return end
	local cents, parts = 0, {}
	for _, g in ipairs(got) do
		if g.n > 0 then
			cents = cents + g.n * g.unit
			parts[#parts + 1] = g.label .. " ×" .. num(g.n)
		end
	end
	cents = floor(cents + 1e-6)
	if #parts == 0 then
		note("ресурсы не дошли до МЭ - ничего не зачислено", C.red)
	elseif credit(0, cents, got, "скупка") then
		wallet.log(("%s сдал в скупку: %s → +%s  %s"):format(nick, table.concat(parts, ", "), resm(cents), accounts()))
		note(("сдано: +%s на ресурсный счёт"):format(resm(cents)), C.green)
	end
	view.inv = store:slotsOfPlayer()
	refresh()
	shop.draw()
end

--- Купить view.qty штук открытого товара: kind "m" - за деньги, "r" - за
--- ресурсы.
function shop.buy(kind)
	local e = view.item
	if not e or not ready() then return end
	if rules.testMode() then shop.say("тестовый режим: покупки отключены", C.gold) return end
	if kind == "r" and rules.moneyOnly(e.key) then return end
	local qty = view.qty
	local cost = totalOf(e, qty)
	balM, balR = wallet.get(nick)
	if cost > (kind == "r" and balR or balM) then shop.draw() return end
	if store:freeSlots() == 0 then
		shop.say("инвентарь полон - освободите место", C.red)
		return
	end
	-- с какого счёта: деньги dm или ресурсы dr
	local function part(v) if kind == "r" then return 0, v end return v, 0 end
	-- сначала списать и записать на диск, потом выдавать: выключение посреди
	-- выдачи не должно оставить предмет бесплатным
	local m, r = wallet.add(nick, part(-cost))
	if not m then shop.say("не удалось списать", C.red) return end
	balM, balR = m, r
	shop.say("выдаю…", C.dim)
	local sent = 0
	for _, v in ipairs(e.variants) do
		if sent >= qty then break end
		sent = sent + store:give(v.id, v.dmg, min(v.size, qty - sent), v.nbt)
	end
	local paid = totalOf(e, sent)
	if paid < cost then
		m, r = wallet.add(nick, part(cost - paid))
		if m then balM, balR = m, r else balM, balR = wallet.get(nick) end
	end
	local fmt = kind == "r" and resm or money
	wallet.log(("%s купил %s ×%s%s за %s  [%s]  %s"):format(nick, e.label, num(sent),
		sent < qty and (" из " .. num(qty)) or "", fmt(paid), e.key, accounts()))

	refresh()
	local now = findStock(e.key)
	if now then
		view.item = now
		view.qty = max(1, min(view.qty, now.size))
	else
		view.screen, view.item = "grid", nil
	end
	if sent == 0 then
		note("не выдано: нет места или товар кончился, счёт не тронут", C.red)
	elseif sent < qty then
		note(("выдано %d из %d - на остальное не хватило места, разница вернулась на счёт"):format(sent, qty), C.gold)
	else
		note(("куплено: %s × %s за %s"):format(e.label, num(sent), fmt(paid)), C.green)
	end
	shop.draw()
end

function shop.withdraw()
	if not ready() then return end
	local n = view.qty
	local cost = n * coinCents()
	balM, balR = wallet.get(nick)
	if n < 1 or cost > balM then shop.draw() return end
	if store:freeSlots() == 0 then
		shop.say("инвентарь полон - освободите место", C.red)
		return
	end
	-- тот же порядок, что у покупки: списать, выдать, недоданное вернуть
	local m, r = wallet.add(nick, -cost, 0)
	if not m then shop.say("не удалось списать деньги", C.red) return end
	balM, balR = m, r
	shop.say("выдаю монеты…", C.dim)
	local sent = store:give(COIN.id, COIN.dmg, n)
	if sent < n then
		m, r = wallet.add(nick, (n - sent) * coinCents(), 0)
		if m then balM, balR = m, r else balM, balR = wallet.get(nick) end
	end
	wallet.log(("%s снял %s монет%s (−%s)  %s"):format(nick, num(sent),
		sent < n and (" из " .. num(n)) or "", money(sent * coinCents()), accounts()))
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
	balM, balR = wallet.get(nick)
	view.screen, view.tab, view.tabTop, view.query, view.page, view.item = "grid", nil, 1, "", 1, nil
	toast.text = nil
	wallet.log(("%s вошёл, %s"):format(nick, accounts()))
	refresh()
	if ADMINS[nick] then
		admin.open()
		view.screen = "admin"
	end
	shop.draw()
end

function logout()
	if nick then wallet.log(nick .. " вышел") end
	nick, balM, balR = nil, 0, 0
	view.screen, view.item, view.query, view.inv = "idle", nil, "", nil
	toast.text = nil
	admin.reset()
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

-- ------------------------------------------------------------------ админка

admin.init({
	C = C, W = W, H = H, hit = hit, pager = pager, num = num,
	money = money, resm = resm, buyIn = buyIn, buyInText = buyInText,
	store = store, cat = cat, recOf = cat and recOf, labelOf = labelOf,
	nick = function() return nick end,
	present = function() return present() end,
	reload = function() if nick then balM, balR = wallet.get(nick) end end,
	draw = function() shop.draw() end,
	say = function(s, colour, secs) shop.say(s, colour, secs) end,
	toShop = function()
		view.screen, view.item = "grid", nil
		shop.draw()
	end,
})

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
	if not nick or (who and who ~= nick) then return end
	if view.screen == "admin" then admin.scroll(dir) return end
	if view.screen == "sell" then
		view.sellPage = max(1, view.sellPage - dir)
		shop.draw()
		return
	end
	if view.screen ~= "grid" then return end
	if y >= 5 and y <= 6 then
		view.tabTop = max(1, min(#tabs, view.tabTop - dir))
		shop.draw()
	else
		shop.turn(dir > 0 and -1 or 1)
	end
end

--- Печатать можно с любого экрана: буквы сразу идут в поиск. В админке -
--- в её поиск.
function handlers.key_down(_, ch, code, who)
	if not nick or (who and who ~= nick) or view.screen == "idle" then return end
	if view.screen == "admin" then admin.key(ch, code) return end
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
