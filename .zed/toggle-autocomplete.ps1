# Flips "show_completions_on_input" in this project's Zed settings.
# Zed reloads settings.json on save, so the change applies immediately.
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'toggle-autocomplete.log'
"$(Get-Date -Format s) run from '$PWD'" | Out-File -Append -Encoding utf8 $log

try {
    $path = Join-Path $PSScriptRoot 'settings.json'
    $text = [IO.File]::ReadAllText($path)

    if ($text -match '"show_completions_on_input":\s*true') { $new = 'false' } else { $new = 'true' }
    $text = $text -replace '"show_completions_on_input":\s*(true|false)', "`"show_completions_on_input`": $new"

    [IO.File]::WriteAllText($path, $text)
    "  -> $new" | Out-File -Append -Encoding utf8 $log
    if ($new -eq 'true') { Write-Host 'Autocomplete popup: ON' } else { Write-Host 'Autocomplete popup: OFF' }
} catch {
    "  ERROR: $_" | Out-File -Append -Encoding utf8 $log
    throw
}
