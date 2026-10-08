import 'package:flutter/material.dart';

import '../api/client.dart';
import '../util/commands.dart';
import '../util/analysis_links.dart';
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

/// Achats. Menu commands: `list` · `new:PURCHASE_RECEIPT` ·
/// `type:PURCHASE_ORDER` · `type:PURCHASE_INVOICE` · `type:PURCHASE_CREDIT_NOTE`.
class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key, required this.api, this.command});
  final ApiClient api;
  final ScreenCommand? command;

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
    widget.command?.addListener(_onCommand);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCommand());
  }

  @override
  void didUpdateWidget(PurchasesScreen old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) {
      old.command?.removeListener(_onCommand);
      widget.command?.addListener(_onCommand);
    }
  }

  @override
  void dispose() {
    widget.command?.removeListener(_onCommand);
    super.dispose();
  }

  void _onCommand() {
    final cmd = widget.command?.value;
    if (cmd == null || !mounted) return;
    widget.command!.done();
    if (!popToModuleRoot(context)) return;
    if (cmd == 'list') {
      _listKey.currentState?.setType(null);
    } else if (cmd.startsWith('type:')) {
      _listKey.currentState?.setType(cmd.substring(5));
    } else if (cmd.startsWith('new:')) {
      final cfg = purchaseEditorFor(cmd.substring(4));
      if (cfg != null) _newDoc(cfg);
    }
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
            primaryLabel: 'Nouveau bon de réception',
            primaryIcon: Icons.move_to_inbox_outlined,
            onPrimary: () => _newDoc(purchaseReceiptConfig),
            more: [
              MenuEntry('Nouveau bon de commande', Icons.shopping_cart_outlined,
                  () => _newDoc(purchaseOrderConfig)),
              MenuEntry('Nouvelle facture fournisseur', Icons.receipt_outlined,
                  () => _newDoc(purchaseInvoiceConfig)),
              MenuEntry('Nouvel avoir fournisseur',
                  Icons.assignment_return_outlined,
                  () => _newDoc(purchaseCreditNoteConfig)),
              if (AnalysisLinks.available)
                MenuEntry('Analyser les achats', Icons.insights_rounded,
                    () => AnalysisLinks.launch(AnalysisLinks.purchases())),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: DocListPane(
              key: _listKey,
              api: widget.api,
              allTypes: _purchaseTypes,
              quickTypes: const [
                'PURCHASE_RECEIPT',
                'PURCHASE_ORDER',
                'PURCHASE_INVOICE'
              ],
              partnerNames: _partnerNames,
              partnerKind: 'supplier',
              editorFor: purchaseEditorFor,
              exportName: 'achats',
              exportTitle: 'Achats',
              prefsKey: 'purchases',
              emptyActions: [
                ('Nouveau bon de commande', () => _newDoc(purchaseOrderConfig)),
                ('Nouveau bon de réception',
                    () => _newDoc(purchaseReceiptConfig)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
