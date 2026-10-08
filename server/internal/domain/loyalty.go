package domain

import (
	"database/sql"
	"fmt"
)

// Fidélité : 1 point par tranche de `loyalty_earn_per` centimes payés, gagné à
// la validation d'une vente (ticket ou facture) avec un client ; un point vaut
// `loyalty_point_value` centimes quand il est utilisé ; il en faut au moins
// `loyalty_min_redeem` pour en utiliser. Le journal loyalty_ledger est
// immuable : annuler une vente écrit une ligne inverse.

// LoyaltyConfig is the shop's loyalty programme.
type LoyaltyConfig struct {
	Enabled    bool  `json:"enabled"`
	EarnPer    int64 `json:"earn_per"`    // centimes for 1 point
	PointValue int64 `json:"point_value"` // centimes per point
	MinRedeem  int64 `json:"min_redeem"`  // points
}

// LoadLoyaltyConfig reads the loyalty settings (same defaults as the app).
func LoadLoyaltyConfig(q Querier) LoyaltyConfig {
	return LoyaltyConfig{
		Enabled:    SettingBool(q, "loyalty_enabled", false),
		EarnPer:    SettingInt(q, "loyalty_earn_per", 10000),
		PointValue: SettingInt(q, "loyalty_point_value", 100),
		MinRedeem:  SettingInt(q, "loyalty_min_redeem", 100),
	}
}

// PointsFor returns the points a purchase of `paid` centimes earns.
func (c LoyaltyConfig) PointsFor(paid int64) int64 {
	if !c.Enabled || c.EarnPer <= 0 || paid <= 0 {
		return 0
	}
	return paid / c.EarnPer
}

// LoyaltyBalance is the sum of a customer's points.
func LoyaltyBalance(q Querier, partnerID string) int64 {
	var b sql.NullInt64
	q.QueryRow(`SELECT SUM(points) FROM loyalty_ledger WHERE partner_id = ?`, partnerID).Scan(&b)
	return b.Int64
}

// earnLoyalty credits the points of a posted sale. Only sales with a real
// customer earn (not the « client comptoir » set as the POS default).
func earnLoyalty(tx *sql.Tx, docType string, partnerID sql.NullString, docID string,
	paid int64, userID, now string) error {
	if docType != SaleTicket && docType != SaleInvoice || !partnerID.Valid {
		return nil
	}
	cfg := LoadLoyaltyConfig(tx)
	pts := cfg.PointsFor(paid)
	if pts <= 0 {
		return nil
	}
	if def, ok := Setting(tx, "pos_default_customer_id"); ok && def == partnerID.String {
		return nil
	}
	var kind string
	if err := tx.QueryRow(`SELECT kind FROM partners WHERE id = ?`, partnerID.String).Scan(&kind); err != nil ||
		kind == "supplier" {
		return nil
	}
	_, err := tx.Exec(`INSERT INTO loyalty_ledger (id, partner_id, points, document_id, kind, created_by, created_at)
		VALUES (?, ?, ?, ?, 'earn', ?, ?)`, NewID(), partnerID.String, pts, docID, nullIfEmpty(userID), now)
	return err
}

// voidLoyalty reverses every point movement tied to a cancelled document:
// points earned are taken back, points used on it are given back.
func voidLoyalty(tx *sql.Tx, docID, userID, now string) error {
	rows, err := tx.Query(`SELECT partner_id, SUM(points) FROM loyalty_ledger
		WHERE document_id = ? GROUP BY partner_id`, docID)
	if err != nil {
		return err
	}
	type pp struct {
		partner string
		pts     int64
	}
	var all []pp
	for rows.Next() {
		var p pp
		if err := rows.Scan(&p.partner, &p.pts); err != nil {
			rows.Close()
			return err
		}
		all = append(all, p)
	}
	rows.Close()
	for _, p := range all {
		if p.pts == 0 {
			continue
		}
		if _, err := tx.Exec(`INSERT INTO loyalty_ledger (id, partner_id, points, document_id, kind, note, created_by, created_at)
			VALUES (?, ?, ?, ?, 'void', 'document annulé', ?, ?)`,
			NewID(), p.partner, -p.pts, docID, nullIfEmpty(userID), now); err != nil {
			return err
		}
	}
	return nil
}

