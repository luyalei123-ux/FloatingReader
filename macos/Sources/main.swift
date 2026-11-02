import AppKit
import WebKit
import Vision

enum ReadingViewport {
    static let size = NSSize(width: 1200, height: 2400)
    static var rect: NSRect { NSRect(origin: .zero, size: size) }
}

enum ReadingParagraphs {
    static func text(from readingLines: [VNRecognizedTextObservation]) -> String {
        var value = ""
        var previous: VNRecognizedTextObservation?
        for line in readingLines {
            guard let content = line.topCandidates(1).first?.string else { continue }
            if let before = previous {
                let gap = before.boundingBox.minY - line.boundingBox.maxY
                let sameRow = abs(before.boundingBox.midY - line.boundingBox.midY) < min(before.boundingBox.height, line.boundingBox.height) * 0.45
                let sameParagraph = sameRow || (gap < max(before.boundingBox.height, line.boundingBox.height) * 0.8 && gap >= -0.02)
                if !sameParagraph { value += "\n\n" }
                else if let last = value.last, let first = content.first, last.isASCII && first.isASCII { value += " " }
            }
            value += content
            previous = line
        }
        return value
    }
}

final class RenderingWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    static func safeFrame(size: NSSize) -> NSRect {
        let x = (NSScreen.screens.map { $0.frame.minX }.min() ?? 0) - 10000
        let y = (NSScreen.screens.map { $0.frame.minY }.min() ?? 0) - 10000
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Self.safeFrame(size: frameRect.size)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(Self.safeFrame(size: frameRect.size), display: flag)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(Self.safeFrame(size: frame.size).origin)
    }
    func securePosition() { setFrame(Self.safeFrame(size: frame.size), display: false) }
}

// Uses a separate page so current-chapter OCR cannot delay next-chapter navigation.
final class NextChapterLoader: NSObject, WKNavigationDelegate {
    struct Page { let text: String; let url: String; let capture: [String: Any]; let top: CGFloat; let bottom: CGFloat; var recognized = true }
    static let maximumPages = 8
    static let maximumCharacters = 18000
    let view: WKWebView
    let host: RenderingWindow
    let owner: String
    var completion: ((Page?) -> Void)?
    var timer: Timer?
    var activity: NSObjectProtocol?
    var sourceUsable = true
    var phase = 0
    var stable = 0
    var signature = ""
    var ownerSignature = ""
    var deadline = Date().addingTimeInterval(50)
    init(owner: String, completion: @escaping (Page?) -> Void) {
        self.owner = owner; self.completion = completion
        let config = WKWebViewConfiguration(); config.websiteDataStore = .default()
        if let url = Bundle.main.url(forResource: "reader", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        view = WKWebView(frame: ReadingViewport.rect, configuration: config)
        host = RenderingWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: ReadingViewport.size), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        host.isReleasedWhenClosed = false; host.isExcludedFromWindowsMenu = true
        host.ignoresMouseEvents = true; host.isRestorable = false
        host.collectionBehavior = [.transient, .ignoresCycle]
        host.contentView?.addSubview(view); host.orderBack(nil)
        view.navigationDelegate = self
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "准备下一章阅读缓存")
        view.load(URLRequest(url: URL(string: owner)!))
        let pollTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        timer = pollTimer; RunLoop.main.add(pollTimer, forMode: .common)
    }
    var polling = false
    var captureRetries = 0
    var pagesRead = 0
    var collectedText = ""
    var collectedTop: CGFloat?
    var collectedBottom: CGFloat?
    var published = false
    func poll() {
        guard completion != nil else { return }
        if Date() > deadline { finish(nil); return }
        guard !polling, phase < 2 else { return }
        polling = true
        view.evaluateJavaScript("(()=>{const s=document.fonts?.status==='loading'?null:window.floatingReaderChapterSnapshot?.();if(s)s.preloadResult=window.floatingReaderPreloadResult||'';return s})()") { [weak self] result, _ in
            guard let self = self, self.completion != nil else { return }
            self.polling = false
            guard let snapshot = result as? [String: Any], snapshot["ready"] as? Bool == true, !self.view.isLoading else { return }
            let current = snapshot["signature"] as? String ?? ""
            let result = snapshot["preloadResult"] as? String ?? ""
            if self.phase == 1 && !result.isEmpty && result != "changed" && result != "loading" && current == self.ownerSignature {
                self.finish(nil); return
            }
            if current == self.signature { self.stable += 1 } else { self.signature = current; self.stable = 0 }
            guard self.stable >= (self.phase == 0 ? 1 : 3) else { return }
            if self.phase == 0 {
                guard self.view.url?.absoluteString == self.owner else { self.finish(nil); return }
                self.phase = 1; self.stable = 0; self.ownerSignature = current
                self.view.evaluateJavaScript("window.floatingReaderUseNativeClick=false; window.floatingReaderPreloadResult=''; window.floatingReaderChangeChapter?.('next').then(result=>window.floatingReaderPreloadResult=result,error=>window.floatingReaderPreloadResult=String(error)); true;", completionHandler: nil)
            } else if self.phase == 1, let target = self.view.url, (target.absoluteString != self.owner || current != self.ownerSignature) {
                // Only cache a confirmed different chapter in the same book.
                let entry = self.owner.components(separatedBy: "/reader/").last?.prefix(21)
                guard target.host == "weread.qq.com", let entry = entry, target.path.contains(String(entry)) else { self.finish(nil); return }
                self.phase = 2
                self.deadline = Date().addingTimeInterval(60)
                self.view.evaluateJavaScript("window.floatingReaderRestoreCaptureState?.({start:0,end:0,current:0}); window.floatingReaderBeginCapture?.();", completionHandler: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.capture() }
            }
        }
    }
    func capture() {
        let extraction = """
        (()=>{
            const n=document.querySelector('.readerChapterContent,.wr_readerChapterContent');if(!n)return null;
            const r=n.getBoundingClientRect(), state=window.floatingReaderCaptureState?.() || {};
            const faces=Array.from(document.fonts || []), nodes=[n,...n.querySelectorAll('p,span,div')];
            const customFont=nodes.some(el=>getComputedStyle(el).fontFamily.split(',').some(name=>faces.some(face=>face.family.replace(/["']/g,'').toLowerCase()===name.trim().replace(/["']/g,'').toLowerCase())));
            const canvas=Array.from(n.querySelectorAll('canvas')).some(c=>c.width>32&&c.height>32);
            const text=(n.innerText||'').trim();
            const plain=!canvas&&!customFont&&!/[\\uE000-\\uF8FF]/.test(text)&&text.length>=80?text:null;
            return {x:Math.max(0,r.left),y:Math.max(0,r.top),w:Math.min(innerWidth,r.right)-Math.max(0,r.left),h:Math.min(innerHeight,r.bottom)-Math.max(0,r.top),capture:state,plain};
        })()
        """
        view.evaluateJavaScript(extraction) { [weak self] value, _ in
            guard let self = self, self.completion != nil, let rect = value as? [String: Any], let x=rect["x"] as? Double, let y=rect["y"] as? Double, let w=rect["w"] as? Double, let h=rect["h"] as? Double, w>100, h>100 else { self?.finish(nil); return }
            let region=NSRect(x:x,y:y,width:w,height:h).intersection(self.view.bounds)
            let capture=rect["capture"] as? [String:Any] ?? [:]
            if self.pagesRead == 0, let plain = rect["plain"] as? String, let url = self.view.url?.absoluteString {
                self.finish(Page(text:plain,url:url,capture:capture,top:0,bottom:CGFloat((capture["maximum"] as? Double) ?? h),recognized:false))
                return
            }
            let offset = CGFloat((capture["current"] as? Double) ?? 0)
            let previousBottom = self.collectedBottom
            let config=WKSnapshotConfiguration();config.rect=region;config.snapshotWidth=NSNumber(value:min(2400,region.width*2))
            self.view.takeSnapshot(with:config) { [weak self] image,_ in
                guard let self = self, self.completion != nil, let image=image,let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),let url=self.view.url?.absoluteString else { self?.finish(nil);return }
                DispatchQueue.global(qos:self.published ? .utility : .userInitiated).async {
                    let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate; request.minimumTextHeight = 0.003
                    request.recognitionLanguages=["zh-Hans","en-US"];request.usesLanguageCorrection=true
                    do {
                        try VNImageRequestHandler(cgImage:cg,options:[:]).perform([request])
                        let lines=(request.results ?? []).filter { line in
                            let b=line.boundingBox
                            let position = offset + region.minY + (1-b.midY)*region.height
                            if let bottom = previousBottom, position <= bottom + b.height*region.height*0.3 { return false }
                            let atEnd = offset >= CGFloat((capture["maximum"] as? Double) ?? .greatestFiniteMagnitude)-2
                            guard (atEnd || b.minY*region.height>3),(offset<=2 || b.maxY*region.height<region.height-3),let text=line.topCandidates(1).first?.string else{return false}
                            return !["上一章","下一章","上一页","下一页","<上一页","下一页>","<上一页下一页>","书城","目录"].contains(text.filter { !$0.isWhitespace }) && !text.contains("去微信读书")
                        }
                        let ordered = lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                        var rows: [[VNRecognizedTextObservation]] = []
                        for line in ordered {
                            if let reference = rows.last?.first, abs(reference.boundingBox.midY-line.boundingBox.midY) < min(reference.boundingBox.height,line.boundingBox.height)*0.45 {
                                rows[rows.count-1].append(line)
                            } else { rows.append([line]) }
                        }
                        let readingLines = rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
                        let text = ReadingParagraphs.text(from: readingLines)
                        let positions=readingLines.map{offset+region.minY+(1-$0.boundingBox.midY)*region.height}
                        DispatchQueue.main.async {
                            guard self.completion != nil else{return}
                            guard let top=positions.min(),let bottom=positions.max(), self.published || text.count>=80 else{
                                if self.captureRetries < 3 {
                                    self.captureRetries += 1
                                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5){[weak self] in self?.capture()}
                                } else { self.finish(nil) }
                                return
                            }
                            self.captureRetries = 0
                            self.collectedText += self.collectedText.isEmpty ? text : "\n\n" + text
                            self.collectedTop = self.collectedTop ?? top; self.collectedBottom = bottom
                            self.pagesRead += 1; self.published = true
                            self.completion?(Page(text:self.collectedText,url:url,capture:capture,top:self.collectedTop!,bottom:bottom))
                            guard self.completion != nil else { return }
                            if self.pagesRead >= Self.maximumPages || self.collectedText.count >= Self.maximumCharacters { self.finish(nil); return }
                            self.view.evaluateJavaScript("window.floatingReaderAdvancePage?.(true, \(Double(bottom)))") { [weak self] result,_ in
                                guard let self = self, self.completion != nil else { return }
                                if result as? String == "moved" {
                                    DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self] in self?.capture() }
                                } else { self.finish(nil) }
                            }
                        }
                    } catch { DispatchQueue.main.async {self.finish(nil)} }
                }
            }
        }
    }
    func endActivity() {
        if let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { sourceUsable = false; finish(nil) }
    func detachPage() -> WKWebView? {
        guard sourceUsable else { cancel(); return nil }
        completion = nil; timer?.invalidate(); timer = nil; endActivity()
        view.stopLoading(); view.navigationDelegate = nil; view.removeFromSuperview(); host.close()
        return view
    }
    func finish(_ page: Page?) {
        timer?.invalidate();timer=nil;endActivity();view.stopLoading();host.close()
        let callback=completion;completion=nil; if page != nil || !published { callback?(page) }
    }
    func cancel() { completion=nil;timer?.invalidate();timer=nil;endActivity();view.stopLoading();host.close() }
    deinit { timer?.invalidate(); endActivity() }

}

final class ReaderWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func focusForInteraction() {
        // The nonactivating panel stays above other apps' full-screen spaces, but
        // an explicit click must still give this app keyboard focus before dragging.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !isKeyWindow { makeKeyAndOrderFront(nil) }
        if !isMainWindow { makeMain() }
    }
    func resizeEdges(at point: NSPoint) -> (Bool, Bool, Bool, Bool) {
        guard styleMask.contains(.resizable), let content = contentView else { return (false, false, false, false) }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(kind), !button.isHidden {
                let local = button.convert(point, from: nil)
                if button.bounds.insetBy(dx: -3, dy: -3).contains(local) { return (false, false, false, false) }
            }
        }
        let p = content.convert(point, from: nil), b = content.bounds
        let leftCorner = p.x <= b.minX + 24
        let rightCorner = p.x >= b.maxX - 24
        let bottomCorner = p.y <= b.minY + 24
        let topCorner = p.y >= b.maxY - 24
        if (leftCorner || rightCorner) && (bottomCorner || topCorner) {
            return (leftCorner, rightCorner, bottomCorner, topCorner)
        }
        return (p.x <= b.minX + 10, p.x >= b.maxX - 10, p.y <= b.minY + 10, p.y >= b.maxY - 10)
    }
    func isResizePoint(_ point: NSPoint) -> Bool {
        let edges = resizeEdges(at: point)
        return edges.0 || edges.1 || edges.2 || edges.3
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { focusForInteraction() }
        guard event.type == .leftMouseDown, isResizePoint(event.locationInWindow) else { super.sendEvent(event); return }
        let edges = resizeEdges(at: event.locationInWindow)
        let start = frame, mouse = convertPoint(toScreen: event.locationInWindow)
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            let dx = current.x - mouse.x, dy = current.y - mouse.y
            var rect = start
            if edges.0 { rect.origin.x = min(start.maxX - 1, start.minX + dx); rect.size.width = start.maxX - rect.minX }
            if edges.1 { rect.size.width = max(1, start.width + dx) }
            if edges.2 { rect.origin.y = min(start.maxY - 1, start.minY + dy); rect.size.height = start.maxY - rect.minY }
            if edges.3 { rect.size.height = max(1, start.height + dy) }
            setFrame(rect, display: true)
        }
    }
}

final class ReaderBorderView: NSView {
    var color = NSColor.windowBackgroundColor
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        outline.lineWidth = 4; outline.stroke()
        // A visible corner grip identifies the resize target without blocking text selection.
        NSColor.secondaryLabelColor.setStroke()
        for offset in [CGFloat(5), 10, 15] {
            let grip = NSBezierPath()
            grip.move(to: NSPoint(x: bounds.maxX - offset - 4, y: 4))
            grip.line(to: NSPoint(x: bounds.maxX - 4, y: offset + 4))
            grip.lineWidth = 1; grip.stroke()
        }
    }
}

final class DraggableBlankView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { fillColor.setFill(); bounds.fill() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

final class ReadingScrollView: NSScrollView {
    var atEdge: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) {
        let before = contentView.bounds.origin.y
        guard let document = documentView else { return }
        let maximum = max(0, document.frame.height - contentView.bounds.height)
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 32
        let destination = min(maximum, max(0, before - event.scrollingDeltaY * scale))
        contentView.scroll(to: NSPoint(x: 0, y: destination))
        reflectScrolledClipView(contentView)
        guard event.scrollingDeltaY != 0 else { return }
        if event.scrollingDeltaY < 0 && destination >= maximum - 2 { atEdge?(true) }
        if event.scrollingDeltaY > 0 && destination <= 2 { atEdge?(false) }
    }
}
final class DraggableTextView: NSTextView {
    var dragEnabled = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) { enclosingScrollView?.scrollWheel(with: event) }
    override func mouseDown(with event: NSEvent) {
        if dragEnabled { window?.performDrag(with: event); return }
        super.mouseDown(with: event)
    }
}

