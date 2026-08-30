import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/tokens.dart';
import '../widgets/doc_editor.dart';
import '../widgets/doc_list.dart';
import '../widgets/ui.dart';
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
    if (changed == true) _listKey.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: Text('Achats', style: T.h1)),
            PopupMenuButton<DocEditorConfig>(
              tooltip: 'Autres documents',
              color: T.surface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(T.rInner)),
              onSelected: _newDoc,
              itemBuilder: (context) => [
                PopupMenuItem(
                    value: purchaseOrderConfig,
                    child: Text('Bon de commande', style: T.body)),
                PopupMenuItem(
                    value: purchaseInvoiceConfig,
                    child: Text('Facture fournisseur', style: T.body)),
                PopupMenuItem(
                    value: purchaseCreditNoteConfig,
                    child: Text('Avoir fournisseur', style: T.body)),
              ],
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: T.surface,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border3),
                ),
                child: const Row(children: [
                  Text('Autres',
                      style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: T.muted)),
                  SizedBox(width: 6),
                  Icon(Icons.expand_more, size: 16, color: T.faint),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 190,
              child: PrimaryButton(
                label: 'Nouvelle réception',
                onPressed: () => _newDoc(purchaseReceiptConfig),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: DocListPane(
              key: _listKey,
              api: widget.api,
              allTypes: _purchaseTypes,
              partnerNames: _partnerNames,
              editorFor: purchaseEditorFor,
              exportName: 'achats',
            ),
          ),
        ],
      ),
    );
  }
}
