'use strict';
'require uci';
'require view';

/*
 * Reviewed overlay for the official luci-app-speedify iframe wrapper.
 *
 * Speedify account authentication may open in another browser screen. Keep
 * the existing iframe alive when the user returns so its WebSocket and
 * in-memory authentication flow can observe the daemon's new account state.
 * Reloading here restarts the vendor login flow and loses that handoff.
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

		var outerHash = window.location.hash.replace(/^#\/?/, '');
		var iframePath = outerHash ? '/' + outerHash : '/';
		var separator = iframePath.indexOf('?') >= 0 ? '&' : '?';
		var iframeSrc = '/luci-app-speedify/view/index.html#' + iframePath + separator + connectionParams;
		var speedifyuiframe = E('iframe', {
			src: iframeSrc,
			style: 'width:100%; height:80vh; border:none;',
			frameborder: '0',
			allowfullscreen: 'true',
			title: _('Speedify management')
		});

		function stripConnectionParams(hash) {
			return hash.replace(/^#\/?/, '').replace(/[?&](?:wsPort|wsEndpoint|wsToken|updateEndpoint|resetEndpoint|restartEndpoint)=[^&]*/g, '').replace(/[?&]$/, '');
		}

		function syncOuterHash() {
			try {
				var innerHash = speedifyuiframe.contentWindow.location.hash || '';
				var path = stripConnectionParams(innerHash);
				var newHash = (path && path !== '/') ? '#/' + path : '';
				if (window.location.hash === newHash || (!window.location.hash && !newHash)) return;
				if (newHash)
					history.replaceState(null, '', window.location.pathname + window.location.search + newHash);
				else
					history.replaceState(null, '', window.location.pathname + window.location.search);
			} catch (e) {
				/* The same-origin frame may not be ready yet. */
			}
		}

		speedifyuiframe.addEventListener('load', function() {
			try {
				var iframeHistory = speedifyuiframe.contentWindow.history;
				var origPushState = iframeHistory.pushState;
				var origReplaceState = iframeHistory.replaceState;
				iframeHistory.pushState = function() {
					origPushState.apply(this, arguments);
					syncOuterHash();
				};
				iframeHistory.replaceState = function() {
					origReplaceState.apply(this, arguments);
					syncOuterHash();
				};
				speedifyuiframe.contentWindow.addEventListener('popstate', syncOuterHash);
				speedifyuiframe.contentWindow.addEventListener('hashchange', syncOuterHash);
			} catch (e) {
				/* Ignore a frame that is still transitioning. */
			}
		});

		return E('div', { 'class': 'cbi-map' }, [ speedifyuiframe ]);
	}
});
