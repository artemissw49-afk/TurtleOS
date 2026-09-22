-- simplified turtle_agent.lua using rednet only
-- listens endlessly for craft messages and executes them
term.clear()
term.setCursorPos(1,1)
local modem = peripheral.find("modem")
if not modem then
    printError("Modem not found!")
    return
end
rednet.open("right")

while true do
    local senderID, msg = rednet.receive()
    if senderID then
        if msg == "craft" then
            local ok, res = turtle.craft()
            if ok then
                -- craft complete, notify master
                rednet.send(senderID, "craft_done")
            else
                rednet.send(senderID, "error:"..tostring(res))
            end
        else
            -- reply to any other message for testing
            rednet.send(senderID, "echo:"..tostring(msg))
        end
    end
end
