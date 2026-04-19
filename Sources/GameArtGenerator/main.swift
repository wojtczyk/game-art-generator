import Foundation
import AppKit
import CoreGraphics
import ImageIO
import ImagePlayground
import UniformTypeIdentifiers

@main
struct GameArtGeneratorCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())

            if CommandLineOptions.isHelpRequest(arguments: arguments) {
                StandardOutput.write(CommandLineOptions.usage)
                Foundation.exit(0)
            }

            try AppBundleRelauncher.relaunchIfNeeded(arguments: arguments)
            try AppBundleRelauncher.restoreWorkingDirectoryIfNeeded()

            if #available(macOS 15.4, *) {
                let options = try CommandLineOptions.parse(arguments: arguments)
                let assets = try AssetListParser.parse(from: options.listURL)
                try await ForegroundApplicationCoordinator.prepareIfNeeded()
                try await ImageGenerationRunner(options: options, assets: assets).run()
            } else {
                throw CLIError.unsupportedOS
            }
        } catch {
            StandardError.write("\(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }
}

enum AppBundleRelauncher {
    private static let wrapperEnvironmentKey = "GAME_ART_GENERATOR_RUNNING_FROM_WRAPPER"
    private static let originalWorkingDirectoryKey = "GAME_ART_GENERATOR_ORIGINAL_CWD"
    private static let stdoutRelayEnvironmentKey = "GAME_ART_GENERATOR_STDOUT_RELAY"
    private static let stderrRelayEnvironmentKey = "GAME_ART_GENERATOR_STDERR_RELAY"
    private static let wrapperBundleIdentifier = "com.codex.gameartgenerator.wrapper"

    static func relaunchIfNeeded(arguments: [String]) throws {
        guard !isRunningInsideAppBundle else {
            return
        }

        guard ProcessInfo.processInfo.environment[wrapperEnvironmentKey] == nil else {
            throw CLIError.failedToPrepareAppBundle(
                """
                The tool relaunched itself from its reusable wrapper app, but macOS still did not treat it as a foreground app.
                Try running the packaged `.app` build directly with `open ... --args ...`.
                """
            )
        }

        let bundleURL = try createWrapperBundle()
        let relayOutputURLs = makeLaunchRelayURLs()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        var openArguments = [
            "-n",
            "-W",
            bundleURL.path,
            "--args"
        ]
        openArguments.append(contentsOf: arguments)
        process.arguments = openArguments

        var environment = ProcessInfo.processInfo.environment
        environment[wrapperEnvironmentKey] = "1"
        environment[originalWorkingDirectoryKey] = FileManager.default.currentDirectoryPath
        environment[stdoutRelayEnvironmentKey] = relayOutputURLs.stdout.path
        environment[stderrRelayEnvironmentKey] = relayOutputURLs.stderr.path
        process.environment = environment
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        do {
            process.standardOutput = try FileHandle(forWritingTo: relayOutputURLs.stdout)
            process.standardError = try FileHandle(forWritingTo: relayOutputURLs.stderr)
        } catch {
            throw CLIError.failedToPrepareAppBundle(
                "Could not prepare wrapper app log files: \(error.localizedDescription)"
            )
        }

        do {
            try process.run()
        } catch {
            throw CLIError.failedToPrepareAppBundle(
                "Could not launch the reusable wrapper app via LaunchServices at \(bundleURL.path): \(error.localizedDescription)"
            )
        }

        let finalOffsets = streamLaunchLogsWhileWaiting(
            for: process,
            from: relayOutputURLs
        )
        process.waitUntilExit()
        relayLaunchLogs(from: relayOutputURLs, startingAt: finalOffsets)
        Foundation.exit(process.terminationStatus)
    }

    private static var isRunningInsideAppBundle: Bool {
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private static func createWrapperBundle() throws -> URL {
        let fileManager = FileManager.default
        cleanupLegacyTemporaryWrapperIfPresent(using: fileManager)

        let applicationSupportURL: URL
        do {
            applicationSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw CLIError.failedToPrepareAppBundle(
                "Could not resolve the Application Support directory: \(error.localizedDescription)"
            )
        }

        let wrapperRootURL = applicationSupportURL
            .appendingPathComponent("GameArtGenerator", isDirectory: true)
            .appendingPathComponent("Wrapper", isDirectory: true)
        let bundleURL = wrapperRootURL.appendingPathComponent("GameArtGenerator.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = macOSURL.appendingPathComponent("game-art-generator", isDirectory: false)
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)

        if fileManager.fileExists(atPath: bundleURL.path) {
            do {
                try fileManager.removeItem(at: bundleURL)
            } catch {
                throw CLIError.failedToPrepareAppBundle(
                    "Could not replace the reusable wrapper app at \(bundleURL.path): \(error.localizedDescription)"
                )
            }
        }

        do {
            try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw CLIError.failedToPrepareAppBundle(
                "Could not create the reusable wrapper app at \(bundleURL.path): \(error.localizedDescription)"
            )
        }

        do {
            try fileManager.copyItem(at: currentExecutableURL(), to: executableURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        } catch {
            throw CLIError.failedToPrepareAppBundle(
                "Could not copy the executable into the reusable wrapper app: \(error.localizedDescription)"
            )
        }

        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": "Game Art Generator",
            "CFBundleExecutable": "game-art-generator",
            "CFBundleIdentifier": wrapperBundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Game Art Generator",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.4",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication"
        ]

        do {
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try plistData.write(to: infoPlistURL, options: .atomic)
        } catch {
            throw CLIError.failedToPrepareAppBundle(
                "Could not write the reusable wrapper app Info.plist: \(error.localizedDescription)"
            )
        }

        return bundleURL
    }

    static func restoreWorkingDirectoryIfNeeded() throws {
        guard isRunningInsideAppBundle,
              let originalWorkingDirectory = ProcessInfo.processInfo.environment[originalWorkingDirectoryKey] else {
            return
        }

        guard FileManager.default.changeCurrentDirectoryPath(originalWorkingDirectory) else {
            throw CLIError.failedToPrepareAppBundle(
                "Could not restore the original working directory at \(originalWorkingDirectory)."
            )
        }
    }

    private static func currentExecutableURL() throws -> URL {
        let fileManager = FileManager.default

        if let executableURL = Bundle.main.executableURL,
           fileManager.isExecutableFile(atPath: executableURL.path) {
            return executableURL
        }

        let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let executableArgument = CommandLine.arguments[0]

        if executableArgument.contains("/") {
            let executableURL = URL(fileURLWithPath: executableArgument, relativeTo: currentDirectoryURL)
                .standardizedFileURL
            if fileManager.isExecutableFile(atPath: executableURL.path) {
                return executableURL
            }
        } else if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let executableURL = URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent(executableArgument, isDirectory: false)
                if fileManager.isExecutableFile(atPath: executableURL.path) {
                    return executableURL
                }
            }
        }

        throw CLIError.failedToPrepareAppBundle("Could not resolve the current executable path.")
    }

    private static func cleanupLegacyTemporaryWrapperIfPresent(using fileManager: FileManager) {
        let legacyWrapperRoot = fileManager.temporaryDirectory
            .appendingPathComponent("game-art-generator-wrapper", isDirectory: true)
        if fileManager.fileExists(atPath: legacyWrapperRoot.path) {
            try? fileManager.removeItem(at: legacyWrapperRoot)
        }
    }

    private static func makeLaunchRelayURLs() -> (stdout: URL, stderr: URL) {
        let baseDirectory = FileManager.default.temporaryDirectory
        let uniqueSuffix = UUID().uuidString.lowercased()
        let urls = (
            stdout: baseDirectory.appendingPathComponent("game-art-generator-open-\(uniqueSuffix).stdout"),
            stderr: baseDirectory.appendingPathComponent("game-art-generator-open-\(uniqueSuffix).stderr")
        )

        FileManager.default.createFile(atPath: urls.stdout.path, contents: Data())
        FileManager.default.createFile(atPath: urls.stderr.path, contents: Data())

        return urls
    }

    private static func relayLaunchLogs(
        from urls: (stdout: URL, stderr: URL),
        startingAt offsets: (stdout: UInt64, stderr: UInt64)
    ) {
        _ = relayIncrementalContents(
            at: urls.stdout,
            from: offsets.stdout,
            writer: { StandardOutput.write($0, mirrorToRelay: false) }
        )
        _ = relayIncrementalContents(
            at: urls.stderr,
            from: offsets.stderr,
            writer: { StandardError.write($0, mirrorToRelay: false) }
        )

        try? FileManager.default.removeItem(at: urls.stdout)
        try? FileManager.default.removeItem(at: urls.stderr)
    }

    private static func streamLaunchLogsWhileWaiting(
        for process: Process,
        from urls: (stdout: URL, stderr: URL)
    ) -> (stdout: UInt64, stderr: UInt64) {
        var stdoutOffset = UInt64(0)
        var stderrOffset = UInt64(0)

        while process.isRunning {
            stdoutOffset = relayIncrementalContents(
                at: urls.stdout,
                from: stdoutOffset,
                writer: { StandardOutput.write($0, mirrorToRelay: false) }
            )
            stderrOffset = relayIncrementalContents(
                at: urls.stderr,
                from: stderrOffset,
                writer: { StandardError.write($0, mirrorToRelay: false) }
            )

            Thread.sleep(forTimeInterval: 0.2)
        }

        return (stdout: stdoutOffset, stderr: stderrOffset)
    }

    @discardableResult
    private static func relayIncrementalContents(
        at url: URL,
        from offset: UInt64,
        writer: (String) -> Void
    ) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return offset
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                return offset
            }

            writer(text)
            return offset + UInt64(data.count)
        } catch {
            return offset
        }
    }

}

