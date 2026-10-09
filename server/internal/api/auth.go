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

const (
	userKey     ctxKey = 0
	approvalKey ctxKey = 1
)

// AuthUser is the authenticated caller, loaded fresh on every request.
type AuthUser struct {
	ID       string          `json:"id"`
	Username string          `json:"username"`
	FullName string          `json:"full_name"`
	Role     string          `json:"role"` // legacy: admin | manager | cashier
	Active   bool            `json:"active"`
	Perms    map[string]bool `json:"perms"`
	// Rôle éditable (0013) : limites et périmètre de données voyagent avec l'utilisateur.
	RoleID             string           `json:"role_id"`
	RoleName           string           `json:"role_name"`
	Limits             map[string]int64 `json:"limits"`
	Scope              string           `json:"scope"` // all | own | warehouse
	WarehouseIDs       []string         `json:"warehouse_ids"`
	DefaultWarehouseID *string          `json:"default_warehouse_id"`
	HasPin             bool             `json:"has_pin"`
	Phone              string           `json:"phone"`
	Email              string           `json:"email"`
	LastLoginAt        *string          `json:"last_login_at"`
	TokenVersion       int64            `json:"-"`
}

// Built-in role ids (seeded by migration 0013).
const (
	RoleAdminID   = "role-admin"
	RoleManagerID = "role-manager"
	RoleCashierID = "role-cashier"
)

// Modules = the legacy access keys; every s.can(r, "<module>") keeps working
// because "<module>" is derived from "<module>.view".
var Modules = []string{
	"dashboard", "pos", "sales", "purchases", "stock",
	"products", "partners", "assistant", "reports",
	"webstore", "settings",
	// Distribution (0016) : commandes clients, livraisons, relation client, tarifs.
	"orders", "deliveries", "crm", "pricing",
}

// ModuleActions lists, per module, the actions of the permission grid.
var ModuleActions = map[string][]string{
	"dashboard": {"view"},
	"pos":       {"view"},
	"assistant": {"view"},
	"webstore":  {"view"},
	"settings":  {"view"},
	"reports":   {"view", "export", "print"},
	"sales":     {"view", "create", "edit", "cancel", "validate", "export", "print"},
	"purchases": {"view", "create", "edit", "cancel", "validate", "export", "print"},
	"stock":     {"view", "create", "edit", "cancel", "validate", "export", "print"},
	"products":  {"view", "create", "edit", "export", "print"},
	"partners":  {"view", "create", "edit", "export", "print"},
	// orders.manage : saisir, préparer, livrer, facturer ; orders.validate :
	// valider (contrôle crédit) ; orders.override_credit : passer outre l'alerte.
	"orders":     {"view", "manage", "validate", "override_credit"},
	"deliveries": {"view", "manage"},
	// crm.all_customers : un rôle au périmètre « own » voit quand même tous les clients.
	"crm":     {"view", "edit", "all_customers"},
	"pricing": {"view", "edit"},
}

// SpecialRights are the « droits particuliers » of a role.
var SpecialRights = []string{
	"view_cost", "discount", "price_edit", "credit_sale", "negative_stock",
	"refund", "void_document", "change_date", "open_drawer", "close_till",
	"view_today", "stock_adjust", "import_data", "export_data",
}

// LimitKeys travel in roles.limits_json (0 = pas de limite).
var LimitKeys = []string{"max_discount_pct", "max_credit", "approval_above"}

// AllPerms: every key a role can carry (module keys included for the legacy UI).
var AllPerms = allPermKeys()

func allPermKeys() []string {
	out := append([]string{}, Modules...)
	for _, m := range Modules {
		for _, a := range ModuleActions[m] {
			out = append(out, m+"."+a)
		}
	}
	return append(out, SpecialRights...)
}

func isKnownPerm(k string) bool {
	for _, p := range AllPerms {
		if p == k {
			return true
		}
	}
	return false
}

func isModule(k string) bool {
	for _, m := range Modules {
		if m == k {
			return true
		}
	}
	return false
}

// builtinRolePerms mirrors the perms_json seeded by 0013 (a test checks it).
func builtinRolePerms(roleID string) map[string]bool {
	p := map[string]bool{}
	switch roleID {
	case RoleAdminID, RoleManagerID:
		for _, k := range AllPerms {
			if !isModule(k) {
				p[k] = true
			}
		}
		if roleID == RoleManagerID {
			// Selling beyond stock follows the shop switch unless a role ticks it.
			delete(p, "negative_stock")
		}
	case RoleCashierID:
		for _, k := range []string{"pos.view", "assistant.view", "sales.view", "sales.create",
			"sales.print", "open_drawer", "close_till"} {
			p[k] = true
		}
	}
	return p
}

func legacyRoleID(role string) string {
	switch role {
	case "admin":
		return RoleAdminID
	case "manager":
		return RoleManagerID
	default:
		return RoleCashierID
	}
}

