package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// ---- helpers -------------------------------------------------------------------------

// call runs a request as admin and returns status + decoded JSON object.
func (f *apiFx) call(method, path string, body any) (int, map[string]any) {
	f.t.Helper()
	return f.as(f.token, method, path, body, nil)
}

// must runs a request as admin and fails the test on a non-2xx answer.
func (f *apiFx) must(method, path string, body any) map[string]any {
	f.t.Helper()
	code, out := f.call(method, path, body)
	if code >= 300 {
		f.t.Fatalf("%s %s: %d %v", method, path, code, out)
	}
	return out
}

func n64(v any) int64 {
	switch x := v.(type) {
	case float64:
		return int64(x)
	case json.Number:
		n, _ := x.Int64()
		return n
	}
	return 0
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// distProduct inserts a product: TTC retail price, VAT, lot/expiry tracking.
func (f *apiFx) distProduct(id, name, barcode string, retailTTC, vat int64, tracked bool) {
	t := 0
	if tracked {
		t = 1
	}
	f.exec(`INSERT INTO products (id, name, barcode, unit, vat_rate, purchase_price, price_retail, track_lots, track_expiry,
		active, created_at, updated_at) VALUES (?, ?, ?, 'pièce', ?, 0, ?, ?, ?, 1, '2026-01-01', '2026-01-01')`,
		id, name, nullIfBlank(barcode), vat, retailTTC, t, t)
}

// receive posts a purchase receipt bringing qty (milli) of a product in, on a lot.
func (f *apiFx) receive(productID string, qty int64, lot, expiry string) {
	f.t.Helper()
	var n int
	f.db.QueryRow(`SELECT COUNT(*) FROM partners WHERE id = 'SUPP'`).Scan(&n)
	if n == 0 {
		f.partner("SUPP", "supplier", "Laboratoire")
	}
	l := map[string]any{"product_id": productID, "description": productID, "qty_milli": qty,
		"unit_price": 4000, "discount_pct": 0, "vat_rate": 0}
	if lot != "" {
		l["lot_number"], l["expiry_date"] = lot, expiry
	}
	f.postDoc(map[string]any{"doc_type": "PURCHASE_RECEIPT", "doc_date": today(), "partner_id": "SUPP",
		"warehouse_id": f.wh, "lines": []any{l}})
}

func (f *apiFx) stock(productID string) int64 {
	var q int64
	f.db.QueryRow(`SELECT COALESCE(SUM(qty_milli),0) FROM stock_levels WHERE product_id = ?`, productID).Scan(&q)
	return q
}

func (f *apiFx) balance(partnerID string) int64 {
	var b int64
	f.db.QueryRow(`SELECT COALESCE(SUM(amount),0) FROM partner_ledger WHERE partner_id = ?`, partnerID).Scan(&b)
	return b
}

func orderLines(o map[string]any) map[string]map[string]any {
	out := map[string]map[string]any{}
	for _, l := range o["lines"].([]any) {
		m := l.(map[string]any)
		if n64(m["qty_ordered_milli"]) > 0 {
			out[str(m["product_id"])] = m
		}
	}
	return out
}

// ---- A. order lifecycle -------------------------------------------------------------------

func TestOrderLifecycleEndToEnd(t *testing.T) {
	f := newAPIFx(t)
	f.distProduct("P1", "Doliprane 1g", "111", 11900, 1900, true) // 100 DA HT
	f.distProduct("P2", "Sérum physiologique", "222", 2000, 0, false)
	f.distProduct("P3", "Hors commande", "333", 1000, 0, false)
	f.receive("P1", 5000, "L1", "2027-06-30")
	f.receive("P1", 5000, "L2", "2026-12-31") // expires first: FEFO
	f.receive("P2", 3000, "", "")
	f.partner("C1", "customer", "Supérette El Amel")
	f.exec(`UPDATE partners SET credit_limit = 100000 WHERE id = 'C1'`) // 1 000 DA

	// Create: prices resolved from the product (retail, TTC → HT).
	o := f.must("POST", "/orders", map[string]any{"partner_id": "C1", "source": "phone",
		"lines": []any{map[string]any{"product_id": "P1", "qty_milli": 8000},
			map[string]any{"product_id": "P2", "qty_milli": 5000}}})
	id := str(o["id"])
	if !strings.HasPrefix(str(o["number"]), "CC-") || str(o["status"]) != "new" {
		t.Fatalf("created: %v %v", o["number"], o["status"])
	}
	ls := orderLines(o)
	if n64(ls["P1"]["unit_price"]) != 10000 || str(ls["P1"]["price_source"]) != "retail" {
		t.Fatalf("P1 price: %v %v", ls["P1"]["unit_price"], ls["P1"]["price_source"])
	}

	// Validate: P2 only 3 available → 2 in backorder; 952 + 60 = 1 012 DA > 1 000 DA ceiling.
	code, out := f.call("POST", "/orders/"+id+"/validate", map[string]any{})
	if code != http.StatusConflict || out["needs_override"] != true {
		t.Fatalf("credit check: %d %v", code, out)
	}
	if !strings.Contains(str(out["error"]), "plafond") {
		t.Fatalf("message: %v", out["error"])
	}
	o = f.must("POST", "/orders/"+id+"/validate", map[string]any{"override_credit": true})
	ls = orderLines(o)
	if str(o["status"]) != "validated" || o["has_backorder"] != true || o["credit_override"] != true {
		t.Fatalf("validated: %v backorder=%v override=%v", o["status"], o["has_backorder"], o["credit_override"])
	}
	if n64(ls["P2"]["qty_validated_milli"]) != 3000 || n64(ls["P2"]["qty_backorder_milli"]) != 2000 {
		t.Fatalf("P2 partial: %v / %v", ls["P2"]["qty_validated_milli"], ls["P2"]["qty_backorder_milli"])
	}
	if n64(o["total_ttc"]) != 95200+6000 {
		t.Fatalf("total on validated qty: %v", o["total_ttc"])
	}

	// Picking list: FEFO suggests L2 (earliest expiry) first.
	pl := f.must("GET", "/orders/"+id+"/picking-list", nil)
	var p1 map[string]any
	for _, l := range pl["lines"].([]any) {
		if m := l.(map[string]any); str(m["product_id"]) == "P1" {
			p1 = m
		}
	}
	sugg := p1["lot_suggestions"].([]any)
	if len(sugg) != 2 || str(sugg[0].(map[string]any)["lot_number"]) != "L2" ||
		n64(sugg[0].(map[string]any)["qty_suggested_milli"]) != 5000 {
		t.Fatalf("FEFO suggestions: %v", sugg)
	}

	// Scan: a product not on the order is refused.
	code, out = f.call("POST", "/orders/"+id+"/scan", map[string]any{"barcode": "333"})
	if code != http.StatusUnprocessableEntity || out["wrong_product"] != true {
		t.Fatalf("wrong product: %d %v", code, out)
	}
	code, _ = f.call("POST", "/orders/"+id+"/scan", map[string]any{"barcode": "999999"})
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("unknown barcode: %d", code)
	}
	// One scan of P1 → preparing, 1 unit picked FEFO on L2.
	sc := f.must("POST", "/orders/"+id+"/scan", map[string]any{"barcode": "111"})
	if n64(sc["qty_prepared_milli"]) != 1000 || len(sc["lots"].([]any)) != 1 || sc["lots"].([]any)[0] != "L2" {
		t.Fatalf("scan: %v", sc)
	}
	// Too many at once is refused.
	if code, _ := f.call("POST", "/orders/"+id+"/scan", map[string]any{"barcode": "111", "qty_milli": 9000}); code != http.StatusConflict {
		t.Fatalf("over-scan: %d", code)
	}
	sc = f.must("POST", "/orders/"+id+"/scan", map[string]any{"barcode": "111", "qty_milli": 7000})
	if sc["line_complete"] != true {
		t.Fatalf("P1 complete: %v", sc)
	}
	f.must("POST", "/orders/"+id+"/picks", map[string]any{"line_id": str(ls["P2"]["id"]), "qty_milli": 3000})

	o = f.must("POST", "/orders/"+id+"/ready", map[string]any{})
	if str(o["status"]) != "ready" {
		t.Fatalf("ready: %v", o["status"])
	}

	// BL from the prepared quantities, with lots; stock leaves.
	o = f.must("POST", "/orders/"+id+"/delivery-note", nil)
	if o["delivery_note_number"] == nil || !strings.HasPrefix(str(o["document_number"]), "BL-") {
		t.Fatalf("BL: %v", o["document_number"])
	}
	if f.stock("P1") != 2000 || f.stock("P2") != 0 {
		t.Fatalf("stock after BL: P1=%d P2=%d", f.stock("P1"), f.stock("P2"))
	}
	var l1, l2 int64
	f.db.QueryRow(`SELECT qty_milli FROM lots WHERE lot_number='L1'`).Scan(&l1)
	f.db.QueryRow(`SELECT qty_milli FROM lots WHERE lot_number='L2'`).Scan(&l2)
	if l2 != 0 || l1 != 2000 {
		t.Fatalf("lots after BL: L1=%d L2=%d", l1, l2)
	}
	var blLines int
	f.db.QueryRow(`SELECT COUNT(*) FROM document_lines WHERE document_id = ? AND lot_id IS NOT NULL`,
		str(o["delivery_note_id"])).Scan(&blLines)
	if blLines != 2 {
		t.Fatalf("BL lines with lots: %d", blLines)
	}

	// Ship, deliver with cash on delivery → PAYMENT_IN.
	f.must("POST", "/orders/"+id+"/ship", nil)
	o = f.must("POST", "/orders/"+id+"/deliver", map[string]any{"cod_amount": 50000, "payment_method": "cash",
		"receiver_name": "Dr Amel"})
	if str(o["status"]) != "delivered" || !strings.HasPrefix(str(o["payment_number"]), "RG-") {
		t.Fatalf("delivered: %v %v", o["status"], o["payment_number"])
	}
	if f.balance("C1") != -50000 {
		t.Fatalf("balance after COD: %d", f.balance("C1"))
	}

	// Invoice from the BL: on account, stock not moved twice.
	o = f.must("POST", "/orders/"+id+"/invoice", map[string]any{})
	total := n64(o["total_ttc"])
	if str(o["status"]) != "invoiced" || !strings.HasPrefix(str(o["invoice_number"]), "FV-") {
		t.Fatalf("invoiced: %v %v", o["status"], o["invoice_number"])
	}
	if f.stock("P1") != 2000 {
		t.Fatalf("invoice moved stock again: %d", f.stock("P1"))
	}
	if f.balance("C1") != total-50000 {
		t.Fatalf("balance after invoice: %d, want %d", f.balance("C1"), total-50000)
	}
	var invTTC int64
	var due string
	f.db.QueryRow(`SELECT total_ttc, due_date FROM documents WHERE id = ?`, str(o["invoice_id"])).Scan(&invTTC, &due)
	if invTTC != total || due == "" {
		t.Fatalf("invoice total %d (order %d), due %q", invTTC, total, due)
	}
	// History and kanban counts.
	if len(o["events"].([]any)) < 8 {
		t.Fatalf("events: %d", len(o["events"].([]any)))
	}
	list := f.must("GET", "/orders?partner_id=C1", nil)
	if n64(list["counts"].(map[string]any)["invoiced"]) != 1 {
		t.Fatalf("counts: %v", list["counts"])
	}
	// Invoiced orders cannot be cancelled.
	if code, _ := f.call("POST", "/orders/"+id+"/cancel", map[string]any{"reason": "x"}); code != http.StatusConflict {
		t.Fatalf("cancel invoiced: %d", code)
	}

	// ---- backorders: stock arrives, who is waiting, new order from backorder.
	bo := f.must("GET", "/orders/backorders?fulfillable=1", nil)
	if len(bo["items"].([]any)) != 0 {
		t.Fatalf("nothing fulfillable yet: %v", bo["items"])
	}
	f.receive("P2", 10000, "", "")
	bo = f.must("GET", "/orders/backorders?fulfillable=1", nil)
	items := bo["items"].([]any)
	if len(items) != 1 || n64(items[0].(map[string]any)["fulfillable_milli"]) != 2000 {
		t.Fatalf("fulfillable backorders: %v", items)
	}
	wc := f.must("GET", "/products/P2/waiting-customers", nil)
	if n64(wc["total_backorder_milli"]) != 2000 || len(wc["items"].([]any)) != 1 {
		t.Fatalf("waiting customers: %v", wc)
	}
	nb := f.must("POST", "/orders/backorders/new-order", map[string]any{"partner_id": "C1"})
	nl := orderLines(nb)
	if str(nb["status"]) != "new" || n64(nl["P2"]["qty_ordered_milli"]) != 2000 ||
		str(nl["P2"]["price_source"]) != "backorder" || nl["P2"]["backorder_from_line_id"] == nil {
		t.Fatalf("backorder order: %v %v", nb["status"], nl["P2"])
	}
	var left int64
	f.db.QueryRow(`SELECT qty_backorder_milli FROM customer_order_lines WHERE id = ?`, str(ls["P2"]["id"])).Scan(&left)
	if left != 0 {
		t.Fatalf("original backorder not cleared: %d", left)
	}
}

