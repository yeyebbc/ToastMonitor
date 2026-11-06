---
target: Usage window, Dashboard and Settings - WinUI/Windows desktop critique
total_score: 23
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 2
target_identity: "file:C:\\Users\\Wallace\\repos\\ToastMonitor-Windows\\Windows\\Sources\\UI"
timestamp: 2026-11-05T03-38-03Z
slug: windows-sources-ui
---
Method: design review only (detector not applicable, native platform)

## Verdict

**These windows need targeted control and layout changes—not another cosmetic polish pass.** The previous pass improved Tokens emphasis, switches, and footer access, but left the underlying Windows interaction design largely unchanged.

The content is specific to ToastMonitor. The composition still resembles a developer utility: vertical stacks, command buttons used as tabs or settings, long credential forms, and weak boundaries between data scopes. **Keep the restrained appearance and SwiftCrossUI; correct the interaction model.**

I inspected the current source and a fresh native Release run, including all Dashboard and Settings sections, at 225% scaling. Testing used an isolated Win32 desktop without activating your running app. The Explorer error in those captures is expected on that desktop—not evidence that your normal taskbar integration is failing.

## Design health: 23/40

Subjective usability scores, not a Microsoft compliance or accessibility certification.

| Heuristic | Score / 4 | Main finding |
|---|---:|---|
| Visibility of system status | 3 | Updates and failures are visible, but status competes with content |
| Match with the real world | 2 | Clear accounting distinctions; implementation terminology leaks into UI |
| User control and freedom | 3 | Reachable exits and guarded destructive actions |
| Consistency and standards | 2 | Navigation, selection, and commands share the same button treatment |
| Error prevention | 3 | Backup safeguards exist; raw dates and paths invite mistakes |
| Recognition rather than recall | 2 | Filter scope and populated form fields require interpretation |
| Flexibility and efficiency | 2 | Useful filters and paging; excessive typing and scrolling |
| Aesthetic and minimalist design | 2 | Restrained, but insufficient information prioritization |
| Error recovery | 2 | Optional setup and genuine failure look too similar |
| Help and documentation | 2 | Explanations exist, but contextual destinations are weak |
| **Total** | **23/40** | **Significant targeted improvements needed** |

## What should stay

- **Tokens-first emphasis and distinct accounting categories.** Do not collapse estimated cost, actual spend, and subscription allocation into an ambiguous “Cost.”
- **The pinned Usage footer.** Navigation and Quit remain reachable while scrolling.
- **Native switches and data safeguards.** Retain the five correctly named switches, mandatory safety backups, and destructive-action confirmation.

## Priority changes

### 1. [P1] Replace buttons masquerading as navigation and selection

**Across all three windows.**

Dashboard’s five destinations, Settings’ six categories, Usage periods, billing mode, week start, and source mode are ordinary buttons. Selection is communicated primarily by bold text. This makes “navigate,” “select a value,” and “execute an action” look equivalent.

Native UI Automation also exposes unnamed Button peers with named Text children; the analysis ComboBoxes have blank accessible names. This does **not** establish a Narrator failure, but it shows that native-widget rendering alone has not supplied a complete accessibility contract.

**Replace:**
- Settings category buttons → **left/adaptive `NavigationView`**.
- Dashboard destination buttons → **top `NavigationView`**; its five destinations fit that pattern.
- Small mutually exclusive settings → **`RadioButtons`**, or a labeled **`ComboBox`** when compactness matters.
- Usage period choices → a genuine **single-selection control**, with an exposed selected state.

Keep ordinary buttons for Refresh, Save, Export, and other commands. Verify names and selection state on the actual interactive peers.

Microsoft’s [NavigationView](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/navigationview) and [RadioButtons](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/radio-button) guidance supports these choices. They are recommendations, not rules that every Windows app must use a sidebar.

Evidence: `WindowsDashboardView.swift:15–20`, `WindowsSettingsView.swift:11–16,47–69,89–94,137–144`, `WindowsUsageView.swift:63–75`.

*Suggested command: `/impeccable shape`.*

### 2. [P1] Give Dashboard filters explicit ownership

Usage analysis shows **Today** and **History days: 30** together above Models and Daily history. They do not control the same data:

- Models uses the selected usage period.
- History and Performance use the independent history-day range.

A user can reasonably assume either date selector applies to everything underneath. Correct numbers can therefore produce an incorrect comparison.

**Change the grouping—not the accounting:**
- Put the model-period selector beside **Models**, with its effective range visible.
- Put the history-range selector beside **Daily history**.
- Keep Tool shared only if that cross-section scope is explicit.
- Place **Export models…** with the model results, rather than leading with a full-width destination-path form.

Also tighten the analytical layout: bounded summary groups and aligned numeric columns will compare better than labels and values stretched across the entire window. Overview should summarize and offer drill-down, not serially reproduce every analysis section.

