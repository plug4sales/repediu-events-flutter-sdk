import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'identity.dart';

const sdkName = 'flutter';
const sdkVersion = '0.1.1';
const defaultEndpoint = 'https://tracker.repediu.com.br/collect';

const allowedEvents = {
  'page_view',
  'page_leave',
  'scroll_depth',
  'item_visible',
  'item_hidden',
  'item_attention',
  'item_revisit',
  'promotion_visible',
  'promotion_click',
  'view_category',
  'view_item',
  'add_to_cart',
  'cart_sync',
  'begin_checkout',
  'purchase',
  'order_cancelled',
  'search',
  'identify',
};

const campaignKeys = [
  'rid',
  'utm_source',
  'utm_medium',
  'utm_campaign',
  'utm_term',
  'utm_content',
];

const _anonymousIdKey = '_rpd_aid';
const _userIdKey = '_rpd_uid';
const _sessionKey = '_rpd_sid';
const _optOutKey = '_rpd_opt';
const _queueKey = '_rpd_queue';
const _optedOut = '0';
const _writeKeyField = '_write_key';
const _optedIn = '1';

const batchMaxSize = 20;
const batchInterval = Duration(seconds: 3);
const sessionTimeout = Duration(minutes: 30);
const maxQueuedEvents = 1000;
const requestTimeout = Duration(seconds: 10);
const maxRetryDelay = Duration(minutes: 5);

