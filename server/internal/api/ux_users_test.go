package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// ---- helpers -------------------------------------------------------------------

func (f *apiFx) as(tok, method, path string, body any, hdr map[string]string) (int, map[string]any) {
	f.t.Helper()
	var buf *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		buf = bytes.NewReader(b)
	} else {
		buf = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, "/api/v1"+path, buf)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	f.h.ServeHTTP(rec, req)
	out := map[string]any{}
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

// mkUser creates a user through the API (as admin) and returns its id + token.
func (f *apiFx) mkUser(username, roleID string, extra map[string]any) (string, string) {
	f.t.Helper()
	body := map[string]any{"username": username, "password": "secret1", "full_name": username, "role_id": roleID}
	for k, v := range extra {
		body[k] = v
	}
	code, out := f.as(f.token, "POST", "/users", body, nil)
	if code != http.StatusCreated {
		f.t.Fatalf("create user %s: %d %v", username, code, out)
	}
	id := out["id"].(string)
	code, out = f.as("", "POST", "/auth/login", map[string]any{"username": username, "password": "secret1"}, nil)
	if code != http.StatusOK {
		f.t.Fatalf("login %s: %d %v", username, code, out)
	}
	return id, out["token"].(string)
}

func (f *apiFx) setPin(id, pin string) {
	f.t.Helper()
	if code, out := f.as(f.token, "PUT", "/users/"+id+"/pin", map[string]any{"pin": pin}, nil); code != http.StatusOK {
		f.t.Fatalf("set pin: %d %v", code, out)
	}
}

func discountedQuote(pct int64) map[string]any {
	l := line(nil, "Article", 1000, 100000)
	l["discount_pct"] = pct
	return map[string]any{"doc_type": "SALE_INVOICE", "doc_date": today(), "lines": []any{l}}
}

// ---- tests -----------------------------------------------------------------------

func TestRolesSeededAndUsersMapped(t *testing.T) {
	f := newAPIFx(t)
	var n int
	f.db.QueryRow(`SELECT COUNT(*) FROM roles WHERE id IN ('role-admin','role-manager','role-cashier')`).Scan(&n)
	if n != 3 {
		t.Fatalf("seeded roles = %d", n)
	}
	// The seeded perms_json match the Go built-ins (EffectivePerms legacy path).
	for _, id := range []string{RoleManagerID, RoleCashierID} {
		var js string
		f.db.QueryRow(`SELECT perms_json FROM roles WHERE id = ?`, id).Scan(&js)
		var seeded map[string]bool
		if err := json.Unmarshal([]byte(js), &seeded); err != nil {
			t.Fatal(err)
		}
		want := builtinRolePerms(id)
		if len(seeded) != len(want) {
			t.Fatalf("%s: seeded %d keys, built-in %d", id, len(seeded), len(want))
		}
		for k := range want {
			if !seeded[k] {
				t.Fatalf("%s: %s missing from the seed", id, k)
			}
		}
	}
	// Pre-0013 users (role_id NULL, e.g. the seeded admin) resolve from users.role.
	f.exec(`INSERT INTO users (id, username, password_hash, full_name, role, active, created_at, updated_at)
		VALUES ('old-m','oldm','x','',  'manager',1,'2026-01-01','2026-01-01'),
		       ('old-c','oldc','x','',  'cashier',1,'2026-01-01','2026-01-01')`)
	for id, want := range map[string]string{"old-m": RoleManagerID, "old-c": RoleCashierID} {
		u, err := f.s().loadAuthUser(id)
		if err != nil {
			t.Fatal(err)
		}
		if u.RoleID != want {
			t.Fatalf("%s: role %s, want %s", id, u.RoleID, want)
		}
	}
	var adminID string
	f.db.QueryRow(`SELECT id FROM users WHERE username='admin'`).Scan(&adminID)
	a, _ := f.s().loadAuthUser(adminID)
	if a.RoleID != RoleAdminID || a.Role != "admin" || !a.Perms["void_document"] || a.RoleName != "Administrateur" {
		t.Fatalf("admin: %+v", a)
	}
}

