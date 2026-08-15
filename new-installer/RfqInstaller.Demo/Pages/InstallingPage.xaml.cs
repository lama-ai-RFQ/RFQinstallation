using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using RfqInstaller.Demo.Models;

namespace RfqInstaller.Demo.Pages;

public partial class InstallingPage : UserControl
{
    private readonly WizardState _state;
    private readonly Action _onComplete;
    private bool _started;

    private static readonly SolidColorBrush PendingBrush = new(Color.FromRgb(0x9B, 0x9B, 0xA1));
    private static readonly SolidColorBrush ActiveBrush = new(Color.FromRgb(0x00, 0x67, 0xC0));
    private static readonly SolidColorBrush DoneBrush = new(Color.FromRgb(0x10, 0x7C, 0x10));

    public InstallingPage(WizardState state, Action onComplete)
    {
        InitializeComponent();
        _state = state;
        _onComplete = onComplete;
    }

    private async void InstallingPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_started)
        {
            return;
        }

        _started = true;

        var steps = new List<string>
        {
            "Validating license key...",
            "Downloading application components...",
            "Setting up database...",
            _state.Mode == InstallMode.WindowsService
                ? "Registering Windows service..."
                : "Installing application files...",
            "Finishing up..."
        };

        var glyphs = new List<TextBlock>();
        var labels = new List<TextBlock>();

        foreach (var step in steps)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 14) };
            var glyph = new TextBlock
            {
                Text = "○",
                Width = 20,
                Foreground = PendingBrush,
                VerticalAlignment = VerticalAlignment.Center
            };
            var label = new TextBlock
            {
                Text = step,
                Margin = new Thickness(8, 0, 0, 0),
                Foreground = PendingBrush,
                VerticalAlignment = VerticalAlignment.Center
            };

            row.Children.Add(glyph);
            row.Children.Add(label);
            StatusList.Children.Add(row);

            glyphs.Add(glyph);
            labels.Add(label);
        }

        var stepProgress = 100.0 / steps.Count;

        for (var i = 0; i < steps.Count; i++)
        {
            glyphs[i].Text = "●";
            glyphs[i].Foreground = ActiveBrush;
            labels[i].Foreground = ActiveBrush;
            labels[i].FontWeight = FontWeights.SemiBold;

            var target = (i + 1) * stepProgress;
            await AnimateProgressAsync(Progress.Value, target);

            glyphs[i].Text = "✓";
            glyphs[i].Foreground = DoneBrush;
            labels[i].Foreground = DoneBrush;
            labels[i].FontWeight = FontWeights.Normal;
        }

        await Task.Delay(300);
        _onComplete();
    }

    private async Task AnimateProgressAsync(double from, double to)
    {
        const int frames = 18;
        var delayPerFrame = TimeSpan.FromMilliseconds(650.0 / frames);

        for (var f = 1; f <= frames; f++)
        {
            var value = from + (to - from) * f / frames;
            Progress.Value = value;
            PercentText.Text = $"{(int)value}%";
            await Task.Delay(delayPerFrame);
        }
    }
}