@available(macOS 15.4, *)
enum ForegroundApplicationCoordinator {
    @MainActor private static var activationWindow: NSWindow?

    static func prepareIfNeeded() async throws {
        let activationOptions: NSApplication.ActivationOptions = [.activateAllWindows]

        try await MainActor.run {
            let application = NSApplication.shared
            let runningApplication = NSRunningApplication.current

            if application.activationPolicy() == .prohibited {
                guard application.setActivationPolicy(.regular) else {
                    throw CLIError.failedToActivateApplication(
                        "The process could not switch from background-only mode to a foreground macOS app."
                    )
                }
            }

            if !runningApplication.isFinishedLaunching {
                application.finishLaunching()
            }

            let window = activationWindow ?? makeActivationWindow()
            activationWindow = window

            _ = runningApplication.unhide()
            application.unhide(nil)
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            _ = runningApplication.activate(options: activationOptions)
            application.activate()
        }

        for _ in 0..<20 {
            let isActive = await MainActor.run { NSApplication.shared.isActive }
            if isActive {
                return
            }

            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                let application = NSApplication.shared
                let window = activationWindow ?? makeActivationWindow()
                activationWindow = window

                application.unhide(nil)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                _ = NSRunningApplication.current.activate(options: activationOptions)
                application.activate()
            }
        }

