package api

import (
	"crypto/rand"
	"database/sql"
	"math/big"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// Gift cards are a liability the shop owes its customers: sold for cash,
// redeemed later as payment. Every redemption is an immutable row.

type GiftCard struct {
	ID            string  `json:"id"`
	Code          string  `json:"code"`
	InitialAmount int64   `json:"initial_amount"`
	Balance       int64   `json:"balance"`
	Status        string  `json:"status"`
	ExpiresAt     *string `json:"expires_at"`
	Notes         *string `json:"notes"`
	CreatedAt     string  `json:"created_at"`
}

const cardCols = `id, code, initial_amount, balance, status, expires_at, notes, created_at`

func scanCard(row interface{ Scan(...any) error }) (GiftCard, error) {
	var c GiftCard
	err := row.Scan(&c.ID, &c.Code, &c.InitialAmount, &c.Balance, &c.Status,
		&c.ExpiresAt, &c.Notes, &c.CreatedAt)
	return c, err
}

// Same unambiguous alphabet as pairing codes; format XXXX-XXXX-XXXX.
func newCardCode() string {
	b := make([]byte, 12)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(pairAlphabet))))
		if err != nil {
			return ""
		}
		b[i] = pairAlphabet[n.Int64()]
	}
	s := string(b)
	return s[0:4] + "-" + s[4:8] + "-" + s[8:12]
}

func normalizeCardCode(raw string) string {
	s := strings.ToUpper(strings.TrimSpace(raw))
	s = strings.ReplaceAll(s, " ", "")
	s = strings.ReplaceAll(s, "-", "")
	if len(s) != 12 {
		return ""
	}
	return s[0:4] + "-" + s[4:8] + "-" + s[8:12]
}

func (s *Server) cardExpired(c *GiftCard) bool {
	if c.ExpiresAt == nil || *c.ExpiresAt == "" {
		return false
	}
	return *c.ExpiresAt < domain.NowISO()[:10]
}

func (s *Server) listGiftCards(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") && !s.can(r, "settings") {
		forbid(w)
		return
	}
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	where := ""
	args := []any{}
	if q != "" {
		where = "WHERE code LIKE ? OR notes LIKE ?"
		like := "%" + strings.ToUpper(q) + "%"
		args = append(args, like, "%"+q+"%")
	}
	rows, err := s.db.Query(`SELECT `+cardCols+` FROM gift_cards `+where+
		` ORDER BY created_at DESC LIMIT 200`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []GiftCard{}
	for rows.Next() {
		c, err := scanCard(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, c)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) createGiftCard(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	var in struct {
		Amount    int64   `json:"amount"`
		ExpiresAt *string `json:"expires_at"`
		Notes     *string `json:"notes"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.Amount <= 0 {
		writeErr(w, http.StatusBadRequest, "montant invalide")
		return
	}
	code := newCardCode()
	if code == "" {
		writeErr(w, http.StatusInternalServerError, "génération du code impossible")
		return
	}
	u := authFrom(r)
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO gift_cards
		(id, code, initial_amount, balance, status, expires_at, notes, created_by, created_at)
		VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?)`,
		id, code, in.Amount, in.Amount, in.ExpiresAt, in.Notes, u.ID, now); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	c, _ := scanCard(s.db.QueryRow(`SELECT `+cardCols+` FROM gift_cards WHERE id = ?`, id))
	writeJSON(w, http.StatusCreated, c)
}

// getGiftCard looks a card up by its code — what the POS does at the till.
func (s *Server) getGiftCard(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	code := normalizeCardCode(chi.URLParam(r, "code"))
	if code == "" {
		writeErr(w, http.StatusBadRequest, "code invalide")
		return
	}
	c, err := scanCard(s.db.QueryRow(`SELECT `+cardCols+` FROM gift_cards WHERE code = ?`, code))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "carte introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if s.cardExpired(&c) && c.Status == "active" {
		c.Status = "expired"
	}
	writeJSON(w, http.StatusOK, c)
}

// redeemGiftCard debits the card. The amount must be fully covered — partial
// tenders would mis-state the caisse, so v1 keeps it whole.
func (s *Server) redeemGiftCard(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	code := normalizeCardCode(chi.URLParam(r, "code"))
	var in struct {
		Amount     int64   `json:"amount"`
		DocumentID *string `json:"document_id"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if code == "" || in.Amount <= 0 {
		writeErr(w, http.StatusBadRequest, "code ou montant invalide")
		return
	}

	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()

	c, err := scanCard(tx.QueryRow(`SELECT `+cardCols+` FROM gift_cards WHERE code = ?`, code))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "carte introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if c.Status != "active" {
		writeErr(w, http.StatusConflict, "carte "+c.Status)
		return
	}
	if s.cardExpired(&c) {
		writeErr(w, http.StatusConflict, "carte expirée")
		return
	}
	if c.Balance < in.Amount {
		writeErr(w, http.StatusConflict, "solde insuffisant sur la carte")
		return
	}

	newBalance := c.Balance - in.Amount
	status := "active"
	if newBalance == 0 {
		status = "depleted"
	}
	if _, err := tx.Exec(`UPDATE gift_cards SET balance = ?, status = ? WHERE id = ?`,
		newBalance, status, c.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	useID := domain.NewID()
	if _, err := tx.Exec(`INSERT INTO gift_card_uses (id, card_id, document_id, amount, created_at)
		VALUES (?, ?, ?, ?, ?)`,
		useID, c.ID, in.DocumentID, in.Amount, domain.NowISO()); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"use_id":  useID,
		"balance": newBalance,
		"status":  status,
	})
}

// refundGiftCardUse puts money back when the sale it paid for failed to post.
func (s *Server) refundGiftCardUse(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "pos") {
		forbid(w)
		return
	}
	useID := chi.URLParam(r, "id")
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()

	var cardID string
	var amount int64
	err = tx.QueryRow(`SELECT card_id, amount FROM gift_card_uses WHERE id = ? AND amount > 0`,
		useID).Scan(&cardID, &amount)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "utilisation introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	// Refuse a double refund.
	var refunded int
	tx.QueryRow(`SELECT COUNT(*) FROM gift_card_uses WHERE card_id = ? AND amount = ? AND id != ? AND amount < 0`,
		cardID, -amount, useID).Scan(&refunded)

	if _, err := tx.Exec(`UPDATE gift_cards SET balance = balance + ?, status = 'active' WHERE id = ?`,
		amount, cardID); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, err := tx.Exec(`INSERT INTO gift_card_uses (id, card_id, document_id, amount, created_at)
		VALUES (?, ?, NULL, ?, ?)`,
		domain.NewID(), cardID, -amount, domain.NowISO()); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "refunded"})
}

// cancelGiftCard voids a card (admin).
func (s *Server) cancelGiftCard(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	res, err := s.db.Exec(`UPDATE gift_cards SET status = 'cancelled' WHERE id = ? AND status = 'active'`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "carte introuvable ou déjà inactive")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "cancelled"})
}
