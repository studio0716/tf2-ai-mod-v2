local vec3 = require "vec3"
local streetutil = require "streetutil"
local util = require "ai_builder_base_util"
local ai_builder_interchange_util = {} 
local trace = util.trace
local highwayTypes = {"standard/country_medium_one_way_new.lua", "standard/country_large_one_way_new.lua"}
local roadtypes = { "standard/town_medium_new.lua", "standard/town_large_new.lua", "standard/town_x_large_new.lua"}
local function hypot(x,y)
	return math.sqrt(x*x+y*y)
end
local function computeDirectionVectorRad(rotation, lenx, leny)
	return vec3.new(math.abs(math.cos(rotation))*lenx, math.abs(math.sin(rotation))*leny,0)
end
local function computeDirectionVector(rotation, lenx, leny)
	return computeDirectionVectorRad(math.rad(rotation),lenx,leny)
end

function ai_builder_interchange_util.addArc(edges , startrotation, arcdegrees, p1, p2, t0z, t1z) 	
if not t0z then t0z = 0 end
if not t1z then t1z = 0 end

local deltax = p2.x-p1.x
local deltay = p2.y-p1.y

local circlefactor = (4 * (math.sqrt(2) - 1))*(math.abs(arcdegrees)/90)
local r = hypot(deltax, deltay)/(2*math.sin(math.rad(math.abs(arcdegrees/2))))

local lenx = deltax < 0 and -r * circlefactor or r * circlefactor
local leny = deltay < 0 and -r * circlefactor or r * circlefactor
local endrotation = arcdegrees + startrotation
local direction1 = computeDirectionVector(startrotation, lenx, leny)
local direction2 = computeDirectionVector(endrotation, lenx, leny) 

direction1.z = t0z*vec3.length(direction1)
direction2.z = t1z*vec3.length(direction2)
trace("direction1.z=",direction1.z,"direction2.z=",direction2.z)
streetutil.addEdge(edges, p1, p2, direction1, direction2)
end

local heights = {}
for i = -50, 50, 5 do
	table.insert(heights, tostring(i))
end

function ai_builder_interchange_util.addSplitArc2(leftedges, rightedges , startrotation, arcdegrees, p1, p2, z, tz) 
if not tz then tz =0 end
local deltax = p2.x-p1.x
local deltay = p2.y-p1.y

local splitangle =  arcdegrees/2
local r = hypot(deltax, deltay)/(2*math.sin(math.rad(math.abs(arcdegrees/2))))

local xorig = r * math.cos(math.rad(startrotation))
local yorig = r * math.sin(math.rad(startrotation))
local cosfactor =  deltay * (1-  math.cos(math.rad(math.abs(splitangle))))
local sinfactor = deltax * math.sin(math.rad(math.abs(splitangle)))

local xmid = p2.x - sinfactor
local ymid = p2.y -  cosfactor
if startrotation == 0 then
	xmid = p2.x - deltax * (1-  math.cos(math.rad(math.abs(splitangle))))
	ymid = p2.y - deltay * math.sin(math.rad(math.abs(splitangle)))

end

local endrotation = arcdegrees + startrotation


local p3 = vec3.new(xmid, ymid, z)

 ai_builder_interchange_util.addArc(leftedges, startrotation, splitangle, p1, p3, tz, 0 )
 ai_builder_interchange_util.addArc(rightedges, startrotation+splitangle, splitangle, p3, p2, 0, -tz)
 return p3
end

function ai_builder_interchange_util.addSplitArc(edges , startrotation, arcdegrees, p1, p2, z, tz) 
	return ai_builder_interchange_util.addSplitArc2(edges, edges , startrotation, arcdegrees, p1, p2, z, tz) 
end

function ai_builder_interchange_util.addSideRamp(rampedges , rampedgescenter, x1, y1, z1, x2,y2,z2, splitpoint)
local deltax = x2-x1
local deltay = y2-y1
local circlefactor = 4 * (math.sqrt(2) - 1) 

local lenx = deltax * circlefactor
local leny = deltay * circlefactor

local startrotation = math.abs(x1) < math.abs(y1) and  math.rad(90) or 0  

local direction1 = computeDirectionVectorRad(startrotation, lenx, leny) -- math.abs(x1) < math.abs(y1) and vec3.new(0,leny,0) or vec3.new(lenx,0,0)
local direction2 = math.abs(x1) < math.abs(y1) and vec3.new(lenx,0,0) or vec3.new(0,leny,0)


local splitangle =  math.rad(90)/splitpoint

local sinefactor = math.sin(splitangle) --  math.abs(math.sin(startrotation)-math.abs(math.sin(splitangle)))
local cosinefactor =  1-math.cos(splitangle) -- math.abs(math.cos(startrotation)-math.abs(math.cos(splitangle)))
local deltax1 = deltax * (startrotation == 0 and sinefactor or cosinefactor)
local deltay1 = deltay * (startrotation == 0 and cosinefactor or sinefactor)

local directionsplit1 = computeDirectionVectorRad(splitangle+startrotation, lenx/splitpoint, leny/splitpoint)

