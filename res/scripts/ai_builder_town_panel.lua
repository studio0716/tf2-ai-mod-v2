local util = require("ai_builder_base_util") 
local constructionUtil = require("ai_builder_construction_util")
local lineManager = require("ai_builder_line_manager")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local paramHelper = require "ai_builder_base_param_helper"
local townPanel = {}
local trace = util.trace

local function tryLoadUndo() 
	local res 
	pcall(function() res = require "undo_base_util" end)
	return res 
end 
local undo_script = tryLoadUndo() 
local function cloneParcelMap(parcelMap) 
	local result = {}
	for k, v in pairs(parcelMap) do 
		local parcelData = {} 
		parcelData.leftEntities = util.deepClone(v.leftEntities)
		parcelData.rightParcels = util.deepClone(v.rightParcels) 
		result[k]=parcelData
	end 
	
	return result

end 

local function cloneCatchmentAreaSystem(catchmentMap) 
	local result = {}
	for k, v in pairs(catchmentMap) do 
		local edgeId = {}
		edgeId.entity = k.entity
		edgeId.index = k.index 
		result[edgeId]=util.deepClone(v)
	end 
	
	return result

end 

local function initCounter() 
	return {
		totalCount = 0,
		countWithPassengerStation = 0,
		countWithCargoStation = 0
	}
end 

local function initLandUseTypeCounter() 
	local countByLandUse = {} 
	countByLandUse[api.type.enum.LandUseType.RESIDENTIAL]=initCounter() 
	countByLandUse[api.type.enum.LandUseType.INDUSTRIAL]=initCounter() 
	countByLandUse[api.type.enum.LandUseType.COMMERCIAL]=initCounter() 
	return countByLandUse
