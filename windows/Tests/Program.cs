using FloatingReader.Core;

int checks=0;
void Check(bool value,string message){if(!value)throw new Exception(message);checks++;}
var defaults=ReaderShortcuts.Defaults();
Check(ReaderShortcuts.Validate(defaults,ReaderAction.Pin,new("C",ShortcutModifiers.Ctrl)) is not null,"Ctrl+C reserved for copy");
Check(defaults[ReaderAction.Mode].Label=="Ctrl+R","Windows mode shortcut must use Ctrl");
Check(defaults[ReaderAction.Toolbar].Label=="Ctrl+/","Windows toolbar shortcut");
Check(defaults.Values.All(v=>!v.Label.Contains('⌘')),"No Command symbols on Windows");
Check(ReaderShortcuts.Match(defaults,new("OemPlus",ShortcutModifiers.Ctrl))==ReaderAction.Larger,"Ctrl+= enlarges font");
Check(ReaderShortcuts.Match(defaults,new("OemPlus",ShortcutModifiers.Ctrl|ShortcutModifiers.Shift))==ReaderAction.Larger,"Ctrl+Shift+= enlarges font");
Check(ReaderShortcuts.Match(defaults,new("Up",ShortcutModifiers.Ctrl))==ReaderAction.Previous,"Ctrl+Up previous chapter");
Check(ReaderShortcuts.Validate(defaults,ReaderAction.Mode,new("K",ShortcutModifiers.Ctrl)) is not null,"Duplicate shortcut rejected");
Check(ReaderShortcuts.Validate(defaults,ReaderAction.Mode,new("F4",ShortcutModifiers.Alt)) is not null,"Windows Alt+F4 preserved");
Check(ReaderShortcuts.Validate(defaults,ReaderAction.Mode,new("R",0)) is not null,"Ordinary input not intercepted");
defaults[ReaderAction.Mode]=new("M",ShortcutModifiers.Ctrl|ShortcutModifiers.Alt);
Check(ReaderShortcuts.Match(defaults,new("R",ShortcutModifiers.Ctrl)) is null,"Old shortcut disabled");
Check(ReaderShortcuts.Match(defaults,new("M",ShortcutModifiers.Ctrl|ShortcutModifiers.Alt))==ReaderAction.Mode,"New shortcut active");
defaults[ReaderAction.Mode]=new("",0);Check(ReaderShortcuts.Match(defaults,new("M",ShortcutModifiers.Ctrl|ShortcutModifiers.Alt)) is null,"Shortcut clear");
Check(ReaderShortcuts.Defaults()[ReaderAction.Mode].Key=="R","Restore defaults");
string root=Path.Combine(Path.GetTempPath(),"FloatingReader.Tests-"+Guid.NewGuid());
try{
 var store=new SettingsStore(root);var state=new ReaderSettings{Shortcuts=defaults,FontSize=30,BackgroundOpacity=.3,Bookmark=new(){Url="https://weread.qq.com/web/reader/abc123k456",SourceY=600,Cursor=120,Text="本地书签正文"}};store.Save(state);
 var loaded=store.Load();Check(loaded.FontSize==30&&loaded.BackgroundOpacity==1,"Style persistence");Check(loaded.Shortcuts[ReaderAction.Mode].Key.Length==0,"Shortcut persistence");Check(loaded.Bookmark?.SourceY==600&&loaded.Bookmark.Text=="本地书签正文","Bookmark roundtrip");
 state.FontSize=double.NaN;state.LineHeight=100;state.BackgroundOpacity=-1;state.Normalize();Check(state.FontSize==14&&state.LineHeight==2.5&&state.BackgroundOpacity==1,"Invalid ranges normalized");
 File.WriteAllText(store.FilePath,"{bad json");Check(store.Load().FontSize==14,"Corrupt settings recover");
}finally{if(Directory.Exists(root))Directory.Delete(root,true);}
Check(ReadingLogic.IsReaderUrl("https://weread.qq.com/web/reader/abc123"),"Known reading host");
Check(!ReadingLogic.IsReaderUrl("https://weread.qq.com.evil.invalid/web/reader/test"),"Host suffix rejected");
Check(ReadingLogic.BookEntry("https://weread.qq.com/web/reader/abc123k456")=="https://weread.qq.com/web/reader/abc123","Chapter route to book entry");
Check(!ReadingLogic.CompleteLine(1780,1799,1800,19,0,false),"Partial bottom row deferred");
Check(ReadingLogic.CompleteLine(300,330,1800,30,1440,false),"Complete overlap row eligible");
Check(!ReadingLogic.CompleteLine(1,20,1800,19,1440,false),"Partial top row deferred");
string passage=string.Concat(Enumerable.Repeat("超过一千五百字的大段重复正文测试。",300));
Check(ReadingLogic.AppendExact("prefix"+passage,passage+"tail")=="prefix"+passage+"\n\ntail","Large overlap removed without 1500 character limit");
Check(ReadingLogic.AppendExact(passage,passage)==passage,"Identical capture ignored");
Check(ReadingLogic.AppendExact("one unique sentence","another unique sentence").EndsWith("another unique sentence"),"New content retained");
Check(ReaderFlowPolicy.CanAppend("chapter-a","chapter-a"),"Current chapter capture retained");
Check(!ReaderFlowPolicy.CanAppend("chapter-a","chapter-b"),"Different chapter must never be appended");
Check(ReaderFlowPolicy.ShouldContinue(true,false,false,false,20,800,1000,100),"Near-bottom user scroll continues reading");
Check(!ReaderFlowPolicy.ShouldContinue(true,true,false,false,20,800,1000,100),"Busy capture cannot start a concurrent capture");
Check(!ReaderFlowPolicy.ShouldContinue(true,false,false,false,0,800,1000,100),"Layout change must not switch chapters");
Check(!ReaderFlowPolicy.ShouldContinue(true,false,true,false,20,800,1000,100),"Paused automatic reading stays paused");
Check(!ReaderFlowPolicy.ShouldContinue(false,false,false,false,20,800,1000,100),"Website scroll stays in website mode");
Check(ReaderFlowPolicy.ChromeVisible(.3),"Partial opacity keeps controls available");
Check(!ReaderFlowPolicy.ChromeVisible(0),"Zero opacity hides controls and background together");
Check(ReaderFlowPolicy.BrightnessFromDarkness(0)==1,"Picker left endpoint is light");
Check(ReaderFlowPolicy.BrightnessFromDarkness(1)==0,"Picker right endpoint is black");
var legacy=new ReaderSettings{ToolbarVisible=false,BackgroundOpacity=.7};legacy.Normalize();Check(legacy.BackgroundOpacity==1&&legacy.ToolbarVisible,"Old opacity migrates to visible binary controls");
var fresh=new ReaderSettings();
Check(fresh.FontSize==14&&fresh.LineHeight==1.4,"First-use font size and spacing");
Check(fresh.Ink=="#333333"&&fresh.Paper=="#FBF6ED","First-use text and paper colors");
Check(fresh.FontFamily.Length==0,"Empty font sentinel selects actual OS message font");
string current="https://weread.qq.com/web/reader/abc123k111",next="https://weread.qq.com/web/reader/abc123k222";
Check(ReaderFlowPolicy.CanUsePrefetch(current,current,next),"Ready adjacent cache is accepted for the exact source chapter");
Check(!ReaderFlowPolicy.CanUsePrefetch(current,next,next),"Stale source chapter cache rejected");
Check(!ReaderFlowPolicy.CanUsePrefetch(current,current,current),"Same chapter never mistaken for next");
Check(!ReaderFlowPolicy.CanUsePrefetch(current,current,current+"#other"),"Fragment-only change is not a new chapter");
Check(!ReaderFlowPolicy.CanUsePrefetch(current,current,"https://weread.qq.com/web/reader/def456k222"),"Other book cache rejected");
Check(ReaderFlowPolicy.ShouldAutoRead(false,current,""),"Opening a book auto-enters plain text");
Check(!ReaderFlowPolicy.ShouldAutoRead(false,"https://weread.qq.com/",""),"Bookshelf stays a webpage");
Check(!ReaderFlowPolicy.ShouldAutoRead(false,current,current),"Explicit raw-mode choice respected");
Check(!ReaderFlowPolicy.ShouldAutoRead(true,current,""),"Already plain text does not start duplicate recognition");
var palette=new ReaderSettings{Ink="#686868",Paper="#E8DFC9",UnifiedVisibility=true,UnifiedTransparency=true};
for(int i=0;i<100;i++){
 palette.ToggleChrome();Check(!palette.ToolbarVisible&&palette.BackgroundOpacity==0,"Chrome hides together");
 palette.Normalize();Check(palette.Ink=="#686868"&&palette.Paper=="#E8DFC9","Hide retains independent palette");
 palette.ToggleChrome();Check(palette.ToolbarVisible&&palette.BackgroundOpacity==1,"Chrome restores fully");
 Check(palette.Ink=="#686868"&&palette.Paper=="#E8DFC9","Show retains independent palette");
}
var temporary=new SettingsStore(Path.Combine(Path.GetTempPath(),"FloatingReader-palette-"+Guid.NewGuid()));
try{temporary.Save(palette);var reopened=temporary.Load();Check(reopened.Ink==palette.Ink&&reopened.Paper==palette.Paper,"Reopened picker starts at persisted colors");}
finally{Directory.Delete(temporary.DirectoryPath,true);}
Check(ReaderFlowPolicy.CaptureVersion==3,"Old wrapped caches must be reread");
var streamAnchors=new List<SourceAnchor>{new(0,0,current),new(5,100,current),new(12,0,next),new(16,100,next)};
var stream="第一章文字内容结束。\n\n第二章新的内容。";
var firstSaved=ReadingLogic.ChapterBookmark(stream,4,20,true,streamAnchors,next);
Check(firstSaved.Url==current&&firstSaved.Text==stream[..12]&&firstSaved.Cursor==4,"Scrolling back through continuous history saves visible chapter");
var nextSaved=ReadingLogic.ChapterBookmark(stream,16,100,true,streamAnchors,next);
Check(nextSaved.Url==next&&nextSaved.Text==stream[12..]&&nextSaved.Cursor==4,"Continuous next chapter saves only its own text");
Check(nextSaved.Anchors.All(a=>a.Url==next)&&nextSaved.Anchors[0].Offset==0,"Continuous bookmark rebases chapter anchors");
Console.WriteLine($"Windows core: {checks} checks passed (Ctrl shortcuts, conflict handling, persistence, bookmark, OCR boundaries, overlap).");
