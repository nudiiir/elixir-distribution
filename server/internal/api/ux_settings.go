package api

import (
	"archive/zip"
	"bytes"
	"database/sql"
	"encoding/csv"
	"fmt"
	"net/http"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// Version of the server binary — bumped with each release (same number as
// the app's kAppVersion). Can be overridden at build time with
// -ldflags "-X elixir/server/internal/api.Version=x.y.z".
var Version = "0.2.2"

// routesSettingsUX registers the settings routes of the settings work.
func (s *Server) routesSettingsUX(r chi.Router) {
	r.Get("/system/info", s.systemInfo)

	// Company logo
	r.Get("/settings/logo", s.getLogo)
	r.Post("/settings/logo", s.putLogo)
	r.Delete("/settings/logo", s.deleteLogo)

	// Depots: rename / address, default, delete (create + list in server.go)
	r.Put("/warehouses/{id}", s.updateWarehouse)
	r.Post("/warehouses/{id}/default", s.setDefaultWarehouse)
	r.Delete("/warehouses/{id}", s.deleteWarehouse)

	// Guided restore (applied at the next server start)
	r.Post("/backups/{name}/restore", s.scheduleRestore)
	r.Delete("/backups/restore", s.cancelRestore)

	// Maintenance
	r.Get("/maintenance/export", s.exportAllData)
	r.Post("/maintenance/reset", s.resetData)
}

func (s *Server) systemInfo(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"version": Version}
	if s.isAdmin(r) {
		out["data_dir"] = filepath.Dir(s.dbPath)
	}
	writeJSON(w, http.StatusOK, out)
}

// ---------------------------------------------------------------------------
// « Exporter toutes les données » — a ZIP of semicolon CSVs (Excel-FR).

type exportSpec struct {
	file  string
	query string
}

var exportSpecs = []exportSpec{
	{"produits.csv", `SELECT p.*, c.name AS categorie FROM products p
		LEFT JOIN product_categories c ON c.id = p.category_id ORDER BY p.name`},
	{"categories.csv", `SELECT * FROM product_categories ORDER BY name`},
	{"clients_fournisseurs.csv", `SELECT * FROM partners ORDER BY name`},
	{"documents.csv", `SELECT d.*, pa.name AS client_fournisseur, w.name AS depot
		FROM documents d LEFT JOIN partners pa ON pa.id = d.partner_id
		LEFT JOIN warehouses w ON w.id = d.warehouse_id ORDER BY d.doc_date, d.created_at`},
	{"lignes_documents.csv", `SELECT d.number AS document_numero, d.doc_type AS document_type,
		pr.name AS produit, l.* FROM document_lines l JOIN documents d ON d.id = l.document_id
		LEFT JOIN products pr ON pr.id = l.product_id ORDER BY d.doc_date, d.created_at, l.position`},
	{"stock.csv", `SELECT pr.name AS produit, pr.barcode AS code_barres, w.name AS depot,
		s.qty_milli, s.avg_cost, s.updated_at FROM stock_levels s
		JOIN products pr ON pr.id = s.product_id JOIN warehouses w ON w.id = s.warehouse_id
		ORDER BY pr.name, w.name`},
	{"mouvements_stock.csv", `SELECT sl.created_at, d.number AS document_numero, d.doc_type AS document_type,
		pr.name AS produit, w.name AS depot, sl.qty_delta_milli, sl.unit_cost, sl.* FROM stock_ledger sl
		LEFT JOIN documents d ON d.id = sl.document_id LEFT JOIN products pr ON pr.id = sl.product_id
		LEFT JOIN warehouses w ON w.id = sl.warehouse_id ORDER BY sl.created_at`},
	{"paiements.csv", `SELECT d.number AS document_numero, d.doc_type AS document_type, d.doc_date,
		pa.name AS client_fournisseur, dp.method, dp.amount, dp.created_at FROM document_payments dp
		JOIN documents d ON d.id = dp.document_id LEFT JOIN partners pa ON pa.id = d.partner_id
		UNION ALL
		SELECT d.number, d.doc_type, d.doc_date, pa.name, d.payment_method, d.amount, d.created_at
		FROM documents d LEFT JOIN partners pa ON pa.id = d.partner_id
		WHERE d.doc_type IN ('PAYMENT_IN','PAYMENT_OUT') AND d.status = 'posted'
		ORDER BY 3, 7`},
	{"comptes_clients_fournisseurs.csv", `SELECT pa.name AS client_fournisseur, d.number AS document_numero,
		pl.* FROM partner_ledger pl JOIN partners pa ON pa.id = pl.partner_id
		LEFT JOIN documents d ON d.id = pl.document_id ORDER BY pl.created_at`},
	{"depots.csv", `SELECT * FROM warehouses ORDER BY name`},
}

const exportReadme = "Export complet Elixir Gestion\r\n" +
	"=============================\r\n\r\n" +
	"Fichiers CSV séparés par des points-virgules (ouvrir avec Excel).\r\n" +
	"Unités : les montants sont en CENTIMES (12345 = 123,45 DA) ;\r\n" +
	"les quantités en MILLIÈMES (1500 = 1,5) ; les taux en centièmes de % (1900 = 19 %).\r\n" +
	"Dates au format ISO (UTC).\r\n"