        throw CLIError.failedToActivateApplication(
            """
            Image Playground requires the generator process to be the active foreground app.
            Launch the tool from a visible interactive macOS session and keep it frontmost while images are being created.
            """
        )
    }

    @MainActor
    private static func makeActivationWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Game Art Generator"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Generating gameplay artwork...")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(
            labelWithString: "Keep this app in front while Image Playground creates the requested images."
        )
        detailLabel.font = NSFont.systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24)
        ])

        return window
    }
}

struct CommandLineOptions {
    let listURL: URL
    let styleName: String
    let imageCount: Int

    static func parse(arguments: [String]) throws -> CommandLineOptions {
        var listPath: String?
        var styleName: String?
        var imageCount: Int?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--list", "-l":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for \(argument).")
                }
                listPath = arguments[index]
            case "--style", "-s":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for \(argument).")
                }
                styleName = arguments[index]
            case "--n", "-n":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("Missing value for \(argument).")
                }
                guard let parsedCount = Int(arguments[index]), parsedCount > 0 else {
                    throw CLIError.invalidArguments("`--n` must be a positive integer.")
                }
                imageCount = parsedCount
            default:
                throw CLIError.invalidArguments("Unknown argument: \(argument)")
            }

            index += 1
        }

        guard let listPath else {
            throw CLIError.invalidArguments("Missing required `--list` argument.")
        }

        guard let styleName else {
            throw CLIError.invalidArguments("Missing required `--style` argument.")
        }

        guard let imageCount else {
            throw CLIError.invalidArguments("Missing required `--n` argument.")
        }

        let listURL = URL(fileURLWithPath: NSString(string: listPath).expandingTildeInPath)
        return CommandLineOptions(listURL: listURL, styleName: styleName, imageCount: imageCount)
    }

    static func isHelpRequest(arguments: [String]) -> Bool {
        arguments.contains("--help") || arguments.contains("-h")
    }

    static let usage = """
    Usage:
      game-art-generator --list <assets.txt> --style <animation|illustration|sketch> --n <count>

    Options:
      --list, -l    Path to the asset list file.
      --style, -s   Image Playground style name.
      --n, -n       Number of images to generate per asset entry.
      --help, -h    Show this help message.
    """
}

