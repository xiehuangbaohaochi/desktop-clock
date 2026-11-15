# 把作者邮箱改为 GitHub noreply，并整理成单个提交后强推
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CredApi2 {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags; public int Type; public IntPtr TargetName; public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount; public IntPtr Attributes;
        public IntPtr TargetAlias; public IntPtr UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr cred);
}
'@

$ptr = [IntPtr]::Zero
if (-not [CredApi2]::CredRead('GitHub - https://api.github.com/xiehuangbaohaochi', 1, 0, [ref]$ptr)) { "NO_TOKEN"; exit 2 }
$cred  = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][CredApi2+CREDENTIAL])
$bytes = New-Object byte[] $cred.CredentialBlobSize
[Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $bytes.Length)
[CredApi2]::CredFree($ptr) | Out-Null
$uni = [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)
$utf = [Text.Encoding]::UTF8.GetString($bytes).TrimEnd([char]0)
$token = if ($uni -match '^[\x20-\x7E]{20,}$') { $uni } else { $utf }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ Authorization = "token $token"; 'User-Agent' = 'dsh-clock'; Accept = 'application/vnd.github+json' }
$user = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 25

$email = "$($user.id)+$($user.login)@users.noreply.github.com"
"author email -> $email"

git -C $dir config user.name  $user.login
git -C $dir config user.email $email

# 压成单个提交（保留文件，历史重建）
git -C $dir checkout --orphan clean-main 2>&1 | Out-Null
git -C $dir add -A
git -C $dir commit -q -m "feat: 此刻 · 桌面时钟 v1.0（透明数字时钟 + 农历 + 天气）" --author "$($user.login) <$email>"
git -C $dir branch -M clean-main main

$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
$hdr   = "http.https://github.com/.extraheader=AUTHORIZATION: basic $basic"
$log   = git -C $dir -c $hdr push -f origin main 2>&1
$code  = $LASTEXITCODE
$log | ForEach-Object { $_ -replace [regex]::Escape($basic), '<redacted>' } | Select-Object -Last 4
"force push exit = $code"
