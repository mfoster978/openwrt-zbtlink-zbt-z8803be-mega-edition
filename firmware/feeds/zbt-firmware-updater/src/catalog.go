// SPDX-License-Identifier: MIT
// This updater trusts one public repository, not URLs supplied by a browser.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const repository = "mfoster978/OpenWrt-ZBT-Z8803BE-Mega"
const repositoryID = "1362525334"
const boardName = "zbtlink,zbt-z8803be"
const apiRoot = "https://api.github.com/repos/" + repository
const webRoot = "https://github.com/" + repository
const megaImagePrefix = "OpenWrt-Mega-Edition-ZBT-Z8803BE"
const compatibilityImage = megaImagePrefix + "-sysupgrade.bin"
const manifestName = "mega-release-v2.json"
const legacyManifestName = "mega-release.json"
const maxImage = 128 << 20
const maxJSON = 4 << 20

var tagPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$`)
var legacyImagePattern = regexp.MustCompile(`^openwrt-(?:[A-Za-z0-9._-]+-)?mediatek-filogic-zbtlink_zbt-z8803be-squashfs-sysupgrade\.bin$`)
var shaPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var sourcePattern = regexp.MustCompile(`^[a-f0-9]{40}$`)
var versionPattern = regexp.MustCompile(`^firmware-([0-9]{1,12})\.([0-9]{1,6})$`)
var localPattern = regexp.MustCompile(`^local-[a-f0-9]{7,40}$`)

type Identity struct {
	Schema      int    `json:"schema"`
	Variant     string `json:"variant"`
	Repository  string `json:"repository"`
	Board       string `json:"board"`
	Version     string `json:"version"`
	SourceSHA   string `json:"source_sha"`
	BuiltAt     string `json:"built_at"`
	BaseVersion string `json:"base_version,omitempty"`
	Dirty       bool   `json:"dirty,omitempty"`
}
type Image struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256,omitempty"`
}
type Manifest struct {
	Identity
	Image Image `json:"image"`
}
type Asset struct {
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	URL   string `json:"browser_download_url"`
	State string `json:"state"`
}
type Release struct {
	ID          int64   `json:"id"`
	Tag         string  `json:"tag_name"`
	Name        string  `json:"name"`
	PublishedAt string  `json:"published_at"`
	Body        string  `json:"body"`
	HTMLURL     string  `json:"html_url"`
	Draft       bool    `json:"draft"`
	Prerelease  bool    `json:"prerelease"`
	Assets      []Asset `json:"assets"`
}
type ReleaseView struct {
	ID          int64  `json:"id"`
	Tag         string `json:"tag"`
	Name        string `json:"name"`
	PublishedAt string `json:"published_at"`
	Body        string `json:"body"`
	HTMLURL     string `json:"html_url"`
	Image       Image  `json:"image"`
	Compatible  bool   `json:"compatible"`
	Reason      string `json:"reason"`
	Legacy      bool   `json:"legacy"`
}
type Catalog struct{ Client *http.Client }

func versionedImageName(tag string) string {
	return megaImagePrefix + "-sysupgrade-" + tag + ".bin"
}

func githubClient() *http.Client {
	return &http.Client{
		Timeout:   12 * time.Minute,
		Transport: &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext, TLSHandshakeTimeout: 15 * time.Second, ResponseHeaderTimeout: 25 * time.Second, DisableCompression: true, MaxIdleConns: 2},
		CheckRedirect: func(r *http.Request, via []*http.Request) error {
			if len(via) > 5 {
				return errors.New("Too many GitHub redirects")
			}
			if !safeRedirect(r.URL, via) {
				return errors.New("Blocked redirect outside the configured GitHub API or release storage")
			}
			return nil
		},
	}
}

func safeHTTPSURL(u *url.URL) bool {
	return u != nil && u.Scheme == "https" && u.User == nil && u.Fragment == "" && u.Port() == ""
}

func pathAtOrBelow(path, root string) bool {
	return path == root || strings.HasPrefix(path, root+"/")
}

func canonicalAPIURL(u *url.URL) bool {
	return safeHTTPSURL(u) && u.Host == "api.github.com" && pathAtOrBelow(u.Path, "/repos/"+repository+"/releases")
}

func immutableAPIURL(u *url.URL) bool {
	return safeHTTPSURL(u) && u.Host == "api.github.com" && pathAtOrBelow(u.Path, "/repositories/"+repositoryID+"/releases")
}

func releaseAssetURL(u *url.URL) bool {
	if !safeHTTPSURL(u) {
		return false
	}
	switch u.Host {
	case "release-assets.githubusercontent.com", "objects.githubusercontent.com":
		return true
	}
	return u.Host == "github.com" && strings.HasPrefix(u.Path, "/"+repository+"/releases/download/")
}

