-- Fixes from the calculation audit (October 2026).
-- Reversals: flagged so the ledger replay knows how to undo the weighted average cost.
ALTER TABLE stock_ledger ADD COLUMN is_reversal INTEGER NOT NULL DEFAULT 0;
-- Revaluation (invoice/receipt price variance): zero-quantity row that
-- sets the absolute weighted average cost after correction; the replay applies it as is.
ALTER TABLE stock_ledger ADD COLUMN avg_after INTEGER;
-- Inventory: theoretical quantity at count time (the variance is computed
-- against it, not against the stock at validation time).
ALTER TABLE document_lines ADD COLUMN expected_milli INTEGER;

-- Per-lot quantities were never maintained by the movements:
-- the ledger is authoritative for any lot that has at least one entry.
UPDATE lots SET qty_milli = (SELECT COALESCE(SUM(sl.qty_delta_milli), 0)
                               FROM stock_ledger sl WHERE sl.lot_id = lots.id)
 WHERE EXISTS (SELECT 1 FROM stock_ledger sl WHERE sl.lot_id = lots.id);
