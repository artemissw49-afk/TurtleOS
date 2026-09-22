-- ============================================================
-- lib/craft.lua  —  Система рецептов и автокрафта
-- Загрузка/сохранение рецептов, построение дерева зависимостей,
-- выполнение крафта на черепашке и в машинах.
-- ============================================================

local M = {}

-- ── Рецепты ──────────────────────────────────────────────────

--- Загрузить рецепты из JSON-файла.
--- @return table  {itemID → recipe}
function M.loadRecipes(file)
    if not fs.exists(file) then return {} end
    local f = fs.open(file, "r")
    local raw = f.readAll(); f.close()
    local ok, data = pcall(textutils.unserialiseJSON, raw)
    return (ok and type(data) == "table") and data or {}
end

--- Сохранить рецепты в JSON-файл.
function M.saveRecipes(recipes, file)
    -- Убедимся что директория существует
    local dir = fs.getDir(file)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(file, "w")
    f.write(textutils.serialiseJSON(recipes))
    f.close()
end

--- Создать объект рецепта из содержимого бочки.
--- Конвенция:
---   Слот 1 = результат (output)
---   Слоты 4,5,6,13,14,15,22,23,24 = ингредиенты (для turtle — позиций 3x3, как в верстаке)
---   Слоты 2+   = ингредиенты (для machine — только id+count)
--- @param contents  table  Результат inv.getBarrelContents()
--- @param craftType string "turtle"|"machine"
--- @param machineName string|nil  Имя машины (для type="machine")
--- @return recipe|nil, string|nil
function M.buildRecipeFromBarrel(contents, craftType, machineName)
    if not contents then return nil, "Barrel contents not provided" end

    local outputItem = contents[1]
    if not outputItem then
        return nil, "Place the craft result in barrel slot 1"
    end

    local recipe = {
        output      = { id = outputItem.name, count = outputItem.count },
        type        = craftType or "turtle",
        machine     = (craftType == "machine" and machineName ~= "") and machineName or nil,
        ingredients = {},
    }

    if craftType == "turtle" then
        -- Слоты 4,5,6,13,14,15,22,23,24 в бочке → соответствующие слоты черепашки
        -- черепашка использует номинальную 3х3 сетку: 1,2,3,5,6,7,9,10,11
        local barrelSlots = {4,5,6,13,14,15,22,23,24}
        local turtleSlots = {1,2,3,5,6,7,9,10,11}
        for i, barrelSlot in ipairs(barrelSlots) do
            local item = contents[barrelSlot]
            if item then
                table.insert(recipe.ingredients, {
                    id    = item.name,
                    count = item.count,
                    slot  = turtleSlots[i],   -- реальный слот черепашки
                })
            end
        end
        if #recipe.ingredients == 0 then
            return nil, "No ingredients in barrel grid slots"
        end
    else
        -- machine: суммируем одинаковые предметы
        local seen = {}
        for slot = 2, 64 do
            local item = contents[slot]
            if not item then break end
            if seen[item.name] then
                seen[item.name].count = seen[item.name].count + item.count
            else
                seen[item.name] = { id = item.name, count = item.count }
                table.insert(recipe.ingredients, seen[item.name])
            end
        end
        if #recipe.ingredients == 0 then
            return nil, "No ingredients in slots 2+"
        end
        if not recipe.machine then
            return nil, "Specify machine name for type=machine"
        end
    end

    return recipe
end

-- ── Дерево крафта ─────────────────────────────────────────────

--- Рекурсивно построить очередь крафта для (itemID, amount).
---
--- Алгоритм:
---   1. Если на складе хватает — использовать из стока.
---   2. Иначе — найти рецепт и рекурсивно разрешить ингредиенты.
---   3. Если рецепта нет — добавить в missing.
---
--- @param itemID  string
--- @param amount  number  Требуемое количество
--- @param stock   table   {itemID→count}  — изменяется по мере расчёта
--- @param recipes table   {itemID→recipe}
--- @param queue   table   Выходная очередь (пополняется в процессе)
--- @param missing table   {itemID→count}  — чего не хватает
--- @param depth   number  Защита от зацикливания
local function resolveItem(itemID, amount, stock, recipes, queue, missing, depth, topLevel)
    if depth > 64 then
        missing[itemID] = (missing[itemID] or 0) + amount
        return
    end

    -- Для верхнего уровня всегда крафтим запрошенное количество,
    -- для под-ингредиентов используем то, что уже есть на складе.
    local stillNeeded = amount
    if not topLevel then
        local available = stock[itemID] or 0
        if available >= amount then
            stock[itemID] = available - amount
            return
        end
        stillNeeded = amount - available
        stock[itemID] = 0
    end

    local recipe = recipes[itemID]
    if not recipe then
        missing[itemID] = (missing[itemID] or 0) + stillNeeded
        return
    end

    local outPerOp = recipe.output.count
    local ops      = math.ceil(stillNeeded / outPerOp)
    local surplus  = ops * outPerOp - stillNeeded

    -- Избыток добавляем обратно в виртуальный сток
    if surplus > 0 then
        stock[itemID] = (stock[itemID] or 0) + surplus
    end

    -- Сначала разрешаем ингредиенты (зависимости идут раньше)
    for _, ing in ipairs(recipe.ingredients) do
        resolveItem(ing.id, ing.count * ops, stock, recipes, queue, missing, depth + 1)
    end

    -- Добавляем операцию в конец очереди (ингредиенты уже в начале)
    table.insert(queue, {
        itemID      = itemID,
        ops         = ops,
        totalOutput = ops * outPerOp,
        recipe      = recipe,
        status      = "pending",
    })
