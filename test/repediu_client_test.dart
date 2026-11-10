import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:repediu_events/src/ecommerce.dart';
import 'package:repediu_events/src/identity.dart';
import 'package:repediu_events/src/repediu_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

class Collector {
  final batches = <Map<String, dynamic>>[];
  var online = true;
  var status = 200;
  var attempts = 0;
  Completer<void>? hold;

  late final client = MockClient((request) async {
    attempts++;
    await hold?.future;
    if (!online) throw http.ClientException('offline');
    if (status == 200) batches.add(jsonDecode(request.body) as Map<String, dynamic>);
    return http.Response('{}', status);
  });

  List<Map<String, dynamic>> get events =>
      [for (final batch in batches) ...(batch['events'] as List).cast<Map<String, dynamic>>()];
}

class BrokenDisk extends SharedPreferencesStorePlatform {
  @override
  Future<Map<String, Object>> getAll() async => {};

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async => {};

  @override
  Future<bool> setValue(String valueType, String key, Object value) => Future.error(StateError('disk full'));

  @override
  Future<bool> remove(String key) => Future.error(StateError('disk full'));

  @override
  Future<bool> clear() => Future.error(StateError('disk full'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Collector collector;
  late SharedPreferences prefs;
  late DateTime now;
  final clients = <RepediuClient>[];

  RepediuClient startClient() {
    final client = RepediuClient(
      writeKey: 'wk_test',
      endpoint: 'https://collector.test/collect',
      platform: 'android',
      userAgent: 'RepediuFlutter/$sdkVersion (Android; Mobile)',
      debug: false,
      prefs: prefs,
      httpClient: collector.client,
      clock: () => now,
    )..start();
    clients.add(client);
    return client;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    collector = Collector();
    now = DateTime.utc(2026, 10, 26, 15);
  });

  tearDown(() {
    for (final client in clients) {
      client.dispose();
    }
    clients.clear();
  });

  test('the version sent to the collector is the published version', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    expect(pubspec, contains('version: $sdkVersion'));
  });

  group('identity derivation matches the web SDK', () {
    test('hashes with the same FNV variant as the JavaScript tracker', () {
      expect(hashId('5517999998888'), 'af426ec6c64d5584');
      expect(hashId('cliente@exemplo.com'), 'd53cc68aada542bc');
      expect(hashId('joão@pão.com.br'), '9446394582d87967');
      expect(hashId(''), '811c9dc501000193');
    });

    test('prefers user id, then phone, then email', () {
      expect(deriveUserId(userId: ' 42 ', phone: '17999998888'), '42');
      expect(deriveUserId(phone: '(17) 99999-8888'), 'rpd:tel:af426ec6c64d5584');
      expect(deriveUserId(email: ' Cliente@Exemplo.com '), 'rpd:mail:d53cc68aada542bc');
      expect(deriveUserId(phone: '123'), isNull);
    });
  });

  test('only https endpoints are allowed, keeping http for local development', () {
    expect(allowedEndpoint('https://tracker.repediu.com.br/collect'), isTrue);
    expect(allowedEndpoint('http://tracker.repediu.com.br/collect'), isFalse);
    expect(allowedEndpoint('http://localhost:8080/collect'), isTrue);
    expect(allowedEndpoint('http://10.0.2.2:8080/collect'), isTrue);
    expect(allowedEndpoint('ftp://tracker.repediu.com.br'), isFalse);
  });

  test('a batch follows the collector contract used by the web SDK', () async {
    final client = startClient();
    client.screen('/cardapio');
    RepediuOrder(client.track).addToCart('pizza-calabresa', 'Calabresa', price: 64.9);
    await client.flush();

    final batch = collector.batches.single;
    expect(batch['write_key'], 'wk_test');
    expect(batch['sdk_name'], 'flutter');
    expect(batch['sdk_version'], sdkVersion);
    expect(batch['sent_at'], '2026-10-26T15:00:00.000Z');

    final addToCart = collector.events.last;
    expect(addToCart['event'], 'add_to_cart');
    expect(addToCart['properties'],
        {'item_id': 'pizza-calabresa', 'item_name': 'Calabresa', 'quantity': 1, 'price': 64.9});
    expect(addToCart['anonymous_id'], client.anonymousId);
    expect(addToCart['session_id'], isNotEmpty);
    expect(addToCart['context'], {
      'page': {'url': 'app:/cardapio', 'path': '/cardapio', 'title': '/cardapio'},
      'platform': 'android',
      'user_agent': 'RepediuFlutter/$sdkVersion (Android; Mobile)',
    });
    expect(client.pendingEvents, isEmpty);
  });