func csvCell(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case []byte:
		// TEXT columns may come back as bytes; real binary is left out.
		if bytes.IndexByte(x, 0) >= 0 {
			return "<binaire>"
		}
		return string(x)
	case string:
		return x
	case int64:
		return strconv.FormatInt(x, 10)
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case bool:
		if x {
			return "1"
		}
		return "0"
	case time.Time:
		return x.UTC().Format(time.RFC3339)
	}
	return fmt.Sprint(v)
}

// writeQueryCSV runs q and writes the result as a CSV entry of zw.
func writeQueryCSV(db *sql.DB, zw *zip.Writer, name, q string) (int, error) {
	rows, err := db.Query(q)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return 0, err
	}
	f, err := zw.Create(name)
	if err != nil {
		return 0, err
	}
	f.Write([]byte{0xEF, 0xBB, 0xBF}) // BOM: Excel reads UTF-8 accents correctly
	cw := csv.NewWriter(f)
	cw.Comma = ';'
	cw.UseCRLF = true
	cw.Write(cols)
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	n := 0
	for rows.Next() {
		if err := rows.Scan(ptrs...); err != nil {
			return n, err
		}
		rec := make([]string, len(cols))
		for i, v := range vals {
			rec[i] = csvCell(v)
		}
		cw.Write(rec)
		n++
	}
	cw.Flush()
	return n, rows.Err()
}

// buildExportZip writes every export into one ZIP archive.
func buildExportZip(db *sql.DB) ([]byte, map[string]int, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	counts := map[string]int{}
	for _, sp := range exportSpecs {
		n, err := writeQueryCSV(db, zw, sp.file, sp.query)
		if err != nil {
			return nil, nil, fmt.Errorf("%s : %w", sp.file, err)
		}
		counts[sp.file] = n
	}
	if f, err := zw.Create("LISEZMOI.txt"); err == nil {
		f.Write([]byte(exportReadme))
	}
	if err := zw.Close(); err != nil {
		return nil, nil, err
	}
	return buf.Bytes(), counts, nil
}

func (s *Server) exportAllData(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	data, _, err := buildExportZip(s.db)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "export impossible : "+err.Error())
		return
	}
	name := "elixir-export-" + time.Now().Format("20060102-150405") + ".zip"
	s.audit(r, "maintenance.export", "maintenance", name, "export de toutes les données")
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

// ---------------------------------------------------------------------------
// « Réinitialiser les données ».

const (
	resetTransactions = "transactions" // sales, purchases, movements
	resetAll          = "all"          // everything except users and settings
)

// Tables a reset never touches (configuration, people, history of who did what).
var resetKeep = map[string]bool{
	"settings": true, "users": true, "schema_migrations": true, "audit_log": true,
	"warehouses": true, "templates": true, "saved_reports": true, "dashboards": true,
	"company_logo": true, "customer_groups": true,
}

func resetKept(t string) bool {
	return resetKeep[t] || strings.HasPrefix(t, "sqlite_") || strings.Contains(t, "role") ||
		strings.HasPrefix(t, "user")
}

var resetTxTables = []string{
	"documents", "document_lines", "document_payments", "document_attachments",
	"stock_ledger", "stock_levels", "partner_ledger", "caisse_sessions",
	"gift_cards", "gift_card_uses", "installment_plans", "installment_dues",
	"lots", "product_units", "repairs", "sequences",
	// Distribution (0016/0017): orders and their deliveries are transactions.
	"customer_orders", "customer_order_lines", "customer_order_events", "customer_order_picks",
	"delivery_runs", "run_stops", "message_log",
}

var resetMasterTables = []string{
	"products", "product_barcodes", "product_images", "product_categories",
	"packagings", "supplier_prices", "partners",
}

type fkRef struct {
	table, column, target string
	notNull               bool
}

