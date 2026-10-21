import SwiftUI

public struct ReaderFloatingBar: View {
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onOpenChaptersList: () -> Void
    let onOpenSettings: () -> Void
    let onOpenComments: () -> Void
    let onReportOrReload: () -> Void
    let onScrollToTop: () -> Void
    
    public init(
        hasPrevious: Bool,
        hasNext: Bool,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onOpenChaptersList: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenComments: @escaping () -> Void,
        onReportOrReload: @escaping () -> Void,
        onScrollToTop: @escaping () -> Void
    ) {
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onOpenChaptersList = onOpenChaptersList
        self.onOpenSettings = onOpenSettings
        self.onOpenComments = onOpenComments
        self.onReportOrReload = onReportOrReload
        self.onScrollToTop = onScrollToTop
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            // 1. Previous Chapter (<)
            BarIconButton(
                systemName: "chevron.left",
                isEnabled: hasPrevious,
                action: onPrevious
            )
            
            // 2. Chapters List Sheet (≡)
            BarIconButton(
                systemName: "list.bullet",
                action: onOpenChaptersList
            )
            
            // 3. Settings (⚙)
            BarIconButton(
                systemName: "gearshape",
                action: onOpenSettings
            )
            
            // 4. Comments / Info (💬)
            BarIconButton(
                systemName: "bubble.left",
                action: onOpenComments
            )
            
            // 5. Warning / Reload (⚠)
            BarIconButton(
                systemName: "exclamationmark.triangle",
                action: onReportOrReload
            )
            
            // 6. Scroll to Top (↑)
            BarIconButton(
                systemName: "arrow.up",
                action: onScrollToTop
            )
            
            // 7. Next Chapter (>)
            BarIconButton(
                systemName: "chevron.right",
                isEnabled: hasNext,
                action: onNext
            )
        }
        .frame(height: 52)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.14).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
        )
        .padding(.horizontal, 24)
    }
}

private struct BarIconButton: View {
    let systemName: String
    var isEnabled: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            guard isEnabled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(isEnabled ? Color.white.opacity(0.9) : Color.white.opacity(0.25))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