Evidence: `WindowsDashboardView.swift:28–38,109–118`; `WindowsModel.swift:55–64,138–151`.

*Suggested command: `/impeccable layout`.*

### 3. [P2] Make Usage a monitoring panel, not a compressed accounting report

The current ordering puts five secondary metrics and explanatory accounting copy before tool breakdown and quota/balance status. With connected providers, the information most relevant to “can I keep working?” is pushed further down.

**Restructure:**
1. Selected period and token total.
2. Calls and relevant connected quota/balance status.
3. Expandable **Cost details** and **By tool** information.

Preserve every financial distinction inside the detail view. The improvement is progressive disclosure, not removing data.

An unused optional provider should not make a local-only installation look broken. Show neutral setup guidance **only when reliable configuration state proves it is unconfigured**. Do not classify errors by string matching or hide credential-store/provider failures.

For genuine app-wide failures, use a concise, severity-appropriate [InfoBar](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/infobar), with technical details available separately. Field-specific validation belongs beside the field—not in the shared status block above the page.

Evidence: `WindowsUsageView.swift:45–58,79–115,143–149`.

*Suggested command: `/impeccable distill`.*

### 4. [P2] Replace developer-style form inputs with native desktop tasks

Settings currently asks users to type complete export paths and formatted dates. The subscription form displays populated `USD` and a date without persistent visible labels; the provider dropdown starts blank. The rendered “New subscription” command is truncated to “New…”.

**Replace or refine:**
- Export-path fields → **native Save As dialogs**, retaining existing destination validation and privacy safeguards.
- Date strings → **`DatePicker`/`CalendarDatePicker`**, with persistent labels and an explicit “No end date” choice.
- Price → **`NumberBox`** or constrained numeric input.
- Blank provider option → a meaningful **“Not linked”** option, if that accurately represents its semantics.
- Wandering controls → bounded settings rows with a consistent action column.
- Long Accounts page → provider-level groups/expanders showing connection state before credential-editing fields.

Keep the existing secure fields and switches. Distinguish immediately applied preferences from explicit credential submission.

Microsoft’s [settings guidance](https://learn.microsoft.com/en-us/windows/apps/design/app-settings/guidelines-for-app-settings), [text-field guidance](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/text-box), and [Common Item Dialog](https://learn.microsoft.com/en-us/windows/win32/shell/common-file-dialog) support this direction. **Adding Windows Community Toolkit solely for SettingsCard styling is unnecessary.**

Evidence: `WindowsSettingsView.swift:148–201,239–255,303–304`; `WindowsDashboardView.swift:109–111`.

*Suggested command: `/impeccable harden`.*

### 5. [P2] Make instructions lead to the promised destination

Two concrete inconsistencies:
- **Edit subscriptions** opens generic Settings; it does not select Subscriptions.
- General says closing a window keeps collection running, but closing Usage exits when taskbar integration is unavailable.

**Polish behavior and copy:**
- Route contextual actions directly to the relevant Settings section.
- Give source/account empty states actionable setup links.
- Correct the lifecycle explanation without changing the established lifecycle.
- Add real version/build information and Help/Report issue links to About, using actual metadata and destinations.

Evidence: `WindowsDashboardView.swift:163`, `WindowsSettingsView.swift:44,330–339`, `WindowsWindowController.swift:54–59,209–214`.

*Suggested command: `/impeccable clarify`.*

## Cognitive load and user impact

**Moderate overall; locally high in Accounts and Usage analysis.** The main failures are progressive disclosure, filter grouping, and remembering what controls affect—not simply the number of visible options.

- **Personal glance-monitor user:** token emphasis helps; secondary accounting and optional setup compete with quota/headroom checks.
- **First-time public-fork user:** “not configured,” blank provider choices, and diagnostics expressed as rows/milliseconds make setup harder to interpret.
- **Analytical or accessibility-dependent user:** ambiguous date scopes and incomplete native name/selection semantics reduce confidence. Keyboard traversal and screen-reader behavior still require direct testing.

The journey starts as a calm numeric utility, becomes uncertain during analysis and setup, then regains some confidence through the Data screen’s explicit backup safeguards.

## Smaller refinements

- Format history dates for people instead of displaying `20261102`.
- Use consistent tool display names rather than mixing “Oh My Pi” and raw identifiers such as `omp`.
- Replace implementation explanations such as “excluded by the shared database query” with user-facing measurement eligibility.
- Review fixed-width bars and non-wrapping value rows during a dedicated resize/localization pass; those are source-level risks, not failures reproduced here.

**No P0 blocker was found.** Dark theme, keyboard traversal, screen readers, resizing, and normal-desktop taskbar integration were not tested in this critique.

The maintainable direction is small Windows-only native-control adapters through SwiftCrossUI’s public API. No shared-engine extraction, macOS changes, framework replacement, decorative animation, or Mica work is justified by these findings.
