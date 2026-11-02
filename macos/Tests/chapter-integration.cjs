const fs=require('fs');const path=require('path');const base=path.resolve(__dirname,'..');let s=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');s=s.slice(0,s.lastIndexOf('let app = NSApplication.shared')).replace('        home()\n        dragMonitor','        dragMonitor').replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','').replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()');
s+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
let script=try! String(contentsOfFile:"${base}/Resources/reader.js",encoding:.utf8)
d.web.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
d.mountSource(offscreen:true)
d.web.loadFileURL(URL(fileURLWithPath:"${base}/Tests/fixtures/reader/chapter.html"),allowingReadAccessTo:URL(fileURLWithPath:"${base}/Tests/fixtures"))
var started=false, checking=false
let timeout=Date().addingTimeInterval(15)
let timer=Timer(timeInterval:0.2,repeats:true){ t in
 if Date()>timeout{print("integration timeout",d.status.stringValue);exit(2)}
 if !started {
  d.web.evaluateJavaScript("typeof window.floatingReaderChapterSnapshot === 'function' && window.floatingReaderChapterSnapshot().ready") {value,_ in
   if value as? Bool == true && !started{started=true;d.changeChapter("next")}
  }
 } else if !d.changingChapter && !checking {
  checking=true
  d.web.evaluateJavaScript("({trusted:window.actualTrust,changed:window.floatingReaderChapterResult,progress:window.floatingReaderChapterProgress})"){value,error in
   guard let result=value as? [String:Any],result["trusted"] as? Bool == true,result["changed"] as? String == "changed" else{print("integration failed",value as Any,error as Any);exit(1)}
   print("WebKit 原生切章 + 下半页画布更新 + 加载确认端到端检查通过")
   exit(0)
  }
 }
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync('/tmp/ReaderChapterIntegration.swift',s);
