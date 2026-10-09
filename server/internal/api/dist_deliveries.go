package api

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

func (s *Server) routesDeliveries(r chi.Router) {
	r.Get("/vehicles", s.listVehicles)
	r.Post("/vehicles", s.createVehicle)
	r.Put("/vehicles/{id}", s.updateVehicle)
	r.Delete("/vehicles/{id}", s.deleteVehicle)

	r.Get("/delivery-routes", s.listRoutes)
	r.Post("/delivery-routes", s.createRoute)
	r.Put("/delivery-routes/{id}", s.updateRoute)
	r.Delete("/delivery-routes/{id}", s.deleteRoute)

	r.Get("/delivery-runs", s.listRuns)
	r.Post("/delivery-runs", s.createRun)
	r.Get("/delivery-runs/{id}", s.getRun)
	r.Put("/delivery-runs/{id}", s.updateRun)
	r.Post("/delivery-runs/{id}/stops", s.addRunStops)
	r.Put("/delivery-runs/{id}/stops/order", s.reorderRunStops)
	r.Patch("/delivery-runs/{id}/stops/{stopId}", s.patchRunStop)
	r.Delete("/delivery-runs/{id}/stops/{stopId}", s.removeRunStop)
	r.Post("/delivery-runs/{id}/stops/{stopId}/result", s.recordRunStop)
	r.Post("/delivery-runs/{id}/start", s.startRun)
	r.Post("/delivery-runs/{id}/close", s.closeRun)
	r.Post("/delivery-runs/{id}/cancel", s.cancelRun)
}

// ---- Vehicles ------------------------------------------------------------------------

type Vehicle struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Plate      string `json:"plate"`
	CapacityKg int64  `json:"capacity_kg"`
	Active     bool   `json:"active"`
	Notes      string `json:"notes"`
	CreatedAt  string `json:"created_at"`
	UpdatedAt  string `json:"updated_at"`
}

func (s *Server) listVehicles(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.view") {
		return
	}
	rows, err := s.db.Query(`SELECT id, name, plate, capacity_kg, active, notes, created_at, updated_at
		FROM vehicles ORDER BY active DESC, name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Vehicle{}
	for rows.Next() {
		var v Vehicle
		var a int
		rows.Scan(&v.ID, &v.Name, &v.Plate, &v.CapacityKg, &a, &v.Notes, &v.CreatedAt, &v.UpdatedAt)
		v.Active = a == 1
		items = append(items, v)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type vehicleInput struct {
	Name       string `json:"name"`
	Plate      string `json:"plate"`
	CapacityKg int64  `json:"capacity_kg"`
	Active     *bool  `json:"active"`
	Notes      string `json:"notes"`
}

func (s *Server) saveVehicle(w http.ResponseWriter, r *http.Request, id string) {
	if !s.need(w, r, "deliveries.manage") {
		return
	}
	var in vehicleInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeFieldErr(w, http.StatusBadRequest, "name", "le nom du véhicule est obligatoire")
		return
	}
	active := in.Active == nil || *in.Active
	now := domain.NowISO()
	status := http.StatusOK
	if id == "" {
		id, status = domain.NewID(), http.StatusCreated
		if _, err := s.db.Exec(`INSERT INTO vehicles (id, name, plate, capacity_kg, active, notes, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, id, strings.TrimSpace(in.Name), strings.TrimSpace(in.Plate),
			in.CapacityKg, b2i(active), in.Notes, now, now); err != nil {
			writeDomainErr(w, err)
			return
		}
	} else {
		res, err := s.db.Exec(`UPDATE vehicles SET name=?, plate=?, capacity_kg=?, active=?, notes=?, updated_at=? WHERE id=?`,
			strings.TrimSpace(in.Name), strings.TrimSpace(in.Plate), in.CapacityKg, b2i(active), in.Notes, now, id)
		if err != nil {
			writeDomainErr(w, err)
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeErr(w, http.StatusNotFound, "véhicule introuvable")
			return
		}
	}
	var v Vehicle
	var a int
	s.db.QueryRow(`SELECT id, name, plate, capacity_kg, active, notes, created_at, updated_at FROM vehicles WHERE id=?`, id).
		Scan(&v.ID, &v.Name, &v.Plate, &v.CapacityKg, &a, &v.Notes, &v.CreatedAt, &v.UpdatedAt)
	v.Active = a == 1
	writeJSON(w, status, v)
}

