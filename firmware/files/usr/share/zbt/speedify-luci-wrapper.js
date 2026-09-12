'use strict';
'require view';

/*
 * Hand the browser to the official Speedify application as a top-level page.
 * Keeping it in a LuCI iframe lets mobile browsers discard or recreate the
 * frame while the account provider is open, which restarts authentication.
 * The daemon session is scoped to the vendor application and the vendor route
 * always starts at its root instead of replaying a transient login hash.
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
		window.location.replace(app.href);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Opening Speedify…')),
			E('p', {}, _('The Speedify application is opening in this tab so account login can return to the same live session.'))
		]);
	}
});
