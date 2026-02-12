# CLAUDE.md

This file is for AI to understand the project context. Keep it focused on project-relevant information only — not a changelog or dump of miscellaneous notes. Only record things that are genuinely useful for understanding the project.

## Rules

- When making significant architectural or structural changes, update this file accordingly if the changes affect the information documented here.
- When committing code written by AI, prefix the commit message with `[CLAUDE]`. Do not add this prefix for commits where the user wrote the code themselves.
- This file exists to help AI understand the project. Do not use it to log change history or store unrelated information.

## Project Overview

NewDownloadManager is a macOS native multi-threaded download manager built with Swift and SwiftUI, inspired by NeatDownloadManager. It splits files into multiple chunks and downloads them in parallel via HTTP Range requests.

## Tech Stack

- Swift / SwiftUI
- URLSession (data tasks with delegate for chunk downloading)
- Async/await + NSLock for concurrency
- No third-party dependencies

## Architecture

```
Models/         Data structures (DownloadItem, DownloadStatus, ChunkInfo)
Services/       Business logic (DownloadManager, DownloadEngine, ChunkDownloader, FileMerger, PersistenceService)
Views/          SwiftUI views (NavigationSplitView layout with sidebar list + detail panel)
Utilities/      Formatting helpers (bytes, speed, ETA)
```

- **DownloadManager** (`@Observable`) is the central state coordinator, injected via `@Environment`.
- **DownloadEngine** orchestrates chunk creation and parallel downloading for a single task.
- **ChunkDownloader** is a `URLSessionDataDelegate` that handles a single chunk's HTTP Range request and writes to a temp file.
- **FileMerger** sequentially merges completed chunk files into the final output file.
- **PersistenceService** saves/loads download state as JSON to `~/Library/Application Support/NewDownloadManager/`.

## Key Design Decisions

- Maximum 8 concurrent chunks per download, minimum chunk size 256 KB.
- Falls back to single-chunk download if the server does not support HTTP Range.
- Speed/ETA updated via a 0.5-second timer.
- Incomplete downloads are reset to "paused" on app startup.
- File merging uses a 1 MB buffer to keep memory usage low.

## Build

```bash
xcodebuild -project NewDownloadManager.xcodeproj -scheme NewDownloadManager -configuration Release build
```

## Roadmap

- Chrome extension for intercepting browser downloads
- Safari extension for intercepting browser downloads
- Settings functionality (concurrent chunk count, default save path, etc.)
