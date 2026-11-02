const fs=require('fs'),path=require('path'),base=path.resolve(__dirname,'..');
let source=fs.readFileSync(path.join(base,'Sources/main.swift'),'utf8');source=source.slice(0,source.lastIndexOf('let app = NSApplication.shared'));
const sameURL=process.argv.includes('--same-url');
const batch=process.argv.includes('--batch');
const plain=process.argv.includes('--plain');
const custom=process.argv.includes('--custom-font');
const folder='/tmp/floatingreader-loader/reader',first=folder+'/123456789012345678901-first.html',next=folder+'/123456789012345678901-next.html';fs.mkdirSync(folder,{recursive:true});
fs.writeFileSync(first,'<meta charset="utf-8"><div class="readerChapterContent">'+('第一章正文保持原样。'.repeat(100))+'</div><a class="readerFooter_button" href="'+next+'">下一章</a>');
fs.writeFileSync(next,'<meta charset="utf-8"><style>body{margin:0}.readerChapterContent{width:1100px;height:1800px}</style><div class="readerChapterContent"><canvas width="1100" height="1800"></canvas></div><script>let c=document.querySelector("canvas").getContext("2d");c.fillStyle="white";c.fillRect(0,0,1100,1800);c.fillStyle="black";c.font="28px sans-serif";for(let i=0;i<30;i++)c.fillText("第二章测试正文，这是独立后台加载的内容，不应覆盖当前章节。",30,70+i*48)</script>');
if(sameURL){
 fs.writeFileSync(first,'<meta charset="utf-8"><style>body{margin:0}.readerChapterContent{width:1100px;height:1700px}</style><div class="readerChapterContent"><canvas width="1100" height="1700"></canvas></div><button class="readerFooter_button" onclick="paint(2)">下一页</button><script>function paint(n){let c=document.querySelector("canvas").getContext("2d");c.fillStyle="white";c.fillRect(0,0,1100,1700);c.fillStyle="black";c.font="28px sans-serif";for(let i=0;i<28;i++)c.fillText((n===2?"第二章":"第一章")+"测试正文，这是独立后台加载的内容，不应覆盖当前章节。",30,70+i*48)}paint(1)</script>');
}
if(batch)fs.writeFileSync(next,'<meta charset="utf-8"><style>body{margin:0}.readerChapterContent{width:1100px;height:20000px}</style><div class="readerChapterContent"><canvas width="1100" height="20000"></canvas></div><script>let c=document.querySelector("canvas").getContext("2d");c.fillStyle="white";c.fillRect(0,0,1100,20000);c.fillStyle="black";c.font="28px sans-serif";for(let i=0;i<400;i++)c.fillText("第"+i+"行，第二章测试正文，这是后台大页面的连续文字，不应影响当前小窗口。",30,70+i*48)</script>');
if(plain)fs.writeFileSync(next,'<meta charset="utf-8"><div class="readerChapterContent">'+('第二章正文，安全的普通字体段落。'.repeat(800))+'</div>');
if(custom)fs.writeFileSync(next,'<meta charset="utf-8"><style>@font-face{font-family:PrefetchTest;src:local("Arial")}.readerChapterContent{font-family:PrefetchTest;font-size:20px}</style><div class="readerChapterContent">'+('第二章正文，使用自定义字体时应走图片识别。'.repeat(200))+'</div>');
source=source.replaceAll('config.websiteDataStore = .default()','config.websiteDataStore = .nonPersistent()')
.replaceAll('Bundle.main.url(forResource: "reader", withExtension: "js")','Optional(URL(fileURLWithPath:'+JSON.stringify(base+'/Resources/reader.js')+'))')
.replace('view.load(URLRequest(url: URL(string: owner)!))','view.loadFileURL(URL(string: owner)!, allowingReadAccessTo: URL(fileURLWithPath:"/tmp/floatingreader-loader"))')
.replace('target.host == "weread.qq.com"','target.isFileURL').replace('if Date() > deadline { finish(nil); return }','if Date() > deadline { print("timeout phase", phase,view.url?.absoluteString ?? "nil",signature.prefix(100)); finish(nil); return }');
source+=`
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let current=WKWebView(frame:NSRect(x:0,y:0,width:240,height:140))
let display=NSWindow(contentRect:NSRect(x:0,y:0,width:240,height:140),styleMask:[.borderless],backing:.buffered,defer:false)
display.contentView=current
var firstSize=0
let began=Date()
let original=URL(fileURLWithPath:${JSON.stringify(first)})
current.loadFileURL(original,allowingReadAccessTo:URL(fileURLWithPath:"/tmp/floatingreader-loader"))
var loader:NextChapterLoader?
loader=NextChapterLoader(owner:original.absoluteString){page in
 guard let page=page else{print("后台预读失败");exit(2)}
 assert(page.url==URL(fileURLWithPath:${JSON.stringify(sameURL?first:next)}).absoluteString)
 assert(page.text.contains("第二章"));assert(page.text.count>300)
 if page.recognized { assert(page.text.split(separator:"\\n").contains(where:{$0.count>70}),"预加载仍保留逐行硬换行，无法按展示窗口重新折行") }
 assert(current.url==original,"后台预读改变了当前阅读页")
 assert(page.bottom>page.top && page.capture["current"] != nil)
 assert(loader!.view.bounds.size == ReadingViewport.size)
 if ${plain} { assert(!page.recognized && page.text.count>10000) }
 if ${custom} { assert(page.recognized) }
 if ${batch} {
  if firstSize == 0 { firstSize=page.text.count;print("首批耗时",Date().timeIntervalSince(began),"字数",firstSize);display.setContentSize(NSSize(width:190,height:110));return }
  if loader!.pagesRead < NextChapterLoader.maximumPages && page.text.count < NextChapterLoader.maximumCharacters { return }
  assert(page.text.count>firstSize*4)
  assert((page.capture["current"] as? Double ?? 0)>2000)
  assert(current.bounds.size==NSSize(width:190,height:110))
 }
 print("独立后台网页切章、中文识别、缓存和当前页隔离检查通过",page.text.count,"总耗时",Date().timeIntervalSince(began))
 exit(0)
}
let watchdog=Timer.scheduledTimer(withTimeInterval:90,repeats:false){_ in print("预读测试超时");exit(2)}
app.run()
`;
fs.writeFileSync(custom?'/tmp/ReaderNextLoaderCustom.swift':plain?'/tmp/ReaderNextLoaderPlain.swift':batch?'/tmp/ReaderNextLoaderBatch.swift':sameURL?'/tmp/ReaderNextLoaderSameURL.swift':'/tmp/ReaderNextLoaderIntegration.swift',source);
