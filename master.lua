local CHANNEL = 1234

local modem = peripheral.find("modem")

if not modem then
    print("Wireless modem not found!")
    return
end

modem.open(CHANNEL)

local turtles = {}

print("=== TurtleOS Master v1.0 ===")
print("Waiting for turtles...")

local function sendAll(packet)
    modem.transmit(CHANNEL, CHANNEL, packet)
end

local function sendOne(id, packet)
    packet.target = id
    modem.transmit(CHANNEL, CHANNEL, packet)
end

local function printHelp()
    print("")
    print("Commands:")
    print("help")
    print("list")
    print("run <blocks>")
    print("run <id> <blocks>")
    print("back")
    print("back <id>")
    print("fuel")
    print("fuel <id>")
    print("stop")
    print("stop <id>")
    print("")
end

local function printList()

    print("")
    print("=== Connected Turtles ===")

    local count = 0

    for id, data in pairs(turtles) do
        count = count + 1

        print("ID: "..id)
        print("Status: "..(data.status or "Unknown"))

        if data.progress then
            print("Progress: "..data.progress)
        end

        if data.fuel then
            print("Fuel: "..data.fuel)
        end

        print("----------------")
    end

    if count == 0 then
        print("No turtles connected.")
    end
end

local function modemThread()

    while true do

        local _, _, channel, _, message =
            os.pullEvent("modem_message")

        if channel == CHANNEL then

            if type(message) == "table" then

                if message.type == "register" then

                    turtles[message.id] = {
                        status = "Idle",
                        fuel = 0,
                        progress = "-"
                    }

                    print("Turtle "..message.id.." connected.")

                elseif message.type == "status" then

                    turtles[message.id] = turtles[message.id] or {}

                    turtles[message.id].status = message.status
                    turtles[message.id].fuel = message.fuel
                    turtles[message.id].progress = message.progress

                end

            end

        end

    end

end

local function consoleThread()

    while true do

        write("> ")
        local line = read()

        local args = {}

        for word in string.gmatch(line,"%S+") do
            table.insert(args, word)
        end

        if args[1] == "help" then

            printHelp()

        elseif args[1] == "list" then

            printList()

        elseif args[1] == "run" then

            if #args == 2 then

                sendAll({
                    command = "run",
                    blocks = tonumber(args[2])
                })

            elseif #args == 3 then

                sendOne(
                    tonumber(args[2]),
                    {
                        command = "run",
                        blocks = tonumber(args[3])
                    }
                )

            end

        elseif args[1] == "back" then

            if #args == 1 then

                sendAll({
                    command = "back"
                })

            else

                sendOne(
                    tonumber(args[2]),
                    {
                        command = "back"
                    }
                )

            end

        elseif args[1] == "fuel" then

            if #args == 1 then

                sendAll({
                    command = "fuel"
                })

            else

                sendOne(
                    tonumber(args[2]),
                    {
                        command = "fuel"
                    }
                )

            end

        elseif args[1] == "stop" then

            if #args == 1 then

                sendAll({
                    command = "stop"
                })

            else

                sendOne(
                    tonumber(args[2]),
                    {
                        command = "stop"
                    }
                )

            end

        else

            print("Unknown command. Type help.")

        end

    end

end

parallel.waitForAny(
    modemThread,
    consoleThread
)