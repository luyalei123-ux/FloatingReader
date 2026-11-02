using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using FloatingReader.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace FloatingReader.Windows;

public sealed record ReadRow(string Text,double Y,double Height);
public sealed record ReadBatch(string Text,bool Recognized,string Url,double SourceY,int Cursor,List<ReadRow> Rows);
public sealed class BrowserSession : IDisposable {
    public WebView2CompositionControl View {get;}=new();
    readonly string _dataPath;
    Panel? _host;
    bool _disposed;
    OcrEngine? _ocr;
    public bool IsLoading {get;private set;}
    public bool Healthy {get;private set;}=true;
    public bool Ready => View.CoreWebView2 is not null;
    public string ChapterDiagnostic {get;private set;}="尚未切章";
    public string OcrLanguages => string.Join(", ",OcrEngine.AvailableRecognizerLanguages.Select(l=>l.LanguageTag));
    public string Url => View.CoreWebView2?.Source??"";
    public event Action? NavigationFinished;
    public event Action? SourceChanged;
    public event Action<string>? Status;
    public BrowserSession(string dataPath){_dataPath=dataPath;}
    public async Task Initialize(Panel host) {
        _host=host;if(!host.Children.Contains(View))host.Children.Add(View);
        var options=new CoreWebView2EnvironmentOptions("--disable-renderer-backgrounding --disable-background-timer-throttling --disable-backgrounding-occluded-windows");
        var environment=await CoreWebView2Environment.CreateAsync(null,Path.Combine(_dataPath,"WebView2"),options);
        await View.EnsureCoreWebView2Async(environment);
        View.CoreWebView2.Settings.IsStatusBarEnabled=false;
        View.CoreWebView2.Settings.AreDefaultContextMenusEnabled=true;
        var script=File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"Resources","reader.js"))+"\n"+File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"Resources","navigation.js"));
        await View.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync("(()=>{const boot=()=>{"+script+"};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();})();");
        View.CoreWebView2.SourceChanged+=(_,_)=>SourceChanged?.Invoke();
        View.CoreWebView2.NavigationStarting+=(_,_)=>IsLoading=true;
        View.CoreWebView2.NavigationCompleted+=(_,e)=>{IsLoading=false;if(!e.IsSuccess)Status?.Invoke("网页加载失败："+e.WebErrorStatus);NavigationFinished?.Invoke();};
        View.CoreWebView2.NewWindowRequested+=(_,e)=>{
            e.Handled=true;if(Uri.TryCreate(e.Uri,UriKind.Absolute,out var u)&&u.Scheme is "https" or "http") {
                if(u.Host=="weread.qq.com")Navigate(e.Uri);else Process.Start(new ProcessStartInfo(e.Uri){UseShellExecute=true});
            }
        };
        View.CoreWebView2.ProcessFailed+=(_,_)=>{Healthy=false;Status?.Invoke("网页进程停止，已保留缓存正文。");};
    }
    public void Navigate(string url){if(Ready){Healthy=true;IsLoading=true;View.CoreWebView2.Navigate(url);}}
    public void Back(){if(Ready&&View.CoreWebView2.CanGoBack)View.CoreWebView2.GoBack();}
    public void Reload(){if(Ready)View.CoreWebView2.Reload();}
    public void Mount(bool offscreen) {
        // Keep the composition control in the live window. Off-desktop WPF windows
        // are occluded/throttled on Windows 10 and can yield stale or empty captures.
        _ = offscreen;
    }
    public async Task SetCaptureViewport(bool reading,bool focused=true) {
        if(!Ready)return;
        if(reading){
            await View.CoreWebView2.CallDevToolsProtocolMethodAsync("Emulation.setDeviceMetricsOverride",JsonSerializer.Serialize(new{width=1200,height=2400,deviceScaleFactor=1,mobile=false}));
            await SetReadingFocus(focused);
        }else {await View.CoreWebView2.CallDevToolsProtocolMethodAsync("Emulation.clearDeviceMetricsOverride","{}");await SetReadingFocus(false);}
    }
    public async Task SetReadingFocus(bool focused){if(Ready)await View.CoreWebView2.CallDevToolsProtocolMethodAsync("Emulation.setFocusEmulationEnabled",JsonSerializer.Serialize(new{enabled=focused}));}
    public async Task<JsonElement> Js(string expression) {
        if(!Ready)throw new InvalidOperationException("网页尚未初始化。");
        var raw=await View.CoreWebView2.CallDevToolsProtocolMethodAsync("Runtime.evaluate",JsonSerializer.Serialize(new{expression,awaitPromise=true,returnByValue=true})).WaitAsync(TimeSpan.FromSeconds(15));
        using var document=JsonDocument.Parse(raw);var root=document.RootElement;
        if(root.TryGetProperty("exceptionDetails",out var error))throw new InvalidOperationException("网页操作未完成："+error.ToString());
        return root.TryGetProperty("result",out var result)&&result.TryGetProperty("value",out var value)?value.Clone():default;
    }
    public async Task WaitReady(CancellationToken token) {
        for(int i=0;i<100;i++){
            token.ThrowIfCancellationRequested();
            try{var value=await Js("typeof window.floatingReaderChapterSnapshot==='function'&&window.floatingReaderChapterSnapshot().ready");if(!IsLoading&&value.ValueKind==JsonValueKind.True)return;}catch(Exception e) when(e is InvalidOperationException or System.Runtime.InteropServices.COMException){}
            await Task.Delay(200,token);
        }
        throw new InvalidOperationException("正文尚未就绪。请返回原网页检查登录、权限和内容。");
    }
    public async Task<JsonElement> CaptureState()=>await Js("window.floatingReaderCaptureState?.()||{}");
    public async Task RestoreCapture(JsonElement state)=>_ = await Js("window.floatingReaderRestoreCaptureState?.("+state.GetRawText()+")");
    public async Task<string> Advance(bool forward,double? recognizedBoundary=null) {
        var result=await Js("window.floatingReaderAdvancePage?.("+(forward?"true":"false")+","+JsonSerializer.Serialize(recognizedBoundary)+")");return result.ValueKind==JsonValueKind.String?result.GetString()!:"unavailable";
    }
    public async Task<ReadBatch> Read(CancellationToken token,double? knownBottom=null) {
        for(int attempt=0;attempt<4;attempt++){
            try{
                var batch=await ReadOnce(token,knownBottom);
                if(!batch.Recognized||!string.IsNullOrWhiteSpace(batch.Text))return batch;
            }catch(InvalidOperationException error) when(error.Message.StartsWith("没有识别到",StringComparison.Ordinal)){}

            if(attempt<3)await Task.Delay(500,token);
        }
        throw new InvalidOperationException("此段尚未识别完整，已保留原读取位置，未跳过正文。请稍后下滑重试或核对原网页。");
    }
    async Task<ReadBatch> ReadOnce(CancellationToken token,double? knownBottom) {
        await WaitReady(token);
        var direct=await Js("""
        (()=>{
          const node=document.querySelector('.readerChapterContent,.readerContent .chapterContent,.wr_readerChapterContent');
          if(!node)return null;
          if(Array.from(node.querySelectorAll('canvas')).some(c=>c.width>32&&c.height>32))return null;
          const faces=document.fonts?Array.from(document.fonts):[];
          if([node,...node.querySelectorAll('p,span,div')].some(n=>{const families=getComputedStyle(n).fontFamily.split(',').map(s=>s.trim().replace(/["']/g,'').toLowerCase());return faces.some(f=>families.includes(f.family.replace(/["']/g,'').toLowerCase()));}))return null;
          const text=(node.innerText||'').trim();if(text.length<80||/[\uE000-\uF8FF]/.test(text))return null;
          const state=window.floatingReaderCaptureState();let cursor=0;
          if(state.current>2&&document.caretRangeFromPoint){const r=node.getBoundingClientRect(),p=document.caretRangeFromPoint(Math.max(0,r.left)+24,Math.max(0,r.top)+24);if(p&&node.contains(p.startContainer)){const prefix=document.createRange();prefix.selectNodeContents(node);prefix.setEnd(p.startContainer,p.startOffset);cursor=prefix.toString().length;}}
          if(!cursor&&state.current>2)cursor=Math.floor(state.current/Math.max(1,state.maximum)*text.length);
          return {text,cursor,y:state.current,url:location.href};
        })()
        """);
        token.ThrowIfCancellationRequested();
        if(direct.ValueKind==JsonValueKind.Object)return new(S(direct,"text"),false,S(direct,"url"),N(direct,"y"),(int)N(direct,"cursor"),[]);
        await Js("(async()=>{if(document.fonts)await document.fonts.ready;await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return true;})()");
        token.ThrowIfCancellationRequested();
        var geometry=await Js("""
        (()=>{
          const state=window.floatingReaderCaptureState(),node=document.querySelector('.readerChapterContent,.wr_readerChapterContent');
          let x=0,y=0,w=innerWidth,h=innerHeight;
          if(node){const r=node.getBoundingClientRect(),cx=Math.max(0,r.left),cy=Math.max(0,r.top),cw=Math.min(innerWidth,r.right)-cx,ch=Math.min(innerHeight,r.bottom)-cy;if(cw>=innerWidth*.55&&ch>=innerHeight*.35){x=cx;y=cy;w=cw;h=ch;}}
          return {x,y,w,h,viewportWidth:innerWidth,current:state.current,maximum:state.maximum,url:location.href};
        })()
        """);
        token.ThrowIfCancellationRequested();
        using var image=new MemoryStream();
        var capture=await View.CoreWebView2.CallDevToolsProtocolMethodAsync("Page.captureScreenshot","{\"format\":\"png\",\"fromSurface\":true,\"captureBeyondViewport\":false}");
        using(var captured=JsonDocument.Parse(capture)){var bytes=Convert.FromBase64String(captured.RootElement.GetProperty("data").GetString()!);await image.WriteAsync(bytes,token);}
        using var stream=new InMemoryRandomAccessStream();using(var writer=new DataWriter(stream)){writer.WriteBytes(image.ToArray());await writer.StoreAsync();await writer.FlushAsync();writer.DetachStream();}stream.Seek(0);
        var decoder=await BitmapDecoder.CreateAsync(stream);
        var scale=decoder.PixelWidth/Math.Max(1,N(geometry,"viewportWidth"));
        uint x=(uint)Math.Clamp(N(geometry,"x")*scale,0,decoder.PixelWidth-1),y=(uint)Math.Clamp(N(geometry,"y")*scale,0,decoder.PixelHeight-1);
        uint w=(uint)Math.Clamp(N(geometry,"w")*scale,1,decoder.PixelWidth-x),h=(uint)Math.Clamp(N(geometry,"h")*scale,1,decoder.PixelHeight-y);
        var transform=new BitmapTransform{Bounds=new BitmapBounds{X=x,Y=y,Width=w,Height=h}};
        var longest=Math.Max(w,h);if(longest>OcrEngine.MaxImageDimension){var factor=(double)OcrEngine.MaxImageDimension/longest;transform.ScaledWidth=(uint)Math.Max(1,decoder.PixelWidth*factor);transform.ScaledHeight=(uint)Math.Max(1,decoder.PixelHeight*factor);transform.Bounds=new BitmapBounds{X=(uint)(x*factor),Y=(uint)(y*factor),Width=(uint)Math.Max(1,w*factor),Height=(uint)Math.Max(1,h*factor)};scale*=factor;}
        using var bitmap=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,transform,ExifOrientationMode.IgnoreExifOrientation,ColorManagementMode.DoNotColorManage);
        var language=OcrEngine.AvailableRecognizerLanguages.FirstOrDefault(l=>l.LanguageTag.StartsWith("zh",StringComparison.OrdinalIgnoreCase));
        if(language is null)throw new InvalidOperationException("当前 Windows 未安装中文 OCR 组件，无法可靠识别微信读书画布正文。请先安装中文光学字符识别语言功能，再重试；不会用英文识别结果代替中文正文。");
        var engine=_ocr??=OcrEngine.TryCreateFromLanguage(language);
        if(engine is null)throw new InvalidOperationException("Windows 尚未安装文字识别语言。请在设置 → 时间和语言 → 语言和区域，添加中文及其 OCR 语言功能。");
        var recognized=await engine.RecognizeAsync(bitmap);token.ThrowIfCancellationRequested();
        var rows=new List<ReadRow>();double current=N(geometry,"current"),maximum=N(geometry,"maximum"),regionHeight=N(geometry,"h");
        foreach(var line in recognized.Lines){
            var words=line.Words.ToArray();if(words.Length==0)continue;
            double top=words.Min(a=>a.BoundingRect.Top)/scale,bottom=words.Max(a=>a.BoundingRect.Bottom)/scale;
            if(!ReadingLogic.CompleteLine(top,bottom,regionHeight,bottom-top,current,current>=maximum-2))continue;
            double position=current+N(geometry,"y")+(top+bottom)/2;
            if(knownBottom is double boundary&&position<=boundary+(bottom-top)*.3)continue;
            var text=line.Text.Trim();if(text.Length==0||text is "上一章" or "下一章" or "上一页" or "下一页" or "<上一页下一页>" or "目录" or "书城"||text.Contains("微信读书 App 阅读",StringComparison.OrdinalIgnoreCase))continue;
            rows.Add(new(text,position,bottom-top));
        }
        rows.Sort((a,b)=>a.Y.CompareTo(b.Y));
        var builder=new StringBuilder();ReadRow? previous=null;
        foreach(var row in rows){if(previous is not null){bool sameParagraph=row.Y-previous.Y<Math.Max(row.Height,previous.Height)*2.1;if(!sameParagraph)builder.Append("\n\n");else if(previous.Text.Length>0&&row.Text.Length>0&&previous.Text[^1]<128&&row.Text[0]<128)builder.Append(' ');}builder.Append(row.Text);previous=row;}
        string output=builder.ToString();
        if(knownBottom is null&&(output.Count(c=>!char.IsWhiteSpace(c))<20||rows.Count<1))throw new InvalidOperationException("没有识别到足够完整的正文，已保留原内容。请返回原网页检查。");
        return new(output,true,S(geometry,"url"),current,0,rows);
    }
    public async Task Click(double x,double y) {
        foreach(var type in new[]{"mouseMoved","mousePressed","mouseReleased"}) {
            var input=type=="mouseMoved"?JsonSerializer.Serialize(new{type,x,y}):JsonSerializer.Serialize(new{type,x,y,button="left",clickCount=1});
            await View.CoreWebView2.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent",input);
        }
    }
    public async Task ChangeChapter(string direction,CancellationToken cancellation) {
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(cancellation);timeout.CancelAfter(TimeSpan.FromSeconds(35));var token=timeout.Token;
        async Task<JsonElement> Eval(string expression)=>await Js(expression).WaitAsync(token);
        try{
            var plan=await Eval("window.floatingWindowsChapterPlan("+JsonSerializer.Serialize(direction)+")");
            if(S(plan,"kind")=="missing"&&direction is "next" or "previous"){
                var scroll=await CaptureState().WaitAsync(token);double edge=direction=="previous"?0:N(scroll,"maximum");
                await ApplyPosition(edge).WaitAsync(token);
                for(int i=0;i<6&&S(plan,"kind")=="missing";i++){await Task.Delay(180,token);plan=await Eval("window.floatingWindowsChapterPlan("+JsonSerializer.Serialize(direction)+")");}
                if(S(plan,"kind")=="missing"){
                    await Eval("window.floatingWindowsOpenCatalog()");
                    for(int i=0;i<6&&S(plan,"kind")=="missing";i++){await Task.Delay(200,token);plan=await Eval("window.floatingWindowsAdjacentCatalog("+JsonSerializer.Serialize(direction)+")");}
                }
            }
            if(S(plan,"kind")=="missing")throw new InvalidOperationException("网页和目录都未能确认相邻章节。请用章节选择核对，并复制阅读诊断反馈；原正文已保留。");
            ChapterDiagnostic="入口: "+S(plan,"kind")+" · "+S(plan,"label");
            await Task.Delay(120,token);
            var before=await Eval("window.floatingReaderChapterSnapshot()");string beforeUrl=Url,baseline=S(before,"signature");
            await Eval("(()=>{window.floatingReaderChapterProgress={phase:'activating',kind:"+JsonSerializer.Serialize(S(plan,"kind"))+",label:"+JsonSerializer.Serialize(S(plan,"label"))+"};return true;})()");
            if(S(plan,"kind")=="url")Navigate(S(plan,"url"));
            else await Eval("window.floatingWindowsActivateChapter()");
            string last="";int stable=0;bool fallback=false;
            for(int i=0;i<120;i++){
                await Task.Delay(200,token);JsonElement now;
                try{now=await Eval("window.floatingReaderChapterSnapshot?.()||{}");}catch(Exception e) when(e is InvalidOperationException or System.Runtime.InteropServices.COMException){continue;}
                string signature=S(now,"signature");bool changed=Url!=beforeUrl||signature.Length>0&&signature!=baseline;
                bool ready=now.TryGetProperty("ready",out var r)&&r.ValueKind==JsonValueKind.True;
                if(changed&&ready&&!IsLoading&&signature==last)stable++;else stable=0;last=signature;
                ChapterDiagnostic=$"入口: {S(plan,"kind")} · 就绪: {ready} · 变化: {changed} · 稳定: {stable} · 等待: {i*200}ms";
                if(stable>=3&&i>=5){await Eval("window.floatingReaderStartChapter?.()");return;}
                if(i==29&&!changed&&ready&&!fallback&&S(plan,"kind")=="element"){
                    fallback=true;var fresh=await Eval("window.floatingWindowsChapterPlan("+JsonSerializer.Serialize(direction)+")");
                    if(S(fresh,"kind")=="element")await Click(N(fresh,"x"),N(fresh,"y")).WaitAsync(token);
                }
            }
            throw new TimeoutException();
        }catch(Exception e) when((e is OperationCanceledException&&!cancellation.IsCancellationRequested)||e is TimeoutException){
            ChapterDiagnostic="切章超时 · "+ChapterDiagnostic;
            throw new InvalidOperationException("切章在 35 秒内未完成，已停止等待并保留正文。请返回原网页核对，或复制阅读诊断反馈。");
        }
    }
    public async Task ApplyPosition(double sourceY,string snippet="",bool recognized=true,double ratio=0)=>_ =await Js("window.floatingReaderSetReadingPosition?.("+JsonSerializer.Serialize(new{y=sourceY,snippet,recognized,ratio})+")");
    public static double N(JsonElement e,string key)=>e.ValueKind==JsonValueKind.Object&&e.TryGetProperty(key,out var v)&&v.ValueKind==JsonValueKind.Number&&v.TryGetDouble(out double n)?n:0;
    public static string S(JsonElement e,string key)=>e.ValueKind==JsonValueKind.Object&&e.TryGetProperty(key,out var v)&&v.ValueKind==JsonValueKind.String?v.GetString()??"":"";
    public void Dispose(){if(_disposed)return;_disposed=true;_host?.Children.Remove(View);View.Dispose();}
}
