# 用本机保存的 GitHub 凭据：建仓库 + 推送（token 只在内存中使用，不落盘、不回显）
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CredApi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr cred);
}
'@

$dir = $PSScriptRoot

function Get-CredentialToken {
    foreach ($t in @('GitHub - https://api.github.com/xiehuangbaohaochi', 'git:https://github.com')) {
        $ptr = [IntPtr]::Zero
        if (-not [CredApi]::CredRead($t, 1, 0, [ref]$ptr)) { continue }
        try {
            $cred  = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][CredApi+CREDENTIAL])
            $bytes = New-Object byte[] $cred.CredentialBlobSize
            [System.Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $bytes.Length)
            $uni = [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)
            $utf = [Text.Encoding]::UTF8.GetString($bytes).TrimEnd([char]0)
            if ($uni -match '^[\x20-\x7E]{20,}$') { return $uni }
            if ($utf -match '^[\x20-\x7E]{20,}$') { return $utf }
        } finally {
            [CredApi]::CredFree($ptr) | Out-Null
        }
    }
    return $null
}

$token = Get-CredentialToken
if (-not $token) { "NO_TOKEN"; exit 2 }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ Authorization = "token $token"; 'User-Agent' = 'dsh-clock'; Accept = 'application/vnd.github+json' }

try {
    $user = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 25
} catch {
    "AUTH_FAIL: " + $_.Exception.Message
    exit 3
}
"login = $($user.login)"

$repoName = 'desktop-clock'
$body = @{
    name        = $repoName
    description = '此刻 · 桌面时钟 —— 透明背景的 Windows 桌面数字时钟：时间 / 日期 / 农历 / 实时天气，零依赖（PowerShell + WPF）'
    private     = $true
    has_issues  = $true
    has_wiki    = $false
    auto_init   = $false
} | ConvertTo-Json

$repoUrl = $null
try {
    $repo = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method Post -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
    $repoUrl = $repo.html_url
    "repo created: $repoUrl"
} catch {
    $resp = $_.Exception.Response
    if ($resp -and [int]$resp.StatusCode -eq 422) {
        $repoUrl = "https://github.com/$($user.login)/$repoName"
        "repo exists: $repoUrl"
    } else {
        "CREATE_FAIL: " + $_.Exception.Message
        if ($_.ErrorDetails) { "detail: " + $_.ErrorDetails.Message }
        exit 4
    }
}

# 设置 topics（失败不影响推送）
try {
    $topics = @{ names = @('desktop-clock', 'desktop-widget', 'wpf', 'powershell', 'windows', 'lunar-calendar', 'weather') } | ConvertTo-Json
    Invoke-RestMethod -Uri "https://api.github.com/repos/$($user.login)/$repoName/topics" -Method Put -Headers $headers -Body $topics -ContentType 'application/json' -TimeoutSec 20 | Out-Null
    "topics set"
} catch { "topics skipped: $($_.Exception.Message)" }

# 配置 remote（不含 token）
$remote = "https://github.com/$($user.login)/$repoName.git"
$ErrorActionPreference = 'Continue'
$remotes = @(git -C $dir remote 2>$null)
if ($remotes -contains 'origin') { git -C $dir remote set-url origin $remote } else { git -C $dir remote add origin $remote }

# 用内存中的 basic auth 推送，不写入任何配置文件
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
$hdr   = "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic"
$log   = git -C $dir -c $hdr push -u origin main 2>&1
$code  = $LASTEXITCODE
$log | ForEach-Object { $_ -replace [regex]::Escape($basic), '<redacted>' } | Select-Object -Last 6
"push exit = $code"
if ($code -ne 0) { exit 5 }
"PUSH_OK $repoUrl"