struct ReadingAnchor: Codable {
    var offset: Int
    var sourceY: Double
    var url: String
}
struct ReadingBookmark: Codable {
    var url: String
    var sourceY: Double
    var cursor: Int
    var text: String
    var anchors: [ReadingAnchor]
    var recognized: Bool
    var updated: Double
}

struct ReaderShortcut: Codable, Equatable {
    var key: String
    var modifiers: UInt
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var label: String {
        if key.isEmpty { return "未设置" }
        let symbols: [String: String] = ["\u{F700}":"↑", "\u{F701}":"↓", "\u{F702}":"←", "\u{F703}":"→", " ":"空格", "\r":"回车", "\t":"Tab"]
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (symbols[key] ?? key.uppercased())
    }
}
final class ShortcutRowButton: NSButton { var shortcutID = "" }

final class ReaderDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSFontChanging, NSWindowDelegate {
    var window: NSWindow!
    var spaceObserver: NSObjectProtocol?
    var web: WKWebView!
    let browserHost = NSView()
    var renderingWindow: NSWindow?
    var sourceIsOffscreen = false
    var nextLoader: NextChapterLoader?
    var prefetchOwner = ""
    var preloadWatchdog: Timer?
    var preloadRetryAfter = Date.distantPast
    var preloadFailures = 0
    var preloadFailureOwner = ""
    var pendingNextAdvance: Bool?
    var bottomAdvanceRequested = false
    var sourceAtEnd = false
    var cachedSourceResume: (() -> Void)?
    var prefetchBudget = 0
    var prefetchOnly = false
    let readerBorder = ReaderBorderView()
    var lineHeightMultiple: CGFloat = 1.4
    let lineHeightLabel = NSTextField(labelWithString: "")
    var backgroundNextLoading = false
    var preparingBackground = false
    var sourceAhead = false
    var nextChapterCache: String?
    var nextChapterOCR = false
    var savedCapture: [String: Any] = [:]
    var nextCapture: [String: Any] = [:]
    var recognizedTop: CGFloat?
    var recognizedBottom: CGFloat?
    var nextRecognizedTop: CGFloat?
    var nextRecognizedBottom: CGFloat?
    var savedRecognizedTop: CGFloat?
    var savedRecognizedBottom: CGFloat?
    var skippedOverlapLines = 0
    var catalogIsOpen = false
    var preloadCurrentOCR = false
    var recognitionRetries = 0
    let root = DraggableBlankView()
    let titleBackdrop = NSView()
    var titleBackdropHeight: NSLayoutConstraint!
    var toolbarTop: NSLayoutConstraint!
    let bar = NSStackView()
    let styleBar = NSStackView()
    let styleToolbar = NSScrollView()
    let fontSizeLabel = NSTextField(labelWithString: "")
    var sizeAdjustmentPanel: NSPanel?
    var spacingAdjustmentPanel: NSPanel?
    var sizeAdjustmentSlider: NSSlider?
    var spacingAdjustmentSlider: NSSlider?
    let scroll = ReadingScrollView()
    let text = DraggableTextView()
    let defaults = UserDefaults.standard
    var pure = false
    var hiddenBar = false
    var transparent = false
    var pinned = true
    let pinButton = NSButton()
    let themeButton = NSButton()
    let modeButton = NSButton()
    let shortcutsButton = NSButton()
    var lastVisibleOpacity: CGFloat = 1
    var dark = false
    var customInk = false
    var originalWeb = false
    var rawOnlyURL = ""
    var readerURLObservation: NSKeyValueObservation?
    var size: CGFloat = 14
    var ink = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
    var contentTop: NSLayoutConstraint!
    var background = NSColor(srgbRed: 251.0/255, green: 246.0/255, blue: 237.0/255, alpha: 1)
    var customBackground = false
    var editingBackground = false
    var acceptingPickerChanges = false
    var pickerObserver: NSObjectProtocol?
    let presetHexes = ["333333", "666666", "999999", "FFFFFF", "FBF6ED", "E8DFC9", "D6E5D8", "1A1A1A"]
    var inkPicker: NSColorPanel?
    var backgroundPicker: NSColorPanel?
    var fontName = ""
    var preparingText = false
    var dragMonitor: Any?
    var pendingStyle: (() -> Void)?
    var chromeVisible = true
    var updatingAppearance = false
    var backgroundOpacity: CGFloat = 1
    var resizeObserver: NSObjectProtocol?
    var changingChapter = false
    var textHasWebSource = false
    let backgroundButton = NSButton()
    let status = NSTextField(labelWithString: "打开书籍后可调整正文外观")
    var contentBottom: NSLayoutConstraint!
    var textWasRecognized = false
    let chapterFooter = DraggableBlankView()
    let previousLink = NSButton(title: "←", target: nil, action: nil)
    let nextLink = NSButton(title: "→", target: nil, action: nil)
    let toolbarScroll = NSScrollView()
    var keyMonitor: Any?
    var shortcutItems: [(String, NSMenuItem)] = []
    var defaultShortcuts: [String: ReaderShortcut] = [:]
    var customShortcuts: [String: ReaderShortcut] = [:]
    var shortcutPanel: NSPanel?
    var recordingShortcut: ShortcutRowButton?
    var shortcutButtons: [String: ShortcutRowButton] = [:]
    let shortcutMessage = NSTextField(labelWithString: "")
    var continuing = false
    var lastEdge = Date.distantPast
    var appendRecognition = false
    var appendOriginal = ""
    var appendScrollPosition: CGFloat = 0
    var appendForward = true
    var chainedText: String?
    var chainedForward = true
    var chainedPosition: CGFloat = 0
    var hoverScrollMonitor: Any?
    var routingHoverScroll = false
    var readGeneration = 0
    var automaticLoadingPaused = false
    var readingAnchors: [ReadingAnchor] = []
    var cachedChapterURL = ""
    var progressObserver: NSObjectProtocol?
    var progressWork: DispatchWorkItem?
    var rawProgressTimer: Timer?
    var rawReadingY: Double = 0
    var rawReadingURL = ""
    var initialOpening = true
    var pendingReadingBookmark: ReadingBookmark?
    var restoringReading = false
    var preferWebsiteProgress = true
    var forceWebsiteProgress = false
    var finishingReadingSession = false
    var repliedToTermination = false
    var terminatingBookmark: ReadingBookmark?

