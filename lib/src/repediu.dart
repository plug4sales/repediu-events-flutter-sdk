import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ecommerce.dart';
import 'repediu_client.dart';

/// Entry point of the SDK.
///
/// Calls made before [init] completes are kept, up to 100, and replayed once it does. No method ever throws into
/// the app.
class Repediu {
  Repediu._();

  static const _maxEarlyCalls = 100;
  static RepediuClient? _client;
  static final _early = <void Function(RepediuClient client)>[];
  static Future<void>? _starting;

  /// Ecommerce events: item views, cart, checkout, purchase and cancellation.
  static const order = RepediuOrder(track);

  /// Starts the SDK for the store identified by [writeKey].
  ///
  /// Call once, usually before `runApp`; later calls are ignored. [endpoint] defaults to the Repediu collector.
  /// [debug] prints every queued event and sent batch. Does nothing on Flutter web, where the JavaScript
  /// tracker should be used.
  static Future<void> init({required String writeKey, String endpoint = defaultEndpoint, bool debug = false}) =>
      _starting ??= _start(writeKey, endpoint, debug).whenComplete(() {
        if (_client == null) _starting = null;
      });

  static Future<void> _start(String writeKey, String endpoint, bool debug) async {
    if (kIsWeb) {
      if (debug) debugPrint('[Repediu] Flutter web is not supported — use the JavaScript tracker');
      return;
    }
    if (writeKey.trim().isEmpty) {
      debugPrint('[Repediu] Error: writeKey is required');
      return;
    }
    if (!allowedEndpoint(endpoint)) {
      debugPrint('[Repediu] Error: endpoint must use https');
      return;
    }
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final client = RepediuClient(
        writeKey: writeKey.trim(),
        endpoint: endpoint,
        platform: _platform(),
        userAgent: 'RepediuFlutter/$sdkVersion (${_platformLabel()}; Mobile)',
        debug: debug,
        prefs: await SharedPreferences.getInstance(),
        httpClient: http.Client(),
        clock: DateTime.now,
      );
      client.start();
      _client = client;
      for (final action in _early) {
        action(client);
      }
      _early.clear();
    } catch (error) {
      if (debug) debugPrint('[Repediu] init failed: $error');
    }
  }

  /// Sends [event] with [properties].
  ///
  /// Event names outside the Repediu contract are dropped. Prefer [screen], [search] and [order]; use this
  /// for contract events without a helper. Property values should be JSON values: a [DateTime] is sent as
  /// ISO 8601, a non-finite number as null and any other object as its `toString()`.
  static void track(String event, [Map<String, Object?> properties = const {}]) =>
      _call((client) => client.track(event, properties));

  /// Records a `page_view` of [name], such as `/menu` or `/store/downtown`, and a `page_leave` with
  /// the time spent on the previous screen.
  ///
  /// Not needed for named routes when [RepediuNavigatorObserver] is installed.
  static void screen(String name) => _call((client) => client.screen(name));

  /// Links this device to a customer.
  ///
  /// The user id is [userId] when given, otherwise a hash of [phone], otherwise a hash of [email]. Events
  /// still queued are attributed to the customer too. [phone], [email] and [name] travel in clear only on
  /// the `identify` event itself.
  static void identify({String? userId, String? phone, String? email, String? name}) =>
      _call((client) => client.identify(userId: userId, phone: phone, email: email, name: name));

  /// Records a `search` for [query].
  static void search(String query, [Map<String, Object?> properties = const {}]) =>
      _call((client) => client.track('search', {'query': query, ...properties}));

  /// Records a `promotion_visible` for the banner or promotion [id] shown as [name], once per screen.
  ///
  /// [url] is where the promotion leads, if anywhere; a link carrying Repediu campaign parameters marks the
  /// promotion as coming from a Repediu campaign.
  static void promotionView(String id, String name, {String? url}) =>
      _call((client) => client.promotionView(id, name, url: url));

  /// Records a `promotion_click` on the banner or promotion [id], with the same fields as [promotionView].
  static void promotionClick(String id, String name, {String? url}) =>
      _call((client) => client.promotionClick(id, name, url: url));

  /// Switches the store events are sent to, for apps that serve several stores.
  ///
  /// The current screen is closed under the previous store. Events already queued keep the store they were
  /// tracked under.
  static void setWriteKey(String key) => _call((client) => client.setWriteKey(key));

  /// Adds [properties] to every following event until [unregister] or [reset].
  static void register(Map<String, Object?> properties) => _call((client) => client.register(properties));

  /// Stops adding the property [key] set with [register].
  static void unregister(String key) => _call((client) => client.unregister(key));

  /// Reads `rid` and `utm_*` from a deep link [uri] and attaches them to the
  /// rest of the session.
  ///
  /// Links routed by Flutter are read automatically; call this only when the app handles links itself.
  static void setCampaignFromUri(Uri uri) => _call((client) => client.setCampaignFromUri(uri));

  /// Forgets the customer, the session and the [register] properties, for logout. The install id is kept.
  static void reset() => _call((client) => client.reset());

  /// Stops all tracking and erases the ids and the queue stored on the device, until [optIn]. Survives app
  /// restarts.
  static void optOut() => _call((client) => client.optOut());

  /// Resumes tracking after [optOut].
  static void optIn() => _call((client) => client.optIn());

  /// Whether the user opted out with [optOut].
  static bool get hasOptedOut => _client?.hasOptedOut ?? false;

  /// Random id of this install, or null before [init].
  static String? get anonymousId => _client == null || hasOptedOut ? null : _client!.anonymousId;

  /// Customer id set by [identify], or null.
  static String? get userId => _client?.userId;

  /// Sends the queued events now.
  ///
  /// Batches already go out every 3 seconds, every 20 events and when the app goes to the background.
  static Future<void> flush() => _client?.flush() ?? Future.value();

  static void _call(void Function(RepediuClient client) action) {
    final client = _client;
    if (client != null) return action(client);
    if (_early.length < _maxEarlyCalls) _early.add(action);
  }

  static String _platform() => switch (defaultTargetPlatform) {
        TargetPlatform.android => 'android',
        TargetPlatform.iOS => 'ios',
        final other => other.name.toLowerCase(),
      };

  static String _platformLabel() => switch (defaultTargetPlatform) {
        TargetPlatform.android => 'Android',
        TargetPlatform.iOS => 'iOS',
        final other => other.name,
      };
}
