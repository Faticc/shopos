-- theme - цвета магазина и какая тема у какого игрока.
--
-- Тем две: тёмная (по умолчанию) и светлая. Игрок переключает её кнопкой
-- с луной или солнцем в шапке, выбор ложится на диск данных в
-- prefs/<ник> - рядом со счетами, но отдельным файлом: запись темы не
-- трогает файл с деньгами. Диска данных нет - тема живёт до ухода игрока.
--
-- Все цвета - из палитры монитора 3-го уровня: чужие он всё равно
-- округлит, а так соседние ячейки одного цвета склеиваются в один вызов.

local vault = require("vault")

local theme = {}

local function style(base, hi, lo, fg) return { base = base, hi = hi, lo = lo, badge = lo, fg = fg } end

theme.dark = {
	name = "dark",
	bg = 0x0F0F0F, surf = 0x1E1E1E, raised = 0x2D2D2D, line = 0x3C3C3C,
	text = 0xF0F0F0, dim = 0x969696, faint = 0x5A5A5A,
	acc = 0x6624FF, on = 0xFFFFFF,
	money = 0xFFDB00, res = 0x33DBFF, ok = 0x33B640, red = 0xFF2440, warn = 0xFFDB00,
	shadow = 0x000000,
	-- тень под плашками на тёмном фоне не видна, карточкам она не нужна
	flatShadow = nil,
	grad = { 0x6624FF, 0x3349FF, 0x3392FF, 0x33DBFF },
	primary = style(0x6624FF, 0x9949FF, 0x330080, 0xFFFFFF),
	green = style(0x33B640, 0x66DB80, 0x006D00, 0xFFFFFF),
	blue = style(0x0092BF, 0x33B6FF, 0x004980, 0xFFFFFF),
	grey = style(0x3C3C3C, 0x5A5A5A, 0x2D2D2D, 0xF0F0F0),
	danger = style(0xCC2440, 0xFF4940, 0x990000, 0xFFFFFF),
	off = style(0x1E1E1E, 0x1E1E1E, 0x1E1E1E, 0x5A5A5A),
	sun = 0xFFDB00,
}

theme.light = {
	name = "light",
	bg = 0xF0F0F0, surf = 0xFFFFFF, raised = 0xFFFFFF, line = 0xD2D2D2,
	text = 0x1E1E1E, dim = 0x696969, faint = 0xA5A5A5,
	acc = 0xFF6D00, on = 0xFFFFFF,
	money = 0xCC6D00, res = 0x0092BF, ok = 0x00B640, red = 0xCC0000, warn = 0xCC6D00,
	shadow = 0xC3C3C3,
	flatShadow = 0xC3C3C3,
	grad = { 0xFF6D00, 0xFF9240 },
	primary = style(0xFF6D00, 0xFF9240, 0xCC4900, 0xFFFFFF),
	green = style(0x00B640, 0x66DB80, 0x006D00, 0xFFFFFF),
	blue = style(0x0092BF, 0x33B6FF, 0x004980, 0xFFFFFF),
	grey = style(0xE1E1E1, 0xF0F0F0, 0xC3C3C3, 0x1E1E1E),
	danger = style(0xCC0000, 0xFF4940, 0x990000, 0xFFFFFF),
	off = style(0xE1E1E1, 0xE1E1E1, 0xE1E1E1, 0xA5A5A5),
	sun = 0xFF9200,
}

local DIR = vault.path("/prefs")
if vault.fs then vault.fs:mkdir(DIR) end

--- Тема игрока: его выбор с диска данных или тёмная.
function theme.of(nick)
	if nick and vault.fs then
		local s = vault.fs:readAll(DIR .. "/" .. nick)
		if s and s:match("light") then return theme.light end
	end
	return theme.dark
end

--- Запомнить выбор игрока. false - диска данных нет или не записалось.
function theme.save(nick, t)
	if not (nick and vault.fs) then return false end
	return vault.fs:writeAll(DIR .. "/" .. nick, t.name .. "\n")
end

return theme