end
local function getTowns(maxToReturn, circle) 
	local begin = os.clock()
	--collectgarbage("collect")
	trace("Begin getting towns")
	-- it seems that if we don't copy these into pure lua objects then wierd things happen
	local catchmentAreaMap = cloneCatchmentAreaSystem( api.engine.system.catchmentAreaSystem.getEdge2stationsMap())
	local townBuildingMap = util.deepClone(api.engine.system.townBuildingSystem.getTown2BuildingMap())
	local townBuildingMapInv = {}
	local personsByTown = {}
	for townId, buildings in pairs(townBuildingMap) do
		personsByTown[townId] = {}
		for i, building in pairs(buildings) do 
			townBuildingMapInv[api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(building)]=townId
		end
	end 
	local seg2parcelMap = cloneParcelMap(api.engine.system.parcelSystem.getSegment2ParcelData())
	local parcel2BuildingMap = util.deepClone(api.engine.system.townBuildingSystem.getParcel2BuildingMap())
	trace("Copied catchmentAreaMap and townBuildingMap, time taken",(os.clock()-begin))
	
	
	api.engine.forEachEntityWithComponent(function(personId)
		local person =util.getComponent(personId, api.type.ComponentType.SIM_PERSON)
		local residence = person.destinations[1] 
		if residence ~= -1 then 
			local townId = townBuildingMapInv[residence]
			--trace("For personId=",personId," their residence was ",residence," the townId = ",townId)
			if townId then 
				if not personsByTown[townId] then 
					personsByTown[townId] = {} 
				end
				table.insert(personsByTown[townId], util.deepClone(person.moveModes))
			end
		end
	end, api.type.ComponentType.SIM_PERSON) 
	
	
	local passengerCatchmentBuildings = {}
	local cargoCatchmentBuildings = {}
	cargoCatchmentBuildings[api.type.enum.LandUseType.COMMERCIAL] = {}
	cargoCatchmentBuildings[api.type.enum.LandUseType.INDUSTRIAL] = {}
	local passengerCatchmentEdges = {}
	local cargoCatchmentEdges = {}
	cargoCatchmentEdges[api.type.enum.LandUseType.COMMERCIAL] = {}
	cargoCatchmentEdges[api.type.enum.LandUseType.INDUSTRIAL] = {}
	local passengerStations = {}
	local fullCargoCatchmentBuildings = {}
	local cargoStations = {}
	cargoStations[api.type.enum.LandUseType.COMMERCIAL] = {}
	cargoStations[api.type.enum.LandUseType.INDUSTRIAL] = {}
	local isCargoLookup = {}
	local isCargoStationFull = {}
	local isEdgeLookup = {}
	api.engine.forEachEntityWithComponent(function(stationId)
		local station = util.getStation(stationId)
		isCargoLookup[stationId]=station.cargo
		isCargoStationFull[stationId]=station.cargo and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId) ~= -1 
		
	end, api.type.ComponentType.STATION) 
	api.engine.forEachEntityWithComponent(function(edgeId)
		isEdgeLookup[edgeId]=true
	end, api.type.ComponentType.BASE_EDGE) 
	trace("Looked up stations, cumulative time taken",(os.clock()-begin), " there are ",util.size(catchmentAreaMap), " entries")
	--local edgesByIndex = {} 
	local count = 0
	local edgeCount = 0
	local cargoLandUseTypeCache = {}
	local function getCargoLandUseType(stationId) 
		if not cargoLandUseTypeCache[stationId] then 
			local landUseTypes = {}
			 
			for i, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLineStopsForStation(stationId))) do  
				trace("About to get cargo type for line",lineId)
				local cargoType = lineManager.discoverLineCargoType(lineId)
				if cargoType then 
					if type(cargoType) == "string" then cargoType = api.res.cargoTypeRep.find(cargoType) end
					local cargoRep = api.res.cargoTypeRep.get(cargoType)
					if #cargoRep.townInput > 0 then 
						if not landUseTypes[cargoRep.townInput[1]] then 
							landUseTypes[cargoRep.townInput[1]]=true
						end
					end 
				end
			end 
			cargoLandUseTypeCache[stationId]=landUseTypes
		end 
		return cargoLandUseTypeCache[stationId]
	end 
	
	--if util.tracelog then debugPrint({isCargoLookup = isCargoLookup, catchmentAreaMap=catchmentAreaMap})end
	for edgeId, stations in pairs(catchmentAreaMap) do 
		--debugPrint(edgeId)
		count = count+1
		--trace("Looping over edges, count=",count)
		--trace("Type of edgeId was ",type(edgeId))
		--trace("Looking up edgeId.entity=",edgeId.entity)
		--trace("Result of looking it up was ",isEdgeLookup[edgeId.entity])
		if isEdgeLookup[edgeId.entity] then 
			edgeCount = edgeCount + 1
			--trace("Inspecting edge, edgeCount = ",edgeCount)
			for i, stationId in pairs(stations) do
				--trace("Looking up an edge, count total:",count," edges",edgeCount)
				--trace("About to check isCargo")
				local isCargo = isCargoLookup[stationId]
				--trace("StationId ",stationId," isCargo?",isCargo, "count total:",count," edges",edgeCount)
				local isCargoFull = isCargoStationFull[stationId]
				--if not edgesByIndex[edgeId.entity] then 
			--		edgesByIndex[edgeId.entity]={}
			--	end
			--	table.insert(edgesByIndex[edgeId.entity], edgeId.index)
				if not isCargo then 
					if not passengerCatchmentEdges[edgeId.entity] then 
						passengerCatchmentEdges[edgeId.entity]=true
					end 
					if not passengerStations[stationId] then 
						passengerStations[stationId] = true
					end 
				end
				
				local left = edgeId.index == 0
				--local parcelData = api.engine.system.parcelSystem.getParcelData(edgeId.entity)
				local parcelData = seg2parcelMap[edgeId.entity]
				-- trace("Got parcel data", parcelData)
				if not parcelData then 
					goto continue 
				end
				local parcels = left and parcelData.leftEntities or parcelData.rightParcels
				for __, parcel in pairs(parcels) do
					-- trace("Inspecting parcel",parcel)
					local townBuilding = parcel2BuildingMap[parcel]
					--api.engine.system.townBuildingSystem.getBuilding(parcel)
					-- trace("Got townBuilding",townBuilding)
					if townBuilding then 
						if isCargo then 
							for   cargoLandUseType, bool in pairs(getCargoLandUseType(stationId)) do
								if not cargoCatchmentBuildings[cargoLandUseType][townBuilding] then 
									cargoCatchmentBuildings[cargoLandUseType][townBuilding]=true
								end 
								if not cargoCatchmentEdges[cargoLandUseType][edgeId.entity] then 
									cargoCatchmentEdges[cargoLandUseType][edgeId.entity]=true
								end 
								if not cargoStations[cargoLandUseType][stationId] then 
									cargoStations[cargoLandUseType][stationId]=true
								end 
							end
							if isCargoFull then 
								fullCargoCatchmentBuildings[townBuilding]=true
							end 
						else 
							if not passengerCatchmentBuildings[townBuilding] then 
								passengerCatchmentBuildings[townBuilding]=true
							end 
						end
					end
				end 
			end
			
			--[[
			for i, linkEntityId in pairs(api.engine.system.tpNetLinkSystem.getLinkEntities(edgeId)) do 
				trace("Inspecting linkEntityId",linkEntityId)
				local linkEntity = util.getComponent(linkEntityId, api.type.ComponentType.TP_NET_LINK)
				local entity = linkEntity.to.edgeId.entity
				if util.getEntity(entity) then 
					trace("Found ",entity," of type ",util.getEntity(entity).type)
				else 
					trace("Unknown entity",entity)
				end 
				entity = linkEntity.from.edgeId.entity
				if util.getEntity(entity) then 
					trace("Found ",entity," of type ",util.getEntity(entity).type)
				else 
					trace("Unknown entity",entity)
				end 
			end ]]--
			::continue::
		end
	end
	trace("Built catchment maps, cummulative time taken:",(os.clock()-begin))
	--debugPrint(edgesByIndex)
	
	local result = {} 
	
	for townId, town in pairs(util.deepClone(game.interface.getEntities(circle, {type="TOWN", includeData=true}))) do 
		local totalCount = 0
		local countWithoutFullCargoCoverage = 0
		local countWithStation = 0
		local personCapacityTotal = 0
		local personCapacityWithStation = 0
		local countByLandUses = initLandUseTypeCounter()
		local buildingsWithoutPassengerCoverage = {}
		local commericalBuildingsWithoutCargoCoverage = {}
		local industrialBuildingsWithoutCargoCoverage = {}
		local buildingsWithoutFullCargoCoverage = {}
		for i, townBuildingId in pairs(townBuildingMap[townId]) do 
			if not fullCargoCatchmentBuildings[townBuildingId] then 
				table.insert(buildingsWithoutFullCargoCoverage, townBuildingId)
				countWithoutFullCargoCoverage = countWithoutFullCargoCoverage + 1
			end 
			local townBuilding = util.getComponent(townBuildingId, api.type.ComponentType.TOWN_BUILDING)
			local personCapacity = util.getComponent(townBuilding.personCapacity, api.type.ComponentType.PERSON_CAPACITY)
			totalCount = totalCount + 1
			local countByLandUse = countByLandUses[personCapacity.type]
			countByLandUse.totalCount = countByLandUse.totalCount + 1
			personCapacityTotal = personCapacityTotal + personCapacity.capacity
			if passengerCatchmentBuildings[townBuildingId] then 
				countWithStation = countWithStation + 1
				personCapacityWithStation = personCapacityWithStation + personCapacity.capacity 
				countByLandUse.countWithPassengerStation = countByLandUse.countWithCargoStation + 1
			else 
				table.insert(buildingsWithoutPassengerCoverage, townBuildingId)
			end
			if personCapacity.type ~= api.type.enum.LandUseType.RESIDENTIAL then 
				if cargoCatchmentBuildings[personCapacity.type][townBuildingId] then 
					countByLandUse.countWithCargoStation = countByLandUse.countWithCargoStation + 1
				else 
					if personCapacity.type == api.type.enum.LandUseType.COMMERCIAL then 
						table.insert(commericalBuildingsWithoutCargoCoverage, townBuildingId)
					else 
						table.insert(industrialBuildingsWithoutCargoCoverage, townBuildingId)
					end
				end
			end
			
			--local parcel = util.getComponent(townBuilding.parcels[1], api.type.ComponentType.PARCEL)
			--local edgeId = parcel.streetSegment
		end 
		local coverageByCount = countWithStation / totalCount
		local coverageByCapacity = personCapacityWithStation / personCapacityTotal
		local coverageWithFullCargo = (totalCount-countWithoutFullCargoCoverage)/totalCount
		local cargoSupply = api.engine.system.townBuildingSystem.getCargoSupplyAndLimit(townId) 
		local personCount = 0 
		local moveModeCar = 0
		local moveModeWalk = 0
		local moveModeTransit = 0
		local commercialTruckStop
		local industrialTruckStop
		local passengerTrainStation
		local stations = api.engine.system.stationSystem.getStations(townId)
		for __, stationId in pairs(stations) do 
			if util.isTruckStop(stationId) then 
				for landUseType, bool in pairs(getCargoLandUseType(stationId)) do 
					if landUseType == api.type.enum.LandUseType.COMMERCIAL then 
						commercialTruckStop = stationId 
					end 
					if landUseType == api.type.enum.LandUseType.INDUSTRIAL then 
						industrialTruckStop = stationId 
					end 
						
				end 
			elseif not util.isBusStop(stationId) then 
				local station = util.getStation(stationId)
				if not station.cargo then 
					local construction = util.getConstructionForStation(stationId) 
					if construction.fileName == "station/rail/modular_station/modular_station.con" then 
						passengerTrainStation = stationId 
					end
				end 
			end 
			if commercialTruckStop and industrialTruckStop then 	
			--	break 
			end
		end 
		 
		for i, moveModes in pairs(personsByTown[townId]) do 
			personCount = personCount + 1
			--local person = util.getComponent(personId, api.type.ComponentType.SIM_PERSON)
			for j = 2, 3 do 
				local moveMode = moveModes[j]
				if moveMode == 2 then 
					moveModeTransit = moveModeTransit + 1
				elseif moveMode == 1 then 
					moveModeCar = moveModeCar + 1
				else 
					moveModeWalk = moveModeWalk + 1
				end 
			end 
		end
		local transitUsage = moveModeTransit / (2*personCount)
		local centralCargoStation = util.searchForNearestStation(util.v3fromArr(town.position), 350, 
			function(station) 
				return station.carriers.ROAD and station.cargo and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station.id) ~= -1 
			end)
		local commercial = countByLandUses[api.type.enum.LandUseType.COMMERCIAL]
		local commercialCargoCoverage = commercial.countWithCargoStation / commercial.totalCount
		local industrial = countByLandUses[api.type.enum.LandUseType.INDUSTRIAL]
		local industrialCargoCoverage = industrial.countWithCargoStation / industrial.totalCount
		local cargoCoverageBoth = (industrial.countWithCargoStation+commercial.countWithCargoStation)/(commercial.totalCount+industrial.totalCount)
		local reachability = game.interface.getTownReachability(townId)
		table.insert(result, {
			town = town,
			hasBusStops = #util.getBusStopsForTown(town, true) > 1,
			coverageByCapacity = coverageByCapacity,
			coverageByCount = coverageByCount,
			cargoSupply = cargoSupply,
			transitUsage = transitUsage,
			moveModeCar = moveModeCar,
			moveModeTransit = moveModeTransit, 
			moveModeWalk = moveModeWalk,
			buildingsWithoutPassengerCoverage = buildingsWithoutPassengerCoverage, 
			commercialCargoCoverage =commercialCargoCoverage,
			industrialCargoCoverage = industrialCargoCoverage,
			cargoCoverageBoth = cargoCoverageBoth,
			personCount = personCount,
			busStation = util.findBusStationForTown(townId),
			commercialTruckStop = commercialTruckStop,
			industrialTruckStop = industrialTruckStop,
			commericalBuildingsWithoutCargoCoverage = commericalBuildingsWithoutCargoCoverage,
			industrialBuildingsWithoutCargoCoverage = industrialBuildingsWithoutCargoCoverage,
			privateReachability=reachability[1],
			transitReachability=reachability[2],
			passengerTrainStation =passengerTrainStation,
			passengerCatchmentEdges = passengerCatchmentEdges,
			cargoCatchmentEdges = cargoCatchmentEdges,
			cargoStations = cargoStations,
			passengerStations = passengerStations,
			countWithoutFullCargoCoverage = countWithoutFullCargoCoverage,
			coverageWithFullCargo = coverageWithFullCargo,
			buildingsWithoutFullCargoCoverage = buildingsWithoutFullCargoCoverage,
			centralCargoStation = centralCargoStation,
		})
		if #result == maxToReturn then 
			break 
		end 
	end 
	trace("Completed towns report, cummulative time taken:",(os.clock()-begin))
	return result
