// SPDX-License-Identifier: MIT
// Linux/rpcd adapter for speedtest-go. Measurement callbacks, never animations
// or interface-wide counters, supply the live values shown by LuCI.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/showwin/speedtest-go/speedtest"
)

const (
	engine             = "speedtest-go 1.8.3 · Speedtest.net servers"
	maxConnections     = 16
	transferTime       = 20 * time.Second
	liveSampleInterval = 250 * time.Millisecond
	uploadProbeBytes   = 32 * 1024
	uploadProbeTimeout = 4 * time.Second
	serverProbeLimit   = 8
)

var runID = regexp.MustCompile(`^[a-f0-9]{24}$`)
var serverID = regexp.MustCompile(`^[0-9]{1,8}$`)

type request struct {
	Interface string `json:"interface"`
	Server    string `json:"server"`
	Mode      string `json:"mode"`
	Consent   bool   `json:"consent"`
	ID        string `json:"id"`
}

type serverInfo struct {
	ID      string  `json:"id"`
	Name    string  `json:"name"`
	Sponsor string  `json:"sponsor"`
	Country string  `json:"country"`
	Ping    float64 `json:"ping_ms"`
}

type sample struct {
	Seconds float64 `json:"seconds"`
	Phase   string  `json:"phase"`
	Mbps    float64 `json:"mbps"`
}

type result struct {
	request
	OK       bool         `json:"ok"`
	Running  bool         `json:"running"`
	Phase    string       `json:"phase"`
	Error    string       `json:"error,omitempty"`
	Engine   string       `json:"engine"`
	Device   string       `json:"device"`
	IfIndex  int          `json:"ifindex"`
	Source   string       `json:"source,omitempty"`
	Selected *serverInfo  `json:"selected,omitempty"`
	Servers  []serverInfo `json:"servers,omitempty"`
	Ping     *float64     `json:"ping_ms"`
	Jitter   *float64     `json:"jitter_ms"`
	Download *float64     `json:"download_mbps"`
	Upload   *float64     `json:"upload_mbps"`
	Live     *float64     `json:"live_mbps"`
	Bytes    int64        `json:"bytes"`
	Elapsed  float64      `json:"elapsed"`
	Samples  []sample     `json:"samples,omitempty"`
}

type store struct{ dir string }

func writeJSON(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".state-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(data)
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

func uptime() int64 {
	b, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 {
		return 0
	}
	f, _ := strconv.ParseFloat(fields[0], 64)
	return int64(f)
}

func (s store) lease() (int64, string) {
	b, err := os.ReadFile(filepath.Join(s.dir, "lock/lease"))
	if err != nil {
		return 0, ""
	}
	var expiry int64
	var token string
	fmt.Sscanf(string(b), "%d %s", &expiry, &token)
	return expiry, token
}

// Same mkdir/uptime lease as the background sampler. Our hard deadline is
// 90 s, below the 120 s lease, including discovery, ping and both transfers.
func (s store) acquire(id string) error {
	if err := os.MkdirAll(s.dir, 0700); err != nil {
		return err
	}
	lock := filepath.Join(s.dir, "lock")
	if err := os.Mkdir(lock, 0700); err != nil {
		expiry, _ := s.lease()
		if expiry == 0 || uptime() <= expiry {
			return errors.New("Another speed test or background sample is running. Try again shortly.")
		}
		os.Remove(filepath.Join(lock, "lease"))
		if err := os.Remove(lock); err != nil {
			return err
		}
		if err := os.Mkdir(lock, 0700); err != nil {
			return err
		}
	}
	err := os.WriteFile(filepath.Join(lock, "lease"), []byte(fmt.Sprintf("%d %s\n", uptime()+120, id)), 0600)
	if err != nil {
		os.Remove(lock)
	}
	return err
}

func (s store) release(id string) {
	_, owner := s.lease()
	if owner != id {
		return
	}
	os.Remove(filepath.Join(s.dir, "lock/lease"))
	os.Remove(filepath.Join(s.dir, "lock"))
	os.Remove(filepath.Join(s.dir, id+".cancel"))
}

func (s store) save(r result) error { return writeJSON(filepath.Join(s.dir, r.ID+".json"), r) }

func (s store) read(id string) (result, error) {
	var r result
	if !runID.MatchString(id) {
		return r, errors.New("Invalid test ID")
	}
	b, err := os.ReadFile(filepath.Join(s.dir, id+".json"))
	if err != nil {
		return r, err
	}
	err = json.Unmarshal(b, &r)
	return r, err
}

func (s store) current() result {
	var id string
	b, _ := os.ReadFile(filepath.Join(s.dir, "current"))
	json.Unmarshal(b, &id)
	r, err := s.read(id)
	if err != nil {
		return result{Phase: "idle", Engine: engine}
	}
	expiry, owner := s.lease()
	if r.Running && (owner != id || uptime() > expiry) {
		r.Running, r.OK, r.Phase, r.Error = false, false, "error", "The test worker stopped. Run a new test."
	}
	return r
}

func validate(q *request) error {
	if q.Interface == "" {
		q.Interface = "default"
	}
	switch q.Interface {
	case "default", "wan", "wan_sfp", "usb_tether", "4_1", "2_1":
	default:
		return errors.New("Unsupported interface")
	}
	if q.Mode == "" {
		q.Mode = "test"
	}
	if q.Mode != "test" && q.Mode != "servers" {
		return errors.New("Unsupported operation")
	}
	if q.Server != "" && !serverID.MatchString(q.Server) {
		return errors.New("Use a numeric Speedtest.net server ID")
	}
	if q.Mode == "test" && !q.Consent {
		return errors.New("Confirm the cellular data-usage warning before starting")
	}
	return nil
}

func physicalDevice(sys, section string) (string, error) {
	usb := map[string]string{"4_1": "4-1", "2_1": "2-1"}[section]
	if usb == "" {
		return "", errors.New("Unknown modem")
	}
	paths, _ := filepath.Glob(filepath.Join(sys, "bus/usb/devices", usb, "*", "net", "*"))
	var found []string
	for _, p := range paths {
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			found = append(found, filepath.Base(p))
		}
	}
	if len(found) != 1 {
		return "", errors.New("Selected modem is absent or has an ambiguous data interface")
	}
	return found[0], nil
}

