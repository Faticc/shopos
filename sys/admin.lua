-- admin - панель владельца магазина прямо на экране машины.
--
-- Открывается сама, когда на PIM встаёт ник из admins в cfg/shop.cfg (по
-- умолчанию Fatic). «В МАГАЗИН» - обычная витрина, «АДМИН» в шапке -
-- обратно. Вкладки:
--   Скупка - курс скупки, что скупается и что продаётся только за деньги.
--            Предмет кладётся в инвентарь и включается кнопкой в строке;
--            убирается крестиком в списке справа;
--   Игроки - счета всех, кто заходил; клик по игроку - правка его денег и
--            ресурсов и его последние записи в журнале. Печать с
--            клавиатуры ищет игрока, по нику, которого ещё нет, можно
--            открыть счёт;
--   Журнал - последние записи, новые сверху; печать - поиск по ним;
--   Обновление - сверка с гитом и загрузка изменившихся файлов, см.
--            update.lua. Переустанавливать систему из OpenOS ради правки
--            пары файлов больше не нужно.
-- Каждое действие админа пишется в журнал с его ником.

local gfx = require("gfx")
local wallet = require("wallet")
local rules = require("rules")
local vault = require("vault")

local computer, unicode = computer, unicode
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local fill, text, pad, clip, button = gfx.fill, gfx.text, gfx.pad, gfx.clip, gfx.button
local ulen = unicode.len

local admin = {}

local ui, C, W, H         -- что даёт shop: цвета, hit, форматы, перерисовка

local st                  -- состояние панели, сбрасывается при выходе

function admin.reset()
	st = {
		tab = "items",         -- items | players | log
		query = "",
		page = 1,
		player = nil,          -- чей счёт открыт на правку
		inv = nil,             -- предметы из инвентаря админа
		nicks = nil,           -- все счета
		cache = {},            -- ник -> { деньги, ресурсы }
		lines = nil,           -- хвост журнала
		resPage = 1, onlyPage = 1,
		confirm = nil,         -- { что, до когда } - обнуление ждёт второго клика
		up = { log = {} },     -- обновление: модуль, список файлов, ход дела
	}
end
admin.reset()

function admin.init(u) ui, C, W, H = u, u.C, u.W, u.H end

function admin.query() return st.query end

local function redraw() ui.draw() end

local function label(key)
	local rec = ui.cat and ui.cat:get(key)
	return rec and ui.labelOf(rec) or key, rec
end

