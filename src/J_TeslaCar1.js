//# sourceURL=J_TeslaCar1.js
// openLuup "TeslaCar" Plug-in
// Written by R.Boer. 
// V3.3 26 June 2023
//
// V3.3 Changes:
//		Added tire pressure status.
// V3.0 Changes:
//		Use of initial token rather than email and password for authentication.
// V2.3 Changes:
//		Added version number to panel headers.
// V1.15 Changes:
//		Added sntry mode control.
// V1.14 Changes:
//		Typo correction
//		Show mileage in miles if applicable.
// V1.10 Changes:
//		Added car type to status screen.
//		Child device selection will only show available remote control devices.
// V1.8 Changes:
//		Added setting for Idle poll as standard 20 minutes may keep some cars awake.
// V1.7 Changes:
//		Added in service status to status tab.
// V1.6 Changes:
//		Added awake status to status tab.
// V1.5 Changes:
//		Re-ordered child device labels and corrected label for Inside and Outside temps.
// V1.4 Changes:
//		Added support for child device creations.
//
var TeslaCar = (function (api) {

	var MOD_SID = 'urn:rboer-com:serviceId:TeslaCar1';
	var moduleName = 'TeslaCar';
	var devList = [{'value':'C','label':'Charging'},{'value':'P','label':'Charge Port'},{'value':'H','label':'Climate'},{'value':'L','label':'Doors Locked'},{'value':'W','label':'Windows'},{'value':'R','label':'Sunroof'},{'value':'T','label':'Trunk'},{'value':'F','label':'Frunk'},{'value':'I','label':'Inside temperature'},{'value':'O','label':'Outside temperature'},{'value':'S','label':'Sentry Mode'}];

	// Forward declaration.
    var myModule = {};

	function _panelHeader(deviceID) {
		var vrsn = varGet(deviceID, 'Version');
		return '<div class="deviceCpanelSettingsPage">'
			+ '<h4>Device #'+deviceID+'&nbsp;&nbsp;&nbsp;'+api.getDisplayedDeviceName(deviceID)+'&nbsp;&nbsp;&nbsp;<font style="vertical-align:middle;" size=-2>Plugin Version '+vrsn+'</font></h3>';
	}
	
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
			var panelHtml = _panelHeader(deviceID);
			if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
				panelHtml += '<br>Plugin is disabled in Attributes.';
			} else {	
				var yesNo = [{'value':'0','label':'No'},{'value':'1','label':'Yes'}];
				var chargeIntervals = [{'value':'5','label':'5 Min'},{'value':'10','label':'10 Min'},{'value':'15','label':'15 Min'},{'value':'20','label':'20 Min'},{'value':'30','label':'30 Min'},{'value':'60','label':'60 Min'},{'value':'90','label':'90 Min'},{'value':'120','label':'Two hours'},{'value':'240','label':'Four Hours'}];
				var chargeIntervals1 = [{'value':'15','label':'15 Min'},{'value':'20','label':'20 Min'},{'value':'30','label':'30 Min'},{'value':'60','label':'60 Min'},{'value':'90','label':'90 Min'}];
				var activeIntervals = [{'value':'1','label':'1 Min'},{'value':'5','label':'5 Min'},{'value':'10','label':'10 Min'},{'value':'15','label':'15 Min'}];
				var limitIntervals = [{'value':'75','label':'75%'},{'value':'80','label':'80%'},{'value':'85','label':'85%'},{'value':'90','label':'90%'}];
				var logLevel = [{'value':'1','label':'Error'},{'value':'2','label':'Warning'},{'value':'8','label':'Info'},{'value':'10','label':'Debug'},{'value':'100','label':'Test Debug'}];

				panelHtml += htmlAddInput(deviceID, 'Initial Token', 30, 'InitialToken') + 
				htmlAddPulldown(deviceID, 'Daily Poll ?', 'PI0', yesNo)+
				htmlAddInput(deviceID, 'Daily Poll time (hh:mm)', 30, 'DailyPollTime')+ 
				htmlAddPulldown(deviceID, 'Poll Interval; Idle', 'PI1', chargeIntervals1)+
				htmlAddPulldown(deviceID, 'Poll Interval; Charging > 1hr', 'PI2', chargeIntervals)+
				htmlAddPulldown(deviceID, 'Poll Interval; Charging < 1 hr', 'PI3', chargeIntervals)+
				htmlAddPulldown(deviceID, 'Poll Interval; Active', 'PI4', activeIntervals)+
				htmlAddPulldown(deviceID, 'Poll Interval; Moving', 'PI5', activeIntervals)+
				htmlAddPulldown(deviceID, 'Standard Charge Limit', 'StandardChargeLimit', limitIntervals)+
				htmlAddPulldown(deviceID, 'Log level', 'LogLevel', logLevel);
			}
			api.setCpanelContent(panelHtml);
        } catch (e) {
            Utils.logError('Error in '+moduleName+'.showSettings(): ' + e);
        }
	}
	
	function _showChildSettings() {
		_init();
        try {
			var deviceID = api.getCpanelDeviceId();
			var deviceObj = api.getDeviceObject(deviceID);
			var panelHtml = _panelHeader(deviceID);
			if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
				panelHtml += '<br>Plugin is disabled in Attributes.';
			} else {	
				panelHtml += 'Select the child devices you want and hit Save.<br>&nbsp;<br>';
				var curSel = varGet(deviceID,'PluginHaveChildren');
				var hsr = varGet(deviceID, 'CarHasSunRoof');
				var hmcp = varGet(deviceID, 'CarHasMotorizedChargePort');
				var cat = varGet(deviceID, 'CarCanActuateTrunks');
				var caw = varGet(deviceID, 'CarCanActuateWindows');
				for(var i=0;i<devList.length;i++){
					var bAdd = true;
					var val = devList[i].value;
					// Check car config for options, skip if not availble for remote control.
					if (val === 'R' && hsr === '0') { bAdd = false; }
					if (val === 'P' && hmcp === '0') { bAdd = false; }
					if (val === 'T' && cat === '0') { bAdd = false; }
					if (val === 'F' && cat === '0') { bAdd = false; }
					if (val === 'W' && caw === '0') { bAdd = false; }
					// Add option to page
					if (bAdd) {
						panelHtml += htmlAddCheckBox(deviceID, devList[i].label+' Control', val, curSel.indexOf(val))
					}	
				}
				panelHtml += htmlAddButton(deviceID, 'updateChildSelections', 'Save');
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
			var panelHtml = _panelHeader(deviceID);
			if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
				panelHtml += '<br>Plugin is disabled in Attributes.';
			} else {	
				var cn = varGet(deviceID, 'CarName');
				var ct = varGet(deviceID, 'CarType');
				var lat = Number.parseFloat(varGet(deviceID, 'Latitude')).toFixed(4);
				var lng = Number.parseFloat(varGet(deviceID, 'Longitude')).toFixed(4);
				var clh = varGet(deviceID, 'LocationHome');
				var awk = varGet(deviceID, 'CarIsAwake');
				var lcst = varGet(deviceID, 'LastCarMessageTimestamp');
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
				var srvs = varGet(deviceID, 'InServiceStatus');
				var srve = varGet(deviceID, 'InServiceEtc');
				var gdu = varGet(deviceID, 'GuiDistanceUnits');
				var smd = varGet(deviceID, 'SentryMode');
				var tpms = varGet(deviceID, 'TyrePressureMessage');
				if (gdu === 'km/hr') {
					gdu = 'Km'
				} else {
					gdu = 'Miles'
				}
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
					'<tr><td>Tesla Car type </td><td>'+ct+'</td></tr>'+
					'<tr><td>&nbsp;&nbsp; </td><td> </td></tr>'+
					'<tr><td>Last Car update received at&nbsp;&nbsp;</td><td>'+ _getFormattedDate(lcst) + '</td></tr>'+
					'<tr><td>&nbsp;&nbsp; </td><td> </td></tr>'+
					'<tr><td>Awake status</td><td>'+(awk==='1'?'Awake':'Sleeping')+'</td></tr>'+
					'<tr><td>&nbsp;&nbsp; </td><td> </td></tr>'+
					'<tr><td>Mileage </td><td>'+mlg+' '+gdu+'</td></tr>'+
					'<tr><td>Car location </td><td>'+(clh==='1'?'Home':'Away, Latitude : '+lat+', Longitude : '+lng)+'</td></tr>'+
					'<tr><td>Power Connection Status </td><td>'+psm+'</td></tr>'+
					'<tr><td>Climate Status </td><td>'+clms+'</td></tr>'+
					'<tr><td>Locks Status </td><td>'+lcks+'</td></tr>'+
					'<tr><td>Doors Status </td><td>'+drs+'</td></tr>'+
					'<tr><td>Trunk/Frunk Status </td><td>'+trs+'/'+frs+'</td></tr>'+
					'<tr><td>Windows Status </td><td>'+wins+'</td></tr>'+
					'<tr><td valign="top">Tire Pressure Status </td><td>'+tpms+'</td></tr>'+
					'<tr><td>Sentry Mode </td><td>'+(smd==='1'?'Active':'Inactive')+'</td></tr>'+
					'<tr><td>&nbsp;&nbsp; </td><td> </td></tr>'+
					'<tr><td>In Service</td><td>'+(srvs==='0'?'Not in service':'In service, ETC : '+srve)+'</td></tr>'+
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
			if (vr === 'LogLevel') {
				api.performLuActionOnDevice(deviceID, MOD_SID, 'SetLogLevel',  { actionArguments: { newLogLevel: val }});
			} else if (vr.startsWith('PI')) {
				var ps = varGet(deviceID,'PollSettings');
				var pa = ps.split(',');
				pa[Number(vr.charAt(2))] = val;
				varSet(deviceID,'PollSettings',pa.join(','));
			} else {
				varSet(deviceID,vr,val);
			}
			application.sendCommandSaveUserData(true);
        } catch (e) {
            Utils.logError('Error in '+moduleName+'.updateVariable(): ' + e);
        }
	}
	
	function _updateChildSelections(deviceID) {
		// Get the selection from the pull down
		var bChanged = false;
		showBusy(true);
		// Get checked boxes
		var selIDs = [];
		for(var i=0;i<devList.length;i++){
			if ($("#"+moduleName+devList[i].value+"Checkbox").is(":checked")) {
				selIDs.push(devList[i].value);
			}
		}
		var sselIDs = selIDs.join();
		var sorgIDs = varGet(deviceID,'PluginHaveChildren');
		if (sselIDs != sorgIDs) {
			varSet(deviceID,'PluginHaveChildren', sselIDs);
			bChanged=true;
		}	
//		selIDs = htmlGetElemVal(deviceID, 'PluginEmbedChildren');
//		orgIDs = varGet(deviceID, 'PluginEmbedChildren');
//		if (selIDs != orgIDs) {
//			varSet(deviceID,'PluginEmbedChildren', selIDs);
//			bChanged=true;
//		}	
		// If we have changes in child devices, reload device.
		if (bChanged) {
			application.sendCommandSaveUserData(true);
			setTimeout(function() {
				api.performLuActionOnDevice(0, "urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {});
				htmlSetMessage("Changes to configuration made.<br>Now wait for reload to complete and then refresh your browser page!<p>New device(s) will be in the No Room section.",false);
				showBusy(false);
			}, 3000);	
		} else {
			showBusy(false);
			htmlSetMessage("You have not made any changes.<br>No changes made.",true);
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
		var val = (typeof df !== 'undefined') ? df : varGet(di,vr,sid);
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


	// Add a check box and label 
// <div class="checkbox checkbox-inline">
//	<input type="checkbox" id="condk15k6td-nocase" value="1" class="nocase"><label for="condk15k6td-nocase">Ignore&nbsp;case</label>
// </div>
	function htmlAddCheckBox(di, lb, di, chk) {
		try {
			var html = '<div class="clearfix labelInputContainer">'+
//					'<div class="pull-left checkbox checkbox-inline">'+
					'<div class="checkbox checkbox-inline">'+
						'<input class="customCheckbox" type="checkbox" id="'+moduleName+di+'Checkbox" '+((chk != -1) ? 'checked' : '')+'>'+
						'<label class="labelForCustomCheckbox" for="'+moduleName+di+'Checkbox">'+lb+'</label>'+
					'</div>'+
				   '</div>';
			return html;
		} catch (e) {
			Utils.logError(moduleName+': htmlAddPulldown(): ' + e);
		}
	}

	// Standard update for  plug-in pull down variable. We can handle multiple selections.
	function htmlGetPulldownSelection(di, vr) {
		var value = $('#'+moduleName+vr+di).val() || [];
		return (typeof value === 'object')?value.join():value;
	}

	function htmlSetMessage(msg,error) {
		try {
			if (error === true) {
				api.ui.showMessagePopupError(msg);
			} else {
				api.ui.showMessagePopup(msg,0);
			}	
		}	
		catch (e) {	
//			$("#ham_msg").html(msg+'<br>&nbsp;');
			Utils.logError(moduleName+': htmlSetMessage(): ' + e);

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
	
	// Show/hide the interface busy indication.
	function showBusy(busy) {
		if (busy === true) {
			try {
				api.ui.showStartupModalLoading(); // version v1.7.437 and up
			} catch (e) {
				myInterface.showStartupModalLoading(); // For ALTUI support.
			}
		} else {
			try {
				api.ui.hideModalLoading(true);
			} catch (e) {
				myInterface.hideModalLoading(true); // For ALTUI support
			}	
		}
	}

	// Expose interface functions
    myModule = {
        init: _init,
        onBeforeCpanelClose: _onBeforeCpanelClose,
		showSettings: _showSettings,
		showChildSettings: _showChildSettings,
		showStatus: _showStatus,
		updateVariable : _updateVariable,
		updateChildSelections : _updateChildSelections
    };
    return myModule;
})(api);