struct AssetEntry: Sendable {
    let lineNumber: Int
    let relativeAssetPath: String
    let directoryPath: String
    let fileName: String
    let prompt: String
}

enum AssetListParser {
    static func parse(from url: URL) throws -> [AssetEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.fileNotFound(url.path)
        }

        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CLIError.unreadableFile(url.path, underlying: error)
        }

        let normalizedContents = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalizedContents.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        if lines.isEmpty {
            throw CLIError.invalidAssetList("""
            The asset list is empty.
            Add one asset per line using the format:
              asset_path/asset_file_name, description prompt
            """)
        }

        var errors = [AssetValidationError]()
        var assets = [AssetEntry]()
        var seenAssetPaths = Set<String>()

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1

            switch parseLine(rawLine, lineNumber: lineNumber, seenAssetPaths: &seenAssetPaths) {
            case .success(let entry):
                assets.append(entry)
            case .failure(let validationError):
                errors.append(validationError)
            }
        }

        if !errors.isEmpty {
            let details = errors.map(\.formatted).joined(separator: "\n")
            throw CLIError.invalidAssetList("""
            Invalid asset list file:
            \(details)
            """)
        }

        return assets
    }

    private static func parseLine(
        _ rawLine: String,
        lineNumber: Int,
        seenAssetPaths: inout Set<String>
    ) -> Result<AssetEntry, AssetValidationError> {
        let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Blank lines are not allowed."
                )
            )
        }

        guard let separatorIndex = trimmedLine.firstIndex(of: ",") else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Expected `asset_path/asset_file_name, description prompt`."
                )
            )
        }

        let rawPath = String(trimmedLine[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
        let rawPrompt = String(trimmedLine[trimmedLine.index(after: separatorIndex)...])
            .trimmingCharacters(in: .whitespaces)

        guard !rawPath.isEmpty, !rawPrompt.isEmpty else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Both the asset path and description prompt are required."
                )
            )
        }

        guard rawPrompt.count <= 100 else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Description prompt must be 100 characters or fewer."
                )
            )
        }

        guard !rawPath.hasPrefix("/") else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Asset paths must be relative, not absolute."
                )
            )
        }

        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Asset path must include both a directory and a file name."
                )
            )
        }

        let invalidComponent = components.first { component in
            component.isEmpty || component == "." || component == ".."
        }
        guard invalidComponent == nil else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Asset path contains an empty, `.` or `..` path component."
                )
            )
        }

        let nsPath = rawPath as NSString
        let directoryPath = nsPath.deletingLastPathComponent
        let fileName = nsPath.lastPathComponent

        guard !directoryPath.isEmpty, !fileName.isEmpty else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Asset path must end with a file name."
                )
            )
        }

        guard (fileName as NSString).pathExtension.isEmpty else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Do not include a file extension in `asset_file_name`."
                )
            )
        }

        guard seenAssetPaths.insert(rawPath).inserted else {
            return .failure(
                AssetValidationError(
                    lineNumber: lineNumber,
                    content: rawLine,
                    reason: "Duplicate asset path `\(rawPath)` would overwrite generated files."
                )
            )
        }

        return .success(
            AssetEntry(
                lineNumber: lineNumber,
                relativeAssetPath: rawPath,
                directoryPath: directoryPath,
                fileName: fileName,
                prompt: rawPrompt
            )
        )
    }
}

