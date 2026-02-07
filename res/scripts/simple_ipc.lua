--[[
    Simple File-Based IPC for TF2

    Direct communication with Python agents.
    No sockets, no daemon - just two files.

    Files:
      /tmp/tf2_cmd.json  - Commands FROM Python (we read)
      /tmp/tf2_resp.json - Responses TO Python (we write)

    Protocol:
      1. Poll command file for new commands
      2. If command found, execute it and write response
      3. Clear command file after processing
]]

local M = {}

-- Speed management: default to 4x but allow IPC override
local targetGameSpeed = 4  -- Can be changed by set_speed handler
local function ensureGameSpeed()
    if api and api.cmd then
        pcall(function()
            api.cmd.sendCommand(api.cmd.make.setGameSpeed(targetGameSpeed))
        end)
    end
end

-- File paths
local CMD_FILE = "/tmp/tf2_cmd.json"
local RESP_FILE = "/tmp/tf2_resp.json"
local LOG_FILE = "/tmp/tf2_simple_ipc.log"

-- State
local last_cmd_id = nil
local json = nil

-- Snapshot storage for state diffing
local snapshots = {}

-- Logging
local function log(msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n")
        f:close()
    end
end

-- Get JSON encoder/decoder
local function get_json()
    if json then return json end
    local ok, mod = pcall(require, "json")
    if ok then json = mod end
    return json
end

-- Write response (direct write since os.rename may not be available in sandbox)
local function write_response(resp)
    local j = get_json()
    if not j then
        log("ERROR: No JSON encoder")
        return false
    end

    -- Safely encode to JSON
    local encode_ok, content = pcall(j.encode, resp)
    if not encode_ok then
        log("ERROR: JSON encode failed: " .. tostring(content))
        return false
    end

    -- Write directly to response file
    local f, err = io.open(RESP_FILE, "w")
    if not f then
        log("ERROR: Cannot open " .. RESP_FILE .. ": " .. tostring(err))
        return false
    end

    local write_ok, write_err = pcall(function()
        f:write(content)
        f:close()
    end)
    if not write_ok then
        log("ERROR: Write failed: " .. tostring(write_err))
        pcall(f.close, f)
        return false
    end

    log("RESP: " .. content:sub(1, 100))
    return true
end

-- Clear command file
local function clear_command()
    os.remove(CMD_FILE)
end

-- Command handlers
local handlers = {}

handlers.ping = function(params)
    return {status = "ok", data = "pong"}
end

handlers.query_game_state = function(params)
    local state = {}

    -- Use game.interface methods (more reliable than api.engine in game script context)
    local gameTime = game.interface.getGameTime()
    if gameTime and gameTime.date then
        state.year = tostring(gameTime.date.year or 1850)
        state.month = tostring(gameTime.date.month or 1)
        state.day = tostring(gameTime.date.day or 1)
    else
        state.year = "1850"
        state.month = "1"
        state.day = "1"
    end

    -- Get money via game.interface
    local player = game.interface.getPlayer()
    if player then
        local playerEntity = game.interface.getEntity(player)
        state.money = tostring(playerEntity and playerEntity.balance or 0)
    else
        state.money = "0"
    end

    -- Get game speed
    state.speed = tostring(game.interface.getGameSpeed() or 1)
    state.paused = game.interface.getGameSpeed() == 0 and "true" or "false"

    return {status = "ok", data = state}
end

handlers.query_towns = function(params)
    if not game or not game.interface then
        return {status = "error", message = "Game interface not available"}
    end

    local towns = {}
    local entities = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})

    for id, town in pairs(entities) do
        local pop = "0"
        if town.counts and town.counts.population then
            pop = tostring(town.counts.population)
        end
        table.insert(towns, {
            id = tostring(id),
            name = town.name or "Unknown",
            population = pop
        })
    end

    return {status = "ok", data = {towns = towns}}
end

