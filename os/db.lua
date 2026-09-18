-- db - счета и корзины игроков на диске.
--
-- Заменяет внешнюю базу прежней машины. Та отвечала на запрос перебором по
-- всем записям: чтобы узнать баланс одного игрока, читалось всё. На сотне
-- завсегдатаев это заметно, а магазин спрашивает баланс на каждый чих.
--
-- Здесь запись на игрока - отдельный файл /var/players/<ник>.lua. Чтение и
-- запись стоят ровно одно обращение к диску и не зависят от того, сколько
-- игроков в базе. Покупка переписывает файл на двести байт, а не таблицу
-- на сто килобайт.
--
-- Формат файла - кусок Lua, который возвращает таблицу. Разбирает его сам
-- load, так что ни своего парсера, ни json не нужно. Писать его тоже просто:
-- значения бывают только числа, строки и такие же таблицы.

local fs = require("fs")

local db = {}

local format, rep, concat = string.format, string.rep, table.concat
local floor = math.floor

-- ------------------------------------------------------------------ запись

--- Строка Lua для значения. Числа целые пишутся без дробной части: иначе
--- количество предметов уезжает в 64.0 и вылезает в интерфейс.
local function dump(value, out, indent)
	local t = type(value)
	if t == "number" then
		if value == floor(value) and value == value and value ~= math.huge and value ~= -math.huge then
			out[#out + 1] = format("%d", value)
		else
			out[#out + 1] = format("%.14g", value)
		end
	elseif t == "string" then
		out[#out + 1] = format("%q", value)
	elseif t == "boolean" then
		out[#out + 1] = tostring(value)
	elseif t == "table" then
		local pad = rep(" ", indent + 1)
		out[#out + 1] = "{\n"
		-- сначала массивная часть, потом именованная: так файл читается
		-- глазами, а не только загрузчиком
		local n = #value
		for i = 1, n do
			out[#out + 1] = pad
			dump(value[i], out, indent + 1)
			out[#out + 1] = ",\n"
		end
		for k, v in pairs(value) do
			if not (type(k) == "number" and k >= 1 and k <= n and k == floor(k)) then
				out[#out + 1] = pad
				if type(k) == "string" and k:match("^[%a_][%w_]*$") then
					out[#out + 1] = k .. " = "
				else
					out[#out + 1] = "["
					dump(k, out, indent + 1)
					out[#out + 1] = "] = "
				end
				dump(v, out, indent + 1)
				out[#out + 1] = ",\n"
			end
		end
		out[#out + 1] = rep(" ", indent) .. "}"
	else
		out[#out + 1] = "nil"
	end
end

function db.serialize(value)
	local out = {}
	dump(value, out, 0)
	return concat(out)
end

-- ------------------------------------------------------------------ ключи

-- Ник приходит от мода и попадает в имя файла. Ники Minecraft - это буквы,
-- цифры и подчёркивание, но проверить дешевле, чем однажды получить ключ
-- с косой чертой и запись в чужом каталоге.
local function safe(key)
	key = tostring(key or "")
	if key == "" or #key > 64 then return nil end
	if not key:match("^[%w_%-%.]+$") then return nil end
	if key:match("^%.+$") then return nil end
	return key
end
db.safeKey = safe

-- ------------------------------------------------------------------ база

local D = {}
D.__index = D

--- root - объект из fs, dir - куда класть записи.
function db.open(root, dir)
	dir = dir or "/var/players"
	root:mkdir(dir)
	return setmetatable({ root = root, dir = dir, cache = {} }, D)
end

function D:path(key) return self.dir .. "/" .. key .. ".lua" end

--- Прочитать запись. Возвращает nil, если такой нет.
function D:get(key)
	key = safe(key)
	if not key then return nil end
	local hit = self.cache[key]
	if hit ~= nil then return hit end
	local path = self:path(key)
	if not self.root:exists(path) then return nil end
	local text = self.root:read(path)
	if not text then return nil end
	local chunk = load("return " .. text, "=" .. path, "t")
	if not chunk then return nil end
	local ok, value = pcall(chunk)
	if not ok or type(value) ~= "table" then return nil end
	self.cache[key] = value
	return value
end

--- Записать. Запись идёт во временный файл и переименовывается: выключение
--- света посреди записи не должно оставить обрезанный счёт.
function D:put(key, value)
	key = safe(key)
	if not key then return nil, "недопустимый ключ" end
	self.cache[key] = value
	local path = self:path(key)
	local tmp = path .. ".new"
	local ok, why = self.root:write(tmp, db.serialize(value) .. "\n")
	if not ok then return nil, why end
	if self.root:exists(path) then self.root:remove(path) end
	self.root:rename(tmp, path)
	return true
end

function D:delete(key)
	key = safe(key)
	if not key then return nil end
	self.cache[key] = nil
	local path = self:path(key)
	if self.root:exists(path) then return self.root:remove(path) end
	return true
end

--- Все ключи. Нужно только обслуживанию - магазин по базе не ходит.
function D:keys()
	local out = {}
	for _, name in ipairs(self.root:list(self.dir)) do
		local key = name:match("^(.+)%.lua$")
		if key then out[#out + 1] = key end
	end
	return out
end

--- Забыть, что прочитали. Кеш живёт, пока игрок стоит на PIM; после его
--- ухода данные перечитываются, иначе два терминала разойдутся.
function D:forget(key)
	if key then self.cache[safe(key) or ""] = nil else self.cache = {} end
end

-- ---------------------------------------------------- совместимость с shopcore

--- shopcore разговаривает с базой так же, как на прежней машине: select с
--- условием по колонке ID и insert по ключу. Менять его ради другой базы
--- незачем - пусть база подстроится, это три строки.
function D:select(clauses)
	local key = clauses and clauses[1] and clauses[1].value
	local row = key and self:get(key)
	return row and { row } or {}
end

function D:insert(key, value) return self:put(key, value) end

return db
