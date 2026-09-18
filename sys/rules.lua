-- rules - что магазин скупает и что продаёт только за деньги.
--
-- Скупка: ресурс из списка игрок сдаёт на ресурсный счёт по цене из
-- выгрузки, умноженной на курс скупки (100% - один в один). Только за
-- деньги: эти товары за ресурсы не продаются - на сервере их за ресурсы
-- не отдают (иридий и прочее).
--
-- Начальные списки - из cfg/shop.cfg, а если там их нет - встроенные.
-- Админка правит их на ходу и сохраняет на диск данных в rules.cfg; с
-- этого момента главнее он, и переустановка его не трогает.

local vault = require("vault")

local floor, max, min = math.floor, math.max, math.min

local rules = {}

local RESOURCES = {
	"minecraft:iron_ingot", "minecraft:gold_ingot", "minecraft:diamond",
	"minecraft:redstone", "minecraft:coal", "minecraft:dye:4", "minecraft:quartz",
	"IC2:itemIngot", "IC2:itemIngot:1", "IC2:itemIngot:5", "IC2:itemIngot:6",
}
local MONEY_ONLY = {
	"AdvancedSolarPanel:asp_crafting_items:10", "IC2:itemOreIridium",
	"IC2:itemPartIridium", "IC2:itemShardIridium", "dwcity:Iridium_ingot",
	"dwcity:Materia",
}

local FILE = vault.path("/rules.cfg")
local sets = { res = {}, only = {} }
local rate = 100          -- курс скупки, % цены из выгрузки

local function fill(name, list)
	sets[name] = {}
	for _, k in ipairs(list) do sets[name][k] = true end
end

function rules.init(cfg)
	local t = vault.fs and vault.fs:table(FILE) or {}
	fill("res", t.resources or cfg.resources or RESOURCES)
	fill("only", t.moneyOnly or cfg.moneyOnly or MONEY_ONLY)
	rate = floor(tonumber(t.rate or cfg.buyRate or 100) or 100)
end

--- Скупается ли предмет с этим ключом каталога.
function rules.accepts(key) return sets.res[key] == true end

--- Продаётся ли только за деньги.
function rules.moneyOnly(key) return sets.only[key] == true end

function rules.rate() return rate end

--- Ключи списка ("res" или "only") по алфавиту.
function rules.list(name)
	local out = {}
	for k in pairs(sets[name]) do out[#out + 1] = k end
	table.sort(out)
	return out
end

local function save()
	if not vault.fs then return false end
	local out = { "-- скупка и «только за деньги»: правит админка магазина", "{",
		("\trate = %d,"):format(rate) }
	for _, p in ipairs({ { "resources", "res" }, { "moneyOnly", "only" } }) do
		out[#out + 1] = "\t" .. p[1] .. " = {"
		for _, k in ipairs(rules.list(p[2])) do out[#out + 1] = ("\t\t%q,"):format(k) end
		out[#out + 1] = "\t},"
	end
	out[#out + 1] = "}"
	return vault.fs:writeAll(FILE, table.concat(out, "\n") .. "\n")
end

--- Включить или выключить ключ в списке. Возвращает новое состояние и
--- записалось ли на диск.
function rules.toggle(name, key)
	sets[name][key] = not sets[name][key] or nil
	return sets[name][key] == true, save()
end

--- Курс скупки в процентах, от 1 до 1000. Возвращает новый и записалось ли.
function rules.setRate(p)
	rate = max(1, min(1000, floor(p)))
	return rate, save()
end

return rules
