// SPDX-License-Identifier: MIT
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

const imageName = "openwrt-mediatek-filogic-zbtlink_zbt-z8803be-squashfs-sysupgrade.bin"

func identityFixture(version string) Identity {
	return Identity{Schema: 1, Variant: "mega", Repository: repository, Board: boardName, Version: version, SourceSHA: strings.Repeat("a", 40), BuiltAt: "2026-09-10T00:00:00Z", BaseVersion: "v25.12.021"}
}
func releaseFixture(tag string, id int64, body []byte, legacy bool) Release {
	r := Release{ID: id, Tag: tag, Name: "Mega " + tag, PublishedAt: "2026-09-10T00:00:00Z", Body: "Fixes and additions", HTMLURL: webRoot + "/releases/tag/" + tag}
	asset := func(name string, size int64) Asset {
		return Asset{Name: name, Size: size, State: "uploaded", URL: webRoot + "/releases/download/" + tag + "/" + name}
	}
	r.Assets = []Asset{asset(imageName, int64(len(body)))}
	if legacy {
		r.Assets = append(r.Assets, asset("SHA256SUMS", 128))
	} else {
		r.Assets = append(r.Assets, asset("mega-release.json", 1024))
	}
	return r
}

type rewriteTransport struct {
	base     http.RoundTripper
	endpoint *url.URL
}

func (t rewriteTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	c := r.Clone(r.Context())
	u := *r.URL
	u.Scheme = t.endpoint.Scheme
	u.Host = t.endpoint.Host
	c.URL = &u
	c.Host = t.endpoint.Host
	resp, e := t.base.RoundTrip(c)
	if resp != nil {
		resp.Request = r
	}
	return resp, e
}

type fixture struct {
	service  Service
	image    []byte
	release  Release
	manifest Manifest
	mu       sync.Mutex
	commands [][]string
	spawns   [][2]string
	replies  map[string][]byte
	status   map[string]int
}

func newFixture(t *testing.T, legacy bool) *fixture {
	t.Helper()
	f := &fixture{image: []byte("Test firmware data: no real flash commands run in these tests."), replies: map[string][]byte{}, status: map[string]int{}}
	f.release = releaseFixture("firmware-101.1", 101, f.image, legacy)
	hash := sha256.Sum256(f.image)
	f.manifest = Manifest{Identity: identityFixture(f.release.Tag), Image: Image{Name: imageName, Size: int64(len(f.image)), SHA256: hex.EncodeToString(hash[:])}}
	f.refresh()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		b, exists := f.replies[r.URL.Path]
		code := f.status[r.URL.Path]
		f.mu.Unlock()
		if code != 0 {
			w.WriteHeader(code)
			return
		}
		if !exists {
			w.WriteHeader(404)
			return
		}
		w.Write(b)
	}))
	t.Cleanup(server.Close)
	u, _ := url.Parse(server.URL)
	client := githubClient()
	client.Transport = rewriteTransport{server.Client().Transport, u}
	client.Timeout = 3 * time.Second
	dir := t.TempDir()
	identityPath := filepath.Join(dir, "rom-identity.json")
	b, _ := json.Marshal(identityFixture("firmware-100.1"))
	if e := os.WriteFile(identityPath, b, 0600); e != nil {
		t.Fatal(e)
	}
	f.service = Service{Store: Store{Dir: filepath.Join(dir, "state")}, Catalog: Catalog{Client: client}, IdentityPath: identityPath, Space: func(int64) error { return nil }}
	f.service.Spawn = func(mode, id string) error {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.spawns = append(f.spawns, [2]string{mode, id})
		return nil
	}
	f.service.Run = func(_ context.Context, path string, args ...string) ([]byte, error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.commands = append(f.commands, append([]string{path}, args...))
		switch {
		case path == "/bin/ubus" && len(args) == 3 && args[2] == "board":
			return []byte(`{"board_name":"zbtlink,zbt-z8803be","rootfs_type":"squashfs"}`), nil
		case path == "/bin/ubus" && len(args) == 4 && args[2] == "validate_firmware_image":
			return []byte(`{"valid":true,"forceable":true,"allow_backup":true}`), nil
		case path == "/sbin/sysupgrade":
			return nil, nil
		default:
			return nil, errors.New("Unexpected fake command")
		}
	}
	return f
}
func (f *fixture) refresh() {
	f.mu.Lock()
	defer f.mu.Unlock()
	b, _ := json.Marshal(f.release)
	f.replies["/repos/"+repository+"/releases/"+fmt.Sprint(f.release.ID)] = b
	f.replies["/repos/"+repository+"/releases/latest"] = b
	b, _ = json.Marshal([]Release{f.release})
	f.replies["/repos/"+repository+"/releases"] = b
	b, _ = json.Marshal(f.manifest)
	f.replies["/"+repository+"/releases/download/"+f.release.Tag+"/mega-release.json"] = b
	sum := sha256.Sum256(f.image)
	f.replies["/"+repository+"/releases/download/"+f.release.Tag+"/SHA256SUMS"] = []byte(hex.EncodeToString(sum[:]) + "  " + imageName + "\n")
	f.replies["/"+repository+"/releases/download/"+f.release.Tag+"/"+imageName] = f.image
}
func (f *fixture) prepare(t *testing.T) State {
	t.Helper()
	v, e := f.service.prepare(context.Background(), f.release.ID)
	if e != nil {
		t.Fatal(e)
	}
	id := v["id"].(string)
	f.service.prepareWorker(id)
	st, e := f.service.status(id)
	if e != nil {
		t.Fatal(e)
	}
	return st
}

