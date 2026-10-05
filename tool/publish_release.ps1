param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$ApkDirectory = (Join-Path $PSScriptRoot '../build/app/outputs/apk/release'),
    [string]$GitHubCli = 'gh'
)
$ErrorActionPreference = 'Stop'
$repository = 'vialoyed-ctrl/TvPlayer'
$tag = "v$Version"
$staging = Join-Path $PSScriptRoot "../build/release-$Version"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$assets = @()
foreach ($pair in @(
    @('app-armeabi-v7a-release.apk', 'tvplayer_32bit.apk'),
    @('app-arm64-v8a-release.apk', 'tvplayer_64bit.apk')
)) {
    $source = Join-Path $ApkDirectory $pair[0]
    $target = Join-Path $staging $pair[1]
    Copy-Item -LiteralPath $source -Destination $target -Force
    $assets += @{
        name = $pair[1]; state = 'uploaded'
        size = (Get-Item -LiteralPath $target).Length
        digest = 'sha256:' + (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        browser_download_url = "https://github.com/$repository/releases/download/$tag/$($pair[1])"
    }
}
$manifest = Join-Path $staging 'update.json'
@{ tag_name = $tag; draft = $false; prerelease = $false; assets = $assets } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding utf8
$notes = Join-Path $staging 'notes.md'
'一个 TV 视频播放器。' | Set-Content -LiteralPath $notes -Encoding utf8
& $GitHubCli release create $tag (Join-Path $staging 'tvplayer_32bit.apk') `
    (Join-Path $staging 'tvplayer_64bit.apk') $manifest --repo $repository `
    --target main --title "TvPlayer $Version" --notes-file $notes
if ($LASTEXITCODE -ne 0) { throw 'GitHub Release 发布失败' }
