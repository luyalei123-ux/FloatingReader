const fs=require('fs');const path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'));
source=source.replace('        home()\n        dragMonitor','        dragMonitor').replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','').replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()').replaceAll('web.url?.host == "weread.qq.com"','(web.url?.host == "weread.qq.com" || web.url?.isFileURL == true)');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
let script=try! String(contentsOfFile:"${base}/Resources/reader.js",encoding:.utf8)
d.web.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
d.mountSource(offscreen:true)
d.web.loadFileURL(URL(fileURLWithPath:"${base}/Tests/fixtures/reader/progress.html"),allowingReadAccessTo:URL(fileURLWithPath:"${base}/Tests/fixtures"))
var started=false,checking=false
let deadline=Date().addingTimeInterval(20)
let timer=Timer(timeInterval:0.2,repeats:true){_ in
 if Date()>deadline {print("import timeout",d.status.stringValue);exit(2)}
 if !started {
  d.web.evaluateJavaScript("typeof window.floatingReaderChapterSnapshot === 'function' && window.floatingReaderChapterSnapshot().ready") {value,_ in
   if value as? Bool == true && !started {
    started=true
    d.web.evaluateJavaScript("window.floatingReaderSetReadingPosition({recognized:true,y:600})") {_,_ in d.prepareText()}
   }
  }
 } else if d.pure && !d.preparingText && !d.changingChapter && !checking {
  checking=true
  assert(d.text.string.contains("网页恢复阅读位置"))
  assert(d.scroll.contentView.bounds.minY>100,"网页已读到中间，纯文字却回到了章首")
  d.web.evaluateJavaScript("window.floatingReaderCaptureState().current") {value,_ in
   assert(abs((value as! Double)-600)<2)
   print("从网页中途位置生成纯文字并继续该位置的 WebKit 端到端检查通过")
   exit(0)
  }
 }
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync('/tmp/ReaderImportProgressIntegration.swift',source);