end	

function townPanel.hasTownCargoSource() 
	return api.res.cargoTypeRep.find("WASTE") ~= -1 -- TODO find a better way to determine this
end 

function townPanel.buildTownPanel(circle) 
	 local boxLayout = api.gui.layout.BoxLayout.new("VERTICAL");
	--[[local button = newButton(_('Create new air connections'))
	boxlayout:addItem(button)
	button:onClick(function() 
		addWork(function()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewAirConnections", "", {ignoreErrors=ignoreErrors}), standardCallback)
		end)
	
	end) 
	-- textInput:setText()]]--
	local maxToReturn = 5

	
	local  refresh
	local function sortableHeader(name, scoreFn, invert) 
		local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
		
		local imageView =api.gui.comp.ImageView.new(invert and "ui/icons/build-control/arrow_up@2x.tga" or "ui/icons/build-control/arrow_down@2x.tga")
		imageView:setMaximumSize(api.gui.util.Size.new( 17, 17 ))
		local button = api.gui.comp.Button.new(imageView, false)
		button:onClick(function() townPanel.addWork(function() refresh(scoreFn)end)end)
		boxLayout:addItem(button) 
		boxLayout:addItem(api.gui.comp.TextView.new(_(name)))
		local comp = api.gui.comp.Component.new(" ")
		comp:setLayout(boxLayout)
		return comp
	end 
	 
	 local developAllButton = util.newButton("Develop all")
	 developAllButton:onClick(function() 
		townPanel.addWork(function() 
			api.engine.forEachEntityWithComponent(function(town) 
				api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","developStationOffside", "", {
					town=town}))
			end, api.type.ComponentType.TOWN)
		end)
		developAllButton:setEnabled(false, false)
	 end)
	 local relocateAllButton = util.newButton("Relocate all")
	 	 relocateAllButton:onClick(function() 
		townPanel.addWork(function() 
			api.engine.forEachEntityWithComponent(function(town) 
				api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","repositionBusStops", "", {
					town=town}))
			end, api.type.ComponentType.TOWN)
		end)
		relocateAllButton:setEnabled(false, false)
	 end)
	 local colHeaders = {
		api.gui.comp.TextView.new(_("Name")), 
		sortableHeader("Population", function(result) return 2^16-result.personCount end, true), 
		sortableHeader("Coverage", function(result) return result.coverageByCapacity end),
		api.gui.comp.TextView.new(_("Bus Network")),
		sortableHeader("Transit use", function(result) return result.transitUsage end),
		sortableHeader("Transit destinations", function(result) return result.transitReachability end),
		api.gui.comp.TextView.new(_("Upgrade")),
		sortableHeader("Cargo Coverage\nCommercial ", function(result) return result.commercialCargoCoverage end),
		api.gui.comp.TextView.new(_("New commercial stop")),
		sortableHeader("Cargo Coverage\nIndustrial", function(result) return result.industrialCargoCoverage end),
		api.gui.comp.TextView.new(_("New industrial stop")),
		relocateAllButton,
		developAllButton,
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local moreButton = util.newButton(_("Show more"), "ui/button/xxsmall/down_thin@2x.tga" ) --"ui/button/xsmall/down@2x.tga"
	local noMatchDisplay = api.gui.comp.TextView.new(_("No matches found"))
	noMatchDisplay:setVisible(false, false)
	boxLayout:addItem(noMatchDisplay)
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	
	local function displayCoverage(result) 
		local coverageByCapacity = math.floor(100*result.coverageByCapacity)
		local coverageByCount = math.floor(100*result.coverageByCount)
		local text = api.util.formatNumber(coverageByCapacity).."%"
		local textView = api.gui.comp.TextView.new(text)
		textView:setTooltip(_("Coverage by building count")..api.util.formatNumber(coverageByCount).."%")
		return textView
	end 
	local function displayTransitUsage(result) 
		local transitUsage = math.floor(100*result.transitUsage)
		
		local text = api.util.formatNumber(transitUsage).."%"
		local textView = api.gui.comp.TextView.new(text)
		local tooltip = _("Walk:")..tostring(result.moveModeWalk).."\n".._("Car:")..tostring(result.moveModeCar).."\n".._("Transit")..tostring(result.moveModeTransit)
		
		textView:setTooltip(tooltip)
		return textView
	end 
	local function displayTransitReachability(result) 
		local text = api.util.formatNumber(result.transitReachability) 
		local textView = api.gui.comp.TextView.new(text)
		local tooltip = _("Private:")..api.util.formatNumber(result.privateReachability) 
		
		textView:setTooltip(tooltip)
		return textView
	end
	
	local function displayCargoCoverage(coverage, extraInfo) 
		local cargoCoverage = math.floor(100*coverage)-- needs to be integer for formatNumber
		--local commercialCargoCoverage = math.floor(100*result.commercialCargoCoverage)
		--local industrialCargoCoverage = math.floor(100*result.industrialCargoCoverage)
		local text = tostring(cargoCoverage).."%"
		local textView = api.gui.comp.TextView.new(text)
		if extraInfo then 
			textView:setTooltip(tostring(math.floor(100*extraInfo)).."% total coverage")
		end 
		
		--local tooltip = _("Commercial:")..api.util.formatNumber(commercialCargoCoverage).."%\n".._("Industrial")..api.util.formatNumber(industrialCargoCoverage).."%"
		--textView:setTooltip(tooltip)
		return textView
	end 
	displayTable:setHeader(colHeaders)
	local lastScoreFn
	refresh = function(scoreFn)
		local begin = os.clock()
		displayTable:deleteAll()
		if not scoreFn then scoreFn = lastScoreFn end 
		lastScoreFn = scoreFn
		local results = scoreFn and getTowns(math.huge, circle) or getTowns(maxToReturn, circle)
		if not results or #results == 0 then 
			moreButton:setVisible(false, false)
			displayTable:setVisible(false, false)
			noMatchDisplay:setVisible(true, false)
			return
		end
		noMatchDisplay:setVisible(false, false)
		moreButton:setVisible(true, false)
		displayTable:setVisible(true, false)
		if scoreFn then 
			results = util.evaluateAndSortFromScores(results, {1}, {scoreFn})
		end 
		for i = 1, #results do
			local result = results[i]
			local relocateButton = util.newButton("Relocate bus stops", "ui/icons/windows/vehicle_set_line@2x.tga")
			local description = result.busStation and "Add bus stop" or "Create bus network"
			local newBusStopButton = util.newButton(description, "ui/button/medium/vehicle_bus@2x.tga")
			relocateButton:onClick(function()
				townPanel.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","repositionBusStops", "", {town=result.town.id}))
				end)
				relocateButton:setEnabled(false)
				newBusStopButton:setEnabled(false) -- because the cached data is now stale
			end)
			relocateButton:setEnabled(result.hasBusStops)
			local addBusLanesButton = util.newButton("Add bus lanes", "ui/streets/bus_new@2x.tga")
			local addTramsButton = util.newButton("Trams", "ui/button/large/tram.tga")
			
			local upgradesComp = api.gui.comp.Component.new(" ")
			local upgradesLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
			upgradesLayout:addItem(addBusLanesButton)
			upgradesLayout:addItem(addTramsButton)
			upgradesComp:setLayout(upgradesLayout)
			addBusLanesButton:onClick(function()
				townPanel.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","addBusLanes", "", {town=result.town.id, addBusLanes=true}))
				end)
				addBusLanesButton:setEnabled(false)
			end)
			addTramsButton:onClick(function()
				townPanel.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","addBusLanes", "", {town=result.town.id, addTrams=true}))
				end)
				addTramsButton:setEnabled(false)
			end)
			 
			newBusStopButton:onClick(function()
				townPanel.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewTownBusStop", "", {town=result.town.id, buildingsWithoutCoverage=result.buildingsWithoutPassengerCoverage, busStation= result.busStation, catchmentEdges=result.passengerCatchmentEdges, existingStations=result.passengerStations}))
				end)
				newBusStopButton:setEnabled(false)
			end)
			--newBusStopButton:setEnabled(result.busStation ~= nil )
			local newCommericalStopButton = util.newButton("Build", "ui/button/medium/vehicle_truck@2x.tga")
			newCommericalStopButton:onClick(function()
				townPanel.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewTownBusStop", "", {
					town=result.town.id,
					buildingsWithoutCoverage=result.commericalBuildingsWithoutCargoCoverage, 
					truckStop = result.commercialTruckStop,
					catchmentEdges = result.cargoCatchmentEdges[api.type.enum.LandUseType.COMMERCIAL],
					existingStations=result.cargoStations[api.type.enum.LandUseType.COMMERCIAL],
					landUseType=api.type.enum.LandUseType.COMMERCIAL,
					isCargo=true
					}), function(res, success) debugPrint({res=res, success=success}) end)
				end)
				newCommericalStopButton:setEnabled(false)
			end)
			newCommericalStopButton:setEnabled(result.commercialTruckStop ~= nil )
			local newIndustrialStopButton = util.newButton("Build", "ui/button/medium/vehicle_truck@2x.tga")
			newIndustrialStopButton:onClick(function()
				townPanel.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","buildNewTownBusStop", "", {
					town=result.town.id, 
					buildingsWithoutCoverage=result.industrialBuildingsWithoutCargoCoverage, 
					truckStop = result.industrialTruckStop,
					catchmentEdges = result.cargoCatchmentEdges[api.type.enum.LandUseType.INDUSTRIAL],
					landUseType=api.type.enum.LandUseType.INDUSTRIAL,
					existingStations=result.cargoStations[api.type.enum.LandUseType.INDUSTRIAL],
					isCargo=true}))
				end)
				newIndustrialStopButton:setEnabled(false)
			end)
			newIndustrialStopButton:setEnabled(result.industrialTruckStop ~= nil )
			
			local developStationOffside = util.newButton("Develop station offside","ui/button/large/rail_station.tga")
			local developStationOffsideEnabled = false 
			
			if result.passengerTrainStation and not util.isStationTerminus(result.passengerTrainStation) then 
				local construction = util.getConstructionForStation(result.passengerTrainStation)
				local countMainBuildings = 0 
				for i, mod in pairs(construction.params.modules) do 
					if string.find(mod.name, "main_building") then 
						countMainBuildings = countMainBuildings + 1
					end
				end 
				if construction.fileName=="station/rail/modular_station/modular_station.con" and (not construction.params.includeOffsideBuildings or countMainBuildings <= 1) and #util.getStation(result.passengerTrainStation).terminals % 2 == 0 then 
					developStationOffsideEnabled = true 
				end
			end 
			
			developStationOffside:setEnabled(developStationOffsideEnabled)
			developStationOffside:onClick(function()
				townPanel.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","developStationOffside", "", {
					stationId=result.passengerTrainStation}))
				end)
				developStationOffside:setEnabled(false)
			end)
			displayTable:addRow({
			 
				util.makelocateRow(result.town),
				api.gui.comp.TextView.new(api.util.formatNumber(result.personCount)),
				displayCoverage(result),
				newBusStopButton,
				displayTransitUsage(result) ,
				displayTransitReachability(result),
				upgradesComp,
				displayCargoCoverage(result.commercialCargoCoverage, result.coverageWithFullCargo),
				newCommericalStopButton,
				displayCargoCoverage(result.industrialCargoCoverage),	
				newIndustrialStopButton,
				relocateButton,
				developStationOffside
			})
			if i == maxToReturn then 
				break 
			end
		end
		local endTime = os.clock()
		trace("Time taken to setup town display was ",(endTime-begin))
	end
	 
	
	
	 
	boxLayout:addItem(displayTable)
	local bottomLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL");
	
	local refreshButton = util.newButton(_("Refresh"),"ui/button/xxsmall/replace@2x.tga")
	bottomLayout:addItem(refreshButton)
	bottomLayout:addItem(moreButton)
	
	boxLayout:addItem(bottomLayout)
	moreButton:onClick(function()  
		maxToReturn = 2*maxToReturn
		refresh( )
	end)
	refreshButton:onClick(function()
		refresh( )
	end)
	

	
	 
	
	local comp= api.gui.comp.Component.new(" ")
	comp:setLayout(boxLayout)
	local isInit = false
	return {
		comp = comp,
		title = util.textAndIcon("TOWNS", "ui/button/medium/towns.tga"),
		refresh = function()
			isInit = false
		end,
		init = function() 
			if not isInit then 
				refresh()  
				isInit = true
			end
		end

	}

