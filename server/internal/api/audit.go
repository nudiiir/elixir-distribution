package api

import (
	"net/http"
	"strconv"

	"elixir/server/internal/domain"
)

// audit records who did what. Failures are swallowed on purpose: the journal
// must never block the business action it describes.
func (s *Server) audit(r *http.Request, action, entity, entityID, detail string) {
	u := authFrom(r)
	var uid any
	who := ""
	if u != nil {
		uid = u.ID
		who = u.Username
	}
	if who != "" {
		detail = who + " — " + detail
	}
	s.db.Exec(`INSERT INTO audit_log (id, user_id, action, entity, entity_id, detail, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		domain.NewID(), uid, action, entity, entityID, detail, domain.NowISO())
}

type AuditEntry struct {
	ID        string  `json:"id"`
	Username  string  `json:"username"`
	Action    string  `json:"action"`
	Entity    string  `json:"entity"`
	EntityID  *string `json:"entity_id"`
	Detail    *string `json:"detail"`
	CreatedAt string  `json:"created_at"`
}

func (s *Server) listAudit(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 150
	}
	rows, err := s.db.Query(`SELECT a.id, COALESCE(u.username, ''), a.action, a.entity,
			a.entity_id, a.detail, a.created_at
		FROM audit_log a LEFT JOIN users u ON u.id = a.user_id
		ORDER BY a.created_at DESC LIMIT ?`, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []AuditEntry{}
	for rows.Next() {
		var e AuditEntry
		if err := rows.Scan(&e.ID, &e.Username, &e.Action, &e.Entity, &e.EntityID,
			&e.Detail, &e.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, e)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}
