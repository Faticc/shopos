-- Установка ShopOS из OpenOS:
--   wget -f https://raw.githubusercontent.com/Faticc/shopos/main/install.lua /tmp/i.lua && /tmp/i.lua
--
--   --repo=владелец/репо  --branch=ветка  --disk=адрес
--   --clean  стереть OpenOS (и прежний ShopOS из /os)   --dry  только показать

local component = require("component")
local computer = require("computer")
local shell = require("shell")

local _, opts = shell.parse(...)
local REPO = opts.repo or "Faticc/shopos"
local BRANCH = opts.branch or "main"

local function die(s) io.stderr:write(s .. "\n") os.exit(1) end

if not component.isAvailable("internet") then die("нужна интернет-карта") end
local internet = require("internet")

local target = opts.disk or computer.getBootAddress()
local disk = component.proxy(component.get(target) or target)
if not disk or disk.type ~= "filesystem" or disk.isReadOnly() then
	die("диск " .. tostring(target) .. " не годится")
end

--- Скачать файл; sink(chunk) получает его по кускам. Каталог весит два
--- мегабайта - целиком в память машины он не лезет, пишется потоком.
local function fetch(path, sink)
	local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, BRANCH, path)
	local ok, h = pcall(internet.request, url, nil, { ["user-agent"] = "ShopOS" })
	if not ok then return nil, tostring(h) end
	local code
	for _ = 1, 200 do
		code = h.response()
		if code then break end
		os.sleep(0.05)
	end
	if code and code ~= 200 then
		pcall(h.close)
		return nil, "HTTP " .. code .. " (" .. path .. ")"
	end
	local size = 0
	local got, err = pcall(function()
		for chunk in h do
			size = size + #chunk
			sink(chunk)
		end
	end)
	pcall(h.close)
	if not got then return nil, tostring(err) end
	return size
end

--- Скачать прямо в файл: сначала рядом, подмена - только если всё дошло.
local function download(from, to)
	local dir = to:match("^(.*)/[^/]*$")
	if dir and dir ~= "" and not disk.exists(dir) then disk.makeDirectory(dir) end
	local tmp = to .. ".part"
	local h, why = disk.open(tmp, "w")
	if not h then return nil, why end
	local size, err = fetch(from, function(chunk) disk.write(h, chunk) end)
	disk.close(h)
	if not size then disk.remove(tmp) return nil, err end
	disk.remove(to)
	disk.rename(tmp, to)
	return size
end

print("ShopOS: " .. REPO .. "@" .. BRANCH .. " -> диск " .. target:sub(1, 8))
local parts = {}
local got, why = fetch("manifest.lua", function(c) parts[#parts + 1] = c end)
if not got then die("manifest.lua: " .. tostring(why)) end
local src = table.concat(parts)
local manifest = load("return " .. src, "=manifest", "t", {})()

if opts.dry then
	for _, f in ipairs(manifest.files) do
		print("  " .. f[2] .. ((f.keep and disk.exists(f[2])) and "  (есть, не трогаю)" or ""))
	end
	os.exit(0)
end

if opts.clean then
	for _, d in ipairs(manifest.openos) do
		if disk.exists(d) then disk.remove(d) print("  стёрто " .. d) end
	end
end

for _, f in ipairs(manifest.files) do
	if f.keep and disk.exists(f[2]) then
		print("  = " .. f[2])
	else
		local size, err = download(f[1], f[2])
		if not size then die("оборвалось на " .. f[1] .. ": " .. tostring(err) .. "\n/init.lua не тронут") end
		print(("  + %-20s %d КБ"):format(f[2], math.ceil(size / 1024)))
	end
end

if not disk.exists("/var") then disk.makeDirectory("/var") end
computer.setBootAddress(target)
print("готово, осталось: reboot")