end

local function edgeIsOk(edgeId) 
	local edge = util.getEdge(edgeId)
	if #edge.objects > 0 then 
		return false 
	end
	if edge.type~=0 then 
		return false 
	end
	if util.isDeadEndEdge(edgeId) then 
		return false 
	end 
	local streetEdge = util.getStreetEdge(edgeId)
	if string.find(api.res.streetTypeRep.getName(streetEdge.streetType), "old") and util.year() >= 1925 then 
		return false  --appears to cause a game crash building on an old street after 1925 (concurrency issue with town street upgrade?)
	end
	if util.calculateSegmentLengthFromEdge(edge) < 60 then 
		return false 
	end
	if streetEdge.tramTrackType > 0 then 
		return false 
	end
	return true
end
function townPanel.buildNewTownBusNetwork(param)
	local townId = param.town 
	local startPosition = util.v3fromArr(util.getEntity(townId).position)
	local existingStation
	 
	for i, stationId in pairs(api.engine.system.stationSystem.getStations(townId)) do
		if not util.getStation(stationId).cargo and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId) ~= -1 then
			startPosition = util.getStationPosition(stationId)
			existingStation = stationId
			break
		end 
	end
	 
	local function callback(res, success) 
		if success then 
			local busStationConstr = res.resultEntities[1]
			townPanel.addWork(function() constructionUtil.buildTownBusStops(townId, function(res, success) 
				if success then 
					townPanel.addWork(function() lineManager.setupTownBusNetwork( busStationConstr, townId) end )
				
				end 
			
			end) end )
		end 
	end 	
	constructionUtil.buildBusStationNearestEdge(townId, startPosition, existingStation, callback)
