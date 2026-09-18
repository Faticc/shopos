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
--   Журнал - последние записи, новые сверху; печать - поиск по ним.
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

-- ------------------------------------------------------------------ кадр

function admin.draw()
	fill(1, 4, W, H - 4, C.bg)
	local x = 3
	for _, t in ipairs({ { "items", "Скупка" }, { "players", "Игроки" }, { "log", "Журнал" } }) do
		local on = st.tab == t[1]
		local w = ulen(t[2]) + 6
		button(x, 5, w, 3, t[2], on and C.black or C.text, on and C.gold or C.line)
		ui.hit(x, 5, w, 3, function() tab(t[1]) end)
		x = x + w + 1
	end
	-- где данные: владельцу это важно знать
	local where = vault.warn or ("данные: " .. vault.where)
	text(x + 2, 6, clip(where, W - x - 24), vault.warn and C.red or C.faint, C.bg)
	button(W - 17, 5, 16, 3, "В МАГАЗИН ▶", C.black, C.green)
	ui.hit(W - 17, 5, 16, 3, function() ui.toShop() end)

	if st.tab == "items" then drawItems()
	elseif st.tab == "players" then drawPlayers()
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
		if st.tab == "items" then
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
