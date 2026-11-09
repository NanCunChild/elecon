/// Supported trusted-source SDK range. Package/data versions are independent.
const currentTrustedScriptSdk = 20;
bool supportsTrustedScriptSdk(Object? version) =>
    version is int && version >= 1 && version <= currentTrustedScriptSdk;
