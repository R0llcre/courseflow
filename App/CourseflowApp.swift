import SwiftUI

@main
struct CourseflowApp: App {
    @State private var store = LibraryStore()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .tint(Color("AccentColor"))
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.timeZone, TimeZone(identifier: "America/Los_Angeles")!)
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 590)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1160, height: 800)
        .windowToolbarStyle(.unified)
        #endif
        #if os(macOS)
        Settings { AppSettings(store: store).frame(width: 440).padding(24) }
        #endif
    }
}

enum Palette {
    static let ink = Color.primary
    static let paper = Color("Paper")
    static let canvas = Color("Canvas")
    static func course(_ name: String) -> Color {
        switch name {
        case "teal": .teal
        case "amber": .orange
        case "purple": .purple
        case "indigo": .indigo
        case "pink": .pink
        default: .blue
        }
    }
}

enum SectionRoute: String, CaseIterable, Identifiable {
    case today = "今天", schedule = "日程", review = "评分跟进", courses = "课程", inbox = "收件箱"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .schedule: "calendar"
        case .review: "text.badge.checkmark"
        case .courses: "books.vertical"
        case .inbox: "tray"
        }
    }
}
