import AppKit
import Carbon.HIToolbox
import CoreServices
import Foundation

private enum ItemKind {
    case website
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
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            let bundleID = bundle?.bundleIdentifier ?? ""
            let executable = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
            let aliases = appAliases[bundleID, default: []].joined(separator: " ")
            let metadata = MDItemCreate(kCFAllocatorDefault, path as CFString)
            let useCount = (metadata.flatMap { MDItemCopyAttribute($0, "kMDItemUseCount" as CFString) } as? NSNumber)?.intValue ?? 0
            let lastUsedAt = metadata.flatMap { MDItemCopyAttribute($0, "kMDItemLastUsedDate" as CFString) } as? Date
            applications.append(InstalledApplication(
                url: url,
                name: name,
                searchable: [name, bundleID, executable, aliases].joined(separator: " "),
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
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .tertiaryLabelColor

        [iconView, titleLabel, subtitleLabel, badgeLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 38),
            iconView.heightAnchor.constraint(equalToConstant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badgeLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class SearchViewController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerLabel = NSTextField(labelWithString: "↑↓ 选择   ↩ 打开   ⌘↩ 在访达显示   ⌘Space 显示/隐藏")
    private var applications = installedApplications()
    private let bookmarks = loadBookmarks()
    private var websiteResults: [SearchItem] = []
    private var appResults: [SearchItem] = []
    private var fileResults: [SearchItem] = []
    private var indexedFiles: [IndexedFile] = []
    private var isIndexingFiles = true
    private var excludedRecommendationBundleID: String?
    private var fileSearchProcess: Process?
    private var searchGeneration = 0
    private(set) var results: [SearchItem] = []

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        view = effectView

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索应用和文件"
        searchField.font = .systemFont(ofSize: 22)
        searchField.focusRingType = .none
        searchField.delegate = self

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(openSelected)
        tableView.target = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center

        [searchField, statusLabel, scrollView, footerLabel].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            searchField.heightAnchor.constraint(equalToConstant: 42),
            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
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
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        let height = max(scrollView.contentSize.height, CGFloat(results.count) * (tableView.rowHeight + tableView.intercellSpacing.height))
        tableView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        tableView.tableColumns.first?.width = width
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func showRecommendations(excluding bundleID: String?) {
        excludedRecommendationBundleID = bundleID
        applications = installedApplications()
        clearSearch()
    }

    func refreshApplications() {
        applications = installedApplications()
        refreshFileIndex()
        updateResults()
    }

    func clearSearch() {
        searchField.stringValue = ""
        fileSearchProcess?.terminate()
        fileResults = []
        updateResults()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

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
        case .recommendation:
            cell.iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.badgeLabel.stringValue = "推荐"
        case .application:
            cell.iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.badgeLabel.stringValue = "应用"
        case .file:
            cell.iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.badgeLabel.stringValue = "文件"
        case .folder:
            cell.iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.badgeLabel.stringValue = "文件夹"
        }
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        searchGeneration += 1
        fileSearchProcess?.terminate()
        fileResults = []
        updateResults()
        searchFiles(query: searchField.stringValue, generation: searchGeneration)
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
        if item.kind == .website {
            openWebsiteInChrome(item.url)
            view.window?.orderOut(nil)
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else {
            NSWorkspace.shared.open(item.url)
        }
        view.window?.orderOut(nil)
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

        results = websiteResults + Array(appResults.prefix(10)) + Array(fileResults.prefix(12))
        tableView.reloadData()
        view.needsLayout = true
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func searchFiles(query: String, generation: Int) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized(term).isEmpty else { return }
        let directIndex = indexedFiles

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let directItems = directFileMatches(query: term, files: directIndex)
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
            DispatchQueue.main.async { self?.fileSearchProcess = process }

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard !process.isRunning else { return }
                let paths = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
                let items = paths.prefix(120).compactMap { path -> SearchItem? in
                    guard !["/Library/", "/.git/", "/node_modules/", "/.venv/", "/venv/"].contains(where: path.contains) else { return nil }
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
                self.fileSearchProcess?.terminate()
                self.searchFiles(query: query, generation: self.searchGeneration)
            }
        }
    }
}

private final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
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
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 760, height: 520))
        window.minSize = NSSize(width: 620, height: 420)
        window.delegate = self
        window.center()

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
        controller.focusSearch()
    }

    @objc private func refreshApplications() {
        controller.refreshApplications()
        showWindow()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private func runSelfCheck() {
    precondition(normalized("Shadow Rocket") == "shadowrocket")
    precondition(fuzzyScore(query: "shadow", candidate: "Shadowrocket") == 10)
    precondition(fuzzyScore(query: "sr", candidate: "Shadowrocket") != nil)
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
    let apps = installedApplications()
    let shadowrocket = apps.first { $0.name == "Shadowrocket" && $0.url.path == "/Applications/Shadowrocket.app" }
    precondition(shadowrocket != nil)
    precondition(fuzzyScore(query: "小火箭", candidate: shadowrocket!.searchable) != nil)
    print("PASS: recommendations, bookmarks, applications and local filenames")
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
