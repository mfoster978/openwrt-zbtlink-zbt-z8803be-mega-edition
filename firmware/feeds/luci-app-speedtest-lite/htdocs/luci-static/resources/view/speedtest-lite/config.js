'use strict';
'require view';
'require rpc';

var start = rpc.declare({ object: 'zbt.speedtest', method: 'start', params: ['interface', 'server', 'mode', 'consent'] });
var status = rpc.declare({ object: 'zbt.speedtest', method: 'status' });
var cancel = rpc.declare({ object: 'zbt.speedtest', method: 'cancel', params: ['id'] });

function svg(tag, attrs, children) {
	var node = document.createElementNS('http://www.w3.org/2000/svg', tag);
	Object.keys(attrs || {}).forEach(function(k) { node.setAttribute(k, attrs[k]); });
	(children || []).forEach(function(c) { node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
	return node;
}
function point(degrees, radius) {
	var radians = degrees * Math.PI / 180;
	return [200 + Math.cos(radians) * radius, 190 + Math.sin(radians) * radius];
}
function arc(startAngle, endAngle, radius) {
	var a = point(startAngle, radius), b = point(endAngle, radius);
	return 'M ' + a.join(' ') + ' A ' + radius + ' ' + radius + ' 0 ' +
		(endAngle - startAngle > 180 ? 1 : 0) + ' 1 ' + b.join(' ');
}
function number(v, digits) {
	return typeof v === 'number' && isFinite(v) && v >= 0 ? v.toFixed(digits == null ? 2 : digits) : '—';
}
// A labelled logarithmic scale leaves low cellular speeds readable while
// still covering multi-gigabit WAN. The pointer is never capped at 100 Mbps.
function fraction(value, maximum) {
	return Math.max(0, Math.min(1, Math.log(1 + value / 10) / Math.log(1 + maximum / 10)));
}

return view.extend({
	handleSave: null, handleSaveApply: null, handleReset: null,
	render: function() {
		var latest = {}, pending = false, lastServers = '', lastID = '', maximum = 2500, generation = 0;
		var refreshTimer = null;
		var down = E('strong', {}, '—'), up = E('strong', {}, '—');
		var ping = E('strong', {}, '—'), jitter = E('strong', {}, '—');
		var reading = E('div', { 'class': 'zst-reading' }, '—');
		var phase = E('div', { 'class': 'zst-phase', role: 'status', 'aria-live': 'polite' }, _('Ready to test'));
		var caption = E('div', { 'class': 'zst-caption' }, _('LIVE SPEED'));
		var badge = E('span', { 'class': 'zst-badge' }, _('READY'));
		var serverLabel = E('strong', {}, _('Automatic · lowest latency'));
		var deviceLabel = E('strong', {}, _('Current router connection'));
		var usage = E('span', {}, _('No test has run yet'));
		var notice = E('div', { 'class': 'zst-notice', role: 'alert' });
		var connection = E('select', { 'aria-label': _('Connection to test') }, [
			E('option', { value: 'default' }, _('Current connection (including VPN)')),
			E('option', { value: 'wan' }, _('Wired WAN')),
			E('option', { value: 'wan_sfp' }, _('SFP WAN')),
			E('option', { value: '4_1' }, _('Modem 1 / 5G1')),
			E('option', { value: '2_1' }, _('Modem 2 / 5G2'))
		]);
		var server = E('select', { 'aria-label': _('Speedtest.net server') }, [
			E('option', { value: '' }, _('Automatic · lowest latency')),
			E('option', { value: 'custom' }, _('Use a server ID…'))
		]);
		var serverInput = E('input', { type: 'text', inputmode: 'numeric', pattern: '[0-9]{1,8}',
			maxlength: 8, placeholder: _('Speedtest.net server ID'), 'aria-label': _('Speedtest.net server ID'), hidden: '' });
		server.addEventListener('change', function() { serverInput.hidden = server.value !== 'custom'; });
		connection.addEventListener('change', function() {
			while (server.options.length > 2) server.remove(2);
			server.value = ''; serverInput.hidden = true; lastServers = '';
		});
		var consent = E('input', { type: 'checkbox', change: function() { buttons(); } });
		var run = E('button', { 'class': 'zst-go', click: function() { begin('test'); }, disabled: '' }, _('GO'));
		var stop = E('button', { 'class': 'zst-stop', disabled: '', click: function() {
			if (!latest.running || !latest.id) return;
			stop.disabled = true;
			cancel(latest.id).then(function(r) {
				if (!r.ok) throw new Error(r.error || _('Cannot stop test'));
				phase.textContent = _('Stopping test…');
			}).catch(function(e) { notice.textContent = e.message; stop.disabled = false; });
		}}, _('Stop test'));
		var find = E('button', { 'class': 'zst-secondary', click: function() { begin('servers'); } }, _('Find nearby servers'));

		var ticks = svg('g', { 'class': 'zst-ticks' });
		var progress = svg('path', { fill: 'none', 'class': 'zst-arc', 'stroke-width': 9, 'stroke-linecap': 'round' });
		var needle = svg('g', { 'class': 'zst-needle' }, [
			svg('path', { d: 'M 194 188 L 207 180 L 319 309 L 202 197 Z' }),
			svg('circle', { cx: 200, cy: 190, r: 9 })
		]);
		var gauge = svg('svg', { viewBox: '0 0 400 350', 'aria-hidden': 'true' }, [
			svg('path', { d: arc(135, 405, 158), fill: 'none', 'class': 'zst-track', 'stroke-width': 9 }),
			svg('path', { d: arc(135, 405, 139), fill: 'none', 'class': 'zst-inner', 'stroke-width': 1 }),
			ticks, progress, needle
		]);
		var downloadLine = svg('path', { 'class': 'zst-down-line', fill: 'none', 'stroke-width': 2.5 });
		var uploadLine = svg('path', { 'class': 'zst-up-line', fill: 'none', 'stroke-width': 2.5 });
		var graph = svg('svg', { viewBox: '0 0 800 110', preserveAspectRatio: 'none', role: 'img',
			'aria-label': _('Measured speed over time; cyan download, purple upload') }, [
			svg('path', { d: 'M0 25H800 M0 60H800 M0 95H800', 'class': 'zst-grid' }), downloadLine, uploadLine
		]);
		var graphMax = E('span', {}, '—');
		var graphTime = E('span', {}, _('Elapsed time'));
		function scale() {
			while (ticks.firstChild) ticks.removeChild(ticks.firstChild);
			[0, 5, 10, 20, 50, 100, 250, 500, 1000, 2500].forEach(function(t) {
				var value = t * maximum / 2500, angle = 135 + 270 * fraction(value, maximum);
				var a = point(angle, 145), b = point(angle, 151), label = point(angle, t === 0 || t === 2500 ? 177 : 122);
				ticks.appendChild(svg('path', { d: 'M' + a.join(' ') + 'L' + b.join(' ') }));
				ticks.appendChild(svg('text', { x: label[0], y: label[1] + 4, 'text-anchor': 'middle' },
					[value >= 1000 ? number(value / 1000, value % 1000 ? 1 : 0) + 'k' : String(value)]));
			});
		}
		scale();
		function meter(value, upload) {
			if (typeof value !== 'number' || !isFinite(value) || value < 0) value = null;
			if (value != null && value > maximum) { maximum = Math.pow(10, Math.ceil(Math.log10(value))); scale(); }
			var f = value == null ? 0 : fraction(value, maximum);
			progress.setAttribute('d', f > 0 ? arc(135, 135 + 270 * f, 158) : '');
			// The template needle points to 45 degrees; rotate to 135…405.
			needle.style.transform = 'rotate(' + (90 + 270 * f) + 'deg)';
			needle.style.opacity = value == null ? '0.2' : '1';
			panel.classList.toggle('zst-uploading', !!upload);
			reading.textContent = number(value);
		}
		function buttons() {
			var busy = pending || !!latest.running;
			run.disabled = busy || !consent.checked;
			stop.disabled = !latest.running;
			find.disabled = busy;
			connection.disabled = server.disabled = serverInput.disabled = busy;
			run.textContent = latest.phase === 'complete' ? _('TEST AGAIN') : _('GO');
		}
		function begin(mode) {
			if (pending || latest.running) return;
			var id = server.value === 'custom' ? serverInput.value.trim() : server.value;
			if (mode === 'test' && id && !/^[0-9]{1,8}$/.test(id)) {
				notice.textContent = _('Enter a numeric Speedtest.net server ID.'); return;
			}
			pending = true; generation++; notice.textContent = ''; buttons();
			start(connection.value, mode === 'servers' ? '' : id, mode, consent.checked).then(function(r) {
				if (!r.ok) throw new Error(r.error || _('Unable to start test'));
				apply(r);
			}).catch(function(e) { notice.textContent = e.message; }).finally(function() { pending = false; buttons(); });
		}
		function chart(samples, elapsed) {
			var max = 10, end = Math.max(30, elapsed || 0);
			samples.forEach(function(s) { if (typeof s.mbps === 'number' && isFinite(s.mbps)) max = Math.max(max, s.mbps); });
			['download', 'upload'].forEach(function(direction, index) {
				var points = samples.filter(function(s) { return s.phase === direction && s.mbps >= 0 && isFinite(s.mbps); });
				var d = points.map(function(s, i) {
					return (i ? 'L' : 'M') + (800 * s.seconds / end).toFixed(2) + ' ' + (100 - 90 * s.mbps / max).toFixed(2);
				}).join(' ');
				(index ? uploadLine : downloadLine).setAttribute('d', d);
			});
			graphMax.textContent = number(max, 0) + ' Mbps';
			graphTime.textContent = number(end, 0) + ' s';
		}
		var phases = {
			idle: _('Ready to test'), discovery: _('Finding Speedtest.net servers…'),
			ping: _('Measuring server latency…'), download: _('Testing download speed…'),
			upload: _('Testing upload speed…'), complete: _('Test complete'),
			ready: _('Servers found — choose one or use automatic selection'),
			cancelled: _('Test stopped — partial measurements are not a completed result'),
			error: _('Test could not complete')
		};
		function apply(r) {
			latest = r;
			if (r.id && r.id !== lastID) {
				lastID = r.id; maximum = 2500; scale();
				if (r.interface) connection.value = r.interface;
			}
			phase.textContent = phases[r.phase] || _('Ready to test');
			badge.textContent = r.running ? _('LIVE') : r.phase === 'complete' ? _('COMPLETE') : r.phase === 'error' ? _('ERROR') : r.phase === 'cancelled' ? _('STOPPED') : _('READY');
			badge.classList.toggle('zst-is-live', !!r.running);
			notice.textContent = r.error || '';
			down.textContent = number(r.running && r.phase === 'download' ? r.live_mbps : r.download_mbps);
			up.textContent = number(r.running && r.phase === 'upload' ? r.live_mbps : r.upload_mbps);
			ping.textContent = number(r.ping_ms, 1); jitter.textContent = number(r.jitter_ms, 1);
			caption.textContent = r.phase === 'complete' ? _('DOWNLOAD RESULT') :
				r.phase === 'upload' ? _('LIVE UPLOAD') : _('LIVE DOWNLOAD');
			meter(r.phase === 'complete' ? r.download_mbps : r.running ? r.live_mbps : null, r.phase === 'upload');
			chart(r.samples || [], r.elapsed);
			if (r.selected) serverLabel.textContent = r.selected.sponsor + ' · ' + r.selected.name + ', ' + r.selected.country + ' (#' + r.selected.id + ')';
			else serverLabel.textContent = _('Automatic · lowest latency');
			deviceLabel.textContent = r.device || _('Current router connection (may include VPN)');
			usage.textContent = r.id ? _('Elapsed: %s s · Test payload: %s MB').format(number(r.elapsed, 1), number((r.bytes || 0) / 1e6, 1)) : _('No test has run yet');
			if (r.servers && r.servers.length && r.interface === connection.value) {
				var key = r.interface + ':' + r.servers.map(function(s) { return s.id; }).join(',');
				if (key !== lastServers) {
					var previous = server.value;
					while (server.options.length > 2) server.remove(2);
					r.servers.forEach(function(s) {
						server.appendChild(E('option', { value: s.id }, s.sponsor + ' · ' + s.name + ' (#' + s.id + ')'));
					});
					server.value = previous; lastServers = key;
				}
			}
			buttons();
		}
		function metric(label, val, unit, cls) {
			return E('div', { 'class': 'zst-metric ' + (cls || '') }, [
				E('span', { 'class': 'zst-metric-label' }, label),
				E('div', {}, [val, E('span', { 'class': 'zst-unit' }, unit)])
			]);
		}
		var panel = E('section', { 'class': 'zst-panel' }, [
			E('link', { rel: 'stylesheet', href: L.resource('view/speedtest-lite/style.css') }),
			E('header', { 'class': 'zst-header' }, [
				E('div', {}, [E('div', { 'class': 'zst-eyebrow' }, _('ROUTER DIAGNOSTICS')),
					E('h2', {}, _('Speed test')), E('p', {}, _('Real transfers. Live measurements. Speedtest.net servers.'))]), badge
			]),
			E('div', { 'class': 'zst-results' }, [
				metric('↓ ' + _('DOWNLOAD'), down, 'Mbps', 'zst-download'),
				metric('↑ ' + _('UPLOAD'), up, 'Mbps', 'zst-upload'),
				metric(_('PING'), ping, 'ms'), metric(_('JITTER'), jitter, 'ms')
			]),
			E('div', { 'class': 'zst-instrument' }, [
				E('div', { 'class': 'zst-gauge' }, [gauge, E('div', { 'class': 'zst-value' }, [caption, reading, E('div', {}, 'Mbps')])]),
				phase, E('div', { 'class': 'zst-actions' }, [run, stop])
			]),
			E('div', { 'class': 'zst-chart' }, [
				E('div', { 'class': 'zst-chart-labels' }, [E('span', {}, _('MEASURED THROUGHPUT')), graphMax]),
				graph, E('div', { 'class': 'zst-chart-labels' }, [
					E('span', {}, [E('span', { 'class': 'zst-download' }, '● ' + _('Download')), '   ',
						E('span', { 'class': 'zst-upload' }, '● ' + _('Upload'))]), graphTime])
			]),
			E('div', { 'class': 'zst-controls' }, [
				E('label', {}, [E('span', {}, _('Connection')), connection]),
				E('label', {}, [E('span', {}, _('Test server')), server, serverInput]), find
			]),
			E('label', { 'class': 'zst-consent' }, [consent,
				E('span', {}, _('I understand a full test can use hundreds of MB or more than 1 GB of data and temporarily saturate this connection.'))]),
			notice,
			E('div', { 'class': 'zst-details' }, [
				E('div', {}, [E('span', {}, _('SERVER')), serverLabel]),
				E('div', {}, [E('span', {}, _('ROUTER INTERFACE')), deviceLabel]), usage
			]),
			E('footer', {}, [
				E('p', {}, _('Powered by speedtest-go · independent client, not the official Ookla app.')),
				E('p', {}, _('Measures this router’s Internet connection, not your phone’s Wi-Fi speed. Selected interfaces never fall back to the other modem. VPN and policy routing may affect the path.')),
				E('p', {}, _('Live values are measured by the test engine; final results are its stabilized rates. Background MultiWAN checks remain separate bounded samples.'))
			])
		]);
		meter(null, false);
		// LuCI's shared poll helper has a one-second cadence. The measurement
		// engine records a real sample every 250 ms, so use a serialized local
		// loop at that same cadence. Only one authenticated RPC can be in flight;
		// no speeds are interpolated or invented between engine samples.
		function refresh() {
			if (!panel.isConnected) {
				refreshTimer = null;
				return;
			}
			if (pending) {
				refreshTimer = window.setTimeout(refresh, 250);
				return;
			}
			var requestedGeneration = generation;
			status().then(function(r) {
				if (requestedGeneration === generation) apply(r);
			}).catch(function(e) {
				if (requestedGeneration !== generation) return;
				notice.textContent = _('Live status unavailable: %s. The router test stops automatically within 90 seconds.').format(e.message);
				reading.textContent = '—';
			}).finally(function() {
				if (panel.isConnected)
					refreshTimer = window.setTimeout(refresh, 250);
			});
		}
		buttons();
		refreshTimer = window.setTimeout(refresh, 0);
		return panel;
	}
});
