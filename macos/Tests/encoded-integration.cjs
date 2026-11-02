const fs=require('fs');const path=require('path');const base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'));
source=source.replace('        home()\n        dragMonitor','        dragMonitor').replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','').replace('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()').replaceAll('web.url?.host == "weread.qq.com"','(web.url?.host == "weread.qq.com" || web.url?.isFileURL == true)');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
let script=try! String(contentsOfFile:"${base}/Resources/reader.js",encoding:.utf8)
d.web.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
d.web.loadFileURL(URL(fileURLWithPath:"${base}/Tests/fixtures/reader/encoded.html"),allowingReadAccessTo:URL(fileURLWithPath:"${base}/Tests/fixtures"))
var started=false,checking=false
let deadline=Date().addingTimeInterval(25)
let timer=Timer(timeInterval:0.2,repeats:true){_ in
 if Date()>deadline{print("prefetch timeout",d.status.stringValue);exit(2)}
 if !started {
  d.web.evaluateJavaScript("typeof window.floatingReaderChapterSnapshot === 'function' && window.floatingReaderChapterSnapshot().ready"){value,_ in
   if value as? Bool == true && !started{started=true;d.prepareText()}
  }
 } else if !d.preparingText && d.textWasRecognized && !checking {
  checking=true
  assert(!d.text.string.contains("CORRUPTED"),"提取了隐藏的错误原文")
  assert(d.text.string.contains("VISIBLE"),"没有读取实际渲染内容")
  print("画布隐藏错误原文不进入正文、实际渲染内容 OCR 检查通过")
  exit(0)
 }
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync('/tmp/ReaderEncodedIntegration.swift',source);