  test('queued events survive the app being killed in the background before sending', () async {
    collector.online = false;
    startClient()
      ..track('view_category', {'category': 'Pizzas'})
      ..didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();

    collector.online = true;
    final restarted = startClient();
    await restarted.flush();

    expect(collector.events.map((e) => e['event']), ['view_category']);
  });

  test('tracking does not rewrite the stored queue on every event, only when the app leaves the foreground', () async {
    collector.online = false;
    final client = startClient();
    for (var i = 0; i < 3; i++) {
      client.track('search', {'query': '$i'});
    }
    expect(prefs.getString('_rpd_queue'), isNull);

    client.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await pumpEventQueue();

    expect(jsonDecode(prefs.getString('_rpd_queue')!), hasLength(3));
  });

  test('a network failure keeps the batch and retries after the backoff', () async {
    final client = startClient();
    collector.online = false;
    client.track('search', {'query': 'pizza'});
    await client.flush();
    expect(client.pendingEvents, hasLength(1));

    collector.online = true;
    await client.flush();
    expect(collector.batches, isEmpty);

    now = now.add(const Duration(seconds: 7));
    await client.flush();
    expect(collector.events.single['event'], 'search');
    expect(client.pendingEvents, isEmpty);
  });

  test('the session survives short pauses and rolls over after 30 minutes idle', () async {
    final client = startClient();
    client.track('page_view');
    now = now.add(const Duration(minutes: 29));
    client.track('page_view');
    now = now.add(const Duration(minutes: 31));
    client.track('page_view');
    await client.flush();

    final sessions = collector.events.map((e) => e['session_id']).toList();
    expect(sessions[0], sessions[1]);
    expect(sessions[2], isNot(sessions[1]));
  });

  test('identify stamps the user on events queued before it', () async {
    final client = startClient();
    client.track('view_item', {'item_id': 'x'});
    client.identify(phone: '17999998888', name: 'Cliente');
    await pumpEventQueue();
    await client.flush();

    expect(collector.events.map((e) => e['user_id']), everyElement('rpd:tel:af426ec6c64d5584'));
    expect(collector.events.last['properties'],
        {'user_id': 'rpd:tel:af426ec6c64d5584', 'phone': '17999998888', 'name': 'Cliente'});
  });

  test('the identify event with the raw phone, email and name is never written to disk', () async {
    collector.online = false;
    final client = startClient();
    client.identify(phone: '17999998888', email: 'ana@exemplo.com', name: 'Ana');
    client.track('search', {'query': 'pizza'});
    client.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();

    final stored = prefs.getString('_rpd_queue')!;
    expect(stored, isNot(contains('17999998888')));
    expect(stored, isNot(contains('ana@exemplo.com')));
    expect(stored, isNot(contains('identify')));
    expect(jsonDecode(stored), hasLength(1));
  });

  test('campaign parameters from a deep link ride along until the session ends', () async {
    final client = startClient();
    client.setCampaignFromUri(
        Uri.parse('pizzeria://abrir?utm_source=whatsapp&rid=abc&rpd_phone=5511999990000&rpd_email=ana@x.com&outro=1'));
    client.track('page_view');
    now = now.add(const Duration(hours: 1));
    client.track('page_view');
    await client.flush();

    expect(collector.events.first['context']['campaign'], {'utm_source': 'whatsapp', 'rid': 'abc'});
    expect((collector.events.last['context'] as Map).containsKey('campaign'), isFalse);
  });

  test('the link that opened the app carries its campaign', () async {
    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.defaultRouteNameTestValue = '/loja/centro?rid=abc&utm_source=whatsapp';
    addTearDown(binding.platformDispatcher.clearDefaultRouteNameTestValue);

    final client = startClient();
    client.screen('/loja/centro?rid=abc&utm_source=whatsapp');
    await client.flush();

    final pageView = collector.events.single;
    expect(pageView['context']['campaign'], {'rid': 'abc', 'utm_source': 'whatsapp'});
    expect(pageView['context']['page']['url'], 'app:/loja/centro?rid=abc&utm_source=whatsapp');
    expect(pageView['context']['page']['path'], '/loja/centro');
  });

