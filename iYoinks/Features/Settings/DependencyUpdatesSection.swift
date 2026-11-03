import SwiftUI

struct DependencyUpdatesSection: View {
    @ObservedObject private var dependencies = ExtractorDependencies.shared
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        Section {
            ForEach(dependencies.packages) { package in
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(package.id.title)
                            .font(AppTypography.font(.body, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Text(versionLabel(package))
                            .font(AppTypography.font(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                        if package.pendingRestart {
                            Text("Downloaded. Reopen yoink'd to finish.")
                                .font(AppTypography.font(.caption))
                                .foregroundStyle(theme.secondaryText)
                        } else if package.id == .ytDLP, package.canUpdate {
                            Text("Includes matching EJS when needed.")
                                .font(AppTypography.font(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                        if let error = package.error {
                            Text(error)
                                .font(AppTypography.font(.caption))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if package.isWorking {
                        if let progress = package.progress {
                            ProgressView(value: progress)
                                .frame(width: 54)
                                .accessibilityLabel("\(package.id.title) download")
                        } else {
                            ProgressView()
                                .accessibilityLabel("Downloading \(package.id.title)")
                        }
                    } else if package.canUpdate {
                        Button(package.installedVersion == nil ? "Get" : "Update") {
                            Task { await dependencies.update(package.id) }
                        }
                        .font(AppTypography.font(.subheadline, weight: .semibold))
                        .buttonStyle(AppSecondaryButtonStyle())
                        .disabled(dependencies.isUpdating || package.pendingRestart)
                        .accessibilityLabel("\(package.installedVersion == nil ? "Get" : "Update") \(package.id.title)")
                    } else if package.latestVersion != nil, package.latestVersion == package.installedVersion, package.error == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityLabel("\(package.id.title) is up to date")
                    }
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 16) {
                Button("Check for updates") {
                    Task { await dependencies.checkForUpdates() }
                }
                Spacer(minLength: 0)
                Button("Update all") {
                    Task { await dependencies.updateAll() }
                }
                .disabled(!dependencies.packages.contains(where: \.canUpdate))
            }
            .font(AppTypography.font(.subheadline, weight: .medium))
            .buttonStyle(.borderless)
            .disabled(dependencies.isUpdating)
            if let status = dependencies.status {
                Text(status)
                    .font(AppTypography.font(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Extraction updates")
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                if let lastChecked = dependencies.lastChecked {
                    Text("Last checked \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                }
                Text("Source packages update from PyPI. Imports and direct downloads work without them.")
            }
            .font(AppTypography.font(.caption))
        }
        Section("Bundled runtime") {
            ForEach(dependencies.nativeVersions.keys.sorted(), id: \.self) { name in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 16) {
                        Text(name)
                            .foregroundStyle(theme.primaryText)
                        Spacer(minLength: 0)
                        Text(dependencies.nativeVersions[name] ?? "")
                            .foregroundStyle(theme.secondaryText)
                    }
                    .font(AppTypography.font(.subheadline))
                    Text("Bundled. App update required.")
                        .font(AppTypography.font(.caption))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func versionLabel(_ package: ExtractorPackageStatus) -> String {
        guard let installed = package.installedVersion else { return "Not installed" }
        if let latest = package.latestVersion, latest != installed {
            return "Installed \(installed). Available \(latest)"
        }
        return "Installed \(installed)"
    }
}
