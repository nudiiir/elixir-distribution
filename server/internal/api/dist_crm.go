package api

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

func (s *Server) routesCRM(r chi.Router) {
	r.Get("/partners/{id}/contacts", s.listContacts)
	r.Post("/partners/{id}/contacts", s.createContact)
	r.Put("/partner-contacts/{id}", s.updateContact)
	r.Delete("/partner-contacts/{id}", s.deleteContact)

	r.Get("/tags", s.listTags)
	r.Post("/tags", s.createTag)
	r.Put("/tags/{id}", s.updateTag)
	r.Delete("/tags/{id}", s.deleteTag)
	r.Put("/partners/{id}/tags", s.putPartnerTags)

	r.Get("/partners/{id}/files", s.listPartnerFiles)
	r.Post("/partners/{id}/files", s.addPartnerFile)
	r.Get("/partners/{id}/files/{fid}", s.getPartnerFile)
	r.Delete("/partners/{id}/files/{fid}", s.deletePartnerFile)

	r.Get("/partners/{id}/timeline", s.partnerTimeline)
	r.Get("/partners/{id}/kpis", s.partnerKPIs)
	r.Get("/partners/{id}/credit", s.partnerCredit)

	r.Get("/crm/activities", s.listActivities)
	r.Post("/crm/activities", s.createActivity)
	r.Put("/crm/activities/{id}", s.updateActivity)
	r.Delete("/crm/activities/{id}", s.deleteActivity)

	r.Get("/crm/tasks", s.listTasks)
	r.Get("/crm/tasks/summary", s.tasksSummary)
	r.Post("/crm/tasks", s.createTask)
	r.Post("/crm/tasks/generate", s.generateTasks)
	r.Put("/crm/tasks/{id}", s.updateTask)
	r.Post("/crm/tasks/{id}/complete", s.completeTask)
	r.Post("/crm/tasks/{id}/cancel", s.cancelTask)

	r.Get("/crm/segments", s.listSegments)
	r.Post("/crm/segments", s.createSegment)
	r.Put("/crm/segments/{id}", s.updateSegment)
	r.Delete("/crm/segments/{id}", s.deleteSegment)
	r.Post("/crm/segments/evaluate", s.evaluateSegmentRules)
	r.Get("/crm/segments/{id}/evaluate", s.evaluateSegment)

	r.Get("/crm/rep-targets", s.listRepTargets)
	r.Put("/crm/rep-targets", s.putRepTarget)
	r.Get("/crm/reps/performance", s.repPerformance)
}

