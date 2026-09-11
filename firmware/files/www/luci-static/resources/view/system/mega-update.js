'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var repository = 'mfoster978/OpenWrt-ZBT-Z8803BE-Mega';
var callInfo = rpc.declare({ object: 'zbt.firmware', method: 'info', expect: {} });
var callCheck = rpc.declare({ object: 'zbt.firmware', method: 'check', params: ['page'], expect: {} });
var callPrepare = rpc.declare({ object: 'zbt.firmware', method: 'prepare', params: ['release_id'], expect: {} });
var callStatus = rpc.declare({ object: 'zbt.firmware', method: 'status', params: ['id'], expect: {} });
var callFlash = rpc.declare({ object: 'zbt.firmware', method: 'flash', params: ['id', 'confirmation', 'keep_settings'], expect: {} });
var callDiscard = rpc.declare({ object: 'zbt.firmware', method: 'discard', params: ['id'], expect: {} });

function text(value, fallback) { return typeof value === 'string' && value ? value : (fallback || '—'); }
function validConfirmation(value) { return typeof value === 'string' && /^[a-f0-9]{32}$/.test(value); }
function size(value) {
	if (!Number.isFinite(Number(value)) || Number(value) < 0) return '—';
	return (Number(value) / 1048576).toFixed(1) + ' MiB';
}
function releaseTime(value) {
	var date = new Date(value || '');
	if (!Number.isFinite(date.getTime())) return { relative: _('Release date unavailable'), exact: '—' };
	var seconds = Math.max(0, Math.floor((Date.now() - date.getTime()) / 1000));
	var amount, unit;
	if (seconds < 60) return { relative: _('Released less than a minute ago'), exact: date.toLocaleString() };
	if (seconds < 3600) { amount = Math.floor(seconds / 60); unit = amount === 1 ? _('minute ago') : _('minutes ago'); }
	else if (seconds < 86400) { amount = Math.floor(seconds / 3600); unit = amount === 1 ? _('hour ago') : _('hours ago'); }
	else if (seconds < 2592000) { amount = Math.floor(seconds / 86400); unit = amount === 1 ? _('day ago') : _('days ago'); }
	else if (seconds < 31536000) { amount = Math.floor(seconds / 2592000); unit = amount === 1 ? _('month ago') : _('months ago'); }
	else { amount = Math.floor(seconds / 31536000); unit = amount === 1 ? _('year ago') : _('years ago'); }
	return { relative: _('Released') + ' ' + amount + ' ' + unit, exact: date.toLocaleString() };
}
function compareVersion(a, b) {
	var x = /^firmware-(\d+)\.(\d+)$/.exec(a || '');
	var y = /^firmware-(\d+)\.(\d+)$/.exec(b || '');
	if (!x || !y) return null;
	for (var i = 1; i <= 2; i++) {
		var left = x[i].replace(/^0+(?=\d)/, '');
		var right = y[i].replace(/^0+(?=\d)/, '');
		if (left.length !== right.length) return left.length > right.length ? 1 : -1;
		if (left !== right) return left > right ? 1 : -1;
	}
	return 0;
}
function releaseUrl(value) {
	try {
		var u = new URL(value);
		if (u.origin === 'https://github.com' && !u.username && !u.password &&
			u.pathname.indexOf('/' + repository + '/releases/') === 0) return u.href;
	} catch (e) { /* Untrusted release metadata is never made into an unsafe link. */ }
	return 'https://github.com/' + repository + '/releases';
}
function replace(node, children) {
	while (node.firstChild) node.removeChild(node.firstChild);
	(Array.isArray(children) ? children : [children]).forEach(function(child) {
		if (child != null) node.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
	});
}
function icon() {
	var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
	svg.setAttribute('viewBox', '0 0 120 120');
	svg.setAttribute('aria-hidden', 'true');
	[['rect', { x: 19, y: 66, width: 82, height: 31, rx: 9 }],
	 ['path', { d: 'M33 66V45M87 66V45M50 81h28M33 81h1M60 16v35m-12-12 12 12 12-12' }],
	 ['path', { d: 'M27 32a47 47 0 0 1 66 0M37 43a32 32 0 0 1 46 0' }]].forEach(function(shape) {
		var el = document.createElementNS(svg.namespaceURI, shape[0]);
		Object.keys(shape[1]).forEach(function(k) { el.setAttribute(k, shape[1][k]); });
		svg.appendChild(el);
	});
	return svg;
}

