local util = require("ai_builder_base_util") 
local paramHelper = require("ai_builder_base_param_helper")
local vec3 = require("vec3")
local vec2 = require("vec2")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local profiler = require("ai_builder_profiler")
local waterMeshUtil = require("ai_builder_water_mesh_util")

local trace = util.trace 
local noResolve = false
local function setPositionOnNode(newNode, p)
	newNode.comp.position.x = p.x
	newNode.comp.position.y = p.y
	newNode.comp.position.z = p.z
end
local routePreparation = {}

local function countNonRebuildOnlyCollisionSegs(collisionSegments)
	if not collisionSegments then 	
		return 0 
	end 
	local count = 0
	for i, seg in pairs(collisionSegments) do 
		if not seg.rebuildOnly then 
			count = count + 1 
		end 
	end 
	return count
end

local function maxBuildSlope(params) 
	if params.isTrack then 
		local trackType = params.isHighSpeedTrack and api.res.trackTypeRep.find("high_speed.lua") or api.res.trackTypeRep.find("standard.lua")
		return api.res.trackTypeRep.get(trackType).maxSlopeBuild
	else 
		return api.res.streetTypeRep.get(api.res.streetTypeRep.find(paramHelper.getParams().preferredCountryRoadType)).maxSlopeBuild
	end
end

local function edgeHasBuildings(edge)
	return not edge.track and util.getStreetTypeCategory(edge.id) == "urban" and util.getEdge(edge.id).type==0 and util.countNearbyEntities(util.getEdgeMidPoint(edge.id), 50, "TOWN_BUILDING") > 0
end

local function trialBuildBetweenPoints(lpos, pPos) 
	local entity = api.type.SegmentAndEntity.new()
	local newProposal = api.type.SimpleProposal.new()
	local newNode0 = util.newNodeWithPosition(lpos.p, -1)
	local newNode1 = util.newNodeWithPosition(pPos.p, -2)
	entity.type=1
	entity.trackEdge.trackType = api.res.trackTypeRep.find("standard.lua")
	entity.comp.node0=-1
	entity.comp.node1=-2
	entity.entity=-3
	util.setTangent(entity.comp.tangent0, lpos.t2)
	util.setTangent(entity.comp.tangent1, pPos.t)
	newProposal.streetProposal.nodesToAdd[1]=newNode0
	newProposal.streetProposal.nodesToAdd[2]=newNode1
	newProposal.streetProposal.edgesToAdd[1]=entity
	local testResult = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	local collisionEntities = {}
	for i, entity in pairs(testResult.collisionInfo.collisionEntities) do 
		table.insert(collisionEntities, {entity = entity.entity}) -- clone to avoid corrupted data
	end 
	return { isError = #testResult.errorState.messages > 0 or testResult.errorState.critical , 
		collisionEntities  = collisionEntities } 
end
local function areEdgesConnected(edge1, edge2)
	return edge1.node0 == edge2.node0 
		or edge1.node0 == edge2.node1
		or edge1.node1 == edge2.node1 
		or edge1.node1 == edge2.node0
end

local function edgeIsRemovable(edge, nodeOrder, numberOfNodes, params) 
	trace("Inspecting ",edge.id," to see if it is removable")
	if edge.track and util.isDepotLink(edge.id) then  
		if  params.allEdgesUsedByLines and not params.allEdgesUsedByLines()[edge.id] then 
			trace("Allowing edge",edge.id," to be removed as a depot link")
			params.reconnectDepotAfter = true
			params.depotPos = util.getEdgeMidPoint(edge.id)
			return true 
		end 
	end 
	if edge.track or util.isIndustryEdge(edge.id) then 
		return false 
	end 
	if util.isFrozenEdge(edge.id) then 
		return false 
	end
	if util.getEdge(edge.id).type ~= 0 then -- not a tunnel or bridge 
		return false 
	end
	if #util.getEdge(edge.id).objects > 0 then	
		return false 
	end
	if util.edgeHasTpLinks(edge.id) then 
		return false 
	end

	local hasDeadEnd = #util.getSegmentsForNode(edge.node1)==1
		or #util.getSegmentsForNode(edge.node0)==1
	trace("Edge has dead end?",hasDeadEnd)
	if hasDeadEnd then
		return true 
	end 
	if util.edgeHasBuildings(edge.id) then 
		return false 
	end 
	for i, node in pairs({edge.node1, edge.node0}) do 
		for i, seg in pairs(util.getStreetSegmentsForNode(node)) do 
			if util.getStreetTypeCategory(seg)=="highway" then 
				return false 
			end
			local edge2 = util.getEdge(seg) 
			for i, node in pairs({edge2.node1, edge2.node0}) do 
				for i, seg in pairs(util.getStreetSegmentsForNode(node)) do 
					if util.getStreetTypeCategory(seg)=="highway" then 
						return false 
					end				
				end 
			end
		end 
	end 
	if params.allEdgesUsedByLines and params.allEdgesUsedByLines()[edge.id] then 
		trace("Detected that edge",edge.id," is used by a line")
		return false 
	end 
	if not params.isCargo and  params.isTrack and (nodeOrder == 1 or nodeOrder == numberOfNodes) and util.getStreetTypeCategory(edge.id)=="urban" and not params.allowGradeCrossings and not params.isElevated and not params.isUnderground 
	and not util.getComponent(edge.id, api.type.ComponentType.PLAYER_OWNED) then 
		-- very hard to have a grade seperated crossing, see if we can remove it without busting any main connections
		local testProposal = api.type.SimpleProposal.new() 
		testProposal.streetProposal.edgesToRemove[1]=edge.id 
		local testResult = api.engine.util.proposal.makeProposalData(testProposal, util.initContext())
		if #testResult.errorState.messages == 0 and #testResult.errorState.warnings == 0 then 
			return true 
		else 
			trace("Could not remove edge ",edge.id," due to error")
			if util.tracelog then debugPrint(testResult.errorState) end 
			if #testResult.errorState.messages == 0 then 
				local allok = true 
				for i, warning in pairs(testResult.errorState.warnings) do 
					if not string.find(warning, "buildings will be removed") then 
						return false 
						
					end 
				end 
				return true
			end
		end 	
	end
	
	if util.isJunctionEdge(edge.id) then 
		return false 
	end
	if params.isCargo and params.isTrack and nodeOrder == 1 or nodeOrder == numberOfNodes then 
		local industry =  util.searchForFirstEntity(util.getEdgeMidPoint(edge.id), 200, "SIM_BUILDING")
		if industry and util.isPrimaryIndustry(industry) then -- primary industry means unlikely to use trucks for onward delivery
			for i, node in pairs({edge.node0, edge.node1}) do 
				local nextSegs = util.getSegmentsForNode(node)
				if #nextSegs ~= 2 then 	
					return false 
				end 
				local otherSeg = nextSegs[1] == edge.id and nextSegs[2] or nextSegs[1]
				if util.isDeadEndEdge(otherSeg) then 
					trace("Determined that ",edge.id," may be removed as it is a dead end for non primary industry")
					return true
				end 
			end 
		end 
	end 
	
	return false 
	
end

local function indexOfClosestPoint(p, routePoints)
	local points = {}
	for i = 1, #routePoints do 
		local dist = vec2.distance(p,routePoints[i].p)
		if dist ~= dist then 
			trace("Problem detected, NAN dist")
			--debugPrint({p=p, routePoints=routePoints})
		end
		table.insert(points, { index=i, scores={dist}})
	end
	return util.evaluateWinnerFromScores(points).index
end

local function buildAndSortCollisionInfo(nearbyEdges, combinedEdge, params, nodeOrder, numberOfNodes, routePoints)
	if params.ignoreAllOtherSegments and false then 
		nearbyEdges= {} 
	end
	local collisionEdges = {}
	local hermiteFracs = {}
	local nonCollisionEdges = {}
	local existingCollisionEdges = {}
	local collisionPointLookup = {}
	local minHeight = math.huge 
	local maxHeight = -math.huge
	local collisionHeights = {}
	local hasJunctionEdges = false
	-- no longer required - put the mainline down the median
	--[[
	if params.isHighway then 
		trace("Adjusting collision point for highway") 
		local edgeWidth = util.getStreetWidth(params.preferredHighwayRoadType)
		local newCombinedEdge = {
			p0 = util.nodePointPerpendicularOffset(combinedEdge.p0, combinedEdge.t0, edgeWidth+0.5*params.highwayMedianSize),
			p1 = util.nodePointPerpendicularOffset(combinedEdge.p1, combinedEdge.t1, edgeWidth+0.5*params.highwayMedianSize),
			t0 = combinedEdge.t0 ,
			t1 = combinedEdge.t1
		}
		combinedEdge = newCombinedEdge
	elseif params.isDoubleTrack then 
		trace("Adjusting collision point for double track") 
		local newCombinedEdge = {
			p0 = util.nodePointPerpendicularOffset(combinedEdge.p0, combinedEdge.t0, 0.5*params.trackWidth),
			p1 = util.nodePointPerpendicularOffset(combinedEdge.p1, combinedEdge.t1, 0.5*params.trackWidth),
			t0 = combinedEdge.t0 ,
			t1 = combinedEdge.t1
		}
		combinedEdge = newCombinedEdge
	end--]]
	local collisionEdgeSet = {}
	for i, edge in pairs(nearbyEdges) do 
		local c
		 
		if params.collisionEntities and params.collisionEntities[edge.id] then 
			-- go straight to a hermite solve as it may not have been picked up with straight line detection
			c = util.fullSolveForCollisionBetweenExistingAndProposedEdge(util.getEdgeMidPoint(edge.id), edge.id, combinedEdge, false, true)
			trace("Inspecting known collision edge ",edge.id," the solution gap was ",c.solutionGap)
		else 
			c = util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(edge.id, combinedEdge, false, true)
		end 
		if c then 
			maxHeight = math.max(edge.node0pos[3], math.max(edge.node1pos[3], math.max(c.existingEdgeSolution.p1.z ,maxHeight)))
			minHeight = math.min(edge.node1pos[3], math.min(edge.node1pos[3], math.min(c.existingEdgeSolution.p1.z ,minHeight))) 
			if c.otherEdge then 
				trace("Checking for collision point with other edge")
				local c2 = util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(c.otherEdge, combinedEdge, false, true)
				if c2 then 
					local swapSolutions = false
					if c2.otherEdge ~= edge.id then 
						swapSolutions = true
					else 
						local solution1 = util.solveForNearestHermitePosition(c.c, combinedEdge, vec2.distance)
						local solution2 = util.solveForNearestHermitePosition(c2.c, combinedEdge, vec2.distance)
						if vec2.distance(solution2, c2.c) < vec2.distance(solution1, c.c) then 
							swapSolutions = true
						end
					end
					if swapSolutions then
						trace("Swapping solutions for edge.id, ",edge.id, " with ",c.otherEdge)
						edge = util.getEntity(c.otherEdge)
						c = c2 
					end
				
				end
			end
			local reject = false 
			if nodeOrder > 1 and nodeOrder<numberOfNodes then 
				for __, node in pairs({edge.node0, edge.node1}) do 
					local segmentsForNode = util.getSegmentsForNode(node)
					if #segmentsForNode == 2 then 
						for i, seg in pairs(segmentsForNode) do 
							if collisionEdgeSet[seg] then 
								local otherEdge = collisionEdges[collisionEdgeSet[seg]]
								if not otherEdge then 
									debugPrint({collisionEdgeSet=collisionEdgeSet, collisionEdges=collisionEdges})
								end
								
								if otherEdge.c.solutionGap < c.solutionGap and not (params.collisionEntities and params.collisionEntities[edge.id]) then 
									trace("Rejecting edge ",edge.id," as it is already directly connected with ",seg)
									reject = true 
									break 
								else
									trace("Removing the edge ",seg," in favour of our solution which is better")
									collisionEdges[collisionEdgeSet[seg]]=nil
									collisionEdgeSet[seg]=nil
								end 
							end 
						end 						
					end
				end
			end
			if c.solutionGap > math.max(util.getEdgeWidth(edge.id), params.edgeWidth) and not (params.collisionEntities and params.collisionEntities[edge.id])  then 
				reject = true 
			end 
			if vec3.length(c.existingEdgeSolution.t1) == 0 or vec3.length(c.existingEdgeSolution.t2)==0  then 
				trace("Discovered zero length tangent in collision, rejecting")
				reject = true 
			end 
			if c.solutionIsNaN then 
				trace("WARNING! Found NaN solution, rejecting")
				reject = true 
			end
			if not reject then 
				local rpos = routePoints[nodeOrder+1]
				local pPos = routePoints[nodeOrder]
				local lpos = routePoints[nodeOrder-1]
				local buildResult = trialBuildBetweenPoints(lpos, pPos) 
				local buildResult2 = trialBuildBetweenPoints(pPos , rpos ) 
				if not buildResult.isError and not buildResult2.isError then 
					trace("Rejecting as no actual collision took place at",nodeOrder,"for",edge.id)
					reject = true 
				end 
			end 
			
			if reject then 
				trace("Rejected solution withe edge ", edge.id," as the solutiongap is too large", c.solutionGap)
				table.insert(nonCollisionEdges, { edge = edge } )
			else 
				local hermiteFrac = util.solveForPositionHermite(c.newEdgeSolution.p1, combinedEdge)
				local count = 0 
				while collisionEdges[hermiteFrac] and count < 10 do 
					hermiteFrac = hermiteFrac * 0.01+0.00001
					count = count +1
				end 
				table.insert(hermiteFracs, hermiteFrac)
				collisionEdges[hermiteFrac]= { edge = edge, hermiteFrac=hermiteFrac, c = c }
				table.insert(collisionHeights, edge.node0pos[3])
				table.insert(collisionHeights, edge.node1pos[3])

				collisionEdgeSet[edge.id] = hermiteFrac
				collisionPointLookup[edge.id] = c.existingEdgeSolution
			end
		else
			table.insert(nonCollisionEdges, { edge = edge } )
		end
	end
	table.sort(hermiteFracs)
	table.sort(collisionHeights)
	local sortedCollisionEdges = {}
	for i = 1, #hermiteFracs do 
		table.insert(sortedCollisionEdges, collisionEdges[hermiteFracs[i]])
	end
	--for i = 1, #nonCollisionEdges do
	--	table.insert(result, nonCollisionEdges[i])
	--end
	--if util.size(collisionEdges) > 1 then 
	--	debugPrint({sortedEdges=result, collisionEdges = collisionEdges})
	--end
	local collisionEdgeNearby = function() 
		local found = false 
		for i = 1, #sortedCollisionEdges do 
			for j = 1, #sortedCollisionEdges do 
				if j~=i then 
					for __, node1 in pairs({ sortedCollisionEdges[i].edge.node0, sortedCollisionEdges[i].edge.node1 } ) do 
						for __, node2 in pairs({ sortedCollisionEdges[j].edge.node0, sortedCollisionEdges[j].edge.node1 } ) do 
							for __, edgeId1 in pairs(util.getSegmentsForNode(node1)) do 
								for __, edgeId2 in pairs(util.getSegmentsForNode(node2)) do  
									if not areEdgesConnected(util.getEdge(edgeId1), util.getEdge(edgeId2)) and  util.checkIfEdgesCollide(edgeId1, edgeId2) then 
										trace("Found collision between",edgeId1, " and ",edgeId2)
										found= true
										existingCollisionEdges[edgeId1]=true 
										existingCollisionEdges[edgeId2]=true
									end 
								end 
							end 						
						end 
					end 
				end 
			end 
		end 
		return found 
	end
	local collisionHeightGapIdx 
	for i = 2, #collisionHeights do 
		if collisionHeights[i-1] - collisionHeights[i] > 2*params.minZoffset then 
			collisionHeightGapIdx = i 
			break 
		end 
	end
	for i = 1, #sortedCollisionEdges do 
		if util.isJunctionEdge(sortedCollisionEdges[i].edge.id) then 
			hasJunctionEdges = true 
			break 
		end
	end 
	
	return { collisionEdges = sortedCollisionEdges, nonCollisionEdges = nonCollisionEdges, maxHeight=maxHeight, minHeight = minHeight, collisionEdgeNearby = collisionEdgeNearby(), collisionHeights = collisionHeights , collisionHeightGapIdx = collisionHeightGapIdx, existingCollisionEdges= existingCollisionEdges, hasJunctionEdges =hasJunctionEdges, collisionPointLookup = collisionPointLookup}
end

local function createCombinedEdgeSafe(p1, p2, p3) -- tolerant to nil p1 or p3
	if not p1 then 
		return {
			p0 = p2.p,
			p1 = p3.p,
			t0 = p2.t2,
			t1 = p3.t
		}
	end
	if not p3 then 
		return {
			p0 = p1.p,
			p1 = p2.p,
			t0 = p1.t2,
			t1 = p2.t
		}
	end
	return util.createCombinedEdge(p1, p2, p3)
end



local function edgeIsHighSpeedTrack(edgeId) 
	local baseEdgeTrack = util.getTrackEdge(edgeId)
	return baseEdgeTrack and baseEdgeTrack.trackType == api.res.trackTypeRep.find("high_speed.lua")
end

