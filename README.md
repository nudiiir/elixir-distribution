# Elixir Distribution

Management software for distributors, wholesalers and shops in Algeria: orders, stock, purchasing, invoicing, delivery rounds, cash collection, customer relations and an online store, in one offline-first system that runs on the shop's own PCs.

> **Meta Global AI Developer Hackathon (Oct 26 – Nov 4, 2026): what existed before, and what is new**
>
> Elixir Distribution is an existing product from Elixir (Algeria). This repository keeps its **real development history since 2026-08-30**.
>
> - **Before the hackathon:** everything up to the tag **[`pre-hackathon`](../../tree/pre-hackathon)** (release v0.4.0, Oct 9, 2026).
> - **During the hackathon:** every commit after that tag. The first ones are publication housekeeping only (license, configurable endpoints, English documentation); no product features. Hackathon features are listed in [Built during the hackathon](#built-during-the-hackathon).
> - To see exactly what is new, compare **`pre-hackathon...main`**.
>
> For publication, the history was rewritten to remove private cloud addresses, old compiled binaries and sector-specific sample data, and the commit messages were translated to English. Commit dates and authors are unchanged.

## Built during the hackathon

_In progress. Each feature built with Meta's models during the event will be listed here, with the commits that introduce it._

## What it does (v0.4.0, before the hackathon)

- **Point of sale:** barcode and weighed items, promotions, gift cards, split payments, parked tickets, ESC/POS receipts.
- **Stock:** multiple warehouses, lots and expiry (FEFO), inventory counts, transfers, reorder suggestions, weighted average cost.
- **Purchasing:** purchase orders, goods receipts with free units and landed costs, supplier price history, supplier-invoice scanning into draft receipts.
- **Sales documents:** quotes, orders, delivery notes, invoices and credit notes that follow Algerian invoicing rules (tax IDs, gapless numbering, stamp duty, amounts in words in French and Arabic).
- **Distribution:** customer order board, credit checks, scan-based picking, delivery rounds and route sheets, cash collection with reconciliation, negotiated prices, free-unit offers and quotas.
- **Customer relations:** 360° customer profile, tasks, automatic payment reminders, segments, sales reps and targets, WhatsApp/SMS/e-mail templates.
- **Online store:** the shop publishes a catalog snapshot to a hosted storefront; web orders come back into the order board.
- **Analytics:** a drag-and-drop dashboard and an Explorer that answers questions about sales, stock and customers.
- **Operations:** roles and permissions, audit log, backups with guided restore, auto-update, Windows service.

The interface is in French (with Arabic documents), because it is used by Algerian businesses.

## Architecture

Client–server and offline-first. One PC in the shop runs the server; the other PCs and phones are clients.

```
┌──────────────────── Shop LAN ────────────────────┐        ┌──────── Cloud (optional) ────────┐
│  server.exe  (Go, Windows service)               │  WSS   │  relay (outbound tunnel)         │
│   ├─ SQLite (WAL), owned by the server only      │───────►│  AI assistant service            │
│   ├─ REST API  /api/v1                           │        │  invoice-scanning service        │
│   └─ posting engine: documents → stock & ledgers │        │  online storefront               │
│                                                  │        └──────────────────────────────────┘
│  Flutter desktop clients  (Windows) × N ─────────┤                       ▲
└──────────────────────────────────────────────────┘                       │
                     Flutter mobile app (same codebase) ───────────────────┘  (or directly on the LAN)
```

- **Server:** Go, single static executable, SQLite in WAL mode, embedded migrations. All writes go through one posting engine, so stock and account balances always come from immutable ledger entries. See [docs/SCHEMA.md](docs/SCHEMA.md).
- **Clients:** Flutter for Windows desktop and Android, sharing models, API client and most screens.
- **Cloud:** optional. The server opens an outbound connection to a relay, so phones and cloud services can reach a shop without any port forwarding. The cloud services are not part of this repository.

## Quickstart

Server (Go 1.23+). It listens on `:8543`, creates and migrates `data/elixir.db`, and seeds a default warehouse and the user `admin` / `admin`:

```bash
cd server
go build -o server.exe ./cmd/server
./server.exe
```

Desktop client (Flutter 3.x, Windows):

```bash
cd app
flutter run -d windows
```

Tests:

```bash
cd server
go test ./...
```

### Optional cloud services

Cloud features stay off unless you point them at your own deployment:

| Variable | Service |
|---|---|
| `STOCK_RELAY_BASE` | relay that tunnels the shop's API (e.g. `https://relay.example.com`) |
| `STOCK_LLM_URL` | AI assistant service |
| `STOCK_INVOICE_URL` | invoice-scanning service |
| `STOCK_WEB_URL` | online storefront service |

## Repository layout

```
server/      Go API server: SQLite, migrations, posting engine, analytics, relay client
app/         Flutter app: Windows desktop and Android from one codebase
docs/        SCHEMA.md (data model and posting rules), API_DISTRIBUTION.md (distribution API)
installer/   Inno Setup scripts for the server and client installers
scripts/     release build and demo-data seeding
```

## License

[GNU Affero General Public License v3.0](LICENSE). You may use, study, modify and share this software; if you run a modified version as a network service, you must publish its source under the same license.

Copyright © 2026 Elixir (Algeria).
