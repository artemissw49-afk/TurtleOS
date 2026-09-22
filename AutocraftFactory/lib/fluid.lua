-- ============================================================
-- lib/fluid.lua  —  Управление жидкостями
-- Работа с gtceu:lv_super_tank: чтение, перекачка.
-- ============================================================

local M = {}

--- Прочитать жидкость из танка.
--- @return {name:string, amount:number, capacity:number}|nil
function M.getTankFluid(tankName)
    local t = peripheral.wrap(tankName)
    if not t then return nil end
    local ok, result = pcall(t.tanks)
    if ok and result then
        for _, fl in ipairs(result) do
            if fl and fl.name and fl.amount and fl.amount > 0 then
                return fl
            end
        end
    end
    return nil
end

--- Вернуть все имена super_tank'ов в сети, кроме исключённых.
function M.getStorageTanks(cfg)
    local excluded = {}
    for _, name in ipairs(cfg.excluded_super_tanks or {}) do
        excluded[name] = true
    end
    local tanks = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "gtceu:lv_super_tank" and not excluded[name] then
            table.insert(tanks, name)
        end
    end
    table.sort(tanks)
    return tanks
end

--- Агрегировать жидкости по хранилищу.
--- @return {[fluidName]:{amount:number, tanks:string[]}}
function M.scanFluids(storageTanks)
    local fluids = {}
    for _, tankName in ipairs(storageTanks) do
        local fl = M.getTankFluid(tankName)
        if fl then
            if not fluids[fl.name] then
                fluids[fl.name] = { amount = 0, tanks = {} }
            end
            fluids[fl.name].amount = fluids[fl.name].amount + fl.amount
            table.insert(fluids[fl.name].tanks, tankName)
        end
    end
    return fluids
end

--- Найти пустой танк в хранилище.
function M.findFreeTank(storageTanks)
    for _, tankName in ipairs(storageTanks) do
        local fl = M.getTankFluid(tankName)
        if not fl then return tankName end
    end
    return nil
end

--- Перекачать `amount` mB жидкости `fluidName` из хранилища в машину/цель.
--- @return moved number
function M.extractFluidFromStorage(storageTanks, fluidName, amount, targetName)
    local fluidMap = M.scanFluids(storageTanks)
    local entry    = fluidMap[fluidName]
    if not entry then return 0 end

    local moved     = 0
    local remaining = amount
    for _, srcName in ipairs(entry.tanks) do
        if remaining <= 0 then break end
        local src = peripheral.wrap(srcName)
        if src then
            local ok, m = pcall(src.pushFluid, targetName, remaining, fluidName)
            if ok and m and m > 0 then
                moved     = moved + m
                remaining = remaining - m
            end
        end
    end
    return moved
end

--- Слить все жидкости из машины `machineName` в excludedTanks.
--- Возвращает {fluidName → amount} слитого.
function M.drainMachineFluids(machineName, excludedTanks)
    local drained = {}
    for _, exTankName in ipairs(excludedTanks) do
        local t = peripheral.wrap(exTankName)
        if t then
            local ok, moved = pcall(t.pullFluid, machineName)
            if ok and type(moved) == "number" and moved > 0 then
                -- Узнаём что оказалось в танке
                local fl = M.getTankFluid(exTankName)
                if fl then
                    drained[fl.name] = (drained[fl.name] or 0) + moved
                end
            end
        end
    end
    return drained
end

--- Найти целевой танк для жидкости fluidName в хранилище.
--- Сначала ищет танк с этой же жидкостью, иначе — первый свободный.
--- @return string|nil
local function findFluidHome(fluidName, storageTanks)
    local emptyTank = nil
    for _, tankName in ipairs(storageTanks) do
        local t = peripheral.wrap(tankName)
        if t then
            local ok, contents = pcall(t.tanks)
            if ok and contents then
                if next(contents) == nil then
                    emptyTank = emptyTank or tankName
                else
                    for _, f in pairs(contents) do
                        if f.name == fluidName then
                            return tankName
                        end
                    end
                end
            end
        end
    end
    return emptyTank
end

--- Слить жидкости из машины в хранилище (machine → storage tanks).
--- Читает machine.tanks(), для каждой жидкости ищет правильный танк
--- (существующий с той же жидкостью, иначе свободный), тянет с фильтром.
--- @return {fluidName → amount} слитого
function M.drainMachineToStorage(machineName, storageTanks)
    local drained = {}

    local machPerip = peripheral.wrap(machineName)
    if not machPerip then return drained end
    local ok, machFluids = pcall(machPerip.tanks)
    if not ok or not machFluids then return drained end

    for _, fl in pairs(machFluids) do
        if fl and fl.name and fl.amount and fl.amount > 0 then
            local targetName = findFluidHome(fl.name, storageTanks)
            if targetName then
                local t = peripheral.wrap(targetName)
                if t then
                    local ok2, moved = pcall(t.pullFluid, machineName, 16000000, fl.name)
                    if ok2 and type(moved) == "number" and moved > 0 then
                        drained[fl.name] = (drained[fl.name] or 0) + moved
                    end
                end
            end
        end
    end

    return drained
end

--- Перекачать всю жидкость из sourceTankName в хранилище.
--- Ищет танк с той же жидкостью; если нет — свободный танк.
--- @return moved number, msg string
function M.pumpToStorage(sourceTankName, storageTanks)
    local srcFluid = M.getTankFluid(sourceTankName)
    if not srcFluid then
        return 0, "empty"
    end

    local fluidMap = M.scanFluids(storageTanks)
    local targetName
    if fluidMap[srcFluid.name] then
        targetName = fluidMap[srcFluid.name].tanks[1]
    else
        targetName = M.findFreeTank(storageTanks)
    end

    if not targetName then
        return 0, "No free storage tank"
    end

    local target = peripheral.wrap(targetName)
    if not target then return 0, "Target not found" end

    local ok, moved = pcall(target.pullFluid, sourceTankName)
    if ok and moved and moved > 0 then
        return moved, "OK"
    end
    return 0, "Transfer failed"
end

return M