func TestVerifiedUpgradeAndSingleUseFlash(t *testing.T) {
	f := newFixture(t, false)
	st := f.prepare(t)
	if st.Phase != "ready" || !st.AllowBackup || st.Legacy || !idPattern.MatchString(st.Confirmation) {
		t.Fatalf("not ready: %+v", st)
	}
	if st.Total != int64(len(f.image)) || st.Bytes != st.Total {
		t.Fatal("missing progress")
	}
	if _, e := f.service.flash(context.Background(), st.ID, "00000000000000000000000000000000", true); e == nil {
		t.Fatal("wrong token accepted")
	}
	v, e := f.service.flash(context.Background(), st.ID, st.Confirmation, true)
	if e != nil || v["accepted"] != true {
		t.Fatal(v, e)
	}
	if _, e = f.service.flash(context.Background(), st.ID, st.Confirmation, true); e == nil {
		t.Fatal("replayed token accepted")
	}
	if _, e = f.service.discard(st.ID); e == nil {
		t.Fatal("flashing could be discarded")
	}
	f.service.flashWorker(st.ID)
	f.service.flashWorker(st.ID)
	flashes := 0
	for _, c := range f.commands {
		for _, arg := range c {
			if arg == "-F" || arg == "--force" {
				t.Fatal("force flag used")
			}
		}
		if c[0] == "/sbin/sysupgrade" && len(c) == 2 {
			flashes++
		}
	}
	if flashes != 1 {
		t.Fatalf("expected exactly one simulated flash, got %d (%v)", flashes, f.commands)
	}
	after, e := f.service.status(st.ID)
	if e != nil || after.Phase != "flashing" || after.Confirmation != "" || !after.FlashStarted {
		t.Fatal(after, e)
	}
}
func TestLegacyDowngradeUsesOnlyExactChecksumImage(t *testing.T) {
	f := newFixture(t, true)
	f.release = releaseFixture("firmware-90.1", 90, f.image, true)
	f.refresh()
	st := f.prepare(t)
	if st.Phase != "ready" || !st.Legacy {
		t.Fatal(st)
	}
	if _, e := f.service.flash(context.Background(), st.ID, st.Confirmation, false); e != nil {
		t.Fatal(e)
	}
	f.service.flashWorker(st.ID)
	last := f.commands[len(f.commands)-1]
	if len(last) != 3 || last[0] != "/sbin/sysupgrade" || last[1] != "-n" {
		t.Fatal(last)
	}
}
func TestEmptyReleaseListAndPagination(t *testing.T) {
	f := newFixture(t, false)
	path := "/repos/" + repository + "/releases"
	f.replies[path] = []byte(`[]`)
	v, e := f.service.Catalog.check(context.Background(), 1)
	if e != nil || v["has_more"] != false || len(v["releases"].([]ReleaseView)) != 0 {
		t.Fatal(v, e)
	}
	for _, p := range []int{-1, 21, 999} {
		if _, e = f.service.Catalog.check(context.Background(), p); e == nil {
			t.Fatal("bad page accepted")
		}
	}
}
func TestCheckMetadataAndResume(t *testing.T) {
	f := newFixture(t, false)
	v, e := f.service.Catalog.check(context.Background(), 1)
	if e != nil {
		t.Fatal(e)
	}
	r := v["releases"].([]ReleaseView)
	if v["latest_tag"] != f.release.Tag || len(r) != 1 || !r[0].Compatible || r[0].Legacy {
		t.Fatal(v)
	}
	st := f.prepare(t)
	info := f.service.info(context.Background())
	if info["active_id"] != st.ID || info["eligible"] != true {
		t.Fatal(info)
	}
}
func TestCatalogRejectsWrongRepositoryAndUnsafeAssets(t *testing.T) {
	cases := map[string]func(*Release){
		"wrong repo": func(r *Release) { r.HTMLURL = "https://github.com/other/repo/releases/tag/" + r.Tag },
		"draft":      func(r *Release) { r.Draft = true }, "prerelease": func(r *Release) { r.Prerelease = true },
		"tag traversal": func(r *Release) { r.Tag = "../main" },
		"foreign asset": func(r *Release) { r.Assets[0].URL = "https://evil.example/image.bin" },
		"plain HTTP":    func(r *Release) { r.Assets[0].URL = strings.Replace(r.Assets[0].URL, "https:", "http:", 1) },
		"userinfo": func(r *Release) {
			r.Assets[0].URL = strings.Replace(r.Assets[0].URL, "github.com", "github.com@evil.example", 1)
		},
		"duplicate image":    func(r *Release) { r.Assets = append(r.Assets, r.Assets[0]) },
		"duplicate manifest": func(r *Release) { r.Assets = append(r.Assets, r.Assets[1]) },
		"oversize":           func(r *Release) { r.Assets[0].Size = maxImage + 1 }, "unuploaded": func(r *Release) { r.Assets[0].State = "new" },
		"initramfs": func(r *Release) {
			r.Assets[0].Name = "openwrt-mediatek-filogic-zbtlink_zbt-z8803be-initramfs-kernel.bin"
		},
		"source only":  func(r *Release) { r.Assets[0].Name = "source.tar.gz" },
		"other device": func(r *Release) { r.Assets[0].Name = "openwrt-mediatek-filogic-openwrt_one-squashfs-sysupgrade.bin" },
	}
	for name, modify := range cases {
		t.Run(name, func(t *testing.T) {
			r := releaseFixture("firmware-101.1", 1, []byte("x"), false)
			modify(&r)
			if _, _, _, e := selectAssets(r); e == nil {
				t.Fatal("unsafe release accepted")
			}
		})
	}
}
func TestRedirectHostAllowlist(t *testing.T) {
	for _, raw := range []string{"http://release-assets.githubusercontent.com/x", "https://evil.example/x", "https://release-assets.githubusercontent.com.evil.example/x", "https://user@release-assets.githubusercontent.com/x", "https://release-assets.githubusercontent.com:444/x", "https://github.com/other/repo/releases/download/v/a"} {
		u, _ := url.Parse(raw)
		if safeRedirect(u) {
			t.Fatal(raw)
		}
	}
	for _, raw := range []string{"https://release-assets.githubusercontent.com/a?sig=fixture", "https://objects.githubusercontent.com/a", webRoot + "/releases/download/firmware-1.1/a"} {
		u, _ := url.Parse(raw)
		if !safeRedirect(u) {
			t.Fatal(raw)
		}
	}
	client := githubClient()
	r, _ := http.NewRequest("GET", "https://evil.example/", nil)
	if client.CheckRedirect(r, nil) == nil {
		t.Fatal("unsafe redirect accepted")
	}
	r, _ = http.NewRequest("GET", "https://release-assets.githubusercontent.com/a", nil)
	if client.CheckRedirect(r, make([]*http.Request, 6)) == nil {
		t.Fatal("redirect loop accepted")
	}
}
func TestManifestFailuresNeverFallbackToLegacy(t *testing.T) {
	cases := map[string]func(*fixture){
		"wrong board":     func(f *fixture) { f.manifest.Board = "other,router" },
		"minimal variant": func(f *fixture) { f.manifest.Variant = "minimal" },
		"wrong repo":      func(f *fixture) { f.manifest.Repository = "evil/repo" },
		"wrong tag":       func(f *fixture) { f.manifest.Version = "firmware-99.1" },
		"bad sha":         func(f *fixture) { f.manifest.Image.SHA256 = strings.Repeat("0", 64) },
		"missing sha":     func(f *fixture) { f.manifest.Image.SHA256 = "" },
		"bad commit":      func(f *fixture) { f.manifest.SourceSHA = "main" },
		"dirty release":   func(f *fixture) { f.manifest.Dirty = true },
		"size mismatch":   func(f *fixture) { f.manifest.Image.Size++ },
		"other file":      func(f *fixture) { f.manifest.Image.Name = "evil.bin" },
	}
	for name, modify := range cases {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, false)
			modify(f)
			f.refresh()
			st := f.prepare(t)
			if st.Phase != "error" || st.Confirmation != "" {
				t.Fatal(st)
			}
			for _, c := range f.commands {
				if c[0] == "/sbin/sysupgrade" {
					t.Fatal("invalid metadata reached platform validation")
				}
			}
		})
	}
}
func TestChecksumParserRejectsDuplicatesWrongNamesAndCorruption(t *testing.T) {
	good := strings.Repeat("a", 64)
	for _, s := range []string{good + "  wrong.bin\n", good + "  " + imageName + "\n" + good + "  " + imageName + "\n", strings.Repeat("x", 64) + "  " + imageName + "\n", "<html>error</html>", good + "  ./" + imageName + "\n"} {
		if _, e := checksumLine([]byte(s), imageName); e == nil {
			t.Fatal("bad sums accepted", s)
		}
	}
	for _, sep := range []string{"  ", " *"} {
		v, e := checksumLine([]byte(good+sep+imageName+"\r\n"), imageName)
		if e != nil || v != good {
			t.Fatal(v, e)
		}
	}
}
func TestDownloadAndHTTPFailures(t *testing.T) {
	for _, code := range []int{403, 429, 404, 500} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			f := newFixture(t, false)
			f.status["/repos/"+repository+"/releases/101"] = code
			st := f.prepare(t)
			if st.Phase != "error" {
				t.Fatal(st)
			}
			if code == 429 && !strings.Contains(st.Error, "rate limit") {
				t.Fatal(st.Error)
			}
		})
	}
	for _, which := range []string{"api html", "manifest html", "image html", "truncated image", "legacy duplicate"} {
		t.Run(which, func(t *testing.T) {
			f := newFixture(t, which == "legacy duplicate")
			base := "/" + repository + "/releases/download/" + f.release.Tag + "/"
			switch which {
			case "api html":
				f.replies["/repos/"+repository+"/releases/101"] = []byte("<html>Error</html>")
			case "manifest html":
				f.replies[base+"mega-release.json"] = []byte("<html>Error</html>")
			case "image html":
				f.replies[base+imageName] = []byte("<html>Error</html>")
			case "truncated image":
				f.replies[base+imageName] = f.image[:5]
			case "legacy duplicate":
				f.replies[base+"SHA256SUMS"] = append(f.replies[base+"SHA256SUMS"], f.replies[base+"SHA256SUMS"]...)
			}
			st := f.prepare(t)
			if st.Phase != "error" {
				t.Fatal(st)
			}
			if _, e := os.Stat(f.service.Store.image(st.ID)); !os.IsNotExist(e) {
				t.Fatal("bad image retained", e)
			}
		})
	}
}
func TestBoardAndIdentityEligibility(t *testing.T) {
	for _, which := range []string{"missing", "minimal", "different board", "initramfs", "rootfs unknown", "bad identity"} {
		t.Run(which, func(t *testing.T) {
			f := newFixture(t, false)
			switch which {
			case "missing":
				os.Remove(f.service.IdentityPath)
			case "minimal":
				b, _ := json.Marshal(Identity{Variant: "minimal"})
				os.WriteFile(f.service.IdentityPath, b, 0600)
			case "bad identity":
				os.WriteFile(f.service.IdentityPath, []byte("{}"), 0600)
			case "different board":
				f.service.Run = func(context.Context, string, ...string) ([]byte, error) {
					return []byte(`{"board_name":"openwrt,one","rootfs_type":"squashfs"}`), nil
				}
			case "initramfs":
				f.service.Run = func(context.Context, string, ...string) ([]byte, error) {
					return []byte(`{"board_name":"zbtlink,zbt-z8803be","rootfs_type":"initramfs"}`), nil
				}
			case "rootfs unknown":
				f.service.Run = func(context.Context, string, ...string) ([]byte, error) {
					return []byte(`{"board_name":"zbtlink,zbt-z8803be"}`), nil
				}
			}
			if f.service.info(context.Background())["eligible"] != false {
				t.Fatal("bad board eligible")
			}
			if _, e := f.service.prepare(context.Background(), 101); e == nil {
				t.Fatal("bad board could prepare")
			}
		})
	}
}
func TestLowSpaceAndPlatformValidationFailure(t *testing.T) {
	for _, which := range []string{"low RAM", "sysupgrade test", "invalid JSON", "invalid image", "allow backup missing", "no backup"} {
		t.Run(which, func(t *testing.T) {
			f := newFixture(t, false)
			orig := f.service.Run
			if which == "low RAM" {
				f.service.Space = func(int64) error { return errors.New("Low RAM") }
			} else {
				f.service.Run = func(ctx context.Context, p string, args ...string) ([]byte, error) {
					if p == "/sbin/sysupgrade" && which == "sysupgrade test" {
						return nil, errors.New("test failed")
					}
					if p == "/bin/ubus" && len(args) == 4 {
						switch which {
						case "invalid JSON":
							return []byte("bad"), nil
						case "invalid image":
							return []byte(`{"valid":false,"forceable":true,"allow_backup":true}`), nil
						case "allow backup missing":
							return []byte(`{"valid":true}`), nil
						case "no backup":
							return []byte(`{"valid":true,"allow_backup":false}`), nil
						}
					}
					return orig(ctx, p, args...)
				}
			}
			st := f.prepare(t)
			if which == "no backup" {
				if st.Phase != "ready" || st.AllowBackup {
					t.Fatal(st)
				}
				if _, e := f.service.flash(context.Background(), st.ID, st.Confirmation, true); e == nil {
					t.Fatal("invalid keep-settings accepted")
				}
			} else if st.Phase != "error" {
				t.Fatal(st)
			}
		})
	}
}
func TestImageModifiedAfterConfirmationFailsClosed(t *testing.T) {
	f := newFixture(t, false)
	st := f.prepare(t)
	if _, e := f.service.flash(context.Background(), st.ID, st.Confirmation, false); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(f.service.Store.image(st.ID), []byte("tampered"), 0600); e != nil {
		t.Fatal(e)
	}
	f.service.flashWorker(st.ID)
	st, e := f.service.status(st.ID)
	if e != nil || st.Phase != "error" {
		t.Fatal(st, e)
	}
	for _, c := range f.commands {
		if c[0] == "/sbin/sysupgrade" && c[1] != "-T" {
			t.Fatal("modified image flashed")
		}
	}
}
func TestFlashCommandFailureVisibleInStatus(t *testing.T) {
	f := newFixture(t, false)
	st := f.prepare(t)
	orig := f.service.Run
	f.service.Run = func(ctx context.Context, p string, args ...string) ([]byte, error) {
		if p == "/sbin/sysupgrade" && args[0] != "-T" {
			return nil, errors.New("simulated flash startup failure")
		}
		return orig(ctx, p, args...)
	}
	if _, e := f.service.flash(context.Background(), st.ID, st.Confirmation, false); e != nil {
		t.Fatal(e)
	}
	f.service.flashWorker(st.ID)
	st, e := f.service.status(st.ID)
	if e != nil || st.Phase != "error" || !strings.Contains(st.Error, "sysupgrade") {
		t.Fatal(st, e)
	}
	if _, e = os.Stat(f.service.Store.image(st.ID)); e != nil {
		t.Fatal("image removed after destructive command started", e)
	}
	if _, e = f.service.discard(st.ID); e == nil {
		t.Fatal("potentially active flash image discarded")
	}
	if _, e = f.service.prepare(context.Background(), 101); e == nil {
		t.Fatal("second update permitted after ambiguous flash error")
	}
}

