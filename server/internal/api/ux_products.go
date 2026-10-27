package api

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/domain"
)

// routesProductsUX registers the products routes added by the UX-benchmark work.
func (s *Server) routesProductsUX(r chi.Router) {
	r.Post("/products/bulk", s.bulkProducts)
	r.Post("/products/{id}/images", s.addProductImage)
	r.Get("/products/{id}/images/{index}", s.getProductImage)
	r.Delete("/products/{id}/images/{index}", s.deleteProductImage)
	r.Post("/products/{id}/images/{index}/main", s.mainProductImage)
}

// ---------------------------------------------------------------- photos

const (
	maxImageBytes    = 2 << 20 // 2 MB per photo
	maxImagesPerProd = 8
	thumbSize        = 160
)

var errImageType = errors.New("format refusé : JPEG ou PNG uniquement")

// readImageBody accepts either a raw body (Content-Type image/jpeg|png or
// sniffed) or a multipart form whose first file is the photo.
func readImageBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	r.Body = http.MaxBytesReader(w, r.Body, maxImageBytes+64<<10)
	ct := r.Header.Get("Content-Type")
	var src io.Reader = r.Body
	if strings.HasPrefix(ct, "multipart/") {
		if err := r.ParseMultipartForm(maxImageBytes + 64<<10); err != nil {
			return nil, fmt.Errorf("formulaire illisible : %w", err)
		}
		var file io.ReadCloser
		for _, fhs := range r.MultipartForm.File {
			if len(fhs) > 0 {
				f, err := fhs[0].Open()
				if err != nil {
					return nil, err
				}
				file = f
				break
			}
		}
		if file == nil {
			return nil, errors.New("aucun fichier dans le formulaire")
		}
		defer file.Close()
		src = file
	}
	data, err := io.ReadAll(io.LimitReader(src, maxImageBytes+1))
	if err != nil {
		return nil, fmt.Errorf("photo trop lourde ou illisible : %w", err)
	}
	if len(data) > maxImageBytes {
		return nil, errors.New("photo trop lourde (2 Mo maximum)")
	}
	if len(data) == 0 {
		return nil, errors.New("photo vide")
	}
	return data, nil
}

// makeThumbnail decodes a JPEG/PNG and returns (mime of the original,
// thumbnail bytes encoded in the same format, fitted in thumbSize×thumbSize).
func makeThumbnail(data []byte) (string, []byte, error) {
	mime := http.DetectContentType(data)
	if mime != "image/jpeg" && mime != "image/png" {
		return "", nil, errImageType
	}
	var src image.Image
	var err error
	if mime == "image/png" {
		src, err = png.Decode(bytes.NewReader(data))
	} else {
		src, err = jpeg.Decode(bytes.NewReader(data))
	}
	if err != nil {
		return "", nil, fmt.Errorf("image illisible : %w", err)
	}
	dst := downscale(src, thumbSize)
	var buf bytes.Buffer
	if mime == "image/png" {
		err = png.Encode(&buf, dst)
	} else {
		err = jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 82})
	}
	if err != nil {
		return "", nil, err
	}
	return mime, buf.Bytes(), nil
}

// downscale fits src in max×max with an area average (box filter): every
// destination pixel is the mean of the source pixels it covers. Never
// upscales.
func downscale(src image.Image, max int) *image.NRGBA {
	b := src.Bounds()
	sw, sh := b.Dx(), b.Dy()
	if sw <= 0 || sh <= 0 {
		return image.NewNRGBA(image.Rect(0, 0, 1, 1))
	}
	dw, dh := sw, sh
	if sw > max || sh > max {
		if sw >= sh {
			dw, dh = max, sh*max/sw
		} else {
			dw, dh = sw*max/sh, max
		}
	}
	if dw < 1 {
		dw = 1
	}
	if dh < 1 {
		dh = 1
	}
	dst := image.NewNRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < dh; y++ {
		y0 := b.Min.Y + y*sh/dh
		y1 := b.Min.Y + (y+1)*sh/dh
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < dw; x++ {
			x0 := b.Min.X + x*sw/dw
			x1 := b.Min.X + (x+1)*sw/dw
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var r, g, bl, a, n uint64
			for yy := y0; yy < y1; yy++ {
				for xx := x0; xx < x1; xx++ {
					c := color.NRGBA64Model.Convert(src.At(xx, yy)).(color.NRGBA64)
					r += uint64(c.R)
					g += uint64(c.G)
					bl += uint64(c.B)
					a += uint64(c.A)
					n++
				}
			}
			dst.SetNRGBA(x, y, color.NRGBA{
				R: uint8(r / n >> 8), G: uint8(g / n >> 8),
				B: uint8(bl / n >> 8), A: uint8(a / n >> 8),
			})
		}
	}
	return dst
}