func (s *Server) createVehicle(w http.ResponseWriter, r *http.Request) { s.saveVehicle(w, r, "") }
func (s *Server) updateVehicle(w http.ResponseWriter, r *http.Request) {
	s.saveVehicle(w, r, chi.URLParam(r, "id"))
}
func (s *Server) deleteVehicle(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.manage") {
		return
	}
	s.deleteRow(w, r, "vehicles", "véhicule introuvable", "")
}

// ---- Routes (tournées types) -----------------------------------------------------------

type DeliveryRoute struct {
	ID                  string   `json:"id"`
	Name                string   `json:"name"`
	Wilayas             []string `json:"wilayas"`
	Communes            []string `json:"communes"`
	Weekdays            []int    `json:"weekdays"`
	DefaultDriverUserID *string  `json:"default_driver_user_id"`
	DefaultDriverName   string   `json:"default_driver_name"`
	DefaultVehicleID    *string  `json:"default_vehicle_id"`
	Active              bool     `json:"active"`
	Notes               string   `json:"notes"`
	PartnersCount       int      `json:"partners_count"`
	ReadyOrdersCount    int      `json:"ready_orders_count"`
	CreatedAt           string   `json:"created_at"`
	UpdatedAt           string   `json:"updated_at"`
}

const routeSelect = `SELECT r.id, r.name, r.wilayas_json, r.communes_json, r.weekdays_json, r.default_driver_user_id,
	r.default_driver_name, r.default_vehicle_id, r.active, r.notes, r.created_at, r.updated_at,
	(SELECT COUNT(*) FROM partners p WHERE p.route_id = r.id AND p.active = 1),
	(SELECT COUNT(*) FROM customer_orders o WHERE o.route_id = r.id AND o.status = 'ready')
FROM delivery_routes r`

func scanRoute(row interface{ Scan(...any) error }) (DeliveryRoute, error) {
	var d DeliveryRoute
	var wj, cj, dj string
	var a int
	err := row.Scan(&d.ID, &d.Name, &wj, &cj, &dj, &d.DefaultDriverUserID, &d.DefaultDriverName,
		&d.DefaultVehicleID, &a, &d.Notes, &d.CreatedAt, &d.UpdatedAt, &d.PartnersCount, &d.ReadyOrdersCount)
	d.Active = a == 1
	d.Wilayas, d.Communes, d.Weekdays = []string{}, []string{}, []int{}
	json.Unmarshal([]byte(wj), &d.Wilayas)
	json.Unmarshal([]byte(cj), &d.Communes)
	json.Unmarshal([]byte(dj), &d.Weekdays)
	return d, err
}

