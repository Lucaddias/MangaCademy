import SwiftUI

public struct BadgeView: View {
    let text: String
    var color: Color = .blue
    
    public init(_ text: String, color: Color = .blue) {
        self.text = text
        self.color = color
    }
    
    public var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
