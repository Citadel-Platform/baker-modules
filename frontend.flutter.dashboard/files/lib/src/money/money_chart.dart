import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../design/states.dart';
import '../design/tokens.dart';
import 'chart_scale.dart';
import 'money.dart';

/// One bar: a label ("Mar") and an amount.
typedef MoneyBar = ({String label, Money amount});

/// Bars of amounts in one currency, on a round-numbered axis from zero.
///
/// A chart is invisible to a screen reader, so the same figures are given as
/// a sentence in its semantics. No bars is an empty state, not an empty axis.
class MoneyBarChart extends StatelessWidget {
  const MoneyBarChart({
    required this.bars,
    required this.currency,
    this.height = 240,
    this.locale,
    super.key,
  });

  final List<MoneyBar> bars;
  final String currency;
  final double height;
  final String? locale;

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) {
      return SizedBox(
        height: height,
        child: const EmptyState(title: 'No figures for this period'),
      );
    }
    for (final MoneyBar bar in bars) {
      if (bar.amount.currency != currency) {
        throw ArgumentError(
          'MoneyBarChart is in $currency; "${bar.label}" is in '
          '${bar.amount.currency}.',
        );
      }
    }
    final AppColors c = AppColors.of(context);
    final int exponent = currencyExponent(currency);
    double major(Money m) => m.minor / _pow10(exponent);
    final List<double> values = <double>[
      for (final MoneyBar b in bars) major(b.amount),
    ];
    final NiceScale scale = NiceScale.of(
      values.reduce((double a, double b) => a < b ? a : b),
      values.reduce((double a, double b) => a > b ? a : b),
    );
    final TextStyle? axis = Theme.of(context).textTheme.labelSmall;

    return Semantics(
      label: bars
          .map((MoneyBar b) => '${b.label}: ${b.amount.format(locale: locale)}')
          .join(', '),
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: BarChart(
            BarChartData(
              minY: scale.min,
              maxY: scale.max,
              gridData: FlGridData(
                drawVerticalLine: false,
                horizontalInterval: scale.step,
                getDrawingHorizontalLine: (_) =>
                    FlLine(color: c.border, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    interval: scale.step,
                    getTitlesWidget: (double value, TitleMeta meta) =>
                        Text(compactAxisLabel(value), style: axis),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (double value, TitleMeta meta) {
                      final int i = value.toInt();
                      return i >= 0 && i < bars.length
                          ? Text(bars[i].label, style: axis)
                          : const SizedBox.shrink();
                    },
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipItem: (BarChartGroupData group, _, _, _) =>
                      BarTooltipItem(
                        bars[group.x].amount.format(locale: locale),
                        TextStyle(color: c.textPrimary),
                      ),
                ),
              ),
              barGroups: <BarChartGroupData>[
                for (int i = 0; i < bars.length; i++)
                  BarChartGroupData(
                    x: i,
                    barRods: <BarChartRodData>[
                      BarChartRodData(
                        toY: values[i],
                        color: values[i] < 0 ? c.danger : c.accent,
                        width: 18,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(AppTokens.radiusSm),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static int _pow10(int n) {
    int v = 1;
    for (int i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }
}
