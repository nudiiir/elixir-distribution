package api

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"elixir/server/internal/analytics"
)

type Server struct {
	db        *sql.DB
	secret    []byte
	dbPath    string
	presence  *presenceRegistry
	analytics *analytics.Engine
}

func New(db *sql.DB, dbPath string, eng *analytics.Engine) http.Handler {
	secret, err := ensureAuthSecret(db)
	if err != nil {
		log.Fatalf("auth secret: %v", err)
	}
	s := &Server{db: db, secret: secret, dbPath: dbPath, presence: newPresenceRegistry(), analytics: eng}
	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	r.Get("/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	r.Post("/api/v1/auth/login", s.login)
	// The phone pairs with a one-time code, so this cannot require a session.
	r.Post("/api/v1/auth/pair", s.pairExchange)

	r.Route("/api/v1", func(r chi.Router) {
		r.Use(s.authMiddleware)

		r.Get("/auth/me", s.me)

		r.Get("/users", s.listUsers)
		r.Post("/users", s.createUser)
		r.Put("/users/{id}", s.updateUser)

		r.Get("/products", s.listProducts)
		r.Post("/products", s.createProduct)
		r.Post("/products/generate-barcode", s.generateBarcode)
		r.Get("/products/{id}", s.getProduct)
		r.Put("/products/{id}", s.updateProduct)
		r.Delete("/products/{id}", s.deactivateProduct)
		r.Get("/products/{id}/fiche", s.ficheProduct)
		r.Post("/products/{id}/split", s.splitProduct)

		r.Get("/partners", s.listPartners)
		r.Post("/partners", s.createPartner)
		r.Get("/partners/{id}", s.getPartner)
		r.Put("/partners/{id}", s.updatePartner)
		r.Get("/partners/{id}/balance", s.partnerBalance)
		r.Get("/partners/{id}/open-items", s.partnerOpenItems)

		r.Get("/warehouses", s.listWarehouses)
		r.Post("/warehouses", s.createWarehouse)

		r.Get("/documents", s.listDocuments)
		r.Post("/documents", s.createDocument)
		r.Get("/documents/{id}", s.getDocument)
		r.Put("/documents/{id}", s.updateDocument)
		r.Post("/documents/{id}/post", s.postDocument)
		r.Post("/documents/{id}/cancel", s.cancelDocument)
		r.Post("/documents/{id}/void", s.voidDocument)
		r.Post("/documents/{id}/close", s.closeOrder)
		r.Get("/documents/{id}/match", s.matchDocument)

		r.Get("/purchases/last-prices", s.lastSupplierPrices)

		r.Get("/stock/levels", s.stockLevels)
		r.Get("/stock/movements", s.stockMovements)
		r.Get("/stock/verify", s.verifyStock)

		r.Get("/settings", s.getSettings)
		r.Put("/settings", s.putSettings)

		r.Get("/caisse/current", s.caisseCurrent)
		r.Post("/caisse/open", s.caisseOpen)
		r.Get("/caisse/report", s.caisseReport)
		r.Post("/caisse/close", s.caisseClose)
		r.Get("/caisse/sessions", s.caisseSessions)

		r.Get("/backups", s.listBackups)
		r.Post("/backups/run", s.runBackupNow)

		r.Get("/gift-cards", s.listGiftCards)
		r.Post("/gift-cards", s.createGiftCard)
		r.Get("/gift-cards/code/{code}", s.getGiftCard)
		r.Post("/gift-cards/code/{code}/redeem", s.redeemGiftCard)
		r.Post("/gift-card-uses/{id}/refund", s.refundGiftCardUse)
		r.Post("/gift-cards/{id}/cancel", s.cancelGiftCard)

		r.Get("/categories", s.listCategories)
		r.Post("/categories", s.createCategory)
		r.Put("/categories/{id}", s.updateCategory)
		r.Delete("/categories/{id}", s.deleteCategory)

		r.Get("/units", s.listUnits)
		r.Post("/units", s.createUnits)
		r.Get("/units/serial/{serial}", s.getUnitBySerial)
		r.Post("/units/sell", s.sellUnit)
		r.Put("/units/{id}", s.updateUnit)
		r.Delete("/units/{id}", s.deleteUnit)

		r.Get("/repairs", s.listRepairs)
		r.Post("/repairs", s.createRepair)
		r.Put("/repairs/{id}", s.updateRepair)

		r.Get("/installment-plans", s.listInstallmentPlans)
		r.Post("/installment-plans", s.createInstallmentPlan)
		r.Delete("/installment-plans/{id}", s.deleteInstallmentPlan)
		r.Post("/installment-dues/{id}/pay", s.payInstallmentDue)
		r.Get("/installments/overdue", s.overdueInstallments)

		r.Get("/lots", s.listLots)
		r.Post("/lots", s.createLot)
		r.Put("/lots/{id}", s.updateLot)
		r.Delete("/lots/{id}", s.deleteLot)

		r.Get("/reports/summary", s.reportSummary)
		r.Get("/reports/breakdown", s.reportBreakdown)

		r.Get("/audit", s.listAudit)

		r.Get("/templates", s.listTemplates)
		r.Post("/templates", s.createTemplate)
		r.Get("/templates/{id}", s.getTemplate)
		r.Put("/templates/{id}", s.updateTemplate)
		r.Delete("/templates/{id}", s.deleteTemplate)
		r.Post("/templates/{id}/default", s.setDefaultTemplate)

		r.Post("/presence", s.presenceBeat)
		r.Get("/presence", s.presenceList)

		r.Get("/analytics/schema", s.analyticsSchema)
		r.Get("/analytics/gallery", s.analyticsGallery)
		r.Post("/analytics/ask", s.analyticsAsk)
		r.Post("/analytics/query", s.analyticsQuery)
		r.Post("/analytics/query/batch", s.analyticsBatch)
		r.Get("/analytics/reports", s.listReports)
		r.Post("/analytics/reports", s.createReport)
		r.Put("/analytics/reports/{id}", s.updateReport)
		r.Delete("/analytics/reports/{id}", s.deleteReport)
		r.Get("/analytics/dashboards", s.listDashboards)
		r.Post("/analytics/dashboards", s.createDashboard)
		r.Put("/analytics/dashboards/{id}", s.updateDashboard)
		r.Delete("/analytics/dashboards/{id}", s.deleteDashboard)

		r.Get("/cloud/status", s.cloudStatus)
		r.Post("/cloud/connect", s.cloudConnect)
		r.Post("/cloud/disconnect", s.cloudDisconnect)
		r.Post("/cloud/pair", s.cloudPair)
	})
	return r
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func decode(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}
