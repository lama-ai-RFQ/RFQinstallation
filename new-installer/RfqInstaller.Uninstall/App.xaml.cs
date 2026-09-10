using System.IO;
using System.Windows;

namespace RfqInstaller.Uninstall;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += (_, args) =>
        {
            File.WriteAllText(Path.Combine(Path.GetTempPath(), "rfq-uninstall-crash.log"), args.Exception.ToString());
            args.Handled = true;
        };
        base.OnStartup(e);
    }
}
