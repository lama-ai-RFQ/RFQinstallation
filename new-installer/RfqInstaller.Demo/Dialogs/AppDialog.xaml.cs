using System.Windows;
using System.Windows.Input;

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
            Owner = owner,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner
        };
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

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 1)
        {
            DragMove();
        }
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
