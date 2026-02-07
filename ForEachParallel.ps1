class CompletionQueue {
    $ThreadCount
    $RunspacePool
    $Count
    $EndQueue

    CompletionQueue($ThreadCount) {
        $this.ThreadCount = $ThreadCount
        $this.RunspacePool = [runspacefactory]::CreateRunspacePool($ThreadCount, $ThreadCount)
        $this.RunspacePool.ApartmentState = [System.Threading.ApartmentState]::MTA
        $this.RunspacePool.Open()
        $this.Count = 0
        $this.EndQueue = [System.Collections.Concurrent.BlockingCollection[object]]::new()
    }

    [void] Add([scriptblock]$Script, [object]$ScriptArgument) {
        $Future = [pscustomobject]@{
            PowerShell = $null
            AsyncResult = $null
        }

        $PowerShell = [powershell]::Create().
            AddScript({
                param($_, $_Script, $_EndQueue, $_Future)
                try {
                    return . ([ScriptBlock]::Create($_Script))
                } finally {
                    $_EndQueue.Add($_Future)
                }
            }).
            AddArgument($ScriptArgument).
            AddArgument($Script.ToString()).
            AddArgument($this.EndQueue).
            AddArgument($Future)

        $PowerShell.RunspacePool = $this.RunspacePool

        $Future.PowerShell = $PowerShell
        $Future.AsyncResult = $PowerShell.BeginInvoke()

        $this.Count++
    }

    [bool] IsFull() {
        return $this.Count -ge $this.ThreadCount
    }
    
    [bool] IsEmpty() {
        return $this.Count -lt 1
    }

    [object] Remove() {
        $this.Count--
        $Future = $this.EndQueue.Take()
        $Result = $null
        $Err = $null

        try {
            $Result = $Future.PowerShell.EndInvoke($Future.AsyncResult)

            if ($Future.PowerShell.HadErrors) {
                $Err = $Future.PowerShell.Streams.Error -join ", "
            }
        } catch {
            $Err = $_
        }

        $Future.PowerShell.Dispose()

        if ($Err -ne $null) {
            throw $Err
        }

        return $Result
    }

    [void] Dispose() {
        $this.EndQueue.CompleteAdding()
        $this.EndQueue.Dispose()
        $this.RunspacePool.Dispose()
    }
}

function ForEachParallel-Object {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [object]$Element,

        [Parameter()]
        [int]$ThreadCount = [Environment]::ProcessorCount,

        [Parameter(Position=0)]
        [scriptblock]$Script
    )

    begin {
        $Queue = [CompletionQueue]::new($ThreadCount)
    }

    process {
        if ($Queue.IsFull()) {
            Write-Output $Queue.Remove()
        }
        $Queue.Add($Script, $Element)
    }

    end {
        while (-not $Queue.IsEmpty()) {
            Write-Output $Queue.Remove()
        }
        $Queue.Dispose()
    }
}

1..10 | ForEachParallel-Object -ThreadCount 10 {
    sleep -Milliseconds (Get-Random -Minimum 0 -Maximum 10)
    $ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    "Element = $_, ThreadId = $ThreadId"
} 
