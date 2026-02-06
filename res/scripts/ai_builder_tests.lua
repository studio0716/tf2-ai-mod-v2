local tests = {}

function tests.testEvaluateWinner() 
	package.loaded["ai_builder_base_util"]=nil
	local util = require "ai_builder_base_util"
	local options = {}
	table.insert(options, {
		code = "A",
		scores = {
			10,
			100,
			0,
		}
	
	})
	table.insert(options, {
		code = "B",
		scores = {
			100,
			10,
			0,
		}
	
	})
		table.insert(options, {
		code = "C",
		scores = {
			0,
			10,
			100,
		}
	
	})
	
	local results = util.evaluateWinnerFromScores(options, { 100, 50, 50})
	assert(results.code=="C")
	local results = util.evaluateWinnerFromScores(options, { 50, 50, 100})
	assert(results.code=="B")
	local results = util.evaluateWinnerFromScores(options, { 100, 50, 100})
	assert(results.code=="A")
	print("testEvaluateWinner Test passed")
end 
function tests.testEvaluateWinner2() 
	package.loaded["ai_builder_base_util"]=nil
	local util = require "ai_builder_base_util"
	local options = {}
	table.insert(options, {
		code = "A",
		scores = {
			10,
			100,
			-100,
		}
	
	})
	table.insert(options, {
		code = "B",
		scores = {
			100,
			10,
			-100,
		}
	
	})
		table.insert(options, {
		code = "C",
		scores = {
			-100,
			10,
			100,
		}
	
	})
	
	local results = util.evaluateWinnerFromScores(options, { 100, 50, 50})
	assert(results.code=="C")
	local results = util.evaluateWinnerFromScores(options, { 50, 50, 100})
	assert(results.code=="B")
	--local results = util.evaluateWinnerFromScores(options, { 100, 50, 100})
--	assert(results.code=="A")
	print("testEvaluateWinner Test passed")
end 

