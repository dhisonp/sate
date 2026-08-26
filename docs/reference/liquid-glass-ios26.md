# Liquid Glass (iOS 26) — working reference for Sate

Compiled 2026-08-26 from Apple's iOS 26 SwiftUI API surface plus community
reference material. Used to drive the Liquid Glass UI pass.

## The one rule that matters for a chat app

> Liquid Glass is exclusively for the **navigation layer** that floats above app
> content. Never apply it to content itself (lists, tables, media).

For Sate this means glass goes on: the input bar, the floating "new tokens" chip,
the status/"Thinking…" pill, toolbars. Glass does **NOT** go on message bubbles,
the transcript, or code blocks — those are the content layer.

## API surface

```swift
func glassEffect<S: Shape>(_ glass: Glass = .regular,
                           in shape: S = DefaultGlassEffectShape,
                           isEnabled: Bool = true) -> some View

func glassEffectID<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View
func glassEffectUnion<ID: Hashable>(id: ID, namespace: Namespace.ID) -> some View
func glassEffectTransition(_ transition: GlassEffectTransition, isEnabled: Bool = true) -> some View
// GlassEffectTransition: .identity | .matchedGeometry | .materialize

struct Glass {
    static var regular: Glass   // medium transparency, full adaptivity — the default choice
    static var clear: Glass     // high transparency, limited adaptivity — needs all 3 conditions below
    static var identity: Glass  // no effect
    func tint(_ color: Color) -> Glass
    func interactive() -> Glass // iOS only: press scaling, bounce, shimmer, touch illumination
}

struct GlassEffectContainer<Content: View>: View {
    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content)
}

.buttonStyle(.glass)           // secondary actions
.buttonStyle(.glassProminent)  // primary actions (known artifact with .circle — add .clipShape(Circle()))
.buttonBorderShape(.capsule | .roundedRectangle | .circle)
```

Shapes: `.capsule` (default), `.circle`, `RoundedRectangle(cornerRadius:)`,
`.rect(cornerRadius: .containerConcentric)`, `.ellipse`, custom `Shape`.

## Why GlassEffectContainer is mandatory for adjacent glass

> Glass cannot sample other glass; the container provides a shared sampling region.

Two sibling `.glassEffect()` calls without a container render inefficiently and
sample inconsistently. `spacing:` sets the distance at which neighbours merge —
this is what produces the "liquid" morph.

## `.clear` requires ALL THREE to be true
1. The element sits over media-rich content.
2. That content is not harmed by a dimming layer.
3. Content above the glass is bold and bright.

Sate's transcript is text on a plain background, so **`.regular` is correct everywhere**
and `.clear` should not be used.

## Anti-patterns (verbatim)
- Apply glass to content itself (lists, tables, media)
- Stack glass on glass (confusing hierarchy)
- Use full-screen glass backgrounds
- Separate `.glassEffect()` calls without a container
- Tint everything (breaks semantic meaning) — tint conveys *state/primacy*, not decoration
- Glass over busy/animated content without dimming
- Apply glass to scrollable content
- Break corner concentricity
- Continuous animations with glass (performance; ~13% battery drain documented)
- Overriding the user's accessibility settings by hand

## Accessibility is automatic
Reduced Transparency, Increased Contrast, Reduced Motion and iOS 26.1+ Tinted Mode
are handled by the system. Override only when genuinely needed:
```swift
@Environment(\.accessibilityReduceTransparency) var reduceTransparency
.glassEffect(reduceTransparency ? .identity : .regular)
```

## Free wins from recompiling against the iOS 26 SDK
Native `NavigationStack`, toolbars, sheets and `List` already adopt Liquid Glass.
Sheets get an inset glass background — so remove any custom
`.presentationBackground(...)` and let the system draw it.

## Other iOS 26 chrome APIs worth using
```swift
ToolbarSpacer(.fixed, spacing: 20) / ToolbarSpacer(.flexible)
.sharedBackgroundVisibility(.hidden)     // opt a toolbar item out of the shared glass
.scrollEdgeEffectStyle(...)              // edge treatment where content meets chrome
.searchToolbarBehavior(.minimized)
```

## Availability
iOS/iPadOS 26.0+, Xcode 26.0+. Older devices fall back to frosted glass with
reduced effects. Sate targets iOS 26.0, so every API here is available unguarded.
