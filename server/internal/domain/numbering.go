package domain

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"
)

// Document numbering, configurable per type in Paramètres › Documents et
// numérotation. Setting keys (all optional — without them, the
// historical format « FV-2026-000124 » stays unchanged):
//
//	number_<TYPE>_prefix  prefix (empty = none)
//	number_<TYPE>_year    '1' / '0': the year appears in the number
//	number_<TYPE>_digits  4 to 8 digits (zero-padded)
//	number_<TYPE>_reset   '1' / '0': restarts at 1 every year (requires the year)
//
// The counters live in `sequences`: (doc_type, year) when the
// numbering restarts every year, (doc_type, 0) when it is continuous.
// A number is only assigned on posting and is never reused: the
// sequence of posted documents stays continuous, with no gap or duplicate.

// Querier is what both *sql.DB and *sql.Tx offer for one-row reads.
type Querier interface {
	QueryRow(query string, args ...any) *sql.Row
}

// Setting reads one shop setting; ok is false when the key is absent.
func Setting(q Querier, key string) (string, bool) {
	var v string
	if err := q.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&v); err != nil {
		return "", false
	}
	return v, true
}

// SettingInt reads an integer setting with a default.
func SettingInt(q Querier, key string, def int64) int64 {
	v, ok := Setting(q, key)
	if !ok {
		return def
	}
	n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
	if err != nil {
		return def
	}
	return n
}

// SettingBool reads a '1'/'0' setting with a default.
func SettingBool(q Querier, key string, def bool) bool {
	v, ok := Setting(q, key)
	if !ok || strings.TrimSpace(v) == "" {
		return def
	}
	return strings.TrimSpace(v) == "1"
}

// NumberFormat is how one document type is numbered.
type NumberFormat struct {
	Prefix      string `json:"prefix"`
	IncludeYear bool   `json:"include_year"`
	Digits      int    `json:"digits"`
	ResetYearly bool   `json:"reset_yearly"`
}

// NumberLabels names each numbered document type in plain French.
var NumberLabels = map[string]string{
	SaleTicket:         "Ticket",
	SaleInvoice:        "Facture",
	Quote:              "Devis",
	DeliveryNote:       "Bon de livraison",
	SaleCreditNote:     "Avoir client",
	PurchaseOrder:      "Bon de commande",
	PurchaseReceipt:    "Bon de réception",
	PurchaseInvoice:    "Facture fournisseur",
	PurchaseCreditNote: "Avoir fournisseur",
	StockAdjustment:    "Ajustement",
	StockTransfer:      "Transfert",
	InventoryCount:     "Inventaire",
	PaymentIn:          "Encaissement",
	PaymentOut:         "Paiement fournisseur",
}

// NumberedTypes is the display order of the numbering settings.
var NumberedTypes = []string{
	SaleTicket, SaleInvoice, Quote, DeliveryNote, SaleCreditNote,
	PurchaseOrder, PurchaseReceipt, PurchaseInvoice, PurchaseCreditNote,
	StockAdjustment, StockTransfer, InventoryCount, PaymentIn, PaymentOut,
}

// DefaultNumberFormat is today's format: « FV-2026-000124 », reset each year.
func DefaultNumberFormat(docType string) NumberFormat {
	return NumberFormat{Prefix: NumberPrefix[docType], IncludeYear: true, Digits: 6, ResetYearly: true}
}

// NumberSettingKey returns the settings key of one numbering field.
func NumberSettingKey(docType, field string) string {
	return "number_" + docType + "_" + field
}

// LoadNumberFormat reads the numbering settings of a document type.
func LoadNumberFormat(q Querier, docType string) NumberFormat {
	f := DefaultNumberFormat(docType)
	if v, ok := Setting(q, NumberSettingKey(docType, "prefix")); ok {
		f.Prefix = strings.TrimSpace(v)
	}
	f.IncludeYear = SettingBool(q, NumberSettingKey(docType, "year"), true)
	if d := SettingInt(q, NumberSettingKey(docType, "digits"), 6); d >= 4 && d <= 8 {
		f.Digits = int(d)
	}
	f.ResetYearly = SettingBool(q, NumberSettingKey(docType, "reset"), true)
	return f.Normalized()
}

// Normalized enforces the rules: digits 4–8, reset only when the year shows
// (otherwise « FV-000001 » would come back every January).
func (f NumberFormat) Normalized() NumberFormat {
	if f.Digits < 4 || f.Digits > 8 {
		f.Digits = 6
	}
	if !f.IncludeYear {
		f.ResetYearly = false
	}
	return f
}

// Validate checks a format typed in the settings screen.
func (f NumberFormat) Validate() string {
	if len(f.Prefix) > 8 {
		return "le préfixe fait au plus 8 caractères"
	}
	for _, c := range f.Prefix {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			return "le préfixe ne contient que des lettres et des chiffres (sans espace ni accent)"
		}
	}
	if f.Digits < 4 || f.Digits > 8 {
		return "le nombre de chiffres va de 4 à 8"
	}
	if f.ResetYearly && !f.IncludeYear {
		return "pour repartir à 1 chaque année, l'année doit figurer dans le numéro"
	}
	return ""
}

// SeqYear is the sequences.year key for a document dated in `year`.
func (f NumberFormat) SeqYear(year int) int {
	if f.ResetYearly {
		return year
	}
	return 0
}