end

--- Построить очередь крафта.
--- @return queue table, missing table
function M.buildCraftTree(itemID, amount, stock, recipes)
    -- Копируем сток чтобы не испортить оригинал
    local stockCopy = {}
    for k, v in pairs(stock) do stockCopy[k] = v end

    local queue   = {}
    local missing = {}
    resolveItem(itemID, amount, stockCopy, recipes, queue, missing, 0, true)
    return queue, missing
end

-- ── Выполнение крафта ─────────────────────────────────────────

--- Крафт на черепашке.
--- Требует: turtle_agent.lua запущен на черепашке.
--- @param job     table   Элемент очереди из buildCraftTree
--- @param vaults  table   Список vault-имён
--- @param cfg     table   Конфигурация
--- @param inv     table   Модуль inventory
--- @param statusCb function(msg, isErr)
function M.craftOnTurtle(job, vaults, cfg, inv, statusCb)
    statusCb = statusCb or function() end
    local recipe = job.recipe

    -- Находим модем и открываем rednet
    local modem = peripheral.find("modem")
    if not modem then
        return false, "Modem not found. Connect a wired modem."
    end
    rednet.open(peripheral.getName(modem))

    -- Максимальный батч: сколько операций за один turtle.craft()
    -- Ограничен размером стака (64) как по ингредиентам, так и по результату.
    local maxBatch = math.floor(64 / math.max(1, recipe.output.count))
    for _, ing in ipairs(recipe.ingredients) do
        maxBatch = math.min(maxBatch, math.floor(64 / math.max(1, ing.count)))
    end
    maxBatch = math.max(1, maxBatch)

    local opsLeft  = job.ops
    local totalOps = math.ceil(job.ops / maxBatch)
    local opsDone  = 0

    while opsLeft > 0 do
        local batch = math.min(opsLeft, maxBatch)
        opsDone = opsDone + 1
        statusCb(string.format("Turtle %d/%d (%dx%d)  %s",
            opsDone, totalOps, batch, recipe.output.count, job.itemID), false)

        -- 1. Очищаем черепашку перед крафтом
        inv.clearInventory(vaults, cfg.turtle)

        -- 2. Раскладываем batch*count ингредиентов; при неудаче откатываемся к batch=1
        local ready = false
        while not ready do
            local failed = false
            for _, ing in ipairs(recipe.ingredients) do
                local need      = ing.count * batch
                local extracted = inv.extractItem(vaults, ing.id, need, cfg.turtle, ing.slot)
                if extracted < need then
                    inv.clearInventory(vaults, cfg.turtle)
                    if batch > 1 then
                        batch   = 1
                        failed  = true
                        break
                    else
                        return false, string.format(
                            "Not enough %s: need %d, have %d", ing.id, ing.count, extracted)
                    end
                end
            end
            if not failed then ready = true end
        end

        sleep(0)

        -- 3. Отправляем команду "craft"
        if cfg.turtle_rednet_id and cfg.turtle_rednet_id > 0 then
            rednet.send(cfg.turtle_rednet_id, "craft")
        else
            rednet.broadcast("craft")
        end

        -- 4. Ждём подтверждения (senderID, message)
        local senderID, msg = rednet.receive(nil, cfg.turtle_timeout)
        if senderID ~= nil and cfg.turtle_rednet_id and cfg.turtle_rednet_id > 0
                and senderID ~= cfg.turtle_rednet_id then
            senderID, msg = rednet.receive(nil, cfg.turtle_timeout)
        end
        if msg == nil then
            inv.clearInventory(vaults, cfg.turtle)
            return false, string.format(
                "Turtle did not respond (timeout %d sec)", cfg.turtle_timeout)
        end
        if type(msg) == "string" and msg:sub(1,6) == "error:" then
            inv.clearInventory(vaults, cfg.turtle)
            return false, "Turtle craft error: " .. msg:sub(7)
        elseif msg ~= "craft_done" then
            inv.clearInventory(vaults, cfg.turtle)
            return false, "Unexpected turtle reply: " .. tostring(msg)
        end

        sleep(0)

        -- 5. Забираем результат обратно в vault'ы
        local ok, err = inv.storeAll(vaults, cfg.turtle)
        if not ok then
            return false, err
        end

        opsLeft = opsLeft - batch
    end

    return true
end

--- Найти все машины по имени или типу.
--- Если machSpec — конкретное имя периферала, вернуть только его.
--- Если это тип (например "gtceu:lv_electric_furnace") — вернуть все машины этого типа.
local function findAllMachines(machSpec)
    local m = peripheral.wrap(machSpec)
    if m then return { peripheral.getName(m) } end
    local result = {}
    for _, pname in ipairs(peripheral.getNames()) do
        if peripheral.getType(pname) == machSpec then
            table.insert(result, pname)
        end
    end
    table.sort(result)
    return result