func (s *Server) productName(id string) (string, bool) {
	var name string
	if err := s.db.QueryRow(`SELECT name FROM products WHERE id = ?`, id).Scan(&name); err != nil {
		return "", false
	}
	return name, true
}

func (s *Server) addProductImage(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "products") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	name, ok := s.productName(id)
	if !ok {
		writeErr(w, http.StatusNotFound, "product not found")
		return
	}
	data, err := readImageBody(w, r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	mime, thumb, err := makeThumbnail(data)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	var n int
	tx.QueryRow(`SELECT COUNT(*) FROM product_images WHERE product_id = ?`, id).Scan(&n)
	if n >= maxImagesPerProd {
		writeErr(w, http.StatusConflict, fmt.Sprintf("%d photos maximum par produit", maxImagesPerProd))
		return
	}
	now := domain.NowISO()
	if _, err := tx.Exec(`INSERT INTO product_images (id, product_id, position, mime, data, thumb, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, domain.NewID(), id, n, mime, data, thumb, now); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if _, err := tx.Exec(`UPDATE products SET image_rev = image_rev + 1, updated_at = ? WHERE id = ?`,
		now, id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "product.image_add", "product", id, name+" : photo ajoutée")
	s.getByID(w, r, id)
}

func imageIndex(r *http.Request) (int, bool) {
	i, err := strconv.Atoi(chi.URLParam(r, "index"))
	return i, err == nil && i >= 0
}

func (s *Server) getProductImage(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	idx, ok := imageIndex(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "index invalide")
		return
	}
	col := "data"
	if r.URL.Query().Get("thumb") == "1" {
		col = "thumb"
	}
	var mime string
	var data []byte
	err := s.db.QueryRow(`SELECT mime, `+col+` FROM product_images
		WHERE product_id = ? ORDER BY position, created_at LIMIT 1 OFFSET ?`, id, idx).Scan(&mime, &data)
	if err == sql.ErrNoRows {
		writeErr(w, http.StatusNotFound, "photo introuvable")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", mime)
	// The client changes ?v=<image_rev> on every modification: the URL is
	// immutable, so it can stay cached for a long time.
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

// orderedImageIDs returns the photo ids in display order.
func orderedImageIDs(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, productID string) ([]string, error) {
	rows, err := q.Query(`SELECT id FROM product_images WHERE product_id = ?
		ORDER BY position, created_at`, productID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		ids = append(ids, v)
	}
	return ids, rows.Err()
}

// reorderImages rewrites positions 0..n-1 after removing the photo at the
// URL index (remove) or moving it first (front = « photo principale »).
func (s *Server) reorderImages(w http.ResponseWriter, r *http.Request, remove, front bool) {
	if !s.can(r, "products") {
		forbid(w)
		return
	}
	id := chi.URLParam(r, "id")
	name, ok := s.productName(id)
	if !ok {
		writeErr(w, http.StatusNotFound, "product not found")
		return
	}
	idx, ok := imageIndex(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "index invalide")
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	ids, err := orderedImageIDs(tx, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if idx >= len(ids) {
		writeErr(w, http.StatusNotFound, "photo introuvable")
		return
	}
	target := ids[idx]
	order := make([]string, 0, len(ids))
	if front {
		order = append(order, target)
	}
	for _, v := range ids {
		if v != target {
			order = append(order, v)
		}
	}
	if remove {
		if _, err := tx.Exec(`DELETE FROM product_images WHERE id = ?`, target); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	for pos, v := range order {
		if _, err := tx.Exec(`UPDATE product_images SET position = ? WHERE id = ?`, pos, v); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if _, err := tx.Exec(`UPDATE products SET image_rev = image_rev + 1, updated_at = ? WHERE id = ?`,
		domain.NowISO(), id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if remove {
		s.audit(r, "product.image_delete", "product", id, name+" : photo supprimée")
	} else {
		s.audit(r, "product.image_main", "product", id, name+" : photo principale changée")
	}
	s.getByID(w, r, id)
}

func (s *Server) deleteProductImage(w http.ResponseWriter, r *http.Request) {
	s.reorderImages(w, r, true, false)
}

func (s *Server) mainProductImage(w http.ResponseWriter, r *http.Request) {
	s.reorderImages(w, r, false, true)
}

// ---------------------------------------------------------------- bulk

type bulkInput struct {
	IDs        []string `json:"ids"`
	Op         string   `json:"op"`
	CategoryID *string  `json:"category_id"`
	VatRate    *int64   `json:"vat_rate"`
	PromoPrice *int64   `json:"promo_price"`
	PromoStart *string  `json:"promo_start"`
	PromoEnd   *string  `json:"promo_end"`
}

// bulkProducts applies one change to many products in a single transaction.
func (s *Server) bulkProducts(w http.ResponseWriter, r *http.Request) {
	if !s.can(r, "products") {
		forbid(w)
		return
	}
	var in bulkInput
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(in.IDs) == 0 {
		writeErr(w, http.StatusBadRequest, "aucun produit sélectionné")
		return
	}
	if len(in.IDs) > 5000 {
		writeErr(w, http.StatusBadRequest, "5000 produits maximum par opération")
		return
	}
	now := domain.NowISO()
	var set string
	var args []any
	var label string
	switch in.Op {
	case "set_category":
		var cat any
		if in.CategoryID != nil && strings.TrimSpace(*in.CategoryID) != "" {
			var n int
			s.db.QueryRow(`SELECT COUNT(*) FROM product_categories WHERE id = ?`, *in.CategoryID).Scan(&n)
			if n == 0 {
				writeErr(w, http.StatusBadRequest, "catégorie introuvable")
				return
			}
			cat = *in.CategoryID
		}
		set, args, label = "category_id = ?", []any{cat}, "catégorie changée"
	case "set_vat":
		if in.VatRate == nil || *in.VatRate < 0 || *in.VatRate > 10000 {
			writeErr(w, http.StatusBadRequest, "taux de TVA invalide")
			return
		}
		set, args = "vat_rate = ?", []any{*in.VatRate}
		label = fmt.Sprintf("TVA %d %%", *in.VatRate/100)
	case "set_promo":
		if in.PromoPrice == nil || *in.PromoPrice <= 0 {
			writeErr(w, http.StatusBadRequest, "prix promo obligatoire")
			return
		}
		start, end := emptyToNil(in.PromoStart), emptyToNil(in.PromoEnd)
		if start != nil && end != nil && *end < *start {
			writeErr(w, http.StatusBadRequest, "la fin de la promotion précède son début")
			return
		}
		set, args = "promo_price = ?, promo_start = ?, promo_end = ?", []any{*in.PromoPrice, start, end}
		label = "promotion " + centimes(*in.PromoPrice) + " DA"
	case "clear_promo":
		set, label = "promo_price = NULL, promo_start = NULL, promo_end = NULL", "promotion retirée"
	case "deactivate":
		set, label = "active = 0", "désactivés"
	case "activate":
		set, label = "active = 1", "réactivés"
	default:
		writeErr(w, http.StatusBadRequest, "opération inconnue")
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer tx.Rollback()
	stmt, err := tx.Prepare(`UPDATE products SET ` + set + `, updated_at = ? WHERE id = ?`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer stmt.Close()
	updated := int64(0)
	seen := map[string]bool{}
	for _, id := range in.IDs {
		if seen[id] {
			continue
		}
		seen[id] = true
		res, err := stmt.Exec(append(append([]any{}, args...), now, id)...)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		n, _ := res.RowsAffected()
		updated += n
	}
	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.audit(r, "product.bulk", "product", "",
		fmt.Sprintf("modification groupée (%s) : %d produit(s) %s", in.Op, updated, label))
	writeJSON(w, http.StatusOK, map[string]any{"updated": updated})
}

func emptyToNil(v *string) *string {
	if v == nil || strings.TrimSpace(*v) == "" {
		return nil
	}
	t := strings.TrimSpace(*v)
	return &t
}
