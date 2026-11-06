import Foundation
import SwiftCrossUI
import WinUI
import WinUIBackend

/// Static top-only application navigation; no sidebar or document-tab actions.
struct WindowsTopTabs: WinUIElementRepresentable {
    let labels: [String]
    let selection: SwiftCrossUI.Binding<Int>
    let name: String
    @MainActor final class Coordinator {
        var selection: SwiftCrossUI.Binding<Int>
        var items: [WinUI.NavigationViewItem] = []
        var removeHandler: (() -> Void)?
        var updating = false
        init(_ selection: SwiftCrossUI.Binding<Int>) { self.selection = selection }
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection) }
    func makeWinUIElement(context: Context) -> WinUI.NavigationView {
        let control = WinUI.NavigationView()
        control.paneDisplayMode = .top
        control.isPaneToggleButtonVisible = false
        control.isBackButtonVisible = .collapsed
        control.isSettingsVisible = false
        control.isTitleBarAutoPaddingEnabled = false
        for label in labels {
            let item = WinUI.NavigationViewItem()
            item.content = label
            WinUI.AutomationProperties.setName(item, label)
            context.coordinator.items.append(item)
            control.menuItems.append(item)
        }
        WinUI.AutomationProperties.setName(control, name)
        let subscription = control.selectionChanged.addHandler { [weak coordinator = context.coordinator] _, arguments in
            guard let coordinator, !coordinator.updating,
                  let item = arguments?.selectedItemContainer,
                  let index = coordinator.items.firstIndex(where: { $0 == item }),
                  coordinator.selection.wrappedValue != index else { return }
            coordinator.selection.wrappedValue = index
        }
        context.coordinator.removeHandler = { subscription.dispose() }
        return control
    }
    func updateWinUIElement(_ control: WinUI.NavigationView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = selection
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
        control.isEnabled = context.environment.isEnabled
        let index = selection.wrappedValue
        if coordinator.items.indices.contains(index), !coordinator.items[index].isSelected {
            coordinator.updating = true
            control.selectedItem = coordinator.items[index]
            coordinator.updating = false
        }
    }
    static func dismantleWinUIElement(_ control: WinUI.NavigationView, coordinator: Coordinator) {
        coordinator.removeHandler?()
        coordinator.removeHandler = nil
    }
}

/// Named, keyboard-operable native single selection for compact filters and forms.
struct WindowsChoice: WinUIElementRepresentable {
    let label: String
    let options: [String]
    let selection: SwiftCrossUI.Binding<Int>
    @MainActor final class Coordinator {
        var binding: SwiftCrossUI.Binding<Int>
        var updating = false
        var removeHandler: (() -> Void)?
        var labels: [String] = []
        let measurement = WinUI.TextBlock()
        init(_ binding: SwiftCrossUI.Binding<Int>) { self.binding = binding }
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection) }
    func makeWinUIElement(context: Context) -> WinUI.ComboBox {
        let control = WinUI.ComboBox()
        for option in options { control.items.append(option) }
        WinUI.AutomationProperties.setName(control, label)
        let subscription = control.selectionChanged.addHandler { [weak coordinator = context.coordinator, weak control] _, _ in
            guard let coordinator, let control, !coordinator.updating, control.selectedIndex >= 0,
                  coordinator.binding.wrappedValue != Int(control.selectedIndex) else { return }
            coordinator.binding.wrappedValue = Int(control.selectedIndex)
        }
        context.coordinator.removeHandler = { subscription.dispose() }
        return control
    }
    func updateWinUIElement(_ control: WinUI.ComboBox, context: Context) {
        context.coordinator.binding = selection
        control.isEnabled = context.environment.isEnabled
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
        if control.selectedIndex != Int32(selection.wrappedValue) {
            context.coordinator.updating = true
            control.selectedIndex = Int32(selection.wrappedValue)
            context.coordinator.updating = false
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.ComboBox, context: Context) -> ViewSize {
        let index = max(0, min(selection.wrappedValue, options.count - 1))
        context.coordinator.measurement.text = options[index]
        let text = WinUIBackend.naturalSize(of: context.coordinator.measurement)
        return ViewSize(Double(text.x + 50), Double(max(text.y + 12, 32)))
    }
    static func dismantleWinUIElement(_ control: WinUI.ComboBox, coordinator: Coordinator) { coordinator.removeHandler?() }
}

struct WindowsDisclosure<Content: View>: View {
    let title: String
    @State private var expanded = false
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WindowsDisclosureToggle(title: title, expanded: $expanded)
            if expanded { content }
        }
    }
}

