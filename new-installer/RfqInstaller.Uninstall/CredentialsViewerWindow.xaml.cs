using System.Windows;
using System.Windows.Controls;
using RfqInstaller.Core.Security;

namespace RfqInstaller.Uninstall;

public partial class CredentialsViewerWindow : Window
{
    public CredentialsViewerWindow(string installPath)
    {
        InitializeComponent();

        List<StoredCredential> credentials;
        try
        {
            credentials = StoredCredentialsResolver.ResolveAll(installPath);
        }
        catch (Exception ex)
        {
            RowsPanel.Children.Add(new TextBlock
            {
                Text = $"Couldn't read stored credentials: {ex.Message}",
                TextWrapping = TextWrapping.Wrap,
                Foreground = System.Windows.Media.Brushes.Firebrick,
            });
            return;
        }

        foreach (var credential in credentials)
        {
            RowsPanel.Children.Add(BuildRow(credential));
        }
    }

    private static UIElement BuildRow(StoredCredential credential)
    {
        var container = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };

        container.Children.Add(new TextBlock
        {
            Text = credential.DisplayName,
            FontWeight = FontWeights.SemiBold,
        });

        if (credential.Value is null)
        {
            container.Children.Add(new TextBlock
            {
                Text = $"({credential.Source})",
                Foreground = System.Windows.Media.Brushes.Gray,
                Margin = new Thickness(0, 4, 0, 0),
            });
            return container;
        }

        var valueRow = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        valueRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        valueRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        valueRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var valueBox = new TextBox
        {
            Text = new string('•', Math.Min(credential.Value.Length, 24)),
            IsReadOnly = true,
            Height = 28,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(valueBox, 0);

        var showButton = new Button { Content = "Show", Width = 60, Height = 28, Margin = new Thickness(8, 0, 0, 0) };
        var shown = false;
        showButton.Click += (_, _) =>
        {
            shown = !shown;
            valueBox.Text = shown ? credential.Value : new string('•', Math.Min(credential.Value.Length, 24));
            showButton.Content = shown ? "Hide" : "Show";
        };
        Grid.SetColumn(showButton, 1);

        var copyButton = new Button { Content = "Copy", Width = 60, Height = 28, Margin = new Thickness(8, 0, 0, 0) };
        copyButton.Click += (_, _) => Clipboard.SetText(credential.Value);
        Grid.SetColumn(copyButton, 2);

        valueRow.Children.Add(valueBox);
        valueRow.Children.Add(showButton);
        valueRow.Children.Add(copyButton);
        container.Children.Add(valueRow);

        container.Children.Add(new TextBlock
        {
            Text = $"Stored in: {credential.Source}",
            FontSize = 11,
            Foreground = System.Windows.Media.Brushes.Gray,
            Margin = new Thickness(0, 4, 0, 0),
        });

        return container;
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
