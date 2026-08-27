import AppKit
import Carbon.HIToolbox
import CoreServices
import Foundation
import QuickLookUI

private enum ItemKind {
    case website
    case fileType
    case application
    case recommendation
    case file
    case folder
}

private struct SearchItem {
    let kind: ItemKind
    let title: String
    let subtitle: String
    let url: URL
    let score: Int
    let modifiedAt: Date
}

private struct IndexedFile {
    let url: URL
    let name: String
    let modifiedAt: Date
    let isDirectory: Bool
}

private struct HiddenConfigActivity {
    let url: URL
    let modifiedAt: Date
    let recentChanges: Int
    let isDirectory: Bool
    let reachedLimit: Bool
}

private struct InstalledApplication {
    let url: URL
    let name: String
    let searchable: String
    let bundleID: String
    let useCount: Int
    let lastUsedAt: Date?
    let isRunning: Bool
}

private struct Bookmark: Decodable {
    let title: String
    let url: String
    let keywords: [String]
}

private let appAliases: [String: [String]] = [
    "com.liguangming.Shadowrocket": ["小火箭", "代理", "shadow rocket"]
]

private let fileTypeCatalog: [(extension: String, label: String)] = [
    ("pdf", "PDF 文档"),
    ("md", "Markdown 文档"),
    ("docx", "Word 文档"),
    ("xlsx", "Excel 表格"),
    ("pptx", "PowerPoint 演示"),
    ("png", "PNG 图片"),
    ("webp", "WebP 图片"),
    ("jpg", "JPEG 图片"),
    ("mp4", "MP4 视频"),
    ("txt", "纯文本"),
    ("csv", "CSV 数据"),
    ("zip", "ZIP 压缩包"),
    ("py", "Python 源码")
]

private func loadBookmarks() -> [Bookmark] {
    guard let url = Bundle.main.url(forResource: "bookmarks", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data)
    else { return [] }
    return bookmarks.filter {
        guard let url = URL(string: $0.url) else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }
}

private func bookmarkResults(query: String, bookmarks: [Bookmark]) -> [SearchItem] {
    bookmarks.enumerated().compactMap { index, bookmark in
        let scores = ([bookmark.title] + bookmark.keywords).compactMap {
            fuzzyScore(query: query, candidate: $0)
        }
        guard let score = scores.min(), let url = URL(string: bookmark.url) else { return nil }
        return SearchItem(
            kind: .website,
            title: bookmark.title,
            subtitle: bookmark.url,
            url: url,
            score: score * 100 + index,
            modifiedAt: .distantPast
        )
    }
    .sorted { $0.score < $1.score }
    .prefix(8)
    .map { $0 }
}

private func fileExtensionQuery(_ query: String) -> String? {
    let trimmed = normalizedSearchInput(query).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.hasPrefix("."), trimmed.count > 1 else { return nil }
    let value = String(trimmed.dropFirst())
    guard value.count <= 10, value.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    return value
}

private func normalizedSearchInput(_ text: String) -> String {
    text.replacingOccurrences(of: "。", with: ".")
        .replacingOccurrences(of: "．", with: ".")
        .replacingOccurrences(of: "，", with: ",")
        .replacingOccurrences(of: "＠", with: "@")
}

private func hiddenConfigQuery(_ query: String) -> String? {
    let trimmed = normalizedSearchInput(query).trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("@") else { return nil }
    return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func spaceQuickLookEligible(query: String, kind: ItemKind) -> Bool {
    guard fileExtensionQuery(query) != nil || hiddenConfigQuery(query) != nil else { return false }
    switch kind {
    case .file, .folder: return true
    default: return false
    }
}

private func hiddenConfigActivity(at url: URL, now: Date, scanLimit: Int = 5_000) -> HiddenConfigActivity {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
    let values = try? url.resourceValues(forKeys: keys)
    let isDirectory = values?.isDirectory == true
    var latest = values?.contentModificationDate ?? .distantPast
    let cutoff = now.addingTimeInterval(-30 * 86_400)
    var recentChanges = !isDirectory && latest >= cutoff ? 1 : 0
    var checked = 0
    var reachedLimit = false

    if isDirectory, values?.isSymbolicLink != true,
       let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsPackageDescendants]
       ) {
        let ignoredDirectories = Set([".git", "node_modules", "Caches", "Cache", "cache", "tmp"])
        while let child = enumerator.nextObject() as? URL {
            checked += 1
            if checked > scanLimit {
                reachedLimit = true
                break
            }
            let childValues = try? child.resourceValues(forKeys: keys)
            if childValues?.isDirectory == true, ignoredDirectories.contains(child.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard childValues?.isDirectory != true else { continue }
            let modifiedAt = childValues?.contentModificationDate ?? .distantPast
            latest = max(latest, modifiedAt)
            if modifiedAt >= cutoff { recentChanges += 1 }
        }
    }

    return HiddenConfigActivity(
        url: url,
        modifiedAt: latest,
        recentChanges: recentChanges,
        isDirectory: isDirectory,
        reachedLimit: reachedLimit
    )
}

