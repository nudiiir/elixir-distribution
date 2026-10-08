// Models of the Stock screen endpoints (/stock/ledger, /stock/reorder,
// /stock/documents, /stock/inventory/{id}).

int _i(Object? v) => (v as num?)?.toInt() ?? 0;

/// One movement of the stock journal, with the running balance of its
/// product × depot after it.
class LedgerRow {
  LedgerRow.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as String?) ?? '',
        createdAt = (j['created_at'] as String?) ?? '',
        docType = (j['doc_type'] as String?) ?? '',
        number = j['number'] as String?,
        documentId = (j['document_id'] as String?) ?? '',
        warehouseId = (j['warehouse_id'] as String?) ?? '',
        warehouseName = (j['warehouse_name'] as String?) ?? '',
        productId = (j['product_id'] as String?) ?? '',
        productName = (j['product_name'] as String?) ?? '',
        lotNumber = j['lot_number'] as String?,
        inMilli = _i(j['in_milli']),
        outMilli = _i(j['out_milli']),
        balanceMilli = _i(j['balance_milli']),
        unitCost = _i(j['unit_cost']),
        isReversal = j['is_reversal'] == true;

  final String id;
  final String createdAt; // RFC3339 UTC
  final String docType;
  final String? number;
  final String documentId;
  final String warehouseId;
  final String warehouseName;
  final String productId;
  final String productName;
  final String? lotNumber;
  final int inMilli;
  final int outMilli;
  final int balanceMilli;
  final int unitCost;
  final bool isReversal;

  int get deltaMilli => inMilli - outMilli;

  /// Local date-time of the movement.
  DateTime? get at => DateTime.tryParse(createdAt)?.toLocal();
}

class StockLedger {
  StockLedger.fromJson(Map<String, dynamic> j)
      : openingMilli = _i(j['opening_milli']),
        inMilli = _i(j['in_milli']),
        outMilli = _i(j['out_milli']),
        closingMilli = _i(j['closing_milli']),
        openingValue = _i(j['opening_value']),
        closingValue = _i(j['closing_value']),
        truncated = j['truncated'] == true,
        rows = [
          for (final e in (j['rows'] as List? ?? const []))
            LedgerRow.fromJson(e as Map<String, dynamic>)
        ];

  final int openingMilli;
  final int inMilli;
  final int outMilli;
  final int closingMilli;
  final int openingValue;
  final int closingValue;
  final bool truncated;
  final List<LedgerRow> rows;
}

/// A replenishment proposal for one product (« À commander »).
class ReorderRow {
  ReorderRow.fromJson(Map<String, dynamic> j)
      : productId = (j['product_id'] as String?) ?? '',
        productName = (j['product_name'] as String?) ?? '',
        barcode = j['barcode'] as String?,
        unit = (j['unit'] as String?) ?? 'piece',
        imageRev = _i(j['image_rev']),
        qtyMilli = _i(j['qty_milli']),
        minStockMilli = _i(j['min_stock_milli']),
        sold30Milli = _i(j['sold_30d_milli']),
        avgDailyMilli = _i(j['avg_daily_milli']),
        coverageDays = (j['coverage_days'] as num?)?.toInt(),
        supplierId = j['supplier_id'] as String?,
        supplierName = j['supplier_name'] as String?,
        lastUnitCost = _i(j['last_unit_cost']),
        packName = j['pack_name'] as String?,
        packFactorMilli = _i(j['pack_factor_milli']),
        targetMilli = _i(j['target_milli']),
        suggestedMilli = _i(j['suggested_milli']),
        urgent = j['urgent'] == true,
        vatRate = _i(j['vat_rate']);

  final String productId;
  final String productName;
  final String? barcode;
  final String unit;
  final int imageRev;
  final int qtyMilli;
  final int minStockMilli;
  final int sold30Milli;
  final int avgDailyMilli;
  final int? coverageDays; // null = aucune vente
  final String? supplierId;
  final String? supplierName;
  final int lastUnitCost; // centimes HT / unité de base
  final String? packName;
  final int packFactorMilli; // 0 = pas de conditionnement
  final int targetMilli;
  final int suggestedMilli;
  final bool urgent;
  final int vatRate;
}

/// An adjustment / inventory / transfer document as the stock lists show it.
class StockDoc {
  StockDoc.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        docType = (j['doc_type'] as String?) ?? '',
        number = j['number'] as String?,
        status = (j['status'] as String?) ?? 'draft',
        docDate = (j['doc_date'] as String?) ?? '',
        warehouseId = j['warehouse_id'] as String?,
        warehouseName = j['warehouse_name'] as String?,
        destWarehouseId = j['dest_warehouse_id'] as String?,
        destWarehouseName = j['dest_warehouse_name'] as String?,
        reason = j['reason'] as String?,
        notes = j['notes'] as String?,
        lineCount = _i(j['line_count']),
        inMilli = _i(j['in_milli']),
        outMilli = _i(j['out_milli']),
        value = _i(j['value']),
        createdBy = j['created_by'] as String?,
        createdAt = (j['created_at'] as String?) ?? '',
        updatedAt = (j['updated_at'] as String?) ?? '';

  final String id;
  final String docType;
  final String? number;
  final String status;
  final String docDate;
  final String? warehouseId;
  final String? warehouseName;
  final String? destWarehouseId;
  final String? destWarehouseName;
  final String? reason;
  final String? notes;
  final int lineCount;
  final int inMilli;
  final int outMilli;
  final int value; // valeur nette mouvementée dans le dépôt source
  final String? createdBy;
  final String createdAt;
  final String updatedAt;
}

class InvDraftLine {
  InvDraftLine.fromJson(Map<String, dynamic> j)
      : productId = (j['product_id'] as String?) ?? '',
        qtyMilli = _i(j['qty_milli']),
        expectedMilli = (j['expected_milli'] as num?)?.toInt(),
        description = (j['description'] as String?) ?? '';
  final String productId;
  final String description;
  final int qtyMilli;
  final int? expectedMilli;
}

/// A saved (draft) inventory session.
class InvDraft {
  InvDraft.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        status = (j['status'] as String?) ?? 'draft',
        docDate = (j['doc_date'] as String?) ?? '',
        warehouseId = j['warehouse_id'] as String?,
        notes = j['notes'] as String?,
        lines = [
          for (final e in (j['lines'] as List? ?? const []))
            InvDraftLine.fromJson(e as Map<String, dynamic>)
        ];
  final String id;
  final String status;
  final String docDate;
  final String? warehouseId;
  final String? notes;
  final List<InvDraftLine> lines;
}
