# Liquid Glass & macOS 26 Development Reference

Comprehensive reference compiled from WWDC25 sessions: "Meet Liquid Glass" (219), "What's new in SwiftUI" (256), "Build a SwiftUI app with the new design" (323), "Build an AppKit app with the new design" (310), "What's new in UIKit" (243), "Build a UIKit app with the new design" (284), "Get to know the new design system" (356), "Design foundations from idea to interface" (359).

---

## Part 1: Liquid Glass -- Core Design Principles

### What Is Liquid Glass

Liquid Glass is Apple's unified design material introduced across all platforms in iOS 26 / macOS Tahoe 26. It is a flexible, dynamic digital meta-material that dynamically bends and shapes light, behaving like a lightweight liquid in response to user touch and app dynamics.

### Visual Properties

- **Lensing**: The primary visual identifier. Dynamically bends, shapes, and concentrates light in real-time.
- **Responsive to interaction**: Flexes and energizes with light when touched, making interfaces feel responsive and alive.
- **Graceful transitions**: Objects materialize/dematerialize by modulating light bending rather than fading.
- **Gel-like flexibility**: Communicates transient and malleable nature through fluid motion.
- **Adaptive layers**: Composed of multiple layers that continuously adapt based on content underneath.
- **Shadow management**: Increases opacity over text for separation, decreases over light backgrounds.
- **Size-based changes**: Larger elements simulate thicker material with deeper shadows and pronounced lensing.

### Two Variants

**Regular (default, most versatile)**:
- Full adaptive behaviors and effects.
- Provides legibility in any context at any size over any content.
- Default choice for the vast majority of use cases.

**Clear (specialized)**:
- Permanently more transparent.
- Requires a dimming layer behind it for legibility.
- Only use when ALL three conditions are met: (1) element is over media-rich content, (2) dimming won't negatively affect the content layer, (3) content above is bold and bright.

### Adaptivity Behavior

- Small elements (navbars, tabbars): Flip between light and dark appearance based on background content brightness.
- Large elements (menus, sidebars): Adapt based on context but do NOT flip light/dark.
- Unfocused windows on Mac/iPad shift appearance to guide attention (become more opaque, grow slightly).
- Scroll edge effects work with Liquid Glass to maintain separation and legibility as content scrolls.

### Tinting

- Generates tone ranges based on underlying content brightness, mimicking real colored glass behavior.
- Use selectively for primary actions only.
- Do NOT tint all elements -- reserve tint for conveying meaning (e.g., accent-colored primary action button).

### Accessibility (Built-in, automatic at system level)

- **Reduce Transparency**: Makes glass frostier, obscures more content behind it.
- **Increase Contrast**: Elements become predominantly black/white with contrasting borders.
- **Reduce Motion**: Decreases effect intensity, disables elastic properties.

---

## Part 2: Design System Principles

### Concentricity

The core shape principle. Elements are designed with curvature nesting within container corner radius.

Three shape types:
- **Fixed shapes**: Constant corner radius.
- **Capsules**: Radius equals half the container height (used for sliders, switches, buttons, grouped table views).
- **Concentric shapes**: Radius calculated by subtracting padding from parent's radius.

On macOS:
- Window corners are softer and more generous (varies by style).
- Toolbar windows: larger radius wrapping concentrically around glass toolbar.
- Titlebar-only windows: smaller radius wrapping compactly around controls.

### Hierarchy

- Liquid Glass is for the **floating navigation layer** above content -- toolbars, sidebars, tab bars.
- Content flows edge-to-edge beneath the glass layer.
- Scroll edge effects provide separation between floating glass and content.
- Do NOT apply glass to content layers where it would compete with navigation.

### Structure Principles

- Action sheets now spring from their source action (not the bottom of screen).
- Custom controls should apply material directly to the control, not inner views.
- Focus signaling: Dimming layer + Liquid Glass = interrupting tasks (modal feel). Liquid Glass alone = parallel tasks.
- Navigation controls are lifted with Liquid Glass to separate from content.
- Remove unnecessary customizations (backgrounds, borders) on bars.
- Express hierarchy through layout and grouping, not decoration.

### Bar Item Organization Rules

