'use strict';
'require view';
return view.extend({
	render: function() {
		var root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Speed Test Utility')),
			E('div', { 'class': 'cbi-section-descr' }, _('Run a speed test on the current internet connection.')),
			E('p', {}, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'id': 'speedtest-run-btn' }, _('Run speed test'))
			]),
			E('div', { 'id': 'speedtest-status' }, _('Idle')),
			E('div', { 'id': 'speedtest-results', 'style': 'margin-top:10px;display:none;' }, [
				E('div', {}, [E('strong', {}, _('Runner: ')), E('span', { 'id': 'st-runner' }, '-')]),
				E('div', {}, [E('strong', {}, _('Server: ')), E('span', { 'id': 'st-server' }, '-')]),
				E('div', {}, [E('strong', {}, _('Ping: ')), E('span', { 'id': 'st-ping' }, '-')]),
				E('div', { 'style': 'margin-top:8px;' }, [
					E('div', {}, _('Download (Mbps)')),
					E('div', { 'style': 'height:16px;background:#ddd;border-radius:3px;' }, [
						E('div', { 'id': 'st-dl-bar', 'style': 'height:16px;width:0%;background:#3b82f6;border-radius:3px;' }, [])
					]),
					E('div', { 'id': 'st-dl-text' }, '-')
				]),
				E('div', { 'style': 'margin-top:8px;' }, [
					E('div', {}, _('Upload (Mbps)')),
					E('div', { 'style': 'height:16px;background:#ddd;border-radius:3px;' }, [
						E('div', { 'id': 'st-ul-bar', 'style': 'height:16px;width:0%;background:#22c55e;border-radius:3px;' }, [])
					]),
					E('div', { 'id': 'st-ul-text' }, '-')
				])
			])
		]);

		setTimeout(function() {
			var btn = document.getElementById('speedtest-run-btn');
			var status = document.getElementById('speedtest-status');
			var results = document.getElementById('speedtest-results');
			btn.addEventListener('click', function() {
				btn.disabled = true;
				status.textContent = 'Running speed test...';
				fetch('/cgi-bin/speedtest-lite-run', { method: 'GET', cache: 'no-store' })
					.then(function(r) { return r.json(); })
					.then(function(data) {
						if (!data.ok) {
							status.textContent = 'Speed test failed: ' + (data.error || 'unknown error');
							return;
						}
						status.textContent = 'Completed';
						results.style.display = '';
						document.getElementById('st-runner').textContent = data.runner || '-';
						document.getElementById('st-server').textContent = data.server || '-';
						document.getElementById('st-ping').textContent = (data.ping_ms || 0) + ' ms';
						var dl = Number(data.download_mbps || 0);
						var ul = Number(data.upload_mbps || 0);
						var dlPct = Math.min(100, Math.max(0, dl));
						var ulPct = Math.min(100, Math.max(0, ul));
						document.getElementById('st-dl-bar').style.width = dlPct + '%';
						document.getElementById('st-ul-bar').style.width = ulPct + '%';
						document.getElementById('st-dl-text').textContent = dl.toFixed(2);
						document.getElementById('st-ul-text').textContent = ul.toFixed(2);
					})
					.catch(function(err) {
						status.textContent = 'Speed test failed: ' + err;
					})
					.finally(function() { btn.disabled = false; });
			});
		}, 0);

		return root;
	}
});