func TestOrderCancelVoidsDeliveryNote(t *testing.T) {
	f := newAPIFx(t)
	f.distProduct("P1", "Produit", "", 1000, 0, false)
	f.receive("P1", 4000, "", "")
	f.partner("C1", "customer", "Client")
	o := f.must("POST", "/orders", map[string]any{"partner_id": "C1",
		"lines": []any{map[string]any{"product_id": "P1", "qty_milli": 4000}}})
	id := str(o["id"])
	f.must("POST", "/orders/"+id+"/validate", nil)
	f.must("POST", "/orders/"+id+"/ready", map[string]any{"auto_pick": true})
	f.must("POST", "/orders/"+id+"/ship", nil)
	if f.stock("P1") != 0 {
		t.Fatalf("stock after ship: %d", f.stock("P1"))
	}
	if code, _ := f.call("POST", "/orders/"+id+"/cancel", map[string]any{}); code != http.StatusBadRequest {
		t.Fatalf("cancel without reason: %d", code)
	}
	o = f.must("POST", "/orders/"+id+"/cancel", map[string]any{"reason": "client absent"})
	if str(o["status"]) != "cancelled" || f.stock("P1") != 4000 {
		t.Fatalf("cancel: %v stock=%d", o["status"], f.stock("P1"))
	}
	var st string
	f.db.QueryRow(`SELECT status FROM documents WHERE id = ?`, str(o["delivery_note_id"])).Scan(&st)
	if st != "cancelled" {
		t.Fatalf("BL not reversed: %s", st)
	}
}