private func hiddenConfigResults(query: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [SearchItem] {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
    let ignored = Set([".DS_Store", ".Trash", ".cache", ".localized"])
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: home,
        includingPropertiesForKeys: Array(keys),
        options: []
    )) ?? []

    return urls.compactMap { url -> SearchItem? in
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.count > 1, !ignored.contains(name) else { return nil }
        let matchScore: Int
        if query.isEmpty {
            matchScore = 0
        } else {
            guard let score = fuzzyScore(query: query, candidate: name), score < 100 else { return nil }
            matchScore = score
        }
        let activity = hiddenConfigActivity(at: url, now: now)
        let count = "\(activity.recentChanges)\(activity.reachedLimit ? "+" : "")"
        let date = activity.modifiedAt == .distantPast
            ? "未知时间"
            : DateFormatter.localizedString(from: activity.modifiedAt, dateStyle: .short, timeStyle: .short)
        return SearchItem(
            kind: activity.isDirectory ? .folder : .file,
            title: name,
            subtitle: "近 30 天改动 \(count) 项 · \(date) · \(url.path)",
            url: url,
            score: matchScore * 10_000 - min(activity.recentChanges, 9_999),
            modifiedAt: activity.modifiedAt
        )
    }
    .sorted { $0.score == $1.score ? $0.modifiedAt > $1.modifiedAt : $0.score < $1.score }
    .prefix(40)
    .map { $0 }
}

private func fileTypeSuggestions() -> [SearchItem] {
    fileTypeCatalog.enumerated().map { index, type in
        SearchItem(
            kind: .fileType,
            title: ".\(type.extension)",
            subtitle: "\(type.label) · 按最近修改时间排序",
            url: URL(fileURLWithPath: "/"),
            score: index,
            modifiedAt: .distantPast
        )
    }
}

private func isSearchNoisePath(_ path: String) -> Bool {
    ["/Library/", "/.git/", "/node_modules/", "/.venv/", "/venv/", "/site-packages/", "/dist/", "/build/"]
        .contains(where: path.contains)
}

private func datedPathSubtitle(url: URL, modifiedAt: Date) -> String {
    guard modifiedAt != .distantPast else { return url.deletingLastPathComponent().path }
    let date = DateFormatter.localizedString(from: modifiedAt, dateStyle: .short, timeStyle: .short)
    return "\(date) · \(url.deletingLastPathComponent().path)"
}

private func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .filter { $0.isLetter || $0.isNumber }
        .lowercased()
}

private func fuzzyScore(query: String, candidate: String) -> Int? {
    let needle = Array(normalized(query))
    let haystack = Array(normalized(candidate))
    guard !needle.isEmpty else { return 0 }

    let normalizedNeedle = String(needle)
    let normalizedHaystack = String(haystack)
    if normalizedNeedle == normalizedHaystack { return 0 }
    if normalizedHaystack.hasPrefix(normalizedNeedle) { return 10 }
    if let range = normalizedHaystack.range(of: normalizedNeedle) {
        return 20 + normalizedHaystack.distance(from: normalizedHaystack.startIndex, to: range.lowerBound)
    }

    var queryIndex = 0
    var firstMatch = 0
    var lastMatch = 0
    for (index, character) in haystack.enumerated() where queryIndex < needle.count {
        if character == needle[queryIndex] {
            if queryIndex == 0 { firstMatch = index }
            lastMatch = index
            queryIndex += 1
        }
    }
    guard queryIndex == needle.count else { return nil }
    return 100 + firstMatch + (lastMatch - firstMatch - needle.count)
}

