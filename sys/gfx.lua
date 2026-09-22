-- gfx - всё рисование магазина: кадр, текст, иконки и элементы экрана.
--
-- Кадр собирается в видеобуфере и показывается целиком: игрок не видит,
-- как экран собирается по кускам. Показ устроен как в DwOS: всё, что
-- рисуется в буфер, пишется ещё и в журнал, и если изменений немного
-- (сообщение, число в полосе количества), они повторяются прямо на
-- экране - десяток set дешевле bitblt, который стоит почти целый тик.
-- Много изменений - один bitblt. Без видеопамяти рисуем прямо на экран.
--
-- Элементы экрана двух размеров: крупные в 3 строки (кнопки, поле поиска,
-- плитки, полоса количества) и мелкие в строку (разделы, списки,
-- листалка). Скругления и тени - полублоки, значки - брайль (в шрифте OC
-- это квадратики 2x4 на ячейку). Всё это считается один раз при загрузке,
-- при рисовании остаются только set и fill.
--
-- Цвет у gpu переключается отдельным вызовом, поэтому он запоминается и не
-- переставляется, если уже нужный.

local gpu = require("gpu")
local unicode = unicode

local byte, rep, concat = string.byte, string.rep, table.concat
local floor, max, min = math.floor, math.max, math.min
local ulen, usub = unicode.len, unicode.sub

local gfx = {}

-- Палитра, которой упакованы иконки: куб 6x8x5 и 16 серых. В ячейке иконки
-- лежит номер цвета, gpu нужен rgb.
local PAL = {}
do
	local i = 0
	for r = 0, 5 do
		for g = 0, 7 do
			for b = 0, 4 do
				PAL[i] = r * 0x33 * 65536 + g * 0x24 * 256 + floor(b / 4 * 0xFF + 0.5)
				i = i + 1
			end
		end
	end
	for n = 1, 16 do
		local v = n * 0x0F
		PAL[i] = v * 65536 + v * 256 + v
		i = i + 1
	end
end
gfx.PAL = PAL

local HALF = unicode.char(0x2584)      -- ▄: верх ячейки - фон, низ - цвет
local UPPER = unicode.char(0x2580)     -- ▀
local LEFT = unicode.char(0x258C)      -- ▌
local RIGHT = unicode.char(0x2590)     -- ▐
local BRAILLE = setmetatable({}, { __index = function(t, k)
	local c = unicode.char(0x2800 + k)
	t[k] = c
	return c
end })

gfx.W, gfx.H = gpu.getResolution()
local W, H = gfx.W, gfx.H

local fgNow, bgNow

-- ------------------------------------------------------------------ журнал

-- Цены операций над экраном по уровням видеокарты (GraphicsCard.scala) и
-- потолок, после которого выгоднее bitblt: он стоит пропорционально
-- размеру буфера, но повтор, подобравшийся к кредиту тика (1.5), и тик
-- теряет, и бюджета на остальное не оставляет - отсюда 0.9, как в DwOS.
local COST = { set = { 1 / 64, 1 / 128, 1 / 256 }, fill = { 1 / 32, 1 / 64, 1 / 128 },
	color = { 1 / 32, 1 / 64, 1 / 128 }, blit = { 0.5, 1, 2 } }
local cSet, cFill, cColor, LIMIT
do
	local mw, mh = gpu.maxResolution()
	local t = mw >= 160 and 3 or mw >= 80 and 2 or 1
	cSet, cFill, cColor = COST.set[t], COST.fill[t], COST.color[t]
	LIMIT = min(COST.blit[t] * (W * H) / (mw * mh), 0.9)
end

local buf = 0
do
	if gpu.allocateBuffer then
		local ok, id = pcall(gpu.allocateBuffer, W, H)
		if ok and id then buf = id end
	end
end

local log, ln, cost, over = {}, 0, 0, false
local lfg, lbg                     -- цвета последней записи журнала
local synced = false               -- на экране то же, что в буфере

