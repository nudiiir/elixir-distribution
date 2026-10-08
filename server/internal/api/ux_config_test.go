package api

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

func (f *apiFx) setting(k, v string) {
	f.exec(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, '2026-01-01')
		ON CONFLICT (key) DO UPDATE SET value = excluded.value`, k, v)
}

func TestConfigBarcodePrefix(t *testing.T) {
	f := newAPIFx(t)
	f.setting("barcode_prefix", "2909")
	for i := 0; i < 20; i++ {
		var out struct{ Barcode string }
		f.ok("POST", "/products/generate-barcode", nil, &out)
		if len(out.Barcode) != 13 || !strings.HasPrefix(out.Barcode, "2909") {
			t.Fatalf("barcode %q: want 13 digits starting with 2909", out.Barcode)
		}
		sum := 0
		for j, c := range out.Barcode[:12] {
			d := int(c - '0')
			if j%2 == 1 {
				d *= 3
			}
			sum += d
		}
		if want := byte('0' + (10-sum%10)%10); out.Barcode[12] != want {
			t.Fatalf("bad EAN-13 checksum in %s", out.Barcode)
		}
	}
	if normBarcodePrefix("ab1") != "200" || normBarcodePrefix("") != "200" || normBarcodePrefix("12345678") != "200" {
		t.Fatal("invalid prefixes must fall back to 200")
	}
}

func TestConfigGiftCardValidity(t *testing.T) {
	f := newAPIFx(t)
	f.setting("gift_card_validity_days", "30")
	var c GiftCard
	f.ok("POST", "/gift-cards", map[string]any{"amount": 5000}, &c)
	want := time.Now().AddDate(0, 0, 30).Format("2006-01-02")
	if c.ExpiresAt == nil || *c.ExpiresAt != want {
		t.Fatalf("expires_at = %v, want %s", c.ExpiresAt, want)
	}

	f.setting("gift_card_validity_days", "0")
	var c2 GiftCard
	f.ok("POST", "/gift-cards", map[string]any{"amount": 5000}, &c2)
	if c2.ExpiresAt != nil {
		t.Fatalf("validity 0 = unlimited, got %v", *c2.ExpiresAt)
	}

	// Expired card: redeem refused with a clear message.
	f.exec(`UPDATE gift_cards SET expires_at = '2020-01-31' WHERE id = ?`, c.ID)
	code, b := f.do("POST", "/gift-cards/code/"+c.Code+"/redeem", map[string]any{"amount": 100}, nil)
	if code != 409 || !strings.Contains(string(b), "expiré le 31/01/2020") {
		t.Fatalf("redeem expired: %d %s", code, b)
	}
}

func TestConfigCustomerGroup(t *testing.T) {
	f := newAPIFx(t)
	var g CustomerGroup
	f.ok("POST", "/customer-groups", map[string]any{"name": "Revendeurs", "price_level": "wholesale", "discount_pct": 500}, &g)
	if code, _ := f.do("POST", "/customer-groups", map[string]any{"name": "Revendeurs"}, nil); code != 409 {
		t.Fatalf("duplicate group name: %d", code)
	}
	if code, _ := f.do("POST", "/customer-groups", map[string]any{"name": "X", "discount_pct": 20000}, nil); code != 400 {
		t.Fatalf("discount > 100 %%: %d", code)
	}

	var p Partner
	f.ok("POST", "/partners", map[string]any{"kind": "customer", "name": "Ali", "group_id": g.ID}, &p)
	if p.GroupID == nil || *p.GroupID != g.ID || p.GroupDiscountPct != 500 ||
		p.GroupPriceLevel == nil || *p.GroupPriceLevel != "wholesale" || p.GroupName == nil {
		t.Fatalf("partner group fields: %+v", p)
	}
	// Update without group_id keeps the group; "" removes it.
	f.ok("PUT", "/partners/"+p.ID, map[string]any{"kind": "customer", "name": "Ali B"}, &p)
	if p.GroupID == nil {
		t.Fatal("absent group_id must keep the group")
	}
	var list struct{ Items []CustomerGroup }
	f.ok("GET", "/customer-groups", nil, &list)
	if len(list.Items) != 1 || list.Items[0].Members != 1 {
		t.Fatalf("groups: %+v", list.Items)
	}
	f.ok("PUT", "/partners/"+p.ID, map[string]any{"kind": "customer", "name": "Ali B", "group_id": ""}, &p)
	if p.GroupID != nil || p.GroupDiscountPct != 0 {
		t.Fatal("empty group_id must remove the group")
	}
	// Deleting a group detaches its customers.
	f.ok("PUT", "/partners/"+p.ID, map[string]any{"kind": "customer", "name": "Ali B", "group_id": g.ID}, &p)
	f.ok("DELETE", "/customer-groups/"+g.ID, nil, nil)
	f.ok("GET", "/partners/"+p.ID, nil, &p)
	if p.GroupID != nil {
		t.Fatal("group deleted: customer must leave it")
	}
}

func TestConfigNumberingAPI(t *testing.T) {
	f := newAPIFx(t)
	year := time.Now().Year()
	var row numberingRow
	f.ok("PUT", "/config/numbering/SALE_INVOICE", map[string]any{
		"prefix": "fac", "include_year": true, "digits": 5, "reset_yearly": true, "next_number": 124, "year": year,
	}, &row)
	if row.Prefix != "FAC" || row.NextNumber != 124 || row.Preview != "FAC-"+strconv.Itoa(year)+"-00124" {
		t.Fatalf("row: %+v", row)
	}
	if code, _ := f.do("PUT", "/config/numbering/SALE_INVOICE", map[string]any{
		"prefix": "FAC", "include_year": false, "digits": 5, "reset_yearly": true}, nil); code != 400 {
		t.Fatalf("reset without year: %d", code)
	}
	// Pretend 130 was issued: 125 is now refused.
	f.exec(`INSERT INTO documents (id, doc_type, status, doc_date, number, created_at, updated_at)
		VALUES ('X1', 'SALE_INVOICE', 'posted', ?, ?, '2026-01-01', '2026-01-01')`,
		strconv.Itoa(year)+"-01-02", "FAC-"+strconv.Itoa(year)+"-00130")
	code, b := f.do("PUT", "/config/numbering/SALE_INVOICE", map[string]any{
		"prefix": "FAC", "include_year": true, "digits": 5, "reset_yearly": true, "next_number": 125, "year": year}, nil)
	if code != 409 || !strings.Contains(string(b), "au moins 131") {
		t.Fatalf("lowering below issued: %d %s", code, b)
	}
	var all struct{ Items []numberingRow }
	f.ok("GET", "/config/numbering?year="+strconv.Itoa(year), nil, &all)
	if len(all.Items) != 14 {
		t.Fatalf("%d types", len(all.Items))
	}
	for _, it := range all.Items {
		if it.DocType == "SALE_INVOICE" && (it.MinNext != 131 || it.NextNumber != 131) {
			t.Fatalf("invoice row: %+v", it)
		}
		if it.DocType == "QUOTE" && it.Preview != "DV-"+strconv.Itoa(year)+"-000001" {
			t.Fatalf("quote default preview: %s", it.Preview)
		}
	}
}