// ---- web import -----------------------------------------------------------------------------

func TestWebImportIdempotentAndPhoneMatch(t *testing.T) {
	f := newAPIFx(t)
	f.distProduct("P1", "Gel hydroalcoolique", "", 23800, 1900, false) // 200 DA HT
	f.receive("P1", 50000, "", "")
	f.partner("C1", "customer", "Supérette du Centre")
	f.exec(`UPDATE partners SET phone = '0550 12 34 56' WHERE id = 'C1'`)

	payload := map[string]any{"id": "web-001", "number": "W-1001", "customer_name": "Karim", "phone": "+213 550123456",
		"customer_type": "supérette", "business_name": "Supérette du Centre", "wilaya": "16", "commune": "Hydra",
		"address": "12 rue des Pins", "note": "livrer le matin", "shipping_fee_centimes": 50000,
		"items":       []any{map[string]any{"product_id": "P1", "name": "Gel", "qty_milli": 2000, "price_centimes": 23800}},
		"extra_field": "ignored"}
	code, o := f.call("POST", "/orders/import-web", payload)
	if code != http.StatusCreated || o["created"] != true || o["partner_created"] != false || str(o["partner_id"]) != "C1" {
		t.Fatalf("import: %d created=%v partner=%v/%v", code, o["created"], o["partner_created"], o["partner_id"])
	}
	if str(o["source"]) != "web" || str(o["payment_mode"]) != "cod" || str(o["external_number"]) != "W-1001" {
		t.Fatalf("web order: %v %v %v", o["source"], o["payment_mode"], o["external_number"])
	}
	// 2 × 238 DA + 500 DA shipping.
	if n64(o["total_ttc"]) != 2*23800+50000 {
		t.Fatalf("total: %v", o["total_ttc"])
	}
	code, again := f.call("POST", "/orders/import-web", payload)
	if code != http.StatusOK || again["created"] != false || str(again["id"]) != str(o["id"]) {
		t.Fatalf("idempotence: %d %v %v", code, again["created"], again["id"])
	}
	var n int
	f.db.QueryRow(`SELECT COUNT(*) FROM customer_orders`).Scan(&n)
	if n != 1 {
		t.Fatalf("orders: %d", n)
	}

	// Unknown phone → a web customer is created (with the person as contact).
	payload2 := map[string]any{"id": "web-002", "number": "W-1002", "customer_name": "Samia", "phone": "0661 00 11 22",
		"customer_type": "supermarket", "business_name": "Supérette Nouvelle", "nif": "000123",
		"items": []any{map[string]any{"product_id": "P1", "qty_milli": 1000, "price_centimes": 23800},
			map[string]any{"product_id": "NOPE", "name": "Inconnu", "qty_milli": 1000}}}
	code, o2 := f.call("POST", "/orders/import-web", payload2)
	if code != http.StatusCreated || o2["partner_created"] != true || len(o2["warnings"].([]any)) != 1 {
		t.Fatalf("new customer import: %d %v %v", code, o2["partner_created"], o2["warnings"])
	}
	var name, phone, ctype, source string
	f.db.QueryRow(`SELECT name, phone, client_type, source FROM partners WHERE id = ?`, str(o2["partner_id"])).
		Scan(&name, &phone, &ctype, &source)
	if name != "Supérette Nouvelle" || phone != "0661001122" || ctype != "supermarket" || source != "web" {
		t.Fatalf("created partner: %s %s %s %s", name, phone, ctype, source)
	}
	var contacts int
	f.db.QueryRow(`SELECT COUNT(*) FROM partner_contacts WHERE partner_id = ?`, str(o2["partner_id"])).Scan(&contacts)
	if contacts != 1 {
		t.Fatalf("contact: %d", contacts)
	}

	// Status sync back to the storefront.
	sync := f.must("GET", "/orders/web-sync", nil)
	if len(sync["items"].([]any)) != 0 {
		t.Fatalf("nothing dirty yet: %v", sync["items"])
	}
	f.must("POST", "/orders/"+str(o["id"])+"/validate", nil)
	sync = f.must("GET", "/orders/web-sync", nil)
	it := sync["items"].([]any)
	if len(it) != 1 || str(it[0].(map[string]any)["external_ref"]) != "web-001" ||
		str(it[0].(map[string]any)["status"]) != "validated" {
		t.Fatalf("dirty: %v", it)
	}
	// A stale ack (status changed meanwhile) does not clear the flag.
	ack := f.must("POST", "/orders/web-sync/ack", map[string]any{"items": []any{
		map[string]any{"id": str(o["id"]), "status": "new"}}})
	if n64(ack["cleared"]) != 0 {
		t.Fatalf("stale ack cleared: %v", ack)
	}
	ack = f.must("POST", "/orders/web-sync/ack", map[string]any{"items": []any{
		map[string]any{"id": str(o["id"]), "status": "validated"}}})
	if n64(ack["cleared"]) != 1 || len(f.must("GET", "/orders/web-sync", nil)["items"].([]any)) != 0 {
		t.Fatalf("ack: %v", ack)
	}
}

