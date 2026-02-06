--[[ 
    AI Builder Agent - Handles commands from IPC (via socket_manager)
]]

local function log(msg)
    local f = io.open("/tmp/agent_debug.log", "a")
    if f then 
        f:write(os.date("%H:%M:%S") .. " [LOAD_DEBUG] " .. tostring(msg) .. "\n") 
        f:close() 
    end
    print("[AGENT] " .. tostring(msg))
end

log("Agent module loading...")

local json = require "json"
local socket_manager = require "socket_manager"

-- Access global game/api objects
local api = _G.api
local game = _G.game

if not api then
    log("Global 'api' not found, attempting require...")
    local ok, res = pcall(require, "api")
    if ok then api = res else log("Failed to require 'api': " .. tostring(res)) end
end

local agent = {}
local pollTickCounter = 0
local POLL_EVERY_N_TICKS = 30

-- --- Helpers ---

local function getPlayerId()
    if api and api.engine and api.engine.util then
        return api.engine.util.getPlayer()
    end
    return 0
end

-- --- Handlers ---

local handlers = {}

handlers.query_game_state = function(params)
    if not game or not game.interface then return { error = "Game interface not available" } end
    local date = game.interface.getGameTime().date
    
    local playerId = getPlayerId()
    local money = "0"
    
    if api and api.engine and api.engine.system and api.engine.system.budgetSystem then
        money = tostring(api.engine.system.budgetSystem.getMoney(playerId))
    elseif game.interface then
        local player = game.interface.getEntity(playerId)
        if player and player.balance then
            money = tostring(player.balance)
        end
    end

    local speed = game.interface.getGameSpeed()
    local paused = (speed == 0) and "true" or "false"
    
    return {
        year = tostring(date.year),
        month = tostring(date.month),
        day = tostring(date.day),
        money = money,
        speed = tostring(speed),
        paused = paused
    }
end

handlers.query_towns = function(params)
    if not game or not game.interface then return { error = "Game interface not available" } end
    
    local towns = {}
    local entities = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})
    
    for id, town in pairs(entities) do
        local pop = "0"
        if town.counts and town.counts.population then
            pop = tostring(town.counts.population)
        end
        
        table.insert(towns, {
            id = tostring(id),
            name = town.name,
            population = pop
        })
    end
    
    return { towns = towns }
end

handlers.query_industries = function(params)
    if not api then return { error = "No api" } end
    local industries = {}
    api.engine.forEachEntityWithComponent(function(entity)
        local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(entity)
        if constructionId and constructionId ~= -1 then
            local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
            local nameComp = api.engine.getComponent(constructionId, api.type.ComponentType.NAME)
            
            if construction and construction.fileName and string.find(construction.fileName, "industry/") then
                local transf = construction.transf
                table.insert(industries, {
                    id = tostring(constructionId),
                    name = nameComp and nameComp.name or "Unknown",
                    fileName = construction.fileName,
                    x = tostring(transf:cols(3).x),
                    y = tostring(transf:cols(3).y)
                })
            end
        end
    end, api.type.ComponentType.SIM_BUILDING)
    return { industries = industries }
end

handlers.query_lines = function(params)
    if not api then return { error = "No api" } end
    local lines = {}
    local lineIds = api.engine.system.lineSystem.getLines()
    for _, lineId in pairs(lineIds) do
        local nameComp = api.engine.getComponent(lineId, api.type.ComponentType.NAME)
        table.insert(lines, {
            id = tostring(lineId),
            name = nameComp and nameComp.name or "Unknown"
        })
    end
    return { lines = lines }
end

handlers.query_vehicles = function(params)
    if not api then return { error = "No api" } end
    local vehicles = {}
    api.engine.forEachEntityWithComponent(function(entity)
        local nameComp = api.engine.getComponent(entity, api.type.ComponentType.NAME)
        table.insert(vehicles, {
            id = tostring(entity),
            name = nameComp and nameComp.name or "Unknown"
        })
    end, api.type.ComponentType.TRANSPORT_VEHICLE)
    return { vehicles = vehicles }
end

