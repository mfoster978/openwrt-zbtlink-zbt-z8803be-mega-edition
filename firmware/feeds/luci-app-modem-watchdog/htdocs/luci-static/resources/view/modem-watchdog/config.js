'use strict';
'require view';
'require form';
'require uci';
return view.extend({
	load: function() {
		return uci.load(['modem_watchdog']);
	},
	render: function() {
		var m, s, o;
		m = new form.Map('modem_watchdog', _('Modem Watchdog'),
			_('Monitor modem connectivity and optionally recover/failover. Disabled by default for safe first boot.'));
		s = m.section(form.TypedSection, 'modem_watchdog', _('Global settings'));
		s.anonymous = true;
		o = s.option(form.Flag, 'enabled', _('Enable watchdog service'));
		o.default = '0';
		o = s.option(form.Flag, 'actions_enabled', _('Allow recovery actions'));
		o.default = '0';
		o = s.option(form.Value, 'interval_seconds', _('Check interval (seconds)'));
		o.datatype = 'uinteger';
		o.default = '30';
		o = s.option(form.Value, 'ping_target', _('Ping target'));
		o.default = '1.1.1.1';
		o = s.option(form.Value, 'ping_fail_threshold', _('Failures before action'));
		o.datatype = 'uinteger';
		o.default = '4';
		o = s.option(form.Value, 'cooldown_seconds', _('Recovery cooldown (seconds)'));
		o.datatype = 'uinteger';
		o.default = '180';
		o = s.option(form.Flag, 'failover', _('Enable failover policy'));
		o.default = '0';
		o = s.option(form.Flag, 'prefer_fastest', _('Prefer fastest modem (speed test-assisted)'));
		o.default = '0';
		o = s.option(form.Flag, 'speed_test', _('Enable speed test sampling'));
		o.default = '0';
		o = s.option(form.Value, 'speed_test_cooldown_minutes', _('Speed test interval (minutes)'));
		o.datatype = 'uinteger';
		o.default = '15';
		o = s.option(form.Value, 'speed_test_min_mbps', _('Minimum acceptable speed (Mbps)'));
		o.datatype = 'ufloat';
		o.default = '5';
		o = s.option(form.Value, 'speed_fail_threshold', _('Low-speed rounds before action'));
		o.datatype = 'uinteger';
		o.default = '1';
		var modem = m.section(form.TypedSection, 'modem', _('Per-modem settings'));
		modem.anonymous = true;
		modem.addremove = false;
		o = modem.option(form.Value, 'section', _('QModem section'));
		o.default = '4_1';
		o = modem.option(form.Flag, 'enabled', _('Monitor this modem'));
		o.default = '1';
		o = modem.option(form.ListValue, 'action', _('Recovery action'));
		o.value('none', _('None (log only)'));
		o.value('disconnect', _('Disconnect modem interface'));
		o.value('redial', _('Redial modem'));
		o.value('power_cycle', _('Power cycle GPIO + redial'));
		o.default = 'redial';
		o = modem.option(form.Value, 'gpio_power_name', _('GPIO power name'));
		o.default = '5g1';
		return m.render();
	}
});