    func applicationDidFinishLaunching(_ notification: Notification) {
        lineHeightMultiple = CGFloat(defaults.object(forKey: "lineHeight") as? Double ?? 1.4)
        backgroundOpacity = CGFloat(defaults.object(forKey: "backgroundOpacity") as? Double ?? 1)
        lastVisibleOpacity = CGFloat(defaults.object(forKey: "lastVisibleOpacity") as? Double ?? 1)
        fontName = defaults.string(forKey: "fontName") ?? ""
        size = CGFloat(defaults.object(forKey: "fontSize") as? Double ?? 14)
        transparent = false
        backgroundOpacity = 1 // Always launch with readable chrome; hiding remains an explicit action.
        dark = defaults.bool(forKey: "dark")
        customInk = defaults.bool(forKey: "customInk")
        customBackground = defaults.bool(forKey: "customBackground")
        if let hex = defaults.string(forKey: "background"), let value = UInt32(hex, radix: 16) {
            background = NSColor(srgbRed: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1)
        }
        pinned = defaults.object(forKey: "pinned") as? Bool ?? true
        if let hex = defaults.string(forKey: "ink"), let value = UInt32(hex, radix: 16) {
            ink = NSColor(srgbRed: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1)
        }
        if let data = defaults.data(forKey: "inkColor"), let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { ink = saved }
        if let data = defaults.data(forKey: "backgroundColor"), let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { background = saved }
        // Apply the requested palette once when upgrading; later user choices persist.
        if !defaults.bool(forKey: "readingPaletteV2") {
            dark = false; customInk = false; customBackground = false
            defaults.set(true, forKey: "readingPaletteV2")
        }
        if !customInk { ink = dark ? NSColor(srgbRed: 0.88, green: 0.88, blue: 0.88, alpha: 1) : NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1) }
        if !customBackground { background = dark ? NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1) : NSColor(srgbRed: 251.0/255, green: 246.0/255, blue: 237.0/255, alpha: 1) }
        window = ReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "浮读 0.26.18 · 微信读书"
        window.minSize = .zero
        window.contentMinSize = .zero
        window.contentView = root
        window.delegate = self
        window.setFrameAutosaveName("FloatingReaderWindow")
        window.center()
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        if let panel = window as? NSPanel {
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = false
            panel.becomesKeyOnlyIfNeeded = false
        }
        configureWindowStacking()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self, self.pinned, self.window.isVisible, !self.window.isMiniaturized, !self.finishingReadingSession else { return }
                self.window.orderFrontRegardless()
            }
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        if let url = Bundle.main.url(forResource: "reader", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: config)
        web.autoresizingMask = [.width, .height]
        browserHost.addSubview(web)
        web.navigationDelegate = self
        readerURLObservation = web.observe(\.url, options: [.new]) { [weak self] view, _ in
            guard let url = view.url else { return }
            self?.autoReadBook(url)
        }
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        bar.orientation = .horizontal
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let buttons: [(String, String, Selector)] = [
            ("书架", "book-open", #selector(home)), ("后退", "arrow-left", #selector(back)),
            ("章节选择", "list", #selector(openChapters))
        ]
        for (title, icon, action) in buttons {
            let button = NSButton()
            configureIcon(button, title: title, icon: icon, action: action)
            bar.addArrangedSubview(button)
        }
        modeButton.target = self; modeButton.action = #selector(togglePure)
        modeButton.isBordered = false; modeButton.imagePosition = .noImage
        modeButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        modeButton.font = .systemFont(ofSize: 11)
        modeButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        bar.insertArrangedSubview(modeButton, at: 2)
        configureIcon(pinButton, title: "取消置顶", icon: "anchor", action: #selector(togglePin))
        configureIcon(themeButton, title: "深色正文", icon: "moon", action: #selector(toggleTheme))
        bar.addArrangedSubview(pinButton)
        configureIcon(shortcutsButton, title: "修改快捷键", icon: "keyboard-settings", action: #selector(showShortcutSettings))
        for constraint in shortcutsButton.constraints where constraint.firstAttribute == .width || constraint.firstAttribute == .height { constraint.isActive = false }
        shortcutsButton.widthAnchor.constraint(equalToConstant: 46).isActive = true
        shortcutsButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        configureIcon(backgroundButton, title: "隐藏／恢复工具栏与正文背景", icon: "background-hidden", action: #selector(toggleBar))
        styleBar.orientation = .horizontal
        styleBar.spacing = 8
        styleBar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        for (title, icon, action) in [
            ("文字大小", "font-size", #selector(fontSizePanel)),
            ("文字间距（行间距）", "line-height", #selector(lineHeightPanel)),
            ("文字颜色", "text-color", #selector(color)),
            ("文字字体", "font-family", #selector(fontPicker)),
            ("正文背景色", "background-color", #selector(backgroundColor))
        ] {
            let button = NSButton()
            configureIcon(button, title: title, icon: icon, action: action)
            styleBar.addArrangedSubview(button)
        }
        bar.addArrangedSubview(backgroundButton)
        styleToolbar.documentView = styleBar
        styleToolbar.hasHorizontalScroller = false
        styleToolbar.hasVerticalScroller = false
        styleBar.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.isSelectable = false
        text.isRichText = false
        text.usesAdaptiveColorMappingForDarkAppearance = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.allowsNonContiguousLayout = false
        text.layoutManager?.usesFontLeading = true
        text.textContainer?.containerSize = NSSize(width: 660, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        text.textContainerInset = NSSize(width: 24, height: 28)
        scroll.documentView = text
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        toolbarScroll.documentView = bar
        toolbarScroll.hasHorizontalScroller = false
        toolbarScroll.hasVerticalScroller = false
        toolbarScroll.drawsBackground = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        for (button, action) in [(previousLink, #selector(previousChapter)), (nextLink, #selector(nextChapter))] {
            button.target = self; button.action = action
            button.isBordered = false
            button.font = .systemFont(ofSize: 13)
            button.translatesAutoresizingMaskIntoConstraints = false
            chapterFooter.addSubview(button)
        }
        NSLayoutConstraint.activate([
            previousLink.leadingAnchor.constraint(equalTo: chapterFooter.leadingAnchor, constant: 20),
            previousLink.centerYAnchor.constraint(equalTo: chapterFooter.centerYAnchor),
            nextLink.trailingAnchor.constraint(equalTo: chapterFooter.trailingAnchor, constant: -20),
            nextLink.centerYAnchor.constraint(equalTo: chapterFooter.centerYAnchor)
        ])
        text.addSubview(chapterFooter)
        previousLink.toolTip = "上一章"
        previousLink.setAccessibilityLabel("上一章")
        nextLink.toolTip = "下一章"
        nextLink.setAccessibilityLabel("下一章")
        scroll.atEdge = { [weak self] forward in
            guard let self = self else { return }
            if forward { self.bottomAdvanceRequested = true }
            self.lastEdge = .distantPast
            self.continueReading(forward: forward)
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for v in [titleBackdrop, toolbarScroll, browserHost, scroll, styleToolbar, shortcutsButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        text.addSubview(status)
        status.isBordered = false; status.drawsBackground = false
        contentTop = browserHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 48)
        contentBottom = browserHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -48)
        titleBackdropHeight = titleBackdrop.heightAnchor.constraint(equalToConstant: 28)
        toolbarTop = toolbarScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 28)
        NSLayoutConstraint.activate([
            titleBackdrop.topAnchor.constraint(equalTo: root.topAnchor), titleBackdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor), titleBackdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor), titleBackdropHeight,
            toolbarScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), toolbarScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -46), toolbarTop, toolbarScroll.heightAnchor.constraint(equalToConstant: 48),
            shortcutsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor), shortcutsButton.centerYAnchor.constraint(equalTo: toolbarScroll.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: toolbarScroll.contentView.leadingAnchor), bar.topAnchor.constraint(equalTo: toolbarScroll.contentView.topAnchor), bar.heightAnchor.constraint(equalToConstant: 48),
            styleToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor), styleToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor), styleToolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor), styleToolbar.heightAnchor.constraint(equalToConstant: 48),
            styleBar.leadingAnchor.constraint(equalTo: styleToolbar.contentView.leadingAnchor), styleBar.topAnchor.constraint(equalTo: styleToolbar.contentView.topAnchor), styleBar.heightAnchor.constraint(equalToConstant: 48),
            contentTop, contentBottom, browserHost.leadingAnchor.constraint(equalTo: root.leadingAnchor), browserHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: browserHost.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: browserHost.bottomAnchor)
        ])
        readerBorder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(readerBorder)
        NSLayoutConstraint.activate([
            readerBorder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            readerBorder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            readerBorder.topAnchor.constraint(equalTo: root.topAnchor),
            readerBorder.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        let preloadTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.maintainNextPreload() }
        preloadWatchdog = preloadTimer; RunLoop.main.add(preloadTimer, forMode: .common)
        progressObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.scheduleReadingProgress() }
        scroll.contentView.postsFrameChangedNotifications = true
        resizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.layoutText() }
        scroll.isHidden = true
        createMenu()
        applyAppearance()
        rawProgressTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshRawReading() }
        if let timer = rawProgressTimer { RunLoop.main.add(timer, forMode: .common) }
        home()
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            (self.window as? ReaderWindow)?.focusForInteraction()
            if let window = self.window as? ReaderWindow, window.isResizePoint(event.locationInWindow) { return event }
            let rootPoint = self.root.convert(event.locationInWindow, from: nil)
            guard self.root.bounds.contains(rootPoint) else { return event }
            if !self.hiddenBar && rootPoint.y > self.window.contentLayoutRect.maxY { return event }
            if self.hiddenBar {
                self.window.performDrag(with: event)
                return nil
            }
            if self.pure {
                var hit = self.root.hitTest(rootPoint)
                while let view = hit, view !== self.root {
                    if view is NSTextView || view is NSButton || view is NSSlider { return event }
                    if let field = view as? NSTextField, field.isEditable || field.isSelectable { return event }
                    hit = view.superview
                }
                self.window.performDrag(with: event)
                return nil
            }
            let point = self.web.convert(event.locationInWindow, from: nil)
            guard self.web.bounds.contains(point) else { return event }
            let x = Double(point.x), y = Double(self.web.isFlipped ? point.y : self.web.bounds.height - point.y)
            self.web.evaluateJavaScript("window.floatingReaderBlankAt?.(\(x), \(y))") { result, _ in
                if result as? Bool == true { self.window.performDrag(with: event) }
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.recordingShortcut != nil, event.window === self.shortcutPanel {
                self.recordShortcut(event); return nil
            }
            guard event.window === self.window, self.window.attachedSheet == nil else { return event }
            if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self); return nil
            }
            if let item = self.matchingShortcut(event), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item); return nil
            }
            return event
        }
        hoverScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, !self.routingHoverScroll,
                  event.window === self.window else { return event }
            self.routingHoverScroll = true
            if self.pure { self.scroll.scrollWheel(with: event) }
            else { self.web.scrollWheel(with: event) }
            self.routingHoverScroll = false
            return nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func configureIcon(_ button: NSButton, title: String, icon: String, action: Selector) {
        button.title = ""
        button.image = iconImage(icon)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.target = self
        button.action = action
        button.toolTip = title
        button.setAccessibilityLabel(title)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 30), button.heightAnchor.constraint(equalToConstant: 30)])
    }
    func iconImage(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"), let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
    func layoutText() {
        guard let container = text.textContainer, let manager = text.layoutManager else { return }
        root.layoutSubtreeIfNeeded()
        if !sourceIsOffscreen { web.frame = browserHost.bounds }
        let toolbarSize = bar.fittingSize
        bar.setFrameSize(NSSize(width: toolbarSize.width, height: 48))
        let width = max(1, scroll.contentSize.width)
        text.setFrameSize(NSSize(width: width, height: max(1, text.frame.height)))
        container.containerSize = NSSize(width: max(1, width - text.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: (text.string as NSString).length), actualCharacterRange: nil)
        manager.ensureLayout(for: container)
        let textHeight = ceil(manager.usedRect(for: container).height) + text.textContainerInset.height * 2
        let footerHeight: CGFloat = chapterFooter.isHidden ? 0 : max(40, size * 1.6)
        let statusHeight: CGFloat = hiddenBar ? 0 : 20
        let height = max(scroll.contentSize.height, textHeight + footerHeight + statusHeight)
        text.setFrameSize(NSSize(width: width, height: height))
        chapterFooter.frame = NSRect(x: 0, y: textHeight, width: width, height: footerHeight)
        status.frame = NSRect(x: 24, y: textHeight + footerHeight, width: max(1, width - 48), height: statusHeight)
        let bounds = scroll.contentView.constrainBoundsRect(scroll.contentView.bounds)
        scroll.contentView.scroll(to: bounds.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func createMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出浮读", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editItem.submenu = editMenu; menu.addItem(editItem)
        let reading = NSMenuItem(title: "阅读", action: nil, keyEquivalent: "")
        let actions = NSMenu()
        for (title, action, key) in [("隐藏／恢复工具栏与正文背景", #selector(toggleBar), "/"), ("切换纯文字／网页", #selector(togglePure), "r"), ("隐藏／恢复工具栏与正文背景（兼容键）", #selector(toggleBackground), "b"), ("切换置顶", #selector(togglePin), "p"), ("粘贴文字", #selector(pasteText), "v"), ("增大字号", #selector(larger), "+"), ("减小字号", #selector(smaller), "-"), ("文字颜色", #selector(color), "k"), ("正文背景色", #selector(backgroundColor), "j"), ("选择本机字体", #selector(fontPicker), "f"), ("行间距", #selector(lineHeightPanel), "h"), ("章节选择", #selector(openChapters), "d"), ("上一章", #selector(previousChapter), "["), ("下一章", #selector(nextChapter), "]"), ("识别当前可见页（可能有错字）", #selector(explicitOCR), ""), ("打开微信读书", #selector(home), "1"), ("显示工具栏（保留正文设置）", #selector(resetAppearance), "0")] {
            let item = actions.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        reading.submenu = actions
        for (title, action) in [("置顶", #selector(pin)), ("取消置顶", #selector(unpin)), ("深色模式", #selector(darkTheme)), ("浅色模式", #selector(lightTheme))] {
            let item = actions.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        for (title, action, key) in [("重新加载网页", #selector(reloadWeb), "l"), ("恢复网页原样", #selector(restoreWeb), "g"), ("启用阅读样式", #selector(enableWebStyle), "e"), ("在浏览器中打开当前页", #selector(openInBrowser), "o")] {
            let item = actions.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        let resetStyle = actions.addItem(withTitle: "恢复默认阅读样式", action: #selector(resetReadingStyle), keyEquivalent: ""); resetStyle.target = self
        let diagnostics = actions.addItem(withTitle: "复制阅读诊断", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        let retry = actions.addItem(withTitle: "重新读取当前章节（不再次切章）", action: #selector(retryCurrentChapter), keyEquivalent: "")
        retry.target = self
        let recover = actions.addItem(withTitle: "恢复阅读窗口（保留配色）", action: #selector(recoverReader), keyEquivalent: "9")
        recover.target = self
        for (title, action) in [("继续上次浮读位置", #selector(resumeLastReading)), ("跟随微信读书阅读位置", #selector(resumeWebsiteReading))] {
            let item = actions.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        for (title, action, key) in [("上一章（箭头快捷键）", #selector(previousChapter), "\u{F700}"), ("下一章（箭头快捷键）", #selector(nextChapter), "\u{F701}"), ("快捷键设置", #selector(showShortcutSettings), "")] {
            let item = actions.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self
        }
        menu.addItem(reading)
        NSApp.mainMenu = menu
        collectShortcuts()
    }
    func collectShortcuts() {
        shortcutItems.removeAll(); defaultShortcuts.removeAll()
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { visit(submenu); continue }
                guard let action = item.action else { continue }
                if action == #selector(NSText.copy(_:)) { continue }
                if action == #selector(pin) || action == #selector(unpin) { continue }
                let id = NSStringFromSelector(action)
                // Each menu item has a stable selector; the chapter arrow alternatives have their own rows.
                let unique = shortcutItems.contains(where: { $0.0 == id }) ? id + ".alternate" : id
                shortcutItems.append((unique, item))
                defaultShortcuts[unique] = ReaderShortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask.rawValue)
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
        if let data = defaults.data(forKey: "readerShortcuts"), let saved = try? JSONDecoder().decode([String: ReaderShortcut].self, from: data) { customShortcuts = saved }
        let toggleID = NSStringFromSelector(#selector(togglePin))
        for legacy in [NSStringFromSelector(#selector(pin)), NSStringFromSelector(#selector(unpin))] {
            if let value = customShortcuts.removeValue(forKey: legacy), !value.key.isEmpty, customShortcuts[toggleID] == nil { customShortcuts[toggleID] = value }
        }
        updateShortcuts()
    }
    func binding(_ id: String) -> ReaderShortcut { customShortcuts[id] ?? defaultShortcuts[id] ?? ReaderShortcut(key: "", modifiers: 0) }
    func shortcutHint(_ action: Selector) -> String {
        let id = NSStringFromSelector(action), value = binding(id)
        return value.key.isEmpty ? "" : "（" + value.label + "）"
    }
    func updateShortcuts() {
        for (id, item) in shortcutItems {
            let value = binding(id)
            item.keyEquivalent = value.key; item.keyEquivalentModifierMask = value.flags
            if let button = shortcutButtons[id], recordingShortcut !== button { button.title = value.label }
        }
        previousLink.toolTip = "上一章" + shortcutHint(#selector(previousChapter))
        nextLink.toolTip = "下一章" + shortcutHint(#selector(nextChapter))
        modeButton.toolTip = (pure ? "当前为纯文字，点击切换到原网页" : "当前为原网页，点击生成纯文字") + shortcutHint(#selector(togglePure))
    }
    func normalizedShortcutKey(_ key: String) -> String { key == "=" ? "+" : key.lowercased() }
    func shortcutForEvent(_ event: NSEvent) -> ReaderShortcut {
        let special: [UInt16: String] = [126:"\u{F700}", 125:"\u{F701}", 123:"\u{F702}", 124:"\u{F703}"]
        let key = special[event.keyCode] ?? (event.keyCode == 24 ? "+" : event.charactersIgnoringModifiers ?? "")
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return ReaderShortcut(key: normalizedShortcutKey(key), modifiers: flags.rawValue)
    }
    func matchingShortcut(_ event: NSEvent) -> NSMenuItem? {
        let incoming = shortcutForEvent(event)
        return shortcutItems.first(where: { id, _ in
            let value = binding(id)
            if value.key.isEmpty { return false }
            var flags = incoming.flags
            // Both Command-= and Command-Shift-= invoke the default plus shortcut.
            if normalizedShortcutKey(value.key) == "+" && !value.flags.contains(.shift) { flags.remove(.shift) }
            return normalizedShortcutKey(value.key) == incoming.key && flags == value.flags
        })?.1
    }
    func saveShortcut(_ value: ReaderShortcut, id: String) -> String? {
        if normalizedShortcutKey(value.key) == "c" && value.flags == .command { return "Command+C 保留用于复制选中文字。" }
        if !value.key.isEmpty, let conflict = shortcutItems.first(where: { other, _ in
            let existing = binding(other)
            return other != id && !existing.key.isEmpty && normalizedShortcutKey(existing.key) == normalizedShortcutKey(value.key) && (normalizedShortcutKey(value.key) == "+" ? existing.flags.subtracting(.shift) == value.flags.subtracting(.shift) : existing.modifiers == value.modifiers)
        }) { return "已用于「" + conflict.1.title + "」，请换一个组合，或先清除该功能的快捷键。" }
        customShortcuts[id] = value
        if let data = try? JSONEncoder().encode(customShortcuts) { defaults.set(data, forKey: "readerShortcuts") }
        updateShortcuts(); return nil
    }
    @objc func editShortcut(_ sender: ShortcutRowButton) {
        if let previous = recordingShortcut { previous.title = binding(previous.shortcutID).label }
        recordingShortcut = sender; sender.title = "请按快捷键…"
        shortcutMessage.stringValue = "按新组合键；Esc 取消，Delete 清除。"
    }
    func recordShortcut(_ event: NSEvent) {
        guard let button = recordingShortcut else { return }
        if event.keyCode == 53 { recordingShortcut = nil; updateShortcuts(); shortcutMessage.stringValue = "已取消修改。"; return }
        let value = shortcutForEvent(event)
        let clearing = [UInt16(51), UInt16(117)].contains(event.keyCode) && value.modifiers == 0
        if !clearing && value.flags.intersection([.command, .option, .control]).isEmpty {
            shortcutMessage.stringValue = "请包含 ⌘、⌥ 或 ⌃，以免影响正文选字和输入。"; return
        }
        if !clearing && value.key.isEmpty { shortcutMessage.stringValue = "没有识别到按键，请再试一次。"; return }
        let chosen = clearing ? ReaderShortcut(key: "", modifiers: 0) : value
        if let error = saveShortcut(chosen, id: button.shortcutID) { shortcutMessage.stringValue = error; return }
        recordingShortcut = nil; updateShortcuts(); shortcutMessage.stringValue = "已保存，立即生效。"
    }
    @objc func resetShortcuts() {
        recordingShortcut = nil; customShortcuts.removeAll(); defaults.removeObject(forKey: "readerShortcuts")
        updateShortcuts(); shortcutMessage.stringValue = "已恢复全部默认快捷键。"
    }
    @objc func closeShortcutSettings() {
        recordingShortcut = nil
        if let panel = shortcutPanel { window.endSheet(panel); panel.orderOut(nil) }
        shortcutPanel = nil; shortcutButtons.removeAll()
    }
    @objc func showShortcutSettings() {
        guard window.attachedSheet == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 530), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "快捷键设置"; panel.appearance = window.appearance
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: window.appearance?.name == .darkAqua ? 0.13 : 0.96, alpha: 1).cgColor
        let heading = NSTextField(labelWithString: "点击右侧快捷键，然后按下新的组合键")
        heading.frame = NSRect(x: 20, y: 486, width: 540, height: 24); content.addSubview(heading)
        let list = NSScrollView(frame: NSRect(x: 20, y: 92, width: 540, height: 384))
        list.hasVerticalScroller = true; list.autohidesScrollers = true; list.borderType = .bezelBorder
        let height = CGFloat(shortcutItems.count) * 36 + 8
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: height))
        shortcutButtons.removeAll()
        for (index, entry) in shortcutItems.enumerated() {
            let (id, item) = entry, y = height - CGFloat(index + 1) * 36
            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: 12); label.frame = NSRect(x: 12, y: y + 8, width: 324, height: 20)
            let button = ShortcutRowButton(title: binding(id).label, target: self, action: #selector(editShortcut(_:)))
            button.shortcutID = id; button.bezelStyle = .rounded
            button.frame = NSRect(x: 344, y: y + 3, width: 162, height: 30)
            button.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            document.addSubview(label); document.addSubview(button); shortcutButtons[id] = button
        }
        list.documentView = document; content.addSubview(list)
        list.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - list.contentSize.height)))
        shortcutMessage.frame = NSRect(x: 20, y: 55, width: 540, height: 30)
        shortcutMessage.font = .systemFont(ofSize: 11); shortcutMessage.maximumNumberOfLines = 2
        shortcutMessage.stringValue = "自动保存。Esc 取消当前录入，Delete 清除选中功能的快捷键。"
        content.addSubview(shortcutMessage)
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetShortcuts))
        reset.frame = NSRect(x: 20, y: 12, width: 110, height: 32); reset.bezelStyle = .rounded; content.addSubview(reset)
        let done = NSButton(title: "完成", target: self, action: #selector(closeShortcutSettings))
        done.frame = NSRect(x: 470, y: 12, width: 90, height: 32); done.bezelStyle = .rounded; content.addSubview(done)
        shortcutPanel = panel; window.beginSheet(panel)
    }
    func storedBookmark() -> ReadingBookmark? {
        guard let data = defaults.data(forKey: "lastReadingBookmark"), let value = try? JSONDecoder().decode(ReadingBookmark.self, from: data), validReadingURL(value.url) else { return nil }
        return value
    }
    func validReadingURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host == "weread.qq.com" && url.path.hasPrefix("/web/reader/")
    }
    func bookEntryURL(_ value: String) -> URL? {
        guard validReadingURL(value), var parts = URLComponents(string: value) else { return nil }
        // Known reader routes use a hexadecimal book token and an optional k + chapter token.
        if let range = parts.path.range(of: "k[0-9a-f]+$", options: .regularExpression) { parts.path.removeSubrange(range) }
        parts.fragment = nil; parts.query = nil
        return parts.url
    }
    func recordReadingAnchor(_ content: String, sourceY: Double, url: String) {
        guard pure, textHasWebSource, validReadingURL(url), !content.isEmpty else { return }
        let range = (text.string as NSString).range(of: content, options: .backwards)
        guard range.location != NSNotFound else { return }
        readingAnchors.removeAll { $0.offset == range.location }
        readingAnchors.append(ReadingAnchor(offset: range.location, sourceY: sourceY, url: url))
        readingAnchors.sort { $0.offset < $1.offset }
    }
    func currentReadingBookmark() -> ReadingBookmark? {
        guard pure, textHasWebSource, !text.string.isEmpty, !readingAnchors.isEmpty else { return nil }
        let point = NSPoint(x: text.textContainerInset.width + 2, y: scroll.contentView.bounds.minY + 4)
        let cursor = min((text.string as NSString).length, text.characterIndexForInsertion(at: point))
        let anchor = readingAnchors.last(where: { $0.offset <= cursor }) ?? readingAnchors[0]
        var sourceY = anchor.sourceY
        if let next = readingAnchors.first(where: { $0.offset > cursor && $0.url == anchor.url }), next.sourceY >= sourceY, next.offset > anchor.offset {
            sourceY += Double(cursor - anchor.offset) / Double(next.offset - anchor.offset) * (next.sourceY - anchor.sourceY)
        }
        let currentIndex = readingAnchors.lastIndex(where: { $0.offset <= cursor }) ?? 0
        var first = currentIndex, last = currentIndex
        while first > 0 && readingAnchors[first - 1].url == anchor.url { first -= 1 }
        while last + 1 < readingAnchors.count && readingAnchors[last + 1].url == anchor.url { last += 1 }
        let full = text.string as NSString
        let start = min(full.length, max(0, readingAnchors[first].offset))
        let end = last + 1 < readingAnchors.count ? min(full.length, readingAnchors[last + 1].offset) : full.length
        let snapshot = full.substring(with: NSRange(location: start, length: max(0, end - start)))
        let anchors = readingAnchors[first...last].map { ReadingAnchor(offset: $0.offset - start, sourceY: $0.sourceY, url: $0.url) }
        return ReadingBookmark(url: anchor.url, sourceY: max(0, sourceY - 24), cursor: max(0, cursor - start), text: snapshot, anchors: anchors, recognized: textWasRecognized, updated: Date().timeIntervalSince1970)
    }
    func refreshRawReading() {
        guard !pure, !restoringReading, !finishingReadingSession, let url = web.url?.absoluteString, validReadingURL(url) else { return }
        web.evaluateJavaScript("window.floatingReaderCaptureState?.()", completionHandler: { [weak self] result, _ in
            guard let self = self, !self.pure, !self.restoringReading, self.web.url?.absoluteString == url else { return }
            self.rawReadingURL = url; self.rawReadingY = (result as? [String: Any])?["current"] as? Double ?? 0
            self.saveReadingBookmark()
        })
    }
    @discardableResult func saveReadingBookmark() -> ReadingBookmark? {
        if restoringReading { return storedBookmark() }
        var bookmark = currentReadingBookmark()
        if bookmark == nil, !pure, let url = web.url?.absoluteString, validReadingURL(url) {
            bookmark = ReadingBookmark(url: url, sourceY: rawReadingURL == url ? rawReadingY : 0, cursor: 0, text: "", anchors: [], recognized: true, updated: Date().timeIntervalSince1970)
        }
        guard let value = bookmark else { return nil }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "lastReadingBookmark") }
        return value
    }
    func scheduleReadingProgress() {
        guard !finishingReadingSession, !restoringReading else { return }
        progressWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let value = self.saveReadingBookmark() else { return }
            guard !self.preparingText, !self.changingChapter, !self.backgroundNextLoading, !self.continuing, self.cachedSourceResume == nil else { return }
            if self.web.url?.absoluteString == value.url { self.applyWebsiteProgress(value, completion: {}) }
        }
        progressWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    func applyWebsiteProgress(_ value: ReadingBookmark, completion: @escaping () -> Void) {
        let full = value.text as NSString
        let start = min(value.cursor, full.length)
        let snippet = full.substring(with: NSRange(location: start, length: min(36, full.length - start))).trimmingCharacters(in: .whitespacesAndNewlines)
        let options: [String: Any] = ["y": value.sourceY, "snippet": snippet, "ratio": Double(start) / Double(max(1, full.length)), "recognized": value.recognized]
        guard let data = try? JSONSerialization.data(withJSONObject: options), let json = String(data: data, encoding: .utf8) else { completion(); return }
        web.evaluateJavaScript("window.floatingReaderSetReadingPosition?.(\(json))", completionHandler: { _, _ in completion() })
    }
    @objc func resumeLastReading() {
        guard let value = storedBookmark(), let url = URL(string: value.url) else { setStatus("还没有保存的阅读位置，请先打开一本书。"); return }
        saveReadingBookmark(); cancelPendingRead(); pendingReadingBookmark = value; preferWebsiteProgress = false; forceWebsiteProgress = false
        restoringReading = true; pure = false; showMode(); web.load(URLRequest(url: url))
    }
    @objc func resumeWebsiteReading() { openWebsiteReading(force: true) }
    func openWebsiteReading(force: Bool) {
        guard let value = storedBookmark(), let url = bookEntryURL(value.url) else { home(); return }
        saveReadingBookmark(); cancelPendingRead(); pendingReadingBookmark = value; preferWebsiteProgress = true; forceWebsiteProgress = force
        restoringReading = true; pure = false; showMode(); web.load(URLRequest(url: url))
    }
    func prefersNewWebsitePosition(_ value: ReadingBookmark, url: String, y: Double) -> Bool {
        preferWebsiteProgress && (forceWebsiteProgress || url != value.url || (y > 2 && abs(y - value.sourceY) > 80))
    }
    func scrollNativeReading(to cursor: Int) {
        guard let manager = text.layoutManager, let container = text.textContainer, !text.string.isEmpty else { return }
        let character = min(cursor, max(0, (text.string as NSString).length - 1))
        let glyph = manager.glyphIndexForCharacter(at: max(0, character))
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let y = min(max(0, text.frame.height - scroll.contentSize.height), max(0, rect.minY + text.textContainerOrigin.y - 4))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func restoreLocalBookmark(_ value: ReadingBookmark) {
        readingAnchors = value.anchors
        let positions = value.anchors.filter { $0.url == value.url }.map { $0.sourceY }
        recognizedTop = positions.min().map { CGFloat($0) }; recognizedBottom = positions.max().map { CGFloat($0) }
        textWasRecognized = value.recognized
        text.string = value.text; textHasWebSource = true; pure = true; showMode()
        scrollNativeReading(to: value.cursor)
        let range: [String: Double] = ["top": positions.min() ?? value.sourceY, "bottom": positions.max() ?? value.sourceY, "current": value.sourceY]
        if let data = try? JSONSerialization.data(withJSONObject: range), let json = String(data: data, encoding: .utf8) {
            web.evaluateJavaScript("window.floatingReaderRestoreKnownRange?.(\(json))", completionHandler: nil)
        }
    }
    func restorePendingReading(attempt: Int = 0) {
        guard restoringReading, let value = pendingReadingBookmark else { return }
        let generation = readGeneration
        web.evaluateJavaScript("({snapshot:window.floatingReaderChapterSnapshot?.(),state:window.floatingReaderCaptureState?.(),href:location.href})", completionHandler: { [weak self] result, _ in
            guard let self = self, self.restoringReading, self.pendingReadingBookmark != nil, self.readGeneration == generation else { return }
            let result = result as? [String: Any] ?? [:]
            let snapshot = result["snapshot"] as? [String: Any] ?? [:]
            if snapshot["ready"] as? Bool != true || self.web.isLoading {
                if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.restorePendingReading(attempt: attempt + 1) } }
                else { self.restoringReading = false; self.pendingReadingBookmark = nil; self.setStatus("阅读位置已保留；请登录微信读书或打开书籍后继续。"); }
                return
            }
            let currentURL = result["href"] as? String ?? ""
            let state = result["state"] as? [String: Any] ?? [:]
            let currentY = state["current"] as? Double ?? 0
            let entry = self.bookEntryURL(value.url)?.absoluteString
            if self.preferWebsiteProgress && currentURL == entry && currentURL != value.url && attempt < 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.restorePendingReading(attempt: attempt + 1) }; return
            }
            let useWebsite = self.prefersNewWebsitePosition(value, url: currentURL, y: currentY)
            self.pendingReadingBookmark = nil
            if useWebsite {
                self.restoringReading = false
                self.readingAnchors.removeAll()
                self.prepareText()
                self.setStatus("正在从微信读书当前打开的位置继续…")
                return
            }
            self.applyWebsiteProgress(value, completion: {
                guard self.restoringReading, self.readGeneration == generation else { return }
                if value.text.isEmpty {
                    self.restoringReading = false; self.prepareText(); return
                }
                self.restoreLocalBookmark(value)
                self.restoringReading = false
                self.setStatus("已恢复上次阅读位置 · 网页进度沿用微信读书的保存机制")
            })
        })
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finishingReadingSession { return .terminateNow }
        guard let value = saveReadingBookmark() else { return .terminateNow }
        finishingReadingSession = true; progressWork?.cancel(); readGeneration += 1
        setStatus("正在保存阅读位置…")
        preparingText = false; changingChapter = false; backgroundNextLoading = false
        terminatingBookmark = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishReadingTermination() }
        if !pure && !restoringReading && web.url?.absoluteString == value.url {
            web.evaluateJavaScript("window.floatingReaderCaptureState?.()", completionHandler: { [weak self] result, _ in
                guard let self = self else { return }
                var current = value
                current.sourceY = (result as? [String: Any])?["current"] as? Double ?? value.sourceY
                if let data = try? JSONEncoder().encode(current) { self.defaults.set(data, forKey: "lastReadingBookmark") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finishReadingTermination() }
            })
        } else if web.url?.absoluteString == value.url {
            applyWebsiteProgress(value, completion: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.finishReadingTermination() }
            })
        } else if let url = URL(string: value.url) { web.load(URLRequest(url: url)) }
        else { DispatchQueue.main.async { self.finishReadingTermination() } }
        return .terminateLater
    }
    func restoreClosingReading(attempt: Int = 0) {
        guard !repliedToTermination, let value = terminatingBookmark else { return }
        web.evaluateJavaScript("window.floatingReaderChapterSnapshot?.().ready", completionHandler: { [weak self] ready, _ in
            guard let self = self, !self.repliedToTermination else { return }
            if ready as? Bool == true {
                self.applyWebsiteProgress(value, completion: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finishReadingTermination() }
                })
            } else if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.restoreClosingReading(attempt: attempt + 1) }
            } else { self.finishReadingTermination() }
        })
    }
    func finishReadingTermination() {
        guard finishingReadingSession, !repliedToTermination else { return }
        repliedToTermination = true; NSApp.reply(toApplicationShouldTerminate: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === NSColorPanel.shared { finishColorPicker(); return true }
        if sender === window { NSApp.terminate(nil); return false }
        return true
    }
    func cancelPendingRead() {
        pendingNextAdvance = nil; bottomAdvanceRequested = false; sourceAtEnd = false; cachedSourceResume = nil
        preloadRetryAfter = .distantPast; preloadFailures = 0; preloadFailureOwner = ""
        nextLoader?.cancel(); nextLoader = nil; prefetchOwner = ""
        readGeneration += 1
        preparingText = false; changingChapter = false; continuing = false
        appendRecognition = false; chainedText = nil; pendingStyle = nil
        automaticLoadingPaused = false
        prefetchBudget = 0; prefetchOnly = false
        backgroundNextLoading = false; preparingBackground = false; sourceAhead = false; nextChapterCache = nil
        catalogIsOpen = false
    }
    @objc func home() {
        if initialOpening { initialOpening = false; if storedBookmark() != nil { openWebsiteReading(force: false); return } }
        saveReadingBookmark(); restoringReading = false; pendingReadingBookmark = nil
        cancelPendingRead(); pure = false; showMode(); web.load(URLRequest(url: URL(string: "https://weread.qq.com/")!))
    }
    @objc func back() { saveReadingBookmark(); restoringReading = false; pendingReadingBookmark = nil; cancelPendingRead(); pure = false; showMode(); web.goBack() }
    func continueReading(forward: Bool, prefetch: Bool = false) {
        guard pure, textHasWebSource, !catalogIsOpen, !backgroundNextLoading, !preparingText, !changingChapter, !continuing, !automaticLoadingPaused,
              Date().timeIntervalSince(lastEdge) > 1 else { return }
        lastEdge = Date()
        if forward && sourceAtEnd {
            if !prefetch { changeChapter("next", continuous: true) }
            return
        }
        if !prefetch && forward && !textWasRecognized && nextChapterCache != nil { changeChapter("next", continuous: true); return }
        if !textWasRecognized { changeChapter(forward ? "next" : "previous", continuous: true); return }
        continuing = true
        prefetchOnly = prefetch
        let generation = readGeneration
        setStatus(forward ? "正在接续后面的正文…" : "正在接续前面的正文…")
        let boundary = forward ? recognizedBottom : nil
        let sourceBoundary = boundary.map { String(Double($0)) } ?? "null"
        web.evaluateJavaScript("window.floatingReaderAdvancePage?.(\(forward ? "true" : "false"), \(sourceBoundary))", completionHandler: { [weak self] result, error in
            guard let self = self else { return }
            guard self.readGeneration == generation else { return }
            if result as? String == "moved" {
                self.sourceAtEnd = false
                self.appendOriginal = self.text.string
                self.appendScrollPosition = self.scroll.contentView.bounds.origin.y
                self.appendRecognition = true
                self.recognitionRetries = 0
                self.appendForward = forward
                self.preparingText = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.readGeneration == generation { self.recognizeVisiblePage() } }
            } else {
                self.continuing = false
                if forward && result as? String == "boundary" { self.sourceAtEnd = true }
                if prefetch {
                    self.prefetchBudget = 0; self.prefetchOnly = false; self.startNextChapterPreload()
                    self.resumeBottomAdvanceIfNeeded(); return
                }
                if result as? String == "boundary" { self.changeChapter(forward ? "next" : "previous", continuous: true) }
                else { self.setStatus("网页未提供可滚动的正文，请返回网页检查阅读布局。") }
            }
        })
    }
    @objc func previousChapter() { changeChapter("previous") }
    @objc func nextChapter() { changeChapter("next") }
    func nativeClickSource(x: Double, y: Double) -> Bool {
        guard let sourceWindow = web.window else { return false }
        let point = NSPoint(x: x, y: web.isFlipped ? y : Double(web.bounds.height) - y)
        guard web.bounds.contains(point), let target = web.hitTest(point) else { return false }
        let location = web.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            if type == .leftMouseDown { target.mouseDown(with: event) }
            else { target.mouseUp(with: event) }
        }
        return true
    }
    @objc func copyDiagnostics() {
        let script = """
        (() => ({
          path: location.pathname,
          chapterTool: typeof window.floatingReaderChangeChapter,
          captureState: window.floatingReaderCaptureState?.(),
          chapterProgress: window.floatingReaderChapterProgress || null,
          candidates: Array.from(document.querySelectorAll('button, a, [role="button"], [class*="readerFooter"], [class*="chapterFooter"]'))
            .map(n => ({label:(n.getAttribute('aria-label') || n.getAttribute('title') || n.textContent || '').trim(), cls:n.className}))
            .filter(n => n.label.length < 80 && /章|目录/.test(n.label)).slice(0,20)
        }))()
        """
        web.evaluateJavaScript(script, completionHandler: { [weak self] value, error in
            guard let self = self else { return }
            var info = "浮读 0.26.14\n文字视图：\(self.pure)\n正文高度：\(self.text.frame.height)\n可视高度：\(self.scroll.contentSize.height)\n滚动位置：\(self.scroll.contentView.bounds.origin.y)\n状态：\(self.status.stringValue)\n预读阶段：\(self.nextLoader?.phase ?? -1)\n预读缓存字数：\(self.nextChapterCache?.count ?? 0)\n"
            if let value = value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]), let json = String(data: data, encoding: .utf8) { info += json }
            if let error = error { info += error.localizedDescription }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info, forType: .string)
            self.setStatus("诊断信息已复制，可粘贴反馈。")
        })
    }
    func changeChapter(_ direction: String, continuous: Bool = false, internalMove: Bool = false, allowPreloadWait: Bool = true, onMoved: (() -> Void)? = nil) {
        guard !finishingReadingSession else { return }
        if !internalMove && direction != "next" { pendingNextAdvance = nil; bottomAdvanceRequested = false }
        if !internalMove && direction == "next", pure, textHasWebSource, !changingChapter {
            if consumeReadyNextChapter(continuous: continuous) { return }
            if allowPreloadWait, nextChapterCache == nil, nextLoader?.completion == nil, let owner = web.url?.absoluteString {
                prefetchOwner = ""; preloadRetryAfter = .distantPast
                beginNextChapterPreload(owner: owner)
            }
            if allowPreloadWait, nextLoader?.completion != nil, prefetchOwner == web.url?.absoluteString {
                pendingNextAdvance = continuous
                setStatus("下一章正在后台准备，完成后自动接续")
                return
            }
        }
        if !internalMove && !changingChapter && (!preparingText || (direction == "next" && nextChapterCache != nil)) {
            nextLoader?.cancel(); nextLoader = nil; prefetchOwner = ""
        }
        // A ready next-chapter cache must not wait for current-chapter OCR to drain.
        if !internalMove && direction == "next" && nextChapterCache != nil && preparingText && !changingChapter {
            readGeneration += 1; preparingText = false; continuing = false
            appendRecognition = false; prefetchBudget = 0; pendingStyle = nil; chainedText = nil
        }
        if !internalMove && !preparingText && !changingChapter {
            if sourceAhead {
                if direction == "next" {
                    sourceAhead = false; backgroundNextLoading = false
                    if let cache = nextChapterCache {
                        nextChapterCache = nil; textWasRecognized = nextChapterOCR
                        prefetchBudget = 20; finishText(cache)
                    } else { prepareText() }
                    return
                }
                changeChapter("previous", internalMove: true, onMoved: {
                    self.sourceAhead = false; self.backgroundNextLoading = false; self.nextChapterCache = nil
                    self.changeChapter(direction, continuous: continuous)
                })
                return
            }
            if direction == "next", let cache = nextChapterCache {
                nextChapterCache = nil
                let old = text.string, position = scroll.contentView.bounds.origin.y
                textWasRecognized = nextChapterOCR; prefetchBudget = 0
                recognizedTop = nextRecognizedTop; recognizedBottom = nextRecognizedBottom
                let cachedCapture = nextCapture
                setText(continuous ? old + "\n\n" + cache : cache)
                recordReadingAnchor(cache, sourceY: nextRecognizedTop.map(Double.init) ?? 0, url: cachedChapterURL)
                scheduleReadingProgress()
                if continuous { scroll.contentView.scroll(to: NSPoint(x: 0, y: position)); scroll.reflectScrolledClipView(scroll.contentView) }
                changeChapter("next", internalMove: true, onMoved: {
                    let resume = {
                        self.prefetchBudget = 20; self.lastEdge = .distantPast
                        if self.textWasRecognized { self.continueReading(forward: true, prefetch: true) }
                        else { self.startNextChapterPreload() }
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: cachedCapture), let json = String(data: data, encoding: .utf8) {
                        self.web.evaluateJavaScript("window.floatingReaderRestoreCaptureState?.(\(json))", completionHandler: { _, _ in resume() })
                    } else { resume() }
                })
                return
            }
            nextChapterCache = nil
        }
        if pure && !textHasWebSource { alert("粘贴文字没有章节来源", "先返回微信读书并打开一本书，再切换章节。"); return }
        if changingChapter || preparingText { setStatus("正在读取正文，请稍候再切章。"); return }
        guard web.url?.path.contains("reader") == true else { alert("当前页面不是阅读章节", "请在书架打开一本书并进入正文后再切换章节。"); return }
        changingChapter = true
        let quietMove = internalMove || backgroundNextLoading || continuous
        automaticLoadingPaused = false
        readGeneration += 1
        let chapterGeneration = readGeneration
        appendRecognition = false
        continuing = false
        let returnToText = pure
        let oldText = text.string
        let oldPosition = scroll.contentView.bounds.origin.y
        chainedText = nil
        setStatus("正在加载章节…")
        let script = """
        (() => {
            if (!window.floatingReaderChangeChapter) throw new Error('章节工具尚未加载，请重新加载网页');
            window.floatingReaderChapterResult = 'loading';
            window.floatingReaderUseNativeClick = false;
            window.floatingReaderAllowNativeFallback = true;
            window.floatingReaderNativeClickRequest = null;
            const before = window.floatingReaderChapterSnapshot();
            window.floatingReaderChangeChapter('\(direction)').then(
                result => { window.floatingReaderChapterResult = result; },
                error => { window.floatingReaderChapterResult = String(error); }
            );
            return before;
        })()
        """
        web.evaluateJavaScript(script, completionHandler: { [weak self] before, error in
            guard let self = self else { return }
            guard self.readGeneration == chapterGeneration else { return }
            if error != nil {
                self.changingChapter = false
                self.backgroundNextLoading = false; self.preparingBackground = false
                self.automaticLoadingPaused = true
                if quietMove { self.setStatus("预读未完成，可手动切章重试。") }
                else { self.alert("章节切换失败", "未找到页面章节工具。请重新加载网页后再试。") }
                return
            }
            var baseline = (before as? [String: Any])?["signature"] as? String ?? ""
            let deadline = Date().addingTimeInterval(35)
            var lastSignature = ""
            var stableObservations = 0
            var polling = false
            var nativeClickSent = false
            let pollTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                guard self.changingChapter, self.readGeneration == chapterGeneration else { timer.invalidate(); return }
                if Date() >= deadline {
                    timer.invalidate()
                    self.changingChapter = false
                    self.backgroundNextLoading = false; self.preparingBackground = false
                    self.automaticLoadingPaused = true
                    self.setStatus("35 秒内未确认新正文，已暂停自动续读。可重新读取当前章节，或切换到原网页检查。")
                    return
                }
                guard !polling else { return }
                polling = true
                self.web.evaluateJavaScript("({result: window.floatingReaderChapterResult || '', snapshot: window.floatingReaderChapterSnapshot?.(), click: window.floatingReaderNativeClickRequest})", completionHandler: { [weak self] value, _ in
                    polling = false
                    guard let self = self, self.changingChapter, self.readGeneration == chapterGeneration else { return }
                    guard let state = value as? [String: Any] else { return }
                    if !nativeClickSent, let request = state["click"] as? [String: Any], let x = request["x"] as? Double, let y = request["y"] as? Double {
                        baseline = request["baseline"] as? String ?? baseline
                        nativeClickSent = true
                        if !self.nativeClickSource(x: x, y: y) {
                            self.web.evaluateJavaScript("window.floatingReaderNativeClickFallback?.(); window.floatingReaderNativeClickContinue?.();", completionHandler: nil)
                            return
                        }
                        self.web.evaluateJavaScript("if (window.floatingReaderChapterProgress) window.floatingReaderChapterProgress.nativeClickSent = true; window.floatingReaderNativeClickContinue?.();", completionHandler: nil)
                        return
                    }
                    let message = state["result"] as? String ?? ""
                    let snapshot = state["snapshot"] as? [String: Any] ?? [:]
                    let signature = snapshot["signature"] as? String ?? ""
                    let ready = snapshot["ready"] as? Bool ?? false
                    if ready && signature != baseline && signature == lastSignature { stableObservations += 1 }
                    else { stableObservations = 0 }
                    lastSignature = signature
                    let confirmedContent = ready && signature != baseline && stableObservations >= 4 && !self.web.isLoading
                    let terminalFailure = !message.isEmpty && message != "loading" && message != "changed" && !message.hasPrefix("已触发章节按钮")
                    guard message == "changed" || confirmedContent || terminalFailure else { return }
                    timer.invalidate()
                    self.changingChapter = false
                    if message == "changed" || confirmedContent {
                        if let onMoved = onMoved { onMoved(); return }
                        if returnToText {
                            if continuous {
                                self.chainedText = oldText
                                self.chainedForward = direction == "next"
                                self.chainedPosition = oldPosition
                            }
                            self.prepareText()
                        }
                    } else {
                        self.backgroundNextLoading = false; self.preparingBackground = false
                        self.automaticLoadingPaused = true
                        if quietMove { self.setStatus(message) }
                        else { self.alert("无法切换章节", message) }
                    }
                })
            }
            RunLoop.main.add(pollTimer, forMode: .common)
        })
    }
    @objc func retryCurrentChapter() {
        guard !preparingText && !changingChapter else { return }
        automaticLoadingPaused = false
        prepareText()
    }
    @objc func explicitOCR() {
        guard !preparingText else { return }
        pure = false; showMode(); pendingStyle = nil; preparingText = true; recognizeVisiblePage()
    }
    @objc func reloadWeb() { cancelPendingRead(); pure = false; showMode(); web.reload() }
    @objc func restoreWeb() { cancelPendingRead(); originalWeb = true; pure = false; showMode(); web.reload() }
    @objc func enableWebStyle() { originalWeb = false; applyWebAppearance() }
    @objc func openInBrowser() {
        if let url = web.url, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
    }
    // Window stacking must not rewrite text, restyle the source page or move its capture window.
    @objc func togglePin() { pinned.toggle(); applyPinState() }
    @objc func pin() { pinned = true; applyPinState() }
    @objc func unpin() { pinned = false; applyPinState() }
    func configureWindowStacking() {
        window.level = pinned ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.managed, .fullScreenNone]
        if #available(macOS 13.0, *), pinned { behavior.insert(.canJoinAllApplications) }
        window.collectionBehavior = behavior
    }
    func applyPinState() {
        configureWindowStacking()
        if pinned && window.isVisible && !window.isMiniaturized { window.orderFrontRegardless() }
        defaults.set(pinned, forKey: "pinned")
        pinButton.toolTip = pinned ? "取消置顶" : "置顶"
        pinButton.setAccessibilityLabel(pinButton.toolTip)
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }
    func setReadingTheme(_ isDark: Bool) {
        makeAdjustable {
            self.dark = isDark
            self.customInk = false; self.customBackground = false
            self.ink = self.dark ? NSColor(srgbRed: 0.88, green: 0.88, blue: 0.88, alpha: 1) : NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
            self.background = self.dark ? NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1) : NSColor(srgbRed: 251.0/255, green: 246.0/255, blue: 237.0/255, alpha: 1)
            self.applyAppearance()
        }
    }
    @objc func toggleTheme() { setReadingTheme(!dark) }
    @objc func darkTheme() { setReadingTheme(true) }
    @objc func lightTheme() { setReadingTheme(false) }
    @objc func toggleBar() { toggleBackground() }
    @objc func toggleBackground() {
        chromeVisible.toggle()
        applyVisibility()
        layoutText()
    }
    @objc func smaller() { makeAdjustable { self.size = max(12, self.size - 2); self.applyAppearance() } }
    @objc func larger() { makeAdjustable { self.size = min(64, self.size + 2); self.applyAppearance() } }
    @objc func color() { openColorPicker(backgroundRole: false) }
    @objc func backgroundColor() { openColorPicker(backgroundRole: true) }
    func openColorPicker(backgroundRole: Bool) {
        acceptingPickerChanges = false
        let panel = NSColorPanel.shared
        panel.setTarget(nil); panel.setAction(nil)
        editingBackground = backgroundRole
        if backgroundRole { backgroundPicker = panel } else { inkPicker = panel }
        panel.delegate = self
        panel.showsAlpha = false; panel.isContinuous = true
        // Keep the system picker stable while its selected color changes the reader appearance.
        panel.appearance = NSAppearance(named: .aqua)
        panel.color = backgroundRole ? background : ink
        panel.accessoryView = makePresetColors()
        panel.title = backgroundRole ? "正文背景颜色" : "正文文字颜色"
        if pickerObserver == nil {
            pickerObserver = NotificationCenter.default.addObserver(forName: NSColorPanel.colorDidChangeNotification, object: panel, queue: .main) { [weak self] note in
                guard let self = self, let sender = note.object as? NSColorPanel else { return }
                self.colorChanged(sender)
            }
        }
        panel.setTarget(self); panel.setAction(#selector(colorChanged(_:)))
        panel.isMovable = true; panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, window.level.rawValue + 1))
        panel.makeKeyAndOrderFront(nil)
        acceptingPickerChanges = true
    }
    func makePresetColors() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        let label = NSTextField(labelWithString: "常用色")
        label.font = .systemFont(ofSize: 11); label.frame = NSRect(x: 10, y: 33, width: 100, height: 16)
        view.addSubview(label)
        for (index, hex) in presetHexes.enumerated() {
            let button = NSButton(frame: NSRect(x: 10 + index * 33, y: 5, width: 26, height: 24))
            button.isBordered = false; button.tag = index; button.target = self
            button.action = #selector(selectPresetColor(_:)); button.toolTip = "#" + hex
            button.setAccessibilityLabel("常用颜色 #" + hex)
            let color = presetColor(index)
            button.image = NSImage(size: NSSize(width: 22, height: 20), flipped: false) { rect in
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
                color.setFill(); path.fill(); NSColor(white: 0.5, alpha: 0.5).setStroke(); path.stroke()
                return true
            }
            view.addSubview(button)
        }
        return view
    }
    func presetColor(_ index: Int) -> NSColor {
        let rgb = UInt32(presetHexes[index], radix: 16)!
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1)
    }
    @objc func selectPresetColor(_ sender: NSButton) {
        guard acceptingPickerChanges, presetHexes.indices.contains(sender.tag) else { return }
        let color = presetColor(sender.tag)
        NSColorPanel.shared.color = color
        commitColor(color, backgroundRole: editingBackground)
    }
    @objc func fontPicker() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size), isMultiple: false)
        manager.orderFrontFontPanel(self)
    }
    func changeFont(_ sender: NSFontManager?) {
        let manager = sender ?? NSFontManager.shared
        let chosen = manager.convert(NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size))
        makeAdjustable { self.fontName = chosen.fontName; self.size = min(64, max(12, chosen.pointSize)); self.applyAppearance() }
    }
    @objc func colorChanged(_ sender: NSColorPanel) {
        guard acceptingPickerChanges, sender === NSColorPanel.shared, sender.isVisible else { return }
        commitColor(sender.color, backgroundRole: editingBackground)
    }
    func finishColorPicker() {
        acceptingPickerChanges = false
        NSColorPanel.shared.setTarget(nil); NSColorPanel.shared.setAction(nil)
        // Closing the picker is not a cancel/reset operation. Keep the committed model.
        applyAppearance()
    }
    func commitColor(_ color: NSColor, backgroundRole: Bool) {
        guard !updatingAppearance else { return }
        let selected = (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(1)
        let isBackground = backgroundRole
        makeAdjustable {
            if isBackground { self.background = selected; self.customBackground = true }
            else { self.ink = selected; self.customInk = true }
            self.applyAppearance()
        }
    }
    @objc func resetReadingStyle() { fontName = ""; size = 14; lineHeightMultiple = 1.4; dark = false; customInk = false; customBackground = false; ink = dark ? NSColor(srgbRed: 0.88, green: 0.88, blue: 0.88, alpha: 1) : NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1); background = dark ? NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1) : NSColor(srgbRed: 251.0/255, green: 246.0/255, blue: 237.0/255, alpha: 1); applyAppearance() }
    @objc func resetAppearance() { chromeVisible = true; applyVisibility(); layoutText() }
    @objc func recoverReader() {
        cancelPendingRead()
        (renderingWindow as? RenderingWindow)?.securePosition()
        if sourceIsOffscreen { renderingWindow?.orderBack(nil) } else { renderingWindow?.orderOut(nil) }
        chromeVisible = true
        showMode()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func mountSource(offscreen: Bool) {
        if sourceIsOffscreen == offscreen && web.superview != nil {
            if offscreen { web.autoresizingMask = []; web.frame = ReadingViewport.rect }
            return
        }
        web.removeFromSuperview()
        web.alphaValue = 1
        web.isHidden = false
        if offscreen {
            if renderingWindow == nil {
                let x = (NSScreen.screens.map { $0.frame.minX }.min() ?? 0) - 10000
                let y = (NSScreen.screens.map { $0.frame.minY }.min() ?? 0) - 10000
                renderingWindow = RenderingWindow(contentRect: NSRect(origin:NSPoint(x:x,y:y),size:ReadingViewport.size), styleMask: [.borderless], backing: .buffered, defer: false)
                renderingWindow?.isReleasedWhenClosed = false
                renderingWindow?.isExcludedFromWindowsMenu = true
                renderingWindow?.backgroundColor = .white
                renderingWindow?.ignoresMouseEvents = true
                renderingWindow?.isRestorable = false
                renderingWindow?.isMovable = false
                renderingWindow?.animationBehavior = .none
                renderingWindow?.collectionBehavior = [.transient, .ignoresCycle]
                renderingWindow?.delegate = self
            }
            renderingWindow?.contentView?.addSubview(web)
            web.autoresizingMask = []; web.frame = ReadingViewport.rect
            (renderingWindow as? RenderingWindow)?.securePosition()
            renderingWindow?.orderBack(nil)
        } else {
            web.autoresizingMask = [.width, .height]
            browserHost.addSubview(web)
            web.frame = browserHost.bounds
            renderingWindow?.orderOut(nil)
        }
        sourceIsOffscreen = offscreen
        applyWebAppearance()
    }
    func showMode() {
        scroll.isHidden = !pure
        browserHost.isHidden = pure
        mountSource(offscreen: pure)
        applyAppearance()
    }
    func applyAppearance() {
        guard !updatingAppearance else { return }
        updatingAppearance = true
        defer { updatingAppearance = false }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Freeze selected colors before changing the native control appearance.
        ink = ink.usingColorSpace(.sRGB) ?? ink
        background = background.usingColorSpace(.sRGB) ?? background
        if let color = background.usingColorSpace(.sRGB) {
            let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            window.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
        }
        text.dragEnabled = true
        defaults.set(fontName, forKey: "fontName")
        defaults.set(Double(lineHeightMultiple), forKey: "lineHeight")
        configureWindowStacking()
        (renderingWindow as? RenderingWindow)?.securePosition()
        pinButton.toolTip = pinned ? "取消置顶" : "置顶"
        pinButton.setAccessibilityLabel(pinned ? "取消置顶" : "置顶")
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        themeButton.toolTip = dark ? "浅色正文" : "深色正文"
        themeButton.setAccessibilityLabel(dark ? "浅色正文" : "深色正文")
        themeButton.image = iconImage(dark ? "sun" : "moon")
        defaults.set(pinned, forKey: "pinned")
        defaults.set(dark, forKey: "dark")
        defaults.set(customInk, forKey: "customInk")
        defaults.set(customBackground, forKey: "customBackground")
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: ink, requiringSecureCoding: true) { defaults.set(data, forKey: "inkColor") }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: background, requiringSecureCoding: true) { defaults.set(data, forKey: "backgroundColor") }
        if let c = background.usingColorSpace(.sRGB) {
            defaults.set(String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)), forKey: "background")
        }
        defaults.set(Double(size), forKey: "fontSize")
        defaults.set(transparent, forKey: "transparent")
        defaults.set(Double(backgroundOpacity), forKey: "backgroundOpacity")
        defaults.set(Double(lastVisibleOpacity), forKey: "lastVisibleOpacity")
        if let c = ink.usingColorSpace(.sRGB) {
            defaults.set(String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)), forKey: "ink")
        }
        applyVisibility()
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        for (button, label) in [(previousLink, "←"), (nextLink, "→")] {
            button.font = font
            button.attributedTitle = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink])
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        let selection = text.selectedRange()
        let value = text.string
        text.usesAdaptiveColorMappingForDarkAppearance = false
        text.textColor = ink
        text.typingAttributes = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
        text.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]))
        let selectionStart = min(selection.location, (value as NSString).length)
        text.setSelectedRange(NSRange(location: selectionStart, length: min(selection.length, (value as NSString).length - selectionStart)))
        sizeAdjustmentSlider?.doubleValue = Double(size)
        spacingAdjustmentSlider?.doubleValue = Double(lineHeightMultiple)
        fontSizeLabel.stringValue = String(format: "%.0f pt", Double(size))
        lineHeightLabel.stringValue = String(format: "%.2f 倍", Double(lineHeightMultiple))
        for panel in [sizeAdjustmentPanel, spacingAdjustmentPanel].compactMap({ $0 }) {
            panel.appearance = window.appearance
            panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, window.level.rawValue + 1))
        }
        text.insertionPointColor = ink
        text.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
        for panel in [inkPicker, backgroundPicker].compactMap({ $0 }) where panel.isVisible {
            panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, window.level.rawValue + 1))
            // Never rewrite the shared picker's color while its continuous action is running.
            // AppKit can send a second change notification and leak the previous target's color.
            // The native picker keeps its own appearance while editing.
        }
        layoutText()
        text.needsDisplay = true
        applyWebAppearance()
    }
    // Visibility changes have no access to palette normalization or color panels.
    func applyVisibility() {
        hiddenBar = !chromeVisible
        transparent = !chromeVisible
        backgroundOpacity = chromeVisible ? 1 : 0
        toolbarScroll.isHidden = hiddenBar
        shortcutsButton.isHidden = hiddenBar
        status.isHidden = hiddenBar
        contentTop?.constant = hiddenBar ? 0 : 48
        contentBottom?.constant = hiddenBar ? 0 : -48
        styleToolbar.isHidden = hiddenBar
        chapterFooter.isHidden = !pure || !textHasWebSource
        previousLink.contentTintColor = ink
        nextLink.contentTintColor = ink
        modeButton.title = pure ? "原网页" : "纯文字"
        modeButton.image = nil
        modeButton.toolTip = (pure ? "当前为纯文字，点击切换到原网页" : "当前为原网页，点击生成纯文字") + shortcutHint(#selector(togglePure))
        modeButton.setAccessibilityLabel(modeButton.toolTip)
        let zeroBackground = transparent || backgroundOpacity <= 0
        backgroundButton.image = iconImage(zeroBackground ? "background-visible" : "background-hidden")
        backgroundButton.toolTip = zeroBackground ? "恢复工具栏与正文背景" : "隐藏工具栏与正文背景"
        backgroundButton.setAccessibilityLabel(backgroundButton.toolTip)
        backgroundButton.contentTintColor = zeroBackground ? .controlAccentColor : .secondaryLabelColor
        let desiredMask: NSWindow.StyleMask = hiddenBar ? [.borderless, .resizable, .nonactivatingPanel] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        if window.styleMask != desiredMask {
            let frame = window.frame
            window.styleMask = desiredMask
            window.setFrame(frame, display: true)
        }
        window.titleVisibility = hiddenBar ? .hidden : .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        root.layoutSubtreeIfNeeded()
        let titleHeight: CGFloat = hiddenBar ? 0 : max(0, window.frame.height - window.contentLayoutRect.height)
        titleBackdropHeight?.constant = titleHeight
        titleBackdrop.isHidden = hiddenBar
        toolbarTop?.constant = titleHeight
        contentTop?.constant = hiddenBar ? 0 : 48 + titleHeight
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = hiddenBar }
        let opacity = transparent ? 0 : backgroundOpacity
        window.isOpaque = false
        window.backgroundColor = .clear
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.fillColor = background.withAlphaComponent(opacity)
        // NSClipView otherwise supplies its own opaque background over the scroll view.
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.contentView.backgroundColor = .clear
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor.clear.cgColor
        text.drawsBackground = false
        text.backgroundColor = .clear
        browserHost.wantsLayer = true
        browserHost.layer?.backgroundColor = NSColor.clear.cgColor
        status.wantsLayer = true
        status.layer?.backgroundColor = NSColor.clear.cgColor
        status.textColor = ink
        readerBorder.wantsLayer = true
        readerBorder.layer?.borderWidth = 4
        readerBorder.layer?.borderColor = background.withAlphaComponent(1).cgColor
        readerBorder.color = background.withAlphaComponent(1)
        readerBorder.isHidden = hiddenBar
        readerBorder.needsDisplay = true
        toolbarScroll.drawsBackground = false
        toolbarScroll.backgroundColor = .clear
        shortcutsButton.wantsLayer = true
        shortcutsButton.layer?.backgroundColor = NSColor.clear.cgColor
        styleToolbar.drawsBackground = false
        styleToolbar.backgroundColor = .clear
        styleToolbar.wantsLayer = true
        styleToolbar.layer?.backgroundColor = NSColor.clear.cgColor
        toolbarScroll.wantsLayer = true
        toolbarScroll.layer?.backgroundColor = NSColor.clear.cgColor
        titleBackdrop.wantsLayer = true
        titleBackdrop.layer?.backgroundColor = NSColor.clear.cgColor
        for tool in [toolbarScroll, shortcutsButton, styleToolbar, titleBackdrop, status] as [NSView] { tool.alphaValue = opacity }
        readerBorder.alphaValue = opacity
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.alphaValue = opacity }
        window.hasShadow = opacity > 0
    }
    func applyWebAppearance() {
        guard let c = ink.usingColorSpace(.sRGB) else { return }
        let color = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        let bg = background.usingColorSpace(.sRGB) ?? background
        let backgroundHex = String(format: "#%02X%02X%02X", Int(bg.redComponent * 255), Int(bg.greenComponent * 255), Int(bg.blueComponent * 255))
        let options: [String: Any] = ["background": backgroundHex, "transparent": transparent, "dark": dark, "color": color, "size": Double(size), "original": originalWeb || sourceIsOffscreen, "hidden": hiddenBar, "opacity": Double(transparent ? 0 : backgroundOpacity)]
        guard let data = try? JSONSerialization.data(withJSONObject: options), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.floatingReaderApply?.(\(json))", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyWebAppearance()
        if let resume = cachedSourceResume { cachedSourceResume = nil; resume(); return }
        if finishingReadingSession, terminatingBookmark != nil {
            restoreClosingReading()
        } else if restoringReading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restorePendingReading() }
        } else if let url = web.url { autoReadBook(url) }
    }
    func autoReadBook(_ url: URL, attempt: Int = 0) {
        guard web.url == url, url.path.hasPrefix("/web/reader/"), !pure, !preparingText, !changingChapter, !backgroundNextLoading, !restoringReading, !finishingReadingSession, !originalWeb, url.absoluteString != rawOnlyURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.web.url == url, !self.pure, !self.preparingText, !self.changingChapter, !self.restoringReading, self.rawOnlyURL != url.absoluteString else { return }
            self.web.evaluateJavaScript("window.floatingReaderChapterSnapshot?.().ready === true") { ready, _ in
                guard self.web.url == url, !self.pure, !self.preparingText, !self.changingChapter, self.rawOnlyURL != url.absoluteString else { return }
                if ready as? Bool == true { self.prepareText() }
                else if attempt < 40 { self.autoReadBook(url, attempt: attempt + 1) }
            }
        }
    }
    @objc func pasteText() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { alert("剪贴板没有文字", "复制一段文字后，再使用粘贴。"); return }
        cancelPendingRead()
        setText(value, webSource: false)
    }
    func setText(_ value: String, webSource: Bool = true) {
        let old = text.string
        if !value.hasPrefix(old) {
            if !old.isEmpty && value.hasSuffix(old) {
                let shift = (value as NSString).length - (old as NSString).length
                readingAnchors = readingAnchors.map { ReadingAnchor(offset: $0.offset + shift, sourceY: $0.sourceY, url: $0.url) }
            } else { readingAnchors.removeAll() }
        }
        if !webSource { readingAnchors.removeAll() }
        textHasWebSource = webSource; text.string = value; pure = true; showMode(); text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    @objc func togglePure() {
        if pure { rawOnlyURL = web.url?.absoluteString ?? ""; cancelPendingRead(); pure = false; showMode(); return }
        rawOnlyURL = ""
        prepareText()
    }
    func makeAdjustable(_ action: @escaping () -> Void) {
        action()
        // Appearance changes must never restart capture or switch reading modes.
    }
    func finishText(_ value: String) {
        preparingText = false
        if preparingBackground {
            nextChapterCache = value; nextChapterOCR = textWasRecognized; cachedChapterURL = web.url?.absoluteString ?? ""
            textWasRecognized = preloadCurrentOCR
            nextRecognizedTop = recognizedTop; nextRecognizedBottom = recognizedBottom
            recognizedTop = savedRecognizedTop; recognizedBottom = savedRecognizedBottom
            preparingBackground = false; prefetchBudget = 0
            web.evaluateJavaScript("window.floatingReaderCaptureState?.()", completionHandler: { [weak self] value, _ in
                guard let self = self else { return }
                self.nextCapture = value as? [String: Any] ?? [:]
                self.changeChapter("previous", internalMove: true, onMoved: {
                self.sourceAhead = false; self.backgroundNextLoading = false
                if let data = try? JSONSerialization.data(withJSONObject: self.savedCapture), let json = String(data:data,encoding:.utf8) {
                    self.web.evaluateJavaScript("window.floatingReaderRestoreCaptureState?.(\(json))", completionHandler:nil)
                }
                self.setStatus("下一章已预读 · 切章时优先显示缓存")
                self.scheduleReadingProgress()
                })
            })
            return
        }
        if let previous = chainedText {
            let oldHeight = text.frame.height
            let joined = chainedForward ? previous + "\n\n" + value : value + "\n\n" + previous
            chainedText = nil
            setText(joined)
            let position = chainedForward ? chainedPosition : chainedPosition + max(0, text.frame.height - oldHeight)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if appendRecognition {
            let oldHeight = text.frame.height
            let currentPosition = scroll.contentView.bounds.origin.y
            let merged = appendForward ? mergeContinuation(appendOriginal, value) : mergeContinuation(value, appendOriginal)
            let changed = merged != appendOriginal
            appendRecognition = false
            continuing = false
            if !appendForward {
                let shift = (merged as NSString).length - (text.string as NSString).length
                readingAnchors = readingAnchors.map { ReadingAnchor(offset: $0.offset + shift, sourceY: $0.sourceY, url: $0.url) }
            }
            text.string = merged
            showMode()
            let position = appendForward ? currentPosition : currentPosition + max(0, text.frame.height - oldHeight)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
            scroll.reflectScrolledClipView(scroll.contentView)
            if !changed { setStatus("此页没有识别到新增正文，请返回网页检查。"); return }
        } else {
            setText(value)
        }
        recordReadingAnchor(value, sourceY: recognizedTop.map(Double.init) ?? 0, url: web.url?.absoluteString ?? "")
        scheduleReadingProgress()
        let action = pendingStyle
        pendingStyle = nil
        action?()
        if !textWasRecognized { sourceAtEnd = true }
        if !isAtReadingBottom { bottomAdvanceRequested = false }
        let count = text.string.filter { !$0.isWhitespace }.count
        setStatus(textWasRecognized ? "已读取 \(count) 字 · 滚动可接续 · 识别可能有错字" : "已读取 \(count) 字 · 字体、字号、颜色与背景均可调整")
        if !backgroundNextLoading { startNextChapterPreload() }
        resumeBottomAdvanceIfNeeded()
        if textWasRecognized && prefetchBudget > 0 {
            prefetchBudget -= 1
            let generation = readGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard self.readGeneration == generation else { return }
                self.lastEdge = .distantPast
                self.continueReading(forward: true, prefetch: true)
            }
        }
    }
    var isAtReadingBottom: Bool {
        scroll.contentView.bounds.maxY >= text.frame.height - 3
    }
    func resumeBottomAdvanceIfNeeded() {
        guard bottomAdvanceRequested, pure, !catalogIsOpen, sourceAtEnd, isAtReadingBottom,
              !preparingText, !changingChapter, !continuing else { return }
        bottomAdvanceRequested = false; lastEdge = .distantPast
        changeChapter("next", continuous: true)
    }
    func applicationDidBecomeActive(_ notification: Notification) { maintainNextPreload() }
    func maintainNextPreload() {
        guard !finishingReadingSession, pure, textHasWebSource, !catalogIsOpen, !restoringReading,
              !changingChapter, let owner = web.url?.absoluteString, validReadingURL(owner) else { return }
        if nextChapterCache == nil, nextLoader?.completion == nil, Date() >= preloadRetryAfter {
            prefetchOwner = ""; beginNextChapterPreload(owner: owner)
        }
        resumeBottomAdvanceIfNeeded()
    }
    @discardableResult func consumeReadyNextChapter(continuous: Bool) -> Bool {
        guard !catalogIsOpen, let value = nextChapterCache, !value.isEmpty, let loader = nextLoader,
              prefetchOwner == web.url?.absoluteString, loader.owner == prefetchOwner,
              validReadingURL(cachedChapterURL) else { return false }
        let url = cachedChapterURL, capture = nextCapture
        let wasRecognized = nextChapterOCR, top = nextRecognizedTop, bottom = nextRecognizedBottom
        let readyView: WKWebView?
        if loader.sourceUsable && loader.view.url?.absoluteString == url { readyView = loader.detachPage() }
        else { loader.cancel(); readyView = nil }
        let old = text.string, position = scroll.contentView.bounds.origin.y
        readGeneration += 1
        preparingText = false; changingChapter = false; continuing = false; appendRecognition = false
        pendingStyle = nil; chainedText = nil; prefetchBudget = 0; pendingNextAdvance = nil
        bottomAdvanceRequested = false; sourceAhead = false; backgroundNextLoading = false; preparingBackground = false
        automaticLoadingPaused = false; progressWork?.cancel()
        nextChapterCache = nil; nextLoader = nil; prefetchOwner = ""
        preloadFailures = 0; preloadRetryAfter = .distantPast
        if let view = readyView {
            readerURLObservation = nil
            web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil; web.removeFromSuperview()
            web = view; web.navigationDelegate = self; web.uiDelegate = self
            web.allowsBackForwardNavigationGestures = true
            web.setValue(false, forKey: "drawsBackground"); web.underPageBackgroundColor = .clear
            readerURLObservation = web.observe(\.url, options: [.new]) { [weak self] view, _ in
                if let url = view.url { self?.autoReadBook(url) }
            }
        }
        textWasRecognized = wasRecognized; recognizedTop = top; recognizedBottom = bottom
        let offset = (capture["current"] as? Double) ?? 0
        let maximum = (capture["maximum"] as? Double) ?? Double.greatestFiniteMagnitude
        sourceAtEnd = !wasRecognized || offset >= maximum - 2
        if !continuous { readingAnchors.removeAll() }
        setText(continuous ? old + "\n\n" + value : value)
        recordReadingAnchor(value, sourceY: top.map(Double.init) ?? 0, url: url)
        if continuous {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: position)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        setStatus("已接续缓存正文 · 正在准备后续章节")
        let adoptedGeneration = readGeneration
        let resume: () -> Void = { [weak self] in
            guard let self = self, self.readGeneration == adoptedGeneration, self.web.url?.absoluteString == url, !self.finishingReadingSession else { return }
            self.beginNextChapterPreload(owner: url)
            let continueFill = {
                guard self.readGeneration == adoptedGeneration, self.web.url?.absoluteString == url else { return }
                self.scheduleReadingProgress()
                if self.textWasRecognized && !self.sourceAtEnd {
                    self.prefetchBudget = 20; self.lastEdge = .distantPast
                    self.continueReading(forward: true, prefetch: true)
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: capture), let json = String(data: data, encoding: .utf8) {
                self.web.evaluateJavaScript("window.floatingReaderRestoreCaptureState?.(\(json))", completionHandler: { _, _ in continueFill() })
            } else { continueFill() }
        }
        if readyView != nil { resume() }
        else {
            cachedSourceResume = resume
            web.load(URLRequest(url: URL(string: url)!))
            beginNextChapterPreload(owner: url)
        }
        return true
    }
    func startNextChapterPreload() {
        guard !finishingReadingSession, pure, textHasWebSource, !catalogIsOpen,
              let owner = web.url?.absoluteString else { return }
        beginNextChapterPreload(owner: owner)
    }
    func beginNextChapterPreload(owner: String) {
        guard !finishingReadingSession, !catalogIsOpen, nextChapterCache == nil,
              validReadingURL(owner), prefetchOwner != owner else { return }
        if preloadFailureOwner != owner {
            preloadFailureOwner = owner; preloadFailures = 0; preloadRetryAfter = .distantPast
        }
        guard Date() >= preloadRetryAfter else { return }
        nextLoader?.cancel(); prefetchOwner = owner
        nextLoader = NextChapterLoader(owner: owner) { [weak self] page in
            guard let self = self, self.prefetchOwner == owner, self.web.url?.absoluteString == owner else { return }
            guard let page = page else {
                self.preloadFailures += 1
                self.preloadRetryAfter = Date().addingTimeInterval(min(300, 15 * pow(2, Double(min(4, self.preloadFailures-1)))))
                self.prefetchOwner = ""
                self.setStatus("下一章预读暂未完成，保留正文并稍后自动重试")
                if let pending = self.pendingNextAdvance {
                    self.pendingNextAdvance = nil; self.nextLoader = nil
                    self.readGeneration += 1; self.preparingText = false; self.continuing = false; self.appendRecognition = false
                    self.changeChapter("next", continuous: pending, allowPreloadWait: false)
                }
                return
            }
            self.preloadFailures = 0; self.preloadRetryAfter = .distantPast
            self.nextChapterCache = page.text; self.nextChapterOCR = page.recognized; self.cachedChapterURL = page.url
            self.nextCapture = page.capture; self.nextRecognizedTop = page.top; self.nextRecognizedBottom = page.bottom
            self.setStatus("下一章已预读 \(page.text.count) 字 · 后台按大页面读取")
            if let pending = self.pendingNextAdvance {
                self.pendingNextAdvance = nil
                _ = self.consumeReadyNextChapter(continuous: pending)
            } else { self.resumeBottomAdvanceIfNeeded() }
        }
    }
    func makeAdjustmentPanel(title: String, key: String, label: NSTextField, slider: NSSlider) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 96), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title; panel.identifier = NSUserInterfaceItemIdentifier(key)
        panel.isReleasedWhenClosed = false; panel.isMovable = true; panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false; panel.delegate = self
        label.frame = NSRect(x: 20, y: 52, width: 260, height: 22)
        slider.frame = NSRect(x: 20, y: 18, width: 260, height: 26)
        slider.isContinuous = true
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(slider)
        if let saved = defaults.string(forKey: key) {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else {
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            var x = window.frame.maxX + 12
            if x + panel.frame.width > visible.maxX { x = window.frame.minX - panel.frame.width - 12 }
            panel.setFrameOrigin(NSPoint(x: min(max(visible.minX, x), visible.maxX - panel.frame.width), y: max(visible.minY, window.frame.maxY - panel.frame.height)))
        }
        return panel
    }
    func showAdjustmentPanel(_ panel: NSPanel) {
        panel.appearance = window.appearance
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, window.level.rawValue + 1))
        panel.makeKeyAndOrderFront(nil)
    }
    @objc func fontSizePanel() {
        if sizeAdjustmentPanel == nil {
            let slider = NSSlider(value: Double(size), minValue: 12, maxValue: 64, target: self, action: #selector(fontSizeChanged(_:)))
            sizeAdjustmentSlider = slider
            sizeAdjustmentPanel = makeAdjustmentPanel(title: "文字大小", key: "fontSizePanelPosition", label: fontSizeLabel, slider: slider)
        }
        sizeAdjustmentSlider?.doubleValue = Double(size)
        fontSizeLabel.stringValue = String(format: "%.0f pt", Double(size))
        if let panel = sizeAdjustmentPanel { showAdjustmentPanel(panel) }
    }
    @objc func fontSizeChanged(_ sender: NSSlider) {
        size = CGFloat(sender.doubleValue.rounded())
        fontSizeLabel.stringValue = String(format: "%.0f pt", Double(size))
        applyAppearance()
    }
    @objc func lineHeightPanel() {
        if spacingAdjustmentPanel == nil {
            let slider = NSSlider(value: Double(lineHeightMultiple), minValue: 1, maxValue: 2.5, target: self, action: #selector(lineHeightChanged(_:)))
            spacingAdjustmentSlider = slider
            spacingAdjustmentPanel = makeAdjustmentPanel(title: "正文行间距", key: "lineSpacingPanelPosition", label: lineHeightLabel, slider: slider)
        }
        spacingAdjustmentSlider?.doubleValue = Double(lineHeightMultiple)
        lineHeightLabel.stringValue = String(format: "%.2f 倍", Double(lineHeightMultiple))
        if let panel = spacingAdjustmentPanel { showAdjustmentPanel(panel) }
    }
    @objc func lineHeightChanged(_ sender:NSSlider) {
        lineHeightMultiple = CGFloat(sender.doubleValue)
        lineHeightLabel.stringValue = String(format:"%.2f 倍", Double(lineHeightMultiple))
        applyAppearance()
    }
    @objc func openChapters() {
        guard window.attachedSheet == nil else { return }
        guard !preparingText && !changingChapter else { setStatus("正在读取，请稍候打开目录。"); return }
        pendingNextAdvance = nil; bottomAdvanceRequested = false
        catalogIsOpen = true
        web.evaluateJavaScript("window.floatingReaderCatalogRows?.()", completionHandler:{ [weak self] rows,_ in
            guard let self = self else { return }
            if let rows = rows as? [[String:Any]], !rows.isEmpty { self.showChapterPicker(rows); return }
            self.web.evaluateJavaScript("window.floatingReaderCatalogButton?.()", completionHandler:{value,_ in
                guard let rect=value as? [String:Double], let x=rect["x"], let y=rect["y"], self.nativeClickSource(x:x,y:y) else { self.catalogIsOpen=false; self.alert("无法打开目录","请切换到原网页，打开目录后再点击章节选择。"); return }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5){
                    self.web.evaluateJavaScript("window.floatingReaderCatalogRows?.()",completionHandler:{value,_ in
                        guard let rows=value as? [[String:Any]], !rows.isEmpty else { self.catalogIsOpen=false; self.alert("目录尚未读取到","请在网页中确认目录已展开。网页目录结构可能需要适配。"); return }
                        self.showChapterPicker(rows)
                    })
                }
            })
        })
    }
    func showChapterPicker(_ rows:[[String:Any]]) {
        let alert=NSAlert();alert.messageText="选择阅读章节"
        let combo=NSComboBox(frame:NSRect(x:0,y:0,width:380,height:28))
        combo.addItems(withObjectValues:rows.map{$0["label"] as? String ?? "章节"}); combo.completes=true; combo.selectItem(at:rows.firstIndex(where:{$0["current"] as? Bool == true}) ?? 0)
        alert.accessoryView=combo;alert.addButton(withTitle:"打开章节");alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:window){response in
            self.catalogIsOpen=false
            guard response == .alertFirstButtonReturn else{self.closeSourceCatalog();return}
            let selected=combo.indexOfSelectedItem
            let index=selected>=0 && selected<rows.count && rows[selected]["label"] as? String == combo.stringValue ? selected : rows.firstIndex(where:{$0["label"] as? String == combo.stringValue}) ?? -1
            guard index>=0,index<rows.count,let target=rows[index]["index"] as? Int else{self.closeSourceCatalog();self.alert("请选择目录中的章节","可输入章节名查找，再从列表中选中。不会跳转到未选中的章节。");return}
            self.nextLoader?.cancel();self.nextLoader=nil;self.prefetchOwner=""
            self.nextChapterCache=nil;self.sourceAhead=false;self.backgroundNextLoading=false;self.preparingBackground=false
            if rows[index]["current"] as? Bool == true {
                self.closeSourceCatalog()
                self.web.evaluateJavaScript("window.floatingReaderStartChapter?.()",completionHandler:nil)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.25){self.prepareText()}
                return
            }
            self.changeChapter("catalog:\(target)",internalMove:true)
        }
    }
    func closeSourceCatalog() {
        web.evaluateJavaScript("window.floatingReaderCatalogCloseButton?.()",completionHandler:{ [weak self] value,_ in
            guard let self=self,let rect=value as? [String:Double],let x=rect["x"],let y=rect["y"] else{return}
            _=self.nativeClickSource(x:x,y:y)
        })
    }
    func mergeContinuation(_ original: String, _ incoming: String) -> String {
        if original.contains(incoming) { return original }
        let a = Array(original.filter { !$0.isWhitespace })
        let b = Array(incoming.filter { !$0.isWhitespace })
        if b.isEmpty { return original }
        if String(a).contains(String(b)) { return original }
        // Linear prefix matching removes overlaps of any length, including several pages.
        var prefix = [Int](repeating: 0, count: b.count)
        if b.count > 1 {
            for i in 1..<b.count {
                var j = prefix[i - 1]
                while j > 0 && b[i] != b[j] { j = prefix[j - 1] }
                if b[i] == b[j] { j += 1 }
                prefix[i] = j
            }
        }
        var overlap = 0
        for char in a {
            if overlap == b.count { overlap = prefix[overlap - 1] }
            while overlap > 0 && char != b[overlap] { overlap = prefix[overlap - 1] }
            if char == b[overlap] { overlap += 1 }
        }
        if overlap < 12 { overlap = 0 }
        // Validate large OCR overlaps using anchors and the entire shared passage.
        if a.count >= 64 && b.count >= 64 {
            let anchor = Array(a.suffix(32))
            for end in stride(from: min(a.count, b.count), through: max(64, overlap + 1), by: -1) {
                guard Array(b[(end - 32)..<end]) == anchor else { continue }
                let left = a.suffix(end), right = b.prefix(end)
                let matches = zip(left, right).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
                if Double(matches) / Double(end) >= 0.90 { overlap = end; break }
            }
        }
        var boundary = incoming.startIndex
        var consumed = 0
        while boundary < incoming.endIndex && consumed < overlap {
            if !incoming[boundary].isWhitespace { consumed += 1 }
            boundary = incoming.index(after: boundary)
        }
        let tail = incoming[boundary...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? original : original + "\n\n" + tail
    }
    func prepareText() {
        guard !finishingReadingSession else { return }
        guard !preparingText else { return }
        guard web.url?.host == "weread.qq.com", web.url?.path.contains("reader") == true else {
            alert("请先打开一本书", "打开章节后可生成文字视图，也可以粘贴文字。"); return
        }
        if let first = readingAnchors.first, let url = web.url?.absoluteString, bookEntryURL(first.url) != bookEntryURL(url) { readingAnchors.removeAll() }
        preparingText = true; sourceAtEnd = false
        recognizedTop = nil; recognizedBottom = nil
        readGeneration += 1
        let generation = readGeneration
        setStatus("正在读取正文…")
        recognitionRetries = 0
        prefetchBudget = preparingBackground ? 0 : 20
        mountSource(offscreen: true)
        if !preparingBackground, let owner = web.url?.absoluteString { beginNextChapterPreload(owner: owner) }
        web.evaluateJavaScript("window.floatingReaderBeginCapture?.()", completionHandler: nil)
        let script = """
        (() => {
          
          for (const selector of ['.readerChapterContent', '.readerContent .chapterContent', '.wr_readerChapterContent']) {
            const node = document.querySelector(selector);
            if (!node) continue;
            // A canvas reader can retain hidden/accessibility strings whose code points
            // do not match the visible glyphs. Never prefer those over rendered content.
            if (Array.from(node.querySelectorAll('canvas')).some(canvas => canvas.width > 32 && canvas.height > 32)) return null;
            const nodes = [node, ...node.querySelectorAll('p, span, div')];
            const faces = document.fonts ? Array.from(document.fonts) : [];
            if (nodes.some(element => {
              const families = getComputedStyle(element).fontFamily.split(',').map(name => name.trim().replace(/["']/g, '').toLowerCase());
              return faces.some(face => families.includes(face.family.replace(/["']/g, '').toLowerCase()));
            })) return null;
            const value = (node.innerText || '').trim();
            if (/[\\uE000-\\uF8FF]/.test(value)) return null;
            if (value.length > 80) {
              const state = window.floatingReaderCaptureState?.() || {current:0,maximum:0};
              let cursor = 0;
              if (state.current > 2 && document.caretRangeFromPoint) {
                const r = node.getBoundingClientRect();
                const caret = document.caretRangeFromPoint(Math.max(0,r.left)+24,Math.max(0,r.top)+24);
                if (caret && node.contains(caret.startContainer)) {
                  const prefix = document.createRange(); prefix.selectNodeContents(node); prefix.setEnd(caret.startContainer,caret.startOffset);
                  cursor = prefix.toString().length;
                }
              }
              if (state.current > 2 && cursor === 0) cursor = Math.floor((state.current / Math.max(1,state.maximum)) * value.length);
              return {text:value,cursor,sourceY:state.current};
            }
          }
          return null;
        })()
        """
        web.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self = self else { return }
            guard self.readGeneration == generation else { return }
            let payload = result as? [String: Any]
            if let value = payload?["text"] as? String ?? result as? String, !value.isEmpty {
                let fromWebsite = !self.preparingBackground && self.chainedText == nil && !self.appendRecognition
                let cursor = payload?["cursor"] as? Int ?? 0
                let sourceY = payload?["sourceY"] as? Double ?? 0
                self.textWasRecognized = false; self.finishText(value)
                if fromWebsite && cursor > 0 {
                    self.scrollNativeReading(to: cursor)
                    if let url = self.web.url?.absoluteString, self.validReadingURL(url) {
                        self.readingAnchors.append(ReadingAnchor(offset: cursor, sourceY: sourceY + 24, url: url))
                        self.readingAnchors.sort { $0.offset < $1.offset }
                    }
                    self.scheduleReadingProgress()
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if self.readGeneration == generation { self.recognizeVisiblePage() } }
            }
        }
    }
    func recognizeVisiblePage() {
        let generation = readGeneration
        setStatus("正在本机识别当前可见正文…")
        let script = """
        (() => {
            if (document.fonts && document.fonts.status !== 'loaded') return {waitingFonts:true};
            const node = document.querySelector('.readerChapterContent, .wr_readerChapterContent');
            if (!node) return null;
            const r = node.getBoundingClientRect();
            const x = Math.max(0, r.left), y = Math.max(0, r.top);
            const w = Math.min(innerWidth, r.right) - x, h = Math.min(innerHeight, r.bottom) - y;
            return w >= innerWidth * 0.55 && h >= innerHeight * 0.35 ? {x, y, w, h} : null;
        })()
        """
        web.evaluateJavaScript(script, completionHandler: { [weak self] value, _ in
            guard let self = self else { return }
            guard self.readGeneration == generation else { return }
            if (value as? [String: Any])?["waitingFonts"] as? Bool == true {
                self.recognitionRetries += 1
                if self.recognitionRetries < 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if self.readGeneration == generation { self.recognizeVisiblePage() } }
                } else {
                    self.preparingText = false; self.continuing = false; self.appendRecognition = false
                    self.preparingBackground = false; self.backgroundNextLoading = false; self.prefetchBudget = 0
                    self.setStatus("网页字体尚未加载完成，已保留原正文；请稍后重新读取。")
                }
                return
            }
            var region = self.web.bounds
            if let rect = value as? [String: NSNumber], let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                region = NSRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue).intersection(self.web.bounds)
            }
            self.web.evaluateJavaScript("window.floatingReaderCaptureState?.()", completionHandler: { [weak self] state, _ in
                guard let self = self, self.readGeneration == generation else { return }
                let offset = (state as? [String: Any])?["current"] as? Double ?? 0
                let maximum = (state as? [String: Any])?["maximum"] as? Double
                self.captureText(region: region, sourceOffset: CGFloat(offset), atSourceEnd: maximum.map { offset >= $0 - 2 } ?? false)
            })
        })
    }
    func isNewSourceLine(_ box: CGRect, region: NSRect, offset: CGFloat, forward: Bool, top: CGFloat?, bottom: CGFloat?) -> Bool {
        let position = offset + region.minY + (1 - box.midY) * region.height
        let tolerance = box.height * region.height * 0.3
        if forward, let boundary = bottom { return position > boundary + tolerance }
        if !forward, let boundary = top { return position < boundary - tolerance }
        return true
    }
    func isCompleteSourceLine(_ box: CGRect, height: CGFloat, offset: CGFloat, atEnd: Bool) -> Bool {
        // Discard an edge fragment before advancing the acknowledged reading boundary.
        // The next overlapping screenshot will contain the entire row.
        let margin = max(12, box.height * height * 0.65)
        if offset > 2 && (1 - box.maxY) * height < margin { return false }
        if !atEnd && box.minY * height < margin { return false }
        return true
    }
    func captureText(region: NSRect, sourceOffset: CGFloat = 0, atSourceEnd: Bool = false) {
        let generation = readGeneration
        let previousTop = recognizedTop, previousBottom = recognizedBottom
        let continuingCapture = appendRecognition
        let forwardCapture = appendForward
        let configuration = WKSnapshotConfiguration()
        configuration.rect = region
        configuration.snapshotWidth = NSNumber(value: min(2400, Double(region.width * 2)))
        web.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self = self else { return }
            guard self.readGeneration == generation else { return }
            guard let image = image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.preparingText = false; self.pendingStyle = nil; self.continuing = false; self.appendRecognition = false; self.chainedText = nil
                self.preparingBackground = false; self.backgroundNextLoading = false
                self.setStatus("正文截图失败，请等待章节加载后重试。"); return
            }
            DispatchQueue.global(qos: continuingCapture && self.prefetchOnly ? .utility : .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.minimumTextHeight = 0.003
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
                    let observations = request.results ?? []
                    let lines = observations.filter { line in
                        if !self.isCompleteSourceLine(line.boundingBox, height: region.height, offset: sourceOffset, atEnd: atSourceEnd) { return false }
                        if continuingCapture && !self.isNewSourceLine(line.boundingBox, region: region, offset: sourceOffset, forward: forwardCapture, top: previousTop, bottom: previousBottom) { return false }
                        guard let value = line.topCandidates(1).first?.string else { return false }
                        let compact = value.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                        return compact.range(of: "^(点击)?去微信读书(App|app)?阅读$", options: .regularExpression) == nil && !["上一章", "下一章", "上一页", "下一页", "<上一页", "下一页>", "<上一页下一页>", "书城", "目录"].contains(compact)
                    }
                    // Vision observation order is not guaranteed. Group fragments into visual rows,
                    // then read each row from left to right instead of concatenating arbitrary order.
                    let ordered = lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    var rows: [[VNRecognizedTextObservation]] = []
                    for observation in ordered {
                        if let row = rows.last, let reference = row.first,
                           abs(reference.boundingBox.midY - observation.boundingBox.midY) < min(reference.boundingBox.height, observation.boundingBox.height) * 0.45 {
                            rows[rows.count - 1].append(observation)
                        } else { rows.append([observation]) }
                    }
                    let readingLines = rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
                    let value = ReadingParagraphs.text(from: readingLines)
                    DispatchQueue.main.async {
                        guard self.readGeneration == generation else { return }
                        self.skippedOverlapLines += max(0, observations.count - lines.count)
                        if continuingCapture && lines.isEmpty {
                            if self.recognitionRetries < 3 {
                                self.recognitionRetries += 1
                                self.setStatus("本段尚未识别完整，正在原位置重试…")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    if self.readGeneration == generation { self.recognizeVisiblePage() }
                                }
                            } else {
                                self.web.evaluateJavaScript("if(window.floatingReaderPendingCaptureState)window.floatingReaderRestoreCaptureState?.(window.floatingReaderPendingCaptureState);window.floatingReaderPendingCaptureState=undefined;true",completionHandler:nil)
                                self.preparingText = false; self.appendRecognition = false; self.continuing = false
                                self.prefetchBudget = 0; self.automaticLoadingPaused = true
                                self.setStatus("此段未读完整，已保留原位置，未跳过正文。可重新读取当前章节或核对原网页。")
                            }
                            return
                        }
                        if !continuingCapture && (value.filter({ !$0.isWhitespace }).count < 80 || lines.count < 3) {
                            if self.recognitionRetries < 2 {
                                self.recognitionRetries += 1
                                self.setStatus("正文尚未完整绘制，正在重试…")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self.readGeneration == generation { self.recognizeVisiblePage() } }
                                return
                            }
                            self.preparingText = false; self.pendingStyle = nil; self.continuing = false; self.appendRecognition = false; self.chainedText = nil; self.preparingBackground=false; self.backgroundNextLoading=false
                            self.automaticLoadingPaused = true
                            self.prefetchBudget = 0
                            self.setStatus("未读取到足够正文，已保留原内容。可切换到原网页检查，不展示零散识别结果。")
                        } else {
                            let positions = lines.map { sourceOffset + region.minY + (1 - $0.boundingBox.midY) * region.height }
                            if let top = positions.min() { self.recognizedTop = min(self.recognizedTop ?? top, top) }
                            if let bottom = positions.max() { self.recognizedBottom = max(self.recognizedBottom ?? bottom, bottom) }
                            self.textWasRecognized = true
                            let backgroundCapture = self.preparingBackground
                            let chapterURL = self.web.url?.absoluteString ?? ""
                            self.finishText(value)
                            if !backgroundCapture {
                                for line in lines {
                                    guard let content = line.topCandidates(1).first?.string else { continue }
                                    let position = sourceOffset + region.minY + (1 - line.boundingBox.midY) * region.height
                                    self.recordReadingAnchor(content, sourceY: Double(position), url: chapterURL)
                                }
                                self.scheduleReadingProgress()
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.readGeneration == generation else { return }
                        self.preparingText = false; self.pendingStyle = nil; self.continuing = false; self.appendRecognition = false; self.chainedText = nil
                        self.preparingBackground = false; self.backgroundNextLoading = false
                        self.setStatus("识别失败：" + error.localizedDescription)
                    }
                }
            }
        }
    }
    func setStatus(_ message: String) { status.stringValue = message; status.toolTip = message }
    func alert(_ title: String, _ message: String) { let a = NSAlert(); a.messageText = title; a.informativeText = message; a.addButton(withTitle: "知道了"); a.beginSheetModal(for: window) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { alert("网页加载失败", error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { alert("章节加载失败", error.localizedDescription + "\n可通过阅读菜单重新加载，或恢复网页原样。") }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        alert("网页进程已停止", "请在阅读菜单选择重新加载网页。如再次空白，选择恢复网页原样。")
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if url.host == "weread.qq.com" { webView.load(navigationAction.request) }
            else if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }
        return nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false } // Only closing the reader explicitly quits; cache windows may close independently.
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === NSColorPanel.shared { finishColorPicker(); return }
        if notification.object as? NSWindow === window {
            cancelPendingRead(); renderingWindow?.close(); renderingWindow = nil
            NSApp.terminate(nil)
        }
    }
    func windowDidMove(_ notification: Notification) {
        if let panel = notification.object as? NSPanel, panel === sizeAdjustmentPanel || panel === spacingAdjustmentPanel, let key = panel.identifier?.rawValue {
            defaults.set(NSStringFromPoint(panel.frame.origin), forKey: key)
        }
        guard notification.object as? NSWindow === renderingWindow, let helper = renderingWindow as? RenderingWindow else { return }
        if NSScreen.screens.contains(where: { $0.frame.intersects(helper.frame) }) { helper.securePosition() }
    }
}
let app = NSApplication.shared
let delegate = ReaderDelegate()
if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = icon
}
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
