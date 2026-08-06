/// Value-free WebView authentication state exposed to UI (ADR-012 §2.2, red line #1).
library;

enum WebViewLoginStatus { success, cancelled, error }

class WebViewLoginResult {
  const WebViewLoginResult({required this.status, this.error});

  final WebViewLoginStatus status;
  final String? error;
}

enum WebViewAuthPhase { loading, harvesting, blocked, error, complete }

/// Structurally cannot carry raw URLs, cookies, tickets, or native exceptions.
class WebViewAuthUiState {
  const WebViewAuthUiState({required this.phase, this.location, this.message});

  final WebViewAuthPhase phase;
  final String? location;
  final String? message;
}