- Group items by function and frequency.
- Do NOT group symbols with text (risk appearing as single button).
- Text buttons should sit in separate containers.
- Primary actions (e.g., Done) stay separate and tinted.
- Avoid mixing elements from different UI parts.

### Scroll Edge Effects

Replace hard dividers. Two styles:
- **Soft**: Default style, subtle transition, works with Liquid Glass elements (preferred on iOS/iPadOS).
- **Hard**: Stronger boundary, more opaque, for interactive text or pinned headers (preferred on macOS).
- Apply one per view; in Split View each pane can have its own.
- Only use where floating UI elements overlap content.

### Color

- System colors adjusted across Light, Dark, and Increased Contrast appearances.
- Enhanced hue differentiation while maintaining Apple's optimistic aesthetic.
- Improved harmony with Liquid Glass.
- Use system/semantic colors as primary palette; custom colors add personality.

### Typography

- Refined for clarity and structure.
- Bolder and left-aligned to improve readability.
- Use system text styles for predefined hierarchy.

---

## Part 3: Do's and Don'ts

### DO

- Reserve Liquid Glass for the top-level navigation layer (toolbars, sidebars, tab bars).
- Let content flow edge-to-edge beneath glass elements.
- Use standard system controls for automatic Liquid Glass treatment.
- Use GlassEffectContainer (SwiftUI) or NSGlassEffectContainerView (AppKit) or UIGlassContainerEffect (UIKit) to group proximate glass elements.
- Remove legacy backgrounds, borders, and visual effect views from toolbars and sidebars.
- Use Auto Layout; avoid hard-coded control heights.
- Use monochrome icon palettes in toolbars to reduce visual noise.
- Use concentric shapes for nested containers.
- Apply material directly to controls, not to inner views.
- Use SF Symbols for menu and toolbar icons.
- Test with Reduce Transparency, Increase Contrast, and Reduce Motion accessibility settings.

### DON'T

- Stack Liquid Glass on top of Liquid Glass (no glass-on-glass). Use fills and transparency for overlays instead.
- Over-apply glass to non-navigation content (dilutes the importance signal).
- Tint all glass elements. Reserve tint for primary actions conveying meaning.
- Use the Clear variant unless all three conditions are met (media-rich content, dimming acceptable, bold content above).
- Hard-code control heights -- sizes changed in macOS 26.
- Keep legacy NSVisualEffectView inside sidebars (remove them).
- Mix glass with legacy visual effect views.
- Place NSGlassEffectView as a sibling behind content.
- Group symbols with text labels in toolbar (risk appearing as single button).

---

## Part 4: SwiftUI APIs for Liquid Glass

### glassEffect Modifier

Applies Liquid Glass material to any view.

```swift
// Basic usage -- capsule shape by default
myView.glassEffect(in: .capsule)

// With custom shape
myView.glassEffect(in: RoundedRectangle(cornerRadius: 12))
```

- Automatically applies vibrant text color adaptation.
- Content placed on glass automatically gets legibility treatment.

### Tinting Glass

```swift
myView
    .glassEffect(in: .capsule)
    .tint(.blue) // Conveys meaning with vibrant adaptive colors
```

### Interactive Glass (iOS)

```swift
myView
    .glassEffect(in: .capsule)
    .interactive // Enables scaling, bouncing, and shimmering on user interaction
```

### GlassEffectContainer

Groups multiple glass elements so they share sampling region and adaptive appearance. Essential because glass cannot sample other glass.

```swift
GlassEffectContainer {
    HStack {
        Button("Play") { }
            .glassEffect(in: .capsule)
        Button("Next") { }
            .glassEffect(in: .capsule)
    }
}
```

### glassEffectID Modifier

Creates fluid morphing transitions between glass elements (glass absorbs/expands smoothly).

```swift
@Namespace var namespace

myView
    .glassEffect(in: .capsule)
    .glassEffectID("myElement", in: namespace)
```

### Glass Button Styles

```swift
Button("Action") { }
    .buttonStyle(.glass)

Button("Primary Action") { }
    .buttonStyle(.glassProminent)
```

### Toolbar APIs

**ToolbarSpacer** -- separates toolbar item groups into distinct glass pills:

