using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using RfqInstaller.Core.Security;
using RfqInstaller.Logging;

namespace RfqInstaller.Dialogs;

/// <summary>
/// Repair's password tool: shows each password the install keeps (the postgres superuser, the
/// rfq_user database login and the Settings page password) and sets a new one. Never shown at the
/// end of an install; only from Repair, which runs elevated as the account that can read them.
/// </summary>
public partial class PasswordsDialog : Window
{
    private readonly string _installPath;
    private bool _busy;

    private PasswordsDialog(string installPath)
    {
        InitializeComponent();
        _installPath = installPath;
        BuildRows();
    }

    public static void Show(Window? owner, string installPath)
    {
        var dialog = new PasswordsDialog(installPath) { Owner = owner };
        if (owner is null)
        {
            dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
            dialog.Width = 1000;
            dialog.Height = 700;
        }
        else
        {
            dialog.WindowStartupLocation = WindowStartupLocation.Manual;
            dialog.Left = owner.Left;
            dialog.Top = owner.Top;
            dialog.Width = owner.ActualWidth;
            dialog.Height = owner.ActualHeight;
        }

        dialog.ShowDialog();
    }

    private static readonly (ManagedPassword Which, string EnvKey)[] Order =
    {
        (ManagedPassword.Settings, "SETTINGS_PASSWORD"),
        (ManagedPassword.AppUser, "RFQ_USER_PASSWORD"),
        (ManagedPassword.SuperUser, "SQL_SUPER_USER"),
    };

    private void BuildRows()
    {
        RowsPanel.Children.Clear();
        List<StoredCredential> credentials;
        try
        {
            credentials = StoredCredentialsResolver.ResolveAll(_installPath);
        }
        catch (Exception ex)
        {
            RowsPanel.Children.Add(Text($"Couldn't read the stored passwords: {ex.Message}", error: true));
            return;
        }

        foreach (var (which, envKey) in Order)
        {
            var credential = credentials.FirstOrDefault(c => c.EnvKey == envKey);
            if (credential is not null)
            {
                RowsPanel.Children.Add(BuildRow(which, credential));
            }
        }
    }

    private UIElement BuildRow(ManagedPassword which, StoredCredential credential)
    {
        var container = new StackPanel { Margin = new Thickness(0, 0, 0, 20) };
        container.Children.Add(new TextBlock
        {
            Text = credential.DisplayName,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("TextPrimaryBrush"),
        });

        var valueRow = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        valueRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < 3; i++)
        {
            valueRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }

        var masked = credential.Value is null ? "" : new string('•', Math.Min(credential.Value.Length, 24));
        var valueBox = new TextBox
        {
            Text = credential.Value is null ? $"Can't be read ({credential.Source})" : masked,
            IsReadOnly = true,
            Height = 36,
            Style = (Style)FindResource("ModernTextBoxStyle"),
        };
        Grid.SetColumn(valueBox, 0);
        valueRow.Children.Add(valueBox);

        if (credential.Value is not null)
        {
            var shown = false;
            var showButton = SmallButton("Show");
            showButton.Click += (_, _) =>
            {
                shown = !shown;
                valueBox.Text = shown ? credential.Value : masked;
                showButton.Content = shown ? "Hide" : "Show";
            };
            Grid.SetColumn(showButton, 1);
            valueRow.Children.Add(showButton);

            var copyButton = SmallButton("Copy");
            copyButton.Click += (_, _) => Clipboard.SetText(credential.Value);
            Grid.SetColumn(copyButton, 2);
            valueRow.Children.Add(copyButton);
        }

        var resetButton = SmallButton("Reset");
        Grid.SetColumn(resetButton, 3);
        valueRow.Children.Add(resetButton);
        container.Children.Add(valueRow);

