local util = require "ai_builder_base_util"
local vec3 = require "vec3"
local vec2 = require "vec2"
local profiler = require "ai_builder_profiler"
local trace =util.trace
local proposalUtil = {}
local setTangent = util.setTangent
local allowDiagnose = util.tracelog and true 
local attemptPartialBuild = util.tracelog and allowDiagnose and true
local debugResults = util.tracelog and false 
local diagnoseLimit = 200
proposalUtil.allowDiagnose = allowDiagnose
local function setTangents(entity, t)
	setTangent(entity.comp.tangent0, t)
	setTangent(entity.comp.tangent1, t)
end 

local function renormalizeTangents(entity, v)
	setTangent(entity.comp.tangent0, v*vec3.normalize(util.v3(entity.comp.tangent0)))
	setTangent(entity.comp.tangent1, v*vec3.normalize(util.v3(entity.comp.tangent1)))
end 
function proposalUtil.setTunnel(entity)
	entity.comp.type = 2 -- tunnel
	entity.comp.typeIndex = entity.type == 0 and api.res.tunnelTypeRep.find("street_old.lua") or api.res.tunnelTypeRep.find("railroad_old.lua")
end
function proposalUtil.getBridgeType()
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	if  util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom  then
		return cement
	elseif  util.year() >= api.res.bridgeTypeRep.get(iron).yearFrom  then
		return iron
	else 
		return api.res.bridgeTypeRep.find("stone.lua")
	end
end
local function cloneNodesToLua(nodes)
local result = {}
	for i, node in pairs(nodes) do 
		local newNode = {} 
		newNode.comp = {} 
		newNode.comp.position = util.v3(node.comp.position)
		newNode.entity = node.entity		
		table.insert(result, newNode)
	end 
	return result
end 
local function cloneEdgeToLua(edge)
	local newEdge = {}
	newEdge.entity = edge.entity
	newEdge.comp = {}
	newEdge.comp.node0 = edge.comp.node0 
	newEdge.comp.node1 = edge.comp.node1 
	newEdge.comp.tangent0 = util.v3( edge.comp.tangent0)
	newEdge.comp.tangent1 = util.v3( edge.comp.tangent1)
 
	newEdge.type = edge.type 
	newEdge.comp.type = edge.comp.type 
	newEdge.comp.typeIndex = edge.comp.typeIndex 
	newEdge.comp.objects = util.deepClone(edge.comp.objects)
	if edge.type == 1 then 
		newEdge.trackEdge = {}
		newEdge.trackEdge.trackType = edge.trackEdge.trackType
		newEdge.trackEdge.catenary = edge.trackEdge.catenary
	else 
		newEdge.streetEdge = {}
		newEdge.streetEdge.streetType = edge.streetEdge.streetType 
		newEdge.streetEdge.hasBus = edge.streetEdge.hasBus
		newEdge.streetEdge.tramTrackType = edge.streetEdge.tramTrackType 
	end 
	if edge.playerOwned then 
		newEdge.playerOwned ={}
		newEdge.playerOwned.player =  edge.playerOwned.player  
	end 
	return newEdge
end

local function cloneEdgesToLua(edges)
	local result = {}
	for i, edge in pairs(edges) do 
		
		table.insert(result, cloneEdgeToLua(edge))
	
	end 
	return result
end
local function toApiEdge(edge, includeSignals) 
	local newEdge = api.type.SegmentAndEntity.new() 
	newEdge.entity = edge.entity
	newEdge.comp.node0 = edge.comp.node0 
	newEdge.comp.node1 = edge.comp.node1 
	util.setTangent(newEdge.comp.tangent0, edge.comp.tangent0)
	util.setTangent(newEdge.comp.tangent1, edge.comp.tangent1)
	newEdge.type = edge.type 
	newEdge.comp.type = edge.comp.type 
	newEdge.comp.typeIndex = edge.comp.typeIndex 
	if includeSignals then 
		newEdge.comp.objects = util.deepClone(edge.comp.objects)
	end 
	if edge.type == 1 then 
		newEdge.trackEdge.trackType = edge.trackEdge.trackType
		newEdge.trackEdge.catenary = edge.trackEdge.catenary
	else 
		newEdge.streetEdge.streetType = edge.streetEdge.streetType 
		newEdge.streetEdge.hasBus = edge.streetEdge.hasBus
		newEdge.streetEdge.tramTrackType = edge.streetEdge.tramTrackType 
	end 
	if edge.playerOwned then 
		local playerOwned = api.type.PlayerOwned.new()
		playerOwned.player =  edge.playerOwned.player 
		newEdge.playerOwned = playerOwned
	end 
	return newEdge
end

local function toApiEdgeObj(edgeObj) 
		local newSig = api.type.SimpleStreetProposal.EdgeObject.new()
		newSig.left = edgeObj.left
		newSig.oneWay = edgeObj.oneWay 

		newSig.playerEntity = edgeObj.playerEntity 
		newSig.edgeEntity = edgeObj.edgeEntity 
		newSig.name = edgeObj.name 
		newSig.model = edgeObj.model 
 
		newSig.param = edgeObj.param
		return newSig
end 
local function cloneEdges (edges)
	local result = {}
	for i, edge in pairs(edges) do 
		
		table.insert(result, toApiEdge(edge, true))
	
	end 
	return result
end
local function nodePosToString(node)
	if not node then return "nil" end
	return "("..node.comp.position.x..","..node.comp.position.y..","..node.comp.position.z..")"
end

function proposalUtil.areIgnorableErrors(errorState)
	local ignorableError = {
		["Narrow angle"]=true,
		["Bridge pillar collision"]=true,
	}
	if errorState.critical then 
		return false 
	end 
	for i, message in pairs(errorState.messages) do 
		if not ignorableError[message] then 
			return false 
		end 
	end
	--[[if util.contains(errorState.warnings, "Main connection will be interrupted") then 
		trace("WARNING! found broken main connection")
		trace(debug.traceback())
		return false 
	end 	]]--
	return true
	

end 

function proposalUtil.copyStreetProposal(newProposal, dummyProposal)
	for i, node in pairs(newProposal.streetProposal.nodesToAdd) do 
		dummyProposal.streetProposal.nodesToAdd[i]=node
	end 
	for i, node in pairs(newProposal.streetProposal.nodesToRemove) do 
		dummyProposal.streetProposal.nodesToRemove[i]=node
	end 
	for i, edge in pairs(newProposal.streetProposal.edgesToAdd) do 
		dummyProposal.streetProposal.edgesToAdd[i]=edge
	end
	for i, edge in pairs(newProposal.streetProposal.edgesToRemove) do 
		dummyProposal.streetProposal.edgesToRemove[i]=edge
	end
	for i, edgeObj in pairs(newProposal.streetProposal.edgeObjectsToAdd) do 
		dummyProposal.streetProposal.edgeObjectsToAdd[i]=edgeObj
	end
	for i, edgeObj in pairs(newProposal.streetProposal.edgeObjectsToRemove) do 
		dummyProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj
	end
end
function proposalUtil.copyProposal(newProposal, dummyProposal)
	copyStreetProposal(newProposal, dummyProposal)
	for i, constr in pairs(newProposal.constructionsToAdd) do 
		dummyProposal.constructionsToAdd[i]=constr
	end
	dummyProposal.constructionsToRemove = util.deepClone(newProposal.constructionsToRemove)
end
function proposalUtil.validateProposal(newProposal)
	local nodesToAdd = util.shallowClone(newProposal.streetProposal.nodesToAdd)
	local edgesToAdd = util.shallowClone(newProposal.streetProposal.edgesToAdd)
	local edgeObjectsToAdd = util.shallowClone(newProposal.streetProposal.edgeObjectsToAdd)
	local edgesToRemove = util.shallowClone(newProposal.streetProposal.edgesToRemove)
	local edgeObjectsToRemove = util.shallowClone(newProposal.streetProposal.edgeObjectsToRemove)
 
	return proposalUtil.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
