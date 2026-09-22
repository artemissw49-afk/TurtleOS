-- ============================================================
-- startup.lua  —  Точка входа системы автокрафта
-- CC: Tweaked + Advanced Peripherals
--
-- Схема запуска:
--   • Эта программа запускается на Advanced Computer.
--   • turtle_agent.lua запускается отдельно на черепашке.
--   • Все устройства подключены через проводные модемы.
--
-- Управление на мониторе:
--   Касание экрана   — выбор, кнопки
--   ▲ / ▼           — прокрутка списков
--   F5               — принудительное обновление склада
--   PageUp/PageDown  — быстрая прокрутка (5 строк)
-- ============================================================

-- ── Инициализация путей ───────────────────────────────────────
if not fs.exists("/data") then fs.makeDir("/data") end

-- ── Загрузка модулей ─────────────────────────────────────────
local cfg = require("config")
local inv = require("lib.inventory")
local cft = require("lib.craft")
local gui = require("lib.gui")
local fld = require("lib.fluid")

-- ── Глобальное состояние (разделяется между GUI и фоном) ──────
local state = {
    -- Навигация
    screen = "recipes",   -- "recipes" | "stock" | "craft" | "add_recipe"
    scroll = 0,

    -- Данные
    recipes = {},
    stock   = {},
    vaults  = {},

    -- Тест-крафт для записи рецепта
    _pending_test_craft = false,
    _cancel_test_craft  = false,

    -- Крафт: выбор
    selected     = nil,      -- itemID выбранного рецепта
    craft_amount = "1",      -- строка (редактируется пользователем)

    -- Крафт: выполнение
    _pending_craft  = nil,           -- {itemID, amount} — триггер запуска
    craft_status    = "idle",        -- "idle"|"running"|"done"|"error"
    craft_message   = "",
    craft_missing   = {},

    -- Добавление рецепта
    add_type    = "turtle",
    add_machine = "",
    add_preview = nil,

    -- Ввод с клавиатуры
    input_active = false,
    input_field  = nil,

    -- Статус-бар
    status_msg = "Initializing...",
    status_err = false,

    -- Размер монитора (заполняется в gui.init)
    mon_w = 0, mon_h = 0,

    -- Флаг перерисовки
    needs_redraw = true,
}