struct AssetValidationError: Error {
    let lineNumber: Int
    let content: String
    let reason: String

    var formatted: String {
        """
          line \(lineNumber): \(reason)
            content: \(content.isEmpty ? "<empty line>" : content)
        """
    }
}

@available(macOS 15.4, *)
struct ImageGenerationRunner {
    let options: CommandLineOptions
    let assets: [AssetEntry]

    func run() async throws {
        let creator = try await ImageCreator()
        let style = try resolveStyle(with: creator)
        let outputDirectory = try createOutputDirectory()

        StandardOutput.write("Writing artwork to \(outputDirectory.path)\n")

        for (index, asset) in assets.enumerated() {
            StandardOutput.write(
                "[\(index + 1)/\(assets.count)] Generating \(options.imageCount) image(s) for \(asset.relativeAssetPath)\n"
            )
            try await generateImages(for: asset, using: creator, style: style, outputDirectory: outputDirectory)
        }

        StandardOutput.write("Finished generating \(assets.count * options.imageCount) image(s).\n")
    }

    private func resolveStyle(with creator: ImageCreator) throws -> ImagePlaygroundStyle {
        guard let requestedStyle = ImagePlaygroundStyle.named(options.styleName) else {
            throw CLIError.invalidArguments(
                "Unsupported style `\(options.styleName)`. Use one of: \(ImagePlaygroundStyle.cliStyleNames.joined(separator: ", "))."
            )
        }

        guard creator.availableStyles.contains(requestedStyle) else {
            let available = creator.availableStyles.map(\.displayName).joined(separator: ", ")
            throw CLIError.styleUnavailable(
                "The requested style `\(requestedStyle.displayName)` is not available on this Mac. Available styles: \(available)."
            )
        }

        return requestedStyle
    }

    private func createOutputDirectory() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH.mm"

        let directoryName = "\(formatter.string(from: Date()))_art-for-review"
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let outputDirectory = currentDirectory.appendingPathComponent(directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw CLIError.failedToCreateDirectory(outputDirectory.path, underlying: error)
        }

        return outputDirectory
    }

    private func generateImages(
        for asset: AssetEntry,
        using creator: ImageCreator,
        style: ImagePlaygroundStyle,
        outputDirectory: URL
    ) async throws {
        let assetDirectory = outputDirectory.appendingPathComponent(asset.directoryPath, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: assetDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw CLIError.failedToCreateDirectory(assetDirectory.path, underlying: error)
        }

        let concepts = [ImagePlaygroundConcept.text(asset.prompt)]
        let generatedImages = creator.images(for: concepts, style: style, limit: options.imageCount)
        var writtenCount = 0

        do {
            for try await createdImage in generatedImages {
                writtenCount += 1
                let outputURL = assetDirectory.appendingPathComponent("\(asset.fileName)-\(writtenCount).png")
                try PNGWriter.write(createdImage.cgImage, to: outputURL)
                StandardOutput.write("  created \(outputURL.path)\n")
            }
        } catch let imageCreatorError as ImageCreator.Error {
            if imageCreatorError == .backgroundCreationForbidden {
                throw CLIError.failedToActivateApplication(
                    """
                    Image Playground refused generation because the app is hidden or running in the background.
                    Keep `game-art-generator` frontmost while it creates images.
                    """
                )
            }

            throw CLIError.imageCreationFailed(asset.relativeAssetPath, imageCreatorError.localizedDescription)
        } catch {
            throw CLIError.imageCreationFailed(asset.relativeAssetPath, error.localizedDescription)
        }

        if writtenCount != options.imageCount {
            throw CLIError.imageCreationFailed(
                asset.relativeAssetPath,
                "Expected \(options.imageCount) image(s) but received \(writtenCount)."
            )
        }
    }
}