end

--- Крафт на машине (GT, Create и т.д.).
--- Если доступно несколько машин одного типа — автоматически распараллеливает.
--- Поддерживает fluid_ingredients и output_type="fluid".
--- @param job      table
--- @param vaults   table
--- @param cfg      table
--- @param inv      table
--- @param statusCb function(msg, isErr)
--- @param fld      table|nil  Модуль fluid
function M.craftOnMachine(job, vaults, cfg, inv, statusCb, fld)
    statusCb = statusCb or function() end
    local recipe   = job.recipe
    local machSpec = recipe.machine

    if not machSpec or machSpec == "" then
        return false, "No machine specified for recipe: " .. job.itemID
    end

    local machines = findAllMachines(machSpec)
    if #machines == 0 then
        return false, "Machine not found: " .. machSpec
    end

    local isFluidOutput = recipe.output_type == "fluid"
    local outputID      = recipe.output.id
    local totalOps      = job.ops
    local machCount     = #machines

    -- Распределяем ops по машинам (первые `rem` машин получают на 1 op больше)
    local base = math.floor(totalOps / machCount)
    local rem  = totalOps % machCount
    local opsForMachine = {}
    for i = 1, machCount do
        opsForMachine[i] = base + (i <= rem and 1 or 0)
    end

    -- Мьютекс для vault / fluid-хранилища.
    -- В CC один поток — операции между sleep атомарны, поэтому флаг достаточен.
    local locked = false
    local function acquireLock() while locked do sleep(0) end; locked = true end
    local function releaseLock() locked = false end

    local taskErrors = {}
    local tasks = {}

    for i, machName in ipairs(machines) do
        local myOps = opsForMachine[i]
        if myOps > 0 then
            local ti = #tasks + 1
            tasks[ti] = function()
                local machine = peripheral.wrap(machName)
                if not machine then
                    taskErrors[ti] = "Machine not found: " .. machName
                    return
                end
                local canonName = peripheral.getName(machine)

                for op = 1, myOps do
                    statusCb(string.format("[%s] op %d/%d", machName, op, myOps), false)

                    -- Загружаем предметы-ингредиенты (под замком)
                    acquireLock()
                    for ingIdx, ing in ipairs(recipe.ingredients) do
                        local extracted = inv.extractItem(vaults, ing.id, ing.count, canonName, ingIdx)
                        if extracted < ing.count then
                            inv.storeAll(vaults, canonName)
                            taskErrors[ti] = string.format(
                                "Not enough %s for %s (need %d, have %d)",
                                ing.id, machName, ing.count, extracted)
                            releaseLock()
                            return
                        end
                    end
                    releaseLock()

                    -- Загружаем жидкие ингредиенты (под замком)
                    if fld and recipe.fluid_ingredients then
                        acquireLock()
                        local storageTanks = fld.getStorageTanks(cfg)
                        for _, fi in ipairs(recipe.fluid_ingredients) do
                            local moved = fld.extractFluidFromStorage(storageTanks, fi.id, fi.amount, canonName)
                            if moved < fi.amount then
                                inv.storeAll(vaults, canonName)
                                fld.drainMachineToStorage(canonName, storageTanks)
                                taskErrors[ti] = string.format(
                                    "Not enough fluid %s for %s: need %d mB, have %d mB",
                                    fi.id, machName, fi.amount, moved)
                                releaseLock()
                                return
                            end
                        end
                        releaseLock()
                    end

                    -- Ждём результата
                    local found       = false
                    local elapsed     = 0

                    while elapsed < cfg.craft_timeout do
                        if isFluidOutput and fld then
                            -- Fluid output: пробуем дренировать; успех = рецепт готов
                            acquireLock()
                            local storageTanks = fld.getStorageTanks(cfg)
                            local drained = fld.drainMachineToStorage(canonName, storageTanks)
                            releaseLock()
                            if next(drained) then found = true end
                        else
                            -- Item output: ждём появления выходного предмета
                            local ok2, items = pcall(machine.list)
                            if ok2 and items then
                                for _, item in pairs(items) do
                                    if item.name == outputID then found = true; break end
                                end
                            end
                        end
                        if found then break end

                        sleep(cfg.check_interval)
                        elapsed = elapsed + cfg.check_interval
                        statusCb(string.format("[%s] waiting %ds/%ds",
                            machName, math.floor(elapsed), cfg.craft_timeout), false)
                    end

                    if not found then
                        taskErrors[ti] = string.format(
                            "Timeout: machine %s did not produce %s in %d sec",
                            machName, outputID, cfg.craft_timeout)
                        return
                    end

                    -- Забираем результат в vault'ы (под замком)
                    acquireLock()
                    inv.storeAll(vaults, canonName)
                    releaseLock()
                end
            end
        end
    end

    if #tasks == 0 then return true end

    if #tasks == 1 then
        tasks[1]()
    else
        parallel.waitForAll(table.unpack(tasks))
    end

    for _, err in pairs(taskErrors) do
        return false, err
    end
    return true
