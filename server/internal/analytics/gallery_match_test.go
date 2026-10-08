package analytics

import "testing"

func TestMatchGalleryRetailQuestions(t *testing.T) {
	cases := map[string]string{
		"quels clients me doivent le plus":       "Crédits clients en cours",
		"marge par catégorie ce mois":            "Marge par catégorie",
		"mes 10 produits les plus vendus":        "Top 15 produits vendus",
		"ventes par mode de paiement":            "Ventes par mode de paiement",
		"combien je dois à mes fournisseurs":     "Dettes fournisseurs",
		"quels sont mes meilleurs clients":       "Meilleurs clients",
		"chiffre d'affaires par jour ce mois-ci": "Chiffre d'affaires par jour ce mois",
	}
	for q, want := range cases {
		got := MatchGallery(q)
		if got == nil || got.Title != want {
			title := "<nil>"
			if got != nil {
				title = got.Title
			}
			t.Errorf("%q → %s, want %s", q, title, want)
		}
	}
	for _, it := range Gallery() {
		if it.Title == "Produits réglementés vendus (registre)" {
			t.Errorf("sector-specific gallery item still present")
		}
	}
}
