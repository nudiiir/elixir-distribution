package analytics

import (
	"fmt"
	"strings"
	"time"
)

// Range : période demandée, relative (résolue à l'exécution, en heure
// locale de la machine) ou absolue.
type Range struct {
	Type string `json:"type"` // today, yesterday, this_week, previous_week, this_month, previous_month,
	//   this_quarter, previous_quarter, this_year, previous_year, year_to_date,
	//   last_n_days, last_n_months, all, custom
	N    int    `json:"n,omitempty"`
	From string `json:"from,omitempty"` // YYYY-MM-DD inclus (custom)
	To   string `json:"to,omitempty"`
}

// Resolved : bornes absolues incluses.
type Resolved struct {
	From string `json:"from"`
	To   string `json:"to"`
	All  bool   `json:"all"` // aucune borne
}

const dayFmt = "2006-01-02"

func startOfWeek(t time.Time, weekStart int) time.Time {
	d := (int(t.Weekday()) - weekStart + 7) % 7
	return time.Date(t.Year(), t.Month(), t.Day()-d, 0, 0, 0, 0, t.Location())
}

// Resolve calcule les bornes. now est en heure locale ; weekStart 0=dimanche…6.
func (r Range) Resolve(now time.Time, weekStart int) (Resolved, error) {
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	f := func(a, b time.Time) Resolved { return Resolved{From: a.Format(dayFmt), To: b.Format(dayFmt)} }
	switch r.Type {
	case "", "this_month":
		a := time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, today.Location())
		return f(a, a.AddDate(0, 1, -1)), nil
	case "today":
		return f(today, today), nil
	case "yesterday":
		y := today.AddDate(0, 0, -1)
		return f(y, y), nil
	case "this_week":
		a := startOfWeek(today, weekStart)
		return f(a, a.AddDate(0, 0, 6)), nil
	case "previous_week":
		a := startOfWeek(today, weekStart).AddDate(0, 0, -7)
		return f(a, a.AddDate(0, 0, 6)), nil
	case "previous_month":
		a := time.Date(today.Year(), today.Month()-1, 1, 0, 0, 0, 0, today.Location())
		return f(a, a.AddDate(0, 1, -1)), nil
	case "this_quarter":
		q := (int(today.Month()) - 1) / 3
		a := time.Date(today.Year(), time.Month(q*3+1), 1, 0, 0, 0, 0, today.Location())
		return f(a, a.AddDate(0, 3, -1)), nil
	case "previous_quarter":
		q := (int(today.Month()) - 1) / 3
		a := time.Date(today.Year(), time.Month(q*3+1), 1, 0, 0, 0, 0, today.Location()).AddDate(0, -3, 0)
		return f(a, a.AddDate(0, 3, -1)), nil
	case "this_year":
		a := time.Date(today.Year(), 1, 1, 0, 0, 0, 0, today.Location())
		return f(a, a.AddDate(1, 0, -1)), nil
	case "previous_year":
		a := time.Date(today.Year()-1, 1, 1, 0, 0, 0, 0, today.Location())
		return f(a, a.AddDate(1, 0, -1)), nil
	case "year_to_date":
		a := time.Date(today.Year(), 1, 1, 0, 0, 0, 0, today.Location())
		return f(a, today), nil
	case "last_n_days":
		n := r.N
		if n <= 0 {
			n = 30
		}
		if n > 3660 {
			n = 3660
		}
		return f(today.AddDate(0, 0, -n+1), today), nil
	case "last_n_months":
		n := r.N
		if n <= 0 {
			n = 3
		}
		if n > 120 {
			n = 120
		}
		a := time.Date(today.Year(), today.Month()-time.Month(n)+1, 1, 0, 0, 0, 0, today.Location())
		return f(a, today), nil
	case "all":
		return Resolved{All: true}, nil
	case "custom":
		a, err := time.ParseInLocation(dayFmt, r.From, now.Location())
		if err != nil {
			return Resolved{}, fmt.Errorf("date de début invalide")
		}
		b, err := time.ParseInLocation(dayFmt, r.To, now.Location())
		if err != nil {
			return Resolved{}, fmt.Errorf("date de fin invalide")
		}
		if b.Before(a) {
			return Resolved{}, fmt.Errorf("la fin précède le début")
		}
		if b.Sub(a) > 3660*24*time.Hour {
			return Resolved{}, fmt.Errorf("période trop longue (10 ans max)")
		}
		return f(a, b), nil
	}
	return Resolved{}, fmt.Errorf("période inconnue : %s", r.Type)
}

// Previous : période de même longueur immédiatement précédente.
func (rs Resolved) Previous(loc *time.Location) Resolved {
	if rs.All {
		return rs
	}
	a, _ := time.ParseInLocation(dayFmt, rs.From, loc)
	b, _ := time.ParseInLocation(dayFmt, rs.To, loc)
	n := int(b.Sub(a).Hours()/24) + 1
	return Resolved{From: a.AddDate(0, 0, -n).Format(dayFmt), To: a.AddDate(0, 0, -1).Format(dayFmt)}
}

