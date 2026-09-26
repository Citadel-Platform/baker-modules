import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../foundation/failure.dart';
import 'tokens.dart';

/// The four things a data-bound region can be showing, each distinct.
///
/// Loading, empty, failed and not configured look alike if they are all a
/// blank rectangle, and each needs a different response from the person
/// looking at it: wait, add something, retry, or set something up. Nothing
/// here ever shows invented data in place of any of them.
class StateMessage extends StatelessWidget {
  const StateMessage({
    required this.icon,
    required this.title,
    this.detail,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final AppColors c = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 32, color: c.textMuted),
              const SizedBox(height: AppTokens.space3),
              Text(title, style: text.titleMedium, textAlign: TextAlign.center),
              if (detail != null) ...<Widget>[
                const SizedBox(height: AppTokens.space2),
                Text(
                  detail!,
                  style: text.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
              if (action != null) ...<Widget>[
                const SizedBox(height: AppTokens.space4),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({this.label = 'Loading', super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: const Center(
      child: Padding(
        padding: EdgeInsets.all(AppTokens.space8),
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.title, this.detail, this.action, super.key});
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => StateMessage(
    icon: Icons.inbox_outlined,
    title: title,
    detail: detail,
    action: action,
  );
}

/// A failure, explained, with Retry when retrying could help.
class FailureState extends StatelessWidget {
  const FailureState({required this.error, this.onRetry, super.key});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (error is NotConfigured) {
      return StateMessage(
        icon: Icons.power_off_outlined,
        title: 'Not set up',
        detail: describeFailure(error),
      );
    }
    return StateMessage(
      icon: error is NotPermitted ? Icons.lock_outline : Icons.error_outline,
      title: error is NotPermitted ? 'Not allowed' : 'Could not load',
      detail: describeFailure(error),
      action: onRetry != null && isRetryable(error)
          ? OutlinedButton(onPressed: onRetry, child: const Text('Retry'))
          : null,
    );
  }
}

/// Renders an [AsyncValue] as one of the four states, or its data.
///
/// [isEmpty] decides when data is "nothing yet" rather than content. While a
/// refresh is running over data already shown, the data stays up: replacing a
/// table with a spinner on every refresh is how people lose their place.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    required this.value,
    required this.builder,
    this.isEmpty,
    this.empty,
    this.onRetry,
    super.key,
  });

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) builder;
  final bool Function(T data)? isEmpty;
  final Widget? empty;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (value.hasValue) {
      final T data = value.requireValue;
      if (isEmpty?.call(data) ?? false) {
        return empty ?? const EmptyState(title: 'Nothing here yet');
      }
      return builder(context, data);
    }
    if (value.hasError) {
      return FailureState(error: value.error!, onRetry: onRetry);
    }
    return const LoadingState();
  }
}
