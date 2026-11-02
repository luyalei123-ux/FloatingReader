const fs=require('fs');const path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'));
source=source.replace('        home()\n        dragMonitor','        dragMonitor').replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','').replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
let script=try! String(contentsOfFile:"${base}/Resources/reader.js",encoding:.utf8)
d.web.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
d.mountSource(offscreen:true)
d.web.loadFileURL(URL(fileURLWithPath:"${base}/Tests/fixtures/reader/prefetch.html"),allowingReadAccessTo:URL(fileURLWithPath:"${base}/Tests/fixtures"))
var stage=0,busy=false
let deadline=Date().addingTimeInterval(20)
let timer=Timer(timeInterval:0.2,repeats:true){_ in
 if Date()>deadline{print("catalog timeout",d.status.stringValue);exit(2)}
 if busy{return}
 busy=true
 if stage==0 {
  d.web.evaluateJavaScript("window.floatingReaderCatalogButton?.()"){value,_ in
   busy=false
   if let rect=value as? [String:Double],let x=rect["x"],let y=rect["y"],d.nativeClickSource(x:x,y:y){stage=1}
  }
 } else if stage==1 {
  d.web.evaluateJavaScript("window.floatingReaderCatalogRows?.()"){value,_ in
   busy=false
   if let rows=value as? [[String:Any]],rows.count==3 {
    assert(rows[2]["label"] as? String == "第3章")
    stage=2
    d.changeChapter("catalog:2",internalMove:true,onMoved:{
     d.web.evaluateJavaScript("window.currentChapter"){value,_ in
      assert(value as? Int == 3)
      print("网页目录读取、章节索引选择、原生跳章端到端检查通过")
      exit(0)
     }
    })
   }
  }
 } else {busy=false}
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync('/tmp/ReaderCatalogIntegration.swift',source);
