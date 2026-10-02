# =============================================================================
#  Сборка руководства в Word: docs\MANUAL.md -> .docx
#
#  Файл собирается как Office Open XML и упаковывается в zip. Word не нужен
#  вообще: на этой машине Office не активирован (LicenseStatus 5) и в режиме
#  ограниченной функциональности открывает файлы, но не сохраняет — SaveAs2
#  висит на невидимом диалоге активации. LibreOffice и pandoc тоже не стоят.
#
#  Что поддерживается из Markdown (ровно столько, сколько нужно MANUAL.md):
#  титульные данные (front matter), заголовки #…####, абзацы, маркированные и
#  нумерованные списки с переносами, таблицы, блоки кода, цитаты, **жирный**,
#  `код`.
#
#  Запуск:
#     powershell -ExecutionPolicy Bypass -File docs\build-doc.ps1
# =============================================================================

param(
  [string]$Src,
  [string]$OutDir,
  [string]$BaseName = 'JMD-2L CNC - Руководство'
)

$ErrorActionPreference = "Stop"

if (-not $Src)    { $Src    = Join-Path $PSScriptRoot 'MANUAL.md' }
if (-not $OutDir) { $OutDir = $PSScriptRoot }
if (-not (Test-Path $Src)) { throw "Не найден исходник: $Src" }

$Docx = Join-Path $OutDir "$BaseName.docx"
$enc  = New-Object System.Text.UTF8Encoding $false   # BOM в XML не нужен

# =============================================================================
#  1. Разбор Markdown
# =============================================================================

$lines = [IO.File]::ReadAllLines($Src, [Text.Encoding]::UTF8)
$i = 0
$meta = @{}
if ($lines.Count -gt 0 -and $lines[0].Trim() -eq '---') {
  $i = 1
  while ($i -lt $lines.Count -and $lines[$i].Trim() -ne '---') {
    if ($lines[$i] -match '^\s*([A-Za-z]+)\s*:\s*(.+?)\s*$') { $meta[$Matches[1]] = $Matches[2] }
    $i++
  }
  $i++
}

# --- вспомогательные функции разбора -------------------------------------------