        container.Children.Add(new TextBlock
        {
            Text = credential.Value is null ? StoreHint(which) : $"Stored in: {credential.Source}",
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)FindResource("TextSecondaryBrush"),
            Margin = new Thickness(0, 4, 0, 0),
        });

        var resetPanel = BuildResetPanel(which);
        resetPanel.Visibility = Visibility.Collapsed;
        container.Children.Add(resetPanel);
        resetButton.Click += (_, _) =>
            resetPanel.Visibility = resetPanel.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;

        return container;
    }

    private StackPanel BuildResetPanel(ManagedPassword which)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var newPassword = new TextBox
        {
            Height = 36,
            Style = (Style)FindResource("ModernTextBoxStyle"),
            // Database logins are only typed by tools; a long generated one is the sensible default.
            Text = which == ManagedPassword.Settings ? "" : PasswordGenerator.Generate(),
            ToolTip = "New password",
        };
        Grid.SetColumn(newPassword, 0);
        row.Children.Add(newPassword);

        var generate = SmallButton("Generate");
        generate.Click += (_, _) => newPassword.Text = PasswordGenerator.Generate(which == ManagedPassword.Settings ? 16 : 24);
        Grid.SetColumn(generate, 1);
        row.Children.Add(generate);

        var save = SmallButton("Save New Password");
        Grid.SetColumn(save, 2);
        row.Children.Add(save);
        panel.Children.Add(row);

        var status = Text(which == ManagedPassword.Settings
            ? "At least 8 characters, with 3 of: upper case, lower case, a digit, a symbol. Write it down before saving."
            : "Copy it somewhere safe if you'll need it for database tools.");
        panel.Children.Add(status);

        save.Click += async (_, _) => await SaveAsync(which, newPassword.Text, status, new[] { save, generate });
        return panel;
    }

    private async Task SaveAsync(ManagedPassword which, string password, TextBlock status, Button[] buttons)
    {
        if (_busy)
        {
            return;
        }

        var problem = Problem(which, password);
        if (problem is not null)
        {
            SetStatus(status, problem, error: true);
            return;
        }

        _busy = true;
        foreach (var button in buttons)
        {
            button.IsEnabled = false;
        }
        CloseButton.IsEnabled = false;
        try
        {
            var progress = new Progress<string>(message => SetStatus(status, message, error: false));
            await Task.Run(() => new PasswordReset(_installPath).ResetAsync(which, password, progress, CancellationToken.None));
            InstallerLog.Write("password reset from Repair", extra: $"{which} password was reset.");
            BuildRows();
            AppDialog.Inform(this, "Password saved",
                "The new password is set and saved. Installed RFQ services that use it were restarted. " +
                "If you run RFQ Application directly, close and reopen it to use the new password.");
        }
        catch (Exception ex)
        {
            var logPath = InstallerLog.Write("resetting a password from Repair", ex);
            SetStatus(status, $"{InstallerLog.FormatUserDetail(ex)}{Environment.NewLine}Details: {logPath}", error: true);
        }
        finally
        {
            _busy = false;
            foreach (var button in buttons)
            {
                button.IsEnabled = true;
            }
            CloseButton.IsEnabled = true;
        }
    }

    internal static string? Problem(ManagedPassword which, string password) => PasswordReset.Problem(which, password);

    private static string StoreHint(ManagedPassword which) =>
        which == ManagedPassword.Settings
            ? "It can't be read from here, but you can still reset it."
            : "It can't be read from here (it's kept in another Windows account's Credential Manager, or it's missing). Reset sets a new one.";

    private Button SmallButton(string text) => new()
    {
        Content = text,
        Height = 36,
        MinWidth = 72,
        Margin = new Thickness(8, 0, 0, 0),
        Style = (Style)FindResource("SecondaryButtonStyle"),
    };

    private TextBlock Text(string text, bool error = false) => new()
    {
        Text = text,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 6, 0, 0),
        Foreground = error ? new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)) : (Brush)FindResource("TextSecondaryBrush"),
    };

    private static void SetStatus(TextBlock status, string text, bool error)
    {
        status.Text = text;
        status.Foreground = error
            ? new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C))
            : (Brush)status.FindResource("TextSecondaryBrush");
    }

    private void Close_Click(object sender, RoutedEventArgs e)
    {
        if (!_busy)
        {
            DialogResult = false;
        }
    }
}
