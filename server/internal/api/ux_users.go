package api

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"golang.org/x/crypto/bcrypt"

	"elixir/server/internal/domain"
)

// routesUsersUX registers the users / roles / approval routes of the settings work.
func (s *Server) routesUsersUX(r chi.Router) {
	r.Post("/auth/approve", s.approveAction)
	r.Post("/auth/pin-login", s.pinLogin)
	r.Get("/auth/pin-users", s.pinUsers)

	r.Put("/users/{id}/pin", s.setUserPin)
	r.Post("/users/{id}/logout-all", s.logoutAll)

	r.Get("/roles", s.listRoles)
	r.Post("/roles", s.createRole)
	r.Put("/roles/{id}", s.updateRole)
	r.Delete("/roles/{id}", s.deleteRole)
	r.Post("/roles/{id}/copy", s.copyRole)
}

func init() {
	// « negative_stock » right: the posting engine asks through this hook,
	// inside its own transaction (the DB has a single connection).
	domain.UserMayOversell = func(tx *sql.Tx, userID string) bool {
		if userID == "" {
			return false
		}
		u, err := loadAuthUserQ(tx, userID)
		// The shop switch « vente en stock négatif » applies to everyone; only a
		// role that EXPLICITLY ticks the right escapes it (not the implicit
		// « everything » of the Administrateur system role).
		return err == nil && u.Active && u.Role != "admin" && hasRight(u, "negative_stock")
	}
}

// rightLabels: plain French for each right (messages, audit, approval dialog).
var rightLabels = map[string]string{
	"view_cost":      "voir les prix d'achat et les marges",
	"discount":       "accorder une remise",
	"price_edit":     "changer le prix à la caisse",
	"credit_sale":    "vendre à crédit",
	"credit_limit":   "dépasser le plafond de crédit du client",
	"approval_above": "valider une vente d'un montant élevé",
	"negative_stock": "vendre au-delà du stock",
	"refund":         "faire un avoir ou un retour",
	"void_document":  "annuler un document validé",
	"change_date":    "modifier la date d'un document",
	"open_drawer":    "ouvrir le tiroir sans vente",
	"close_till":     "clôturer la caisse",
	"view_today":     "voir le chiffre du jour",
	"stock_adjust":   "ajuster le stock ou faire un inventaire",
	"import_data":    "importer des données",
	"export_data":    "exporter des données",
}

var actionLabels = map[string]string{
	"view": "voir", "create": "créer", "edit": "modifier", "cancel": "annuler",
	"validate": "valider", "export": "exporter", "print": "imprimer",
}

var moduleLabels = map[string]string{
	"dashboard": "le tableau de bord", "pos": "la caisse", "sales": "les ventes",
	"purchases": "les achats", "stock": "le stock", "products": "les produits",
	"partners": "les clients et fournisseurs", "assistant": "l'assistant",
	"reports": "les rapports", "webstore": "la boutique en ligne", "settings": "les paramètres",
}

func rightLabel(key string) string {
	if l, ok := rightLabels[key]; ok {
		return l
	}
	if i := strings.IndexByte(key, '.'); i > 0 {
		m, a := key[:i], key[i+1:]
		if al, ok := actionLabels[a]; ok {
			return al + " dans " + moduleLabels[m]
		}
	}
	return key
}

// ---- Approval (code du gérant) ----------------------------------------------

const approvalTTL = 2 * time.Minute

type approvalGrant struct {
	approverID   string
	approverName string
	action       string
	amount       int64
	expires      time.Time
}

type approvalStore struct {
	mu sync.Mutex
	m  map[string]*approvalGrant
}

var approvals = &approvalStore{m: map[string]*approvalGrant{}}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (st *approvalStore) put(g *approvalGrant) string {
	st.mu.Lock()
	defer st.mu.Unlock()
	now := time.Now()
	for k, v := range st.m {
		if now.After(v.expires) {
			delete(st.m, k)
		}
	}
	tok := randHex(16)
	st.m[tok] = g
	return tok
}

// take returns and REMOVES the grant (single use); nil when unknown or expired.
func (st *approvalStore) take(tok string) *approvalGrant {
	st.mu.Lock()
	defer st.mu.Unlock()
	g := st.m[tok]
	delete(st.m, tok)
	if g == nil || time.Now().After(g.expires) {
		return nil
	}
	return g
}

type approvalCtx struct {
	grant    *approvalGrant
	approver *AuthUser
	mu       sync.Mutex
	used     map[string]bool
}