private func installedApplications() -> [InstalledApplication] {
    let roots = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]
    var seen = Set<String>()
    var applications: [InstalledApplication] = []
    let runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap {
        $0.bundleURL?.standardizedFileURL.path
    })

    for root in roots where FileManager.default.fileExists(atPath: root.path) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isApplicationKey, .localizedNameKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }

        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            let metadata = MDItemCreate(kCFAllocatorDefault, path as CFString)
            let name = metadata.flatMap { MDItemCopyAttribute($0, "kMDItemDisplayName" as CFString) } as? String
                ?? url.deletingPathExtension().lastPathComponent
            let bundleID = metadata.flatMap { MDItemCopyAttribute($0, "kMDItemCFBundleIdentifier" as CFString) } as? String ?? ""
            let aliases = appAliases[bundleID, default: []].joined(separator: " ")
            let useCount = (metadata.flatMap { MDItemCopyAttribute($0, "kMDItemUseCount" as CFString) } as? NSNumber)?.intValue ?? 0
            let lastUsedAt = metadata.flatMap { MDItemCopyAttribute($0, "kMDItemLastUsedDate" as CFString) } as? Date
            applications.append(InstalledApplication(
                url: url,
                name: name,
                searchable: [name, bundleID, aliases].joined(separator: " "),
                bundleID: bundleID,
                useCount: useCount,
                lastUsedAt: lastUsedAt,
                isRunning: runningPaths.contains(path)
            ))
        }
    }
    return applications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private func recommendationScore(_ app: InstalledApplication, now: Date = Date()) -> Double {
    let ageDays = app.lastUsedAt.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 60
    let frequency = log2(Double(max(0, app.useCount)) + 1) * 15
    let recency = max(0, 30 - ageDays) * 4
    return frequency + recency - min(ageDays, 180) + (app.isRunning ? 10 : 0)
}

private func recommendedApplications(
    _ applications: [InstalledApplication],
    excluding bundleID: String?,
    now: Date = Date()
) -> [InstalledApplication] {
    applications
        .filter { app in
            app.bundleID != "com.tang.miaosou"
                && app.bundleID != bundleID
                && (app.useCount > 0 || app.lastUsedAt != nil || app.isRunning)
        }
        .sorted {
            let left = recommendationScore($0, now: now)
            let right = recommendationScore($1, now: now)
            return left == right ? $0.name < $1.name : left > right
        }
}

private func recommendationSubtitle(_ app: InstalledApplication, now: Date = Date()) -> String {
    var details: [String] = []
    if app.isRunning { details.append("正在运行") }
    if app.useCount > 0 { details.append("使用 \(app.useCount) 次") }
    if let lastUsedAt = app.lastUsedAt {
        let days = max(0, Int(now.timeIntervalSince(lastUsedAt) / 86_400))
        details.append(days == 0 ? "今天使用" : "\(days) 天前")
    }
    return details.isEmpty ? app.url.path : details.joined(separator: " · ")
}

private func defaultSearchRoots() -> [URL] {
    let manager = FileManager.default
    let directories: [FileManager.SearchPathDirectory] = [
        .desktopDirectory, .documentDirectory, .downloadsDirectory
    ]
    let roots = directories.compactMap { manager.urls(for: $0, in: .userDomainMask).first }
    return Array(Dictionary(grouping: roots, by: \.standardizedFileURL.path).values.compactMap(\.first))
}

private let skippedDirectoryNames = [
    ".git", "node_modules", ".venv", "venv", "site-packages", "deriveddata", "build", "dist"
]

private func shouldSkipDirectory(_ name: String) -> Bool {
    skippedDirectoryNames.contains(name.lowercased())
}

private func scanLocalRoot(_ root: URL) -> [IndexedFile] {
    let manager = FileManager.default
    guard manager.fileExists(atPath: root.path) else { return [] }

    let maxDepth = 3
    let perRootLimit = 50_000
    let process = Process()
    let pipe = Pipe()
    let readerFinished = DispatchSemaphore(value: 0)
    let outputLock = NSLock()
    var output = Data()

    var arguments = ["-x", root.path, "("]
    let pruneNames = [".*"] + skippedDirectoryNames + ["*.app", "*.photoslibrary"]
    for (index, name) in pruneNames.enumerated() {
        if index > 0 { arguments.append("-o") }
        arguments += ["-name", name]
    }
    arguments += [
        "-o", "-path", root.path + String(repeating: "/*", count: maxDepth),
        ")", "-prune", "-o", "-print0"
    ]

    process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        DispatchQueue(label: "com.tang.miaosou.find-reader").async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                outputLock.lock()
                output.append(chunk)
                outputLock.unlock()
            }
            readerFinished.signal()
        }
        process.waitUntilExit()
    } catch {
        return []
    }

    readerFinished.wait()

    outputLock.lock()
    let data = output
    outputLock.unlock()
    return data.split(separator: 0).prefix(perRootLimit).compactMap { bytes in
        guard let path = String(data: Data(bytes), encoding: .utf8), path != root.path else { return nil }
        let url = URL(fileURLWithPath: path)
        return IndexedFile(url: url, name: url.lastPathComponent, modifiedAt: .distantPast, isDirectory: false)
    }
}