// Redemption is the result of using points at the till.
type Redemption struct {
	ID      string `json:"redemption_id"`
	Points  int64  `json:"points"`
	Value   int64  `json:"value"`   // centimes to take off the ticket
	Balance int64  `json:"balance"` // points left
}

// RedeemLoyalty uses `points` of a customer's balance. The value in centimes
// is returned; the caller takes it off the sale (a « Points fidélité » line).
func RedeemLoyalty(db *sql.DB, partnerID string, points int64, documentID, userID string) (*Redemption, error) {
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	cfg := LoadLoyaltyConfig(tx)
	if !cfg.Enabled {
		return nil, &PostError{"le programme de fidélité n'est pas activé (Paramètres › Clients et fidélité)"}
	}
	if points <= 0 {
		return nil, &PostError{"nombre de points invalide"}
	}
	var name string
	if err := tx.QueryRow(`SELECT name FROM partners WHERE id = ?`, partnerID).Scan(&name); err != nil {
		return nil, ErrNotFound
	}
	bal := LoyaltyBalance(tx, partnerID)
	if points < cfg.MinRedeem {
		return nil, &PostError{fmt.Sprintf("il faut au moins %d points pour les utiliser", cfg.MinRedeem)}
	}
	if points > bal {
		return nil, &PostError{fmt.Sprintf("%s n'a que %d points", name, bal)}
	}
	if documentID != "" {
		var n int
		tx.QueryRow(`SELECT COUNT(*) FROM documents WHERE id = ?`, documentID).Scan(&n)
		if n == 0 {
			return nil, &PostError{"document introuvable"}
		}
	}
	id := NewID()
	if _, err := tx.Exec(`INSERT INTO loyalty_ledger (id, partner_id, points, document_id, kind, created_by, created_at)
		VALUES (?, ?, ?, ?, 'redeem', ?, ?)`,
		id, partnerID, -points, nullIfEmpty(documentID), nullIfEmpty(userID), NowISO()); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &Redemption{ID: id, Points: points, Value: points * cfg.PointValue, Balance: bal - points}, nil
}

// CancelRedemption gives back the points of a redemption whose sale did not
// go through. Refused twice, and refused once the sale is validated (void the
// sale instead: that gives the points back too).
func CancelRedemption(db *sql.DB, redemptionID, userID string) (int64, error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var partnerID string
	var pts int64
	var docID sql.NullString
	if err := tx.QueryRow(`SELECT partner_id, points, document_id FROM loyalty_ledger
		WHERE id = ? AND kind = 'redeem'`, redemptionID).Scan(&partnerID, &pts, &docID); err != nil {
		return 0, ErrNotFound
	}
	var n int
	tx.QueryRow(`SELECT COUNT(*) FROM loyalty_ledger WHERE ref_id = ?`, redemptionID).Scan(&n)
	if n > 0 {
		return 0, &PostError{"cette utilisation de points est déjà annulée"}
	}
	if docID.Valid {
		var status string
		tx.QueryRow(`SELECT status FROM documents WHERE id = ?`, docID.String).Scan(&status)
		if status == "posted" {
			return 0, &PostError{"la vente est validée : annulez la vente pour rendre les points"}
		}
		var voided int
		tx.QueryRow(`SELECT COUNT(*) FROM loyalty_ledger WHERE document_id = ? AND kind = 'void' AND ref_id IS NULL`,
			docID.String).Scan(&voided)
		if voided > 0 {
			return 0, &PostError{"la vente a été annulée : les points ont déjà été rendus"}
		}
	}
	if _, err := tx.Exec(`INSERT INTO loyalty_ledger (id, partner_id, points, document_id, kind, ref_id, note, created_by, created_at)
		VALUES (?, ?, ?, ?, 'void', ?, 'utilisation annulée', ?, ?)`,
		NewID(), partnerID, -pts, docID, redemptionID, nullIfEmpty(userID), NowISO()); err != nil {
		return 0, err
	}
	bal := LoyaltyBalance(tx, partnerID)
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return bal, nil
}
