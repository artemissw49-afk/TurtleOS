-- ============================================================
-- lib/gui.lua  —  Интерфейс на мониторе
-- Экраны: RECIPES / STOCK / CRAFT / + RECIPE
-- Управление: касание (monitor_touch), прокрутка, ввод текста.
-- ============================================================

local M = {}

-- ── Приватный контекст модуля ─────────────────────────────────

local mon                     -- peripheral монитора
local W, H = 0, 0             -- размер монитора в символах
local state_ref               -- ссылка на глобальное состояние
local cfg_ref, inv_ref, cft_ref, fld_ref

-- Таблица кнопок текущего кадра (сбрасывается при каждом рендере)
local buttons = {}

-- Фильтр рецептов по моду (nil = все)
local recipe_mod_filter = nil

-- ── Палитра цветов ────────────────────────────────────────────

local C = {
    bg        = colors.black,
    hdr_bg    = colors.black,
    hdr_fg    = colors.yellow,
    tab_on    = colors.yellow,   -- активная вкладка (фон)
    tab_off   = colors.black,    -- неактивная вкладка (фон)
    tab_fg    = colors.black,    -- текст активной вкладки
    tab_dim   = colors.gray,     -- текст неактивной вкладки
    row_a     = colors.gray,
    row_b     = colors.black,
    row_fg    = colors.white,
    sel_bg    = colors.yellow,
    sel_fg    = colors.black,
    btn_bg    = colors.yellow,
    btn_fg    = colors.black,
    btn2_bg   = colors.red,
    btn2_fg   = colors.white,
    btn3_bg   = colors.cyan,
    btn3_fg   = colors.black,
    hlite_fg  = colors.lime,
    warn_fg   = colors.orange,
    err_fg    = colors.red,
    dim_fg    = colors.gray,
    status_bg = colors.yellow,   -- фон строки прокрутки/статуса
    status_fg = colors.black,
    input_bg  = colors.gray,
    input_fg  = colors.white,
    head_col  = colors.yellow,
    head_bg   = colors.gray,
    border_bg = colors.yellow,
    border_fg = colors.black,
    pixel_on  = colors.yellow,   -- "включённый" пиксель шрифта FACTORY
    pixel_off = colors.black,    -- "выключённый" пиксель
}

-- ── Константы компоновки ──────────────────────────────────────
local TABS_ROW    = 8    -- строка с вкладками
local CONTENT_TOP = 9    -- первая строка контентной области
local FOOTER_H    = 3    -- строк в подвале (прокрутка + статус)

local TABS = {
    { id = "recipes",    label = "  RECIPES  " },
    { id = "stock",      label = "  STOCK  "   },
    { id = "fluids",     label = "  FLUIDS  "  },
    { id = "craft",      label = "  CRAFT  "   },
    { id = "add_recipe", label = "  +RECIPE  " },
}

-- ── Низкоуровневые вспомогательные функции ────────────────────

local function setC(fg, bg)
    mon.setTextColor(fg or colors.white)
    mon.setBackgroundColor(bg or colors.black)
end

local function fillLine(y, bg)
    -- Не трогаем col 1 и col W — они зарезервированы под рамку.
    setC(colors.white, bg)
    mon.setCursorPos(2, y)
    mon.write(string.rep(" ", W - 2))
end

local function writeAt(x, y, text, fg, bg)
    if y < 1 or y > H then return end
    setC(fg, bg)
    mon.setCursorPos(x, y)
    -- Обрезаем чтобы не выйти за правую границу
    local maxLen = W - x + 1
    if maxLen <= 0 then return end
    if #text > maxLen then text = text:sub(1, maxLen) end
    mon.write(text)
end

local function fillRect(x1, y1, x2, y2, bg)
    -- Зажимаем в col 2..W-1 чтобы не затирать боковые грани рамки.
    x1 = math.max(x1, 2)
    x2 = math.min(x2, W - 1)
    setC(colors.white, bg)
    local w = x2 - x1 + 1
    if w <= 0 then return end
    local line = string.rep(" ", w)
    for y = y1, y2 do
        if y >= 1 and y <= H then
            mon.setCursorPos(x1, y)
            mon.write(line)
        end
    end
end

--- Обрезать строку с добавлением '~' при превышении maxLen.
local function trunc(s, maxLen)
    s = tostring(s)
    if #s <= maxLen then return s end
    return s:sub(1, maxLen - 1) .. "~"
end

--- Зарегистрировать интерактивную зону.
-- no_flash=true — пропустить анимацию вспышки при нажатии.
local function addBtn(x1, y1, x2, y2, action, bfg, bbg, blabel, no_flash)
    table.insert(buttons, { x1=x1, y1=y1, x2=x2, y2=y2,
                             action=action, bfg=bfg, bbg=bbg, label=blabel,
                             no_flash=no_flash })
end

--- Нарисовать кнопку, вернуть X следующей позиции.
-- no_flash=true — зарегистрировать без анимации нажатия.
local function drawBtn(x, y, label, fg, bg, action, no_flash)
    local w = #label + 2
    fillRect(x, y, x + w - 1, y, bg)
    writeAt(x + 1, y, label, fg, bg)
    if action then addBtn(x, y, x + w - 1, y, action, fg, bg, label, no_flash) end
    return x + w + 1
end

-- ── Вспомогательные функции ───────────────────────────────────

--- Извлечь имя предмета без префикса мода (minecraft:stick → stick).
local function stripMod(id)
    return id:match(":(.+)$") or id
end

