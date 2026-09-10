// SPDX-License-Identifier: MIT
package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Service struct {
	Store        Store
	Catalog      Catalog
	IdentityPath string
	Run          func(context.Context, string, ...string) ([]byte, error)
	Spawn        func(string, string) error
	Space        func(int64) error
}

func production() Service {
	s := Service{Store: Store{Dir: "/tmp/zbt-firmware-updater"}, Catalog: Catalog{Client: githubClient()}, IdentityPath: "/rom/etc/zbt-mega-build.json", Run: runCommand, Spawn: spawnWorker}
	s.Space = func(n int64) error { return checkSpace(s.Store.Dir, n) }
	return s
}

type boundedOutput struct{ b []byte }

func (w *boundedOutput) Write(b []byte) (int, error) {
	n := len(b)
	if len(w.b) < 16384 {
		w.b = append(w.b, b[:min(n, 16384-len(w.b))]...)
	}
	return n, nil
}
func runCommand(ctx context.Context, path string, args ...string) ([]byte, error) {
	if path == "/sbin/sysupgrade" && (len(args) == 1 || (len(args) == 2 && args[0] == "-n")) {
		// After the final destructive operation begins, no HTTP/RPC timeout,
		// context cancellation or inherited output pipe may kill its process.
		null, e := os.OpenFile("/dev/null", os.O_RDWR, 0)
		if e != nil {
			return nil, e
		}
		defer null.Close()
		cmd := exec.Command(path, args...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = null, null, null
		return nil, cmd.Run()
	}
	cmd := exec.CommandContext(ctx, path, args...)
	var out boundedOutput
	cmd.Stdout = &out
	cmd.Stderr = &out
	cmd.WaitDelay = 2 * time.Second
	e := cmd.Run()
	return out.b, e
}
func spawnWorker(mode, id string) error {
	if (mode != "prepare" && mode != "flash") || !idPattern.MatchString(id) {
		return errors.New("Invalid worker")
	}
	bin, e := os.Executable()
	if e != nil {
		return e
	}
	null, e := os.OpenFile("/dev/null", os.O_RDWR, 0)
	if e != nil {
		return e
	}
	defer null.Close()
	cmd := exec.Command(bin, "worker", mode, id)
	cmd.Stdin = null
	cmd.Stdout = null
	cmd.Stderr = null
	cmd.Dir = "/"
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Env = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/", "LANG=C"}
	if e = cmd.Start(); e != nil {
		return e
	}
	return cmd.Process.Release()
}
func checkSpace(dir string, n int64) error {
	if n < 0 || n > maxImage {
		return errors.New("Invalid firmware size")
	}
	var st syscall.Statfs_t
	if e := syscall.Statfs(dir, &st); e != nil {
		return e
	}
	if st.Bavail*uint64(st.Bsize) < uint64(n+(64<<20)) {
		return errors.New("Not enough free temporary storage (64 MiB reserve required)")
	}
	b, e := os.ReadFile("/proc/meminfo")
	if e != nil {
		return e
	}
	var available int64
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) == 3 && f[0] == "MemAvailable:" && f[2] == "kB" {
			available, _ = strconv.ParseInt(f[1], 10, 64)
			available *= 1024
		}
	}
	if available < n+(96<<20) {
		return errors.New("Not enough available RAM (96 MiB reserve required)")
	}
	return nil
}
func (s Service) identity(ctx context.Context) (Identity, string, error) {
	var i Identity
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	b, e := os.ReadFile(s.IdentityPath)
	if e != nil {
		return i, "", errors.New("Installed Mega identity is missing from read-only firmware; install an identity-enabled Mega build first")
	}
	if len(b) > 16384 {
		return i, "", errors.New("Installed firmware metadata is too large")
	}
	if e = decode(b, &i); e != nil {
		return i, "", e
	}
	if e = validIdentity(i, true); e != nil {
		return i, "", e
	}
	b, e = s.Run(ctx, "/bin/ubus", "call", "system", "board")
	if e != nil {
		return i, "", errors.New("Cannot read the router board identity")
	}
	var board struct {
		BoardName string `json:"board_name"`
		RootFS    string `json:"rootfs_type"`
	}
	if e = decode(b, &board); e != nil {
		return i, "", e
	}
	if board.BoardName != boardName || board.RootFS != "squashfs" {
		return i, board.BoardName, errors.New("Updates require the ZBT-Z8803BE running installed SquashFS firmware, not recovery/initramfs")
	}
	return i, board.BoardName, nil
}
func (s Service) info(ctx context.Context) map[string]any {
	i, b, e := s.identity(ctx)
	v := map[string]any{"ok": true, "installed": i, "board": b, "eligible": e == nil}
	if e != nil {
		v["error"] = e.Error()
	}
	if l, err := s.Store.lock(); err == nil {
		if st, err := s.Store.read(); err == nil {
			v["active_id"] = st.ID
		}
		unlock(l)
	}
	return v
}
func (s Service) prepare(ctx context.Context, releaseID int64) (map[string]any, error) {
	if _, _, e := s.identity(ctx); e != nil {
		return nil, e
	}
	if releaseID <= 0 || releaseID > 9007199254740991 {
		return nil, errors.New("Invalid release ID")
	}
	l, e := s.Store.lock()
	if e != nil {
		return nil, e
	}
	defer unlock(l)
	old, e := s.Store.read()
	if e != nil && !os.IsNotExist(e) {
		return nil, e
	}
	if e == nil && (active(old.Phase) || old.FlashStarted) {
		return nil, fmt.Errorf("An update is already %s (job %s); resume or discard it first", old.Phase, old.ID)
	}
	if e == nil {
		if e = os.Remove(s.Store.image(old.ID)); e != nil && !os.IsNotExist(e) {
			return nil, e
		}
	}
	id, e := token()
	if e != nil {
		return nil, e
	}
	st := State{OK: true, ID: id, Phase: "downloading", Release: ReleaseView{ID: releaseID}}
	if e = s.Store.save(st); e != nil {
		return nil, e
	}
	if e = s.Spawn("prepare", id); e != nil {
		st.Phase = "error"
		st.Error = "Cannot start firmware download worker"
		s.Store.save(st)
		return nil, errors.New(st.Error)
	}
	return map[string]any{"ok": true, "id": id}, nil
}
func (s Service) status(id string) (State, error) {
	if !idPattern.MatchString(id) {
		return State{}, errors.New("Invalid update ID")
	}
	l, e := s.Store.lock()
	if e != nil {
		return State{}, e
	}
	defer unlock(l)
	st, e := s.Store.read()
	if e != nil {
		return st, e
	}
	if st.ID != id {
		return State{}, errors.New("Update job not found (temporary data is cleared on reboot)")
	}
	return st, nil
}
func (s Service) discard(id string) (map[string]any, error) {
	if !idPattern.MatchString(id) {
		return nil, errors.New("Invalid update ID")
	}
	e := s.Store.update(id, func(st *State) error {
		if st.Phase == "flashing" || st.FlashStarted {
			return errors.New("Cannot discard firmware after flash confirmation")
		}
		st.Phase = "discarded"
		st.Confirmation = ""
		st.Error = ""
		if e := os.Remove(s.Store.image(id)); e != nil && !os.IsNotExist(e) {
			return e
		}
		return nil
	})
	return map[string]any{"ok": e == nil, "id": id}, e
}
func (s Service) fail(id string, e error) {
	removeImage := false
	defer func() {
		if removeImage {
			_ = os.Remove(s.Store.image(id))
		}
	}()
	// Retry brief lock contention from UI polling; never mutate a later job.
	for n := 0; n < 25; n++ {
		err := s.Store.update(id, func(st *State) error {
			removeImage = !st.FlashStarted
			if st.Phase == "discarded" {
				return nil
			}
			st.Phase = "error"
			st.Confirmation = ""
			st.Error = e.Error()
			return nil
		})
		if err == nil {
			return
		}
		time.Sleep(40 * time.Millisecond)
	}
}
func (s Service) workerStatus(id string) (State, error) {
	var st State
	var e error
	for n := 0; n < 25; n++ {
		st, e = s.status(id)
		if e == nil || !strings.Contains(e.Error(), "Updater is busy") {
			return st, e
		}
		time.Sleep(40 * time.Millisecond)
	}
	return st, e
}
func (s Service) change(id string, fn func(*State) error) error {
	// RPC requests use a nonblocking flock. Workers may wait briefly for a poll.
	var e error
	for n := 0; n < 25; n++ {
		e = s.Store.update(id, func(st *State) error {
			if st.Phase == "discarded" {
				return errors.New("Download discarded")
			}
			return fn(st)
		})
		if e == nil || !strings.Contains(e.Error(), "Updater is busy") {
			return e
		}
		time.Sleep(40 * time.Millisecond)
	}
	return e
}

