# Seeds the dev server with realistic Algerian retail demo data.
# Usage: run the server first (server.exe), then: powershell -File scripts\seed-demo.ps1
$base = "http://127.0.0.1:8543/api/v1"

$wh = (Invoke-RestMethod "$base/warehouses").items[0].id
Write-Output "warehouse: $wh"

$products = @(
    @{barcode="6130229000015"; name="Coca-Cola 1L";              vat_rate=1900; price_retail=12000; purchase_price=8000},
    @{barcode="6130229000022"; name="Hamoud Boualem Selecto 1L"; vat_rate=1900; price_retail=11000; purchase_price=7500},
    @{barcode="6130104000019"; name="Eau Ifri 1.5L";             vat_rate=900;  price_retail=4500;  purchase_price=2800},
    @{barcode="6130455000012"; name="Huile Elio 1L";             vat_rate=900;  price_retail=65000; purchase_price=52000},
    @{barcode="6130455000029"; name="Huile Elio 5L";             vat_rate=900;  price_retail=310000; purchase_price=260000},
    @{barcode="6130788000016"; name="Sucre Skor 1kg";            vat_rate=900;  price_retail=13500; purchase_price=10500},
    @{barcode="6130788000023"; name="Farine Safina 1kg";         vat_rate=900;  price_retail=9000;  purchase_price=6500},
    @{barcode="6131234000018"; name="Café Facto Moulu 250g";     vat_rate=1900; price_retail=42000; purchase_price=33000},
    @{barcode="6131234000025"; name="Thé El Djazair 200g";       vat_rate=1900; price_retail=28000; purchase_price=21000},
    @{barcode="6132345000011"; name="Lait Candia UHT 1L";        vat_rate=900;  price_retail=14000; purchase_price=11500},
    @{barcode="6132345000028"; name="Yaourt Soummam nature x4";  vat_rate=900;  price_retail=18000; purchase_price=14000},
    @{barcode="6133456000014"; name="Pâtes Sim Spaghetti 500g";  vat_rate=900;  price_retail=8500;  purchase_price=6000},
    @{barcode="6133456000021"; name="Couscous Mama moyen 1kg";   vat_rate=900;  price_retail=16000; purchase_price=12500},
    @{barcode="6134567000017"; name="Savon Isis 125g";           vat_rate=1900; price_retail=6500;  purchase_price=4200},
    @{barcode="6134567000024"; name="Javel Eau de Crystal 1L";   vat_rate=1900; price_retail=9500;  purchase_price=6800},
    @{barcode="6135678000010"; name="Tomate Cevital 400g";       vat_rate=900;  price_retail=12500; purchase_price=9500},
    @{barcode="6135678000027"; name="Concentré Amor Benamor";    vat_rate=900;  price_retail=15500; purchase_price=12000},
    @{barcode="6136789000013"; name="Biscuit Bimo Choco";        vat_rate=1900; price_retail=5000;  purchase_price=3400},
    @{barcode="6136789000020"; name="Chips Krounchy 90g";        vat_rate=1900; price_retail=7000;  purchase_price=4800},
    @{barcode="6137890000016"; name="Danette Chocolat x4";       vat_rate=900;  price_retail=20000; purchase_price=16000}
)

$sup = Invoke-RestMethod -Method Post -Uri "$base/partners" -ContentType "application/json" `
    -Body (@{kind="supplier"; name="EURL Distribution Numidia"; nif="000216001234567"; phone="0550 12 34 56"} | ConvertTo-Json)
Write-Output "supplier: $($sup.id)"

$lines = @()
foreach ($p in $products) {
    try {
        $created = Invoke-RestMethod -Method Post -Uri "$base/products" -ContentType "application/json" -Body ($p | ConvertTo-Json)
        $qty = Get-Random -Minimum 12 -Maximum 120
        $lines += @{product_id=$created.id; description=$p.name; qty_milli=($qty*1000); unit_price=$p.purchase_price; vat_rate=$p.vat_rate}
        Write-Output "  + $($p.name) (x$qty)"
    } catch { Write-Output "  skip $($p.name): $($_.Exception.Message)" }
}

if ($lines.Count -gt 0) {
    $body = @{doc_type="PURCHASE_RECEIPT"; doc_date=(Get-Date -Format "yyyy-MM-dd"); partner_id=$sup.id; warehouse_id=$wh; lines=$lines} | ConvertTo-Json -Depth 5
    $rec = Invoke-RestMethod -Method Post -Uri "$base/documents" -ContentType "application/json" -Body $body
    $rec = Invoke-RestMethod -Method Post -Uri "$base/documents/$($rec.id)/post"
    Write-Output "receipt posted: $($rec.number) — $($rec.total_ttc) centimes TTC"
}
Write-Output "done."
