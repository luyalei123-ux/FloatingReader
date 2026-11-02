using System.Windows;

namespace FloatingReader.Windows;
public static class Program {
    [STAThread] public static void Main() {
        var app=new Application{ShutdownMode=ShutdownMode.OnMainWindowClose};
        app.DispatcherUnhandledException+=(_,e)=>{MessageBox.Show(e.Exception.Message,"浮读",MessageBoxButton.OK,MessageBoxImage.Error);e.Handled=true;};
        app.Run(new ReaderWindow());
    }
}
