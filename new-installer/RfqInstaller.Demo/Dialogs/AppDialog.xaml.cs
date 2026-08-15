using System.Windows;

namespace RfqInstaller.Demo.Dialogs;

public partial class AppDialog : Window
{
    private enum Choice
    {
        Dismissed,
        Primary,
        Secondary
    }

    private Choice _choice = Choice.Dismissed;

    private AppDialog()
    {
        InitializeComponent();
    }

    public static bool Confirm(Window? owner, string heading, string message, string confirmText, string dismissText)
    {
        var dialog = Create(owner, heading, message, primaryText: dismissText, secondaryText: confirmText);
        dialog.ShowDialog();
        return dialog._choice == Choice.Secondary;
    }

    public static void Inform(Window? owner, string heading, string message)
    {
        var dialog = Create(owner, heading, message, primaryText: "OK");
        dialog.SecondaryButton.Visibility = Visibility.Collapsed;
        dialog.ShowDialog();
    }

    private static AppDialog Create(Window? owner, string heading, string message, string primaryText, string? secondaryText = null)
    {
        var dialog = new AppDialog
        {
            Owner = owner
        };
        dialog.CoverOwner(owner);
        dialog.HeadingText.Text = heading;
        dialog.MessageText.Text = message;
        dialog.PrimaryButton.Content = primaryText;
        if (secondaryText is null)
        {
            dialog.SecondaryButton.Visibility = Visibility.Collapsed;
        }
        else
        {
            dialog.SecondaryButton.Content = secondaryText;
        }

        return dialog;
    }

    private void CoverOwner(Window? owner)
    {
        if (owner is null)
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Width = 1000;
            Height = 660;
            return;
        }

        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = owner.Left;
        Top = owner.Top;
        Width = owner.ActualWidth;
        Height = owner.ActualHeight;
    }

    private void Primary_Click(object sender, RoutedEventArgs e)
    {
        _choice = Choice.Primary;
        DialogResult = true;
    }

    private void Secondary_Click(object sender, RoutedEventArgs e)
    {
        _choice = Choice.Secondary;
        DialogResult = true;
    }

    private void Dismiss_Click(object sender, RoutedEventArgs e)
    {
        _choice = Choice.Dismissed;
        DialogResult = false;
    }
}