func approvalFrom(r *http.Request) *approvalCtx {
	a, _ := r.Context().Value(approvalKey).(*approvalCtx)
	return a
}

// allowed: may this user do <action> (for <amount>) on his own? Limits are
// 0 = no limit. Used both for the caller and for the approving manager.
func allowed(u *AuthUser, action string, amount int64) bool {
	if u == nil {
		return false
	}
	if u.Role == "admin" || u.RoleID == RoleAdminID {
		return true
	}
	lim := func(k string) int64 {
		if u.Limits == nil {
			return 0
		}
		return u.Limits[k]
	}
	switch action {
	case "discount":
		return hasRight(u, "discount") && (lim("max_discount_pct") == 0 || amount <= lim("max_discount_pct"))
	case "credit_sale":
		return hasRight(u, "credit_sale") && (lim("max_credit") == 0 || amount <= lim("max_credit"))
	case "credit_limit":
		// Whoever may change a customer's ceiling may exceed it.
		return hasRight(u, "credit_sale") && hasRight(u, "partners.edit")
	case "approval_above":
		return lim("approval_above") == 0 || amount <= lim("approval_above")
	}
	return hasRight(u, action)
}

// rightOrApproval: the caller has the right, or the request carries a manager
// code whose approver has it (logged « approuvé par » once per action).
func (s *Server) rightOrApproval(r *http.Request, action string, amount int64) bool {
	if allowed(authFrom(r), action, amount) {
		return true
	}
	ac := approvalFrom(r)
	if ac == nil || !allowed(ac.approver, action, amount) {
		return false
	}
	ac.mu.Lock()
	first := ac.used == nil || !ac.used[action]
	if ac.used == nil {
		ac.used = map[string]bool{}
	}
	ac.used[action] = true
	ac.mu.Unlock()
	if first {
		name := ac.approver.FullName
		if name == "" {
			name = ac.approver.Username
		}
		detail := rightLabel(action)
		if action == "discount" && amount > 0 {
			detail += " (" + pctText(amount) + " %)"
		} else if amount > 0 {
			detail += " (" + centimes(amount) + " DA)"
		}
		s.audit(r, "approval", "user", ac.approver.ID, detail+" — approuvé par "+name)
	}
	return true
}

// writeNeedsApproval answers the 403 the client turns into « Code du gérant ».
func writeNeedsApproval(w http.ResponseWriter, action string, amount int64, msg string) {
	if msg == "" {
		msg = "vous n'avez pas le droit de " + rightLabel(action)
	}
	writeJSON(w, http.StatusForbidden, map[string]any{
		"error": msg, "needs_approval": true, "action": action, "amount": amount,
	})
}

// requireRight = rightOrApproval, writing the needs_approval 403 when refused.
func (s *Server) requireRight(w http.ResponseWriter, r *http.Request, action string, amount int64, msg string) bool {
	if s.rightOrApproval(r, action, amount) {
		return true
	}
	writeNeedsApproval(w, action, amount, msg)
	return false
}

// requireDocAction: <module>.<action> on a document type (manager code accepted).
func (s *Server) requireDocAction(w http.ResponseWriter, r *http.Request, docType, action string) bool {
	if docActionOK(authFrom(r), docType, action) {
		return true
	}
	m := docModule(docType)
	key := m + "." + action
	if m == "partners" && (action == "validate" || action == "cancel") {
		key = "partners.create"
	}
	return s.requireRight(w, r, key, 0, "vous n'avez pas le droit de "+rightLabel(key))
}

func today() string { return time.Now().Format("2006-01-02") }

func isSaleFamily(docType string) bool {
	return strings.HasPrefix(docType, "SALE") || docType == domain.Quote || docType == domain.DeliveryNote
}

// SaleCheck describes a document about to be created / changed / validated.
type SaleCheck struct {
	DocType   string
	DocDate   string // "" = today
	OldDate   string // stored date of the draft being edited ("" on create)
	PartnerID *string
	Lines     []DocumentLine
	Credit    int64 // part sold on credit (centimes); only checked when Posting
	Total     int64 // TTC (centimes); 0 = computed from Lines
	Posting   bool  // the call also validates the document
}

