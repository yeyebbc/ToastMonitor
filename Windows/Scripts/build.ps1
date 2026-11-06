[CmdletBinding()]
param(
    [ValidateSet('resolve', 'build', 'test', 'run', 'package')]
    [string]$Action = 'build',
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'debug',
    [string]$BuildPath,
    [string]$SwiftPath,
    [string]$OutputPath,
    [ValidateRange(1, 32)]
    [int]$Jobs = 2,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)
$ErrorActionPreference = 'Stop'
$Configuration = $Configuration.ToLowerInvariant()
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$BuildPath) { $BuildPath = Join-Path $root '.build/windows' }
$BuildPath = [IO.Path]::GetFullPath($BuildPath)
New-Item -ItemType Directory -Force -Path $BuildPath | Out-Null
$tempPath = Join-Path $BuildPath 'tmp'
New-Item -ItemType Directory -Force -Path $tempPath | Out-Null
$env:TEMP = $tempPath
$env:TMP = $tempPath

# Import the installed native toolchain into this process, not the user's profile.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path $vswhere)) { throw 'Install Visual Studio 2022 C++ Build Tools and a Windows SDK first.' }
$vs = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'Visual Studio C++ x64 build tools were not found.' }
$vcvars = Join-Path ($vs | Select-Object -First 1) 'VC/Auxiliary/Build/vcvars64.bat'
$nativeEnvironment = & $env:ComSpec /d /s /c "call `"$vcvars`" && set"
if ($LASTEXITCODE -ne 0) { throw 'The Visual Studio developer environment could not be initialized.' }
foreach ($line in $nativeEnvironment) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    }
}
$userEnvironment = [Environment]::GetEnvironmentVariables('User')
foreach ($key in $userEnvironment.Keys) {
    if ($key -match '^(SDKROOT|SWIFT.*|DEVELOPER_DIR|TOOLCHAINS)$' -and ![Environment]::GetEnvironmentVariable($key, 'Process')) {
        [Environment]::SetEnvironmentVariable($key, $userEnvironment[$key], 'Process')
    }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
if ($SwiftPath) {
    $swift = [IO.Path]::GetFullPath($SwiftPath)
    $env:Path = (Split-Path $swift) + ';' + $env:Path
} else {
    $command = Get-Command swift.exe -ErrorAction SilentlyContinue
    if (!$command) { throw 'Install the Swift Windows toolchain, or pass -SwiftPath with its swift.exe path.' }
    $swift = $command.Source
}
$common = @('--package-path', $root, '--scratch-path', $BuildPath, '--cache-path', (Join-Path $BuildPath 'cache'))
# Select the SDK and runtime from the same official installation as the compiler.
# A long-running terminal can retain environment variables from an older install.
$swiftBin = Split-Path $swift
$toolchain = Get-Item ([IO.Path]::GetFullPath((Join-Path $swiftBin '../..')))
$installation = $toolchain.Parent.Parent.FullName
$version = $toolchain.Name -replace '\+.*$', ''
$sdk = Join-Path $installation "Platforms/$version/Windows.platform/Developer/SDKs/Windows.sdk"
$runtime = Join-Path $installation "Runtimes/$version/usr/bin"
if (!(Test-Path $sdk) -or !(Test-Path $runtime)) {
    throw "The matching Swift $version Windows SDK and runtime were not found under $installation."
}
$env:SDKROOT = $sdk
$env:Path = $swiftBin + ';' + $runtime + ';' + $env:Path
# Keep package implementations inside the application DLL; WinUI exceeds PE's export limit as a separate DLL.
$env:SCUI_LIBRARY_TYPE = 'auto'

& $swift package @common resolve
if ($LASTEXITCODE -ne 0) { throw "Swift package resolution failed (exit $LASTEXITCODE)." }
# Pin the official SQLite 3.54.1 x64 DLL and matching amalgamation header.
$sqliteRoot = Join-Path $BuildPath 'dependencies/sqlite'
$sqliteDownloads = Join-Path $sqliteRoot 'downloads'
$sqliteBin = Join-Path $sqliteRoot 'bin'
$sqliteInclude = Join-Path $sqliteRoot 'include'
$sqliteLib = Join-Path $sqliteRoot 'lib'
New-Item -ItemType Directory -Force -Path $sqliteDownloads, $sqliteBin, $sqliteInclude, $sqliteLib | Out-Null
$sqliteDllArchive = Join-Path $sqliteDownloads 'sqlite-dll-win-x64-3540100.zip'
$sqliteHeaderArchive = Join-Path $sqliteDownloads 'sqlite-amalgamation-3540100.zip'
if (!(Test-Path $sqliteDllArchive)) {
    Invoke-WebRequest -UseBasicParsing 'https://www.sqlite.org/2026/sqlite-dll-win-x64-3540100.zip' -OutFile $sqliteDllArchive
}
if (!(Test-Path $sqliteHeaderArchive)) {
    Invoke-WebRequest -UseBasicParsing 'https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip' -OutFile $sqliteHeaderArchive
}
$sqliteDllArchiveHash = (Get-FileHash $sqliteDllArchive -Algorithm SHA256).Hash
$sqliteHeaderArchiveHash = (Get-FileHash $sqliteHeaderArchive -Algorithm SHA256).Hash
if ($sqliteDllArchiveHash -ne 'f436f53ad8f965af43f3817b42c99c0689e6787f6b7ace208fe38dab7ffc4971') {
    throw 'SQLite 3.54.1 x64 DLL archive checksum mismatch.'
}
if ($sqliteHeaderArchiveHash -ne '0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9') {
    throw 'SQLite 3.54.1 amalgamation archive checksum mismatch.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Copy-ZipEntry([string]$ArchivePath, [string]$EntryName, [string]$DestinationPath) {
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entry = $archive.GetEntry($EntryName)
        if (!$entry) { throw "Missing archive entry $EntryName in $ArchivePath." }
        $source = $entry.Open()
        try {
            $destination = [IO.File]::Create($DestinationPath)
            try { $source.CopyTo($destination) } finally { $destination.Dispose() }
        } finally {
            $source.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}
$sqliteDll = Join-Path $sqliteBin 'sqlite3.dll'
$sqliteDef = Join-Path $sqliteLib 'sqlite3.def'
$sqliteHeader = Join-Path $sqliteInclude 'sqlite3.h'
$sqliteImportLibrary = Join-Path $sqliteLib 'sqlite3.lib'
$sqliteDllSha256 = '4b59d3cded9dc1608544160f3b4b10ac974c6ac0d6ffc23064e5f4c8dbd05aea'
$sqliteDefSha256 = '4fd9c79ce52498bc69a2c588680888ece2dff33d47a949416da34148c660b6b5'
$sqliteHeaderSha256 = 'd6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c'
if (!(Test-Path $sqliteDll) -or (Get-FileHash $sqliteDll -Algorithm SHA256).Hash -ne $sqliteDllSha256) {
    Copy-ZipEntry $sqliteDllArchive 'sqlite3.dll' $sqliteDll
}
if (!(Test-Path $sqliteDef) -or (Get-FileHash $sqliteDef -Algorithm SHA256).Hash -ne $sqliteDefSha256) {
    Copy-ZipEntry $sqliteDllArchive 'sqlite3.def' $sqliteDef
}
if (!(Test-Path $sqliteHeader) -or (Get-FileHash $sqliteHeader -Algorithm SHA256).Hash -ne $sqliteHeaderSha256) {
    Copy-ZipEntry $sqliteHeaderArchive 'sqlite-amalgamation-3540100/sqlite3.h' $sqliteHeader
}
$sqliteStampPath = Join-Path $sqliteLib 'sqlite3-import.json'
$rebuildImportLibrary = $true
if ((Test-Path $sqliteImportLibrary) -and (Test-Path $sqliteStampPath)) {
    try {
        $stamp = Get-Content $sqliteStampPath -Raw | ConvertFrom-Json
        $importHash = (Get-FileHash $sqliteImportLibrary -Algorithm SHA256).Hash
        $rebuildImportLibrary = !($stamp.version -eq '3.54.1' -and
            $stamp.dllArchiveSha256 -eq $sqliteDllArchiveHash -and
            $stamp.headerArchiveSha256 -eq $sqliteHeaderArchiveHash -and
            $stamp.defSha256 -eq $sqliteDefSha256 -and
            $stamp.importLibrarySha256 -eq $importHash)
    } catch {
        $rebuildImportLibrary = $true
    }
}
if ($rebuildImportLibrary) {
    & lib.exe /nologo /machine:x64 "/def:$sqliteDef" "/out:$sqliteImportLibrary"
    if ($LASTEXITCODE -ne 0) { throw 'SQLite import library generation failed.' }
    $stamp = @{
        version = '3.54.1'
        dllArchiveSha256 = $sqliteDllArchiveHash
        headerArchiveSha256 = $sqliteHeaderArchiveHash
        defSha256 = $sqliteDefSha256
        importLibrarySha256 = (Get-FileHash $sqliteImportLibrary -Algorithm SHA256).Hash
    }
    $stamp | ConvertTo-Json | Set-Content $sqliteStampPath -Encoding utf8
}
$env:LIB = $sqliteLib + ';' + $env:LIB
$env:Path = $sqliteBin + ';' + $env:Path
$buildOptions = @('-Xcc', "-I$sqliteInclude")
$resolved = Get-Content (Join-Path $root 'Package.resolved') -Raw | ConvertFrom-Json
$winuiPin = $resolved.pins | Where-Object { $_.identity -eq 'swift-winui' } | Select-Object -First 1
$winuiRevision = 'c4f1cb75c02f4a4fdefcef2e5c5c4388c7cf9389'
if (!$winuiPin -or $winuiPin.state.version -ne '0.2.2' -or $winuiPin.state.revision -ne $winuiRevision) {
    throw 'The STA patch is pinned to swift-winui 0.2.2 at the approved revision; update the patch with any dependency change.'
}
$winuiCheckout = Join-Path $BuildPath 'checkouts/swift-winui'
$winuiSource = Join-Path $winuiCheckout 'Sources/WinUI/Application/SwiftApplication.swift'
if (!(Test-Path $winuiSource)) { throw "Resolved swift-winui source was not found at $winuiSource." }
$winuiPatch = Join-Path $root 'Windows/Patches/swift-winui-0.2.2-sta.patch'
if (!(Test-Path $winuiPatch)) { throw "The required WinUI STA patch is missing: $winuiPatch" }
function Get-LfSha256([string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}
$winuiPreimageSha256 = '535c8d612534b662d609b55159fca539b8fa3da03da71bab745c0f71295259fc'
$winuiPostimageSha256 = 'a2a71a080b27b7555ce7388daf2015bd9bc9a5cbbf9b3f4d5251ad5eb64e587d'
$winuiText = [IO.File]::ReadAllText($winuiSource)
$winuiNormalized = $winuiText.Replace("`r`n", "`n").Replace("`r", "`n")
$winuiHash = Get-LfSha256 $winuiNormalized
if ($winuiHash -eq $winuiPreimageSha256) {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (!$git) { throw 'Git for Windows is required to apply the pinned swift-winui STA patch.' }
    $winuiFile = Get-Item -LiteralPath $winuiSource
    if ($winuiFile.IsReadOnly) { $winuiFile.IsReadOnly = $false }
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($winuiSource, $winuiNormalized, $utf8NoBom)
    $previousErrorPreference = $ErrorActionPreference
    $patchApplyExit = 0
    try {
        $ErrorActionPreference = 'Continue'
        & $git.Source -C $winuiCheckout apply $winuiPatch
        $patchApplyExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    if ($patchApplyExit -ne 0) { throw 'Failed to apply the pinned WinUI STA patch.' }
    $winuiNormalized = ([IO.File]::ReadAllText($winuiSource)).Replace("`r`n", "`n").Replace("`r", "`n")
    $winuiHash = Get-LfSha256 $winuiNormalized
}
if ($winuiHash -ne $winuiPostimageSha256) {
    throw 'The pinned WinUI source matches neither the approved STA patch preimage nor postimage.'
}
$crossUIPin = $resolved.pins | Where-Object { $_.identity -eq 'swift-cross-ui' } | Select-Object -First 1
$crossUIRevision = '0f3ec3958b79cdc39a1a3e604516b71ab33a9043'
if (!$crossUIPin -or $crossUIPin.state.version -ne '0.10.0' -or $crossUIPin.state.revision -ne $crossUIRevision) {
    throw 'The WinUI patch is pinned to swift-cross-ui 0.10.0 at the approved revision; update the patch with any dependency change.'
}
$crossUICheckout = Join-Path $BuildPath 'checkouts/swift-cross-ui'
$crossUISource = Join-Path $crossUICheckout 'Sources/WinUIBackend/WinUIBackend.swift'
if (!(Test-Path $crossUISource)) { throw "Resolved swift-cross-ui source was not found at $crossUISource." }
$crossUIPatch = Join-Path $root 'Windows/Patches/swift-cross-ui-0.10.0-winui.patch'
if (!(Test-Path $crossUIPatch)) { throw "The required SwiftCrossUI WinUI patch is missing: $crossUIPatch" }
$crossUIPreimageSha256 = '9e05b833533c9c75ad702d9f17a35bc141b837ad2496c3171ec4059fa20d7d75'
$crossUIPostimageSha256 = '6aab51b8f530b53f9a01d800fed5c594571adfd4a15baf761557e8efa7c51962'
$crossUIText = [IO.File]::ReadAllText($crossUISource)
$crossUINormalized = $crossUIText.Replace("`r`n", "`n").Replace("`r", "`n")
$crossUIHash = Get-LfSha256 $crossUINormalized
if ($crossUIHash -eq $crossUIPreimageSha256) {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (!$git) { throw 'Git for Windows is required to apply the pinned SwiftCrossUI WinUI patch.' }
    $crossUIFile = Get-Item -LiteralPath $crossUISource
    if ($crossUIFile.IsReadOnly) { $crossUIFile.IsReadOnly = $false }
    $crossUIUtf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($crossUISource, $crossUINormalized, $crossUIUtf8NoBom)
    $crossUIPreviousErrorPreference = $ErrorActionPreference
    $crossUIPatchApplyExit = 0
    try {
        $ErrorActionPreference = 'Continue'
        & $git.Source -C $crossUICheckout apply $crossUIPatch
        $crossUIPatchApplyExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $crossUIPreviousErrorPreference
    }
    if ($crossUIPatchApplyExit -ne 0) { throw 'Failed to apply the pinned SwiftCrossUI WinUI patch.' }
    $crossUINormalized = ([IO.File]::ReadAllText($crossUISource)).Replace("`r`n", "`n").Replace("`r", "`n")
    $crossUIHash = Get-LfSha256 $crossUINormalized
}
if ($crossUIHash -ne $crossUIPostimageSha256) {
    throw 'The pinned SwiftCrossUI source matches neither the approved WinUI patch preimage nor postimage.'
}
if ($Action -eq 'resolve') {
    Write-Output 'Prepared SQLite 3.54.1 and verified the pinned swift-winui STA and SwiftCrossUI activation/text-measurement patches.'
    return
}
if ($Action -eq 'test') {
    $bin = (& $swift build @common -c $Configuration --show-bin-path | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or !$bin) { throw 'SwiftPM did not report the test executable directory.' }
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item $sqliteDll (Join-Path $bin 'sqlite3.dll') -Force
    & $swift test @common @buildOptions -c $Configuration --jobs $Jobs @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Windows tests failed.' }
    return
}
$builtAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
$git = Get-Command git -ErrorAction SilentlyContinue
$tagVersion = $null
if ([string]::IsNullOrEmpty($env:TM_VERSION) -and $git) {
    $tag = & $git.Source -C $root describe --tags --match 'v[0-9]*' --exact-match 2>$null
    if ($LASTEXITCODE -eq 0 -and $tag -match '^v[0-9]+(\.[0-9]+){1,2}$') {
        $tagVersion = $tag.Substring(1)
    }
}
$rawVersion = if (![string]::IsNullOrEmpty($env:TM_VERSION)) { $env:TM_VERSION }
    elseif ($tagVersion) { $tagVersion } else { '' }
if ($rawVersion.StartsWith('v')) { $rawVersion = $rawVersion.Substring(1) }
$isDevelopment = [string]::IsNullOrEmpty($env:TM_VERSION) -and !$tagVersion
if ([string]::IsNullOrEmpty($rawVersion)) { $rawVersion = '1.0' }
if ($rawVersion -notmatch '^[0-9]+(\.[0-9]+){1,2}$') {
    throw "TM_VERSION/tag must be a semantic numeric version (for example 1.0 or 1.2.3): $rawVersion"
}
$sourceCommit = $null
if ($git) {
    $commit = & $git.Source -C $root rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $commit -match '^[0-9a-fA-F]{40,64}$') {
        $sourceCommit = $commit.ToLowerInvariant()
    }
}
$buildInfo = [ordered]@{
    version = $rawVersion
    commit = $sourceCommit
    builtAtUtc = $builtAtUtc
    isDevelopment = $isDevelopment
}
& $swift build @common @buildOptions -c $Configuration --jobs $Jobs --product ToastMonitorRuntime
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
$bin = (& $swift build @common -c $Configuration --show-bin-path | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or !$bin) { throw 'SwiftPM did not report the executable directory.' }
Copy-Item $sqliteDll (Join-Path $bin 'sqlite3.dll') -Force
$buildInfoPath = Join-Path $bin 'ToastMonitor-buildinfo.json'
$buildInfo | ConvertTo-Json -Compress | Set-Content -LiteralPath $buildInfoPath -Encoding utf8
$executable = Join-Path $bin 'ToastMonitor.exe'
$launcher = Join-Path $root 'Windows/Launcher/main.c'
$launcherObject = Join-Path $bin 'ToastMonitorLauncher.obj'
& cl.exe /nologo /MD /O2 $launcher "/Fo$launcherObject" "/Fe$executable" /link "/LIBPATH:$bin" ToastMonitorRuntime.lib /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup /INCREMENTAL:NO
if ($LASTEXITCODE -ne 0) { throw 'The native Windows launcher build failed.' }
if ($Action -eq 'run') {
    & $executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ToastMonitor exited with code $LASTEXITCODE." }
    return
}
if ($Action -ne 'package') { Write-Output $executable; return }
if (!$OutputPath) { $OutputPath = Join-Path $root 'dist/ToastMonitor-Windows-x64' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path $OutputPath) { throw "Choose an empty package destination: $OutputPath" }
New-Item -ItemType Directory -Path $OutputPath | Out-Null
Copy-Item $executable $OutputPath
Copy-Item $buildInfoPath $OutputPath
# Only the application DLL is shipped; Swift/VC/SQLite runtimes remain prerequisites.
Copy-Item (Join-Path $bin 'ToastMonitorRuntime.dll') $OutputPath
Get-ChildItem $bin -Directory | Where-Object { $_.Name -match '\.(resources|bundle)$' } |
    Copy-Item -Destination $OutputPath -Recurse -Force
