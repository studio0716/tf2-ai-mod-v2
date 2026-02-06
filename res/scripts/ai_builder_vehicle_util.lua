local util = require("ai_builder_base_util") 
local paramHelper = require("ai_builder_base_param_helper")
local pathFindingUtil = require("ai_builder_pathfinding_util")
local profiler = require("ai_builder_profiler")
local vehicleUtil = {}
vehicleUtil.VERSION = "2026.01.04_throughput_fix"  -- For mod verification
local trace = util.trace
local reportInconsistent = false
local debugResults = util.tracelog and false
local climate
local g = 9.8
local twentyMinutes = 20*60 
local climateRestrictionsInForce
local function discoverClimate() 
	-- game.config references the default, not the current climate. Not sure about api.res.getGameConfig() this may reference the saved game climate
	for i, fileName in pairs(api.res.autoGroundTexRep.getAll()) do
		if string.find(fileName, "usa") then
			climate = "usa" 
			break
		end
		if string.find(fileName, "tropical") then
			climate = "asia" 
			break
		end
	end
	if not climate then
		climate = "europe"
	end
	climateRestrictionsInForce = true 
	for __, name in pairs(api.res.multipleUnitRep.getAll()) do -- for some reason the muRep seems to be prefiltered, not the model rep
		if climate == "usa" and string.find(name, "asia/") then 
			climateRestrictionsInForce  = false
			break 
		elseif climate == "asia" and string.find(name, "usa/") then 
			climateRestrictionsInForce = false 
			break 
		elseif climate == "europe" and (string.find(name, "usa/") or string.find(name, "asia/")) then 
			climateRestrictionsInForce = false 
			break
		end
	end
	trace("Climate was ", climate," climateRestrictionsInForce=",climateRestrictionsInForce)
end
local function isElectricTrain(transportModes) 
	local mode =  api.type.enum.TransportMode.ELECTRIC_TRAIN + 1 
	return transportModes[mode]==1
end
 

local function getTypeFromMode(transportModes)
	if type(transportModes)=="string" then
		return transportModes
	end
	local TransportMode = api.type.enum.TransportMode
	for i, v in pairs(transportModes) do
		if type(i)=="string" then
			debugPrint({transportModes=transportModes}) 
			print(debug.traceback())
		end 
		local mode = i-1
		if v == 1 then
			if mode == TransportMode.BUS then 
				return "bus"
			elseif mode == TransportMode.TRUCK then
				return "truck"
			elseif mode == TransportMode.TRAIN or mode == TransportMode.ELECTRIC_TRAIN then
				return "train"
			elseif mode == TransportMode.SHIP or mode == TransportMode.SMALL_SHIP then
				return "ship"
			elseif mode == TransportMode.AIRCRAFT or mode == TransportMode.SMALL_AIRCRAFT then
				return "plane"
			elseif mode == TransportMode.TRAM or mode == TransportMode.ELECTRIC_TRAM then
				return "tram"
			else 
				trace("unsupported transport type",mode)
			end
		end
	end
	trace("WARNING! No matching vehicles found")
end
local alwaysAllow = { -- annoying there doesn't seem to be a way to access the vehicle set from the api
	["vehicle/truck/opel_blitz_1930.mdl"]=true ,
	["vehicle/truck/opel_blitz_tanker.mdl"]=true,
	["vehicle/truck/opel_blitz_tipper.mdl"]=true,
	["vehicle/truck/opel_blitz_1930_tanker.mdl"]=true,
	["vehicle/truck/opel_blitz_1930_tipper.mdl"]=true,
	["vehicle/truck/opel_blitz_1930_universal.mdl"]=true,
	["vehicle/truck/benz1912_lkw.mdl"]=true,
	["vehicle/truck/benz1912_lkw_stake.mdl"]=true,
	["vehicle/truck/man_19_304_1970.mdl"]=true,
	["vehicle/truck/man_19_304_tanker.mdl"]=true,
	["vehicle/truck/man_19_304_tipper.mdl"]=true,
	["vehicle/truck/urban_etruck.mdl"]=true,
	 
	["vehicle/truck/asia/isuzu_elf_tld20_tanker.mdl"]=true, -- europe + usa confirmed
	["vehicle/truck/asia/isuzu_elf_tld20_universal.mdl"]=true,-- europe + usa confirmed
	["vehicle/truck/asia/faw_jiefang_j6p_stake.mdl"]=true,
	["vehicle/truck/asia/faw_jiefang_j6p_tanker.mdl"]=true,
	["vehicle/truck/asia/faw_jiefang_j6p_tipper.mdl"]=true,
	["vehicle/truck/asia/faw_jiefang_j6p_universal.mdl"]=true,

	
	-- buses 
	["vehicle/bus/ecitaro.mdl"]=true,
	["vehicle/bus/volvo_5000.mdl"]=true, -- allowed in USA need to check Asia
	["vehicle/bus/asia/maz_103.mdl"]=true, -- allowed in USA + Europe confirmed
} 

local asiaAllow = {  
	["vehicle/truck/40_tons.mdl"]=true ,
	["vehicle/truck/40_tons_stake.mdl"]=true,
	["vehicle/truck/40_tons_tanker.mdl"]=true, 
} 
local usaAllow = {  
	["vehicle/truck/asia/gaz_3307_tanker.mdl"]=true,
	["vehicle/truck/asia/gaz_3307_tipper.mdl"]=true,
	["vehicle/truck/asia/gaz_3307_universal.mdl"]=true,
} 


local function filterClimateOverride(name, vehicleType, model, climate)
	if climate == "all" then 
		return true 
	end
	local testName = string.gsub(name, "_v2.mdl",".mdl")
	if alwaysAllow[testName] then return true end
	if vehicleType == "ship" or vehicleType == "plane" then
		return true -- these do not have climate specific vehicles
	end
	
	if (vehicleType == "waggon" or vehicleType=="tram") and model and model.metadata and model.metadata.availability and model.metadata.availability.yearFrom >= 2000 and 
		(vehicleUtil.getCargoCapacity(model, "PASSENGERS") == 0 or vehicleType=="tram") then
		return true
	end
	if climate == "asia" and asiaAllow[testName] then 
		return true 
	end
	if climate == "usa" and usaAllow[testName] then 
		return true 
	end
	
	if climate == "europe" then
		return not string.find(name, "asia") and not string.find(name,"usa")
	else 
		return string.find(name, climate)
	end
end 

local function filterClimate(name, vehicleType, model)
	
	if not climate then
		discoverClimate() 
	end
	if not climateRestrictionsInForce then 
		return true
	end
	return filterClimateOverride(name, vehicleType, model, climate)
	
end
local function getMuTypeNames() 
	local result = {}
	for __, name in pairs(util.deepClone(api.res.multipleUnitRep.getAll())) do 
		local muType = api.res.multipleUnitRep.find(name)
		local muDetail = api.res.multipleUnitRep.get(muType)
		for ___, vehicle in pairs(muDetail.vehicles) do 
			if not result[vehicle.name] then 
				result[vehicle.name]=true 
			end 
		end 
	end 
	return result
end 

local subtitutions = {
	waggon_front = "middle1",
	waggon_mid = "middle2",
	waggon_back = "middle3",
	avelia_liberty_v2 = "avelia_liberty_front_v2",
	waggon = "middle1",
--	middle1 = "back",
	--middle3 = "front",
	fuxing_hao_middle3="fuxing_hao_middle1",
	alco_pa="alco_pa_front",
	alco_pb="alco_pb_back",
	speedance_express_wagon="speedance_express_middle1",
	speedance_express_v2 = "speedance_express_front_v2",
	metroliner_v2 = "metroliner_front_v2",
	["waggon/usa/amfleet"]="train/usa/metroliner_middle1",
}
local v2versions = {} 
local function getV2Version(vehicle, modelId)
	if v2versions[modelId] then 
		return v2versions[modelId]
	end
	local originalModelId = modelId
	local v2Version = string.gsub(vehicle.name, ".mdl","_v2.mdl")
	local testModelId = api.res.modelRep.find(v2Version)
	trace("Attempting to find v2 version from ",vehicle.name," using ",v2Version," success?",testModelId~=-1)
	local found = false 
	if testModelId ~= -1 then 	
		found = true
		modelId = testModelId 
	else 
		trace("Falling through to look at subtitutions")
		for k, v in pairs(subtitutions) do 
			local testv2Version = string.gsub(v2Version, k, v)
			local testModelId = api.res.modelRep.find(testv2Version)
			trace("Attempting to find v2 version from ",vehicle.name," using ",testv2Version," success?",testModelId~=-1)
			if testModelId ~= -1 then 	
				found = true
				modelId = testModelId
				break 
			end
		end
	end 
	if not found then 
		trace("WARNING! Unable to find v2 version for ",vehicle.name)
	end
	v2versions[originalModelId]=modelId
	return modelId
end 

