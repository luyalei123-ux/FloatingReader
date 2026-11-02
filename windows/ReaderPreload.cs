using System.Text.Json;
using FloatingReader.Core;
namespace FloatingReader.Windows;

public sealed partial class ReaderWindow {
    sealed record CachedChapter(string Owner,ReadBatch Batch,JsonElement Capture,bool End);
    BrowserSession? _preloader;
    Task? _preloaderInit;
    readonly SemaphoreSlim _preloadGate=new(1,1);
    Task _preloadTask=Task.CompletedTask,_fillTask=Task.CompletedTask;
    CancellationTokenSource? _preloadStop,_fillStop;
    CachedChapter? _cachedNext;
    string _preloadOwner="",_preloadStatus="尚未预读";
    bool _atChapterEnd;
    TaskCompletionSource<bool> _nextReady=new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly System.Windows.Threading.DispatcherTimer _preloadWatchdog=new(){Interval=TimeSpan.FromSeconds(15)};
    DateTime _retryAfter=DateTime.MinValue;
    int _preloadFailures;
    void MaintainPreload(){if(_pure&&!_busy&&!_catalogOpen&&!_closing&&DateTime.UtcNow>=_retryAfter)StartNextPreload();}
    void ResumeBottomRequest(){
        if(!_wantContinue||_closing||_busy||_catalogOpen||!_pure||_pauseAutomatic)return;
        _reader.UpdateLayout();
        if(_reader.VerticalOffset<_reader.ExtentHeight-_reader.ViewportHeight-3){_wantContinue=false;return;}
        if(!_fillTask.IsCompleted)return;
        _wantContinue=false;Dispatcher.BeginInvoke(new Action(async()=>await RunBusy(ContinueReading)));
    }

