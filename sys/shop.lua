-- shop - магазин: витрина из МЭ, цены из выгрузки, два счёта.
--
-- Как это работает для игрока:
--   1. встал на PIM - магазин узнал ник и показал его счета и его тему;
--   2. «Пополнить» - монеты customnpcs:npcMoney из инвентаря уходят в МЭ,
--      на денежный счёт ложится их стоимость;
--   3. «Скупка» - ресурсы из списка скупки (железо, золото…) уходят в МЭ,
--      на ресурсный счёт ложится их цена из выгрузки по курсу скупки;
--   4. нашёл предмет поиском или в разделе мода, выбрал количество,
--      «Купить за деньги» или «Купить за ресурсы» - предмет пришёл из МЭ в
--      инвентарь, с выбранного счёта списана цена. Что-то (иридий) за
--      ресурсы не продаётся;
--   5. «Снять» - деньги со счёта возвращаются монетами из МЭ. Ресурсный
--      счёт не снимается никак.
-- Владелец (admins в конфиге) попадает в свою панель, см. admin.lua.
--
-- Экран: сверху шапка (поиск, счёт, кнопки, тема), под ней разделы модов с
-- подчёркиванием, ниже сетка карточек. Размеров два: крупные элементы в 3
-- строки, мелкие в строку; поля по краям M, между соседями GAP. Что не
-- влезает - уходит в выпадающий список: моды в «Ещё ▾», кнопки шапки в «☰».
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
local theme = require("theme")
local admin = require("admin")

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local fill, text, clip, box, pill = gfx.fill, gfx.text, gfx.clip, gfx.box, gfx.pill
local ICON = gfx.ICON
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
local M, GAP = 5, 2       -- поля по краям экрана и зазор между соседями
local T = theme.dark      -- цвета: тема того, кто стоит на PIM

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
	query = "",
	sort = "name",         -- name | cheap | dear
	page = 1,
	item = nil,
	qty = 1,
	inv = nil,             -- слоты игрока на экране скупки
	sellPage = 1,
	open = nil,            -- открытый список: more | sort | menu
}
local shown, tabs = {}, {}
local hits = {}           -- кликабельные области кадра
local noHits = false      -- перерисовка куска: области остаются прежними
local toast = { title = nil, sub = nil, kind = "ok", till = 0 }
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

--- «1 монета», «3 монеты», «5 монет».
local function plural(n, one, few, many)
	local a, b = n % 10, n % 100
	local w = many
	if a == 1 and b ~= 11 then w = one
	elseif a >= 2 and a <= 4 and (b < 12 or b > 14) then w = few end
	return num(n) .. " " .. w
end
local function coins(n) return plural(n, "монета", "монеты", "монет") end

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
	local out, byKey, nCoins = {}, {}, 0
	for i = 1, #items do
		local it = items[i]
		if it.id == COIN.id and it.dmg == COIN.dmg then
			if not it.nbt then nCoins = nCoins + it.size end
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
	stock, coinsInMe, stockErr = out, nCoins, nil
	if #out == 0 then stockErr = "в МЭ нет товаров с ценой" end
end

--- Выборка: поиск по всему складу, по найденному - разделы модов с
--- числами, потом отбор по открытому разделу и сортировка.
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
	-- открытый мод в выдаче не нашёлся - раздел остаётся, но пустой
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

-- ------------------------------------------------------------------ элементы

