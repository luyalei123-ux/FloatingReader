(() => {
  const style = document.createElement('style');
  style.id = 'floating-reader-style';
  document.head.appendChild(style);
  let options;
  let capturedRange;
  function readingScroller() {
    const content = document.querySelector('.readerChapterContent, .wr_readerChapterContent, .readerContent');
    let node = content;
    while (node && node !== document.body) {
      const css = getComputedStyle(node);
      if (node.clientHeight > 0 && node.scrollHeight > node.clientHeight + 2 && /(auto|scroll)/.test(css.overflowY)) return node;
      node = node.parentElement;
    }
    return document.scrollingElement || document.documentElement;
  }
  window.floatingReaderBeginCapture = () => {
    const node = readingScroller();
    capturedRange = { node, start: node.scrollTop, end: node.scrollTop };
    return true;
  };
  window.floatingReaderCaptureState = () => ({start:capturedRange?.start || 0,end:capturedRange?.end || 0,current:readingScroller().scrollTop, maximum:Math.max(0,readingScroller().scrollHeight-readingScroller().clientHeight)});
  window.floatingReaderSetReadingPosition = state => {
    const node = readingScroller();
    let target = Number(state.y) || 0;
    if (!state.recognized && state.snippet) {
      const content = document.querySelector('.readerChapterContent, .wr_readerChapterContent');
      if (content) {
        const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
        let text, found = false;
        while ((text = walker.nextNode())) {
          const index = text.textContent.indexOf(state.snippet);
          if (index < 0) continue;
          const range = document.createRange(); range.setStart(text,index); range.setEnd(text,Math.min(text.length,index + 1));
          const rect = range.getBoundingClientRect();
          target = node.scrollTop + rect.top - (node === document.scrollingElement ? 0 : node.getBoundingClientRect().top) - 24;
          found = true; break;
        }
        if (!found) target = (Number(state.ratio) || 0) * Math.max(0,node.scrollHeight-node.clientHeight);
      }
    }
    node.scrollTop = Math.max(0, Math.min(Math.max(0,node.scrollHeight-node.clientHeight), target));
    return {current:node.scrollTop,href:location.href};
  };
  window.floatingReaderRestoreKnownRange = state => {
    const node = readingScroller(), maximum = Math.max(0,node.scrollHeight-node.clientHeight);
    capturedRange = {node,start:Math.max(0,state.top - 40),end:Math.min(maximum,Math.max(0,state.bottom-node.clientHeight+40))};
    node.scrollTop = Math.min(maximum,Math.max(0,state.current));
  };
  window.floatingReaderRestoreCaptureState = state => {
    const node = readingScroller();
    capturedRange = {node,start:state.start,end:state.end};
    node.scrollTop = state.current;
  };
  window.floatingReaderCatalogRows = () => {
    const selectors = '.readerCatalog_list_item, .readerCatalogItem, [class*="chapterItem"], [class*="catalogItem"]';
    const nodes = Array.from(document.querySelectorAll(selectors)).filter(node => {
      const label=(node.innerText || node.textContent || '').trim();
      return label && label.length < 160 && node.getClientRects().length;
    });
    window.floatingReaderCatalogNodes = nodes.filter(node => !nodes.some(other => node !== other && node.contains(other)));
    return window.floatingReaderCatalogNodes.map((node,index)=>({index,label:(node.innerText || node.textContent || '').trim(),current:node.getAttribute('aria-current') === 'true' || /(^|[\s_-])(current|selected|active)([\s_-]|$)/i.test(node.className)}));
  };
  window.floatingReaderCatalogButton = () => {
    const button = Array.from(document.querySelectorAll('.readerControls_item.catalog, .rbb_item.catalog, [aria-label="目录"], [title="目录"]')).find(node=>node.getClientRects().length);
    if(!button) return null;
    button.scrollIntoView({block:'nearest'});
    const r=button.getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2};
  };
  window.floatingReaderCatalogCloseButton = () => {
    const node=document.querySelector('.readerCatalog_closeButton, .readerCatalog_close, .readerCatalog [aria-label="关闭"]');
    if(!node) return window.floatingReaderCatalogButton();
    const r=node.getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2};
  };
  window.floatingReaderStartChapter = () => { capturedRange=undefined; readingScroller().scrollTop=0; };
  window.floatingReaderAdvancePage = (forward = true, recognizedBoundary = null) => {
    if (!location.pathname.includes('reader')) return 'unavailable';
    if (!capturedRange) window.floatingReaderBeginCapture();
    const node = capturedRange.node;
    const anchor = forward ? capturedRange.end : capturedRange.start;
    const maximum = Math.max(0, node.scrollHeight - node.clientHeight);
    let target = anchor + (forward ? 1 : -1) * Math.max(1, node.clientHeight * .8);
    // A partially painted viewport must not acknowledge its blank lower region.
    // Keep the next image overlapping the last successfully recognized source row.
    if (forward && Number.isFinite(recognizedBoundary) && anchor < maximum - 2) {
      target = Math.min(target, Math.max(0, recognizedBoundary - Math.max(96,node.clientHeight * .1)));
    }
    const next = Math.max(0, Math.min(maximum, target));
    if (Math.abs(next - anchor) < 2) return forward && Number.isFinite(recognizedBoundary) && anchor < maximum - 2 ? 'unavailable' : 'boundary';
    window.floatingReaderPendingCaptureState = {start:capturedRange.start,end:capturedRange.end,current:node.scrollTop};
    node.scrollTop = next;
    if (Math.abs(node.scrollTop - anchor) < 2) return 'unavailable';
    if (forward) capturedRange.end = node.scrollTop; else capturedRange.start = node.scrollTop;
    return 'moved';
  };
  // Canvas text can change without changing URL, title, or innerText.
  const paintMethods = ['drawImage', 'fillText', 'strokeText', 'clearRect', 'fillRect'];
  if (typeof CanvasRenderingContext2D !== 'undefined') {
    for (const name of paintMethods) {
      const original = CanvasRenderingContext2D.prototype[name];
      if (!original || original.floatingReaderHook) continue;
      const hooked = function (...args) {
        const result = original.apply(this, args);
        this.canvas.floatingReaderPaintVersion = (this.canvas.floatingReaderPaintVersion || 0) + 1;
        return result;
      };
      hooked.floatingReaderHook = true;
      CanvasRenderingContext2D.prototype[name] = hooked;
    }
  }
  window.floatingReaderChapterSnapshot = () => {
    const title = document.querySelector('.readerChapterTitle, .readerChapterContent h1, .readerChapterContent h2');
    const content = document.querySelector('.readerChapterContent, .wr_readerChapterContent');
    const text = content ? (content.innerText || '').trim() : '';
    const canvases = content && content.querySelectorAll ? Array.from(content.querySelectorAll('canvas')).filter(c => c.width > 0 && c.height > 0).slice(0,12) : [];
    let readable = false;
    const pixels = canvases.map(canvas => {
      let hash = 2166136261, varied = false;
      try {
        const sampler = document.createElement('canvas');
        sampler.width = 128;
        sampler.height = 128;
        const context = sampler.getContext('2d');
        if (!context) throw new Error('No 2d context');
        context.drawImage(canvas, 0, 0, 128, 128);
        const data = context.getImageData(0, 0, 128, 128).data;
        for (let i = 0; i < data.length; i += 16) {
          if (data[i] !== data[0] || data[i+1] !== data[1] || data[i+2] !== data[2] || data[i+3] !== data[3]) varied = true;
          hash = Math.imul(hash ^ data[i] ^ (data[i+1]<<8) ^ (data[i+2]<<16) ^ data[i+3], 16777619);
        }
        readable = readable || varied;
      } catch (_) {
        readable = readable || (canvas.floatingReaderPaintVersion || 0) > 0;
      }
      return canvas.width + 'x' + canvas.height + ':' + hash + ':' + (canvas.floatingReaderPaintVersion || 0);
    });
    const busyNode = document.querySelector('[aria-busy="true"], .readerLoading, .readerContent_loading');
    const busy = !!busyNode && busyNode.getClientRects().length > 0;
    return {
      identity: location.href + '|' + (title ? title.textContent : ''),
      signature: location.href + '|' + (title ? title.textContent : '') + '|' + (canvases.length ? pixels.join('|') : text),
      ready: !busy && (canvases.length ? readable : text.length > 40),
      busy,
      canvasCount: canvases.length
    };
  };
  window.floatingReaderChangeChapter = async direction => {
    if (!location.pathname.includes('reader')) return '请先打开一本书。';
    const previous = direction === 'previous';
    const selector = previous ? '.readerChapterFooter_prev, .readerFooter_button_prev, [class*="prevChapter"], [class*="previousChapter"], [rel="prev"]' : '.readerChapterFooter_next, .readerFooter_button_next, [class*="nextChapter"], [rel="next"]';
    const label = previous ? /^(上一章节|上一章|前一章|上一页|前一页)/ : /^(下一章节|下一章|后一章|下一页|后一页)/;
    const catalogChoice = /^catalog:(\d+)$/.exec(direction);
    const findButton = () => {
      const dedicated = Array.from(document.querySelectorAll(selector));
      const labelled = Array.from(document.querySelectorAll('.readerFooter_button, .readerHeaderButton, button, a, [role="button"], .floating-chapter-link, [class*="readerFooter"], [class*="chapterFooter"]')).filter(node => {
        return ['aria-label', 'title'].map(key => node.getAttribute(key) || '').concat(node.textContent || '').some(value => {
          const text = value.replace(/\s+/g, '').replace(/^[<>＜＞←→‹›«»]+/, '');
          return text.length < 160 && label.test(text);
        });
      });
      const candidates = Array.from(new Set([...dedicated, ...labelled])).filter(node => node.getClientRects().length && !node.disabled && node.getAttribute('aria-disabled') !== 'true');
      const priority = node => {
        if (node.matches && node.matches('.readerFooter_button, .readerHeaderButton, .readerChapterFooter_prev, .readerChapterFooter_next')) return 30;
        if (node.matches && node.matches('button, a, [role="button"]')) return 20;
        return dedicated.includes(node) ? 10 : 0;
      };
      candidates.sort((a,b) => priority(b)-priority(a) || (a.contains && a.contains(b) ? 1 : b.contains && b.contains(a) ? -1 : 0));
      return candidates[0];
    };
    let button = catalogChoice ? window.floatingReaderCatalogNodes?.[Number(catalogChoice[1])] : findButton();
    // Some footers are only mounted after the source page actually reaches its edge.
    if (!button && !catalogChoice) {
      const node = readingScroller(), original = node.scrollTop;
      for (let attempt = 0; attempt < 8 && !button; attempt++) {
        node.scrollTop = previous ? 0 : Math.max(0, node.scrollHeight - node.clientHeight);
        await new Promise(resolve => setTimeout(resolve, 250));
        button = findButton();
      }
      if (!button) node.scrollTop = original;
    }
    if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') {
      window.floatingReaderChapterProgress = {missingEntry:true,direction,scroll:window.floatingReaderCaptureState(), candidates:Array.from(document.querySelectorAll('.readerFooter_button, .readerHeaderButton, button, a, [role="button"]')).map(node=>({label:(node.textContent||'').trim().slice(0,100),cls:node.className,disabled:!!node.disabled})).filter(node=>/章/.test(node.label)).slice(0,20)};
      return previous ? '未找到可用的上一章入口，可打开章节选择，从目录选择。' : '未找到可用的下一章入口，可打开章节选择，从目录选择；也可能已到全书末尾。';
    }
    const clicked = {clickedClass: typeof button.className === 'string' ? button.className : '', clickedLabel: (button.textContent || '').trim().slice(0,80)};
    window.floatingReaderChapterProgress = clicked;
    if (window.floatingReaderUseNativeClick) {
      button.scrollIntoView({block:'center', inline:'nearest'});
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    const before = window.floatingReaderChapterSnapshot();
    window.floatingReaderChapterBefore = before;
    capturedRange = undefined;
    const anchor = button.closest?.('a[href]') || button.querySelector?.('a[href]');
    const chapterHref = anchor?.getAttribute('href') || button.getAttribute('href');
    let targetURL;
    try { if (chapterHref) targetURL = new URL(chapterHref, location.href); } catch (_) {}
    if (targetURL && targetURL.hostname === 'weread.qq.com' && targetURL.pathname.startsWith('/web/reader/') && targetURL.pathname !== location.pathname) {
      location.assign(targetURL.href);
      return 'loading';
    }
    window.floatingReaderNativeClickFallback = () => { if (button.isConnected !== false) button.click(); };
    if (window.floatingReaderUseNativeClick) {
      const rect = button.getBoundingClientRect();
      const hit = document.elementFromPoint(rect.left + rect.width/2, rect.top + rect.height/2);
      clicked.hitClass = hit && typeof hit.className === 'string' ? hit.className : '';
      clicked.hitLabel = hit ? (hit.textContent || '').trim().slice(0,80) : '';
      window.floatingReaderNativeClickRequest = {x:rect.left + rect.width/2, y:rect.top + rect.height/2, baseline:before.signature};
      await new Promise(resolve => { window.floatingReaderNativeClickContinue = resolve; });
      // A native event can be accepted by AppKit yet ignored by an offscreen WebView.
      await new Promise(resolve => setTimeout(resolve, 2000));
      const afterClick = window.floatingReaderChapterSnapshot();
      if (!afterClick.busy && afterClick.signature === before.signature) window.floatingReaderNativeClickFallback?.();
    } else {
      button.click();
    }
    let last = before.signature, stable = 0;
    for (let count = 0; count < 120; count++) {
      await new Promise(resolve => setTimeout(resolve, 250));
      const now = window.floatingReaderChapterSnapshot();
      const changed = now.signature !== before.signature;
      if (count === 8 && !changed && !now.busy && !window.floatingReaderUseNativeClick && window.floatingReaderAllowNativeFallback) {
        button.scrollIntoView({block:'center', inline:'nearest'});
        await new Promise(resolve => setTimeout(resolve, 200));
        const rect = button.getBoundingClientRect();
        window.floatingReaderNativeClickRequest = {x:rect.left+rect.width/2,y:rect.top+rect.height/2,baseline:before.signature};
        await new Promise(resolve => {window.floatingReaderNativeClickContinue=resolve;});
      }
      if (changed && now.ready && now.signature === last) stable++; else stable = 0;
      last = now.signature;
      window.floatingReaderChapterProgress = {...clicked, ready: now.ready, busy: now.busy, changed, stable, canvasCount: now.canvasCount};
      if (stable >= 4) return 'changed';
    }
    return '已触发章节按钮，但未确认新章节加载完成。请检查网页正文，再切换纯文字。';
  };
  window.floatingReaderBlankAt = (x, y) => {
    const node = document.elementFromPoint(x, y);
    if (!node || node.closest('a, button, input, textarea, select, [role="button"], canvas, img, svg')) return false;
    const range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    if (range && range.startContainer.nodeType === Node.TEXT_NODE) {
      const length = range.startContainer.textContent.length;
      if (length) {
        range.setStart(range.startContainer, Math.min(range.startOffset, length - 1));
        range.setEnd(range.startContainer, range.startOffset + 1);
        const rect = range.getBoundingClientRect();
        if (x >= rect.left - 3 && x <= rect.right + 3 && y >= rect.top - 3 && y <= rect.bottom + 3) return false;
      }
    }
    return true;
  };
  function markChapterLinks() {
    if (!location.pathname.includes('reader')) return;
    document.querySelectorAll('button, a, [role="button"], .readerChapterFooter_prev, .readerChapterFooter_next').forEach(node => {
      const label = (node.textContent || '').trim();
      if (/^(上一章|下一章|上一章节|下一章节)$/.test(label) && !node.classList.contains('floating-chapter-link')) {
        node.classList.add('floating-chapter-link');
      }
    });
    document.querySelectorAll('a, button, span, div').forEach(node => {
      if (node.childElementCount > 1) return;
      const label = (node.textContent || '').replace(/\s+/g, '');
      if (/^(点击)?去微信读书(App|app)?阅读$|^(打开微信读书|在微信读书中打开)$/.test(label) && !node.classList.contains('floating-reader-promotion')) {
        node.classList.add('floating-reader-promotion');
      }
    });
  }
  window.floatingReaderApply = settings => {
    options = settings;
    if (settings.original) {
      style.textContent = '';
      return;
    }
    const reading = location.pathname.includes('reader');
    const background = settings.transparent ? 'transparent' : /^#[0-9a-f]{6}$/i.test(settings.background || '') ? settings.background : settings.dark ? '#191919' : '#faf7f0';
    // Never paint all descendants: the reader uses overlapping rendering layers.
    // An opaque background on those layers can cover the chapter's canvas.
    const readerCSS = reading ? `
      .floating-reader-promotion { display: none !important; }
      html, body { background-color: ${background} !important; }
      ${settings.opacity < 1 || settings.transparent ? `
        html, body, #app, .app, .reader, .readerContent,
        .readerChapterContent, .wr_readerChapterContent {
          background-color: transparent !important;
          background-image: none !important; box-shadow: none !important;
        }
      ` : ''}
      .readerChapterContent p, .readerChapterContent span, .wr_readerChapterContent p, .wr_readerChapterContent span {
        color: ${settings.color} !important;
      }
      .floating-chapter-link, .readerChapterFooter_prev, .readerChapterFooter_next {
        appearance: none !important; background: transparent !important;
        border: 0 !important; border-radius: 0 !important; box-shadow: none !important;
        color: ${settings.color} !important; font-size: 14px !important;
        font-weight: 400 !important; opacity: .65; cursor: pointer;
        min-width: 0 !important; min-height: 0 !important; padding: 4px 8px !important;
      }
      .floating-chapter-link:hover { opacity: 1; text-decoration: underline; }
      .floating-chapter-link:focus-visible { outline: 1px solid currentColor; }
    ` : '';
    const css = `
      * { scrollbar-width: none !important; }
      *::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
      ${readerCSS}
    `;
    if (style.textContent !== css) style.textContent = css;
    markChapterLinks();
  };
  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled || !options) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      window.floatingReaderApply(options);
    });
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