struct WindowsRadioChoice: WinUIElementRepresentable {
    let label: String
    let options: [String]
    let selection: SwiftCrossUI.Binding<Int>
    typealias Coordinator = WindowsChoice.Coordinator
    func makeCoordinator() -> Coordinator { Coordinator(selection) }
    func makeWinUIElement(context: Context) -> WinUI.StackPanel {
        let control = WinUI.StackPanel()
        control.orientation = .horizontal
        control.spacing = 8
        WinUI.AutomationProperties.setName(control, label)
        // Named native buttons bind Checked events without the composite's focus-driven selection.
        let group = UUID().uuidString
        var removals: [() -> Void] = []
        for (index, option) in options.enumerated() {
            let item = WinUI.RadioButton()
            item.minWidth = 0
            item.content = option
            item.groupName = group
            item.isChecked = index == selection.wrappedValue
            WinUI.AutomationProperties.setName(item, option)
            control.children.append(item)
            let subscription = item.checked.addHandler { [weak coordinator = context.coordinator] _, _ in
                guard let coordinator, !coordinator.updating, coordinator.binding.wrappedValue != index else { return }
                coordinator.binding.wrappedValue = index
            }
            removals.append { subscription.dispose() }
        }
        context.coordinator.labels = options
        context.coordinator.removeHandler = { for remove in removals { remove() } }
        return control
    }
    func updateWinUIElement(_ control: WinUI.StackPanel, context: Context) {
        context.coordinator.binding = selection
        if context.coordinator.labels != options {
            for index in options.indices {
                if let item = control.children.getAt(UInt32(index)) as? WinUI.RadioButton {
                    item.content = options[index]
                    WinUI.AutomationProperties.setName(item, options[index])
                }
            }
            context.coordinator.labels = options
        }
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
        context.coordinator.updating = true
        for index in options.indices {
            if let item = control.children.getAt(UInt32(index)) as? WinUI.RadioButton {
                item.isEnabled = context.environment.isEnabled
                if item.isChecked != (index == selection.wrappedValue) {
                    item.isChecked = index == selection.wrappedValue
                }
            }
        }
        context.coordinator.updating = false
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.StackPanel, context: Context) -> ViewSize {
        var maximum = 0
        for option in options {
            context.coordinator.measurement.text = option
            maximum = max(maximum, WinUIBackend.naturalSize(of: context.coordinator.measurement).x)
        }
        let width = Double((maximum + 32) * options.count + max(0, options.count - 1) * 8)
        return ViewSize(width, 36)
    }
    static func dismantleWinUIElement(_ control: WinUI.StackPanel, coordinator: Coordinator) { coordinator.removeHandler?() }
}

/// Decimal-only editing, with final finite/nonnegative validation at submission.
struct WindowsPriceField: WinUIElementRepresentable {
    let text: SwiftCrossUI.Binding<String>
    @MainActor final class Coordinator {
        var binding: SwiftCrossUI.Binding<String>
        var updating = false
        var removeHandlers: [() -> Void] = []
        init(_ binding: SwiftCrossUI.Binding<String>) { self.binding = binding }
    }
    func makeCoordinator() -> Coordinator { Coordinator(text) }
    func makeWinUIElement(context: Context) -> WinUI.TextBox {
        let control = WinUI.TextBox()
        WinUI.AutomationProperties.setName(control, "Subscription price")
        let filter = control.beforeTextChanging.addHandler { _, arguments in
            guard let arguments else { return }
            let value = arguments.newText
            arguments.cancel = !value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 46 }
                || value.utf8.filter { $0 == 46 }.count > 1
        }
        let change = control.textChanged.addHandler { [weak coordinator = context.coordinator, weak control] _, _ in
            guard let coordinator, let control, !coordinator.updating, coordinator.binding.wrappedValue != control.text else { return }
            coordinator.binding.wrappedValue = control.text
        }
        context.coordinator.removeHandlers = [{ filter.dispose() }, { change.dispose() }]
        return control
    }
    func updateWinUIElement(_ control: WinUI.TextBox, context: Context) {
        context.coordinator.binding = text
        control.isEnabled = context.environment.isEnabled
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
        if control.text != text.wrappedValue {
            context.coordinator.updating = true
            control.text = text.wrappedValue
            context.coordinator.updating = false
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.TextBox, context: Context) -> ViewSize {
        ViewSize(240, 32)
    }
    static func dismantleWinUIElement(_ control: WinUI.TextBox, coordinator: Coordinator) {
        for remove in coordinator.removeHandlers { remove() }
    }
}

