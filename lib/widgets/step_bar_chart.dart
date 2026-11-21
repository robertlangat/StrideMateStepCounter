import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'common.dart';

class ChartPoint {
  const ChartPoint(this.label, this.value, {this.semanticLabel, this.highlight = false});
  final String label;
  final int value;
  final String? semanticLabel;
  final bool highlight;
}

/// Bar chart with a goal line. Accessible: the whole chart has a spoken summary,
/// goal status is shown by colour AND a ✓ marker, and users can switch to a
/// plain table (also used automatically by screen readers via the summary).
class StepBarChart extends StatefulWidget {
  const StepBarChart({super.key, required this.points, this.goal, required this.title});
  final List<ChartPoint> points;
  final int? goal;
  final String title;

  @override
  State<StepBarChart> createState() => _StepBarChartState();
}

class _StepBarChartState extends State<StepBarChart> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final goal = widget.goal;
    final maxV = widget.points.fold<int>(goal ?? 0, (m, p) => p.value > m ? p.value : m);
    final total = widget.points.fold<int>(0, (s, p) => s + p.value);
    final met = goal == null ? 0 : widget.points.where((p) => p.value >= goal).length;
    final summary = '${widget.title}. ${widget.points.length} bars, total ${fmtInt(total)} steps'
        '${goal == null ? '' : ', goal ${fmtInt(goal)} met on $met'}. Double tap "Table" to hear each value.';

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium)),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Chart'), icon: Icon(Icons.bar_chart)),
            ButtonSegment(value: true, label: Text('Table'), icon: Icon(Icons.table_rows_outlined)),
          ],
          selected: {_table},
          onSelectionChanged: (s) => setState(() => _table = s.first),
        ),
      ]),
      const SizedBox(height: 12),
      if (_table)
        Column(
          children: [
            for (final p in widget.points)
              ListTile(
                dense: true,
                title: Text(p.semanticLabel ?? p.label),
                trailing: Text(
                  '${fmtInt(p.value)}${goal != null && p.value >= goal ? '  ✓' : ''}',
                  style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
          ],
        )
      else
        Semantics(
          label: summary,
          excludeSemantics: true,
          child: SizedBox(
            height: 220,
            child: BarChart(
              BarChartData(
                maxY: (maxV <= 0 ? 1000 : maxV * 1.15).toDouble(),
                alignment: BarChartAlignment.spaceAround,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                barTouchData: BarTouchData(enabled: true),
                extraLinesData: ExtraLinesData(horizontalLines: [
                  if (goal != null)
                    HorizontalLine(
                      y: goal.toDouble(),
                      color: dark ? SmColors.mint : SmColors.mintDark,
                      strokeWidth: 1.5,
                      dashArray: const [6, 4],
                    ),
                ]),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (value, meta) => Text(
                        value >= 1000 ? '${(value / 1000).toStringAsFixed(0)}k' : value.toStringAsFixed(0),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= widget.points.length) return const SizedBox.shrink();
                        final every = widget.points.length > 16 ? (widget.points.length / 8).ceil() : 1;
                        if (i % every != 0 && i != widget.points.length - 1) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(widget.points[i].label, style: Theme.of(context).textTheme.labelSmall),
                        );
                      },
                    ),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < widget.points.length; i++)
                    BarChartGroupData(x: i, barRods: [
                      BarChartRodData(
                        toY: widget.points[i].value.toDouble(),
                        width: widget.points.length > 20 ? 6 : 14,
                        borderRadius: BorderRadius.circular(4),
                        color: widget.points[i].highlight
                            ? SmColors.amber
                            : goal != null && widget.points[i].value >= goal
                                ? (dark ? SmColors.mint : SmColors.mintDark)
                                : (dark ? SmColors.ivory.withValues(alpha: 0.35) : SmColors.navy.withValues(alpha: 0.35)),
                      ),
                    ]),
                ],
              ),
            ),
          ),
        ),
    ]);
  }
}