func TestNormalizePhoneDZ(t *testing.T) {
	for in, want := range map[string]string{
		"0550123456": "0550123456", "+213550123456": "0550123456", "00213 550 12 34 56": "0550123456",
		"213550123456": "0550123456", "550123456": "0550123456", "021 23 45 67": "021234567", "12": "",
	} {
		if got := NormalizePhoneDZ(in); got != want {
			t.Errorf("%q → %q, want %q", in, got, want)
		}
	}
	if IntlPhoneDZ("0550 12 34 56") != "213550123456" {
		t.Fatal("intl")
	}
}

// ---- pricing ----------------------------------------------------------------------------------

func TestPriceResolutionOrderAndFreeGoods(t *testing.T) {
	f := newAPIFx(t)
	f.distProduct("P1", "Amoxicilline", "", 11900, 1900, false)          // retail 100 DA HT
	f.exec(`UPDATE products SET price_wholesale = 9520 WHERE id = 'P1'`) // 80 DA HT
	f.must("POST", "/customer-groups", map[string]any{"name": "Supérettes", "price_level": "wholesale", "discount_pct": 500})
	var gid string
	f.db.QueryRow(`SELECT id FROM customer_groups WHERE name = 'Supérettes'`).Scan(&gid)
	f.partner("B", "customer", "Particulier")
	f.partner("C", "customer", "Supérette groupe")
	f.partner("A", "customer", "Supérette spéciale")
	f.exec(`UPDATE partners SET group_id = ? WHERE id IN ('A','C')`, gid)

	quote := func(partner string, qty int64) map[string]any {
		t.Helper()
		out := f.must("GET", "/pricing/resolve?product_id=P1&partner_id="+partner+"&qty_milli="+itoa(qty), nil)
		return out["quote"].(map[string]any)
	}
	check := func(q map[string]any, price, disc int64, src string) {
		t.Helper()
		if n64(q["unit_price"]) != price || n64(q["discount_pct"]) != disc || str(q["price_source"]) != src {
			t.Fatalf("quote %v/%v/%v, want %d/%d/%s", q["unit_price"], q["discount_pct"], q["price_source"], price, disc, src)
		}
	}
	check(quote("B", 1000), 10000, 0, "retail")
	check(quote("C", 1000), 8000, 500, "wholesale") // group level + group discount

	gp := f.must("POST", "/customer-prices", map[string]any{"group_id": gid, "product_id": "P1", "price_ht": 7500})
	check(quote("C", 1000), 7500, 0, "special_group")
	f.must("POST", "/customer-prices", map[string]any{"partner_id": "A", "product_id": "P1", "price_ht": 7000})
	check(quote("A", 1000), 7000, 0, "special_partner") // partner beats group
	// Quantity tier on the partner price.
	f.must("POST", "/customer-prices", map[string]any{"partner_id": "A", "product_id": "P1", "price_ht": 6500,
		"min_qty_milli": 50000})
	check(quote("A", 60000), 6500, 0, "special_partner")
	check(quote("A", 10000), 7000, 0, "special_partner")
	// Expired special price is ignored.
	f.exec(`UPDATE customer_prices SET end_date = '2020-01-01' WHERE id = ?`, str(gp["id"]))
	check(quote("C", 1000), 8000, 500, "wholesale")

	// Promotions: 10 + 1 free (UG), and −7 % from 20 units.
	f.must("POST", "/promo-rules", map[string]any{"name": "UG Amox", "scope": "product", "product_id": "P1",
		"type": "free_goods", "min_qty_milli": 10000, "free_qty_milli": 1000})
	f.must("POST", "/promo-rules", map[string]any{"name": "Remise volume", "scope": "all",
		"type": "qty_discount", "min_qty_milli": 20000, "discount_pct": 700, "channel": "desk"})
	q := quote("B", 25000)
	if n64(q["qty_free_milli"]) != 2000 || n64(q["discount_pct"]) != 700 {
		t.Fatalf("promos: free=%v disc=%v", q["qty_free_milli"], q["discount_pct"])
	}
	if q2 := quote("B", 9000); n64(q2["qty_free_milli"]) != 0 || n64(q2["discount_pct"]) != 0 {
		t.Fatalf("below threshold: %v", q2)
	}
	// Web channel: the desk-only discount does not apply.
	web := f.must("GET", "/pricing/resolve?product_id=P1&partner_id=B&qty_milli=25000&channel=web", nil)["quote"].(map[string]any)
	if n64(web["discount_pct"]) != 0 || n64(web["qty_free_milli"]) != 2000 {
		t.Fatalf("web channel: %v", web)
	}
	wp := f.must("GET", "/promo-rules/web", nil)["items"].([]any)
	if len(wp) != 1 || str(wp[0].(map[string]any)["name"]) != "UG Amox" {
		t.Fatalf("web promos: %v", wp)
	}

	// On an order the free units ride on the line and follow the validated quantity.
	f.receive("P1", 30000, "", "")
	o := f.must("POST", "/orders", map[string]any{"partner_id": "B",
		"lines": []any{map[string]any{"product_id": "P1", "qty_milli": 25000}}})
	l := orderLines(o)["P1"]
	if n64(l["qty_free_milli"]) != 2000 || n64(l["discount_pct"]) != 700 {
		t.Fatalf("order line: %v", l)
	}
	o = f.must("POST", "/orders/"+str(o["id"])+"/validate", nil)
	l = orderLines(o)["P1"]
	if n64(l["qty_validated_milli"]) != 25000 || n64(l["qty_free_milli"]) != 2000 {
		t.Fatalf("validated line: %v", l)
	}
	o = f.must("POST", "/orders/"+str(o["id"])+"/ready", map[string]any{"auto_pick": true})
	o = f.must("POST", "/orders/"+str(o["id"])+"/delivery-note", nil)
	var free, paid int64
	f.db.QueryRow(`SELECT COALESCE(SUM(CASE WHEN discount_pct = 10000 THEN qty_milli END),0),
		COALESCE(SUM(CASE WHEN discount_pct < 10000 THEN qty_milli END),0)
		FROM document_lines WHERE document_id = ?`, str(o["delivery_note_id"])).Scan(&free, &paid)
	if free != 2000 || paid != 25000 || f.stock("P1") != 3000 {
		t.Fatalf("BL free=%d paid=%d stock=%d", free, paid, f.stock("P1"))
	}

	// A price typed by hand needs price_edit (the admin has it) and is marked manual.
	o = f.must("POST", "/orders", map[string]any{"partner_id": "B",
		"lines": []any{map[string]any{"product_id": "P1", "qty_milli": 1000, "unit_price": 9000}}})
	if str(orderLines(o)["P1"]["price_source"]) != "manual" {
		t.Fatalf("manual price: %v", orderLines(o)["P1"])
	}
}