// head is everything before the counter (« FV-2026- »).
func (f NumberFormat) head(year int) string {
	var parts []string
	if f.Prefix != "" {
		parts = append(parts, f.Prefix)
	}
	if f.IncludeYear {
		parts = append(parts, strconv.Itoa(year))
	}
	if len(parts) == 0 {
		return ""
	}
	return strings.Join(parts, "-") + "-"
}

// Format builds the number « FV-2026-000124 ».
func (f NumberFormat) Format(year int, n int64) string {
	return f.head(year) + fmt.Sprintf("%0*d", f.Digits, n)
}

// counterOf returns the counter of an issued number when it belongs to the
// same series as (f, year); ok is false otherwise.
func (f NumberFormat) counterOf(number string, year int) (int64, bool) {
	i := strings.LastIndex(number, "-")
	head, tail := "", number
	if i >= 0 {
		head, tail = number[:i+1], number[i+1:]
	}
	n, err := strconv.ParseInt(tail, 10, 64)
	if err != nil || tail == "" {
		return 0, false
	}
	if f.ResetYearly || !f.IncludeYear {
		return n, head == f.head(year)
	}
	// Continuous with the year shown: « FV-2025-000010 » and « FV-2026-000011 »
	// are the same series.
	want := ""
	if f.Prefix != "" {
		want = f.Prefix + "-"
	}
	if !strings.HasPrefix(head, want) {
		return 0, false
	}
	y := strings.TrimSuffix(strings.TrimPrefix(head, want), "-")
	if len(y) != 4 {
		return 0, false
	}
	if _, err := strconv.Atoi(y); err != nil {
		return 0, false
	}
	return n, true
}

// LastIssued returns the highest counter already given to a validated (or
// cancelled — the number stays) document of this series; 0 when none.
func LastIssued(db *sql.DB, docType string, f NumberFormat, year int) (int64, error) {
	q := `SELECT number FROM documents WHERE doc_type = ? AND number IS NOT NULL`
	args := []any{docType}
	if f.Prefix != "" {
		q += ` AND number LIKE ?`
		args = append(args, f.Prefix+"-%")
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var max int64
	for rows.Next() {
		var num string
		if err := rows.Scan(&num); err != nil {
			return 0, err
		}
		if n, ok := f.counterOf(num, year); ok && n > max {
			max = n
		}
	}
	return max, rows.Err()
}

// SequenceNext returns the counter the next validated document will get.
func SequenceNext(q Querier, docType string, f NumberFormat, year int) int64 {
	var n int64
	if err := q.QueryRow(`SELECT next_number FROM sequences WHERE doc_type = ? AND year = ?`,
		docType, f.SeqYear(year)).Scan(&n); err != nil || n < 1 {
		return 1
	}
	return n
}

// SetNextNumber moves the counter of the current series. It can be raised
// freely (the jump is logged by the caller) but never set at or below a
// number already issued: two documents never share a number.
func SetNextNumber(db *sql.DB, docType string, year int, next int64) error {
	f := LoadNumberFormat(db, docType)
	last, err := LastIssued(db, docType, f, year)
	if err != nil {
		return err
	}
	if next <= last {
		return &PostError{fmt.Sprintf(
			"le prochain numéro doit être supérieur à %d : ce numéro a déjà été attribué (%s)",
			last, f.Format(year, last))}
	}
	if next < 1 {
		return &PostError{"le prochain numéro doit être au moins 1"}
	}
	_, err = db.Exec(`INSERT INTO sequences (doc_type, year, next_number) VALUES (?, ?, ?)
		ON CONFLICT (doc_type, year) DO UPDATE SET next_number = excluded.next_number`,
		docType, f.SeqYear(year), next)
	return err
}

// nextNumberFmt draws the next number of a document type for a document dated
// docDate, honouring the numbering settings. A number already present (after
// a format change, say) is skipped so documents.number stays unique.
func nextNumberFmt(tx *sql.Tx, docType, docDate string) (string, error) {
	year := 0
	if len(docDate) >= 4 {
		fmt.Sscanf(docDate[:4], "%d", &year)
	}
	if year == 0 {
		return "", fmt.Errorf("invalid doc_date %q", docDate)
	}
	f := LoadNumberFormat(tx, docType)
	key := f.SeqYear(year)
	if _, err := tx.Exec(`INSERT INTO sequences (doc_type, year, next_number) VALUES (?, ?, 1)
		ON CONFLICT (doc_type, year) DO NOTHING`, docType, key); err != nil {
		return "", err
	}
	var n int64
	if err := tx.QueryRow(`SELECT next_number FROM sequences WHERE doc_type=? AND year=?`,
		docType, key).Scan(&n); err != nil {
		return "", err
	}
	if n < 1 {
		n = 1
	}
	number := f.Format(year, n)
	for tries := 0; tries < 100000; tries++ {
		var taken int
		tx.QueryRow(`SELECT COUNT(*) FROM documents WHERE number = ?`, number).Scan(&taken)
		if taken == 0 {
			break
		}
		n++
		number = f.Format(year, n)
	}
	if _, err := tx.Exec(`UPDATE sequences SET next_number = ? WHERE doc_type=? AND year=?`,
		n+1, docType, key); err != nil {
		return "", err
	}
	return number, nil
}