```swift
.toolbar {
    ToolbarItemGroup(placement: .primaryAction) {
        UpButton()
        DownButton()
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
        SettingsButton()
    }
}
```

- .fixed spacing: emphasizes related groups with small gap.
- Default/flexible spacing: creates leading/trailing alignment patterns.

**Toolbar tinting**:
```swift
ToolbarItem {
    Button { } label: { Image(systemName: "flag.fill") }
        .tint(.orange)
}
```

Use .borderedProminent style with .tint() to tint the glass background.

**Badge on toolbar items**:
```swift
ToolbarItem {
    Button { } label: { Image(systemName: "bell") }
        .badge(4)
}
```

**Shared background visibility** -- separates items into own group without glass background:
```swift
ToolbarItem {
    Button { } label: { Text("Title") }
        .sharedBackgroundVisibility(.hidden)
}
```

**Scroll edge effect style**:
```swift
.scrollEdgeEffectStyle(.hard) // For dense UIs like Calendar
// Default is .soft
```

### Search APIs

**Bottom-aligned search on iPhone** (automatic):
```swift
NavigationSplitView {
    SidebarView()
} detail: {
    DetailView()
}
.searchable(text: $searchText)
```

**Search tab role**:
```swift
TabView {
    Tab("Home", systemImage: "house") { HomeView() }
    Tab("Library", systemImage: "books.vertical") { LibraryView() }
    Tab(role: .search) { SearchView() }
}
.searchable(text: $searchText)
```

**Toolbar search behavior**:
```swift
.searchToolbarBehavior(.minimized) // Shows as button, expands on tap
```

### Navigation & Tab Updates

- NavigationSplitView sidebar is now a floating Liquid Glass pane.
- Sidebar automatically adapts light/dark based on content underneath.
- Tab bars have compact appearance on iPhone.
- Tab bar minimization on scroll:
```swift
.tabBarMinimizeBehavior(.onScrollDown)
```
- Bottom accessory view above tab bar:
```swift
.tabViewBottomAccessory {
    NowPlayingView()
}
```

### Sheets & Presentations

- Default Liquid Glass background on partial-height sheets.
- Automatic morphing transitions from buttons to sheet content.
- Navigation zoom transitions support sheet presentations.
```swift
.presentationBackground(.clear) // Let Liquid Glass show through
```

### Background Extension Effect

Extends view appearance beyond safe area without clipping content:
```swift
myImageView
    .backgroundExtensionEffect()
```

### Window APIs (macOS)

**Window resize anchor**:
```swift
.windowResizeAnchor(.top) // Animation origin during resize
```

### Control APIs

**Concentric rectangle shape** (auto-maintains corner alignment):
```swift
RoundedRectangle.concentric
// or
.containerConcentric // Aligns with container corners
```

**Button border shape**:
```swift
.buttonBorderShape(.capsule)
```

**Control size**:
```swift
.controlSize(.extraLarge) // New in macOS 26
```

**Slider with ticks**:
```swift
Slider(value: $value, in: 0...10, step: 1)
// Tick marks appear automatically with step parameter

// Manual tick placement
Slider(value: $value) {
    // label
} ticks: {
    // custom tick views
}

// Neutral value (bidirectional fill)
Slider(value: $speed, in: 0.5...2.0)
    .neutralValue(1.0)
```

---

## Part 5: AppKit APIs for Liquid Glass (macOS)

### NSGlassEffectView

Primary API for placing content on Liquid Glass.

```swift
let glassView = NSGlassEffectView()
glassView.contentView = myView       // Assigns content; geometry tied via Auto Layout
glassView.cornerRadius = 12          // Customize glass shape
glassView.tintColor = .systemBlue    // Customize glass color
```

### NSGlassEffectContainerView

Groups multiple glass elements for unified visual effect.

```swift
let glassContainer = NSGlassEffectContainerView()
glassContainer.contentView = stackView
glassContainer.spacing = 8  // Controls proximity-based joining/separation
```

Benefits:
- Fluid joining/separation of glass shapes via liquid visual effect.
- Shared adaptive appearance across grouped elements.
- Single sampling pass (performance optimization).
- Visual correctness when glass elements are proximate.

### NSBackgroundExtensionView

Mirrors and blurs content to create edge-to-edge effect:

```swift
let bgExtension = NSBackgroundExtensionView()
bgExtension.contentView = myArtworkView
// Automatically creates blurred replica to fill spaces outside safe area
```

### NSView.LayoutRegion (Corner Avoidance)

```swift
func updateConstraints() {
    let safeArea = layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
    NSLayoutConstraint.activate([
        safeArea.leadingAnchor.constraint(equalTo: button.leadingAnchor),
        safeArea.trailingAnchor.constraint(greaterThanOrEqualTo: button.trailingAnchor),
        safeArea.bottomAnchor.constraint(equalTo: button.bottomAnchor)
    ])
}
```

### Toolbar Changes

Toolbar elements automatically sit on Liquid Glass and float above content. AppKit automatically groups multiple toolbar buttons on a single glass element, separated by control type.

```swift
// Remove glass backing from non-interactive items
toolbarItem.isBordered = false

// Prominent style (accent color tint)
toolbarItem.style = .prominent

// Custom color tint
toolbarItem.backgroundTintColor = .systemGreen

// Badging
toolbarItem.badge = NSItemBadge.count(4)
toolbarItem.badge = NSItemBadge.text("New")
toolbarItem.badge = NSItemBadge.indicator
```

### Split View & Sidebar

- Sidebars appear as floating glass panes above content.
- Inspectors use edge-to-edge glass alongside content.
- Use NSSplitViewController with sidebar/inspector behaviors for automatic glass.

```swift
// Extend content beneath sidebar
splitViewItem.automaticallyAdjustsSafeAreaInsets = true
```

Remove legacy NSVisualEffectView from inside sidebars to prevent glass material showing through.

### Split Item Accessories (New)

```swift
let accessoryVC = NSSplitViewItemAccessoryViewController()
splitViewItem.addTopAlignedAccessoryViewController(accessoryVC)
// or
splitViewItem.addBottomAlignedAccessoryViewController(accessoryVC)
```

### Control System Updates

**New extra-large size**: For emphasizing most important actions.

**Height changes**: Mini, small, medium controls are slightly taller. Use Auto Layout, avoid hard-coded heights.

**Compact control size compatibility**:
```swift
view.prefersCompactControlSizeMetrics = true
// Reverts to previous macOS sizing; inherited down view hierarchy
```

**Shape variations**:
- Mini through medium: rounded-rectangle (greater horizontal density).
- Large and extra-large: capsule shape.

```swift
// Override default shape
button.borderShape = .capsule
// Available on: NSButton, NSPopUpButton, NSSegmentedControl
```

**Glass bezel style**:
```swift
button.bezelStyle = .glass
button.bezelColor = .systemGreen  // Optional tinting
```

**Tint prominence**:
```swift
shuffleButton.tintProminence = .secondary
playButton.keyEquivalent = "\r"  // Makes it default (auto-primary)
// Cases: .automatic, .none, .secondary, .primary
```

**Slider updates**:
```swift
slider.tintProminence = .secondary  // Fills track with accent color
slider.neutralValue = 1.0           // Anchor point for fill
```

### Menu Updates

- Refreshed appearance across menu bar and context menus.
- Icons in single column per menu section for easy scanning.
- Add SF Symbols to menu actions.

---

## Part 6: UIKit APIs for Liquid Glass (iOS/iPadOS)

### UIGlassEffect and UIVisualEffectView

```swift
// Create glass effect
let glassEffect = UIGlassEffect()
let effectView = UIVisualEffectView()

// Materialize with animation
UIView.animate {
    effectView.effect = glassEffect
}

// Dematerialize
UIView.animate {
    effectView.effect = nil
}

// Corner configuration
effectView.cornerConfiguration = .fixed(8)
effectView.cornerConfiguration = .containerRelative()

// Add content
effectView.contentView.addSubview(label)

// Tinted glass
glassEffect.tintColor = .systemBlue

// Interactive glass (scales and bounces on tap)
glassEffect.isInteractive = true

// Custom tint color
glassEffect.tintColor = UIColor(displayP3Red: r, green: g, blue: b, alpha: 1)
```

### UIGlassContainerEffect

Groups glass elements for proper sampling and merging.