// partnerAccess checks the partner exists and the caller may see it.
func (s *Server) partnerAccess(w http.ResponseWriter, r *http.Request, id string) bool {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM partners WHERE id = ?`, id).Scan(&n)
	if n == 0 {
		writeErr(w, http.StatusNotFound, "partner not found")
		return false
	}
	if !s.canSeePartner(r, id) {
		writeErr(w, http.StatusForbidden, "ce client n'est pas dans votre portefeuille")
		return false
	}
	return true
}

func localToday() string { return time.Now().Format("2006-01-02") }

func daysAgo(n int) string { return time.Now().AddDate(0, 0, -n).Format("2006-01-02") }

// ---- Contacts -----------------------------------------------------------------------

type PartnerContact struct {
	ID        string `json:"id"`
	PartnerID string `json:"partner_id"`
	Name      string `json:"name"`
	Role      string `json:"role"`
	Phone     string `json:"phone"`
	Whatsapp  string `json:"whatsapp"`
	Email     string `json:"email"`
	IsPrimary bool   `json:"is_primary"`
	Notes     string `json:"notes"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

const contactSelect = `SELECT id, partner_id, name, role, phone, whatsapp, email, is_primary, notes, created_at, updated_at
	FROM partner_contacts`

func scanContact(row interface{ Scan(...any) error }) (PartnerContact, error) {
	var c PartnerContact
	var p int
	err := row.Scan(&c.ID, &c.PartnerID, &c.Name, &c.Role, &c.Phone, &c.Whatsapp, &c.Email, &p, &c.Notes,
		&c.CreatedAt, &c.UpdatedAt)
	c.IsPrimary = p == 1
	return c, err
}

func (s *Server) listContacts(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "partners.view") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	rows, err := s.db.Query(contactSelect+` WHERE partner_id = ? ORDER BY is_primary DESC, name`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []PartnerContact{}
	for rows.Next() {
		c, err := scanContact(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, c)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type contactInput struct {
	Name      string `json:"name"`
	Role      string `json:"role"`
	Phone     string `json:"phone"`
	Whatsapp  string `json:"whatsapp"`
	Email     string `json:"email"`
	IsPrimary bool   `json:"is_primary"`
	Notes     string `json:"notes"`
}

func (s *Server) saveContact(w http.ResponseWriter, r *http.Request, partnerID, id string) {
	var in contactInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeFieldErr(w, http.StatusBadRequest, "name", "le nom du contact est obligatoire")
		return
	}
	status := http.StatusOK
	if !s.inTx(w, func(tx *sql.Tx) error {
		now := domain.NowISO()
		if in.IsPrimary {
			if _, err := tx.Exec(`UPDATE partner_contacts SET is_primary = 0 WHERE partner_id = ?`, partnerID); err != nil {
				return err
			}
		}
		if id == "" {
			id, status = domain.NewID(), http.StatusCreated
			_, err := tx.Exec(`INSERT INTO partner_contacts (id, partner_id, name, role, phone, whatsapp, email, is_primary,
				notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, id, partnerID,
				strings.TrimSpace(in.Name), strings.TrimSpace(in.Role), strings.TrimSpace(in.Phone),
				strings.TrimSpace(in.Whatsapp), strings.TrimSpace(in.Email), b2i(in.IsPrimary), in.Notes, now, now)
			return err
		}
		res, err := tx.Exec(`UPDATE partner_contacts SET name=?, role=?, phone=?, whatsapp=?, email=?, is_primary=?,
			notes=?, updated_at=? WHERE id=?`, strings.TrimSpace(in.Name), strings.TrimSpace(in.Role),
			strings.TrimSpace(in.Phone), strings.TrimSpace(in.Whatsapp), strings.TrimSpace(in.Email),
			b2i(in.IsPrimary), in.Notes, now, id)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return &domain.NotFoundError{Msg: "contact introuvable"}
		}
		return nil
	}) {
		return
	}
	c, err := scanContact(s.db.QueryRow(contactSelect+` WHERE id = ?`, id))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, c)
}

func (s *Server) createContact(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit", "partners.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	s.saveContact(w, r, id, "")
}

func (s *Server) updateContact(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit", "partners.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	var partnerID string
	if err := s.db.QueryRow(`SELECT partner_id FROM partner_contacts WHERE id = ?`, id).Scan(&partnerID); err != nil {
		writeErr(w, http.StatusNotFound, "contact introuvable")
		return
	}
	if !s.partnerAccess(w, r, partnerID) {
		return
	}
	s.saveContact(w, r, partnerID, id)
}

func (s *Server) deleteContact(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit", "partners.edit") {
		return
	}
	s.deleteRow(w, r, "partner_contacts", "contact introuvable", "")
}

// ---- Tags ------------------------------------------------------------------------------

type Tag struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Colour        string `json:"colour"`
	PartnersCount int    `json:"partners_count"`
	CreatedAt     string `json:"created_at"`
	UpdatedAt     string `json:"updated_at"`
}

const tagSelect = `SELECT t.id, t.name, t.colour, (SELECT COUNT(*) FROM partner_tags pt WHERE pt.tag_id = t.id),
	t.created_at, t.updated_at FROM tags t`

func scanTag(row interface{ Scan(...any) error }) (Tag, error) {
	var t Tag
	err := row.Scan(&t.ID, &t.Name, &t.Colour, &t.PartnersCount, &t.CreatedAt, &t.UpdatedAt)
	return t, err
}

func (s *Server) listTags(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "partners.view") {
		return
	}
	rows, err := s.db.Query(tagSelect + ` ORDER BY t.name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Tag{}
	for rows.Next() {
		t, err := scanTag(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, t)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) saveTag(w http.ResponseWriter, r *http.Request, id string) {
	if !s.need(w, r, "crm.edit", "partners.edit") {
		return
	}
	var in struct {
		Name   string `json:"name"`
		Colour string `json:"colour"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		writeFieldErr(w, http.StatusBadRequest, "name", "le nom de l'étiquette est obligatoire")
		return
	}
	if in.Colour == "" {
		in.Colour = "#00CC99"
	}
	now := domain.NowISO()
	status := http.StatusOK
	var err error
	if id == "" {
		id, status = domain.NewID(), http.StatusCreated
		_, err = s.db.Exec(`INSERT INTO tags (id, name, colour, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
			id, in.Name, in.Colour, now, now)
	} else {
		var res sql.Result
		res, err = s.db.Exec(`UPDATE tags SET name=?, colour=?, updated_at=? WHERE id=?`, in.Name, in.Colour, now, id)
		if err == nil {
			if n, _ := res.RowsAffected(); n == 0 {
				writeErr(w, http.StatusNotFound, "étiquette introuvable")
				return
			}
		}
	}
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			writeFieldErr(w, http.StatusConflict, "name", "une étiquette porte déjà ce nom")
			return
		}
		writeDomainErr(w, err)
		return
	}
	t, _ := scanTag(s.db.QueryRow(tagSelect+` WHERE t.id = ?`, id))
	writeJSON(w, status, t)
}

func (s *Server) createTag(w http.ResponseWriter, r *http.Request) { s.saveTag(w, r, "") }
func (s *Server) updateTag(w http.ResponseWriter, r *http.Request) {
	s.saveTag(w, r, chi.URLParam(r, "id"))
}
func (s *Server) deleteTag(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit", "partners.edit") {
		return
	}
	s.deleteRow(w, r, "tags", "étiquette introuvable", "")
}

func (s *Server) putPartnerTags(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit", "partners.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	var in struct {
		TagIDs []string `json:"tag_ids"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := s.setPartnerTags(id, in.TagIDs); msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	s.getPartnerByID(w, id)
}

// ---- Files ------------------------------------------------------------------------------

type PartnerFile struct {
	ID        string  `json:"id"`
	PartnerID string  `json:"partner_id"`
	Kind      string  `json:"kind"`
	Name      string  `json:"name"`
	Mime      string  `json:"mime"`
	Size      int64   `json:"size"`
	ExpiresAt *string `json:"expires_at"`
	Expired   bool    `json:"expired"`
	Notes     string  `json:"notes"`
	CreatedAt string  `json:"created_at"`
}

var partnerFileKinds = map[string]bool{"license": true, "registre": true, "nif": true, "nis": true,
	"contract": true, "id": true, "other": true}

func (s *Server) listPartnerFiles(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "partners.view") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	rows, err := s.db.Query(`SELECT id, partner_id, kind, name, mime, length(data), expires_at, notes, created_at
		FROM partner_files WHERE partner_id = ? ORDER BY created_at DESC`, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []PartnerFile{}
	today := localToday()
	for rows.Next() {
		var f PartnerFile
		if err := rows.Scan(&f.ID, &f.PartnerID, &f.Kind, &f.Name, &f.Mime, &f.Size, &f.ExpiresAt, &f.Notes, &f.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		f.Expired = f.ExpiresAt != nil && *f.ExpiresAt != "" && *f.ExpiresAt < today
		items = append(items, f)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// addPartnerFile: POST /partners/{id}/files?name=&kind=&expires_at=&notes= with
// the raw file as body (≤ 5 Mo), like document attachments.
func (s *Server) addPartnerFile(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit", "partners.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	qp := r.URL.Query()
	name := strings.TrimSpace(filepath.Base(strings.ReplaceAll(qp.Get("name"), "\\", "/")))
	if name == "" || name == "." || name == "/" {
		writeErr(w, http.StatusBadRequest, "nom de fichier requis (?name=)")
		return
	}
	kind := qp.Get("kind")
	if kind == "" {
		kind = "other"
	}
	if !partnerFileKinds[kind] {
		writeErr(w, http.StatusBadRequest, "type de pièce invalide (license, registre, nif, nis, contract, id, other)")
		return
	}
	exp := qp.Get("expires_at")
	if exp != "" && !validDate(&exp) {
		writeErr(w, http.StatusBadRequest, "expires_at au format AAAA-MM-JJ")
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxAttachment+1))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(data) == 0 {
		writeErr(w, http.StatusBadRequest, "fichier vide")
		return
	}
	if len(data) > maxAttachment {
		writeErr(w, http.StatusRequestEntityTooLarge, "fichier trop volumineux (5 Mo maximum)")
		return
	}
	mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(name)))
	if mt == "" {
		mt = http.DetectContentType(data)
	}
	f := PartnerFile{ID: domain.NewID(), PartnerID: id, Kind: kind, Name: name, Mime: mt, Size: int64(len(data)),
		Notes: qp.Get("notes"), CreatedAt: domain.NowISO()}
	if exp != "" {
		f.ExpiresAt = &exp
	}
	if _, err := s.db.Exec(`INSERT INTO partner_files (id, partner_id, kind, name, mime, data, expires_at, notes, created_by, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, f.ID, id, kind, name, mt, data, nullIfEmpty(exp), f.Notes,
		nullIfEmpty(uidOf(r)), f.CreatedAt); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "partner.file", "partner", id, "pièce « "+name+" » ("+kind+")")
	writeJSON(w, http.StatusCreated, f)
}

func (s *Server) getPartnerFile(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "partners.view") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	var name, mt string
	var data []byte
	if err := s.db.QueryRow(`SELECT name, mime, data FROM partner_files WHERE id = ? AND partner_id = ?`,
		chi.URLParam(r, "fid"), id).Scan(&name, &mt, &data); err != nil {
		writeErr(w, http.StatusNotFound, "pièce introuvable")
		return
	}
	w.Header().Set("Content-Type", mt)
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": name}))
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

func (s *Server) deletePartnerFile(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit", "partners.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	fid := chi.URLParam(r, "fid")
	res, err := s.db.Exec(`DELETE FROM partner_files WHERE id = ? AND partner_id = ?`, fid, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "pièce introuvable")
		return
	}
	s.audit(r, "partner.file_delete", "partner", id, "pièce supprimée")
	writeJSON(w, http.StatusOK, map[string]any{"deleted": fid})
}

// ---- Activities ---------------------------------------------------------------------------

type Activity struct {
	ID          string   `json:"id"`
	PartnerID   string   `json:"partner_id"`
	PartnerName string   `json:"partner_name"`
	Type        string   `json:"type"`
	Outcome     string   `json:"outcome"`
	Summary     string   `json:"summary"`
	At          string   `json:"at"`
	DurationMin int64    `json:"duration_min"`
	UserID      *string  `json:"user_id"`
	UserName    string   `json:"user_name"`
	OrderID     *string  `json:"order_id"`
	OrderNumber *string  `json:"order_number"`
	DocumentID  *string  `json:"document_id"`
	Latitude    *float64 `json:"latitude"`
	Longitude   *float64 `json:"longitude"`
	NextAction  string   `json:"next_action"`
	CreatedAt   string   `json:"created_at"`
	UpdatedAt   string   `json:"updated_at"`
}

var activityTypes = map[string]string{"call": "Appel", "visit": "Visite", "note": "Note", "whatsapp": "WhatsApp",
	"sms": "SMS", "email": "E-mail", "meeting": "Rendez-vous"}

const activitySelect = `SELECT a.id, a.partner_id, p.name, a.type, a.outcome, a.summary, a.at, a.duration_min,
	a.user_id, COALESCE(NULLIF(u.full_name,''), u.username, ''), a.order_id, o.number, a.document_id,
	a.latitude, a.longitude, a.next_action, a.created_at, a.updated_at
FROM crm_activities a JOIN partners p ON p.id = a.partner_id
LEFT JOIN users u ON u.id = a.user_id LEFT JOIN customer_orders o ON o.id = a.order_id`

func scanActivity(row interface{ Scan(...any) error }) (Activity, error) {
	var a Activity
	err := row.Scan(&a.ID, &a.PartnerID, &a.PartnerName, &a.Type, &a.Outcome, &a.Summary, &a.At, &a.DurationMin,
		&a.UserID, &a.UserName, &a.OrderID, &a.OrderNumber, &a.DocumentID, &a.Latitude, &a.Longitude,
		&a.NextAction, &a.CreatedAt, &a.UpdatedAt)
	return a, err
}

func (s *Server) listActivities(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view") {
		return
	}
	qp := r.URL.Query()
	where, args := " WHERE 1=1", []any{}
	eq := func(param, col string) {
		if v := qp.Get(param); v != "" {
			if v == "me" {
				v = uidOf(r)
			}
			where += " AND " + col + " = ?"
			args = append(args, v)
		}
	}
	eq("partner_id", "a.partner_id")
	eq("user_id", "a.user_id")
	eq("type", "a.type")
	eq("order_id", "a.order_id")
	if v := qp.Get("from"); v != "" {
		where += " AND a.at >= ?"
		args = append(args, v)
	}
	if v := qp.Get("to"); v != "" {
		if len(v) == 10 {
			v += "~"
		}
		where += " AND a.at < ?"
		args = append(args, v)
	}
	if sw, sa := partnerScopeWhere(authFrom(r), "p"); sw != "" {
		where += sw
		args = append(args, sa...)
	}
	limit, _ := strconv.Atoi(qp.Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	offset, _ := strconv.Atoi(qp.Get("offset"))
	rows, err := s.db.Query(activitySelect+where+` ORDER BY a.at DESC LIMIT ? OFFSET ?`, append(args, limit, offset)...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Activity{}
	for rows.Next() {
		a, err := scanActivity(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, a)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type activityInput struct {
	PartnerID   string   `json:"partner_id"`
	Type        string   `json:"type"`
	Outcome     string   `json:"outcome"`
	Summary     string   `json:"summary"`
	At          string   `json:"at"`
	DurationMin int64    `json:"duration_min"`
	OrderID     *string  `json:"order_id"`
	DocumentID  *string  `json:"document_id"`
	Latitude    *float64 `json:"latitude"`
	Longitude   *float64 `json:"longitude"`
	NextAction  string   `json:"next_action"`
	// Optional follow-up task created with the activity.
	NextActionDue *string `json:"next_action_due"`
}

func (s *Server) saveActivity(w http.ResponseWriter, r *http.Request, id string) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	var in activityInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if _, ok := activityTypes[in.Type]; !ok {
		writeFieldErr(w, http.StatusBadRequest, "type", "type invalide (call, visit, note, whatsapp, sms, email, meeting)")
		return
	}
	if in.PartnerID == "" {
		writeFieldErr(w, http.StatusBadRequest, "partner_id", "le client est obligatoire")
		return
	}
	if !s.partnerAccess(w, r, in.PartnerID) {
		return
	}
	if in.At == "" {
		in.At = domain.NowISO()
	}
	if in.DurationMin < 0 {
		writeFieldErr(w, http.StatusBadRequest, "duration_min", "durée invalide")
		return
	}
	now := domain.NowISO()
	status := http.StatusOK
	if !s.inTx(w, func(tx *sql.Tx) error {
		if id == "" {
			id, status = domain.NewID(), http.StatusCreated
			if _, err := tx.Exec(`INSERT INTO crm_activities (id, partner_id, type, outcome, summary, at, duration_min,
					user_id, order_id, document_id, latitude, longitude, next_action, created_at, updated_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, id, in.PartnerID, in.Type, in.Outcome,
				in.Summary, in.At, in.DurationMin, nullIfEmpty(uidOf(r)), emptyNil(in.OrderID),
				emptyNil(in.DocumentID), in.Latitude, in.Longitude, in.NextAction, now, now); err != nil {
				return err
			}
			if strings.TrimSpace(in.NextAction) != "" && in.NextActionDue != nil && *in.NextActionDue != "" {
				_, err := tx.Exec(`INSERT INTO crm_tasks (id, title, partner_id, order_id, assignee_id, due_at, type,
						source, created_by, created_at, updated_at)
					VALUES (?, ?, ?, ?, ?, ?, 'follow_up', 'manual', ?, ?, ?)`, domain.NewID(),
					strings.TrimSpace(in.NextAction), in.PartnerID, emptyNil(in.OrderID), nullIfEmpty(uidOf(r)),
					*in.NextActionDue, nullIfEmpty(uidOf(r)), now, now)
				return err
			}
			// A prospect visited/called who ordered is now active.
			return nil
		}
		res, err := tx.Exec(`UPDATE crm_activities SET partner_id=?, type=?, outcome=?, summary=?, at=?, duration_min=?,
				order_id=?, document_id=?, latitude=?, longitude=?, next_action=?, updated_at=? WHERE id=?`,
			in.PartnerID, in.Type, in.Outcome, in.Summary, in.At, in.DurationMin, emptyNil(in.OrderID),
			emptyNil(in.DocumentID), in.Latitude, in.Longitude, in.NextAction, now, id)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return &domain.NotFoundError{Msg: "activité introuvable"}
		}
		return nil
	}) {
		return
	}
	a, err := scanActivity(s.db.QueryRow(activitySelect+` WHERE a.id = ?`, id))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, a)
}

func (s *Server) createActivity(w http.ResponseWriter, r *http.Request) { s.saveActivity(w, r, "") }
func (s *Server) updateActivity(w http.ResponseWriter, r *http.Request) {
	s.saveActivity(w, r, chi.URLParam(r, "id"))
}
func (s *Server) deleteActivity(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	s.deleteRow(w, r, "crm_activities", "activité introuvable", "")
}

// ---- Tasks ----------------------------------------------------------------------------------

type Task struct {
	ID           string  `json:"id"`
	Title        string  `json:"title"`
	Description  string  `json:"description"`
	PartnerID    *string `json:"partner_id"`
	PartnerName  *string `json:"partner_name"`
	PartnerPhone *string `json:"partner_phone"`
	OrderID      *string `json:"order_id"`
	OrderNumber  *string `json:"order_number"`
	AssigneeID   *string `json:"assignee_id"`
	AssigneeName string  `json:"assignee_name"`
	DueAt        *string `json:"due_at"`
	Overdue      bool    `json:"overdue"`
	Priority     int64   `json:"priority"`
	Status       string  `json:"status"`
	Type         string  `json:"type"`
	Source       string  `json:"source"`
	AutoKey      *string `json:"auto_key"`
	CompletedAt  *string `json:"completed_at"`
	CompletedBy  *string `json:"completed_by"`
	Result       string  `json:"result"`
	CreatedBy    *string `json:"created_by"`
	CreatedAt    string  `json:"created_at"`
	UpdatedAt    string  `json:"updated_at"`
}

const taskSelect = `SELECT t.id, t.title, t.description, t.partner_id, p.name, p.phone, t.order_id, o.number,
	t.assignee_id, COALESCE(NULLIF(u.full_name,''), u.username, ''), t.due_at, t.priority, t.status, t.type,
	t.source, t.auto_key, t.completed_at, t.completed_by, t.result, t.created_by, t.created_at, t.updated_at
FROM crm_tasks t LEFT JOIN partners p ON p.id = t.partner_id LEFT JOIN customer_orders o ON o.id = t.order_id
LEFT JOIN users u ON u.id = t.assignee_id`

func scanTask(row interface{ Scan(...any) error }) (Task, error) {
	var t Task
	err := row.Scan(&t.ID, &t.Title, &t.Description, &t.PartnerID, &t.PartnerName, &t.PartnerPhone, &t.OrderID,
		&t.OrderNumber, &t.AssigneeID, &t.AssigneeName, &t.DueAt, &t.Priority, &t.Status, &t.Type, &t.Source,
		&t.AutoKey, &t.CompletedAt, &t.CompletedBy, &t.Result, &t.CreatedBy, &t.CreatedAt, &t.UpdatedAt)
	t.Overdue = t.Status == "open" && t.DueAt != nil && len(*t.DueAt) >= 10 && (*t.DueAt)[:10] < localToday()
	return t, err
}

var taskTypes = map[string]bool{"call": true, "visit": true, "collect_payment": true, "follow_up": true, "other": true}

// taskScope: a rep-restricted user sees the tasks assigned to him or about
// his customers.
func taskScope(u *AuthUser) (string, []any) {
	if !repRestricted(u) {
		return "", nil
	}
	return " AND (t.assignee_id = ? OR p.rep_user_id = ?)", []any{u.ID, u.ID}
}

func (s *Server) listTasks(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view") {
		return
	}
	qp := r.URL.Query()
	where, args := " WHERE 1=1", []any{}
	switch v := qp.Get("assignee_id"); v {
	case "":
	case "unassigned":
		where += " AND t.assignee_id IS NULL"
	default:
		if v == "me" {
			v = uidOf(r)
		}
		where += " AND t.assignee_id = ?"
		args = append(args, v)
	}
	status := qp.Get("status")
	if status == "" {
		status = "open"
	}
	if status != "all" {
		where += " AND t.status = ?"
		args = append(args, status)
	}
	for param, col := range map[string]string{"partner_id": "t.partner_id", "type": "t.type", "source": "t.source",
		"order_id": "t.order_id"} {
		if v := qp.Get(param); v != "" {
			where += " AND " + col + " = ?"
			args = append(args, v)
		}
	}
	today := localToday()
	switch qp.Get("due") {
	case "overdue":
		where += " AND t.due_at IS NOT NULL AND substr(t.due_at,1,10) < ?"
		args = append(args, today)
	case "today":
		where += " AND substr(t.due_at,1,10) = ?"
		args = append(args, today)
	case "week":
		where += " AND t.due_at IS NOT NULL AND substr(t.due_at,1,10) <= ?"
		args = append(args, time.Now().AddDate(0, 0, 7).Format("2006-01-02"))
	}
	sw, sa := taskScope(authFrom(r))
	where += sw
	args = append(args, sa...)
	limit, _ := strconv.Atoi(qp.Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	rows, err := s.db.Query(taskSelect+where+` ORDER BY t.due_at IS NULL, t.due_at, t.priority DESC, t.created_at
		LIMIT ?`, append(args, limit)...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []Task{}
	for rows.Next() {
		t, err := scanTask(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, t)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// tasksSummary: GET /crm/tasks/summary?assignee_id=me — the badge counts.
func (s *Server) tasksSummary(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view") {
		return
	}
	where, args := " WHERE t.status = 'open'", []any{}
	if v := r.URL.Query().Get("assignee_id"); v != "" && v != "all" {
		if v == "me" {
			v = uidOf(r)
		}
		where += " AND t.assignee_id = ?"
		args = append(args, v)
	}
	sw, sa := taskScope(authFrom(r))
	where += sw
	args = append(args, sa...)
	today := localToday()
	week := time.Now().AddDate(0, 0, 7).Format("2006-01-02")
	var open, overdue, todayN, upcoming int
	s.db.QueryRow(`SELECT COUNT(*),
			COALESCE(SUM(CASE WHEN t.due_at IS NOT NULL AND substr(t.due_at,1,10) < ? THEN 1 ELSE 0 END),0),
			COALESCE(SUM(CASE WHEN substr(t.due_at,1,10) = ? THEN 1 ELSE 0 END),0),
			COALESCE(SUM(CASE WHEN substr(t.due_at,1,10) > ? AND substr(t.due_at,1,10) <= ? THEN 1 ELSE 0 END),0)
		FROM crm_tasks t LEFT JOIN partners p ON p.id = t.partner_id`+where,
		append([]any{today, today, today, week}, args...)...).Scan(&open, &overdue, &todayN, &upcoming)
	writeJSON(w, http.StatusOK, map[string]any{"open": open, "overdue": overdue, "today": todayN, "upcoming_7d": upcoming})
}

type taskInput struct {
	Title       string  `json:"title"`
	Description string  `json:"description"`
	PartnerID   *string `json:"partner_id"`
	OrderID     *string `json:"order_id"`
	AssigneeID  *string `json:"assignee_id"`
	DueAt       *string `json:"due_at"`
	Priority    int64   `json:"priority"`
	Type        string  `json:"type"`
}

func (s *Server) saveTask(w http.ResponseWriter, r *http.Request, id string) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	var in taskInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		writeFieldErr(w, http.StatusBadRequest, "title", "le titre de la tâche est obligatoire")
		return
	}
	if in.Type == "" {
		in.Type = "other"
	}
	if !taskTypes[in.Type] {
		writeFieldErr(w, http.StatusBadRequest, "type", "type invalide (call, visit, collect_payment, follow_up, other)")
		return
	}
	if in.Priority < 0 || in.Priority > 2 {
		writeFieldErr(w, http.StatusBadRequest, "priority", "priorité 0, 1 ou 2")
		return
	}
	if in.PartnerID != nil && *in.PartnerID != "" && !s.partnerAccess(w, r, *in.PartnerID) {
		return
	}
	assignee := emptyNil(in.AssigneeID)
	if in.AssigneeID == nil && id == "" {
		assignee = uidOf(r)
	}
	now := domain.NowISO()
	status := http.StatusOK
	var err error
	if id == "" {
		id, status = domain.NewID(), http.StatusCreated
		_, err = s.db.Exec(`INSERT INTO crm_tasks (id, title, description, partner_id, order_id, assignee_id, due_at,
				priority, type, source, created_by, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual', ?, ?, ?)`, id, in.Title, in.Description, emptyNil(in.PartnerID),
			emptyNil(in.OrderID), assignee, emptyNil(in.DueAt), in.Priority, in.Type, nullIfEmpty(uidOf(r)), now, now)
	} else {
		var res sql.Result
		res, err = s.db.Exec(`UPDATE crm_tasks SET title=?, description=?, partner_id=?, order_id=?, assignee_id=?,
				due_at=?, priority=?, type=?, updated_at=? WHERE id=?`, in.Title, in.Description, emptyNil(in.PartnerID),
			emptyNil(in.OrderID), assignee, emptyNil(in.DueAt), in.Priority, in.Type, now, id)
		if err == nil {
			if n, _ := res.RowsAffected(); n == 0 {
				writeErr(w, http.StatusNotFound, "tâche introuvable")
				return
			}
		}
	}
	if err != nil {
		writeDomainErr(w, err)
		return
	}
	s.respondTask(w, id, status)
}

func (s *Server) respondTask(w http.ResponseWriter, id string, status int) {
	t, err := scanTask(s.db.QueryRow(taskSelect+` WHERE t.id = ?`, id))
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "tâche introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, t)
}

func (s *Server) createTask(w http.ResponseWriter, r *http.Request) { s.saveTask(w, r, "") }
func (s *Server) updateTask(w http.ResponseWriter, r *http.Request) {
	s.saveTask(w, r, chi.URLParam(r, "id"))
}

func (s *Server) closeTask(w http.ResponseWriter, r *http.Request, status string) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	id := chi.URLParam(r, "id")
	var in struct {
		Result string `json:"result"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	now := domain.NowISO()
	res, err := s.db.Exec(`UPDATE crm_tasks SET status=?, result=?, completed_at=?, completed_by=?, updated_at=?
		WHERE id=? AND status='open'`, status, in.Result, now, nullIfEmpty(uidOf(r)), now, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusConflict, "tâche introuvable ou déjà close")
		return
	}
	s.respondTask(w, id, http.StatusOK)
}

func (s *Server) completeTask(w http.ResponseWriter, r *http.Request) { s.closeTask(w, r, "done") }
func (s *Server) cancelTask(w http.ResponseWriter, r *http.Request)   { s.closeTask(w, r, "cancelled") }

// generateTasks: POST /crm/tasks/generate — automatic tasks, idempotent: a
// task with the same auto_key is not created again while it is open or was
// closed less than 7 days ago.
//   - overdue invoices → collect_payment for the customer's rep;
//   - customers inactive N days → follow_up;
//   - backorder now available → call.
func (s *Server) generateTasks(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	var in struct {
		InactiveDays *int  `json:"inactive_days"`
		Overdue      *bool `json:"overdue"`
		Inactive     *bool `json:"inactive"`
		Backorder    *bool `json:"backorder"`
	}
	if err := decodeOptional(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	days := int(domain.SettingInt(s.db, "crm_inactive_days", 30))
	if in.InactiveDays != nil && *in.InactiveDays > 0 {
		days = *in.InactiveDays
	}
	on := func(b *bool) bool { return b == nil || *b }
	type cand struct {
		key, title, desc, partner, order, assignee, typ, source string
		priority                                                int
	}
	var cands []cand
	metrics, err := s.customerMetrics(nil, segmentRules{PeriodDays: 30})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, m := range metrics {
		rep := ""
		if m.RepUserID != nil {
			rep = *m.RepUserID
		}
		if on(in.Overdue) && m.OverdueAmount > 0 {
			cands = append(cands, cand{key: "overdue:" + m.PartnerID, partner: m.PartnerID, assignee: rep,
				title: "Relancer le paiement — " + m.Name, typ: "collect_payment", source: "auto_overdue", priority: 1,
				desc: fmt.Sprintf("%d facture(s) échue(s), %s DA en retard (solde %s DA)", m.OverdueCount,
					centimes(m.OverdueAmount), centimes(m.Balance))})
		}
		if on(in.Inactive) && m.CRMStatus == "active" && m.LastOrderDate != "" && m.DaysSinceLastOrder >= days {
			cands = append(cands, cand{key: "inactive:" + m.PartnerID, partner: m.PartnerID, assignee: rep,
				title: fmt.Sprintf("Relancer %s (aucune commande depuis %d jours)", m.Name, m.DaysSinceLastOrder),
				typ:   "follow_up", source: "auto_inactive",
				desc: "Dernière commande le " + m.LastOrderDate})
		}
	}
	if on(in.Backorder) {
		req, _ := http.NewRequest("GET", "/?fulfillable=1", nil)
		req = req.WithContext(r.Context())
		rows, err := s.backorderRows(req, "")
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		reps := map[string]string{}
		for _, b := range rows {
			if b.Fulfillable <= 0 {
				continue
			}
			if _, ok := reps[b.PartnerID]; !ok {
				var rep sql.NullString
				s.db.QueryRow(`SELECT rep_user_id FROM partners WHERE id = ?`, b.PartnerID).Scan(&rep)
				reps[b.PartnerID] = rep.String
			}
			cands = append(cands, cand{key: "backorder:" + b.LineID, partner: b.PartnerID, order: b.OrderID,
				assignee: reps[b.PartnerID], typ: "call", source: "auto_backorder", priority: 1,
				title: fmt.Sprintf("Appeler %s : %s de nouveau disponible", b.PartnerName, b.ProductName),
				desc: fmt.Sprintf("Reliquat de %s sur la commande %s — %s disponible(s)", qtyText(b.QtyBackorder),
					b.OrderNumber, qtyText(b.Fulfillable))})
		}
	}
	created := map[string]int{"auto_overdue": 0, "auto_inactive": 0, "auto_backorder": 0}
	skipped := 0
	since := time.Now().AddDate(0, 0, -7).UTC().Format(time.RFC3339)
	today := localToday()
	if !s.inTx(w, func(tx *sql.Tx) error {
		now := domain.NowISO()
		for _, c := range cands {
			var n int
			tx.QueryRow(`SELECT COUNT(*) FROM crm_tasks WHERE auto_key = ? AND (status = 'open' OR completed_at >= ?)`,
				c.key, since).Scan(&n)
			if n > 0 {
				skipped++
				continue
			}
			if _, err := tx.Exec(`INSERT INTO crm_tasks (id, title, description, partner_id, order_id, assignee_id, due_at,
					priority, type, source, auto_key, created_by, created_at, updated_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, domain.NewID(), c.title, c.desc, nullIfEmpty(c.partner),
				nullIfEmpty(c.order), nullIfEmpty(c.assignee), today, c.priority, c.typ, c.source, c.key,
				nullIfEmpty(uidOf(r)), now, now); err != nil {
				return err
			}
			created[c.source]++
		}
		return nil
	}) {
		return
	}
	total := created["auto_overdue"] + created["auto_inactive"] + created["auto_backorder"]
	if total > 0 {
		s.audit(r, "crm.tasks_generate", "crm_task", "", fmt.Sprintf("%d tâche(s) automatique(s)", total))
	}
	writeJSON(w, http.StatusOK, map[string]any{"created": total, "by_source": created, "skipped": skipped,
		"inactive_days": days})
}

// ---- Customer metrics (segments, tasks, KPIs) ---------------------------------------------

type customerMetric struct {
	PartnerID          string   `json:"partner_id"`
	Name               string   `json:"name"`
	Phone              string   `json:"phone"`
	ClientType         string   `json:"client_type"`
	CRMStatus          string   `json:"crm_status"`
	Wilaya             string   `json:"wilaya"`
	RepUserID          *string  `json:"rep_user_id"`
	RepName            string   `json:"rep_name"`
	RouteID            *string  `json:"route_id"`
	CreatedAt          string   `json:"created_at"`
	TagIDs             []string `json:"tag_ids"`
	Turnover           int64    `json:"turnover"`          // TTC over period_days
	TurnoverPrevious   int64    `json:"turnover_previous"` // the period before
	OrdersCount        int      `json:"orders_count"`      // customer orders over period_days
	LastOrderDate      string   `json:"last_order_date"`
	DaysSinceLastOrder int      `json:"days_since_last_order"` // -1 = never
	Balance            int64    `json:"balance"`
	CreditLimit        int64    `json:"credit_limit"`     // 0 = none
	CreditUsagePct     int64    `json:"credit_usage_pct"` // whole percent, 0 when no limit
	OverdueAmount      int64    `json:"overdue_amount"`
	OverdueCount       int      `json:"overdue_count"`
}

// salesTurnoverSQL sums what a customer bought between two dates: tickets and
// invoices minus credit notes, plus delivery notes not yet invoiced.
const salesTurnoverSQL = `SELECT d.partner_id,
	SUM(CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN -d.total_ttc ELSE d.total_ttc END), MAX(d.doc_date)
FROM documents d
WHERE d.status = 'posted' AND d.partner_id IS NOT NULL AND d.doc_date >= ? AND d.doc_date <= ?
  AND (d.doc_type IN ('SALE_TICKET','SALE_INVOICE','SALE_CREDIT_NOTE')
       OR (d.doc_type = 'DELIVERY_NOTE' AND NOT EXISTS (SELECT 1 FROM documents i
            WHERE i.ref_document_id = d.id AND i.doc_type = 'SALE_INVOICE' AND i.status = 'posted')))`

// customerMetrics computes the key figures of every active customer the
// caller may see (r nil = all), filtered by the rule's simple filters.
func (s *Server) customerMetrics(r *http.Request, rules segmentRules) ([]*customerMetric, error) {
	if rules.PeriodDays <= 0 {
		rules.PeriodDays = 90
	}
	where, args := ` WHERE p.active = 1 AND p.kind IN ('customer','both')`, []any{}
	if r != nil {
		sw, sa := partnerScopeWhere(authFrom(r), "p")
		where += sw
		args = append(args, sa...)
	}
	eq := func(v, col string) {
		if v != "" {
			where += " AND " + col + " = ?"
			args = append(args, v)
		}
	}
	eq(rules.ClientType, "p.client_type")
	eq(rules.CRMStatus, "p.crm_status")
	eq(rules.Wilaya, "p.wilaya")
	eq(rules.RepUserID, "p.rep_user_id")
	eq(rules.RouteID, "p.route_id")
	eq(rules.GroupID, "p.group_id")
	if rules.TagID != "" {
		where += " AND p.id IN (SELECT partner_id FROM partner_tags WHERE tag_id = ?)"
		args = append(args, rules.TagID)
	}
	if def, ok := domain.Setting(s.db, "pos_default_customer_id"); ok && def != "" {
		where += " AND p.id <> ?"
		args = append(args, def)
	}
	rows, err := s.db.Query(`SELECT p.id, p.name, COALESCE(p.phone,''), p.client_type, p.crm_status, p.wilaya,
			p.rep_user_id, COALESCE((SELECT COALESCE(NULLIF(u.full_name,''), u.username) FROM users u WHERE u.id = p.rep_user_id), ''),
			p.route_id, p.created_at, COALESCE(p.credit_limit, 0),
			COALESCE((SELECT group_concat(pt.tag_id) FROM partner_tags pt WHERE pt.partner_id = p.id), '')
		FROM partners p`+where+` ORDER BY p.name`, args...)
	if err != nil {
		return nil, err
	}
	out := []*customerMetric{}
	idx := map[string]*customerMetric{}
	for rows.Next() {
		m := &customerMetric{DaysSinceLastOrder: -1}
		var tags string
		if err := rows.Scan(&m.PartnerID, &m.Name, &m.Phone, &m.ClientType, &m.CRMStatus, &m.Wilaya, &m.RepUserID,
			&m.RepName, &m.RouteID, &m.CreatedAt, &m.CreditLimit, &tags); err != nil {
			rows.Close()
			return nil, err
		}
		m.TagIDs = splitCSV(tags)
		out = append(out, m)
		idx[m.PartnerID] = m
	}
	rows.Close()
	if len(out) == 0 {
		return out, nil
	}
	today := localToday()
	from := daysAgo(rules.PeriodDays - 1)
	prevTo := daysAgo(rules.PeriodDays)
	prevFrom := daysAgo(2*rules.PeriodDays - 1)
	sumInto := func(a, b string, set func(m *customerMetric, v int64, last string)) error {
		rows, err := s.db.Query(salesTurnoverSQL+` GROUP BY d.partner_id`, a, b)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var pid, last string
			var v int64
			if err := rows.Scan(&pid, &v, &last); err != nil {
				return err
			}
			if m := idx[pid]; m != nil {
				set(m, v, last)
			}
		}
		return rows.Err()
	}
	if err := sumInto(from, today, func(m *customerMetric, v int64, _ string) { m.Turnover = v }); err != nil {
		return nil, err
	}
	if err := sumInto(prevFrom, prevTo, func(m *customerMetric, v int64, _ string) { m.TurnoverPrevious = v }); err != nil {
		return nil, err
	}
	// Last purchase: any sale document or customer order, ever.
	if err := sumInto("0000-00-00", "9999-12-31", func(m *customerMetric, _ int64, last string) {
		if last > m.LastOrderDate {
			m.LastOrderDate = last
		}
	}); err != nil {
		return nil, err
	}
	orows, err := s.db.Query(`SELECT partner_id, MAX(order_date),
			SUM(CASE WHEN order_date >= ? THEN 1 ELSE 0 END)
		FROM customer_orders WHERE status <> 'cancelled' GROUP BY partner_id`, from)
	if err != nil {
		return nil, err
	}
	for orows.Next() {
		var pid, last string
		var n int
		orows.Scan(&pid, &last, &n)
		if m := idx[pid]; m != nil {
			if last > m.LastOrderDate {
				m.LastOrderDate = last
			}
			m.OrdersCount = n
		}
	}
	orows.Close()
	brows, err := s.db.Query(`SELECT partner_id, SUM(amount) FROM partner_ledger GROUP BY partner_id`)
	if err != nil {
		return nil, err
	}
	for brows.Next() {
		var pid string
		var b int64
		brows.Scan(&pid, &b)
		if m := idx[pid]; m != nil {
			m.Balance = b
		}
	}
	brows.Close()
	defLimit := domain.SettingInt(s.db, "default_credit_limit", 0)
	now := time.Now()
	for _, m := range out {
		if m.CreditLimit <= 0 {
			m.CreditLimit = max(0, defLimit)
		}
		if m.CreditLimit > 0 && m.Balance > 0 {
			m.CreditUsagePct = m.Balance * 100 / m.CreditLimit
		}
		if m.LastOrderDate != "" {
			if t, err := time.ParseInLocation("2006-01-02", m.LastOrderDate, now.Location()); err == nil {
				m.DaysSinceLastOrder = int(now.Sub(t).Hours() / 24)
			}
		}
		if m.Balance > 0 {
			amt, n, err := domain.OverdueOf(s.db, m.PartnerID)
			if err != nil {
				return nil, err
			}
			m.OverdueAmount, m.OverdueCount = amt, n
		}
	}
	return out, nil
}

// ---- Segments ----------------------------------------------------------------------------------

// segmentRules is the JSON stored in crm_segments.rules_json.
type segmentRules struct {
	Builtin     string `json:"builtin,omitempty"`      // inactive|credit_usage|overdue|top_customers|declining|new_customers
	Days        int    `json:"days,omitempty"`         // inactive / new customers window
	MinPct      int64  `json:"min_pct,omitempty"`      // credit usage threshold (%)
	MinDropPct  int64  `json:"min_drop_pct,omitempty"` // declining: minimum drop (%), default 20
	Limit       int    `json:"limit,omitempty"`        // top customers: N
	PeriodDays  int    `json:"period_days,omitempty"`  // turnover window (default 90)
	ClientType  string `json:"client_type,omitempty"`
	CRMStatus   string `json:"crm_status,omitempty"`
	TagID       string `json:"tag_id,omitempty"`
	Wilaya      string `json:"wilaya,omitempty"`
	RepUserID   string `json:"rep_user_id,omitempty"`
	RouteID     string `json:"route_id,omitempty"`
	GroupID     string `json:"group_id,omitempty"`
	MinTurnover int64  `json:"min_turnover,omitempty"`
	MinBalance  int64  `json:"min_balance,omitempty"`
}

type segmentDef struct {
	ID        string       `json:"id"`
	Name      string       `json:"name"`
	Builtin   bool         `json:"builtin"`
	Rules     segmentRules `json:"rules"`
	CreatedAt string       `json:"created_at,omitempty"`
	UpdatedAt string       `json:"updated_at,omitempty"`
}

var builtinSegments = []segmentDef{
	{ID: "builtin:inactive_30", Name: "Inactifs depuis 30 jours", Builtin: true, Rules: segmentRules{Builtin: "inactive", Days: 30}},
	{ID: "builtin:inactive_60", Name: "Inactifs depuis 60 jours", Builtin: true, Rules: segmentRules{Builtin: "inactive", Days: 60}},
	{ID: "builtin:inactive_90", Name: "Inactifs depuis 90 jours", Builtin: true, Rules: segmentRules{Builtin: "inactive", Days: 90}},
	{ID: "builtin:credit_80", Name: "Crédit utilisé à plus de 80 %", Builtin: true, Rules: segmentRules{Builtin: "credit_usage", MinPct: 80}},
	{ID: "builtin:overdue", Name: "Factures échues impayées", Builtin: true, Rules: segmentRules{Builtin: "overdue"}},
	{ID: "builtin:top_customers", Name: "Meilleurs clients (90 jours)", Builtin: true, Rules: segmentRules{Builtin: "top_customers", Limit: 20, PeriodDays: 90}},
	{ID: "builtin:declining", Name: "Chiffre d'affaires en baisse (30 j vs 30 j précédents)", Builtin: true, Rules: segmentRules{Builtin: "declining", PeriodDays: 30, MinDropPct: 20}},
	{ID: "builtin:new_customers", Name: "Nouveaux clients (30 jours)", Builtin: true, Rules: segmentRules{Builtin: "new_customers", Days: 30}},
}

func (rules segmentRules) validate() string {
	switch rules.Builtin {
	case "", "inactive", "credit_usage", "overdue", "top_customers", "declining", "new_customers":
	default:
		return "règle inconnue (inactive, credit_usage, overdue, top_customers, declining, new_customers)"
	}
	if rules.ClientType != "" {
		if _, ok := clientTypes[rules.ClientType]; !ok {
			return "client_type invalide"
		}
	}
	return ""
}

func (s *Server) evaluateRules(r *http.Request, rules segmentRules) ([]*customerMetric, map[string]string, error) {
	switch rules.Builtin {
	case "inactive", "new_customers":
		if rules.Days <= 0 {
			rules.Days = 30
		}
	case "credit_usage":
		if rules.MinPct <= 0 {
			rules.MinPct = 80
		}
	case "top_customers":
		if rules.Limit <= 0 {
			rules.Limit = 20
		}
	case "declining":
		if rules.MinDropPct <= 0 {
			rules.MinDropPct = 20
		}
		if rules.PeriodDays <= 0 {
			rules.PeriodDays = 30
		}
	}
	all, err := s.customerMetrics(r, rules)
	if err != nil {
		return nil, nil, err
	}
	period := map[string]string{"from": daysAgo(max(rules.PeriodDays, 90) - 1), "to": localToday()}
	if rules.PeriodDays > 0 {
		period["from"] = daysAgo(rules.PeriodDays - 1)
	}
	newSince := time.Now().AddDate(0, 0, -rules.Days).UTC().Format(time.RFC3339)
	out := []*customerMetric{}
	for _, m := range all {
		if rules.MinTurnover > 0 && m.Turnover < rules.MinTurnover {
			continue
		}
		if rules.MinBalance > 0 && m.Balance < rules.MinBalance {
			continue
		}
		keep := true
		switch rules.Builtin {
		case "inactive":
			keep = m.LastOrderDate != "" && m.DaysSinceLastOrder >= rules.Days
		case "credit_usage":
			keep = m.CreditLimit > 0 && m.CreditUsagePct >= rules.MinPct
		case "overdue":
			keep = m.OverdueAmount > 0
		case "top_customers":
			keep = m.Turnover > 0
		case "declining":
			keep = m.TurnoverPrevious > 0 && m.Turnover*100 <= m.TurnoverPrevious*(100-rules.MinDropPct)
		case "new_customers":
			keep = m.CreatedAt >= newSince
		}
		if keep {
			out = append(out, m)
		}
	}
	switch rules.Builtin {
	case "top_customers":
		sort.SliceStable(out, func(i, j int) bool { return out[i].Turnover > out[j].Turnover })
		if len(out) > rules.Limit {
			out = out[:rules.Limit]
		}
	case "inactive":
		sort.SliceStable(out, func(i, j int) bool { return out[i].DaysSinceLastOrder > out[j].DaysSinceLastOrder })
	case "overdue":
		sort.SliceStable(out, func(i, j int) bool { return out[i].OverdueAmount > out[j].OverdueAmount })
	case "credit_usage":
		sort.SliceStable(out, func(i, j int) bool { return out[i].CreditUsagePct > out[j].CreditUsagePct })
	case "declining":
		sort.SliceStable(out, func(i, j int) bool {
			return out[i].TurnoverPrevious-out[i].Turnover > out[j].TurnoverPrevious-out[j].Turnover
		})
	}
	return out, period, nil
}

func (s *Server) writeSegmentResult(w http.ResponseWriter, r *http.Request, rules segmentRules, extra map[string]any) {
	items, period, err := s.evaluateRules(r, rules)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var turnover, balance int64
	for _, m := range items {
		turnover += m.Turnover
		balance += m.Balance
	}
	out := map[string]any{"items": items, "count": len(items), "period": period, "rules": rules,
		"total_turnover": turnover, "total_balance": balance}
	for k, v := range extra {
		out[k] = v
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) listSegments(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view") {
		return
	}
	items := append([]segmentDef{}, builtinSegments...)
	rows, err := s.db.Query(`SELECT id, name, rules_json, created_at, updated_at FROM crm_segments ORDER BY name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	for rows.Next() {
		var d segmentDef
		var js string
		rows.Scan(&d.ID, &d.Name, &js, &d.CreatedAt, &d.UpdatedAt)
		json.Unmarshal([]byte(js), &d.Rules)
		items = append(items, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) saveSegment(w http.ResponseWriter, r *http.Request, id string) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	var in struct {
		Name  string       `json:"name"`
		Rules segmentRules `json:"rules"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		writeFieldErr(w, http.StatusBadRequest, "name", "le nom du segment est obligatoire")
		return
	}
	if msg := in.Rules.validate(); msg != "" {
		writeFieldErr(w, http.StatusBadRequest, "rules", msg)
		return
	}
	js, _ := json.Marshal(in.Rules)
	now := domain.NowISO()
	status := http.StatusOK
	var err error
	if id == "" {
		id, status = domain.NewID(), http.StatusCreated
		_, err = s.db.Exec(`INSERT INTO crm_segments (id, name, rules_json, created_by, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?)`, id, in.Name, string(js), nullIfEmpty(uidOf(r)), now, now)
	} else {
		var res sql.Result
		res, err = s.db.Exec(`UPDATE crm_segments SET name=?, rules_json=?, updated_at=? WHERE id=?`, in.Name, string(js), now, id)
		if err == nil {
			if n, _ := res.RowsAffected(); n == 0 {
				writeErr(w, http.StatusNotFound, "segment introuvable")
				return
			}
		}
	}
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			writeFieldErr(w, http.StatusConflict, "name", "un segment porte déjà ce nom")
			return
		}
		writeDomainErr(w, err)
		return
	}
	writeJSON(w, status, segmentDef{ID: id, Name: in.Name, Rules: in.Rules, UpdatedAt: now})
}

func (s *Server) createSegment(w http.ResponseWriter, r *http.Request) { s.saveSegment(w, r, "") }
func (s *Server) updateSegment(w http.ResponseWriter, r *http.Request) {
	s.saveSegment(w, r, chi.URLParam(r, "id"))
}
func (s *Server) deleteSegment(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	s.deleteRow(w, r, "crm_segments", "segment introuvable", "")
}

// evaluateSegmentRules: POST /crm/segments/evaluate {rules} — ad-hoc filter.
func (s *Server) evaluateSegmentRules(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view") {
		return
	}
	var in struct {
		Rules segmentRules `json:"rules"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if msg := in.Rules.validate(); msg != "" {
		writeFieldErr(w, http.StatusBadRequest, "rules", msg)
		return
	}
	s.writeSegmentResult(w, r, in.Rules, nil)
}

// evaluateSegment: GET /crm/segments/{id}/evaluate — saved or built-in
// (id « builtin:inactive_30 »…). Query params override the simple filters.
func (s *Server) evaluateSegment(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view") {
		return
	}
	id := chi.URLParam(r, "id")
	var def *segmentDef
	for i := range builtinSegments {
		if builtinSegments[i].ID == id {
			d := builtinSegments[i]
			def = &d
		}
	}
	if def == nil {
		var d segmentDef
		var js string
		if err := s.db.QueryRow(`SELECT id, name, rules_json FROM crm_segments WHERE id = ?`, id).Scan(&d.ID, &d.Name, &js); err != nil {
			writeErr(w, http.StatusNotFound, "segment introuvable")
			return
		}
		json.Unmarshal([]byte(js), &d.Rules)
		def = &d
	}
	qp := r.URL.Query()
	for k, p := range map[string]*string{"client_type": &def.Rules.ClientType, "tag_id": &def.Rules.TagID,
		"wilaya": &def.Rules.Wilaya, "rep_user_id": &def.Rules.RepUserID, "route_id": &def.Rules.RouteID,
		"crm_status": &def.Rules.CRMStatus} {
		if v := qp.Get(k); v != "" {
			*p = v
		}
	}
	s.writeSegmentResult(w, r, def.Rules, map[string]any{"segment": def})
}

// ---- Timeline ---------------------------------------------------------------------------------

type timelineItem struct {
	Kind     string  `json:"kind"` // order | order_event | document | payment | activity | task | message
	ID       string  `json:"id"`
	At       string  `json:"at"`
	Title    string  `json:"title"`
	Detail   string  `json:"detail"`
	Amount   *int64  `json:"amount"`
	RefID    *string `json:"ref_id"` // order id / document id
	Status   string  `json:"status"`
	SubType  string  `json:"sub_type"` // doc_type, activity type, channel, action…
	UserName string  `json:"user_name"`
}

const timelineSQL = `
SELECT 'order' AS kind, o.id, o.created_at AS at, o.number AS title, o.source AS detail, o.total_ttc AS amount,
       o.id AS ref_id, o.status, o.source AS sub_type, COALESCE(NULLIF(u.full_name,''), u.username, '') AS user_name
  FROM customer_orders o LEFT JOIN users u ON u.id = o.created_by WHERE o.partner_id = ?1
UNION ALL
SELECT 'order_event', e.id, e.created_at, o.number, e.note, NULL, o.id, COALESCE(e.to_status,''), e.action,
       COALESCE(NULLIF(u.full_name,''), u.username, '')
  FROM customer_order_events e JOIN customer_orders o ON o.id = e.order_id LEFT JOIN users u ON u.id = e.user_id
 WHERE o.partner_id = ?1 AND e.action NOT IN ('create','pick','unpick','edit_line','add_line','delete_line','update')
UNION ALL
SELECT CASE WHEN d.doc_type IN ('PAYMENT_IN','PAYMENT_OUT') THEN 'payment' ELSE 'document' END, d.id,
       COALESCE(d.posted_at, d.created_at), COALESCE(d.number, ''), COALESCE(d.notes, ''),
       CASE WHEN d.doc_type IN ('PAYMENT_IN','PAYMENT_OUT') THEN d.amount ELSE d.total_ttc END,
       d.id, d.status, d.doc_type, COALESCE(NULLIF(u.full_name,''), u.username, '')
  FROM documents d LEFT JOIN users u ON u.id = COALESCE(d.posted_by, d.created_by)
 WHERE d.partner_id = ?1 AND d.status <> 'draft'
UNION ALL
SELECT 'activity', a.id, a.at, a.outcome, a.summary, NULL, a.order_id, '', a.type,
       COALESCE(NULLIF(u.full_name,''), u.username, '')
  FROM crm_activities a LEFT JOIN users u ON u.id = a.user_id WHERE a.partner_id = ?1
UNION ALL
SELECT 'task', t.id, COALESCE(t.completed_at, t.created_at), t.title, t.description, NULL, t.order_id, t.status, t.type,
       COALESCE(NULLIF(u.full_name,''), u.username, '')
  FROM crm_tasks t LEFT JOIN users u ON u.id = t.assignee_id WHERE t.partner_id = ?1
UNION ALL
SELECT 'message', m.id, m.created_at, m.template_code, m.body, NULL, m.order_id, m.status, m.channel,
       COALESCE(NULLIF(u.full_name,''), u.username, '')
  FROM message_log m LEFT JOIN users u ON u.id = m.user_id WHERE m.partner_id = ?1`

var docTypeLabels = map[string]string{
	domain.SaleTicket: "Ticket", domain.SaleInvoice: "Facture", domain.SaleCreditNote: "Avoir",
	domain.DeliveryNote: "Bon de livraison", domain.Quote: "Devis", domain.PaymentIn: "Encaissement",
	domain.PaymentOut: "Paiement", domain.PurchaseInvoice: "Facture fournisseur",
	domain.PurchaseReceipt: "Réception", domain.PurchaseOrder: "Bon de commande",
	domain.PurchaseCreditNote: "Avoir fournisseur",
}

// partnerTimeline: GET /partners/{id}/timeline?limit=&offset=&kinds=order,document…
func (s *Server) partnerTimeline(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "partners.view") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	qp := r.URL.Query()
	limit, _ := strconv.Atoi(qp.Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	offset, _ := strconv.Atoi(qp.Get("offset"))
	where, args := "", []any{id}
	if kinds := splitCSV(qp.Get("kinds")); len(kinds) > 0 {
		where = " WHERE kind IN (" + placeholders(len(kinds)) + ")"
		for _, k := range kinds {
			args = append(args, k)
		}
	}
	var total int
	s.db.QueryRow(`SELECT COUNT(*) FROM (`+timelineSQL+`)`+where, args...).Scan(&total)
	rows, err := s.db.Query(`SELECT kind, id, at, title, detail, amount, ref_id, status, sub_type, user_name
		FROM (`+timelineSQL+`)`+where+` ORDER BY at DESC, id DESC LIMIT ? OFFSET ?`, append(args, limit, offset)...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []timelineItem{}
	for rows.Next() {
		var t timelineItem
		if err := rows.Scan(&t.Kind, &t.ID, &t.At, &t.Title, &t.Detail, &t.Amount, &t.RefID, &t.Status,
			&t.SubType, &t.UserName); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		switch t.Kind {
		case "order":
			t.Title = "Commande " + t.Title
			t.Detail = "Origine : " + t.Detail
		case "order_event":
			t.Title = "Commande " + t.Title
		case "document", "payment":
			label := docTypeLabels[t.SubType]
			if label == "" {
				label = t.SubType
			}
			t.Title = strings.TrimSpace(label + " " + t.Title)
		case "activity":
			label := activityTypes[t.SubType]
			if t.Title != "" {
				label += " — " + t.Title
			}
			t.Title = label
		case "task":
			t.Title = "Tâche : " + t.Title
		case "message":
			t.Title = "Message " + t.SubType
			if t.Title != "" && t.Detail != "" && len(t.Detail) > 200 {
				t.Detail = t.Detail[:200] + "…"
			}
		}
		items = append(items, t)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

// ---- KPIs / credit -----------------------------------------------------------------------------

// partnerCredit: GET /partners/{id}/credit — what the order entry screen shows.
func (s *Server) partnerCredit(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "orders.view", "crm.view", "partners.view") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	balance := domain.PartnerBalance(s.db, id)
	limit := domain.CreditLimitOf(s.db, id)
	var open sql.NullInt64
	var openN int
	s.db.QueryRow(`SELECT SUM(total_ttc), COUNT(*) FROM customer_orders WHERE partner_id = ?
		AND status IN ('validated','preparing','ready','shipping','delivered')`, id).Scan(&open, &openN)
	overdue, n, err := domain.OverdueOf(s.db, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var status string
	s.db.QueryRow(`SELECT crm_status FROM partners WHERE id = ?`, id).Scan(&status)
	var available *int64
	if limit > 0 {
		a := limit - balance - open.Int64
		available = &a
	}
	writeJSON(w, http.StatusOK, map[string]any{"partner_id": id, "balance": balance, "credit_limit": limit,
		"open_orders_total": open.Int64, "open_orders_count": openN, "available_credit": available,
		"overdue_amount": overdue, "overdue_count": n, "crm_status": status,
		"payment_terms_days": domain.PaymentTermsDays(s.db, id)})
}

// partnerKPIs: GET /partners/{id}/kpis — the partner page dashboard.
func (s *Server) partnerKPIs(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "partners.view") {
		return
	}
	id := chi.URLParam(r, "id")
	if !s.partnerAccess(w, r, id) {
		return
	}
	today := localToday()
	turnover := func(days int) int64 {
		var v sql.NullInt64
		s.db.QueryRow(`SELECT SUM(x) FROM (SELECT CASE WHEN d.doc_type = 'SALE_CREDIT_NOTE' THEN -d.total_ttc ELSE d.total_ttc END AS x
			FROM documents d WHERE d.status = 'posted' AND d.partner_id = ? AND d.doc_date >= ? AND d.doc_date <= ?
			AND (d.doc_type IN ('SALE_TICKET','SALE_INVOICE','SALE_CREDIT_NOTE')
			     OR (d.doc_type = 'DELIVERY_NOTE' AND NOT EXISTS (SELECT 1 FROM documents i
			          WHERE i.ref_document_id = d.id AND i.doc_type = 'SALE_INVOICE' AND i.status = 'posted'))))`,
			id, daysAgo(days-1), today).Scan(&v)
		return v.Int64
	}
	t30, t90, t365 := turnover(30), turnover(90), turnover(365)
	// Purchase dates over a year: customer orders, else sale documents.
	dates := map[string]bool{}
	from := daysAgo(364)
	drows, err := s.db.Query(`SELECT order_date FROM customer_orders WHERE partner_id = ? AND status <> 'cancelled' AND order_date >= ?
		UNION SELECT d.doc_date FROM documents d WHERE d.partner_id = ? AND d.status = 'posted' AND d.doc_date >= ?
		  AND (d.doc_type IN ('SALE_TICKET','SALE_INVOICE') AND d.ref_document_id IS NULL OR d.doc_type = 'DELIVERY_NOTE')`,
		id, from, id, from)
	if err == nil {
		for drows.Next() {
			var d string
			drows.Scan(&d)
			dates[d] = true
		}
		drows.Close()
	}
	sorted := make([]string, 0, len(dates))
	for d := range dates {
		sorted = append(sorted, d)
	}
	sort.Strings(sorted)
	var freq *float64
	if len(sorted) >= 2 {
		a, _ := time.Parse("2006-01-02", sorted[0])
		b, _ := time.Parse("2006-01-02", sorted[len(sorted)-1])
		f := b.Sub(a).Hours() / 24 / float64(len(sorted)-1)
		f = float64(int64(f*10+0.5)) / 10
		freq = &f
	}
	var avgBasket int64
	if len(sorted) > 0 {
		avgBasket = t365 / int64(len(sorted))
	}
	var lastOrderN sql.NullString
	s.db.QueryRow(`SELECT MAX(x) FROM (SELECT MAX(order_date) AS x FROM customer_orders WHERE partner_id = ? AND status <> 'cancelled'
		UNION ALL SELECT MAX(doc_date) FROM documents WHERE partner_id = ? AND status = 'posted'
		  AND doc_type IN ('SALE_TICKET','SALE_INVOICE','DELIVERY_NOTE'))`, id, id).Scan(&lastOrderN)
	lastOrder := lastOrderN.String
	daysSince := -1
	if lastOrder != "" {
		if t, err := time.ParseInLocation("2006-01-02", lastOrder, time.Now().Location()); err == nil {
			daysSince = int(time.Since(t).Hours() / 24)
		}
	}
	type topProduct struct {
		ProductID string `json:"product_id"`
		Name      string `json:"name"`
		QtyMilli  int64  `json:"qty_milli"`
		Amount    int64  `json:"amount"`
	}
	tops := []topProduct{}
	trows, err := s.db.Query(`SELECT l.product_id, p.name, SUM(l.qty_milli), SUM(l.line_ttc)
		FROM document_lines l JOIN documents d ON d.id = l.document_id JOIN products p ON p.id = l.product_id
		WHERE d.partner_id = ? AND d.status = 'posted' AND d.doc_date >= ?
		  AND (d.doc_type = 'SALE_TICKET' OR (d.doc_type = 'SALE_INVOICE' AND d.ref_document_id IS NULL)
		       OR d.doc_type = 'DELIVERY_NOTE')
		GROUP BY l.product_id ORDER BY SUM(l.line_ttc) DESC, SUM(l.qty_milli) DESC LIMIT 10`, id, from)
	if err == nil {
		for trows.Next() {
			var t topProduct
			trows.Scan(&t.ProductID, &t.Name, &t.QtyMilli, &t.Amount)
			tops = append(tops, t)
		}
		trows.Close()
	}
	// Payment delay: days from invoice date to the settlement that cleared it (FIFO).
	items, _, err := domain.LedgerFIFO(s.db, id, 1)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var delaySum, delayN int64
	var overdue int64
	for _, it := range items {
		if it.Overdue {
			overdue += it.Outstanding
		}
		if it.SettledOn == "" || it.DocDate == "" || it.DocDate < from {
			continue
		}
		a, err1 := time.Parse("2006-01-02", it.DocDate)
		b, err2 := time.Parse("2006-01-02", it.SettledOn)
		if err1 == nil && err2 == nil && !b.Before(a) {
			delaySum += int64(b.Sub(a).Hours() / 24)
			delayN++
		}
	}
	var delay *float64
	if delayN > 0 {
		d := float64(delaySum*10/delayN) / 10
		delay = &d
	}
	balance := domain.PartnerBalance(s.db, id)
	limit := domain.CreditLimitOf(s.db, id)
	var usage int64
	if limit > 0 && balance > 0 {
		usage = balance * 100 / limit
	}
	var openN int
	var openAmt sql.NullInt64
	s.db.QueryRow(`SELECT COUNT(*), SUM(total_ttc) FROM customer_orders WHERE partner_id = ?
		AND status IN ('new','validated','preparing','ready','shipping')`, id).Scan(&openN, &openAmt)
	var boLines int
	var boQty sql.NullInt64
	s.db.QueryRow(`SELECT COUNT(*), SUM(l.qty_backorder_milli) FROM customer_order_lines l
		JOIN customer_orders o ON o.id = l.order_id WHERE o.partner_id = ? AND o.status <> 'cancelled'
		AND l.qty_backorder_milli > 0`, id).Scan(&boLines, &boQty)
	writeJSON(w, http.StatusOK, map[string]any{
		"partner_id": id, "turnover_30d": t30, "turnover_90d": t90, "turnover_365d": t365,
		"purchases_count_365d": len(sorted), "avg_basket": avgBasket, "order_frequency_days": freq,
		"last_order_date": nilIfEmptyStr(lastOrder), "days_since_last_order": daysSince, "top_products": tops,
		"payment_delay_avg_days": delay, "balance": balance, "credit_limit": limit, "credit_usage_pct": usage,
		"overdue_amount": overdue, "open_orders_count": openN, "open_orders_amount": openAmt.Int64,
		"backorder_lines": boLines, "backorder_qty_milli": boQty.Int64,
	})
}

func nilIfEmptyStr(v string) *string {
	if v == "" {
		return nil
	}
	return &v
}

// ---- Rep targets & performance -----------------------------------------------------------------

type RepTarget struct {
	ID                 string `json:"id"`
	UserID             string `json:"user_id"`
	UserName           string `json:"user_name"`
	Month              string `json:"month"`
	SalesTarget        int64  `json:"sales_target"`
	OrdersTarget       int64  `json:"orders_target"`
	VisitsTarget       int64  `json:"visits_target"`
	NewCustomersTarget int64  `json:"new_customers_target"`
	CollectionsTarget  int64  `json:"collections_target"`
	UpdatedAt          string `json:"updated_at"`
}

func validMonth(m string) bool {
	_, err := time.Parse("2006-01", m)
	return err == nil
}

func (s *Server) listRepTargets(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view") {
		return
	}
	month := r.URL.Query().Get("month")
	if month == "" {
		month = time.Now().Format("2006-01")
	}
	where, args := ` WHERE t.month = ?`, []any{month}
	if repRestricted(authFrom(r)) {
		where += ` AND t.user_id = ?`
		args = append(args, uidOf(r))
	}
	rows, err := s.db.Query(`SELECT t.id, t.user_id, COALESCE(NULLIF(u.full_name,''), u.username, ''), t.month,
			t.sales_target, t.orders_target, t.visits_target, t.new_customers_target, t.collections_target, t.updated_at
		FROM rep_targets t JOIN users u ON u.id = t.user_id`+where+` ORDER BY u.full_name, u.username`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []RepTarget{}
	for rows.Next() {
		var t RepTarget
		rows.Scan(&t.ID, &t.UserID, &t.UserName, &t.Month, &t.SalesTarget, &t.OrdersTarget, &t.VisitsTarget,
			&t.NewCustomersTarget, &t.CollectionsTarget, &t.UpdatedAt)
		items = append(items, t)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "month": month})
}

// putRepTarget: PUT /crm/rep-targets — upsert by (user_id, month).
func (s *Server) putRepTarget(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	if repRestricted(authFrom(r)) {
		writeErr(w, http.StatusForbidden, "seul un responsable fixe les objectifs")
		return
	}
	var in RepTarget
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.UserID == "" {
		writeFieldErr(w, http.StatusBadRequest, "user_id", "commercial obligatoire")
		return
	}
	if !validMonth(in.Month) {
		writeFieldErr(w, http.StatusBadRequest, "month", "mois au format AAAA-MM")
		return
	}
	if in.SalesTarget < 0 || in.OrdersTarget < 0 || in.VisitsTarget < 0 || in.NewCustomersTarget < 0 || in.CollectionsTarget < 0 {
		writeErr(w, http.StatusBadRequest, "un objectif ne peut pas être négatif")
		return
	}
	now := domain.NowISO()
	if _, err := s.db.Exec(`INSERT INTO rep_targets (id, user_id, month, sales_target, orders_target, visits_target,
			new_customers_target, collections_target, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (user_id, month) DO UPDATE SET sales_target=excluded.sales_target, orders_target=excluded.orders_target,
			visits_target=excluded.visits_target, new_customers_target=excluded.new_customers_target,
			collections_target=excluded.collections_target, updated_at=excluded.updated_at`,
		domain.NewID(), in.UserID, in.Month, in.SalesTarget, in.OrdersTarget, in.VisitsTarget, in.NewCustomersTarget,
		in.CollectionsTarget, now, now); err != nil {
		writeDomainErr(w, err)
		return
	}
	var t RepTarget
	s.db.QueryRow(`SELECT t.id, t.user_id, COALESCE(NULLIF(u.full_name,''), u.username, ''), t.month,
			t.sales_target, t.orders_target, t.visits_target, t.new_customers_target, t.collections_target, t.updated_at
		FROM rep_targets t JOIN users u ON u.id = t.user_id WHERE t.user_id = ? AND t.month = ?`, in.UserID, in.Month).
		Scan(&t.ID, &t.UserID, &t.UserName, &t.Month, &t.SalesTarget, &t.OrdersTarget, &t.VisitsTarget,
			&t.NewCustomersTarget, &t.CollectionsTarget, &t.UpdatedAt)
	s.audit(r, "crm.rep_target", "user", in.UserID, "objectifs "+in.Month)
	writeJSON(w, http.StatusOK, t)
}

type repPerf struct {
	UserID       string           `json:"user_id"`
	Name         string           `json:"name"`
	Month        string           `json:"month"`
	Sales        int64            `json:"sales"`         // TTC of his orders (validated or beyond)
	OrdersCount  int64            `json:"orders_count"`  // his orders past « new », not cancelled
	NewCustomers int64            `json:"new_customers"` // customers created this month with him as rep
	Visits       int64            `json:"visits"`
	Calls        int64            `json:"calls"`
	Collections  int64            `json:"collections"` // PAYMENT_IN of his customers
	Customers    int64            `json:"customers"`   // portfolio size
	Targets      *RepTarget       `json:"targets"`
	Achievement  map[string]int64 `json:"achievement_pct"` // per target, whole percent (absent = no target)
}

// repPerformance: GET /crm/reps/performance?month=YYYY-MM&user_id=.
func (s *Server) repPerformance(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view") {
		return
	}
	month := r.URL.Query().Get("month")
	if month == "" {
		month = time.Now().Format("2006-01")
	}
	if !validMonth(month) {
		writeFieldErr(w, http.StatusBadRequest, "month", "mois au format AAAA-MM")
		return
	}
	only := r.URL.Query().Get("user_id")
	if repRestricted(authFrom(r)) {
		only = uidOf(r)
	}
	from := month + "-01"
	t, _ := time.Parse("2006-01-02", from)
	to := t.AddDate(0, 1, -1).Format("2006-01-02")
	// Reps: users with a target this month, a portfolio, or orders as rep.
	rows, err := s.db.Query(`SELECT u.id, COALESCE(NULLIF(u.full_name,''), u.username) FROM users u
		WHERE u.active = 1 AND (u.id IN (SELECT user_id FROM rep_targets WHERE month = ?)
		   OR u.id IN (SELECT rep_user_id FROM partners WHERE rep_user_id IS NOT NULL)
		   OR u.id IN (SELECT rep_user_id FROM customer_orders WHERE rep_user_id IS NOT NULL AND order_date BETWEEN ? AND ?))
		ORDER BY 2`, month, from, to)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var reps []*repPerf
	for rows.Next() {
		p := &repPerf{Month: month, Achievement: map[string]int64{}}
		rows.Scan(&p.UserID, &p.Name)
		if only == "" || only == p.UserID {
			reps = append(reps, p)
		}
	}
	rows.Close()
	items := []repPerf{}
	for _, p := range reps {
		s.db.QueryRow(`SELECT COALESCE(SUM(total_ttc),0), COUNT(*) FROM customer_orders
			WHERE rep_user_id = ? AND order_date BETWEEN ? AND ? AND status NOT IN ('new','cancelled')`, p.UserID, from, to).
			Scan(&p.Sales, &p.OrdersCount)
		s.db.QueryRow(`SELECT COUNT(*) FROM partners WHERE rep_user_id = ? AND substr(created_at,1,7) = ?`, p.UserID, month).
			Scan(&p.NewCustomers)
		s.db.QueryRow(`SELECT COALESCE(SUM(CASE WHEN type='visit' THEN 1 ELSE 0 END),0),
				COALESCE(SUM(CASE WHEN type='call' THEN 1 ELSE 0 END),0)
			FROM crm_activities WHERE user_id = ? AND substr(at,1,7) = ?`, p.UserID, month).Scan(&p.Visits, &p.Calls)
		s.db.QueryRow(`SELECT COALESCE(SUM(d.amount),0) FROM documents d JOIN partners pa ON pa.id = d.partner_id
			WHERE d.doc_type = 'PAYMENT_IN' AND d.status = 'posted' AND pa.rep_user_id = ? AND d.doc_date BETWEEN ? AND ?`,
			p.UserID, from, to).Scan(&p.Collections)
		s.db.QueryRow(`SELECT COUNT(*) FROM partners WHERE rep_user_id = ? AND active = 1`, p.UserID).Scan(&p.Customers)
		var tg RepTarget
		if err := s.db.QueryRow(`SELECT id, user_id, month, sales_target, orders_target, visits_target, new_customers_target,
				collections_target, updated_at FROM rep_targets WHERE user_id = ? AND month = ?`, p.UserID, month).
			Scan(&tg.ID, &tg.UserID, &tg.Month, &tg.SalesTarget, &tg.OrdersTarget, &tg.VisitsTarget,
				&tg.NewCustomersTarget, &tg.CollectionsTarget, &tg.UpdatedAt); err == nil {
			tg.UserName = p.Name
			p.Targets = &tg
			pct := func(k string, got, want int64) {
				if want > 0 {
					p.Achievement[k] = got * 100 / want
				}
			}
			pct("sales", p.Sales, tg.SalesTarget)
			pct("orders", p.OrdersCount, tg.OrdersTarget)
			pct("visits", p.Visits, tg.VisitsTarget)
			pct("new_customers", p.NewCustomers, tg.NewCustomersTarget)
			pct("collections", p.Collections, tg.CollectionsTarget)
		}
		items = append(items, *p)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "month": month, "from": from, "to": to})
}
