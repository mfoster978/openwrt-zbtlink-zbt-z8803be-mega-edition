'use strict';
'require view';

/*
 * LuCI navigation is client-side, so an nginx redirect cannot see a click on
 * the Speedify menu. Keep this launcher outside the vendor APK's file paths:
 * it moves the browser to HTTPS before loading the vendor-owned view.
 */
return view.extend({
	load: function() {
		var target = new URL(L.url('admin/speedify/app'), window.location.origin);

		target.protocol = 'https:';
		target.port = '';
		target.search = window.location.search;
		target.hash = window.location.hash;
		window.location.replace(target.href);
	},

	render: function() {
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Opening Speedify securely…')),
			E('p', {}, _('Speedify requires HTTPS for its authenticated connection interface.'))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
