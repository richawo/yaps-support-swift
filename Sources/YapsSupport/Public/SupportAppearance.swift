import SwiftUI

/// Local styling for the Support chat.
///
/// Every property is optional: `nil` means "use the SDK default". When `usesRemoteAppearance` is on,
/// values published from the inbox win over these, so the precedence is
/// **remote > local > default**. Remote changes apply the next time the chat opens.
///
/// ```swift
/// var look = SupportAppearance()
/// look.accentColor = .orange
/// look.title = "Help"
/// YapsSupport.shared.appearance = look
/// ```
public struct SupportAppearance: Sendable {
    /// Outgoing bubbles, the send button and other accented controls. Default: the system tint.
    public var accentColor: Color?
    /// Text and symbols drawn on accent surfaces. Default: white.
    public var onAccentColor: Color?
    /// The chat background. Default: the system grouped background.
    public var backgroundColor: Color?
    /// Incoming bubbles and cards. Default: a system fill.
    public var incomingBackgroundColor: Color?
    /// Incoming message text. Default: the primary label colour.
    public var incomingForegroundColor: Color?

    /// Navigation title. Default: the localized "Support".
    public var title: String?
    /// Heading above the conversation. Default: the localized "How can we help?".
    public var welcomeTitle: String?
    /// Supporting text below the heading. Default: the localized "We usually reply within a few hours.".
    public var welcomeText: String?

    /// System font design for chat text.
    public var fontDesign: FontDesign?
    /// Bubble and card corner style.
    public var cornerStyle: CornerStyle?
    /// Light, dark or following the system.
    public var colorScheme: ColorSchemePreference?
    /// Whether the SDK sheet shows a close button. Default: `true`.
    public var showsCloseButton: Bool?
    /// Symbol for the close button.
    public var closeIcon: CloseIcon
    /// Icon above the welcome heading. Default: a chat bubble symbol in the accent colour.
    public var welcomeIcon: WelcomeIcon?
    /// Draw older outgoing bubbles slightly lighter. Default: `false`.
    public var fadesOlderMessages: Bool?

    public init() {
        closeIcon = .xmark
    }

    public enum FontDesign: String, Sendable, CaseIterable {
        case `default`, rounded, serif, monospaced
    }

    public enum CornerStyle: String, Sendable, CaseIterable {
        /// Fully rounded, iMessage-like bubbles.
        case round
        /// Gently rounded corners.
        case soft
        /// Nearly square corners.
        case square
    }

    public enum ColorSchemePreference: String, Sendable, CaseIterable {
        case system, light, dark
    }

    public enum CloseIcon: String, Sendable, CaseIterable {
        case xmark
        case chevronDown = "chevron.down"
        case arrowDown = "arrow.down"
    }

    public enum WelcomeIcon: Sendable {
        /// An SF Symbol drawn in the accent colour.
        case symbol(String)
        /// An image from your app, drawn with its own colours.
        case image(Image)
        /// An image loaded from a URL.
        case url(URL)
        /// No icon.
        case hidden
    }
}