local function record(op, x, y, a, f, b, h)
	if over then return end
	if b ~= lbg then cost = cost + cColor lbg = b end
	if op == 1 and f ~= lfg then cost = cost + cColor lfg = f end
	cost = cost + (op == 1 and cSet or cFill)
	if cost > LIMIT then
		over = true
		for i = 1, ln do log[i] = nil end
		ln = 0
		return
	end
	ln = ln + 1
	local e = log[ln]
	if not e then e = {} log[ln] = e end
	e[1], e[2], e[3], e[4], e[5], e[6], e[7] = op, x, y, a, f, b, h
end

local function fg(c) if c ~= fgNow then gpu.setForeground(c) fgNow = c end end
local function bg(c) if c ~= bgNow then gpu.setBackground(c) bgNow = c end end

--- Начать рисовать: всё дальнейшее идёт в буфер и в журнал.
function gfx.begin()
	if buf ~= 0 then gpu.setActiveBuffer(buf) end
	ln, cost, over, lfg, lbg = 0, 0, false, nil, nil
end

--- Показать нарисованное с прошлого показа: мало - повтором на экране,
--- много - одним bitblt. "blit" - без выбора.
function gfx.show(force)
	if buf == 0 then return end
	gpu.setActiveBuffer(0)
	if synced and not over and force ~= "blit" then
		local f, b
		for i = 1, ln do
			local e = log[i]
			if e[6] ~= b then gpu.setBackground(e[6]) b = e[6] end
			if e[1] == 1 and e[5] ~= f then gpu.setForeground(e[5]) f = e[5] end
			if e[1] == 1 then gpu.set(e[2], e[3], e[4])
			else gpu.fill(e[2], e[3], e[4], e[7], " ") end
		end
		-- цвета карты общие для буферов и экрана: теперь они такие
		fgNow, bgNow = f or fgNow, b or bgNow
	elseif ln > 0 or over or not synced then
		gpu.bitblt(0, 1, 1, W, H, buf, 1, 1)
	end
	synced = true
	ln, cost, over = 0, 0, false
	-- активным остаётся экран: сообщение init.lua о падении должно быть
	-- видно, а не уйти в буфер; следующий кадр начнёт begin()
end

--- Кто-то рисовал мимо буфера: следующий показ - целиком.
function gfx.dirty() synced = false end

function gfx.release()
	if buf ~= 0 then
		pcall(gpu.setActiveBuffer, 0)
		pcall(gpu.freeBuffer, buf)
		buf = 0
	end
end

-- ------------------------------------------------------------------ текст

--- Строка s с цветом f на фоне b.
local function set(x, y, s, f, b)
	bg(b)
	fg(f)
	gpu.set(x, y, s)
	if buf ~= 0 then record(1, x, y, s, f, b) end
end

--- Прямоугольник фона b.
local function fill(x, y, w, h, b)
	if w < 1 or h < 1 then return end
	bg(b)
	gpu.fill(x, y, w, h, " ")
	if buf ~= 0 then record(2, x, y, w, fgNow, b, h) end
end

gfx.set, gfx.fill = set, fill
function gfx.text(x, y, s, f, b) set(x, y, s, f, b) end

--- Обрезать до n символов с многоточием.
function gfx.clip(s, n)
	s = tostring(s)
	if n < 1 then return "" end
	if ulen(s) <= n then return s end
	return usub(s, 1, n - 1) .. "…"
end

--- Ровно n символов: обрезать или добить пробелами.
function gfx.pad(s, n, align)
	s = gfx.clip(s, n)
	local gap = n - ulen(s)
	if gap <= 0 then return s end
	if align == "right" then return rep(" ", gap) .. s end
	if align == "center" then
		local l = floor(gap / 2)
		return rep(" ", l) .. s .. rep(" ", gap - l)
	end
	return s .. rep(" ", gap)
end

gfx.len = ulen

--- Поделить total на n частей с зазором gap поровну; остаток - первым.
function gfx.split(total, n, gap)
	local room = total - gap * (n - 1)
	local base = floor(room / n)
	local extra = room - base * n
	local out = {}
	for i = 1, n do out[i] = base + (i <= extra and 1 or 0) end
	return out
end

-- ------------------------------------------------------------------ иконки товаров

