--[[
	Module L_TeslaCar1.lua
	
	Written by R.Boer. 
	V1.7, 6 March 2020
	
	A valid Tesla account registration is required.
	
	V1.7 Changes:
		- Added new service_data command to get car service data.
		- Added retry if Tesla API returns 408 or 502.
		- Better polling if car woke up.
		- Reduced polling after multiple commands are sent.
		- Improved login with retry.
	V1.6 Changes:
		- Increased http request time out to 60 seconds for slow 3G connections on older models.
		- Fixed Daily Poll running at Vera start up.
	V1.5 Changes:
		- Changed door lock child device to a D_DoorLock_NoPin
		- Fixed issue with Car kept awake on Vera.
	V1.4 Changes:
		- Added support for child device creations.	
		- Added Vera event triggers.
		- Not checking awake state for each command when sending a series of commands.
		- Some re-writes
	V1.3 changes:
		- Fix on auto software install
		- Added Vera triggers in D_TeslaCar1.json
	V1.2 changes:
		- added command prepareDeparture that will stop charging and unlatch the power cable.
	V1.1 changes:
		- Tesla API version 6 does not seem to report windows status, set to closed for that version.
		- Similar for cable connected or not. Using derived value form charge_status instead for V6.
		
	To-do
		3) Check for ChargPortLatched to be 1 status.
		4) Doing a poll after each command in a few seconds is a bit much. Delay for like 5 sec after last command?
		5) Smart, auto tuning preheat

	https://www.teslaapi.io/
	https://tesla-api.timdorr.com/
	https://github.com/timdorr/tesla-api
	http://visibletesla.com/Doc_v2/pages/GettingStarted.html
	https://medium.com/@jhuang5132/a-beginners-guide-to-the-unofficial-tesla-api-a5b3edfe1467
	https://github.com/mseminatore/TeslaJS
	https://teslamotorsclub.com/tmc/threads/model-s-rest-api.13410/page-134
	https://support.teslafi.com/knowledge-bases/2/articles/640-enabling-sleep-settings-to-limit-vampire-loss
	https://github.com/dirkvm/teslams
	https://github.com/zabuldon/teslajsonpy/tree/master/teslajsonpy
	https://github.com/irritanterik/homey-tesla.com
	https://github.com/jonahwh/tesla-api-client/blob/master/swagger.yml
	
]]

local ltn12 	= require("ltn12")
local json 		= require("dkjson")
local https     = require("ssl.https")
local http		= require("socket.http")
local url 		= require("socket.url")
local TeslaCar
local CarModule
local log
local var
local utils

local SIDS = { 
	MODULE	= "urn:rboer-com:serviceId:TeslaCar1",
	ALTUI	= "urn:upnp-org:serviceId:altui1",
	HA		= "urn:micasaverde-com:serviceId:HaDevice1",
	ZW		= "urn:micasaverde-com:serviceId:ZWaveDevice1",
	ENERGY	= "urn:micasaverde-com:serviceId:EnergyMetering1",
	TEMP	= "urn:upnp-org:serviceId:TemperatureSensor1",
	HVAC_U	= "urn:upnp-org:serviceId:HVAC_UserOperatingMode1",
	HEAT	= "urn:upnp-org:serviceId:TemperatureSetpoint1",
	DOOR	= "urn:micasaverde-com:serviceId:DoorLock1",
	SP		= "urn:upnp-org:serviceId:SwitchPower1",
	DIM		= "urn:upnp-org:serviceId:Dimming1"
}

local pD = {
	Version = "1.5",
	DEV = nil,
	Description = "Tesla Car",
	onOpenLuup = false,
	pwdMessage = "Check UID/PWD in settings",
	retryLoginMessage = "Login failed, retrying...",
	failedLoginMessage = "Login failed, check UID/PWD."
}

-- Define message when condition is not true
local messageMap = {
	{var="MovingStatus", val="0", msg="Moving"},
	{var="ChargeStatus", val="0", msg="Charging On"},
	{var="ClimateStatus", val="0", msg="Climatizing On"},
	{var="DoorsMessage",val="Closed",msg="Doors Open"},
	{var="WindowsMessage",val="Closed",msg="Windows Open"},
	{var="LockedStatus",val="1",msg="Car Unlocked"},
	{var="SunroofStatus",val="0",msg="Sunroof Open"}
}

