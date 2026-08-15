namespace RfqInstaller.Demo.Models;

public class RailStep
{
    public required string Title { get; init; }

    public int Index { get; init; }

    public bool IsActive { get; init; }

    public bool IsCompleted { get; init; }
}
