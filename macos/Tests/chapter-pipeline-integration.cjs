const fs=require('fs'),path=require('path'),base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'));
const canvas=process.argv.includes('--canvas');
const dead=process.argv.includes('--dead-source');
const pending=process.argv.includes('--pending');
const folder='/tmp/floatingreader-pipeline/reader';fs.mkdirSync(folder,{recursive:true});
const files=[1,2,3].map(i=>folder+'/123456789012345678901k'+i+'.html');
files.forEach((file,i)=>fs.writeFileSync(file,'<meta charset="utf-8"><style>.readerChapterContent{font-size:18px}</style><div class="readerChapterContent"><h1>第'+(i+1)+'章</h1>'+(('这是第'+(i+1)+'章独有的正文，用于检查缓存交接和自动续读。').repeat(100))+'</div>'+(i<2?'<a class="readerFooter_button" href="'+files[i+1]+'">下一章</a>':'')));
if(canvas)for(let i=1;i<3;i++)fs.writeFileSync(files[i],'<meta charset="utf-8"><style>body{margin:0}.readerChapterContent{width:1100px;height:9000px}</style><div class="readerChapterContent"><canvas width="1100" height="9000"></canvas></div>'+(i<2?'<a class="readerFooter_button" href="'+files[i+1]+'">下一章</a>':'')+'<script>let c=document.querySelector("canvas").getContext("2d");c.fillStyle="white";c.fillRect(0,0,1100,9000);c.fillStyle="black";c.font="28px sans-serif";for(let row=0;row<175;row++)c.fillText("第"+row+"行，当前第'+(i+1)+'章固定大页面正文，预读接手后继续补充，并保持行序。",30,70+row*48)</script>');
source=source.replace('        home()\n        dragMonitor','        dragMonitor').replace('        window.makeKeyAndOrderFront(nil)\n        NSApp.activate(ignoringOtherApps: true)','')
.replaceAll('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()')
.replace('let defaults = UserDefaults.standard','let defaults = UserDefaults(suiteName:"local.floatingreader.pipeline-tests")!')
.replaceAll('Bundle.main.url(forResource: "reader", withExtension: "js")','Optional(URL(fileURLWithPath:'+JSON.stringify(base+'/Resources/reader.js')+'))')
.replace('view.load(URLRequest(url: URL(string: owner)!))','view.loadFileURL(URL(string:owner)!,allowingReadAccessTo:URL(fileURLWithPath:"/tmp/floatingreader-pipeline"))')
.replace('target.host == "weread.qq.com"','target.isFileURL')
.replace('return url.scheme == "https" && url.host == "weread.qq.com" && url.path.hasPrefix("/web/reader/")','return url.isFileURL && url.path.contains("/reader/")')
.replace('guard web.url?.host == "weread.qq.com",','guard web.url?.isFileURL == true,');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let prefs=UserDefaults(suiteName:"local.floatingreader.pipeline-tests")!;prefs.removePersistentDomain(forName:"local.floatingreader.pipeline-tests")
let d=ReaderDelegate();d.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
d.web.loadFileURL(URL(fileURLWithPath:${JSON.stringify(files[0])}),allowingReadAccessTo:URL(fileURLWithPath:"/tmp/floatingreader-pipeline"))
var stage=0;var checks=0;var adoptedView:WKWebView?
var pendingText=""
let began=Date();var idleUntil=Date.distantFuture
let timer=Timer(timeInterval:0.1,repeats:true){_ in
 if Date().timeIntervalSince(began)>${canvas?120:50}{print("流水线测试超时",stage,d.status.stringValue);exit(2)}
 if stage==0 && !d.web.isLoading && d.web.url?.path.hasSuffix("k1.html")==true {
  stage=1;d.prepareText()
 } else if stage==1 && d.nextChapterCache != nil && !d.preparingText {
  assert(d.nextChapterCache!.contains("第2章"));assert(d.text.string.contains("第1章"))
  adoptedView=d.nextLoader!.view
  let size=d.window.frame.size
  d.readingAnchors.append(ReadingAnchor(offset:100,sourceY:500,url:d.web.url!.absoluteString))
  let ready=Date();d.nextChapter()
  assert(Date().timeIntervalSince(ready)<0.5)
  assert(d.web === adoptedView && d.web.url!.path.hasSuffix("k2.html"),"没有接手已加载的后台页")
  assert(d.text.string.contains("第2章") && !d.text.string.contains("第1章"))
  assert(d.window.frame.size==size)
  assert(d.readingAnchors.allSatisfy{$0.url==d.web.url!.absoluteString},"替换章节后保留了旧章进度锚点")
  stage=2
 } else if stage==2 && (${pending} || d.nextChapterCache?.contains("第3章")==true) && d.sourceAtEnd && !d.preparingText {
  assert(d.web === adoptedView && d.web.url!.path.hasSuffix("k2.html"))
  if ${pending} {
   pendingText=d.text.string
   let maximum=max(0,d.text.frame.height-d.scroll.contentSize.height)
   d.scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,maximum-40)))
   d.scroll.reflectScrolledClipView(d.scroll.contentView)
   let event=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:-20,wheel2:0,wheel3:0)!)!
   d.scroll.scrollWheel(with:event)
   assert(d.pendingNextAdvance == true && d.web.url!.path.hasSuffix("k2.html"))
   assert(d.text.string == pendingText)
   stage=6;return
  }
  idleUntil=Date().addingTimeInterval(1);stage=3
 } else if stage==3 && Date()>idleUntil {
  d.maintainNextPreload()
  assert(d.nextChapterCache?.contains("第3章")==true,"闲置检查丢弃了有效缓存")
  d.nextChapterCache=nil;d.nextLoader?.cancel();d.nextLoader=nil
  d.prefetchOwner=d.web.url!.absoluteString;d.preloadRetryAfter = .distantPast
  d.maintainNextPreload()
  assert(d.nextLoader?.completion != nil,"闲置检查没有重启停住的预读")
  stage=4
 } else if stage==4 && d.nextChapterCache?.contains("第3章")==true {
  let second=d.text.string, incoming=d.nextChapterCache!
  if ${dead} { d.nextLoader!.sourceUsable=false }
  let maximum=max(0,d.text.frame.height-d.scroll.contentSize.height)
  d.scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,maximum-40)))
  d.scroll.reflectScrolledClipView(d.scroll.contentView)
  let event=NSEvent(cgEvent:CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:-20,wheel2:0,wheel3:0)!)!
  d.scroll.scrollWheel(with:event)
  if !${dead} { assert(d.web.url!.path.hasSuffix("k3.html"),"第一次滚动到底未自动接续") }
  assert(d.text.string.hasPrefix(second) && d.text.string.contains("第3章"))
  assert(d.text.string == second+"\\n\\n"+incoming,"续读出现章节重复或缺失")
  if ${dead} {stage=5;return}
  prefs.removePersistentDomain(forName:"local.floatingreader.pipeline-tests")
  print("第1章→缓存第2章→自动预读第3章→闲置保留→滚动到底自动接续检查通过")
  exit(0)
 } else if stage==6 && d.web.url?.path.hasSuffix("k3.html")==true {
  assert(d.pendingNextAdvance == nil && d.text.string.hasPrefix(pendingText) && d.text.string.contains("第3章"))
  assert(d.text.string.components(separatedBy:"第3章独有").count==101)
  prefs.removePersistentDomain(forName:"local.floatingreader.pipeline-tests")
  print("滚到底时缓存尚未就绪，完成后自动接续且无需再次点击检查通过")
  exit(0)
 } else if stage==5 && d.cachedSourceResume == nil && !d.web.isLoading && d.web.url?.path.hasSuffix("k3.html")==true {
  assert(d.text.string.contains("第3章"))
  prefs.removePersistentDomain(forName:"local.floatingreader.pipeline-tests")
  print("闲置网页被回收时仍立即显示缓存，并恢复后台原网页检查通过")
  exit(0)
 }
}
RunLoop.main.add(timer,forMode:.common);app.run()
`;
fs.writeFileSync(pending?'/tmp/ReaderChapterPendingPipeline.swift':dead?'/tmp/ReaderChapterDeadPipeline.swift':canvas?'/tmp/ReaderChapterCanvasPipeline.swift':'/tmp/ReaderChapterPipelineIntegration.swift',source);