  test('the screen url never carries the phone or email from the link', () async {
    final client = startClient();
    client.screen('/loja/centro?rid=abc&rpd_phone=5517999990000&rpd_email=ana@x.com');
    client.screen('/cardapio?rpd_phone=5517999990000');
    await client.flush();

    final urls = collector.events.where((e) => e['event'] == 'page_view').map((e) => e['context']['page']['url']);
    expect(urls, ['app:/loja/centro?rid=abc', 'app:/cardapio']);
  });

  test('a store-specific delivery mode is sent as given', () async {
    final client = startClient();
    RepediuOrder(client.track).placeOrder('pedido-1', 24.9, deliveryType: const DeliveryType('dine_in'));
    await client.flush();

    expect(collector.events.single['properties']['delivery_type'], 'dine_in');
    expect(const DeliveryType('pickup'), DeliveryType.pickup);
  });

  test('a promotion is seen once per screen and every click counts', () async {
    final client = startClient();
    client.screen('/cardapio');
    client.promotionView('cashback-15', 'Cashback 15%', url: 'app:/promo?rid=abc');
    client.promotionView('cashback-15', 'Cashback 15%', url: 'app:/promo?rid=abc');
    client.promotionClick('cashback-15', 'Cashback 15%', url: 'app:/promo?rid=abc');
    client.promotionClick('cashback-15', 'Cashback 15%', url: 'app:/promo?rid=abc');
    client.screen('/cardapio');
    client.promotionView('combo-doce', 'Combo doce');
    await client.flush();

    final promotions = collector.events.where((e) => '${e['event']}'.startsWith('promotion_')).toList();
    expect(promotions.map((e) => e['event']),
        ['promotion_visible', 'promotion_click', 'promotion_click', 'promotion_visible']);
    expect(promotions.first['properties'], {
      'promotion_id': 'cashback-15',
      'promotion_name': 'Cashback 15%',
      'promotion_url': 'app:/promo?rid=abc',
      'repediu_origin': true,
    });
    expect(promotions.last['properties'],
        {'promotion_id': 'combo-doce', 'promotion_name': 'Combo doce', 'repediu_origin': false});
  });

  test('a malformed link in a screen or promotion never throws into the app', () async {
    final client = startClient();
    client.screen('/busca?q=%FF');
    client.promotionClick('promo', 'Promo', url: 'https://loja.com/?q=%FF&rpd_phone=5517999990000&rid=abc');
    await client.flush();

    expect(collector.events.map((e) => e['event']), ['page_view', 'promotion_click']);
    expect(collector.events.last['properties'], {
      'promotion_id': 'promo',
      'promotion_name': 'Promo',
      'promotion_url': 'https://loja.com/?q=%FF&rid=abc',
      'repediu_origin': true,
    });
  });

  test('a link received while the app is open replaces the campaign without being consumed', () async {
    final client = startClient();
    final handled = await client.didPushRouteInformation(RouteInformation(uri: Uri.parse('/abrir?rid=xyz')));
    client.track('search', {'query': 'pizza'});
    await client.flush();

    expect(handled, isFalse);
    expect(collector.events.single['context']['campaign'], {'rid': 'xyz'});
  });

  test('leaving a screen reports how long it stayed in front', () async {
    final client = startClient();
    client.screen('/cardapio');
    now = now.add(const Duration(seconds: 5));
    client.screen('/produto/calabresa');
    await client.flush();

    expect(collector.events.map((e) => e['event']), ['page_view', 'page_leave', 'page_view']);
    final leave = collector.events[1];
    expect(leave['properties'], {'duration_ms': 5000});
    expect(leave['context']['page']['path'], '/cardapio');
  });

  test('time on screen stops in the background and counts again on return', () async {
    final client = startClient();
    client.screen('/cardapio');
    now = now.add(const Duration(seconds: 3));
    client.didChangeAppLifecycleState(AppLifecycleState.paused);
    client.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 5));
    client.didChangeAppLifecycleState(AppLifecycleState.resumed);
    now = now.add(const Duration(seconds: 4));
    client.screen('/carrinho');
    await pumpEventQueue();
    await client.flush();

