const fs=require('fs'),path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');
source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'))
.replace('        home()\n        dragMonitor','        dragMonitor')
.replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','')
.replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()')
.replace('let defaults = UserDefaults.standard','let defaults = UserDefaults(suiteName: "local.floatingreader.shortcut-tests")!')
.replace('guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"), let image','let url = URL(fileURLWithPath: '+JSON.stringify(path.join(base,'Resources/Icons'))+').appendingPathComponent(name + ".png")\n        guard let image');
source+=`
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
UserDefaults(suiteName:"local.floatingreader.shortcut-tests")!.removePersistentDomain(forName:"local.floatingreader.shortcut-tests")
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
let wasPinned=d.pinned
d.togglePin();assert(d.pinned != wasPinned && d.window.level == (d.pinned ? .floating : .normal))
d.togglePin();assert(d.pinned == wasPinned)
assert(!d.shortcutItems.contains(where:{$0.1.action == #selector(ReaderDelegate.pin) || $0.1.action == #selector(ReaderDelegate.unpin)}))
let hide=NSStringFromSelector(#selector(ReaderDelegate.toggleBar))
let bigger=NSStringFromSelector(#selector(ReaderDelegate.larger))
func event(_ key:String,_ flags:NSEvent.ModifierFlags,_ code:UInt16=0)->NSEvent {
 NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:d.shortcutPanel?.windowNumber ?? d.window.windowNumber,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:code)!
}
assert(d.matchingShortcut(event("/",.command,44))?.action == #selector(ReaderDelegate.toggleBar))
assert(d.matchingShortcut(event("=",.command,24))?.action == #selector(ReaderDelegate.larger))
assert(d.matchingShortcut(event("+",[.command,.shift],24))?.action == #selector(ReaderDelegate.larger))
assert(d.matchingShortcut(event("",.command,126))?.action == #selector(ReaderDelegate.previousChapter))
assert(d.shortcutItems.contains(where:{$0.0.hasSuffix(".alternate")}))
for width in [300.0,720.0] {
 d.window.setContentSize(NSSize(width:width,height:600));d.root.layoutSubtreeIfNeeded()
 assert(d.root.bounds.contains(d.shortcutsButton.frame))
 assert(d.shortcutsButton.frame.minX >= d.toolbarScroll.frame.maxX)
 assert(d.shortcutsButton.image != nil)
}
d.showShortcutSettings()
assert(d.shortcutPanel != nil && d.shortcutButtons.count == d.shortcutItems.count)
let button=d.shortcutButtons[hide]!
button.performClick(nil)
assert(d.recordingShortcut === button)
d.recordShortcut(event("k",.command,40))
assert(d.recordingShortcut === button && d.shortcutMessage.stringValue.contains("已用于"))
d.recordShortcut(event("y",[.control,.option],16))
assert(d.recordingShortcut == nil)
assert(d.matchingShortcut(event("/",.command,44)) == nil)
assert(d.matchingShortcut(event("y",[.control,.option],16))?.action == #selector(ReaderDelegate.toggleBar))
assert(d.saveShortcut(ReaderShortcut(key:"=",modifiers:NSEvent.ModifierFlags([.command,.shift]).rawValue),id:hide) != nil)
let stored=try! JSONDecoder().decode([String:ReaderShortcut].self,from:d.defaults.data(forKey:"readerShortcuts")!)
assert(stored[hide]?.key == "y")
let reloaded=ReaderDelegate();reloaded.createMenu()
assert(reloaded.binding(hide).key == "y")
assert(reloaded.binding(hide).modifiers == NSEvent.ModifierFlags([.control,.option]).rawValue)
button.performClick(nil);d.recordShortcut(event("",[],51))
assert(d.binding(hide).key.isEmpty && d.matchingShortcut(event("y",[.control,.option],16)) == nil)
button.performClick(nil);d.recordShortcut(event("",[],53))
assert(d.recordingShortcut == nil)
d.resetShortcuts()
assert(d.binding(hide).key == "/" && d.defaults.data(forKey:"readerShortcuts") == nil)
if let view=d.shortcutPanel?.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
 view.cacheDisplay(in:view.bounds,to:bitmap)
 try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/reader-shortcuts-check.png"))
}
d.closeShortcutSettings();assert(d.shortcutPanel == nil && d.recordingShortcut == nil)
UserDefaults(suiteName:"local.floatingreader.shortcut-tests")!.removePersistentDomain(forName:"local.floatingreader.shortcut-tests")
print("快捷键默认组合、改键录入、旧键失效、冲突检测、保存、清除、取消和恢复默认检查通过")
exit(0)
`;
fs.writeFileSync('/tmp/ReaderShortcutsIntegration.swift',source);
