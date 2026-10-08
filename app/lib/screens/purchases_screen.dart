import 'package:flutter/material.dart';

import '../api/client.dart';
import '../widgets/doc_editor.dart';
import '../widgets/doc_list.dart';
import '../widgets/list_toolbar.dart';
import 'sales_screen.dart' show saleEditorFor;

const _purchaseTypes = [
  'PURCHASE_ORDER',
  'PURCHASE_RECEIPT',
  'PURCHASE_INVOICE',
  'PURCHASE_CREDIT_NOTE',
];

DocEditorConfig? purchaseEditorFor(String docType) => switch (docType) {
      'PURCHASE_ORDER' => purchaseOrderConfig,
      'PURCHASE_RECEIPT' => purchaseReceiptConfig,
      'PURCHASE_INVOICE' => purchaseInvoiceConfig,
      'PURCHASE_CREDIT_NOTE' => purchaseCreditNoteConfig,
      _ => saleEditorFor(docType),
    };

class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  final _listKey = GlobalKey<DocListPaneState>();
  Map<String, String> _partnerNames = const {};

  @override
  void initState() {
    super.initState();
    _loadPartners();
  }

  Future<void> _loadPartners() async {
    try {
      final ps = await widget.api.partners(limit: 500);
      if (mounted) {
        setState(() => _partnerNames = {for (final p in ps) p.id: p.name});
      }
    } catch (_) {}
  }

  Future<void> _newDoc(DocEditorConfig cfg) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DocEditorScreen(api: widget.api, config: cfg),
    ));
    if (changed == true) {
      _loadPartners();
      _listKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Achats',
            primaryLabel: 'Nouvelle réception',
            primaryIcon: Icons.move_to_inbox_outlined,
            onPrimary: () => _newDoc(purchaseReceiptConfig),
            more: [
              MenuEntry('Bon de commande', Icons.shopping_cart_outlined,
                  () => _newDoc(purchaseOrderConfig)),
              MenuEntry('Facture fournisseur', Icons.receipt_outlined,
                  () => _newDoc(purchaseInvoiceConfig)),
              MenuEntry('Avoir fournisseur', Icons.assignment_return_outlined,
                  () => _newDoc(purchaseCreditNoteConfig)),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: DocListPane(
              key: _listKey,
              api: widget.api,
              allTypes: _purchaseTypes,
              partnerNames: _partnerNames,
              partnerKind: 'supplier',
              editorFor: purchaseEditorFor,
              exportName: 'achats',
              exportTitle: 'Achats',
              prefsKey: 'purchases',
              emptyActions: [
                ('Bon de commande', () => _newDoc(purchaseOrderConfig)),
                ('Nouvelle réception', () => _newDoc(purchaseReceiptConfig)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