// computePerms = role perms, every known key filled (false when absent), the
// module keys derived from "<module>.view", then the legacy per-user overrides
// (users.perms, from before 0013): a module key there switches the whole module.
func computePerms(roleID, rolePermsJSON, userPermsJSON string) map[string]bool {
	p := map[string]bool{}
	for _, k := range AllPerms {
		p[k] = false
	}
	if roleID == RoleAdminID {
		for _, k := range AllPerms {
			p[k] = true
		}
		return p
	}
	var rp map[string]bool
	if json.Unmarshal([]byte(rolePermsJSON), &rp) == nil {
		for k, v := range rp {
			if isKnownPerm(k) && !isModule(k) {
				p[k] = v
			}
		}
	}
	for _, m := range Modules {
		p[m] = p[m+".view"]
	}
	var overrides map[string]bool
	if json.Unmarshal([]byte(userPermsJSON), &overrides) == nil {
		for k, v := range overrides {
			if isModule(k) {
				p[k] = v
				for _, a := range ModuleActions[k] {
					p[k+"."+a] = v
				}
			} else if isKnownPerm(k) {
				p[k] = v
			}
		}
	}
	return p
}

// EffectivePerms (legacy signature): perms of a legacy role with per-user
// overrides, using the built-in role definitions.
func EffectivePerms(role, permsJSON string) map[string]bool {
	id := legacyRoleID(role)
	b, _ := json.Marshal(builtinRolePerms(id))
	return computePerms(id, string(b), permsJSON)
}

// legacyRoleFor keeps users.role consistent for the code that still reads it:
// 'admin' only for the Administrateur role.
func legacyRoleFor(roleID string, perms map[string]bool) string {
	if roleID == RoleAdminID {
		return "admin"
	}
	if roleID == RoleManagerID {
		return "manager"
	}
	if roleID == RoleCashierID {
		return "cashier"
	}
	for _, k := range []string{"purchases.view", "stock.view", "settings.view", "void_document"} {
		if perms[k] {
			return "manager"
		}
	}
	return "cashier"
}

func parseLimits(js string) map[string]int64 {
	out := map[string]int64{}
	for _, k := range LimitKeys {
		out[k] = 0
	}
	var m map[string]int64
	if json.Unmarshal([]byte(js), &m) == nil {
		for _, k := range LimitKeys {
			if v, ok := m[k]; ok && v > 0 {
				out[k] = v
			}
		}
	}
	return out
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

// makeToken signs "uid.version.exp". The version is the user's token_version:
// « Déconnecter partout » bumps it and every older token stops working.
func (s *Server) makeToken(uid string) string {
	var ver int64
	if s.db != nil {
		s.db.QueryRow(`SELECT token_version FROM users WHERE id = ?`, uid).Scan(&ver)
	}
	return s.makeTokenV(uid, ver)
}

func (s *Server) makeTokenV(uid string, ver int64) string {
	exp := time.Now().Add(tokenTTL).Unix()
	msg := fmt.Sprintf("%s.%d.%d", uid, ver, exp)
	mac := hmac.New(sha256.New, s.secret)
	mac.Write([]byte(msg))
	return msg + "." + hex.EncodeToString(mac.Sum(nil))
}

// parseToken accepts the current 4-part token and the pre-0013 3-part one
// (version 0).
func (s *Server) parseToken(tok string) (string, int64, bool) {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 && len(parts) != 4 {
		return "", 0, false
	}
	n := len(parts)
	msg := strings.Join(parts[:n-1], ".")
	mac := hmac.New(sha256.New, s.secret)
	mac.Write([]byte(msg))
	want := hex.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(want), []byte(parts[n-1])) {
		return "", 0, false
	}
	exp, err := strconv.ParseInt(parts[n-2], 10, 64)
	if err != nil || time.Now().Unix() > exp {
		return "", 0, false
	}
	var ver int64
	if n == 4 {
		if ver, err = strconv.ParseInt(parts[1], 10, 64); err != nil {
			return "", 0, false
		}
	}
	return parts[0], ver, true
}

type queryRower interface {
	QueryRow(query string, args ...any) *sql.Row
}

const authUserSelect = `SELECT u.id, u.username, u.full_name, u.role, u.perms, u.active,
		COALESCE(u.role_id, CASE u.role WHEN 'admin' THEN 'role-admin'
			WHEN 'manager' THEN 'role-manager' ELSE 'role-cashier' END),
		COALESCE(r.name, ''), COALESCE(r.perms_json, '{}'), COALESCE(r.limits_json, '{}'),
		COALESCE(r.scope, 'all'), COALESCE(u.pin_hash, ''), u.phone, u.email,
		u.warehouse_ids_json, u.default_warehouse_id, u.last_login_at, u.token_version
	FROM users u
	LEFT JOIN roles r ON r.id = COALESCE(u.role_id, CASE u.role WHEN 'admin' THEN 'role-admin'
			WHEN 'manager' THEN 'role-manager' ELSE 'role-cashier' END)`

