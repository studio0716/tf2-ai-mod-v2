local vec2 = require "vec2"
local vec3 = require "vec3"

local util = {}
local function trace(...)
	if util.tracelog then 
		print(...)
	end 
end 



local function contourToString(contour)
	if contour == nil then 
		return "<none>"
	end
	return "contour at ["..tostring(contour.p.x)..","..tostring(contour.p.y).."] mesh=["..tostring(contour.mesh).."] contour=["..tostring(contour.contour).."] index=["..tostring(contour.index).."] hash=["..tostring(contour.hash).."]"
end 
 util.riverMeshContoursCache = {}
local function meshHash(mesh0, mesh1) 
	if mesh0<mesh1 then 
		return mesh0 + 1000000*mesh1
	else 
		return mesh1 + 1000000*mesh0
	end 
end 
util.meshHash = meshHash

local meshTileSize = 256
function util.getWaterMeshGroups() 
	if not util.cachedWaterMeshedGroups then 
		local begin = os.clock()
		local meshes = {}
		local contourPoints = {}
		local function pointHash2dFuzzy(p) 
			return math.floor(p.x/4)+ 10000*math.floor(p.y/4)
		end 
		api.engine.forEachEntityWithComponent(function(mesh) table.insert(meshes, mesh) end, api.type.ComponentType.WATER_MESH)
		local nodeToMeshMap = {}
		local connectedMeshes = {}
		local meshPositions = {}
		for i, meshId in pairs(meshes) do 
		
			local mesh = util.getComponent(meshId, api.type.ComponentType.WATER_MESH)
			meshPositions[meshId] = vec2.new(mesh.pos.x*meshTileSize, mesh.pos.y*meshTileSize)
			for j, point in pairs(mesh.vertices) do 
				local node = util.pointHash2d(point )
				if not nodeToMeshMap[node] then 
					nodeToMeshMap[node]={}
				end 
				table.insert(nodeToMeshMap[node], meshId)
			end 
			for j, contour in pairs(mesh.contours) do 
				for k, point in pairs(contour.vertices) do 
					local node = pointHash2dFuzzy(point )
					if not contourPoints[node] then 
						contourPoints[node] = true
					end
				end
			end
			
		end 
		local meshGroups = {}
		local nextGroupId = 1
		local alreadySeen = {}
		local function findAllConnectedMeshes(meshId)
			if alreadySeen[meshId] then 
				return 
			end 
			alreadySeen[meshId] = true 
			local mesh = util.getComponent(meshId, api.type.ComponentType.WATER_MESH)
			for j, point in pairs(mesh.vertices) do 
				local depth = mesh.depths[j]
				local node = util.pointHash2d(point )
				local contourNode = pointHash2dFuzzy(point) 
				if depth > 10 and not contourPoints[contourNode] then -- seems to be the definition of "non-navigable"
					for k , otherMeshId in pairs(nodeToMeshMap[node]) do 
					
						if not connectedMeshes[meshId] then 
							connectedMeshes[meshId] = {}
						end
						if not connectedMeshes[otherMeshId] then 
							connectedMeshes[otherMeshId] = {}
						end 
						connectedMeshes[meshId][otherMeshId]=true 
						connectedMeshes[otherMeshId][meshId]=true 
						
						--connectedMeshes[meshHash(meshId, otherMeshId)]=true
						if not meshGroups[otherMeshId] then 
							meshGroups[otherMeshId] = nextGroupId 
							findAllConnectedMeshes(otherMeshId ) 
						end
					end 
				end
			end
		end
		

		for i, meshId in pairs(meshes) do 
			if not alreadySeen[meshId] then 
				meshGroups[meshId] = nextGroupId 
				findAllConnectedMeshes(meshId)
				nextGroupId = nextGroupId + 1
				
			end 
		end 
		for meshId, position in pairs(meshPositions) do 
			position.neighbors = {}
			for otherMeshId, bool in pairs(connectedMeshes[meshId] or {}) do 
				table.insert(position.neighbors, otherMeshId)
			end 
		end 
		
		trace("Grouped all water meshes, time taken=",os.clock()-begin, " total groups",nextGroupId)
		util.cachedWaterMeshedGroups =  meshGroups
		util.nodeToMeshMap = nodeToMeshMap
		util.meshPositions = meshPositions
	end 
	return util.cachedWaterMeshedGroups
end 
function util.getMeshPositions()
	if not util.meshPositions then 
		util.getWaterMeshGroups() 
	end 
	return util.meshPositions
end 