-- Query buildings in a town with their positions and ACTUAL cargo demands
handlers.query_town_buildings = function(params)
    if not params or not params.town_id then
        return {status = "error", message = "Need town_id parameter"}
    end

    local town_id = tonumber(params.town_id)
    if not town_id then
        return {status = "error", message = "Invalid town_id"}
    end

    local buildings = {}
    local commercial = {}
    local residential = {}

    -- Get ACTUAL cargo demands from the game using getTownCargoSupplyAndLimit
    local cargoDemandsMap = {}  -- cargo -> {supply, limit, demand}
    local cargoDemandsStr = ""
    local ok, cargoSupplyAndLimit = pcall(function()
        return game.interface.getTownCargoSupplyAndLimit(town_id)
    end)

    if ok and cargoSupplyAndLimit then
        for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do
            local supply = supplyAndLimit[1] or 0
            local limit = supplyAndLimit[2] or 0
            local demand = math.max(0, limit - supply)
            if demand > 0 then
                cargoDemandsMap[cargoName] = {
                    supply = supply,
                    limit = limit,
                    demand = demand
                }
                if cargoDemandsStr ~= "" then cargoDemandsStr = cargoDemandsStr .. ", " end
                cargoDemandsStr = cargoDemandsStr .. cargoName
            end
        end
    end

    -- Get town buildings
    local townBuildingMap = api.engine.system.townBuildingSystem.getTown2BuildingMap()
    local townBuildings = townBuildingMap[town_id] or {}

    log("QUERY_TOWN_BUILDINGS: town_id=" .. town_id .. " buildings=" .. #townBuildings .. " cargo_demands=" .. cargoDemandsStr)

    -- Calculate town center and categorize buildings
    local sumX, sumY, count = 0, 0, 0
    local buildingCargoTypes = {}  -- Track cargo types per building

    for i, buildingId in pairs(townBuildings) do
        local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(buildingId)
        local construction = constructionId and constructionId > 0 and game.interface.getEntity(constructionId) or nil
        local buildingEntity = game.interface.getEntity(buildingId)

        -- Try to get cargo types this building consumes
        local buildingCargo = {}
        local ok2, constructionComp = pcall(function()
            return api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
        end)
        if ok2 and constructionComp and constructionComp.params and constructionComp.params.cargoTypes then
            for _, cargoType in ipairs(constructionComp.params.cargoTypes) do
                table.insert(buildingCargo, cargoType)
            end
        end

        if buildingEntity or construction then
            local position = (buildingEntity and buildingEntity.position) or (construction and construction.position) or nil

            if position then
                local x = position[1] or 0
                local y = position[2] or 0
                sumX = sumX + x
                sumY = sumY + y
                count = count + 1

                -- Categorize building by type
                local fileName = construction and construction.fileName or ""
                local buildingInfo = {
                    id = tostring(buildingId),
                    x = tostring(math.floor(x)),
                    y = tostring(math.floor(y)),
                    cargo_types = table.concat(buildingCargo, ",")
                }

                if fileName:find("commercial") or fileName:find("shop") or fileName:find("store") then
                    table.insert(commercial, buildingInfo)
                elseif fileName:find("residential") or fileName:find("house") then
                    table.insert(residential, buildingInfo)
                end
            end
        end
    end

    local town = game.interface.getEntity(town_id)
    local townPos = town and town.position or {0, 0, 0}

    -- Build detailed cargo demand info
    local cargoDetails = {}
    for cargoName, info in pairs(cargoDemandsMap) do
        table.insert(cargoDetails, cargoName .. ":" .. tostring(info.demand) .. "/" .. tostring(info.limit))
    end

    return {status = "ok", data = {
        town_id = tostring(town_id),
        town_name = town and town.name or "Unknown",
        building_count = tostring(#townBuildings),
        town_center_x = tostring(math.floor(townPos[1] or (count > 0 and sumX/count or 0))),
        town_center_y = tostring(math.floor(townPos[2] or (count > 0 and sumY/count or 0))),
        commercial_count = tostring(#commercial),
        residential_count = tostring(#residential),
        cargo_demands = cargoDemandsStr,  -- ACTUAL cargo demands (e.g., "FOOD, GOODS")
        cargo_details = table.concat(cargoDetails, "; ")  -- demand/limit per cargo
    }}
end

-- Query ALL towns with their ACTUAL cargo demands - for Claude to evaluate routing targets
handlers.query_town_demands = function(params)
    local towns = {}
    local allTowns = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})

    for townId, town in pairs(allTowns) do
        -- Get ACTUAL cargo demands using game API
        local cargoDemandsMap = {}
        local cargoDemandsStr = ""
        local ok, cargoSupplyAndLimit = pcall(function()
            return game.interface.getTownCargoSupplyAndLimit(townId)
        end)

        if ok and cargoSupplyAndLimit then
            for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do
                local supply = supplyAndLimit[1] or 0
                local limit = supplyAndLimit[2] or 0
                local demand = math.max(0, limit - supply)
                if demand > 0 then
                    cargoDemandsMap[cargoName] = demand
                    if cargoDemandsStr ~= "" then cargoDemandsStr = cargoDemandsStr .. ", " end
                    cargoDemandsStr = cargoDemandsStr .. cargoName .. ":" .. tostring(demand)
                end
            end
        end

        local townPos = town.position or {0, 0, 0}

        -- Get building counts
        local townBuildingMap = api.engine.system.townBuildingSystem.getTown2BuildingMap()
        local townBuildings = townBuildingMap[townId] or {}

        table.insert(towns, {
            id = tostring(townId),
            name = town.name or "Unknown",
            x = tostring(math.floor(townPos[1] or 0)),
            y = tostring(math.floor(townPos[2] or 0)),
            population = tostring(town.population or 0),
            building_count = tostring(#townBuildings),
            cargo_demands = cargoDemandsStr  -- ACTUAL demands: "FOOD:50, GOODS:30" or empty if none
        })
    end

    log("QUERY_TOWN_DEMANDS: found " .. #towns .. " towns")
    return {status = "ok", data = {towns = towns}}
end

-- Query ALL cargo supply/limit/demand for every town (for metrics tracking)
handlers.query_town_supply = function(params)
    local towns = {}
    local allTowns = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})

    for townId, town in pairs(allTowns) do
        local cargos = {}
        local ok, cargoSupplyAndLimit = pcall(function()
            return game.interface.getTownCargoSupplyAndLimit(townId)
        end)

        if ok and cargoSupplyAndLimit then
            for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do
                local supply = supplyAndLimit[1] or 0
                local limit = supplyAndLimit[2] or 0
                table.insert(cargos, {
                    cargo = cargoName,
                    supply = tostring(supply),
                    limit = tostring(limit),
                    demand = tostring(math.max(0, limit - supply))
                })
            end
        end

        table.insert(towns, {
            id = tostring(townId),
            name = town.name or "Unknown",
            cargos = cargos
        })
    end

    log("QUERY_TOWN_SUPPLY: found " .. #towns .. " towns")
    return {status = "ok", data = {towns = towns}}
end

handlers.query_industries = function(params)
    if not game or not game.interface then
        return {status = "error", message = "Game interface not available"}
    end

    local industries = {}
    -- Get all SIM_BUILDING entities (industries) - this is what AI Builder uses
    local entities = game.interface.getEntities({radius=1e9}, {type="SIM_BUILDING", includeData=true})

    for id, industry in pairs(entities) do
        -- Industries have itemsProduced/itemsConsumed
        if industry.itemsProduced or industry.itemsConsumed then
            -- Get the construction for name/position info
            local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(id)
            local construction = constructionId and constructionId > 0 and game.interface.getEntity(constructionId) or nil

            local name = industry.name or (construction and construction.name) or "Industry"
            local position = industry.position or (construction and construction.position) or {0, 0, 0}
            local fileName = construction and construction.fileName or ""

            table.insert(industries, {
                id = tostring(id),
                name = name,
                type = fileName:match("industry/(.-)%.") or "unknown",
                x = tostring(math.floor(position[1] or 0)),
                y = tostring(math.floor(position[2] or 0))
            })
        end
    end

    return {status = "ok", data = {industries = industries}}
end

handlers.query_lines = function(params)
    local util = require "ai_builder_base_util"
    local lines = {}

    -- Use line system API to get all lines
    local lineIds = api.engine.system.lineSystem.getLines()

    for i, lineId in pairs(lineIds) do
        local naming = util.getComponent(lineId, api.type.ComponentType.NAME)
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
        local lineData = util.getComponent(lineId, api.type.ComponentType.LINE)
        local lineEntity = util.getEntity(lineId)

        -- Get frequency/rate data
        local rate = lineEntity and lineEntity.rate or 0
        local frequency = lineEntity and lineEntity.frequency or 0

        -- Calculate interval between vehicles (if we have vehicles)
        local interval = 0
        if #vehicles > 0 and frequency > 0 then
            interval = 1 / frequency  -- frequency is vehicles per second
        end

        -- Get items transported using CUMULATIVE totals.
        -- itemsTransported has: _lastYear (table), _lastMonth (table), _sum (number),
        -- plus top-level cargo keys like GRAIN=102 (cumulative total per cargo).
        -- There is NO _thisYear field. Use top-level cargo keys for reliable data.
        local transported = {}
        local totalTransported = 0
        if lineEntity and lineEntity.itemsTransported then
            -- Top-level keys (not starting with _) are cumulative cargo totals
            for cargoName, amount in pairs(lineEntity.itemsTransported) do
                if type(cargoName) == "string" and cargoName:sub(1,1) ~= "_"
                   and type(amount) == "number" and amount > 0 then
                    transported[cargoName] = amount
                    totalTransported = totalTransported + amount
                end
            end
            -- If no top-level cargo keys found, fall back to _lastYear
            if totalTransported == 0 and lineEntity.itemsTransported._lastYear then
                for cargoName, amount in pairs(lineEntity.itemsTransported._lastYear) do
                    if type(cargoName) == "string" and cargoName:sub(1,1) ~= "_"
                       and type(amount) == "number" and amount > 0 then
                        transported[cargoName] = amount
                        totalTransported = totalTransported + amount
                    end
                end
            end
        end
        -- Convert to strings for JSON
        for k, v in pairs(transported) do
            transported[k] = tostring(math.floor(v))
        end

        table.insert(lines, {
            id = tostring(lineId),
            name = naming and naming.name or ("Line " .. lineId),
            vehicle_count = tostring(#vehicles),
            stop_count = tostring(lineData and #lineData.stops or 0),
            rate = tostring(rate),
            frequency = tostring(frequency),
            interval = tostring(math.floor(interval)),  -- seconds between vehicles
            transported = transported,  -- cargo -> amount last year
            total_transported = tostring(math.floor(totalTransported))
        })
    end

    return {status = "ok", data = {lines = lines}}
end

-- Debug: dump itemsTransported structure for a line
handlers.debug_line_transport = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end
    local util = require "ai_builder_base_util"
    local lineId = tonumber(params.line_id)
    local lineEntity = util.getEntity(lineId)
    if not lineEntity then
        return {status = "error", message = "Line entity not found"}
    end

    local result = {entity_keys = {}, transport_keys = {}, raw_type = "unknown"}

    -- Enumerate entity top-level keys
    for k, v in pairs(lineEntity) do
        table.insert(result.entity_keys, tostring(k) .. "=" .. type(v))
    end

    if lineEntity.itemsTransported then
        result.raw_type = type(lineEntity.itemsTransported)
        -- Enumerate all keys in itemsTransported
        for k, v in pairs(lineEntity.itemsTransported) do
            table.insert(result.transport_keys, tostring(k) .. "=" .. type(v))
            if type(v) == "table" then
                local sub = {}
                for sk, sv in pairs(v) do
                    sub[tostring(sk)] = tostring(sv)
                end
                result["sub_" .. tostring(k)] = sub
            elseif type(v) == "userdata" then
                -- Try tostring on userdata
                result["val_" .. tostring(k)] = "userdata:" .. tostring(v)
            else
                result["val_" .. tostring(k)] = tostring(v)
            end
        end
    else
        result.raw_type = "nil_or_false"
        result.has_field = tostring(lineEntity.itemsTransported)
    end

    result.rate = tostring(lineEntity.rate or 0)
    result.frequency = tostring(lineEntity.frequency or 0)

    return {status = "ok", data = result}
end

-- Trigger AI Builder to optimize a line's vehicle count
handlers.optimize_line_vehicles = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Missing line_id parameter"}
    end

    local lineId = tonumber(params.line_id)
    if not lineId then
        return {status = "error", message = "Invalid line_id"}
    end

    log("OPTIMIZE_VEHICLES: Triggering AI Builder optimization for line " .. lineId)

    -- Queue the line for AI Builder's regular optimization cycle
    -- The AI Builder will check and add vehicles if needed during its next tick
    local ok, err = pcall(function()
        local lineManager = require "ai_builder_line_manager"
        -- Add to high priority queue for next evaluation
        if lineManager.addLineToEvaluationQueue then
            lineManager.addLineToEvaluationQueue(lineId, "HIGH")
        end
    end)

    if not ok then
        log("OPTIMIZE_VEHICLES: " .. tostring(err) .. " - AI Builder will handle naturally")
    end

    return {status = "ok", data = {line_id = lineId, action = "queued_for_optimization"}}
end

handlers.query_vehicles = function(params)
    if not game or not game.interface then
        return {status = "error", message = "Game interface not available"}
    end

    local vehicles = {}
    local entities = game.interface.getEntities({radius=1e9}, {type="VEHICLE", includeData=true})

    for id, vehicle in pairs(entities) do
        table.insert(vehicles, {
            id = tostring(id),
            line = tostring(vehicle.line or -1)
        })
    end

    return {status = "ok", data = {vehicles = vehicles}}
end

handlers.query_stations = function(params)
    if not game or not game.interface then
        return {status = "error", message = "Game interface not available"}
    end

    local stations = {}
    local entities = game.interface.getEntities({radius=1e9}, {type="STATION", includeData=true})

    for id, station in pairs(entities) do
        table.insert(stations, {
            id = tostring(id),
            name = station.name or "Station"
        })
    end

    return {status = "ok", data = {stations = stations}}
end

-- Snapshot state for later diffing
handlers.snapshot_state = function(params)
    local util = require "ai_builder_base_util"

    -- Generate unique snapshot ID
    local snapshot_id = tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))

    -- Capture current state
    local snapshot = {
        timestamp = os.time(),
        game_state = {},
        lines = {},
        vehicles = {},
        money = "0"
    }

    -- Get game state
    local gameTime = game.interface.getGameTime()
    if gameTime and gameTime.date then
        snapshot.game_state.year = tostring(gameTime.date.year or 1850)
        snapshot.game_state.month = tostring(gameTime.date.month or 1)
    end

    -- Get money
    local player = game.interface.getPlayer()
    if player then
        local playerEntity = game.interface.getEntity(player)
        snapshot.money = tostring(playerEntity and playerEntity.balance or 0)
    end

    -- Get lines
    local lineIds = api.engine.system.lineSystem.getLines()
    for i, lineId in pairs(lineIds) do
        local naming = util.getComponent(lineId, api.type.ComponentType.NAME)
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
        local lineData = util.getComponent(lineId, api.type.ComponentType.LINE)

        snapshot.lines[tostring(lineId)] = {
            id = tostring(lineId),
            name = naming and naming.name or ("Line " .. lineId),
            vehicle_count = #vehicles,
            stop_count = lineData and #lineData.stops or 0
        }
    end

    -- Get vehicles
    local vehicleEntities = game.interface.getEntities({radius=1e9}, {type="VEHICLE", includeData=true})
    for id, vehicle in pairs(vehicleEntities) do
        snapshot.vehicles[tostring(id)] = {
            id = tostring(id),
            line = tostring(vehicle.line or -1)
        }
    end

    -- Store snapshot
    snapshots[snapshot_id] = snapshot

    -- Clean up old snapshots (keep only last 10)
    local snapshotIds = {}
    for id, _ in pairs(snapshots) do
        table.insert(snapshotIds, id)
    end
    table.sort(snapshotIds)
    while #snapshotIds > 10 do
        local oldId = table.remove(snapshotIds, 1)
        snapshots[oldId] = nil
    end

    log("SNAPSHOT: Created " .. snapshot_id .. " with " .. #lineIds .. " lines")

    return {
        status = "ok",
        data = {
            snapshot_id = snapshot_id,
            lines_count = #lineIds,
            vehicles_count = util.tableSize and util.tableSize(vehicleEntities) or 0
        }
    }
end

-- Diff current state against a snapshot
handlers.diff_state = function(params)
    if not params or not params.snapshot_id then
        return {status = "error", message = "Missing snapshot_id parameter"}
    end

    local snapshot_id = params.snapshot_id
    local snapshot = snapshots[snapshot_id]

    if not snapshot then
        return {status = "error", message = "Snapshot not found: " .. snapshot_id}
    end

    local util = require "ai_builder_base_util"

    -- Get current state
    local current_lines = {}
    local current_vehicles = {}
    local current_money = "0"

    -- Get money
    local player = game.interface.getPlayer()
    if player then
        local playerEntity = game.interface.getEntity(player)
        current_money = tostring(playerEntity and playerEntity.balance or 0)
    end

    -- Get current lines
    local lineIds = api.engine.system.lineSystem.getLines()
    for i, lineId in pairs(lineIds) do
        local naming = util.getComponent(lineId, api.type.ComponentType.NAME)
        local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
        local lineData = util.getComponent(lineId, api.type.ComponentType.LINE)

        current_lines[tostring(lineId)] = {
            id = tostring(lineId),
            name = naming and naming.name or ("Line " .. lineId),
            vehicle_count = #vehicles,
            stop_count = lineData and #lineData.stops or 0,
            type = lineData and lineData.stops and lineData.stops[1] and "ROAD" or "UNKNOWN"
        }
    end

    -- Get current vehicles
    local vehicleEntities = game.interface.getEntities({radius=1e9}, {type="VEHICLE", includeData=true})
    for id, vehicle in pairs(vehicleEntities) do
        current_vehicles[tostring(id)] = {
            id = tostring(id),
            line = tostring(vehicle.line or -1)
        }
    end

    -- Calculate diff
    local diff = {
        added = {lines = {}, vehicles = {}},
        removed = {lines = {}, vehicles = {}},
        changed = {lines = {}, money = nil}
    }

    -- Find added and changed lines
    for lineId, line in pairs(current_lines) do
        if not snapshot.lines[lineId] then
            table.insert(diff.added.lines, line)
            log("DIFF: Added line " .. lineId .. " (" .. line.name .. ")")
        elseif snapshot.lines[lineId].vehicle_count ~= line.vehicle_count then
            table.insert(diff.changed.lines, {
                id = lineId,
                name = line.name,
                old_vehicles = snapshot.lines[lineId].vehicle_count,
                new_vehicles = line.vehicle_count
            })
        end
    end

    -- Find removed lines
    for lineId, line in pairs(snapshot.lines) do
        if not current_lines[lineId] then
            table.insert(diff.removed.lines, line)
            log("DIFF: Removed line " .. lineId)
        end
    end

    -- Find added vehicles
    for vehicleId, vehicle in pairs(current_vehicles) do
        if not snapshot.vehicles[vehicleId] then
            table.insert(diff.added.vehicles, vehicle)
        end
    end

    -- Find removed vehicles
    for vehicleId, vehicle in pairs(snapshot.vehicles) do
        if not current_vehicles[vehicleId] then
            table.insert(diff.removed.vehicles, vehicle)
        end
    end

    -- Money change
    local old_money = tonumber(snapshot.money) or 0
    local new_money = tonumber(current_money) or 0
    if old_money ~= new_money then
        diff.changed.money = {
            old = tostring(old_money),
            new = tostring(new_money),
            delta = tostring(new_money - old_money)
        }
    end

    log("DIFF: " .. #diff.added.lines .. " lines added, " .. #diff.added.vehicles .. " vehicles added")

    return {
        status = "ok",
        data = {
            snapshot_id = snapshot_id,
            diff = diff,
            summary = {
                lines_added = #diff.added.lines,
                lines_removed = #diff.removed.lines,
                lines_changed = #diff.changed.lines,
                vehicles_added = #diff.added.vehicles,
                vehicles_removed = #diff.removed.vehicles
            }
        }
    }
end

handlers.pause = function(params)
    targetGameSpeed = 0
    log("PAUSE: Setting speed to 0")
    api.cmd.sendCommand(api.cmd.make.setGameSpeed(0))
    return {status = "ok"}
end

handlers.resume = function(params)
    targetGameSpeed = 4
    api.cmd.sendCommand(api.cmd.make.setGameSpeed(4))
    return {status = "ok"}
end

handlers.set_speed = function(params)
    local speed = tonumber(params and params.speed) or 4
    if speed < 0 then speed = 0 end
    if speed > 4 then speed = 4 end
    targetGameSpeed = speed  -- Update the global target so poll() respects it
    log("SET_SPEED: Setting to " .. tostring(speed))
    api.cmd.sendCommand(api.cmd.make.setGameSpeed(speed))
    return {status = "ok", data = {speed = tostring(speed)}}
end

-- Calendar speed controls date advancement rate (separate from game simulation speed)
-- Raw integer value: displayed_speed = 2000 / value (at game speed 4x)
-- Examples: 4=500x (default), 16=125x, 8000=0.25x
-- 0 pauses the calendar
handlers.set_calendar_speed = function(params)
    local speed = math.floor(tonumber(params and params.speed) or 4)
    if speed < 0 then speed = 0 end
    log("SET_CALENDAR_SPEED: Setting to " .. tostring(speed))
    api.cmd.sendCommand(api.cmd.make.setCalendarSpeed(speed))
    return {status = "ok", data = {calendar_speed = tostring(speed)}}
end

-- Query terrain height at a position (water is below 0)
handlers.query_terrain_height = function(params)
    local x = tonumber(params and params.x) or 0
    local y = tonumber(params and params.y) or 0

    local vec2f = api.type.Vec2f.new(x, y)

    if not api.engine.terrain.isValidCoordinate(vec2f) then
        return {status = "error", message = "Invalid coordinates"}
    end

    local baseHeight = api.engine.terrain.getBaseHeightAt(vec2f)
    local currentHeight = api.engine.terrain.getHeightAt(vec2f)
    -- Water level is typically 0 in TF2
    local waterLevel = 0
    local isWater = baseHeight < waterLevel

    return {
        status = "ok",
        data = {
            x = tostring(x),
            y = tostring(y),
            base_height = tostring(baseHeight),
            current_height = tostring(currentHeight),
            water_level = tostring(waterLevel),
            is_water = isWater and "true" or "false"
        }
    }
end

-- Check if water path exists between two points (samples terrain along line)
handlers.check_water_path = function(params)
    local x1 = tonumber(params and params.x1) or 0
    local y1 = tonumber(params and params.y1) or 0
    local x2 = tonumber(params and params.x2) or 0
    local y2 = tonumber(params and params.y2) or 0
    local samples = tonumber(params and params.samples) or 20

    -- Water level is typically 0 in TF2
    local waterLevel = 0
    local waterPoints = 0
    local landPoints = 0
    local heights = {}

    for i = 0, samples do
        local t = i / samples
        local x = x1 + (x2 - x1) * t
        local y = y1 + (y2 - y1) * t
        local vec2f = api.type.Vec2f.new(x, y)

        if api.engine.terrain.isValidCoordinate(vec2f) then
            local h = api.engine.terrain.getBaseHeightAt(vec2f)
            table.insert(heights, h)
            if h < waterLevel then
                waterPoints = waterPoints + 1
            else
                landPoints = landPoints + 1
            end
        end
    end

    -- Consider water path viable if >70% of samples are water
    local waterRatio = waterPoints / (waterPoints + landPoints)
    local hasWaterPath = waterRatio > 0.7

    -- Also check endpoints - both should be near water for ship access
    local start_vec = api.type.Vec2f.new(x1, y1)
    local end_vec = api.type.Vec2f.new(x2, y2)
    local startNearWater = false
    local endNearWater = false

    -- Check 500m radius around start for water
    for dx = -500, 500, 100 do
        for dy = -500, 500, 100 do
            local check_vec = api.type.Vec2f.new(x1 + dx, y1 + dy)
            if api.engine.terrain.isValidCoordinate(check_vec) then
                if api.engine.terrain.getBaseHeightAt(check_vec) < waterLevel then
                    startNearWater = true
                    break
                end
            end
        end
        if startNearWater then break end
    end

    for dx = -500, 500, 100 do
        for dy = -500, 500, 100 do
            local check_vec = api.type.Vec2f.new(x2 + dx, y2 + dy)
            if api.engine.terrain.isValidCoordinate(check_vec) then
                if api.engine.terrain.getBaseHeightAt(check_vec) < waterLevel then
                    endNearWater = true
                    break
                end
            end
        end
        if endNearWater then break end
    end

    return {
        status = "ok",
        data = {
            water_points = tostring(waterPoints),
            land_points = tostring(landPoints),
            water_ratio = tostring(waterRatio),
            has_water_path = hasWaterPath and "true" or "false",
            start_near_water = startNearWater and "true" or "false",
            end_near_water = endNearWater and "true" or "false",
            ship_viable = (hasWaterPath and startNearWater and endNearWater) and "true" or "false"
        }
    }
end

handlers.add_money = function(params)
    local amount = tonumber(params and params.amount) or 50000000
    log("ADD_MONEY: Adding " .. tostring(amount))
    local player = api.engine.util.getPlayer()
    -- Try multiple approaches to add money
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.setBalance(amount))
    end)
    if ok then
        return {status = "ok", data = {added = tostring(amount)}}
    end
    -- Fallback: use sendScriptEvent to trigger the AI builder's money cheat
    local ok2, err2 = pcall(function()
        local util = require("ai_builder_base_util")
        -- Direct entity component manipulation
        local playerComp = api.engine.getComponent(player, api.type.ComponentType.PLAYER_FINANCES)
        if playerComp then
            log("ADD_MONEY: Player finances component found")
        end
    end)
    return {status = "error", message = "setBalance not available: " .. tostring(err) .. " / " .. tostring(err2)}
end

handlers.build_road = function(params)
    log("BUILD_ROAD: === START ===")
    log("BUILD_ROAD: params.cargo=" .. tostring(params and params.cargo or "nil"))
    
    local cargo = params and params.cargo or nil
    log("BUILD_ROAD: cargo extracted=" .. tostring(cargo))
    
    local opts = {ignoreErrors = false}
    if cargo then 
        opts.cargoFilter = cargo 
        log("BUILD_ROAD: cargoFilter set to " .. cargo)
    else
        log("BUILD_ROAD: WARNING - no cargo filter, will use AI Builder default")
    end

    if not api or not api.cmd then
        log("BUILD_ROAD: ERROR - api.cmd not available")
        return {status = "error", message = "api.cmd not available"}
    end

    log("BUILD_ROAD: Sending sendScriptEvent with opts.cargoFilter=" .. tostring(opts.cargoFilter))
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            "buildNewIndustryRoadConnection",
            "",
            opts
        ))
    end)

    if not ok then
        log("BUILD_ROAD: ERROR - " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_ROAD: === SUCCESS - event sent with cargoFilter=" .. tostring(opts.cargoFilter) .. " ===")
    return {status = "ok", data = "build_started", cargo = cargo}
end

-- Build a connection between two specific industries using evaluation (recommended)
-- This runs the AI Builder's evaluation with preSelectedPair, ensuring all required
-- data is populated correctly before building.
handlers.build_industry_connection = function(params)
    if not params or not params.industry1_id or not params.industry2_id then
        return {status = "error", message = "Missing industry1_id or industry2_id"}
    end

    local ind1_id = tonumber(params.industry1_id)
    local ind2_id = tonumber(params.industry2_id)

    if not ind1_id or not ind2_id then
        return {status = "error", message = "Invalid industry IDs (must be numbers)"}
    end

    log("BUILD_INDUSTRY_CONNECTION: " .. ind1_id .. " -> " .. ind2_id)

    -- Check if api is available
    if not api or not api.cmd then
        log("ERROR: api.cmd not available in this context")
        return {status = "error", message = "api.cmd not available"}
    end

    -- Send event with preSelectedPair to run evaluation then build
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            "buildIndustryRoadConnectionEval",
            "",
            {
                preSelectedPair = {ind1_id, ind2_id},
                ignoreErrors = false
            }
        ))
    end)

    if not ok then
        log("BUILD_INDUSTRY_CONNECTION ERROR: " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_INDUSTRY_CONNECTION: Script event sent")
    return {status = "ok", data = {industry1_id = ind1_id, industry2_id = ind2_id}}
end

-- Build a connection between two specific industries (bypasses AI Builder's evaluation)
handlers.build_connection = function(params)
    if not params or not params.industry1_id or not params.industry2_id then
        return {status = "error", message = "Missing industry1_id or industry2_id"}
    end

    local ind1_id = tonumber(params.industry1_id)
    local ind2_id = tonumber(params.industry2_id)

    if not ind1_id or not ind2_id then
        return {status = "error", message = "Invalid industry IDs (must be numbers)"}
    end

    log("BUILD_CONNECTION: Getting industry entities " .. ind1_id .. " -> " .. ind2_id)

    -- Get industry entities from game
    local ind1 = game.interface.getEntity(ind1_id)
    local ind2 = game.interface.getEntity(ind2_id)

    if not ind1 then
        return {status = "error", message = "Industry 1 not found: " .. ind1_id}
    end
    if not ind2 then
        return {status = "error", message = "Industry 2 not found: " .. ind2_id}
    end

    -- Add IDs to entities
    ind1.id = ind1_id
    ind2.id = ind2_id

    log("BUILD_CONNECTION: Found industries: " .. tostring(ind1.name) .. " -> " .. tostring(ind2.name))

    -- Get positions for p0 and p1 (required by getTruckStationsToBuild)
    -- Convert from array format {1=x, 2=y, 3=z} to object format {x=..., y=..., z=...}
    local function posToVec3(pos)
        if not pos then return nil end
        return {
            x = pos[1] or pos.x or 0,
            y = pos[2] or pos.y or 0,
            z = pos[3] or pos.z or 0
        }
    end
    local p0 = posToVec3(ind1.position)
    local p1 = posToVec3(ind2.position)
    log("BUILD_CONNECTION: p0=(" .. tostring(p0.x) .. "," .. tostring(p0.y) .. "," .. tostring(p0.z) .. ")")
    log("BUILD_CONNECTION: p1=(" .. tostring(p1.x) .. "," .. tostring(p1.y) .. "," .. tostring(p1.z) .. ")")

    -- Determine transport type
    local transport_type = params.transport_type or "road"
    local carrier = api.type.enum.Carrier.ROAD
    local event_name = "buildNewIndustryRoadConnection"

    if transport_type == "rail" then
        carrier = api.type.enum.Carrier.RAIL
        event_name = "buildIndustryRailConnection"
    elseif transport_type == "water" or transport_type == "ship" then
        carrier = api.type.enum.Carrier.WATER
        event_name = "buildNewWaterConnection"
    end

    log("BUILD_CONNECTION: transport_type=" .. transport_type .. " carrier=" .. tostring(carrier))

    -- Calculate distance between industries
    local dx = p1.x - p0.x
    local dy = p1.y - p0.y
    local distance = math.sqrt(dx * dx + dy * dy)
    log("BUILD_CONNECTION: distance=" .. distance)

    -- Create result object for AI Builder
    local result = {
        industry1 = ind1,
        industry2 = ind2,
        carrier = carrier,
        cargoType = params.cargo or nil,
        -- Required position vectors
        p0 = p0,
        p1 = p1,
        -- Distance (required for rail params)
        distance = distance,
        -- Other fields that may be needed
        isTown = false,
        needsNewRoute = true,
        isAutoBuildMode = true,
        isCargo = true
    }

    -- Send to AI Builder with the pre-built result
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            event_name,
            "",
            {ignoreErrors = false, result = result, preSelectedPair = {ind1_id, ind2_id}}
        ))
    end)

    if not ok then
        log("BUILD_CONNECTION ERROR: " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_CONNECTION: Script event sent with result")
    return {status = "ok", data = {industry1 = ind1.name, industry2 = ind2.name}}
end

handlers.enable_auto_build = function(params)
    -- Enable AI Builder's auto-build options
    local options = {
        autoEnableTruckFreight = true,
        autoEnableLineManager = true,
    }

    -- Add optional settings from params
    if params then
        if params.trucks ~= nil then options.autoEnableTruckFreight = params.trucks end
        if params.trains ~= nil then options.autoEnableFreightTrains = params.trains end
        if params.buses ~= nil then options.autoEnableIntercityBus = params.buses end
        if params.ships ~= nil then options.autoEnableShipFreight = params.ships end
        if params.full ~= nil then options.autoEnableFullManagement = params.full end
    end

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script",
        "aiEnableOptions",
        "",
        {aiEnableOptions = options}
    ))
    return {status = "ok", data = options}
end

handlers.disable_auto_build = function(params)
    -- Disable ALL AI Builder auto-build options
    local options = {
        autoEnablePassengerTrains = false,
        autoEnableFreightTrains = false,
        autoEnableTruckFreight = false,
        autoEnableIntercityBus = false,
        autoEnableShipFreight = false,
        autoEnableShipPassengers = false,
        autoEnableAirPassengers = false,
        autoEnableLineManager = false,
        autoEnableHighwayBuilder = false,
        autoEnableAirFreight = false,
        autoEnableFullManagement = false,
        autoEnableExpandingBusCoverage = false,
        autoEnableExpandingCargoCoverage = false,
    }

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script",
        "aiEnableOptions",
        "",
        {aiEnableOptions = options}
    ))
    return {status = "ok", data = {message = "All auto-build options disabled", options = options}}
end