// s returns a bare Server on the fixture DB (for direct helper calls).
func (f *apiFx) s() *Server { return &Server{db: f.db} }

func TestEffectivePerms(t *testing.T) {
	c := EffectivePerms("cashier", "{}")
	for k, want := range map[string]bool{"pos": true, "sales": true, "sales.create": true,
		"sales.validate": false, "discount": false, "purchases": false, "refund": false} {
		if c[k] != want {
			t.Fatalf("cashier %s = %v", k, c[k])
		}
	}
	m := EffectivePerms("manager", "{}")
	for _, k := range AllPerms {
		if !m[k] && k != "negative_stock" {
			t.Fatalf("manager lacks %s", k)
		}
	}
	if m["negative_stock"] {
		t.Fatalf("manager must follow the shop switch for negative stock")
	}
	// Legacy per-user override on a module switches its actions too.
	o := EffectivePerms("cashier", `{"purchases":true,"sales":false}`)
	if !o["purchases.validate"] || o["sales.create"] || o["sales"] {
		t.Fatalf("override: %v", o)
	}
	if legacyRoleFor(RoleCashierID, c) != "cashier" || legacyRoleFor("x", m) != "manager" {
		t.Fatal("legacy role mapping")
	}
}

func TestRefusedActionAndApprovalRoundTrip(t *testing.T) {
	f := newAPIFx(t)
	_, cashTok := f.mkUser("caisse", RoleCashierID, nil)
	gid, _ := f.mkUser("gerant", RoleManagerID, nil)
	f.setPin(gid, "1234")

	// A module the role does not have: plain 403, no manager code.
	code, out := f.as(cashTok, "POST", "/documents", map[string]any{"doc_type": "PURCHASE_ORDER",
		"doc_date": today(), "lines": []any{line(nil, "x", 1000, 100)}}, nil)
	if code != http.StatusForbidden || out["needs_approval"] == true {
		t.Fatalf("purchase by cashier: %d %v", code, out)
	}
	// A discount: 403 needs_approval action=discount.
	code, out = f.as(cashTok, "POST", "/documents", discountedQuote(1000), nil)
	if code != http.StatusForbidden || out["needs_approval"] != true || out["action"] != "discount" {
		t.Fatalf("discount by cashier: %d %v", code, out)
	}
	// Wrong code.
	if code, _ := f.as(cashTok, "POST", "/auth/approve", map[string]any{"pin": "9999", "action": "discount"}, nil); code != http.StatusBadRequest {
		t.Fatalf("wrong pin: %d", code)
	}
	code, out = f.as(cashTok, "POST", "/auth/approve", map[string]any{"pin": "1234", "action": "discount", "amount": 1000}, nil)
	if code != http.StatusOK || out["approver_id"] != gid {
		t.Fatalf("approve: %d %v", code, out)
	}
	tok := out["approval_token"].(string)
	hdr := map[string]string{"X-Approval": tok}
	if code, out := f.as(cashTok, "POST", "/documents", discountedQuote(1000), hdr); code != http.StatusCreated {
		t.Fatalf("approved retry: %d %v", code, out)
	}
	// Single use.
	if code, _ := f.as(cashTok, "POST", "/documents", discountedQuote(1000), hdr); code != http.StatusForbidden {
		t.Fatalf("token reused: %d", code)
	}
	// Expired.
	old := approvals.put(&approvalGrant{approverID: gid, action: "discount", expires: time.Now().Add(-time.Second)})
	if code, _ := f.as(cashTok, "POST", "/documents", discountedQuote(1000), map[string]string{"X-Approval": old}); code != http.StatusForbidden {
		t.Fatalf("expired token accepted: %d", code)
	}
	// Audit « approuvé par ».
	var n int
	f.db.QueryRow(`SELECT COUNT(*) FROM audit_log WHERE action='approval' AND detail LIKE '%approuvé par gerant%'`).Scan(&n)
	if n != 1 {
		t.Fatalf("approval audit rows = %d", n)
	}
	// A cashier cannot validate an invoice alone (sales.validate) nor make an avoir.
	var d Document
	code, _ = f.as(cashTok, "POST", "/documents", map[string]any{"doc_type": "SALE_INVOICE", "doc_date": today(),
		"lines": []any{line(nil, "x", 1000, 100)}}, nil)
	if code != http.StatusCreated {
		t.Fatalf("plain invoice: %d", code)
	}
	f.db.QueryRow(`SELECT id FROM documents WHERE created_by = (SELECT id FROM users WHERE username='caisse')
		AND total_discount = 0`).Scan(&d.ID)
	code, out = f.as(cashTok, "POST", "/documents/"+d.ID+"/post", nil, nil)
	if code != http.StatusForbidden || out["action"] != "sales.validate" {
		t.Fatalf("validate by cashier: %d %v", code, out)
	}
	code, out = f.as(cashTok, "POST", "/documents", map[string]any{"doc_type": "SALE_CREDIT_NOTE",
		"doc_date": today(), "lines": []any{line(nil, "x", 1000, 100)}}, nil)
	if code != http.StatusForbidden || out["action"] != "refund" {
		t.Fatalf("avoir by cashier: %d %v", code, out)
	}
	// Another date than today.
	code, out = f.as(cashTok, "POST", "/documents", map[string]any{"doc_type": "QUOTE",
		"doc_date": "2020-01-01", "lines": []any{line(nil, "x", 1000, 100)}}, nil)
	if code != http.StatusForbidden || out["action"] != "change_date" {
		t.Fatalf("date by cashier: %d %v", code, out)
	}
	// The approver must hold the right: a cashier's code does not approve.
	cid, _ := f.mkUser("caisse2", RoleCashierID, nil)
	f.setPin(cid, "5678")
	if code, _ := f.as(cashTok, "POST", "/auth/approve", map[string]any{"pin": "5678", "action": "discount"}, nil); code != http.StatusForbidden {
		t.Fatalf("cashier approving: %d", code)
	}
	// 5 wrong codes → locked.
	for i := 0; i < 5; i++ {
		f.as(cashTok, "POST", "/auth/approve", map[string]any{"pin": "0000", "action": "discount"}, nil)
	}
	if code, _ := f.as(cashTok, "POST", "/auth/approve", map[string]any{"pin": "1234", "action": "discount"}, nil); code != http.StatusTooManyRequests {
		t.Fatalf("lock after 5 tries: %d", code)
	}
}

