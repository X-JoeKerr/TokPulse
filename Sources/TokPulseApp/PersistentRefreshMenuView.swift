import AppKit

/// A CodexBar-style persistent menu row: native-looking highlight, SF Symbol icon,
/// and a right-aligned shortcut label. Clicking it runs `onClick` without closing the menu.
@MainActor
final class PersistentRefreshMenuView: NSView {
    private enum Metrics {
        static let rowHeight: CGFloat = 24
        static let selectionHorizontalInset: CGFloat = 5
        static let selectionCornerRadius: CGFloat = 7
        static let leadingPadding: CGFloat = 15
        static let trailingPadding: CGFloat = 8
        static let iconWidth: CGFloat = 16
        static let iconSymbolPointSize: CGFloat = 16
        static let iconTitleSpacing: CGFloat = 4.5
        static let shortcutFontSize: CGFloat = 13
        static let shortcutXOffset: CGFloat = -9.5
        static let titleShortcutGap: CGFloat = 8
    }

    private let selectionView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private let shortcutField: NSTextField
    private var isRowHighlighted = false
    private let onClick: () -> Void

    override var allowsVibrancy: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.rowHeight)
    }

    init(title: String, systemImageName: String, shortcutText: String, onClick: @escaping () -> Void) {
        self.titleField = NSTextField(labelWithString: title)
        self.shortcutField = NSTextField(labelWithString: shortcutText)
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Metrics.rowHeight))

        self.setupSelectionView()
        self.setupIconView(systemImageName: systemImageName)
        self.setupTextFields()

        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.handlePrimaryClick(_:)))
        recognizer.buttonMask = 0x1
        self.addGestureRecognizer(recognizer)
        self.updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityLabel() -> String? {
        self.titleField.stringValue
    }

    override func accessibilityPerformPress() -> Bool {
        self.onClick()
        return true
    }

    func setHighlighted(_ highlighted: Bool) {
        guard self.isRowHighlighted != highlighted else { return }
        self.isRowHighlighted = highlighted
        self.selectionView.isHidden = !highlighted
        self.updateColors()
    }

    override func layout() {
        super.layout()

        self.selectionView.frame = self.bounds.insetBy(dx: Metrics.selectionHorizontalInset, dy: 0)
        self.selectionView.layer?.cornerRadius = Metrics.selectionCornerRadius

        var leadingX = Metrics.leadingPadding
        let iconSide = Metrics.iconWidth
        self.iconView.frame = NSRect(
            x: leadingX,
            y: floor((self.bounds.height - iconSide) / 2),
            width: iconSide,
            height: iconSide)
        leadingX += Metrics.iconWidth + Metrics.iconTitleSpacing

        let shortcutSize = self.shortcutField.intrinsicContentSize
        let shortcutX = self.bounds.maxX
            - Metrics.trailingPadding
            + Metrics.shortcutXOffset
            - shortcutSize.width
        self.shortcutField.frame = NSRect(
            x: shortcutX,
            y: floor((self.bounds.height - shortcutSize.height) / 2),
            width: shortcutSize.width,
            height: shortcutSize.height)

        let titleSize = self.titleField.intrinsicContentSize
        self.titleField.frame = NSRect(
            x: leadingX,
            y: floor((self.bounds.height - titleSize.height) / 2),
            width: max(0, shortcutX - Metrics.titleShortcutGap - leadingX),
            height: titleSize.height)
    }

    private func setupSelectionView() {
        self.selectionView.material = .selection
        self.selectionView.blendingMode = .withinWindow
        self.selectionView.state = .active
        self.selectionView.isEmphasized = true
        self.selectionView.isHidden = true
        self.selectionView.wantsLayer = true
        self.selectionView.layer?.masksToBounds = true
        self.addSubview(self.selectionView)
    }

    private func setupIconView(systemImageName: String) {
        guard let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil) else {
            self.iconView.isHidden = true
            return
        }
        image.isTemplate = true
        self.iconView.image = image
        self.iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Metrics.iconSymbolPointSize,
            weight: .regular)
        self.iconView.imageScaling = .scaleProportionallyDown
        self.iconView.contentTintColor = .labelColor
        self.addSubview(self.iconView)
    }

    private func setupTextFields() {
        self.titleField.font = NSFont.menuFont(ofSize: 0)
        self.titleField.lineBreakMode = .byTruncatingTail
        self.titleField.maximumNumberOfLines = 1
        self.titleField.backgroundColor = .clear
        self.addSubview(self.titleField)

        self.shortcutField.font = NSFont.menuFont(ofSize: Metrics.shortcutFontSize)
        self.shortcutField.lineBreakMode = .byClipping
        self.shortcutField.maximumNumberOfLines = 1
        self.shortcutField.backgroundColor = .clear
        self.addSubview(self.shortcutField)
    }

    private func updateColors() {
        if self.isRowHighlighted {
            self.titleField.textColor = .selectedMenuItemTextColor
            self.shortcutField.textColor = .selectedMenuItemTextColor
            self.iconView.contentTintColor = .selectedMenuItemTextColor
        } else {
            self.titleField.textColor = .labelColor
            self.shortcutField.textColor = .tertiaryLabelColor
            self.iconView.contentTintColor = .labelColor
        }
    }

    @objc private func handlePrimaryClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        self.onClick()
    }
}