// checkSaleRights runs the shared permission checks of a document (POS
// checkout included): avoir → refund, date ≠ today → change_date, remises →
// discount (+ max_discount_pct), stock adjustments → stock_adjust and, when
// posting, crédit → credit_sale (+ max_credit, + the customer's own ceiling)
// and the approval_above amount. It writes the 403 (needs_approval when a
// manager code can unlock it) and returns false when refused.
func (s *Server) checkSaleRights(w http.ResponseWriter, r *http.Request, c SaleCheck) bool {
	if c.DocType == domain.SaleCreditNote && !s.requireRight(w, r, "refund", 0,
		"vous n'avez pas le droit de faire un avoir") {
		return false
	}
	if (c.DocType == domain.StockAdjustment || c.DocType == domain.InventoryCount) &&
		!s.requireRight(w, r, "stock_adjust", 0, "vous n'avez pas le droit d'ajuster le stock") {
		return false
	}
	if c.DocDate != "" && c.DocDate != today() && c.DocDate != c.OldDate &&
		!s.requireRight(w, r, "change_date", 0, "vous n'avez pas le droit de modifier la date du document") {
		return false
	}
	if isSaleFamily(c.DocType) {
		// The customer's group discount is a shop rule, not a cashier's
		// decision: a line discounted up to that rate needs no right.
		var groupPct int64
		if c.PartnerID != nil && *c.PartnerID != "" {
			s.db.QueryRow(`SELECT COALESCE(g.discount_pct, 0) FROM partners p
				LEFT JOIN customer_groups g ON g.id = p.group_id WHERE p.id = ?`, *c.PartnerID).Scan(&groupPct)
		}
		var maxPct int64
		for _, l := range c.Lines {
			if l.DiscountPct > maxPct && l.DiscountPct > groupPct {
				maxPct = l.DiscountPct
			}
		}
		if maxPct > 0 && !s.requireRight(w, r, "discount", maxPct, discountMsg(authFrom(r), maxPct)) {
			return false
		}
	}
	if !c.Posting || !isSaleFamily(c.DocType) {
		return true
	}
	total := c.Total
	if total == 0 {
		for _, l := range c.Lines {
			_, _, t := domain.LineTotals(l.UnitPrice, l.QtyMilli, l.DiscountPct, l.VatRate)
			total += t
		}
	}
	if c.Credit > 0 {
		if !s.requireRight(w, r, "credit_sale", c.Credit, creditMsg(authFrom(r), c.Credit)) {
			return false
		}
		if c.PartnerID != nil && *c.PartnerID != "" {
			var limit sql.NullInt64
			var balance int64
			s.db.QueryRow(`SELECT credit_limit FROM partners WHERE id = ?`, *c.PartnerID).Scan(&limit)
			s.db.QueryRow(`SELECT COALESCE(SUM(amount),0) FROM partner_ledger WHERE partner_id = ?`,
				*c.PartnerID).Scan(&balance)
			if limit.Valid && limit.Int64 > 0 && balance+c.Credit > limit.Int64 &&
				!s.requireRight(w, r, "credit_limit", balance+c.Credit, fmt.Sprintf(
					"le plafond de crédit du client (%s DA) serait dépassé : %s DA dus après cette vente",
					centimes(limit.Int64), centimes(balance+c.Credit))) {
				return false
			}
		}
	}
	if c.DocType != domain.Quote && c.DocType != domain.SaleCreditNote && total > 0 &&
		!s.requireRight(w, r, "approval_above", total, fmt.Sprintf(
			"au-delà de %s DA, le code du gérant est demandé", centimes(limitOf(authFrom(r), "approval_above")))) {
		return false
	}
	return true
}

func limitOf(u *AuthUser, k string) int64 {
	if u == nil || u.Limits == nil {
		return 0
	}
	return u.Limits[k]
}

func discountMsg(u *AuthUser, pct int64) string {
	if hasRight(u, "discount") {
		return fmt.Sprintf("remise de %s %% au-delà de votre maximum (%s %%)",
			pctText(pct), pctText(limitOf(u, "max_discount_pct")))
	}
	return "vous n'êtes pas autorisé à accorder des remises"
}

func creditMsg(u *AuthUser, amount int64) string {
	if hasRight(u, "credit_sale") {
		return fmt.Sprintf("crédit de %s DA au-delà de votre maximum (%s DA)",
			centimes(amount), centimes(limitOf(u, "max_credit")))
	}
	return "vous n'avez pas le droit de vendre à crédit"
}

func pctText(v int64) string {
	s := fmt.Sprintf("%.2f", float64(v)/100)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	return strings.Replace(s, ".", ",", 1)
}