handlers.query_stations = function(params)
    if not api then return { error = "No api" } end
    local stations = {}
    api.engine.forEachEntityWithComponent(function(entity)
        local nameComp = api.engine.getComponent(entity, api.type.ComponentType.NAME)
        table.insert(stations, {
            id = tostring(entity),
            name = nameComp and nameComp.name or "Unknown"
        })
    end, api.type.ComponentType.STATION)
    return { stations = stations }
end

handlers.create_line = function(params)
    if not api then return { error = "No api" } end
    
    local name = params.name or "New Line"
    local lineType = params.line_type or "ROAD"
    
    local transportMode = api.type.enum.TransportMode.BUS
    if lineType == "RAIL" then transportMode = api.type.enum.TransportMode.TRAIN
    elseif lineType == "TRAM" then transportMode = api.type.enum.TransportMode.TRAM
    elseif lineType == "TRUCK" then transportMode = api.type.enum.TransportMode.TRUCK
    elseif lineType == "WATER" then transportMode = api.type.enum.TransportMode.SHIP
    elseif lineType == "AIR" then transportMode = api.type.enum.TransportMode.AIRCRAFT
    end

    local playerId = getPlayerId()
    local line = api.type.Line.new()
    line.vehicleInfo.transportModes[transportMode + 1] = 1
    
    local color = api.type.Vec3f.new(1.0, 0.0, 0.0)
    local cmd = api.cmd.make.createLine(name, color, playerId, line)
    
    api.cmd.sendCommand(cmd, function(res, success)
        local result = {}
        if success then
            local lineId = res.resultEntity
            result = { line_id = tostring(lineId) }
            log("Created line: " .. tostring(lineId))
        else
            result = { error = "Failed to create line" }
            log("Failed to create line")
        end
        
        socket_manager.send_result({
            timestamp = params.timestamp,
            success = success and "true" or "false",
            data = result
        })
    end)
    
    return "PENDING"
end

handlers.set_pause = function(params)
    if not api then return { error = "No api" } end
    local paused = params.paused == "true"
    local speed = paused and 0 or 1
    
    local cmd = api.cmd.make.setGameSpeed(speed)
    api.cmd.sendCommand(cmd, function(res, success)
        local result = {}
        if success then
            result = { success = "true" }
            log("Set pause: " .. tostring(paused))
        else
            result = { error = "Failed to set pause" }
            log("Failed to set pause")
        end
        
        socket_manager.send_result({
            timestamp = params.timestamp,
            success = success and "true" or "false",
            data = result
        })
    end)
    
    return "PENDING"
end

-- --- Main Handle Function ---

function agent.handle(msg)
    if not msg then return nil end

    local cmd = msg.command or msg.type
    local params = msg.params or msg.data or {}
    local timestamp = msg.timestamp
    params.timestamp = timestamp

    log("Handling command: " .. tostring(cmd))

    local handler = handlers[cmd]
    if handler then
        local success, result = pcall(handler, params)
        if success then
            if result == "PENDING" then
                return nil
            end
            return {
                timestamp = timestamp,
                success = "true",
                data = result
            }
        else
            log("Handler error: " .. tostring(result))
            return {
                timestamp = timestamp,
                success = "false",
                error = tostring(result)
            }
        end
    else
        log("Unknown command: " .. tostring(cmd))
        return {
            timestamp = timestamp,
            success = "false",
            error = "Unknown command: " .. tostring(cmd)
        }
    end
end

function agent.poll()
    pollTickCounter = pollTickCounter + 1
    if pollTickCounter < POLL_EVERY_N_TICKS then return end
    pollTickCounter = 0

    local raw = socket_manager.poll()
    if not raw then return end

    if raw:sub(1, 1) == "{" then
        local success, msg = pcall(json.decode, raw)
        if success and msg then
            local response = agent.handle(msg)
            if response then
                socket_manager.send_result(response)
            end
        else
            log("JSON decode error: " .. tostring(msg))
        end
    else
        log("Executing raw Lua...")
        local func, err = load(raw)
        if func then
            local ok, res = pcall(func)
            socket_manager.send_result({success=ok and "true" or "false", data=tostring(res or err)})
        else
            socket_manager.send_result({success="false", error=tostring(err)})
        end
    end
end

log("LOAD COMPLETED SUCCESSFULLY")
return agent
