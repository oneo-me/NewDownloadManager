# NewDownloadManager Chrome Extension

## Features

- Intercept browser download requests.
- Global intercept switch + per-site intercept switch in popup.
- Action icon state:
  - Green: intercept enabled.
  - Yellow: current site intercept disabled.
  - Red: global intercept disabled.
- Forward intercepted downloads directly to NewDownloadManager via local HTTP.

## Development

```bash
pnpm install
pnpm dev
```

## Integration with macOS App

1. Run `NewDownloadManager` app first.
2. In app toolbar, toggle `Chrome拦截` on/off to control whether Chrome downloads are taken over.
3. Load extension in Chrome (`chrome://extensions` -> Developer mode -> Load unpacked).

When the app is running, extension sends requests to:

```text
GET  http://127.0.0.1:48652/interception/status
POST http://127.0.0.1:48652/downloads/intercepted
```

Behavior:
- If app is unreachable: extension blocks Chrome download and shows failure notification.
- If app reachable and `Chrome拦截` is off: extension allows Chrome default download.
- If app reachable and `Chrome拦截` is on: extension forwards to app and blocks Chrome download.