func (s *Server) listRoutes(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.view", "orders.view", "crm.view") {
		return
	}
	rows, err := s.db.Query(routeSelect + ` ORDER BY r.active DESC, r.name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []DeliveryRoute{}
	for rows.Next() {
		d, err := scanRoute(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type routeInput struct {
	Name                string   `json:"name"`
	Wilayas             []string `json:"wilayas"`
	Communes            []string `json:"communes"`
	Weekdays            []int    `json:"weekdays"`
	DefaultDriverUserID *string  `json:"default_driver_user_id"`
	DefaultDriverName   string   `json:"default_driver_name"`
	DefaultVehicleID    *string  `json:"default_vehicle_id"`
	Active              *bool    `json:"active"`
	Notes               string   `json:"notes"`
}

func (s *Server) saveRoute(w http.ResponseWriter, r *http.Request, id string) {
	if !s.need(w, r, "deliveries.manage") {
		return
	}
	var in routeInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeFieldErr(w, http.StatusBadRequest, "name", "le nom de la tournée est obligatoire")
		return
	}
	for _, d := range in.Weekdays {
		if d < 1 || d > 7 {
			writeFieldErr(w, http.StatusBadRequest, "weekdays", "jours de 1 (lundi) à 7 (dimanche)")
			return
		}
	}
	if in.Wilayas == nil {
		in.Wilayas = []string{}
	}
	if in.Communes == nil {
		in.Communes = []string{}
	}
	if in.Weekdays == nil {
		in.Weekdays = []int{}
	}
	wj, _ := json.Marshal(in.Wilayas)
	cj, _ := json.Marshal(in.Communes)
	dj, _ := json.Marshal(in.Weekdays)
	active := in.Active == nil || *in.Active
	now := domain.NowISO()
	status := http.StatusOK
	if id == "" {
		id, status = domain.NewID(), http.StatusCreated
		if _, err := s.db.Exec(`INSERT INTO delivery_routes (id, name, wilayas_json, communes_json, weekdays_json,
				default_driver_user_id, default_driver_name, default_vehicle_id, active, notes, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, id, strings.TrimSpace(in.Name), string(wj), string(cj),
			string(dj), emptyNil(in.DefaultDriverUserID), in.DefaultDriverName, emptyNil(in.DefaultVehicleID),
			b2i(active), in.Notes, now, now); err != nil {
			writeDomainErr(w, err)
			return
		}
	} else {
		res, err := s.db.Exec(`UPDATE delivery_routes SET name=?, wilayas_json=?, communes_json=?, weekdays_json=?,
				default_driver_user_id=?, default_driver_name=?, default_vehicle_id=?, active=?, notes=?, updated_at=?
			WHERE id=?`, strings.TrimSpace(in.Name), string(wj), string(cj), string(dj),
			emptyNil(in.DefaultDriverUserID), in.DefaultDriverName, emptyNil(in.DefaultVehicleID), b2i(active),
			in.Notes, now, id)
		if err != nil {
			writeDomainErr(w, err)
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeErr(w, http.StatusNotFound, "tournée introuvable")
			return
		}
	}
	d, err := scanRoute(s.db.QueryRow(routeSelect+` WHERE r.id = ?`, id))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, d)
}

func (s *Server) createRoute(w http.ResponseWriter, r *http.Request) { s.saveRoute(w, r, "") }
func (s *Server) updateRoute(w http.ResponseWriter, r *http.Request) {
	s.saveRoute(w, r, chi.URLParam(r, "id"))
}

func (s *Server) deleteRoute(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	var n int
	s.db.QueryRow(`SELECT (SELECT COUNT(*) FROM partners WHERE route_id = ?) + (SELECT COUNT(*) FROM delivery_runs WHERE route_id = ?)
		+ (SELECT COUNT(*) FROM customer_orders WHERE route_id = ?)`, id, id, id).Scan(&n)
	if n > 0 {
		writeErr(w, http.StatusConflict, "cette tournée est utilisée (clients, commandes ou tournées passées) : désactivez-la plutôt")
		return
	}
	s.deleteRow(w, r, "delivery_routes", "tournée introuvable", "")
}

// ---- Runs ---------------------------------------------------------------------------------

