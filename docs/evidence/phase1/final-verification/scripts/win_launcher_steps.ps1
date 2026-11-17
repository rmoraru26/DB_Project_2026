$ErrorActionPreference = 'Stop'
# Final Windows launcher verification (tree 28f2fc09), adapted from the Phase 1
# steps: an isolated copy in a path with a space, its own Compose project
# (frt-finalw-28f2fc09, ports 23327/25091). Fresh `up`, ACLs, logins, `up`
# again, `demo`, `test`, `reset-demo`. No secret is printed.
$w = "<scratch>\win-launcher\FRANtastic final copy"
$o = "<scratch>\win-launcher\out"
. (Join-Path $w 'scripts/windows_security.ps1')
function Run([string] $Name, [string] $Command) {
    $p = Start-Process -FilePath "$w\frantastic.cmd" -ArgumentList $Command -WorkingDirectory $w -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput "$o\$Name.stdout.txt" -RedirectStandardError "$o\$Name.stderr.txt"
    return $p.ExitCode
}
function Sha([string] $f) { (Get-FileHash -LiteralPath (Join-Path $w $f) -Algorithm SHA256).Hash }
function Login([string] $file) {
    $lines = [IO.File]::ReadAllLines((Join-Path $w $file))
    $env:LOGIN_EMAIL = $lines[0]; $env:LOGIN_PASSWORD = $lines[1]
    try { Push-Location -LiteralPath $w; (Get-Content -Raw (Join-Path $w 'tests/integration/http_login.py')) | docker compose exec -T -e LOGIN_EMAIL -e LOGIN_PASSWORD web python - }
    finally { Pop-Location; Remove-Item Env:LOGIN_EMAIL, Env:LOGIN_PASSWORD }
}
"up (fresh) exit=$(Run '01-up-fresh' 'up')"
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach ($f in '.env', '.demo-credentials', '.admin-credentials') {
    $state = Assert-LocalFileDacl (Join-Path $w $f) (Get-LocalFileDaclState (Join-Path $w $f)).OwnerSid
    "ACL $f : protected DACL, $($state.Aces.Count) entries (current user, SYSTEM, Administrators), owner is current user: $($state.OwnerSid -ceq $owner)"
}
"demo file: $(([IO.File]::ReadAllLines((Join-Path $w '.demo-credentials'))).Count) lines, first line $(([IO.File]::ReadAllLines((Join-Path $w '.demo-credentials')))[0])"
"login demo student : $(Login '.demo-credentials')"
"login administrator: $(Login '.admin-credentials')"
$d = Sha '.demo-credentials'; $a = Sha '.admin-credentials'
"up (second run) exit=$(Run '02-up-again' 'up'); demo file unchanged: $((Sha '.demo-credentials') -ceq $d); admin file unchanged: $((Sha '.admin-credentials') -ceq $a)"
(Get-Content "$o\02-up-again.stdout.txt" | Select-String -Pattern 'no rotation performed').Line
"demo exit=$(Run '03-demo' 'demo')"
"test exit=$(Run '04-test' 'test')"
Get-Content "$o\04-test.stdout.txt" | Select-String -Pattern 'checks passed|^\[(PASS|FAIL|SKIP)\]|passed, |Total suites|Overall result|^Passed:|^Failed:|^Skipped' | ForEach-Object { $_.Line }
"reset-demo exit=$(Run '05-reset-demo' 'reset-demo'); demo file changed: $((Sha '.demo-credentials') -cne $d); admin file unchanged: $((Sha '.admin-credentials') -ceq $a)"
"login demo student after reset: $(Login '.demo-credentials')"
[void](Assert-LocalFileDacl (Join-Path $w '.demo-credentials') (Get-LocalFileDaclState (Join-Path $w '.demo-credentials')).OwnerSid); "ACL of the replaced .demo-credentials still owner-only: True"
$secrets = @(([IO.File]::ReadAllLines((Join-Path $w '.demo-credentials')))[1], ([IO.File]::ReadAllLines((Join-Path $w '.admin-credentials')))[1])
$secrets += @(Get-Content (Join-Path $w '.env') | Where-Object { $_ -match '^(MARIADB_ROOT_PASSWORD|CAMPUS_APP_PASSWORD|SECRET_KEY)=(.+)$' } | ForEach-Object { $Matches[2] })
$hits = 0; foreach ($file in Get-ChildItem $o -Filter *.txt) { $text = [IO.File]::ReadAllText($file.FullName); foreach ($s in $secrets) { if ($text.Contains($s)) { $hits++ } } }
"secrets found in the $(@(Get-ChildItem $o -Filter *.txt).Count) captured output files: $hits (of $($secrets.Count) values checked)"
