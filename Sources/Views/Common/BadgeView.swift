import SwiftUI

public struct BadgeView: View {
    let text: String
    var color: Color = Theme.accent

    public init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color ?? Theme.accent
    }

    public var body: some View {
        Text(text)
            .font(.caption2.bold())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