func TestPinLoginAndPinUsers(t *testing.T) {
	f := newAPIFx(t)
	gid, gTok := f.mkUser("gerant", RoleManagerID, nil)
	// PIN rules: digits only, 4–6, unique.
	if code, out := f.as(f.token, "PUT", "/users/"+gid+"/pin", map[string]any{"pin": "12a4"}, nil); code != http.StatusBadRequest || out["field"] != "pin" {
		t.Fatalf("bad pin: %d %v", code, out)
	}
	f.setPin(gid, "4321")
	oid, _ := f.mkUser("autre", RoleCashierID, nil)
	if code, _ := f.as(f.token, "PUT", "/users/"+oid+"/pin", map[string]any{"pin": "4321"}, nil); code != http.StatusConflict {
		t.Fatalf("duplicate pin: %d", code)
	}
	code, out := f.as(gTok, "GET", "/auth/pin-users", nil, nil)
	items, _ := out["items"].([]any)
	if code != http.StatusOK || len(items) != 1 {
		t.Fatalf("pin-users: %d %v", code, out)
	}
	if code, _ := f.as("", "GET", "/auth/pin-users", nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("pin-users without session: %d", code)
	}
	if code, _ := f.as(f.token, "POST", "/auth/pin-login", map[string]any{"user_id": gid, "pin": "0000"}, nil); code != http.StatusBadRequest {
		t.Fatalf("wrong pin login: %d", code)
	}
	code, out = f.as(f.token, "POST", "/auth/pin-login", map[string]any{"user_id": gid, "pin": "4321"}, nil)
	if code != http.StatusOK {
		t.Fatalf("pin login: %d %v", code, out)
	}
	tok := out["token"].(string)
	user := out["user"].(map[string]any)
	if user["id"] != gid || user["has_pin"] != true || user["role_name"] != "Gérant" || user["last_login_at"] == nil {
		t.Fatalf("pin login user: %v", user)
	}
	if code, me := f.as(tok, "GET", "/auth/me", nil, nil); code != http.StatusOK || me["id"] != gid {
		t.Fatalf("me with pin token: %d %v", code, me)
	}
	// Clear the PIN.
	f.as(f.token, "PUT", "/users/"+gid+"/pin", map[string]any{"pin": ""}, nil)
	if code, _ := f.as(f.token, "POST", "/auth/pin-login", map[string]any{"user_id": gid, "pin": "4321"}, nil); code != http.StatusBadRequest {
		t.Fatalf("login after pin cleared: %d", code)
	}
}

