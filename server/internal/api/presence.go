package api

import (
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// Presence is a lightweight in-memory registry of client apps currently
// running against this server. Each app heartbeats every ~30s; an entry that
// misses three beats is considered gone. Nothing is persisted — a restart
// simply starts empty and refills within a minute.

const presenceTTL = 95 * time.Second

type presenceEntry struct {
	UserID   string
	Username string
	FullName string
	Device   string
	Screen   string
	Kind     string // "desktop" | "mobile"
	Seen     time.Time
}

type presenceRegistry struct {
	mu      sync.Mutex
	entries map[string]presenceEntry
}

func newPresenceRegistry() *presenceRegistry {
	return &presenceRegistry{entries: map[string]presenceEntry{}}
}

func (s *Server) presenceBeat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Device string `json:"device"`
		Screen string `json:"screen"`
		Kind   string `json:"kind"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	u := authFrom(r)
	device := strings.TrimSpace(in.Device)
	if device == "" {
		device = "poste"
	}
	if in.Kind != "mobile" {
		in.Kind = "desktop"
	}
	s.presence.mu.Lock()
	s.presence.entries[device+"|"+u.ID] = presenceEntry{
		UserID:   u.ID,
		Username: u.Username,
		FullName: u.FullName,
		Device:   device,
		Screen:   in.Screen,
		Kind:     in.Kind,
		Seen:     time.Now(),
	}
	s.presence.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) presenceList(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	type item struct {
		Device     string `json:"device"`
		Username   string `json:"username"`
		FullName   string `json:"full_name"`
		Screen     string `json:"screen"`
		Kind       string `json:"kind"`
		SecondsAgo int    `json:"seconds_ago"`
	}
	items := []item{}
	s.presence.mu.Lock()
	for k, e := range s.presence.entries {
		if now.Sub(e.Seen) > presenceTTL {
			delete(s.presence.entries, k)
			continue
		}
		items = append(items, item{
			Device:     e.Device,
			Username:   e.Username,
			FullName:   e.FullName,
			Screen:     e.Screen,
			Kind:       e.Kind,
			SecondsAgo: int(now.Sub(e.Seen).Seconds()),
		})
	}
	s.presence.mu.Unlock()
	sort.Slice(items, func(i, j int) bool {
		if items[i].Device != items[j].Device {
			return items[i].Device < items[j].Device
		}
		return items[i].Username < items[j].Username
	})
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