enum PNGWriter {
    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.failedToWriteImage(url.path, reason: "Could not create a PNG image destination.")
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.failedToWriteImage(url.path, reason: "Could not finalize the PNG file.")
        }
    }
}

enum CLIError: LocalizedError {
    case invalidArguments(String)
    case unsupportedOS
    case fileNotFound(String)
    case unreadableFile(String, underlying: Error)
    case invalidAssetList(String)
    case styleUnavailable(String)
    case failedToPrepareAppBundle(String)
    case failedToActivateApplication(String)
    case failedToCreateDirectory(String, underlying: Error)
    case failedToWriteImage(String, reason: String)
    case imageCreationFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return """
            \(message)

            \(CommandLineOptions.usage)
            """
        case .unsupportedOS:
            return "Image Playground programmatic generation requires macOS 15.4 or newer."
        case .fileNotFound(let path):
            return "Asset list file not found: \(path)"
        case .unreadableFile(let path, let underlying):
            return "Could not read asset list file at \(path): \(underlying.localizedDescription)"
        case .invalidAssetList(let details):
            return details
        case .styleUnavailable(let message):
            return message
        case .failedToPrepareAppBundle(let message):
            return message
        case .failedToActivateApplication(let message):
            return message
        case .failedToCreateDirectory(let path, let underlying):
            return "Could not create directory at \(path): \(underlying.localizedDescription)"
        case .failedToWriteImage(let path, let reason):
            return "Could not write image to \(path): \(reason)"
        case .imageCreationFailed(let assetPath, let reason):
            return "Image generation failed for `\(assetPath)`: \(reason)"
        }
    }
}

@available(macOS 15.4, *)
extension ImagePlaygroundStyle {
    static var cliStyleNames: [String] {
        var names = ["animation", "illustration", "sketch"]
        if #available(macOS 26.0, *) {
            names.append("external-provider")
        }
        return names
    }

    static func named(_ rawValue: String) -> ImagePlaygroundStyle? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "animation", "animated":
            return .animation
        case "illustration", "illustrated":
            return .illustration
        case "sketch":
            return .sketch
        case "external-provider", "externalprovider":
            if #available(macOS 26.0, *) {
                return .externalProvider
            }
            return nil
        default:
            return nil
        }
    }

    var displayName: String {
        if self == .animation {
            return "animation"
        }
        if self == .illustration {
            return "illustration"
        }
        if self == .sketch {
            return "sketch"
        }
        if #available(macOS 26.0, *), self == .externalProvider {
            return "external-provider"
        }
        return id
    }
}

enum StandardOutput {
    static func write(_ message: String, mirrorToRelay: Bool = true) {
        FileHandle.standardOutput.write(Data(message.utf8))
        if mirrorToRelay {
            RelayLogWriter.append(message, toEnvironmentKey: "GAME_ART_GENERATOR_STDOUT_RELAY")
        }
    }
}

enum StandardError {
    static func write(_ message: String, mirrorToRelay: Bool = true) {
        FileHandle.standardError.write(Data(message.utf8))
        if mirrorToRelay {
            RelayLogWriter.append(message, toEnvironmentKey: "GAME_ART_GENERATOR_STDERR_RELAY")
        }
    }
}

enum RelayLogWriter {
    static func append(_ message: String, toEnvironmentKey environmentKey: String) {
        guard let relayPath = ProcessInfo.processInfo.environment[environmentKey],
              !relayPath.isEmpty,
              let data = message.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: relayPath) else {
            return
        }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }
}
