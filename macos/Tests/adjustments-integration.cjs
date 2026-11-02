const fs=require('fs'),path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');
source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'))
.replace('        home()\n        dragMonitor','        dragMonitor')
.replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','')
.replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()')
.replace('let defaults = UserDefaults.standard','let defaults = UserDefaults(suiteName: "local.floatingreader.adjustment-tests")!')
.replace('guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"), let image','let url = URL(fileURLWithPath: '+JSON.stringify(path.join(base,'Resources/Icons'))+').appendingPathComponent(name + ".png")\n        guard let image');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.regular)
DispatchQueue.main.async {
let prefs=UserDefaults(suiteName:"local.floatingreader.adjustment-tests")!
prefs.removePersistentDomain(forName:"local.floatingreader.adjustment-tests")
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
d.setText(String(repeating:"正文预览，调整期间应保持可滚动。",count:100))
assert(!d.text.isSelectable && d.text.dragEnabled)
let readerPanel=d.window as! ReaderWindow
readerPanel.orderOut(nil)
readerPanel.resignKey()
readerPanel.focusForInteraction()
DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
assert(readerPanel.isKeyWindow && readerPanel.isMainWindow,"点击阅读区后没有恢复窗口焦点")
assert(!d.text.isSelectable && d.text.dragEnabled)
let initialFrame=d.window.frame
for width in [160.0,320.0,900.0] {
 d.window.setContentSize(NSSize(width:width,height:180));d.layoutText()
 assert(d.web.bounds.size == ReadingViewport.size)
 assert(abs(d.text.frame.width-d.scroll.contentSize.width)<1)
}
d.window.setFrame(initialFrame,display:false);d.layoutText()
d.fontSizePanel();d.lineHeightPanel()
let sizePanel=d.sizeAdjustmentPanel!,spacingPanel=d.spacingAdjustmentPanel!
assert(d.window.attachedSheet == nil && app.modalWindow == nil)
assert(sizePanel.sheetParent == nil && spacingPanel.sheetParent == nil)
assert(sizePanel.isMovable && sizePanel.isMovableByWindowBackground && sizePanel.isVisible)
assert(spacingPanel.isMovable && spacingPanel.isMovableByWindowBackground && spacingPanel.isVisible)
assert(!d.text.usesAdaptiveColorMappingForDarkAppearance)
assert(!d.scroll.contentView.drawsBackground && !d.text.drawsBackground)
assert(abs(d.background.redComponent - 251.0/255)<0.001)
assert(abs(d.ink.redComponent - 0.2)<0.001)
d.chromeVisible=false;d.applyVisibility()
assert(d.root.fillColor.alphaComponent == 0)
d.chromeVisible=true;d.applyVisibility()
let keptInk=d.ink,keptBackground=d.background
let keptText=d.text.string
for _ in 0..<10 {
 d.toggleBar();assert(d.backgroundOpacity == 0)
 d.toggleBar();assert(d.backgroundOpacity == 1)
 assert(d.ink == keptInk && d.background == keptBackground && d.text.string == keptText && d.pure)
}
assert(d.status.superview === d.text && !d.status.drawsBackground)
assert(d.modeButton.image == nil && d.root.fillColor == d.background)
d.setText("")
d.root.layoutSubtreeIfNeeded()
let bitmap=d.root.bitmapImageRepForCachingDisplay(in:d.root.bounds)!
d.root.cacheDisplay(in:d.root.bounds,to:bitmap)
let pixel=bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)!.usingColorSpace(.sRGB)!
let expected=d.background.usingColorSpace(.sRGB)!
assert(abs(pixel.redComponent-expected.redComponent)<0.02 && abs(pixel.greenComponent-expected.greenComponent)<0.02 && abs(pixel.blueComponent-expected.blueComponent)<0.02,"正文空白区域没有绘制所选背景")
d.setText(keptText)
let originalText=d.text.string
let originalAttributes=d.text.attributedString()
assert(d.window is NSPanel)
assert(d.window.styleMask.contains(.nonactivatingPanel))
assert(!(d.window as! NSPanel).hidesOnDeactivate)
d.pin()
assert(d.window.collectionBehavior.contains(.fullScreenAuxiliary))
if #available(macOS 13.0, *) { assert(d.window.collectionBehavior.contains(.canJoinAllApplications)) }
d.unpin()
assert(d.window.level == .normal && !d.window.collectionBehavior.contains(.fullScreenAuxiliary))
d.pin()
var pinEdits=0
let pinObserver=NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,object:d.text.textStorage,queue:nil) { _ in pinEdits += 1 }
for _ in 0..<100 { d.togglePin() }
NotificationCenter.default.removeObserver(pinObserver)
assert(pinEdits == 0)
assert(d.text.attributedString().isEqual(to:originalAttributes))
let origin=sizePanel.frame.origin
sizePanel.setFrameOrigin(NSPoint(x:origin.x+40,y:origin.y-40))
assert(sizePanel.frame.origin != origin)
d.windowDidMove(Notification(name:NSWindow.didMoveNotification,object:sizePanel))
assert(prefs.string(forKey:"fontSizePanelPosition") != nil)
d.sizeAdjustmentSlider!.doubleValue=30;d.fontSizeChanged(d.sizeAdjustmentSlider!)
assert(d.size==30 && d.text.string==originalText)
assert((d.text.textStorage!.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize==30)
d.spacingAdjustmentSlider!.doubleValue=1.8;d.lineHeightChanged(d.spacingAdjustmentSlider!)
assert(abs(d.lineHeightMultiple-1.8)<0.001 && d.window.attachedSheet == nil)
d.color();let colorPanel=d.inkPicker!
assert(colorPanel.isMovable && colorPanel.sheetParent == nil && colorPanel.isContinuous)
colorPanel.color=NSColor.systemRed
NotificationCenter.default.post(name:NSColorPanel.colorDidChangeNotification,object:colorPanel)
assert(d.ink==NSColor.systemRed.usingColorSpace(.sRGB)!.withAlphaComponent(1))
let unchangedInk=d.ink
assert(d.text.textColor == unchangedInk)
d.chromeVisible=false;d.applyVisibility()
d.window.makeKeyAndOrderFront(nil)
d.window.resignKey()
d.window.makeKey()
assert(d.ink == unchangedInk && d.text.textColor == unchangedInk)
assert((d.text.textStorage!.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor) == unchangedInk)
let unchangedOpacity=d.backgroundOpacity
d.backgroundColor()
let backgroundPanel=d.backgroundPicker!
assert(backgroundPanel === colorPanel && backgroundPanel === NSColorPanel.shared)
assert(backgroundPanel.title=="正文背景颜色" && d.window.attachedSheet == nil)
let expectedBlue=NSColor(srgbRed:0.1,green:0.25,blue:0.7,alpha:1)
backgroundPanel.color=expectedBlue
NotificationCenter.default.post(name:NSColorPanel.colorDidChangeNotification,object:backgroundPanel)
let actualBlue=d.background.usingColorSpace(.sRGB)!
print("Background RGB:",actualBlue.redComponent,actualBlue.greenComponent,actualBlue.blueComponent)
fflush(stdout)
assert(abs(actualBlue.redComponent-0.1)<0.001 && abs(actualBlue.greenComponent-0.25)<0.001 && abs(actualBlue.blueComponent-0.7)<0.001)
assert(d.ink==unchangedInk && d.backgroundOpacity==unchangedOpacity)
assert(backgroundPanel.accessoryView != nil)
let chip=backgroundPanel.accessoryView!.subviews.compactMap{$0 as? NSButton}.first{$0.tag == 6}!
chip.performClick(nil)
assert(d.background == d.presetColor(6))
let exactBackground=d.background, exactInk=d.ink
backgroundPanel.performClose(nil)
RunLoop.main.run(until:Date().addingTimeInterval(0.3))
assert(d.background == exactBackground && d.ink == exactInk)
// A late notification from the closing panel must not overwrite the committed palette.
backgroundPanel.color = NSColor.white
NotificationCenter.default.post(name:NSColorPanel.colorDidChangeNotification,object:backgroundPanel)
assert(d.background == exactBackground && d.ink == exactInk)
d.color()
assert(d.inkPicker!.color == exactInk)
d.inkPicker!.performClose(nil)
d.backgroundColor()
assert(d.backgroundPicker!.color == exactBackground)
d.backgroundPicker!.performClose(nil)
let saved=try! NSKeyedUnarchiver.unarchivedObject(ofClass:NSColor.self,from:prefs.data(forKey:"backgroundColor")!)!
assert(saved == exactBackground)
let reloaded=ReaderDelegate()
reloaded.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
assert(reloaded.background == exactBackground && reloaded.ink == exactInk,"重新启动未保留选定颜色")
for _ in 0..<50 {
 d.toggleBar();d.toggleBar()
 assert(d.background == exactBackground && d.ink == exactInk)
}
d.resetAppearance()
assert(d.chromeVisible && d.root.fillColor == exactBackground)
assert(d.modeButton.bounds.width <= 54)
assert(!d.bar.arrangedSubviews.contains(where:{$0 is NSSlider}))
sizePanel.close();d.fontSizePanel()
assert(d.sizeAdjustmentPanel === sizePanel && sizePanel.isVisible)
assert(sizePanel.frame.origin != origin)
sizePanel.close();spacingPanel.close();colorPanel.close();backgroundPanel.close()
prefs.removePersistentDomain(forName:"local.floatingreader.adjustment-tests")
print("字号、行距非模态可拖动、实时预览、位置记忆及颜色面板检查通过")
exit(0)
}
}
app.run()
`;
fs.writeFileSync('/tmp/ReaderAdjustmentIntegration.swift',source);
