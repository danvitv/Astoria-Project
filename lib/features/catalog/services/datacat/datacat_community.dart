import '../../../../core/credentials/credential_vault.dart';
import '../../catalog_models.dart';
import 'datacat_account.dart';
import 'datacat_errors.dart';
import 'datacat_models.dart';

/// Kudos and comments on a DataCat character.
///
/// Reading is anonymous — the client id is enough. Writing is not: a kudos or a
/// comment is attributed to a logged-in account, so both need the linked user
/// token *and* the installation id it was bound to. A developer token would not
/// substitute, and neither would a `linked_anonymous` installation: there is no
/// such thing as an unattributed comment here.

/// Longest comment the API accepts.
const datacatCommentMaxLength = 4000;

/// Largest comment page the API serves.
const datacatCommentPageLimit = 100;

/// Reads the community panel for [characterId].
Future<DatacatCommunity> datacatFetchCommunity(
  String characterId, {
  required DatacatAccountService account,
  int offset = 0,
  int limit = 40,
}) async {
  final current = account.captureAuthGuard();
  final data = await account.communityRequest(
    'GET', '/characters/${Uri.encodeComponent(characterId)}/community',
    query: {
      'offset': offset,
      'limit': limit.clamp(1, datacatCommentPageLimit),
    },
  );
  if (!current()) throw const CredentialVaultAdmissionDenied();
  return DatacatCommunity.fromJson(data);
}

/// Maps one DataCat comment onto the shared catalog comment.
///
/// The author block was measured carrying `username` and `avatarUrl` only —
/// `displayName` is in the contract but not in any response, so the fallback
/// below is the path every comment actually takes, not an edge case.
CatalogComment datacatComment(Map<String, dynamic> json) {
  final author = datacatMap(json['author']);
  final username = datacatString(author['username']);
  final name = datacatString(author['displayName']).isNotEmpty
      ? datacatString(author['displayName'])
      : username;
  return CatalogComment(
    id: datacatString(json['id']),
    content: datacatString(json['body']),
    authorName: name.isEmpty ? 'Anonymous' : name,
    authorUserName: username,
    avatarUrl: author['avatarUrl'] as String?,
    createdAt: DateTime.tryParse(datacatString(json['createdAt'])),
  );
}

/// Sends a kudos reply using [giftKey], as the linked account.
///
/// Both writes answer with the refreshed thread, so the caller gets the new
/// state without a second read — which also means the count the user sees is
/// the server's, not one the client incremented hopefully.
Future<DatacatCommunity> datacatSendKudos(
  String characterId, {
  required DatacatAccountService account,
  required String giftKey,
}) async {
  final current = account.captureAuthGuard();
  final data = await account.communityRequest(
    'POST', '/characters/${Uri.encodeComponent(characterId)}/community/kudos',
    body: {'giftKey': giftKey},
    requiredAccount: true,
  );
  if (!current()) throw const CredentialVaultAdmissionDenied();
  return DatacatCommunity.fromJson(data);
}

/// Posts a plain comment as the linked account.
Future<DatacatCommunity> datacatPostComment(
  String characterId, {
  required DatacatAccountService account,
  required String body,
}) async {
  final text = body.trim();
  if (text.isEmpty || text.length > datacatCommentMaxLength) {
    throw const DatacatApiException(
      status: 400,
      message: 'A comment must be between 1 and 4000 characters',
    );
  }
  final current = account.captureAuthGuard();
  final data = await account.communityRequest(
    'POST', '/characters/${Uri.encodeComponent(characterId)}/community/comments',
    body: {'body': text},
    requiredAccount: true,
  );
  if (!current()) throw const CredentialVaultAdmissionDenied();
  return DatacatCommunity.fromJson(data);
}
