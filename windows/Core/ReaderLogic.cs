using System.Text.Json;
using System.Text.Json.Serialization;

namespace FloatingReader.Core;

public enum ReaderAction { ResetStyle, Diagnostics, Shelf, Back, Mode, Paste, Pin, Theme, Background, FontSize, Font, Ink, Paper, Spacing, Catalog, Previous, Next, Larger, Smaller, Toolbar, Reload, Resume, WebsiteProgress, Shortcuts, Quit }
[Flags] public enum ShortcutModifiers { None=0, Ctrl=1, Alt=2, Shift=4 }
public sealed record Shortcut(string Key, ShortcutModifiers Modifiers) {
    public string CanonicalKey => Key is "OemPlus" or "=" or "+" ? "Plus" : Key;
    public ShortcutModifiers CanonicalModifiers => CanonicalKey == "Plus" ? Modifiers & ~ShortcutModifiers.Shift : Modifiers;
    public bool Matches(Shortcut other) => CanonicalKey == other.CanonicalKey && CanonicalModifiers == other.CanonicalModifiers;
    public string Label => Key.Length == 0 ? "未设置" : (Modifiers.HasFlag(ShortcutModifiers.Ctrl)?"Ctrl+":"")+(Modifiers.HasFlag(ShortcutModifiers.Alt)?"Alt+":"")+(Modifiers.HasFlag(ShortcutModifiers.Shift)?"Shift+":"")+ DisplayKey(CanonicalKey);
    public static string DisplayKey(string key) => key switch { "Plus"=>"+", "OemMinus"=>"−", "OemQuestion"=>"/", "Up"=>"↑", "Down"=>"↓", "OemOpenBrackets"=>"[", "OemCloseBrackets"=>"]", "OemComma"=>",", "D1"=>"1", "D0"=>"0", _=>key };
}
public static class ReaderShortcuts {
    public static Dictionary<ReaderAction, Shortcut> Defaults() => new() {
        [ReaderAction.Diagnostics]=new("",0), [ReaderAction.ResetStyle]=new("",0),
        [ReaderAction.Shelf]=new("D1",ShortcutModifiers.Ctrl), [ReaderAction.Back]=new("Left",ShortcutModifiers.Alt),
        [ReaderAction.Mode]=new("R",ShortcutModifiers.Ctrl), [ReaderAction.Paste]=new("V",ShortcutModifiers.Ctrl),
        [ReaderAction.Pin]=new("P",ShortcutModifiers.Ctrl), [ReaderAction.Theme]=new("T",ShortcutModifiers.Ctrl),
        [ReaderAction.Background]=new("B",ShortcutModifiers.Ctrl), [ReaderAction.FontSize]=new("",0),
        [ReaderAction.Font]=new("F",ShortcutModifiers.Ctrl), [ReaderAction.Ink]=new("K",ShortcutModifiers.Ctrl),
        [ReaderAction.Paper]=new("J",ShortcutModifiers.Ctrl), [ReaderAction.Spacing]=new("H",ShortcutModifiers.Ctrl),
        [ReaderAction.Catalog]=new("D",ShortcutModifiers.Ctrl), [ReaderAction.Previous]=new("Up",ShortcutModifiers.Ctrl),
        [ReaderAction.Next]=new("Down",ShortcutModifiers.Ctrl), [ReaderAction.Larger]=new("Plus",ShortcutModifiers.Ctrl),
        [ReaderAction.Smaller]=new("OemMinus",ShortcutModifiers.Ctrl), [ReaderAction.Toolbar]=new("OemQuestion",ShortcutModifiers.Ctrl),
        [ReaderAction.Reload]=new("L",ShortcutModifiers.Ctrl), [ReaderAction.Resume]=new("",0),
        [ReaderAction.WebsiteProgress]=new("",0), [ReaderAction.Shortcuts]=new("OemComma",ShortcutModifiers.Ctrl),
        [ReaderAction.Quit]=new("Q",ShortcutModifiers.Ctrl)
    };
    public static string Title(ReaderAction a) => a switch {
        ReaderAction.ResetStyle=>"恢复默认阅读样式",ReaderAction.Diagnostics=>"复制阅读诊断",ReaderAction.Shelf=>"书架",ReaderAction.Back=>"后退",ReaderAction.Mode=>"纯文字／原网页",ReaderAction.Paste=>"粘贴文字",ReaderAction.Pin=>"置顶／取消置顶",ReaderAction.Theme=>"深色／浅色",ReaderAction.Background=>"工具栏与背景隐藏／恢复（兼容键）",ReaderAction.FontSize=>"文字大小",ReaderAction.Font=>"文字字体",ReaderAction.Ink=>"文字颜色",ReaderAction.Paper=>"正文背景色",ReaderAction.Spacing=>"行间距",ReaderAction.Catalog=>"章节选择",ReaderAction.Previous=>"上一章",ReaderAction.Next=>"下一章",ReaderAction.Larger=>"增大字号",ReaderAction.Smaller=>"缩小字号",ReaderAction.Toolbar=>"隐藏／恢复工具栏与背景",ReaderAction.Reload=>"重新加载网页",ReaderAction.Resume=>"继续上次浮读位置",ReaderAction.WebsiteProgress=>"跟随微信读书位置",ReaderAction.Shortcuts=>"快捷键设置",ReaderAction.Quit=>"退出",_=>a.ToString()
    };
    public static ReaderAction? Match(Dictionary<ReaderAction,Shortcut> bindings, Shortcut value) {
        foreach(var pair in bindings) if(pair.Value.Key.Length>0 && pair.Value.Matches(value)) return pair.Key;
        return null;
    }
    public static string? Validate(Dictionary<ReaderAction,Shortcut> bindings, ReaderAction action, Shortcut value) {
        if(value.Key.Length==0) return null;
        if(value.CanonicalKey=="C" && value.CanonicalModifiers==ShortcutModifiers.Ctrl) return "Ctrl+C 保留用于复制选中文字。";
        if((value.Modifiers & (ShortcutModifiers.Ctrl|ShortcutModifiers.Alt))==0) return "请包含 Ctrl 或 Alt，避免影响普通输入。";
        if(value.Key=="F4" && value.Modifiers.HasFlag(ShortcutModifiers.Alt)) return "Alt+F4 保留为 Windows 关闭窗口操作。";
        foreach(var pair in bindings) if(pair.Key!=action && pair.Value.Key.Length>0 && pair.Value.Matches(value)) return $"已用于「{Title(pair.Key)}」。请先清除或更换该组合。";
        return null;
    }
}
public sealed record SourceAnchor(int Offset, double SourceY, string Url);
public sealed class Bookmark {
    public int CaptureVersion {get;set;}
    public string Url {get;set;}="";
    public string Text {get;set;}="";
    public int Cursor {get;set;}
    public double SourceY {get;set;}
    public bool Recognized {get;set;}
    public List<SourceAnchor> Anchors {get;set;}=[];
}
public sealed class ReaderSettings {
    public double FontSize {get;set;}=14;
    public double LineHeight {get;set;}=1.4;
    public string FontFamily {get;set;}="";
    public string Ink {get;set;}="#333333";
    public string Paper {get;set;}="#FBF6ED";
    public bool Dark {get;set;}
    public bool Pinned {get;set;}=true;
    public double BackgroundOpacity {get;set;}=1;
    public double LastOpacity {get;set;}=1;
    public bool ToolbarVisible {get;set;}=true;
    public bool UnifiedTransparency {get;set;}
    public bool UnifiedVisibility {get;set;}
    public Dictionary<ReaderAction,Shortcut> Shortcuts {get;set;}=ReaderShortcuts.Defaults();
    public Bookmark? Bookmark {get;set;}
    public void ToggleChrome(){ToolbarVisible=!ToolbarVisible;BackgroundOpacity=ToolbarVisible?1:0;LastOpacity=1;}
    public void Normalize() {
        FontSize=Math.Clamp(double.IsFinite(FontSize)?FontSize:14,12,64);
        LineHeight=Math.Clamp(double.IsFinite(LineHeight)?LineHeight:1.4,1,2.5);
        BackgroundOpacity=Math.Clamp(double.IsFinite(BackgroundOpacity)?BackgroundOpacity:1,0,1);
        LastOpacity=Math.Clamp(double.IsFinite(LastOpacity)?LastOpacity:1,.05,1);
        if(!UnifiedTransparency){if(!ToolbarVisible)BackgroundOpacity=0;UnifiedTransparency=true;}
        if(!UnifiedVisibility){ToolbarVisible=true;UnifiedVisibility=true;}
        BackgroundOpacity=ToolbarVisible?1:0;LastOpacity=1;
        Shortcuts ??= ReaderShortcuts.Defaults();
        foreach(var pair in ReaderShortcuts.Defaults()) Shortcuts.TryAdd(pair.Key,pair.Value);
    }
}
public sealed class SettingsStore(string directory) {
    public string DirectoryPath {get;}=directory;
    public string FilePath => Path.Combine(DirectoryPath,"settings.json");
    static readonly JsonSerializerOptions Options=new(){WriteIndented=true,Converters={new JsonStringEnumConverter()}};
    public ReaderSettings Load() {
        try {var state=File.Exists(FilePath)?JsonSerializer.Deserialize<ReaderSettings>(File.ReadAllText(FilePath),Options):null;state??=new();state.Normalize();return state;}
        catch(Exception e) when(e is IOException or JsonException or UnauthorizedAccessException){return new();}
    }
    public void Save(ReaderSettings state) {
        Directory.CreateDirectory(DirectoryPath);var temporary=FilePath+".tmp";
        File.WriteAllText(temporary,JsonSerializer.Serialize(state,Options));File.Move(temporary,FilePath,true);
    }
}
public static class ReadingLogic {
    public static bool IsReaderUrl(string? value) => Uri.TryCreate(value,UriKind.Absolute,out var u)&&u.Scheme=="https"&&u.Host=="weread.qq.com"&&u.AbsolutePath.StartsWith("/web/reader/",StringComparison.Ordinal);
    public static string BookEntry(string value) {
        if(!IsReaderUrl(value))return "https://weread.qq.com/";
        var builder=new UriBuilder(value){Query="",Fragment=""};builder.Path=System.Text.RegularExpressions.Regex.Replace(builder.Path,"k[0-9a-f]+$","");return builder.Uri.AbsoluteUri;
    }
    public static bool CompleteLine(double top,double bottom,double viewportHeight,double rowHeight,double sourceY,bool atEnd) {
        var margin=Math.Max(12,rowHeight*.65);
        return !(sourceY>2&&top<margin) && !(!atEnd&&viewportHeight-bottom<margin);
    }
    public static Bookmark ChapterBookmark(string text,int cursor,double sourceY,bool recognized,IReadOnlyList<SourceAnchor> anchors,string fallbackUrl){
        cursor=Math.Clamp(cursor,0,text.Length);
        var anchor=anchors.LastOrDefault(a=>a.Offset<=cursor)??anchors.FirstOrDefault();
        string url=anchor?.Url??fallbackUrl;
        int start=anchors.Where(a=>a.Url==url).Select(a=>a.Offset).DefaultIfEmpty(0).Min();
        int end=anchors.Where(a=>a.Offset>start&&a.Url!=url).Select(a=>a.Offset).DefaultIfEmpty(text.Length).Min();
        start=Math.Clamp(start,0,text.Length);end=Math.Clamp(end,start,text.Length);
        return new(){CaptureVersion=ReaderFlowPolicy.CaptureVersion,Url=url,Text=text[start..end],Cursor=Math.Clamp(cursor-start,0,end-start),SourceY=sourceY,Recognized=recognized,Anchors=anchors.Where(a=>a.Url==url&&a.Offset>=start&&a.Offset<end).Select(a=>a with {Offset=a.Offset-start}).ToList()};
    }
    public static string AppendExact(string before,string after) {
        if(string.IsNullOrWhiteSpace(after)||before.Contains(after,StringComparison.Ordinal))return before;
        var a=before.Where(c=>!char.IsWhiteSpace(c)).ToArray();var b=after.Where(c=>!char.IsWhiteSpace(c)).ToArray();
        if(b.Length==0)return before;
        var prefix=new int[b.Length];for(int i=1,j=0;i<b.Length;i++){while(j>0&&b[i]!=b[j])j=prefix[j-1];if(b[i]==b[j])j++;prefix[i]=j;}
        int n=0;foreach(var c in a){if(n==b.Length)n=prefix[n-1];while(n>0&&c!=b[n])n=prefix[n-1];if(c==b[n])n++;}
        if(n<12)n=0;
        int index=0,count=0;while(index<after.Length&&count<n){if(!char.IsWhiteSpace(after[index]))count++;index++;}
        var tail=after[index..].Trim();return tail.Length==0?before:before+"\n\n"+tail;
    }
}

public static class ReaderFlowPolicy {
    public const int CaptureVersion=3;
    public static bool CanUsePrefetch(string owner,string current,string target)=>owner==current&&ReadingLogic.IsReaderUrl(current)&&ReadingLogic.IsReaderUrl(target)&&new Uri(target).AbsolutePath!=new Uri(current).AbsolutePath&&ReadingLogic.BookEntry(target)==ReadingLogic.BookEntry(current);
    public static bool ShouldAutoRead(bool pure,string url,string manualRaw)=>!pure&&ReadingLogic.IsReaderUrl(url)&&url!=manualRaw;
    public static bool ChromeVisible(double opacity)=>opacity>0;
    public static double BrightnessFromDarkness(double value)=>1-Math.Clamp(value,0,1);
    public static bool CanAppend(string chapterUrl,string captureUrl)=>chapterUrl.Length>0&&chapterUrl==captureUrl;
    public static bool ShouldContinue(bool pure,bool busy,bool paused,bool catalog,double verticalChange,double offset,double extent,double viewport)
        =>pure&&!busy&&!paused&&!catalog&&verticalChange>0&&offset>=Math.Max(0,extent-viewport-120);
}
