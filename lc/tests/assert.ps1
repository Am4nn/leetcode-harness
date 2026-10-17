# Assertion helpers for *.tests.ps1 files. Each throws on failure.
function Assert-Equal($actual, $expected, [string]$message = '') {
    if ("$actual" -ne "$expected") {
        throw "Assert-Equal failed. $message`n  expected: $expected`n  actual:   $actual"
    }
}
function Assert-True($cond, [string]$message = '') {
    if (-not $cond) { throw "Assert-True failed. $message" }
}
function Assert-Match([string]$text, [string]$regex) {
    if ($text -notmatch $regex) { throw "Assert-Match failed: /$regex/ not found in:`n$text" }
}