end

-- ── Полный автокрафт с конвейерной параллелизацией ───────────

--- Запустить полный цикл автокрафта для (itemID, amount).
---
--- Конвейерная модель: каждый op — отдельная корутина.
--- Как только шаг N выдаёт 1 результат, шаг N+1 может стартовать,
--- не дожидаясь завершения всех ops шага N.
--- Несколько машин одного типа используются параллельно через пул.
---
--- @param itemID    string
--- @param amount    number
--- @param stock     table   Текущий сток (читается, не изменяется)
--- @param vaults    table
--- @param recipes   table
--- @param cfg       table
--- @param inv       table   Модуль inventory
--- @param statusCb  function(msg, isErr)
--- @param fld       table|nil  Модуль fluid
--- @return ok bool, message string, missing table
function M.runAutocraft(itemID, amount, stock, vaults, recipes, cfg, inv, statusCb, fld, progressCb)
    statusCb    = statusCb    or function() end
    progressCb  = progressCb  or function() end
    statusCb("Analysing craft tree...", false)

    local queue, missing = M.buildCraftTree(itemID, amount, stock, recipes)

    if next(missing) then
        local lines = {}
        for id, cnt in pairs(missing) do
            table.insert(lines, string.format("  * %s  x%d", id, cnt))
        end
        table.sort(lines)
        return false, "Missing resources:\n" .. table.concat(lines, "\n"), missing
    end
    if #queue == 0 then
        return true, "Nothing to craft (no recipe found)", {}
    end

    -- ── Живой сток ───────────────────────────────────────────────
    -- Копия текущего физического стока; уменьшается при резервировании,
    -- увеличивается когда op кладёт результат обратно в vault.
    local liveStock = {}
    for k, v in pairs(stock) do liveStock[k] = v end

    -- ── Глобальный мьютекс ───────────────────────────────────────
    local locked = false
    local function acquireLock() while locked do sleep(0) end; locked = true end
    local function releaseLock() locked = false end

    -- ── Пулы машин: machSpec → {список свободных имён} ──────────
    local machinePools = {}
    for _, job in ipairs(queue) do
        if job.recipe.type == "machine" and job.recipe.machine then
            local s = job.recipe.machine
            if not machinePools[s] then
                machinePools[s] = findAllMachines(s)
            end
        end
    end

    -- ── Пул черепашек ────────────────────────────────────────────
    local turtleFree = true

    local function acquireMachine(machSpec)
        if not machSpec then
            while true do
                acquireLock()
                if turtleFree then turtleFree = false; releaseLock(); return "turtle" end
                releaseLock(); sleep(0)
            end
        end
        while true do
            acquireLock()
            local pool = machinePools[machSpec]
            if pool and #pool > 0 then
                local m = table.remove(pool, 1); releaseLock(); return m
            end
            releaseLock(); sleep(cfg.check_interval)
        end
    end

    local function releaseMachine(machSpec, machName)
        acquireLock()
        if not machSpec then turtleFree = true
        else table.insert(machinePools[machSpec], machName) end
        releaseLock()
    end

    -- Зарезервировать 1 op ингредиентов из liveStock; возвращает false если не хватает.
    local function tryReserve(job)
        acquireLock()
        for _, ing in ipairs(job.recipe.ingredients) do
            if (liveStock[ing.id] or 0) < ing.count then
                releaseLock(); return false
            end
        end
        for _, ing in ipairs(job.recipe.ingredients) do
            liveStock[ing.id] = liveStock[ing.id] - ing.count
        end
        releaseLock(); return true
    end

    -- ── Прогресс ─────────────────────────────────────────────────
    local perItemTotal = {}   -- {[itemID] = кол-во op}
    local perItemDone  = {}   -- {[itemID] = выполнено op}
    for _, job in ipairs(queue) do
        perItemTotal[job.itemID] = (perItemTotal[job.itemID] or 0) + job.ops
        perItemDone[job.itemID]  = 0
    end
    local totalOps     = 0    -- заполняется после построения allTasks
    local completedOps = 0

    -- ── Формируем плоский список op-корутин ──────────────────────
    local taskErrors = {}
    local allTasks   = {}

    for _, job in ipairs(queue) do
        for op = 1, job.ops do
            local ti      = #allTasks + 1
            local thisJob = job
            local thisOp  = op

            allTasks[ti] = function()
                local recipe = thisJob.recipe

                -- ── Turtle op ────────────────────────────────────
                if recipe.type == "turtle" then
                    while not tryReserve(thisJob) do sleep(0) end
                    local machName = acquireMachine(nil)
                    local singleJob = {
                        itemID = thisJob.itemID, ops = 1,
                        totalOutput = recipe.output.count, recipe = recipe,
                    }
                    local ok, err = M.craftOnTurtle(singleJob, vaults, cfg, inv, statusCb)
                    releaseMachine(nil, machName)
                    if not ok then taskErrors[ti] = err; return end
                    acquireLock()
                    liveStock[thisJob.itemID] = (liveStock[thisJob.itemID] or 0) + recipe.output.count
                    completedOps = completedOps + 1
                    perItemDone[thisJob.itemID] = (perItemDone[thisJob.itemID] or 0) + 1
                    progressCb(completedOps, totalOps, thisJob.itemID, perItemDone, perItemTotal)
                    releaseLock()

                -- ── Machine op ───────────────────────────────────
                elseif recipe.type == "machine" then
                    local machSpec = recipe.machine
                    local isFluid  = recipe.output_type == "fluid"
                    local outputID = recipe.output.id

                    -- Ждём ингредиенты
                    while not tryReserve(thisJob) do sleep(cfg.check_interval) end

                    -- Берём машину из пула
                    local machName = acquireMachine(machSpec)
                    local machine  = peripheral.wrap(machName)
                    if not machine then
                        taskErrors[ti] = "Machine not found: " .. machName
                        releaseMachine(machSpec, machName); return
                    end
                    local canonName = peripheral.getName(machine)
                    statusCb(string.format("[%s] op %d/%d on %s",
                        thisJob.itemID, thisOp, thisJob.ops, machName), false)

                    -- Загружаем предметы (под замком)
                    acquireLock()
                    for ingIdx, ing in ipairs(recipe.ingredients) do
                        local extracted = inv.extractItem(vaults, ing.id, ing.count, canonName, ingIdx)
                        if extracted < ing.count then
                            inv.storeAll(vaults, canonName)
                            taskErrors[ti] = string.format(
                                "Not enough %s for %s (need %d)", ing.id, machName, ing.count)
                            releaseLock(); releaseMachine(machSpec, machName); return
                        end
                    end
                    releaseLock()

                    -- Загружаем жидкости (под замком)
                    if fld and recipe.fluid_ingredients then
                        acquireLock()
                        local sTanks = fld.getStorageTanks(cfg)
                        for _, fi in ipairs(recipe.fluid_ingredients) do
                            local moved = fld.extractFluidFromStorage(sTanks, fi.id, fi.amount, canonName)
                            if moved < fi.amount then
                                inv.storeAll(vaults, canonName)
                                fld.drainMachineToStorage(canonName, sTanks)
                                taskErrors[ti] = string.format(
                                    "Not enough fluid %s for %s", fi.id, machName)
                                releaseLock(); releaseMachine(machSpec, machName); return
                            end
                        end
                        releaseLock()
                    end

                    -- Ждём результата (без замка — только sleep и чтение машины)
                    local found, elapsed = false, 0
                    while elapsed < cfg.craft_timeout do
                        if isFluid and fld then
                            acquireLock()
                            local sTanks = fld.getStorageTanks(cfg)
                            local drained = fld.drainMachineToStorage(canonName, sTanks)
                            releaseLock()
                            if next(drained) then found = true end
                        else
                            local ok2, items = pcall(machine.list)
                            if ok2 and items then
                                for _, it in pairs(items) do
                                    if it.name == outputID then found = true; break end
                                end
                            end
                        end
                        if found then break end
                        sleep(cfg.check_interval)
                        elapsed = elapsed + cfg.check_interval
                        statusCb(string.format("[%s] waiting %ds on %s",
                            thisJob.itemID, math.floor(elapsed), machName), false)
                    end

                    if not found then
                        taskErrors[ti] = string.format(
                            "Timeout: %s on %s in %ds", outputID, machName, cfg.craft_timeout)
                        releaseMachine(machSpec, machName); return
                    end

                    -- Забираем результат (под замком)
                    acquireLock()
                    inv.storeAll(vaults, canonName)
                    releaseLock()
                    releaseMachine(machSpec, machName)

                    -- Добавляем выход в liveStock → разблокирует следующие этапы
                    acquireLock()
                    liveStock[thisJob.itemID] = (liveStock[thisJob.itemID] or 0) + recipe.output.count
                    completedOps = completedOps + 1
                    perItemDone[thisJob.itemID] = (perItemDone[thisJob.itemID] or 0) + 1
                    progressCb(completedOps, totalOps, thisJob.itemID, perItemDone, perItemTotal)
                    releaseLock()
                end
            end
        end
    end

    totalOps = #allTasks
    progressCb(0, totalOps, nil, perItemDone, perItemTotal)

    if #allTasks == 0 then return true, "Nothing to craft", {} end
    if #allTasks == 1 then
        allTasks[1]()
    else
        parallel.waitForAll(table.unpack(allTasks))
    end

    for _, err in pairs(taskErrors) do
        return false, err, {}
    end
    return true, string.format("Craft complete: %s x%d", itemID, amount), {}
