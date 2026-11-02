/// ADR-061: widgets obtain only validated account-bound message data.
part of 'session_controller.dart';

extension MessageSession on SessionController {
  Future<MessageArchiveView?> messageArchive(
    ScriptPackage package, {
    String? conversationId,
    String? conversationKind,
    int limit = 100,
  }) async {
    final generation = _scripts.generation;
    final registry = await scriptRegistry;
    final store = _store;
    final account = MessageArchiveStore(store).account(package);
    final revision = MessageArchiveStore(store).revision(package);
    bool active() =>
        !_scripts.disposed &&
        identical(store, _store) &&
        generation == _scripts.generation &&
        _school?.id == package.manifest.schoolId &&
        registry.find(package.manifest.id)?.enabled == true &&
        registry.find(package.manifest.id)?.package.digest == package.digest &&
        registry.find(package.manifest.id)?.package.requiresUpdate == false &&
        identical(MessageArchiveStore(store).revision(package), revision) &&
        MessageArchiveStore(store).account(package)?['accountId'] ==
            account?['accountId'] &&
        MessageArchiveStore(store).account(package)?['serviceId'] ==
            account?['serviceId'];
    if (!active() ||
        package.manifest.capability('messages.conversations') == null) {
      return null;
    }
    final result = await MessageArchiveStore(store).read(
      package,
      conversationId: conversationId,
      conversationKind: conversationKind,
      limit: limit,
    );
    return active() ? result : null;
  }
}
