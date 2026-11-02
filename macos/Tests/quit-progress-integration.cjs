const fs=require('fs'),path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');
source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'))
.replace('        home()\n        dragMonitor','        dragMonitor')
.replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','')
.replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()')
.replace('let defaults = UserDefaults.standard','let defaults = UserDefaults(suiteName: "local.floatingreader.quit-progress-tests")!')
.replace('guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"), let image','let url = URL(fileURLWithPath: '+JSON.stringify(path.join(base,'Resources/Icons'))+').appendingPathComponent(name + ".png")\n        guard let image');
source=source.replace('return url.scheme == "https" && url.host == "weread.qq.com" && url.path.hasPrefix("/web/reader/")','return url.isFileURL || (url.scheme == "https" && url.host == "weread.qq.com" && url.path.hasPrefix("/web/reader/"))');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let prefs=UserDefaults(suiteName:"local.floatingreader.quit-progress-tests")!
prefs.removePersistentDomain(forName:"local.floatingreader.quit-progress-tests")
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
let script=try! String(contentsOfFile:"${base}/Resources/reader.js",encoding:.utf8)
d.web.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
d.mountSource(offscreen:true)
let file=URL(fileURLWithPath:"${base}/Tests/fixtures/reader/progress.html")
d.web.loadFileURL(file,allowingReadAccessTo:URL(fileURLWithPath:"${base}/Tests/fixtures"))
var closing=false
let observer=NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main){_ in
 assert(d.repliedToTermination)
 assert(d.storedBookmark()?.url==file.absoluteString)
 print("实际关闭主窗口：先保存书签和网页位置，再退出进程检查通过")
 prefs.removePersistentDomain(forName:"local.floatingreader.quit-progress-tests")
}
let deadline=Date().addingTimeInterval(15)
let timer=Timer(timeInterval:0.2,repeats:true){_ in
 if Date()>deadline {print("quit timeout");exit(2)}
 if !closing {
  d.web.evaluateJavaScript("window.floatingReaderChapterSnapshot?.().ready"){ready,_ in
   if ready as? Bool == true && !closing {
    closing=true
    d.setText(String(repeating:"退出前保存阅读位置。",count:300))
    d.readingAnchors=[ReadingAnchor(offset:0,sourceY:0,url:file.absoluteString),ReadingAnchor(offset:800,sourceY:900,url:file.absoluteString)]
    d.text.scrollRangeToVisible(NSRange(location:800,length:1))
    app.delegate=d
    d.window.performClose(nil)
   }
  }
 }
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync('/tmp/ReaderQuitProgressIntegration.swift',source);
