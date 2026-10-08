package api

import (
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// routesConfigUX registers the config routes of the settings work:
// numbering, customer groups, loyalty.
func (s *Server) routesConfigUX(r chi.Router) {
	// Cached settings (timbre on/off) used by the draft/POS previews.
	domain.RefreshSettingsCache(s.db)

	r.Get("/config/numbering", s.getNumbering)
	r.Put("/config/numbering/{type}", s.putNumbering)

	r.Get("/customer-groups", s.listCustomerGroups)
	r.Post("/customer-groups", s.createCustomerGroup)
	r.Put("/customer-groups/{id}", s.updateCustomerGroup)
	r.Delete("/customer-groups/{id}", s.deleteCustomerGroup)

	r.Get("/partners/{id}/loyalty", s.partnerLoyalty)
	r.Post("/partners/{id}/loyalty/redeem", s.redeemLoyalty)
	r.Post("/loyalty/redemptions/{id}/cancel", s.cancelLoyaltyRedemption)
}

// ---- Numérotation -----------------------------------------------------------

type numberingRow struct {
	DocType string `json:"doc_type"`
	Label   string `json:"label"`
	domain.NumberFormat
	Year       int    `json:"year"`
	NextNumber int64  `json:"next_number"` // what the next validated document gets
	LastIssued int64  `json:"last_issued"` // 0 = none yet in this series
	MinNext    int64  `json:"min_next"`    // lowest value next_number may take
	Preview    string `json:"preview"`
}

func (s *Server) numberingRow(docType string, year int) (numberingRow, error) {
	f := domain.LoadNumberFormat(s.db, docType)
	last, err := domain.LastIssued(s.db, docType, f, year)
	if err != nil {
		return numberingRow{}, err
	}
	next := domain.SequenceNext(s.db, docType, f, year)
	if next <= last {
		next = last + 1 // the posting skips used numbers anyway
	}
	return numberingRow{
		DocType: docType, Label: domain.NumberLabels[docType], NumberFormat: f, Year: year,
		NextNumber: next, LastIssued: last, MinNext: last + 1, Preview: f.Format(year, next),
	}, nil
}

func numberingYear(r *http.Request) int {
	if y, err := strconv.Atoi(r.URL.Query().Get("year")); err == nil && y >= 2000 && y <= 2100 {
		return y
	}
	return time.Now().Year()
}

// getNumbering: GET /config/numbering?year=2026 → {items: [...]}.
func (s *Server) getNumbering(w http.ResponseWriter, r *http.Request) {
	year := numberingYear(r)
	items := []numberingRow{}
	for _, t := range domain.NumberedTypes {
		row, err := s.numberingRow(t, year)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, row)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "year": year})
}

type numberingInput struct {
	Prefix      string `json:"prefix"`
	IncludeYear bool   `json:"include_year"`
	Digits      int    `json:"digits"`
	ResetYearly bool   `json:"reset_yearly"`
	NextNumber  *int64 `json:"next_number"`
	Year        int    `json:"year"`
}

