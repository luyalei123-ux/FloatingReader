const delayed=process.argv.includes('--delayed');
const fs=require('fs');const path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'));
source=source.replace('        home()\n        dragMonitor','        dragMonitor').replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','').replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()').replaceAll('web.url?.host == "weread.qq.com"','(web.url?.host == "weread.qq.com" || web.url?.isFileURL == true)');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
let script=try! String(contentsOfFile:"${base}/Resources/reader.js",encoding:.utf8)
d.web.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
d.web.loadFileURL(URL(fileURLWithPath:"${base}/Tests/fixtures/reader/${delayed?"delayed-seam":"seam"}.html"),allowingReadAccessTo:URL(fileURLWithPath:"${base}/Tests/fixtures"))
var started=false,checking=false
let deadline=Date().addingTimeInterval(60)
let timer=Timer(timeInterval:0.2,repeats:true){_ in
 if Date()>deadline{print("prefetch timeout",d.status.stringValue);exit(2)}
 if !started {
  d.web.evaluateJavaScript("typeof window.floatingReaderChapterSnapshot === 'function' && window.floatingReaderChapterSnapshot().ready"){value,_ in
   if value as? Bool == true && !started{started=true;d.prepareText()}
  }
 } else if !d.preparingText && d.textWasRecognized && d.text.string.contains(${delayed?'"FINAL COMPLETE SENTENCE"':'"BOUNDARY"'}) && !checking {
  checking=true
  assert(d.text.string.contains("BOUNDARY RECOVERED SENTENCE"),"边界完整行没有恢复")
  assert(d.text.string.components(separatedBy:"BOUNDARY").count == 2,"边界行重复")
  print("真实两屏 OCR：边缘残行由下一屏完整恢复且不重复检查通过")
  exit(0)
 }
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync(delayed?'/tmp/ReaderDelayedSeamIntegration.swift':'/tmp/ReaderSeamIntegration.swift',source);