bool allowedEndpoint(String endpoint) {
  final uri = Uri.tryParse(endpoint);
  if (uri == null) return false;
  if (uri.isScheme('https')) return true;
  return uri.isScheme('http') && const {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
}

class RepediuClient with WidgetsBindingObserver {
  RepediuClient({
    required this.writeKey,
    required this.endpoint,
    required this.platform,
    required this.userAgent,
    required this.debug,
    required SharedPreferences prefs,
    required http.Client httpClient,
    required DateTime Function() clock,
  })  : _prefs = prefs,
        _http = httpClient,
        _clock = clock;

  String writeKey;
  final String endpoint;
  final String platform;
  final String userAgent;
  final bool debug;
  final SharedPreferences _prefs;
  final http.Client _http;
  final DateTime Function() _clock;
  final _random = Random.secure();
  final _superProperties = <String, Object?>{};
  final _promotionsSeen = <String>{};
  final _pending = <Map<String, Object?>>[];
  String _screenPath = '/';
  String _screenTitle = '';
  String _screenUrl = 'app:/';
  DateTime? _screenEnteredAt;
  bool _leftScreenOnPause = false;
  Timer? _timer;
  bool _sending = false;
  bool _queueChanged = false;
  int _failures = 0;
  DateTime? _retryAt;

  bool get hasOptedOut => _prefs.getString(_optOutKey) == _optedOut;

  String? get userId => _prefs.getString(_userIdKey);

  String get anonymousId {
    final existing = _prefs.getString(_anonymousIdKey);
    if (existing != null) return existing;
    final created = _uuid();
    _save(_anonymousIdKey, created);
    _log('New anonymous visitor: $created');
    return created;
  }

  List<Map<String, Object?>> get pendingEvents => List.unmodifiable(_pending);

  void start() {
    _pending.addAll(_loadQueue());
    WidgetsBinding.instance.addObserver(this);
    if (hasOptedOut) {
      _log('User has opted out — tracking disabled');
      return;
    }
    anonymousId;
    setCampaignFromUri(Uri.tryParse(WidgetsBinding.instance.platformDispatcher.defaultRouteName) ?? Uri());
    _startTimer();
    _log('=== Repediu Flutter SDK v$sdkVersion ===');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _leftScreenOnPause = _leftScreenOnPause || _screenEnteredAt != null;
      _guard('page_leave', _leaveScreen);
    }
    if (state == AppLifecycleState.resumed) return _guard('resume', _returnToScreen);
    _guard('queue save', _saveQueueIfChanged);
    _guard('lifecycle flush', flush);
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    setCampaignFromUri(routeInformation.uri);
    return Future.value(false);
  }

  void track(String event, [Map<String, Object?> properties = const {}]) => _guard('track $event', () {
        if (hasOptedOut) return;
        if (!allowedEvents.contains(event)) {
          _log('Event ignored: "$event" is not part of the contract');
          return;
        }
        final sessionId = _sessionId();
        final campaign = _sessionData()?['campaign'];
        _push(_plain({
          _writeKeyField: writeKey,
          'event_id': _uuid(),
          'event': event,
          'properties': {..._superProperties, ...properties},
          'anonymous_id': anonymousId,
          'user_id': userId,
          'session_id': sessionId,
          'timestamp': _clock().toUtc().toIso8601String(),
          'context': {
            'page': {
              'url': _screenUrl,
              'path': _screenPath,
              'title': _screenTitle,
            },
            if (campaign is Map && campaign.isNotEmpty) 'campaign': campaign,
            'platform': platform,
            'user_agent': userAgent,
          },
        }));
      });

  void screen(String name) => _guard('screen', () {
        _leaveScreen();
        _promotionsSeen.clear();
        final route = _withoutPii(name.startsWith('/') ? name : '/$name');
        _screenUrl = 'app:$route';
        _screenPath = route.split(RegExp('[?#]')).first;
        _screenTitle = _screenPath;
        _screenEnteredAt = _clock();
        track('page_view');
      });

  void promotionView(String id, String name, {String? url}) => _guard('promotion', () {
        if (_promotionsSeen.add(id)) track('promotion_visible', _promotion(id, name, url));
      });

  void promotionClick(String id, String name, {String? url}) =>
      _guard('promotion', () => track('promotion_click', _promotion(id, name, url)));

  Map<String, Object?> _promotion(String id, String name, String? url) => {
        'promotion_id': id,
        'promotion_name': name,
        if (url != null && url.isNotEmpty) 'promotion_url': _withoutPii(url),
        'repediu_origin':
            url != null && _queryKeys(url).any(const {'rid', 'rpd_phone', 'rpd_email', 'utm_source'}.contains),
      };

  static Iterable<String> _queryKeys(String url) {
    final query = url.indexOf('?');
    if (query < 0) return const [];
    return url.substring(query + 1).split('#').first.split('&').map((pair) => pair.split('=').first);
  }

  static String _withoutPii(String url) {
    final query = url.indexOf('?');
    if (query < 0) return url;
    final kept = url
        .substring(query + 1)
        .split('&')
        .where((pair) => !const {'rpd_phone', 'rpd_email'}.contains(pair.split('=').first));
    return kept.isEmpty ? url.substring(0, query) : '${url.substring(0, query)}?${kept.join('&')}';
  }

  void _returnToScreen() {
    if (!_leftScreenOnPause || hasOptedOut) return;
    _leftScreenOnPause = false;
    final last = DateTime.tryParse('${_sessionData()?['last']}');
    _screenEnteredAt = _clock();
    if (last == null || _clock().difference(last) >= sessionTimeout) track('page_view');
  }

  void _leaveScreen() {
    final enteredAt = _screenEnteredAt;
    if (enteredAt == null) return;
    _screenEnteredAt = null;
    track('page_leave', {'duration_ms': _clock().difference(enteredAt).inMilliseconds});
  }

  void identify({String? userId, String? phone, String? email, String? name}) => _guard('identify', () {
        if (hasOptedOut) return;
        final derived = deriveUserId(userId: userId, phone: phone, email: email);
        if (derived == null) {
          _log('identify() requires userId, phone or email');
          return;
        }
        _save(_userIdKey, derived);
        _log('User identified: $derived');
        track('identify',
            {'user_id': derived, 'phone': phone, 'email': email, 'name': name}..removeWhere((_, v) => v == null));
        flush();
      });

  void setWriteKey(String key) => _guard('setWriteKey', () {
        final trimmed = key.trim();
        if (trimmed.isEmpty || trimmed == writeKey) return;
        _leaveScreen();
        writeKey = trimmed;
        _log('Write key switched: $trimmed');
      });

  void register(Map<String, Object?> properties) => _guard('register', () {
        _superProperties.addAll(properties);
        _log('Super properties registered: $properties');
      });

  void unregister(String key) => _guard('unregister', () => _superProperties.remove(key));

  void setCampaignFromUri(Uri uri) => _guard('campaign', () {
        if (hasOptedOut) return;
        final campaign = {
          for (final key in campaignKeys)
            if ((uri.queryParameters[key] ?? '').isNotEmpty) key: uri.queryParameters[key],
        };
        if (campaign.isEmpty) return;
        _sessionId();
        final session = _sessionData()!;
        session['campaign'] = campaign;
        _save(_sessionKey, jsonEncode(session));
        _log('Campaign captured: $campaign');
      });

  void reset() => _guard('reset', () {
        _remove(_userIdKey);
        _remove(_sessionKey);
        _superProperties.clear();
        _log('SDK reset — identity and super properties cleared');
      });

  void optOut() => _guard('optOut', () {
        _save(_optOutKey, _optedOut);
        _remove(_userIdKey);
        _remove(_sessionKey);
        _remove(_anonymousIdKey);
        _superProperties.clear();
        _pending.clear();
        _persistQueue();
        _timer?.cancel();
        _timer = null;
        _log('User opted out — tracking disabled, identity cleared');
      });

  void optIn() => _guard('optIn', () {
        _save(_optOutKey, _optedIn);
        _startTimer();
        _log('User opted in — tracking enabled');
      });

  Future<void> flush() async {
    try {
      while (!_sending && _pending.isNotEmpty && !hasOptedOut && !_inBackoff()) {
        if (!await _sendNextBatch()) return;
      }
    } catch (error) {
      _sending = false;
      _log('Flush failed: $error');
    }
  }

  Future<bool> _sendNextBatch() async {
    _sending = true;
    final key = _keyOf(_pending.first);
    final batch = _pending.where((event) => _keyOf(event) == key).take(batchMaxSize).toList();
    final currentUserId = userId;
    if (currentUserId != null) {
      for (final event in batch) {
        event['user_id'] ??= currentUserId;
      }
    }
    _log('Sending batch with ${batch.length} event(s)');

    final delivered = await _post(key, batch);
    _sending = false;
    if (!delivered) {
      _failures++;
      final delay = batchInterval * pow(2, min(_failures, 7));
      _retryAt = _clock().add(delay < maxRetryDelay ? delay : maxRetryDelay);
      _log('Batch kept for retry in ${_retryAt!.difference(_clock()).inSeconds}s');
      return false;
    }

    final sentIds = batch.map((event) => event['event_id']).toSet();
    _pending.removeWhere((event) => sentIds.contains(event['event_id']));
    _persistQueue();
    _failures = 0;
    _retryAt = null;
    _log('Batch sent (${batch.length} event(s))');
    return true;
  }

  String _keyOf(Map<String, Object?> event) => '${event[_writeKeyField] ?? writeKey}';

  Future<bool> _post(String key, List<Map<String, Object?>> events) async {
    try {
      final response = await _http
          .post(
            Uri.parse(endpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'write_key': key,
              'sdk_name': sdkName,
              'sdk_version': sdkVersion,
              'sent_at': _clock().toUtc().toIso8601String(),
              'events': [
                for (final event in events) {...event}..remove(_writeKeyField)
              ],
            }),
          )
          .timeout(requestTimeout);
      final retryable = response.statusCode >= 500 || response.statusCode == 408 || response.statusCode == 429;
      if (response.statusCode >= 400 && !retryable) {
        _log('Dropping ${events.length} event(s) — collector answered ${response.statusCode}');
      }
      return !retryable;
    } catch (error) {
      _log('Network error: $error');
      return false;
    }
  }

  bool _inBackoff() {
    final wait = _retryAt?.difference(_clock());
    return wait != null && wait > Duration.zero && wait <= maxRetryDelay;
  }

  void _push(Map<String, Object?> event) {
    _pending.add(event);
    if (_pending.length > maxQueuedEvents) _pending.removeRange(0, _pending.length - maxQueuedEvents);
    _queueChanged = true;
    _log('Event queued: ${event['event']}');
    if (_pending.length >= batchMaxSize) flush();
  }

  void _startTimer() {
    _timer ??= Timer.periodic(batchInterval, (_) {
      _guard('queue save', _saveQueueIfChanged);
      if (_pending.isNotEmpty) flush();
    });
  }

  String _sessionId() {
    final now = _clock();
    final session = _sessionData();
    if (session != null) {
      final last = DateTime.tryParse('${session['last']}');
      if (last != null && now.difference(last) < sessionTimeout) {
        session['last'] = now.toUtc().toIso8601String();
        _save(_sessionKey, jsonEncode(session));
        return '${session['id']}';
      }
    }
    final id = _uuid();
    final stamp = now.toUtc().toIso8601String();
    _save(_sessionKey, jsonEncode({'id': id, 'start': stamp, 'last': stamp}));
    _log('New session started: $id');
    return id;
  }

  Map<String, Object?>? _sessionData() {
    final raw = _prefs.getString(_sessionKey);
    if (raw == null) return null;
    try {
      return Map<String, Object?>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, Object?>> _loadQueue() {
    final raw = _prefs.getString(_queueKey);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).map((event) => Map<String, Object?>.from(event as Map)).toList();
    } catch (_) {
      return const [];
    }
  }

  void _saveQueueIfChanged() {
    if (_queueChanged) _persistQueue();
  }

  void _persistQueue() {
    _queueChanged = false;
    _save(
        _queueKey,
        jsonEncode([
          for (final event in _pending)
            if (event['event'] != 'identify') event
        ]));
  }

  void _save(String key, String value) => _settle(_prefs.setString(key, value));

  void _remove(String key) => _settle(_prefs.remove(key));

  void _settle(Future<bool> write) => unawaited(write.catchError((Object error) {
        _log('Storage write failed: $error');
        return false;
      }));

  Map<String, Object?> _plain(Map<String, Object?> event) => jsonDecode(jsonEncode(event,
      toEncodable: (value) => switch (value) {
            DateTime() => value.toUtc().toIso8601String(),
            num() => null,
            _ => '$value',
          })) as Map<String, Object?>;

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _guard(String operation, void Function() body) {
    try {
      body();
    } catch (error) {
      _log('$operation failed: $error');
    }
  }

  void _log(String message) {
    if (debug) debugPrint('[Repediu] $message');
  }
}
