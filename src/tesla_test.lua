-- tessla test code
local ltn12 	= require("ltn12")
local json 		= require("dkjson")
local https     = require("ssl.https")
local http		= require("socket.http")
local url 		= require("socket.url")
local socket 	= require("socket")

local USER = "rene.boer@intl.att.com"
local PWD = "65&\\e24Hd811P65]"


-- The API to contact the Tesla Vehicle 
-- First call Authenticate, then GetVehicle before sending commands
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
		["openSunroof"] 			= { method = "POST", url ="/command/sun_roof_control", data = function(p) return {state="open"} end },
		["closeSunroof"] 			= { method = "POST", url ="/command/sun_roof_control", data = function(p) return {state="close"} end },
		["setSunroof"] 				= { method = "POST", url ="/command/sun_roof_control", data = function(p) return {state="move",percent=p} end },
		["updateSoftware"] 			= { method = "POST", url ="/command/schedule_software_update?offset_sec=50" }
	}
	
	-- Tesla API location
	local base_url = "https://owner-api.teslamotors.com"
	local vehicle_url = nil
	-- Authentication data
	local auth_data = {
			['client_secret'] = 'c7257eb71a564034f9419ee651c7d0e5f7aa6bfbd18bafb5c5c033b093bb2fa3',
			['client_id'] = '81527cff06843c8634fdc09e8ac0abefb46ac849f38fe1e431c2ef2106796384',
			['token'] = nil,
			['refresh_token'] = nil,
			['expires_in'] = nil,
			['created_at'] = nil,
			['expires_at'] = nil
		}
	local request_header = {
		['x-tesla-user-agent'] = "VeraTeslaCarApp/1.0",
		['user-agent'] = "Mozilla/5.0 (Linux; Android 8.1.0; Pixel XL Build/OPM4.171019.021.D1; wv) Chrome/68.0.3440.91",
		['accept'] = 'application/json'
	}
	-- Found vehicle details
	local vehicle_data = nil
	
	-- HTTPs request
	local function HttpsRequest(mthd, strURL, ReqHdrs, PostData)
		local result = {}
		local request_body = nil
print("HttpsRequest 1 %s", strURL)		
		if PostData then
			-- We pass JSONs in all cases
			ReqHdrs["content-type"] = 'application/json; charset=UTF-8'
			request_body=json.encode(PostData)
			ReqHdrs["content-length"] = string.len(request_body)
print("HttpsRequest 2 body: %s",request_body)		
		else	
--print("HttpsRequest 2, no body ")		
			ReqHdrs["content-length"] = '0'
		end 
		http.TIMEOUT = 15 
		local bdy,cde,hdrs,stts = https.request{
			url = strURL, 
			method = mthd,
			sink = ltn12.sink.table(result),
			source = ltn12.source.string(request_body),
			headers = ReqHdrs
		}
print("HttpsRequest 3 %d", cde)		
		if cde ~= 200 then
			return false, nil, cde
		else
print("HttpsRequest 4 %s", table.concat(result))		
			return true, json.decode(table.concat(result)), cde
		end
	end	

	-- Initialize API functions 
	local function _init(email, password)
		auth_data.email = email
		auth_data.password = password
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
			request_header['authorization'] = reply.token_type.." "..reply.access_token
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
	local function _get_vehicle(vin)
		-- Check if we are authenticated
		if auth_data.token then
			local idx = 1
			local msg = "OK"
			local cmd = commands.listCars
			local res, reply, cde = HttpsRequest(cmd.method, base_url .. cmd.url , request_header )
			if res then
				if reply.count > 0 then
					-- See if we can find vin
					if vin then
						for i = 1, reply.count do
							if reply.response[i].vin == vin then
								idx = i
								break
							end	
						end
					end
					vehicle_data = reply.response[idx]
					-- Set the corect URL for vehicle requests
					vehicle_url = base_url .. '/api/1/vehicles/' .. vehicle_data.id_s
				else
					res = false
					msg = "No vehicles found."
				end
			else
				msg = "HTTP Request failed, code ".. cde
			end
			return res, vehicle_data, msg
		else
			return false, 401, "Not authenticated."
		end
	end

	-- Send a command to the API.
	local function _sendcommand(command, param)
print('Enter SendCommand :'.. command)
		if vehicle_data then
			local msg = "OK"
			local cmd = commands[command]
			if cmd then 
				-- Set correct command URL with optional parameter
				local url = cmd.url
--				if cmd.fmt then url = cmd.fmt(cmd.url, param) end
				local data = nil
				if param then
					data = { percent = param }
				end
				local res, reply, cde = HttpsRequest(cmd.method, vehicle_url..url, request_header, data)
print('SendCommand res : %d',cde)
				return res, reply, msg
			else
				return false, nil, "Unknown command : "..command
			end
		else
			return false, nil, "No vehicle selected."
		end
	end

	return {
		Initialize = _init,
		Authenticate = _authenticate,
		GetVehicle = _get_vehicle,
		SendCommand = _sendcommand
	}
end

local function wakeitup(my_car)
	local res, reply, msg = my_car.GetVehicle()
	local sleeping = 15
	if res then
		print("found car :", reply.vin)
		if reply.state == "online" then
			print("Your Tesla is awake...")
			sleeping = -1
		else	
			res, reply, msg = my_car.SendCommand('wakeUp')
			while sleeping > 0 do
				local now = os.time()
				local res, reply, msg = my_car.GetVehicle()
				if res then
					if reply.state == "online" then
						print(os.date("%T",now)..": Tesla is awake...")
						sleeping = -1
					else	
						print(os.date("%T",now)..": Ssst, Tesla is sleeping...")
						socket.sleep(1)
						sleeping = sleeping -1
					end
				else
					print("failed ", msg)
				end	
			end
		end
	end	
	return sleeping == -1
end

local my_car = TeslaCarAPI()
my_car.Initialize(USER, PWD)
if my_car.Authenticate() then
	if wakeitup(my_car) then
		local res, reply, msg = my_car.SendCommand('getVehicleDetails')
		res, reply, msg = my_car.SendCommand('setChargeLimit', 70)
--		res, reply, msg = my_car.SendCommand('setStandardRangeChargeLimit')
		local sleeping = true
--		local sleeping = false
		while not sleeping do
			local now = os.time()
			local res, reply, msg = my_car.GetVehicle()
			if res then
				if reply.state == "online" then
--[[			res, reply, msg = my_car.SendCommand('wakeUp')
			res, reply, msg = my_car.SendCommand('getVehicleDetails')
			res, reply, msg = my_car.SendCommand('getServiceData')
			res, reply, msg = my_car.SendCommand('getChargeState')
			res, reply, msg = my_car.SendCommand('getClimateState')
			res, reply, msg = my_car.SendCommand('getDriveState')
			res, reply, msg = my_car.SendCommand('getMobileEnabled')
			res, reply, msg = my_car.SendCommand('getGuiSettings')
]]			
					print(os.date("%T",now)..": Tesla is awake...")
					socket.sleep(30)
				else
					print(os.date("%T",now)..": Ssst, Tesla is sleeping...")
					sleeping = true
				end	
			else
				print("failed ", msg)
			end
		end
	else
		print("Wakeup failed")
	end	
else
	print("failed to authenticate")
end
