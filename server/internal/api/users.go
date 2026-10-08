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

// UserOut is what the users list returns: the same shape as /auth/me
// (perms, limits, scope, role, depots, has_pin, last_login_at…).
type UserOut = AuthUser

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	rows, err := s.db.Query(authUserSelect + ` ORDER BY u.username`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []*UserOut{}
	for rows.Next() {
		u, err := scanAuthUser(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, u)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type userInput struct {
	Username           string          `json:"username"`
	Password           *string         `json:"password"` // required on create; optional on update (= reset)
	FullName           string          `json:"full_name"`
	Role               string          `json:"role"`    // legacy: admin | manager | cashier
	RoleID             *string         `json:"role_id"` // 0013: editable role
	Active             *bool           `json:"active"`
	Perms              map[string]bool `json:"perms"` // legacy per-user overrides
	Phone              *string         `json:"phone"`
	Email              *string         `json:"email"`
	WarehouseIDs       []string        `json:"warehouse_ids"`
	DefaultWarehouseID *string         `json:"default_warehouse_id"`
}

// resolve validates the input and returns the role id + legacy role column.
func (s *Server) resolveUserInput(in *userInput, create bool) (roleID, legacy, field, msg string) {
	in.Username = strings.TrimSpace(in.Username)
	if in.Username == "" {
		return "", "", "username", "l'identifiant est obligatoire"
	}
	if strings.ContainsAny(in.Username, " \t") {
		return "", "", "username", "l'identifiant ne doit pas contenir d'espace"
	}
	if in.RoleID != nil && *in.RoleID != "" {
		roleID = *in.RoleID
		var perms string
		if err := s.db.QueryRow(`SELECT perms_json FROM roles WHERE id = ?`, roleID).Scan(&perms); err != nil {
			return "", "", "role_id", "rôle introuvable"
		}
		legacy = legacyRoleFor(roleID, computePerms(roleID, perms, "{}"))
	} else {
		switch in.Role {
		case "admin", "manager", "cashier":
		default:
			return "", "", "role_id", "choisissez un rôle"
		}
		roleID, legacy = legacyRoleID(in.Role), in.Role
	}
	if create && (in.Password == nil || len(*in.Password) < 4) {
		return "", "", "password", "mot de passe obligatoire (4 caractères minimum)"
	}
	if in.Password != nil && len(*in.Password) > 0 && len(*in.Password) < 4 {
		return "", "", "password", "mot de passe trop court (4 caractères minimum)"
	}
	if in.Email != nil {
		e := strings.TrimSpace(*in.Email)
		if e != "" && (!strings.Contains(e, "@") || strings.ContainsAny(e, " ")) {
			return "", "", "email", "adresse email invalide"
		}
	}
	return roleID, legacy, "", ""
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

func warehousesJSON(ids []string, def *string) (string, *string) {
	clean := []string{}
	seen := map[string]bool{}
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id != "" && !seen[id] {
			seen[id] = true
			clean = append(clean, id)
		}
	}
	var d *string
	if def != nil && *def != "" {
		v := *def
		d = &v
		if len(clean) > 0 && !seen[v] {
			clean = append(clean, v)
		}
	}
	b, _ := json.Marshal(clean)
	return string(b), d
}

func strOr(p *string) string {
	if p == nil {
		return ""
	}
	return strings.TrimSpace(*p)
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
	roleID, legacy, field, msg := s.resolveUserInput(&in, true)
	if msg != "" {
		writeFieldErr(w, http.StatusBadRequest, field, msg)
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
	whJSON, def := warehousesJSON(in.WarehouseIDs, in.DefaultWarehouseID)
	_, err = s.db.Exec(`INSERT INTO users (id, username, password_hash, full_name, role, perms, active,
			role_id, phone, email, warehouse_ids_json, default_warehouse_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.Username, string(hash), strings.TrimSpace(in.FullName), legacy,
		permsJSONOf(in.Perms), b2i(active), roleID, strOr(in.Phone), strOr(in.Email),
		whJSON, def, now, now)
	if err != nil {
		writeFieldErr(w, http.StatusConflict, "username", "cet identifiant existe déjà")
		return
	}
	s.audit(r, "user.create", "user", id, in.Username)
	s.respondUser(w, id, http.StatusCreated)
}

func (s *Server) activeAdminsExcept(id string) int {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM users WHERE active = 1 AND id <> ?
		AND COALESCE(role_id, CASE role WHEN 'admin' THEN 'role-admin' ELSE '' END) = 'role-admin'`, id).Scan(&n)
	return n
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
	roleID, legacy, field, msg := s.resolveUserInput(&in, false)
	if msg != "" {
		writeFieldErr(w, http.StatusBadRequest, field, msg)
		return
	}
	cur, err := s.loadAuthUser(id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "utilisateur introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	// Never let the admin lock themselves out by demoting/deactivating.
	me := authFrom(r)
	if me != nil && me.ID == id && (roleID != RoleAdminID || !active) {
		writeFieldErr(w, http.StatusConflict, "role_id",
			"impossible de retirer vos propres droits administrateur")
		return
	}
	if cur.RoleID == RoleAdminID && (roleID != RoleAdminID || !active) && s.activeAdminsExcept(id) == 0 {
		writeFieldErr(w, http.StatusConflict, "role_id",
			"il faut garder au moins un administrateur actif")
		return
	}
	// The new users page sends role_id without per-user overrides: the role
	// becomes the only source of rights. The legacy UI keeps its overrides.
	perms := ""
	if in.Perms != nil {
		perms = permsJSONOf(in.Perms)
	} else if in.RoleID != nil {
		perms = "{}"
	}
	now := domain.NowISO()
	q := `UPDATE users SET username=?, full_name=?, role=?, role_id=?, active=?, updated_at=?`
	args := []any{in.Username, strings.TrimSpace(in.FullName), legacy, roleID, b2i(active), now}
	if perms != "" {
		q += `, perms=?`
		args = append(args, perms)
	}
	if in.Phone != nil {
		q += `, phone=?`
		args = append(args, strOr(in.Phone))
	}
	if in.Email != nil {
		q += `, email=?`
		args = append(args, strOr(in.Email))
	}
	if in.WarehouseIDs != nil || in.DefaultWarehouseID != nil {
		whJSON, def := warehousesJSON(in.WarehouseIDs, in.DefaultWarehouseID)
		q += `, warehouse_ids_json=?, default_warehouse_id=?`
		args = append(args, whJSON, def)
	}
	q += ` WHERE id=?`
	args = append(args, id)
	if _, err := s.db.Exec(q, args...); err != nil {
		writeFieldErr(w, http.StatusConflict, "username", "cet identifiant existe déjà")
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
		s.audit(r, "user.password", "user", id, "mot de passe réinitialisé")
	}
	s.audit(r, "user.update", "user", id, in.Username)
	s.respondUser(w, id, http.StatusOK)
}

func (s *Server) respondUser(w http.ResponseWriter, id string, status int) {
	u, err := s.loadAuthUser(id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "utilisateur introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, u)
}
