using namespace System.Net

# Input bindings são passados através do bloco param.
# Input bindings are passed through the param block.
param($Request, $TriggerMetadata)

# Adiciona o parâmetro viewlog
# Add the viewlog parameter
# 0 para desativar logs, 1 para ativar logs
# 0 to disable logs, 1 to enable logs
$viewlog = 0  

# Função auxiliar para controle de logs
# Helper function for log control
function Log-Output {
    param (
        [string]$message
    )
    if ($viewlog -eq 1) {
        Write-Output $message
    }
}

$Catalog = $Request.Body.Catalog
$ConnectionString = $Request.Body.ConnectionString
$RulesAdress = $Request.Body.RulesAdress
$TenantId = $Request.Body.TenantId
$AppId = $Request.Body.AppId
$AppSecret = $Request.Body.AppSecret

# Obtém o caminho temporário para as Funções do Azure
# Get the temporary path for Azure Functions
$tempPath = [System.Environment]::GetEnvironmentVariable("TEMP")

# Define caminhos para download e extração
# Define paths for download and extraction
$downloadPath = Join-Path -Path $tempPath -ChildPath "TabularEditor.Portable.zip"
$extractPath = Join-Path -Path $tempPath -ChildPath "TabularEditor"

# Verifica se o Tabular Editor já existe
# Check if Tabular Editor already exists
$tabularEditorExe = Join-Path -Path $extractPath -ChildPath "TabularEditor.exe"
if (Test-Path $tabularEditorExe) {
    Log-Output "Tabular Editor already exists at $extractPath."
}
else {
    # Baixa e instala o Tabular Editor
    # Download and install Tabular Editor
    $tabularEditorUrl = "https://cdn.tabulareditor.com/files/TabularEditor.2.25.0.zip"

    # Mensagens de saída para o log das Funções do Azure
    # Log messages for Azure Functions
    Log-Output "Downloading Tabular Editor from $tabularEditorUrl."

    # Usa WebClient para download
    # Use WebClient for download
    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($tabularEditorUrl, $downloadPath)

    Log-Output "Extracting Tabular Editor to $extractPath"
    Expand-Archive -Path $downloadPath -DestinationPath $extractPath

    Log-Output "Tabular Editor downloaded and extracted successfully."
}

