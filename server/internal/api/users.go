package api

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"golang.org/x/crypto/bcrypt"

	"elixir/server/internal/domain"
)

type UserOut struct {
	ID       string          `json:"id"`
	Username string          `json:"username"`
	FullName string          `json:"full_name"`
	Role     string          `json:"role"`
	Active   bool            `json:"active"`
	Perms    map[string]bool `json:"perms"`
}

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	rows, err := s.db.Query(
		`SELECT id, username, full_name, role, perms, active FROM users ORDER BY username`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []UserOut{}
	for rows.Next() {
		var u UserOut
		var permsJSON string
		var active int
		if err := rows.Scan(&u.ID, &u.Username, &u.FullName, &u.Role, &permsJSON, &active); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		u.Active = active == 1
		u.Perms = EffectivePerms(u.Role, permsJSON)
		items = append(items, u)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type userInput struct {
	Username string           `json:"username"`
	Password *string          `json:"password"` // required on create; optional on update
	FullName string           `json:"full_name"`
	Role     string           `json:"role"`
	Active   *bool            `json:"active"`
	Perms    map[string]bool  `json:"perms"`
}

func (in *userInput) validate(create bool) string {
	if strings.TrimSpace(in.Username) == "" {
		return "le nom d'utilisateur est obligatoire"
	}
	switch in.Role {
	case "admin", "manager", "cashier":
	default:
		return "rôle invalide"
	}
	if create && (in.Password == nil || len(*in.Password) < 4) {
		return "mot de passe obligatoire (4 caractères minimum)"
	}
	if in.Password != nil && len(*in.Password) > 0 && len(*in.Password) < 4 {
		return "mot de passe trop court (4 caractères minimum)"
	}
	return ""
}

func permsJSONOf(p map[string]bool) string {
	if p == nil {
		return "{}"
	}
	b, err := json.Marshal(p)
	if err != nil {
		return "{}"
	}
	return string(b)
}

func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	var in userInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(true); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(*in.Password), bcrypt.DefaultCost)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	_, err = s.db.Exec(`INSERT INTO users (id, username, password_hash, full_name, role, perms, active, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, strings.TrimSpace(in.Username), string(hash), in.FullName, in.Role,
		permsJSONOf(in.Perms), b2i(active), now, now)
	if err != nil {
		writeErr(w, http.StatusConflict, "ce nom d'utilisateur existe déjà")
		return
	}
	s.respondUser(w, id, http.StatusCreated)
}

func (s *Server) updateUser(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in userInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(false); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	// Never let the last admin lock themselves out by demoting/deactivating.
	me := authFrom(r)
	if me != nil && me.ID == id && (in.Role != "admin" || (in.Active != nil && !*in.Active)) {
		writeErr(w, http.StatusConflict,
			"impossible de retirer vos propres droits administrateur")
		return
	}
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	res, err := s.db.Exec(`UPDATE users SET username=?, full_name=?, role=?, perms=?, active=?, updated_at=?
		WHERE id=?`,
		strings.TrimSpace(in.Username), in.FullName, in.Role,
		permsJSONOf(in.Perms), b2i(active), domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusConflict, "ce nom d'utilisateur existe déjà")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "utilisateur introuvable")
		return
	}
	if in.Password != nil && *in.Password != "" {
		hash, err := bcrypt.GenerateFromPassword([]byte(*in.Password), bcrypt.DefaultCost)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if _, err := s.db.Exec(`UPDATE users SET password_hash=?, updated_at=? WHERE id=?`,
			string(hash), domain.NowISO(), id); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	s.respondUser(w, id, http.StatusOK)
}

func (s *Server) respondUser(w http.ResponseWriter, id string, status int) {
	var u UserOut
	var permsJSON string
	var active int
	err := s.db.QueryRow(
		`SELECT id, username, full_name, role, perms, active FROM users WHERE id = ?`, id).
		Scan(&u.ID, &u.Username, &u.FullName, &u.Role, &permsJSON, &active)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "utilisateur introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	u.Active = active == 1
	u.Perms = EffectivePerms(u.Role, permsJSON)
	writeJSON(w, status, u)
}
