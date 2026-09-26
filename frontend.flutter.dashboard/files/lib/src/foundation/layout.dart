import 'dart:async';

import 'package:flutter/widgets.dart';

/// Window size classes, after Material 3's.
///
/// Layout decisions are made on these, never on raw pixel widths scattered
/// through widgets: a breakpoint moved once moves everywhere.
enum WindowSize {
  /// Phones in portrait. Bottom navigation, one column.
  compact,

  /// Tablets, phones in landscape, narrow browser windows. A navigation rail.
  medium,

  /// Laptops and desktops. An extended rail with labels.
  expanded;

  static const double mediumFrom = 600;
  static const double expandedFrom = 1200;

  static WindowSize forWidth(double width) {
    if (width >= expandedFrom) return WindowSize.expanded;
    if (width >= mediumFrom) return WindowSize.medium;
    return WindowSize.compact;
  }

  static WindowSize of(BuildContext context) =>
      forWidth(MediaQuery.sizeOf(context).width);
}

/// Calls [action] once input has paused for [delay].
///
/// For search boxes: a query per keystroke is a query per keystroke billed,
/// and results arriving out of order can show the answer to an older query.
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 300)});

  final Duration delay;
  Timer? _timer;

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() => _timer?.cancel();
}
