const fs=require('fs'),path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');
source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'))
.replace('        home()\n        dragMonitor','        dragMonitor')
.replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','')
.replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()')
.replace('let defaults = UserDefaults.standard','let defaults = UserDefaults(suiteName: "local.floatingreader.progress-tests")!')
.replace('guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"), let image','let url = URL(fileURLWithPath: '+JSON.stringify(path.join(base,'Resources/Icons'))+').appendingPathComponent(name + ".png")\n        guard let image');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let prefs=UserDefaults(suiteName:"local.floatingreader.progress-tests")!
prefs.removePersistentDomain(forName:"local.floatingreader.progress-tests")
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
let url="https://weread.qq.com/web/reader/abc1234567890abcdef12345k1234567890abcdef123456"
assert(d.bookEntryURL(url)!.path=="/web/reader/abc1234567890abcdef12345")
assert(!d.validReadingURL("https://example.com/web/reader/test"))
let content=String(repeating:"读到这里应当保存本地位置，后台预读不能改变当前书签。",count:200)
d.setText(content)
d.readingAnchors=[ReadingAnchor(offset:0,sourceY:0,url:url),ReadingAnchor(offset:1000,sourceY:900,url:url),ReadingAnchor(offset:3000,sourceY:2700,url:url)]
d.text.scrollRangeToVisible(NSRange(location:1300,length:1))
let saved=d.saveReadingBookmark()!
assert(saved.url==url && saved.cursor>500 && saved.sourceY>0)
let reloaded=ReaderDelegate()
assert(reloaded.storedBookmark()!.cursor==saved.cursor && reloaded.storedBookmark()!.text==content)
d.preferWebsiteProgress=true
assert(d.prefersNewWebsitePosition(saved,url:url+"different",y:0))
assert(d.prefersNewWebsitePosition(saved,url:url,y:saved.sourceY+200))
assert(!d.prefersNewWebsitePosition(saved,url:url,y:saved.sourceY))
d.forceWebsiteProgress=true
assert(d.prefersNewWebsitePosition(saved,url:url,y:0))
d.forceWebsiteProgress=false
d.preferWebsiteProgress=false
assert(!d.prefersNewWebsitePosition(saved,url:url+"different",y:200))
d.restoreLocalBookmark(saved)
let restored=d.currentReadingBookmark()!
assert(abs(restored.cursor-saved.cursor)<80)
d.backgroundNextLoading=true;d.sourceAhead=true
assert(d.currentReadingBookmark()!.url==url)
d.setText(content+"NEXT CHAPTER CONTENT")
d.readingAnchors.append(ReadingAnchor(offset:(content as NSString).length,sourceY:0,url:url+"next"))
d.scrollNativeReading(to:800)
assert(d.currentReadingBookmark()!.text==content,"书签不能混入后续章节缓存")
print("阅读书签保存及重载、章节路由、正文位置恢复、外部进度选择、预读不污染书签检查通过")
prefs.removePersistentDomain(forName:"local.floatingreader.progress-tests")
exit(0)
`;
fs.writeFileSync('/tmp/ReaderProgressIntegration.swift',source);