// putNumbering: PUT /config/numbering/{type}. Admin only. The next number can
// be raised (the jump is written to the journal) but never brought down to a
// number already given to a document.
func (s *Server) putNumbering(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	docType := chi.URLParam(r, "type")
	if _, ok := domain.NumberLabels[docType]; !ok {
		writeErr(w, http.StatusBadRequest, "type de document inconnu")
		return
	}
	var in numberingInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	year := in.Year
	if year < 2000 || year > 2100 {
		year = time.Now().Year()
	}
	f := domain.NumberFormat{Prefix: strings.ToUpper(strings.TrimSpace(in.Prefix)),
		IncludeYear: in.IncludeYear, Digits: in.Digits, ResetYearly: in.ResetYearly}
	if msg := f.Validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	before, err := s.numberingRow(docType, year)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	// Refuse a next number at or below one already issued in the NEW series
	// before saving anything.
	if in.NextNumber != nil {
		last, err := domain.LastIssued(s.db, docType, f, year)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if *in.NextNumber < 1 {
			writeErr(w, http.StatusBadRequest, "le prochain numéro doit être au moins 1")
			return
		}
		if *in.NextNumber <= last {
			writeErr(w, http.StatusConflict, fmt.Sprintf(
				"le prochain numéro doit être au moins %d : le n° %s a déjà été attribué",
				last+1, f.Format(year, last)))
			return
		}
	}
	now := domain.NowISO()
	kv := map[string]string{
		domain.NumberSettingKey(docType, "prefix"): f.Prefix,
		domain.NumberSettingKey(docType, "year"):   boolStr(f.IncludeYear),
		domain.NumberSettingKey(docType, "digits"): strconv.Itoa(f.Digits),
		domain.NumberSettingKey(docType, "reset"):  boolStr(f.ResetYearly),
	}
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	for k, v := range kv {
		if _, err := tx.Exec(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
			ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
			k, v, now); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if f != before.NumberFormat {
		s.audit(r, "settings.numbering", "settings", docType, fmt.Sprintf(
			"%s : format %s → %s", domain.NumberLabels[docType], before.Preview, f.Format(year, before.NextNumber)))
	}
	after, err := s.numberingRow(docType, year)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if in.NextNumber != nil && *in.NextNumber != after.NextNumber {
		if err := domain.SetNextNumber(s.db, docType, year, *in.NextNumber); err != nil {
			// The format is saved; only the counter move is refused.
			writeErr(w, http.StatusConflict, err.Error())
			return
		}
		s.audit(r, "settings.numbering", "settings", docType, fmt.Sprintf(
			"%s : prochain numéro %d → %d", domain.NumberLabels[docType], after.NextNumber, *in.NextNumber))
		if after, err = s.numberingRow(docType, year); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	writeJSON(w, http.StatusOK, after)
}

func boolStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// ---- Groupes de clients -----------------------------------------------------

type CustomerGroup struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	PriceLevel  string `json:"price_level"`  // retail | wholesale
	DiscountPct int64  `json:"discount_pct"` // pct x100
	Members     int64  `json:"members"`
}

func (s *Server) listCustomerGroups(w http.ResponseWriter, _ *http.Request) {
	rows, err := s.db.Query(`SELECT g.id, g.name, g.price_level, g.discount_pct,
			(SELECT COUNT(*) FROM partners p WHERE p.group_id = g.id AND p.active = 1)
		FROM customer_groups g ORDER BY g.name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []CustomerGroup{}
	for rows.Next() {
		var g CustomerGroup
		if err := rows.Scan(&g.ID, &g.Name, &g.PriceLevel, &g.DiscountPct, &g.Members); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, g)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type groupInput struct {
	Name        string `json:"name"`
	PriceLevel  string `json:"price_level"`
	DiscountPct int64  `json:"discount_pct"`
}

func (in *groupInput) validate() string {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return "le nom du groupe est obligatoire"
	}
	if in.PriceLevel == "" {
		in.PriceLevel = "retail"
	}
	if in.PriceLevel != "retail" && in.PriceLevel != "wholesale" {
		return "tarif invalide (détail ou demi-gros)"
	}
	if in.DiscountPct < 0 || in.DiscountPct > 10000 {
		return "la remise va de 0 à 100 %"
	}
	return ""
}

func (s *Server) writeGroup(w http.ResponseWriter, id string, status int) {
	var g CustomerGroup
	err := s.db.QueryRow(`SELECT g.id, g.name, g.price_level, g.discount_pct,
			(SELECT COUNT(*) FROM partners p WHERE p.group_id = g.id AND p.active = 1)
		FROM customer_groups g WHERE g.id = ?`, id).
		Scan(&g.ID, &g.Name, &g.PriceLevel, &g.DiscountPct, &g.Members)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "groupe introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, g)
}

func groupConflict(w http.ResponseWriter, err error) {
	if strings.Contains(err.Error(), "UNIQUE") {
		writeErr(w, http.StatusConflict, "un groupe porte déjà ce nom")
		return
	}
	writeErr(w, http.StatusConflict, err.Error())
}

func (s *Server) createCustomerGroup(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	var in groupInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO customer_groups (id, name, price_level, discount_pct, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)`, id, in.Name, in.PriceLevel, in.DiscountPct, now, now); err != nil {
		groupConflict(w, err)
		return
	}
	s.writeGroup(w, id, http.StatusCreated)
}

func (s *Server) updateCustomerGroup(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in groupInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	res, err := s.db.Exec(`UPDATE customer_groups SET name=?, price_level=?, discount_pct=?, updated_at=? WHERE id=?`,
		in.Name, in.PriceLevel, in.DiscountPct, domain.NowISO(), id)
	if err != nil {
		groupConflict(w, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "groupe introuvable")
		return
	}
	s.writeGroup(w, id, http.StatusOK)
}

// deleteCustomerGroup removes a group; its customers simply leave the group.
func (s *Server) deleteCustomerGroup(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE partners SET group_id = NULL WHERE group_id = ?`, id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	res, err := tx.Exec(`DELETE FROM customer_groups WHERE id = ?`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "groupe introuvable")
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// ---- Fidélité -----------------------------------------------------------------

type loyaltyEntry struct {
	ID         string  `json:"id"`
	Points     int64   `json:"points"`
	Kind       string  `json:"kind"`
	DocumentID *string `json:"document_id"`
	Number     *string `json:"number"`
	Note       *string `json:"note"`
	CreatedAt  string  `json:"created_at"`
}

// partnerLoyalty: GET /partners/{id}/loyalty → balance, value, history.
func (s *Server) partnerLoyalty(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "partners") && !s.can(r, "pos") && !s.can(r, "sales") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM partners WHERE id = ?`, id).Scan(&n)
	if n == 0 {
		writeErr(w, http.StatusNotFound, "client introuvable")
		return
	}
	cfg := domain.LoadLoyaltyConfig(s.db)
	bal := domain.LoyaltyBalance(s.db, id)
	rows, err := s.db.Query(`SELECT l.id, l.points, l.kind, l.document_id, d.number, l.note, l.created_at
		FROM loyalty_ledger l LEFT JOIN documents d ON d.id = l.document_id
		WHERE l.partner_id = ? ORDER BY l.created_at DESC, l.id DESC LIMIT 200`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	hist := []loyaltyEntry{}
	for rows.Next() {
		var e loyaltyEntry
		if err := rows.Scan(&e.ID, &e.Points, &e.Kind, &e.DocumentID, &e.Number, &e.Note, &e.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		hist = append(hist, e)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"partner_id":  id,
		"enabled":     cfg.Enabled,
		"balance":     bal,
		"value":       max(bal, 0) * cfg.PointValue,
		"point_value": cfg.PointValue,
		"earn_per":    cfg.EarnPer,
		"min_redeem":  cfg.MinRedeem,
		"can_redeem":  cfg.Enabled && bal >= cfg.MinRedeem && bal > 0,
		"history":     hist,
	})
}

func loyaltyErr(w http.ResponseWriter, err error) {
	var pe *domain.PostError
	switch {
	case errors.As(err, &pe):
		writeErr(w, http.StatusConflict, pe.Msg)
	case errors.Is(err, domain.ErrNotFound):
		writeErr(w, http.StatusNotFound, "introuvable")
	default:
		writeErr(w, http.StatusInternalServerError, err.Error())
	}
}

// redeemLoyalty: POST /partners/{id}/loyalty/redeem {points, document_id?}
// → {redemption_id, points, value, balance}. The POS takes `value` off the
// ticket; if the sale is abandoned it calls /loyalty/redemptions/{id}/cancel.
func (s *Server) redeemLoyalty(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") && !s.can(r, "sales") {
		forbid(w)
		return
	}
	var in struct {
		Points     int64   `json:"points"`
		DocumentID *string `json:"document_id"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	doc := ""
	if in.DocumentID != nil {
		doc = strings.TrimSpace(*in.DocumentID)
	}
	uid := ""
	if u := authFrom(r); u != nil {
		uid = u.ID
	}
	res, err := domain.RedeemLoyalty(s.db, chi.URLParam(r, "id"), in.Points, doc, uid)
	if err != nil {
		loyaltyErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// cancelLoyaltyRedemption: POST /loyalty/redemptions/{id}/cancel → {balance}.
func (s *Server) cancelLoyaltyRedemption(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") && !s.can(r, "sales") {
		forbid(w)
		return
	}
	uid := ""
	if u := authFrom(r); u != nil {
		uid = u.ID
	}
	bal, err := domain.CancelRedemption(s.db, chi.URLParam(r, "id"), uid)
	if err != nil {
		loyaltyErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "cancelled", "balance": bal})
}
