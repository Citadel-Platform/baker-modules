import 'package:flutter/material.dart';

import 'tokens.dart';

/// A page: a title, and the thing the page is.
class AppPage extends StatelessWidget {
  const AppPage({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(AppTokens.space4),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTokens.space4),
            child: child,
          ),
        ),
      ],
    );
  }
}

/// A bounded region with a heading. The unit almost every screen is made of.
class AppPanel extends StatelessWidget {
  const AppPanel({required this.child, this.title, super.key});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.space4),
      decoration: BoxDecoration(
        color: AppTokens.surfaceRaised,
        border: Border.all(color: AppTokens.border),
        borderRadius: BorderRadius.circular(AppTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (title case final String heading) ...<Widget>[
            Text(heading, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppTokens.space3),
          ],
          child,
        ],
      ),
    );
  }
}

/// A labelled value. Label above, in the muted style, so a column of these
/// reads as a table without being one.
class AppDetail extends StatelessWidget {
  const AppDetail({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label.toUpperCase(), style: text.labelSmall),
        const SizedBox(height: AppTokens.space1),
        Text(
          value,
          style: text.bodyMedium?.copyWith(color: AppTokens.textPrimary),
        ),
      ],
    );
  }
}

/// Something the reader needs to know before acting on the panel it sits in.
class AppNotice extends StatelessWidget {
  const AppNotice({required this.message, this.tone = AppTone.neutral, super.key});

  final String message;
  final AppTone tone;

  @override
  Widget build(BuildContext context) {
    final Color colour = switch (tone) {
      AppTone.neutral => AppTokens.border,
      AppTone.warning => AppTokens.danger,
    };
    return Container(
      padding: const EdgeInsets.all(AppTokens.space3),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colour, width: 3)),
        color: AppTokens.surfaceRaised,
      ),
      child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}

enum AppTone { neutral, warning }