direction1 = computeDirectionVectorRad(startrotation, lenx/splitpoint, leny/splitpoint)
direction2 = computeDirectionVectorRad(startrotation+math.rad(90), lenx/splitpoint, leny/splitpoint)


streetutil.addEdge(rampedges, vec3.new(x1, y1,  z1), vec3.new( x1+deltax1,  y1+deltay1, z1), direction1, directionsplit1)


local deltax2 = deltax -deltax1 
local deltay2 = deltay - deltay1 
local directionsplit2 = computeDirectionVectorRad(math.rad(90)-splitangle+startrotation, lenx/splitpoint, leny/splitpoint)


local deltax2 = deltax * (startrotation ~= 0 and sinefactor or cosinefactor)
local deltay2 = deltay * (startrotation ~= 0 and cosinefactor or sinefactor)


 streetutil.addEdge(rampedges, vec3.new( x2-deltax2,  y2-deltay2, z2), vec3.new(x2,  y2, z2), directionsplit2, direction2)
 

 
 
 
local lenymid = (splitpoint-2)*leny / splitpoint
local lenxmid = (splitpoint-2)*lenx / splitpoint

streetutil.addEdge(rampedgescenter, vec3.new( x1+deltax1,  y1+deltay1, z1), vec3.new( x2-deltax2,  y2-deltay2, z2), 
	computeDirectionVectorRad(startrotation+splitangle, lenxmid, lenymid)
, computeDirectionVectorRad(math.rad(90)-splitangle+startrotation, lenxmid, lenymid))

end

function ai_builder_interchange_util.addSCurveX(edges, p1, p2)
	-- experimentation suggests best curve speed limit achieved by simply adding the x and y difference
	local lenx = math.abs(p2.x-p1.x) + math.abs(p2.y-p1.y)
	if p2.x < p1.x then
		lenx = -lenx
	end
 
	local direction = vec3.new(lenx, 0, 0)
	streetutil.addEdge(edges,p1,p2, direction, direction)
end
function ai_builder_interchange_util.addSCurveY(edges, p1, p2)
	-- experimentation suggests best curve speed limit achieved by simply adding the x and y difference
	local leny = math.abs(p2.x-p1.x) + math.abs(p2.y-p1.y)
	if p2.y < p1.y then
		leny = -leny
	end
 
	local direction = vec3.new(0, leny, 0)
	streetutil.addEdge(edges,p1,p2, direction, direction)
end
function ai_builder_interchange_util.addStraightEdges(edges, p1, p2, p3, p4)
	streetutil.addStraightEdge(edges, p1, p2)
	streetutil.addStraightEdge(edges, p2, p3)
	streetutil.addStraightEdge(edges, p3, p4)
end

local function reverseTangent(edge, edge2)
	for i=1,3 do
		edge[2][i]=-edge[2][i]
	end
	-- subtlety - the neighbouring edges may be sharing the same table, so only reverse if it is different
	if edge2[2] ~= edge[2] then
		for i=1,3 do
			edge2[2][i]=-edge2[2][i]
		end
	end
end
local function reverseEdge(edges, i)
	local temp = edges[i]
	edges[i]=edges[i+1]
	edges[i+1]=temp
	reverseTangent(edges[i],edges[i+1])
end
function ai_builder_interchange_util.reverseAllEdges(result)
	for _,edgeList in pairs(result.edgeLists) do
		local snapnodesLookup = {} 

		for k,v in pairs(edgeList.snapNodes) do
			snapnodesLookup[v+1]=k
		end
		for i=1 ,#edgeList.edges, 2 do 
			reverseEdge(edgeList.edges,i) 
			if snapnodesLookup[i]~= nil then
				edgeList.snapNodes[snapnodesLookup[i]]=i
			end
			if snapnodesLookup[i+1]~= nil then
				edgeList.snapNodes[snapnodesLookup[i+1]]=i-1
			end
		end

	end
end

function ai_builder_interchange_util.applySpecialArgs(params, result)
	if params.trafficside == 1 then
		ai_builder_interchange_util.reverseAllEdges(result)
	end
	if params.special then 
		params.aiBuilderInterchangeSpecial = params.special
	end 
	if params.aiBuilderInterchangeSpecial == 1 then 
		for _,edgeList in pairs(result.edgeLists) do
			 edgeList.edgeType = "BRIDGE"
			 edgeList.edgeTypeName = "cement.lua"
		end
	end
	if params.aiBuilderInterchangeSpecial == 2 then 
		for _,edgeList in pairs(result.edgeLists) do
			 edgeList.edgeType = "TUNNEL"
			 edgeList.edgeTypeName = "street_old.lua" 
		end
	end
end
function ai_builder_interchange_util.getHeight(params)
	return 5*(params.vanillahiwayheight-10)
end
function ai_builder_interchange_util.getCentral(params)
	-- can't use, no access to streetTypeRep, have to hard code
	--local roadType = ai_builder_interchange_util.getRoadType(params)
	--local streetWidth = util.getStreetWidth(streetType)
	local laneCount = params.aiBuilderInterchangeLaneCount+4
	local streetWidth = laneCount * 4
	return (5+streetWidth) / 2