end
function proposalUtil.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	if diagnose and (not proposalUtil.allowDiagnose or #edgesToAdd > diagnoseLimit) then
		trace("Suppressing diagnose")
		return 
	end 
	if not edgesToRemove then 
		edgesToRemove = {}
	end
	if not nodesToAdd then 
		nodesToAdd = {}
	end 
	if not edgeObjectsToAdd then 
		edgeObjectsToAdd = {}
	end
	local highSpeedTrackType = api.res.trackTypeRep.find("high_speed.lua")
	trace("Being setting up proposal for route builder")
	if tryToFixTunnelPortals or true then 
		edgesToAdd = cloneEdges(edgesToAdd)
	end
	local oldNodesReferenced = {}
	local newNodeToSegmentMap = {}
	local function recordNodeReferenced(nodeId , newEdgeIdx)
		if nodeId > 0 then
			if not oldNodesReferenced[nodeId] then 
				oldNodesReferenced[nodeId] = {}
			end
			table.insert(oldNodesReferenced[nodeId], newEdgeIdx)
		else 
			if not newNodeToSegmentMap[nodeId] then 
				newNodeToSegmentMap[nodeId]={}
			end 
			table.insert(newNodeToSegmentMap[nodeId], newEdgeIdx)
		end 
	end
	for i, edge in pairs(edgesToAdd) do
		recordNodeReferenced(edge.comp.node0, i)
		recordNodeReferenced(edge.comp.node1, i)
	end
	
	
	
	local removedNodeToSegmentMap = {}
	local function addToMap(nodeId, edgeId)
		if not removedNodeToSegmentMap[nodeId] then
			removedNodeToSegmentMap[nodeId]={}
		end
		removedNodeToSegmentMap[nodeId][edgeId]=true
	end
	
	for i, edgeId in pairs(edgesToRemove) do 
		assert(not util.isFrozenEdge(edgeId), " attempted to remove frozen edge "..edgeId)
		local edge = util.getEdge(edgeId)
		addToMap(edge.node0, edgeId)
		addToMap(edge.node1, edgeId)
	end
	
	local function containsAllEdges(nodeId, edgeSet) 
		local edges =  util.getSegmentsForNode(nodeId) 
		for j, edgeId in pairs(edges) do
			if not edgeSet[edgeId] then
				return false
			end
		end
		return true	
	end
	
	local nextNodeId = -1000-#edgesToAdd 
	local allNodesToAdd = {}
	local nodesByHash = {}
	for i, newNode in pairs(nodesToAdd) do 
		nextNodeId = math.min(nextNodeId, newNode.entity)
		if  newNodeToSegmentMap[newNode.entity] then
			table.insert(allNodesToAdd, newNode)
		else 
			trace("WARNING! Unrefernced node found in newNodes",newNode.entity)
		end 
		local pointHash = util.pointHash3d(newNode.comp.position)
		if pointHash ~= pointHash then
			debugPrint(newNode)
			error("NaN has discovered for newNode "..tostring(newNode.entity))
		end 
		nodesByHash[pointHash]=newNode
	end
	local function getNextNodeId() 
		nextNodeId = nextNodeId -1 
		return nextNodeId
	end
	trace("Setting up proposal, checking nodes to remove")
	
	local function doubleSlipSwitchRemoved(nodeId, edgeSet)
		local nodeComp = util.getNode(nodeId)
		if not nodeComp.doubleSlipSwitch then	
			return false
		end
		local originalCount = #util.getTrackSegmentsForNode(nodeId) 
		local removedCount = util.size(edgeSet)
		local replacedCount = oldNodesReferenced[nodeId] and util.size(oldNodesReferenced[nodeId]) or 0
		local totalNew = originalCount - removedCount + replacedCount
		local isRemoved = totalNew < originalCount
		trace("Detected doubleSlipSwitch, originalCount=",originalCount,"removedCount=",removedCount,"replacedCount=",replacedCount, "totalNew=",totalNew, " isRemoved =", isRemoved)
		return isRemoved
	end
	
	local nodesToRemove = {}
	for nodeId, edgeSet in pairs(removedNodeToSegmentMap) do 
		local removedDoubleSlipSwitch= doubleSlipSwitchRemoved(nodeId, edgeSet) 
		--trace("Double slipswitch removed?",removedDoubleSlipSwitch)
		local isContainsAllEdges = containsAllEdges(nodeId, edgeSet)
		if isContainsAllEdges  or removedDoubleSlipSwitch then
			trace("proposalUtil.setupProposal: removing node",nodeId," isContainsAllEdges?",isContainsAllEdges," doubleSlipSwitchRemoved?", removedDoubleSlipSwitch, "oldNodesReferenced[nodeId]=",oldNodesReferenced[nodeId])
			if util.tracelog then 
				--debugPrint({nodeId = nodeId, edgeSet=edgeSet, segmentForNode = util.getSegmentsForNode(nodeId) })
			end
			assert(not util.isFrozenNode(nodeId), " attempted to remove frozen node "..nodeId)
			table.insert(nodesToRemove, nodeId)
			if oldNodesReferenced[nodeId] or removedDoubleSlipSwitch then -- annoying, we are forced to replace the node if all the segment references are new
				local newNode =  api.type.NodeAndEntity.new() 
				newNode.entity = getNextNodeId() 
				newNode.comp = util.getComponent(nodeId, api.type.ComponentType.BASE_NODE)
				if removedDoubleSlipSwitch then 
					--newNode.comp.doubleSlipSwitch = false
					local segs = util.getSegmentsForNode(nodeId)
					for __, seg in pairs(segs) do 
						if not edgeSet[seg] then 
							local newSeg = util.copyExistingEdge(seg, -1-#edgesToAdd)
							trace("replacing ",seg," attached to a doubleSlipSwitch")
							table.insert(edgesToAdd, newSeg)
							if not oldNodesReferenced[nodeId] then 
								oldNodesReferenced[nodeId]={}
							end
							table.insert(oldNodesReferenced[nodeId], #edgesToAdd)
							table.insert(edgesToRemove, seg)
						end
					end
					
				end
				if  oldNodesReferenced[nodeId] then 
					local hash = util.pointHash3d(newNode.comp.position)
					if nodesByHash[hash] then 
						
						newNode = nodesByHash[hash]
						trace("WARNING! Old node was referenced",nodeId," but a replacement was already setup, using this instead newNodeId=",newNode.entity)
					else 
						trace("proposalUtil.setupProposal: Inserting new node with id ", nextNodeId, " replacing ",nodeId)
						table.insert(allNodesToAdd, newNode)
						nodesByHash[hash]=newNode
					end 
					for __, edgeIdx in pairs( oldNodesReferenced[nodeId]) do 
						trace("Resetting edge on node for ",edgeIdx)
						local newEdge = edgesToAdd[edgeIdx]
						if newEdge.comp.node0 == nodeId then
							newEdge.comp.node0 = newNode.entity
						else 
							assert(newEdge.comp.node1==nodeId)
							newEdge.comp.node1 = newNode.entity						
						end
						if not newNodeToSegmentMap[newNode.entity] then 
							newNodeToSegmentMap[newNode.entity]={}
						end 
						table.insert(newNodeToSegmentMap[newNode.entity], edgeIdx)
					end
				end
			end
		end
	end
	local newNodeToPositionMap = {}
	local newNodeMap = {}
	for i, newNode in pairs(allNodesToAdd) do 
		newNodeToPositionMap[newNode.entity]=util.v3(newNode.comp.position)
		newNodeMap[newNode.entity]=newNode
	end
	local removedEdgeSet = {}
	for i , edge in pairs(edgesToRemove) do 
		removedEdgeSet[edge]=true
	end
	local function getNodePosition(node) 
		if node < 0 then 
			if not newNodeToPositionMap[node] then 
				trace("ERROR! Could not find node",node)
				for i, newNode in pairs(allNodesToAdd) do 
					if newNode.entity == node then 
						trace("Found the node at i=",i,"adding to missing map")
						newNodeToPositionMap[node]=util.v3(newNode.comp.position)
						break 
					end 
				end 
				
			end
			if not newNodeToPositionMap[node] then 
				trace("ERROR!!! Still no node found")
				debugPrint({nodesToAdd=nodesToAdd, allNodesToAdd=allNodesToAdd})
			end 
			return newNodeToPositionMap[node]
		else 
			return util.nodePos(node)
		end
	end
	
	local function calculateMaxConnectAngle(node, tangent, thisEdgeIdx) 
		local maxAngle = 0
		if node > 0 then 
			for i, seg in pairs(util.getTrackSegmentsForNode(node)) do 
				if not removedEdgeSet[seg] then 
					local edge = util.getEdge(seg)
					local otherTangent = util.v3(edge.node0 == node and edge.tangent0 or edge.tangent1)
					maxAngle = math.max(maxAngle, math.abs(util.signedAngle(tangent, otherTangent)))
				end 
			end
		else 
			for i, edgeIdx in pairs(newNodeToSegmentMap[node]) do
				if edgeIdx ~= thisEdgeIdx then 
					local edge = edgesToAdd[edgeIdx].comp
					local otherTangent = util.v3(edge.node0 == node and edge.tangent0 or edge.tangent1)
					maxAngle = math.max(maxAngle, math.abs(util.signedAngle(tangent, otherTangent)))
				end 
			end			
		end 
		return maxAngle
	end 
	if not edgeObjectsToRemove then 
		edgeObjectsToRemove = {}
	end
	local edgeIdxToRemove
	local junctionTunnelPortals = {}
	for node, edges in pairs(newNodeToSegmentMap) do 
		local connectedNodes = { }
		local priorEdgeType
		for i, edgeIdx in pairs(edges) do 
			local entity = edgesToAdd[edgeIdx]
			if not priorEdgeType then priorEdgeType = entity.comp.type end 
			if priorEdgeType ~= entity.comp.type and #edges > 2 and (entity.comp.type == 2 or priorEdgeType == 2) and not junctionTunnelPortals[node] and tryToFixTunnelPortals and entity.type == 1 then 
				trace("Found junction tunnel portal", node)
				junctionTunnelPortals[node] = edges
			end
			
			
			priorEdgeType = entity.comp.type
			local otherNode = entity.comp.node0 == node and entity.comp.node1 or entity.comp.node0 
			if connectedNodes[otherNode] then 
				trace("WARNING! The entity ",entity.entity," appears to be double connected!")
				if util.tracelog then debugPrint({edgesToAdd=edgesToAdd, nodesToAdd=nodesToAdd}) end
				edgeIdxToRemove = edgeIdx 
			else 
				connectedNodes[otherNode]=true
			end
		end
	end
	for node, edges in pairs(junctionTunnelPortals) do  
		local tunnelEdges = {}
		local otherEdges = {}
		for i, edgeIdx in pairs(edges) do 
			local entity = edgesToAdd[edgeIdx]
			if entity.comp.type == 2 then 
				table.insert(tunnelEdges, entity)
			else 
				table.insert(otherEdges, entity)
			end 
		end 
		if #tunnelEdges >= 2 then 
			if #edges == 3 then 
				local tangent = tunnelEdges[1].comp.node0 == node and util.v3(tunnelEdges[1].comp.tangent0) or -1*util.v3(tunnelEdges[1].comp.tangent1)
				local offset = 4*vec3.normalize(tangent) 
				local newNodePos = getNodePosition(node)+offset
				local newNode = newNodeWithPosition(newNodePos, getNextNodeId())
				table.insert(allNodesToAdd, newNode)
				newNodeToPositionMap[newNode.entity]=newNodePos
				newNodeMap[newNode.entity]=newNode
				local newEdge = copySegmentAndEntity(otherEdges[1], -1-#edgesToAdd)
				table.insert(edgesToAdd, newEdge)
				newEdge.comp.objects = {}
				trace("Created newEdge for tunnel junction portal",node," newNode was ",newNode.entity)
				if newEdge.comp.node0 == node then 
					newEdge.comp.node1 = newNode.entity
					util.setTangents(newEdge, offset)
				else 
					newEdge.comp.node0 = newNode.entity
					util.setTangents(newEdge, -1*offset)
				end 
				
				newNodeToSegmentMap[newNode.entity]={} 
				newNodeToSegmentMap[node]={}
				table.insert(newNodeToSegmentMap[node],-newEdge.entity)
				table.insert(newNodeToSegmentMap[newNode.entity],-newEdge.entity)
				for i, entity in pairs(otherEdges) do 
					table.insert(newNodeToSegmentMap[node], -entity.entity)
				end
				for i, entity in pairs(tunnelEdges) do
					if entity.comp.node0 == node then 
						trace("Setting new node on tunnel at node0 ",entity.entity)
						entity.comp.node0 = newNode.entity
						--util.setTangent(entity.comp.tangent0, -1*tangent)
					else 
						trace("Setting new node on tunnel at node1 ",entity.entity)
						entity.comp.node1 = newNode.entity
						--util.setTangent(entity.comp.tangent1, -1*tangent)
					end 
					table.insert(newNodeToSegmentMap[newNode.entity], -entity.entity)
				end
			else 
				for i, entity in pairs(otherEdges) do 
					trace("Setting tunnel on ",entity.entity)
					proposalUtil.setTunnel(entity)
				end 
			end 
		end
	end
	local uniqueObjectCheck ={}
	for i, entity in pairs(edgesToAdd) do 
		if entity.type == 1 then -- track, edge objects are signals
			local newEdgeObjs = {}
			for i, edgeObj in pairs(entity.comp.objects) do 
				if edgeObj[1] > 0 then 
					trace("Removing and replacing ",edgeObj[1]," for entity ",entity.entity)
					assert(not util.contains(edgeObjectsToRemove, edgeObj[1]))
					table.insert(edgeObjectsToRemove, edgeObj[1])
					local newEdgeObj = util.copyEdgeObject(edgeObj, entity.entity, entity, getNodePosition)
					if entity.trackEdge.trackType == highSpeedTrackType and newEdgeObj.model == oldSignalType then 
						newEdgeObj.model = newSignalType
					end
					table.insert(edgeObjectsToAdd,newEdgeObj )
					table.insert(newEdgeObjs, {-#edgeObjectsToAdd , edgeObj[2]})
				else 
					--trace("Edge object already in place ",edgeObj[1]," for entity ",entity.entity)
					table.insert(newEdgeObjs, edgeObj)
				end 
				assert(edgeObj[2] == api.type.enum.EdgeObjectType.SIGNAL)
				assert(not uniqueObjectCheck[newEdgeObjs[#newEdgeObjs][1]])
				uniqueObjectCheck[newEdgeObjs[#newEdgeObjs][1]] =true
			end 
			entity.comp.objects = newEdgeObjs 
		end
	end
	for i, edgeObject in pairs(edgeObjectsToAdd) do 
		if edgeObject.edgeEntity < 0 then 
			local entity = edgesToAdd[-edgeObject.edgeEntity]
			local found = false 
			trace("Inspecting entity",entity.entity," had ",#entity.comp.objects," objects")
			for j, edgeObj in pairs(entity.comp.objects) do  
				if edgeObj[1]==-i then 
					found = true 
					break 
				end 
			end 
			if not found then 
				debugPrint({edgeObjectsToAdd=edgeObjectsToAdd, edgesToAdd=edgesToAdd})
			end
			if not diagnose then 
				assert(found, " edgeObj"..edgeObject.edgeEntity.." found")
			end
		end
	end
	
	
	
	local function doDiagnose(includeSignals)
		trace("doDiagnose: Being, includeSignals?",includeSignals)
		local alreadyAddedNodes = {}
		local function setupBase() 
			local testProposal  = api.type.SimpleProposal.new()
			for i, edgeId in pairs(edgesToRemove) do 
				testProposal.streetProposal.edgesToRemove[i]=edgeId
			end
			for i, nodeId in pairs(nodesToRemove) do  
				testProposal.streetProposal.nodesToRemove[i]=nodeId
			end
			for i, edgeObj in pairs(edgeObjectsToRemove) do 
				testProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj 
			end
			alreadyAddedNodes = {}
			return testProposal
		end
		local testData =  api.engine.util.proposal.makeProposalData(setupBase() , util.initContext())
		--assert(#testData.errorState.messages == 0 and not testData.errorState.critical)
		
		local function toApiNode(node) 
			--if node then 
				return util.newNodeWithPosition(node.comp.position, node.entity)
			--end
		end 
 
		
		local function addEdgeToProposal(testProposal, edge)
			if edge.comp.node0  < 0 and not alreadyAddedNodes[edge.comp.node0] then 
				testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=toApiNode(newNodeMap[edge.comp.node0])
				alreadyAddedNodes[edge.comp.node0] = true
			end 
			if edge.comp.node1 < 0 and not alreadyAddedNodes[edge.comp.node1] then 
				testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=toApiNode(newNodeMap[edge.comp.node1])
				alreadyAddedNodes[edge.comp.node1] = true
			end
			local copiedEdge = toApiEdge(edge, includeSignals)
			
			
			if includeSignals then 
				local newEdgeEntity = -1-#testProposal.streetProposal.edgesToAdd 
				local newObjects = {}
				for i, edgeObj in pairs(copiedEdge.comp.objects) do 
					local edgeObjFull = edgeObjectsToAdd[-edgeObj[1]]
					assert(edgeObjFull.edgeEntity==copiedEdge.entity)
					local copiedEdgeObj = toApiEdgeObj(edgeObjFull)
					copiedEdgeObj.edgeEntity = newEdgeEntity
					testProposal.streetProposal.edgeObjectsToAdd[1+#testProposal.streetProposal.edgeObjectsToAdd]=copiedEdgeObj
					table.insert(newObjects, { -#testProposal.streetProposal.edgeObjectsToAdd, edgeObj[2] })
				end 
				copiedEdge.comp.objects  = newObjects
				copiedEdge.entity = newEdgeEntity
				trace("setting up signals on", newEdgeEntity)
			else 
				assert(#copiedEdge.comp.objects == 0 )
			end 
			testProposal.streetProposal.edgesToAdd[1+#testProposal.streetProposal.edgesToAdd]=copiedEdge
			
			return testProposal
		end
		local foundCritialError = false 
	 
		local testData =  api.engine.util.proposal.makeProposalData(setupBase()  , util.initContext())
		local isError =  #testData.errorState.messages > 0 or testData.errorState.critical
		trace("Setup only base, is error?",isError)
		for i, edge in pairs(edgesToAdd) do
			 --collectgarbage()
			local testProposal = addEdgeToProposal(setupBase(), edge)
			--debugPrint(testProposal)
			local testData =  api.engine.util.proposal.makeProposalData(testProposal , util.initContext())
			local isError =  #testData.errorState.messages > 0 or testData.errorState.critical
			trace("Checking edge ",i," isError=",isError, " isCriticalError=",testData.errorState.critical)
			--[[if #testData.errorState.messages > 0 then 
				debugPrint(testData.errorState.messages)
				debugPrint(testData.collisionInfo.collisionEntities)
				trace("Error message found for edge ",edge.entity)
			end ]]--
			if testData.errorState.critical then 
				foundCritialError = true
				trace("doDiagnose: Critical error found for edge ",edge.entity)
				debugPrint(testProposal)
				local t0 = util.v3(edge.comp.tangent0)
				local t1 = util.v3(edge.comp.tangent1)
				
				local p0 = getNodePosition(edge.comp.node0)
				local p1 = getNodePosition(edge.comp.node1)
				local naturalTangent = p1-p0
				trace("the natural tangent length was",vec3.length(naturalTangent), " vs", vec3.length(t0),vec3.length(t1))
				trace("The angles between tangents were",math.deg(util.signedAngle(t0,t1)), "deg and to naturalTangent was (degrees)",math.deg(util.signedAngle(t0, naturalTangent)), math.deg(util.signedAngle(t1, naturalTangent)))
				for n, node in pairs({edge.comp.node0, edge.comp.node1}) do 
					if node > 0 then 
						local segs = util.getSegmentsForNode(node)
						for i, seg in pairs(segs) do 
							local otherEdge = util.getEdge(seg)
							local otherNode = node == otherEdge.node0 and otherEdge.node1 or otherEdge.node1 
							local otherTangent = util.v3(node == otherEdge.node0 and otherEdge.tangent1 or otherEdge.tangent0)
							local theirNaturalTangent = util.nodePos(otherNode)-util.nodePos(node)
							local ourTangent = n == 1 and t0 or t1 
							local angleToTangent = util.signedAngle(ourTangent, otherTangent)
							local angleToNaturalTangent = util.signedAngle(ourTangent, theirNaturalTangent)
							trace("Found edge",seg,"connected to node",node, " the angle between tangents was(deg)", math.deg(angleToTangent)," angle to natural tangent was ",math.deg(angleToNaturalTangent))
						end 
					end
				end 
				
			end 
		end 
		if not foundCritialError or attemptPartialBuild then 
			trace("Attempting to build more segments")
		
			local ignoredEdges = {}
			local maxI = 1-- #edgesToAdd
			repeat 
				local testProposal = setupBase() 
				for i, edge in pairs(edgesToAdd) do
					--collectgarbage() 
					if not ignoredEdges[i] then 
						addEdgeToProposal(testProposal, edge)
						trace("i=",i,"maxI=",maxI,"i>=maxI=",(i>=maxI))
						if i >= maxI then 
							local testData =  api.engine.util.proposal.makeProposalData(testProposal , util.initContext())
							local isError =  #testData.errorState.messages > 0 or testData.errorState.critical
							trace("Checking edge ",i," isError=",isError, " isCriticalError=",testData.errorState.critical)
							--[[if #testData.errorState.messages > 0 then 
								debugPrint(testData.errorState.messages)
								debugPrint(testData.collisionInfo.collisionEntities)
								trace("Error message found for edge ",edge.entity)
							end ]]--
							if testData.errorState.critical then 
								foundCritialError = true
								--debugPrint(testProposal)
								trace("Second run critical error found for edge ",edge.entity)
								local t0 = util.v3(edge.comp.tangent0)
								local t1 = util.v3(edge.comp.tangent1)
								
								local p0 = getNodePosition(edge.comp.node0)
								local p1 = getNodePosition(edge.comp.node1)
								local naturalTangent = p1-p0
								trace("the natural tangent length was",vec3.length(naturalTangent), " vs", vec3.length(t0),vec3.length(t1))
								trace("The angles between tangents were",math.deg(util.signedAngle(t0,t1)), " and to naturalTangent was ",math.deg(util.signedAngle(t0, naturalTangent)), math.deg(util.signedAngle(t1, naturalTangent)))
								ignoredEdges[i]=true
								break 
								
							end 
						end
					end 
					maxI = math.max(i, maxI)				 				
				end 
			until  maxI == #edgesToAdd
			local testProposal = setupBase() 
			local fullDiagnosticIgnoredEdges = {}
			for i, edge in pairs(edgesToAdd) do
				if not ignoredEdges[i] then 
					addEdgeToProposal(testProposal, edge)
				else 
					table.insert(fullDiagnosticIgnoredEdges, edge)
				end 
			end 
			debugPrint({ignoredEdges=fullDiagnosticIgnoredEdges})
			if util.size(ignoredEdges) == 0 then 
				trace("No critical errors were found") 
				return false 
			end
			local testProposal = setupBase()
			for i, edge in pairs(edgesToAdd) do
				if  not ignoredEdges[i] then 
					addEdgeToProposal(testProposal, edge)
				end 
			end 
			if attemptPartialBuild then 
				assert(not  api.engine.util.proposal.makeProposalData(testProposal, util.initContext()).errorState.critical)
				api.cmd.sendCommand(api.cmd.make.buildProposal(testProposal, util.initContext(), true), function(res, success) 
					trace("Attempt to build interim proposal was",success)
				end)
				error("Partial build") 
				--proposalUtil.addWork(function() error("Partial build") end) -- seems this has to be done in a different frame
			end
			
		end 
		return true
	end
	for i, edgeObj in pairs(edgeObjectsToAdd) do 
		if edgeObj.param ~= 0.5 and edgeObj.edgeEntity <0 then 
			local edge = edgesToAdd[-edgeObj.edgeEntity]
			local p0 = getNodePosition(edge.comp.node0)
			local p1 = getNodePosition(edge.comp.node1)
			if not p0 or not p1 then 
				debugPrint(nodesToAdd)
				debugPrint(edge)
				trace("WARNING! Could not find position, p0=",p0,"p1=",p1)
				local lastNode = allNodesToAdd[#allNodesToAdd] 
				if lastNode.entity == edge.comp.node1 then 
					trace("But I found it in the last node in allNodesToAdd!!") 
					p1 = util.v3(lastNode.comp.position)
				end
				local lastNode = nodesToAdd[#nodesToAdd] 
				if lastNode.entity == edge.comp.node1 then 
					trace("But I found it in the last node in nodesToAdd!!") 
					p1 = util.v3(lastNode.comp.position)
				end
			end
		 
			if util.distance(p0, p1)< 40 then 
				trace("Resetting edge object position for short segment at ",edgeObj.edgeEntity," param was",edgeObj.param)
				edgeObj.param=0.5
			end
		end 
	end 
	local removedEdgeObjectSet = {}
	for i, edgeObj in pairs(edgeObjectsToRemove) do 
		removedEdgeObjectSet[edgeObj]=true
	end 
	
	local retainedObjectsSet = {}
	local alreadySeenEdgeObjects = {}
	for i, edge in pairs(edgesToAdd) do
		for j , edgeObj in pairs(edge.comp.objects) do 
			local edgeObjId = edgeObj[1]
			if alreadySeenEdgeObjects[edgeObjId] then 
				debugPrint(edgesToAdd)
			end 	
			assert(not alreadySeenEdgeObjects[edgeObjId])
			alreadySeenEdgeObjects[edgeObjId]=true
			if edgeObjId < 0 then 
				assert(edgeObjectsToAdd[-edgeObjId].edgeEntity==edge.entity)
			else 
				assert(not removedEdgeObjectSet[edgeObjId])
				retainedObjectsSet[edgeObjId]=true
			end 
		end 
	end 
	for i, edgeId in pairs(edgesToRemove) do
		local edge = util.getEdge(edgeId) 
		for j, edgeObject in pairs(edge.objects) do 
			if edgeObject[2]==api.type.enum.EdgeObjectType.SIGNAL then 
--				assert(removedEdgeObjectSet[edgeObject[1]])
				if not removedEdgeObjectSet[edgeObject[1]] then 
					trace("Remove edgeObject ",edgeObject[1])
					table.insert(edgeObjectsToRemove, edgeObject[1])
					removedEdgeObjectSet[edgeObject[1]]=true
				end 
			else 
				if not removedEdgeObjectSet[edgeObject[1]] or retainedObjectsSet[edgeObject[1]] then 
					debugPrint({edgeObject=edgeObject,edgeId=edgeId,removedEdgeObjectSet=removedEdgeObjectSet,retainedObjectsSet=retainedObjectsSet})
				end 
				assert(removedEdgeObjectSet[edgeObject[1]] or retainedObjectsSet[edgeObject[1]])
			end 			
		end 
	end 
	
	if diagnose then 
		trace("Begin diagnosis 1")
		if not doDiagnose() then 
			trace("Begin diagnosis 2")
			doDiagnose(true)
		end
	end 
	

	
 	
	local bridgeTypeCount = util.size(api.res.bridgeTypeRep.getAll())
	local tunnelTypeCount = util.size(api.res.tunnelTypeRep.getAll())
	for i, edge in pairs(edgesToAdd) do
		local t0 = util.v3(edge.comp.tangent0)
		local t1 = util.v3(edge.comp.tangent1)
		assert(edge.comp.node0~=edge.comp.node1, "Edge had same nodes"..edge.comp.node0.." "..edge.comp.node1.." entity="..edge.entity)
		local p0 = getNodePosition(edge.comp.node0)
		local p1 = getNodePosition(edge.comp.node1)
		if not p0 or not p1 then 
			debugPrint(nodesToAdd)
			debugPrint(edge)
			trace("WARNING! Could not find position, p0=",p0,"p1=",p1)
			local lastNode = allNodesToAdd[#allNodesToAdd] 
			if lastNode.entity == edge.comp.node1 then 
				trace("But I found it in the last node in allNodesToAdd!!") 
				p1 = util.v3(lastNode.comp.position)
			end
			local lastNode = nodesToAdd[#nodesToAdd] 
			if lastNode.entity == edge.comp.node1 then 
				trace("But I found it in the last node in nodesToAdd!!") 
				p1 = util.v3(lastNode.comp.position)
			end
		end
		local lt0 = vec3.length(t0)
		local lt1 = vec3.length(t1)
		local dist = util.distance(p0, p1)
		assert(dist>0, "Zero dist between nodes "..edge.comp.node0.." "..edge.comp.node1.." entity="..edge.entity)
		local tolerance = 0.02*dist
		local angle = math.abs(util.signedAngle(t0, t1))
		local tangentRatio = math.max(math.abs(1-(lt0/lt1)), math.abs(1-(lt1/lt0)))
		local calcLen = util.calculateTangentLength(p0, p1, t0, t1)
		local distToTangent0 =  math.max(math.abs(1-(calcLen/lt0)),math.abs(1-(lt0/calcLen)))
		local distToTangent1 =  math.max(math.abs(1-(calcLen/lt1)),math.abs(1-(lt1/calcLen)))
		local naturalTangent = p1 - p0 
		local angle1 = math.abs(util.signedAngle(t0, naturalTangent))
		local angle2 = math.abs(util.signedAngle(t1, naturalTangent))
		local isOk = true 
		local tryRenormlize = false 
		local connectAngle1 = math.abs(calculateMaxConnectAngle(edge.comp.node0, t0, i))
		local connectAngle2 = math.abs(calculateMaxConnectAngle(edge.comp.node1, t1, i))
		
		if edge.type==1 then --track 
			if connectAngle1 > math.rad(90) then 
				connectAngle1 = math.rad(180)-connectAngle1
			end
			if connectAngle2 > math.rad(90) then 
				connectAngle2 = math.rad(180)-connectAngle2
			end
			if connectAngle1 > math.rad(5) or connectAngle2 > math.rad(5) then 
				trace("WARNING! High connect angle detected", math.deg(connectAngle1), math.deg(connectAngle2))
				isOk = false
			end
		end
		if dist < 4 then 
			trace("WARNING!, short distance ",dist, util.newEdgeToString(edge))
			isOk =false 
		end 
		if lt0~=lt0 or lt1~=lt1 then 
			trace("WARNING!, NAN tangent",lt0,lt1)
			if util.tracelog then 
				debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd})
				error("NaN Tangent")
			end 
		end
		if tangentRatio > 0.1 then 
			trace("WARNING, possible tangent inconsistentcy",lt1,lt0, " true dist was",dist)
			isOk = false
			tryRenormlize = true 
			if util.tracelog then 
				debugPrint(edge)
			end 
		end 
		if angle1 > math.rad(45) or angle2 > math.rad(45) then 
			trace("WARNING! high angle to natural tangent", math.deg(angle1), math.deg(angle2), util.newEdgeToString(edge))
			if angle1 > math.rad(160) and angle2 > math.rad(160)   then
				trace("proposalUtil: Swapping nodes")
				local temp = edge.comp.node1
				edge.comp.node1 = edge.comp.node0
				edge.comp.node0 = temp
			end
			if angle1 > math.rad(160) and angle2 < math.rad(20) then 
				if connectAngle1 > math.rad(20) then 
					trace("Inverting tangent0 as connect angle was",math.deg(connectAngle1))
					util.setTangent(edge.comp.tangent0, -1*util.v3(edge.comp.tangent0))
				else 
					trace("Skipped inverting as the connect angle was only",math.deg(connectAngle1))
				end 
			elseif angle2 > math.rad(160) and angle1 < math.rad(20) then 
				if connectAngle2 > math.rad(20) then 
					trace("Inverting tangent1 as connect angle was",math.deg(connectAngle2))
					util.setTangent(edge.comp.tangent1, -1*util.v3(edge.comp.tangent1))
				else 
					trace("Skipped inverting tangent1 as the connect angle was only",math.deg(connectAngle2))
				end 
			end 
			
			isOk =  false
		end
		if lt0 < dist-tolerance or lt1 < dist-tolerance then 
			trace("WARNING! too short tangent",  lt1,lt0, " true dist was",dist)
			isOk = false
			tryRenormlize = true
		end 
		if distToTangent0 > 0.2 or distToTangent1 > 0.2 then 
			trace("WARNING, unexpected distToTangent",   lt1,lt0, " true dist was",dist, "calculated was ",calcLen)
			isOk = false
		end 
		if angle > math.rad(90) then
			trace("WARNING, unexpected angle, ",math.deg(angle))
			isOk = false
		end
		if not isOk then 
			trace("Possible problem detected with new edge",edge.entity," connecting ",edge.comp.node0," and ",edge.comp.node1," at ",p0.x, p0.y, p0.z, " with ",p1.x, p1.y, p1.z)
		end 
		if (tryRenormlize or util.alwaysCorrectTangentLengths)  then --and not proposalUtil.suppressTangentAlteration
			--local length = math.max(dist,math.max(lt0, lt1))
			--trace("Attempting to fix tangents with length ",calcLen)
			if lt0 > 0 and lt1 > 0 then 
				local shouldRenormalise = true 
				if edge.type == 0 and util.getStreetTypeCategory(edge.streetEdge.streetType)=="highway" then 
					trace("Found highway streettype, tryRenormlize?",tryRenormlize)
					shouldRenormalise = tryRenormlize
				end 
					
				if shouldRenormalise then 
					--trace("Renormalizing tangent for edge",edge.entity,"at i=",i)
					renormalizeTangents(edge, calcLen)
				end
			else 
				trace("WARNING! Zero length tangent detected, attempting to correct")
				if util.tracelog then 	
					--debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd})
					--error("Zero length tangent")
				end 
				util.setTangents(edge, p1-p0)
			end
		end 
		local msg = " edge"..tostring(edge.entity).." type="..tostring(edge.comp.type).." typeIndex="..tostring(edge.comp.typeIndex)
		if edge.comp.type == 0 then 
			assert(edge.comp.typeIndex == -1,msg)
		elseif edge.comp.type == 1 then 
			assert(edge.comp.typeIndex ~= -1 , msg)
			if util.tracelog then assert(edge.comp.typeIndex <= bridgeTypeCount,msg) end
			if string.find(api.res.bridgeTypeRep.getName(edge.comp.typeIndex), "lollo_cement") then 
				edge.comp.typeIndex = api.res.bridgeTypeRep.find("cement.lua")
			end 
			
		else 
			assert( edge.comp.type == 2,msg )
			assert(edge.comp.typeIndex ~= -1,msg)
			if util.tracelog then assert(edge.comp.typeIndex <= tunnelTypeCount,msg) end
		end 
	end 
	if diagnose then 
		trace("Begin diagnosis 2")
		if not doDiagnose() then 
			doDiagnose(true)
		end
	end 
	
	local nodeHashes = {}
	for i, node in pairs(allNodesToAdd) do -- game engine now forbids two nodes with the same position
		 local hash = util.pointHash3d(node.comp.position)
		 if nodeHashes[hash] then 
			if util.positionsEqual(node.comp.position, nodeHashes[hash].comp.position, 0.1) then 
				error(" duplicate position node at"..i.." pos="..nodePosToString(node).." node "..node.entity.." other node "..(nodeHashes[hash] and nodeHashes[hash].entity or ""))
			end 
		 end  
		 nodeHashes[hash]=node 
		 local otherNode = util.getNodeClosestToPosition(node.comp.position)
		 if otherNode and util.positionsEqual(util.nodePos(otherNode), node.comp.position) and not util.contains(nodesToRemove, otherNode) then 
			error("Attempt to build node at "..nodePosToString(node).." for entity "..node.entity..", existing node at this position "..otherNode)
		 end 
		 assert(newNodeToSegmentMap[node.entity]~=nil)
		 assert(#newNodeToSegmentMap[node.entity] > 0)
	end 
	
	-- can only add to proposal when everything is finalized, it seems the underlying object is copied when put on the proposal
	local newProposal  = api.type.SimpleProposal.new()
	local uniquenessCheck = {}
	for i, node in pairs(allNodesToAdd) do
		assert(node.comp.position.x == node.comp.position.x, "NaN coordinate in x")
		assert(node.comp.position.y == node.comp.position.y, "NaN coordinate in y")
		assert(node.comp.position.z == node.comp.position.z, "NaN coordinate in z")
		--assert(util.isValidCoordinate(node.comp.position),"invalid coordinate at "..node.comp.position.x..", "..node.comp.position.y.." for node "..node.entity)
		assert(not uniquenessCheck[node.entity],"failed node uniquenessCheck at "..node.entity.." original node at "..nodePosToString(uniquenessCheck[node.entity]).." this node at="..nodePosToString(node))
		uniquenessCheck[node.entity]=node
		newProposal.streetProposal.nodesToAdd[i]=node 
	end
	for i, edge in pairs(edgesToAdd) do
		--if #edgeObjectsToAdd > 0 then 
			assert(i==-edge.entity,"new edgeId check failed for "..i.." and "..edge.entity) -- apparently this is needed for edge object lookup
		--end
		assert(not uniquenessCheck[edge.entity],"new edgeId failed uniquenessCheck at "..edge.entity)
		assert(edge.type ~= -1, " type not set" )
		if edge.type == 0 then 
			assert(edge.streetEdge.streetType ~= -1, "street type not set")
		else 
			assert(edge.trackEdge.trackType ~= -1, "track type not set")
		end
		uniquenessCheck[edge.entity]=true
		newProposal.streetProposal.edgesToAdd[i]=edge  
	end

	for i, obj in pairs(edgeObjectsToAdd) do
		newProposal.streetProposal.edgeObjectsToAdd[i] = obj
	end
	
	
	for i, edgeId in pairs(edgesToRemove) do
		assert(not util.isFrozenEdge(edgeId), " attempted to remove frozen edge "..edgeId)
		if uniquenessCheck[edgeId] then 
			trace("WARNING! EdgeId",edgeId,"appeared twice in edgesToRemove")
		else 
			uniquenessCheck[edgeId]=true
			newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=edgeId
		end
	end
	for i, nodeId in pairs(nodesToRemove) do 
		assert(not util.isFrozenNode(nodeId), " attempted to remove frozen node "..nodeId)
		assert(not util.isNodeConnectedToFrozenEdge(nodeId), " attempted to remove node for frozen edge "..nodeId)
		assert(not uniquenessCheck[nodeId],"failed nodeId removal uniquenessCheck at "..nodeId)
		--assert(newNodeToSegmentMap[nodeId],"new node referenced "..nodeId)
		--assert(#newNodeToSegmentMap[nodeId]>0,"new node referenced "..nodeId)
		uniquenessCheck[nodeId]=true
		-- validate every node removed has no edges left behind
		for j, edgeId in pairs(util.getSegmentsForNode(nodeId)) do
			if not uniquenessCheck[edgeId] and util.tracelog then 
				debugPrint({edgesToRemove=edgesToRemove, nodesToRemove=nodesToRemove, removedNodeToSegmentMap=removedNodeToSegmentMap})
			end
			assert(uniquenessCheck[edgeId]," attempted to remove "..nodeId.." but it still belonged to "..edgeId)
		end
		newProposal.streetProposal.nodesToRemove[i]=nodeId
	end
	
	if edgeObjectsToRemove then 
		for i, edgeObj in pairs(edgeObjectsToRemove) do 
			newProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj 
		end
	end
	
	trace("Proposal setup complete")
	return newProposal
end


 function proposalUtil.trialBuildBetweenPoints(p0, p1, t0, t1) 
	local entity = api.type.SegmentAndEntity.new()
	local newProposal = api.type.SimpleProposal.new()
	local newNode0 = util.newNodeWithPosition(p0, -1)
	local newNode1 = util.newNodeWithPosition(p1, -2)
	local node0 =  util.getNodeAtPosition(p0) 
	local node1 =  util.getNodeAtPosition(p1)
	entity.type=1
	entity.trackEdge.trackType = api.res.trackTypeRep.find("standard.lua")
	if node0 then 
		newNode0.entity=node0
		if #util.getTrackSegmentsForNode(node0) ==0 then 
			entity.type = 0
			entity.trackEdge.trackType =-1 
			entity.streetEdge = util.getComponent(util.getStreetSegmentsForNode(node0)[1], api.type.ComponentType.BASE_EDGE_STREET)
		end 
	end 
	if node1 then 
		newNode1.entity= node1
		if #util.getTrackSegmentsForNode(node1) ==0 then 
			entity.type = 0
			entity.trackEdge.trackType =-1 
			entity.streetEdge = util.getComponent(util.getStreetSegmentsForNode(node1)[1], api.type.ComponentType.BASE_EDGE_STREET)
		end 
	end 
	

	entity.comp.node0=newNode0.entity
	entity.comp.node1=newNode1.entity
	entity.entity=-3
	if not t0 then 
		t0 = p1-p0
	end 
	
	if not t1 then 
		t1 = p1-p0
	end 
	local length = util.calculateTangentLength(p0, p1, t0, t1)
	if length == 0 or length ~= length then 
		debugPrint({p0=p0,p1=p1,t0=t0,t1=t1})
		error("Zero or NaN length specified")
	end 
	t0 = length*vec3.normalize(t0)
	t1 = length*vec3.normalize(t1)
	
	util.setTangent(entity.comp.tangent0, t0  )
	util.setTangent(entity.comp.tangent1, t1   )
	if newNode0.entity < 0 then 
		newProposal.streetProposal.nodesToAdd[1]=newNode0
	end 
	if newNode1.entity < 0 then 
		newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode1
	end 
	newProposal.streetProposal.edgesToAdd[1]=entity
	trace("trialBuildBetweenPoints: about to make proposal data")
	--debugPrint(newProposal)
	local testResult = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	local isError =  #testResult.errorState.messages > 0 or testResult.errorState.critical
	if util.tracelog and testResult.errorState.critical then
		trace("trialBuildBetweenPoints: Unexpected critical error found ")
		debugPrint({newProposal=newProposal})
	--	error("trialBuildBetweenPoints: Unexpected critical error found ")
		
		--assert(not testResult.errorState.critical)
	end
	--trace("trialBuildBetweenPoints: constructed proposal, is error?",isError)

	local collisionEntitySet = {}
	for i, entity in pairs(testResult.collisionInfo.collisionEntities) do 
		if not collisionEntitySet[entity.entity] then 
			collisionEntitySet[entity.entity]=true 
		end 
	end 
	local hasConstructionCollision = false 
	for collisionEntity, bool in pairs(collisionEntitySet) do
		if util.isConstruction(collisionEntity) then 
			hasConstructionCollision = true 
		end 
	end 
	--debugPrint(testResult.collisionInfo)
	--debugPrint(testResult.errorState)
	
	return {
		isError = isError, 
		collisionEntities = testResult.collisionInfo.collisionEntities,
		testResult = testResult,-- hold a reference to this anyway to prevent gc of the children
		hasConstructionCollision = hasConstructionCollision,
	}
end

function proposalUtil.trialBuildStraightLine(p0, t0, dist) 
	if type(p0) == "number" then
		p0 = util.nodePos(p0)
	end 
	if not dist then 
		dist = 40 
	end 
	if not t0 then 
		local node0 =  util.getNodeAtPosition(p0) 
		t0 = util.getDeadEndNodeDetails(node0).tangent 
	end 	
	local p1 = p0 + dist*vec3.normalize(t0)
	return 	proposalUtil.trialBuildBetweenPoints(p0, p1, t0, t0) 
end
function proposalUtil.trialBuildFromDeadEndNode(node, dist) 
	if not dist then dist = 40 end 
	local details = util.getDeadEndNodeDetails(node)
	
	return proposalUtil.trialBuildStraightLine(details.nodePos, details.tangent, dist)
end 
function proposalUtil.deconflictEdges(edges, height, connectedEdges) 
	 


	local nextNodeId = -1000
	
	local function getNextNodeId() 
		nextNodeId = nextNodeId - 1
		return nextNodeId
	end
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	local newNodeMap = {}
	local replacedEdgesMap = {}
	local oldToNewNodeMap = {}
	local newNode2SegMap = {}
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
 
	local function addNode(newNode, oldNode) 
		table.insert(nodesToAdd, newNode)
		newNodeMap[newNode.entity]=newNode
		oldToNewNodeMap[oldNode]=newNode
		newNode2SegMap[newNode.entity]={} 
	end 
	local function nodePos(node) 
		if node > 0 then 
			return util.nodePos(node) 
		else 
			return util.v3(newNodeMap[node].comp.position)
		end 
	end	
	  
	local function setHeightOnNode(node, z , forbidRecurse)
		local nodeP = util.v3(nodePos(node), true)
		if   not oldToNewNodeMap[node] then  
			local segs = util.getSegmentsForNode(node)
			local canReplace = true 
			for __, seg in pairs(segs) do 
				if connectedEdges[seg] or util.isFrozenEdge(seg) or util.edgeHasTpLinks(seg) then 	
					canReplace = false 
					break 
				end
			end 
			if not canReplace then 
				return 
			end
		
			nodeP.z = math.min(z, nodeP.z)
			trace("Reducing height offset of node ",node," with height",nodeP.z, " targetHeight was",z)
			local newNode = util.newNodeWithPosition(nodeP, getNextNodeId())
			addNode(newNode, node)
			
			for __, seg in pairs(segs) do 
				if not replacedEdgesMap[seg] then 
					local replacement = util.copyExistingEdge(seg, nextEdgeId() )
					table.insert(edgesToAdd, replacement)
					table.insert(edgesToRemove, seg)
					replacedEdgesMap[seg] = replacement
				end 
				
				local replacement = replacedEdgesMap[seg]
				if not util.contains(newNode2SegMap[newNode.entity], replacement) then 
					table.insert(newNode2SegMap[newNode.entity], replacement) 
				end
				local otherNode
				if replacement.comp.node0 == node then 
					replacement.comp.node0 = newNode.entity
					otherNode = replacement.comp.node1 
				else 
					replacement.comp.node1 = newNode.entity
					otherNode = replacement.comp.node0 
				end 
				if edges[seg] then 
					replacement.comp.type = 2
					replacement.comp.typeIndex = replacement.type == 0 and api.res.tunnelTypeRep.find("street_old.lua") or api.res.tunnelTypeRep.find("railroad_old.lua")
				elseif otherNode > 0 and not forbidRecurse then 
					setHeightOnNode(otherNode, height - 7.5, true)
				end 
			end 
		end 
	end 
		
	local function replaceEdge(edgeId) 
		local edge = util.getEdge(edgeId)
		trace("Replacing edge",edgeId," nodes were",edge.node0, edge.node1)
		setHeightOnNode(edge.node0, height - 15)
		setHeightOnNode(edge.node1, height - 15)
	end
	for edge, bool in pairs(edges) do  
		local doubleTrackEdge = util.findDoubleTrackEdge(edge)
		if doubleTrackEdge and not edges[doubleTrackEdge] then 
			edges[doubleTrackEdge]=true 
		end
	end
	for edge, bool in pairs(edges) do  
		replaceEdge(edge) 
	end
	for i , newNode in pairs(nodesToAdd) do 
		local node = newNode.entity
		if #newNode2SegMap[node]==2 then 
			local leftEdge = newNode2SegMap[node][1]
			local rightEdge = newNode2SegMap[node][2]
			local leftNode0 = leftEdge.comp.node0 == node
			local rightNode0 = rightEdge.comp.node0 == node
			local leftNodePos = nodePos(leftNode0 and leftEdge.comp.node1 or leftEdge.comp.node0)
			local rightNodePos = nodePos(rightNode0 and rightEdge.comp.node1 or rightEdge.comp.node0)
			local midNodePos = nodePos(node)
			local leftTangent = util.v3(leftNode0 and leftEdge.comp.tangent0 or leftEdge.comp.tangent1)
			local rightTangent = util.v3(rightNode0 and rightEdge.comp.tangent0 or rightEdge.comp.tangent1)
			
			leftTangent.z = midNodePos.z - leftNodePos.z 
			rightTangent.z = rightNodePos.z - midNodePos.z
		 
			local len1 = vec3.length(leftTangent)
			local len2 = vec3.length(rightTangent)
			local t = vec3.normalize(leftTangent)
			local t2 = vec3.normalize(rightTangent)
			local weightedAverage = (len1*t.z + len2*t2.z)/(len1+len2)
			local leftZTangent = leftNode0 and -weightedAverage*len1 or weightedAverage*len1
			local rightZTangent = rightNode0 and  weightedAverage*len2 or -weightedAverage*len2
			trace("The leftZTangent was",leftZTangent," the rightZTangent was",rightZTangent)
			if leftNode0 then 
				leftEdge.comp.tangent0.z = leftZTangent
			else 
				leftEdge.comp.tangent1.z = leftZTangent
			end 
			
			if rightNode0 then 
				rightEdge.comp.tangent0.z = rightZTangent
			else 
				rightEdge.comp.tangent1.z = rightZTangent
			end 
			
		end 
		
		
		
	
	end 
	xpcall(function() -- if we try to remove frozen edge. Not worth filtering as likely to break the route
		local newProposal = routeBuilder.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
		local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
		trace(" About to sent replace edges")
		api.cmd.sendCommand(build, function(res, success) 
			trace(" attempt command result was", tostring(success))
			util.clearCacheNode2SegMaps()
			if not success and util.tracelog then 
				debugPrint(res) 
			end 
		end)
	end, 
	err)
end 

local function getBoxForNewEntity(entity, nodePosFn) 
	local p0 = nodePosFn(entity.comp.node0)
	local p1 = nodePosFn(entity.comp.node1)
	local edgeWidth 
	if entity.type == 1 then 
		edgeWidth = 5
	else 
		edgeWidth = util.getStreetWidth(entity.streetEdge.streetType)
	end 
	local margin = edgeWidth/2
	local zMargin = 10 
	return { 
		bbox = {
			min = {
				x = math.min(p0.x-margin, p1.x-margin),
				y = math.min(p0.y-margin, p1.y-margin),
				z = math.min(p0.z-zMargin, p1.z-zMargin)
			},
			max = { 
				x = math.max(p0.x+margin, p1.x+margin),
				y = math.max(p0.y+margin, p1.y+margin),
				z = math.max(p0.z+zMargin, p1.z+zMargin)
			}	
		}
	}
end 

local function getEdgeWidth(entity)
	if entity.type == 1 then 
		return 5 -- track 
	else 
		return util.getStreetWidth(entity.streetEdge.streetType)
	end 
end 

function proposalUtil.attemptDeconfliction(newProposal)	
	util.validateProposal(newProposal)
	
	--[[if #newProposal.streetProposal.edgesToAdd > 200 then --try to avoid unexplained crashes
		trace("attemptDeconfliction aborting due to a large number of edges",#newProposal.streetProposal.edgesToAdd )
		return newProposal
	end]]--
	trace("Attempt deconfliction, about to setup proposal data")
	local testData =  api.engine.util.proposal.makeProposalData(newProposal , util.initContext())
	if testData.errorState.critical then 
		trace("WARNING! proposalUtil.attemptDeconfliction: found critical error, unable to continue")
		if util.tracelog then 
			debugPrint(newProposal)
		end 
		return newProposal
	end 
	if proposalUtil.areIgnorableErrors(testData.errorState) then 
		return newProposal
	end 	
	profiler.beginFunction("proposalUtil.attemptDeconfliction")
	local edgesToAdd = util.shallowClone(newProposal.streetProposal.edgesToAdd)
	local nodesToAdd = util.shallowClone(newProposal.streetProposal.nodesToAdd)
	local edgeObjectsToAdd = util.shallowClone(newProposal.streetProposal.edgeObjectsToAdd)
	local edgeObjectsToRemove = util.shallowClone(newProposal.streetProposal.edgeObjectsToRemove)
	local edgesToRemove = util.shallowClone(newProposal.streetProposal.edgesToRemove)
	local nodesToRemove = util.shallowClone(newProposal.streetProposal.nodesToRemove)
	local constructionsToAdd = util.shallowClone(newProposal.constructionsToAdd)
	local constructionsToRemove = util.shallowClone(newProposal.constructionsToRemove)
	trace("proposalUtil.attemptDeconfliction, there were",#edgesToAdd,"edgeToAdd",#edgesToRemove,"edgesToRemove, critical error?",testData.errorState.critical)
	local newNodeMap = {}
	local minimumNodeEntity = -1000 -- N.B. node entities must be distinct from edge entities, so allow a gap 
	for i, node in pairs(nodesToAdd) do
		newNodeMap[node.entity]=node
		minimumNodeEntity = math.min(minimumNodeEntity, node.entity)
	end 
	
	local function nodePos(node) 
		if node > 0 then 
			return util.nodePos(node)
		else 
			return util.v3(newNodeMap[node].comp.position)
		end 
	end 
	
	local function toBasicEdge(edge)
		return {
			t0 = util.v3(edge.comp.tangent0),
			t1 = util.v3(edge.comp.tangent1),
			p0 = nodePos(edge.comp.node0),
			p1 = nodePos(edge.comp.node1)		
		}
	
	end 
	
	local oldNodesReferenced = {}
	local newNodeToSegmentMap = {}
	local function recordNodeReferenced(nodeId , newEdgeIdx)
		if nodeId > 0 then
			if not oldNodesReferenced[nodeId] then 
				oldNodesReferenced[nodeId] = {}
			end
			table.insert(oldNodesReferenced[nodeId], newEdgeIdx)
		else 
			if not newNodeToSegmentMap[nodeId] then 
				newNodeToSegmentMap[nodeId]={}
			end 
			table.insert(newNodeToSegmentMap[nodeId], newEdgeIdx)
		end 
	end
	
	local function checkOrphanedNodes(testProposal) 
		for node, edges in pairs(oldNodesReferenced) do 
			local segs = util.getSegmentsForNode(node)
			
			local referenceCount = #segs
			if debugResults then 
				trace("Checking for orphaned node",node)
			end 
			for i, seg in pairs(segs) do 
				if util.contains(testProposal.streetProposal.edgesToRemove, seg) then 
					referenceCount = referenceCount - 1
				end 
			end 
			if debugResults then 
				trace("After inspecting the removed the referenceCount was",referenceCount)
			end
			for i, newEdge in pairs(testProposal.streetProposal.edgesToAdd) do 
				if newEdge.comp.node0 == node or newEdge.comp.node1 == node then 
					referenceCount = referenceCount + 1
				end 
			end 
			if debugResults then 
				trace("After inspecting the re-referenced nodes the count was",referenceCount)
			end 
			assert(referenceCount>=0)
			if referenceCount == 0 then 
				trace("Removing the node reference",node)
				testProposal.streetProposal.nodesToRemove[1+#testProposal.streetProposal.nodesToRemove]=node
			end 
		end 
		
		return testProposal
	end 	
	
	local function rebuildNewNodeToSegmentMap() 	
		newNodeToSegmentMap ={}
		for i, edge in pairs(edgesToAdd) do
			recordNodeReferenced(edge.comp.node0, i)
			recordNodeReferenced(edge.comp.node1, i)
		end
	end 
	rebuildNewNodeToSegmentMap()
	
	local function isEdgeNodesReferenced(edgeId) 
		local edge = util.getEdge(edgeId) 
		for i, node in pairs({edge.node0, edge.node1}) do 
			if oldNodesReferenced[node] then 
				return true 
			end 
		end 
	end 
	
	local originalNumMessages = #testData.errorState.messages
	if util.contains(testData.errorState.messages, "Collision") then 
		trace("proposalUtil.attemptDeconfliction: found collision")
		local collisionEntitySet = {}
		for i, entity in pairs(testData.collisionInfo.collisionEntities)  do 
			 
			if entity.entity > 0 and util.getEdge(entity.entity) then 
				collisionEntitySet[entity.entity]=true 
			end 
 		
		end 
		local collisionBoxes = {}
		for entity, bool in pairs(collisionEntitySet) do 
			table.insert(collisionBoxes, util.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME))
		end 
		if util.tracelog then 
			assert(#collisionBoxes == util.size(collisionEntitySet))
		end 
		
		local alreadyAddedNodes = {}
		local function setupBase() 
			local testProposal  = api.type.SimpleProposal.new()
			for i, edgeId in pairs(edgesToRemove) do 
				testProposal.streetProposal.edgesToRemove[i]=edgeId
			end
			for i, nodeId in pairs(nodesToRemove) do  
				testProposal.streetProposal.nodesToRemove[i]=nodeId
			end
			for i, edgeObj in pairs(edgeObjectsToRemove) do 
				testProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj 
			end
			alreadyAddedNodes = {}
			return testProposal
		end
		--local testData =  api.engine.util.proposal.makeProposalData(checkOrphanedNodes(setupBase()) , util.initContext())
		--assert(#testData.errorState.messages == 0 and not testData.errorState.critical)
		
		local function toApiNode(node) 
			--if node then 
				return util.newNodeWithPosition(node.comp.position, node.entity)
			--end
		end 
 
		
		local function addEdgeToProposal(testProposal, edge)
			if edge.comp.node0  < 0 and not alreadyAddedNodes[edge.comp.node0] then 
				testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=toApiNode(newNodeMap[edge.comp.node0])
				alreadyAddedNodes[edge.comp.node0] = true
			end 
			if edge.comp.node1 < 0 and not alreadyAddedNodes[edge.comp.node1] then 
				testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=toApiNode(newNodeMap[edge.comp.node1])
				alreadyAddedNodes[edge.comp.node1] = true
			end
			local copiedEdge = toApiEdge(edge, includeSignals)
			
			
			if includeSignals then 
				local newEdgeEntity = -1-#testProposal.streetProposal.edgesToAdd 
				local newObjects = {}
				for i, edgeObj in pairs(copiedEdge.comp.objects) do 
					local edgeObjFull = edgeObjectsToAdd[-edgeObj[1]]
					assert(edgeObjFull.edgeEntity==copiedEdge.entity)
					local copiedEdgeObj = toApiEdgeObj(edgeObjFull)
					copiedEdgeObj.edgeEntity = newEdgeEntity
					testProposal.streetProposal.edgeObjectsToAdd[1+#testProposal.streetProposal.edgeObjectsToAdd]=copiedEdgeObj
					table.insert(newObjects, { -#testProposal.streetProposal.edgeObjectsToAdd, edgeObj[2] })
				end 
				copiedEdge.comp.objects  = newObjects
				copiedEdge.entity = newEdgeEntity
				trace("setting up signals on", newEdgeEntity)
			else 
				assert(#copiedEdge.comp.objects == 0 )
			end 
			testProposal.streetProposal.edgesToAdd[1+#testProposal.streetProposal.edgesToAdd]=copiedEdge
			
			return testProposal
		end
		local foundCritialError = false 
	 
		local testData =  api.engine.util.proposal.makeProposalData(checkOrphanedNodes(setupBase())  , util.initContext())
		local isError =  not proposalUtil.areIgnorableErrors(testData.errorState)
		trace("Setup only base, is error?",isError)
		local wasCleanedUp = false 
		local edgesToInspect = {}
		for i, edge in pairs(edgesToAdd) do 
			local ourBox = getBoxForNewEntity(edge, nodePos)
			for j, theirBox in pairs(collisionBoxes) do 
				if util.boxesIntersect(ourBox.bbox, theirBox.bbox) then 
					table.insert(edgesToInspect, edge)
					break
				end 
			end 
		end 
		trace("Inspecting",#edgesToInspect,"of",#edgesToAdd)
		local startTime = os.clock()
		for i = 1, #edgesToInspect do
			local timeSinceStart = os.clock()-startTime
			local edge = edgesToInspect[i]
			--collectgarbage()
			trace("About to create proposal for edge at",i,"timeSinceStart=",timeSinceStart)
			if timeSinceStart > 60 then 
				trace("Aborting due to excessive time taken")
				break
			end 
			local testProposal = checkOrphanedNodes( addEdgeToProposal(setupBase(), edge))
			if wasCleanedUp and util.tracelog then 
				--debugPrint({testProposal=testProposal})
			end 
			trace("About to setup proposal data for edge",i)
			
			local testData =  api.engine.util.proposal.makeProposalData(testProposal , util.initContext())
			local isError = not  proposalUtil.areIgnorableErrors(testData.errorState)
			trace("Checking edge ",i," isError=",isError, " isCriticalError=",testData.errorState.critical)
			if util.tracelog then 
				--debugPrint({collisionInfo=testData.collisionInfo})
			end 
			if testData.errorState.critical then 
				trace("WARNING! Critical error found, aborting")
				if util.tracelog then 
					debugPrint({testProposal=testProposal, errorState=testData.errorState})
					trace("WARNING! Unexpected critical error")
--					error("Unexpected critical error")
				end 
				profiler.endFunction("proposalUtil.attemptDeconfliction")
				return newProposal 
			end 
			
			if util.contains(testData.errorState.messages, "Collision") then 
				local originalAddedNodeCount = #nodesToAdd
				local originalRemovedEdgesCount = #edgesToRemove
				local collisionEntities = testData.collisionInfo.collisionEntities 
				local otherEdges = {}
				for i, entity in pairs(collisionEntities) do 
					trace("Inspecting collisionEntity",entity.entity)
					if entity.entity > 0 and util.getEdge(entity.entity) then 
						otherEdges[entity.entity]=true 
					end 
				end 
				local existingEdgesToAdd = {}
				local solutions = {}  
				for otherEdge , bool in pairs(otherEdges) do 
					local minDist = math.max(util.getEdgeWidth(otherEdge), getEdgeWidth(edge))
					if not util.isFrozenEdge(otherEdge) and not util.contains(edgesToRemove, otherEdge) and #util.getEdge(otherEdge).objects == 0 and util.isDeadEndEdgeNotIndustry(otherEdge) and not util.edgeHasTpLinks(otherEdge) and not isEdgeNodesReferenced(otherEdge) and not util.isTrackEdge(otherEdge) then 
						trace("Straigh up removing the other edge",otherEdge)
						table.insert(edgesToRemove, otherEdge)
						local edge = util.getEdge(otherEdge)
						for i, node in pairs({edge.node0, edge.node1}) do 
							if #util.getSegmentsForNode(node) == 1 then 
								table.insert(nodesToRemove, node)
							end 
						end 
					else 
						local solution = util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(otherEdge, toBasicEdge(edge))
						if solution and solution.solutionConverged and not util.isFrozenEdge(otherEdge) and not util.contains(edgesToRemove, otherEdge)  then 
							solution.otherEdge = otherEdge 
							for i, node in pairs({edge.comp.node0, edge.comp.node1}) do
								if node < 0 or not util.isNodeConnectedToFrozenEdge(node) then 
									local distance = util.distance(nodePos(node), solution.c)
									trace("Inspecting the distance to the next node, distance was",distance,"at",node,"c=",solution.c.x,solution.c.y,"against minDist=",minDist)
									local deltaZ = nodePos(node).z - solution.existingEdgeSolution.p1.z 
									if distance < minDist and distance < 0.5*util.distance(nodePos(edge.comp.node0),nodePos(edge.comp.node1)) and math.abs(deltaZ) < 5 then 
										trace("Detected short distance,using node solution")
										solution.isOurNodeSolution = true 
										solution.ourNode = node 
										break
									end 
								end
							end 
							if not solution.isOurNodeSolution then 
								local edgeFull = util.getEdge(otherEdge)
								for i, node in pairs({edgeFull.node0, edgeFull.node1}) do 
									if not util.isNodeConnectedToFrozenEdge(node) then 
										local distance = util.distance(nodePos(node), solution.c)
										trace("Inspecting the distance to the next node, distance was",distance,"at",node,"c=",solution.c.x,solution.c.y,"against minDist=",minDist)
										if distance < minDist then 
											solution.theirNode = node
											solution.isNodeSolution = true 
											break
										end 
									end 
								end 
							end 
							
							
							table.insert(solutions, solution)
						elseif not util.isFrozenEdge(otherEdge) then 
							trace("WARNING! No solution found for ",otherEdge)
							local edgeFull = util.getEdge(otherEdge)
							local options = {}
							for i, node in pairs({edgeFull.node0, edgeFull.node1}) do 
								local p0 = util.nodePos(node)
								local solution = util.solveForPosition(p0, toBasicEdge(edge) )
								local p1 = solution.p1 
								local nodeSolution =  { } 
								nodeSolution.dist =  util.distance(p0, p1)
								nodeSolution.deltaZ = p1.z - p0.z
								nodeSolution.newEdgeSolution = solution 
								nodeSolution.c = p1 
								nodeSolution.theirNode = node
								nodeSolution.isNodeSolution = true 
								if not util.isNodeConnectedToFrozenEdge(node) and #util.getSegmentsForNode(node) <= 2 then 
									table.insert(options,nodeSolution)
								end
							end  
							if #options > 0 then 
								local nodeSolution = util.evaluateWinnerFromSingleScore(options, function(solution) return solution.dist end)
								trace("Found nodeSolution at a dist",nodeSolution.dist)
								if nodeSolution.dist < 5 and math.abs(nodeSolution.deltaZ) < 5 then 
									table.insert(solutions, nodeSolution)
								end 
							end
						end
					end 
				end 
				  
				
				solutions = util.evaluateAndSortFromSingleScore(solutions, function(solution) 
					return vec2.distance(nodePos(edge.comp.node0), solution.c)
				end)
				local currentEdge = edge
				local firstEdge
				local replacedEdge 
				local newEdgesToAdd = {}
				local tempNodeToSegMap = {}
				local countGradeCrossings = 0
				local alreadyHandled = {}
				for j, solution in pairs(solutions) do  
					if alreadyHandled[solution.otherEdge] then 
						trace("Skipping",solution.otherEdge,"as already handled")
						goto continue 
					end
					if solution.isNodeSolution then 
						local isRailroadCrossing = #util.getStreetSegmentsForNode(solution.theirNode)>0 and currentEdge.type==1 or #util.getTrackSegmentsForNode(solution.theirNode)>0 and currentEdge.type==0
						trace("Setting up nodeSolution at",solution.theirNode,"isRailroadCrossing?",isRailroadCrossing)
						local newEdge1 = util.copySegmentAndEntity(currentEdge, currentEdge.entity)
						local isFirst = firstEdge == nil
						if isFirst then 
							firstEdge = newEdge1
						else 
							newEdge1 = currentEdge
						end						
						local newEdge2 = util.copySegmentAndEntity(currentEdge, -1-#edgesToAdd-#newEdgesToAdd)
						newEdge2.comp.objects = {}
						table.insert(newEdgesToAdd, newEdge2)
						trace("attemptDeconfliction: created new edge  with entities", newEdge2.entity)
						currentEdge = newEdge2
						newEdge1.comp.node1 = solution.theirNode 
						newEdge2.comp.node0 = solution.theirNode 
						local ourSolution = solution.newEdgeSolution
						util.setTangent(newEdge1.comp.tangent0, ourSolution.t0)
						util.setTangent(newEdge1.comp.tangent1, ourSolution.t1)
						util.setTangent(newEdge2.comp.tangent0, ourSolution.t2)
						util.setTangent(newEdge2.comp.tangent1, ourSolution.t3)
						for i, seg in pairs(util.getSegmentsForNode(solution.theirNode)) do 
							alreadyHandled[seg]=true 							
						end 
						if isRailroadCrossing then -- can cause game crash if build railroad crossing too close without replacing other
							trace("Detected railroad crossing, inspecting")
							for i, seg in pairs(util.getSegmentsForNode(solution.theirNode)) do 
								local edge = util.getEdge(seg)
								local otherNode = edge.node0 == solution.theirNode and edge.node1 or edge.node0
								if util.isRailroadCrossing(otherNode) and not util.contains(edgesToRemove, seg) then 
									trace("Detected other railroad crossing on ",otherNode,"adjusting, removing",seg)
									table.insert(edgesToRemove, seg)
									table.insert(newEdgesToAdd, util.copyExistingEdge(seg, -1-#edgesToAdd-#newEdgesToAdd))
								end 
							end 
						end 
						
						
						if util.tracelog then 
							debugPrint({newEdge1 = newEdge1, newEdge2 = newEdge2})
						end
						goto continue 
					end 
					if solution.isOurNodeSolution then 
						trace("Setting up  OurNodeSolution")
						local theirSolution = solution.existingEdgeSolution	
						local otherEdge = solution.otherEdge						
						local newEdge3 = util.copyExistingEdge(otherEdge, -1-#edgesToAdd-#newEdgesToAdd)
						table.insert(newEdgesToAdd, newEdge3)
						local newEdge4 = util.copyExistingEdge(otherEdge, -1-#edgesToAdd-#newEdgesToAdd)
						newEdge4.comp.objects = {}
						table.insert(newEdgesToAdd, newEdge4) 
						table.insert(edgesToRemove, otherEdge)
						alreadyHandled[otherEdge]=true
						trace("attemptDeconfliction: created new edges with entities", newEdge3.entity,newEdge4.entity,"removing",otherEdge)
						newEdge3.comp.node1 = solution.ourNode
						newEdge4.comp.node0 = solution.ourNode
						  
						util.setTangent(newEdge3.comp.tangent0, theirSolution.t0)
						util.setTangent(newEdge3.comp.tangent1, theirSolution.t1)
						util.setTangent(newEdge4.comp.tangent0, theirSolution.t2)
						util.setTangent(newEdge4.comp.tangent1, theirSolution.t3)
						goto continue 
					end 
					
					local otherEdge = solution.otherEdge
					trace("Found collision with",otherEdge,"found solution?",solution)
					
					solution = util.checkAndFullSolveForCollisionBetweenExistingAndProposedEdge(otherEdge, toBasicEdge(currentEdge)) -- need to resolve here because we may have just changed
					if not solution or not solution.solutionConverged then 
						trace("WARNING! Second solve found no solution")
						goto continue 
					end
					local theirSolution = solution.existingEdgeSolution
					local ourSolution = solution.newEdgeSolution
					
					local deltaZ = ourSolution.p1.z - theirSolution.p1.z 
					local crossingAngle = util.signedAngle(ourSolution.t1, theirSolution.t1)
					
					local canReplace = #util.getEdge(otherEdge).objects == 0 or util.getTrackEdge(otherEdge)
					
					canReplace = canReplace and math.abs(crossingAngle) > math.rad(20) and math.abs(crossingAngle)< math.rad(180-20)
					if util.getTrackEdge(otherEdge) and edge.type == 1 then -- for now explicitly disallow track to track, this can have unintended side effects
						canReplace = false 
						trace("Suppressing can replace for track to track")
					end 	 			
					trace("the deltaz was",deltaZ,"the crossingAngle was",math.deg(crossingAngle),"canReplace?",canReplace)
					local function splitAndCombine()
						if not canReplace then 
							return 
						end
						local newEdge1 = util.copySegmentAndEntity(currentEdge, currentEdge.entity)
						local isFirst = firstEdge == nil
						if isFirst then 
							firstEdge = newEdge1
						else 
							newEdge1 = currentEdge
						end						
						local newEdge2 = util.copySegmentAndEntity(currentEdge, -1-#edgesToAdd-#newEdgesToAdd)
						newEdge2.comp.objects = {}
						table.insert(newEdgesToAdd, newEdge2)
						currentEdge = newEdge2
						local newEdge3 = util.copyExistingEdge(otherEdge, -1-#edgesToAdd-#newEdgesToAdd)
						table.insert(newEdgesToAdd, newEdge3)
						local newEdge4 = util.copyExistingEdge(otherEdge, -1-#edgesToAdd-#newEdgesToAdd)
						newEdge4.comp.objects = {}
						table.insert(newEdgesToAdd, newEdge4)
						trace("attemptDeconfliction: created new edges with entities",newEdge2.entity,newEdge3.entity,newEdge4.entity)
						local newP = 0.5*(ourSolution.p1 + theirSolution.p1)
						if not isFirst then 
							local lastNode = nodesToAdd[#nodesToAdd]
							local dist = util.distance(newP, lastNode.comp.position)
							trace("j=",j,"dist to last node was", dist)
							if dist < 10 then 
								local averageHeight = (lastNode.comp.position.z  + newP.z)/2
								newP.z = averageHeight
								lastNode.comp.position.z = averageHeight
								trace("Clamping the height to ",averageHeight)
							end
						end 
						
						local newNode = util.newNodeWithPosition(newP, minimumNodeEntity-1-#nodesToAdd)
						trace("attemptDeconfliction: placing newNode at",newP.x,newP.y,newP.z,"the deltaZ was",deltaZ,"removing",otherEdge)
						tempNodeToSegMap[newNode.entity]={}
						for i = 1, 4 do 
							local idx = #newEdgesToAdd-3 + i 
							trace("Inserting tempNodeToSegMap for ",newNode.entity,"idx=",idx)
							table.insert(tempNodeToSegMap[newNode.entity], idx)
						end 
						table.insert(edgesToRemove, otherEdge)
						alreadyHandled[otherEdge]=true
						table.insert(nodesToAdd, newNode)
						countGradeCrossings = countGradeCrossings + 1
						assert(not newNodeMap[newNode.entity],"Node"..tostring(newNode.entity).."Already found in map!")
						newNodeMap[newNode.entity]=newNode
						newEdge1.comp.node1 = newNode.entity 
						newEdge2.comp.node0 = newNode.entity 
						newEdge3.comp.node1 = newNode.entity 
						newEdge4.comp.node0 = newNode.entity 
						
						util.setTangent(newEdge1.comp.tangent0, ourSolution.t0)
						util.setTangent(newEdge1.comp.tangent1, ourSolution.t1)
						util.setTangent(newEdge2.comp.tangent0, ourSolution.t2)
						util.setTangent(newEdge2.comp.tangent1, ourSolution.t3)
						
						util.setTangent(newEdge3.comp.tangent0, theirSolution.t0)
						util.setTangent(newEdge3.comp.tangent1, theirSolution.t1)
						util.setTangent(newEdge4.comp.tangent0, theirSolution.t2)
						util.setTangent(newEdge4.comp.tangent1, theirSolution.t3)
					end
					if math.abs(deltaZ) < 5 and canReplace then  
						splitAndCombine()
					else 
						trace("Could not replace",solution.otherEdge,"checking zoffset options,deltaZ=",deltaZ)
						local edgeTypeChanged = false 
						if deltaZ > 0 then 
							
							if currentEdge.comp.type == 0 then 
								if not firstEdge then
									currentEdge = util.copySegmentAndEntity(currentEdge, currentEdge.entity)
								end
								currentEdge.comp.type = 1
								currentEdge.comp.typeIndex = proposalUtil.getBridgeType()
								edgeTypeChanged = true 
							end 
							
						else 
							if currentEdge.comp.type == 0 then 
								if not firstEdge then -- copy in case we want to roll back
									currentEdge = util.copySegmentAndEntity(currentEdge, currentEdge.entity)
								end 
								proposalUtil.setTunnel(currentEdge) 
								edgeTypeChanged = true 
							end 
						end 
						trace("About to setup test data")
						
						local testData =  api.engine.util.proposal.makeProposalData(checkOrphanedNodes( addEdgeToProposal(setupBase(), currentEdge)) , util.initContext())
						if not proposalUtil.areIgnorableErrors(testData.errorState) then  
							trace("Error was not resolved by changin type, atttempting to do something else")
							local wasFixed = false 
							local p0 = nodePos(currentEdge.comp.node0)
							local p1 = nodePos(currentEdge.comp.node1)
							local originalZ = { p0.z, p1.z } 
							local sign = deltaZ > 0 and 1 or -1
							local function getSegmentCountForNode(nodeId)
								if nodeId > 0 then return 0 end -- Or handle positive IDs if needed
								
								local count = 0 
								-- 1. Check the main map (committed edges)
								if newNodeToSegmentMap[nodeId] then
									count = count + #newNodeToSegmentMap[nodeId]
								end 
								-- 2. Check the temporary map (created during splitAndCombine)
								if tempNodeToSegMap[nodeId] then
									count = count + #tempNodeToSegMap[nodeId]
								end 
								
								return count
							end
							for offset = 4, 16, 4 do 
								
								for m, node in pairs({currentEdge.comp.node0, currentEdge.comp.node1}) do 
									if node < 0 and getSegmentCountForNode(node) > 1 then -- cannot do for dead ends 
										local newNode = newNodeMap[node]
										newNode.comp.position.z = originalZ[m] + sign*offset
										trace("Attempting to change z to ",newNode.comp.position.z)
										if newNodeToSegmentMap[node] then 
											for n, otherEdgeIdx in pairs(newNodeToSegmentMap[node]) do
												local otherEdge = edgesToAdd[otherEdgeIdx] 
												if otherEdge.entity ~= currentEdge.entity and not util.contains(existingEdgesToAdd, otherEdge) then 
													table.insert(existingEdgesToAdd, otherEdge) -- for testing purposes
												end 
											end 
										else 
											trace("Testing purposes not adding any extra edges as should be there")
											--[[for n, otherEdgeIdx in pairs(tempNodeToSegMap[node]) do
												local otherEdge = extraEd[otherEdgeIdx] 
												if otherEdge.entity ~= currentEdge.entity and not util.contains(existingEdgesToAdd, otherEdge) then 
													table.insert(existingEdgesToAdd, otherEdge) -- for testing purposes
												end 
											end ]]--
										end 
									end 
								end 
								local testProposal = addEdgeToProposal(setupBase(), currentEdge)
								for i , newEdge in pairs(existingEdgesToAdd) do 
									addEdgeToProposal(testProposal, newEdge) 
								end
								trace("About to setup data at offset=",offset)
								checkOrphanedNodes(testProposal)
								local testData =  api.engine.util.proposal.makeProposalData(testProposal , util.initContext())
								if proposalUtil.areIgnorableErrors(testData.errorState) then 
									trace("Fixed at offset= ",offset)
									wasFixed=true
									break
								elseif util.contains(testData.errorState.messages, "Too much slope") then
									trace("Encountered too much slope, aborting")
									break
								end 
							end 
							if not wasFixed then 
								if edgeTypeChanged then 
									trace("was not fixed, setting edgeType back to none")
									currentEdge.comp.type = 0
									currentEdge.comp.typeIndex = -1
								end 
								for m, node in pairs({currentEdge.comp.node0, currentEdge.comp.node1}) do 
									if node < 0 then 
										local newNode = newNodeMap[node]
										newNode.comp.position.z = originalZ[m]
										trace("returning height to ",newNode.comp.position.z)										
									end
								end 
								if math.abs(deltaZ) < 10 then 
									trace("Attempting splitAndCombine instead")
									splitAndCombine()
								end 
							end 
						end 
					end
					::continue:: 
				end  -- end solutions loop
				
				if not firstEdge then 
					firstEdge = currentEdge
				end 
				
				if #solutions > 0 then 
					trace("about to setup proposal data")
					local testProposal = addEdgeToProposal(setupBase(), firstEdge)
					for i , newEdge in pairs(newEdgesToAdd) do 
						addEdgeToProposal(testProposal, newEdge) 
					end
					for i , newEdge in pairs(existingEdgesToAdd) do 
						addEdgeToProposal(testProposal, newEdge) 
					end
					trace("About to make proposalData")
					checkOrphanedNodes(testProposal)
					if util.tracelog then 
						--debugPrint(testProposal)
					end
					local testData =  api.engine.util.proposal.makeProposalData(testProposal , util.initContext())
					--if util.tracelog then debugPrint(testData.errorState) end 
					if proposalUtil.areIgnorableErrors(testData.errorState) then 
						trace("Success! collision was resolved edgeIdx was",i,"entity=",firstEdge.entity)
						assert(edgesToAdd[-firstEdge.entity].entity==firstEdge.entity)
						edgesToAdd[-firstEdge.entity]=firstEdge
						
						for i , newEdge in pairs(newEdgesToAdd) do 
							table.insert(edgesToAdd, newEdge)
							trace("new edge added was at",i,"entity=",newEdge.entity,"edges total=",#edgesToAdd,util.newEdgeToString(newEdge))
							assert(#edgesToAdd==-newEdge.entity)
						end  
						rebuildNewNodeToSegmentMap() 
					else
						if util.tracelog and testData.errorState.critical then -- temp removed due to excessive time 
							debugPrint(testProposal)
							debugPrint(testData.errorState)
							 debugPrint(testData.collisionInfo)
						end 
						trace("Not Success, collision was NOT resolved, was crit?",testData.errorState.critical)
						for i = originalRemovedEdgesCount+1, #edgesToRemove do 
							local removed = table.remove(edgesToRemove)
							trace("Cleanup, removing edge at i=",i,"edgeId",removed)
							
						end 
						for i = originalAddedNodeCount+1, #nodesToAdd do 
							local node = table.remove(nodesToAdd)
							trace("Cleanup, removing node at i=",i," #nodesToAdd",#nodesToAdd,"entity was",node.entity)
							newNodeMap[node.entity]=nil
						end
						trace("End of cleanup")
						wasCleanedUp = true
					end  
				end 
			end 
		end  
	end 
	trace("Start final check, setting up proposal")
	local correctedProposal = proposalUtil.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	for i , constr in pairs(constructionsToAdd) do 
		correctedProposal.constructionsToAdd[i]=constr
	end 
	correctedProposal.constructionsToRemove = constructionsToRemove
	profiler.endFunction("proposalUtil.attemptDeconfliction")
	if util.tracelog then -- allow the error to propogate
		if not xpcall(function() util.validateProposal(correctedProposal) end, proposalUtil.err) then 
			return newProposal
		end
	else 
		if not pcall(function() util.validateProposal(correctedProposal) end) then 
			return newProposal
		end 
	end 
	if util.tracelog then 
		--trace(debug.traceback())
	end 
	trace("About to make final proposal data")
	
	local testData =  api.engine.util.proposal.makeProposalData(correctedProposal , util.initContext())
	trace("After corrections the testData for correctedProposal was",testData.errorState.critical,"had errors?",#testData.errorState.messages>0)
	if util.tracelog and #testData.errorState.messages > 0 then 
		debugPrint(testData.errorState.messages)
	end 
	
	if testData.errorState.critical then 
		trace("WARNING! Correction had critical error, aborting")
		return newProposal
	end 
	return correctedProposal
end 

function proposalUtil.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	return proposalUtil.attemptDeconfliction(proposalUtil.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose))
end
function proposalUtil.setupProposalAndDeconflictAndSplit(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) 
	local edgesNeedSplit = {}
	
	local nodePosMap = {}
	local maxNodeId = 0
	for i, node in pairs(nodesToAdd) do 
		nodePosMap[node.entity]=node.comp.position
		maxNodeId = math.max(math.abs(node.entity, maxNodeId))
	end 
	local function nodePos(node) 
		if node < 0 then 
			return nodePosMap[node]
		end 
		return util.nodePos(node)
	end 
	local targetSegLength = 90
	
	if util.tracelog then 
		debugPrint({setupProposalAndDeconflictAndSplitEdges=edgesToAdd})
	end
	
	for i = 1, #edgesToAdd do
		local edge = edgesToAdd[i]
		if not edge.comp.tangent0 then 
			debugPrint({edgesToAdd=edgesToAdd, edge=edge})
		end 
		local p0 = nodePos(edge.comp.node0)
		local p1 = nodePos(edge.comp.node1)
		local t0 = util.v3(edge.comp.tangent0) 
		local t1 = util.v3(edge.comp.tangent1) 
		local inputEdge = {
			p0 = p0, 
			p1 = p1,
			t0 = t0,
			t1 = t1 		
		} 
		
		local dist = util.distance(p0,	p1 )
		trace("Checking edge to split at ",i,"dist was",dist)
		if dist > 2*targetSegLength then 
			
			local newEntity = util.copySegmentAndEntity(edge,-1-#edgesToAdd)
			table.insert(edgesToAdd, newEntity)
			newEntity.comp.objects = {} -- clear any edge objects 
			local s = util.solveForPositionHermiteFraction(0.5, inputEdge)
			maxNodeId = maxNodeId + 1
			local newNode = util.newNodeWithPosition(s.p1, -maxNodeId)
			table.insert(nodesToAdd, newNode)
			nodePosMap[newNode.entity]=newNode.comp.position
			edge.comp.node1 = newNode.entity 
			newEntity.comp.node0 = newNode.entity 
			
			util.setTangent(edge.comp.tangent0, s.t0)
			util.setTangent(edge.comp.tangent1, s.t1)
			util.setTangent(newEntity.comp.tangent0, s.t2)
			util.setTangent(newEntity.comp.tangent1, s.t3)
			trace("Splitting edge, setup new node at",s.p1.x, s.p1.y,"nodeEntity=",newNode.entity,"newEdgeEntity=",newEntity.entity)
		end 
	end 
	
	
	return proposalUtil.setupProposalAndDeconflict(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
end 

local function getEdgesToInspect(edgePositionsToCheck)
local alreadySeen = {}
	
	local edgesToInspect = {}
	for i , edgePosition in pairs(edgePositionsToCheck) do 
		local p0 = edgePosition.p0 
		local p1 = edgePosition.p1
		local edgeId = util.findEdgeConnectingPoints(p0, p1) 
		if edgeId and not util.isFrozenEdge(edgeId) then 
			
			if not alreadySeen[edgeId] then 
				alreadySeen[edgeId]  = true 
				table.insert(edgesToInspect, edgeId)
			end	 
		else 
			trace("WARNING! checkEdgeTypes: No edge found",p0.x, p0.y,"-",p1.x,p1.y)
			local dist = util.distance(p0, p1)
			local pMid = 0.5*(p0+p1)
			local excludeData =  true 
			for i, edge in pairs(util.searchForEntities(pMid, dist, "BASE_EDGE", excludeData)) do 
				if not alreadySeen[edge] and not util.isFrozenEdge(edge)  then 
					table.insert(edgesToInspect, edge)
					alreadySeen[edge]=true
					table.insert(edgePositionsToCheck, {
						p0 = util.nodePos(util.getEdge(edge).node0),
						p1 = util.nodePos(util.getEdge(edge).node1)
					})
				end 
			end 
		end
	end 
	return edgesToInspect
end 

function proposalUtil.cleanUpEdges(edgePositionsToCheck,params)
	trace("cleanUpEdges: begin")
	if not params then 
		params = {
			passCount = 1, problematicEdges = {}
		}
	end 
	util.clearCacheNode2SegMaps()
	util.lazyCacheNode2SegMaps()
	local context = util.initContext()
	context.player = -1
	local nodes = {}
	local edgesToInspect = getEdgesToInspect(edgePositionsToCheck)
	for i, seg in pairs(edgesToInspect) do 
		local edge = util.getEdge(seg) 
		for j, node in pairs({edge.node0, edge.node1}) do 
			if not nodes[node] and not util.isNodeConnectedToFrozenEdge(node) then 
				nodes[node]=true
			end 
		end 
	end 
	
	local edgesToRemove = {}
	local edgesToAdd = {}
	local nodesToRemove = {}
	
	local alreadySeen = {}
	for node, bool in pairs(nodes) do 
		local segs = util.getSegmentsForNode(node)
		if #util.getSegmentsForNode(node)  == 2 then 
			local leftEdgeId =  segs[1]
			local rightEdgeId = segs[2]
			local leftEdge = util.getEdge(leftEdgeId) 
			if leftEdge.node0 == node then -- keep the left as always node1
				leftEdgeId = segs[2]
				rightEdgeId = segs[1]
			end 
			
			if not alreadySeen[leftEdgeId] and not alreadySeen[rightEdgeId] then 
				local leftEdge = util.getEdge(leftEdgeId) 
				local rightEdge = util.getEdge(rightEdgeId)
				if rightEdge.type == leftEdge.type and #leftEdge.objects==0 and #rightEdge.objects==0 and leftEdge.node1 == node then 
					local len1 = util.calculateSegmentLengthFromEdge(leftEdge)
					local len2 = util.calculateSegmentLengthFromEdge(rightEdge)
					local total = len1+len2
					trace("inspecting edges",leftEdgeId,rightEdgeId,"lengths were",len1, len2,"total=",total,"edgeTypes were",rightEdge.type,leftEdge.type)
					if total < 90 then 
						trace("Attempting recombination")
						local newEntity = util.copyExistingEdge(leftEdgeId,-1-#edgesToAdd)
						assert(newEntity.comp.node1 == node)
						local rightIsNode0 = rightEdge.node0 == node
						local otherRightNode = rightIsNode0 and rightEdge.node1 or rightEdge.node0 
						local otherRightTangent = rightIsNode0 and util.v3(rightEdge.tangent1) or -1*util.v3(rightEdge.tangent0)
						 
						newEntity.comp.node1 = otherRightNode
						util.setTangent(newEntity.comp.tangent1, otherRightTangent)  
						util.setTangentLengths(newEntity )
						  
						local testProposal = api.type.SimpleProposal.new()
						testProposal.streetProposal.edgesToAdd[1]=newEntity
						testProposal.streetProposal.edgesToRemove[1]=leftEdgeId
						testProposal.streetProposal.edgesToRemove[2]=rightEdgeId
						testProposal.streetProposal.nodesToRemove[1]=node
						local testData = api.engine.util.proposal.makeProposalData(testProposal , context)
					
						local isCritical = testData.errorState.critical
						local isError = #testData.errorState.messages > 0 or isCritical
						trace("Test data made, isError",isError,"isCritical?",isCritical)
						if not isError then 
							trace("Adding to main proposal")
							alreadySeen[leftEdgeId]=true 
							alreadySeen[rightEdgeId]=true 
							table.insert(edgesToRemove, leftEdgeId)
							table.insert(edgesToRemove, rightEdgeId)
							table.insert(edgesToAdd, newEntity)
							table.insert(nodesToRemove, node)
							table.insert(edgePositionsToCheck, {
								p0 = util.nodePos(newEntity.comp.node0),
								p1 = util.nodePos(newEntity.comp.node1)
							})
						end 
					end
				end 
			end
		end 
	end 
	
	
	local newProposal = api.type.SimpleProposal.new()
	for i, node in pairs(nodesToRemove) do 
		newProposal.streetProposal.nodesToRemove[i]=node
	end 
	for i, edge in pairs(edgesToAdd) do 
		newProposal.streetProposal.edgesToAdd[i]=edge
	end 
	for i, edge in pairs(edgesToRemove) do 
		newProposal.streetProposal.edgesToRemove[i]=edge
	end 	
	local atLeastOneChanged = #edgesToRemove > 0  
	trace("checkEdgeTypes: About to send command to build")

	local build = api.cmd.make.buildProposal(newProposal, context , true)
	api.cmd.sendCommand(build, function(res, success) 
		trace("cleanUpEdges: Result of checking edges was",success," params.passCount=",params.passCount,"atLeastOneChanged?",atLeastOneChanged)
		if util.tracelog then 
			--  game.interface.setGameSpeed(0)
		end
		if success then 
			util.clearCacheNode2SegMaps()
			if params.passCount <= 5 and atLeastOneChanged then 
				params.passCount = params.passCount + 1  
				trace("Doing second pass")
				proposalUtil.addWork(function() proposalUtil.cleanUpEdges(edgePositionsToCheck, params)  end)
			end 
		else  
		end 
	end)
end 

local function getNodeSize(node) 
	local result = 0 
	local tn = util.getComponent(node, api.type.ComponentType.TRANSPORT_NETWORK)
	for i, edge in pairs(tn.edges) do 
		result = math.max(result, edge.geometry.length)
	end 
	return result -- / 2 -- can't divide by 2, it is not symmetric
end 

function proposalUtil.checkEdgeTypes(edgePositionsToCheck, params, checkTerrainEffects) 
	util.lazyCacheNode2SegMaps()
	if not params then 
		params = {
			passCount = 1, problematicEdges = {}
		}
	end 
	local terrain = util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.TERRAIN)
	local waterLevel = terrain.waterLevel
	local edgesToRemove = {}
	local edgesToAdd = {}
	local nodesToAdd = {}
	local bridgeType = api.res.bridgeTypeRep.find("cement.lua")
	local tunnelType  = api.res.tunnelTypeRep.find("street_old.lua")
	--local checkTerrainEffects =  false --true--params.passCount > 1
	local allowTunnels = true --params.passCount < 3
	local waterLevel = util.getWaterLevel()
	local function getSuggestEdgeTypeForPosition(pos ,t, node ) 
		local requiresBridge = false 
		local requiresTunnel = false 
		
		local alreadyHasBridge = false 
		local alreadyHasTunnel = false 
		local suggestedTunnelType = tunnelType 
		local suggestedBridgeType = bridgeType
		if node then 
			for i , seg in pairs(util.getSegmentsForNode(node)) do
				if util.getEdge(seg).type == 2 then 
					alreadyHasTunnel = true 
					suggestedTunnelType = util.getEdge(seg).typeIndex
				end 
				if util.getEdge(seg).type == 1 then 
					alreadyHasBridge = true 
					suggestedBridgeType = util.getEdge(seg).typeIndex
				end 
			end			
		end 
		local thresholdForTunnel = alreadyHasTunnel and 10 or 15
		local thresholdForBridge = alreadyHasBridge and 10 or 15
		local startAt = -1 
		local endAt = 1
		if node and #util.getSegmentsForNode(node) > 2 then 
			startAt = 0
			endAt = 0
		end 
		for i = startAt, endAt do 
			local p = pos +i*5*vec3.normalize(vec3.new(t.x, t.y, 0))
			local th = util.th(p)
			local th2 = util.th(p, checkTerrainEffects)
			
			if alreadyHasTunnel and th2-pos.z < 8 then 
				trace("ignoring the terrainEffect height at node",node,"as already has tunnel, the heights were",th,th2,"compared to ",pos.z)
				th2 = th 
			end 
			
			local minHeight = math.min(th, th2)
			local maxHeight = math.max(th,  th2)
			requiresBridge = requiresBridge or th < waterLevel or  p.z - minHeight > thresholdForBridge  
			requiresTunnel = requiresTunnel or maxHeight - p.z  > thresholdForTunnel    
			trace("getSuggestEdgeTypeForPosition: ",p.x,p.y," requiresTunnel?",requiresTunnel,"requiresBridge?",requiresBridge, " maxHeight = ",maxHeight,"p.z=",p.z,"th,th2=",th,th2) 
		end
		trace("getSuggestEdgeTypeForPosition: ",pos.x,pos.y,pos.z," requiresTunnel?",requiresTunnel,"requiresBridge?",requiresBridge) 
		if requiresTunnel and allowTunnels then 
			return 2 , suggestedTunnelType
		end  	
		if requiresBridge then 
			return 1, suggestedBridgeType
		end 		
		return 0, -1
	end 
	local function getSuggestedBridgeType(edge) 
		for i, node in pairs({edge.node0, edge.node1}) do 
			for j, seg in pairs(util.getSegmentsForNode(node)) do 
				if util.getEdge(seg).type == 1 then 
					return util.getEdge(seg).typeIndex -- try to keep bridge types the same
				end 
			end 
		end 
		return bridgeType 
	end 
	local function getSuggestedEdgeTypeForEdge(edge, edgeId, forbidRecurse)
		local p0 = util.nodePos(edge.node0)
		local p1 = util.nodePos(edge.node1)
		local t0 = util.v3(edge.tangent0)
		local t1 = util.v3(edge.tangent1)
		local th0 = util.th(p0)
		local th1 = util.th(p1) 
		local alreadyHasBridge = edge.type == 1 
		local alreadyHasTunnel = edge.type == 2
		local thresholdForTunnel = alreadyHasTunnel and 10 or 15
		local thresholdForBridge = alreadyHasBridge and 10 or 15	
		if util.isJunctionEdge(edgeId) then 
			trace("Increasing thresholds for ",edge.id,"due to junction")
			--thresholdForBridge = thresholdForBridge + 5
			--thresholdForTunnel = thresholdForTunnel + 5
			if #util.getSegmentsForNode(edge.node0) > 2 then 
				return getSuggestEdgeTypeForPosition(p0 , edge.tangent0 ) 
			end 
			if #util.getSegmentsForNode(edge.node1) > 2 then 
				return getSuggestEdgeTypeForPosition(p1 ,edge.tangent1  ) 
			end 
		end 
		for i = 1, 15 do 
			local testP = util.hermite(i/16, p0, t0, p1, t1).p 
			local th = util.th(testP)  
			local needsTunnel = th > testP.z + thresholdForTunnel
			local th2 = util.th(testP, true)
			if th2 > testP.z+ 8 then 
				needsTunnel = true
			end 
			if needsTunnel then 
				trace("checkTerrainEffects: Detected tunnel needed at ",testP.x,testP.y)
				return 2, tunnelType
			end 
			if th < waterLevel or th < testP.z -thresholdForBridge then 
				trace("checkTerrainEffects: Detected bridge needed",testP.x,testP.y) 
				return 1, getSuggestedBridgeType(edge) 
			end 
		end 
		local requiresBridge = th0 < waterLevel or th1< waterLevel or p0.z - th0 > thresholdForBridge and p1.z - th1 > thresholdForBridge
		local requiresTunnel = th0 - p0.z  > thresholdForTunnel and th1 - p1.z  > thresholdForTunnel
		
		if requiresBridge and requiresTunnel then
			trace("WARNING!, both requiresTunnel and requiresBridge at ",p0.x,p0.y,"-",p1.x,p1.y)
		end 
		
		--assert(not (requiresBridge and requiresTunnel))
		if requiresTunnel and not forbidRecurse then 
		
			local rightSegs = util.getSegmentsForNode(edge.node1)
			local potentialJunctionTunnelPortal = false
			
			for __, node in pairs({edge.node0, edge.node1}) do
				local segs = util.getSegmentsForNode(node)
				if #segs > 2 then 
					for j, edge2 in pairs(segs) do 
						if edge2~= edgeId then 
							local theyAreTunnel = getSuggestedEdgeTypeForEdge(util.getEdge(edge2), edge2, true) == 2
							if theyAreTunnel~= requiresTunnel then 
								trace("getSuggestedEdgeTypeForEdge: Discovered tunnel junction portal at ",node)
								potentialJunctionTunnelPortal = true 
							end 
						end
					end 
				end
			end 
			if potentialJunctionTunnelPortal then 
				thresholdForTunnel = thresholdForTunnel + 5
				requiresTunnel = th0 - p0.z  > thresholdForTunnel and th1 - p1.z  > thresholdForTunnel
				trace("potentialJunctionTunnelPortal found, after increasing the height threshold offset we discover needs tunnel=",requiresTunnel)
			end 
		end 
		local requiresNeither = not requiresBridge and not requiresTunnel and math.abs(th0-p0.z) < 5 and math.abs(th1-p1.z) < 5
		trace("At positions ",p0.x,p0.y,"-",p1.x,p1.y," determined requiresBridge?",requiresBridge," requiresTunnel?",requiresTunnel, ", requiresNeither?",requiresNeither, "allowTunnels?",allowTunnels)
		if requiresBridge then 
			return 1, bridgeType
		end 
		if requiresTunnel  and allowTunnels then 
			return 2 , tunnelType
		end 
		local p0EdgeType, p0EdgeTypeIndex = getSuggestEdgeTypeForPosition(p0, t0 , edge.node0)
		local p1EdgeType, p1EdgeTypeIndex = getSuggestEdgeTypeForPosition(p1, t1, edge.node1)
		if p0EdgeType == p1EdgeType then 
			trace("getSuggestedEdgeTypeForEdge did not pick up any but the types at either end were defined",p0EdgeType) 
			return p0EdgeType, p0EdgeTypeIndex
		end 
		
		return 0, -1
	end

	 
	
	
	local f = math.floor
	local function edgeRequiresCorrection(edgeId) 
		if util.getTrackEdge(edgeId) then 
			return false 
		end
		local edge = util.getEdge(edgeId)
		local p0 = util.nodePos(edge.node0)
		local p1 = util.nodePos(edge.node1)
		local t0 = util.v3(edge.tangent0)
		local t1 = util.v3(edge.tangent1) 
		
		local isTunnel = edge.type == 2 
		local isBridge = edge.type == 1
		local isNeither = edge.type == 0
		local result = false 
		local maxTerrainOffset = -math.huge
		local minTerrainOffset = math.huge
		local totalTerrainOffset = 0
		local hasWaterPoints = false
		for i = 0, 16 do 
			local p = util.hermite(i/16, p0, t0, p1, t1).p 
			local th = util.th(p) 
			local th2 = util.th(p, true)
			if    (isTunnel or isNeither) then 
				if th2 > th then
					if th2 - p.z < 8 then
						trace("Using the original  height instead edge",edgeId)
						th2 = th
					end 
						--trace("The self offset at edge",edgeId," was ",th2-th," adjusting th2 to ",th2-6)
--					th2 = th2 - 6 -- need to account for the tunnels own effect on the terrain
				end
			end 
			local maxH = math.max(th, th2)
			local minH = math.min(th, th2)
			local heightToUse = isBridge and minH or maxH
			local terrainOffset =  p.z - heightToUse
			--[[if f(th)~=f(th2) then 
				local adjustedTerrainOffset = terrainOffset < 0 and p.z-minH or p.z-maxH
				trace("edgeRequiresCorrection: th=",th,"th2=",th2, " at",p.x,p.y," ourHeight=",p.x, "terrainOffset=",terrainOffset, " adjustedTerrainOffset=",adjustedTerrainOffset)
				terrainOffset = adjustedTerrainOffset
			end ]]--
			totalTerrainOffset = terrainOffset + totalTerrainOffset
			minTerrainOffset = math.min(terrainOffset, minTerrainOffset)
			maxTerrainOffset = math.max(terrainOffset, maxTerrainOffset)
			if th < waterLevel then 
				hasWaterPoints = true 
			end
		end 
		if isTunnel and totalTerrainOffset > 0 then 
			result = true 
		end 
		if isBridge and totalTerrainOffset < 0 then 
			result = true 
		end 
		if isBridge and minTerrainOffset < 2 then 
			result = true 
		end 
		if isTunnel and maxTerrainOffset > -5 then 
			result = true 
		end
		if not isBridge and not isTunnel and math.max(math.abs(maxTerrainOffset), math.abs(minTerrainOffset)) > 10 then 
			result = true 
		end
		if not isBridge and hasWaterPoints then 
			result = true 
		end
		
		if not result then 
			local leftSegs = util.getSegmentsForNode(edge.node0)
			local rightSegs = util.getSegmentsForNode(edge.node1)
		 
			for j, edge2 in pairs(leftSegs) do
			
				local theirEdge = util.getEdge(edge2)
				local theyAreTunnel = theirEdge.type == 2
				local theyAreBridge = theirEdge.type == 1
				trace("For edge",edgeId,"inspecting other edge on the left",edge2,"theyAreBridge?",theyAreBridge,"theyAreTunnel?",theyAreTunnel)
				if theyAreTunnel~= isTunnel and #leftSegs>2 then 
					trace("Discovered tunnel junction portal at ",edge.node0)
					result = true 
				end 
				if theyAreBridge and isTunnel or theyAreTunnel and isBridge then 
					trace("Discovered tunnel to bridge at ",edge.node0)
					result = true 
				end 
			end 
			  
			 
			for j, edge2 in pairs(rightSegs) do 
				local theirEdge = util.getEdge(edge2)
				local theyAreTunnel = theirEdge.type == 2 
				local theyAreBridge = theirEdge.type == 1
				
				if theyAreTunnel~= isTunnel and #rightSegs>2 then 
					trace("Discovered tunnel junction portal at ",edge.node1)
					result = true 
				end 
				if theyAreBridge and isTunnel or theyAreTunnel and isBridge then 
					trace("Discovered tunnel to bridge at ",edge.node1)
					result = true 
				end 
			end 
			  
		end 
		
		trace("Inspecting edge",edgeId,"isTunnel=",isTunnel,"isBridge=",isBridge," to determin if needs correction?",result, "minTerrainOffset=",minTerrainOffset,"maxTerrainOffset=",maxTerrainOffset, "totalTerrainOffset=",totalTerrainOffset)
		return result			
	end 
	local edgesToInspect = getEdgesToInspect(edgePositionsToCheck)
	local oldEdgesToInspect = edgesToInspect
	local edgesToInspect = {}
	for i , edgeId in pairs(oldEdgesToInspect) do 
		if edgeRequiresCorrection(edgeId) then 
			table.insert(edgesToInspect, edgeId)
		end 
	end 
	local context  = util.initContext()
	
	context.cleanupStreetGraph=params.passCount < 4
	trace("Set cleanupStreetGraph to",context.cleanupStreetGraph)
	local splitEdgeCount = 0 
	local replacedEdgeCount = 0
	for i , edgeId in pairs(edgesToInspect) do 
	 
		local edge = util.getEdge(edgeId)
		local edgeLength = util.calculateSegmentLengthFromEdge(edge)
		local deflectionAngle = math.abs(util.signedAngle(edge.tangent0, edge.tangent1))
		--local maxAngle = math.rad(5)
		local maxAngle = math.rad(100)
		if params.passCount >= 2 then 
			--maxAngle = math.rad(45)
		end
		
		local leftSegs = util.getSegmentsForNode(edge.node0)
		local rightSegs = util.getSegmentsForNode(edge.node1)
		local minDist1 = 8 + getNodeSize(edge.node0)
		local minDist2 = 8 + getNodeSize(edge.node1)
		
		trace("The mindist at node",edge.node0,"was",minDist1,"for",edge.node1,"was",minDist2)
		
		
		local safeToSplit = edgeLength > (minDist1+minDist2) and deflectionAngle < maxAngle and #edge.objects == 0
		
		
		
		local edgeWasSplit = false 
		local p0 = util.nodePos(edge.node0)
		local p1 = util.nodePos(edge.node1)
		local t0 = util.v3(edge.tangent0)
		local t1 = util.v3(edge.tangent1)
		trace("checkEdgeTypes: edgeId=",edgeId," At positions ",p0.x,p0.y,"-",p1.x,p1.y)
		local p0EdgeType, p0EdgeTypeIndex = getSuggestEdgeTypeForPosition(p0, t0 , edge.node0)
		local p1EdgeType, p1EdgeTypeIndex = getSuggestEdgeTypeForPosition(p1, t1, edge.node1)
		local suggestedEdgeType, suggestedEdgeTypeIndex = getSuggestedEdgeTypeForEdge(edge, edgeId)
		local splitsDisabled = params.disableEdgeSplits or not safeToSplit
		local shouldSplit =  (p0EdgeType~=p1EdgeType or p0EdgeType~=suggestedEdgeType) and not splitsDisabled
		if not shouldSplit and not splitsDisabled then
			for i = 1, 15 do 
				local frac = i/16
				--local split = util.solveForPositionHermiteFractionExistingEdge(frac, edgeId)
				local split = util.hermite(i/16, p0, t0, p1, t1)
				local pMidEdgeType, pMidEdgeTypeIndex = getSuggestEdgeTypeForPosition(split.p, split.t)
				shouldSplit = shouldSplit or pMidEdgeType~= p0EdgeType
			end
		end
		trace("checkEdgeTypes: edgeId=",edgeId,"safeToSplit?",safeToSplit," length =",edgeLength,"deflectionAngle=",math.deg(deflectionAngle),"shouldSplit?",shouldSplit,"splitsDisabled?",params.disableEdgeSplits, "the p0EdgeType was",p0EdgeType,"the p1EdgeType was",p1EdgeType,"suggestedEdgeType=",suggestedEdgeType)
		local reverseSearch = false 
		local fixBridgeToTunnel = false
		if not splitsDisabled  and params.passCount >= 2 then 
			local ourEdgeType = edge.type 
			local countMisMatchedEdges = 0
			local theirEdgeType
			local theirEdgeTypeIndex
			if #leftSegs >= 3 then 
				for i, seg in pairs(leftSegs) do 
					local theirSuggestedEdgeType, theirSuggestedEdgeTypeIndex = getSuggestedEdgeTypeForEdge(util.getEdge(seg), seg)
					if params.problematicEdges[seg] then 
						local edgeFull = util.getEdge(seg)
						theirSuggestedEdgeType = edgeFull.type
						theirSuggestedEdgeTypeIndex = edgeFull.typeIndex
					end 
					if seg~= edgeId and  theirSuggestedEdgeType ~= ourEdgeType then 
						countMisMatchedEdges = countMisMatchedEdges + 1
						if not theirEdgeType or params.problematicEdges[seg] then 
							theirEdgeType = theirSuggestedEdgeType
							theirEdgeTypeIndex = theirSuggestedEdgeTypeIndex
						end
					end
				end 
			end 
			if countMisMatchedEdges>= 2 then 
				trace("Left segs: Setting should split to avoid a junction conflict")
				shouldSplit = true 
				p0EdgeType = theirEdgeType
				p0EdgeTypeIndex = theirEdgeTypeIndex
			end 
			theirEdgeType = nil 
			theirEdgeTypeIndex = nil
			countMisMatchedEdges = 0
			if #rightSegs >= 3 then 
				for i, seg in pairs(rightSegs) do 
					local theirSuggestedEdgeType, theirSuggestedEdgeTypeIndex = getSuggestedEdgeTypeForEdge(util.getEdge(seg), seg)
					if params.problematicEdges[seg] then  -- use the actual type 
						local edgeFull = util.getEdge(seg)
						theirSuggestedEdgeType = edgeFull.type
						theirSuggestedEdgeTypeIndex = edgeFull.typeIndex
					end 
					if seg~= edgeId and  theirSuggestedEdgeType ~= ourEdgeType then 
						countMisMatchedEdges = countMisMatchedEdges + 1 
						if not theirEdgeType or params.problematicEdges[seg] then --problem edges take priority
							theirEdgeType = theirSuggestedEdgeType
							theirEdgeTypeIndex = theirSuggestedEdgeTypeIndex
						end
					end
				end 
			end 
			if countMisMatchedEdges>= 2 then 
				trace("Right segs: Setting should split to avoid a junction conflict")
				shouldSplit = true 
				p1EdgeType = theirEdgeType
				p1EdgeTypeIndex = theirEdgeTypeIndex
				reverseSearch = true 
			end
			if not shouldSplit then 
				for j, segs in pairs({leftSegs, rightSegs}) do
					if #segs == 2 then  
						local otherEdgeId  = segs[1] == edgeId and segs[2] or segs[1]
						--local ourNode = j==1 and edge.node0 or edge.node1 
						local otherEdgeFull = util.getEdge(otherEdgeId)
						if edge.type > 0 and otherEdgeFull.type > 0 and edge.type~=otherEdgeFull.type then 
							
							shouldSplit = true 
							fixBridgeToTunnel = true 
							reverseSearch = j == 2
							
							if j == 1 then 
								p0EdgeType = 0
								p0EdgeTypeIndex = -1
							else 
								p1EdgeType = 0
								p1EdgeTypeIndex = -1
							end 
							trace("EdgeId",edgeId,"discovered bridgeToTunnelTofix set reverseSearch to",reverseSearch,"j=",j,"p0EdgeType=",p0EdgeType,"p1EdgeType=",p1EdgeType)
						end 
						
					end
				end
			end 
			
			if shouldSplit then 
				trace("Attempting to force a split on edge",edgeId)
			end
		end 
		
		if  shouldSplit then 
			local kStart = reverseSearch and 2 or 1
			local kEnd = reverseSearch and 1 or 2
			local kInc = reverseSearch and -1 or 1
			if #leftSegs > 2 then -- for junctions need to flatten out the tangents to avoid sharp gradients 
				t0.z = 0 
			end 
			if #rightSegs > 2 then 
				t1.z = 0
			end 
			
			local hadCriticalError = false 
			for k = kStart, kEnd, kInc do 
				local startAt = k == 1 and 1 or 15
				local endAt = k == 1 and 15 or 1 
				local increment = k == 1 and 1 or -1
				local comparisonEdgeType = k==1 and  p0EdgeType or p1EdgeType
				
				for i = startAt, endAt, increment do 
					local frac = i/16
					--local split = util.solveForPositionHermiteFractionExistingEdge(frac, edgeId)
					local split = util.hermite(i/16, p0, t0, p1, t1)
					local pMidEdgeType, pMidEdgeTypeIndex = getSuggestEdgeTypeForPosition(split.p, split.t)
					local d1 = util.distance(split.p,p0)
					local d2 = util.distance(split.p,p1)
					trace("checkEdgeTypes: edgeId=",edgeId,"At k=",k,"i=",i,"comparing the pMidEdgeType",pMidEdgeType,"to the comparisonEdgeType",comparisonEdgeType,"dists were",d1,d2,"minDists=",minDist1,minDist2)
					if pMidEdgeType ~= comparisonEdgeType and d1>minDist1 and d2>minDist2 then 
						trace("Splitting edge", edgeId)
						local newEntity = util.copyExistingEdge(edgeId, -1-#edgesToAdd)
						newEntity.comp.type = p0EdgeType
						newEntity.comp.typeIndex = p0EdgeTypeIndex
						local newNode = util.newNodeWithPosition(split.p, -1000-#nodesToAdd)
						newEntity.comp.node1 = newNode.entity 
						util.setTangent(newEntity.comp.tangent1, split.t)
						util.setTangentLengths(newEntity, util.distance(split.p, p0))
						
						
						local newEntity2 = util.copyExistingEdge(edgeId, -2-#edgesToAdd)
						newEntity2.comp.type = p1EdgeType
						newEntity2.comp.typeIndex = p1EdgeTypeIndex
						newEntity2.comp.node0 = newNode.entity 
						util.setTangent(newEntity2.comp.tangent0, split.t)
						util.setTangentLengths(newEntity2, util.distance(split.p, p1))
						
						trace("About to setup testProposal")
						local testProposal = api.type.SimpleProposal.new()
						testProposal.streetProposal.edgesToAdd[1]=newEntity 
						testProposal.streetProposal.edgesToAdd[2]=newEntity2 
						testProposal.streetProposal.edgesToRemove[1] = edgeId 
						testProposal.streetProposal.nodesToAdd[1] = newNode 
						trace("testProposal setup,now about to make test data")
						 
						local testData = api.engine.util.proposal.makeProposalData(testProposal , context)
						trace("Test data made")
						local isCritical = testData.errorState.critical
						local isError = #testData.errorState.messages > 0 or isCritical
						trace("Made test data for splitting edge",edgeId, " at ",split.p.x,split.p.y," isError?",isError," isCritical?",isCritical)
						if isError and util.tracelog  then 
							debugPrint(testData.errorState)
						end 
						local hasCollision = util.contains(testData.errorState.messages, "Collision")
						local abort = isCritical
						hadCriticalError = hadCriticalError or isCritical
						if hasCollision then -- and params.isHighwayInsideCity then 
							abort = true 
							trace("Aborting due to collision and isHighwayInsideCity")
						end 
						if abort then 
							trace("Aborting attempted split of ",edgeId)
							--break 
						else 
							
							table.insert(nodesToAdd, newNode)
							table.insert(edgesToAdd, newEntity)
							table.insert(edgesToRemove, edgeId)
							trace("Removing edge",edgeId)
							table.insert(edgesToAdd, newEntity2)
							table.insert(edgePositionsToCheck, {
								p0 = p0,
								p1 = split.p
							})
							table.insert(edgePositionsToCheck, {
								p0 = split.p,
								p1 = p1
							})
							edgeWasSplit = true 
							splitEdgeCount = splitEdgeCount+1
							break
						end
					end 
				end
				if edgeWasSplit then 
					break 
				end 
			end 
			if not edgeWasSplit and hadCriticalError then 
				trace("Discovered problematic edge",edgeId,"could not split")
				if not params.problematicEdges then 
					params.problematicEdges = {}
				end 
				params.problematicEdges[edgeId] = true 
			end 
		end 
		if not edgeWasSplit then 
			for j, segs in pairs({leftSegs, rightSegs}) do
				if #segs > 2 then  
					local theirSuggestedTypes = {}
					for i, seg in pairs(segs) do
						if seg~=edgeId then 
							if params.problematicEdges[seg] then 
								local theirEdge = util.getEdge(seg)
								suggestedEdgeType = theirEdge.type 
								suggestedEdgeTypeIndex = theirEdge.typeIndex 
								trace("checkEdgeTypes: found edge",edgeId,"connected to problematic edge",seg,"overriding type to ", suggestedEdgeType)
								break 
							else 
								local theirSuggestedEdgeType, theirSuggestedEdgeTypeIndex = getSuggestedEdgeTypeForEdge(util.getEdge(seg), seg)
								table.insert(theirSuggestedTypes, { theirSuggestedEdgeType=theirSuggestedEdgeType, theirSuggestedEdgeTypeIndex=theirSuggestedEdgeTypeIndex})
							end 
						end 
					end 
					if #theirSuggestedTypes >= 2 then 
						if theirSuggestedTypes[1].theirSuggestedEdgeType == theirSuggestedTypes[2].theirSuggestedEdgeType then 
							local shouldFix = #theirSuggestedTypes==2 or theirSuggestedTypes[2].theirSuggestedEdgeType == theirSuggestedTypes[3].theirSuggestedEdgeType
							if shouldFix then 
								suggestedEdgeType = theirSuggestedTypes[1].theirSuggestedEdgeType
								suggestedEdgeTypeIndex = theirSuggestedTypes[1].theirSuggestedEdgeTypeIndex
								trace("checkEdgeTypes: found edge",edgeId,"overruling our suggestedEdgeType to", suggestedEdgeType)
							end
						end 
						
					end 
				end 
			end
			trace("Edge",edgeId, "was not split, comparing the suggestedEdgeType",suggestedEdgeType,"to the actual edge type",edge.type)
			if suggestedEdgeType ~= edge.type then 
				trace("checkEdgeTypes: Replacing edgetype for ",edgeId, " suggestedEdgeType=",suggestedEdgeType," existing type =" ,edge.type)
				local newEntity = util.copyExistingEdge(edgeId, -1-#edgesToAdd)
				newEntity.comp.type = suggestedEdgeType
				newEntity.comp.typeIndex = suggestedEdgeTypeIndex
				local testProposal = api.type.SimpleProposal.new()
				testProposal.streetProposal.edgesToAdd[1]=newEntity  
				testProposal.streetProposal.edgesToRemove[1] = edgeId 
				local testData = api.engine.util.proposal.makeProposalData(testProposal , context)
				local isCritical = testData.errorState.critical
				local isError = #testData.errorState.messages > 0 or isCritical
				trace("Made test data for replacing edge",edgeId, "  isError?",isError," isCritical?",isCritical)
				local hasCollision = util.contains(testData.errorState.messages, "Collision")
				if isError and util.tracelog  then 
					debugPrint({errorState = testData.errorState, collisionInfo = testData.collisionInfo} )
					
				end 
				if hasCollision then -- need to check for a "bugged" collision
					local bb = util.getComponent(edgeId, api.type.ComponentType.BOUNDING_VOLUME)
					local minX = bb.bbox.min.x
					local minY = bb.bbox.min.y
					local maxX = bb.bbox.max.x
					local maxY = bb.bbox.max.y
					local foundAll = true
					for j , e in pairs(testData.collisionInfo.collisionEntities) do
						local entity = e.entity
						local entityFull = game.interface.getEntity(entity)
						if entityFull and entityFull.type == "BASE_NODE" then 
							local nodePos = util.nodePos(entity)
							local isInBox2d = nodePos.x>= minX and nodePos.x <= maxX and nodePos.y >= minY and nodePos.x <= maxY 
							trace("Inspecting node",entity," at pos",nodePos.x,nodePos.y," is in edge bb?",isInBox2d)
							if isInBox2d then 
								foundAll = false 
								break
							end 	
							
						else 
							foundAll = false 
							break
						end 
					end
					if foundAll then 
						trace("found all the collision entities and all were bugged, overriding hasCollision")
						hasCollision = false
					end 
				end 
				local canAccept = not isCritical and not hasCollision
				if not canAccept and not isCritical then 
					if suggestedEdgeType == 2 and edge.type == 0 then 
						trace("Overriding the canAccept to true for changing to tunnel")
						canAccept = true 
					end 
					if suggestedEdgeType == 0 and edge.type == 2 then 
					
						newEntity.comp.type = 1
						newEntity.comp.typeIndex = bridgeType
						local testProposal = api.type.SimpleProposal.new()
						testProposal.streetProposal.edgesToAdd[1]=newEntity  
						testProposal.streetProposal.edgesToRemove[1] = edgeId 
						local testData = api.engine.util.proposal.makeProposalData(testProposal , context)
						local isError = #testData.errorState.messages > 0 or isCritical
						trace("Checking if we can change the edge to a bridge, is still error?",isError)
						--debugPrint(testData)
						canAccept = not isError
					end 
				end 
				if canAccept then 
					trace("s Setup new entity connecting",newEntity.comp.node0,newEntity.comp.node1,"  id=",newEntity.entity," replacing ",edgeId)

					table.insert(edgesToAdd, newEntity)
					table.insert(edgesToRemove, edgeId)
					replacedEdgeCount = replacedEdgeCount + 1
				else 
					trace("Aborting the replacment of edge",edgeId)
				end 
			end  
		else 
			trace("Edge",edgeId, "was split")
		end 
	end 
	trace("checkEdgeTypes: replaced",#edgesToAdd, " of ",#edgePositionsToCheck," splitEdgeCount=",splitEdgeCount," replacedEdgeCount=",replacedEdgeCount)
	--local newProposal =  proposalUtil.setupProposal(nodesToAdd, edgesToAdd, {}, edgesToRemove, {})
	local newProposal = api.type.SimpleProposal.new()
	for i, node in pairs(nodesToAdd) do 
		newProposal.streetProposal.nodesToAdd[i]=node
	end 
	for i, edge in pairs(edgesToAdd) do 
		newProposal.streetProposal.edgesToAdd[i]=edge
	end 
	for i, edge in pairs(edgesToRemove) do 
		newProposal.streetProposal.edgesToRemove[i]=edge
	end 	
	local atLeastOneChanged = splitEdgeCount > 0 or replacedEdgeCount > 0 
	trace("checkEdgeTypes: About to send command to build")
	context.player = -1 -- do not charge the player for this 
	local build = api.cmd.make.buildProposal(newProposal, context , true)
	api.cmd.sendCommand(build, function(res, success) 
		trace("checkEdgeTypes: Result of checking edges was",success," params.passCount=",params.passCount,"atLeastOneChanged?",atLeastOneChanged)
		if util.tracelog then 
			-- game.interface.setGameSpeed(0)
		end
		if success then 
			util.clearCacheNode2SegMaps()
			if params.passCount <= 10 and atLeastOneChanged then 
				params.passCount = params.passCount + 1 
				params.disableEdgeSplits = false 
				trace("Doing second pass")
				proposalUtil.addWork(function() proposalUtil.checkEdgeTypes(edgePositionsToCheck, params)  end)
			else 
				--game.interface.setGameSpeed(0)
				proposalUtil.addWork(function() proposalUtil.cleanUpEdges(edgePositionsToCheck)  end)
			end 			
		else 
			if not params.disableEdgeSplits then 
				trace("Attempting with splits disabled")
				params.disableEdgeSplits = true
				proposalUtil.addWork(function() proposalUtil.checkEdgeTypes(edgePositionsToCheck, params)  end)
			end
		end 
	
	end)
end

function proposalUtil.applySmoothing(edgesToAdd, nodesToAdd) 
	if true then -- TODO fix the logic here  
		return 
	end 
	trace("builder.applySmoothing begin")
	local newNodeToSegmentMap = {}
	
	for i, edge in pairs(edgesToAdd) do 
		for j, node in pairs({edge.comp.node0, edge.comp.node1}) do 
			if not newNodeToSegmentMap[node] then 
				newNodeToSegmentMap[node]={}
			end 
			table.insert(newNodeToSegmentMap[node], edge.entity)
		end 
	end 
	local alreadySeen = {}
	local routeSections = {}
	for i, edge in pairs(edgesToAdd) do
		if not alreadySeen[edge.entity] then
			local routeSection = {}
			routeSection.edges = { edge }
			
			for j, node in pairs({edge.comp.node0, edge.comp.node1}) do 
				local nextNode = node 
				local nextEdge = edge.entity
				while(#newNodeToSegmentMap[nextNode]==2 and nextNode < 0) do
					trace("Inside loop, inspecting nextEdge",nextEdge,"nextNode=",nextNode)
					local segs = newNodeToSegmentMap[nextNode]
					local priorEdge = nextEdge
					local priorEdgeFull = edgesToAdd[-nextEdge]
					nextEdge = nextEdge == segs[1] and segs[2] or segs[1]
					nextEdgeFull = edgesToAdd[-nextEdge]
					assert(nextEdgeFull.entity == nextEdge)
					local isNode0 = nextNode == nextEdgeFull.comp.node0
					local wasNode0 = nextNode == priorEdgeFull.comp.node0 
					if isNode0 == wasNode0 then 
						trace("applySmoothing: Detected node reversal, aborting isNode0=",isNode0,"wasNode0=",wasNode0)
						break
					end 
					local t0 = wasNode0 and priorEdgeFull.comp.tangent0 or priorEdgeFull.comp.tangent1
					local t1 = isNode0 and nextEdgeFull.comp.tangent0 or nextEdgeFull.comp.tangent1
					local angle = math.abs(util.signedAngle(t0, t1))
					trace("ApplySmoothing: angle was", math.deg(angle))
					if angle > math.rad(5) then 
						trace("ApplySmoothing: detected misaligned angles, aborting")
						break
					end 
					nextNode = isNode0 and nextEdgeFull.comp.node1 or nextEdgeFull.comp.node0 
					
					assert(not alreadySeen[nextEdge] )
					alreadySeen[nextEdge]=true 
					if j == 1 then 
						table.insert(routeSection.edges, 1, nextEdgeFull)
					else 
						table.insert(routeSection.edges, nextEdgeFull)
					end 
				end 
				if j == 1 then 
					routeSection.startNode = nextNode
				else 
					routeSection.endNode = nextNode 
				end 			 
			end 
			if #routeSection.edges > 1 then 
				table.insert(routeSections, routeSection)
				routeSection.sectionIdx = #routeSections
			end 
		end  	
	end 
	local newNodeLookup = {}
	for i, node in pairs(nodesToAdd) do 
		newNodeLookup[node.entity]=node 
	end 
	local function nodePos(node) 
		if node < 0 then 
			return util.v3(newNodeLookup[node].comp.position)
		else 
			return util.nodePos(node)
		end 
	end 
	
	local startAndEndNodes = {}
	for i, routeSection in pairs(routeSections) do 
		startAndEndNodes[routeSection.startNode] = routeSection.sectionIdx
		startAndEndNodes[routeSection.endNode] = routeSection.sectionIdx
	end
	--[[
	local groupedSections = {}
	for node, sectionIdx in pairs(startAndEndNodes) do 
		for node2, sectionIdx2 in pairs(startAndEndNodes) do 
			if node ~= node2 and sectionIdx ~= sectionIdx2 then 
				local dist = util.distance(nodePos(node), nodePos(node2))
				if dist < 6 then 
					trace("Found adjacent nodes")
					-- TODO tangent check 
					if not groupedSections[sectionIdx] then 
						groupedSections[sectionIdx]={}
					end 
					if not util.contains(groupedSections[sectionIdx], sectionIdx2) then 
						table.insert(groupedSections[sectionIdx], sectionIdx2)
					end 
				
				end 
				
			end
		end
	end]]--
	local numRouteSections = util.size(routeSections)
	local positions = { }
	for i = -numRouteSections, numRouteSections do 
		if i ~= 0 then 
			table.insert(positions, 5*i)
		end 
	end 
	if util.tracelog then debugPrint({positionsForDoubleTrack = positions}) end
	
	local disableDoubleTrackFollowing = false 
	local function findDoubleTrackNodes(node, p, t)
		local result = {}
		if disableDoubleTrackFollowing then  --TODO need to fix
			return result
		end
		if not p then 
			trace("WARNING! no position provided, aborting findDoubleTrackNodes")
			return result
		end
	
		t.z = 0
		t = vec3.normalize(t)
		local tPerp = util.rotateXY(t, math.rad(90) )
		for i, otherNode in pairs(nodesToAdd) do 
			local otherNodePos = nodePos(otherNode.entity) 
			if otherNode.entity ~= node and util.distance(p, otherNodePos) < 5+ 5*numRouteSections then 
				for j, offset in pairs(positions) do 
					local testP = p + offset*tPerp
					local positionsEqual = util.positionsEqual(testP, otherNodePos, 2)
					local dist = util.distance(testP, otherNodePos)
					trace("Comparing the test position",testP.x, testP.y, " to the actual",otherNodePos.x, otherNodePos.y, " are equal? ",positionsEqual," at a dist of ",dist)
					if positionsEqual then 
						local segs = newNodeToSegmentMap[otherNode.entity] or {}
						trace("Found another candidate double track node for ",node, " at ",otherNode.entity," seg count",#segs)
						if #segs == 2 then 
							local edge = edgesToAdd[-segs[1]]
							local isNode0 = edge.comp.node0 == otherNode.entity
							if not isNode0 then 
								assert(edge.comp.node1 == otherNode.entity)
							end
							local otherTangent = isNode0 and edge.comp.tangent0 or edge.comp.tangent1 
							local angle = math.abs(util.signedAngle(t, otherTangent))
							trace("Got tangent angle of ",math.deg(angle), "tangents were ",t.x,t.y, " and ",otherTangent.x, otherTangent.y, " isNode0?",isNode0)
							if angle > math.rad(90) then 
								angle = math.rad(180) - angle
							end 
							local withinTolerance = angle < math.rad(5)
							trace("Got tangent angle of ",math.deg(angle), " after correction, within tolerance?",withinTolerance)
							if withinTolerance then 
								result[otherNode.entity] = offset  
								trace("Found another candidate double track node for ",node)
							end
						end
					end 
				end
			end
		end 
		trace("There were ",util.size(result), " doubleTrackNodes found at ",node)
		return result
	end
	local alreadyAdjusted = {}
	trace("proposalUtil.applySmoothing, found",#routeSections,"routeSections for smoothing")
	
	local edgeIdxLookup = {}
	for i, routeSection in pairs(routeSections) do 
		for j, edge in pairs(routeSection.edges) do 
			edgeIdxLookup[edge.entity]=j
		end 
	end
	for i, routeSection in pairs(routeSections) do 
		local alreadySeenNodes = { [routeSection.startNode] = true, [routeSection.endNode] = true }
		local routeNodes = {}
		for j , edge in pairs(routeSection.edges) do 
			for k, node in pairs({edge.comp.node0, edge.comp.node1}) do 
				if not alreadySeenNodes[node] and not alreadyAdjusted[node] then 
					alreadySeenNodes[node] = true
					table.insert(routeNodes, node)
				end 
			end 
		end 
		local startEdge = routeSection.edges[1]
		local endEdge = routeSection.edges[#routeSection.edges]
		local isStartNode0 = routeSection.startNode == startEdge.comp.node0
		local isEndNode1 = routeSection.endNode == endEdge.comp.node1
		local startTangent = isStartNode0 and util.v3(startEdge.comp.tangent0) or -1*util.v3(startEdge.comp.tangent1)
		local endTangent = isEndNode1 and util.v3(endEdge.comp.tangent1) or -1*util.v3(endEdge.comp.tangent0)
		local p0 = nodePos(routeSection.startNode)
		local p1 = nodePos(routeSection.endNode)
		local t0 = vec3.normalize(startTangent)
		local t1 = vec3.normalize(endTangent)
		local tangentLength = util.calculateTangentLength(p0, p1, t0, t1)
		t0 = tangentLength * t0 
		t1 = tangentLength * t1 
		local inputEdge = {
			p0 = p0, 
			p1 = p1,
			t0 = t0,
			t1 = t1 		
		} 
		
		for j, node in pairs(routeNodes) do 
			local position = nodePos(node)
			local newPosition = util.solveForPosition(position, inputEdge )
			trace("proposalUtil.applySmoothing at section",i," at node",j,"changing position",position.x,position.y," to ",newPosition.p.x, newPosition.p.y)
			newPosition.p.z = position.z -- keep z 
			
			local function setPositionOnNode(node, p, t, isDoubleTrackNode)
				trace("applySmoothing.setPositionOnNode begin for node",node)
				if alreadyAdjusted[node] then 
					trace("WARNING! Already adjusted",node," aborting")
					return					
				end
				alreadyAdjusted[node] = true
				local segs = newNodeToSegmentMap[node]
				assert(#segs == 2)
				local seg1 = segs[1]
				local seg2 = segs[2]
				if not edgeIdxLookup[seg1] or not edgeIdxLookup[seg2] then 
					trace("WARNING! setPositionOnNode: No seg found",seg,"aborting")
					return
				end
				if edgeIdxLookup[seg2] < edgeIdxLookup[seg1] then 
					trace("Swapping seg1, seg2",seg1,seg2)
					local temp = seg1 
					seg1 = seg2 
					seg2 = temp
				end 
				local oldPos = nodePos(node)
				local oldT 
			
				for k, seg in pairs({seg1, seg2}) do 
					local entity = edgesToAdd[-seg]
					local isNode0 = node == entity.comp.node0
					local needsReverse = (k == 1) == isNode0
					
					local thisT = needsReverse and -1*t or t
					local p0 = nodePos(entity.comp.node0)
					local p1 = nodePos(entity.comp.node1)
					local t0 = util.v3(entity.comp.tangent0)
					local t1 = util.v3(entity.comp.tangent1)
					if isDoubleTrackNode then 
						local otherT =  isNode0 and t1 or t0 
						local naturalTangent = p1 - p0 
						local tangentAngle = math.abs(util.signedAngle(thisT, otherT))
						local tangentAngle2 = math.abs(util.signedAngle(thisT, naturalTangent))
						local tangentAngle3 = math.abs(util.signedAngle(otherT, naturalTangent))
						local angleDiscrepency = tangentAngle2 - tangentAngle3
						-- example of wrong: Checking the tangent angles, were	151.48389080622	163.32776421565	11.843873409424
						trace("Checking the tangent angles, were",math.deg(tangentAngle),math.deg(tangentAngle2),math.deg(tangentAngle3), " angleDiscrepency=",math.deg(angleDiscrepency))
						if tangentAngle > math.rad(160) or angleDiscrepency > math.rad(90) then 
							trace("WARNING! Significant angle detected,  reversing")
							thisT = -1*thisT -- it is possible the edges are heading in the opposite direction
						end 
					end 
					
					if isNode0 then 	
						oldT = t0
						t0 = thisT 
						p0 = p -- set most accurate positions for tangent length calculation
						if entity.comp.node1 < 0 then 
							p1 = util.v3(newNodeLookup[entity.comp.node1].comp.position)
						end 
					else
						oldT = t1					
						t1 = thisT 
						if entity.comp.node0 < 0 then 
							p0 = util.v3(newNodeLookup[entity.comp.node0].comp.position)
						end
						p1 = p
					end 
					local tangentLength = util.calculateTangentLength(p0, p1, t0, t1)
					trace("Setting tangent at k=",k,"isNode0=",isNode0, "needsReverse?",needsReverse, "tangentLength was",tangentLength,"dist between nodes=",util.distance(p0,p1),"tangentAngle=",math.deg(util.signedAngle(t0,t1)))
					t0 = tangentLength*vec3.normalize(t0)
					t1 = tangentLength*vec3.normalize(t1)
					util.setTangent(entity.comp.tangent0, t0)
					util.setTangent(entity.comp.tangent1, t1)
				end 
				util.setPositionOnNode(newNodeLookup[node], p)
				return oldPos, oldT, t
			end 
			local oldPos, oldT , newT = setPositionOnNode(node, newPosition.p, newPosition.t1)
			for otherNode, offset in pairs(findDoubleTrackNodes(node, oldPos, oldT)) do 
				local newTN = util.v3(newT, true)
				newTN.z= 0 
				--local offsetVector = offset * util.rotateXY(vec3.normalize(newTN), math.rad(90))
				local offsetVector = nodePos(otherNode) -oldPos
				local offsetVector1 = offset * util.rotateXY(vec3.normalize(newTN), math.rad(90))
				local offsetVector2 = offset * util.rotateXY(vec3.normalize(newTN), -math.rad(90))
				if math.abs(util.signedAngle(offsetVector, offsetVector1)) < math.abs(util.signedAngle(offsetVector, offsetVector2)) then 
					offsetVector = offsetVector1 
				else 
					offsetVector = offsetVector2
				end -- TODO need to fix this
				--setPositionOnNode(otherNode, newPosition.p + offsetVector, newPosition.t1, true)
			end
		end 
		 
	end 
	
end 

return proposalUtil