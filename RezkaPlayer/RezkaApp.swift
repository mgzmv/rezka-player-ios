import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            DownloadManager.shared.backgroundCompletion = completionHandler
        }
    }
}

@main
struct RezkaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UserStore.shared
    @StateObject private var downloads = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(downloads)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Главная", systemImage: "house.fill") }
            SearchView()
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
            LibraryView()
                .tabItem { Label("Моё", systemImage: "books.vertical.fill") }
            DownloadsView()
                .tabItem { Label("Загрузки", systemImage: "arrow.down.circle.fill") }
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
        }
    }
}
