package api

import (
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// routesDistribution registers the distribution routes (commandes clients,
// tarifs, livraisons, relation client, messages). Contract:
// docs/API_DISTRIBUTION.md.
func (s *Server) routesDistribution(r chi.Router) {
	s.routesOrders(r)
	s.routesPricing(r)
	s.routesDeliveries(r)
	s.routesCRM(r)
	s.routesMessages(r)
}

// writeDomainErr maps the domain errors to HTTP answers.
func writeDomainErr(w http.ResponseWriter, err error) {
	var nf *domain.NotFoundError
	var pe *domain.PostError
	var wp *domain.WrongProductError
	var ob *domain.OrderBlock
	switch {
	case errors.As(err, &ob):
		writeJSON(w, http.StatusConflict, map[string]any{
			"error": ob.Msg, "warnings": ob.Warnings, "needs_override": true,
		})
	case errors.As(err, &nf):
		writeErr(w, http.StatusNotFound, nf.Msg)
	case errors.As(err, &wp):
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": wp.Msg, "wrong_product": true})
	case errors.As(err, &pe):
		writeErr(w, http.StatusConflict, pe.Msg)
	case errors.Is(err, domain.ErrNotFound):
		writeErr(w, http.StatusNotFound, err.Error())
	case errors.Is(err, domain.ErrNotDraft), errors.Is(err, domain.ErrNoLines),
		errors.Is(err, domain.ErrNoWarehouse), errors.Is(err, domain.ErrNoPartner),
		errors.Is(err, domain.ErrBadAmount), errors.Is(err, domain.ErrNotPosted):
		writeErr(w, http.StatusConflict, err.Error())
	default:
		if strings.Contains(err.Error(), "UNIQUE constraint failed") {
			writeErr(w, http.StatusConflict, "cette valeur existe déjà")
			return
		}
		if strings.Contains(err.Error(), "FOREIGN KEY constraint failed") {
			writeErr(w, http.StatusConflict, "référence introuvable ou encore utilisée")
			return
		}
		if strings.Contains(err.Error(), "CHECK constraint failed") {
			writeErr(w, http.StatusBadRequest, "valeur invalide")
			return
		}
		writeErr(w, http.StatusInternalServerError, err.Error())
	}
}

// inTx runs fn in one write transaction and writes the error answer on
// failure. fn must only use tx (the pool has a single connection).
func (s *Server) inTx(w http.ResponseWriter, fn func(tx *sql.Tx) error) bool {
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return false
	}
	defer tx.Rollback()
	if err := fn(tx); err != nil {
		writeDomainErr(w, err)
		return false
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return false
	}
	return true
}

func uidOf(r *http.Request) string {
	if u := authFrom(r); u != nil {
		return u.ID
	}
	return ""
}

// need answers 403 unless the caller holds one of the keys.
func (s *Server) need(w http.ResponseWriter, r *http.Request, keys ...string) bool {
	u := authFrom(r)
	for _, k := range keys {
		if hasRight(u, k) {
			return true
		}
	}
	forbid(w)
	return false
}

// repRestricted: a role whose data scope is « own » sees only ITS customers
// (partners.rep_user_id) in the CRM, unless it holds crm.all_customers. The
// rule only applies to CRM users (crm.view), so a cashier picking a customer
// at the till is not affected.
func repRestricted(u *AuthUser) bool {
	return u != nil && u.Role != "admin" && u.Scope == "own" && hasRight(u, "crm.view") &&
		!hasRight(u, "crm.all_customers")
}

// partnerScopeWhere filters a partners query (alias) for a rep-restricted
// user: suppliers stay visible, customers only when he is their rep.
func partnerScopeWhere(u *AuthUser, alias string) (string, []any) {
	if !repRestricted(u) {
		return "", nil
	}
	return " AND (" + alias + ".kind = 'supplier' OR " + alias + ".rep_user_id = ?)", []any{u.ID}
}

// orderScopeWhere filters customer orders (alias o, partner alias p): own
// scope = orders he is the rep of, created, or of his customers; warehouse
// scope = his depots.
func orderScopeWhere(u *AuthUser) (string, []any) {
	if u == nil || u.Role == "admin" || hasRight(u, "crm.all_customers") && u.Scope == "own" {
		return "", nil
	}
	switch u.Scope {
	case "own":
		return " AND (o.rep_user_id = ? OR o.created_by = ? OR p.rep_user_id = ?)", []any{u.ID, u.ID, u.ID}
	case "warehouse":
		ids := allowedWarehouses(u)
		if len(ids) == 0 {
			return " AND 0", nil
		}
		args := []any{}
		for _, id := range ids {
			args = append(args, id)
		}
		return " AND o.warehouse_id IN (" + strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",") + ")", args
	}
	return "", nil
}

// canSeePartner applies the rep restriction to one partner.
func (s *Server) canSeePartner(r *http.Request, partnerID string) bool {
	u := authFrom(r)
	if !repRestricted(u) {
		return true
	}
	var kind string
	var rep sql.NullString
	if err := s.db.QueryRow(`SELECT kind, rep_user_id FROM partners WHERE id = ?`, partnerID).Scan(&kind, &rep); err != nil {
		return true // 404 is answered by the caller
	}
	return kind == "supplier" || rep.String == u.ID
}

// canSeeOrder applies orderScopeWhere to one order.
func (s *Server) canSeeOrder(r *http.Request, orderID string) bool {
	sw, sa := orderScopeWhere(authFrom(r))
	if sw == "" {
		return true
	}
	var n int
	args := append([]any{orderID}, sa...)
	s.db.QueryRow(`SELECT COUNT(*) FROM customer_orders o JOIN partners p ON p.id = o.partner_id
		WHERE o.id = ?`+sw, args...).Scan(&n)
	if n == 0 {
		// Unknown order: let the handler answer 404.
		var exists int
		s.db.QueryRow(`SELECT COUNT(*) FROM customer_orders WHERE id = ?`, orderID).Scan(&exists)
		return exists == 0
	}
	return true
}

// placeholders returns "?,?,?" for n values.
func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

// splitCSV splits a comma list, dropping blanks.
func splitCSV(v string) []string {
	out := []string{}
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
