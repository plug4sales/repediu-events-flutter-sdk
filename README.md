# repediu_events

Repediu events SDK for Flutter apps on Android and iOS. Sends screens, cart, orders and campaigns to the store's
Repediu project, with the same identity and event contract as the Repediu JavaScript tracker.

## Install

```sh
flutter pub add repediu_events
```

Requires Dart 3 and Flutter 3.13 or newer.

On Android, release builds need the internet permission in `android/app/src/main/AndroidManifest.xml` (the Flutter
template only adds it to the debug manifest):

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

## Getting started

```dart
import 'package:repediu_events/repediu_events.dart';

Future<void> main() async {
  await Repediu.init(writeKey: 'STORE_WRITE_KEY');
  runApp(MaterialApp(
    navigatorObservers: [RepediuNavigatorObserver()],
    routes: {...},
  ));
}
```

The write key is in the store's Repediu panel. If the app only knows it later, for example after loading the store from
its own backend, call `init` then: up to 100 calls made before it are kept and sent once it completes.

`RepediuNavigatorObserver` records a `page_view` for every named route and a `page_leave` with the time spent on it.
With another router, call `Repediu.screen('/menu')` when each screen opens. `page_leave` is also sent when the app goes
to the background.

`debug: kDebugMode` in `init` prints every queued event and every sent batch in debug builds. Keep it off in release:
the log includes customer data.

## Environments

`init` sends to production by default. Point `endpoint` to homologation while testing the integration:

| Environment | `endpoint` |
| --- | --- |
| Production (default) | `https://tracker.repediu.com.br/collect` |
| Homologation | `https://tracker-hml.repediu.com.br/collect` |

Each environment has its own write keys, and Repediu provides the homologation one. A key sent to the other
environment is accepted and dropped, so nothing shows up in the panel. Homologation may be offline outside business
hours (Brasília time); events stay queued in the app and are sent later.

Choose both at build time instead of hardcoding them:

```dart
await Repediu.init(
  writeKey: const String.fromEnvironment('REPEDIU_WRITE_KEY'),
  endpoint: const String.fromEnvironment(
    'REPEDIU_ENDPOINT',
    defaultValue: 'https://tracker.repediu.com.br/collect',
  ),
);
```

```sh
flutter run \
  --dart-define=REPEDIU_ENDPOINT=https://tracker-hml.repediu.com.br/collect \
  --dart-define=REPEDIU_WRITE_KEY=HOMOLOGATION_WRITE_KEY
```

## Customer

```dart
Repediu.identify(phone: '5511999998888', email: 'customer@example.com', name: 'Maria');
Repediu.reset();
```

Call `identify` on login or whenever the customer provides a phone or an email, and `reset` on logout.

## Orders

```dart
Repediu.order.viewCategory('Pizzas');
Repediu.order.viewItem('pepperoni-pizza', 'Pepperoni Pizza', category: 'Pizzas', price: 64.9);
Repediu.order.addToCart('pepperoni-pizza', 'Pepperoni Pizza', price: 64.9, quantity: 2);
Repediu.order.cartSync([EcommerceItem(itemId: 'pepperoni-pizza', itemName: 'Pepperoni Pizza', price: 64.9, quantity: 2)]);
Repediu.order.beginCheckout(value: 129.8, itemCount: 2, deliveryType: DeliveryType.delivery);
Repediu.order.placeOrder(
  'ORDER-123',
  129.8,
  paymentMethod: 'pix',
  deliveryType: DeliveryType.delivery,
  items: [EcommerceItem(itemId: 'pepperoni-pizza', itemName: 'Pepperoni Pizza', price: 64.9, quantity: 2)],
);
Repediu.order.cancelOrder('ORDER-123', reason: 'customer gave up');
Repediu.search('pepperoni');
```

Send `cartSync` with the whole cart on every change, including when it becomes empty. Send `placeOrder` once, after the
store confirms the order, with the order id the store uses, the delivery type and the ordered items.

## Several stores in one app

Each store has its own write key. Start with the default store and switch when the customer picks another one:

```dart
Repediu.setWriteKey(store.repediuWriteKey);
```

Every event goes to the store that was active when it happened, including events still waiting in the queue.

## Campaigns

Links that open the app through the Flutter router are read automatically: `rid` and `utm_*` are kept for the session
and sent with all of its events. If the app handles links itself, or calls `init` after `runApp`, pass each link on:

```dart
Repediu.setCampaignFromUri(uri);
```

## Banners and promotions

Report a banner or promotion when it appears on screen and when it is tapped. A view counts once per screen;
every tap counts. `url` is optional: where the promotion leads.

```dart
Repediu.promotionView('cashback-15', 'Cashback 15%', url: 'app:/promo/cashback');
Repediu.promotionClick('cashback-15', 'Cashback 15%', url: 'app:/promo/cashback');
```

## Privacy

```dart
Repediu.optOut();
Repediu.optIn();
```

`optOut` erases the ids and the queue stored on the device and stops all sending, also after the app restarts.

What the SDK sends to Repediu, for the App Store privacy details and the Google Play data safety form:

- a random install id and session id, created by the SDK (no advertising id, no device id);
- the customer id given to `identify`, or a hash of the phone or e-mail; the phone, e-mail and name themselves only on
  the `identify` event;
- screen names, searches, viewed and carted items, and orders (id, value, items, payment method, delivery type);
- campaign parameters of the link that opened the app (`rid`, `utm_*`), with every event of that session;
- the platform (Android or iOS) and the SDK version.

No location, contacts or other app data is read.

## Delivery

Events go out in batches every 3 seconds or every 20 events. The queue is saved on the device every 3 seconds and when
the app leaves the foreground, so it survives the app being closed. Without network, or with Repediu unreachable, the
batch is kept and retried with a growing interval of up to 5 minutes. The queue holds at most 1,000 events. No SDK
error ever reaches the app.

Flutter web is not supported: use the Repediu JavaScript tracker.
