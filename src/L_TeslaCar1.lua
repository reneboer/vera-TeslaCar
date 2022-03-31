--[[

	Module L_TeslaCar1.lua
	
	Written by R.Boer. 
	V2.7, 29 March 2022
	
	A valid Tesla account registration is required with OWNER or DRIVER access type.
	
	V2.7 Chagnges:
		- Updates for changed token handling by Tesla from March 21, 2022.
	V2.6 Changes:
		- Changed user agent to standard one.
		- Added Scheduled Charging and Departure commands. (in progress)
	V2.5 Changes:
		- Fix in case no return headers in http response.
	V2.4 Changes:
		- Replace all https request to owner-api.teslamotors.com to use cURL for out dated LuaSec version (Vera)
		- Added zlib support for openLuup.
		- Fix for log api on log.Debug
	V2.3 Changes:
		- Fix to logAPI.DisplayMessage
	V2.2 Changes:
		- Added log file setting for development debug
		- Improved logging module.
		- Hardening poller routines.
		- Minor fixes.
	V2.1 Changes:
		- Added more variables to the service file so they are included in the sdata request.
	V2.0 Changes:
		- Updated Authentication for new OAuth2 used by Tesla.
		- Tokens are stored so no reauthentication is needed at startup.
		- A reauthentication with UID/PWD can be forced if needed.
	V1.16 Changes:
		- Added icon to show communication is busy.
	V1.15 Changes:
		- Added sentry mode control.
	V1.14 Changes:
		- Fix for mileage vs km display.
	V1.13 Changes:
		- Fix for auto software install.
		- Units correction for ChargeRate if not mi/hr
		- Added HTTP return code 400 to the list of retry reason codes.
	V1.12 Changes:
		- Fix for new installs failing due to missing LogLevel variable.
		- Fixed handling of Trunk/Frunk status. Open is not 1, but not equal 0.
	V1.11 Changes:
		- Corrected state of several child devices.
	V1.10 Changes:
		- Improved car config handling.
		- Corrected sun roof handling.
		- Completed Vera scene triggers configurations in json.
		- Status temperature units use Vera setting, rather then car.
		- Hardened var module.
		- Added all car variables to startup routine.
		- Fixed json for setAutoSoftwareInstall control.
	V1.9 Changes:
		- Improved car wake up and send queue handling.
		- Changed call back to one handler for all with registrable call backs for specific commands as needed.
		- Added close trunk command for Model S
		- Module interfaces cleanup.
	V1.8 Changes:
		- Temperatures are converted from API standard Celsius to Vera's temp units (C or F) and back.
		- Retry command in 15 sec if the return is 200, but message could_not_wake_buses
		- Allow idle timer to be set as default 20 minutes may not be sufficient.
	V1.7 Changes:
		- Added new service_data command to get car service data.
		- Added retry if Tesla API returns 408, 502 or 504.
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
		- Tesla API for some model S does not seem to report windows status, set to closed for that version.
		- Similar for cable connected or not. Using derived value form charge_status instead for V6.
		
	To-do
		Smart, auto tuning preheat

]]

local ltn12 	= require("ltn12")
local json 		= require("dkjson")
local https     = require("ssl.https")
local http		= require("socket.http")
local mime 		= require("mime")
local bit		= require("bit")
local zlib = nil
pcall(function()
	-- Install package: sudo apt-get install lua-zlib
	zlib = require('zlib')
	if not zlib.inflate then zlib = nil end
end)

-- Modules definitions.
local TeslaCar
local CarModule
local log
local var
local utils