func TestFinalFlashHasNoCancellationDeadline(t *testing.T) {
	f := newFixture(t, false)
	st := f.prepare(t)
	orig := f.service.Run
	f.service.Run = func(ctx context.Context, p string, args ...string) ([]byte, error) {
		if p == "/sbin/sysupgrade" && args[0] != "-T" {
			if _, deadline := ctx.Deadline(); deadline || ctx.Done() != nil {
				t.Fatal("destructive flash can be killed by context cancellation")
			}
		}
		return orig(ctx, p, args...)
	}
	if _, e := f.service.flash(context.Background(), st.ID, st.Confirmation, false); e != nil {
		t.Fatal(e)
	}
	f.service.flashWorker(st.ID)
}

func TestConcurrentDuplicateDownloadWorkers(t *testing.T) {
	f := newFixture(t, false)
	v, e := f.service.prepare(context.Background(), 101)
	if e != nil {
		t.Fatal(e)
	}
	id := v["id"].(string)
	var wg sync.WaitGroup
	for n := 0; n < 6; n++ {
		wg.Add(1)
		go func() { defer wg.Done(); f.service.prepareWorker(id) }()
	}
	wg.Wait()
	st, e := f.service.status(id)
	if e != nil || st.Phase != "ready" {
		t.Fatal(st, e)
	}
	if _, e = os.Stat(f.service.Store.image(id)); e != nil {
		t.Fatal("valid image erased by duplicate worker", e)
	}
}

