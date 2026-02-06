local ssu = require "stylesheetutil"
function data()
    local result = {}
    local a = ssu.makeAdder(result)
	
	a("!AIBuilderButton", {
		backgroundColor = ssu.makeColor(83, 151, 198, 200),
		borderColor = ssu.makeColor(0, 0, 0, 150)
	})
	a("!AIBuilderButton:hover", {
		backgroundColor =  ssu.makeColor(106, 192, 251, 200),
	})
	a("!AIBuilderButton:active", {
		backgroundColor = ssu.makeColor(161, 217, 255, 200),
	})
	a("!AIBuilderButton:disabled", {
		backgroundColor = ssu.makeColor(160, 180, 190, 50),
	})
	return result 
end