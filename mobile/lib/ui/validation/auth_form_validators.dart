/// Input checks for form usability. Password policy and account eligibility are
/// enforced by Flask, never by these presentation helpers.
abstract final class AuthFormValidators {
  static String? email(String? value) =>
      value != null &&
          RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim())
      ? null
      : 'Enter a valid email address.';

  static String? password(String? value) =>
      value == null || value.isEmpty ? 'Enter your password.' : null;

  static String? confirmation(String? value, String password) =>
      value == null || value.isEmpty
      ? 'Confirm your password.'
      : value != password
      ? 'Passwords do not match.'
      : null;
}
