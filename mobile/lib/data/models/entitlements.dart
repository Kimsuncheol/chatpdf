class AccountEntitlements {
  AccountEntitlements.fromJson(Map<String, dynamic> json)
    : tier = json['tier'] as String,
      status = json['subscription_status'] as String,
      expiresAt = json['subscription_expires_at'] == null
          ? null
          : DateTime.parse(json['subscription_expires_at'] as String),
      chatAvailable =
          (json['entitlements'] as Map<String, dynamic>)['chat'] as bool,
      models = List<String>.from(
        (json['entitlements'] as Map<String, dynamic>)['allowed_models']
            as List,
      ),
      family =
          (json['entitlements'] as Map<String, dynamic>)['model_family']
              as String?,
      unavailableReason =
          (json['entitlements'] as Map<String, dynamic>)['unavailable_reason']
              as String?;

  final String tier;
  final String status;
  final DateTime? expiresAt;
  final bool chatAvailable;
  final List<String> models;
  final String? family;
  final String? unavailableReason;
}
