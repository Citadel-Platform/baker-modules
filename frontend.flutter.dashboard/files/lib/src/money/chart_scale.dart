import 'dart:math' as math;

/// An axis range with round tick values: 0, 250, 500, 750, 1000.
///
/// Ticks at 0, 263.4, 526.8 are correct and unreadable. This is the "nice
/// numbers" method (Heckbert, Graphics Gems, 1990): the step is 1, 2, 2.5 or 5
/// times a power of ten, chosen so the axis holds the data with at most
/// [maxTicks] intervals.
class NiceScale {
  const NiceScale._(this.min, this.max, this.step);

  factory NiceScale.of(double dataMin, double dataMax, {int maxTicks = 5}) {
    if (maxTicks < 1) throw ArgumentError.value(maxTicks, 'maxTicks');
    if (!dataMin.isFinite || !dataMax.isFinite) {
      throw ArgumentError('Axis bounds must be finite.');
    }
    double low = math.min(dataMin, dataMax);
    double high = math.max(dataMin, dataMax);
    // Money axes start at zero unless the data goes below it: a bar chart
    // whose axis starts at 900 makes 910 look ten times 901.
    if (low > 0) low = 0;
    if (high < 0) high = 0;
    if (low == high) {
      high = low == 0 ? 1 : low.abs() * 2;
    }
    final double step = _niceStep((high - low) / maxTicks);
    return NiceScale._(
      (low / step).floorToDouble() * step,
      (high / step).ceilToDouble() * step,
      step,
    );
  }

  final double min;
  final double max;
  final double step;

  /// Every tick from [min] to [max], computed by index so rounding error does
  /// not accumulate into a tick at 999.9999.
  List<double> get ticks {
    final int count = ((max - min) / step).round();
    return <double>[for (int i = 0; i <= count; i++) min + i * step];
  }

  static double _niceStep(double rough) {
    final double exponent = (math.log(rough) / math.ln10).floorToDouble();
    final double magnitude = math.pow(10, exponent).toDouble();
    final double fraction = rough / magnitude;
    final double nice = fraction <= 1
        ? 1
        : fraction <= 2
        ? 2
        : fraction <= 2.5
        ? 2.5
        : fraction <= 5
        ? 5
        : 10;
    return nice * magnitude;
  }
}

/// A short axis label: 1,500 → "1.5K", 2,000,000 → "2M".
String compactAxisLabel(double value) {
  final double a = value.abs();
  final String sign = value < 0 ? '-' : '';
  String trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  if (a >= 1e9) return '$sign${trim(a / 1e9)}B';
  if (a >= 1e6) return '$sign${trim(a / 1e6)}M';
  if (a >= 1e3) return '$sign${trim(a / 1e3)}K';
  return '$sign${trim(a)}';
}
