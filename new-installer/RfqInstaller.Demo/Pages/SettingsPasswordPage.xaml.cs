using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using RfqInstaller.Core.Security;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class SettingsPasswordPage : UserControl, IWizardPage
{
    private static readonly SolidColorBrush MetBrush = new(Color.FromRgb(0x10, 0x7C, 0x10));
    private static readonly SolidColorBrush UnmetBrush = new(Color.FromRgb(0x9B, 0x9B, 0xA1));

    private readonly WizardState _state;
    private bool _suppressSync;
    private string _confirmValue = string.Empty;

    public SettingsPasswordPage(WizardState state)
    {
        InitializeComponent();
        _state = state;

        if (!string.IsNullOrEmpty(_state.SettingsPassword))
        {
            PasswordMaskedBox.Password = _state.SettingsPassword;
            PasswordPlainBox.Text = _state.SettingsPassword;
        }

        UpdateStrengthUi();
    }

    private void PasswordMaskedBox_PasswordChanged(object sender, RoutedEventArgs e) => OnPasswordChanged(PasswordMaskedBox.Password);

    private void PasswordPlainBox_TextChanged(object sender, TextChangedEventArgs e) => OnPasswordChanged(PasswordPlainBox.Text);

    private void OnPasswordChanged(string value)
    {
        if (_suppressSync)
        {
            return;
        }

        _state.SettingsPassword = value;
        ErrorText.Visibility = Visibility.Collapsed;
        UpdateStrengthUi();
        UpdateMismatch();
    }

    private void ConfirmMaskedBox_PasswordChanged(object sender, RoutedEventArgs e) => OnConfirmChanged(ConfirmMaskedBox.Password);

    private void ConfirmPlainBox_TextChanged(object sender, TextChangedEventArgs e) => OnConfirmChanged(ConfirmPlainBox.Text);

    private void OnConfirmChanged(string value)
    {
        if (_suppressSync)
        {
            return;
        }

        _confirmValue = value;
        UpdateMismatch();
    }

    private void UpdateMismatch()
    {
        MismatchText.Visibility = !string.IsNullOrEmpty(_confirmValue) && _confirmValue != _state.SettingsPassword
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void ShowPasswordCheck_Changed(object sender, RoutedEventArgs e)
    {
        var show = ShowPasswordCheck.IsChecked == true;

        _suppressSync = true;
        try
        {
            PasswordPlainBox.Text = _state.SettingsPassword;
            ConfirmPlainBox.Text = _confirmValue;
            PasswordMaskedBox.Password = _state.SettingsPassword;
            ConfirmMaskedBox.Password = _confirmValue;
        }
        finally
        {
            _suppressSync = false;
        }

        PasswordMaskedBox.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        PasswordPlainBox.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        ConfirmMaskedBox.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        ConfirmPlainBox.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    private void GenerateButton_Click(object sender, RoutedEventArgs e)
    {
        var generated = PasswordGenerator.Generate();
        _state.SettingsPassword = generated;
        _confirmValue = generated;

        ShowPasswordCheck.IsChecked = true; // ensure it's visible so the admin actually sees it

        _suppressSync = true;
        try
        {
            PasswordPlainBox.Text = generated;
            ConfirmPlainBox.Text = generated;
            PasswordMaskedBox.Password = generated;
            ConfirmMaskedBox.Password = generated;
        }
        finally
        {
            _suppressSync = false;
        }

        ErrorText.Visibility = Visibility.Collapsed;
        UpdateStrengthUi();
        UpdateMismatch();
    }

    private void CopyPasswordButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(_state.SettingsPassword))
        {
            Clipboard.SetText(_state.SettingsPassword);
        }
    }

    private void UpdateStrengthUi()
    {
        var evaluation = PasswordPolicy.Evaluate(_state.SettingsPassword);

        var (fraction, brush, label) = evaluation.Strength switch
        {
            PasswordStrength.VeryWeak => (0.10, (Brush)FindResource("DangerBrush"), "Very weak"),
            PasswordStrength.Weak => (0.32, (Brush)FindResource("DangerBrush"), "Weak"),
            PasswordStrength.Fair => (0.58, (Brush)FindResource("WarningBrush"), "Fair"),
            PasswordStrength.Good => (0.80, (Brush)FindResource("SuccessBrush"), "Good"),
            PasswordStrength.Strong => (1.0, (Brush)FindResource("SuccessBrush"), "Strong"),
            _ => (0.0, (Brush)FindResource("BorderStrongBrush"), string.Empty),
        };

        StrengthFill.Background = brush;
        StrengthLabel.Foreground = brush;
        StrengthLabel.Text = string.IsNullOrEmpty(_state.SettingsPassword) ? string.Empty : label;

        // StrengthTrack's ActualWidth is 0 until layout runs at least once; fall back to a sensible default.
        var trackWidth = StrengthTrack.ActualWidth > 0 ? StrengthTrack.ActualWidth : 460;
        StrengthFill.Width = trackWidth * fraction;

        RebuildCriteriaList(evaluation.Criteria);
    }

    private void RebuildCriteriaList(PasswordCriteria criteria)
    {
        CriteriaList.Children.Clear();

        AddCriterionRow("At least 8 characters", criteria.HasMinLength);
        AddCriterionRow("Contains 3 of: uppercase, lowercase, number, symbol", criteria.ClassCountMet);
        AddCriterionRow("Not a commonly used password", criteria.IsNotCommon);
    }

    private void AddCriterionRow(string text, bool met)
    {
        var brush = met ? MetBrush : UnmetBrush;

        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        row.Children.Add(new TextBlock
        {
            Text = met ? "✓" : "○",
            Width = 18,
            Foreground = brush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        row.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = 12,
            Foreground = brush,
            VerticalAlignment = VerticalAlignment.Center,
        });

        CriteriaList.Children.Add(row);
    }

    public bool Validate()
    {
        var evaluation = PasswordPolicy.Evaluate(_state.SettingsPassword);

        if (string.IsNullOrEmpty(_state.SettingsPassword))
        {
            ShowError("Please create a Settings password to continue.");
            return false;
        }

        if (!evaluation.MeetsMinimum)
        {
            ShowError("This password doesn't meet the minimum requirements above yet.");
            return false;
        }

        if (_confirmValue != _state.SettingsPassword)
        {
            ShowError("The passwords don't match.");
            MismatchText.Visibility = Visibility.Visible;
            return false;
        }

        return true;
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }
}
