# Elixir Software — Retail Management for Algeria

Management software for Algerian retail businesses: a complete commerce suite (stock, sales, purchases, invoicing, warehouses, caisse) plus the three differentiators no competitor offers — delivery-company integration, invoice scanning, and B2B ordering.

## Vision

Algerian shops today sell both walk-in and online (Facebook/Instagram + COD delivery), and manage the two in different places with different tools. This software is one central system:

1. **E-commerce / delivery integration** — create parcels, print labels, track, and reconcile COD money with all major Algerian carriers, from the same stock pool as the counter. The ~100 DZ carriers collapse into ~4 platform APIs:
   - **Yalidine platform** (`api.yalidine.app/v1`, `X-API-ID`/`X-API-TOKEN`) → Yalidine, Guepex, Yalitec, Easy & Speed, Economiqua, We Can. Webhooks + label PDFs + fees API.
   - **EcoTrack** (Bearer token on `https://<tenant>.ecotrack.dz/api/v1`) → ~80 tenant carriers (DHD, Anderson, Coyote, 48H, UPS/Conexlog…). Polling only.
   - **ZR Express / Procolis** (token+key; new platform adds webhooks + treasury API — best COD reconciliation surface).
   - **Maystro** (Token auth, webhooks, fulfillment).
   - COD reconciliation = expected-payout ledger (delivered → +COD − fees − ~1.5% commission; returned → −100–200 DA RTO fee) matched against versement batches.
2. **Invoice scanning** — scan a paper supplier invoice → OCR (cloud) → draft purchase entry matched line-by-line to the catalog → confirm → stock + cost prices updated.
3. **B2B ordering** — purchase orders to distributors, later a live marketplace module.

Secondary wedges: décret 05-468-compliant invoices (NIF/NIS/RC/AI, gapless sequential numbering, montant en lettres FR/AR), pre-filled G50/G50A, timbre auto-calc (exempt on e-payment), QR e-payment (LF 2020 art. 111 obligation, TPE shortage), pre-loaded product catalog from GS1 Algeria / Mantooj (barcodes mandatory since 2023).

## Architecture

Client–server, offline-first. One PC in the shop runs the server; other PCs and phones are clients.

```
┌─────────────── Shop LAN ───────────────┐        ┌───────── Cloud (thin) ─────────┐
│  server.exe (Go, Windows service)      │  WS ↗  │  relay (outbound tunnel, same  │
│   ├─ SQLite (WAL) — single owner       │────────│  pattern as Elixir agent)      │
│   ├─ REST/WebSocket API                │        │  OCR service (invoice scan)    │
│   └─ delivery-API clients (outbound)   │        │  shared product catalog        │
│                                        │        │  licensing / updates           │
│  client.exe (Flutter Windows) ×N ──────┤        └────────────────────────────────┘
└────────────────────────────────────────┘                     ↑
                    mobile app (Flutter, same codebase) ───────┘ (or LAN direct)
```

## Tech stack (decided 2026-08-29)

| Layer | Choice | Why |
|---|---|---|
| Desktop client | **Flutter Windows** (Windows 10+) | AOT native, no WebView/Electron, ~1–2s cold start on HDDs, fine on 4GB RAM; shares Dart code with the mobile app. Grids: Syncfusion DataGrid (community license) or pluto_grid_plus. |
| Mobile app | **Flutter** (same monorepo) | Shared models, API client, business logic, most screens. |
| Server | **Go**, single static .exe, Windows service | ~10MB binary, ~10–30MB RAM, trivial cross-compile. |
| Database | **SQLite (WAL mode)**, owned exclusively by the server process | All clients go through the API, so LAN concurrency is a non-issue. Zero admin, one file to back up. |
| Backups | Nightly `VACUUM INTO` second disk/USB + Litestream 0.5.x → cloud when online | |
| Installers | Inno Setup (client + server) | No MSIX (cert + OS-version friction). |
| Auto-update | **Velopack** (or the proven DIY GitHub-Releases + silent Inno reinstall pattern) | Squirrel.Windows is dead; Velopack is its maintained successor with delta updates. Server and client versioned independently; clients tolerate ±1 API version skew. |

Explicitly rejected: Electron/Compose Desktop (RAM), web-app-in-browser (requirement), bundled PostgreSQL/Firebird (admin surface for nothing at shop scale), MSIX, Windows 7 support (would force Tauri; revisit only if field reality demands it).

## Build order

- **P0 — base suite**: server + schema, Flutter desktop shell, products/stock/sales/purchases/caisse, 05-468 invoices, installer + updater.
- **P1 — delivery module**: Yalidine client → EcoTrack generic client → ZR. Confirmation queue + COD ledger.
- **P2 — invoice scanning** + pre-loaded GS1/Mantooj catalog.
- **P3 — mobile app** + compliance extras (G50, QR payment).
- **P4 — B2B ordering/marketplace.**

## Repository layout & quickstart

```
server/   Go API server (SQLite WAL, embedded migrations, posting engine)
app/      Flutter app — Windows desktop + Android from one codebase
docs/     SCHEMA.md — data model + posting rules (read this first)
```

Run the server (Go 1.23+, listens on :8543, creates/migrates `data/elixir.db`, seeds warehouse "Magasin" + user admin/admin):

```bash
cd server && go build -o server.exe ./cmd/server && ./server.exe
```

Run the desktop client:

```bash
cd app && flutter run -d windows
```

API base: `http://<server>:8543/api/v1` — `products`, `partners` (+`/{id}/balance`), `warehouses`, `documents` (+`/{id}/post`, `/{id}/cancel`), `stock/levels`. Documents are created as drafts and become immutable when posted; see [docs/SCHEMA.md](docs/SCHEMA.md).

## Useful references

- Open-source DZ carrier maps (wilaya/commune data, status normalization, per-carrier quirks): [dzship](https://github.com/DZBuild-com/dzship) (MIT), [vargo](https://github.com/KaziSTM/vargo), [CourierDZ](https://github.com/PiteurStudio/CourierDZ)
- Main modern competitor to benchmark: [Almawarid](https://almawarid.app) (cloud+offline POS, G50 export, subscriptions — no delivery integration)
