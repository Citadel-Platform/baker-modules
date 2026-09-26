import 'package:flutter/material.dart';

import 'tokens.dart';

/// Asks before an action, saying what it touches and whether it can be undone.
///
/// Returns true only on an explicit confirm; dismissing is a no. [count] is
/// stated in the question — "Delete 37 records" — because a bulk action whose
/// size is only visible in a selection somebody scrolled past is the one that
/// surprises them. An action that cannot be undone says so, and its button is
/// coloured as a danger.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? detail,
  int? count,
  bool reversible = true,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      final AppColors c = AppColors.of(context);
      return AlertDialog(
        title: Text(count == null ? title : '$title ($count)'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (detail != null) Text(detail),
              if (!reversible) ...<Widget>[
                if (detail != null) const SizedBox(height: AppTokens.space3),
                Text(
                  'This cannot be undone.',
                  style: TextStyle(
                    color: c.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: reversible
                ? null
                : FilledButton.styleFrom(backgroundColor: c.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// A detail view for one record, opened from a table row.
///
/// A side sheet on wide screens, so the table stays visible beside it; a
/// full-screen page on a phone, where a dialog would be cramped.
Future<void> showDetail(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
}) {
  final bool compact = MediaQuery.sizeOf(context).width < 600;
  if (compact) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext context) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTokens.space4),
            child: builder(context),
          ),
        ),
      ),
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    transitionDuration: AppTokens.motionMedium,
    pageBuilder: (BuildContext context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        elevation: 8,
        child: SizedBox(
          width: 480,
          height: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space5,
                  AppTokens.space4,
                  AppTokens.space2,
                  AppTokens.space4,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppTokens.space5),
                  child: builder(context),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    transitionBuilder: (_, Animation<double> animation, _, Widget child) =>
        SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        ),
  );
}