Copy-Item (Join-Path $root 'LICENSE') $OutputPath
# Preserve licenses/notices for the SwiftPM dependencies actually resolved for this build.
$licenseDirectory = Join-Path $OutputPath 'ThirdPartyNotices'
New-Item -ItemType Directory -Path $licenseDirectory | Out-Null
Get-Content (Join-Path $sqliteInclude 'sqlite3.h') -TotalCount 10 |
    Set-Content (Join-Path $licenseDirectory 'SQLite-3.54.1-public-domain-notice.txt') -Encoding utf8
Get-ChildItem (Join-Path $BuildPath 'checkouts') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $dependencyName = $_.Name
    Get-ChildItem $_.FullName -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPY|NOTICE|PATENTS).*$' } | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $licenseDirectory "$dependencyName-$($_.Name)")
    }
}
# Swift runtime licensing, pinned to the source tag used by the installed toolchain.
$swiftLicense = Join-Path $licenseDirectory 'Swift-6.1.3-LICENSE.txt'
Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/swiftlang/swift/swift-6.1.3-RELEASE/LICENSE.txt' -OutFile $swiftLicense
if ((Get-FileHash $swiftLicense -Algorithm SHA256).Hash -ne '770AF8291F708538D8FF885A0BBC4E045CD700531741C4F99528D435C14D7F55') {
    throw 'Swift 6.1.3 license checksum mismatch.'
}
# Swift Foundation and libdispatch runtime sources use these release-tagged licenses.
function Save-VerifiedLicense([string]$Url, [string]$Name, [string]$Sha256) {
    $path = Join-Path $licenseDirectory $Name
    Invoke-WebRequest -UseBasicParsing $Url -OutFile $path
    if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $Sha256) {
        throw "License checksum mismatch: $Name"
    }
}
# swift-crypto vendors CCryptoBoringSSL from this exact commit; retain its root license verbatim.
Save-VerifiedLicense 'https://raw.githubusercontent.com/google/boringssl/0226f30467f540a3f62ef48d453f93927da199b6/LICENSE' `
    'BoringSSL-0226f30467f540a3f62ef48d453f93927da199b6-LICENSE.txt' `
    '827C8D8FC207C2392794EEF9E00FE246F9F61FDCC132556C275BE3DD8C3CD97F'