function tests.testEvaluateWinnerGemini()
	package.loaded["ai_builder_base_util"]=nil
	local util = require "ai_builder_base_util"
		-- 4. TEST HARNESS
	local passCount = 0
	local failCount = 0

	local function runTest(name, assertion)
		if assertion then
			print("[PASS] " .. name)
			passCount = passCount + 1
		else
			print("[FAIL] " .. name)
			failCount = failCount + 1
		end
	end

	print("\n========================================")
	print("TESTING: util.evaluateWinnerFromScores")
	print("========================================")

	-- TEST 1: Basic 1D Score (Lowest Wins)
	-- Objective: Ensure the item with the mathematically lowest score is selected.
	local items1 = {
		{ id = "A", scores = { 10 } },
		{ id = "B", scores = { 5 } },  -- Winner
		{ id = "C", scores = { 20 } }
	}
	local winner1 = util.evaluateWinnerFromScores(items1, {1})
	runTest("Simple 1D Score (Lowest Wins)", winner1.id == "B")


	-- TEST 2: Multi-Dimensional Score with Equal Weights
	-- Objective: Ensure normalization works. 
	-- Item A is consistently low. Item B is high in one, low in another.
	-- Range Col 1: 0-100. Range Col 2: 0-100.
	local items2 = {
		{ id = "A", scores = { 10, 10 } }, -- (10/100 + 10/100) = 0.2 total score
		{ id = "B", scores = { 0, 100 } }, -- (0/100 + 100/100) = 1.0 total score
		{ id = "C", scores = { 100, 0 } }  -- (100/100 + 0/100) = 1.0 total score
	}
	-- Note: Function defaults to weight 50 if not provided
	local winner2 = util.evaluateWinnerFromScores(items2) 
	runTest("2D Score with Default Weights", winner2.id == "A")


	-- TEST 3: Skewed Weights
	-- Objective: Ensure weights allow prioritizing specific score columns.
	-- We heavily penalize column 1 (Weight 100) and ignore column 2 (Weight 1).
	local weights3 = { 100, 1 } 
	local items3 = {
		{ id = "A", scores = { 10, 100 } }, -- Low col 1 (Good), High col 2 (Bad but ignored) -> Winner
		{ id = "B", scores = { 20, 0 } }    -- High col 1 (Bad), Low col 2 (Good but ignored)
	}
	local winner3 = util.evaluateWinnerFromScores(items3, weights3)
	runTest("Skewed Weights Logic", winner3.id == "A")


	-- TEST 4: Score Functions (Dynamic Calculation)
	-- Objective: Ensure the function can calculate scores on the fly using the scoreFns argument.
	local rawItems = {
		{ val = 50 },
		{ val = 10 } -- Winner
	}
	local scoreFns = {
		function(item) return item.val end
	}
	local winner4 = util.evaluateWinnerFromScores(rawItems, {1}, scoreFns)
	runTest("Dynamic Score Functions", winner4.val == 10)


	-- TEST 5: Sorting / Return All Results
	-- Objective: Ensure the `returnAllResults` flag returns a sorted list, not just the winner.
	local items5 = {
		{ id = "Worst", scores = { 100 } },
		{ id = "Best",  scores = { 10 } },
		{ id = "Mid",   scores = { 50 } }
	}
	local sorted = util.evaluateWinnerFromScores(items5, {1}, nil, true) -- true for returnAllResults

	runTest("Returns Table", type(sorted) == "table")
	runTest("Returns Correct Count", #sorted == 3)
	runTest("Sort Order 1 (Best)", sorted[1].id == "Best")
	runTest("Sort Order 2 (Mid)",  sorted[2].id == "Mid")
	runTest("Sort Order 3 (Worst)", sorted[3].id == "Worst")


	-- TEST 6: Handling Zero Variance
	-- Objective: Ensure no division by zero errors if all items have the exact same score.
	local items6 = {
		{ id = "A", scores = { 5 } },
		{ id = "B", scores = { 5 } }
	}
	local winner6 = util.evaluateWinnerFromScores(items6, {1})
	runTest("Zero Variance Handling", winner6 ~= nil)
	local items1 = {
		{ id = "A", scores = { -10 } },
		{ id = "B", scores = { -5 } }, 
		{ id = "C", scores = { -20 } } -- Winner
	}
	local winner1 = util.evaluateWinnerFromScores(items1, {1})
	runTest("Simple negative iD Score (Lowest Wins)", winner1.id == "C")
	
	local items = {
		"Best",
		"Worst",
		"Mid",
		"Mid2",
	}
	local sorted = util.evaluateAndSortFromSingleScore(items, function(item)
		if item == "Best" then 
			return 0
		elseif item == "Mid" then 
			return 1
		elseif item == "Mid2" then 
			return 1
		else 
			return 2
		end 
	end)
	
	runTest("Sort Order 1 (Best)", sorted[1] == "Best")
	runTest("Sort Order 2 (Mid)",  sorted[2] == "Mid")
	runTest("Sort Order 2 (Mid)",  sorted[3] == "Mid2")
	runTest("Sort Order 3 (Worst)", sorted[4] == "Worst")
	
	local items = {
		"Best",
		"Worst",
		"Mid",
		"Mid2",
	}
	local sorted = util.evaluateAndSortFromSingleScore(items, function(item)
		if item == "Best" then 
			return -2
		elseif item == "Mid" then 
			return -1
		elseif item == "Mid2" then 
			return -1
		else 
			return 0
		end 
	end)
	
	runTest("Sort Order 1 (Best)", sorted[1] == "Best")
	runTest("Sort Order 2 (Mid)",  sorted[2] == "Mid")
	runTest("Sort Order 2 (Mid)",  sorted[3] == "Mid2")
	runTest("Sort Order 3 (Worst)", sorted[4] == "Worst")


	print("========================================")
	print("SUMMARY")
	print("Passed: " .. passCount)
	print("Failed: " .. failCount)
	print("========================================")
	end 


return tests 