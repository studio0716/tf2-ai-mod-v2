local util = require("ai_builder_base_util") 
local constructionUtil = require("ai_builder_construction_util")
local lineManager = require("ai_builder_line_manager")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local vehicleUtil = require("ai_builder_vehicle_util")
local routeBuilder = require("ai_builder_route_builder")
local stationTemplateHelper = require("ai_builder_station_template_helper")
local paramHelper = require("ai_builder_base_param_helper")
local upgradesPanel = {}
local trace = util.trace
local formatTime = util.formatTime

local function sendScriptEvent(lineId, upgrade)
	upgradesPanel.addWork(function()
		api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","doUpgrade", "", {lineId=lineId, upgrade=upgrade}),upgradesPanel.standardCallback)
	end)
end

local function buildUpgradesButtons(report) 
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	
	if report.isBusLine or report.isTramLine then 
		local addBusLanesButton = util.newButton("Add bus lanes", "ui/streets/bus_new@2x.tga")
		
		boxLayout:addItem(addBusLanesButton)
		addBusLanesButton:onClick(function() 
			sendScriptEvent(report.lineId, "addBusLanes")
			addBusLanesButton:setEnabled(false)
		end)
		if report.isTramLine then 
			local removeTramsButton = util.newButton("Convert to bus line", "ui/button/large/bus.tga")
			boxLayout:addItem(removeTramsButton)
			removeTramsButton:onClick(function() 
				sendScriptEvent(report.lineId, "convertToBusLine")
				removeTramsButton:setEnabled(false)
			
			end)
		else 
			local addTramsButton = util.newButton("Convert to tram line", "ui/button/large/tram.tga")
			boxLayout:addItem(addTramsButton)
			addTramsButton:onClick(function() 
				sendScriptEvent(report.lineId, "convertToTramLine")
				addTramsButton:setEnabled(false) 
			end)
		end
		
		--
	end 
	if report.isAirLine then 
		local secondRunwayAvailable = util.isSecondRunwayAvailable()
		local line = util.getLine(report.lineId)
		local canUpgrade = false 
		for i, stop in pairs(line.stops) do 
			local station = util.stationFromStop(stop)
			local construction = util.getConstructionForStation(station)
			if secondRunwayAvailable and construction.fileName == "station/air/airport.con" and not construction.params.modules[stationTemplateHelper.secondRunwaySlotId] then 
				canUpgrade= true 
				break
			end
		end 
		if canUpgrade then 
			local upgradeAirport = util.newButton("Add second runway" )
			boxLayout:addItem(upgradeAirport)
			upgradeAirport:onClick(function() 
				sendScriptEvent(report.lineId, "addSecondRunway")
				upgradeAirport:setEnabled(false) 
			end) 
		end 
	end 
	if report.isRailLine then 
		if report.routeInfos and report.routeInfos[1] then 
			if not report.routeInfos[1].isDoubleTrack then 
				local doubleTrackButton = util.newButton("Double track" )
				boxLayout:addItem(doubleTrackButton)
				doubleTrackButton:onClick(function() 
					sendScriptEvent(report.lineId, "doubleTrackUpgrade")
					doubleTrackButton:setEnabled(false) 
				end) 
			end
			for i, routeInfo in pairs(report.routeInfos) do  
				if not routeInfo.isElectricTrack then 
					local electricTrackButton = util.newButton("Electric track" )
					boxLayout:addItem(electricTrackButton)
					electricTrackButton:onClick(function() 
						sendScriptEvent(report.lineId, "electricTrackUpgrade")
						electricTrackButton:setEnabled(false) 
					end) 
					break
				end 
			end
			for i, routeInfo in pairs(report.routeInfos) do  
				if not routeInfo.isHighSpeedTrack then 
					local highSpeedButton = util.newButton("High-speed track" )
					boxLayout:addItem(highSpeedButton)
					highSpeedButton:onClick(function() 
						sendScriptEvent(report.lineId, "highSpeedTrackUpgrade")
						highSpeedButton:setEnabled(false) 
					end) 
					break
				end
			end
		end 
		if report.stationLength < paramHelper.getMaxStationLength() then 
			local lengthenButton = util.newButton("Increase station length" )
			boxLayout:addItem(lengthenButton)
			lengthenButton:onClick(function() 
				sendScriptEvent(report.lineId, "stationLengthUpgrade")
				lengthenButton:setEnabled(false) 
			end) 
		end 
	end 
	if not report.hasDoubleTerminals  then 
		local doubleTerminalButton = util.newButton("Add double terminals" )
		boxLayout:addItem(doubleTerminalButton)
		doubleTerminalButton:onClick(function() 
			sendScriptEvent(report.lineId, "doubleTerminalUpgrade")
			doubleTerminalButton:setEnabled(false) 
		end) 
	end 
	local comp= api.gui.comp.Component.new(" ")
	comp:setLayout(boxLayout)
	return comp
