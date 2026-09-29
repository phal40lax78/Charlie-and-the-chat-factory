# chatq's PermissionRequest hook for AskUserQuestion (docs/phone-ask-spec.md,
# src/ask.ps1 Start-ChatqAskHook): what the chatq-ask plugin runs, as
#   powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <this file>
# Not a part of the script: it loads the script, then holds one question for
# the phone. Nothing but the one decision line may reach stdout - so the load
# goes to *> $null, every stream, not | Out-Null, which lets Write-Host
# through - and it always exits 0: exit 2 means block to Claude Code, and
# any failure must leave the dialog exactly as it was.
$ProgressPreference = 'SilentlyContinue'
$env:CHATQ_OVERLAY = '1'
try {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-codex-chat-manager.ps1') *> $null
    Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference', 'env:CHATQ_OVERLAY' -EA SilentlyContinue
    $null = Start-ChatqAskHook
}
catch {
    try {
        $log = Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'data') 'logs') 'ask.log'
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $log))
        [System.IO.File]::AppendAllText($log, (Get-Date).ToString('o') + "  [$PID] the hook did not load: " + $_.Exception.Message + [char]10)
    }
    catch {}
}
exit 0
