package api

import (
	"strings"

	"elixir/server/internal/domain"
)

// Distribution / CRM customer record (0016): fields added to partners, read and
// written by GET/POST/PUT /partners. Fields missing from a PUT stay
// unchanged, so that existing screens (which do not send them) do not
// erase them.

var clientTypes = map[string]string{
	"supermarket": "Supérette", "restaurant": "Restaurant", "hotel": "Hôtel", "wholesaler": "Grossiste",
	"retailer": "Commerce", "individual": "Particulier", "other": "Autre",
}

var crmStatuses = map[string]string{
	"prospect": "Prospect", "active": "Actif", "dormant": "Inactif", "blocked": "Bloqué",
}

var partnerSources = map[string]bool{"manual": true, "web": true, "import": true, "rep": true, "portal": true}

func (in *partnerInput) validateCRM() string {
	if in.ClientType != nil {
		if _, ok := clientTypes[*in.ClientType]; !ok {
			return "client_type invalide (supermarket, restaurant, hotel, wholesaler, retailer, individual, other)"
		}
	}
	if in.CRMStatus != nil {
		if _, ok := crmStatuses[*in.CRMStatus]; !ok {
			return "crm_status invalide (prospect, active, dormant, blocked)"
		}
	}
	if in.Source != nil && !partnerSources[*in.Source] {
		return "source invalide (manual, web, import, rep, portal)"
	}
	if in.Latitude != nil && (*in.Latitude < -90 || *in.Latitude > 90) {
		return "latitude invalide"
	}
	if in.Longitude != nil && (*in.Longitude < -180 || *in.Longitude > 180) {
		return "longitude invalide"
	}
	if in.PaymentTermsDays != nil && (*in.PaymentTermsDays < -1 || *in.PaymentTermsDays > 3650) {
		return "délai de paiement invalide (jours, -1 = défaut du magasin)"
	}
	return ""
}

// applyPartnerCRM writes the CRM fields present in the input.
func (s *Server) applyPartnerCRM(id string, in *partnerInput, _ bool) string {
	sets, args := []string{}, []any{}
	str := func(col string, v *string) {
		if v != nil {
			sets = append(sets, col+" = ?")
			args = append(args, strings.TrimSpace(*v))
		}
	}
	str("client_type", in.ClientType)
	str("crm_status", in.CRMStatus)
	str("wilaya", in.Wilaya)
	str("commune", in.Commune)
	str("opening_hours", in.OpeningHours)
	str("license_no", in.LicenseNo)
	str("whatsapp", in.Whatsapp)
	str("website", in.Website)
	str("source", in.Source)
	if in.RepUserID != nil {
		v := strings.TrimSpace(*in.RepUserID)
		if v != "" {
			var n int
			s.db.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, v).Scan(&n)
			if n == 0 {
				return "commercial introuvable"
			}
		}
		sets = append(sets, "rep_user_id = ?")
		args = append(args, nullIfEmpty(v))
	}
	if in.RouteID != nil {
		v := strings.TrimSpace(*in.RouteID)
		if v != "" {
			var n int
			s.db.QueryRow(`SELECT COUNT(*) FROM delivery_routes WHERE id = ?`, v).Scan(&n)
			if n == 0 {
				return "tournée introuvable"
			}
		}
		sets = append(sets, "route_id = ?")
		args = append(args, nullIfEmpty(v))
	}
	if in.Latitude != nil {
		sets = append(sets, "latitude = ?")
		args = append(args, *in.Latitude)
	}
	if in.Longitude != nil {
		sets = append(sets, "longitude = ?")
		args = append(args, *in.Longitude)
	}
	if in.PaymentTermsDays != nil {
		sets = append(sets, "payment_terms_days = ?")
		if *in.PaymentTermsDays < 0 {
			args = append(args, nil)
		} else {
			args = append(args, *in.PaymentTermsDays)
		}
	}
	if len(sets) > 0 {
		args = append(args, id)
		if _, err := s.db.Exec(`UPDATE partners SET `+strings.Join(sets, ", ")+` WHERE id = ?`, args...); err != nil {
			return err.Error()
		}
	}
	if in.TagIDs != nil {
		if msg := s.setPartnerTags(id, *in.TagIDs); msg != "" {
			return msg
		}
	}
	return ""
}

// setPartnerTags replaces the tags of a partner.
func (s *Server) setPartnerTags(id string, tagIDs []string) string {
	tx, err := s.db.Begin()
	if err != nil {
		return err.Error()
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM partner_tags WHERE partner_id = ?`, id); err != nil {
		return err.Error()
	}
	now := domain.NowISO()
	for _, t := range tagIDs {
		if strings.TrimSpace(t) == "" {
			continue
		}
		var n int
		tx.QueryRow(`SELECT COUNT(*) FROM tags WHERE id = ?`, t).Scan(&n)
		if n == 0 {
			return "étiquette introuvable"
		}
		if _, err := tx.Exec(`INSERT OR IGNORE INTO partner_tags (partner_id, tag_id, created_at) VALUES (?, ?, ?)`,
			id, t, now); err != nil {
			return err.Error()
		}
	}
	if err := tx.Commit(); err != nil {
		return err.Error()
	}
	return ""
}
