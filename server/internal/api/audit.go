package api

import (
	"net/http"
	"strconv"
	"strings"

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
	UserID    *string `json:"user_id"`
	Username  string  `json:"username"`
	FullName  string  `json:"full_name"`
	Action    string  `json:"action"`
	Entity    string  `json:"entity"`
	EntityID  *string `json:"entity_id"`
	Detail    *string `json:"detail"`
	CreatedAt string  `json:"created_at"`
}

// listAudit: the activity journal, newest first. Filters (all optional):
// user_id, action (exact, or a prefix ending with '.' such as "document."),
// from / to (YYYY-MM-DD inclusive, or full UTC timestamps), q (text in the
// detail), limit (≤ 1000). The response also lists the distinct actions so
// the screen can offer them in a dropdown.
func (s *Server) listAudit(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	qv := r.URL.Query()
	limit, _ := strconv.Atoi(qv.Get("limit"))
	if limit <= 0 || limit > 1000 {
		limit = 150
	}
	where := []string{"1=1"}
	args := []any{}
	if v := qv.Get("user_id"); v != "" {
		where = append(where, "a.user_id = ?")
		args = append(args, v)
	}
	if v := qv.Get("action"); v != "" {
		if strings.HasSuffix(v, ".") {
			where = append(where, "a.action LIKE ? ESCAPE '\\'")
			args = append(args, auditLikeEscape(v)+"%")
		} else {
			where = append(where, "a.action = ?")
			args = append(args, v)
		}
	}
	if v := qv.Get("from"); v != "" {
		where = append(where, "a.created_at >= ?")
		args = append(args, v)
	}
	if v := qv.Get("to"); v != "" {
		// A bare date is inclusive (everything of that day); a full timestamp
		// is an exclusive upper bound.
		if len(v) == 10 {
			v += "~"
		}
		where = append(where, "a.created_at < ?")
		args = append(args, v)
	}
	if v := strings.TrimSpace(qv.Get("q")); v != "" {
		where = append(where, "(a.detail LIKE ? ESCAPE '\\' OR a.action LIKE ? ESCAPE '\\' OR a.entity_id = ?)")
		p := "%" + auditLikeEscape(v) + "%"
		args = append(args, p, p, v)
	}
	args = append(args, limit)
	rows, err := s.db.Query(`SELECT a.id, a.user_id, COALESCE(u.username, ''), COALESCE(u.full_name, ''),
			a.action, a.entity, a.entity_id, a.detail, a.created_at
		FROM audit_log a LEFT JOIN users u ON u.id = a.user_id
		WHERE `+strings.Join(where, " AND ")+`
		ORDER BY a.created_at DESC LIMIT ?`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []AuditEntry{}
	for rows.Next() {
		var e AuditEntry
		if err := rows.Scan(&e.ID, &e.UserID, &e.Username, &e.FullName, &e.Action, &e.Entity, &e.EntityID,
			&e.Detail, &e.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, e)
	}
	rows.Close()
	actions := []string{}
	if ar, err := s.db.Query(`SELECT DISTINCT action FROM audit_log ORDER BY action`); err == nil {
		for ar.Next() {
			var a string
			if ar.Scan(&a) == nil {
				actions = append(actions, a)
			}
		}
		ar.Close()
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "actions": actions})
}

func auditLikeEscape(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(s)
}