func itoa(v int64) string { return strconv.FormatInt(v, 10) }

func TestQuotaEnforcement(t *testing.T) {
	f := newAPIFx(t)
	f.distProduct("P1", "Vaccin rare", "", 1000, 0, false)
	f.receive("P1", 100000, "", "")
	f.partner("C1", "customer", "Supérette 1")
	f.partner("C2", "customer", "Supérette 2")
	f.must("POST", "/product-quotas", map[string]any{"product_id": "P1", "max_qty_milli": 5000, "period": "week"})

	mk := func(partner string, qty int64) string {
		o := f.must("POST", "/orders", map[string]any{"partner_id": partner,
			"lines": []any{map[string]any{"product_id": "P1", "qty_milli": qty}}})
		return str(o["id"])
	}
	f.must("POST", "/orders/"+mk("C1", 4000)+"/validate", nil)
	second := mk("C1", 2000)
	code, out := f.call("POST", "/orders/"+second+"/validate", map[string]any{"override_credit": true})
	if code != http.StatusConflict || !strings.Contains(str(out["error"]), "quota dépassé") ||
		!strings.Contains(str(out["error"]), "il reste 1") {
		t.Fatalf("quota: %d %v", code, out)
	}
	// Another customer has his own allowance.
	f.must("POST", "/orders/"+mk("C2", 5000)+"/validate", nil)
	// Within the remaining allowance it passes.
	f.must("PATCH", "/orders/"+second+"/lines/"+str(orderLines(f.must("GET", "/orders/"+second, nil))["P1"]["id"]),
		map[string]any{"qty_milli": 1000})
	f.must("POST", "/orders/"+second+"/validate", nil)
	u := f.must("GET", "/product-quotas/usage?partner_id=C1", nil)["items"].([]any)
	if len(u) != 1 || n64(u[0].(map[string]any)["used_milli"]) != 5000 || n64(u[0].(map[string]any)["remaining_milli"]) != 0 {
		t.Fatalf("usage: %v", u)
	}
}

// ---- deliveries -----------------------------------------------------------------------------------