-- Misc delays and retries on car communication
local TCS_RETRY_DELAY			= 5			-- Between retries of failed commands
local TCS_POLL_SUCCESS_DELAY	= 10		-- To poll for new status after command succesfully send
local TCS_MAX_RETRIES			= 10		-- Maximum number of command send retries.
local TCS_MAX_WAKEUP_RETRIES	= 25		-- Maximum number of wake up resend attempts before giving up.
local TCS_WAKEUP_CHECK_INTERVAL	= 10		-- Time to see if wakeUp command woke up car.
local TCS_SEND_INTERVAL			= 1			-- Time to send next command from queue.
local TCS_HTTP_TIMEOUT			= 60		-- Timeout on http requests

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
	Version = "2.7",
	DEV = nil,
	LogLevel = 1,
	LogFile = "/tmp/TeslaCar.log",
	Description = "Tesla Car",
	onOpenLuup = false,
	veraTemperatureScale = "C",
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
						if not var.GetBoolean("ClimateStatus") then
							var.Set("ModeStatus", "Off", SIDS.HVAC_U, chDevID)
						else
							var.Set("ModeStatus", "HeatOn", SIDS.HVAC_U, chDevID)
						end
					end,
					smt_af = function(chDevID, newMode)
						-- Climate on or off
						local cmd = ""
						if newMode == "Off" then
							cmd = "stopClimate"
						elseif newMode == "HeatOn" then
							cmd = "startClimate"
						end
						if cmd ~= "" then
							local res, cde, data, msg = CarModule.StartAction(cmd)
							if res then
								var.Set("ModeStatus", newMode, SIDS.HVAC_U, chDevID)
							else
								log.Warning("Heater Mode command %s failed. Error #%d, %s", cmd, cde, msg)
							end
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
						if newTemp > maxTemp then newTemp = maxTemp end
						local res, cde, data, msg = CarModule.StartAction("setTemperature", newTemp)
						if res then
							var.Set("CurrentSetpoint", newTemp, SIDS.HEAT, chDevID)
							var.Set("ClimateTargetTemp", newTemp)
						else
							log.Warning("Heater Temp command failed. Error #%d, %s", cde, msg)
						end
					end
			},
	["L"] = { typ = "L", df = "D_DoorLock1", sid = SIDS.DOOR, json = "D_DoorLock_NoPin.json", name = "Doors Locked", devID = nil, st_ac0 = "unlockDoors", st_ac1 = "lockDoors", 
					pVal = function()
						return var.GetBoolean("LockedStatus") and 1 or 0
					end,
					sf = function(chDevID)
						local status = var.GetBoolean("LockedStatus") and 1 or 0
						var.Set("Status", status, SIDS.DOOR, chDevID)
						var.Set("Target", status, SIDS.DOOR, chDevID)
					end 
			},
	["W"] = { typ = "W", df = "D_BinaryLight1", name = "Windows Closed", devID = nil, st_ac0 = "ventWindows", st_ac1 = "closeWindows", 
					pVal = function()
						return var.Get("WindowsMessage") == "Closed" and 1 or 0
					end,
					sf = function(chDevID)
						local status = var.Get("WindowsMessage") == "Closed" and 1 or 0
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["R"] = { typ = "R", df = "D_BinaryLight1", name = "Sunroof Closed", devID = nil, st_ac0 = "ventSunroof", st_ac1 = "closeSunroof",
					pVal = function()
						return var.GetBoolean("SunroofStatus") and 0 or 1
					end,
					sf = function(chDevID)
						local status = var.GetBoolean("SunroofStatus") and 0 or 1
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["T"] = { typ = "T", df = "D_BinaryLight1", name = "Trunk Closed", devID = nil, st_ac0 = "unlockTrunc", st_ac1 = "lockTrunc", 
					pVal = function()
						return var.GetBoolean("TrunkStatus") and 0 or 1
					end,
					sf = function(chDevID)
						local status = var.GetBoolean("TrunkStatus") and 0 or 1
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["F"] = { typ = "F", df = "D_BinaryLight1", name = "Frunk Closed", devID = nil, st_ac0 = "unlockFrunc",
					pVal = function()
						return var.GetBoolean("FrunkStatus") and 0 or 1
					end,
					sf = function(chDevID)
						local status = var.GetBoolean("FrunkStatus") and 0 or 1
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["P"] = { typ = "P", df = "D_BinaryLight1", name = "Charge Port Closed", devID = nil, st_ac1 = "closeChargePort", st_ac0 = "openChargePort", 
					pVal = function()
						return var.GetBoolean("ChargePortDoorOpen") and 0 or 1
					end,
					sf = function(chDevID)
						local status = var.GetBoolean("ChargePortDoorOpen") and 0 or 1
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["C"] = { typ = "C", df = "D_DimmableLight1", name = "Charging", devID = nil, st_ac0 = "stopCharge", st_ac1 = "startCharge", 
					pVal = function()
						return var.GetBoolean("ChargeStatus") and 1 or 0
					end,
					sll_af = function(chDevID, newLoadlevelTarget)
						-- Set SOC level to new target, but must be between 50 and 100%
						local soc = tonumber(newLoadlevelTarget)
						if soc < 50 then soc = 50 end
						if soc > 100 then soc = 100 end
						local res, cde, data, msg = CarModule.StartAction("setChargeLimit", soc)
						if res then
							var.Set("LoadLevelStatus", soc, SIDS.DIM, chDevID)
							var.Set("LoadLevelTarget", soc, SIDS.DIM, chDevID)
						else
							log.Warning("Charge level SOC command %s failed. Error #%d, %s", cmd, cde, msg)
						end
					end,
					sf = function(chDevID)
						local status = var.GetBoolean("ChargeStatus") and 1 or 0
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
						local soc = var.GetNumber("ChargeLimitSOC")
						var.Set("LoadLevelStatus", soc, SIDS.DIM, chDevID)
						var.Set("LoadLevelTarget", soc, SIDS.DIM, chDevID)
						var.Set("BatteryLevel", var.Get("BatteryLevel", SIDS.HA), SIDS.HA, chDevID)
					end
			},
	["S"] = { typ = "P", df = "D_BinaryLight1", name = "Sentry Mode", devID = nil, st_ac1 = "startSentryMode", st_ac0 = "stopSentryMode", 
					pVal = function()
						return var.GetBoolean("SentryMode") and 1 or 0
					end,
					sf = function(chDevID)
						local status = var.GetBoolean("SentryMode") and 1 or 0
						var.Set("Status", status, SIDS.SP, chDevID)
						var.Set("Target", status, SIDS.SP, chDevID)
					end 
			},
	["I"] = { typ = "I", df = "D_TemperatureSensor1", name = "Inside temp", devID = nil, sid = SIDS.TEMP, var = "CurrentTemperature", 
					pVal = function()
						return var.GetNumber("InsideTemp")
					end },
	["O"] = { typ = "O", df = "D_TemperatureSensor1", name = "Outside temp", devID = nil, sid = SIDS.TEMP, var = "CurrentTemperature", 
					pVal = function()
						return var.GetNumber("OutsideTemp")
					end }
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
	SENTRY = 11,
	BUSY = 12,
	UNCONFIGURED = -1
}

-- API getting and setting variables and attributes from Vera more efficient and with parameter type checks.
local function varAPI()
	local def_sid, def_dev = "", 0
	
	local function _init(sid,dev)
		def_sid = sid
		def_dev = dev
	end
	
	-- Get variable value
	local function _get(name, sid, device)
		if type(name) ~= "string" then
			luup.log("var.Get: variable name not a string.", 1)
			return false
		end	
		local value, ts = luup.variable_get(sid or def_sid, name, tonumber(device or def_dev))
		return (value or "")
	end

	-- Get variable value as string type
	local function _get_string(name, sid, device)
		local value = _get(name, sid, device)
		if type(value) ~= "string" then
			luup.log("var.GetString: wrong data type :"..type(value).." for variable "..(name or "unknown"), 2)
			return false
		end
		return value
	end
	
	-- Get variable value as number type
	local function _get_num(name, sid, device)
		local value = _get(name, sid, device)
		local num = tonumber(value,10)
		if type(num) ~= "number" then
			luup.log("var.GetNumber: wrong data type :"..type(value).." for variable "..(name or "unknown"), 2)
			return false
		end
		return num
	end
	
	-- Get variable value as boolean type. Convert 0/1 to true/false
	local function _get_bool(name, sid, device)
		local value = _get(name, sid, device)
		if value ~= "0" and value ~= "1" then
			luup.log("var.GetBoolean: wrong data value :"..(value or "").." for variable "..(name or "unknown"), 2)
			return false
		end
		return (value == "1")
	end

	-- Get variable value as JSON type. Return decoded result
	local function _get_json(name, sid, device)
		local value = _get(name, sid, device)
		if value == "" then
			luup.log("var.GetJson: empty data value for variable "..(name or "unknown"), 2)
			return {}
		end
		local res, msg = json.decode(value)
		if res then 
			return res
		else
			luup.log("var.GetJson: failed to decode json ("..(value or "")..") for variable "..(name or "unknown"), 2)
			return {}
		end
	end

	-- Set variable value
	local function _set(name, value, sid, device)
		if type(name) ~= "string" then
			luup.log("var.Set: variable name not a string.", 1)
			return false
		end	
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local old, ts = luup.variable_get(sid, name, device) or ""
		if (tostring(value) ~= tostring(old)) then 
			luup.variable_set(sid, name, value, device)
		end
		return true
	end

	-- Set string variable value. If value type is not a string, do not set.
	local function _set_string(name, value, sid, device)
		if type(value) ~= "string" then
			luup.log("var.SetString: wrong data type :"..type(value).." for variable "..(name or "unknown"), 2)
			return false
		end
		return _set(name, value, sid, device)
	end

	-- Set number variable value. If value type is not a number, do not set.
	local function _set_num(name, value, sid, device)
		if type(value) ~= "number" then
			luup.log("var.SetNumber: wrong data type :"..type(value).." for variable "..(name or "unknown"), 2)
			return false
		end
		return _set(name, value, sid, device)
	end

	-- Set boolean variable value. If value is not o/1 or true/false, do not set.
	local function _set_bool(name, value, sid, device)
		if type(value) == "number" then
			if value == 1 or value == 0 then
				return _set(name, value, sid, device)
			else	
				luup.log("var.SetBoolean: wrong value. Expect 0/1.", 2)
				return false
			end
		elseif type(value) == "boolean" then
			return _set(name, (value and 1 or 0), sid, device)
		end
		luup.log("var.SetBoolean: wrong data type :"..type(value).." for variable "..(name or "unknown"), 2)
		return false
	end

	-- Set json variable value. If value is not array, do not set.
	local function _set_json(name, value, sid, device)
		if type(value) ~= "table" then
			luup.log("var.SetJson: wrong data type ("..type(value)..") for variable "..(name or "unknown"), 2)
			return false
		end
		local jsd = json.encode(value) or "{}"
		return _set(name, jsd, sid, device)
	end

	-- create missing variable with default value or return existing
	local function _default(name, default, sid, device)
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local value, ts = luup.variable_get(sid, name, device) 
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
		Set = _set,
		SetString = _set_string,
		SetNumber = _set_num,
		SetBoolean = _set_bool,
		SetJson = _set_json,
		Get = _get,
		GetString = _get_string,
		GetNumber = _get_num,
		GetBoolean = _get_bool,
		GetJson = _get_json,
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
local log_file = nil
local lvl_pfx = { [10] = "_debug", [8] = "_info", [2] = "_warning", [1] = "_error" }

	local function _update(level)
		if type(level) ~= "number" then level = def_level end
		if level >= 100 then
			def_file = (log_file ~= nil)
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

	local function _init(prefix, level, onol, lf)
		def_prefix = prefix
		onOpenLuup = onol
		log_file = lf
		_update(level)
	end	
	
	-- Build loggin string safely up to given lenght. If only one string given, then do not format because of length limitations.
	local function prot_format(lvl,ln,str,...)
		local msg = ""
		local sf = string.format
		if arg[1] then 
			_, msg = pcall(sf, str, unpack(arg))
		else 
			msg = str or "no text"
		end 
		if ln > 0 then
			msg = msg:sub(1,ln)
		end
		local pl = math.min(10, lvl)
		msg = def_prefix .. (lvl_pfx[pl] or "") .. ": " .. msg
		-- Write to Vera Log
		luup.log(msg, lvl) 
		-- Write to plugin log
		if def_file then
			local fh = io.open(log_file,"a")
			fh:write(os.date("%d/%m/%Y %X") .. "   " .. msg)
			fh:write("\n")
			fh:close()
		end
	end	
	local function _log(...) 
		if (def_level >= 10) then prot_format(50, max_length,...) end	
	end	
	
	local function _info(...) 
		if (def_level >= 8) then prot_format(8, max_length,...) end	
	end	

	local function _warning(...) 
		if (def_level >= 2) then prot_format(2, max_length,...) end	
	end	

	local function _error(...) 
		if (def_level >= 1) then prot_format(1, max_length,...) end	
	end	

	local function _debug(...)
		if def_debug then prot_format(50, -1,...) end	
	end
	
	local function _devmessage(devID, status, timeout, ...)
		local function pf(ln,str,...)
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
		local message = pf(60,...) or ""
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
		DeviceMessage = _devmessage
	}
end 

-- API to handle some Util functions
-- API to handle some Util functions
local function utilsAPI()
local _UI5 = 5
local _UI6 = 6
local _UI7 = 7
local _UI8 = 8
local _OpenLuup = 99
local charTable = {}

local  table_insert, table_concat, format, byte, char, string_rep, sub, gsub, ceil, floor =
   table.insert, table.concat, string.format, string.byte, string.char, string.rep, string.sub, string.gsub, math.ceil, math.floor

	local function _init()
		local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

		-- for urandom
		for c in chars:gmatch"." do
			table_insert(charTable, c)
		end

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
	
	-- Round up or down to specified decimals.
	local function _round(value, decimals)
		local power = 10^decimals
		return (value >= 0) and
				(floor(value * power) / power) or
				(ceil(value * power) / power)
	end

	local function _split(source, deli)
		local del = deli or ","
		local elements = {}
		local pattern = '([^'..del..']+)'
		gsub(source, pattern, function(value) elements[#elements + 1] = value end)
		return elements
	end
	
	local function _ctof(temp)
		return _round(temp * 9/5 + 32,0)
	end	
  
	local function _ftoc(temp)
		return _round((temp - 32) * 5 / 9,1)
	end	

	local function _join(tab, deli)
		local del = deli or ","
		return table_concat(tab, del)
	end

	-- Generate a (semi) random string
	local function _urandom(length)
		local random = math.random
		local randomString = {}

		for i = 1, length do
			randomString[i] = charTable[random(1, #charTable)]
		end
		return table_concat(randomString)
	end
	
	-- remove training chars
	local function _rstrip(str, chr)
		if sub(str,-1) == chr then 
			return _rstrip(sub(str, 1, -2),chr)
		else
			return str
		end
	end

	-- URL safe encode
	local function _uuencode(url)
		if not url then return nil end
		local char_to_hex = function(c)
			if c ~= "." and c ~= "_" and c ~= "-" then
				return format("%%%02X", c:byte());
			else
				return c;
			end
		end
		url = url:gsub("([^%w ])", char_to_hex)
		url = url:gsub(" ", "+")
		return url
	end

	return {
		Initialize = _init,
		ReloadLuup = _luup_reload,
		Round = _round,
		CtoF = _ctof,
		FtoC = _ftoc,
		GetMemoryUsed = _getmemoryused,
		SetLuupFailure = _setluupfailure,
		Split = _split,
		Join = _join,
		GetUI = _getui,
		IsUI5 = _UI5,
		IsUI6 = _UI6,
		IsUI7 = _UI7,
		IsUI8 = _UI8,
		IsOpenLuup = _OpenLuup,
		urandom = _urandom,
		rstrip = _rstrip,
		uuencode = _uuencode
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

-- Just get first item of queue, do not remove it.
function Queue.peak(list)
	local first = list.first
	if first > list.last then return nil end
	local value = list[first]
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
local unpack, table_insert, table_concat, byte, char, string_rep, sub, gsub, match, gmatch, len, ceil, floor, math_min, math_max, slower =
   table.unpack or unpack, table.insert, table.concat, string.byte, string.char, string.rep, string.sub, string.gsub, string.match, string.gmatch, string.len, math.ceil, math.floor, math.min, math.max, string.lower

	-- Map commands to details
	local commands = {
		["listCars"]				= { method = "GET" },
		
		["wakeUp"]					= { method = "POST", url ="wake_up" },
		["getVehicleDetails"]		= { method = "GET", url ="vehicle_data" },
		["getServiceData"]			= { method = "GET", url ="service_data" },
		["getChargeState"]			= { method = "GET", url ="data_request/charge_state" },
		["getClimateState"]			= { method = "GET", url ="data_request/climate_state" },
		["getDriveState"]			= { method = "GET", url ="data_request/drive_state" },
		["getMobileEnabled"]		= { method = "GET", url ="mobile_enabled" },
		["getGuiSettings"]			= { method = "GET", url ="data_request/gui_settings" },
		["startCharge"]				= { method = "POST", url ="command/charge_start" },
		["stopCharge"]				= { method = "POST", url ="command/charge_stop" },
		["startClimate"]			= { method = "POST", url ="command/auto_conditioning_start" },
		["stopClimate"]				= { method = "POST", url ="command/auto_conditioning_stop" },
		["startSentryMode"]			= { method = "POST", url ="command/set_sentry_mode", data = function(p) return {on=true} end },
		["stopSentryMode"]			= { method = "POST", url ="command/set_sentry_mode", data = function(p) return {on=false} end },
		["unlockDoors"]				= { method = "POST", url ="command/door_unlock" },
		["lockDoors"]				= { method = "POST", url ="command/door_lock" },
		["honkHorn"]				= { method = "POST", url ="command/honk_horn" },
		["flashLights"]				= { method = "POST", url ="command/flash_lights" },
		["unlockFrunc"]				= { method = "POST", url ="command/actuate_trunk", data = function(p) return {which_trunk="front"} end },
		["unlockTrunc"]				= { method = "POST", url ="command/actuate_trunk", data = function(p) return {which_trunk="rear"} end },
		["lockTrunc"]				= { method = "POST", url ="command/actuate_trunk", data = function(p) return {which_trunk="rear"} end },
		["openChargePort"]		 	= { method = "POST", url ="command/charge_port_door_open" },
		["closeChargePort"]		 	= { method = "POST", url ="command/charge_port_door_close" },
		["setTemperature"] 			= { method = "POST", url ="command/set_temps", data = function(p) return {driver_temp=p,passenger_temp=p} end },
		["setChargeLimit"] 			= { method = "POST", url ="command/set_charge_limit", data = function(p) return {percent=p} end },
		["setMaximumChargeLimit"] 	= { method = "POST", url ="command/charge_max_range" },
		["setStandardChargeLimit"]  = { method = "POST", url ="command/charge_standard" },
		["setScheduledCharging"]    = { method = "POST", url ="command/set_scheduled_charging", data = function(e,t) return {enable=e,time=t} end },
		["setScheduledDeparture"]   = { method = "POST", url ="command/set_scheduled_departure", data = function(e,pe,oe,pt,ot,dt,oe) return {enable=e, preconditioning_enabled=pe, off_peak_charging_enabled=oe,preconditioning_times=pt,off_peak_charging_times=ot,scheduled_departure_time=dt,off_peak_hours_end_time,op} end  },
		["ventSunroof"] 			= { method = "POST", url ="command/sun_roof_control", data = function(p) return {state="vent"} end },
		["closeSunroof"] 			= { method = "POST", url ="command/sun_roof_control", data = function(p) return {state="close"} end },
		["ventWindows"] 			= { method = "POST", url ="command/window_control", data = function(p) return {command="vent",lat=var.GetNumber("Latitude"),lon=var.GetNumber("Longitude")} end },
		["closeWindows"] 			= { method = "POST", url ="command/window_control", data = function(p) return {command="close",lat=var.GetNumber("Latitude"),lon=var.GetNumber("Longitude")} end },
		["updateSoftware"] 			= { method = "POST", url ="command/schedule_software_update", data = function(p) return {offset_sec=120} end }
	}

	-- Tesla API location details
	local base_host = "owner-api.teslamotors.com"
	local auth_host = "auth.tesla.com"
	local vehicle_url = nil
	local api_url = "/api/1/vehicles"
--	local ui_agent = "VeraTeslaCarApp/2.0"
	local ui_agent = "TeslaApp/3.10.9-433/adff2e065/android/10" -- V2.6
	local cookie_jar = {}

	-- Authentication data
	local auth_data = {
		["client_secret"] = "c7257eb71a564034f9419ee651c7d0e5f7aa6bfbd18bafb5c5c033b093bb2fa3",
		["client_id"] = "81527cff06843c8634fdc09e8ac0abefb46ac849f38fe1e431c2ef2106796384",
		["email"] = nil,
		["password"] = nil,
		["vin"] = nil,
		["access_token"] = nil,
		["refresh_token"] = nil,
		["expires_in"] = nil,
		["created_at"] = nil,
		["expires_at"] = nil
	}

	-- Header values to add to each HTTP request
	local base_request_headers = {
		["User-Agent"] = ui_agent,
		["Accept"] = "*/*",
		["Accept-Encoding"] = "deflate",
		["Connection"] = "keep-alive",
		["Content-Type"] = "application/json",
		["x-tesla-user-agent"] = ui_agent,
		["x-requested-with"] = "com.teslamotors.tesla"	
	}

	-- Vehicle details
	local last_wake_up_time = 0		-- Keep track of wake up so we can more efficiently query car.
	local wake_up_retry = 0			-- When not zero it is a retry wake up attempt.
	local command_retry = 0			-- When not zero it is a retry send attempt.
	local SendQueue = Queue.new()	-- Queue to hold commands to be handled.
	local callBacks = {}			-- To register command specific call back by client.

	local function url_encode(p_data)
		local result = {};
		if p_data[1] then -- Array of ordered { name, value }
			for _, field in ipairs(p_data) do
				table_insert(result, utils.uuencode(field[1]).."="..utils.uuencode(field[2]));
			end
		else -- Unordered map of name -> value
			for name, value in pairs(p_data) do
				table_insert(result, utils.uuencode(name).."="..utils.uuencode(value));
			end
		end
		return table_concat(result, "&");
	end

	-- Get all parameters from the URL, or just the one specified
	local function extract_url_parameters(url,key)
		local function urldecode(s)
			local sc = string.char
			s = s:gsub('+', ' '):gsub('%%(%x%x)', function(h)
				return sc(tonumber(h, 16))
				end)
		return s
		end
	
		local ans = {}
		for k,v in url:gmatch('([^&=?]-)=([^&=?]+)' ) do
			if key then
				if k == key then
					return urldecode(v)
				end
			else
				ans[ k ] = urldecode(v)
			end
		end
		if key then
			return ''
		else	
			return ans
		end	
	end

	-- We assume all host cookies apply to all urls (Path=/)
	-- Parse cookie-set and store cookie
	local function cookies_parse(host, cookies)
		if not cookie_jar[host] then cookie_jar[host] = {} end
		local cookie_tab = cookie_jar[host]
		local cookies = gsub(cookies, "Expires=(.-); ", "")
		for cookie in gmatch(cookies..',','(.-),') do
			local key,val,pth = match(cookie..";", '(.-)=(.-);.- [P|p]ath=(.-);')
			if not key then key,val,pth = match(cookie..";", '(.-)=(.-);.- [P|p]ath=(.-);') end
			if key then
				key = gsub(key," ","")
--				if pth == "/" then pth = "" end
				cookie_tab[key] = val
			end
		end
	end

	-- Build a cookie string for the given cookie keys/paths
	local function cookies_build(host)
		if not host then return nil end
		if not cookie_jar[host] then return nil end

		local cookie_tab = cookie_jar[host]
		local cookies = nil
		for kv, kp in pairs(cookie_tab) do
			if cookies then
				cookies = cookies.."; "..kv.."="..kp
			else
				cookies = kv.."="..kp
			end	
		end
		return cookies
	end

	-- Build a cookie string for the given cookie keys/paths
	local function cookies_clear(host)
		if not host then return nil end
		cookie_jar[host] = {}
	end

	-- Return a copy of the header with the additional values.
	local function copy_header(source_hdr, base)
		local hdr = base or {}
		for key, val in pairs(source_hdr) do
			hdr[key] = val
		end
		return hdr
	end

	-- HTTPs request wrapper with Tesla API required attributes
	local function _tesla_https_request(params)
		local cl = 0
		local result = {}
		local request_body = nil
		local host = params.host or base_host
		local url = "https://"..host..params.url
		
		-- Build heders from base and request.
		local headers = copy_header(base_request_headers)
		if params.headers then headers = copy_header(params.headers, headers) end
		headers["host"] = params.host
		
		if type(params.data) == "table" then
			-- Build request body
			if headers["Content-Type"] == "application/x-www-form-urlencoded" then
				request_body = url_encode(params.data)
			else
				-- Default is json
				request_body = json.encode(params.data)
			end
			cl = len(request_body)
		elseif type(params.data) == "string" then
			request_body = params.data
			cl = len(request_body)
		else	
		end 

		-- For LuaSec older than 0.8 use cURL
		local httpsVersion = string.sub(https._VERSION,1,3)	-- Handle versions like 1.0.1 as 1.0
		log.Debug("LuaSec version found %s",https._VERSION)
		if (tonumber(httpsVersion,10) < 0.8) and host==base_host then
			log.Debug("Old LuaSec version detected, using cURL for https request")
			local cmdStr = 'curl -s -X '..params.method
			-- Add headers
			for key, val in pairs(headers) do
				local lkey = slower(key)
				if key == "user-agent" then
					cmdStr = cmdStr .. ' -A "'..val..'"'
				elseif key == "connection" or key == "accept" or key == "accept-encoding" then
				else
					cmdStr = cmdStr .. ' -H "'..key..': '..val..'"'
				end
			end
			
			-- Add data
			if request_body then
				cmdStr = cmdStr .. " -d '"..request_body.."'"
			end
--log.Debug("cURL command %s %s",cmdStr,url)
			local handle=io.popen(cmdStr..' '..url )
			if handle then
				local response = handle:read('*a')
				handle:close()
--log.Debug("cURL command response %s", response)
				-- These are all json commands, check for expected response 
				if sub(response,1,1) == "{" then
					return true, 200, json.decode(response), "OK", nil
				else
					return true, 200, response, "OK", nil
				end
			else
				-- Bad request
				return false, 400, nil, "HTTP/1.1 400 BAD REQUEST !!", nil
			end
		else
			-- Add any cookies for the host.
			headers['Cookie'] = cookies_build(host) 
			if zlib then
				headers["Accept-Encoding"] = "gzip, deflate"
			else
				headers["Accept-Encoding"] = "deflate"
			end
			if params.params then
				-- Add parameters to URL
				url = url .. "?" .. url_encode(params.params)
			end
			headers["Content-Length"] = cl
		
--log.Debug("HttpsRequest method %s, url %s", params.method, url)		
			for key, val in pairs(headers) do
--log.Debug("Send header %s %s",key,val)
			end
			http.TIMEOUT = TCS_HTTP_TIMEOUT
			local bdy,cde,hdrs,stts = https.request{
				url = url, 
				method = params.method,
-- Have to force protocol on Vera.
				protocol = "tlsv1_2",
				options  = {"all", "no_sslv2", "no_sslv3"},
				verify   = "none",
 -- vera must end			
				sink = ltn12.sink.table(result),
				source = ltn12.source.string(request_body),
				redirect = false,
				headers = headers
			}
			if bdy == 1 then
				-- Capture any set-cookie header for next request
				local enc = "none"
				if hdrs then
					for key, val in pairs(hdrs) do
--log.Debug("Received header %s %s",key,val)
						if key == "set-cookie" then
							cookies_parse(host, val)
						end
					end
					enc = hdrs["content-encoding"] or "none"
				end
				if type(result) == 'table' then result = table.concat(result) end
				if zlib and string.find(enc, "gzip") then
					result = zlib.inflate()(result)
				end	
--log.Debug("Body :"..result)
				if cde == 200 then
					if hdrs["content-type"] == "application/json" or hdrs["content-type"] == "application/json; charset=utf-8" then
						return true, cde, json.decode(result), "OK", hdrs
					else
						return true, cde, result, "OK", hdrs
					end
				else
					return true, cde, result, stts, hdrs
				end
			else
				-- Bad request
				return false, 400, nil, "HTTP/1.1 400 BAD REQUEST !!", nil
			end
		end
	end	
	
	-- Store and retrieve credentials from perm storage if available
	local function _retrieve_credentials()
		if auth_data.token_storage_handler then
			local cred = auth_data.token_storage_handler("GET")
			if cred then
				auth_data.access_token = cred.access_token
				auth_data.refresh_token = cred.refresh_token
				auth_data.token_type = cred.token_type
				auth_data.expires_at = cred.expires_at
			end
		end
	end
	local function _store_credentials()
		if auth_data.token_storage_handler then
			auth_data.token_storage_handler("SET", auth_data)
		end
	end

	local function  _authenticate (force)
		if (not force) and auth_data.access_token and auth_data.expires_at and auth_data.expires_at > os.time() then
			log.Debug("Tokens valid. No need to authenticate.")
			return true, 200, nil, "OK"
		end
		-- Need to logon to obtain tokens
		cookies_clear(auth_host)
		-- See if we have a refresh token, so use that.
		if (not force) and auth_data.refresh_token then
			-- We have a refresh token, so use that.
			log.Debug("Refesh Token availble to reauthenticate.")
			data = {
				grant_type = "refresh_token",
				client_id = "ownerapi",
				refresh_token = auth_data.refresh_token,
				scope = "openid email offline_access"
			}
			-- Clear current values
			auth_data.access_token = nil
			auth_data.refresh_token = nil
			auth_data.expires_at = os.time() - 3600
			local res, cde, body, msg, hdrs = _tesla_https_request({method="POST", host=auth_host, url="/oauth2/v3/token", data=data})
			if cde ~= 200 then return false, cde, nil, 'Incorrect response code ' .. cde .. ' expect 200' end
			-- Succeed, set token details
			auth_data.refresh_token = body.refresh_token
			auth_data.access_token = body.access_token
			auth_data.token_type = body.token_type
			auth_data.expires_at = os.time() + body.expires_in - 10
			-- Save credentials to perm storage
			_store_credentials()
			return res, cde, nil, msg
		else
			-- Full authenticate is needed.
			log.Debug("Full authentication user UID/PWD required.")
			-- Clear current values
			auth_data.access_token = nil
			auth_data.refresh_token = nil
			auth_data.expires_at = os.time() - 3600
			
			-- Generate new logon request codes. Works with any challange code for now.
			local code_verifier = utils.urandom(86)
--			local code_challenge = utils.rstrip(mime.b64(utils.sha256(code_verifier)), "=")
			local code_challenge = utils.urandom(86)
			local state = utils.urandom(12)
		
			-- Get landing page
			local params = {
				{"client_id", "ownerapi"},
				{"code_challenge", code_challenge},
				{"code_challenge_method", "S256"},
				{"redirect_uri", "https://" .. auth_host .. "/void/callback"},
				{"response_type", "code"},
				{"scope", "openid email offline_access"},
				{"login_hint", auth_data.email},	-- V2.7
				{"state", state}
			}
			local res, cde, body, msg, hdrs = _tesla_https_request({method="GET", host=auth_host, url="/oauth2/v3/authorize", params=params})
			-- Request does not always return the page we need. p3p header looks like good indicator.
			if cde ~= 200 or hdrs["p3p"] then return false, cde, nil, msg end
			-- Collect known hidden input fields from form.
			local inputs = {}
			local form = match(body,'<form method="post" id="form" class="sso%-form sign%-in%-form">(.+)</form>')
--			if not form then  form = match(body,'<form method="post" id="form">(.+)</form>') end
			for str in gmatch(form,'<input type="hidden" name=(.-) />') do
				local key, val = match(str, '"(.-)" value="(.+)"')
				if key and val then
					if val:sub(1,1) == '"' then val = "" end
					inputs[key] = val
				end	
			end
			log.Debug('_csrf from landing page : %s', inputs._csrf)
			log.Debug('_phase from landing page : %s', inputs._phase)
			log.Debug('transaction_id from landing page : %s', inputs.transaction_id)

			-- Do logon
			local headers = {
				["Content-Type"] = "application/x-www-form-urlencoded"
			}
			local data = {
				{"identity", auth_data.email},
				{"credential", auth_data.password}
			}
			-- Add hidden form inputs from landing page
			for key, val in pairs(inputs) do
				table_insert(data, {key, val})
			end
			local res, cde, body, msg, hdrs = _tesla_https_request({method="POST", host=auth_host, url="/oauth2/v3/authorize", data=data, params=params, headers=headers})
			if cde == 200 then
				-- See if Multi Factor is on. Not supporting for now.
				if match(body, "/mfa/verify") then
					return false, cde, nil, "Multi Factor Authentication is not supported."
				else
					return false, cde, nil, "Retry"
				end
			end	
			if cde == 302 or hdrs["location"] then 
				local loc_code = extract_url_parameters(hdrs["location"],"code")
				if not loc_code or loc_code == "" then return false, cde, nil, 'No loc_code found' end
				log.Debug("location code : %s" , loc_code)			

				-- Get OAuth tokens
				data = {
					grant_type = "authorization_code",
					client_id = "ownerapi",
					code_verifier = code_verifier,
					code = {loc_code},
					redirect_uri = "https://auth.tesla.com/void/callback"
				}
				local res, cde, body, msg, hdrs = _tesla_https_request({method="POST", host=auth_host, url="/oauth2/v3/token", data=data})
				if cde ~= 200 then return false, cde, nil, msg end
				-- Succeed, set token details
				auth_data.refresh_token = body.refresh_token
				auth_data.access_token = body.access_token
				auth_data.token_type = body.token_type
				auth_data.expires_at = os.time() + body.expires_in - 10
				-- Save credentials to perm storage
				_store_credentials()
				return res, cde, nil, msg
			else
				return false, cde, nil, msg
			end
		end
--[[ not getting here anymore. Step obsolete as of 21 March 2022
		-- Get API tokens.
		local headers = { ["Authorization"] = auth_data.token_type.." "..auth_data.access_token }
		data = {
			grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
			client_id = auth_data.client_id,
			client_secret = auth_data.client_secret
		}
		auth_data.access_token = nil
		auth_data.expires_at = os.time() - 3600
		local res, cde, body, msg, hdrs = _tesla_https_request({method="POST", host=base_host, url="/oauth/token", data=data, headers=headers})
		if cde ~= 200 then return false, cde, nil, 'Incorrect response code ' .. cde .. ' expect 200' end
		if body.token_type then
			auth_data.access_token = body.access_token
			auth_data.token_type = body.token_type
			auth_data.expires_at = body.created_at + body.expires_in - 86400  -- 1 day margin in 45 days token expiration
			-- Save credentials to perm storage
			_store_credentials()
			return res, cde, nil, msg
		else
			return false, cde, nil, 'Incorrect token response: '..(body.response or "non-JSON reply")
		end
		]]
--
	end
	
	-- Send a command to the API.
	local function _send_command(command, param)	
		local cmd = commands[command]
		if cmd then 
			-- See if we are logged in and/or need to refresh the token
			local res, cde, data, msg = _authenticate()
			if not res then
				return false, cde, nil, "Unable to authenticate"
			end
			log.Debug("SendCommand, sending command %s.", command)
			-- Build correct URL to use
			local url = nil
			if cmd.url then
				if vehicle_url then
					url = vehicle_url..cmd.url
				else
					return false, 412, nil, "No vehicle select. Call GetVehicle first."
				end
			else
				-- Only used for listCars command.
				url = api_url
			end
			local headers = {
				["authorization"] = auth_data.token_type.." "..auth_data.access_token
			}
			local cmd_data = nil
			if cmd.data then cmd_data = cmd.data(param) end
			return _tesla_https_request({method=cmd.method, url=url, data=cmd_data, headers=headers})
		else
			log.Error("SendCommand, got unimplemented command %s.", command)
			return false, 501, nil, "Unimplemented command : "..(command or "?")
		end
	end
	
	-- Get the right vehicle details to use in the API requests. If vin is set, find vehicle with that vin, else use first in list
	-- In rare cases I noticed this command returned a 404 or empty list while there are car on the account. Not handling that exception for now.
	-- We rebuild vehicle_url each call are there are reports it can change over time.
	local function _get_vehicle()
		local vin = auth_data.vin
		local res, cde, data, msg = _send_command("listCars")
		if res then
			if data.count then
log.Debug("GetVehicle got %d cars.", data.count)				
				if data.count > 0 then
					local idx = 1
					if data.count > 1 then
						-- See if we can find specific vin to support multiple vehicles.
						if vin and vin ~= "" then
							for i = 1, data.count do
								if data.response[i].vin == vin then
									idx = i
									break
								end	
							end
						end
					end
					local resp = data.response[idx]
log.Debug("will use car #%d, %s",idx, json.encode(resp))						
					-- Set the corect URL for vehicle requests
					vehicle_url = api_url .. "/" .. resp.id_s .. "/"
log.Debug("Car URL to use %s.",vehicle_url)						
					return true, cde, resp, msg
				else
					return false, 404, nil, "No vehicles found."
				end
			else
				return false, 428, nil, "Vehicle in deep sleep."
			end
		else
			return false, cde, nil, msg
		end
	end

	-- Get the vehicle awake status. Should be only command faster than 4 times per hour keeping car asleep.
	local function _get_vehicle_awake_status()
		-- Only poll car if last confirmed awake is more than 50 seconds ago.
		if (os.difftime(os.time(), last_wake_up_time) > 50) then
			local awake = false
			local res, cde, data, msg = _get_vehicle()
			if res then
				-- Return true if online.
				awake = data.state=="online"
				if awake then last_wake_up_time = os.time()	end
			end
			return res, cde, awake, msg
		else	
			return true, 200, true, "OK"
		end
	end

	-- Get the vehicle vin numbers on the account
	local function _get_vehicle_vins()
		-- Check if we are authenticated
		if auth_data.access_token then
			local vins = {}
			local res, cde, data, msg = _send_command("listCars")
			if res then
				if data.count then
					if data.count > 0 then
						for i = 1, data.count do
							table_insert(vins, data.response[i].vin)
						end
						return true, cde, vins, msg
					else
						return false, 404, nil, "No vehicles found."
					end
				else
					return false, 428, nil, "Vehicle in deep sleep."
				end
			else
				return false, cde, nil, msg
			end
		else
			return false, 401, nil, "Not authenticated."
		end
	end
	
	-- Close session.
	local function _logoff()
		-- Check if we are authenticated
		if auth_data.access_token then
			local headers = {
				["authorization"] = auth_data.token_type.." "..auth_data.access_token
			}
			local res, cde, data, msg = _tesla_https_request({method="POST", url="/oauth/revoke", data={ token = auth_data.access_token }, headers=headers})
			if res then
				auth_data.expires_at = nil
				auth_data.access_token = nil
			end
			return res, cde, nil, msg
		else
			return false, 401, nil, "Not authenticated."
		end
	end

	-- Call back for send commands async
	-- Caller can add callbacks for commands that will be called on success and failure, but not on retry.
	local function _send_callback(cmd, res, cde, data, msg)
		-- Handle wake up see if car did wake up or not.
		local command = cmd.cmd
		local func = callBacks[command] or callBacks["other"]
		if func then
			-- Call the registered handler
			local stat, res = pcall(func, cmd, res, cde, data, msg)
			if not stat then
				log.Error("Error in call back for command %s, msg %s", command, res)
			end
		else
			-- No call back
			log.Debug("No call back for command %s.", command)
		end	
	end

	-- Put a new command on the send queue and initiate send process.
	-- Call results are handled async.
	local function _send_command_async(command, param)
		local qlen = Queue.len(SendQueue)
		log.Debug("SendCommand, command %s pushed on send queue. Queue depth %d", command, qlen)
		Queue.push(SendQueue, {cmd = command, param = param})
		if wake_up_retry == 0 then
			if qlen == 0 then
				-- First command put on send queue, initiate send process. 
				-- See if car is awake
				local res, cde, awake, msg = _get_vehicle_awake_status()
				if awake then
					-- It's awake, send the command(s) from the queue
					log.Debug("Car is awake. Send command in %d sec.", TCS_SEND_INTERVAL)
					command_retry = 0
					luup.call_delay("TSC_send_queued", TCS_SEND_INTERVAL)
				else
					-- Send wake up command and wait for car to wake up.
					_send_command("wakeUp")
					wake_up_retry = 1
					luup.call_delay("TSC_wakeup_vehicle", TCS_WAKEUP_CHECK_INTERVAL)
				end
			else
				-- Commands on queue. Let that run its course.
				log.Debug("Already processing queued commands")
			end
		else
			-- We are trying to wake up car. Let that run its course.
			log.Debug("Already trying to wake up car. Retry count %d.", wake_up_retry)
		end	
		return true, 200, nil, "OK"
	end

	-- Wait until vehicle is awake, then re-send the queued command
	-- If wake up fails we empty the whole queue, to avoid dead lock. It is up to calling app to start over at later point.
	local function TSC_wakeup_vehicle()
		log.Debug("TSC_wakeup_vehicle: Retry count %d. ", wake_up_retry)
		local awake = false
		-- See if awake by now.
		local res, cde, data, msg = _send_command("wakeUp")
		if res then
			local resp = data.response
			if resp then
				awake = resp.state=="online"
			else
				log.Debug("Wake up send failed. No response data. Message %s", msg)
			end
		else
			-- Send failed.
			log.Debug("Wake up send failed. Error #%d, %s", cde, msg)
		end
		if awake then
			-- It's awake, start sending the command(s) from the queue
			log.Debug("Wake up loop %d woke up car. Start sending queued command(s).", wake_up_retry)
			luup.call_delay("TSC_send_queued", TCS_SEND_INTERVAL)
			wake_up_retry = 0
		else
			wake_up_retry = wake_up_retry + 1
			if wake_up_retry < TCS_MAX_WAKEUP_RETRIES then
				luup.call_delay("TSC_wakeup_vehicle", TCS_WAKEUP_CHECK_INTERVAL)
			else
				-- Wake up failed. Empty command queue.
				Queue.drop(SendQueue)
				log.Error("Unable to wake up car in set time.")
				_send_callback({cmd = "wakeUp", param = nil}, false, 408, nil, "Unable to wakeup car.")
				wake_up_retry = 0
			end	
		end
	end
	
	-- Send a queued command. We must make sure car is awake before doing this.
	-- On specific conditions we know the command needs to be resend, so do this.
	local function TSC_send_queued()
		if (Queue.len(SendQueue) > 0) then
			local need_retry = false
			local interval = TCS_SEND_INTERVAL
			log.Debug("TSC_send_queued: Sending command from Queue. Send queue length %d.", Queue.len(SendQueue))
			-- Look at command on top of the queue
			local pop_t = Queue.peak(SendQueue)
			local res, cde, data, msg = _send_command(pop_t.cmd, pop_t.param)
			if cde == 400 or cde == 408 or cde == 502 or cde == 504 then
				-- HTTP Error code indicates need to resend command
				need_retry = true
			else
				-- Older Model S can be slow to wake up.
				if cde == 200 then
					if data.response then
						if data.response.reason == "could_not_wake_buses" then
							need_retry = true
						end
					end
				end
			end
			-- If retry is needed, resend command
			if need_retry then
				if command_retry < TCS_MAX_RETRIES then
					command_retry = command_retry + 1
					interval = TCS_RETRY_DELAY
					log.Warning("TSC_send_queued: Doing retry #%d, command %s, cde #%d, msg: %s", command_retry, pop_t.cmd, (cde or 0), (msg or "??"))
				else
					-- Max retries exeeded. Drop command.
					log.Error("TSC_send_queued:Call back command %s failed after max retries #%d, msg: %s", pop_t.cmd, command_retry, (msg or "??"))
					Queue.pop(SendQueue)
					command_retry = 0
					_send_callback(pop_t, false, 400, nil, "Failed to send command: "..pop_t.cmd)
				end
			else
				-- No need to retry, send results to call back handler and remove command from queue.
				Queue.pop(SendQueue)
				_send_callback(pop_t, res, cde, data, msg)
				command_retry = 0
			end	
			-- If we have more on Q, send next with an interval.
			-- If call back did not remove the command from the queu, it will be resend.
			if (Queue.len(SendQueue) > 0) then
				log.Debug("SendCommandAsync, more commands to send. Queue length %d", Queue.len(SendQueue))
				luup.call_delay("TSC_send_queued", interval)
				return true, 200, nil, "More commands queued. Send next in " .. interval
			else	
				log.Debug("TSC_send_queued: No more commands on Queue.")
				return true, 200, nil, "No more commands to send."
			end	
		else	
			log.Debug("TSC_send_queued: Queue is empty.")
			return true, 200, nil, "All commands sent."
		end
	end
	
		-- Add a callback for a given command on top of internal handing
	local _register_callback = function(cmdtype, cbFunction)
		if (type(cbFunction) == 'function') then
			callBacks[cmdtype] = cbFunction 
			return true, 200, nil, "OK"
		end
		return nil, 501, nil, "Not a function"
	end

	-- Initialize API functions 
	local function _init(email, password, token_storage_handler, vin, vera_clnt)
		auth_data.email = email
		auth_data.password = password
		auth_data.vin = vin
		auth_data.token_storage_handler = token_storage_handler
		vera_client = vera_clnt or false
		_retrieve_credentials()
		
		-- Need to make these global for luup.call_delay use. 
		_G.TSC_send_queued = TSC_send_queued
		_G.TSC_wakeup_vehicle = TSC_wakeup_vehicle
	end

	-- See if more commands are queued
	local function _get_commands_queued()
		return (Queue.len(SendQueue) > 0)
	end
	
	return {
		Initialize = _init,
		Authenticate = _authenticate,
		Logoff = _logoff,
		GetVehicleVins = _get_vehicle_vins,
		GetVehicle = _get_vehicle,
		GetVehicleAwakeStatus = _get_vehicle_awake_status,
		RegisterCallBack = _register_callback,
		SendCommand = _send_command_async,
		GetCommandsQueued = _get_commands_queued
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
					msg = string.format("Range: %s %s", var.Get("BatteryRange"), units)
				end
			end
		end
		var.Set("DisplayLine2", msg, SIDS.ALTUI)
	end
	
	-- All range values are in miles per hour, convert to KM per hour if GUI is set to it.
	-- Trunkate to whole number.
	local _convert_range_miles_to_units = function(miles, typ)
		local miles = miles or 0
		local units
		if typ == "C" then
			units = var.Get("GuiChargeRateUnits")
		else
			units = var.Get("GuiDistanceUnits")
		end
		if units == "km/hr" then
			return math.floor(miles / 0.621371)
		else
			return math.floor(miles)
		end	
	end
	
	-- It looks like Tesla always reports temp in Celsius, so convert if Vera units are Fahrenheit
	local _convert_temp_units = function(temp)
		local temp = temp or -99
		if pD.veraTemperatureScale ~= "C" then
			return utils.CtoF(temp)
		else
			return temp
		end	
	end
	
	-- Hander to store and retrieve credentials
	local function _credentials_storage(action, cred)
		if action == "SET" then
			local crd = {}
			crd.access_token = cred.access_token
			crd.refresh_token = cred.refresh_token
			crd.token_type = cred.token_type
			crd.expires_at = cred.expires_at
			var.SetJson("Credentials", crd)
		elseif action == "GET" then
			return var.GetJson("Credentials")
		else
			log.Error("CredentialStore, unknowns action : $s.", action)
		end
	end

	-- Logoff, This will fore a new login
	local function _reset()
		readyToPoll = false
		TeslaCar.Logoff()
		_set_status_message()
		return true, 200, nil, "OK"
	end
	
	local function _login()
		-- Get login details
		local email = var.GetString("Email")
		local password = var.GetString("Password")
		-- If VIN is set look for car with that VIN, else first found is used.
		local vin = var.GetString("VIN")
		if email ~= "" and password ~= "" then
			TeslaCar.Initialize(email, password, _credentials_storage, vin, not pD.onOpenLuup)
			local res, cde, data, msg = TeslaCar.Authenticate(var.GetBoolean("ForcedLogon"))
			if res then
				var.SetNumber("LastLogin", os.time())
				var.SetBoolean("ForcedLogon", false)
				res, cde, data, msg = TeslaCar.GetVehicle()
				if res then
					readyToPoll = true
					if var.GetNumber("CarIsAwake") == 0 then
						var.Set("IconSet", ICONS.ASLEEP)
					else
						var.Set("IconSet", ICONS.IDLE)
					end
					return true, 200, data, msg
				else	
					log.Error("Unable to select vehicle. errorCode : %d, errorMessage : %s", cde, msg)
					return false, cde, nil, msg
				end
			else
				log.Error("Unable to login. errorCode : %d, errorMessage : %s", cde, msg)
				return false, cde, nil, "Login to TeslaCar Portal failed "..msg
			end
		else
			log.Warning("Configuration not complete, missing email and/or password")
			return false, 404, nil, "Plug-in setup not complete", "Missing email and/or password, please complete setup."
		end
	end
	
	local function _command(command)
		log.Debug("Sending command : %s", command)
		var.Set("IconSet", ICONS.BUSY)
		local res, cde, data, msg = TeslaCar.SendCommand(command, param)
		log.Log("Command result : Code ; %d, Response ; %s", cde, string.sub(msg,1,30))
		log.Debug(msg)	
		return res, cde, data, msg
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
					local val = tostring(chDev.pVal())
					log.Debug("parent type %s, value %s, to update %s", chDevTyp, val, chDev.var)
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
			if var.GetBoolean("PowerSupplyConnected") and var.GetBoolean("PowerPlugState") then
				var.Set("DisplayLine2", "Power cable connected, not charging.", SIDS.ALTUI)
				icon = ICONS.CONNECTED
			end
			var.Set("ChargeMessage", sf("Battery %s%%, range %s%s.", bl, br, units))
		end
		-- Set user messages and icons based on actual values
		if var.GetBoolean("ClimateStatus") then
			var.Set("ClimateMessage", "Climatizing On")
			var.Set("DisplayLine2", "Climatizing On.", SIDS.ALTUI)
			icon = ICONS.CLIMATE
		else
			local inst = var.Get("InsideTemp")
			local outt = var.Get("OutsideTemp")
--			local units = var.Get("GuiTempUnits")
			local units = pD.veraTemperatureScale
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
		if var.GetBoolean("FrunkStatus") then
			var.Set("FrunkMessage", "Unlocked.")
			var.Set("DisplayLine2", "Frunk is unlocked.", SIDS.ALTUI)
			icon = ICONS.FRUNK
		else	
			var.Set("FrunkMessage", "Locked")
		end
		if var.GetBoolean("TrunkStatus") then
			var.Set("TrunkMessage", "Unlocked.")
			var.Set("DisplayLine2", "Trunk is unlocked.", SIDS.ALTUI)
			icon = ICONS.TRUNK
		else	
			var.Set("TrunkMessage", "Locked")
		end
		if not var.GetBoolean("LockedStatus") then
			var.Set("LockedMessage", "Car is unlocked.")
			var.Set("DisplayLine2", "Car is unlocked.", SIDS.ALTUI)
			icon = ICONS.UNLOCKED
		else	
			var.Set("LockedMessage", "Locked")
		end
		if var.GetBoolean("MovingStatus") then
			var.Set("DisplayLine2", "Car is moving.", SIDS.ALTUI)
			icon = ICONS.MOVING
		else	
			-- var.Set("LockedMessage", "Locked")
		end
		if var.GetBoolean("SentryMode") then
			var.Set("DisplayLine2", "Sentry Mode is active.", SIDS.ALTUI)
			icon = ICONS.SENTRY
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
		return (icon or 0)
	end

	-- Process the values returned for drive state
	local function _update_gui_settings(settings)
		if settings then
			var.SetBoolean("Gui24HourClock", settings.gui_24_hour_time or false)
			var.SetString("GuiChargeRateUnits", settings.gui_charge_rate_units or "km/hr")
			var.SetString("GuiDistanceUnits", settings.gui_distance_units or "km/hr")
			var.SetString("GuiTempUnits", settings.gui_temperature_units or "C")
			var.SetString("GuiRangeDisplay", settings.gui_range_display or "")
			var.SetNumber("GuiSettingsTS", settings.timestamp or os.time())
			return true
		else
			log.Warning("Update: No vehicle settings found")
			return false, 404, nil, "No vehicle settings found"
		end
	end

	-- Process the values returned for vehicle config
	local function _update_vehicle_config(config)
		if config then
			var.SetString("CarType", config.car_type or "")
			var.SetBoolean("CarHasRearSeatHeaters", config.rear_seat_heaters or false)
			-- Sunroof value can be missing
			local has_sunroof = config.sun_roof_installed or 0
			var.SetBoolean("CarHasSunRoof", (has_sunroof > 0))
			var.SetBoolean("CarHasMotorizedChargePort", config.motorized_charge_port or false)
			var.SetBoolean("CarCanActuateTrunks", config.can_actuate_trunks or false)
			return true
		else
			log.Warning("Update: No vehicle configuration found")
			return false, 404, nil, "No vehicle configuration found"
		end
	end

	-- Process the values returned for drive state
	local function _update_drive_state(state)
		if state then
			-- Update location details
			local lat = (state.latitude or 0)
			local lng = (state.longitude or 0)
			var.SetNumber("Latitude", lat)
			var.SetNumber("Longitude", lng)
			-- Compare to home location and set/clear at home flag when within 500 m
			lat = tonumber(lat) or luup.latitude
			lng = tonumber(lng) or luup.longitude
			local radius = var.GetNumber("AtLocationRadius")
			var.SetBoolean("LocationHome", (_distance(lat, lng, luup.latitude, luup.longitude) < radius))
			var.SetNumber("LocationTS", state.gps_as_of)

			-- Update other drive details
			var.SetBoolean("MovingStatus", (state.shift_state and state.shift_state ~= "P") or false)
			var.SetNumber("DriveSpeed", state.speed or 0)
			var.SetNumber("DrivePower", state.power or 0)
			var.SetString("DriveShiftState", state.shift_state or "P")
			var.SetNumber("DriveStateTS", state.timestamp)
			return true
		else
			log.Warning("Update: No vehicle driving state found")
			return false, 404, nil, "No vehicle driving state found"
		end
	end

	-- Process the values returned for climate state
	local function _update_climate_state(state)
		if state then
			var.SetBoolean("BatteryHeaterStatus", state.battery_heater or false)
			var.SetBoolean("ClimateStatus", state.is_climate_on or false)
			var.SetNumber("InsideTemp", _convert_temp_units(state.inside_temp))
			var.SetNumber("MinInsideTemp", _convert_temp_units(state.min_avail_temp))
			var.SetNumber("MaxInsideTemp", _convert_temp_units(state.max_avail_temp))
			var.SetNumber("OutsideTemp",_convert_temp_units(state.outside_temp))
			var.SetNumber("ClimateTargetTemp", _convert_temp_units(state.driver_temp_setting))
			var.SetBoolean("FrontDefrosterStatus", state.is_front_defroster_on or false)
			var.SetBoolean("RearDefrosterStatus", state.is_rear_defroster_on or false)
			var.SetBoolean("PreconditioningStatus", state.is_preconditioning or false)
			var.SetNumber("FanStatus", state.fan_status or 0)
			var.SetNumber("SeatHeaterStatus", state.seat_heater_left or 0)
			var.SetBoolean("MirrorHeaterStatus", state.side_mirror_heaters or false)
			var.SetBoolean("SteeringWeelHeaterStatus", state.steering_wheel_heater or false)
			var.SetBoolean("WiperBladesHeaterStatus", state.wiper_blade_heater or false)
			var.SetBoolean("SmartPreconditioning", state.smart_preconditioning or false)
			var.SetNumber("ClimateStateTS", state.timestamp)
			return true
		else
			log.Warning("Update: No vehicle climate state found")
			return false, 404, nil, "No vehicle climate state found"
		end
	end

	-- Process the values returned for charge state
	local function _update_charge_state(state)
		if state then
			if state.charging_state == "Charging" and state.time_to_full_charge and state.time_to_full_charge > 0 then
				var.SetNumber("RemainingChargeTime", state.time_to_full_charge)
			else
				var.Set("RemainingChargeTime", 0)
			end
			var.SetNumber("BatteryRange", _convert_range_miles_to_units(state.battery_range, "D"))
			var.SetNumber("BatteryLevel", state.battery_level or 0, SIDS.HA)
			if state.conn_charge_cable then
				-- Is in api_version 7, but not before I think
				var.SetBoolean("PowerPlugState", (state.conn_charge_cable ~= "<invalid>"))
			else
				-- V6 and prior.
				var.SetBoolean("PowerPlugState", not (state.charging_state == "Disconnected" or state.charging_state == "NoPower"))
			end
			if state.charging_state then 
				if state.charging_state == "Charging" then
					var.SetBoolean("ChargeStatus", true) 
					var.SetBoolean("PowerSupplyConnected", true)
				elseif state.charging_state == "Complete" or state.charging_state == "Stopped" then
					var.SetBoolean("ChargeStatus", false) 
					var.SetBoolean("PowerSupplyConnected", true)
				elseif state.charging_state == "NoPower" or state.charging_state == "Disconnected" then
					var.SetBoolean("ChargeStatus", false) 
					var.SetBoolean("PowerSupplyConnected", false)
				else
					log.Warning("Car state; Unknown charging state : %s.", tostring(state.charging_state))
				end
			end
			var.SetBoolean("ChargePortLatched", (state.charge_port_latch == "Engaged"))
			var.SetBoolean("ChargePortDoorOpen", state.charge_port_door_open or false)
			var.SetBoolean("BatteryHeaterOn",state.battery_heater_on or false)
			var.SetNumber("ChargeRate",  _convert_range_miles_to_units(state.charge_rate or 0, "C"))
			var.SetNumber("ChargePower", state.charger_power or 0)
			var.SetNumber("ChargeLimitSOC", state.charge_limit_soc or 0)
			var.SetNumber("ChargeStateTS", state.timestamp)
			return true
		else
			log.Warning("Update: No vehicle charge state found")
			return false, 404, nil, "No vehicle charge state found"
		end
	end

	-- Process the values returned for vehicle state
	local function _update_vehicle_state(state)
		if state then
			var.SetNumber("CarApiVersion", state.api_version or 0)
			var.SetString("CarFirmwareVersion", state.car_version or "")
			var.SetNumber("CarCenterDisplayStatus", state.center_display_state or 0)
			var.SetBoolean("UserPresent", (state.is_user_present ~= 0) or false)
			var.SetNumber("Mileage",_convert_range_miles_to_units(state.odometer, "D"))
			var.SetBoolean("LockedStatus", state.locked or false)
			var.SetBoolean("FrunkStatus", (state.ft ~= 0) or false)
			var.SetBoolean("TrunkStatus", (state.rt ~= 0) or false)
			var.SetString("DoorsStatus",json.encode({df = state.df, pf = state.pf, dr = state.dr, pr = state.pr}))
			if state.fd_window then
				var.SetString("WindowsStatus", json.encode({df = state.fd_window, pf = state.fp_window, dr = state.rd_window, pr = state.rp_window}))
				var.SetBoolean("CarCanActuateWindows", true)
			else
				-- Seems model S does not report windows status, so assume closed.
				var.SetString("WindowsStatus", json.encode({df = 0, pf = 0, dr = 0, pr = 0}))
				var.SetBoolean("CarCanActuateWindows", false)
			end	
			if var.GetBoolean("CarHasSunRoof") then 
				var.SetBoolean("SunroofStatus",(state.sun_roof_percent_open ~= 0))
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
				var.SetString("AvailableSoftwareVersion", swu.version or "")
				var.SetNumber("SoftwareStatus", swStat or 0)
			end
			if state.sentry_mode_available then
				var.SetBoolean("SentryMode", state.sentry_mode)
			end
			return true
		else
			log.Warning("Update: No vehicle state found")
			return false, 404, nil, "No vehicle state found"
		end
	end

	-- Call backs for car request commands. Must be registered as handlers.
	local function CB_getVehicleDetails(cmd, res, cde, data, msg)
		log.Debug("Call back for command %s, message: %s", cmd.cmd, msg)
		local icon = ICONS.IDLE
		if cde == 200 then
			var.SetBoolean("CarIsAwake", true)  -- Car must be awake by now.
			if data.response then
				local resp = data.response
				if resp.id_s then
					-- successful reply on command
					-- update with latest vehicle
					-- Update car config data when Car name or VIN has changed
					local cur_name = var.GetString("CarName")
					local cur_vin = var.GetString("VIN")
					if cur_name ~= resp.display_name or cur_vin ~= resp.vin then
						var.SetString("CarName", resp.display_name)
						var.Set("DisplayLine1","Car : "..resp.display_name, SIDS.ALTUI)
						var.SetString("VIN", resp.vin)
						_update_vehicle_config(resp.vehicle_config)
					end	
					-- Process specific category states
					_update_gui_settings(resp.gui_settings)
					_update_vehicle_state(resp.vehicle_state)
					_update_drive_state(resp.drive_state)
					_update_climate_state(resp.climate_state)
					_update_charge_state(resp.charge_state)
					-- Update GUI messages and child devices
					icon = _update_message_texts()
					_update_child_devices()
					_set_status_message()
				else
					-- Some error in request, look at reason
					local res = resp.reason or "unknown"
					log.Error("Get vehicle details missing data. Reason %s.", res)
					_set_status_message("Get vehicle details missing data. Reason "..res)
				end
			else
				log.Error("Get vehicle details error. Empty response.")
			end
		else
			log.Error("Get vehicle details error. Reason #%d, %s.", cde, msg)
			_set_status_message("Get vehicle details error. Reason  "..msg)
		end
		if TeslaCar.GetCommandsQueued() then
			-- More commands in queue, so keep busy status.
			icon = ICONS.BUSY
		end
		var.Set("IconSet", icon)
	end
	
	local function CB_getServiceData(cmd, res, cde, data, msg)
		log.Debug("Call back for command %s, message: %s", cmd.cmd, msg)
		if cde == 200 then
			var.SetBoolean("CarIsAwake", true)  -- Car must be awake by now.
			local service_status = false
			local service_etc = ""
			if data.response then
				local resp = data.response
				if resp.service_status then
					service_status = (resp.service_status == "in_service")
					service_etc = resp.service_etc
				else
					-- Is normal response if not in service.
				end
			else
				log.Error("Get service data error. No response.")
			end
			var.SetBoolean("InServiceStatus", service_status)
			var.SetString("InServiceEtc", service_etc)
		else
			log.Error("Get service data error. Reason #%d, %s.", cde, msg)
			_set_status_message("Get service data error. Reason  "..msg)
		end
		if TeslaCar.GetCommandsQueued() then
			-- More commands in queue, so keep busy status.
			var.Set("IconSet", ICONS.BUSY)
		else
			var.Set("IconSet", ICONS.IDLE)
		end
	end

	local function CB_wakeUp(cmd, res, cde, data, msg)
		log.Debug("Call back for command %s, message: %s", cmd.cmd, msg)
		if cde == 200 then
			var.SetBoolean("CarIsAwake", true)  -- Car must be awake by now.
		else
			log.Error("Wake up error. Reason #%d, %s.", cde, msg)
			_set_status_message("Wake up error. Reason  "..msg)
		end
	end
	
	-- Call back if no command specific is registered.
	local function CB_other(cmd, res, cde, data, msg)
		log.Debug("Call back for command %s, message: %s", cmd.cmd, msg)
		if cde == 200 then
			var.SetBoolean("CarIsAwake", true)  -- Car must be awake by now.
			-- Schedule poll to update car status details change because of command.
			local delay = TCS_POLL_SUCCESS_DELAY
			-- For sent temp setpoint we take longer delay and typically user sends multiple. Should give better GUI response.
			if cmd.cmd == "setTemperature" then delay = delay * 2 end
			last_scheduled_poll = os.time() + delay
			log.Debug("Scheduling poll at %s", os.date("%X", last_scheduled_poll))
			luup.call_delay("TeslaCarModule_poll", delay)
		else
			log.Error("Command send error. Reason #%d, %s.", cde, msg)
			_set_status_message("Command send error. Reason  "..msg)
		end
		if TeslaCar.GetCommandsQueued() then
			-- More commands in queue, so keep busy status.
			var.Set("IconSet", ICONS.BUSY)
		else
			var.Set("IconSet", ICONS.IDLE)
		end
	end

	-- Request the latest status from the car
	local function _update_car_status(force)
		if not force then
			-- Only poll if car is awake
			if not var.GetBoolean("CarIsAwake") then
				var.Set("IconSet", ICONS.ASLEEP)
				log.Debug("CarModule.UpdateCarStatus, skipping, Tesla is asleep.")
				return false, 307, nil, "Car is asleep"
			end
		end
		-- Get status update from car.
		_set_status_message("Updating car status...")
		var.Set("IconSet", ICONS.BUSY)
		TeslaCar.SendCommand("getServiceData")
		return TeslaCar.SendCommand("getVehicleDetails")
	end	

	-- Send the requested command
	local function _start_action(request, param)
		log.Debug("Start Action enter for command %s, %s.", request, (param or ""))
		_set_status_message("Sending "..request)
		var.Set("IconSet", ICONS.BUSY)
		return TeslaCar.SendCommand(request, param)
	end	
	
	-- Trigger a forced update of the car status. Will wake up car.
	function _poll()
		log.Debug("Poll, start")
		local dt = os.time() - last_scheduled_poll
		if dt >= 0 then
			pcall(_update_car_status, true)
			last_scheduled_poll = 0
		else
			log.Info("Skipping Poll as a next is planned in %d sec.", math.abs(dt))
		end
	end

	-- Execute daily poll if scheduled
	local function __daily_poll(startup)
		local sg = string.gsub
		local force = false
		if startup == true then force = true end -- on Vera with luup.call_delay the paramter is never nil, but empty string "" is not specified.

		log.Debug("Daily Poll, enter")
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
	end
	
	-- Wrapper for daily poll loop.
	local function _daily_poll(startup)
		-- Schedule at next day if a time is configured
		local poll_time = var.Get("DailyPollTime")
		if poll_time ~= "" then
			log.Debug("Daily Poll, scheduling for %s.", poll_time)
			luup.call_timer("TeslaCarModule_daily_poll", 2, poll_time .. ":00", "1,2,3,4,5,6,7")
			local res, stat = pcall(__daily_poll, startup)
			if not res then
				log.Error("Daily Poll failed. Error %s.", stat)
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
	local function __scheduled_poll(startup)
		local sg = string.gsub
		log.Debug("Scheduled Poll, enter")
		if readyToPoll then
			local interval, awake = 0, false
			local force = false
			-- For V1.10 handling, force car name update at startup 
			if startup and var.Get("CarName") == "" then force = true end
			local lastPollInt = os.time() - var.GetNumber("LastCarMessageTimestamp")
			local prevAwake = var.GetBoolean("CarIsAwake")
			local swStat = var.GetNumber("SoftwareStatus")
			local lckStat = var.GetBoolean("LockedStatus")
			local clmStat = var.GetBoolean("ClimateStatus")
			local mvStat = var.GetBoolean("MovingStatus")
			local smStat = var.GetBoolean("SentryMode")
			local res, cde, data, msg = TeslaCar.GetVehicleAwakeStatus()
			if res then
				if data then
					awake = true
					if not prevAwake then
						last_woke_up_time = os.time()
						log.Debug("Monitor awake state, Car woke up")
					else
						log.Debug("Monitor awake state, Car is awake")
					end
				else
					last_woke_up_time = 0
					log.Debug("Monitor awake state, Car is asleep")
					var.SetNumber("IconSet", ICONS.ASLEEP)
				end	
				var.SetBoolean("CarIsAwake", awake)
			else	
				last_woke_up_time = 0
				log.Error("Monitor awake state, failed #%d %s", cde, msg)
			end
			-- PollSettings [2] = Poll interval if car is awake
			-- PollSettings [3] = Poll interval if charging and remaining charge time > 1 hour
			-- PollSettings [4] = Poll interval if charging and remaining charge time < 1 hour
			-- PollSettings [5] = Poll interval when car just woke up not by our action or activity occurs (Unlocked, Preheat, SW install)
			-- PollSettings [6] = Poll interval if car is moving
			local pol = var.Get("PollSettings")
			local pol_t = {}
			local last_wake_delta = os.time() - last_woke_up_time
			sg(pol..",","(.-),", function(c) pol_t[#pol_t+1] = c end)
			log.Debug("mvStat %s, awake %s, prevAwake %s, last woke int %d, swStat %s, lckStat %s, clmStat %s, smStat %s",tostring(mvStat), tostring(awake), tostring(prevAwake), last_wake_delta, tostring(swStat), tostring(lckStat), tostring(clmStat), tostring(smStat))
			if mvStat then
				interval = pol_t[6]
				force = true
			elseif (awake and (last_wake_delta < 200)) or swStat ~= 0 or (not lckStat) or clmStat or smStat then
				interval = pol_t[5]
				force = true
			elseif var.GetBoolean("ChargeStatus") then
				force = true
				if var.GetNumber("RemainingChargeTime") > 1 then
					interval = pol_t[3]
				else
					interval = pol_t[4]
				end
			elseif awake then
				interval = pol_t[2]
			end
			interval = interval * 60  -- Minutes to seconds
			if interval == 0 then interval = 15*60 end
			-- Force update to get get car config after install or update to V1.10
			if startup and var.Get("CarName") == "" then 
				interval = 10
				force = true 
			end
			log.Debug("Next Scheduled Poll in %s seconds, last poll %s seconds ago, forced is %s.", interval, lastPollInt, tostring(force))
			-- See if we passed poll interval.
			if interval <= lastPollInt and readyToPoll then
				-- Get latest status from car.
				_update_car_status(force)
			end
			-- If we have software ready to install and auto install is on, send command to install
			if swStat == 2 then
				if var.GetBoolean("AutoSoftwareInstall") then
					_start_action("updateSoftware")
				end
			end
		else
			log.Warning("Scheduled Poll, not yet ready to poll.")
		end
	end

	-- Wrapper for one minute poll loop
	local function _scheduled_poll(startup)
		-- Schedule fro next minute
		local int = var.GetNumber("MonitorAwakeInterval")
		if int < 60 then int = 60 end
		luup.call_delay("TeslaCarModule_scheduled_poll", int)
		local res, stat = pcall(__scheduled_poll, startup)
		if not res then
			log.Error("Scheduled Poll failed. Error %s.", stat)
		end
	end

	-- Initialize module
	local function _init()
	
		-- Create variables we will need from get-go
		local prv_ver = var.Get("Version")
		var.Set("Version", pD.Version)
		var.Default("Email")
		var.Default("Password") --store in attribute
		var.Default("IconSet",ICONS.UNCONFIGURED)
		var.Default("PollSettings", "1,20,15,5,1,5") --Daily Poll (1=Y,0=N), Interval for; Idle, Charging long, Charging Short, Active, Moving in minutes
		var.Default("DailyPollTime","7:30")
		var.Default("MonitorAwakeInterval",60) -- Interval to check is car is awake, in seconds
		var.Default("LastCarMessageTimestamp", 0)
		var.Default("LocationHome",0)
		-- Need to wipe car name for update to V1.10 config handling so fileds like car type are set.
		local car_type = var.Default("CarType")
		if car_type == "" and prv_ver ~= pD.Version then
			var.Set("CarName", "") 
		end
		var.Default("VIN")
		var.Default("ChargeStatus", 0)
		var.Default("ClimateStatus", 0)
		var.Default("ChargeMessage")
		var.Default("ClimateMessage")
		var.Default("WindowMeltMessage")
		var.Default("DoorsMessage", "Closed")
		var.Default("WindowsMessage", "Closed")
		var.Default("FrunkMessage", "Locked")
		var.Default("TrunkMessage", "Locked")
		var.Default("LockedMessage", "Locked")
		var.Default("SoftwareMessage")
		var.Default("LockedStatus", 1)
		var.Default("DoorsStatus", 0)
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
		var.Default("LastLogin", 0)
		var.Default("ForcedLogon", 1)
		var.Default("Credentials", "{}")
		var.Default("CarIsAwake", 0)
		var.Default("Gui24HourClock", 1)
		var.Default("GuiChargeRateUnits", "km/hr")
		var.Default("GuiDistanceUnits", "km/hr")
		var.Default("GuiTempUnits", "C")
		var.Default("GuiRangeDisplay")
		var.Default("GuiSettingsTS", 0)
		var.Default("CarApiVersion", 0)
		var.Default("CarFirmwareVersion")
		var.Default("CarCenterDisplayStatus", 0)
		var.Default("UserPresent", 0)
		var.Default("Latitude", 0)
		var.Default("Longitude", 0)
		var.Default("LocationTS", 0)
		var.Default("DriveSpeed", 0)
		var.Default("DrivePower", 0)
		var.Default("DriveShiftState", 0)
		var.Default("DriveStateTS", 0)
		var.Default("BatteryHeaterStatus", 0)
		var.Default("OutsideTemp", -99)
		var.Default("InsideTemp", -99)
		var.Default("MinInsideTemp", 15)
		var.Default("MaxInsideTemp", 28)
		var.Default("ClimateTargetTemp", 19)
		var.Default("FrontDefrosterStatus", 0)
		var.Default("RearDefrosterStatus", 0)
		var.Default("PreconditioningStatus", 0)
		var.Default("FanStatus", 0)
		var.Default("SeatHeaterStatus", 0)
		var.Default("MirrorHeaterStatus", 0)
		var.Default("SteeringWeelHeaterStatus", 0)
		var.Default("WiperBladesHeaterStatus", 0)
		var.Default("SmartPreconditioning", 0)
		var.Default("ClimateStateTS", 0)
		var.Default("RemainingChargeTime", 0)
		var.Default("BatteryRange", 0)
--		var.Default("BatteryLevel", 50)
		var.Default("PowerPlugState", 0)
		var.Default("ChargePortLatched", 0)
		var.Default("ChargePortDoorOpen", 0)
		var.Default("BatteryHeaterOn", 0)
		var.Default("SentryMode", 0)
		var.Default("ChargeRate", 0)
		var.Default("ChargePower", 0)
		var.Default("ChargeLimitSOC", 90)
		var.Default("AvailableSoftwareVersion")
		var.Default("InServiceStatus", 0)
		var.Default("CarHasRearSeatHeaters", 0)
		var.Default("CarHasSunRoof", 0)
		var.Default("CarHasMotorizedChargePort", 0)
		var.Default("CarCanActuateTrunks", 0)
		var.Default("CarCanActuateWindows", 0)
		
		_G.TeslaCarModule_poll = _poll
		_G.TeslaCarModule_daily_poll = _daily_poll
		_G.TeslaCarModule_scheduled_poll = _scheduled_poll
		
		-- Register call backs
		TeslaCar.RegisterCallBack("getVehicleDetails", CB_getVehicleDetails)
		TeslaCar.RegisterCallBack("getServiceData", CB_getServiceData)
		TeslaCar.RegisterCallBack("wakeUp", CB_wakeUp)
		TeslaCar.RegisterCallBack("other", CB_other)
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
		local newTV = tonumber(newTargetValue)
		local chDev = childDeviceMap[childIDMap[deviceID]]
		log.Debug("SetTarget Found child device %d, for type %s, name %s.", deviceID, chDev.typ, chDev.name)
		local curVal = chDev.pVal()
		if curVal ~= newTV then
			-- Find default car action for child SetTarget
			local ac = chDev.st_ac
			if not ac then
				ac = chDev["st_ac"..newTV]
			end
			if ac then
				local res, cde, data, msg = CarModule.StartAction(ac)
				if res then
					local sid = chDev.sid or SIDS.SP
					var.Set("Target", newTV, sid, deviceID)
					var.Set("Status", newTV, sid, deviceID)
				else
					log.Error("SetTarget action %s failed. Error #%d, %s", ac, cde, msg)
				end
			else
				log.Info("No action defined for child device.")
			end
			-- Update the parent variable, next poll should fall back if failed.
--			var.Set(chDev.pVar, newTV)
		else
			log.Debug("SetTarget, value not changed (old %s, new %s). Ignoring action.", curVal, newTV)
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
	local res, cde, data, msg = CarModule.Login()
	if res then
		CarModule.SetStatusMessage()
		-- Start pollers
		CarModule.DailyPoll(true)
		CarModule.ScheduledPoll(true)
	elseif cde == 404 then
		log.DeviceMessage(pD.DEV, 2, 0, pD.pwdMessage)
		-- UID and/or Pwd missing. Wait for setup complete.
		-- Start pollers
		CarModule.DailyPoll(true)
		CarModule.ScheduledPoll(true)
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
	pD.veraTemperatureScale = string.upper(luup.attr_get("TemperatureFormat",0)) or "C"
		
	-- start Utility API's
	log = logAPI()
	var = varAPI()
	utils = utilsAPI()
	var.Initialize(SIDS.MODULE, pD.DEV)
	local lv = var.Default("LogLevel", pD.LogLevel)
	log.Initialize(pD.Description, tonumber(lv), true, pD.LogFile)
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
	luup.call_delay("TeslaCar_DeferredInitialize", 10, "0")

	-- Set watches on email and password as userURL needs to be erased when changed
	luup.variable_watch("TeslaCar_VariableChanged", SIDS.MODULE, "Email", pD.DEV)
	luup.variable_watch("TeslaCar_VariableChanged", SIDS.MODULE, "Password", pD.DEV)

	log.Log("TeslaCarModule_Initialize finished ")
	utils.SetLuupFailure(0, pD.DEV)
	return true, "Plug-in started.", pD.Description
end
