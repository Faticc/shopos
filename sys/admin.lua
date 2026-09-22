-- admin - панель владельца магазина прямо на экране машины.
--
-- Открывается сама, когда на PIM встаёт ник из admins в cfg/shop.cfg (по
-- умолчанию Fatic). «Витрина» в шапке - обычный магазин, «Админ» - обратно.
-- Вкладки:
--   Скупка - курс скупки, что скупается и что продаётся только за деньги.
--            Предмет кладётся в инвентарь и включается переключателем в
--            строке; убирается крестиком в списке справа;
--   Игроки - счета всех, кто заходил; клик по игроку - правка его денег и
--            ресурсов и его последние записи в журнале. Печать с
--            клавиатуры ищет игрока, по нику, которого ещё нет, можно
--            открыть счёт;
--   Журнал - последние записи, новые сверху; печать - поиск по ним;
--   Обновление - сверка с гитом и загрузка изменившихся файлов в четыре
--            потока, см. update.lua.
-- Справа в строке вкладок - выключатель тестового режима.
-- Каждое действие админа пишется в журнал с его ником.

local gfx = require("gfx")
local wallet = require("wallet")
local rules = require("rules")
local vault = require("vault")

local computer, unicode = computer, unicode
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local fill, text, clip, box, pill = gfx.fill, gfx.text, gfx.clip, gfx.box, gfx.pill
local ICON = gfx.ICON
local ulen = unicode.len

local admin = {}

local ui, W, H, M, GAP    -- что даёт shop: элементы, форматы, перерисовка
local T                   -- цвета текущей темы

local st                  -- состояние панели, сбрасывается при выходе

function admin.reset()
	st = {
		tab = "items",         -- items | players | log | update
		query = "",
		page = 1,
		player = nil,          -- чей счёт открыт на правку
		inv = nil,             -- предметы из инвентаря админа
		nicks = nil,           -- все счета
		cache = {},            -- ник -> { деньги, ресурсы }
		lines = nil,           -- хвост журнала
		resPage = 1, onlyPage = 1,
		confirm = nil,         -- { что, до когда } - обнуление ждёт второго клика
		up = {},               -- обновление: модуль, список файлов, ход дела
	}
end
admin.reset()

function admin.init(u) ui, W, H, M, GAP = u, u.W, u.H, u.M, u.GAP end

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
	if not saved then ui.note("Не записалось на диск данных", "err", "После перезапуска вернётся как было") end
	redraw()
end

local function setRate(v)
	if not ui.present() then return end
	local was = rules.rate()
	local now, saved = rules.setRate(v)
	if now ~= was then wallet.log(("АДМИН %s: курс скупки %d%% → %d%%"):format(ui.nick(), was, now)) end
	if not saved then ui.note("Не записалось на диск данных", "err") end
	redraw()
end

--- Тестовый режим: покупки закрыты, всё остальное (витрина, поиск,
--- пополнение, скупка, снятие, админка) работает как обычно.
local function setTest()
	if not ui.present() then return end
	local on, saved = rules.setTest(not rules.testMode())
	wallet.log(("АДМИН %s: тестовый режим %s"):format(ui.nick(), on and "включён" or "выключен"))
	if not saved then ui.note("Не записалось на диск данных", "err", "После перезапуска вернётся как было") end
	redraw()
end

--- Переключатель-таблетка: вкл - залит цветом, выкл - серый.
local function toggle(x, y, w, on, name, colour, back, fn)
	local b = on and colour or (T.name == "dark" and T.line or T.bg)
	local s = gfx.pad((on and "✓ " or "  ") .. name, w - 4, "center")
	pill(x, y, s, on and 0x000000 or T.dim, b, back)
	ui.hit(x, y, w, 1, fn)
end

