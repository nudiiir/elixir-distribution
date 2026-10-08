package api

import (
	"archive/zip"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/store"
)

type setFx struct {
	t      *testing.T
	db     *sql.DB
	dbPath string
	s      *Server
	h      http.Handler
	wh     string
	usr    *AuthUser
}

func newSetFx(t *testing.T) *setFx {
	t.Helper()
	path := filepath.Join(t.TempDir(), "data", "elixir.db")
	os.MkdirAll(filepath.Dir(path), 0o755)
	db, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(db); err != nil {
		t.Fatal(err)
	}
	if err := store.Seed(db); err != nil {
		t.Fatal(err)
	}
	f := &setFx{t: t, db: db, dbPath: path}
	t.Cleanup(func() { f.db.Close() })
	f.s = &Server{db: db, dbPath: path}
	db.QueryRow(`SELECT id FROM warehouses LIMIT 1`).Scan(&f.wh)
	var uid string
	db.QueryRow(`SELECT id FROM users LIMIT 1`).Scan(&uid)
	f.usr = &AuthUser{ID: uid, Username: "admin", Role: "admin", Active: true,
		Perms: EffectivePerms("admin", "{}")}
	r := chi.NewRouter()
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			next.ServeHTTP(w, req.WithContext(context.WithValue(req.Context(), userKey, f.usr)))
		})
	})
	r.Route("/api/v1", func(r chi.Router) {
		r.Get("/warehouses", f.s.listWarehouses)
		r.Post("/warehouses", f.s.createWarehouse)
		r.Get("/backups", f.s.listBackups)
		r.Post("/backups/run", f.s.runBackupNow)
		r.Get("/audit", f.s.listAudit)
		r.Get("/settings", f.s.getSettings)
		f.s.routesSettingsUX(r)
	})
	f.h = r
	return f
}

func (f *setFx) exec(q string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(q, args...); err != nil {
		f.t.Fatalf("%v\n%s", err, q)
	}
}

func (f *setFx) call(method, path string, body any) (int, map[string]any) {
	f.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		rd = bytes.NewReader(b)
	default:
		js, _ := json.Marshal(b)
		rd = bytes.NewReader(js)
	}
	req := httptest.NewRequest(method, path, rd)
	rec := httptest.NewRecorder()
	f.h.ServeHTTP(rec, req)
	out := map[string]any{}
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func (f *setFx) count(q string, args ...any) int {
	var n int
	if err := f.db.QueryRow(q, args...).Scan(&n); err != nil {
		f.t.Fatalf("%v: %s", err, q)
	}
	return n
}

func (f *setFx) setting(k string) string {
	var v string
	f.db.QueryRow(`SELECT value FROM settings WHERE key = ?`, k).Scan(&v)
	return v
}