end 
function townPanel.autoExpandCargoCoverage() 
	trace("Begin townPanel.autoExpandBusCoverage")
	townPanel.autoExpandCoverage(false, true) 
end 
	
function townPanel.autoExpandBusCoverage() 
	trace("Begin townPanel.autoExpandBusCoverage")
	townPanel.autoExpandCoverage(true, false) 
end

function townPanel.autoExpandAllCoverage() 
	trace("Begin townPanel.autoExpandAllCoverage")
	townPanel.autoExpandCoverage(true, true) 
end

function townPanel.autoExpandCoverage(expandBus, expandCargo) 
	trace("Begin townPanel.autoExpandCoverage")
	local gameTime = util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	if not townPanel.lastAutoCoverageCheckTime then 
		townPanel.lastAutoCoverageCheckTime = 0
	end 
	if  gameTime-townPanel.lastAutoCoverageCheckTime < 300000 then -- I think this is 5 minutes? 
		trace("townPanel.autoExpandCoverage: sleeping")
		return 
	end 
	townPanel.lastAutoCoverageCheckTime = gameTime
	
	local params = paramHelper.getParams()
	local passengerThreshold = params.passengerCoverageTarget 
	local cargoThreshold = params.cargoCoverageTarget
	for i , result in pairs(getTowns(math.huge, { pos = {0,0,0}, radius=math.huge})) do 
		if expandBus and result.coverageByCapacity < passengerThreshold and result.coverageByCapacity>0 then 
			trace("adding bus stop for town",result.town.name," based on coverageByCapacity",result.coverageByCapacity)
			
			townPanel.addWork(function() 
				
				local param = {town=result.town.id, buildingsWithoutCoverage=result.buildingsWithoutPassengerCoverage, busStation= result.busStation, catchmentEdges=result.passengerCatchmentEdges, existingStations=result.passengerStations}
				townPanel.buildNewTownBusStop(param)
			end)
		end
		if expandCargo then 
			if townPanel.hasTownCargoSource() then 
			
			
				townPanel.addWork(function() 
					if result.centralCargoStation and  result.coverageWithFullCargo < cargoThreshold then
						local param = {
							town=result.town.id,
							buildingsWithoutCoverage=result.buildingsWithoutFullCargoCoverage, 
						 
							catchmentEdges = result.cargoCatchmentEdges[api.type.enum.LandUseType.COMMERCIAL],
							existingStations=result.cargoStations ,
							centralCargoStation = result.centralCargoStation,
							isCargo=true}
							townPanel.buildNewFullTruckStation(param)
						end
					end)
			
			else 
				if result.commercialTruckStop ~= nil and result.commercialCargoCoverage < cargoThreshold then 
					trace("adding commercial cargo stop for town",result.town.name," based on coverage",result.commercialCargoCoverage)
					townPanel.addWork(function() 
						
						local param = {
							town=result.town.id,
							buildingsWithoutCoverage=result.commericalBuildingsWithoutCargoCoverage, 
							truckStop = result.commercialTruckStop,
							catchmentEdges = result.cargoCatchmentEdges[api.type.enum.LandUseType.COMMERCIAL],
							existingStations=result.cargoStations[api.type.enum.LandUseType.COMMERCIAL],
							landUseType=api.type.enum.LandUseType.COMMERCIAL,
							isCargo=true}
						townPanel.buildNewTownBusStop(param)
					end)
				end 
				if result.industrialTruckStop ~= nil and result.industrialCargoCoverage < cargoThreshold then 
					trace("adding industrial cargo stop for town",result.town.name," based on coverage",result.industrialCargoCoverage)
					townPanel.addWork(function() 
							
						local param = {
							town=result.town.id, 
							buildingsWithoutCoverage=result.industrialBuildingsWithoutCargoCoverage, 
							truckStop = result.industrialTruckStop,
							catchmentEdges = result.cargoCatchmentEdges[api.type.enum.LandUseType.INDUSTRIAL],
							landUseType=api.type.enum.LandUseType.INDUSTRIAL,
							existingStations=result.cargoStations[api.type.enum.LandUseType.INDUSTRIAL],
							isCargo=true}
						townPanel.buildNewTownBusStop(param)
					end)
				end
			end
		end 
	end 
