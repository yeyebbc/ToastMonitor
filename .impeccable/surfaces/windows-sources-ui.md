---
version: 1
slug: "windows-sources-ui"
primary_target: "Windows/Sources/UI"
related_targets: ["Windows/Sources/UI/WindowsUsageView.swift","Windows/Sources/UI/WindowsDashboardView.swift","Windows/Sources/UI/WindowsSettingsView.swift"]
---

# Windows native monitoring surfaces
Visitor mode: Operate
Scope: Windows/Sources/UI; Usage, Dashboard, Settings.
Audience/job: personal and public users checking usage and configuring local monitoring. Preserve upstream-sync-friendly Windows-only changes.
User commitment: compact Usage A; genuine TOP TABS, no sidebar. Dashboard exact order Overview / Analysis / Performance / Plans / Sessions. Settings exact order General / Appearance / Sources / Accounts / Data / Updates. Subscriptions belongs under Accounts; build/help/manual updates under Updates. The three user-supplied macOS screenshots (clipboard_2026-11-05_11-3, 11-2, 11-47) are authoritative grouping/density references, translated into native Windows widgets.
Additional authoritative references: SCR-20261105-kskd/ksqp/kstv/ksvb/kswi pin grouped settings rows, real compact source radios, initially closed provider disclosures with connection status, subscriptions below providers, guarded data tasks, and truthful Updates/build actions. Native top-only NavigationView is permitted; no hidden binding proxy or unsupported projection. Alerts threshold is disabled with explanation when alerts are off. No macOS-only Dock, font, Safari, or automatic updater controls.

## Direction contract
THESIS: Usage preserves its accepted native popup composition; Dashboard preserves its accepted top tabs. Settings reflows the existing actions into the six SCR-20261106-bcnu/bcqe/bcsk/bcws/bcxn/bcyd reference layouts with native WinUI controls.
OWN-WORLD: Native Windows system typography, themed card surfaces and controls, accessible selection/focus, semantic status and colored data series; never imitation macOS window chrome.
STORY: In Usage, choose one of four periods, read dominant tokens and truthful Spent/Value, scan always-visible tool proportions, then separate Quota, Balance and Activity cards.
FIRST VIEWPORT: At approximately 450×680 DIP, Usage keeps its accepted summary, Quota, Balance, Activity and footer. Settings uses a centered icon-above-label page strip, selected page title and compact grouped rows in a bounded 620-DIP content column; only the form body scrolls. Dashboard remains unchanged.
FORM: User-pinned clipboard_2026-11-05_11-47.png is the popup composition authority, superseding the previous disclosure-first Usage. Native Operate refinement; no concept tournament or DESIGN.md.
FINISH: Actual native captures and UI Automation evidence, independent finish review with its scoped verdict, and updated docs/windows-port.md. This existing-world refinement does not create DESIGN.md.

Settings implementation: reuse WindowsModel actions, provider clients, credential-state reporting, subscription editor and maintenance guards in place. Small Settings-only row/group and native navigation primitives handle layout; no form schema, service layer or shared-core rewrite. Preserve inline validation, immediate preferences, contextual account navigation, secure blank secret fields, owner-bound export, safety backups and CLEAR/RECOVER. Windows mapping omits unsupported Dock, popup-close, taskbar-font/customization and automatic updater controls rather than displaying fake actions. The production footprint is WindowsSettingsView.swift plus the narrowly scoped generic WindowsRadioChoice adapter in WindowsNativeControls.swift: a native horizontal StackPanel with named native RadioButtons binds Checked events, preserving independent selection through form scrolling and resizing. Dashboard navigation/layout, its WindowsTopTabs, the popup, WindowsModel, shared core and macOS source stay unchanged.

Accepted evidence: immutable Settings Debug packet 4 has independent scoped CLEAR/SHIP reviews. SETTINGS-FINAL-GATE-1 subsequently passed once with official Swift 6.1.3: Debug Jobs 2 reported 389 XCTest cases, 2 optional skips, 0 failures and 0 Swift Testing cases; Release Jobs 1 packaged the new native-settings-final ZIP. Canonical extracted CLI commands all exited 0, 61 package/pristine files match, and 22 native import images plus adjacent pinned bootstrap resources were checked. Detailed hashes/results are in docs/windows-port.md and the existing gate artifacts. Native visual/interaction proof remains the isolated production-object Debug harness with three explicitly confined parser-input objects; Release proof is canonical CLI/package only. Historical Foundation-home isolation limits remain qualified; no physical-keyboard/authenticated canonical-GUI/dark/Win11 claim.

Constraints: preserve all money distinctions, unknown/partial/stale/credential-error truth, shared SQL/parsers/accounting and lifecycle. Activity uses existing UsageQueryService data and macOS calendar/trend semantics, not new SQL or a Dashboard redesign. Existing-world refinement does not create DESIGN.md. Native GUI/UIA proof and windows-port docs required. No unresolved decisions.