```swift
let container = UIGlassContainerEffect()
container.spacing = 20
let containerView = UIVisualEffectView(effect: container)

let glass1 = UIVisualEffectView(effect: UIGlassEffect())
let glass2 = UIVisualEffectView(effect: UIGlassEffect())
containerView.contentView.addSubview(glass1)
containerView.contentView.addSubview(glass2)

// Glass elements merge when overlapping
UIView.animate {
    glass1.frame = targetFrame
    glass2.frame = targetFrame
}
```

### UIBackgroundExtensionView

```swift
let extensionView = UIBackgroundExtensionView()
extensionView.contentView = posterImageView

// Custom layout
extensionView.automaticallyPlacesContentView = false
```

### Navigation Bar Items

```swift
// Separate items into groups with fixedSpace
navigationItem.rightBarButtonItems = [
    doneButton,
    flagButton,
    folderButton,
    .fixedSpace(0),  // Creates separate background group
    shareButton,
    selectButton
]

// Tinted item
flagButton.tintColor = .systemOrange
flagButton.style = .prominent  // Tints the glass background

// Flexible space that groups items
let flexibleSpace = UIBarButtonItem.flexibleSpace()
flexibleSpace.hidesSharedBackground = false
```

### Glass Button Configurations

```swift
button.configuration = .glass()            // Standard glass
button.configuration = .prominentGlass()   // Tinted glass
```

### Tab Bar

```swift
tabBarController.tabBarMinimizeBehavior = .onScrollDown

// Bottom accessory
let accessory = UITabAccessory(contentView: nowPlayingView)
tabBarController.bottomAccessory = accessory
```

### Search

```swift
// Search in toolbar
toolbarItems = [navigationItem.searchBarPlacementBarButtonItem, .flexibleSpace(), addButton]

// iPad nav bar integration
navigationItem.searchBarPlacementAllowsExternalIntegration = true

// Search tab
searchTab.automaticallyActivatesSearch = true

// Centered search
navigationItem.preferredSearchBarPlacement = .integratedCentered
```

### Scroll Edge Effect

```swift
// Soft or hard scroll edge
scrollView.topEdgeEffect.style = .hard

// Edge effect for custom floating containers
let interaction = UIScrollEdgeElementContainerInteraction()
interaction.scrollView = contentScrollView
interaction.edge = .bottom
buttonsContainerView.addInteraction(interaction)
```

### Sliders

```swift
slider.trackConfiguration = .init(
    allowsTickValuesOnly: true,
    neutralValue: 0.2,
    numberOfTicks: 5
)
slider.sliderStyle = .thumbless
```

### Presentations

```swift
// Popover morphing from bar button
viewController.popoverPresentationController?.sourceItem = barButtonItem

// Sheet zoom transition
viewController.preferredTransition = .zoom { _ in folderBarButtonItem }

// Action sheet source
alertController.popoverPresentationController?.sourceItem = barButtonItem
```

---

## Part 7: Migration Guide

### Step 1: Build with Xcode 26

Simply recompiling with the new SDK gives you automatic enhancements:
- Standard controls (toolbars, tab bars, navigation bars) automatically adopt Liquid Glass.
- Window chrome updates automatically.
- Scroll edge effects appear automatically in scroll views.

### Step 2: Remove Legacy Customizations

- Remove custom backgrounds from toolbars, tab bars, navigation bars.
- Remove NSVisualEffectView from inside sidebars.
- Remove custom presentationBackground settings on sheets (let Liquid Glass show).
- Remove hard-coded dividers between content and bars (scroll edge effects replace them).
- Remove unnecessary borders and shadows on navigation elements.

### Step 3: Extend Content Edge-to-Edge

- Content should flow beneath floating glass elements.
- Use backgroundExtensionEffect() (SwiftUI) or NSBackgroundExtensionView / UIBackgroundExtensionView for rich imagery.
- Set automaticallyAdjustsSafeAreaInsets = true on split view items.

### Step 4: Audit Control Sizes

- Control heights changed (mini, small, medium are slightly taller).
- Replace ALL hard-coded control heights with Auto Layout.
- Use prefersCompactControlSizeMetrics = true (AppKit) if needed temporarily for complex layouts.

### Step 5: Adopt New APIs