type DeliveryRun struct {
	ID             string    `json:"id"`
	RunDate        string    `json:"run_date"`
	RouteID        *string   `json:"route_id"`
	RouteName      string    `json:"route_name"`
	DriverUserID   *string   `json:"driver_user_id"`
	DriverName     string    `json:"driver_name"`
	VehicleID      *string   `json:"vehicle_id"`
	VehicleName    string    `json:"vehicle_name"`
	Status         string    `json:"status"`
	DepartedAt     *string   `json:"departed_at"`
	ClosedAt       *string   `json:"closed_at"`
	CashExpected   int64     `json:"cash_expected"`
	CashCollected  int64     `json:"cash_collected"`
	CashDifference int64     `json:"cash_difference"`
	CountedCash    *int64    `json:"counted_cash"`
	Notes          string    `json:"notes"`
	StopsCount     int       `json:"stops_count"`
	PendingCount   int       `json:"pending_count"`
	CODExpected    int64     `json:"cod_expected_total"` // live sum of the stops
	CODCollected   int64     `json:"cod_collected_total"`
	CreatedAt      string    `json:"created_at"`
	UpdatedAt      string    `json:"updated_at"`
	Stops          []RunStop `json:"stops,omitempty"`
}

type RunStop struct {
	ID              string   `json:"id"`
	OrderID         string   `json:"order_id"`
	OrderNumber     string   `json:"order_number"`
	OrderStatus     string   `json:"order_status"`
	PartnerID       string   `json:"partner_id"`
	PartnerName     string   `json:"partner_name"`
	PartnerPhone    string   `json:"partner_phone"`
	DeliveryAddress string   `json:"delivery_address"`
	Wilaya          string   `json:"wilaya"`
	Commune         string   `json:"commune"`
	Latitude        *float64 `json:"latitude"`
	Longitude       *float64 `json:"longitude"`
	TotalTTC        int64    `json:"total_ttc"`
	DeliveryNoteID  *string  `json:"delivery_note_id"`
	DeliveryNoteNo  *string  `json:"delivery_note_number"`
	Sequence        int64    `json:"sequence"`
	Status          string   `json:"status"`
	FailureReason   string   `json:"failure_reason"`
	CODExpected     int64    `json:"cod_expected"`
	CODCollected    int64    `json:"cod_collected"`
	PaymentMethod   string   `json:"payment_method"`
	PaymentID       *string  `json:"payment_id"`
	PaymentNumber   *string  `json:"payment_number"`
	ReceiverName    string   `json:"receiver_name"`
	DeliveredAt     *string  `json:"delivered_at"`
	Note            string   `json:"note"`
}

const runSelect = `SELECT r.id, r.run_date, r.route_id, COALESCE(rt.name,''), r.driver_user_id,
	CASE WHEN r.driver_name <> '' THEN r.driver_name ELSE COALESCE(NULLIF(u.full_name,''), u.username, '') END,
	r.vehicle_id, COALESCE(v.name,''), r.status, r.departed_at, r.closed_at, r.cash_expected, r.cash_collected,
	r.cash_difference, r.counted_cash, r.notes, r.created_at, r.updated_at,
	(SELECT COUNT(*) FROM run_stops s WHERE s.run_id = r.id),
	(SELECT COUNT(*) FROM run_stops s WHERE s.run_id = r.id AND s.status = 'pending'),
	(SELECT COALESCE(SUM(s.cod_expected),0) FROM run_stops s WHERE s.run_id = r.id),
	(SELECT COALESCE(SUM(s.cod_collected),0) FROM run_stops s WHERE s.run_id = r.id)
FROM delivery_runs r LEFT JOIN delivery_routes rt ON rt.id = r.route_id
LEFT JOIN users u ON u.id = r.driver_user_id LEFT JOIN vehicles v ON v.id = r.vehicle_id`

func scanRun(row interface{ Scan(...any) error }) (DeliveryRun, error) {
	var d DeliveryRun
	err := row.Scan(&d.ID, &d.RunDate, &d.RouteID, &d.RouteName, &d.DriverUserID, &d.DriverName, &d.VehicleID,
		&d.VehicleName, &d.Status, &d.DepartedAt, &d.ClosedAt, &d.CashExpected, &d.CashCollected, &d.CashDifference,
		&d.CountedCash, &d.Notes, &d.CreatedAt, &d.UpdatedAt, &d.StopsCount, &d.PendingCount, &d.CODExpected,
		&d.CODCollected)
	return d, err
}