// ---- seaux temporels ----------------------------------------------------------

var validBuckets = map[string]bool{"day": true, "week": true, "month": true, "quarter": true, "year": true, "dow": true, "hour": true}

// bucketExpr : expression SQL du seau pour une colonne date (YYYY-MM-DD)
// ou datetime (RFC3339 UTC, ramenée en heure locale).
func bucketExpr(col, typ, bucket string, weekStart int) string {
	dateExpr := col
	timeExpr := col
	if typ == "datetime" {
		dateExpr = fmt.Sprintf("date(%s,'localtime')", col)
		timeExpr = fmt.Sprintf("datetime(%s,'localtime')", col)
	}
	switch bucket {
	case "day":
		return dateExpr
	case "week":
		return fmt.Sprintf("date(%s, '-' || ((CAST(strftime('%%w', %s) AS INTEGER) + 7 - %d) %% 7) || ' days')", dateExpr, dateExpr, weekStart)
	case "month":
		return fmt.Sprintf("strftime('%%Y-%%m', %s)", dateExpr)
	case "quarter":
		return fmt.Sprintf("strftime('%%Y', %s) || '-Q' || ((CAST(strftime('%%m', %s) AS INTEGER) + 2) / 3)", dateExpr, dateExpr)
	case "year":
		return fmt.Sprintf("strftime('%%Y', %s)", dateExpr)
	case "dow":
		return fmt.Sprintf("CAST(strftime('%%w', %s) AS INTEGER)", dateExpr)
	case "hour":
		return fmt.Sprintf("CAST(strftime('%%H', %s) AS INTEGER)", timeExpr)
	}
	return dateExpr
}

// bucketDomain : toutes les valeurs de seau de la période (remplissage à zéro).
// Pour dow et hour le domaine est fixe (7 / 24) ; dow est ordonné à partir du
// jour de début de semaine configuré.
func bucketDomain(bucket string, rs Resolved, weekStart int, loc *time.Location) []any {
	switch bucket {
	case "dow":
		out := make([]any, 0, 7)
		for i := 0; i < 7; i++ {
			out = append(out, int64((weekStart+i)%7))
		}
		return out
	case "hour":
		out := make([]any, 0, 24)
		for i := 0; i < 24; i++ {
			out = append(out, int64(i))
		}
		return out
	}
	if rs.All {
		return nil // pas de domaine sans bornes : seules les valeurs observées
	}
	a, _ := time.ParseInLocation(dayFmt, rs.From, loc)
	b, _ := time.ParseInLocation(dayFmt, rs.To, loc)
	var out []any
	switch bucket {
	case "day":
		for d := a; !d.After(b); d = d.AddDate(0, 0, 1) {
			out = append(out, d.Format(dayFmt))
		}
	case "week":
		for d := startOfWeek(a, weekStart); !d.After(b); d = d.AddDate(0, 0, 7) {
			out = append(out, d.Format(dayFmt))
		}
	case "month":
		for d := time.Date(a.Year(), a.Month(), 1, 0, 0, 0, 0, loc); !d.After(b); d = d.AddDate(0, 1, 0) {
			out = append(out, d.Format("2006-01"))
		}
	case "quarter":
		q := (int(a.Month()) - 1) / 3
		for d := time.Date(a.Year(), time.Month(q*3+1), 1, 0, 0, 0, 0, loc); !d.After(b); d = d.AddDate(0, 3, 0) {
			out = append(out, fmt.Sprintf("%d-Q%d", d.Year(), (int(d.Month())-1)/3+1))
		}
	case "year":
		for y := a.Year(); y <= b.Year(); y++ {
			out = append(out, fmt.Sprintf("%d", y))
		}
	}
	if len(out) > 5000 {
		out = out[:5000]
	}
	return out
}

// bucketLabel : libellé français d'une valeur de seau.
func bucketLabel(bucket string, v any) string {
	switch bucket {
	case "dow":
		names := []string{"Dimanche", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi"}
		if n, ok := toInt(v); ok && n >= 0 && n < 7 {
			return names[n]
		}
	case "hour":
		if n, ok := toInt(v); ok {
			return fmt.Sprintf("%02dh", n)
		}
	case "month":
		if s, ok := v.(string); ok && len(s) == 7 {
			months := []string{"janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."}
			var y, m int
			fmt.Sscanf(s, "%d-%d", &y, &m)
			if m >= 1 && m <= 12 {
				return fmt.Sprintf("%s %d", months[m-1], y)
			}
		}
	case "week":
		if s, ok := v.(string); ok {
			return "Sem. du " + s
		}
	}
	return fmt.Sprint(v)
}

func toInt(v any) (int, bool) {
	switch x := v.(type) {
	case int64:
		return int(x), true
	case int:
		return x, true
	case float64:
		return int(x), true
	case string:
		var n int
		if _, err := fmt.Sscanf(strings.TrimSpace(x), "%d", &n); err == nil {
			return n, true
		}
	}
	return 0, false
}
