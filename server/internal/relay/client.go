// Package relay connects the shop server OUT to the stock-relay service over a
// WebSocket, so off-LAN clients (mobile app, LLM service) can reach this
// server's API through https://relay.example.com/t/<subdomain>/*.
//
// Wire protocol is identical to the Elixir domain-service relay:
//   agent → relay : {"t":"hello","binding_id":..,"token":..}
//   relay → agent : {"t":"ready","key":..} | {"t":"denied"}
//   relay → agent : {"t":"req","id":N,"method","path","headers","body"(b64|null)}
//   agent → relay : {"t":"res","id":N,"status","headers","body"(b64)}
//
// Unlike our other agents, we do NOT inject a loopback-bypass header: the
// Authorization header is forwarded verbatim and this server's own auth
// middleware remains the security gate, even over the tunnel.
package relay

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"math/rand"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

type Config struct {
	Enabled   bool
	URL       string // wss://relay.example.com/agent-ws
	BindingID string
	Token     string
	LocalAddr string // http://127.0.0.1:8543
}

const (
	gzipMinBytes   = 4096
	localTimeout   = 25 * time.Second
	pingInterval   = 20 * time.Second
	maxConcurrency = 8
)

// forwardedHeaders is the exact whitelist the relay sends us; we re-forward the
// same set to the local server (the relay strips everything else).
var forwardedHeaders = []string{"authorization", "content-type", "accept", "accept-encoding"}

type reqMsg struct {
	T       string            `json:"t"`
	ID      int64             `json:"id"`
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Headers map[string]string `json:"headers"`
	Body    *string           `json:"body"`
	Key     string            `json:"key"`
}

var connected atomic.Bool

// Connected reports whether the tunnel is currently up (for the UI indicator).
func Connected() bool { return connected.Load() }

// Run supervises the relay connection until ctx is cancelled. The config is
// re-read before every attempt, so enabling the relay in Paramètres connects
// without restarting the Windows service.
func Run(ctx context.Context, load func() Config) {
	backoff := 2 * time.Second
	for ctx.Err() == nil {
		cfg := load()
		if !cfg.Enabled || cfg.URL == "" || cfg.BindingID == "" {
			// Not configured yet — idle cheaply and look again.
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Second):
			}
			continue
		}

		started := time.Now()
		if err := session(ctx, cfg); err != nil && ctx.Err() == nil {
			log.Printf("relay: %v", err)
		}
		connected.Store(false)
		if ctx.Err() != nil {
			return
		}
		if time.Since(started) > 30*time.Second {
			backoff = 2 * time.Second // real session → reset
		}
		jitter := time.Duration(rand.Int63n(int64(1500 * time.Millisecond)))
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff + jitter):
		}
		backoff *= 2
		if backoff > 15*time.Second {
			backoff = 15 * time.Second
		}
	}
}

func session(ctx context.Context, cfg Config) error {
	dialCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(dialCtx, cfg.URL, nil)
	if err != nil {
		return err
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(16 * 1024 * 1024)

	// hello
	hello, _ := json.Marshal(map[string]string{
		"t":          "hello",
		"binding_id": cfg.BindingID,
		"token":      cfg.Token,
	})
	if err := conn.Write(ctx, websocket.MessageText, hello); err != nil {
		return err
	}

	var writeMu sync.Mutex
	send := func(b []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		wctx, c := context.WithTimeout(ctx, 30*time.Second)
		defer c()
		return conn.Write(wctx, websocket.MessageText, b)
	}

	// Client-initiated pings so NAT idle timeouts don't drop us.
	pingCtx, stopPing := context.WithCancel(ctx)
	defer stopPing()
	go func() {
		t := time.NewTicker(pingInterval)
		defer t.Stop()
		for {
			select {
			case <-pingCtx.Done():
				return
			case <-t.C:
				pctx, c := context.WithTimeout(pingCtx, 10*time.Second)
				_ = conn.Ping(pctx)
				c()
			}
		}
	}()

	sem := make(chan struct{}, maxConcurrency)
	client := &http.Client{Timeout: localTimeout}

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return err
		}
		var m reqMsg
		if json.Unmarshal(data, &m) != nil {
			continue
		}
		switch m.T {
		case "ready":
			connected.Store(true)
			log.Printf("relay: ready (key=%s)", m.Key)
		case "denied":
			log.Printf("relay: server denied auth — check binding_id/token")
			return nil // back off, don't hot-loop
		case "req":
			sem <- struct{}{}
			go func(rm reqMsg) {
				defer func() { <-sem }()
				out := serveLocal(client, cfg.LocalAddr, rm)
				_ = send(out)
			}(m)
		}
	}
}

func serveLocal(client *http.Client, localAddr string, m reqMsg) []byte {
	status := http.StatusBadGateway
	respHeaders := map[string]string{"content-type": "application/json"}
	var rbody []byte = []byte(`{"error":"agent local call failed"}`)

	var bodyReader io.Reader
	if m.Body != nil && *m.Body != "" {
		if raw, err := base64.StdEncoding.DecodeString(*m.Body); err == nil {
			bodyReader = bytes.NewReader(raw)
		}
	}

	req, err := http.NewRequest(m.Method, localAddr+m.Path, bodyReader)
	if err == nil {
		for _, h := range forwardedHeaders {
			if v, ok := m.Headers[h]; ok {
				req.Header.Set(h, v)
			}
		}
		if resp, err := client.Do(req); err == nil {
			defer resp.Body.Close()
			if b, err := io.ReadAll(resp.Body); err == nil {
				rbody = b
				status = resp.StatusCode
				if ct := resp.Header.Get("Content-Type"); ct != "" {
					respHeaders["content-type"] = ct
				}
			}
		}
	}

	// gzip the response when the caller accepts it and it actually shrinks.
	acceptsGzip := strings.Contains(
		strings.ToLower(m.Headers["accept-encoding"]), "gzip")
	if acceptsGzip && len(rbody) >= gzipMinBytes {
		var buf bytes.Buffer
		zw, _ := gzip.NewWriterLevel(&buf, 6)
		zw.Write(rbody)
		zw.Close()
		if buf.Len() < len(rbody) {
			rbody = buf.Bytes()
			respHeaders["content-encoding"] = "gzip"
		}
	}

	out, _ := json.Marshal(map[string]any{
		"t":       "res",
		"id":      m.ID,
		"status":  status,
		"headers": respHeaders,
		"body":    base64.StdEncoding.EncodeToString(rbody),
	})
	return out
}