func TestDeliveryRunCloseReconciliation(t *testing.T) {
	f := newAPIFx(t)
	f.distProduct("P1", "Produit", "", 10000, 0, false) // 100 DA
	f.receive("P1", 10000, "", "")
	f.partner("C1", "customer", "Client 1")
	f.partner("C2", "customer", "Client 2")
	route := f.must("POST", "/delivery-routes", map[string]any{"name": "Alger Est", "wilayas": []string{"16"},
		"weekdays": []int{1, 3}, "default_driver_name": "Yacine"})
	ready := func(partner string, qty int64) string {
		o := f.must("POST", "/orders", map[string]any{"partner_id": partner, "payment_mode": "cod",
			"route_id": str(route["id"]), "lines": []any{map[string]any{"product_id": "P1", "qty_milli": qty}}})
		id := str(o["id"])
		f.must("POST", "/orders/"+id+"/validate", nil)
		f.must("POST", "/orders/"+id+"/ready", map[string]any{"auto_pick": true})
		return id
	}
	o1, o2 := ready("C1", 2000), ready("C2", 3000)
	run := f.must("POST", "/delivery-runs", map[string]any{"route_id": str(route["id"]), "order_ids": []string{o1, o2}})
	if str(run["driver_name"]) != "Yacine" || len(run["stops"].([]any)) != 2 {
		t.Fatalf("run: %v %v", run["driver_name"], run["stops"])
	}
	stops := run["stops"].([]any)
	s1, s2 := stops[0].(map[string]any), stops[1].(map[string]any)
	if n64(s1["cod_expected"]) != 20000 || n64(s2["cod_expected"]) != 30000 {
		t.Fatalf("cod expected: %v %v", s1["cod_expected"], s2["cod_expected"])
	}
	// An order cannot be on two open runs.
	if code, _ := f.call("POST", "/delivery-runs", map[string]any{"order_ids": []string{o1}}); code != http.StatusConflict {
		t.Fatalf("double run: %d", code)
	}
	runID := str(run["id"])
	// Reorder, then start: orders leave (BL generated).
	f.must("PUT", "/delivery-runs/"+runID+"/stops/order", map[string]any{"stop_ids": []string{str(s2["id"]), str(s1["id"])}})
	run = f.must("POST", "/delivery-runs/"+runID+"/start", nil)
	if str(run["status"]) != "out" || str(run["stops"].([]any)[0].(map[string]any)["id"]) != str(s2["id"]) {
		t.Fatalf("start: %v", run["status"])
	}
	if st := str(f.must("GET", "/orders/"+o1, nil)["status"]); st != "shipping" || f.stock("P1") != 5000 {
		t.Fatalf("o1 %s stock %d", st, f.stock("P1"))
	}
	// Closing with pending stops is refused.
	if code, _ := f.call("POST", "/delivery-runs/"+runID+"/close", nil); code != http.StatusConflict {
		t.Fatalf("close pending: %d", code)
	}
	f.must("POST", "/delivery-runs/"+runID+"/stops/"+str(s1["id"])+"/result", map[string]any{"status": "delivered",
		"cod_collected": 19000, "receiver_name": "Gérant"})
	if code, _ := f.call("POST", "/delivery-runs/"+runID+"/stops/"+str(s2["id"])+"/result",
		map[string]any{"status": "failed"}); code != http.StatusConflict {
		t.Fatalf("failure without reason: %d", code)
	}
	f.must("POST", "/delivery-runs/"+runID+"/stops/"+str(s2["id"])+"/result", map[string]any{"status": "failed",
		"failure_reason": "magasin fermé"})
	if st := str(f.must("GET", "/orders/"+o2, nil)["status"]); st != "ready" {
		t.Fatalf("failed stop → order %s", st)
	}
	if st := str(f.must("GET", "/orders/"+o1, nil)["status"]); st != "delivered" {
		t.Fatalf("delivered stop → order %s", st)
	}
	if f.balance("C1") != 0 {
		t.Fatalf("money booked before closing: %d", f.balance("C1"))
	}
	run = f.must("POST", "/delivery-runs/"+runID+"/close", map[string]any{"counted_cash": 19000})
	rec := run["reconciliation"].(map[string]any)
	if n64(rec["cash_expected"]) != 20000 || n64(rec["cash_collected"]) != 19000 || n64(rec["cash_difference"]) != -1000 {
		t.Fatalf("reconciliation: %v", rec)
	}
	if len(rec["payments"].([]any)) != 1 || f.balance("C1") != -19000 || str(run["status"]) != "closed" {
		t.Fatalf("payments %v balance %d status %v", rec["payments"], f.balance("C1"), run["status"])
	}
	var pays int
	f.db.QueryRow(`SELECT COUNT(*) FROM documents WHERE doc_type = 'PAYMENT_IN' AND status = 'posted'`).Scan(&pays)
	if pays != 1 {
		t.Fatalf("PAYMENT_IN: %d", pays)
	}
	// The failed order can go on another run.
	f.must("POST", "/delivery-runs", map[string]any{"order_ids": []string{o2}})
}

// ---- CRM ------------------------------------------------------------------------------------------