func resolve(section string) (string, int, string, error) {
	if section == "default" {
		return "", 0, "", nil
	}
	var device string
	var err error
	if section == "4_1" || section == "2_1" {
		device, err = physicalDevice("/sys", section)
	} else {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		var b []byte
		b, err = exec.CommandContext(ctx, "ubus", "call", "network.interface."+section, "status").Output()
		var v struct {
			Up     bool   `json:"up"`
			Device string `json:"l3_device"`
		}
		if err == nil {
			err = json.Unmarshal(b, &v)
		}
		if err == nil && !v.Up {
			err = errors.New("Selected WAN is not online")
		}
		device = v.Device
	}
	if err != nil {
		return "", 0, "", err
	}
	nic, err := net.InterfaceByName(device)
	if err != nil {
		return "", 0, "", err
	}
	addresses, err := nic.Addrs()
	if err != nil {
		return "", 0, "", err
	}
	for _, a := range addresses {
		ip, _, e := net.ParseCIDR(a.String())
		if e == nil && ip.To4() != nil && !ip.IsLoopback() {
			return device, nic.Index, ip.String(), nil
		}
	}
	return "", 0, "", errors.New("Selected connection has no IPv4 address; it will not fall back to the other modem")
}

func (s store) start(q request) (result, error) {
	if err := validate(&q); err != nil {
		return result{}, err
	}
	device, index, source, err := resolve(q.Interface)
	if err != nil {
		return result{}, err
	}
	b := make([]byte, 12)
	if _, err = rand.Read(b); err != nil {
		return result{}, err
	}
	q.ID = hex.EncodeToString(b)
	if err = s.acquire(q.ID); err != nil {
		return result{}, err
	}
	r := result{request: q, OK: true, Running: true, Phase: "discovery", Engine: engine, Device: device, IfIndex: index, Source: source}
	old := s.current().ID
	if err = s.save(r); err == nil {
		err = writeJSON(filepath.Join(s.dir, "current"), q.ID)
	}
	if err == nil {
		var exe string
		exe, err = os.Executable()
		if err == nil {
			cmd := exec.Command(exe, "worker", q.ID)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
			err = cmd.Start() // nil stdio opens /dev/null; no rpcd pipe inherited
			if err == nil {
				cmd.Process.Release()
			}
		}
	}
	if err != nil {
		r.OK, r.Running, r.Phase, r.Error = false, false, "error", "Could not start the test worker"
		s.save(r)
		s.release(q.ID)
		return r, err
	}
	if runID.MatchString(old) {
		os.Remove(filepath.Join(s.dir, old+".json"))
		os.Remove(filepath.Join(s.dir, old+".cancel"))
	}
	return r, nil
}