- Add SF Symbol icons to all menu items.
- Identify key custom UI elements that should be elevated with Liquid Glass.
- Use GlassEffectContainer to group proximate glass elements.
- Apply tint prominence strategically for visual hierarchy.
- Use ToolbarSpacer(.fixed) to create distinct glass pills in toolbars.

### Step 6: Test Thoroughly

- Test with light and dark content scrolling under glass elements.
- Verify content is not clipped near window corners (use LayoutRegion API).
- Test all accessibility settings (Reduce Transparency, Increase Contrast, Reduce Motion).
- Verify automatic glass adaptive appearance.

---

## Part 8: SwiftUI Performance (Related)

### List Performance Improvements

- macOS lists over 100,000 items: 6x faster loading.
- List updates: up to 16x faster.
- Improvements across all platforms.

### Scrolling

- Improved scheduling of UI updates on iOS and macOS.
- Nested ScrollView with LazyVStack now delays view loading.
- Reduced frame drops at high frame rates.

### SwiftUI Performance Instrument (Xcode)

New inspection lanes for view body updates, platform view updates, and other performance metrics.

---

## Part 9: Other Notable SwiftUI APIs (macOS 26)

### @Animatable Macro

```swift
@Animatable
struct LoadingArc: Shape {
    var center: CGPoint
    var radius: CGFloat
    var startAngle: Angle
    var endAngle: Angle
    @AnimatableIgnored var drawPathClockwise: Bool

    func path(in rect: CGRect) -> Path { ... }
}
```

### Window Resize Anchor

```swift
.windowResizeAnchor(.top) // Controls animation origin during window resize
```

### Drag and Drop (macOS)

```swift
.draggable(containerItemID: photo.id)
.dragContainer(for: Photo.self, selection: selectedPhotos) { draggedIDs in
    photos(ids: draggedIDs)
}
.dragConfiguration(DragConfiguration(allowMove: false, allowDelete: true))
.onDragSessionUpdated { session in
    let ids = session.draggedItemIDs(for: Photo.ID.self)
    if session.phase == .ended(.delete) { deletePhotos(ids) }
}
.dragPreviewsFormation(.stack)
```

### Rich Text Editing

```swift
@Binding var text: AttributedString
TextEditor(text: $text)
// Built-in formatting controls, paragraph styles, attribute constraints
```

### WebView

```swift
WebView(url: myURL)
// Or with programmable control:
@State private var page = WebPage()
WebView(page)
    .ignoresSafeArea()
    .onAppear { page.load(URLRequest(url: myURL)) }
```

### Scene Bridging

UIKit/AppKit apps can now request SwiftUI scenes:
```swift
// In UIKit:
class MySceneDelegate: UIResponder, UIHostingSceneDelegate {
    static var rootScene: some Scene {
        WindowGroup(id: "mywindow") { MyView() }
    }
}
```

### Controls on More Platforms

- Controls (Control Center widgets) now available on watchOS 26 and macOS Tahoe.
- Widgets coming to visionOS and CarPlay.

---

## Part 10: UIKit Architectural Improvements (iOS 26)

### Automatic Observation Tracking

UIKit automatically tracks @Observable objects in update methods:

```swift
@Observable class Model {
    var showStatus: Bool
    var statusText: String
}

override func viewWillLayoutSubviews() {
    statusLabel.alpha = model.showStatus ? 1.0 : 0.0
    statusLabel.text = model.statusText
}
// UIKit records dependencies; any change triggers re-layout automatically
```

Back-deploy to iOS 18 with UIObservationTrackingEnabled Info.plist key.

### New updateProperties() Method

```swift
override func updateProperties() {
    super.updateProperties()
    if let badgeCount = model.badgeCount {
        folderButton.badge = .count(badgeCount)
    } else {
        folderButton.badge = nil
    }
}
```

Runs before layoutSubviews, independently. Tracks Observable objects. Trigger via setNeedsUpdateProperties().

### Animation flushUpdates Option

```swift
UIView.animate(options: .flushUpdates) {
    model.badgeColor = .red
}
// No manual layoutIfNeeded() calls needed
```

### UIHostingSceneDelegate

