-- Установка ShopOS. Запускается из OpenOS на той машине, где будет магазин.
--
-- Одной командой:
--   wget -f https://raw.githubusercontent.com/ВЛАДЕЛЕЦ/РЕПО/main/install.lua /tmp/i.lua && /tmp/i.lua
--
-- Ключи:
--   --repo=ВЛАДЕЛЕЦ/РЕПО   откуда качать (по умолчанию зашит ниже)
--   --branch=ИМЯ           ветка или хеш коммита
--   --disk=АДРЕС           на какой диск ставить; по умолчанию загрузочный
--   --token=ФАЙЛ           файл с токеном, если репозиторий приватный
--   --clean                стереть OpenOS с диска перед установкой
--   --dry                  показать, что будет сделано, и выйти
--
-- Почему установку можно делать прямо поверх работающей OpenOS: ShopOS
-- занимает /os, /cfg, /data и /var, а из занятого OpenOS трогает только
-- /init.lua, и то последним. Пока файлы качаются, машина продолжает жить на
-- старой системе; новая включается со следующей перезагрузки.

local component = require("component")
local computer = require("computer")
local shell = require("shell")

------------------------------------------------------------------ настройки

local REPO    = "Faticc/shopos"
local BRANCH  = "main"
local TIMEOUT = 10

------------------------------------------------------------------ разбор

local args, opts = shell.parse(...)
REPO = opts.repo or REPO
BRANCH = opts.branch or BRANCH
local TOKEN_FILE = opts.token
local DRY = opts.dry and true or false
local CLEAN = opts.clean and true or false

local function die(text)
	io.stderr:write(text .. "\n")
	os.exit(1)
end

if not component.isAvailable("internet") then
	die("Нужна интернет-карта: без неё качать нечем.")
end
local internet = require("internet")

local token
if TOKEN_FILE then
	local f = io.open(TOKEN_FILE, "r")
	if not f then die("Нет файла с токеном: " .. TOKEN_FILE) end
	token = (f:read("*l") or ""):gsub("%s", "")
	f:close()
	if token == "" then die("Файл с токеном пуст.") end
end

------------------------------------------------------------------ диск

local target = opts.disk or computer.getBootAddress()
if not target then die("Не понял, на какой диск ставить. Задайте --disk=адрес.") end

local disk = component.proxy(component.get and component.get(target) or target)
if not disk or disk.type ~= "filesystem" then
	die("По адресу " .. tostring(target) .. " не файловая система.")
end
if disk.isReadOnly() then die("Диск только для чтения.") end

------------------------------------------------------------------ загрузка

--- Скачать один файл. Возвращает содержимое строкой или nil и причину.
--- Заголовки ответа ждём отдельно: иначе 404 молча запишется в файл как
--- html-страница, и система не загрузится по совершенно непонятной причине.
local function fetch(path)
	local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, BRANCH, path)
	local headers = { ["user-agent"] = "ShopOS-install" }
	if token then headers["Authorization"] = "Bearer " .. token end

	local ok, handle = pcall(internet.request, url, nil, headers)
	if not ok then return nil, "запрос не ушёл: " .. tostring(handle) end

	local code, message
	for _ = 1, TIMEOUT * 20 do
		local c, m = handle.response()
		if c then code, message = c, m break end
		os.sleep(0.05)
	end
	if code and code ~= 200 then
		pcall(handle.close)
		if code == 404 then
			return nil, ("нет файла %s в %s@%s"):format(path, REPO, BRANCH)
		end
		return nil, ("HTTP %s %s"):format(tostring(code), tostring(message))
	end

	local parts, n = {}, 0
	local got, err = pcall(function()
		for chunk in handle do
			n = n + 1
			parts[n] = chunk
		end
	end)
	pcall(handle.close)
	if not got then return nil, "обрыв загрузки: " .. tostring(err) end
	return table.concat(parts)
end

------------------------------------------------------------------ запись

local function mkdirs(path)
	local dir = path:match("^(.*)/[^/]*$")
	if not dir or dir == "" then return end
	if not disk.exists(dir) then disk.makeDirectory(dir) end
end

local function put(path, data)
	mkdirs(path)
	local h, why = disk.open(path, "w")
	if not h then return nil, tostring(why) end
	disk.write(h, data)
	disk.close(h)
	return true
end

------------------------------------------------------------------ ход дела

print("ShopOS: установка из " .. REPO .. "@" .. BRANCH)
print("диск:   " .. target:sub(1, 8) .. "   свободно "
	.. math.floor((disk.spaceTotal() - disk.spaceUsed()) / 1024) .. " КБ")

local manifestText, why = fetch("manifest.lua")
if not manifestText then die("Не скачался manifest.lua: " .. why) end
local manifest = load("return " .. manifestText, "=manifest", "t")
if not manifest then die("manifest.lua не разбирается.") end
manifest = manifest()

if DRY then
	print("\nбудет записано:")
	for _, f in ipairs(manifest.files) do
		local keep = f.keep and disk.exists(f[2])
		print(("  %-26s %s"):format(f[2], keep and "уже есть, не трогаю" or ""))
	end
	if CLEAN then
		print("\nбудет стёрто (--clean):")
		for _, d in ipairs(manifest.openos) do print("  " .. d) end
	end
	os.exit(0)
end

-- Стираем ДО установки: иначе только что записанное и удалим.
if CLEAN then
	print("\nстираю OpenOS...")
	for _, d in ipairs(manifest.openos) do
		if disk.exists(d) then
			disk.remove(d)
			print("  убрано " .. d)
		end
	end
end

print("")
local total, skipped = 0, 0
for _, f in ipairs(manifest.files) do
	local from, to = f[1], f[2]
	if f.keep and disk.exists(to) then
		skipped = skipped + 1
		print(("  = %-26s уже есть"):format(to))
	else
		local data, err = fetch(from)
		if not data then
			io.stderr:write(("\nОборвалось на %s: %s\n"):format(from, err))
			io.stderr:write("Записанное осталось на диске; init.lua не тронут, "
				.. "машина по-прежнему грузится как раньше.\n")
			os.exit(1)
		end
		local ok, wErr = put(to, data)
		if not ok then die(("\nНе записался %s: %s"):format(to, wErr)) end
		total = total + #data
		print(("  + %-26s %d Б"):format(to, #data))
	end
end

-- Каталоги под данные: пусть будут сразу, чтобы первая покупка не спотыкалась
for _, d in ipairs({ "/var", "/var/players" }) do
	if not disk.exists(d) then disk.makeDirectory(d) end
end

computer.setBootAddress(target)

print("")
print(("Готово: %d файлов, %d КБ%s"):format(#manifest.files - skipped,
	math.floor(total / 1024), skipped > 0 and (", конфигов не тронуто: " .. skipped) or ""))
print("Загрузочный диск переставлен на " .. target:sub(1, 8))
print("")
print("Осталось перезагрузиться:  reboot")
print("После этого машина поднимается прямо в магазин, и выйти из него")
print("будет нечем - оболочки в ShopOS нет.")