// ---- Data scope ---------------------------------------------------------------

// allowedWarehouses: nil = every depot; otherwise the user's depots.
func allowedWarehouses(u *AuthUser) []string {
	if u == nil || u.Scope != "warehouse" || u.Role == "admin" {
		return nil
	}
	out := append([]string{}, u.WarehouseIDs...)
	if u.DefaultWarehouseID != nil && *u.DefaultWarehouseID != "" {
		found := false
		for _, w := range out {
			found = found || w == *u.DefaultWarehouseID
		}
		if !found {
			out = append(out, *u.DefaultWarehouseID)
		}
	}
	return out
}

// docScopeWhere returns the extra WHERE of a documents query for the caller's
// data scope ("own" = created or validated by him, "warehouse" = his depots).
func docScopeWhere(u *AuthUser, alias string) (string, []any) {
	if u == nil || u.Role == "admin" {
		return "", nil
	}
	p := ""
	if alias != "" {
		p = alias + "."
	}
	switch u.Scope {
	case "own":
		return " AND (" + p + "created_by = ? OR " + p + "posted_by = ?)", []any{u.ID, u.ID}
	case "warehouse":
		ids := allowedWarehouses(u)
		if len(ids) == 0 {
			return " AND 0", nil
		}
		ph := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
		args := []any{}
		for _, id := range ids {
			args = append(args, id)
		}
		args = append(args, args...)
		return " AND (" + p + "warehouse_id IN (" + ph + ") OR " + p + "dest_warehouse_id IN (" + ph + "))", args
	}
	return "", nil
}

// applyWarehouseScope rewrites ?warehouse_id= so a "warehouse"-scoped user only
// reads his own depots (stock levels): an unknown or missing depot becomes his
// default one.
func applyWarehouseScope(r *http.Request) {
	ids := allowedWarehouses(authFrom(r))
	if ids == nil {
		return
	}
	q := r.URL.Query()
	want := q.Get("warehouse_id")
	for _, id := range ids {
		if id == want {
			return
		}
	}
	pick := "-"
	if u := authFrom(r); u.DefaultWarehouseID != nil && *u.DefaultWarehouseID != "" {
		pick = *u.DefaultWarehouseID
	} else if len(ids) > 0 {
		pick = ids[0]
	}
	q.Set("warehouse_id", pick)
	r.URL.RawQuery = q.Encode()
}

// ---- PIN (code caisse) --------------------------------------------------------

var pinRe = regexp.MustCompile(`^[0-9]{4,6}$`)

const (
	pinMaxTries = 5
	pinLock     = time.Minute
	pinCost     = 8
)

type tries struct {
	n     int
	until time.Time
}

var pinGuard = struct {
	sync.Mutex
	m map[string]*tries
}{m: map[string]*tries{}}

// pinLocked returns the remaining lock time for a key.
func pinLocked(key string) time.Duration {
	pinGuard.Lock()
	defer pinGuard.Unlock()
	t := pinGuard.m[key]
	if t == nil || time.Now().After(t.until) {
		return 0
	}
	return time.Until(t.until)
}

func pinFailed(key string) {
	pinGuard.Lock()
	defer pinGuard.Unlock()
	t := pinGuard.m[key]
	if t == nil || (!t.until.IsZero() && time.Now().After(t.until)) {
		t = &tries{}
		pinGuard.m[key] = t
	}
	t.n++
	if t.n >= pinMaxTries {
		t.until = time.Now().Add(pinLock)
		t.n = 0
	}
}

func pinOK(key string) {
	pinGuard.Lock()
	delete(pinGuard.m, key)
	pinGuard.Unlock()
}

func writeLocked(w http.ResponseWriter, d time.Duration) {
	writeErr(w, http.StatusTooManyRequests, fmt.Sprintf(
		"trop de codes incorrects : réessayez dans %d secondes", int(d.Seconds())+1))
}

type pinRow struct {
	id, name, hash string
}

