package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/analytics"
	"elixir/server/internal/domain"
)

func (s *Server) analyticsCaller(r *http.Request) analytics.Caller {
	u := authFrom(r)
	if u == nil {
		return analytics.Caller{}
	}
	return analytics.Caller{UserID: u.ID, Role: u.Role, Perms: u.Perms}
}

func writeAnalyticsErr(w http.ResponseWriter, err error) {
	var ae *analytics.Error
	if errors.As(err, &ae) {
		status := http.StatusBadRequest
		switch ae.Code {
		case "forbidden":
			status = http.StatusForbidden
		case "timeout":
			status = http.StatusGatewayTimeout
		}
		writeJSON(w, status, map[string]string{"error": ae.Message, "code": ae.Code})
		return
	}
	writeErr(w, http.StatusInternalServerError, err.Error())
}

// GET /analytics/schema — la liste blanche visible par le demandeur.
func (s *Server) analyticsSchema(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	var ws string
	s.db.QueryRow(`SELECT value FROM settings WHERE key='week_start_day'`).Scan(&ws)
	writeJSON(w, http.StatusOK, map[string]any{
		"version":        analytics.SchemaVersion,
		"week_start_day": ws,
		"sources":        analytics.VisibleSchema(s.analyticsCaller(r)),
		"ranges": []string{"today", "yesterday", "this_week", "previous_week", "this_month", "previous_month",
			"this_quarter", "previous_quarter", "this_year", "previous_year", "year_to_date", "last_n_days", "last_n_months", "all", "custom"},
	})
}

