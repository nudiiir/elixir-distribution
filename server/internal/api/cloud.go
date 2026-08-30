package api

import (
	"database/sql"
	"net/http"
)

// Cloud settings live in the settings table rather than in environment
// variables: a shopkeeper can edit them in Paramètres, whereas changing the
// environment of a Windows service means editing the registry.
var cloudKeys = []string{
	"relay_enabled",     // "1" to connect out to the relay
	"relay_url",         // wss://relay.example.com/agent-ws
	"relay_binding_id",  // this shop's binding
	"relay_token",       // its secret
	"relay_subdomain",   // the /t/<sub>/ segment — used by the app, not the tunnel
	"llm_url",           // https://llm.example.com
	"invoice_url",       // https://invoice.example.com
}

// LoadCloudSettings reads the cloud configuration. Environment variables win,
// so a dev machine can override without touching the database.
func LoadCloudSettings(db *sql.DB) map[string]string {
	out := map[string]string{}
	rows, err := db.Query(`SELECT key, value FROM settings WHERE key LIKE 'relay_%' OR key LIKE 'llm_%' OR key LIKE 'invoice_%'`)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var k, v string
		if rows.Scan(&k, &v) == nil {
			out[k] = v
		}
	}
	return out
}

// cloudStatus reports what the client needs to reach the cloud services:
// which URLs to call and under which shop id. The relay token is never
// returned — the app has no use for it and it would only widen its exposure.
func (s *Server) cloudStatus(w http.ResponseWriter, r *http.Request) {
	cfg := LoadCloudSettings(s.db)
	writeJSON(w, http.StatusOK, map[string]any{
		"relay_enabled":   cfg["relay_enabled"] == "1",
		"relay_url":       cfg["relay_url"],
		"relay_subdomain": cfg["relay_subdomain"],
		"relay_connected": relayConnected(),
		"llm_url":         cfg["llm_url"],
		"invoice_url":     cfg["invoice_url"],
		"configured":      cfg["relay_binding_id"] != "" && cfg["relay_token"] != "",
	})
}

// relayState is set by the relay client so the UI can show a live indicator.
var relayStateFn func() bool

// SetRelayStateFn wires the relay client's liveness into the API.
func SetRelayStateFn(fn func() bool) { relayStateFn = fn }

func relayConnected() bool {
	if relayStateFn == nil {
		return false
	}
	return relayStateFn()
}
