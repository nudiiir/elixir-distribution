package api

import (
	"database/sql"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

type Partner struct {
	ID          string  `json:"id"`
	Kind        string  `json:"kind"`
	Name        string  `json:"name"`
	Phone       *string `json:"phone"`
	Email       *string `json:"email"`
	Address     *string `json:"address"`
	NIF         *string `json:"nif"`
	NIS         *string `json:"nis"`
	RC          *string `json:"rc"`
	AI          *string `json:"ai"`
	CreditLimit *int64  `json:"credit_limit"`
	Notes       *string `json:"notes"`
	PriceLevel  string  `json:"price_level"` // retail | wholesale
	MinShelfDays   int64 `json:"min_shelf_days"`   // durée de vie restante minimale (jours)
	OverReceiptPct int64 `json:"over_receipt_pct"` // tolérance de sur-réception, pct x100
	Active      bool    `json:"active"`
	Balance     int64   `json:"balance"` // positive = the partner owes us
	CreatedAt   string  `json:"created_at"`
	UpdatedAt   string  `json:"updated_at"`
}

const partnerCols = `p.id, p.kind, p.name, p.phone, p.email, p.address, p.nif, p.nis, p.rc, p.ai,
	p.credit_limit, p.notes, p.price_level, p.min_shelf_days, p.over_receipt_pct, p.active,
	COALESCE((SELECT SUM(amount) FROM partner_ledger pl WHERE pl.partner_id = p.id), 0),
	p.created_at, p.updated_at`

func scanPartner(row interface{ Scan(...any) error }) (Partner, error) {
	var p Partner
	var active int
	err := row.Scan(&p.ID, &p.Kind, &p.Name, &p.Phone, &p.Email, &p.Address,
		&p.NIF, &p.NIS, &p.RC, &p.AI, &p.CreditLimit, &p.Notes, &p.PriceLevel,
		&p.MinShelfDays, &p.OverReceiptPct, &active,
		&p.Balance, &p.CreatedAt, &p.UpdatedAt)
	p.Active = active == 1
	return p, err
}

func (s *Server) listPartners(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	kind := r.URL.Query().Get("kind")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))

	where := "WHERE active = 1"
	args := []any{}
	if q != "" {
		where += " AND (name LIKE ? OR phone LIKE ?)"
		like := "%" + q + "%"
		args = append(args, like, like)
	}
	if kind == "customer" || kind == "supplier" {
		where += " AND kind IN (?, 'both')"
		args = append(args, kind)
	}
	args = append(args, limit, offset)

	rows, err := s.db.Query(`SELECT `+partnerCols+` FROM partners p `+where+
		` ORDER BY name LIMIT ? OFFSET ?`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Partner{}
	for rows.Next() {
		p, err := scanPartner(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, p)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type partnerInput struct {
	Kind        string  `json:"kind"`
	Name        string  `json:"name"`
	Phone       *string `json:"phone"`
	Email       *string `json:"email"`
	Address     *string `json:"address"`
	NIF         *string `json:"nif"`
	NIS         *string `json:"nis"`
	RC          *string `json:"rc"`
	AI          *string `json:"ai"`
	CreditLimit *int64  `json:"credit_limit"`
	Notes       *string `json:"notes"`
	PriceLevel  string  `json:"price_level"`
	MinShelfDays   *int64 `json:"min_shelf_days"`
	OverReceiptPct *int64 `json:"over_receipt_pct"`
	Active      *bool   `json:"active"`
}

func orInt(v *int64, def int64) int64 {
	if v == nil {
		return def
	}
	return *v
}

func (in *partnerInput) validate() string {
	if strings.TrimSpace(in.Name) == "" {
		return "name is required"
	}
	if in.PriceLevel == "" {
		in.PriceLevel = "retail"
	}
	if in.PriceLevel != "retail" && in.PriceLevel != "wholesale" {
		return "price_level must be retail or wholesale"
	}
	switch in.Kind {
	case "customer", "supplier", "both":
		return ""
	default:
		return "kind must be customer, supplier or both"
	}
}

func (s *Server) createPartner(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") && !s.can(r, "pos") {
		forbid(w)
		return
	}
	var in partnerInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	_, err := s.db.Exec(`INSERT INTO partners (id, kind, name, phone, email, address,
			nif, nis, rc, ai, credit_limit, notes, price_level, min_shelf_days,
			over_receipt_pct, active, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, in.Kind, in.Name, in.Phone, in.Email, in.Address,
		in.NIF, in.NIS, in.RC, in.AI, in.CreditLimit, in.Notes, in.PriceLevel,
		orInt(in.MinShelfDays, 0), orInt(in.OverReceiptPct, 500),
		b2i(active), now, now)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	s.getPartnerByID(w, id)
}

func (s *Server) getPartner(w http.ResponseWriter, r *http.Request) {
	s.getPartnerByID(w, chi.URLParam(r, "id"))
}

func (s *Server) getPartnerByID(w http.ResponseWriter, id string) {
	p, err := scanPartner(s.db.QueryRow(`SELECT `+partnerCols+` FROM partners p WHERE p.id = ?`, id))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "partner not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (s *Server) updatePartner(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in partnerInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	active := true
	if in.Active != nil {
		active = *in.Active
	}
	res, err := s.db.Exec(`UPDATE partners SET kind=?, name=?, phone=?, email=?, address=?,
			nif=?, nis=?, rc=?, ai=?, credit_limit=?, notes=?, price_level=?,
			min_shelf_days=?, over_receipt_pct=?, active=?, updated_at=?
		WHERE id=?`,
		in.Kind, in.Name, in.Phone, in.Email, in.Address,
		in.NIF, in.NIS, in.RC, in.AI, in.CreditLimit, in.Notes, in.PriceLevel,
		orInt(in.MinShelfDays, 0), orInt(in.OverReceiptPct, 500), b2i(active),
		domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "partner not found")
		return
	}
	s.getPartnerByID(w, id)
}

// partnerBalance returns the partner's current balance from the ledger.
// Positive = the partner owes us.
func (s *Server) partnerBalance(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var balance sql.NullInt64
	if err := s.db.QueryRow(`SELECT SUM(amount) FROM partner_ledger WHERE partner_id = ?`, id).
		Scan(&balance); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"partner_id": id, "balance": balance.Int64})
}