Embed SwiftUI scenes in UIKit apps for incremental adoption:
```swift
class ZenSceneDelegate: UIResponder, UIHostingSceneDelegate {
    static var rootScene: some Scene {
        WindowGroup(id: "zen") { ZenView() }
    }
}
```

### Menu Bar on iPad

```swift
var config = UIMainMenuSystem.Configuration()
config.printingPreference = .included
config.inspectorPreference = .removed
config.findingConfiguration.style = .search
UIMainMenuSystem.shared.setBuildConfiguration(config) { builder in
    builder.insertElements([...], afterCommand: #selector(copy(_:)))
}
```

### UIScene Required

All UIKit apps must use UIScene-based lifecycle. Legacy UIApplicationDelegate callbacks are deprecated. All UIWindow initializers except init(windowScene:) are deprecated.

---

## Part 11: Quick Reference -- Key API Names

### SwiftUI Modifiers
- .glassEffect(in:) -- apply Liquid Glass to view
- .tint(_:) -- tint glass color
- .interactive -- enable interactive glass (iOS)
- .glassEffectID(_:in:) -- morphing transitions
- .buttonStyle(.glass) -- glass button
- .buttonStyle(.glassProminent) -- tinted glass button
- .tabBarMinimizeBehavior(_:) -- minimize tab bar on scroll
- .tabViewBottomAccessory { } -- accessory above tab bar
- .searchToolbarBehavior(.minimized) -- search as button
- .backgroundExtensionEffect() -- extend beyond safe area
- .scrollEdgeEffectStyle(_:) -- tune edge effect (.soft, .hard)
- .sharedBackgroundVisibility(_:) -- separate toolbar group
- .badge(_:) -- badge on toolbar item
- .windowResizeAnchor(_:) -- resize animation origin
- .controlSize(.extraLarge) -- new extra-large size
- .buttonBorderShape(.capsule) -- override border shape
- .presentationBackground(_:) -- sheet background
- .neutralValue(_:) -- slider bidirectional fill anchor

### SwiftUI Views/Containers
- GlassEffectContainer { } -- group glass elements
- ToolbarSpacer(.fixed) -- separate toolbar groups
- Tab(role: .search) -- dedicated search tab
- WebView(url:) / WebView(page) -- web content

### AppKit Classes
- NSGlassEffectView -- glass material view (.contentView, .cornerRadius, .tintColor)
- NSGlassEffectContainerView -- group glass (.contentView, .spacing)
- NSBackgroundExtensionView -- edge-to-edge content extension
- NSView.LayoutRegion -- corner avoidance layout
- NSSplitViewItemAccessoryViewController -- split item accessory
- NSItemBadge -- toolbar badges (.count(), .text(), .indicator)

### AppKit Properties
- toolbarItem.isBordered -- toggle glass on toolbar item
- toolbarItem.style = .prominent -- accent color tint
- toolbarItem.backgroundTintColor -- custom tint
- splitViewItem.automaticallyAdjustsSafeAreaInsets -- content under sidebar
- button.bezelStyle = .glass -- glass button
- button.bezelColor -- glass tint color
- button.borderShape = .capsule -- shape override
- view.prefersCompactControlSizeMetrics -- legacy sizing
- tintProminence -- .automatic, .none, .secondary, .primary
- slider.neutralValue -- fill anchor point

### UIKit Classes
- UIGlassEffect -- glass effect (.tintColor, .isInteractive)
- UIGlassContainerEffect -- group glass (.spacing)
- UIVisualEffectView -- host for glass effect
- UIBackgroundExtensionView -- edge-to-edge extension
- UIScrollEdgeElementContainerInteraction -- scroll edge for custom containers
- UITabAccessory -- tab bar accessory view

### UIKit Properties/Methods
- effectView.effect = UIGlassEffect() -- apply glass
- effectView.cornerConfiguration -- .fixed(), .containerRelative()
- button.configuration = .glass() -- glass button config
- button.configuration = .prominentGlass() -- tinted glass
- tabBarController.tabBarMinimizeBehavior -- scroll minimize
- navigationItem.searchBarPlacementBarButtonItem -- search in toolbar
- scrollView.topEdgeEffect.style = .hard -- hard edge
- slider.trackConfiguration -- tick marks, neutral value
- slider.sliderStyle = .thumbless -- thumbless slider