local function checkIfRoadRouteRecollides(edge, routePoints, nodeOrder, numberOfNodes, c, context, params) 
	if edge.track then return end
	local function isProblematicEdge(edgeId)
		return util.isJunctionEdge(edgeId)
			or util.isFrozenEdge(edgeId) 
			or util.isIndustryEdge(edgeId) 
			or util.getStreetTypeCategory(edgeId) == "highway"
			or util.isOriginalBridge(edgeId) 
	end
	if isProblematicEdge(edge.id) then 
		trace("edge ",edge.id," was problematic, cannot reroute")
		return 
	end
	
	for i = nodeOrder+1, math.min(nodeOrder+10, numberOfNodes) do 
		local p0=routePoints[i-1].p 
		local p1=routePoints[i].p 
		local ourEdge = {
			p0 = p0,
			p1 = p1,
			t0 = routePoints[i-1].t2,
			t1 = routePoints[i].t 	
		}
		for __ ,otherEdge in pairs(util.searchForEntities(p1, vec2.distance(p0,p1), "BASE_EDGE")) do
			if not otherEdge.track and not context.allCollisionEdges[otherEdge.id] and otherEdge.id~=edge.id then 
				local c2 = util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(otherEdge.id, ourEdge)
				if c2 and not util.positionsEqual2d(c.c, c2.c, 10) then 
					trace("Found a collision ahead at i=",i," edgeId=",otherEdge.id," checking for connection")
					local route = pathFindingUtil.findRoadPathBetweenEdges(edge.id, otherEdge.id)
					if #route > 0 then 
						trace("Found a route with ",#route," answers") 
						local result = {
							startIndex = nodeOrder, 
							endIndex = i, 
							edgeIds = { edge.id } 
						} 
						local uniqueNessCheck = {}
						uniqueNessCheck[edge.id]=true
						for j, segOrNode in pairs(route) do 
							local routeEdge = util.getEdge(segOrNode.entity)
							if routeEdge then 
								if isProblematicEdge(segOrNode.entity) then 
									trace("Problematic edge found,",segOrNode.entity," reroute not possible")
									return 
								end
								
								if segOrNode.entity ~= edge.id and areEdgesConnected(edge, routeEdge) then
									if edge.node0 == routeEdge.node0 or edge.node0 == routeEdge.node1 then 
										result.startNode = edge.node1
										result.startTangent = -1*util.v3fromArr(edge.node1tangent)
									else 
										result.startNode = edge.node0
										result.startTangent =  util.v3fromArr(edge.node0tangent)
									end
								
								end
								if segOrNode.entity ~= otherEdge.id and areEdgesConnected(routeEdge, otherEdge) then
									if otherEdge.node0 == routeEdge.node0 or otherEdge.node0 == routeEdge.node1 then 
										result.endNode = otherEdge.node1
										result.endTangent =  util.v3fromArr(edge.node1tangent)
									else 
										result.endNode = otherEdge.node0
										result.endTangent = -1* util.v3fromArr(edge.node0tangent)
									end
								end
								if not uniqueNessCheck[segOrNode.entity] then 
									uniqueNessCheck[segOrNode.entity] = true 
									context.allCollisionEdges[segOrNode.entity]=true 
									table.insert(result.edgeIds, segOrNode.entity)
								end
							else 
								local segs = util.getSegmentsForNode(segOrNode.entity)
								if segs and #segs > 2 then 
									trace("Junction found, reroute not possible")
									return
								end
							end
						
						end
						if not uniqueNessCheck[otherEdge.id] then 
							table.insert(result.edgeIds, otherEdge.id)
							context.allCollisionEdges[otherEdge.id]=true 
						end
						local maxWidth = 0
						for __, edgeId in pairs(result.edgeIds) do 
							context.allCollisionEdges[edgeId]=true
							maxWidth = math.max(maxWidth, util.getEdgeWidth(edgeId))
						end
						local minOffset = maxWidth + params.ourWidth + 10
						if params.isHighway then 
							minOffset = minOffset + 10
						end
						
						local function checkRequiresMoreClearanceFromTrack(edgeId) 
							local edge = util.getEdge(edgeId)
							for __, node in pairs({edge.node0, edge.node1}) do 
								local nodePos = util.nodePos(node)
								local index = indexOfClosestPoint(nodePos, routePoints)
								local testEdge = createCombinedEdgeSafe(routePoints[index-1], routePoints[index], routePoints[index+1])
								for i = 1, 31 do -- walk along the route checking the clearance 
									local trackP = util.hermite2(i/32, testEdge).p 
									if vec2.distance(nodePos, trackP) < 2*minOffset then 
										return true 
									end
								end
							end
							return false
						end
						
						local requiresMoreClearance = vec2.distance(util.nodePos(result.startNode), c.c) < minOffset + 10 or c.otherEdge or checkRequiresMoreClearanceFromTrack(edge.id) 
						local startEdge = edge.id
						while requiresMoreClearance do 
							trace("Removing segment prior to collision for clearance ", startEdge)
							local nextSegs = util.getSegmentsForNode(result.startNode)
							local priorEdgeId = startEdge == nextSegs[1] and nextSegs[2] or nextSegs[1] 
							if #nextSegs == 2 and priorEdgeId and not uniqueNessCheck[priorEdgeId] and not isProblematicEdge(priorEdgeId,true) and not context.allCollisionEdges[priorEdgeId] then 
								local priorEdge = util.getEdge(priorEdgeId) 
								result.startTangent = priorEdge.node0 == result.startNode and -1*util.v3(priorEdge.tangent1) or util.v3(priorEdge.tangent0) 
								result.startNode = priorEdge.node0 == result.startNode and priorEdge.node1 or priorEdge.node0 
								table.insert(result.edgeIds,1, priorEdgeId)
								context.allCollisionEdges[priorEdgeId]=true 
								startEdge = priorEdgeId
							else 
								trace("Could not accept ",priorEdgeId, " for reroute")
								break
							end
							requiresMoreClearance = checkRequiresMoreClearanceFromTrack(priorEdgeId)
						end
						requiresMoreClearance = vec2.distance(util.nodePos(result.endNode), c2.c) < minOffset + 10 or c2.otherEdge or checkRequiresMoreClearanceFromTrack(otherEdge.id)
						local endEdge = otherEdge.id
						while requiresMoreClearance do
							trace("Removing segment after to collision for clearance ",endEdge)
							local nextSegs = util.getSegmentsForNode(result.endNode)
							local afterEdgeId = endEdge == nextSegs[1] and nextSegs[2] or nextSegs[1] 
							if #nextSegs == 2 and afterEdgeId and not uniqueNessCheck[afterEdgeId] and not isProblematicEdge(afterEdgeId, true) and not context.allCollisionEdges[afterEdgeId] then 
								local afterEdge = util.getEdge(afterEdgeId) 
								result.endTangent = afterEdge.node0 == result.endNode and util.v3(afterEdge.tangent1) or -1*util.v3(afterEdge.tangent0)
								result.endNode = afterEdge.node0 == result.endNode and afterEdge.node1 or afterEdge.node0 
								table.insert(result.edgeIds, afterEdgeId)
								context.allCollisionEdges[afterEdgeId]=true 
								endEdge = afterEdgeId
							else 
								trace("Could not accept ",afterEdgeId, " for reroute")
								break
							end
							requiresMoreClearance = checkRequiresMoreClearanceFromTrack(afterEdgeId)
						end
						-- try to figure out what side we are on
						local tangentSign = 1 
						local ourPriorTestP = c.c - 80*vec3.normalize(routePoints[nodeOrder].t)
						local ourEndTestP = c.c + 80*vec3.normalize(routePoints[nodeOrder].t)
						local t = routePoints[nodeOrder+1].t
						local theirStartP = util.nodePos(result.startNode)
						local testP = util.nodePointPerpendicularOffset(c.c,t, minOffset)
						local testP2 = util.nodePointPerpendicularOffset(c.c,t,2* minOffset)
						if util.checkFor2dCollisionBetweenPoints(ourPriorTestP, ourEndTestP, theirStartP, testP ) then
							trace("Collision found on testP,",testP.x, testP.y)
							tangentSign = -1
							if util.checkFor2dCollisionBetweenPoints(ourPriorTestP, ourEndTestP, theirStartP, testP2 ) then 
								trace("WARNING! Collision also found on testP2, ", testP2.x, testP2.y)
							end
						end 
						
						local replacementPoints = {} 
						local startNodePos = util.nodePos(result.startNode)
						local endNodePos = util.nodePos(result.endNode)
						local maxGradient = paramHelper.getParams().maxGradientRoad
						local startFrom = 1 + indexOfClosestPoint(util.nodePos(result.startNode), routePoints)
						local endAt =   indexOfClosestPoint(util.nodePos(result.endNode), routePoints)-1
						local lastP = startNodePos
						local lastT = result.startTangent
						for j = startFrom, endAt do 
							local t = routePoints[j].t 
							local p = util.nodePointPerpendicularOffset(routePoints[j].p, tangentSign*t, minOffset)
							local th = util.th(p)
							if th > p.z then 
								local maxHeight = math.min(vec2.distance(p, lastP)*maxGradient+lastP.z, 
													math.min(vec2.distance(p, startNodePos)*maxGradient + startNodePos.z,
															vec2.distance(p, endNodePos)*maxGradient + endNodePos.z))
								p.z = math.min(th, maxHeight)
							elseif th < p.z and th >0 then 
								local minHeight = math.max(-vec2.distance(p, lastP)*maxGradient+lastP.z, 
													math.max(-vec2.distance(p, startNodePos)*maxGradient + startNodePos.z,
															-vec2.distance(p, endNodePos)*maxGradient + endNodePos.z))
								p.z = math.max(th, minHeight)
							end
							local distFromLast = util.distance(lastP,p)
							local maxDist = distFromLast
							local distToLast = 0
							if j == endAt then 
								distToLast = util.distance(p, util.nodePos(result.endNode))
								maxDist = math.max(maxDist, distToLast)
	 
							end 
							trace("Inserting replacement point at a distance of ",maxDist,"distFromLast=",distFromLast,"distToLast=",distToLast)
							
							if distFromLast > 2*params.targetSeglenth then 
								
								local input = {
									p0 = lastP ,
									p1 = p ,
									t0 = lastT, 
									t1 = t,
								}
								local solution = util.solveForPositionHermiteFraction(0.5, input)
								trace("Splitting the point from last at ",solution.p1.x, solution.p1.y)
								table.insert(replacementPoints, { 
									p = solution.p1,
									t = solution.t1,
									t2 = solution.t2,
									terrainHeight = util.th( solution.p1), 
								})
								t = solution.t3
							end
									
		 
								
								
							  
							table.insert(replacementPoints, { 
								p = p,
								t = t,
								t2 = routePoints[j].t2,
								terrainHeight = th 
							})
							
							if distToLast > 2*params.targetSeglenth then 
								
								local input = {
									p0 = p ,
									p1 = util.nodePos(result.endNode) ,
									t0 = t, 
									t1 = result.endTangent,
								}
								local solution = util.solveForPositionHermiteFraction(0.5, input)
								trace("Splitting the point from end at ",solution.p1.x, solution.p1.y)
								table.insert(replacementPoints, { 
									p = solution.p1,
									t = solution.t1,
									t2 = solution.t2,
									terrainHeight = util.th( solution.p1), 
								})
								
							end 
							 
							lastP = p
							lastT = t
						end
						for j = 1, #replacementPoints do 
							local before = j==1 and startNodePos or replacementPoints[j-1].p
							local this = replacementPoints[j]
							local after = j==#replacementPoints and endNodePos or replacementPoints[j+1].p
							local averageZChange = ((this.p.z-before.z) + (after.z-this.p.z))/2
							this.t.z = averageZChange
							this.t2.z = averageZChange
							this.tunnelCandidate = this.p.z < this.terrainHeight-10
							this.needsBridge = this.p.z > this.terrainHeight + 10 or this.terrainHeight < 0
							local lastP = before 
							local p = this.p 
							local nextP = after 
							local index = indexOfClosestPoint(p, routePoints)
							local deltaz = routePoints[index].p.z - this.p.z 
							 
							
							 
							if index > 0 and index < #routePoints then 
								if util.checkFor2dCollisionBetweenPoints(lastP, p, routePoints[index].p, routePoints[index-1].p)
									or util.checkFor2dCollisionBetweenPoints(lastP, p, routePoints[index].p, routePoints[index+1].p)
									or util.checkFor2dCollisionBetweenPoints(nextP, p, routePoints[index].p, routePoints[index-1].p)
									or util.checkFor2dCollisionBetweenPoints(nextP, p, routePoints[index].p, routePoints[index+1].p) then 
										trace("Collision detected with reroute, deltaz was",deltaz)
									if math.abs(deltaz) < params.minZoffset  then 
										if deltaz >= 0 and p.z - params.minZoffset + deltaz > util.getWaterLevel() then 
											p.z = p.z - params.minZoffset + deltaz
											trace("Decreasing their height to ",p.z)
											before.z = math.min(p.z, before.z) 
											after.z = math.min(p.z , after.z)
											 
										else 
											p.z = p.z + params.minZoffset - deltaz 
											trace("Incrasing their height to ",p.z)
											before.z = math.max(p.z, before.z) 
											after.z = math.max(p.z , after.z)
										end  
									end
									if deltaz > 0 then  
										this.tunnelCandidate = true  
										if j == 1 then 
											result.tunnelCandidateStart = true 
										else 
											replacementPoints[j-1].tunnelCandidate = true 
										end 										
										if j == #replacementPoints then 
											result.tunnelCandidateEnd = true 
										else 
											replacementPoints[j+1].tunnelCandidate = true 
										end 										
									else 
										 
										this.needsBridge = true  
										if j == 1 then 
											result.needsBridgeStart = true 
										else 
											replacementPoints[j-1].needsBridge = true 
										end  
										if j == #replacementPoints then 
											result.needsBridgeEnd = true 
										else 
											replacementPoints[j+1].needsBridge = true 
										end 	 
									end   
								end
							end 
							
							
							if this.terrainHeight < util.getWaterLevel() then 
								if replacementPoints[j-1] then 
									replacementPoints[j-1].needsBridge = true 
								end 
								if replacementPoints[j+1] then 
									replacementPoints[j+1].needsBridge = true
								end
							end
						end
						
						
						
						if #replacementPoints > 0 then 
							local startDist = util.distance(replacementPoints[1].p, util.nodePos(result.startNode))
							replacementPoints[1].t = startDist * vec3.normalize(replacementPoints[1].t)
							result.startTangent = startDist * vec3.normalize(result.startTangent)
							
							local endDist = util.distance(replacementPoints[#replacementPoints].p, util.nodePos(result.endNode))
							replacementPoints[#replacementPoints].t2 = endDist * vec3.normalize(replacementPoints[#replacementPoints].t2)
							result.endTangent = endDist * vec3.normalize(result.endTangent)
						else 
							local dist = util.distBetweenNodes(result.startNode, result.endNode)
							if dist > 2*params.targetSeglenth then 
								
								local splits = math.ceil(dist / params.targetSeglenth)
								local segLength  = dist / splits
								local edge = { 
									p0 = util.nodePos(result.startNode), 
									p1 = util.nodePos(result.endNode), 
									t0 = dist * vec3.normalize(result.startTangent),
									t1 = dist * vec3.normalize(result.endTangent)
								}
								result.startTangent  = segLength * vec3.normalize(result.startTangent)
								result.endTangent = segLength * vec3.normalize(result.endTangent)
								
								local lastP = util.nodePos(result.startNode)
								 
								trace("Adding extra points to have shorter segments splits was ",splits) 
								local priorTunnelCandidate= false 
								local priorNeedsBridge= false 
								local wasCollision = false
								local nextMinHeight 
								local nextMaxHeight
								for i = 1, splits do 
									local splitPoint = util.solveForPositionHermiteFraction(i/(splits+1), edge)
									
									local p = splitPoint.p 
									
									local th = util.th(p)
									local index = indexOfClosestPoint(p, routePoints)
									
									local nextP = i < splits and util.solveForPositionHermiteFraction((i+1)/(splits+1), edge).p or lastP
									if wasCollision then 
										p.z = lastP.z
									end
									local deltaz = routePoints[index].p.z - p.z 
									local needsBridge = p.z - th > 10 
									local tunnelCandidate = p.z - th < -10
									local thisWasCollsion = false
									if index > 0 and index < #routePoints then 
										if util.checkFor2dCollisionBetweenPoints(lastP, p, routePoints[index].p, routePoints[index-1].p)
											or util.checkFor2dCollisionBetweenPoints(lastP, p, routePoints[index].p, routePoints[index+1].p)
											or util.checkFor2dCollisionBetweenPoints(p, nextP, routePoints[index].p, routePoints[index-1].p)
											or util.checkFor2dCollisionBetweenPoints(p, nextP, routePoints[index].p, routePoints[index+1].p) then 
											thisWasCollsion = true
											if math.abs(deltaz) < params.minZoffset  then 
												local goUnder = deltaz >= 0
												if goUnder then 
													local trialZ = p.z - params.minZoffset + deltaz
													trace("Checking the trialZ for",trialZ,"at",p.x,p.y)
													if waterMeshUtil.isPointOnWaterMeshTile(p) then 
														
														goUnder = trialZ >= 15+util.getWaterLevel()
														trace("The point WAS on a water mesh setting goUnder to",goUnder)
													end 
												end 
												if goUnder then 
													p.z = p.z - params.minZoffset + deltaz
													trace("Decreasing their height to ",p.z)
													if #replacementPoints > 0 then 
														replacementPoints[#replacementPoints].p.z = math.min(p.z, replacementPoints[#replacementPoints].p.z)
													end 
													nextMaxHeight = p.z
												else 
													p.z = p.z + params.minZoffset + deltaz -- NB deltaz negative here
													trace("Incrasing their height to ",p.z,"index height was",routePoints[index].p.z,"the deltaz was",deltaz)
													if #replacementPoints > 0 then 
														replacementPoints[#replacementPoints].p.z = math.max(p.z, replacementPoints[#replacementPoints].p.z)
													end
													nextMinHeight = p.z
												end 
											end 
											if deltaz > 0 then 
												tunnelCandidate = true 
											else 
												needsBridge = true 
											end 
											if #replacementPoints > 0 then 
												replacementPoints[#replacementPoints].tunnelCandidate = tunnelCandidate
												replacementPoints[#replacementPoints].needsBridge = needsBridge
											else 
												result.needsBridgeStart = needsBridge
												result.tunnelCandidateStart = tunnelCandidate
											end		
											if i == splits then 
												result.needsBridgeEnd = needsBridge
												result.tunnelCandidateEnd  = tunnelCandidate
											end
										else 
											if nextMaxHeight then 
												p.z = math.max(nextMaxHeight, p.z)
												nextMaxHeight = nil
											end 
											if nextMinHeight then 
												p.z = math.min(nextMinHeight, p.z) 
												nextMinHeight = nil
											end 
										end 
									end 
									
									local t = segLength * vec3.normalize(splitPoint.t)
									table.insert(replacementPoints, { 
										p = p,
										t = t,
										t2 = t,
										terrainHeight = th ,
										needsBridge = needsBridge or priorNeedsBridge and wasCollision ,
										tunnelCandidate = tunnelCandidate or priorTunnelCandidate and wasCollision
										
									})
									lastP = p
									priorTunnelCandidate = tunnelCandidate
									priorNeedsBridge = needsBridge
									wasCollision = thisWasCollsion
								end 
								
							else  
								result.startTangent  = dist * vec3.normalize(result.startTangent)
								result.endTangent = dist * vec3.normalize(result.endTangent)
							end
						end
						if #replacementPoints > 0 then 
							if util.th(replacementPoints[1].p) < util.getWaterLevel() then 
								result.needsBridgeStart = true 
							end 
							if util.th(replacementPoints[#replacementPoints].p) < util.getWaterLevel() then 
								result.needsBridgeEnd = true 
							end 
						end 
						result.replacementPoints = replacementPoints
						trace("Created reroute")
						if util.tracelog then 
							debugPrint({reroute=result})
						end
						for i, edgeId in pairs(result.edgeIds) do 
							local edge = util.getEdge(edgeId)
							for j, node in pairs({edge.node0, edge.node1}) do 
								context.reRouteNodes[node]=true 
							end
						end 
						return result
					end
				end
			end
		end
	end
	
end

local function buildSplitPoints(edge, routePoints, numberOfNodes, nodeOrder, lastSplit, context, params)
	local newSplitPoints = {}
	
	local function getActualLastSplit() 
		if #newSplitPoints > 0 then 
			return newSplitPoints[#newSplitPoints]
		end 
		if lastSplit then 
			if #lastSplit.newSplitPoints > 0 then 
				return lastSplit.newSplitPoints[ #lastSplit.newSplitPoints]
			end
			return lastSplit
		end
	end
	
	local function getActualLastLastPoint() 
		if #newSplitPoints > 1 then 
			return newSplitPoints[#newSplitPoints-1].pPos.p
		end 
		if lastSplit then 
			if #lastSplit.newSplitPoints > 1 then 
				return lastSplit.newSplitPoints[ #lastSplit.newSplitPoints-1].pPos.p
			end
			return lastSplit.pPos.p
		end
		return routePoints[0].p
	end
	local function getActualLastPoint() 
		if #newSplitPoints > 0 then 
			return newSplitPoints[#newSplitPoints].pPos.p
		end 
		if lastSplit then 
			if #lastSplit.newSplitPoints > 1 then 
				return lastSplit.newSplitPoints[ #lastSplit.newSplitPoints].pPos.p
			end
			return lastSplit.pPos.p
		end
		return routePoints[0].p
	end
	local maxGradient = params.maxGradient
	--local maxGradient = paramHelper.getMaxGradient(params.isTrack)
	--if params.isHighway then 
	--	maxGradient = paramHelper.getParams().maxGradientHighway
	--end
	local highestFrozen  = math.max(edge.p0.z,edge.p1.z)
	local lowestFrozen  = math.min(edge.p0.z,edge.p1.z)
	--local minHeight = (edge.p0.z > 100 and edge.p1.z> 100) and lowestFrozen or params.tunnelDepthLimit
	local minHeight = params.tunnelDepthLimit
	local minBridgeHeight = params.minBridgeHeight
	local minTunnelDepth = params.minTunnelDepth
	local minBridgeHeightAboveGround = 5
	local maxbridgeHeight = 30
	local collissionThisSplit = false
	local tunnelThreashold = math.min(maxGradient+0.1, 0.15)
	local collisionSegments
	local collisionSegmentsForNextSplit
	local segmentsPassingAbove = false
	local junction
	local oldNode
	local noResolve = false
	if routePoints[nodeOrder].followRoute then 
		noResolve = true 
	end
	local continueCrossingNextSeg = false
	local needsTunnelNextSplit = false 
	local needsBridgeNextSplit = false 
	local edgeTypeRequiredForDeconfliction = false 
	local terrainOffset = 0
	local smoothToTerrainTolerance = 1
	if params.isElevated then 
		terrainOffset = params.elevationHeight
		smoothToTerrainTolerance = 4
	end
	if params.isUnderground then 
		terrainOffset = -params.elevationHeight
	end
	
	if lastSplit and lastSplit.collisionSegmentsForNextSplit then 
		collisionSegments = lastSplit.collisionSegmentsForNextSplit
		collissionThisSplit = true
	end
	
	if lastSplit and lastSplit.junction and (lastSplit.junction.rightEntryNodeNextSplit or lastSplit.junction.leftEntryNodeNextSplit) then 
		junction = {}
		junction.tangent = lastSplit.junction.tangent
		junction.minDist = lastSplit.junction.minDist
		local function canAddThisSplit(node) 
			if not node then return false end
			local nodePos = util.nodePos(node)
			local angle = util.signedAngle(routePoints[nodeOrder].t,nodePos-routePoints[nodeOrder].p)
			local dist = util.distance(nodePos, routePoints[nodeOrder].p)
			trace("Checking if can add ",node," the angle was ",math.deg(angle), " dist was ",dist)
			return  dist > lastSplit.junction.minDist
			and math.abs(angle)>math.rad(130) -- needs to be behind
		end
		if canAddThisSplit(lastSplit.junction.rightEntryNodeNextSplit) then 
			junction.rightEntryNode = lastSplit.junction.rightEntryNodeNextSplit
		else 
			junction.rightEntryNodeNextSplit = lastSplit.junction.rightEntryNodeNextSplit
		end
		if canAddThisSplit(lastSplit.junction.leftEntryNodeNextSplit)  then
			junction.leftEntryNode = lastSplit.junction.leftEntryNodeNextSplit
		else
			junction.leftEntryNodeNextSplit = lastSplit.junction.leftEntryNodeNextSplit
		end 
			
	end

	local totalsegs= numberOfNodes+1
	local fracspace = 1/ (totalsegs ) 
	local strictFrac = nodeOrder / totalsegs 
	local function getFollowRouteEdge(i)
		if routePoints[i].followRoute then 
			local doubleTrackNode0 = util.findDoubleTrackNode(routePoints[i].p,routePoints[i].t )
			local doubleTrackNode1 = util.findDoubleTrackNode(routePoints[i+1].p,routePoints[i+1].t )
			if doubleTrackNode0 and doubleTrackNode1 then 
				local theirEdge = util.findEdgeConnectingNodes(doubleTrackNode0, doubleTrackNode1)
				if theirEdge then 
				
				else 
					trace("WARNING! Could not find any edge connecting",doubleTrackNode0,doubleTrackNode1)
				end 
			else 
				trace("WARNING! Could not find double track nodes at ",i)
			end 
		end 
	end 
	trace(" totalsegs=", totalsegs, " strictFrac=", strictFrac, " nodeOrder=", nodeOrder, " calculating new node point")
	local function isBridge(i)
		local followRouteEdge = getFollowRouteEdge(i)
		if followRouteEdge then 
			return util.getEdge(followRouteEdge).type == 1
		end  
		return context.bridgeStart and context.bridgeStart >= 0 and i >= context.bridgeStart and i <= context.bridgeEnd
	end 
	
	local function isTunnelCandidateFn(i)
		local followRouteEdge = getFollowRouteEdge(i)
		if followRouteEdge then 
			return util.getEdge(followRouteEdge).type == 2
		end  
		return context.tunnelStart and (context.tunnelStart >= 0 and i >= context.tunnelStart and i <= context.tunnelEnd or context.tunnelHeights[i])
	end
	
	local function gradBetween(i, j) 
		return ((context.terrainHeights[i] - context.terrainHeights[j]) / 
		(math.abs(i-j)*context.seglength))
	end

	local function getActualLength(i)
		return util.calcEdgeLength2d(routePoints[i].p, routePoints[i-1].p, routePoints[i].t, routePoints[i-1].t2)
	end
	
	local function calc2dEdgeLength(pLeft, pRight)
		return util.calcEdgeLength2d(pRight.p, pLeft.p, pRight.t, pLeft.t2)
	end

	
	local function leftGrad(i)
		return ((context.terrainHeights[i] - context.terrainHeights[i-1])) 
		/ getActualLength(i)
	end
	
		
	local function smoothToTerrain(i)
		if 
		context.suppressSmoothToTerrain[i] or 
		context.terrainHeights[i] <0 or
		--isTunnelCandidateFn(i-1) or isBridge(i-1) or
		context.tunnelHeights[i] and not params.isUnderground
		or isTunnelCandidateFn(i) and not params.isUnderground
		or routePoints[i].spiralPoint
		--or isTunnelCandidateFn(i+1) or isBridge(i+1)
		then 
			trace("Suppressing smoothToTerrain at ",i, " is suppressSmoothToTerrain?",context.suppressSmoothToTerrain[i]," is tunnelHeight?",context.tunnelHeights[i], " isTunnelCandidateFn(i)",isTunnelCandidateFn(i), " isSpiralPoint? ",routePoints[i].spiralPoint, " terrainHeight was ",context.terrainHeights[i])
			return 
		end
		if  isBridge(i) and not context.bridgeOverTerrain then 
			trace("Suppressing smoothToTerrain at ",i, " due to bridge")
			return 
		end
		local correctedTerrainOffset = terrainOffset
		if params.isElevated and (context.tunnelHeights[i+1] or context.tunnelHeights[i-1]) then 
			correctedTerrainOffset = 0.5*terrainOffset 
		end
		
		local leftHeight = context.actualHeights[i-1]-correctedTerrainOffset
		local height = context.actualHeights[i]-correctedTerrainOffset
		local rightHeight = context.actualHeights[i+1]-correctedTerrainOffset
		
		if height < context.terrainHeights[i] 
			and context.terrainHeights[i-1] < context.terrainHeights[i] 
			and context.terrainHeights[i+1] < context.terrainHeights[i] 
			and leftHeight >= context.terrainHeights[i-1]
			and rightHeight >= context.terrainHeights[i+1]
			then 
				trace("Suppressing smoothing to local high at ",i)
			return 
		end
		if context.actualHeights[i] > context.terrainHeights[i] 
			and context.terrainHeights[i-1] > context.terrainHeights[i] 
			and context.terrainHeights[i+1] > context.terrainHeights[i]
			and leftHeight <= context.terrainHeights[i-1]
			and rightHeight <= context.terrainHeights[i+1]

			then 
				trace("Suppressing smoothing to local low at ",i)
			return 
		end
		local maxGradientForSmoothToTerrain = math.min(maxGradient, params.isTrack and 0.03 or 0.1) -- prevent excessive rolling
		local maxDeltaZLeft = maxGradientForSmoothToTerrain*context.leftLengths[i]
		local maxDeltaZRight= maxGradientForSmoothToTerrain*context.rightLengths[i]
		
		
		
		local maxHeight = math.min(leftHeight+maxDeltaZLeft, rightHeight+maxDeltaZRight)
		local minHeight = math.max(leftHeight-maxDeltaZLeft, rightHeight-maxDeltaZRight)
		if height < context.terrainHeights[i] and  context.townBuildingCount[i] > 0 then 
			trace("Suppressing smoothToTerrain at ",i," due to proximity to town buildings")
			return 
		end
		if height > context.terrainHeights[i] and params.isUnderground then 
			trace("Suppressing smoothToTerrain at ",i, " as height is ",height, " and this is underground, terrainheight=",context.terrainHeights[i] ," true height = ",context.actualHeights[i])
			return 
		end
		local terraingap = context.terrainHeights[i] -height 
		--[[if math.abs(terraingap) > 50 then 
			trace("Suppressing smooth to terrain for large height gap")
			return
		end ]]--
		if terraingap > smoothToTerrainTolerance and height < maxHeight then
			local adjustment = math.min(terraingap, maxHeight-height) --  -correctedTerrainOffset
			local hbefore = context.actualHeights[i]
			context.actualHeights[i]=math.min(context.maxHeights[i], math.max(context.minHeights[i], context.actualHeights[i]+adjustment))
			trace("adjusted height at ",i," by",adjustment, "maxHeight=",maxHeight, "terraingap=",terraingap, " hbefore=",hbefore,"new height=",context.actualHeights[i])
		end 
	
		if terraingap < -smoothToTerrainTolerance and height > minHeight then
			local adjustment = math.max(terraingap, minHeight-height) -- -correctedTerrainOffset
			local hbefore = context.actualHeights[i]			
			context.actualHeights[i]=math.min(context.maxHeights[i], math.max(context.minHeights[i], context.actualHeights[i]+adjustment))
			trace("adjusted height at ",i," by",adjustment, "minHeight=",minHeight, "terraingap=",terraingap, " hbefore=",hbefore,"new height=",context.actualHeights[i])
		end 
		height = context.actualHeights[i]-correctedTerrainOffset
		terraingap = context.terrainHeights[i] -height 
		if math.abs(terraingap) > 0 or smoothToTerrainTolerance > 0 then -- may need to correct a hump left over from initial smoothing 
			local linearInterpolate = false 
			if terraingap > 0 then -- below ground 
				if height < rightHeight
				and height < leftHeight then -- have a local minima 
					linearInterpolate = true
				end
			else -- above ground 
				if height > rightHeight
				and height > leftHeight then -- have a local maxima
					linearInterpolate = true
				end
			end
			if smoothToTerrainTolerance > 0 
				and math.abs(terraingap) < smoothToTerrainTolerance 
				and math.abs(context.terrainHeights[i-1]-leftHeight) < smoothToTerrainTolerance
				and math.abs(context.terrainHeights[i+1]-rightHeight) < smoothToTerrainTolerance
				then 
				linearInterpolate = true 
			end
			if linearInterpolate and (
				math.abs(context.actualHeights[i-1]-context.actualHeights[i]) > maxDeltaZLeft
				or math.abs(context.actualHeights[i+1]-context.actualHeights[i]) > maxDeltaZRight
				or math.abs(context.actualHeights[i+1]-context.actualHeights[i-1]) > maxDeltaZLeft+maxDeltaZRight) then 
				trace("Suppressing linearInterpolation at ",i," because it would exceed max gradient")
				linearInterpolate = false 
			end
			
			if linearInterpolate then 
				local leftLength = context.leftLengths[i]
				local rightLength = context.rightLengths[i]
				local interpolateHeight = (leftLength*context.actualHeights[i-1]+rightLength*context.actualHeights[i+1])/(rightLength+leftLength)
				context.actualHeights[i] = math.min(context.maxHeights[i], math.max(interpolateHeight, context.minHeights[i]))
			
				trace("adjusted height at ",i," by linear iterpolation of neightbourbing points. Height before=",height,"context.actualHeights[i]=",context.actualHeights[i], " left height was",context.actualHeights[i-1]," right height was",context.actualHeights[i+1])
			end
		end
		routePoints[i].t.z = context.actualHeights[i]-context.actualHeights[i-1]
		routePoints[i].t2.z = context.actualHeights[i+1]-context.actualHeights[i]
	end
	local function reversesmooth(from, to)
		local correctionsMade = false
		trace("reverse smoothing from ",from," to ", to)
		--local maxDeltaZ = (maxGradient/100)*context.seglength
		for i = from, math.max(to,1), -1 do
			local maxDeltaZ = maxGradient*context.rightLengths[i]
			if i == numberOfNodes then 
			--	maxDeltaZ = maxDeltaZ / 2 -- half the gradient out of the station to allow smooth transition changes
			end
			context.minHeights[i] = math.max(context.minHeights[i], context.minHeights[i+1]- params.absoluteMaxGradient*context.rightLengths[i])
			context.maxHeights[i] = math.min(context.maxHeights[i], context.maxHeights[i+1]+ params.absoluteMaxGradient*context.rightLengths[i])
			if context.maxHeights[i] < context.minHeights[i] then 
				trace("WARNING! Detected maxHeight below min at ",i," maxHeight=", context.maxHeights[i], "minHeight=", context.minHeights[i]," setting max=min")
				context.maxHeights[i]=context.minHeights[i]
			end
			local deltaz = context.actualHeights[i]-context.actualHeights[i+1]
			if context.lockedHeights[i] then 
				if math.abs(deltaz) > maxDeltaZ then 
					trace("Warning!, locked height unable to correct large deltaz =",deltaz, " maxDeltaz=",maxDeltaZ, " at i=",i)
				end
				goto continue 
				
			end
			
			local hbefore=context.actualHeights[i]
		
			if deltaz > maxDeltaZ then
				context.actualHeights[i]= math.min(context.maxHeights[i], math.max(context.minHeights[i], context.actualHeights[i+1]+maxDeltaZ))
				trace("reverse clamped height at ",i," due to deltaz=",deltaz, "maxDeltaZ=",maxDeltaZ," hbefore=",hbefore, " context.actualHeights[i]=",context.actualHeights[i])
				correctionsMade = true
			elseif deltaz < -maxDeltaZ then
				context.actualHeights[i]= math.min(context.maxHeights[i], math.max(context.minHeights[i], context.actualHeights[i+1]-maxDeltaZ))
				trace("reverse clamped height at ",i," due to deltaz=",deltaz, "maxDeltaZ=",maxDeltaZ," hbefore=",hbefore, " context.actualHeights[i]=",context.actualHeights[i])
				correctionsMade = true
			end
			smoothToTerrain(i)
			if correctionsMade and not context.frozen[i] then 
				routePoints[i].t.z = context.actualHeights[i]-context.actualHeights[i-1]
				routePoints[i].t2.z = context.actualHeights[i+1]-context.actualHeights[i]
			end 
			::continue::
		end
		
		local thisPrevSplit = lastSplit
		for i = 1, nodeOrder - to do 
			if i < nodeOrder and i >= 1 and thisPrevSplit then 
				local j = thisPrevSplit.nodeOrder
				if not context.lockedHeights[j] then 
					local oldHeight = thisPrevSplit.pPos.p.z
					local delta = context.actualHeights[j]-thisPrevSplit.pPos.p.z
					trace("reverse smoothing setting height at ",j," to ",context.actualHeights[j]," originally ",oldHeight, " delta=",delta)
					thisPrevSplit.pPos.p.z=context.actualHeights[j]
					local maxTerrainHeight = math.max(util.th(thisPrevSplit.pPos.p), util.th(thisPrevSplit.pPos.p, true))
					if delta > 0 and thisPrevSplit.tunnelCandidate and maxTerrainHeight - thisPrevSplit.pPos.p.z < 5 then 
						trace("Removing tunnel candidate at ",j)
						thisPrevSplit.tunnelCandidate = false 
						context.tunnelHeights[j]=false 
					end
					for __, otherSplit in pairs(thisPrevSplit.newSplitPoints) do 
						local oldHeight2 = otherSplit.pPos.p.z
						if oldHeight2 ~= context.actualHeights[j] then 
							local deltaZ = thisPrevSplit.pPos.p.z-otherSplit.pPos.p.z 
							local dist = vec2.distance(thisPrevSplit.pPos.p,otherSplit.pPos.p)
							local grad = math.abs(deltaZ) / dist 
							if grad > maxGradient then 
								trace("Discovered intermidate split point exceeds max grad")
								local hMax = thisPrevSplit.pPos.p.z+dist*grad 
								local hMin = thisPrevSplit.pPos.p.z-dist*grad 
								otherSplit.pPos.p.z = math.min(hMax, math.max(hMin, otherSplit.pPos.p.z))
								trace("adjusted intermediate split point from ", oldHeight2 , " to ",otherSplit.pPos.p.z)
							end 
							
						end
					end
				end 
				if not thisPrevSplit then 
					trace("no previous split found at i=",i)
					break
				end
				thisPrevSplit = thisPrevSplit.lastSplit
			end
		end
		return correctionsMade
	end

	local function smooth(from, to)
		trace("smoothing from ",from," to ", to)
		local correctionsMade = false
		--local maxDeltaZ = (maxGradient/100)*context.seglength
		for i = from, to do
			
			local maxDeltaZ = (maxGradient)*context.leftLengths[i]
			if i == 1 then 
				maxDeltaZ = maxDeltaZ / 2 -- half the gradient out of the station to allow smooth transition changes
			end
			
			context.minHeights[i] = math.max(context.minHeights[i], context.minHeights[i-1]- params.absoluteMaxGradient*context.leftLengths[i])
			context.maxHeights[i] = math.min(context.maxHeights[i], context.maxHeights[i-1]+ params.absoluteMaxGradient*context.leftLengths[i])
			if context.maxHeights[i] < context.minHeights[i] then 
				trace("WARNING! Detected maxHeight below min at ",i," maxHeight=", context.maxHeights[i], "minHeight=", context.minHeights[i]," setting max=min")
				context.maxHeights[i]=context.minHeights[i]
			end
			local deltaz = context.actualHeights[i]-context.actualHeights[i-1]
			if context.lockedHeights[i] then 
				if math.abs(deltaz) > maxDeltaZ then 
					trace("Warning!, locked height unable to correct large deltaz =",deltaz, " maxDeltaz=",maxDeltaZ)
				end
				goto continue 
				
			end
			
			local hbefore=context.actualHeights[i]
			if deltaz > maxDeltaZ then
				context.actualHeights[i]= math.min(context.maxHeights[i], math.max(context.minHeights[i],context.actualHeights[i-1]+maxDeltaZ))
				trace("clamped height at ",i," due to deltaz=",deltaz, "maxDeltaZ=",maxDeltaZ, " hbefore=",hbefore, " context.actualHeights[i]=",context.actualHeights[i], " terrainheight=",context.terrainHeights[i], "hmin=",context.minHeights[i])
				correctionsMade = true
			elseif deltaz < -maxDeltaZ then
				context.actualHeights[i]= math.min(context.maxHeights[i],math.max(context.minHeights[i], context.actualHeights[i-1]-maxDeltaZ))
				trace("clamped height at ",i," due to deltaz=",deltaz, "maxDeltaZ=",maxDeltaZ, " hbefore=",hbefore, " context.actualHeights[i]=",context.actualHeights[i])
				correctionsMade = true
			end 
			if correctionsMade and not context.frozen[i] then 
				routePoints[i].t.z = context.actualHeights[i]-context.actualHeights[i-1]
				routePoints[i].t2.z = context.actualHeights[i+1]-context.actualHeights[i]
			end 
			smoothToTerrain(i)
			::continue::
		end
		if to == numberOfNodes then -- always come back in the opposite direction to avoid a big jump at the end
			correctionsMade =  reversesmooth(to, from) or correctionsMade
		end
		
		return correctionsMade
	end
	
	local function maxAbsGradient(from, to) 
		local maxgrad = 0
		for i = from, math.min(to, numberOfNodes+1) do
			--trace("checking gradient at ",i)
			maxgrad = math.max(maxgrad, math.abs(context.gradients[i]))
		end
		return maxgrad
	end
	
	local function meetsTunnelGradientThreshold(i)
		local length = 0
		for j = context.tunnelStart, i-1 do 
			length = length + context.rightLengths[j]
		end 
		if length == 0 then 
			return false 
		end 
		local terrainHeight = context.terrainHeights[i]
		if terrainHeight < context.tunnelHeight then 
			return true 
		end 
		local deltaZ = terrainHeight - context.tunnelHeight
		local meetsGradientThreshold = deltaZ / length <= params.absoluteMaxGradient
		trace("meetsTunnelGradientThreshold: got length",length,"from tunnel start at ",context.tunnelStart,"to",i, "deltaZ = ",deltaZ,"meetsGradientThreshold=",meetsGradientThreshold,"deltaZ / length=",(deltaZ / length))
		return meetsGradientThreshold
	 
	end 
	
	local function searchForTunnels(startFrom)
		local previousTunnelEnd = (context.tunnelEnd and context.tunnelEnd ~= 1) and context.tunnelEnd or 1
		context.tunnelStart = -1
		context.tunnelEnd = -1
		context.tunnelHeight = nil
		

		local rightHandSearch = numberOfNodes
	
		for i= 	startFrom, numberOfNodes do
			 
			-- search for tunnels in the current direction
			local pleft = routePoints[i-1].p
			local p = routePoints[i].p
			local pright = routePoints[i+1].p
			local terrainHeight = util.th(p, i==numberOfNodes)
			local leftterrainHeight = i==1 and pleft.z or util.th(pleft)
			if i==1 then 
				trace(" pleft.x=",pleft.x," pleft.y=",pleft.y, " pleft.z= ",pleft.z, " edge.p0.x=", edge.p0.x, " edge.p0.y=", edge.p0.y, " edge.p0.z=", edge.p0.z,"  api.engine.terrain.getHeightAt(api.type.Vec2f.new(edge.p0.x,edge.p0.y))=", api.engine.terrain.getHeightAt(api.type.Vec2f.new(edge.p0.x,edge.p0.y)))
			end
			
	 
			local leftgrad = ((terrainHeight - leftterrainHeight) / util.distance(p, pleft))
			trace("looking for tunnel at ", tostring(i), " leftGrad was ", leftgrad, " leftterrainHeight=",leftterrainHeight, " terrainHeight=",terrainHeight, " p.x=", p.x, " p.y=", p.y, " calculated leftgrad was",leftGrad(i))
			local lowlimit = lowestFrozen - 10
			if leftterrainHeight>=lowlimit and terrainHeight>=lowlimit and leftgrad >= tunnelThreashold and context.tunnelStart == -1 then
				trace("tunnel started at ", tostring(i), " leftGrad was ", leftgrad)
				context.tunnelStart = i -- - 1
				context.tunnelHeight = math.max(math.min(leftterrainHeight, terrainHeight-10),context.hermiteHeights[i]-20)
				context.tunnelHeight = math.min(context.actualHeights[i], context.tunnelHeight) -- do not increase the height
				trace("The tunnel height was ",context.tunnelHeight)
				if not routePoints[i].frozen then 
					context.actualHeights[i] = context.tunnelHeight
				end
				context.tunnelHeights[i] = context.tunnelHeight
				reversesmooth(i-1, previousTunnelEnd)
			elseif context.tunnelStart ~= -1 and context.tunnelEnd == -1 and (
			(context.tunnelHeight+10) >= terrainHeight
			or context.hermiteHeights[i]+10 >= terrainHeight
			or maxAbsGradient(i, i+5) < tunnelThreashold and meetsTunnelGradientThreshold(i) -- implies smooth terrain ahead, we should exit 
			)
			then
				
				context.tunnelEnd = i-1
				trace("ending tunnel at ",context.tunnelEnd)
				if context.tunnelEnd == context.tunnelStart then
					trace("tunnel ended on the same point as the start, searching for next at ",i)
					smooth(i-1,i)
					searchForTunnels(i)
					return
				end
				
				for j = context.tunnelStart, context.tunnelEnd do 
					if routePoints[j].followRoute then 
						trace("skipping tunnel height calculation for followRoute")
						goto continue 
					end
					local height = context.tunnelHeight
					local tunnellength = context.tunnelEnd - context.tunnelStart 
					local b = context.tunnelHeight
					local a = (terrainHeight - b) / (tunnellength+1)
					local x = j-context.tunnelStart
					if math.abs(context.tunnelHeight-terrainHeight) > 10 then
						
						height = a*x+b
						routePoints[j].t.z=a
						routePoints[j].t2.z=a
					else 
						routePoints[j].t.z=0
						routePoints[j].t2.z=0
					end
					context.tunnelHeights[j]=height
					if not routePoints[j].frozen then 
						context.actualHeights[j] = height
					end
					--context.suppressSmoothToTerrain[j]=true
					trace("tunnel end setting context.actualHeights[j] ", j, " to ",context.actualHeights[j]," a=",a," x=",x," b=",b )
					::continue::
				end
				if not routePoints[i].frozen and not routePoints[i].followRoute then 
					context.actualHeights[i]=context.tunnelHeight
				end
				smooth(i , numberOfNodes)
				smooth(i , numberOfNodes) -- second pass to allow route to be flattened to terrain 
				trace("left tunnel ended at ", (i-1), "(context.tunnelHeight+10) >= terrainHeight ", (context.tunnelHeight+10) >= terrainHeight, "context.tunnelHeight+10=",context.tunnelHeight+10)
				break
			end
		end
		
		if context.tunnelStart ~= -1 and context.tunnelEnd == -1 then
			context.tunnelEnd = numberOfNodes
			local tunnellength = context.tunnelEnd - context.tunnelStart
			if tunnellength > 0 then
				local b = context.tunnelStart
				local a = (edge.p1.z - b) / tunnellength
			
				for j = context.tunnelStart, context.tunnelEnd do 
					if routePoints[j].followRoute then 
						trace("skipping tunnel height calculation for followRoute")
						goto continue 
					end
					local x = j-context.tunnelStart
					local h = a*x + b
					context.tunnelHeights[j]=h 
					if not routePoints[j].frozen then 
						context.actualHeights[j] = h
					end
					routePoints[j].t.z=a
					routePoints[j].t2.z=a 
					trace("End tunnel setting height at ",j," to ",h)
					::continue::
				end
			else
				context.tunnelStart = -1
				context.tunnelEnd = -1
			end
		end
		
		-- search for tunnels in the opposite direction
		if context.tunnelStart == -1 then
			local isTunnel = false -- overwrite to left most results
			for i = numberOfNodes, startFrom, -1 do
				local pright = routePoints[i+1].p
				local p = routePoints[i].p	
				local terrainHeight = util.th(p)
				local rightterrainHeight =	util.th(pright)
				local rightGrad = ((terrainHeight - rightterrainHeight ) / util.distance(p, pright))
				trace("looking for tunnel at ", tostring(i), " rightGrad was ", rightGrad)
				local lowlimit = math.max(minHeight, lowestFrozen - 10)
				if rightterrainHeight>=lowlimit and terrainHeight>=lowlimit and rightGrad >= tunnelThreashold and not isTunnel then
					isTunnel = true
					
					context.tunnelEnd = i
					context.tunnelHeight = math.max(math.min(rightterrainHeight, terrainHeight-10),context.hermiteHeights[i]-20)
					context.tunnelHeight = math.min(context.tunnelHeight, context.actualHeights[i])
					trace("right tunnel started at ", tostring(i), " rightGrad was ", rightGrad, " initial tunnel height set",context.tunnelHeight)
					local deltaz = context.tunnelHeight - context.actualHeights[i+1]
					local maxDeltaZ = maxGradient*context.rightLengths[i]
					if math.abs(deltaz) > maxDeltaZ then 
						
						if deltaz > 0 then 
							context.tunnelHeight = maxDeltaZ+context.actualHeights[i+1]
						else 
							context.tunnelHeight = -maxDeltaZ+context.actualHeights[i+1]
						end
						trace("Detected large tunnel gradient, correcting",deltaz," new tunnel height",context.tunnelHeight, " maxDeltaZ=",maxDeltaZ,"context.actualHeights[i]=",context.actualHeights[i], " and i+1=", context.actualHeights[i+1])
					end
					if not routePoints[i].frozen and not routePoints[i].followRoute then 
						context.actualHeights[i]=context.tunnelHeight
					end
					--context.suppressSmoothToTerrain[i]=true
					--context.suppressSmoothToTerrain[i+1]=true
					smooth(i+1,numberOfNodes)
				end
				if context.tunnelEnd ~= -1 and isTunnel and ((context.tunnelHeight+10) >= terrainHeight
					or context.hermiteHeights[i]+10 >= terrainHeight
					or maxAbsGradient(i, i-5) < tunnelThreashold ) then -- implies smooth terrain ahead, we should exit then
					context.tunnelStart = i
					isTunnel = false
					trace("right tunnel ended at ", tostring(i))
					for j = context.tunnelStart, context.tunnelEnd do 
						if routePoints[j].followRoute then 
							trace("skipping tunnel height calculation for followRoute")
							goto continue 
						end
						context.tunnelHeights[j]=context.tunnelHeight
						if not routePoints[j].frozen then 
							context.actualHeights[j] = context.tunnelHeight
						end
						routePoints[j].t.z=0
						routePoints[j].t2.z=0
						
						trace("right tunnel end, setting context.actualHeights[j] ", j, " to ",context.actualHeights[j] )
						::continue::
					end
					reversesmooth(i, previousTunnelEnd)
					break
				end
			end
		end
		if context.tunnelEnd ~= -1 and context.tunnelStart == -1 then
			context.tunnelStart = startFrom
			local tunnellength = context.tunnelEnd - context.tunnelStart 
			if tunnellength==0 then
				trace("cancelling tunnel of zero length at ",startFrom)
				context.tunnelStart = -1
				context.tunnelEnd = -1
				return
			end
		
			local tunnelStartHeight = startFrom == 1 and edge.p0.z or routePoints[startFrom].p.z
			local b =tunnelStartHeight
			local a = ( context.tunnelHeight-b) / (tunnellength+1)
				
			for j = context.tunnelStart, context.tunnelEnd do 
				if routePoints[j].followRoute then 
					trace("skipping tunnel height calculation for followRoute")
					goto continue 
				end
				local x = j-context.tunnelStart
				local h = a*x + b
				if h < context.terrainHeights[j] then
					context.tunnelHeights[j]=h
					
					context.actualHeights[j]=h
					routePoints[j].t.z=a
					routePoints[j].t2.z=a
					trace("End tunnel setting height at ",j," to ",h, " b=",b," a=",a)
				end
				::continue::
			end
		end
		
	
	end

	if nodeOrder == 1 then 
		-- init
		local waterLevel = util.getWaterLevel()
		local edgeLength = util.calcEdgeLength(edge.p0,edge.p1,edge.t0,edge.t1)
		context.seglength =edgeLength/(numberOfNodes+1)
		context.lockedHeights = {}
		context.terrainHeights = {}
		context.maxTerrainHeights = {}
		context.minTerrainHeights = {}		
		context.hermiteHeights ={}
		context.suppressSmoothToTerrain = {}
		context.gradients = {}
		context.allCollisionEdges = {}
		context.reRouteNodes = {}
		context.edgesToIgnore = { [params.leftEdgeId]=true, [params.rightEdgeId]=true}
		if params.otherLeftEdge then 
			context.edgesToIgnore[params.otherLeftEdge]=true 
		end 
		if params.otherRightEdge then 
			context.edgesToIgnore[params.otherRightEdge]=true 
		end  
		for edgeId, bool in pairs(util.shallowClone(context.edgesToIgnore)) do -- need to avoid interacting with edges at start and end
			local edge = util.getEdge(edgeId) 
			if not edge then 
				trace("No edge found for ",edgeId)
				if util.tracelog then 
					debugPrint({edgesToIgnore=context.edgesToIgnore})
				end 
			else 
				for j, node in pairs({edge.node0, edge.node1}) do 
					for k, seg in pairs(util.getSegmentsForNode(node)) do 
						context.edgesToIgnore[seg]=true 
						trace("prepareRoute: marking edge",seg,"to ignore")
					end 
				end 
			end
		end 
		context.leftLengths = {}
		context.rightLengths = {}
		context.townBuildingCount = {}
		context.falseWaterPoints = {}
		context.tunnelHeights = {}
		context.frozen = {} 
		context.lastJunctionIdx = 0
		context.lastCrossingJunctionIdx = 0
		context.terrainHeights[0] = edge.p0.z -- fixed
		context.hermiteHeights[0] = edge.p0.z
		local maxStartEndHeight = math.max(edge.p0.z, edge.p1.z)
		local minStartEndHeight = math.min(edge.p0.z, edge.p1.z)
		context.gradients[0] = 0
		local maxHeightAboveTerrain = 0
		for i = 1, numberOfNodes do
			local p = routePoints[i].p
			context.terrainHeights[i]=util.th(p)
			local thAdj = util.th(p, true)
			context.maxTerrainHeights[i]=math.max(thAdj, context.terrainHeights[i])
			context.minTerrainHeights[i]=math.min(thAdj, context.terrainHeights[i])
			context.hermiteHeights[i]=p.z
			maxHeightAboveTerrain = math.max(context.hermiteHeights[i]-context.terrainHeights[i], maxHeightAboveTerrain)
			context.gradients[i]=leftGrad(i)
			if routePoints[i].spiralPoint then
				context.hasSpiralPoints = true
			end
			if i <= 3 or i >= numberOfNodes-2 then 
				if routePoints[i].followRoute then 
					routePoints[i].frozen = true  
				end 
			end 
			if routePoints[i].frozen then
				context.lockedHeights[i]=true
				context.frozen[i]=true
			end
			context.leftLengths[i]=getActualLength(i)
			context.rightLengths[i]=getActualLength(i+1)
			context.townBuildingCount[i] = util.countNearbyEntities (p, 150, "TOWN_BUILDING")

		end
		context.terrainHeights[numberOfNodes+1] = edge.p1.z -- fixed
		context.hermiteHeights[numberOfNodes+1] = edge.p1.z
		context.gradients[numberOfNodes+1]=0
		if maxHeightAboveTerrain > 50 then 
			trace("detected large height above terrain, adjusting to maximum gradient")
			params.maxGradient = params.absoluteMaxGradient 
			maxGradient = params.maxGradient
		end
		context.actualHeights = {}
		context.minHeights = {}
		context.maxHeights = {}
		local waterPointStart = -1
		 
		for i, h in pairs(context.terrainHeights) do
			local minh = minHeight
			if h < util.getWaterLevel() then 
				local distToNearestWaterVertex = util.distanceToNearestWaterVertex(routePoints[i].p) 
				trace("Inspecting height ",h," at ",i, " distToNearestWaterVertex was ",distToNearestWaterVertex)
				if distToNearestWaterVertex > 150 and h > -10 then 
					context.falseWaterPoints[i]=true
				else 
					minh = math.max(minh, minBridgeHeight+waterLevel)
					if waterPointStart == -1 then
						waterPointStart = i 
					end 
				end
			elseif waterPointStart ~= -1 then 
				local waterPointEnd = i-1 
				local midPoint = (waterPointStart+waterPointEnd)/2
				context.minHeights[math.floor(midPoint)] = math.max(params.minimumWaterMeshClearance+waterLevel, context.minHeights[math.floor(midPoint)])
				context.minHeights[math.ceil(midPoint)] = math.max(params.minimumWaterMeshClearance+waterLevel, context.minHeights[math.ceil(midPoint)])
				if waterPointStart - waterPointEnd >= 6 then
					context.minHeights[math.floor(midPoint)-1] = math.max(params.minimumWaterMeshClearance+waterLevel, context.minHeights[math.floor(midPoint)-1])
					context.minHeights[math.ceil(midPoint)+1] = math.max(params.minimumWaterMeshClearance+waterLevel, context.minHeights[math.ceil(midPoint)+1])
				end
				waterPointStart = -1
			end
			local tolerance = params.isTrack and 40 or 50
			if api.res.getBaseConfig().climate == "dry.clima.lua" then 
				tolerance = tolerance - 10
			end
			if h > tolerance+maxStartEndHeight then 
				context.suppressSmoothToTerrain[i] = true 
			end
			context.minHeights[i] = minh
			context.maxHeights[i] = math.huge
		end
		context.minHeights[0] = context.hermiteHeights[0]
		context.minHeights[numberOfNodes+1]=context.hermiteHeights[numberOfNodes+1]
		context.maxHeights[0] =  context.hermiteHeights[0]
		context.maxHeights[numberOfNodes+1]=context.hermiteHeights[numberOfNodes+1]
		context.actualHeights[0] =  context.hermiteHeights[0]
		context.actualHeights[numberOfNodes+1]=context.hermiteHeights[numberOfNodes+1]
		local absoluteMaxGradient = params.absoluteMaxGradient
		for i = 1, numberOfNodes do 
			local minBefore = context.minHeights[i-1]
			local minh = context.minHeights[i]
			local maxDeltaz = absoluteMaxGradient * getActualLength(i)
			context.minHeights[i]= math.max(minh, minBefore-maxDeltaz)	
				
		end
		for i = numberOfNodes, 1, -1 do 
			local minBefore = context.minHeights[i+1]
			local minh = context.minHeights[i]
			local maxDeltaz = absoluteMaxGradient * getActualLength(i+1)
			context.minHeights[i]= math.max(minh, minBefore-maxDeltaz)	
		end	
		for i = 1, numberOfNodes do 
			local maxBefore = context.maxHeights[i-1]
			local maxh = context.maxHeights[i]
			local maxDeltaz = absoluteMaxGradient * getActualLength(i)
			context.maxHeights[i]= math.max(context.minHeights[i], math.min(maxh, maxBefore+maxDeltaz))	
		end
		for i = numberOfNodes, 1, -1 do 
			local maxBefore = context.maxHeights[i+1]
			local maxh = context.maxHeights[i]
			local maxDeltaz = absoluteMaxGradient * getActualLength(i+1)
			context.maxHeights[i]= math.max(context.minHeights[i], math.min(maxh, maxBefore+maxDeltaz))	
		end				
		for i = 1, numberOfNodes do 
			context.actualHeights[i]=context.hermiteHeights[i]
		end 
		
		
		searchForTunnels(1)
		
		for i = 1, numberOfNodes do
			local h = context.terrainHeights[i]
			if routePoints[i].minHeight then 
				context.minHeights[i] = math.max(context.minHeights[i], routePoints[i].minHeight)
				context.maxHeights[i] = math.max(context.maxHeights[i], routePoints[i].minHeight)--need to ensure we keep this valid
				trace("Overriding minHeight at i=",i," to ",routePoints[i].minHeight)
			end 
			if routePoints[i].maxHeight then
				context.minHeights[i] = math.min(context.minHeights[i], routePoints[i].maxHeight)
				context.maxHeights[i] = math.min(context.maxHeights[i], routePoints[i].maxHeight)
				trace("Overriding maxHeight at i=",i," to ",routePoints[i].maxHeight)
			end 			
			local minh = context.minHeights[i] 
			local maxh = context.maxHeights[i]
			local setHeight = context.suppressSmoothToTerrain[i] and context.actualHeights[i-1] or h+terrainOffset
			if not context.tunnelHeights[i] then 
				context.actualHeights[i]=math.min(math.max(setHeight,minh), maxh)
			end 
			if routePoints[i].frozen then
				local h = context.hermiteHeights[i]
				if routePoints[i].minHeight then 
					h = math.max(h, routePoints[i].minHeight)
				end 
				if routePoints[i].maxHeight then 
					h = math.min(h, routePoints[i].maxHeight)
				end
				context.actualHeights[i]=h
			end
			context.hermiteHeights[i]=math.min(math.max(context.hermiteHeights[i]+terrainOffset, minh),maxh)
		end
		if util.tracelog then debugPrint({minHeights=context.minHeights, maxHeights = context.maxHeights, terrainHeights=context.terrainHeights, initialActualHeights=context.actualHeights}) end
		if context.hasSpiralPoints then
			context.actualHeights = util.deepClone(context.hermiteHeights)
		else
			local count = 0 
			while(smooth(1, numberOfNodes) and count < 10) do
				count = count + 1
			end
		end
		if math.abs(edge.p0.z - edge.p1.z)/edgeLength > maxGradient then
			context.needsspiral = true
		end
		
		trace("context.actualHeights[0]=",context.actualHeights[0],"context.terrainHeights[numberOfNodes+1]=",context.terrainHeights[numberOfNodes+1],"edge.p1.z=",edge.p1.z, "maxGradient=",maxGradient, "isTrack=",params.isTrack)
		local intersectingEntitiesAlreadySeen = {}
		-- the first and last road nodes are deconflicted by the routebuilder by rotating 90 degrees
		local startAt = params.isTrack and 2 or 3 
		local endAt = params.isTrack and numberOfNodes or numberOfNodes-1
		for i = startAt , endAt  do -- skipping first and last as false results from the connect stations
			local p0 = routePoints[i-1].p
			local p1 = routePoints[i].p
			local t0 = routePoints[i-1].t2
			local t1 = routePoints[i-1].t
			local edge = { p0=p0, p1=p1, t0=t0, t1=t1}
			local length = util.calculateSegmentLengthFromNewEdge(edge)
			local searchIntervalDist =  params.edgeWidth
			local searchIntervals = math.ceil(length / searchIntervalDist)
			local searchInterval = 1 / searchIntervals
			trace("Searching for collisions at ",searchInterval, " of ", searchIntervals, " for a dist ",searchIntervalDist, " edgeLength was ",length)
			local count =0 
			local entityCount = 0
			
			for j = 0,  searchIntervals do 
				local hermiteFraction = j / searchIntervals 
				--trace("Doing search at hermite fraction=",hermiteFraction)
				count = count + 1
				local testP = util.solveForPositionHermiteFraction(hermiteFraction, edge).p
				for entity, boundingVolume in pairs(util.findIntersectingEntitiesAndVolume(testP, params.edgeWidth/2, 100)) do 
					--debugPrint({entity=entity, boundingVolume=boundingVolume})
					entityCount = entityCount+1
					if not intersectingEntitiesAlreadySeen[entity] and entity > 0 then 
						
						local entityDetails = util.getEntity(entity)
						if entityDetails then 
							if entityDetails.type == "CONSTRUCTION" and (#entityDetails.townBuildings == 0 or i > 5 and i < numberOfNodes-4)
							then 
								local minz = boundingVolume.bbox.min.z - params.minZoffset
								local maxz = boundingVolume.bbox.max.z + params.minZoffsetSuspension -- assume we will need a large span
								local theirPos =  util.getConstructionPosition(entity)
								local distToTheirs = util.distance(theirPos, testP)
								local idx = indexOfClosestPoint(theirPos, routePoints)
								distToTheirs = math.min(distToTheirs, vec2.distance(routePoints[idx].p, theirPos)) 
								if idx >= numberOfNodes then 
									idx = numberOfNodes -1 
								end 
								if idx <= 1 then 
									idx = 2 
								end 
								local idx2 
								if vec2.distance(routePoints[idx+1].p, theirPos) < vec2.distance(routePoints[idx-1].p, theirPos) then 
									idx2 = idx+1
								else 
									idx2 = idx-1
								end 
								local isAirport =  string.find(entityDetails.fileName,"airport") or string.find(entityDetails.fileName, "airfield")
								trace("Discovered a construction on route, i=",i," j=",j," minz=",minz, " maxz = ",maxz, " testP=",testP.x,testP.y, "id=",entity, "distToTheirs=",distToTheirs, "closest was",idx, " second closest was ",idx2,"isAirport?",isAirport)
								local lpos = routePoints[i-1]
								local pPos = routePoints[i]
								if isAirport then 
									idx = i-1 
									idx2 = i
								end 
								
								local testBuild = trialBuildBetweenPoints(lpos, pPos)
								trace("Attempt of test build was ", testBuild.isError) 
								if not testBuild.isError or pPos.spiralPoint then 
									goto continue 
								end
								if #entityDetails.simBuildings > 0 and distToTheirs > 120 then 
									trace("Skipping as the building should be cleared")
									goto continue
								end
								if not isAirport then 
									intersectingEntitiesAlreadySeen[entity] = true   -- need to set this flag here to make sure we test again in next section. airports are big so may require multiple points deconfliction
								end
								if context.actualHeights[idx] < minz and context.actualHeights[idx2] < minz and not isAirport then 
									trace("We are under the construction")
									context.tunnelHeights[idx2]=context.actualHeights[idx2]
									context.tunnelHeights[idx]=context.actualHeights[idx]
									context.maxHeights[idx2]=math.min(context.maxHeights[idx2], minz)
									context.maxHeights[idx]=math.min(context.maxHeights[idx], minz)
								elseif   context.actualHeights[idx] > maxz and context.actualHeights[idx2] > maxz and not isAirport then 
									trace("We are above the construction")
									context.minHeights[idx2]=math.max(context.minHeights[idx2], maxz)
									context.minHeights[idx]=math.max(context.minHeights[idx], maxz)
									routePoints[idx].needsSuspensionBridge = true
									routePoints[idx2].needsSuspensionBridge = true
								else 
								
									local ourMinHeight = math.max(context.minHeights[idx], context.minHeights[idx2])
									local ourMaxHeight = math.min(context.maxHeights[idx], context.maxHeights[idx2])
									local canGoUnder = ourMinHeight <= minz or isAirport -- force going under an aiport
									local canGoAbove = ourMaxHeight >= maxz and not isAirport
									trace("Construction is in the way, will need adjustment canGoUnder=",canGoUnder, " canGoAbove=",canGoAbove, " ourMinHeight=",ourMinHeight,"minz=",minz,"ourMaxHeight=",ourMaxHeight,"maxZ=",maxZ,"isAirport?",isAirport)
									if not canGoAbove and not canGoUnder and not lpos.spiralPoint and not pPos.spiralPoint then 
										trace("WARNING! Construction with entityId",entity," can neightr go above or below, attempting to compensate")
										local offsetAbove = maxz - ourMaxHeight
										local offsetBelow = ourMinHeight - minz  
										trace("The offsetAbove was",offsetAbove," the offsetBelow was",offsetBelow)
										if offsetAbove < offsetBelow and not isAirport then 
											trace("Choosing to go above")
											canGoAbove = true 
											maxz = ourMaxHeight
										else 
											trace("choosing to go below")
											canGoUnder = true 
											maxz = ourMinHeight
										end 
									end 
									
									-- preference is to go under, bridiging has a chance to fail
									if canGoUnder  then 
										trace("attempting to go under z= ",minz) 
										context.actualHeights[idx2] = minz 
										context.actualHeights[idx] = minz 
										context.tunnelHeights[idx2]=context.actualHeights[idx2]
										context.tunnelHeights[idx]=context.actualHeights[idx]
										context.maxHeights[idx2]=math.min(context.maxHeights[idx2], minz)
										context.maxHeights[idx]=math.min(context.maxHeights[idx], minz)
										context.minHeights[idx2]=math.min(context.minHeights[idx2], minz)
										context.minHeights[idx]=math.min(context.minHeights[idx], minz)
										if isAirport then 
											local distToEnd = 0 
											local distToStart = 0 
											for i = idx2, numberOfNodes+1 do 
												distToEnd = distToEnd + getActualLength(i)
											end 
											for i = 1, idx do 
												distToStart = distToStart + getActualLength(i)
											end 
											-- allow exceed max gradient but do it in a consistent way
											local newMaxEndGrad =  math.max(params.absoluteMaxGradient, math.abs(minz-routePoints[numberOfNodes+1].p.z)/distToEnd)
											local newMaxStartGrad =  math.max(params.absoluteMaxGradient, math.abs(minz-routePoints[0].p.z)/distToStart)
											trace("For airport recalculated max grads were",newMaxEndGrad,newMaxStartGrad)
											params.absoluteMaxGradient = math.max(params.absoluteMaxGradient, math.max(newMaxEndGrad, newMaxStartGrad))
											local distFromCollision = 0
											for i = idx, 1, -1 do 
												distFromCollision = distFromCollision + getActualLength(i)
												local recalculatedMinz = newMaxStartGrad*distFromCollision+minz
												trace("Going to start set the new max height to ",recalculatedMinz,"context.maxHeights[i]=",context.maxHeights[i],"at i=",i)
												--context.maxHeights[i]=math.min(context.maxHeights[i], minz)
												context.maxHeights[i]=math.min(context.maxHeights[i], recalculatedMinz)
												context.minHeights[i]=math.min(context.minHeights[i], context.maxHeights[i])
											end 
											local distFromCollision = 0
											for i = idx2, numberOfNodes do 
												distFromCollision = distFromCollision + getActualLength(i)
												local recalculatedMinz = newMaxEndGrad*distFromCollision+minz
												trace("Going to end set the new max height to ",recalculatedMinz,"context.maxHeights[i]=",context.maxHeights[i],"at i=",i)
												--context.maxHeights[i]=math.min(context.maxHeights[i], minz)
												context.maxHeights[i]=math.min(context.maxHeights[i], recalculatedMinz)
												context.minHeights[i]=math.min(context.minHeights[i], context.maxHeights[i])
											end
											
											
										end 
										
										smooth(math.max(idx,idx2), numberOfNodes)
										reversesmooth(math.min(idx,idx2), 1)
									elseif  canGoAbove then 
										trace("attempting to go above z= ",maxz)
										context.actualHeights[idx2] = maxz 
										context.actualHeights[idx] = maxz  
										context.minHeights[idx2]=math.max(context.minHeights[idx2], maxz)
										context.minHeights[idx]=math.max(context.minHeights[idx], maxz)
										context.maxHeights[idx2]=math.max(context.maxHeights[idx2], maxz)
										context.maxHeights[idx]=math.max(context.maxHeights[idx], maxz)
										routePoints[idx].needsSuspensionBridge = true
										routePoints[idx2].needsSuspensionBridge = true
										smooth(math.max(idx,idx2), numberOfNodes)
										reversesmooth(math.min(idx,idx2), 1)
									else 
										trace("Unable to apply height offset!")
									end
									
									
								end
								
							end 
						else 
							trace("Found entity not recognised ",entity)
						end
						
					end
					::continue::
				end 
			end 
			trace("Searched ",count," positions and discovered", entityCount)
		end
		--[[for i = 1, numberOfNodes do 
			routePoints[i].t.z = context.actualHeights[i]-context.actualHeights[i-1]
			routePoints[i].t2.z = context.actualHeights[i+1]-context.actualHeights[i]
		end
		for i = 1, numberOfNodes do
			local tz = 0.5*(routePoints[i].t.z+routePoints[i].t2.z)
			--routePoints[i].t.z = tz 
			--routePoints[i].t2.z = tz 
			trace("Setting t.z at routepoints",routePoints[i].t.z,routePoints[i].t2.z,"tz=",tz)
		end]]--
		-- need to inspect collisions at the end of the route to avoid busting gradient limits if there are prior collisions
		local lastPoint = routePoints[numberOfNodes].p 
		local searchCircle = { radius=0.9*util.distance(lastPoint, routePoints[numberOfNodes+1].p), pos= { lastPoint.x,  lastPoint.y,  lastPoint.z, }}
		
		local endEdges = game.interface.getEntities(searchCircle, {type="BASE_EDGE", includeData=true})
 
		local combinedEdge = util.createCombinedEdge(routePoints[numberOfNodes-1], routePoints[numberOfNodes], routePoints[numberOfNodes+1])
	  	local collisionInfo = buildAndSortCollisionInfo(endEdges, combinedEdge, params, numberOfNodes, numberOfNodes, routePoints)
		local maxCollisionHeight = -math.huge
		local minCollisionHeight = math.huge 
		local ourCollisionHeight 
		for i = 1, #collisionInfo.collisionEdges do 
			if collisionInfo.collisionEdges[i].edge.track or util.getStreetTypeCategory(collisionInfo.collisionEdges[i].edge.id) =="highway" then 
				local theirSolution = collisionInfo.collisionEdges[i].c.existingEdgeSolution
				local ourSolution = collisionInfo.collisionEdges[i].c.newEdgeSolution
				local deltaz = ourSolution.p1.z - theirSolution.p1.z 
				if math.abs(deltaz) < params.minZoffset then 
					trace("Found a collision near the end")
					ourCollisionHeight = ourSolution.p1.z 
				end 
				maxCollisionHeight = math.max(maxCollisionHeight, theirSolution.p1.z)
				minCollisionHeight = math.min(minCollisionHeight, theirSolution.p1.z)
			end
			
		end 
		if ourCollisionHeight then 
			local canGoAbove = maxCollisionHeight + params.minZoffset <= context.maxHeights[numberOfNodes] 
			local canGoUnder = minCollisionHeight - params.minZoffset >= context.minHeights[numberOfNodes]
			trace("End point collision found, canGoAbove?",canGoAbove, " canGoUnder?",canGoUnder)
			if canGoAbove and not canGoUnder then 
				context.minHeights[numberOfNodes] = math.max(context.minHeights[numberOfNodes], maxCollisionHeight + params.minZoffset)
			elseif canGoUnder and not canGoAbove then 
				context.maxHeights[numberOfNodes] = math.min(context.maxHeights[numberOfNodes], minCollisionHeight - params.minZoffset)
			elseif not canGoUnder and not canGoAbove then 
				trace("WARNING! problematic end point discovered") 
				for i = 1, params.minZoffset do
					local reducedOffset = params.minZoffset-i 
					
					canGoAbove = maxCollisionHeight + reducedOffset <= context.maxHeights[numberOfNodes] 
					canGoUnder = minCollisionHeight - reducedOffset >= context.minHeights[numberOfNodes]
					if canGoAbove then 
						trace("Was able to go above with a reduced offset of ",reducedOffset)
						context.minHeights[numberOfNodes] = math.max(context.minHeights[numberOfNodes], maxCollisionHeight +reducedOffset)
						break 
					end 
					if canGoUnder then 
						trace("Was able to go under with a reduced offset of ",reducedOffset)
						context.maxHeights[numberOfNodes] = math.min(context.maxHeights[numberOfNodes], minCollisionHeight - reducedOffset)
						break 
					end 
				end
			end 
			reversesmooth(numberOfNodes, 1)
		end 
	end

	

	
	local function searchForBridges(startFrom)
		context.bridgeMaxHeight = nil
		context.bridgeStartHeight = 0
		context.bridgeStart = -1
		context.bridgeEnd = -1
		context.bridgeEndHeight = 0
		context.bridgeLength = 0
		context.bridgeOverTerrain = nil
		local waterLevel = util.getWaterLevel()
		for i= startFrom, numberOfNodes do
			--if isTunnelCandidateFn(i) then
			--	searchForBridges(i+1)-- reset the context
			--	return
			--end
			local pleft = routePoints[i-1]
			local p = routePoints[i]
			local pright = routePoints[i+1]
			local terrainHeight = util.th(p.p)
			local leftterrainHeight = context.terrainHeights[i]
			local minterrainHeight = terrainHeight
			for k = 1, 31 do -- need to look at points along the segment
				local p2 = util.hermite((k/32) / totalsegs, pleft.p,pleft.t,pright.p,pright.t).p
				minterrainHeight = math.min(minterrainHeight, util.th(p.p))
			end
			-- search for bridges
			local leftGrad = leftGrad(i)
			local bridgeOverTerrain = terrainHeight < highestFrozen  and (context.actualHeights[i] >= minBridgeHeight+context.terrainHeights[i]) and not params.isElevated
 			trace("checking for bridge at i=", i, " terrainHeight=", terrainHeight, " x,y=", p.x, ",", p.y, " minterrainHeight=", minterrainHeight, "leftgrad=",leftGrad, "bridgeOverTerrain=",bridgeOverTerrain)
			if (minterrainHeight <waterLevel and not context.falseWaterPoints[i]) or bridgeOverTerrain then 
				if context.bridgeStart == -1 then 
					context.bridgeStart = i-1
					context.bridgeLength = 1
					context.bridgeOverTerrain = minterrainHeight >waterLevel and context.terrainHeights[i+1] > waterLevel
					--context.bridgeStartHeight = minterrainHeight < 0 and context.terrainHeights[i-1]+minBridgeHeightAboveGround or context.actualHeights[i-1]
					context.bridgeStartHeight = math.max(context.terrainHeights[i-1]+minBridgeHeightAboveGround , context.actualHeights[i-1])
					if i == 1 then 
						context.bridgeStartHeight = context.actualHeights[0]
					elseif not routePoints[i-1].followRoute then  
						context.actualHeights[i-1]=context.bridgeStartHeight
					end
					if not routePoints[i].followRoute then 
						context.actualHeights[i]= math.max(context.bridgeStartHeight, context.minHeights[i])
					end
					
					if i > 1 and not context.bridgeOverTerrain then
						-- smooth out ramp
						context.bridgeStartHeight = math.max(context.minHeights[i],  math.max(context.bridgeStartHeight, context.terrainHeights[i-2]))
						if math.abs(context.actualHeights[i]-context.terrainHeights[i]) < 50 then 
							context.suppressSmoothToTerrain[i] = true
							context.suppressSmoothToTerrain[i-1] = true
						end
						reversesmooth(i-1, 1)
					end
						 
					
					local maxSlopeBuild = maxBuildSlope(params)
					--[[
					if i == 1 and terrainHeight < 0 and not (params.isElevated or routePoints[0].p.z > 10)then
						trace("detected early bridge start")
						for k = 5,1, -1 do
							local testP = util.hermite((k/6), pleft.p,pleft.t,p.p,p.t).p
							if util.isUnderwater(testP) then 
								routePoints[i].p=testP
								local distToStart = util.distance(pleft.p, testP)
								routePoints[i].t = distToStart*vec3.normalize(routePoints[i].t)
								trace("Shifting start point by factor ",k/12)
								local maxDeltaZ = maxSlopeBuild*distToStart
								local newZ = maxDeltaZ + pleft.p.z 
								if newZ < context.bridgeStartHeight then 
									trace("new height is ",newZ)
									context.bridgeStartHeight=newZ
									routePoints[i].p.z=newZ
									routePoints[i].t.z=maxDeltaZ
									context.actualHeights[i]=newZ
									context.lockedHeights[i]=true
								end
								routePoints[i].t2 = util.distance(pright.p, testP)*vec3.normalize(routePoints[i].t)
							end
						end
					end
					if i == numberOfNodes and terrainHeight < 0 and not (params.isElevated or routePoints[numberOfNodes+1].p.z > 10) then
						trace("detected late bridge end")
						for k = 1,5 do
							local testP = util.hermite((k/6), p.p,p.t,pright.p,pright.t).p
							if util.isUnderwater(testP) then 
								routePoints[i].p=testP
								local distToEnd = util.distance(pright.p, testP)
								routePoints[i].t2 = distToEnd*vec3.normalize(routePoints[i].t2)
								trace("Shifting end point by factor ",k/12)
								local maxDeltaZ = maxSlopeBuild*distToEnd
								local newZ = maxDeltaZ + pleft.p.z 
								if newZ < context.actualHeights[i] then 
									trace("new height is ",newZ)
									routePoints[i].p.z=newZ
									routePoints[i].t2.z=-maxDeltaZ
									context.actualHeights[i]=newZ
									context.lockedHeights[i]=true
								end
								routePoints[i].t = util.distance(pright.p, testP)*vec3.normalize(routePoints[i].t2)
							end
						end
					end
					]]--
					trace("bridge started at ", tostring(i-1), " context.bridgeStartHeight=", context.bridgeStartHeight)
				else 
					context.bridgeLength = context.bridgeLength + 1
					trace("bridge continued at ", tostring(i))
					if context.bridgeOverTerrain and context.terrainHeights[i] < waterLevel then
						trace("cancelling bridgeOverTerrain at ",i)
						context.bridgeOverTerrain = false
					elseif routePoints[i].needsSuspensionBridge then 
						context.needsSuspensionBridge = true
					end
				end
			elseif context.bridgeStart ~= -1 and context.bridgeEnd == -1 then
				-- short look ahead to the next two nodes as may form continuous bridge
				if not context.bridgeOverTerrain and ((i <numberOfNodes and context.terrainHeights[i+1] <waterLevel)
					or (i <numberOfNodes-1 and context.terrainHeights[i+2] <waterLevel)) then
					context.bridgeLength = context.bridgeLength + 1
					trace("bridge continued due to look ahead at ", tostring(i))
				else
					context.bridgeLength = context.bridgeLength + 1
					context.bridgeEnd = i
					context.bridgeEndHeight = math.max(terrainHeight+minBridgeHeightAboveGround, context.actualHeights[i])
					local exceedsMaxGradient = math.abs(context.bridgeEndHeight - context.bridgeStartHeight) / (context.bridgeLength * context.seglength) > maxGradient
					if exceedsMaxGradient then 
						if context.bridgeOverTerrain then
							trace("bridge cancelled at ", i, " due to high gradient")
							searchForBridges(i)
							return
						else 
							local maxDeltaZ = maxGradient * vec2.distance(routePoints[context.bridgeStart].p, routePoints[context.bridgeEnd].p)
							trace("correcting bridge height as the limit has been exceeded, start=", context.bridgeStartHeight, " end=",context.bridgeEndHeight, " maxDeltaZ=",maxDeltaZ)
							if context.bridgeEndHeight > context.bridgeStartHeight then 
								context.bridgeEndHeight = maxDeltaZ + context.bridgeStartHeight
							else 
								context.bridgeStartHeight = maxDeltaZ + context.bridgeEndHeight 
							end
							trace("After correction start=", context.bridgeStartHeight, " end=",context.bridgeEndHeight, " maxDeltaZ=",maxDeltaZ)
						end
					
					end
					 
					trace("bridge finished at ", tostring(i))
					
					local maximumBridgeEndHeight = routePoints[numberOfNodes+1].p.z + vec2.distance(routePoints[context.bridgeEnd].p, routePoints[numberOfNodes+1].p)*maxBuildSlope(params)
					trace("maximumBridgeEndHeight calculated as ",maximumBridgeEndHeight, "compared with ",context.bridgeEndHeight)
					if context.bridgeEndHeight > maximumBridgeEndHeight then 
						trace("Detected bridge height too high, ",context.bridgeEndHeight," vs ", maximumBridgeEndHeight)
						context.bridgeEndHeight = maximumBridgeEndHeight
					end
					if not context.bridgeOverTerrain then 
						local minHeight = params.minimumWaterMeshClearance
						local imid = (context.bridgeLength/2)
						-- want a quadratic curve, conditions are height and gradient at the edges
						-- h = ax^2 + b
						-- hmax = b 
						-- hmin = a(bridgelength/2)^2 + hmax 
						-- grad = 2 * a * bridgeLength / 2
						local segGrad = maxGradient*context.seglength
						local calcHmax = math.max(minHeight, imid^2*segGrad / context.bridgeLength + minBridgeHeight)
						
		
						context.bridgeMaxHeight = context.bridgeStartHeight
						
						for j = context.bridgeStart, context.bridgeEnd do 
							if routePoints[j].followRoute then 
								trace("skipping bridge calculation for followRoute")
								goto continue
							end
							local x = imid-j+context.bridgeStart+waterLevel
							local minheight = x > 0 and math.max(context.bridgeStartHeight, minBridgeHeight) or math.max(context.bridgeEndHeight, minBridgeHeight)
							local maxHeight = math.min(calcHmax, maxbridgeHeight)
							maxHeight = math.max(maxHeight,minheight) -- bridges to a high terrain point will be flat
							local a = (minheight - maxHeight)/imid^2
							--if x > 0 then x = math.floor(x) else x = math.ceil(x) end
							local result = maxHeight+a*x^2
							context.actualHeights[j]=math.max(result, context.minHeights[j])
							--context.minHeights[j]=context.actualHeights[j]
							context.bridgeMaxHeight = math.max(context.bridgeMaxHeight, context.actualHeights[j])
							local grad = -2*a*x
							routePoints[j].t.z=grad
							routePoints[j].t2.z=grad
							trace("bridge calculation for bridge over water, setting context.actualHeights[j]=",context.actualHeights[j],"j=",j," a=",a," x=",x," b=",b, " grad=",grad)
							::continue::
						end
					else
				
						local b = context.actualHeights[context.bridgeStart]
						local a = (context.bridgeEndHeight - b) / (context.bridgeLength+1)
					
						for j = context.bridgeStart, context.bridgeEnd do 
							if routePoints[j].followRoute then 
								trace("skipping bridge calculation for followRoute")
								goto continue
							end
							local x = j-context.bridgeStart
							
							context.actualHeights[j]=math.max(a*x + b, context.minHeights[j])
							if util.searchForFirstEntity(routePoints[j].p, 20, "SIM_BUILDING") then 
								trace("Discovered bridging industry at ",j," point ", routePoints[j].p.x, routePoints[j].p.y)
								context.needsSuspensionBridge = true 
							end
							routePoints[j].t.z=a
							routePoints[j].t2.z=a
							trace("bridge calculation for bridge over terrain, setting context.actualHeights[j]=",context.actualHeights[j],"j=",j," a=",a," x=",x," b=",b)
							::continue::
						end
						context.bridgeMaxHeight = math.max(b,context.actualHeights[context.bridgeEnd])
					end
					
					smooth(i+1, numberOfNodes)
					 
					break
				end
			end
			::continue::
		end
		if context.bridgeStart~=-1 and context.bridgeEnd==-1 then
			context.bridgeEnd=numberOfNodes
			context.bridgeLength=1+context.bridgeEnd-context.bridgeStart
			context.bridgeEndHeight = util.th(edge.p1)
			context.bridgeMaxHeight = math.max(context.bridgeEndHeight,context.bridgeStartHeight)
			context.suppressSmoothToTerrain[context.bridgeEnd]=true
			reversesmooth(numberOfNodes, context.bridgeStart)
			trace("bridge automatically finished at ", tostring(numberOfNodes))
		end
	
	end
	

	
	
	
	if nodeOrder == 1 and not context.hasSpiralPoints  then 
		searchForTunnels(nodeOrder)
		searchForBridges(nodeOrder)
		
	end
	local frozen = routePoints[nodeOrder].spiralPoint or routePoints[nodeOrder].frozen
	-- need three points for smooth z tangents
	local lpos = routePoints[nodeOrder-1] --  == 1 and { p = edge.p0, t = edge.t0 } or util.hermite(strictFrac-fracspace, edge.p0,edge.t0,edge.p1,edge.t1)
	local pPos = routePoints[nodeOrder] -- util.hermite(strictFrac, edge.p0,edge.t0,edge.p1,edge.t1)
	local rpos = routePoints[nodeOrder+1]-- nodeOrder == numberOfNodes and {p = edge.p1, t = edge.t1} or util.hermite(strictFrac+fracspace, edge.p0,edge.t0,edge.p1,edge.t1)


	lpos.p.z = context.actualHeights[nodeOrder-1]
	pPos.p.z = context.actualHeights[nodeOrder]
	rpos.p.z = context.actualHeights[nodeOrder+1]

	
	


	local tunnelCandidate = isTunnelCandidateFn(nodeOrder)
	local needsBridge = isBridge(nodeOrder)
	local needsSuspensionBridge = needsBridge and context.needsSuspensionBridge or routePoints[nodeOrder].needsSuspensionBridge

	if nodeOrder == context.bridgeEnd then
		searchForBridges(nodeOrder+1) -- look for the next bridge
	end
	
	if nodeOrder == context.tunnelEnd then
		searchForTunnels(nodeOrder+1) -- look for the next tunnel
	end
	
	-- collision check
	local searchRadius =  util.distance(rpos.p, lpos.p)
	local upperSearch = 0.5
	local lowerSearch = 0.5
	local searchPoint = util.v3(pPos.p)
	-- at the ends need to cover all the way to the start / final point
	if nodeOrder == 1 then 
		searchPoint = util.hermite(0.75, lpos.p, lpos.t, pPos.p, pPos.t).p
		searchRadius = 1.5*searchRadius
		lowerSearch = 0
	end
	if nodeOrder == numberOfNodes then
		searchPoint = util.hermite(0.25, pPos.p, pPos.t, rpos.p, rpos.t).p
		searchRadius = 1.5*searchRadius
		upperSearch = 1
	end
	
	local searchCircle = { radius=searchRadius, pos= { searchPoint.x,  searchPoint.y,  searchPoint.z, }}
	  -- if tracelog then debugPrint(searchCircle) end
	local nearbyEdges = game.interface.getEntities(searchCircle, {type="BASE_EDGE", includeData=true})
	--debugPrint({nearbyEdges = nearbyEdges})
	
	if util.size(nearbyEdges) > 0 then -- and nodeOrder > 1 and nodeOrder < numberOfNodes  and not context.collisionSegments[nodeOrder-1] 
		local pUp = util.solveForPositionHermiteFraction2(upperSearch, pPos.p, pPos.t, rpos.p, rpos.t)
		local pDown = util.solveForPositionHermiteFraction2(lowerSearch, lpos.p, lpos.t, pPos.p, pPos.t)
		--if tracelog then debugPrint({lpos=lpos, pDown=pDown, pPos=pPos ,pUp=pUp,rpos=rpos}) end
		trace("found ",util.size(nearbyEdges)," nearby edges at nodeOrder=",nodeOrder, " searchRadius=",searchRadius," x,y=", pPos.p.x, pPos.p.y)
		local combinedEdge = util.createCombinedEdge(lpos, pPos, rpos)
		local townBuildingCount =  #game.interface.getEntities(searchCircle, {type="TOWN_BUILDING", includeData=false})
		local hUp = util.solveForPositionHermite(pUp.p, combinedEdge)+0.1
		local hDown = util.solveForPositionHermite(pDown.p, combinedEdge)-0.1
		trace("Solution for hUp=",hUp," hDown=",hDown)
		local collisionInfo = buildAndSortCollisionInfo(nearbyEdges, combinedEdge, params, nodeOrder, numberOfNodes, routePoints)
		trace("At nodeOrder",nodeOrder, " found ",#collisionInfo.collisionEdges," edges")
		local endAt = #collisionInfo.collisionEdges
		if #collisionInfo.collisionEdges > 2 and townBuildingCount > 0 then
			local theirMinHeight = collisionInfo.minHeight
			local ourMinHeight = context.minHeights[nodeOrder] 
			local minRequired = theirMinHeight-params.minZoffset
			trace("Discovered a large number of collisionEdges. minRequired=",minRequired, " ourMinHeight=",ourMinHeight)
			if ourMinHeight <= minRequired  then
				trace("Attempting to pass under")
				context.maxHeights[nodeOrder+1] = math.max(context.minHeights[nodeOrder+1], math.min(context.maxHeights[nodeOrder+1], minRequired))
				context.maxHeights[nodeOrder] = math.min(context.maxHeights[nodeOrder], minRequired)
				context.maxHeights[nodeOrder-1] =math.max(context.minHeights[nodeOrder-1], math.min(context.maxHeights[nodeOrder-1], minRequired))
				pPos.z = minRequired
				tunnelCandidate = true 
				edgeTypeRequiredForDeconfliction = true 
				context.actualHeights[nodeOrder] = math.min(context.actualHeights[nodeOrder],minRequired)
				endAt = 0 
				smooth(nodeOrder, numberOfNodes)
			else 
				trace("Unable to pass under")
			end 
			
		
		end 
		for i = 1, endAt do
			local edge = collisionInfo.collisionEdges[i].edge
			local c = collisionInfo.collisionEdges[i].c
			trace("Inspecting potential collision edge at nodeOrder=",nodeOrder," edgeId=",edge.id, " was collision=",c~=nil, " hermiteFrac=",collisionInfo.collisionEdges[i].hermiteFrac,"followRoute=",routePoints[nodeOrder].followRoute)
			
			if c and c.otherEdge then -- where we collide very close to a node we may pick up an edge on both sides, only consider one of them though
				trace("Found another edge, ",c.otherEdge)
				if context.allCollisionEdges[c.otherEdge] then 
					trace("detected that this edge has already been processed by another edge, ",edge.id," and ",c.otherEdge)
					goto continue
				end 
					
				
			end 
			if context.allCollisionEdges[edge.id] or context.edgesToIgnore[edge.id] then
				trace("route preparation already seen ",edge.id," skipping")
				goto continue
			end
			local node0Pos = util.v3fromArr(edge.node0pos)
			local node1Pos = util.v3fromArr(edge.node1pos)
			if getActualLastSplit() then
					lpos = getActualLastSplit().pPos
			end
			local deadEndTrackNode = #util.getTrackSegmentsForNode(edge.node1)==1
				or #util.getTrackSegmentsForNode(edge.node0)==1
			local constructionId =  api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge.id)
			local tolerance = params.isTrack and 2 or 5 -- roads may pick up a collision at the start end points even though they are actually joining to them
			if c and collisionInfo.collisionEdges[i].hermiteFrac <= hUp and collisionInfo.collisionEdges[i].hermiteFrac >= hDown
				and not routePoints[nodeOrder].followRoute
				and -1 == constructionId 	
				and (not util.positionsEqual2d(c.c, routePoints[nodeOrder+1].p,tolerance)
					and not util.positionsEqual2d(c.c, routePoints[nodeOrder-1].p,tolerance)
					and not util.positionsEqual2d(c.c,lpos.p,tolerance)
					and not (params.otherLeftNodePos and util.positionsEqual2d(c.c,params.otherLeftNodePos,tolerance))
					and not (params.otherRightNodePos and util.positionsEqual2d(c.c,params.otherRightNodePos,tolerance))
					and not (#newSplitPoints > 0 and util.positionsEqual2d(c.c, newSplitPoints[#newSplitPoints].pPos.p, tolerance))
					and not deadEndTrackNode 
					
					or params.collisionEntities and params.collisionEntities[edge.id]
				)
				then
				
				
				if nodeOrder == 1 and ( util.positionsEqual2d(util.v3fromArr(edge.node0pos), routePoints[0].p,tolerance)
					or util.positionsEqual2d(util.v3fromArr(edge.node1pos), routePoints[0].p,tolerance)) 
					then 
					trace("False collision found with edge",edge.id)
					context.allCollisionEdges[edge.id] =true 
					goto continue
				end
				if nodeOrder == numberOfNodes and ( util.positionsEqual2d(util.v3fromArr(edge.node0pos), routePoints[nodeOrder+1].p,tolerance)
					or util.positionsEqual2d(util.v3fromArr(edge.node1pos), routePoints[nodeOrder+1].p,tolerance)) 
					then 
					trace("False collision found with edge",edge.id)
					context.allCollisionEdges[edge.id] =true 
					goto continue
				end
				
				trace("Processing collision edge at nodeOrder=",nodeOrder," edgeId=",edge.id)
				local theyAreHighway = not edge.track and util.getStreetTypeCategory(edge.id)=="highway"
				collissionThisSplit = true 
				if c.otherEdge then
					context.edgesToIgnore[c.otherEdge] = true -- prevent double processing
				end
				local leftSegs = util.getSegmentsForNode(edge.node0)
				local rightSegs =  util.getSegmentsForNode(edge.node1)
				local leftConnectedSeg = leftSegs[1] == edge.id and leftSegs[2] or leftSegs[1]
				local rightConnectedSeg = rightSegs[1] == edge.id and rightSegs[2] or rightSegs[1]
				if #leftSegs == 2 then
					--trace("Marking leftConnectedSeg ",leftConnectedSeg," as ignored")
					--context.edgesToIgnore[leftConnectedSeg]=true
				end 
				if #rightSegs == 2 then 
					--trace("Marking rightConnectedSeg ",rightConnectedSeg," as ignored")
					--context.edgesToIgnore[rightConnectedSeg]=true
				end
				local overrideCanCrossAtGrade = not canGoUnder and not canGoAbove and (#rightSegs > 2 or #leftSegs > 2)
				trace("Setting overrideCanCrossAtGrade to",overrideCanCrossAtGrade)
				local canCrossAtGrade
				if not params.isTrack and not edge.track then -- road to road
					canCrossAtGrade = true
				elseif params.isTrack and edge.track then -- track to track - always grade seperate 
					canCrossAtGrade = false 
				elseif params.isHighSpeedTrack or edgeIsHighSpeedTrack(edge.id) then
					canCrossAtGrade = overrideCanCrossAtGrade or paramHelper.getParams().allowGradeCrossingsHighSpeedTrack
				else 
					canCrossAtGrade = overrideCanCrossAtGrade or params.allowGradeCrossings
				end
				local doubleTrackEdge = edge.track and util.findDoubleTrackEdge(edge.id, 2)
				if canCrossAtGrade and not params.isTrack and edge.track and doubleTrackEdge then 
					canCrossAtGrade = false -- don't have the logic for building a road across double track
				end
				if params.isHighway or util.getStreetTypeCategory(edge.id) == "highway" then 
					canCrossAtGrade = false
				end
				if util.isFrozenEdge(edge.id) then 
					canCrossAtGrade = false 
				end
				if params.isQuadrupleTrack then 
					canCrossAtGrade = false 
				end
				if util.getEdge(edge.id).type ~= 0 and params.isTrack  then -- technically possible but doesn't look good
					canCrossAtGrade = false 
				end 
				if util.isNodeConnectedToFrozenEdge(edge.node0) and vec2.distance(c.c, util.nodePos(edge.node0)) < 10+params.edgeWidth then 
					trace("Overriding canCrossAtGrade to false for node",edge.node0,"connected to frozen edge")
					canCrossAtGrade = false 
				end 
				if util.isNodeConnectedToFrozenEdge(edge.node1) and vec2.distance(c.c, util.nodePos(edge.node1)) < 10+params.edgeWidth then 
					canCrossAtGrade = false 
					trace("Overriding canCrossAtGrade to false for node",edge.node1,"connected to frozen edge")
				end 
				rpos = routePoints[nodeOrder+1] -- just in case it was changed
				local ourEdge = util.createCombinedEdge(lpos, pPos, rpos)
				local ourActualEdge = ourEdge
				--[[if params.isDoubleTrack and not params.isHighSpeedTrack and not params.isHighway then 
					ourEdge = {
						p0 = util.nodePointPerpendicularOffset(ourActualEdge.p0, ourActualEdge.t0, 0.5*params.trackWidth),
						p1 = util.nodePointPerpendicularOffset(ourActualEdge.p1, ourActualEdge.t1, 0.5*params.trackWidth),
						t0 = ourActualEdge.t0 ,
						t1 = ourActualEdge.t1
					}
				end ]]--
				local checkForDoubleTrack = true 
				local allowEdgeExpansion = false 
				local solveTheirOuterEdge = #leftSegs == 2 and #rightSegs==2 and not canCrossAtGrade
				local solution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c.c, edge.id, ourEdge,vec2.distance, checkForDoubleTrack, allowEdgeExpansion, solveTheirOuterEdge)
				local theirPos = solution.existingEdgeSolution
				local newPos = solution.newEdgeSolution
				if theyAreHighway then 
					local otherEdge = util.findParallelHighwayEdge(edge.id, 25)
					if otherEdge then 
						local solution2 = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c.c, otherEdge, ourEdge,vec2.distance, checkForDoubleTrack, allowEdgeExpansion, solveTheirOuterEdge)
						trace("Solving for the highway other edge, converged?",solution2.newEdgeSolution.solutionConverged )
						if solution2.newEdgeSolution.solutionConverged then 
							
							local newP = 0.5*(newPos.p1+solution2.newEdgeSolution.p1)
							local newSolution = util.solveForPosition(newP, ourEdge) 
							trace("Combining solutions for highway crossing, newsolution converged?", newSolution.solutionConverged)
							if newSolution.solutionConverged then 
								newPos = newSolution
							end
						end 
					end 
				end 
				
				local deltaz = newPos.p1.z - theirPos.p1.z
				if math.abs(deltaz) > 8 then 
					trace("Forcing canCrossAtGrade to false due to deltaz",deltaz)
					canCrossAtGrade = false 
				end
				if routePoints[nodeOrder].spiralPoint then 
					if not collisionSegments then
						collisionSegments={}					
					end
					trace("We are spiral point, setting theirs to adjust for edge",edge.id)
					table.insert(collisionSegments, {
						edge = edge,
						deltaz = deltaz,
						remainingDeltaz = -deltaz,
						applyNodeOffsetsOnly = true,
						theirPos = theirPos,
						ourZCorrection = 0
					}) 
					goto continue
				end
				local theirEdge = util.getEdge(edge.id)
				local theirsIsBridge = theirEdge.type == 1
				local theirsIsTunnel = theirEdge.type == 2
				local minimumClearanceRequired = params.minZoffset
				if deltaz > 0 and not edge.track then 
					minimumClearanceRequired = params.minZoffsetRoad
					if theirsIsTunnel then 
						minimumClearanceRequired = 8
					end
				end
				if deltaz < 0 and not params.isTrack then 
					minimumClearanceRequired = params.minZoffsetRoad
				end 
				local isWithinClearance = math.abs(deltaz) >= minimumClearanceRequired
				if not isWithinClearance and (params.isTrack or params.isHighway) and nodeOrder > 1 and nodeOrder < numberOfNodes and not edge.track then 
					local reRoute = checkIfRoadRouteRecollides(edge, routePoints, nodeOrder, numberOfNodes, c, context, params) 
					if reRoute then 
						if not collisionSegments then
							collisionSegments={}					
						end
						table.insert(collisionSegments, {
							edge = edge,
							reRoute = reRoute
						})
						goto continue
					end
				end 
				if not isWithinClearance and params.isTrack and edgeIsRemovable(edge, nodeOrder, numberOfNodes, params) then 
					if not collisionSegments then
						collisionSegments={}					
					end
					table.insert(collisionSegments, {
						edge = edge,
						removeEdge = true
					})
					if c.otherEdge and edgeIsRemovable(util.getEntity(c.otherEdge), nodeOrder, numberOfNodes, params) then 
							table.insert(collisionSegments, {
							edge = util.getEntity(edge),
							removeEdge = true
						})
						context.allCollisionEdges[c.otherEdge]=true
					end
					goto continue 
				end
				
				local function edgeHasRoadRailCrossing(edge)
					if #util.getTrackSegmentsForNode(edge.node0) > 0 and #util.getStreetSegmentsForNode(edge.node0) > 0 then 
						return true 
					end
					if #util.getTrackSegmentsForNode(edge.node1) > 0 and #util.getStreetSegmentsForNode(edge.node1) > 0 then 
						return true 
					end
					return false
				end
				
				local function isHardProblematicEdge(edge)
					for __, node in pairs({edge.node0, edge.node1}) do 
						for __, seg in pairs(util.getSegmentsForNode(node)) do 
							if util.isFrozenEdge(seg) or util.isIndustryEdge(seg) or util.isOriginalBridge(seg) or util.edgeHasTpLinks(seg) then 
								return true 
							end
						end 
					end  
					return false
				end 
				
				local function isProblematicEdge(edge, allowJunctionNode)
					if type(edge)=="number" then 
						edge = util.getEntity(edge) 
					end
					trace("Inspecting ",edge.id," to see if it is problematic")
					if collisionInfo.hasJunctionEdges and not allowJunctionNode then 
						trace("junctionEdges detected")
						return true 
					end
					if edgeHasRoadRailCrossing(edge) then 
						trace("RoadRail detected")
						return true 
					end
					if edge.track and (util.findDoubleTrackNode(edge.node0, nil, 1,1) and util.findDoubleTrackNode(edge.node0, nil, 2,1, true)
									or  util.findDoubleTrackNode(edge.node1, nil, 1,1) and util.findDoubleTrackNode(edge.node1, nil, 2,1, true))
						then 
						trace("triple detected")
						return true --triple track
					end
					 
					
					if #util.getTrackSegmentsForNode(edge.node0) > 2 or #util.getTrackSegmentsForNode(edge.node1) > 2 then 
						trace("Track junction detected")
						return true 
					end
					local leftSegs = util.getSegmentsForNode(edge.node0)
					local rightSegs =  util.getSegmentsForNode(edge.node1)
					if (#leftSegs > 2 or #rightSegs > 2) and not allowJunctionNode then 
						return true
					end
					if collisionInfo.existingCollisionEdges[edge.id] then 
						trace("Track existingCollisionEdges detected")
						return true 
					end
					local leftConnectedSeg = leftSegs[1] == edge.id and leftSegs[2] or leftSegs[1]
					local rightConnectedSeg = rightSegs[1] == edge.id and rightSegs[2] or rightSegs[1]
					
					if not canCrossAtGrade then
						local leftEdge = util.getEdge(leftConnectedSeg)
						local outerLeftNode = leftEdge.node0 == edge.node0 and leftEdge.node1 or leftEdge.node1 
						local rightEdge = util.getEdge(rightConnectedSeg)
						local outerRightNode = rightEdge.node0 == edge.node1 and rightEdge.node1 or rightEdge.node1
						if #util.getSegmentsForNode(outerLeftNode) > 2  and not allowJunctionNode  or #util.getSegmentsForNode(outerRightNode)>2 and not allowJunctionNode  then 
							return true
						end 
					end 
					if not params.isTrack and not edge.track and util.getStreetTypeCategory(edge.id)=="highway" -- don't have the logic for "double track" roads may give odd results 
						and nodeOrder > 3 and nodeOrder < numberOfNodes -2 -- but allow near the ends where we may not be able to change z
						then 
						return true 
					end
					local theirGradient = math.max(math.max(math.abs(util.calculateEdgeGradient(edge.id)),math.abs(util.calculateEdgeGradient(rightConnectedSeg))),math.abs(util.calculateEdgeGradient(leftConnectedSeg)))
					if edge.track and theirGradient > 0.06 then 
						trace("High track gradient detected",theirGradient)
						return true 
					end 
					if not edge.track and theirGradient > 0.18 then 
						trace("High road gradient detected",theirGradient)
						return true 
					end
					
					return isHardProblematicEdge(edge)
				end
				
				
				
				local closeToEnds = util.distance(newPos.p1, routePoints[0].p) < 50 or util.distance(newPos.p1, routePoints[numberOfNodes+1].p) < 50
				if closeToEnds and not isWithinClearance and not util.isFrozenEdge(edge.id) and not edge.track and #util.getSegmentsForNode(edge.node0) == 2 and #util.getSegmentsForNode(edge.node1) == 2 and params.isTrack  and  util.getStreetTypeCategory(edge.id)~="highway" and util.getEdge(edge.id).type==0 then
					trace("Setting up a reroute for underpass , isTrack=",params.isTrack,"for edge",edge.id)
					context.allCollisionEdges[edge.id]=true
					local solution = util.solveForPosition(c.c, ourEdge) 
					local dist = util.calcEdgeLength(solution.p0, solution.p1, solution.t0, solution.t1)
					local totalDist = util.calculateSegmentLengthFromNewEdge(ourEdge)
				
					local reRoute = {}
					reRoute.edgeIds = {edge.id} 
					
					local theirEdgeWidth = util.getEdgeWidth(edge.id)
					local minDist = theirEdgeWidth+params.edgeWidth+15
					
					reRoute.startNode = edge.node0 	
					reRoute.endNode = edge.node1
					if util.distance(solution.p1, util.nodePos(edge.node0)) <= minDist then 
						local nextSegs = util.getSegmentsForNode(edge.node0)
						local nextEdgeId = edge.id == nextSegs[1] and nextSegs[2] or nextSegs[1]
						local nextEdge = util.getEdge(nextEdgeId)
						local nextNode = edge.node0 == nextEdge.node1 and nextEdge.node0 or nextEdge.node1 
						if #util.getSegmentsForNode(nextNode) == 2 then 
							trace("Settign reRoute.startNode to",nextNode)
							reRoute.startNode = nextNode 
							if not context.allCollisionEdges[nextEdgeId] then 
								table.insert(reRoute.edgeIds, nextEdgeId)
								context.allCollisionEdges[nextEdgeId] = true
							end
						else 
							trace("Suppressing using ",nextNode,"as rerouteNode for start node as it does not have the right number of segments")
						end 
					else 
						
					end
					if util.distance(solution.p1, util.nodePos(edge.node1)) <= minDist then 
						local nextSegs = util.getSegmentsForNode(edge.node1)
						local nextEdgeId = edge.id == nextSegs[1] and nextSegs[2] or nextSegs[1]
						local nextEdge = util.getEdge(nextEdgeId)
						local nextNode = edge.node1 == nextEdge.node1 and nextEdge.node0 or nextEdge.node1 
					
						if #util.getSegmentsForNode(nextNode) == 2 then 
							trace("Settign reRoute.endNode to",nextNode)
							reRoute.endNode = nextNode 
							if not context.allCollisionEdges[nextEdgeId] then 
								table.insert(reRoute.edgeIds, nextEdgeId)
								context.allCollisionEdges[nextEdgeId] = true
							end
						else 
							trace("Suppressing using ",nextNode,"as rerouteNode for start node as it does not have the right number of segments")
						end  
					end
					local parallelOffset = 60
					local desiredLength = dist + 60 
					if dist + parallelOffset > totalDist then 
						parallelOffset = -parallelOffset
					end
					--local desiredLength = dist + parallelOffset 
					--local newP = util.solveForPositionHermiteLength(desiredLength, ourEdge)
					--local leftPerpTangent = util.nodePos(reRoute.startNode)-c.c 
					reRoute.startTangent = parallelOffset*vec3.normalize(solution.t1) 
					--local leftp = newP.p + leftPerpTangent
					local leftp = util.nodePos(reRoute.startNode )+reRoute.startTangent
					leftp.z = leftp.z - params.minZoffset
						
						
					local rightp = util.nodePos(reRoute.endNode )+reRoute.startTangent
					rightp.z = leftp.z
					reRoute.endTangent = -1*reRoute.startTangent
					local diameter = util.distance(leftp, rightp)
					local circ = 0.5*diameter*(4 * (math.sqrt(2) - 1))*2
					reRoute.replacementPoints = {
						{
							p=leftp,
							t=reRoute.startTangent,
							t2=circ*vec3.normalize(reRoute.startTangent),
							tunnelCandidate = true
						}, 
						{
							p=rightp,
							t=circ*vec3.normalize(reRoute.endTangent),
							t2=reRoute.startTangent,
							tunnelCandidate = true
						}
					}
					if not collisionSegments then 
						collisionSegments = {}
					end
					table.insert(collisionSegments, {
						edge = edge,
						reRoute = reRoute
					})
					goto continue
				end
				
				if not solution.newEdgeSolution.solutionConverged or vec3.length(newPos.t1) ==0 or vec3.length(newPos.t2) ==0 then 
					trace("Warning! The new edge solution did not converge aborting")
					goto continue 
				end
				local crossingAngle = util.signedAngle(newPos.t1, theirPos.t1)
				if crossingAngle == 0 then
					trace("WARNING zero crossing angle detected, attempting to force correction") 
					newPos.t1 = util.rotateXY(newPos.t1, math.rad(10))
				end
				trace("The crossingAngle was ",math.deg(crossingAngle))
				if math.abs(crossingAngle) > math.rad(179) or math.abs(crossingAngle)<math.rad(1) then 
					trace("Shallow crossing angle detected, ignoring")
					goto continue
				end 
				local forceTunnelTheirs = false
				local hMax = context.maxHeights[nodeOrder]
				local hMin = context.minHeights[nodeOrder]
				local canGoAbove = collisionInfo.maxHeight+params.minZoffset <= hMax 
				local canGoUnder = collisionInfo.minHeight-params.minZoffset >= hMin  
				trace("inspecting cangoabove or under based on theights",maxHeight,minHeight,"zoffset=",minZoffset)
				if params.isHighway and nodeOrder > 2 and nodeOrder < numberOfNodes-1 and nodeOrder-context.lastJunctionIdx > 3 and nodeOrder - context.lastCrossingJunctionIdx  > 6 and not edge.track and not isProblematicEdge(edge) and context.terrainHeights[nodeOrder]>0 and math.abs(crossingAngle) > math.rad(45) then 
					
					local edgeWidth = util.getStreetWidth(params.preferredHighwayRoadType)
					local rightHandPoint = util.nodePointPerpendicularOffset(newPos.p1, newPos.t1, -edgeWidth)
					local rightHandNode = util.distance(rightHandPoint, node0Pos) < util.distance(rightHandPoint, node1Pos) and edge.node0 or edge.node1 
					local leftHandNode = rightHandNode == edge.node0 and edge.node1 or edge.node0
					local naturalTangent = util.nodePos(leftHandNode)-util.nodePos(rightHandNode) 
					local perpAngle = util.signedAngle(naturalTangent, util.rotateXY(newPos.t1, math.rad(90)))
					trace("The perpAngle was ",math.deg(perpAngle))
					if math.abs(perpAngle) > math.rad(90) then 
						trace("Swapping left and right")
						local temp = rightHandNode
						rightHandNode = leftHandNode
						leftHandNode = temp 
					end
					
					
					local sinf = math.sin(math.abs(crossingAngle))
					local minimumRightOffset = 2*edgeWidth /sinf  
					local minimumLeftOffset = (3*edgeWidth+params.highwayMedianSize) /sinf
					local rightHandOffset = util.distance(util.nodePos(rightHandNode), newPos.p1)
					local leftHandOffset = util.distance(util.nodePos(leftHandNode), newPos.p1)
					trace("Inspecting edge",edge.id," for junction, minimumRightOffset=",minimumRightOffset," minimumLeftOffset=",minimumLeftOffset, "rightHandOffset =",rightHandOffset," for node",rightHandNode," leftHandOffset=",leftHandOffset,"for node",leftHandNode)
					local originalRightHandNode = rightHandNode 
					local originalLeftHandNode = leftHandNode
					if  rightHandOffset < minimumRightOffset then 
						local nextSegs = util.getStreetSegmentsForNode(rightHandNode)
						local nextEdgeId = edge.id == nextSegs[1] and nextSegs[2] or nextSegs[1]
						local nextEdge = util.getEdge(nextEdgeId)
						rightHandNode = rightHandNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
						if #util.getSegmentsForNode(rightHandNode) > 2 then 
							trace("Rolling back change to rightHandNode due to too many segments at",rightHandNode)
							rightHandNode = originalRightHandNode
						else
							trace("Replaced rigthHandNode with ",rightHandNode)
						end
					end
					if leftHandOffset < minimumLeftOffset then 
						local nextSegs = util.getStreetSegmentsForNode(leftHandNode)
						local nextEdgeId = edge.id == nextSegs[1] and nextSegs[2] or nextSegs[1]
						local nextEdge = util.getEdge(nextEdgeId)
						leftHandNode = leftHandNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
						if #util.getSegmentsForNode(leftHandNode) > 2 then 
							trace("Rolling back change to leftHandNode due to too many segments at",leftHandNode)
							leftHandNode = originalLeftHandNode
						else 
							trace("Replaced leftHandNode with ",leftHandNode)
						end 
					end
					if leftHandNode == rightHandNode then 
						trace("WARNING! Left hand and right hand node were the same, reverting")
						leftHandNode = originalLeftHandNode
						rightHandNode = originalRightHandNode
					end 
					assert(rightHandNode~=leftHandNode)
					local rightHandOffset = util.distance(util.nodePos(rightHandNode), newPos.p1)
					local leftHandOffset = util.distance(util.nodePos(leftHandNode), newPos.p1)
					trace("After replacemernts edge",edge.id," for junction, minimumRightOffset=",minimumRightOffset," minimumLeftOffset=",minimumLeftOffset, "rightHandOffset =",rightHandOffset," for node",rightHandNode," leftHandOffset=",leftHandOffset,"for node",leftHandNode)
					if rightHandOffset >= minimumRightOffset and leftHandOffset>= minimumLeftOffset then 
						local maxSlope = maxBuildSlope(params)
						local minDist = math.max(120, math.abs(deltaz)/maxSlope) 
						junction = {}
						junction.leftEntryNodeNextSplit = leftHandNode
						junction.rightEntryNodeNextSplit = rightHandNode
						junction.minDist = minDist
						junction.p = newPos.p1
						junction.tangent = vec3.normalize(newPos.t1)
						junction.tangent.z = 0
						junction.tangent = vec3.normalize(junction.tangent)
						 
						local lastSplitForLeft = lastSplit
						while  lastSplitForLeft.lastSplit and (util.distance(util.nodePos(leftHandNode), lastSplitForLeft.pPos.p) < minDist
							or	 math.abs(util.signedAngle(lastSplitForLeft.pPos.t,util.nodePos(leftHandNode)-lastSplitForLeft.pPos.p))>math.rad(60)) do 
							trace("Deffering left hand exit to priorSplit")
							lastSplitForLeft = lastSplitForLeft.lastSplit
						end 
						if not lastSplitForLeft.junction then  
							lastSplitForLeft.junction = {}
							lastSplitForLeft.junction.tangent = junction.tangent 
						end 
						lastSplitForLeft.junction.leftHandExitNode = leftHandNode 
						lastSplitForLeft.junction.tangent = junction.tangent 
						trace("Set lastSplitForLeft at ",lastSplitForLeft.nodeOrder," leftHandExitNode=",lastSplitForLeft.junction.leftHandExitNode)
						
						local lastSplitForRight = lastSplit
						while lastSplitForRight.lastSplit and (util.distance(util.nodePos(rightHandNode), lastSplitForRight.pPos.p) <minDist
							or math.abs(util.signedAngle(lastSplitForRight.pPos.t,util.nodePos(rightHandNode) -lastSplitForRight.pPos.p))>math.rad(60))  do 
							trace("Deffering right hand exit to priorSplit")
							lastSplitForRight = lastSplitForRight.lastSplit
						end 
						if not lastSplitForRight.junction then  
							lastSplitForRight.junction = {}
							lastSplitForRight.junction.tangent = junction.tangent 
						end 
						lastSplitForRight.junction.rightHandExitNode = rightHandNode 
						trace("Set lastSplitForRight at ",lastSplitForRight.nodeOrder," rightHandExitNode=",lastSplitForRight.junction.rightHandExitNode)
						context.lastJunctionIdx = nodeOrder
						trace("Setting up junction at nodeOrder,",nodeOrder)
					else 
						trace("Unable to create junction as the minimum offset required is not met")
					end
				end
				
				if not params.isTrack and nodeOrder > 2 and nodeOrder < numberOfNodes-1 and theyAreHighway and nodeOrder-context.lastCrossingJunctionIdx > 3 then 
					trace("Discoved another highway crossing")
					if context.lastJunctionIdx < nodeOrder-5 then 
						local foundLeft = false 
						local foundRight = false
						local nextSplit = lastSplit 
						trace("Removing prior junction in favour of crossing")
						while (not foundLeft or not foundRight) and nextSplit do 
							trace("Looking for junction on ",nextSplit.nodeOrder, " had junction? ",nextSplit.junction)
							if nextSplit.junction and nextSplit.junction.rightHandExitNode and not foundRight  then 
								foundRight = true 
								nextSplit.junction.rightHandExitNode = nil 
								trace("removed rightHandExitNode")
							end 
							if nextSplit.junction and nextSplit.junction.leftHandExitNode and not foundLeft  then 
								foundLeft = true 
								nextSplit.junction.leftHandExitNode = nil 
								trace("removed leftHandExitNode")
							end 
							nextSplit = nextSplit.lastSplit
						end 
					end
					junction = {} 
					local startNodePos = vec2.distance(newPos.p1, node0Pos) < vec2.distance(newPos.p1, node1Pos) and node0Pos or node1Pos
					junction.highwayCrossing = startNodePos
				
					local shouldGoAbove = deltaz >= 0
					if params.isElevated and not shouldGoAbove and deltaz > -15 then 
						trace("Overriding initial assesment of should go above to true")
						shouldGoAbove = true 
					end 
					if params.isUnderground and shouldGoAbove and deltaz < 15 and not util.isUnderwater(startNodePos) then 
						trace("Overriding initial assesment of should go above to false")
						shouldGoAbove = false 
					end 
					
					if shouldGoAbove then 
						context.actualHeights[nodeOrder]=math.max(context.actualHeights[nodeOrder], startNodePos.z+params.minZoffset)
						context.minHeights[nodeOrder-1]=math.max(context.minHeights[nodeOrder-1], startNodePos.z+params.minZoffset)
						context.minHeights[nodeOrder]=math.max(context.minHeights[nodeOrder], startNodePos.z+params.minZoffset)
						trace("Set minheights to ",context.minHeights[nodeOrder], " at ",nodeOrder)
						context.minHeights[nodeOrder+1]=math.max(context.minHeights[nodeOrder+1], startNodePos.z+params.minZoffset)
					else 
						context.maxHeights[nodeOrder-1]=math.min(context.maxHeights[nodeOrder-1], startNodePos.z-params.minZoffset)
						context.maxHeights[nodeOrder]=math.min(context.maxHeights[nodeOrder], startNodePos.z-params.minZoffset)
						context.maxHeights[nodeOrder+1]=math.min(context.maxHeights[nodeOrder+1], startNodePos.z-params.minZoffset)
						trace("Set maxHeights to ",context.maxHeights[nodeOrder], " at ",nodeOrder)
						context.actualHeights[nodeOrder]=math.min(context.actualHeights[nodeOrder], startNodePos.z-params.minZoffset)
					
					end
					junction.crossingPoint = newPos.p1
					junction.crossingAngle = math.abs(util.signedAngle(newPos.t1, theirPos.t1))
					if junction.crossingAngle == 0 then 
						trace("Warning! initial calculation of crossing angle was zero attempting to correct") 
						junction.crossingAngle = math.abs(util.signedAngle(pPos.t, util.v3fromArr(edge.node0tangent)))
					end
					context.lastJunctionIdx = nodeOrder
					context.lastCrossingJunctionIdx = nodeOrder 
				end 
				
				
				if params.isDoubleTrack then 
					--newPos.p1 = util.nodePointPerpendicularOffset(newPos.p1, newPos.t1, -0.5*params.trackWidth)
				end
				if not newPos.solutionConverged then 
					trace("WARNING! Solution not fully converged for our position")
				end 
				if not theirPos.solutionConverged then 
					trace("WARNING! Solution not fully converged for our position")
				end
				local deltaz = newPos.p1.z - theirPos.p1.z
				
				trace("The deltaz for edge",edge.id, " was ",deltaz, " minimumClearanceRequired was ", minimumClearanceRequired)
				local ourMaxTerrainOffset = math.max(pPos.p.z - util.th(pPos.p), math.max(lpos.p.z-util.th(lpos.p), rpos.p.z-util.th(rpos.p))) 
				local ourMinTerrainOffset = math.min(pPos.p.z - util.th(pPos.p), math.min(lpos.p.z-util.th(lpos.p), rpos.p.z-util.th(rpos.p)))
				if  deltaz  > minimumClearanceRequired   -- we are higher with enough offset to pass without further action
					and (theirsIsTunnel or ourMinTerrainOffset >= minBridgeHeight)
					then
					if not theirsIsTunnel or townBuildingCount>0 then 
						needsBridge = true 
						if getActualLastSplit() then 
							getActualLastSplit().needsBridge = true
						end 
						needsBridgeNextSplit = true 
						edgeTypeRequiredForDeconfliction = true
						local minHeight = theirPos.p1.z+minimumClearanceRequired
						trace("Setting min height to ",minHeight)
						context.minHeights[nodeOrder-1]=math.max(context.minHeights[nodeOrder-1], minHeight)
						context.minHeights[nodeOrder]=math.max(context.minHeights[nodeOrder], minHeight)
						context.minHeights[nodeOrder+1]=math.max(context.minHeights[nodeOrder+1], minHeight)
					end
					trace("potential collision found but we are higher at nodeOrder=",nodeOrder)
				elseif deltaz < -minimumClearanceRequired -- they are higher 
					and theirsIsBridge then
					local maxHeight = theirPos.p1.z-minimumClearanceRequired
					context.maxHeights[nodeOrder]=math.min(context.maxHeights[nodeOrder], maxHeight)
					 -- requires rebuilding theirs to adjust pillars
					if not collisionSegments then 
						collisionSegments = {}
					end
					table.insert(collisionSegments, {
						edge = edge,
						rebuildOnly = true
					}) 
					context.allCollisionEdges[edge.id]=true 
					if edge.track then 
						local doubleTrackEdge = util.findDoubleTrackEdgeExpanded(edge.id, context.allCollisionEdges)
						if doubleTrackEdge and not context.allCollisionEdges[doubleTrackEdge] then 
							trace("Setting doubleTrackEdge to rebuild only",doubleTrackEdge) 
							context.allCollisionEdges[doubleTrackEdge] = true 
							table.insert(collisionSegments, {
							edge = util.getEntity(doubleTrackEdge),
							rebuildOnly = true
							}) 
						end 
					elseif theyAreHighway then 
						local highwayEdge = util.findParallelHighwayEdge(edge.id, 25)
						if highwayEdge and not context.allCollisionEdges[highwayEdge] then 
							trace("Setting highwayEdge to rebuild only",highwayEdge) 
							context.allCollisionEdges[highwayEdge] = true 
							table.insert(collisionSegments, {
							edge = util.getEntity(highwayEdge),
							rebuildOnly = true
						}) 
						end 
					end 
					
					segmentsPassingAbove = true
					trace("potential collision found but we are lower at nodeOrder=",nodeOrder)
				else 
					context.allCollisionEdges[edge.id]=true
					local otherNode0 = util.findDoubleTrackNode(edge.node0)
					local otherNode1 = util.findDoubleTrackNode(edge.node1)
					local doubleTrackEdge = util.findDoubleTrackEdgeExpanded(edge.id, context.allCollisionEdges)
					if doubleTrackEdge then 
						context.allCollisionEdges[doubleTrackEdge]=true 
					end
					--[[if otherNode0 and otherNode1 then 
						doubleTrackEdge = util.findEdgeConnectingNodes(otherNode0, otherNode1)
						trace("Found doubletrackdge ",doubleTrackEdge)
						if doubleTrackEdge then 
							context.allCollisionEdges[doubleTrackEdge]=true
						end
					else 
						trace("Did NOT find a double track edge")
					end]]--
					
					local theirTangent = vec3.length(theirPos.t1) > 0 and theirPos.t1 or theirPos.t2
					local ourTangent = vec3.length(newPos.t1) > 0 and newPos.t1 or newPos.t2
					local crossingAngle = util.signedAngle(theirTangent, ourTangent)
					local crossingAngleNegative = crossingAngle < 0
					crossingAngle = math.abs(crossingAngle) 
					if crossingAngle > math.rad(90) then 
						crossingAngle = math.rad(180) - crossingAngle
					end 
					if math.abs(crossingAngle) < math.rad(params.minimumCrossingAngle) and vec3.length(theirTangent)>0 then
						trace("detected shallow angle, attempting to correct", math.deg(crossingAngle))
						local correction = math.rad(params.minimumCrossingAngle) - math.abs(crossingAngle)
						if crossingAngleNegative then correction = -correction end
						newPos.t1= util.rotateXY(newPos.t1, correction)
						newPos.t2 =util.rotateXY(newPos.t2, correction)
						pPos.t = util.rotateXY(pPos.t, correction)
						pPos.t2 = util.rotateXY(pPos.t2, correction)
						trace("Corrected angle, attempting to correct", math.deg(util.signedAngle(theirTangent, ourTangent)))
					end
					
					if otherNode0 or otherNode1 then 
						canCrossAtGrade = false 
					end
					if crossingAngle < math.rad(20) then 
						canCrossAtGrade = false
					end 
					

					-- if it would take more height adjustment to meet the grade than by passing over, do not try to cross at grade
					if math.abs( deltaz) > 0.5*params.minZoffset then -- half the minimum height clearance
						canCrossAtGrade = false 
					end
					if #util.getEdge(edge.id).objects > 0 then 
						canCrossAtGrade = false 
					end
					if canCrossAtGrade then 
						local p = newPos.p1 
						local theirEdgeWidth = util.getEdgeWidth(edge.id)
						local ourWidth = params.edgeWidth
						local clearanceNeeded = 5* (theirEdgeWidth+ourWidth)/2
						if #util.getSegmentsForNode(edge.node0) > 2 then 
							local distToNode = util.distance(p, util.nodePos(edge.node0))
							if distToNode < clearanceNeeded then 
								trace("Overriding canCrossAtGrade to false for",edge.id,"due to",edge.node0,"being at a short ditance",distToNode,"on a junctionNode")
								canCrossAtGrade = false
							end 
						end 
						if #util.getSegmentsForNode(edge.node1) > 2 then 
							local distToNode = util.distance(p, util.nodePos(edge.node1))
							if distToNode < clearanceNeeded then 
								trace("Overriding canCrossAtGrade to false for",edge.id,"due to",edge.node1,"being at a short ditance",distToNode,"on a junctionNode")
								canCrossAtGrade = false
							end 
						end 
						
					end 
				
				--if not edge.isTrack then
					local posUsingBezier = { p = newPos.p1, t = ourTangent, t2=newPos.t2}
					--local newPos = solveForPositionHermite(t, ourEdge, vec2.distance)--hermite(approxfrac, pDown.p, pDown.t, pUp.p, pUp.t)
					trace("collision requires rerouting  changing position ", pPos.p.x,",",pPos.p.y," to ",newPos.p1.x,",",newPos.p1.y, "at nodeOrder=",nodeOrder, " theirPos=",theirPos.p1.x,theirPos.p1.y,"canCrossAtGrade?",canCrossAtGrade)
					local theirRequiredSpan
					if canCrossAtGrade then
						local doubleTrackSolution
						if params.isDoubleTrack and false then -- disabled after shift in mainline later
							local lpos2 = { p=util.doubleTrackNodePoint(lpos.p, lpos.t), t=lpos.t, t2=lpos.t2 } 
							local pPos2 = { p=util.doubleTrackNodePoint(pPos.p, pPos.t), t=pPos.t, t2=pPos.t2 } 
							local rpos2 = { p=util.doubleTrackNodePoint(rpos.p, rpos.t), t=rpos.t, t2=rpos.t2 }  
							if vec2.distance(pPos2.p, node1Pos) < 10 or vec2.distance(pPos2.p, node0Pos) < 10 then 
								trace("detected close node to double track node, shifting at ",nodeOrder)
								lpos2.p = lpos.p
								pPos2.p = pPos.p
								rpos2.p = rpos.p
								lpos.p = util.doubleTrackNodePoint(lpos2.p, -1*pPos.t)
								pPos.p  = util.doubleTrackNodePoint(pPos2.p, -1*pPos.t)
								rpos.p  = util.doubleTrackNodePoint(rpos2.p, -1*pPos.t)
								c.c = pPos.p
								ourEdge = util.createCombinedEdge(lpos, pPos, rpos)
								
								solution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c.c, edge.id, ourEdge)
								theirPos = solution.existingEdgeSolution
								newPos = solution.newEdgeSolution
							end
							
							local ourEdge2 = util.createCombinedEdge(lpos2, pPos2, rpos2)
							local c2 = util.doubleTrackNodePoint(util.v2ToV3(c.c),pPos.t)
							doubleTrackSolution = util.fullSolveForCollisionBetweenExistingAndProposedEdge(c2, edge.id, ourEdge2)
							local pUp2 = pPos2.p + 10*vec3.normalize(pPos2.t)
							local pDown2 = pPos2.p - 10*vec3.normalize(pPos2.t)
							local c3 = util.checkFor2dCollisionBetweenPoints(pUp2, pDown2, theirPos.p0, theirPos.p1)
							if c3 then -- need to keep the left -> right ordering consistent for the route builder
								trace("detected swap needed at nodeOrder ",nodeOrder," with collision points")
								local temp = doubleTrackSolution
								doubleTrackSolution = { existingEdgeSolution = theirPos, newEdgeSolution = doubleTrackSolution.newEdgeSolution }
								theirPos = temp.existingEdgeSolution 
								newPos = temp.newEdgeSolution								
							end
							
							
						end
						local theirEdge = { 
							p0 = node0Pos,
							p1 = node1Pos, 
							t0 = util.v3fromArr(edge.node0tangent),
							t1 = util.v3fromArr(edge.node1tangent)
						}
						
						local doNotCorrectOtherSeg = util.edgeHasTpLinks(edge.id) -- otherwise risk breaking a connection
						local replaceNodeOnly = false
						
						local correctionDistance = params.isTrack and 5 or 15
						local minDistance = params.isTrack and 2 or 5
						local crossingNode
						if edgeHasRoadRailCrossing(edge) and not params.isTrack and not edge.track then 
							doNotCorrectOtherSeg = true
							if #util.getTrackSegmentsForNode(edge.node0) > 0 then
								posUsingBezier.p = node1Pos
								oldNode = edge.node1 
								doNotCorrectOtherSeg = true
								crossingNode = edge.node1
							else 
								posUsingBezier.p = node0Pos
								oldNode = edge.node0
								doNotCorrectOtherSeg = true
								crossingNode = edge.node0
							end 
							
						elseif util.distance(newPos.p1, node1Pos) < minDistance and #util.getSegmentsForNode(edge.node1) <= 2 and not params.isDoubleTrack or rightConnectedSeg and util.isFrozenEdge(rightConnectedSeg) and not params.isDoubleTrack then 
							posUsingBezier.p = node1Pos
							oldNode = edge.node1 
							doNotCorrectOtherSeg = true
							crossingNode = edge.node1
							trace("Using oldNode ",oldNode," for the crossing")							
						elseif  util.distance(newPos.p1, node0Pos) < minDistance and #util.getSegmentsForNode(edge.node0) <= 2 and not params.isDoubleTrack or leftConnectedSeg and util.isFrozenEdge(leftConnectedSeg) and not params.isDoubleTrack  then 
							posUsingBezier.p = node0Pos
							oldNode = edge.node0
							doNotCorrectOtherSeg = true
							 crossingNode = edge.node0
							trace("Using oldNode ",oldNode," for the crossing")
						elseif util.distance(newPos.p1, node1Pos) < 10 and #util.getSegmentsForNode(edge.node1) <= 2 and util.getEdgeLength(edge.id) > 30 and not params.isDoubleTrack then 
						 
							replaceNodeOnly = edge.node1
							crossingNode = edge.node1
							trace("Replacing oldNode ",oldNode," for the crossing")							
						elseif  util.distance(newPos.p1, node0Pos) < 10 and #util.getSegmentsForNode(edge.node0) <= 2 and util.getEdgeLength(edge.id) > 30 and not params.isDoubleTrack then 
							 
							replaceNodeOnly = edge.node0
							 crossingNode = edge.node0
							trace("Replacing oldNode ",oldNode," for the crossing")
						elseif util.distance(newPos.p1, node1Pos) < correctionDistance then 
							trace("detected short distance from problematic node, attempting to correct") 
							local theirEdgeLength = util.calculateSegmentLengthFromNewEdge(theirEdge)
							newPos.p1 = util.solveForPositionHermiteLength(theirEdgeLength-correctionDistance, theirEdge).p
							posUsingBezier.p = newPos.p1
							crossingNode = edge.node1
						elseif util.distance(newPos.p1, node0Pos) < correctionDistance then
							trace("detected short distance from problematic node, attempting to correct")
							newPos.p1 = util.solveForPositionHermiteLength(correctionDistance, theirEdge).p
							posUsingBezier.p = newPos.p1
							crossingNode = edge.node0
						end 
						if crossingNode then 
							for i, seg in pairs(util.getSegmentsForNode(crossingNode)) do 
								context.edgesToIgnore[seg]=true -- TODO think using allCollisionEdges results in orphaned roads at crossings
							end
						end 
						--frozen = true
						noResolve = true
						routePoints[nodeOrder+1].t= newPos.t3
						local collisionSeg = {edge = edge, theirPos = theirPos , deltaz=deltaz, canCrossAtGrade=canCrossAtGrade, theirRequiredSpan = theirRequiredSpan, doubleTrackSolution=doubleTrackSolution, doNotCorrectOtherSeg = doNotCorrectOtherSeg, replaceNodeOnly=replaceNodeOnly}
						local countOfCollisionSegments = countNonRebuildOnlyCollisionSegs(collisionSegments)
						trace("Inspecting grade crossing at ",nodeOrder, " number of collisionSegments  so far?",countOfCollisionSegments) 
						if countOfCollisionSegments == 0 then
							
							if getActualLastSplit() then
								getActualLastSplit().pPos.t2 = newPos.t0
							else 
								routePoints[nodeOrder-1].t2= newPos.t0
							end 
							pPos = posUsingBezier
						
							routePoints[nodeOrder]=posUsingBezier
							collisionSegments={collisionSeg}	 
							rpos.t = newPos.t3
							trace("Grade crossing: moving this point at ",nodeOrder, " to pPos",pPos.p.x, pPos.p.y)
						else 
							trace("Inserting new split point for at grade  collision at ",nodeOrder)
							pPos.t2 = newPos.t0
							rpos.t = newPos.t3 
							local newSplitPoint = {
									pPos =posUsingBezier,
									tunnelCandidate = tunnelCandidate,
									needsBridge = needsBridge,
									terrainHeight = util.th(posUsingBezier.p),
									frozen = frozen,
									noResolve = noResolve,
									collisionSegments = {collisionSeg},
									nodeOrder = nodeOrder,
									oldNode = oldNode,
									spiralPoint = routePoints[nodeOrder].spiralPoint,
							}
							oldNode = nil
							table.insert(newSplitPoints, newSplitPoint)
						end
					
						
					else -- can not cross at grade
						local ourWidth = params.ourWidth
						newPos.t1.z = 0 
						newPos.t2.z = 0
						local tnormal = vec3.normalize(ourTangent)
						local minZoffset = params.minZoffset
						local collisionBox = util.calculateCollisionBoxSize(ourTangent, theirTangent, ourWidth, edge.id, minZoffset)
						local ourRequiredSpan = collisionBox.ourRequiredSpan
						local ourRequiredMinOffset = 0.5*ourRequiredSpan + params.minSeglength
						theirRequiredSpan = collisionBox.theirRequiredSpan
						if params.collisionEntities and params.collisionEntities[edge.id] then 
							trace("Increasing required spans for known collision entities")
							theirRequiredSpan = theirRequiredSpan + 10 
							ourRequiredSpan = ourRequiredSpan + 10
						end 
					
						
						
						
						-- if track crossing road then give the road the higher share
						local ourDeltzFractionStart = (params.isTrack and edge.track) and 4/8 or params.isTrack and 2/8 or 6/8 -- keeping everything in eigths for correction later
						local doNotCorrectOtherSeg = false
						local ourDeltzFraction
						if edgeHasBuildings(edge) and nodeOrder > 1 and nodeOrder < numberOfNodes-1 then 
							trace("Setting our initial deltaZ fraction to 1 to avoid town buildings at nodeOrder = ",nodeOrder)
							ourDeltzFraction = 1
							doNotCorrectOtherSeg = true
						end 
						
						if nodeOrder == 1 or nodeOrder == numberOfNodes then 
							ourDeltzFractionStart = 0
						elseif collisionInfo.collisionEdgeNearby then
							trace("Found collisionEdgeNearby at ",nodeOrder)
							doNotCorrectOtherSeg = true 
							ourDeltzFractionStart = 1
						end
						if params.isHighway and theyAreHighway then 
							doNotCorrectOtherSeg = true 
							ourDeltzFractionStart = 1
						end 
						local otherEdgeId 
						if collisionInfo.collisionEdges[i+1] and collisionInfo.collisionEdges[i+1].c and collisionInfo.collisionEdges[i+1].edge.id~=doubleTrackEdge then 
							local nextC = collisionInfo.collisionEdges[i+1].c.newEdgeSolution
							local nextCTheirs = collisionInfo.collisionEdges[i+1].c.existingEdgeSolution
							local nextEdge = collisionInfo.collisionEdges[i+1].edge
							local distToNextC = vec2.distance(newPos.p1, nextC.p1)
							if distToNextC == 0 then 
								trace("Detected 2nd collision result for ",nextEdge.id, " ignoring")
								context.edgesToIgnore[nextEdge.id]=true
							--elseif areEdgesConnected(edge, nextEdge) then 
								--trace("edges are connected, ignoring")
								--edgesToIgnore[nextEdge.id]=true
								otherEdgeId = nextEdge.id
							elseif distToNextC < ourRequiredMinOffset then 
								trace("Detected a collision point ahead", distToNextC , " attempting to span both  ourRequiredSpan=" ,ourRequiredSpan)
								local collisionBox2 = util.calculateCollisionBoxSize(nextC.t1, nextCTheirs.t1, ourWidth, nextEdge.id, minZoffset)
								local startPoint = newPos.p1 - 0.5*ourRequiredSpan*tnormal 
								local endPoint = nextC.p1 + 0.5*collisionBox2.ourRequiredSpan*vec3.normalize(nextC.t1)
								startPoint = util.solveForNearestHermitePosition(startPoint, ourActualEdge)
								endPoint = util.solveForNearestHermitePosition(endPoint, ourActualEdge)
								local midPoint = util.solveForNearestHermitePosition( 0.5*(startPoint+endPoint), ourActualEdge)
								local deltaz2 = nextC.p1.z - nextCTheirs.p1.z
								if deltaz>0 then -- not yet dealing with the case where one is higher and one is lower
									deltaz = math.max(deltaz, deltaz2)
								else 
									deltaz = math.min(deltaz, deltaz2)
								end 
								if isProblematicEdge(nextEdge) then 
									ourDeltzFractionStart = 1 -- do not attempt to correct theirs 
									doNotCorrectOtherSeg = true
								end
							
								--context.allCollisionEdges[nextEdge.id]=true -- so we don't reprocess
								context.edgesToIgnore[nextEdge.id]=true -- so we don't reprocess
								otherEdgeId = nextEdge.id
								ourRequiredSpan = 2*math.max(vec2.distance(midPoint, startPoint), vec2.distance(midPoint, endPoint))
							
								newPos = util.solveForPosition(midPoint, ourActualEdge)
								newPos.t1.z = 0 
								newPos.t2.z = 0
								tnormal = vec3.normalize(ourTangent)
								trace("Altered solution, attempting to span both  ourRequiredSpan=" ,ourRequiredSpan, " midpoint at ",newPos.p1.x,newPos.p1.y, " theirEdgeId = ",otherEdgeId)
							end
							
						end
						local parallelHighwayEdge
						if theyAreHighway and not otherEdgeId then 
							local test = util.findParallelHighwayEdge(edge.id, 25)
							if test and not context.edgesToIgnore[test] and not context.allCollisionEdges[test] then 
								context.allCollisionEdges[test]=true 
							parallelHighwayEdge = test
							trace("Setting up the otherEdgeId as the parallelHighwayEdge")
							end
						end
						
						local weAreHigher =  deltaz  >= 0
						
						
						
						if weAreHigher then 
							if  ourRequiredSpan > params.maxCrossingBridgeSpan and util.isSuspensionBridgeAvailable() and ourRequiredSpan<=			params.maxCrossingBridgeSpanSuspension and not util.isCableBridgeAvailable() and nodeOrder < numberOfNodes and i > nodeOrder and not theyAreHighway and not params.isHighway then
								minZoffset = params.minZoffsetSuspension
							elseif not edge.track and not params.isTrack then  
								minZoffset = params.minZoffsetRoad
							end 
						else
							if theirRequiredSpan > params.maxCrossingBridgeSpan and util.isSuspensionBridgeAvailable() and theirRequiredSpan<=params.maxCrossingBridgeSpanSuspension and not util.isCableBridgeAvailable() and nodeOrder < numberOfNodes and i > nodeOrder and not theyAreHighway and not params.isHighway then
								minZoffset = params.minZoffsetSuspension
							elseif not params.isTrack and not edge.track then  
								minZoffset = params.minZoffsetRoad
							end
						end
						if params.isHighway or not edge.track and util.getStreetTypeCategory(edge.id) == "highway" then 
							minZoffset = math.max(minZoffset, 15)
						end
						if (edge.track or params.isTrack) and util.th(newPos.p1) < -10 then 
							minZoffset = params.minZoffsetSuspension
						end 
						
					
						 
						
						local theirGradientLimit = util.maxBuildSlopeEdge(edge.id) 
						 
						local leftSegs = util.getSegmentsForNode(edge.node0)
						local rightSegs = util.getSegmentsForNode(edge.node1)
						local leftConnectedSeg = leftSegs[1] == edge.id and leftSegs[2] or leftSegs[1]
						local rightConnectedSeg = rightSegs[1] == edge.id and rightSegs[2] or rightSegs[1]
						local theirLeftSeg = util.getEdge(leftConnectedSeg)
						
						local leftOuterNode = theirLeftSeg.node == edge.node0 and theirLeftSeg.node1 or theirLeftSeg.node0
						local leftOuterNodePos = util.nodePos(leftOuterNode)
						local theirLeftDistance = vec2.distance(leftOuterNodePos, theirPos.p1)-0.5*theirRequiredSpan
						if #util.getSegmentsForNode(leftOuterNode) == 2 then 
							local segs = util.getSegmentsForNode(leftOuterNode)
							local outerOuterLeftEdge = leftConnectedSeg == segs[1] and segs[2] or segs[1] 
							local isProblematic = isProblematicEdge(outerOuterLeftEdge)
							trace("Inspecting the outerOuterLeftEdge",outerOuterLeftEdge, "isProblematic?",isProblematic)
							if not isProblematic  then
								local edge = util.getEdge(outerOuterLeftEdge)
								local otherNode = leftOuterNode == edge.node0 and edge.node1 or edge.node0 
								local otherNodePos = util.nodePos(otherNode)
								local dist = vec2.distance(leftOuterNodePos, otherNodePos)
								trace("Increasing their effective dist by", dist)
								theirLeftDistance = theirLeftDistance + dist 
								leftOuterNodePos = otherNodePos
							end 
						end 
						local theirRightSeg = util.getEdge(rightConnectedSeg)
						local rightOuterNode = theirRightSeg.node == edge.node1 and theirRightSeg.node0 or theirRightSeg.node1
						local rightOuterNodePos = util.nodePos(rightOuterNode)
						local theirRightDistance = vec2.distance(rightOuterNodePos, theirPos.p1)-0.5*theirRequiredSpan
						if #util.getSegmentsForNode(rightOuterNode) == 2 then 
							local segs = util.getSegmentsForNode(rightOuterNode)
							local outerOuterRightEdge = rightConnectedSeg == segs[1] and segs[2] or segs[1] 
							local isProblematic = isProblematicEdge(outerOuterRightEdge)
							trace("Inspecting the outerOuterRightEdge",outerOuterRightEdge, "isProblematic?",isProblematic)
							if not isProblematic  then
								local edge = util.getEdge(outerOuterRightEdge)
								local otherNode = rightOuterNode == edge.node0 and edge.node1 or edge.node0 
								local otherNodePos = util.nodePos(otherNode)
								local dist = vec2.distance(rightOuterNodePos, otherNodePos)
								trace("Increasing their effective dist by", dist)
								theirRightDistance = theirRightDistance + dist 
								rightOuterNodePos = otherNodePos
							end 
						end 
						local applyNodeOffsetsOnly = false
						if isProblematicEdge(edge) or params.isHighway or doubleTrackEdge and isProblematicEdge(util.getEntity(doubleTrackEdge)) then 
							local problematicAllowingJunctions = isProblematicEdge(edge, true)
							trace("Detected possible problematic edge ",edge.id,"  problematicAllowingJunctions=",problematicAllowingJunctions)
							--if doubleTrackEdge then 
							--	trace("is doubletrackdge problematic?",isProblematicEdge(doubleTrackEdge))
							--end 
						
							if isHardProblematicEdge(edge) or edgeHasBuildings(edge) then 
								ourDeltzFractionStart = 1
								doNotCorrectOtherSeg = true
								trace("avoiding z corrections to their edge")
							else 
						 
								trace("Setting applyNodeOffsetsOnly")
								applyNodeOffsetsOnly = true 
							end 
						end
						
						local zcorrection = 0
						local maxHeight = collisionInfo.maxHeight
						local minHeight = collisionInfo.minHeight
						if collisionInfo.collisionHeightGapIdx then 
							trace("Found collision heightGap at ",collisionInfo.collisionHeights[collisionInfo.collisionHeightGapIdx])
							if newPos.p1.z < collisionInfo.collisionHeights[collisionInfo.collisionHeightGapIdx] then 
								maxHeight = collisionInfo.collisionHeights[collisionInfo.collisionHeightGapIdx-1]
							else 
								minHeight = collisionInfo.collisionHeights[collisionInfo.collisionHeightGapIdx]
							end 
							
						end 
						local minz 
						local maxz
						if weAreHigher  then -- we are higher  
							--zcorrection = math.max(minZoffset-deltaz, 0)
							zcorrection = math.max(maxHeight+minZoffset-newPos.p1.z,0)
						else  -- they are higher 
							--zcorrection = math.min(-minZoffset-deltaz,0)
							 zcorrection = math.min((minHeight-minZoffset)-newPos.p1.z,0)
						end
					--	if math.abs(deltaz) >= minZoffset then 
						--	zcorrection = 0
					--	end
						local minHeightOverWater = util.getWaterLevel() + 15
						trace("Initial zcorrection calculated as ",zcorrection, " minHeight=",minHeight," maxHeight=",maxHeight, " current z =",newPos.p1.z)
						if util.th(newPos.p1)<= util.getWaterLevel() or waterMeshUtil.isPointOnWaterMeshTile(newPos.p1)  then 
							
							
							trace("Collision above water detected, rechecking heights, minHeightOverWater=",minHeightOverWater,"weAreHigher?",weAreHigher)
							if weAreHigher and theirPos.p1.z - zcorrection < minHeightOverWater then
								trace("Would make them too low") 
								weAreHigher = false 
								zcorrection = -params.minZoffset-deltaz 
								ourDeltzFractionStart = 0
							elseif not weAreHigher and newPos.p1.z+zcorrection < minHeightOverWater then 
								trace("Would make us too low") 
								weAreHigher = true 
								zcorrection = params.minZoffset + deltaz
								ourDeltzFractionStart = 0
							end 
						end 
						
						
					
						
						
						local ourMaxDeltaZFraction = 1
						
						local isAirport = string.find(edge.streetType,"airport")
					
						if isAirport then 
							trace("Overriding canGoAbove to false and canGoUnder to true for airport segment near",newPos.p1.x,newPos.p1.y,"from", canGoAbove,canGoUnder)
							canGoAbove = false 
							canGoUnder = true
						end 
						local isOverWater = util.isUnderwater(newPos.p1)
						trace("Inspecting options, canGoAbove=",canGoAbove," canGoUnder=",canGoUnder," at ",nodeOrder, "deltaz+minZoffset=",deltaz+minZoffset," hMax=",hMax,"deltaz-minZoffset=",deltaz-minZoffset, " hMin=",hMin, " maxHeight+minZoffset=",maxHeight+minZoffset, " minHeight-minZoffset=", minHeight-minZoffset, " isOverWater=",isOverWater)
						local problematicHeights = false
						
						if not canGoAbove and not canGoUnder then 
							trace("WARNING! cannot go under or above, attempting to correct") 
							minZoffset = math.min(minZoffset, params.minZoffset)
							problematicHeights = true
							
							for i = 1, minZoffset do
								local reducedOffset = minZoffset - i
								--canGoAbove = newPos.p1.z+reducedOffset-deltaz <= hMax 
								--canGoUnder = newPos.p1.z-reducedOffset-deltaz >= hMin 
								canGoAbove = collisionInfo.maxHeight+reducedOffset <= hMax 
								canGoUnder = collisionInfo.minHeight-reducedOffset >= hMin  
								if canGoAbove and isOverWater then 
									local theirZ = theirPos.p1.z -(deltaz-reducedOffset)
									if theirZ < 5 then 
										canGoAbove = false
									end 
									trace("Checking their solution, theirZ was",theirZ," theirOiginalz=",theirPos.p1.z, " rechecked canGoAbove=",canGoAbove)
								end 
								ourMaxDeltaZFraction = reducedOffset/minZoffset
								ourDeltzFractionStart = math.min(ourDeltzFractionStart, ourMaxDeltaZFraction)
								if canGoAbove or canGoUnder then  
									trace("Found a solution at reduced offset ",reducedOffset, " ourMaxDeltaZFraction=",ourMaxDeltaZFraction, "canGoAbove=",canGoAbove,"canGoUnder=",canGoUnder, " test height can go above",(newPos.p1.z+reducedOffset-deltaz), " test height can go under",(newPos.p1.z-reducedOffset-deltaz))
									break 
								end 
								 
							end
							
							if weAreHigher  then 
								zcorrection = math.max(maxHeight+minZoffset-newPos.p1.z,0)
							else  -- they are higher 
								zcorrection = math.min((minHeight-minZoffset)-newPos.p1.z,0)
							end
							trace("Recalculated zcorrection as ",zcorrection)
							if  isProblematicEdge(edge) and not isProblematicEdge(edge, true) then 
								applyNodeOffsetsOnly = true 
							end 
						end 
						if weAreHigher and not canGoAbove and canGoUnder then 
							
							weAreHigher = false
							--zcorrection = newPos.p1.z-(minHeight-minZoffset)
							zcorrection = (minHeight-minZoffset)-newPos.p1.z
							trace("Swapping weAreHigher as we can go under instead, zcorrection=",zcorrection)
						elseif not weAreHigher and not canGoUnder and canGoAbove then
							
							weAreHigher = true 
							zcorrection = maxHeight+minZoffset-newPos.p1.z
							
							trace("Swapping weAreHigher as we can go above instead, zcorrection=",zcorrection)
						end 
						
						if weAreHigher and townBuildingCount>0 and canGoUnder and deltaz < 0.5*minZoffset and not params.isHighway then 
							-- try to bury under a town
							
--							zcorrection = newPos.p1.z-(minHeight-minZoffset)
							zcorrection = math.min((minHeight-minZoffset)-newPos.p1.z,0)
							trace("Detected town buildings, attempting to reduce height, zcorrection=",zcorrection)
							if not problematicHeights then 
								--ourDeltzFractionStart = 1
							end
							weAreHigher = false 
						elseif not weAreHigher and (nodeOrder == 1 or nodeOrder == numberOfNodes) and params.isTrack and not edge.track and math.abs(deltaz) < 0.5*minZoffset and canGoAbove
							and newPos.p1.z -(params.minZoffset+deltaz) <= leftOuterNodePos.z - theirGradientLimit*theirLeftDistance 
							and newPos.p1.z -(params.minZoffset+deltaz) <= rightOuterNodePos.z - theirGradientLimit*theirRightDistance
							and	util.th(leftOuterNodePos) > 0 
							and util.th(rightOuterNodePos) > 0
							then 
							
							zcorrection = minZoffset+deltaz 
							trace("adjusting their position down, zcorrection=",zcorrection) 
							ourDeltzFractionStart = 0
							weAreHigher = true 
							forceTunnelTheirs = true
						end
						
						if params.isElevated and canGoAbove and not weAreHigher  then 
							weAreHigher = true 
							zcorrection = minZoffset+ (deltaz > 0 and -deltaz or deltaz)
							trace("Elevated and can go higher, so setting zcorrection positive",zcorrection)
						end 
						if params.isUnderground and canGoBelow and weAreHigher  then 
							weAreHigher = false 
							zcorrection = -minZoffset- (deltaz > 0 and -deltaz or deltaz)
							trace("Underground and can go lower, so setting zcorrection negative",zcorrection)
						end 
						if not ourDeltzFraction then 
							ourDeltzFraction = ourDeltzFractionStart
						end
						--[[for i = nodeOrder, 1  , -1 do 
							local distanceToLast  = util.distance(newPos.p1, routePoints[i].p)-0.5*ourRequiredSpan
							local maxDeltaz = maxGradient * distanceToLast
							local height = context.actualHeights[i]
							hMin = math.max(context.minHeights[i]-maxDeltaz, hMin)
							if context.lockedHeights[i] then 			
								hMax = math.min(hMax, maxDeltaz + height)
								break
							end 
						end
						local maxCorrection = zcorrection + newPos.p1.z
						if maxCorrection > hMax then 
							local testZcorrection =  newPos.p1.z-(minZoffset + deltaz)
							if weAreHigher and testZcorrection > hMin then 
								zcorrection = -(minZoffset + deltaz)
								if newPos.p1.z > hMax and ourDeltzFraction < 1 then 
									ourDeltzFraction = (hMax-newPos.p1.z)/zcorrection
									assert(ourDeltzFraction>0)
									if ourDeltzFraction > 1 then 
										ourDeltzFraction = 1
										trace("A very large difference was detected, changin underlying z from ",newPos.p1.z)
										--newPos.p1.z = hMax+zcorrection
										newPos.p1.z = newPos.p1.z + zcorrection
										trace("to ",newPos.p1.z)
									end
								end
								trace("detected large correction from locked height attempting to correct by reducing height zcorrection=", zcorrection, " ourDeltzFraction=",ourDeltzFraction, " current z = ",newPos.p1.z)
								weAreHigher = false
							end
						elseif maxCorrection < hMin and townBuildingCount == 0 then
							if not weAreHigher then
								local testZcorrection =  minZoffset + math.abs(deltaz)
								if testZcorrection + newPos.p1.z < hMax then
									zcorrection = testZcorrection
									if newPos.p1.z < hMin and ourDeltzFraction < 1 then 
										ourDeltzFraction = (hMin-newPos.p1.z)/zcorrection
										assert(ourDeltzFraction>0)
										if ourDeltzFraction > 1 then 
											ourDeltzFraction = 1
											trace("A very large difference was detected, changin underlying z from ",newPos.p1.z)
											--newPos.p1.z = hMax+zcorrection
											newPos.p1.z = newPos.p1.z + zcorrection
											trace("to ",newPos.p1.z)
										end
									end
									trace("detected large correction from min height attempting to correct by increasing height zcorrection=",zcorrection, " maxCorrection=",maxCorrection, "hMin=",hMin) 
									weAreHigher = true
								end
							end
						end]]--
						
						
						local remainingDeltaz = (ourDeltzFraction-1)*zcorrection
						local function calculateTheirMaxGradient(ourDeltzFraction)
							remainingDeltaz = (ourDeltzFraction-1)*zcorrection
							
							
							local theirCorrectedZ = theirPos.p1.z +remainingDeltaz
							trace("Their original pos=",theirPos.p1.z," their remainingDeltaz=",remainingDeltaz," theirCorrectedZ=",theirCorrectedZ)
							if isOverWater and theirCorrectedZ < 5 and zcorrection > 0 then 
								return math.huge 
							end
							local theirLeftDeltaz= math.abs(theirCorrectedZ-leftOuterNodePos.z)
							local theirLeftGradient =theirLeftDeltaz/theirLeftDistance
							
							local theirRightDeltaz = math.abs(theirCorrectedZ-rightOuterNodePos.z)
							local theirRightGradient =theirRightDeltaz/theirRightDistance
							local theirMaxGradient = math.max(theirRightGradient, theirLeftGradient)
							trace("theirMaxGradient=",theirMaxGradient, " ourDeltzFraction=",ourDeltzFraction, " theirLeftDeltaz=",theirLeftDeltaz," theirLeftDistance=",theirLeftDistance," theirRightDeltaz=",theirRightDeltaz,"theirRightDistance=",theirRightDistance)
							return theirMaxGradient
						end
						
						
						if math.abs(zcorrection) > 0 then
							while ourDeltzFraction <= ourMaxDeltaZFraction and calculateTheirMaxGradient(ourDeltzFraction) > theirGradientLimit do 
								trace("Large potential gradient detected in the other segment at ",nodeOrder, " attempting to adjust")
								ourDeltzFraction = ourDeltzFraction + (1/16) -- powers of 2 fractions are used as these add exactly in binary
								if ourDeltzFraction > ourMaxDeltaZFraction then 
									ourDeltzFraction = ourMaxDeltaZFraction 
									break 
								end
							end
						end
						
						
						local ourZCorrection = zcorrection*ourDeltzFraction
						local ourZ = ourZCorrection + newPos.p1.z
						if ourZ < context.minHeights[nodeOrder] and util.th(newPos.p1)<util.getWaterLevel() then 
							trace("detected z below min heights, attempting to correct") -- avoid going below water line as this can create problems if we need to cross water expanses
							zcorrection = minZoffset-deltaz
							ourDeltzFraction = ourDeltzFractionStart
							while ourDeltzFraction < 1 and calculateTheirMaxGradient(ourDeltzFraction) > theirGradientLimit do 
								trace("Large potential gradient detected in the other segment at ",nodeOrder, " attempting to adjust")
								ourDeltzFraction = ourDeltzFraction + (1/8) -- eighths are used as these add exactly in binary
							end
							ourZCorrection = zcorrection*ourDeltzFraction
							ourZ = ourZCorrection + newPos.p1.z
						end
						local localMinOrMax = ourZ > rpos.p.z and ourZ > lpos.p.z or ourZ < rpos.p.z and ourZ < lpos.p.z
						trace("adjusted deltaz by ourDeltzFraction=",ourDeltzFraction, " ourZCorrection=",ourZCorrection," deltaz=",deltaz, " ourZ=",ourZ, " zcorrection=",zcorrection, " minZoffset=",minZoffset, " ourOriginalz=",newPos.p1.z," theirOiginalz=",theirPos.p1.z, " localMinOrMax=",localMinOrMax)
						
						newPos.p1.z = ourZ
						
						
						if params.isCargo and weAreHigher and nodeOrder >= numberOfNodes-1 and params.isTrack then 
							trace("Setting forceTunnelTheirs because ",nodeOrder)
							forceTunnelTheirs = true
							theirRequiredSpan = theirRequiredSpan + 20
						end
						segmentsPassingAbove = segmentsPassingAbove or zcorrection < 0 
						local collisionSegsThisSplit = {}
						local function buildSplitDetail(edge, doubleTrackEdge) 
							if type(edge) == "number" then 
								edge = util.getEntity(edge) 
							end 
							if doubleTrackEdge and type(doubleTrackEdge)=="table" then 
								doubleTrackEdge = doubleTrackEdge.id
							end 
							local theirPosLocal = collisionInfo.collisionPointLookup[edge.id] or theirPos
							return { 
								edge = edge,
								theirPos = theirPosLocal ,
								deltaz=deltaz,
								canCrossAtGrade=canCrossAtGrade,
								theirRequiredSpan = theirRequiredSpan,
								ourRequiredSpan=ourRequiredSpan,
								remainingDeltaz=remainingDeltaz, 
								doubleTrackEdge=doubleTrackEdge, 
								doNotCorrectOtherSeg=doNotCorrectOtherSeg,
								forceTunnelTheirs =forceTunnelTheirs,
								ourZCorrection=ourZCorrection,
								applyNodeOffsetsOnly=applyNodeOffsetsOnly
							}
						end 
						
						table.insert(collisionSegsThisSplit, buildSplitDetail(edge, doubleTrackEdge) )
					 
						if doubleTrackEdge then
							table.insert(collisionSegsThisSplit, buildSplitDetail(doubleTrackEdge, edge))
							local edgesThisSplit = {}
							edgesThisSplit[edge.id]=true 
							edgesThisSplit[doubleTrackEdge]=true
							for i = 1, 3 do 
								local otherDoubleTrackEdge = util.findDoubleTrackEdgeExpanded(edge.id,edgesThisSplit)
								trace("RoutePreparation looking for otherDoubleTrackEdge, found:",otherDoubleTrackEdge, " from ",doubleTrackEdge)
								if otherDoubleTrackEdge then 
									edgesThisSplit[otherDoubleTrackEdge]=true
									context.allCollisionEdges[otherDoubleTrackEdge]=true 
									table.insert(collisionSegsThisSplit, buildSplitDetail(otherDoubleTrackEdge))
								else 
									break
								end 
							end 
						end 
						if otherEdgeId then 
							trace("Setting up collisionSeg2 for ",otherEdgeId)
							table.insert(collisionSegsThisSplit, buildSplitDetail(otherEdgeId))
						end
						if parallelHighwayEdge   then 
							trace("Setting up parallelHighwayEdge for ",parallelHighwayEdge)
							table.insert(collisionSegsThisSplit,  buildSplitDetail(parallelHighwayEdge))
						end
						if edge.track then 
							if #collisionSegsThisSplit > 1 then 
								ourRequiredSpan = ourRequiredSpan + (1-#collisionSegsThisSplit)*params.trackWidth
								trace("Increasing ourRequiredSpan to ", ourRequiredSpan)
							end 
						end 
							
						ourRequiredMinOffset = 0.5*ourRequiredSpan + params.minSeglength
						 
						
						
						if  ourRequiredMinOffset < vec2.distance(newPos.p1, routePoints[nodeOrder+1].p) and
							ourRequiredMinOffset < vec2.distance(newPos.p1, lpos.p) and nodeOrder > 1 
							and #newSplitPoints ==0 then
							
							local flatten = localMinOrMax and math.abs(ourZCorrection) > 0
							
							if flatten then 
								-- want a flat solution for our crossing
								trace("Flattening the solution")
								ourActualEdge.p0.z = ourZ
								ourActualEdge.p1.z = ourZ
								ourActualEdge.t0.z = 0 
								ourActualEdge.t1.z = 0
								noResolve = true
								context.frozen[nodeOrder]=true
							end
							
							local pBefore = newPos.p1 - 0.5*ourRequiredSpan*tnormal
							local pBefore1 = pBefore
							--pBefore = util.solveForNearestHermitePosition(pBefore, ourEdge)
							local s = util.solveForPositionHermitePositionAtRelativeOffset(newPos.p1, - 0.5*ourRequiredSpan, ourActualEdge)
							if s.solutionConverged then
								pBefore = s.p
							end
							trace("The gap between the pBefore1 and pBefore was ", util.distance(pBefore1, pBefore), " distance to their pos",vec2.distance(pBefore,theirPos.p1), " at ",pBefore.x,pBefore.y)
							if util.distance(pBefore1, pBefore) > params.minSeglength then 
								trace("The gap between the pBefore1 and pBefore was ", util.distance(pBefore1, pBefore), " using original postion")
								pBefore = pBefore1
							end
							local solutionBefore = util.solveForPosition(pBefore, ourActualEdge, vec2.distance)
							solutionBefore.p1.z=ourZ
							rpos.p.z = ourZ
							local edgeToNextPoint = {
								p0 = solutionBefore.p1,
								p1 = rpos.p,
								t0 = solutionBefore.t2, 
								t1 = solutionBefore.t3
							} 
							
							
							local pAfter = newPos.p1 + 0.5*ourRequiredSpan*tnormal
							local pAfter1 = pAfter
							--pAfter = util.solveForNearestHermitePosition(pAfter, edgeToNextPoint)
							local s = util.solveForPositionHermitePositionAtRelativeOffset(newPos.p1, 0.5*ourRequiredSpan, ourActualEdge)
							if s.solutionConverged then 
								pAfter = s.p
							end 
							trace("The gap between the pAfter1 and pAfter was ", util.distance(pAfter1, pAfter), " distance to their pos",vec2.distance(pAfter,theirPos.p1), " at ",pAfter.x,pAfter.y)
							if  util.distance(pAfter1, pAfter)  > params.minSeglength then 
								trace("The gap between the pAfter1 and pAfter was ", util.distance(pAfter1, pAfter)," using original postion")
								pAfter = pAfter1
							end
							if flatten and solutionBefore.t1.z ~= 0 then 
								trace("Warning! SolutionBefore.t1.z ~=0", solutionBefore.t1.z ~= 0, " attempting to correct") 
								solutionBefore.t1.z =0 
							end
							local solutionAfter = util.solveForPosition(pAfter, edgeToNextPoint)
							pPos = { p = solutionBefore.p1, t = solutionBefore.t1, t2=solutionAfter.t0}
							pPos.p.z = ourZ 
							if context.rightLengths[nodeOrder-1] then 
								context.rightLengths[nodeOrder-1]=math.min(context.rightLengths[nodeOrder-1], calc2dEdgeLength(lpos, pPos))
							end
							solutionAfter.p1.z = ourZ 
							context.actualHeights[nodeOrder] = ourZ
							if flatten then 
								context.actualHeights[nodeOrder-1] = ourZ
								context.actualHeights[nodeOrder+1] = ourZ
							end
							if  weAreHigher  then
								context.minHeights[nodeOrder] = math.max(context.minHeights[nodeOrder], ourZ)
								context.maxHeights[nodeOrder] = math.max(context.minHeights[nodeOrder], context.maxHeights[nodeOrder])
								trace("Set context.minHeights to ",context.minHeights[nodeOrder]," at ",nodeOrder)
							else 
								segmentsPassingAbove = true
								context.maxHeights[nodeOrder] = math.min(context.maxHeights[nodeOrder], ourZ)
								context.minHeights[nodeOrder] = math.min(context.minHeights[nodeOrder], context.maxHeights[nodeOrder])
								trace("Set context.maxHeights to ",context.maxHeights[nodeOrder]," at ",nodeOrder)
							end
							--context.suppressSmoothToTerrain[nodeOrder-2]=true
							if math.abs(zcorrection) > 0 then
								context.suppressSmoothToTerrain[nodeOrder-1]=true
								context.suppressSmoothToTerrain[nodeOrder]=true
								context.suppressSmoothToTerrain[nodeOrder+1]=true
							end
							--context.suppressSmoothToTerrain[nodeOrder+2]=true
							trace("Length first of tangent before, ", vec3.length(routePoints[nodeOrder-1].t2)," after=",vec3.length(solutionBefore.t0)," and ",vec3.length(pPos.t),  " dist = " , util.distance(routePoints[nodeOrder-1].p, pPos.p), " dist to actual = ", util.distance(lpos.p, pPos.p))
							trace("Length mid of tangent before, ", vec3.length(routePoints[nodeOrder].t  )," after=",vec3.length(pPos.t2), " and ",vec3.length(solutionAfter.t1 ), " dist = " , util.distance(solutionAfter.p1, pPos.p))
							trace("Length last of tangent =",vec3.length(solutionAfter.t2 )," and ", vec3.length(solutionAfter.t3 ), " dist = " , util.distance(routePoints[nodeOrder+1].p, solutionAfter.p1 ))
							trace("Solution before converged? ",solutionBefore.solutionConverged, " solutionAfterConverged?",solutionAfter.solutionConverged)
							lpos.t= vec3.length(lpos.t)*vec3.normalize(solutionBefore.t0)
							lpos.t2= solutionBefore.t0
							routePoints[nodeOrder]=pPos 
							trace("Setting point at ",nodeorder,"to",pPos.p.x,pPos.p.y)
							routePoints[nodeOrder+1].t= solutionAfter.t3
							
							-- can't rely on smoothing function as it doesn't know about point we are about to insert
							local distance = vec2.distance(pPos.p, lpos.p)
							local maxDeltazToLast = maxGradient*distance
							trace("correcting prior route point z by ",maxDeltazToLast, " height before = ",lpos.p.z, " distance was",distance)
							local maxDeltazToNext = maxGradient*vec2.distance(pPos.p,solutionAfter.p1)
							
							if zcorrection > 0 then 
								lpos.p.z= math.max(lpos.p.z, pPos.p.z -maxDeltazToLast)
								routePoints[nodeOrder+1].p.z= math.max(context.minHeights[nodeOrder+1], math.max(routePoints[nodeOrder+1].p.z, pPos.p.z -maxDeltazToNext))
								--context.minHeights[nodeOrder-1]=math.max(context.minHeights[nodeOrder-1], lpos.p.z)
								--context.minHeights[nodeOrder+1]=math.max(context.minHeights[nodeOrder+1], routePoints[nodeOrder+1].p.z)
							elseif zcorrection < 0 then 
								lpos.p.z= math.min(lpos.p.z, pPos.p.z +maxDeltazToLast)
								routePoints[nodeOrder+1].p.z= math.min(routePoints[nodeOrder+1].p.z, pPos.p.z +maxDeltazToNext)
								--context.lockedHeights[nodeOrder-1]=true
								 
								context.maxHeights[nodeOrder+1]=math.min(context.maxHeights[nodeOrder+1], routePoints[nodeOrder+1].p.z)
							end
							--context.actualHeights[nodeOrder-1]=routePoints[nodeOrder-1].p.z
							context.actualHeights[nodeOrder+1]=routePoints[nodeOrder+1].p.z
							trace(" height after = ",lpos.p.z, " nodeOrder=",nodeOrder)
							
							smooth(nodeOrder, numberOfNodes)
							reversesmooth(nodeOrder, 2)
							
							trace("inserting new split point at nodeOrder=",nodeOrder," ourRequiredSpan=",ourRequiredSpan," theirRequiredSpan=",theirRequiredSpan, " remainingDeltaz=",remainingDeltaz, " theirZ = ",theirPos.p1.z, " length(t2)=",vec3.length(solutionAfter.t2), ", p=",solutionAfter.p1.x,  solutionAfter.p1.y)
							local newPpos =  { p = solutionAfter.p1, t=solutionAfter.t1, t2 = solutionAfter.t2 }
							if context.leftLengths[nodeOrder+1] then 
								context.leftLengths[nodeOrder+1]=math.min(context.leftLengths[nodeOrder+1],calc2dEdgeLength(newPpos, routePoints[nodeOrder+1]))
							end
							local newSplitPoint = {
									pPos =newPpos,
									tunnelCandidate = tunnelCandidate,
									needsBridge = needsBridge,
									terrainHeight = util.th(solutionAfter.p1),
									frozen = frozen,
									noResolve = noResolve,
									collisionSegments = collisionSegsThisSplit,
									nodeOrder = nodeOrder,
									spiralPoint = routePoints[nodeOrder].spiralPoint,
							}
							 
							if #newSplitPoints > 0 then -- not fully tested
								trace("WARNING, multiple split points detected at nodeOrder ",nodeOrder)
							end
							table.insert(newSplitPoints, newSplitPoint)
						else  -- required span is too much 
							local minSeglength = params.minSeglength
							if (nodeOrder == 1 or nodeOrder==numberOfNodes) and params.useDoubleTerminals then 
								minSeglength = 60
								trace("Setting minSeglength to ", minSeglength," at ",nodeOrder)
							end 
							--local originalp = pPos.p
							local originalp = #newSplitPoints > 0 and  newSplitPoints[1].pPos.p or pPos.p
							pPos = { p = newPos.p1, t = newPos.t1, t2=newPos.t2}
						--	local nextpPos = #newSplitPoints > 0 and  newSplitPoints[1].pPos or routePoints[nodeOrder+1] -- TODO: don't think this is right, this needs to be oour current point 
							local nextpPos = routePoints[nodeOrder+1]
							local distanceChange = vec2.distance(originalp, pPos.p)
							local movedBackwards = vec2.distance(pPos.p,nextpPos.p) > vec2.distance(originalp,nextpPos.p) 
							if movedBackwards then
								local originalDistanceToLast = vec2.distance(pPos.p, getActualLastLastPoint())
								local recalculatedDistance = originalDistanceToLast-distanceChange
								if recalculatedDistance <0 then 
									trace("WARNING! Detected attempt to encroach on previous point, distToLast was ", originalDistanceToLast," distanceChange =",distanceChange, " attempting to correct at ",pPos.p.x,pPos.p.y)
									pPos.p = pPos.p + (math.abs(recalculatedDistance)+params.minSeglength)*tnormal
									trace("Corrected p =",pPos.p.x, pPos.p.y)
								end
							end
							
							local maxBackDist = vec2.distance(pPos.p, getActualLastPoint())-minSeglength
							local backLimited = maxBackDist < 0.5*ourRequiredSpan 
							if maxBackDist < minSeglength then
								 
								trace("Appears to be relatively back limited, attempting to correct maxBackDist=", maxBackDist)
								local s = util.solveForPositionHermitePositionAtRelativeOffset(pPos.p, minSeglength, ourActualEdge) 
								if s.solutionConverged then 
									pPos  = s 
									pPos.t = pPos.t1
									maxBackDist = vec2.distance(pPos.p, getActualLastPoint())-minSeglength
									trace("New maxBackDist=", maxBackDist)
								end 
							end
							
							
							
							local maxFrontDist = vec2.distance(pPos.p, nextpPos.p)-minSeglength
							local frontLimited = maxFrontDist < 0.5*ourRequiredSpan
							if maxFrontDist < minSeglength then 
								trace("Appears to be relatively front limited, attempting to correct maxFrontDist=", maxFrontDist)
								local s =  util.solveForPositionHermitePositionAtRelativeOffset(pPos.p, -minSeglength, ourActualEdge) 
								if s.solutionConverged then 
									pPos = s
									pPos.t = pPos.t1
									maxFrontDist = vec2.distance(pPos.p, nextpPos.p)-minSeglength
									maxBackDist = vec2.distance(pPos.p, getActualLastPoint())-minSeglength
									trace("New maxFrontDist=", maxFrontDist,"recalculated maxBackdist =",maxBackDist)
								end 
							end
						 
							trace("Detected large span ",ourRequiredSpan," attempting to adjust, h=",pPos.p.z, " maxBackDist=",maxBackDist, " maxFrontDist=",maxFrontDist)
							if localMinOrMax then 
								tnormal.z=0
								lpos.t2.z=0
								nextpPos.t.z=0
								tnormal = vec3.normalize(tnormal)
							end
						--	local s1 = util.solveForPositionHermitePositionAtRelativeOffset(pPos.p, -math.min(maxBackDist, 0.5*ourRequiredSpan), ourActualEdge)
						--	local s2 = util.solveForPositionHermitePositionAtRelativeOffset(pPos.p,  math.min(maxFrontDist, 0.5*ourRequiredSpan), ourActualEdge)
							local s1 = util.solveForPositionHermitePositionAtRelativeOffset(newPos.p1, -math.min(maxBackDist, 0.5*ourRequiredSpan), ourActualEdge)
						 	local s2 = util.solveForPositionHermitePositionAtRelativeOffset(newPos.p1,  math.min(maxFrontDist, 0.5*ourRequiredSpan), ourActualEdge)
							if not s1.solutionConverged or not s2.solutionConverged then 
								trace("WARNING! Solution before did not converge, aborting")
								if weAreHigher then 
									local minHeight = math.abs(zcorrection) > 0 and ourZ or theirPos.p1.z+minZoffset
									trace("Setting minHeights to ",minHeight)
									context.minHeights[nodeOrder]=math.max(context.minHeights[nodeOrder], minHeight) 
								else
									segmentsPassingAbove = true
									local maxHeight = math.abs(zcorrection) > 0 and ourZ or theirPos.p1.z-minZoffset
									trace("Setting maxHeights to ",maxHeight)									
									context.maxHeights[nodeOrder]=math.min(context.maxHeights[nodeOrder], maxHeight)
								end 
								smooth(nodeOrder, numberOfNodes)
								if not collisionSegments then
									collisionSegments={}					
								end
								util.insertAll(collisionSegments, collisionSegsThisSplit)
								--table.insert(collisionSegments, collisionSeg)
								goto continue
							end
							local pBefore = s1.p
							local pAfter = s2.p
							pPos.z = ourZ 
							pBefore.z = ourZ
							pAfter.z = ourZ
							local length = util.calculateTangentLength(lpos.p, pPos.p, lpos.t2, tnormal)
							local priorEdge = {
								p0 = lpos.p,
								p1 = pPos.p,
								t0 = length*vec3.normalize(lpos.t2), 
								t1 = length*tnormal, 
							}
							
							local solutionBefore = util.solveForPosition(pBefore, priorEdge)
							if not solutionBefore.solutionConverged then 
								trace("WARNING! Solution before did not converge, aborting")
								if weAreHigher then 
									local minHeight = math.abs(zcorrection) > 0 and ourZ or theirPos.p1.z+minZoffset
									trace("Setting minHeights to ",minHeight)
									context.minHeights[nodeOrder]=math.max(context.minHeights[nodeOrder], minHeight) 
								else
									segmentsPassingAbove = true
									local maxHeight = math.abs(zcorrection) > 0 and ourZ or theirPos.p1.z-minZoffset
									trace("Setting maxHeights to ",maxHeight)									
									context.maxHeights[nodeOrder]=math.min(context.maxHeights[nodeOrder], maxHeight)
								end 
								smooth(nodeOrder, numberOfNodes)
								if not collisionSegments then
									collisionSegments={}					
								end
								util.insertAll(collisionSegments, collisionSegsThisSplit)
								--table.insert(collisionSegments, collisionSeg)
								goto continue
							end
							local priorPoint = nodeOrder == 1 and pPos or lpos
							if frontLimited and not backLimited then 
								priorPoint.p.z = ourZ 
								priorPoint.t.z = 0
								priorPoint.t2 = solutionBefore.t0
								priorPoint.t2.z = 0
								trace("Using the current point to move backwards")
								priorPoint = pPos
							end
							priorPoint.p= solutionBefore.p1
							priorPoint.t= solutionBefore.t1
							priorPoint.t2= solutionBefore.t2
							local length = util.calculateTangentLength(pPos.p, nextpPos.p, pPos.t2, nextpPos.t)
							local nextEdge = {
								p0 = pPos.p,
								p1 = nextpPos.p,
								t0 = length*vec3.normalize(pPos.t2), 
								t1 = length*vec3.normalize(nextpPos.t), 
							}
							local solutionAfter = util.solveForPosition(pAfter, nextEdge)
							if not solutionAfter.solutionConverged then 
								trace("WARNING! Solution after did not converge, aborting")
							 
								if weAreHigher then 
									local minHeight = math.abs(zcorrection) > 0 and ourZ or theirPos.p1.z+minZoffset
									trace("Setting minHeights to ",minHeight)
									context.minHeights[nodeOrder]=math.max(context.minHeights[nodeOrder], minHeight) 
								else
									segmentsPassingAbove = true
									local maxHeight = math.abs(zcorrection) > 0 and ourZ or theirPos.p1.z-minZoffset
									trace("Setting maxHeights to ",maxHeight)									
									context.maxHeights[nodeOrder]=math.min(context.maxHeights[nodeOrder], maxHeight)
								end 
								smooth(nodeOrder, numberOfNodes)
								if not collisionSegments then
									collisionSegments={}					
								end
								util.insertAll(collisionSegments, collisionSegsThisSplit)
								goto continue 
							end
							
							
							routePoints[nodeOrder]=pPos 
							local nextPToAdjust = nodeOrder == numberOfNodes and pPos or nextpPos
							if backLimited and not frontLimited then 
								nextPToAdjust.p.z = ourZ 
								nextPToAdjust.t = solutionAfter.t3
								nextPToAdjust.t.z = 0 
								nextPToAdjust.t2.z = 0
								trace("Using the current point to move forwards")
								nextPToAdjust = pPos
								nextPToAdjust.t= solutionAfter.t1
								nextPToAdjust.t2= solutionAfter.t2
								nextpPos.t = solutionAfter.t3
								nextpPos.t2 = vec3.length(nextpPos.t2)*vec3.normalize(solutionAfter.t3)
							else 
								pPos.t = solutionAfter.t0 
								pPos.t2 = solutionAfter.t1 
								nextPToAdjust.t=solutionAfter.t2
								nextPToAdjust.t2 = solutionAfter.t3
							end
							
							if nodeOrder < numberOfNodes then
								nextPToAdjust.p= solutionAfter.p1
							end
							
							trace("adjusted prior point to ",priorPoint.p.x,priorPoint.p.y)
							trace("adjusted this point to ",pPos.p.x,pPos.p.y,"tangents",pPos.t.x,pPos.t.y)
							trace("adjusted next point to ",nextPToAdjust.p.x,nextPToAdjust.p.y)
							trace("This == prior",pPos == priorPoint, " this == next", pPos == nextPToAdjust)
							trace("Dist prior to this = ",util.distance(priorPoint.p, pPos.p)," dist this to next=",util.distance(pPos.p, nextPToAdjust.p))
							if pPos == nextPToAdjust then 
								trace("Discovered that we are now back so next segment set to continue")
								continueCrossingNextSeg = true 
							end
							if pPos.t.x ~= pPos.t.x then -- not exactly sure how we get here, but if we solve for position at start or end of curve and end  up with zero tangents, which NaN during normalization
								trace("WARNING! NaN tangent detected, attempting to correct")
								if pPos == priorPoint then -- TODO: this may need refinement
									pPos.t = nextPToAdjust.p - pPos.p
								
								else 
									pPos.t = pPos.p - priorPoint.p
								end
								if pPos.t2.x ~= pPos.t2.x then 
									trace("Correcting t2")
									pPos.t2 = pPos.t
								end  								
							end 
							context.leftLengths[nodeOrder]=math.min(calc2dEdgeLength(lpos,pPos), context.leftLengths[nodeOrder])
							context.rightLengths[nodeOrder]=math.min(calc2dEdgeLength(pPos,nextpPos), context.rightLengths[nodeOrder])
							-- for adjacent points only adjust downwards in length as they may have already made their own corrections
							if context.rightLengths[nodeOrder-1] then
								context.rightLengths[nodeOrder-1]=math.min(context.rightLengths[nodeOrder-1],context.leftLengths[nodeOrder])
							end
							if context.leftLengths[nodeOrder+1] then
								context.leftLengths[nodeOrder+1]=math.min(context.leftLengths[nodeOrder+1],context.rightLengths[nodeOrder])
							end	
							context.actualHeights[nodeOrder-1]= pPos.p.z  
							context.actualHeights[nodeOrder]= pPos.p.z  
							context.actualHeights[nodeOrder+1]= pPos.p.z   
							if math.abs(zcorrection) > 0 then 
								context.suppressSmoothToTerrain[nodeOrder-1]=true
								context.suppressSmoothToTerrain[nodeOrder]=true
								context.suppressSmoothToTerrain[nodeOrder+1]=true
								if params.isHighway then -- because of the large potential collision box
									context.suppressSmoothToTerrain[nodeOrder-2]=true
									context.suppressSmoothToTerrain[nodeOrder+2]=true
								end 
							end 
							if weAreHigher then 
								--local minHeight =  theirPos.p1.z+params.minZoffset
								local minHeight = ourZ--
								context.minHeights[nodeOrder-1]=  math.max(context.minHeights[nodeOrder-1], minHeight ) 
								context.minHeights[nodeOrder]= math.max(context.minHeights[nodeOrder], minHeight ) 
								context.minHeights[nodeOrder+1]= math.max(context.minHeights[nodeOrder+1], minHeight )
								trace("Set minHeights to ",minHeight)
								if nodeOrder == 1 or nodeOrder == numberOfNodes and params.isTrack then 
									trace("Forcing tunnel on their edge at nodeorder = ",nodeOrder) 
									for k, collisionSeg in pairs(collisionSegsThisSplit) do 
										collisionSeg.forceTunnelTheirs = true
										collisionSeg.theirRequiredSpan = collisionSeg.theirRequiredSpan + 40
									end
								end
								
							else 
								segmentsPassingAbove = true
	--							local maxHeight =  theirPos.p1.z-params.minZoffset
								local maxHeight = ourZ 
								trace("Setting maxHeights from ",nodeOrder-1," to ",nodeOrder+1," to ",maxHeight)
								context.maxHeights[nodeOrder-1]= math.min(context.maxHeights[nodeOrder-1],maxHeight) 
								context.maxHeights[nodeOrder]=  math.min(context.maxHeights[nodeOrder], maxHeight ) 
								context.maxHeights[nodeOrder+1]=  math.min(context.maxHeights[nodeOrder+1],maxHeight ) 
							end
							if not pcall(function() smooth(nodeOrder, numberOfNodes) end) then
								debugPrint(routePoints)
							end
							reversesmooth(nodeOrder, 2)
							if not collisionSegments then
								collisionSegments={}					
							end
							if pPos ~= priorPoint or nodeOrder == 1 and pPos == nextPToAdjust or nodeOrder == numberOfNodes then 
								util.insertAll(collisionSegments, collisionSegsThisSplit)
							else 
								if not collisionSegmentsForNextSplit then 
									collisionSegmentsForNextSplit = {}
								end 
								trace("Inserting collision segment for next split at nodeOrder",nodeOrder)
								util.insertAll(collisionSegmentsForNextSplit, collisionSegsThisSplit)
 
							end
							if pPos ~= priorPoint and pPos ~= nextPToAdjust then 
								trace("Setting continueCrossingNextSeg at",nodeorder)
								if #newSplitPoints > 0 then 
									newSplitPoints[#newSplitPoints].continueCrossingNextSeg = true
								else
									continueCrossingNextSeg = true
								end
							end
						end
					end 
				end
				
				--trace("collision check at nodeOrder = ",nodeOrder," came back as false as the collide point is out of range") 
			elseif t and constructionId >=0 then
				local construction = util.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
				if  construction.stations[1] and nodeOrder > 2 and nodeOrder < numberOfNodes-2 then
					local constructionz = construction.transf:cols(3).z
					local heightNeeded = math.min(context.actualHeights[nodeOrder], constructionz-15)
					context.actualHeights[nodeOrder] = heightNeeded
					context.maxHeights[nodeOrder] = math.min(heightNeeded, context.maxHeights[nodeOrder])
					tunnelCandidate=true
				end
			else
				local connectedSegs1= util.getSegmentsForNode(edge.node0)
				local connectedSegs2= util.getSegmentsForNode(edge.node1)
				if (#connectedSegs1 == 1 or #connectedSegs2 == 1) and nodeOrder > 1 and nodeOrder < numberOfNodes-1 then 
					local tangent 
					local node 
					if #connectedSegs1 == 1 then 
						node = edge.node0
						tangent = -1*util.v3fromArr(edge.node0tangent)
					else 
						node = edge.node1
						tangent = util.v3fromArr(edge.node1tangent)
					end
					local nodePos = util.nodePos(node)
					local minDistToNode = 15 + util.getEdgeWidth(edge.id)
					local dummyNodePos = nodePos + minDistToNode * vec3.normalize(tangent)
					local c = util.checkFor2dCollisionBetweenPoints(pUp.p, pDown.p, nodePos, dummyNodePos)
					if c then 
						local dist = vec2.distance(nodePos,c)
						trace("detected collision with dead end node at ", nodeOrder, " the position was ",c.x, c.y, " dist=",dist, " pPos.p=",pPos.p.x,pPos.p.y)
						pPos.p = util.v2ToV3(c, pPos.p.z) + (minDistToNode-dist)* vec3.normalize(tangent)
						trace("pPos after = ", pPos.p.x, pPos.p.y)
						routePoints[nodeOrder]=pPos 
					end
				end
			end
			
			::continue::
		end
	end
	if lastSplit and lastSplit.needsBridgeNextSplit then 
		needsBridge = true 
		edgeTypeRequiredForDeconfliction = true 
	elseif lastSplit and lastSplit.needsTunnelNextSplit then 
		tunnelCandidate = true 
		edgeTypeRequiredForDeconfliction = true 
	end
	
	--if not collisionSegments and not collissionThisSplit then
	--	pPos.p = util.checkProposedNodePositionAndShiftIfNecessary(pPos.p, context.seglength/2, params.isTrack)
	--end
	if not collisionSegments and not collissionThisSplit and not needsBridge and not tunnelCandidate and nodeOrder>1 and not routePoints[nodeOrder].followRoute and not routePoints[nodeOrder-1].followRoute then
		local testBuild = trialBuildBetweenPoints(lpos, pPos)
		if testBuild.isError then 
			trace("Trial build discovered problem at ",nodeOrder, " attempting to correct")
			local roadSegments = {}
			local maxWidth = 0
			for i, entity in pairs(testBuild.collisionEntities) do 
				if entity.entity < 0 then goto continue end
				local entityDetails = util.getEntity(entity.entity)  
				trace("Inspecting collision entity ",entity.entity, " full entity details were ", entityDetails)
				if not entityDetails then -- water mesh 
					if util.distanceToNearestWaterVertex(pPos.p) < 40 then 
						needsBridge = true 
						local minHeight = math.max(math.max(minBridgeHeight, util.th(pPos.p)+minBridgeHeightAboveGround),util.th(lpos.p)+minBridgeHeightAboveGround)
						trace("Setting minHeight to ",minHeight," to avoid water mesh collision")
						pPos.p.z = math.max(pPos.p.z, minHeight)
						context.minHeights[nodeOrder] = math.max(context.minHeights[nodeOrder], minHeight)
						context.actualHeights[nodeOrder]=math.max(context.actualHeights[nodeOrder], context.minHeights[nodeOrder])
						if lastSplit then 
							lastSplit.needsBridge = true
							lpos.p.z = math.max( lpos.p.z, minHeight)
							context.minHeights[nodeOrder-1] = math.max(context.minHeights[nodeOrder-1], minHeight)
							context.actualHeights[nodeOrder-1]=math.max(context.actualHeights[nodeOrder-1], context.minHeights[nodeOrder-1])
						end
						smooth(nodeOrder, numberOfNodes)
					end
				elseif entityDetails.type == "BASE_EDGE" and not context.allCollisionEdges[entityDetails.id] and edgeIsRemovable(entityDetails, nodeOrder, numberOfNodes, params) and not context.edgesToIgnore[entityDetails.id] then 
					if not collisionSegments then
						collisionSegments={}					
					end
					table.insert(collisionSegments, {
						edge = entityDetails,
						removeEdge = true
					})
				elseif entityDetails.type == "BASE_EDGE" and not entityDetails.track and not context.allCollisionEdges[entityDetails.id]
					and not util.isIndustryEdge(entityDetails.id) and not context.edgesToIgnore[entityDetails.id] then
					local deltaz = pPos.p.z - util.getEdgeMidPoint(entityDetails.id).z
					if math.abs(deltaz) > params.minZoffset and not string.find(entityDetails.streetType,"airport")  then 
						trace("Collision can likely be resolved by adjusting the edge type as the deltaz was ",deltaz)
						if deltaz > 0 then 
							trace("adding needsBridge at ",nodeOrder)
							needsBridge = true 
							if getActualLastSplit() then
								getActualLastSplit().needsBridge = true
							end
							needsBridgeNextSplit = true 
							
						else 
							trace("adding tunnelCandidate at ",nodeOrder)
							tunnelCandidate = true 
							if getActualLastSplit() then
								getActualLastSplit().tunnelCandidate = true
							end
							needsTunnelNextSplit = true
						end
						edgeTypeRequiredForDeconfliction = true
						context.allCollisionEdges[entityDetails.id]=true
					elseif math.abs(util.signedAngle(pPos.t, util.v3fromArr(entityDetails.node0tangent))) < math.rad(20) and
						math.abs(util.signedAngle(pPos.t, util.v3fromArr(entityDetails.node1tangent))) < math.rad(20) and not util.isFrozenEdge(entityDetails.id) then 
						trace("Discovered possible reroute candidate at ",entityDetails.id)
						table.insert(roadSegments, entityDetails)
						maxWidth = math.max(maxWidth, util.getEdgeWidth(entity.entity))
					else 
						if deltaz >= 0 and not string.find(entityDetails.streetType,"airport") then 
							pPos.p.z = pPos.p.z + math.max(params.minZoffset-deltaz,0) 
							context.actualHeights[nodeOrder-1] = math.max(pPos.p.z,context.actualHeights[nodeOrder-1])
							context.actualHeights[nodeOrder] = pPos.p.z 
							context.actualHeights[nodeOrder+1] = math.max(pPos.p.z,context.actualHeights[nodeOrder+1])
							trace("Setting minHeights to ",pPos.p.z)
							context.minHeights[nodeOrder-1] = math.max(pPos.p.z, context.minHeights[nodeOrder-1])
							context.minHeights[nodeOrder] = math.max(pPos.p.z, context.minHeights[nodeOrder])
							context.minHeights[nodeOrder+1] = math.max(pPos.p.z, context.minHeights[nodeOrder+1])
							needsBridge = true 
							if getActualLastSplit() then
								getActualLastSplit().needsBridge = true
							end
							needsBridgeNextSplit = true 
						else 
							pPos.p.z = pPos.p.z -math.max(params.minZoffset+deltaz,0)
							trace("Setting tunnelCandidate at",pPos.p.x,pPos.p.y,"at a height of",pPos.p.z)
							tunnelCandidate = true 
							if getActualLastSplit() then
								getActualLastSplit().tunnelCandidate = true
							end
							needsTunnelNextSplit = true
							context.actualHeights[nodeOrder-1] = math.max(pPos.p.z,context.actualHeights[nodeOrder-1])
							context.actualHeights[nodeOrder] = pPos.p.z 
							context.actualHeights[nodeOrder+1] = math.max(pPos.p.z,context.actualHeights[nodeOrder+1])
							trace("Setting maxHeights to ",pPos.p.z)
							context.maxHeights[nodeOrder] = math.min(pPos.p.z ,  context.maxHeights[nodeOrder])
						end	
						smooth(nodeOrder, numberOfNodes)
						context.allCollisionEdges[entityDetails.id]=true
						edgeTypeRequiredForDeconfliction = true						
					end
				elseif entityDetails.type == "BASE_EDGE" and (entityDetails.track or util.isIndustryEdge(entityDetails.id)) and not context.allCollisionEdges[entityDetails.id]  and not context.edgesToIgnore[entityDetails.id] then
					local pPos2 = util.deepClone(pPos) 
					local collisionResolvedByShift = false 
					for i = -10, 10 do 
						pPos2.p = util.nodePointPerpendicularOffset(pPos.p, pPos.t, i)
						if not trialBuildBetweenPoints(lpos, pPos2).isError then 
							trace("Collision was resolved by shifting by an offset of i=",i, " at nodeOrder",nodeOrder)
							pPos.p = pPos2.p 
							collisionResolvedByShift = true 
							frozen = true
							context.frozen[nodeOrder]=true
							break 
						end 
					end
					if collisionResolvedByShift then 
						break 
					end
					if not collisionSegments then
						collisionSegments={}					
					end
					context.allCollisionEdges[entityDetails.id]=true
					local deltaz = pPos.p.z - util.getEdgeMidPoint(entityDetails.id).z 
					
					if math.abs(deltaz) < params.minZoffset then 
						local ourZ 
						local ourZCorrection
						if deltaz > 0 then 
							ourZCorrection=math.max(params.minZoffset-deltaz,0)
							ourZ = ourZCorrection +pPos.p.z 
							context.minHeights[nodeOrder-1]=math.max(ourZ, context.minHeights[nodeOrder-1]) 
							context.minHeights[nodeOrder]=math.max(ourZ, context.minHeights[nodeOrder]) 
							if not util.getEdge(entityDetails.id).type == 2 then 
								needsBridge = true
							end
						else 
							ourZCorrection = math.min(-params.minZoffset+deltaz,0)
							ourZ = ourZCorrection+pPos.p.z
							context.maxHeights[nodeOrder-1]=math.min(ourZ, context.maxHeights[nodeOrder-1])
							context.maxHeights[nodeOrder]=math.min(ourZ, context.maxHeights[nodeOrder])
							tunnelCandidate =true
						end
						trace("Attempting to fix collision with entity ",entityDetails.id," by changing height from ",pPos.p.z," to ",ourZ)
						context.actualHeights[nodeOrder]=ourZ
						pPos.p.z = ourZ 
						smooth(nodeOrder, numberOfNodes)
						table.insert(collisionSegments, 
						{edge = entityDetails , theirPos = nil , deltaz=deltaz, canCrossAtGrade=false, theirRequiredSpan = 200, ourRequiredSpan=ourRequiredSpan, remainingDeltaz=0, doubleTrackEdge=false, doNotCorrectOtherSeg=true, forceTunnelTheirs =false, ourZCorrection=ourZCorrection})
					end
				elseif entityDetails.type == "CONSTRUCTION" then 
					trace("Found potential construction on route")
					local theirP = util.getConstructionPosition(entityDetails.id)
					local deltaz = pPos.p.z - theirP.z 
				end 
				::continue::
			end
			if #roadSegments > 0 then 
				local reRoute = {}
				reRoute.edgeIds = {} 
				local alreadySeen = {} 
				local ourEdge = { 
					t0 = lpos.t2,
					t1 = pPos.t, 
					p0 = lpos.p,
					p1 = pPos.p,
				}
				local midPoint = util.hermite2(0.5, ourEdge).p
				local t = util.solveForPosition(midPoint, ourEdge, util.distance).t1
				local minOffset = maxWidth + 15
				local testP = util.nodePointPerpendicularOffset(midPoint,t, minOffset)
				local testP2 = util.nodePointPerpendicularOffset(midPoint,t, -minOffset)
				local closest = util.evaluateWinnerFromSingleScore(roadSegments, function(edge) return vec2.distance(util.getEdgeMidPoint(edge.id), midPoint) end)
				if not context.allCollisionEdges[ closest.id] then 
					table.insert(reRoute.edgeIds, closest.id)
					context.allCollisionEdges[ closest.id] = true 
				end
					
				local replacementPoint 
				if vec2.distance(testP, util.getEdgeMidPoint(closest.id)) < vec2.distance(testP2, util.getEdgeMidPoint(closest.id)) then 
					replacementPoint = { p = testP, t=t, t2=t}
				else 
					replacementPoint = { p = testP2, t=t, t2=t}
				end
				
				alreadySeen[closest.id]=true
				local leftSegs = util.getSegmentsForNode(closest.node0)
				local leftEdgeId = leftSegs[1] == closest.id and leftSegs[2] or leftSegs[1]
				if not context.allCollisionEdges[ leftEdgeId] then 
					table.insert(reRoute.edgeIds, leftEdgeId)
					context.allCollisionEdges[ leftEdgeId] = true 
				end
				local leftEdge = util.getEdge(leftEdgeId) 
				reRoute.startNode = leftEdge.node0 == closest.node0 and leftEdge.node1 or leftEdge.node0 
				reRoute.startTangent = leftEdge.node0 == closest.node0 and -1*util.v3(leftEdge.tangent1) or util.v3(leftEdge.tangent0) 
				
				local rightSegs = util.getSegmentsForNode(closest.node1)
				local rightEdgeId = rightSegs[1] == closest.id and rightSegs[2] or rightSegs[1]
				if not context.allCollisionEdges[ rightEdgeId] then 
					table.insert(reRoute.edgeIds, rightEdgeId)
					context.allCollisionEdges[ rightEdgeId] = true 
				end
				local rightEdge = util.getEdge(rightEdgeId) 
				reRoute.endNode = rightEdge.node1 == closest.node1 and rightEdge.node1 or rightEdge.node0 
				reRoute.endTangent = rightEdge.node1 == closest.node1 and -1*util.v3(rightEdge.tangent0) or util.v3(rightEdge.tangent1) 
				
				local startNodePos = util.nodePos(reRoute.startNode)
				local endNodePos = util.nodePos(reRoute.endNode)
				replacementPoint.p.z = 0.5*(startNodePos.z+endNodePos.z)
				replacementPoint.t.z = 0.5*(endNodePos.z-startNodePos.z)
				replacementPoint.t2.z = replacementPoint.t.z
				
				local leftDist = util.distance(startNodePos, replacementPoint.p)
				reRoute.startTangent = leftDist * vec3.normalize(reRoute.startTangent)
				replacementPoint.t = leftDist * vec3.normalize(replacementPoint.t)
				
				local rightDist = util.distance(endNodePos, replacementPoint.p)
				reRoute.endTangent = rightDist * vec3.normalize(reRoute.endTangent)
				replacementPoint.t2 = rightDist * vec3.normalize(replacementPoint.t2)
				--for i, edge in pairs(roadSegments) do
				--	table.insert(reRoute.edges)
				--end
				
				if not context.allCollisionEdges[rightEdgeId] and not context.allCollisionEdges[leftEdgeId]
					and not util.isIndustryEdge(rightEdgeId) and not util.isIndustryEdge(leftEdgeId) then
					context.allCollisionEdges[rightEdgeId] = true 
					context.allCollisionEdges[leftEdgeId] = true
					trace("Setup reroute for edge ",closest.id," with new point", replacementPoint.p.x, replacementPoint.p.y)
					reRoute.replacementPoints = { replacementPoint } 
					context.allCollisionEdges[closest.id]=true
					 
					if not collisionSegments then
						collisionSegments={}					
					end
					table.insert(collisionSegments, {
						edge = closest,
						reRoute = reRoute
					})
				end
			end
		end 
	end

	
	local valid = true
	




	local abort = false
	
	-- final validation
	if needsBridge and pPos.p.z < (context.minTerrainHeights[nodeOrder]+minBridgeHeightAboveGround) and not edgeTypeRequiredForDeconfliction then
		trace("removing needsBridge",nodeOrder)
		needsBridge =false
	end 
	if pPos.p.z > (context.minTerrainHeights[nodeOrder]+minBridgeHeight) and not needsBridge then  
		needsBridge = true
		trace("adding needsBridge",nodeOrder)
	end 
	if pPos.p.z < (context.maxTerrainHeights[nodeOrder]-minTunnelDepth) and not tunnelCandidate then
		tunnelCandidate = true
		for i =1, #newSplitPoints do 
			if newSplitPoints[i].pPos.p.z < newSplitPoints[i].terrainHeight-minTunnelDepth then
				newSplitPoints[i].tunnelCandidate = true
			end
		end
		trace("adding tunnelCandidate", nodeOrder)
	end 
	if tunnelCandidate and pPos.p.z>= context.maxTerrainHeights[nodeOrder] and not edgeTypeRequiredForDeconfliction then
		tunnelCandidate = false
		context.tunnelHeights[nodeOrder]=nil
		trace("removing tunnelCandidate", nodeOrder)
	
	end
	
	

	if routePoints[nodeOrder].frozen then
		trace("checking for nearByEdge")
		local edgeId = util.findEdgeConnectingPoints(routePoints[nodeOrder-1].p, pPos.p)
		if edgeId then 
			trace("Nearby edge found at ",nodeOrder, " edgeId=",edgeId)
			local edge = util.getEdge(edgeId)
			if edge.type == 1 then
				trace("Found tunnel type in nearby edge, copying")
				tunnelCandidate = true
			end
		end
	end
	if numberOfNodes == nodeOrder then -- final validation pass 
		for i = 1, numberOfNodes do  
			context.actualHeights[i] = math.min(context.maxHeights[i], math.max(context.minHeights[i], context.actualHeights[i]))
		end 
		
		smooth(1, numberOfNodes) -- final pass to correct gradients
	end

	--trace("finished creating new node")
	--if tracelog then debugPrint( {  newnode = newNode.comp.position, calculatedNode = pPos, t0=t0, t1=t1, t2=t2,t3=t3, t=t}) end
	return {
		pPos=pPos,
		oldNode=oldNode,
		oldNodePos= oldNode and util.nodePos(oldNode) or nil,
		tunnelCandidate=tunnelCandidate,
		frozen = frozen,
		noResolve = noResolve,
		valid= valid,
		needsBridge=needsBridge,
		needsSuspensionBridge = needsSuspensionBridge,
		terrainHeight = context.terrainHeights[nodeOrder],
		maxTerrainHeight = context.maxTerrainHeights[nodeOrder],
		minTerrainHeight = context.minTerrainHeights[nodeOrder],
		lastSplit = lastSplit,
		abort = abort,
		bridgeHeight = bridgeHeight,
		collisionSegments = collisionSegments,
		newSplitPoints = newSplitPoints,
		nodeOrder = nodeOrder,
		spiralPoint = routePoints[nodeOrder].spiralPoint,
		continueCrossingNextSeg = continueCrossingNextSeg,
		needsTunnelNextSplit = needsTunnelNextSplit ,
		needsBridgeNextSplit = neesBridgeNextSplit, 
		edgeTypeRequiredForDeconfliction = edgeTypeRequiredForDeconfliction, 
		collisionSegmentsForNextSplit = collisionSegmentsForNextSplit,
		junction = junction,
		segmentsPassingAbove = segmentsPassingAbove,
	}
end

local function buildFinalSplitDetail(split, nodeOrder,   splits,routePoints, context) 
	local lpos = nodeOrder > 1 and splits[nodeOrder-1].pPos or routePoints[0]
	local pPos = split.pPos
	local rpos = nodeOrder < #splits and splits[nodeOrder+1].pPos or routePoints[#routePoints]
	
	local inputT0 = 2*util.v3(lpos.t2)
	local inputT1 = 2*util.v3(rpos.t)

	
	 --[[
	local newEdge = {
			t0 = inputT0,
			t1 = inputT1,
			p0 = lpos.p,
			p1 = rpos.p,
	}]]--
	
	local newEdge = util.createCombinedEdge(lpos, pPos, rpos)

	local solution = util.solveForPosition(pPos.p, newEdge)
	if not solution.solutionConverged then 
		trace("WARNING! Solution not fully converged at ",nodeOrder)
	end
	local p1 = solution.p1
	local t1 = solution.t1
	local t2 = solution.t2
	if not p1 then
		p1 = pPos.p
		t1 = pPos.t
		t2 = pPos.t2
	end
	
	
	if not solution.solutionConverged or split.frozen or split.noResolve or noResolve then
		p1 = pPos.p
		t1 = pPos.t 
		t2 = pPos.t2 
	end
	if pPos.p.z ~= p1.z then
		trace("d=",d, "changing p1.z from ", p1.z, " to pPos.p.z=", pPos.p.z, " lpos.p.z=",lpos.p.z," rpos.p.z=",rpos.p.z," lpos.t.z=",lpos.t.z," rpos.t.z=",rpos.t.z," t1=",t1.x,t1.y,t1.z," t2=",t2.x,t2.y,t2.z, " pPos.p.t=",pPos.t.x,pPos.t.y,pPos.t.z)
		p1.z = pPos.p.z
	end
	local newNode = api.type.NodeAndEntity.new()
	newNode.entity = split.oldNode and split.oldNode or -nodeOrder-3*#splits-10000
	setPositionOnNode(newNode, p1)
	split.newNode = newNode
	split.p1=p1
	split.t1=t1
	split.t2=t2
	return split
end
local function validateRoutePoints(routePoints) 
	for i = 1 , #routePoints do 
		local p0 = routePoints[i-1].p
		local p1 = routePoints[i].p
		local t0 = routePoints[i-1].t2
		local t1 = routePoints[i].t
		local t2 = routePoints[i].t2
		local dist = util.distance(p0,p1)
		local lt0 = vec3.length(t0)
		local lt1 = vec3.length(t1)
		local tnat = p1-p0 
		local angle1 = util.signedAngle(t0,t1)
		local angle2 = util.signedAngle(t0,tnat)
		local angle3 = util.signedAngle(tnat,t1)
		local zeroAngle = util.signedAngle(t1,t2)
		local tangentLength = util.calculateTangentLength(p0, p1, t0, t1)
		trace("Routepoint i=",i,"p=",p1.x,p1.y,p1.z,"t1=",t1.x,t1.y,t1.z,"t2=",t2.x,t2.y,t2.z," followRoute=",routePoints[i].followRoute,"frozen=",routePoints[i].frozen,"Dist was ",dist, " lt0=",lt0,"lt1=",lt1,"angles were",math.deg(angle1),math.deg(angle2),math.deg(angle3),"tangentLength=",tangentLength,"zeroAngle=",math.deg(zeroAngle))
		if lt0 < dist then 
			trace("Possible problem at ",i)
		end 
		if lt1 < dist then 
			trace("Possible problem at ",i)
		end
		if math.abs(zeroAngle) > math.rad(1) then 
			trace("Problem, non zero angle at",i)
		end 
	
		
		if math.abs(lt0/lt1) > 1.1 or math.abs(lt1/lt0) > 1.1 then 
			trace("Possible problem at ",i)
		end
		if math.abs(lt0-tangentLength) > 5 or math.abs(lt1-tangentLength)>5 or math.abs(lt0/lt1) > 1.1 or math.abs(lt1/lt0) > 1.1 then 
			trace("Possible inconsisten tangent lengths, correcting")
			routePoints[i-1].t2 = tangentLength*vec3.normalize(t0)
			routePoints[i].t = tangentLength*vec3.normalize(t1)
		end 
		
		local maxAngle = math.max(math.abs(angle1),math.max(math.abs(angle2),math.abs(angle3)))
		if maxAngle > math.rad(90) then 
			trace("WARNING! Inconsistent angle may have been obsevered at",i,"maxAngle was",math.deg(maxAngle))
		end 

	end 
end


local function validate(routePoints, splits, params, context)
	local maxBuildGrad = maxBuildSlope(params)
	trace("being validation of split points")
	local maxGradient = params.maxGradient
	local lastP = routePoints[0].p
	local lastT = routePoints[0].t2
	local needsGradientCorrection = false
	local splitsToRemove = {}
	for i = 1, #splits+1 do 
		local p = i<=#splits and splits[i].pPos.p or routePoints[#routePoints].p
		local nextP = i<=#splits-1 and splits[i+1].pPos.p or i == #splits and routePoints[#routePoints].p or nil
		local t = i<=#splits and splits[i].pPos.t or routePoints[#routePoints].t
		local t2 = i<=#splits and splits[i].pPos.t2 or routePoints[#routePoints].t2
		trace("Inspecting point at",i,"p=",p.x,p.y,p.z,"t=",t.x,t.y,t.z,"t2=",t2.x,t2.y,t2.z)
		local length = util.calcEdgeLength2d(lastP, p, lastT, t)
		local deltaz = p.z-lastP.z
		local gradient = deltaz/length
		if math.abs(gradient) > maxGradient then 
			trace("Gradient exceeds limits at i=",i," gradient=",gradient," maxGradient=",maxGradient," deltaz=",deltaz," length=",length)
		end
		if math.abs(gradient) > maxBuildGrad  then 
			trace("Detected maxbuildSlope exceeded, will need correction")
			needsGradientCorrection = true
		end
		if util.distance(p, lastP) < params.minSeglength then
			trace("Short distance detected at i=",i, util.distance(p, lastP))
		end
		local tl = vec3.length(t)
		if t1~=t1 then 
			trace("ERROR! NaN tangent detected at i=",i,  tl)
		end 
		if tl < params.minSeglength  then
			trace("Short tangent detected at i=",i,  tl)
		end
		if math.abs(vec3.length(lastT)-vec3.length(t))> 1.1*tl then 
			trace("Tangent difference detected at i=",i, " vec3.length(lastT)=",vec3.length(lastT),"vec3.length(t)=",vec3.length(t))
		end
		if util.distance(p, lastP) < 1 then 
			--trace("removing split at i",i," original nodeOrder=",splits[i].nodeOrder)
			table.insert(splitsToRemove, i)
		end
		if math.abs(vec3.length(lastT)-util.distance(lastP, p))> 1.1*vec3.length(lastT) then 
			trace("Tangent to dist difference detected at i=",i, " vec3.length(lastT)=",vec3.length(lastT),"util.distance(lastP, p)=",util.distance(lastP, p))
		end
		local angle = util.signedAngle(t,  t2)
		local angleToNaturalTangent = util.signedAngle(t, p-lastP)
		local angleToNextNaturalTangent
		if nextP then 
			angleToNextNaturalTangent = util.signedAngle(t2, nextP-p)
		end 
		if math.abs(angleToNaturalTangent) > math.rad(30) then 
			trace("WARNING! High angle to naturalTangent at i=",i," was ",math.deg(angleToNaturalTangent), " connecting ",p.x,p.y, " with ",lastP.x,lastP.y )
			if math.abs(math.rad(180)-math.abs(angleToNaturalTangent)) < 1 then 
				trace("removing split at i",i," original nodeOrder=",splits[i] and splits[i].nodeOrder or "?", " due to high angle to natural tangent")
				table.insert(splitsToRemove, i)
			end 
		end 
		
		if  math.abs(angle) > math.rad(5) then
			trace("Tangent Angle difference detected at i=",i, " util.signedAngle(t, splits[i].t2)=",math.deg(angle))
			local newT = vec3.normalize(vec3.normalize(t)+vec3.normalize(t2))
			if  i<=#splits then 
				trace("Attempting to correct")
				splits[i].pPos.t = vec3.length(t)*newT
				splits[i].pPos.t2 = vec3.length(t2)*newT
			end 
		end
		if nextP then 
			local pointsAngle = util.signedAngle(p-lastP, nextP-p)
			if math.abs(pointsAngle) > math.rad(30) then 
				trace("Large angle change detected at ",i," angle=",math.deg(pointsAngle))
			end
		end
		
		lastT = t2 
		lastP = p
	end
	
	for j = 1, #splitsToRemove do
		local i = splitsToRemove[j]
		local correctedIdx = i-j+1
		trace("Removing split point at ",i," correctedIdx=",correctedIdx)
		local split = splits[correctedIdx]
		if not split then 
			trace("WARNING! No split found at ",correctedIdx)
			goto continue 
		end
		if split.collisionSegments then 
			local priorSplit = splits[correctedIdx-1]
			if not priorSplit then 
				priorSplit = splits[correctedIdx+1]
			end
			if not priorSplit.collisionSegments then 
				priorSplit.collisionSegments ={}
			end 
			for k , seg in pairs(split.collisionSegments) do 
				table.insert(priorSplit.collisionSegments, seg)
			end 
		end 
		local splitBefore = splits[correctedIdx-1]
		local splitAfter = splits[correctedIdx+1]
		if splitBefore and splitAfter then 
			local dist = util.distance(splitBefore.pPos.p, splitAfter.pPos.p)
			splitBefore.pPos.t2 = dist*vec3.normalize(splitBefore.pPos.t) -- use opposite side tangent to avoid numerical problems with short length
			splitAfter.pPos.t = dist*vec3.normalize(splitAfter.pPos.t2)
		end 
		table.remove(splits, correctedIdx)
		::continue::
	end 

	for i = 1, #splits do
		local split = splits[i]
		local th = util.th(split.pPos.p)
		local thAdj = util.th(split.pPos.p, true)
		split.terrainHeight = th 
		split.maxTerrainHeight = math.max(th, thAdj)
		split.minTerrainHeight = math.min(th, thAdj)
	end
	local count = 0 
	while needsGradientCorrection and count < 12 do
		count = count + 1
		local lastP = routePoints[0].p
		local lastT = routePoints[0].t2
		needsGradientCorrection = false
		local startAt = 1
		local endAt = #splits+1 
		local increment = 1
		local shouldReverse = count%4<0
		if shouldReverse then 
			startAt = endAt 
			endAt = 1 
			increment = -1
		end 
		trace("Doing gradient correction iteration at count=",count,"shouldReverse?",shouldReverse)
		for i = startAt, endAt,increment do 
			local p = i<=#splits and splits[i].pPos.p or routePoints[#routePoints].p
			local nextP = i<=#splits-1 and splits[i+1].pPos.p or i == #splits and routePoints[#routePoints].p or nil
			local t = i<=#splits and splits[i].pPos.t or routePoints[#routePoints].t
			local t2 = i<=#splits and splits[i].pPos.t2 or routePoints[#routePoints].t2
			local length = util.calcEdgeLength2d(lastP, p, lastT, t)
			local deltaz = p.z-lastP.z
			local gradient = deltaz/length
			if math.abs(gradient) > maxBuildGrad and not (splits[i] and (splits[i].collisionSegments or splits[i].spiralPoint))  then 
				local maxDeltaZ = maxBuildGrad * length * 0.99 -- don't want to keep recorrecting the same point
				local pointToCorrect = i == #splits and lastP or p 
				local referenceHeight = i == #splits and p.z or lastP.z
				if i == #splits then 
					deltaz = -deltaz 
				end
				local originalz = pointToCorrect.z
				if deltaz < 0 then 
					pointToCorrect.z = referenceHeight - maxDeltaZ
				else 
					pointToCorrect.z = referenceHeight + maxDeltaZ
				end
				
				lastT.z = p.z-lastP.z 
				t.z = lastT.z
				trace("corrected height at ",i," from ",originalz," to ",pointToCorrect.z,"t.z=",t.z)
				if nextP then 
					t2.z = nextP.z-p.z
					trace("Set t2.z=",t2.z)
				end
				needsGradientCorrection = true 
				break -- need to revalidate the whole route 
			end
			lastT = t2
			lastP = p
		end 
		
	end
	local bridgeSections = {}
	local prevNeedsBridge = false 
	local prevHadCollisionSegments = false 
	for i = 1, #splits do 
		local split = splits[i]
		local height = split.pPos.p.z
		local heightAboveTerrain = height - split.terrainHeight
		local forbidSuspension = false 
		if split.collisionSegments then 
			for i, seg in pairs(split.collisionSegments) do 
				if seg.remainingDeltaz then 
					local zcorrection = seg.ourZCorrection-seg.remainingDeltaz
					if zcorrection > 0 and zcorrection < params.minZoffsetSuspension -1 then 
						trace("Fobidding suspension bridge at split ",i)
						forbidSuspension = true 
						break
					end 
				end				
			end 
		
		end 
		
		local needsNewSection = split.needsBridge and not   prevNeedsBridge
		local hasCollisionSegments = split.collisionSegments and #split.collisionSegments > 0
	--[[	if split.needsBridge and prevHadCollisionSegments~=hasCollisionSegments then 
			trace("Inserting extra bridge section to account for collision segments")
			needsNewSection = true 
		end]]--
		local currentSection = bridgeSections[#bridgeSections]
		if currentSection and split.needsBridge and context.minHeights[split.nodeOrder] > currentSection.startHeight and hasCollisionSegments then 
			trace("At ",split.nodeOrder,"the min height was higher than the required height adjusting to add new section")
			needsNewSection = true 
		end 
		
		if needsNewSection  then 
			if currentSection and not currentSection.endIdx then 
				currentSection.endIdx = i-1
				currentSection.numPoints = currentSection.endIdx-currentSection.startIdx 
				currentSection.length = util.distance( splits[i-1].pPos.p,  splits[currentSection.startIdx].pPos.p)
				currentSection.endHeight = splits[i-1].pPos.p.z
				currentSection.segmentsPassingAbove = currentSection.segmentsPassingAbove or split.segmentsPassingAbove
				currentSection.forbidSuspension = currentSection.forbidSuspension or forbidSuspension
				if split.collisionSegments then 
					currentSection.collisionSegments = true 
				end
			end
			
			local bridgeSection = {}
			bridgeSection.startIdx = i
			bridgeSection.maxHeightAboveTerrain = heightAboveTerrain
			bridgeSection.startHeight = height
			bridgeSection.segmentsPassingAbove = split.segmentsPassingAbove
			bridgeSection.collisionSegments = split.collisionSegments
			bridgeSection.forbidSuspension = forbidSuspension
			table.insert(bridgeSections, bridgeSection)
		elseif prevNeedsBridge and not split.needsBridge then 
			local bridgeSection = bridgeSections[#bridgeSections]
			bridgeSection.endIdx = i-1
			bridgeSection.numPoints = bridgeSection.endIdx-bridgeSection.startIdx 
			bridgeSection.length = util.distance( splits[i-1].pPos.p,  splits[bridgeSection.startIdx].pPos.p)
			bridgeSection.endHeight = splits[i-1].pPos.p.z
			bridgeSection.segmentsPassingAbove = bridgeSection.segmentsPassingAbove or split.segmentsPassingAbove
			bridgeSection.forbidSuspension = bridgeSection.forbidSuspension or forbidSuspension
			if split.collisionSegments then 
				bridgeSection.collisionSegments = true 
			end
		end 
		if split.needsBridge then 
			local bridgeSection = bridgeSections[#bridgeSections]
			if split.needsSuspensionBridge then 
				bridgeSection.needsSuspensionBridge = true 
			end 
			if split.terrainHeight < util.getWaterLevel() then 
				bridgeSection.bridgeOverWater = true 
			end 
			bridgeSection.segmentsPassingAbove = bridgeSection.segmentsPassingAbove or split.segmentsPassingAbove
			bridgeSection.maxHeightAboveTerrain = math.max(bridgeSection.maxHeightAboveTerrain, heightAboveTerrain)
			bridgeSection.forbidSuspension = bridgeSection.forbidSuspension or forbidSuspension
			trace("Height above terrain was ", heightAboveTerrain)
			
		end 
		
		prevHadCollisionSegments = hasCollisionSegments
		prevNeedsBridge = splits[i].needsBridge
	end 
	trace("Found ",#bridgeSections, " along route")
	if util.tracelog then 
		debugPrint({bridgeSections=bridgeSections}) 
	end
	for j = 1, #bridgeSections do 
		local bridgeSection = bridgeSections[j] 
		local previousHeight = bridgeSection.startHeight 
		if not bridgeSection.endHeight then 
			bridgeSection.endHeight = routePoints[#routePoints].p.z
			bridgeSection.endIdx = #splits
			bridgeSection.numPoints = bridgeSection.endIdx-bridgeSection.startIdx 
			bridgeSection.length = util.distance( splits[#splits].pPos.p,  splits[bridgeSection.startIdx].pPos.p)
		end
		local goingUp = bridgeSection.endHeight > bridgeSection.startHeight
		local goingDown = bridgeSection.endHeight < bridgeSection.startHeight 
		local level = bridgeSection.endHeight == bridgeSection.startHeight 
		trace("Inspecting bridgeSection ",j," needsSuspensionBridge=",bridgeSection.needsSuspensionBridge , " startHeight=",bridgeSection.startHeight, " endHeight=",bridgeSection.endHeight,"bridgeSection.isOverWater?",bridgeSection.isOverWater)
		for i = bridgeSection.startIdx, bridgeSection.endIdx do 
			local split = splits[i]
			split.segmentsPassingAbove = bridgeSection.segmentsPassingAbove
			local height = split.pPos.p.z
			if not bridgeSection.bridgeOverWater and bridgeSection.numPoints > 2 and i ~= bridgeSection.startIdx and i ~= bridgeSection.endIdx and not params.isElevated and not bridgeSection.collisionSegments then 
				local nextHeight = splits[i].pPos.p.z
				local leftDist = util.distance(splits[i-1].pPos.p, split.pPos.p)
				local rightDist = util.distance(splits[i+1].pPos.p, split.pPos.p)
				
				local change = false
				if goingUp then 
					if height < previousHeight then 
						change = true 
						nextHeight = math.max(nextHeight, previousHeight)
					end 
				elseif goingDown then
					if height > previousHeight then 
						change = true
						nextHeight = math.min(nextHeight, previousHeight)						
					end 
				elseif level then 
					if height ~= previousHeight then 
						change = true  
					end 
				end 
				local interpolateHeight = (leftDist*previousHeight+rightDist*nextHeight)/(leftDist+rightDist)
				if split.collisionSegments or splits[i-1] and splits[i-1].collisionSegments or splits[i+1] and splits[i+1].collisionSegments then 
					
					
					--change = false 
				end
				if split.spiralPoint then 
					change = false 
				end 
				if change then 
					trace("Clamping the interpolateHeight to context heights, originally",interpolateHeight)
					interpolateHeight = math.min(context.maxHeights[split.nodeOrder], math.max(context.minHeights[split.nodeOrder], interpolateHeight))
					trace("Discovered bridge dip at ",i," height=",height,"previousHeight=",previousHeight, " interpolateHeight=",interpolateHeight," attempting to correct setting height to ",interpolateHeight, " goingUp=",goingUp, " goingDown=",goingDown)
					height = interpolateHeight
					split.pPos.p.z = height 
					split.pPos.t.z = height-previousHeight
					split.pPos.t2.z = nextHeight-height
					splits[i-1].pPos.t2.z=height-previousHeight
				end 
			end 
			if bridgeSection.needsSuspensionBridge and not params.isElevated and not bridgeSection.forbidSuspension then 
				split.needsSuspensionBridge = true
			end 
			split.bridgeHeight = bridgeSection.maxHeightAboveTerrain
			split.forbidSuspension = bridgeSection.forbidSuspension
			previousHeight = height
		end 
	end 
	for i = 1, #splits do 
		local prevSplit = i == 1 and routePoints[0] or splits[i-1].pPos
		local nextSplit = i == #splits and routePoints[#routePoints] or splits[i+1].pPos
		local split = splits[i].pPos 
		trace("Split at ",i,"t=",split.t.x,split.t.y,split.t.z,"t2=",split.t2.x,split.t2.y,split.t2.z)
		if not splits[i].frozen then 
			local len1 = util.calculateTangentLength(prevSplit.p, split.p, prevSplit.t2, split.t)
			local len2 = util.calculateTangentLength( split.p, nextSplit.p, split.t2, nextSplit.t)
			split.t = len1*vec3.normalize(split.t)
			split.t2 = len2*vec3.normalize(split.t2)
			--[[local count = 0
			while vec3.length(split.t) < len1 and count < 10 do 
				count = count + 1
				split.t = len1*vec3.normalize(split.t)
				len1 = util.calcEdgeLength(prevSplit.p, split.p, prevSplit.t2, split.t)
			end 
			local count = 0
			while vec3.length(split.t2) < len2 and count < 10 do 
				count = count + 1
				split.t2 = len2*vec3.normalize(split.t2)
				len2 = util.calcEdgeLength( split.p, nextSplit.p, split.t2, nextSplit.t)
			end ]]--	
		end 
	end 
	
	
	for i = 1, #splits do 
		local prevSplit = i == 1 and routePoints[0] or splits[i-1].pPos
		local nextSplit = i == #splits and routePoints[#routePoints] or splits[i+1].pPos
		local split = splits[i]
		local pPos = split.pPos 
		if not split.tunnelCandidate and  split.terrainHeight > 0 and not split.frozen then 
			pPos.t.z = pPos.p.z - prevSplit.p.z
			pPos.t2.z = nextSplit.p.z - pPos.p.z 
			local len1 = util.calcEdgeLength(prevSplit.p, pPos.p, prevSplit.t2, pPos.t)
			local len2 = util.calcEdgeLength( pPos.p, nextSplit.p, pPos.t2, nextSplit.t)
			local t = vec3.normalize(pPos.t)
			local t2 = vec3.normalize(pPos.t2)
			local weightedAverage = (len1*t.z + len2*t2.z)/(len1+len2)
			pPos.t.z = weightedAverage*len1
			pPos.t2.z = weightedAverage*len2
		else 
			if pPos.t.z == 0 ~= pPos.t2.z == 0 then 
				trace("Discovered tangent z inconsistency", pPos.t.z, pPos.t2.z," setting both to zero")
				pPos.t.z = 0
				pPos.t2.z = 0
			end
		end 
	end
	
	
	trace("end validation of split points")
end

local function checkTunnels(splits) 
	
	for i = 1, #splits do 
		local p = splits[i].pPos.p 
		local th = splits[i].maxTerrainHeight
		if th-p.z < 10 and th-p.z > 5 and util.searchForFirstEntity(p, 500, "TOWN") then 
			local oldHeight = p.z
			p.z = th - 11
			trace("Reducing height at ",p.x,p.y," for town tunnel from ",oldHeight," to ",p.z) 
		end		
		local expectedTunnel = th-p.z >= 10
		if expectedTunnel ~= splits[i].tunnelCandidate and 
			not(splits[i].tunnelCandidate and
				(
					splits[i].collisionSegments or splits[i].edgeTypeRequiredForDeconfliction
					or splits[i+1] and splits[i+1].collisionSegments
					or splits[i-1] and splits[i-1].collisionSegments
				)
			)
			then
			trace("Correcting tunnel candidate to ",expectedTunnel, " from ", splits[i].tunnelCandidate," at i=",i)
			splits[i].tunnelCandidate = expectedTunnel
		end
		local expectedBridge = splits[i].pPos.p.z-splits[i].minTerrainHeight > 10 
		if expectedBridge and not splits[i].needsBridge then
			trace("Correcting needsBridgee to ",expectedBridge, " from ", splits[i].needsBridge," at i=",i)
			splits[i].needsBridge = expectedBridge
		end
		if i > 1 and i<#splits then 
			local shouldNotHaveBridge = splits[i].pPos.p.z-splits[i].minTerrainHeight <5
				and splits[i-1].pPos.p.z-math.min(splits[i-1].terrainHeight, util.th(splits[i-1].pPos.p,true)) <5
				and splits[i+1].pPos.p.z-math.min(splits[i+1].terrainHeight, util.th(splits[i+1].pPos.p,true)) <5
				and splits[i].terrainHeight >0 
				and splits[i-1].terrainHeight >0 
				and splits[i+1].terrainHeight >0 
			if shouldNotHaveBridge and splits[i].needsBridge then 
				trace("Removing needs bridge from ",i)
				splits[i].needsBridge = false 
			end
			
		end
	end
end

local function applyZSmoothing(splits, params, routePoints)
	local smoothingPasses = 5 
	
	for j = 1, smoothingPasses do 
		for i = 1, #splits  do 
			local before = i==1 and routePoints[0] or splits[i-1].pPos
			local this = splits[i].pPos
			local after = i==#splits and routePoints[#routePoints] or splits[i+1].pPos
			if not this.collisionSegments and not before.collisionSegments and not after.collisionSegments then 
				local combinedEdge = util.createCombinedEdge(before, this, after)
				local s = util.solveForPosition(this.p, combinedEdge, vec2.distance)
				this.p.z = s.p.z 
				this.t.z = s.t1.z
				this.t2.z= s.t2.z
			end
		end
	end 
end

function routePreparation.prepareRoute(dummyEdge, routePoints, nodecount, params)
	local begin = os.clock()
	profiler.beginFunction("routePreparation.prepareRoute")
	local wasCached=  util.cacheNode2SegMapsIfNecessary() 
	if not params.isTrack then 
		--params.minSeglength = math.max(8, params.minSeglength/2)
	end 
	if params.isElevated then 
		params.minBridgeHeight = 8 
	end
	params.ourWidth = params.isTrack and (params.isDoubleTrack and 2*params.trackWidth or params.trackWidth) 
		or params.isHighway and util.getStreetWidth(params.preferredHighwayRoadType) + params.highwayMedianSize 
		or util.getStreetWidth(params.preferredCountryRoadType) 
	
	local prevSplit = nil
	 validateRoutePoints(routePoints) 
	local abort = false
	local context = {} 
	local splits = {}
	for i=1, nodecount do 
		local split = buildSplitPoints(dummyEdge, routePoints,  nodecount, i, prevSplit, context, params)
		prevSplit = split
		table.insert(splits, split) 
		for __, newSplit in pairs(split.newSplitPoints) do
			table.insert(splits, newSplit) 		
		end
	end
	
	
	if params.isElevated then 
		applyZSmoothing(splits, params, routePoints)
	end
	validate(routePoints, splits, params, context)
	checkTunnels(splits)
	local expandedSplits = {} 

	
	for i=2, #splits do 
		local prevSplit = splits[i-1]
		
		table.insert(expandedSplits, prevSplit)
		local split = splits[i]
		-- now try to split for better tunnel portals
		local dist = vec2.distance(split.pPos.p, prevSplit.pPos.p)
		local hasCollisionSegments = split.collisionSegments or prevSplit.collisionSegments
		if dist > 2*params.minSeglength and prevSplit.tunnelCandidate ~= split.tunnelCandidate    then
			local intervals = 2*math.floor(dist/params.minSeglength)
			local minJ =  math.max(math.ceil((32*params.minSeglength)/dist),1)
			trace("inspecting possible tunnel candidate at i=",i, " at intervals ",intervals, "minJ was",minJ)
			local tunnelCandidate = prevSplit.tunnelCandidate and true or false
			local edge = {
				p0=prevSplit.pPos.p,
				t0=prevSplit.pPos.t2,
				p1=split.pPos.p,
				t1=split.pPos.t
			}
			
			local lastP
			local endAt= 32-minJ
			for j = minJ, endAt do -- need to look at points along the segment
				local solution  = util.solveForPositionHermiteFraction((j/32), edge)
				if solution.solutionIsNaN then 
					trace("WARNING! NaN solution found at j=",j,"aborting")
					break
				end 
				local p = solution.p
				local terrainHeight = math.max(util.th(p), util.th(p, true))
				local thisTunnelCandidate = terrainHeight-p.z > 10
				local newSplitPoint
				if thisTunnelCandidate~=tunnelCandidate then 
				
					if tunnelCandidate and not hasCollisionSegments then -- was a tunnel, now in the open -> use previous point  
						if lastP then 
							newSplitPoint = lastP 
							thisTunnelCandidate = true
						else 
							break -- already have the best location
						end
					else 
						newSplitPoint = solution
						thisTunnelCandidate = true
					end
				end
				
				if j == endAt and thisTunnelCandidate and not split.tunnelCandidate then 
					newSplitPoint = solution
				end
				
				if newSplitPoint then 
					terrainHeight = util.th(newSplitPoint.p, true)
					trace("Found a new tunnel portal at i=",i," j=",j, " thisTunnelCandidate=",thisTunnelCandidate, " tunnelCandidate=",tunnelCandidate, "terrainHeight was ",terrainHeight, " ourHeight was ",newSplitPoint.z)
					--assert(thisTunnelCandidate==true)
					thisTunnelCandidate = true
					local otherTunnelPortal
					if prevSplit.tunnelCandidate then 
						for k = i-1, 1, -1 do 
							if splits[k].tunnelCandidate then 
								otherTunnelPortal =splits[k].pPos.p 
							else 
								break
							end
						end
					else 
						for k = i, #splits do 
							if splits[k].tunnelCandidate then 
								otherTunnelPortal =splits[k].pPos.p 
							else 
								break
							end
						end
					end 
					
					if otherTunnelPortal and util.distance(newSplitPoint.p, otherTunnelPortal) >= params.minTunnelLength or hasCollisionSegments then 
						local p = newSplitPoint.p
						if util.distance(p, prevSplit.pPos.p) > params.minSeglength and util.distance(p, split.pPos.p) > params.minSeglength then 
							trace("inserting new tunnel split at ", p.x, p.y, " tangentLengths were ", vec3.length(newSplitPoint.t0), vec3.length(newSplitPoint.t1), vec3.length(newSplitPoint.t2), vec3.length(newSplitPoint.t3))
							prevSplit.pPos.t2= newSplitPoint.t0 
							split.pPos.t = newSplitPoint.t3
							table.insert(expandedSplits, {
								pPos = { p = newSplitPoint.p1, t = newSplitPoint.t1, t2 = newSplitPoint.t2  },
								tunnelCandidate = thisTunnelCandidate,
								terrainHeight = terrainHeight,
								needsBridge = p.z-terrainHeight > 10,
								nodeOrder = split.nodeOrder,
								spiralPoint = split.spiralPoint,
								--frozen = split.frozen or prevSplit.frozen
							})
						elseif util.distance(p, prevSplit.pPos.p) > params.minSeglength then 
							trace("Moving current split backward for tunnel portal")
							split.pPos.p= p
							prevSplit.pPos.t2=newSplitPoint.t0 
							split.pPos.t = newSplitPoint.t1 
							local newLength = vec3.length(split.pPos.t2)+vec3.length(newSplitPoint.t2)
							split.pPos.t2 = newLength*vec3.normalize(newSplitPoint.t2)
							if splits[i+1] then 
								splits[i+1].pPos.t = newLength*vec3.normalize(splits[i+1].pPos.t)
							end
							split.needsBridge = p.z-terrainHeight > 10
							split.tunnelCandidate = thisTunnelCandidate
						elseif util.distance(p, split.pPos.p) > params.minSeglength   then 
							trace("Moving prior split forwards for tunnelPortal")
							prevSplit.pPos.p= p
							local newLength = vec3.length(prevSplit.pPos.t)+vec3.length(newSplitPoint.t0)
							prevSplit.pPos.t= newLength*vec3.normalize(newSplitPoint.t1)
							prevSplit.pPos.t2 = newSplitPoint.t2 
							split.pPos.t = newSplitPoint.t3
							if splits[i-2] then 
								splits[i-2].pPos.t2 = newLength * vec3.normalize(splits[i-2].pPos.t2)
							end
							prevSplit.needsBridge = p.z-terrainHeight > 10
							prevSplit.tunnelCandidate = thisTunnelCandidate
						end 
					else 
						trace("rejected tunnel split as is too short",util.distance(p, otherTunnelPortal))
					end
					break
				end
				
				
				lastP = solution
			end
		end
	end
	table.insert(expandedSplits, splits[#splits]) -- insert the last one 
	
	local expandedSplits2 = {}
		
	for i=2, #expandedSplits do 
		local minSeglength = params.minSeglength
		local prevSplit = expandedSplits[i-1]
		
		table.insert(expandedSplits2, prevSplit)
		local split = expandedSplits[i]
		-- now try to split for better bridge portals
		local dist = vec2.distance(split.pPos.p, prevSplit.pPos.p)
		local hasCollisionSegments = split.collisionSegments or prevSplit.collisionSegments
		if dist > 2*minSeglength and prevSplit.needsBridge ~= split.needsBridge then
			local intervals = 2*math.floor(dist/minSeglength)
			local minJ =  math.max(math.ceil((32*params.minSeglength)/dist),1)
			trace("inspecting possible bridge candidate at i=",i, " at intervals ",intervals,"minJ=",minJ)
			local needsBridge = prevSplit.needsBridge and true or false
			local edge = {
				p0=prevSplit.pPos.p,
				t0=prevSplit.pPos.t2,
				p1=split.pPos.p,
				t1=split.pPos.t
			}
			local waterLevel = util.getWaterLevel()
			local bridgeOverWater  = util.th(split.pPos.p)<waterLevel or util.th(prevSplit.pPos.p)<waterLevel 
			local lastP
			local minPoint = prevSplit.tunnelCandidate and math.ceil(30*minSeglength/dist) or 2
			local maxPoint = split.tunnelCandidate and math.floor(30*(dist-minSeglength)/dist) or 30
			minPoint = math.max(minPoint, minJ)
			maxPoint = math.min(maxPoint, 32-minJ)
			trace("Set max point as ",maxPoint, " minPoint=",minPoint)
			for j = minPoint, maxPoint do -- need to look at points along the segment
				local solution  = util.solveForPositionHermiteFraction((j/32), edge)
				if solution.solutionIsNaN then 
					trace("WARNING! NaN solution found at j=",j,"aborting for bridges")
					break
				end 
				local p = solution.p
				local terrainHeight = math.min(util.th(p), util.th(p, true))
				local thisNeedsBridge = p.z-terrainHeight > params.minBridgeHeight or terrainHeight < 0 or bridgeOverWater and util.distanceToNearestWaterVertex(p) < 40
				local newSplitPoint
				if thisNeedsBridge~=needsBridge then 
				
					if needsBridge and not hasCollisionSegments then -- bridge ending, but want to  end on land
						if lastP then 
							newSplitPoint = lastP 
							thisNeedsBridge = true
						else 
							break -- already have the best location
						end
					else 
						newSplitPoint = solution
						thisNeedsBridge = true
					end
				end
				
				if j == maxPoint and needsBridge and not split.needsBridge then 
					newSplitPoint = solution
				end
				
				if newSplitPoint then 
					terrainHeight = util.th(newSplitPoint.p, true)
					local p =newSplitPoint.p
					trace("Found a new bridge portal at i=",i," j=",j, " thisNeedsBridge=",thisNeedsBridge, " needsBridge=",needsBridge, " terrainHeight was ", terrainHeight, " our height was ",newSplitPoint.z)
					if util.distance(p, prevSplit.pPos.p) > minSeglength and util.distance(p, split.pPos.p) > minSeglength then 
					 
						prevSplit.pPos.t2= newSplitPoint.t0
						
						split.pPos.t = newSplitPoint.t3
						trace("inserting new bridge split at ", newSplitPoint.p1.x, newSplitPoint.p1.y)
						table.insert(expandedSplits2, {
							pPos = { p = newSplitPoint.p1, t = newSplitPoint.t1, t2 = newSplitPoint.t2  },
							needsBridge = thisNeedsBridge,
							terrainHeight = terrainHeight,
							tunnelCandidate = terrainHeight - newSplitPoint.p.z > 10,
							nodeOrder = split.nodeOrder,
							spiralPoint = split.spiralPoint,
							--frozen = split.frozen or prevSplit.frozen
						})
					
					elseif util.distance(p, prevSplit.pPos.p) > minSeglength then 
						if not split.tunnelCandidate then 
							trace("Moving current split backward for bridge portal at ", newSplitPoint.p1.x, newSplitPoint.p1.y, " from ",split.pPos.p.x, split.pPos.p.y)
							split.pPos.p= p
							prevSplit.pPos.t2=newSplitPoint.t0 
							split.pPos.t = newSplitPoint.t1 
							local newLength = vec3.length(split.pPos.t2)+vec3.length(newSplitPoint.t2)
							split.pPos.t2 = newLength*vec3.normalize(newSplitPoint.t2)
							if splits[i+1] then 
								splits[i+1].pPos.t = newLength*vec3.normalize(splits[i+1].pPos.t)
							end
							split.tunnelCandidate = terrainHeight - newSplitPoint.p.z > 10
							split.needsBridge = thisNeedsBridge
						else 
							trace("Suppressing the moving as the split was a tunnel candidate")
							split.needsBridge = thisNeedsBridge	
						end 
					else 
						if not prevSplit.tunnelCandidate then 
							trace("Moving prior split forwards for bridge portal at ", newSplitPoint.p1.x, newSplitPoint.p1.y)
							prevSplit.pPos.p= p
							local newLength = vec3.length(prevSplit.pPos.t)+vec3.length(newSplitPoint.t0)
							prevSplit.pPos.t= newLength*vec3.normalize(newSplitPoint.t1)
							prevSplit.pPos.t2 = newSplitPoint.t2 
							split.pPos.t = newSplitPoint.t3
							if splits[i-2] then 
								splits[i-2].pPos.t2 = newLength * vec3.normalize(splits[i-2].pPos.t2)
							end
							prevSplit.tunnelCandidate = terrainHeight - newSplitPoint.p.z > 10
							prevSplit.needsBridge = thisNeedsBridge	
						else 
							trace("Suppressing the moving as the prior split was a tunnel candidate")
							prevSplit.needsBridge = thisNeedsBridge	
						end 
					end 
					
					break
				end
				
				
				lastP = solution
			end
		end
	end
	table.insert(expandedSplits2, expandedSplits[#expandedSplits]) -- insert the last one 
	
	trace("The expandedSplits were ",#expandedSplits2," compared with ",#splits, " and original nodecount=",nodecount)
	validate(routePoints, expandedSplits2, params, context)
	local result = {}
	for i=1, #expandedSplits2 do
		table.insert(result, buildFinalSplitDetail(expandedSplits2[i], i, expandedSplits2, routePoints, context))
	end
	validate(routePoints, result, params, context)
	if util.tracelog then 
		debugPrint({actualHeights=context.actualHeights, suppressSmoothToTerrain=context.suppressSmoothToTerrain, tunnelHeights = context.tunnelHeights, minHeightsAfter=context.minHeights, maxHeights=context.maxHeights})
	end
	for i = 1, #result do 
		local split = result[i]
		trace("i=",i,"p=",split.p1.x, split.p1.y," tunnelCandidate=",split.tunnelCandidate, "needsBridge=",split.needsBridge," height=",split.p1.z)
	end
	if wasCached then 
		trace("Route preparation clearing node2segmaps")
		util.clearCacheNode2SegMaps()
	end		
	trace("Prepared route time taken:",(os.clock()-begin))
	profiler.endFunction("routePreparation.prepareRoute")
	return {splits = result, allCollisionEdges = context.allCollisionEdges, reRouteNodes=context.reRouteNodes} 
end
return routePreparation