func TestTaskAutoGenerationIdempotent(t *testing.T) {
	f := newAPIFx(t)
	f.setting("allow_negative_stock", "1")
	f.distProduct("P1", "Produit", "", 10000, 0, false)
	f.partner("C1", "customer", "Client en retard")
	f.partner("C2", "customer", "Client dormant")
	rep, _ := f.mkUser("rep1", RoleManagerID, nil)
	f.exec(`UPDATE partners SET rep_user_id = ? WHERE id = 'C1'`, rep)
	old := time.Now().AddDate(0, 0, -60).Format("2006-01-02")
	// C1: a credit invoice due 40 days ago, unpaid.
	f.postDoc(map[string]any{"doc_type": "SALE_INVOICE", "doc_date": old, "partner_id": "C1", "warehouse_id": f.wh,
		"payment_method": "credit", "due_date": time.Now().AddDate(0, 0, -40).Format("2006-01-02"),
		"lines": []any{line(strp("P1"), "P1", 1000, 10000)}})
	// C2: last purchase 60 days ago, paid.
	f.postDoc(map[string]any{"doc_type": "SALE_TICKET", "doc_date": old, "partner_id": "C2", "warehouse_id": f.wh,
		"payment_method": "cib", "lines": []any{line(strp("P1"), "P1", 1000, 10000)}})

	out := f.must("POST", "/crm/tasks/generate", map[string]any{"inactive_days": 30, "backorder": false})
	by := out["by_source"].(map[string]any)
	if n64(by["auto_overdue"]) != 1 || n64(by["auto_inactive"]) != 2 {
		t.Fatalf("first run: %v", out)
	}
	var assignee string
	f.db.QueryRow(`SELECT assignee_id FROM crm_tasks WHERE auto_key = 'overdue:C1'`).Scan(&assignee)
	if assignee != rep {
		t.Fatalf("overdue task assigned to %q, want the rep", assignee)
	}
	out = f.must("POST", "/crm/tasks/generate", map[string]any{"inactive_days": 30, "backorder": false})
	if n64(out["created"]) != 0 || n64(out["skipped"]) != 3 {
		t.Fatalf("second run must create nothing: %v", out)
	}
	// Done today → still not recreated (7-day quiet period).
	var tid string
	f.db.QueryRow(`SELECT id FROM crm_tasks WHERE auto_key = 'inactive:C2'`).Scan(&tid)
	f.must("POST", "/crm/tasks/"+tid+"/complete", map[string]any{"result": "commande prise"})
	out = f.must("POST", "/crm/tasks/generate", map[string]any{"inactive_days": 30, "backorder": false})
	if n64(out["created"]) != 0 {
		t.Fatalf("after completion: %v", out)
	}
	sum := f.must("GET", "/crm/tasks/summary", nil)
	if n64(sum["open"]) != 2 || n64(sum["today"]) != 2 {
		t.Fatalf("summary: %v", sum)
	}

	// Segments built on the same metrics.
	seg := f.must("GET", "/crm/segments/builtin:overdue/evaluate", nil)
	if n64(seg["count"]) != 1 || str(seg["items"].([]any)[0].(map[string]any)["partner_id"]) != "C1" {
		t.Fatalf("overdue segment: %v", seg["items"])
	}
	seg = f.must("GET", "/crm/segments/builtin:inactive_30/evaluate", nil)
	if n64(seg["count"]) != 2 {
		t.Fatalf("inactive segment: %v", seg["count"])
	}
	// KPIs and timeline of a customer.
	k := f.must("GET", "/partners/C1/kpis", nil)
	if n64(k["turnover_365d"]) != 10000 || n64(k["overdue_amount"]) != 10000 || n64(k["days_since_last_order"]) < 59 {
		t.Fatalf("kpis: %v", k)
	}
	tl := f.must("GET", "/partners/C1/timeline", nil)
	kinds := map[string]bool{}
	for _, it := range tl["items"].([]any) {
		kinds[str(it.(map[string]any)["kind"])] = true
	}
	if !kinds["document"] || !kinds["task"] {
		t.Fatalf("timeline kinds: %v", kinds)
	}
}

func TestScopeOwnFiltering(t *testing.T) {
	f := newAPIFx(t)
	f.distProduct("P1", "Produit", "", 10000, 0, false)
	role := f.must("POST", "/roles", map[string]any{"name": "Commercial", "scope": "own", "perms": map[string]bool{
		"orders.view": true, "orders.manage": true, "crm.view": true, "crm.edit": true, "partners.view": true}})
	repA, tokA := f.mkUser("repa", str(role["id"]), nil)
	repB, _ := f.mkUser("repb", str(role["id"]), nil)
	f.partner("PA", "customer", "Supérette A")
	f.partner("PB", "customer", "Supérette B")
	f.partner("S1", "supplier", "Labo")
	f.exec(`UPDATE partners SET rep_user_id = ? WHERE id = 'PA'`, repA)
	f.exec(`UPDATE partners SET rep_user_id = ? WHERE id = 'PB'`, repB)
	oa := f.must("POST", "/orders", map[string]any{"partner_id": "PA", "lines": []any{map[string]any{"product_id": "P1", "qty_milli": 1000}}})
	ob := f.must("POST", "/orders", map[string]any{"partner_id": "PB", "lines": []any{map[string]any{"product_id": "P1", "qty_milli": 1000}}})

	ids := func(out map[string]any) map[string]bool {
		m := map[string]bool{}
		for _, it := range out["items"].([]any) {
			x := it.(map[string]any)
			if v := str(x["id"]); v != "" {
				m[v] = true
			} else {
				m[str(x["partner_id"])] = true
			}
		}
		return m
	}
	_, ps := f.as(tokA, "GET", "/partners", nil, nil)
	got := ids(ps)
	if !got["PA"] || got["PB"] || !got["S1"] {
		t.Fatalf("rep A partners: %v", got)
	}
	_, os := f.as(tokA, "GET", "/orders", nil, nil)
	got = ids(os)
	if !got[str(oa["id"])] || got[str(ob["id"])] || n64(os["total"]) != 1 {
		t.Fatalf("rep A orders: %v", got)
	}
	if code, _ := f.as(tokA, "GET", "/orders/"+str(ob["id"]), nil, nil); code != http.StatusForbidden {
		t.Fatalf("other rep's order: %d", code)
	}
	if code, _ := f.as(tokA, "GET", "/partners/PB/timeline", nil, nil); code != http.StatusForbidden {
		t.Fatalf("other rep's timeline: %d", code)
	}
	if code, _ := f.as(tokA, "GET", "/partners/PA/timeline", nil, nil); code != http.StatusOK {
		t.Fatalf("own timeline: %d", code)
	}
	if code, _ := f.as(tokA, "POST", "/orders", map[string]any{"partner_id": "PB",
		"lines": []any{map[string]any{"product_id": "P1", "qty_milli": 1000}}}, nil); code != http.StatusForbidden {
		t.Fatalf("order for another rep's customer: %d", code)
	}
	_, seg := f.as(tokA, "POST", "/crm/segments/evaluate", map[string]any{"rules": map[string]any{}}, nil)
	got = ids(seg)
	if !got["PA"] || got["PB"] || len(got) != 1 {
		t.Fatalf("rep A segment: %v", got)
	}
	// crm.all_customers lifts the restriction.
	f.must("PUT", "/roles/"+str(role["id"]), map[string]any{"name": "Commercial", "scope": "own", "perms": map[string]bool{
		"orders.view": true, "orders.manage": true, "crm.view": true, "crm.edit": true, "partners.view": true,
		"crm.all_customers": true}})
	_, ps = f.as(tokA, "GET", "/partners", nil, nil)
	if got := ids(ps); !got["PB"] {
		t.Fatalf("all customers: %v", got)
	}
	_, os = f.as(tokA, "GET", "/orders", nil, nil)
	if n64(os["total"]) != 2 {
		t.Fatalf("all orders: %v", os["total"])
	}
	// Without orders.validate the rep cannot validate.
	if code, _ := f.as(tokA, "POST", "/orders/"+str(oa["id"])+"/validate", nil, nil); code != http.StatusForbidden {
		t.Fatalf("validate without right: %d", code)
	}
}

