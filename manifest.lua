-- Что из репозитория куда ложится на диск. init.lua последним: пока его
-- нет, недокачанная система не станет загрузочной.
{
	files = {
		{ "sys/disk.lua",     "/sys/disk.lua" },
		{ "sys/gfx.lua",      "/sys/gfx.lua" },
		{ "sys/catalog.lua",  "/sys/catalog.lua" },
		{ "sys/storage.lua",  "/sys/storage.lua" },
		{ "sys/vault.lua",    "/sys/vault.lua" },
		{ "sys/wallet.lua",   "/sys/wallet.lua" },
		{ "sys/rules.lua",    "/sys/rules.lua" },
		{ "sys/admin.lua",    "/sys/admin.lua" },
		{ "sys/shop.lua",     "/sys/shop.lua" },
		-- каталог двумя частями: крупные иконки на один диск не влезают.
		-- Вторая часть ложится на второй жёсткий диск, магазин найдёт её сам
		{ "data/catalog.bin",   "/data/catalog.bin",   big = true },
		{ "data/catalog.2.bin", "/data/catalog.2.bin", big = true, disk = 2 },
		{ "cfg/shop.cfg",     "/cfg/shop.cfg", keep = true },
		{ "init.lua",         "/init.lua" },
	},
	-- стирается только по --clean
	openos = { "/bin", "/lib", "/boot", "/etc", "/usr", "/home", "/mnt" },
	-- прежние версии ShopOS: стирается всегда
	obsolete = { "/os", "/data/shop.bin", "/data/icons.bin" },
}