end 

function upgradesPanel.buildUpgradesPanel(circle) 
	local boxLayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local maxReports = 10
	local colHeaders = {
		api.gui.comp.TextView.new(_("Line")),
		api.gui.comp.TextView.new(_("Current\n rate")),
		api.gui.comp.TextView.new(_("Demand\nrate")),
		api.gui.comp.TextView.new(_("Vehicles")),
		api.gui.comp.TextView.new(_("Stops")),
		api.gui.comp.TextView.new(_("Ticket\nprice")),
		api.gui.comp.TextView.new(_("Route\nlength")),
		api.gui.comp.TextView.new(_("Interval")),
		api.gui.comp.TextView.new(_("Totaltime")),
		api.gui.comp.TextView.new(_("topSpeed")),
		api.gui.comp.TextView.new(_("averageSpeed")),
	
		api.gui.comp.TextView.new(_("Profit")),
		api.gui.comp.TextView.new(_("Vehicle config")), 	
		api.gui.comp.TextView.new(_("Upgrades")), 
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	displayTable:setHeader(colHeaders)
	local vehicleFilter = lineManager.buildVehicleFilterPanel() 
	boxLayout:addItem(vehicleFilter.panel)
	local function refreshTable(linesToReport, currentLineId)
		trace("Being refresh line manager table, got " ,#linesToReport," to report")
		if util.tracelog then debugPrint(linesToReport) end
		displayTable:deleteAll()
		local allButtons = {}
		local count = 0
		for i = 1, #linesToReport do
			trace("Building line row for ",lineId)
			local lineId = linesToReport[i]
			local line = util.getComponent(lineId, api.type.ComponentType.LINE)
			local isForVehicleReport = false
			local useRouteInfo = false 
			local displayOnly = true
			local report = lineManager.getLineReport(lineId, line, isForVehicleReport, useRouteInfo, displayOnly)
			
			displayTable:addRow({
				lineManager.makelocateRow(report),
				api.gui.comp.TextView.new(tostring(math.ceil(report.rate))),				
				api.gui.comp.TextView.new(tostring(math.ceil(report.targetLineRate))),
				api.gui.comp.TextView.new(tostring(report.existingVehicleCount)),
				api.gui.comp.TextView.new(tostring(report.stopCount)),
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.existingTicketPrice))),
				api.gui.comp.TextView.new(api.util.formatLength(math.floor(report.routeLength))),
				api.gui.comp.TextView.new(formatTime(report.totalExistingTime/report.existingVehicleCount)),
				lineManager.makeTimingsPanel(report.existingTimings, nil, report.impliedLoadTime),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.topSpeed)),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.averageSpeed)),
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.profit))),
				vehicleUtil.displayVehicleConfig(report.currentVehicleConfig, 80),
				buildUpgradesButtons(report),
			})
			if i == maxReports then 
				break 
			end
		end
		trace("The report found ", count, " lines needing attention")
		displayTable:setVisible( #linesToReport > 0, false)
		 
	end
	boxLayout:addItem(displayTable)
	local function refresh()  
		upgradesPanel.addWork(function() refreshTable(lineManager.getLines(circle, vehicleFilter.filterFn,maxReports))end) 
	end
	local buttonLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	local refreshButton  = util.newButton(_('Refresh'),"ui/button/xxsmall/replace@2x.tga")
	buttonLayout:addItem(refreshButton)
	local showMoreButton  = util.newButton(_('Show More'), "ui/button/xxsmall/down_thin@2x.tga")
	refreshButton:onClick(refresh)

	buttonLayout:addItem(showMoreButton)
	showMoreButton:onClick(function() 
		maxReports = 2*maxReports
		refresh()  
	end)
	vehicleFilter.setCallback(refresh)
	boxLayout:addItem(buttonLayout)
	local comp= api.gui.comp.Component.new(" ")
	comp:setLayout(boxLayout)
	local isInit = false
	return {
		comp = comp,
		title = util.textAndIcon("UPGRADES", "ui/small_button_arrow_up@2x.tga"),
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

function upgradesPanel.doUpgrade(param)
	local lineId = param.lineId 
	local upgrade = param.upgrade
	util.lazyCacheNode2SegMaps()
	local params = lineManager.getLineParams(lineId)
	if upgrade == "addBusLanes" then  
		params.setAddBusLanes(true)
		routeBuilder.checkRoadLineForUpgrade(upgradesPanel.standardCallback, params, lineId)
	end 
	if upgrade == "convertToTramLine" then
		params.tramTrackType = util.getCurrentTramTrackType()
		params.forTramConversion = true
		params.buildBusLanesWithTramLines = false
		routeBuilder.checkRoadLineForUpgrade(function(res, success) 
			trace("Attempt to add tram track was",success)
			if success then 
				upgradesPanel.addWork(function() lineManager.upgradeBusToTramLine(lineId) end)
			end 
		end, params, lineId)
	end
	if upgrade == "convertToBusLine" then 
		--routeBuilder.checkRoadLineForUpgrade(upgradesPanel.standardCallback, params, lineId)
		lineManager.convertTramToBusLine(lineId) 
	end
	if upgrade == "addSecondRunway" then 
		local line = util.getLine(lineId)
		local canUpgrade = false 
		for i, stop in pairs(line.stops) do 
			local station = util.stationFromStop(stop)
			local construction = util.getConstructionForStation(station)
			if construction.fileName == "station/air/airport.con" and not construction.params.modules[stationTemplateHelper.secondRunwaySlotId] then 
				local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
				local stationParams = util.deepClone(construction.params)
				stationParams.secondRunway = true
				stationParams.modules[stationTemplateHelper.secondRunwaySlotId] = "station/air/airport_2nd_runway.module"
				stationParams.seed = nil
				stationParams.modules = util.setupModuleDetailsForTemplate(stationTemplateHelper.createAirportTemplateFn(stationParams))   
				trace("About to execute upgradeConstruction for constructionId ",constructionId)
				
				game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)
				trace("About set player")
				game.interface.setPlayer(constructionId, game.interface.getPlayer())
			end
		end 
	end 
	if upgrade == "doubleTrackUpgrade" then 
		lineManager.upgradeToDoubleTrack(lineId)
	end
	if upgrade == "electricTrackUpgrade" then 
		lineManager.upgradeToElectricTrack(lineId)
	end
	if upgrade == "highSpeedTrackUpgrade" then 
		lineManager.upgradeToHighSpeedTrack(lineId)
	end
	if upgrade == "stationLengthUpgrade" then 
		lineManager.upgradeStationLength(lineId) 
	end
	if upgrade == "doubleTerminalUpgrade" then 
		lineManager.upgradeToDoubleTerminals(lineId) 
	end 
end
 
return upgradesPanel