package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"elixir/server/internal/analytics"
)

// GET /analytics/gallery — les questions prêtes à l'emploi.
func (s *Server) analyticsGallery(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": analytics.Gallery()})
}

type askInput struct {
	Question string `json:"question"`
}

type askOutput struct {
	Question      string            `json:"question"`
	Spec          any               `json:"spec"`
	ChartType     string            `json:"chart_type"`
	Title         string            `json:"title"`
	Explanation   string            `json:"explanation"`
	Clarification string            `json:"clarification,omitempty"`
	Provider      string            `json:"provider"` // cloud | local
	Model         string            `json:"model,omitempty"`
	Attempts      int               `json:"attempts"`
	Result        *analytics.Result `json:"result,omitempty"`
	Error         string            `json:"error,omitempty"`
	DurationMs    int64             `json:"duration_ms"`
}

// compactSchema : la liste blanche visible par l'appelant, réduite au strict
// nécessaire pour le modèle (clés, libellés, types, seaux, énumérations).
func compactSchema(c analytics.Caller) []map[string]any {
	out := []map[string]any{}
	for _, src := range analytics.VisibleSchema(c) {
		fields := []map[string]any{}
		for _, f := range src["fields"].([]analytics.Field) {
			m := map[string]any{"key": f.Key, "label": f.LabelFR, "type": f.Type}
			if f.Dimension && f.Measure {
				m["use"] = "dimension|measure"
			} else if f.Dimension {
				m["use"] = "dimension"
			} else if f.Measure {
				m["use"] = "measure"
			}
			if len(f.Buckets) > 0 {
				m["buckets"] = f.Buckets
			}
			if len(f.EnumValues) > 0 {
				m["values"] = f.EnumValues
			}
			if f.Unit != "" {
				m["unit"] = f.Unit
			}
			fields = append(fields, m)
		}
		named := []map[string]any{}
		for _, n := range src["named_measures"].([]analytics.NamedMeasure) {
			named = append(named, map[string]any{"key": n.Key, "label": n.LabelFR, "format": n.Format})
		}
		item := map[string]any{"source": src["key"], "label": src["label_fr"], "fields": fields, "measures": named}
		if df, _ := src["date_field"].(string); df != "" {
			item["date_field"] = df
		}
		if params, ok := src["params"].([]analytics.Param); ok && len(params) > 0 {
			item["params"] = params
		}
		out = append(out, item)
	}
	return out
}

// POST /analytics/ask — question en langage naturel → spec → résultat.
// Le modèle ne reçoit que la question et le schéma ; la spec revient ici, est
// validée et exécutée localement. Une seconde tentative est faite avec le
// message d'erreur si la première est refusée. Sans cloud : appariement
// local sur la galerie.
func (s *Server) analyticsAsk(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "reports") {
		forbid(w)
		return
	}
	var in askInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	q := strings.TrimSpace(in.Question)
	if q == "" || len(q) > 600 {
		writeErr(w, http.StatusBadRequest, "question requise (600 caractères max)")
		return
	}
	start := time.Now()
	caller := s.analyticsCaller(r)
	out := askOutput{Question: q}

	cfg := LoadCloudSettings(s.db)
	llmURL := strings.TrimSuffix(settingOr(cfg, "llm_url", defaultLLMURL), "/")
	shop := cfg["relay_subdomain"]
	auth := r.Header.Get("Authorization")
	cloudOK := shop != "" && cfg["relay_enabled"] == "1" && auth != ""

	var lastErr string
	var lastSpec any
	if cloudOK {
		schema := compactSchema(caller)
		for attempt := 1; attempt <= 2; attempt++ {
			out.Attempts = attempt
			resp, err := s.callSpecService(llmURL, auth, shop, map[string]any{
				"question": q, "schema": schema, "today": time.Now().Format("2006-01-02"),
				"error": lastErr, "previous": lastSpec,
			})
			if err != nil {
				out.Error = err.Error()
				break
			}
			out.Spec, out.ChartType, out.Title, out.Explanation = resp.Spec, resp.ChartType, resp.Title, resp.Explanation
			out.Clarification, out.Provider, out.Model = resp.Clarification, "cloud", resp.Model
			js, _ := json.Marshal(resp.Spec)
			var rq analytics.Request
			if err := json.Unmarshal(js, &rq); err != nil {
				lastErr, lastSpec = "spécification illisible", resp.Spec
				continue
			}
			res, err := s.analytics.Run(r.Context(), rq, caller)
			if err == nil {
				out.Result = res
				out.Error = ""
				break
			}
			var ae *analytics.Error
			if errors.As(err, &ae) && (ae.Code == "bad_request" || ae.Code == "forbidden") {
				lastErr, lastSpec = ae.Message, resp.Spec
				out.Error = ae.Message
				continue
			}
			out.Error = err.Error()
			break
		}
	}

	// ---- repli local (hors ligne, ou cloud en échec)
	if out.Result == nil {
		if it := analytics.MatchGallery(q); it != nil {
			out.Provider = "local"
			out.Spec, out.ChartType, out.Title = it.Spec, it.ChartType, it.Title
			out.Explanation = "Question reconnue dans la galerie : « " + it.Title + " »"
			if res, err := s.analytics.Run(r.Context(), it.Spec, caller); err == nil {
				out.Result = res
				out.Error = ""
			} else {
				out.Error = err.Error()
			}
		} else if out.Provider == "" {
			out.Provider = "local"
			if !cloudOK {
				out.Error = "assistant cloud non connecté et question inconnue de la galerie — reformulez ou utilisez le constructeur"
			}
		}
	}
	out.DurationMs = time.Since(start).Milliseconds()
	status := http.StatusOK
	if out.Result == nil {
		status = http.StatusUnprocessableEntity
	}
	writeJSON(w, status, out)
}

type specServiceResponse struct {
	Spec          any    `json:"spec"`
	ChartType     string `json:"chart_type"`
	Title         string `json:"title"`
	Explanation   string `json:"explanation"`
	Clarification string `json:"clarification"`
	Provider      string `json:"provider"`
	Model         string `json:"model"`
	Error         string `json:"error"`
}

func (s *Server) callSpecService(base, auth, shop string, body map[string]any) (*specServiceResponse, error) {
	js, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, base+"/analytics/spec", bytes.NewReader(js))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", auth)
	req.Header.Set("X-Shop-Id", shop)
	client := &http.Client{Timeout: 35 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return nil, errors.New("assistant injoignable : " + err.Error())
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 256<<10))
	var out specServiceResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, errors.New("réponse de l'assistant illisible")
	}
	if res.StatusCode != http.StatusOK {
		if out.Error != "" {
			return nil, errors.New(out.Error)
		}
		return nil, errors.New("assistant : HTTP " + res.Status)
	}
	return &out, nil
}