func TestLogoutAll(t *testing.T) {
	f := newAPIFx(t)
	gid, t1 := f.mkUser("gerant", RoleManagerID, nil)
	_, t2 := f.as("", "POST", "/auth/login", map[string]any{"username": "gerant", "password": "secret1"}, nil)
	tok2 := t2["token"].(string)
	if code, _ := f.as(t1, "GET", "/auth/me", nil, nil); code != http.StatusOK {
		t.Fatal("token 1 before")
	}
	if code, _ := f.as(f.token, "POST", "/users/"+gid+"/logout-all", nil, nil); code != http.StatusOK {
		t.Fatal("logout-all")
	}
	for _, tok := range []string{t1, tok2} {
		if code, _ := f.as(tok, "GET", "/auth/me", nil, nil); code != http.StatusUnauthorized {
			t.Fatalf("old token still valid: %d", code)
		}
	}
	_, t3 := f.as("", "POST", "/auth/login", map[string]any{"username": "gerant", "password": "secret1"}, nil)
	if code, _ := f.as(t3["token"].(string), "GET", "/auth/me", nil, nil); code != http.StatusOK {
		t.Fatal("new login after logout-all")
	}
	// The admin's own pre-existing token is untouched.
	if code, _ := f.as(f.token, "GET", "/auth/me", nil, nil); code != http.StatusOK {
		t.Fatal("admin token")
	}
}

func TestScopeFiltering(t *testing.T) {
	f := newAPIFx(t)
	_, cashTok := f.mkUser("caisse", RoleCashierID, nil) // Caissier = own documents
	quote := func(tok, wh string) {
		f.t.Helper()
		body := map[string]any{"doc_type": "QUOTE", "doc_date": today(), "warehouse_id": wh,
			"lines": []any{line(nil, "x", 1000, 100)}}
		if code, out := f.as(tok, "POST", "/documents", body, nil); code != http.StatusCreated {
			t.Fatalf("quote: %d %v", code, out)
		}
	}
	quote(f.token, f.wh)
	quote(cashTok, f.wh)
	count := func(tok string) int {
		_, out := f.as(tok, "GET", "/documents?type=QUOTE", nil, nil)
		items, _ := out["items"].([]any)
		return len(items)
	}
	if n := count(cashTok); n != 1 {
		t.Fatalf("own scope sees %d", n)
	}
	if n := count(f.token); n != 2 {
		t.Fatalf("admin sees %d", n)
	}

	// Depot scope.
	var wh2 Warehouse
	f.ok("POST", "/warehouses", map[string]any{"name": "Dépôt 2"}, &wh2)
	code, role := f.as(f.token, "POST", "/roles", map[string]any{"name": "Magasinier", "scope": "warehouse",
		"perms": map[string]bool{"sales.create": true, "stock.view": true}}, nil)
	if code != http.StatusCreated {
		t.Fatalf("role: %d %v", code, role)
	}
	_, depTok := f.mkUser("depot", role["id"].(string), map[string]any{"warehouse_ids": []string{wh2.ID}})
	quote(f.token, wh2.ID)
	if n := count(depTok); n != 1 {
		t.Fatalf("warehouse scope sees %d", n)
	}
	// Stock levels are forced to the user's depot.
	req := httptest.NewRequest("GET", "/api/v1/stock/levels?warehouse_id="+f.wh, nil)
	u, _ := f.s().loadAuthUser(mustID(f, "depot"))
	req = req.WithContext(contextWithUser(req, u))
	applyWarehouseScope(req)
	if got := req.URL.Query().Get("warehouse_id"); got != wh2.ID {
		t.Fatalf("stock levels depot = %s", got)
	}
}

