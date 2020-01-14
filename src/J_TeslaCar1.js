//# sourceURL=J_TeslaCar1.js
// openLuup "TeslaCar" Plug-in
// Written by R.Boer. 
// V1.0 10 January 2020
//
var TeslaCar = (function (api) {

	var MOD_SID = 'urn:rboer-com:serviceId:TeslaCar1';
	var moduleName = 'TeslaCar';

	// Forward declaration.
    var myModule = {};

    function _onBeforeCpanelClose(args) {
    }

    function _init() {
        // register to events...
        api.registerEventHandler('on_ui_cpanel_before_close', myModule, 'onBeforeCpanelClose');
    }

	function _showSettings() {
		_init();
        try {
			var deviceID = api.getCpanelDeviceId();
			var deviceObj = api.getDeviceObject(deviceID);
			var panelHtml = '<div class="deviceCpanelSettingsPage">'
				+ '<h3>Device #'+deviceID+'&nbsp;&nbsp;&nbsp;'+api.getDisplayedDeviceName(deviceID)+'</h3>';
			if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
				panelHtml += '<br>Plugin is disabled in Attributes.';
			} else {	
				var yesNo = [{'value':'0','label':'No'},{'value':'1','label':'Yes'}];
				var chargeIntervals = [{'value':'5','label':'5 Min'},{'value':'10','label':'10 Min'},{'value':'15','label':'15 Min'},{'value':'20','label':'20 Min'},{'value':'30','label':'30 Min'},{'value':'60','label':'60 Min'},{'value':'90','label':'90 Min'},{'value':'120','label':'Two hours'},{'value':'240','label':'Four Hours'}];
				var activeIntervals = [{'value':'1','label':'1 Min'},{'value':'5','label':'5 Min'},{'value':'10','label':'10 Min'},{'value':'15','label':'15 Min'}];
				var logLevel = [{'value':'1','label':'Error'},{'value':'2','label':'Warning'},{'value':'8','label':'Info'},{'value':'10','label':'Debug'},{'value':'11','label':'Test Debug'}];
//				var retries = [{'value':'0','label':'None'},{'value':'1','label':'One'},{'value':'2','label':'Two'},{'value':'3','label':'Three'},{'value':'4','label':'Four'}];

				panelHtml += htmlAddInput(deviceID, 'Tesla Email', 30, 'Email') + 
				htmlAddInput(deviceID, 'Tesla Password', 30, 'Password')+
//				htmlAddPulldown(deviceID, 'Action retries', 'ActionRetries', retries)+
				htmlAddPulldown(deviceID, 'Daily Poll ?', 'PI0', yesNo)+
				htmlAddInput(deviceID, 'Daily Poll time (hh:mm)', 30, 'DailyPollTime')+ 
				htmlAddPulldown(deviceID, 'Poll Interval; Charging > 1hr', 'PI2', chargeIntervals)+
				htmlAddPulldown(deviceID, 'Poll Interval; Charging < 1 hr', 'PI3', chargeIntervals)+
				htmlAddPulldown(deviceID, 'Poll Interval; Active', 'PI4', activeIntervals)+
//				htmlAddPulldown(deviceID, 'Poll Interval; Fast Locations', 'PI4', chargeIntervals)+
//				htmlAddInput(deviceID, 'Fast Poll Locations (lat,lng;lat,lng)', 30, 'FastPollLocations')+ 
//				htmlAddInput(deviceID, 'No Poll time window (hh:mm-hh:mm)', 30, 'NoPollWindow')+ 
				htmlAddPulldown(deviceID, 'Log level', 'LogLevel', logLevel);
			}
			api.setCpanelContent(panelHtml);
        } catch (e) {
            Utils.logError('Error in '+moduleName+'.showSettings(): ' + e);
        }
	}
	
	function _showStatus() {
		_init();
		// Thanks for amg0
		function _format2Digits(d) {
			return ("0"+d).substr(-2);
		}	
		// Format time stamp to dd-mm-yyyy, hh:mm:ss
		function _getFormattedDate(ts) {
			var date = new Date(ts * 1000);
			var month = _format2Digits(date.getMonth() + 1);
			var day = _format2Digits(date.getDate());
			var hour = _format2Digits(date.getHours());
			var min = _format2Digits(date.getMinutes());
			var sec = _format2Digits(date.getSeconds());
			var str = day + "-" + month + "-" + date.getFullYear() + ", " +  hour + ":" + min + ":" + sec;
			return str;
		}
		
        try {
			var deviceID = api.getCpanelDeviceId();
			var deviceObj = api.getDeviceObject(deviceID);
			var panelHtml = '<div class="deviceCpanelSettingsPage">'
				+ '<h3>Device #'+deviceID+'&nbsp;&nbsp;&nbsp;'+api.getDisplayedDeviceName(deviceID)+'</h3>';
			if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
				panelHtml += '<br>Plugin is disabled in Attributes.';
			} else {	
				var cn = varGet(deviceID, 'CarName');
				var lat = Number.parseFloat(varGet(deviceID, 'Latitude')).toFixed(4);
				var lng = Number.parseFloat(varGet(deviceID, 'Longitude')).toFixed(4);
				var clh = varGet(deviceID, 'LocationHome');
				var lcst = varGet(deviceID, 'LastCarMessageTimestamp');
				var fwv = varGet(deviceID, 'CarFirmwareVersion');
				var ppls = varGet(deviceID, 'PowerPlugLockState');
				var pps = varGet(deviceID, 'PowerPlugState');
				var psc = varGet(deviceID, 'PowerSupplyConnected');
				var clms = varGet(deviceID, 'ClimateMessage');
				var drs = varGet(deviceID, 'DoorsMessage');
				var lcks = varGet(deviceID, 'LockedMessage');
				var trs = varGet(deviceID, 'TrunkMessage');
				var frs = varGet(deviceID, 'FrunkMessage');
				var mlg = varGet(deviceID, 'Mileage');
				var wins = varGet(deviceID, 'WindowsMessage');
				var psm = 'Unknown';
				if (psc === '1') {
					psm = 'Charge power available';
				} else {
					if (pps === '1') {
						psm = 'Cable in car, but not in charge station'
					} else {
						psm = 'Not connected'
					}
				}
				panelHtml += '<p><div class="col-12" style="overflow-x: auto;"><table class="table-responsive-OFF table-sm"><tbody>'+
					'<tr><td>Tesla Car name </td><td>'+cn+'</td></tr>'+
					'<tr><td> </td><td> </td></tr>'+
					'<tr><td>Last Car Message received at </td><td>'+ _getFormattedDate(lcst) + '</td></tr>'+
					'<tr><td> </td><td> </td></tr>'+
					'<tr><td>Milage </td><td>'+mlg+' Km</td></tr>'+
					'<tr><td> </td><td> </td></tr>'+
					'<tr><td>Car location </td><td>'+(clh==='1'?'Home':'Away, Latitude : '+lat+', Longitude : '+lng)+'</td></tr>'+
//					'<tr><td> </td><td> </td></tr>'+
					'<tr><td>Power Connection Status </td><td>'+psm+'</td></tr>'+
					'<tr><td>Climate Status </td><td>'+clms+'</td></tr>'+
					'<tr><td>Locks Status </td><td>'+lcks+'</td></tr>'+
					'<tr><td>Doors Status </td><td>'+drs+'</td></tr>'+
					'<tr><td>Trunk/Frunk Status </td><td>'+trs+'/'+frs+'</td></tr>'+
					'<tr><td>Windows Status </td><td>'+wins+'</td></tr>'+
					'<tr><td> </td><td> </td></tr>'+
					'<tr><td>Car Firmware </td><td>'+fwv+'</td></tr>'+
					'</tbody></table></div></p>';
			}	
			api.setCpanelContent(panelHtml);
        } catch (e) {
            Utils.logError('Error in '+moduleName+'.showStatus(): ' + e);
        }
	}
	
	function  _updateVariable(vr,val) {
        try {
			var deviceID = api.getCpanelDeviceId();
			if (vr.startsWith('PI')) {
				var ps = varGet(deviceID,'PollSettings');
				var pa = ps.split(',');
				pa[Number(vr.charAt(2))] = val;
				varSet(deviceID,'PollSettings',pa.join(','));
			} else {
				varSet(deviceID,vr,val);
			}
        } catch (e) {
            Utils.logError('Error in '+moduleName+'.updateVariable(): ' + e);
        }
	}
	
	// Add a button html
	function htmlAddButton(di, cb, lb) {
		var html = '<div class="cpanelSaveBtnContainer labelInputContainer clearfix">'+	
			'<input class="vBtn pull-right" type="button" value="'+lb+'" onclick="'+moduleName+'.'+cb+'(\''+di+'\');"></input>'+
			'</div>';
		return html;
	}

	// Add a standard input for a plug-in variable.
	function htmlAddInput(di, lb, si, vr, sid, df) {
		var val = (typeof df != 'undefined') ? df : varGet(di,vr,sid);
		var typ = (vr.toLowerCase() == 'password') ? 'type="password"' : 'type="text"';
		var html = '<div class="clearfix labelInputContainer">'+
					'<div class="pull-left inputLabel" style="width:280px;">'+lb+'</div>'+
					'<div class="pull-left">'+
						'<input class="customInput altui-ui-input form-control" '+typ+' size="'+si+'" id="'+moduleName+vr+di+'" value="'+val+'" onChange="'+moduleName+'.updateVariable(\''+vr+'\',this.value)">'+
					'</div>'+
				   '</div>';
		if (vr.toLowerCase() == 'password') {
			html += '<div class="clearfix labelInputContainer">'+
					'<div class="pull-left inputLabel" style="width:280px;">&nbsp; </div>'+
					'<div class="pull-left">'+
						'<input class="customCheckbox" type="checkbox" id="'+moduleName+vr+di+'Checkbox">'+
						'<label class="labelForCustomCheckbox" for="'+moduleName+vr+di+'Checkbox">Show Password</label>'+
					'</div>'+
				   '</div>';
			html += '<script type="text/javascript">'+
					'$("#'+moduleName+vr+di+'Checkbox").on("change", function() {'+
					' var typ = (this.checked) ? "text" : "password" ; '+
					' $("#'+moduleName+vr+di+'").prop("type", typ);'+
					'});'+
					'</script>';
		}
		return html;
	}

	// Add a label and pulldown selection
	function htmlAddPulldown(di, lb, vr, values) {
		try {
			var selVal = '';
			if (vr.startsWith('PI')) {
				var ps = varGet(di,'PollSettings');
				var pa = ps.split(',');
				selVal = pa[Number(vr.charAt(2))];
			} else {
				selVal = varGet(di, vr);
			}
			var html = '<div class="clearfix labelInputContainer">'+
				'<div class="pull-left inputLabel" style="width:280px;">'+lb+'</div>'+
				'<div class="pull-left customSelectBoxContainer">'+
				'<select id="'+moduleName+vr+di+'" onChange="'+moduleName+'.updateVariable(\''+vr+'\',this.value)" class="customSelectBox form-control">';
			for(var i=0;i<values.length;i++){
				html += '<option value="'+values[i].value+'" '+((values[i].value==selVal)?'selected':'')+'>'+values[i].label+'</option>';
			}
			html += '</select>'+
				'</div>'+
				'</div>';
			return html;
		} catch (e) {
			Utils.logError(moduleName+': htmlAddPulldown(): ' + e);
		}
	}

	// Update variable in user_data and lu_status
	function varSet(deviceID, varID, varVal, sid) {
		if (typeof(sid) == 'undefined') { sid = MOD_SID; }
		api.setDeviceStateVariablePersistent(deviceID, sid, varID, varVal);
	}
	// Get variable value. When variable is not defined, this new api returns false not null.
	function varGet(deviceID, varID, sid) {
		try {
			if (typeof(sid) == 'undefined') { sid = MOD_SID; }
			var res = api.getDeviceState(deviceID, sid, varID);
			if (res !== false && res !== null && res !== 'null' && typeof(res) !== 'undefined') {
				return res;
			} else {
				return '';
			}	
        } catch (e) {
            return '';
        }
	}

	// Expose interface functions
    myModule = {
        init: _init,
        onBeforeCpanelClose: _onBeforeCpanelClose,
		showSettings: _showSettings,
		showStatus: _showStatus,
		updateVariable : _updateVariable
    };
    return myModule;
})(api);
