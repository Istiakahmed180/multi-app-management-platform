import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

final _dateTime = DateFormat('MMM d, y · HH:mm');
final _date = DateFormat('MMM d, y');
final _number = NumberFormat.decimalPattern();

String formatDateTime(DateTime? d) => d == null ? '—' : _dateTime.format(d);
String formatDate(DateTime? d) => d == null ? '—' : _date.format(d);
String formatNumber(num? n) => n == null ? '—' : _number.format(n);
String formatPercent(num? ratio, {int digits = 1}) => ratio == null ? '—' : '${(ratio * 100).toStringAsFixed(digits)}%';

String timeAgo(DateTime? d) {
  if (d == null) return 'never';
  final diff = DateTime.now().difference(d);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return formatDate(d);
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.subtitle, this.trailing, required this.child, this.padding = const EdgeInsets.all(20)});

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title!, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 16),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value, this.hint, this.icon});

  final String label;
  final String value;
  final String? hint;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[Icon(icon, size: 18, color: theme.colorScheme.primary), const SizedBox(width: 8)],
                Expanded(
                  child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lays out children in a responsive grid of fixed minimum width.
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.minItemWidth = 220, this.spacing = 16});

  final List<Widget> children;
  final double minItemWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / (minItemWidth + spacing)).floor().clamp(1, 6);
        final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [for (final c in children) SizedBox(width: width, child: c)],
        );
      },
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

  static const _tones = {
    'active': _Tone.good,
    'sent': _Tone.good,
    'released': _Tone.good,
    'ok': _Tone.good,
    'enabled': _Tone.good,
    'scheduled': _Tone.info,
    'sending': _Tone.info,
    'rolling_out': _Tone.info,
    'in_review': _Tone.info,
    'draft': _Tone.neutral,
    'planned': _Tone.neutral,
    'inactive': _Tone.warn,
    'partially_failed': _Tone.warn,
    'halted': _Tone.warn,
    'disabled': _Tone.neutral,
    'cancelled': _Tone.neutral,
    'archived': _Tone.neutral,
    'suspended': _Tone.bad,
    'failed': _Tone.bad,
    'revoked': _Tone.bad,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final (bg, fg) = switch (_tones[status] ?? _Tone.neutral) {
      _Tone.good => (dark ? const Color(0xFF14532D) : const Color(0xFFDCFCE7), dark ? const Color(0xFFBBF7D0) : const Color(0xFF166534)),
      _Tone.info => (dark ? const Color(0xFF1E3A8A) : const Color(0xFFDBEAFE), dark ? const Color(0xFFBFDBFE) : const Color(0xFF1E40AF)),
      _Tone.warn => (dark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7), dark ? const Color(0xFFFDE68A) : const Color(0xFF92400E)),
      _Tone.bad => (dark ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2), dark ? const Color(0xFFFECACA) : const Color(0xFF991B1B)),
      _Tone.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(
        status.replaceAll('_', ' '),
        style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

enum _Tone { good, info, warn, bad, neutral }

class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.child});
  final String label;
  final String? value;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(child: child ?? SelectableText(value ?? '—')),
        ],
      ),
    );
  }
}

/// Simple accessible bar chart without third-party dependencies.
class BarSeriesChart extends StatelessWidget {
  const BarSeriesChart({super.key, required this.labels, required this.values, this.height = 160, this.semanticLabel});

  final List<String> labels;
  final List<num> values;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = values.fold<num>(0, (m, v) => v > m ? v : m);
    return Semantics(
      label: semanticLabel,
      child: SizedBox(
        height: height + 22,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final barWidth = (constraints.maxWidth / values.length.clamp(1, 1000)).clamp(2.0, 40.0);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < values.length; i++)
                  Tooltip(
                    message: '${labels[i]}: ${formatNumber(values[i])}',
                    child: SizedBox(
                      width: barWidth,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            margin: EdgeInsets.symmetric(horizontal: barWidth > 6 ? 1.5 : 0.5),
                            height: max == 0 ? 0 : (values[i] / max * height).toDouble().clamp(values[i] > 0 ? 2.0 : 0.0, height),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.85),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                            ),
                          ),
                          SizedBox(
                            height: 22,
                            child: i == 0 || i == values.length - 1
                                ? FittedBox(
                                    child: Text(
                                      labels[i].length > 5 ? labels[i].substring(5) : labels[i],
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Horizontal proportion bars for categorical breakdowns.
class BreakdownList extends StatelessWidget {
  const BreakdownList({super.key, required this.items});
  final List<(String, num)> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = items.fold<num>(0, (s, i) => s + i.$2);
    return Column(
      children: [
        for (final (label, value) in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
                    Text(
                      '${formatNumber(value)} · ${formatPercent(total == 0 ? 0 : value / total, digits: 0)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: total == 0 ? 0 : (value / total).toDouble(), minHeight: 6),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
