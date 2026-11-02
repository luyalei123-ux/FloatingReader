using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using FloatingReader.Core;

namespace FloatingReader.Windows;
public sealed partial class ReaderWindow {
    readonly Dictionary<Window,Action> _panelRefresh=[];
    ReaderAction? _recording;
    TextBlock? _shortcutNotice;
    readonly Dictionary<ReaderAction,Button> _shortcutButtons=[];
    bool _catalogOpen;
    bool ActivatePanel(string title){var p=_panels.FirstOrDefault(p=>p.Title==title);if(p is null)return false;p.Activate();return true;}
    Window PanelWindow(string title,double width,double height){var panel=new Window{Title=title,Width=width,Height=height,Owner=this,Topmost=Topmost,WindowStartupLocation=WindowStartupLocation.CenterOwner,ResizeMode=ResizeMode.CanResizeWithGrip,MinWidth=250,MinHeight=120,Background=new SolidColorBrush(Color.FromRgb(246,246,246)),Foreground=Brushes.Black};_panels.Add(panel);panel.PreviewKeyDown+=OnShortcut;panel.Closed+=(_,_)=>{_panels.Remove(panel);_panelRefresh.Remove(panel);if(title=="快捷键设置"){_recording=null;_shortcutButtons.Clear();}};return panel;}
    void ShowSlider(string title,double minimum,double maximum,double current,Action<double> changed){
        if(ActivatePanel(title))return;var panel=PanelWindow(title,320,150);panel.ResizeMode=ResizeMode.NoResize;
        var body=new StackPanel{Margin=new Thickness(20)};var value=new TextBlock{Margin=new Thickness(0,0,0,12)};var slider=new Slider{Minimum=minimum,Maximum=maximum,Value=current,IsSnapToTickEnabled=title=="文字大小",TickFrequency=1};bool updating=false;
        void Refresh(){updating=true;double v=title=="文字大小"?_settings.FontSize:_settings.LineHeight;slider.Value=v;value.Text=title=="文字大小"?$"{v:0} pt":$"{v:0.00} 倍";updating=false;}
        slider.ValueChanged+=(_,_)=>{if(!updating){changed(slider.Value);Refresh();}};_panelRefresh[panel]=Refresh;Refresh();body.Children.Add(value);body.Children.Add(slider);panel.Content=body;panel.Show();
    }
    void ShowColors(bool paper){
        string title=paper?"正文背景色":"文字颜色";if(ActivatePanel(title))return;
        var panel=PanelWindow(title,330,500);panel.ResizeMode=ResizeMode.NoResize;
        var body=new StackPanel{Margin=new Thickness(18)};
        var wheel=new ColorWheel{Width=256,Height=256,HorizontalAlignment=HorizontalAlignment.Center};body.Children.Add(wheel);
        var brightness=new Slider{Minimum=0,Maximum=1,Margin=new Thickness(0,16,0,12),Background=new LinearGradientBrush(Colors.White,Colors.Black,0),IsMoveToPointEnabled=true};brightness.Template=(ControlTemplate)System.Windows.Markup.XamlReader.Parse("""
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="{x:Type Slider}">
          <Grid Height="24">
            <Border Height="8" Margin="6,0" CornerRadius="4" VerticalAlignment="Center" BorderBrush="#999999" BorderThickness="0.5">
              <Border.Background><LinearGradientBrush StartPoint="0,0.5" EndPoint="1,0.5"><GradientStop Color="White" Offset="0"/><GradientStop Color="Black" Offset="1"/></LinearGradientBrush></Border.Background>
            </Border>
            <Track x:Name="PART_Track" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}">
              <Track.DecreaseRepeatButton><RepeatButton Command="{x:Static Slider.DecreaseLarge}" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Command="{x:Static Slider.IncreaseLarge}" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb Width="12" Height="22"><Thumb.Template><ControlTemplate TargetType="{x:Type Thumb}"><Border Background="#FAFAFA" BorderBrush="#666666" BorderThickness="1" CornerRadius="3"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
            </Track>
          </Grid>
        </ControlTemplate>
        """);body.Children.Add(brightness);
        var row=new DockPanel();var preview=new Border{Width=34,Height=28,CornerRadius=new CornerRadius(5),BorderBrush=Brushes.Gray,BorderThickness=new Thickness(1),Margin=new Thickness(0,0,10,0)};row.Children.Add(preview);
        var hex=new TextBox{FontFamily=new FontFamily("Consolas"),Foreground=Brushes.Black,Background=Brushes.White,VerticalContentAlignment=VerticalAlignment.Center};row.Children.Add(hex);body.Children.Add(row);
        var swatches=new WrapPanel{Margin=new Thickness(0,16,0,0)};body.Children.Add(swatches);bool updating=false;
        void Refresh(){updating=true;var c=ParseColor(paper?_settings.Paper:_settings.Ink,Colors.White);wheel.SetColor(c);brightness.Value=1-wheel.Brightness;preview.Background=new SolidColorBrush(c);hex.Text=$"#{c.R:X2}{c.G:X2}{c.B:X2}";updating=false;}
        void Commit(Color c){if(!panel.IsVisible||!_panels.Contains(panel))return;if(paper)_settings.Paper=$"#{c.R:X2}{c.G:X2}{c.B:X2}";else _settings.Ink=$"#{c.R:X2}{c.G:X2}{c.B:X2}";ApplyStyle();}
        wheel.Changed+=c=>{if(!updating)Commit(c);};brightness.ValueChanged+=(_,_)=>{if(!updating){wheel.Brightness=ReaderFlowPolicy.BrightnessFromDarkness(brightness.Value);Commit(wheel.Current);}};
        hex.TextChanged+=(_,_)=>{if(!updating&&Regex.IsMatch(hex.Text,"^#[0-9A-Fa-f]{6}$"))Commit(ParseColor(hex.Text,Colors.White));};
        foreach(var value in new[]{"#FFFFFF","#FBF6ED","#333333","#666666","#E8DFC9","#D6E5D8","#E5E5E5","#B3B3B3","#808080","#404040","#191919","#000000","#FF453A","#FF9F0A","#FFD60A","#32D74B","#64D2FF","#0A84FF","#BF5AF2","#FF375F"}){var color=ParseColor(value,Colors.White);var chip=new Button{Width=29,Height=25,Margin=new Thickness(2),Background=new SolidColorBrush(color),BorderBrush=Brushes.Gray,BorderThickness=new Thickness(1),ToolTip=value};chip.Click+=(_,_)=>Commit(color);swatches.Children.Add(chip);}
        _panelRefresh[panel]=Refresh;Refresh();panel.Content=body;panel.Show();
    }
    void ShowFonts(){
        if(ActivatePanel("文字字体"))return;var panel=PanelWindow("文字字体",400,420);var body=new DockPanel{Margin=new Thickness(16)};var search=new TextBox{Margin=new Thickness(0,0,0,12),Foreground=Brushes.Black,Background=Brushes.White};DockPanel.SetDock(search,Dock.Top);body.Children.Add(search);
        var fonts=Fonts.SystemFontFamilies.Select(f=>f.Source).OrderBy(s=>s,StringComparer.CurrentCulture).ToList();var list=new ListBox{ItemsSource=fonts,SelectedItem=string.IsNullOrWhiteSpace(_settings.FontFamily)?SystemFonts.MessageFontFamily.Source:_settings.FontFamily,Foreground=Brushes.Black,Background=Brushes.White};search.TextChanged+=(_,_)=>list.ItemsSource=fonts.Where(f=>f.Contains(search.Text,StringComparison.CurrentCultureIgnoreCase)).ToList();list.SelectionChanged+=(_,_)=>{if(list.SelectedItem is string font){_settings.FontFamily=font;ApplyStyle();}};body.Children.Add(list);panel.Content=body;panel.Show();list.ScrollIntoView(_settings.FontFamily);
    }
    void OnShortcut(object? sender,KeyEventArgs e){
        if(e.Handled||_closing)return;var key=e.Key==Key.System?e.SystemKey:e.Key;var mods=Keyboard.Modifiers;var flags=(mods.HasFlag(ModifierKeys.Control)?ShortcutModifiers.Ctrl:0)|(mods.HasFlag(ModifierKeys.Alt)?ShortcutModifiers.Alt:0)|(mods.HasFlag(ModifierKeys.Shift)?ShortcutModifiers.Shift:0);
        if(_recording is ReaderAction recording){
            if(key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)return;e.Handled=true;
            if(key==Key.Escape){_recording=null;RefreshShortcutButtons();return;}
            if(mods.HasFlag(ModifierKeys.Windows)){if(_shortcutNotice is not null)_shortcutNotice.Text="Win 组合保留给 Windows，请改用 Ctrl 或 Alt。";return;}
            var value=(key is Key.Delete or Key.Back)&&flags==0?new Shortcut("",0):new Shortcut(key.ToString(),flags);var error=ReaderShortcuts.Validate(_settings.Shortcuts,recording,value);if(error is not null){if(_shortcutNotice is not null)_shortcutNotice.Text=error;return;}
            _settings.Shortcuts[recording]=value;_recording=null;RefreshShortcutButtons();SaveSettings();if(_shortcutNotice is not null)_shortcutNotice.Text="已保存，立即生效。";return;
        }
        if(mods==ModifierKeys.Control&&key==Key.C){if(Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase) return;if(_pure&&!_reader.Selection.IsEmpty){_reader.Copy();e.Handled=true;}return;}
        if(Keyboard.FocusedElement is TextBox&&mods.HasFlag(ModifierKeys.Control)&&key is Key.A or Key.C or Key.V or Key.X or Key.Z or Key.Y)return;
        if(!_pure&&mods.HasFlag(ModifierKeys.Control)&&key is Key.A or Key.C or Key.V or Key.X or Key.Z or Key.Y)return;
        if(key==Key.F4&&mods.HasFlag(ModifierKeys.Alt))return;
        if(ReaderShortcuts.Match(_settings.Shortcuts,new(key.ToString(),flags)) is not ReaderAction action)return;e.Handled=true;_ = Execute(action);
    }
    void RefreshShortcutButtons(){foreach(var pair in _shortcutButtons)pair.Value.Content=_settings.Shortcuts[pair.Key].Label;ApplyStyle();}
    void ShowShortcuts(){
        if(ActivatePanel("快捷键设置"))return;var panel=PanelWindow("快捷键设置",570,560);var body=new DockPanel{Margin=new Thickness(18)};var header=new TextBlock{Text="点击右侧组合键，然后按新快捷键。Esc 取消，Delete 清除。",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,12)};DockPanel.SetDock(header,Dock.Top);body.Children.Add(header);
        var bottom=new StackPanel();_shortcutNotice=new TextBlock{Text="Ctrl / Alt / Shift 为 Windows 组合键；Alt+F4 保留系统关闭。",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,10,0,10)};bottom.Children.Add(_shortcutNotice);var reset=new Button{Content="恢复默认",Padding=new Thickness(10,5,10,5),HorizontalAlignment=HorizontalAlignment.Left,Foreground=Brushes.Black};reset.Click+=(_,_)=>{_settings.Shortcuts=ReaderShortcuts.Defaults();_recording=null;RefreshShortcutButtons();SaveSettings();};bottom.Children.Add(reset);DockPanel.SetDock(bottom,Dock.Bottom);body.Children.Add(bottom);
        var rows=new StackPanel();_shortcutButtons.Clear();foreach(var action in Enum.GetValues<ReaderAction>().Where(a=>a is not ReaderAction.Paste and not ReaderAction.Theme)){
            var row=new DockPanel{Margin=new Thickness(0,4,0,4)};var button=new Button{Content=_settings.Shortcuts[action].Label,Width=160,Padding=new Thickness(5),Foreground=Brushes.Black};DockPanel.SetDock(button,Dock.Right);row.Children.Add(button);row.Children.Add(new TextBlock{Text=ReaderShortcuts.Title(action),VerticalAlignment=VerticalAlignment.Center});rows.Children.Add(row);_shortcutButtons[action]=button;
            button.Click+=(_,_)=>{_recording=null;RefreshShortcutButtons();_recording=action;button.Content="按新快捷键…";_shortcutNotice.Text="正在修改「"+ReaderShortcuts.Title(action)+"」";};
        }
        body.Children.Add(new ScrollViewer{Content=rows,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});panel.Content=body;panel.Show();
    }
    sealed record ChapterItem(int Index,string Label){public override string ToString()=>Label;}
    async Task ClickCatalogButton(string expression){var b=await _browser.Js(expression);if(b.ValueKind!=JsonValueKind.Object)throw new InvalidOperationException("没有找到可点击的目录入口，请返回原网页打开目录。");await _browser.Click(BrowserSession.N(b,"x"),BrowserSession.N(b,"y"));}
    async Task ShowCatalog(){
        if(_catalogOpen)return;CancelBackgroundWork();await StopCurrentFill();if(!ReadingLogic.IsReaderUrl(_browser.Url))throw new InvalidOperationException("请先打开一本书。");
        var rows=await _browser.Js("window.floatingReaderCatalogRows()");if(rows.ValueKind!=JsonValueKind.Array||rows.GetArrayLength()==0){await ClickCatalogButton("window.floatingReaderCatalogButton()");await Task.Delay(400,_operation.Token);rows=await _browser.Js("window.floatingReaderCatalogRows()");}if(rows.ValueKind!=JsonValueKind.Array||rows.GetArrayLength()==0)throw new InvalidOperationException("当前网页目录尚未读取到，请返回原网页检查。");
        var chapters=rows.EnumerateArray().Select(e=>new ChapterItem((int)BrowserSession.N(e,"index"),BrowserSession.S(e,"label"))).ToList();var panel=PanelWindow("章节选择",440,500);var body=new DockPanel{Margin=new Thickness(15)};var search=new TextBox{Margin=new Thickness(0,0,0,12),Foreground=Brushes.Black,Background=Brushes.White};DockPanel.SetDock(search,Dock.Top);body.Children.Add(search);var list=new ListBox{ItemsSource=chapters,Foreground=Brushes.Black,Background=Brushes.White};body.Children.Add(list);search.TextChanged+=(_,_)=>list.ItemsSource=chapters.Where(c=>c.Label.Contains(search.Text,StringComparison.CurrentCultureIgnoreCase)).ToList();
        bool selecting=false;async Task Open(){if(list.SelectedItem is not ChapterItem item)return;selecting=true;panel.Close();await RunBusy(()=>Chapter("catalog:"+item.Index));}list.MouseDoubleClick+=async(_,_)=>await Open();var open=new Button{Content="打开选中章节",Padding=new Thickness(8),Margin=new Thickness(0,10,0,0),Foreground=Brushes.Black};open.Click+=async(_,_)=>await Open();DockPanel.SetDock(open,Dock.Bottom);body.Children.Insert(1,open);
        panel.Closed+=async(_,_)=>{_catalogOpen=false;if(!selecting){try{await ClickCatalogButton("window.floatingReaderCatalogCloseButton()");}catch(InvalidOperationException){}StartCurrentFill();StartNextPreload();}};_catalogOpen=true;panel.Content=body;panel.Show();
    }
}