local function getMultipleUnitTypes(params)
	if not params then params = {} end
	if params.banMu then return {} end
	if not vehicleUtil.muTypes then 
		local result  ={} 
		for __, name in pairs(util.deepClone(api.res.multipleUnitRep.getAll())) do 
			local muType = api.res.multipleUnitRep.find(name)
	
			local muDetail = api.res.multipleUnitRep.get(muType)
			local vehicleDetails = {}
			for ___, vehicle in pairs(muDetail.vehicles) do 
				local modelId = api.res.modelRep.find(vehicle.name)
				if not string.find(vehicle.name, "_v2.mdl") then -- try to use the v2 models if possible
					 modelId = getV2Version(vehicle, modelId)
				end 
				local model = api.res.modelRep.get(modelId)
				local isAsia = string.find(name, "asia/")
				local isUsa = string.find(name, "usa/")
				table.insert(vehicleDetails, {model=model, modelId=modelId,isAsia=isAsia, isUsa=isUsa, reversed = not vehicle.forward})
			end 
			table.insert(result, vehicleDetails)
 			
		end
		trace("multiple units found  ",#result)
		vehicleUtil.muTypes = result
	end
	local result = {}
	for i, muType in pairs(vehicleUtil.muTypes) do
		if muType[1].model and muType[1].model.metadata and util.filterYearFromAndTo(muType[1].model.metadata.availability) then
			local isOk = true 
			if params.vehicleRestriction == "usa"   then 
				isOk = muType.isUsa 
			end 
			if params.vehicleRestriction == "asia"   then 
				isOk =  muType.isAsia 
			end 
			if params.vehicleRestriction == "europe"   then 
				isOk = not muType.isAsia and not muType.isUsa
			end 
			if muType[2] and muType[2].model and muType[2].model.metadata then 
				if not util.filterYearFromAndTo(muType[2].model.metadata.availability) then -- HST power car is apparently available from 1850!
					isOk = false
				end 
			end 
			if isOk then 
				table.insert(result, muType)
			end
		end
	end
	return result	
end

local function firstNonNil(...)
	local args = table.pack(...)
    for i=1,args.n do
		if args[i] then
			return args[i]
		end
    end
end

local function initVehiclePart(params)
	local vehiclePart = api.type.TransportVehiclePart.new()
	vehiclePart.part.loadConfig={0}
	vehiclePart.autoLoadConfig={1} 
	vehiclePart.purchaseTime=util.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	if params and params.targetMaintenanceState then 
		vehiclePart.targetMaintenanceState = params.targetMaintenanceState
	else 
		vehiclePart.targetMaintenanceState = paramHelper.getParams().targetMaintenanceState
	end 
	return vehiclePart
end

vehicleUtil.initVehiclePart = initVehiclePart

local function getModelLengthx(model) 
	return model.boundingInfo.bbMax.x - model.boundingInfo.bbMin.x
end

local function getVehicleConfig(vehicle)
	return firstNonNil(vehicle.metadata.railVehicle, vehicle.metadata.roadVehicle, vehicle.metadata.waterVehicle, vehicle.metadata.airVehicle)
end

local function getVehicleMass(vehicle)
	return getVehicleConfig(vehicle).weight
end

local function getVehicleEngine(vehicle)
	local config = getVehicleConfig(vehicle)
	local engine = config.engine and config.engine or config.engines and config.engines[1]
	if not engine then 
		if config.availPower then 
			engine = { power = config.availPower, tractiveEffort = config.availPower } -- ship
		end
		if config.maxThrust then 
			engine = { power = config.maxThrust, tractiveEffort = config.maxThrust } -- plane
		end
	end
	return engine
end

local function getStandardTrackSpeed() 
	return api.res.trackTypeRep.get(api.res.trackTypeRep.find("standard.lua")).speedLimit
end
local function getHighSpeedTrackSpeed() 
	return api.res.trackTypeRep.get(api.res.trackTypeRep.find("high_speed.lua")).speedLimit
end
local function calculateDistanceToAccelerate(power, mass, speed)
	return ((1/3) * mass * speed^3)/power
end
local function calculateDistanceToAccelerateGradient(power, mass, speed, downHillForce )
	--https://physics.stackexchange.com/questions/389945/for-a-car-engine-why-does-velocity-increase-as-force-decreases
	return calculateDistanceToAccelerate(power, mass, speed)-(mass*speed^2 / 2*downHillForce)
end
local function calculateSpeedAtDistance(power, mass, distance)
	return (3*distance*power/mass)^(1/3)
end
local function calculateSpeedAtDistanceWithStartSpeed(power, mass, distance, startSpeed)
	-- https://www.wolframalpha.com/input?i2d=true&i=d%3DIntegrate%5B%5C%2840%29Divide%5Bmv%2Cp%5D%5C%2841%29v%2C%7Bv%2Ca%2Cb%7D%5D+solve+for+b
	return ((mass*startSpeed^3+3*distance*power)/mass)^(1/3)
end

local function calculateDistanceToAccelerateDelta(power, mass, lowSpeed, highSpeed, downHillForce)
	if downHillForce and math.abs(downHillForce) > 1 then 
		local a = lowSpeed
		local b = highSpeed 
		local f = downHillForce
		local p = power
		
		--https://www.wolframalpha.com/input?i2d=true&i=Integrate%5Bv%5C%2840%29Divide%5Bmv%2Cp%5D-Divide%5Bm%2Cf%5D%5C%2841%29%2C%7Bv%2Ca%2Cb%7D%5D
		return (mass *(-2* a^3* f + b^2 *(2* b *f - 3 *p) + 3* a^2 *p))/(6 *f* p)
		--return calculateDistanceToAccelerateGradient(power, mass, highSpeed, downHillForce )-calculateDistanceToAccelerateGradient(power, mass, lowSpeed, downHillForce )
	end
	return calculateDistanceToAccelerate(power, mass, highSpeed)-calculateDistanceToAccelerate(power, mass, lowSpeed)
end

local function calculateTimeToAccelerate(power, mass, lowSpeed, highSpeed)
	local a = lowSpeed
	local b = highSpeed  
	local p = power
	local m= mass
	--https://www.wolframalpha.com/input?i2d=true&i=Integrate%5B%5C%2840%29Divide%5Bmv%2Cp%5D%5C%2841%29%2C%7Bv%2Ca%2Cb%7D%5D
	return ((-a^2 + b^2)*m)/(2*p)
end

local function calculateTimeToAccelerateWithDownHillForce(power, mass, lowSpeed, highSpeed, downHillForce)
	local a = lowSpeed
	local b = highSpeed 
	local f = downHillForce
	local p = power
	local m= mass
	if f == 0 then  
		return calculateTimeToAccelerate(power, mass, lowSpeed, highSpeed)
	end
    --	https://www.wolframalpha.com/input?i2d=true&i=Integrate%5B%5C%2840%29Divide%5Bmv%2Cp%5D-Divide%5Bm%2Cf%5D%5C%2841%29%2C%7Bv%2Ca%2Cb%7D%5D
	return -((a - b) *m *(a* f + b* f - 2* p))/(2* f* p)
end

local function calculateVehicleAcceleration2(power, tractiveEffort, topSpeed, totalMass)
	 
	local fudgeFactor = 0.9 -- seems to be needed to get my numbers in agreement with TPF2
	power = fudgeFactor *power -- units kW
	  
	-- the lowSpeed is the transition point between tractiveEffort and power being the limiting factor 
	local lowSpeed  = power/tractiveEffort
	local initialAcceleration = tractiveEffort / totalMass  -- f = ma -> a = f/m
	local initialTime = lowSpeed/initialAcceleration
	local initialDistance  = 0.5*lowSpeed*initialTime -- distance at lowspeed
	
	
	local d = initialDistance + calculateDistanceToAccelerateDelta(power, totalMass, lowSpeed, topSpeed)
	--trace("time taken to reach the lowspeed of ",lowSpeed," (",api.util.formatSpeed(lowSpeed),") was ",initialTime, " estimated distance=",initialDistance) 
	local lowEnergy = 0.5*totalMass*lowSpeed^2
	local highEnergy = 0.5*totalMass*topSpeed^2
	local difference = highEnergy - lowEnergy
	local t = initialTime + (difference / power) -- time taken to add kinetic energy
	return { 
		t=t, 
		d=d,
		mass = totalMass,
		power=power,
		tractiveEffort=tractiveEffort,
		initialDistance = initialDistance,
		initialTime = initialTime,
		lowSpeed = lowSpeed,
		initialAcceleration =initialAcceleration,
		powerToWeight = power/totalMass
	}
end
local function calculateVehicleAcceleration(vehicle, totalMass, numberOfLocomotives) 
	local engine =	getVehicleEngine(vehicle)
	local power = engine.power*numberOfLocomotives -- units kW
	local tractiveEffort = engine.tractiveEffort*numberOfLocomotives -- units kN
	local topSpeed = getVehicleConfig(vehicle).topSpeed -- units m/s
	return calculateVehicleAcceleration2(power, tractiveEffort, topSpeed, totalMass)
end

local crawlSpeed = 1/3.6 -- 1km/h
local function calculateTripTimeOnRouteSection(power, tractiveEffort, topSpeed, totalMass, gradient, distance, startSpeed, debugOutput)
	local theta = math.atan(gradient)
	local downHillForce =  totalMass * math.sin(theta) * g
	startSpeed = math.min(startSpeed, topSpeed)
	tractiveEffort = tractiveEffort * 2 -- based on observations of the game the vehicles behave as if they had twice the displayed tractiveEffort
	local dragFactor = 0.02 * totalMass 
	downHillForce = downHillForce / 3 -- again based on observations of the game 
	downHillForce = downHillForce + dragFactor
	--trace("Inspecting section, the downHillForce was ",downHillForce," gradient=",gradient," the tractiveEffort was",tractiveEffort," the start power based speed was",(power/startSpeed),"power=",power,"downHillForce2=",downHillForce2)
	local maxForce = math.min(tractiveEffort, power/startSpeed) 
	if downHillForce > tractiveEffort and startSpeed > 0 then 
	--	trace("Allowing the power to be used")
		--maxForce = power/startSpeed
	end 
	local balancingSpeed = downHillForce > 0 and math.min(topSpeed, power/downHillForce) or topSpeed
	if downHillForce > tractiveEffort then 
	--	trace("WARNING! The locomotive is stalling")
		balancingSpeed = crawlSpeed
	end
	local alternateBalancingSpeed = power / ((totalMass * math.sin(theta) * g)/3 + dragFactor) 
	local alternateBalancingSpeed2 = power / ((totalMass *gradient * g)/3 + dragFactor) 
	local transitionSpeed = power/tractiveEffort
	local netForce = maxForce-downHillForce
	if netForce == 0 then 
	--	trace("Forces were exactly balanced, leaving")
		startSpeed = math.max(startSpeed, 1) -- to avoid problems when engine has "not enough power"
		return {
			speed = startSpeed,
			time = distance/startSpeed
		}
	end 
	local a= netForce / totalMass 
	local s = distance
	local u = startSpeed
	local quadraticFactor = 2*a*s + u^2 -- if this is negative it means the train has stalled, in the game it proceeds at a crawl
	--trace("The netForce was",netForce," the transitionSpeed=",transitionSpeed," the balancingSpeed=",balancingSpeed," alternateBalancingSpeed=",alternateBalancingSpeed,"alternateBalancingSpeed2=",alternateBalancingSpeed2)
	local calcTime  
	local endSpeed 
	if quadraticFactor < 0 then 
	--	trace("WARNING! The quadraticFactor was <0")
		
		endSpeed = balancingSpeed
		calcTime = 2*distance / (startSpeed+endSpeed)  
	else 
		calcTime = (math.sqrt(quadraticFactor) - u)/a
		endSpeed = math.min(startSpeed + a*calcTime, topSpeed)
	end 
	local endSpeedAboveTransition = endSpeed > transitionSpeed
	local startSpeedAboveTransition = startSpeed > transitionSpeed 
	if endSpeedAboveTransition ~= startSpeedAboveTransition then 
	--	trace("Crossed a transition boundary",endSpeed, startSpeed, transitionSpeed)
		if endSpeedAboveTransition then 
			local timeTakenToTransitionSpeed = (transitionSpeed-startSpeed) / a 
			local distanceCovered = timeTakenToTransitionSpeed*(transitionSpeed+startSpeed)/2
		end 
	end 
	if (endSpeedAboveTransition or startSpeedAboveTransition) and quadraticFactor > 0 then
		local isConverged = false 
		local count= 0
		local maxResult = endSpeed
		local minResult = endSpeed 
		repeat 
		
			local maxForce1 = math.min(tractiveEffort, power/startSpeed) 
			local maxForce2 = math.min(tractiveEffort, power/endSpeed) 
			local maxForceAverage = (maxForce1 + maxForce2 )/2
			local netForce = maxForceAverage-downHillForce
			count = count+1
			local a= netForce / totalMass 
			local s = distance
			local u = startSpeed
			local quadraticFactor = 2*a*s + u^2
			if quadraticFactor < 0 then 
			--	trace("WARNING! The quadraticFactor was <0, setting to balancingSpeed",balancingSpeed)
				isConverged = false
				break
			end
			calcTime = (math.sqrt(quadraticFactor) - u)/a
			local newEndSpeed = math.min(startSpeed + a*calcTime, topSpeed)
			 
			isConverged = math.abs(endSpeed-newEndSpeed) < 0.01
		--	trace("In loop, the endSpeed=",endSpeed,"new endSpeed=",newEndSpeed,"isConverged?",isConverged," netForce=",netForce," predicted accel:",a," maxForceAverage=",maxForceAverage)
			endSpeed = newEndSpeed
			maxResult = math.max(endSpeed,maxResult)
			minResult = math.min(endSpeed,minResult)
		until isConverged or count > 20
	--	trace("exited loop, is converged?",isConverged, " count=",count)
		if not isConverged then 
			if balancingSpeed >= minResult and balancingSpeed <= maxResult then 
			--	trace("Using balancing speed as the solution",balancingSpeed," calcEndSpeed=",endSpeed,"startSpeed=",startSpeed)
				endSpeed = balancingSpeed
				calcTime = 2*distance / (startSpeed+balancingSpeed)  
			else 
				--trace("WARNING! Did not converge and out of range of balancing speed",minResult, maxResult)
			end 
		end
	end 

	--trace("The calc time=",calcTime," vs",calculatedTime," and the end, endSpeed,",endSpeed," in mph:" ,api.util.formatSpeed(endSpeed),"predicted acceleration=",a,"netForce=",netForce)
	if calcTime~=calcTime then 
		trace("WARNING! Nan time found!")
		trace("Inspecting section, the downHillForce was ",downHillForce," gradient=",gradient," the tractiveEffort was",tractiveEffort," the start power based speed was",(power/startSpeed),"power=",power,"downHillForce2=",downHillForce2)
		trace("The distance was",distance," the balancingSpeed was ",balancingSpeed)
	end 	
	return {
		speed = endSpeed, 
		time =calcTime
	}
end


local function calculateTripTimeOnRouteSectionOld(power, tractiveEffort, topSpeed, totalMass, gradient, distance, startSpeed, debugOutput)
	local theta = math.atan(gradient)
	local downHillForce =  totalMass * math.sin(theta) * g
	if math.abs(gradient) < 0.001 then 
		downHillForce = 0
	end
	-- https://www.reddit.com/r/TransportFever/comments/7h8gvd/fixed_slope_track_gradients/
	local fudgeFactor = 1/3 
	downHillForce = downHillForce * fudgeFactor
	if downHillForce <= 0 then 
		--downHillForce = 0 -- not sure the calculations are correct for negatives
		--gradient =0
	end
	startSpeed = math.min(startSpeed, topSpeed)
	-- the tfSpeed is the transition point between tractiveEffort and power being the limiting factor 
	local tfSpeed  = power/tractiveEffort
	local initialAcceleration = (tractiveEffort-downHillForce) / totalMass  -- f = ma -> a = f/m
	local initialTime = startSpeed < tfSpeed and (tfSpeed-startSpeed)/initialAcceleration or 0
	if initialTime < 0 or initialTime ~= initialTime then
		-- might happen if insufficient tractive effort, the game behaviour is to crawl at 1km/h 
		local assumedSpeed = 1/3.6 -- 1km/h
		local t = distance / assumedSpeed
		if debugOutput then
			trace(" a low tractive effort was detected, ",tractiveEffort, " vs downHillForce ", downHillForce," crawling, assumedSpeed=",assumedSpeed, " t=",t)
		end
		return {
			speed = assumedSpeed,
			time = t
		}
	end
	local initialDistance  = 0.5*(tfSpeed+startSpeed)*initialTime -- distance at lowspeed
	if initialDistance > distance then 
		local endSpeed = (2*distance*initialAcceleration+startSpeed^2)^0.5
		local t = (endSpeed-startSpeed)/initialAcceleration
		if debugOutput then 
			trace("Vehicle did not reach lowspeed. Calculated endspeed=",endSpeed,"t=",t, " distance=",distance,"gradient=",gradient)
		end
		return {
			speed = endSpeed,
			time = t
		}
	end
	local remainingDistance = distance - initialDistance
	
	local lowerSpeed = math.max(tfSpeed, startSpeed)
	
	
	local balancingSpeed = downHillForce > 0 and math.min(topSpeed, power/downHillForce) or topSpeed
	
	if math.abs(balancingSpeed-startSpeed) <  0.01 then 
		return {
			speed=startSpeed,
			time = distance/startSpeed
		}
	end
	if startSpeed > balancingSpeed or downHillForce < 0 then 
		local heightDiff = gradient*distance 
		local perequired = heightDiff*g*totalMass
		local kineticEnergy = 0.5*totalMass*startSpeed^2
		local kP = 0.333*totalMass*startSpeed^3 
		local peP = startSpeed*gradient*g*totalMass
		local maxForce = math.min(tractiveEffort, power/startSpeed)
		local decelForce = downHillForce - maxForce
		local decelAccel = decelForce / totalMass 
		local estimatedTime = distance/startSpeed 
		local estimatedDeltaV = estimatedTime * decelAccel
		local endSpeed = math.min(startSpeed-estimatedDeltaV, topSpeed)
		return {
			speed = endSpeed, 
			time = distance / ((startSpeed+endSpeed)/2)
		}
		
	end 
	local upperSpeed = balancingSpeed
	if balancingSpeed < lowerSpeed then 
		if debugOutput then 
			local d1 = calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed,balancingSpeed, downHillForce)
			local d2 = calculateDistanceToAccelerateDelta(power, totalMass, balancingSpeed,lowerSpeed, downHillForce)
			local d3 = calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed,balancingSpeed, -downHillForce)
			local d4 = calculateDistanceToAccelerateDelta(power, totalMass, balancingSpeed,lowerSpeed, -downHillForce)
			local d5 = calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed,balancingSpeed, 0)
			local d6 = calculateDistanceToAccelerateDelta(power, totalMass, balancingSpeed,lowerSpeed, 0)
			trace("BalancingSpeed=",balancingSpeed," lowSpeed=",lowerSpeed," d1=",d1,"d2=",d2, " d3=",d3,"d4=",d4, " d5=",d5, " d6=",d6)
			local t1= calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, balancingSpeed, downHillForce)
			local t2= calculateTimeToAccelerateWithDownHillForce(power, totalMass, balancingSpeed, lowerSpeed, downHillForce)
			local t3= calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, balancingSpeed, -downHillForce)
			local t4= calculateTimeToAccelerateWithDownHillForce(power, totalMass, balancingSpeed, lowerSpeed, -downHillForce)
			local t5= calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, balancingSpeed, 0)
			local t6= calculateTimeToAccelerateWithDownHillForce(power, totalMass, balancingSpeed, lowerSpeed, 0)
			trace("t1=",t1,"t2=",t2,"t3=",t3,"t4=",t4, "t5=",t5, " t6=",t6)
		end
		upperSpeed = lowerSpeed
		lowerSpeed = balancingSpeed
		downHillForce = -downHillForce
	end
	
	local potentialEnergy = remainingDistance*gradient*totalMass*g
	local lowEnergy = 0.5*totalMass*lowerSpeed^2
	local highEnergy = 0.5*totalMass*upperSpeed^2+potentialEnergy
	local difference = highEnergy - lowEnergy
	local t = initialTime + math.abs(difference / power) -- time taken to add kinetic energy
	local d = initialDistance + math.abs(calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed,upperSpeed, downHillForce))
	if d > distance  then 
		if downHillForce == 0 then -- analytic solution possible
			local endSpeed = calculateSpeedAtDistanceWithStartSpeed(power, totalMass, distance-initialDistance, lowerSpeed)
			local sectionTime = initialTime + calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, endSpeed, downHillForce)
			if debugOutput then 
				trace("For downHillForce==0 calculated sectiontime =",sectionTime,"  endSpeed=",endSpeed, " over distance " , distance)
			end
			return {
				speed = endSpeed,
				time = sectionTime
			}
		end
		local vlow = lowerSpeed
		local vhigh =upperSpeed
  
		local distanceFn = function(v)
			return initialDistance + math.abs(calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed , v, downHillForce))
		end
		--if startSpeed > balancingSpeed then 
		--	distanceFn = function(v)
		--		return initialDistance + math.abs(calculateDistanceToAccelerateDelta(power, totalMass, v , upperSpeed, downHillForce))
		--	end
		--end
		local solutionFn = function(v)
			return distanceFn(v)-distance
		end
		local maxIteration = 128
		--local maxRecursions = precision
		local iteration = 1
		local vmid = (vhigh+vlow)/2
		repeat 
			 
			local temp = vmid
			if solutionFn(vmid) > 0 then
				vmid = (vlow+vmid)/2
				vhigh = temp
			else
				vmid = (vhigh+vmid)/2
				vlow = temp
			end
 
			iteration = iteration + 1
		until iteration == maxIteration or math.abs(solutionFn(vmid)) < 1 
		if debugOutput then 
			trace("Solved vlow=",vlow," vhigh=",vhigh," vmid=",vmid," after ", iteration,"iterations tfSpeed=",tfSpeed," balancingSpeed=",balancingSpeed, " initialDistance=",initialDistance, " downHillForce=",downHillForce)
		end
		local endSpeed =vmid
		lowEnergy = 0.5*totalMass*lowerSpeed^2
		highEnergy = 0.5*totalMass*endSpeed^2+potentialEnergy 
		difference = highEnergy - lowEnergy
		t = initialTime + math.abs(difference / power)
		 
 
		local alternativeTime = initialTime + math.abs(calculateTimeToAccelerateWithDownHillForce(power, totalMass,lowerSpeed,upperSpeed, math.abs(downHillForce)))
		local minTime = distance / upperSpeed
		local maxTime = distance / lowerSpeed
		if alternativeTime > maxTime or alternativeTime < minTime then 
			if debugOutput then 
				trace("WARNING! Time calculated not in valid range, min=",minTime, " max=",maxTime, " calculated=",alternativeTime)
			end
			alternativeTime = (minTime+maxTime)/2
		end
		if debugOutput then 
			trace("Vehicle did not reach balancingSpeed. After ",d," Calculated endspeed=",endSpeed,"t=",t, " distance=",distance,"gradient=",gradient, " startSpeed=",startSpeed," recalculated distance=",distanceFn(endSpeed), " alternativeTime=",alternativeTime, " solutionFn(vmid)=",solutionFn(vmid))
		end
		return {
			speed = endSpeed,
			time = alternativeTime
		}
	else 
		
		local remainingDistance = distance - d 
		local remainingTime = remainingDistance / balancingSpeed
		local totalTime = t+remainingTime
		local alternativeTime = remainingTime + calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, upperSpeed, downHillForce)
		if debugOutput then 
			trace("Vehicle DID reach balancingSpeed. Calculated endspeed=",balancingSpeed,"t=",t, " totalTime=",totalTime, " distance=",distance,"gradient=",gradient,"d=",d, " startSpeed=",startSpeed, " initialDistance=",initialDistance, " alternativeTime=",alternativeTime, "remainingTime=",remainingTime)
		end
		local minSpeed = math.min(startSpeed, balancingSpeed)
		local maxSpeed = math.max(startSpeed, balancingSpeed)
		local minTime = distance / maxSpeed
		local maxTime = distance / minSpeed
		if totalTime > maxTime or totalTime < minTime then 
			if debugOutput then 
				trace("WARNING! Time calculated not in valid range, min=",minTime, " max=",maxTime, " calculated=",totalTime)
			end
			totalTime = (minTime+maxTime)/2
		end
		
		return {
			speed = balancingSpeed, 
			time = totalTime
		}
		
		
	end
	

end