    expect(collector.events.map((e) => e['event']), ['page_view', 'page_leave', 'page_leave', 'page_view']);
    expect(collector.events.where((e) => e['event'] == 'page_leave').map((e) => e['properties']), [
      {'duration_ms': 3000},
      {'duration_ms': 4000},
    ]);
  });

  test('returning after the session expired opens the screen again in the new session', () async {
    final client = startClient();
    client.screen('/cardapio');
    client.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 40));
    client.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
    await client.flush();

    final views = collector.events.where((e) => e['event'] == 'page_view').toList();
    expect(views, hasLength(2));
    expect(views.last['context']['page']['path'], '/cardapio');
    expect(views.last['session_id'], isNot(views.first['session_id']));
  });

  test('register merges store context into every event until reset', () async {
    final client = startClient();
    client.register({'store_id': 'centro'});
    client.track('view_category', {'category': 'Pizzas'});
    client.reset();
    client.track('view_category', {'category': 'Bebidas'});
    await client.flush();

    expect(collector.events.first['properties'], {'store_id': 'centro', 'category': 'Pizzas'});
    expect(collector.events.last['properties'], {'category': 'Bebidas'});
  });

  test('opting out drops queued events and stops tracking until opt in', () async {
    final client = startClient();
    client.track('page_view');
    client.optOut();
    client.track('page_view');
    await client.flush();
    expect(collector.batches, isEmpty);
    expect(client.hasOptedOut, isTrue);

    client.optIn();
    client.track('search', {'query': 'pizza'});
    await client.flush();
    expect(collector.events.map((e) => e['event']), ['search']);
  });

  test('opting out clears registered properties so they do not come back after opting in', () async {
    final client = startClient();
    client.register({'store_id': 'centro'});
    client.optOut();
    client.optIn();
    client.track('search', {'query': 'pizza'});
    await client.flush();

    expect(collector.events.single['properties'], {'query': 'pizza'});
  });

  test('switching the write key sends each event under the key active when it was tracked', () async {
    final client = startClient();
    client.track('page_view');
    client.setWriteKey('wk_loja_norte');
    client.track('view_category', {'category': 'Pizzas'});
    client.track('view_item', {'item_id': 'x'});
    await client.flush();

    expect(collector.batches.map((b) => b['write_key']), ['wk_test', 'wk_loja_norte']);
    expect(collector.batches.last['events'].map((e) => e['event']), ['view_category', 'view_item']);
    expect(collector.events.every((e) => !e.containsKey('_write_key')), isTrue);
  });

  Map<String, List<String>> eventsByKey() {
    final result = <String, List<String>>{};
    for (final batch in collector.batches) {
      result.putIfAbsent(batch['write_key'] as String, () => []).addAll([
        for (final event in batch['events'] as List) '${event['event']} ${event['context']['page']['path']}',
      ]);
    }
    return result;
  }

  test('a customer hopping between stores lands every event in the project of the store it happened in', () async {
    final client = startClient();
    final order = RepediuOrder(client.track);
    client.screen('/lojas');
    client.setWriteKey('wk_centro');
    client.screen('/loja/centro');
    order.addToCart('acai-500', 'Açaí 500ml', price: 24.9);
    client.setWriteKey('wk_norte');
    client.screen('/loja/norte');
    order.viewItem('acai-300', 'Açaí 300ml');
    client.setWriteKey('wk_centro');
    client.screen('/loja/centro');
    order.placeOrder('pedido-1', 24.9);
    await client.flush();

    expect(eventsByKey(), {
      'wk_test': ['page_view /lojas', 'page_leave /lojas'],
      'wk_centro': [
        'page_view /loja/centro',
        'add_to_cart /loja/centro',
        'page_leave /loja/centro',
        'page_view /loja/centro',
        'purchase /loja/centro',
      ],
      'wk_norte': ['page_view /loja/norte', 'view_item /loja/norte', 'page_leave /loja/norte'],
    });
  });

  test('events of several stores queued offline survive a restart and each reaches its own project', () async {
    collector.online = false;
    final client = startClient();
    client.setWriteKey('wk_centro');
    client.track('view_category', {'category': 'Açaí'});
    client.setWriteKey('wk_norte');
    client.track('view_category', {'category': 'Bebidas'});
    client.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(collector.batches, isEmpty);

    collector.online = true;
    await startClient().flush();

    expect(collector.batches.map((b) => b['write_key']), ['wk_centro', 'wk_norte']);
    expect(collector.batches.map((b) => b['events'].single['properties']['category']), ['Açaí', 'Bebidas']);
  });

  test('events outside the contract are ignored', () async {
    final client = startClient();
    client.track('app_open');
    await client.flush();
    expect(collector.batches, isEmpty);
  });

  group('the host app is never hurt and nobody can steer the data', () {
    test('a property the encoder cannot handle is converted and never jams the queue', () async {
      final loop = <String, Object?>{};
      loop['self'] = loop;
      collector.online = false;
      final client = startClient();
      client.track('view_item',
          {'item_id': 'x', 'seen_at': DateTime.utc(2026, 10, 26, 15), 'price': double.nan, 'raw': Object()});
      client.track('view_item', {'item_id': 'loop', 'loop': loop});
      client.track('search', {'query': 'pizza'});
      client.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();

      collector.online = true;
      now = now.add(const Duration(minutes: 10));
      await startClient().flush();

      expect(collector.events.map((e) => e['event']), ['view_item', 'search']);
      expect(collector.events.first['properties'],
          {'item_id': 'x', 'seen_at': '2026-10-26T15:00:00.000Z', 'price': null, 'raw': "Instance of 'Object'"});
    });

    test('storage corrupted by an older version or a tampered device does not stop tracking', () async {
      for (final queue in ['not json', '{"a":1}', '[1, "x", null]']) {
        SharedPreferences.setMockInitialValues({'_rpd_queue': queue, '_rpd_sid': '{"id":', '_rpd_opt': 'talvez'});
        prefs = await SharedPreferences.getInstance();
        collector.batches.clear();

        final client = startClient();
        client.screen('/cardapio');
        await client.flush();

        expect(collector.events.map((e) => e['event']), ['page_view'], reason: queue);
        expect(collector.events.single['session_id'], isNotEmpty, reason: queue);
      }
    });

    test('a disk that refuses writes never surfaces as an error in the app', () async {
      SharedPreferencesStorePlatform.instance = BrokenDisk();
      SharedPreferences.resetStatic();
      prefs = await SharedPreferences.getInstance();

      final client = startClient();
      client.screen('/cardapio');
      client.identify(phone: '17999998888');
      client.setCampaignFromUri(Uri.parse('pizzeria://abrir?rid=abc'));
      client.reset();
      client.optOut();
      client.optIn();
      client.track('search', {'query': 'pizza'});
      await pumpEventQueue();
      await client.flush();

      expect(collector.events.map((e) => e['event']), ['page_view', 'identify', 'search'],
          reason: 'identify flushes eagerly, so events queued before the opt-out are delivered; nothing crashes');
    });

    test('a batch the collector refuses is dropped instead of retried forever', () async {
      final client = startClient();
      for (final status in [400, 401, 403, 404, 413, 422]) {
        collector.status = status;
        client.track('search', {'query': '$status'});
        await client.flush();
        expect(client.pendingEvents, isEmpty, reason: '$status');
      }
    });

    test('a collector outage keeps the batch until the collector is back', () async {
      final client = startClient();
      for (final status in [408, 429, 500, 502, 503]) {
        collector.status = status;
        client.track('search', {'query': '$status'});
        await client.flush();
        expect(client.pendingEvents, hasLength(1), reason: '$status');

        collector.status = 200;
        now = now.add(maxRetryDelay);
        await client.flush();
        expect(client.pendingEvents, isEmpty, reason: '$status');
      }
      expect(collector.events.map((e) => e['properties']['query']), ['408', '429', '500', '502', '503']);
    });

    test('a long time offline keeps only the newest events, in memory and on disk', () async {
      collector.online = false;
      final client = startClient();
      for (var i = 0; i < maxQueuedEvents + 50; i++) {
        client.track('search', {'query': '$i'});
      }
      client.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();

      expect(client.pendingEvents, hasLength(maxQueuedEvents));
      expect(client.pendingEvents.first['properties'], {'query': '50'});
      expect(startClient().pendingEvents, hasLength(maxQueuedEvents));
    });

    test('retries back off to one attempt every five minutes while the collector is down', () async {
      collector.online = false;
      final client = startClient();
      client.track('search', {'query': 'pizza'});
      for (var second = 0; second < 3600; second++) {
        await client.flush();
        now = now.add(const Duration(seconds: 1));
      }
      expect(collector.attempts, lessThanOrEqualTo(20));

      collector.online = true;
      now = now.add(maxRetryDelay);
      await client.flush();
      expect(collector.events.single['event'], 'search');
    });

    test('a device clock set back does not freeze delivery', () async {
      collector.online = false;
      final client = startClient();
      client.track('search', {'query': 'pizza'});
      client.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();

      collector.online = true;
      now = now.subtract(const Duration(days: 1));
      now = now.add(maxRetryDelay);
      await client.flush();

      expect(collector.events.single['event'], 'search');
    });

    test('two flushes at the same time never send an event twice', () async {
      final client = startClient();
      client.track('search', {'query': 'pizza'});
      client.track('view_item', {'item_id': 'x'});
      collector.hold = Completer<void>();
      final first = client.flush();
      final second = client.flush();
      collector.hold!.complete();
      await Future.wait([first, second]);
      collector.hold = null;
      await client.flush();

      expect(collector.events.map((e) => e['event']), ['search', 'view_item']);
    });

    test('opting out is remembered after a restart and nothing about the person stays on the device', () async {
      final client = startClient();
      client.identify(phone: '17999998888');
      client.screen('/cardapio');
      client.optOut();
      await pumpEventQueue();
      collector.batches.clear();

      final restarted = startClient();
      restarted.screen('/cardapio');
      restarted.identify(phone: '17999998888');
      RepediuOrder(restarted.track).placeOrder('pedido-1', 24.9);
      await restarted.flush();
      await pumpEventQueue();

      expect(collector.batches, isEmpty);
      expect(prefs.getKeys(), {'_rpd_opt', '_rpd_queue'});
      expect(prefs.getString('_rpd_queue'), '[]');
    });

    test('a hostile link cannot switch the store, impersonate a user or inject fields', () async {
      final client = startClient();
      final link = Uri.parse(
          'pizzeria://abrir?write_key=wk_evil&user_id=admin&anonymous_id=a1&event=purchase&value=999&rid=r1&utm_source=zap');
      client.setCampaignFromUri(link);
      await client.didPushRouteInformation(RouteInformation(uri: link));
      client.screen('/loja/centro?write_key=wk_evil&user_id=admin');
      await client.flush();

      final batch = collector.batches.single;
      final pageView = collector.events.single;
      expect(batch['write_key'], 'wk_test');
      expect(pageView['event'], 'page_view');
      expect(pageView['user_id'], isNull);
      expect(pageView['anonymous_id'], client.anonymousId);
      expect(pageView['properties'], isEmpty);
      expect(pageView['context']['campaign'], {'rid': 'r1', 'utm_source': 'zap'});
    });

    test('a blank store key is ignored and the internal key field never leaves the device', () async {
      final client = startClient();
      client.setWriteKey('   ');
      client.setWriteKey('');
      client.track('search', {'query': 'pizza'});
      client.setWriteKey('  wk_centro  ');
      client.track('search', {'query': 'acai'});
      await client.flush();

      expect(collector.batches.map((b) => b['write_key']), ['wk_test', 'wk_centro']);
      expect(collector.batches.map((b) => b.keys.toSet()),
          everyElement({'write_key', 'sdk_name', 'sdk_version', 'sent_at', 'events'}));
      expect(
          collector.events.map((e) => e.keys.toSet()),
          everyElement(
              {'event_id', 'event', 'properties', 'anonymous_id', 'user_id', 'session_id', 'timestamp', 'context'}));
    });

    test('the raw phone and email only travel on identify, every other event carries the hash', () async {
      final client = startClient();
      client.identify(phone: '(17) 99999-8888', email: 'cliente@exemplo.com');
      client.track('search', {'query': 'pizza'});
      await pumpEventQueue();
      await client.flush();

      final otherEvents = collector.events.where((e) => e['event'] != 'identify');
      expect(otherEvents, isNotEmpty);
      for (final event in otherEvents) {
        expect(jsonEncode(event), isNot(contains('99999')));
        expect(jsonEncode(event), isNot(contains('cliente@')));
        expect(event['user_id'], 'rpd:tel:af426ec6c64d5584');
      }
    });
  });
}
