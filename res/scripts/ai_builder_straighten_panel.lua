local util = require("ai_builder_base_util") 
local constructionUtil = require("ai_builder_construction_util")
local lineManager = require("ai_builder_line_manager")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local routeBuilder = require("ai_builder_route_builder")
local paramHelper = require("ai_builder_base_param_helper")
local straightenPanel = {}
local   trace = util.trace

local function makelocateRow(edgeId)
	local boxLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL"); 
	local imageView = api.gui.comp.ImageView.new("ui/button/xxsmall/locate.tga")
	local button = api.gui.comp.Button.new(imageView, true)
	button:onClick(function() 
		api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(edgeId, false)
	end) 
	return button
end  
function straightenPanel.buildFilterPanel() 
	 
	local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local all = util.newToggleButton("", "ui/construction/categories/all@2x.tga") 
	local rail = util.newToggleButton("", "ui/icons/construction-menu/category_tracks@2x.tga") 
	local road = util.newToggleButton("", "ui/icons/construction-menu/category_street@2x.tga") 
	local highway = util.newToggleButton("", "ui/construction/categories/highway@2x.tga") 
 
	
	all:setTooltip(_("Show all"))
	rail:setTooltip(_("Track only"))
	road:setTooltip(_("Roads only"))
	highway:setTooltip(_("Highway only")) 
	 
	all:setSelected(true, false)
	buttonGroup:add(all)
	buttonGroup:add(rail)
	buttonGroup:add(road)
	buttonGroup:add(highway) 
	return {
		panel = buttonGroup,
		filterFn = function(edgeId, isTrack) 
			if road:isSelected() then 
				return not isTrack and not util.isOneWayStreet(edgeId)
			end 
			if rail:isSelected() then 
				return isTrack
			end 
			if highway:isSelected() then 
				return not isTrack and util.getStreetTypeCategory(edgeId)=="highway" and util.findParallelHighwayEdge(edgeId)
			end  
			return true 
		end,  
	}
end 
local function getEdgesReport(circle, filterFn)
	if not filterFn then filterFn = function() return true end end
	local results = {}
	util.lazyCacheNode2SegMaps()
	for __, edgeId in pairs(game.interface.getEntities(circle, {type="BASE_EDGE"})) do 
		local edge = util.getEdge(edgeId)
		if #util.getSegmentsForNode(edge.node0) ~= 2 or #util.getSegmentsForNode(edge.node1)~=2 then 
			goto continue 
		end
		local isTrack = util.getTrackEdge(edgeId)~=nil
		if not filterFn(edgeId, isTrack) then 
			goto continue 
		end
		local isHighway = not isTrack and util.getStreetTypeCategory(edgeId)=="highway"
		
		local tn = util.getComponent(edgeId, api.type.ComponentType.TRANSPORT_NETWORK)
		local minCurSpeed = math.huge 
		local minCurveSpeedLimit = math.huge 
		local speedLimit = math.huge
		for _, t in pairs(tn.edges) do
			if t.curSpeed > 0 then 
				minCurSpeed = math.min(t.curSpeed, minCurSpeed)
			end 
			if t.curveSpeedLimit > 0 then 
				minCurveSpeedLimit = math.min(t.curveSpeedLimit, minCurveSpeedLimit)
			end
			if t.speedLimit > 0 then 
				 speedLimit = math.min(t.speedLimit, speedLimit)
			end 
			trace("The speed limit was",speedLimit," the t.speedLimit was",t.speedLimit)
		end 
		
		if minCurveSpeedLimit < speedLimit then 
			table.insert(results, {
				edgeId = edgeId, 
				curSpeed = minCurSpeed,
				isTrack = isTrack,
				isHighway = isHighway,
				curveSpeedLimit = math.min(minCurveSpeedLimit, speedLimit),
				speedLimit = speedLimit,
				scores = {
					--minCurSpeed,
					minCurveSpeedLimit,
				}
			})
		end
		::continue::
	end 
	util.clearCacheNode2SegMaps()
	return util.evaluateAndSortFromScores(results)