end 

function townPanel.buildNewFullTruckStation(param)
	trace("buildNewFullTruckStation:Begin")
	util.lazyCacheNode2SegMaps()
	local townId = param.town
		local edges = {}
	local positions = {}
	local alreadySeen = {}
	for i, buildingId in pairs(param.buildingsWithoutCoverage) do 
		local building = util.getComponent(buildingId, api.type.ComponentType.TOWN_BUILDING)
		if building then 
			local parcel = util.getComponent(building.parcels[1], api.type.ComponentType.PARCEL)
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(buildingId)
			if not alreadySeen[constructionId] then 
				alreadySeen[constructionId] = true
				table.insert(positions,  util.getConstructionPosition(constructionId))
				if not edges[parcel.streetSegment] then 
					edges[parcel.streetSegment] = true 
				end
			end
		end
	end 
	
	local stations = {}
	local p = game.interface.getEntity(townId).position
	for i ,station in pairs(util.searchForEntities(p, 1000, "STATION")) do
		if station.carriers.ROAD and station.cargo and api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station.id) ~= -1 then 
			table.insert(stations, station.id)
		end
		
	end
	local function getDistToClosestStation(p) 
		local dists = {}
		for __, stationId in pairs(stations) do 
			table.insert(dists, util.distance(p, util.getStationPosition(stationId)))
		end		
		table.sort(dists)
		return dists[1]
	end
	local options = {} 
	local centralStation = param.centralCargoStation
	local centralP = util.getStationPosition(centralStation)
	for edgeId, bool in pairs(edges) do 
		if param.catchmentEdges[edgeId] or not edgeIsOk(edgeId) then 
			goto continue 
		end
		local edgeMidPoint = util.getEdgeMidPoint(edgeId)
		local sum = 0 
		local outOfRange = 0 
		for i, position in pairs(positions) do 
			local dist =  util.distance(edgeMidPoint, position)
			sum = sum + math.min(300,dist)
			if dist > 300 then 
				outOfRange = outOfRange + 1
			end
		end 
		local stationScore = math.abs(500-getDistToClosestStation(edgeMidPoint))
		if util.distance(centralP, edgeMidPoint) > 250 then 
			table.insert(options, {
				edgeId = edgeId,
				scores = {sum, outOfRange, stationScore}
			})
		end
		::continue::
	end 
	if #options > 0 then
		local best = util.evaluateWinnerFromScores(options)
		local existingStation = param.centralCargoStation
		local function callback(res, success) 
			if success then 
				local construction = util.getConstruction(res.resultEntities[1])
				local newStation = construction.stations[1]
				lineParams = { cargoType = "MAIL"}
				townPanel.addWork(function() lineManager.setupTruckLine({existingStation, newStation}, lineParams, result) end ) 
			end  
		end
		trace("About to attempt to build cargoRoadStaiton Nearest Edge")
		constructionUtil.buildCargoRoadStationNearestEdge(townId, util.getEdgeMidPoint(best.edgeId), existingStation, callback)
	end 
