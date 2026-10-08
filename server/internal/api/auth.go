package api

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"elixir/server/internal/domain"
)

type ctxKey int

const userKey ctxKey = 0

// AuthUser is the authenticated caller, loaded fresh on every request.
type AuthUser struct {
	ID       string          `json:"id"`
	Username string          `json:"username"`
	FullName string          `json:"full_name"`
	Role     string          `json:"role"`
	Active   bool            `json:"active"`
	Perms    map[string]bool `json:"perms"`
}

// AllPerms: module access flags + special flags.
// view_cost = may see purchase prices / CUMP / margins (enforced by redaction).
// discount = may apply remises on sale lines (enforced at document creation).
var AllPerms = []string{
	"dashboard", "pos", "sales", "purchases", "stock",
	"products", "partners", "assistant", "reports",
	"webstore", "settings", "view_cost", "discount",
}

func defaultPerms(role string) map[string]bool {
	p := map[string]bool{}
	switch role {
	case "admin", "manager":
		for _, k := range AllPerms {
			p[k] = true
		}
	case "cashier":
		p["pos"] = true
		p["assistant"] = true
	}
	return p
}

// EffectivePerms merges per-user overrides over the role defaults.
// Admins always have everything — they manage the system.
func EffectivePerms(role, permsJSON string) map[string]bool {
	p := defaultPerms(role)
	var overrides map[string]bool
	if err := json.Unmarshal([]byte(permsJSON), &overrides); err == nil {
		for k, v := range overrides {
			p[k] = v
		}
	}
	if role == "admin" {
		for _, k := range AllPerms {
			p[k] = true
		}
	}
	return p
}

func ensureAuthSecret(db *sql.DB) ([]byte, error) {
	var v string
	err := db.QueryRow(`SELECT value FROM settings WHERE key = 'auth_secret'`).Scan(&v)
	if err == sql.ErrNoRows {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			return nil, err
		}
		v = hex.EncodeToString(b)
		if _, err := db.Exec(`INSERT INTO settings (key, value, updated_at) VALUES ('auth_secret', ?, ?)`,
			v, domain.NowISO()); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	return hex.DecodeString(v)
}

const tokenTTL = 30 * 24 * time.Hour

func (s *Server) makeToken(uid string) string {
	exp := time.Now().Add(tokenTTL).Unix()
	msg := fmt.Sprintf("%s.%d", uid, exp)
	mac := hmac.New(sha256.New, s.secret)
	mac.Write([]byte(msg))
	return msg + "." + hex.EncodeToString(mac.Sum(nil))
}

func (s *Server) parseToken(tok string) (string, bool) {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return "", false
	}
	msg := parts[0] + "." + parts[1]
	mac := hmac.New(sha256.New, s.secret)
	mac.Write([]byte(msg))
	want := hex.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(want), []byte(parts[2])) {
		return "", false
	}
	exp, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || time.Now().Unix() > exp {
		return "", false
	}
	return parts[0], true
}

func (s *Server) loadAuthUser(uid string) (*AuthUser, error) {
	var u AuthUser
	var permsJSON string
	var active int
	err := s.db.QueryRow(
		`SELECT id, username, full_name, role, perms, active FROM users WHERE id = ?`, uid).
		Scan(&u.ID, &u.Username, &u.FullName, &u.Role, &permsJSON, &active)
	if err != nil {
		return nil, err
	}
	u.Active = active == 1
	u.Perms = EffectivePerms(u.Role, permsJSON)
	return &u, nil
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var id, hash string
	var active int
	err := s.db.QueryRow(`SELECT id, password_hash, active FROM users WHERE username = ?`,
		strings.TrimSpace(in.Username)).Scan(&id, &hash, &active)
	if err != nil || active == 0 ||
		bcrypt.CompareHashAndPassword([]byte(hash), []byte(in.Password)) != nil {
		writeErr(w, http.StatusUnauthorized, "identifiants invalides")
		return
	}
	u, err := s.loadAuthUser(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token": s.makeToken(id),
		"user":  u,
	})
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, authFrom(r))
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		uid, ok := s.parseToken(tok)
		if !ok {
			writeErr(w, http.StatusUnauthorized, "authentification requise")
			return
		}
		u, err := s.loadAuthUser(uid)
		if err != nil || !u.Active {
			writeErr(w, http.StatusUnauthorized, "session invalide")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), userKey, u)))
	})
}

func authFrom(r *http.Request) *AuthUser {
	u, _ := r.Context().Value(userKey).(*AuthUser)
	return u
}

func (s *Server) can(r *http.Request, perm string) bool {
	u := authFrom(r)
	return u != nil && u.Perms[perm]
}

func (s *Server) isAdmin(r *http.Request) bool {
	u := authFrom(r)
	return u != nil && u.Role == "admin"
}

func forbid(w http.ResponseWriter) {
	writeErr(w, http.StatusForbidden, "accès refusé")
}

// docPermOK maps a document type to the permission that authorizes acting on it.
func docPermOK(u *AuthUser, docType string) bool {
	if u == nil {
		return false
	}
	switch {
	case strings.HasPrefix(docType, "PURCHASE"):
		return u.Perms["purchases"]
	case docType == domain.StockAdjustment || docType == domain.StockTransfer ||
		docType == domain.InventoryCount:
		return u.Perms["stock"]
	case docType == domain.PaymentOut:
		return u.Perms["partners"]
	case docType == domain.PaymentIn:
		return u.Perms["partners"] || u.Perms["pos"]
	default: // devis, tickets, factures, BL, avoirs
		return u.Perms["sales"] || u.Perms["pos"]
	}
}
