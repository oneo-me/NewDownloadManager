# NewDownloadManager

A macOS native multi-threaded download manager built with Swift and SwiftUI, inspired by [NeatDownloadManager](https://www.neatdownloadmanager.com/).

## Features

- **Multi-threaded chunk download** - splits files into up to 8 chunks and downloads them in parallel via HTTP Range requests, maximizing bandwidth utilization
- **Pause / Resume** - pause downloads at any time and resume from the exact byte offset without re-downloading
- **Persistence** - download state is saved to disk automatically; incomplete downloads survive app restarts
- **Real-time progress** - live speed, ETA, and per-chunk progress visualization
- **Custom save path** - choose where to save each download

## Screenshots

![](screenshot-1.png)

## Requirements

- macOS 26.0+
- Xcode 26.0+

## Build

Open `NewDownloadManager.xcodeproj` in Xcode and run the target, or build from the command line:

```bash
xcodebuild -project NewDownloadManager.xcodeproj -scheme NewDownloadManager -configuration Release build
```

## How It Works

1. A HEAD request determines the file size and whether the server supports `Range` requests.
2. The file is split into 1–8 chunks (minimum 256 KB each). Each chunk is downloaded concurrently via its own `URLSession` data task with a `Range: bytes=start-end` header.
3. Progress, speed, and ETA are updated every 0.5 seconds and reflected in the UI in real time.
4. Once all chunks complete, they are merged sequentially into the final file using a 1 MB buffer for memory efficiency.
5. Temporary chunk files are cleaned up after a successful merge.

If the server does not support range requests, the file is downloaded as a single chunk.

## Roadmap

- [ ] Chrome extension for intercepting browser downloads
- [ ] Safari extension for intercepting browser downloads
- [ ] Settings (concurrent chunk count, default save path, etc.)

## Acknowledgements

This project is primarily built with the assistance of AI (Claude).

## License

MIT