private func buildLocalFileIndex() -> [IndexedFile] {
    defaultSearchRoots().flatMap(scanLocalRoot)
}

private func directFileMatches(query: String, files: [IndexedFile]) -> [SearchItem] {
    files.compactMap { file in
        guard let score = fuzzyScore(query: query, candidate: file.name), score < 100 else { return nil }
        let values = try? file.url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory ?? file.isDirectory
        let modifiedAt = values?.contentModificationDate ?? file.modifiedAt
        return SearchItem(
            kind: isDirectory ? .folder : .file,
            title: file.name,
            subtitle: file.url.deletingLastPathComponent().path,
            url: file.url,
            score: score,
            modifiedAt: modifiedAt
        )
    }
    .sorted { $0.score == $1.score ? $0.modifiedAt > $1.modifiedAt : $0.score < $1.score }
    .prefix(24)
    .map { $0 }
}

private final class ResultCell: NSTableCellView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let badgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabel.alignment = .center
        badgeLabel.drawsBackground = true
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 7

        [iconView, titleLabel, subtitleLabel, badgeLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 38),
            iconView.heightAnchor.constraint(equalToConstant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            badgeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
            badgeLabel.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class SearchViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource {
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerLabel = NSTextField(labelWithString: "↑↓ 选择   Space 预览文件   ↩ 打开   ⌘↩ 在访达显示   可拖动文件   ⌘Space 显示/隐藏")
    private var applications = installedApplications()
    private let bookmarks = loadBookmarks()
    private var websiteResults: [SearchItem] = []
    private var appResults: [SearchItem] = []
    private var fileResults: [SearchItem] = []
    private var indexedFiles: [IndexedFile] = []
    private var isIndexingFiles = true
    private var isSearchingHiddenConfigs = false
    private var excludedRecommendationBundleID: String?
    private var lastApplicationRefresh = Date()
    private var isRefreshingApplications = false
    private var fileSearchProcess: Process?
    private var fileSearchWorkItem: DispatchWorkItem?
    private var quickLookKeyMonitor: Any?
    private var previewedURL: URL?
    private var searchGeneration = 0
    private(set) var results: [SearchItem] = []

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        view = effectView

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderAttributedString = NSAttributedString(
            string: "搜索应用、文件或网站",
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        searchField.font = .systemFont(ofSize: 18, weight: .medium)
        searchField.controlSize = .large
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .default
        searchField.delegate = self

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(openSelected)
        tableView.target = self
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        let resultMenu = NSMenu()
        let revealItem = resultMenu.addItem(withTitle: "在访达中显示", action: #selector(revealSelectedInFinder), keyEquivalent: "")
        revealItem.target = self
        tableView.menu = resultMenu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.alignment = .center

        [searchField, statusLabel, scrollView, footerLabel].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            searchField.heightAnchor.constraint(equalToConstant: 48),
            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 2),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),
            footerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            footerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            footerLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
        updateResults()
        refreshFileIndex()
        quickLookKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Space),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  QLPreviewPanel.sharedPreviewPanelExists(),
                  QLPreviewPanel.shared()?.isVisible == true
            else { return event }
            self?.closeQuickLook()
            return nil
        }
    }

    deinit {
        if let quickLookKeyMonitor { NSEvent.removeMonitor(quickLookKeyMonitor) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        let height = max(scrollView.contentSize.height, CGFloat(results.count) * (tableView.rowHeight + tableView.intercellSpacing.height))
        tableView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        tableView.tableColumns.first?.width = width
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewedURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewedURL as NSURL?
    }

    private func selectedPreviewURL() -> URL? {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        guard results.indices.contains(row),
              spaceQuickLookEligible(query: searchField.stringValue, kind: results[row].kind)
        else { return nil }
        return results[row].url
    }

    private func toggleQuickLook() {
        guard let url = selectedPreviewURL(), let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            closeQuickLook()
            return
        }
        previewedURL = url
        panel.updateController()
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func handleSpaceKey() -> Bool {
        guard selectedPreviewURL() != nil else { return false }
        toggleQuickLook()
        return true
    }

    func closeQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
        }
        previewedURL = nil
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func showRecommendations(excluding bundleID: String?) {
        excludedRecommendationBundleID = bundleID
        clearSearch()
        guard !isRefreshingApplications, Date().timeIntervalSince(lastApplicationRefresh) >= 60 else { return }
        isRefreshingApplications = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let refreshed = installedApplications()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applications = refreshed
                self.lastApplicationRefresh = Date()
                self.isRefreshingApplications = false
                if self.searchField.stringValue.isEmpty { self.updateResults() }
            }
        }
    }

    func refreshApplications() {
        applications = installedApplications()
        refreshFileIndex()
        updateResults()
    }

    func clearSearch() {
        closeQuickLook()
        searchField.stringValue = ""
        fileSearchWorkItem?.cancel()
        fileSearchProcess?.terminate()
        isSearchingHiddenConfigs = false
        fileResults = []
        updateResults()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard results.indices.contains(row) else { return nil }
        switch results[row].kind {
        case .file, .folder:
            return results[row].url as NSURL
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ResultCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCell ?? ResultCell()
        cell.identifier = identifier
        let item = results[row]
        cell.titleLabel.stringValue = item.title
        cell.subtitleLabel.stringValue = item.subtitle
        switch item.kind {
        case .website:
            cell.iconView.image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "网站")
            cell.badgeLabel.stringValue = "网站"
            cell.badgeLabel.textColor = .systemBlue
            cell.badgeLabel.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10)
        case .fileType:
            cell.iconView.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "文件类型")
                ?? NSImage(systemSymbolName: "doc", accessibilityDescription: "文件类型")
            cell.badgeLabel.stringValue = "类型"
            cell.badgeLabel.textColor = .systemTeal
            cell.badgeLabel.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.10)
        case .recommendation:
            cell.iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.badgeLabel.stringValue = "推荐"
            cell.badgeLabel.textColor = .systemIndigo
            cell.badgeLabel.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.10)
        case .application:
            cell.iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.badgeLabel.stringValue = "应用"
            cell.badgeLabel.textColor = .secondaryLabelColor
            cell.badgeLabel.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        case .file:
            cell.iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.badgeLabel.stringValue = "文件"
            cell.badgeLabel.textColor = .secondaryLabelColor
            cell.badgeLabel.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        case .folder:
            cell.iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.badgeLabel.stringValue = "文件夹"
            cell.badgeLabel.textColor = .secondaryLabelColor
            cell.badgeLabel.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
        }
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        closeQuickLook()
        let input = normalizedSearchInput(searchField.stringValue)
        if input != searchField.stringValue {
            let selection = searchField.currentEditor()?.selectedRange
            searchField.stringValue = input
            if let selection { searchField.currentEditor()?.selectedRange = selection }
        }
        performSearch()
    }

    private func performSearch() {
        searchGeneration += 1
        fileSearchWorkItem?.cancel()
        fileSearchProcess?.terminate()
        fileResults = []
        let query = searchField.stringValue
        isSearchingHiddenConfigs = hiddenConfigQuery(query) != nil
        updateResults()
        guard query != ".", !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = searchGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, generation == self.searchGeneration else { return }
            self.searchFiles(query: query, generation: generation)
        }
        fileSearchWorkItem = workItem
        let delay = fileExtensionQuery(query) == nil ? 0.12 : 0.05
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty { view.window?.orderOut(nil) } else { clearSearch() }
            return true
        default:
            return false
        }
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = tableView.selectedRow < 0 ? (offset > 0 ? -1 : 0) : tableView.selectedRow
        let next = min(max(current + offset, 0), results.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc func openSelected() {
        guard !results.isEmpty else { return }
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let item = results[row]
        closeQuickLook()
        if item.kind == .fileType {
            searchField.stringValue = item.title
            performSearch()
            return
        }
        if item.kind == .website {
            openWebsiteInChrome(item.url)
            view.window?.orderOut(nil)
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            revealSelectedInFinder()
            return
        } else {
            NSWorkspace.shared.open(item.url)
        }
        view.window?.orderOut(nil)
    }

    @objc private func revealSelectedInFinder() {
        guard results.indices.contains(tableView.selectedRow) else { return }
        let item = results[tableView.selectedRow]
        switch item.kind {
        case .file, .folder:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-R", item.url.path]
            try? process.run()
            view.window?.orderOut(nil)
        default:
            return
        }
    }

    private func openWebsiteInChrome(_ url: URL) {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
        }
    }

    private func updateResults() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            websiteResults = []
            let recommendations = recommendedApplications(applications, excluding: excludedRecommendationBundleID)
            let visibleApps = recommendations.isEmpty ? Array(applications.prefix(10)) : Array(recommendations.prefix(10))
            appResults = visibleApps.enumerated().map { index, app in
                SearchItem(
                    kind: recommendations.isEmpty ? .application : .recommendation,
                    title: app.name,
                    subtitle: recommendations.isEmpty ? app.url.path : recommendationSubtitle(app),
                    url: app.url,
                    score: index,
                    modifiedAt: app.lastUsedAt ?? .distantPast
                )
            }
            let fileStatus = isIndexingFiles ? "正在整理常用文件…" : "直接索引 \(indexedFiles.count) 项"
            statusLabel.stringValue = recommendations.isEmpty
                ? "已找到 \(applications.count) 个应用 · \(fileStatus)"
                : "推荐打开 · 最近和常用优先 · \(fileStatus)"
        } else if hiddenConfigQuery(query) != nil {
            websiteResults = []
            appResults = []
            statusLabel.stringValue = isSearchingHiddenConfigs
                ? "正在统计隐藏配置活跃度…"
                : (fileResults.isEmpty ? "没有找到匹配的隐藏配置" : "隐藏配置 · \(fileResults.count) 项 · 近 30 天改动优先")
        } else if query == "." {
            websiteResults = []
            appResults = []
            fileResults = []
            statusLabel.stringValue = "选择文件类型 · 回车查看全部 · 最近修改优先"
        } else if let fileExtension = fileExtensionQuery(query) {
            websiteResults = []
            appResults = []
            if fileSearchProcess != nil {
                statusLabel.stringValue = "正在查找所有 .\(fileExtension) 文件…"
            } else if fileResults.isEmpty {
                statusLabel.stringValue = "没有找到 .\(fileExtension) 文件"
            } else {
                statusLabel.stringValue = ".\(fileExtension) 文件 · \(fileResults.count) 个 · 最近修改优先"
            }
        } else {
            websiteResults = bookmarkResults(query: query, bookmarks: bookmarks)
            appResults = applications.compactMap { app in
                guard let score = fuzzyScore(query: query, candidate: app.searchable) else { return nil }
                return SearchItem(kind: .application, title: app.name, subtitle: app.url.path, url: app.url, score: score, modifiedAt: .distantPast)
            }
            .sorted { $0.score == $1.score ? $0.title < $1.title : $0.score < $1.score }
            .prefix(10)
            .map { $0 }
            statusLabel.stringValue = !websiteResults.isEmpty
                ? "网站优先 · 回车用 Chrome 打开"
                : (fileResults.isEmpty && isIndexingFiles ? "正在整理常用文件…" : "应用优先 · 文件和文件夹直接检索")
        }

        if hiddenConfigQuery(query) != nil {
            results = fileResults
        } else if query == "." {
            results = fileTypeSuggestions()
        } else if fileExtensionQuery(query) != nil {
            results = fileResults
        } else {
            results = websiteResults + Array(appResults.prefix(10)) + Array(fileResults.prefix(12))
        }
        tableView.reloadData()
        view.needsLayout = true
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func searchFiles(query: String, generation: Int) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hiddenQuery = hiddenConfigQuery(term) {
            let items = hiddenConfigResults(query: hiddenQuery)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searchGeneration else { return }
                self.isSearchingHiddenConfigs = false
                self.fileResults = items
                self.updateResults()
            }
            return
        }
        if let fileExtension = fileExtensionQuery(term) {
            searchFilesByExtension(fileExtension, generation: generation)
            return
        }
        guard !normalized(term).isEmpty else { return }
        let directIndex = indexedFiles

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let directItems = directFileMatches(query: term, files: directIndex)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searchGeneration else { return }
                self.fileResults = Array(directItems.prefix(12))
                self.updateResults()
            }
            let publish: ([SearchItem]) -> Void = { metadataItems in
                var seen = Set<String>()
                let merged = (directItems + metadataItems)
                    .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
                    .sorted { $0.score == $1.score ? $0.modifiedAt > $1.modifiedAt : $0.score < $1.score }
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.searchGeneration else { return }
                    self.fileSearchProcess = nil
                    self.fileResults = Array(merged.prefix(12))
                    self.updateResults()
                }
            }

            guard normalized(term).count >= 2 else {
                publish([])
                return
            }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", FileManager.default.homeDirectoryForCurrentUser.path, "-name", term]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searchGeneration else { return }
                self.fileSearchProcess = process
            }

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard !process.isRunning else { return }
                let paths = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
                let items = paths.prefix(120).compactMap { path -> SearchItem? in
                    guard !isSearchNoisePath(path) else { return nil }
                    let url = URL(fileURLWithPath: path)
                    guard url.pathExtension.lowercased() != "app" else { return nil }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                    return SearchItem(
                        kind: values?.isDirectory == true ? .folder : .file,
                        title: url.lastPathComponent,
                        subtitle: url.deletingLastPathComponent().path,
                        url: url,
                        score: fuzzyScore(query: term, candidate: url.lastPathComponent) ?? 500,
                        modifiedAt: values?.contentModificationDate ?? .distantPast
                    )
                }.filter { $0.score < 100 }
                publish(items)
            } catch {
                publish([])
            }
        }
    }

    private func searchFilesByExtension(_ fileExtension: String, generation: Int) {
        let directIndex = indexedFiles
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let directItems = directIndex.compactMap { file -> SearchItem? in
                guard file.url.pathExtension.lowercased() == fileExtension else { return nil }
                let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory != true else { return nil }
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                return SearchItem(
                    kind: .file,
                    title: file.url.lastPathComponent,
                    subtitle: datedPathSubtitle(url: file.url, modifiedAt: modifiedAt),
                    url: file.url,
                    score: 0,
                    modifiedAt: modifiedAt
                )
            }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = [
                "-onlyin", FileManager.default.homeDirectoryForCurrentUser.path,
                "kMDItemFSName == '*.\(fileExtension)'cd"
            ]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searchGeneration else { return }
                self.fileSearchProcess = process
                self.fileResults = directItems.sorted { $0.modifiedAt > $1.modifiedAt }
                self.updateResults()
            }

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let paths = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
                let metadataItems = paths.compactMap { path -> SearchItem? in
                    guard !isSearchNoisePath(path) else { return nil }
                    let url = URL(fileURLWithPath: path)
                    guard url.pathExtension.lowercased() == fileExtension else { return nil }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                    guard values?.isDirectory != true else { return nil }
                    let modifiedAt = values?.contentModificationDate ?? .distantPast
                    return SearchItem(
                        kind: .file,
                        title: url.lastPathComponent,
                        subtitle: datedPathSubtitle(url: url, modifiedAt: modifiedAt),
                        url: url,
                        score: 0,
                        modifiedAt: modifiedAt
                    )
                }

                var seen = Set<String>()
                let merged = (directItems + metadataItems)
                    .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
                    .sorted { $0.modifiedAt > $1.modifiedAt }
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.searchGeneration else { return }
                    self.fileSearchProcess = nil
                    self.fileResults = merged
                    self.updateResults()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.searchGeneration else { return }
                    self.fileSearchProcess = nil
                    self.fileResults = directItems.sorted { $0.modifiedAt > $1.modifiedAt }
                    self.updateResults()
                }
            }
        }
    }

    private func refreshFileIndex() {
        isIndexingFiles = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let files = buildLocalFileIndex()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.indexedFiles = files
                self.isIndexingFiles = false
                self.updateResults()
                let query = self.searchField.stringValue
                guard !normalized(query).isEmpty else { return }
                self.searchGeneration += 1
                self.fileSearchWorkItem?.cancel()
                self.fileSearchProcess?.terminate()
                self.searchFiles(query: query, generation: self.searchGeneration)
            }
        }
    }
}

