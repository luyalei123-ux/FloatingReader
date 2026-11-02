// Windows-only chapter navigation. Uses only real links and DOM controls from the page.
(() => {
  const labelOf = n => (n?.innerText || n?.textContent || n?.getAttribute?.('aria-label') || '').replace(/\s+/g,' ').trim();
  const visible = n => n && n.isConnected !== false && !n.disabled && n.getAttribute?.('aria-disabled') !== 'true' && n.getClientRects().length;
  const readerURL = value => {try{const u=new URL(value,location.href);return u.protocol==='https:' && u.hostname==='weread.qq.com' && u.pathname.startsWith('/web/reader/') ? u.href : null;}catch{return null;}};
  const planFor = node => {
    if(!visible(node))return {kind:'missing'};
    const anchor=node.matches?.('a[href]') ? node : node.querySelector?.('a[href]');
    const href=anchor?.getAttribute('href');const url=href ? readerURL(href) : null;
    window.floatingWindowsChapterTarget=node;
    if(url && url!==location.href)return {kind:'url',url,label:labelOf(node)};
    node.scrollIntoView?.({block:'center',inline:'nearest'});
    const r=node.getBoundingClientRect();return {kind:'element',label:labelOf(node),x:r.left+r.width/2,y:r.top+r.height/2};
  };
  window.floatingWindowsChapterPlan = direction => {
    const match=/^catalog:(\d+)$/.exec(direction);
    if(match)return planFor(window.floatingReaderCatalogNodes?.[Number(match[1])]);
    const prev=direction==='previous';
    const selector=prev?'.readerChapterFooter_prev,.readerFooter_button_prev,[class*="prevChapter"],[class*="previousChapter"],[rel="prev"]':'.readerChapterFooter_next,.readerFooter_button_next,[class*="nextChapter"],[rel="next"]';
    const pattern=prev?/^(上一章|上一章节|前一章|上一页)/:/^(下一章|下一章节|后一章|下一页)/;
    const dedicated=Array.from(document.querySelectorAll(selector)).filter(visible);
    const labelled=Array.from(document.querySelectorAll('.readerFooter_button,.readerHeaderButton,button,a,[role="button"],[class*="readerFooter"],[class*="chapterFooter"]')).filter(n=>visible(n)&&[labelOf(n),n.getAttribute('title')||'',n.getAttribute('aria-label')||''].some(s=>s.length<160&&pattern.test(s.replace(/\s+/g,'').replace(/^[←→‹›«»<>〈〉《》]+/,''))));
    const nodes=Array.from(new Set([...dedicated,...labelled]));
    nodes.sort((a,b)=>Number(b.matches?.('.readerFooter_button,.readerHeaderButton,button,a,[role="button"]'))-Number(a.matches?.('.readerFooter_button,.readerHeaderButton,button,a,[role="button"]')));
    return planFor(nodes[0]);
  };
  window.floatingWindowsActivateChapter = () => {
    const node=window.floatingWindowsChapterTarget;if(!visible(node))return false;
    node.click();return true;
  };
  window.floatingWindowsOpenCatalog = () => {
    const button=Array.from(document.querySelectorAll('.readerControls_item.catalog,.rbb_item.catalog,[aria-label="目录"],[title="目录"]')).find(visible);
    if(!button)return false;button.click();return true;
  };
  window.floatingWindowsAdjacentCatalog = direction => {
    const rows=window.floatingReaderCatalogRows?.()||[];
    const title=((window.floatingReaderChapterSnapshot?.().identity||'').split('|').slice(1).join('|')).replace(/\s+/g,'');
    let current=rows.findIndex(r=>r.current);
    if(current<0)current=rows.findIndex(r=>{const node=window.floatingReaderCatalogNodes?.[r.index];return node?.getAttribute('aria-selected')==='true'||!!node?.querySelector('[aria-current="true"],[aria-selected="true"],.current,.selected,.active')||(title&&r.label.replace(/\s+/g,'')===title);});
    if(current<0)return {kind:'missing',reason:'目录未标记当前章节'};
    const next=current+(direction==='previous'?-1:1);
    if(next<0||next>=rows.length)return {kind:'missing',reason:'当前目录没有相邻章节'};
    return planFor(window.floatingReaderCatalogNodes?.[rows[next].index]);
  };
})();
