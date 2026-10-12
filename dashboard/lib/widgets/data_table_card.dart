import 'dart:async';

import 'package:flutter/material.dart';

import 'states.dart';

class TableColumn<T> {
  const TableColumn(this.label, this.cell, {this.numeric = false, this.tooltip});

  final String label;
  final Widget Function(T row) cell;
  final bool numeric;
  final String? tooltip;
}

/// Card with a search/filter toolbar, a data table and pagination.
class DataTableCard<T> extends StatelessWidget {
  const DataTableCard({
    super.key,
    required this.columns,
    required this.rows,
    required this.loading,
    this.error,
    this.onRetry,
    this.onRowTap,
    this.searchHint,
    this.onSearch,
    this.initialSearch = '',
    this.filters = const [],
    this.actions = const [],
    this.page = 1,
    this.totalPages = 1,
    this.total,
    this.onPage,
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage,
    this.emptyAction,
  });

  final List<TableColumn<T>> columns;
  final List<T> rows;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final void Function(T row)? onRowTap;
  final String? searchHint;
  final ValueChanged<String>? onSearch;
  final String initialSearch;
  final List<Widget> filters;
  final List<Widget> actions;
  final int page;
  final int totalPages;
  final int? total;
  final ValueChanged<int>? onPage;
  final String emptyTitle;
  final String? emptyMessage;
  final Widget? emptyAction;

  @override
  Widget build(BuildContext context) {
    final hasToolbar = onSearch != null || filters.isNotEmpty || actions.isNotEmpty;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasToolbar)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (onSearch != null)
                    SizedBox(
                      width: 280,
                      child: _SearchField(hint: searchHint ?? 'Search', initial: initialSearch, onChanged: onSearch!),
                    ),
                  ...filters,
                  if (actions.isNotEmpty) ...actions,
                ],
              ),
            ),
          if (loading) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
          if (error != null)
            ErrorState(message: error!, onRetry: onRetry)
          else if (!loading && rows.isEmpty)
            EmptyState(title: emptyTitle, message: emptyMessage, action: emptyAction)
          else
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: DataTable(
                    showCheckboxColumn: false,
                    columns: [for (final c in columns) DataColumn(label: Text(c.label), numeric: c.numeric, tooltip: c.tooltip)],
                    rows: [
                      for (final r in rows)
                        DataRow(
                          onSelectChanged: onRowTap == null ? null : (_) => onRowTap!(r),
                          cells: [for (final c in columns) DataCell(c.cell(r))],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (onPage != null && (totalPages > 1 || (total ?? 0) > 0))
            PaginationBar(page: page, totalPages: totalPages, total: total, onPage: onPage!),
        ],
      ),
    );
  }
}

class PaginationBar extends StatelessWidget {
  const PaginationBar({super.key, required this.page, required this.totalPages, required this.onPage, this.total});

  final int page;
  final int totalPages;
  final int? total;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (total != null) Text('$total total', style: theme.textTheme.bodySmall),
          const Spacer(),
          IconButton(tooltip: 'Previous page', onPressed: page > 1 ? () => onPage(page - 1) : null, icon: const Icon(Icons.chevron_left)),
          Text('Page $page of $totalPages', style: theme.textTheme.bodyMedium),
          IconButton(
            tooltip: 'Next page',
            onPressed: page < totalPages ? () => onPage(page + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.hint, required this.initial, required this.onChanged});
  final String hint;
  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final _controller = TextEditingController(text: widget.initial);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: widget.hint),
      onChanged: (v) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 350), () => widget.onChanged(v.trim()));
      },
    );
  }
}

/// Compact dropdown filter for table toolbars.
class FilterDropdown extends StatelessWidget {
  const FilterDropdown({super.key, required this.label, required this.value, required this.options, required this.onChanged});

  final String label;
  final String? value;
  final Map<String, String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: DropdownButtonFormField<String?>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('All')),
          for (final e in options.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
        ],
        onChanged: onChanged,
      ),
    );
  }
}
