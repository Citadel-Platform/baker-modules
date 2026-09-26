import 'package:flutter/material.dart';

import 'tokens.dart';

/// A page: a title bar with the page's actions, and the page itself.
///
/// The title is chrome and paints at once; only [child] waits for data.
class AppPage extends StatelessWidget {
  const AppPage({
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.scrolls = true,
    super.key,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  /// False when [child] scrolls itself (a table), so there is one scroller.
  final bool scrolls;

  @override
  Widget build(BuildContext context) {
    final Widget body = Padding(
      padding: const EdgeInsets.all(AppTokens.space6),
      child: child,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space6,
            AppTokens.space4,
            AppTokens.space6,
            AppTokens.space4,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              for (final Widget action in actions) ...<Widget>[
                const SizedBox(width: AppTokens.space2),
                action,
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTokens.contentMaxWidth,
              ),
              child: scrolls ? SingleChildScrollView(child: body) : body,
            ),
          ),
        ),
      ],
    );
  }
}

/// A bounded region with an optional heading. What most screens are made of.
class AppPanel extends StatelessWidget {
  const AppPanel({required this.child, this.title, this.trailing, super.key});

  final String? title;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (title != null) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title!,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: AppTokens.space4),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// The meaning a status carries, independent of its wording.
enum Tone { neutral, accent, success, warning, danger }

/// A short status label. Colour is never the only signal: the label says it.
class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.label, this.tone = Tone.neutral, super.key});

  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final AppColors c = AppColors.of(context);
    final Color color = switch (tone) {
      Tone.neutral => c.textSecondary,
      Tone.accent => c.accentText,
      Tone.success => c.success,
      Tone.warning => c.warning,
      Tone.danger => c.danger,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space2,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
      ),
    );
  }
}

/// Transient confirmation that something happened.
void showFeedback(
  BuildContext context,
  String message, {
  Tone tone = Tone.neutral,
}) {
  final AppColors c = AppColors.of(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: tone == Tone.danger ? c.danger : null,
      ),
    );
}
