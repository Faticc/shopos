-- Что из репозитория куда ложится на диск. init.lua последним: пока его
-- нет, недокачанная система не станет загрузочной.
{
	files = {
		{ "sys/disk.lua",    "/sys/disk.lua",  size = 4034, crc = "f4f1ea5d" },
		{ "sys/gfx.lua",     "/sys/gfx.lua",   size = 5755, crc = "82afaf36" },
		{ "sys/catalog.lua", "/sys/catalog.lua",size = 6729, crc = "8812a011" },
		{ "sys/storage.lua", "/sys/storage.lua",size = 6278, crc = "754e836d" },
		{ "sys/vault.lua",   "/sys/vault.lua", size = 5478, crc = "b9f8d648" },
		{ "sys/wallet.lua",  "/sys/wallet.lua",size = 7503, crc = "10a6dd92" },
		{ "sys/rules.lua",   "/sys/rules.lua", size = 4264, crc = "4d95c36b" },
		{ "sys/update.lua",  "/sys/update.lua",size = 14780, crc = "398424a8" },
		{ "sys/admin.lua",   "/sys/admin.lua", size = 23576, crc = "73c9c92b" },
		{ "sys/shop.lua",    "/sys/shop.lua",  size = 51226, crc = "48f23642" },
		-- каталог двумя частями: крупные иконки на один диск не влезают.
		-- Вторая часть ложится на второй жёсткий диск, магазин найдёт её сам
		{ "data/catalog.bin", "/data/catalog.bin",size = 2661940, crc = "690383a0", big = true },
		{ "data/catalog.2.bin", "/data/catalog.2.bin",size = 2970624, crc = "2812a7f8", big = true, disk = 2 },
		{ "cfg/shop.cfg",    "/cfg/shop.cfg",  size = 3279, crc = "b8d18532", keep = true },
		{ "init.lua",        "/init.lua",      size = 4650, crc = "c1b2e830" },
	},
	-- стирается только по --clean
	openos = { "/bin", "/lib", "/boot", "/etc", "/usr", "/home", "/mnt" },
	-- прежние версии ShopOS: стирается всегда
	obsolete = { "/os", "/data/shop.bin", "/data/icons.bin" },
}