-- Build cargo delivery route from industry to town
-- Completes supply chains by delivering final products (FOOD, TOOLS, etc.) to towns
handlers.build_cargo_to_town = function(params)
    if not params or not params.industry_id or not params.town_id then
        return {status = "error", message = "Need industry_id and town_id"}
    end

    local ind_id = tonumber(params.industry_id)
    local town_id = tonumber(params.town_id)

    if not ind_id or not town_id then
        return {status = "error", message = "Invalid IDs (must be numbers)"}
    end

    log("BUILD_CARGO_TO_TOWN: " .. ind_id .. " -> town " .. town_id)

    -- Get source industry
    local industry = game.interface.getEntity(ind_id)
    if not industry then
        return {status = "error", message = "Industry not found: " .. ind_id}
    end

    -- Get town
    local town = game.interface.getEntity(town_id)
    if not town then
        return {status = "error", message = "Town not found: " .. town_id}
    end

    log("BUILD_CARGO_TO_TOWN: " .. industry.name .. " -> " .. town.name)

    -- Get positions for both entities
    local function posToVec3(pos)
        if not pos then return {x = 0, y = 0, z = 0} end
        return {
            x = pos[1] or pos.x or 0,
            y = pos[2] or pos.y or 0,
            z = pos[3] or pos.z or 0
        }
    end

    local p0 = posToVec3(industry.position)
    local p1 = posToVec3(town.position)

    log("BUILD_CARGO_TO_TOWN: p0=(" .. tostring(p0.x) .. "," .. tostring(p0.y) .. ") p1=(" .. tostring(p1.x) .. "," .. tostring(p1.y) .. ")")

    -- Add IDs to entities (required by AI builder)
    industry.id = ind_id
    town.id = town_id

    local dx = p1.x - p0.x
    local dy = p1.y - p0.y
    local distance = math.sqrt(dx * dx + dy * dy)

    -- Build result object same as build_connection does
    local result = {
        industry1 = industry,
        industry2 = town,
        carrier = api.type.enum.Carrier.ROAD,
        cargoType = params.cargo or nil,
        p0 = p0,
        p1 = p1,
        distance = distance,
        isTown = true,
        needsNewRoute = true,
        isAutoBuildMode = true,
        isCargo = true
    }

    -- Send to AI Builder using the standard road connection builder
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            "buildNewIndustryRoadConnection",
            "",
            {ignoreErrors = false, result = result, preSelectedPair = {ind_id, town_id}}
        ))
    end)

    if not ok then
        log("BUILD_CARGO_TO_TOWN ERROR: " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_CARGO_TO_TOWN: Event sent for " .. industry.name .. " -> " .. town.name)
    return {status = "ok", data = {
        industry = industry.name,
        town = town.name,
        cargo = params.cargo
    }}
end

-- Build intra-city bus network for a town
handlers.build_town_bus = function(params)
    if not params or not params.town_id then
        return {status = "error", message = "Need town_id"}
    end

    local town_id = tonumber(params.town_id)
    if not town_id then
        return {status = "error", message = "Invalid town_id (must be number)"}
    end

    log("BUILD_TOWN_BUS: town " .. town_id)

    -- Send event to build town bus network
    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script", "buildNewTownBusStop", "", {town = town_id}))

    return {status = "ok", data = {
        message = "Town bus network build triggered",
        town_id = tostring(town_id)
    }}
end

-- Build a multi-stop route - bypasses AI Builder evaluation
-- Uses DAG-indicated industries directly
handlers.build_multistop_route = function(params)
    if not params or not params.industry_ids or #params.industry_ids < 2 then
        return {status = "error", message = "Need industry_ids array with at least 2 IDs"}
    end

    log("BUILD_MULTISTOP: " .. #params.industry_ids .. " stops")

    -- Get all industry entities
    local industries = {}
    local names = {}
    for i, id_str in ipairs(params.industry_ids) do
        local ind_id = tonumber(id_str)
        if not ind_id then
            return {status = "error", message = "Invalid ID at position " .. i}
        end

        local ind = game.interface.getEntity(ind_id)
        if not ind then
            return {status = "error", message = "Industry not found: " .. ind_id}
        end

        -- Add required fields for buildMultiStopCargoRoute
        ind.id = ind_id
        ind.type = "INDUSTRY"
        table.insert(industries, ind)
        table.insert(names, ind.name)
        log("BUILD_MULTISTOP: Stop " .. i .. ": " .. ind.name .. " (ID " .. ind_id .. ")")
    end

    -- Build the route directly - NO EVALUATION
    local event_params = {
        industries = industries,
        lineName = params.line_name or "DAG Route",
        defaultCargoType = params.cargo or "COAL",
        transportMode = params.transport_mode or "ROAD",  -- "ROAD" or "RAIL"
        targetRate = params.target_rate or 100
    }

    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script",
            "buildMultiStopCargoRoute",
            "",
            event_params
        ))
    end)

    if not ok then
        log("BUILD_MULTISTOP ERROR: " .. tostring(err))
        return {status = "error", message = tostring(err)}
    end

    log("BUILD_MULTISTOP: Event sent for " .. #industries .. " stops")
    return {status = "ok", data = {
        industries = names,
        mode = params.transport_mode or "ROAD",
        stops = #industries
    }}
end

-- Line manipulation handlers for two-step multi-stop strategy

-- Create a line from existing station IDs
handlers.create_line_from_stations = function(params)
    if not params or not params.station_ids or #params.station_ids < 2 then
        return {status = "error", message = "Need station_ids array with at least 2 station IDs"}
    end

    local ok, result = pcall(function()
        local util = require "ai_builder_base_util"
        local line = api.type.Line.new()
        local stopIndex = 1
        local isRail = false

        for _, stationIdStr in ipairs(params.station_ids) do
            local entityId = tonumber(stationIdStr)
            if entityId and api.engine.entityExists(entityId) then
                local stationGroupId = nil
                local stationEntityId = nil

                -- The IDs from query_nearby_stations are CONSTRUCTION entity IDs.
                -- Chain: Construction -> Station entity -> Station Group
                local conOk, con = pcall(function()
                    return api.engine.getComponent(entityId, api.type.ComponentType.CONSTRUCTION)
                end)
                if conOk and con and con.stations and #con.stations > 0 then
                    stationEntityId = con.stations[1]
                    log("CREATE_LINE: construction " .. entityId .. " -> station " .. tostring(stationEntityId))
                    if con.fileName and tostring(con.fileName):find("rail") then
                        isRail = true
                    end
                else
                    stationEntityId = entityId
                    log("CREATE_LINE: using entity " .. entityId .. " as station directly")
                end

                if stationEntityId then
                    local sgOk, sg = pcall(function()
                        return api.engine.system.stationGroupSystem.getStationGroup(stationEntityId)
                    end)
                    if sgOk and sg then
                        stationGroupId = sg
                        log("CREATE_LINE: station " .. tostring(stationEntityId) .. " -> stationGroup " .. tostring(sg))
                    else
                        log("CREATE_LINE: Failed getStationGroup for " .. tostring(stationEntityId))
                    end
                end

                if stationGroupId then
                    local stop = api.type.Line.Stop.new()
                    stop.stationGroup = stationGroupId
                    stop.station = 0
                    stop.terminal = 0
                    line.stops[stopIndex] = stop
                    stopIndex = stopIndex + 1
                    log("CREATE_LINE: added stop " .. (stopIndex-1) .. " stationGroup=" .. tostring(stationGroupId))
                end
            else
                log("CREATE_LINE: Skipping invalid entity: " .. tostring(stationIdStr))
            end
        end

        -- Set transport mode (critical for rail lines!)
        if isRail or (params.transport_type and params.transport_type == "rail") then
            local transportModes = line.vehicleInfo.transportModes
            transportModes[api.type.enum.TransportMode.TRAIN + 1] = 1
            line.vehicleInfo.transportModes = transportModes
            log("CREATE_LINE: Set transport mode to TRAIN")
        end

        local lineName = params.name or ("Line " .. os.time())
        local lineColor = api.type.Vec3f.new(math.random(), math.random(), math.random())
        local player = api.engine.util.getPlayer()

        log("CREATE_LINE: Creating line '" .. lineName .. "' with " .. (stopIndex-1) .. " stops, player=" .. tostring(player) .. " isRail=" .. tostring(isRail))

        api.cmd.sendCommand(
            api.cmd.make.createLine(lineName, lineColor, player, line),
            function(res, success)
                log("CREATE_LINE: callback success=" .. tostring(success))
                if success then
                    local getOk, lineId = pcall(function() return res.resultEntity end)
                    if getOk and lineId then
                        log("CREATE_LINE: Created line " .. tostring(lineId))
                    else
                        log("CREATE_LINE: Created but couldn't get resultEntity")
                    end
                else
                    log("CREATE_LINE: Failed to create line")
                end
            end
        )

        return {status = "ok", message = "Line creation command sent", line_name = lineName}
    end)

    if ok then return result end
    return {status = "error", message = "create_line_from_stations failed: " .. tostring(result)}
end

-- Delete a line
handlers.delete_line = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end

    local lineId = tonumber(params.line_id)

    -- Sell ALL vehicles first (deleteLine fails if vehicles remain)
    local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
    local sold = 0
    for i = #vehicles, 1, -1 do
        pcall(function()
            api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicles[i]))
        end)
        sold = sold + 1
    end
    if sold > 0 then
        log("Sold " .. sold .. " vehicles before deleting line " .. tostring(lineId))
    end

    api.cmd.sendCommand(api.cmd.make.deleteLine(lineId))
    log("Deleted line " .. tostring(lineId))

    return {status = "ok", message = "Line deleted", data = {
        vehicles_sold = tostring(sold),
        line_id = tostring(lineId)
    }}
end