Save-VerifiedLicense 'https://raw.githubusercontent.com/swiftlang/swift-foundation/swift-6.1.3-RELEASE/LICENSE.md' 'Swift-Foundation-LICENSE.md' '2245A990B635558BE210FB3EB4F8A6F7A49AEBC0FEFBF5859146A65DDC7DDCF3'
# corelibs-foundation and libdispatch 6.1.3 carry byte-identical Apache 2.0 + Runtime Library Exception terms.
Save-VerifiedLicense 'https://raw.githubusercontent.com/swiftlang/swift-corelibs-libdispatch/swift-6.1.3-RELEASE/LICENSE' 'Swift-corelibs-LICENSE' '0CA84095D1DE77CAD1A866EBBAD28F8DB98A0826C6055D92B0608C5BAA1643E2'
# Foundation ICU's 74.1 Unicode/ICU license includes its third-party notices.
Save-VerifiedLicense 'https://raw.githubusercontent.com/unicode-org/icu/release-74-1/LICENSE' 'ICU-74.1-LICENSE' '17510CF7A58B4879B887EC05A45D72CF1B73544DD9EC7E72F20110ED104229EE'
# Retain the matching Windows App SDK license/NOTICE without redistributing its runtime payloads.
$sdkPackage = Join-Path $BuildPath 'microsoft.windowsappsdk.1.5.240607001.nupkg'
if (!(Test-Path $sdkPackage)) {
    Invoke-WebRequest -UseBasicParsing 'https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk/1.5.240607001/microsoft.windowsappsdk.1.5.240607001.nupkg' -OutFile $sdkPackage
}
if ((Get-FileHash $sdkPackage -Algorithm SHA256).Hash -ne '16E66BBA4F1637014831BF54946A8B21A07F3F089D4201913E8E1E8B7C093337') {
    throw 'Windows App SDK NuGet package checksum mismatch.'
}
Copy-ZipEntry $sdkPackage 'license.txt' (Join-Path $licenseDirectory 'Microsoft-WindowsAppSDK-license.txt')
Copy-ZipEntry $sdkPackage 'NOTICE.txt' (Join-Path $licenseDirectory 'Microsoft-WindowsAppSDK-NOTICE.txt')
Compress-Archive -Path (Join-Path $OutputPath '*') -DestinationPath ($OutputPath + '.zip')
Write-Output ($OutputPath + '.zip')
