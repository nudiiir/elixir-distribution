-- Fiche produit pour la boutique en ligne : texte libre + lignes « Clé: Valeur »
-- que la vitrine rend en tableau de caractéristiques.
ALTER TABLE products ADD COLUMN description TEXT NOT NULL DEFAULT '';
