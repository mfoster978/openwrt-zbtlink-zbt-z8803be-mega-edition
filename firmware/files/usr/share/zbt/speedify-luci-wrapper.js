'use strict';
'require uci';
'require view';

/*
 * Reviewed overlay for the official luci-app-speedify iframe wrapper.
 *
 * Speedify account authentication may open in another browser screen. The
 * vendor wrapper keeps its existing iframe alive when the user returns, so it
 * can continue displaying the signed-out state even though the local daemon
 * has received the login. Refresh the iframe after a real leave/return cycle.
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
		var backgroundedAt = 0;
		var lastRefreshAt = 0;
		var refreshTimer = null;

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

		function markBackgrounded() {
			if (!backgroundedAt) backgroundedAt = Date.now();
		}

		function refreshAfterAccountLogin() {
			refreshTimer = null;
			var now = Date.now();
			if (!backgroundedAt || now - backgroundedAt < 1500 || now - lastRefreshAt < 5000 ||
				document.visibilityState === 'hidden' || !document.documentElement.contains(speedifyuiframe)) return;

			backgroundedAt = 0;
			lastRefreshAt = now;
			try {
				speedifyuiframe.contentWindow.location.reload();
			} catch (e) {
				speedifyuiframe.src = iframeSrc;
			}
		}

		function scheduleRefresh() {
			if (refreshTimer != null) window.clearTimeout(refreshTimer);
			refreshTimer = window.setTimeout(refreshAfterAccountLogin, 350);
		}

		function visibilityChanged() {
			if (document.visibilityState === 'hidden') markBackgrounded();
			else scheduleRefresh();
		}

		window.addEventListener('blur', markBackgrounded);
		window.addEventListener('focus', scheduleRefresh);
		document.addEventListener('visibilitychange', visibilityChanged);
		window.addEventListener('pageshow', function(event) {
			if (event.persisted) {
				backgroundedAt = Date.now() - 2000;
				scheduleRefresh();
			}
		});

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
