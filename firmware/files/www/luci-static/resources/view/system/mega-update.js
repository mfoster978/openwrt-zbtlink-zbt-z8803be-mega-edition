'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var repository = 'mfoster978/openwrt-zbtlink-zbt-z8803be-mega-edition';
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
		this.releaseList = E('div', { 'class': 'zfu-release-list' }, E('p', { 'class': 'zfu-empty' }, _('Check GitHub to see the latest compatible Mega firmware and its release notes. Nothing is downloaded or flashed until you choose it.')));
		this.moreButton = E('button', { 'class': 'zfu-button', type: 'button', hidden: '', click: function() { return self.check(self.page + 1); } }, _('Load older releases'));
		this.jobPanel = E('section', { 'class': 'zfu-card zfu-job', 'aria-label': _('Firmware download and validation'), hidden: '' });
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
			E('section', { 'class': 'zfu-releases' }, [E('div', { 'class': 'zfu-section-head' }, [E('h3', {}, _('Available releases')), E('span', { 'class': 'zfu-muted' }, _('Mega firmware only'))]), this.releaseList, this.moreButton])
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
			if (self.releaseSelect) self.renderSelected();
		});
	},

	renderReleases: function() {
		var self = this;
		var selected = this.releaseSelect && this.releaseSelect.value;
		var releases = this.releases;
		if (!releases.length) { replace(this.releaseList, E('p', { 'class': 'zfu-empty' }, _('No published releases were returned.'))); return; }
		var options = releases.map(function(release) {
			var relation = self.relation(release);
			return E('option', { value: String(release.id) }, text(release.tag) + ' — ' + relation.label + (release.compatible ? '' : ' — ' + _('Unavailable')));
		});
		this.releaseSelect = E('select', { id: 'zfu-release', 'aria-label': _('Release to install'), change: function() { self.renderSelected(); } }, options);
		if (selected && releases.some(function(r) { return String(r.id) === selected; })) this.releaseSelect.value = selected;
		this.selectedPanel = E('div', { 'class': 'zfu-selected' });
		replace(this.releaseList, [E('label', { 'class': 'zfu-select-label', for: 'zfu-release' }, _('Select a release to upgrade, reinstall or downgrade')), this.releaseSelect, this.selectedPanel]);
		this.renderSelected();
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

	renderSelected: function() {
		var self = this;
		var release = this.releases.find(function(r) { return String(r.id) === self.releaseSelect.value; });
		if (!release) return;
		var relation = this.relation(release);
		var button = E('button', { type: 'button', 'class': 'zfu-button zfu-primary zfu-download', click: function() { return self.prepare(release); } }, relation.kind === 'downgrade' ? _('Download & verify downgrade') : _('Download & verify'));
		button.disabled = !this.writable || !this.info.eligible || !release.compatible || !!this.job || this.busy || this.accepted;
		var image = release.image || {};
		replace(this.selectedPanel, E('article', { 'class': 'zfu-card zfu-release' }, [
			E('div', { 'class': 'zfu-release-heading' }, [E('div', {}, [E('span', { 'class': 'zfu-eyebrow' }, release.tag === this.latestTag ? _('LATEST PUBLISHED RELEASE') : _('PROJECT RELEASE')), E('h3', {}, text(release.name, release.tag))]), E('span', { 'class': 'zfu-badge' }, relation.label)]),
			E('p', { 'class': 'zfu-muted' }, text(release.tag) + ' · ' + text(release.published_at)),
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
		this.renderSelected();
		this.message(_('Requesting this release’s exact upgrade image. This does not flash the router.'));
		return callPrepare(release.id).then(function(result) {
			if (!result.ok || typeof result.id !== 'string' || !result.id) throw new Error(result.error || _('Download request was not accepted.'));
			self.job = { id: result.id, phase: 'downloading', release: release };
			self.message('');
			self.renderJob();
			return self.refreshStatus();
		}).catch(function(error) { self.message(error.message, true); }).finally(function() { self.busy = false; self.renderSelected(); });
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
			if (result.phase === 'discarded') { self.job = null; self.jobPanel.hidden = true; if (self.releaseSelect) self.renderSelected(); }
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
		var progress = E('progress', { 'aria-label': _('Firmware download progress'), max: total > 0 ? total : 1 });
		if (total > 0) progress.value = Math.min(bytes, total);
		var action = E('button', { 'class': 'zfu-button zfu-danger zfu-review', type: 'button', click: function() { self.confirm(); } }, this.relation(job.release || {}).kind === 'downgrade' ? _('Review downgrade…') : _('Review update…'));
		action.disabled = !this.writable || phase !== 'ready' || !validConfirmation(job.confirmation) || this.accepted || this.busy;
		var discard = E('button', { 'class': 'zfu-button zfu-discard', type: 'button', click: function() { return self.discard(); } }, phase === 'downloading' || phase === 'validating' ? _('Cancel download') : _('Discard image'));
		discard.disabled = !this.writable || this.accepted || this.busy || phase === 'flashing' || !!job.flash_started;
		replace(this.jobPanel, [E('span', { 'class': 'zfu-eyebrow' }, _('VERIFIED UPGRADE PIPELINE')),
			E('h3', {}, labels[phase] || _('Unknown download state')),
			E('p', {}, text(job.release && job.release.tag)),
			phase === 'downloading' || phase === 'validating' ? progress : null,
			phase === 'downloading' ? E('p', { 'class': 'zfu-muted' }, size(bytes) + (total ? ' / ' + size(total) : ' ' + _('downloaded'))) : null,
			phase === 'ready' ? E('p', {}, _('The downloaded image passed server-side checks. Nothing has been flashed. Review the final confirmation to continue.')) : null,
			phase === 'ready' && !validConfirmation(job.confirmation) ? E('p', { 'class': 'zfu-warning' }, _('A valid confirmation token is missing. Discard this image and try again.')) : null,
			job.sha256 ? E('div', { 'class': 'zfu-checksum' }, [E('strong', {}, 'SHA256'), E('code', {}, String(job.sha256))]) : null,
			job.error ? E('p', { 'class': 'zfu-warning' }, String(job.error)) : null,
			job.flash_started && phase === 'error' ? E('p', { 'class': 'zfu-warning' }, _('The image is retained because flashing may have started. Deleting it or starting another update is blocked. Keep power connected; confirm that no upgrade is running before attempting recovery.')) : null,
			E('div', { 'class': 'zfu-actions' }, [phase === 'ready' ? action : null, discard].filter(function(x) { return x != null; }))
		].filter(function(x) { return x != null; }));
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
		}).catch(function(error) { self.message(error.message, true); }).finally(function() { self.busy = false; if (self.releaseSelect) self.renderSelected(); if (self.job) self.renderJob(); });
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
			var receivedReply = false;
			return callFlash(job.id, job.confirmation, job.allow_backup === true && keep.checked).then(function(result) {
				receivedReply = true;
				if (!result.ok || result.accepted !== true || result.id !== job.id) throw new Error(result.error || _('The flash request was not accepted.'));
				self.accepted = true;
				self.flashKeep = job.allow_backup === true && keep.checked;
				self.checkButton.disabled = true;
				ui.showModal(_('Flashing requested — keep power connected'), [E('p', { 'class': 'spinning' }, _('The router accepted the flash request. It will restart and disconnect this page. Do not switch it off.')),
					E('p', {}, self.flashKeep ? _('After reboot, reconnect to your current router address. Downloaded add-on packages are not automatically restored.') : _('Settings will be reset. After reboot, renew your computer’s network connection and open 192.168.1.1.')),
					E('p', {}, _('This page will watch for a reported failure or a disconnect, then wait for the router to return. If it cannot reconnect automatically, wait several minutes before checking the router manually.'))]);
				return self.refreshStatus();
			}).catch(function(error) {
				ui.hideModal();
				self.message(receivedReply ? error.message : _('The flash response was lost, so acceptance could not be confirmed. Keep power connected and check the router before trying again. ') + error.message, true);
			}).finally(function() { self.busy = false; self.renderJob(); if (self.releaseSelect) self.renderSelected(); });
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