# Verifica e cria o diretório de exportação, se necessário
# Check and create the export directory if necessary
$exportDir = Join-Path -Path $tempPath -ChildPath "BPAA_Output/TabularEditorPortable"
if (!(Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir | Out-Null
    Log-Output "Export directory created at $exportDir."
}
else {
    Log-Output "Export directory already exists at $exportDir."
}

# Caminho completo do arquivo de exportação
# Full path of the export file
$ExportFile = Join-Path -Path $exportDir -ChildPath "Export.txt"

# Comando para executar o Tabular Editor
# Command to execute Tabular Editor
$CmdCommand = @"
$tabularEditorExe "Provider=MSOLAP;Data Source=$ConnectionString;User ID=app:$AppId@$TenantId;Password=$AppSecret" "$Catalog" -A "$RulesAdress" "-trx" "$ExportFile"
"@

# Executar o comando CMD sem abrir uma nova janela do CMD
# Execute CMD command without opening a new CMD window
$processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
$processStartInfo.FileName = "cmd.exe"
$processStartInfo.Arguments = "/c $CmdCommand"
$processStartInfo.RedirectStandardOutput = $true
$processStartInfo.RedirectStandardError = $true
$processStartInfo.UseShellExecute = $false
$processStartInfo.CreateNoWindow = $true

$process = [System.Diagnostics.Process]::Start($processStartInfo)

$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()

$process.WaitForExit()

# Log do conteúdo de $stdout para depuração
# Log content of $stdout for debugging
Log-Output "Content of stdout:"
Log-Output $stdout

# Log do conteúdo de $stderr para depuração
# Log content of $stderr for debugging
Log-Output "Content of stderr:"
Log-Output $stderr

# Remover partes desnecessárias da saída
# Remove unnecessary parts of the output
$stdout = $stdout -replace "Tabular Editor .*", ""
$stdout = $stdout -replace "Loading model\.\.\.", ""
$stdout = $stdout -replace "Running Best Practice Analyzer\.\.\.", ""
$stdout = $stdout -replace "Using System Proxy without credentials", ""
$stdout = $stdout -replace "VSTest XML file saved:.*", ""
$stdout = $stdout -replace "=================================", ""

# Log do conteúdo de $stdout após limpeza
# Log content of $stdout after cleaning
Log-Output "Content of stdout after cleaning:"
Log-Output $stdout

# Inicializar a lista de violações
# Initialize the list of violations
$violations = @()

# Processar cada linha de saída
# Process each line of output
$stdout -split "`n" | ForEach-Object {
    Log-Output "Line: $_" 
    # Log para verificar cada linha
    # Log to check each line

    # Dividir a linha com base na parte "violates rule"
    # Split the line based on the "violates rule" part
    $parts = $_ -split " violates rule "

    if ($parts.Length -eq 2) {
        $description = $parts[0]
        $rule = $parts[1] -replace "`r", "" # Remover o caractere de retorno de carro
        # Remove carriage return character

        # Dividir a descrição para capturar Tipo e Local
        # Split description to capture Type and Location
        if ($description -match "^(Column|Table|Model|Partition) '([^']*)'\[([^]]*)\]") {
            $Scope = $matches[1]
            $Place = "$($matches[2])[$($matches[3])]"

            # Extrair Tipo Infração e Regra de forma simplificada
            # Extract Violation Type and Rule in a simplified manner
            $Category = ($rule -split " ")[0] -replace '\"', "" -replace "^\[|\]$", ""
            $Rule = ($rule -split "] ")[1] -replace '\"', ""

            # Adicionar a violação à lista
            # Add violation to the list
            $violations += [PSCustomObject]@{
                ConnectionString = $ConnectionString
                Catalog          = $Catalog
                Scope            = $Scope
                Place            = $Place
                Category         = $Category
                Rule             = $Rule
            }
        }
        else {
            Log-Output "Description does not match the pattern: $description"
        }
    }
    else {
        Log-Output "Line does not match the pattern: $_"
    }
}

# Baixar e carregar o arquivo RulesAdress
# Download and load the RulesAdress file
$rulesPath = Join-Path -Path $tempPath -ChildPath "Rules.json"
$webClient.DownloadFile($RulesAdress, $rulesPath)

# Carregar regras do JSON em uma variável
# Load rules from JSON into a variable
$rulesJson = Get-Content -Path $rulesPath | ConvertFrom-Json

# Log do conteúdo do rulesJson
# Log content of rulesJson
Log-Output "Content of rulesJson:"
$rulesJson | ForEach-Object { Log-Output "$($_.Name) | $($_.ID) | $($_.Severity)" }

# Cruzar os dados de violações com o RulesAdress
# Cross-reference violation data with RulesAdress
foreach ($violation in $violations) {
    $combinedRule = "[$($violation.Category)] $($violation.Rule)"
    $matchingRule = $rulesJson | Where-Object { $_.Name -eq $combinedRule }
    if ($matchingRule) {
        $violation | Add-Member -MemberType NoteProperty -Name "ID" -Value $matchingRule.ID
        $violation | Add-Member -MemberType NoteProperty -Name "Severity" -Value $matchingRule.Severity
    }
}

# Contar o número de violações
# Count the number of violations
$violationCount = $violations.Count

# Adicionar a contagem e erros ao corpo da resposta
# Add count and errors to the response body
$body = "Total Violations: $violationCount`n"
if ($violationCount -gt 0) {
    $jsonOutput = $violations | ConvertTo-Json -Compress
    $body += $jsonOutput
}
else {
    $body += "`nNo violations found."
}

# Retornar a resposta HTTP.
# Return HTTP response
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $body
    })
