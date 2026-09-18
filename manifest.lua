-- Что из репозитория куда ложится на диск.
--
-- Читается установщиком. Пути слева - от корня репозитория, справа - от
-- корня диска. Порядок важен: init.lua пишется последним, чтобы наполовину
-- скачанная система не оказалась загрузочной.

{
	files = {
		{ "os/fs.lua",        "/os/fs.lua" },
		{ "os/event.lua",     "/os/event.lua" },
		{ "os/db.lua",        "/os/db.lua" },
		{ "os/paint.lua",     "/os/paint.lua" },
		{ "os/oci3.lua",      "/os/oci3.lua" },
		{ "os/icons.lua",     "/os/icons.lua" },
		{ "os/ui.lua",        "/os/ui.lua" },
		{ "os/meio.lua",      "/os/meio.lua" },
		{ "os/shopcore.lua",  "/os/shopcore.lua" },

		{ "os/shop.lua",       "/os/shop.lua" },

		{ "data/icons.bin",    "/data/icons.bin",   binary = true },

		-- конфиги не перезаписываются, если уже лежат: цены правит владелец
		-- магазина, а не установщик
		{ "cfg/shop.cfg",         "/cfg/shop.cfg",         keep = true },
		{ "cfg/sellShop.cfg",     "/cfg/sellShop.cfg",     keep = true },
		{ "cfg/buyShop.cfg",      "/cfg/buyShop.cfg",      keep = true },
		{ "cfg/oreExchanger.cfg", "/cfg/oreExchanger.cfg", keep = true },
		{ "cfg/exchanger.cfg",    "/cfg/exchanger.cfg",    keep = true },
		{ "cfg/icons.cfg",        "/cfg/icons.cfg",        keep = true },

		-- последним: пока его нет, диск не загрузочный
		{ "init.lua",          "/init.lua" },
	},

	-- Каталоги OpenOS: стираются только по явному --clean, и только до
	-- установки, а не после. ShopOS нарочно живёт в /os, /cfg, /data и /var,
	-- чтобы ничего из этого списка не задеть, - установка на тот же диск не
	-- ломает работающую OpenOS до самой перезагрузки.
	openos = { "/bin", "/lib", "/boot", "/etc", "/usr", "/home", "/mnt" },
}
