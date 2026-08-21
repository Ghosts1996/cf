/// Metadata and lifetime stats for a single proxied connection.
///
/// Emitted as part of the list on [SingboxClient.connectionStream].
/// Use [isActive] to distinguish open from closed connections.
class ConnectionInfo {
  /// Unique connection identifier assigned by the Sing-box core.
  final String id;

  /// Tag of the inbound that accepted the connection (from config).
  final String inbound;

  /// Protocol type of the inbound (e.g. `'mixed'`, `'tun'`).
  final String inboundType;

  /// IP version: `4` or `6`.
  final int ipVersion;

  /// Transport protocol: `'tcp'` or `'udp'`.
  final String network;

  /// Source address in `IP:port` format.
  final String source;

  /// Destination address in `IP:port` format.
  final String destination;

  /// Resolved domain name, if available.
  final String domain;

  /// Sniffed application protocol (e.g. `'http'`, `'tls'`, `'dns'`).
  final String protocol;

  /// Authenticated user name, if the inbound uses user authentication.
  final String user;

  /// Tag of the outbound used to forward this connection.
  final String outbound;

  /// Protocol type of the outbound (e.g. `'vless'`, `'direct'`).
  final String outboundType;

  /// Time the connection was opened.
  final DateTime createdAt;

  /// Time the connection was closed. `null` if the connection is still active.
  final DateTime? closedAt;

  /// Total bytes sent upstream since the connection opened.
  final int uplinkTotalBytes;

  /// Total bytes received downstream since the connection opened.
  final int downlinkTotalBytes;

  /// Route rule that matched this connection.
  final String rule;

  /// Outbound detour chain (e.g. `'proxy -> direct'`).
  final String chain;

  /// Android package name of the originating app (per-app proxy only).
  final String? packageName;

  /// Originating process path (desktop platforms only).
  final String? processPath;

  /// Creates a [ConnectionInfo] with all required fields.
  const ConnectionInfo({
    required this.id,
    this.inbound = '',
    this.inboundType = '',
    this.ipVersion = 4,
    this.network = '',
    this.source = '',
    this.destination = '',
    this.domain = '',
    this.protocol = '',
    this.user = '',
    this.outbound = '',
    this.outboundType = '',
    required this.createdAt,
    this.closedAt,
    this.uplinkTotalBytes = 0,
    this.downlinkTotalBytes = 0,
    this.rule = '',
    this.chain = '',
    this.packageName,
    this.processPath,
  });

  /// Deserializes a [ConnectionInfo] from a platform channel map.
  factory ConnectionInfo.fromMap(Map<Object?, Object?> map) {
    return ConnectionInfo(
      id: map['id'] as String? ?? '',
      inbound: map['inbound'] as String? ?? '',
      inboundType: map['inboundType'] as String? ?? '',
      ipVersion: (map['ipVersion'] as num?)?.toInt() ?? 4,
      network: map['network'] as String? ?? '',
      source: map['source'] as String? ?? '',
      destination: map['destination'] as String? ?? '',
      domain: map['domain'] as String? ?? '',
      protocol: map['protocol'] as String? ?? '',
      user: map['user'] as String? ?? '',
      outbound: map['outbound'] as String? ?? '',
      outboundType: map['outboundType'] as String? ?? '',
      createdAt: map['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch((map['createdAt'] as num).toInt())
          : DateTime.now(),
      closedAt: map['closedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch((map['closedAt'] as num).toInt())
          : null,
      uplinkTotalBytes: (map['uplinkTotalBytes'] as num?)?.toInt() ?? 0,
      downlinkTotalBytes: (map['downlinkTotalBytes'] as num?)?.toInt() ?? 0,
      rule: map['rule'] as String? ?? '',
      chain: map['chain'] as String? ?? '',
      packageName: map['packageName'] as String?,
      processPath: map['processPath'] as String?,
    );
  }

  /// `true` when [closedAt] is `null` — the connection is still open.
  bool get isActive => closedAt == null;

  /// Returns a copy of this connection with the given fields replaced.
  ConnectionInfo copyWith({DateTime? closedAt, int? uplinkTotalBytes, int? downlinkTotalBytes}) =>
      ConnectionInfo(
        id: id,
        inbound: inbound,
        inboundType: inboundType,
        ipVersion: ipVersion,
        network: network,
        source: source,
        destination: destination,
        domain: domain,
        protocol: protocol,
        user: user,
        outbound: outbound,
        outboundType: outboundType,
        createdAt: createdAt,
        closedAt: closedAt ?? this.closedAt,
        uplinkTotalBytes: uplinkTotalBytes ?? this.uplinkTotalBytes,
        downlinkTotalBytes: downlinkTotalBytes ?? this.downlinkTotalBytes,
        rule: rule,
        chain: chain,
        packageName: packageName,
        processPath: processPath,
      );
}