local function calculateTripTimeFromRouteSections(params, power, tractiveEffort, topSpeed, mass, gradient, length, speed, isOutbound, debugOutput, zeroGradients)
	local routeSections 
	if isOutbound then 
		routeSections = params.routeInfo.routeSections
	else 
		trace("calculateTripTimeFromRouteSections: reversing routeSections")
		routeSections = {} 
		for i = #params.routeInfo.routeSections, 1, -1 do 
			local reversedSection = util.deepClone(params.routeInfo.routeSections[i])
			reversedSection.avgGradient = -reversedSection.avgGradient
			table.insert(routeSections, reversedSection) -- reverse the order
		end
	end
	local decelFactor =  api.res.getBaseConfig().trainBrakeDeceleration
	local priorSpeed = 1 -- techinally zero but use 1 to avoid strange effects
	for i = #routeSections, 1 , -1 do 
		local routeSection = routeSections[i]
		local nextSpeed = math.sqrt(priorSpeed*priorSpeed + 2*decelFactor*routeSection.length)
		priorSpeed = math.min(nextSpeed, routeSection.speedLimit)
		routeSection.maxRouteSectionSpeed = priorSpeed
	end 
	local maxSpeedAchieved = 0
	local totalTime = 0
	local speed = 0
	local routeLength = 0
	for i = 1, #routeSections do 
		local routeSection = routeSections[i]
		local length = routeSection.length
		local gradient = routeSection.avgGradient
		if zeroGradients then 
			gradient =0
		end
		local sectionTopSpeed = math.min(routeSection.maxRouteSectionSpeed, topSpeed)
		local info = calculateTripTimeOnRouteSection(power, tractiveEffort, sectionTopSpeed, mass, gradient, length, speed, debugOutput)
		speed = info.speed
		maxSpeedAchieved = math.max(maxSpeedAchieved, speed)
		totalTime = totalTime + info.time 
		routeLength = routeLength + length
	end
	return totalTime, maxSpeedAchieved
end

local function calculateTripTime(acceleration, params, topSpeed, isOutbound, info)
	local distance = params.distance
	--trace("calculating trip time, the type was ",params.carrier, " distance =",distance)
	if params.carrier == api.type.enum.Carrier.AIR then 
		local taxiAndApproachTime = 286 -- measured time of Airbus A320 travelling between airports next to each other 
		local totalTime = taxiAndApproachTime + distance/topSpeed -- does not consider thrust/acceleration etc. but its a reasonable guess, speed profile of in game aircraft is a bit of a black box
		return { totalTime = totalTime, originalTotalTime = totalTime, maxSpeedAchieved=topSpeed }
	end 
	if params.carrier == api.type.enum.Carrier.WATER then -- at present this has a very simplified calculation, with the low speeds its probably not worth considering the acceleration
		if params.impliedShipDistance then 
			trace("Calculating ship time, using",params.impliedShipDistance," instead of ",distance)
			distance = params.impliedShipDistance 
		end
		local totalTime = distance/topSpeed  
		return { totalTime = totalTime, originalTotalTime = totalTime, maxSpeedAchieved=topSpeed }
	end 
	local initialTime = acceleration.t 
	local initialDistance = acceleration.d
	local totalTime = 0
	local power = acceleration.power
	local mass = acceleration.mass
	local lowSpeed = acceleration.lowSpeed 
	local tractiveEffort = acceleration.tractiveEffort
	local maxSpeedAchieved = 0
	if initialDistance > distance then 
		local tractiveEffortDistance = acceleration.initialDistance
		if tractiveEffortDistance > distance then 
			totalTime = (2*distance / acceleration.initialAcceleration)^0.5
			maxSpeedAchieved = distance*acceleration.initialAcceleration
			trace("The tractiveEffortDistance was greater than distance", tractiveEffortDistance, " vs ",distance, " calculated time=",t)
			 
		else 
			local tractiveEffortTime = acceleration.initialTime	
		
			local terminalSpeed = lowSpeed + calculateSpeedAtDistance(power, mass, distance)-calculateSpeedAtDistance(power, mass, tractiveEffortDistance) 
			totalTime = tractiveEffortTime +  calculateTimeToAccelerate(power, mass, lowSpeed, terminalSpeed)
			maxSpeedAchieved = terminalSpeed
			--trace("The distance ",distance," was not long enough to reach full speed, terminalSpeed=",terminalSpeed," time =",t)
		end
	else 
		local remainingDistance = distance - initialDistance
		local remainingTime = remainingDistance / topSpeed
		totalTime = initialTime + remainingTime
	end
	
	local originalTotalTime = totalTime
	if params.routeInfo then 
		--trace("calculating trip time from route sections")
		totalTime , maxSpeedAchieved = calculateTripTimeFromRouteSections(params, power, tractiveEffort, topSpeed, mass, gradient, length, speed, isOutbound)
		if reportInconsistent then 
			if math.abs(originalTotalTime-totalTime)/originalTotalTime > 1.5 or math.abs(originalTotalTime-totalTime)/totalTime > 1.5 or totalTime~=totalTime or originalTotalTime~=originalTotalTime or math.abs(totalTime) == math.huge then
				trace("WARNING! Considering actual route parameters, recalculated trip time from ", originalTotalTime, " to ",totalTime, " routeLength was=",routeLength, " vs distance=",distance, " for the consist ",info.leadName)
				local testTime = calculateTripTimeFromRouteSections(params, power, tractiveEffort, topSpeed, mass, gradient, length, speed, isOutbound,true)
				trace("The caclulation a second time gave ", testTime)
				local testTime2 = calculateTripTimeFromRouteSections(params, power, tractiveEffort, topSpeed, mass, gradient, length, speed, isOutbound,true, true)
				trace("The caclulation a third time gave ", testTime2)
			end
		end
	end
	
	return { totalTime = totalTime, originalTotalTime = originalTotalTime, maxSpeedAchieved=maxSpeedAchieved }
end 


local function calculateMaxSlope(vehicle, totalMass)
	local tractiveEffort = getVehicleEngine(vehicle).tractiveEffort
	local weight = g*totalMass
	if tractiveEffort > weight then
		return math.huge
	end
	local theta = math.asin(tractiveEffort / weight)
	return math.tan(theta)
end 

local function calculateMaxMassForLocomotive(vehicle, params)
	local tractiveEffort = getVehicleEngine(vehicle).tractiveEffort
	local maxGradient = paramHelper.getParams().maxGradientTrack
	if not params.maxSeenGradient and params.routeInfos then 
		trace("Using the routeInfos to find the true actual max gradient, initial maxGradient=",maxGradient)
		for i, routeInfo in pairs(params.routeInfos) do 
			for j, routeSection in pairs(routeInfo.routeSections) do 
				maxGradient = math.max(maxGradient, routeSection.avgGradient)
			end 
		end 
		trace("Set the maxGradient to ",maxGradient)
		params.maxSeenGradient=maxGradient
	end 
	if params.maxSeenGradient then 
		maxGradient = params.maxSeenGradient
	end 
	
	local theta = math.atan(maxGradient/3) -- the game divides the gradient by 3 
	return (2*tractiveEffort) / (0.02 + math.sin(theta) * g) -- game also multiplies tractive effort by 2 and has a drag factor of 2% 
end 

local function calculateTractiveEffortForMass(mass) 
	local maxGradient = paramHelper.getParams().maxGradientTrack
	local theta = math.atan(maxGradient)
	return mass * math.sin(theta) * g
