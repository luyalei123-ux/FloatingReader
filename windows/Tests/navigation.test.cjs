const fs=require('fs'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(require('path').join(__dirname,'../Resources/navigation.js'),'utf8');let checks=0;
function node(text,{href,disabled=false,tag='div',cls='readerFooter_button',child=null,selected=false,connected=true}={}){
 return {textContent:text,innerText:text,isConnected:connected,disabled,tag,cls,child,clicked:0,getAttribute(k){return k==='href'?href:k==='aria-selected'&&selected?'true':null;},getClientRects(){return connected?[{}]:[];},getBoundingClientRect(){return {left:10,top:200,width:100,height:40}},scrollIntoView(){},click(){this.clicked++},querySelector(s){return s==='a[href]'?child:selected?{}:null;},matches(s){return s.split(',').some(t=>{t=t.trim();if(t==='a[href]')return tag==='a'&&!!href;if(t==='a'||t==='button')return tag===t;if(t==='[role="button"]')return false;if(t.startsWith('.'))return cls.split(' ').includes(t.slice(1));return false;});}};
}
function setup(nodes=[],rows=[],catalog=[]){const context={URL,location:{href:'https://weread.qq.com/web/reader/abc123k111'},window:{},document:{querySelectorAll(s){if(s.includes('prevChapter')||s.includes('nextChapter'))return nodes.filter(n=>n.cls.includes(s.includes('prevChapter')?'prevChapter':'nextChapter'));if(s.includes('.catalog'))return [];return nodes;}}};context.window.floatingReaderCatalogRows=()=>rows;context.window.floatingReaderCatalogNodes=catalog;context.window.floatingReaderChapterSnapshot=()=>({identity:'https://weread.qq.com/web/reader/abc123k111|本章'});vm.createContext(context);vm.runInContext(source,context);return context.window;}
function check(value){assert(value);checks++}
let n=node('下一章',{tag:'a',href:'/web/reader/abc123k222'}),w=setup([n]);check(w.floatingWindowsChapterPlan('next').kind==='url');check(w.floatingWindowsChapterPlan('next').url.endsWith('k222'));
n=node('下一章',{tag:'a',href:'https://weread.qq.com.evil.invalid/web/reader/abc123k222'});w=setup([n]);check(w.floatingWindowsChapterPlan('next').kind==='element');
n=node('下一章');w=setup([n]);check(w.floatingWindowsChapterPlan('next').kind==='element');check(w.floatingWindowsActivateChapter()===true&&n.clicked===1);
w=setup([node('下一章',{disabled:true})]);check(w.floatingWindowsChapterPlan('next').kind==='missing');
w=setup([node('下一章',{connected:false})]);check(w.floatingWindowsChapterPlan('next').kind==='missing');
const first=node('本章'),second=node('下一章',{tag:'a',href:'/web/reader/abc123k222'});w=setup([], [{index:0,label:'本章',current:true},{index:1,label:'第二章',current:false}],[first,second]);check(w.floatingWindowsAdjacentCatalog('next').url.endsWith('k222'));
w=setup([], [{index:0,label:'其他章',current:false}],[first]);check(w.floatingWindowsAdjacentCatalog('next').kind==='missing');
w=setup([], [],[second]);check(w.floatingWindowsChapterPlan('catalog:0').url.endsWith('k222'));
for(const label of ['下一页','下一页>','→下一章']){w=setup([node(label)]);check(w.floatingWindowsChapterPlan('next').kind==='element');}
for(const label of ['<上一页','←上一章']){w=setup([node(label)]);check(w.floatingWindowsChapterPlan('previous').kind==='element');}
console.log(`Windows chapter navigation: ${checks} checks passed (real links, host validation, DOM activation, disabled/stale buttons, adjacent catalog).`);
