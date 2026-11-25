using RfqInstaller.Core.Models;
using RfqInstaller.Core.Processes;
using RfqInstaller.Core.Services;
using Xunit;

namespace RfqInstaller.Core.Tests;

public class NssmLogRotationTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public void Missing_cap_uses_original_300_MiB_default(string? value) =>
        Assert.Equal("314572800", NssmLogRotation.ParseMaxBytes(value));

    [Theory]
    [InlineData("0")]
    [InlineData("1")]
    [InlineData("4294967295")]
    [InlineData("0xffffffff")]
    [InlineData("037777777777")]
    [InlineData(" \t+0x10")]
    public void Valid_NSSM_DWORD_is_preserved(string value) =>
        Assert.Equal(value, NssmLogRotation.ParseMaxBytes(value));

    [Theory]
    [InlineData(" ")]
    [InlineData("-1")]
    [InlineData("08")]
    [InlineData("1MB")]
    [InlineData("1 ")]
    [InlineData("4294967296")]
    [InlineData("0x100000000")]
    [InlineData("040000000000")]
    public void Invalid_cap_is_rejected(string value) =>
        Assert.Throws<ArgumentException>(() => NssmLogRotation.ParseMaxBytes(value));

    [Fact]
    public async Task Invalid_cap_does_not_query_or_remove_an_existing_service()
    {
        var calls = 0;
        var manager = new NssmServiceManager("nssm.exe", (_, _, _) =>
        {
            calls++;
            return Task.FromResult(new ProcessResult(0, "", ""));
        }, getLogCapValue: () => "invalid");

        await Assert.ThrowsAsync<ArgumentException>(() => Install(manager, "RFQapplication"));
        Assert.Equal(0, calls);
    }

    [Theory]
    [InlineData("RFQapplication")]
    [InlineData("RFQUpdaterService")]
    public async Task Both_services_keep_stream_paths_and_rotate_before_start(string service)
    {
        var calls = new List<string[]>();
        var firstQuery = true;
        var manager = new NssmServiceManager("nssm.exe", (file, args, _) =>
        {
            calls.Add(args.ToArray());
            if (file == "sc.exe" && args[0] == "query" && firstQuery)
            {
                firstQuery = false;
                return Task.FromResult(new ProcessResult(1060, "", ""));
            }
            return Task.FromResult(new ProcessResult(0, "STATE : 4 RUNNING", ""));
        }, (_, _) => Task.CompletedTask, () => "0x1000");

        await Install(manager, service);
        var start = calls.FindIndex(a => a[0] == "start");
        foreach (var (setting, value) in new[]
        {
            ("AppStdout", "stdout.log"), ("AppStderr", "stderr.log"),
            ("AppRotateFiles", "1"), ("AppRotateOnline", "1"), ("AppRotateBytes", "0x1000")
        })
        {
            var command = new[] { "set", service, setting, value };
            Assert.Single(calls.Where(a => a.SequenceEqual(command)));
            Assert.InRange(calls.FindIndex(a => a.SequenceEqual(command)), 0, start - 1);
        }
    }

    [Theory]
    [InlineData("AppRotateFiles")]
    [InlineData("AppRotateOnline")]
    [InlineData("AppRotateBytes")]
    public async Task Failed_rotation_setting_is_reported_and_service_is_not_started(string setting)
    {
        var started = false;
        var manager = new NssmServiceManager("nssm.exe", (file, args, _) =>
        {
            started |= args[0] == "start";
            var result = file == "sc.exe" ? new ProcessResult(1060, "", "") :
                args.Count > 2 && args[2] == setting ? new ProcessResult(7, "setting failed", "") :
                new ProcessResult(0, "", "");
            return Task.FromResult(result);
        }, getLogCapValue: () => null);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Install(manager, "RFQapplication"));
        Assert.Contains(setting, error.Message);
        Assert.False(started);
    }

    private static Task Install(NssmServiceManager manager, string service) =>
        manager.InstallOrReplaceAsync(service, "display", "description", "app.exe", "app-dir",
            service == "RFQUpdaterService" ? "--service" : null, "stdout.log", "stderr.log",
            ServiceAccountKind.LocalSystem, null, null, CancellationToken.None);
}