func (s store) cancel(id string) error {
	r := s.current()
	if !runID.MatchString(id) || r.ID != id || !r.Running {
		return errors.New("That test is no longer running")
	}
	return os.WriteFile(filepath.Join(s.dir, id+".cancel"), []byte("stop\n"), 0600)
}

func mbps(v speedtest.ByteRate) *float64 {
	f := float64(v) * 8 / 1e6
	if f < 0 || math.IsInf(f, 0) || math.IsNaN(f) {
		return nil
	}
	return &f
}

// Bind sockets to the device, not just its potentially duplicated private IP.
func bindDevice(device string) func(string, string, syscall.RawConn) error {
	if device == "" {
		return nil
	}
	return func(_, _ string, c syscall.RawConn) error {
		var bindErr error
		err := c.Control(func(fd uintptr) {
			bindErr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, device)
		})
		if err != nil {
			return err
		}
		return bindErr
	}
}

// speedtest-go's HTTP engine does not itself reject non-200 bodies. Never
// report an error page as throughput, or count unacknowledged upload buffers
// as a successful final result. Cancellation at phase end is expected.
type checkedTransport struct {
	base  http.RoundTripper
	bad   atomic.Int64
	posts atomic.Int64
}

func (t *checkedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req.Header.Set("User-Agent", "zbt-speedtest/1 speedtest-go/1.8.3")
	resp, err := t.base.RoundTrip(req)
	if err != nil {
		return resp, err
	}
	// Modern Ookla hosts redirect the catalogue's HTTP URL to a canonical
	// HTTPS hostname. Let http.Client follow it with normal TLS validation.
	if resp.StatusCode == 301 || resp.StatusCode == 302 || resp.StatusCode == 303 || resp.StatusCode == 307 || resp.StatusCode == 308 {
		return resp, nil
	}
	transfer := req.Method == "POST" || strings.Contains(req.URL.Path, "/random")
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices || (transfer && strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "text/html")) {
		resp.Body.Close()
		if transfer {
			t.bad.Add(1)
		}
		return nil, fmt.Errorf("Server returned an invalid HTTP response (%d)", resp.StatusCode)
	}
	if req.Method == "POST" {
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, 1024))
		resp.Body.Close()
		if readErr != nil {
			t.bad.Add(1)
			return nil, errors.New("Speedtest server upload response could not be read")
		}
		// Speedtest.net-compatible upload.php implementations do not share one
		// response body: common valid responses include size=N, an empty body,
		// or another short plain-text acknowledgement. A completed POST followed
		// by a non-HTML 2xx response is the interoperable success condition.
		resp.Body = io.NopCloser(bytes.NewReader(body))
		t.posts.Add(1)
	}
	return resp, nil
}