type progressWriter struct {
	dest    io.Writer
	total   int64
	written int64
	last    time.Time
	tick    func(int64) error
}

func (p *progressWriter) Write(b []byte) (int, error) {
	if p.written+int64(len(b)) > p.total {
		return 0, errors.New("Image is larger than its published size")
	}
	n, e := p.dest.Write(b)
	p.written += int64(n)
	if e == nil && time.Since(p.last) > time.Second {
		e = p.tick(p.written)
		p.last = time.Now()
	}
	return n, e
}
func (s Service) prepareWorker(id string) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	st, e := s.workerStatus(id)
	if e != nil {
		return
	}
	if st.Phase != "downloading" {
		return
	}
	// Duplicate worker invocations must not fail/erase another worker's image.
	workerLock, e := openPrivate(filepath.Join(s.Store.Dir, id+".worker.lock"), syscall.O_RDWR|syscall.O_CREAT)
	if e != nil {
		s.fail(id, e)
		return
	}
	defer workerLock.Close()
	if syscall.Flock(int(workerLock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return
	}
	defer syscall.Flock(int(workerLock.Fd()), syscall.LOCK_UN)
	st, e = s.workerStatus(id)
	if e != nil || st.Phase != "downloading" {
		return
	}
	if _, _, e = s.identity(ctx); e != nil {
		s.fail(id, e)
		return
	}
	r, e := s.Catalog.release(ctx, st.Release.ID)
	if e != nil {
		s.fail(id, e)
		return
	}
	v, asset, hash, e := s.Catalog.verifiedMetadata(ctx, r)
	if e != nil {
		s.fail(id, e)
		return
	}
	if e = s.Space(asset.Size); e != nil {
		s.fail(id, e)
		return
	}
	e = s.change(id, func(st *State) error {
		st.Release = v
		st.Total = asset.Size
		st.SHA256 = hash
		st.Legacy = v.Legacy
		return nil
	})
	if e != nil {
		s.fail(id, e)
		return
	}
	path := s.Store.image(id)
	f, e := openPrivate(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_EXCL)
	if e != nil {
		s.fail(id, e)
		return
	}
	resp, e := s.Catalog.get(ctx, asset.URL)
	if e != nil {
		f.Close()
		s.fail(id, e)
		return
	}
	if resp.ContentLength != -1 && resp.ContentLength != asset.Size {
		resp.Body.Close()
		f.Close()
		s.fail(id, errors.New("Downloaded image size disagrees with release metadata"))
		return
	}
	h := sha256.New()
	p := progressWriter{dest: io.MultiWriter(f, h), total: asset.Size, tick: func(n int64) error {
		return s.change(id, func(st *State) error { st.Bytes = n; return s.Space(asset.Size - n) })
	}}
	n, e := io.Copy(&p, io.LimitReader(resp.Body, asset.Size+1))
	resp.Body.Close()
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e == nil && (n != asset.Size || hex.EncodeToString(h.Sum(nil)) != hash) {
		e = errors.New("Firmware SHA-256 or exact size verification failed")
	}
	if e != nil {
		s.fail(id, e)
		return
	}
	if e = s.change(id, func(st *State) error { st.Phase = "validating"; st.Bytes = n; return nil }); e != nil {
		s.fail(id, e)
		return
	}
	allow, e := s.validate(ctx, id, hash, asset.Size)
	if e != nil {
		s.fail(id, e)
		return
	}
	tok, e := token()
	if e != nil {
		s.fail(id, e)
		return
	}
	if e = s.change(id, func(st *State) error { st.Phase = "ready"; st.AllowBackup = allow; st.Confirmation = tok; return nil }); e != nil {
		s.fail(id, e)
	}
}
func (s Service) validate(ctx context.Context, id, hash string, size int64) (bool, error) {
	if !idPattern.MatchString(id) || !shaPattern.MatchString(hash) || size <= 0 || size > maxImage {
		return false, errors.New("Invalid prepared image metadata")
	}
	if _, _, e := s.identity(ctx); e != nil {
		return false, e
	}
	if e := s.Space(0); e != nil {
		return false, e
	}
	f, e := openPrivate(s.Store.image(id), syscall.O_RDONLY)
	if e != nil {
		return false, e
	}
	st, e := f.Stat()
	if e != nil {
		f.Close()
		return false, e
	}
	if st.Size() != size {
		f.Close()
		return false, errors.New("Prepared image size changed")
	}
	h := sha256.New()
	_, e = io.Copy(h, io.LimitReader(f, maxImage+1))
	f.Close()
	if e != nil {
		return false, e
	}
	if hex.EncodeToString(h.Sum(nil)) != hash {
		return false, errors.New("Prepared image checksum changed")
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	if _, e = s.Run(ctx, "/sbin/sysupgrade", "-T", "-n", s.Store.image(id)); e != nil {
		return false, errors.New("OpenWrt sysupgrade image test failed; force flashing is not permitted")
	}
	arg, _ := json.Marshal(map[string]string{"path": s.Store.image(id)})
	b, e := s.Run(ctx, "/bin/ubus", "call", "system", "validate_firmware_image", string(arg))
	if e != nil {
		return false, errors.New("OpenWrt firmware validation service failed")
	}
	var result struct {
		Valid       *bool `json:"valid"`
		AllowBackup *bool `json:"allow_backup"`
	}
	if e = decode(b, &result); e != nil {
		return false, e
	}
	if result.Valid == nil || !*result.Valid || result.AllowBackup == nil {
		return false, errors.New("OpenWrt rejected this image or omitted compatibility/backup information; force flashing is not permitted")
	}
	return *result.AllowBackup, nil
}
func (s Service) flash(ctx context.Context, id, confirmation string, keep bool) (map[string]any, error) {
	if !idPattern.MatchString(id) || !idPattern.MatchString(confirmation) {
		return nil, errors.New("Invalid update confirmation")
	}
	if _, _, e := s.identity(ctx); e != nil {
		return nil, e
	}
	l, e := s.Store.lock()
	if e != nil {
		return nil, e
	}
	defer unlock(l)
	st, e := s.Store.read()
	if e != nil {
		return nil, e
	}
	if st.ID != id || st.Phase != "ready" || subtle.ConstantTimeCompare([]byte(st.Confirmation), []byte(confirmation)) != 1 {
		return nil, errors.New("Image is not ready or confirmation has expired/already been used")
	}
	if keep && !st.AllowBackup {
		return nil, errors.New("This image does not allow keeping settings")
	}
	// Consume confirmation before spawning so concurrent requests cannot flash
	// twice. The worker rehashes and revalidates immediately before sysupgrade.
	st.Phase = "flashing"
	st.Confirmation = ""
	st.KeepSettings = keep
	if e = s.Store.save(st); e != nil {
		return nil, e
	}
	if e = s.Spawn("flash", id); e != nil {
		st.Phase = "error"
		st.Error = "Cannot start flash worker"
		s.Store.save(st)
		return nil, errors.New(st.Error)
	}
	return map[string]any{"ok": true, "id": id, "accepted": true}, nil
}
func (s Service) flashWorker(id string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	st, e := s.workerStatus(id)
	if e != nil || st.Phase != "flashing" || st.FlashStarted {
		return
	}
	// A second worker process must not be able to launch the same flash. Hold a
	// separate permanent inode lock for the entire validation/flash operation.
	f, e := openPrivate(filepath.Join(s.Store.Dir, "flash.lock"), syscall.O_RDWR|syscall.O_CREAT)
	if e != nil {
		s.fail(id, e)
		return
	}
	defer f.Close()
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	st, e = s.workerStatus(id)
	if e != nil || st.Phase != "flashing" || st.FlashStarted {
		return
	}
	allow, e := s.validate(ctx, id, st.SHA256, st.Total)
	if e != nil {
		s.fail(id, e)
		return
	}
	if st.KeepSettings && !allow {
		s.fail(id, errors.New("Image no longer allows preserving settings"))
		return
	}
	args := []string{}
	if !st.KeepSettings {
		args = append(args, "-n")
	}
	args = append(args, s.Store.image(id))
	if e = s.change(id, func(st *State) error {
		if st.Phase != "flashing" || st.FlashStarted {
			return errors.New("Flash request was already consumed")
		}
		st.FlashStarted = true
		return nil
	}); e != nil {
		s.fail(id, e)
		return
	}
	_, e = s.Run(context.Background(), "/sbin/sysupgrade", args...)
	if e != nil {
		s.fail(id, errors.New("sysupgrade returned an error after launch; image retained. Do not retry or power off until the router's update state is checked. Reboot only once no upgrade is running."))
		return
	}
	// A successful call delegates reboot to procd. Do not claim completion:
	// temporary state vanishes on boot and the reloaded page reads its identity.
}