func TestCurrentLocalDevelopmentIdentityIsNotPublishedRelease(t *testing.T) {
	i := identityFixture("local-aaaaaaaaaaaa")
	i.Dirty = true
	if e := validIdentity(i, true); e != nil {
		t.Fatal(e)
	}
	if e := validIdentity(i, false); e == nil {
		t.Fatal("local dirty build accepted as published release")
	}
}

func TestMetadataAndImageReadersAreBounded(t *testing.T) {
	f := newFixture(t, false)
	path := "/" + repository + "/releases/download/" + f.release.Tag + "/mega-release.json"
	f.replies[path] = []byte(strings.Repeat("x", (64<<10)+1))
	st := f.prepare(t)
	if st.Phase != "error" {
		t.Fatal(st)
	}
	var b boundedOutput
	data := []byte(strings.Repeat("x", 50000))
	n, e := b.Write(data)
	if n != len(data) || e != nil || len(b.b) != 16384 {
		t.Fatal(n, e, len(b.b))
	}
	p := progressWriter{dest: &b, total: 3, tick: func(int64) error { return nil }}
	if _, e = p.Write([]byte("four")); e == nil {
		t.Fatal("oversized stream accepted")
	}
}
func TestDiscardAndWorkerCancellation(t *testing.T) {
	f := newFixture(t, false)
	v, e := f.service.prepare(context.Background(), 101)
	if e != nil {
		t.Fatal(e)
	}
	id := v["id"].(string)
	if _, e = f.service.discard(id); e != nil {
		t.Fatal(e)
	}
	f.service.prepareWorker(id)
	st, e := f.service.status(id)
	if e != nil || st.Phase != "discarded" {
		t.Fatal(st, e)
	}
	st = f.prepare(t)
	if _, e = f.service.discard(st.ID); e != nil {
		t.Fatal(e)
	}
	if _, e = os.Stat(f.service.Store.image(st.ID)); !os.IsNotExist(e) {
		t.Fatal("discard did not remove image")
	}
}
func TestConcurrentPrepareAndConfirmation(t *testing.T) {
	f := newFixture(t, false)
	var won atomic.Int32
	var id string
	var mu sync.Mutex
	var wg sync.WaitGroup
	for n := 0; n < 16; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, e := f.service.prepare(context.Background(), 101)
			if e == nil {
				won.Add(1)
				mu.Lock()
				id = r["id"].(string)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if won.Load() != 1 {
		t.Fatal("parallel prepares accepted", won.Load())
	}
	f.service.prepareWorker(id)
	st, e := f.service.status(id)
	if e != nil || st.Phase != "ready" {
		t.Fatal(st, e)
	}
	won.Store(0)
	for n := 0; n < 16; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, e := f.service.flash(context.Background(), id, st.Confirmation, false); e == nil {
				won.Add(1)
			}
		}()
	}
	wg.Wait()
	if won.Load() != 1 {
		t.Fatal("parallel confirmations accepted", won.Load())
	}
}
func TestSecureStateRejectsSymlinksHardlinksAndPermissions(t *testing.T) {
	for _, which := range []string{"directory symlink", "world directory", "lock symlink", "state symlink", "image symlink", "hardlink"} {
		t.Run(which, func(t *testing.T) {
			f := newFixture(t, false)
			outside := filepath.Join(t.TempDir(), "untouched")
			os.WriteFile(outside, []byte("untouched"), 0600)
			switch which {
			case "directory symlink":
				os.Symlink(filepath.Dir(outside), f.service.Store.Dir)
				if _, e := f.service.Store.lock(); e == nil {
					t.Fatal("symlink directory accepted")
				}
			case "world directory":
				os.Mkdir(f.service.Store.Dir, 0777)
				os.Chmod(f.service.Store.Dir, 0777)
				if _, e := f.service.Store.lock(); e == nil {
					t.Fatal("public directory accepted")
				}
			case "lock symlink":
				f.service.Store.secure()
				os.Symlink(outside, filepath.Join(f.service.Store.Dir, "lock"))
				if _, e := f.service.Store.lock(); e == nil {
					t.Fatal("symlink lock accepted")
				}
			case "state symlink":
				f.service.Store.secure()
				os.Symlink(outside, filepath.Join(f.service.Store.Dir, "current.json"))
				if _, e := f.service.prepare(context.Background(), 101); e == nil {
					t.Fatal("symlink state accepted")
				}
			case "image symlink":
				v, e := f.service.prepare(context.Background(), 101)
				if e != nil {
					t.Fatal(e)
				}
				id := v["id"].(string)
				os.Symlink(outside, f.service.Store.image(id))
				f.service.prepareWorker(id)
				st, _ := f.service.status(id)
				if st.Phase != "error" {
					t.Fatal(st)
				}
			case "hardlink":
				f.service.Store.secure()
				os.Link(outside, filepath.Join(f.service.Store.Dir, "lock"))
				if _, e := f.service.Store.lock(); e == nil {
					t.Fatal("hardlinked lock accepted")
				}
			}
			b, _ := os.ReadFile(outside)
			if string(b) != "untouched" {
				t.Fatal("outside file was changed")
			}
		})
	}
}
func TestStoreLocksAcrossIndependentInstances(t *testing.T) {
	f := newFixture(t, false)
	l, e := f.service.Store.lock()
	if e != nil {
		t.Fatal(e)
	}
	defer unlock(l)
	other := Store{Dir: f.service.Store.Dir}
	if _, e = other.lock(); e == nil {
		t.Fatal("flock not enforced")
	}
	if e = syscall.Flock(int(l.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		t.Fatal(e)
	}
}
func TestClientRequestsCannotChooseURLPathOrCommand(t *testing.T) {
	f := newFixture(t, false)
	for _, id := range []string{"../firmware", "/tmp/image.bin", ";reboot", "", "zzzz"} {
		if _, e := f.service.status(id); e == nil {
			t.Fatal(id)
		}
		if _, e := f.service.discard(id); e == nil {
			t.Fatal(id)
		}
	}
	for _, id := range []int64{-1, 0, 9007199254740992} {
		if _, e := f.service.prepare(context.Background(), id); e == nil {
			t.Fatal(id)
		}
	}
	if _, e := f.service.call(context.Background(), "shell", Request{}); e == nil {
		t.Fatal("unknown command accepted")
	}
}
func TestWorkerSpawnFailureIsRecoverable(t *testing.T) {
	f := newFixture(t, false)
	f.service.Spawn = func(string, string) error { return errors.New("fork failed") }
	if _, e := f.service.prepare(context.Background(), 101); e == nil {
		t.Fatal("spawn error ignored")
	}
	info := f.service.info(context.Background())
	st, e := f.service.status(info["active_id"].(string))
	if e != nil || st.Phase != "error" {
		t.Fatal(st, e)
	}
}