end



--- Тестовый крафт для записи рецепта.
--- Перекладывает ингредиенты из бочки (слоты 4,5,6,13,14,15,22,23,24) в черепашку,
--- крафтит, возвращает результат в слот 14 бочки.
--- @param cfg      table
--- @param inv      table  Модуль inventory
--- @param statusCb function(msg, isErr)
--- @return recipe|nil, string|nil
function M.craftTestRecipe(cfg, inv, statusCb)
    statusCb = statusCb or function() end

    local contents, berr = inv.getBarrelContents(cfg.barrel)
    if not contents then return nil, "Barrel error: " .. (berr or "?") end

    local barrelSlots = {4,5,6,13,14,15,22,23,24}
    local turtleSlots = {1,2,3,5,6,7,9,10,11}

    local hasIng = false
    for _, bs in ipairs(barrelSlots) do
        if contents[bs] then hasIng = true; break end
    end
    if not hasIng then return nil, "No ingredients in barrel grid slots" end

    local modem = peripheral.find("modem")
    if not modem then return nil, "Modem not found" end
    rednet.open(peripheral.getName(modem))

    local barrel = peripheral.wrap(cfg.barrel)
    if not barrel then return nil, "Barrel not found: " .. cfg.barrel end

    -- Очищаем черепашку (pullItems из каждого слота в бочку)
    statusCb("Clearing turtle...", false)
    for slot = 1, 16 do
        pcall(barrel.pullItems, cfg.turtle, slot, 64)
    end

    -- Перекладываем ингредиенты из бочки в черепашку
    statusCb("Moving ingredients...", false)
    local ingredients = {}
    for i, bs in ipairs(barrelSlots) do
        local item = contents[bs]
        if item then
            local ok, moved = pcall(barrel.pushItems, cfg.turtle, bs, item.count, turtleSlots[i])
            if ok and moved and moved > 0 then
                table.insert(ingredients, { id = item.name, count = moved, slot = turtleSlots[i] })
            end
        end
    end

    if #ingredients == 0 then return nil, "Failed to move ingredients to turtle" end

    sleep(0)

    -- Отправляем команду крафта черепашке
    statusCb("Crafting...", false)
    if cfg.turtle_rednet_id and cfg.turtle_rednet_id > 0 then
        rednet.send(cfg.turtle_rednet_id, "craft")
    else
        rednet.broadcast("craft")
    end

    -- Ждём ответа от черепашки.
    -- rednet.receive возвращает (senderID, message, protocol).
    -- Если пришёл error: — прерываем. Если timeout или craft_done — в любом случае
    -- пытаемся забрать результат (на случай если craft_done потерялся).
    local _, msg = rednet.receive(nil, cfg.turtle_timeout)

    -- Вспомогательная функция: вернуть всё из черепашки в бочку (при ошибке)
    local function returnToBarrel()
        for slot = 1, 16 do
            pcall(barrel.pullItems, cfg.turtle, slot, 64)
        end
    end

    if type(msg) == "string" and msg:sub(1,6) == "error:" then
        returnToBarrel()
        return nil, "Craft error: " .. msg:sub(7)
    end

    -- msg == "craft_done"  ИЛИ  msg == nil (timeout) —
    -- в обоих случаях проверяем наличие результата в черепашке
    sleep(0.1)

    -- Вытягиваем результат из черепашки в слот 14 бочки
    statusCb("Storing result...", false)
    local resultMoved = 0
    for slot = 1, 16 do
        local ok4, moved4 = pcall(barrel.pullItems, cfg.turtle, slot, 64, 14)
        if ok4 and moved4 and moved4 > 0 then
            resultMoved = resultMoved + moved4
            break  -- один стак — результат крафта
        end
    end
    -- Очищаем остаток (ингредиенты, если крафт не получился)
    for slot = 1, 16 do
        pcall(barrel.pullItems, cfg.turtle, slot, 64)
    end

    if resultMoved == 0 then
        if msg == nil then
            return nil, "Turtle timeout and no result in turtle"
        end
        return nil, "No result pulled from turtle"
    end

    -- Читаем что оказалось в слоте 14 бочки
    local ok5, bc = pcall(barrel.list)
    local resultItem = ok5 and bc and bc[14]
    if not resultItem then return nil, "Cannot read result from barrel slot 14" end

    local recipe = {
        output      = { id = resultItem.name, count = resultItem.count },
        type        = "turtle",
        machine     = nil,
        ingredients = ingredients,
    }
    statusCb("Done: " .. resultItem.name .. " x" .. resultItem.count, false)
    return recipe