// GitHub redirects a renamed repository's /repos/{owner}/{name} API route to
// its immutable numeric /repositories/{id} route. Keep redirect handling
// origin-aware: metadata requests may only follow that exact repository ID,
// while image requests may only enter GitHub's release-asset storage.
func safeRedirect(u *url.URL, via []*http.Request) bool {
	if len(via) == 0 || via[0] == nil || via[0].URL == nil {
		return false
	}
	if canonicalAPIURL(via[0].URL) {
		return canonicalAPIURL(u) || immutableAPIURL(u)
	}
	if releaseAssetURL(via[0].URL) {
		return releaseAssetURL(u)
	}
	return false
}

func safeInitialURL(u *url.URL) bool {
	if u.Scheme != "https" || u.User != nil || u.Fragment != "" || u.Port() != "" {
		return false
	}
	return canonicalAPIURL(u) || (u.Host == "github.com" && strings.HasPrefix(u.Path, "/"+repository+"/releases/download/"))
}
func (c Catalog) get(ctx context.Context, raw string) (*http.Response, error) {
	u, e := url.Parse(raw)
	if e != nil {
		return nil, errors.New("Invalid GitHub URL")
	}
	if !safeInitialURL(u) {
		return nil, errors.New("Release URL is outside the configured repository")
	}
	r, e := http.NewRequestWithContext(ctx, "GET", raw, nil)
	if e != nil {
		return nil, e
	}
	r.Header.Set("User-Agent", "ZBT-Mega-Firmware-Updater/1.0")
	r.Header.Set("Accept", "application/vnd.github+json")
	r.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, e := c.Client.Do(r)
	if e != nil {
		return nil, fmt.Errorf("GitHub HTTPS request failed: %w", e)
	}
	if resp.StatusCode != 200 {
		resp.Body.Close()
		if resp.StatusCode == 403 || resp.StatusCode == 429 {
			return nil, errors.New("GitHub rate limit or access restriction; try again later")
		}
		if resp.StatusCode == http.StatusNotFound {
			return nil, errors.New("GitHub could not find the Mega release repository or release. Token-free updates require the Mega repository to be public")
		}
		return nil, fmt.Errorf("GitHub returned HTTP %d", resp.StatusCode)
	}
	return resp, nil
}
func (c Catalog) bytes(ctx context.Context, raw string, limit int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 35*time.Second)
	defer cancel()
	r, e := c.get(ctx, raw)
	if e != nil {
		return nil, e
	}
	defer r.Body.Close()
	if r.ContentLength > limit {
		return nil, errors.New("Release metadata exceeds size limit")
	}
	b, e := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if e != nil {
		return nil, e
	}
	if int64(len(b)) > limit {
		return nil, errors.New("Release metadata exceeds size limit")
	}
	return b, nil
}
func decode(b []byte, dest any) error {
	d := json.NewDecoder(strings.NewReader(string(b)))
	if e := d.Decode(dest); e != nil {
		return errors.New("Invalid JSON returned by GitHub or local firmware metadata")
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return errors.New("Unexpected trailing JSON data")
	}
	return nil
}
func (c Catalog) release(ctx context.Context, id int64) (Release, error) {
	var r Release
	if id <= 0 || id > 9007199254740991 {
		return r, errors.New("Invalid release ID")
	}
	b, e := c.bytes(ctx, apiRoot+"/releases/"+strconv.FormatInt(id, 10), maxJSON)
	if e != nil {
		return r, e
	}
	e = decode(b, &r)
	if e == nil && r.ID != id {
		e = errors.New("GitHub release ID mismatch")
	}
	return r, e
}
func validIdentity(i Identity, local bool) error {
	if i.Dirty && !local {
		return errors.New("Dirty development builds cannot be published as verified Mega releases")
	}
	if i.Schema != 1 || i.Variant != "mega" || i.Repository != repository || i.Board != boardName || !sourcePattern.MatchString(i.SourceSHA) || (!versionPattern.MatchString(i.Version) && !(local && localPattern.MatchString(i.Version))) {
		return errors.New("Firmware identity does not match this Mega repository and board")
	}
	if _, e := time.Parse(time.RFC3339, i.BuiltAt); e != nil {
		return errors.New("Invalid firmware build date")
	}
	return nil
}
func selectAssets(r Release) (image Asset, manifest Asset, sums Asset, err error) {
	if r.Draft || r.Prerelease || r.ID <= 0 || !tagPattern.MatchString(r.Tag) || r.HTMLURL != webRoot+"/releases/tag/"+r.Tag {
		err = errors.New("Not a stable release in the Mega repository")
		return
	}
	if _, e := time.Parse(time.RFC3339, r.PublishedAt); e != nil {
		err = errors.New("Invalid release publication date")
		return
	}
	var versioned, compatibility, legacy, currentManifest, legacyManifest Asset
	seen := map[string]bool{}
	for _, a := range r.Assets {
		var dst *Asset
		switch {
		case a.Name == versionedImageName(r.Tag):
			dst = &versioned
		case a.Name == compatibilityImage:
			dst = &compatibility
		case legacyImagePattern.MatchString(a.Name):
			dst = &legacy
		case a.Name == manifestName:
			dst = &currentManifest
		case a.Name == legacyManifestName:
			dst = &legacyManifest
		case a.Name == "SHA256SUMS":
			dst = &sums
		default:
			continue
		}
		if dst.Name != "" || seen[a.Name] {
			err = errors.New("Ambiguous duplicate firmware or verification asset")
			return
		}
		if a.State != "uploaded" || a.Size <= 0 || a.URL != webRoot+"/releases/download/"+r.Tag+"/"+a.Name {
			err = errors.New("Invalid release asset URL or upload state")
			return
		}
		seen[a.Name] = true
		*dst = a
	}
	switch {
	case versioned.Name != "":
		image = versioned
	case compatibility.Name != "":
		image = compatibility
	default:
		image = legacy
	}
	if currentManifest.Name != "" {
		manifest = currentManifest
	} else {
		manifest = legacyManifest
	}
	if currentManifest.Name != "" && legacyManifest.Name != "" {
		err = errors.New("Ambiguous duplicate firmware or verification asset")
		return
	}
	if image.Name == "" || image.Size > maxImage {
		err = errors.New("Release has no supported device SquashFS sysupgrade image, or exceeds 128 MiB")
		return
	}
	if manifest.Name == "" && sums.Name == "" {
		err = errors.New("Release has no Mega manifest or SHA256SUMS")
		return
	}
	if manifest.Size > 64<<10 || sums.Size > 1<<20 {
		err = errors.New("Verification asset is too large")
	}
	return
}
func releaseView(r Release) ReleaseView {
	image, manifest, _, err := selectAssets(r)
	v := ReleaseView{ID: r.ID, Tag: r.Tag, Name: r.Name, PublishedAt: r.PublishedAt, Body: r.Body, HTMLURL: r.HTMLURL, Image: Image{Name: image.Name, Size: image.Size}, Compatible: err == nil, Legacy: manifest.Name == ""}
	if len(v.Body) > 65536 {
		v.Body = string([]rune(v.Body)[:min(16000, len([]rune(v.Body)))]) + "\n[Release notes truncated. Open GitHub for the full notes.]"
	}
	if err != nil {
		v.Reason = err.Error()
		v.HTMLURL = ""
	} else if v.Legacy {
		v.Reason = "Legacy release: checksum and device checks required; no independent Mega manifest."
	} else {
		v.Reason = "Mega manifest, checksum and device validation will run before flashing."
	}
	return v
}
func (c Catalog) check(ctx context.Context, page int) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if page == 0 {
		page = 1
	}
	if page < 1 || page > 20 {
		return nil, errors.New("Release page must be between 1 and 20")
	}
	b, e := c.bytes(ctx, fmt.Sprintf("%s/releases?per_page=20&page=%d", apiRoot, page), maxJSON)
	if e != nil {
		return nil, e
	}
	var rs []Release
	if e = decode(b, &rs); e != nil {
		return nil, e
	}
	if len(rs) > 20 {
		return nil, errors.New("Unexpected GitHub page size")
	}
	views := []ReleaseView{}
	for _, r := range rs {
		if !r.Draft && !r.Prerelease {
			views = append(views, releaseView(r))
		}
	}
	latest := ""
	if page == 1 && len(rs) > 0 {
		b, e = c.bytes(ctx, apiRoot+"/releases/latest", maxJSON)
		if e == nil {
			var r Release
			if decode(b, &r) == nil && releaseView(r).Compatible {
				latest = r.Tag
			}
		}
	}
	return map[string]any{"ok": true, "page": page, "has_more": len(rs) == 20 && page < 20, "latest_tag": latest, "releases": views}, nil
}
func checksumLine(b []byte, name string) (string, error) {
	found := ""
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if len(line) < 67 {
			continue
		}
		hash := line[:64]
		sep := line[64:66]
		if (sep == "  " || sep == " *") && line[66:] == name {
			if found != "" || !shaPattern.MatchString(strings.ToLower(hash)) {
				return "", errors.New("Ambiguous or malformed image checksum")
			}
			found = strings.ToLower(hash)
		}
	}
	if found == "" {
		return "", errors.New("Exact firmware filename is absent from SHA256SUMS")
	}
	return found, nil
}
func (c Catalog) verifiedMetadata(ctx context.Context, r Release) (ReleaseView, Asset, string, error) {
	im, ma, sums, e := selectAssets(r)
	v := releaseView(r)
	if e != nil {
		return v, im, "", e
	}
	if ma.Name != "" {
		b, e := c.bytes(ctx, ma.URL, 64<<10)
		if e != nil {
			return v, im, "", e
		}
		var m Manifest
		if e = decode(b, &m); e != nil {
			return v, im, "", e
		}
		if e = validIdentity(m.Identity, false); e != nil {
			return v, im, "", e
		}
		if m.Version != r.Tag || m.Image.Name != im.Name || m.Image.Size != im.Size || !shaPattern.MatchString(m.Image.SHA256) {
			return v, im, "", errors.New("Mega manifest does not match the selected release image")
		}
		return v, im, m.Image.SHA256, nil
	}
	b, e := c.bytes(ctx, sums.URL, 1<<20)
	if e != nil {
		return v, im, "", e
	}
	sum, e := checksumLine(b, im.Name)
	return v, im, sum, e
}
