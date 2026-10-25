abstract final class AppRoutes {
  static const startup = '/startup';
  static const signIn = '/sign-in';
  static const createAccount = '/create-account';
  static const resetPassword = '/reset-password';
  static const library = '/';
  static const upload = '/upload';
  static const history = '/history';
  static const settings = '/settings';
  static String processing(String documentId) =>
      Uri(path: upload, queryParameters: {'documentId': documentId}).toString();
  static String chat(String documentId, {String? conversationId}) => Uri(
    path: '/documents/${Uri.encodeComponent(documentId)}/chat',
    queryParameters: {'conversationId': ?conversationId},
  ).toString();
}
