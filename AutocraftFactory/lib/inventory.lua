-- ============================================================
-- lib/inventory.lua  —  Управление инвентарём
-- Работа с create:vault, бочкой, перемещение предметов.
-- ============================================================

local M = {}

-- ── Поиск хранилищ ────────────────────────────────────────────

--- Вернуть список имён всех vault-периферий в сети.
function M.getVaults()
    local vaults = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "create:item_vault" then
            table.insert(vaults, name)
        end
    end
    return vaults
end

-- ── Сканирование инвентаря ────────────────────────────────────

--- Просканировать все vault'ы, вернуть суммарный сток {itemID → count}.
function M.scanStock(vaults)
    local stock = {}
    for _, vaultName in ipairs(vaults) do
        local v = peripheral.wrap(vaultName)
        if v then
            local ok, items = pcall(v.list)
            if ok and items then
                for _, item in pairs(items) do
                    stock[item.name] = (stock[item.name] or 0) + item.count
                end
            end
        end
    end
    return stock
end

--- Найти все слоты с нужным предметом в vault'ах.
--- @return {{vault:string, slot:number, count:number}}
function M.findItemSlots(vaults, itemID)
    local slots = {}
    for _, vaultName in ipairs(vaults) do
        local v = peripheral.wrap(vaultName)
        if v then
            local ok, items = pcall(v.list)
            if ok and items then
                for slot, item in pairs(items) do
                    if item.name == itemID then
                        table.insert(slots, { vault = vaultName, slot = slot, count = item.count })
                    end
                end
            end
        end
    end
    return slots
end

-- ── Перемещение предметов ─────────────────────────────────────

--- Извлечь `count` единиц `itemID` из vault'ов в инвентарь `destName`.
--- `destSlot` — целевой слот (nil = любой свободный).
--- Возвращает фактически перемещённое количество.
function M.extractItem(vaults, itemID, count, destName, destSlot)
    local extracted = 0
    local slots = M.findItemSlots(vaults, itemID)
    for _, s in ipairs(slots) do
        if extracted >= count then break end
        local v = peripheral.wrap(s.vault)
        if v then
            local need = count - extracted
            local ok, moved = pcall(v.pushItems, destName, s.slot, need, destSlot)
            if ok and moved then extracted = extracted + moved end
        end
    end
    return extracted
end

--- Переместить все предметы из `sourceName` в vault'ы.
-- Черепашка НЕ поддерживает list()/pushItems() через peripheral.wrap,
-- поэтому для неё используем pullItems со стороны vault'а.
function M.storeAll(vaults, sourceName)
    -- Оборачиваем vault'ы один раз
    local wv = {}
    for _, vaultName in ipairs(vaults) do
        local v = peripheral.wrap(vaultName)
        if v then table.insert(wv, { v = v, name = vaultName }) end
    end

    if sourceName:find("turtle") then
        -- Все 16 слотов параллельно
        local tasks = {}
        for slot = 1, 16 do
            local s = slot
            tasks[s] = function()
                for _, w in ipairs(wv) do
                    local ok, moved = pcall(w.v.pullItems, sourceName, s, 64)
                    if ok and moved and moved > 0 then return end
                end
            end
        end
        parallel.waitForAll(table.unpack(tasks))
        return true
    end

    local src = peripheral.wrap(sourceName)
    if not src then
        return false, "Inventory not found: " .. sourceName
    end
    local ok, items = pcall(src.list)
    if not ok or not items then return false, "Failed to read inventory" end

    -- Все занятые слоты параллельно
    local tasks = {}
    for slot, item in pairs(items) do
        if item.count > 0 then
            local s, c = slot, item.count
            tasks[#tasks + 1] = function()
                for _, w in ipairs(wv) do
                    local ok2, moved = pcall(src.pushItems, w.name, s, c)
                    if ok2 and moved and moved > 0 then return end
                end
            end
        end
    end
    if #tasks > 0 then parallel.waitForAll(table.unpack(tasks)) end
    return true
end

--- Переместить конкретный слот из `sourceName` в vault'ы.
--- Возвращает фактически сохранённое количество.
function M.storeSlot(vaults, sourceName, slot, count)
    local stored = 0
    if sourceName:find("turtle") then
        for _, vaultName in ipairs(vaults) do
            if stored >= count then break end
            local v = peripheral.wrap(vaultName)
            if v then
                local ok, moved = pcall(v.pullItems, sourceName, slot, count - stored)
                if ok and moved then stored = stored + moved end
            end
        end
        return stored
    end
    local src = peripheral.wrap(sourceName)
    if not src then return 0 end
    for _, vaultName in ipairs(vaults) do
        if stored >= count then break end
        local ok, moved = pcall(src.pushItems, vaultName, slot, count - stored)
        if ok and moved then stored = stored + moved end
    end
    return stored
end

--- Очистить инвентарь `invName` — переместить всё в vault'ы.
function M.clearInventory(vaults, invName)
    if invName:find("turtle") then
        local tasks = {}
        for slot = 1, 16 do
            local s = slot
            tasks[s] = function() M.storeSlot(vaults, invName, s, 64) end
        end
        parallel.waitForAll(table.unpack(tasks))
        return true
    end
    local inv = peripheral.wrap(invName)
    if not inv then return false end
    local ok, items = pcall(inv.list)
    if not ok or not items then return false end
    local tasks = {}
    for slot, item in pairs(items) do
        if item.count > 0 then
            local s, c = slot, item.count
            tasks[#tasks + 1] = function() M.storeSlot(vaults, invName, s, c) end
        end
    end
    if #tasks > 0 then parallel.waitForAll(table.unpack(tasks)) end
    return true
end

-- ── Бочка ─────────────────────────────────────────────────────

--- Прочитать содержимое бочки.
--- @return table|nil, string|nil
function M.getBarrelContents(barrelName)
    local b = peripheral.wrap(barrelName)
    if not b then return nil, "Barrel not found: " .. barrelName end
    local ok, items = pcall(b.list)
    if not ok then return nil, "Error reading barrel" end
    return items
end

--- Вернуть размер инвентаря периферии.
function M.getSize(invName)
    local inv = peripheral.wrap(invName)
    if not inv then return 0 end
    local ok, sz = pcall(inv.size)
    return (ok and sz) or 0
end

--- Проверить, не пустой ли инвентарь (игнорируя excludeSlots).
function M.isEmpty(invName, excludeSlots)
    local inv = peripheral.wrap(invName)
    if not inv then return true end
    local ok, items = pcall(inv.list)
    if not ok or not items then return true end
    local excl = {}
    for _, s in ipairs(excludeSlots or {}) do excl[s] = true end
    for slot, item in pairs(items) do
        if not excl[slot] and item.count > 0 then return false end
    end
    return true
end

return M
