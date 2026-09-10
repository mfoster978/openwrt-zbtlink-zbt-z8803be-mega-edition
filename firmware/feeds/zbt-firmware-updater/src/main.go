// SPDX-License-Identifier: MIT
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"time"
)

type Request struct {
	Page         int    `json:"page"`
	ReleaseID    int64  `json:"release_id"`
	ID           string `json:"id"`
	Confirmation string `json:"confirmation"`
	KeepSettings bool   `json:"keep_settings"`
}

func methods() map[string]any {
	return map[string]any{"info": map[string]any{}, "check": map[string]any{"page": 1}, "prepare": map[string]any{"release_id": 1}, "status": map[string]any{"id": ""}, "flash": map[string]any{"id": "", "confirmation": "", "keep_settings": false}, "discard": map[string]any{"id": ""}}
}
func (s Service) call(ctx context.Context, method string, r Request) (any, error) {
	switch method {
	case "info":
		return s.info(ctx), nil
	case "check":
		return s.Catalog.check(ctx, r.Page)
	case "prepare":
		return s.prepare(ctx, r.ReleaseID)
	case "status":
		return s.status(r.ID)
	case "discard":
		return s.discard(r.ID)
	case "flash":
		return s.flash(ctx, r.ID, r.Confirmation, r.KeepSettings)
	}
	return nil, errors.New("Unknown firmware method")
}
func main() {
	s := production()
	args := os.Args[1:]
	if len(args) == 3 && args[0] == "worker" && idPattern.MatchString(args[2]) {
		if args[1] == "prepare" {
			s.prepareWorker(args[2])
		}
		if args[1] == "flash" {
			s.flashWorker(args[2])
		}
		return
	}
	var result any
	var e error
	if len(args) == 1 && args[0] == "list" {
		result = methods()
	} else if len(args) == 2 && args[0] == "call" {
		var b []byte
		b, e = io.ReadAll(io.LimitReader(os.Stdin, 16385))
		var r Request
		if e == nil && len(b) > 16384 {
			e = errors.New("Request too large")
		}
		if e == nil {
			e = decode(b, &r)
		}
		if e == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			result, e = s.call(ctx, args[1], r)
		}
	} else {
		e = errors.New("Invalid rpcd invocation")
	}
	if e != nil {
		result = map[string]any{"ok": false, "error": e.Error()}
	}
	json.NewEncoder(os.Stdout).Encode(result)
}
