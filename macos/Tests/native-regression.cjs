const fs = require('fs');
const path = require('path');
const base = path.resolve(__dirname, '..');
let source = fs.readFileSync(path.join(base, 'Sources/main.swift'), 'utf8');
source = source.slice(0, source.lastIndexOf('let app = NSApplication.shared'));
source = source.replace('        home()\n        dragMonitor', '        dragMonitor');
source = source.replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)', '');
source = source.replace('config.websiteDataStore = .default()', 'config.websiteDataStore = .nonPersistent()');
source = source.replace('guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"), let image', 'let url = URL(fileURLWithPath: '+JSON.stringify(path.join(base,'Resources/Icons'))+').appendingPathComponent(name + ".png")\n        guard let image');
source += `
let app = NSApplication.shared
let d = ReaderDelegate()
d.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
d.dark = false; d.customInk = false; d.customBackground = false
d.hiddenBar = false; d.transparent = false; d.backgroundOpacity = 1; d.size = 22
d.setText(String(repeating: "正文测试：窗口改变大小时，文字应折行；留白仍可拖动。\\n", count: 100))
func verifyToolbar(_ label: String) {
    d.root.layoutSubtreeIfNeeded(); d.layoutText()
    let viewport = d.root.bounds
    assert(viewport.contains(d.toolbarScroll.frame), "工具栏在窗口范围外 " + label)
    assert(d.toolbarScroll.frame.maxY <= viewport.maxY - d.titleBackdropHeight.constant + 1)
    let clip = d.toolbarScroll.contentView
    let first = d.bar.arrangedSubviews[0]
    let firstInClip = clip.convert(first.bounds, from: first)
    assert(clip.bounds.contains(firstInClip), "第一个按钮被裁切 " + label)
    assert((first as! NSButton).image != nil, "图标资源缺失")
    assert(abs(d.text.frame.width - d.scroll.contentSize.width) < 1)
    print("可见布局检查通过：", label)
}
for width in [720.0, 300.0, 1000.0] {
    d.window.setContentSize(NSSize(width: width, height: 600))
    verifyToolbar(String(width))
}
for _ in 0..<8 {
    d.chromeVisible = false; d.applyAppearance()
    assert(!d.window.styleMask.contains(.titled))
    d.resetAppearance()
    verifyToolbar("隐藏后恢复")
}
d.window.setContentSize(NSSize(width: 720, height: 600)); verifyToolbar("最终")
let event = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)!)!
d.scroll.scrollWheel(with: event)
assert(d.scroll.contentView.bounds.origin.y > 0)
d.resetAppearance()
assert(d.chromeVisible && d.modeButton.title == "纯文字")
assert(d.bar.arrangedSubviews.contains(d.backgroundButton))
assert(!d.bar.arrangedSubviews.contains(where: {$0 is NSSlider}))
let chosen = NSColor(srgbRed: 0.23, green: 0.38, blue: 0.49, alpha: 1)
d.backgroundColor()
d.backgroundPicker!.color = chosen; d.colorChanged(d.backgroundPicker!)
let selectedInk = d.ink, selectedBackground = d.background
for _ in 0..<30 {
 d.toggleBackground(); assert(d.hiddenBar && d.root.fillColor.alphaComponent == 0)
 d.toggleBackground(); assert(!d.hiddenBar && d.root.fillColor == selectedBackground)
 assert(d.ink == selectedInk && d.background == selectedBackground)
}
assert(d.readerBorder.color == selectedBackground && !d.readerBorder.isHidden)
assert(!d.scroll.drawsBackground)
assert((d.window as! ReaderWindow).isResizePoint(NSPoint(x: d.root.bounds.maxX - 8, y: 30)))
assert(d.status.layer!.backgroundColor!.alpha == 0)
assert(d.browserHost.layer!.backgroundColor!.alpha == 0)
print("显示隐藏、配色保持和紧凑工具栏检查通过")
let corner = (d.window as! ReaderWindow).resizeEdges(at: NSPoint(x: d.root.bounds.maxX - 18, y: 18))
assert(corner.1 && corner.2)
assert(!d.isCompleteSourceLine(CGRect(x: 0.1, y: 0.002, width: 0.8, height: 0.015), height: 1800, offset: 0, atEnd: false))
assert(d.isCompleteSourceLine(CGRect(x: 0.1, y: 0.35, width: 0.8, height: 0.015), height: 1800, offset: 1440, atEnd: false))
assert(!d.isCompleteSourceLine(CGRect(x: 0.1, y: 0.983, width: 0.8, height: 0.015), height: 1800, offset: 1440, atEnd: false))
print("截图上下边缘残行不推进读取边界检查通过")
let region = NSRect(x: 0, y: 0, width: 1100, height: 1800)
let overlapLine = CGRect(x: 0.1, y: 0.90, width: 0.8, height: 0.02)
let newLine = CGRect(x: 0.1, y: 0.50, width: 0.8, height: 0.02)
assert(!d.isNewSourceLine(overlapLine, region: region, offset: 1440, forward: true, top: 40, bottom: 1770))
assert(d.isNewSourceLine(newLine, region: region, offset: 1440, forward: true, top: 40, bottom: 1770))
assert(!d.isNewSourceLine(newLine, region: region, offset: 1440, forward: false, top: 40, bottom: 1770))
print("滚动截图重叠区域按正文坐标过滤检查通过")
let largePassage = String(repeating: "正文大段重叠超过一千五百字的测试内容。", count: 250)
assert(d.mergeContinuation("START" + largePassage, largePassage + "END") == "START" + largePassage + "\\n\\nEND")
assert(d.mergeContinuation(largePassage, largePassage.replacingOccurrences(of: "。", with: "。\\n")) == largePassage)
let passage = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 8)
let faulty = "x" + passage.dropFirst()
assert(d.mergeContinuation(passage, faulty + "NEWCONTENT").hasSuffix("NEWCONTENT"))
assert(d.mergeContinuation(passage, faulty + "NEWCONTENT").count < passage.count + 20)
assert(d.mergeContinuation("different previous text", "different following text").contains("different following text"))
if let close = d.window.standardWindowButton(.closeButton) {
    let point = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
    assert(!(d.window as! ReaderWindow).isResizePoint(point))
}
let w = d.window as! ReaderWindow
assert(w.isResizePoint(NSPoint(x: 1, y: 100)))
assert(!w.isResizePoint(NSPoint(x: 150, y: 100)))
d.scroll.contentView.scroll(to: .zero)
d.backgroundOpacity = 1; d.dark = false; d.customBackground = false; d.customInk = false; d.applyAppearance()
if let bitmap = d.root.bitmapImageRepForCachingDisplay(in: d.root.bounds) {
    d.root.cacheDisplay(in: d.root.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/reader-ui-check.png"))
}
print("原生滚动、缩放分流、颜色与透明度、图标加载检查通过")
let helper=d.renderingWindow as! RenderingWindow
assert(!helper.canBecomeKey && !helper.canBecomeMain && helper.ignoresMouseEvents)
for _ in 0..<40 {
    d.togglePin()
    assert(!NSScreen.screens.contains { $0.frame.intersects(helper.frame) })
    assert(d.web.window === helper)
}
helper.setFrame(NSRect(origin: .zero, size: helper.frame.size), display: false)
assert(!NSScreen.screens.contains { $0.frame.intersects(helper.frame) })
helper.setFrameOrigin(.zero)
assert(!NSScreen.screens.contains { $0.frame.intersects(helper.frame) })
print("辅助窗不抢焦点、不接收鼠标、强制移动和四十次置顶切换检查通过")
d.lineHeightMultiple=1;d.applyAppearance();let compactHeight=d.text.frame.height
d.lineHeightMultiple=2;d.applyAppearance()
assert(d.text.frame.height > compactHeight)
assert(UserDefaults.standard.double(forKey:"lineHeight") == 2)
assert((d.text.textStorage!.attribute(.paragraphStyle,at:0,effectiveRange:nil) as! NSParagraphStyle).lineHeightMultiple == 2)
print("行间距重排和持久化检查通过")
let oldGeneration = d.readGeneration
d.preparingText = true; d.changingChapter = true; d.chainedText = "旧正文"
d.cancelPendingRead()
assert(d.readGeneration > oldGeneration && !d.preparingText && !d.changingChapter && d.chainedText == nil)
print("过期读取与切章状态取消检查通过")
d.window.close()
`;
fs.writeFileSync('/tmp/ReaderNativeRegression.swift', source);