return view.extend({
	load: function() {
		return callInfo().catch(function(error) { return { ok: false, eligible: false, error: error.message }; });
	},

	render: function(info) {
		var self = this;
		this.info = info || {};
		this.info.eligible = this.info.ok === true && this.info.eligible === true;
		this.installed = this.info.installed || {};
		this.writable = typeof L.hasViewPermission === 'function' && L.hasViewPermission();
		this.releases = [];
		this.page = 0;
		this.busy = false;
		this.job = null;
		this.accepted = false;
		this.reconnecting = false;
		this.progressBusy = false;

		var backupUrl = L.url('admin', 'system', 'flash');
		this.notice = E('div', { 'class': 'zfu-notice', role: 'status', 'aria-live': 'polite', hidden: '' });
		this.checkButton = E('button', { 'class': 'zfu-button zfu-primary', type: 'button', click: function() { return self.check(1); } }, _('Check for updates'));
		this.checkButton.disabled = !this.info.eligible;
		this.updateList = E('div', { 'class': 'zfu-release-list zfu-update-list' }, E('p', { 'class': 'zfu-empty' }, _('Check GitHub to see newer OpenWrt Mega Edition releases. Nothing is downloaded or flashed until you choose it.')));
		this.downgradeList = E('div', { 'class': 'zfu-release-list zfu-downgrade-list' }, E('p', { 'class': 'zfu-empty' }, _('Check GitHub to choose an older compatible release for a deliberate downgrade.')));
		this.moreButton = E('button', { 'class': 'zfu-button', type: 'button', hidden: '', click: function() { return self.check(self.page + 1); } }, _('Load older releases'));
		this.jobPanel = E('section', { 'class': 'zfu-card zfu-job', 'aria-label': _('Firmware download and validation'), role: 'status', 'aria-live': 'polite', tabindex: '-1', hidden: '' });
		var root = E('div', { 'class': 'zfu' }, [
			E('link', { rel: 'stylesheet', href: L.resource('view/system/mega-update.css') }),
			E('section', { 'class': 'zfu-hero' }, [
				E('div', {}, [E('span', { 'class': 'zfu-eyebrow' }, 'ZBT-Z8803BE / MEGA'),
					E('h2', {}, _('Your next upgrade. In one place.')),
					E('p', {}, _('Official project releases, verified on your router before you flash. Update your Mega build or choose a previous release without searching for the right file.')),
					E('a', { href: 'https://github.com/' + repository + '/releases', target: '_blank', rel: 'noopener noreferrer', 'class': 'zfu-hero-link' }, _('Browse releases on GitHub ↗'))]),
				E('div', { 'class': 'zfu-hero-art' }, icon())]),
			E('div', { 'class': 'zfu-top-grid' }, [
				E('section', { 'class': 'zfu-card' }, [E('span', { 'class': 'zfu-eyebrow' }, _('INSTALLED ON THIS ROUTER')),
					E('h3', { 'class': 'zfu-version' }, text(this.installed.version, _('Unknown build version')) + (this.installed.dirty ? ' + ' + _('local changes') : '')),
					E('dl', { 'class': 'zfu-facts' }, [E('dt', {}, _('Device')), E('dd', {}, text(this.info.board)),
						E('dt', {}, _('Variant')), E('dd', {}, text(this.installed.variant)),
						E('dt', {}, _('Built')), E('dd', {}, text(this.installed.built_at)),
						E('dt', {}, _('Source commit')), E('dd', {}, E('code', {}, text(this.installed.source_sha).slice(0, 12))),
						E('dt', {}, _('Local changes')), E('dd', {}, this.installed.dirty ? _('Included in this build') : _('None recorded'))]),
					E('p', { 'class': 'zfu-muted' }, _('Build identity comes from the installed firmware, not saved settings.'))]),
				E('section', { 'class': 'zfu-card zfu-check-card' }, [E('span', { 'class': 'zfu-eyebrow' }, _('YOU ARE IN CONTROL')),
					E('h3', {}, _('Check. Review. Verify. Flash.')),
					E('p', {}, _('Only this project’s compatible SquashFS sysupgrade images are offered. No factory, bootloader, source archive or force-flash option.')),
					this.checkButton, E('p', { 'class': 'zfu-muted' }, _('Checks contact GitHub. Downloads use your active Internet connection and may count against your data allowance.'))])]),
			this.notice,
			!this.writable ? E('p', { 'class': 'zfu-warning' }, _('Read-only access: you may inspect releases, but downloading and flashing requires firmware-update permission.')) : null,
			E('section', { 'class': 'zfu-safety' }, [E('h3', {}, _('Before you update')),
				E('p', {}, [_('Use stable power and a wired connection. '), E('a', { href: backupUrl }, _('Download a configuration backup')), _(' before continuing. Flashing restarts the router and disconnects the Internet. Installed add-on packages are not automatically retained.')]),
				E('p', {}, _('Older firmware can contain security issues, incompatible settings, or no updater at all. A downgrade is not an automatic recovery system; there is no guaranteed unattended rollback.'))]),
			this.jobPanel,
			E('section', { 'class': 'zfu-releases zfu-updates' }, [E('div', { 'class': 'zfu-section-head' }, [E('h3', {}, _('Updates')), E('span', { 'class': 'zfu-muted' }, _('Newer and currently installed Mega releases'))]), this.updateList]),
			E('section', { 'class': 'zfu-releases zfu-downgrades' }, [E('div', { 'class': 'zfu-section-head' }, [E('h3', {}, _('Older releases / downgrade')), E('span', { 'class': 'zfu-muted' }, _('Separate deliberate downgrade path'))]),
				E('p', { 'class': 'zfu-warning' }, _('Downgrading can restore old bugs or security issues and may make current settings incompatible. Back up first; fresh settings are selected by default.')),
				this.downgradeList, this.moreButton])
		].filter(function(x) { return x != null; }));
		if (!this.info.eligible) this.message(this.info.error || _('This installed firmware or router is not eligible for the Mega updater. Use Backup / Flash Firmware to install a verified compatible image manually.'), true);
		if (this.info.active_id) this.job = { id: this.info.active_id, phase: 'loading' };
		poll.add(function() { return self.refreshStatus(); }, 2);
		if (this.job) this.refreshStatus();
		return root;
	},

	message: function(message, error) {
		this.notice.hidden = !message;
		this.notice.classList.toggle('zfu-error', !!error);
		this.notice.textContent = message || '';
	},

	scrollToJob: function() {
		var panel = this.jobPanel;
		window.requestAnimationFrame(function() {
			if (!panel.hidden && typeof panel.scrollIntoView === 'function')
				panel.scrollIntoView({ behavior: 'smooth', block: 'center' });
		});
	},

	renderRequestProgress: function(release, error) {
		this.jobPanel.hidden = false;
		replace(this.jobPanel, [
			E('span', { 'class': 'zfu-eyebrow' }, _('VERIFIED UPGRADE PIPELINE')),
			E('h3', {}, error ? _('Download request failed') : _('Starting secure firmware download…')),
			E('p', {}, text(release && release.tag)),
			!error ? E('div', { 'class': 'zfu-progress zfu-request-progress', role: 'progressbar', 'aria-label': _('Starting firmware download'), 'aria-valuetext': _('Contacting the router update service') }, E('span')) : null,
			E('p', { 'class': error ? 'zfu-warning' : 'zfu-muted' }, error || _('Contacting the router update service and reserving temporary space. Nothing is being flashed.'))
		].filter(function(x) { return x != null; }));
		this.scrollToJob();
	},

	check: function(page) {
		var self = this;
		if (this.busy || !this.info.eligible) return Promise.resolve();
		this.busy = true;
		this.checkButton.disabled = true;
		this.moreButton.disabled = true;
		this.message(_('Checking published releases on GitHub…'));
		return callCheck(page).then(function(result) {
			if (!result.ok || !Array.isArray(result.releases)) throw new Error(result.error || _('Unable to check releases.'));
			self.page = Number(result.page) || page;
			if (page === 1) self.releases = [];
			if (result.latest_tag) self.latestTag = result.latest_tag;
			result.releases.forEach(function(release) {
				if (self.releases.every(function(r) { return r.id !== release.id; })) self.releases.push(release);
			});
			self.moreButton.hidden = !result.has_more;
			self.renderReleases();
			var latest = self.releases.find(function(r) { return r.compatible && r.tag === self.latestTag; });
			var delta = latest && compareVersion(latest.tag, self.installed.version);
			if (self.installed.dirty) self.message(_('This installed build includes local changes. Its version tag does not identify an unmodified release; installing a published release will replace those firmware changes.'));
			else if (latest && latest.tag === self.installed.version) self.message(_('You have the latest compatible published release.'));
			else if (latest && delta > 0) self.message(_('A newer Mega release is available. Review its notes before downloading.'));
			else self.message(_('Release list updated. Version ordering is only known for firmware-N.A build tags; review any other release manually.'));
		}).catch(function(error) { self.message(error.message, true); }).finally(function() {
			self.busy = false;
			self.checkButton.disabled = !self.info.eligible || !!self.accepted;
			self.moreButton.disabled = !!self.accepted;
			self.renderSelections();
		});
	},

	renderReleases: function() {
		var self = this;
		var updates = this.releases.filter(function(release) { return self.relation(release).kind !== 'downgrade'; });
		var downgrades = this.releases.filter(function(release) { return self.relation(release).kind === 'downgrade'; });
		this.renderReleaseGroup('update', updates);
		this.renderReleaseGroup('downgrade', downgrades);
	},

	renderReleaseGroup: function(kind, releases) {
		var self = this;
		var isDowngrade = kind === 'downgrade';
		var list = isDowngrade ? this.downgradeList : this.updateList;
		var previous = isDowngrade ? this.downgradeSelect : this.releaseSelect;
		var selected = previous && previous.value;
		if (!releases.length) {
			replace(list, E('p', { 'class': 'zfu-empty' }, isDowngrade ? _('No older releases are loaded. Use Load older releases to search further back.') : _('No newer or current published releases were returned.')));
			if (isDowngrade) { this.downgradeSelect = null; this.downgradePanel = null; }
			else { this.releaseSelect = null; this.selectedPanel = null; }
			return;
		}
		var options = releases.map(function(release) {
			var relation = self.relation(release);
			var age = releaseTime(release.published_at);
			return E('option', { value: String(release.id) }, text(release.tag) + ' — ' + age.relative + (release.compatible ? '' : ' — ' + _('Unavailable')));
		});
		var id = isDowngrade ? 'zfu-downgrade-release' : 'zfu-release';
		var panel = E('div', { 'class': 'zfu-selected' });
		var select = E('select', { id: id, 'aria-label': isDowngrade ? _('Older release to install') : _('Update release to install'), change: function() { self.renderSelected(select, panel); } }, options);
		if (selected && releases.some(function(r) { return String(r.id) === selected; })) select.value = selected;
		if (isDowngrade) { this.downgradeSelect = select; this.downgradePanel = panel; }
		else { this.releaseSelect = select; this.selectedPanel = panel; }
		replace(list, [E('label', { 'class': 'zfu-select-label', for: id }, isDowngrade ? _('Select an older release to downgrade') : _('Select a newer release to update or the current release to reinstall')), select, panel]);
		this.renderSelected(select, panel);
	},

	relation: function(release) {
		if (this.installed.dirty) return { kind: 'unknown', label: _('Locally modified build') };
		if (release.tag === this.installed.version) return { kind: 'same', label: _('Installed version') };
		var delta = compareVersion(release.tag, this.installed.version);
		if (delta === null) return { kind: 'unknown', label: _('Version order unknown') };
		if (delta === 0) return { kind: 'same', label: _('Installed version') };
		if (delta < 0) return { kind: 'downgrade', label: _('Older version / downgrade') };
		return { kind: 'upgrade', label: _('Newer version / upgrade') };
	},

	renderSelections: function() {
		if (this.releaseSelect && this.selectedPanel) this.renderSelected(this.releaseSelect, this.selectedPanel);
		if (this.downgradeSelect && this.downgradePanel) this.renderSelected(this.downgradeSelect, this.downgradePanel);
	},

	renderSelected: function(select, panel) {
		var self = this;
		select = select || this.releaseSelect;
		panel = panel || this.selectedPanel;
		if (!select || !panel) return;
		var release = this.releases.find(function(r) { return String(r.id) === select.value; });
		if (!release) return;
		var relation = this.relation(release);
		var released = releaseTime(release.published_at);
		var button = E('button', { type: 'button', 'class': 'zfu-button zfu-primary zfu-download', click: function() { return self.prepare(release); } }, relation.kind === 'downgrade' ? _('Download & verify downgrade') : _('Download & verify'));
		button.disabled = !this.writable || !this.info.eligible || !release.compatible || !!this.job || this.busy || this.accepted;
		var image = release.image || {};
		replace(panel, E('article', { 'class': 'zfu-card zfu-release' }, [
			E('div', { 'class': 'zfu-release-heading' }, [E('div', {}, [E('span', { 'class': 'zfu-eyebrow' }, release.tag === this.latestTag ? _('LATEST PUBLISHED RELEASE') : _('PROJECT RELEASE')), E('h3', {}, text(release.name, release.tag))]), E('span', { 'class': 'zfu-badge' }, relation.label)]),
			E('p', { 'class': 'zfu-release-age' }, [released.relative, E('time', { datetime: text(release.published_at), title: released.exact }, released.exact)]),
			E('p', { 'class': 'zfu-muted' }, text(release.tag)),
			!release.compatible ? E('p', { 'class': 'zfu-warning' }, text(release.reason, _('This release has no compatible verified upgrade image.'))) : null,
			relation.kind === 'downgrade' ? E('p', { 'class': 'zfu-warning' }, _('Downgrade selected. Starting with fresh settings is recommended. Make a backup and check the older release’s limitations.')) : null,
			relation.kind === 'unknown' ? E('p', { 'class': 'zfu-warning' }, _('The updater cannot establish whether this release is older or newer than the installed build. Settings preservation will be off by default.')) : null,
			release.legacy ? E('p', { 'class': 'zfu-warning' }, _('Legacy release: review its notes carefully. Additional compatibility checks are required before it can be flashed.')) : null,
			E('h4', {}, _('What this release offers')),
			E('pre', { 'class': 'zfu-notes' }, text(release.body, _('No release notes were published.'))),
			E('div', { 'class': 'zfu-image-info' }, [E('span', {}, _('Upgrade image')), E('code', {}, text(image.name)), E('span', {}, size(image.size))]),
			E('div', { 'class': 'zfu-actions' }, [button, E('a', { href: releaseUrl(release.html_url), target: '_blank', rel: 'noopener noreferrer' }, _('Read on GitHub ↗'))])
		].filter(function(x) { return x != null; })));
	},

	prepare: function(release) {
		var self = this;
		if (!this.writable || !this.info.eligible || !release.compatible || this.busy || this.job || this.accepted) return Promise.resolve();
		this.busy = true;
		this.renderSelections();
		this.message(_('Requesting this release’s exact upgrade image. This does not flash the router.'));
		this.renderRequestProgress(release);
		return callPrepare(release.id).then(function(result) {
			if (!result.ok || typeof result.id !== 'string' || !result.id) throw new Error(result.error || _('Download request was not accepted.'));
			self.job = { id: result.id, phase: 'downloading', release: release };
			self.message('');
			self.renderJob();
			self.scrollToJob();
			return self.refreshStatus();
		}).catch(function(error) {
			self.message(error.message, true);
			self.renderRequestProgress(release, error.message);
		}).finally(function() { self.busy = false; self.renderSelections(); });
	},

	refreshStatus: function() {
		var self = this;
		if (!this.job || this.progressBusy || this.reconnecting) return Promise.resolve();
		var requestedId = this.job.id;
		this.progressBusy = true;
		return callStatus(requestedId).then(function(result) {
			if (!self.job || self.job.id !== requestedId) return;
			if (!result.ok || result.id !== requestedId) {
				self.message(result.error || _('Invalid download status response. Keep power connected and retry the status check before taking any other action.'), true);
				return;
			}
			self.job = result;
			if (result.phase === 'error' && self.accepted) {
				self.accepted = false;
				self.checkButton.disabled = !self.info.eligible;
				self.moreButton.disabled = false;
				ui.hideModal();
				self.message(result.error || (result.flash_started ? _('Flashing was started, but its outcome cannot be confirmed. Keep power connected and check the router before taking further action.') : _('Flashing was rejected. The router has not been told to reboot.')), true);
			}
			self.renderJob();
			if (result.phase === 'discarded') { self.job = null; self.jobPanel.hidden = true; self.renderSelections(); }
		}).catch(function(error) {
			if (self.accepted) {
				// Only an explicitly accepted flash may turn a lost connection into a reconnect wait.
				self.reconnecting = true;
				if (self.flashKeep) ui.awaitReconnect(window.location.host);
				else ui.awaitReconnect('192.168.1.1', 'openwrt.lan');
			} else self.message(_('Could not read download status: ') + error.message, true);
		}).finally(function() { self.progressBusy = false; });
	},

	renderJob: function() {
		var self = this;
		var job = this.job;
		if (!job) { this.jobPanel.hidden = true; return; }
		this.jobPanel.hidden = false;
		var phase = job.phase;
		var labels = { loading: _('Loading download status…'), downloading: _('Downloading upgrade image'), validating: _('Verifying checksum and device compatibility'), ready: _('Verified and ready to review'), flashing: _('Flash request accepted'), error: _('Download or validation failed'), discarded: _('Download discarded') };
		if (job.flash_started && phase === 'error') labels.error = _('Flash outcome requires attention');
		var total = Number(job.total) || 0;
		var bytes = Math.max(0, Number(job.bytes) || 0);
		var showProgress = phase === 'loading' || phase === 'downloading' || phase === 'validating';
		var progress = showProgress ? E('progress', { 'aria-label': phase === 'validating' ? _('Firmware validation progress') : _('Firmware download progress') }) : null;
		var percent = total > 0 ? Math.min(100, Math.round(bytes * 100 / total)) : null;
		if (progress && phase === 'downloading' && total > 0) {
			progress.max = total;
			progress.value = Math.min(bytes, total);
		}
		var action = E('button', { 'class': 'zfu-button zfu-danger zfu-review', type: 'button', click: function() { self.confirm(); } }, this.relation(job.release || {}).kind === 'downgrade' ? _('Review downgrade…') : _('Review update…'));
		action.disabled = !this.writable || phase !== 'ready' || !validConfirmation(job.confirmation) || this.accepted || this.busy;
		var discard = E('button', { 'class': 'zfu-button zfu-discard', type: 'button', click: function() { return self.discard(); } }, phase === 'downloading' || phase === 'validating' ? _('Cancel download') : _('Discard image'));
		discard.disabled = !this.writable || this.accepted || this.busy || phase === 'flashing' || !!job.flash_started;
		replace(this.jobPanel, [E('span', { 'class': 'zfu-eyebrow' }, _('VERIFIED UPGRADE PIPELINE')),
			E('h3', {}, labels[phase] || _('Unknown download state')),
			E('p', {}, text(job.release && job.release.tag)),
			showProgress ? progress : null,
			phase === 'loading' ? E('p', { 'class': 'zfu-muted' }, _('Reading the current download state from the router…')) : null,
			phase === 'downloading' ? E('p', { 'class': 'zfu-muted zfu-progress-text' }, (percent != null ? percent + '% · ' : '') + size(bytes) + (total ? ' / ' + size(total) : ' ' + _('downloaded'))) : null,
			phase === 'validating' ? E('p', { 'class': 'zfu-muted zfu-progress-text' }, _('Download complete. Checking SHA256, image format, board identity and upgrade compatibility…')) : null,
			phase === 'ready' ? E('p', {}, _('The downloaded image passed server-side checks. Nothing has been flashed. Review the final confirmation to continue.')) : null,
			phase === 'ready' && !validConfirmation(job.confirmation) ? E('p', { 'class': 'zfu-warning' }, _('A valid confirmation token is missing. Discard this image and try again.')) : null,
			job.sha256 ? E('div', { 'class': 'zfu-checksum' }, [E('strong', {}, 'SHA256'), E('code', {}, String(job.sha256))]) : null,
			job.error ? E('p', { 'class': 'zfu-warning' }, String(job.error)) : null,
			job.flash_started && phase === 'error' ? E('p', { 'class': 'zfu-warning' }, _('The image is retained because flashing may have started. Deleting it or starting another update is blocked. Keep power connected; confirm that no upgrade is running before attempting recovery.')) : null,
			E('div', { 'class': 'zfu-actions' }, [phase === 'ready' ? action : null, discard].filter(function(x) { return x != null; }))
		].filter(function(x) { return x != null; }));
	},

	showFlashProgress: function(title, status, details) {
		ui.showModal(title, [E('div', { 'class': 'zfu zfu-flash-progress', role: 'status', 'aria-live': 'assertive' }, [
			E('div', { 'class': 'zfu-progress', role: 'progressbar', 'aria-label': status, 'aria-valuetext': status }, E('span')),
			E('h3', {}, status),
			E('p', {}, details),
			E('p', { 'class': 'zfu-warning' }, _('Keep stable power connected. Never unplug or restart the router while firmware is being written.'))
		])]);
	},

	discard: function() {
		var self = this;
		if (!this.writable || !this.job || this.accepted || this.busy || this.job.phase === 'flashing' || this.job.flash_started) return Promise.resolve();
		this.busy = true;
		this.renderJob();
		return callDiscard(this.job.id).then(function(result) {
			if (!result.ok) throw new Error(result.error || _('Unable to discard the image.'));
			self.job = null;
			self.jobPanel.hidden = true;
			self.message(_('Downloaded image discarded. No firmware was flashed.'));
		}).catch(function(error) { self.message(error.message, true); }).finally(function() { self.busy = false; self.renderSelections(); if (self.job) self.renderJob(); });
	},

	confirm: function() {
		var self = this;
		var job = this.job;
		if (!this.writable || !this.info.eligible || !job || job.phase !== 'ready' || !validConfirmation(job.confirmation) || this.accepted || this.busy) return;
		var relation = this.relation(job.release || {});
		var keep = E('input', { type: 'checkbox', id: 'zfu-keep' });
		keep.checked = job.allow_backup === true && (relation.kind === 'upgrade' || relation.kind === 'same');
		keep.disabled = job.allow_backup !== true;
		var acknowledged = E('input', { type: 'checkbox', id: 'zfu-ack' });
		var install = E('button', { type: 'button', 'class': 'zfu-button zfu-danger zfu-install', click: function() {
			if (!acknowledged.checked || self.busy || self.accepted || !self.writable || !self.job || self.job.id !== job.id || self.job.phase !== 'ready' || self.job.confirmation !== job.confirmation) return;
			self.busy = true;
			install.disabled = true;
			cancel.disabled = true;
			keep.disabled = true;
			acknowledged.disabled = true;
			self.showFlashProgress(_('Starting firmware update'), _('Submitting the verified image…'), _('The router is performing final checks before it accepts the flash. No restart has been assumed yet.'));
			var receivedReply = false;
			return callFlash(job.id, job.confirmation, job.allow_backup === true && keep.checked).then(function(result) {
				receivedReply = true;
				if (!result.ok || result.accepted !== true || result.id !== job.id) throw new Error(result.error || _('The flash request was not accepted.'));
				self.accepted = true;
				self.flashKeep = job.allow_backup === true && keep.checked;
				self.checkButton.disabled = true;
				self.showFlashProgress(_('Flashing requested — keep power connected'), _('Writing firmware and waiting for restart…'),
					(self.flashKeep ? _('The router accepted the image. After reboot, reconnect to your current router address. Downloaded add-on packages are not automatically restored. ') : _('The router accepted the image. Settings will be reset; after reboot, renew your network connection and open 192.168.1.1. ')) +
					_('This page will detect the disconnect and wait for the router to return.'));
				return self.refreshStatus();
			}).catch(function(error) {
				ui.hideModal();
				self.message(receivedReply ? error.message : _('The flash response was lost, so acceptance could not be confirmed. Keep power connected and check the router before trying again. ') + error.message, true);
			}).finally(function() { self.busy = false; self.renderJob(); self.renderSelections(); });
		} }, relation.kind === 'downgrade' ? _('Downgrade now') : relation.kind === 'same' ? _('Reinstall now') : _('Update now'));
		install.disabled = true;
		acknowledged.addEventListener('change', function() { install.disabled = !acknowledged.checked; });
		var cancel = E('button', { type: 'button', 'class': 'zfu-button', click: function() { ui.hideModal(); } }, _('Cancel'));
		ui.showModal(_('Confirm firmware flash'), [E('div', { 'class': 'zfu zfu-confirm' }, [
			E('p', {}, [_('Install '), E('strong', {}, text(job.release && job.release.tag)), _(' on this ZBT-Z8803BE router?')]),
			E('p', { 'class': 'zfu-warning' }, _('Flashing replaces the firmware and interrupts every connection. Use wired Ethernet and stable power. Do not close this page until the flash request is accepted, and never disconnect power during the update.')),
			E('p', {}, E('a', { href: L.url('admin', 'system', 'flash'), target: '_blank', rel: 'noopener noreferrer' }, _('Open Backup / Flash Firmware to save a backup first ↗'))),
			E('label', { 'class': 'zfu-checkbox', for: 'zfu-keep' }, [keep, E('span', {}, _('Keep current settings'))]),
			job.allow_backup !== true ? E('p', { 'class': 'zfu-warning' }, _('This image does not permit keeping settings. Your configuration will be reset.')) : null,
			relation.kind === 'downgrade' || relation.kind === 'unknown' ? E('p', { 'class': 'zfu-warning' }, _('Fresh settings are recommended for older firmware or unknown version ordering. Preserved settings may not be compatible. Older releases may not include this updater.')) : null,
			E('p', { 'class': 'zfu-muted' }, _('Keeping settings does not preserve packages you installed yourself. There is no guaranteed automatic rollback if the router fails to boot.')),
			E('label', { 'class': 'zfu-checkbox', for: 'zfu-ack' }, [acknowledged, E('span', {}, _('I have reviewed this release and understand that flashing restarts the router.'))]),
			E('div', { 'class': 'zfu-actions' }, [cancel, install])
		].filter(function(x) { return x != null; }))]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