end

--- Тестовый крафт в машине для записи рецепта.
--- Поддерживает жидкие ингредиенты (из excluded_super_tanks) и жидкие результаты.
---
--- Если в excluded-танках есть жидкости, пользователю задаётся вопрос
--- в терминале компьютера: сколько mB каждой жидкости нужно для крафта.
---
--- После завершения крафта:
---   • Предмет-результат → слот 14 бочки.
---   • Жидкий результат → excluded-танки.
--- Пользователь убирает лишнее и нажимает "Yes, save".
---
--- @param machineName string
--- @param cfg         table
--- @param inv         table   Модуль inventory
--- @param fld         table|nil  Модуль fluid (nil = без жидкостей)
--- @param statusCb    function(msg, isErr)
--- @param isCancelled function() → bool
--- @return recipe|nil, string|nil
function M.craftTestMachine(machineName, cfg, inv, fld, statusCb, isCancelled)
    statusCb    = statusCb    or function() end
    isCancelled = isCancelled or function() return false end

    -- machSpec сохраняем как исходное имя (тип или конкретная машина) для рецепта.
    -- Для типа ("gtceu:iv_electric_furnace") находим любую доступную машину этого типа.
    local machSpec = machineName
    local machine  = peripheral.wrap(machineName)
    if not machine then
        for _, pname in ipairs(peripheral.getNames()) do
            if peripheral.getType(pname) == machineName then
                machine     = peripheral.wrap(pname)
                machineName = pname
                break
            end
        end
    end
    if not machine then return nil, "Machine not found: " .. machineName end
    machineName = peripheral.getName(machine)

    local barrel = peripheral.wrap(cfg.barrel)
    if not barrel then return nil, "Barrel not found: " .. cfg.barrel end

    -- Читаем бочку
    local okB, barrelItems = pcall(barrel.list)
    if not okB or not barrelItems then return nil, "Cannot read barrel" end

    local hasBarrelItems = false
    for _, item in pairs(barrelItems) do
        if item.count > 0 then hasBarrelItems = true; break end
    end

    -- Проверяем excluded-танки на наличие жидкостей
    local fluidInputs = {}   -- { {tank, id, available} }
    if fld then
        for _, tankName in ipairs(cfg.excluded_super_tanks or {}) do
            local fl = fld.getTankFluid(tankName)
            if fl then
                table.insert(fluidInputs, { tank = tankName, id = fl.name, available = fl.amount })
            end
        end
    end

    if not hasBarrelItems and #fluidInputs == 0 then
        return nil, "Barrel is empty and no fluids in source tanks"
    end

    -- Спрашиваем пользователя о количестве жидкостей (через терминал)
    local fluidUse = {}   -- { {id, amount, tank} }
    if #fluidInputs > 0 then
        statusCb("CHECK TERMINAL: enter fluid amounts", false)
        print("")
        print("=== Fluid recipe setup: " .. machineName .. " ===")
        for _, fi in ipairs(fluidInputs) do
            local bare = fi.id:match(":(.+)$") or fi.id
            print(string.format("  Fluid: %s  (available: %d mB)", bare, fi.available))
            io.write("  How many mB to use? [0 = skip]: ")
            local input = read()
            local amt = tonumber(input) or 0
            if amt > 0 then
                amt = math.min(amt, fi.available)
                table.insert(fluidUse, { id = fi.id, amount = amt, tank = fi.tank })
            end
        end
        print("=== Starting machine test craft ===")
        print("")
        statusCb("Starting machine test craft...", false)
    end

    -- Снапшот машины ДО загрузки
    local machBefore = {}
    local okM, mB = pcall(machine.list)
    if okM and mB then
        for slot, item in pairs(mB) do
            machBefore[slot] = { name = item.name, count = item.count }
        end
    end

    -- Перемещаем предметы из бочки в машину
    statusCb("Moving items to machine...", false)
    local ingSet = {}
    for slot, item in pairs(barrelItems) do
        if item.count > 0 then
            local okP, moved = pcall(barrel.pushItems, machineName, slot, item.count)
            if okP and moved and moved > 0 then
                ingSet[item.name] = (ingSet[item.name] or 0) + moved
            end
        end
    end

    -- Перемещаем жидкости в машину
    local fluidIngredients = {}
    if fld and #fluidUse > 0 then
        statusCb("Moving fluids to machine...", false)
        local storageTanks = fld.getStorageTanks(cfg)
        for _, fu in ipairs(fluidUse) do
            local src = peripheral.wrap(fu.tank)
            if src then
                local ok2, moved = pcall(src.pushFluid, machineName, fu.amount, fu.id)
                local actualMoved = (ok2 and moved and moved > 0) and moved or 0
                if actualMoved > 0 then
                    table.insert(fluidIngredients, { id = fu.id, amount = actualMoved })
                end
                -- Отправляем остаток в хранилище
                local remaining = fld.getTankFluid(fu.tank)
                if remaining and remaining.amount > 0 then
                    fld.pumpToStorage(fu.tank, storageTanks)
                end
            end
        end
    end

    if next(ingSet) == nil and #fluidIngredients == 0 then
        return nil, "Failed to move any ingredients to machine"
    end

    local ingredients = {}
    for id, count in pairs(ingSet) do
        table.insert(ingredients, { id = id, count = count })
    end

    -- Снапшот машины ПОСЛЕ загрузки (для определения результата)
    local machAfterPlace = {}
    local okA, mAP = pcall(machine.list)
    if okA and mAP then
        for slot, item in pairs(mAP) do
            machAfterPlace[slot] = { name = item.name, count = item.count }
        end
    end

    -- Слоты, в которые мы загрузили предметы (для определения fluid-output)
    local loadedSlots = {}
    for slot, _ in pairs(machAfterPlace) do
        local bf = machBefore[slot]
        local af = machAfterPlace[slot]
        if not bf or bf.name ~= af.name or bf.count < af.count then
            loadedSlots[slot] = true
        end
    end
    local hasLoadedItems = next(loadedSlots) ~= nil

    -- Множество входных жидкостей (для детекции их потребления машиной)
    local inputFluidSet = {}
    for _, fi in ipairs(fluidIngredients) do
        inputFluidSet[fi.id] = true
    end

    -- Ждём результата
    statusCb("Waiting for machine to process...", false)
    local resultSlot = nil   -- слот предмета-результата (nil = нет предмета)
    local elapsed    = 0
    local done       = false

    local function cancelAndCleanup()
        statusCb("Cancelling...", true)
        for s = 1, 64 do pcall(barrel.pullItems, machineName, s, 64) end
        if fld then
            local storageTanks = fld.getStorageTanks(cfg)
            fld.drainMachineFluids(machineName, cfg.excluded_super_tanks or {})
            for _, exTankName in ipairs(cfg.excluded_super_tanks or {}) do
                fld.pumpToStorage(exTankName, storageTanks)
            end
        end
    end

    while not done and elapsed < cfg.craft_timeout do
        if isCancelled() then
            cancelAndCleanup()
            return nil, "Cancelled by user"
        end

        -- Ждём нового предмета в выходных слотах машины
        local ok2, mN = pcall(machine.list)
        if ok2 then
            mN = mN or {}
            for slot, item in pairs(mN) do
                local ap = machAfterPlace[slot]
                if ap then
                    if item.name ~= ap.name then
                        local bef = machBefore[slot]
                        if not bef or bef.name ~= item.name then
                            resultSlot = slot; done = true; break
                        end
                    elseif item.count > ap.count then
                        resultSlot = slot; done = true; break
                    end
                else
                    resultSlot = slot; done = true; break
                end
            end
        end

        -- Параллельно пробуем слить жидкий результат в excluded-танки.
        -- Если что-то перелилось — рецепт завершён (fluid output).
        -- Не полагаемся на "входные слоты опустели" / "жидкость потреблена":
        -- в GT входные ресурсы потребляются при СТАРТЕ рецепта,
        -- а выход появляется только при ЗАВЕРШЕНИИ.
        if not done and fld then
            local partialDrain = fld.drainMachineFluids(machineName, cfg.excluded_super_tanks or {})
            if next(partialDrain) then done = true end
        end

        if done then break end
        sleep(cfg.check_interval)
        elapsed = elapsed + cfg.check_interval
        statusCb(string.format(
            "Waiting for machine %s... %ds/%ds", machineName,
            math.floor(elapsed), cfg.craft_timeout), false)
    end

    if not done then
        cancelAndCleanup()
        return nil, string.format(
            "Timeout: machine %s did not finish in %d sec", machineName, cfg.craft_timeout)
    end

    -- Забираем предмет-результат в слот 14 бочки
    statusCb("Collecting result...", false)
    if resultSlot then
        pcall(barrel.pullItems, machineName, resultSlot, 64, 14)
    end
    -- Очищаем оставшиеся предметы из машины → в бочку
    for s = 1, 64 do
        if s ~= resultSlot then pcall(barrel.pullItems, machineName, s, 64) end
    end

    -- Жидкие результаты из машины → в excluded-танки
    local fluidDrained = {}
    if fld then
        fluidDrained = fld.drainMachineFluids(machineName, cfg.excluded_super_tanks or {})
    end

    -- Читаем слот 14 бочки
    local okR, bcAfter = pcall(barrel.list)
    local ri14 = okR and bcAfter and bcAfter[14]

    -- Проверяем есть ли жидкость в excluded-танках
    local firstFluid = nil
    for fname, famt in pairs(fluidDrained) do
        firstFluid = { id = fname, count = famt }; break
    end

    if not ri14 and not firstFluid then
        return nil, "No result found: no item in barrel slot 14 and no fluid in excluded tanks"
    end

    -- Строим предварительный рецепт (выход уточняется при сохранении)
    local outItem = ri14 and { id = ri14.name, count = ri14.count }
                         or  { id = firstFluid.id, count = firstFluid.count }
    local outType = ri14 and "item" or "fluid"

    local parts = {}
    if ri14 then table.insert(parts, "item: " .. ri14.name) end
    for fname, famt in pairs(fluidDrained) do
        local bare = fname:match(":(.+)$") or fname
        table.insert(parts, string.format("fluid: %s %d mB", bare, famt))
    end
    statusCb("Done! " .. table.concat(parts, "  |  "), false)

    if ri14 and firstFluid then
        statusCb("Both item and fluid found. Remove unwanted result, then Save.", false)
    end

    return {
        output            = outItem,
        output_type       = outType,
        type              = "machine",
        machine           = machSpec,   -- тип или конкретная машина (как выбрал пользователь)
        ingredients       = ingredients,
        fluid_ingredients = fluidIngredients,
        fluid_outputs     = fluidDrained,
    }
end

--- Отправить на черепашку произвольную тестовую строку и дождаться отклика.
--- Используется для проверки связи, не касаясь крафтовых функций.
--- @param cfg table  конфиг (см. config.lua)
--- @return reply, senderID
function M.testLink(cfg)
    local modem = peripheral.find("modem")
    if not modem then
        return nil, "modem not found"
    end
    rednet.open(peripheral.getName(modem))
    local msg = "test-message"
    if cfg and cfg.turtle_rednet_id and cfg.turtle_rednet_id > 0 then
        rednet.send(cfg.turtle_rednet_id, msg)
    else
        rednet.broadcast(msg)
    end
    local timeout = (cfg and cfg.turtle_timeout) or 5
    local reply, sender = rednet.receive(nil, timeout)
    return reply, sender
end

return M
