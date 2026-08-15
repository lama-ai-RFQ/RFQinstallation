using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using RfqInstaller.Demo.Dialogs;
using RfqInstaller.Demo.Logging;

namespace RfqInstaller.Demo;

/// <summary>
/// Interaction logic for App.xaml
/// </summary>
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
        base.OnStartup(e);
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        e.Handled = true;
        ReportFatal(e.Exception, "an unexpected error");
    }

    private void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        var exception = e.ExceptionObject as Exception
            ?? new Exception(e.ExceptionObject.ToString() ?? "Unknown error");
        ReportFatal(exception, "a fatal error");
    }

    private void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        e.SetObserved();
        ReportFatal(e.Exception, "a background task");
    }

    private void ReportFatal(Exception exception, string context)
    {
        void Show()
        {
            if (MainWindow is MainWindow window)
            {
                window.ReportFatalError(exception, context);
                return;
            }

            var logPath = InstallerLog.Write(context, exception);
            try
            {
                AppDialog.Inform(
                    null,
                    "Setup couldn't continue",
                    $"RFQ Application Setup hit an unexpected error while {context} and had to stop."
                    + $"{Environment.NewLine}{Environment.NewLine}{InstallerLog.FormatUserDetail(exception)}"
                    + $"{Environment.NewLine}{Environment.NewLine}A detailed log was saved to:{Environment.NewLine}{logPath}");
            }
            catch
            {
                // Last resort: we already wrote the log.
            }

            Shutdown();
        }

        if (Dispatcher.CheckAccess())
        {
            Show();
        }
        else
        {
            Dispatcher.Invoke(Show);
        }
    }
}
