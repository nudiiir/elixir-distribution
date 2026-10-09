import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/ui.dart';

/// Search-and-pick a product (substitution, prix spécial, offre, quota…).
Future<Product?> pickProduct(BuildContext context, ApiClient api, {String title = 'Choisir un produit'}) =>
    showDialog<Product>(context: context, builder: (_) => _ProductPickDialog(api: api, title: title));

class _ProductPickDialog extends StatefulWidget {
  const _ProductPickDialog({required this.api, required this.title});
  final ApiClient api;
  final String title;

  @override
  State<_ProductPickDialog> createState() => _ProductPickDialogState();
}

class _ProductPickDialogState extends State<_ProductPickDialog> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Product> _items = const [];
  bool _loading = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final r = await widget.api.products(q: _q.text.trim(), limit: 60);
      if (mounted && seq == _seq) {
        setState(() {
          _items = r;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text(widget.title, style: T.h2),
      content: SizedBox(
        width: 580,
        height: 460,
        child: Column(children: [
          SearchField(
            controller: _q,
            autofocus: true,
            hint: 'Nom, code-barres, marque…',
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), _load);
            },
            onSubmitted: (_) {
              if (_items.length == 1) Navigator.pop(context, _items.first);
            },
          ),
          const SizedBox(height: 8),
          if (_loading) const LinearProgressIndicator(minHeight: 2, color: T.mint),
          Expanded(
            child: _items.isEmpty && !_loading
                ? Center(child: Text('Aucun produit.', style: T.bodyMuted))
                : ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, i) {
                      final p = _items[i];
                      return ListTile(
                        dense: true,
                        onTap: () => Navigator.pop(context, p),
                        title: Text(p.name, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                        subtitle: Text([p.barcode ?? '', p.brand].where((s) => s.isNotEmpty).join(' · '),
                            style: T.monoSmall),
                        trailing: Text(fmtDA(p.priceWholesale ?? p.priceRetail), style: T.monoBody),
                      );
                    },
                  ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler'))],
    );
  }
}