end 

local function makeEdgeTypeRow(report) 
	
	local repo 
	if report.isTrack then 
		repo = api.res.trackTypeRep.get(util.getTrackEdge(report.edgeId).trackType)
	else	 
		repo = api.res.streetTypeRep.get(util.getStreetEdge(report.edgeId).streetType)
	end 
	local icon = repo.icon
	if not icon then 
		icon = report.isTrack and "ui/icons/construction-menu/category_tracks@2x.tga" or "ui/icons/construction-menu/category_street@2x.tga"
	end
	 	
	local imageView  = api.gui.comp.ImageView.new(icon)
	if repo.name then 
		imageView:setTooltip(repo.name)
	end
	local maxSize = 36 
	imageView:setMaximumSize(api.gui.util.Size.new( maxSize, maxSize ))
	return imageView 
end 	
local function newSlider( )
	local sliderLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	sliderLayout:addItem(api.gui.comp.TextView.new(_("Max adjacent edges to replace")))
	local valueDisplay = api.gui.comp.TextView.new("3")
	local slider = api.gui.comp.Slider.new(true) 
	slider:setMinimum(1)
	slider:setMaximum(30)
	slider:setStep(1)
	slider:setPageStep(1)
	local size = slider:calcMinimumSize()
	size.w = size.w+60
	slider:setMinimumSize(size)
	slider:onValueChanged(function(x)  
		valueDisplay:setText(tostring(x)) 
	end)
	sliderLayout:addItem(slider)
	sliderLayout:addItem(valueDisplay)
	return sliderLayout, slider
end 

