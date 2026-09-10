package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/showwin/speedtest-go/speedtest"
)

func TestValidation(t *testing.T) {
	for _, iface := range []string{"default", "wan", "wan_sfp", "4_1", "2_1"} {
		q := request{Interface: iface, Consent: true, Server: "12345"}
		if err := validate(&q); err != nil {
			t.Fatal(err)
		}
	}
	for _, q := range []request{
		{Consent: false}, {Consent: true, Interface: ";reboot"},
		{Consent: true, Server: "https://localhost"}, {Consent: true, Server: "1; reboot"},
		{Consent: true, Mode: "shell"}, {Consent: true, Server: "123456789"},
	} {
		if validate(&q) == nil {
			t.Fatalf("accepted unsafe request: %+v", q)
		}
	}
	q := request{Mode: "servers"}
	if err := validate(&q); err != nil {
		t.Fatal("discovery must not require bulk data consent", err)
	}
}

func TestMbpsNeverFabricatesInvalidRates(t *testing.T) {
	if got := mbps(12500000); got == nil || *got != 100 {
		t.Fatal("bytes/s to decimal Mbps", got)
	}
	for _, rate := range []float64{-1, math.NaN(), math.Inf(1)} {
		if mbps(speedtest.ByteRate(rate)) != nil {
			t.Fatal("invalid rate should be unknown")
		}
	}
}

func TestPhysicalModemsDoNotFollowEnumerationOrder(t *testing.T) {
	sys := t.TempDir()
	for _, pair := range [][2]string{{"4-1", "wwan8"}, {"2-1", "wwan3"}} {
		p := filepath.Join(sys, "bus/usb/devices", pair[0], pair[0]+":1.4/net", pair[1])
		if err := os.MkdirAll(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, pair := range [][2]string{{"4_1", "wwan8"}, {"2_1", "wwan3"}} {
		got, err := physicalDevice(sys, pair[0])
		if err != nil || got != pair[1] {
			t.Fatal(got, err)
		}
	}
	os.MkdirAll(filepath.Join(sys, "bus/usb/devices/2-1/2-1:1.5/net/wwan9"), 0700)
	if _, err := physicalDevice(sys, "2_1"); err == nil {
		t.Fatal("ambiguous slot was accepted")
	}
	if _, err := physicalDevice(t.TempDir(), "2_1"); err == nil {
		t.Fatal("absent slot fell back")
	}
}

func TestMeasurementLeaseAndOwnership(t *testing.T) {
	s := store{t.TempDir()}
	var acquired atomic.Int64
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if s.acquire("first") == nil {
				acquired.Add(1)
			}
		}()
	}
	wg.Wait()
	if acquired.Load() != 1 {
		t.Fatal("overlapping tests", acquired.Load())
	}
	s.release("wrong-owner")
	if _, owner := s.lease(); owner != "first" {
		t.Fatal("unrelated worker released test")
	}
	os.WriteFile(filepath.Join(s.dir, "lock/lease"), []byte("1 expired-shell-sampler\n"), 0600)
	if err := s.acquire("new-owner"); err != nil {
		t.Fatal(err)
	}
	s.release("first")
	if _, owner := s.lease(); owner != "new-owner" {
		t.Fatal("stale worker released new lease")
	}
	s.release("new-owner")
	if _, err := os.Stat(filepath.Join(s.dir, "lock")); !os.IsNotExist(err) {
		t.Fatal(err)
	}
}

func TestStatusCancellationAndExpiredWorker(t *testing.T) {
	s := store{t.TempDir()}
	id := "0123456789abcdef01234567"
	if err := s.acquire(id); err != nil {
		t.Fatal(err)
	}
	r := result{request: request{ID: id}, OK: true, Running: true, Phase: "download"}
	s.save(r)
	writeJSON(filepath.Join(s.dir, "current"), id)
	if err := s.cancel("../../bad"); err == nil {
		t.Fatal("unsafe cancellation")
	}
	if err := s.cancel("111111111111111111111111"); err == nil {
		t.Fatal("cancelled another test")
	}
	if err := s.cancel(id); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(s.dir, id+".cancel")); err != nil {
		t.Fatal(err)
	}
	s.release(id)
	current := s.current()
	if current.Running || current.OK || current.Phase != "error" {
		t.Fatal("lost worker reported success")
	}
}

func TestFinalStateCannotBeOverwrittenByLateCallbacks(t *testing.T) {
	s := store{t.TempDir()}
	id := "0123456789abcdef01234567"
	s.acquire(id)
	p := &reporter{s: s, r: result{request: request{ID: id}, Running: true}, began: time.Now()}
	p.update(func(r *result) { r.Download = mbps(12500000) })
	p.finish("cancelled", nil)
	p.update(func(r *result) { r.Phase = "complete"; r.OK = true })
	r, err := s.read(id)
	if err != nil || r.Phase != "cancelled" || r.OK || r.Running || *r.Download != 100 {
		t.Fatal(r, err)
	}
	b, _ := os.ReadFile(filepath.Join(s.dir, id+".json"))
	if !json.Valid(b) {
		t.Fatal("non-atomic JSON")
	}
}

func TestRejectHTTPErrorAndCaptivePortalBodies(t *testing.T) {
	for _, code := range []int{403, 500, 200} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			w.WriteHeader(code)
			io.WriteString(w, "<html>not a speed test</html>")
		}))
		checked := &checkedTransport{base: http.DefaultTransport}
		c := &http.Client{Transport: checked}
		if _, err := c.Get(srv.URL + "/speedtest/random1000x1000.jpg"); err == nil {
			t.Fatal("download error body counted")
		}
		if _, err := c.Post(srv.URL+"/speedtest/upload.php", "application/octet-stream", strings.NewReader("payload")); err == nil {
			t.Fatal("upload error counted")
		}
		if checked.bad.Load() != 2 || checked.posts.Load() != 0 {
			t.Fatal("failed upload counted as acknowledged")
		}
		srv.Close()
	}
}

