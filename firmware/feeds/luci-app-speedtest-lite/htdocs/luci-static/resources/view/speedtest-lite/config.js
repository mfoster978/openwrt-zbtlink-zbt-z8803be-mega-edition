'use strict';
'require view';
'require rpc';
'require poll';
var start = rpc.declare({ object: 'zbt.speedtest', method: 'start', params: ['interface'] });
var status = rpc.declare({ object: 'zbt.speedtest', method: 'status' });
return view.extend({
	handleSave: null, handleSaveApply: null, handleReset: null,
	render: function() {
		var output = E('p', {}, _('Ready'));
		var select = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: 'default' }, _('Current default connection (may use VPN)')),
			E('option', { value: 'wan' }, _('Wired WAN')),
			E('option', { value: 'wan_sfp' }, _('SFP WAN')),
			E('option', { value: '4_1' }, _('Modem 1 / 5G1')),
			E('option', { value: '2_1' }, _('Modem 2 / 5G2'))
		]);
		var button = E('button', { 'class': 'btn cbi-button-action', click: function() {
			button.disabled = true;
			start(select.value).then(function(r) {
				if (!r.ok) throw new Error(r.error || _('Unable to start sample'));
				output.textContent = _('Sampling… this can take up to one minute.');
			}).catch(function(e) { output.textContent = e.message; button.disabled = false; });
		}}, _('Run speed sample'));
		poll.add(function() {
			return status().then(function(r) {
				if (r.running) { button.disabled = true; return; }
				button.disabled = false;
				if (r.ok) output.textContent = _('Download: %s Mbps · Upload: %s Mbps · TCP connect: %s ms · Device: %s')
					.format(Number(r.download_mbps).toFixed(2), r.upload_mbps == null ? '—' : Number(r.upload_mbps).toFixed(2),
						Number(r.latency_ms).toFixed(1), r.device || _('default route'));
				else if (r.error) output.textContent = r.error;
			}).catch(function(e) { output.textContent = _('Cannot read sample status: %s').format(e.message); });
		}, 2);
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Speed Test Utility')),
			E('p', {}, _('Bounded, single-stream HTTPS throughput sample, not an Ookla benchmark. Uses up to 30 MB per test. Cellular data charges may apply.')),
			E('p', {}, _('A selected interface is bound directly; it is never substituted with the other modem. VPN policy can still affect routing.')),
			select, ' ', button, output
		]);
	}
});