function Esc([string]$s) {
  if ($null -eq $s) { return '' }
  $s = $s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''   # управляющие символы Word не берёт
  return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Run([string]$text, [string]$rstyle, [bool]$bold) {
  if ($text -eq '') { return '' }
  $rpr = ''
  if ($rstyle -or $bold) {
    $rpr = '<w:rPr>'
    if ($rstyle) { $rpr += "<w:rStyle w:val=`"$rstyle`"/>" }
    if ($bold)   { $rpr += '<w:b/>' }
    $rpr += '</w:rPr>'
  }
  return "<w:r>$rpr<w:t xml:space=`"preserve`">$text</w:t></w:r>"
}

# Строка с **жирным** и `код` -> последовательность w:r
function Runs([string]$s) {
  $out = New-Object System.Collections.ArrayList
  $pos = 0
  foreach ($m in [regex]::Matches($s, '(`[^`]+`|\*\*[^*]+\*\*)')) {
    if ($m.Index -gt $pos) {
      [void]$out.Add((Run (Esc $s.Substring($pos, $m.Index - $pos)) '' $false))
    }
    $t = $m.Value
    if ($t.StartsWith('`')) {
      [void]$out.Add((Run (Esc $t.Substring(1, $t.Length - 2)) 'CodeChar' $false))
    } else {
      [void]$out.Add((Run (Esc $t.Substring(2, $t.Length - 4)) '' $true))
    }
    $pos = $m.Index + $t.Length
  }
  if ($pos -lt $s.Length) { [void]$out.Add((Run (Esc $s.Substring($pos)) '' $false)) }
  return ($out -join '')
}

# --- основной проход -----------------------------------------------------------

$blocks = New-Object System.Collections.ArrayList
$para   = New-Object System.Collections.ArrayList
$list   = $null          # @{ t = 'ul'|'ol'; items = ArrayList }
$quote  = New-Object System.Collections.ArrayList

function FlushPara {
  if ($para.Count -gt 0) {
    [void]$script:blocks.Add(@{ t = 'p'; x = ($para -join ' ') })
    $para.Clear()
  }
}
function FlushQuote {
  if ($quote.Count -gt 0) {
    [void]$script:blocks.Add(@{ t = 'quote'; x = ($quote -join ' ') })
    $quote.Clear()
  }
}
function FlushList {
  if ($script:list) {
    [void]$script:blocks.Add($script:list)
    $script:list = $null
  }
}
function FlushAll { FlushPara; FlushQuote; FlushList }

$inCode = $false
$codeBuf = New-Object System.Collections.ArrayList

while ($i -lt $lines.Count) {
  $line = $lines[$i]

  # --- блок кода ---
  if ($line -match '^\s*```') {
    FlushAll
    if ($inCode) {
      [void]$blocks.Add(@{ t = 'pre'; lines = @($codeBuf) })
      $codeBuf.Clear(); $inCode = $false
    } else { $inCode = $true }
    $i++; continue
  }
  if ($inCode) { [void]$codeBuf.Add($line); $i++; continue }

  # --- пустая строка ---
  if ([string]::IsNullOrWhiteSpace($line)) { FlushAll; $i++; continue }

  # --- горизонтальная черта: пропускаем ---
  if ($line -match '^\s*-{3,}\s*$') { FlushAll; $i++; continue }

  # --- заголовок ---
  if ($line -match '^(#{1,4})\s+(.*)$') {
    FlushAll
    [void]$blocks.Add(@{ t = 'h'; lvl = $Matches[1].Length; x = $Matches[2].Trim() })
    $i++; continue
  }

  # --- таблица: строка с плюсом и следующая-разделитель ---
  if ($line.Trim() -match '^\|' -and ($i + 1) -lt $lines.Count -and
      $lines[$i + 1].Trim() -match '^\|[\s:|-]+\|?\s*$') {
    FlushAll
    $head = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    $i += 2
    $rows = New-Object System.Collections.ArrayList
    while ($i -lt $lines.Count -and $lines[$i].Trim() -match '^\|') {
      [void]$rows.Add(@($lines[$i].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }))
      $i++
    }
    [void]$blocks.Add(@{ t = 'table'; head = $head; rows = @($rows) })
    continue
  }

  # --- цитата: соседние строки склеиваются в один абзац ---
  if ($line -match '^>\s?(.*)$') {
    FlushPara; FlushList
    [void]$quote.Add($Matches[1].Trim())
    $i++; continue
  }
  FlushQuote

  # --- маркированный список ---
  if ($line -match '^\s*[-*]\s+(.*)$') {
    FlushPara
    if (-not $list -or $list.t -ne 'ul') { FlushList; $list = @{ t = 'ul'; items = (New-Object System.Collections.ArrayList) } }
    [void]$list.items.Add($Matches[1].Trim())
    $i++; continue
  }

  # --- нумерованный список ---
  if ($line -match '^\s*\d+\.\s+(.*)$') {
    FlushPara
    if (-not $list -or $list.t -ne 'ol') { FlushList; $list = @{ t = 'ol'; items = (New-Object System.Collections.ArrayList) } }
    [void]$list.items.Add($Matches[1].Trim())
    $i++; continue
  }

  # --- продолжение пункта списка (строка с отступом) ---
  if ($list -and $line -match '^\s{2,}\S') {
    $k = $list.items.Count - 1
    $list.items[$k] = $list.items[$k] + ' ' + $line.Trim()
    $i++; continue
  }

  # --- обычный абзац ---
  FlushList
  [void]$para.Add($line.Trim())
  $i++
}
FlushAll

# =============================================================================
#  2. Сборка document.xml
# =============================================================================

$CW = 9354          # ширина набора A4 при полях 2 см, в твипах
$body = New-Object System.Collections.ArrayList

# --- абзац-конструктор ---
function P([string]$pstyle, [string]$runs, [string]$pprExtra) {
  if ([string]::IsNullOrEmpty($pstyle) -and [string]::IsNullOrEmpty($pprExtra)) {
    return "<w:p>$runs</w:p>"
  }
  $ppr = '<w:pPr>'
  if ($pstyle)     { $ppr += "<w:pStyle w:val=`"$pstyle`"/>" }
  if ($pprExtra)   { $ppr += $pprExtra }
  $ppr += '</w:pPr>'
  return "<w:p>$ppr$runs</w:p>"
}

function CellXml([string]$text, [int]$width, [bool]$header) {
  $tcpr = "<w:tcPr><w:tcW w:w=`"$width`" w:type=`"dxa`"/>"
  if ($header) { $tcpr += '<w:shd w:val="clear" w:color="auto" w:fill="E8E8E8"/>' }
  $tcpr += '<w:vAlign w:val="top"/></w:tcPr>'
  $ppr = '<w:pPr><w:spacing w:before="20" w:after="20"/><w:jc w:val="left"/></w:pPr>'
  $sz = '<w:rPr><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr>'
  $runs = Runs $text
  # уменьшенный кегль в таблице: заменяем только базовый rPr
  $runs = $runs -replace '<w:r><w:t', "<w:r>$sz<w:t"
  if ($header) { $runs = $runs -replace '<w:r>(<w:rPr>)?(<w:t)', "<w:r>`$1<w:b/>`$2" }
  return "<w:tc>$tcpr$(P '' $runs $ppr)</w:tc>"
}

function TableXml([string[]]$head, [object[]]$rows) {
  $n = $head.Count
  # ширины колонок пропорционально самой длинной ячейке, но не уже 9 % и не шире 45 %
  $w = @(); for ($c = 0; $c -lt $n; $c++) { $w += 8 }
  for ($c = 0; $c -lt $n; $c++) {
    $max = ($head[$c]).Length
    foreach ($r in $rows) { if ($c -lt $r.Count -and $r[$c].Length -gt $max) { $max = $r[$c].Length } }
    $w[$c] = $max
  }
  $sum = ($w | Measure-Object -Sum).Sum
  $px  = @(); $acc = 0
  for ($c = 0; $c -lt $n; $c++) {
    if ($c -eq $n - 1) { $px += $CW - $acc }
    else {
      $v = [int][math]::Round($CW * $w[$c] / $sum)
      $min = [int]($CW * 0.09)
      if ($v -lt $min) { $v = $min }
      $px += $v; $acc += $v
    }
  }
  $bd = '<w:tblBorders>' +
        '<w:top w:val="single" w:sz="4" w:space="0" w:color="808080"/>' +
        '<w:left w:val="single" w:sz="4" w:space="0" w:color="808080"/>' +
        '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="808080"/>' +
        '<w:right w:val="single" w:sz="4" w:space="0" w:color="808080"/>' +
        '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="808080"/>' +
        '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="808080"/>' +
        '</w:tblBorders>'
  $t = '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/>' + $bd +
       '<w:tblCellMar><w:top w:w="60" w:type="dxa"/><w:left w:w="100" w:type="dxa"/>' +
       '<w:bottom w:w="60" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar>' +
       '</w:tblPr><w:tblGrid>'
  foreach ($v in $px) { $t += "<w:gridCol w:w=`"$v`"/>" }
  $t += '</w:tblGrid>'
  $t += '<w:tr><w:trPr><w:tblHeader/></w:trPr>'
  for ($c = 0; $c -lt $n; $c++) { $t += CellXml $head[$c] $px[$c] $true }
  $t += '</w:tr>'
  foreach ($r in $rows) {
    $t += '<w:tr>'
    for ($c = 0; $c -lt $n; $c++) {
      $txt = if ($c -lt $r.Count) { $r[$c] } else { '' }
      $t += CellXml $txt $px[$c] $false
    }
    $t += '</w:tr>'
  }
  $t += '</w:tbl>'
  return $t
}

# --- титульный лист ---
$title = if ($meta.ContainsKey('title'))    { $meta['title'] }    else { 'Руководство' }
$sub   = if ($meta.ContainsKey('subtitle')) { $meta['subtitle'] } else { '' }
$ver   = if ($meta.ContainsKey('version'))  { $meta['version'] }  else { '' }
$date  = if ($meta.ContainsKey('date'))     { $meta['date'] }     else { '' }

$ctr = '<w:jc w:val="center"/>'
function TitlePara([string]$text, [int]$sz, [int]$before, [bool]$bold) {
  $rpr = '<w:rPr>'
  if ($bold) { $rpr += '<w:b/>' }
  $rpr += "<w:sz w:val=`"$sz`"/><w:szCs w:val=`"$sz`"/></w:rPr>"
  $r = "<w:r>$rpr<w:t xml:space=`"preserve`">$(Esc $text)</w:t></w:r>"
  return P '' $r ($ctr + "<w:spacing w:before=`"$before`" w:after=`"0`"/>")
}

[void]$body.Add((TitlePara $title 52 3600 $true))
if ($sub) { [void]$body.Add((TitlePara $sub   28 240  $false)) }
if ($ver -or $date) {
  $line = @()
  if ($ver)  { $line += "Версия $ver" }
  if ($date) { $line += $date }
  [void]$body.Add((TitlePara ($line -join '   |   ') 22 1800 $false))
}

# --- содержание ---
[void]$body.Add('<w:p><w:r><w:br w:type="page"/></w:r></w:p>')
[void]$body.Add((TitlePara 'Содержание' 32 0 $true))
$toc = '<w:p><w:pPr>' + $ctr + '</w:pPr>' +
       '<w:r><w:fldChar w:fldCharType="begin"/></w:r>' +
       '<w:r><w:instrText xml:space="preserve"> TOC \o "1-3" \h \z \u </w:instrText></w:r>' +
       '<w:r><w:fldChar w:fldCharType="separate"/></w:r>' +
       '<w:r><w:rPr><w:i/><w:sz w:val="22"/></w:rPr><w:t xml:space="preserve">Оглавление собирается при открытии файла. Не собралось — нажмите Ctrl+A, затем F9.</w:t></w:r>' +
       '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
[void]$body.Add($toc)
[void]$body.Add('<w:p><w:r><w:br w:type="page"/></w:r></w:p>')

# --- содержимое ---
$hCount = @{ 1 = 0; 2 = 0; 3 = 0; 4 = 0 }
$tCount = 0
$liCount = 0
foreach ($b in $blocks) {
  switch ($b.t) {
    'h' {
      $hCount[$b.lvl]++
      [void]$body.Add((P "Heading$($b.lvl)" (Runs $b.x) ''))
    }
    'p'   { [void]$body.Add((P '' (Runs $b.x) '<w:jc w:val="both"/>')) }
    'quote' {
      $ppr = '<w:ind w:left="454"/><w:spacing w:before="120" w:after="120"/><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="A0A0A0"/></w:pBdr>'
      $runs = Runs $b.x
      $runs = $runs -replace '<w:r><w:t', '<w:r><w:rPr><w:i/></w:rPr><w:t'
      [void]$body.Add((P '' $runs $ppr))
    }
    'pre' {
      foreach ($cl in $b.lines) {
        if ($cl -eq '') { [void]$body.Add((P 'Code' '' '')); continue }
        [void]$body.Add((P 'Code' (Run (Esc $cl) '' $false) ''))
      }
    }
    'ul' {
      foreach ($it in $b.items) {
        $liCount++
        [void]$body.Add((P 'ListParagraph' (Runs $it) '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>'))
      }
    }
    'ol' {
      foreach ($it in $b.items) {
        $liCount++
        [void]$body.Add((P 'ListParagraph' (Runs $it) '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>'))
      }
    }
    'table' { $tCount++; [void]$body.Add((TableXml $b.head $b.rows)); [void]$body.Add('<w:p/>') }
  }
}

# --- свойства страницы и колонтитул ---
$sect = '<w:sectPr>' +
        '<w:footerReference w:type="default" r:id="rId4"/>' +
        '<w:pgSz w:w="11906" w:h="16838"/>' +
        '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>' +
        '<w:docGrid w:linePitch="360"/>' +
        '</w:sectPr>'

$documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ' +
'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
'<w:body>' + ($body -join '') + $sect + '</w:body></w:document>'

# =============================================================================
#  3. Остальные части пакета
# =============================================================================

$stylesXml = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults><w:rPrDefault><w:rPr>
<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>
<w:sz w:val="24"/><w:szCs w:val="24"/><w:lang w:val="ru-RU"/></w:rPr></w:rPrDefault>
<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault>
</w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>
<w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="180"/><w:outlineLvl w:val="0"/></w:pPr>
<w:rPr><w:b/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>
<w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="140"/><w:outlineLvl w:val="1"/></w:pPr>
<w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/>
<w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="220" w:after="110"/><w:outlineLvl w:val="2"/></w:pPr>
<w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/>
<w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="180" w:after="90"/><w:outlineLvl w:val="3"/></w:pPr>
<w:rPr><w:b/><w:i/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/>
<w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>
<w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:left="170"/>
<w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr>
<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>
<w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/><w:qFormat/>
<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>
</w:styles>
'@

$numberingXml = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>
<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#8226;"/><w:lvlJc w:val="left"/>
<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
<w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:hint="default"/></w:rPr></w:lvl></w:abstractNum>
<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>
<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/>
<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
</w:numbering>
'@

# updateFields — Word пересобирает оглавление и номера страниц при открытии.
$settingsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
'<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
'<w:updateFields w:val="true"/>' +
'<w:compat><w:compatSetting w:name="compatibilityMode" ' +
'w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>' +
'</w:settings>'

$footerXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
'<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
'<w:p><w:pPr><w:jc w:val="center"/></w:pPr>' +
'<w:r><w:fldChar w:fldCharType="begin"/></w:r>' +
'<w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>' +
'<w:r><w:fldChar w:fldCharType="separate"/></w:r>' +
'<w:r><w:rPr><w:sz w:val="20"/></w:rPr><w:t>1</w:t></w:r>' +
'<w:r><w:fldChar w:fldCharType="end"/></w:r>' +
'</w:p></w:ftr>'

$contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
'<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
'<Default Extension="xml" ContentType="application/xml"/>' +
'<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
'<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>' +
'<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>' +
'<Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>' +
'<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>' +
'<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' +
'<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>' +
'</Types>'

$rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
'<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
'<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
'<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>' +
'</Relationships>'

$docRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
'<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
'<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>' +
'<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>' +
'<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>' +
'</Relationships>'

$iso = $date -replace '^(\d{4})-(\d{2})-(\d{2}).*$', '$1-$2-$3T00:00:00Z'
if ($iso -notmatch '^\d{4}-') { $iso = (Get-Date).ToString('yyyy-MM-dd') + 'T00:00:00Z' }

$coreXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
'<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' +
'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ' +
'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
'<dc:title>' + (Esc $title) + '</dc:title>' +
'<dc:subject>' + (Esc $sub) + '</dc:subject>' +
'<dc:creator>JET JMD-2L CNC</dc:creator>' +
'<cp:lastModifiedBy>JET JMD-2L CNC</cp:lastModifiedBy>' +
'<dcterms:created xsi:type="dcterms:W3CDTF">' + $iso + '</dcterms:created>' +
'<dcterms:modified xsi:type="dcterms:W3CDTF">' + $iso + '</dcterms:modified>' +
'</cp:coreProperties>'

$appXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
'<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">' +
'<Application>docs\build-doc.ps1</Application></Properties>'

# =============================================================================
#  4. Упаковка
# =============================================================================

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

Remove-Item $Docx -Force -ErrorAction SilentlyContinue
# Порядок частей важен: [Content_Types].xml должен идти первым.
$parts = @(
  @{ n = '[Content_Types].xml';        s = $contentTypes },
  @{ n = '_rels/.rels';                s = $rootRels },
  @{ n = 'docProps/core.xml';          s = $coreXml },
  @{ n = 'docProps/app.xml';           s = $appXml },
  @{ n = 'word/document.xml';          s = $documentXml },
  @{ n = 'word/_rels/document.xml.rels'; s = $docRels },
  @{ n = 'word/styles.xml';            s = $stylesXml },
  @{ n = 'word/numbering.xml';         s = $numberingXml },
  @{ n = 'word/settings.xml';          s = $settingsXml },
  @{ n = 'word/footer1.xml';           s = $footerXml }
)

$zip = [System.IO.Compression.ZipFile]::Open($Docx, 'Create')
try {
  foreach ($p in $parts) {
    $entry = $zip.CreateEntry($p.n, [System.IO.Compression.CompressionLevel]::Optimal)
    $st = $entry.Open()
    $bytes = $enc.GetBytes($p.s)
    $st.Write($bytes, 0, $bytes.Length)
    $st.Close()
  }
} finally { $zip.Dispose() }

# =============================================================================
#  5. Проверка
# =============================================================================

$zip = [System.IO.Compression.ZipFile]::OpenRead($Docx)
$names = @()
$xmlOk = $true
try {
  foreach ($e in $zip.Entries) {
    $names += $e.FullName
    $sr = New-Object System.IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd(); $sr.Close()
    try { $null = [xml]$txt } catch { $xmlOk = $false; Write-Output "  XML сломан: $($e.FullName) — $($_.Exception.Message)" -ForegroundColor Red }
  }
} finally { $zip.Dispose() }

Write-Host ""
Write-Host "Файл:  $Docx"
Write-Host ("Размер: {0:N0} КБ" -f ((Get-Item $Docx).Length / 1KB))
Write-Host "Частей: $($names.Count), XML корректен: $xmlOk"
Write-Host "Заголовки: H1=$($hCount[1]) H2=$($hCount[2]) H3=$($hCount[3]) H4=$($hCount[4])"
Write-Host "Таблиц: $tCount, пунктов списка: $liCount"
if (-not $xmlOk) { throw "В собранном файле битый XML — открывать нельзя." }
Write-Host "Готово." -ForegroundColor Green
