import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/app_routes.dart';
import '../../state/session_controller.dart';
import '../validation/auth_form_validators.dart';
import '../widgets/auth_feedback.dart';

enum AuthMode { signIn, createAccount, resetPassword }

/// Shared form presentation for the three independently routed auth screens.
/// Session transitions, errors, token handling, and API work live in the controller.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.session, required this.mode});
  final SessionController session;
  final AuthMode mode;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _submitted = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _navigate(String path) {
    if (widget.session.busy) return;
    widget.session.clearFeedback();
    final from = GoRouterState.of(context).uri.queryParameters['from'];
    context.go(Uri(path: path, queryParameters: {'from': ?from}).toString());
  }

  Future<void> _submit() async {
    if (widget.session.busy) return;
    setState(() => _submitted = true);
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    if (widget.mode == AuthMode.resetPassword) {
      await widget.session.resetPassword(_email.text);
    } else {
      final request = widget.session.authenticate(
        _email.text,
        _password.text,
        create: widget.mode == AuthMode.createAccount,
      );
      // No password is kept in controller state or persisted by this app.
      // Clear the form immediately; a rejected attempt requires re-entry.
      setState(() => _submitted = false);
      _password.clear();
      _confirmation.clear();
      await request;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.mode) {
      AuthMode.signIn => 'Sign in',
      AuthMode.createAccount => 'Create account',
      AuthMode.resetPassword => 'Reset password',
    };
    final reset = widget.mode == AuthMode.resetPassword;
    final create = widget.mode == AuthMode.createAccount;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: ListenableBuilder(
                listenable: widget.session,
                builder: (context, _) {
                  final session = widget.session;
                  final busy = session.busy;
                  return Form(
                    key: _form,
                    autovalidateMode: _submitted
                        ? AutovalidateMode.onUserInteraction
                        : AutovalidateMode.disabled,
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'ChatPDF',
                            style: Theme.of(context).textTheme.headlineLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            reset
                                ? 'Enter your account email to request password-reset instructions.'
                                : 'Your documents. Answers with page references.',
                          ),
                          const SizedBox(height: 32),
                          TextFormField(
                            key: const ValueKey('auth-email'),
                            controller: _email,
                            enabled: !busy,
                            autofillHints: const [AutofillHints.email],
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: reset
                                ? TextInputAction.done
                                : TextInputAction.next,
                            autocorrect: false,
                            textCapitalization: TextCapitalization.none,
                            decoration: const InputDecoration(
                              labelText: 'Email',
                            ),
                            validator: AuthFormValidators.email,
                            onFieldSubmitted: reset ? (_) => _submit() : null,
                          ),
                          if (!reset) ...[
                            const SizedBox(height: 16),
                            TextFormField(
                              key: const ValueKey('auth-password'),
                              controller: _password,
                              enabled: !busy,
                              obscureText: _obscurePassword,
                              autocorrect: false,
                              enableSuggestions: false,
                              enableIMEPersonalizedLearning: false,
                              autofillHints: [
                                create
                                    ? AutofillHints.newPassword
                                    : AutofillHints.password,
                              ],
                              textInputAction: create
                                  ? TextInputAction.next
                                  : TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                suffixIcon: IconButton(
                                  onPressed: busy
                                      ? null
                                      : () => setState(
                                          () => _obscurePassword =
                                              !_obscurePassword,
                                        ),
                                  tooltip: _obscurePassword
                                      ? 'Show password'
                                      : 'Hide password',
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: AuthFormValidators.password,
                              onFieldSubmitted: create
                                  ? null
                                  : (_) => _submit(),
                            ),
                            if (create) ...[
                              const SizedBox(height: 16),
                              TextFormField(
                                key: const ValueKey('auth-confirmation'),
                                controller: _confirmation,
                                enabled: !busy,
                                obscureText: _obscurePassword,
                                autocorrect: false,
                                enableSuggestions: false,
                                enableIMEPersonalizedLearning: false,
                                autofillHints: const [
                                  AutofillHints.newPassword,
                                ],
                                textInputAction: TextInputAction.done,
                                decoration: const InputDecoration(
                                  labelText: 'Confirm password',
                                ),
                                validator: (value) =>
                                    AuthFormValidators.confirmation(
                                      value,
                                      _password.text,
                                    ),
                                onFieldSubmitted: (_) => _submit(),
                              ),
                            ],
                          ],
                          if (widget.mode == AuthMode.signIn)
                            CheckboxListTile(
                              key: const ValueKey('remember-me'),
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: const Text('Remember me'),
                              subtitle: const Text(
                                'Keep me signed in on this device until I sign out.',
                              ),
                              value: session.rememberMe,
                              onChanged: busy
                                  ? null
                                  : (value) =>
                                        session.setRememberMe(value ?? false),
                            ),
                          if (session.error != null) ...[
                            const SizedBox(height: 16),
                            AuthFeedback(message: session.error!),
                          ],
                          if (session.notice != null) ...[
                            const SizedBox(height: 16),
                            AuthFeedback(
                              message: session.notice!,
                              isError: false,
                            ),
                          ],
                          const SizedBox(height: 24),
                          FilledButton(
                            onPressed: busy ? null : _submit,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (busy) ...[
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                Text(
                                  busy
                                      ? 'Please wait…'
                                      : reset
                                      ? 'Send reset instructions'
                                      : title,
                                ),
                              ],
                            ),
                          ),
                          if (widget.mode == AuthMode.signIn) ...[
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => _navigate(AppRoutes.createAccount),
                              child: const Text('Create account'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => _navigate(AppRoutes.resetPassword),
                              child: const Text('Forgot password?'),
                            ),
                          ] else
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => _navigate(AppRoutes.signIn),
                              child: const Text('Back to sign in'),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
