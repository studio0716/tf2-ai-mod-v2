local ssu = require "stylesheetutil"
  
local function stringifyColourStyle(colour) 
	return "AIMinimap-"..tostring(colour[1]).."-"..tostring(colour[2]).."-"..tostring(colour[3])
end
 
function data()  
	local result = {}
    local a = ssu.makeAdder(result)
	local count = 0 
	
	local function addStyleSheet(r, g, b)
		a(stringifyColourStyle({r, g, b}) , {
			color = ssu.makeColor(r, g, b),
			backgroundColor = ssu.makeColor(r, g, b),
			padding = { 0, 0, 0, 0 },
			margin = { 0, 0, 0, 0 }
		})
	end
	addStyleSheet( 99, 79 ,70) -- track 
	addStyleSheet( 120, 112 ,120 ) -- road 
	addStyleSheet(0, 240, 240) -- station  
	addStyleSheet(255, 255,255) -- camera
 
	
	for b = 0, 255 do -- blue 
		addStyleSheet( 0, 0 ,b)
	end 
	for g = 0, 255 do -- green 
		addStyleSheet( 0, g ,0)
	end 

	for y = 0, 255 do -- yellow (ish) red+green
		addStyleSheet( y, y ,0)
	end 	  
	return result 
end