func scanAuthUser(row interface{ Scan(...any) error }) (*AuthUser, error) {
	var u AuthUser
	var permsJSON, rolePerms, limits, pin, whJSON string
	var active int
	if err := row.Scan(&u.ID, &u.Username, &u.FullName, &u.Role, &permsJSON, &active,
		&u.RoleID, &u.RoleName, &rolePerms, &limits, &u.Scope, &pin, &u.Phone, &u.Email,
		&whJSON, &u.DefaultWarehouseID, &u.LastLoginAt, &u.TokenVersion); err != nil {
		return nil, err
	}
	u.Active = active == 1
	u.Perms = computePerms(u.RoleID, rolePerms, permsJSON)
	u.Role = legacyRoleFor(u.RoleID, u.Perms)
	u.HasPin = pin != ""
	if u.RoleID == RoleAdminID {
		u.Limits = parseLimits("{}")
		u.Scope = "all"
	} else {
		u.Limits = parseLimits(limits)
	}
	u.WarehouseIDs = []string{}
	json.Unmarshal([]byte(whJSON), &u.WarehouseIDs)
	if u.WarehouseIDs == nil {
		u.WarehouseIDs = []string{}
	}
	return &u, nil
}

func loadAuthUserQ(q queryRower, uid string) (*AuthUser, error) {
	return scanAuthUser(q.QueryRow(authUserSelect+` WHERE u.id = ?`, uid))
}

func (s *Server) loadAuthUser(uid string) (*AuthUser, error) {
	return loadAuthUserQ(s.db, uid)
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
	s.respondLogin(w, id)
}

// respondLogin stamps last_login_at and answers {token, user} (password and
// PIN login share it).
func (s *Server) respondLogin(w http.ResponseWriter, id string) {
	now := domain.NowISO()
	s.db.Exec(`UPDATE users SET last_login_at = ? WHERE id = ?`, now, id)
	u, err := s.loadAuthUser(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token": s.makeTokenV(id, u.TokenVersion),
		"user":  u,
	})
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, authFrom(r))
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		uid, ver, ok := s.parseToken(tok)
		if !ok {
			writeErr(w, http.StatusUnauthorized, "authentification requise")
			return
		}
		u, err := s.loadAuthUser(uid)
		if err != nil || !u.Active {
			writeErr(w, http.StatusUnauthorized, "session invalide")
			return
		}
		if ver != u.TokenVersion {
			writeErr(w, http.StatusUnauthorized, "session terminée : reconnectez-vous")
			return
		}
		ctx := context.WithValue(r.Context(), userKey, u)
		// Code du gérant : the token is consumed by THIS request (single use).
		if at := strings.TrimSpace(r.Header.Get("X-Approval")); at != "" {
			if a := approvals.take(at); a != nil {
				if approver, err := s.loadAuthUser(a.approverID); err == nil && approver.Active {
					ctx = context.WithValue(ctx, approvalKey, &approvalCtx{grant: a, approver: approver})
				}
			}
		}
		next.ServeHTTP(w, r.WithContext(ctx))
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

// isAdmin is true only for the Administrateur role (users.role is kept 'admin'
// for that role only).
func (s *Server) isAdmin(r *http.Request) bool {
	u := authFrom(r)
	return u != nil && u.Role == "admin"
}

func forbid(w http.ResponseWriter) {
	writeErr(w, http.StatusForbidden, "accès refusé")
}

// hasRight reads a fine-grained key. Hand-built legacy perm maps (without the
// dotted keys) fall back to the module key, and to admin for special rights.
func hasRight(u *AuthUser, key string) bool {
	if u == nil {
		return false
	}
	if v, ok := u.Perms[key]; ok {
		return v
	}
	if i := strings.IndexByte(key, '.'); i > 0 {
		return u.Perms[key[:i]]
	}
	return u.Role == "admin"
}

// docModule maps a document type to its module of the permission grid.
func docModule(docType string) string {
	switch {
	case strings.HasPrefix(docType, "PURCHASE"):
		return "purchases"
	case docType == domain.StockAdjustment || docType == domain.StockTransfer ||
		docType == domain.InventoryCount:
		return "stock"
	case docType == domain.PaymentOut || docType == domain.PaymentIn:
		return "partners"
	default:
		return "sales"
	}
}

// docActionOK: may the user <action> a document of this type? The cash desk
// (pos) may create and validate tickets and customer payments by itself.
func docActionOK(u *AuthUser, docType, action string) bool {
	if u == nil {
		return false
	}
	if (docType == domain.SaleTicket || docType == domain.PaymentIn) && u.Perms["pos"] &&
		(action == "create" || action == "edit" || action == "validate" || action == "view") {
		return true
	}
	m := docModule(docType)
	if m == "partners" && (action == "validate" || action == "cancel") {
		// Payments have no validate/cancel column: creating them is the act.
		action = "create"
	}
	return hasRight(u, m+"."+action)
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
