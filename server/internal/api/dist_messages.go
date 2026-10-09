package api

import (
	"crypto/tls"
	"database/sql"
	"encoding/base64"
	"fmt"
	"net"
	"net/http"
	"net/smtp"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

func (s *Server) routesMessages(r chi.Router) {
	r.Get("/message-templates", s.listMessageTemplates)
	r.Post("/message-templates", s.createMessageTemplate)
	r.Put("/message-templates/{id}", s.updateMessageTemplate)
	r.Delete("/message-templates/{id}", s.deleteMessageTemplate)
	r.Get("/messages/placeholders", s.messagePlaceholders)
	r.Post("/messages/render", s.renderMessage)
	r.Post("/messages/log", s.logMessage)
	r.Get("/messages/log", s.listMessageLog)
	r.Post("/messages/send-email", s.sendEmail)
}

type MessageTemplate struct {
	ID        string `json:"id"`
	Code      string `json:"code"`
	Channel   string `json:"channel"`
	Lang      string `json:"lang"`
	Name      string `json:"name"`
	Subject   string `json:"subject"`
	Body      string `json:"body"`
	Active    bool   `json:"active"`
	IsSystem  bool   `json:"is_system"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

const templateSelect = `SELECT id, code, channel, lang, name, subject, body, active, is_system, created_at, updated_at
	FROM message_templates`

func scanMsgTemplate(row interface{ Scan(...any) error }) (MessageTemplate, error) {
	var t MessageTemplate
	var a, sys int
	err := row.Scan(&t.ID, &t.Code, &t.Channel, &t.Lang, &t.Name, &t.Subject, &t.Body, &a, &sys, &t.CreatedAt, &t.UpdatedAt)
	t.Active, t.IsSystem = a == 1, sys == 1
	return t, err
}

var messageChannels = map[string]bool{"whatsapp": true, "sms": true, "email": true}

// Placeholders understood by the renderer (anything else stays as typed and
// is reported in "missing").
var messagePlaceholderDocs = []map[string]string{
	{"key": "client", "label": "Nom du client"},
	{"key": "contact", "label": "Contact principal (ou nom du client)"},
	{"key": "numero", "label": "N° de la commande"},
	{"key": "reference_web", "label": "N° de la commande sur la boutique web"},
	{"key": "montant", "label": "Montant TTC de la commande"},
	{"key": "solde", "label": "Solde du compte client"},
	{"key": "date", "label": "Date du jour (JJ/MM/AAAA)"},
	{"key": "date_commande", "label": "Date de la commande"},
	{"key": "magasin", "label": "Nom de l'entreprise (Paramètres)"},
	{"key": "telephone_magasin", "label": "Téléphone de l'entreprise"},
	{"key": "lien_suivi", "label": "Lien de suivi (réglage order_tracking_url, {ref} = référence web)"},
	{"key": "produit", "label": "Produit (reliquat disponible…) — via extra"},
	{"key": "promo", "label": "Offres en cours (promotions web) — ou via extra"},
	{"key": "statut", "label": "Statut de la commande"},
}

func (s *Server) messagePlaceholders(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"items": messagePlaceholderDocs})
}

func (s *Server) listMessageTemplates(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "orders.view") {
		return
	}
	qp := r.URL.Query()
	where, args := " WHERE 1=1", []any{}
	for _, k := range []string{"code", "channel", "lang"} {
		if v := qp.Get(k); v != "" {
			where += " AND " + k + " = ?"
			args = append(args, v)
		}
	}
	rows, err := s.db.Query(templateSelect+where+` ORDER BY code, channel, lang`, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []MessageTemplate{}
	for rows.Next() {
		t, err := scanMsgTemplate(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, t)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type msgTemplateInput struct {
	Code    string `json:"code"`
	Channel string `json:"channel"`
	Lang    string `json:"lang"`
	Name    string `json:"name"`
	Subject string `json:"subject"`
	Body    string `json:"body"`
	Active  *bool  `json:"active"`
}

var templateCodeRe = regexp.MustCompile(`^[a-z0-9_]{2,40}$`)

func (s *Server) saveMessageTemplate(w http.ResponseWriter, r *http.Request, id string) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	var in msgTemplateInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if !templateCodeRe.MatchString(in.Code) {
		writeFieldErr(w, http.StatusBadRequest, "code", "code : lettres minuscules, chiffres et _ (ex. order_ready)")
		return
	}
	if !messageChannels[in.Channel] {
		writeFieldErr(w, http.StatusBadRequest, "channel", "canal invalide (whatsapp, sms, email)")
		return
	}
	if in.Lang == "" {
		in.Lang = "fr"
	}
	if in.Lang != "fr" && in.Lang != "ar" {
		writeFieldErr(w, http.StatusBadRequest, "lang", "langue fr ou ar")
		return
	}
	if strings.TrimSpace(in.Body) == "" {
		writeFieldErr(w, http.StatusBadRequest, "body", "le texte du message est obligatoire")
		return
	}
	active := in.Active == nil || *in.Active
	now := domain.NowISO()
	status := http.StatusOK
	var err error
	if id == "" {
		id, status = domain.NewID(), http.StatusCreated
		_, err = s.db.Exec(`INSERT INTO message_templates (id, code, channel, lang, name, subject, body, active, is_system,
			created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`, id, in.Code, in.Channel, in.Lang,
			in.Name, in.Subject, in.Body, b2i(active), now, now)
	} else {
		var res sql.Result
		res, err = s.db.Exec(`UPDATE message_templates SET code=?, channel=?, lang=?, name=?, subject=?, body=?, active=?,
			updated_at=? WHERE id=?`, in.Code, in.Channel, in.Lang, in.Name, in.Subject, in.Body, b2i(active), now, id)
		if err == nil {
			if n, _ := res.RowsAffected(); n == 0 {
				writeErr(w, http.StatusNotFound, "modèle introuvable")
				return
			}
		}
	}
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			writeFieldErr(w, http.StatusConflict, "code", "un modèle existe déjà pour ce code, ce canal et cette langue")
			return
		}
		writeDomainErr(w, err)
		return
	}
	t, _ := scanMsgTemplate(s.db.QueryRow(templateSelect+` WHERE id = ?`, id))
	writeJSON(w, status, t)
}

func (s *Server) createMessageTemplate(w http.ResponseWriter, r *http.Request) {
	s.saveMessageTemplate(w, r, "")
}
func (s *Server) updateMessageTemplate(w http.ResponseWriter, r *http.Request) {
	s.saveMessageTemplate(w, r, chi.URLParam(r, "id"))
}

func (s *Server) deleteMessageTemplate(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit") {
		return
	}
	var sys int
	if err := s.db.QueryRow(`SELECT is_system FROM message_templates WHERE id = ?`, chi.URLParam(r, "id")).Scan(&sys); err != nil {
		writeErr(w, http.StatusNotFound, "modèle introuvable")
		return
	}
	if sys == 1 {
		writeErr(w, http.StatusConflict, "un modèle par défaut ne se supprime pas : désactivez-le ou modifiez son texte")
		return
	}
	s.deleteRow(w, r, "message_templates", "modèle introuvable", "")
}

// fmtMoneyHuman: 1234567 → « 12 345,67 DA ».
func fmtMoneyHuman(c int64) string {
	sign := ""
	if c < 0 {
		sign, c = "-", -c
	}
	ints := strconv.FormatInt(c/100, 10)
	var b strings.Builder
	for i, ch := range ints {
		if i > 0 && (len(ints)-i)%3 == 0 {
			b.WriteByte(' ')
		}
		b.WriteRune(ch)
	}
	return fmt.Sprintf("%s%s,%02d DA", sign, b.String(), c%100)
}

func frDate(iso string) string {
	if t, err := time.Parse("2006-01-02", iso); err == nil {
		return t.Format("02/01/2006")
	}
	return iso
}

var placeholderRe = regexp.MustCompile(`\{\{\s*([a-zA-Z0-9_]+)\s*\}\}`)

type renderedMessage struct {
	Channel   string   `json:"channel"`
	Code      string   `json:"template_code"`
	Subject   string   `json:"subject"`
	Body      string   `json:"body"`
	Recipient string   `json:"recipient"` // intl phone (213…) or e-mail
	PhoneIntl string   `json:"phone_intl"`
	WaLink    string   `json:"wa_link"` // https://wa.me/<intl>?text=…
	Mailto    string   `json:"mailto"`
	Missing   []string `json:"missing"` // placeholders left unresolved
}

// renderMessage: POST /messages/render.
func (s *Server) renderMessage(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "orders.view") {
		return
	}
	var in struct {
		TemplateID string            `json:"template_id"`
		Code       string            `json:"code"`
		Channel    string            `json:"channel"`
		Lang       string            `json:"lang"`
		Body       string            `json:"body"` // free text instead of a template
		Subject    string            `json:"subject"`
		PartnerID  string            `json:"partner_id"`
		OrderID    string            `json:"order_id"`
		Extra      map[string]string `json:"extra"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var tpl MessageTemplate
	switch {
	case in.TemplateID != "":
		t, err := scanMsgTemplate(s.db.QueryRow(templateSelect+` WHERE id = ?`, in.TemplateID))
		if err != nil {
			writeErr(w, http.StatusNotFound, "modèle introuvable")
			return
		}
		tpl = t
	case in.Code != "":
		if in.Channel == "" {
			in.Channel = "whatsapp"
		}
		if in.Lang == "" {
			in.Lang = "fr"
		}
		t, err := scanMsgTemplate(s.db.QueryRow(templateSelect+` WHERE code = ? AND channel = ? AND lang = ? AND active = 1`,
			in.Code, in.Channel, in.Lang))
		if err != nil {
			// Fall back to the French template of the same channel.
			t, err = scanMsgTemplate(s.db.QueryRow(templateSelect+` WHERE code = ? AND channel = ? AND active = 1
				ORDER BY lang = 'fr' DESC LIMIT 1`, in.Code, in.Channel))
			if err != nil {
				writeErr(w, http.StatusNotFound, "aucun modèle actif « "+in.Code+" » pour ce canal")
				return
			}
		}
		tpl = t
	case strings.TrimSpace(in.Body) != "":
		if in.Channel == "" {
			in.Channel = "whatsapp"
		}
		if !messageChannels[in.Channel] {
			writeFieldErr(w, http.StatusBadRequest, "channel", "canal invalide (whatsapp, sms, email)")
			return
		}
		tpl = MessageTemplate{Channel: in.Channel, Body: in.Body, Subject: in.Subject}
	default:
		writeErr(w, http.StatusBadRequest, "indiquez template_id, code ou body")
		return
	}
	if in.PartnerID == "" && in.OrderID != "" {
		s.db.QueryRow(`SELECT partner_id FROM customer_orders WHERE id = ?`, in.OrderID).Scan(&in.PartnerID)
	}
	if in.PartnerID != "" && !s.partnerAccess(w, r, in.PartnerID) {
		return
	}
	out, err := s.render(tpl, in.PartnerID, in.OrderID, in.Extra)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) render(tpl MessageTemplate, partnerID, orderID string, extra map[string]string) (*renderedMessage, error) {
	vals := map[string]string{
		"date": time.Now().Format("02/01/2006"),
	}
	if v, ok := domain.Setting(s.db, "company_name"); ok {
		vals["magasin"] = v
	}
	if v, ok := domain.Setting(s.db, "company_phone"); ok {
		vals["telephone_magasin"] = v
	}
	var phone, whatsapp, email string
	if partnerID != "" {
		var name string
		var ph, em sql.NullString
		if err := s.db.QueryRow(`SELECT name, phone, whatsapp, email FROM partners WHERE id = ?`, partnerID).
			Scan(&name, &ph, &whatsapp, &em); err == nil {
			vals["client"] = name
			vals["contact"] = name
			phone, email = ph.String, em.String
			vals["solde"] = fmtMoneyHuman(domain.PartnerBalance(s.db, partnerID))
			var cname, cphone, cwa, cmail string
			if s.db.QueryRow(`SELECT name, phone, whatsapp, email FROM partner_contacts WHERE partner_id = ?
				ORDER BY is_primary DESC, created_at LIMIT 1`, partnerID).Scan(&cname, &cphone, &cwa, &cmail) == nil {
				vals["contact"] = cname
				if phone == "" {
					phone = cphone
				}
				if whatsapp == "" {
					whatsapp = cwa
				}
				if email == "" {
					email = cmail
				}
			}
		}
	}
	if orderID != "" {
		var number, date, status, extRef, extNum, cphone string
		var total int64
		if err := s.db.QueryRow(`SELECT number, order_date, status, total_ttc, COALESCE(external_ref,''),
				COALESCE(external_number,''), contact_phone FROM customer_orders WHERE id = ?`, orderID).
			Scan(&number, &date, &status, &total, &extRef, &extNum, &cphone); err == nil {
			vals["numero"] = number
			vals["date_commande"] = frDate(date)
			vals["montant"] = fmtMoneyHuman(total)
			vals["statut"] = domain.OrderStatusLabels[status]
			vals["reference_web"] = extNum
			if u, ok := domain.Setting(s.db, "order_tracking_url"); ok && strings.TrimSpace(u) != "" {
				ref := extRef
				if ref == "" {
					ref = number
				}
				vals["lien_suivi"] = strings.ReplaceAll(strings.TrimSpace(u), "{ref}", url.PathEscape(ref))
			}
			if phone == "" && whatsapp == "" {
				phone = cphone
			}
		}
	}
	if _, ok := extra["promo"]; !ok && strings.Contains(tpl.Body, "promo") {
		d := localToday()
		promos, _ := s.queryPromos(` WHERE r.active = 1 AND r.channel IN ('all','web') AND r.audience = 'all'
			AND (r.start_date IS NULL OR r.start_date = '' OR r.start_date <= ?)
			AND (r.end_date IS NULL OR r.end_date = '' OR r.end_date >= ?)`, d, d)
		parts := []string{}
		for _, p := range promos {
			target := p.Name
			if p.ProductName != nil {
				target = *p.ProductName
			}
			parts = append(parts, target+" ("+p.Label+")")
			if len(parts) == 5 {
				break
			}
		}
		if len(parts) > 0 {
			vals["promo"] = strings.Join(parts, ", ")
		}
	}
	for k, v := range extra {
		vals[k] = v
	}
	missing := []string{}
	seen := map[string]bool{}
	repl := func(text string) string {
		return placeholderRe.ReplaceAllStringFunc(text, func(m string) string {
			key := placeholderRe.FindStringSubmatch(m)[1]
			if v, ok := vals[key]; ok {
				return v
			}
			if !seen[key] {
				seen[key] = true
				missing = append(missing, key)
			}
			return ""
		})
	}
	out := &renderedMessage{Channel: tpl.Channel, Code: tpl.Code, Subject: repl(tpl.Subject), Body: repl(tpl.Body),
		Missing: missing}
	wa := whatsapp
	if wa == "" {
		wa = phone
	}
	out.PhoneIntl = IntlPhoneDZ(wa)
	switch tpl.Channel {
	case "email":
		out.Recipient = email
		if email != "" {
			out.Mailto = "mailto:" + email + "?subject=" + url.QueryEscape(out.Subject) + "&body=" + url.QueryEscape(out.Body)
		}
	case "sms":
		out.PhoneIntl = IntlPhoneDZ(phone)
		out.Recipient = out.PhoneIntl
	default:
		out.Recipient = out.PhoneIntl
	}
	if out.PhoneIntl != "" {
		out.WaLink = "https://wa.me/" + out.PhoneIntl + "?text=" + url.QueryEscape(out.Body)
	} else {
		out.WaLink = "https://wa.me/?text=" + url.QueryEscape(out.Body)
	}
	return out, nil
}

type MessageLogEntry struct {
	ID           string  `json:"id"`
	PartnerID    *string `json:"partner_id"`
	PartnerName  *string `json:"partner_name"`
	OrderID      *string `json:"order_id"`
	OrderNumber  *string `json:"order_number"`
	Channel      string  `json:"channel"`
	TemplateCode string  `json:"template_code"`
	Recipient    string  `json:"recipient"`
	Subject      string  `json:"subject"`
	Body         string  `json:"body"`
	Status       string  `json:"status"`
	Error        string  `json:"error"`
	UserID       *string `json:"user_id"`
	UserName     string  `json:"user_name"`
	CreatedAt    string  `json:"created_at"`
}

const messageLogSelect = `SELECT m.id, m.partner_id, p.name, m.order_id, o.number, m.channel, m.template_code, m.recipient,
	m.subject, m.body, m.status, m.error, m.user_id, COALESCE(NULLIF(u.full_name,''), u.username, ''), m.created_at
FROM message_log m LEFT JOIN partners p ON p.id = m.partner_id LEFT JOIN customer_orders o ON o.id = m.order_id
LEFT JOIN users u ON u.id = m.user_id`

func scanMessageLog(row interface{ Scan(...any) error }) (MessageLogEntry, error) {
	var m MessageLogEntry
	err := row.Scan(&m.ID, &m.PartnerID, &m.PartnerName, &m.OrderID, &m.OrderNumber, &m.Channel, &m.TemplateCode,
		&m.Recipient, &m.Subject, &m.Body, &m.Status, &m.Error, &m.UserID, &m.UserName, &m.CreatedAt)
	return m, err
}

func (s *Server) insertMessageLog(partnerID, orderID, channel, code, recipient, subject, body, status, errMsg, userID string) (string, error) {
	id := domain.NewID()
	_, err := s.db.Exec(`INSERT INTO message_log (id, partner_id, order_id, channel, template_code, recipient, subject, body,
		status, error, user_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, id, nullIfEmpty(partnerID),
		nullIfEmpty(orderID), channel, code, recipient, subject, body, status, errMsg, nullIfEmpty(userID), domain.NowISO())
	return id, err
}

// logMessage: POST /messages/log — the desktop opened WhatsApp / SMS with the
// rendered text (status prepared) or the user confirmed it was sent.
func (s *Server) logMessage(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "orders.view") {
		return
	}
	var in struct {
		PartnerID    string `json:"partner_id"`
		OrderID      string `json:"order_id"`
		Channel      string `json:"channel"`
		TemplateCode string `json:"template_code"`
		Recipient    string `json:"recipient"`
		Subject      string `json:"subject"`
		Body         string `json:"body"`
		Status       string `json:"status"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if !messageChannels[in.Channel] {
		writeFieldErr(w, http.StatusBadRequest, "channel", "canal invalide (whatsapp, sms, email)")
		return
	}
	if strings.TrimSpace(in.Body) == "" {
		writeFieldErr(w, http.StatusBadRequest, "body", "message vide")
		return
	}
	if in.Status == "" {
		in.Status = "prepared"
	}
	if in.Status != "prepared" && in.Status != "sent" {
		writeFieldErr(w, http.StatusBadRequest, "status", "statut prepared ou sent")
		return
	}
	if in.PartnerID == "" && in.OrderID != "" {
		s.db.QueryRow(`SELECT partner_id FROM customer_orders WHERE id = ?`, in.OrderID).Scan(&in.PartnerID)
	}
	id, err := s.insertMessageLog(in.PartnerID, in.OrderID, in.Channel, in.TemplateCode, in.Recipient, in.Subject,
		in.Body, in.Status, "", uidOf(r))
	if err != nil {
		writeDomainErr(w, err)
		return
	}
	m, _ := scanMessageLog(s.db.QueryRow(messageLogSelect+` WHERE m.id = ?`, id))
	writeJSON(w, http.StatusCreated, m)
}

func (s *Server) listMessageLog(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.view", "orders.view") {
		return
	}
	qp := r.URL.Query()
	where, args := " WHERE 1=1", []any{}
	for _, k := range []string{"partner_id", "order_id", "channel", "status"} {
		if v := qp.Get(k); v != "" {
			where += " AND m." + k + " = ?"
			args = append(args, v)
		}
	}
	if sw, sa := partnerScopeWhere(authFrom(r), "p"); sw != "" {
		where += " AND (m.partner_id IS NULL OR (1=1" + sw + "))"
		args = append(args, sa...)
	}
	limit, _ := strconv.Atoi(qp.Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.Query(messageLogSelect+where+` ORDER BY m.created_at DESC LIMIT ?`, append(args, limit)...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	items := []MessageLogEntry{}
	for rows.Next() {
		m, err := scanMessageLog(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, m)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// ---- E-mail (SMTP) ----------------------------------------------------------------------

type smtpConf struct {
	host, user, pass, from, security string
	port                             int
}

func (s *Server) loadSMTP() (smtpConf, bool) {
	c := smtpConf{}
	c.host, _ = domain.Setting(s.db, "smtp_host")
	c.user, _ = domain.Setting(s.db, "smtp_user")
	c.pass, _ = domain.Setting(s.db, "smtp_pass")
	c.from, _ = domain.Setting(s.db, "smtp_from")
	c.security, _ = domain.Setting(s.db, "smtp_security") // starttls | ssl | none
	c.host, c.from = strings.TrimSpace(c.host), strings.TrimSpace(c.from)
	c.port = int(domain.SettingInt(s.db, "smtp_port", 587))
	if c.from == "" {
		c.from = c.user
	}
	if c.security == "" {
		c.security = "starttls"
		if c.port == 465 {
			c.security = "ssl"
		}
	}
	return c, c.host != "" && c.from != ""
}

// smtpSend is replaceable in tests.
var smtpSend = func(c smtpConf, to, subject, body string) error {
	addr := net.JoinHostPort(c.host, strconv.Itoa(c.port))
	msg := "From: " + c.from + "\r\nTo: " + to + "\r\nSubject: =?UTF-8?B?" + b64(subject) + "?=\r\n" +
		"MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n" +
		"Date: " + time.Now().Format(time.RFC1123Z) + "\r\n\r\n" + strings.ReplaceAll(body, "\n", "\r\n")
	var auth smtp.Auth
	if c.user != "" {
		auth = smtp.PlainAuth("", c.user, c.pass, c.host)
	}
	if c.security != "ssl" {
		if c.security == "none" {
			auth = nil
		}
		return smtp.SendMail(addr, auth, c.from, []string{to}, []byte(msg))
	}
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 15 * time.Second}, "tcp", addr, &tls.Config{ServerName: c.host})
	if err != nil {
		return err
	}
	cl, err := smtp.NewClient(conn, c.host)
	if err != nil {
		return err
	}
	defer cl.Close()
	if auth != nil {
		if err := cl.Auth(auth); err != nil {
			return err
		}
	}
	if err := cl.Mail(c.from); err != nil {
		return err
	}
	if err := cl.Rcpt(to); err != nil {
		return err
	}
	wc, err := cl.Data()
	if err != nil {
		return err
	}
	if _, err := wc.Write([]byte(msg)); err != nil {
		return err
	}
	if err := wc.Close(); err != nil {
		return err
	}
	return cl.Quit()
}

// sendEmail: POST /messages/send-email — through the SMTP account of the
// settings (smtp_host, smtp_port, smtp_user, smtp_pass, smtp_from,
// smtp_security). Logged in message_log (sent / failed).
func (s *Server) sendEmail(w http.ResponseWriter, r *http.Request) {
	if !s.need(w, r, "crm.edit", "orders.manage") {
		return
	}
	var in struct {
		PartnerID    string `json:"partner_id"`
		OrderID      string `json:"order_id"`
		To           string `json:"to"`
		Subject      string `json:"subject"`
		Body         string `json:"body"`
		TemplateCode string `json:"template_code"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	conf, ok := s.loadSMTP()
	if !ok {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "l'envoi d'e-mails n'est pas configuré : renseignez le serveur SMTP dans Paramètres (smtp_host, smtp_port, smtp_user, smtp_pass, smtp_from)",
			"smtp_not_configured": true})
		return
	}
	if in.PartnerID == "" && in.OrderID != "" {
		s.db.QueryRow(`SELECT partner_id FROM customer_orders WHERE id = ?`, in.OrderID).Scan(&in.PartnerID)
	}
	to := strings.TrimSpace(in.To)
	if to == "" && in.PartnerID != "" {
		var em sql.NullString
		s.db.QueryRow(`SELECT email FROM partners WHERE id = ?`, in.PartnerID).Scan(&em)
		to = strings.TrimSpace(em.String)
		if to == "" {
			s.db.QueryRow(`SELECT email FROM partner_contacts WHERE partner_id = ? AND email <> ''
				ORDER BY is_primary DESC LIMIT 1`, in.PartnerID).Scan(&to)
		}
	}
	if to == "" || !strings.Contains(to, "@") || strings.ContainsAny(to, "\r\n") {
		writeFieldErr(w, http.StatusBadRequest, "to", "adresse e-mail du destinataire manquante ou invalide")
		return
	}
	if strings.ContainsAny(in.Subject, "\r\n") {
		writeFieldErr(w, http.StatusBadRequest, "subject", "objet invalide")
		return
	}
	if strings.TrimSpace(in.Body) == "" {
		writeFieldErr(w, http.StatusBadRequest, "body", "message vide")
		return
	}
	sendErr := smtpSend(conf, to, in.Subject, in.Body)
	status, errMsg := "sent", ""
	if sendErr != nil {
		status, errMsg = "failed", sendErr.Error()
	}
	id, _ := s.insertMessageLog(in.PartnerID, in.OrderID, "email", in.TemplateCode, to, in.Subject, in.Body, status,
		errMsg, uidOf(r))
	if sendErr != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": "envoi impossible : " + sendErr.Error(), "log_id": id})
		return
	}
	m, _ := scanMessageLog(s.db.QueryRow(messageLogSelect+` WHERE m.id = ?`, id))
	writeJSON(w, http.StatusOK, m)
}

func b64(v string) string { return base64.StdEncoding.EncodeToString([]byte(v)) }