// Check upload capability before a full automatic test. Some entries in the
// public Speedtest.net directory answer latency/download requests but reject
// upload.php. Skipping those servers prevents a 20-second download from ending
// with a missing upload result. This probe sends only 32 KiB and uses the same
// interface-bound, TLS-validating client as the real measurement.
func probeUpload(ctx context.Context, client *http.Client, checked *checkedTransport, server *speedtest.Server) error {
	probeCtx, cancel := context.WithTimeout(ctx, uploadProbeTimeout)
	defer cancel()

	resolved := server.URL
	head, err := http.NewRequestWithContext(probeCtx, http.MethodHead, resolved, nil)
	if err == nil {
		if resp, headErr := client.Do(head); headErr == nil {
			if resp.Request != nil && resp.Request.URL != nil {
				resolved = resp.Request.URL.String()
			}
			resp.Body.Close()
		}
	}

	before := checked.posts.Load()
	payload := bytes.Repeat([]byte{0x5a}, uploadProbeBytes)
	req, err := http.NewRequestWithContext(probeCtx, http.MethodPost, resolved, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if checked.posts.Load() == before {
		return errors.New("server did not accept an upload probe")
	}
	return nil
}

func selectUploadServer(ctx context.Context, client *http.Client, checked *checkedTransport, candidates speedtest.Servers, automatic bool) (*speedtest.Server, error) {
	limit := len(candidates)
	if !automatic && limit > 1 {
		limit = 1
	}
	if limit > serverProbeLimit {
		limit = serverProbeLimit
	}
	for i := 0; i < limit; i++ {
		if err := probeUpload(ctx, client, checked, candidates[i]); err == nil {
			// Probe traffic must not satisfy final-result validation or pollute a
			// later server's error state.
			checked.posts.Store(0)
			checked.bad.Store(0)
			return candidates[i], nil
		}
		checked.posts.Store(0)
		checked.bad.Store(0)
	}
	if automatic {
		return nil, errors.New("No automatic Speedtest.net server accepted both download and upload traffic; choose a server manually")
	}
	return nil, errors.New("Selected Speedtest.net server does not accept upload traffic; choose Automatic or another server")
}

type reporter struct {
	sync.Mutex
	s     store
	r     result
	began time.Time
	done  bool
}

func (p *reporter) update(fn func(*result)) {
	p.Lock()
	defer p.Unlock()
	if p.done {
		return
	}
	fn(&p.r)
	p.r.Elapsed = time.Since(p.began).Seconds()
	p.s.save(p.r)
}

func (p *reporter) finish(phase string, err error) {
	p.Lock()
	defer p.Unlock()
	if p.done {
		return
	}
	p.done = true
	p.r.Running, p.r.Phase = false, phase
	p.r.OK = err == nil && phase != "cancelled"
	p.r.Live = nil
	p.r.Elapsed = time.Since(p.began).Seconds()
	if err != nil {
		p.r.Error = err.Error()
	}
	p.s.save(p.r)
	p.s.release(p.r.ID)
}

func info(s *speedtest.Server) serverInfo {
	return serverInfo{ID: s.ID, Name: s.Name, Sponsor: s.Sponsor, Country: s.Country, Ping: float64(s.Latency) / 1e6}
}

func runTest(ctx context.Context, p *reporter) error {
	q := p.r
	// High-latency cellular paths often need more parallel transfers and a
	// longer warm-up than a wired connection before they reach their available
	// throughput. v1.8.3 also adapts upload concurrency using bytes confirmed by
	// successful server responses instead of counting queued request data.
	uc := &speedtest.UserConfig{Source: q.Source, DialerControl: bindDevice(q.Device), MaxConnections: maxConnections, PingMode: speedtest.HTTP}
	client := speedtest.New(speedtest.WithUserConfig(uc))
	// Do not inherit server/container HTTP_PROXY variables or silently redirect
	// an explicitly selected modem test through an application proxy.
	uc.T.Proxy = nil
	checked := &checkedTransport{base: uc.T}
	httpClient := &http.Client{Transport: checked, Timeout: 25 * time.Second}
	speedtest.WithDoer(httpClient)(client)
	client.SetRateCaptureFrequency(liveSampleInterval).SetCaptureTime(transferTime)
	var candidates speedtest.Servers
	var err error
	if q.Server != "" && q.Mode == "test" {
		var target *speedtest.Server
		target, err = client.FetchServerByIDContext(ctx, q.Server)
		if err == nil {
			candidates = append(candidates, target)
		}
	} else {
		candidates, err = client.FetchServerListContext(ctx)
	}
	if err != nil {
		return fmt.Errorf("Speedtest.net server discovery failed: %w", err)
	}
	if len(candidates) == 0 {
		return errors.New("No Speedtest.net servers found")
	}
	if q.Server == "" || q.Mode == "servers" {
		available := candidates.Available()
		candidates = *available
	}
	if len(candidates) == 0 {
		return errors.New("No reachable Speedtest.net servers on this connection")
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].Latency < candidates[j].Latency })
	p.update(func(r *result) {
		for _, s := range candidates {
			r.Servers = append(r.Servers, info(s))
		}
	})
	if q.Mode == "servers" {
		return nil
	}
	server, err := selectUploadServer(ctx, httpClient, checked, candidates, q.Server == "")
	if err != nil {
		return err
	}
	p.update(func(r *result) { v := info(server); r.Selected = &v; r.Phase = "ping" })
	err = server.PingTestContext(ctx, func(v time.Duration) {
		p.update(func(r *result) { f := float64(v) / 1e6; r.Ping = &f })
	})
	if err != nil || server.Latency <= 0 {
		return fmt.Errorf("Server latency test failed; try another server (%v)", err)
	}
	p.update(func(r *result) {
		a, b := float64(server.Latency)/1e6, float64(server.Jitter)/1e6
		r.Ping, r.Jitter = &a, &b
	})
	for _, phase := range []string{"download", "upload"} {
		p.update(func(r *result) { r.Phase = phase; r.Live = nil })
		callback := func(rate speedtest.ByteRate) {
			p.update(func(r *result) {
				r.Live = mbps(rate)
				r.Bytes = client.GetTotalDownload() + client.GetTotalUpload()
				if r.Live != nil && len(r.Samples) < 240 {
					r.Samples = append(r.Samples, sample{Seconds: time.Since(p.began).Seconds(), Phase: phase, Mbps: *r.Live})
				}
			})
		}
		var value *float64
		if phase == "download" {
			client.SetCallbackDownload(callback)
			err = server.DownloadTestContext(ctx)
			value = mbps(server.DLSpeed)
		} else {
			client.SetCallbackUpload(callback)
			err = server.UploadTestContext(ctx)
			value = mbps(server.ULSpeed)
		}
		if err != nil || ctx.Err() != nil || value == nil || *value <= 0 || checked.bad.Load() > 0 || (phase == "upload" && checked.posts.Load() == 0) {
			return fmt.Errorf("%s measurement failed; no complete result. Try another server or check the connection.", phase)
		}
		p.update(func(r *result) {
			if phase == "download" {
				r.Download = value
			} else {
				r.Upload = value
			}
			r.Bytes = client.GetTotalDownload() + client.GetTotalUpload()
		})
	}
	return nil
}

