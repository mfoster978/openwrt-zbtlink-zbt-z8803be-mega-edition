// SPDX-License-Identifier: MIT
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
)

var idPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

type State struct {
	OK           bool        `json:"ok"`
	ID           string      `json:"id"`
	Phase        string      `json:"phase"`
	Bytes        int64       `json:"bytes"`
	Total        int64       `json:"total"`
	Error        string      `json:"error,omitempty"`
	Release      ReleaseView `json:"release"`
	SHA256       string      `json:"sha256,omitempty"`
	AllowBackup  bool        `json:"allow_backup"`
	Legacy       bool        `json:"legacy"`
	Confirmation string      `json:"confirmation,omitempty"`
	KeepSettings bool        `json:"keep_settings"`
	FlashStarted bool        `json:"flash_started,omitempty"`
}

func token() (string, error) {
	b := make([]byte, 16)
	_, e := rand.Read(b)
	return hex.EncodeToString(b), e
}

type Store struct{ Dir string }

// /tmp is shared, but this directory must be owned by this process's UID and
// private. Never fix up/reuse an attacker's symlink, permissive directory, file,
// or lock. RPC clients never provide directory names or image paths.
func (s Store) secure() error {
	if e := os.Mkdir(s.Dir, 0700); e != nil && !os.IsExist(e) {
		return e
	}
	st, e := os.Lstat(s.Dir)
	if e != nil {
		return e
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok || !st.IsDir() || st.Mode().Perm() != 0700 || sys.Uid != uint32(os.Geteuid()) {
		return errors.New("Unsafe updater state directory; refusing to continue")
	}
	return nil
}
func openPrivate(path string, flags int) (*os.File, error) {
	fd, e := syscall.Open(path, flags|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), path)
	st, e := f.Stat()
	if e != nil {
		f.Close()
		return nil, e
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 || sys.Uid != uint32(os.Geteuid()) || sys.Nlink != 1 {
		f.Close()
		return nil, errors.New("Unsafe updater state file")
	}
	return f, nil
}
func (s Store) lock() (*os.File, error) {
	if e := s.secure(); e != nil {
		return nil, e
	}
	path := filepath.Join(s.Dir, "lock")
	f, e := openPrivate(path, syscall.O_RDWR|syscall.O_CREAT)
	if e != nil {
		return nil, e
	}
	if e = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		f.Close()
		return nil, errors.New("Updater is busy; retry shortly")
	}
	a, e := f.Stat()
	b, e2 := os.Lstat(path)
	if e != nil || e2 != nil || !os.SameFile(a, b) {
		f.Close()
		return nil, errors.New("Updater lock changed unexpectedly")
	}
	return f, nil
}
func unlock(f *os.File) { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }
func (s Store) read() (State, error) {
	var st State
	f, e := openPrivate(filepath.Join(s.Dir, "current.json"), syscall.O_RDONLY)
	if e != nil {
		return st, e
	}
	defer f.Close()
	b, e := io.ReadAll(io.LimitReader(f, 256<<10))
	if e != nil {
		return st, e
	}
	e = decode(b, &st)
	if e == nil && !idPattern.MatchString(st.ID) {
		e = errors.New("Invalid saved update state")
	}
	return st, e
}
func (s Store) save(st State) error {
	if !idPattern.MatchString(st.ID) {
		return errors.New("Invalid update ID")
	}
	b, e := json.Marshal(st)
	if e != nil {
		return e
	}
	f, e := os.CreateTemp(s.Dir, ".state-")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	_, e = f.Write(b)
	ce := f.Close()
	if e != nil {
		return e
	}
	if ce != nil {
		return ce
	}
	return os.Rename(f.Name(), filepath.Join(s.Dir, "current.json"))
}
func (s Store) image(id string) string { return filepath.Join(s.Dir, id+".bin") }
func (s Store) update(id string, fn func(*State) error) error {
	l, e := s.lock()
	if e != nil {
		return e
	}
	defer unlock(l)
	st, e := s.read()
	if e != nil {
		return e
	}
	if st.ID != id {
		return errors.New("Update job was replaced")
	}
	if e = fn(&st); e != nil {
		return e
	}
	return s.save(st)
}
func active(phase string) bool {
	switch phase {
	case "downloading", "validating", "ready", "flashing":
		return true
	}
	return false
}
