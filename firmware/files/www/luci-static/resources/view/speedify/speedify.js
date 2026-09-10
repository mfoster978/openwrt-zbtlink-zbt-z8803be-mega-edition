'use strict';
'require view';

/*
 * This small ROM-resident screen keeps Speedify in LuCI across sysupgrades.
 * The checksum-verified vendor APK replaces this file with the full management
 * UI after Internet access is available; no proprietary payload is bundled.
 */
return view.extend({
	render: function() {
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Speedify')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Finishing Speedify setup')),
				E('p', {}, _('This firmware keeps the Speedify menu available while the official Speedify packages are downloaded and installed. The full management screen will replace this message automatically after the router has working HTTPS Internet access.')),
				E('p', {}, _('Installation retries in the background. It can take several minutes after a firmware upgrade or first boot. Your modem and normal routing do not depend on Speedify finishing.')),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'type': 'button',
					'click': function() { window.location.reload(); }
				}, _('Reload Speedify')),
				E('p', { 'class': 'cbi-value-description' }, [
					_('For diagnostics over SSH, run '),
					E('code', {}, 'logread -e speedify-installer')
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
