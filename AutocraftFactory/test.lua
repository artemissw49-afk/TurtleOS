local machine = peripheral.wrap("gtceu:hv_chemical_reactor_1")
local tank38   = peripheral.wrap("gtceu:lv_super_tank_38")
local tank35   = peripheral.wrap("gtceu:lv_super_tank_35")
local machineName = peripheral.getName(machine)

tank35.pullFluid(machineName)
sleep(0.5)
tank38.pullFluid(machineName)