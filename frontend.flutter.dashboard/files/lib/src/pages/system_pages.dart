import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../access/session.dart';
import '../design/states.dart';
import '../design/tokens.dart';
import '../foundation/failure.dart';

/// Sign-in, with whatever methods the connected sign-in module offers.
class SignInPage extends ConsumerStatefulWidget {
  const SignInPage({required this.returnTo, super.key});

  /// Already checked to be a path inside this app.
  final String returnTo;

  @override
  ConsumerState<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends ConsumerState<SignInPage> {
  bool _busy = false;
  Object? _error;

  Future<void> _run(SignInOption option) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await option.signIn();
      // The router's sign-in guard sends a signed-in person on to [returnTo]
      // when the session changes; nothing to navigate here.
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final SignInActions? actions = ref.watch(signInActionsProvider);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.space6),
            child: actions == null
                ? const StateMessage(
                    icon: Icons.power_off_outlined,
                    title: 'No sign-in connected',
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text('Sign in', style: text.headlineSmall),
                      const SizedBox(height: AppTokens.space6),
                      for (final SignInOption option
                          in actions.options) ...<Widget>[
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _run(option),
                          icon: Icon(option.icon),
                          label: Text(option.label),
                        ),
                        const SizedBox(height: AppTokens.space3),
                      ],
                      if (_error != null)
                        Text(
                          describeFailure(_error!),
                          style: text.bodyMedium?.copyWith(
                            color: AppColors.of(context).danger,
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class ForbiddenPage extends StatelessWidget {
  const ForbiddenPage({super.key});

  @override
  Widget build(BuildContext context) => const StateMessage(
    icon: Icons.lock_outline,
    title: 'Not allowed',
    detail: 'Your account does not have access to this page.',
  );
}

/// A page needing a signed-in person, in a build with no sign-in.
class NoSignInPage extends StatelessWidget {
  const NoSignInPage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: StateMessage(
      icon: Icons.power_off_outlined,
      title: 'No sign-in connected',
      detail: 'This build has no sign-in, so pages that need one cannot open.',
    ),
  );
}

class StartingPage extends StatelessWidget {
  const StartingPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: LoadingState(label: 'Starting'));
}

class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: StateMessage(
      icon: Icons.explore_off_outlined,
      title: 'Page not found',
      action: OutlinedButton(
        onPressed: () => context.go('/'),
        child: const Text('Home'),
      ),
    ),
  );
}
