/// Stable view model for query.controls 1.0 (ADR-071 compatibility).
library;

class QueryControls {
  const QueryControls({
    required this.target,
    required this.title,
    required this.submitLabel,
    required this.controls,
  });
  final String target, title, submitLabel;
  final List<QueryControlsControls> controls;
}

class QueryControlsControls {
  const QueryControlsControls({
    required this.id,
    required this.kind,
    required this.label,
    required this.parameter,
    this.initialValue,
    this.initialEnd,
    this.options,
  });
  final String id, kind, label, parameter;
  final String? initialValue, initialEnd;
  final List<QueryControlsControlsOptions>? options;
}

class QueryControlsControlsOptions {
  const QueryControlsControlsOptions({
    required this.value,
    required this.label,
  });
  final String value, label;
}