/// Native command peer with an explicit name, unlike the stock text-child button.
struct WindowsAction: WinUIElementRepresentable {
    let label: String
    let action: () -> Void
    init(_ label: String, action: @escaping () -> Void) { self.label = label; self.action = action }
    @MainActor final class Coordinator {
        var action: () -> Void
        var removeHandler: (() -> Void)?
        let text = WinUI.TextBlock()
        var label: String?
        init(_ action: @escaping () -> Void) { self.action = action }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeWinUIElement(context: Context) -> WinUI.Button {
        let control = WinUI.Button()
        control.content = context.coordinator.text
        let subscription = control.click.addHandler { [weak coordinator = context.coordinator] _, _ in coordinator?.action() }
        context.coordinator.removeHandler = { subscription.dispose() }
        return control
    }
    func updateWinUIElement(_ control: WinUI.Button, context: Context) {
        context.coordinator.action = action
        if context.coordinator.label != label {
            context.coordinator.text.text = label
            WinUI.AutomationProperties.setName(control, label)
            context.coordinator.label = label
        }
        control.isEnabled = context.environment.isEnabled
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Button, context: Context) -> ViewSize {
        let text = WinUIBackend.naturalSize(of: context.coordinator.text)
        return ViewSize(Double(text.x + 26), Double(max(text.y + 14, 32)))
    }
    static func dismantleWinUIElement(_ control: WinUI.Button, coordinator: Coordinator) { coordinator.removeHandler?() }
}

/// Measures the rendered native label itself, including its semibold glyphs.
struct WindowsSectionHeading: WinUIElementRepresentable {
    let label: String
    init(_ label: String) { self.label = label }
    func makeWinUIElement(context: Context) -> WinUI.TextBlock {
        let text = WinUI.TextBlock()
        text.fontSize = 14
        text.fontWeight.weight = 600
        text.textWrapping = .noWrap
        text.textTrimming = .none
        return text
    }
    func updateWinUIElement(_ text: WinUI.TextBlock, context: Context) {
        if text.text != label { text.text = label }
        text.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.TextBlock, context: Context) -> ViewSize {
        let size = WinUIBackend.naturalSize(of: winUIElement)
        return ViewSize(Double(size.x + 2), Double(size.y + 2))
    }
}

struct WindowsDisclosureToggle: WinUIElementRepresentable {
    let title: String
    let expanded: SwiftCrossUI.Binding<Bool>
    @MainActor final class Coordinator {
        var binding: SwiftCrossUI.Binding<Bool>
        var removeHandler: (() -> Void)?
        let text = WinUI.TextBlock()
        var caption: String?
        init(_ binding: SwiftCrossUI.Binding<Bool>) { self.binding = binding }
    }
    func makeCoordinator() -> Coordinator { Coordinator(expanded) }
    func makeWinUIElement(context: Context) -> WinUI.ToggleButton {
        let control = WinUI.ToggleButton()
        control.content = context.coordinator.text
        let subscription = control.click.addHandler { [weak coordinator = context.coordinator, weak control] _, _ in
            guard let coordinator, let control, coordinator.binding.wrappedValue != (control.isChecked == true) else { return }
            coordinator.binding.wrappedValue = control.isChecked == true
        }
        context.coordinator.removeHandler = { subscription.dispose() }
        return control
    }
    func updateWinUIElement(_ control: WinUI.ToggleButton, context: Context) {
        context.coordinator.binding = expanded
        let caption = "\(expanded.wrappedValue ? "Hide" : "Show") \(title)"
        if context.coordinator.caption != caption {
            context.coordinator.text.text = caption
            WinUI.AutomationProperties.setName(control, "\(title), \(expanded.wrappedValue ? "expanded" : "collapsed")")
            context.coordinator.caption = caption
        }
        if control.isChecked != expanded.wrappedValue { control.isChecked = expanded.wrappedValue }
        control.isEnabled = context.environment.isEnabled
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.ToggleButton, context: Context) -> ViewSize {
        let text = WinUIBackend.naturalSize(of: context.coordinator.text)
        return ViewSize(Double(text.x + 26), Double(max(text.y + 14, 32)))
    }
    static func dismantleWinUIElement(_ control: WinUI.ToggleButton, coordinator: Coordinator) { coordinator.removeHandler?() }
}
