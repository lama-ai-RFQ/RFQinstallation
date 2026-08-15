using System;
using System.Configuration;
using System.Data;
using System.IO;
using System.Windows;
using System.Windows.Threading;

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
        base.OnStartup(e);
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        File.WriteAllText(
            Path.Combine(AppContext.BaseDirectory, "crash.log"),
            e.Exception.ToString());
        e.Handled = true;
    }

    private void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        File.WriteAllText(
            Path.Combine(AppContext.BaseDirectory, "crash.log"),
            (e.ExceptionObject as Exception)?.ToString() ?? e.ExceptionObject.ToString() ?? "unknown");
    }
}

