/// Severity level of a [LogEntry] from the Sing-box Go core.
enum LogLevel {
  /// Extremely verbose tracing output.
  trace,

  /// Debug-level messages useful during development.
  debug,

  /// Informational messages about normal operation.
  info,

  /// Non-fatal warnings that may indicate configuration issues.
  warn,

  /// Errors that did not stop the service but may affect functionality.
  error,

  /// Fatal errors that caused the service to stop.
  fatal,

  /// Panic-level errors (Go runtime panics).
  panic,
}

/// A single log entry emitted by the Sing-box Go core.
///
/// Received as batches via [SingboxClient.coreLogStream].
/// Suitable for developer-facing log viewers; do not show raw entries to
/// end users — use [SingboxClient.faultStream] for user-facing errors.
class LogEntry {
  /// Severity of this log entry.
  final LogLevel level;

  /// Log message text from the Go core.
  final String message;

  /// Timestamp when the entry was produced.
  final DateTime time;

  /// Creates a [LogEntry].
  const LogEntry({
    required this.level,
    required this.message,
    required this.time,
  });

  /// Deserializes a [LogEntry] from a platform channel map.
  factory LogEntry.fromMap(Map<Object?, Object?> map) {
    return LogEntry(
      level: _parseLevel(map['level'] as String? ?? 'info'),
      message: map['message'] as String? ?? '',
      time: map['time'] != null
          ? DateTime.fromMillisecondsSinceEpoch((map['time'] as num).toInt())
          : DateTime.now(),
    );
  }

  static LogLevel _parseLevel(String raw) {
    switch (raw.toLowerCase()) {
      case 'trace':
        return LogLevel.trace;
      case 'debug':
        return LogLevel.debug;
      case 'warn':
      case 'warning':
        return LogLevel.warn;
      case 'error':
        return LogLevel.error;
      case 'fatal':
        return LogLevel.fatal;
      case 'panic':
        return LogLevel.panic;
      default:
        return LogLevel.info;
    }
  }

  /// Returns a human-readable string, e.g. `[INFO] service started`.
  @override
  String toString() => '[${level.name.toUpperCase()}] $message';
}