// A small sale: product, customer, posted document, line, stock, ledger.
func (f *setFx) seedSale() {
	now := "2026-10-01T10:00:00Z"
	f.exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,created_at,updated_at)
		VALUES ('p1','Café','piece',1900,100,200,1,?,?)`, now, now)
	f.exec(`INSERT INTO partners (id,kind,name,created_at,updated_at) VALUES ('c1','customer','Ali',?,?)`, now, now)
	f.exec(`INSERT INTO documents (id,doc_type,number,status,doc_date,partner_id,warehouse_id,created_at,updated_at)
		VALUES ('d1','SALE_INVOICE','FA-1','posted','2026-10-01','c1',?,?,?)`, f.wh, now, now)
	f.exec(`INSERT INTO document_lines (id,document_id,product_id,qty_milli,created_at) VALUES ('l1','d1','p1',1000,?)`, now)
	f.exec(`INSERT INTO stock_levels (product_id,warehouse_id,qty_milli,avg_cost,updated_at) VALUES ('p1',?,5000,100,?)`, f.wh, now)
	f.exec(`INSERT INTO stock_ledger (id,product_id,warehouse_id,qty_delta_milli,document_id,created_at)
		VALUES ('s1','p1',?,-1000,'d1',?)`, f.wh, now)
	f.exec(`INSERT INTO partner_ledger (id,partner_id,amount,kind,document_id,created_at) VALUES ('pl1','c1',200,'invoice','d1',?)`, now)
	f.exec(`INSERT INTO supplier_prices (id,partner_id,product_id,unit_cost,document_id,created_at)
		VALUES ('sp1','c1','p1',100,'d1',?)`, now)
}

// ---- guided restore --------------------------------------------------------

func TestPendingRestoreAppliedAtStartup(t *testing.T) {
	f := newSetFx(t)
	f.exec(`INSERT INTO settings (key,value,updated_at) VALUES ('probe','before','x')`)
	dest, err := RunBackup(f.db, f.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	name := filepath.Base(dest)
	f.exec(`UPDATE settings SET value='after' WHERE key='probe'`)

	if code, out := f.call("POST", "/api/v1/backups/"+name+"/restore", map[string]string{"confirm": "non"}); code != 400 {
		t.Fatalf("missing confirmation accepted: %d %v", code, out)
	}
	if code, out := f.call("POST", "/api/v1/backups/../x.db/restore", map[string]string{"confirm": "RESTAURER"}); code == 200 {
		t.Fatalf("path traversal accepted: %v", out)
	}
	code, out := f.call("POST", "/api/v1/backups/"+name+"/restore", map[string]string{"confirm": "restaurer"})
	if code != 200 || out["pending_restore"] != name {
		t.Fatalf("schedule: %d %v", code, out)
	}
	_, list := f.call("GET", "/api/v1/backups", nil)
	if list["pending_restore"] != name {
		t.Fatalf("list does not show the pending restore: %v", list)
	}

	// Server stops (WAL still holds 'after' until checkpoint) …
	f.db.Close()
	// … and starts again.
	got, err := store.ApplyPendingRestore(f.dbPath)
	if err != nil || got != name {
		t.Fatalf("apply: %q %v", got, err)
	}
	if store.ReadPendingRestore(f.dbPath) != "" {
		t.Fatal("pending marker not removed")
	}
	lr := store.ReadLastRestore(f.dbPath)
	if lr == nil || lr.Backup != name || lr.Before == "" || lr.Error != "" {
		t.Fatalf("last restore report: %+v", lr)
	}
	db, err := store.Open(f.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	f.db = db
	if v := f.setting("probe"); v != "before" {
		t.Fatalf("restored value = %q, want before", v)
	}
	// The base replaced by the restore was saved, including its WAL content.
	before, err := store.Open(filepath.Join(store.BackupsDir(f.dbPath), lr.Before))
	if err != nil {
		t.Fatal(err)
	}
	defer before.Close()
	var v string
	before.QueryRow(`SELECT value FROM settings WHERE key='probe'`).Scan(&v)
	if v != "after" {
		t.Fatalf("before-restore copy holds %q, want after", v)
	}
	// Nothing pending: a second start is a no-op.
	if got, err := store.ApplyPendingRestore(f.dbPath); got != "" || err != nil {
		t.Fatalf("second apply: %q %v", got, err)
	}
}

func TestPendingRestoreMissingBackupKeepsDatabase(t *testing.T) {
	f := newSetFx(t)
	f.exec(`INSERT INTO settings (key,value,updated_at) VALUES ('probe','live','x')`)
	os.WriteFile(store.PendingRestorePath(f.dbPath), []byte("elixir-19990101-000000.db"), 0o644)
	f.db.Close()
	if _, err := store.ApplyPendingRestore(f.dbPath); err == nil {
		t.Fatal("expected an error for a missing backup")
	}
	if store.ReadPendingRestore(f.dbPath) != "" {
		t.Fatal("failed marker must be cleared so the server starts normally")
	}
	if lr := store.ReadLastRestore(f.dbPath); lr == nil || lr.Error == "" {
		t.Fatalf("failure not reported: %+v", lr)
	}
	db, _ := store.Open(f.dbPath)
	f.db = db
	if v := f.setting("probe"); v != "live" {
		t.Fatalf("database changed: %q", v)
	}
}

func TestCancelRestore(t *testing.T) {
	f := newSetFx(t)
	dest, _ := RunBackup(f.db, f.dbPath)
	f.call("POST", "/api/v1/backups/"+filepath.Base(dest)+"/restore", map[string]string{"confirm": "RESTAURER"})
	if code, _ := f.call("DELETE", "/api/v1/backups/restore", nil); code != 200 {
		t.Fatal(code)
	}
	if store.ReadPendingRestore(f.dbPath) != "" {
		t.Fatal("still pending")
	}
}

// ---- reset -----------------------------------------------------------------

func TestResetTransactionsKeepsMasterData(t *testing.T) {
	f := newSetFx(t)
	f.seedSale()
	if code, _ := f.call("POST", "/api/v1/maintenance/reset", map[string]string{"scope": "transactions", "confirm": "oui"}); code != 400 {
		t.Fatalf("reset without the typed word: %d", code)
	}
	code, out := f.call("POST", "/api/v1/maintenance/reset", map[string]string{"scope": "transactions", "confirm": "réinitialiser"})
	if code != 200 {
		t.Fatalf("reset: %d %v", code, out)
	}
	backup, _ := out["backup"].(string)
	if !strings.HasPrefix(backup, "before-reset-") {
		t.Fatalf("backup name %q", backup)
	}
	if _, err := os.Stat(filepath.Join(store.BackupsDir(f.dbPath), backup)); err != nil {
		t.Fatal("backup file missing")
	}
	for _, tb := range []string{"documents", "document_lines", "stock_levels", "stock_ledger", "partner_ledger"} {
		if n := f.count(`SELECT COUNT(*) FROM ` + tb); n != 0 {
			t.Errorf("%s still has %d rows", tb, n)
		}
	}
	if f.count(`SELECT COUNT(*) FROM products`) != 1 || f.count(`SELECT COUNT(*) FROM partners`) != 1 {
		t.Fatal("products/partners must be kept")
	}
	if f.count(`SELECT COUNT(*) FROM users`) != 1 || f.count(`SELECT COUNT(*) FROM warehouses`) != 1 {
		t.Fatal("users/warehouses must be kept")
	}
	if f.count(`SELECT COUNT(*) FROM supplier_prices WHERE document_id IS NOT NULL`) != 0 {
		t.Fatal("optional pointer to an emptied table must be cleared")
	}
	if f.count(`SELECT COUNT(*) FROM audit_log WHERE action='maintenance.reset'`) != 1 {
		t.Fatal("reset not audited")
	}
	var fkErr int
	rows, _ := f.db.Query(`PRAGMA foreign_key_check`)
	for rows.Next() {
		fkErr++
	}
	rows.Close()
	if fkErr != 0 {
		t.Fatalf("%d foreign key violations", fkErr)
	}
}

func TestResetAllKeepsUsersAndSettings(t *testing.T) {
	f := newSetFx(t)
	f.seedSale()
	f.exec(`INSERT INTO settings (key,value,updated_at) VALUES ('company_name','Supérette','x')`)
	code, out := f.call("POST", "/api/v1/maintenance/reset", map[string]string{"scope": "all", "confirm": "RÉINITIALISER"})
	if code != 200 {
		t.Fatalf("reset: %d %v", code, out)
	}
	if f.count(`SELECT COUNT(*) FROM products`) != 0 || f.count(`SELECT COUNT(*) FROM partners`) != 0 {
		t.Fatal("products/partners must be gone")
	}
	if f.count(`SELECT COUNT(*) FROM users`) != 1 || f.setting("company_name") != "Supérette" {
		t.Fatal("users and settings must be kept")
	}
}

func TestResetRefusedWhileTillOpen(t *testing.T) {
	f := newSetFx(t)
	f.exec(`INSERT INTO caisse_sessions (id,user_id,status,opened_at) VALUES ('cs','` + f.usr.ID + `','open','x')`)
	if code, _ := f.call("POST", "/api/v1/maintenance/reset", map[string]string{"scope": "transactions", "confirm": "RÉINITIALISER"}); code != 409 {
		t.Fatalf("want 409, got %d", code)
	}
}

// ---- export ----------------------------------------------------------------

func TestExportAllDataZip(t *testing.T) {
	f := newSetFx(t)
	f.seedSale()
	req := httptest.NewRequest("GET", "/api/v1/maintenance/export", nil)
	rec := httptest.NewRecorder()
	f.h.ServeHTTP(rec, req)
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "application/zip" {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	zr, err := zip.NewReader(bytes.NewReader(rec.Body.Bytes()), int64(rec.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]string{}
	for _, zf := range zr.File {
		rc, _ := zf.Open()
		b, _ := io.ReadAll(rc)
		rc.Close()
		files[zf.Name] = string(b)
	}
	for _, sp := range exportSpecs {
		if _, ok := files[sp.file]; !ok {
			t.Errorf("missing %s", sp.file)
		}
	}
	if !strings.Contains(files["produits.csv"], "Café") || !strings.Contains(files["lignes_documents.csv"], "FA-1") {
		t.Fatalf("content missing:\n%s", files["produits.csv"])
	}
}

// ---- depots ----------------------------------------------------------------

func TestWarehouseLifecycle(t *testing.T) {
	f := newSetFx(t)
	code, out := f.call("POST", "/api/v1/warehouses", map[string]string{"name": "Réserve", "address": "Rue 1", "phone": "0550"})
	if code != 201 {
		t.Fatalf("%d %v", code, out)
	}
	res := out["id"].(string)
	if code, _ := f.call("POST", "/api/v1/warehouses", map[string]string{"name": "réserve"}); code != 409 {
		t.Fatal("duplicate name accepted")
	}
	code, out = f.call("PUT", "/api/v1/warehouses/"+res, map[string]string{"name": "Arrière-boutique", "address": "Rue 2", "phone": ""})
	if code != 200 || out["name"] != "Arrière-boutique" || out["address"] != "Rue 2" {
		t.Fatalf("rename: %d %v", code, out)
	}
	// The default depot cannot be removed.
	if code, out := f.call("DELETE", "/api/v1/warehouses/"+f.wh, nil); code != 409 || !strings.Contains(out["error"].(string), "défaut") {
		t.Fatalf("default delete: %d %v", code, out)
	}
	// Stock blocks the delete, with the reason.
	f.exec(`INSERT INTO products (id,name,unit,vat_rate,purchase_price,price_retail,active,created_at,updated_at)
		VALUES ('p1','Café','piece',1900,100,200,1,'x','x')`)
	f.exec(`INSERT INTO stock_levels (product_id,warehouse_id,qty_milli,avg_cost,updated_at) VALUES ('p1',?,3000,0,'x')`, res)
	if code, out := f.call("DELETE", "/api/v1/warehouses/"+res, nil); code != 409 || !strings.Contains(out["error"].(string), "stock") {
		t.Fatalf("stocked delete: %d %v", code, out)
	}
	f.exec(`UPDATE stock_levels SET qty_milli = 0 WHERE warehouse_id = ?`, res)
	// Documents block it too.
	f.exec(`INSERT INTO documents (id,doc_type,status,doc_date,warehouse_id,created_at,updated_at)
		VALUES ('d1','QUOTE','draft','2026-10-01',?,'x','x')`, res)
	if code, out := f.call("DELETE", "/api/v1/warehouses/"+res, nil); code != 409 || !strings.Contains(out["error"].(string), "document") {
		t.Fatalf("documented delete: %d %v", code, out)
	}
	f.exec(`DELETE FROM documents`)
	// Make it the default, then the old default can go.
	if code, out := f.call("POST", "/api/v1/warehouses/"+res+"/default", nil); code != 200 || out["is_default"] != true {
		t.Fatalf("default: %d %v", code, out)
	}
	if f.count(`SELECT COUNT(*) FROM warehouses WHERE is_default = 1`) != 1 {
		t.Fatal("exactly one default expected")
	}
	if code, out := f.call("DELETE", "/api/v1/warehouses/"+f.wh, nil); code != 200 {
		t.Fatalf("delete: %d %v", code, out)
	}
	_, list := f.call("GET", "/api/v1/warehouses", nil)
	if items := list["items"].([]any); len(items) != 1 {
		t.Fatalf("list after delete: %v", items)
	}
	// The last depot is kept.
	if code, _ := f.call("DELETE", "/api/v1/warehouses/"+res, nil); code != 409 {
		t.Fatal("last depot deleted")
	}
}

// ---- audit -----------------------------------------------------------------

func TestAuditFilters(t *testing.T) {
	f := newSetFx(t)
	f.exec(`INSERT INTO audit_log (id,user_id,action,entity,detail,created_at) VALUES
		('a1',?,'document.cancel','document','admin — annulation FA-1','2026-10-01T09:00:00Z'),
		('a2',?,'caisse.open','caisse','admin — ouverture','2026-10-02T09:00:00Z'),
		('a3',NULL,'document.void','document','annulation FA-2','2026-10-03T09:00:00Z')`, f.usr.ID, f.usr.ID)
	get := func(q string) int {
		_, out := f.call("GET", "/api/v1/audit?"+q, nil)
		return len(out["items"].([]any))
	}
	if n := get(""); n != 3 {
		t.Fatalf("all = %d", n)
	}
	if n := get("action=document."); n != 2 {
		t.Fatalf("prefix = %d", n)
	}
	if n := get("action=caisse.open"); n != 1 {
		t.Fatalf("exact = %d", n)
	}
	if n := get("user_id=" + f.usr.ID); n != 2 {
		t.Fatalf("user = %d", n)
	}
	if n := get("from=2026-10-02&to=2026-10-02"); n != 1 {
		t.Fatalf("period = %d", n)
	}
	if n := get("q=FA-2"); n != 1 {
		t.Fatalf("text = %d", n)
	}
	_, out := f.call("GET", "/api/v1/audit", nil)
	if len(out["actions"].([]any)) != 3 {
		t.Fatalf("actions = %v", out["actions"])
	}
}

// ---- logo ------------------------------------------------------------------

func TestCompanyLogo(t *testing.T) {
	f := newSetFx(t)
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	img.Set(1, 1, color.RGBA{255, 0, 0, 255})
	var buf bytes.Buffer
	png.Encode(&buf, img)

	if code, _ := f.call("GET", "/api/v1/settings/logo", nil); code != 404 {
		t.Fatal("logo before upload")
	}
	if code, _ := f.call("POST", "/api/v1/settings/logo", []byte("GIF89a......")); code != 415 {
		t.Fatalf("gif accepted: %d", code)
	}
	if code, _ := f.call("POST", "/api/v1/settings/logo", bytes.Repeat([]byte{0x89}, maxLogoBytes+10)); code != 413 {
		t.Fatalf("too big accepted: %d", code)
	}
	code, out := f.call("POST", "/api/v1/settings/logo", buf.Bytes())
	if code != 200 || out["mime"] != "image/png" {
		t.Fatalf("upload: %d %v", code, out)
	}
	if f.setting("logo_rev") == "" || f.setting("logo_rev") == "0" {
		t.Fatal("logo_rev not bumped")
	}
	req := httptest.NewRequest("GET", "/api/v1/settings/logo", nil)
	rec := httptest.NewRecorder()
	f.h.ServeHTTP(rec, req)
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), buf.Bytes()) || rec.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("download: %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}
	if code, _ := f.call("DELETE", "/api/v1/settings/logo", nil); code != 200 {
		t.Fatal("delete")
	}
	if f.setting("logo_rev") != "0" {
		t.Fatal("logo_rev not reset")
	}
}
