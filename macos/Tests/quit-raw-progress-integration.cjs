const fs=require('fs'),path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');
source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'))
.replace('        home()\n        dragMonitor','        dragMonitor')
.replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','')
.replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()')
.replace('let defaults = UserDefaults.standard','let defaults = UserDefaults(suiteName: "local.floatingreader.quit-raw-progress-tests")!')
.replace('guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"), let image','let url = URL(fileURLWithPath: '+JSON.stringify(path.join(base,'Resources/Icons'))+').appendingPathComponent(name + ".png")\n        guard let image');
source=source.replace('return url.scheme == "https" && url.host == "weread.qq.com" && url.path.hasPrefix("/web/reader/")','return url.isFileURL || (url.scheme == "https" && url.host == "weread.qq.com" && url.path.hasPrefix("/web/reader/"))');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let prefs=UserDefaults(suiteName:"local.floatingreader.quit-raw-progress-tests")!
prefs.removePersistentDomain(forName:"local.floatingreader.quit-raw-progress-tests")
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
 assert(d.storedBookmark()!.text.isEmpty && abs(d.storedBookmark()!.sourceY-600)<2)
 print("原网页模式实际关闭：保存当前网页位置并退出检查通过")
 prefs.removePersistentDomain(forName:"local.floatingreader.quit-raw-progress-tests")
}
let deadline=Date().addingTimeInterval(15)
let timer=Timer(timeInterval:0.2,repeats:true){_ in
 if Date()>deadline {print("quit timeout");exit(2)}
 if !closing {
  d.web.evaluateJavaScript("window.floatingReaderChapterSnapshot?.().ready"){ready,_ in
   if ready as? Bool == true && !closing {
    closing=true
    d.web.evaluateJavaScript("window.floatingReaderSetReadingPosition({recognized:true,y:600})"){_,_ in
     app.delegate=d
     d.window.performClose(nil)
    }
   }
  }
 }
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync('/tmp/ReaderQuitRawProgressIntegration.swift',source);
