## 0.1.1

- The `identify` event, the only one carrying the raw phone, e-mail and name, is no longer written to the offline queue on disk, and is flushed as soon as it is tracked.
- `init` refuses a non-`https` endpoint (except `localhost`/`10.0.2.2` for local development).
- `optOut` now also clears the properties set with `register`.
- CI hardening: least-privilege `permissions`, checkouts without persisted credentials, the publish step isolated in its own job with `id-token` and a pinned `pana`.

## 0.1.0

- First release: `init`, `screen` and `RepediuNavigatorObserver`, `page_leave` with time on screen, `identify`, order events in `Repediu.order`, deep link campaigns, banner and promotion events, `setWriteKey` for multi-store apps, offline queue with retry, and opt-out.
- Calls made before `init` completes are kept and sent once it does.
