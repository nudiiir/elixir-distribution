-- Product sheet for the online shop: free text + « Clé: Valeur » lines
-- that the storefront renders as a spec table.
ALTER TABLE products ADD COLUMN description TEXT NOT NULL DEFAULT '';