func TestPartnerCRMFieldsAndMessages(t *testing.T) {
	f := newAPIFx(t)
	f.setting("company_name", "Grossiste Elixir")
	route := f.must("POST", "/delivery-routes", map[string]any{"name": "Blida"})
	tag := f.must("POST", "/tags", map[string]any{"name": "VIP", "colour": "#FF0000"})
	p := f.must("POST", "/partners", map[string]any{"kind": "customer", "name": "Supérette Ennour",
		"phone": "0770 11 22 33", "email": "ennour@example.dz", "client_type": "supermarket", "crm_status": "prospect",
		"route_id": str(route["id"]), "wilaya": "09", "commune": "Blida", "latitude": 36.47, "longitude": 2.83,
		"license_no": "AGR-77", "whatsapp": "0770112233", "tag_ids": []string{str(tag["id"])}})
	if str(p["client_type"]) != "supermarket" || str(p["route_name"]) != "Blida" || len(p["tag_ids"].([]any)) != 1 ||
		str(p["email"]) != "ennour@example.dz" {
		t.Fatalf("partner CRM fields: %v", p)
	}
	// A PUT from the existing screens (no CRM keys) keeps them.
	p = f.must("PUT", "/partners/"+str(p["id"]), map[string]any{"kind": "customer", "name": "Supérette Ennour",
		"phone": "0770 11 22 33", "email": "contact@ennour.dz"})
	if str(p["client_type"]) != "supermarket" || str(p["wilaya"]) != "09" || str(p["email"]) != "contact@ennour.dz" {
		t.Fatalf("PUT dropped CRM fields: %v", p)
	}
	if code, _ := f.call("PUT", "/partners/"+str(p["id"]), map[string]any{"kind": "customer", "name": "X",
		"client_type": "martian"}); code != http.StatusBadRequest {
		t.Fatalf("bad client_type: %d", code)
	}
	list := f.must("GET", "/partners?client_type=supermarket&tag_id="+str(tag["id"]), nil)
	if len(list["items"].([]any)) != 1 {
		t.Fatalf("filters: %v", list["items"])
	}
	// Render a WhatsApp template.
	msg := f.must("POST", "/messages/render", map[string]any{"code": "payment_reminder", "partner_id": str(p["id"])})
	if !strings.Contains(str(msg["body"]), "Supérette Ennour") || !strings.Contains(str(msg["body"]), "Grossiste Elixir") ||
		!strings.HasPrefix(str(msg["wa_link"]), "https://wa.me/213770112233?text=") || len(msg["missing"].([]any)) != 0 {
		t.Fatalf("render: %v", msg)
	}
	f.must("POST", "/messages/log", map[string]any{"partner_id": str(p["id"]), "channel": "whatsapp",
		"template_code": "payment_reminder", "body": str(msg["body"]), "status": "sent"})
	if len(f.must("GET", "/messages/log?partner_id="+str(p["id"]), nil)["items"].([]any)) != 1 {
		t.Fatal("message log")
	}
	// No SMTP configured → clear error.
	code, out := f.call("POST", "/messages/send-email", map[string]any{"partner_id": str(p["id"]), "subject": "x", "body": "y"})
	if code != http.StatusConflict || out["smtp_not_configured"] != true {
		t.Fatalf("smtp: %d %v", code, out)
	}
	// The SMTP password never leaves the server.
	f.must("PUT", "/settings", map[string]string{"smtp_pass": "secret"})
	st := f.must("GET", "/settings", nil)
	if _, ok := st["smtp_pass"]; ok || str(st["smtp_pass_set"]) != "1" {
		t.Fatalf("settings leak: %v", st)
	}
	// Activities feed the timeline; contacts.
	f.must("POST", "/crm/activities", map[string]any{"partner_id": str(p["id"]), "type": "visit",
		"summary": "Présentation gamme", "next_action": "Rappeler pour commande", "next_action_due": today()})
	f.must("POST", "/partners/"+str(p["id"])+"/contacts", map[string]any{"name": "Dr Benali", "is_primary": true})
	tl := f.must("GET", "/partners/"+str(p["id"])+"/timeline", nil)
	if n64(tl["total"]) < 3 { // activity, follow-up task, message
		t.Fatalf("timeline: %v", tl)
	}
}