// POST /analytics/query
func (s *Server) analyticsQuery(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	var rq analytics.Request
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&rq); err != nil {
		writeErr(w, http.StatusBadRequest, "requête illisible : "+err.Error())
		return
	}
	res, err := s.analytics.Run(r.Context(), rq, s.analyticsCaller(r))
	if err != nil {
		writeAnalyticsErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// POST /analytics/query/batch
func (s *Server) analyticsBatch(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	var br analytics.BatchRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&br); err != nil {
		writeErr(w, http.StatusBadRequest, "requête illisible : "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": s.analytics.Batch(r.Context(), br, s.analyticsCaller(r))})
}

// ---- rapports enregistrés -------------------------------------------------------

type savedReport struct {
	ID          string          `json:"id"`
	Name        string          `json:"name"`
	Spec        json.RawMessage `json:"spec"`
	SpecVersion int             `json:"spec_version"`
	ChartType   string          `json:"chart_type"`
	Encoding    json.RawMessage `json:"encoding"`
	OwnerID     *string         `json:"owner_id"`
	IsShared    bool            `json:"is_shared"`
	IsDefault   bool            `json:"is_default"`
	Missing     []string        `json:"missing_fields,omitempty"`
	CreatedAt   string          `json:"created_at"`
	UpdatedAt   string          `json:"updated_at"`
}

const reportCols = `id, name, spec_json, spec_version, chart_type, encoding_json, owner_id, is_shared, is_default, created_at, updated_at`

func scanReport(row interface{ Scan(...any) error }) (savedReport, error) {
	var rp savedReport
	var spec, enc string
	var shared, def int
	err := row.Scan(&rp.ID, &rp.Name, &spec, &rp.SpecVersion, &rp.ChartType, &enc, &rp.OwnerID, &shared, &def, &rp.CreatedAt, &rp.UpdatedAt)
	if err != nil {
		return rp, err
	}
	migrated, missing := analytics.MigrateSpec(json.RawMessage(spec), rp.SpecVersion)
	rp.Spec = migrated
	rp.Missing = missing
	if enc == "" {
		enc = "{}"
	}
	rp.Encoding = json.RawMessage(enc)
	rp.IsShared, rp.IsDefault = shared == 1, def == 1
	return rp, nil
}

func (s *Server) listReports(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	u := authFrom(r)
	rows, err := s.db.Query(`SELECT `+reportCols+` FROM saved_reports WHERE is_shared = 1 OR owner_id = ? ORDER BY is_default DESC, name`, u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []savedReport{}
	for rows.Next() {
		rp, err := scanReport(rows)
		if err == nil {
			items = append(items, rp)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type reportInput struct {
	Name      string          `json:"name"`
	Spec      json.RawMessage `json:"spec"`
	ChartType string          `json:"chart_type"`
	Encoding  json.RawMessage `json:"encoding"`
	IsShared  bool            `json:"is_shared"`
}

func (in *reportInput) validate() string {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || len(in.Name) > 120 {
		return "nom requis (120 caractères max)"
	}
	if len(in.Spec) == 0 || len(in.Spec) > 64<<10 {
		return "spécification requise"
	}
	var rq analytics.Request
	if err := json.Unmarshal(in.Spec, &rq); err != nil {
		return "spécification invalide"
	}
	switch in.ChartType {
	case "", "auto":
		in.ChartType = "auto"
	case "stat", "line", "bar", "donut", "pivot", "table":
	default:
		return "type de graphique inconnu"
	}
	if len(in.Encoding) == 0 {
		in.Encoding = json.RawMessage("{}")
	}
	if len(in.Encoding) > 16<<10 {
		return "encodage trop volumineux"
	}
	return ""
}

func (s *Server) createReport(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	var in reportInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	u := authFrom(r)
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO saved_reports (id, name, spec_json, spec_version, chart_type, encoding_json, owner_id, is_shared, is_default, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
		id, in.Name, string(in.Spec), analytics.SchemaVersion, in.ChartType, string(in.Encoding), u.ID, b2i(in.IsShared), now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	rp, _ := scanReport(s.db.QueryRow(`SELECT `+reportCols+` FROM saved_reports WHERE id = ?`, id))
	writeJSON(w, http.StatusCreated, rp)
}

func (s *Server) reportOwnerOK(r *http.Request, id string) (bool, error) {
	var owner sql.NullString
	var def int
	err := s.db.QueryRow(`SELECT owner_id, is_default FROM saved_reports WHERE id = ?`, id).Scan(&owner, &def)
	if err != nil {
		return false, err
	}
	u := authFrom(r)
	var shared int
	s.db.QueryRow(`SELECT is_shared FROM saved_reports WHERE id = ?`, id).Scan(&shared)
	if u.Role == "admin" || (u.Role == "manager" && (shared == 1 || def == 1)) {
		return true, nil
	}
	return owner.Valid && owner.String == u.ID, nil
}

func (s *Server) updateReport(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	ok, err := s.reportOwnerOK(r, id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "rapport introuvable")
		return
	}
	if err != nil || !ok {
		forbid(w)
		return
	}
	var in reportInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	if _, err := s.db.Exec(`UPDATE saved_reports SET name=?, spec_json=?, spec_version=?, chart_type=?, encoding_json=?, is_shared=?, updated_at=? WHERE id=?`,
		in.Name, string(in.Spec), analytics.SchemaVersion, in.ChartType, string(in.Encoding), b2i(in.IsShared), domain.NowISO(), id); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	rp, _ := scanReport(s.db.QueryRow(`SELECT `+reportCols+` FROM saved_reports WHERE id = ?`, id))
	writeJSON(w, http.StatusOK, rp)
}

func (s *Server) deleteReport(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	ok, err := s.reportOwnerOK(r, id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "rapport introuvable")
		return
	}
	if err != nil || !ok {
		forbid(w)
		return
	}
	s.db.Exec(`DELETE FROM saved_reports WHERE id = ?`, id)
	// la vue disparaît aussi de tous les tableaux de bord qui l'affichaient
	rows, err := s.db.Query(`SELECT id, layout_json FROM dashboards`)
	if err == nil {
		type upd struct{ id, layout string }
		var updates []upd
		for rows.Next() {
			var did, layout string
			if rows.Scan(&did, &layout) != nil {
				continue
			}
			var tiles []map[string]any
			if json.Unmarshal([]byte(layout), &tiles) != nil {
				continue
			}
			kept := tiles[:0]
			for _, t := range tiles {
				if t["report_id"] != id {
					kept = append(kept, t)
				}
			}
			if len(kept) != len(tiles) {
				js, _ := json.Marshal(kept)
				updates = append(updates, upd{did, string(js)})
			}
		}
		rows.Close()
		for _, u := range updates {
			s.db.Exec(`UPDATE dashboards SET layout_json=?, updated_at=? WHERE id=?`, u.layout, domain.NowISO(), u.id)
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- tableaux de bord -----------------------------------------------------------

type dashboard struct {
	ID                string          `json:"id"`
	Name              string          `json:"name"`
	OwnerID           *string         `json:"owner_id"`
	IsShared          bool            `json:"is_shared"`
	IsDefault         bool            `json:"is_default"`
	Layout            json.RawMessage `json:"layout"`
	GlobalRange       json.RawMessage `json:"global_range"`
	GlobalWarehouseID *string         `json:"global_warehouse_id"`
	CreatedAt         string          `json:"created_at"`
	UpdatedAt         string          `json:"updated_at"`
}

const dashCols = `id, name, owner_id, is_shared, is_default, layout_json, global_range_json, global_warehouse_id, created_at, updated_at`

func scanDashboard(row interface{ Scan(...any) error }) (dashboard, error) {
	var d dashboard
	var layout, rng string
	var shared, def int
	err := row.Scan(&d.ID, &d.Name, &d.OwnerID, &shared, &def, &layout, &rng, &d.GlobalWarehouseID, &d.CreatedAt, &d.UpdatedAt)
	if layout == "" {
		layout = "[]"
	}
	if rng == "" {
		rng = "{}"
	}
	d.Layout, d.GlobalRange = json.RawMessage(layout), json.RawMessage(rng)
	d.IsShared, d.IsDefault = shared == 1, def == 1
	return d, err
}

func (s *Server) listDashboards(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	u := authFrom(r)
	rows, err := s.db.Query(`SELECT `+dashCols+` FROM dashboards WHERE is_shared = 1 OR owner_id = ? ORDER BY is_default DESC, name`, u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []dashboard{}
	for rows.Next() {
		if d, err := scanDashboard(rows); err == nil {
			items = append(items, d)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type dashboardInput struct {
	Name              string          `json:"name"`
	Layout            json.RawMessage `json:"layout"`
	GlobalRange       json.RawMessage `json:"global_range"`
	GlobalWarehouseID *string         `json:"global_warehouse_id"`
	IsShared          bool            `json:"is_shared"`
}

func (in *dashboardInput) validate() string {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || len(in.Name) > 120 {
		return "nom requis"
	}
	if len(in.Layout) == 0 {
		in.Layout = json.RawMessage("[]")
	}
	var tiles []map[string]any
	if err := json.Unmarshal(in.Layout, &tiles); err != nil || len(tiles) > 40 {
		return "disposition invalide (40 tuiles max)"
	}
	if len(in.GlobalRange) == 0 {
		in.GlobalRange = json.RawMessage(`{"type":"this_month"}`)
	}
	var rg analytics.Range
	if err := json.Unmarshal(in.GlobalRange, &rg); err != nil {
		return "période globale invalide"
	}
	return ""
}

func (s *Server) createDashboard(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	var in dashboardInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	u := authFrom(r)
	id, now := domain.NewID(), domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO dashboards (id, name, owner_id, is_shared, is_default, layout_json, global_range_json, global_warehouse_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?)`,
		id, in.Name, u.ID, b2i(in.IsShared), string(in.Layout), string(in.GlobalRange), in.GlobalWarehouseID, now, now); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	d, _ := scanDashboard(s.db.QueryRow(`SELECT `+dashCols+` FROM dashboards WHERE id = ?`, id))
	writeJSON(w, http.StatusCreated, d)
}

func (s *Server) dashboardOwnerOK(r *http.Request, id string) (bool, error) {
	var owner sql.NullString
	var def, shared int
	err := s.db.QueryRow(`SELECT owner_id, is_default, is_shared FROM dashboards WHERE id = ?`, id).Scan(&owner, &def, &shared)
	if err != nil {
		return false, err
	}
	u := authFrom(r)
	if u.Role == "admin" || u.Role == "manager" && shared == 1 {
		return true, nil
	}
	return owner.Valid && owner.String == u.ID, nil
}

func (s *Server) updateDashboard(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	ok, err := s.dashboardOwnerOK(r, id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "tableau de bord introuvable")
		return
	}
	if err != nil || !ok {
		forbid(w)
		return
	}
	var in dashboardInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	if _, err := s.db.Exec(`UPDATE dashboards SET name=?, layout_json=?, global_range_json=?, global_warehouse_id=?, is_shared=?, updated_at=? WHERE id=?`,
		in.Name, string(in.Layout), string(in.GlobalRange), in.GlobalWarehouseID, b2i(in.IsShared), domain.NowISO(), id); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	d, _ := scanDashboard(s.db.QueryRow(`SELECT `+dashCols+` FROM dashboards WHERE id = ?`, id))
	writeJSON(w, http.StatusOK, d)
}

func (s *Server) deleteDashboard(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	ok, err := s.dashboardOwnerOK(r, id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "tableau de bord introuvable")
		return
	}
	if err != nil || !ok {
		forbid(w)
		return
	}
	var def int
	s.db.QueryRow(`SELECT is_default FROM dashboards WHERE id = ?`, id).Scan(&def)
	if def == 1 {
		writeErr(w, http.StatusConflict, "le tableau de bord par défaut ne peut pas être supprimé")
		return
	}
	s.db.Exec(`DELETE FROM dashboards WHERE id = ?`, id)
	w.WriteHeader(http.StatusNoContent)
}