-- Remove N vehicles from a line (sells them)
handlers.remove_vehicles_from_line = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end
    local lineId = tonumber(params.line_id)
    local count = math.min(tonumber(params.count or "1") or 1, 20)
    if not lineId then
        return {status = "error", message = "Invalid line_id"}
    end

    local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
    if #vehicles == 0 then
        return {status = "ok", data = {removed = "0", remaining = "0"}}
    end

    -- Keep at least 1 vehicle on the line
    local toRemove = math.min(count, #vehicles - 1)
    if toRemove <= 0 then
        return {status = "ok", data = {removed = "0", remaining = tostring(#vehicles)}}
    end

    local removed = 0
    for i = 1, toRemove do
        local vehicleId = vehicles[#vehicles - i + 1]  -- Remove from end
        local ok, err = pcall(function()
            api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleId))
        end)
        if ok then
            removed = removed + 1
        else
            log("REMOVE_VEHICLES: Failed to sell vehicle " .. tostring(vehicleId) .. ": " .. tostring(err))
        end
    end

    log("REMOVE_VEHICLES: Removed " .. removed .. "/" .. toRemove .. " from line " .. lineId)
    return {status = "ok", data = {
        removed = tostring(removed),
        remaining = tostring(#vehicles - removed),
        line_id = tostring(lineId)
    }}
end

-- Sell a vehicle
handlers.sell_vehicle = function(params)
    if not params or not params.vehicle_id then
        return {status = "error", message = "Need vehicle_id parameter"}
    end

    local vehicleId = tonumber(params.vehicle_id)
    api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleId))
    log("Sold vehicle " .. tostring(vehicleId))

    return {status = "ok", message = "Vehicle sold", vehicle_id = tostring(vehicleId)}
end

-- Set load mode for all stops on a line
-- mode: "load_if_available" (default), "full_load_all", "full_load_any"
handlers.set_line_load_mode = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end
    local lineId = tonumber(params.line_id)
    local mode = params.mode or "load_if_available"

    local ok, result = pcall(function()
        local lineManager = require "ai_builder_line_manager"
        local util = require "ai_builder_base_util"

        local lineDetails = util.getComponent(lineId, api.type.ComponentType.LINE)
        if not lineDetails then
            return {status = "error", message = "Line not found: " .. tostring(lineId)}
        end

        -- Map mode string to enum
        local loadMode
        if mode == "full_load_all" then
            loadMode = api.type.enum.LineLoadMode.FULL_LOAD_ALL
        elseif mode == "full_load_any" then
            loadMode = api.type.enum.LineLoadMode.FULL_LOAD_ANY
        else
            loadMode = api.type.enum.LineLoadMode.LOAD_IF_AVAILABLE or 0
        end

        -- Build updated line with new load mode on all stops
        local line = api.type.Line.new()
        line.vehicleInfo = lineDetails.vehicleInfo
        local stopCount = 0
        for i, stopDetail in pairs(lineDetails.stops) do
            local stop = api.type.Line.Stop.new()
            stop.stationGroup = stopDetail.stationGroup
            stop.station = stopDetail.station
            stop.terminal = stopDetail.terminal
            stop.loadMode = loadMode
            stop.minWaitingTime = stopDetail.minWaitingTime
            stop.maxWaitingTime = stopDetail.maxWaitingTime
            stop.waypoints = stopDetail.waypoints
            stop.stopConfig = stopDetail.stopConfig
            stop.alternativeTerminals = stopDetail.alternativeTerminals
            line.stops[i] = stop
            stopCount = stopCount + 1
        end

        local updateLine = api.cmd.make.updateLine(lineId, line)
        api.cmd.sendCommand(updateLine, function(cmd, success)
            log("SET_LOAD_MODE: updateLine callback success=" .. tostring(success))
        end)

        return {status = "ok", data = {
            line_id = tostring(lineId),
            mode = mode,
            stops_updated = tostring(stopCount)
        }}
    end)
    if ok then return result end
    return {status = "error", message = "set_line_load_mode failed: " .. tostring(result)}
end

-- Set all stops on a line to use all terminals at each station
handlers.set_line_all_terminals = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end
    local lineId = tonumber(params.line_id)

    local ok, result = pcall(function()
        local util = require "ai_builder_base_util"

        local lineDetails = util.getComponent(lineId, api.type.ComponentType.LINE)
        if not lineDetails then
            return {status = "error", message = "Line not found: " .. tostring(lineId)}
        end

        local line = api.type.Line.new()
        line.vehicleInfo = lineDetails.vehicleInfo
        local stopCount = 0
        local terminalsAdded = 0
        for i, stopDetail in pairs(lineDetails.stops) do
            local stop = api.type.Line.Stop.new()
            stop.stationGroup = stopDetail.stationGroup
            stop.station = stopDetail.station
            stop.terminal = stopDetail.terminal
            stop.loadMode = stopDetail.loadMode
            stop.minWaitingTime = stopDetail.minWaitingTime
            stop.maxWaitingTime = stopDetail.maxWaitingTime
            stop.waypoints = stopDetail.waypoints
            stop.stopConfig = stopDetail.stopConfig

            -- Find all terminals for this station
            local stationGroupComp = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
            if stationGroupComp then
                local stationId = stationGroupComp.stations[stop.station + 1]
                if stationId then
                    local station = util.getStation(stationId)
                    if station and station.terminals then
                        local numTerminals = #station.terminals
                        -- Add all OTHER terminals as alternatives
                        local altIdx = 1
                        for t = 0, numTerminals - 1 do
                            if t ~= stop.terminal then
                                local alt = api.type.StationTerminal.new()
                                alt.station = stop.station
                                alt.terminal = t
                                stop.alternativeTerminals[altIdx] = alt
                                altIdx = altIdx + 1
                                terminalsAdded = terminalsAdded + 1
                            end
                        end
                        log("SET_ALL_TERMINALS: stop " .. i .. " station=" .. tostring(stationId) .. " numTerminals=" .. numTerminals .. " alternatives=" .. (altIdx - 1))
                    end
                end
            end

            line.stops[i] = stop
            stopCount = stopCount + 1
        end

        local updateLine = api.cmd.make.updateLine(lineId, line)
        api.cmd.sendCommand(updateLine, function(cmd, success)
            log("SET_ALL_TERMINALS: updateLine callback success=" .. tostring(success))
        end)

        return {status = "ok", data = {
            line_id = tostring(lineId),
            stops_updated = tostring(stopCount),
            terminals_added = tostring(terminalsAdded)
        }}
    end)
    if ok then return result end
    return {status = "error", message = "set_line_all_terminals failed: " .. tostring(result)}
end

-- Add vehicle(s) to a line
handlers.add_vehicle_to_line = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end

    local lineId = tonumber(params.line_id)
    if not lineId then
        return {status = "error", message = "Invalid line_id (must be number)"}
    end

    local count = tonumber(params.count) or 1
    if count < 1 or count > 10 then
        return {status = "error", message = "count must be 1-10"}
    end

    log("ADD_VEHICLE: Adding " .. count .. " vehicles to line " .. lineId)

    local ok, result = pcall(function()
        local lineManager = require "ai_builder_line_manager"
        local vehicleUtil = require "ai_builder_vehicle_util"
        local util = require "ai_builder_base_util"

        -- Get line info to determine carrier type
        local line = util.getComponent(lineId, api.type.ComponentType.LINE)
        if not line then
            return {status = "error", message = "Line not found: " .. tostring(lineId)}
        end

        -- Determine carrier type from line (or explicit param)
        local carrier = api.type.enum.Carrier.ROAD
        if params.carrier == "rail" then
            carrier = api.type.enum.Carrier.RAIL
            log("ADD_VEHICLE: Using explicit carrier=RAIL from params")
        elseif params.carrier == "water" then
            carrier = api.type.enum.Carrier.WATER
        elseif params.carrier == "air" then
            carrier = api.type.enum.Carrier.AIR
        elseif line.vehicleInfo and line.vehicleInfo.transportModes then
            local modes = line.vehicleInfo.transportModes
            if modes[api.type.enum.TransportMode.TRAIN+1] and modes[api.type.enum.TransportMode.TRAIN+1] > 0 then
                carrier = api.type.enum.Carrier.RAIL
            elseif modes[api.type.enum.TransportMode.SHIP+1] and modes[api.type.enum.TransportMode.SHIP+1] > 0 then
                carrier = api.type.enum.Carrier.WATER
            elseif modes[api.type.enum.TransportMode.AIRCRAFT+1] and modes[api.type.enum.TransportMode.AIRCRAFT+1] > 0 then
                carrier = api.type.enum.Carrier.AIR
            end
        end

        -- Find depots for this line (pass nil/empty to buyVehicleForLine and it will build one)
        local depotOk, depotOptions = pcall(function()
            return lineManager.findDepotsForLine(lineId, carrier)
        end)
        if not depotOk then
            log("ADD_VEHICLE: findDepotsForLine error: " .. tostring(depotOptions))
            depotOptions = nil
        end
        -- Don't return error - buyVehicleForLine will attempt to build a depot if none found

        -- Detect if this is a cargo line and what cargo type it carries
        local isCargoLine = false
        local lineCargoType = nil

        -- Method 1: Check line name for cargo types (most reliable for AI Builder created lines)
        -- AI Builder names lines like "Industry1-Industry2 Coal" with the cargo type at the end
        local lineName = ""
        local lineComponent = api.engine.getComponent(lineId, api.type.ComponentType.NAME)
        if lineComponent and lineComponent.name then
            lineName = lineComponent.name
        end
        log("ADD_VEHICLE: lineName=" .. lineName)

        -- Check if line name contains known cargo types
        -- Cargo types ordered longest-first to prevent false substring matches
        -- (e.g. "OIL_SAND" before "OIL", "IRON_ORE" before "IRON")
        -- Game uses CRUDE (not CRUDE_OIL) for crude oil cargo
        local cargoTypes = {"CONSTRUCTION_MATERIALS", "COFFEE_BERRIES", "SILVER_ORE", "IRON_ORE", "OIL_SAND", "LIVESTOCK", "MACHINES", "PLASTIC", "PLANKS", "MARBLE", "SILVER", "GRAIN", "CRUDE", "STEEL", "STONE", "PAPER", "GOODS", "TOOLS", "COAL", "FOOD", "FUEL", "FISH", "MEAT", "SAND", "SLAG", "LOGS", "ALCOHOL", "COFFEE"}
        for _, cargo in ipairs(cargoTypes) do
            -- Check for cargo name in line name (case insensitive, also check without underscore)
            local cargoLower = string.lower(cargo)
            local cargoNoUnderscore = string.gsub(cargoLower, "_", " ")
            local nameLower = string.lower(lineName)
            if string.find(nameLower, cargoLower) or string.find(nameLower, cargoNoUnderscore) then
                isCargoLine = true
                lineCargoType = cargo
                log("ADD_VEHICLE: Found cargo type in line name: " .. cargo)
                break
            end
        end

        -- Method 2: Check if it's NOT a passenger line (bus stop names typically have town names)
        if not isCargoLine then
            -- Check if line stops at industries (not towns)
            if line.stops and #line.stops >= 2 then
                local hasIndustryStop = false
                for i, stop in ipairs(line.stops) do
                    if stop.stationGroup then
                        local station = api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION)
                        if station and station.industries and #station.industries > 0 then
                            hasIndustryStop = true
                            log("ADD_VEHICLE: Stop " .. i .. " has industry connection")
                            break
                        end
                    end
                end
                if hasIndustryStop then
                    isCargoLine = true
                    lineCargoType = "COAL" -- Default
                    log("ADD_VEHICLE: Detected cargo line from industry stops")
                end
            end
        end

        -- Method 3: Check line rule cargo (if available)
        if not isCargoLine and line.rule and line.rule.cargo then
            for cargoIdx, enabled in pairs(line.rule.cargo) do
                if enabled then
                    isCargoLine = true
                    lineCargoType = cargoIdx
                    log("ADD_VEHICLE: Found cargo in rule: " .. tostring(cargoIdx))
                    break
                end
            end
        end

        -- Allow explicit cargo_type override from params
        if params.cargo_type then
            isCargoLine = true
            lineCargoType = params.cargo_type
            log("ADD_VEHICLE: Using explicit cargo_type from params: " .. lineCargoType)
        end

        log("ADD_VEHICLE: Line " .. lineId .. " isCargoLine=" .. tostring(isCargoLine) .. " cargoType=" .. tostring(lineCargoType))

        -- Build vehicle config based on carrier type AND cargo/passenger type
        local vehicleConfig
        if carrier == api.type.enum.Carrier.ROAD then
            if isCargoLine then
                -- Build cargo truck with proper params
                local truckParams = {
                    cargoType = lineCargoType or "COAL",  -- Default to COAL if unknown
                    targetThroughput = 25,
                    distance = 1000,
                    preferUniversal = true,  -- Use ALL CARGO trucks
                    useAutoLoadConfig = true
                }
                -- Allow explicit vehicle model filter (e.g. "benz" to get Benz tarp trucks)
                if params.vehicle_model then
                    local modelFilter = string.lower(params.vehicle_model)
                    local universalFilter = vehicleUtil.filterToUniversalTruckWithCargo(truckParams.cargoType, truckParams.minCargoTypes)
                    local filterFn = function(vehicleId, vehicle)
                        if not universalFilter(vehicleId) then return false end
                        local modelName = string.lower(api.res.modelRep.getName(vehicleId) or "")
                        return string.find(modelName, modelFilter) ~= nil
                    end
                    vehicleConfig = vehicleUtil.buildVehicle(truckParams, "truck", filterFn)
                    if vehicleConfig then
                        log("ADD_VEHICLE: Using model filter '" .. params.vehicle_model .. "' for truck")
                    else
                        log("ADD_VEHICLE: WARNING - No truck matching model '" .. params.vehicle_model .. "' found for cargo " .. tostring(truckParams.cargoType) .. ", falling back to default")
                        vehicleConfig = vehicleUtil.buildTruck(truckParams)
                    end
                else
                    vehicleConfig = vehicleUtil.buildTruck(truckParams)
                end
                log("ADD_VEHICLE: Using cargo truck for line " .. lineId .. " cargo=" .. tostring(lineCargoType))
            else
                vehicleConfig = vehicleUtil.buildUrbanBus()
                log("ADD_VEHICLE: Using urban bus for line " .. lineId)
            end
        elseif carrier == api.type.enum.Carrier.RAIL then
            -- Build manual consist: 1 loco + N wagons (matching create_rail_line_with_vehicles)
            local paramHelper = require("ai_builder_base_param_helper")
            local trainCargoType = lineCargoType or "COAL"
            local numWagons = tonumber(params.num_wagons) or 4
            local wagonFilter = params.wagon_type or "gondola"
            local stationLen = tonumber(params.station_length) or 160
            local trainParams = paramHelper.getDefaultRouteBuildingParams(trainCargoType, true, true, stationLen)
            trainParams.isCargo = true
            trainParams.cargoType = trainCargoType
            trainParams.stationLength = stationLen

            -- Find matching wagon
            local allWagons = vehicleUtil.getWaggonsByCargoType(trainCargoType, trainParams)
            local matchedWagon = nil
            for _, w in pairs(allWagons) do
                local modelName = api.res.modelRep.getName(w.modelId) or ""
                if modelName:lower():find(wagonFilter:lower()) then
                    matchedWagon = w
                    break
                end
            end
            if not matchedWagon and #allWagons > 0 then
                matchedWagon = allWagons[1]
            end

            -- Find best loco
            local locoInfo = vehicleUtil.findBestMatchLocomotive(
                vehicleUtil.getStandardTrackSpeed and vehicleUtil.getStandardTrackSpeed() or 80,
                50, vehicleUtil.filterToNonElectricLocomotive, trainParams
            )

            if matchedWagon and locoInfo then
                local loadConfigIdx = vehicleUtil.cargoIdxLookup[matchedWagon.modelId][trainCargoType] - 1
                vehicleConfig = {vehicles = {}, vehicleGroups = {}}
                vehicleConfig.vehicles[1] = {
                    part = {modelId = locoInfo.modelId, loadConfig = {0}, reversed = false},
                    autoLoadConfig = {1}
                }
                vehicleConfig.vehicleGroups[1] = 1
                for i = 1, numWagons do
                    vehicleConfig.vehicles[1 + i] = {
                        part = {modelId = matchedWagon.modelId, loadConfig = {loadConfigIdx}, reversed = false},
                        autoLoadConfig = {1}
                    }
                    vehicleConfig.vehicleGroups[1 + i] = 1
                end
                local wagonName = api.res.modelRep.getName(matchedWagon.modelId) or "?"
                log("ADD_VEHICLE: Built train: 1 loco + " .. numWagons .. "x " .. wagonName)
            else
                -- Fallback to buildMaximumCapacityTrain if no wagon found
                trainParams.stationLength = 160
                vehicleConfig = vehicleUtil.buildMaximumCapacityTrain(trainParams)
                log("ADD_VEHICLE: Fallback to buildMaximumCapacityTrain for " .. trainCargoType)
            end
        elseif carrier == api.type.enum.Carrier.WATER then
            vehicleConfig = vehicleUtil.buildShip({cargoType = lineCargoType, targetThroughput = 50, distance = 2000})
        elseif carrier == api.type.enum.Carrier.AIR then
            vehicleConfig = vehicleUtil.buildPlane({cargoType = lineCargoType, targetThroughput = 25, distance = 5000})
        else
            vehicleConfig = vehicleUtil.buildUrbanBus() -- fallback
        end

        -- Guard: vehicleConfig must not be nil
        if not vehicleConfig then
            return {status = "error", error = "Failed to build vehicle config for line " .. tostring(lineId) .. " cargo=" .. tostring(lineCargoType)}
        end

        -- Queue vehicles for purchase
        for i = 1, count do
            lineManager.addWork(function()
                lineManager.buyVehicleForLine(lineId, i, depotOptions, vehicleConfig)
            end)
        end

        return {status = "ok", data = {
            line_id = tostring(lineId),
            vehicles_queued = tostring(count),
            carrier = carrier == api.type.enum.Carrier.ROAD and "road" or
                      carrier == api.type.enum.Carrier.RAIL and "rail" or
                      carrier == api.type.enum.Carrier.WATER and "water" or "air"
        }}
    end)

    if ok then
        return result
    else
        return {status = "error", message = "Failed to add vehicles: " .. tostring(result)}
    end
end

-- Reassign vehicle to a different line
handlers.reassign_vehicle = function(params)
    if not params or not params.vehicle_id or not params.line_id then
        return {status = "error", message = "Need vehicle_id and line_id parameters"}
    end

    local vehicleId = tonumber(params.vehicle_id)
    local lineId = tonumber(params.line_id)

    -- Use setLine command to reassign vehicle (args: vehicle, line, stopIndex)
    local stopIndex = tonumber(params.stop_index) or 0
    api.cmd.sendCommand(api.cmd.make.setLine(vehicleId, lineId, stopIndex))
    log("Reassigned vehicle " .. tostring(vehicleId) .. " to line " .. tostring(lineId) .. " at stop " .. tostring(stopIndex))

    return {status = "ok", message = "Vehicle reassigned", vehicle_id = tostring(vehicleId), line_id = tostring(lineId)}
end

-- Merge multiple P2P lines into one multi-stop line
-- Takes station IDs from the lines and creates a new combined line
handlers.merge_lines = function(params)
    if not params or not params.line_ids or #params.line_ids < 2 then
        return {status = "error", message = "Need line_ids array with at least 2 line IDs"}
    end

    local util = require "ai_builder_base_util"
    local allStations = {}
    local allVehicles = {}
    local stationsSeen = {}

    -- Collect all stations and vehicles from the lines
    for i, lineIdStr in pairs(params.line_ids) do
        local lineId = tonumber(lineIdStr)
        local line = util.getComponent(lineId, api.type.ComponentType.LINE)

        if line then
            for j, stop in pairs(line.stops) do
                -- Get station from stop using proper API
                local stationGroupComp = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
                if stationGroupComp and stationGroupComp.stations then
                    local stationId = stationGroupComp.stations[stop.station + 1]
                    if stationId and not stationsSeen[stationId] then
                        table.insert(allStations, stationId)
                        stationsSeen[stationId] = true
                    end
                end
            end

            -- Get vehicles for this line
            local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
            for k, vehicleId in pairs(vehicles) do
                table.insert(allVehicles, vehicleId)
            end
        end
    end

    if #allStations < 2 then
        return {status = "error", message = "Not enough unique stations found in lines"}
    end

    -- Create new combined line
    local line = api.type.Line.new()
    for i, stationId in pairs(allStations) do
        local stop = api.type.Line.Stop.new()
        stop.stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)
        -- Get station index within the station group
        local stationGroupComp = util.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
        stop.station = util.indexOf(stationGroupComp.stations, stationId) - 1
        stop.terminal = 0
        line.stops[i] = stop
    end

    local lineName = params.name or ("Combined Line " .. os.time())
    -- Use Vec3f for line color (RGB 0-1)
    local lineColor = api.type.Vec3f.new(math.random(), math.random(), math.random())

    log("Merging " .. #params.line_ids .. " lines into " .. lineName .. " with " .. #allStations .. " stations and " .. #allVehicles .. " vehicles")

    local createCmd = api.cmd.make.createLine(lineName, lineColor, game.interface.getPlayer(), line)
    api.cmd.sendCommand(createCmd, function(res, success)
        if success then
            local newLineId = res.resultEntity
            log("Created merged line " .. tostring(newLineId))

            -- Reassign all vehicles to the new line (use stopIndex 0)
            for i, vehicleId in pairs(allVehicles) do
                api.cmd.sendCommand(api.cmd.make.setLine(vehicleId, newLineId, 0))
            end

            -- Delete the old lines
            for i, lineIdStr in pairs(params.line_ids) do
                local lineId = tonumber(lineIdStr)
                api.cmd.sendCommand(api.cmd.make.deleteLine(lineId))
            end

            log("Merged " .. #allVehicles .. " vehicles and deleted " .. #params.line_ids .. " old lines")
        else
            log("Failed to create merged line")
        end
    end)

    return {status = "ok", message = "Merge initiated", station_count = tostring(#allStations), vehicle_count = tostring(#allVehicles)}
end

-- DELETED: build_rail_connection - was broken (ignored industry IDs)
-- Use build_specific_rail_route instead which supports preSelectedPair

-- Build rail connection between specific industries (bypasses evaluation)
-- Uses preSelectedPair to force buildIndustryRailConnection to use specific industries
-- NEW: Supports cheap mode (single track, terrain-following) by default
-- Params:
--   industry1_id, industry2_id: Required industry IDs
--   double_track: "true" to force double track (default: single track)
--   expensive_mode: "true" to allow expensive construction (default: cheap mode)
--   ignoreErrors: "false" to fail on errors (default: "true")
handlers.build_specific_rail_route = function(params)
    if not params or not params.industry1_id or not params.industry2_id then
        return {status = "error", message = "Need industry1_id and industry2_id"}
    end

    local ind1_id = tonumber(params.industry1_id)
    local ind2_id = tonumber(params.industry2_id)

    if not ind1_id or not ind2_id then
        return {status = "error", message = "Invalid industry IDs (must be numbers)"}
    end

    -- Parse track options (defaults to cheap single track)
    local forceDoubleTrack = params.double_track == "true"
    local expensiveMode = params.expensive_mode == "true"
    local ignore = params.ignoreErrors ~= "false"

    log("BUILD_SPECIFIC_RAIL: " .. ind1_id .. " -> " .. ind2_id ..
        " double_track=" .. tostring(forceDoubleTrack) ..
        " expensive=" .. tostring(expensiveMode))

    -- Use preSelectedPair to force specific industry pair
    local event_params = {
        preSelectedPair = {ind1_id, ind2_id},
        ignoreErrors = ignore,
        -- NEW: Pass track options to buildIndustryRailConnection
        forceDoubleTrack = forceDoubleTrack,
        expensiveMode = expensiveMode
    }

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script", "buildIndustryRailConnection", "", event_params))

    return {status = "ok", data = {
        message = "Rail route build triggered (cheap mode: single track, terrain-following)",
        industry1_id = tostring(ind1_id),
        industry2_id = tostring(ind2_id),
        mode = "RAIL",
        single_track = forceDoubleTrack and "false" or "true",
        cheap_mode = expensiveMode and "false" or "true"
    }}
end

-- Build water/ship connection between industries
-- Uses AI Builder's buildNewWaterConnections which auto-evaluates water routes
handlers.build_water_connection = function(params)
    log("BUILD_WATER: Triggering AI Builder water connection evaluation")

    -- Use the AI Builder's water connection evaluator
    -- It will find the best unconnected water routes and build them
    local event_params = {
        ignoreErrors = false
    }

    api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
        "ai_builder_script", "buildNewWaterConnections", "", event_params))

    return {status = "ok", data = {
        message = "Water connection evaluation triggered",
        mode = "WATER"
    }}
end

-- Build water/ship connection between specific industries (bypasses evaluation)
handlers.build_specific_water_route = function(params)
    if not params or not params.industry1_id or not params.industry2_id then
        return {status = "error", message = "Need industry1_id and industry2_id"}
    end

    local ind1_id = tonumber(params.industry1_id)
    local ind2_id = tonumber(params.industry2_id)

    if not ind1_id or not ind2_id then
        return {status = "error", message = "Invalid industry IDs (must be numbers)"}
    end

    log("BUILD_SPECIFIC_WATER: " .. ind1_id .. " -> " .. ind2_id)

    -- Get industry entities
    local ind1 = game.interface.getEntity(ind1_id)
    local ind2 = game.interface.getEntity(ind2_id)

    if not ind1 then
        return {status = "error", message = "Industry 1 not found: " .. ind1_id}
    end
    if not ind2 then
        return {status = "error", message = "Industry 2 not found: " .. ind2_id}
    end

    ind1.id = ind1_id
    ind2.id = ind2_id

    log("BUILD_SPECIFIC_WATER: " .. tostring(ind1.name) .. " -> " .. tostring(ind2.name))

    -- Create result object with specific industries
    -- buildNewWaterConnections will use these directly instead of evaluating
    local result = {
        industry1 = ind1,
        industry2 = ind2,
        cargoType = params.cargo or "OIL"
    }

    -- Wrap in {result = ...} because event handler expects param.result
    log("BUILD_SPECIFIC_WATER: Sending script event...")
    local ok, err = pcall(function()
        api.cmd.sendCommand(api.cmd.make.sendScriptEvent(
            "ai_builder_script", "buildNewWaterConnections", "", {result = result}))
    end)

    if not ok then
        log("BUILD_SPECIFIC_WATER: ERROR sending event: " .. tostring(err))
        return {status = "error", message = "Failed to send script event: " .. tostring(err)}
    end

    log("BUILD_SPECIFIC_WATER: Script event sent successfully")

    return {status = "ok", data = {
        message = "Water route build triggered for specific industries",
        industry1 = ind1.name,
        industry2 = ind2.name,
        mode = "WATER"
    }}
end

-- ============================================================================
-- SUPPLY CHAIN STRATEGY SYSTEM
-- Evaluates complete supply chains from town demands backward through all
-- production tiers, with profitability analysis and multi-round planning.
-- ============================================================================

-- Cargo values per unit (approximate, scaled for year 1850-1900)
local CARGO_VALUES = {
    FOOD = 150,
    GOODS = 250,
    MACHINES = 280,
    TOOLS = 200,
    FUEL = 180,
    CONSTRUCTION_MATERIALS = 160,
    GRAIN = 80,
    LOGS = 60,
    PLANKS = 100,
    COAL = 70,
    IRON_ORE = 75,
    STEEL = 150,
    OIL = 120,
    STONE = 50,
    LIVESTOCK = 100
}

-- Supply chain definitions: what's needed to produce each final cargo
-- Each chain shows phases from raw material -> intermediate -> final product -> town
local CHAIN_DEFINITIONS = {
    FOOD = {
        description = "Farm produces GRAIN, Food Processing converts to FOOD",
        phases = {
            {producer_types = {"farm"}, cargo_out = "GRAIN", cargo_in = nil},
            {producer_types = {"food_processing_plant", "food"}, cargo_out = "FOOD", cargo_in = "GRAIN", delivers_to = "TOWN"}
        }
    },
    GOODS = {
        description = "Forest produces LOGS, Sawmill makes PLANKS, Goods Factory makes GOODS",
        phases = {
            {producer_types = {"forest"}, cargo_out = "LOGS", cargo_in = nil},
            {producer_types = {"saw_mill", "sawmill"}, cargo_out = "PLANKS", cargo_in = "LOGS"},
            {producer_types = {"goods_factory", "goods"}, cargo_out = "GOODS", cargo_in = "PLANKS", delivers_to = "TOWN"}
        }
    },
    TOOLS = {
        description = "Forest produces LOGS, Sawmill makes PLANKS, Tools Factory makes TOOLS",
        phases = {
            {producer_types = {"forest"}, cargo_out = "LOGS", cargo_in = nil},
            {producer_types = {"saw_mill", "sawmill"}, cargo_out = "PLANKS", cargo_in = "LOGS"},
            {producer_types = {"tool_factory", "tools"}, cargo_out = "TOOLS", cargo_in = "PLANKS", delivers_to = "TOWN"}
        }
    },
    MACHINES = {
        description = "Iron Mine + Coal Mine -> Steel Mill -> Machine Factory",
        phases = {
            {producer_types = {"iron_ore_mine", "iron"}, cargo_out = "IRON_ORE", cargo_in = nil},
            {producer_types = {"coal_mine", "coal"}, cargo_out = "COAL", cargo_in = nil},
            {producer_types = {"steel_mill", "steel"}, cargo_out = "STEEL", cargo_in = "IRON_ORE,COAL"},
            {producer_types = {"machine_factory", "machines"}, cargo_out = "MACHINES", cargo_in = "STEEL", delivers_to = "TOWN"}
        }
    },
    FUEL = {
        description = "Oil Well produces OIL, Oil Refinery OR Fuel Refinery makes FUEL",
        phases = {
            {producer_types = {"oil_well"}, cargo_out = "OIL", cargo_in = nil},
            {producer_types = {"oil_refinery", "fuel_refinery"}, cargo_out = "FUEL", cargo_in = "OIL", delivers_to = "TOWN"}
        }
    },
    CONSTRUCTION_MATERIALS = {
        description = "Quarry produces STONE, processed to CONSTRUCTION_MATERIALS",
        phases = {
            {producer_types = {"quarry", "stone"}, cargo_out = "STONE", cargo_in = nil},
            {producer_types = {"building_materials", "construction"}, cargo_out = "CONSTRUCTION_MATERIALS", cargo_in = "STONE", delivers_to = "TOWN"}
        }
    }
}

-- Transport mode characteristics
-- ROAD: Low setup cost, low capacity, good for short distances (<3km)
-- RAIL: High setup cost, high capacity, good for medium-long distances (3-15km)
-- WATER: Medium setup cost, very high capacity, requires water access, good for bulk/long distance
local TRANSPORT_MODES = {
    ROAD = {
        cost_per_km = 40000,      -- Road + truck stations
        station_cost = 100000,    -- Truck stop
        capacity_per_vehicle = 20, -- Cargo units per truck
        maintenance_rate = 0.005, -- 0.5% of build cost per month
        speed_factor = 1.0,       -- Base speed
        min_efficient_dist = 0,   -- Good for any distance
        max_efficient_dist = 5000 -- Less efficient beyond 5km
    },
    RAIL = {
        cost_per_km = 120000,     -- Track + signaling
        station_cost = 400000,    -- Freight station
        capacity_per_vehicle = 100, -- Cargo units per train
        maintenance_rate = 0.003, -- 0.3% (more efficient at scale)
        speed_factor = 2.0,       -- Faster than trucks
        min_efficient_dist = 3000, -- Needs distance to justify setup
        max_efficient_dist = 50000 -- Efficient for long hauls
    },
    WATER = {
        cost_per_km = 20000,      -- Just dredging/buoys (water is free)
        station_cost = 300000,    -- Harbor/dock
        capacity_per_vehicle = 200, -- Cargo units per ship
        maintenance_rate = 0.004, -- 0.4%
        speed_factor = 0.8,       -- Slower than trucks
        min_efficient_dist = 2000, -- Needs some distance
        max_efficient_dist = 100000, -- Very efficient for long hauls
        requires_water = true     -- Must have water access
    }
}

-- Check if a position is near water (simplified - checks if near coast/river)
local function has_water_access(position, water_bodies)
    if not position then return false end
    -- Check if any water body is within 500m
    for _, water in ipairs(water_bodies or {}) do
        local dist = calc_distance(position, water.position)
        if dist < 500 then
            return true
        end
    end
    return false
end

-- Estimate profitability of a supply chain route for a specific transport mode
local function estimate_profitability(cargo, distance_m, monthly_demand, year, transport_mode)
    year = year or 1850
    transport_mode = transport_mode or "ROAD"
    local mode = TRANSPORT_MODES[transport_mode] or TRANSPORT_MODES.ROAD

    local distance_km = distance_m / 1000

    -- Build costs scale with year (earlier = cheaper but slower vehicles)
    local era_multiplier = 1.0
    if year < 1880 then era_multiplier = 0.8
    elseif year < 1920 then era_multiplier = 1.0
    elseif year < 1960 then era_multiplier = 1.5
    else era_multiplier = 2.0 end

    -- Calculate infrastructure cost based on mode
    local cost_per_km = mode.cost_per_km * era_multiplier
    local station_cost = mode.station_cost * era_multiplier

    local build_cost = distance_km * cost_per_km + station_cost * 2  -- 2 stations per segment

    -- Revenue based on cargo value and demand
    local cargo_value = CARGO_VALUES[cargo] or 100

    -- Capacity depends on transport mode
    local transported = math.min(monthly_demand, mode.capacity_per_vehicle * 2.5)  -- ~2.5 trips/month
    local monthly_revenue = transported * cargo_value

    -- Operating costs (maintenance scales with mode efficiency)
    local monthly_cost = build_cost * mode.maintenance_rate

    local monthly_profit = monthly_revenue - monthly_cost
    local annual_roi = 0
    local payback_months = 999

    if build_cost > 0 and monthly_profit > 0 then
        annual_roi = (monthly_profit * 12) / build_cost * 100
        payback_months = build_cost / monthly_profit
    end

    -- Calculate efficiency score based on distance vs mode characteristics
    local efficiency = 1.0
    if distance_m < mode.min_efficient_dist then
        efficiency = distance_m / mode.min_efficient_dist  -- Penalty for too short
    elseif distance_m > mode.max_efficient_dist then
        efficiency = mode.max_efficient_dist / distance_m  -- Penalty for too long
    end

    return {
        build_cost = math.floor(build_cost),
        monthly_revenue = math.floor(monthly_revenue),
        monthly_cost = math.floor(monthly_cost),
        monthly_profit = math.floor(monthly_profit),
        annual_roi = math.floor(annual_roi * efficiency * 10) / 10,  -- Adjusted by efficiency
        payback_months = math.floor(payback_months),
        efficiency = math.floor(efficiency * 100),
        transport_mode = transport_mode
    }
end

-- Evaluate all transport modes and return the best one
local function find_best_transport_mode(cargo, distance_m, monthly_demand, year, has_water)
    local best_mode = "ROAD"
    local best_roi = -999
    local all_modes = {}

    for mode_name, mode_config in pairs(TRANSPORT_MODES) do
        -- Skip water if no water access
        if mode_name == "WATER" and not has_water then
            -- Skip
        else
            local profit = estimate_profitability(cargo, distance_m, monthly_demand, year, mode_name)
            all_modes[mode_name] = profit

            if profit.annual_roi > best_roi then
                best_roi = profit.annual_roi
                best_mode = mode_name
            end
        end
    end

    return best_mode, all_modes
end

-- Calculate distance between two positions
local function calc_distance(pos1, pos2)
    if not pos1 or not pos2 then return 999999 end
    local x1 = pos1[1] or pos1.x or 0
    local y1 = pos1[2] or pos1.y or 0
    local x2 = pos2[1] or pos2.x or 0
    local y2 = pos2[2] or pos2.y or 0
    return math.sqrt((x2-x1)^2 + (y2-y1)^2)
end

-- Check if industry type matches any of the producer_types
local function matches_producer_type(industry_type, producer_types)
    if not industry_type then return false end
    local lower_type = industry_type:lower()
    for _, pt in ipairs(producer_types) do
        if lower_type:find(pt:lower()) then
            return true
        end
    end
    return false
end

-- Evaluate all possible supply chains based on town demands
-- Now evaluates ROAD, RAIL, and WATER transport modes
handlers.evaluate_supply_chains = function(params)
    log("EVALUATE_SUPPLY_CHAINS: Starting multi-mode evaluation")

    -- Get current budget
    local player = game.interface.getPlayer()
    local playerEntity = player and game.interface.getEntity(player) or nil
    local current_money = playerEntity and playerEntity.balance or 0
    local budget = tonumber(params and params.budget) or (current_money * 0.3)  -- Default to 30% of funds

    -- Get current year
    local gameTime = game.interface.getGameTime()
    local year = (gameTime and gameTime.date and gameTime.date.year) or 1850

    -- Get all towns with demands
    local allTowns = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})

    -- Get all industries
    local allIndustries = game.interface.getEntities({radius=1e9}, {type="SIM_BUILDING", includeData=true})

    -- Collect water body positions (oil wells, refineries near water, harbors)
    -- For simplicity, assume industries with "oil", "harbor", "port", "dock" in name have water access
    local water_industries = {}

    -- Index industries by type for fast lookup
    local industries_by_type = {}
    local industry_list = {}
    for id, industry in pairs(allIndustries) do
        if industry.itemsProduced or industry.itemsConsumed then
            local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(id)
            local construction = constructionId and constructionId > 0 and game.interface.getEntity(constructionId) or nil
            local fileName = construction and construction.fileName or ""
            local industry_type = fileName:match("industry/(.-)%.") or "unknown"
            local name_lower = (industry.name or ""):lower()

            -- Check for water access indicators
            local has_water = name_lower:find("oil") or name_lower:find("harbor") or
                              name_lower:find("port") or name_lower:find("dock") or
                              name_lower:find("refinery") or industry_type:find("oil")

            local ind_data = {
                id = id,
                name = industry.name or "Unknown",
                type = industry_type,
                position = industry.position or (construction and construction.position) or {0, 0, 0},
                produces = industry.itemsProduced or {},
                consumes = industry.itemsConsumed or {},
                has_water_access = has_water
            }

            table.insert(industry_list, ind_data)

            if has_water then
                table.insert(water_industries, ind_data)
            end

            -- Index by type
            if not industries_by_type[industry_type] then
                industries_by_type[industry_type] = {}
            end
            table.insert(industries_by_type[industry_type], ind_data)
        end
    end

    log("EVALUATE_SUPPLY_CHAINS: Found " .. #industry_list .. " industries, " .. #water_industries .. " with water access")

    -- Collect all supply chain opportunities
    local chains = {}
    local chain_count = 0

    for townId, town in pairs(allTowns) do
        local townPos = town.position or {0, 0, 0}
        local townName = town.name or "Unknown"

        -- Check if town has water access (near any water industry)
        local town_has_water = false
        for _, wi in ipairs(water_industries) do
            if calc_distance(townPos, wi.position) < 3000 then
                town_has_water = true
                break
            end
        end

        -- Get actual cargo demands for this town
        local ok, cargoSupplyAndLimit = pcall(function()
            return game.interface.getTownCargoSupplyAndLimit(townId)
        end)

        if ok and cargoSupplyAndLimit then
            for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do
                local supply = supplyAndLimit[1] or 0
                local limit = supplyAndLimit[2] or 0
                local demand = math.max(0, limit - supply)

                if demand > 5 then  -- Only consider meaningful demands
                    local chain_def = CHAIN_DEFINITIONS[cargoName]

                    if chain_def then
                        -- Find industries that can produce the final cargo
                        local final_phase = chain_def.phases[#chain_def.phases]

                        for _, ind in ipairs(industry_list) do
                            if matches_producer_type(ind.type, final_phase.producer_types) then
                                -- Found a potential final producer
                                local distance = calc_distance(ind.position, townPos)

                                -- Check water access for this route
                                local route_has_water = ind.has_water_access and town_has_water

                                -- Find best transport mode for final leg
                                local best_mode, all_modes = find_best_transport_mode(
                                    cargoName, distance, demand, year, route_has_water)

                                -- Calculate profitability for the final leg with best mode
                                local profit = estimate_profitability(cargoName, distance, demand, year, best_mode)

                                -- Build the full phase list with actual industry candidates
                                local phases = {}
                                local total_distance = distance
                                local total_cost_road = 0
                                local total_cost_rail = 0
                                local total_cost_best = profit.build_cost
                                local valid_chain = true
                                local chain_has_water = route_has_water

                                -- Work backward through the chain phases
                                local current_pos = ind.position
                                local current_ind = ind

                                for phase_idx = #chain_def.phases, 1, -1 do
                                    local phase = chain_def.phases[phase_idx]

                                    if phase_idx == #chain_def.phases then
                                        -- Final phase: industry -> town
                                        -- Calculate costs for all modes
                                        local road_profit = estimate_profitability(cargoName, distance, demand, year, "ROAD")
                                        local rail_profit = estimate_profitability(cargoName, distance, demand, year, "RAIL")

                                        total_cost_road = total_cost_road + road_profit.build_cost
                                        total_cost_rail = total_cost_rail + rail_profit.build_cost

                                        table.insert(phases, 1, {
                                            from = ind.name,
                                            from_id = tostring(ind.id),
                                            from_type = ind.type,
                                            to = townName,
                                            to_id = tostring(townId),
                                            cargo = cargoName,
                                            distance = tostring(math.floor(distance)),
                                            is_town_delivery = "true",
                                            best_mode = best_mode,
                                            road_cost = tostring(road_profit.build_cost),
                                            rail_cost = tostring(rail_profit.build_cost),
                                            water_available = route_has_water and "true" or "false"
                                        })
                                    else
                                        -- Find nearest source industry for this phase
                                        local best_source = nil
                                        local best_dist = 1e9

                                        for _, source_ind in ipairs(industry_list) do
                                            if matches_producer_type(source_ind.type, phase.producer_types) then
                                                local dist = calc_distance(source_ind.position, current_pos)
                                                if dist < best_dist then
                                                    best_dist = dist
                                                    best_source = source_ind
                                                end
                                            end
                                        end

                                        if best_source then
                                            -- Check water access for this leg
                                            local leg_has_water = best_source.has_water_access and current_ind.has_water_access

                                            -- Find best mode for this leg
                                            local leg_best_mode, _ = find_best_transport_mode(
                                                phase.cargo_out, best_dist, demand, year, leg_has_water)

                                            local phase_profit = estimate_profitability(
                                                phase.cargo_out, best_dist, demand, year, leg_best_mode)
                                            local road_profit = estimate_profitability(
                                                phase.cargo_out, best_dist, demand, year, "ROAD")
                                            local rail_profit = estimate_profitability(
                                                phase.cargo_out, best_dist, demand, year, "RAIL")

                                            total_cost_road = total_cost_road + road_profit.build_cost
                                            total_cost_rail = total_cost_rail + rail_profit.build_cost
                                            total_cost_best = total_cost_best + phase_profit.build_cost

                                            table.insert(phases, 1, {
                                                from = best_source.name,
                                                from_id = tostring(best_source.id),
                                                from_type = best_source.type,
                                                to = current_ind.name,
                                                to_id = tostring(current_ind.id),
                                                cargo = phase.cargo_out,
                                                distance = tostring(math.floor(best_dist)),
                                                best_mode = leg_best_mode,
                                                road_cost = tostring(road_profit.build_cost),
                                                rail_cost = tostring(rail_profit.build_cost),
                                                water_available = leg_has_water and "true" or "false"
                                            })

                                            total_distance = total_distance + best_dist
                                            current_pos = best_source.position
                                            current_ind = best_source

                                            if leg_has_water then chain_has_water = true end
                                        else
                                            valid_chain = false
                                            break
                                        end
                                    end
                                end

                                if valid_chain and #phases > 0 then
                                    -- Calculate ROI for each transport strategy
                                    local function calc_roi(total_cost, monthly_rev)
                                        local monthly_cost = total_cost * 0.004  -- Average maintenance
                                        local monthly_profit = monthly_rev - monthly_cost
                                        if total_cost > 0 and monthly_profit > 0 then
                                            return (monthly_profit * 12) / total_cost * 100
                                        end
                                        return 0
                                    end

                                    local roi_road = calc_roi(total_cost_road, profit.monthly_revenue)
                                    local roi_rail = calc_roi(total_cost_rail, profit.monthly_revenue)
                                    local roi_best = calc_roi(total_cost_best, profit.monthly_revenue)

                                    -- Determine overall best mode based on distance and demand
                                    local recommended_mode = "ROAD"
                                    local recommended_cost = total_cost_road
                                    local best_roi = roi_road

                                    if total_distance > 5000 and demand > 30 then
                                        -- Rail better for long distance + high demand
                                        if roi_rail > roi_road * 0.8 then  -- Rail within 20% is worth it for capacity
                                            recommended_mode = "RAIL"
                                            recommended_cost = total_cost_rail
                                            best_roi = roi_rail
                                        end
                                    end

                                    if chain_has_water and total_distance > 3000 and
                                       (cargoName == "FUEL" or cargoName == "CRUDE" or cargoName == "OIL") then
                                        recommended_mode = "WATER"
                                        -- Water cost estimated
                                        recommended_cost = total_cost_road * 0.6  -- Water is cheaper
                                        best_roi = roi_road * 1.3
                                    end

                                    chain_count = chain_count + 1

                                    -- Generate recommendation
                                    local recommendation = "SKIP - Low ROI"
                                    if best_roi > 50 then
                                        recommendation = "BUILD " .. recommended_mode .. " - Excellent ROI"
                                    elseif best_roi > 25 then
                                        recommendation = "BUILD " .. recommended_mode .. " - Good ROI"
                                    elseif best_roi > 10 then
                                        recommendation = "CONSIDER " .. recommended_mode .. " - Moderate ROI"
                                    elseif best_roi > 5 then
                                        recommendation = "MARGINAL " .. recommended_mode .. " - Low ROI"
                                    end

                                    if recommended_cost > budget then
                                        recommendation = "DEFER - Over budget (" .. recommended_mode .. ")"
                                    end

                                    table.insert(chains, {
                                        town = townName,
                                        town_id = tostring(townId),
                                        cargo = cargoName,
                                        demand = tostring(demand),
                                        phases = phases,
                                        phase_count = tostring(#phases),
                                        total_distance = tostring(math.floor(total_distance)),
                                        -- Transport mode comparison
                                        recommended_mode = recommended_mode,
                                        estimated_cost = tostring(math.floor(recommended_cost)),
                                        road_cost = tostring(math.floor(total_cost_road)),
                                        rail_cost = tostring(math.floor(total_cost_rail)),
                                        water_available = chain_has_water and "true" or "false",
                                        -- ROI comparison
                                        estimated_monthly_revenue = tostring(math.floor(profit.monthly_revenue)),
                                        roi_annual = tostring(math.floor(best_roi * 10) / 10) .. "%",
                                        roi_road = tostring(math.floor(roi_road * 10) / 10) .. "%",
                                        roi_rail = tostring(math.floor(roi_rail * 10) / 10) .. "%",
                                        priority = best_roi,  -- Used for sorting
                                        recommendation = recommendation
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Sort by ROI (highest first)
    table.sort(chains, function(a, b) return (a.priority or 0) > (b.priority or 0) end)

    -- Convert priority to rank and make it a string
    for i, chain in ipairs(chains) do
        chain.priority = tostring(i)
    end

    -- Count affordable chains
    local affordable_count = 0
    local remaining = budget
    for _, chain in ipairs(chains) do
        local cost = tonumber(chain.estimated_cost) or 0
        if cost <= remaining then
            affordable_count = affordable_count + 1
            remaining = remaining - cost
        end
    end

    log("EVALUATE_SUPPLY_CHAINS: Found " .. #chains .. " potential chains, " .. affordable_count .. " affordable")

    return {
        status = "ok",
        data = {
            chains = chains,
            budget = tostring(math.floor(budget)),
            current_money = tostring(math.floor(current_money)),
            affordable_chains = tostring(affordable_count),
            year = tostring(year),
            industry_count = tostring(#industry_list),
            water_access_industries = tostring(#water_industries),
            transport_modes = "ROAD,RAIL,WATER"
        }
    }
end

-- Plan a multi-round build strategy based on budget
handlers.plan_build_strategy = function(params)
    log("PLAN_BUILD_STRATEGY: Starting planning")

    -- Get current budget
    local player = game.interface.getPlayer()
    local playerEntity = player and game.interface.getEntity(player) or nil
    local current_money = playerEntity and playerEntity.balance or 0

    local budget = tonumber(params and params.budget) or (current_money * 0.3)
    local rounds = tonumber(params and params.rounds) or 3
    local min_roi = tonumber(params and params.min_roi) or 10  -- Minimum ROI% to consider

    -- Get all chain candidates
    local eval_result = handlers.evaluate_supply_chains({budget = tostring(budget * rounds)})

    if eval_result.status ~= "ok" then
        return eval_result
    end

    local chains = eval_result.data.chains

    -- Filter chains by minimum ROI
    local viable_chains = {}
    for _, chain in ipairs(chains) do
        local roi = tonumber(chain.roi_annual:match("([%d%.]+)")) or 0
        if roi >= min_roi then
            table.insert(viable_chains, chain)
        end
    end

    -- Allocate chains to rounds
    local plan = {}
    local remaining_budget = budget
    local planned_chains = {}

    for round = 1, rounds do
        plan[round] = {
            round = tostring(round),
            routes = {},
            total_cost = 0,
            expected_revenue = 0
        }

        for _, chain in ipairs(viable_chains) do
            if not planned_chains[chain] then
                local cost = tonumber(chain.estimated_cost) or 0
                local revenue = tonumber(chain.estimated_monthly_revenue) or 0

                if cost <= remaining_budget then
                    table.insert(plan[round].routes, {
                        town = chain.town,
                        town_id = chain.town_id,
                        cargo = chain.cargo,
                        phases = chain.phases,
                        cost = chain.estimated_cost,
                        roi = chain.roi_annual,
                        transport_mode = chain.recommended_mode or "ROAD"
                    })
                    plan[round].total_cost = plan[round].total_cost + cost
                    plan[round].expected_revenue = plan[round].expected_revenue + revenue
                    remaining_budget = remaining_budget - cost
                    planned_chains[chain] = true
                end
            end
        end

        -- Convert numbers to strings for TF2
        plan[round].total_cost = tostring(math.floor(plan[round].total_cost))
        plan[round].expected_revenue = tostring(math.floor(plan[round].expected_revenue))
        plan[round].route_count = tostring(#plan[round].routes)

        -- After first round, assume some revenue comes in (simplified model)
        if round < rounds then
            remaining_budget = remaining_budget + (plan[round].expected_revenue * 3)  -- 3 months of revenue
        end
    end

    -- Calculate total planned
    local total_planned_cost = 0
    local total_planned_routes = 0
    for _, round_plan in ipairs(plan) do
        total_planned_cost = total_planned_cost + tonumber(round_plan.total_cost)
        total_planned_routes = total_planned_routes + #round_plan.routes
    end

    log("PLAN_BUILD_STRATEGY: Created " .. rounds .. "-round plan with " .. total_planned_routes .. " routes")

    return {
        status = "ok",
        data = {
            plan = plan,
            rounds = tostring(rounds),
            initial_budget = tostring(math.floor(budget)),
            total_planned_cost = tostring(math.floor(total_planned_cost)),
            total_routes = tostring(total_planned_routes),
            unplanned_viable = tostring(#viable_chains - total_planned_routes)
        }
    }
end

-- Build a rail station near an industry at a specific offset
-- Ported from rail.py station() function
handlers.build_rail_station = function(params)
    if not params or not params.industry_id then
        return {status = "error", message = "Need industry_id parameter"}
    end

    local industryId = tonumber(params.industry_id)
    if not industryId then
        return {status = "error", message = "Invalid industry_id"}
    end

    local stationName = params.name or "Rail Station"
    local stationDist = tonumber(params.distance) or 20

    log("BUILD_RAIL_STATION: industry=" .. industryId .. " distance=" .. stationDist)

    local ok, result = pcall(function()
        local util = require("ai_builder_base_util")
        local helper = require("ai_builder_station_template_helper")
        local transf = require("transf")
        local vec3 = require("vec3")

        local factoryId = industryId
        local conId = nil

        -- Check if input is a construction ID (has CONSTRUCTION component)
        local testCon = api.engine.getComponent(industryId, api.type.ComponentType.CONSTRUCTION)
        if testCon then
            conId = industryId
            if testCon.simBuildings and #testCon.simBuildings > 0 then
                factoryId = testCon.simBuildings[1]
            end
        else
            conId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(factoryId)
        end

        if not conId then return {status = "error", message = "Invalid industry ID"} end

        local con = api.engine.getComponent(conId, api.type.ComponentType.CONSTRUCTION)
        if not con then return {status = "error", message = "Could not get construction"} end

        local industryPos = con.transf:cols(3)

        -- Find road connected to industry for orientation
        util.clearCacheNode2SegMaps()
        util.lazyCacheNode2SegMaps()
        local industry = {id = factoryId, position = {industryPos[1], industryPos[2], industryPos[3]}}
        local edge = util.findEdgeForIndustry(industry, 300)

        local stationPos, stationAngle

        if edge then
            -- Calculate road tangent
            local node0Pos = util.nodePos(edge.node0)
            local node1Pos = util.nodePos(edge.node1)
            local roadTangentX = node1Pos.x - node0Pos.x
            local roadTangentY = node1Pos.y - node0Pos.y
            local roadLen = math.sqrt(roadTangentX * roadTangentX + roadTangentY * roadTangentY)
            local roadAngle = math.atan2(roadTangentY, roadTangentX)

            -- Perpendicular unit vector
            local perpX = -roadTangentY / roadLen
            local perpY = roadTangentX / roadLen

            -- Road midpoint
            local roadMidX = (node0Pos.x + node1Pos.x) / 2
            local roadMidY = (node0Pos.y + node1Pos.y) / 2

            -- Which side of road is industry on?
            local industryDot = (industryPos[1] - roadMidX) * perpX + (industryPos[2] - roadMidY) * perpY

            -- Station goes on OPPOSITE side of road from industry
            local sideSign = industryDot > 0 and -1 or 1
            local stationX = roadMidX + sideSign * perpX * stationDist
            local stationY = roadMidY + sideSign * perpY * stationDist
            stationPos = vec3.new(stationX, stationY, industryPos[3])

            -- Orient tracks parallel to road, building faces toward the road
            -- TF2 modular stations: building is on LEFT side of tracks (+90 from track direction)
            -- We want building between tracks and road (facing toward road/industry)
            local toRoadAngle = math.atan2(roadMidY - stationY, roadMidX - stationX)

            -- Two track orientations parallel to road: roadAngle or roadAngle + pi
            local buildingFace1 = roadAngle + math.pi / 2
            local buildingFace2 = roadAngle - math.pi / 2

            -- Pick orientation where building face is closest to toRoadAngle
            local diff1 = math.abs(math.atan2(math.sin(buildingFace1 - toRoadAngle), math.cos(buildingFace1 - toRoadAngle)))
            local diff2 = math.abs(math.atan2(math.sin(buildingFace2 - toRoadAngle), math.cos(buildingFace2 - toRoadAngle)))

            if diff1 < diff2 then
                stationAngle = roadAngle
            else
                stationAngle = roadAngle + math.pi
            end
            -- Rotate 90 deg clockwise so tracks run parallel to road
            stationAngle = stationAngle - math.pi / 2

            log("BUILD_RAIL_STATION: road angle=" .. string.format("%.2f", math.deg(roadAngle)) ..
                " station angle=" .. string.format("%.2f", math.deg(stationAngle)) ..
                " side=" .. sideSign ..
                " pos=(" .. string.format("%.0f", stationX) .. "," .. string.format("%.0f", stationY) .. ")")
        else
            -- Fallback: simple offset from industry
            local offsetX = tonumber(params.offset_x) or 100
            local offsetY = tonumber(params.offset_y) or 0
            stationPos = vec3.new(industryPos[1] + offsetX, industryPos[2] + offsetY, industryPos[3])
            stationAngle = 0
            log("BUILD_RAIL_STATION: no road found, using fallback offset=(" .. offsetX .. "," .. offsetY .. ")")
        end

        -- Pass-through station (templateIndex=6), not terminus
        local stationParams = {
            catenary = 0, length = 1, paramX = 0, paramY = 0, seed = 0,
            templateIndex = 6, trackType = 0, tracks = 0,
            year = game.interface.getGameTime().date.year
        }
        stationParams.modules = util.setupModuleDetailsForTemplate(helper.createTemplateFn(stationParams))

        local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
        newConstruction.fileName = "station/rail/modular_station/modular_station.con"
        newConstruction.name = stationName
        newConstruction.playerEntity = api.engine.util.getPlayer()
        newConstruction.params = stationParams
        newConstruction.transf = util.transf2Mat4f(transf.rotZTransl(stationAngle, stationPos))

        local newProposal = api.type.SimpleProposal.new()
        newProposal.constructionsToAdd[1] = newConstruction
        local context = util.initContext()
        local cmd = api.cmd.make.buildProposal(newProposal, context, true)

        api.cmd.sendCommand(cmd)

        return {status = "ok", data = {
            message = "Rail station '" .. stationName .. "' build initiated (parallel to road, building facing road)",
            industry_id = tostring(industryId),
            position_x = tostring(stationPos[1]),
            position_y = tostring(stationPos[2]),
            station_angle_deg = tostring(string.format("%.1f", math.deg(stationAngle)))
        }}
    end)

    if ok then return result end
    return {status = "error", message = "build_rail_station failed: " .. tostring(result)}
end

-- Build rail track between two station constructions
-- Ported from rail.py route() function
handlers.build_rail_track = function(params)
    -- Accept either station names OR industry IDs to locate rail stations
    if not params then
        return {status = "error", message = "Need station1_name/station2_name or industry1_id/industry2_id"}
    end

    local name1 = params.station1_name
    local name2 = params.station2_name
    local ind1 = tonumber(params.industry1_id)
    local ind2 = tonumber(params.industry2_id)

    if not (name1 and name2) and not (ind1 and ind2) then
        return {status = "error", message = "Need station1_name/station2_name or industry1_id/industry2_id"}
    end

    log("BUILD_RAIL_TRACK: " .. tostring(name1 or ind1) .. " -> " .. tostring(name2 or ind2))

    local ok, result = pcall(function()
        local routeBuilder = require("ai_builder_route_builder")
        local proposalUtil = require("ai_builder_proposal_util")
        local paramHelper = require("ai_builder_base_param_helper")
        local util = require("ai_builder_base_util")
        local vec3 = require("vec3")

        util.clearCacheNode2SegMaps()
        util.lazyCacheNode2SegMaps()

        -- Find rail station constructions
        local con1, con2 = nil, nil

        if ind1 and ind2 then
            -- Find rail stations nearest to each industry
            local function getIndustryPos(indId)
                local conId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(indId)
                if conId then
                    local conComp = api.engine.getComponent(conId, api.type.ComponentType.CONSTRUCTION)
                    if conComp then
                        local pos = conComp.transf:cols(3)
                        return {x = pos[1], y = pos[2], z = pos[3]}
                    end
                end
                return nil
            end

            local indPos1 = getIndustryPos(ind1)
            local indPos2 = getIndustryPos(ind2)
            if not indPos1 then return {status = "error", message = "Industry " .. ind1 .. " not found"} end
            if not indPos2 then return {status = "error", message = "Industry " .. ind2 .. " not found"} end

            log("BUILD_RAIL_TRACK: ind1 pos=(" .. string.format("%.0f,%.0f", indPos1.x, indPos1.y) .. ")")
            log("BUILD_RAIL_TRACK: ind2 pos=(" .. string.format("%.0f,%.0f", indPos2.x, indPos2.y) .. ")")

            -- Find all rail station constructions
            local railStations = {}
            for id = 1, 60000 do
                if api.engine.entityExists(id) then
                    local conComp = api.engine.getComponent(id, api.type.ComponentType.CONSTRUCTION)
                    if conComp and conComp.fileName and string.find(conComp.fileName, "rail") and conComp.stations and #conComp.stations > 0 then
                        local pos = conComp.transf:cols(3)
                        table.insert(railStations, {id = id, x = pos[1], y = pos[2], z = pos[3]})
                        log("BUILD_RAIL_TRACK: Found rail station con=" .. id .. " pos=(" .. string.format("%.0f,%.0f", pos[1], pos[2]) .. ")")
                    end
                end
            end

            -- Find closest rail station to each industry
            local bestDist1, bestDist2 = math.huge, math.huge
            for _, rs in ipairs(railStations) do
                local d1 = math.sqrt((rs.x - indPos1.x)^2 + (rs.y - indPos1.y)^2)
                local d2 = math.sqrt((rs.x - indPos2.x)^2 + (rs.y - indPos2.y)^2)
                if d1 < bestDist1 then bestDist1 = d1; con1 = rs.id end
                if d2 < bestDist2 then bestDist2 = d2; con2 = rs.id end
            end

            if not con1 then return {status = "error", message = "No rail station near industry " .. ind1} end
            if not con2 then return {status = "error", message = "No rail station near industry " .. ind2} end
            if con1 == con2 then return {status = "error", message = "Both industries map to same station " .. con1} end
            log("BUILD_RAIL_TRACK: Matched con1=" .. con1 .. " (dist=" .. string.format("%.0f", bestDist1) .. ") con2=" .. con2 .. " (dist=" .. string.format("%.0f", bestDist2) .. ")")
        else
            -- Find by name
            for id = 1, 60000 do
                if api.engine.entityExists(id) then
                    local nameComp = api.engine.getComponent(id, api.type.ComponentType.NAME)
                    if nameComp and nameComp.name then
                        local conComp = api.engine.getComponent(id, api.type.ComponentType.CONSTRUCTION)
                        if conComp and conComp.stations and #conComp.stations > 0 then
                            if nameComp.name == name1 then con1 = id end
                            if nameComp.name == name2 then con2 = id end
                        end
                    end
                end
                if con1 and con2 then break end
            end
            if not con1 then return {status = "error", message = "Station '" .. name1 .. "' not found"} end
            if not con2 then return {status = "error", message = "Station '" .. name2 .. "' not found"} end
        end

        -- Get station IDs from construction entities for buildRouteBetweenStations
        local conComp1 = api.engine.getComponent(con1, api.type.ComponentType.CONSTRUCTION)
        local conComp2 = api.engine.getComponent(con2, api.type.ComponentType.CONSTRUCTION)

        if not conComp1 or not conComp1.stations or #conComp1.stations == 0 then
            return {status = "error", message = "Construction " .. con1 .. " has no station component"}
        end
        if not conComp2 or not conComp2.stations or #conComp2.stations == 0 then
            return {status = "error", message = "Construction " .. con2 .. " has no station component"}
        end

        local station1 = conComp1.stations[1]
        local station2 = conComp2.stations[1]
        log("BUILD_RAIL_TRACK: con1=" .. con1 .. " station1=" .. station1 .. " con2=" .. con2 .. " station2=" .. station2)

        -- Get positions for distance calculation
        local pos1 = conComp1.transf:cols(3)
        local pos2 = conComp2.transf:cols(3)
        local dx = pos2[1] - pos1[1]
        local dy = pos2[2] - pos1[2]
        local distance = math.sqrt(dx * dx + dy * dy)
        log("BUILD_RAIL_TRACK: distance=" .. string.format("%.0f", distance))

        -- Use buildRouteBetweenStations - the SAME function build_connection uses
        -- This handles terrain, bridges, tunnels, gradients properly (async via work queue)
        local trackParams = paramHelper.getDefaultRouteBuildingParams("COAL", true, true, distance)
        trackParams.isTrack = true
        trackParams.isCargo = true
        trackParams.isDoubleTrack = false
        trackParams.ignoreErrors = true
        trackParams.allowCargoTrackSharing = true

        log("BUILD_RAIL_TRACK: Calling buildRouteBetweenStations(" .. station1 .. ", " .. station2 .. ")")

        routeBuilder.buildRouteBetweenStations(station1, station2, trackParams, function(result, success)
            log("BUILD_RAIL_TRACK_CB: buildRouteBetweenStations callback success=" .. tostring(success))
            if not success then
                log("BUILD_RAIL_TRACK_CB: Route build FAILED between stations " .. station1 .. " and " .. station2)
            else
                log("BUILD_RAIL_TRACK_CB: Route build SUCCEEDED between stations " .. station1 .. " and " .. station2)
            end
        end)

        return {status = "pending", data = {
            message = "Track build queued via buildRouteBetweenStations (async)",
            con1 = tostring(con1),
            con2 = tostring(con2),
            station1 = tostring(station1),
            station2 = tostring(station2),
            distance = tostring(math.floor(distance))
        }}
    end)

    if ok then return result end
    return {status = "error", message = "build_rail_track failed: " .. tostring(result)}
end

-- Verify that a rail track connection exists between two stations using the game's pathfinder
handlers.verify_track_connection = function(params)
    if not params then
        return {status = "error", message = "Need station1_id/station2_id or industry1_id/industry2_id"}
    end

    local ok, result = pcall(function()
        local util = require("ai_builder_base_util")
        local pathFindingUtil = require("ai_builder_pathfinding_util")

        util.clearCacheNode2SegMaps()
        util.lazyCacheNode2SegMaps()

        local station1, station2

        -- If given station IDs directly, use them
        if params.station1_id and params.station2_id then
            station1 = tonumber(params.station1_id)
            station2 = tonumber(params.station2_id)
        elseif params.industry1_id and params.industry2_id then
            -- Find rail stations nearest to each industry (same logic as build_rail_track)
            local ind1 = tonumber(params.industry1_id)
            local ind2 = tonumber(params.industry2_id)

            local function getIndustryPos(indId)
                local conId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(indId)
                if conId and conId ~= -1 then
                    local conComp = api.engine.getComponent(conId, api.type.ComponentType.CONSTRUCTION)
                    if conComp then
                        local pos = conComp.transf:cols(3)
                        return {x = pos[1], y = pos[2]}
                    end
                end
                return nil
            end

            local indPos1 = getIndustryPos(ind1)
            local indPos2 = getIndustryPos(ind2)
            if not indPos1 then return {status = "error", message = "Industry " .. ind1 .. " not found"} end
            if not indPos2 then return {status = "error", message = "Industry " .. ind2 .. " not found"} end

            -- Find all rail station constructions and their station component IDs
            local railStations = {}
            for id = 1, 60000 do
                if api.engine.entityExists(id) then
                    local conComp = api.engine.getComponent(id, api.type.ComponentType.CONSTRUCTION)
                    if conComp and conComp.fileName and string.find(conComp.fileName, "rail") and conComp.stations and #conComp.stations > 0 then
                        local pos = conComp.transf:cols(3)
                        table.insert(railStations, {conId = id, stationId = conComp.stations[1], x = pos[1], y = pos[2]})
                    end
                end
            end

            local bestDist1, bestDist2 = math.huge, math.huge
            for _, rs in ipairs(railStations) do
                local d1 = math.sqrt((rs.x - indPos1.x)^2 + (rs.y - indPos1.y)^2)
                local d2 = math.sqrt((rs.x - indPos2.x)^2 + (rs.y - indPos2.y)^2)
                if d1 < bestDist1 then bestDist1 = d1; station1 = rs.stationId end
                if d2 < bestDist2 then bestDist2 = d2; station2 = rs.stationId end
            end

            if not station1 then return {status = "error", message = "No rail station near industry " .. ind1} end
            if not station2 then return {status = "error", message = "No rail station near industry " .. ind2} end
        else
            return {status = "error", message = "Need station1_id/station2_id or industry1_id/industry2_id"}
        end

        if station1 == station2 then
            return {status = "error", message = "Both resolve to the same station " .. station1}
        end

        log("VERIFY_TRACK: Checking path station " .. station1 .. " -> " .. station2)

        -- Use the game's actual pathfinder to check for a TRAIN-mode path
        local connected = pathFindingUtil.checkForRailPathBetweenStationFreeTerminals(station1, station2)

        -- Also try the full terminal search (not just free terminals) as a fallback
        if not connected then
            local path = pathFindingUtil.findRailPathBetweenStations(station1, station2)
            connected = path and #path > 0
        end

        -- Get station positions for context
        local pos1 = util.getStationPosition(station1)
        local pos2 = util.getStationPosition(station2)
        local distance = util.distBetweenStations(station1, station2)

        log("VERIFY_TRACK: station1=" .. station1 .. " station2=" .. station2 .. " connected=" .. tostring(connected) .. " dist=" .. tostring(math.floor(distance or 0)))

        return {status = "ok", data = {
            connected = tostring(connected),
            station1_id = tostring(station1),
            station2_id = tostring(station2),
            station1_pos = pos1 and string.format("%.0f,%.0f", pos1.x, pos1.y) or "unknown",
            station2_pos = pos2 and string.format("%.0f,%.0f", pos2.x, pos2.y) or "unknown",
            distance = tostring(math.floor(distance or 0))
        }}
    end)

    if ok then return result end
    return {status = "error", message = "verify_track_connection failed: " .. tostring(result)}
end

-- Query available wagons for a cargo type - shows model names, IDs, and capacity
handlers.query_available_wagons = function(params)
    local cargoType = params and params.cargo_type or "COAL"
    local ok, result = pcall(function()
        local vehicleUtil = require("ai_builder_vehicle_util")
        local paramHelper = require("ai_builder_base_param_helper")
        local stationLen = tonumber(params and params.station_length or "160") or 160
        local trainParams = paramHelper.getDefaultRouteBuildingParams(cargoType, true, true, stationLen)
        trainParams.isCargo = true
        trainParams.cargoType = cargoType
        trainParams.stationLength = stationLen

        local allWagons = vehicleUtil.getWaggonsByCargoType(cargoType, trainParams)
        local wagonList = {}
        for _, w in pairs(allWagons) do
            local modelName = api.res.modelRep.getName(w.modelId) or "unknown"
            -- Check what cargo types this wagon can carry
            local cargoTypes = {}
            if vehicleUtil.cargoIdxLookup and vehicleUtil.cargoIdxLookup[w.modelId] then
                for cType, _ in pairs(vehicleUtil.cargoIdxLookup[w.modelId]) do
                    table.insert(cargoTypes, cType)
                end
            end
            table.insert(wagonList, {
                model_id = tostring(w.modelId),
                name = modelName,
                capacity = tostring(w.capacity or 0),
                cargo_types = table.concat(cargoTypes, ",")
            })
        end

        -- Also find locos
        local locoInfo = vehicleUtil.findBestMatchLocomotive(
            vehicleUtil.getStandardTrackSpeed and vehicleUtil.getStandardTrackSpeed() or 80,
            50, vehicleUtil.filterToNonElectricLocomotive, trainParams
        )
        local locoName = locoInfo and api.res.modelRep.getName(locoInfo.modelId) or "none"

        return {status = "ok", data = {
            cargo_type = cargoType,
            wagon_count = tostring(#wagonList),
            wagons = wagonList,
            best_loco = locoName,
            best_loco_id = tostring(locoInfo and locoInfo.modelId or -1)
        }}
    end)
    if ok then return result end
    return {status = "error", message = "query_available_wagons failed: " .. tostring(result)}
end

-- Create a rail line with vehicles using the line manager's full pipeline
-- Takes construction entity IDs (from query_nearby_stations), resolves to station entities,
-- then delegates to lineManager.createLineAndAssignVechicles
handlers.create_rail_line_with_vehicles = function(params)
    if not params or not params.station_ids then
        return {status = "error", message = "Need station_ids (comma-separated construction entity IDs)"}
    end

    local ok, result = pcall(function()
        local lineManager = require("ai_builder_line_manager")
        local vehicleUtil = require("ai_builder_vehicle_util")
        local paramHelper = require("ai_builder_base_param_helper")
        local util = require("ai_builder_base_util")

        local lineName = params.name or ("Rail " .. os.time())
        local cargoType = params.cargo_type or "COAL"
        local numVehicles = tonumber(params.num_vehicles) or 1

        -- Parse station_ids from comma-separated string or table
        local stationIdList = {}
        if type(params.station_ids) == "string" then
            for id in params.station_ids:gmatch("([^,]+)") do
                table.insert(stationIdList, id:match("^%s*(.-)%s*$"))  -- trim whitespace
            end
        elseif type(params.station_ids) == "table" then
            stationIdList = params.station_ids
        end

        if #stationIdList < 2 then
            return {status = "error", message = "Need at least 2 station_ids, got " .. #stationIdList}
        end

        -- Resolve construction IDs to station entity IDs
        local stationEntities = {}
        for _, idStr in ipairs(stationIdList) do
            local entityId = tonumber(idStr)
            if entityId and api.engine.entityExists(entityId) then
                local con = api.engine.getComponent(entityId, api.type.ComponentType.CONSTRUCTION)
                if con and con.stations and #con.stations > 0 then
                    table.insert(stationEntities, con.stations[1])
                    log("RAIL_LINE_VEH: construction " .. entityId .. " -> station " .. con.stations[1])
                end
            end
        end

        if #stationEntities < 2 then
            return {status = "error", message = "Need at least 2 valid station entities, got " .. #stationEntities}
        end

        -- Build train config - 1 loco + gondola wagons
        local stationLen = tonumber(params.station_length) or 160
        local numWagons = tonumber(params.num_wagons) or 4
        local wagonFilter = params.wagon_type or "gondola"  -- default to gondola for bulk cargo

        -- Find best locomotive (non-electric)
        local trainParams = paramHelper.getDefaultRouteBuildingParams(cargoType, true, true, stationLen)
        trainParams.isCargo = true
        trainParams.cargoType = cargoType
        trainParams.stationLength = stationLen

        -- Find wagons matching the filter (e.g., "gondola")
        local allWagons = vehicleUtil.getWaggonsByCargoType(cargoType, trainParams)
        local matchedWagon = nil
        for _, w in pairs(allWagons) do
            local modelName = api.res.modelRep.getName(w.modelId) or ""
            log("RAIL_LINE_VEH: Available wagon: " .. modelName .. " (id=" .. w.modelId .. ")")
            if modelName:lower():find(wagonFilter:lower()) then
                matchedWagon = w
                log("RAIL_LINE_VEH: Matched wagon filter '" .. wagonFilter .. "': " .. modelName)
                break
            end
        end

        -- If no match, use first available wagon
        if not matchedWagon and #allWagons > 0 then
            matchedWagon = allWagons[1]
            local modelName = api.res.modelRep.getName(matchedWagon.modelId) or ""
            log("RAIL_LINE_VEH: No '" .. wagonFilter .. "' match, using first wagon: " .. modelName)
        end

        if not matchedWagon then
            return {status = "error", message = "No wagons found for cargo " .. cargoType}
        end

        -- Find best locomotive
        local locoInfo = vehicleUtil.findBestMatchLocomotive(
            vehicleUtil.getStandardTrackSpeed and vehicleUtil.getStandardTrackSpeed() or 80,
            50,  -- target tractive effort
            vehicleUtil.filterToNonElectricLocomotive,
            trainParams
        )
        if not locoInfo then
            return {status = "error", message = "No locomotive found"}
        end
        local locoName = api.res.modelRep.getName(locoInfo.modelId) or "?"
        local wagonName = api.res.modelRep.getName(matchedWagon.modelId) or "?"
        log("RAIL_LINE_VEH: Using loco: " .. locoName .. " + " .. numWagons .. "x " .. wagonName)

        -- Build consist manually: 1 loco + N wagons
        -- Format must match vehiclePartForId: loadConfig is ARRAY, reversed=false
        local loadConfigIdx = vehicleUtil.cargoIdxLookup[matchedWagon.modelId][cargoType] - 1
        local vehicleConfig = {vehicles = {}, vehicleGroups = {}}

        -- Add 1 locomotive (loadConfig={0} for locos, not -1)
        vehicleConfig.vehicles[1] = {
            part = {modelId = locoInfo.modelId, loadConfig = {0}, reversed = false},
            autoLoadConfig = {1}
        }
        vehicleConfig.vehicleGroups[1] = 1

        -- Add N wagons
        for i = 1, numWagons do
            vehicleConfig.vehicles[1 + i] = {
                part = {modelId = matchedWagon.modelId, loadConfig = {loadConfigIdx}, reversed = false},
                autoLoadConfig = {1}
            }
            vehicleConfig.vehicleGroups[1 + i] = 1
        end
        log("RAIL_LINE_VEH: Built config: 1 loco + " .. numWagons .. " wagons = " .. (1 + numWagons) .. " parts")

        -- Clear and cache segment maps (needed by line manager)
        util.clearCacheNode2SegMaps()
        util.lazyCacheNode2SegMaps()

        -- Use the line manager's complete pipeline
        log("RAIL_LINE_VEH: Calling createLineAndAssignVechicles: name=" .. lineName .. " vehicles=" .. numVehicles)
        lineManager.createLineAndAssignVechicles(
            vehicleConfig,
            stationEntities,
            lineName,
            numVehicles,
            api.type.enum.Carrier.RAIL,
            trainParams,
            function(res, success)
                log("RAIL_LINE_VEH: createLineAndAssignVechicles callback: success=" .. tostring(success))
                if success then
                    local lineIdOk, lineId = pcall(function() return res.resultEntity end)
                    log("RAIL_LINE_VEH: Line created: " .. tostring(lineId))
                end
            end
        )

        return {status = "ok", data = {
            message = "Rail line creation + vehicle purchase initiated",
            line_name = lineName,
            stations = tostring(#stationEntities),
            num_vehicles = tostring(numVehicles),
            cargo = cargoType
        }}
    end)

    if ok then return result end
    return {status = "error", message = "create_rail_line_with_vehicles failed: " .. tostring(result)}
end

-- Buy a small train with limited wagons for a line
-- Ported from rail.py train() function
handlers.buy_small_train = function(params)
    if not params or not params.line_id then
        return {status = "error", message = "Need line_id parameter"}
    end

    local lineId = tonumber(params.line_id)
    local numWagons = tonumber(params.num_wagons) or 3
    local cargoType = params.cargo_type or "COAL"

    if not lineId then
        return {status = "error", message = "Invalid line_id"}
    end

    log("BUY_SMALL_TRAIN: line=" .. lineId .. " wagons=" .. numWagons .. " cargo=" .. cargoType)

    local ok, result = pcall(function()
        local vehicleUtil = require("ai_builder_vehicle_util")
        local paramHelper = require("ai_builder_base_param_helper")
        local lineManager = require("ai_builder_line_manager")
        local util = require("ai_builder_base_util")

        -- Get line info
        local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
        if not line then
            return {status = "error", message = "Line not found: " .. tostring(lineId)}
        end

        -- Find depot (wrap in pcall since findDepotsForLine can crash on manual lines)
        util.clearCacheNode2SegMaps()
        util.lazyCacheNode2SegMaps()

        local depotId = nil
        local depotOk, depotOptions = pcall(function()
            return lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.RAIL)
        end)

        if depotOk and depotOptions and #depotOptions > 0 then
            depotId = depotOptions[1].depotEntity or depotOptions[1].depot or depotOptions[1]
        end

        if not depotId then
            -- Search for any train depot by scanning entities
            log("BUY_SMALL_TRAIN: findDepotsForLine failed, scanning for depot...")
            for id = 1, 50000 do
                if api.engine.entityExists(id) then
                    local con = api.engine.getComponent(id, api.type.ComponentType.CONSTRUCTION)
                    if con and con.fileName and tostring(con.fileName):find("depot") and tostring(con.fileName):find("train") then
                        if con.depots and #con.depots > 0 then
                            depotId = con.depots[1]
                            break
                        end
                    end
                end
            end
        end

        if not depotId then
            return {status = "error", message = "No train depot found"}
        end

        -- Build train config
        vehicleUtil.cachedVehicleParts = {}
        local trainParams = paramHelper.getDefaultRouteBuildingParams(cargoType, true, true, 1000)
        trainParams.isCargo = true
        trainParams.cargoType = cargoType
        trainParams.stationLength = 1000
        trainParams.targetThroughput = 100
        trainParams.totalTargetThroughput = 100
        trainParams.distance = 1000

        local fullConfig = vehicleUtil.buildMaximumCapacityTrain(trainParams)
        if not fullConfig or not fullConfig.vehicles then
            return {status = "error", message = "Could not build train config for " .. cargoType}
        end

        -- Trim to requested number of wagons (keep 1 locomotive + N wagons)
        local trimmedVehicles = {}
        local trimmedGroups = {}
        local wagonCount = 0
        local locoCount = 0

        for i = 1, #fullConfig.vehicles do
            local modelId = fullConfig.vehicles[i].part.modelId
            local name = api.res.modelRep.getName(modelId) or ""

            local isWagon = name:find("open") or name:find("flat") or name:find("stake") or
                            name:find("rungen") or name:find("tank") or name:find("kessel") or
                            name:find("box") or name:find("covered") or name:find("gondola") or
                            name:find("wagon") or name:find("car") or name:find("coach")

            if isWagon and wagonCount < numWagons then
                table.insert(trimmedVehicles, fullConfig.vehicles[i])
                table.insert(trimmedGroups, fullConfig.vehicleGroups[i])
                wagonCount = wagonCount + 1
            elseif not isWagon and locoCount < 1 then
                table.insert(trimmedVehicles, fullConfig.vehicles[i])
                table.insert(trimmedGroups, fullConfig.vehicleGroups[i])
                locoCount = locoCount + 1
            end
        end

        fullConfig.vehicles = trimmedVehicles
        fullConfig.vehicleGroups = trimmedGroups

        -- Enable auto-loading
        for i = 1, #fullConfig.vehicles do
            fullConfig.vehicles[i].autoLoadConfig = {1}
        end

        -- Buy the vehicle
        local player = api.engine.util.getPlayer()
        local apiVehicle = vehicleUtil.copyConfigToApi(fullConfig)

        log("BUY_SMALL_TRAIN: Buying vehicle at depot " .. tostring(depotId) .. " with " .. #trimmedVehicles .. " parts")
        api.cmd.sendCommand(api.cmd.make.buyVehicle(player, depotId, apiVehicle), function(res, success)
            log("BUY_SMALL_TRAIN: Callback. success=" .. tostring(success))
            if success then
                local getOk, vehicleId = pcall(function() return res.resultVehicleEntity end)
                log("BUY_SMALL_TRAIN: resultVehicleEntity=" .. tostring(vehicleId) .. " getOk=" .. tostring(getOk))
                if getOk and vehicleId then
                    -- Use assignVehicleToLine like the line manager does
                    local lineManagerMod = require("ai_builder_line_manager")
                    lineManagerMod.addBackgroundWork(function()
                        lineManagerMod.assignVehicleToLine(vehicleId, lineId, lineManagerMod.standardCallback)
                    end)
                    log("BUY_SMALL_TRAIN: Queued assignVehicleToLine for vehicle " .. vehicleId .. " -> line " .. lineId)
                else
                    -- Fallback: try setLine directly
                    log("BUY_SMALL_TRAIN: No resultVehicleEntity, trying setLine directly")
                    local errStr = pcall(function() return res.errorStr end)
                    log("BUY_SMALL_TRAIN: errorStr=" .. tostring(errStr))
                end
            else
                log("BUY_SMALL_TRAIN: Purchase failed!")
                local errOk, errStr = pcall(function() return res.errorStr end)
                if errOk then log("BUY_SMALL_TRAIN: errorStr=" .. tostring(errStr)) end
            end
        end)

        return {status = "ok", data = {
            message = "Train with " .. wagonCount .. " " .. cargoType .. " wagons purchase initiated",
            line_id = tostring(lineId),
            wagons = tostring(wagonCount),
            cargo = cargoType,
            loco_count = tostring(locoCount)
        }}
    end)

    if ok then return result end
    return {status = "error", message = "buy_small_train failed: " .. tostring(result)}
end

-- Query nearby stations/constructions around an industry
handlers.query_nearby_stations = function(params)
    if not params or not params.industry_id then
        return {status = "error", message = "Need industry_id parameter"}
    end

    local industryId = tonumber(params.industry_id)
    local radius = tonumber(params.radius) or 300

    log("QUERY_NEARBY: industry=" .. industryId .. " radius=" .. radius)

    local ok, result = pcall(function()
        local util = require("ai_builder_base_util")

        -- Get industry position
        local conId = industryId
        local testCon = api.engine.getComponent(industryId, api.type.ComponentType.CONSTRUCTION)
        if not testCon then
            conId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(industryId)
        end
        if not conId then return {status = "error", message = "Invalid industry ID"} end

        local con = api.engine.getComponent(conId, api.type.ComponentType.CONSTRUCTION)
        if not con then return {status = "error", message = "No construction"} end

        local pos = con.transf:cols(3)
        local industryX = pos[1]
        local industryY = pos[2]

        -- Find nearby stations
        local nearbyStations = {}
        for id = 1, 60000 do
            if api.engine.entityExists(id) then
                local staCon = api.engine.getComponent(id, api.type.ComponentType.CONSTRUCTION)
                if staCon and staCon.stations and #staCon.stations > 0 then
                    local staPos = staCon.transf:cols(3)
                    local dist = math.sqrt((staPos[1]-industryX)^2 + (staPos[2]-industryY)^2)
                    if dist < radius then
                        local nameComp = api.engine.getComponent(id, api.type.ComponentType.NAME)
                        local staName = nameComp and nameComp.name or "unnamed"

                        -- Detect type from filename
                        local staType = "unknown"
                        if staCon.fileName then
                            local fn = tostring(staCon.fileName)
                            if fn:find("rail") or fn:find("train") then staType = "rail"
                            elseif fn:find("bus") or fn:find("truck") or fn:find("road") then staType = "road"
                            elseif fn:find("port") or fn:find("harbor") then staType = "water"
                            end
                        end

                        table.insert(nearbyStations, {
                            id = tostring(id),
                            name = staName,
                            type = staType,
                            distance = tostring(math.floor(dist)),
                            x = tostring(math.floor(staPos[1])),
                            y = tostring(math.floor(staPos[2]))
                        })
                    end
                end
            end
        end

        return {status = "ok", data = {
            industry_id = tostring(industryId),
            industry_x = tostring(math.floor(industryX)),
            industry_y = tostring(math.floor(industryY)),
            radius = tostring(radius),
            stations = nearbyStations,
            station_count = tostring(#nearbyStations)
        }}
    end)

    if ok then return result end
    return {status = "error", message = "query_nearby_stations failed: " .. tostring(result)}
end

-- Build a train depot near a rail station
-- Ported from rail.py depot_at_station() function
handlers.build_train_depot = function(params)
    if not params or not params.station_name then
        return {status = "error", message = "Need station_name parameter"}
    end

    local stationName = params.station_name
    log("BUILD_TRAIN_DEPOT: near station=" .. stationName)

    local ok, result = pcall(function()
        local util = require("ai_builder_base_util")
        local transf = require("transf")
        local vec3 = require("vec3")

        -- Find station construction by name
        local conId = nil
        for id = 1, 60000 do
            if api.engine.entityExists(id) then
                local nameComp = api.engine.getComponent(id, api.type.ComponentType.NAME)
                if nameComp and nameComp.name == stationName then
                    local conComp = api.engine.getComponent(id, api.type.ComponentType.CONSTRUCTION)
                    if conComp and conComp.stations and #conComp.stations > 0 then
                        conId = id
                        break
                    end
                end
            end
        end

        if not conId then
            return {status = "error", message = "Station '" .. stationName .. "' not found"}
        end

        -- Get free nodes from station construction
        local nodes = util.getFreeNodesForConstruction(conId)
        if not nodes or #nodes == 0 then
            return {status = "error", message = "No track nodes for station"}
        end

        -- Find the free end node and another node for direction
        local freeNode = nil
        local otherNode = nil
        local minSegs = 999
        for _, nodeId in pairs(nodes) do
            local segs = util.getSegmentsForNode(nodeId)
            local segCount = segs and #segs or 0
            if segCount < minSegs then
                minSegs = segCount
                otherNode = freeNode
                freeNode = nodeId
            else
                otherNode = nodeId
            end
        end

        if not freeNode then
            return {status = "error", message = "Could not find free track end"}
        end

        -- Get positions
        local freePos = util.nodePos(freeNode)
        local otherPos = otherNode and util.nodePos(otherNode) or freePos

        -- Track direction
        local trackDirX = freePos.x - otherPos.x
        local trackDirY = freePos.y - otherPos.y
        local trackLen = math.sqrt(trackDirX^2 + trackDirY^2)
        if trackLen > 0 then
            trackDirX = trackDirX / trackLen
            trackDirY = trackDirY / trackLen
        else
            trackDirX = 1
            trackDirY = 0
        end

        -- Place depot 60m along track extension from free end
        local depotX = freePos.x + trackDirX * 60
        local depotY = freePos.y + trackDirY * 60
        local depotZ = freePos.z
        local depotAngle = math.atan2(trackDirY, trackDirX)

        local depotParams = {
            seed = 0,
            year = game.interface.getGameTime().date.year
        }

        local depotConstruction = api.type.SimpleProposal.ConstructionEntity.new()
        depotConstruction.fileName = "depot/train_depot_era_a.con"
        depotConstruction.name = "Train Depot"
        depotConstruction.playerEntity = api.engine.util.getPlayer()
        depotConstruction.params = depotParams
        depotConstruction.transf = util.transf2Mat4f(transf.rotZTransl(depotAngle, vec3.new(depotX, depotY, depotZ)))

        local proposal = api.type.SimpleProposal.new()
        proposal.constructionsToAdd[1] = depotConstruction
        local context = util.initContext()
        api.cmd.sendCommand(api.cmd.make.buildProposal(proposal, context, true))

        return {status = "ok", data = {
            message = "Depot placed near " .. stationName,
            position_x = tostring(math.floor(depotX)),
            position_y = tostring(math.floor(depotY)),
            station_name = stationName
        }}
    end)

    if ok then return result end
    return {status = "error", message = "build_train_depot failed: " .. tostring(result)}
end

-- ============================================================================
-- SUPPLY CHAIN TREE BUILDER
-- Builds a recursive tree of all supply chains from towns back to raw materials
-- Uses constructionRep params (sourcesCountForAiBuilder) + backup functions
-- ============================================================================
handlers.query_supply_tree = function(params)
    log("QUERY_SUPPLY_TREE: building supply chain tree")

    local ok, result = pcall(function()
        local util = require "ai_builder_base_util"

        -- ====================================================================
        -- Step 1: Build recipe lookup tables from constructionRep + backups
        -- ====================================================================
        local industriesToOutput = {}   -- fileName -> {cargoType, ...}
        local outputsToIndustries = {}  -- cargoType -> {fileName, ...}
        local ruleSources = {}          -- fileName -> {cargoType -> sourcesCount}
        local hasOrCondition = {}       -- fileName -> true if any sourcesCount < 1

        -- Try constructionRep params first (same pattern as discoverIndustryData)
        local allConstructions = {}
        local repOk, allReps = pcall(function()
            return util.deepClone(api.res.constructionRep.getAll())
        end)
        if repOk and allReps then
            for _, fileName in pairs(allReps) do
                if string.find(fileName, "industry") and not string.find(fileName, "industry/extension/") then
                    table.insert(allConstructions, fileName)
                    local findOk, industryRep = pcall(function()
                        return api.res.constructionRep.get(api.res.constructionRep.find(fileName))
                    end)
                    if findOk and industryRep and industryRep.params then
                        local thisInputCargos = {}
                        local thisSourcesCounts = {}
                        local thisOutputCargos = {}

                        for _, param in pairs(industryRep.params) do
                            if param.key == "inputCargoTypeForAiBuilder" then
                                for _, cargoType in pairs(param.values) do
                                    if cargoType == "NONE" then break end
                                    table.insert(thisInputCargos, cargoType)
                                end
                            end
                            if param.key == "outputCargoTypeForAiBuilder" then
                                for _, cargoType in pairs(param.values) do
                                    if cargoType == "NONE" then break end
                                    table.insert(thisOutputCargos, cargoType)
                                end
                            end
                            if param.key == "sourcesCountForAiBuilder" then
                                thisSourcesCounts = param.values
                            end
                        end

                        -- Store outputs
                        if #thisOutputCargos > 0 then
                            industriesToOutput[fileName] = thisOutputCargos
                        end

                        -- Store rule sources (OR/AND detection)
                        if #thisInputCargos > 0 then
                            ruleSources[fileName] = {}
                            for i, cargo in ipairs(thisInputCargos) do
                                local sc = tonumber(thisSourcesCounts[i]) or 1
                                ruleSources[fileName][cargo] = sc
                                if sc < 1 then
                                    hasOrCondition[fileName] = true
                                end
                            end
                        else
                            ruleSources[fileName] = {}
                        end
                    end
                end
            end
        end

        -- Backup data for industries not discovered from constructionRep
        -- (these functions are local in ai_builder_new_connections_evaluation.lua
        -- and not exported, so we include inline copies here)
        local backupOutputs
        do
            backupOutputs = {}
            backupOutputs["industry/iron_ore_mine.con"] = {"IRON_ORE"}
            backupOutputs["industry/coal_mine.con"] = {"COAL"}
            backupOutputs["industry/forest.con"] = {"LOGS"}
            backupOutputs["industry/oil_well.con"] = {"CRUDE"}
            backupOutputs["industry/quarry.con"] = {"STONE"}
            backupOutputs["industry/farm.con"] = {"GRAIN"}
            backupOutputs["industry/steel_mill.con"] = {"STEEL"}
            backupOutputs["industry/saw_mill.con"] = {"PLANKS"}
            backupOutputs["industry/oil_refinery.con"] = {"FUEL", "PLASTIC"}
            backupOutputs["industry/chemical_plant.con"] = {"PLASTIC"}
            backupOutputs["industry/fuel_refinery.con"] = {"FUEL"}
            backupOutputs["industry/food_processing_plant.con"] = {"FOOD"}
            backupOutputs["industry/tools_factory.con"] = {"TOOLS"}
            backupOutputs["industry/machines_factory.con"] = {"MACHINES"}
            backupOutputs["industry/goods_factory.con"] = {"GOODS"}
            backupOutputs["industry/construction_material.con"] = {"CONSTRUCTION_MATERIALS"}
            backupOutputs["industry/advanced_chemical_plant.con"] = {"PLASTIC"}
            backupOutputs["industry/advanced_construction_material.con"] = {"CONSTRUCTION_MATERIALS"}
            backupOutputs["industry/advanced_food_processing_plant.con"] = {"FOOD"}
            backupOutputs["industry/advanced_fuel_refinery.con"] = {"FUEL", "SAND"}
            backupOutputs["industry/advanced_goods_factory.con"] = {"GOODS"}
            backupOutputs["industry/advanced_machines_factory.con"] = {"MACHINES"}
            backupOutputs["industry/advanced_steel_mill.con"] = {"STEEL", "SLAG"}
            backupOutputs["industry/advanced_tools_factory.con"] = {"TOOLS"}
            backupOutputs["industry/alcohol_distillery.con"] = {"ALCOHOL"}
            backupOutputs["industry/coffee_farm.con"] = {"COFFEE_BERRIES"}
            backupOutputs["industry/coffee_refinery.con"] = {"COFFEE"}
            backupOutputs["industry/fishery.con"] = {"FISH"}
            backupOutputs["industry/livestock_farm.con"] = {"LIVESTOCK"}
            backupOutputs["industry/marble_mine.con"] = {"MARBLE"}
            backupOutputs["industry/meat_processing_plant.con"] = {"MEAT"}
            backupOutputs["industry/oil_sand_mine.con"] = {"OIL_SAND"}
            backupOutputs["industry/paper_mill.con"] = {"PAPER"}
            backupOutputs["industry/silver_mill.con"] = {"SILVER"}
            backupOutputs["industry/silver_ore_mine.con"] = {"SILVER_ORE"}
        end

        local backupRuleSources
        do
            backupRuleSources = {}
            backupRuleSources["industry/iron_ore_mine.con"] = {}
            backupRuleSources["industry/coal_mine.con"] = {}
            backupRuleSources["industry/forest.con"] = {}
            backupRuleSources["industry/oil_well.con"] = {}
            backupRuleSources["industry/quarry.con"] = {}
            backupRuleSources["industry/farm.con"] = {}
            backupRuleSources["industry/steel_mill.con"] = {["IRON_ORE"]=1, ["COAL"]=1}
            backupRuleSources["industry/saw_mill.con"] = {["LOGS"]=1}
            backupRuleSources["industry/oil_refinery.con"] = {["CRUDE"]=1}
            backupRuleSources["industry/chemical_plant.con"] = {["CRUDE"]=1}
            backupRuleSources["industry/fuel_refinery.con"] = {["CRUDE"]=1}
            backupRuleSources["industry/food_processing_plant.con"] = {["GRAIN"]=1}
            backupRuleSources["industry/tools_factory.con"] = {["STEEL"]=1, ["PLANKS"]=1}
            backupRuleSources["industry/machines_factory.con"] = {["STEEL"]=1, ["PLASTIC"]=1}
            backupRuleSources["industry/goods_factory.con"] = {["STEEL"]=1, ["PLASTIC"]=1}
            backupRuleSources["industry/construction_material.con"] = {["STONE"]=1, ["STEEL"]=1}
            backupRuleSources["industry/advanced_chemical_plant.con"] = {["GRAIN"]=2}
            backupRuleSources["industry/advanced_construction_material.con"] = {["SLAG"]=1, ["SAND"]=1, ["MARBLE"]=1, ["STONE"]=1}
            backupRuleSources["industry/advanced_food_processing_plant.con"] = {["MEAT"]=1, ["COFFEE"]=1, ["ALCOHOL"]=1}
            backupRuleSources["industry/advanced_fuel_refinery.con"] = {["OIL_SAND"]=2}
            backupRuleSources["industry/advanced_goods_factory.con"] = {["PLASTIC"]=1, ["PLANKS"]=1, ["PAPER"]=1, ["SILVER"]=1}
            backupRuleSources["industry/advanced_machines_factory.con"] = {["SILVER"]=1, ["STEEL"]=1}
            backupRuleSources["industry/advanced_steel_mill.con"] = {["IRON_ORE"]=2, ["COAL"]=2}
            backupRuleSources["industry/advanced_tools_factory.con"] = {["STEEL"]=1}
            backupRuleSources["industry/alcohol_distillery.con"] = {["GRAIN"]=1}
            backupRuleSources["industry/coffee_refinery.con"] = {["COFFEE_BERRIES"]=1}
            backupRuleSources["industry/livestock_farm.con"] = {["GRAIN"]=1}
            backupRuleSources["industry/meat_processing_plant.con"] = {["LIVESTOCK"]=1, ["FISH"]=1}
            backupRuleSources["industry/paper_mill.con"] = {["LOGS"]=1}
            backupRuleSources["industry/silver_mill.con"] = {["SILVER_ORE"]=1}
            backupRuleSources["industry/coffee_farm.con"] = {}
            backupRuleSources["industry/fishery.con"] = {}
            backupRuleSources["industry/marble_mine.con"] = {}
            backupRuleSources["industry/oil_sand_mine.con"] = {}
            backupRuleSources["industry/silver_ore_mine.con"] = {}
        end

        -- Merge backup data for anything not discovered from constructionRep
        for fileName, outputs in pairs(backupOutputs) do
            if not industriesToOutput[fileName] or #industriesToOutput[fileName] == 0 then
                industriesToOutput[fileName] = outputs
            end
        end
        for fileName, sources in pairs(backupRuleSources) do
            -- Check if ruleSources is nil OR empty (constructionRep may set it
            -- to {} when no inputCargoTypeForAiBuilder params exist)
            if not ruleSources[fileName] or next(ruleSources[fileName]) == nil then
                ruleSources[fileName] = sources
            end
        end

        -- Build reverse map: cargoType -> {fileName, ...}
        for fileName, outputs in pairs(industriesToOutput) do
            for _, cargo in ipairs(outputs) do
                if not outputsToIndustries[cargo] then
                    outputsToIndustries[cargo] = {}
                end
                table.insert(outputsToIndustries[cargo], fileName)
            end
        end

        log("SUPPLY_TREE: loaded " .. #allConstructions .. " industry types")

        -- ====================================================================
        -- Step 2: Get all live industry instances
        -- ====================================================================
        local industryInstances = {}   -- id -> {id, name, fileName, x, y, outputs, inputs}
        local instancesByType = {}     -- fileName -> {instance, ...}
        local instancesByCargo = {}    -- cargoType -> {instance, ...} (producers of that cargo)

        local entities = game.interface.getEntities({radius=1e9}, {type="SIM_BUILDING", includeData=true})
        for id, industry in pairs(entities) do
            local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(id)
            local construction = constructionId and constructionId > 0 and game.interface.getEntity(constructionId) or nil

            local name = industry.name or (construction and construction.name) or "Industry"
            local position = industry.position or (construction and construction.position) or {0, 0, 0}
            local fileName = construction and construction.fileName or ""

            if fileName ~= "" and string.find(fileName, "industry") then
                local outputs = industriesToOutput[fileName] or {}
                local inputs = ruleSources[fileName] or {}

                -- Get production amount from live entity data
                local productionAmount = "0"
                if industry.itemsProduced then
                    for k, v in pairs(industry.itemsProduced) do
                        if type(k) == "string" and not k:match("^_") and type(v) == "number" and v > 0 then
                            productionAmount = tostring(math.floor(v))
                            break
                        end
                    end
                end

                local inst = {
                    id = tostring(id),
                    name = name,
                    fileName = fileName,
                    typeName = fileName:match("industry/(.-)%.") or "unknown",
                    x = math.floor(position[1] or 0),
                    y = math.floor(position[2] or 0),
                    outputs = outputs,
                    inputs = inputs,  -- {cargoType -> sourcesCount}
                    hasOr = hasOrCondition[fileName] or false,
                    production_amount = productionAmount
                }

                industryInstances[tostring(id)] = inst

                if not instancesByType[fileName] then
                    instancesByType[fileName] = {}
                end
                table.insert(instancesByType[fileName], inst)

                for _, cargo in ipairs(outputs) do
                    if not instancesByCargo[cargo] then
                        instancesByCargo[cargo] = {}
                    end
                    table.insert(instancesByCargo[cargo], inst)
                end
            end
        end

        local instanceCount = 0
        for _ in pairs(industryInstances) do instanceCount = instanceCount + 1 end
        log("SUPPLY_TREE: found " .. instanceCount .. " industry instances")

        -- ====================================================================
        -- Step 3: Helper - compute distance between two points
        -- ====================================================================
        local function dist(x1, y1, x2, y2)
            local dx = x1 - x2
            local dy = y1 - y2
            return math.floor(math.sqrt(dx * dx + dy * dy))
        end

        -- ====================================================================
        -- Step 4: Recursive tree builder
        -- ====================================================================
        local function buildSupplierNode(instance, targetX, targetY, visited, depth)
            if depth > 10 then return nil end

            local visitKey = instance.id
            if visited[visitKey] then return nil end
            visited[visitKey] = true

            local distance = dist(instance.x, instance.y, targetX, targetY)
            local inputs = instance.inputs  -- {cargoType -> sourcesCount}

            -- Check if this is a raw producer (no inputs)
            local hasInputs = false
            for _ in pairs(inputs) do
                hasInputs = true
                break
            end

            if not hasInputs then
                -- Raw producer - leaf node
                local node = {
                    producer_id = instance.id,
                    producer_name = instance.name,
                    producer_type = instance.typeName,
                    x = tostring(instance.x),
                    y = tostring(instance.y),
                    distance = tostring(distance),
                    outputs = instance.outputs,
                    production_amount = instance.production_amount,
                    input_groups = {},
                    is_raw = "true"
                }
                visited[visitKey] = nil  -- Allow reuse in other branches
                return node
            end

            -- Processor - build input groups
            local inputGroups = {}
            local hasOr = instance.hasOr

            -- Separate OR members from AND members
            local orMembers = {}
            local andMembers = {}
            for cargo, sc in pairs(inputs) do
                if hasOr and sc < 1 then
                    table.insert(orMembers, cargo)
                else
                    table.insert(andMembers, cargo)
                end
            end

            -- If hasOrCondition is set but all sourcesCount >= 1 in backup data,
            -- we still know OR exists from constructionRep. Check if there are
            -- multiple inputs that could be OR. In that case, fallback: treat
            -- all non-essential inputs as OR if hasOr flag is set from constructionRep.
            -- However, the sourcesCount from constructionRep is the authoritative source.
            -- If sourcesCount was 0 from constructionRep, we already caught it above.

            -- Build OR group if any
            if #orMembers > 0 then
                local orGroup = {
                    type = "or",
                    alternatives = orMembers,
                    suppliers = {}
                }
                for _, cargo in ipairs(orMembers) do
                    orGroup.suppliers[cargo] = {}
                    local producers = instancesByCargo[cargo] or {}
                    for _, producer in ipairs(producers) do
                        if not visited[producer.id] then
                            local subNode = buildSupplierNode(producer, instance.x, instance.y, visited, depth + 1)
                            if subNode then
                                table.insert(orGroup.suppliers[cargo], subNode)
                            end
                        end
                    end
                end
                table.insert(inputGroups, orGroup)
            end

            -- Build AND groups
            for _, cargo in ipairs(andMembers) do
                local andGroup = {
                    type = "and",
                    cargo = cargo,
                    sources_count = tostring(inputs[cargo] or 1),
                    suppliers = {}
                }
                local producers = instancesByCargo[cargo] or {}
                for _, producer in ipairs(producers) do
                    if not visited[producer.id] then
                        local subNode = buildSupplierNode(producer, instance.x, instance.y, visited, depth + 1)
                        if subNode then
                            table.insert(andGroup.suppliers, subNode)
                        end
                    end
                end
                table.insert(inputGroups, andGroup)
            end

            local node = {
                producer_id = instance.id,
                producer_name = instance.name,
                producer_type = instance.typeName,
                x = tostring(instance.x),
                y = tostring(instance.y),
                distance = tostring(distance),
                outputs = instance.outputs,
                production_amount = instance.production_amount,
                input_groups = inputGroups,
                is_raw = "false"
            }

            visited[visitKey] = nil  -- Allow reuse in other branches
            return node
        end

        -- ====================================================================
        -- Step 5: Build tree for each town
        -- ====================================================================
        local towns = {}
        local allTowns = game.interface.getEntities({radius=1e9}, {type="TOWN", includeData=true})

        for townId, town in pairs(allTowns) do
            local townPos = town.position or {0, 0, 0}
            local townX = math.floor(townPos[1] or 0)
            local townY = math.floor(townPos[2] or 0)

            -- Get town demands
            local demands = {}
            local demandOk, cargoSupplyAndLimit = pcall(function()
                return game.interface.getTownCargoSupplyAndLimit(townId)
            end)
            if demandOk and cargoSupplyAndLimit then
                for cargoName, supplyAndLimit in pairs(cargoSupplyAndLimit) do
                    local supply = supplyAndLimit[1] or 0
                    local limit = supplyAndLimit[2] or 0
                    local demand = math.max(0, limit - supply)
                    if demand > 0 then
                        demands[cargoName] = tostring(demand)
                    end
                end
            end

            -- Build supply trees for each demanded cargo
            local supplyTrees = {}
            for cargoName, demandAmount in pairs(demands) do
                local producers = instancesByCargo[cargoName] or {}
                local trees = {}
                for _, producer in ipairs(producers) do
                    local visited = {}
                    local node = buildSupplierNode(producer, townX, townY, visited, 0)
                    if node then
                        -- Override distance to be distance to town specifically
                        node.distance_to_town = tostring(dist(producer.x, producer.y, townX, townY))
                        table.insert(trees, node)
                    end
                end
                -- Sort by distance to town
                table.sort(trees, function(a, b)
                    return tonumber(a.distance_to_town) < tonumber(b.distance_to_town)
                end)
                if #trees > 0 then
                    supplyTrees[cargoName] = trees
                end
            end

            table.insert(towns, {
                id = tostring(townId),
                name = town.name or "Unknown",
                x = tostring(townX),
                y = tostring(townY),
                demands = demands,
                supply_trees = supplyTrees
            })
        end

        -- Sort towns by name
        table.sort(towns, function(a, b) return a.name < b.name end)

        log("SUPPLY_TREE: built trees for " .. #towns .. " towns")
        return {status = "ok", data = {towns = towns}}
    end)

    if ok then return result end
    return {status = "error", message = "query_supply_tree failed: " .. tostring(result)}
end

-- Poll for commands and process them
function M.poll()
    -- Ensure game is at target speed
    ensureGameSpeed()

    local j = get_json()
    if not j then
        -- Try to log that JSON isn't available
        log("ERROR: JSON module not loaded")
        return
    end

    -- Check for command file
    local f = io.open(CMD_FILE, "r")
    if not f then return end

    local content = f:read("*a")
    f:close()

    if not content or #content == 0 then return end

    -- Parse command
    local ok, cmd = pcall(j.decode, content)
    if not ok or not cmd then
        log("ERROR: Bad JSON: " .. tostring(content):sub(1, 50))
        clear_command()
        return
    end

    -- Check if already processed (using timestamp to avoid stuck state)
    local cmd_id = cmd.id
    if cmd_id == last_cmd_id then
        return  -- Already processed this command
    end

    log("RECV: " .. tostring(cmd.cmd) .. " id=" .. tostring(cmd_id))

    -- IMMEDIATELY mark as processed to prevent re-processing
    last_cmd_id = cmd_id

    -- Get handler
    local handler = handlers[cmd.cmd]
    local resp

    -- Ensure game is at target speed before executing command
    if api and api.cmd then
        pcall(function()
            api.cmd.sendCommand(api.cmd.make.setGameSpeed(targetGameSpeed))
        end)
    end

    if handler then
        log("EXEC: " .. tostring(cmd.cmd))
        local success, result = pcall(handler, cmd.params)
        if success then
            resp = result
            log("OK: " .. tostring(cmd.cmd))
        else
            resp = {status = "error", message = tostring(result)}
            log("FAIL: " .. tostring(result))
        end
    else
        resp = {status = "error", message = "Unknown command: " .. tostring(cmd.cmd)}
        log("UNKNOWN: " .. tostring(cmd.cmd))
    end

    log("PRE_WRITE")

    -- Add request ID to response
    if resp then
        resp.id = cmd_id
        log("RESP_READY: " .. type(resp))
    else
        log("ERROR: resp is nil!")
        resp = {status = "error", message = "nil response", id = cmd_id}
    end

    -- Write response with error handling
    local write_success, write_result = pcall(function()
        return write_response(resp)
    end)

    if write_success then
        if write_result then
            log("SENT: id=" .. tostring(cmd_id))
        else
            log("WRITE_FAIL: id=" .. tostring(cmd_id))
        end
    else
        log("WRITE_ERROR: " .. tostring(write_result))
    end

    -- Clear command file
    clear_command()
    log("DONE: " .. tostring(cmd_id))
end

-- Initialize
function M.init()
    log("=== Simple IPC initialized ===")
    -- Clear any stale files
    pcall(os.remove, CMD_FILE)
    pcall(os.remove, RESP_FILE)
end

return M
