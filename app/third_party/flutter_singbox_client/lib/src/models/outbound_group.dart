/// A proxy outbound group as reported by the Sing-box core.
///
/// Emitted as part of the list on [SingboxClient.outboundGroupStream].
/// Groups with [selectable] `== true` support [SingboxClient.selectOutbound].
class OutboundGroup {
  /// Group name as defined in the Sing-box config.
  final String tag;

  /// Group type: `'selector'` or `'urltest'`.
  final String type;

  /// Whether the group supports manual outbound selection.
  /// Only `selector` type groups are selectable.
  final bool selectable;

  /// Tag of the currently active outbound in this group.
  final String selected;

  /// Whether the group is expanded in the core's internal UI state.
  final bool isExpand;

  /// All outbounds that belong to this group.
  final List<OutboundGroupItem> items;

  /// Creates an [OutboundGroup].
  const OutboundGroup({
    required this.tag,
    required this.type,
    this.selectable = false,
    this.selected = '',
    this.isExpand = false,
    this.items = const [],
  });

  /// Deserializes an [OutboundGroup] from a platform channel map.
  factory OutboundGroup.fromMap(Map<Object?, Object?> map) {
    final rawItems = map['items'] as List<Object?>? ?? [];
    return OutboundGroup(
      tag: map['tag'] as String? ?? '',
      type: map['type'] as String? ?? '',
      selectable: map['selectable'] as bool? ?? false,
      selected: map['selected'] as String? ?? '',
      isExpand: map['isExpand'] as bool? ?? false,
      items: rawItems
          .cast<Map<Object?, Object?>>()
          .map(OutboundGroupItem.fromMap)
          .toList(),
    );
  }
}

/// A single outbound entry inside an [OutboundGroup].
class OutboundGroupItem {
  /// Outbound name as defined in the Sing-box config.
  final String tag;

  /// Outbound protocol type (e.g. `'vless'`, `'shadowsocks'`).
  final String type;

  /// Timestamp of the last URL latency test. `null` if never tested.
  final DateTime? urlTestTime;

  /// Round-trip latency measured by the last URL test, in milliseconds.
  /// `0` if the outbound has never been tested.
  final int urlTestDelayMs;

  /// Creates an [OutboundGroupItem].
  const OutboundGroupItem({
    required this.tag,
    required this.type,
    this.urlTestTime,
    this.urlTestDelayMs = 0,
  });

  /// Deserializes an [OutboundGroupItem] from a platform channel map.
  factory OutboundGroupItem.fromMap(Map<Object?, Object?> map) {
    return OutboundGroupItem(
      tag: map['tag'] as String? ?? '',
      type: map['type'] as String? ?? '',
      urlTestTime: map['urlTestTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch((map['urlTestTime'] as num).toInt())
          : null,
      urlTestDelayMs: (map['urlTestDelayMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// `true` when [urlTestDelayMs] is greater than zero.
  bool get hasLatency => urlTestDelayMs > 0;
}
