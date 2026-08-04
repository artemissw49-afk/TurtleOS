local CHANNEL = 1234

local modem = peripheral.find("modem")

if not modem then
    print("Wireless modem not found!")
    return
end

modem.open(CHANNEL)

local id = os.getComputerID()

local distance = 0
local stopRequested = false

local state = "Idle"

local queue = {}

local function sendStatus()

    modem.transmit(CHANNEL, CHANNEL, {
        type = "status",
        id = id,
        status = state,
        fuel = turtle.getFuelLevel(),
        progress = distance
    })

end

print("Worker #" .. id)
print("Waiting...")

modem.transmit(CHANNEL, CHANNEL, {
    type = "register",
    id = id
})

----------------------------------------------------
-- MODEM THREAD
----------------------------------------------------

local function modemThread()

    while true do

        local _,_,channel,_,message =
            os.pullEvent("modem_message")

        if channel == CHANNEL and type(message) == "table" then

            if message.target == nil or message.target == id then

                if message.command == "ping" then

                    modem.transmit(CHANNEL, CHANNEL,{
                        type="pong",
                        id=id
                    })

                elseif message.command == "run" then

                    table.insert(queue,{
                        command="run",
                        blocks=message.blocks
                    })

                elseif message.command == "back" then

                    table.insert(queue,{
                        command="back"
                    })

                elseif message.command == "fuel" then

                    table.insert(queue,{
                        command="fuel"
                    })

                elseif message.command == "stop" then

                    stopRequested = true

                end

            end

        end

    end

end

----------------------------------------------------
-- WORK THREAD
----------------------------------------------------

local function workerThread()

    while true do

        if #queue == 0 then
            sleep(0.05)
        else

            local job = table.remove(queue,1)

            ------------------------------------------------
            -- RUN
            ------------------------------------------------

            if job.command == "run" then

                stopRequested = false

                state = "Mining"
                sendStatus()

                local blocks = job.blocks

                print("Run "..blocks)

                for i=1,blocks do

                    if stopRequested then
                        print("Stopped")
                        state="Stopped"
                        sendStatus()
                        break
                    end

                    while turtle.detect() do
                        turtle.dig()
                        sleep(0.2)
                    end

                    while not turtle.forward() do

                        if stopRequested then
                            break
                        end

                        turtle.attack()
                        turtle.dig()
                        sleep(0.2)

                    end

                    if stopRequested then
                        break
                    end

                    distance = distance + 1
                    sendStatus()

                end
                                state = "Idle"
                sendStatus()

                print("Done")

            ------------------------------------------------
            -- BACK
            ------------------------------------------------

            elseif job.command == "back" then

                stopRequested = false

                state = "Returning"
                sendStatus()

                print("Returning...")

                turtle.turnLeft()
                turtle.turnLeft()

                for i = 1, distance do

                    if stopRequested then
                        print("Stopped")
                        state = "Stopped"
                        sendStatus()
                        break
                    end

                    while not turtle.forward() do

                        if stopRequested then
                            break
                        end

                        turtle.attack()
                        turtle.dig()
                        sleep(0.2)

                    end

                    if stopRequested then
                        break
                    end

                    distance = distance - 1
                    sendStatus()

                end

                turtle.turnLeft()
                turtle.turnLeft()

                if not stopRequested then
                    distance = 0
                    print("Home!")
                end

                state = "Idle"
                sendStatus()

            ------------------------------------------------
            -- FUEL
            ------------------------------------------------

            elseif job.command == "fuel" then

                turtle.select(1)

                while turtle.getItemCount(1) > 0 do

                    if not turtle.refuel(1) then
                        break
                    end

                end

                print("Fuel: "..turtle.getFuelLevel())

                sendStatus()

            end

        end

    end

end

----------------------------------------------------
-- START
----------------------------------------------------

parallel.waitForAll(
    modemThread,
    workerThread
)