package api

import (
	"database/sql"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// SAV: repair intake tickets for phone/electronics shops.

type Repair struct {
	ID            string  `json:"id"`
	Number        string  `json:"number"`
	PartnerID     *string `json:"partner_id"`
	CustomerName  string  `json:"customer_name"`
	CustomerPhone *string `json:"customer_phone"`
	Device        string  `json:"device"`
	Serial        *string `json:"serial"`
	Fault         string  `json:"fault"`
	Deposit       int64   `json:"deposit"`
	Quote         *int64  `json:"quote"`
	Status        string  `json:"status"`
	Notes         *string `json:"notes"`
	CreatedAt     string  `json:"created_at"`
	UpdatedAt     string  `json:"updated_at"`
}

const repairCols = `id, number, partner_id, customer_name, customer_phone, device,
	serial, fault, deposit, quote, status, notes, created_at, updated_at`

func scanRepair(row interface{ Scan(...any) error }) (Repair, error) {
	var x Repair
	err := row.Scan(&x.ID, &x.Number, &x.PartnerID, &x.CustomerName, &x.CustomerPhone,
		&x.Device, &x.Serial, &x.Fault, &x.Deposit, &x.Quote, &x.Status, &x.Notes,
		&x.CreatedAt, &x.UpdatedAt)
	return x, err
}

var repairStatuses = map[string]bool{
	"received": true, "in_progress": true, "ready": true,
	"returned": true, "cancelled": true,
}

func (s *Server) listRepairs(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "sav") {
		forbid(w)
		return
	}
	where, args := "WHERE 1=1", []any{}
	if st := r.URL.Query().Get("status"); st != "" {
		where += " AND status = ?"
		args = append(args, st)
	}
	if q := strings.TrimSpace(r.URL.Query().Get("q")); q != "" {
		where += ` AND (customer_name LIKE ? OR customer_phone LIKE ? OR device LIKE ?
			OR serial LIKE ? OR number LIKE ?)`
		like := "%" + q + "%"
		args = append(args, like, like, like, like, like)
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	args = append(args, limit)
	rows, err := s.db.Query(`SELECT `+repairCols+` FROM repairs `+where+
		` ORDER BY created_at DESC LIMIT ?`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Repair{}
	for rows.Next() {
		x, err := scanRepair(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, x)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type repairInput struct {
	PartnerID     *string `json:"partner_id"`
	CustomerName  string  `json:"customer_name"`
	CustomerPhone *string `json:"customer_phone"`
	Device        string  `json:"device"`
	Serial        *string `json:"serial"`
	Fault         string  `json:"fault"`
	Deposit       int64   `json:"deposit"`
	Quote         *int64  `json:"quote"`
	Status        string  `json:"status"`
	Notes         *string `json:"notes"`
}

func (s *Server) createRepair(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "sav") {
		forbid(w)
		return
	}
	var in repairInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.CustomerName) == "" || strings.TrimSpace(in.Device) == "" ||
		strings.TrimSpace(in.Fault) == "" {
		writeErr(w, http.StatusBadRequest, "client, appareil et panne sont obligatoires")
		return
	}
	id, now := domain.NewID(), domain.NowISO()

	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()

	// Gapless yearly numbering, same scheme as documents (REPAIR row in sequences).
	year := 0
	fmt.Sscanf(now[:4], "%d", &year)
	if _, err := tx.Exec(`INSERT INTO sequences (doc_type, year, next_number) VALUES ('REPAIR', ?, 1)
		ON CONFLICT (doc_type, year) DO NOTHING`, year); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var n int64
	if err := tx.QueryRow(`SELECT next_number FROM sequences WHERE doc_type='REPAIR' AND year=?`,
		year).Scan(&n); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, err := tx.Exec(`UPDATE sequences SET next_number = next_number + 1
		WHERE doc_type='REPAIR' AND year=?`, year); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	number := fmt.Sprintf("RP-%d-%06d", year, n)

	u := authFrom(r)
	if _, err := tx.Exec(`INSERT INTO repairs (id, number, partner_id, customer_name,
			customer_phone, device, serial, fault, deposit, quote, status, notes,
			created_by, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'received', ?, ?, ?, ?)`,
		id, number, in.PartnerID, strings.TrimSpace(in.CustomerName), in.CustomerPhone,
		strings.TrimSpace(in.Device), in.Serial, strings.TrimSpace(in.Fault),
		in.Deposit, in.Quote, in.Notes, u.ID, now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.respondRepair(w, id, http.StatusCreated)
}

func (s *Server) updateRepair(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "sav") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	var in repairInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if !repairStatuses[in.Status] {
		writeErr(w, http.StatusBadRequest, "invalid status")
		return
	}
	res, err := s.db.Exec(`UPDATE repairs SET customer_name=?, customer_phone=?, device=?,
			serial=?, fault=?, deposit=?, quote=?, status=?, notes=?, updated_at=?
		WHERE id=?`,
		strings.TrimSpace(in.CustomerName), in.CustomerPhone, strings.TrimSpace(in.Device),
		in.Serial, strings.TrimSpace(in.Fault), in.Deposit, in.Quote, in.Status, in.Notes,
		domain.NowISO(), id)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "repair not found")
		return
	}
	s.respondRepair(w, id, http.StatusOK)
}

func (s *Server) respondRepair(w http.ResponseWriter, id string, status int) {
	x, err := scanRepair(s.db.QueryRow(`SELECT `+repairCols+` FROM repairs WHERE id = ?`, id))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "repair not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, x)
}