    async Task<BrowserSession> GetPreloader(){
        if(_preloader is null){
            _preloader=new BrowserSession(_store.DirectoryPath);BindBrowser(_preloader);
            _preloader.View.PreviewKeyDown+=OnShortcut;
            _preloaderInit=_preloader.Initialize(_preloadHost);
        }
        if(_preloaderInit is not null){try{await _preloaderInit;}catch{_preloader?.Dispose();_preloader=null;_preloaderInit=null;throw;}}
        return _preloader;
    }
    async Task PreparePreloader(){try{await GetPreloader();}catch(Exception e){_preloadStatus="后台页面初始化失败："+e.Message;}}
    void StartNextPreload(){
        string owner=_chapterUrl;
        if(!_pure||!ReadingLogic.IsReaderUrl(owner)||_closing||_catalogOpen)return;
        if(_preloadOwner==owner&&DateTime.UtcNow<_retryAfter)return;
        if(_preloadOwner==owner&&(!_preloadTask.IsCompleted||_cachedNext is not null))return;
        _preloadStop?.Cancel();_cachedNext=null;
        if(_preloadOwner!=owner){_preloadFailures=0;_retryAfter=DateTime.MinValue;}
        _preloadOwner=owner;_nextReady=new(TaskCreationOptions.RunContinuationsAsynchronously);
        _preloadStop=CancellationTokenSource.CreateLinkedTokenSource(_operation.Token);
        _preloadTask=LoadNextInBackground(owner,_preloadStop.Token);
    }
    async Task LoadNextInBackground(string owner,CancellationToken token){
        bool entered=false;BrowserSession? session=null;JsonElement stable=default;
        try{
            await _preloadGate.WaitAsync(token);entered=true;token.ThrowIfCancellationRequested();
            session=await GetPreloader();token.ThrowIfCancellationRequested();
            if(!session.Healthy){session.Dispose();_preloader=null;_preloaderInit=null;session=await GetPreloader();}
            _preloadStatus="正在后台打开相邻章节";
            await session.SetCaptureViewport(true,false).WaitAsync(token);
            session.Navigate(owner);await session.WaitReady(token).WaitAsync(token);
            if(session.Url!=owner)throw new InvalidOperationException("后台页面未停在当前章节，已放弃预读以避免串章。");
            await session.ChangeChapter("next",token);
            await session.Js("window.floatingReaderBeginCapture()").WaitAsync(token);
            var batch=await session.Read(token).WaitAsync(token);
            if(!ReaderFlowPolicy.CanUsePrefetch(owner,_chapterUrl,batch.Url))return;
            stable=await session.CaptureState().WaitAsync(token);
            var combined=batch;bool end=!batch.Recognized;
            void Publish(){token.ThrowIfCancellationRequested();if(_chapterUrl!=owner||!ReferenceEquals(session,_preloader))return;_cachedNext=new(owner,combined,stable,end);_nextReady.TrySetResult(true);_preloadFailures=0;_retryAfter=DateTime.MinValue;}
            Publish();_preloadStatus="下一章首批文字已就绪";
            for(int page=1;page<8&&batch.Recognized&&combined.Text.Length<18000;page++){
                token.ThrowIfCancellationRequested();
                var advance=await session.Advance(true,combined.Rows.Count>0?combined.Rows.Max(r=>r.Y):null).WaitAsync(token);
                if(advance=="boundary"){end=true;Publish();break;}if(advance!="moved")break;
                await Task.Delay(180,token);
                double? bottom=combined.Rows.Count>0?combined.Rows.Max(r=>r.Y):null;
                var more=await session.Read(token,bottom).WaitAsync(token);token.ThrowIfCancellationRequested();
                if(more.Url!=batch.Url)throw new InvalidOperationException("后台章节已变化，停止预读。");
                combined=combined with {Text=ReadingLogic.AppendExact(combined.Text,more.Text),Rows=combined.Rows.Concat(more.Rows).ToList()};
                stable=await session.CaptureState().WaitAsync(token);Publish();
            }
            _preloadStatus=$"下一章已预读 {combined.Text.Length} 字";
            if(_pure&&_chapterUrl==owner&&!_closing)SetStatus($"本章已读取 {_text.Length} 字 · {_preloadStatus}");
        }catch(OperationCanceledException){}
        catch(Exception e){if(!token.IsCancellationRequested&&_chapterUrl==owner){_preloadStatus="下一章预读未完成："+e.Message;_retryAfter=DateTime.UtcNow.AddSeconds(15*Math.Pow(2,Math.Min(4,_preloadFailures++)));}}
        finally{
            if(token.IsCancellationRequested&&session is not null&&stable.ValueKind==JsonValueKind.Object&&!ReferenceEquals(session,_browser)){
                try{await session.RestoreCapture(stable).WaitAsync(TimeSpan.FromSeconds(2));}catch(Exception){}
            }
            if(entered)_preloadGate.Release();
        }
    }
    async Task<bool> TryUseCachedNext(bool continuous=false){
        var cached=_cachedNext;
        if(_catalogOpen||cached is null||_preloader is null||!ReaderFlowPolicy.CanUsePrefetch(cached.Owner,_chapterUrl,cached.Batch.Url))return false;
        _preloadStop?.Cancel();
        try{await _preloadTask.WaitAsync(TimeSpan.FromSeconds(3));}catch(TimeoutException){return false;}
        cached=_cachedNext;if(cached is null)return false;
        if(!_preloader.Healthy||_preloader.Url!=cached.Batch.Url){
            _cachedNext=null;_preloadOwner="";_chapterUrl=cached.Batch.Url;_sourceBottom=null;
            ApplyBatch(cached.Batch,continuous,continuous);_atChapterEnd=cached.End;SetMode(true);if(!continuous)ScrollToCharacter(0);
            _restoring=true;
            try{_browser.Navigate(cached.Batch.Url);await _browser.WaitReady(_operation.Token);await _browser.SetCaptureViewport(true);await _browser.RestoreCapture(cached.Capture);}
            finally{_restoring=false;}
            StartNextPreload();StartCurrentFill();return true;
        }
        var ready=_preloader;var previous=_browser;
        // Swap roles, not visual parents: WebView2 stays loaded and keeps its painted page.
        var previousHost=_webHost;_webHost=_preloadHost;_preloadHost=previousHost;
        _preloadHost.Opacity=0;_preloadHost.IsHitTestVisible=false;
        _browser=ready;_preloader=previous;_preloaderInit=Task.CompletedTask;
        _cachedNext=null;_preloadOwner="";
        _chapterUrl=cached.Batch.Url;_sourceBottom=null;ApplyBatch(cached.Batch,continuous,continuous);_atChapterEnd=cached.End;
        SetMode(true);if(!continuous)ScrollToCharacter(0);SetStatus("已使用后台预读的下一章");
        await _browser.SetReadingFocus(true);await _browser.RestoreCapture(cached.Capture);
        StartNextPreload();StartCurrentFill();return true;
    }
    void StartCurrentFill(){
        _fillStop?.Cancel();if(_atChapterEnd||!_recognized)return;
        _fillStop=CancellationTokenSource.CreateLinkedTokenSource(_operation.Token);
        _fillTask=FillCurrentInBackground(_browser,_chapterUrl,_fillStop.Token);
    }
    async Task FillCurrentInBackground(BrowserSession session,string owner,CancellationToken token){
        JsonElement unreadStart=default;
        try{
            for(int page=0;page<8;page++){
                token.ThrowIfCancellationRequested();
                unreadStart=await session.CaptureState().WaitAsync(token);
                var result=await session.Advance(true,_sourceBottom).WaitAsync(token);
                if(result=="boundary"){_atChapterEnd=true;unreadStart=default;return;}if(result!="moved"){unreadStart=default;return;}
                await Task.Delay(150,token);
                var batch=await session.Read(token,_sourceBottom).WaitAsync(token);token.ThrowIfCancellationRequested();
                if(!ReferenceEquals(session,_browser)||_chapterUrl!=owner)return;
                if(batch.Text.Length>0)ApplyBatch(batch,true);unreadStart=default;
            }
        }catch(OperationCanceledException){}
        catch(Exception e){if(!token.IsCancellationRequested&&_chapterUrl==owner)SetStatus("已保留正文，后续可下滑重试："+e.Message);}
        finally{
            if(unreadStart.ValueKind==JsonValueKind.Object&&ReferenceEquals(session,_browser)&&session.Url==owner){try{await session.RestoreCapture(unreadStart).WaitAsync(TimeSpan.FromSeconds(2));}catch(Exception){}}
            if(!token.IsCancellationRequested)_ = Dispatcher.BeginInvoke(new Action(ResumeBottomRequest));
        }
    }
    async Task StopCurrentFill(){
        _fillStop?.Cancel();
        try{await _fillTask.WaitAsync(TimeSpan.FromSeconds(4));}catch(TimeoutException){throw new InvalidOperationException("当前页面尚未完成绘制，请稍后再试切章。");}
    }
    void CancelBackgroundWork(){_fillStop?.Cancel();_preloadStop?.Cancel();_cachedNext=null;_preloadOwner="";_retryAfter=DateTime.MinValue;_preloadFailures=0;_nextReady.TrySetCanceled();}
}
