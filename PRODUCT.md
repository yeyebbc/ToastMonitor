# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

Native desktop applications for macOS and Windows. This does not imply mobile or web support; each platform keeps its native implementation and conventions.

## Users

People who use AI coding tools and want to see their usage, subscription quota, prepaid balances, and related costs. The product serves both the maintainer’s everyday personal use and other users of the public Windows fork; personal use is prioritized without excluding the wider user community. No team-billing or enterprise persona is established.

## Product Purpose

ToastMonitor collects usage information from supported AI coding tools and account services, then makes it easy to check current and historical usage. Its primary job is glanceable, unobtrusive monitoring—including today’s token total and quota/balance status—while the Dashboard and analysis provide supporting detail for investigation and comparison.

## Positioning

A native desktop monitor that combines local coding-tool usage with optional account quota and balance information, so a user can see both recorded activity and relevant plan status in one place. Do not present estimates, quota value, or plan balances as interchangeable with actual spend.

## Operating Context

Users may leave collection running in the background and check a compact menu-bar panel on macOS or the Explorer taskbar readout on Windows; they can open the app for dashboard analysis and settings. Local usage logs are the default source. Remote feeds and provider/account requests are configured or enabled by the user. Windows does not use the notification tray as its taskbar-readout substitute; when taskbar integration is unavailable, the ordinary app window remains available.

## Capabilities and Constraints

- The macOS SwiftUI app remains intact. The additive Windows front end uses SwiftCrossUI/WinUI and a small native Win32 Explorer taskbar host; parsers, accounting, and SQL remain in the shared `ToastMonitor` module in place, with platform behavior isolated in narrow OS adapters. Do not extract the shared core for Windows convenience; keep the port straightforward to synchronize with upstream macOS work.
- Native desktop behavior differs by operating system. Windows usage appears in the primary horizontal Explorer taskbar when integration is available; vertical and secondary taskbars and tray fallback are unsupported. macOS uses its menu bar. Do not imply mobile or browser versions.
- Background collection continues when the panel/window is hidden. Windows `--background` startup and background secondary launches do not show or activate a window. With taskbar integration available, closing a window or pressing Escape hides it while collection continues; Quit exits. The existing host-unavailable Usage fallback is an exception: closing Usage exits, and Escape does not hide it. Do not use unsolicited popups or steal focus, including while the user is gaming. Platform-specific lifecycle and integration limitations are documented in `docs/windows-port.md`.
- Local-first privacy is a durable default: logs, usage, project paths, and session metadata are stored locally. Remote feeds and quota services are contacted only when configured or enabled. Credentials belong in the platform’s secure credential store and must not be written in plaintext to logs or the database. Do not add analytics, undisclosed network activity, or data sharing. Preserve documented platform-specific update behavior and user controls: macOS checks for updates at launch by default, can disable checks in Settings, and installs only after confirmation; Windows updates are manual downloads.
- Keep accounting categories distinct: actual variable spend, estimated variable cost, subscription fixed cost, quota value consumed, and account balance are not interchangeable. Token meanings and data quality must remain explicit; unknown values are not zero, partial results are not complete, and stale data is marked stale. See `docs/data-semantics.md`.
- Supported sources, provider behavior, setup, and platform limits are described in `README.md` and `docs/windows-port.md`. Provider coverage and platform capabilities can differ; do not imply unsupported integrations or treat unverified behavior as established.

## Evidence on Hand

- `README.md` documents the product name ToastMonitor, existing menu-bar icon assets (`artifacts/menu-bar-icon.svg` and `artifacts/ToastMonitor-Icon/`), workflows, sources, privacy behavior, limitations, and panel, dashboard, and settings screenshots explicitly made with demo data. The screenshots are not evidence of real customer usage or provider results.
- `docs/windows-port.md` records Windows build/package and platform behavior, limitations, and a Windows 10 x64 acceptance account. Windows 11 placement, macOS build execution in this Windows environment, live provider authentication, suspend/resume behavior, and live timezone changes are explicitly unverified. Treat this as repository-documented validation, not a broader user study or market proof.
- `docs/data-semantics.md` is the normative reference for usage, money, data-quality, time, and event semantics.

## Product Principles

- Make the current usage and account state easy to check at a glance; keep deeper analysis available without making it the primary task.
- Respect the user’s attention: background collection and any remote activity follow documented behavior and user choice.
- Prefer local handling and secure credential storage; never introduce implicit data sharing.
- Preserve accounting meaning and communicate estimates, unknowns, partial coverage, and stale data honestly.
- Keep both desktop implementations native and the shared core maintainable across the public fork and its upstream macOS source.

## Accessibility & Inclusion

Preserve native platform accessibility behavior, including keyboard and system interaction conventions, readable content at supported display scaling/high-DPI settings, and accessible native controls. No formal accessibility conformance target or additional product-specific user requirements have been established.