local util = require "ai_builder_base_util"
local trace =util.trace
local profiler = {}

local profiledCalls = {}
 
function profiler.beginFunction(functionName)
	if not profiledCalls[functionName] then 
		profiledCalls[functionName]={
			totalCalls = 0,
			totalTime = 0,
			maxTime = 0,
		}
	end 	

	profiledCalls[functionName].startTime = os.clock()
end 

function profiler.endFunction(functionName)
	local timeTaken  = os.clock() - profiledCalls[functionName].startTime
	--trace("End function:",functionName,"time taken was",timeTaken)
	profiledCalls[functionName].totalCalls = profiledCalls[functionName].totalCalls+1
	profiledCalls[functionName].totalTime = profiledCalls[functionName].totalTime+timeTaken
	profiledCalls[functionName].maxTime = math.max(profiledCalls[functionName].maxTime,timeTaken)
end 
local lastReportTime = 0
function profiler.printResults() 
	if util.tracelog then
		if os.time() < lastReportTime+600 then 
			return 
		end 
		lastReportTime = os.time()
		trace("profiler.printResults start")
		local sortedResults = {}
		for functionName, results in pairs(profiledCalls) do
			table.insert(sortedResults, {
				functionName = functionName,
				results = results, 
				scores = { 1/ math.max(results.totalTime,0.0001) }
			})
		
		end
		for i , item in pairs(util.evaluateAndSortFromScores(sortedResults)) do
			local functionName= item.functionName
			local results = item.results
			trace("Function: ",functionName, "totalTime was",results.totalTime,"total calls was",results.totalCalls,"average time",(results.totalTime/results.totalCalls),"maxTime=",results.maxTime)
		end 
		trace("profiler.printResults end")
	end 
end 

function profiler.reset() 
	profiledCalls = {}
end 


return profiler