end
function ai_builder_interchange_util.getRoadType(params)
	return highwayTypes[params.aiBuilderInterchangeLaneCount + 1]
end
function ai_builder_interchange_util.getRoadTypeRamp(params)
	return  "standard/country_small_one_way_new.lua"  
end
function ai_builder_interchange_util.getConnectingRoadType(params)
	return roadtypes[params.aiBuilderInterchangeConnectRoad]
end
function ai_builder_interchange_util.addSplitRamp(edges1, edges2, p1, p2)
	local deltax = p2.x - p1.x
	local deltay = p2.y - p1.y
	local deltaz = p2.z - p1.z
	
	local p3 = vec3.new(p1.x+deltax/2, p1.y+deltay/2, p1.z+deltaz/2)
	local directionmid = vec3.new(deltax/2,deltay/2, deltaz/2)
	local directionend = vec3.new(deltax/2,deltay/2, 0)
	streetutil.addEdge(edges1, p1, p3, directionend, directionmid)
	streetutil.addEdge(edges2, p3, p2, directionmid, directionend)
end
function ai_builder_interchange_util.getHeightOffset(params) 
	return heights[params.aiBuilderHighwayHeight+1]
end 

function util.getTailRoadType(params) 
	return highwaysByLaneCount[params.stackinterchangelanes+2]
end
function ai_builder_interchange_util.findSnapNodes(edgeList, otherEdgeLists)
	local positions = {}
	for i=1 ,#edgeList do 
		local p = edgeList[i][1]
		local x = p[1]
		local y = p[2]
		local z = p[3]
		local positionHash = math.floor(x)+1000*math.floor(y)+1000*1000*math.floor(z)
		if not positions[positionHash] then 
			positions[positionHash] = { idx = i, count = 1}
		else 
			positions[positionHash].count = positions[positionHash].count + 1
		end 
	end
	for j = 1, #otherEdgeLists do 
		local edgeList = otherEdgeLists[j].edges
		--debugPrint(edgeList)
		--print("Inspecting other edgelist they had",#edgeList)
		for i=1 ,#edgeList do 
			local p = edgeList[i][1]
			local x = p[1]
			local y = p[2]
			local z = p[3]
			local positionHash = math.floor(x)+1000*math.floor(y)+1000*1000*math.floor(z)
			print("positionHash was ",positionHash)
			if not positions[positionHash] then 
				--positions[positionHash] = { idx = i, count = 1}
			else 
				positions[positionHash].count = positions[positionHash].count + 1
			end 
		end
	end
		
 
	local result = {}
	for positionHash, detail in pairs(positions) do 
		if detail.count == 1 then 
			table.insert(result, detail.idx-1)
		end 
	end 
	--debugPrint({edgeList=edgeList, result=result, positions=positions})
	return result

end
function ai_builder_interchange_util.commonParams()
	

	return {
		{
			key = "aiBuilderInterchangeSize",
			name = _("Size"),
			values = { _("SMALL"), _("MEDIUM"), _("LARGE") },
			defaultIndex = 0,
			yearFrom = 1850,
			yearTo = 0
		},
		{
			key = "aiBuilderInterchangeLaneCount",
			name = _("Lane count"),
			values = { _("2"), _("3") },
			defaultIndex = 1,
			yearFrom = 1850,
			yearTo = 0
		},
		{
			key = "aiBuilderHighwayHeight",
			name =	_("Hiway height offset"),
			uiType = "SLIDER",
			values = heights,
			defaultIndex = 10,
			yearFrom = 1850,
			yearTo = 0
		},
		{
			key = "aiBuilderInterchangeLevel",
			name =	_("Highway level"),
			values = {  _('GROUND'),  _('ELEVATED'), _('UNDERGROUND')},
			defaultIndex = 1,
			yearFrom = 1850,
			yearTo = 0
		},
		{
			key = "aiBuilderInterchangeSpecial",
			name =	_("Special treatement"),
			values = { _('NONE'), _('ALL BRIDGES'), _('ALL TUNNELS')},
			defaultIndex = 0,
			yearFrom = 1850,
			yearTo = 0
		},
		{
			key = "aiBuilderInterchangeConnectRoad",
			name =	_("Connecting road"),
			values = { _("NONE"), _("2 lane road"), _("4 lane road"), _("6 lane road") },
			defaultIndex = 1,
			yearFrom = 1850,
			yearTo = 0
		},
	--[[	 {
			key = "trafficside",
			name =	_("Traffic side?"),
			values = {   _("RIGHT"),  _("LEFT"),  },
			defaultIndex = 0,
			yearFrom = 1850,
			yearTo = 0
		},
		{
			key = "Central",
			name =	_("Central Reservation Gap"),
			values = { _("Tight"), _("Normal") },
			defaultIndex = 1,
			yearFrom = 1850,
			yearTo = 0
		},]]--
	}
end
function ai_builder_interchange_util.defaultParams()
	local result = {}
	for i , param in pairs(ai_builder_interchange_util.commonParams()) do 
		result[param.key]=param.defaultIndex
	
	end 
	return result
	
end 
return ai_builder_interchange_util