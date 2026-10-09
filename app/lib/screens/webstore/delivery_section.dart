import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../settings/config_widgets.dart' show NumberField;
import 'web_common.dart';

/// « Livraison » : fees and delays per wilaya, free delivery threshold,
/// pick-up in store (DESKTOP_API.md §10).
class DeliverySection extends StatefulWidget {
  const DeliverySection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<DeliverySection> createState() => _DeliverySectionState();
}

class _Wilaya {
  _Wilaya(this.code, this.name);
  final String code;
  final String name;
  bool enabled = true;
  final fee = TextEditingController();
  final delay = TextEditingController();
}

class _DeliverySectionState extends State<DeliverySection> {
  Future<void>? _loading;
  Map<String, dynamic>? _raw;
  final _wilayas = <_Wilaya>[];
  final _selected = <String>{};

  bool _enabled = true;
  final _defaultFee = TextEditingController();
  final _defaultDelay = TextEditingController();
  final _free = TextEditingController();
  bool _pickup = false;
  final _pickupAddress = TextEditingController();
  final _pickupHours = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;
  bool _dirty = false;

  final _bulkFee = TextEditingController();
  final _bulkDelay = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loading = _load();
  }

  @override
  void dispose() {
    for (final w in _wilayas) {
      w.fee.dispose();
      w.delay.dispose();
    }
    for (final c in [
      _defaultFee, _defaultDelay, _free, _pickupAddress, _pickupHours, _note,
      _bulkFee, _bulkDelay,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final (d, list) = await widget.ctx.client.webDelivery();
    _raw = d;
    for (final w in _wilayas) {
      w.fee.dispose();
      w.delay.dispose();
    }
    _wilayas
      ..clear()
      ..addAll([for (final (c, n) in list) _Wilaya(c, n)]);
    int? i(String k, [Map? m]) => ((m ?? d)?[k] as num?)?.toInt();
    _enabled = d == null ? true : d['enabled'] != false;
    _defaultFee.text = i('default_fee_centimes') == null ? '' : editDA(i('default_fee_centimes')!);
    _defaultDelay.text = i('default_delay_days') == null ? '' : '${i('default_delay_days')}';
    _free.text = (i('free_threshold_centimes') ?? 0) > 0 ? editDA(i('free_threshold_centimes')!) : '';
    final pk = d?['pickup'] as Map?;
    _pickup = pk?['enabled'] == true;
    _pickupAddress.text = '${pk?['address'] ?? ''}';
    _pickupHours.text = '${pk?['hours'] ?? ''}';
    _note.text = '${d?['note'] ?? ''}';
    final per = (d?['wilayas'] as Map?) ?? const {};
    for (final w in _wilayas) {
      final e = per[w.code] as Map?;
      if (e == null) continue;
      w.enabled = e['enabled'] != false;
      final f = (e['fee_centimes'] as num?)?.toInt();
      if (f != null) w.fee.text = editDA(f);
      final dl = (e['delay_days'] as num?)?.toInt();
      if (dl != null) w.delay.text = '$dl';
    }
    _dirty = false;
    if (mounted) setState(() {});
  }

  void _touch() {
    if (!_dirty) setState(() => _dirty = true);
  }

  String? _validate() {
    int? da(TextEditingController c) => c.text.trim().isEmpty ? -1 : parseDA(c.text);
    int? days(TextEditingController c) =>
        c.text.trim().isEmpty ? -1 : int.tryParse(c.text.trim());
    if (da(_defaultFee) == null) return 'Frais par défaut invalides.';
    final dd = days(_defaultDelay);
    if (dd == null || dd > 60) return 'Délai par défaut : 0 à 60 jours.';
    if (da(_free) == null) return 'Seuil de livraison offerte invalide.';
    for (final w in _wilayas) {
      if (da(w.fee) == null) return 'Frais invalides pour ${w.code} ${w.name}.';
      final d = days(w.delay);
      if (d == null || d > 60) return 'Délai invalide pour ${w.code} ${w.name} (0 à 60 jours).';
    }
    if (_pickup && _pickupAddress.text.trim().isEmpty) {
      return 'Indiquez l’adresse de retrait en magasin.';
    }
    if (_note.text.length > 300) return 'Note : 300 caractères maximum.';
    return null;
  }

  Map<String, dynamic> _build() {
    final m = <String, dynamic>{'enabled': _enabled};
    final fee = parseDA(_defaultFee.text);
    if (fee != null) m['default_fee_centimes'] = fee;
    final dd = int.tryParse(_defaultDelay.text.trim());
    if (dd != null) m['default_delay_days'] = dd;
    final free = parseDA(_free.text);
    if (free != null && free > 0) m['free_threshold_centimes'] = free;
    final min = (_raw?['min_order_centimes'] as num?)?.toInt();
    if (min != null && min > 0) m['min_order_centimes'] = min;
    final per = <String, dynamic>{};
    for (final w in _wilayas) {
      final e = <String, dynamic>{};
      if (!w.enabled) e['enabled'] = false;
      final f = parseDA(w.fee.text);
      if (f != null) e['fee_centimes'] = f;
      final d = int.tryParse(w.delay.text.trim());
      if (d != null) e['delay_days'] = d;
      if (e.isNotEmpty) per[w.code] = e;
    }
    if (per.isNotEmpty) m['wilayas'] = per;
    m['pickup'] = {
      'enabled': _pickup,
      if (_pickupAddress.text.trim().isNotEmpty) 'address': _pickupAddress.text.trim(),
      if (_pickupHours.text.trim().isNotEmpty) 'hours': _pickupHours.text.trim(),
    };
    if (_note.text.trim().isNotEmpty) m['note'] = _note.text.trim();
    return m;
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      showToast(context, err, kind: ToastKind.warning);
      return;
    }
    setState(() => _busy = true);
    try {
      final d = _build();
      await widget.ctx.client.webPutDelivery(d);
      _raw = d;
      _dirty = false;
      if (mounted) showToast(context, 'Livraison enregistrée — le site est à jour.');
    } catch (e) {
      if (mounted) toastError(context, 'Enregistrement impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _bulk({bool? enable, bool fee = false, bool delay = false}) {
    if (_selected.isEmpty) {
      showToast(context, 'Cochez d’abord des wilayas dans le tableau.', kind: ToastKind.info);
      return;
    }
    if (fee && _bulkFee.text.trim().isNotEmpty && parseDA(_bulkFee.text) == null) {
      showToast(context, 'Frais invalides.', kind: ToastKind.warning);
      return;
    }
    setState(() {
      for (final w in _wilayas) {
        if (!_selected.contains(w.code)) continue;
        if (enable != null) w.enabled = enable;
        if (fee) w.fee.text = _bulkFee.text.trim();
        if (delay) w.delay.text = _bulkDelay.text.trim();
      }
      _dirty = true;
    });
  }

  Widget _cell(TextEditingController c, String hint, {bool money = true, bool enabled = true}) {
    return SizedBox(
      height: 38,
      child: TextField(
        controller: c,
        enabled: enabled,
        onChanged: (_) => _touch(),
        style: T.monoBody,
        inputFormatters: [
          FilteringTextInputFormatter.allow(money ? RegExp(r'[0-9 ,.]') : RegExp(r'[0-9]')),
        ],
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: T.monoSmall.copyWith(color: T.ghost),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loading,
      builder: (context, snap) {
        if (snap.hasError) {
          return WebNotice(
              icon: Icons.error_outline_rounded,
              title: 'Chargement impossible',
              body: errText(snap.error!),
              action: ('Réessayer', () => setState(() => _loading = _load())));
        }
        if (snap.connectionState != ConnectionState.done) return webSpinner;
        return _body();
      },
    );
  }

  Widget _body() {
    final defFee = _defaultFee.text.trim().isEmpty ? 'à confirmer' : _defaultFee.text.trim();
    final defDelay = _defaultDelay.text.trim().isEmpty ? '—' : _defaultDelay.text.trim();
    final allSel = _selected.length == _wilayas.length && _wilayas.isNotEmpty;
    return WebPane(
      title: 'Livraison',
      intro: 'Frais et délais par wilaya, livraison offerte, retrait en magasin. '
          'Le site calcule les frais au moment de la commande.',
      actions: [
        PageAction(
            label: _busy ? 'Enregistrement…' : (_dirty ? 'Enregistrer *' : 'Enregistrer'),
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      children: [
        if (_raw == null)
          const InfoBanner(
              text: 'Aucun réglage pour l’instant : le site affiche « frais confirmés '
                  'par téléphone ». Remplissez puis enregistrez pour calculer les frais.'),
        WebBlock(title: 'Règles générales', children: [
          SwitchRow(
            title: 'Calculer les frais de livraison sur le site',
            explanation: 'Désactivé : les frais sont confirmés par téléphone (les wilayas '
                'fermées restent fermées).',
            value: _enabled,
            onChanged: (v) => setState(() {
              _enabled = v;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 16, children: [
            NumberField(
                label: 'Frais par défaut',
                controller: _defaultFee,
                suffix: 'DA',
                decimals: true,
                width: 200,
                onChanged: (_) => setState(() => _dirty = true)),
            NumberField(
                label: 'Délai par défaut',
                controller: _defaultDelay,
                suffix: 'jours',
                width: 160,
                onChanged: (_) => setState(() => _dirty = true)),
            NumberField(
                label: 'Livraison offerte dès',
                controller: _free,
                suffix: 'DA',
                decimals: true,
                width: 220,
                help: 'Vide = jamais offerte.',
                onChanged: (_) => _touch()),
          ]),
          LabeledField(
              label: 'Note affichée à la commande',
              controller: _note,
              hint: 'ex. Livraison par Yalidine sous 48 h.',
              help: '300 caractères maximum.',
              onChanged: (_) => _touch()),
        ]),
        WebBlock(title: 'Retrait en magasin', children: [
          SwitchRow(
            title: 'Proposer le retrait en magasin',
            explanation: 'Le client peut choisir de venir chercher sa commande (sans frais).',
            value: _pickup,
            onChanged: (v) => setState(() {
              _pickup = v;
              _dirty = true;
            }),
          ),
          if (_pickup) ...[
            const SizedBox(height: 8),
            LabeledField(
                label: 'Adresse de retrait',
                controller: _pickupAddress,
                required: true,
                onChanged: (_) => _touch()),
            LabeledField(
                label: 'Horaires de retrait',
                controller: _pickupHours,
                hint: 'ex. 8h–20h',
                onChanged: (_) => _touch()),
          ],
        ]),
        WebBlock(
          title: 'Par wilaya',
          help: 'Laissez une case vide pour utiliser la valeur par défaut. Décochez '
              '« Livrée » pour ne pas livrer une wilaya.',
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: T.bg, borderRadius: BorderRadius.circular(T.rInner)),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${_selected.length} sélectionnée(s) :', style: T.label),
                  SizedBox(width: 120, child: _cell(_bulkFee, 'Frais DA')),
                  OutlinedButton(
                      onPressed: () => _bulk(fee: true),
                      child: const Text('Appliquer les frais')),
                  SizedBox(width: 90, child: _cell(_bulkDelay, 'Jours', money: false)),
                  OutlinedButton(
                      onPressed: () => _bulk(delay: true),
                      child: const Text('Appliquer le délai')),
                  OutlinedButton(
                      onPressed: () => _bulk(enable: true),
                      child: const Text('Livrer')),
                  OutlinedButton(
                      onPressed: () => _bulk(enable: false),
                      child: const Text('Ne pas livrer')),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              SizedBox(
                width: 44,
                child: Checkbox(
                  value: allSel,
                  activeColor: T.mintDeep,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.addAll(_wilayas.map((w) => w.code));
                    } else {
                      _selected.clear();
                    }
                  }),
                ),
              ),
              const Expanded(child: Text('Wilaya', style: T.label)),
              const SizedBox(width: 90, child: Text('Livrée', style: T.label)),
              SizedBox(width: 150, child: Text('Frais (défaut $defFee)', style: T.label)),
              const SizedBox(width: 12),
              SizedBox(width: 130, child: Text('Délai jours ($defDelay)', style: T.label)),
            ]),
            const Divider(),
            for (final w in _wilayas)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 3),
                decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: T.border))),
                child: Row(children: [
                  SizedBox(
                    width: 44,
                    child: Checkbox(
                      value: _selected.contains(w.code),
                      activeColor: T.mintDeep,
                      onChanged: (v) => setState(() =>
                          v == true ? _selected.add(w.code) : _selected.remove(w.code)),
                    ),
                  ),
                  Expanded(
                    child: Text('${w.code}  ${w.name}',
                        style: T.body.copyWith(color: w.enabled ? T.ink : T.faint)),
                  ),
                  SizedBox(
                    width: 90,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Switch(
                          value: w.enabled,
                          onChanged: (v) => setState(() {
                                w.enabled = v;
                                _dirty = true;
                              })),
                    ),
                  ),
                  SizedBox(width: 150, child: _cell(w.fee, defFee, enabled: w.enabled)),
                  const SizedBox(width: 12),
                  SizedBox(
                      width: 130,
                      child: _cell(w.delay, defDelay, money: false, enabled: w.enabled)),
                ]),
              ),
            const SizedBox(height: 14),
            Row(children: [
              TextButton(
                onPressed: () async {
                  final ok = await confirmAction(context,
                      title: 'Revenir au comportement d’origine ?',
                      message: 'Plus aucun frais calculé : le site affichera « frais '
                          'confirmés par téléphone » et « Livraison 58 wilayas ». La '
                          'commande minimum est aussi retirée.',
                      confirmLabel: 'Effacer les réglages',
                      danger: true);
                  if (!ok) return;
                  try {
                    await widget.ctx.client.webPutDelivery(null);
                    setState(() => _loading = _load());
                  } catch (e) {
                    if (mounted) toastError(context, 'Effacement impossible', e);
                  }
                },
                style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                child: const Text('Effacer tous les réglages de livraison'),
              ),
              const Spacer(),
              PageAction(
                  label: _busy ? 'Enregistrement…' : 'Enregistrer',
                  primary: true,
                  onPressed: _busy ? null : _save),
            ]),
          ],
        ),
      ],
    );
  }
}
