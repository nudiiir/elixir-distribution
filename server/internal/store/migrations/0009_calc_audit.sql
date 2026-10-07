-- Corrections de l'audit des calculs (octobre 2026).
-- Contrepassations : marquées pour que le rejeu du journal sache défaire le CUMP.
ALTER TABLE stock_ledger ADD COLUMN is_reversal INTEGER NOT NULL DEFAULT 0;
-- Réévaluation (écart de prix facture/réception) : ligne à quantité nulle qui
-- fixe le CUMP absolu après correction ; le rejeu l'applique telle quelle.
ALTER TABLE stock_ledger ADD COLUMN avg_after INTEGER;
-- Inventaire : quantité théorique au moment du comptage (l'écart est calculé
-- contre elle, pas contre le stock au moment de la validation).
ALTER TABLE document_lines ADD COLUMN expected_milli INTEGER;

-- Les quantités par lot n'étaient jamais maintenues par les mouvements :
-- le journal fait foi pour tout lot qui en porte au moins une écriture.
UPDATE lots SET qty_milli = (SELECT COALESCE(SUM(sl.qty_delta_milli), 0)
                               FROM stock_ledger sl WHERE sl.lot_id = lots.id)
 WHERE EXISTS (SELECT 1 FROM stock_ledger sl WHERE sl.lot_id = lots.id);
