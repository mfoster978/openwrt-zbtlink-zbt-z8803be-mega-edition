'use strict';
'require view';

// Speedify owns account sign-in, activation and account-state updates.
// This wrapper only embeds its official UI and supplies router-session auth.
return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
	load: function() {},
	render: function() {
		var sessionId = (L.env && L.env.sessionid) || '';
		if (sessionId) {
			document.cookie = 'sfy-session=' + encodeURIComponent(sessionId) +
				'; path=/luci-app-speedify/; SameSite=Strict' +
				(window.location.protocol === 'https:' ? '; Secure' : '');
		}
		var app = new URL('/luci-app-speedify/view/index.html', window.location.origin);
		// Angular owns the fragment and can replace it on navigation. Keep the
		// non-secret transport parameters in the document query so reconnects
		// cannot fall back to port 9330 after an account/login route change.
		// The official sfy-ws-auth proxy accepts the scoped session cookie;
		// never put the router's session token in query strings or server logs.
		app.search = 'wsPort=match&wsEndpoint=/luci-app-speedify/api/ws&updateEndpoint=/luci-app-speedify/cgi/perform-update.sh&restartEndpoint=/luci-app-speedify/cgi/perform-restart.sh&resetEndpoint=/luci-app-speedify/cgi/perform-reset.sh';
		app.hash = '/';
		return E('div', { 'class': 'cbi-map', id: 'mega-speedify' }, [
			E('iframe', {
				id: 'mega-speedify-dashboard', title: _('Speedify dashboard'),
				src: app.href, style: 'display:block;width:100%;min-height:720px;height:80vh;border:0;',
				referrerpolicy: 'no-referrer', allowfullscreen: true
			})
		]);
	}
});