// resetPlan returns the tables to empty and the nullable references (in
// kept tables) to clear, for a scope. Tables added later by other features
// are handled by following their foreign keys: a table that MUST point at an
// emptied table is emptied too; an optional pointer is set to NULL.
func resetPlan(tx *sql.Tx, scope string) (del []string, nullify []fkRef, err error) {
	rows, err := tx.Query(`SELECT name FROM sqlite_master WHERE type = 'table'`)
	if err != nil {
		return nil, nil, err
	}
	var tables []string
	for rows.Next() {
		var n string
		rows.Scan(&n)
		tables = append(tables, n)
	}
	rows.Close()
	exists := map[string]bool{}
	for _, t := range tables {
		exists[t] = true
	}
	set := map[string]bool{}
	add := func(t string) {
		if exists[t] && !resetKept(t) {
			set[t] = true
		}
	}
	for _, t := range resetTxTables {
		add(t)
	}
	for _, t := range tables {
		if strings.HasPrefix(t, "document_") || strings.HasPrefix(t, "stock_") ||
			strings.HasPrefix(t, "caisse_") || strings.HasPrefix(t, "loyalty_") {
			add(t)
		}
	}
	if scope == resetAll {
		for _, t := range resetMasterTables {
			add(t)
		}
		for _, t := range tables {
			if strings.HasPrefix(t, "product") || strings.HasPrefix(t, "partner") || strings.HasPrefix(t, "gift_") {
				add(t)
			}
		}
	}
	// Foreign keys of every table.
	refs := map[string][]fkRef{}
	for _, t := range tables {
		if strings.HasPrefix(t, "sqlite_") {
			continue
		}
		notNull := map[string]bool{}
		ci, err := tx.Query(`SELECT name, "notnull" FROM pragma_table_info(?)`, t)
		if err != nil {
			return nil, nil, err
		}
		for ci.Next() {
			var c string
			var nn int
			ci.Scan(&c, &nn)
			notNull[c] = nn == 1
		}
		ci.Close()
		fk, err := tx.Query(`SELECT "table", "from" FROM pragma_foreign_key_list(?)`, t)
		if err != nil {
			return nil, nil, err
		}
		for fk.Next() {
			var target, from string
			fk.Scan(&target, &from)
			refs[t] = append(refs[t], fkRef{table: t, column: from, target: target, notNull: notNull[from]})
		}
		fk.Close()
	}
	// Closure: a mandatory pointer into an emptied table empties the table.
	for changed := true; changed; {
		changed = false
		for _, t := range tables {
			if set[t] || resetKept(t) {
				continue
			}
			for _, ref := range refs[t] {
				if set[ref.target] && ref.notNull {
					set[t] = true
					changed = true
					break
				}
			}
		}
	}
	for _, t := range tables {
		if set[t] {
			continue
		}
		for _, ref := range refs[t] {
			if set[ref.target] {
				if ref.notNull {
					return nil, nil, fmt.Errorf("la table %s doit garder %s.%s : réinitialisation impossible",
						t, t, ref.column)
				}
				nullify = append(nullify, ref)
			}
		}
	}
	for t := range set {
		del = append(del, t)
	}
	sort.Strings(del)
	return del, nullify, nil
}

// ResetData empties the tables of a scope inside one transaction and returns
// the number of rows removed per table.
func ResetData(db *sql.DB, scope string) (map[string]int64, error) {
	if scope != resetTransactions && scope != resetAll {
		return nil, fmt.Errorf("portée inconnue : %q", scope)
	}
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`PRAGMA defer_foreign_keys = ON`); err != nil {
		return nil, err
	}
	del, nullify, err := resetPlan(tx, scope)
	if err != nil {
		return nil, err
	}
	for _, ref := range nullify {
		if _, err := tx.Exec(fmt.Sprintf(`UPDATE "%s" SET "%s" = NULL WHERE "%s" IS NOT NULL`,
			ref.table, ref.column, ref.column)); err != nil {
			return nil, err
		}
	}
	counts := map[string]int64{}
	for _, t := range del {
		res, err := tx.Exec(fmt.Sprintf(`DELETE FROM "%s"`, t))
		if err != nil {
			return nil, fmt.Errorf("%s : %w", t, err)
		}
		n, _ := res.RowsAffected()
		counts[t] = n
	}
	if scope == resetAll {
		tx.Exec(`UPDATE settings SET value = '' WHERE key IN ('pos_default_customer_id')`)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return counts, nil
}

func (s *Server) resetData(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	var in struct {
		Scope   string `json:"scope"`
		Confirm string `json:"confirm"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	c := strings.ToUpper(strings.TrimSpace(in.Confirm))
	if c != "RÉINITIALISER" && c != "REINITIALISER" {
		writeErr(w, http.StatusBadRequest, "Tapez RÉINITIALISER pour confirmer.")
		return
	}
	if in.Scope != resetTransactions && in.Scope != resetAll {
		writeErr(w, http.StatusBadRequest, "Choisissez ce qu’il faut effacer.")
		return
	}
	var open int
	s.db.QueryRow(`SELECT COUNT(*) FROM caisse_sessions WHERE status = 'open'`).Scan(&open)
	if open > 0 {
		writeErr(w, http.StatusConflict, "Une caisse est encore ouverte. Clôturez-la avant de réinitialiser.")
		return
	}
	backup, err := runBackupNamed(s.db, s.dbPath, "before-reset-"+time.Now().Format("20060102-150405")+".db")
	if err != nil {
		writeErr(w, http.StatusInternalServerError,
			"La sauvegarde automatique a échoué, rien n’a été effacé : "+err.Error())
		return
	}
	counts, err := ResetData(s.db, in.Scope)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "Réinitialisation impossible, rien n’a été effacé : "+err.Error())
		return
	}
	var total int64
	for _, n := range counts {
		total += n
	}
	label := "ventes, achats et mouvements"
	if in.Scope == resetAll {
		label = "toutes les données sauf utilisateurs et paramètres"
	}
	name := filepath.Base(backup)
	s.audit(r, "maintenance.reset", "maintenance", in.Scope,
		fmt.Sprintf("réinitialisation (%s) : %d ligne(s) effacée(s), sauvegarde %s", label, total, name))
	writeJSON(w, http.StatusOK, map[string]any{"backup": name, "deleted": counts, "at": domain.NowISO()})
}