private final class LauncherWindow: NSWindow {
    var spaceHandler: (() -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == UInt16(kVK_Space),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           spaceHandler?() == true {
            return
        }
        super.sendEvent(event)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: LauncherWindow!
    private var controller: SearchViewController!
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        controller = SearchViewController()
        window = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "秒搜"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentViewController = controller
        window.spaceHandler = { [weak controller] in controller?.handleSpaceKey() ?? false }
        window.setContentSize(NSSize(width: 760, height: 520))
        window.minSize = NSSize(width: 620, height: 420)
        window.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "打开秒搜")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleWindow)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        registerHotKey()
        showWindow()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出秒搜", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue().toggleWindow()
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler
        )
        let identifier = EventHotKeyID(signature: 0x4D534F55, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
    }

    @objc private func toggleWindow() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开秒搜", action: #selector(showWindow), keyEquivalent: "")
            menu.addItem(withTitle: "重新扫描应用", action: #selector(refreshApplications), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if window.isVisible {
            controller.closeQuickLook()
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    @objc private func showWindow() {
        let previousBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        controller.showRecommendations(excluding: previousBundleID)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        positionWindowOnActiveScreen()
        controller.focusSearch()
    }

    private func positionWindowOnActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.midY - window.frame.height / 2 + frame.height * 0.08
        )
        window.setFrameOrigin(origin)
    }

    @objc private func refreshApplications() {
        controller.refreshApplications()
        showWindow()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        controller.closeQuickLook()
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            showWindow()
        }
        return true
    }
}