--- Список ключей в плашке: название, ключ, крестик. Свои страницы.
local function keyList(x, y, w, rows, title, name, pageField)
	local list = rules.list(name)
	text(x, y, title, T.text, T.bg)
	text(x + ulen(title) + 1, y, ui.num(#list), T.faint, T.bg)
	local count = max(1, ceil(#list / rows))
	st[pageField] = max(1, min(st[pageField], count))
	ui.pager(x + w - 1, y, st[pageField], count, function(p)
		st[pageField] = max(1, min(count, p))
		redraw()
	end)
	local n = max(1, min(rows, #list - (st[pageField] - 1) * rows))
	box(x, y + 2, w, n + 2, T.surf, T.bg, nil, nil, T.flatShadow)
	if #list == 0 then text(x + 2, y + 3, "пусто", T.faint, T.surf) end
	for i = 1, rows do
		local k = list[(st[pageField] - 1) * rows + i]
		if not k then break end
		local yy = y + 2 + i
		local what, rec = label(k)
		text(x + 2, yy, clip(what, 30), rec and T.text or T.faint, T.surf)
		text(x + 34, yy, clip(k, w - 42), T.faint, T.surf)
		text(x + w - 4, yy, "×", T.red, T.surf)
		ui.hit(x + w - 6, yy, 6, 1, function() flip(name, k, what) end)
	end
end

local function drawItems()
	local L, lw = M, 74
	local R = L + lw + GAP + 4
	local rw = W - M + 1 - R

	-- курс скупки
	text(L, 9, "Курс скупки", T.dim, T.bg)
	ui.stepper(L, 10, 44, { 1, 10 }, rules.rate, setRate, nil, "%")
	local _, iron = label("minecraft:iron_ingot")
	if iron then
		text(L + 47, 10, "64 железа → " .. ui.resm(floor(64 * ui.buyIn(iron) + 1e-6)), T.faint, T.bg)
	end
	text(L + 47, 11, clip(vault.warn or ("данные: " .. vault.where), lw - 47),
		vault.warn and T.red or T.faint, T.bg)

	-- слева: инвентарь админа
	text(L, 15, "Твой инвентарь", T.text, T.bg)
	local rb = "Обновить"
	pill(L + lw - ulen(rb) - 4, 15, rb, T.text, T.name == "dark" and T.line or T.surf, T.bg)
	ui.hit(L + lw - ulen(rb) - 4, 15, ulen(rb) + 4, 1, function() readInv() redraw() end)
	local inv = st.inv or {}
	local rows = H - 17 - 4
	box(L, 17, lw, max(1, min(#inv, rows)) + 2, T.surf, T.bg, nil, nil, T.flatShadow)
	for i, it in ipairs(inv) do
		if i > rows then break end
		local y = 17 + i
		text(L + 2, y, clip(it.label, 28), T.text, T.surf)
		text(L + 31, y, clip(ui.buyInText(ui.buyIn(it.rec)), 12), T.res, T.surf)
		toggle(L + 44, y, 13, rules.accepts(it.key), "скупка", T.ok, T.surf,
			function() flip("res", it.key, it.label) end)
		toggle(L + 58, y, 14, rules.moneyOnly(it.key), "только $", T.warn, T.surf,
			function() flip("only", it.key, it.label) end)
	end
	if #inv == 0 then
		text(L + 2, 18, "Пусто: положи предмет в инвентарь и нажми «Обновить»", T.dim, T.surf)
	end
	if (st.skipped or 0) > 0 then
		text(L, H - 2, clip(("ещё %d стопок без цены в выгрузке - их нельзя ни скупать, ни продавать")
			:format(st.skipped), lw), T.faint, T.bg)
	end

	-- справа: списки
	local half = floor((H - 9 - 10) / 2)
	keyList(R, 9, rw, half, "Скупается", "res", "resPage")
	keyList(R, 9 + half + 5, rw, H - 9 - half - 5 - 5, "Только за деньги", "only", "onlyPage")
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
		ui.say("Счёт не записался", "err", "Проверь диск данных")
		return
	end
	-- список перечитается: счёт мог открыться только что
	st.cache[n], st.lines, st.confirm, st.nicks = { m, r }, nil, nil, nil
	wallet.log(("АДМИН %s: %s %s %s → %s"):format(ui.nick(), n,
		kind == "m" and "деньги" or "ресурсы", fmt(kind, was), fmt(kind, now)))
	if n == ui.nick() then ui.reload() end
	redraw()
end

local function drawEditor()
	local n = st.player
	local m, r = wallet.get(n)
	st.cache[n] = { m, r }
	pill(M, 9, "‹ К списку", T.text, T.raised, T.bg)
	ui.hit(M, 9, 14, 1, function() st.player, st.confirm = nil, nil redraw() end)
	text(M + 16, 9, "Счёт игрока " .. n, T.text, T.bg)

	local function row(y, kind, title, value, colour)
		text(M, y, title, T.dim, T.bg)
		text(M + ulen(title) + 2, y, fmt(kind, value), colour, T.bg)
		local get = function()
			local mm, rr = wallet.get(n)
			return floor((kind == "m" and mm or rr) / 100)
		end
		ui.stepper(M, y + 1, 96, { 1, 10, 100, 1000 }, get,
			function(v) adjust(kind, (v - get()) * 100) end, nil, kind == "m" and "$" or "рес")
		-- обнуление - вторым кликом в течение 5 секунд
		local armed = st.confirm and st.confirm[1] == kind and computer.uptime() < st.confirm[2]
		ui.button(M + 98, y + 1, 22, armed and "Точно обнулить?" or "Обнулить", armed and T.danger or T.grey, nil,
			function()
				if armed then adjust(kind, nil)
				else
					st.confirm = { kind, computer.uptime() + 5 }
					redraw()
				end
			end)
	end
	row(11, "m", "Деньги", m, T.money)
	row(16, "r", "Ресурсы", r, T.res)
	text(M, 21, "Шаги в целых монетах; каждое изменение сразу пишется на диск и в журнал", T.faint, T.bg)

	-- его последние записи
	text(M, 23, "Последние записи о " .. n, T.dim, T.bg)
	local lines = {}
	for _, l in ipairs(logLines()) do
		if l:find(" " .. n .. " ", 1, true) or l:find(" " .. n .. ":", 1, true) then lines[#lines + 1] = l end
		if #lines >= H - 29 then break end
	end
	local w = W - 2 * M + 1
	box(M, 25, w, max(1, #lines) + 2, T.surf, T.bg, nil, nil, T.flatShadow)
	for i, l in ipairs(lines) do
		text(M + 2, 25 + i, clip(l, w - 4), l:find("АДМИН", 1, true) and T.money or T.text, T.surf)
	end
	if #lines == 0 then text(M + 2, 26, "записей нет", T.faint, T.surf) end
end

local function drawPlayers()
	local ok, why = wallet.ok()
	if not ok then
		text(M, 10, why, T.red, T.bg)
		return
	end
	if st.player then return drawEditor() end
	local list = nicks()
	text(M, 9, "Игроков со счётом", T.text, T.bg)
	text(M + 18, 9, ui.num(#st.nicks), T.faint, T.bg)
	if st.query ~= "" then
		text(M + 26, 9, ("по «%s» - %d"):format(st.query, #list), T.dim, T.bg)
	else
		text(M + 26, 9, "печатай ник - найдётся; клик по игроку - правка счёта", T.faint, T.bg)
	end
	-- ника нет - можно открыть ему счёт заранее
	local q = st.query
	if #list == 0 and #q >= 2 and #q <= 16 and q:match("^[%w_]+$") then
		ui.button(M, 12, 40, "Открыть счёт " .. q, T.green, ICON.deposit, function() st.player = q redraw() end)
		return
	end

	local w = W - 2 * M + 1
	local rows, cols = H - 16, 2
	local per = rows * cols
	local count = max(1, ceil(#list / per))
	st.page = max(1, min(st.page, count))
	ui.pager(W - M + 1, 9, st.page, count, function(p)
		st.page = max(1, min(count, p))
		redraw()
	end)
	local cw = gfx.split(w - 4, cols, 4)
	local n = min(per, #list - (st.page - 1) * per)
	box(M, 11, w, max(1, min(rows, n)) + 3, T.surf, T.bg, nil, nil, T.flatShadow)
	for c = 0, cols - 1 do
		local x = M + 2 + c * (cw[1] + 4)
		text(x, 12, "игрок", T.faint, T.surf)
		text(x + 22, 12, "деньги", T.faint, T.surf)
		text(x + 44, 12, "ресурсы", T.faint, T.surf)
	end
	for i = 1, per do
		local nk = list[(st.page - 1) * per + i]
		if not nk then break end
		local c = floor((i - 1) / rows)
		local x, y = M + 2 + c * (cw[1] + 4), 13 + (i - 1) % rows
		local mm, rr = balances(nk)
		text(x, y, clip(nk, 20), T.text, T.surf)
		text(x + 22, y, clip(ui.money(mm), 20), T.money, T.surf)
		text(x + 44, y, clip(ui.resm(rr), cw[1] - 44), T.res, T.surf)
		ui.hit(x, y, cw[1], 1, function()
			st.player, st.confirm = nk, nil
			redraw()
		end)
	end
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
	text(M, 9, q == "" and "Журнал, новые сверху" or ("Журнал по «" .. st.query .. "»: " .. #list), T.text, T.bg)
	text(M + 30, 9, clip("печатай - поиск; весь журнал в " .. wallet.logPath .. " (" .. vault.where .. ")", W - M - 60),
		T.faint, T.bg)
	local w = W - 2 * M + 1
	local rows = H - 15
	local count = max(1, ceil(#list / rows))
	st.page = max(1, min(st.page, count))
	ui.pager(W - M + 1, 9, st.page, count, function(p)
		st.page = max(1, min(count, p))
		redraw()
	end)
	local rb = "Обновить"
	local rx = W - M + 1 - 24 - ulen(rb)
	pill(rx, 9, rb, T.text, T.name == "dark" and T.line or T.surf, T.bg)
	ui.hit(rx, 9, ulen(rb) + 4, 1, function() st.lines = nil redraw() end)
	local n = max(1, min(rows, #list - (st.page - 1) * rows))
	box(M, 11, w, n + 2, T.surf, T.bg, nil, nil, T.flatShadow)
	for i = 1, rows do
		local l = list[(st.page - 1) * rows + i]
		if not l then break end
		local colour = T.text
		if l:find("ВНИМАНИЕ", 1, true) then colour = T.red
		elseif l:find("АДМИН", 1, true) then colour = T.money
		elseif l:find(" вошёл", 1, true) or l:find(" вышел", 1, true) then colour = T.dim end
		text(M + 2, 11 + i, clip(l, w - 4), colour, T.surf)
	end
	if #list == 0 then text(M + 2, 12, "записей нет", T.faint, T.surf) end
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

local function kb(n)
	if n >= 1048576 then return ("%.1f МБ"):format(n / 1048576) end
	return ("%d КБ"):format(max(0, ceil(n / 1024)))
end

local function checkUpdate(force)
	local u = updater()
	if not u then redraw() return end
	st.up.err, st.up.done, st.up.list, st.up.prog = nil, nil, nil, nil
	st.up.busy = true
	ui.say("Смотрю, что изменилось на гите…", "wait")
	local list, why = u.check()
	st.up.busy = false
	ui.note(nil)
	if not list then st.up.err = why else st.up.list = force and u.forceAll(list) or list end
	redraw()
end

local drawProgress

local function applyUpdate()
	local u = updater()
	if not (u and st.up.list) or not ui.present() then return end
	local n = u.pending(st.up.list)
	if n == 0 then return end
	st.up.busy, st.up.err = true, nil
	wallet.log(("АДМИН %s: обновление, файлов %d"):format(ui.nick(), n))
	redraw()
	local done, why = u.apply(st.up.list, function(prog)
		st.up.prog = prog
		ui.part(function() drawProgress(true) end)
	end, ui.release)
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

--- Ход загрузки: общий процент, скорость, четыре потока и файлы. part -
--- перерисовать только то, что меняется: так ход дела идёт повтором на
--- экран, а не целым кадром раз в полсекунды.
function drawProgress(part)
	local p = st.up.prog
	local x, w = M, W - 2 * M + 1
	local y = 13
	if not part then
		box(x, y, w, 23, T.surf, T.bg, nil, nil, T.flatShadow)
		text(x + 2, y + 7, "Потоки", T.faint, T.surf)
		text(x + 2, y + 13, "Файлы", T.faint, T.surf)
		text(x + 2, y + 21, clip("Счета, журнал, rules.cfg и cfg/shop.cfg не трогаются. Файлы сверяются по CRC32 и подменяются разом.",
			w - 4), T.dim, T.surf)
		st.up.marks = {}
	end
	if not p then
		text(x + 2, y + 1, "Готовлюсь…", T.text, T.surf)
		return
	end
	local frac = p.total > 0 and p.got / p.total or 0
	local title = st.up.done and "Готово, перезагружаюсь…" or p.phase
	fill(x + 2, y + 1, w - 4, 1, T.surf)
	text(x + 2, y + 1, clip(title, w - 12), T.text, T.surf)
	local pct = floor(frac * 100) .. "%"
	text(x + w - 2 - ulen(pct), y + 1, pct, T.text, T.surf)
	gfx.progress(x + 2, y + 3, w - 4, frac, T.grad, T.name == "dark" and T.raised or T.line, T.surf)
	local left = p.speed > 0 and max(0, (p.wireTotal - p.wire) / p.speed) or 0
	local s = ("%s из %s   ·   %d КБ/с   ·   осталось %d:%02d   ·   по сети %s")
		:format(kb(p.got), kb(p.total), floor(p.speed / 1024), floor(left / 60), floor(left % 60), kb(p.wire))
	fill(x + 2, y + 5, w - 4, 1, T.surf)
	text(x + 2, y + 5, clip(s, w - 4), T.dim, T.surf)
	local lw = gfx.split(w - 4, 2, GAP)
	for i = 1, 4 do
		local lx = x + 2 + ((i - 1) % 2) * (lw[1] + GAP)
		local ly = y + 8 + floor((i - 1) / 2) * 2
		local f = p.lanes[i]
		local ww = lw[(i - 1) % 2 + 1]
		fill(lx, ly, ww, 1, T.surf)
		text(lx, ly, tostring(i), T.acc, T.surf)
		if f then
			text(lx + 2, ly, clip(f.to, 22), T.text, T.surf)
			local sz = kb(f.got) .. " / " .. kb(f.size)
			text(lx + ww - ulen(sz), ly, sz, T.faint, T.surf)
			local bx = lx + 26
			local bwid = ww - 26 - ulen(sz) - 2
			if bwid > 4 then
				gfx.progress(bx, ly, bwid, f.size > 0 and f.got / f.size or 0, T.grad,
					T.name == "dark" and T.raised or T.line, T.surf)
			end
		else
			text(lx + 2, ly, clip(p.idle or "свободен", ww - 4), T.faint, T.surf)
		end
	end
	local cw = gfx.split(w - 4, 3, GAP)
	local marks = st.up.marks or {}
	st.up.marks = marks
	for i, f in ipairs(p.files) do
		local c = floor((i - 1) / 6)
		if c > 2 then break end
		if marks[i] ~= f.state then
			marks[i] = f.state
			local fx = x + 2
			for k = 1, c do fx = fx + cw[k] + GAP end
			local fy = y + 14 + (i - 1) % 6
			local mark = f.state == "ok" and "✓" or f.state == "run" and "↓" or f.state == "bad" and "✕" or "·"
			local mc = f.state == "ok" and T.ok or f.state == "run" and T.acc or f.state == "bad" and T.red or T.faint
			text(fx, fy, mark, mc, T.surf)
			text(fx + 2, fy, clip(f.to, cw[c + 1] - 12), f.state == "wait" and T.faint or T.text, T.surf)
			local sz = kb(f.size)
			text(fx + cw[c + 1] - ulen(sz), fy, sz, T.faint, T.surf)
		end
	end
end

local function drawUpdate()
	local u = updater()
	local busy = st.up.busy
	local bw = gfx.split(W - 2 * M + 1, 4, GAP)
	ui.button(M, 9, bw[1], "Проверить", T.grey, ICON.refresh, function() checkUpdate(false) end, busy)
	ui.button(M + bw[1] + GAP, 9, bw[2], "Скачать всё заново", T.grey, ICON.deposit,
		function() checkUpdate(true) end, busy)

	local sx = M + bw[1] + bw[2] + 2 * GAP + 1
	local sw = W - M - sx
	local where = u and u.where or "гита"
	if st.up.err then
		text(sx, 10, clip(st.up.err, sw), T.red, T.bg)
	elseif st.up.done then
		text(sx, 10, ("Положено файлов %d - перезагрузка…"):format(st.up.done), T.ok, T.bg)
	elseif not st.up.list then
		-- «u and u.card()» обрезало бы вторую отдачу: в Lua and даёт одно значение
		local why, known = nil, 0
		if u then
			_, why = u.card()
			for _ in pairs(u.record().files) do known = known + 1 end
		end
		local hint = why or (known > 0
			and ("На диске записано файлов " .. known .. " - нажми «Проверить»")
			or "Записи о версии нет: сверю по хэшам, каталог - по размеру")
		text(sx, 10, clip(hint, sw), why and T.red or T.dim, T.bg)
	end
	text(sx, 11, clip("Берётся только изменившееся с " .. where .. ", сжатым", sw), T.faint, T.bg)

	if busy or st.up.prog then return drawProgress() end
	if not st.up.list then return end

	local list = st.up.list
	local w = W - 2 * M + 1
	local rows = min(#list, H - 13 - 9)
	box(M, 13, w, rows + 3, T.surf, T.bg, nil, nil, T.flatShadow)
	text(M + 2, 14, "файл", T.faint, T.surf)
	text(M + 34, 14, "размер", T.faint, T.surf)
	text(M + 48, 14, "что с ним", T.faint, T.surf)
	for i = 1, rows do
		local e = list[i]
		local y = 14 + i
		text(M + 2, y, clip(e.to, 30), e.need and T.text or T.faint, T.surf)
		text(M + 34, y, kb(e.size), e.need and T.text or T.faint, T.surf)
		text(M + 48, y, clip(e.why or "", w - 50), e.need and T.money or T.faint, T.surf)
	end

	local n, bytes, wire = u.pending(list)
	local by = 13 + rows + 4
	ui.button(M, by, 40, n > 0 and "Обновить и перезагрузить" or "Всё и так свежее", T.primary,
		ICON.refresh, applyUpdate, n == 0)
	if n > 0 then
		text(M + 42, by + 1, clip(("скачать файлов %d, %s (по сети около %s); машина перезагрузится сама")
			:format(n, kb(bytes), kb(wire)), W - M - 42 - M), T.dim, T.bg)
	end
end

-- ------------------------------------------------------------------ кадр

function admin.draw()
	T = ui.theme()
	local tabsList = {
		{ id = "items", name = "Скупка", n = #rules.list("res") },
		{ id = "players", name = "Игроки", n = st.nicks and #st.nicks or nil },
		{ id = "log", name = "Журнал" },
		{ id = "update", name = "Обновление", n = st.up.list and ((st.up.mod and st.up.mod.pending(st.up.list)) or nil) or nil },
	}
	local active = 1
	for i, t in ipairs(tabsList) do
		local id = t.id
		t.fn = function() tab(id) end
		if id == st.tab then active = i end
	end
	-- выключатель магазина: виден с любой вкладки, это не настройка скупки
	local test = rules.testMode()
	local tl = test and "Тест-режим: вкл" or "Тест-режим: выкл"
	local tw = ulen(tl) + 4
	local tx = W - M + 1 - tw
	ui.tabs(M, 6, tx - GAP - M, tabsList, active, "adm-more")
	gfx.rule(tx - GAP, 7, tw + GAP, T.name == "dark" and T.raised or T.line, T.bg)
	pill(tx, 6, tl, test and 0x000000 or T.dim, test and T.warn or (T.name == "dark" and T.line or T.surf), T.bg)
	ui.hit(tx, 6, tw, 1, setTest)

	if st.tab == "items" then drawItems()
	elseif st.tab == "players" then drawPlayers()
	elseif st.tab == "update" then drawUpdate()
	else drawLog() end
end

--- Списки поверх кадра: у панели своих нет (вкладок четыре, влезают).
function admin.overlay() end

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
	elseif code == 201 then st.page = max(1, st.page - 1)  -- PgUp
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