-- ── Инициализация ─────────────────────────────────────────────
local function init()
    -- Инициализируем монитор (до cfg_ref — передаём cfg напрямую)
    -- gui.init вызывается с cfg_ref=nil, масштаб будет скорректирован в gui.run
    gui.init(cfg.monitor, state)

    -- Загружаем рецепты
    state.recipes = cft.loadRecipes(cfg.recipes_file)

    -- Сканируем сеть
    state.vaults = inv.getVaults()
    if #state.vaults == 0 then
        state.status_msg = string.format(
            "No storages of type '%s' found!", cfg.vault_type)
        state.status_err = true
    else
        state.status_msg = string.format(
            "Found %d storage(s)", #state.vaults)
    end

    -- Первичный скан инвентаря
    state.stock = inv.scanStock(state.vaults)
    state.needs_redraw = true

    -- тест связи: отправим "Hello" черепашке сразу при запуске
    local modem = peripheral.find("modem")
    if modem then
        rednet.open(peripheral.getName(modem))
        if cfg.turtle_rednet_id and cfg.turtle_rednet_id > 0 then
            rednet.send(cfg.turtle_rednet_id, "Hello")
        else
            rednet.broadcast("Hello")
        end
    else
    end
end

-- ── Фоновый поток: периодическое обновление склада ────────────
local function backgroundLoop()
    while true do
        sleep(cfg.stock_refresh)
        state.vaults       = inv.getVaults()
        state.stock        = inv.scanStock(state.vaults)
        state.needs_redraw = true
    end
end

-- ── Поток: малый монитор управления жидкостями ────────────────

local function fluidsMonitorLoop()
    local monName = cfg.fluids_monitor
    if not monName then return end

    local fmon = peripheral.wrap(monName)
    if not fmon then return end

    if fmon.setTextScale then fmon.setTextScale(0.5) end
    local FW, FH = fmon.getSize()

    -- Локальные кнопки монитора (сбрасываются при каждом рендере)
    local fbtns  = {}
    local status = ""
    local statusErr = false

    local function fWriteAt(x, y, text, fg, bg)
        if y < 1 or y > FH then return end
        fmon.setTextColor(fg or colors.white)
        fmon.setBackgroundColor(bg or colors.black)
        fmon.setCursorPos(x, y)
        local maxLen = FW - x + 1
        if maxLen <= 0 then return end
        if #text > maxLen then text = text:sub(1, maxLen) end
        fmon.write(text)
    end

    local function fFillLine(y, bg)
        fmon.setBackgroundColor(bg or colors.black)
        fmon.setCursorPos(1, y)
        fmon.write(string.rep(" ", FW))
    end

    local function fAddBtn(x1, y1, x2, y2, action)
        table.insert(fbtns, { x1=x1, y1=y1, x2=x2, y2=y2, action=action })
    end

    local function fDrawBtn(x, y, label, fg, bg, action)
        local w = #label + 2
        fmon.setBackgroundColor(bg)
        fmon.setCursorPos(x, y)
        fmon.write(string.rep(" ", w))
        fWriteAt(x + 1, y, label, fg, bg)
        if action then fAddBtn(x, y, x + w - 1, y, action) end
        return x + w + 1
    end

    local function redraw()
        fbtns = {}
        FW, FH = fmon.getSize()
        fmon.setBackgroundColor(colors.black)
        fmon.clear()

        local excluded = cfg.excluded_super_tanks or {}
        local storageTanks = fld.getStorageTanks(cfg)

        -- Заголовок
        fFillLine(1, colors.blue)
        fWriteAt(2, 1, "FLUID PUMP", colors.white, colors.blue)

        -- Строки для каждого excluded tank (_48 сверху, _44 снизу)
        for dispIdx = 1, #excluded do
            local tankName = excluded[#excluded - dispIdx + 1]
            local y = dispIdx + 1
            if y > FH - 2 then break end
            fFillLine(y, colors.gray)

            local fl = fld.getTankFluid(tankName)
            local label
            if fl then
                -- Коротко: имя без мода + объём
                local bare = fl.name:match(":(.+)$") or fl.name
                label = string.format("%-14s %dB", bare:sub(1, 14), fl.amount)
            else
                label = "(empty)"
            end
            fWriteAt(2, y, label, colors.white, colors.gray)

            local tn = tankName
            local st = storageTanks
            fDrawBtn(FW - 4, y, "<<", colors.black, colors.lime, function()
                status    = "Pumping..."
                statusErr = false
                local moved, msg = fld.pumpToStorage(tn, st)
                if moved > 0 then
                    status = string.format("Moved %d mB", moved)
                else
                    status    = msg
                    statusErr = true
                end
            end)
        end

        -- Кнопка Pump all
        local pumpY = #excluded + 2
        if pumpY <= FH - 1 then
            fFillLine(pumpY, colors.black)
            fDrawBtn(2, pumpY, " Pump all ", colors.black, colors.cyan, function()
                status    = "Pumping all..."
                statusErr = false
                local st2 = fld.getStorageTanks(cfg)
                local total = 0
                for _, tn in ipairs(cfg.excluded_super_tanks or {}) do
                    local moved = fld.pumpToStorage(tn, st2)
                    total = total + moved
                    -- Обновляем список танков после каждой перекачки
                    st2 = fld.getStorageTanks(cfg)
                end
                status = string.format("Done: %d mB total", total)
            end)
        end

        -- Строка статуса
        fFillLine(FH, colors.gray)
        local sc = statusErr and colors.red or colors.lime
        fWriteAt(2, FH, status:sub(1, FW - 2), sc, colors.gray)
    end

    redraw()

    while true do
        local ev, mon3, x, y = os.pullEvent()
        if ev == "monitor_touch" and mon3 == monName then
            for _, btn in ipairs(fbtns) do
                if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
                    btn.action()
                    break
                end
            end
            redraw()
        elseif ev == "monitor_resize" and mon3 == monName then
            redraw()
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            fmon = peripheral.wrap(monName)
            if fmon then redraw() end
        end
    end
end

-- ── Запуск ────────────────────────────────────────────────────
local ok, err = pcall(init)
if not ok then
    -- Критическая ошибка инициализации — выводим в терминал
    printError("Init error: " .. tostring(err))
    print("Press Enter to exit.")
    read()
    return
end

-- Запускаем GUI и фоновый поток параллельно.
-- parallel.waitForAny завершится если любой поток вернёт значение
-- (в норме — никогда, оба бесконечные циклы).
parallel.waitForAny(
    function() gui.run(state, cfg, inv, cft, fld) end,
    function() backgroundLoop() end,
    function() fluidsMonitorLoop() end
)