--- Иконка из ячеек каталога. mode 0 - полублоки (2 байта на ячейку: цвет
--- сверху, цвет снизу), 1 - брайль (3 байта: фон, цвет точек, узор).
--- Цвет 0 - это подложка, на которой иконку снимали: он заменяется на back.
--- scale 2 рисует полублочную иконку вдвое крупнее.
function gfx.icon(cells, mode, w, h, x, y, back, scale)
	scale = (mode == 0 and scale == 2) and 2 or 1
	local step = mode == 0 and 2 or 3
	for row = 0, h - 1 do
		local base = row * w * step
		-- для удвоения строка ячеек собирается в две экранных: верхние
		-- половинки и нижние
		for sub = 1, scale do
			local run, rx, rb, rf = nil, 0, 0, 0
			local sy = y + row * scale + sub - 1
			for col = 0, w - 1 do
				local p = base + col * step + 1
				local a, b = byte(cells, p), byte(cells, p + 1)
				local ch, cb, cf
				if mode == 0 then
					cb = a == 0 and back or PAL[a]
					cf = b == 0 and back or PAL[b]
					if scale == 2 then
						if sub == 1 then cf = cb else cb = cf end
					end
					ch = cb == cf and " " or HALF
				else
					local g = byte(cells, p + 2)
					cb = a == 0 and back or PAL[a]
					cf = b == 0 and back or PAL[b]
					if g == 0 then ch = " " cf = cb else ch = BRAILLE[g] end
				end
				if ch == " " then cf = run and rf or cf end
				local piece = scale == 2 and ch .. ch or ch
				if run and cb == rb and (cf == rf or ch == " ") then
					run[#run + 1] = piece
				else
					if run then set(rx, sy, concat(run), rf, rb) end
					run, rx, rb, rf = { piece }, x + col * scale, cb, cf
				end
			end
			if run then set(rx, sy, concat(run), rf, rb) end
		end
	end
end

-- ------------------------------------------------------------------ значки брайлем

local BIT = { { 1, 8 }, { 2, 16 }, { 4, 32 }, { 64, 128 } }

--- Значок из рисунка в точках: слои { строки, номер цвета }; точка берёт
--- номер последнего слоя, где в ней '#', иначе 0 - фон. В ячейке брайля
--- два цвета: чаще встречающийся - фон, другой - точки. Возвращает строки
--- ячеек { символ, номер цвета точек, номер цвета фона }.
function gfx.glyph(...)
	local layers = { ... }
	local wd, ht = 0, 0
	for _, l in ipairs(layers) do
		ht = max(ht, #l[1])
		for _, r in ipairs(l[1]) do wd = max(wd, #r) end
	end
	local function role(dx, dy)
		local v = 0
		for _, l in ipairs(layers) do
			local r = l[1][dy]
			if r and r:sub(dx, dx) == "#" then v = l[2] end
		end
		return v
	end
	local out = {}
	for cy = 0, math.ceil(ht / 4) - 1 do
		local row = {}
		for cx = 0, math.ceil(wd / 2) - 1 do
			local roles, count = {}, {}
			for dy = 1, 4 do
				for dx = 1, 2 do
					local v = role(cx * 2 + dx, cy * 4 + dy)
					roles[#roles + 1] = v
					count[v] = (count[v] or 0) + 1
				end
			end
			local order = {}
			for v, n in pairs(count) do order[#order + 1] = { v, n } end
			table.sort(order, function(a, b)
				if a[2] ~= b[2] then return a[2] > b[2] end
				return a[1] < b[1]
			end)
			local back = order[1][1]
			local dots = order[2] and order[2][1] or back
			local code, k = 0, 0
			for dy = 1, 4 do
				for dx = 1, 2 do
					k = k + 1
					if roles[k] ~= back then code = code + BIT[dy][dx] end
				end
			end
			row[#row + 1] = { code == 0 and " " or BRAILLE[code], dots, back }
		end
		out[#out + 1] = row
	end
	return out
end

--- Нарисовать значок: colours[номер] - цвет, colours[0] - фон под ним.
function gfx.draw(g, x, y, colours)
	for r = 1, #g do
		local row, run, rx, rf, rb = g[r], nil, 0, 0, 0
		for c = 1, #row do
			local cell = row[c]
			local f, b = colours[cell[2]], colours[cell[3]]
			if cell[1] == " " then f = rf end
			if run and b == rb and (f == rf or cell[1] == " ") then
				run[#run + 1] = cell[1]
			else
				if run then set(rx, y + r - 1, concat(run), rf, rb) end
				run, rx, rf, rb = { cell[1] }, x + c - 1, f or b, b
			end
		end
		if run then set(rx, y + r - 1, concat(run), rf, rb) end
	end
end

-- 8 точек в ширину (4 ячейки), 12 в высоту (3 строки)
local function icon(rows) return gfx.glyph({ rows, 1 }) end
gfx.ICON = {
	deposit = icon({ "", "   ##", "   ##", "   ##", " ######", "  ####", "   ##", "",
		"#      #", "#      #", "########", "" }),
	withdraw = icon({ "", "   ##", "  ####", " ######", "   ##", "   ##", "   ##", "",
		"#      #", "#      #", "########", "" }),
	crate = icon({ "", " ######", "#      #", "########", "#      #", "#  ##  #", "#  ##  #",
		"#      #", "#      #", "########", "", "" }),
	coin = icon({ "", "  ####", " #    #", "#  ##  #", "# #    #", "#  ##  #", "#    # #",
		"#  ##  #", " #    #", "  ####", "", "" }),
	lens = icon({ "", " ####", "#    #", "#    #", "#    #", "#    #", " ####", "     #",
		"      #", "       #", "", "" }),
	sun = icon({ "", "", "   #", " #    #", "  ####", "# #### #", "  ####", " #    #", "   #",
		"", "", "" }),
	moon = icon({ "", "", "  ####", " ##", "##", "##", "##", " ##   #", "  ####", "", "", "" }),
	menu = icon({ "", "", " ######", "", "", " ######", "", "", " ######", "", "", "" }),
	refresh = icon({ "", "  #### #", " #    ##", "#    ###", "#", "#", "#      #", " #    #",
		"  ####", "", "", "" }),
	key = icon({ "", "", " ###", "#   #", "#   ####", "#   # #", " ###  #", "", "", "", "", "" }),
	shop = icon({ "", "", "########", "#  ##  #", "########", " #    #", " # ## #", " # ## #",
		" ######", "", "", "" }),
}
-- кружок 8x8 точек (4 ячейки на 2 строки) со значком внутри
local DISC = { "  ####", " ######", "########", "########", "########", "########", " ######", "  ####" }
gfx.BADGE = {
	ok = gfx.glyph({ DISC, 1 }, { { "", "      #", "     ##", " #  ##", " ####", "  ##", "", "" }, 2 }),
	err = gfx.glyph({ DISC, 1 }, { { "", " ##  ##", "  ####", "   ##", "  ####", " ##  ##", "", "" }, 2 }),
	wait = gfx.glyph({ DISC, 1 }, { { "", "", "", " ## ## #", "", "", "", "" }, 2 }),
	warn = gfx.glyph({ DISC, 1 }, { { "", "   ##", "   ##", "   ##", "", "   ##", "", "" }, 2 }),
}

-- ------------------------------------------------------------------ формы

--- Прямоугольник со срезанными углами (по 2 точки сверху и снизу): mid -
--- заливка, top и bot - цвет самой верхней и нижней строки точек (свет и
--- тень объёма), back - что под углами, shadow - тень в полстроки снизу.
--- Высота h от 2 строк.
function gfx.box(x, y, w, h, mid, back, top, bot, shadow)
	top, bot = top or mid, bot or mid
	local inner = w - 4
	-- верх: крайние ячейки не трогаем, соседние - полублок заливки
	set(x + 1, y, HALF, mid, back)
	if inner > 0 then
		if top == mid then fill(x + 2, y, inner, 1, mid)
		else set(x + 2, y, rep(HALF, inner), mid, top) end
	end
	set(x + w - 2, y, HALF, mid, back)
	if h > 2 then fill(x, y + 1, w, h - 2, mid) end
	local by = y + h - 1
	set(x + 1, by, HALF, back, mid)
	if inner > 0 then
		if bot == mid then fill(x + 2, by, inner, 1, mid)
		else set(x + 2, by, rep(HALF, inner), bot, mid) end
	end
	set(x + w - 2, by, HALF, back, mid)
	-- по краям средних строк - целые ячейки заливки
	if shadow and by < H then set(x + 2, by + 1, rep(HALF, w - 2), back, shadow) end
end

--- Мелкая плашка в строку: половинки по краям, надпись внутри. Ширина.
function gfx.pill(x, y, label, f, b, back)
	set(x, y, RIGHT, b, back)
	set(x + 1, y, " " .. label .. " ", f, b)
	local w = ulen(label) + 4
	set(x + w - 1, y, LEFT, b, back)
	return w
end

--- Крупная кнопка: объём, значок на тёмной плашке слева, тень.
---   st = { base, hi, lo, badge, fg }, icon - из gfx.ICON или nil
function gfx.button(x, y, w, label, st, back, icon, shadow)
	gfx.box(x, y, w, 3, st.base, back, st.hi, st.lo, shadow)
	local lx, lw = x, w
	if icon then
		-- плашка значка: те же срезанные углы слева, справа прямая
		set(x + 1, y, HALF, st.badge, back)
		fill(x + 2, y, 6, 1, st.badge)
		fill(x, y + 1, 8, 1, st.badge)
		set(x + 1, y + 2, HALF, back, st.badge)
		fill(x + 2, y + 2, 6, 1, st.badge)
		gfx.draw(icon, x + 2, y, { [0] = st.badge, [1] = st.fg })
		lx, lw = x + 8, w - 8
	end
	label = gfx.clip(label, lw - 2)
	set(lx + floor((lw - ulen(label)) / 2), y + 1, label, st.fg, st.base)
end

--- Кнопка из одного значка: та же высота, ширина 8.
function gfx.iconButton(x, y, icon, colour, b, back, shadow)
	gfx.box(x, y, 8, 3, b, back, b, b, shadow)
	gfx.draw(icon, x + 2, y, { [0] = b, [1] = colour })
end

--- Плавная полоса в строку: точность в полклетки, цвет идёт по stops.
function gfx.progress(x, y, w, p, stops, track, back)
	p = max(0, min(1, p or 0))
	local halves = floor(p * (w - 2) * 2 + 0.5)
	local function colour(t)
		if #stops == 1 then return stops[1] end
		t = t * (#stops - 1)
		local i = min(#stops - 1, floor(t) + 1)
		return gfx.mix(stops[i], stops[i + 1], t - (i - 1))
	end
	set(x, y, RIGHT, halves > 0 and colour(0) or track, back)
	-- заливка пачками одного цвета: у градиента цвет меняется, у ровной
	-- полосы вся заливка - один fill
	local i = 0
	while i < w - 2 do
		local c = colour(i / max(1, w - 3))
		if i * 2 + 2 <= halves then
			local n = 1
			while i + n < w - 2 and (i + n) * 2 + 2 <= halves and colour((i + n) / max(1, w - 3)) == c do n = n + 1 end
			fill(x + 1 + i, y, n, 1, c)
			i = i + n
		elseif i * 2 + 1 == halves then
			set(x + 1 + i, y, LEFT, c, track)
			i = i + 1
		else
			fill(x + 1 + i, y, w - 2 - i, 1, track)
			break
		end
	end
	set(x + w - 1, y, LEFT, halves >= (w - 2) * 2 and colour(1) or track, back)
end

--- Черта в полстроки под строкой y: разделы, края списков.
function gfx.rule(x, y, w, colour, back)
	if w > 0 then set(x, y, rep(UPPER, w), colour, back) end
end

--- Смешать два RGB-цвета: t=0 - первый, t=1 - второй.
function gfx.mix(a, b, t)
	local function ch(c, s) return floor(c / s) % 256 end
	local r = floor(ch(a, 65536) + (ch(b, 65536) - ch(a, 65536)) * t + 0.5)
	local g = floor(ch(a, 256) + (ch(b, 256) - ch(a, 256)) * t + 0.5)
	local bl = floor(ch(a, 1) + (ch(b, 1) - ch(a, 1)) * t + 0.5)
	-- монитор всё равно округлит до палитры: округляем сами, иначе
	-- соседние ячейки с «разными» цветами не склеятся в один вызов
	return gfx.nearest(r * 65536 + g * 256 + bl)
end

--- Ближайший цвет палитры монитора 3-го уровня.
local near = {}
function gfx.nearest(c)
	local v = near[c]
	if v then return v end
	local r, g, b = floor(c / 65536) % 256, floor(c / 256) % 256, c % 256
	local best, bd = 0, math.huge
	for i = 0, 255 do
		local p = PAL[i]
		local dr, dg, db = r - floor(p / 65536) % 256, g - floor(p / 256) % 256, b - p % 256
		local d = 0.3 * dr * dr + 0.59 * dg * dg + 0.11 * db * db
		if d < bd then best, bd = p, d end
	end
	near[c] = best
	return best
end

-- ------------------------------------------------------------------ крупные буквы

-- 5x7 точек, точка - полклетки: буква занимает 5 ячеек на 3.5 строки
local FONT = {
	A = { " ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #" },
	B = { "#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### " },
	C = { " ####", "#    ", "#    ", "#    ", "#    ", "#    ", " ####" },
	D = { "#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### " },
	E = { "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####" },
	F = { "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    " },
	G = { " ####", "#    ", "#    ", "#  ##", "#   #", "#   #", " ####" },
	H = { "#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #" },
	I = { "#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####" },
	J = { "  ###", "    #", "    #", "    #", "    #", "#   #", " ### " },
	K = { "#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #" },
	L = { "#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####" },
	M = { "#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #" },
	N = { "#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #" },
	O = { " ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " },
	P = { "#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    " },
	Q = { " ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #" },
	R = { "#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #" },
	S = { " ####", "#    ", "#    ", " ### ", "    #", "    #", "#### " },
	T = { "#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  " },
	U = { "#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### " },
	V = { "#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  " },
	W = { "#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #" },
	X = { "#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #" },
	Y = { "#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  " },
	Z = { "#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####" },
	["0"] = { " ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### " },
	["1"] = { "  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " },
	["2"] = { " ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####" },
	["3"] = { "#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### " },
	["4"] = { "   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # " },
	["5"] = { "#####", "#    ", "#### ", "    #", "    #", "#   #", " ### " },
	["6"] = { "  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### " },
	["7"] = { "#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   " },
	["8"] = { " ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### " },
	["9"] = { " ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  " },
	[" "] = { "     ", "     ", "     ", "     ", "     ", "     ", "     " },
}

--- Можно ли написать s крупными буквами.
function gfx.canBig(s)
	for i = 1, #s do if not FONT[s:sub(i, i)] then return false end end
	return #s > 0
end

--- Ширина надписи крупными буквами в ячейках.
function gfx.bigWidth(s, scale) return #s * 6 * scale - scale end

--- Крупная надпись: scale - во сколько раз точка больше, colour(x) - цвет
--- столбца (для перелива), back - фон.
function gfx.big(x, y, s, scale, colour, back)
	local w, hp = gfx.bigWidth(s, scale), 7 * scale
	local rows = math.ceil(hp / 2)
	-- точки надписи: px[строка точек][столбец] = true
	local function on(px, py)
		local i = floor(px / (6 * scale))
		local cx = floor((px % (6 * scale)) / scale)
		local ch = s:sub(i + 1, i + 1)
		local g = FONT[ch]
		if not g or cx > 4 then return false end
		local r = g[floor(py / scale) + 1]
		return r and r:sub(cx + 1, cx + 1) == "#"
	end
	for row = 0, rows - 1 do
		local run, rx, rf, rb = nil, 0, 0, 0
		for c = 0, w - 1 do
			local col = colour(c)
			local t = on(c, row * 2) and col or back
			local b = (row * 2 + 1 < hp and on(c, row * 2 + 1)) and col or back
			local ch, f = HALF, b
			if t == b then ch, f = " ", rf end
			if run and t == rb and (f == rf or ch == " ") then
				run[#run + 1] = ch
			else
				if run then set(rx, y + row, concat(run), rf, rb) end
				run, rx, rf, rb = { ch }, x + c, f or t, t
			end
		end
		if run then set(rx, y + row, concat(run), rf, rb) end
	end
	return w
end

return gfx