func mustID(f *apiFx, username string) string {
	var id string
	f.db.QueryRow(`SELECT id FROM users WHERE username = ?`, username).Scan(&id)
	return id
}

func TestRolesCRUD(t *testing.T) {
	f := newAPIFx(t)
	if code, _ := f.as(f.token, "PUT", "/roles/"+RoleAdminID, map[string]any{"name": "X"}, nil); code != http.StatusConflict {
		t.Fatalf("system role edited: %d", code)
	}
	f.mkUser("caisse", RoleCashierID, nil)
	code, out := f.as(f.token, "DELETE", "/roles/"+RoleCashierID, nil, nil)
	if code != http.StatusConflict || out["user_count"] != float64(1) {
		t.Fatalf("delete in use: %d %v", code, out)
	}
	code, cp := f.as(f.token, "POST", "/roles/"+RoleCashierID+"/copy", nil, nil)
	if code != http.StatusCreated || cp["name"] != "Caissier (copie)" {
		t.Fatalf("copy: %d %v", code, cp)
	}
	id := cp["id"].(string)
	code, up := f.as(f.token, "PUT", "/roles/"+id, map[string]any{"name": "Vendeur", "scope": "all",
		"perms": map[string]bool{"sales.create": true, "sales.validate": true, "discount": true, "bogus": true},
		"limits": map[string]int64{"max_discount_pct": 500}}, nil)
	perms, _ := up["perms"].(map[string]any)
	if code != http.StatusOK || perms["sales.view"] != true || perms["bogus"] != nil {
		t.Fatalf("update: %d %v", code, up)
	}
	// Limit enforced: 5 % allowed alone, 10 % needs approval.
	_, vTok := f.mkUser("vendeur", id, nil)
	if code, _ := f.as(vTok, "POST", "/documents", discountedQuote(500), nil); code != http.StatusCreated {
		t.Fatalf("5%% within limit: %d", code)
	}
	if code, out := f.as(vTok, "POST", "/documents", discountedQuote(1000), nil); code != http.StatusForbidden || out["needs_approval"] != true {
		t.Fatalf("10%% above limit: %d %v", code, out)
	}
	f.exec(`UPDATE users SET role_id = 'role-cashier' WHERE username = 'vendeur'`)
	if code, _ := f.as(f.token, "DELETE", "/roles/"+id, nil, nil); code != http.StatusOK {
		t.Fatalf("delete unused: %d", code)
	}
	// Only the Administrateur role is admin.
	code, out = f.as(f.token, "GET", "/users", nil, nil)
	for _, it := range out["items"].([]any) {
		u := it.(map[string]any)
		if (u["role"] == "admin") != (u["role_id"] == RoleAdminID) {
			t.Fatalf("legacy role mismatch: %v", u)
		}
	}
}

func contextWithUser(r *http.Request, u *AuthUser) context.Context {
	return context.WithValue(r.Context(), userKey, u)
}
