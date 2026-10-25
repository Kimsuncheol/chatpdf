class User {
  const User({
    required this.id,
    required this.email,
    required this.subscription,
  });
  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as String,
    email: json['email'] as String,
    subscription: json['subscription_tier'] as String? ?? 'unknown',
  );
  final String id;
  final String email;
  // Display-only server data; never proof of API authorization.
  final String subscription;
}
