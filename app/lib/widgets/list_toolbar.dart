import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ui.dart';

/// An entry of a page's « Plus » menu (import, secondary documents…).
class MenuEntry {
  const MenuEntry(this.label, this.icon, this.onSelected, {this.enabled = true});
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool enabled;
}

/// Screen title row: title (+ optional subtitle/count) left; on the right
/// an optional « Plus » menu and ONE primary action — the only coloured
/// button of the screen.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.primaryLabel,
    this.primaryIcon = Icons.add_rounded,
    this.onPrimary,
    this.more = const [],
    this.trailing = const [],
  });

  final String title;
  final String? subtitle;
  final String? primaryLabel;
  final IconData primaryIcon;
  final VoidCallback? onPrimary;
  final List<MenuEntry> more;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(title, style: T.h1),
      if (subtitle != null) ...[
        const SizedBox(width: 12),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(subtitle!, style: T.bodyMuted),
        ),
      ],
      const Spacer(),
      ...trailing,
      if (more.isNotEmpty) ...[
        PopupMenuButton<MenuEntry>(
          tooltip: 'Plus d’actions',
          color: T.surface,
          position: PopupMenuPosition.under,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(T.rInner),
              side: const BorderSide(color: T.border)),
          itemBuilder: (_) => [
            for (final m in more)
              PopupMenuItem(
                value: m,
                enabled: m.enabled,
                height: 36,
                child: Row(children: [
                  Icon(m.icon, size: 16, color: T.muted),
                  const SizedBox(width: 10),
                  Text(m.label, style: T.body.copyWith(fontSize: 13)),
                ]),
              ),
          ],
          onSelected: (m) => m.onSelected(),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Plus', style: T.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more_rounded, size: 18, color: T.muted),
            ]),
          ),
        ),
        const SizedBox(width: 10),
      ],
      if (primaryLabel != null)
        SizedBox(
          height: 40,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: T.mint,
              foregroundColor: T.ink,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(T.rInner)),
              textStyle: const TextStyle(
                  fontFamily: T.sans, fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
            onPressed: onPrimary,
            icon: Icon(primaryIcon, size: 18),
            label: Text(primaryLabel!),
          ),
        ),
    ]);
  }
}

/// A quick filter pill (on/off). Neutral when off, ink when on, so colour
/// keeps meaning « primary action » elsewhere.
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
    this.count,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active ? T.ink : T.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: active ? T.ink : T.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: active ? Colors.white : T.muted),
              const SizedBox(width: 5),
            ],
            Text(label,
                style: T.small.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : T.ink)),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: active ? Colors.white24 : T.bg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('$count',
                    style: T.label.copyWith(
                        fontSize: 9.5, color: active ? Colors.white : T.muted)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// A filter that is ON, shown as a removable chip so nobody wonders why rows
/// are missing.
class ActiveFilter {
  const ActiveFilter(this.label, this.onRemove);
  final String label;
  final VoidCallback onRemove;
}

/// Search + quick pills + « Filtres » button (with the active count) on one
/// row; the filter panel unfolds below it; active filters become chips with
/// « Tout effacer ».
class ListToolbar extends StatefulWidget {
  const ListToolbar({
    super.key,
    this.search,
    this.searchHint = 'Rechercher…',
    this.onSearchChanged,
    this.onSearchSubmitted,
    this.searchFocus,
    this.quickFilters = const [],
    this.panel,
    this.active = const [],
    this.onClearAll,
    this.trailing = const [],
    this.initiallyOpen = false,
  });

  final TextEditingController? search;
  final String searchHint;
  final ValueChanged<String>? onSearchChanged;
  final ValueChanged<String>? onSearchSubmitted;
  final FocusNode? searchFocus;
  final List<Widget> quickFilters;

  /// Content of the « Filtres » panel (use [FilterPanel]).
  final Widget? panel;
  final List<ActiveFilter> active;
  final VoidCallback? onClearAll;
  final List<Widget> trailing;
  final bool initiallyOpen;

  @override
  State<ListToolbar> createState() => _ListToolbarState();
}

class _ListToolbarState extends State<ListToolbar> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (widget.search != null)
          SizedBox(
            width: 340,
            child: SearchField(
              controller: widget.search!,
              hint: widget.searchHint,
              focusNode: widget.searchFocus,
              onChanged: widget.onSearchChanged,
              onSubmitted: widget.onSearchSubmitted,
            ),
          ),
        if (widget.search != null) const SizedBox(width: 10),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: widget.quickFilters),
          ),
        ),
        if (widget.panel != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6),
            child: FilterPill(
              label: 'Filtres',
              icon: Icons.tune_rounded,
              active: _open,
              count: widget.active.length,
              onTap: () => setState(() => _open = !_open),
            ),
          ),
        ...widget.trailing,
      ]),
      AnimatedSize(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.topCenter,
        child: _open && widget.panel != null
            ? Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Card14(child: widget.panel!),
              )
            : const SizedBox(width: double.infinity),
      ),
      if (widget.active.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final f in widget.active)
              InputChip(
                label: Text(f.label, style: T.small.copyWith(color: T.ink, fontSize: 12)),
                onDeleted: f.onRemove,
                deleteIconColor: T.muted,
                backgroundColor: T.mintTint,
                side: const BorderSide(color: T.mintTint2),
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
            if (widget.onClearAll != null && widget.active.length > 1)
              TextButton(
                onPressed: widget.onClearAll,
                child: const Text('Tout effacer', style: TextStyle(fontSize: 12)),
              ),
          ]),
        ),
    ]);
  }
}

/// Grid of labelled filter fields for [ListToolbar.panel].
class FilterPanel extends StatelessWidget {
  const FilterPanel({super.key, required this.fields});
  final List<FilterField> fields;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 14, runSpacing: 12, children: fields);
  }
}

/// One filter of the panel: a dropdown with « Tous » as the empty choice.
class FilterField<V> extends StatelessWidget {
  const FilterField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.allLabel = 'Tous',
    this.width = 210,
  });

  final String label;
  final V? value;
  final List<(V, String)> options;
  final ValueChanged<V?> onChanged;
  final String allLabel;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MicroLabel(label),
        const SizedBox(height: 5),
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: value == null ? T.border : T.mintDeep),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<V?>(
              isExpanded: true,
              value: value,
              style: T.body.copyWith(fontSize: 13),
              items: [
                DropdownMenuItem<V?>(value: null, child: Text(allLabel)),
                for (final (v, l) in options)
                  DropdownMenuItem<V?>(
                      value: v, child: Text(l, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
      ]),
    );
  }
}
