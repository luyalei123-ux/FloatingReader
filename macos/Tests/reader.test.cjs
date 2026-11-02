const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const script = fs.readFileSync(require('path').join(__dirname, '../Resources/reader.js'), 'utf8');
function page({button = true, changes = true, labelText = "下一章", lazy = false, decoy = false, labelOnly = false} = {}) {
  const style = {textContent:''};
  let chapter = '第一章', selected='';
  const control = {disabled:false, getClientRects:()=>[{}], scrollIntoView(){}, getBoundingClientRect:()=>({left:0,top:0,width:60,height:30}), getAttribute:()=>null, click:()=>{if(changes) chapter='第二章'}, textContent:labelText};
  const scroller={scrollTop:0,scrollHeight:5000,clientHeight:1000};
  const disabled={...control,disabled:true};
  const document = {
    head:{appendChild(){}}, documentElement:scroller, scrollingElement:scroller, createElement:()=>style,
    querySelector: selector => selector.includes('aria-busy') ? null : selector.includes('Title') ? {textContent:chapter} : {innerText:chapter + '正文'.repeat(50)},
    querySelectorAll: selector => {
      if(labelOnly && selector.includes('readerChapterFooter_')) return [];
      if(selector.includes('readerFooter_button')) {if(selector.includes('readerChapterFooter_')) selected=selector;return button && (!lazy || scroller.scrollTop === 4000) ? (decoy ? [disabled, control] : [control]) : []}
      return [];
    }
  };
  const context = {document,getComputedStyle:()=>({overflowY:'visible'}),window:{},location:{href:'https://weread.qq.com/web/reader/test',pathname:'/web/reader/test'},MutationObserver:class{observe(){}},setTimeout:fn=>fn(),requestAnimationFrame:fn=>fn()};
  vm.runInNewContext(script,context);
  return {api:context.window,style,nativeComplete:()=>{chapter="第二章"},selector:()=>selected};
}
(async()=>{
  let p=page();
  p.api.floatingReaderBeginCapture();
  const acknowledged=p.api.floatingReaderCaptureState();
  assert.equal(p.api.floatingReaderAdvancePage(true),'moved');
  assert.deepEqual(p.api.floatingReaderPendingCaptureState,{start:acknowledged.start,end:acknowledged.end,current:acknowledged.current});
  p.api.floatingReaderRestoreCaptureState(p.api.floatingReaderPendingCaptureState);
  assert.deepEqual(p.api.floatingReaderCaptureState(),acknowledged);
  p=page();
  p.api.floatingReaderBeginCapture();
  assert.equal(p.api.floatingReaderAdvancePage(true,450),'moved');
  assert.equal(p.api.floatingReaderCaptureState().current,350);
  assert(p.api.floatingReaderCaptureState().current<450,'Partially painted viewport skipped unread region');
  p=page();
  assert.equal(await p.api.floatingReaderChangeChapter('next'),'changed');
  assert(p.selector().includes('readerChapterFooter_next'));
  p=page();
  assert.equal(await p.api.floatingReaderChangeChapter('previous'),'changed');
  assert(p.selector().includes('readerChapterFooter_prev'));
  p=page({button:false});
  assert((await p.api.floatingReaderChangeChapter('next')).includes('未找到可用'));
  p=page({lazy:true,labelText:'下一章第二节',decoy:true});
  assert.equal(await p.api.floatingReaderChangeChapter('next'),'changed');
  for (const [text,direction] of [['<下一页>','next'],['下一页>','next'],['<上一页','previous']]) {
    const front=page({labelText:text,labelOnly:true,lazy:direction === 'next'});
    assert.equal(await front.api.floatingReaderChangeChapter(direction),'changed');
  }
  console.log('版权页上一页／下一页文字入口检查通过');
  console.log('延迟挂载章节入口、禁用按钮优先级、紧接章节标题检查通过');
  p=page({changes:false});
  assert((await p.api.floatingReaderChangeChapter('next')).includes('未确认'));
  p=page();
  p.api.floatingReaderApply({color:'#222222',opacity:0.4});
  assert(p.style.textContent.includes('background-color: transparent'));
  assert(!p.style.textContent.includes('body *'));
  p.api.floatingReaderApply({background:'#345678',color:'#ffffff',opacity:1});
  assert(p.style.textContent.includes('background-color: #345678'));
  p.api.floatingReaderApply({original:true});
  assert.equal(p.style.textContent,'');
  console.log('章节前进、后退、缺失入口、加载未完成及透明样式恢复检查通过');
})();
// Continuation must follow the captured range, not the current viewport cursor.
{
  const scroller = {scrollTop:200,scrollHeight:2000,clientHeight:500};
  const context = {
    document: {head:{appendChild(){}},documentElement:scroller,scrollingElement:scroller,createElement:()=>({textContent:''}),querySelector:()=>null,querySelectorAll:()=>[]},
    window:{},location:{href:'https://weread.qq.com/web/reader/test',pathname:'/web/reader/test'},
    MutationObserver:class{observe(){}},getComputedStyle:()=>({overflowY:'visible'})
  };
  vm.runInNewContext(script,context);
  context.window.floatingReaderBeginCapture();
  assert.equal(context.window.floatingReaderAdvancePage(true),'moved');
  assert.equal(scroller.scrollTop,600);
  assert.equal(context.window.floatingReaderAdvancePage(false),'moved');
  assert.equal(scroller.scrollTop,0);
  assert.equal(context.window.floatingReaderAdvancePage(false),'boundary');
  assert.equal(context.window.floatingReaderAdvancePage(true),'moved');
  assert.equal(scroller.scrollTop,1000);
  context.window.floatingReaderAdvancePage(true);
  context.window.floatingReaderAdvancePage(true);
  assert.equal(context.window.floatingReaderAdvancePage(true),'boundary');
  console.log('正文向前、向后接续及章节边界检查通过');
}
// A slow canvas chapter can change while URL/title/innerText all stay constant.
(async () => {
  let ticks=0, clicked=false, paint=20;
  const canvas={width:8,height:8,getContext:()=>({getImageData:()=>{
    const data=new Uint8ClampedArray(256);
    data[3]=255; data[16]=paint; data[19]=255;
    return {data};
  }})};
  const content={innerText:'',querySelectorAll:()=>[canvas]};
  const button={disabled:false,getClientRects:()=>[{}],getAttribute:()=>null,click:()=>{clicked=true}};
  const document={
    head:{appendChild(){}},documentElement:{},createElement:()=>({textContent:'',getContext:()=>({drawImage(){},getImageData:()=>canvas.getContext().getImageData()})}),
    querySelector:selector=>selector.includes('aria-busy') ? (ticks<73 ? {getClientRects:()=>[{}]} : null) : selector.includes('Title') ? {textContent:'固定标题'} : content,
    querySelectorAll:selector=>selector.includes('readerFooter_button') ? [button] : []
  };
  const context={document,window:{},location:{href:'https://weread.qq.com/web/reader/test',pathname:'/web/reader/test'},MutationObserver:class{observe(){}},setTimeout:fn=>{ticks++;if(clicked && ticks>=70)paint=42;fn()},requestAnimationFrame:fn=>fn()};
  vm.runInNewContext(script,context);
  assert.equal(await context.window.floatingReaderChangeChapter('next'),'changed');
  assert(ticks>=76 && ticks<120);
  assert(context.window.floatingReaderChapterProgress.changed);
  console.log('固定网址与标题的画布切章、慢加载、绘制稳定检查通过');
})();
// Reproduce the user's DOM: a non-interactive readerFooter wraps readerFooter_button.
async function nestedFooter(source) {
  let chapter='第一章', parentClicks=0, childClicks=0;
  const child={className:'readerFooter_button floating-chapter-link',textContent:'下一章',disabled:false,getClientRects:()=>[{}],getAttribute:()=>null,matches:s=>s.includes('.readerFooter_button'),contains:()=>false,click:()=>{childClicks++;chapter='第二章'}};
  const parent={className:'readerFooter',textContent:'下一章',disabled:false,getClientRects:()=>[{}],getAttribute:()=>null,matches:()=>false,contains:n=>n===child,click:()=>{parentClicks++}};
  const document={head:{appendChild(){}},documentElement:{},createElement:()=>({textContent:''}),querySelector:s=>s.includes('aria-busy')?null:s.includes('Title')?{textContent:chapter}:{innerText:chapter+'正文'.repeat(50)},querySelectorAll:s=>s.includes('[class*="nextChapter"]')?[]:s.includes('[class*="readerFooter"]')?[parent,child]:[]};
  const context={document,window:{},location:{href:'https://weread.qq.com/web/reader/test',pathname:'/web/reader/test'},MutationObserver:class{observe(){}},setTimeout:fn=>fn(),requestAnimationFrame:fn=>fn()};
  vm.runInNewContext(source,context);
  const result=await context.window.floatingReaderChangeChapter('next');
  return {result,parentClicks,childClicks,progress:context.window.floatingReaderChapterProgress};
}
(async()=>{
  const oldPath=require('path').join(__dirname,'../dist/0.6/浮读.app/Contents/Resources/reader.js');
  if(fs.existsSync(oldPath)){
    const old=await nestedFooter(fs.readFileSync(oldPath,'utf8'));
    assert(old.result.includes('未确认'));
    assert.equal(old.parentClicks,1);assert.equal(old.childClicks,0);
    console.log('已复现 0.6 点击外层容器造成切章超时');
  }
  const fixed=await nestedFooter(script);
  assert.equal(fixed.result,'changed');
  assert.equal(fixed.parentClicks,0);assert.equal(fixed.childClicks,1);
  assert(fixed.progress.clickedClass.includes('readerFooter_button'));
  console.log('真实父子按钮结构的修复回归检查通过');
})();
// Moving the website to the visible reading position must not reset the preload range.
{
 const scroller={scrollTop:200,scrollHeight:6000,clientHeight:1000};
 const context={document:{head:{appendChild(){}},documentElement:scroller,scrollingElement:scroller,createElement:()=>({textContent:''}),querySelector:()=>null,querySelectorAll:()=>[]},window:{},location:{href:'https://weread.qq.com/web/reader/test',pathname:'/web/reader/test'},MutationObserver:class{observe(){}},getComputedStyle:()=>({overflowY:'visible'})};
 vm.runInNewContext(script,context);
 context.window.floatingReaderBeginCapture();
 context.window.floatingReaderAdvancePage(true);
 const end=context.window.floatingReaderCaptureState().end;
 context.window.floatingReaderSetReadingPosition({recognized:true,y:300});
 assert.equal(scroller.scrollTop,300);
 assert.equal(context.window.floatingReaderCaptureState().end,end);
 context.window.floatingReaderRestoreKnownRange({top:40,bottom:3900,current:600});
 assert.equal(scroller.scrollTop,600);
 assert.equal(context.window.floatingReaderCaptureState().end,2940);
 console.log('网页阅读位置与预读范围分离、恢复已读取区域检查通过');
}
// An offscreen native hit-test failure can activate the same live DOM button.
(async()=>{
 let chapter='第一章', clicks=0;
 const button={className:'readerFooter_button',textContent:'下一章',isConnected:true,disabled:false,getClientRects:()=>[{}],getAttribute:()=>null,matches:()=>true,scrollIntoView(){},getBoundingClientRect:()=>({left:10,top:20,width:80,height:30}),click(){clicks++;chapter='第二章'}};
 const document={head:{appendChild(){}},documentElement:{},createElement:()=>({textContent:''}),elementFromPoint:()=>button,querySelector:s=>s.includes('aria-busy')?null:s.includes('Title')?{textContent:chapter}:{innerText:chapter+'正文'.repeat(50)},querySelectorAll:s=>s.includes('readerFooter')?[button]:[]};
 const context={URL,document,window:{floatingReaderUseNativeClick:true},location:{href:'https://weread.qq.com/web/reader/test',pathname:'/web/reader/test'},MutationObserver:class{observe(){}},setTimeout:fn=>fn(),requestAnimationFrame:fn=>fn()};
 vm.runInNewContext(script,context);
 const pending=context.window.floatingReaderChangeChapter('next');
 for(let i=0;i<10 && !context.window.floatingReaderNativeClickRequest;i++)await Promise.resolve();
 assert(context.window.floatingReaderNativeClickRequest);
 context.window.floatingReaderNativeClickFallback();context.window.floatingReaderNativeClickContinue();
 assert.equal(await pending,'changed');assert.equal(clicks,1);
 console.log('原生点击失败后的网页按钮回退检查通过');
})().catch(error=>{console.error(error);process.exitCode=1});

(async()=>{
 const p=page({changes:false});p.api.floatingReaderAllowNativeFallback=true;
 const pending=p.api.floatingReaderChangeChapter('next');
 for(let i=0;i<30 && !p.api.floatingReaderNativeClickRequest;i++)await Promise.resolve();
 assert(p.api.floatingReaderNativeClickRequest);
 p.nativeComplete();p.api.floatingReaderNativeClickContinue();
 assert.equal(await pending,'changed');
 console.log('网页点击优先、原生点击备用检查通过');
})().catch(error=>{console.error(error);process.exitCode=1});