-- Mapping of child devices and their update routines
--[[
	sf = state update function.
	smt_af = Set State Mode action function
	scs_af = Set Current Setpoint action function
	sll_af = Set Load Level action function

definition from J_TestlaCar1.js 
var devList = [{'value':'H','label':'Climate'},{'value':'L','label':'Doors Locked'},{'value':'W','label':'Windows'},{'value':'R','label':'Sunroof'},{'value':'T','label':'Trunk'},{'value':'F','label':'Frunk'},{'value':'P','label':'Charge Port'},{'value':'C','label':'Charging'},{'value':'I','label':'Inside temperature'},{'value':'O','label':'Outside temperature'}]
]]
local childDeviceMap = {
	["H"] = { typ = "H", df = "D_Heater1", name = "Climate", devID = nil, 
					sf = function(chDevID)
						local it = var.GetNumber("InsideTemp")
						local tt = var.GetNumber("ClimateTargetTemp")
						var.Set("CurrentTemperature", it, SIDS.TEMP, chDevID)
						var.Set("CurrentSetpoint", tt, SIDS.HEAT, chDevID)
						local clim = var.GetNumber("ClimateStatus")
						if clim == 0 then
							var.Set("ModeStatus", "Off", SIDS.HVAC_U, chDevID)
						else
							var.Set("ModeStatus", "HeatOn", SIDS.HVAC_U, chDevID)
						end
					end,
					smt_af = function(chDevID, newMode)
						-- Climate on or off
						if newMode == "Off" then
							var.Set("ModeStatus", newMode, SIDS.HVAC_U, chDevID)
							CarModule.StartAction("stopClimate")
						elseif newMode == "HeatOn" then
							var.Set("ModeStatus", newMode, SIDS.HVAC_U, chDevID)
							CarModule.StartAction("startClimate")
						else
							log.Error("Unsupported newMode %s.", newMode)
						end
					end,
					scs_af = function(chDevID, newTemp)
						-- Set inside temp target
						local minTemp = var.GetNumber("MinInsideTemp")
						local maxTemp = var.GetNumber("MaxInsideTemp")
						local newTemp = tonumber(newTemp,10)
						if newTemp < minTemp then newTemp = minTemp end
						if newTemp > maxTemp then newTemp = minTemp end
						var.Set("CurrentSetpoint", newTemp, SIDS.HEAT, chDevID)
						var.Set("ClimateTargetTemp", newTemp)
						CarModule.StartAction("setTemperature", newTemp)
					end
			},
	["L"] = { typ = "L", df = "D_DoorLock1", sid = SIDS.DOOR, json = "D_DoorLock_NoPin.json", name = "Doors Locked", devID = nil, st_ac0 = "unlockDoors", st_ac1 = "lockDoors",
					sf = function(chDevID)
						local status = var.GetNumber("LockedStatus")
						var.Set("Status", status, SIDS.DOOR, chDevID)
						var.Set("Target", status, SIDS.DOOR, chDevID)
					end 
			},
	["W"] = { typ = "W", df = "D_BinaryLight1", name = "Windows Closed", devID = nil, st_ac0 = "ventWindows", st_ac1 = "closeWindows",
					sf = function(chDevID)
						local status = var.Get("WindowsMessage") == "Closed" and 1 or 0
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["R"] = { typ = "R", df = "D_BinaryLight1", name = "Sunroof Closed", devID = nil, st_ac0 = "ventSunroof", st_ac1 = "closeSunroof",
					sf = function(chDevID)
						local status = var.Get("DoorsMessage") == "Closed" and 1 or 0
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["T"] = { typ = "T", df = "D_BinaryLight1", name = "Trunk Closed", devID = nil, st_ac0 = "unlockTrunc",
					sf = function(chDevID)
						local status = var.GetNumber("TrunkStatus") == 0 and 1 or 0
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["F"] = { typ = "F", df = "D_BinaryLight1", name = "Frunk Closed", devID = nil, st_ac0 = "unlockFrunc",
					sf = function(chDevID)
						local status = var.GetNumber("FrunkStatus") == 0 and 1 or 0
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["P"] = { typ = "P", df = "D_BinaryLight1", name = "Charge Port Closed", devID = nil, st_ac1 = "closeChargePort", st_ac0 = "openChargePort",
					sf = function(chDevID)
						local status = var.GetNumber("ChargePortDoorOpen") == 0 and 1 or 0
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["C"] = { typ = "C", df = "D_DimmableLight1", name = "Charging", devID = nil, st_ac0 = "stopCharge", st_ac1 = "startCharge",
					sll_af = function(chDevID, newLoadlevelTarget)
						-- Set SOC level to new target, but must be between 50 and 100%
						local soc = tonumber(newLoadlevelTarget)
						if soc < 50 then soc = 50 end
						var.Set("LoadLevelStatus", soc, SIDS.DIM, chDevID)
						var.Set("LoadLevelTarget", soc, SIDS.DIM, chDevID)
						CarModule.StartAction("setChargeLimit", soc)
					end,
					sf = function(chDevID)
						local status = var.Get("ChargeStatus")
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
						local soc = var.Get("ChargeLimitSOC")
						var.Set("LoadLevelStatus", soc, SIDS.DIM, chDevID)
						var.Set("LoadLevelTarget", soc, SIDS.DIM, chDevID)
						var.Set("BatteryLevel", var.Get("BatteryLevel", SIDS.HA), SIDS.HA, chDevID)
					end
			},
	["I"] = { typ = "I", df = "D_TemperatureSensor1", name = "Inside temp", devID = nil, sid = SIDS.TEMP, var = "CurrentTemperature", pVar = "InsideTemp" },
	["O"] = { typ = "O", df = "D_TemperatureSensor1", name = "Outside temp", devID = nil, sid = SIDS.TEMP, var = "CurrentTemperature", pVar = "OutsideTemp" }
}
local childIDMap = {}

-- Maps to icons definition in D_TeslaCar1.json for IconSet variable.
local ICONS = {
	IDLE = 0,
	ASLEEP = 10,
	CONNECTED = 1,
	CHARGING = 2,
	CLIMATE = 3,
	UNLOCKED = 4,
	TRUNK = 5,
	FRUNK = 6,
	DOORS = 7,
	WINDOWS = 8,
	MOVING = 9,
	UNCONFIGURED = -1
}

-- API getting and setting variables and attributes from Vera more efficient.
local function varAPI()
	local def_sid, def_dev = "", 0
	
	local function _init(sid,dev)
		def_sid = sid
		def_dev = dev
	end
	
	-- Get variable value
	local function _get(name, sid, device)
		local value = luup.variable_get(sid or def_sid, name, tonumber(device or def_dev))
		return (value or "")
	end

	-- Get variable value as number type
	local function _getnum(name, sid, device)
		local value = luup.variable_get(sid or def_sid, name, tonumber(device or def_dev))
		local num = tonumber(value,10)
		return (num or 0)
	end
	
	-- Set variable value
	local function _set(name, value, sid, device)
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local old = luup.variable_get(sid, name, device)
		if (tostring(value) ~= tostring(old or "")) then 
			luup.variable_set(sid, name, value, device)
		end
	end

	-- create missing variable with default value or return existing
	local function _default(name, default, sid, device)
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local value = luup.variable_get(sid, name, device) 
		if (not value) then
			value = default	or ""
			luup.variable_set(sid, name, value, device)	
		end
		return value
	end
	
	-- Get an attribute value, try to return as number value if applicable
	local function _getattr(name, device)
		local value = luup.attr_get(name, tonumber(device or def_dev))
		local nv = tonumber(value,10)
		return (nv or value)
	end

	-- Set an attribute
	local function _setattr(name, value, device)
		luup.attr_set(name, value, tonumber(device or def_dev))
	end
	
	return {
		Get = _get,
		Set = _set,
		GetNumber = _getnum,
		Default = _default,
		GetAttribute = _getattr,
		SetAttribute = _setattr,
		Initialize = _init
	}
end

-- API to handle basic logging and debug messaging
local function logAPI()
local def_level = 1
local def_prefix = ""
local def_debug = false
local def_file = false
local max_length = 100
local onOpenLuup = false
local taskHandle = -1

	local function _update(level)
		if level >= 100 then
			def_file = true
			def_debug = true
			def_level = 10
		elseif level >= 10 then
			def_debug = true
			def_file = false
			def_level = 10
		else
			def_file = false
			def_debug = false
			def_level = level
		end
	end	

	local function _init(prefix, level, onol)
		_update(level)
		def_prefix = prefix
		onOpenLuup = onol
	end	
	
	-- Build loggin string safely up to given lenght. If only one string given, then do not format because of length limitations.
	local function prot_format(ln,str,...)
		local msg = ""
		local sf = string.format
		if arg[1] then 
			_, msg = pcall(sf, str, unpack(arg))
		else 
			msg = str or "no text"
		end 
		if ln > 0 then
			return msg:sub(1,ln)
		else
			return msg
		end	
	end	
	local function _log(...) 
		if (def_level >= 10) then
			luup.log(def_prefix .. ": " .. prot_format(max_length,...), 50) 
		end	
	end	
	
	local function _info(...) 
		if (def_level >= 8) then
			luup.log(def_prefix .. "_info: " .. prot_format(max_length,...), 8) 
		end	
	end	

	local function _warning(...) 
		if (def_level >= 2) then
			luup.log(def_prefix .. "_warning: " .. prot_format(max_length,...), 2) 
		end	
	end	

	local function _error(...) 
		if (def_level >= 1) then
			luup.log(def_prefix .. "_error: " .. prot_format(max_length,...), 1) 
		end	
	end	

	local function _debug(...)
		if def_debug then
			luup.log(def_prefix .. "_debug: " .. prot_format(-1,...), 50) 
			if def_file then
				local fh = io.open("/tmp/TeslaCar.log","a")
				local msg = os.date("%d/%m/%Y %X") .. ": " .. prot_format(-1,...)
				fh:write(msg)
				fh:write("\n")
				fh:close()
			end
		end	
	end
	
	-- Write to file for detailed analisys
	local function _logfile(...)
		if def_file then
			local fh = io.open("/tmp/TeslaCar.log","a")
			local msg = os.date("%d/%m/%Y %X") .. ": " .. prot_format(-1,...)
			fh:write(msg)
			fh:write("\n")
			fh:close()
		end	
	end
	
	local function _devmessage(devID, status, timeout, ...)
		local message = prot_format(60,...) or ""
		-- On Vera the message must be an exact repeat to erase, on openLuup it must be empty.
		if onOpenLuup and status == -2 then
			message = ""
		end
		luup.device_message(devID, status, message, timeout, def_prefix)
	end
	
	local function logAPI_clearTask()
		luup.task("", 4, def_prefix, taskHandle)
		taskHandle = -1
	end
	_G.logAPI_clearTask = logAPI_clearTask
	
	return {
		Initialize = _init,
		Error = _error,
		Warning = _warning,
		Info = _info,
		Log = _log,
		Debug = _debug,
		Update = _update,
		LogFile = _logfile,
		DeviceMessage = _devmessage
	}
end 

-- API to handle some Util functions
local function utilsAPI()
local floor = math.floor
local _UI5 = 5
local _UI6 = 6
local _UI7 = 7
local _UI8 = 8
local _OpenLuup = 99

	local function _init()
	end	

	-- See what system we are running on, some Vera or OpenLuup
	local function _getui()
		if luup.attr_get("openLuup",0) ~= nil then
			return _OpenLuup
		else
			return luup.version_major
		end
		return _UI7
	end
	
	local function _getmemoryused()
		return floor(collectgarbage "count")         -- app's own memory usage in kB
	end
	
	local function _setluupfailure(status,devID)
		if luup.version_major < 7 then status = status ~= 0 end        -- fix UI5 status type
		luup.set_failure(status,devID)
	end

	-- Luup Reload function for UI5,6 and 7
	local function _luup_reload()
		if luup.version_major < 6 then 
			luup.call_action("urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {}, 0)
		else
			luup.reload()
		end
	end
	
	-- Round up or down to whole number.
	local function _round(n)
		return floor((floor(n*2) + 1)/2)
	end

	local function _split(source, deli)
		local del = deli or ","
		local elements = {}
		local pattern = '([^'..del..']+)'
		string.gsub(source, pattern, function(value) elements[#elements + 1] = value end)
		return elements
	end
  
	local function _join(tab, deli)
		local del = deli or ","
		return table.concat(tab, del)
	end

	return {
		Initialize = _init,
		ReloadLuup = _luup_reload,
		Round = _round,
		GetMemoryUsed = _getmemoryused,
		SetLuupFailure = _setluupfailure,
		Split = _split,
		Join = _join,
		GetUI = _getui,
		IsUI5 = _UI5,
		IsUI6 = _UI6,
		IsUI7 = _UI7,
		IsUI8 = _UI8,
		IsOpenLuup = _OpenLuup
	}
end 


--- QUEUE STRUCTURE ---
local Queue = {}
function Queue.new()
	return {first = 0, last = -1}
end

function Queue.push(list, value)
	local last = list.last + 1
	list.last = last
	list[last] = value
end
    
function Queue.pop(list)
	local first = list.first
	if first > list.last then return nil end
	local value = list[first]
	list[first] = nil -- to allow garbage collection
	list.first = first + 1
	return value
end

function Queue.len(list)
	return list.last - list.first + 1
end

function Queue.drop(list)
	log.Error("Dropping %d items from queue.", Queue.len(list))
	while Queue.len(list) > 0 do
		Queue.pop(list)
	end
	list.first = 0
	list.last = -1
end

--[[
The API to contact the Tesla Vehicle 
First call Authenticate, then GetVehicle awake status before sending commands. You cannot send comamnds when car is in asleep status.
Note that if there is no charging schedule and you send a wake_up command to a not fully charged car, it will start charging without sending any other command.
Adviced polling:
	* Standard status polling no more then once per 15 minutes for idle car so it can go asleep
	* When asleep, check for that status as often as you like, eg every five minutes.
	* When charging it can go to sleep, but you may want to poll more frequently depending on remining charge time. E.g. 
		- if 10 hrs left, poll once per hour, if less than an hour, poll every five minutes (car will not go asleep).
	* For other activities like heating, poll every five minutes.
]]
local function TeslaCarAPI()
	-- Map commands to details
	local commands = {
		["authenticate"] 			= { method = "POST", url ="/oauth/token" },
		["logoff"] 					= { method = "POST", url ="/oauth/revoke" },
		["listCars"] 				= { method = "GET", url ="/api/1/vehicles" },
		["wakeUp"] 					= { method = "POST", url ="/wake_up" },
		
		["getVehicleDetails"] 		= { method = "GET", url ="/vehicle_data" },
		["getServiceData"] 			= { method = "GET", url ="/service_data" },
		["getChargeState"] 			= { method = "GET", url ="/data_request/charge_state" },
		["getClimateState"] 		= { method = "GET", url ="/data_request/climate_state" },
		["getDriveState"] 			= { method = "GET", url ="/data_request/drive_state" },
		["getMobileEnabled"] 		= { method = "GET", url ="/mobile_enabled" },
		["getGuiSettings"] 			= { method = "GET", url ="/data_request/gui_settings" },

		["startCharge"] 			= { method = "POST", url ="/command/charge_start" },
		["stopCharge"] 				= { method = "POST", url ="/command/charge_stop" },
		["startClimate"] 			= { method = "POST", url ="/command/auto_conditioning_start" },
		["stopClimate"] 			= { method = "POST", url ="/command/auto_conditioning_stop" },
		["unlockDoors"] 			= { method = "POST", url ="/command/door_unlock" },
		["lockDoors"] 				= { method = "POST", url ="/command/door_lock" },
		["honkHorn"] 				= { method = "POST", url ="/command/honk_horn" },
		["flashLights"] 			= { method = "POST", url ="/command/flash_lights" },
		["unlockFrunc"]				= { method = "POST", url ="/command/actuate_trunk", data = function(p) return {which_trunk="front"} end },
		["unlockTrunc"] 			= { method = "POST", url ="/command/actuate_trunk", data = function(p) return {which_trunk="rear"} end },
		["openChargePort"]		 	= { method = "POST", url ="/command/charge_port_door_open" },
		["closeChargePort"]		 	= { method = "POST", url ="/command/charge_port_door_close" },
		["setTemperature"] 			= { method = "POST", url ="/command/set_temps", data = function(p) return {driver_temp=p,passenger_temp=p} end },
		["setChargeLimit"] 			= { method = "POST", url ="/command/set_charge_limit", data = function(p) return {percent=p} end },
		["setMaximumChargeLimit"] 	= { method = "POST", url ="/command/charge_max_range" },
		["setStandardChargeLimit"]  = { method = "POST", url ="/command/charge_standard" },
		["ventSunroof"] 			= { method = "POST", url ="/command/sun_roof_control", data = function(p) return {state="vent"} end },
		["closeSunroof"] 			= { method = "POST", url ="/command/sun_roof_control", data = function(p) return {state="close"} end },
		["ventWindows"] 			= { method = "POST", url ="/command/window_control", data = function(p) return {command="vent",lat=var.GetNumber("Latitude"),lon=var.GetNumber("Longitude")} end },
		["closeWindows"] 			= { method = "POST", url ="/command/window_control", data = function(p) return {command="close",lat=var.GetNumber("Latitude"),lon=var.GetNumber("Longitude")} end },
		["updateSoftware"] 			= { method = "POST", url ="/command/schedule_software_update", data = function(p) return {offset_sec=120} end }
	}
	
	-- Tesla API location
	local base_url = "https://owner-api.teslamotors.com"
	local vehicle_url = nil
	-- Authentication data
	local auth_data = {
			["client_secret"] = "c7257eb71a564034f9419ee651c7d0e5f7aa6bfbd18bafb5c5c033b093bb2fa3",
			["client_id"] = "81527cff06843c8634fdc09e8ac0abefb46ac849f38fe1e431c2ef2106796384",
			["email"] = nil,
			["password"] = nil,
			["vin"] = nil,
			["token"] = nil,
			["refresh_token"] = nil,
			["expires_in"] = nil,
			["created_at"] = nil,
			["expires_at"] = nil
		}
	local request_header = {
		["x-tesla-user-agent"] = "VeraTeslaCarApp/1.0",
		["user-agent"] = "Mozilla/5.0 (Linux; Android 8.1.0; Pixel XL Build/OPM4.171019.021.D1; wv) Chrome/68.0.3440.91",
		["accept"] = "application/json"
	}
	-- Vehicle details
	local vehicle_data = nil
	local last_wake_up_time = 0
	local SendQueue = Queue.new()  -- Queue to hold commands to be handled.
	
	-- HTTPs request
	local function HttpsRequest(mthd, strURL, ReqHdrs, PostData)
		local result = {}
		local request_body = nil
--log.Debug("HttpsRequest 1 %s", strURL)		
		if PostData then
			-- We pass JSONs in all cases
			ReqHdrs["content-type"] = "application/json; charset=UTF-8"
			request_body=json.encode(PostData)
			ReqHdrs["content-length"] = string.len(request_body)
--log.Debug("HttpsRequest 2 body: %s",request_body)		
		else	
--log.Debug("HttpsRequest 2, no body ")		
			ReqHdrs["content-length"] = "0"
		end 
		http.TIMEOUT = 60
		local bdy,cde,hdrs,stts = https.request{
			url = strURL, 
			method = mthd,
			sink = ltn12.sink.table(result),
			source = ltn12.source.string(request_body),
			headers = ReqHdrs
		}
--log.Debug("HttpsRequest 3 %s", cde)		
		if cde ~= 200 then
			return false, nil, cde
		else
--log.Debug("HttpsRequest 4 %s", table.concat(result))		
			return true, json.decode(table.concat(result)), cde
		end
	end	

	-- ask for new token, if we have a refresh token, try refresh first.
	local function _authenticate (force)
		local msg = "OK"
		local cmd = commands.authenticate
		local data = {
				client_id     = auth_data.client_id,
				client_secret = auth_data.client_secret
			}
		if force or (not auth_data.refresh_token) then
			data.grant_type    	= "password"
			data.email 			= auth_data.email
			data.password 		= auth_data.password
		else
			data.grant_type		= "refresh_token"
			data.refresh_token	= auth_data.refresh_token
		end
		local res, reply, cde = HttpsRequest(cmd.method, base_url .. cmd.url , request_header ,	data)
		if res then
			-- Succeed, set token details
			auth_data.token 		= reply.access_token
			auth_data.refresh_token	= reply.refresh_token
			auth_data.token_type 	= reply.token_type
			auth_data.expires_in	= reply.expires_in
			auth_data.created_at	= reply.created_at		
			auth_data.expires_at	= reply.created_at + reply.expires_in - 3600
			request_header["authorization"] = reply.token_type.." "..reply.access_token
		else
			-- Fail, clear token data
			auth_data.token 		= nil
			auth_data.refresh_token	= nil
			auth_data.expires_at 	= os.time() - 3600
			msg = "request failed, HTTP code ".. cde
		end
		return res, cde, msg
	end

	-- Get the right vehicle details to use in the API requests. If vin is set, find vehicle with that vin, else use first in list
	-- Must be authenticated, there is no auto-authenticate.
	local function _get_vehicle()
		-- Check if we are authenticated
		if auth_data.token then
			local idx = 1
			local cmd = commands.listCars
			local vin = auth_data.vin
			local res, reply, cde = HttpsRequest(cmd.method, base_url .. cmd.url , request_header )
			if res then
				if reply.count then
--log.Debug("GetVehicle got %d cars.", reply.count)				
					if reply.count > 0 then
						if reply.count > 1 then
							-- See if we can find specific vin to support mutliple vehicles.
							if vin and vin ~= "" then
								for i = 1, reply.count do
									if reply.response[i].vin == vin then
										idx = i
										break
									end	
								end
							end
						end	
--log.Debug("will use car #%d.",idx)						
						vehicle_data = reply.response[idx]
						-- Set the corect URL for vehicle requests
						vehicle_url = base_url .. "/api/1/vehicles/" .. vehicle_data.id_s
--log.Debug("URL to use %s",vehicle_url)						
						return true, vehicle_data, "OK"
					else
						return false, 404, "No vehicles found."
					end
				else
					return false, 428, "Vehicle in deep sleep."
				end
			else
				return false, cde, "HTTP Request failed, code ".. cde
			end
		else
			return false, 401, "Not authenticated."
		end
	end

	-- Get the vehicle awake status. Should be only command faster than 4 times per hour keeping car asleep.
	local function _get_vehicle_awake_status()
		-- Only poll car if last confirmed awake is more than 50 seconds ago.
		if (os.difftime(os.time(), last_wake_up_time) > 50) then
			local res, data, msg = _get_vehicle()
			if res then
				-- Return true if online.
				local awake =  data.state=="online"
				if awake then last_wake_up_time = os.time()	end
				return true, awake, "OK"
			else
				return res, data, msg
			end
		else	
			return true, true, "OK"
		end
	end

	-- Get the vehicle vin numbers on the account
	local function _get_vehicle_vins()
		-- Check if we are authenticated
		if auth_data.token then
			local cmd = commands.listCars
			local vins = {}
			local res, reply, cde = HttpsRequest(cmd.method, base_url .. cmd.url , request_header )
			if res then
				if reply.count then
					if reply.count > 0 then
						for i = 1, reply.count do
							table.insert(reply.response[i].vin)
						end
						return true, vins, "OK"
					else
						return false, 404, "No vehicles found."
					end
				else
					return false, 428, "Vehicle in deep sleep."
				end
			else
				return false, cde, "HTTP Request failed, code ".. cde
			end
		else
			return false, 401, "Not authenticated."
		end
	end

	-- Send a command to the API.
	local function _send_command(command, param)
		if vehicle_data then
			log.Debug("SendCommand, sending %s", command)
			local cmd = commands[command]
			if cmd then 
				-- Set correct command URL with optional parameter
				local url = cmd.url
				local data = nil
				if cmd.data then data = cmd.data(param) end
				local res, reply, cde = HttpsRequest(cmd.method, vehicle_url..url, request_header, data)
				if res then
					return true, reply, "OK"
				else
					return false, cde, "HTTP Request failed, code ".. cde
				end	
			else
				return false, 501, "Unknown command : "..command
			end
		else
			return false, 404, "No vehicle selected."
		end
	end
	
	-- Send a command to the API. To be used as primary method to send commands to the car.
	-- If car is not awake, wake it up first. Commands can be queued if needed.
	-- Also handles situation when no vehicles are reported on the account by retrying several times.
	-- For each command the callback cbs function is called to process the results. cbf is called for failures.
	local function _send_command_async(cmd, param, cbs, cbf, retry)
		local retry = retry or 0
		if (cmd == nil) then
			log.Debug("SendCommandAsync, no cmd specified. Queue length %d.", Queue.len(SendQueue))
			-- Triggered to empty q
			if (Queue.len(SendQueue) > 0) then
				local pop_t = Queue.pop(SendQueue)
				local res, reply, msg = _send_command(pop_t.cmd, pop_t.param)
				if res then
					pop_t.cbs(pop_t, reply, msg)
				else
					pop_t.cbf(pop_t, reply, msg)
				end
				-- If we have more on Q, send those with 5 sec interval not to hog resources.
				if (Queue.len(SendQueue) > 0) then
					log.Debug("SendCommandAsync, more commands to send. Queue length %d", Queue.len(SendQueue))
					luup.call_delay("TSC_send_queued", 5)
					return true, 200, "More commands queued to send."
				else	
					return true, 200, "All commands sent."
				end	
			else	
				return true, 200, "All commands sent."
			end
		else
			log.Debug("SendCommandAsync, command %s. Queue length %d.", cmd, Queue.len(SendQueue))
			if (Queue.len(SendQueue) > 0) then
				-- We are working on a command, add this to queue
				log.Debug("SendCommandAsync, command %s pushed on queue.", cmd)
				Queue.push(SendQueue, {cmd = cmd, cbs = cbs, cbf = cbf, param = param, retry = retry})
				return true, 200, "Command pushed on queue."
			else
				log.Debug("SendCommandAsync, queue empty command %s to be send.", cmd)
				-- Q empty try sending right away
				-- See if we are logged in and or need to refresh the token
				if (not auth_data.expires_at) or auth_data.expires_at < os.time() then
					log.Debug("SendCommandAsync, need to authenticate.")
					local res, reply, msg = _authenticate()
					if not res then
						cbf({cmd = cmd, cbs = cbs, cbf = cbf, param = param, retry = retry}, reply, msg)
						return false, 401, "Unable to authenticate"
					end	
				end
				-- See if car is available. Sometimes the API responds no vehicles, esp with SW update installing.
				-- If not push command and try again a tad later.
				local res, reply, msg = _get_vehicle_awake_status()
				if res and reply then
					log.Debug("SendCommandAsync, car is awake. Sending command %s", cmd)
					-- Its ready for the command, send it
					local res, reply, msg = _send_command(cmd, param)
					if res then
						cbs({cmd = cmd, cbs = cbs, cbf = cbf, param = param, retry = retry}, reply, msg)
					else
						cbf({cmd = cmd, cbs = cbs, cbf = cbf, param = param, retry = retry}, reply, msg)
					end
					-- If we have more on Q by now, send those with 2 sec interval not to hog Vera resources.
					if (Queue.len(SendQueue) > 0) then
						log.Debug("SendCommandAsync, more commands to send. Queue length %d", Queue.len(SendQueue))
						luup.call_delay("TSC_send_queued", 2)
						return true, 200, "More commands queued to send."
					else	
						return true, 200, "All commands sent."
					end	
				elseif res and not reply then
					-- It is not awake, wake it up, then send command. Push it on the queue.
					log.Debug("SendCommandAsync, car is asleep. Wake it up and queue command %s", cmd)
					Queue.push(SendQueue, {cmd = cmd, cbs = cbs, cbf = cbf, param = param, retry = retry})
					_send_command("wakeUp")
					luup.call_delay("TSC_await_wakeup_vehicle", 5, "15")
					return true, 200, "Waiting to wake up vehicle."
				elseif not res and reply == 404 then
					-- We got a response that there are no vehicles on the account. Retry after 10 secs, 20 times max.
					log.Debug("SendCommandAsync, got a no vehicles on account. Wait and queue command", cmd)
					Queue.push(SendQueue, {cmd = cmd, cbs = cbs, cbf = cbf, param = param, retry = retry})
					luup.call_delay("TSC_recheck_vehicle", 10, "20")
					return true, 200, "Waiting to re-find vehicle on account."
				else
					-- We have some failure
					cbf({cmd = cmd, cbs = cbs, cbf = cbf, param = param, retry = retry}, reply, msg)
					log.Debug("SendCommandAsync, failure for command %s", cmd)
					return false, reply, msg
				end	
			end
		end
	end

	-- Get all the data for car if awake
	local function _get_vehicle_data()
		-- Check for awake status
		local res, reply, msg = _get_vehicle_awake_status()
		if res and reply then
			local res, reply, msg = _send_command("getVehicleDetails")
			return res, reply, msg
		elseif res and not reply then
			return false, false, "Car is not online."
		else	
			return false, reply, msg
		end
	end
	
	-- Close session.
	local function _logoff()
		-- Check if we are authenticated
		if auth_data.token then
			local msg = "OK"
			local cmd = commands.logoff
			local res, reply, cde = HttpsRequest(cmd.method, base_url .. cmd.url , request_header ,	
			{
				token = auth_data.token
			} )
			if res then
				auth_data.expires_at = nil
				auth_data.token = nil
			else
				msg = "request failed, HTTP code ".. cde
			end
			return res, cde, msg
		else
			return false, 401, "Not authenticated."
		end
	end

	-- Wait until vehicle is awake, then re-send the queued command
	-- If wake up fails we empty the whole queue, to avoid dead lock. It is up to calling app to start over at later point.
	local function TSC_await_wakeup_vehicle(param)
		log.Debug("TSC_await_wakeup_vehicle enter",param)	
		local cnt = tonumber(param) - 1
		if cnt > 0 then
			-- See if awake by now.
			local res, reply, msg = _get_vehicle_awake_status()
			if res and reply then
				-- It's awake, send the command(s) from the queue
				log.Debug("Wake up loop #%d woke up car. Send command(s).", cnt)
				luup.call_delay("TSC_send_queued", 2)
			elseif res then
				-- Not awake yet retry in three seconds.
				log.Debug("Loop #%d to wake up car.", cnt)
				luup.call_delay("TSC_await_wakeup_vehicle", 3, tostring(cnt))
				if (cnt % 5) == 1 then
					-- resend wake_up command if still asleep after 15 seconds
					local res, reply, msg = _send_command("wakeUp")
					if res then
						log.Debug("Loop #%d to wake up car resend wake_up.", cnt)
					else
						-- Wake up failing signal then empty queue
						local pop_t = Queue.pop(SendQueue)
						pop_t.cbf(pop_t, reply, msg)
						Queue.drop(SendQueue)
						log.Error("Failure to wake up car. #%s, %s", reply, msg)
					end
				end	
			else
				-- Failure
				local pop_t = Queue.pop(SendQueue)
				pop_t.cbf(pop_t, reply, msg)
				Queue.drop(SendQueue)
				log.Error("Failure to wake up car. #%s, %s", reply, msg)
			end
		else
			-- Wake up failed. Empty command queue.
			local pop_t = Queue.pop(SendQueue)
			pop_t.cbf(pop_t, 522, "Unable to wake up car in set time.")
			Queue.drop(SendQueue)
			log.Error("Unable to wake up car in set time.")
		end
	end
	
	-- We got that no vehicles where on the account. Recheck, then wake up.
	local function TSC_recheck_vehicle(param)
		local cnt = tonumber(param) - 1
		if cnt > 0 then
			-- See if there is a car by now.
			local res, reply, msg = _get_vehicle_awake_status()
			if res and reply then
				-- Car found and awake
				log.Debug("Recheck loop #%d found car awake. Send command(s).", cnt)
				luup.call_delay("TSC_send_queued", 2)
			elseif res and not reply then
				-- Found, but awake yet. Try to wake up.
				log.Debug("Loop #%d found car, but need to wake up car.", cnt)
				_send_command("wakeUp")
				luup.call_delay("TSC_await_wakeup_vehicle", 5, "10")
			elseif not res and reply == 404 then
				-- Still no car reported, try again
				log.Debug("Loop #%d to find car on account.", tostring(cnt))
				luup.call_delay("TSC_recheck_vehicle", 10, cnt)
			else	
				log.Error("Failure to find car. #%s, %s", reply, msg)
			end
		else
			log.Error("Unable to wake up car in set time.")
		end
	end

	-- Send a queued command
	local function TSC_send_queued()
		log.Debug("Sending command #%d from Queue.", Queue.len(SendQueue))
		_send_command_async(nil)
	end
	
	-- Initialize API functions 
	local function _init(email, password, vin)
		auth_data.email = email
		auth_data.password = password
		auth_data.vin = vin
		-- Need to make these global for luup.call_delay use. 
		_G.TSC_send_queued = TSC_send_queued
		_G.TSC_recheck_vehicle = TSC_recheck_vehicle
		_G.TSC_await_wakeup_vehicle = TSC_await_wakeup_vehicle
	end

	return {
		Initialize = _init,
		Authenticate = _authenticate,
		Logoff = _logoff,
		GetVehicleVins = _get_vehicle_vins,
		GetVehicle = _get_vehicle,
		GetVehicleAwakeStatus = _get_vehicle_awake_status,
		GetVehicleData = _get_vehicle_data,
		SendCommand = _send_command,
		SendCommandAsync = _send_command_async
	}
end

-- Interface of the module
function TeslaCarModule()
	local readyToPoll = false
	local last_woke_up_time = 0
	local last_scheduled_poll = 0

	-- Set best status message
	local function _set_status_message(proposed)
		local msg = ""
		if proposed then
			msg = proposed
		else
			-- First check if configured and connected or not
			if not readyToPoll then
				msg = "Not ready for regular polling. Check settings or reload luup."
			else
				-- Look for messages based on key status items
				for k, msg_t in pairs(messageMap) do
					local val = var.Get(msg_t.var)
					if val ~= msg_t.val then
						msg = msg_t.msg
						break
					end    
				end
				-- If no message, display range
				if msg == "" then
					local units = (var.Get("GuiDistanceUnits") == "km/hr" and "km" or "mi")
					msg = string.format("Range: %s%s", var.Get("BatteryRange"), units)
				end
			end
		end
		var.Set("DisplayLine2", msg, SIDS.ALTUI)
	end
	
	-- Some generic conversion functions for variables
	local _bool_to_zero_one = function(bstate)
		if type(bstate) == "boolean" then
			return bstate and "1" or "0"
		else
			return tostring(bstate or 0)
		end
	end
	
	-- All range values are in miles per hour, convert to KM per hour if GUI is set to it.
	-- Trunkate to whole number.
	local _convert_range_miles_to_units = function(miles, typ)
		local units
		if typ == "C" then
			units = var.Get("GuiChargeRateUnits")
		else
			units = var.Get("GuiDistanceUnits")
		end
		if units ~= "mi/hr" then
			return math.floor(miles / 0.621371)
		else
			return math.floor(miles)
		end	
	end

	-- Logoff, This will fore a new login
	local function _reset()
		readyToPoll = false
		TeslaCar.Logoff()
		_set_status_message()
		return 200, "OK"
	end
	
	local function _login()
		-- Get login details
		local email = var.Get("Email")
		local password = var.Get("Password")
		-- If VIN is set look for car with that VIN, else first found is used.
		local vin = var.Get("VIN")
		if email ~= "" and password ~= "" then
			TeslaCar.Initialize(email, password, vin)
			local res, reply, msg = TeslaCar.Authenticate(true)
			if res then
				var.Set("LastLogin", os.time())
				res, reply, msg = TeslaCar.GetVehicle()
				if res then
					readyToPoll = true
					var.Set("IconSet", ICONS.IDLE)
					return 200, msg
				else	
					log.Error("Unable to select vehicle. errorCode : %s, errorMessage : %s", reply, msg)
					return reply, msg
				end
			else
				log.Error("Unable to login. errorCode : %s, errorMessage : %s", reply, msg)
				return reply, "Login to TeslaCar Portal failed "..msg
			end
		else
			log.Warning("Configuration not complete, missing email and/or password")
			return 404, "Plug-in setup not complete", "Missing email and/or password, please complete setup."
		end
	end
	
	local function _command(command)
		log.Debug("Sending command : %s", command)
		local res, cde, msg = TeslaCar.SendCommand(command, param)
		if res then
			log.Log("Command result : Code ; %s, Response ; %s",cde, string.sub(res,1,30))
			log.Debug(res)	
			return cde, res
		else
			return cde, res
		end
	end
	
	-- Calculate distance between two lat/long coordinates
	local function _distance(lat1, lon1, lat2, lon2) 
		local p = 0.017453292519943295    -- Math.PI / 180
		local c = math.cos
		local a = 0.5 - c((lat2 - lat1) * p)/2 + c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p))/2
		return 12742 * math.asin(math.sqrt(a)) -- 2 * R; R = 6371 km
	end
	
	-- Update any child device variables.
	local function _update_child_devices()

		-- Loop over all configured child devices
		for chDevID, chDevTyp in pairs (childIDMap) do
			local chDev = childDeviceMap[chDevTyp]
			if chDev then
				log.Debug("Updating child device %s, %s", chDevID, chDev.name)
				if chDev.sf then
					-- Function defined, call that
					chDev.sf(chDev.devID)
				else
					-- Get the value from parent variable
					local val = var.Get(chDev.pVar)
					log.Debug("parent variable %s, value %s, to update %s" ,chDev.pVar, val, chDev.var)
					-- Update the child variable
					var.Set(chDev.var, val, chDev.sid, chDev.devID)
				end
			else
				-- Should never get here.
				log.Warning("UpdateChildDevice, undefined child device type %s for child device ID %s", chDevTyp, chDevID)
			end
		end
	end
	
	-- Set the GUI textual message texts based on currently known status variables
	local function _update_message_texts()
		local sf = string.format
		
		-- Create desired text message
		local function buildStatusText(item)
			local tc = table.concat
			local drs, lckd = 4,0
			local txt_t = {}
			if item.df ~= lckd then txt_t[#txt_t+1] = "Driver front" end
			if item.pf ~= lckd then txt_t[#txt_t+1] = "Passenger front" end
			if item.dr ~= lckd then txt_t[#txt_t+1] = "Driver rear" end
			if item.pr ~= lckd then txt_t[#txt_t+1] = "Passenger rear" end
			if #txt_t == 0 then
				return nil
			elseif #txt_t == 1 then
				return tc(txt_t, ", ").." is "
			elseif #txt_t < drs then
				return tc(txt_t, ", ").." are "
			else	
				return "All are "
			end
		end
		-- Set status messages
		-- Convert remaining time to hh:mm time
		local units = (var.Get("GuiDistanceUnits") == "km/hr" and "km" or "mi")
		local bl = var.Get("BatteryLevel", SIDS.HA)
		local br = var.Get("BatteryRange")
		local icon = ICONS.IDLE
		if var.GetNumber("ChargeStatus") == 1 then
			local chrTime = var.GetNumber("RemainingChargeTime")
			local hrs = math.floor(chrTime)
			local mins = math.floor((chrTime - hrs) * 60)
			var.Set("ChargeMessage", sf("Battery %s%%, range %s%s, time remaining %d:%02d.", bl, br, units, hrs, mins))
			var.Set("DisplayLine2", sf("Charging; range %s%s, time remaining %d:%02d.", bl, units, hrs, mins), SIDS.ALTUI)
			icon = ICONS.CHARGING
		else	
			if var.GetNumber("PowerSupplyConnected") == 1 and var.GetNumber("PowerPlugState") == 1 then
				var.Set("DisplayLine2", "Power cable connected, not charging.", SIDS.ALTUI)
				icon = ICONS.CONNECTED
			end
			var.Set("ChargeMessage", sf("Battery %s%%, range %s%s.", bl, br, units))
		end
		-- Set user messages and icons based on actual values
		if var.GetNumber("ClimateStatus") == 1 then
			var.Set("ClimateMessage", "Climatizing on")
			var.Set("DisplayLine2", "Climatizing on.", SIDS.ALTUI)
			icon = ICONS.CLIMATE
		else
			local inst = var.Get("InsideTemp")
			local outt = var.Get("OutsideTemp")
			local units = var.Get("GuiTempUnits")
			var.Set("ClimateMessage", sf("Inside temp %s%s, outside temp %s%s", inst, units, outt, units))
		end	
		local txt = buildStatusText(json.decode(var.Get("DoorsStatus")))
		if txt then
			var.Set("DoorsMessage", txt .. "open")
			var.Set("DisplayLine2", "One or more doors are opened.", SIDS.ALTUI)
			icon = ICONS.DOORS
		else	
			var.Set("DoorsMessage", "Closed")
		end	
		txt = buildStatusText(json.decode(var.Get("WindowsStatus")))
		if txt then
			var.Set("WindowsMessage", txt .. "open")
			var.Set("DisplayLine2", "One or more windows are opened.", SIDS.ALTUI)
			icon = ICONS.WINDOWS
		else	
			var.Set("WindowsMessage", "Closed")
		end
		if var.GetNumber("FrunkStatus") == 1 then
			var.Set("FrunkMessage", "Unlocked.")
			var.Set("DisplayLine2", "Frunk is unlocked.", SIDS.ALTUI)
			icon = ICONS.FRUNK
		else	
			var.Set("FrunkMessage", "Locked")
		end
		if var.GetNumber("TrunkStatus") == 1 then
			var.Set("TrunkMessage", "Unlocked.")
			var.Set("DisplayLine2", "Trunk is unlocked.", SIDS.ALTUI)
			icon = ICONS.TRUNK
		else	
			var.Set("TrunkMessage", "Locked")
		end
		if var.GetNumber("LockedStatus") == 0 then
			var.Set("LockedMessage", "Car is unlocked.")
			var.Set("DisplayLine2", "Car is unlocked.", SIDS.ALTUI)
			icon = ICONS.UNLOCKED
		else	
			var.Set("LockedMessage", "Locked")
		end
		if var.GetNumber("MovingStatus") == 1 then
			var.Set("DisplayLine2", "Car is moving.", SIDS.ALTUI)
			icon = ICONS.MOVING
		else	
			var.Set("LockedMessage", "Locked")
		end
		local swStat = var.GetNumber("SoftwareStatus")
		if swStat == 0 then
			var.Set("SoftwareMessage", "Current version : ".. var.Get("CarFirmwareVersion"))
		elseif swStat == 1 then
			var.Set("SoftwareMessage", "Downloading version : ".. var.Get("AvailableSoftwareVersion"))
		elseif swStat == 2 then
			var.Set("SoftwareMessage", "Version ".. var.Get("AvailableSoftwareVersion").. " ready for installation.")
		elseif swStat == 3 then
			var.Set("SoftwareMessage", "Scheduled version : ".. var.Get("AvailableSoftwareVersion"))
		elseif swStat == 4 then
			var.Set("SoftwareMessage", "Installing version : ".. var.Get("AvailableSoftwareVersion"))
		end
		var.Set("LastCarMessageTimestamp", os.time())
		var.Set("IconSet", icon or 0) -- Do not use nil on ALTUI!
		return true
	end

	-- Process the values returned for drive state
	local function _update_gui_settings(settings)
		if settings then
			var.Set("Gui24HourClock", _bool_to_zero_one(settings.gui_24_hour_time))
			var.Set("GuiChargeRateUnits", settings.gui_charge_rate_units or "km/hr")
			var.Set("GuiDistanceUnits", settings.gui_distance_units or "km/hr")
			var.Set("GuiTempUnits", settings.gui_temperature_units or "C")
			var.Set("GuiRangeDisplay", settings.gui_range_display or "")
			var.Set("GuiSettingsTS", settings.timestamp or os.time())

		end
	end

	-- Process the values returned for vehicle config
	local function _update_vehicle_config(config)
		if config then
			var.Set("CarType", config.car_type or "")
			var.Set("CarHasRearSeatHeaters", config.rear_seat_heaters or 0)
			var.Set("CarHasSunRoof", config.sun_roof_installed or 0)
			var.Set("CarHasMotorizedChargePort", _bool_to_zero_one(config.motorized_charge_port))
			var.Set("CarCanAccutateTrunks", _bool_to_zero_one(config.motorized_charge_port))
		end
	end

	-- Process the values returned for drive state
	local function _update_drive_state(state)
		if state then
			-- Update location details
			local lat = (state.latitude or 0)
			local lng = (state.longitude or 0)
			var.Set("Latitude", lat)
			var.Set("Longitude", lng)
			-- Compare to home location and set/clear at home flag when within 500 m
			lat = tonumber(lat) or luup.latitude
			lng = tonumber(lng) or luup.longitude
			local radius = var.GetNumber("AtLocationRadius")
			if _distance(lat, lng, luup.latitude, luup.longitude) < radius then
				var.Set("LocationHome", 1)
			else
				var.Set("LocationHome", 0)
			end
			var.Set("LocationTS", state.gps_as_of or 0)

			-- Update other drive details
			var.Set("MovingStatus", (state.shift_state and state.shift_state ~= 'P') and 1 or 0)
			var.Set("DriveSpeed", state.speed or 0)
			var.Set("DrivePower", state.power or 0)
			var.Set("DriveShiftState", state.shift_state or 0)
			var.Set("DriveStateTS", state.timestamp or os.time())
		end
	end

	-- Process the values returned for climate state
	local function _update_climate_state(state)
		if state then
			var.Set("BatteryHeaterStatus", _bool_to_zero_one(state.battery_heater))
			var.Set("ClimateStatus", _bool_to_zero_one(state.is_climate_on))
			var.Set("InsideTemp", state.inside_temp or 0)
			var.Set("MinInsideTemp", state.min_avail_temp or 0)
			var.Set("MaxInsideTemp", state.max_avail_temp or 0)
			var.Set("OutsideTemp",state.outside_temp or 0)
			var.Set("ClimateTargetTemp", state.driver_temp_setting or 0)
			var.Set("FrontDefrosterStatus", _bool_to_zero_one(state.is_front_defroster_on))
			var.Set("RearDefrosterStatus", _bool_to_zero_one(state.is_rear_defroster_on))
			var.Set("PreconditioningStatus", _bool_to_zero_one(state.is_preconditioning))
			var.Set("FanStatus", state.fan_status or 0)
			var.Set("SeatHeaterStatus", state.seat_heater_left or 0)
			var.Set("MirrorHeaterStatus", _bool_to_zero_one(state.side_mirror_heaters))
			var.Set("SteeringWeelHeaterStatus", _bool_to_zero_one(state.steering_wheel_heater))
			var.Set("WiperBladesHeaterStatus", _bool_to_zero_one(state.wiper_blade_heater))
			var.Set("SmartPreconditioning", _bool_to_zero_one(state.smart_preconditioning))
			var.Set("ClimateStateTS", state.timestamp or os.time())
		end
	end

	-- Process the values returned for charge state
	local function _update_charge_state(state)
		if state then
			if state.charging_state == "Charging" and state.time_to_full_charge and state.time_to_full_charge > 0 then
				var.Set("RemainingChargeTime", state.time_to_full_charge)
			else
				var.Set("RemainingChargeTime", 0)
			end
			if state.battery_range then var.Set("BatteryRange", _convert_range_miles_to_units(state.battery_range, "D")) end
			if state.battery_level then var.Set("BatteryLevel", state.battery_level , SIDS.HA) end
			if state.conn_charge_cable then
				-- Is in api_version 7, but not before I think
				if state.conn_charge_cable ~= "<invalid>" then
					var.Set("PowerPlugState", 1)
				else	
					var.Set("PowerPlugState", 0)
				end
			else
				-- V6 and prior.
				if state.charging_state == "Disconnected" or state.charging_state == "NoPower" then
					var.Set("PowerPlugState", 0)
				else
					var.Set("PowerPlugState", 1)
				end
			end
			if state.charging_state then 
				if state.charging_state == "Charging" then
					var.Set("ChargeStatus", 1) 
					var.Set("PowerSupplyConnected", 1)
				elseif state.charging_state == "Complete" then
					var.Set("ChargeStatus", 0) 
					var.Set("PowerSupplyConnected", 1)
				elseif state.charging_state == "NoPower" then
					var.Set("ChargeStatus", 0) 
					var.Set("PowerSupplyConnected", 0)
				elseif state.charging_state == "Disconnected" then
					var.Set("ChargeStatus", 0) 
					var.Set("PowerSupplyConnected", 0)
				elseif state.charging_state == "Stopped" then
					var.Set("ChargeStatus", 0) 
					var.Set("PowerSupplyConnected", 1)
				end
			end
			if state.charge_port_latch then var.Set("ChargePortLatched", state.charge_port_latch == "Engaged" and 1 or 0) end
			var.Set("ChargePortDoorOpen", _bool_to_zero_one(state.charge_port_door_open))
			var.Set("BatteryHeaterOn", _bool_to_zero_one(state.battery_heater_on))
			var.Set("ChargeRate", state.charge_rate or 0)
			var.Set("ChargePower", state.charger_power or 0)
			var.Set("ChargeLimitSOC", state.charge_limit_soc or 90)
			var.Set("ChargeStateTS", state.timestamp or 0)
		end
	end

	-- Process the values returned for vehicle state
	local function _update_vehicle_state(state)
		if state then
			var.Set("CarApiVersion", state.api_version or 0)
			var.Set("CarFirmwareVersion", state.car_version or 0)
			var.Set("CarCenterDisplayStatus", state.center_display_state or 0)
			var.Set("UserPresent", _bool_to_zero_one(state.is_user_present))
			if state.odometer then var.Set("Mileage",_convert_range_miles_to_units(state.odometer, "D")) end
			var.Set("LockedStatus", _bool_to_zero_one(state.locked))
			var.Set("FrunkStatus",state.ft)
			var.Set("TrunkStatus",state.rt)
			var.Set("DoorsStatus",json.encode({df = state.df, pf = state.pf, dr = state.dr, pr = state.pr}))
			if state.fd_window then
				var.Set("WindowsStatus", json.encode({df = state.fd_window, pf = state.fp_window, dr = state.rd_window, pr = state.rp_window}))
			else
				-- Seems model S does not report windows status, so assume closed.
				var.Set("WindowsStatus", json.encode({df = 0, pf = 0, dr = 0, pr = 0}))
			end	
			if var.GetNumber("CarHasSunRoof") ~= 0 and state.sun_roof_state then 
				var.Set("SunroofStatus",state.sun_roof_state)
			end	
			-- Check for software update status
			if state.software_update then
				local swStat = 0
				local swu = state.software_update
				if swu.status == "" then
					-- nothing to do.
				elseif swu.status == "available" then
					if swu.download_perc == 100 then
						swStat = 2
					else
						swStat = 1
					end
				elseif swu.status == "scheduled" then
					swStat = 3
				elseif swu.status == "installing" then
					swStat = 4
				end
				if swu.version and swu.version ~= "" then
					var.Set("AvailableSoftwareVersion", swu.version)
				else
					var.Set("AvailableSoftwareVersion", "")
				end
				var.Set("SoftwareStatus", swStat)
			end
		end
	end

	-- Call backs for car request commands.
	local function CM_CBS_Error(cmd,data,msg)
		-- cmd = {cmd, cbs , cbf, param, retry}
		log.Error("Call back fail called: %s",msg)
		if data == 522 then
			-- Could not wake up car
			log.Error("Call back fail to wake up car: %s",msg)
			_set_status_message("Failed to wake up car for command: "..cmd.cmd)
		elseif data == 408 or data == 502 or data == 504 then
			-- codes 502, 504 and 408 call for a retry
			if cmd.retry < 4 then
				log.Warning("Call back fail. Doing retry #%d, command %s, msg: %s", cmd.retry, cmd.cmd, msg)
				TeslaCar.SendCommandAsync(cmd.cmd, cmd.param, cmd.cbs, cmd.cbf, cmd.retry+1)
			else
				log.Error("Call back failed of command %s after max retries #%d, msg: %s", cmd.cmd, cmd.retry, msg)
				_set_status_message("Failed to send command: "..cmd.cmd)
			end
		else	
			_set_status_message()
		end
	end
	
	-- Standard call back for commands that do not require special handling
	local function CM_CBS_Success(cmd,data,msg)
		-- cmd = {cmd, cbs , cbf, param, retry}
		if type(data) ~= "string" then
			if data.response.result then
				var.Set("CarIsAwake", 1)  -- Car must be awake by now.
				log.Debug("Call back for success command %s, message : %s", cmd.cmd, msg)
			else
				log.Debug("Call back for success command %s, error message : %s", cmd.cmd, data.response.reason)
			end
			-- Update car status in 15 seconds so car can process command. Get scheduled time, so we can optimize.
			last_scheduled_poll = os.time() + 15
			log.Debug("Scheduling poll at %s", os.date("%X", last_scheduled_poll))
			luup.call_delay("_poll", 15)
		else
			log.Debug("Call back success message : %s",msg)
			log.Debug("Call back data: %s",data)
		end
		_set_status_message()
	end

	-- Callback for GetVehicleDetails
	local function CM_CBS_getVehicleDetails(cmd,data,msg)
		-- cmd = {cmd, cbs , cbf, param, retry}
		if data.response then
			local icon = ICONS.IDLE
			var.Set("CarIsAwake", 1)  -- Car must be awake by now.
			local resp = data.response
--			var.Set("VehicleData", json.encode(resp))
			-- Process overall response values
			var.Set("CarName", resp.display_name)
			var.Set("DisplayLine1","Car : "..resp.display_name, SIDS.ALTUI)
			var.Set("VIN", resp.vin)
			-- Process specific category states
			_update_gui_settings(resp.gui_settings)
			_update_vehicle_state(resp.vehicle_state)
			_update_drive_state(resp.drive_state)
			_update_climate_state(resp.climate_state)
			_update_charge_state(resp.charge_state)
			-- Update GUI messages and child devices
			_update_message_texts()
			_update_child_devices()
		else
			-- No response data, some error I presume
			log.Error("Get TeslaCar.GetVehicleData, no response data error : %s", msg)
		end
		_set_status_message()
		data = nil
	end

	-- Callback for GetServiceData
	local function CM_CBS_getServiceData(cmd,data,msg)
		-- cmd = {cmd, cbs , cbf, param, retry}
		if data.response then
			local resp = data.response
			-- Process overall response values
			if resp.service_status then
				var.Set("InServiceStatus", resp.service_status == "in_service" and 1 or 0)
				var.Set("InServiceEtc", resp.service_etc)
			else
				var.Set("InServiceStatus", 0)
				var.Set("InServiceEtc", "")
			end
		else
			-- No response data, some error I presume
			log.Error("Get TeslaCar.GetServiceData, no response data error : %s", msg)
		end
		data = nil
	end

	-- Request the latest status from the car
	local function _update_car_status(force)
		
		if not force then
			-- Only poll if car is awake
			if var.GetNumber("CarIsAwake") == 0 then
				var.Set("IconSet",ICONS.ASLEEP)
				log.Debug("CarModule.UpdateCarStatus, skipping, Tesla is asleep.")
				return false, "Car is asleep"
			end
		end

		_set_status_message("Updating car status...")
		local res, data, msg = TeslaCar.SendCommandAsync("getVehicleDetails",nil,CM_CBS_getVehicleDetails,CM_CBS_Error)
		if res then
			log.Debug("TeslaCar.GetVehicleData Async result : %s, %s", data, msg)
			local res, data, msg = TeslaCar.SendCommandAsync("getServiceData",nil,CM_CBS_getServiceData,CM_CBS_Error)
		else
			log.Error("TeslaCar.GetVehicleData Async failed : %s, %s", data, msg)
			_set_status_message()
		end
		return res, msg
	end	

	-- Send the requested command
	local function _start_action(request, param)
		log.Debug("Start Action enter for command %s, %s.", request, (param or ""))
		_set_status_message("Sending command "..request)
		local res, data, msg = TeslaCar.SendCommandAsync(request,param,CM_CBS_Success,CM_CBS_Error)
		if res then
			log.Debug("Start Action Async result : %s, %s", data, msg)
		else
			log.Error("Start Action Async failed : %s, %s", data, msg)
			_set_status_message()
		end

	end	
	
	-- Trigger a forced update of the car status. Will wake up car.
	function _poll()
		log.Debug("Poll, start")
		local dt = os.time() - last_scheduled_poll
		if dt >= 0 then
			_update_car_status(true)
			last_scheduled_poll = 0
		else
			log.Info("Skipping Poll as a next is planned in %d sec.", math.abs(dt))
		end
	end

	-- Execute daily poll if scheduled
	local function _daily_poll(startup)
		local sg = string.gsub
		local force = false
		if startup == true then force = true end -- on Vera with luup.call_delay the paramter is never nil, but empty string "" is not specified.

		log.Debug("Daily Poll, enter")
		-- Schedule at next day if a time is configured
		local poll_time = var.Get("DailyPollTime")
		if poll_time ~= "" then
			log.Debug("Daily Poll, scheduling for %s.", poll_time)
			luup.call_timer("_daily_poll", 2, poll_time .. ":00", "1,2,3,4,5,6,7")
			if (not force) and readyToPoll then
				-- If not at start-up, poll car if enabled.
				-- PollSettings [1] = DailyPoll Enabled
				local pol = var.Get("PollSettings")
				local pol_t = {}
				sg(pol..",","(.-),", function(c) pol_t[#pol_t+1] = c end)
				if pol_t[1] == "1" then
					log.Debug("Daily Poll, start poll.")
					_update_car_status(true)
				else
					log.Debug("Daily Poll, not enabled.")
				end
			else
				log.Debug("Daily Poll, not polling now.")
			end
		else
			log.Debug("Daily Poll, no time set.")
		end
	end
	
	-- Calculates polls based on car status
	-- Advised polling:
	--	* Standard status polling no more then once per 15 minutes for idle car so it can go asleep
	--	* When asleep, check for that status as often as you like, e.g. every five minutes.
	--	* When charging it can go to sleep, but you may want to poll more frequently depending on remining charge time. E.g. 
	--		- if 10 hrs left, poll once per hour, if less than an hour, poll every five minutes (car will not go asleep).
	--	* For other activities like heating, poll every minute or so.
	local function _scheduled_poll(startup)
		local sg = string.gsub

		log.Debug("Scheduled Poll, enter")
		luup.call_delay("_scheduled_poll", 60)
		if readyToPoll then
			local interval, awake = 0, 0
			local force = false
			local lastPollInt = os.time() - var.GetNumber("LastCarMessageTimestamp")
			local prevAwake = var.GetNumber("CarIsAwake")
			local swStat = var.GetNumber("SoftwareStatus")
			local lckStat = var.GetNumber("LockedStatus")
			local clmStat = var.GetNumber("ClimateStatus")
			local mvStat = var.GetNumber("MovingStatus")
			local res, cde, msg = TeslaCar.GetVehicleAwakeStatus()
			if res then
				if cde then
					awake = 1
					if prevAwake == 0 then
						last_woke_up_time = os.time()
						log.Debug("Monitor awake state, Car woke up")
					else
						log.Debug("Monitor awake state, Car is awake")
					end
				else
					last_woke_up_time = 0
					log.Debug("Monitor awake state, Car is asleep")
				end	
				var.Set("CarIsAwake", awake)
			else	
				last_woke_up_time = 0
				log.Debug("Monitor awake state, failed %s %s", cde, msg)
			end
			-- PollSettings [2] = Poll interval if car is awake
			-- PollSettings [3] = Poll interval if charging and remaining charge time > 1 hour
			-- PollSettings [4] = Poll interval if charging and remaining charge time < 1 hour
			-- PollSettings [5] = Poll interval when car just woke up not by our action or activity occurs (Unlocked, Preheat, SW install)
			-- PollSettings [6] = Poll interval if car is moving
			local pol = var.Get("PollSettings")
			local pol_t = {}
			sg(pol..",","(.-),", function(c) pol_t[#pol_t+1] = c end)
			log.Debug("mvStat %d, awake %d, prevAwake %d, last woke int %s, swStat %d, lckStat %d, clmStat %d",mvStat,awake, prevAwake, tostring((os.time() - last_woke_up_time)),swStat,lckStat,clmStat)
			if mvStat == 1 then
				interval = pol_t[6]
				force = true
			elseif (awake == 1 and (os.time() - last_woke_up_time) < 200) or swStat ~= 0 or lckStat == 0 or clmStat == 1 then
				interval = pol_t[5]
				force = true
			elseif var.GetNumber("ChargeStatus") == 1 then
				force = true
				if var.GetNumber("RemainingChargeTime") > 1 then
					interval = pol_t[3]
				else
					interval = pol_t[4]
				end
			elseif awake == 1 then
				interval = pol_t[2]
			end
			interval = interval * 60  -- Minutes to seconds
			if interval == 0 then interval = 15*60 end
			log.Debug("Next Scheduled Poll in %s seconds, last poll %s seconds ago, forced is %s.", interval, lastPollInt, tostring(force))
			-- See if we passed poll interval.
			if interval <= lastPollInt and readyToPoll then
				-- Get latest status from car.
				_update_car_status(force)
			end
			-- If we have software ready to install and auto install is on, send command to install
			if swStat == 2 then
				if var.GetNumber("AutoSoftwareInstall") == 1 then
					_start_action("updateSoftware")
				end
			end
		else
			log.Warning("Scheduled Poll, not yet ready to poll.")
		end
	end

	-- Initialize module
	local function _init()
	
		-- Create variables we will need from get-go
		var.Set("Version", pD.Version)
		var.Default("Email")
		var.Default("Password") --store in attribute
		var.Default("LogLevel", pD.LogLevel)
		var.Default("PollSettings", "1,20,15,5,1,5") --Daily Poll (1=Y,0=N), Interval for; Idle, Charging long, Charging Short, Active, Moving in minutes
		var.Default("DailyPollTime","7:30")
		var.Default("MonitorAwakeInterval",60) -- Interval to check is car is awake, in seconds
		var.Default("LastCarMessageTimestamp", 0)
		var.Default("LocationHome",0)
		var.Default("CarName")
		var.Default("VIN")
		var.Default("ChargeStatus", 0)
		var.Default("ClimateStatus", 0)
		var.Default("ChargeMessage")
		var.Default("ClimateMessage")
		var.Default("WindowMeltMessage")
		var.Default("DoorsStatus", 0)
		var.Default("LocksStatus", 0)
		var.Default("WindowsStatus", 0)
		var.Default("SunroofStatus", 0)
		var.Default("LightsStatus", 0)
		var.Default("TrunkStatus", 0)
		var.Default("FrunkStatus", 0)
		var.Default("SoftwareStatus", 0)
		var.Default("MovingStatus", 0)
		var.Default("PowerSupplyConnected", 0)
		var.Default("Mileage")
		var.Default("StandardChargeLimit", 90)
		var.Default("AutoSoftwareInstall", 0)
		var.Default("AtLocationRadius", 0.5)
		var.Default("IconSet",ICONS.UNCONFIGURED)
		var.Default("PluginHaveChildren")
		
		_G._poll = _poll
		_G._daily_poll = _daily_poll
		_G._scheduled_poll = _scheduled_poll
		
		return true
	end

	return {
		Reset = _reset,
		Login = _login,
		Poll = _poll,
		DailyPoll = _daily_poll,
		ScheduledPoll = _scheduled_poll,
		StartAction = _start_action,
		UpdateCarStatus = _update_car_status,
		UpdateChildren = _update_child_devices,
		SetStatusMessage = _set_status_message,
		Initialize = _init
	}
end

-- Handle child SetTarget actions
local function TeslaCar_Child_SetTarget(newTargetValue, deviceID)
	log.Debug("SetTarget for deviceID %s, newTargetValue %s.", deviceID, newTargetValue)
	if childIDMap[deviceID] then
		local chDev = childDeviceMap[childIDMap[deviceID]]
		log.Debug("SetTarget Found child device %d, for type %s, name %s.", deviceID, chDev.typ, chDev.name)
		local curVal = var.Get(chDev.pVar)
		if curVal ~= newTargetValue then
			-- Find default car action for child SetTarget
			local ac = chDev.st_ac
			if not ac then
				ac = chDev["st_ac"..newTargetValue]
			end
			if ac then
				CarModule.StartAction(ac)
				local sid = chDev.sid or SIDS.SP
				var.Set("Target", newTargetValue, sid, deviceID)
				var.Set("Status", newTargetValue, sid, deviceID)
			else
				log.Debug("No action defined for child device.")
			end
			-- Update the parent variable, next poll should fall back if failed.
--			var.Set(chDev.pVar, newTargetValue)
		else
			log.Debug("SetTarget, value not changed (old %s, new %s). Ignoring action.", curVal, newTargetValue)
		end
	end
end

-- Handle child SetLoadLevelTarget actions
local function TeslaCar_Child_SetLoadLevelTarget(newLoadlevelTarget, deviceID)
	log.Debug("SetLoadLevelTarget for deviceID %s, newLoadlevelTarget %s.", deviceID, newLoadlevelTarget)
	if childIDMap[deviceID] then
		local chDev = childDeviceMap[childIDMap[deviceID]]
		log.Debug("SetLoadLevelTarget Found child device %d, for type %s, name %s.", deviceID, chDev.typ, chDev.name)
		if chDev.sll_af then
			chDev.sll_af(deviceID, newLoadlevelTarget)
		else
			log.Debug("No action defined for child device.")
		end
	end
end

-- Handle child SetModeTarget actions
local function TeslaCar_Child_SetModeTarget(newModeTarget, deviceID)
	log.Debug("SetModeTarget for deviceID %s, newModeTarget %s.", deviceID, tostring(newModeTarget))
	if childIDMap[deviceID] then
		local chDev = childDeviceMap[childIDMap[deviceID]]
		log.Debug("SetModeTarget Found child device %d, for type %s, name %s.", deviceID, chDev.typ, chDev.name)
		if chDev.smt_af then
			chDev.smt_af(deviceID, newModeTarget)
		else
			log.Debug("No action defined for child device.")
		end
	end
end

-- Handle child SetCurrentSetpoint actions
local function TeslaCar_Child_SetCurrentSetpoint(newCurrentSetpoint, deviceID)
	log.Debug("SetCurrentSetpoint for deviceID %s, newCurrentSetpoint %s.", deviceID, newCurrentSetpoint)
	if childIDMap[deviceID] then
		local chDev = childDeviceMap[childIDMap[deviceID]]
		log.Debug("SetCurrentSetpoint Found child device %d, for type %s, name %s.", deviceID, chDev.typ, chDev.name)
		if chDev.scs_af then
			chDev.scs_af(deviceID, newCurrentSetpoint)
		else
			log.Debug("No action defined for child device.")
		end
	end
end

-- Create any of the configured child devices
local function TeslaCar_CreateChilderen(disabled)
	local childTypes = var.Get("PluginHaveChildren")
	if childTypes == "" then 
		-- Note: we must continue this routine when there are no child devices as we may have ones that need to be deleted.
		log.Debug("No child devices to create.")
	else
		log.Debug("Child device types to create : %s.",childTypes)
	end
	local child_devices = luup.chdev.start(pD.DEV);				-- create child devices...
	childTypes = childTypes .. ','
	for chType in childTypes:gmatch("([^,]*),") do
		if chType ~= "" then
			local device = childDeviceMap[chType]
			local altid = 'TSC'..pD.DEV..'_'..chType
			if device then
				local vartable = {
					",disabled="..disabled,
					SIDS.HA..",HideDeleteButton=1",
					SIDS.MODULE..",ChildType="..chType
				}
				if chType == "H" then vartable[#vartable+1] = SIDS.TEMP..",Range=15,28/59,82;15,28/59,82;15,28/59,82" end
				-- Overwrite default json if needed.
				if device.json then vartable[#vartable+1] = ",device_json="..device.json end
				local name = "TSC: "..device.name
				log.Debug("Child device id " .. altid .. " (" .. name .. "), type " .. chType)
				luup.chdev.append(
					pD.DEV, 					-- parent (this device)
					child_devices, 				-- pointer from above "start" call
					altid,						-- child Alt ID
					name,						-- child device description 
					"", 						-- serviceId (keep blank for UI7 restart avoidance)
					device.df..".xml",			-- device file for given device
					"",							-- Implementation file is common for all child devices. Handled by parent?
					utils.Join(vartable, "\n"),	-- parameters to set 
					false,						-- child devices can go in any room
					false)						-- child devices is not hidden
			end
		end
	end	
	luup.chdev.sync(pD.DEV, child_devices)	-- any changes in configuration will cause a restart at this point

	-- Get device IDs of childs created_at
	for chDevID, d in pairs (luup.devices) do
		if d.device_num_parent == pD.DEV then
			local ct = var.Get("ChildType", SIDS.MODULE, chDevID)
			if childDeviceMap[ct] then
				log.Debug("Found child device %d, for type %s, name %s.", chDevID, ct, childDeviceMap[ct].name)
				childDeviceMap[ct].devID = chDevID
				childIDMap[chDevID] = ct
			end
		end
	end
end

-- Finish last setup deferred
function TeslaCar_DeferredInitialize(retry)
	local retry = tonumber(retry) or 0
	if retry ~= 0 then
		-- Wipe any message from previous attempts
		log.DeviceMessage(pD.DEV, -2, 0, pD.pwdMessage)
		log.DeviceMessage(pD.DEV, -2, 0, pD.retryLoginMessage)
		log.DeviceMessage(pD.DEV, -2, 0, pD.failedLoginMessage)
		log.Log("TeslaCar_DeferredInitialize start. Retry # : %d", retry)
	else	
		log.Log("TeslaCar_DeferredInitialize start.")
	end	
	local res, msg = CarModule.Login()
	if res == 200 then
		CarModule.SetStatusMessage()
	elseif res == 404 then
		log.DeviceMessage(pD.DEV, 2, 0, pD.pwdMessage)
		-- UID and/or Pwd missing. Wait for setup complete.
	else
		-- Login error, retry in 5 secs.
		if retry < 4 then
			log.DeviceMessage(pD.DEV, 1, 0, pD.retryLoginMessage)
			luup.call_delay("TeslaCar_DeferredInitialize", 5, retry + 1)
		else
			-- Too many retries.
			log.Error("Could not login to Tesla API after 5 attempts.")
			log.DeviceMessage(pD.DEV, 2, 0, pD.failedLoginMessage)
		end
	end

	log.Log("TeslaCar_DeferredInitialize finished ")
end

-- Handle changes in some key configuration variables.
-- Change in log level.
-- Changes in email or password for Telsa account.
function TeslaCar_VariableChanged(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
	local strNewVal = (lul_value_new or "")
	local strOldVal = (lul_value_old or "")
	local strVariable = (lul_variable or "")
	local lDevID = tonumber(lul_device or "0")
	log.Log("TeslaCar_VariableChanged Device " .. lDevID .. " " .. strVariable .. " changed from " .. strOldVal .. " to " .. strNewVal .. ".")

	if (strVariable == "VIN") then
	elseif (strVariable == "Email") then
		log.Debug("resetting TeslaCar connection...")
		CarModule.Reset()
		local pwd = var.Get("Password")
		if strVariable ~= "" and pwd ~= "" then
			TeslaCar_DeferredInitialize(1)
			CarModule.Poll()
		end
	elseif (strVariable == "Password") then
		log.Debug("resetting TeslaCar connection...")
		CarModule.Reset()
		local em = var.Get("Email")
		if strVariable ~= "" and em ~= "" then
			TeslaCar_DeferredInitialize(1)
			CarModule.Poll()
		end
	end
end

-- Initialize plug-in
function TeslaCarModule_Initialize(lul_device)
	pD.DEV = lul_device

	-- start Utility API's
	log = logAPI()
	var = varAPI()
	utils = utilsAPI()
	var.Initialize(SIDS.MODULE, pD.DEV)
	log.Initialize(pD.Description, var.GetNumber("LogLevel"), true)
	utils.Initialize()
	
	log.Info("device #%d is initializing!", tonumber(pD.DEV))

	-- See if we are running on openLuup or UI7. If not stop.
	if utils.GetUI() == utils.IsOpenLuup then
		pD.onOpenLuup = true
		log.Log("We are running on openLuup!!")
	elseif utils.GetUI() == utils.IsUI7 then	
		pD.onOpenLuup = false
		log.Log("We are running on Vera UI7!!")
	else	
		log.Error("Not supporting Vera UI%s!! Sorry.",luup.version_major)
		return false, "Not supporting Vera UI version", pD.Description
	end
	TeslaCar = TeslaCarAPI()
	CarModule = TeslaCarModule()
	CarModule.Initialize()

	-- Create child devices
	TeslaCar_CreateChilderen(var.GetAttribute("disabled"))
	
	-- See if user disabled plug-in 
	if (var.GetAttribute("disabled") == 1) then
		log.Warning("Init: Plug-in version %s - DISABLED",pD.Version)
		-- Now we are done. Mark device as disabled
		var.Set("DisplayLine2","Plug-in disabled", SIDS.ALTUI)
		utils.SetLuupFailure(0, pD.DEV)
		return true, "Plug-in Disabled.", pD.Description
	end	
	CarModule.UpdateChildren()

	-- Defer last bits of initialization for 15 seconds.
	luup.call_delay("TeslaCar_DeferredInitialize", 15, "0")

	-- Set watches on email and password as userURL needs to be erased when changed
	luup.variable_watch("TeslaCar_VariableChanged", SIDS.MODULE, "Email", pD.DEV)
	luup.variable_watch("TeslaCar_VariableChanged", SIDS.MODULE, "Password", pD.DEV)

	-- Start pollers
	CarModule.DailyPoll(true)
	CarModule.ScheduledPoll(true)

	log.Log("TeslaCarModule_Initialize finished ")
	utils.SetLuupFailure(0, pD.DEV)
	return true, "Plug-in started.", pD.Description
end