func worker(s store, id string) {
	workerRun(s, id, runTest, 90*time.Second)
}

func workerRun(s store, id string, run func(context.Context, *reporter) error, deadline time.Duration) {
	r, err := s.read(id)
	expiry, owner := s.lease()
	if err != nil || owner != id || uptime() > expiry {
		return
	}
	p := &reporter{s: s, r: r, began: time.Now()}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// A hard process deadline closes *all* sockets even if a library operation
	// stops responding to context cancellation. This is not a modem restart.
	go func() {
		tick := time.NewTicker(100 * time.Millisecond)
		defer tick.Stop()
		for range tick.C {
			phase, message := "", ""
			if _, err := os.Stat(filepath.Join(s.dir, id+".cancel")); err == nil {
				phase = "cancelled"
			}
			if time.Since(p.began) > deadline {
				phase, message = "error", fmt.Sprintf("Speed test timed out after %.0f seconds", deadline.Seconds())
			}
			if r.Device != "" {
				nic, err := net.InterfaceByName(r.Device)
				if err != nil || nic.Index != r.IfIndex {
					phase, message = "error", "Selected network device disappeared; test stopped without switching modems"
				}
			}
			if phase != "" {
				cancel()
				var err error
				if message != "" {
					err = errors.New(message)
				}
				p.finish(phase, err)
				os.Exit(0)
			}
		}
	}()
	err = run(ctx, p)
	phase := "complete"
	if r.Mode == "servers" {
		phase = "ready"
	}
	if err != nil {
		phase = "error"
	}
	p.finish(phase, err)
}

func main() {
	s := store{dir: "/tmp/zbt-speedtest"}
	if len(os.Args) == 3 && os.Args[1] == "worker" {
		worker(s, os.Args[2])
		return
	}
	enc := json.NewEncoder(os.Stdout)
	if len(os.Args) == 2 && os.Args[1] == "list" {
		// rpcd derives types from example JSON values, not type-name strings.
		fmt.Println(`{"start":{"interface":"","server":"","mode":"","consent":false},"status":{},"cancel":{"id":""}}`)
		return
	}
	if len(os.Args) != 3 || os.Args[1] != "call" {
		return
	}
	var q request
	var err error
	var response any
	if os.Args[2] != "status" {
		// The authenticated HTTP bridge may add this field. Accept it, but do
		// not persist or expose session credentials in status/results.
		var input struct {
			request
			Session string `json:"ubus_rpc_session"`
		}
		dec := json.NewDecoder(io.LimitReader(os.Stdin, 4096))
		dec.DisallowUnknownFields()
		err = dec.Decode(&input)
		q = input.request
	}
	if err == nil {
		switch os.Args[2] {
		case "start":
			response, err = s.start(q)
		case "status":
			response = s.current()
		case "cancel":
			err = s.cancel(q.ID)
			response = map[string]bool{"ok": err == nil}
		default:
			err = errors.New("Unknown operation")
		}
	}
	if err != nil {
		response = map[string]any{"ok": false, "error": err.Error()}
	}
	enc.Encode(response)
}