function straightenPanel.buildStraightenPanel(circle) 
	local boxLayout = api.gui.layout.BoxLayout.new("VERTICAL");
	
	local colHeaders = {
		api.gui.comp.TextView.new(_("Jump")),
		api.gui.comp.TextView.new(_("Type")),
		api.gui.comp.TextView.new(_("Speed limit")),
		api.gui.comp.TextView.new(_("Curve Speed limit ")),
		api.gui.comp.TextView.new(_("Upgrade")), 
	}
	local maxRows = 10
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	local allButtons = {}
	local numEdges = 5
	local sliderLayout, slider = newSlider( )
	local buttonGroup, standard, elevated, underground = util.createElevationButtonGroup( ) 
	local filterPanel = straightenPanel.buildFilterPanel() 
	boxLayout:addItem(filterPanel.panel)	
	boxLayout:addItem(buttonGroup)
	boxLayout:addItem(sliderLayout)
	local removeTrackOnlyChkbox  = api.gui.comp.CheckBox.new(_("Remove segments only (for manual rebuild)"))
	boxLayout:addItem(removeTrackOnlyChkbox)
	local replaceGradeCrossings  = api.gui.comp.CheckBox.new(_("Replace grade crossings?"))
	boxLayout:addItem(replaceGradeCrossings)
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	displayTable:setHeader(colHeaders)
	local function refresh ( )
		local edgesReport = getEdgesReport(circle, filterPanel.filterFn)
		trace("Being refresh straightenPanel table, got " ,#edgesReport," to report")
		displayTable:deleteAll()
		allButtons = {}
		
		local count = 0
		for i = 1, math.min(maxRows, #edgesReport) do
			trace("Building line row for ",lineId)
			local report = edgesReport[i]
			 
			local button = util.newMutilIconButton("ui/button/medium/streetbuildermode_curved@2x.tga","ui/design/window-content/arrow_style1_20px_right@2x.tga", "ui/button/medium/streetbuildermode_straight@2x.tga")
			table.insert(allButtons, button)
			
			button:onClick(function() 
				lineManager.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("ai_builder_script","doStraighten", "", {
					edgeId=report.edgeId, 
					numEdges = slider:getValue(),
					isTrack = report.isTrack,
					isHighway = report.isHighway,
					removeTrackOnly = removeTrackOnlyChkbox:isSelected(),
					isElevated = elevated:isSelected(),
					isUnderground = underground:isSelected(),
					replaceGradeCrossings = replaceGradeCrossings:isSelected(),
					}))
				end) 
				lineManager.addWork(function() 
					for j = 1, #allButtons do 
						allButtons[j]:setEnabled(false)
					end 
				
				end) 			
			end)
			displayTable:addRow({
				 makelocateRow(report.edgeId),
				 makeEdgeTypeRow(report),
				 api.gui.comp.TextView.new(api.util.formatSpeed(report.speedLimit)),
				 api.gui.comp.TextView.new(api.util.formatSpeed(report.curveSpeedLimit)),
				button
			})
		end 
	end
	 
 	boxLayout:addItem(displayTable)
	local bottomLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL");
	
	local refreshButton = util.newButton(_("Refresh"),"ui/button/xxsmall/replace@2x.tga")
	bottomLayout:addItem(refreshButton)
	local moreButton  = util.newButton(_('Show More'), "ui/button/xxsmall/down_thin@2x.tga")
	bottomLayout:addItem(moreButton)
	
	boxLayout:addItem(bottomLayout)
	moreButton:onClick(function()  
		maxRows = 2*maxRows
		lineManager.addWork(refresh)
	end)
	refreshButton:onClick(function()
		lineManager.addWork(refresh)
	end)
	local comp= api.gui.comp.Component.new(" ")
	comp:setLayout(boxLayout)
	local isInit = false
	return {
		comp = comp,
		title = util.textAndIcon("STRAIGHTEN", "ui/button/medium/speed_limits@2x.tga"),
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

local function checkForDepotSegments(depotConstrId, edgesToRemove, param)
	if not depotConstrId then 
		return false 
	end
	local depotConstr = util.getConstruction(depotConstrId)
	local nextEdgeId = depotConstr.frozenEdges[1]
	local nextNode = util.getEdge(nextEdgeId).node1 
	if #util.getTrackSegmentsForNode(nextNode)==1 then 
		return false 
	end 
	local count = 0
	repeat 
		count = count + 1
		nextEdgeId = util.findNextEdgeInSameDirection(nextEdgeId, nextNode)
		if not util.contains(edgesToRemove, nextEdgeId) then 
			table.insert(edgesToRemove, nextEdgeId)
		end
		local nextEdge = util.getEdge(nextEdgeId)
		nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
	until #util.getTrackSegmentsForNode(nextNode)==3 or count > 10
	param.reconnectDepotAfter = true 
	if not param.depots then 
		param.depots = {} 
		
	end
	table.insert(param.depots, depotConstr.depots[1])
	return true
end

function straightenPanel.doStraighten(param) 
	trace("Got instruction to straighten edge",param.edgeId, " numEdges=",param.numEdges)
	util.lazyCacheNode2SegMaps() 
	local edgesToReplace = {}
	local leftMostEdge 
	local leftMostNode 
	local rightMostEdge
	local rightMostNode
	local edge =util.getEdge(param.edgeId)
	edgesToReplace[param.edgeId]=true
	local nextNode = edge.node1 
	local nextEdgeId = param.edgeId
	local highSpeedTrack = api.res.trackTypeRep.find("high_speed.lua")
	local count = 0
	local function segmentCount(node) 
		if param.replaceGradeCrossings then
			if param.isTrack then 
				return #util.getTrackSegmentsForNode(node)
			else 
				return #util.getStreetSegmentsForNode(node)
			end 
		else 
			return #util.getSegmentsForNode(node)
		end 
	end 
	for i = 1, param.numEdges do 
		
		local priorEdge = nextEdgeId
		nextEdgeId = util.findNextEdgeInSameDirection(nextEdgeId, nextNode)
		if not nextEdgeId or util.isFrozenEdge(nextEdgeId) or segmentCount(nextNode) ~= 2 or param.isHighway and not util.findParallelHighwayEdge(nextEdgeId) then 
			rightMostEdge = priorEdge
			rightMostNode = nextNode
			break
		end 
		count = count+1
		edgesToReplace[nextEdgeId]=true
		if param.isHighway then 
			edgesToReplace[util.findParallelHighwayEdge(nextEdgeId)]=true
		end 
		local nextEdge = util.getEdge(nextEdgeId) 
		nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0 
		if i == param.numEdges then 
			rightMostEdge = nextEdgeId
			rightMostNode = nextNode
		end 
	end 
	local nextNode = edge.node0
	local nextEdgeId = param.edgeId
	for i = 1, param.numEdges do 
		
		local priorEdge = nextEdgeId
		nextEdgeId = util.findNextEdgeInSameDirection(nextEdgeId, nextNode)
		if not nextEdgeId or util.isFrozenEdge(nextEdgeId) or segmentCount(nextNode) ~= 2 or param.isHighway and not util.findParallelHighwayEdge(nextEdgeId)  then 
			leftMostEdge = priorEdge
			leftMostNode = nextNode
			break
		end 
		count = count+1
		edgesToReplace[nextEdgeId]=true
		if param.isHighway then 
			edgesToReplace[util.findParallelHighwayEdge(nextEdgeId)]=true
		end 
		local nextEdge = util.getEdge(nextEdgeId) 
		nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0 
		if i == param.numEdges then 
			leftMostEdge = nextEdgeId
			leftMostNode = nextNode
		end 
	end 
	local nodePair = { leftMostNode, rightMostNode }
	local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", param.isTrack)
	params.isElevated = param.isElevated 
	params.isUnderground = param.isUnderground
	if param.isTrack then 
		local depot1 =  constructionUtil.searchForRailDepot(util.nodePos(leftMostNode), 150)
		local depot2 =  constructionUtil.searchForRailDepot(util.nodePos(rightMostNode),150)
		if depot1 or depot2 then 
			local edgesToRemove = {}
			if checkForDepotSegments(depot1, edgesToRemove, param) or checkForDepotSegments(depot2, edgesToRemove, param) then 
				local function callbackThis(res, success) 
					util.clearCacheNode2SegMaps()
					if success then 
						lineManager.addWork(function() straightenPanel.doStraighten(param) end)
					end 
				end 
				local newProposal = routeBuilder.setupProposalAndDeconflict({}, {}, {}, edgesToRemove )
				local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
				trace("About to sent command remove edges")
				api.cmd.sendCommand(build,callbackThis)
				return
			end 
			
		end 
		
		local trackEdge = util.getTrackEdge(param.edgeId)
		params.isHighSpeedTrack = trackEdge.trackType == highSpeedTrack
		params.isElectricTrack = trackEdge.catenary
		local alternativeNodePairs = {}
		local otherLeftNodes = {} 
		local otherRightNodes = {}
		local alreadySeen = { [leftMostNode]=true, [rightMostNode]=true }
		for i = 1, 10 do 
			local trackOffset = math.floor(i/2) -- to scan on both sides
			local otherLeftNode = util.findDoubleTrackNode(leftMostNode, nil, trackOffset, 1, true, alreadySeen)
			if otherLeftNode then 
				alreadySeen[otherLeftNode]=true 
				table.insert(otherLeftNodes, otherLeftNode)
			end 
			local otherRightNode = util.findDoubleTrackNode(rightMostNode, nil, trackOffset, 1, true, alreadySeen)
			if otherRightNode then 
				alreadySeen[otherRightNode]=true 
				table.insert(otherRightNodes, otherRightNode)
			end 
		end 
		local rightAlreadySeen = {}
		for i = 1, #otherLeftNodes do 
			for j = 1, #otherRightNodes do
				local routeInfo = pathFindingUtil.getRailRouteInfoBetweenNodesIncludingReversed(otherLeftNodes[i], otherRightNodes[j])
				if routeInfo then 
					for k = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
						if not edgesToReplace[routeInfo.edges[k].id] then 
							edgesToReplace[routeInfo.edges[k].id]=true
							local trackEdge = util.getTrackEdge(routeInfo.edges[k].id)
							params.isElectricTrack = params.isElectricTrack or trackEdge.catenary
							params.isHighSpeedTrack = params.isHighSpeedTrack or trackEdge.trackType == highSpeedTrack
						end 
					end 
					table.insert(alternativeNodePairs, {otherLeftNodes[i], otherRightNodes[j]})
				end 
			end 
		end
		if params.isHighSpeedTrack then 
			params.setForVeryHighSpeed() 
		end
		trace("Found alternativeNodePairs:",#alternativeNodePairs, " from ",#otherLeftNodes," and ",#otherRightNodes)
		if #alternativeNodePairs > 0 then 
			params.isDoubleTrack = true 
			table.insert(nodePair, alternativeNodePairs[1][1])
			table.insert(nodePair, alternativeNodePairs[1][2])
		end 
		if #alternativeNodePairs > 2 then 
			params.isQuadrupleTrack = true 
			local midPoint = util.nodePos(leftMostNode)
			local allNodePairs = { nodePair}
			for i = 1, #alternativeNodePairs do
				local nodePair = alternativeNodePairs[i]
				midPoint = midPoint + util.nodePos(nodePair[1])
				table.insert(allNodePairs, nodePair)
			end 
			midPoint = (1/#allNodePairs)*midPoint
			allNodePairs = util.evaluateAndSortFromSingleScore(allNodePairs, function(nodePair) return util.distance(util.nodePos(nodePair[1]), midPoint) end, 2)
			-- need center most node pair
			nodePair = {
				allNodePairs[1][1],
				allNodePairs[1][2],
				allNodePairs[2][1],
				allNodePairs[2][2],
			}
			
			
		--	table.insert(nodePair, alternativeNodePairs[1][1])
		--	table.insert(nodePair, alternativeNodePairs[1][2])
		end 
	else 	
		local streetEdge = util.getStreetEdge(param.edgeId)
		params.tramTrackType = streetEdge.tramTrackType
		params.addBusLanes = streetEdge.hasBus
		if param.isHighway then 
			params.setForHighway()
			params.preferredHighwayRoadType=streetEdge.streetType
			local otherLeftNode = util.findParallelHighwayNode(leftMostNode)
			local otherRightNode = util.findParallelHighwayNode(rightMostNode)
			table.insert(nodePair, otherLeftNode )
			table.insert(nodePair, otherRightNode)
			local routeInfo = pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(otherLeftNode, otherRightNode) or pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(otherRightNode, otherLeftNode)
			for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
				local edgeId = routeInfo.edges[i].id
				if not edgesToReplace[edgeId] and not util.isJunctionEdge(edgeId) then 
					edgesToReplace[edgeId]=true
				end 
			end 
		else 
			params.preferredCountryRoadType=streetEdge.streetType
			params.preferredCountryRoadTypeWithBus=streetEdge.streetType
		end 
	end 
	local edgesToRemove = util.getKeysAsTable(edgesToReplace)
	local newProposal = routeBuilder.setupProposalAndDeconflict({}, {}, {}, edgesToRemove, edgeObjectsToRemove)
	if util.tracelog then debugPrint({nodePair=nodePair, edgesToRemove=edgesToRemove, newProposal=newProposal}) end
	
	 
	-- set these to very small values to keep the ultimate curve close to the hermite curve. We still use route evaluation to avoid a hard collision e.g. with industry
	params.routeDeviationPerSegment = 5
	params.routeEvaluationLimit = 100
	params.outerIterations = 5
	params.routeEvaluationOffsetsLimit = 2
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	trace("About to sent command remove edges")
	api.cmd.sendCommand(build, function(res, success) 
		trace("Result of removing edges was ",success)
		util.clearCacheNode2SegMaps()
		if success and not param.removeTrackOnly then 
			routeBuilder.addWork(function() routeBuilder.buildRoute(nodePair, params, function(res, success)
					util.clearCacheNode2SegMaps()
					if param.reconnectDepotAfter then 
						for __, depot in pairs(param.depots) do 
							routeBuilder.addWork(function() routeBuilder.buildDepotConnection(routeBuilder.standardCallback, depot, params)end)
						end
					end 
				end)
			end)
		end 
		 
	end)
end  

return straightenPanel