func (s *Server) pinRows() ([]pinRow, error) {
	rows, err := s.db.Query(`SELECT id, CASE WHEN full_name <> '' THEN full_name ELSE username END, pin_hash
		FROM users WHERE active = 1 AND pin_hash IS NOT NULL AND pin_hash <> '' ORDER BY full_name, username`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []pinRow
	for rows.Next() {
		var p pinRow
		if err := rows.Scan(&p.id, &p.name, &p.hash); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Server) setUserPin(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	me := authFrom(r)
	if !s.isAdmin(r) && (me == nil || me.ID != id) {
		forbid(w)
		return
	}
	var in struct {
		Pin *string `json:"pin"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var hash any
	if in.Pin != nil && *in.Pin != "" {
		pin := *in.Pin
		if !pinRe.MatchString(pin) {
			writeFieldErr(w, http.StatusBadRequest, "pin", "le code caisse doit avoir 4 à 6 chiffres")
			return
		}
		others, err := s.pinRows()
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		for _, o := range others {
			if o.id != id && bcrypt.CompareHashAndPassword([]byte(o.hash), []byte(pin)) == nil {
				writeFieldErr(w, http.StatusConflict, "pin", "ce code est déjà utilisé : choisissez-en un autre")
				return
			}
		}
		h, err := bcrypt.GenerateFromPassword([]byte(pin), pinCost)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		hash = string(h)
	}
	res, err := s.db.Exec(`UPDATE users SET pin_hash = ?, updated_at = ? WHERE id = ?`, hash, domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "utilisateur introuvable")
		return
	}
	if hash == nil {
		s.audit(r, "user.pin", "user", id, "code caisse retiré")
	} else {
		s.audit(r, "user.pin", "user", id, "code caisse défini")
	}
	s.respondUser(w, id, http.StatusOK)
}

func (s *Server) pinUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`SELECT u.id, u.username, u.full_name, COALESCE(ro.name, '')
		FROM users u LEFT JOIN roles ro ON ro.id = u.role_id
		WHERE u.active = 1 AND u.pin_hash IS NOT NULL AND u.pin_hash <> ''
		ORDER BY CASE WHEN u.full_name <> '' THEN u.full_name ELSE u.username END`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	type item struct {
		ID       string `json:"id"`
		Username string `json:"username"`
		FullName string `json:"full_name"`
		RoleName string `json:"role_name"`
	}
	items := []item{}
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Username, &it.FullName, &it.RoleName); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, it)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) pinLogin(w http.ResponseWriter, r *http.Request) {
	var in struct {
		UserID string `json:"user_id"`
		Pin    string `json:"pin"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	key := "login:" + in.UserID
	if d := pinLocked(key); d > 0 {
		writeLocked(w, d)
		return
	}
	var hash sql.NullString
	var active int
	err := s.db.QueryRow(`SELECT pin_hash, active FROM users WHERE id = ?`, in.UserID).Scan(&hash, &active)
	if err != nil || active == 0 || !hash.Valid || hash.String == "" {
		writeErr(w, http.StatusBadRequest, "cet utilisateur n'a pas de code caisse")
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash.String), []byte(in.Pin)) != nil {
		pinFailed(key)
		if d := pinLocked(key); d > 0 {
			writeLocked(w, d)
			return
		}
		writeFieldErr(w, http.StatusBadRequest, "pin", "code incorrect")
		return
	}
	pinOK(key)
	s.audit(r, "auth.pin_login", "user", in.UserID, "changement de caissier")
	s.respondLogin(w, in.UserID)
}

// approveAction: POST /auth/approve {pin, action, amount?} — a manager types
// his code; the token unlocks ONE request (header X-Approval), 2 minutes.
func (s *Server) approveAction(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Pin    string `json:"pin"`
		Action string `json:"action"`
		Amount int64  `json:"amount"`
		UserID string `json:"user_id"` // optional: the approver, when picked
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Action) == "" {
		writeErr(w, http.StatusBadRequest, "action obligatoire")
		return
	}
	caller := authFrom(r)
	key := "approve:" + caller.ID
	if d := pinLocked(key); d > 0 {
		writeLocked(w, d)
		return
	}
	rows, err := s.pinRows()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var match *pinRow
	for i := range rows {
		if in.UserID != "" && rows[i].id != in.UserID {
			continue
		}
		if bcrypt.CompareHashAndPassword([]byte(rows[i].hash), []byte(in.Pin)) == nil {
			match = &rows[i]
			break
		}
	}
	if match == nil {
		pinFailed(key)
		if d := pinLocked(key); d > 0 {
			writeLocked(w, d)
			return
		}
		writeFieldErr(w, http.StatusBadRequest, "pin", "code incorrect")
		return
	}
	pinOK(key)
	approver, err := s.loadAuthUser(match.id)
	if err != nil || !approver.Active {
		writeErr(w, http.StatusForbidden, "utilisateur inactif")
		return
	}
	if !allowed(approver, in.Action, in.Amount) {
		writeErr(w, http.StatusForbidden, fmt.Sprintf("%s n'a pas le droit de %s", match.name, rightLabel(in.Action)))
		return
	}
	tok := approvals.put(&approvalGrant{approverID: approver.ID, approverName: match.name,
		action: in.Action, amount: in.Amount, expires: time.Now().Add(approvalTTL)})
	writeJSON(w, http.StatusOK, map[string]any{
		"approval_token": tok,
		"approver_id":    approver.ID,
		"approver_name":  match.name,
		"expires_in":     int(approvalTTL.Seconds()),
	})
}

func (s *Server) logoutAll(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	me := authFrom(r)
	if !s.isAdmin(r) && (me == nil || me.ID != id) {
		forbid(w)
		return
	}
	res, err := s.db.Exec(`UPDATE users SET token_version = token_version + 1, updated_at = ? WHERE id = ?`,
		domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "utilisateur introuvable")
		return
	}
	s.audit(r, "user.logout_all", "user", id, "déconnecté de tous les postes")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func writeFieldErr(w http.ResponseWriter, status int, field, msg string) {
	writeJSON(w, status, map[string]string{"error": msg, "field": field})
}

// ---- Roles ----------------------------------------------------------------------

type RoleOut struct {
	ID          string           `json:"id"`
	Name        string           `json:"name"`
	Description string           `json:"description"`
	Perms       map[string]bool  `json:"perms"`
	Limits      map[string]int64 `json:"limits"`
	Scope       string           `json:"scope"`
	IsSystem    bool             `json:"is_system"`
	UserCount   int              `json:"user_count"`
	CreatedAt   string           `json:"created_at"`
	UpdatedAt   string           `json:"updated_at"`
}

const roleCols = `r.id, r.name, r.description, r.perms_json, r.limits_json, r.scope, r.is_system,
	r.created_at, r.updated_at,
	(SELECT COUNT(*) FROM users u WHERE COALESCE(u.role_id, CASE u.role WHEN 'admin' THEN 'role-admin'
		WHEN 'manager' THEN 'role-manager' ELSE 'role-cashier' END) = r.id)`

func scanRole(row interface{ Scan(...any) error }) (RoleOut, error) {
	var ro RoleOut
	var perms, limits string
	var sys int
	err := row.Scan(&ro.ID, &ro.Name, &ro.Description, &perms, &limits, &ro.Scope, &sys,
		&ro.CreatedAt, &ro.UpdatedAt, &ro.UserCount)
	if err != nil {
		return ro, err
	}
	ro.IsSystem = sys == 1
	all := computePerms(ro.ID, perms, "{}")
	ro.Perms = map[string]bool{}
	for k, v := range all {
		if !isModule(k) {
			ro.Perms[k] = v
		}
	}
	ro.Limits = parseLimits(limits)
	return ro, nil
}

func (s *Server) loadRole(id string) (RoleOut, error) {
	return scanRole(s.db.QueryRow(`SELECT `+roleCols+` FROM roles r WHERE r.id = ?`, id))
}

func (s *Server) listRoles(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	rows, err := s.db.Query(`SELECT ` + roleCols + ` FROM roles r
		ORDER BY r.is_system DESC, CASE r.id WHEN 'role-manager' THEN 0 WHEN 'role-cashier' THEN 1 ELSE 2 END, r.name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []RoleOut{}
	for rows.Next() {
		ro, err := scanRole(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, ro)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type roleInput struct {
	Name        string           `json:"name"`
	Description string           `json:"description"`
	Perms       map[string]bool  `json:"perms"`
	Limits      map[string]int64 `json:"limits"`
	Scope       string           `json:"scope"`
}

// normalize keeps only known keys (true ones) and valid limits/scope.
func (in *roleInput) normalize() (perms, limits string, field, msg string) {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return "", "", "name", "le nom du rôle est obligatoire"
	}
	if in.Scope == "" {
		in.Scope = "all"
	}
	if in.Scope != "all" && in.Scope != "own" && in.Scope != "warehouse" {
		return "", "", "scope", "périmètre invalide"
	}
	p := map[string]bool{}
	keys := make([]string, 0, len(in.Perms))
	for k := range in.Perms {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if in.Perms[k] && isKnownPerm(k) && !isModule(k) {
			p[k] = true
		}
	}
	// An action without « Voir » makes no sense: grant the view.
	for _, m := range Modules {
		for _, a := range ModuleActions[m] {
			if a != "view" && p[m+"."+a] {
				p[m+".view"] = true
			}
		}
	}
	l := map[string]int64{}
	for _, k := range LimitKeys {
		v := in.Limits[k]
		if v < 0 {
			return "", "", k, "une limite ne peut pas être négative"
		}
		if k == "max_discount_pct" && v > 10000 {
			return "", "", k, "la remise maximale ne peut pas dépasser 100 %"
		}
		l[k] = v
	}
	pb, _ := json.Marshal(p)
	lb, _ := json.Marshal(l)
	return string(pb), string(lb), "", ""
}

func (s *Server) roleNameTaken(name, exceptID string) bool {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM roles WHERE LOWER(name) = LOWER(?) AND id <> ?`, name, exceptID).Scan(&n)
	return n > 0
}

func (s *Server) createRole(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	var in roleInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	perms, limits, field, msg := in.normalize()
	if msg != "" {
		writeFieldErr(w, http.StatusBadRequest, field, msg)
		return
	}
	if s.roleNameTaken(in.Name, "") {
		writeFieldErr(w, http.StatusConflict, "name", "un rôle porte déjà ce nom")
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO roles (id, name, description, perms_json, limits_json, scope, is_system, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)`, id, in.Name, strings.TrimSpace(in.Description), perms, limits, in.Scope, now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	s.audit(r, "role.create", "role", id, in.Name)
	s.respondRole(w, id, http.StatusCreated)
}

func (s *Server) updateRole(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	cur, err := s.loadRole(id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "rôle introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if cur.IsSystem {
		writeErr(w, http.StatusConflict, "le rôle Administrateur ne peut pas être modifié")
		return
	}
	var in roleInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	perms, limits, field, msg := in.normalize()
	if msg != "" {
		writeFieldErr(w, http.StatusBadRequest, field, msg)
		return
	}
	if s.roleNameTaken(in.Name, id) {
		writeFieldErr(w, http.StatusConflict, "name", "un rôle porte déjà ce nom")
		return
	}
	now := domain.NowISO()
	if _, err := s.db.Exec(`UPDATE roles SET name=?, description=?, perms_json=?, limits_json=?, scope=?, updated_at=?
		WHERE id=?`, in.Name, strings.TrimSpace(in.Description), perms, limits, in.Scope, now, id); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	// Keep users.role (read by older code) in line with the new rights.
	s.db.Exec(`UPDATE users SET role=? WHERE role_id=?`, legacyRoleFor(id, computePerms(id, perms, "{}")), id)
	s.audit(r, "role.update", "role", id, in.Name)
	s.respondRole(w, id, http.StatusOK)
}

func (s *Server) deleteRole(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	cur, err := s.loadRole(id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "rôle introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if cur.IsSystem {
		writeErr(w, http.StatusConflict, "le rôle Administrateur ne peut pas être supprimé")
		return
	}
	if cur.UserCount > 0 {
		plural := ""
		if cur.UserCount > 1 {
			plural = "s"
		}
		writeJSON(w, http.StatusConflict, map[string]any{
			"error": fmt.Sprintf("ce rôle est utilisé par %d utilisateur%s : donnez-leur d'abord un autre rôle",
				cur.UserCount, plural),
			"user_count": cur.UserCount,
		})
		return
	}
	if _, err := s.db.Exec(`DELETE FROM roles WHERE id = ?`, id); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	s.audit(r, "role.delete", "role", id, cur.Name)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) copyRole(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	src, err := s.loadRole(chi.URLParam(r, "id"))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "rôle introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	name := src.Name + " (copie)"
	for i := 2; s.roleNameTaken(name, ""); i++ {
		name = fmt.Sprintf("%s (copie %d)", src.Name, i)
	}
	pb, _ := json.Marshal(src.Perms)
	lb, _ := json.Marshal(src.Limits)
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO roles (id, name, description, perms_json, limits_json, scope, is_system, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)`, id, name, src.Description, string(pb), string(lb), src.Scope, now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	s.audit(r, "role.create", "role", id, name+" (copie de "+src.Name+")")
	s.respondRole(w, id, http.StatusCreated)
}

func (s *Server) respondRole(w http.ResponseWriter, id string, status int) {
	ro, err := s.loadRole(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, ro)
}
