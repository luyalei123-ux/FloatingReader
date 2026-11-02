using System.ComponentModel;
using System.Diagnostics;
using System.Threading;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Data;
using FloatingReader.Core;

namespace FloatingReader.Windows;

public sealed partial class ReaderWindow : Window {
    readonly SettingsStore _store;
    readonly ReaderSettings _settings;
    BrowserSession _browser;
    readonly Grid _root=new(),_page=new();
    Grid _webHost=new(),_preloadHost=new(){Opacity=0,IsHitTestVisible=false};
    readonly Border _frame=new(){BorderThickness=new Thickness(4)};
    readonly DockPanel _top=new(){LastChildFill=true},_bottom=new(){LastChildFill=true};
    readonly TextBlock _status=new(){FontSize=11,Margin=new Thickness(12,4,12,4),TextTrimming=TextTrimming.CharacterEllipsis};
    readonly RichTextBox _reader=new(){IsReadOnly=true,IsDocumentEnabled=true,BorderThickness=new Thickness(0),Background=Brushes.Transparent,VerticalScrollBarVisibility=ScrollBarVisibility.Hidden,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,Padding=new Thickness(0)};
    readonly List<Hyperlink> _chapterLinks=[];
    readonly Paragraph _paragraph=new(){Margin=new Thickness(0)};
    readonly FlowDocument _document=new(){PagePadding=new Thickness(24,28,24,24),ColumnWidth=double.PositiveInfinity};
    readonly Button _mode=new(){MinWidth=48,MaxWidth=54,FontSize=11,Margin=new Thickness(2),Padding=new Thickness(5)},_pin=new(),_background=new();
    readonly DispatcherTimer _autoReadTimer=new(){Interval=TimeSpan.FromMilliseconds(250)};
    string _rawOnlyUrl="";
    readonly DispatcherTimer _saveTimer=new(){Interval=TimeSpan.FromSeconds(1)};
    readonly List<Window> _panels=[];
    readonly List<SourceAnchor> _anchors=[];
    CancellationTokenSource _operation=new();
    bool _wantContinue;
    bool _pure,_busy,_styling,_closing,_finalClose,_pauseAutomatic,_restoring;
    string _text="",_chapterUrl="";
    bool _recognized;
    double? _sourceBottom;
    Bookmark? _pendingRestore;
    bool _forceWebsite;
    const string ShelfUrl="https://weread.qq.com/";
    public ReaderWindow() {
        _store=new SettingsStore(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"FloatingReader"));
        _settings=_store.Load();_settings.ToolbarVisible=true;_settings.BackgroundOpacity=1;_browser=new BrowserSession(_store.DirectoryPath);
        Title="浮读 0.29.2 · Windows";Width=720;Height=560;MinWidth=64;MinHeight=64;WindowStyle=WindowStyle.None;AllowsTransparency=true;Background=Brushes.Transparent;ResizeMode=ResizeMode.CanResize;
        WindowStartupLocation=WindowStartupLocation.CenterScreen;
        Icon=BitmapFrame.Create(new Uri(Path.Combine(AppContext.BaseDirectory,"Assets","App.ico")));
        BuildWindow();ApplyStyle();
        BindBrowser(_browser);
        _preloadWatchdog.Tick+=(_,_)=>MaintainPreload();
        _autoReadTimer.Tick+=async(_,_)=>{_autoReadTimer.Stop();if(_closing||!ReaderFlowPolicy.ShouldAutoRead(_pure,_browser.Url,_rawOnlyUrl)||_pendingRestore is not null)return;if(_busy||_browser.IsLoading){_autoReadTimer.Start();return;}await RunBusy(ReadCurrent);};
        _saveTimer.Tick+=async(_,_)=>{_saveTimer.Stop();await SaveReadingPosition(!_busy&&_fillTask.IsCompleted);};
        _reader.AddHandler(ScrollViewer.ScrollChangedEvent,new ScrollChangedEventHandler((_,e)=>{if(_styling||_restoring)return;_saveTimer.Stop();_saveTimer.Start();}));
        _reader.PreviewMouseWheel+=async(_,e)=>{
            if(!_pure||_pauseAutomatic||_catalogOpen)return;
            _wantContinue=false;
            if(_busy){if(e.Delta<0&&_reader.VerticalOffset>=_reader.ExtentHeight-_reader.ViewportHeight-3)_wantContinue=true;return;}
            if(e.Delta<0){e.Handled=true;_reader.ScrollToVerticalOffset(_reader.VerticalOffset+Math.Max(24,_settings.FontSize*3)*Math.Max(1,Math.Abs(e.Delta)/120.0));_reader.UpdateLayout();if(_reader.VerticalOffset>=_reader.ExtentHeight-_reader.ViewportHeight-3)await RunBusy(ContinueReading);}
            else if(e.Delta>0&&_reader.VerticalOffset<=1&&Keyboard.Modifiers.HasFlag(ModifierKeys.Control)){e.Handled=true;await RunBusy(()=>Chapter("previous"));}
        };
        _reader.PreviewMouseLeftButtonDown+=(_,e)=>{
            FocusForInteraction();
            if(e.Handled||FindHyperlink(e.OriginalSource as DependencyObject))return;
            e.Handled=true;DragMove();
        };
        _reader.SelectionChanged+=(_,_)=>{if(!_reader.Selection.IsEmpty)_reader.Selection.Select(_reader.Document.ContentStart,_reader.Document.ContentStart);};
        PreviewKeyDown+=OnShortcut;
        Loaded+=async(_,_)=>{
            try{
                await _browser.Initialize(_webHost);_browser.View.PreviewKeyDown+=OnShortcut;
                if(_settings.Bookmark is { } saved&&ReadingLogic.IsReaderUrl(saved.Url)){_pendingRestore=saved;_browser.Navigate(ReadingLogic.BookEntry(saved.Url));}
                else _browser.Navigate(ShelfUrl);
                _ = PreparePreloader();_preloadWatchdog.Start();
            }catch(Exception e){SetStatus("网页初始化失败："+e.Message);ShowRuntimeHelp();}
        };
        Closing+=OnClosing;
        Closed+=(_,_)=>{_autoReadTimer.Stop();_preloadWatchdog.Stop();CancelBackgroundWork();_operation.Cancel();_browser.Dispose();_preloader?.Dispose();foreach(var panel in _panels.ToArray())panel.Close();};
    }
    void BindBrowser(BrowserSession session){
        session.Status+=value=>{if(ReferenceEquals(session,_browser))SetStatus(value);};
        session.SourceChanged+=()=>{if(ReferenceEquals(session,_browser)&&!_pure){_autoReadTimer.Stop();_autoReadTimer.Start();}};
        session.NavigationFinished+=()=>{if(!ReferenceEquals(session,_browser))return;if(_restoring)return;if(_pendingRestore is not null&&!_busy)_=RestorePending();else if(!_pure){_autoReadTimer.Stop();_autoReadTimer.Start();}};
    }
    void BuildWindow() {
        _root.RowDefinitions.Add(new(){Height=GridLength.Auto});_root.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});_root.RowDefinitions.Add(new(){Height=GridLength.Auto});_root.RowDefinitions.Add(new(){Height=GridLength.Auto});
        _frame.Child=_root;Content=_frame;
        var caption=new DockPanel{Height=26};var close=new Button{Content="×",Width=34,ToolTip="关闭（Alt+F4）"};close.Click+=(_,_)=>Close();DockPanel.SetDock(close,Dock.Right);caption.Children.Add(close);
        var maximize=new Button{Content="□",Width=34,ToolTip="最大化／还原"};maximize.Click+=(_,_)=>WindowState=WindowState==WindowState.Maximized?WindowState.Normal:WindowState.Maximized;DockPanel.SetDock(maximize,Dock.Right);caption.Children.Add(maximize);
        var minimize=new Button{Content="−",Width=34,ToolTip="最小化"};minimize.Click+=(_,_)=>WindowState=WindowState.Minimized;DockPanel.SetDock(minimize,Dock.Right);caption.Children.Add(minimize);
        var title=new TextBlock{Text="浮读",Margin=new Thickness(10,3,0,0)};title.MouseLeftButtonDown+=(_,e)=>{if(e.ClickCount==2)WindowState=WindowState==WindowState.Maximized?WindowState.Normal:WindowState.Maximized;else DragMove();};caption.Children.Add(title);
        var topStack=new StackPanel();topStack.Children.Add(caption);topStack.Children.Add(_top);_root.Children.Add(topStack);topStack.Tag="toolbar";
        var shortcuts=IconButton("keyboard-settings",ReaderAction.Shortcuts);DockPanel.SetDock(shortcuts,Dock.Right);_top.Children.Add(shortcuts);
        var tools=new StackPanel{Orientation=Orientation.Horizontal};
        foreach(var (icon,action) in new[]{("book-open",ReaderAction.Shelf),("arrow-left",ReaderAction.Back)})tools.Children.Add(IconButton(icon,action));
        _mode.Click+=async(_,_)=>await Execute(ReaderAction.Mode);tools.Children.Add(_mode);
        tools.Children.Add(IconButton("list",ReaderAction.Catalog));
        ConfigureIcon(_pin,"anchor",ReaderAction.Pin);tools.Children.Add(_pin);
        _top.Children.Add(new ScrollViewer{Content=tools,HorizontalScrollBarVisibility=ScrollBarVisibility.Hidden,VerticalScrollBarVisibility=ScrollBarVisibility.Disabled});
        Grid.SetRow(_page,1);_root.Children.Add(_page);_page.Children.Add(_preloadHost);_page.Children.Add(_webHost);_page.Children.Add(_reader);_reader.Visibility=Visibility.Collapsed;
        _document.Blocks.Add(_paragraph);
        var footer=new Table{CellSpacing=0,Margin=new Thickness(0,16,0,0)};
        footer.Columns.Add(new TableColumn{Width=new GridLength(1,GridUnitType.Star)});footer.Columns.Add(new TableColumn{Width=new GridLength(1,GridUnitType.Star)});
        var group=new TableRowGroup();var row=new TableRow();group.Rows.Add(row);footer.RowGroups.Add(group);
        foreach(var forward in new[]{false,true}){
            var link=new Hyperlink(new Run(forward?"→":"←")){TextDecorations=null};
            _chapterLinks.Add(link);link.Click+=async(_,_)=>await RunBusy(()=>Chapter(forward?"next":"previous"));
            row.Cells.Add(new TableCell(new Paragraph(link){Margin=new Thickness(0),TextAlignment=forward?TextAlignment.Right:TextAlignment.Left}));
        }
        _document.Blocks.Add(footer);_reader.Document=_document;
        _document.Blocks.Add(new BlockUIContainer(_status){Margin=new Thickness(0,4,0,0)});
        SetStatus("打开书籍后自动读取正文。");
        var styleTools=new StackPanel{Orientation=Orientation.Horizontal};
        foreach(var (icon,action) in new[]{("font-size",ReaderAction.FontSize),("line-height",ReaderAction.Spacing),("text-color",ReaderAction.Ink),("font-family",ReaderAction.Font),("background-color",ReaderAction.Paper)})styleTools.Children.Add(IconButton(icon,action));
        ConfigureIcon(_background,"background-hidden",ReaderAction.Toolbar);tools.Children.Add(_background);
        _bottom.Children.Add(new ScrollViewer{Content=styleTools,HorizontalScrollBarVisibility=ScrollBarVisibility.Hidden,VerticalScrollBarVisibility=ScrollBarVisibility.Disabled});Grid.SetRow(_bottom,3);_root.Children.Add(_bottom);
        PreviewMouseLeftButtonDown+=(_,e)=>{
            FocusForInteraction();
            if(WindowState!=WindowState.Normal)return;var p=e.GetPosition(this);bool left=p.X<8,right=p.X>ActualWidth-8,top=p.Y<8,bottom=p.Y>ActualHeight-8;
            if((p.X<24||p.X>ActualWidth-24)&&(p.Y<24||p.Y>ActualHeight-24)){left=p.X<24;right=p.X>ActualWidth-24;top=p.Y<24;bottom=p.Y>ActualHeight-24;}
            if(!(left||right||top||bottom)){if(!_settings.ToolbarVisible){e.Handled=true;DragMove();}return;}
            // Caption buttons must receive clicks before the resize border.
            if(p.Y<34&&p.X>ActualWidth-110&&e.OriginalSource is DependencyObject item&&FindButton(item) is not null)return;
            int hit=top?(left?13:right?14:12):bottom?(left?16:right?17:15):left?10:11;
            e.Handled=true;ReleaseCapture();SendMessage(new WindowInteropHelper(this).Handle,0xA1,(IntPtr)hit,IntPtr.Zero);
        };
        var context=new ContextMenu();foreach(var action in Enum.GetValues<ReaderAction>().Where(a=>a is not ReaderAction.Paste and not ReaderAction.Theme)){var entry=new MenuItem{Header=ReaderShortcuts.Title(action)};entry.Click+=async(_,_)=>await Execute(action);context.Items.Add(entry);}_frame.ContextMenu=context;
    }
    void FocusForInteraction(){
        // Explicit clicks must activate the reader before a drag consumes the event.
        // Keep Topmost and the reading palette unchanged during focus transitions.
        if(!IsActive)Activate();
        if(!IsKeyboardFocusWithin)Focus();
    }
    static bool FindHyperlink(DependencyObject? node){while(node is not null){if(node is Hyperlink)return true;node=node is Visual or System.Windows.Media.Media3D.Visual3D?VisualTreeHelper.GetParent(node):LogicalTreeHelper.GetParent(node);}return false;}
    static Button? FindButton(DependencyObject node){while(node is not null){if(node is Button b)return b;node=node is System.Windows.Media.Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);}return null;}
    Button IconButton(string icon,ReaderAction action){var button=new Button();ConfigureIcon(button,icon,action);return button;}
    void ConfigureIcon(Button button,string icon,ReaderAction action){button.Width=32;button.Height=32;button.Margin=new Thickness(2);button.Padding=new Thickness(5);button.BorderThickness=new Thickness(0);button.Background=Brushes.Transparent;SetIcon(button,icon);button.ToolTip=ReaderShortcuts.Title(action);button.Click+=async(_,_)=>await Execute(action);}
    void SetIcon(Button button,string icon){var mark=new Border{Width=19,Height=19,OpacityMask=new ImageBrush(new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory,"Resources","Icons",icon+".png"))))};mark.SetBinding(Border.BackgroundProperty,new Binding("Foreground"){Source=this});button.Content=mark;}
    void SetStatus(string value){_status.Text=value;_status.ToolTip=value;}
    static Color ParseColor(string hex,Color fallback){try{return (Color)ColorConverter.ConvertFromString(hex);}catch(FormatException){return fallback;}}
    void ApplyStyle(){
        _styling=true;_settings.BackgroundOpacity=_settings.ToolbarVisible?1:0;var ink=ParseColor(_settings.Ink,Colors.Black);var paper=ParseColor(_settings.Paper,Colors.White);
        Foreground=new SolidColorBrush(ink);
        _mode.Background=Brushes.Transparent;_mode.BorderThickness=new Thickness(0);
        _frame.Background=Brushes.Transparent;
        _root.Background=Brushes.Transparent;
        _page.Background=new SolidColorBrush(Color.FromArgb((byte)Math.Max(1,Math.Round(_settings.BackgroundOpacity*255)),paper.R,paper.G,paper.B));
        _frame.BorderBrush=new SolidColorBrush(Color.FromArgb((byte)Math.Round(_settings.BackgroundOpacity*255),paper.R,paper.G,paper.B));_frame.BorderThickness=new Thickness(_settings.ToolbarVisible?4:0);
        _top.Background=_bottom.Background=new SolidColorBrush(paper);_status.Foreground=new SolidColorBrush(ink);
        if(_root.Children[0] is FrameworkElement chrome){chrome.Visibility=_settings.ToolbarVisible?Visibility.Visible:Visibility.Collapsed;chrome.Opacity=_settings.BackgroundOpacity;if(chrome is Panel chromePanel)chromePanel.Background=new SolidColorBrush(paper);chrome.SetValue(TextElement.ForegroundProperty,new SolidColorBrush(ink));}
        _bottom.Opacity=_status.Opacity=_settings.BackgroundOpacity;_status.Background=new SolidColorBrush(paper);
        _bottom.Visibility=_status.Visibility=_settings.ToolbarVisible?Visibility.Visible:Visibility.Collapsed;
        _reader.Foreground=new SolidColorBrush(ink);_reader.FontFamily=string.IsNullOrWhiteSpace(_settings.FontFamily)?SystemFonts.MessageFontFamily:new FontFamily(_settings.FontFamily);_reader.FontSize=_settings.FontSize*96/72;_document.FontSize=_settings.FontSize*96/72;_document.FontFamily=_reader.FontFamily;_document.Foreground=_reader.Foreground;_document.LineHeight=_reader.FontSize*_settings.LineHeight;
        foreach(var link in _chapterLinks){link.Foreground=_reader.Foreground;link.FontFamily=_reader.FontFamily;link.FontSize=_reader.FontSize;}
        foreach(var block in _document.Blocks){block.LineHeight=_reader.FontSize*_settings.LineHeight;block.Foreground=_reader.Foreground;}
        Topmost=_settings.Pinned;_mode.Content=_pure?"原网页":"纯文字";_mode.ToolTip=(_pure?"切换到原网页":"生成纯文字")+" · "+_settings.Shortcuts[ReaderAction.Mode].Label;
        SetIcon(_background,_settings.BackgroundOpacity==0?"background-visible":"background-hidden");_pin.ToolTip=_settings.Pinned?"已置顶 · 点击取消":"未置顶 · 点击置顶";
        _pin.Content=new TextBlock{Text=_settings.Pinned?"已置顶":"置顶",FontSize=12,FontWeight=_settings.Pinned?FontWeights.Bold:FontWeights.Normal,Foreground=_settings.Pinned?Brushes.DodgerBlue:new SolidColorBrush(ink),VerticalAlignment=VerticalAlignment.Center};_pin.Width=54;
        _pin.Background=_settings.Pinned?new SolidColorBrush(Color.FromArgb(35,30,144,255)):Brushes.Transparent;
        foreach(var panel in _panels){panel.Topmost=Topmost;}
        foreach(var refresh in _panelRefresh.Values.ToArray())refresh();
        _styling=false;SaveSettings();
    }
    void SaveSettings(){try{_store.Save(_settings);}catch(IOException e){SetStatus("设置保存失败："+e.Message);}catch(UnauthorizedAccessException e){SetStatus("设置保存失败："+e.Message);}}
    void SetMode(bool pure){_pure=pure;if(!pure)_ = ResetBrowserViewport();_browser.Mount(pure);_reader.Visibility=pure?Visibility.Visible:Visibility.Collapsed;_webHost.Visibility=Visibility.Visible;_webHost.Opacity=pure?0:1;_webHost.IsHitTestVisible=!pure;ApplyStyle();}
    async Task ResetBrowserViewport(){try{await _browser.SetCaptureViewport(false);}catch(Exception e){SetStatus("网页视口恢复失败："+e.Message);}}
    async Task RunBusy(Func<Task> action){
        if(_busy){SetStatus("正在读取，请稍候；可切换回原网页停止读取。");return;}
        _busy=true;
        try{await action();}
        catch(OperationCanceledException){SetStatus("已停止读取。");}
        catch(Exception e){_pauseAutomatic=true;SetStatus(e.Message);}
        finally{
            _busy=false;
            if(!_pure||_pauseAutomatic||_reader.VerticalOffset<_reader.ExtentHeight-_reader.ViewportHeight-3)_wantContinue=false;
            if(_wantContinue&&!_catalogOpen&&_fillTask.IsCompleted){_wantContinue=false;_ = Dispatcher.BeginInvoke(new Action(async()=>await RunBusy(ContinueReading)));}
        }
    }
    void ResetOperation(){CancelBackgroundWork();_operation.Cancel();_operation.Dispose();_operation=new();_pauseAutomatic=false;_wantContinue=false;}
    async Task Execute(ReaderAction action){
        if(_closing)return;
        switch(action){
            case ReaderAction.ResetStyle:_settings.FontFamily="";_settings.FontSize=14;_settings.LineHeight=1.4;_settings.Ink="#333333";_settings.Paper="#FBF6ED";_settings.Dark=false;ApplyStyle();break;
            case ReaderAction.Diagnostics:
                var diag=await _browser.Js("({path:location.pathname,title:document.querySelector('.readerChapterTitle,.readerContent .chapterTitle')?.textContent,viewport:{w:innerWidth,h:innerHeight},state:window.floatingReaderCaptureState?.(),chapter:window.floatingReaderChapterProgress})");
                Clipboard.SetText("浮读 Windows 0.29.2\nOS: "+Environment.OSVersion+"\n纯文字: "+_pure+" 读取中: "+_busy+"\n后台预读: "+_preloadStatus+"\n切章过程: "+_browser.ChapterDiagnostic+"\nOCR 语言: "+_browser.OcrLanguages+"\n正文长度: "+_text.Length+"\n状态: "+_status.Text+"\n"+diag.GetRawText());SetStatus("诊断已复制，请在发送前删除私人书籍标识。");break;
            case ReaderAction.Shelf:await SaveReadingPosition(true);ResetOperation();_pendingRestore=null;SetMode(false);_browser.Navigate(ShelfUrl);break;
            case ReaderAction.Back:await SaveReadingPosition(true);ResetOperation();SetMode(false);_browser.Back();break;
            case ReaderAction.Mode:
                if(_pure||_busy){_rawOnlyUrl=_browser.Url;ResetOperation();await _browser.SetCaptureViewport(false);SetMode(false);}else{_rawOnlyUrl="";await RunBusy(()=>ReadCurrent());}break;
            case ReaderAction.Paste:if(Clipboard.ContainsText()){ResetOperation();_chapterUrl="";_anchors.Clear();_text=Clipboard.GetText();RenderText();SetMode(true);SetStatus("粘贴文字没有书籍章节来源。");}break;
            case ReaderAction.Pin:_settings.Pinned=!_settings.Pinned;ApplyStyle();break;
            case ReaderAction.Theme:_settings.Dark=!_settings.Dark;_settings.Ink=_settings.Dark?"#E0E0E0":"#333333";_settings.Paper=_settings.Dark?"#191919":"#FBF6ED";ApplyStyle();break;
            case ReaderAction.Toolbar:
            case ReaderAction.Background:_settings.ToggleChrome();ApplyStyle();break;
            case ReaderAction.Larger:_settings.FontSize=Math.Min(64,_settings.FontSize+2);ApplyStyle();break;
            case ReaderAction.Smaller:_settings.FontSize=Math.Max(12,_settings.FontSize-2);ApplyStyle();break;
            case ReaderAction.FontSize:ShowSlider("文字大小",12,64,_settings.FontSize,v=>{_settings.FontSize=Math.Round(v);ApplyStyle();});break;
            case ReaderAction.Spacing:ShowSlider("行间距",1,2.5,_settings.LineHeight,v=>{_settings.LineHeight=v;ApplyStyle();});break;
            case ReaderAction.Ink:ShowColors(false);break;case ReaderAction.Paper:ShowColors(true);break;case ReaderAction.Font:ShowFonts();break;
            case ReaderAction.Shortcuts:ShowShortcuts();break;
            case ReaderAction.Previous:await RunBusy(()=>Chapter("previous"));break;case ReaderAction.Next:await RunBusy(()=>Chapter("next"));break;
            case ReaderAction.Catalog:await RunBusy(ShowCatalog);break;
            case ReaderAction.Reload:ResetOperation();SetMode(false);_browser.Reload();break;
            case ReaderAction.Resume:await BeginResume(false);break;case ReaderAction.WebsiteProgress:await BeginResume(true);break;
            case ReaderAction.Quit:Close();break;
        }
    }
    Task ReadCurrent()=>ReadCurrent(false);
    async Task ReadCurrent(bool continuous){
        _pauseAutomatic=false;var token=_operation.Token;await StopCurrentFill();
        if(!ReadingLogic.IsReaderUrl(_browser.Url))throw new InvalidOperationException("请先在微信读书里打开一本书。");
        SetMode(true);SetStatus("正在读取当前章节（完整阅读视口）…");await _browser.SetCaptureViewport(true);await Task.Delay(250,token);await _browser.WaitReady(token);await _browser.Js("window.floatingReaderBeginCapture()");
        ReadBatch? batch=null;for(int attempt=0;attempt<3;attempt++){try{batch=await _browser.Read(token).WaitAsync(token);break;}catch(InvalidOperationException e) when(e.Message.StartsWith("没有识别到")&&attempt<2){SetStatus("正文正在绘制，正在重新读取…");await Task.Delay(350,token);}}
        token.ThrowIfCancellationRequested();if(batch is null)throw new InvalidOperationException("正文尚未绘制完成，请重新读取或返回原网页检查。");if(!continuous)_anchors.Clear();_sourceBottom=null;_chapterUrl=batch.Url;if(!continuous)_text="";ApplyBatch(batch,continuous,continuous);SetMode(true);if(!continuous)ScrollToCharacter(batch.Cursor);
        _atChapterEnd=!batch.Recognized;StartCurrentFill();StartNextPreload();
    }
    void ApplyBatch(ReadBatch batch,bool append,bool chapterTransition=false){
        if(append&&!chapterTransition&&!ReaderFlowPolicy.CanAppend(_chapterUrl,batch.Url))throw new InvalidOperationException("原网页已切换章节，已停止追加，避免混入其他章节内容。请重新读取当前章节。");
        var oldOffset=_reader.VerticalOffset;string before=_text;_recognized=batch.Recognized;
        _text=append?(chapterTransition?_text+"\n\n"+batch.Text:ReadingLogic.AppendExact(_text,batch.Text)):batch.Text;
        if(!append)_anchors.Clear();
        if(!append||chapterTransition)_anchors.Add(new(chapterTransition?before.Length+2:0,batch.SourceY,batch.Url));
        if(batch.Rows.Count>0){foreach(var row in batch.Rows){int index=_text.LastIndexOf(row.Text,StringComparison.Ordinal);if(index>=0){_anchors.RemoveAll(a=>a.Offset==index);_anchors.Add(new(index,row.Y,batch.Url));}}_sourceBottom=Math.Max(_sourceBottom??0,batch.Rows.Max(r=>r.Y));}
        else if(_anchors.Count==0)_anchors.Add(new(0,batch.SourceY,batch.Url));
        _anchors.Sort((a,b)=>a.Offset.CompareTo(b.Offset));RenderText(append?before:null);if(append)_reader.ScrollToVerticalOffset(oldOffset);
        SetStatus($"已读取 {_text.Length} 字"+(batch.Recognized?" · 图片识别可能有错字":"")+(_cachedNext?.Owner==_chapterUrl?" · 下一章已预读":_preloadOwner==_chapterUrl&&!_preloadTask.IsCompleted?" · 正在预读下一章":""));
    }
    void RenderText(string? before=null){
        _styling=true;
        if(before is not null&&_text.StartsWith(before,StringComparison.Ordinal)){
            if(_text.Length>before.Length)_paragraph.Inlines.Add(new Run(_text[before.Length..]));
        }else{_paragraph.Inlines.Clear();_paragraph.Inlines.Add(new Run(_text));}
        _reader.UpdateLayout();_styling=false;
    }
    async Task ContinueReading(){
        if(!_fillTask.IsCompleted){_wantContinue=true;SetStatus("正在接续正文，完成后自动显示。");return;}
        if(_atChapterEnd||!_recognized){await Chapter("next",true);return;}
        var token=_operation.Token;var sourceSession=_browser;string sourceUrl=_browser.Url;var saved=await _browser.CaptureState();
        try{
            var result=await _browser.Advance(true,_sourceBottom);if(result=="boundary"){_atChapterEnd=true;await Chapter("next",true);return;}if(result!="moved")return;
            await Task.Delay(150,token);var batch=await _browser.Read(token,_sourceBottom).WaitAsync(token);token.ThrowIfCancellationRequested();if(batch.Text.Length>0)ApplyBatch(batch,true);
        }catch{if(ReferenceEquals(_browser,sourceSession)&&_browser.Url==sourceUrl)await _browser.RestoreCapture(saved);throw;}
        StartCurrentFill();StartNextPreload();
    }
    async Task Chapter(string direction,bool continuous=false){
        _wantContinue=false;
        if(!ReadingLogic.IsReaderUrl(_browser.Url))throw new InvalidOperationException("粘贴文字没有章节来源。");
        await StopCurrentFill();_pauseAutomatic=false;
        if(direction=="next"){
            if(await TryUseCachedNext(continuous))return;
            _retryAfter=DateTime.MinValue;StartNextPreload();
            if(!_preloadTask.IsCompleted){
                SetStatus("正在预读下一章，正文保留，完成后自动接续…");
                await Task.WhenAny(_nextReady.Task,_preloadTask,Task.Delay(TimeSpan.FromSeconds(45),_operation.Token));
                _operation.Token.ThrowIfCancellationRequested();
                if(await TryUseCachedNext(continuous))return;
            }
        }
        _preloadStop?.Cancel();_cachedNext=null;_preloadOwner="";
        SetStatus("正在加载章节…");await _browser.ChangeChapter(direction,_operation.Token);await ReadCurrent(continuous);
    }
    int CharacterCursor(){var p=_reader.GetPositionFromPoint(new Point(24,8),true);return p is null?0:Math.Clamp(new TextRange(_document.ContentStart,p).Text.Length,0,_text.Length);}
    TextPointer? PositionAt(int offset){var p=_paragraph.ContentStart;while(p is not null&&p.CompareTo(_paragraph.ContentEnd)<0){if(p.GetPointerContext(LogicalDirection.Forward)==TextPointerContext.Text){string run=p.GetTextInRun(LogicalDirection.Forward);if(offset<=run.Length)return p.GetPositionAtOffset(offset);offset-=run.Length;}p=p.GetNextContextPosition(LogicalDirection.Forward);}return _paragraph.ContentEnd;}
    void ScrollToCharacter(int offset){_reader.UpdateLayout();var p=PositionAt(Math.Clamp(offset,0,_text.Length));if(p is not null){var r=p.GetCharacterRect(LogicalDirection.Forward);_reader.ScrollToVerticalOffset(Math.Max(0,_reader.VerticalOffset+r.Top-8));}}
    async Task SaveReadingPosition(bool sync){
        if(_restoring)return;
        if(_pure&&ReadingLogic.IsReaderUrl(_chapterUrl)&&_text.Length>0){int cursor=CharacterCursor();var anchor=_anchors.LastOrDefault(a=>a.Offset<=cursor)??_anchors.FirstOrDefault();double y=anchor?.SourceY??0;var next=_anchors.FirstOrDefault(a=>a.Offset>cursor);if(anchor is not null&&next is not null&&next.Offset>anchor.Offset&&next.Url==anchor.Url&&next.SourceY>=y)y+=(cursor-anchor.Offset)/(double)(next.Offset-anchor.Offset)*(next.SourceY-y);
            var saved=ReadingLogic.ChapterBookmark(_text,cursor,Math.Max(0,y-24),_recognized,_anchors,_chapterUrl);
            _settings.Bookmark=saved;SaveSettings();
            string url=saved.Url,chapterText=saved.Text;int localCursor=saved.Cursor;
            if(sync&&_fillTask.IsCompleted&&_browser.Url==url){try{string snippet=chapterText.Substring(localCursor,Math.Min(36,chapterText.Length-localCursor)).Trim();await _browser.ApplyPosition(Math.Max(0,y-24),snippet,_recognized,localCursor/(double)Math.Max(1,chapterText.Length));}catch(Exception e) when(e is InvalidOperationException or COMException){}}
        }else if(!_pure&&ReadingLogic.IsReaderUrl(_browser.Url)){try{var state=await _browser.CaptureState();_settings.Bookmark=new(){Url=_browser.Url,SourceY=BrowserSession.N(state,"current"),Recognized=true};SaveSettings();}catch(Exception e) when(e is InvalidOperationException or COMException){}}
    }
    async Task BeginResume(bool website){await SaveReadingPosition(true);if(_settings.Bookmark is not { } saved)return;ResetOperation();_forceWebsite=website;_pendingRestore=saved;SetMode(false);_browser.Navigate(website?ReadingLogic.BookEntry(saved.Url):saved.Url);}
    async Task RestorePending(){
        if(_pendingRestore is not { } saved)return;_pendingRestore=null;
        await RunBusy(async()=>{
            await StopCurrentFill();_restoring=true;try{
                await _browser.WaitReady(_operation.Token);var state=await _browser.CaptureState();
                if((_forceWebsite||_browser.Url!=saved.Url)&&ReadingLogic.IsReaderUrl(_browser.Url)){_restoring=false;await ReadCurrent();return;}
                await _browser.ApplyPosition(saved.SourceY);
                if(saved.Text.Length>0&&saved.CaptureVersion==ReaderFlowPolicy.CaptureVersion){_text=saved.Text;_chapterUrl=saved.Url;_recognized=saved.Recognized;_anchors.Clear();_anchors.AddRange(saved.Anchors);_sourceBottom=_anchors.Count>0?_anchors.Max(a=>a.SourceY):null;RenderText();SetMode(true);ScrollToCharacter(saved.Cursor);await _browser.Js("window.floatingReaderRestoreKnownRange("+JsonSerializer.Serialize(new{top=_anchors.Count>0?_anchors.Min(a=>a.SourceY):0,bottom=_sourceBottom??saved.SourceY,current=saved.SourceY})+")");SetStatus("已恢复上次浮读位置。");_atChapterEnd=!_recognized;StartCurrentFill();StartNextPreload();}
                else{_restoring=false;await ReadCurrent();}
            }finally{_restoring=false;}
        });
    }
    async Task FlushWebsiteOnExit(Bookmark saved){
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(4));
        if(_browser.Url!=saved.Url){_browser.Navigate(saved.Url);await _browser.WaitReady(timeout.Token);}
        string snippet=saved.Text.Length>0?saved.Text.Substring(Math.Min(saved.Cursor,saved.Text.Length),Math.Min(36,Math.Max(0,saved.Text.Length-saved.Cursor))).Trim():"";
        await _browser.ApplyPosition(saved.SourceY,snippet,saved.Recognized,saved.Cursor/(double)Math.Max(1,saved.Text.Length));await Task.Delay(700,timeout.Token);
    }
    async void OnClosing(object? sender,CancelEventArgs e){
        if(_finalClose)return;e.Cancel=true;if(_closing)return;_closing=true;SetStatus("正在保存阅读位置…");_saveTimer.Stop();CancelBackgroundWork();_operation.Cancel();
        try{await SaveReadingPosition(false).WaitAsync(TimeSpan.FromSeconds(2));if(_settings.Bookmark is { } saved)await FlushWebsiteOnExit(saved).WaitAsync(TimeSpan.FromSeconds(4));}
        catch(Exception error) when(error is InvalidOperationException or TimeoutException or OperationCanceledException or System.Runtime.InteropServices.COMException){SetStatus(error.Message);}
        finally{_finalClose=true;Close();}
    }
    void ShowRuntimeHelp(){var panel=PanelWindow("需要 WebView2 Runtime",420,170);var body=new StackPanel{Margin=new Thickness(18)};body.Children.Add(new TextBlock{Text="请安装 Microsoft Edge WebView2 Evergreen Runtime 后重启浮读。",TextWrapping=TextWrapping.Wrap});var link=new Button{Content="打开微软官方下载页",Margin=new Thickness(0,20,0,0)};link.Click+=(_,_)=>Process.Start(new ProcessStartInfo("https://developer.microsoft.com/microsoft-edge/webview2/"){UseShellExecute=true});body.Children.Add(link);panel.Content=body;panel.Show();}
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd,uint msg,IntPtr wParam,IntPtr lParam);
}