func (s *Server) listRuns(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.view") {
		return
	}
	qp := r.URL.Query()
	where, args := " WHERE 1=1", []any{}
	if v := qp.Get("from"); v != "" {
		where += " AND r.run_date >= ?"
		args = append(args, v)
	}
	if v := qp.Get("to"); v != "" {
		where += " AND r.run_date <= ?"
		args = append(args, v)
	}
	if st := splitCSV(qp.Get("status")); len(st) > 0 {
		where += " AND r.status IN (" + placeholders(len(st)) + ")"
		for _, v := range st {
			args = append(args, v)
		}
	}
	if v := qp.Get("route_id"); v != "" {
		where += " AND r.route_id = ?"
		args = append(args, v)
	}
	if v := qp.Get("driver_user_id"); v != "" {
		where += " AND r.driver_user_id = ?"
		args = append(args, v)
	}
	rows, err := s.db.Query(runSelect+where+` ORDER BY r.run_date DESC, r.created_at DESC LIMIT 500`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []DeliveryRun{}
	for rows.Next() {
		d, err := scanRun(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) loadRun(id string) (DeliveryRun, error) {
	d, err := scanRun(s.db.QueryRow(runSelect+` WHERE r.id = ?`, id))
	if err != nil {
		return d, err
	}
	rows, err := s.db.Query(`SELECT s.id, s.order_id, o.number, o.status, o.partner_id, p.name, COALESCE(p.phone,''),
			o.delivery_address, o.wilaya, o.commune, p.latitude, p.longitude, o.total_ttc, o.delivery_note_id, bl.number,
			s.sequence, s.status, s.failure_reason, s.cod_expected, s.cod_collected, s.payment_method, s.payment_id,
			pay.number, s.receiver_name, s.delivered_at, s.note
		FROM run_stops s JOIN customer_orders o ON o.id = s.order_id JOIN partners p ON p.id = o.partner_id
		LEFT JOIN documents bl ON bl.id = o.delivery_note_id LEFT JOIN documents pay ON pay.id = s.payment_id
		WHERE s.run_id = ? ORDER BY s.sequence, s.created_at`, id)
	if err != nil {
		return d, err
	}
	defer rows.Close()
	d.Stops = []RunStop{}
	for rows.Next() {
		var st RunStop
		if err := rows.Scan(&st.ID, &st.OrderID, &st.OrderNumber, &st.OrderStatus, &st.PartnerID, &st.PartnerName,
			&st.PartnerPhone, &st.DeliveryAddress, &st.Wilaya, &st.Commune, &st.Latitude, &st.Longitude,
			&st.TotalTTC, &st.DeliveryNoteID, &st.DeliveryNoteNo, &st.Sequence, &st.Status, &st.FailureReason,
			&st.CODExpected, &st.CODCollected, &st.PaymentMethod, &st.PaymentID, &st.PaymentNumber,
			&st.ReceiverName, &st.DeliveredAt, &st.Note); err != nil {
			return d, err
		}
		d.Stops = append(d.Stops, st)
	}
	return d, rows.Err()
}

func (s *Server) respondRun(w http.ResponseWriter, id string, status int, extra map[string]any) {
	d, err := s.loadRun(id)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "tournée introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if len(extra) == 0 {
		writeJSON(w, status, d)
		return
	}
	b, _ := json.Marshal(d)
	m := map[string]any{}
	json.Unmarshal(b, &m)
	for k, v := range extra {
		m[k] = v
	}
	writeJSON(w, status, m)
}

func (s *Server) getRun(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.view") {
		return
	}
	s.respondRun(w, chi.URLParam(r, "id"), http.StatusOK, nil)
}

type runInput struct {
	RunDate      string   `json:"run_date"`
	RouteID      *string  `json:"route_id"`
	DriverUserID *string  `json:"driver_user_id"`
	DriverName   string   `json:"driver_name"`
	VehicleID    *string  `json:"vehicle_id"`
	Notes        string   `json:"notes"`
	OrderIDs     []string `json:"order_ids"`
}