func TestBindingCannotSilentlyFallBack(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") }))
	defer srv.Close()
	dial := net.Dialer{Control: bindDevice("no-such-zbt")}
	c := &http.Client{Transport: &http.Transport{DialContext: dial.DialContext}, Timeout: time.Second}
	if _, err := c.Get(srv.URL); err == nil {
		t.Fatal("invalid interface fell back to default")
	}
	if bindDevice("") != nil {
		t.Fatal("default route should remain unbound")
	}
}

func TestRedirectsAndUploadAcknowledgement(t *testing.T) {
	var wrong atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "/speedtest/upload.php", http.StatusTemporaryRedirect)
			return
		}
		io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "text/plain")
		if wrong.Load() {
			io.WriteString(w, "size=0")
		} else {
			fmt.Fprintf(w, "size=%d", r.ContentLength)
		}
	}))
	defer srv.Close()
	checked := &checkedTransport{base: http.DefaultTransport}
	c := &http.Client{Transport: checked}
	resp, err := c.Post(srv.URL+"/redirect", "application/octet-stream", strings.NewReader("real data"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if checked.posts.Load() != 1 || checked.bad.Load() != 0 {
		t.Fatal("legitimate redirect was rejected")
	}
	wrong.Store(true)
	if _, err := c.Post(srv.URL+"/redirect", "application/octet-stream", strings.NewReader("real data")); err == nil {
		t.Fatal("zero-byte server ack accepted as a measured upload")
	}
}

func TestWorkerSubprocess(t *testing.T) {
	if os.Getenv("ZBT_WORKER_TEST_CHILD") != "1" {
		return
	}
	s := store{os.Getenv("ZBT_WORKER_TEST_DIR")}
	limit := 3 * time.Second
	if os.Getenv("ZBT_WORKER_TEST_DEADLINE") == "1" {
		limit = 500 * time.Millisecond
	}
	workerRun(s, "0123456789abcdef01234567", func(_ context.Context, p *reporter) error {
		p.update(func(r *result) { r.Phase = "download" })
		// Deliberately uncooperative operation: supervisor must exit the
		// process, not merely cancel a context and leave sockets running.
		select {}
	}, limit)
	os.Exit(3)
}

func TestWorkerStopAndDeadlineActuallyExit(t *testing.T) {
	for _, phase := range []string{"cancelled", "error"} {
		t.Run(phase, func(t *testing.T) {
			s := store{t.TempDir()}
			id := "0123456789abcdef01234567"
			s.acquire(id)
			s.save(result{request: request{ID: id}, Running: true, Phase: "discovery"})
			writeJSON(filepath.Join(s.dir, "current"), id)
			cmd := exec.Command(os.Args[0], "-test.run=^TestWorkerSubprocess$")
			cmd.Env = append(os.Environ(), "ZBT_WORKER_TEST_CHILD=1", "ZBT_WORKER_TEST_DIR="+s.dir)
			if phase == "error" {
				cmd.Env = append(cmd.Env, "ZBT_WORKER_TEST_DEADLINE=1")
			}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer cmd.Process.Kill()
			for i := 0; i < 100 && s.current().Phase != "download"; i++ {
				time.Sleep(10 * time.Millisecond)
			}
			if phase == "cancelled" {
				if err := s.cancel(id); err != nil {
					t.Fatal(err)
				}
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("worker did not exit promptly")
			}
			r := s.current()
			if r.Phase != phase || r.OK || r.Running {
				t.Fatal("bad terminal state", r)
			}
			if _, owner := s.lease(); owner != "" {
				t.Fatal("worker left the measurement lock behind")
			}
		})
	}
}

func TestActualTransfersDriveLiveCallbacks(t *testing.T) {
	// A controlled loopback server exercises the *real pinned library*, not
	// fake rates or the public Internet. Data transfers are throttled/bounded.
	var received atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			n, _ := io.Copy(io.Discard, r.Body)
			received.Add(n)
			w.Header().Set("Content-Type", "text/plain")
			io.WriteString(w, "size=999490")
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		for i := 0; i < 24; i++ {
			if _, err := w.Write(make([]byte, 8192)); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			time.Sleep(2 * time.Millisecond)
		}
	}))
	defer srv.Close()
	uc := &speedtest.UserConfig{MaxConnections: 2}
	c := speedtest.New(speedtest.WithUserConfig(uc))
	checked := &checkedTransport{base: uc.T}
	speedtest.WithDoer(&http.Client{Transport: checked})(c)
	c.SetCaptureTime(400 * time.Millisecond).SetRateCaptureFrequency(50 * time.Millisecond)
	server, _ := c.CustomServer(srv.URL)
	var downEvents, upEvents atomic.Int64
	c.SetCallbackDownload(func(v speedtest.ByteRate) {
		if value := mbps(v); value != nil && *value > 0 {
			downEvents.Add(1)
		}
	})
	c.SetCallbackUpload(func(v speedtest.ByteRate) {
		if value := mbps(v); value != nil && *value > 0 {
			upEvents.Add(1)
		}
	})
	if err := server.DownloadTestContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := server.UploadTestContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	if c.GetTotalDownload() <= 0 || received.Load() <= 0 || checked.posts.Load() <= 0 || downEvents.Load() == 0 || upEvents.Load() == 0 {
		t.Fatal("real transfers did not produce progress", c.GetTotalDownload(), received.Load(), downEvents.Load(), upEvents.Load())
	}
}
