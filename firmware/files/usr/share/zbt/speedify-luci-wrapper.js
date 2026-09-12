'use strict';
'require view';
'require rpc';
'require poll';

var getRouterUser = rpc.declare({ object: 'zbt.speedify', method: 'status', expect: {} });
var getRouterActivation = rpc.declare({ object: 'zbt.speedify', method: 'activation', expect: {} });

/* Keep the official dashboard inside LuCI. Account activation belongs to the
 * router daemon, not a transient browser tab or hash. Never mirror iframe
 * hashes into LuCI, reload on focus, or navigate away from the router menu.
 */
return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
	load: function() {},
	render: function() {
		var connectionParams = 'wsPort=match&wsEndpoint=/luci-app-speedify/api/ws&updateEndpoint=/luci-app-speedify/cgi/perform-update.sh&restartEndpoint=/luci-app-speedify/cgi/perform-restart.sh&resetEndpoint=/luci-app-speedify/cgi/perform-reset.sh';
		var sessionId = (L.env && L.env.sessionid) || '';
		if (sessionId) {
			connectionParams += '&wsToken=' + encodeURIComponent(sessionId);
			document.cookie = 'sfy-session=' + encodeURIComponent(sessionId) +
				'; path=/luci-app-speedify/; SameSite=Strict' +
				(window.location.protocol === 'https:' ? '; Secure' : '');
		}
		var app = new URL('/luci-app-speedify/view/index.html', window.location.origin);
		app.hash = '/?' + connectionParams;
		var frame = E('iframe', {
			id: 'mega-speedify-dashboard', title: _('Speedify dashboard'),
			src: app.href, style: 'display:block;width:100%;min-height:720px;height:80vh;border:0;',
			referrerpolicy: 'no-referrer'
		});
		var status = E('p', { id: 'mega-speedify-status', role: 'status' }, _('Checking the router Speedify account...'));
		var activation = E('div', { id: 'mega-speedify-activation' });
		var signedIn = null, checking = false;
		var begin = E('button', {
			'class': 'btn cbi-button-action', type: 'button', disabled: true,
			click: function() {
				begin.disabled = true;
				status.textContent = _('Requesting a sign-in link from this router...');
				return getRouterActivation().then(function(reply) {
					if (!reply || !reply.ok || !reply.url)
						throw new Error((reply && reply.message) || _('The router did not return a sign-in link.'));
					var target = new URL(reply.url);
					if (target.origin !== 'https://my.speedify.com' || target.pathname !== '/activate' ||
						target.username || target.password || target.searchParams.get('role') !== 'router')
						throw new Error(_('Invalid Speedify activation link.'));
					activation.replaceChildren(E('a', {
						href: target.href, target: '_blank', rel: 'noopener noreferrer',
						'class': 'btn cbi-button-action'
					}, _('Open Speedify sign-in')));
					status.textContent = _('Open the sign-in link, finish activation in the new tab, then return here. Waiting for the router to confirm sign-in.');
					begin.textContent = _('Request a new sign-in link');
				}).catch(function(error) {
					status.textContent = error.message;
				}).finally(function() { begin.disabled = false; });
			}
		}, _('Sign in this router'));
		function check() {
			if (checking) return Promise.resolve();
			checking = true;
			return getRouterUser().then(function(reply) {
				if (!reply || !reply.ok)
					throw new Error((reply && reply.message) || _('Cannot read the router Speedify account.'));
				var nowSignedIn = reply.signed_in === true;
				if (nowSignedIn) {
					status.textContent = _('Router signed in: ') + (reply.email || _('Speedify account'));
					activation.replaceChildren();
					if (signedIn === false) {
						var refreshed = new URL(app.href);
						refreshed.searchParams.set('account', String(Date.now()));
						frame.src = refreshed.href;
					}
				}
				else if (!activation.childNodes.length)
					status.textContent = _('This router is not signed in to Speedify. Use Sign in this router below.');
				signedIn = nowSignedIn;
				begin.hidden = nowSignedIn;
				begin.disabled = false;
			}).catch(function(error) {
				status.textContent = error.message;
				// Keep an existing activation link when the daemon temporarily
				// disappears. Do not present a network failure as a logout.
				begin.disabled = false;
			}).finally(function() { checking = false; });
		}
		var container = E('div', { 'class': 'cbi-map', id: 'mega-speedify' }, [
			E('h2', {}, _('Speedify')),
			E('div', { 'class': 'cbi-section' }, [
				status, begin, ' ', E('button', {
					type: 'button', 'class': 'btn', click: check
				}, _('Check sign-in')), activation,
				E('p', {}, _('Signing into the website alone does not activate the router. This link is issued by the router Speedify service. A router license may be required.')),
				E('a', { href: L.url('admin/about') }, _('Back to About'))
			]),
			frame
		]);
		poll.add(function() {
			if (!document.contains(container)) return Promise.resolve();
			return check();
		}, 5);
		check();
		return container;
	}
});