end 

function townPanel.buildNewTownBusStop(param)
	trace("Begin building new town bus stop")
	util.lazyCacheNode2SegMaps()
	local townId = param.town
	if not param.busStation and not param.isCargo then 
		townPanel.buildNewTownBusNetwork(param)
		return 
	end 
	local edges = {}
	local positions = {}
	local alreadySeen = {}
	for i, buildingId in pairs(param.buildingsWithoutCoverage) do 
		local building = util.getComponent(buildingId, api.type.ComponentType.TOWN_BUILDING)
		if building then 
			local parcel = util.getComponent(building.parcels[1], api.type.ComponentType.PARCEL)
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForTownBuilding(buildingId)
			if not alreadySeen[constructionId] then 
				alreadySeen[constructionId] = true
				table.insert(positions,  util.getConstructionPosition(constructionId))
				if not edges[parcel.streetSegment] then 
					edges[parcel.streetSegment] = true 
				end
			end
		end
	end 
	local function getDistToClosestStation(p) 
		local dists = {}
		for stationId, __ in pairs(param.existingStations) do 
			table.insert(dists, util.distance(p, util.getStationPosition(stationId)))
		end		
		table.sort(dists)
		return dists[1]
	end
	local options = {} 
	for edgeId, bool in pairs(edges) do 
		if param.catchmentEdges[edgeId] or not edgeIsOk(edgeId) then 
			goto continue 
		end
		local edgeMidPoint = util.getEdgeMidPoint(edgeId)
		local sum = 0 
		local outOfRange = 0 
		for i, position in pairs(positions) do 
			local dist =  util.distance(edgeMidPoint, position)
			sum = sum + math.min(300,dist)
			if dist > 300 then 
				outOfRange = outOfRange + 1
			end
		end 
		local stationScore = math.abs(500-getDistToClosestStation(edgeMidPoint))
		table.insert(options, {
			edgeId = edgeId,
			scores = {sum, outOfRange, stationScore}
		})
		::continue::
	end 
	if #options > 0 then
		local edgeId = util.evaluateWinnerFromScores(options).edgeId 
		if param.isCargo then 
			local baseStation = lineManager.getSourceStationForTruckStop(param.truckStop)
			local shouldExtend = util.distBetweenStations(param.truckStop, baseStation) > 1000 
			local lineId = lineManager.findLineConnectingStations(baseStation, param.truckStop)
			local name = util.getComponent(param.town, api.type.ComponentType.NAME).name.." ".._("Supplemental delivery")
			
			local edge = util.getEdge(edgeId)
			local node1 = edge.node1
			local node0 = edge.node0
			local params =lineManager.getLineParams(lineId) 
			params.lineName = util.getComponent(lineId, api.type.ComponentType.NAME).name.." ".._("Supplemental")
			params.targetThroughput = 25
			params.totalTargetThroughput= 25
			local function callback(res, success) 
				if success then 
					trace("Built new truck stop now completing")
					if shouldExtend then 
						townPanel.addWork(function() lineManager.extendLine(lineId,util.findStopBetweenNodes(node0, node1))end)
					else 
						townPanel.addWork(function() constructionUtil.checkBusStationForUpgrade(baseStation) end)
						townPanel.addDelayedWork(function() lineManager.setupTruckLine({baseStation,util.findStopBetweenNodes(node0, node1)} , params)  end)
					end
				end 
			end 
			constructionUtil.buildTruckStopOnProposal(edgeId, name, callback)
		else 
			local name = util.getComponent(param.town, api.type.ComponentType.NAME).name.." ".._("Bus Stop").." "..tostring(#util.getBusStopsForTown(param.town)+1)
			local p = util.getEdgeMidPoint(edgeId)
			local node0 = util.getEdge(edgeId).node0
			local node1 = util.getEdge(edgeId).node1
			local function callback(res, success) 
				if success then 
					townPanel.addWork(function() 
						trace("Built new bus stop now completing")
						local stopId = util.findStopBetweenNodes(node0, node1)
						local nearestPassengerStation = util.searchForNearestStation(p, 500, function(station)
							return not station.cargo and station.id ~= stopId	
						end)
						
						
						if nearestPassengerStation and  util.isBusStop(nearestPassengerStation) and #api.engine.system.lineSystem.getLineStopsForStation(nearestPassengerStation) == 1 
						and #util.getLine(api.engine.system.lineSystem.getLineStopsForStation(nearestPassengerStation)[1]).stops == 2 then 
							townPanel.addWork(function() 
								lineManager.extendLine(api.engine.system.lineSystem.getLineStopsForStation(nearestPassengerStation)[1], stopId)
							end)
						else 
							local excludeFull = true
							local bestBusStation = util.findBusStationForTown(townId, p, excludeFull)
							if not bestBusStation then 
								trace("No available bus station found, attempting to place new station")
								local startPosition = util.v3fromArr(util.getEntity(townId).position)
								local function thisCallback(res, success) 
									if success then 
										local construction = util.construction(res.resultEntities[1])
										townPanel.addDelayedWork(function() lineManager.setupBusLineBetweenStations(construction.stations[1], stopId, params) end)
									end 
								end 
								constructionUtil.buildBusStationNearestEdge(townId, startPosition, existingStation, thisCallback)
							else   
								townPanel.addWork(function() constructionUtil.checkBusStationForUpgrade(bestBusStation) end)
								--townPanel.addDelayedWork(function() lineManager.setupTownBusNetwork(bestBusStation, param.town) end)
								townPanel.addDelayedWork(function() lineManager.setupBusLineBetweenStations(bestBusStation, stopId, params) end)
							end
						end
					end)
				end 
			end 
			constructionUtil.buildBusStopEdge(edgeId, name, callback) 
		end
	end 
	
end

function townPanel.addBusLanes(params) 
	local townLines = lineManager.getBusAndTramLinesForTown(params.town) 
	local edges = {} 
	local alreadySeen = {}
	for __, lineId in pairs(townLines) do 
		local line = lineManager.getLine(lineId) 
		for i = 1 , #line.stops do 
			
			local priorStop = i==1 and line.stops[#line.stops] or line.stops[i-1]
			local stop = line.stops[i]
			local station1 =lineManager.stationFromStop(priorStop)
			local station2 = lineManager.stationFromStop(stop)
			if params.addTrams then 
				constructionUtil.checkBusStationForUpgradeTramOnly(station1) 
				constructionUtil.checkBusStationForUpgradeTramOnly(station2) 
				local mainStation 
				if not util.isBusStop(station1) then 
					mainStation= station1 
				elseif not util.isBusStop(station2) then 
					mainStation = station2 
				end 
				if mainStation then 
				
					local roadDepot = constructionUtil.searchForRoadDepot(util.getStationPosition(mainStation), 100)
						trace("Looking for road depot near",mainStation, " found ",roadDepot)
					if roadDepot and not alreadySeen[roadDepot] then 
						alreadySeen[roadDepot]=true
						townPanel.addWork(function() constructionUtil.replaceRoadDepotWithTramDepot(roadDepot) end)
					end 
				end
			end 
		
			local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station1 ,station2)
			for j = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
				local edgeId = routeInfo.edges[j].id
				if not edges[edgeId] and util.getStreetTypeCategory(edgeId) == "urban" then 
					edges[edgeId]=true
				end 
			end 
			if #line.stops == 2 then 
				break 
			end
		end 
	end 
	local streetType = api.res.streetTypeRep.find("standard/town_large_new.lua")
	for edgeId , bool in pairs(edges) do 
		if not util.getStreetEdge(edgeId).hasBus then 
			local entity = util.copyExistingEdge(edgeId, -1)
			if params.addBusLanes then 
				entity.streetEdge.hasBus = true 
				if util.getNumberOfStreetLanes(edgeId) < 6 then -- street lanes includes pedestrian lanes 
					entity.streetEdge.streetType = streetType 
				end 
			end 
			if params.addTrams then 
				entity.streetEdge.tramTrackType=util.getCurrentTramTrackType()
			end 
			-- upgrade one segment at a time, doing multiple segments can confuse the building reposition algorithm
			local newProposal = api.type.SimpleProposal.new() 
			newProposal.streetProposal.edgesToAdd[1]=entity 
			newProposal.streetProposal.edgesToRemove[1]=edgeId 
			local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
			api.cmd.sendCommand(build )
		end
	end
	if params.addTrams then 
		townPanel.addDelayedWork(function() lineManager.upgradeToTramLines(townLines) end)
	end 
end

return townPanel