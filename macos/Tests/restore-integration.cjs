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
let script=try! String(contentsOfFile:"${base}/Resources/reader.js",encoding:.utf8)
d.web.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
d.mountSource(offscreen:true)
let url="https://weread.qq.com/web/reader/abc1234567890abcdef12345k1234567890abcdef123456"
let content=String(repeating:"记录正文和位置，重新打开后还要能够继续阅读。",count:180)
let saved=ReadingBookmark(url:url,sourceY:600,cursor:800,text:content,anchors:[ReadingAnchor(offset:0,sourceY:0,url:url),ReadingAnchor(offset:800,sourceY:624,url:url),ReadingAnchor(offset:3000,sourceY:3500,url:url)],recognized:true,updated:Date().timeIntervalSince1970)
d.pendingReadingBookmark=saved;d.preferWebsiteProgress=false;d.restoringReading=true
d.web.loadFileURL(URL(fileURLWithPath:"${base}/Tests/fixtures/reader/progress.html"),allowingReadAccessTo:URL(fileURLWithPath:"${base}/Tests/fixtures"))
var checked=false
let deadline=Date().addingTimeInterval(20)
let timer=Timer(timeInterval:0.2,repeats:true){_ in
 if Date()>deadline {print("restore timeout",d.status.stringValue);exit(2)}
 if !d.restoringReading && !checked {
  checked=true
  assert(d.pure && d.text.string==content)
  assert(abs(d.currentReadingBookmark()!.cursor-800)<80)
  d.web.evaluateJavaScript("window.floatingReaderCaptureState()") {value,_ in
   let state=value as! [String:Double]
   assert(abs(state["current"]!-600)<2)
   assert(state["end"]!>1000)
   print("WebKit 加载后恢复正文、原生文字位置、网页滚动位置及预读边界端到端检查通过")
   d.progressWork?.cancel();prefs.removePersistentDomain(forName:"local.floatingreader.progress-tests");exit(0)
  }
 }
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync('/tmp/ReaderRestoreIntegration.swift',source);