function util.isPointOnWaterMeshTile(p) 
	local function hashPoint(p) 
		return math.floor(p.x / 256 + 0.5) + 10000* math.floor(p.y/256+0.5)
	end 
	if not util.tileLookup then 
		util.tileLookup = {}
		for mesh, meshPosition in pairs(util.getMeshPositions()) do 
			local hash = hashPoint(meshPosition)
			--if util.tileLookup[hash] then 
			--	local otherPos = util.getMeshPositions()[util.tileLookup[hash]]
			--	trace("util.tileLookup[hash]=",util.tileLookup[hash],"hash=",hash,"this mesh=",mesh,"meshPosition=",meshPosition.x,meshPosition.y,"other position",otherPos.x,otherPos.y)
			--end 
			--assert(not util.tileLookup[hash])
			util.tileLookup[hash]=mesh
		end 
	end 
	return util.tileLookup[hashPoint(p)]
end 

function util.findWaterPathDistanceBetweenContours(contour1, contour2)
	local meshGroups = util.getWaterMeshGroups() 
	if meshGroups[contour1.mesh]==meshGroups[contour2.mesh] then 
		return util.findWaterPathDistanceBetweenMeshes(contour1.mesh, contour2.mesh) 
	end 
	if contour1.group == contour2.group then 
		local alreadySeen = {}
		--trace("The contours were not on the same mesh group but were on the same contour group")
		local function findConnectingMeshes(contour1, contour2)
			if not contour1 or not contour2 then 
				return 
			end 
			if meshGroups[contour1.mesh]==meshGroups[contour2.mesh] then 
				return util.findWaterPathDistanceBetweenMeshes(contour1.mesh, contour2.mesh) 
			end
			if alreadySeen[meshHash(contour1.mesh, contour2.mesh)] then 
				return 
			end 
			alreadySeen[meshHash(contour1.mesh, contour2.mesh)] =true
			for i, mesh1 in pairs({contour1.nextMesh, contour1.mesh, contour1.priorMesh}) do  -- ok so for now just do 1 level deep, not sure about recusive search
				for i, mesh2 in pairs({contour2.nextMesh,contour2.mesh, contour2.priorMesh}) do 
				
					if meshGroups[mesh1]==meshGroups[mesh2] then 
						return util.findWaterPathDistanceBetweenMeshes(mesh1, mesh2) 
					end
					--[[local contour3 = util.getWaterMeshEntities
					local result = findConnectingMeshes(contour3, contour4)
					if result then 
						return result
					end ]]--
				end 
			end 
		end 
		local result =  findConnectingMeshes(contour1, contour2)
		if result then 
			--trace("DID find for",contourToString(contour1), contourToString(contour2),"result=",result)
			return result 
		end
		--trace("WARNING! Unable to find for",contourToString(contour1), contourToString(contour2))
		--local nextContour = contour1.priorContour 
		--local nextContour = contour2.nextContour
		--for i, contour in pairs({ contour1.nextContour, co
	end 
	return math.huge

end
util.cachedWaterMechDistances = {} 
function util.findWaterPathDistanceBetweenMeshes(mesh0, mesh1) 
	local meshGroups = util.getWaterMeshGroups() 
	local hash = meshHash(mesh0, mesh1) 
--	print(debug.traceback())
	if util.cachedWaterMechDistances[hash] then 
		return util.cachedWaterMechDistances[hash]
	end 
	local meshTileSize = 256
	if meshGroups[mesh0]~=meshGroups[mesh1] then 
		trace("util.findWaterPathDistanceBetweenMeshes:",mesh0, mesh1," were not on the same mesh group")
		
		return math.huge 
	end
	local function heuristic(a, b)
		return math.abs(a.x - b.x) + math.abs(a.y - b.y)
	end

	local function astar(tiles, start_key, goal_key)
		local open_set = {[start_key] = true}
		local came_from = {}
		local g_score = {[start_key] = 0}
		local f_score = {[start_key] = heuristic(tiles[start_key], tiles[goal_key])}

		while next(open_set) do
			-- Find node in open_set with lowest f_score
			local current_key, current_f = nil, math.huge
			for key in pairs(open_set) do
				if f_score[key] and f_score[key] < current_f then
					current_key = key
					current_f = f_score[key]
				end
			end

			if current_key == goal_key then
				-- Reconstruct path
				local path = {tiles[current_key]}
				while came_from[current_key] do
					current_key = came_from[current_key]
					table.insert(path, 1, tiles[current_key])
				end
				return path
			end

			open_set[current_key] = nil

			for _, neighbor_key in ipairs(tiles[current_key].neighbors) do
				local tentative_g = g_score[current_key] + 1 -- Or use edge weight if any

				if not g_score[neighbor_key] or tentative_g < g_score[neighbor_key] then
					came_from[neighbor_key] = current_key
					g_score[neighbor_key] = tentative_g
					f_score[neighbor_key] = tentative_g + heuristic(tiles[neighbor_key], tiles[goal_key])
					open_set[neighbor_key] = true
				end
			end
		end

		return nil -- No path
	end
	local tiles = util.getMeshPositions()
	local path = astar(tiles, mesh0, mesh1)

	if path then
		--[[for i, tile in ipairs(path) do
			trace("Step " .. i .. ": (" .. tile.x .. ", " .. tile.y .. ")")
		end]]--
		local approxLength = meshTileSize*#path 
		trace("Calculated approxLength as",approxLength)
		util.cachedWaterMechDistances[hash]=approxLength
		return approxLength
	else
		trace("No path found")
		util.cachedWaterMechDistances[hash] = math.huge
		return math.huge
	end
end

function util.getRiverMeshContours(mesh) 
	if util.riverMeshContoursCache[mesh] then 
		return util.riverMeshContoursCache[mesh]
	end 
	local contours = {}
	local meshComp = util.getComponent(mesh, api.type.ComponentType.WATER_MESH)
	for i , contour in pairs(meshComp.contours) do 
		contours[i]={}
		for j = 1, #contour.vertices do 
			local normal = contour.normals[j]
			local point = contour.vertices[j]
			contours[i][j]= {p = vec3.new(point.x, point.y, meshComp.waterLevel), t = vec3.new(normal.x, normal.y,0), mesh=mesh, contour=i, index=j, isRiverMeshContour=true} 
		end 
		for j = 1, #contour.vertices do 
			if j > 1 then 
				contours[i][j].priorContour = contours[i][j-1]
			end 
			if j < #contour.vertices then 
				contours[i][j].nextContour = contours[i][j+1]   
			end
		end 
	end 
	util.riverMeshContoursCache[mesh]=contours
	return contours
end 
local buildContourToMeshMapAlreadyCalled = false 


local function pointHash2d(p) 
	return math.floor(p.x*100+0.5)+1000000*math.floor(p.y*100+0.5)
end 

local function printContourDetails(contour1, contour2, expectedMesh)
	trace("There was an unexpected result")
	trace("contour1: ",contourToString(contour1))
	trace("contour2: ",contourToString(contour2))
	trace("contour1.nextContour: ",contourToString(contour1.nextContour))
	trace("contour1.priorContour: ",contourToString(contour1.priorContour))
	trace("contour2.nextContour: ",contourToString(contour2.nextContour))
	trace("contour2.priorContour: ",contourToString(contour2.priorContour))
	trace("expectedMesh: ",contourToString(expectedMesh))
	trace("contour1==contour2?",contour1==contour2)
end
function util.buildContourToMeshMap() 
	if buildContourToMeshMapAlreadyCalled then 
		return util.allContours
	end 
	trace("util.buildContourToMeshMap begin")
	local hashToContourMap = {}
	local allContours = {}
	api.engine.forEachEntityWithComponent(function(mesh) 
		for j, contours in pairs(util.getRiverMeshContours(mesh)) do 
			local mesh = util.getComponent(mesh, api.type.ComponentType.WATER_MESH)
			if #mesh.indices>0 then 
				for k , contour in pairs(contours) do 
					local hash = pointHash2d(contour.p)
					contour.hash = hash
					if not hashToContourMap[hash] then 
						hashToContourMap[hash]= {}
					end 
					table.insert(allContours, contour)
					contour.id = #allContours
					table.insert(hashToContourMap[hash], contour)
				end
			end
		end
	
	end, api.type.ComponentType.WATER_MESH)
	
	for hash, contours in pairs(hashToContourMap) do 
		if #contours > 1 then 
			--trace("Found point with contours>1",#contours )
			while #contours > 2 do 
				trace("Found a contour with multiple",#contours)
				local wasRemoved = false 
				for i, contour in pairs(util.shallowClone(contours)) do 
					trace("Contours found at",i,contourToString(contour))
					local mesh = util.getComponent(contour.mesh, api.type.ComponentType.WATER_MESH)
					if #mesh.indices==0 then 
						trace("Removing contour at ",i)
						table.remove(contours, i)
						wasRemoved = true 
						break
					end 
				end 
				if not wasRemoved then 
					trace("WARNING! Unable to remove")
					table.remove(contours)
					break 
				end
			end 
			
			-- assert(#contours==2)
			local contour1 = contours[1]
			local contour2 = contours[2]
			if contour1.index == 1 then 
				local expectedMesh = util.getRiverMeshContours(contour1.mesh)[contour1.contour][contour1.index+1]
				--assert(contour2.nextContour == nil or contour2.nextContour == expectedMesh)
				contour2.nextContour =expectedMesh
			--	assert(contour1.nextContour == contour2.nextContour)
				for i, contour in pairs(util.getRiverMeshContours(contour1.mesh)[contour1.contour]) do 
					contour.priorMesh = contour2.mesh
				end 
			else 
				local expectedMesh =util.getRiverMeshContours(contour1.mesh)[contour1.contour][contour1.index-1]
				if contour2.priorContour ~= nil then 
					printContourDetails(contour1, contour2, expectedMesh)
				end 
--				assert(contour2.priorContour == nil or contour2.priorContour == expectedMesh)
				contour2.priorContour = util.getRiverMeshContours(contour1.mesh)[contour1.contour][contour1.index-1]
			--	assert(contour1.priorContour == contour2.priorContour)
				for i, contour in pairs(util.getRiverMeshContours(contour1.mesh)[contour1.contour]) do 
					contour.nextMesh = contour2.mesh
				end 
			end 			
			if contour2.index == 1 then 
				local expectedMesh = util.getRiverMeshContours(contour2.mesh)[contour2.contour][contour2.index+1]
				if contour1.nextContour ~= nil then 
					printContourDetails(contour1, contour2, expectedMesh)
				end 
			--	assert(contour1.nextContour == nil or contour1.nextContour == expectedMesh)
				contour1.nextContour = expectedMesh
			--	assert(contour1.nextContour == contour2.nextContour)
				for i, contour in pairs(util.getRiverMeshContours(contour2.mesh)[contour2.contour]) do 
					contour.priorMesh = contour1.mesh
				end 
				
			else 
				local expectedMesh = util.getRiverMeshContours(contour2.mesh)[contour2.contour][contour2.index-1]
				
				if expectedMesh ~= contour2.priorContour then 
					printContourDetails(contour1, contour2)
				end 
			--	assert(contour1.priorContour==nil or expectedMesh == contour1.priorContour)
				contour1.priorContour = expectedMesh
			--	 assert(contour1.priorContour == contour2.priorContour)
				for i, contour in pairs(util.getRiverMeshContours(contour2.mesh)[contour2.contour]) do 
					contour.nextMesh = contour1.mesh
				end 
				--contour1
			end 			
		end 
	end 
	trace("util.buildContourToMeshMap complete")
	local contourGroups = {}
	local nextGroupId = 1
	local alreadySeen = {}
	local function findAllConnectedContours(contour)
		if alreadySeen[contour.hash] then 
			return 
		end 
		alreadySeen[contour.hash] = true 
		 
		for j, contour2 in pairs({contour.priorContour, contour.nextContour}) do 
			local otherHash = contour2.hash 
			contour2.group = nextGroupId
			if not contourGroups[otherHash] then 
				contourGroups[otherHash] = nextGroupId 
				
				findAllConnectedContours(contour2 ) 
			end 
		end
	end
		

	for i, contour  in pairs(allContours) do 
		if not alreadySeen[contour.hash] then 
			contourGroups[contour.hash] = nextGroupId 
			contour.group = nextGroupId
			findAllConnectedContours(contour )
			nextGroupId = nextGroupId + 1 
	 
		end 		
	end  
	
	for i, contour  in pairs(allContours) do 
		if not contour.group then -- there are two that overlap at the boundary
			contour.group =  contour.nextContour and contour.nextContour.group or contour.priorContour and contour.priorContour.group 
			trace("Found a nil group, correcting to ",contour.group)
			if not contour.group then 
				--debugPrint({contour=contour}) -- NB need to be careful with this as it may contain a complete linked list
				--debugPrint({contour={p=contour.p, mesh=contour.mesh}})
				
				--error("No contour group")
			end 
		end 
	end 
	util.contourGroups = contourGroups
	util.allContours = allContours
	trace("Gathered contourgroups there were",nextGroupId,"distinct groups from",#allContours)
	buildContourToMeshMapAlreadyCalled = true 
	--return contourToMeshMap
	return util.contourGroups
end 
util.cachedMeshPositions = {}
function util.getMeshPostion(mesh) 
	if util.cachedMeshPositions[mesh] then 
		return util.cachedMeshPositions[mesh]
	end
	local meshComp = util.getComponent(mesh, api.type.ComponentType.WATER_MESH)
	local p = { x=meshComp.pos.x*256+128 , y=meshComp.pos.y*256 +128}
	util.cachedMeshPositions[mesh]=p 
	return p
end 
 
function util.isWaterMeshOnSameCoast(mesh, p) -- TODO need to refine this 
	for j, contours in pairs(util.getRiverMeshContours(mesh)) do 
		for k , contour in pairs(contours) do 
			if not util.isWaterContourMeshOnSameCoast(contour ,p) then 
				return false 
			end
		end 
	end
	return true 	
end
function util.isWaterContourMeshOnSameCoast(vertex, p) --TODO need to refine to identify the common coast
	util.buildContourToMeshMap() 
	--local pMid = 0.5*(vertex.p+p)
	local range = util.distance(vertex.p,p)
	
	local meshOptions = {} 
	local options = {}
	local p3 = p 
	--local p4 =   vertex.p -- 10*vertex.t
	local p4 =   vertex.p + 10*vertex.t
	local pMid = 0.5*(p3+p4)
	local meshes = util.getRiverMeshEntitiesInRange(pMid, range )
	--[[for i, mesh in pairs(meshes) do 
		trace("Inspecting mesh",mesh,"count contours?",#util.getRiverMeshContours(mesh),"at i=",i)
		if #util.getRiverMeshContours(mesh) > 0 and #util.getRiverMeshContours(mesh)[1] > 0 then 
			trace("Insering meshoption at",mesh)
			table.insert(meshOptions, {mesh=mesh, scores = { vec2.distance(p3, util.getMeshPostion(mesh)) } })
		end 
	end 
	trace("Num meshoptions was",#meshOptions)
	if #meshOptions==0 then 
		return
	end 
	local meshes = { util.evaluateWinnerFromScores(meshOptions).mesh }]]--
	--[[local ourMesh  = util.indexOf(meshes, vertex.mesh)
	if ourMesh ~= -1 then 
		table.remove(meshes, ourMesh)
	end ]]--
	trace("Looking for in a total of",#meshes)
	--local p5 = p - range*vec3.normalize(t)
	local collisionCount = 0
	for i, mesh in pairs(meshes) do 
		--trace("getNearestVirtualRiverMeshContour: Inspecting mesh",mesh)
		for j, contours in pairs(util.getRiverMeshContours(mesh)) do 
			--trace("getNearestVirtualRiverMeshContour: Inspecting contour at",j)
			if contours[1].group == vertex.group then 
				--trace("Skipping check as belong to same group")
				goto continue
			end 
			local contours2 = util.shallowClone(contours)
			if contours2[1].priorContour then 
				--trace("inserting the prior mesh point at dist",vec2.distance(contours2[1].p, contours2[1].nextContour.p))
				table.insert(contours2, 1, contours2[1].priorContour )
			else 
				--trace("WARNING! No other mesh point found at ",contours2[1].p.x,contours2[1].p.y)
			end  
			if contours2[#contours2].nextContour then 
				--trace("inserting the next mesh point at a dist",vec2.distance(contours2[#contours2].p, contours2[#contours2].nextContour.p))
				table.insert(contours2, 1, contours2[#contours2].nextContour)
			else 
				--trace("WARNING! No other mesh point found at ",contours2[#contours2].p.x,contours2[#contours2].p.y)
			end 
			
			for k = 2, #contours2 do
				local p1 = contours2[k-1].p
				local p2 = contours2[k].p
				local t1 = contours2[k-1].t
				local t2 = contours2[k].t
				local c = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4) 
				--local c2 = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p5)
				if c then 
					--local tc = vec3.normalize(vec2.distance(c, p1)*t1 + vec2.distance(c, p2)*t2)
					 
					--local dist = vec2.distance(p, c)
					--local virtualContour = {p = vec3.new(c.x, c.y, p1.z), t = tc, mesh=mesh, contour=j, index=k, angle=angle,distance=dist } 
					collisionCount = collisionCount + 1
					--trace("Angle to t was",math.deg(angle))
					--[[table.insert(options, {
						 
						contour = virtualContour,
					 
					})]]--
				end 
				--[[if c2 then 
					local c = c2
					local tc = vec3.normalize(vec2.distance(c, p1)*t1 + vec2.distance(c, p2)*t2)
					local angle = util.signedAngle(tc, t)
					local virtualContour = {p = vec3.new(c.x, c.y, p1.z), t = tc, mesh=mesh, contour=j, index=k, angle=angle} 
					
					trace("c2 Angle to t was",math.deg(angle))
					table.insert(options, {
						angle = angle, 
						contour = virtualContour,
						scores = { vec2.distance(p, c)}
					})
				end ]]--
			end
			
			::continue::
		end 
	end 
	if util.tracelog then 
		--debugPrint({nearestMeshes = options})
	end 
--	trace("The collision count was",collisionCount)
	if collisionCount > 0 then 
		trace("Rejecting the vertex on group",vertex.group,"at",vertex.p.x,vertex.p.y,"as not on the same coast as",p.x,p.y)
	end 
	return collisionCount == 0
end   

function util.getClosestWaterContours(entity, range)
	local result = {}
	local entityComp = game.interface.getEntity(entity)
	 util.buildContourToMeshMap() 
	local p = util.v3fromArr(entityComp.position)
	local checkedContourGroups = {}
	for i, mesh in pairs(util.getRiverMeshEntitiesInRange(entityComp.position, range )) do 
		for j, contours in pairs(util.getRiverMeshContours(mesh)) do 
			for k, vertex in pairs(contours) do 
				if util.distance(vertex.p, p) <= range then 
					if vertex.group then -- TODO determine if this is a bug
						if checkedContourGroups[vertex.group] == nil then 
							checkedContourGroups[vertex.group]= util.isWaterContourMeshOnSameCoast(vertex, p)
						end 
						if checkedContourGroups[vertex.group] then 
							table.insert(result, vertex)
						end 
					end
				end 
			end 
		end 
	end 
	
	
	return result

end 

function util.safeCloneContours(contours)
	local res = {}
	for i, contour in pairs(contours) do 
		table.insert(res, util.safeCloneContour(contour))
	end 
	return res
end
function util.safeCloneContour(contour)
	return util.deepClone(contour, function(v) -- remove the  links to prevent stackoverflow
		--trace("safeCloneContour, got v",v,"type?",type(v))
		if v and type(v)=="table" and v.isRiverMeshContour then 
			return nil 
		end 
		return v
	end)
end 
function util.getNearestVirtualRiverMeshContour(p, t, range)
	if not range then range = 256 end
	util.buildContourToMeshMap() 
	local meshes = util.getRiverMeshEntitiesInRange(p, range )
	local meshOptions = {} 
	local options = {}
	local p3 = p 
	local p4 = p + range*vec3.normalize(t)
	local pMid = 0.5*(p3+p4)
	for i, mesh in pairs(meshes) do 
		trace("Inspecting mesh",mesh,"count contours?",#util.getRiverMeshContours(mesh),"at i=",i)
		if #util.getRiverMeshContours(mesh) > 0 and #util.getRiverMeshContours(mesh)[1] > 0 then 
			trace("Insering meshoption at",mesh)
			table.insert(meshOptions, {mesh=mesh, scores = { vec2.distance(p3, util.getMeshPostion(mesh)) } })
		end 
	end 
	--trace("Num meshoptions was",#meshOptions)
	if #meshOptions==0 then 
		return
	end 
	-- can't do this optimisation it misses some points
	--local meshes = { util.evaluateWinnerFromScores(meshOptions).mesh }
	
	local p5 = p - range*vec3.normalize(t)
	for i, mesh in pairs(meshes) do 
		--trace("getNearestVirtualRiverMeshContour: Inspecting mesh",mesh)
		for j, contours in pairs(util.getRiverMeshContours(mesh)) do 
			--trace("getNearestVirtualRiverMeshContour: Inspecting contour at",j)
			local contours2 = util.shallowClone(contours)
			if contours2[1].nextContour then 
				--trace("inserting the prior mesh point at dist",vec2.distance(contours2[1].p, contours2[1].nextContour.p))
				table.insert(contours2, 1, contours2[1].nextContour )
			else 
				--trace("WARNING! No other mesh point found at ",contours2[1].p.x,contours2[1].p.y)
			end  
			if contours2[#contours2].nextContour then 
				--trace("inserting the next mesh point at a dist",vec2.distance(contours2[#contours2].p, contours2[#contours2].nextContour.p))
				table.insert(contours2, 1, contours2[#contours2].nextContour)
			else 
				--trace("WARNING! No other mesh point found at ",contours2[#contours2].p.x,contours2[#contours2].p.y)
			end 
			
			for k = 2, #contours2 do
				local p1 = contours2[k-1].p
				local p2 = contours2[k].p
				local t1 = contours2[k-1].t
				local t2 = contours2[k].t
				local c = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p4) 
				local c2 = util.checkFor2dCollisionBetweenPoints(p1, p2, p3, p5)
				if c then 
					local tc = vec3.normalize(vec2.distance(c, p1)*t1 + vec2.distance(c, p2)*t2)
					local angle = util.signedAngle(tc, t)
					local dist = vec2.distance(p, c)
					local virtualContour = {p = vec3.new(c.x, c.y, p1.z), t = tc, mesh=mesh, contour=j, index=k, angle=angle,distance=dist } 
					
					--trace("Angle to t was",math.deg(angle))
					table.insert(options, {
						angle = angle,
						contour = virtualContour,
						scores = { dist}
					})
				end 
				--[[if c2 then 
					local c = c2
					local tc = vec3.normalize(vec2.distance(c, p1)*t1 + vec2.distance(c, p2)*t2)
					local angle = util.signedAngle(tc, t)
					local virtualContour = {p = vec3.new(c.x, c.y, p1.z), t = tc, mesh=mesh, contour=j, index=k, angle=angle} 
					
					trace("c2 Angle to t was",math.deg(angle))
					table.insert(options, {
						angle = angle, 
						contour = virtualContour,
						scores = { vec2.distance(p, c)}
					})
				end ]]--
			end
			
			
		end 
	end 
	if util.tracelog then 
		--debugPrint({nearestMeshes = options})
	end 
	if #options == 0 then 
		return 
	end 	
	return util.evaluateWinnerFromScores(options).contour
end  
function util.printContorMeshDetails(mesh) 
	local meshComp = util.getComponent(mesh, api.type.ComponentType.WATER_MESH)
	for i , contour in pairs(meshComp.contours) do 
		for j, vertex in pairs(contour.vertices) do 
			if j > 1 then 
				trace("Dist to las mesh=",vec2.distance(vertex, contour.vertices[j-1]))
			end 
		end 
	end 
end 
function util.printAllContorMeshDetails( ) 
	local minDist = math.huge 
	local maxDist = 0
	local total = 0 
	local samples = 0
	api.engine.forEachEntityWithComponent(function(mesh) 
	
		local meshComp = util.getComponent(mesh, api.type.ComponentType.WATER_MESH)
		for i , contour in pairs(meshComp.contours) do 
			for j, vertex in pairs(contour.vertices) do 
				if j > 1 then 
					local dist = vec2.distance(vertex, contour.vertices[j-1])
					trace("Dist to las mesh=",dist )
					minDist = math.min(minDist, dist)
					maxDist=  math.max(maxDist, dist) 
					total = dist + total 
					samples = samples + 1 
				end 
			end 
		end 
	end, api.type.ComponentType.WATER_MESH)
	trace("The minDist was",minDist,"the maxDist was ",maxDist,"total=",total,"samples=",samples,"average=",(total/samples))
end 

function util.getRiverMeshInRange(position, range, minDist)
	if not minDist then minDist = 0 end
	if position.x and position.y then 
		position = { position.x, position.y , position.z} 
	end
	local v3pos =  util.v3fromArr(position)
	local result = {}
	for i, mesh in pairs(util.getRiverMeshEntitiesInRange(position, range )) do
		--local waterMesh = util.getComponent(mesh, api.type.ComponentType.WATER_MESH)
		--local foundVerticies = false 
		--[[for j, contour in pairs(waterMesh.contours) do
			for k, point in pairs(contour.vertices) do 
				local v2point = vec3.new(point.x, point.y,0)
				local distance = vec2.distance(v3pos, v2point)
				if distance<=range and distance>=minDist then
					foundVerticies = true 
					local normal  =contour.normals[k]
					table.insert(result, {p = v2point, t = vec3.new(normal.x, normal.y,0), mesh=mesh, contour=j, index=k})
				end
			end
		end--]]
			for j, contours in pairs(util.getRiverMeshContours(mesh)) do 
				for k, contour in pairs(contours) do 
					local distance = vec2.distance(v3pos, contour.p)
					if distance<=range and distance>=minDist then
						table.insert(result, contour)
					end
				end 
			end
		--trace("Inspecting mesh",mesh,"foundVerticies?",foundVerticies,"range=",range,"minDist=",minDist)
	end

	return result 
end

function util.getClosestWaterVerticies(position, range, minDist, filterFn)
	if not range then 
		range = 150 
	end
	if not filterFn then filterFn = function() return true end end 
	local vertices = util.getRiverMeshInRange(position, range, minDist)
	--local dists = {}
	--local distsToVertexMap = {}
	local v3pos = position.x and util.v3(position) or util.v3fromArr(position)
	local options = {}
	for i, vertex in pairs(vertices) do
		
		if filterFn(vertex) then 
		--	local dist = vec2.distance(v3pos, vertex.p)
			--while distsToVertexMap[dist] do
			--	dist = dist + 0.01
			--end
			--table.insert(dists, dist)
			--distsToVertexMap[dist]=vertex
			table.insert(options, vertex)
		end
		
	end
	trace("getClosestWaterVerticies: found",#options)
	if #options == 0 then 
		--trace("No dists were found")
		return 
	end
	
	--table.sort(dists)
	--local result = {}
	--for i = 1, #dists do 
		--table.insert(result, distsToVertexMap[dists[i]])
	--end--]]--
	
	return util.evaluateAndSortFromSingleScore(options, function(vertex) return vec2.distance(v3pos,vertex.p) end)
	
	--return result
end
function util.distanceToNearestWaterVertex(p)
	local nearestVerticies = util.getClosestWaterVerticies(p)
	if nearestVerticies then
		local result= vec2.distance(p, nearestVerticies[1].p)
		--trace("Dist to nearest water vertext was ",result)
		return result
	end
	--trace("No water verticies found in range")
	return math.huge
end

function util.getRiverMeshEntitiesInRange(position, range )
	--	--collectgarbage() -- seems to be necessary to prevent random crashing
	
	local tileSize = 256
	if not range then 
		range = 256
	end
	if position.x and position.y then 
		position = { position.x, position.y , position.z} 
	end
	if range == math.huge then -- doesnt like this
		range = 2^16
	end
	if position[1]~=position[1] or position[2]~=position[2] then 
		debugPrint(position)
		error("NaN position provided")
	end 
	--debugPrint({range=range, position=position})
	local xLow= math.floor((position[1]-range)/tileSize)-1
	local xHigh = math.ceil((position[1]+range)/tileSize)+1
	local yLow = math.floor((position[2]-range)/tileSize)-1
	local yHigh = math.ceil((position[2]+range)/tileSize)+1
	trace("getting river mesh entities using",xLow,yLow,xHigh,yHigh)
	local tile0 = api.type.Vec2i.new(xLow, yLow)
	local tile1 = api.type.Vec2i.new(xHigh, yHigh)
	if util.tracelog then 
		--debugPrint({getRiverMeshEntitiesInRange = position, tile0=tile0, tile1=tile1,range=range})
	end 
	return util.deepClone(api.engine.system.riverSystem.getWaterMeshEntities(tile0,tile1))
end 

util.displays = {}
 
function util.displayWaterMeshGroups() 
	local waterMeshDrawn =0
	for meshId, groupId  in pairs(util.getWaterMeshGroups() ) do 
		local waterMesh = util.getComponent(meshId, api.type.ComponentType.WATER_MESH)
		local polygon = {}
		local polygon2 = {}
		for j, contour in pairs(waterMesh.contours) do
			for k, point in pairs(contour.vertices) do 
				--local v2point = vec3.new(point.x, point.y,0)
			 
					table.insert(polygon, { point.x, point.y})
				   
			end
		end
		
		for j, point in pairs(waterMesh.vertices) do
		 
				--local v2point = vec3.new(point.x, point.y,0)
				 
			 
					table.insert(polygon2, { point.x, point.y})
				 
			 
		end
		print("Water mesh at",waterMesh.pos.x,waterMesh.pos.y, " for mesh",meshId)
		local name = "ai_builder_river_mesh"..tostring(#util.displays)
	 
		table.insert(util.displays, name)
		local colourIdx = 1 + groupId % #game.config.gui.lineColors
		--trace("Colouridx=",colourIdx)
		local colour = game.config.gui.lineColors[colourIdx]
		--local drawColour = { colour[1]*255, colour[2]*255, colour[3]*255, 1} 
		local drawColour = { colour[1], colour[2], colour[3], 1} 
		game.interface.setZone(name, {
			polygon=polygon,
			draw=true,
			drawColor = drawColour,
		})
		local name = "ai_builder_river_mesh2"..tostring(#util.displays)
		drawColour[4] = 0.5
		 
		table.insert(util.displays, name)
		game.interface.setZone(name, {
			polygon=polygon2,
			draw=true,
			drawColor = drawColour,
		})
	end
end 
function util.areVerticiesInSameGroup(vertex1,vertex2)
	if vertex1.group == vertex2.group then 
		return true 
	end 
	local mesh1 = vertex1.mesh 
	local mesh2 = vertex2.mesh 
	local meshGroups = util.getWaterMeshGroups() 
	return meshGroups[mesh1]==meshGroups[mesh2]
end 
function util.getContourGroupToContoursMap() 
	if util.contourGroupToContoursMap then 
		return util.contourGroupToContoursMap
	end 
	local map = {}
	util.buildContourToMeshMap()
	api.engine.forEachEntityWithComponent(function(mesh) 
		for j, contours in pairs(util.getRiverMeshContours(mesh)) do 
			for k , contour in pairs(contours) do 
				local group = contour.group 
				if group then 
					if not map[group] then 
						map[group] = {}
					end 
					table.insert(map[group], contour)
				end 
			end 
		end
	
	end, api.type.ComponentType.WATER_MESH)
	util.contourGroupToContoursMap = map 
	return map
end 

local function drawContours(map)
	util.buildContourToMeshMap()
	for groupId, contours in pairs(map) do
		local polygon = {}
		for j, point in pairs(contours) do
			--for k, point in pairs(contour.vertices) do 
				--local v2point = vec3.new(point.x, point.y,0)
			 
					table.insert(polygon, { point.p.x, point.p.y})
				   
			--end
		end
		
	  
		local name = "ai_builder_river_mesh"..tostring(#util.displays)
	 
		table.insert(util.displays, name)
		local colourIdx = 1 + groupId % #game.config.gui.lineColors
		--trace("Colouridx=",colourIdx)
		local colour = game.config.gui.lineColors[colourIdx]
		--local drawColour = { colour[1]*255, colour[2]*255, colour[3]*255, 1} 
		local drawColour = { colour[1], colour[2], colour[3], 1} 
		game.interface.setZone(name, {
			polygon=polygon,
			draw=true,
			drawColor = drawColour,
		}) 
	end  
end

function util.displayWaterContourGroups()
	 
	api.engine.forEachEntityWithComponent(function(mesh) 
		local map = {}
		for j, contours in pairs(util.getRiverMeshContours(mesh)) do 
			
			for k , contour in pairs(contours) do 
				local group = contour.group 
				if group then 
					if not map[group] then 
						map[group] = {}
					end 
					table.insert(map[group], contour)
				end 
			end 
			
			
			
		end
		drawContours(map)
	end, api.type.ComponentType.WATER_MESH)
	 
end 

function util.clearDisplays() 
	for i, display in pairs(util.displays) do 
		game.interface.setZone(display)
	end 
	util.displays = {}
end 


return util