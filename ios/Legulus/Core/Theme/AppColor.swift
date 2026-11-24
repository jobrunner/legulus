import SwiftUI
import UIKit

/// Semantic color tokens for the app. Reads from `Assets.xcassets`
/// where we ship our own brand colours; everything else wraps
/// `UIColor` system semantics so Light/Dark/Increase-Contrast all
/// behave correctly without us having to ship per-mode hex values.
///
/// Picking the right token:
/// - **Brand** colours: the green identity (header background, FAB,
///   primary CTAs). Don't use brand colours for body text — use the
///   text tokens below.
/// - **Surface** colours: anything that's a "card" or "background".
///   Pick by elevation, not by aesthetic.
/// - **Text** tokens: body content. Default to `textPrimary`; use
///   `textSecondary`/`textTertiary` for de-emphasised text.
/// - **Status** tokens: success/warning/danger/info — for badges,
///   inline error messages, sync indicators.
///
/// Contrast notes:
///   - `BrandPrimary` `#186029` (same in both schemes) → contrast
///     vs. white ≈ 7.65:1
///   - Light `BrandPrimaryText` `#186029` → contrast vs. white
///     background ≈ 7.31:1
///   - Dark  `BrandPrimaryText` `#6ECB86` → contrast vs. dark card
///     background ≈ 7.35:1
enum AppColor {
    // MARK: - Brand

    /// Primary brand colour used as a **surface** — home header
    /// background, FAB fill. White (`brandOnPrimary`) is the only
    /// legible foreground on this surface.
    ///
    /// `brandPrimary` and `brandPrimaryText` are deliberately two
    /// separate tokens, not one colour reused for both jobs: a fill
    /// that carries white text must stay dark in both schemes (this
    /// token is `#186029` everywhere, 7.65:1 against white), while a
    /// colour drawn as foreground on the page background must
    /// lighten in dark mode to stay legible there. The former
    /// single-role `BrandPrimary` (`#1B6B2F` light / `#3FA85A` dark)
    /// tried to serve both roles and met neither at 7:1: only 6.58:1
    /// as a light-mode fill under white text, and only 3.02:1 when
    /// the dark variant was itself used as a foreground/text colour.
    /// Do **not** use this token for text/icon foregrounds — use
    /// `brandPrimaryText`.
    static let brandPrimary = Color("BrandPrimary")

    /// Primary brand colour used as a **foreground** — icon tints,
    /// `tint`/`foregroundStyle` on brand-coloured controls, text set
    /// in the brand colour. Lightens in dark mode (`#186029` light /
    /// `#6ECB86` dark) so it keeps ≥7:1 contrast against the page
    /// background in both schemes; see `brandPrimary` above for why
    /// this can't be the same token as the surface colour.
    static let brandPrimaryText = Color("BrandPrimaryText")

    /// The "on" pair to `brandPrimary` — text/icons sitting on a
    /// brand surface. Always white in both colour schemes.
    static let brandOnPrimary = Color("BrandOnPrimary")

    /// Lower-emphasis variant for section headers inside the brand-
    /// coloured header (e.g. the "ACTIVE COLLECTOR" caption above
    /// the actual name).
    static let brandPrimaryMuted = Color("BrandPrimaryMuted")

    /// Light brand fill behind `brandPrimaryText`: the secondary
    /// buttons of the sample view's action bar.
    static let brandTint = Color("BrandPrimary").opacity(0.14)

    // MARK: - Surfaces

    // System wrappers — let iOS handle Light/Dark/Contrast for us.

    /// Default app background.
    static let surface = Color(uiColor: .systemBackground)

    /// One level up from `surface` — cards-on-background.
    static let surfaceSecondary = Color(uiColor: .secondarySystemBackground)

    /// Two levels up — nested cards, modal sheets on a card.
    static let surfaceTertiary = Color(uiColor: .tertiarySystemBackground)

    /// Grouped-list backdrop (used by Settings, Home menu).
    static let surfaceGrouped = Color(uiColor: .systemGroupedBackground)

    /// A card on the grouped backdrop (`AppCard`, the sample view's
    /// sections): white in Light, lifted grey in Dark.
    static let surfaceCard = Color(uiColor: .secondarySystemGroupedBackground)

    /// Dims the screen behind a blocking progress card (e.g. „Foto wird
    /// gelesen …“): the grouped backdrop at 60 %, so the content stays
    /// faintly visible in Light and Dark.
    static let scrim = Color(uiColor: .systemGroupedBackground).opacity(0.6)

    /// Shade behind the controls laid over the camera picture, so white
    /// icons stay readable on a bright scene. The strong variant is for
    /// Increase Contrast.
    static let cameraScrim = Color.black.opacity(0.45)
    static let cameraScrimStrong = Color.black.opacity(0.75)
    /// A camera mode that is switched on (LED, flash, fixed focus, macro)
    /// and the current value on the zoom dial; yellow as in the system
    /// camera. The icons differ in shape as well, never by colour alone.
    static let cameraActive = Color(uiColor: .systemYellow)

    // MARK: - Text

    /// Default body text colour. Black/white per scheme.
    static let textPrimary = Color(uiColor: .label)

    /// Captions, supporting text.
    static let textSecondary = Color(uiColor: .secondaryLabel)

    /// Sparingly-used disabled / placeholder text.
    static let textTertiary = Color(uiColor: .tertiaryLabel)

    // MARK: - Borders / dividers

    /// The hairline divider colour matching iOS list separators.
    static let separator = Color(uiColor: .separator)

    /// Slightly stronger than `separator`; use when the divider
    /// must register at a glance (sectioned cards).
    static let outlineSubtle = Color(uiColor: .opaqueSeparator)

    // MARK: - Status

    // System semantic colours — they already adapt to Increase
    // Contrast and meet AA against system backgrounds.

    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemYellow)
    static let danger = Color(uiColor: .systemRed)
    static let info = Color(uiColor: .systemBlue)

    // MARK: - Sync state (app-specific aliases)

    // Centralised here so the four sync states stay visually consistent
    // across `SampleEditor`, `SampleDetail` and `SamplesList`.

    /// Local-only, push queued.
    static let syncPending = Color(.secondaryLabel)
    /// Push in flight.
    static let syncInFlight = Color(.secondaryLabel)
    /// Backend confirmed.
    static let syncSynced = success
    /// Last push failed; retry pending.
    static let syncFailed = warning

    // MARK: - Sky (light band of the „Zeit“ card)

    // Fixed in both schemes: the band shows the sky, which is bright by
    // day and dark at night whatever the phone's appearance. The steps
    // differ in lightness, not hue alone.

    /// Sun above the horizon.
    static let skyDay = Color(red: 0.98, green: 0.89, blue: 0.63)
    /// Civil twilight (sun 0° to -6°).
    static let skyCivil = Color(red: 0.62, green: 0.71, blue: 0.85)
    /// Nautical twilight (-6° to -12°).
    static let skyNautical = Color(red: 0.34, green: 0.44, blue: 0.62)
    /// Astronomical twilight (-12° to -18°).
    static let skyAstronomical = Color(red: 0.20, green: 0.27, blue: 0.42)
    /// Night (below -18°).
    static let skyNight = Color(red: 0.12, green: 0.16, blue: 0.27)
    /// The sun's disk.
    static let skySun = Color(red: 0.96, green: 0.71, blue: 0.0)
    /// The moon's lit and dark part.
    static let skyMoonLit = Color(red: 0.93, green: 0.92, blue: 0.89)
    static let skyMoonDark = Color(red: 0.29, green: 0.31, blue: 0.38)
}
