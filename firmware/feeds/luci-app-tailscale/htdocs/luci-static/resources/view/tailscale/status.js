'use strict';
'require view';
'require rpc';
'require poll';
var status = rpc.declare({ object: 'zbt.tailscale', method: 'status' });
var login = rpc.declare({ object: 'zbt.tailscale', method: 'login' });
var stop = rpc.declare({ object: 'zbt.tailscale', method: 'stop' });
return view.extend({
	handleSave: null, handleSaveApply: null, handleReset: null,
	render: function() {
		var state = E('p', {}, _('Loading…'));
		var message = E('p', {});
		var link = E('a', { target: '_blank', rel: 'noopener noreferrer', style: 'display:none' }, _('Open Tailscale sign-in'));
		function setLink(url) {
			if (/^https:\/\/login\.tailscale\.com\//.test(url || '')) { link.href = url; link.style.display = ''; }
			else { link.removeAttribute('href'); link.style.display = 'none'; }
		}
		poll.add(function() {
			return status().then(function(r) {
				state.textContent = _('Status: %s · Addresses: %s').format(r.state, r.ips.join(', ') || '—');
				setLink(r.state === 'Running' ? '' : r.auth_url);
				if (r.state === 'Running') message.textContent = '';
				else if (r.error && !r.auth_url) message.textContent = r.error;
			}).catch(function(e) { state.textContent = e.message; });
		}, 5);
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Tailscale')),
			E('p', {}, _('Private remote access. Sign in to your own account; no account credentials are baked into this image.')),
			state,
			E('button', { 'class': 'btn cbi-button-action', click: function(ev) {
				ev.target.disabled = true;
				login().then(function(r) { if (r.error) throw new Error(r.error); setLink(r.auth_url); message.textContent = r.auth_url ? _('Finish authorization using the link below.') : r.message; })
					.catch(function(e) { message.textContent = e.message; }).finally(function() { ev.target.disabled = false; });
			}}, _('Start / sign in')), ' ',
			E('button', { 'class': 'btn', click: function() { return stop(); } }, _('Disconnect')),
			message, link,
			E('p', {}, _('Subnet routes and exit-node settings remain available through the Tailscale CLI; this page does not change them.'))
		]);
	}
});