--- Убрать префикс напряжения GT (lv_, mv_, hv_, …) из имени машины.
local function stripTier(name)
    -- Порядок важен: длинные префиксы проверяем первыми
    local tiers = { "ulv", "luv", "uhv", "uev", "uiv", "uxv", "opv", "max",
                    "zpm", "uv", "lv", "mv", "hv", "ev", "iv" }
    for _, t in ipairs(tiers) do
        local p = t .. "_"
        if name:sub(1, #p) == p then return name:sub(#p + 1) end
    end
    return name
end

--- Вернуть список машин в сети для экрана "+ RECIPE".
--- Обычные машины одного типа объединяются в одну запись (name = ptype).
--- Специальные (extruder, chemical_reactor и др.) выводятся по отдельности.
local function getMachineList()
    local stdExclude = {
        modem = true, monitor = true, speaker = true,
        ["create:item_vault"] = true,
        ["minecraft:barrel"]  = true,
    }
    local excludeNames = {}
    for _, v in ipairs((cfg_ref and cfg_ref.excluded_machines) or {}) do
        excludeNames[v] = true
    end
    local specials = (cfg_ref and cfg_ref.special_machines) or {}
    local function isSpecial(ptype)
        local bare = stripMod(ptype)
        for _, pat in ipairs(specials) do
            if bare:find(pat, 1, true) then return true end
        end
        return false
    end

    local typeGroups   = {}   -- ptype → { names... }
    local specialItems = {}   -- { name, ptype }

    for _, pname in ipairs(peripheral.getNames()) do
        if not excludeNames[pname] and not pname:find("turtle") then
            local ptype = peripheral.getType(pname)
            if ptype and not stdExclude[ptype] and not excludeNames[ptype] then
                if isSpecial(ptype) then
                    table.insert(specialItems, { name = pname, ptype = ptype })
                else
                    if not typeGroups[ptype] then typeGroups[ptype] = {} end
                    table.insert(typeGroups[ptype], pname)
                end
            end
        end
    end

    local result = {}

    -- Обычные машины: одна запись на тип
    for ptype, names in pairs(typeGroups) do
        table.sort(names)
        local bare = stripMod(ptype)
        local disp = #names > 1 and (bare .. " (x" .. #names .. ")") or bare
        table.insert(result, { name = ptype, ptype = ptype, display = disp })
    end

    -- Специальные машины: каждая по отдельности
    for _, m in ipairs(specialItems) do
        local bare = stripMod(m.ptype)
        local disp = stripMod(m.name)
        -- Экструдер: читаем форму из инвентаря
        if m.ptype:find("extruder", 1, true) then
            local ok, items = pcall(function()
                local p = peripheral.wrap(m.name)
                return p and p.list and p.list()
            end)
            if ok and items then
                for _, item in pairs(items) do
                    local moldName = stripMod(item.name):match("^(.-)_extruder_mold$")
                    if moldName then disp = bare .. " (" .. moldName .. ")"; break end
                end
            end
        end
        table.insert(result, { name = m.name, ptype = m.ptype, display = disp })
    end

    table.sort(result, function(a, b) return a.display < b.display end)
    return result
end

-- ── Пиксельный шрифт 5×5 ─────────────────────────────────────
-- Каждая буква: 5 строк по 5 бит (bit4=левый, bit0=правый).

local PIXEL_FONT = {
    F = {0x1F, 0x10, 0x1E, 0x10, 0x10},
    A = {0x0E, 0x11, 0x1F, 0x11, 0x11},
    C = {0x0F, 0x10, 0x10, 0x10, 0x0F},
    T = {0x1F, 0x04, 0x04, 0x04, 0x04},
    O = {0x0E, 0x11, 0x11, 0x11, 0x0E},
    R = {0x1E, 0x11, 0x1E, 0x14, 0x12},
    Y = {0x11, 0x11, 0x0E, 0x04, 0x04},
    I = {0x1F, 0x04, 0x04, 0x04, 0x1F},
    S = {0x0F, 0x10, 0x0E, 0x01, 0x1E},
    E = {0x1F, 0x10, 0x1E, 0x10, 0x1F},
    N = {0x11, 0x19, 0x15, 0x13, 0x11},
    G = {0x0F, 0x10, 0x17, 0x11, 0x0F},
}

--- Нарисовать строку крупным пиксельным шрифтом, центрировано.
--- @param text     string   Текст (только символы из PIXEL_FONT)
--- @param startY   number   Первая строка рисования (5 строк в высоту)
--- @param onColor  color    Цвет включённого пикселя
--- @param offColor color    Цвет фона / выключенного пикселя
--- @param pixW     number   Ширина 1 пикселя в символах (по умолчанию 2)
local function drawPixelText(text, startY, onColor, offColor, pixW)
    pixW = pixW or 2
    local GAP = pixW          -- пробел между буквами
    local letters = {}
    for c in text:upper():gmatch(".") do table.insert(letters, c) end

    local totalW = #letters * (5 * pixW) + (#letters - 1) * GAP
    local startX = math.max(2, math.floor((W - totalW) / 2) + 1)

    for row = 1, 5 do
        local x = startX
        for li, letter in ipairs(letters) do
            local bits = PIXEL_FONT[letter]
            if bits then
                local rowBits = bits[row]
                for bit = 4, 0, -1 do
                    local on = math.floor(rowBits / (2 ^ bit)) % 2 == 1
                    mon.setBackgroundColor(on and onColor or offColor)
                    mon.setCursorPos(x, startY + row - 1)
                    mon.write(string.rep(" ", pixW))
                    x = x + pixW
                end
            end
            if li < #letters then
                mon.setBackgroundColor(offColor)
                mon.setCursorPos(x, startY + row - 1)
                mon.write(string.rep(" ", GAP))
                x = x + GAP
            end
        end
    end
end

--- Нарисовать боковые границы рамки (перекрывает последний слой).
local function drawBorderSides()
    mon.setBackgroundColor(C.border_bg)
    for row = 2, H - 1 do
        mon.setCursorPos(1, row)
        mon.write(" ")
        mon.setCursorPos(W, row)
        mon.write(" ")
    end
end

-- ── Заголовок ─────────────────────────────────────────────────

local function drawHeader()
    -- Строка 1: верхняя жёлтая полоса рамки
    mon.setBackgroundColor(C.border_bg)
    mon.setCursorPos(1, 1)
    mon.write(string.rep(" ", W))

    -- Строки 2–6: чёрный фон для пиксельного шрифта (col 2..W-1, не трогаем рамку)
    mon.setBackgroundColor(C.pixel_off)
    for row = 2, 6 do
        mon.setCursorPos(2, row)
        mon.write(string.rep(" ", W - 2))
    end

    -- FACTORY крупным пиксельным шрифтом (строки 2–6).
    -- Адаптивная ширина пикселя: 2 символа при широком мониторе, иначе 1.
    local pixW = (W >= 90) and 2 or 1
    drawPixelText("FACTORY", 2, C.pixel_on, C.pixel_off, pixW)

    -- Строка 7: разделитель — жёлтые тире + статистика
    local itemTypes  = 0
    local totalItems = 0
    for _, cnt in pairs(state_ref.stock or {}) do
        itemTypes  = itemTypes + 1
        totalItems = totalItems + cnt
    end
    local stats = string.format(" Vaults:%d  Types:%d  Total:%d ",
        #(state_ref.vaults or {}), itemTypes, totalItems)

    mon.setBackgroundColor(C.pixel_off)
    mon.setTextColor(C.border_bg)
    -- Тире от col 2 до W-1 (col 1 и W закроет рамка)
    mon.setCursorPos(2, 7)
    mon.write(string.rep("-", W - 2))
    -- Статистика справа (заканчивается на W-1, не перекрывает рамку)
    local maxStatW = W - 3               -- доступная ширина (col 2..W-1)
    local statsOut = stats:sub(1, maxStatW)
    local statsX   = math.max(2, W - 1 - #statsOut + 1)
    mon.setCursorPos(statsX, 7)
    mon.write(statsOut)
end

-- ── Вкладки ───────────────────────────────────────────────────

local function drawTabs()
    -- Строка 8: фон (col 2..W-1, не трогаем рамку)
    mon.setBackgroundColor(C.bg)
    mon.setCursorPos(2, TABS_ROW)
    mon.write(string.rep(" ", W - 2))

    local x = 3
    for _, tab in ipairs(TABS) do
        local active = (state_ref.screen == tab.id)
        local fg = active and C.tab_fg or C.tab_dim
        local bg = active and C.tab_on or C.tab_off

        mon.setBackgroundColor(bg)
        mon.setTextColor(fg)
        mon.setCursorPos(x, TABS_ROW)
        mon.write(tab.label)

        local tid = tab.id
        addBtn(x, TABS_ROW, x + #tab.label - 1, TABS_ROW, function()
            state_ref.screen = tid
            state_ref.scroll = 0
            if tid == "add_recipe" then state_ref.add_machine_page = 0 end
            state_ref.needs_redraw = true
        end)
        x = x + #tab.label + 2
    end
end

-- ── Подвал ────────────────────────────────────────────────────

local function drawFooter()
    local scrollRow = H - 1
    local statusRow = H

    -- ── Строка прокрутки (H-1): жёлтый фон ──────────────────────
    mon.setBackgroundColor(C.border_bg)
    mon.setCursorPos(1, scrollRow)
    mon.write(string.rep(" ", W))

    local nx = 3
    nx = drawBtn(nx, scrollRow, " ^ ", C.border_fg, colors.orange, function()
        state_ref.scroll = math.max(0, state_ref.scroll - 1)
        state_ref.needs_redraw = true
    end)
    nx = drawBtn(nx, scrollRow, " v ", C.border_fg, colors.orange, function()
        state_ref.scroll = state_ref.scroll + 1
        state_ref.needs_redraw = true
    end)

    -- Статус крафта на строке прокрутки
    local craftMsg = ""
    local craftFg  = C.border_fg
    if state_ref.craft_status == "running" then
        craftMsg = "  [*] " .. (state_ref.craft_message or "Crafting...")
        craftFg  = colors.black
    elseif state_ref.craft_status == "done" then
        craftMsg = "  [+] " .. (state_ref.craft_message or "Done")
        craftFg  = colors.green
    elseif state_ref.craft_status == "error" then
        craftMsg = "  [!] " .. (state_ref.craft_message or "Error")
        craftFg  = colors.red
    end
    if craftMsg ~= "" then
        writeAt(nx, scrollRow, trunc(craftMsg, W - nx - 2), craftFg, C.border_bg)
    end

    -- ── Нижняя строка (H): жёлтая полоса рамки со статусом ──────
    mon.setBackgroundColor(C.border_bg)
    mon.setCursorPos(1, statusRow)
    mon.write(string.rep(" ", W))

    local msg = state_ref.status_msg or "Ready"
    local fg  = state_ref.status_err and colors.red or C.border_fg
    writeAt(3, statusRow, trunc(msg, W - 16), fg, C.border_bg)

    -- Кнопка Refresh в правом углу нижней полосы
    drawBtn(W - 11, statusRow, " Refresh ", C.border_fg, colors.orange, function()
        state_ref.vaults = inv_ref.getVaults()
        state_ref.stock  = inv_ref.scanStock(state_ref.vaults)
        state_ref.status_msg = "Stock refreshed"
        state_ref.status_err = false
        state_ref.needs_redraw = true
    end)
end

-- ── Экран: RECIPES ────────────────────────────────────────────

local function drawScreenRecipes()
    local recipes = state_ref.recipes

    -- Собираем уникальные моды
    local modSet = {}
    for id in pairs(recipes) do
        local mod = id:match("^([^:]+):") or "other"
        modSet[mod] = true
    end
    local modList = {}
    for mod in pairs(modSet) do table.insert(modList, mod) end
    table.sort(modList)

    local y0 = CONTENT_TOP

    -- Контентная область: сдвинута левее центра на 6 символов
    local CW = math.min(W - 4, 80)
    local CX = math.max(2, math.floor((W - CW) / 2) + 1 - 6)
    local colOut  = CX + math.floor(CW * 0.73)
    local colType = colOut + 7          -- 7 символов для OUTPUT, потом TYPE

    -- Шапка
    fillLine(y0, C.head_bg)
    writeAt(CX + 1,  y0, "ITEM",   C.head_col, C.head_bg)
    writeAt(colOut,  y0, "OUTPUT", C.head_col, C.head_bg)
    writeAt(colType, y0, "TYPE",   C.head_col, C.head_bg)
    y0 = y0 + 1

    -- Подвкладки по модам (только если модов > 1)
    if #modList > 1 then
        fillLine(y0, C.status_bg)
        -- Сброс невалидного фильтра
        if recipe_mod_filter ~= nil and not modSet[recipe_mod_filter] then
            recipe_mod_filter = nil
        end
        local fx = 3
        local allActive = recipe_mod_filter == nil
        fx = drawBtn(fx, y0, "All",
            allActive and C.tab_fg or C.tab_dim,
            allActive and C.tab_on  or C.tab_off,
            function() recipe_mod_filter = nil; state_ref.scroll = 0; state_ref.needs_redraw = true end)
        for _, mod in ipairs(modList) do
            local active = (recipe_mod_filter == mod)
            local m = mod  -- closure copy
            fx = drawBtn(fx, y0, mod,
                active and C.tab_fg or C.tab_dim,
                active and C.tab_on or C.tab_off,
                function() recipe_mod_filter = m; state_ref.scroll = 0; state_ref.needs_redraw = true end)
        end
        y0 = y0 + 1
    end

    -- Строим отфильтрованный список, сортированный по имени без мода
    local list = {}
    for id, r in pairs(recipes) do
        local mod = id:match("^([^:]+):") or "other"
        if recipe_mod_filter == nil or mod == recipe_mod_filter then
            table.insert(list, { id = id, recipe = r, name = stripMod(id) })
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)

    local ITEM_H    = 1
    local visCount  = math.floor((H - y0 - FOOTER_H) / ITEM_H)
    local maxScroll = math.max(0, #list - visCount)
    state_ref.scroll = math.min(state_ref.scroll, maxScroll)

    local startIdx = state_ref.scroll + 1
    local endIdx   = math.min(#list, startIdx + visCount - 1)

    fillRect(1, y0, W, H - FOOTER_H, C.bg)

    for i = startIdx, endIdx do
        local entry = list[i]
        local r     = entry.recipe
        local rowY  = y0 + (i - startIdx) * ITEM_H
        if rowY > H - FOOTER_H then break end

        local selected = (entry.id == state_ref.selected)
        local bg = selected and C.sel_bg or (i % 2 == 0 and C.row_a or C.row_b)
        local fg = selected and C.sel_fg or C.row_fg

        -- Единственная строка: имя | кнопки | выход | тип
        fillLine(rowY, bg)
        local nameW = colOut - 22 - (CX + 2)
        local nameStr = trunc(entry.name, nameW)
        writeAt(CX + 1 + (nameW - #nameStr), rowY, nameStr, fg, bg)

        local bx = colOut - 22
        bx = drawBtn(bx, rowY, ">Craft", C.btn_fg, C.btn_bg, function()
            state_ref.selected     = entry.id
            state_ref.screen       = "craft"
            state_ref.craft_amount = "1"
            state_ref.scroll       = 0
            state_ref.needs_redraw = true
        end)
        bx = drawBtn(bx, rowY, "Edit", colors.white, colors.gray, function()
            state_ref.add_type    = r.type or "turtle"
            state_ref.add_machine = r.machine or ""
            state_ref.add_preview = r
            state_ref.screen      = "add_recipe"
            state_ref.scroll      = 0
            state_ref.needs_redraw = true
        end)
        local isPending = (state_ref.del_pending == entry.id)
        local delLabel  = isPending and "Del?" or "Del"
        local delFg     = isPending and colors.white  or C.btn2_fg
        local delBg     = isPending and colors.red    or C.btn2_bg
        drawBtn(bx, rowY, delLabel, delFg, delBg, function()
            local id = entry.id
            if state_ref.del_pending == id then
                -- Второй клик — удаляем
                state_ref.recipes[id] = nil
                cft_ref.saveRecipes(state_ref.recipes, cfg_ref.recipes_file)
                if state_ref.selected == id then state_ref.selected = nil end
                state_ref.del_pending = nil
                state_ref.status_msg  = "Deleted: " .. id
                state_ref.status_err  = false
            else
                -- Первый клик — помечаем как ожидающий удаления
                state_ref.del_pending = id
            end
            state_ref.needs_redraw = true
        end)

        local outStr = trunc("x" .. (r.output and r.output.count or "?"), 6)
        writeAt(colOut, rowY, outStr, C.warn_fg, bg)

        local typeStr
        if r.type == "turtle" then
            typeStr = "craft"
        elseif r.machine then
            typeStr = stripTier(stripMod(r.machine))
        else
            typeStr = r.type or "?"
        end
        local typeW = CX + CW - colType
        writeAt(colType, rowY, trunc(typeStr, typeW), colors.lightGray, bg)

        addBtn(CX, rowY, CX + CW, rowY, function()
            state_ref.selected    = entry.id
            state_ref.del_pending = nil
            state_ref.needs_redraw = true
        end)
    end

    if #list == 0 then
        writeAt(2, y0 + 1, "No recipes. Go to '+ RECIPE'.", C.dim_fg, C.bg)
    end

    if #list > 0 then
        local pag = string.format(" %d-%d / %d ", startIdx, endIdx, #list)
        writeAt(W - #pag, H - 1, pag, C.dim_fg, C.status_bg)
    end
end

-- ── Экран: STOCK ──────────────────────────────────────────────

local function drawScreenStock()
    local stock = state_ref.stock
    local y0    = CONTENT_TOP

    -- Центрованная контентная область
    local CW = math.min(W - 2, 60)
    local CX = math.floor((W - CW) / 2) + 1
    local cntCol = CX + CW  -- правый край (позиция последнего символа счётчика)

    fillLine(y0, C.head_bg)
    writeAt(CX + 1, y0, "ITEM",  C.head_col, C.head_bg)
    writeAt(cntCol - 4, y0, "COUNT", C.head_col, C.head_bg)

    local list = {}
    for id, cnt in pairs(stock) do
        table.insert(list, { id = id, count = cnt })
    end
    table.sort(list, function(a, b) return a.id < b.id end)

    local visCount  = H - y0 - FOOTER_H
    local maxScroll = math.max(0, #list - visCount)
    state_ref.scroll = math.min(state_ref.scroll, maxScroll)

    local startIdx = state_ref.scroll + 1
    local endIdx   = math.min(#list, startIdx + visCount - 1)

    fillRect(1, y0 + 1, W, H - FOOTER_H, C.bg)

    for i = startIdx, endIdx do
        local entry = list[i]
        local rowY  = y0 + 1 + (i - startIdx)
        if rowY > H - FOOTER_H then break end

        local bg     = i % 2 == 0 and C.row_a or C.row_b
        local hasRec = state_ref.recipes[entry.id] ~= nil
        local fg     = hasRec and C.hlite_fg or C.row_fg

        fillLine(rowY, bg)
        local cntStr = tostring(entry.count)
        writeAt(cntCol - #cntStr + 1, rowY, cntStr, C.warn_fg, bg)
        writeAt(CX + 1, rowY, trunc(entry.id, CW - #cntStr - 2), fg, bg)

        if hasRec then
            addBtn(CX, rowY, CX + CW, rowY, function()
                state_ref.selected     = entry.id
                state_ref.screen       = "craft"
                state_ref.craft_amount = "1"
                state_ref.scroll       = 0
                state_ref.needs_redraw = true
            end)
        end
    end

    if #list == 0 then
        writeAt(CX + 1, y0 + 2, "Storages empty or not found.", C.dim_fg, C.bg)
    end

    local total = 0
    for _, cnt in pairs(stock) do total = total + cnt end
    local sumStr = string.format(" Types:%d Total:%d ", #list, total)
    writeAt(W - #sumStr, H - 1, sumStr, C.dim_fg, C.status_bg)
end

-- ── Экран: FLUIDS ─────────────────────────────────────────────

local function drawScreenFluids()
    if not fld_ref then
        writeAt(2, CONTENT_TOP + 1, "Fluid module not loaded.", C.err_fg, C.bg)
        return
    end

    local storageTanks = fld_ref.getStorageTanks(cfg_ref)
    local fluids       = fld_ref.scanFluids(storageTanks)

    local y0 = CONTENT_TOP
    local CW = math.min(W - 2, 60)
    local CX = math.floor((W - CW) / 2) + 1
    local amtCol = CX + CW

    fillLine(y0, C.head_bg)
    writeAt(CX + 1, y0, "FLUID",  C.head_col, C.head_bg)
    writeAt(amtCol - 9, y0, "AMOUNT", C.head_col, C.head_bg)

    -- Собрать и отсортировать список жидкостей
    local list = {}
    for name, info in pairs(fluids) do
        table.insert(list, { name = name, amount = info.amount })
    end
    table.sort(list, function(a, b) return a.name < b.name end)

    local visCount  = H - y0 - FOOTER_H
    local maxScroll = math.max(0, #list - visCount)
    state_ref.scroll = math.min(state_ref.scroll, maxScroll)

    local startIdx = state_ref.scroll + 1
    local endIdx   = math.min(#list, startIdx + visCount - 1)

    fillRect(1, y0 + 1, W, H - FOOTER_H, C.bg)

    for i = startIdx, endIdx do
        local entry = list[i]
        local rowY  = y0 + 1 + (i - startIdx)
        if rowY > H - FOOTER_H then break end

        local bg = i % 2 == 0 and C.row_a or C.row_b
        fillLine(rowY, bg)

        local amtStr = tostring(entry.amount) .. " mB"
        writeAt(amtCol - #amtStr + 1, rowY, amtStr, C.warn_fg, bg)
        writeAt(CX + 1, rowY,
            trunc(stripMod(entry.name), CW - #amtStr - 2), C.row_fg, bg)
    end

    if #list == 0 then
        writeAt(CX + 1, y0 + 2, "No fluids found in storage tanks.", C.dim_fg, C.bg)
    end

    local sumStr = string.format(" Tanks:%d  Fluids:%d ", #storageTanks, #list)
    writeAt(W - #sumStr, H - 1, sumStr, C.dim_fg, C.status_bg)
end

-- ── Экран: CRAFT ──────────────────────────────────────────────

local function drawScreenCraft()
    local y = CONTENT_TOP
    fillRect(1, y, W, H - FOOTER_H, C.bg)

    local selID = state_ref.selected
    if not selID then
        writeAt(2, y + 1, "Select a recipe on the RECIPES or STOCK tab.", C.dim_fg, C.bg)
        return
    end

    local recipe = state_ref.recipes[selID]
    if not recipe then
        writeAt(2, y + 1, "Recipe not found: " .. selID, C.err_fg, C.bg)
        return
    end

    -- Строка: выбранный предмет
    fillLine(y, C.head_bg)
    writeAt(2, y, "Craft:  " .. trunc(selID, W - 20), colors.white, C.head_bg)
    local typeStr = "Type: " .. recipe.type
    writeAt(W - #typeStr - 1, y, typeStr, C.dim_fg, C.head_bg)
    y = y + 2

    -- Количество
    local isFluidRecipe = recipe.output_type == "fluid"
    -- Инициализируем значение по умолчанию для типа рецепта
    local defaultAmt = isFluidRecipe and "1000" or "1"
    if not state_ref.craft_amount or state_ref.craft_amount == "1" and isFluidRecipe
                                  or state_ref.craft_amount == "1000" and not isFluidRecipe then
        state_ref.craft_amount = defaultAmt
    end

    local amtLabel = isFluidRecipe and "Amount (mB):" or "Amount:"
    writeAt(2, y, amtLabel, colors.white, C.bg)
    local amtX   = isFluidRecipe and 15 or 11
    local amtW   = 8
    local amt    = state_ref.craft_amount or defaultAmt
    local inputActive = state_ref.input_active and state_ref.input_field == "craft_amount"
    local inputBg = inputActive and colors.yellow or C.input_bg
    fillRect(amtX, y, amtX + amtW - 1, y, inputBg)
    writeAt(amtX + 1, y, trunc(amt, amtW - 2), C.input_fg, inputBg)
    addBtn(amtX, y, amtX + amtW - 1, y, function()
        state_ref.input_active = true
        state_ref.input_field  = "craft_amount"
        state_ref.needs_redraw = true
    end)

    local nx = amtX + amtW + 1
    if isFluidRecipe then
        nx = drawBtn(nx, y, "-100", colors.white, C.row_a, function()
            local n = math.max(1000, (tonumber(state_ref.craft_amount) or 1000) - 100)
            state_ref.craft_amount = tostring(n)
            state_ref.needs_redraw = true
        end)
        nx = drawBtn(nx, y, "+100", colors.white, C.row_a, function()
            local n = (tonumber(state_ref.craft_amount) or 1000) + 100
            state_ref.craft_amount = tostring(n)
            state_ref.needs_redraw = true
        end)
        for _, qty in ipairs({ 1000, 5000, 10000, 50000, 100000 }) do
            nx = drawBtn(nx, y, tostring(qty), colors.black, C.row_a, function()
                state_ref.craft_amount = tostring(qty)
                state_ref.needs_redraw = true
            end)
        end
    else
        nx = drawBtn(nx, y, "-", colors.white, C.row_a, function()
            local n = math.max(1, (tonumber(state_ref.craft_amount) or 1) - 1)
            state_ref.craft_amount = tostring(n)
            state_ref.needs_redraw = true
        end)
        nx = drawBtn(nx, y, "+", colors.white, C.row_a, function()
            local n = (tonumber(state_ref.craft_amount) or 1) + 1
            state_ref.craft_amount = tostring(n)
            state_ref.needs_redraw = true
        end)
        for _, qty in ipairs({ 8, 16, 32, 64, 128 }) do
            nx = drawBtn(nx, y, tostring(qty), colors.black, C.row_a, function()
                state_ref.craft_amount = tostring(qty)
                state_ref.needs_redraw = true
            end)
        end
    end
    y = y + 2

    -- Дерево крафта
    local minAmt = isFluidRecipe and 1000 or 1
    local amount = math.max(minAmt, tonumber(state_ref.craft_amount) or minAmt)
    local queue, missing = cft_ref.buildCraftTree(selID, amount, state_ref.stock, state_ref.recipes)

    fillLine(y, C.head_bg)
    writeAt(2, y,
        string.format("Craft tree  (%d operations)", #queue),
        colors.white, C.head_bg)
    y = y + 1

    local maxTreeRows = H - y - FOOTER_H - 2
    for i, job in ipairs(queue) do
        if i > maxTreeRows then
            writeAt(3, y, string.format("... and %d more operations", #queue - i + 1), C.dim_fg, C.bg)
            y = y + 1; break
        end
        fillLine(y, C.bg)
        local icon = job.recipe.type == "turtle" and "[T]" or "[M]"
        local line = string.format("%s %-40s  x%-6d (%d op.)",
            icon, trunc(job.itemID, 40), job.totalOutput, job.ops)
        writeAt(2, y, trunc(line, W - 2), C.row_fg, C.bg)
        y = y + 1
    end

    -- Недостающие ресурсы
    if next(missing) then
        if y <= H - FOOTER_H - 1 then
            fillLine(y, C.btn2_bg)
            writeAt(2, y, "MISSING RESOURCES:", colors.white, C.btn2_bg)
            y = y + 1
        end
        for id, cnt in pairs(missing) do
            if y > H - FOOTER_H - 2 then break end
            fillLine(y, C.bg)
            writeAt(3, y, string.format("[!] %s  x%d", trunc(id, W - 12), cnt), C.err_fg, C.bg)
            y = y + 1
        end
    end

    -- Кнопки действий
    local btnY = H - FOOTER_H
    fillLine(btnY, C.bg)
    local bx = 2

    if state_ref.craft_status == "running" then
        -- ── Прогресс-бар ─────────────────────────────────────────
        local prog = state_ref.craft_progress
        if prog and prog.total and prog.total > 0 then
            -- Строка per-item: "tin_rod 2/4  tin_ingot 4/4  ..."
            local parts = {}
            if prog.per_total then
                local keys = {}
                for k in pairs(prog.per_total) do table.insert(keys, k) end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    local done  = prog.per_done  and (prog.per_done[k]  or 0) or 0
                    local total = prog.per_total[k]
                    table.insert(parts, stripMod(k) .. " " .. done .. "/" .. total)
                end
            end
            local itemsLine = table.concat(parts, "  ")
            fillLine(btnY - 2, C.bg)
            writeAt(2, btnY - 2, trunc(itemsLine, W - 2), C.row_fg, C.bg)

            -- Визуальная полоска: [====-------] 45%
            local pct    = math.floor(prog.completed * 100 / prog.total)
            local barW   = W - 10
            local filled = math.floor(barW * prog.completed / prog.total)
            local bar    = string.rep("\127", filled) .. string.rep("-", barW - filled)
            fillLine(btnY - 1, C.bg)
            writeAt(2,         btnY - 1, "[",  C.dim_fg,  C.bg)
            writeAt(3,         btnY - 1, bar,  colors.lime, C.bg)
            writeAt(3 + barW,  btnY - 1, "]",  C.dim_fg,  C.bg)
            writeAt(3 + barW + 2, btnY - 1, pct .. "%", C.warn_fg, C.bg)
        end
        writeAt(bx, btnY, "  [*]  Crafting... please wait  ", C.warn_fg, C.bg)
    elseif not next(missing) then
        bx = drawBtn(bx, btnY, "  > START CRAFT  ", C.btn_fg, C.btn_bg, function()
            if state_ref.craft_status ~= "running" then
                state_ref._pending_craft = {
                    itemID = selID,
                    amount = amount,
                }
                state_ref.craft_status  = "running"
                state_ref.craft_message = "Starting..."
                state_ref.needs_redraw  = true
            end
        end)
    else
        writeAt(bx, btnY, " [!] Cannot craft - restock storage ", C.err_fg, C.bg)
        bx = bx + 38
    end

    if state_ref.craft_status == "done" or state_ref.craft_status == "error" then
        drawBtn(bx, btnY, " Reset status ", colors.black, colors.gray, function()
            state_ref.craft_status  = "idle"
            state_ref.craft_message = ""
            state_ref.needs_redraw  = true
        end)
    end
end

-- ── Экран: + RECIPE ──────────────────────────────────────────

local function drawScreenAddRecipe()
    local y = CONTENT_TOP
    fillRect(1, y, W, H - FOOTER_H, C.bg)

    fillLine(y, C.head_bg)
    writeAt(2, y, "Add / edit recipe", colors.white, C.head_bg)
    y = y + 2

    -- Тип крафта
    writeAt(2, y, "Craft type:", colors.white, C.bg)
    local nx = 15
    local isTurtle = state_ref.add_type == "turtle"
    nx = drawBtn(nx, y, " Turtle  ", colors.black,
        isTurtle and C.hlite_fg or C.row_a, function()
        state_ref.add_type    = "turtle"
        state_ref.add_preview = nil
        state_ref.needs_redraw = true
    end)
    drawBtn(nx, y, " Machine ", colors.black,
        (not isTurtle) and C.hlite_fg or C.row_a, function()
        state_ref.add_type    = "machine"
        state_ref.add_preview = nil
        state_ref.needs_redraw = true
    end)
    y = y + 2

    if isTurtle then
        -- ── TURTLE: тест-крафт ────────────────────────────────
        writeAt(2, y, "Place ingredients in barrel grid slots:", C.dim_fg, C.bg); y = y + 1
        writeAt(2, y, "  [4][5][6]  [13][14][15]  [22][23][24]", C.dim_fg, C.bg); y = y + 2

        if state_ref.craft_status == "running" then
            writeAt(2, y, "[*] Test crafting... please wait", C.warn_fg, C.bg)
        else
            local nx2 = 2
            nx2 = drawBtn(nx2, y, " Test craft ", colors.black, C.btn3_bg, function()
                state_ref._pending_test_craft = true
                state_ref.craft_status        = "running"
                state_ref.craft_message       = "Starting test craft..."
                state_ref.needs_redraw        = true
            end)
            if state_ref.add_preview then
                drawBtn(nx2, y, " Clear ", colors.white, C.btn2_bg, function()
                    state_ref.add_preview = nil
                    state_ref.needs_redraw = true
                end)
            end
        end
        y = y + 2

    else
        -- ── MACHINE: список машин + scan barrel ───────────────
        writeAt(2, y, "Machine name:", colors.white, C.bg)
        local mx = 17
        local mw = math.floor(W * 0.5) - mx
        local mach = state_ref.add_machine or ""
        local mAct = state_ref.input_active and state_ref.input_field == "add_machine"
        local mBg  = mAct and colors.yellow or C.input_bg
        fillRect(mx, y, mx + mw - 1, y, mBg)
        writeAt(mx + 1, y, trunc(mach, mw - 2), C.input_fg, mBg)
        addBtn(mx, y, mx + mw - 1, y, function()
            state_ref.input_active = true
            state_ref.input_field  = "add_machine"
            state_ref.needs_redraw = true
        end)
        y = y + 2

        -- Список доступных машин (скрываем, когда уже есть preview)
        if state_ref.add_preview or state_ref._fluid_select_mode then
            -- результат уже получен — список не нужен
        else
        writeAt(2, y, "Available peripherals (click to select):", C.dim_fg, C.bg); y = y + 1
        local machines = getMachineList()
        -- Зарезервируем 1 строку под кнопки <</>>, если страниц > 1
        local maxMach  = H - y - FOOTER_H - 5
        if maxMach < 1 then maxMach = 1 end
        if #machines == 0 then
            writeAt(3, y, "(none found on network)", C.dim_fg, C.bg); y = y + 1
        else
            local pageCount = math.max(1, math.ceil(#machines / maxMach))
            -- Собственный счётчик страниц — не мешает глобальному scroll
            local page = math.min(math.max(state_ref.add_machine_page or 0, 0), pageCount - 1)
            state_ref.add_machine_page = page

            local startM = page * maxMach + 1
            local endM   = math.min(#machines, startM + maxMach - 1)

            -- Строка навигации << страница >> (только если страниц > 1)
            if pageCount > 1 then
                local navY = y
                fillLine(navY, C.bg)
                local nx = 3
                -- Кнопка <<
                if page > 0 then
                    nx = drawBtn(nx, navY, "<<", C.border_fg, C.border_bg, function()
                        state_ref.add_machine_page = page - 1
                        state_ref.needs_redraw = true
                    end, true)
                else
                    nx = nx + 5  -- пустое место вместо <<
                end
                -- Текст страницы
                local pag = string.format(" %d/%d ", page + 1, pageCount)
                writeAt(nx, navY, pag, C.dim_fg, C.bg)
                nx = nx + #pag
                -- Кнопка >>
                if page < pageCount - 1 then
                    drawBtn(nx, navY, ">>", C.border_fg, C.border_bg, function()
                        state_ref.add_machine_page = page + 1
                        state_ref.needs_redraw = true
                    end, true)
                end
                y = y + 1
            end

            for i = startM, endM do
                local m   = machines[i]
                local isSel = (state_ref.add_machine == m.name)
                local mbg = isSel and C.sel_bg or C.bg
                local mfg = isSel and C.sel_fg or C.row_fg
                fillLine(y, mbg)
                writeAt(3, y, trunc(m.display, W - 4), mfg, mbg)
                local mn = m.name
                addBtn(3, y, W - 1, y, function()
                    state_ref.add_machine  = mn
                    state_ref.input_active = false
                    state_ref.needs_redraw = true
                end, mfg, mbg)
                y = y + 1
            end
        end
        y = y + 1
        end  -- if not add_preview (machine list)

        local nx3 = 2
        if state_ref.craft_status == "running" then
            writeAt(nx3, y, "[*] Processing machine...", C.warn_fg, C.bg)
            drawBtn(nx3 + 27, y, " Cancel ", C.btn2_fg, C.btn2_bg, function()
                state_ref._cancel_test_craft = true
                state_ref.needs_redraw = true
            end)
        else
            local canTest = (state_ref.add_machine or "") ~= ""
            nx3 = drawBtn(nx3, y, " Test craft ",
                canTest and colors.black or colors.white,
                canTest and C.btn3_bg    or C.row_a,
                canTest and function()
                    state_ref._pending_test_craft = true
                    state_ref._cancel_test_craft  = false
                    state_ref.craft_status        = "running"
                    state_ref.craft_message       = "Starting machine test craft..."
                    state_ref.needs_redraw        = true
                end or nil)
            if state_ref.add_preview then
                drawBtn(nx3, y, " Clear ", colors.white, C.btn2_bg, function()
                    state_ref.add_preview = nil
                    state_ref.needs_redraw = true
                end)
            end
        end
        y = y + 2
    end

    -- ── Выбор жидкого выхода (когда несколько жидкостей) ─────────
    if state_ref._fluid_select_mode then
        local outputs = state_ref._fluid_select_outputs or {}
        fillLine(y, C.head_bg)
        writeAt(2, y, "Multiple fluid outputs:", colors.white, C.head_bg)
        y = y + 1
        for fname, famt in pairs(outputs) do
            local bare = fname:match(":(.+)$") or fname
            writeAt(3, y, string.format("%s  %d mB", bare, famt), C.hlite_fg, C.bg)
            y = y + 1
        end
        writeAt(2, y, "Remove unwanted fluids, then press Ready.", C.warn_fg, C.bg)
        y = y + 1
        drawBtn(2, y, "  Ready  ", C.btn_fg, C.btn_bg, function()
            -- Читаем какая жидкость осталась в excluded-танках
            local fl = nil
            for _, tankName in ipairs(cfg_ref.excluded_super_tanks or {}) do
                fl = fld_ref and fld_ref.getTankFluid(tankName)
                if fl then break end
            end
            local recipe = state_ref._fluid_select_recipe
            if fl and recipe then
                recipe.output      = { id = fl.name, count = fl.amount }
                recipe.output_type = "fluid"
                state_ref.add_preview = recipe
                state_ref.status_msg  = "Ready: " .. fl.name
                state_ref.status_err  = false
            else
                state_ref.status_msg = "No fluid found in excluded tanks!"
                state_ref.status_err = true
            end
            state_ref._fluid_select_mode    = false
            state_ref._fluid_select_recipe  = nil
            state_ref._fluid_select_outputs = nil
            state_ref.needs_redraw = true
        end)
        drawBtn(14, y, "  Cancel  ", colors.white, C.row_a, function()
            state_ref._fluid_select_mode    = false
            state_ref._fluid_select_recipe  = nil
            state_ref._fluid_select_outputs = nil
            state_ref.needs_redraw = true
        end)
        y = y + 2

    -- ── Предпросмотр результата и подтверждение ───────────────
    elseif state_ref.add_preview then
        local pr = state_ref.add_preview
        fillLine(y, C.head_bg)
        writeAt(2, y, "Result:", colors.white, C.head_bg)
        y = y + 1

        local outLabel = string.format("  %s  x%d",
            trunc(pr.output.id, W - 14), pr.output.count)
        if pr.output_type == "fluid" then
            outLabel = string.format("  [FLUID] %s  %d mB",
                trunc(stripMod(pr.output.id), W - 18), pr.output.count)
        end
        writeAt(2, y, outLabel, C.hlite_fg, C.bg)
        y = y + 1

        local fluidIng = pr.fluid_ingredients or {}
        writeAt(2, y,
            string.format("  Items: %d  Fluids: %d  (%s%s)",
                #pr.ingredients, #fluidIng, pr.type,
                pr.machine and ("  machine: " .. stripMod(pr.machine)) or ""),
            C.dim_fg, C.bg)
        y = y + 1

        if pr.type == "machine" then
            writeAt(2, y, "  Decide output: keep item in barrel slot 14 OR", C.dim_fg, C.bg); y = y + 1
            writeAt(2, y, "  one fluid in excluded tank, then click Save.", C.dim_fg, C.bg)
        else
            writeAt(2, y, "  Tip: change qty — edit barrel slot 14 before saving", C.dim_fg, C.bg)
        end
        y = y + 2

        writeAt(2, y, "Save this recipe?", colors.white, C.bg)
        y = y + 1
        local bx = 2
        bx = drawBtn(bx, y, "  Yes, save  ", C.btn_fg, C.btn_bg, function()
            local pr2 = state_ref.add_preview
            if not pr2 then return end

            if pr2.type == "machine" then
                -- Определяем выход: проверяем слот 14 бочки и excluded-танки
                local bc   = inv_ref.getBarrelContents(cfg_ref.barrel)
                local ri14 = bc and bc[14]

                local fluidOutput = nil
                if fld_ref then
                    for _, tankName in ipairs(cfg_ref.excluded_super_tanks or {}) do
                        local fl = fld_ref.getTankFluid(tankName)
                        if fl then fluidOutput = fl; break end
                    end
                end

                if ri14 then
                    pr2.output      = { id = ri14.name, count = ri14.count }
                    pr2.output_type = "item"
                elseif fluidOutput then
                    pr2.output      = { id = fluidOutput.name, count = fluidOutput.amount }
                    pr2.output_type = "fluid"
                else
                    state_ref.status_msg = "Nothing to save! Put item in barrel slot 14 OR fluid in excluded tank."
                    state_ref.status_err = true
                    state_ref.needs_redraw = true
                    return
                end
            else
                -- Turtle: перечитываем слот 14 бочки
                local bc   = inv_ref.getBarrelContents(cfg_ref.barrel)
                local ri14 = bc and bc[14]
                if ri14 and ri14.name == pr2.output.id then
                    pr2.output.count = ri14.count
                end
            end

            state_ref.recipes[pr2.output.id] = pr2
            cft_ref.saveRecipes(state_ref.recipes, cfg_ref.recipes_file)
            state_ref.status_msg  = "Saved: " .. pr2.output.id
                                    .. " x" .. pr2.output.count
            state_ref.status_err  = false
            state_ref.add_preview = nil
            state_ref.screen      = "recipes"
            state_ref.scroll      = 0
            state_ref.needs_redraw = true
        end)
        drawBtn(bx, y, "  No, cancel  ", colors.white, C.row_a, function()
            state_ref.add_preview = nil
            state_ref.needs_redraw = true
        end)
    elseif isTurtle and state_ref.craft_status ~= "running" then
        writeAt(2, y, "No result yet. Press 'Test craft'.", C.dim_fg, C.bg)
    end
end

-- ── Главный рендер ────────────────────────────────────────────

local function drawAll()
    buttons = {}

    -- Двойная буферизация (если поддерживается)
    if mon.setVisible then mon.setVisible(false) end

    -- Не вызываем mon.clear() — каждый блок сам закрашивает свою область.
    -- Строка H-2 не покрывается ни хедером, ни контентом, ни футером — очищаем явно.
    fillLine(H - 2, C.bg)

    drawHeader()
    drawTabs()

    if     state_ref.screen == "recipes"    then drawScreenRecipes()
    elseif state_ref.screen == "stock"      then drawScreenStock()
    elseif state_ref.screen == "fluids"     then drawScreenFluids()
    elseif state_ref.screen == "craft"      then drawScreenCraft()
    elseif state_ref.screen == "add_recipe" then drawScreenAddRecipe()
    end

    drawFooter()
    drawBorderSides()   -- поверх всего — боковые грани рамки

    if mon.setVisible then mon.setVisible(true) end

    state_ref.needs_redraw = false
end

-- ── Обработка касания ─────────────────────────────────────────

local function handleTouch(x, y)
    for _, btn in ipairs(buttons) do
        if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
            if btn.action then
                if not btn.no_flash then
                    -- Flash: инвертируем цвета, но оставляем текст видимым
                    local flashBg = btn.bfg or colors.white
                    local flashFg = btn.bbg or colors.black
                    mon.setCursorPos(btn.x1, btn.y1)
                    mon.setBackgroundColor(flashBg)
                    mon.setTextColor(flashFg)
                    if btn.label then
                        mon.write(" " .. btn.label .. " ")
                    else
                        mon.write(string.rep(" ", btn.x2 - btn.x1 + 1))
                    end
                    sleep(0.08)
                end
                btn.action()
                return true
            end
        end
    end
    return false
end

-- ── Обработка текстового ввода ────────────────────────────────

local function handleInputEvent(ev, a)
    if not state_ref.input_active then return end
    local field = state_ref.input_field
    local cur   = tostring(state_ref[field] or "")

    if ev == "char" then
        state_ref[field] = cur .. a
        state_ref.needs_redraw = true
    elseif ev == "key" then
        if a == keys.backspace then
            state_ref[field] = cur:sub(1, -2)
            state_ref.needs_redraw = true
        elseif a == keys.enter or a == keys.escape then
            state_ref.input_active = false
            state_ref.input_field  = nil
            state_ref.status_msg   = "Ready"
            state_ref.needs_redraw = true
        end
    end
end

-- ── Тест-крафт для записи рецепта ────────────────────────────

local function startPendingTestCraft()
    state_ref._pending_test_craft = false
    state_ref._cancel_test_craft  = false
    local done = false

    local statusCb = function(m, isErr)
        state_ref.craft_message = m
        state_ref.status_msg    = m
        state_ref.status_err    = isErr
        state_ref.needs_redraw  = true
    end

    parallel.waitForAny(
        function()
            local recipe, err
            if state_ref.add_type == "machine" then
                recipe, err = cft_ref.craftTestMachine(
                    state_ref.add_machine, cfg_ref, inv_ref, fld_ref, statusCb,
                    function() return state_ref._cancel_test_craft end)
            else
                recipe, err = cft_ref.craftTestRecipe(cfg_ref, inv_ref, statusCb)
            end

            if recipe then
                -- Считаем сколько жидких выходов получилось
                local fluidOutCount = 0
                for _ in pairs(recipe.fluid_outputs or {}) do fluidOutCount = fluidOutCount + 1 end

                if recipe.output_type == "fluid" and fluidOutCount > 1 then
                    -- Несколько жидкостей → ждём выбора пользователя
                    state_ref._fluid_select_mode    = true
                    state_ref._fluid_select_recipe  = recipe
                    state_ref._fluid_select_outputs = recipe.fluid_outputs
                    state_ref.status_msg = "Multiple fluid outputs! Remove unwanted, then press Ready."
                    state_ref.status_err = false
                else
                    state_ref.add_preview = recipe
                    state_ref.status_msg  = "Test craft OK: " .. recipe.output.id
                    state_ref.status_err  = false
                end
                state_ref.craft_status = "idle"
            else
                state_ref.status_msg   = "Test craft failed: " .. (err or "?")
                state_ref.status_err   = true
                state_ref.craft_status = "error"
            end
            state_ref.needs_redraw = true
            done = true
        end,
        function()
            drawAll()
            while not done do
                local ev, a, b, c = os.pullEvent()
                handleInputEvent(ev, a)
                if ev == "monitor_touch" and a == cfg_ref.monitor then
                    handleTouch(b, c)
                elseif ev == "mouse_scroll" then
                    state_ref.scroll = math.max(0, state_ref.scroll + a)
                    state_ref.needs_redraw = true
                end
                if state_ref.needs_redraw then drawAll() end
            end
        end
    )
end

-- ── Запуск крафта с параллельным GUI ─────────────────────────

local function startPendingCraft()
    local pc = state_ref._pending_craft
    state_ref._pending_craft = nil

    local craftFinished = false

    parallel.waitForAny(
        -- Поток 1: выполнение крафта
        function()
            state_ref.craft_progress = nil
            local ok, msg, missing = cft_ref.runAutocraft(
                pc.itemID, pc.amount,
                state_ref.stock,
                state_ref.vaults,
                state_ref.recipes,
                cfg_ref,
                inv_ref,
                function(m, isErr)
                    state_ref.craft_message = m
                    state_ref.status_msg    = m
                    state_ref.status_err    = isErr
                    state_ref.needs_redraw  = true
                end,
                fld_ref,
                function(done, total, itemID, perItemDone, perItemTotal)
                    state_ref.craft_progress = {
                        completed    = done,
                        total        = total,
                        item         = itemID,
                        per_done     = perItemDone,
                        per_total    = perItemTotal,
                    }
                    state_ref.needs_redraw = true
                end
            )

            -- Обновляем состояние по итогу крафта
            if ok then
                state_ref.craft_status  = "done"
                state_ref.craft_message = msg
                state_ref.status_msg    = msg
                state_ref.status_err    = false
            else
                state_ref.craft_status  = "error"
                state_ref.craft_message = msg
                state_ref.status_msg    = msg
                state_ref.status_err    = true
                state_ref.craft_missing = missing or {}
            end

            -- Обновляем склад после завершения
            state_ref.stock        = inv_ref.scanStock(state_ref.vaults)
            state_ref.needs_redraw = true
            craftFinished = true
        end,

        -- Поток 2: GUI остаётся отзывчивым во время крафта
        function()
            drawAll()
            while not craftFinished do
                local ev, a, b, c = os.pullEvent()
                handleInputEvent(ev, a)
                if ev == "monitor_touch" and a == cfg_ref.monitor then
                    handleTouch(b, c)
                elseif ev == "mouse_scroll" then
                    state_ref.scroll = math.max(0, state_ref.scroll + a)
                    state_ref.needs_redraw = true
                elseif ev == "key" then
                    handleInputEvent(ev, a)
                end
                if state_ref.needs_redraw then drawAll() end
            end
        end
    )
end

-- ── Публичный API ─────────────────────────────────────────────

--- Инициализировать монитор и сохранить ссылку на состояние.
function M.init(monName, state)
    mon = peripheral.wrap(monName)
    if not mon then error("Monitor not found: " .. monName) end

    state_ref = state

    -- Устанавливаем масштаб
    if mon.setTextScale then
        mon.setTextScale(cfg_ref and cfg_ref.text_scale or 0.5)
    end

    W, H = mon.getSize()
    state.mon_w = W
    state.mon_h = H
    mon.setCursorBlink(false)
end

--- Главный цикл GUI. Запускать через parallel.waitForAny.
function M.run(state, cfg, inv, cft, fld)
    state_ref = state
    cfg_ref   = cfg
    inv_ref   = inv
    cft_ref   = cft
    fld_ref   = fld

    -- Переустанавливаем масштаб (init мог вызваться до присвоения cfg_ref)
    if mon and mon.setTextScale then
        mon.setTextScale(cfg.text_scale or 0.5)
        W, H = mon.getSize()
        state.mon_w = W
        state.mon_h = H
    end

    while true do
        -- Отрисовка
        if state_ref.needs_redraw then
            pcall(drawAll)
        end

        -- Запуск ожидающего крафта
        if state_ref._pending_craft then
            startPendingCraft()
        end

        -- Запуск тест-крафта (для записи рецепта)
        if state_ref._pending_test_craft then
            startPendingTestCraft()
        end

        -- Ожидание события
        local ev, a, b, c = os.pullEvent()

        -- Обработка ввода (если активен)
        handleInputEvent(ev, a)

        if ev == "monitor_touch" and a == cfg.monitor then
            handleTouch(b, c)

        elseif ev == "mouse_scroll" then
            -- a = направление (-1 вверх, 1 вниз)
            state_ref.scroll = math.max(0, state_ref.scroll + a)
            state_ref.needs_redraw = true

        elseif ev == "key" and not state_ref.input_active then
            if a == keys.f5 then
                state_ref.vaults     = inv_ref.getVaults()
                state_ref.stock      = inv_ref.scanStock(state_ref.vaults)
                state_ref.status_msg = "Stock refreshed (F5)"
                state_ref.needs_redraw = true
            elseif a == keys.pageUp then
                state_ref.scroll = math.max(0, state_ref.scroll - 5)
                state_ref.needs_redraw = true
            elseif a == keys.pageDown then
                state_ref.scroll = state_ref.scroll + 5
                state_ref.needs_redraw = true
            end

        elseif ev == "peripheral" or ev == "peripheral_detach" then
            -- Периферия изменилась — обновить vault'ы
            state_ref.vaults = inv_ref.getVaults()
            state_ref.needs_redraw = true

        elseif ev == "term_resize" or ev == "monitor_resize" then
            W, H = mon.getSize()
            state_ref.mon_w = W
            state_ref.mon_h = H
            state_ref.needs_redraw = true
        end
    end
end

return M