local function hit(x, y, w, h, fn)
	if not noHits then hits[#hits + 1] = { x, y, x + w - 1, y + h - 1, fn } end
end

local function drawIcon(e, x, y, back, scale)
	local cells = cat and cat:cells(e.rec)
	local w, h = cat.iw * (scale or 1), cat.ih * (scale or 1)
	if cells then
		gfx.icon(cells, e.rec.braille and 1 or 0, cat.iw, cat.ih, x, y, back, scale)
	else
		fill(x, y, w, h, back)
		text(x + floor((w - 1) / 2), y + floor(h / 2), "?", T.faint, back)
	end
end

--- Крупная кнопка; disabled - серая и не нажимается.
local function button(x, y, w, label, st, icon, fn, disabled)
	if disabled then st = T.off end
	gfx.button(x, y, w, label, st, T.bg, icon, not disabled and T.shadow or nil)
	if fn and not disabled then hit(x, y, w, 3, fn) end
end

--- Плитка: подпись и число.
local function tile(x, y, w, label, value, colour)
	box(x, y, w, 3, T.surf, T.bg, nil, nil, T.flatShadow)
	text(x + 2, y, clip(label, w - 4), T.faint, T.surf)
	text(x + 2, y + 1, clip(value, w - 4), colour, T.surf)
end

--- Строка с подчёркиванием под ней: разделы и строка «‹ Назад».
local function underline(y) gfx.rule(M, y + 1, W - 2 * M + 1, T.name == "dark" and T.raised or T.line, T.bg) end

--- Полоса количества: шаги вниз, число, шаги вверх, «макс». Деления
--- делят ширину поровну. get/set - текущее значение: области клика живут
--- дольше кадра (число меняется перерисовкой куска).
local function stepper(x, y, w, steps, get, set, maxFn, unit)
	local b = T.raised
	box(x, y, w, 3, b, T.bg, nil, nil, T.flatShadow)
	local n = #steps * 2 + (maxFn and 1 or 0)
	local small = floor((w - 14) / n)
	local vw = w - small * n
	local cx = x
	local function part(label, colour, fn, divider)
		text(cx + floor((small - ulen(label)) / 2), y + 1, label, colour, b)
		if divider then text(cx, y + 1, "▏", T.line, b) end
		hit(cx, y, small, 3, fn)
		cx = cx + small
	end
	for i = #steps, 1, -1 do
		local d = steps[i]
		part("−" .. num(d), T.text, function() set(get() - d) end, i ~= #steps)
	end
	local vx = cx
	local function value()
		box(vx, y, vw, 3, T.text, b)
		local v = num(get()) .. (unit and (" " .. unit) or "")
		text(vx + floor((vw - ulen(v)) / 2), y + 1, v, T.bg, T.text)
	end
	value()
	cx = cx + vw
	for i = 1, #steps do
		local d = steps[i]
		part("+" .. num(d), T.text, function() set(get() + d) end, i ~= 1)
	end
	if maxFn then part("макс", T.acc, function() set(maxFn()) end, true) end
	return value
end

--- Выпадающий список: пункт - { название, число или nil, действие }.
--- Длинный встаёт в несколько колонок по 14 строк; правый край - там же,
--- где у одной колонки (x + w). Щелчок мимо закрывает его: сначала
--- ловушка на весь экран, пункты - поверх неё.
local function menu(x, y, w, items, sel)
	local b = T.raised
	local cols = max(1, min(ceil(#items / 14), floor((W - 2 * M + 1) / w)))
	local rows = ceil(#items / cols)
	local right = x + w
	w = w * cols
	x = max(M, min(right - w, W - M + 1 - w))
	local cw = floor(w / cols)
	box(x, y, w, rows + 2, b, T.bg, nil, nil, T.shadow)
	hit(1, 1, W, H, function() view.open = nil shop.draw() end)
	for i, it in ipairs(items) do
		local col = floor((i - 1) / rows)
		local yy = y + 1 + (i - 1) % rows
		local x0, w0 = x, w
		x, w = x0 + col * cw, cw
		local on = i == sel
		local bb = on and T.acc or b
		if on then
			text(x + 1, yy, "▐", T.acc, b)
			fill(x + 2, yy, w - 4, 1, T.acc)
			text(x + w - 2, yy, "▌", T.acc, b)
		end
		local count = it[2] and num(it[2]) or ""
		text(x + 3, yy, clip(it[1], w - 6 - ulen(count)), on and T.on or T.text, bb)
		if it[2] then text(x + w - 3 - ulen(count), yy, count, on and T.on or T.faint, bb) end
		hit(x, yy, w, 1, function() view.open = nil it[3]() end)
		x, w = x0, w0
	end
end

--- Разделы с подчёркиванием. Берём столько, сколько влезает в w, остальные
--- уходят в «Ещё N ▾»; открытый, если он не влез, встаёт последним
--- видимым. Свободное место делится между вкладками поровну.
---   list - { name, n, fn }, active - номер открытого, key - какой список
---   открывает «Ещё». Возвращает спрятанные и где стоит «Ещё».
local function tabRow(x, y, w, list, active, key)
	local function nat(t) return ulen(t.name) + (t.n and (1 + ulen(num(t.n))) or 0) + 2 end
	local MORE = 11
	local order = {}
	for i = 1, #list do order[i] = i end
	local function fit()
		local k, used = 0, 0
		for i = 1, #order do
			local need = used + (i > 1 and GAP or 0) + nat(list[order[i]])
			local tail = i < #order and (GAP + MORE) or 0
			if need + tail > w and i > 1 then break end
			k, used = i, need
		end
		return k
	end
	local k = fit()
	for _ = 1, 3 do
		local pos
		for i = 1, #order do if order[i] == active then pos = i end end
		if not pos or pos <= k then break end
		table.remove(order, pos)
		table.insert(order, max(1, k), active)
		k = fit()
	end
	local more = k < #order
	local room = w - (more and (GAP + MORE) or 0) - GAP * (k - 1)
	for i = 1, k do room = room - nat(list[order[i]]) end
	local add = gfx.split(max(0, room) + GAP * (k - 1), k, GAP)
	gfx.rule(x, y + 1, w, T.name == "dark" and T.raised or T.line, T.bg)
	local cx = x
	for i = 1, k do
		local t = list[order[i]]
		local tw = nat(t) + add[i]
		local on = order[i] == active
		local lx = cx + floor((tw - nat(t) + 2) / 2)
		text(lx, y, t.name, on and T.text or T.dim, T.bg)
		if t.n then text(lx + ulen(t.name) + 1, y, num(t.n), on and T.acc or T.faint, T.bg) end
		if on then gfx.rule(cx, y + 1, tw, T.acc, T.bg) end
		hit(cx, y, tw, 2, t.fn)
		cx = cx + tw + GAP
	end
	local hidden = {}
	for i = k + 1, #order do hidden[#hidden + 1] = list[order[i]] end
	if more then
		local mx = x + w - MORE
		local open = view.open == key
		local label = "Ещё " .. #hidden .. " ▾"
		text(mx + floor((MORE - ulen(label)) / 2), y, label, open and T.text or T.dim, T.bg)
		if open then gfx.rule(mx, y + 1, MORE, T.acc, T.bg) end
		hit(mx, y, MORE, 2, function() view.open = open and nil or key shop.draw() end)
		return hidden, mx, MORE
	end
	return hidden
end

--- Листалка в строку: ‹ n из m ›, прижата вправо к x.
local function pager(xr, y, page, count, set)
	if count <= 1 then return end
	local label = ("%d из %d"):format(page, count)
	local x = xr - 3
	local nb = page < count and T.acc or (T.name == "dark" and T.raised or T.line)
	pill(x, y, "›", page < count and T.on or T.faint, nb, T.bg)
	hit(x, y, 4, 1, function() set(page + 1) end)
	x = x - ulen(label) - 2
	text(x + 1, y, label, T.text, T.bg)
	x = x - 4
	local pb = T.name == "dark" and T.raised or T.line
	pill(x, y, "‹", page > 1 and T.text or T.faint, pb, T.bg)
	hit(x, y, 4, 1, function() set(page - 1) end)
end

-- ------------------------------------------------------------------ шапка

local header = {}         -- где что встало: для списка «☰»

--- Шапка: поиск, счёт, кнопки, тема. Кнопки справа налево; если поиску
--- остаётся меньше 30 клеток, «Снять» и «Админ» уходят в меню «☰».
local function drawHeader()
	local y = 2
	fill(1, 1, W, 5, T.bg)
	text(M, y + 1, "◆", T.acc, T.bg)
	local adm = view.screen == "admin"
	local items = {
		{ "Пополнить", T.green, ICON.deposit, function() shop.deposit() end },
		{ "Скупка", T.blue, ICON.crate, function() shop.openSell() end },
		{ "Снять", T.grey, ICON.withdraw, function() shop.openCash() end, menu = "Снять деньги" },
	}
	if ADMINS[nick] then
		items[#items + 1] = adm
			and { "Витрина", T.primary, ICON.shop, function() shop.toShop() end, menu = "Витрина" }
			or { "Админ", T.grey, ICON.key, function() shop.openAdmin() end, menu = "Панель владельца" }
	end
	-- счёт одной строкой: ник, деньги, ресурсы; плашка - по ширине текста
	local who = nick or ""
	local mStr, rStr = "● " .. money(balM), "◈ " .. resm(balR)
	local BW, SEARCH = 19, 30
	local ACC = max(30, ulen(who) + ulen(mStr) + ulen(rStr) + 10)
	local left = M + 3
	local right = W - M + 1 - 8               -- кнопка темы
	local hidden = {}
	local function room()
		local used = #items * (BW + GAP) + (#hidden > 0 and (8 + GAP) or 0)
		return right - GAP - used - (ACC + GAP) - left
	end
	while room() < SEARCH do
		local at
		for i = #items, 1, -1 do if items[i].menu then at = i break end end
		if not at then break end
		table.insert(hidden, 1, table.remove(items, at))
	end

	gfx.iconButton(right, y, T.name == "dark" and ICON.moon or ICON.sun, T.sun, T.grey.base, T.bg, T.shadow)
	hit(right, y, 8, 3, function() shop.toggleTheme() end)
	local x = right
	header.menu = nil
	if #hidden > 0 then
		x = x - GAP - 8
		gfx.iconButton(x, y, ICON.menu, view.open == "menu" and T.acc or T.text, T.grey.base, T.bg, T.shadow)
		local mx = x
		hit(mx, y, 8, 3, function() view.open = view.open ~= "menu" and "menu" or nil shop.draw() end)
		header.menu = { x = mx, items = hidden }
	end
	for i = #items, 1, -1 do
		local it = items[i]
		x = x - GAP - BW
		button(x, y, BW, it[1], it[2], it[3], it[4])
	end
	-- счёт
	x = x - GAP - ACC
	box(x, y, ACC, 3, T.surf, T.bg, nil, nil, T.flatShadow)
	local ax = x + 2
	text(ax, y + 1, who, T.text, T.surf)
	ax = ax + ulen(who) + 3
	text(ax, y + 1, mStr, T.money, T.surf)
	ax = ax + ulen(mStr) + 3
	text(ax, y + 1, rStr, T.res, T.surf)
	-- поиск - всё, что осталось слева
	local sx, sw = left, x - GAP - left
	local q = adm and admin.query() or view.query
	box(sx, y, sw, 3, T.raised, T.bg, nil, nil, T.flatShadow)
	gfx.draw(ICON.lens, sx + 2, y, { [0] = T.raised, [1] = q ~= "" and T.text or T.dim })
	if not adm then hit(sx, y, sw, 3, function() if view.screen ~= "grid" then shop.back() end end) end
	if q == "" then
		local hint = adm and "Игрок или журнал" or "Поиск — начни печатать"
		text(sx + 8, y + 1, clip(hint, sw - 10), T.faint, T.raised)
	else
		local count = (not adm and view.screen == "grid") and plural(#shown, "товар", "товара", "товаров") or ""
		local room2 = sw - 14 - ulen(count)
		text(sx + 8, y + 1, clip(q, room2), T.text, T.raised)
		text(sx + 8 + min(ulen(q), room2), y + 1, "▏", T.acc, T.raised)
		if count ~= "" then text(sx + sw - 5 - ulen(count), y + 1, count, T.faint, T.raised) end
		text(sx + sw - 3, y + 1, "×", T.dim, T.raised)
		hit(sx + sw - 5, y, 5, 3, function() if adm then admin.clear() else shop.search("") end end)
	end
end

local function headerMenu()
	if view.open ~= "menu" or not header.menu then return end
	local list = {}
	for _, it in ipairs(header.menu.items) do list[#list + 1] = { it.menu, nil, it[4] } end
	local w = 26
	menu(header.menu.x + 8 - w, 6, w, list, nil)
end

-- ------------------------------------------------------------------ подвал и сообщения

local function footerText()
	local ok, why = wallet.ok()
	if not ok then return why, T.red end
	if ADMINS[nick] and cat and cat:missing() then
		return "нет второго диска с " .. cat.path2 .. " - часть иконок не видна", T.red
	end
	if not nick then return "", T.dim end
	if rules.testMode() then return "Покупки временно закрыты, остальное работает", T.warn end
	if view.screen == "admin" then return "Панель владельца: всё, что здесь меняется, пишется в журнал", T.faint end
	if view.screen == "item" then return "Предмет придёт сразу в инвентарь. Не влезет — разницу вернём на счёт", T.faint end
	if view.screen == "cash" then return "Монеты придут в инвентарь. Не влезут все — остаток останется на счёте", T.faint end
	if view.screen == "sell" then return "Сдаётся всё подходящее из инвентаря разом", T.faint end
	return "Монеты можно положить и забрать обратно. Ресурсы из скупки — только на покупки", T.faint
end

local function drawFooter()
	fill(1, H, W, 1, T.bg)
	local s, col = footerText()
	text(M, H, clip(s, W - 2 * M - 20), col, T.bg)
	if view.screen == "grid" then
		pager(W - M + 1, H, view.page, pages, function(p) shop.turn(p - view.page) end)
	end
end

local function drawToast()
	if not toast.title or view.screen == "idle" then return end
	local w = min(W - 2 * M, max(40, ulen(toast.title) + 12, ulen(toast.sub or "") + 12))
	local x, y = W - M + 1 - w, H - 6
	box(x, y, w, 4, T.raised, T.bg, nil, nil, T.shadow)
	local c = toast.kind == "ok" and T.ok or toast.kind == "err" and T.red
		or toast.kind == "warn" and T.warn or T.line
	gfx.draw(gfx.BADGE[toast.kind] or gfx.BADGE.wait, x + 2, y + 1, { [0] = T.raised, [1] = c, [2] = 0xFFFFFF })
	text(x + 8, y + 1, clip(toast.title, w - 10), T.text, T.raised)
	if toast.sub then text(x + 8, y + 2, clip(toast.sub, w - 10), toast.subColour or T.dim, T.raised) end
end

-- ------------------------------------------------------------------ витрина

-- Карточка подстраивается под размер иконок каталога: 32x32 во всю ширину
-- карточки, 16x16 - с полями по бокам.
local IW, IH = cat and cat.iw or 16, cat and cat.ih or 8
local CW = max(IW + 4, 24)
local CH = IH + 4         -- иконка, название, цена, нижний край
local SORTS = { { "name", "По названию" }, { "cheap", "Сначала дешёвые" }, { "dear", "Сначала дорогие" } }

--- Карточка: картинка, название, цена и сколько есть. У товаров только за
--- деньги вместо числа - пометка об этом.
local function drawCard(e, x, y)
	local b = T.surf
	box(x, y, CW, CH, b, T.bg, nil, nil, T.flatShadow)
	drawIcon(e, x + floor((CW - IW) / 2), y + 1, b)
	text(x + 2, y + CH - 3, clip(e.label, CW - 4), T.text, b)
	local price = unitText(e)
	text(x + 2, y + CH - 2, price, T.money, b)
	local only = rules.moneyOnly(e.key)
	local tag = only and ("только за " .. SIGN) or (num(e.size) .. " шт")
	local room = CW - 5 - ulen(price)
	if room >= 3 then
		tag = clip(tag, room)
		text(x + CW - 2 - ulen(tag), y + CH - 2, tag, only and T.money or T.faint, b)
	end
end

--- Сколько карточек в ряд и где стоит каждая: слоты делят ширину поровну.
local function slots()
	local cols = max(1, floor((W - 2 * M + 1 + GAP) / (CW + GAP)))
	local ws = gfx.split(W - 2 * M + 1, cols, GAP)
	local xs, x = {}, M
	for i = 1, cols do
		xs[i] = x + floor((ws[i] - CW) / 2)
		x = x + ws[i] + GAP
	end
	return xs
end

local function drawGrid()
	fill(1, 6, W, H - 6, T.bg)
	local ty, sortW = 6, 20
	local list = {}
	local active = 1
	for i, t in ipairs(tabs) do
		list[i] = { name = t.name, n = t.n, fn = function() shop.setTab(t.id) end }
		if t.id == view.tab then active = i end
	end
	local hidden, mx, mw = tabRow(M, ty, W - 2 * M + 1 - sortW - GAP, list, active, "more")
	-- сортировка - тоже список, справа в той же строке
	local sx = W - M + 1 - sortW
	gfx.rule(sx - GAP, ty + 1, sortW + GAP, T.name == "dark" and T.raised or T.line, T.bg)
	local sname = SORTS[1][2]
	for _, s in ipairs(SORTS) do if s[1] == view.sort then sname = s[2] end end
	local sl = "↕ " .. sname .. " ▾"
	text(sx + sortW - ulen(sl), ty, sl, view.open == "sort" and T.text or T.dim, T.bg)
	hit(sx, ty, sortW, 2, function() view.open = view.open ~= "sort" and "sort" or nil shop.draw() end)

	local xs = slots()
	local gy = 9
	local cols = #xs
	local rows = max(1, floor((H - gy + 1) / (CH + 1)))
	local per = cols * rows
	pages = max(1, ceil(#shown / per))
	if view.page > pages then view.page = pages end
	if view.page < 1 then view.page = 1 end

	if #shown == 0 then
		local msg = view.query ~= "" and ("По запросу «" .. view.query .. "» ничего нет") or "Витрина пока пустая"
		text(floor((W - ulen(msg)) / 2) + 1, gy + 8, msg, T.dim, T.bg)
		if stockErr and ADMINS[nick] then
			text(floor((W - ulen(stockErr)) / 2) + 1, gy + 10, clip(stockErr, W - 4), T.faint, T.bg)
		end
	else
		local first = (view.page - 1) * per
		for n = 1, per do
			local e = shown[first + n]
			if not e then break end
			local cx = xs[(n - 1) % cols + 1]
			local cy = gy + floor((n - 1) / cols) * (CH + 1)
			drawCard(e, cx, cy)
			hit(cx, cy, CW, CH, function() shop.open(e) end)
		end
	end
	return hidden, mx, mw
end

local function openLists(hidden, mx, mw)
	if view.open == "more" and hidden and #hidden > 0 then
		local items, wd = {}, 24
		for _, t in ipairs(hidden) do
			items[#items + 1] = { t.name, t.n, t.fn }
			wd = max(wd, ulen(t.name) + ulen(num(t.n or 0)) + 8)
		end
		menu(mx + mw - wd, 8, wd, items, nil)
	elseif view.open == "sort" then
		local items, sel = {}, 1
		for i, s in ipairs(SORTS) do
			items[i] = { s[2], nil, function() view.sort, view.page = s[1], 1 shop.draw() end }
			if s[1] == view.sort then sel = i end
		end
		menu(W - M + 1 - 24, 8, 24, items, sel)
	end
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

local function backRow(trail)
	local y = 6
	fill(1, y, W, 2, T.bg)
	pill(M, y, "‹ Назад", T.text, T.raised, T.bg)
	hit(M, y, 11, 1, function() shop.back() end)
	text(M + 13, y, clip(trail, W - M - 14), T.faint, T.bg)
	underline(y)
end

-- колонка справа от крупной иконки
local IX = M + 68 + GAP + 2
local IWD = W - M + 1 - IX

-- что нарисовано на экране товара и снятия: для перерисовки куска
local shownPart = {}

--- Количество, итог и кнопки оплаты. part - поменялось только число:
--- перерисовываются число, итог и подписи, кнопки - если стали
--- доступны или недоступны. Так смена количества - пара десятков вызовов,
--- они идут повтором прямо на экран.
local function drawItemQty(part)
	local e = view.item
	local x, w = IX, IWD
	if not part then
		fill(x, 19, w, 15, T.bg)
		text(x, 19, "Количество", T.dim, T.bg)
		shownPart = { value = stepper(x, 20, w, { 1, 10, 64 }, function() return view.qty end, shop.setQty,
			function() return maxQty(view.item) end, "шт") }
	else
		shownPart.value()
	end
	local only = rules.moneyOnly(e.key)
	local total = totalOf(e, view.qty)
	fill(x, 25, w, 2, T.bg)
	text(x, 25, "Итого", T.dim, T.bg)
	text(x + 7, 25, only and money(total) or (money(total) .. "   или   " .. resm(total)), T.text, T.bg)
	local inStock = view.qty >= 1 and view.qty <= e.size
	if not inStock then text(x, 26, "Есть только " .. num(e.size) .. " шт.", T.red, T.bg) end

	local bw = gfx.split(w, 2, GAP)
	local testMode = rules.testMode()
	local function pay(bx, bwid, kind)
		local have = kind == "r" and balR or balM
		local fmt = kind == "r" and resm or money
		local ok = inStock and total <= have and not testMode
		if not part or shownPart[kind] ~= ok then
			button(bx, 28, bwid, kind == "r" and "Купить за ресурсы" or "Купить за деньги",
				kind == "r" and T.blue or T.primary, kind == "r" and ICON.crate or ICON.coin, nil, not ok)
			if not ok and bx then fill(bx + 2, 31, bwid - 2, 1, T.bg) end
			shownPart[kind] = ok
		end
		-- область клика есть всегда: shop.buy сам проверит, хватает ли
		hit(bx, 28, bwid, 3, function() shop.buy(kind) end)
		local s, c
		if testMode then s, c = "Покупки временно закрыты", T.warn
		elseif total > have then s, c = "Не хватает " .. fmt(total - have), T.red
		else s, c = "Останется " .. fmt(have - total), T.faint end
		fill(bx, 32, bwid, 1, T.bg)
		text(bx + 1, 32, clip(s, bwid - 2), c, T.bg)
	end
	pay(x, bw[1], "m")
	if only then
		if not part then button(x + bw[1] + GAP, 28, bw[2], "Только за деньги", T.off, ICON.crate, nil, true) end
	else
		pay(x + bw[1] + GAP, bw[2], "r")
	end
end

local function drawItem()
	local e = view.item
	fill(1, 6, W, H - 6, T.bg)
	backRow("Все  ›  " .. modName(e.mod))

	-- крупная иконка: полублочные вдвое, брайлевые как есть, по центру
	box(M, 9, 68, 34, T.surf, T.bg, nil, nil, T.flatShadow)
	local scale = (not e.rec.braille and IW * 2 <= 64) and 2 or 1
	drawIcon(e, M + floor((68 - IW * scale) / 2), 9 + floor((34 - IH * scale) / 2), T.surf, scale)

	local x, w = IX, IWD
	text(x, 9, clip(unicode.upper(modName(e.mod)), w), T.acc, T.bg)
	text(x, 10, clip(e.label, w), T.text, T.bg)
	text(x, 11, clip(e.key, w), T.faint, T.bg)
	if rules.moneyOnly(e.key) then
		text(x, 12, "Только за деньги", T.money, T.bg)
	elseif e.mixed then
		text(x, 12, clip("Заряд у штук разный — первыми выдаём самые целые", w), T.dim, T.bg)
	end
	local tw = gfx.split(w, 4, GAP)
	local tx = x
	local tl = {
		{ "Цена за шт.", unitText(e), T.money },
		{ "В наличии", num(e.size) .. " шт", T.text },
		{ "Твои деньги", money(balM), T.money },
		{ "Твои ресурсы", resm(balR), T.res },
	}
	for i, t in ipairs(tl) do
		tile(tx, 14, tw[i], t[1], t[2], t[3])
		tx = tx + tw[i] + GAP
	end
	drawItemQty()
end

-- ------------------------------------------------------------------ снятие

local function coinCents() return COIN_VALUE * 100 end

--- Сколько монет можно снять: хватает на счету, есть в МЭ, влезет.
local function maxCash()
	return max(0, min(floor(balM / coinCents()), coinsInMe, 64 * store:freeSlots()))
end

local CASH_W = 76
local function cashX() return M + floor((W - 2 * M + 1 - CASH_W) / 2) end

local function drawCashQty(part)
	local x, w = cashX(), CASH_W
	if not part then
		fill(x, 17, w, 13, T.bg)
		text(x, 17, "Сколько монет", T.dim, T.bg)
		shownPart = { value = stepper(x, 18, w, { 1, 10, 64, 640 }, function() return view.qty end,
			shop.setCash, maxCash) }
		hit(x, 26, w, 3, function() shop.withdraw() end)
	else
		shownPart.value()
	end
	local cost = view.qty * coinCents()
	fill(x, 23, w, 1, T.bg)
	text(x, 23, "Спишется", T.dim, T.bg)
	text(x + 10, 23, money(cost), T.money, T.bg)
	local ok = view.qty >= 1 and cost <= balM and view.qty <= coinsInMe
	local s, c
	if cost > balM then s, c = "На счёте столько нет", T.red
	elseif view.qty > coinsInMe then s, c = "В кассе только " .. coins(coinsInMe), T.red
	else s, c = "останется " .. money(balM - cost), T.faint end
	text(x + 12 + ulen(money(cost)), 23, s, c, T.bg)
	-- надпись на кнопке - число монет, поэтому она перерисовывается всегда
	button(x, 26, w, "Снять " .. coins(view.qty), T.green, ICON.withdraw, nil, not ok)
	if not ok then fill(x + 2, 29, w - 2, 1, T.bg) end
end

local function drawCash()
	fill(1, 6, W, H - 6, T.bg)
	backRow("Снять деньги")
	local x, w = cashX(), CASH_W
	text(x, 9, "Снять деньги", T.text, T.bg)
	text(x, 10, clip("1 монета = " .. money(coinCents()) .. ". Ресурсы снять нельзя, только потратить", w), T.faint, T.bg)
	local tw = gfx.split(w, 2, GAP)
	tile(x, 12, tw[1], "На счёте", money(balM), T.money)
	tile(x + tw[1] + GAP, 12, tw[2], "Монет в кассе", num(coinsInMe), T.text)
	drawCashQty()
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
	fill(1, 6, W, H - 6, T.bg)
	backRow("Скупка")
	local L, lw = M, 72
	local R = L + lw + GAP + 4
	local rw = W - M + 1 - R
	text(L, 9, "У тебя с собой", T.text, T.bg)
	text(L, 10, clip(("За сданное — ресурсы на счёт (курс %d%%). Ими платят за товары, снять их нельзя")
		:format(rules.rate()), lw), T.faint, T.bg)

	-- слева: что игрок может сдать сейчас
	local have, total = sellable(), 0
	local maxRows = H - 12 - 9
	local rows = max(1, min(#have, maxRows))
	box(L, 12, lw, rows + 2, T.surf, T.bg, nil, nil, T.flatShadow)
	for i, g in ipairs(have) do
		local v = g.qty * g.unit
		total = total + v
		if i <= maxRows then
			local y = 12 + i
			text(L + 2, y, clip(g.label, 36), T.text, T.surf)
			text(L + 40, y, "×" .. num(g.qty), T.dim, T.surf)
			local s = resm(floor(v + 1e-6))
			text(L + lw - 2 - ulen(s), y, s, T.res, T.surf)
		end
	end
	if #have == 0 then
		text(L + 2, 13, "Сдавать нечего — возьми что-нибудь из списка справа", T.dim, T.surf)
	end
	total = floor(total + 1e-6)
	local by = 12 + rows + 3
	text(L, by, "Получишь", T.dim, T.bg)
	text(L + 10, by, resm(total), T.res, T.bg)
	button(L, by + 2, lw, "Сдать всё", T.blue, ICON.crate, function() shop.sell() end, total <= 0)

	-- справа: что скупаем и почём, по названию
	local list = {}
	for _, k in ipairs(rules.list("res")) do
		local rec = cat and cat:get(k)
		list[#list + 1] = { rec = rec and rec.price > 0 and rec or nil, label = rec and labelOf(rec) or k }
	end
	table.sort(list, function(a, b) return a.label < b.label end)
	text(R, 9, "Принимаем", T.text, T.bg)
	text(R + 10, 9, num(#list), T.faint, T.bg)
	local per = H - 16
	local count = max(1, ceil(#list / per))
	view.sellPage = max(1, min(view.sellPage, count))
	local shownN = min(per, #list - (view.sellPage - 1) * per)
	box(R, 11, rw, max(1, shownN) + 2, T.surf, T.bg, nil, nil, T.flatShadow)
	for i = 1, shownN do
		local it = list[(view.sellPage - 1) * per + i]
		local y = 11 + i
		if it.rec then
			text(R + 2, y, clip(it.label, rw - 22), T.text, T.surf)
			local s = buyInText(buyIn(it.rec)) .. " за шт."
			text(R + rw - 2 - ulen(s), y, s, T.res, T.surf)
		else
			text(R + 2, y, clip(it.label, rw - 22), T.faint, T.surf)
			text(R + rw - 2 - ulen("не принимаем"), y, "не принимаем", T.faint, T.surf)
		end
	end
	pager(W - M + 1, 11 + shownN + 3, view.sellPage, count, function(p)
		view.sellPage = max(1, min(count, p))
		shop.draw()
	end)
end

-- ------------------------------------------------------------------ ожидание

local teaser = {}

local function pickTeaser()
	teaser = {}
	local pool = {}
	for i = 1, #stock do if stock[i].rec.icon ~= 0 then pool[#pool + 1] = stock[i] end end
	for _ = 1, min(#slots(), #pool) do
		teaser[#teaser + 1] = table.remove(pool, math.random(#pool))
	end
end

local function drawIdle()
	fill(1, 1, W, H, T.bg)
	local title = unicode.upper(TITLE)
	local y = 4
	if gfx.canBig(title) and gfx.bigWidth(title, 3) <= W - 2 * M then
		local tw = gfx.bigWidth(title, 3)
		local tx = floor((W - tw) / 2) + 1
		local stops = T.grad
		gfx.big(tx, y, title, 3, function(c)
			if T.name ~= "dark" then return T.text end
			local t = c / max(1, tw - 1) * (#stops - 1)
			local i = min(#stops - 1, floor(t) + 1)
			return gfx.mix(stops[i], stops[i + 1], t - (i - 1))
		end, T.bg)
	else
		local spaced = {}
		for i = 1, ulen(title) do spaced[#spaced + 1] = unicode.sub(title, i, i) end
		local t = table.concat(spaced, " ")
		text(floor((W - ulen(t)) / 2) + 1, y + 5, t, T.acc, T.bg)
	end
	local sub = "Платишь монетами или ресурсами, сданными в скупку"
	text(floor((W - ulen(sub)) / 2) + 1, 17, sub, T.dim, T.bg)
	local bw = 44
	gfx.button(floor((W - bw) / 2) + 1, 19, bw, "Встань на платформу, чтобы войти", T.primary, T.bg, nil, T.shadow)

	local _, why = wallet.ok()
	local err = why or stockErr
	if rules.testMode() then
		local tag = "Покупки временно закрыты"
		pill(floor((W - ulen(tag) - 4) / 2) + 1, 23, tag, 0x000000, T.warn, T.bg)
	end
	if err then
		text(floor((W - ulen(err)) / 2) + 1, 25, clip(err, W - 4), T.red, T.bg)
	elseif #teaser > 0 then
		local xs = slots()
		for i = 1, #teaser do drawCard(teaser[i], xs[i], 25) end
		local s = plural(#stock, "товар", "товара", "товаров") .. " в наличии"
		text(floor((W - ulen(s)) / 2) + 1, min(H, 25 + CH + 1), s, T.faint, T.bg)
	end
end

-- ------------------------------------------------------------------ отрисовка

function shop.draw()
	hits = {}
	gfx.begin()
	if view.screen == "idle" then
		drawIdle()
	else
		-- шапка первой: её области клика - под списками, которые рисуются
		-- последними и поверх
		local hidden, mx, mw
		if view.screen == "grid" then choose() end
		drawHeader()
		if view.screen == "item" then drawItem()
		elseif view.screen == "cash" then drawCash()
		elseif view.screen == "sell" then drawSell()
		elseif view.screen == "admin" then
			fill(1, 6, W, H - 6, T.bg)
			admin.draw()
		else hidden, mx, mw = drawGrid() end
		drawFooter()
		drawToast()
		openLists(hidden, mx, mw)
		headerMenu()
		if view.screen == "admin" then admin.overlay() end
	end
	gfx.show()
end

--- Перерисовать кусок: области клика остаются прежними.
local function redrawPart(fn)
	noHits = true
	gfx.begin()
	fn()
	drawToast()
	gfx.show()
	noHits = false
end

--- Сообщение сразу, поверх кадра: «Выдаю…» пока идёт выдача. Весь кадр
--- ради него не перерисовывается - повтор на экране стоит пару вызовов.
function shop.say(title, kind, sub, secs)
	if view.screen == "idle" then return end
	toast.title, toast.sub, toast.kind = title, sub, kind or "wait"
	toast.subColour = nil
	toast.till = computer.uptime() + (secs or 6)
	gfx.begin()
	drawToast()
	gfx.show()
end

--- Итог операции: покажется со следующим кадром.
local function note(title, kind, sub, subColour)
	toast.title, toast.sub, toast.kind, toast.subColour = title, sub, kind, subColour
	toast.till = computer.uptime() + 8
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
	view.tab, view.page, view.open = id, 1, nil
	shop.draw()
end

function shop.search(q)
	view.query, view.page, view.screen, view.item, view.open = q, 1, "grid", nil, nil
	shop.draw()
end

function shop.open(e)
	view.screen, view.item, view.qty, view.open = "item", e, 1, nil
	shop.draw()
end

function shop.back()
	view.screen, view.item, view.open = "grid", nil, nil
	shop.draw()
end

function shop.toShop()
	view.screen, view.item, view.open = "grid", nil, nil
	shop.draw()
end

function shop.setQty(n)
	local e = view.item
	if not e then return end
	local q = max(1, min(floor(n), max(1, e.size)))
	if q == view.qty then return end
	view.qty = q
	redrawPart(function() drawItemQty(true) end)
end

function shop.openCash()
	balM, balR = wallet.get(nick)
	refresh()
	view.screen, view.item, view.qty, view.open = "cash", nil, 1, nil
	shop.draw()
end

function shop.setCash(n)
	local q = max(1, floor(n))
	if q == view.qty then return end
	view.qty = q
	redrawPart(function() drawCashQty(true) end)
end

function shop.openSell()
	balM, balR = wallet.get(nick)
	view.inv = store:slotsOfPlayer()
	if cat then cat:resolve(rules.list("res")) end
	view.screen, view.item, view.sellPage, view.open = "sell", nil, 1, nil
	shop.draw()
end

function shop.openAdmin()
	if not ADMINS[nick] then return end
	admin.open()
	view.screen, view.item, view.open = "admin", nil, nil
	shop.draw()
end

--- Тема: тёмная <-> светлая, выбор запоминается на диске данных.
function shop.toggleTheme()
	T = T.name == "dark" and theme.light or theme.dark
	view.open = nil
	if nick and not theme.save(nick, T) then
		note("Тема включена до выхода", "warn", "Запомнить её негде: нет диска данных")
	end
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
	if not ok then shop.say("Счета недоступны", "err", why) return false end
	return true
end

--- Забрать у игрока стопки без NBT, которые выбирает pick(it) - он
--- возвращает цену штуки в сотых и название или nil. Возвращает по
--- каждому предмету, сколько ушло из инвентаря (pushed) и сколько из этого
--- действительно пришло в МЭ (n); зачислять можно только n.
local function intake(pick)
	local slotsNow = store:slotsOfPlayer()
	local plan, list = {}, {}
	for s = 1, store.slots do
		local it = slotsNow[s]
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
	if not before then return nil, "Магазин не ответил, попробуй ещё раз" end
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
	note("Счёт не записался", "err", "Всё принятое вернули в инвентарь")
	return false
end

function shop.deposit()
	if not ready() then return end
	if not wallet.writable(nick) then shop.say("Не могу записать счёт", "err", "Приём закрыт — напиши владельцу") return end
	shop.say("Принимаю монеты…", "wait")
	local got, err = intake(function(it)
		if it.id == COIN.id and it.dmg == COIN.dmg then return coinCents(), "монеты" end
	end)
	if not got then shop.say(err, "err") return end
	local g = got[1]
	if not g then shop.say("В инвентаре нет монет", "err") return end
	if g.pushed <= 0 then
		note("Касса не принимает монеты", "err", "Напиши владельцу магазина")
	elseif g.n <= 0 then
		note("Монеты не дошли", "err", "Счёт не изменился")
	else
		local cents = g.n * coinCents()
		if credit(cents, 0, got, "пополнение") then
			wallet.log(("%s пополнил: %s монет → +%s  %s"):format(nick, num(g.n), money(cents), accounts()))
			note("+" .. money(cents) .. " на счёт", "ok", "Принято " .. coins(g.n))
		end
	end
	refresh()
	shop.draw()
end

function shop.sell()
	if not ready() then return end
	if not wallet.writable(nick) then shop.say("Не могу записать счёт", "err", "Скупка закрыта — напиши владельцу") return end
	shop.say("Принимаю ресурсы…", "wait")
	local got, err = intake(function(it)
		if not cat then return nil end
		local rec = recOf(it.id, it.dmg)
		if rec and rec.price > 0 and rules.accepts(rec.key) then return buyIn(rec), labelOf(rec) end
	end)
	if not got then shop.say(err, "err") return end
	if #got == 0 then shop.say("Нечего сдавать", "err", "Подходящих ресурсов в инвентаре нет") return end
	local cents, parts = 0, {}
	for _, g in ipairs(got) do
		if g.n > 0 then
			cents = cents + g.n * g.unit
			parts[#parts + 1] = g.label .. " ×" .. num(g.n)
		end
	end
	cents = floor(cents + 1e-6)
	if #parts == 0 then
		note("Ресурсы не дошли", "err", "Счёт не изменился")
	elseif credit(0, cents, got, "скупка") then
		wallet.log(("%s сдал в скупку: %s → +%s  %s"):format(nick, table.concat(parts, ", "), resm(cents), accounts()))
		note("+" .. resm(cents) .. " за сданное", "ok", table.concat(parts, ", "))
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
	if rules.testMode() then shop.say("Покупки временно закрыты", "err") return end
	if kind == "r" and rules.moneyOnly(e.key) then return end
	local qty = view.qty
	local cost = totalOf(e, qty)
	balM, balR = wallet.get(nick)
	if cost > (kind == "r" and balR or balM) or qty > e.size then shop.draw() return end
	if store:freeSlots() == 0 then
		shop.say("Инвентарь забит", "err", "Освободи место и попробуй снова")
		return
	end
	-- с какого счёта: деньги dm или ресурсы dr
	local function part(v) if kind == "r" then return 0, v end return v, 0 end
	-- сначала списать и записать на диск, потом выдавать: выключение посреди
	-- выдачи не должно оставить предмет бесплатным
	local m, r = wallet.add(nick, part(-cost))
	if not m then shop.say("Не вышло списать", "err", "Попробуй ещё раз") return end
	balM, balR = m, r
	shop.say("Выдаю…", "wait", e.label .. " ×" .. num(qty))
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
		note("Ничего не выдано", "err", "Нет места или товар кончился. Деньги на месте")
	elseif sent < qty then
		note(("Выдано %s из %s"):format(num(sent), num(qty)), "warn", "Остальное не влезло, разницу вернули на счёт")
	else
		note("Куплено: " .. e.label .. " ×" .. num(sent), "ok", "−" .. fmt(paid), kind == "r" and T.res or T.money)
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
		shop.say("Инвентарь забит", "err", "Освободи место и попробуй снова")
		return
	end
	-- тот же порядок, что у покупки: списать, выдать, недоданное вернуть
	local m, r = wallet.add(nick, -cost, 0)
	if not m then shop.say("Не вышло списать", "err", "Попробуй ещё раз") return end
	balM, balR = m, r
	shop.say("Выдаю монеты…", "wait")
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
		note("Монеты не выданы", "err", "Нет места или касса пуста. Деньги на счёте")
	elseif sent < n then
		note(("Выдано %s из %s"):format(num(sent), coins(n)), "warn", "Остальное осталось на счёте")
	else
		note("Выдано " .. coins(sent), "ok", "−" .. money(sent * coinCents()), T.money)
	end
	shop.draw()
end

local function login(name)
	if not name or name == nick then return end
	nick = name
	T = theme.of(nick)
	balM, balR = wallet.get(nick)
	view.screen, view.tab, view.query, view.page, view.item, view.open = "grid", nil, "", 1, nil, nil
	toast.title = nil
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
	T = theme.dark
	view.screen, view.item, view.query, view.inv, view.open = "idle", nil, "", nil, nil
	toast.title = nil
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
	W = W, H = H, M = M, GAP = GAP,
	theme = function() return T end,
	hit = hit, button = button, tile = tile, stepper = stepper, menu = menu,
	tabs = tabRow, pager = pager, num = num, plural = plural,
	money = money, resm = resm, buyIn = buyIn, buyInText = buyInText,
	store = store, cat = cat, recOf = cat and recOf, labelOf = labelOf,
	nick = function() return nick end,
	present = function() return present() end,
	reload = function() if nick then balM, balR = wallet.get(nick) end end,
	draw = function() shop.draw() end,
	say = function(title, kind, sub) shop.say(title, kind, sub) end,
	note = note,
	part = function(fn) redrawPart(fn) end,
	-- обновление подменяет каталог: открытый файл не стереть
	release = function() if cat then pcall(cat.close, cat) end end,
	toShop = function() shop.toShop() end,
	open = function() return view.open end,
	setOpen = function(k) view.open = k end,
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
	-- мимо всего - открытый список закрывается
	if view.open then
		view.open = nil
		shop.draw()
	end
end

local handlers = {}

function handlers.player_on(...) login(nickFrom(...)) end
function handlers.player_off() logout() end

function handlers.touch(_, x, y, _, who)
	if nick and who and who ~= nick then
		shop.say("Магазин занят", "err", "Сейчас покупает " .. nick, 4)
		return
	end
	if nick then click(floor(x), floor(y)) end
end

function handlers.scroll(_, _, _, dir, who)
	if not nick or (who and who ~= nick) then return end
	if view.screen == "admin" then admin.scroll(dir) return end
	if view.screen == "sell" then
		view.sellPage = max(1, view.sellPage - dir)
		shop.draw()
		return
	end
	if view.screen ~= "grid" then return end
	shop.turn(dir > 0 and -1 or 1)
end

--- Печатать можно с любого экрана: буквы сразу идут в поиск. В админке -
--- в её поиск. Esc сначала закрывает открытый список.
function handlers.key_down(_, ch, code, who)
	if not nick or (who and who ~= nick) or view.screen == "idle" then return end
	if code == 1 and view.open then
		view.open = nil
		shop.draw()
		return
	end
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
		if toast.title and toast.till < wake then wake = toast.till end
		local sig = table.pack(computer.pullSignal(max(0.05, wake - now)))
		local h = sig[1] and handlers[sig[1]]
		if h then h(table.unpack(sig, 2, sig.n)) end

		now = computer.uptime()
		if toast.title and now >= toast.till then
			toast.title = nil
			shop.draw()
		end
		if now >= nextScan then
			-- пока игрок выбирает количество, выдачу под ним не трогаем
			if (view.screen == "grid" and not view.open) or view.screen == "idle" then
				refresh()
				if view.screen == "idle" then pickTeaser() end
				shop.draw()
			end
			nextScan = now + (nick and 30 or 60)
		end
	end
end

return shop
