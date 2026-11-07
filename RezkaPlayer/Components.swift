import SwiftUI

struct PosterCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: item.poster)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    ZStack { Color.gray.opacity(0.25); Image(systemName: "film").foregroundStyle(.secondary) }
                default:
                    ZStack { Color.gray.opacity(0.15); ProgressView() }
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if item.isSeries {
                    Text("Сериал")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            }

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct MediaGrid: View {
    let items: [MediaItem]
    var onLastAppear: (() -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 170), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if item.id == items.last?.id { onLastAppear?() }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

struct ErrorBanner: View {
    let text: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let retry {
                Button("Повторить", action: retry).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    func rezkaDestinations() -> some View {
        navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
    }
}
