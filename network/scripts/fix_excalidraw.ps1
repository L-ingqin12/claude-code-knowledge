$diagramsDir = "D:\Document\local\knowledge\diagrams"
$files = Get-ChildItem $diagramsDir -Filter "*.excalidraw.md"

foreach ($file in $files) {
    Write-Host "Fixing: $($file.Name)"
    $content = Get-Content $file.FullName -Raw -Encoding UTF8

    # Extract JSON between first { and last } before %%
    $jsonStart = $content.IndexOf("`n{")
    $jsonEnd = $content.LastIndexOf("}`n")
    if ($jsonStart -lt 0 -or $jsonEnd -le $jsonStart) {
        Write-Host "  SKIP: can't find JSON"
        continue
    }

    $jsonStr = $content.Substring($jsonStart + 1, $jsonEnd - $jsonStart)
    $data = $jsonStr | ConvertFrom-Json

    # Fix all elements
    foreach ($e in $data.elements) {
        if (-not $e.groupIds) { $e | Add-Member -MemberType NoteProperty -Name "groupIds" -Value @() -Force }
        if (-not $e.angle) { $e | Add-Member -MemberType NoteProperty -Name "angle" -Value 0 -Force }
        if (-not $e.strokeStyle) { $e | Add-Member -MemberType NoteProperty -Name "strokeStyle" -Value "solid" -Force }
        if (-not $e.seed) { $e | Add-Member -MemberType NoteProperty -Name "seed" -Value 123456789 -Force }

        if ($e.type -eq "rectangle") {
            if (-not $e.roundness) { $e | Add-Member -MemberType NoteProperty -Name "roundness" -Value (@{type=3}) -Force }
        }
        elseif ($e.type -eq "arrow") {
            if (-not $e.roundness) { $e | Add-Member -MemberType NoteProperty -Name "roundness" -Value $null -Force }
            if (-not $e.startBinding) { $e | Add-Member -MemberType NoteProperty -Name "startBinding" -Value $null -Force }
            if (-not $e.endBinding) { $e | Add-Member -MemberType NoteProperty -Name "endBinding" -Value $null -Force }
            if (-not $e.lastCommittedPoint) { $e | Add-Member -MemberType NoteProperty -Name "lastCommittedPoint" -Value $null -Force }
        }
        elseif ($e.type -eq "text") {
            if (-not $e.roundness) { $e | Add-Member -MemberType NoteProperty -Name "roundness" -Value $null -Force }
            if (-not $e.fontSize) { $e | Add-Member -MemberType NoteProperty -Name "fontSize" -Value 16 -Force }
            if (-not $e.fontFamily) { $e | Add-Member -MemberType NoteProperty -Name "fontFamily" -Value 2 -Force }
            if (-not $e.textAlign) { $e | Add-Member -MemberType NoteProperty -Name "textAlign" -Value "center" -Force }
            if (-not $e.verticalAlign) { $e | Add-Member -MemberType NoteProperty -Name "verticalAlign" -Value "middle" -Force }
            if (-not $e.containerId) { $e | Add-Member -MemberType NoteProperty -Name "containerId" -Value $null -Force }
            if (-not $e.originalText) { $e | Add-Member -MemberType NoteProperty -Name "originalText" -Value $e.text -Force }
            if (-not $e.lineHeight) { $e | Add-Member -MemberType NoteProperty -Name "lineHeight" -Value 1.2 -Force }
        }
    }

    if (-not $data.appState.theme) {
        $data.appState | Add-Member -MemberType NoteProperty -Name "theme" -Value "dark" -Force
    }

    $newJson = $data | ConvertTo-Json -Depth 10 -Compress

    $newContent = @"
---
excalidraw-plugin: parsed
excalidraw-export-transparent: false
excalidraw-export-dark: false
---
# Text Elements

# Embedded files

%%
````json
$newJson
````
%%
"@

    $newContent | Set-Content $file.FullName -Encoding UTF8 -NoNewline
    Write-Host "  OK: $($data.elements.Count) elements"
}

Write-Host ""
Write-Host "All files fixed. Open in Obsidian to verify."
