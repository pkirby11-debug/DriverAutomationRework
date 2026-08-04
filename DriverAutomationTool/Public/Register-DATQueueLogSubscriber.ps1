function Register-DATQueueLogSubscriber {
    <#
    .SYNOPSIS
        Registers a log subscriber that enqueues messages to a ConcurrentQueue.
    .DESCRIPTION
        Used by background runspaces to send log messages back to the UI thread.
        This is an exported wrapper so runspaces (which can only call exported functions)
        can register a subscriber that feeds into a shared thread-safe queue.
    .PARAMETER LogQueue
        A [System.Collections.Concurrent.ConcurrentQueue[string]] shared with the UI thread.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $LogQueue
    )

    Register-DATLogSubscriber -Action {
        param($LogEvent)
        $SeverityTag = switch ($LogEvent.Severity) {
            1 { 'INFO' }
            2 { 'WARN' }
            3 { 'ERROR' }
        }
        $Entry = "[{0}] [{1}] {2}" -f $LogEvent.Timestamp.ToString('HH:mm:ss'), $SeverityTag, $LogEvent.Message
        $LogQueue.Enqueue($Entry)
    }.GetNewClosure()
}