--- Что лежит у админа в инвентаре: по записи каталога, без повторов.
local function readInv()
	local out, by, skipped = {}, {}, 0
	local slots = ui.store:slotsOfPlayer()
	for s = 1, ui.store.slots do
		local it = slots[s]
		if it then
			local rec = ui.recOf and ui.recOf(it.id, it.dmg)
			if rec and rec.price > 0 then
				if not by[rec.key] then
					by[rec.key] = true
					out[#out + 1] = { key = rec.key, rec = rec, label = ui.labelOf(rec) }
				end
			else
				skipped = skipped + 1
			end
		end
	end
	table.sort(out, function(a, b) return a.label < b.label end)
	st.inv, st.skipped = out, skipped
end

function admin.open()
	admin.reset()
	readInv()
end

local function tab(t)
	st.tab, st.page, st.player, st.confirm, st.query = t, 1, nil, nil, ""
	if t == "items" then readInv() end
	if t == "players" then st.nicks, st.cache = nil, {} end
	if t == "log" then st.lines = nil end
	redraw()
end

-- ------------------------------------------------------------------ скупка

local function flip(name, key, what)
	if not ui.present() then return end
	local on, saved = rules.toggle(name, key)
	wallet.log(("АДМИН %s: %s %s %s  [%s]"):format(ui.nick(),
		name == "res" and "скупка" or "только за деньги", on and "+" or "−", what, key))
	if not saved then ui.say("не записалось на диск данных - после перезапуска вернётся как было", C.red) end
	redraw()
end

local function setRate(d)
	if not ui.present() then return end
	local was = rules.rate()
	local now, saved = rules.setRate(was + d)
	if now ~= was then wallet.log(("АДМИН %s: курс скупки %d%% → %d%%"):format(ui.nick(), was, now)) end
	if not saved then ui.say("не записалось на диск данных", C.red) end
	redraw()
end

--- Тестовый режим: покупки закрыты, всё остальное (витрина, поиск,
--- пополнение, скупка, снятие, админка) работает как обычно.
local function setTest()
	if not ui.present() then return end
	local on, saved = rules.setTest(not rules.testMode())
	wallet.log(("АДМИН %s: тестовый режим %s"):format(ui.nick(), on and "включён" or "выключен"))
	if not saved then ui.say("не записалось на диск данных - после перезапуска вернётся как было", C.red) end
	redraw()
end

--- Переключатель в строку: «скупка: да».
local function toggle(x, y, w, on, name, fn)
	text(x, y, pad(name .. (on and ": да" or ": нет"), w, "center"), on and C.black or C.text, on and C.green or C.line)
	ui.hit(x, y, w, 1, fn)
end

--- Список ключей с крестиками и своими страницами.
local function keyList(x, y, rows, title, name, pageField)
	local list = rules.list(name)
	text(x, y, title .. ": " .. #list, C.dim, C.bg)
	local count = max(1, ceil(#list / rows))
	st[pageField] = max(1, min(st[pageField], count))
	for i = 1, rows do
		local k = list[(st[pageField] - 1) * rows + i]
		if not k then break end
		local yy = y + i
		local what, rec = label(k)
		local back = i % 2 == 0 and C.panel or C.bg
		fill(x, yy, 76, 1, back)
		text(x, yy, pad(what, 34), rec and C.text or C.faint, back)
		text(x + 35, yy, pad(k, 36), C.faint, back)
		text(x + 73, yy, " × ", C.white, C.red)
		ui.hit(x + 73, yy, 3, 1, function() flip(name, k, what) end)
	end
	ui.pager(x + 50, y, st[pageField], count, function(p)
		st[pageField] = p
		redraw()
	end)
end

local function drawItems()
	-- курс скупки
	text(3, 9, "Курс скупки", C.dim, C.bg)
	text(3, 10, rules.rate() .. "% цены", C.gold, C.bg)
	local bx = 17
	for _, d in ipairs({ -10, -1, 1, 10 }) do
		button(bx, 9, 6, 3, (d > 0 and "+" or "") .. d, C.text, C.line)
		ui.hit(bx, 9, 6, 3, function() setRate(d) end)
		bx = bx + 7
	end
	local _, iron = label("minecraft:iron_ingot")
	local example = iron and ("  64 железа → " .. ui.resm(floor(64 * ui.buyIn(iron) + 1e-6))) or ""
	text(bx + 2, 10, clip("ресурс идёт на ресурсный счёт по этому проценту цены из выгрузки" .. example, W - bx - 4), C.faint, C.bg)

	-- слева: инвентарь админа
	local L = 3
	text(L, 13, "Ваш инвентарь: что скупать, что только за деньги", C.dim, C.bg)
	button(L + 76 - 12, 13, 12, 1, "ОБНОВИТЬ", C.text, C.line)
	ui.hit(L + 64, 13, 12, 1, function() readInv() redraw() end)
	local inv = st.inv or {}
	for i, it in ipairs(inv) do
		local y = 14 + i
		if y > H - 3 then break end
		local back = i % 2 == 0 and C.panel or C.bg
		fill(L, y, 76, 1, back)
		text(L, y, pad(it.label, 30), C.text, back)
		text(L + 31, y, pad(ui.buyInText(ui.buyIn(it.rec)), 14), C.accent, back)
		toggle(L + 46, y, 14, rules.accepts(it.key), "скупка", function() flip("res", it.key, it.label) end)
		toggle(L + 61, y, 15, rules.moneyOnly(it.key), "только $", function() flip("only", it.key, it.label) end)
	end
	if #inv == 0 then
		text(L, 15, "инвентарь пуст: положите предмет и нажмите «ОБНОВИТЬ»", C.dim, C.bg)
	end
	if (st.skipped or 0) > 0 then
		text(L, H - 2, ("ещё %d стопок без цены в выгрузке - их нельзя ни скупать, ни продавать"):format(st.skipped), C.faint, C.bg)
	end

	-- справа: списки
	local R = 82
	local half = floor((H - 17) / 2)
	keyList(R, 13, half, "Скупается", "res", "resPage")
	keyList(R, 14 + half + 1, H - 17 - half - 1, "Только за деньги", "only", "onlyPage")
end

-- ------------------------------------------------------------------ игроки

local function nicks()
	if not st.nicks then st.nicks = wallet.list() end
	local q = unicode.lower(st.query)
	if q == "" then return st.nicks end
	local out = {}
	for _, n in ipairs(st.nicks) do
		if unicode.lower(n):find(q, 1, true) then out[#out + 1] = n end
	end
	return out
end

local function balances(n)
	local c = st.cache[n]
	if not c then
		local m, r = wallet.get(n)
		c = { m, r }
		st.cache[n] = c
	end
	return c[1], c[2]
end

local function logLines()
	if not st.lines then st.lines = wallet.tail(48 * 1024) end
	return st.lines
end

local function fmt(kind, cents) return kind == "m" and ui.money(cents) or ui.resm(cents) end

--- Изменить счёт открытого игрока: delta в сотых, nil - обнулить.
local function adjust(kind, delta)
	if not ui.present() then return end
	local n = st.player
	local m, r = wallet.get(n)
	local was = kind == "m" and m or r
	local now = delta and max(0, was + delta) or 0
	if kind == "m" then m = now else r = now end
	if not wallet.set(n, m, r) then
		ui.say("счёт не записался - диск данных?", C.red)
		return
	end
	-- список перечитается: счёт мог открыться только что
	st.cache[n], st.lines, st.confirm, st.nicks = { m, r }, nil, nil, nil
	wallet.log(("АДМИН %s: %s %s %s → %s"):format(ui.nick(), n,
		kind == "m" and "деньги" or "ресурсы", fmt(kind, was), fmt(kind, now)))
	if n == ui.nick() then ui.reload() end
	redraw()
end

local STEPS = { 1000, 100, 10, 1 }   -- в целых монетах

local function drawEditor()
	local n = st.player
	local m, r = wallet.get(n)
	st.cache[n] = { m, r }
	button(3, 9, 16, 3, "◀ К СПИСКУ", C.text, C.line)
	ui.hit(3, 9, 16, 3, function() st.player, st.confirm = nil, nil redraw() end)
	text(22, 10, "Счёт игрока " .. n, C.white, C.bg)

	local function row(y, kind, title, value, colour)
		text(3, y, title, C.dim, C.bg)
		text(3, y + 1, fmt(kind, value), colour, C.bg)
		local bx = 24
		for _, s in ipairs(STEPS) do
			button(bx, y, 8, 3, "-" .. s, C.text, C.line)
			ui.hit(bx, y, 8, 3, function() adjust(kind, -s * 100) end)
			bx = bx + 9
		end
		for i = #STEPS, 1, -1 do
			local s = STEPS[i]
			button(bx, y, 8, 3, "+" .. s, C.text, C.line)
			ui.hit(bx, y, 8, 3, function() adjust(kind, s * 100) end)
			bx = bx + 9
		end
		-- обнуление - вторым кликом в течение 5 секунд
		local armed = st.confirm and st.confirm[1] == kind and computer.uptime() < st.confirm[2]
		button(bx + 1, y, 14, 3, armed and "ТОЧНО?" or "ОБНУЛИТЬ", C.white, armed and C.red or C.blue)
		ui.hit(bx + 1, y, 14, 3, function()
			if armed then adjust(kind, nil)
			else
				st.confirm = { kind, computer.uptime() + 5 }
				redraw()
			end
		end)
	end
	row(13, "m", "деньги", m, C.gold)
	row(18, "r", "ресурсы", r, C.accent)
	text(3, 22, "шаги в целых монетах; каждое изменение сразу пишется на диск и в журнал", C.faint, C.bg)

	-- его последние записи
	text(3, 24, "последние записи о " .. n, C.dim, C.bg)
	local y = 25
	for _, l in ipairs(logLines()) do
		if y > H - 2 then break end
		if l:find(" " .. n .. " ", 1, true) or l:find(" " .. n .. ":", 1, true) then
			text(3, y, clip(l, W - 5), l:find("АДМИН", 1, true) and C.gold or C.text, C.bg)
			y = y + 1
		end
	end
	if y == 25 then text(3, 25, "записей нет", C.faint, C.bg) end
end

local function drawPlayers()
	local ok, why = wallet.ok()
	if not ok then
		text(3, 10, why, C.red, C.bg)
		return
	end
	if st.player then return drawEditor() end
	local list = nicks()
	text(3, 9, "Игроков со счётом: " .. ui.num(#st.nicks), C.text, C.bg)
	if st.query ~= "" then
		text(30, 9, ("по «%s» - %d"):format(st.query, #list), C.dim, C.bg)
	else
		text(30, 9, "печатайте ник - найдётся; клик по игроку - правка счёта", C.faint, C.bg)
	end
	-- ника нет - можно открыть ему счёт заранее
	local q = st.query
	if #list == 0 and #q >= 2 and #q <= 16 and q:match("^[%w_]+$") then
		button(3, 12, 40, 3, "ОТКРЫТЬ СЧЁТ " .. q, C.black, C.green)
		ui.hit(3, 12, 40, 3, function() st.player = q redraw() end)
		return
	end

	local rows, cols = H - 14, 2
	local per = rows * cols
	local count = max(1, ceil(#list / per))
	st.page = max(1, min(st.page, count))
	for c = 0, cols - 1 do
		local x = 3 + c * 79
		text(x, 11, pad("игрок", 20), C.dim, C.bg)
		text(x + 21, 11, pad("деньги", 18), C.dim, C.bg)
		text(x + 40, 11, "ресурсы", C.dim, C.bg)
	end
	for i = 1, per do
		local n = list[(st.page - 1) * per + i]
		if not n then break end
		local c = floor((i - 1) / rows)
		local x, y = 3 + c * 79, 12 + (i - 1) % rows
		local m, r = balances(n)
		local back = i % 2 == 0 and C.panel or C.bg
		fill(x, y, 76, 1, back)
		text(x, y, pad(n, 20), C.text, back)
		text(x + 21, y, pad(ui.money(m), 18), C.gold, back)
		text(x + 40, y, ui.resm(r), C.accent, back)
		ui.hit(x, y, 76, 1, function()
			st.player, st.confirm = n, nil
			redraw()
		end)
	end
	ui.pager(floor(W / 2) - 8, H - 1, st.page, count, function(p)
		st.page = p
		redraw()
	end)
end

-- ------------------------------------------------------------------ журнал

local function drawLog()
	local all = logLines()
	local q = unicode.lower(st.query)
	local list = all
	if q ~= "" then
		list = {}
		for _, l in ipairs(all) do
			if unicode.lower(l):find(q, 1, true) then list[#list + 1] = l end
		end
	end
	text(3, 9, q == "" and "Журнал: новые записи сверху" or ("Журнал по «" .. st.query .. "»: " .. #list), C.text, C.bg)
	text(40, 9, clip("печатайте - поиск; весь журнал лежит в " .. wallet.logPath .. " (" .. vault.where .. ")", W - 56), C.faint, C.bg)
	button(W - 13, 9, 12, 1, "ОБНОВИТЬ", C.text, C.line)
	ui.hit(W - 13, 9, 12, 1, function() st.lines = nil redraw() end)
	local rows = H - 13
	local count = max(1, ceil(#list / rows))
	st.page = max(1, min(st.page, count))
	for i = 1, rows do
		local l = list[(st.page - 1) * rows + i]
		if not l then break end
		local colour = C.text
		if l:find("ВНИМАНИЕ", 1, true) then colour = C.red
		elseif l:find("АДМИН", 1, true) then colour = C.gold
		elseif l:find(" вошёл", 1, true) or l:find(" вышел", 1, true) then colour = C.dim end
		text(3, 10 + i, clip(l, W - 5), colour, C.bg)
	end
	if #list == 0 then text(3, 11, "записей нет", C.faint, C.bg) end
	ui.pager(floor(W / 2) - 8, H - 1, st.page, count, function(p)
		st.page = p
		redraw()
	end)
end

-- ------------------------------------------------------------------ обновление

--- Модуль обновления грузится по требованию: на диске, поставленном
--- прежним установщиком, его ещё нет, и вкладка должна сказать об этом, а
--- не уронить магазин.
local function updater()
	if st.up.mod == nil then
		local ok, m = pcall(require, "update")
		st.up.mod = ok and m or false
		if not ok then st.up.err = "нет модуля обновления, нужна переустановка: " .. tostring(m) end
	end
	return st.up.mod or nil
end

local function checkUpdate(force)
	local u = updater()
	if not u then redraw() return end
	st.up.err, st.up.log, st.up.done, st.up.list = nil, {}, nil, nil
	st.up.busy = true
	ui.say("смотрю, что изменилось на гите…", C.dim)
	local list, why = u.check()
	st.up.busy = false
	if not list then st.up.err = why else st.up.list = force and u.forceAll(list) or list end
	redraw()
end

local function applyUpdate()
	local u = updater()
	if not (u and st.up.list) or not ui.present() then return end
	local n = u.pending(st.up.list)
	if n == 0 then return end
	st.up.busy, st.up.log, st.up.err = true, {}, nil
	wallet.log(("АДМИН %s: обновление, файлов %d"):format(ui.nick(), n))
	local done, why = u.apply(st.up.list, function(s)
		local log = st.up.log
		log[#log + 1] = s
		while #log > 8 do table.remove(log, 1) end
		redraw()
	end)
	st.up.busy = false
	if not done then
		st.up.err = why
		wallet.log(("АДМИН %s: обновление не удалось - %s"):format(ui.nick(), tostring(why)))
		redraw()
		return
	end
	st.up.done = done
	wallet.log(("АДМИН %s: обновлено файлов %d, перезагрузка"):format(ui.nick(), done))
	redraw()
	-- новые файлы уже на диске, а в памяти машины прежние: перезагружаемся,
	-- дав прочитать надпись
	local t = computer.uptime() + 3
	while computer.uptime() < t do computer.pullSignal(t - computer.uptime()) end
	computer.shutdown(true)
end

local function drawUpdate()
	local u = updater()
	local busy = st.up.busy
	text(3, 9, "Обновление ShopOS", C.white, C.bg)
	text(3, 10, clip(("качается только изменившееся из %s; счета, журнал и свой cfg/shop.cfg не трогаются")
		:format(u and u.where or "гита"), W - 5), C.faint, C.bg)

	button(3, 12, 16, 3, "ПРОВЕРИТЬ", busy and C.faint or C.black, busy and C.card or C.green)
	if not busy then ui.hit(3, 12, 16, 3, function() checkUpdate(false) end) end
	button(20, 12, 24, 3, "СКАЧАТЬ ВСЁ ЗАНОВО", busy and C.faint or C.text, busy and C.card or C.line)
	if not busy then ui.hit(20, 12, 24, 3, function() checkUpdate(true) end) end

	local sx = 47
	if st.up.err then
		text(sx, 13, clip(st.up.err, W - sx - 2), C.red, C.bg)
	elseif st.up.done then
		text(sx, 13, ("положено файлов %d - перезагрузка…"):format(st.up.done), C.green, C.bg)
	elseif not st.up.list then
		-- «u and u.card()» обрезало бы вторую отдачу: в Lua and даёт одно значение
		local why, known = nil, 0
		if u then
			_, why = u.card()
			for _ in pairs(u.record().files) do known = known + 1 end
		end
		local hint = why or (known > 0
			and ("на диске записано файлов " .. known .. " - нажмите «ПРОВЕРИТЬ»")
			or "записи о версии нет: сверю по хэшам, каталог - по размеру")
		text(sx, 13, clip(hint, W - sx - 2), why and C.red or C.dim, C.bg)
	end

	if not st.up.list then return end

	text(3, 15, pad("файл", 26) .. pad("размер", 11) .. "что с ним", C.dim, C.bg)
	local y = 16
	for i, e in ipairs(st.up.list) do
		if y > H - 14 then break end       -- ниже идут кнопка и ход дела
		local back = i % 2 == 0 and C.panel or C.bg
		fill(3, y, 76, 1, back)
		text(3, y, pad(e.to, 26), e.need and C.text or C.faint, back)
		text(29, y, pad(ui.num(ceil(e.size / 1024)) .. " КБ", 11), e.need and C.text or C.faint, back)
		text(40, y, clip(e.why or "", 38), e.need and C.gold or C.faint, back)
		y = y + 1
	end

	local n, bytes = u.pending(st.up.list)
	local ready = n > 0 and not busy
	local by = y + 1
	button(3, by, 34, 3, busy and "ОБНОВЛЯЮ…" or (n > 0 and "ОБНОВИТЬ И ПЕРЕЗАГРУЗИТЬ" or "ВСЁ И ТАК СВЕЖЕЕ"),
		ready and C.black or C.faint, ready and C.green or C.card)
	if ready then ui.hit(3, by, 34, 3, applyUpdate) end
	if n > 0 then
		text(39, by + 1, clip(("скачать файлов %d, %s КБ; машина перезагрузится сама")
			:format(n, ui.num(ceil(bytes / 1024))), W - 41), C.dim, C.bg)
	end

	local ly = by + 4
	for _, s in ipairs(st.up.log) do
		if ly > H - 2 then break end
		text(3, ly, clip(s, W - 5), C.dim, C.bg)
		ly = ly + 1
	end
end

-- ------------------------------------------------------------------ кадр

function admin.draw()
	fill(1, 4, W, H - 4, C.bg)
	local x = 3
	for _, t in ipairs({ { "items", "Скупка" }, { "players", "Игроки" }, { "log", "Журнал" },
		{ "update", "Обновление" } }) do
		local on = st.tab == t[1]
		local w = ulen(t[2]) + 6
		button(x, 5, w, 3, t[2], on and C.black or C.text, on and C.gold or C.line)
		ui.hit(x, 5, w, 3, function() tab(t[1]) end)
		x = x + w + 1
	end
	-- выключатель магазина: виден с любой вкладки, это не настройка скупки
	local test = rules.testMode()
	local tx, tw = W - 45, 26
	button(tx, 5, tw, 3, test and "ТЕСТ-РЕЖИМ: ВКЛЮЧЁН" or "ТЕСТ-РЕЖИМ: ВЫКЛЮЧЕН",
		test and C.black or C.text, test and C.gold or C.line)
	ui.hit(tx, 5, tw, 3, setTest)
	-- где данные: владельцу это важно знать
	local where = vault.warn or ("данные: " .. vault.where)
	text(x + 2, 6, clip(where, tx - x - 4), vault.warn and C.red or C.faint, C.bg)
	button(W - 17, 5, 16, 3, "В МАГАЗИН ▶", C.black, C.green)
	ui.hit(W - 17, 5, 16, 3, function() ui.toShop() end)

	if st.tab == "items" then drawItems()
	elseif st.tab == "players" then drawPlayers()
	elseif st.tab == "update" then drawUpdate()
	else drawLog() end
end

-- ------------------------------------------------------------------ ввод

function admin.clear()
	st.query, st.page = "", 1
	redraw()
end

--- Клавиатура: буквы - в поиск (игроки или журнал), Backspace - стереть
--- букву или закрыть счёт игрока, Esc - очистить поиск.
function admin.key(ch, code)
	if code == 14 then                                     -- Backspace
		if st.query ~= "" then st.query, st.page = unicode.sub(st.query, 1, -2), 1
		elseif st.player then st.player = nil end
	elseif code == 1 then                                  -- Esc
		if st.player then st.player = nil else st.query, st.page = "", 1 end
	elseif code == 201 then st.page = st.page - 1          -- PgUp
	elseif code == 209 then st.page = st.page + 1          -- PgDn
	elseif ch and ch >= 32 and ulen(st.query) < 24 then
		-- печать - это поиск по игрокам и журналу; со вкладок, где искать
		-- нечего, она уводит к игрокам
		if st.tab == "items" or st.tab == "update" then
			st.tab, st.nicks, st.cache = "players", nil, {}
		end
		st.player, st.page = nil, 1
		st.query = st.query .. unicode.char(ch)
	else
		return
	end
	redraw()
end

function admin.scroll(dir)
	st.page = max(1, st.page - dir)
	redraw()
end

return admin