end 

 
local function discoverVehicles() 
	--collectgarbage("collect")
	local discoveredVehiclesByType = {}
	local modelRepLookup = {}
	local modelNameLookup = {}
	local modelAvailablility = {}
	local muNames = getMuTypeNames() 
	trace("Begin discovering vehicles")
	local allModels = util.deepClone(api.res.modelRep.getAll())
	--collectgarbage("collect")
	local legacyModels = {}
	for idx, name in pairs(allModels) do
		--e.g. vehicle/train/usa/emd_aem_7_v2.mdl -> vehicle/train/usa/emd_aem_7.mdl
		local legacyModel
		if string.sub(name, -7, -5) == "_v3" then 
			legacyModel = string.sub(name, 1, -8).."_v2.mdl" 
		 
		elseif string.sub(name, -7, -5) == "_v2" then
			legacyModel = string.sub(name, 1, -8)..".mdl"
		end
		if legacyModel then 
			trace("Found legacyModel",legacyModel," to ignore based on model name",name)
			legacyModels[legacyModel]=true 
		end
	end
	
	local foundModVehicles = false 
	local seenWaggon = false
	for idx, name in pairs(allModels) do
		if string.sub(name,1,8) == "vehicle/" and not legacyModels[name] or muNames[name] then
			
			local vehicleType = string.match(string.sub(name,9,-1), "%a*")
			
			trace("Discovered vechileType",vehicleType," from name ",name)
			local i = api.res.modelRep.find(name)
			local model = api.res.modelRep.get(i)
			if not model.metadata.transportVehicle then 
				goto continue 
			end 
			if vehicleType == "waggon" then -- note this is before making the subtitution
				seenWaggon = true 
			end 
			if vehicleType == "train" and  not model.metadata.railVehicle then 
				goto continue 
			end
			if vehicleType == "train" and #model.metadata.railVehicle.engines == 0 then 
				trace("Ressigning the model",name," as a waggon")
				vehicleType = "waggon"
			end
			if vehicleType=="train" and seenWaggon   then -- can't use discoveredVehiclesByType["waggon"] because we reassign 
				trace("Possibly found mod vehicles at ",idx)
				foundModVehicles = true -- this is a bit brittle TODO: better way of distinguishing mod vehicles
			end
			if not discoveredVehiclesByType[vehicleType] then 
				discoveredVehiclesByType[vehicleType] = {}
			end
			
			modelAvailablility[i] = { all = true }
			if filterClimate(name, vehicleType, model) or foundModVehicles or muNames[name] then
				modelAvailablility[i].auto=true
			end
			for k, v in pairs({"europe", "usa", "asia"}) do
				if filterClimateOverride(name, vehicleType, model, v) then 
					modelAvailablility[i][v]=true
				end
			end
			local modelCopy = {}
			--`modelCopy.metadata = util.deepClone(model.metadata) -- 'sol::as_container_t<MetadataMap>': it is not recognized as a container
			modelCopy.metadata = model.metadata
		--	modelCopy.boundingInfo = util.deepClone(model.boundingInfo)
			modelCopy.boundingInfo = model.boundingInfo
			modelRepLookup[i]=modelCopy
			modelNameLookup[i]=api.res.modelRep.getName(i)
			if model.metadata.transportVehicle and not model.metadata.transportVehicle.multipleUnitOnly then 
				discoveredVehiclesByType[vehicleType][i]=modelCopy
			end
			::continue::
		end
	end
	local locomotiveReplacments = {}
	locomotiveReplacments[api.res.modelRep.find("vehicle/train/usa/alco_pa.mdl")]= api.res.modelRep.find("vehicle/train/usa/alco_pb.mdl")
	locomotiveReplacments[api.res.modelRep.find("vehicle/train/usa/alco_pa_front_v2.mdl")]= api.res.modelRep.find("vehicle/train/usa/alco_pb_back_v2.mdl")
	local cargoCapacityLookup = {}
	local cargoIdxLookup = {}
	local inverseCargoIdxLookup = {}
	local cargoRep = api.res.cargoTypeRep.getAll()
	for modelId, model in pairs(modelRepLookup) do 
		cargoCapacityLookup[modelId]={}
		cargoIdxLookup[modelId]={}
		inverseCargoIdxLookup[modelId]={}
		for cargoTypeIdx, cargoTypeName in pairs(cargoRep) do 
			cargoCapacityLookup[modelId][cargoTypeIdx] = 0
			cargoCapacityLookup[modelId][cargoTypeName] = 0
		end
		local transportVehicle = model.metadata.transportVehicle
		if transportVehicle then 
			for i, compartment in pairs(transportVehicle.compartments) do
				for j, loadConfig in pairs(compartment.loadConfigs) do
					for k, cargoEntry in pairs(loadConfig.cargoEntries) do
						local cargoName = api.res.cargoTypeRep.find(cargoEntry.type)
						cargoCapacityLookup[modelId][cargoEntry.type] = cargoEntry.capacity + cargoCapacityLookup[modelId][cargoEntry.type]
						cargoCapacityLookup[modelId][cargoName] = cargoEntry.capacity + cargoCapacityLookup[modelId][cargoName]
						cargoIdxLookup[modelId][cargoEntry.type] = j
						cargoIdxLookup[modelId][cargoName] = j
						inverseCargoIdxLookup[modelId][j]=cargoName
					end
				end
			end 
		end
	end
	
	local cargoWeightLookup = {}
	for cargoTypeIdx, cargoTypeName in pairs(api.res.cargoTypeRep.getAll()) do 
		local weigth = api.res.cargoTypeRep.get(cargoTypeIdx).weight
		cargoWeightLookup[cargoTypeIdx] = weigth
		cargoWeightLookup[cargoTypeName] = weigth
	end
	vehicleUtil.modelAvailablility = modelAvailablility
	vehicleUtil.cargoIdxLookup = cargoIdxLookup
	vehicleUtil.inverseCargoIdxLookup = inverseCargoIdxLookup
	vehicleUtil.cargoWeightLookup = cargoWeightLookup
	vehicleUtil.cargoCapacityLookup = cargoCapacityLookup
	vehicleUtil.locomotiveReplacments = locomotiveReplacments
	vehicleUtil.discoveredVehiclesByType = discoveredVehiclesByType-- local cache not just for performance, frequent calls to modelRep seem to cause random crashes
	vehicleUtil.modelRepLookup =  modelRepLookup
	vehicleUtil.modelNameLookup = modelNameLookup
	vehicleUtil.difficultyModifier = 1 - (game.interface.getGameDifficulty()/5) -- https://www.reddit.com/r/TransportFever/comments/ztpldt/update_payment_formula/
	trace("End discovering vehicles, set difficultyModifier to ",vehicleUtil.difficultyModifier)
end 

local function getAllVehiclesByType(vehicleType) 
	if not vehicleUtil.discoveredVehiclesByType then 
		discoverVehicles()  
	end
	if not vehicleUtil.discoveredVehiclesByType[vehicleType] then 
		debugPrint(discoveredVehiclesByType)
		print("WARNING! No vehicles of type, ",vehicleType)
		discoverVehicles() 
	end
	return vehicleUtil.discoveredVehiclesByType[vehicleType]
end
 
local function findVehiclesOfType(vehicleType, params) 
	local result = {}
	if not params then params = {} end
	if not params.vehicleRestriction then 
		params.vehicleRestriction = "auto" 
	end
	if not params.vehicleFavourites then 
		params.vehicleFavourites = {} 
	end
	for i, model in pairs(getAllVehiclesByType(vehicleType) ) do
		if model.metadata and vehicleUtil.modelAvailablility[i][params.vehicleRestriction] then 
			local availability = model.metadata.availability
			--trace("inspecting vehicle", model.metadata, " index ", i," availability=",availability)
			if util.filterYearFromAndTo(availability) then 
				if not params.vehicleFavourites[vehicleType] or params.vehicleFavourites[vehicleType][i] then 
					table.insert(result, {modelId = i, model=model}) 
				end 
			end 
		end
	end
	return result
end

local function getVehicleDescription(vehicle)
	local baseDescription = _(vehicle.model.metadata.description.name)
	if vehicleUtil.discoveredVehiclesByType["waggon"][vehicle.modelId] then -- it is a waggon - needs some disambiguation
		local name = vehicleUtil.modelNameLookup[vehicle.modelId]
		local region
		if string.find(name, "asia") then 
			region = "asia"
		elseif string.find(name, "usa") then 
			region = "usa"
		end
		if region then 
			baseDescription = baseDescription.." (".._(region)..")"
		end 
		local topSpeed = vehicle.model.metadata.railVehicle.topSpeed
		baseDescription = baseDescription.." "..api.util.formatSpeed(topSpeed)
	end
	return baseDescription
end
paramHelper.findVehiclesOfType = findVehiclesOfType
paramHelper.getVehicleDescription = getVehicleDescription

function vehicleUtil.findBestMatchVehicleOfType(vehicleType, params, scoreWeights , optionalFilterFn)	
	local cargoType = params.cargoType 
	params.vehicleType = vehicleType
	local vehicles =  findVehiclesOfType(vehicleType,  params) 
	trace("finding best match vehicle of type",vehicleType," the base number of vehicles was",#vehicles)
	local options = {}
	local filterByCargoType = vehicleUtil.filterByCargoTypeId(cargoType)
	for i, vehicleDetail in pairs(vehicles) do	
		local vehicle = vehicleDetail.model
		local vehicleId = vehicleDetail.modelId
		if optionalFilterFn and not optionalFilterFn(vehicleId, vehicle) then
			trace("Vehicle",vehicleId," did not meet the optional filter")
			goto continue
		end
		
		if not filterByCargoType(vehicleId) then
			trace("Vehicle",vehicleId," did not meet the cargo filter")
			goto continue 
		end		
		local engine = getVehicleEngine(vehicle)
		local config = getVehicleConfig(vehicle)
		local capacity = vehicleUtil.cargoCapacityLookup[vehicleDetail.modelId][cargoType]
		local meetsCapacity = 0
		if params.targetCapacity then 
			meetsCapacity = math.abs(params.targetCapacity-capacity)
		end 
		local vehicleConfig = vehicleUtil.copyConfig(vehicleUtil.createVehicleConfig(vehicleDetail.modelId))
		local info = vehicleUtil.getConsistInfo(vehicleConfig, cargoType, params)
		local vehicleCount
		
		local p = vehicleUtil.calculateProjectedProfit(vehicleConfig, info, params)
		if params.totalTargetThroughput and params.cargoType ~= "PASSENGERS" then -- passenger lines may require minimum frequency
			vehicleCount = math.ceil(params.totalTargetThroughput / p.maxThroughput)
			-- CLAUDE FIX: Cap vehicle count based on minimum interval for road/truck vehicles
			if p.totalTime and vehicleType == "truck" then
				local minInterval = paramHelper.getParams().minimumIntervalRoad
				local maxVehicles = math.ceil(p.totalTime / minInterval)
				trace("vehicleUtil: vehicleCount=", vehicleCount, "maxVehicles=", maxVehicles, "totalTime=", p.totalTime, "minInterval=", minInterval)
				if vehicleCount > maxVehicles then
					trace("vehicleUtil: CAPPING vehicleCount from", vehicleCount, "to", maxVehicles)
					vehicleCount = maxVehicles
				end
			end
			p = vehicleUtil.calculateProjectedProfit(vehicleConfig, info, params , vehicleCount)
		end 
		if p.projectedProfit ~= p.projectedProfit then 
			trace("WARNING! NaN value calculated for profit, setting to zero")
			if util.tracelog then 
				trace("Begin debugPrint1")
				debugPrint({info=info})
				trace("Being debugPrint2")
				debugPrint({projections=p}) 
				trace("Begin debugPrint3")
				debugPrint({vehicleConfig=vehicleConfig})
				--trace("Begin debugPrint4") 
				--debugPrint({params=params})
				--debugPrint({vehicleConfig = vehicleConfig, info=info, params=params, projections=p})
			end 
			p.projectedProfit = 0
		end 
		table.insert(options, { 
			vehicleDetail = vehicleDetail,
			config = vehicleConfig ,
			p = p,
			vehicleCount = vehicleCount,
			scores = {
				config.weight/engine.power,
				config.weight/engine.tractiveEffort,
				1/capacity,
				1/config.topSpeed,
				vehicle.metadata.cost.price,
				vehicle.metadata.maintenance.runningCosts,
				vehicle.metadata.emission and vehicle.metadata.emission.idleEmission or 60,
				meetsCapacity,
				2^24-p.projectedProfit,
			}
		})
		::continue::
	end
	trace("number of vehicles found=",#options)
--[[	
	if (vehicleType == "tram" or vehicleType == "bus") and util.tracelog then 
		debugPrint({tramOptions=util.evaluateAndSortFromScores(options,scoreWeights),scoreWeights=scoreWeights})
	end
	if vehicleType == "truck" and util.tracelog then 
		debugPrint({truckOptions=util.evaluateAndSortFromScores(options,scoreWeights),scoreWeights=scoreWeights})
	end
	if vehicleType == "ship" and util.tracelog then 
		debugPrint({shipOptions=util.evaluateAndSortFromScores(options,scoreWeights),scoreWeights=scoreWeights})
	end]]--
	if params.isForVehicleReport then 
		return util.evaluateAndSortFromScores(options, scoreWeights)
	end

	local best = util.evaluateWinnerFromScores(options, scoreWeights)
	return best and best.vehicleDetail
end

	
function vehicleUtil.getBestMatchForIntercityBus(params)
	if not params then 
		params = {cargoType="PASSENGERS", distance = 4000, targetThroughput=25, carrier == api.type.enum.Carrier.ROAD}
	end 
	return vehicleUtil.findBestMatchVehicleOfType("bus",params ,paramHelper.getParams().interCityBusScoreWeights )
end

function vehicleUtil.buildIntercityBus(params) 
	return vehicleUtil.createVehicleConfig(vehicleUtil.getBestMatchForIntercityBus(params).modelId)
end 

function vehicleUtil.getBestMatchForUrbanBus()
	return vehicleUtil.findBestMatchVehicleOfType("bus", {cargoType="PASSENGERS", distance = 1000, targetThroughput=25, carrier == api.type.enum.Carrier.ROAD}, paramHelper.getParams().urbanBusScoreWeights)
end

function vehicleUtil.buildUrbanBus() 
	return vehicleUtil.createVehicleConfig(vehicleUtil.getBestMatchForUrbanBus().modelId)
end 
local function isCargo(cargoType) 
	if type("cargoType") == "string" then 
		return cargoType ~= "PASSENGERS"
	else 
		return cargoType > 0
	end
end

function vehicleUtil.getWaggonsByCargoType(cargoType, params) 
	local result = {}
	for i, vehicleDetail in pairs(findVehiclesOfType("waggon", params)) do	
		local vehicle = vehicleDetail.modelId
		if vehicleUtil.filterByCargoTypeId(cargoType)(vehicle) then 
			table.insert(result, vehicleDetail)
		end
	end
	return result
end

function vehicleUtil.findBestMatchWaggon( params )
	local options = {}
	local cargoType = params.cargoType
	local targetSpeed = params.isHighSpeedTrack and getHighSpeedTrackSpeed()  or getStandardTrackSpeed()
	for i, vehicleDetail in pairs(vehicleUtil.getWaggonsByCargoType(cargoType, params)) do	
		local vehicle = vehicleDetail.model
	
		 
		local config = getVehicleConfig(vehicle)
		local mass = config.weight
	 
		--local capacity = vehicleUtil.getCargoCapacity(vehicle, cargoType)
		local capacity = vehicleUtil.cargoCapacityLookup[vehicleDetail.modelId][cargoType]
		local length = getModelLengthx(vehicle)
		local differenceFromTargetSpeed = math.abs(targetSpeed - config.topSpeed)
		local underTargetSpeed = math.max(targetSpeed - config.topSpeed ,0)
		local loadSpeed = vehicle.metadata.transportVehicle.loadSpeed
		table.insert(options, { 
			vehicleDetail=vehicleDetail, 
			scores = {
				differenceFromTargetSpeed, 
				underTargetSpeed,
				mass / capacity ,
				length/capacity,
				capacity / loadSpeed
				}			
			}
		)
	end
	trace("number of options found = ",util.size(options))
	return util.evaluateWinnerFromScores(options, paramHelper.getParams().waggonScoreWeights).vehicleDetail
end

local function emptyCompartment(vehicle)
	local transportVehicle = vehicle.metadata.transportVehicle
	for i, compartment in pairs(transportVehicle.compartments) do
		for j, loadConfig in pairs(compartment.loadConfigs) do
			return #loadConfig.cargoEntries == 0
		end
	end
	return true
end

local function getAllAvailableLocomotives(params, forbidRecurse) 
	local vehicles =  findVehiclesOfType("train", params) 
	local results = {} 
	for i, vehicleDetail in pairs(vehicles) do 
		local vehicle = vehicleDetail.model
		local engine = getVehicleEngine(vehicle)
		if engine and engine.type ~= params.locomotiveRestriction and  emptyCompartment(vehicle) then 
			table.insert(results, vehicleDetail)
		else 
			--trace("No engine found for ",vehicleDetail.modelId)
			--debugPrint(vehicleDetail)
		end
	end
	if #results == 0 and params.locomotiveRestriction ~= -1 and not forbidRecurse then 
		local copy = util.shallowClone(params)
		copy.locomotiveRestriction = -1
		copy.vehicleFavourites = nil
		forbidRecurse = true 
		return getAllAvailableLocomotives(copy, forbidRecurse)
	end 
	return results
end

function vehicleUtil.findBestMatchLocomotive(targetSpeed, targetTractiveEffort, filterFn, params )
	 
	local options = {} 
	for i, vehicleDetail in pairs( getAllAvailableLocomotives(params) ) do 	
		local vehicle = vehicleDetail.model
		if filterFn and not filterFn(vehicle) then goto continue end		
		local engine =getVehicleEngine(vehicle)
		local config = getVehicleConfig(vehicle)
		local engineMass = config.weight
		-- need to account for the fact the locomotive has to haul itself (which may be signficant)
		local tractiveEffortForLoco  = calculateTractiveEffortForMass(engineMass)
		local actualTargetTractiveEffort = tractiveEffortForLoco + targetTractiveEffort
		--trace("Calulated the actualTargetTractiveEffort=",actualTargetTractiveEffort," based on targetTractiveEffort=",targetTractiveEffort," and tractiveEffortForLoco=",tractiveEffortForLoco)
		local length = getModelLengthx(vehicle)
		local differenceFromTargetSpeed = math.abs(targetSpeed - config.topSpeed)
		local underTargetSpeed = math.max(targetSpeed - config.topSpeed ,0) -- double penalty for being below the target speed
		table.insert(options, { 
			vehicleDetail=vehicleDetail, 
			scores = {
				differenceFromTargetSpeed,
				underTargetSpeed,
				math.abs(actualTargetTractiveEffort -engine.tractiveEffort),
				engineMass/engine.tractiveEffort,
				length/engine.tractiveEffort,
				vehicle.metadata.cost.price,
				engineMass/engine.power,
				vehicle.metadata.emission and vehicle.metadata.emission.idleEmission or 60
				}			
			}
		)
	
		::continue::
	end
	local weights = paramHelper.getLocomotiveScoreWeights(isCargo)
	return util.evaluateWinnerFromScores(options, weights).vehicleDetail
end



function vehicleUtil.filterByCargoType(cargoType)
	if type(cargoType) == "number" then
		cargoType = api.res.cargoTypeRep.get(cargoType).id
	end
	--trace("Filtering vehicles for cargoType=",cargoType)
	return function(vehicle)
		--trace("inspecting vehicle ", vehicle.metadata.description.name)
		local transportVehicle = vehicle.metadata.transportVehicle
		for i, compartment in pairs(transportVehicle.compartments) do
			for j, loadConfig in pairs(compartment.loadConfigs) do
				for k, cargoEntry in pairs(loadConfig.cargoEntries) do
					if cargoEntry.type==cargoType then
						--trace("vehicle was successful")
						return true
					end
				end
			end
		end
		--trace("vehicle failed")
		return false
	end
end
function vehicleUtil.filterByCargoTypeId(cargoType) 
	return function(vehicleId)
		return vehicleUtil.cargoCapacityLookup[vehicleId][cargoType] and vehicleUtil.cargoCapacityLookup[vehicleId][cargoType] > 0
	end
end

-- Filter for "universal" trucks that can carry multiple cargo types
function vehicleUtil.filterToUniversalTruck(minCargoTypes)
	minCargoTypes = minCargoTypes or 5  -- Lowered from 20 to ensure trucks can be found for all cargo types including oil
	return function(vehicleId)
		local capacities = vehicleUtil.cargoCapacityLookup[vehicleId]
		if not capacities then return false end
		local cargoTypeCount = 0
		for cargoType, capacity in pairs(capacities) do if type(cargoType) == "number" then
			if capacity and capacity > 0 and cargoType ~= "PASSENGERS" then
				cargoTypeCount = cargoTypeCount + 1
			end
		end end
		return cargoTypeCount >= minCargoTypes
	end
end

-- Filter for universal trucks that can also carry a specific cargo type
function vehicleUtil.filterToUniversalTruckWithCargo(cargoType, minCargoTypes)
	local universalFilter = vehicleUtil.filterToUniversalTruck(minCargoTypes)
	return function(vehicleId)
		local capacities = vehicleUtil.cargoCapacityLookup[vehicleId]
		if not capacities then return false end
		if not capacities[cargoType] or capacities[cargoType] <= 0 then
			return false
		end
		return universalFilter(vehicleId)
	end
end
function vehicleUtil.getCargoCapacityFromId(vehicleId, cargoType) 
	if not vehicleUtil.cargoCapacityLookup then 
		discoverVehicles()
	end 
	return vehicleUtil.cargoCapacityLookup[vehicleId][cargoType]
end 

function vehicleUtil.getCargoCapacity(vehicle, cargoType)
	if type(cargoType) == "number" then
		cargoType = api.res.cargoTypeRep.get(cargoType).id
	end
	local transportVehicle = vehicle.metadata.transportVehicle
	for i, compartment in pairs(transportVehicle.compartments) do
		for j, loadConfig in pairs(compartment.loadConfigs) do
			for k, cargoEntry in pairs(loadConfig.cargoEntries) do
				if cargoEntry.type==cargoType then
					
					return cargoEntry.capacity
				end
			end
		end
	end

	return 0
	
end

function vehicleUtil.createVehicleConfig(modelId)
	local config = api.type.TransportVehicleConfig.new()
	local vehiclePart = initVehiclePart()
	vehiclePart.part.modelId = modelId
	config.vehicles[1]=vehiclePart
	config.vehicleGroups[1]=1
	return config
end

function vehicleUtil.filterToNonElectricLocomotive(vehicle)
	local engines = vehicle.metadata.railVehicle.engines
	for i, engine in pairs(engines) do
		if engine.type == api.type.enum.VehicleEngineType.ELECTRIC then  
			return false
		end
	end
	return true
end


local function calculateMaxConsistPerLoco(locoInfo, waggonInfo, cargoType, params)
 
	local locoMass = getVehicleMass(locoInfo.model)
	--local waggonCapacity = vehicleUtil.getCargoCapacity(waggonInfo.model, cargoType)
	local waggonCapacity = vehicleUtil.cargoCapacityLookup[waggonInfo.modelId][cargoType]
	local waggonMass = getVehicleMass(waggonInfo.model)
	 
	local cargoMass = waggonCapacity * vehicleUtil.cargoWeightLookup[cargoType] / 1000
	local totalwaggonMass = waggonMass + cargoMass
	
	local maxMass =calculateMaxMassForLocomotive(locoInfo.model, params)
	
	local maxCarriages  = math.floor( (maxMass-locoMass) / totalwaggonMass)
	--trace("maxCarriages calculated as ",maxCarriages,"maxMass=",maxMass,"locoMass=",locoMass,"totalwaggonMass=",totalwaggonMass)
	return math.max(1, maxCarriages) -- prevent downstream errors with zero carriages
end

vehicleUtil.cachedVehicleParts = {}

local function vehiclePartForId(modelId, loadConfigIdx)
	if vehicleUtil.cachedVehicleParts[modelId] then
		if vehicleUtil.cachedVehicleParts[modelId][loadConfigIdx] then
			return vehicleUtil.cachedVehicleParts[modelId][loadConfigIdx]
		end
	else
		vehicleUtil.cachedVehicleParts[modelId] = {}
	end
	local vehiclePart = {}
	vehiclePart.part = {}
	vehiclePart.part.loadConfig={loadConfigIdx < 0 and 0 or loadConfigIdx}
	vehiclePart.autoLoadConfig={1}  -- ALWAYS use autoLoadConfig for ANY cargo
	vehiclePart.part.modelId = modelId
	vehiclePart.part.reversed = false
	vehicleUtil.cachedVehicleParts[modelId][loadConfigIdx]=vehiclePart
	return vehiclePart
end

local function assembleConsistForWaggon(targetCapacity, params, waggonInfo, locoInfo, extraLocomotives)
	local config = {}
	config.vehicles = {} 
	config.vehicleGroups = {}
	local cargoType = params.cargoType
	--local waggonCapacity = vehicleUtil.getCargoCapacity(waggonInfo.model, cargoType)
	local waggonCapacity = vehicleUtil.cargoCapacityLookup[waggonInfo.modelId][cargoType]
	local waggonLength = getModelLengthx(waggonInfo.model)
	local waggonMass = getVehicleMass(waggonInfo.model)
 
	local cargoWeight = waggonCapacity * vehicleUtil.cargoWeightLookup[cargoType]
	cargoWeight = cargoWeight / 1000 -- seems to be in kg, everything else is in tons
	local desiredNumberOfWaggons = math.ceil(targetCapacity/waggonCapacity)
	local stationLength =params.stationLength 
		if not stationLength then 
		stationLength = paramHelper.getStationLength()
	end
	local maxLength = stationLength-4 -- have to subtract 4 for the length of the buffer stop
	
	desiredNumberOfWaggons = math.min(math.floor(maxLength/waggonLength), desiredNumberOfWaggons)
	local waggonTopSpeed = waggonInfo.model.metadata.railVehicle.topSpeed
	local targetSpeed = waggonTopSpeed
	local targetTractiveEffort = calculateTractiveEffortForMass((waggonMass+cargoWeight)*desiredNumberOfWaggons)
	--trace("Calculated targetspeed=",targetSpeed," and targetTractiveEffort=",targetTractiveEffort, " for targetCapacity=",targetCapacity, " allowElectricTrains=",allowElectricTrains)
	local filterFn
	if not params.isElectricTrack then 
		filterFn = vehicleUtil.filterToNonElectricLocomotive
	end
	if not locoInfo then 
		locoInfo = vehicleUtil.findBestMatchLocomotive(targetSpeed, targetTractiveEffort, filterFn, params )
	end
	local locoLength = getModelLengthx(locoInfo.model)
	local totalMass = 0
	local emptyMass = totalMass
	--trace("Found loco to use, locoLength=",locoLength)
	
	local maxWaggonsPerLoco  = calculateMaxConsistPerLoco(locoInfo, waggonInfo, cargoType, params)
	local function calculateLocomotivesRequired() 
		return math.ceil(desiredNumberOfWaggons/maxWaggonsPerLoco)
	end
	
	local numberOfLocomotivesRequired = calculateLocomotivesRequired()
	local function getLength() 
		return desiredNumberOfWaggons*waggonLength +numberOfLocomotivesRequired * locoLength
	end
	local proposedLength = getLength() 
	
	if proposedLength >  maxLength then
		--trace("The proposed length is exceeds station length. proposedLength=",proposedLength," stationlength=",maxLength, " cutting back. targetCapacity was ",targetCapacity)
		numberOfLocomotivesRequired = maxLength / (waggonLength*maxWaggonsPerLoco + locoLength)
		desiredNumberOfWaggons = maxWaggonsPerLoco * numberOfLocomotivesRequired
		--trace("After calculation, the optimal locomotives is ",numberOfLocomotivesRequired, " with ",desiredNumberOfWaggons, " waggons. New length is", getLength(), " theoretical locomotives required is", calculateLocomotivesRequired())
		desiredNumberOfWaggons =  math.max(math.floor(desiredNumberOfWaggons),1)
		numberOfLocomotivesRequired = calculateLocomotivesRequired()
		if getLength() > maxLength then 
			desiredNumberOfWaggons = desiredNumberOfWaggons -1
			numberOfLocomotivesRequired = calculateLocomotivesRequired()
		end
		if maxLength-getLength() > waggonLength then 
			desiredNumberOfWaggons = desiredNumberOfWaggons +1 
		end
		--trace("After rounding, the number of locomotives is ",numberOfLocomotivesRequired, " with ",desiredNumberOfWaggons, " waggons. New length is", getLength(), " theoretical locomotives required is", calculateLocomotivesRequired())
	end
	desiredNumberOfWaggons = math.max(desiredNumberOfWaggons, 1)
	if extraLocomotives then 
		numberOfLocomotivesRequired = math.max(1, numberOfLocomotivesRequired + extraLocomotives)
		while getLength() > maxLength do
			desiredNumberOfWaggons = desiredNumberOfWaggons -1
		end
	end
	
	
	for i = 1, numberOfLocomotivesRequired do  
		if i > 1 and vehicleUtil.locomotiveReplacments[locoInfo.modelId] then 
			config.vehicles[i]=vehiclePartForId(vehicleUtil.locomotiveReplacments[locoInfo.modelId], -1) 
		else 
			config.vehicles[i]=vehiclePartForId(locoInfo.modelId, -1)
		end 
		config.vehicleGroups[i]=1
	end 

	
	--trace("the waggonCapacity=",waggonCapacity," waggonMass=",waggonMass," cargoWeight=",cargoWeight, " numberOfLocomotivesRequired=",numberOfLocomotivesRequired, " desiredNumberOfWaggons=",desiredNumberOfWaggons)
	local loadConfigIdx = vehicleUtil.cargoIdxLookup[waggonInfo.modelId][params.cargoType]-1
	for i = 1,desiredNumberOfWaggons do  
		config.vehicles[i+numberOfLocomotivesRequired]=vehiclePartForId(waggonInfo.modelId, loadConfigIdx)
		config.vehicleGroups[i+numberOfLocomotivesRequired]=1
	end

	return { config = config, waggons = desiredNumberOfWaggons, locomotives = numberOfLocomotivesRequired}
end

local function assembleConsist(targetCapacity, params)
	
	
	local waggonInfo = vehicleUtil.findBestMatchWaggon(params)
	return assembleConsistForWaggon(targetCapacity, params, waggonInfo).config
end
function vehicleUtil.getVehichleCost(transportVehicleConfig)
	local cost = 0 
	if not vehicleUtil.modelRepLookup then 
		discoverVehicles()
	end
	for i, vehiclePart in pairs(transportVehicleConfig.vehicles) do  
		local model = vehicleUtil.modelRepLookup[vehiclePart.part.modelId] 
		cost = cost + model.metadata.cost.price
	end
	return cost
end 

function vehicleUtil.getConsistInfo(transportVehicleConfig, cargoType, params)
	if type(transportVehicleConfig) == "table" and transportVehicleConfig.consistInfo then 
		return transportVehicleConfig.consistInfo
	end
	local totalMass =0 
	local emptyMass =0
	local power = 0
	local tractiveEffort = 0
	local capacity = 0
	local cost = 0
	local runningCost = 0
	local emission = 0
	local lifespan = 2^16
	local engineType
	local topSpeed = 2^16 
	local length = 0
	local numCars = 0
	local loadSpeed = 0
	local leadName 
	local trailName
	local depreciation = 0
	local carrier 
	-- need to discover topSpeed first
	if not vehicleUtil.modelRepLookup then
		discoverVehicles()
	end

	-- CLAUDE: Guard against nil transportVehicleConfig
	if not transportVehicleConfig or not transportVehicleConfig.vehicles then
		trace("WARNING: transportVehicleConfig or vehicles is nil, returning empty consist info")
		return {
			totalMass = 0, emptyMass = 0, power = 0, tractiveEffort = 0,
			capacity = 0, cost = 0, runningCost = 0, emission = 0,
			lifespan = 0, topSpeed = 0, length = 0, numCars = 0,
			loadSpeed = 0, depreciation = 0
		}
	end

	for i, vehiclePart in pairs(transportVehicleConfig.vehicles) do 
		if not vehicleUtil.modelRepLookup[vehiclePart.part.modelId] then 
			vehicleUtil.modelRepLookup[vehiclePart.part.modelId] = api.res.modelRep.get(vehiclePart.part.modelId)
		end
		local vehicleMetaData = getVehicleConfig(vehicleUtil.modelRepLookup[vehiclePart.part.modelId])
		topSpeed = math.min(topSpeed, vehicleMetaData.topSpeed)
	end
	for i, vehiclePart in pairs(transportVehicleConfig.vehicles) do 
		numCars= numCars+1
		local model = vehicleUtil.modelRepLookup[vehiclePart.part.modelId]
		if i == 1 then 
			leadName = vehicleUtil.modelNameLookup[vehiclePart.part.modelId]
		end
		trailName =  vehicleUtil.modelNameLookup[vehiclePart.part.modelId]
		--local cargoCapacity = vehicleUtil.getCargoCapacity(model, cargoType)
		local cargoCapacity = vehicleUtil.cargoCapacityLookup[vehiclePart.part.modelId] and vehicleUtil.cargoCapacityLookup[vehiclePart.part.modelId][cargoType]  or vehicleUtil.getCargoCapacity(model, cargoType)
		local cargoMass = cargoCapacity * vehicleUtil.cargoWeightLookup[cargoType] / 1000
		capacity = capacity + cargoCapacity
		local vehicleMetaData = getVehicleConfig(model)
		local engines = vehicleMetaData.engines or  { vehicleMetaData.engine }
		for j , engine in pairs(engines) do 
			if engine.power then 
				power = power + engine.power
			end 
			if engine.tractiveEffort then 
				tractiveEffort = tractiveEffort + engine.tractiveEffort
			end 
			engineType = engine.type
		end
		if cargoCapacity > 0 then
			loadSpeed= loadSpeed + model.metadata.transportVehicle.loadSpeed
		end
		if model.metadata.emission then 
			emission = emission + model.metadata.emission.idleEmission
		end
		carrier  = model.metadata.carrier
		emptyMass = emptyMass + vehicleMetaData.weight
		totalMass = totalMass + vehicleMetaData.weight+ cargoMass
		lifespan = math.min(lifespan, model.metadata.maintenance.lifespan)
		cost = cost + model.metadata.cost.price
		depreciation = depreciation + (model.metadata.cost.price / model.metadata.maintenance.lifespan)*(12*60)--seems to be 60 ticks per in game month
		local thisTopSpeed = vehicleMetaData.topSpeed
		local adjustment = 1-(1-(topSpeed/thisTopSpeed))*(2/3) -- derived from experimentation
		runningCost = runningCost + model.metadata.maintenance.runningCosts*adjustment
		length = length + getModelLengthx(model)
	end
	local emptyAccel = calculateVehicleAcceleration2(power, tractiveEffort, topSpeed, emptyMass)
	local loadedAccel = calculateVehicleAcceleration2(power, tractiveEffort, topSpeed, totalMass)
	local maxLength = params and params.stationLength and params.stationLength-4 or paramHelper.getStationLength()-4
	local res =  {
		emptyMass = emptyMass,
		totalMass = totalMass,
		power = power,
		tractiveEffort = tractiveEffort,
		emission = emission,
		emptyAccel=emptyAccel,
		loadedAccel=loadedAccel,
		capacity=capacity,
		length = length,
		topSpeed = topSpeed,
		cost=cost,
		runningCost = runningCost,
		isElectric = engineType == api.type.enum.VehicleEngineType.ELECTRIC, 
		lifespan=lifespan,
		isMaxLength=maxLength-length < length/numCars,
		isHighSpeed = topSpeed > getStandardTrackSpeed() ,
		loadSpeed = loadSpeed,
		leadName = leadName,
		trailName = trailName,
		isVeryHighSpeedTrain = topSpeed > 200 / 3.6, -- 200 km/h in m/s
		numCars = numCars,
		depreciation = depreciation,
		carrier = carrier 
	}
	if type(transportVehicleConfig) == "table" then 
		transportVehicleConfig.consistInfo = res
	end 
	return res  
end
local function buildFromMultipleUnit(multipleUnitInfo, cargoType, targetCapacity, params)
	local numRepeats =1 
	local count = 0
	local result = {}
	local function buildMuConfig(numRepeats)
		local config = api.type.TransportVehicleConfig.new()
		for i = 1, numRepeats do
			for j, vehicleInfo in pairs(multipleUnitInfo) do 
				local car = initVehiclePart(params)
				car.part.modelId = vehicleInfo.modelId
				car.part.reversed = vehicleInfo.reversed and vehicleInfo.reversed or false -- explicit nil to false conversion
				config.vehicles[1+#config.vehicles]=car
				config.vehicleGroups[1+#config.vehicleGroups]=1
			end
		end
		return config
	end
	
	local config = buildMuConfig(1)
	 
	local info = vehicleUtil.getConsistInfo(config, cargoType, params)
	local numRepeats = math.ceil(targetCapacity/info.capacity)
	
	local maxRepeats = math.floor(((params.stationLength or paramHelper.getStationLength())-4)/info.length)
	if params.buildMaximumCapacityTrain then 
		numRepeats = maxRepeats
	elseif params.targetThroughput then 
		for i =1 , maxRepeats do 
			numRepeats = i
			if vehicleUtil.estimateThroughputBasedOnConsist(buildMuConfig(i), params).throughput >= params.targetThroughput then 
				break 
			end
		end
	end
	numRepeats = math.min(numRepeats, maxRepeats)
	local results ={} 
	if numRepeats <= maxRepeats then 
		table.insert(results, vehicleUtil.copyConfig(buildMuConfig(numRepeats)))
	end
	-- to give more options to select also build one more and one less than optimal 
	if numRepeats > 1 then 
		table.insert(results, vehicleUtil.copyConfig(buildMuConfig(numRepeats-1)))
	end
	
	if numRepeats < maxRepeats then 
		table.insert(results, vehicleUtil.copyConfig(buildMuConfig(numRepeats+1)))
	end
	
	return results
end
local function checkBudget(cost, params) 
	if params.constrainVehicleBudget then 
		--trace("Constraining vehicle budget")
		return cost <= util.getAvailableBalance() 
	end 
	return true 
end 
local alreadySeen = {}
local function evaluateBestPassengerTrainOption(vehicleConfigs,cargoType, targetCapacity, params)
	local choices = {}
	local begin = os.clock()
	for i , vehicleConfig in pairs(vehicleConfigs) do
		--debugPrint({vehicleConfig=vehicleConfig})
		local info = vehicleUtil.getConsistInfo(vehicleConfig, cargoType, params)
		
		local canAccept =(not info.isElectric or params.isElectricTrack or params.allowPassengerElectricTrains) and info.capacity > 0 and info.length < (params.stationLength or paramHelper.getStationLength())-4 
		if canAccept and params.constrainVehicleBudget then 
			canAccept = checkBudget(info.cost, params)
		end 
		
		if canAccept then
			local accelerationScore = 0
			if info.loadedAccel.d ~= info.loadedAccel.d then
				trace("WARNING invalid acceleration for ",info.leadName)
				goto continue 
			end
			accelerationScore = 1/info.loadedAccel.initialAcceleration + 1/info.loadedAccel.powerToWeight
			if params.distance then 
				local targetDist = 	paramHelper.getParams().targetTrainAccelerationDistance*params.distance
				--accelerationScore = math.abs(targetDist-info.loadedAccel.d)
				
			end
			local capacityScore = math.abs(info.capacity-targetCapacity)
			local p = vehicleUtil.calculateProjectedProfit(vehicleConfig, info, params)
			if params.targetThroughput then 
				capacityScore = math.abs(params.targetThroughput-p.maxThroughput)
			end 
			local speedGap = info.topSpeed - p.maxSpeedAchieved
			table.insert(choices, {
				config = vehicleConfig,
				p =p,
				speedGap=speedGap,
				leadName = info.leadName,
				scores = {
					capacityScore, 
					1/info.topSpeed, 
					info.emission,
					accelerationScore,
					2^24-p.projectedProfit,
					speedGap,
					p.totalTime
				}
			})
			
		else
			trace("rejected config as not allowElectricTrains for ",info.leadName, " capacity was ",info.capacity ," length was ", info.length)
		end
		::continue::
	end
	trace("evaluateBestPassengerTrainOption: time taken to prepare ",#choices," was ",(os.clock()-begin))
	local weights  =paramHelper.getParams().passengerTrainConsistScoreWeights
	if game.interface.getGameDifficulty() >=2 then
		weights = util.deepClone(weights)
		for i = 1 , #weights-1 do -- keep totalTime at original weight
			weights[i]=weights[i]/4
		end 
		weights[5]=100
	end 
	if params.isForVehicleReport then 
		return util.evaluateAndSortFromScores(choices, weights)
	end
	if #choices == 0 then 
		trace("WARNING! No choices found") 
		return 
	end
	local bestOption =  util.evaluateWinnerFromScores(choices, weights)
	if not bestOption then 
		trace("No best option!??")
		debugPrint({weights=weights})
		debugPrint({choices=choices})
	end
	local p = bestOption.p
	
	if util.tracelog and params.lineName  and false then -- and string.find(params.lineName, "Express") then 
		--[[if not alreadySeen[params.lineName] then 
			debugPrint({lineName = params.lineName, options=choices, bestOption=bestOption})
			alreadySeen[params.lineName]=true 
		else 
			trace("Already seen this")
			trace(debug.traceback())
		end]]--
		local reducedChoices = {}
		for i, choice in pairs(util.evaluateAndSortFromScores(choices, paramHelper.getParams().passengerTrainConsistScoreWeights)) do 
			local this = util.deepClone(choice)
			this.config = nil
			this.rank = i
			table.insert(reducedChoices, this)
			if i > 20 then 
				break 
			end
		end 
		debugPrint({lineName = params.lineName, reducedChoices=reducedChoices, bestOption=bestOption, targetCapacity=targetCapacity})
		trace(debug.traceback())
	end 
	if bestOption then 
		trace("For line",params.lineName,"The best passenger option was ",bestOption.leadName,"  projected ticket price=",p.projectedTicketPrice, " projectedPayment=",p.projectedPayment," projectedRevenue=",p.projectedRevenue, " projectedProfit=",p.projectedProfit, " runningCost=",p.runningCost, " throughput=",p.throughput, " projectedPaymentPerLoad=",p.projectedPaymentPerLoad, " distance=",params.distance, " totalTime=",p.totalTime, " totalTimeOriginal=",p.totalTimeOriginal, " total choices=",#choices, " time taken ",(os.clock()-begin), " targetCapacity=",targetCapacity)
	else 
		trace("WARNING! No options found")
	end 
	return bestOption and bestOption.config
	
end
local function getSelfPropelledVehicles(cargoType, params)
	local result = {}
	for i, vehicleDetails in pairs(findVehiclesOfType("train", params)) do
		if #vehicleDetails.model.metadata.railVehicle.engines > 0 and vehicleUtil.cargoCapacityLookup[vehicleDetails.modelId][cargoType] > 0 then 
			table.insert(result, vehicleDetails)
		end
	end
	return result
end
function vehicleUtil.assembleConsistForTargetThroughput(waggonInfo, locoInfo, targetThroughput, params, extraLocomotives)
	local waggonCapacity = vehicleUtil.cargoCapacityLookup[waggonInfo.modelId][params.cargoType]
	local length = getModelLengthx(waggonInfo.model)
	local maxWaggons = math.ceil(((params.stationLength or paramHelper.getStationLength())-4)/length) 
	local consist = assembleConsistForWaggon(maxWaggons*waggonCapacity, params, waggonInfo, locoInfo, extraLocomotives)
	local throughputInfo = vehicleUtil.estimateThroughputBasedOnConsist(consist.config, params)
	local throughput = throughputInfo.throughput
	if debugResults then 
		trace("assembleConsistForTargetThroughput: maxCapacity: the throughput",throughput,"as less than the targetThroughput at ",targetThroughput,"?",throughput<targetThroughput,"params.totalTargetThroughput=",params.totalTargetThroughput)
	end 
	if params.buildMaximumCapacityTrain then 
		--trace("assembleConsistForTargetThroughput: buildMaximumCapacityTrain")
		return consist
	end 
	if params.fractionBasedReachability  then 
		--trace("found fractionBasedReachability, totalTime=",params.fractionBasedReachability.totalTime,"currentFraction=",params.fractionBasedReachability.fractionOfTotal)
			
		if params.fractionBasedReachability.totalTime > twentyMinutes then 
			local currentFraction = params.fractionBasedReachability.fractionOfTotal
			local maxThroughput = targetThroughput / currentFraction
			local thisTotalTime = throughputInfo.totalTime
			--trace("Adjusting the targetThroughput based on the total time was",targetThroughput,"new time=",thisTotalTime,"maxThroughput=",maxThroughput,"currentFraction=",currentFraction)
			if thisTotalTime > twentyMinutes then 
				local newFraction = twentyMinutes  /  thisTotalTime
				targetThroughput = maxThroughput * newFraction
			--	trace("Setting the targetThroughput to",targetThroughput,"based on new fraction",newFraction,"thisTotalTime=",thisTotalTime)
			else 
				targetThroughput = maxThroughput
			--	trace("Setting the targetThroughput to maxThroughput of",maxThroughput)
			end 
			 
		end 
	end 
	if throughput < targetThroughput and params.isCargo then 
		if throughput > 0.9*targetThroughput then 
			return consist 
		else 
			local estimate = math.ceil(targetThroughput / throughput) -- try to get a whole number of vehicles
			local originalTarget = targetThroughput
			targetThroughput = targetThroughput / estimate
		 	--trace("based on targetThroughput=",originalTarget,"and max throughput=",throughput,"estimating vehicles =",estimate," reducing targetThroughput to",targetThroughput)
			assert(targetThroughput<=originalTarget)
		end 
	end 
	if params.isCargo and params.totalTargetThroughput  and throughput > params.totalTargetThroughput   then 
		trace("assembleConsistForTargetThroughput: setting target throughput to maximum for cargo")
		targetThroughput = params.totalTargetThroughput
	
	end 
	local fraction =   targetThroughput/ throughput
	
	local numWaggons =  math.min(maxWaggons, math.max(math.ceil(maxWaggons*fraction) , 1))

	--trace("setting the targetNumWaggons to",numWaggons,"based on maxWaggons=",maxWaggons,"faction=",fraction)
	
	
	local done = false 
	local count = 0
	 
	repeat -- hmm half implemented binary search 
		local nextConsist = assembleConsistForWaggon(numWaggons*waggonCapacity, params, waggonInfo, locoInfo, extraLocomotives)
		if count == 0 then 
			consist = nextConsist -- save it off in case we exit 
		end 
		local nextThroughput = vehicleUtil.estimateThroughputBasedOnConsist(nextConsist.config, params).throughput
		if count == 0 and nextThroughput < targetThroughput and numWaggons< maxWaggons then
			while numWaggons < maxWaggons and nextThroughput < targetThroughput do
				numWaggons = numWaggons + 1
				nextConsist = assembleConsistForWaggon(numWaggons*waggonCapacity, params, waggonInfo, locoInfo, extraLocomotives)
				nextThroughput = vehicleUtil.estimateThroughputBasedOnConsist(nextConsist.config, params).throughput
			--	trace("assembleConsistForTargetThroughput: numWaggons incremented to",numWaggons,"nextThroughput=",nextThroughput)
			end
		elseif nextThroughput > targetThroughput and numWaggons > 1 then 
			consist = nextConsist
			numWaggons = numWaggons - 1
		--	trace("assembleConsistForTargetThroughput: numWaggons decremented to",numWaggons,"nextThroughput=",nextThroughput)
		else 
			done = true
		--	trace("assembleConsistForTargetThroughput: done at numWaggons=",numWaggons)
		end 		
		
		count = count+1
		if count > maxWaggons then 
		--	trace("WARNING! assembleConsistForTargetThroughput was not able to solve",count,"numWaggons=",numWaggons,"numWaggons=",numWaggons)
		end 
	until done or count > maxWaggons
	
	return consist
	
	--[[
	local consistMeetingTargetThroughput
	local consistMeetingTotalThroughput
	for i = waggonCapacity, maxWaggons*waggonCapacity, waggonCapacity do 
		consist = assembleConsistForWaggon(i, params, waggonInfo, locoInfo, extraLocomotives)
		local throughput = vehicleUtil.estimateThroughputBasedOnConsist(consist.config, params).throughput
		if not consistMeetingTargetThroughput and throughput >= targetThroughput then 
			consistMeetingTargetThroughput=  consist
		end
		if not consistMeetingTotalThroughput and throughput >= params.totalTargetThroughput then 
			consistMeetingTotalThroughput=  consist
		end
	end
	return consistMeetingTotalThroughput or consistMeetingTargetThroughput or consist]]--
end

function vehicleUtil.calculateProjectedProfit(config, info, params, vehicleCount)
	local throughputInfo =  vehicleUtil.estimateThroughputBasedOnConsist(config, params) 
	local throughput = throughputInfo.throughput
	local isCargo = params.cargoType ~= "PASSENGERS" 
	if params.targetThroughput then
		local originalThroughput = throughput
		if vehicleCount and params.totalTargetThroughput and vehicleCount > 0 then 
			throughput = math.min(throughput, params.totalTargetThroughput / vehicleCount )
		else  
			-- need to clamp the expected throughput to the actual demand, any extra capacity will not produce revenue
			if params.totalTargetThroughput and throughput >= params.totalTargetThroughput and false then -- why did i do this?? 
				throughput = math.min(throughput, params.totalTargetThroughput)
			else 
				throughput = math.min(throughput, params.targetThroughput)
			end
		end
		if params.fractionBasedReachability then 
			--trace("found fractionBasedReachability, totalTime=",params.fractionBasedReachability.totalTime,"currentFraction=",params.fractionBasedReachability.fractionOfTotal)
			
			if params.fractionBasedReachability.totalTime > twentyMinutes then 
				local currentFraction = params.fractionBasedReachability.fractionOfTotal
				local maxThroughput = throughput / currentFraction
				local thisTotalTime = throughputInfo.totalTime
				trace("Adjusting the throughput based on the total time was",throughput,"new time=",thisTotalTime,"maxThroughput=",maxThroughput,"currentFraction=",currentFraction)
				if thisTotalTime > twentyMinutes then 
					local newFraction = twentyMinutes  /  thisTotalTime
					throughput = maxThroughput * newFraction
					trace("Setting the throughput to",throughput,"based on new fraction",newFraction,"thisTotalTime=",thisTotalTime)
				else 
					throughput = maxThroughput
					trace("Setting the throughput to maxThroughput of",maxThroughput)
				end 
				trace("Constraining the throughput to the actual vehicle capacity of ",originalThroughput,"from",throughput)
				throughput = math.min(throughput, originalThroughput)
			end 
		end 
		if params.isForVehicleReport then 
			trace("Clamping throughput, originally",originalThroughput," new throughput=",throughput,"targetThroughput=",params.targetThroughput," totalTargetThroughput=",params.totalTargetThroughput,"vehicleCount=",vehicleCount)
		end
	else
		-- No targetThroughput provided - use actual throughput (don't clamp)
		trace("Did not clamp throughput of ",throughput," (no targetThroughput provided)")
	end 
	-- thank you to this source for ticket price calculation:
	-- https://www.reddit.com/r/TransportFever/comments/rj8b9l/so_i_heard_yall_were_wondering_how_payment_is/
	--local cargoFactor = 1.75
	local cargoFactor = 1
	local speedKmh = info.topSpeed*3.6
	local projectedTicketPrice = 10 + speedKmh^0.86
	if params.carrier == api.type.enum.Carrier.ROAD then 
		projectedTicketPrice = 4 + speedKmh^0.78
	elseif params.carrier == api.type.enum.Carrier.WATER then 
		projectedTicketPrice = 0.65 * speedKmh
	elseif params.carrier == api.type.enum.Carrier.AIR then 
		projectedTicketPrice = -2.03e-5*speedKmh^2  + 0.17*speedKmh + 28.36
	end 
	
	local sections = 2 
	local assumedDistance = params.distance
	if params.line  or params.routeInfos  then 
		sections = params.line and #params.line.stops or #params.routeInfos
		--[[if params.cargoType and params.cargoType ~= "PASSENGERS" then 
			trace("reducing assumed sections by 1")
			sections = sections - 1 
		end]]--
		assumedDistance = throughputInfo.straightLineDistance / sections
		if params.isForVehicleReport then 
			trace("Recalculating average distance based on secions averageDistance= ",assumedDistance," params.distance=",params.distance," for ",sections," sections")
		end
	end 
	local projectedPaymentOld = 0.1*(math.max(300 , params.distance))*projectedTicketPrice*cargoFactor
	
 -- 	https://www.reddit.com/r/TransportFever/comments/ztpldt/update_payment_formula/
	local millisPerDay = 2000 -- think this is now fixed in TPF2, since the data can be paused this would give a divide by zero
	local cargoFactor = isCargo and 1.75 or 1
	local projectedPayment = (300.0 +  assumedDistance) * projectedTicketPrice * (cargoFactor) * 125 / millisPerDay * vehicleUtil.difficultyModifier
	
	
	local projectedPaymentPerLoad = projectedPayment*info.capacity
	local projectedRevenue =  math.log(sections,2)*projectedPayment * throughput
	local costBeforeDepreciation = info.runningCost
--	local totalCost = info.depreciation + info.runningCost
	local totalCost = info.runningCost
	local projectedProfit = projectedRevenue - totalCost
	if params.isForVehicleReport then 
		trace("Caluclated the cost with depreciation as ",totalCost," runningcost=",info.runningCost," depreciation=",info.depreciation, " projectedProfit=",projectedProfit, " projectedTicketPrice=",projectedTicketPrice," projectedPaymentOld=",projectedPaymentOld,"projectedPayment=",projectedPayment, "isCargo?",isCargo)
	end
	local profitBeforeDepreciation = projectedRevenue - costBeforeDepreciation
	return {
		projectedPayment = projectedPayment,
		projectedTicketPrice = projectedTicketPrice,
		projectedRevenue = projectedRevenue,
		projectedProfit = projectedProfit,
		runningCost = info.runningCost ,
		throughput= throughput,
		leadName = info.leadName,
		projectedPaymentPerLoad=projectedPaymentPerLoad,
		projectedProfit = projectedProfit,
		totalTime = throughputInfo.totalTime,
		totalTimeOriginal = throughputInfo.totalTimeOriginal,
		maxThroughput = throughputInfo.throughput,
		averageSpeed = throughputInfo.averageSpeed,
		routeLength = throughputInfo.routeLength,
		projectedTimings = throughputInfo.projectedTimings,
		projectedTimingsRaw = throughputInfo.projectedTimingsRaw,
		projectedLoadTime = throughputInfo.projectedLoadTime,
		topSpeed = info.topSpeed,
		maxSpeedAchieved = throughputInfo.maxSpeedAchieved,
		costBeforeDepreciation = costBeforeDepreciation,
		profitBeforeDepreciation = profitBeforeDepreciation,
		depreciation = info.depreciation,
	}
end

local function assembleConsistUsingWaggonAndLocomotive(targetCapacity, params, waggonInfo, locoInfo, extraLocomotives)
	if params.targetThroughput then 
		return vehicleUtil.assembleConsistForTargetThroughput(waggonInfo, locoInfo, params.targetThroughput, params, extraLocomotives)
	else 
		return assembleConsistForWaggon(targetCapacity, params, waggonInfo, locoInfo, extraLocomotives)
	end
end

function vehicleUtil.buildAllConsistPermutations(targetCapacity, params) 
	profiler.beginFunction("buildAllConsistPermutations")
	local results ={}
	trace("buildAllConsistPermutations: begin")
	local locos = getAllAvailableLocomotives(params) 
	local waggons = vehicleUtil.getWaggonsByCargoType(params.cargoType, params)
	trace("Build all consistPermutations got num locos=",#locos,"num waggons=",#waggons)
	for i, waggonInfo in pairs(waggons) do
		for j, locoInfo in pairs(locos) do 
			profiler.beginFunction("assembleConsistUsingWaggonAndLocomotive")
			local consist = assembleConsistUsingWaggonAndLocomotive(targetCapacity, params, waggonInfo, locoInfo, 0)
			profiler.endFunction("assembleConsistUsingWaggonAndLocomotive")
			if consist.waggons > 0 and  checkBudget(vehicleUtil.getVehichleCost(consist.config), params)   then 
				table.insert(results, consist.config)
			end 
			local startFrom =  consist.locomotives > 1 and -1 or 1
			local endAt = math.min(consist.locomotives , 2)
			
			if #waggons * #locos < 200 then -- for performance do not do this step if we have a large number of these
				for extraLocomotives = startFrom , endAt do 
					if extraLocomotives ~= 0 then 
						profiler.beginFunction("assembleConsistUsingWaggonAndLocomotive extraLocomotives")
						local consist = assembleConsistUsingWaggonAndLocomotive(targetCapacity, params, waggonInfo, locoInfo, extraLocomotives)
						profiler.endFunction("assembleConsistUsingWaggonAndLocomotive extraLocomotives")
						if consist.waggons > 0 and  checkBudget(vehicleUtil.getVehichleCost(consist.config), params)  then
							table.insert(results, consist.config)
						end
						
					end
				end
			end
		end
	end
	profiler.endFunction("buildAllConsistPermutations")
	return results
end


function vehicleUtil.solveAndBuildOptimalCargoTrain(targetCapacity, params)
	profiler.beginFunction("solveAndBuildOptimalCargoTrain")
	local options = {}
	local begin = os.clock()
	local minVehicleCount = math.huge 
	local maxVehicleCount = 1
	trace("solveAndBuildOptimalCargoTrain: about to buildAllConsistPermutations")
	local consistPermutations =vehicleUtil.buildAllConsistPermutations(targetCapacity, params) 
	trace("solveAndBuildOptimalCargoTrain: built",#consistPermutations,"consists in",(os.clock()-begin))
	for i, config in pairs(consistPermutations) do
		 
		local info = vehicleUtil.getConsistInfo(config, params.cargoType, params)
		local vehicleCount = 1
		local p = vehicleUtil.calculateProjectedProfit(config, info, params)
		if params.totalTargetThroughput then 
			vehicleCount = math.ceil(params.totalTargetThroughput / p.maxThroughput)
			p = vehicleUtil.calculateProjectedProfit(config, info, params,vehicleCount) 
		end
		if p.projectedProfit ~= p.projectedProfit then 
				trace("NAN profit detected:",info.leadName,"  projected ticket price=",p.projectedTicketPrice, " projectedPayment=",p.projectedPayment," projectedRevenue=",p.projectedRevenue, " projectedProfit=",p.projectedProfit, " runningCost=",p.runningCost, " throughput=",p.throughput, " projectedPaymentPerLoad=",p.projectedPaymentPerLoad, " distance=",params.distance, " totalTime=",p.totalTime," totalTimeOriginal=",p.totalTimeOriginal)
		else 
			if vehicleCount ~= vehicleCount then 
				vehicleCount = 1
			end 
			minVehicleCount = math.min(minVehicleCount, vehicleCount)
			maxVehicleCount = math.max(maxVehicleCount, vehicleCount)
			table.insert(options, {
				config = config,
				p = p,
				projectedPayment = p.projectedPayment,
				projectedTicketPrice = p.projectedTicketPrice,
				projectedRevenue = p.projectedRevenue,
				projectedProfit = p.projectedProfit,
				runningCost = info.runningCost ,
				throughput= p.throughput,
				leadName = info.leadName,
				totalTime = p.totalTime,
				length = info.length,
				projectedPaymentPerLoad=p.projectedPaymentPerLoad,
				vehicleCount = vehicleCount,
				scores = { 
					2^28-p.projectedProfit, -- smaller is better,
					vehicleCount,
					p.totalTime, -- adding this in to give a boost to power
					info.isElectric and 1 or 0, -- electric penalty for the cost of upgrading
				}
			})
		end
  
	end
	trace("solveAndBuildOptimalCargoTrain: Time taken to build ",#options, " was ",(os.clock()-begin), " the maxVehicleCount=",maxVehicleCount,"the minVehicleCount=",minVehicleCount)
	local weights = { 90, 10, 20, 10 }
	if params.minimiseRequiredVehicles then 
		trace("vehicleBuilder: adjusting score weights to minimise vehicle count")
		weights = { 90, 75, 20, 10}
	end 
	if params.isForVehicleReport then 
		return util.evaluateAndSortFromScores(options, weights)
	end
	if #options == 0 then 
		trace("WARNING! No options found")
		profiler.endFunction("solveAndBuildOptimalCargoTrain")
		return 
	end

	local bestOption = util.evaluateWinnerFromScores(options, weights)

	
	trace("The best option was ",bestOption.leadName," vehicle count=",bestOption.vehicleCount,"length=",bestOption.length,"  projected ticket price=",bestOption.projectedTicketPrice, " projectedPayment=",bestOption.projectedPayment," projectedRevenue=",bestOption.projectedRevenue, " projectedProfit=",bestOption.projectedProfit, " runningCost=",bestOption.runningCost, " throughput=",bestOption.throughput, " projectedPaymentPerLoad=",bestOption.projectedPaymentPerLoad, " distance=",params.distance," time taken:",(os.clock()-begin))
	profiler.endFunction("solveAndBuildOptimalCargoTrain")
	return bestOption.config
end

function vehicleUtil.getTopSpeed(vehicleConfig) 
	if not vehicleUtil.modelRepLookup then 
		discoverVehicles() 
	end 
	local vehicle = vehicleUtil.modelRepLookup[vehicleConfig.vehicles[1].part.modelId]
	return getVehicleConfig(vehicle).topSpeed
end 

function vehicleUtil.buildTrain(targetCapacity, params)
	if params.locomotiveRestriction == -1 and climate=="usa" and util.year() < 2000 and params.isCargo and climateRestrictionsInForce then 
		params.locomotiveRestriction =  api.type.enum.VehicleEngineType.ELECTRIC 
	end
	if not params.stationLength then 
		trace("WARNING! No length specified")
		trace(debug.traceback())
	end  
	local cargoType = params.cargoType
	if isCargo(cargoType) then 
		return vehicleUtil.solveAndBuildOptimalCargoTrain(targetCapacity, params)
	end
	profiler.beginFunction("buildTrain (PASSENGERS)")
	local begin = os.clock()
	local results = vehicleUtil.buildAllConsistPermutations(targetCapacity, params) 
	local buildTrains = os.clock()
	trace("checking consists against prebuilt options, time taken for train build ",(buildTrains-begin),"number before adding Mu was",#results)
	
	local muTypes = getMultipleUnitTypes(params)
	for i, multipleUnitInfo in pairs(muTypes) do 
		--trace("Adding multiple unit info, i=",i, " of ",#muTypes)
		if params.vehicleFavourites and params.vehicleFavourites["train"] then 
			if not params.vehicleFavourites[multipleUnitInfo[1].modelId] then 	
				goto continue 
			end
		end
		for i, result in pairs(buildFromMultipleUnit(multipleUnitInfo, cargoType, targetCapacity, params)) do 
			table.insert(results,result )
		end
		::continue::
	end
	local selfPropelledTime = os.clock()
	trace("about to get self propelled cars, time taken to getMu",(selfPropelledTime-buildTrains),"number now",#results)
	local selfPropelled = getSelfPropelledVehicles(cargoType, params)
	--trace("got ",#selfPropelled, " selfPropelled cars")
	for i, modelInfo in pairs(selfPropelled) do 
		--trace("Adding self propelled unit info, i=",i)
		for i, result in pairs(buildFromMultipleUnit({modelInfo}, cargoType, targetCapacity, params)) do 
			table.insert(results,result )
		end
	end
	trace("Time taken to build ",#results," was ",(os.clock()-begin), " self propelled time ",(os.clock()-selfPropelledTime))
	--debugPrint(results)
	local result=  evaluateBestPassengerTrainOption(results,cargoType, targetCapacity, params)
	profiler.endFunction("buildTrain (PASSENGERS)")
	return result
end
	
function vehicleUtil.getLoadTime(vehicleConfig, cargoType) 
	local capacity =  vehicleUtil.calculateCapacity(vehicleConfig, cargoType) 
	
	local loadSpeed = 0 
	for i = 1, #vehicleConfig.vehicles do 
		local modelId = vehicleConfig.vehicles[i].part.modelId
		loadSpeed = loadSpeed + vehicleUtil.getModel(modelId).metadata.transportVehicle.loadSpeed
	end
	return capacity / loadSpeed 
end 

function vehicleUtil.isHighSpeedTrainsAvailable() -- defined as 100mph or 160km/h
	local foundHighSpeedWaggon = false 
	local foundHighSpeedLoco = false 
	local targetSpeed = 159 / 3.6 -- one less to account for rounding errors
	for i, vehicle in pairs(findVehiclesOfType("train")) do 
		if getVehicleConfig(vehicle.model).topSpeed >= targetSpeed then 
			foundHighSpeedLoco = true 
			break 
		end 
	end 	
	for i, vehicle in pairs(findVehiclesOfType("waggon")) do 
		if getVehicleConfig(vehicle.model).topSpeed >= targetSpeed then 
			foundHighSpeedWaggon = true 
			break 
		end 
	end 	
	if foundHighSpeedLoco and foundHighSpeedWaggon then 
		return true 
	end 
	for i, multipleUnitInfo in pairs(getMultipleUnitTypes()) do
		if getVehicleConfig(multipleUnitInfo[1].model).topSpeed  >= targetSpeed then 
			return true 
		end 
	end 
	 
	
	return false
end 
function vehicleUtil.estimateThroughputBasedOnConsist(config, params)
	if not config then 
		trace("WARNING! No config provided")
		return { 
			throughput = 0,
			isEmptyConsist = true
		}
	end
	profiler.beginFunction("estimateThroughputBasedOnConsist")
	local distance = params.distance
	local info = vehicleUtil.getConsistInfo(config, params.cargoType, params)
	local projectedTimings = {} 
	local projectedTimingsRaw = {}
	local routeLength = 0
	local totalTime 
	local totalTimeOriginal 
	local loadTime
	local loadStationFactor = params.isCargo and 1 or 2 -- N.B. loading and unloading are considered two seperate steps
	if params.loadStationFactor then 
		loadStationFactor = ( params.currentCapacity/info.capacity ) * params.loadStationFactor
	end
	local maxSpeedAchieved = 0
	local straightLineDistance = 0
	if params.line or params.routeInfos then 
		local line = params.line
		totalTime = 0 
		loadTime = 0
		totalTimeOriginal = 0
		local endAt = line and #line.stops or #params.routeInfos
		for i = 1, endAt do 
		
			
			if not params.routeInfos then 
				params.routeInfos = {}
			end
			if not params.routeInfos[i] and line then
				--[[if not line then 
					trace("WARNING! Missing routeInfo at i=",i," skipping")
					goto continue 
				end]]--
				local nextStop = i == #line.stops and line.stops[1] or line.stops[i+1]
				local stationGroup1 = util.getComponent(line.stops[i].stationGroup, api.type.ComponentType.STATION_GROUP)
				local stationGroup2 = util.getComponent(nextStop.stationGroup, api.type.ComponentType.STATION_GROUP)
				local station1 = stationGroup1.stations[line.stops[i].station+1]
				local station2 = stationGroup2.stations[nextStop.station+1]
				if not params.routeInfoMissing then --prevent repeated attempts
					if info.carrier == api.type.enum.Carrier.RAIL then 
						params.routeInfos[i] = pathFindingUtil.getRouteInfo(station1, station2)
					elseif info.carrier == api.type.enum.Carrier.ROAD then 
						params.routeInfos[i] = pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2)
					end 
				end 
				params.distance = util.distBetweenStations(station1, station2)
			end
			if params.routeInfos[i] then 
				params.routeInfo = params.routeInfos[i]
				params.distance = params.routeInfo.straightDistance
				straightLineDistance = straightLineDistance + params.routeInfo.straightDistance
			else 
				params.routeInfoMissing = true 
				--trace("WARNING! No routeInfo found estimateThroughputBasedOnConsist")
			end 
			local accel = info.loadedAccel
			if params.isCargo and i ==2 then 
				accel = info.emptyAccel
				--trace("Setting accel to empty for cargo")
			end
			local tripTime = calculateTripTime(accel, params, info.topSpeed, true,info)
			table.insert(projectedTimings, tripTime.totalTime)
			table.insert(projectedTimingsRaw, tripTime.originalTotalTime)
			maxSpeedAchieved = math.max(maxSpeedAchieved, tripTime.maxSpeedAchieved)
			totalTime = totalTime + tripTime.totalTime
			totalTimeOriginal = totalTimeOriginal + tripTime.originalTotalTime
			loadTime = loadTime + loadStationFactor*(info.capacity/info.loadSpeed) 
			if params.routeInfos[i] then 
				routeLength = routeLength + params.routeInfos[i].routeLength
			end
			::continue::
		end 
	else 
		local outboundTripTime = calculateTripTime(info.loadedAccel, params, info.topSpeed, true,info)
		local returnTripTime = calculateTripTime(info.emptyAccel, params, info.topSpeed, false,info)
		projectedTimings = {
			outboundTripTime.totalTime,
			returnTripTime.totalTime 
		}
		projectedTimingsRaw = {
			outboundTripTime.originalTotalTime,
			returnTripTime.originalTotalTime 
		}
		maxSpeedAchieved = math.max(outboundTripTime.maxSpeedAchieved, returnTripTime.maxSpeedAchieved)
		
		totalTime	=outboundTripTime.totalTime+returnTripTime.totalTime 
		totalTimeOriginal = outboundTripTime.originalTotalTime+returnTripTime.originalTotalTime 
		loadTime =  2*(info.capacity/info.loadSpeed)
		if params.routeInfo then 
			routeLength = params.routeInfo.routeLength*2
			straightLineDistance = params.routeInfo.straightDistance*2
		else 
			routeLength = params.distance*2
			straightLineDistance = routeLength
		end
		
	end
	if loadTime ~= loadTime then 
		--debugPrint({vehicleInfo=info})
	--	trace("NAN loadTime detected")
	end
	local uncorrectedTimings = util.deepClone(projectedTimings)
	if params.sectionTimeCorrection then 
		local correctedTime = totalTime * params.sectionTimeCorrection
		--trace("Correcting the section time by ", params.sectionTimeCorrection, " originally:",util.formatTime(totalTime)," corrected:",util.formatTime(correctedTime))
		totalTime = correctedTime
		for i = 1 , #projectedTimings do 
			projectedTimings[i]=projectedTimings[i]*params.sectionTimeCorrection
		end 
	end 
	local totalSectionTime = totalTime
	totalTime = totalTime + loadTime
	local throughput = info.capacity /  totalTime
	if totalTime == 0 then 
		debugPrint(info )
		trace("Had params.line or params.routeInfos ?",(params.line or params.routeInfos ))
		trace(debug.traceback)
		totalTime = 100
		trace("ERROR total time was zero")
		throughput = 10 
	--	error("Total time was zero")
	end
	local throughputPer12min = throughput * 12 * 60
	local averageSpeed = routeLength/totalTime 
	--trace("Calculated averageSpeed as ",api.util.formatSpeed(averageSpeed), " based on routeLength=",routeLength," and totalTime=",totalTime, " sectionTImeCorrection was ",params.sectionTimeCorrection )
	--trace("for ",info.numCars," waggons outboundTripTime= ", outboundTripTime," returnTripTime= ",returnTripTime,   " totalTime=",totalTime, " totalCapacity=",totalCapacity, " distance=",distance,  " throughput=",throughput, " throughputPer12min=",throughputPer12min, " loadTime=",loadTime, "topSpeed=",info.topSpeed," isHighSpeed?",info.isHighSpeed)
	--end 
	profiler.endFunction("estimateThroughputBasedOnConsist")
	return {
		maxSpeedAchieved = maxSpeedAchieved,
		throughput = throughputPer12min, 
		totalCapacity=info.capacity,
		totalTime=totalTime,
		isMaxLength=info.isMaxLength, 
		totalTimeOriginal=totalTimeOriginal,
		averageSpeed = averageSpeed,
		routeLength= routeLength,
		projectedTimings=projectedTimings, 
		projectedTimingsRaw=projectedTimingsRaw, 
		projectedLoadTime=loadTime,
		totalSectionTime=totalSectionTime,
		straightLineDistance = straightLineDistance,
		uncorrectedTimings = uncorrectedTimings,
		}
end

function vehicleUtil.estimateThroughputBasedOnCapacity( distance, targetCapacity, params)
	
	params.distance = distance
	local targetThroughput = params.targetThroughput
	--params.targetThroughput = 2^16
	params.buildMaximumCapacityTrain = true 
	local config = vehicleUtil.buildTrain(targetCapacity, params)
	params.targetThroughput = targetThroughput
	params.buildMaximumCapacityTrain = false
	return vehicleUtil.estimateThroughputBasedOnConsist(config, params)
end
function vehicleUtil.estimateMaxThroughputPerConsist(distance, params)
	return vehicleUtil.estimateThroughputBasedOnCapacity( distance, 2^16, params)
end

function vehicleUtil.copyConfig(newVehicleConfig) -- seems like we need to store this data in lua objects to avoid strange effects (disspearing)
	local copy = {}
	copy.vehicles ={}
	copy.vehicleGroups = {} 
	for i, vehicle in pairs(newVehicleConfig.vehicles) do 
		local vehicleCopy = {}
		vehicleCopy.part = {}
		vehicleCopy.part.loadConfig= util.deepClone(vehicle.part.loadConfig)
		vehicleCopy.autoLoadConfig= util.deepClone(vehicle.autoLoadConfig)
		vehicleCopy.part.modelId = vehicle.part.modelId
		vehicleCopy.part.reversed = vehicle.part.reversed
		vehicleCopy.purchaseTime = vehicle.purchaseTime
		vehicleCopy.targetMaintenanceState = vehicle.targetMaintenanceState
		copy.vehicles[i] = vehicleCopy
	end
	for k, v in pairs(newVehicleConfig.vehicleGroups) do 
		copy.vehicleGroups[k]=v
	end
	return copy
end


function vehicleUtil.copyConfigToApi(newVehicleConfig, params) -- reverses the process above
	trace("===== copyConfigToApi =====")
	trace("  input vehicles count=", newVehicleConfig and newVehicleConfig.vehicles and #newVehicleConfig.vehicles or "nil")
	local copy  = api.type.TransportVehicleConfig.new()
	for i, vehicle in pairs(newVehicleConfig.vehicles) do
		local modelName = vehicle.part and vehicle.part.modelId and api.res.modelRep.getName(vehicle.part.modelId) or "unknown"
		trace("  copying vehicle[", i, "]: modelId=", vehicle.part and vehicle.part.modelId, " name=", modelName)
		local vehicleCopy = initVehiclePart( params)
		vehicleCopy.part.modelId = vehicle.part.modelId
		vehicleCopy.part.reversed = vehicle.part.reversed
		vehicleCopy.part.loadConfig= util.deepClone(vehicle.part.loadConfig)
		vehicleCopy.autoLoadConfig= util.deepClone(vehicle.autoLoadConfig)
		if vehicle.targetMaintenanceState then
			vehicleCopy.targetMaintenanceState = vehicle.targetMaintenanceState
		end
		copy.vehicles[i] = vehicleCopy
	end
	for k, v in pairs(newVehicleConfig.vehicleGroups) do
		copy.vehicleGroups[k]=v
	end
	trace("  output vehicles count=", copy.vehicles and #copy.vehicles or "nil")
	return copy
end

function vehicleUtil.estimateThroughputPerConsist(distance, targetLineRate, params)
	local cargoType =params.cargoType
	trace("Estimating capacity for consist, based on cargoType=",cargoType)
	if params.locomotiveRestriction == -1 and climate=="usa" and util.year() < 2000 and params.isCargo and climateRestrictionsInForce then 
		params.locomotiveRestriction =  api.type.enum.VehicleEngineType.ELECTRIC 
	end 
	params.distance = distance
	--params.targetThroughput = targetLineRate
	local converged = false 
	local minCapacity = 2^16
	local minLength = 2^16
	for i , waggon in pairs(vehicleUtil.getWaggonsByCargoType(cargoType, params)) do 
		minCapacity = math.min(minCapacity, vehicleUtil.cargoCapacityLookup[waggon.modelId][cargoType])
		minLength = math.min(minLength, getModelLengthx(waggon.model))
	end
	local stationLength =params.stationLength 
	if not stationLength then 
		stationLength = paramHelper.getStationLength()
	end
	local maxWaggons = math.ceil((stationLength-4)/minLength)
	local maxThroughput = vehicleUtil.estimateMaxThroughputPerConsist( distance, params)
	local targetCapacity  = math.ceil(targetLineRate / 10)
	--params.targetTrainThroughput = 
	for testCapacity = minCapacity, maxWaggons*minCapacity, minCapacity do 
		
		local throughput = vehicleUtil.estimateThroughputBasedOnCapacity( distance, testCapacity, params)
		if throughput.throughput>targetLineRate then 
			trace("determined that the line rate can be achieved with capacity at ",testCapacity)
			return throughput
		end
		if throughput.isMaxLength or throughput.throughput == maxThroughput.throughput then 
			trace("determined that the line rate cannot be achieved with capacity at ",testCapacity)
			return throughput
		end
	end
	trace("unable to determine appropriate solution for target, falling back to maximum")	
	return maxThroughput
end 

function vehicleUtil.getModel(modelId) 
	if not vehicleUtil.modelRepLookup then 
		discoverVehicles()
	end
	return  vehicleUtil.modelRepLookup[modelId]
end

function vehicleUtil.getThroughputInfoForRoadVehicle(config, stations, params)
	local modelId = config.vehicles[1].part.modelId
	local model = vehicleUtil.getModel(modelId) 
	local configData = getVehicleConfig(model)
	local engine = getVehicleEngine(model)
	local topSpeed = configData.topSpeed
	local tractiveEffort = engine.tractiveEffort
	local power = engine.power
	local mass = configData.weight
	local capacity = vehicleUtil.cargoCapacityLookup[modelId][params.cargoType]
	local cargoWeight = capacity * vehicleUtil.cargoWeightLookup[params.cargoType] / 1000
	
	
	local function createRouteSectionsFromRouteInfo(routeInfo) 
		local routeSections = {} 
		local previousSpeedLimit
		for i = 1, #routeInfo.edges do
			local edgeId  =routeInfo.edges[i].id
			local edge = routeInfo.edges[i].edge
			local speedLimit =  math.min(util.getRoadSpeedLimit(edgeId), topSpeed)
			trace("The speed limit was ", api.util.formatSpeed(speedLimit))
			local resetSpeed = false
			if i > 2 then 
				local angle = util.calculateAngleConnectingEdges(edge, routeInfo.edges[i-1].edge)
				if angle > math.rad(60) then 
					trace("Junction angle detected ",math.deg(angle)," at ",edgeId," resetting speed")
					resetSpeed=true
					routeSections[#routeSections].resetEndSpeed =true
				end 
			end
			
			if speedLimit ~= previousSpeedLimit or resetSpeed then 
				table.insert(routeSections, {
					length = util.calculateSegmentLengthFromEdge(edge),
					resetStartSpeed = resetSpeed,
					speedLimit = speedLimit
				})
			else 
				local routeSection = routeSections[#routeSections]
				routeSection.length = routeSection.length +  util.calculateSegmentLengthFromEdge(edge)
			end
			previousSpeedLimit = speedLimit
		end
		trace("Constructed ",#routeSections," between ",stations[1]," and ",stations[2])
		return routeSections
	end 
	local function createRouteSectionsFromRouteInfo2(routeInfo) 
		local routeSections = {} 
		local previousSpeedLimit
		for i = 1, #routeInfo.speedLimits do
			 
			local speedLimit =  math.min(routeInfo.speedLimits[i], topSpeed)
			--trace("The speed limit was ", api.util.formatSpeed(speedLimit)) 
			table.insert(routeSections, {
				length = routeInfo.lengths[i],
				grad = routeInfo.grads[i],
				speedLimit = speedLimit
			})
		end
		trace("Constructed ",#routeSections," between ",stations[1]," and ",stations[2])
		return routeSections
	end	
	
	
	local totalTime = 0
	local totalDistance = 0
	local function estimateTripTime(priorStation, station)
		local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(priorStation, station)
		if not routeInfo then 
			
			local assumedDist = 1.2*util.distBetweenStations(priorStation, station)
			totalDistance = totalDistance + assumedDist 
			local speedFactor = assumedDist > 1000 and (2/3) or (1/2)
			local assumedTime = assumedDist/(speedFactor*topSpeed)
			trace("WARNING! Could not find a path between",priorStation," and ",station,"! Using assumedDist=",assumedDist," assumedTime=",assumedTime)
			return
		end 
		
		local routeSections =  createRouteSectionsFromRouteInfo2(routeInfo) 
		local speed = 0
		for i = 1, #routeSections do 
			local routeSection = routeSections[i]
			local topSpeed = routeSection.speedLimit
			speed = math.min(speed, topSpeed)
			if routeSection.resetStartSpeed then 
				speed =0 
			end
			--local gradient= 0 -- may do gradient correction later
			local gradient = routeSection.grad
			local info = calculateTripTimeOnRouteSection(power, tractiveEffort, topSpeed, mass+cargoWeight, gradient, routeSection.length, speed)
			assert(info.speed == info.speed) 
			assert(info.time == info.time)
			speed = info.speed
			totalDistance = totalDistance + routeSection.length
			totalTime = totalTime + info.time 
		end
	end
	
	for i = 1, #stations do 
		local priorStation = i==1 and stations[#stations] or stations[i-1]
		local station = stations[i]
		estimateTripTime(priorStation, station)
		trace("Estimated total oubound time between ",priorStation, " and ", station," as ",totalTime)
	end 
	
 
	 
	local avgSpeed = totalDistance/totalTime
	trace("Estimated total trip time between ", stations[1], " and ", stations[2]," as ",totalTime, " total dist was ",totalDistance," averageSpeed =",api.util.formatSpeed(avgSpeed))
	local throughput = capacity /  totalTime
	local throughputPer12min = throughput * 12 * 60
	return { 
		estimatedTripTime = totalTime,
		totalTime = totalTime,
		capacity = capacity,
		routeLength = totalDistance,
		throughput = throughputPer12min
	} 

end

function vehicleUtil.buildVehicle(params, vehicleType, optionalFilterFn, scoreWeights)
	local config = api.type.TransportVehicleConfig.new()
	if not scoreWeights then 
		if vehicleType == "truck" then 
			if params.hasTruckStop and params.routeLength and params.routeLength < 1500 then
				scoreWeights = paramHelper.getParams().urbanTruckScoreWeights
			else 
				scoreWeights = paramHelper.getParams().truckScoreWeights
			end
		end
		if vehicleType == "bus" then 
			if params.isUrbanLine or params.routeLength and params.routeLength < 1500 then
				scoreWeights = paramHelper.getParams().urbanBusScoreWeights
			else 
				scoreWeights = paramHelper.getParams().interCityBusScoreWeights
			end
		end
		if vehicleType == "plane" then 
			scoreWeights =  paramHelper.getParams().airCraftScoreWeights
		end
		if vehicleType == "tram" then 
			scoreWeights = paramHelper.getParams().urbanBusScoreWeights
		end
		if vehicleType == "ship" then 
			if params.isCargo then 
				scoreWeights = paramHelper.getParams().cargoShipScoreWeights
			else 
				scoreWeights = paramHelper.getParams().passengerShipScoreWeights
			end 
			if not optionalFilterFn then
				if not params.allowLargeShips or not params.allowLargeHarbourUpgrade then
					trace("Setting small ship filter")
					optionalFilterFn = function(vehicleId, vehicle)
						return vehicle.metadata.waterVehicle.type == 0
					end
				end
			end 
		 
		end 
	end
	trace("About to findBestMatchVehicleOfType, distance was",params.distance)
	if game.interface.getGameDifficulty() >= 2 then -- on hard mode bump up the importance of profitability 
		scoreWeights = util.deepClone(scoreWeights)
		for i = 1 , 8 do 
			scoreWeights[i]=scoreWeights[i]/2
		end 
		
		scoreWeights[9]=100 -- projected profit 
	end 
	local modelDetail = vehicleUtil.findBestMatchVehicleOfType(vehicleType, params, scoreWeights, optionalFilterFn)
	if params.isForVehicleReport then 
		return modelDetail 
	end
	if not modelDetail then 
		debugPrint({vehicleType=vehicleType, params=params})
		return
	end 
	local vehiclePart = initVehiclePart(params)
	vehiclePart.part.modelId = modelDetail.modelId
	config.vehicles[1]=vehiclePart
	config.vehicleGroups[1]=1
	if vehicleType=="ship" and not modelDetail.model.metadata.waterVehicle then
		trace("could not find waterVehicle for model")
		debugPrint(modelDetail)
	end
	local numConfigs = 1
	if modelDetail.model.metadata.waterVehicle or  modelDetail.model.metadata.airVehicle then 
		numConfigs = #firstNonNil(modelDetail.model.metadata.waterVehicle,modelDetail.model.metadata.airVehicle).configs
	end
	numConfigs = #modelDetail.model.metadata.transportVehicle.compartments
	local loadConfig = vehicleUtil.cargoIdxLookup[vehiclePart.part.modelId][params.cargoType]-1
	trace("setting up ", vehicleType," vechicle, numConfigs was ", numConfigs)
	if numConfigs > 1 then
		local loadConfigs ={}
		local autoLoadConfig ={}
		for i = 1, numConfigs do
			table.insert(loadConfigs, loadConfig)
			table.insert(autoLoadConfig, 1)  -- ALWAYS use autoLoadConfig for ANY cargo
		end
		vehiclePart.part.loadConfig=loadConfigs
		vehiclePart.autoLoadConfig=autoLoadConfig
		config.vehicles[1]=vehiclePart -- copy on assignment ?
	else
		--if util.tracelog then debugPrint({vehiclePartBefore=vehiclePart})end

		trace("Setting up vehicle for ",params.cargoType," the loadConfig was ",loadConfig)
		local loadConfigs = {loadConfig}
		local autoLoadConfig ={1}  -- ALWAYS use autoLoadConfig for ANY cargo
		vehiclePart.part.loadConfig=loadConfigs
		vehiclePart.autoLoadConfig=autoLoadConfig
		--if util.tracelog then debugPrint({vehiclePart=vehiclePart, autoLoadConfig=autoLoadConfig,loadConfig=loadConfig})end
		config.vehicles[1]=vehiclePart
	end 
	
	return vehicleUtil.copyConfig(config)
end

function vehicleUtil.getCurrentCargoConfig(vehiclePart)
	local loadConfig = vehiclePart.part.loadConfig[1]
	local modelId = vehiclePart.part.modelId
	if not vehicleUtil.inverseCargoIdxLookup then 
		discoverVehicles()
	end 
	local cargoLookup = vehicleUtil.inverseCargoIdxLookup[ modelId]
	if not cargoLookup then 
		trace("WARNING! Unable to find config for ",modelId)
		return 
	end
	return cargoLookup[loadConfig+1]
end 

function vehicleUtil.buildTruck(params)
	local filterFn = nil
	-- For cargo trucks (not passengers), use universal trucks that can carry all cargo types
	if params.cargoType ~= "PASSENGERS" then
		params.preferUniversal = true
		params.useAutoLoadConfig = true  -- Enable auto-load so trucks pick up any cargo they can carry
		local universalFilter = vehicleUtil.filterToUniversalTruckWithCargo(params.cargoType, params.minCargoTypes)
		filterFn = function(vehicleId, vehicle)
			return universalFilter(vehicleId)
		end
	end
	return vehicleUtil.buildVehicle(params, "truck", filterFn)
end

function vehicleUtil.buildTram(params)
	if not params then 
		params = { targetThroughput = 25, distance = 500 , carrier == api.type.enum.Carrier.ROAD}
	end 
	params.cargoType="PASSENGERS"
	return vehicleUtil.buildVehicle(params, "tram")
end

function vehicleUtil.isLargeShip(vehicleConfig) 
	if not vehicleUtil.modelRepLookup then 
		discoverVehicles() 
	end 
	return vehicleUtil.modelRepLookup[vehicleConfig.vehicles[1].part.modelId].metadata.waterVehicle.type == 1
end 

function vehicleUtil.buildShip(params, allowLargeShips)
	local filterFn
	if not allowLargeShips then
		filterFn = function(vehicleId, vehicle)
			return vehicle.metadata.waterVehicle.type == 0
		end
	end
	return vehicleUtil.buildVehicle(params, "ship", filterFn)
end

function vehicleUtil.buildPlane(params, smallOnly)
	local filterFn
	if smallOnly then
		filterFn = function(vehicleId, vehicle)
			return vehicle.metadata.airVehicle.type == 0
		end
	end
	params.carrier = api.type.enum.Carrier.AIR
	if not params.targetThroughput then 
		trace("buildPlane: no throughput specified defaulting to 100")
		params.targetThroughput = 100 
	end 
	return vehicleUtil.buildVehicle(params, "plane", filterFn)
end

function vehicleUtil.buildVehicleFromLineType(transportModes, params)
	local vehicleType = getTypeFromMode(transportModes)
	local filterFn
	if vehicleType == "plane" and not params.allowLargePlanes then
		filterFn = function(vehicleId, vehicle)
			return vehicle.metadata.airVehicle.type == 0
		end
	end
	if vehicleType == "ship" and not params.allowLargeShips then
		filterFn = function(vehicleId, vehicle)
			return vehicle.metadata.waterVehicle.type == 0
		end
	end 
	
	
	return vehicleUtil.buildVehicle(params,vehicleType, filterFn)
end

function vehicleUtil.buildVehicleFromCarrier(carrier, params) 
	if not vehicleUtil.vehicleCarrierToType then 
		vehicleUtil.vehicleCarrierToType = { 
			[api.type.enum.Carrier.RAIL]="train",
			[api.type.enum.Carrier.ROAD]="truck",
			[api.type.enum.Carrier.TRAM]="tram",
			[api.type.enum.Carrier.WATER]="ship",
			[api.type.enum.Carrier.AIR]="plane",
		}	
	
	end 
	local vehicleType = vehicleUtil.vehicleCarrierToType[carrier]
	if vehicleType == "truck" and params.cargoType=="PASSENGERS" then 
		trace("buildVehicleFromCarrier: detected bus type needed, switching")
		vehicleType = "bus"
	end 
	return vehicleUtil.buildVehicle(params,vehicleType)
end

function vehicleUtil.buildMaximumCapacityTrain(params)
	params.buildMaximumCapacityTrain = true 
	local res =  vehicleUtil.buildTrain(2^16, params)
	params.buildMaximumCapacityTrain = false 
	return res
end

function vehicleUtil.isElectricTram(transportVehicleConfig)
	if not  vehicleUtil.modelRepLookup then 
		discoverVehicles()
	end
	 
	local model = vehicleUtil.modelRepLookup[transportVehicleConfig.vehicles[1].part.modelId]
	return model.metadata.railVehicle
	and model.metadata.railVehicle.engines[1]
	and model.metadata.railVehicle.engines[1].type == api.type.enum.VehicleEngineType.ELECTRIC
end

function vehicleUtil.calculateCapacity(transportVehicleConfig, cargoType)
	local capacity = 0 
	if not  vehicleUtil.modelRepLookup then 
		discoverVehicles()
	end
	for i = 1, #transportVehicleConfig.vehicles do 
		local modelId = transportVehicleConfig.vehicles[i].part.modelId
		local waggonCapacity = vehicleUtil.cargoCapacityLookup[modelId][cargoType]
		if not waggonCapacity then 
			debugPrint({modelId=modelId, cargoType=cargoType, lookup=vehicleUtil.cargoCapacityLookup[modelId]})
		end 
		capacity = capacity + waggonCapacity
	end
	return capacity
end
function vehicleUtil.findVehicleFromLineType(transportModes, params)
	return vehicleUtil.findBestMatchVehicleOfType(getTypeFromMode(transportModes), params)
end 
function vehicleUtil.checkIfVechicleCanBeUpgradeOrExtended(vehicle, transportModes, params) 
	local vehicleType = getTypeFromMode(transportModes)
	local vehicleDetail =  util.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
	local transportVehicleConfig = vehicleDetail.transportVehicleConfig
	local testConfig
	if vehicleType=="train" then
		testConfig = vehicleUtil.buildMaximumCapacityTrain(params)
	 
	else 
		testConfig = vehicleUtil.buildVehicle(params, vehicleType )
	end
	return not vehicleUtil.checkIfVehicleConfigMatches(testConfig, transportVehicleConfig)
end

function vehicleUtil.checkIfVehicleConfigMatches(testConfig, transportVehicleConfig)
	if #testConfig.vehicles ~= #transportVehicleConfig.vehicles then
		return false
	end
	for i=1, #testConfig.vehicles do
		if testConfig.vehicles[i].part.modelId ~= transportVehicleConfig.vehicles[i].part.modelId then
			return false
		end
	end
	return true
end 

-- ************************
-- UI
-- ************************


function vehicleUtil.getImageForSingleVehicle(modelId)
	
		local model = api.res.modelRep.get(modelId)
		local name = model.metadata.description.name
		--[[
		icon = "ui/models/vehicle/train/usa/hhp_8.tga",
  smallIcon = "ui/models_small/vehicle/train/usa/hhp_8.tga",
  smallIconCblend = "ui/models_small/vehicle/train/usa/hhp_8_cblend.tga",
  icon20 = "ui/models_20/vehicle/train/usa/hhp_8.tga",
  icon20cblend = "ui/models_20/vehicle/train/usa/hhp_8_cblend.tga",]]--
		local icon = model.metadata.description.icon20
		--trace("Getting icon for ",name," modelId was ",modelId)
		local imageView = api.gui.comp.ImageView.new(icon)
		imageView:setTooltip(_(name))
		return imageView
end 

function vehicleUtil.displayVehicleConfig(newVehicleConfig, maxSize) 
	--trace("About to display newVehicleConfig")
	--debugPrint(newVehicleConfig)
	if not newVehicleConfig then 
		return api.gui.comp.TextView.new(" ")
	end
	
	
	local boxlayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	for i, vehicle in pairs(newVehicleConfig.vehicles) do
		local modelId = vehicle.part.modelId
		local imageView = vehicleUtil.getImageForSingleVehicle(modelId)
		boxlayout:addItem(imageView)
	end
	local comp= api.gui.comp.Component.new(" ")
	if maxSize then 
		comp:setMaximumSize(api.gui.util.Size.new(maxSize,30))
	end 
	--comp:setMaximumSize(api.gui.util.Size.new(300,30))
	comp:setLayout(boxlayout)
	return comp 	
end

function vehicleUtil.calculateSectionCorrections(lineReport)
	local sectionCorrections = {}
	--local throughPut = util.


end



return vehicleUtil