func (s *Server) createRun(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.manage") {
		return
	}
	var in runInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.RunDate == "" {
		in.RunDate = today()
	}
	if !validDate(&in.RunDate) {
		writeFieldErr(w, http.StatusBadRequest, "run_date", "date au format AAAA-MM-JJ")
		return
	}
	// Route defaults: driver and vehicle.
	if in.RouteID != nil && *in.RouteID != "" {
		var drv, veh sql.NullString
		var drvName string
		if err := s.db.QueryRow(`SELECT default_driver_user_id, default_driver_name, default_vehicle_id
			FROM delivery_routes WHERE id = ?`, *in.RouteID).Scan(&drv, &drvName, &veh); err != nil {
			writeFieldErr(w, http.StatusBadRequest, "route_id", "tournée introuvable")
			return
		}
		if in.DriverUserID == nil && drv.Valid {
			in.DriverUserID = &drv.String
		}
		if in.DriverName == "" {
			in.DriverName = drvName
		}
		if in.VehicleID == nil && veh.Valid {
			in.VehicleID = &veh.String
		}
	}
	id, now := domain.NewID(), domain.NowISO()
	if !s.inTx(w, func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO delivery_runs (id, run_date, route_id, driver_user_id, driver_name, vehicle_id,
				status, notes, created_by, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, 'planned', ?, ?, ?, ?)`, id, in.RunDate, emptyNil(in.RouteID),
			emptyNil(in.DriverUserID), strings.TrimSpace(in.DriverName), emptyNil(in.VehicleID), in.Notes,
			nullIfEmpty(uidOf(r)), now, now); err != nil {
			return err
		}
		if len(in.OrderIDs) > 0 {
			return domain.AddRunStops(tx, id, in.OrderIDs, uidOf(r))
		}
		return nil
	}) {
		return
	}
	s.audit(r, "delivery_run.create", "delivery_run", id, "tournée du "+in.RunDate)
	s.respondRun(w, id, http.StatusCreated, nil)
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (s *Server) updateRun(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	var in runInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.RunDate == "" || !validDate(&in.RunDate) {
		writeFieldErr(w, http.StatusBadRequest, "run_date", "date au format AAAA-MM-JJ")
		return
	}
	res, err := s.db.Exec(`UPDATE delivery_runs SET run_date=?, route_id=?, driver_user_id=?, driver_name=?, vehicle_id=?,
		notes=?, updated_at=? WHERE id=? AND status IN ('planned','out')`, in.RunDate, emptyNil(in.RouteID),
		emptyNil(in.DriverUserID), strings.TrimSpace(in.DriverName), emptyNil(in.VehicleID), in.Notes, domain.NowISO(), id)
	if err != nil {
		writeDomainErr(w, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusConflict, "tournée introuvable ou clôturée")
		return
	}
	s.respondRun(w, id, http.StatusOK, nil)
}

func (s *Server) runStep(w http.ResponseWriter, r *http.Request, fn func(tx *sql.Tx, id, uid string) error) {
	if !s.need(w, r, "deliveries.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.inTx(w, func(tx *sql.Tx) error { return fn(tx, id, uidOf(r)) }) {
		return
	}
	s.respondRun(w, id, http.StatusOK, nil)
}

func (s *Server) addRunStops(w http.ResponseWriter, r *http.Request) {
	var in struct {
		OrderIDs []string `json:"order_ids"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(in.OrderIDs) == 0 {
		writeFieldErr(w, http.StatusBadRequest, "order_ids", "aucune commande à ajouter")
		return
	}
	s.runStep(w, r, func(tx *sql.Tx, id, uid string) error { return domain.AddRunStops(tx, id, in.OrderIDs, uid) })
}

func (s *Server) removeRunStop(w http.ResponseWriter, r *http.Request) {
	s.runStep(w, r, func(tx *sql.Tx, id, uid string) error {
		return domain.RemoveRunStop(tx, id, chi.URLParam(r, "stopId"), uid)
	})
}