private func runSelfCheck() {
    precondition(normalizedSearchInput("。pdf，md．docx＠pi") == ".pdf,md.docx@pi")
    precondition(hiddenConfigQuery("@") == "")
    precondition(hiddenConfigQuery("＠codex") == "codex")
    precondition(hiddenConfigQuery("codex") == nil)
    precondition(spaceQuickLookEligible(query: ".png", kind: .file))
    precondition(spaceQuickLookEligible(query: "@codex", kind: .folder))
    precondition(!spaceQuickLookEligible(query: "project image", kind: .file))
    precondition(!spaceQuickLookEligible(query: ".png", kind: .application))
    precondition(normalized("Shadow Rocket") == "shadowrocket")
    precondition(fuzzyScore(query: "shadow", candidate: "Shadowrocket") == 10)
    precondition(fuzzyScore(query: "sr", candidate: "Shadowrocket") != nil)
    precondition(fileExtensionQuery(".PDF") == "pdf")
    precondition(fileExtensionQuery("。PDF") == "pdf")
    precondition(fileExtensionQuery(".") == nil)
    precondition(fileTypeSuggestions().first?.title == ".pdf")
    precondition(NSURL(fileURLWithPath: "/tmp/example.pdf").writableTypes(for: NSPasteboard.general).contains(.fileURL))
    precondition(shouldSkipDirectory("node_modules"))
    precondition(defaultSearchRoots().contains(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")))
    let sample = IndexedFile(url: URL(fileURLWithPath: "/tmp/基础检索.txt"), name: "基础检索.txt", modifiedAt: .distantPast, isDirectory: false)
    precondition(directFileMatches(query: "基础", files: [sample]).first?.title == "基础检索.txt")
    let now = Date()
    let recent = InstalledApplication(url: URL(fileURLWithPath: "/Recent.app"), name: "Recent", searchable: "Recent", bundleID: "test.recent", useCount: 5, lastUsedAt: now.addingTimeInterval(-3_600), isRunning: false)
    let stale = InstalledApplication(url: URL(fileURLWithPath: "/Stale.app"), name: "Stale", searchable: "Stale", bundleID: "test.stale", useCount: 50, lastUsedAt: now.addingTimeInterval(-120 * 86_400), isRunning: false)
    precondition(recommendedApplications([stale, recent], excluding: nil, now: now).first?.bundleID == "test.recent")
    let bookmarks = loadBookmarks()
    precondition(bookmarkResults(query: "X", bookmarks: bookmarks).first?.title == "X / Twitter")
    precondition(bookmarkResults(query: "黄雀", bookmarks: bookmarks).first?.title == "黄雀主站")
    let hiddenFixture = FileManager.default.temporaryDirectory.appendingPathComponent("miaosou-hidden-\(UUID().uuidString)")
    let recentHidden = hiddenFixture.appendingPathComponent(".recent")
    let oldHidden = hiddenFixture.appendingPathComponent(".old")
    try? FileManager.default.createDirectory(at: recentHidden, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: oldHidden, withIntermediateDirectories: true)
    try? Data("recent".utf8).write(to: recentHidden.appendingPathComponent("settings.json"))
    let oldFile = oldHidden.appendingPathComponent("settings.json")
    try? Data("old".utf8).write(to: oldFile)
    try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: oldFile.path)
    let hiddenResults = hiddenConfigResults(query: "", home: hiddenFixture, now: now)
    precondition(hiddenResults.first?.title == ".recent")
    precondition(hiddenConfigResults(query: "old", home: hiddenFixture, now: now).first?.title == ".old")
    try? FileManager.default.removeItem(at: hiddenFixture)
    let apps = installedApplications()
    let shadowrocket = apps.first { $0.name == "Shadowrocket" && $0.url.path == "/Applications/Shadowrocket.app" }
    precondition(shadowrocket != nil)
    precondition(fuzzyScore(query: "小火箭", candidate: shadowrocket!.searchable) != nil)
    print("PASS: recommendations, bookmarks, extension filters, applications and local filenames")
}

if CommandLine.arguments.contains("--self-check") {
    runSelfCheck()
    exit(0)
}

if CommandLine.arguments.contains("--index-check") {
    for root in defaultSearchRoots() {
        print("\(scanLocalRoot(root).count)\t\(root.path)")
    }
    exit(0)
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
