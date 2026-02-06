require "tableutil"
local transf = require "transf"
local vec3 = require "vec3"

local bridgeutil = { }

local getMaxSize = function(modelData, models, dim, inverted)
	local result = .0
	
	for i = 1, #models do
		local size = inverted and -modelData[models[i]].min[dim] or modelData[models[i]].max[dim]
		
		if size > result then result = size end
	end
	
	return result
end

local getSizes = function(modelData, models, dim)
	local result = { }
	
	for i = 1, #models do
		table.insert(result, modelData[models[i]].max[dim])
	end

	return result
end 

local getSteps = function(indices, flipped, refSizes, size)
	if #indices == 1 then
		return { { idx = 1, refSize = refSizes[1], flipped = flipped[1] } }
	end

	assert(#indices == 3 or #indices == 4)
	assert(indices[1] > 0 or indices[2] > 0 or indices[3] > 0)

	local minSize = .0
	if indices[1] > 0 then minSize = minSize + refSizes[indices[1]] end
	if indices[3] > 0 then minSize = minSize + refSizes[indices[3]] end
	
	local numRepeat = 0
	if indices[2] > 0 then
		local repeatSize = math.max(size - minSize, .0)
		numRepeat = math.floor(repeatSize / refSizes[indices[2]] + .5)
		
		if indices[1] <= 0 and indices[3] <= 0 and numRepeat == 0 then numRepeat = 1 end -- TODO HACK
		
		minSize = minSize + numRepeat * refSizes[indices[2]]
	end

	local scale = size / minSize
	
	local steps = { }
	if indices[1] > 0 then table.insert(steps, { idx = indices[1], refSize = scale * refSizes[indices[1]], flipped = flipped[1] }) end
	for j = 1, numRepeat do table.insert(steps, { idx = indices[2], refSize = scale * refSizes[indices[2]], flipped = flipped[2] }) end
	if indices[3] > 0 then table.insert(steps, { idx = indices[3], refSize = scale * refSizes[indices[3]], flipped = flipped[3] }) end
	if #indices == 4 then table.insert(steps, { idx = indices[4], refSize = refSizes[indices[4]], flipped = false }) end
	
	return steps
end

function bridgeutil.getRailingIntervalIdx(params, pillarIndex, before)
	for i = 1, #params.railingIntervals do
		local interval = params.railingIntervals[i]
	
		if before then
			if interval.hasPillar[2] == pillarIndex - 1 then return i end
		else
			if interval.hasPillar[1] == pillarIndex - 1 then return i end
		end
	end
	
	assert(false)
	return -1
end

function bridgeutil.getRailingInterval(params, pillarIndex, before)
	return params.railingIntervals[bridgeutil.getRailingIntervalIdx(params, pillarIndex, before)]
end

function bridgeutil.configurePillar(modelData, pillarModels, height, width)
	assert(#pillarModels == 3 or #pillarModels == 4)

	local result = { }
	
	result.models = pillarModels
	
	result.dim1 = 3
	result.dim2 = 2
	
	result.size1 = height
	result.size2 = width
	
	result.inverted = { false, false, true }
	result.flipped = { }
	
	result.refSizes1 = { }
	result.refSizes2 = { }
	
	result.indices1 = { }
	for i = 1, #pillarModels do result.indices1[i] = i end

	result.indices2 = { }
	
	for i = 1, #pillarModels do 
		table.insert(result.refSizes1, getMaxSize(modelData, pillarModels[i], result.dim1, result.inverted[i]))
		
		assert(#pillarModels[i] == 1 or #pillarModels[i] == 2 or #pillarModels[i] == 3)
		result.indices2[i] = #pillarModels[i] == 3 and { 1, 2, 3 } or #pillarModels[i] == 2 and { 1, 2, 1 } or { 1 }
		result.flipped[i] = #pillarModels[i] == 3 and { false, false, false } or #pillarModels[i] == 2 and { false, false, true } or { false }
		
		table.insert(result.refSizes2, getSizes(modelData, pillarModels[i], result.dim2))
	end
	
	result.min2 = #pillarModels[1] == 1 and .0 or -.5 * width -- TODO HACK
	 
	return result
end

function bridgeutil.configureRailing(modelData, interval, railingModels, length, width)
	assert(#railingModels == 3)
	
	local result = { }
	
	result.models = railingModels
	
	result.dim1 = 1
	result.dim2 = 2
	
	result.size1 = length
	result.size2 = width
	
	result.inverted = { false, false, false }
	result.flipped = { }
	
	result.refSizes1 = { }
	result.refSizes2 = { }
	
	local lanes = interval.lanes
			
	local centerY = #lanes % 2 == 0 and .5 * (lanes[#lanes / 2].offset + lanes[#lanes / 2 + 1].offset) or lanes[(#lanes + 1) / 2].offset
	result.min2 = centerY - .5 * width

	local typeRight = lanes[1].type
	local typeLeft = lanes[#lanes].type
	
	local hasCollision = (typeRight > 0 or typeLeft > 0)
	
	result.indices1 = {
		#railingModels[1] > 0 and 1 or -1,
		#railingModels[2] > 0 and 2 or -1,
		#railingModels[3] > 0 and 3 or -1
	}
	result.indices2 = { }
	
	for i = 1, #railingModels do 
		table.insert(result.refSizes1, getMaxSize(modelData, railingModels[i], result.dim1, result.inverted[i]))

		local flipOffset = 0
		if #railingModels[i] > 5 then flipOffset = 5 end

		local hasCollModels = #railingModels[i] == 5 or #railingModels[i] == 8 -- TODO HACK 3 side and 2 rep, doubled for flipped
	
		local rightIdx = (typeRight <= 1) and ((hasCollModels and hasCollision) and 2 or 1) or (hasCollModels and 3 or 2)
		local leftIdx = (typeLeft % 2 == 0) and ((hasCollModels and hasCollision) and 2 or 1) or (hasCollModels and 3 or 2)
		local repIdx = hasCollModels and (hasCollision and 5 or 4) or 2
	
		result.indices2[i] = { rightIdx, repIdx, leftIdx + flipOffset }
		result.flipped[i] = { false, false, #railingModels[i] <= 5 and true or 1 }
		
		table.insert(result.refSizes2, getSizes(modelData, railingModels[i], result.dim2))
	end
	
	return result
end

function bridgeutil.repeat2D(modelData, config)
	local result = { }

	local steps1 = getSteps(config.indices1, { false, false, false }, config.refSizes1, config.size1)
			
	local pos1 = .0
	for i = 1, #steps1 do
		local rowResult = { }
	
		local idx1 = steps1[i].idx
		local size1 = steps1[i].refSize
		
		local inverted = config.inverted[idx1]
		
		local offset1 = inverted and size1 or .0
		
		local steps2 = getSteps(config.indices2[idx1], config.flipped[idx1], config.refSizes2[idx1], config.size2)
	
		local pos2 = config.min2
		for j = 1, #steps2 do
			local idx2 = steps2[j].idx
			local size2 = steps2[j].refSize
			
			local flipped = steps2[j].flipped and steps2[j].flipped ~= 1
			
			local model = config.models[idx1][idx2]
			
			local size = table.copy(modelData[model].max)
			if inverted then size[config.dim1] = -modelData[model].min[config.dim1] end
			
			local offset2 = (flipped or steps2[j].flipped == 1) and size2 or .0
			
			local scale = { 1.0, 1.0, 1.0 }
			scale[config.dim1] = size[config.dim1] > 0 and size1 / size[config.dim1] or 1
			scale[config.dim2] = (flipped and -1 or 1) * (size[config.dim2] > 0 and size2 / size[config.dim2] or 1)
			
			local pos = { .0, .0, .0 }
			pos[config.dim1] = pos1 + offset1
			pos[config.dim2] = pos2 + offset2
			
			local scaleVec = vec3.new(scale[1], scale[2], scale[3])
			local posVec = vec3.new(pos[1], pos[2], pos[3])
			
			local modelTransf = transf.scaleXYZRotZTransl(scaleVec, .0, posVec)
			
			table.insert(rowResult, { id = model, transf = modelTransf })
			
			pos2 = pos2 + size2
		end
		
		table.insert(result, rowResult)
		
		pos1 = pos1 + size1
	end
	
	return result
end

function bridgeutil.makeDefaultUpdateFn(data)
	print("Making default updatefn")
	return function(params)
		local modelData = params.state.models
		debugPrint(modelData)
		local configurePillar = data.configurePillar and data.configurePillar or
			function(modelData, params, i, height, width)
				print("in configure pillar, i=",i,"height=",height,"width=",width)
				--if i==1 then height =0 end
				if i == 1 then width = 1 end
				return bridgeutil.configurePillar(modelData, { data.pillarBase, data.pillarRepeat, data.pillarTop }, height, width)
			end

		local configureRailing = data.configureRailing and data.configureRailing or
			function(modelData, params, interval, i, length, width)
				local railingModels = {
					interval.hasPillar[1] >= 0 and data.railingBegin or { },
					data.railingRepeat,
					interval.hasPillar[2] >= 0 and data.railingEnd or { }
				}
				
				return bridgeutil.configureRailing(modelData, interval, railingModels, length, width)
			end
	
		local result = { }
		result.pillarModels = { }
		result.railingModels = { }
		
		local pillarWidth = (not data.pillarWidth or data.pillarWidth < .0) and params.railingWidth or data.pillarWidth
 
		for i = 1, #params.pillarHeights do
			print("Adding a pillar")
			local pillarConfig = configurePillar(modelData, params, i, params.pillarHeights[i], pillarWidth)
			local pillarResult = bridgeutil.repeat2D(modelData, pillarConfig)
			
			table.insert(result.pillarModels, pillarResult)
		end
		
		local railingModels = { data.railingBegin, data.railingRepeat, data.railingEnd }
		
		for i = 1, #params.railingIntervals do
			local interval = params.railingIntervals[i]
			local railingConfig = configureRailing(modelData, params, interval, i, interval.length, params.railingWidth)
			local intervalResult = bridgeutil.repeat2D(modelData, railingConfig)
			
			table.insert(result.railingModels, intervalResult)
		end
		
		return result
	end
end

return bridgeutil