func (s *Server) reorderRunStops(w http.ResponseWriter, r *http.Request) {
	var in struct {
		StopIDs []string `json:"stop_ids"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.runStep(w, r, func(tx *sql.Tx, id, uid string) error {
		for i, sid := range in.StopIDs {
			res, err := tx.Exec(`UPDATE run_stops SET sequence=?, updated_at=? WHERE id=? AND run_id=?`,
				i+1, domain.NowISO(), sid, id)
			if err != nil {
				return err
			}
			if n, _ := res.RowsAffected(); n == 0 {
				return &domain.NotFoundError{Msg: "arrêt introuvable : " + sid}
			}
		}
		return nil
	})
}

func (s *Server) patchRunStop(w http.ResponseWriter, r *http.Request) {
	var in struct {
		CODExpected *int64  `json:"cod_expected"`
		Note        *string `json:"note"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.runStep(w, r, func(tx *sql.Tx, id, uid string) error {
		sid := chi.URLParam(r, "stopId")
		var st string
		if err := tx.QueryRow(`SELECT status FROM run_stops WHERE id=? AND run_id=?`, sid, id).Scan(&st); err != nil {
			return &domain.NotFoundError{Msg: "arrêt introuvable"}
		}
		if in.CODExpected != nil {
			if *in.CODExpected < 0 {
				return &domain.PostError{Msg: "montant attendu négatif"}
			}
			if _, err := tx.Exec(`UPDATE run_stops SET cod_expected=? WHERE id=?`, *in.CODExpected, sid); err != nil {
				return err
			}
		}
		if in.Note != nil {
			if _, err := tx.Exec(`UPDATE run_stops SET note=? WHERE id=?`, *in.Note, sid); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Server) recordRunStop(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Status        string `json:"status"`
		FailureReason string `json:"failure_reason"`
		CODCollected  int64  `json:"cod_collected"`
		PaymentMethod string `json:"payment_method"`
		ReceiverName  string `json:"receiver_name"`
		Note          string `json:"note"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.runStep(w, r, func(tx *sql.Tx, id, uid string) error {
		return domain.RecordStop(tx, id, chi.URLParam(r, "stopId"), uid, domain.StopResult{Status: in.Status,
			FailureReason: in.FailureReason, CODCollected: in.CODCollected, Method: in.PaymentMethod,
			Receiver: in.ReceiverName, Note: in.Note})
	})
}

func (s *Server) startRun(w http.ResponseWriter, r *http.Request) {
	s.runStep(w, r, domain.StartRun)
}

func (s *Server) closeRun(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "deliveries.manage") {
		return
	}
	id := chi.URLParam(r, "id")
	var in struct {
		CountedCash *int64 `json:"counted_cash"`
		Notes       string `json:"notes"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var rec *domain.RunReconciliation
	if !s.inTx(w, func(tx *sql.Tx) error {
		var err error
		rec, err = domain.CloseRun(tx, id, uidOf(r), in.CountedCash, in.Notes)
		return err
	}) {
		return
	}
	s.respondRun(w, id, http.StatusOK, map[string]any{"reconciliation": rec})
}

func (s *Server) cancelRun(w http.ResponseWriter, r *http.Request) {
	s.runStep(w, r, func(tx *sql.Tx, id, uid string) error {
		var st string
		if err := tx.QueryRow(`SELECT status FROM delivery_runs WHERE id=?`, id).Scan(&st); err != nil {
			return &domain.NotFoundError{Msg: "tournée introuvable"}
		}
		if st != "planned" {
			return &domain.PostError{Msg: "seule une tournée planifiée (pas encore partie) peut être annulée"}
		}
		if _, err := tx.Exec(`DELETE FROM run_stops WHERE run_id=?`, id); err != nil {
			return err
		}
		_, err := tx.Exec(`UPDATE delivery_runs SET status='cancelled', updated_at=? WHERE id=?`, domain.NowISO(), id)
		return err
	})
}
