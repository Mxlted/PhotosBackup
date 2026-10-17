import Photos
import SwiftUI
import UIKit

struct FolderSelectionView: View {
    @EnvironmentObject private var albums: PhotoAlbumStore
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var queue: UploadQueue
    @Environment(\.openURL) private var openURL
    @State private var searchText = ""

    private func refreshBackedUpCounts() {
        albums.refreshBackedUpCounts(for: preferences.selectedAlbumIDs,
                                     isBackedUp: queue.backedUpAssetLookup())
    }

    private var filteredAlbums: [PhotoAlbum] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return albums.albums }
        return albums.albums.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var selectionTitle: String {
        if preferences.selectedAlbumIDs.contains(PhotoAlbum.allPhotosID) {
            return albums.isLimited ? "All available photos" : "Your whole library"
        }
        let count = preferences.selectedAlbumIDs.count
        if count == 0 { return "Choose your albums" }
        return count == 1 ? "1 album selected" : "\(count.formatted()) albums selected"
    }

    var body: some View {
        NavigationView {
            Group {
                if albums.authorization == .notDetermined {
                    permissionState
                } else if !albums.canRead {
                    deniedState
                } else if albums.isLoading {
                    ProgressView("Loading your albums…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if albums.albums.isEmpty {
                    EmptyState(symbol: "rectangle.stack", title: "Your albums will appear here", message: "Add photos to your library, then return here to choose what to back up.")
                } else {
                    albumList
                }
            }
            .background(BackupTheme.background)
            .navigationTitle("Albums")
            .searchable(text: $searchText, prompt: "Find an album")
            .onAppear {
                albums.refreshInBackground()
                refreshBackedUpCounts()
            }
            .onChange(of: preferences.selectedAlbumIDs) { _ in refreshBackedUpCounts() }
            .onChange(of: albums.albums) { _ in refreshBackedUpCounts() }
            // The completion ledger, not the rows: `items` changes on every
            // progress tick, and each of those kicked off a fresh enumeration of
            // every asset in every selected album. Only a finished upload can
            // move a "N of M backed up" count.
            .onChange(of: queue.completedSourceKeys) { _ in refreshBackedUpCounts() }
        }
        .navigationViewStyle(.stack)
    }

    private var albumList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                selectionOverview
                if albums.isLimited { limitedAccessBanner }
                backupPreferencesLink

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "Albums to back up", subtitle: "Select All Photos for your library, or choose individual albums.")
                    if filteredAlbums.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No matching albums")
                                .font(.headline)
                            Text("Try a different name.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .backupCard()
                    } else {
                        ForEach(filteredAlbums) { album in
                            AlbumSelectionRow(album: album,
                                              isSelected: preferences.selectedAlbumIDs.contains(album.id),
                                              backedUpCount: albums.backedUpCounts[album.id]) {
                                preferences.toggle(albumID: album.id)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var selectionOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                FeatureIcon(symbol: "photo.stack", size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectionTitle)
                        .font(.title3.weight(.semibold))
                    Text(preferences.selectedAlbumIDs.isEmpty
                         ? "Keep the moments that matter backed up."
                         : "These albums are checked for new photos using your backup preferences.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Label(preferences.automaticBackup ? "Automatic backup is on" : "Automatic backup is paused",
                  systemImage: preferences.automaticBackup ? "arrow.triangle.2.circlepath" : "pause.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(preferences.automaticBackup ? BackupTheme.blue : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .backupCard()
    }

    private var backupPreferencesLink: some View {
        NavigationLink(destination: BackupRulesView()) {
            HStack(spacing: 12) {
                FeatureIcon(symbol: "slider.horizontal.3", size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("What to back up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(preferences.selectionRules.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .backupCard(padding: 16)
        }
        .buttonStyle(.plain)
    }

    /// Under limited access every PhotoKit fetch is scoped to the assets the
    /// user hand-picked, so counts must not imply full-library coverage.
    private var limitedAccessBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Some photos are hidden", systemImage: "photo.badge.checkmark")
                .font(.subheadline.weight(.semibold))
            Text("You’ve allowed access to selected photos. Album counts and backups include only those photos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Manage photo access") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .backupCard()
    }

    private var permissionState: some View {
        VStack(spacing: 18) {
            Spacer()
            EmptyState(symbol: "photo.on.rectangle.angled", title: "Choose what to protect", message: "Allow access to your photos, then pick the albums you’d like to back up.")
            Button("Choose Photo Access") { Task { await albums.requestAccess() } }
                .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            Spacer()
        }
    }

    private var deniedState: some View {
        VStack(spacing: 18) {
            Spacer()
            EmptyState(symbol: "photo.badge.exclamationmark", title: "Photo access is off", message: "Allow access in Settings to choose albums and back up your photos.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            Spacer()
        }
    }
}
