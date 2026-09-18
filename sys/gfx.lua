-- gfx - всё рисование магазина.
--
-- Рисуем в видеобуфер и показываем готовый кадр одним bitblt: игрок не
-- видит, как экран собирается по кускам. Если видеопамяти на буфер нет,
-- рисуем прямо на экран - медленнее, но работает.
--
-- Цвет у gpu переключается отдельным вызовом, поэтому он запоминается и не
-- переставляется, если уже нужный.

local gpu = require("gpu")
local unicode = unicode

local byte, rep, concat = string.byte, string.rep, table.concat
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
				PAL[i] = r * 0x33 * 65536 + g * 0x24 * 256 + math.floor(b / 4 * 0xFF + 0.5)
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

local HALF = unicode.char(0x2584)
local BRAILLE = setmetatable({}, { __index = function(t, k)
	local c = unicode.char(0x2800 + k)
	t[k] = c
	return c
end })

gfx.W, gfx.H = gpu.getResolution()

local fgNow, bgNow
local function fg(c) if c ~= fgNow then gpu.setForeground(c) fgNow = c end end
local function bg(c) if c ~= bgNow then gpu.setBackground(c) bgNow = c end end
gfx.fg, gfx.bg = fg, bg

-- ------------------------------------------------------------------ буфер

local buf = 0
do
	if gpu.allocateBuffer then
		local ok, id = pcall(gpu.allocateBuffer, gfx.W, gfx.H)
		if ok and id then buf = id end
	end
end

--- Начать кадр: всё дальнейшее рисуется в буфер.
function gfx.begin()
	if buf ~= 0 then gpu.setActiveBuffer(buf) end
	fgNow, bgNow = nil, nil
end

--- Показать нарисованное. Без аргументов - весь экран.
function gfx.show(x, y, w, h)
	if buf == 0 then return end
	x, y = x or 1, y or 1
	gpu.bitblt(0, x, y, w or gfx.W, h or gfx.H, buf, x, y)
end

function gfx.release()
	if buf ~= 0 then
		pcall(gpu.setActiveBuffer, 0)
		pcall(gpu.freeBuffer, buf)
		buf = 0
	end
end

-- ------------------------------------------------------------------ текст

function gfx.fill(x, y, w, h, colour, ch)
	if w < 1 or h < 1 then return end
	bg(colour)
	gpu.fill(x, y, w, h, ch or " ")
end

function gfx.text(x, y, s, colour, back)
	if back then bg(back) end
	fg(colour)
	gpu.set(x, y, s)
end

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
		local l = math.floor(gap / 2)
		return rep(" ", l) .. s .. rep(" ", gap - l)
	end
	return s .. rep(" ", gap)
end

gfx.len = ulen

--- Кнопка: прямоугольник с надписью по центру.
function gfx.button(x, y, w, h, label, colour, back)
	gfx.fill(x, y, w, h, back)
	gfx.text(x, y + math.floor((h - 1) / 2), gfx.pad(label, w, "center"), colour, back)
end

-- ------------------------------------------------------------------ иконки

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
						-- верхняя экранная строка целиком цвета верха ячейки,
						-- нижняя - цвета низа
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
				local n = scale
				local piece = scale == 2 and ch .. ch or ch
				if run and cb == rb and (cf == rf or ch == " ") then
					run[#run + 1] = piece
				else
					if run then
						bg(rb) fg(rf)
						gpu.set(rx, sy, concat(run))
					end
					run, rx, rb, rf = { piece }, x + col * n, cb, cf
				end
			end
			if run then
				bg(rb) fg(rf)
				gpu.set(rx, sy, concat(run))
			end
		end
	end
end

gfx.PAL = PAL
return gfx
