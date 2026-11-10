#Requires -Version 5.1
<#
.SYNOPSIS
    BJMPC Toolbox - interface graphique (WPF) pour les scripts de maintenance et d'optimisation Windows 11.
.DESCRIPTION
    Cette application ne duplique aucune logique : elle charge les fonctions de
        BJMPC-Maintenance-Win11.ps1, BJMPC-Optimisation-Win11.ps1, BJMPC-Reglages-Win11.ps1, BJMPC-Outils-Win11.ps1,
        BJMPC-Sauvegarde-Win11.ps1
    (qui doivent rester dans le même dossier) et les exécute en arrière-plan.
    Les questions du script (Read-Host, confirmations) s'affichent sous forme de boîtes de dialogue.
    Chaque modification est enregistrée avant d'être faite (C:\BJMPC-Logs\Backup) : voir Sauvegarde et restauration > "Restauration".

    Interface 2.0 : six sections dans le menu de gauche (Accueil, Réparer, Optimiser, Confidentialité et réglages,
    Logiciels et pilotes, Sauvegardes), chacune avec ses onglets. Une page = un onglet.
#>

$ErrorActionPreference = 'Continue'
$Script:AppVersion = '2.1'
$Script:Root       = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Script:LogDir     = Join-Path $env:SystemDrive 'BJMPC-Logs'
$Script:BackupDir  = Join-Path $Script:LogDir 'Backup'
$Script:LogFile    = Join-Path $Script:LogDir ("Toolbox_{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:StateFile  = Join-Path $Script:BackupDir ("EtatOrigine_{0}.json" -f $env:COMPUTERNAME)

try { New-Item -ItemType Directory -Path $Script:BackupDir -Force -ErrorAction Stop | Out-Null } catch {}

function Write-Crash {
    param([string]$Text)
    try { Add-Content -Path (Join-Path $Script:LogDir 'Toolbox_erreurs.log') -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8 } catch {}
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
} catch {
    Write-Crash "Chargement de WPF impossible : $($_.Exception.Message)"
    exit 1
}

function Show-Fatal {
    param([string]$Message)
    Write-Crash $Message
    [void][Windows.MessageBox]::Show($Message + "`n`nDétails : $Script:LogDir\Toolbox_erreurs.log", 'BJMPC Toolbox', 'OK', 'Error')
}

# ---------------------------------------------------------------- Prérequis
$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}
if (-not $isAdmin -and -not $env:BJMPC_SELFTEST) {
    Show-Fatal "BJMPC Toolbox doit être lancé en administrateur.`nUtilisez BJMPC-Toolbox.bat (clic droit, Exécuter en tant qu'administrateur)."
    exit 1
}

function Protect-LogFolder {
    # C:\BJMPC-Logs est créé à la racine du disque : par défaut, n'importe quel utilisateur peut y écrire. Or la Toolbox
    # y range des pilotes (sauvegardes, paquets en cours de contrôle) qu'elle installe ensuite en administrateur.
    # L'écriture est donc réservée aux administrateurs et au système ; tout le monde garde la lecture.
    # Exception : le sous-dossier Sauvegarde (journaux et dernier résultat seulement), car la sauvegarde vers un partage
    # réseau tourne dans la session de l'utilisateur.
    # Fait une seule fois : un dossier déjà protégé (héritage coupé) n'est plus touché. $Path sert aux essais.
    param([string]$Path = $Script:LogDir)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        if ((Get-Acl -LiteralPath $Path -ErrorAction Stop).AreAccessRulesProtected) { return $true }
        # D'abord tout ce qui demande d'écrire et les droits voulus, en dernier seulement la coupure de l'héritage :
        # le dossier n'est jamais sans accès, même si une étape échoue.
        $bak = Join-Path $Path 'Sauvegarde'
        New-Item -ItemType Directory -Path $bak -Force -ErrorAction Stop | Out-Null
        & icacls.exe $Path /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls /grant a échoué (code $LASTEXITCODE)" }
        & icacls.exe $bak /grant '*S-1-5-11:(OI)(CI)M' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls /grant (Sauvegarde) a échoué (code $LASTEXITCODE)" }
        & icacls.exe $Path /inheritance:r /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls /inheritance a échoué (code $LASTEXITCODE)" }
        # Ancien dossier de travail des pilotes (versions 2.0 et antérieures), dans le dossier temporaire de l'utilisateur.
        try { Remove-Item -LiteralPath (Join-Path $env:TEMP 'bjmpc_drivers') -Recurse -Force -ErrorAction Stop } catch {}
        return $true
    } catch { Write-Crash ("Protection de " + $Path + " : " + $_.Exception.Message); return $false }
}
if ($isAdmin) { [void](Protect-LogFolder) }

# ================================================================ MOTEUR
#region Moteur

$Script:Sync = [hashtable]::Synchronized(@{
    Queue        = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
    Auto         = [hashtable]::Synchronized(@{})
    AutoDefault  = $null
    Prompt       = $null
    PromptAnswer = $null
    PromptEvent  = (New-Object System.Threading.ManualResetEvent $false)
    Cancel       = $false
    Reboot       = $false
    Result       = $null
    Diag         = [hashtable]::Synchronized(@{})
    LogFile      = $Script:LogFile
    Root         = $Script:Root
    EvtQueue     = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')   # surveillance en direct de l'Observateur d'événements
    EvtStop      = $true
    EvtBeat      = $null
})

# Extrait d'un script les fonctions et variables globales, sans exécuter le menu ni la relance admin.
function Get-EngineCode {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Fichier introuvable : $Path" }
    $tokens = $null; $errs = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { throw "Erreur de syntaxe dans $(Split-Path $Path -Leaf) : $($errs[0].Message)" }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $ast.EndBlock.Statements) {
        if ($s -is [Management.Automation.Language.FunctionDefinitionAst]) { $parts.Add($s.Extent.Text) }
        elseif ($s -is [Management.Automation.Language.AssignmentStatementAst]) {
            $left = $s.Left.Extent.Text
            if ($left -notmatch '^\$Host\.' -and $left -notmatch 'emptyCount') { $parts.Add($s.Extent.Text) }
        }
    }
    return ($parts -join "`r`n")
}

# Code injecté au début de chaque exécution : remplace la console par l'interface.
$Script:Prelude = @'
function Get-Auto {
    # Réponse préparée par l'interface pour une question du script (null si aucune).
    param([string]$Text)
    foreach ($k in @($Sync.Auto.Keys)) { if ($Text -match $k) { return [string]$Sync.Auto[$k] } }
    if ($null -ne $Sync.AutoDefault) { return [string]$Sync.AutoDefault }
    return $null
}
function Write-Host {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object, [object]$ForegroundColor, [object]$BackgroundColor, [switch]$NoNewline, [object]$Separator)
    $sep = if ($PSBoundParameters.ContainsKey('Separator')) { [string]$Separator } else { ' ' }
    $t = if ($Object) { (@($Object) | ForEach-Object { [string]$_ }) -join $sep } else { '' }
    # Les menus numérotés du script sont inutiles quand l'interface a déjà fait le choix.
    if (($Sync.Auto.Count -gt 0 -or $null -ne $Sync.AutoDefault) -and $t -match '^\s*\d+\)\s') { return }
    $Sync.Queue.Enqueue([pscustomobject]@{ K = 'log'; T = $t; C = [string]$ForegroundColor })
}
function Clear-Host { }
function Out-Host {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    begin { $buf = @() }
    process { $buf += $InputObject }
    end { if ($buf.Count -gt 0) { Write-Host (($buf | Out-String -Width 200).TrimEnd()) } }
}
function Ask-Gui {
    param([string]$Kind, [string]$Text, [string]$Default)
    $Sync.PromptAnswer = $null
    [void]$Sync.PromptEvent.Reset()
    $Sync.Prompt = [pscustomobject]@{ Kind = $Kind; Text = $Text; Default = $Default }
    $Sync.Queue.Enqueue([pscustomobject]@{ K = 'prompt' })
    while (-not $Sync.PromptEvent.WaitOne(200)) { if ($Sync.Cancel) { throw 'Opération interrompue.' } }
    if ($Sync.Cancel) { throw 'Opération interrompue.' }
    return [string]$Sync.PromptAnswer
}
function Read-Host {
    param([Parameter(Position = 0)][string]$Prompt, [switch]$AsSecureString)
    $a = Get-Auto $Prompt
    if ($null -ne $a) { return $a }
    return (Ask-Gui 'text' $Prompt '')
}
function Confirm-Action {
    param([string]$Question, [bool]$Default = $false)
    if ($Script:AssumeDefaults) { return $Default }
    $a = Get-Auto $Question
    if ($null -ne $a) { return ($a -eq 'yes') }
    $r = Ask-Gui 'yesno' $Question ([string]$Default)
    return ($r -eq 'yes')
}
function Confirm-Strong {
    param([string]$Question)
    if ($Script:AssumeDefaults) { return $false }
    $a = Get-Auto $Question
    if ($null -ne $a) { return ($a -ceq 'OUI') }
    $r = Ask-Gui 'strong' $Question ''
    return ($r -ceq 'OUI')
}
function Wait-Key { }
function Show-Header {
    param([string]$Title)
    if ($Title) { Write-Host ''; Write-Host ('=== ' + $Title + ' ===') -ForegroundColor Yellow }
}
'@

$Script:EngineCode = @{}
$Script:EngineError = $null
try {
    $Script:EngineCode['opt']   = (Get-EngineCode (Join-Path $Script:Root 'BJMPC-Optimisation-Win11.ps1')) + "`r`n" + (Get-EngineCode (Join-Path $Script:Root 'BJMPC-Reglages-Win11.ps1'))
    $Script:EngineCode['maint'] = Get-EngineCode (Join-Path $Script:Root 'BJMPC-Maintenance-Win11.ps1')
    $Script:EngineCode['tools'] = Get-EngineCode (Join-Path $Script:Root 'BJMPC-Outils-Win11.ps1')
    $Script:EngineCode['bak']   = Get-EngineCode (Join-Path $Script:Root 'BJMPC-Sauvegarde-Win11.ps1')
    # Réparation guidée par l'Observateur d'événements : ses réparations appellent les fonctions de Maintenance et d'Outils.
    $Script:EvtCore             = Get-EngineCode (Join-Path $Script:Root 'BJMPC-Evenements-Win11.ps1')
    $Script:EngineCode['evt']   = $Script:EngineCode['maint'] + "`r`n" + $Script:EngineCode['tools'] + "`r`n" + $Script:EvtCore
    $Script:EngineCode['none']  = ''
} catch {
    $Script:EngineError = $_.Exception.Message
}

$Script:Run = $null   # exécution en cours
$Script:RunFlags = @{ Fail = 0; Warn = 0 }

function Start-Run {
    param(
        [string]$Engine = 'none',
        [string]$Code,
        [string]$Title = '',
        [hashtable]$Auto = @{},
        [string]$AutoDefault = '',
        [scriptblock]$OnDone
    )
    if ($Script:Run) { return }
    if ($Script:EngineError) { Show-Fatal $Script:EngineError; return }
    $Script:Sync.Cancel = $false
    $Script:Sync.Result = $null
    $Script:Sync.Auto.Clear()
    foreach ($k in $Auto.Keys) { $Script:Sync.Auto[[string]$k] = [string]$Auto[$k] }
    $Script:Sync.AutoDefault = $(if ($AutoDefault) { $AutoDefault } else { $null })
    [void]$Script:Sync.PromptEvent.Reset()

    # Le moteur d'abord, puis le prélude : les fonctions de l'interface (questions, console) priment sur celles des scripts.
    $init = $Script:EngineCode[$Engine] + "`r`n" + $Script:Prelude + "`r`n"
    if ($Engine -ne 'none') { $init += "`$Script:LogFile = `$Sync.LogFile`r`n" }
    if ($Engine -eq 'opt')  { $init += "Import-Orig`r`n" }
    $wrapped = $init + "try { & {`r`n" + $Code + "`r`n} | Out-Null } catch { Write-Host ('  [X]   ' + `$_.Exception.Message) -ForegroundColor Red } finally { if (`$Script:RebootNeeded) { `$Sync.Reboot = `$true } }"

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $Script:Sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($wrapped)
    $Script:RunFlags.Fail = 0; $Script:RunFlags.Warn = 0
    $Script:Run = [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $null; Title = $Title; OnDone = $OnDone; Started = Get-Date; Code = $Code; Engine = $Engine }
    Set-Busy $true $Title
    $Script:Run.Handle = $ps.BeginInvoke()
}

function Stop-Run {
    if (-not $Script:Run) { return }
    $Script:Sync.Cancel = $true
    try { [void]$Script:Run.PS.BeginStop($null, $null) } catch {}
}

#endregion

# ================================================================ INTERFACE
#region Fenêtre

$Script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BJMPC Toolbox" Width="1320" Height="860" MinWidth="1020" MinHeight="640"
        Background="#050506" Foreground="#ECEDEF" FontFamily="Segoe UI" FontSize="14"
        WindowStartupLocation="CenterScreen" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#ECEDEF"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#2A2E36"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="MinHeight" Value="40"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#14181E"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#5AD1FF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Foreground" Value="#04141C"/>
      <Setter Property="Background" Value="#5AD1FF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="MinHeight" Value="40"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="2" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#8DE0FF"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#FFFFFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C5C9D0"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Background="Transparent" CornerRadius="10" Padding="12,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#101318"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="#14181E"/>
                <Setter Property="Foreground" Value="#5AD1FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Tab" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#9298A3"/>
      <Setter Property="Height" Value="42"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Background="Transparent" BorderBrush="Transparent" BorderThickness="0,0,0,2" Padding="14,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#ECEDEF"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="Background" Value="#101318"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="#5AD1FF"/>
                <Setter Property="Foreground" Value="#ECEDEF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="12"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb"><Border Background="#2A2E36" CornerRadius="5" Margin="2"/></ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="280"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <Border Grid.Column="0" Background="#0A0B0D" BorderBrush="#1A1D22" BorderThickness="0,0,1,0">
      <DockPanel Margin="16,24,16,20" LastChildFill="True">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="8,0,0,22">
          <Border Width="36" Height="36" CornerRadius="10" Background="#5AD1FF">
            <TextBlock Text="BJ" Foreground="#04141C" FontFamily="Consolas" FontWeight="SemiBold" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="BJMPC Toolbox" FontWeight="SemiBold" FontSize="15"/>
            <TextBlock Text="Informatique" Foreground="#8A909B" FontSize="12"/>
          </StackPanel>
        </StackPanel>
        <Border DockPanel.Dock="Bottom" BorderBrush="#1D2026" BorderThickness="1" CornerRadius="12" Padding="14,12">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Ellipse Width="8" Height="8" Fill="#62D98B" Margin="0,0,8,0"/>
              <TextBlock Text="Session administrateur" FontWeight="Medium" FontSize="13"/>
            </StackPanel>
            <TextBlock x:Name="PcText" Foreground="#8A909B" FontFamily="Consolas" FontSize="12" Margin="0,4,0,0"/>
          </StackPanel>
        </Border>
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="NavPanel"/>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="230" MinHeight="90"/>
      </Grid.RowDefinitions>

      <Border Grid.Row="0" Background="#0A0B0D" BorderBrush="#1A1D22" BorderThickness="0,0,0,1" Padding="20,10">
        <DockPanel LastChildFill="True">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <Border x:Name="RebootChip" Visibility="Collapsed" Background="#2A2210" CornerRadius="8" Padding="12,4" Margin="0,0,10,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Redémarrage conseillé" Foreground="#F5B94A" VerticalAlignment="Center" FontSize="13"/>
                <Button x:Name="BtnReboot" Content="Redémarrer" Style="{StaticResource Btn}" MinHeight="30" Padding="12,0" Margin="12,0,0,0" FontSize="13"/>
              </StackPanel>
            </Border>
            <Button x:Name="BtnCancel" Content="Interrompre" Style="{StaticResource Btn}" MinHeight="32" Padding="14,0" Visibility="Collapsed" FontSize="13"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="StatusText" Text="Prêt" Foreground="#C5C9D0" VerticalAlignment="Center"/>
            <ProgressBar x:Name="Prog" Width="170" Height="4" Margin="14,0,0,0" IsIndeterminate="False" Visibility="Collapsed" Background="#1D2026" Foreground="#5AD1FF" BorderThickness="0"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid Grid.Row="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" BorderBrush="#1A1D22" BorderThickness="0,0,0,1" Padding="22,0">
          <Grid x:Name="TabHost"/>
        </Border>
        <Grid x:Name="PageHost" Grid.Row="1"/>
      </Grid>

      <GridSplitter Grid.Row="2" Height="6" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="#0A0B0D" ResizeDirection="Rows"/>

      <Border Grid.Row="3" Background="#0A0B0D" BorderBrush="#1A1D22" BorderThickness="0,1,0,0" Padding="16,10,16,14">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="BtnCopy" Content="Copier" Style="{StaticResource Btn}" MinHeight="28" Padding="12,0" FontSize="12"/>
              <Button x:Name="BtnSave" Content="Enregistrer" Style="{StaticResource Btn}" MinHeight="28" Padding="12,0" Margin="8,0,0,0" FontSize="12"/>
              <Button x:Name="BtnClear" Content="Effacer" Style="{StaticResource Btn}" MinHeight="28" Padding="12,0" Margin="8,0,0,0" FontSize="12"/>
              <Button x:Name="BtnLogs" Content="Dossier des journaux" Style="{StaticResource Btn}" MinHeight="28" Padding="12,0" Margin="8,0,0,0" FontSize="12"/>
            </StackPanel>
            <TextBlock Text="Sortie en direct" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </DockPanel>
          <RichTextBox x:Name="Console" Grid.Row="1" IsReadOnly="True" Background="#000000" Foreground="#C5C9D0" BorderBrush="#1A1D22" BorderThickness="1"
                       FontFamily="Consolas" FontSize="12.5" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="8"/>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

try {
    $xml = New-Object System.Xml.XmlDocument
    $xml.LoadXml($Script:Xaml)
    $Script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
} catch {
    Show-Fatal "Création de la fenêtre impossible : $($_.Exception.Message)"
    exit 1
}
$Script:NavPanel   = $Script:Window.FindName('NavPanel')
$Script:PageHost   = $Script:Window.FindName('PageHost')
$Script:TabHost    = $Script:Window.FindName('TabHost')
$Script:Console    = $Script:Window.FindName('Console')
$Script:StatusText = $Script:Window.FindName('StatusText')
$Script:Prog       = $Script:Window.FindName('Prog')
$Script:BtnCancel  = $Script:Window.FindName('BtnCancel')
$Script:RebootChip = $Script:Window.FindName('RebootChip')
$Script:Window.FindName('PcText').Text = "$env:COMPUTERNAME · Windows 11"
$Script:Window.Title = "BJMPC Toolbox $Script:AppVersion"

$Script:ActionButtons = New-Object System.Collections.ArrayList
$Script:Pages = @{}
$Script:NavItems = @{}

# ---------------------------------------------------------------- Fabrique d'éléments
function Br { param([string]$Hex) return ([Windows.Media.BrushConverter]::new()).ConvertFromString($Hex) }

function New-Text {
    param([string]$Text, [double]$Size = 14, [string]$Color = '#ECEDEF', [string]$Weight = 'Normal', [switch]$Wrap, [string]$Font = '')
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = (Br $Color)
    $t.FontWeight = [Windows.FontWeights]::$Weight
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    if ($Font) { $t.FontFamily = New-Object Windows.Media.FontFamily $Font }
    return $t
}

function New-Tag {
    param([string]$Text, [string]$Kind = 'n')
    $bg = 'Transparent'; $fg = '#B4B9C2'; $bd = '#2A2E36'
    switch ($Kind) {
        'w' { $bg = '#2A2210'; $fg = '#F5B94A'; $bd = '#2A2210' }
        'a' { $bg = '#102632'; $fg = '#5AD1FF'; $bd = '#102632' }
        'g' { $bg = '#10281A'; $fg = '#62D98B'; $bd = '#10281A' }
        'r' { $bg = '#2E1416'; $fg = '#FF7B7B'; $bd = '#2E1416' }
    }
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 6
    $b.Padding = '8,2'
    $b.Margin = '8,0,0,0'
    $b.Background = (Br $bg)
    $b.BorderBrush = (Br $bd)
    $b.BorderThickness = 1
    $b.VerticalAlignment = 'Center'
    $b.Child = (New-Text $Text 12 $fg)
    return $b
}

function New-Btn {
    param([string]$Text, [hashtable]$Spec, [switch]$Primary)
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text
    $b.Style = $Script:Window.FindResource($(if ($Primary) { 'BtnPrimary' } else { 'Btn' }))
    $b.Tag = $Spec
    $b.Margin = '8,4,0,4'
    $b.Add_Click($Script:OnActionClick)
    [void]$Script:ActionButtons.Add($b)
    return $b
}

function New-Card {
    param([string]$Title, [string]$Sub = '', [string]$TagText = '', [string]$TagKind = 'n', [string]$Margin = '0,0,0,20')
    $card = New-Object Windows.Controls.Border
    $card.Background = (Br '#0E1013')
    $card.BorderBrush = (Br '#1D2026')
    $card.BorderThickness = 1
    $card.CornerRadius = 14
    $card.Padding = 22
    $card.Margin = $Margin
    $stack = New-Object Windows.Controls.StackPanel
    $card.Child = $stack
    $head = New-Object Windows.Controls.StackPanel
    $head.Orientation = 'Horizontal'
    [void]$head.Children.Add((New-Text $Title 16 '#ECEDEF' 'SemiBold'))
    if ($TagText) { [void]$head.Children.Add((New-Tag $TagText $TagKind)) }
    [void]$stack.Children.Add($head)
    if ($Sub) {
        $s = New-Text $Sub 13 '#9298A3' 'Normal' -Wrap
        $s.Margin = '0,4,0,0'
        [void]$stack.Children.Add($s)
    }
    return @{ Card = $card; Body = $stack }
}

function Add-Row {
    # Une ligne : titre + description à gauche, boutons à droite.
    param($Body, [string]$Title, [string]$Desc, [string]$TagText = '', [string]$TagKind = 'n', $Buttons = @())
    $row = New-Object Windows.Controls.Border
    $row.BorderBrush = (Br '#1A1D22')
    $row.BorderThickness = '0,1,0,0'
    $row.Margin = '0,12,0,0'
    $row.Padding = '0,12,0,0'
    $g = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(1, 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::Auto
    [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    $left = New-Object Windows.Controls.StackPanel
    $left.Margin = '0,0,16,0'
    $left.VerticalAlignment = 'Center'
    $line = New-Object Windows.Controls.StackPanel
    $line.Orientation = 'Horizontal'
    [void]$line.Children.Add((New-Text $Title 14 '#ECEDEF' 'Medium'))
    if ($TagText) { [void]$line.Children.Add((New-Tag $TagText $TagKind)) }
    [void]$left.Children.Add($line)
    if ($Desc) { [void]$left.Children.Add((New-Text $Desc 13 '#9298A3' 'Normal' -Wrap)) }
    [Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$g.Children.Add($left)
    $right = New-Object Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'
    $right.VerticalAlignment = 'Center'
    foreach ($b in @($Buttons)) { [void]$right.Children.Add($b) }
    [Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$g.Children.Add($right)
    $row.Child = $g
    [void]$Body.Children.Add($row)
}

function New-Check {
    param([string]$Text, [bool]$Checked = $false)
    $c = New-Object Windows.Controls.CheckBox
    $c.Content = $Text
    $c.IsChecked = $Checked
    $c.Foreground = (Br '#C5C9D0')
    $c.Margin = '0,6,0,0'
    $c.FontSize = 13
    return $c
}

function New-Page {
    param([string]$Key, [string]$Title, [string]$Sub)
    $sv = New-Object Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.Visibility = 'Collapsed'
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '36,30,36,40'
    $sp.MaxWidth = 1120
    $sp.HorizontalAlignment = 'Stretch'
    $sv.Content = $sp
    $h = New-Text $Title 28 '#ECEDEF' 'SemiBold'
    [void]$sp.Children.Add($h)
    $s = New-Text $Sub 14 '#9298A3' 'Normal' -Wrap
    $s.Margin = '0,4,0,24'
    [void]$sp.Children.Add($s)
    [void]$Script:PageHost.Children.Add($sv)
    $Script:Pages[$Key] = $sv
    return $sp
}

# Navigation : le menu de gauche liste les sections ; chaque section a une rangée d'onglets, un onglet = une page.
$Script:Sections = @{}        # clé de section -> @{ Item; Strip; Tabs (clé de page -> onglet); First }
$Script:PageSection = @{}     # clé de page -> clé de section
$Script:CurrentSection = ''

function Add-Section {
    # $Tabs = @(@('clé de page', 'libellé de l''onglet'), …)
    param([string]$Key, [string]$Label, [string]$Glyph, $Tabs)
    $rb = New-Object Windows.Controls.RadioButton
    $rb.GroupName = 'nav'
    $rb.Style = $Script:Window.FindResource('Nav')
    $rb.Tag = $Key
    $rb.Height = 48
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $ic = New-Object Windows.Controls.TextBlock
    $ic.Text = $Glyph
    $ic.FontFamily = New-Object Windows.Media.FontFamily 'Segoe MDL2 Assets'
    $ic.FontSize = 17
    $ic.Width = 28
    $ic.VerticalAlignment = 'Center'
    $tx = New-Object Windows.Controls.TextBlock
    $tx.Text = $Label
    $tx.FontSize = 14.5
    $tx.VerticalAlignment = 'Center'
    [void]$sp.Children.Add($ic); [void]$sp.Children.Add($tx)
    $rb.Content = $sp
    $rb.Add_Checked({ param($s, $e) Show-Section ([string]$s.Tag) })
    [void]$Script:NavPanel.Children.Add($rb)

    $strip = New-Object Windows.Controls.StackPanel
    $strip.Orientation = 'Horizontal'; $strip.Visibility = 'Collapsed'
    $map = @{}; $first = ''
    foreach ($t in $Tabs) {
        $pk = [string]$t[0]
        $tb = New-Object Windows.Controls.RadioButton
        $tb.GroupName = 'tab_' + $Key
        $tb.Style = $Script:Window.FindResource('Tab')
        $tb.Content = [string]$t[1]
        $tb.Tag = $pk
        $tb.Add_Checked({ param($s, $e) $k = [string]$s.Tag; if ([string]$Script:PageSection[$k] -eq $Script:CurrentSection) { Show-Page $k } })
        [void]$strip.Children.Add($tb)
        $map[$pk] = $tb
        $Script:PageSection[$pk] = $Key
        $Script:NavItems[$pk] = $tb
        if (-not $first) { $first = $pk }
    }
    [void]$Script:TabHost.Children.Add($strip)
    $Script:Sections[$Key] = @{ Item = $rb; Strip = $strip; Tabs = $map; First = $first }
}

function Show-Section {
    param([string]$Key)
    $sec = $Script:Sections[$Key]
    if (-not $sec) { return }
    $Script:CurrentSection = $Key
    foreach ($k in @($Script:Sections.Keys)) { $Script:Sections[$k].Strip.Visibility = $(if ($k -eq $Key) { 'Visible' } else { 'Collapsed' }) }
    $sel = @($sec.Tabs.Values | Where-Object { $_.IsChecked }) | Select-Object -First 1
    if ($sel) { Show-Page ([string]$sel.Tag) } else { $sec.Tabs[$sec.First].IsChecked = $true }
}

function Open-Page {
    # Ouvre une page depuis n'importe où (bouton, démarrage) : sélectionne son onglet et sa section.
    param([string]$Key)
    $sk = [string]$Script:PageSection[$Key]
    if (-not $sk) { return }
    $sec = $Script:Sections[$sk]
    if ($Script:CurrentSection -eq $sk) {
        if ($sec.Tabs[$Key].IsChecked) { Show-Page $Key } else { $sec.Tabs[$Key].IsChecked = $true }
    } else {
        $sec.Tabs[$Key].IsChecked = $true
        $sec.Item.IsChecked = $true
    }
}

function Show-Page {
    param([string]$Key)
    foreach ($k in @($Script:Pages.Keys)) { $Script:Pages[$k].Visibility = $(if ($k -eq $Key) { 'Visible' } else { 'Collapsed' }) }
    $Script:CurrentPage = $Key
    if ($Key -eq 'journal') { Load-Journal; Load-RestorePoints }
    elseif ($Key -eq 'files') { Refresh-BackupStatus }
    elseif ($Key -eq 'events') { if (-not $Script:Evt.Analyzed -and -not $Script:Run -and -not $Script:EngineError) { Start-EventAnalysis } }
}

# ---------------------------------------------------------------- Console
$Script:ColorMap = @{
    'Green' = '#62D98B'; 'DarkGreen' = '#62D98B'; 'Yellow' = '#F5B94A'; 'DarkYellow' = '#F5B94A'
    'Red' = '#FF7B7B'; 'DarkRed' = '#FF7B7B'; 'Cyan' = '#5AD1FF'; 'DarkCyan' = '#5AD1FF'
    'DarkGray' = '#7A808B'; 'Gray' = '#9298A3'; 'Magenta' = '#C792EA'; 'DarkMagenta' = '#C792EA'
    'White' = '#ECEDEF'; 'Blue' = '#6EA8FF'; 'DarkBlue' = '#6EA8FF'
}
$Script:RecentLines = New-Object System.Collections.ArrayList
$Script:LastProgress = $null

function Add-Console {
    param([string]$Text, [string]$Color = '')
    $clean = ($Text -replace "`r", '' -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    $hex = '#C5C9D0'
    if ($Color -and $Script:ColorMap.ContainsKey($Color)) { $hex = $Script:ColorMap[$Color] }
    $doc = $Script:Console.Document
    $isProgress = ($clean -match '^\s*\[[= ]*[\d.,]+%[= ]*\]\s*$' -or $clean -match '^\s*\d{1,3}(?:[.,]\d+)?\s*%\s*$')
    if ($isProgress -and $Script:LastProgress -and $doc.Blocks.Contains($Script:LastProgress)) {
        [void]$doc.Blocks.Remove($Script:LastProgress)
    }
    $p = New-Object Windows.Documents.Paragraph
    $p.Margin = '0'
    $r = New-Object Windows.Documents.Run $clean
    $r.Foreground = (Br $hex)
    [void]$p.Inlines.Add($r)
    [void]$doc.Blocks.Add($p)
    $Script:LastProgress = $(if ($isProgress) { $p } else { $null })
    while ($doc.Blocks.Count -gt 2500) { [void]$doc.Blocks.Remove($doc.Blocks.FirstBlock) }
    $Script:Console.ScrollToEnd()
    if ($clean.Trim()) {
        [void]$Script:RecentLines.Add($clean)
        if ($Script:RecentLines.Count -gt 16) { $Script:RecentLines.RemoveAt(0) }
    }
}

# ---------------------------------------------------------------- Boîtes de dialogue
function Show-PromptDialog {
    param([string]$Kind, [string]$Text, [string]$Context)
    $w = New-Object Windows.Window
    $w.Title = 'BJMPC Toolbox'
    $w.Owner = $Script:Window
    $w.Width = 580
    $w.SizeToContent = 'Height'
    $w.WindowStartupLocation = 'CenterOwner'
    $w.ResizeMode = 'NoResize'
    $w.ShowInTaskbar = $false
    $w.Background = (Br '#0E1013')
    $w.Foreground = (Br '#ECEDEF')
    $w.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI'
    $w.Tag = ''
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = 22
    # Menu numéroté (1) ... 2) ...) : un bouton par option, aucune saisie.
    $opts = @()
    if ($Kind -eq 'text' -and $Context) {
        foreach ($l in ($Context -split "`n")) {
            if ($l -match '^\s*(\d+)\)\s+(.+)$') { $opts += ,@($Matches[1], $Matches[2].Trim()) }
            elseif ($l -match '^\s*\[(\d+)\]\s+(.+)$') { $opts += ,@($Matches[1], $Matches[2].Trim()) }
        }
    }
    $useButtons = ($opts.Count -ge 2)
    if ($Context -and -not $useButtons) {
        $ctx = New-Text $Context 12 '#9298A3' 'Normal' -Wrap -Font 'Consolas'
        $sv = New-Object Windows.Controls.ScrollViewer
        $sv.MaxHeight = 230
        $sv.VerticalScrollBarVisibility = 'Auto'
        $sv.Content = $ctx
        $bd = New-Object Windows.Controls.Border
        $bd.Background = (Br '#000000'); $bd.BorderBrush = (Br '#1A1D22'); $bd.BorderThickness = 1; $bd.CornerRadius = 8; $bd.Padding = 10; $bd.Margin = '0,0,0,14'
        $bd.Child = $sv
        [void]$sp.Children.Add($bd)
    }
    $q = New-Text $Text 15 '#ECEDEF' 'Medium' -Wrap
    $q.Margin = '0,0,0,12'
    [void]$sp.Children.Add($q)
    $tb = $null
    if ($useButtons) {
        $optClick = { param($s, $e) $s.Tag.Win.Tag = [string]$s.Tag.Val; $s.Tag.Win.Close() }
        foreach ($o in $opts) {
            $ob = New-Object Windows.Controls.Button
            $ob.Content = ("{0}) {1}" -f $o[0], $o[1])
            $ob.Style = $Script:Window.FindResource('Btn')
            $ob.Margin = '0,0,0,8'
            $ob.HorizontalContentAlignment = 'Left'
            $ob.Tag = @{ Win = $w; Val = $o[0] }
            $ob.Add_Click($optClick)
            [void]$sp.Children.Add($ob)
        }
    } elseif ($Kind -eq 'text' -or $Kind -eq 'strong') {
        $tb = New-Object Windows.Controls.TextBox
        $tb.Background = (Br '#14181E'); $tb.Foreground = (Br '#ECEDEF'); $tb.CaretBrush = (Br '#ECEDEF')
        $tb.BorderBrush = (Br '#2A2E36'); $tb.Padding = '10,8'; $tb.FontSize = 14; $tb.Margin = '0,0,0,14'
        if ($Kind -eq 'strong') {
            $hint = New-Text 'Action sensible : tapez OUI en majuscules pour confirmer.' 12 '#F5B94A' 'Normal' -Wrap
            $hint.Margin = '0,0,0,8'
            [void]$sp.Children.Add($hint)
        }
        [void]$sp.Children.Add($tb)
    }
    $bar = New-Object Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'
    $bar.HorizontalAlignment = 'Right'
    $okText = 'OK'; $noText = 'Annuler'; $okVal = 'ok'; $noVal = 'cancel'
    if ($Kind -eq 'yesno') { $okText = 'Oui'; $noText = 'Non'; $okVal = 'yes'; $noVal = 'no' }
    if ($Kind -eq 'strong') { $okText = 'Confirmer' }
    $bNo = New-Object Windows.Controls.Button
    $bNo.Content = $noText; $bNo.Style = $Script:Window.FindResource('Btn'); $bNo.IsCancel = $true
    $bNo.Tag = @{ Win = $w; Val = $noVal; Box = $null }
    $bOk = New-Object Windows.Controls.Button
    $bOk.Content = $okText; $bOk.Style = $Script:Window.FindResource('BtnPrimary'); $bOk.IsDefault = $true; $bOk.Margin = '10,0,0,0'
    $bOk.Tag = @{ Win = $w; Val = $okVal; Box = $tb }
    $dlgClick = {
        param($s, $e)
        $t = $s.Tag
        if ($t.Box) { $t.Win.Tag = [string]$t.Box.Text } else { $t.Win.Tag = [string]$t.Val }
        $t.Win.Close()
    }
    $bNo.Add_Click({ param($s, $e) $s.Tag.Win.Tag = [string]$s.Tag.Val; if ($s.Tag.Val -eq 'cancel') { $s.Tag.Win.Tag = '' }; $s.Tag.Win.Close() })
    $bOk.Add_Click($dlgClick)
    if ($useButtons) { $bOk.Visibility = 'Collapsed' }
    [void]$bar.Children.Add($bNo); [void]$bar.Children.Add($bOk)
    [void]$sp.Children.Add($bar)
    $w.Content = $sp
    if ($tb) { $w.Add_ContentRendered({ param($s, $e) $s.Content.Children | Where-Object { $_ -is [Windows.Controls.TextBox] } | ForEach-Object { [void]$_.Focus() } }) }
    [void]$w.ShowDialog()
    return [string]$w.Tag
}

function Resolve-Prompt {
    $p = $Script:Sync.Prompt
    $ctx = ($Script:RecentLines | Select-Object -Last 12) -join "`n"
    $Script:RecentLines.Clear()
    $ans = ''
    try { $ans = Show-PromptDialog $p.Kind ([string]$p.Text) $ctx } catch { $ans = '' }
    $Script:Sync.PromptAnswer = $ans
    [void]$Script:Sync.PromptEvent.Set()
}

#endregion

# ================================================================ EXÉCUTION DES ACTIONS
#region Actions

function Set-Busy {
    param([bool]$Busy, [string]$Title = '')
    foreach ($b in $Script:ActionButtons) { $b.IsEnabled = (-not $Busy) }
    if ($Busy) {
        $Script:StatusText.Text = $(if ($Title) { "En cours : $Title" } else { 'Analyse en cours…' })
        $Script:Prog.Visibility = 'Visible'
        $Script:Prog.IsIndeterminate = $true
        $Script:BtnCancel.Visibility = $(if ($Title) { 'Visible' } else { 'Collapsed' })
    } else {
        $Script:StatusText.Text = 'Prêt'
        $Script:Prog.IsIndeterminate = $false
        $Script:Prog.Visibility = 'Collapsed'
        $Script:BtnCancel.Visibility = 'Collapsed'
    }
}

function Update-RebootChip {
    $Script:RebootChip.Visibility = $(if ($Script:Sync.Reboot) { 'Visible' } else { 'Collapsed' })
}

function Invoke-Spec {
    param($Spec)
    if ($Script:Run) { return }
    if ($Spec.Fn) { & $Spec.Fn $Spec; return }
    $auto = @{}
    if ($Spec.AutoFn) { $auto = & $Spec.AutoFn } elseif ($Spec.Auto) { $auto = $Spec.Auto }
    $code = [string]$Spec.Code
    if ($Spec.CodeFn) {
        $code = [string](& $Spec.CodeFn)
        if (-not $code.Trim()) { Add-Console "Rien n'est coché." 'Yellow'; return }
    }
    $conf = [string]$Spec.Confirm
    if ($Spec.ConfirmFn) { $conf = [string](& $Spec.ConfirmFn) }
    if ($conf) {
        $r = [Windows.MessageBox]::Show($Script:Window, $conf, 'BJMPC Toolbox', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
    }
    $engine = if ($Spec.Engine) { [string]$Spec.Engine } else { 'none' }
    $Script:RecentLines.Clear()
    Add-Console ''
    Add-Console ("▶ " + $Spec.Title) 'Cyan'
    Start-Run -Engine $engine -Code $code -Title ([string]$Spec.Title) -Auto $auto -AutoDefault ([string]$Spec.AutoDefault) -OnDone $Spec.OnDone
}

$Script:OnActionClick = {
    param($s, $e)
    try { Invoke-Spec $s.Tag }
    catch { Write-Crash $_.Exception.ToString(); Add-Console ("  [X]   Erreur : " + $_.Exception.Message) 'Red' }
}

function Complete-Run {
    $r = $Script:Run
    try { [void]$r.PS.EndInvoke($r.Handle) } catch {}
    try {
        foreach ($er in @($r.PS.Streams.Error | Select-Object -First 8)) {
            Add-Console ("  [!]   " + $er.ToString().Trim()) 'DarkGray'
        }
    } catch {}
    $res = $Script:Sync.Result
    $errCount = 0
    try { $errCount = @($r.PS.Streams.Error).Count } catch {}
    try { $r.PS.Dispose(); $r.RS.Close(); $r.RS.Dispose() } catch {}
    $Script:Run = $null
    Set-Busy $false
    Update-RebootChip
    $secs = [int]((Get-Date) - $r.Started).TotalSeconds
    if ($r.Title) { Add-Console ("✔ Terminé : {0} ({1} s)" -f $r.Title, $secs) 'Green' }
    $Script:RunFlags.Warn += $errCount
    try { Add-SessionEntry $r $res } catch { Write-Crash ("Session : " + $_.Exception.Message) }
    if ($r.OnDone) { try { & $r.OnDone $res } catch { Add-Console ("  [X]   " + $_.Exception.Message) 'Red' } }
    # La page Sauvegardes a demandé son état pendant qu'une autre opération tournait : on le lit maintenant.
    if ($Script:BakPending -and -not $Script:Run -and $Script:CurrentPage -eq 'files') { try { Refresh-BackupStatus } catch {} }
}

function Update-Ui {
    $item = $null
    $n = 0
    while ($n -lt 300 -and $Script:Sync.Queue.TryDequeue([ref]$item)) {
        $n++
        if ($item.K -eq 'log') {
            Add-Console ([string]$item.T) ([string]$item.C)
            if ([string]$item.T -match '^\s*\[X\]') { $Script:RunFlags.Fail++ } elseif ([string]$item.T -match '^\s*\[!\]') { $Script:RunFlags.Warn++ }
        }
        elseif ($item.K -eq 'prompt') { $Script:Timer.Stop(); try { Resolve-Prompt } finally { $Script:Timer.Start() } }
    }
    if ($Script:Run -and $Script:Run.Handle.IsCompleted -and $Script:Sync.Queue.IsEmpty) { Complete-Run }
    # Surveillance en direct : nouveaux constats envoyés par le fil de surveillance
    $ev = $null; $m = 0
    while ($m -lt 40 -and $Script:Sync.EvtQueue.TryDequeue([ref]$ev)) { $m++; try { Add-LiveEvent $ev } catch { Write-Crash ("Surveillance : " + $_.Exception.ToString()) } }
    if ($Script:Evt.AutoPending.Count -gt 0 -and -not $Script:Run) { Start-EventAutoFix }
    if ($Script:EvtWatch -and $Script:EvtWatch.Handle.IsCompleted) { Stop-EventWatch; Add-Console '  [!]   La surveillance en direct s''est arrêtée. Relancez-la depuis Réparer > Réparation automatique.' 'Yellow' }
}

#endregion

# ================================================================ PAGES
#region Pages

function New-Spec {
    # Auto : réponses préparées aux questions du script (motif de la question => 'yes' / 'no' / valeur).
    param([string]$Engine, [string]$Code, [string]$Title, [hashtable]$Auto = @{}, [string]$Confirm = '', [scriptblock]$OnDone = $null)
    $h = @{ Engine = $Engine; Code = $Code; Title = $Title; Auto = $Auto; Confirm = $Confirm }
    if ($OnDone) { $h.OnDone = $OnDone }
    return $h
}

$Script:AfterChange = { param($r) Refresh-Dashboard }

# ---------------------------------------------------------------- Tableau de bord
$Script:DashCode = @'
function Get-RegVal { param($p, $n) try { (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n } catch { $null } }
$i = [ordered]@{}
try { $os = Get-CimInstance Win32_OperatingSystem; $i.Os = @($os.Caption, ("Build " + $os.BuildNumber)) } catch { $i.Os = @('Inconnu', '') }
try { $c = Get-CimInstance Win32_Processor | Select-Object -First 1; $i.Cpu = @((($c.Name -replace '\s+', ' ').Trim()), ("{0} coeurs / {1} threads" -f $c.NumberOfCores, $c.NumberOfLogicalProcessors)) } catch { $i.Cpu = @('Inconnu', '') }
try {
    $cs = Get-CimInstance Win32_ComputerSystem; $m = @(Get-CimInstance Win32_PhysicalMemory)
    $i.Ram = @(("{0} Go" -f [math]::Round($cs.TotalPhysicalMemory / 1GB)), ("{0} barrette(s) · {1} MT/s" -f $m.Count, ($m | Select-Object -First 1).ConfiguredClockSpeed))
} catch { $i.Ram = @('Inconnu', '') }
try {
    $g = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual|Meta' } | Select-Object -First 1
    $i.Gpu = @($g.Name, ("{0} x {1} · {2} Hz" -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution, $g.CurrentRefreshRate))
} catch { $i.Gpu = @('Inconnu', '') }
try {
    $d = @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object DeviceId); $f = $d | Select-Object -First 1
    $extra = if ($d.Count -gt 1) { " (+{0})" -f ($d.Count - 1) } else { '' }
    $i.Disk = @(($f.FriendlyName + $extra), ("{0} · {1:N0} Go · {2}" -f $f.BusType, ($f.Size / 1GB), $f.HealthStatus))
} catch { $i.Disk = @('Inconnu', '') }
try {
    $a = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    $i.Net = @($a.InterfaceDescription, ("{0} · {1}" -f $a.Name, $a.LinkSpeed))
} catch { $i.Net = @('Aucune carte active', '') }
$hv = Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
$i.Hags = @($(if ($hv -eq 2) { 'activée' } elseif ($hv -eq 1) { 'désactivée' } else { 'non définie (désactivée par défaut)' }), [string]$hv)

$list = New-Object System.Collections.ArrayList
function Chk { param($l, $g, $d) [void]$list.Add([pscustomobject]@{ Label = $l; Good = [bool]$g; Detail = $d }) }
# --- Vos fichiers et votre filet de sécurité
$bak = $null
try { $bak = Get-Content -LiteralPath (Join-Path $env:SystemDrive 'BJMPC-Logs\Sauvegarde\etat.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch {}
$bakDays = $null
if ($bak -and $bak.LastSuccess) { try { $bakDays = [int][math]::Floor(((Get-Date) - [datetime]$bak.LastSuccess).TotalDays) } catch {} }
$bakHint = if ($null -eq $bakDays) { 'Aucune sauvegarde : section Sauvegarde et restauration' } else { "Dernière il y a $bakDays jour(s) : section Sauvegarde et restauration" }
Chk 'Fichiers personnels sauvegardés depuis moins de 8 jours' ($null -ne $bakDays -and $bakDays -le 7) $bakHint
$auto = $false
try { $tk = Get-ScheduledTask -TaskName 'BJMPC Sauvegarde automatique' -TaskPath '\BJMPC\' -ErrorAction Stop; $auto = ([string]$tk.State -ne 'Disabled') } catch {}
Chk 'Sauvegarde automatique programmée' $auto 'À activer : section Sauvegarde et restauration'
$rpDays = $null
try {
    $rp = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending | Select-Object -First 1
    if ($rp) { $rpDays = [int][math]::Floor(((Get-Date) - [Management.ManagementDateTimeConverter]::ToDateTime($rp.CreationTime)).TotalDays) }
} catch {}
Chk 'Point de restauration de moins de 30 jours' ($null -ne $rpDays -and $rpDays -le 30) 'À créer : Sauvegarde et restauration > Restauration'
# --- Santé du PC
$pct = -1
try { $ld = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop; if ($ld.Size) { $pct = [int](100 * $ld.FreeSpace / $ld.Size) } } catch {}
Chk 'Assez de place libre sur le disque de Windows' ($pct -ge 15) ("{0} % libres : Réparer > Nettoyage et dépannage" -f $pct)
$sick = @()
try { $sick = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.HealthStatus -ne 'Healthy' }) } catch {}
Chk 'Disques en bonne santé' ($sick.Count -eq 0) 'À contrôler : Réparer > Diagnostics'
$pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
Chk 'Aucun redémarrage en attente' (-not $pend) 'Redémarrez le PC pour finir une mise à jour'
$crit = 0
try { $crit = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 20 -ErrorAction Stop).Count } catch {}
Chk 'Aucun plantage ni arrêt brutal depuis 7 jours' ($crit -eq 0) ("{0} événement(s) critique(s) : Réparer > Réparation automatique" -f $crit)
# --- Réglages recommandés
$o = & fsutil.exe behavior query DisableDeleteNotify 2>$null | Out-String
Chk 'TRIM actif sur le SSD' ($o -match 'NTFS DisableDeleteNotify\s*=\s*0') 'Optimiser > Disque et démarrage'
Chk 'Capture de jeu en arrière-plan coupée' ((Get-RegVal 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0) 'Bouton « Réglages recommandés »'
$dt = Get-Service -Name DiagTrack -ErrorAction SilentlyContinue
Chk 'Télémétrie réduite au minimum' ($dt -and $dt.StartType -eq 'Disabled') 'Bouton « Réglages recommandés »'
# --- Anciens réglages des versions 1.x, sans effet mesurable sur Windows 11 : à remettre par défaut
$old = @()
if ((Get-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex') -eq -1) { $old += 'MMCSS' }
$sm = Get-Service -Name SysMain -ErrorAction SilentlyContinue
if ($sm -and $sm.StartType -eq 'Disabled') { $old += 'SysMain' }
foreach ($ad in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
    if ((Get-RegVal "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($ad.InterfaceGuid)" 'TCPNoDelay') -eq 1) { $old += 'Nagle'; break }
}
if ($old.Count -gt 0) { Chk 'Aucun ancien réglage dépassé' $false (($old -join ', ') + ' : Sauvegarde et restauration > Restauration > Comparer avec Windows 11') }
$Sync.Result = @{ Info = $i; Checks = @($list) }
'@

$Script:Tiles = @{}
$Script:SegPanel = $null
$Script:ScoreText = $null
$Script:ScoreSub = $null
$Script:RecoPanel = $null

function Add-Tile {
    param($Parent, [string]$Key, [string]$Label, [string]$Margin)
    $b = New-Object Windows.Controls.Border
    $b.Background = (Br '#0E1013'); $b.BorderBrush = (Br '#1D2026'); $b.BorderThickness = 1; $b.CornerRadius = 14; $b.Padding = 18
    $b.Margin = $Margin
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $Label.ToUpper() 12 '#9298A3'))
    $v = New-Text '…' 16 '#ECEDEF' 'Medium' -Wrap
    $v.Margin = '0,6,0,0'
    $s = New-Text '' 13 '#9298A3' 'Normal' -Wrap
    [void]$sp.Children.Add($v); [void]$sp.Children.Add($s)
    $b.Child = $sp
    [void]$Parent.Children.Add($b)
    $Script:Tiles[$Key] = @{ V = $v; S = $s }
}

function Refresh-Dashboard {
    Start-Run -Engine 'none' -Code $Script:DashCode -Title '' -OnDone {
        param($res)
        if (-not $res) { return }
        if ($Script:HagsText -and $res.Info.Contains('Hags')) {
            $on = ([string]$res.Info['Hags'][1] -eq '2')
            $Script:HagsText.Text = 'État actuel : ' + [string]$res.Info['Hags'][0]
            $Script:HagsText.Foreground = (Br $(if ($on) { '#62D98B' } else { '#F5B94A' }))
        }
        foreach ($k in @('Os', 'Cpu', 'Ram', 'Gpu', 'Disk', 'Net')) {
            $t = $Script:Tiles[$k.ToLower()]
            if ($t -and $res.Info.Contains($k)) { $t.V.Text = [string]$res.Info[$k][0]; $t.S.Text = [string]$res.Info[$k][1] }
        }
        $checks = @($res.Checks)
        $good = @($checks | Where-Object { $_.Good }).Count
        $Script:ScoreText.Text = "$good"
        $Script:ScoreSub.Text = if ($checks.Count - $good -eq 0) { "Tout est en ordre." } else { "{0} point(s) à regarder, détaillés ci-dessous." -f ($checks.Count - $good) }
        $Script:SegPanel.Children.Clear()
        $Script:SegPanel.Columns = [math]::Max(1, $checks.Count)
        foreach ($c in $checks) {
            $seg = New-Object Windows.Controls.Border
            $seg.Height = 8; $seg.CornerRadius = 4; $seg.Margin = '0,0,4,0'
            $seg.Background = (Br $(if ($c.Good) { '#5AD1FF' } else { '#1D2026' }))
            [void]$Script:SegPanel.Children.Add($seg)
        }
        $Script:ScoreTotal.Text = "/ $($checks.Count)"
        $Script:RecoPanel.Children.Clear()
        foreach ($c in $checks) {
            $row = New-Object Windows.Controls.StackPanel
            $row.Orientation = 'Horizontal'; $row.Margin = '0,6,0,0'
            $dot = New-Object Windows.Shapes.Ellipse
            $dot.Width = 8; $dot.Height = 8; $dot.Margin = '0,0,12,0'
            $dot.Fill = (Br $(if ($c.Good) { '#62D98B' } else { '#F5B94A' }))
            [void]$row.Children.Add($dot)
            [void]$row.Children.Add((New-Text $c.Label 14 $(if ($c.Good) { '#C5C9D0' } else { '#ECEDEF' })))
            $st = New-Text $(if ($c.Good) { 'OK' } else { [string]$c.Detail }) 13 $(if ($c.Good) { '#62D98B' } else { '#F5B94A' })
            $st.Margin = '12,0,0,0'
            [void]$row.Children.Add($st)
            [void]$Script:RecoPanel.Children.Add($row)
        }
    }
}

$Script:ScoreTotal = $null

function Build-Dashboard {
    $p = New-Page 'dash' 'Accueil' 'L''état de ce PC en un coup d''œil : ce qui est en ordre, ce qui reste à faire, et où le faire.'
    $grid = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(3, 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::new(2, 'Star')
    [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)

    $hero = New-Card 'Réglages recommandés' 'Seulement ce qui est sûr et utile sur tout PC Windows 11 : réglages de jeu de Windows (planification GPU, Mode Jeu, capture en arrière-plan coupée), contrôle du TRIM du SSD et télémétrie minimale. Un point de restauration est créé d''abord et chaque valeur d''origine est mémorisée. Le reste (alimentation, réseau, DNS, écran) dépend du PC : voir la section Optimiser.' 'Sans risque' 'g' '0,0,10,20'
    $act = New-Object Windows.Controls.WrapPanel
    $act.Margin = '0,18,0,0'
    $spec = New-Spec 'opt' 'Invoke-FullProfile' 'Réglages recommandés' @{} 'Appliquer les réglages recommandés ? Un point de restauration est créé avant.' $Script:AfterChange
    $b1 = New-Btn 'Appliquer les réglages recommandés' $spec -Primary; $b1.Margin = '0,4,0,4'
    [void]$act.Children.Add($b1)
    [void]$act.Children.Add((New-Btn 'Sauvegarder les fichiers' @{ Fn = { Open-Page 'files' } }))
    [void]$act.Children.Add((New-Btn 'Actualiser' @{ Fn = { Refresh-Dashboard } }))
    [void]$hero.Body.Children.Add($act)
    [Windows.Controls.Grid]::SetColumn($hero.Card, 0)
    [void]$grid.Children.Add($hero.Card)

    $score = New-Card 'Points en ordre' '' '' 'n' '10,0,0,20'
    $line = New-Object Windows.Controls.StackPanel
    $line.Orientation = 'Horizontal'; $line.Margin = '0,10,0,10'
    $Script:ScoreText = New-Text '–' 44 '#ECEDEF' 'SemiBold' -Font 'Consolas'
    $Script:ScoreTotal = New-Text '' 18 '#9298A3' 'Normal' -Font 'Consolas'
    $Script:ScoreTotal.VerticalAlignment = 'Bottom'; $Script:ScoreTotal.Margin = '8,0,0,8'
    [void]$line.Children.Add($Script:ScoreText); [void]$line.Children.Add($Script:ScoreTotal)
    [void]$score.Body.Children.Add($line)
    $Script:SegPanel = New-Object Windows.Controls.Primitives.UniformGrid
    $Script:SegPanel.Rows = 1; $Script:SegPanel.Columns = 10
    [void]$score.Body.Children.Add($Script:SegPanel)
    $Script:ScoreSub = New-Text 'Analyse en cours…' 13 '#9298A3' 'Normal' -Wrap
    $Script:ScoreSub.Margin = '0,10,0,0'
    [void]$score.Body.Children.Add($Script:ScoreSub)
    [Windows.Controls.Grid]::SetColumn($score.Card, 1)
    [void]$grid.Children.Add($score.Card)
    [void]$p.Children.Add($grid)

    $hw = New-Object Windows.Controls.Primitives.UniformGrid
    $hw.Columns = 3
    $hw.Margin = '0,0,0,10'
    Add-Tile $hw 'os' 'Windows' '0,0,10,10'
    Add-Tile $hw 'cpu' 'Processeur' '5,0,5,10'
    Add-Tile $hw 'ram' 'Mémoire' '10,0,0,10'
    Add-Tile $hw 'gpu' 'Carte graphique' '0,0,10,10'
    Add-Tile $hw 'disk' 'Stockage' '5,0,5,10'
    Add-Tile $hw 'net' 'Réseau' '10,0,0,10'
    [void]$p.Children.Add($hw)

    $reco = New-Card 'État de ce PC' 'Vert : en ordre. Orange : à regarder, avec l''endroit où agir.'
    $Script:RecoPanel = New-Object Windows.Controls.StackPanel
    $Script:RecoPanel.Margin = '0,10,0,0'
    [void]$reco.Body.Children.Add($Script:RecoPanel)
    [void]$p.Children.Add($reco.Card)

    $tools = New-Card 'En savoir plus sur ce PC' 'Le résultat s''affiche dans la zone « Sortie en direct » en bas de la fenêtre.'
    Add-Row $tools.Body 'État détaillé des réglages' 'Affiche chaque réglage et sa valeur actuelle.' '' 'n' @((New-Btn 'Afficher' (New-Spec 'opt' 'Show-State' 'État des optimisations')))
    Add-Row $tools.Body 'Profil matériel détecté' 'CPU, RAM, GPU, NVMe, Wi-Fi et écran, avec les points d''attention.' '' 'n' @((New-Btn 'Afficher' (New-Spec 'opt' 'Show-HardwareProfile' 'Profil matériel')))
    Add-Row $tools.Body 'Informations système et santé des disques' '' '' 'n' @((New-Btn 'Afficher' (New-Spec 'maint' 'Get-SystemSummary' 'Informations système')))
    [void]$p.Children.Add($tools.Card)
}

# ---------------------------------------------------------------- Outils et diagnostics
function Build-Tools {
    $p = New-Page 'tools' 'Diagnostics' 'Mesures, rapports et inventaires : rien n''est modifié ici. Les actions qui corrigent sont dans les deux onglets voisins.'
    function ToolSpec { param([string]$Code, [string]$Title, [string]$Confirm = '') return (New-Spec 'tools' $Code $Title @{} $Confirm) }

    $hw = New-Card 'Matériel' 'Santé des disques, erreurs système liées au matériel, rapports énergétiques.' 'Lecture seule' 'g'
    Add-Row $hw.Body 'Santé des disques (SMART)' 'État, température, usure du SSD, heures de fonctionnement, erreurs de lecture et d''écriture.' '' 'n' @((New-Btn 'Analyser' (ToolSpec 'Get-StorageHealth' 'Santé des disques') -Primary))
    Add-Row $hw.Body 'Erreurs matérielles récentes' 'Disque, mémoire (WHEA), alimentation (Kernel-Power) et pilote graphique, avec des pistes de diagnostic.' '' 'n' @(
        (New-Btn '7 jours' (ToolSpec 'Get-HardwareErrors -Days 7' 'Erreurs matérielles (7 jours)')),
        (New-Btn '30 jours' (ToolSpec 'Get-HardwareErrors -Days 30' 'Erreurs matérielles (30 jours)')))
    Add-Row $hw.Body 'Rapport d''efficacité énergétique' 'Analyse d''environ 20 secondes, rapport HTML ouvert automatiquement.' '' 'n' @((New-Btn 'Générer' (ToolSpec 'New-EnergyReport' 'Rapport énergétique')))
    Add-Row $hw.Body 'Rapport de batterie' 'Portables : capacité d''origine, capacité actuelle, cycles.' '' 'n' @((New-Btn 'Générer' (ToolSpec 'New-BatteryReport' 'Rapport de batterie')))
    [void]$p.Children.Add($hw.Card)

    $nt = New-Card 'Réseau' 'Latence, perte de paquets, résolution DNS et état du Wi-Fi.' 'Lecture seule' 'g'
    Add-Row $nt.Body 'Qualité de la connexion' 'Ping du routeur et de deux serveurs publics (8 essais chacun), temps de résolution DNS.' '' 'n' @((New-Btn 'Tester' (ToolSpec 'Test-NetworkQuality' 'Qualité de la connexion') -Primary))
    Add-Row $nt.Body 'Connexion Wi-Fi actuelle' 'Réseau, canal, débit, puissance du signal.' '' 'n' @((New-Btn 'Afficher' (ToolSpec 'Get-WifiInfo' 'Wi-Fi')))
    Add-Row $nt.Body 'Rapport Wi-Fi des 3 derniers jours' 'Coupures, déconnexions et durée des sessions, au format HTML.' '' 'n' @((New-Btn 'Générer' (ToolSpec 'New-WlanReport' 'Rapport Wi-Fi')))
    [void]$p.Children.Add($nt.Card)

    $sc = New-Card 'Sécurité et mises à jour' 'Contrôle de l''état de protection du PC, sans rien modifier.' 'Lecture seule' 'g'
    Add-Row $sc.Body 'Audit de sécurité' 'TPM, Secure Boot, BitLocker, Defender, pare-feu, UAC, SMBv1, Bureau à distance, redémarrage en attente, espace libre.' '' 'n' @((New-Btn 'Lancer l''audit' (ToolSpec 'Get-SecurityAudit' 'Audit de sécurité') -Primary))
    Add-Row $sc.Body 'Mises à jour Windows en attente' 'Liste des mises à jour disponibles (recherche d''environ une minute).' '' 'n' @((New-Btn 'Rechercher' (ToolSpec 'Get-PendingUpdates' 'Mises à jour Windows')))
    [void]$p.Children.Add($sc.Card)

    $sw = New-Card 'Système et licence' 'Programmes au démarrage, licence et informations système pour un dossier client.'
    Add-Row $sw.Body 'Programmes au démarrage' 'Liste dans la console ; la désactivation se fait dans les paramètres de Windows.' '' 'n' @(
        (New-Btn 'Lister' (ToolSpec 'Get-StartupItems' 'Programmes au démarrage')),
        (New-Btn 'Ouvrir les paramètres' @{ Fn = { try { Start-Process 'ms-settings:startupapps' } catch {} } }))
    Add-Row $sw.Body 'Licence Windows' 'Édition, état d''activation et clé OEM inscrite dans le BIOS.' '' 'n' @((New-Btn 'Afficher' (ToolSpec 'Get-LicenseInfo' 'Licence Windows')))
    Add-Row $sw.Body 'Informations système complètes' 'Exporte le résultat de systeminfo dans un fichier texte.' '' 'n' @((New-Btn 'Exporter' (ToolSpec 'Export-SystemInfo' 'Informations système (export)')))
    [void]$p.Children.Add($sw.Card)
}

# ---------------------------------------------------------------- Maintenance
function Build-Maintenance {
    $p = New-Page 'maint' 'Réparer Windows' 'Dans l''ordre recommandé : l''image Windows d''abord, puis les fichiers système, puis le disque.'
    $seq = New-Card 'Réparation guidée' '' '' 'n'
    $seqSpec = New-Spec 'maint' 'Invoke-FullSequence' 'Séquence complète' @{ 'RestoreHealth' = 'yes'; 'composants' = 'yes' } 'Lancer toute la séquence ? Elle peut durer 30 minutes et plus.'
    $seqSpec.AutoDefault = 'no'
    $seqBtn = New-Btn 'Lancer la séquence complète' $seqSpec -Primary
    $seqBtn.HorizontalAlignment = 'Left'; $seqBtn.Margin = '0,12,0,0'
    [void]$seq.Body.Children.Add($seqBtn)
    Add-Row $seq.Body '1. DISM : image Windows' 'CheckHealth et ScanHealth (lecture seule) ; la réparation RestoreHealth nécessite Internet.' '' 'n' @(
        (New-Btn 'Vérifier seulement' (New-Spec 'maint' 'Invoke-DISM' 'DISM (vérification)' @{ 'RestoreHealth' = 'no' })),
        (New-Btn 'Vérifier et réparer' (New-Spec 'maint' 'Invoke-DISM' 'DISM (vérification et réparation)' @{ 'RestoreHealth' = 'yes' })))
    Add-Row $seq.Body '2. SFC : fichiers système' '/scannow, de 10 à 30 minutes. Détails dans CBS.log.' '' 'n' @((New-Btn 'Lancer' (New-Spec 'maint' 'Invoke-SFC' 'SFC')))
    Add-Row $seq.Body '3. CHKDSK : disque' 'Analyse en ligne, ou réparation complète au prochain démarrage.' '' 'n' @(
        (New-Btn 'Analyse en ligne' (New-Spec 'maint' 'Invoke-Chkdsk' 'CHKDSK (analyse)' @{ '^\s*Choix' = '1' })),
        (New-Btn 'Réparer au redémarrage' (New-Spec 'maint' 'Invoke-Chkdsk' 'CHKDSK (planification)' @{ '^\s*Choix' = '2' } 'Planifier une réparation complète du disque système au prochain redémarrage ?')),
        (New-Btn 'Autre lecteur…' (New-Spec 'maint' 'Invoke-Chkdsk' 'CHKDSK (autre lecteur)' @{ '^\s*Choix' = '3' })))
    Add-Row $seq.Body '4. WMI : dépôt' 'Vérification, puis réparation sur confirmation.' '' 'n' @((New-Btn 'Vérifier' (New-Spec 'maint' 'Repair-WMI' 'WMI')))
    [void]$p.Children.Add($seq.Card)

    $rst = New-Card 'Réinitialisations' 'Quand un composant de Windows ne répond plus. Créez d''abord un point de restauration (Sauvegarde et restauration > Restauration).'
    Add-Row $rst.Body 'Services Windows' 'Remet les services essentiels à leur démarrage par défaut.' '' 'n' @((New-Btn 'Réinitialiser' (New-Spec 'maint' 'Reset-Services' 'Services Windows')))
    Add-Row $rst.Body 'Réseau' 'DNS, Winsock, TCP/IP, ARP.' 'Coupe la connexion' 'w' @((New-Btn 'Réinitialiser' (New-Spec 'maint' 'Reset-Network' 'Réseau' @{} 'La connexion Internet sera coupée brièvement. Continuer ?')))
    Add-Row $rst.Body 'Windows Update' 'Dossiers renommés en .bak, DLL ré-enregistrées.' 'Redémarrage' 'n' @((New-Btn 'Réinitialiser' (New-Spec 'maint' 'Reset-WindowsUpdate' 'Windows Update')))
    Add-Row $rst.Body 'Options graphiques' 'Préférences GPU, caches de shaders, DPI, pilote d''affichage.' 'L''écran clignote' 'w' @((New-Btn 'Réinitialiser' (New-Spec 'maint' 'Reset-Graphics' 'Options graphiques')))
    Add-Row $rst.Body 'Caches icônes, miniatures, polices' 'L''explorateur est relancé automatiquement.' '' 'n' @((New-Btn 'Vider' (New-Spec 'maint' 'Clear-ShellCaches' 'Caches')))
    Add-Row $rst.Body 'Microsoft Store' 'wsreset puis ré-enregistrement du Store.' '' 'n' @((New-Btn 'Réinitialiser' (New-Spec 'maint' 'Reset-Store' 'Microsoft Store')))
    Add-Row $rst.Body 'Applications Windows' 'Ré-enregistre toutes les applications intégrées.' 'Opération longue' 'n' @((New-Btn 'Ré-enregistrer' (New-Spec 'maint' 'Register-AllApps' 'Applications Windows' @{} 'Opération longue. Continuer ?')))
    Add-Row $rst.Body 'Windows Search' 'L''index est reconstruit en arrière-plan.' '' 'n' @((New-Btn 'Reconstruire' (New-Spec 'maint' 'Reset-Search' 'Windows Search')))
    Add-Row $rst.Body 'Modes d''alimentation' 'Restaure les plans par défaut de Windows.' '' 'n' @((New-Btn 'Restaurer' (New-Spec 'maint' 'Reset-PowerPlan' 'Modes d''alimentation')))
    [void]$p.Children.Add($rst.Card)

    # Deuxième onglet de la section Réparer : les petites actions du quotidien.
    $p = New-Page 'care' 'Nettoyage et dépannage' 'Libérer de la place et régler les petits soucis courants, sans toucher aux fichiers personnels.'

    $dp = New-Card 'Dépannage rapide' 'Petites actions courantes en atelier.' 'Modifie le système' 'w'
    Add-Row $dp.Body 'Redémarrer l''Explorateur' 'Règle les problèmes de barre des tâches, de menu Démarrage ou de bureau figé. L''écran clignote une seconde.' '' 'n' @((New-Btn 'Redémarrer' (New-Spec 'tools' 'Restart-ExplorerShell' 'Explorateur Windows')))
    Add-Row $dp.Body 'Redémarrer les services audio' 'Si le son disparaît ou crépite sans raison.' '' 'n' @((New-Btn 'Redémarrer' (New-Spec 'tools' 'Restart-AudioServices' 'Services audio')))
    Add-Row $dp.Body 'Vider la file d''impression' 'Supprime les travaux bloqués puis relance le spouleur.' '' 'n' @((New-Btn 'Vider' (New-Spec 'tools' 'Clear-PrintQueue' 'File d''impression' @{} 'Supprimer tous les travaux d''impression en attente ?')))
    Add-Row $dp.Body 'Synchroniser l''horloge' 'Recale l''heure sur le serveur de temps Windows.' '' 'n' @((New-Btn 'Synchroniser' (New-Spec 'tools' 'Sync-Clock' 'Horloge')))
    Add-Row $dp.Body 'Diagnostic de la mémoire (RAM)' 'Ouvre l''outil Windows, qui propose de redémarrer le PC pour tester la mémoire.' 'Redémarrage' 'n' @((New-Btn 'Ouvrir' (New-Spec 'tools' 'Start-MemoryDiagnostic' 'Diagnostic de la mémoire')))
    Add-Row $dp.Body 'Vider le cache DNS' 'Utile après un changement de DNS ou un site inaccessible.' '' 'n' @((New-Btn 'Vider' (New-Spec 'tools' 'Clear-DnsCache' 'Cache DNS')))
    [void]$p.Children.Add($dp.Card)

    $ent = New-Card 'Entretien'
    Add-Row $ent.Body 'Nettoyage' 'Fichiers temporaires, corbeille, magasin de composants.' '' 'n' @((New-Btn 'Nettoyer' (New-Spec 'maint' 'Invoke-Cleanup' 'Nettoyage')))
    $wo = New-Check 'Supprimer aussi l''ancienne installation de Windows (Windows.old) : retour à la version précédente impossible ensuite' $false
    $wo.Margin = '0,10,0,0'
    $woSpec = New-Spec 'tools' 'Invoke-DiskCleanup' 'Nettoyage de disque Windows'
    $woSpec.CodeFn = { if ($wo.IsChecked) { 'Invoke-DiskCleanup -WindowsOld' } else { 'Invoke-DiskCleanup' } }.GetNewClosure()
    $woSpec.ConfirmFn = { if ($wo.IsChecked) { 'Windows.old sera supprimé définitivement : vous ne pourrez plus revenir à la version précédente de Windows. Continuer ?' } else { '' } }.GetNewClosure()
    Add-Row $ent.Body 'Nettoyage de disque Windows' 'Outil officiel avec une sélection prudente (fichiers temporaires, caches, journaux). Téléchargements, corbeille et vidages mémoire ne sont jamais touchés. Une fenêtre de Windows s''ouvre pendant le nettoyage.' '' 'n' @((New-Btn 'Nettoyer' $woSpec))
    [void]$ent.Body.Children.Add($wo)
    Add-Row $ent.Body 'Caches des navigateurs' 'Edge, Chrome, Brave, Firefox : dossiers de cache uniquement. Historique, cookies et mots de passe conservés. Fermez les navigateurs avant.' '' 'n' @((New-Btn 'Vider' (New-Spec 'tools' 'Clear-BrowserCaches' 'Caches des navigateurs' @{} 'Les navigateurs ouverts doivent être fermés pour que leurs caches soient vidés. Continuer ?')))
    Add-Row $ent.Body 'Caches de shaders (jeux)' 'Utile après un changement de pilote graphique ou en cas de saccades et de plantages dans un jeu. Les caches DirectX, NVIDIA et AMD sont reconstruits au prochain lancement des jeux ; seuls des fichiers temporaires sont supprimés.' '' 'n' @((New-Btn 'Vider' (New-Spec 'tools' 'Clear-ShaderCache' 'Caches de shaders')))
    Add-Row $ent.Body 'Compte résiduel defaultuser0' 'Laissé par certaines installations de Windows. Supprime le compte seulement, jamais de dossier.' '' 'n' @((New-Btn 'Supprimer' (New-Spec 'tools' 'Remove-DefaultUser0' 'Compte defaultuser0' @{} 'Supprimer le compte utilisateur résiduel defaultuser0 ? Cette suppression ne peut pas être annulée par le Journal.')))
    Add-Row $ent.Body 'Analyse Defender rapide' 'Met à jour les signatures puis analyse.' '' 'n' @((New-Btn 'Analyser' (New-Spec 'maint' 'Invoke-DefenderScan' 'Analyse Defender')))
    [void]$p.Children.Add($ent.Card)
}

# ---------------------------------------------------------------- Gaming
$Script:GamingChecks = @{}
function Build-Gaming {
    $p = New-Page 'gaming' 'Jeux et alimentation' 'Les réglages de Windows qui comptent vraiment pour les jeux, et le mode d''alimentation. Chaque réglage mémorise sa valeur d''origine.'
    # ---- HAGS : un réglage à part entière, avec son état et ses deux boutons
    $hg = New-Card 'Planification GPU matérielle (HAGS)' 'La carte graphique gère elle-même sa file de travail. Requise pour la génération d''images (DLSS 3 et suivants) dans beaucoup de jeux. À désactiver seulement si un jeu ou un logiciel de capture saccade depuis son activation. Redémarrage nécessaire ; sans effet si le pilote graphique ne la propose pas.' 'Redémarrage' 'n'
    $Script:HagsText = New-Text 'État actuel : lecture…' 14 '#C5C9D0' 'Medium'
    $Script:HagsText.Margin = '0,12,0,0'
    [void]$hg.Body.Children.Add($Script:HagsText)
    $hbar = New-Object Windows.Controls.WrapPanel
    $hbar.Margin = '0,12,0,0'
    $hOn = New-Btn 'Activer HAGS' (New-Spec 'opt' 'Set-Hags -Mode on' 'HAGS (activation)' @{} '' $Script:AfterChange) -Primary
    $hOn.Margin = '0,4,0,4'
    [void]$hbar.Children.Add($hOn)
    [void]$hbar.Children.Add((New-Btn 'Désactiver HAGS' (New-Spec 'opt' 'Set-Hags -Mode off' 'HAGS (désactivation)' @{} 'Désactiver la planification GPU matérielle ? La génération d''images DLSS ne fonctionnera plus dans les jeux qui l''exigent.' $Script:AfterChange)))
    [void]$hbar.Children.Add((New-Btn 'Ouvrir le réglage dans Windows' @{ Fn = { try { Start-Process 'ms-settings:display-advancedgraphics' } catch {} } }))
    [void]$hg.Body.Children.Add($hbar)
    [void]$p.Children.Add($hg.Card)

    $c = New-Card 'Réglages de jeu de Windows' 'Mode Jeu, capture en arrière-plan désactivée, jeux fenêtrés optimisés avec fréquence variable. Les options ci-dessous se cochent ou non.'
    $Script:GamingChecks.Hags = New-Check 'Activer aussi la planification GPU matérielle (HAGS, voir ci-dessus)' $true
    $Script:GamingChecks.Mouse = New-Check 'Désactiver l''accélération de la souris (précision du pointeur, effet à la prochaine session)' $false
    $Script:GamingChecks.Mpo = New-Check 'Désactiver MPO (Multiplane Overlay) : seulement en cas de scintillement ou de bug d''affichage OLED/VRR' $false
    [void]$c.Body.Children.Add($Script:GamingChecks.Hags)
    [void]$c.Body.Children.Add($Script:GamingChecks.Mouse)
    [void]$c.Body.Children.Add($Script:GamingChecks.Mpo)
    $gs = New-Spec 'opt' 'Optimize-Gaming' 'Profil Gaming' @{} '' $Script:AfterChange
    $gs.AutoFn = { @{
            'planification GPU'          = $(if ($Script:GamingChecks.Hags.IsChecked) { 'yes' } else { 'no' })
            'accélération de la souris'  = $(if ($Script:GamingChecks.Mouse.IsChecked) { 'yes' } else { 'no' })
            'Multiplane'                 = $(if ($Script:GamingChecks.Mpo.IsChecked) { 'yes' } else { 'no' })
        } }
    $gb = New-Btn 'Appliquer les réglages de jeu' $gs -Primary
    $gb.HorizontalAlignment = 'Left'; $gb.Margin = '0,14,0,0'
    [void]$c.Body.Children.Add($gb)
    [void]$p.Children.Add($c.Card)

    $pw = New-Card 'Mode d''alimentation' 'Sur les processeurs récents, « Équilibré » donne déjà pratiquement toute la puissance en jeu : c''est le bon choix pour un portable ou un PC de bureautique. Les autres modes servent surtout aux PC fixes de jeu. L''annulation revient au plan d''origine.'
    Add-Row $pw.Body 'Équilibré' 'Le réglage par défaut de Windows.' 'Recommandé' 'g' @((New-Btn 'Activer' (New-Spec 'opt' 'Set-BuiltinPowerPlan -Mode balanced' 'Plan Équilibré' @{} '' $Script:AfterChange)))
    Add-Row $pw.Body 'Performances pour PC fixe de jeu (BJMPC Gaming)' 'Copie du plan actif avec le processeur au maximum, PCIe et USB sans économie d''énergie, Wi-Fi en performances maximales. Consomme plus au repos.' 'PC fixe' 'n' @((New-Btn 'Créer et activer' (New-Spec 'opt' 'Optimize-Power' 'Plan d''alimentation' @{} '' $Script:AfterChange)))
    Add-Row $pw.Body 'Plans intégrés de Windows' '« Performances optimales » est créé s''il n''existe pas.' '' 'n' @(
        (New-Btn 'Hautes performances' (New-Spec 'opt' 'Set-BuiltinPowerPlan -Mode high' 'Plan Hautes performances' @{} '' $Script:AfterChange)),
        (New-Btn 'Performances optimales' (New-Spec 'opt' 'Set-BuiltinPowerPlan -Mode ultimate' 'Plan Performances optimales' @{} '' $Script:AfterChange)))
    [void]$p.Children.Add($pw.Card)

    [void](New-TweakCard $p 'Barre de jeu et capture' 'Les réglages de jeu coupent déjà la capture pour votre session. Cette option applique la désactivation complète (stratégie) pour tous les comptes.')
}

# ---------------------------------------------------------------- Réseau
$Script:NetChecks = @{}
function Build-Network {
    $p = New-Page 'net' 'Réseau et DNS' 'Stabilité des cartes Wi-Fi et Ethernet, et DNS chiffré. La pile TCP de Windows 11 est laissée à ses valeurs par défaut. Retour arrière possible.'
    $c = New-Card 'Cartes réseau' 'Pour un Wi-Fi ou un Ethernet qui décroche ou se met en veille : Windows ne peut plus éteindre la carte, les modes Wi-Fi 6/7 sont activés, les économies d''énergie du pilote (U-APSD, MIMO, Ethernet vert) sont coupées. Les cartes redémarrent : la connexion est coupée quelques secondes.'
    $Script:NetChecks.Single = New-Check 'Le Wi-Fi passe par un seul routeur ou point d''accès (pas de réseau maillé) : réduit les recherches d''un autre point d''accès' $false
    [void]$c.Body.Children.Add($Script:NetChecks.Single)
    $ns = New-Spec 'opt' 'Optimize-Network' 'Réseau' @{} '' $Script:AfterChange
    $ns.AutoFn = { @{ 'UN SEUL routeur' = $(if ($Script:NetChecks.Single.IsChecked) { 'yes' } else { 'no' }); 'cartes réseau vont redémarrer' = 'yes' } }
    $nb = New-Btn 'Régler les cartes réseau' $ns -Primary
    $nb.HorizontalAlignment = 'Left'; $nb.Margin = '0,14,0,0'
    [void]$c.Body.Children.Add($nb)
    [void]$p.Children.Add($c.Card)

    [void](New-TweakCard $p 'Pile réseau' 'Ordre de préférence des protocoles.')

    $d = New-Card 'DNS chiffré (Mullvad)' 'DNS over HTTPS en IPv4 et IPv6, mise à niveau automatique. Avec le repli UDP désactivé, si Mullvad est injoignable la résolution s''arrête au lieu de passer en clair.' 'DoH' 'a'
    Add-Row $d.Body 'Mullvad standard' '194.242.2.2 · 2a07:e340::2 · aucun filtrage' '' 'n' @((New-Btn 'Appliquer' (New-Spec 'opt' 'Set-MullvadDns' 'DNS Mullvad standard' @{ '^\s*Choix' = '1'; 'Continuer' = 'yes' } '' $Script:AfterChange) -Primary))
    Add-Row $d.Body 'Mullvad base' '194.242.2.4 · 2a07:e340::4 · bloque pubs, traqueurs et malwares' '' 'n' @((New-Btn 'Appliquer' (New-Spec 'opt' 'Set-MullvadDns' 'DNS Mullvad base' @{ '^\s*Choix' = '2'; 'Continuer' = 'yes' } '' $Script:AfterChange) -Primary))
    Add-Row $d.Body 'Revenir au DNS d''origine' 'Annule la modification du DNS uniquement.' '' 'n' @((New-Btn 'Revenir' (New-Spec 'opt' 'Set-MullvadDns' 'DNS d''origine' @{ '^\s*Choix' = '3' } '' $Script:AfterChange)))
    [void]$p.Children.Add($d.Card)

    $o = New-Card 'Autres DNS chiffrés' 'Même principe (DNS over HTTPS, IPv4 et IPv6). Le repli en clair reste autorisé : si le fournisseur est injoignable, la connexion continue. Le retour au DNS d''origine se fait ci-dessus ou dans le Journal.' 'DoH' 'a'
    Add-Row $o.Body 'Cloudflare' '1.1.1.1 · très rapide' '' 'n' @((New-Btn 'Appliquer' (New-Spec 'opt' 'Set-DnsPreset -Provider cloudflare' 'DNS Cloudflare' @{} '' $Script:AfterChange)))
    Add-Row $o.Body 'Quad9' '9.9.9.9 · bloque les domaines malveillants, siège en Suisse' '' 'n' @((New-Btn 'Appliquer' (New-Spec 'opt' 'Set-DnsPreset -Provider quad9' 'DNS Quad9' @{} '' $Script:AfterChange)))
    Add-Row $o.Body 'AdGuard' '94.140.14.14 · bloque aussi les publicités' '' 'n' @((New-Btn 'Appliquer' (New-Spec 'opt' 'Set-DnsPreset -Provider adguard' 'DNS AdGuard' @{} '' $Script:AfterChange)))
    Add-Row $o.Body 'Google' '8.8.8.8 · très rapide, mais Google voit vos requêtes' '' 'n' @((New-Btn 'Appliquer' (New-Spec 'opt' 'Set-DnsPreset -Provider google' 'DNS Google' @{} '' $Script:AfterChange)))
    Add-Row $o.Body 'OpenDNS' '208.67.222.222 · filtrage de base (Cisco)' '' 'n' @((New-Btn 'Appliquer' (New-Spec 'opt' 'Set-DnsPreset -Provider opendns' 'DNS OpenDNS' @{} '' $Script:AfterChange)))
    [void]$p.Children.Add($o.Card)
    $t = New-Text 'Contrôle : ouvrez https://mullvad.net/check après l''application. Tests de latence et de perte : Réparer > Diagnostics.' 13 '#9298A3' 'Normal' -Wrap
    [void]$p.Children.Add($t)
}

# ---------------------------------------------------------------- Système
$Script:HibRadios = @()
$Script:SysChecks = @{}
function Build-System {
    $p = New-Page 'sys' 'Disque et démarrage' 'Le SSD, le démarrage rapide et l''hibernation. Windows 11 gère seul le reste (SysMain, services) : la Toolbox n''y touche plus.'
    $c = New-Card 'SSD et démarrage' 'Vérifie que le TRIM est actif (et le rétablit s''il a été coupé). Choisissez le reste ci-dessous.'
    $Script:SysChecks.Retrim = New-Check 'Lancer un ReTrim immédiat des volumes SSD' $true
    [void]$c.Body.Children.Add($Script:SysChecks.Retrim)
    $rp = New-Object Windows.Controls.StackPanel
    $rp.Margin = '0,14,0,0'
    [void]$rp.Children.Add((New-Text 'Démarrage rapide et hibernation' 13 '#9298A3'))
    $opts = @(
        @('1', 'Désactiver le démarrage rapide seulement (arrêt complet, pilotes rechargés)'),
        @('2', 'Désactiver aussi l''hibernation (libère plusieurs Go : hiberfil.sys)'),
        @('3', 'Ne rien changer au démarrage rapide ni à l''hibernation'))
    $Script:HibRadios = @()
    foreach ($o in $opts) {
        $rb = New-Object Windows.Controls.RadioButton
        $rb.GroupName = 'hib'; $rb.Content = $o[1]; $rb.Tag = $o[0]; $rb.Margin = '0,4,0,4'
        $rb.Foreground = (Br '#C5C9D0'); $rb.IsChecked = ($o[0] -eq '3')
        [void]$rp.Children.Add($rb)
        $Script:HibRadios += $rb
    }
    [void]$c.Body.Children.Add($rp)
    $spec = New-Spec 'opt' 'Optimize-Storage' 'SSD et démarrage' @{} '' $Script:AfterChange
    $spec.AutoFn = {
        $sel = $Script:HibRadios | Where-Object { $_.IsChecked } | Select-Object -First 1
        @{ 'ReTrim' = $(if ($Script:SysChecks.Retrim.IsChecked) { 'yes' } else { 'no' }); '^\s*Choix' = $(if ($sel) { [string]$sel.Tag } else { '3' }) }
    }
    $b = New-Btn 'Appliquer' $spec -Primary
    $b.HorizontalAlignment = 'Left'; $b.Margin = '0,14,0,0'
    [void]$c.Body.Children.Add($b)
    [void]$p.Children.Add($c.Card)

    [void](New-TweakCard $p 'Démarrage et diagnostic' 'Affichage au démarrage, écran bleu et horloge matérielle.')

    $n = New-Text 'Les anciennes cartes « Services inutiles » ont été retirées : désactiver des services ne rend pas Windows 11 plus rapide. Pour remettre par défaut des services modifiés par une ancienne version : Sauvegarde et restauration > Restauration > « Comparer avec Windows 11 ».' 13 '#9298A3' 'Normal' -Wrap
    [void]$p.Children.Add($n)
}

# ---------------------------------------------------------------- Affichage
$Script:MonPanel = $null
$Script:DistSlider = $null
$Script:DistLabel = $null
$Script:TextSlider = $null
$Script:TextLabel = $null

$Script:AnalyzeCode = @'
Initialize-DpiApi | Out-Null
$Script:DiagOverride = $Sync.Diag
$d = __DIST__
$list = @()
foreach ($m in @(Get-DisplayModel)) {
    $list += [pscustomobject]@{ Name = $m.Name; DevicePath = $m.DevicePath; Width = $m.Width; Height = $m.Height; DiagIn = $m.DiagIn; Ppi = $m.Ppi; Source = $m.Source; Suspect = $m.Suspect; CurPct = $m.CurPct; RecPct = $m.RecPct; MinPct = $m.MinPct; MaxPct = $m.MaxPct; Sug = (Get-SuggestedScale $m $d) }
}
$Sync.Result = $list
'@

$Script:ApplyScaleCode = @'
Initialize-DpiApi | Out-Null
$m = @(Get-DisplayModel) | Where-Object { $_.DevicePath -eq '__PATH__' } | Select-Object -First 1
if (-not $m) { Write-Log 'Écran introuvable.' 'ERROR' } else { [void](Set-MonitorScale $m __PCT__) }
'@

function Analyze-Monitors {
    $dist = [int]$Script:DistSlider.Value
    $code = $Script:AnalyzeCode.Replace('__DIST__', [string]$dist)
    Start-Run -Engine 'opt' -Code $code -Title '' -OnDone { param($res) Show-Monitors $res }
}

function Show-Monitors {
    param($List)
    $Script:MonPanel.Children.Clear()
    $items = @($List)
    if ($items.Count -eq 0 -or -not $items[0]) {
        [void]$Script:MonPanel.Children.Add((New-Text 'Aucun écran exploitable détecté, ou l''API d''échelle est indisponible (voir la console).' 13 '#F5B94A' 'Normal' -Wrap))
        return
    }
    $steps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)
    foreach ($m in $items) {
        $c = New-Card ("{0}  ·  {1} × {2}" -f $m.Name, $m.Width, $m.Height) '' '' 'n' '0,0,0,16'
        if ($m.DiagIn -gt 0) {
            $info = "{0:N1} pouces ({1}) · {2:N0} PPI" -f $m.DiagIn, $m.Source, $m.Ppi
            $t = New-Text $info 15 '#5AD1FF' 'Medium' -Font 'Consolas'
        } else {
            $t = New-Text 'Taille inconnue (pas d''EDID exploitable) : saisissez la diagonale ci-dessous.' 14 '#F5B94A' 'Normal' -Wrap
        }
        $t.Margin = '0,10,0,0'
        [void]$c.Body.Children.Add($t)
        if ($m.Suspect -and $m.DiagIn -gt 0 -and $m.Source -notmatch 'saisie') {
            $w = New-Text 'Taille EDID douteuse (arrondie ou ratio incohérent) : vérifiez la diagonale réelle ci-dessous.' 13 '#F5B94A' 'Normal' -Wrap
            $w.Margin = '0,4,0,0'
            [void]$c.Body.Children.Add($w)
        }
        $sub = "Échelle actuelle {0} %  ·  recommandée par Windows {1} %  ·  suggestion {2} % (à {3} cm)" -f $m.CurPct, $m.RecPct, $m.Sug, [int]$Script:DistSlider.Value
        $s = New-Text $sub 13 '#9298A3' 'Normal' -Wrap
        $s.Margin = '0,6,0,10'
        [void]$c.Body.Children.Add($s)
        $wrap = New-Object Windows.Controls.WrapPanel
        foreach ($pct in $steps) {
            if ($pct -lt $m.MinPct -or $pct -gt $m.MaxPct) { continue }
            $label = "$pct %"
            $notes = @()
            if ($pct -eq $m.CurPct) { $notes += 'actuel' }
            if ($pct -eq $m.RecPct) { $notes += 'Windows' }
            if ($pct -eq $m.Sug) { $notes += 'suggestion' }
            if ($notes.Count -gt 0) { $label = "$pct %  ·  " + ($notes -join ', ') }
            $code = $Script:ApplyScaleCode.Replace('__PATH__', ([string]$m.DevicePath -replace "(['\u2018\u2019\u201A\u201B])", '$1$1')).Replace('__PCT__', [string]$pct)
            $spec = New-Spec 'opt' $code ("Échelle {0} % sur {1}" -f $pct, $m.Name) @{} '' { param($r) Analyze-Monitors }
            $b = New-Btn $label $spec -Primary:($pct -eq $m.Sug)
            $b.Margin = '0,4,8,4'
            [void]$wrap.Children.Add($b)
        }
        [void]$c.Body.Children.Add($wrap)

        $diag = New-Object Windows.Controls.StackPanel
        $diag.Orientation = 'Horizontal'; $diag.Margin = '0,12,0,0'
        $diag.Children.Add((New-Text 'Diagonale réelle (pouces)' 13 '#C5C9D0')) | Out-Null
        $tb = New-Object Windows.Controls.TextBox
        $tb.Width = 70; $tb.Margin = '12,0,0,0'; $tb.Padding = '8,6'
        $tb.Background = (Br '#14181E'); $tb.Foreground = (Br '#ECEDEF'); $tb.CaretBrush = (Br '#ECEDEF'); $tb.BorderBrush = (Br '#2A2E36')
        $diag.Children.Add($tb) | Out-Null
        $spec2 = @{ Box = $tb; Path = [string]$m.DevicePath; Fn = {
            param($sp)
            $v = ([string]$sp.Box.Text) -replace ',', '.'
            $dd = 0.0
            if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dd) -and $dd -ge 10 -and $dd -le 100) {
                $Script:Sync.Diag[$sp.Path] = $dd
                Add-Console ("Diagonale fixée à {0} pouces pour le calcul (cette session)." -f $dd) 'Green'
                Analyze-Monitors
            } else {
                [void][Windows.MessageBox]::Show($Script:Window, 'Entrez une diagonale entre 10 et 100 pouces (ex : 27, 31.5, 42, 48).', 'BJMPC Toolbox', 'OK', 'Information')
            }
        } }
        $bd = New-Btn 'Recalculer' $spec2
        $diag.Children.Add($bd) | Out-Null
        [void]$c.Body.Children.Add($diag)
        [void]$Script:MonPanel.Children.Add($c.Card)
    }
}

function Build-Display {
    $p = New-Page 'display' 'Affichage et OLED' 'Taille de l''affichage calculée à partir des pixels par pouce réels de l''écran (Windows prend 96 PPI comme référence, soit 100 %), et protection des écrans OLED.'
    $c = New-Card 'Densité et échelle' 'Windows se base sur la taille physique lue dans l''EDID, souvent fausse sur les TV et certains OLED. Réglez la distance puis analysez.'
    $dRow = New-Object Windows.Controls.StackPanel
    $dRow.Orientation = 'Horizontal'; $dRow.Margin = '0,14,0,0'
    [void]$dRow.Children.Add((New-Text 'Distance yeux-écran' 14 '#C5C9D0'))
    $Script:DistSlider = New-Object Windows.Controls.Slider
    $Script:DistSlider.Minimum = 40; $Script:DistSlider.Maximum = 120; $Script:DistSlider.Value = 70
    $Script:DistSlider.Width = 240; $Script:DistSlider.Margin = '16,0,12,0'; $Script:DistSlider.IsSnapToTickEnabled = $true; $Script:DistSlider.TickFrequency = 1
    $Script:DistLabel = New-Text '70 cm' 14 '#ECEDEF' 'Medium' -Font 'Consolas'
    $Script:DistSlider.Add_ValueChanged({ param($s, $e) $Script:DistLabel.Text = ("{0} cm" -f [int]$s.Value) })
    [void]$dRow.Children.Add($Script:DistSlider); [void]$dRow.Children.Add($Script:DistLabel)
    [void]$c.Body.Children.Add($dRow)
    $ab = New-Btn 'Analyser les écrans' @{ Fn = { Analyze-Monitors } } -Primary
    $ab.HorizontalAlignment = 'Left'; $ab.Margin = '0,14,0,0'
    [void]$c.Body.Children.Add($ab)
    [void]$p.Children.Add($c.Card)
    $Script:MonPanel = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add($Script:MonPanel)

    $t = New-Card 'Taille du texte seule' 'Réglage fin de 100 à 225 % sans flouter les applications. Fermez puis rouvrez la session pour une prise en compte complète.'
    $tRow = New-Object Windows.Controls.StackPanel
    $tRow.Orientation = 'Horizontal'; $tRow.Margin = '0,14,0,0'
    $Script:TextSlider = New-Object Windows.Controls.Slider
    $Script:TextSlider.Minimum = 100; $Script:TextSlider.Maximum = 225; $Script:TextSlider.Value = 100
    $Script:TextSlider.Width = 260; $Script:TextSlider.IsSnapToTickEnabled = $true; $Script:TextSlider.TickFrequency = 5; $Script:TextSlider.Margin = '0,0,12,0'
    $Script:TextLabel = New-Text '100 %' 14 '#ECEDEF' 'Medium' -Font 'Consolas'
    $Script:TextSlider.Add_ValueChanged({ param($s, $e) $Script:TextLabel.Text = ("{0} %" -f [int]$s.Value) })
    [void]$tRow.Children.Add($Script:TextSlider); [void]$tRow.Children.Add($Script:TextLabel)
    $tspec = New-Spec 'opt' '' 'Taille du texte'
    $tspec.CodeFn = { "Set-Reg 'HKCU:\Software\Microsoft\Accessibility' 'TextScaleFactor' {0}" -f [int]$Script:TextSlider.Value }
    [void]$tRow.Children.Add((New-Btn 'Appliquer' $tspec))
    [void]$t.Body.Children.Add($tRow)
    [void]$p.Children.Add($t.Card)
    try {
        $cur = (Get-ItemProperty 'HKCU:\Software\Microsoft\Accessibility' -Name TextScaleFactor -ErrorAction Stop).TextScaleFactor
        if ($cur -ge 100 -and $cur -le 225) { $Script:TextSlider.Value = $cur }
    } catch {}

    $o = New-Card 'Protection OLED' 'Seulement pour un écran OLED : mode sombre et extinction de l''écran après 10 minutes. Rappelle aussi les réglages à faire à la main (barre des tâches masquée, rafraîchissement et décalage des pixels dans le menu de l''écran).' 'Écran OLED' 'n'
    Add-Row $o.Body 'Appliquer la protection OLED' '' '' 'n' @((New-Btn 'Appliquer' (New-Spec 'opt' 'Set-OledCare' 'Protection OLED' @{} '' $Script:AfterChange) -Primary))
    [void]$p.Children.Add($o.Card)
}

# ---------------------------------------------------------------- Journal et annulation
$Script:JournalPanel = $null
$Script:JournalChecks = @()
$Script:RestorePanel = $null
$Script:TypeLabels = @{
    reg = 'Registre'; svc = 'Services'; task = 'Tâches planifiées'; adv = 'Carte réseau (propriétés)'; nicpm = 'Carte réseau (énergie)'
    rsc = 'Carte réseau (RSC)'; dns = 'DNS'; power = 'Plan d''alimentation'; fsutil = 'Système de fichiers'; hib = 'Hibernation'
    mma = 'Compression mémoire'; dpi = 'Échelle d''affichage'
    regkey = 'Clés de registre créées'; feature = 'Fonctionnalités Windows'; cap = 'Capacités Windows'
}

function Load-Journal {
    if (-not $Script:JournalPanel) { return }
    $Script:JournalPanel.Children.Clear()
    $Script:JournalChecks = @()
    $recs = @()
    try {
        if (Test-Path $Script:StateFile) {
            $raw = Get-Content $Script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $recs = @($raw | Where-Object { $_ -and $_.Key })
        }
    } catch {}
    if ($recs.Count -eq 0) {
        [void]$Script:JournalPanel.Children.Add((New-Text 'Aucune modification enregistrée : il n''y a rien à annuler.' 14 '#9298A3' 'Normal' -Wrap))
        return
    }
    foreach ($g in ($recs | Group-Object Type | Sort-Object Name)) {
        $label = if ($Script:TypeLabels.ContainsKey([string]$g.Name)) { $Script:TypeLabels[[string]$g.Name] } else { [string]$g.Name }
        $row = New-Object Windows.Controls.DockPanel
        $row.Margin = '0,8,0,0'
        $cb = New-Object Windows.Controls.CheckBox
        $cb.IsChecked = $true; $cb.Tag = [string]$g.Name; $cb.VerticalAlignment = 'Center'; $cb.Margin = '0,0,12,0'
        [void]$row.Children.Add($cb)
        $cnt = New-Text ("{0} valeur(s)" -f $g.Count) 13 '#9298A3' 'Normal' -Font 'Consolas'
        [Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
        [void]$row.Children.Add($cnt)
        [void]$row.Children.Add((New-Text $label 14 '#ECEDEF' 'Medium'))
        [void]$Script:JournalPanel.Children.Add($row)
        $Script:JournalChecks += $cb
    }
}

$Script:RevertCode = @'
Import-Orig
$types = @(__TYPES__)
$recs = @($Script:Orig.Values | Where-Object { $types -contains [string]$_.Type })
if ($recs.Count -eq 0) { Write-Log 'Rien à annuler pour cette sélection.' 'WARN' }
else {
    [array]::Reverse($recs)
    foreach ($r in $recs) { Restore-Record $r; $Script:Orig.Remove($r.Key) }
    Save-Orig
    $Script:RebootNeeded = $true
    Write-Log ("{0} modification(s) annulée(s). Redémarrage conseillé." -f $recs.Count) 'OK'
}
'@

$Script:RestoreListCode = @'
$out = @()
try {
    $out = @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending | Select-Object -First 6 | ForEach-Object {
        [pscustomobject]@{ Name = $_.Description; Date = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) }
    })
} catch {}
$Sync.Result = $out
'@

function Load-RestorePoints {
    Start-Run -Engine 'none' -Code $Script:RestoreListCode -Title '' -OnDone {
        param($res)
        $Script:RestorePanel.Children.Clear()
        $items = @($res | Where-Object { $_ })
        if ($items.Count -eq 0) {
            [void]$Script:RestorePanel.Children.Add((New-Text 'Aucun point de restauration trouvé (ou la protection du système est désactivée).' 13 '#9298A3' 'Normal' -Wrap))
            return
        }
        foreach ($it in $items) {
            $sp = New-Object Windows.Controls.StackPanel
            $sp.Margin = '0,8,0,0'
            [void]$sp.Children.Add((New-Text ([string]$it.Name) 14 '#ECEDEF' 'Medium'))
            [void]$sp.Children.Add((New-Text (([datetime]$it.Date).ToString('dd/MM/yyyy HH:mm')) 12 '#9298A3'))
            [void]$Script:RestorePanel.Children.Add($sp)
        }
    }
}

$Script:DefChecks = New-Object 'System.Collections.Generic.List[object]'
$Script:DefHeaders = @{}
$Script:DefCols = @(3.4, 1.7, 1.7)
$Script:DefPanel = $null
$Script:DefSummary = $null

function Update-DefaultsHeaders {
    # Case d'en-tête de catégorie : cochée si tout est coché, vide si rien, indéterminée sinon.
    foreach ($k in @($Script:DefHeaders.Keys)) {
        $mine = @($Script:DefChecks | Where-Object { $_.Cat -eq $k })
        if ($mine.Count -eq 0) { continue }
        $on = @($mine | Where-Object { $_.Check.IsChecked }).Count
        $h = $Script:DefHeaders[$k]
        if ($on -eq 0) { $h.IsChecked = $false } elseif ($on -eq $mine.Count) { $h.IsChecked = $true } else { $h.IsChecked = $null }
    }
}

function Show-DefaultsRows {
    param($Res)
    if (-not $Script:DefPanel) { return }
    $Script:DefPanel.Children.Clear(); $Script:DefChecks.Clear(); $Script:DefHeaders = @{}
    $rows = @($Res | Where-Object { $_ -and $_.Id })
    if ($rows.Count -eq 0) {
        $Script:DefSummary.Text = 'Aucun écart : pour les réglages connus, ce PC est déjà aux valeurs par défaut de Windows 11.'
        return
    }
    $Script:DefSummary.Text = ('{0} réglage(s) diffèrent de Windows 11. Décochez ce que vous voulez conserver, puis « Rétablir les réglages cochés ».' -f $rows.Count)
    foreach ($g in ($rows | Group-Object Cat)) {
        $first = $g.Group | Select-Object -First 1
        $hc = New-Object Windows.Controls.CheckBox
        $hc.IsThreeState = $true; $hc.Tag = [string]$g.Name; $hc.IsChecked = [bool]$first.On
        $hc.Add_Click({ param($s, $e)
            try {
                $v = [bool]$s.IsChecked
                foreach ($x in @($Script:DefChecks | Where-Object { $_.Cat -eq [string]$s.Tag })) { $x.Check.IsChecked = $v }
                $s.IsChecked = $v
            } catch { Add-Console ('  [!]   ' + $_.Exception.Message) 'Yellow' }
        })
        $Script:DefHeaders[[string]$g.Name] = $hc
        $head = New-TableRow $Script:DefCols @(@{ T = ('{0}  ({1})' -f $first.CatName, $g.Count); C = '#5AD1FF'; W = 'SemiBold' }, '', '') $hc
        $head.Margin = '0,10,0,0'
        [void]$Script:DefPanel.Children.Add($head)
        foreach ($r in $g.Group) {
            $cb = New-Check '' ([bool]$r.On)
            $cb.Tag = [string]$r.Id
            $cb.Add_Click({ try { Update-DefaultsHeaders } catch {} })
            $cells = @(
                @{ T = [string]$r.Label; C = '#ECEDEF'; Tip = ([string]$r.Tip -replace '\|', '\') },
                @{ T = [string]$r.Def; C = '#7CE3A1'; W = 'SemiBold' },
                @{ T = [string]$r.Cur; C = '#F5B94A' }
            )
            [void]$Script:DefPanel.Children.Add((New-TableRow $Script:DefCols $cells $cb))
            [void]$Script:DefChecks.Add([pscustomobject]@{ Check = $cb; Cat = [string]$g.Name })
        }
    }
    Update-DefaultsHeaders
}

function Build-Journal {
    $p = New-Page 'journal' 'Restauration' 'Revenir en arrière : annuler ce que la Toolbox a modifié, rétablir les réglages d''origine de Windows 11, ou utiliser un point de restauration.'
    $c = New-Card 'Journal : annuler les modifications de la Toolbox' 'Chaque modification a gardé sa valeur d''origine. Cochez les catégories à annuler ; les valeurs sont restaurées dans l''ordre inverse des modifications.'
    $Script:JournalPanel = New-Object Windows.Controls.StackPanel
    $Script:JournalPanel.Margin = '0,10,0,0'
    [void]$c.Body.Children.Add($Script:JournalPanel)
    $bar = New-Object Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.Margin = '0,16,0,0'
    $selSpec = New-Spec 'opt' '' 'Annulation de la sélection' @{} 'Annuler les modifications des catégories cochées ?' { param($r) Load-Journal; Refresh-Dashboard }
    $selSpec.CodeFn = {
        $types = @($Script:JournalChecks | Where-Object { $_.IsChecked } | ForEach-Object { "'" + ([string]$_.Tag -replace "(['\u2018\u2019\u201A\u201B])", '$1$1') + "'" })
        $Script:RevertCode.Replace('__TYPES__', ($types -join ','))
    }
    $b1 = New-Btn 'Annuler la sélection' $selSpec -Primary; $b1.Margin = '0,0,0,0'
    [void]$bar.Children.Add($b1)
    [void]$bar.Children.Add((New-Btn 'Tout annuler' (New-Spec 'opt' 'Restore-All' 'Retour à l''état d''origine' @{} '' { param($r) Load-Journal; Refresh-Dashboard })))
    [void]$bar.Children.Add((New-Btn 'Actualiser' @{ Fn = { Load-Journal } }))
    [void]$c.Body.Children.Add($bar)
    [void]$p.Children.Add($c.Card)

    # ---- Retour aux valeurs par défaut de Windows 11
    $d = New-Card 'Rétablir les valeurs par défaut de Windows 11' 'Compare ce PC à un Windows 11 d''origine (services, priorités système, réseau, télémétrie, stratégies, tâches) et remet les écarts à leur valeur par défaut. Utile quand le Journal est vide (réglages posés par une ancienne version ou un autre outil). Ne touche ni la sécurité, ni les pilotes, ni les stratégies d''un PC en domaine. Un point de restauration est créé et les valeurs actuelles sont enregistrées : tout s''annule.' 'Sans risque pour Windows' 'g'
    $dc = New-Spec 'tools' 'Get-Win11DefaultsState' 'Comparaison avec Windows 11'
    $dc.OnDone = { param($r) Show-DefaultsRows $r }
    $dr = New-Spec 'tools' '' 'Rétablissement des valeurs par défaut Windows 11'
    $dr.CodeFn = {
        $ids = @($Script:DefChecks | Where-Object { $_.Check.IsChecked } | ForEach-Object { "'" + ([string]$_.Check.Tag -replace '[^A-Za-z0-9_:{}\-\.]', '') + "'" })
        if ($ids.Count -eq 0) { return '' }
        return ('Restore-Win11Defaults -Ids @(' + ($ids -join ',') + ')')
    }
    $dr.ConfirmFn = {
        $n = @($Script:DefChecks | Where-Object { $_.Check.IsChecked }).Count
        "Rétablir {0} réglage(s) aux valeurs par défaut de Windows 11 ? Un point de restauration est créé et les valeurs actuelles sont enregistrées (annulation possible depuis cette carte). Un redémarrage est conseillé ensuite." -f $n
    }
    $dr.OnDone = { param($r) $Script:DefPanel.Children.Clear(); $Script:DefChecks.Clear(); $Script:DefSummary.Text = 'Terminé. Cliquez sur « Comparer avec Windows 11 » pour vérifier ce qui reste (redémarrez d''abord si possible).' }
    $du = New-Spec 'tools' 'Undo-Win11Defaults' 'Annulation du rétablissement Windows 11' @{} 'Remettre les valeurs telles qu''elles étaient avant le dernier rétablissement ?' { param($r) $Script:DefPanel.Children.Clear(); $Script:DefChecks.Clear(); $Script:DefSummary.Text = 'Valeurs d''avant remises. Comparez de nouveau si besoin.' }
    $dbar = New-Object Windows.Controls.WrapPanel
    $dbar.Margin = '0,14,0,0'
    $db1 = New-Btn 'Comparer avec Windows 11' $dc -Primary; $db1.Margin = '0,4,0,4'
    [void]$dbar.Children.Add($db1)
    [void]$dbar.Children.Add((New-Btn 'Rétablir les réglages cochés' $dr -Primary))
    $dAll = New-Object Windows.Controls.Button
    $dAll.Content = 'Tout cocher'; $dAll.Style = $Script:Window.FindResource('Btn'); $dAll.Margin = '8,4,0,4'
    $dAll.Add_Click({ foreach ($x in @($Script:DefChecks)) { $x.Check.IsChecked = $true }; Update-DefaultsHeaders })
    [void]$dbar.Children.Add($dAll)
    $dNone = New-Object Windows.Controls.Button
    $dNone.Content = 'Tout décocher'; $dNone.Style = $Script:Window.FindResource('Btn'); $dNone.Margin = '8,4,0,4'
    $dNone.Add_Click({ foreach ($x in @($Script:DefChecks)) { $x.Check.IsChecked = $false }; Update-DefaultsHeaders })
    [void]$dbar.Children.Add($dNone)
    [void]$dbar.Children.Add((New-Btn 'Annuler le dernier rétablissement' $du))
    [void]$d.Body.Children.Add($dbar)
    $Script:DefSummary = New-Text 'Cliquez sur « Comparer avec Windows 11 » : la comparaison ne modifie rien.' 13 '#5AD1FF' 'Medium' -Wrap
    $Script:DefSummary.Margin = '0,12,0,8'
    [void]$d.Body.Children.Add($Script:DefSummary)
    $dh = New-TableRow $Script:DefCols @('Réglage', 'Valeur par défaut', 'Valeur actuelle') -Header
    $dh.Margin = '0,0,18,0'
    [void]$d.Body.Children.Add($dh)
    $Script:DefPanel = New-Object Windows.Controls.StackPanel
    [void]$d.Body.Children.Add((New-ScrollList $Script:DefPanel 420))
    $dn = New-Text 'Les réglages « Interface et Explorateur » (confort : fichiers cachés, menu classique, souris…) ne sont pas cochés : ce sont des choix personnels. Les réglages réseau avancés, DNS et plans d''alimentation se défont depuis le Journal ci-dessus.' 12 '#9298A3' 'Normal' -Wrap
    $dn.Margin = '0,8,0,0'
    [void]$d.Body.Children.Add($dn)
    [void]$p.Children.Add($d.Card)

    $r = New-Card 'Points de restauration' 'Les 6 plus récents.'
    $Script:RestorePanel = New-Object Windows.Controls.StackPanel
    $Script:RestorePanel.Margin = '0,6,0,0'
    [void]$r.Body.Children.Add($Script:RestorePanel)
    $rb = New-Object Windows.Controls.StackPanel
    $rb.Orientation = 'Horizontal'; $rb.Margin = '0,14,0,0'
    $cr = New-Btn 'Créer un point de restauration' (New-Spec 'opt' 'New-RestorePoint' 'Point de restauration' @{} '' { param($x) Load-RestorePoints })
    $cr.Margin = '0,0,0,0'
    [void]$rb.Children.Add($cr)
    [void]$rb.Children.Add((New-Btn 'Actualiser' @{ Fn = { Load-RestorePoints } }))
    [void]$rb.Children.Add((New-Btn 'Ouvrir la restauration du système' @{ Fn = { try { Start-Process rstrui.exe } catch {} } }))
    [void]$r.Body.Children.Add($rb)
    [void]$p.Children.Add($r.Card)
}

#endregion
# ================================================================ RÉPARATION GUIDÉE PAR L'OBSERVATEUR D'ÉVÉNEMENTS
#region Événements

$Script:Evt = @{
    Rows        = (New-Object 'System.Collections.Generic.List[object]')   # cases à cocher des constats réparables
    Analyzed    = $false
    LiveCount   = 0
    AutoDone    = @{}                                                       # constats déjà réparés automatiquement dans cette session
    AutoPending = (New-Object 'System.Collections.Generic.List[object]')
}
$Script:EvtWatch = $null
# Réponses préparées aux deux questions des réparations lourdes : DISM répare, CHKDSK fait l'analyse en ligne.
$Script:EvtAuto = @{ 'RestoreHealth' = 'yes'; '^\s*Choix' = '1' }

function New-EventRow {
    # Une ligne de constat : case à cocher (si réparable), titre, explication, réparation ou conseil.
    param($F, [switch]$Live)
    $bd = New-Object Windows.Controls.Border
    $bd.BorderBrush = (Br '#1A1D22'); $bd.BorderThickness = '0,0,0,1'; $bd.Padding = '0,10'
    $bd.Background = [Windows.Media.Brushes]::Transparent
    if ($F.Sample) {
        $tip = New-Text ("Message de Windows :`n" + [string]$F.Sample) 12 '#111111' 'Normal' -Wrap
        $tip.MaxWidth = 620
        $bd.ToolTip = $tip
        [Windows.Controls.ToolTipService]::SetShowDuration($bd, 60000)
    }
    $g = New-Object Windows.Controls.Grid
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::new(30)
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(1, 'Star')
    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
    $cb = $null
    $fixable = ([string]$F.Kind -eq 'fix')
    if ($fixable -and -not $Live) {
        $cb = New-Object Windows.Controls.CheckBox
        # Cochées d'office : les réparations rapides et sans risque. Les lourdes se cochent à la main.
        $cb.IsChecked = ([string]$F.Status -ne 'fixed' -and [bool]$F.Safe); $cb.Tag = $F; $cb.VerticalAlignment = 'Top'; $cb.Margin = '0,3,0,0'
        [void]$g.Children.Add($cb)
    } else {
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8; $dot.VerticalAlignment = 'Top'; $dot.HorizontalAlignment = 'Left'; $dot.Margin = '4,7,0,0'
        $dot.Fill = (Br $(switch ([string]$F.Kind) { 'fix' { '#5AD1FF' } 'advice' { if ([int]$F.Sev -ge 3) { '#FF7B7B' } else { '#F5B94A' } } 'noise' { '#4A505B' } default { '#9298A3' } }))
        [void]$g.Children.Add($dot)
    }
    $sp = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($sp, 1)
    $head = New-Object Windows.Controls.WrapPanel
    $title = [string]$F.Title
    if ($Live) { $title = ([datetime]$F.Last).ToString('HH:mm:ss') + '   ' + $title }
    [void]$head.Children.Add((New-Text $title 14 $(if ([string]$F.Kind -eq 'noise') { '#9298A3' } else { '#ECEDEF' }) 'Medium' -Wrap))
    if ([int]$F.Count -gt 1) { [void]$head.Children.Add((New-Tag ("{0} fois" -f $F.Count) 'n')) }
    if ([int]$F.Sev -ge 3) { [void]$head.Children.Add((New-Tag 'Important' 'r')) }
    if ($fixable -and -not $F.Safe -and -not $Live) { [void]$head.Children.Add((New-Tag 'Réparation lourde : à cocher vous-même' 'w')) }
    if ([string]$F.Status -eq 'fixed') { [void]$head.Children.Add((New-Tag ("Réparé le {0} : plus d'erreur depuis" -f ([datetime]$F.FixedAt).ToString('dd/MM à HH:mm')) 'g')) }
    elseif ([string]$F.Status -eq 'back') { [void]$head.Children.Add((New-Tag ("Revenu après la réparation du {0}" -f ([datetime]$F.FixedAt).ToString('dd/MM')) 'r')) }
    [void]$sp.Children.Add($head)
    if (-not $Live) {
        [void]$sp.Children.Add((New-Text ("Dernière fois le {0}   ·   {1}, événement {2}" -f ([datetime]$F.Last).ToString('dd/MM à HH:mm'), $F.Provider, $F.EventId) 12 '#7A808B' 'Normal' -Wrap))
    }
    if ($F.Why) { [void]$sp.Children.Add((New-Text ([string]$F.Why) 13 '#9298A3' 'Normal' -Wrap)) }
    if ($fixable) {
        $a = New-Text ('Réparation : ' + [string]$F.FixLabel) 13 '#5AD1FF' 'Medium' -Wrap
        $a.Margin = '0,3,0,0'
        [void]$sp.Children.Add($a)
        if ([string]$F.Status -eq 'back' -and $F.Advice) { [void]$sp.Children.Add((New-Text ('La réparation n''a pas suffi. ' + [string]$F.Advice) 13 '#F5B94A' 'Normal' -Wrap)) }
        elseif ($F.Advice) { [void]$sp.Children.Add((New-Text ('Ensuite : ' + [string]$F.Advice) 12.5 '#7A808B' 'Normal' -Wrap)) }
    } elseif ($F.Advice) {
        $a = New-Text ('À faire : ' + [string]$F.Advice) 13 '#C5C9D0' 'Normal' -Wrap
        $a.Margin = '0,3,0,0'
        [void]$sp.Children.Add($a)
    }
    [void]$g.Children.Add($sp)
    $bd.Child = $g
    return @{ Row = $bd; Check = $cb; Stack = $sp }
}

function Show-EventFindings {
    param($Res)
    $e = $Script:Evt
    if (-not $e.Panel -or -not $Res) { return }
    $e.Analyzed = $true
    $e.Panel.Children.Clear(); $e.Rows.Clear()
    $list = @($Res.Findings | Where-Object { $_ })
    if ($list.Count -eq 0) {
        $e.Summary.Text = 'Aucune erreur dans le journal de Windows sur cette période : rien à réparer.'
        $e.Summary.Foreground = (Br '#62D98B')
        return
    }
    $sections = @(
        @('fix', 'À réparer', '#5AD1FF'),
        @('advice', 'À regarder : matériel ou logiciel, pas de réparation automatique', '#F5B94A'),
        @('unknown', 'Erreurs que la Toolbox ne sait pas interpréter', '#9298A3'),
        @('noise', 'Sans gravité : bruit connu de Windows, rien à faire', '#7A808B'))
    foreach ($s in $sections) {
        $sub = @($list | Where-Object { [string]$_.Kind -eq $s[0] })
        if ($sub.Count -eq 0) { continue }
        $h = New-Text ("{0}  ({1})" -f $s[1], $sub.Count) 13 $s[2] 'SemiBold' -Wrap
        $h.Margin = '0,14,0,2'
        [void]$e.Panel.Children.Add($h)
        foreach ($f in $sub) {
            $r = New-EventRow $f
            [void]$e.Panel.Children.Add($r.Row)
            if ($r.Check) { [void]$e.Rows.Add($r.Check) }
        }
    }
    $nFix = @($list | Where-Object { $_.Kind -eq 'fix' -and $_.Status -ne 'fixed' }).Count
    $nAdv = @($list | Where-Object { $_.Kind -eq 'advice' }).Count
    $txt = if ($nFix -gt 0) { "{0} problème(s) avec une réparation prête : vérifiez les cases (les réparations lourdes ne sont pas cochées d'office), puis « Réparer ce qui est coché »." -f $nFix }
           elseif ($nAdv -gt 0) { 'Rien à réparer automatiquement.' } else { 'Rien à réparer.' }
    if ($nAdv -gt 0) { $txt += "  {0} point(s) demandent un coup d'œil du technicien (matériel ou logiciel)." -f $nAdv }
    if ($Res.Truncated) { $txt += '  Journal très chargé : seuls les événements les plus récents ont été lus.' }
    $e.Summary.Text = $txt
    $e.Summary.Foreground = (Br $(if ($nFix -gt 0) { '#5AD1FF' } elseif ($nAdv -gt 0) { '#F5B94A' } else { '#62D98B' }))
}

function Get-EventAnalysisCode {
    $t = 'd7'; try { $t = [string]$Script:Evt.Period.SelectedItem.Tag } catch {}
    switch ($t) { 'h24' { 'Get-EventFindings -Hours 24' } 'd30' { 'Get-EventFindings -Days 30' } default { 'Get-EventFindings -Days 7' } }
}

function Start-EventAnalysis {
    # Analyse silencieuse (à l'ouverture de l'onglet et après une réparation) : lecture seule, moins d'une seconde.
    if ($Script:Run -or $Script:EngineError) { return }
    Start-Run -Engine 'evt' -Code (Get-EventAnalysisCode) -Title '' -OnDone { param($r) Show-EventFindings $r }
}

function ConvertTo-EventItems {
    # Constats -> littéral PowerShell attendu par Invoke-EventFix.
    param($Findings)
    $items = @($Findings | Where-Object { $_ -and $_.Fix } | ForEach-Object { '@{{K={0};F={1};S={2}}}' -f (ConvertTo-PsLiteral ([string]$_.Key)), (ConvertTo-PsLiteral ([string]$_.Fix)), (ConvertTo-PsLiteral ([string]$_.Sub)) })
    if ($items.Count -eq 0) { return '' }
    return '@(' + ($items -join ',') + ')'
}

# ---- Surveillance en direct
function Update-EventWatchUi {
    $e = $Script:Evt
    if (-not $e.WatchBtn) { return }
    if ($Script:EvtWatch) {
        $e.WatchBtn.Content = 'Arrêter la surveillance'
        $e.WatchBtn.Style = $Script:Window.FindResource('Btn')
        $e.WatchText.Text = ("Surveillance en cours depuis {0}  ·  vérification toutes les 5 secondes  ·  {1} nouvelle(s) erreur(s)" -f ([datetime]$Script:EvtWatch.Since).ToString('HH:mm'), $e.LiveCount)
        $e.WatchText.Foreground = (Br '#62D98B')
    } else {
        $e.WatchBtn.Content = 'Démarrer la surveillance'
        $e.WatchBtn.Style = $Script:Window.FindResource('BtnPrimary')
        $e.WatchText.Text = 'Surveillance arrêtée.'
        $e.WatchText.Foreground = (Br '#9298A3')
    }
}

function Start-EventWatch {
    if ($Script:EvtWatch -or $Script:EngineError) { return }
    $Script:Sync.EvtStop = $false
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $Script:Sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    # Le fil de surveillance n'a besoin que du moteur Événements ; il n'écrit rien à l'écran lui-même.
    [void]$ps.AddScript($Script:EvtCore + "`r`nfunction Write-Host { }`r`n`$Script:LogFile = `$Sync.LogFile`r`nWatch-Events -Every 5")
    $Script:EvtWatch = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Since = (Get-Date) }
    Add-Console 'Surveillance en direct de l''Observateur d''événements démarrée.' 'Cyan'
    Update-EventWatchUi
}

function Stop-EventWatch {
    $w = $Script:EvtWatch
    if (-not $w) { return }
    $Script:Sync.EvtStop = $true
    $Script:EvtWatch = $null
    try {
        if (-not $w.Handle.AsyncWaitHandle.WaitOne(1500)) { [void]$w.PS.BeginStop($null, $null) }
        else { $w.PS.Dispose(); $w.RS.Close(); $w.RS.Dispose() }
    } catch {}
    Update-EventWatchUi
}

function Add-LiveEvent {
    param($F)
    $e = $Script:Evt
    if (-not $e.LivePanel -or -not $F) { return }
    if ([string]$F.Kind -eq 'noise') { return }
    $e.LiveCount++
    $r = New-EventRow $F -Live
    $auto = ($e.AutoCheck.IsChecked -and [string]$F.Kind -eq 'fix' -and $F.Safe)
    if ($auto) {
        $k = [string]$F.Key + '>' + [string]$F.Fix
        if ($e.AutoDone.ContainsKey($k)) { [void]$r.Stack.Children.Add((New-Text 'Déjà réparé automatiquement dans cette session : pas de nouvelle tentative (voir le conseil).' 12.5 '#F5B94A' 'Normal' -Wrap)) }
        else {
            $e.AutoDone[$k] = (Get-Date)
            [void]$e.AutoPending.Add($F)
            [void]$r.Stack.Children.Add((New-Text 'Réparation automatique lancée.' 12.5 '#62D98B' 'Medium' -Wrap))
        }
    }
    if ($e.LiveEmpty) { $e.LiveEmpty.Visibility = 'Collapsed' }
    $e.LivePanel.Children.Insert(0, $r.Row)
    while ($e.LivePanel.Children.Count -gt 60) { $e.LivePanel.Children.RemoveAt($e.LivePanel.Children.Count - 1) }
    Add-Console (("  [!]   Nouvelle erreur Windows : {0}" -f $F.Title) + $(if ([string]$F.Kind -eq 'fix') { '  ->  ' + [string]$F.FixLabel } else { '' })) 'Yellow'
    Update-EventWatchUi
}

function Start-EventAutoFix {
    $e = $Script:Evt
    if ($Script:Run -or $e.AutoPending.Count -eq 0) { return }
    $lit = ConvertTo-EventItems @($e.AutoPending)
    $e.AutoPending.Clear()
    if (-not $lit) { return }
    Add-Console ''
    Add-Console '▶ Réparation automatique (surveillance en direct)' 'Cyan'
    Start-Run -Engine 'evt' -Code ('Invoke-EventFix -Live -Items ' + $lit) -Title 'Réparation des erreurs de Windows (automatique)' -Auto $Script:EvtAuto -AutoDefault 'no'
}

function Build-Events {
    $p = New-Page 'events' 'Réparation automatique' 'La Toolbox lit ce que Windows a noté dans l''Observateur d''événements, explique chaque erreur en clair, et lance la réparation adaptée quand il en existe une.'
    if ($Script:EngineError) {
        [void]$p.Children.Add((New-Text ("Moteur indisponible : " + $Script:EngineError) 13 '#FF7B7B' 'Normal' -Wrap))
        return
    }
    $e = $Script:Evt

    # ---- Analyse à la demande
    $c = New-Card 'Erreurs relevées par Windows' 'Journaux Système, Application, Defender et intégrité du code. La lecture ne modifie rien ; survolez une ligne pour lire le message d''origine.'
    $e.Period = New-Combo @(@('24 dernières heures', 'h24'), @('7 derniers jours', 'd7'), @('30 derniers jours', 'd30')) 190
    $e.Period.SelectedIndex = 1
    $bar = New-Object Windows.Controls.WrapPanel
    $bar.Margin = '0,14,0,0'
    [void]$bar.Children.Add((New-OptionPair 'Période' $e.Period))
    $an = New-Spec 'evt' '' 'Analyse des erreurs de Windows' @{} '' { param($r) Show-EventFindings $r }
    $an.CodeFn = { Get-EventAnalysisCode }
    $ab = New-Btn 'Analyser' $an -Primary; $ab.Margin = '0,4,0,4'
    [void]$bar.Children.Add($ab)
    $fx = New-Spec 'evt' '' 'Réparation des erreurs de Windows' $Script:EvtAuto '' { param($r) Start-EventAnalysis }
    $fx.AutoDefault = 'no'
    $fx.CodeFn = {
        $lit = ConvertTo-EventItems @($Script:Evt.Rows | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if (-not $lit) { return '' }
        return ('Invoke-EventFix -Items ' + $lit)
    }
    $fx.ConfirmFn = {
        $labels = @($Script:Evt.Rows | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag.FixLabel } | Sort-Object -Unique)
        "Lancer ces réparations ?`n`n  •  " + ($labels -join "`n  •  ") + "`n`nUn point de restauration est créé avant les réparations lourdes. La réparation des fichiers de Windows et l'analyse du disque peuvent durer plus de 20 minutes."
    }
    [void]$bar.Children.Add((New-Btn 'Réparer ce qui est coché' $fx -Primary))
    [void]$bar.Children.Add((New-Btn 'Tout cocher' @{ Fn = { foreach ($x in $Script:Evt.Rows) { $x.IsChecked = $true } } }))
    [void]$bar.Children.Add((New-Btn 'Tout décocher' @{ Fn = { foreach ($x in $Script:Evt.Rows) { $x.IsChecked = $false } } }))
    [void]$bar.Children.Add((New-Btn 'Ouvrir l''Observateur d''événements' @{ Fn = { try { Start-Process eventvwr.msc } catch {} } }))
    [void]$c.Body.Children.Add($bar)
    $e.Summary = New-Text 'Analyse en cours…' 13 '#9298A3' 'Medium' -Wrap
    $e.Summary.Margin = '0,12,0,0'
    [void]$c.Body.Children.Add($e.Summary)
    $e.Panel = New-Object Windows.Controls.StackPanel
    [void]$c.Body.Children.Add((New-ScrollList $e.Panel 560))
    [void]$p.Children.Add($c.Card)

    # ---- Surveillance en direct
    $l = New-Card 'Surveillance en direct' 'Tant que la Toolbox est ouverte, chaque nouvelle erreur de Windows apparaît ici en quelques secondes, avec son explication et sa réparation. Pratique pour reproduire une panne avec le client.' 'Temps réel' 'a'
    $lbar = New-Object Windows.Controls.StackPanel
    $lbar.Orientation = 'Horizontal'; $lbar.Margin = '0,14,0,0'
    $e.WatchBtn = New-Object Windows.Controls.Button
    $e.WatchBtn.Margin = '0,0,14,0'
    $e.WatchBtn.Add_Click({ try { if ($Script:EvtWatch) { Stop-EventWatch } else { Start-EventWatch } } catch { Write-Crash $_.Exception.ToString(); Add-Console ('  [X]   ' + $_.Exception.Message) 'Red' } })
    [void]$lbar.Children.Add($e.WatchBtn)
    $e.WatchText = New-Text '' 13 '#9298A3' 'Medium' -Wrap
    $e.WatchText.VerticalAlignment = 'Center'
    [void]$lbar.Children.Add($e.WatchText)
    [void]$l.Body.Children.Add($lbar)
    $e.AutoCheck = New-Check 'Réparer tout de suite, sans demander, quand la réparation est sans risque' $false
    $e.AutoCheck.Margin = '0,12,0,0'; $e.AutoCheck.FontSize = 14
    [void]$l.Body.Children.Add($e.AutoCheck)
    $hint = New-Text 'Sans risque : cache DNS, horloge, service arrêté, audio, compteurs de performance, caches graphiques. Les réparations lourdes (fichiers de Windows, disque, Windows Update, index de recherche) ne partent jamais seules : elles sont proposées, à vous de les lancer depuis la carte du dessus. Une même erreur n''est réparée automatiquement qu''une fois par session.' 12.5 '#9298A3' 'Normal' -Wrap
    $hint.Margin = '0,6,0,0'
    [void]$l.Body.Children.Add($hint)
    $e.LiveEmpty = New-Text 'Aucune nouvelle erreur pour l''instant.' 13 '#7A808B'
    $e.LiveEmpty.Margin = '0,12,0,0'
    [void]$l.Body.Children.Add($e.LiveEmpty)
    $e.LivePanel = New-Object Windows.Controls.StackPanel
    [void]$l.Body.Children.Add((New-ScrollList $e.LivePanel 320))
    [void]$p.Children.Add($l.Card)
    Update-EventWatchUi

    # ---- Ce que la page fait, et ne fait pas
    $k = New-Card 'Ce que cette page répare, et ce qu''elle ne peut pas réparer'
    foreach ($line in @(
            'Réparé par la Toolbox : services arrêtés, DNS, horloge, échecs répétés de Windows Update, fichiers de Windows abîmés (écrans bleus, composants de Windows qui plantent), erreurs de disque (analyse), index de recherche, Microsoft Store, compteurs de performance, plantages du pilote graphique (caches).',
            'Pas réparable par un logiciel : les pannes matérielles (erreurs WHEA, arrêts brutaux, disque qui répond mal, surchauffe) et les logiciels tiers qui plantent. La page dit alors précisément quoi vérifier.',
            'Erreurs non reconnues : affichées telles quelles, jamais « corrigées » au hasard. Les messages connus comme sans conséquence (DCOM 10016, par exemple) sont rangés à part.',
            'Windows ne retire pas les anciennes erreurs de son journal. Après une réparation, la page retient la date et indique à l''analyse suivante si l''erreur est revenue ou non.')) {
        $t = New-Text ('•  ' + $line) 13 '#C5C9D0' 'Normal' -Wrap
        $t.Margin = '0,8,0,0'
        [void]$k.Body.Children.Add($t)
    }
    [void]$p.Children.Add($k.Card)
}

#endregion
# ================================================================ SAUVEGARDE DES FICHIERS DU CLIENT
#region Sauvegarde

$Script:Bak = @{ Filled = $false; Profiles = @(); Folders = @() }   # contrôles et données de la page
$Script:BakStatus = $null     # dernier état rendu par Get-BackupStatus
$Script:BakPending = $false   # actualisation demandée pendant qu'une autre opération tournait
$Script:BakDays = @(@('lundi', 'Monday'), @('mardi', 'Tuesday'), @('mercredi', 'Wednesday'), @('jeudi', 'Thursday'), @('vendredi', 'Friday'), @('samedi', 'Saturday'), @('dimanche', 'Sunday'))

function ConvertTo-PsLiteral {
    # Texte sûr à placer dans le code envoyé au moteur. PowerShell accepte aussi les apostrophes typographiques
    # comme délimiteurs : on les double toutes.
    param([string]$Text)
    return "'" + ($Text -replace "(['\u2018\u2019\u201A\u201B])", '$1$1') + "'"
}

function Get-BakDestination {
    # Un disque choisi dans la liste (« E:\   Nom   ·   … ») ou un chemin tapé à la main.
    $t = ([string]$Script:Bak.Dest.Text).Trim()
    if ($t -match '^([A-Za-z]:\\)\s{3}') { return $Matches[1] }
    return $t.Trim('"')
}

function Select-ComboTag {
    param($Combo, [string]$Tag)
    foreach ($it in $Combo.Items) { if ([string]$it.Tag -eq $Tag) { $Combo.SelectedItem = $it; return $true } }
    return $false
}

function Update-BackupFolderHints {
    # Affiche, pour l'utilisateur choisi, l'emplacement réel de chaque dossier (info-bulle) et grise ceux qui n'existent pas.
    $it = $Script:Bak.Profile.SelectedItem
    if (-not $it) { return }
    $prof = $Script:Bak.Profiles[[int]$it.Tag]
    foreach ($cb in $Script:Bak.Folders) {
        $f = @($prof.Folders | Where-Object { [string]$_.Id -eq [string]$cb.Tag }) | Select-Object -First 1
        if (-not $f) { continue }
        $cb.ToolTip = [string]$f.Path
        $cb.Opacity = $(if ($f.Exists) { 1.0 } else { 0.5 })
    }
}

function Update-BackupForm {
    param($Res)
    $b = $Script:Bak
    $cfg = $Res.Config
    $first = (-not $b.Filled)

    # Utilisateurs
    $keep = ''
    if ($b.Profile.SelectedItem) { $keep = [string]$b.Profiles[[int]$b.Profile.SelectedItem.Tag].Path }
    if ($first -and $cfg) { $keep = [string]$cfg.Profile }
    $b.Profiles = @($Res.Profiles)
    $b.Profile.Items.Clear()
    $i = 0; $sel = 0
    foreach ($pr in $b.Profiles) {
        $ci = New-Object Windows.Controls.ComboBoxItem
        $ci.Content = [string]$pr.Name + $(if ($pr.Current) { '   (session ouverte)' } else { '' })
        $ci.Tag = $i
        [void]$b.Profile.Items.Add($ci)
        if ($keep -and ([string]$pr.Path -ieq $keep)) { $sel = $i }
        $i++
    }
    if ($b.Profile.Items.Count -gt 0) { $b.Profile.SelectedIndex = $sel }

    # Disques de destination
    $typed = [string]$b.Dest.Text
    if ($first -and $cfg) { $typed = [string]$cfg.DestRoot }
    $b.Dest.Items.Clear()
    $match = ''
    foreach ($d in @($Res.Drives)) {
        $line = ('{0}   {1}   ·   {2}   ·   {3:N0} Go libres' -f $d.Root, $(if ($d.Label) { $d.Label } else { 'sans nom' }), $d.Kind, ($d.Free / 1GB))
        [void]$b.Dest.Items.Add($line)
        if ($typed -and ($typed.TrimEnd('\') -ieq ([string]$d.Root).TrimEnd('\'))) { $match = $line }
    }
    $b.Dest.Text = $(if ($match) { $match } else { $typed })

    # Première ouverture : on reprend la configuration enregistrée
    if ($first -and $cfg) {
        $ids = @(@($cfg.Sources) | ForEach-Object { [string]$_.Id })
        foreach ($cb in $b.Folders) { $cb.IsChecked = ($ids -contains [string]$cb.Tag) }
        $b.Browsers.IsChecked = [bool]$cfg.Browsers
        [void](Select-ComboTag $b.Freq ([string]$cfg.Frequency))
        [void](Select-ComboTag $b.Day ([string]$cfg.Day))
        if (-not (Select-ComboTag $b.Time ([string]$cfg.Time))) {
            $ci = New-Object Windows.Controls.ComboBoxItem
            $ci.Content = [string]$cfg.Time; $ci.Tag = [string]$cfg.Time
            [void]$b.Time.Items.Add($ci); $b.Time.SelectedItem = $ci
        }
        $b.Auto.IsChecked = [bool]$Res.Auto
    }
    $b.Filled = $true
    Update-BackupFolderHints
}

function Show-BackupStatus {
    param($Res)
    if (-not $Res -or -not $Script:Bak.StatusPanel) { return }
    $Script:BakStatus = $Res
    $pn = $Script:Bak.StatusPanel
    $pn.Children.Clear()
    function Line { param([string]$Label, [string]$Value, [string]$Color = '#ECEDEF')
        $g = New-Object Windows.Controls.Grid
        $g.Margin = '0,6,0,0'
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(190)
        $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::new(1, 'Star')
        [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
        $l = New-Text $Label 13 '#9298A3'
        $v = New-Text $Value 14 $Color 'Medium' -Wrap
        [Windows.Controls.Grid]::SetColumn($v, 1)
        [void]$g.Children.Add($l); [void]$g.Children.Add($v)
        [void]$pn.Children.Add($g)
    }
    $cfg = $Res.Config; $st = $Res.State
    # Tant que rien n'est configuré, un seul bouton d'action sur la page : celui de la carte « Configurer ».
    if ($Script:Bak.StatusBar) { $Script:Bak.StatusBar.Visibility = $(if ($Res.Configured) { 'Visible' } else { 'Collapsed' }) }
    if (-not $Res.Configured) {
        [void]$pn.Children.Add((New-Text 'Aucune sauvegarde n''est configurée sur ce PC. Faites les trois choix ci-dessous, puis cliquez sur « Enregistrer et sauvegarder maintenant ».' 14 '#F5B94A' 'Normal' -Wrap))
    } else {
        $last = ''; $days = $null
        if ($st -and $st.LastSuccess) { try { $d = [datetime]$st.LastSuccess; $last = $d.ToString('dd/MM/yyyy à HH:mm'); $days = [int][math]::Floor(((Get-Date) - $d).TotalDays) } catch {} }
        if ($last) {
            $age = if ($days -le 0) { 'aujourd''hui' } elseif ($days -eq 1) { 'hier' } else { "il y a $days jours" }
            Line 'Dernière sauvegarde' ("{0}  ·  {1}" -f $last, $age) $(if ($days -le 7) { '#62D98B' } else { '#F5B94A' })
        } else { Line 'Dernière sauvegarde' 'Aucune pour l''instant' '#F5B94A' }
        if ($st -and [string]$st.Result -notin 'ok', '' -and $st.Message) { Line 'Dernier essai' ([string]$st.Message) $(if ([string]$st.Result -eq 'partiel') { '#F5B94A' } else { '#FF7B7B' }) }
        $what = @(@($cfg.Sources) | ForEach-Object { [string]$_.Label })
        if ($cfg.Browsers) { $what += 'favoris des navigateurs' }
        Line 'Contenu' ("{0}  ·  {1}" -f [string]$cfg.User, ($what -join ', '))
        if ($Res.DestPresent) { Line 'Destination' ([string]$Res.Folder) }
        else { Line 'Destination' ("{0}  ·  disque absent : branchez-le" -f [string]$cfg.DestRoot) '#F5B94A' }
        if ($Res.Auto) {
            $dayFr = [string](@($Script:BakDays | Where-Object { $_[1] -eq [string]$cfg.Day }) | ForEach-Object { $_[0] } | Select-Object -First 1)
            $when = if ([string]$cfg.Frequency -eq 'weekly') { "chaque $dayFr à $($cfg.Time)" } else { "chaque jour à $($cfg.Time)" }
            $next = ''
            if ($Res.NextRun) { try { $next = '  ·  prochaine : ' + ([datetime]$Res.NextRun).ToString('dd/MM à HH:mm') } catch {} }
            Line 'Sauvegarde automatique' ("Activée  ·  {0}{1}" -f $when, $next) '#62D98B'
        } else { Line 'Sauvegarde automatique' 'Désactivée' '#F5B94A' }
    }
    try { Update-BackupForm $Res } catch { Write-Crash ("Sauvegarde (formulaire) : " + $_.Exception.ToString()) }
}

function Refresh-BackupStatus {
    if ($Script:EngineError) { return }
    if ($Script:Run) { $Script:BakPending = $true; return }
    $Script:BakPending = $false
    Start-Run -Engine 'bak' -Code 'Get-BackupStatus' -Title '' -OnDone { param($res) Show-BackupStatus $res }
}

function Get-BakConfigCode {
    # Code « Set-BackupConfig … » correspondant aux choix de la page, ou '' s'il manque quelque chose.
    $b = $Script:Bak
    $pi = $b.Profile.SelectedItem
    if (-not $pi) { Add-Console 'Sauvegarde : choisissez un utilisateur (cliquez sur Actualiser si la liste est vide).' 'Yellow'; return '' }
    $prof = $b.Profiles[[int]$pi.Tag]
    $ids = @($b.Folders | Where-Object { $_.IsChecked } | ForEach-Object { "'" + ([string]$_.Tag -replace '[^A-Za-z]', '') + "'" })
    $br = [bool]$b.Browsers.IsChecked
    if ($ids.Count -eq 0 -and -not $br) { Add-Console 'Sauvegarde : cochez au moins un dossier.' 'Yellow'; return '' }
    $dest = Get-BakDestination
    if (-not $dest) { Add-Console 'Sauvegarde : choisissez le disque ou le dossier de destination.' 'Yellow'; return '' }
    $freq = [string]$b.Freq.SelectedItem.Tag -replace '[^a-z]', ''
    $day = [string]$b.Day.SelectedItem.Tag -replace '[^A-Za-z]', ''
    $time = [string]$b.Time.SelectedItem.Tag -replace '[^0-9:]', ''
    return ('Set-BackupConfig -ProfilePath {0} -Sid {1} -Folders @({2}) -Browsers ${3} -Destination {4} -Frequency {5} -Time {6} -Day {7}' -f
        (ConvertTo-PsLiteral ([string]$prof.Path)), (ConvertTo-PsLiteral ([string]$prof.Sid)), ($ids -join ','), $br.ToString().ToLower(),
        (ConvertTo-PsLiteral $dest), $freq, (ConvertTo-PsLiteral $time), $day)
}

function Build-Backup {
    $p = New-Page 'files' 'Sauvegarde des fichiers' 'Une copie des dossiers personnels sur un autre disque, refaite automatiquement. Seuls les fichiers nouveaux ou modifiés sont copiés, et rien n''est jamais effacé dans la sauvegarde.'
    if ($Script:EngineError) {
        [void]$p.Children.Add((New-Text ("Moteur de sauvegarde indisponible : " + $Script:EngineError) 13 '#FF7B7B' 'Normal' -Wrap))
        return
    }
    $b = $Script:Bak
    $done = { param($r) Refresh-BackupStatus }

    # ---- État
    $s = New-Card 'Où en est la sauvegarde' '' '' 'n'
    $b.StatusPanel = New-Object Windows.Controls.StackPanel
    $b.StatusPanel.Margin = '0,8,0,0'
    [void]$b.StatusPanel.Children.Add((New-Text 'Lecture de l''état…' 13 '#9298A3'))
    [void]$s.Body.Children.Add($b.StatusPanel)
    $sbar = New-Object Windows.Controls.WrapPanel
    $sbar.Margin = '0,16,0,0'; $sbar.Visibility = 'Collapsed'
    $b.StatusBar = $sbar
    $now = New-Btn 'Sauvegarder maintenant' (New-Spec 'bak' 'Invoke-FileBackup' 'Sauvegarde des fichiers' @{} '' $done) -Primary
    $now.Margin = '0,4,0,4'
    [void]$sbar.Children.Add($now)
    [void]$sbar.Children.Add((New-Btn 'Ouvrir la sauvegarde' @{ Fn = {
                $f = ''; if ($Script:BakStatus) { $f = [string]$Script:BakStatus.Folder }
                if ($f -and (Test-Path -LiteralPath $f)) { try { Start-Process explorer.exe ('"' + $f + '"') } catch {} }
                else { Add-Console 'Aucune sauvegarde à ouvrir (pas encore faite, ou disque absent).' 'Yellow' }
            } }))
    [void]$sbar.Children.Add((New-Btn 'Récupérer les fichiers manquants' (New-Spec 'bak' 'Restore-FileBackup' 'Restauration des fichiers' @{} 'Recopier vers le PC les fichiers présents dans la sauvegarde mais absents du PC ? Aucun fichier existant ne sera remplacé.' $done)))
    [void]$sbar.Children.Add((New-Btn 'Arrêter la sauvegarde automatique' (New-Spec 'bak' 'Unregister-BackupTask' 'Sauvegarde automatique (arrêt)' @{} 'Arrêter la sauvegarde automatique ? Les fichiers déjà sauvegardés sont conservés.' $done)))
    [void]$sbar.Children.Add((New-Btn 'Actualiser' @{ Fn = { Refresh-BackupStatus } }))
    [void]$s.Body.Children.Add($sbar)
    [void]$p.Children.Add($s.Card)

    # ---- Configuration : trois choix, un bouton
    $c = New-Card 'Configurer la sauvegarde' 'Trois choix, puis un seul bouton. À refaire seulement pour changer quelque chose.'
    function Step { param([string]$Text) $t = New-Text $Text 14 '#5AD1FF' 'SemiBold'; $t.Margin = '0,18,0,4'; return $t }
    function Hint { param([string]$Text) $t = New-Text $Text 12.5 '#9298A3' 'Normal' -Wrap; $t.Margin = '0,6,0,0'; return $t }

    [void]$c.Body.Children.Add((Step '1 · Quoi sauvegarder'))
    $b.Profile = New-Object Windows.Controls.ComboBox
    $b.Profile.MinWidth = 300; $b.Profile.Padding = '8,4'; $b.Profile.VerticalAlignment = 'Center'
    $b.Profile.Add_SelectionChanged({ try { Update-BackupFolderHints } catch {} })
    [void]$c.Body.Children.Add((New-OptionPair 'Fichiers de' $b.Profile))
    $fw = New-Object Windows.Controls.WrapPanel
    $fw.Margin = '0,4,0,0'
    $defs = @()
    try { $defs = Import-Catalog 'BJMPC-Sauvegarde-Win11.ps1' 'BakFolders' } catch { Write-Crash ("Sauvegarde (dossiers) : " + $_.Exception.Message) }
    $b.Folders = @()
    foreach ($d in $defs) {
        $cb = New-Check ([string]$d.Label) ([bool]$d.Default)
        $cb.Tag = [string]$d.Id; $cb.Margin = '0,6,24,0'; $cb.FontSize = 14
        [void]$fw.Children.Add($cb)
        $b.Folders += $cb
    }
    [void]$c.Body.Children.Add($fw)
    $b.Browsers = New-Check 'Favoris des navigateurs (Chrome, Edge, Brave, Firefox…)' $true
    $b.Browsers.FontSize = 14
    [void]$c.Body.Children.Add($b.Browsers)
    [void]$c.Body.Children.Add((Hint 'Survolez un dossier pour voir son emplacement réel (il peut être dans OneDrive). Les mots de passe des navigateurs ne sont pas copiés : Windows les chiffre et ils ne serviraient à rien ailleurs.'))

    [void]$c.Body.Children.Add((Step '2 · Où'))
    $b.Dest = New-Object Windows.Controls.ComboBox
    $b.Dest.IsEditable = $true; $b.Dest.MinWidth = 520; $b.Dest.Padding = '8,4'; $b.Dest.Margin = '0,0,8,0'; $b.Dest.VerticalAlignment = 'Center'
    $drow = New-Object Windows.Controls.StackPanel
    $drow.Orientation = 'Horizontal'; $drow.Margin = '0,6,0,0'
    [void]$drow.Children.Add($b.Dest)
    $browse = New-Btn 'Parcourir…' @{ Fn = {
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = 'Dossier ou disque où ranger la sauvegarde'
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Script:Bak.Dest.Text = [string]$dlg.SelectedPath }
            } catch { Add-Console ('  [!]   ' + $_.Exception.Message) 'Yellow' }
        } }
    $browse.Margin = '0,0,0,0'
    [void]$drow.Children.Add($browse)
    [void]$drow.Children.Add((New-Btn 'Actualiser la liste' @{ Fn = { Refresh-BackupStatus } }))
    [void]$c.Body.Children.Add($drow)
    [void]$c.Body.Children.Add((Hint 'Choisissez un disque externe ou un second disque dans la liste, ou tapez un dossier ou un partage réseau (\\serveur\partage). La sauvegarde est rangée dans un dossier « BJMPC-Sauvegarde » ; le disque est reconnu même si sa lettre change.'))

    [void]$c.Body.Children.Add((Step '3 · Quand'))
    $b.Auto = New-Check 'Refaire cette sauvegarde automatiquement' $true
    $b.Auto.FontSize = 14
    [void]$c.Body.Children.Add($b.Auto)
    $b.Freq = New-Combo @(@('chaque jour', 'daily'), @('chaque semaine', 'weekly')) 170
    $b.Day = New-Combo $Script:BakDays 130
    $b.Day.IsEnabled = $false
    $b.Time = New-Combo @(@('08:00', '08:00'), @('10:00', '10:00'), @('12:30', '12:30'), @('14:00', '14:00'), @('16:00', '16:00'), @('18:00', '18:00'), @('20:00', '20:00'), @('22:00', '22:00')) 100
    $b.Time.SelectedIndex = 2
    $b.Freq.Add_SelectionChanged({ try { $Script:Bak.Day.IsEnabled = ([string]$Script:Bak.Freq.SelectedItem.Tag -eq 'weekly') } catch {} })
    $qrow = New-Object Windows.Controls.StackPanel
    $qrow.Orientation = 'Horizontal'; $qrow.Margin = '0,8,0,0'
    [void]$qrow.Children.Add($b.Freq)
    [void]$qrow.Children.Add($b.Day)
    $at = New-Text 'à' 13 '#C5C9D0'; $at.VerticalAlignment = 'Center'; $at.Margin = '0,0,12,0'
    [void]$qrow.Children.Add($at)
    [void]$qrow.Children.Add($b.Time)
    [void]$c.Body.Children.Add($qrow)
    [void]$c.Body.Children.Add((Hint 'Choisissez une heure où le PC est allumé. S''il est éteint à ce moment-là, la sauvegarde se lance au démarrage suivant. Si le disque n''est pas branché, elle est reportée et la page d''accueil le signale.'))

    $run = New-Spec 'bak' '' 'Sauvegarde des fichiers' @{} '' $done
    $run.CodeFn = {
        $cfg = Get-BakConfigCode
        if (-not $cfg) { return '' }
        $auto = $(if ($Script:Bak.Auto.IsChecked) { 'Register-BackupTask' } else { 'Unregister-BackupTask' })
        return ('if (' + $cfg + ') { ' + $auto + '; [void](Invoke-FileBackup) }')
    }
    $run.ConfirmFn = {
        $who = ''; try { $who = [string]$Script:Bak.Profiles[[int]$Script:Bak.Profile.SelectedItem.Tag].Name } catch {}
        $auto = $(if ($Script:Bak.Auto.IsChecked) { "`nElle sera ensuite refaite automatiquement." } else { "`nLa sauvegarde automatique ne sera pas activée." })
        "Sauvegarder les fichiers de {0} vers {1} ?`nLa première copie peut être longue : elle continue en arrière-plan, vous pouvez utiliser les autres pages.{2}" -f $who, (Get-BakDestination), $auto
    }
    $rb = New-Btn 'Enregistrer et sauvegarder maintenant' $run -Primary
    $rb.HorizontalAlignment = 'Left'; $rb.Margin = '0,20,0,0'
    [void]$c.Body.Children.Add($rb)
    [void]$p.Children.Add($c.Card)

    # ---- À savoir
    $k = New-Card 'Bon à savoir'
    foreach ($line in @(
            'Ce sont les fichiers personnels qui sont sauvegardés, pas Windows ni les logiciels : en cas de panne du disque, on réinstalle Windows puis on récupère les fichiers.',
            'Un fichier ouvert au moment de la sauvegarde (une boîte Outlook, par exemple) peut être sauté ; il est repris à la sauvegarde suivante.',
            'Un fichier supprimé du PC reste dans la sauvegarde. Pour récupérer un seul fichier : « Ouvrir la sauvegarde » et copiez-le.',
            'La sauvegarde automatique ne dépend pas de la Toolbox : elle est installée dans C:\Program Files\BJMPC\Sauvegarde. Journaux : C:\BJMPC-Logs\Sauvegarde.')) {
        $t = New-Text ('•  ' + $line) 13 '#C5C9D0' 'Normal' -Wrap
        $t.Margin = '0,8,0,0'
        [void]$k.Body.Children.Add($t)
    }
    [void]$p.Children.Add($k.Card)
}

#endregion
# ================================================================ RÉGLAGES WINDOWS ET LOGICIELS (pages issues des catalogues)
#region Catalogues

# Lit un catalogue (données pures) directement dans le fichier du moteur, sans l'exécuter.
function Import-Catalog {
    param([string]$File, [string]$Name)
    $path = Join-Path $Script:Root $File
    $tokens = $null; $errs = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
    $want = '$Script:' + $Name
    foreach ($s in $ast.EndBlock.Statements) {
        if ($s -is [Management.Automation.Language.AssignmentStatementAst] -and $s.Left.Extent.Text -eq $want) {
            return , @(& ([scriptblock]::Create($s.Right.Extent.Text)))
        }
    }
    throw "Catalogue $Name introuvable dans $File"
}

$Script:TweakCatalog = @()
$Script:AppCatalog = @()
$Script:CatalogError = $null
try {
    $Script:TweakCatalog = Import-Catalog 'BJMPC-Reglages-Win11.ps1' 'TweakCatalog'
    $Script:AppCatalog = Import-Catalog 'BJMPC-Outils-Win11.ps1' 'AppCatalog'
} catch {
    $Script:CatalogError = $_.Exception.Message
    Write-Crash ("Catalogues : " + $_.Exception.ToString())
}

$Script:TweakChecks = @{}   # groupe -> liste de cases à cocher

function New-TweakCheck {
    # Une case à cocher riche : libellé, étiquettes (prudence, redémarrage) et description.
    param($T)
    $cb = New-Object Windows.Controls.CheckBox
    $cb.IsChecked = [bool]$T.Default
    $cb.Margin = '0,10,0,0'
    $cb.Tag = [string]$T.Id
    $sp = New-Object Windows.Controls.StackPanel
    $line = New-Object Windows.Controls.StackPanel
    $line.Orientation = 'Horizontal'
    [void]$line.Children.Add((New-Text ([string]$T.Label) 14 '#ECEDEF' 'Medium'))
    if ($T.Risk -eq 'warn') { [void]$line.Children.Add((New-Tag 'À savoir' 'w')) }
    if ($T.Reboot) { [void]$line.Children.Add((New-Tag 'Redémarrage' 'n')) }
    [void]$sp.Children.Add($line)
    if ($T.Desc) { [void]$sp.Children.Add((New-Text ([string]$T.Desc) 13 '#9298A3' 'Normal' -Wrap)) }
    $cb.Content = $sp
    return $cb
}

function New-TweakCard {
    # Une carte par groupe du catalogue. Le bouton applique uniquement les cases cochées.
    param($Body, [string]$Group, [string]$Sub, [string]$ConfirmExtra = '')
    $items = @($Script:TweakCatalog | Where-Object { $_.Group -eq $Group })
    if ($items.Count -eq 0) { return $null }
    $card = New-Card $Group $Sub
    $checks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in $items) {
        $cb = New-TweakCheck $t
        [void]$card.Body.Children.Add($cb)
        [void]$checks.Add($cb)
    }
    $spec = New-Spec 'opt' '' ("Réglages : " + $Group) @{} '' $Script:AfterChange
    $spec.AutoDefault = 'no'
    $spec.CodeFn = {
        $ids = @($checks | Where-Object { $_.IsChecked } | ForEach-Object { "'" + ([string]$_.Tag -replace "[^A-Za-z0-9_]", '') + "'" })
        if ($ids.Count -eq 0) { return '' }
        return ('Set-Tweaks -Ids @(' + ($ids -join ',') + ')')
    }.GetNewClosure()
    $spec.ConfirmFn = {
        $n = @($checks | Where-Object { $_.IsChecked }).Count
        return ("Appliquer {0} réglage(s) ? Chaque valeur d'origine est enregistrée : tout s'annule depuis l'onglet Restauration." -f $n)
    }.GetNewClosure()
    $bar = New-Object Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.Margin = '0,16,0,0'
    $b = New-Btn 'Appliquer les réglages cochés' $spec -Primary; $b.Margin = '0,0,0,0'
    [void]$bar.Children.Add($b)
    $all = New-Btn 'Tout cocher' @{ Fn = { foreach ($c in $checks) { $c.IsChecked = $true } }.GetNewClosure() }
    $none = New-Btn 'Tout décocher' @{ Fn = { foreach ($c in $checks) { $c.IsChecked = $false } }.GetNewClosure() }
    [void]$bar.Children.Add($all); [void]$bar.Children.Add($none)
    [void]$card.Body.Children.Add($bar)
    [void]$Body.Children.Add($card.Card)
    return $card
}

function Build-TweakPage {
    param([string]$Key, [string]$Title, [string]$Sub, $Groups)
    $p = New-Page $Key $Title $Sub
    if ($Script:CatalogError) {
        [void]$p.Children.Add((New-Text ("Catalogue illisible : " + $Script:CatalogError) 13 '#FF7B7B' 'Normal' -Wrap))
        return
    }
    foreach ($g in $Groups) { [void](New-TweakCard $p $g.Name $g.Sub) }
}

function Build-Privacy {
    Build-TweakPage 'priv' 'Confidentialité et télémétrie' 'Réduit la collecte de données de Windows et des logiciels tiers. Les cases déjà cochées sont les réglages recommandés ; rien n''est appliqué avant que vous cliquiez.' @(
        @{ Name = 'Télémétrie et diagnostics'; Sub = 'Données envoyées à Microsoft. Windows reste pleinement fonctionnel.' },
        @{ Name = 'Publicités, recherche et suggestions'; Sub = 'Suggestions du menu Démarrage, publicités dans Windows, recherche web.' },
        @{ Name = 'IA et Copilot'; Sub = 'Copilot, Recall et les fonctions d''IA de Windows.' },
        @{ Name = 'Navigateurs et logiciels tiers'; Sub = 'Collecte de données d''Edge, Brave, Office, NVIDIA, Visual Studio… Les réglages d''un logiciel absent sont ignorés.' },
        @{ Name = 'Autorisations des applications'; Sub = 'Retire l''accès par défaut des applications à la caméra, au micro, aux contacts, etc.' })
}

function Build-Interface {
    Build-TweakPage 'ui' 'Interface et Explorateur' 'Confort d''utilisation de Windows 11. Tous ces réglages sont réversibles depuis le Journal.' @(
        @{ Name = 'Interface et Explorateur'; Sub = 'Menu contextuel, barre des tâches, fichiers cachés, démarrage, notifications…' })
}

function Build-WinSettings {
    Build-TweakPage 'winset' 'Mises à jour et sécurité' 'Windows Update, sécurité et fonctionnalités facultatives.' @(
        @{ Name = 'Mises à jour Windows'; Sub = 'Les mises à jour de sécurité restent installées.' },
        @{ Name = 'Sécurité'; Sub = 'Réglages à lire avant de cocher : certains retirent une protection ou en ajoutent une.' },
        @{ Name = 'Fonctionnalités Windows facultatives'; Sub = 'Composants anciens rarement utiles. Désactivation réversible depuis le Journal.' })
}

#endregion

# ================================================================ LOGICIELS
#region Logiciels

$Script:AppChecks = New-Object 'System.Collections.Generic.List[object]'
$Script:AppGroups = New-Object 'System.Collections.Generic.List[object]'
$Script:AppCountText = $null
$Script:BloatPanel = $null
$Script:BloatChecks = New-Object 'System.Collections.Generic.List[object]'

function Update-AppCount {
    if (-not $Script:AppCountText) { return }
    $n = @($Script:AppChecks | Where-Object { $_.IsChecked }).Count
    $Script:AppCountText.Text = $(if ($n -eq 0) { 'Aucune application sélectionnée' } elseif ($n -eq 1) { '1 application sélectionnée' } else { "$n applications sélectionnées" })
}

function Update-AppFilter {
    param([string]$Text)
    $q = $Text.Trim()
    foreach ($g in $Script:AppGroups) {
        $any = $false
        foreach ($cb in $g.Checks) {
            $show = ($q -eq '') -or ($cb.Tag.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($cb.Tag.Id.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($g.Category.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            $cb.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
            if ($show) { $any = $true }
        }
        $g.Panel.Visibility = $(if ($any) { 'Visible' } else { 'Collapsed' })
        if ($q -ne '' -and $any) { $g.Wrap.Visibility = 'Visible'; $g.Arrow.Text = '▾' }
        elseif ($q -eq '') { $g.Wrap.Visibility = 'Collapsed'; $g.Arrow.Text = '▸' }
    }
}

function Show-BloatList {
    param($Res)
    $Script:BloatPanel.Children.Clear()
    $Script:BloatChecks.Clear()
    $list = @($Res)
    if ($list.Count -eq 0) {
        [void]$Script:BloatPanel.Children.Add((New-Text 'Aucune application du catalogue n''est installée.' 13 '#9298A3'))
        return
    }
    $cats = [ordered]@{
        'inutile' = 'Rarement utiles (publicités, essais, services Microsoft peu utilisés)'
        'utile'   = 'Souvent utiles : décochées par défaut, à retirer seulement si vous êtes sûr'
        'tiers'   = 'Applications de partenaires installées par le constructeur ou Microsoft'
    }
    foreach ($k in $cats.Keys) {
        $sub = @($list | Where-Object { $_.Cat -eq $k })
        if ($sub.Count -eq 0) { continue }
        $h = New-Text $cats[$k] 13 '#C5C9D0' 'SemiBold' -Wrap
        $h.Margin = '0,14,0,0'
        [void]$Script:BloatPanel.Children.Add($h)
        foreach ($a in ($sub | Sort-Object Label)) {
            $cb = New-Check ("{0}   ({1})" -f $a.Label, $a.Name) ($k -ne 'utile')
            $cb.Tag = [string]$a.Name
            [void]$Script:BloatPanel.Children.Add($cb)
            [void]$Script:BloatChecks.Add($cb)
        }
    }
}

function Build-Apps {
    $p = New-Page 'apps' 'Logiciels et applications' 'Installez vos logiciels courants avec winget, retirez les applications préinstallées inutiles.'
    if ($Script:CatalogError) {
        [void]$p.Children.Add((New-Text ("Catalogue illisible : " + $Script:CatalogError) 13 '#FF7B7B' 'Normal' -Wrap))
        return
    }

    # --- Installation
    $c = New-Card 'Installer des logiciels (winget)' 'Cochez ce que vous voulez, puis installez. Les logiciels déjà présents sont ignorés. Si un identifiant ne répond plus, utilisez « Vérifier le catalogue ».' 'Nécessite winget' 'a'
    $search = New-Object Windows.Controls.TextBox
    $search.Margin = '0,14,0,0'; $search.Padding = '8,6'; $search.FontSize = 13
    $search.Background = (Br '#15171C'); $search.Foreground = (Br '#ECEDEF'); $search.BorderBrush = (Br '#2A2E36'); $search.CaretBrush = (Br '#ECEDEF')
    $search.ToolTip = 'Filtrer le catalogue par nom, identifiant ou catégorie'
    [void]$c.Body.Children.Add((New-Text 'Filtrer le catalogue' 12 '#9298A3'))
    [void]$c.Body.Children.Add($search)
    $Script:AppCountText = New-Text 'Aucune application sélectionnée' 13 '#5AD1FF' 'Medium'
    $Script:AppCountText.Margin = '0,12,0,0'
    [void]$c.Body.Children.Add($Script:AppCountText)

    $cats = @($Script:AppCatalog | ForEach-Object { [string]$_[0] } | Select-Object -Unique)
    foreach ($cat in $cats) {
        $rows = @($Script:AppCatalog | Where-Object { [string]$_[0] -eq $cat })
        $head = New-Object Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'; $head.Margin = '0,14,0,0'; $head.Cursor = [Windows.Input.Cursors]::Hand
        $arrow = New-Text '▸' 14 '#9298A3'
        $arrow.Width = 16
        [void]$head.Children.Add($arrow)
        [void]$head.Children.Add((New-Text ("{0}  ({1})" -f $cat, $rows.Count) 14 '#ECEDEF' 'SemiBold'))
        $wrap = New-Object Windows.Controls.WrapPanel
        $wrap.Margin = '16,4,0,0'; $wrap.Visibility = 'Collapsed'
        $g = [pscustomobject]@{ Category = $cat; Panel = $null; Wrap = $wrap; Arrow = $arrow; Checks = (New-Object 'System.Collections.Generic.List[object]') }
        foreach ($r in $rows) {
            $id = [string]$r[2]
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') { continue }
            $cb = New-Check ([string]$r[1]) $false
            $cb.Width = 300
            $cb.ToolTip = $id
            $cb.Tag = [pscustomobject]@{ Name = [string]$r[1]; Id = $id }
            $cb.Add_Click({ Update-AppCount })
            [void]$wrap.Children.Add($cb)
            [void]$g.Checks.Add($cb)
            [void]$Script:AppChecks.Add($cb)
        }
        $holder = New-Object Windows.Controls.StackPanel
        [void]$holder.Children.Add($head)
        [void]$holder.Children.Add($wrap)
        $g.Panel = $holder
        $head.Tag = $g
        $head.Add_MouseLeftButtonUp({
            param($s, $e)
            $gg = $s.Tag
            if ($gg.Wrap.Visibility -eq 'Visible') { $gg.Wrap.Visibility = 'Collapsed'; $gg.Arrow.Text = '▸' } else { $gg.Wrap.Visibility = 'Visible'; $gg.Arrow.Text = '▾' }
        })
        [void]$Script:AppGroups.Add($g)
        [void]$c.Body.Children.Add($holder)
    }
    $search.Add_TextChanged({ param($s, $e) try { Update-AppFilter $s.Text } catch { Write-Crash $_.Exception.ToString() } })

    $inst = New-Spec 'tools' '' 'Installation des applications' @{} '' $null
    $inst.CodeFn = {
        $ids = @($Script:AppChecks | Where-Object { $_.IsChecked } | ForEach-Object { "'" + $_.Tag.Id + "'" })
        if ($ids.Count -eq 0) { return '' }
        return ('Install-WingetApps -Ids @(' + ($ids -join ',') + ')')
    }
    $inst.ConfirmFn = { "Installer {0} application(s) avec winget ? L'opération peut durer plusieurs minutes." -f @($Script:AppChecks | Where-Object { $_.IsChecked }).Count }
    $bar = New-Object Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.Margin = '0,18,0,0'
    $bi = New-Btn 'Installer la sélection' $inst -Primary; $bi.Margin = '0,0,0,0'
    [void]$bar.Children.Add($bi)
    [void]$bar.Children.Add((New-Btn 'Tout décocher' @{ Fn = { foreach ($x in $Script:AppChecks) { $x.IsChecked = $false }; Update-AppCount } }))
    [void]$bar.Children.Add((New-Btn 'Vérifier le catalogue' (New-Spec 'tools' 'Test-WingetCatalog' 'Vérification des identifiants' @{} 'Vérifier chaque identifiant du catalogue avec winget ? Cela prend plusieurs minutes et ne modifie rien.')))
    [void]$c.Body.Children.Add($bar)
    [void]$p.Children.Add($c.Card)

    # --- Recherche libre
    $f = New-Card 'Un autre logiciel' 'Recherchez dans winget, puis installez par identifiant exact (par exemple Mozilla.Firefox).'
    $q = New-Object Windows.Controls.TextBox
    $q.Margin = '0,14,0,0'; $q.Padding = '8,6'; $q.FontSize = 13; $q.MaxLength = 60
    $q.Background = (Br '#15171C'); $q.Foreground = (Br '#ECEDEF'); $q.BorderBrush = (Br '#2A2E36'); $q.CaretBrush = (Br '#ECEDEF')
    [void]$f.Body.Children.Add($q)
    $ss = New-Spec 'tools' '' 'Recherche winget'
    $ss.CodeFn = {
        $t = $q.Text.Trim()
        if ($t -notmatch '^[\w .+\-]{2,60}$') { Add-Console 'Saisissez 2 à 60 caractères : lettres, chiffres, espaces, points, plus ou tirets.' 'Yellow'; return '' }
        return ("Search-WingetApp -Query '" + ($t -replace "(['\u2018\u2019\u201A\u201B])", '$1$1') + "'")
    }.GetNewClosure()
    $is = New-Spec 'tools' '' 'Installation par identifiant'
    $is.CodeFn = {
        $t = $q.Text.Trim()
        if ($t -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') { Add-Console 'Identifiant invalide : il ne contient ni espace ni caractère spécial (exemple : Mozilla.Firefox).' 'Yellow'; return '' }
        return ("Install-WingetApps -Ids @('" + $t + "')")
    }.GetNewClosure()
    $is.ConfirmFn = { "Installer « {0} » avec winget ?" -f $q.Text.Trim() }.GetNewClosure()
    $fb = New-Object Windows.Controls.StackPanel
    $fb.Orientation = 'Horizontal'; $fb.Margin = '0,12,0,0'
    $b1 = New-Btn 'Rechercher' $ss -Primary; $b1.Margin = '0,0,0,0'
    [void]$fb.Children.Add($b1)
    [void]$fb.Children.Add((New-Btn 'Installer cet identifiant' $is))
    [void]$f.Body.Children.Add($fb)
    [void]$p.Children.Add($f.Card)

    # --- Mises à jour et inventaire
    $wu = New-Card 'Mises à jour et inventaire' 'Applications installées : mises à jour disponibles (winget) et inventaire pour un dossier client.'
    Add-Row $wu.Body 'Applications à mettre à jour (winget)' 'Liste seulement. Nécessite winget (Programme d''installation d''application).' '' 'n' @(
        (New-Btn 'Rechercher' (New-Spec 'tools' 'Get-WingetUpdates' 'Applications à mettre à jour')),
        (New-Btn 'Tout mettre à jour' (New-Spec 'tools' 'Update-WingetApps' 'Mise à jour des applications' @{} 'Mettre à jour toutes les applications installées avec winget ? Certaines seront fermées et relancées.')))
    Add-Row $wu.Body 'Inventaire des logiciels installés' 'Fichier CSV (nom, version, éditeur) enregistré dans C:\BJMPC-Logs\Rapports.' '' 'n' @((New-Btn 'Exporter' (New-Spec 'tools' 'Export-InstalledSoftware' 'Inventaire des logiciels')))
    [void]$p.Children.Add($wu.Card)

    # --- Applications préinstallées
    $b = New-Card 'Applications préinstallées' 'Analyse les applications du Store présentes sur ce PC. Les composants dont Windows dépend (Store, Photos, Calculatrice, Terminal, Defender, codecs…) sont protégés et jamais proposés.' 'Non annulable par le Journal' 'w'
    $Script:BloatPanel = New-Object Windows.Controls.StackPanel
    [void]$b.Body.Children.Add($Script:BloatPanel)
    $an = New-Spec 'tools' 'Get-BloatApps' 'Analyse des applications préinstallées' @{} '' { param($r) Show-BloatList $r }
    $rm = New-Spec 'tools' '' 'Désinstallation des applications'
    $rm.CodeFn = {
        $n = @($Script:BloatChecks | Where-Object { $_.IsChecked } | ForEach-Object { "'" + ([string]$_.Tag -replace "[^A-Za-z0-9._\-]", '') + "'" })
        if ($n.Count -eq 0) { return '' }
        return ('Remove-AppxApps -Names @(' + ($n -join ',') + ')')
    }
    $rm.ConfirmFn = { "Désinstaller {0} application(s) pour tous les comptes ? Le Journal ne peut pas les restaurer, mais vous pourrez les réinstaller depuis le Microsoft Store." -f @($Script:BloatChecks | Where-Object { $_.IsChecked }).Count }
    $rm.OnDone = { param($r) $Script:BloatPanel.Children.Clear(); $Script:BloatChecks.Clear(); [void]$Script:BloatPanel.Children.Add((New-Text 'Terminé. Relancez l''analyse pour actualiser la liste.' 13 '#9298A3')) }
    $bb = New-Object Windows.Controls.StackPanel
    $bb.Orientation = 'Horizontal'; $bb.Margin = '0,16,0,0'
    $ba = New-Btn 'Analyser' $an -Primary; $ba.Margin = '0,0,0,0'
    [void]$bb.Children.Add($ba)
    [void]$bb.Children.Add((New-Btn 'Désinstaller la sélection' $rm))
    [void]$b.Body.Children.Add($bb)
    Add-Row $b.Body 'OneDrive' 'Désinstalle le client sans toucher à vos fichiers. Refusé automatiquement si Bureau, Documents ou Images sont enregistrés dans OneDrive.' '' 'n' @((New-Btn 'Désinstaller' (New-Spec 'tools' 'Uninstall-OneDrive' 'Désinstallation de OneDrive' @{} 'Désinstaller le client OneDrive ? Vos fichiers ne sont pas supprimés.')))
    [void]$p.Children.Add($b.Card)
}

# ================================================================ PILOTES
# Page en cinq onglets : Mises à jour (Catalog Microsoft) · Pilotes installés (magasin, comme DriverStore Explorer) ·
# Ajouter un pilote · Appareils absents · Sauvegardes. Tous les tableaux sont des lignes à colonnes proportionnelles.
$Script:UpChecks = New-Object 'System.Collections.Generic.List[object]'
$Script:DrvChecks = New-Object 'System.Collections.Generic.List[object]'
$Script:DrvRows = New-Object 'System.Collections.Generic.List[object]'
$Script:DrvInfo = @{}
$Script:GhostChecks = New-Object 'System.Collections.Generic.List[object]'
$Script:DrvTabs = @{}
$Script:UpCols = @(3.2, 1.1, 1.5, 1.7, 1.0, 0.8, 1.0)
$Script:StoreCols = @(1.2, 1.8, 1.1, 2.4, 1.5, 1.0, 0.8, 1.5)
$Script:GhostCols = @(3.2, 1.2, 1.6, 1.2)

function New-Combo {
    # Liste déroulante à choix fixes (aucune saisie) : $Items = @(@('libellé', 'valeur'), …)
    param($Items, [double]$MinWidth = 260)
    $cb = New-Object Windows.Controls.ComboBox
    $cb.MinWidth = $MinWidth; $cb.Padding = '8,4'; $cb.Margin = '0,0,16,0'; $cb.VerticalAlignment = 'Center'
    foreach ($it in $Items) {
        $ci = New-Object Windows.Controls.ComboBoxItem
        $ci.Content = [string]$it[0]; $ci.Tag = [string]$it[1]
        [void]$cb.Items.Add($ci)
    }
    $cb.SelectedIndex = 0
    return $cb
}

function New-OptionPair {
    param([string]$Label, $Control)
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.Margin = '0,6,0,0'
    $t = New-Text $Label 13 '#C5C9D0' 'Normal'
    $t.VerticalAlignment = 'Center'; $t.Margin = '0,0,8,0'
    [void]$sp.Children.Add($t)
    [void]$sp.Children.Add($Control)
    return $sp
}

function Add-DeviceMenu {
    param($Element, [string]$DeviceId)
    if ($DeviceId -notmatch '^[A-Za-z0-9_\\&\.\-\{\}#]+$') { return }
    $cm = New-Object Windows.Controls.ContextMenu
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = 'Propriétés de l''appareil (Windows)'; $mi.Tag = $DeviceId
    $mi.Add_Click({ param($s, $e) try { Start-Process 'rundll32.exe' ('devmgr.dll,DeviceProperties_RunDLL /DeviceID "' + [string]$s.Tag + '"') } catch {} })
    [void]$cm.Items.Add($mi)
    $Element.ContextMenu = $cm
}

function New-TableRow {
    # Une ligne de tableau : 1re colonne = case à cocher (facultative), puis des colonnes proportionnelles.
    # Chaque cellule est un texte, ou @{ T = texte; C = couleur; W = graisse; Tip = info-bulle }.
    param([double[]]$Widths, $Cells, $Check = $null, [switch]$Header)
    $bd = New-Object Windows.Controls.Border
    $bd.Background = [Windows.Media.Brushes]::Transparent
    $bd.BorderBrush = (Br $(if ($Header) { '#2A2E36' } else { '#1A1D22' }))
    $bd.BorderThickness = '0,0,0,1'; $bd.Padding = '0,6'
    $g = New-Object Windows.Controls.Grid
    $c0 = New-Object Windows.Controls.ColumnDefinition
    $c0.Width = [Windows.GridLength]::new(30)
    [void]$g.ColumnDefinitions.Add($c0)
    foreach ($w in $Widths) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = [Windows.GridLength]::new($w, 'Star')
        [void]$g.ColumnDefinitions.Add($cd)
    }
    if ($Check) {
        $Check.VerticalAlignment = 'Center'; $Check.Margin = '6,0,0,0'
        [Windows.Controls.Grid]::SetColumn($Check, 0)
        [void]$g.Children.Add($Check)
    }
    $col = 1
    foreach ($cell in @($Cells)) {
        $txt = ''; $clr = '#C5C9D0'; $wt = 'Normal'; $tip = ''
        if ($cell -is [hashtable]) {
            $txt = [string]$cell.T
            if ($cell.C) { $clr = [string]$cell.C }
            if ($cell.W) { $wt = [string]$cell.W }
            if ($cell.Tip) { $tip = [string]$cell.Tip }
        } else { $txt = [string]$cell }
        $sz = 13; if ($Header) { $clr = '#9298A3'; $wt = 'SemiBold'; $sz = 12 }
        $t = New-Text $txt $sz $clr $wt
        $t.TextTrimming = 'CharacterEllipsis'; $t.Margin = '0,0,10,0'; $t.VerticalAlignment = 'Center'
        if ($tip) { $t.ToolTip = $tip } elseif ($txt.Length -gt 16) { $t.ToolTip = $txt }
        [Windows.Controls.Grid]::SetColumn($t, $col)
        [void]$g.Children.Add($t)
        $col++
    }
    $bd.Child = $g
    return $bd
}

function New-ScrollList {
    # Liste défilante de hauteur limitée : les boutons restent visibles sans faire défiler toute la page.
    param($Panel, [double]$MaxHeight = 340)
    $sv = New-Object Windows.Controls.ScrollViewer
    $sv.MaxHeight = $MaxHeight; $sv.VerticalScrollBarVisibility = 'Auto'; $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.Margin = '0,0,0,0'; $sv.Content = $Panel
    $sv.Add_PreviewMouseWheel({
        param($s, $e)
        try {
            $atTop = ($s.VerticalOffset -le 0); $atBottom = ($s.VerticalOffset -ge $s.ScrollableHeight)
            if (($e.Delta -gt 0 -and $atTop) -or ($e.Delta -lt 0 -and $atBottom)) {
                $e.Handled = $true
                $ev = New-Object Windows.Input.MouseWheelEventArgs($e.MouseDevice, $e.Timestamp, $e.Delta)
                $ev.RoutedEvent = [Windows.UIElement]::MouseWheelEvent; $ev.Source = $s
                ([Windows.UIElement]$s.Parent).RaiseEvent($ev)
            }
        } catch {}
    })
    return $sv
}

function Show-DriverTab {
    param([string]$Key)
    foreach ($k in @($Script:DrvTabs.Keys)) {
        $t = $Script:DrvTabs[$k]
        $t.Panel.Visibility = $(if ($k -eq $Key) { 'Visible' } else { 'Collapsed' })
        $t.Button.Style = $Script:Window.FindResource($(if ($k -eq $Key) { 'BtnPrimary' } else { 'Btn' }))
    }
}

# ---------------------------------------------------------------- Onglet « Mises à jour »
function Set-UpChecks {
    param([bool]$Value)
    foreach ($cb in $Script:UpChecks) { if ($cb.IsEnabled) { $cb.IsChecked = $Value } }
}

function Show-UpdateResults {
    param($Res)
    $Script:UpPanel.Children.Clear(); $Script:UpChecks.Clear()
    $rows = @($Res | Where-Object { $_ })
    if ($rows.Count -eq 0) {
        $Script:UpSummary.Text = 'Aucun résultat : recherche interrompue ou aucun appareil à analyser avec ce choix.'
        return
    }
    $upd = @($rows | Where-Object { $_.Status -eq 'found' } | Sort-Object Level, Class, Name)
    $oth = @($rows | Where-Object { $_.Status -ne 'found' } | Sort-Object @{ Expression = { switch ([string]$_.State) { 'error' { 0 } 'none' { 1 } 'nomatch' { 1 } default { 2 } } } }, Name)
    $nCur = @($oth | Where-Object { $_.State -eq 'current' }).Count
    $nNone = @($oth | Where-Object { $_.State -eq 'none' -or $_.State -eq 'nomatch' }).Count
    $nErr = @($oth | Where-Object { $_.State -eq 'error' }).Count
    $s = ("{0} appareil(s) analysé(s) · {1} mise(s) à jour disponible(s) · {2} déjà à jour · {3} sans pilote trouvé" -f $rows.Count, $upd.Count, $nCur, $nNone)
    if ($nErr -gt 0) { $s += (" · {0} en erreur de connexion" -f $nErr) }
    $Script:UpSummary.Text = $s
    foreach ($r in $upd) {
        $ext = ([int]$r.Level -ge 2)
        $cb = New-Check '' (-not $ext)
        $cb.Tag = ([string]$r.Id + '|' + $(if ($r.Alts) { [string]$r.Alts } else { [string]$r.Guid }) + '|' + [string]$(if ($ext) { 2 } else { 1 }))
        $nameClr = '#ECEDEF'; if ($ext) { $nameClr = '#C9A227' }
        $cells = @(
            @{ T = [string]$r.Name; C = $nameClr; W = 'Medium'; Tip = ([string]$r.Title + "`nIdentifiant : " + [string]$r.HwId + $(if ($r.Note) { "`n" + [string]$r.Note } else { '' })) },
            [string]$r.Class,
            $(if ($r.Installed) { 'v' + [string]$r.Installed } else { 'aucun pilote' }),
            @{ T = ('v' + [string]$r.Version); C = '#7CE3A1'; W = 'SemiBold'; Tip = $(if ($r.Verified) { 'Paquet contrôlé : son INF déclare bien cet appareil' } else { 'Paquet volumineux : contrôlé au moment de l''installation' }) },
            [string]$r.Date,
            ('{0} Mo' -f $r.SizeMB),
            $(if ($ext) { @{ T = 'Élargie'; C = '#C9A227'; Tip = [string]$r.Note } } else { @{ T = 'Stricte'; C = '#7CE3A1' } })
        )
        $row = New-TableRow $Script:UpCols $cells $cb
        Add-DeviceMenu $row ([string]$r.Id)
        [void]$Script:UpPanel.Children.Add($row)
        [void]$Script:UpChecks.Add($cb)
    }
    foreach ($r in $oth) {
        $st = 'Introuvable'; $clr = '#9298A3'
        if ($r.State -eq 'current') { $st = 'À jour'; $clr = '#7CE3A1' }
        elseif ($r.State -eq 'error') { $st = 'Erreur'; $clr = '#FF8A80' }
        elseif ($r.State -eq 'nomatch') { $st = 'Aucun paquet adapté'; $clr = '#C9A227' }
        $cells = @(
            @{ T = [string]$r.Name; C = '#9298A3'; Tip = [string]$r.Note },
            @{ T = [string]$r.Class; C = '#9298A3' },
            @{ T = $(if ($r.Installed) { 'v' + [string]$r.Installed } else { 'aucun pilote' }); C = '#9298A3' },
            @{ T = $st; C = $clr; Tip = [string]$r.Note },
            '', '', ''
        )
        $row = New-TableRow $Script:UpCols $cells
        Add-DeviceMenu $row ([string]$r.Id)
        [void]$Script:UpPanel.Children.Add($row)
    }
}

# ---------------------------------------------------------------- Onglet « Pilotes installés » (magasin)
function Get-ShownDrivers {
    return @($Script:DrvRows | Where-Object { $_.Row.Visibility -eq 'Visible' })
}

function Update-DriverCount {
    $sel = @($Script:DrvRows | Where-Object { $_.Check.IsChecked -and $_.Row.Visibility -eq 'Visible' })
    $mb = 0.0; foreach ($x in $sel) { $mb += [double]$x.Info.SizeMB }
    $Script:DrvCountText.Text = $(if ($sel.Count -eq 0) { 'Aucun pilote sélectionné' } else { ("{0} pilote(s) sélectionné(s) · {1:N1} Mo à libérer" -f $sel.Count, $mb) })
}

function Set-DriverChecks {
    param([string]$Mode)
    foreach ($x in (Get-ShownDrivers)) {
        if (-not $x.Check.IsEnabled) { continue }
        switch ($Mode) {
            'old'  { $x.Check.IsChecked = [bool]$x.Info.Old }
            'none' { $x.Check.IsChecked = $false }
        }
    }
    Update-DriverCount
}

function Set-DriverFilter {
    $q = ''; $mode = 'all'
    try { $q = $Script:DrvFilter.Text.Trim().ToLower() } catch {}
    try { $mode = [string]$Script:DrvView.SelectedItem.Tag } catch {}
    foreach ($x in $Script:DrvRows) {
        $ok = (-not $q) -or $x.Hay.Contains($q)
        if ($ok -and $mode -eq 'old') { $ok = [bool]$x.Info.Old }
        if ($ok -and $mode -eq 'unused') { $ok = (-not $x.Info.InUse) }
        $x.Row.Visibility = $(if ($ok) { 'Visible' } else { 'Collapsed' })
    }
    Update-DriverCount
}

function Show-DriverList {
    param($Res)
    $Script:DrvPanel.Children.Clear(); $Script:DrvChecks.Clear(); $Script:DrvRows.Clear()
    $Script:DrvInfo = @{}
    $list = @($Res)
    if ($list.Count -eq 0) {
        [void]$Script:DrvPanel.Children.Add((New-Text 'Aucun pilote tiers dans le magasin (ou analyse refusée : droits administrateur requis).' 13 '#9298A3' 'Normal' -Wrap))
        Update-DriverCount
        return
    }
    foreach ($d in $list) {
        $state = 'En service'; $clr = '#7CE3A1'
        if ($d.Boot) { $state = 'Protégé (démarrage)'; $clr = '#9298A3' }
        elseif ($d.Old) { $state = 'Ancienne version'; $clr = '#C9A227' }
        elseif (-not $d.InUse) { $state = 'Aucun appareil branché'; $clr = '#9298A3' }
        $cb = New-Check '' $false
        if ($d.Boot) { $cb.IsEnabled = $false; $cb.ToolTip = 'Nécessaire au démarrage de Windows : protégé' }
        elseif ($d.InUse) { $cb.ToolTip = 'Utilisé par un appareil actuellement branché : Windows refusera la suppression' }
        $cb.Tag = [string]$d.Inf
        $cb.Add_Click({ try { Update-DriverCount } catch {} })
        $cells = @([string]$d.Inf, [string]$d.Provider, [string]$d.Class, [string]$d.Device, ('v' + [string]$d.Version), [string]$d.Date, ('{0} Mo' -f $d.SizeMB), @{ T = $state; C = $clr })
        $row = New-TableRow $Script:StoreCols $cells $cb
        [void]$Script:DrvPanel.Children.Add($row)
        [void]$Script:DrvChecks.Add($cb)
        $hay = (([string]$d.Inf + ' ' + [string]$d.Provider + ' ' + [string]$d.Class + ' ' + [string]$d.Device)).ToLower()
        [void]$Script:DrvRows.Add(@{ Row = $row; Check = $cb; Info = $d; Hay = $hay })
        $Script:DrvInfo[[string]$d.Inf] = $d
    }
    Set-DriverFilter
}

function Export-DriverCsv {
    if ($Script:DrvInfo.Count -eq 0) { Add-Console 'Lancez d''abord « Analyser ».' 'Yellow'; return }
    $dest = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Pilotes_{0}_{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmm'))
    try {
        @($Script:DrvInfo.Values | Sort-Object Class, Provider, Inf) | Select-Object Inf, Provider, Class, Version, Date, SizeMB, Device, InUse, Old, Boot | Export-Csv -LiteralPath $dest -NoTypeInformation -Delimiter ';' -Encoding UTF8
        Add-Console ("Liste exportée sur le Bureau : " + $dest) 'LightGreen'
    } catch { Add-Console ("Export impossible : " + $_.Exception.Message) 'Red' }
}

# ---------------------------------------------------------------- Onglet « Ajouter un pilote »
function Show-DownloadedDrivers {
    param($Res)
    $Script:DlBox.Items.Clear()
    foreach ($r in @($Res)) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = ("{0}  ({1}, {2} INF, {3} Mo, {4})" -f $r.Name, $r.Kind, $r.InfCount, $r.SizeMB, $r.Date)
        $it.Tag = [string]$r.Path
        [void]$Script:DlBox.Items.Add($it)
    }
    if ($Script:DlBox.Items.Count -gt 0) { $Script:DlBox.SelectedIndex = 0 }
    else { Add-Console 'Aucun pilote (dossier ou .zip avec un .inf) trouvé dans Téléchargements.' 'Yellow' }
}

function Get-SelectedDownload {
    param([switch]$Name)
    $i = $Script:DlBox.SelectedItem
    if (-not $i -or -not $i.Tag) { if (-not $Name) { Add-Console 'Cliquez d''abord sur « Chercher dans Téléchargements », puis choisissez un pilote.' 'Yellow' }; return '' }
    if ($Name) { return [string]$i.Content }
    return [string]$i.Tag
}

function Test-OpenLevel {
    try { return ([string]$Script:CmbOpen.SelectedItem.Tag -eq 'open') } catch { return $false }
}

# ---------------------------------------------------------------- Onglet « Appareils absents »
function Show-GhostList {
    param($Res)
    $Script:GhostPanel.Children.Clear(); $Script:GhostChecks.Clear()
    $list = @($Res)
    if ($list.Count -eq 0) { [void]$Script:GhostPanel.Children.Add((New-Text 'Aucun appareil absent à nettoyer.' 13 '#7CE3A1' 'Normal' -Wrap)); return }
    foreach ($g in $list) {
        $cb = New-Check '' $false   # jamais coché d'office : supprimer un appareil absent se décide ligne par ligne
        $cb.Tag = [string]$g.Id; $cb.ToolTip = [string]$g.Id
        if (-not $g.Eligible) { $cb.IsEnabled = $false }
        $seen = $(if ($g.LastSeen) { [string]$g.LastSeen } else { 'date inconnue' })
        $ago = $(if ($g.LastSeen) { ('il y a {0} j' -f $g.Days) } else { 'conservé' })
        $clr = $(if ($g.Eligible) { '#C5C9D0' } else { '#9298A3' })
        $row = New-TableRow $Script:GhostCols @(@{ T = [string]$g.Name; C = $clr }, [string]$g.Class, $seen, @{ T = $ago; C = $clr }) $cb
        [void]$Script:GhostPanel.Children.Add($row)
        [void]$Script:GhostChecks.Add($cb)
    }
}

function Refresh-DriverBackups {
    $cb = $Script:DrvBackupBox
    if (-not $cb) { return }
    $cb.Items.Clear()
    try {
        $root = Join-Path $Script:LogDir 'Pilotes'
        if (Test-Path -LiteralPath $root) {
            foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
                $n = @(Get-ChildItem -LiteralPath $d.FullName -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count
                $it = New-Object Windows.Controls.ComboBoxItem
                $it.Content = ("{0}  ({1} pilote(s))" -f $d.Name, $n)
                $it.Tag = [string]$d.Name
                [void]$cb.Items.Add($it)
            }
        }
    } catch {}
    if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
}

function New-ToggleButton {
    # Bouton « Tout cocher / Tout décocher » : agit directement sur la liste demandée.
    param([string]$Text, [string]$Which, [bool]$Value)
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text; $b.Style = $Script:Window.FindResource('Btn'); $b.Margin = '8,4,0,4'
    $b.Tag = @($Which, $Value)
    $b.Add_Click({ param($s, $e)
        try {
            $w = [string]$s.Tag[0]; $v = [bool]$s.Tag[1]
            $lst = @(); if ($w -eq 'up') { $lst = @($Script:UpChecks) } elseif ($w -eq 'ghost') { $lst = @($Script:GhostChecks) }
            foreach ($c in $lst) { if ($c.IsEnabled) { $c.IsChecked = $v } }
        } catch { Add-Console ('  [!]   ' + $_.Exception.Message) 'Yellow' }
    })
    return $b
}

function Build-Drivers {
    $p = New-Page 'drivers' 'Pilotes' 'Mettez à jour les pilotes avec le catalogue officiel de Microsoft, faites le ménage dans le magasin de pilotes et sauvegardez : tout est contrôlé avant installation et sauvegardé avant suppression.'

    # --- Barre d'onglets
    $tabs = @(@('upd', 'Mises à jour'), @('store', 'Pilotes installés'), @('add', 'Ajouter un pilote'), @('ghost', 'Appareils absents'), @('bak', 'Sauvegardes'))
    $tb = New-Object Windows.Controls.WrapPanel
    $tb.Margin = '0,0,0,16'
    foreach ($t in $tabs) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $t[1]; $b.Style = $Script:Window.FindResource('Btn'); $b.Margin = '0,0,8,4'; $b.Tag = [string]$t[0]
        $b.Add_Click({ param($s, $e) try { Show-DriverTab ([string]$s.Tag) } catch {} })
        [void]$tb.Children.Add($b)
        $pn = New-Object Windows.Controls.StackPanel
        $pn.Visibility = 'Collapsed'
        $Script:DrvTabs[[string]$t[0]] = @{ Button = $b; Panel = $pn }
    }
    [void]$p.Children.Add($tb)

    # =============== Mises à jour
    $u = New-Card 'Mises à jour des pilotes' 'Pour chaque appareil, cherche sur le catalogue officiel de Microsoft (cartes graphiques NVIDIA / AMD / Intel comprises) un pilote plus récent. Rien ne s''installe sans votre accord : chaque pilote est contrôlé (signature WHQL Microsoft, identifiant, architecture, classe, version), un point de restauration et une copie de l''ancien pilote sont créés avant.' 'Contrôle WHQL' 'g'
    $Script:CmbScope = New-Combo @(@('Appareils principaux (graphique, réseau, son, Bluetooth, stockage, caméra…)', 'Main'), @('Appareils sans pilote seulement', 'Missing'), @('Tous les appareils (plus long)', 'All')) 430
    $Script:CmbLevel = New-Combo @(@('Stricte : identifiant exact (recommandée)', 'strict'), @('Élargie : si rien en strict, essayer la puce, les identifiants compatibles et le nom', 'ext')) 430
    [void]$u.Body.Children.Add((New-OptionPair 'Appareils :' $Script:CmbScope))
    [void]$u.Body.Children.Add((New-OptionPair 'Analyse :' $Script:CmbLevel))
    $cs = New-Spec 'tools' '' 'Recherche des pilotes (Catalog)'
    $cs.CodeFn = {
        $sc = 'Main'; $ex = ''
        try { $sc = [string]$Script:CmbScope.SelectedItem.Tag; if ([string]$Script:CmbLevel.SelectedItem.Tag -eq 'ext') { $ex = ' -Extended' } } catch {}
        if ($sc -notmatch '^(Main|Missing|All)$') { $sc = 'Main' }
        return ('Find-DriverCatalog -Scope ' + $sc + $ex)
    }
    $cs.ConfirmFn = { try { if ([string]$Script:CmbScope.SelectedItem.Tag -eq 'All') { return 'Analyser tous les appareils peut durer plusieurs minutes (une recherche par appareil). Continuer ?' } } catch {}; return '' }
    $cs.OnDone = { param($r) Show-UpdateResults $r }
    $ci = New-Spec 'tools' '' 'Installation des pilotes (Catalog)'
    $ci.CodeFn = {
        $it = @($Script:UpChecks | Where-Object { $_.IsChecked } | ForEach-Object { "'" + ([string]$_.Tag -replace '[^A-Za-z0-9_\\&\.\-\{\}#|~]', '') + "'" })
        if ($it.Count -eq 0) { return '' }
        return ('Install-CatalogDrivers -Items @(' + ($it -join ',') + ')')
    }
    $ci.ConfirmFn = {
        $n = @($Script:UpChecks | Where-Object { $_.IsChecked }).Count
        $ne = @($Script:UpChecks | Where-Object { $_.IsChecked -and ([string]$_.Tag).EndsWith('|2') }).Count
        $warn = ''; if ($ne -gt 0) { $warn = " ATTENTION : $ne de ces pilotes viennent de l'analyse élargie (identifiant de puce ou compatible, SUBSYS non exigé) : signature WHQL Microsoft, architecture, classe et version restent vérifiées, et Windows décide en dernier s'il applique le pilote." }
        "Télécharger depuis Microsoft et installer $n pilote(s) ? Chaque pilote est d'abord contrôlé et refusé au moindre doute. Un point de restauration et une copie de l'ancien pilote sont créés avant. L'écran peut clignoter (pilote graphique) et un redémarrage peut être demandé. La taille de chaque téléchargement est indiquée dans la liste." + $warn
    }
    $ci.OnDone = { param($r) $Script:UpPanel.Children.Clear(); $Script:UpChecks.Clear(); $Script:UpSummary.Text = 'Terminé. Relancez la recherche pour vérifier ce qui reste.' }
    $ub = New-Object Windows.Controls.WrapPanel
    $ub.Margin = '0,14,0,0'
    $b1 = New-Btn 'Rechercher les mises à jour' $cs -Primary; $b1.Margin = '0,4,0,4'
    [void]$ub.Children.Add($b1)
    [void]$ub.Children.Add((New-Btn 'Installer les mises à jour cochées' $ci -Primary))
    [void]$ub.Children.Add((New-ToggleButton 'Tout cocher' 'up' $true))
    [void]$ub.Children.Add((New-ToggleButton 'Tout décocher' 'up' $false))
    [void]$ub.Children.Add((New-Btn 'Gestionnaire de périphériques' @{ Fn = { try { Start-Process 'devmgmt.msc' } catch {} } }))
    [void]$ub.Children.Add((New-Btn 'Windows Update' @{ Fn = { try { Start-Process 'ms-settings:windowsupdate' } catch {} } }))
    [void]$u.Body.Children.Add($ub)
    $Script:UpSummary = New-Text 'Cliquez sur « Rechercher les mises à jour » : la recherche ne modifie rien.' 13 '#5AD1FF' 'Medium' -Wrap
    $Script:UpSummary.Margin = '0,12,0,8'
    [void]$u.Body.Children.Add($Script:UpSummary)
    $uh = New-TableRow $Script:UpCols @('Appareil', 'Classe', 'Installé', 'Proposé', 'Date', 'Taille', 'Analyse') -Header
    $uh.Margin = '0,0,18,0'
    [void]$u.Body.Children.Add($uh)
    $Script:UpPanel = New-Object Windows.Controls.StackPanel
    [void]$u.Body.Children.Add((New-ScrollList $Script:UpPanel 380))
    [void]$u.Body.Children.Add((New-Text 'Les résultats « Élargie » (en orange) ne sont pas cochés : à vérifier avant d''installer. Clic droit sur un appareil : ses propriétés Windows.' 12 '#C9A227' 'Normal' -Wrap))
    $u.Body.Children[$u.Body.Children.Count - 1].Margin = '0,8,0,0'
    [void]$Script:DrvTabs['upd'].Panel.Children.Add($u.Card)

    # =============== Pilotes installés (magasin)
    $c = New-Card 'Pilotes installés (magasin de pilotes)' 'Les pilotes tiers conservés par Windows, comme dans DriverStore Explorer. Les anciennes versions (une plus récente existe) peuvent être supprimées pour gagner de la place. Une copie de chaque pilote supprimé est d''abord enregistrée dans C:\BJMPC-Logs\Pilotes ; un pilote utilisé par un appareil est refusé par Windows, ceux nécessaires au démarrage sont protégés.' 'Sauvegarde automatique' 'g'
    $an = New-Spec 'tools' 'Get-DriverStoreList' 'Analyse du magasin de pilotes' @{} '' { param($r) Show-DriverList $r; Set-DriverChecks 'none' }
    $rm = New-Spec 'tools' '' 'Suppression de pilotes'
    $rm.CodeFn = {
        $n = @(Get-ShownDrivers | Where-Object { $_.Check.IsChecked } | ForEach-Object { "'" + ([string]$_.Check.Tag -replace '[^A-Za-z0-9.]', '') + "'" })
        if ($n.Count -eq 0) { return '' }
        return ('Remove-DriverPackages -Infs @(' + ($n -join ',') + ')')
    }
    $rm.ConfirmFn = {
        $sel = @(Get-ShownDrivers | Where-Object { $_.Check.IsChecked })
        $un = @($sel | Where-Object { -not $_.Info.InUse }).Count
        $t = "Supprimer {0} pilote(s) du magasin ? Une copie est d'abord enregistrée dans C:\BJMPC-Logs\Pilotes (restauration possible depuis l'onglet Sauvegardes). Un pilote encore utilisé sera refusé par Windows." -f $sel.Count
        if ($un -gt 0) { $t += " Attention : $un de ces pilotes n'ont aucun appareil branché en ce moment ; ils resserviront si l'appareil est rebranché (pensez aux imprimantes, clés USB, périphériques de bureau)." }
        return $t
    }
    $rm.OnDone = { param($r) $Script:DrvPanel.Children.Clear(); $Script:DrvChecks.Clear(); $Script:DrvRows.Clear(); $Script:DrvInfo = @{}; $Script:DrvCountText.Text = 'Terminé. Relancez l''analyse pour actualiser la liste.'; Refresh-DriverBackups }
    $Script:DrvView = New-Combo @(@('Tous les pilotes', 'all'), @('Anciennes versions', 'old'), @('Sans appareil branché', 'unused')) 200
    $Script:DrvView.Add_SelectionChanged({ try { Set-DriverFilter } catch {} })
    $Script:DrvFilter = New-Object Windows.Controls.TextBox
    $Script:DrvFilter.MinWidth = 220; $Script:DrvFilter.Padding = '6,4'; $Script:DrvFilter.ToolTip = 'Filtrer la liste (nom, éditeur, classe, appareil)'
    $Script:DrvFilter.Add_TextChanged({ try { Set-DriverFilter } catch {} })
    $bar = New-Object Windows.Controls.WrapPanel
    $bar.Margin = '0,14,0,0'
    $ba = New-Btn 'Analyser' $an -Primary; $ba.Margin = '0,4,0,4'
    [void]$bar.Children.Add($ba)
    $bo = New-Object Windows.Controls.Button
    $bo.Content = 'Cocher les anciennes versions'; $bo.Style = $Script:Window.FindResource('Btn'); $bo.Margin = '8,4,0,4'
    $bo.Add_Click({ try { Set-DriverChecks 'old' } catch {} })
    [void]$bar.Children.Add($bo)
    $bn = New-Object Windows.Controls.Button
    $bn.Content = 'Tout décocher'; $bn.Style = $Script:Window.FindResource('Btn'); $bn.Margin = '8,4,0,4'
    $bn.Add_Click({ try { Set-DriverChecks 'none' } catch {} })
    [void]$bar.Children.Add($bn)
    [void]$bar.Children.Add((New-Btn 'Supprimer la sélection' $rm -Primary))
    [void]$bar.Children.Add((New-Btn 'Exporter en CSV' @{ Fn = { try { Export-DriverCsv } catch { Add-Console $_.Exception.Message 'Red' } } }))
    [void]$c.Body.Children.Add($bar)
    $bar2 = New-Object Windows.Controls.WrapPanel
    $bar2.Margin = '0,6,0,0'
    [void]$bar2.Children.Add((New-OptionPair 'Afficher :' $Script:DrvView))
    $fp = New-OptionPair 'Filtrer :' $Script:DrvFilter
    [void]$bar2.Children.Add($fp)
    [void]$c.Body.Children.Add($bar2)
    $Script:DrvCountText = New-Text 'Aucun pilote sélectionné' 13 '#5AD1FF' 'Medium'
    $Script:DrvCountText.Margin = '0,10,0,8'
    [void]$c.Body.Children.Add($Script:DrvCountText)
    $sh = New-TableRow $Script:StoreCols @('Pilote', 'Éditeur', 'Classe', 'Appareil', 'Version', 'Date', 'Taille', 'État') -Header
    $sh.Margin = '0,0,18,0'
    [void]$c.Body.Children.Add($sh)
    $Script:DrvPanel = New-Object Windows.Controls.StackPanel
    [void]$c.Body.Children.Add((New-ScrollList $Script:DrvPanel 400))
    [void]$c.Body.Children.Add((New-Text '« Aucun appareil branché » ne veut pas dire « inutile » : imprimantes, périphériques USB, antivirus ou services réseau peuvent y figurer. Décochez ce dont vous n''êtes pas sûr.' 12 '#C9A227' 'Normal' -Wrap))
    $c.Body.Children[$c.Body.Children.Count - 1].Margin = '0,8,0,0'
    [void]$Script:DrvTabs['store'].Panel.Children.Add($c.Card)

    # =============== Ajouter un pilote téléchargé
    $k = New-Card 'Ajouter un pilote téléchargé' 'Pour un appareil que le catalogue ne propose pas : téléchargez le pilote sur le site du constructeur (dossier ou .zip) dans Téléchargements. Il est contrôlé avant tout ajout ; sans accord de votre part rien n''est installé.' 'Contrôlé' 'g'
    $fd = New-Spec 'tools' 'Find-DownloadedDrivers' 'Recherche des pilotes téléchargés' @{} '' { param($r) Show-DownloadedDrivers $r }
    $Script:DlBox = New-Object Windows.Controls.ComboBox
    $Script:DlBox.MinWidth = 520; $Script:DlBox.Padding = '8,4'; $Script:DlBox.Margin = '0,0,8,0'
    $Script:CmbOpen = New-Combo @(@('Strict : signature WHQL Microsoft obligatoire (recommandé)', 'strict'), @('Ouvert : signature valide d''un autre éditeur acceptée', 'open')) 430
    $fa = New-Spec 'tools' '' 'Ajout de pilote (dossier)'
    $fa.CodeFn = { $f = Get-SelectedDownload; if (-not $f) { return '' }; return ("Add-DriverFromFolder -Path '" + ($f -replace "(['\u2018\u2019\u201A\u201B])", '$1$1') + "' -Install" + $(if (Test-OpenLevel) { ' -Level 3' } else { '' })) }
    $fa.ConfirmFn = { if (Test-OpenLevel) { "NIVEAU OUVERT : contrôler le pilote « {0} » puis l'installer, même si sa signature n'est pas celle de Microsoft ? La signature doit rester valide (un pilote non signé ou altéré est refusé). Ce pilote n'est pas certifié WHQL : à réserver aux appareils introuvables en mode strict. Un point de restauration est créé avant." -f (Get-SelectedDownload -Name) } else { "Contrôler le pilote « {0} » puis l'installer ? Seul un pilote signé WHQL par Microsoft est accepté ; sinon rien n'est modifié. Un point de restauration est créé avant." -f (Get-SelectedDownload -Name) } }
    $fs = New-Spec 'tools' '' 'Ajout de pilote (dossier)'
    $fs.CodeFn = { $f = Get-SelectedDownload; if (-not $f) { return '' }; return ("Add-DriverFromFolder -Path '" + ($f -replace "(['\u2018\u2019\u201A\u201B])", '$1$1') + "'" + $(if (Test-OpenLevel) { ' -Level 3' } else { '' })) }
    $fs.ConfirmFn = { "Contrôler le pilote « {0} » puis l'ajouter au magasin de pilotes (sans l'installer sur un appareil) ?" -f (Get-SelectedDownload -Name) }
    $kb = New-Object Windows.Controls.WrapPanel
    $kb.Margin = '0,14,0,0'
    $kf = New-Btn '1. Chercher dans Téléchargements' $fd -Primary; $kf.Margin = '0,4,0,4'
    [void]$kb.Children.Add($kf)
    [void]$k.Body.Children.Add($kb)
    $kr = New-Object Windows.Controls.WrapPanel
    $kr.Margin = '0,8,0,0'
    [void]$kr.Children.Add($Script:DlBox)
    [void]$k.Body.Children.Add($kr)
    [void]$k.Body.Children.Add((New-OptionPair 'Contrôle :' $Script:CmbOpen))
    $kc = New-Object Windows.Controls.WrapPanel
    $kc.Margin = '0,10,0,0'
    $ki = New-Btn '2. Installer le pilote choisi' $fa -Primary; $ki.Margin = '0,4,0,4'
    [void]$kc.Children.Add($ki)
    [void]$kc.Children.Add((New-Btn 'Ajouter au magasin seulement' $fs))
    [void]$k.Body.Children.Add($kc)
    [void]$Script:DrvTabs['add'].Panel.Children.Add($k.Card)

    # =============== Appareils absents
    $gc = New-Card 'Appareils absents (fantômes)' 'Windows garde la trace des appareils qui ne sont plus branchés (anciennes clés USB, disques externes, écrans, claviers, souris, webcams…). Seuls ceux absents depuis 15 jours ou plus sont proposés ; un appareil dont la date est inconnue ne l''est jamais. Rebranché, l''appareil est réinstallé tout seul par Windows. Les cartes réseau, appareils Bluetooth, ports série et imprimantes ne sont jamais proposés : les supprimer ferait perdre une adresse IP fixe, un appairage, un numéro de port ou des réglages d''impression. Rien n''est coché d''office ; la liste est enregistrée avant suppression.' 'Réversible' 'g'
    $gs = New-Spec 'tools' 'Get-GhostDevices' 'Recherche des appareils absents' @{} '' { param($r) Show-GhostList $r }
    $gr = New-Spec 'tools' '' 'Suppression des appareils absents'
    $gr.CodeFn = {
        $ids = @($Script:GhostChecks | Where-Object { $_.IsChecked } | ForEach-Object { "'" + ([string]$_.Tag -replace '[^A-Za-z0-9_\\&\.\-\{\}#]', '') + "'" })
        if ($ids.Count -eq 0) { return '' }
        return ('Remove-GhostDevices -Instances @(' + ($ids -join ',') + ')')
    }
    $gr.ConfirmFn = { "Supprimer {0} entrée(s) d'appareils absents depuis 15 jours ou plus ? Le pilote n'est pas retiré du magasin : si l'appareil est rebranché, Windows le reconnaît et le réinstalle." -f @($Script:GhostChecks | Where-Object { $_.IsChecked }).Count }
    $gr.OnDone = { param($r) $Script:GhostPanel.Children.Clear(); $Script:GhostChecks.Clear(); [void]$Script:GhostPanel.Children.Add((New-Text 'Terminé. Relancez la recherche pour actualiser.' 13 '#9298A3')) }
    $gb = New-Object Windows.Controls.WrapPanel
    $gb.Margin = '0,14,0,8'
    $g1 = New-Btn 'Rechercher' $gs -Primary; $g1.Margin = '0,4,0,4'
    [void]$gb.Children.Add($g1)
    [void]$gb.Children.Add((New-Btn 'Supprimer la sélection' $gr -Primary))
    [void]$gb.Children.Add((New-ToggleButton 'Tout cocher' 'ghost' $true))
    [void]$gb.Children.Add((New-ToggleButton 'Tout décocher' 'ghost' $false))
    [void]$gc.Body.Children.Add($gb)
    $gh = New-TableRow $Script:GhostCols @('Appareil', 'Classe', 'Dernière présence', 'Absent') -Header
    $gh.Margin = '0,0,18,0'
    [void]$gc.Body.Children.Add($gh)
    $Script:GhostPanel = New-Object Windows.Controls.StackPanel
    [void]$gc.Body.Children.Add((New-ScrollList $Script:GhostPanel 340))
    [void]$Script:DrvTabs['ghost'].Panel.Children.Add($gc.Card)

    # =============== Sauvegardes
    $r = New-Card 'Sauvegarde et restauration' 'Exportez tous les pilotes tiers, ou réinstallez ceux d''une sauvegarde (créée ici, lors d''une mise à jour ou lors d''une suppression).' '' 'n'
    Add-Row $r.Body 'Sauvegarder tous les pilotes tiers' 'Copie tous les pilotes installés dans C:\BJMPC-Logs\Pilotes.' '' 'n' @((New-Btn 'Sauvegarder' (New-Spec 'tools' 'Export-DriversBackup' 'Sauvegarde des pilotes')))
    $Script:DrvBackupBox = New-Object Windows.Controls.ComboBox
    $Script:DrvBackupBox.MinWidth = 340; $Script:DrvBackupBox.Padding = '8,4'; $Script:DrvBackupBox.Margin = '0,0,8,0'
    $rs = New-Spec 'tools' '' 'Restauration de pilotes'
    $rs.CodeFn = {
        $i = $Script:DrvBackupBox.SelectedItem
        if (-not $i -or -not $i.Tag) { Add-Console 'Aucune sauvegarde sélectionnée.' 'Yellow'; return '' }
        $n = [string]$i.Tag
        if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9_.\-]*$') { return '' }
        return ("Restore-DriverBackup -Name '" + $n + "'")
    }
    $rs.ConfirmFn = { "Réinstaller les pilotes de la sauvegarde « {0} » ?" -f $(try { [string]$Script:DrvBackupBox.SelectedItem.Tag } catch { '' }) }
    $rrow = New-Object Windows.Controls.StackPanel
    $rrow.Orientation = 'Horizontal'; $rrow.Margin = '0,14,0,0'
    [void]$rrow.Children.Add($Script:DrvBackupBox)
    $rb = New-Btn 'Restaurer' $rs; $rb.Margin = '0,0,0,0'
    [void]$rrow.Children.Add($rb)
    $act = New-Object Windows.Controls.Button
    $act.Content = 'Actualiser la liste'; $act.Style = $Script:Window.FindResource('Btn'); $act.Margin = '8,0,0,0'
    $act.Add_Click({ try { Refresh-DriverBackups } catch {} })
    [void]$rrow.Children.Add($act)
    [void]$r.Body.Children.Add($rrow)
    [void]$Script:DrvTabs['bak'].Panel.Children.Add($r.Card)
    Refresh-DriverBackups

    foreach ($t in $tabs) { [void]$p.Children.Add($Script:DrvTabs[[string]$t[0]].Panel) }
    Show-DriverTab 'upd'
}


#endregion
# ================================================================ RÉSUMÉ POUR LE CLIENT (journal de session, textes simples, avatar animé et voix)
#region Résumé client

$Script:SessionLog = New-Object System.Collections.ArrayList
$Script:RunFlags = @{ Fail = 0; Warn = 0 }
$Script:SessionFile = Join-Path $Script:LogDir ("Session_{0}_{1}.json" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))

# Catégories dans l'ordre où elles sont racontées.
$Script:SumCats = [ordered]@{
    verif   = 'Les vérifications'
    repar   = 'Les réparations'
    vitesse = 'Pour que ça aille plus vite'
    prive   = 'Votre vie privée'
    net     = 'Votre connexion Internet'
    menage  = 'Le ménage'
    logi    = 'Vos logiciels'
    secu    = 'Votre protection'
    filet   = 'Votre filet de sécurité'
}

function Join-French {
    param([string[]]$Items)
    $a = @($Items | Where-Object { $_ })
    if ($a.Count -eq 0) { return '' }
    if ($a.Count -eq 1) { return $a[0] }
    return (($a[0..($a.Count - 2)] -join ', ') + ' et ' + $a[-1])
}

function Get-AppDisplayName {
    param([string]$Id)
    $row = @($Script:AppCatalog | Where-Object { [string]$_[2] -eq $Id } | Select-Object -First 1)
    if ($row.Count -gt 0 -and $row[0]) { return [string]$row[0][1] }
    return ''
}

function Get-PackageDisplayName {
    param([string]$Name)
    try {
        if (-not $Script:BloatRows) { $Script:BloatRows = Import-Catalog 'BJMPC-Outils-Win11.ps1' 'BloatCatalog' }
        foreach ($r in $Script:BloatRows) { if ($Name -like [string]$r[0]) { return [string]$r[1] } }
    } catch {}
    return ''
}

# Chaque entrée : K = motif cherché dans "code|titre", C = catégorie, T = phrase (ou bloc qui rend des phrases).
$Script:PlainMap = @(
    @{ K = '^Test-WingetCatalog|^Get-BloatApps|¦Recherche winget|^Show-State|¦État des optimisations|¦Annulation de la sélection|¦Retour à l.état d.origine'; C = 'skip'; T = '' }
    @{ K = '^Get-DriverStoreList|¦Analyse du magasin de pilotes'; C = 'skip'; T = '' }
    @{ K = '^Show-HardwareProfile|¦Profil matériel'; C = 'verif'; T = 'Nous avons relevé les caractéristiques de votre ordinateur pour bien adapter nos réglages.' }
    @{ K = '^Get-SystemSummary|^Export-SystemInfo|¦Informations système'; C = 'verif'; T = 'Nous avons noté les caractéristiques de votre ordinateur.' }
    @{ K = '^Get-StorageHealth|¦Santé des disques'; C = 'verif'; T = 'Nous avons contrôlé l''état de santé de vos disques, là où vos fichiers sont rangés.' }
    @{ K = '^Get-HardwareErrors|¦Erreurs matérielles'; C = 'verif'; T = 'Nous avons cherché des signes de panne dans votre ordinateur.' }
    @{ K = '^New-EnergyReport|¦Rapport énergétique'; C = 'verif'; T = 'Nous avons fait un bilan de la consommation d''énergie de votre ordinateur.' }
    @{ K = '^New-BatteryReport|¦Rapport de batterie'; C = 'verif'; T = 'Nous avons contrôlé l''état de votre batterie.' }
    @{ K = '^Test-NetworkQuality|¦Qualité de la connexion|^Get-WifiInfo|^New-WlanReport|¦Rapport Wi-Fi'; C = 'verif'; T = 'Nous avons testé la qualité de votre connexion Internet.' }
    @{ K = '^Get-SecurityAudit|¦Audit de sécurité'; C = 'verif'; T = 'Nous avons contrôlé le niveau de protection de votre ordinateur.' }
    @{ K = '^Get-PendingUpdates|¦Mises à jour Windows$'; C = 'verif'; T = 'Nous avons vérifié s''il manquait des mises à jour de Windows.' }
    @{ K = '^Get-WingetUpdates|¦Applications à mettre à jour'; C = 'verif'; T = 'Nous avons cherché quels logiciels avaient besoin d''une mise à jour.' }
    @{ K = '^Get-StartupItems|¦Programmes au démarrage'; C = 'verif'; T = 'Nous avons regardé quels programmes se lancent tout seuls au démarrage.' }
    @{ K = '^Get-LicenseInfo|¦Licence Windows'; C = 'verif'; T = 'Nous avons vérifié que votre Windows est bien activé.' }
    @{ K = '^Start-MemoryDiagnostic|¦Diagnostic de la mémoire'; C = 'verif'; T = 'Nous avons préparé un test de la mémoire de votre ordinateur. Il se fera au prochain démarrage.' }
    @{ K = '^Invoke-FullSequence|¦Séquence complète'; C = 'repar'; T = 'Nous avons fait une grande vérification : les fichiers essentiels de Windows, puis votre disque. Ce qui était abîmé a été réparé.' }
    @{ K = '^Invoke-SFC|¦SFC'; C = 'repar'; T = 'Nous avons vérifié les fichiers essentiels de Windows et réparé ceux qui étaient abîmés.' }
    @{ K = '^Invoke-DISM|¦DISM'; C = 'repar'; T = 'Nous avons contrôlé le cœur de Windows pour nous assurer qu''il est en bon état.' }
    @{ K = '¦CHKDSK \(planification\)'; C = 'repar'; T = 'Nous avons programmé une vérification approfondie de votre disque. Elle se fera au prochain démarrage et peut prendre un peu de temps.' }
    @{ K = '^Invoke-Chkdsk|¦CHKDSK'; C = 'repar'; T = 'Nous avons contrôlé que votre disque ne présente pas de problème.' }
    @{ K = '^Repair-WMI|¦WMI'; C = 'repar'; T = 'Nous avons vérifié que Windows sait bien s''informer sur votre ordinateur.' }
    @{ K = '^Reset-Services|¦Services Windows'; C = 'repar'; T = 'Nous avons remis en ordre les petits programmes de fond dont Windows a besoin.' }
    @{ K = '^Reset-Network'; C = 'repar'; T = 'Nous avons remis à zéro la connexion à Internet de votre ordinateur, pour corriger d''éventuelles coupures ou lenteurs.' }
    @{ K = '^Reset-WindowsUpdate'; C = 'repar'; T = 'Nous avons réparé le système qui télécharge les mises à jour de Windows.' }
    @{ K = '^Reset-Graphics|¦Options graphiques'; C = 'repar'; T = 'Nous avons remis à zéro les réglages de l''affichage de votre écran.' }
    @{ K = '^Clear-ShellCaches|¦Caches$'; C = 'repar'; T = 'Nous avons rafraîchi l''affichage des icônes et des aperçus de vos images.' }
    @{ K = '^Reset-Store|¦Microsoft Store'; C = 'repar'; T = 'Nous avons réparé la boutique d''applications de Windows.' }
    @{ K = '^Register-AllApps|¦Applications Windows'; C = 'repar'; T = 'Nous avons réparé les applications fournies avec Windows.' }
    @{ K = '^Reset-Search|¦Windows Search'; C = 'repar'; T = 'Nous avons remis en état la recherche de fichiers de Windows. Elle se reconstruit en arrière-plan.' }
    @{ K = '^Reset-PowerPlan|¦Modes d.alimentation'; C = 'repar'; T = 'Nous avons remis les modes d''économie d''énergie à leurs réglages normaux.' }
    @{ K = '^Restart-ExplorerShell'; C = 'repar'; T = 'Nous avons relancé l''affichage de Windows, c''est-à-dire la barre du bas et le bureau.' }
    @{ K = '^Restart-AudioServices|¦Services audio'; C = 'repar'; T = 'Nous avons relancé le son de votre ordinateur.' }
    @{ K = '^Clear-PrintQueue|¦File d.impression'; C = 'repar'; T = 'Nous avons débloqué la file d''impression.' }
    @{ K = '^Sync-Clock|¦Horloge'; C = 'repar'; T = 'Nous avons remis votre ordinateur à l''heure.' }
    @{ K = '^Clear-DnsCache|¦Cache DNS'; C = 'repar'; T = 'Nous avons vidé la mémoire temporaire de la connexion Internet, ce qui règle certains sites qui ne s''ouvraient pas.' }
    @{ K = '^Get-BackupStatus'; C = 'skip'; T = '' }
    @{ K = '^Get-EventFindings|¦Analyse des erreurs de Windows'; C = 'verif'; T = 'Nous avons relu le journal dans lequel Windows note ses erreurs, pour repérer ce qui n''allait pas.' }
    @{ K = '^Invoke-EventFix|¦Réparation des erreurs de Windows'; C = 'repar'; T = {
            param($e)
            $n = @($e.Ok).Count
            if ($n -eq 0) { return @() }
            $s = if ($n -eq 1) { 'Nous avons corrigé un problème que Windows avait signalé dans son journal d''erreurs.' } else { "Nous avons corrigé $n problèmes que Windows avait signalés dans son journal d'erreurs." }
            return @($s, 'Nous vérifierons à la prochaine visite qu''ils ne sont pas revenus.')
        } }
    @{ K = 'Invoke-FileBackup|Register-BackupTask|¦Sauvegarde des fichiers'; C = 'filet'; T = {
            # Le moteur rend dans Ok les dossiers copiés, et 'auto' si la sauvegarde automatique a été programmée.
            param($e)
            $what = @(@($e.Ok) | Where-Object { $_ -and $_ -ne 'auto' })
            $r = @()
            if ($what.Count -gt 0) {
                $r += 'Nous avons fait une copie de sécurité de vos fichiers sur un autre disque : ' + (Join-French $what) + '.'
                $r += 'Si un fichier est effacé par erreur, il pourra être récupéré.'
            }
            if (@($e.Ok) -contains 'auto') {
                $r += 'Cette sauvegarde se refera désormais toute seule, à heure fixe. Pensez seulement à laisser le disque de sauvegarde branché.'
            }
            return $r
        } }
    @{ K = '^Unregister-BackupTask|¦Sauvegarde automatique'; C = 'skip'; T = '' }
    @{ K = '^Restore-FileBackup|¦Restauration des fichiers'; C = 'repar'; T = 'Nous avons remis à leur place des fichiers qui manquaient, à partir de votre copie de sécurité.' }
    @{ K = '^Invoke-FullProfile|¦Réglages recommandés|¦Profil complet recommandé'; C = 'vitesse'; T = 'Nous avons appliqué les réglages recommandés pour que votre ordinateur soit plus agréable à utiliser, sans rien changer à vos habitudes.' }
    @{ K = '^Optimize-Gaming|¦Profil Gaming'; C = 'vitesse'; T = 'Nous avons réglé votre ordinateur pour qu''il soit plus fluide dans les jeux.' }
    @{ K = '^Optimize-Storage|¦SSD'; C = 'vitesse'; T = 'Nous avons vérifié que Windows utilise bien votre disque rapide.' }
    @{ K = '^Optimize-Explorer'; C = 'vitesse'; T = 'Nous avons rendu l''explorateur de fichiers plus pratique à utiliser.' }
    @{ K = '^Optimize-Power|¦Plan d.alimentation'; C = 'vitesse'; T = 'Nous avons choisi un mode d''alimentation qui privilégie la rapidité de votre ordinateur.' }
    @{ K = '^Set-Hags -Mode on'; C = 'vitesse'; T = 'Nous avons activé un réglage de votre carte graphique qui aide les jeux à être plus fluides. Il prendra effet au prochain redémarrage.' }
    @{ K = '^Set-Hags'; C = 'vitesse'; T = 'Nous avons remis un réglage de votre carte graphique à sa valeur d''origine.' }
    @{ K = '^Set-BuiltinPowerPlan -Mode balanced'; C = 'vitesse'; T = 'Nous avons choisi un mode d''alimentation équilibré entre rapidité et économie d''énergie.' }
    @{ K = '^Set-BuiltinPowerPlan'; C = 'vitesse'; T = 'Nous avons choisi un mode d''alimentation qui privilégie la rapidité de votre ordinateur.' }
    @{ K = '^Set-OledCare|¦Protection OLED'; C = 'vitesse'; T = 'Nous avons ajouté des protections pour que votre écran dure plus longtemps.' }
    @{ K = '¦Échelle|¦Taille du texte'; C = 'vitesse'; T = 'Nous avons ajusté la taille de l''affichage pour que votre écran soit net et confortable à lire.' }
    @{ K = '^Optimize-Privacy|¦Confidentialité$'; C = 'prive'; T = 'Nous avons réduit le suivi publicitaire dont vous étiez l''objet.' }
    @{ K = '¦Réglages : Télémétrie'; C = 'prive'; T = 'Nous avons limité les informations que votre ordinateur envoie à Microsoft sur la façon dont vous l''utilisez.' }
    @{ K = '¦Réglages : Publicités'; C = 'prive'; T = 'Nous avons réduit les publicités et les suggestions qui s''affichaient dans Windows.' }
    @{ K = '¦Réglages : IA'; C = 'prive'; T = 'Nous avons désactivé les assistants et fonctions d''intelligence artificielle de Windows qui observent ce que vous faites.' }
    @{ K = '¦Réglages : Navigateurs'; C = 'prive'; T = 'Nous avons réduit la collecte d''informations par certains logiciels installés sur votre ordinateur.' }
    @{ K = '¦Réglages : Autorisations'; C = 'prive'; T = 'Nous avons retiré aux applications l''accès automatique à votre micro, à votre caméra ou à vos contacts. Vous pourrez toujours leur donner la permission quand vous le souhaitez.' }
    @{ K = '¦Réglages : Interface'; C = 'vitesse'; T = 'Nous avons ajusté l''affichage de Windows pour qu''il soit plus pratique et plus réactif.' }
    @{ K = '¦Réglages : Mises à jour'; C = 'secu'; T = 'Nous avons réglé la façon dont Windows se met à jour, pour éviter les mauvaises surprises.' }
    @{ K = '¦Réglages : Sécurité'; C = 'secu'; T = 'Nous avons ajusté quelques réglages de sécurité et de connexion.' }
    @{ K = '¦Réglages : Fonctionnalités'; C = 'vitesse'; T = 'Nous avons retiré de vieux éléments de Windows qui ne servent presque plus.' }
    @{ K = '¦Réglages : Barre de jeu'; C = 'vitesse'; T = 'Nous avons désactivé la barre de jeu et l''enregistrement en arrière-plan, qui ralentissent parfois les jeux.' }
    @{ K = '¦Réglages : Pile réseau'; C = 'net'; T = 'Nous avons ajusté la façon dont votre ordinateur choisit sa connexion Internet.' }
    @{ K = '¦Réglages : Démarrage'; C = 'vitesse'; T = 'Nous avons ajusté quelques réglages de démarrage de Windows.' }
    @{ K = '¦Réglages : '; C = 'vitesse'; T = 'Nous avons ajusté quelques réglages de Windows.' }
    @{ K = '¦Mullvad base|¦AdGuard'; C = 'net'; T = 'Nous avons rendu votre navigation sur Internet plus privée : les adresses des sites que vous visitez sont maintenant protégées. Cela bloque aussi une partie des publicités et des sites dangereux.' }
    @{ K = '¦DNS d.origine'; C = 'net'; T = 'Nous avons remis le réglage d''origine de votre connexion Internet.' }
    @{ K = '^Set-MullvadDns|^Set-DnsPreset|¦DNS '; C = 'net'; T = 'Nous avons rendu votre navigation sur Internet plus privée : les adresses des sites que vous visitez sont maintenant protégées.' }
    @{ K = '^Optimize-Network|¦Réseau$'; C = 'net'; T = 'Nous avons réglé votre carte Wi-Fi et réseau pour que la connexion soit plus stable.' }
    @{ K = '^Invoke-DiskCleanup -WindowsOld'; C = 'menage'; T = 'Nous avons nettoyé les fichiers inutiles qui prenaient de la place, y compris l''ancienne version de Windows.' }
    @{ K = '^Invoke-DiskCleanup|^Invoke-Cleanup|¦Nettoyage'; C = 'menage'; T = 'Nous avons nettoyé les fichiers inutiles qui prenaient de la place.' }
    @{ K = '^Clear-BrowserCaches|¦Caches des navigateurs'; C = 'menage'; T = 'Nous avons vidé la mémoire temporaire de vos navigateurs web pour libérer de la place. Vos favoris et vos mots de passe sont conservés.' }
    @{ K = '^Clear-ShaderCache|¦Caches de shaders'; C = 'menage'; T = 'Nous avons vidé la mémoire temporaire de vos jeux. Elle se reconstruit toute seule.' }
    @{ K = '^Remove-DefaultUser0|¦defaultuser0'; C = 'menage'; T = 'Nous avons supprimé un compte utilisateur inutile, laissé par l''installation de Windows.' }
    @{ K = '^Uninstall-OneDrive|¦OneDrive'; C = 'menage'; T = 'Nous avons désinstallé OneDrive, le service de stockage en ligne de Microsoft. Aucun de vos fichiers n''a été supprimé.' }
    @{ K = '^Remove-AppxApps|¦Désinstallation des applications'; C = 'menage'; T = {
            param($e)
            $names = @(@($e.Ok) | ForEach-Object { Get-PackageDisplayName ([string]$_) } | Where-Object { $_ })
            $n = @($e.Ok).Count
            if ($n -eq 0) { return @() }
            $s = if ($n -eq 1) { 'Nous avons retiré une application fournie avec Windows dont vous n''aviez pas besoin.' } else { "Nous avons retiré $n applications fournies avec Windows dont vous n'aviez pas besoin." }
            if ($names.Count -gt 0) { $s += ' Par exemple : ' + (Join-French @($names | Select-Object -First 4)) + '.' }
            return @($s, 'Vous pouvez les récupérer à tout moment depuis la boutique de Windows.')
        } }
    @{ K = '^Install-WingetApps|¦Installation des applications|¦Installation par identifiant'; C = 'logi'; T = {
            param($e)
            $names = @(@($e.Ok) | ForEach-Object { $x = Get-AppDisplayName ([string]$_); if ($x) { $x } else { [string]$_ } })
            if ($names.Count -eq 0) { return @() }
            return @('Nous avons installé : ' + (Join-French $names) + '.')
        } }
    @{ K = '^Update-WingetApps|¦Mise à jour des applications'; C = 'logi'; T = 'Nous avons mis à jour vos logiciels pour qu''ils soient plus sûrs et plus récents.' }
    @{ K = '^Export-InstalledSoftware|¦Inventaire des logiciels'; C = 'logi'; T = 'Nous avons dressé la liste de tous les logiciels installés sur votre ordinateur.' }
    @{ K = '^Get-DriverDevices|¦Liste des appareils'; C = 'skip'; T = '' }
    @{ K = '^Find-DriverCatalog|¦Recherche des pilotes \(Catalog\)'; C = 'verif'; T = 'Nous avons cherché, sur le site officiel de Microsoft, des versions plus récentes des petits programmes qui font fonctionner chaque composant de votre ordinateur.' }
    @{ K = '^Install-CatalogDrivers|¦Installation des pilotes \(Catalog\)'; C = 'logi'; T = {
            param($e)
            $n = @($e.Ok).Count
            $r = @()
            if ($n -gt 0) {
                $r += $(if ($n -eq 1) { 'Nous avons mis à jour un composant de votre ordinateur avec un programme officiel Microsoft, vérifié et certifié.' } else { "Nous avons mis à jour $n composants de votre ordinateur avec des programmes officiels Microsoft, vérifiés et certifiés." })
                $r += 'L''ancienne version a été gardée de côté, au cas où.'
            }
            if (@($e.Bad).Count -gt 0) { $r += 'Quelques mises à jour n''ont pas passé notre contrôle de sécurité : nous ne les avons pas installées, par prudence.' }
            if ($e.Reboot -and $n -gt 0) { $r += 'Un redémarrage sera nécessaire pour terminer.' }
            return $r
        } }
    @{ K = '^Add-DriverFromFolder|¦Ajout de pilote'; C = 'logi'; T = {
            param($e)
            if (@($e.Ok).Count -eq 0) { return @() }
            return @('Nous avons installé un pilote fourni à la main, après avoir vérifié qu''il est bien certifié par Microsoft.')
        } }
    @{ K = '^Get-GhostDevices|¦Recherche des appareils absents'; C = 'skip'; T = '' }
    @{ K = '^Find-DownloadedDrivers|¦Recherche des pilotes téléchargés'; C = 'skip'; T = '' }
    @{ K = '^Remove-GhostDevices|¦Suppression des appareils absents'; C = 'menage'; T = {
            param($e)
            $n = @($e.Ok).Count
            if ($n -eq 0) { return @() }
            $s = if ($n -eq 1) { 'Nous avons effacé la trace d''un appareil qui n''est plus branché depuis longtemps.' } else { "Nous avons effacé la trace de $n appareils qui ne sont plus branchés depuis longtemps." }
            return @($s, 'S''ils sont rebranchés un jour, Windows les reconnaîtra tout seul.')
        } }
    @{ K = '^Get-DriverUpdates|¦Recherche des pilotes'; C = 'verif'; T = 'Nous avons cherché si Windows proposait des versions plus récentes des petits programmes qui font fonctionner les composants de votre ordinateur.' }
    @{ K = '^Install-DriverUpdates|¦Installation des pilotes'; C = 'logi'; T = {
            param($e)
            $n = @($e.Ok).Count
            if ($n -eq 0) { return @() }
            $s = if ($n -eq 1) { 'Nous avons mis à jour un des petits programmes qui font fonctionner les composants de votre ordinateur.' } else { "Nous avons mis à jour $n des petits programmes qui font fonctionner les composants de votre ordinateur." }
            $r = @($s, 'Cela améliore la stabilité et la compatibilité.')
            if ($e.Reboot) { $r += 'Un redémarrage sera nécessaire pour terminer la mise à jour.' }
            return $r
        } }
    @{ K = '^Remove-DriverPackages|¦Suppression de pilotes'; C = 'menage'; T = {
            param($e)
            $n = @($e.Ok).Count
            if ($n -eq 0) { return @() }
            $s = if ($n -eq 1) { 'Nous avons supprimé un ancien petit programme de composant devenu inutile, qui prenait de la place.' } else { "Nous avons supprimé $n anciens petits programmes de composants devenus inutiles, qui prenaient de la place." }
            return @($s, 'Nous en avons gardé une copie de sécurité, au cas où.')
        } }
    @{ K = '^Restore-DriverBackup|¦Restauration de pilotes'; C = 'repar'; T = 'Nous avons remis en place des petits programmes de composants à partir d''une copie de sécurité.' }
    @{ K = '^Export-DriversBackup|¦Sauvegarde des pilotes'; C = 'filet'; T = 'Nous avons mis de côté une copie des petits programmes qui font fonctionner les composants de votre ordinateur, pour pouvoir les réinstaller facilement.' }
    @{ K = '^Get-Win11DefaultsState|¦Comparaison avec Windows 11'; C = 'skip'; T = '' }
    @{ K = '^Restore-Win11Defaults|¦Rétablissement des valeurs par défaut Windows 11'; C = 'repar'; T = {
            param($e)
            $n = @($e.Ok).Count
            if ($n -le 0) { return @() }
            return @('Nous avons remis ' + $(if ($n -eq 1) { 'un réglage' } else { "$n réglages" }) + ' de Windows à leur état d''origine, avec une sauvegarde pour pouvoir revenir en arrière.')
        } }
    @{ K = '^Undo-Win11Defaults|¦Annulation du rétablissement Windows 11'; C = 'filet'; T = 'Nous avons annulé le dernier retour aux réglages d''origine de Windows et remis les réglages comme avant.' }
    @{ K = '^New-RestorePoint|¦Point de restauration'; C = 'filet'; T = 'Nous avons créé un point de sauvegarde de Windows : en cas de souci, on peut revenir à l''état d''avant notre intervention.' }
    @{ K = '^Invoke-DefenderScan|¦Analyse Defender'; C = 'secu'; T = 'Nous avons fait analyser votre ordinateur par l''antivirus de Windows.' }
)

function Get-PlainEntry {
    # Rend @{ Cat; Lines } pour une entrée du journal de session, ou $null si rien à raconter.
    param($E)
    $key = ([string]$E.Code).Trim() + '¦' + ([string]$E.Title)
    foreach ($m in $Script:PlainMap) {
        if ($key -match $m.K) {
            if ($m.C -eq 'skip') { return $null }
            $lines = @()
            if ($m.T -is [scriptblock]) { $lines = @(& $m.T $E) } else { $lines = @([string]$m.T) }
            return @{ Cat = [string]$m.C; Lines = $lines }
        }
    }
    return @{ Cat = 'unknown'; Lines = @() }
}

function New-SummaryScenes {
    # Transforme le journal de session en scènes : @{ Title; Mood; Lines }.
    param($Entries, [string]$Client = '', [string]$Company = 'BJMPC Informatique', [string]$Assistant = 'Mia', [bool]$Reboot = $false)
    $scenes = New-Object 'System.Collections.Generic.List[object]'
    $hello = if ($Client.Trim()) { 'Bonjour ' + $Client.Trim() + ' !' } else { 'Bonjour !' }
    [void]$scenes.Add(@{ Title = 'Bienvenue'; Mood = 'happy'; Lines = @(
        $hello,
        ("Je m'appelle $Assistant, je suis l'assistante virtuelle de $Company."),
        'Je vais vous expliquer, avec des mots simples, ce que nous avons fait sur votre ordinateur.') })

    $byCat = @{}; foreach ($k in $Script:SumCats.Keys) { $byCat[$k] = New-Object 'System.Collections.Generic.List[string]' }
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $anyChange = $false
    $anyReversible = $false
    foreach ($e in @($Entries | Where-Object { $_.Include })) {
        $p = Get-PlainEntry $e
        if (-not $p) { continue }
        if ($p.Cat -eq 'unknown') { continue }
        if ([int]$e.Fail -gt 0 -or [int]$e.Warn -gt 0) {
            if (-not $failed.Contains([string]$Script:SumCats[$p.Cat])) { [void]$failed.Add([string]$Script:SumCats[$p.Cat]) }
            continue
        }
        foreach ($l in $p.Lines) { if ($l -and -not $byCat[$p.Cat].Contains([string]$l)) { [void]$byCat[$p.Cat].Add([string]$l) } }
        if ($p.Cat -ne 'verif') { $anyChange = $true }
        if ($e.Engine -eq 'opt' -and ([string]$e.Code + [string]$e.Title) -notmatch 'Show-|Restore-|New-RestorePoint') { $anyReversible = $true }
        # éléments qui n'ont pas pu être faits dans une exécution réussie dans l'ensemble
        $bad = @($e.Bad | Where-Object { $_ })
        if ($bad.Count -gt 0) {
            $nm = @($bad | ForEach-Object { $x = Get-AppDisplayName ([string]$_); if (-not $x) { $x = Get-PackageDisplayName ([string]$_) }; $x } | Where-Object { $_ })
            if ($nm.Count -gt 0) { [void]$failed.Add('certains éléments (' + (Join-French $nm) + ')') } else { [void]$failed.Add('un des éléments demandés') }
        }
    }
    foreach ($k in $Script:SumCats.Keys) {
        if ($byCat[$k].Count -gt 0) { [void]$scenes.Add(@{ Title = [string]$Script:SumCats[$k]; Mood = 'happy'; Lines = @($byCat[$k]) }) }
    }
    if ($scenes.Count -eq 1 -and $failed.Count -eq 0) {
        [void]$scenes.Add(@{ Title = 'Aujourd''hui'; Mood = 'happy'; Lines = @('Pour le moment, aucune intervention n''a été enregistrée sur cet ordinateur.') })
    }
    if ($failed.Count -gt 0) {
        $l = @()
        foreach ($f in $failed) { $l += ('Une étape n''a pas pu être menée jusqu''au bout : ' + $f.Substring(0, 1).ToLower() + $f.Substring(1) + '.') }
        $l += 'Votre technicien va regarder cela avec vous.'
        [void]$scenes.Add(@{ Title = 'À revoir ensemble'; Mood = 'serious'; Lines = $l })
    }
    $end = @()
    if ($anyReversible) { $end += 'Chaque réglage a été noté. Si quelque chose ne vous convient pas, nous pouvons tout remettre comme avant, très simplement.' }
    if ($anyChange) { $end += 'Nous n''avons supprimé aucun de vos documents, de vos photos ou de vos fichiers personnels.' }
    if ($Reboot) { $end += 'Pour que tout soit bien pris en compte, l''ordinateur devra redémarrer. Pensez à enregistrer votre travail avant.' }
    if ($end.Count -gt 0) { [void]$scenes.Add(@{ Title = 'Bon à savoir'; Mood = 'happy'; Lines = $end }) }
    [void]$scenes.Add(@{ Title = 'Au revoir'; Mood = 'happy'; Lines = @(
        'Voilà, c''est terminé !',
        ("Si vous remarquez quoi que ce soit d'inhabituel, ou si vous avez une question, n'hésitez pas à contacter $Company."),
        'Merci de votre confiance, et à bientôt !') })
    return , $scenes
}

function Get-SummaryText {
    param($Scenes)
    $sb = New-Object Text.StringBuilder
    foreach ($s in $Scenes) {
        [void]$sb.AppendLine(('# ' + $s.Title))
        foreach ($l in $s.Lines) { [void]$sb.AppendLine($l) }
        [void]$sb.AppendLine('')
    }
    return $sb.ToString().TrimEnd()
}

# ---------------------------------------------------------------- Journal de session
function Save-SessionLog {
    try {
        $rows = @($Script:SessionLog | ForEach-Object { [pscustomobject]@{ Time = $_.Time; Engine = $_.Engine; Title = $_.Title; Code = $_.Code; Fail = $_.Fail; Warn = $_.Warn; Ok = @($_.Ok); Bad = @($_.Bad); Reboot = [bool]$_.Reboot } })
        $json = ConvertTo-Json -InputObject $rows -Depth 4
        [IO.File]::WriteAllText($Script:SessionFile, $json, (New-Object Text.UTF8Encoding($true)))
    } catch { Write-Crash ("Session : " + $_.Exception.Message) }
}

function Import-SessionLog {
    try {
        if (-not (Test-Path -LiteralPath $Script:SessionFile)) { return }
        $raw = Get-Content -LiteralPath $Script:SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($raw)) {
            if (-not $r -or -not $r.Title) { continue }
            [void]$Script:SessionLog.Add([pscustomobject]@{ Time = [string]$r.Time; Engine = [string]$r.Engine; Title = [string]$r.Title; Code = [string]$r.Code; Fail = [int]$r.Fail; Warn = [int]$r.Warn; Ok = @($r.Ok | Where-Object { $_ }); Bad = @($r.Bad | Where-Object { $_ }); Reboot = [bool]$r.Reboot; Include = $true })
        }
    } catch { Write-Crash ("Lecture session : " + $_.Exception.Message) }
}

function Add-SessionEntry {
    param($Run, $Res)
    if (-not $Run -or -not $Run.Title) { return }
    if ($Script:Sync.Cancel) { return }
    $ok = @(); $bad = @(); $reb = $false
    if ($Res -is [hashtable]) { $ok = @($Res.Ok); $bad = @($Res.Bad); $reb = [bool]$Res.Reboot }
    [void]$Script:SessionLog.Add([pscustomobject]@{ Time = (Get-Date -Format 'HH:mm'); Engine = [string]$Run.Engine; Title = [string]$Run.Title; Code = [string]$Run.Code; Fail = [int]$Script:RunFlags.Fail; Warn = [int]$Script:RunFlags.Warn; Ok = $ok; Bad = $bad; Reboot = $reb; Include = $true })
    Save-SessionLog
    try { Refresh-SummaryList } catch {}
}

# ---------------------------------------------------------------- Avatar
function New-AvShape {
    param([string]$Kind, [double]$W, [double]$H, [double]$X, [double]$Y, [string]$Fill, [double]$Radius = 0, [string]$Stroke = '', [double]$StrokeW = 0)
    $s = if ($Kind -eq 'ellipse') { New-Object Windows.Shapes.Ellipse } else { New-Object Windows.Shapes.Rectangle }
    $s.Width = $W; $s.Height = $H
    if ($Radius -gt 0 -and $Kind -ne 'ellipse') { $s.RadiusX = $Radius; $s.RadiusY = $Radius }
    $s.Fill = (Br $Fill)
    if ($Stroke) { $s.Stroke = (Br $Stroke); $s.StrokeThickness = $StrokeW }
    [Windows.Controls.Canvas]::SetLeft($s, $X)
    [Windows.Controls.Canvas]::SetTop($s, $Y)
    return $s
}

function New-Avatar {
    $cv = New-Object Windows.Controls.Canvas
    $cv.Width = 300; $cv.Height = 330
    $root = New-Object Windows.Controls.Canvas
    $root.Width = 300; $root.Height = 330
    $tr = New-Object Windows.Media.TranslateTransform
    $root.RenderTransform = $tr
    [void]$cv.Children.Add((New-AvShape 'ellipse' 150 16 75 308 '#26000000'))
    [void]$cv.Children.Add($root)
    $blue = '#3F7BF0'; $dark = '#2A55C4'; $face = '#F5F9FF'
    $armL = New-AvShape 'rect' 28 84 58 214 $dark 14
    $armR = New-AvShape 'rect' 28 84 214 214 $dark 14
    $rotL = New-Object Windows.Media.RotateTransform -ArgumentList 0, 14, 8
    $rotR = New-Object Windows.Media.RotateTransform -ArgumentList 0, 14, 8
    $armL.RenderTransform = $rotL; $armR.RenderTransform = $rotR
    [void]$root.Children.Add($armL); [void]$root.Children.Add($armR)
    [void]$root.Children.Add((New-AvShape 'rect' 136 92 82 206 $blue 34))
    [void]$root.Children.Add((New-AvShape 'ellipse' 34 34 133 232 '#FFFFFF'))
    [void]$root.Children.Add((New-AvShape 'ellipse' 18 18 141 240 '#FFB84D'))
    [void]$root.Children.Add((New-AvShape 'ellipse' 26 48 32 100 $dark))
    [void]$root.Children.Add((New-AvShape 'ellipse' 26 48 242 100 $dark))
    $line = New-Object Windows.Shapes.Rectangle
    $line.Width = 6; $line.Height = 30; $line.Fill = (Br $dark)
    [Windows.Controls.Canvas]::SetLeft($line, 147); [Windows.Controls.Canvas]::SetTop($line, 20)
    [void]$root.Children.Add($line)
    $ball = New-AvShape 'ellipse' 20 20 140 6 '#FFB84D'
    [void]$root.Children.Add($ball)
    $head = New-AvShape 'rect' 210 176 45 44 $blue 78
    try {
        $g = New-Object Windows.Media.RadialGradientBrush
        $g.GradientOrigin = New-Object Windows.Point -ArgumentList 0.35, 0.25
        [void]$g.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList ([Windows.Media.Color]::FromRgb(0x8F, 0xBE, 0xFF)), 0.0))
        [void]$g.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList ([Windows.Media.Color]::FromRgb(0x3F, 0x7B, 0xF0)), 1.0))
        $head.Fill = $g
    } catch {}
    [void]$root.Children.Add($head)
    [void]$root.Children.Add((New-AvShape 'rect' 170 118 65 72 $face 52))
    [void]$root.Children.Add((New-AvShape 'ellipse' 42 46 86 98 '#FFFFFF' 0 '#D5E2F7' 2))
    [void]$root.Children.Add((New-AvShape 'ellipse' 42 46 172 98 '#FFFFFF' 0 '#D5E2F7' 2))
    $pL = New-AvShape 'ellipse' 24 24 95 109 '#1E2A44'
    $pR = New-AvShape 'ellipse' 24 24 181 109 '#1E2A44'
    [void]$root.Children.Add($pL); [void]$root.Children.Add($pR)
    [void]$root.Children.Add((New-AvShape 'ellipse' 7 7 108 114 '#FFFFFF'))
    [void]$root.Children.Add((New-AvShape 'ellipse' 7 7 194 114 '#FFFFFF'))
    $lidL = New-AvShape 'rect' 46 0 84 96 $face
    $lidR = New-AvShape 'rect' 46 0 170 96 $face
    [void]$root.Children.Add($lidL); [void]$root.Children.Add($lidR)
    $browL = New-AvShape 'rect' 36 7 89 86 $dark 3
    $browR = New-AvShape 'rect' 36 7 175 86 $dark 3
    $bl = New-Object Windows.Media.RotateTransform -ArgumentList 0, 18, 3
    $br = New-Object Windows.Media.RotateTransform -ArgumentList 0, 18, 3
    $browL.RenderTransform = $bl; $browR.RenderTransform = $br
    [void]$root.Children.Add($browL); [void]$root.Children.Add($browR)
    [void]$root.Children.Add((New-AvShape 'ellipse' 30 18 70 150 '#66FF8FA3'))
    [void]$root.Children.Add((New-AvShape 'ellipse' 30 18 200 150 '#66FF8FA3'))
    $mouth = New-AvShape 'rect' 48 8 126 160 '#7A1F2B' 18
    $mouth.Visibility = 'Collapsed'
    [void]$root.Children.Add($mouth)
    $smile = New-Object Windows.Shapes.Path
    $smile.Data = [Windows.Media.Geometry]::Parse('M 122,164 Q 150,192 178,164')
    $smile.Stroke = (Br '#7A1F2B'); $smile.StrokeThickness = 6
    $smile.StrokeStartLineCap = 'Round'; $smile.StrokeEndLineCap = 'Round'
    [void]$root.Children.Add($smile)
    return @{ Canvas = $cv; Move = $tr; ArmL = $rotL; ArmR = $rotR; PupilL = $pL; PupilR = $pR; LidL = $lidL; LidR = $lidR; BrowL = $bl; BrowR = $br; BrowLEl = $browL; BrowREl = $browR; Mouth = $mouth; Smile = $smile; Ball = $ball }
}

function Update-Avatar {
    # t : secondes écoulées ; speaking : la voix parle ; mood : happy ou serious ; blink : 0 à 1 (clignement)
    param($Av, [double]$T, [bool]$Speaking, [string]$Mood, [double]$Blink)
    $Av.Move.Y = [Math]::Sin($T * 2.2) * 3
    $amp = 0.0
    if ($Speaking) { $amp = (0.35 + 0.65 * [Math]::Abs([Math]::Sin($T * 11.3))) * (0.6 + 0.4 * [Math]::Abs([Math]::Sin($T * 4.1))) }
    if ($Speaking) {
        $Av.Mouth.Height = 5 + 26 * $amp
        $Av.Mouth.Visibility = 'Visible'; $Av.Smile.Visibility = 'Collapsed'
    } else {
        $Av.Mouth.Visibility = 'Collapsed'; $Av.Smile.Visibility = 'Visible'
    }
    $swing = $(if ($Speaking) { 14 } else { 3 })
    $Av.ArmL.Angle = [Math]::Sin($T * 2.6) * $swing
    $Av.ArmR.Angle = -[Math]::Sin($T * 2.6 + 1.2) * $swing
    $dx = [Math]::Sin($T * 0.7) * 3; $dy = [Math]::Cos($T * 0.5) * 2
    [Windows.Controls.Canvas]::SetLeft($Av.PupilL, 95 + $dx); [Windows.Controls.Canvas]::SetTop($Av.PupilL, 109 + $dy)
    [Windows.Controls.Canvas]::SetLeft($Av.PupilR, 181 + $dx); [Windows.Controls.Canvas]::SetTop($Av.PupilR, 109 + $dy)
    $lid = 48 * $Blink
    $Av.LidL.Height = $lid; $Av.LidR.Height = $lid
    if ($Mood -eq 'serious') { $Av.BrowL.Angle = -10; $Av.BrowR.Angle = 10; $Av.Smile.Data = [Windows.Media.Geometry]::Parse('M 128,176 Q 150,168 172,176') }
    else { $Av.BrowL.Angle = 3 + [Math]::Sin($T * 1.3) * 3; $Av.BrowR.Angle = -3 - [Math]::Sin($T * 1.3) * 3; $Av.Smile.Data = [Windows.Media.Geometry]::Parse('M 122,164 Q 150,192 178,164') }
}

# ---------------------------------------------------------------- Voix
function Get-FrenchVoiceName {
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        try {
            $v = @($s.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'fr*' })
            if ($v.Count -eq 0) { return '' }
            $f = @($v | Where-Object { [string]$_.VoiceInfo.Gender -eq 'Female' } | Select-Object -First 1)
            if ($f.Count -gt 0 -and $f[0]) { return [string]$f[0].VoiceInfo.Name }
            return [string]$v[0].VoiceInfo.Name
        } finally { $s.Dispose() }
    } catch { return '' }
}

function New-Narrator {
    param([string]$VoiceName)
    if (-not $VoiceName) { return $null }
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $s.SelectVoice($VoiceName)
        $s.Rate = -1
        $s.Volume = 100
        return $s
    } catch { Write-Crash ("Voix : " + $_.Exception.Message); return $null }
}

# ---------------------------------------------------------------- Voix naturelle (en ligne)
$Script:NeuralCode = @'
# Synthèse vocale neuronale Azure (service officiel Microsoft Speech, avec la clé du technicien). Retourne le chemin du MP3.
param([string]$Text, [string]$Voice, [string]$OutFile, [string]$Key, [string]$Region)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$esc = [Security.SecurityElement]::Escape($Text)
$ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='fr-FR'><voice name='$Voice'><prosody rate='-4%'>$esc</prosody></voice></speak>"
$body = [Text.Encoding]::UTF8.GetBytes($ssml)
$req = [Net.HttpWebRequest]::Create("https://$Region.tts.speech.microsoft.com/cognitiveservices/v1")
$req.Method = 'POST'
$req.ContentType = 'application/ssml+xml'
$req.UserAgent = 'BJMPC-Toolbox'
$req.Timeout = 20000
$req.ReadWriteTimeout = 20000
$req.Headers.Add('Ocp-Apim-Subscription-Key', $Key)
$req.Headers.Add('X-Microsoft-OutputFormat', 'audio-24khz-48kbitrate-mono-mp3')
$req.ContentLength = $body.Length
try {
    $st = $req.GetRequestStream(); $st.Write($body, 0, $body.Length); $st.Close()
    $resp = $req.GetResponse()
} catch [Net.WebException] {
    $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    switch ($code) {
        401 { throw 'Clé Azure refusée (401) : vérifiez la clé et la région.' }
        403 { throw 'Accès refusé (403) : clé ou région incorrecte, ou quota dépassé.' }
        429 { throw 'Trop de demandes (429) ou quota mensuel atteint.' }
        default { throw ('Service injoignable : ' + $_.Exception.Message) }
    }
}
try {
    $ms = New-Object IO.MemoryStream
    $rs = $resp.GetResponseStream(); $rs.CopyTo($ms); $rs.Close()
} finally { $resp.Close() }
if ($ms.Length -lt 800) { throw 'Aucun son reçu du service.' }
$tmp = $OutFile + '.part'
[IO.File]::WriteAllBytes($tmp, $ms.ToArray())
Move-Item -LiteralPath $tmp -Destination $OutFile -Force
return $OutFile
'@

$Script:NeuralVoices = [ordered]@{ 'fr-FR-DeniseNeural' = 'Denise (douce)'; 'fr-FR-VivienneMultilingualNeural' = 'Vivienne (très naturelle)'; 'fr-FR-HenriNeural' = 'Henri (voix d''homme)' }
$Script:AzureFile = Join-Path $env:APPDATA 'BJMPC\voix_azure.xml'
$Script:NeuralDir = Join-Path ([IO.Path]::GetTempPath()) 'bjmpc_voix'

function Get-AzureConfig {
    # Clé protégée par Windows (lisible uniquement par ce compte sur ce PC).
    $r = @{ Key = ''; Region = 'francecentral' }
    try {
        if (Test-Path -LiteralPath $Script:AzureFile) {
            $x = Import-Clixml -LiteralPath $Script:AzureFile
            if ($x.Region) { $r.Region = [string]$x.Region }
            if ($x.Key) {
                $sec = ConvertTo-SecureString ([string]$x.Key)
                $r.Key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
            }
        }
    } catch {}
    return $r
}

function Save-AzureConfig {
    param([string]$Key, [string]$Region)
    $dir = Split-Path $Script:AzureFile
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $enc = ''
    if ($Key) { $enc = ConvertFrom-SecureString (ConvertTo-SecureString $Key -AsPlainText -Force) }
    [pscustomobject]@{ Region = $Region; Key = $enc } | Export-Clixml -LiteralPath $Script:AzureFile
}

function Get-NeuralFile {
    param([string]$Text, [string]$Voice)
    $sha = [Security.Cryptography.SHA1]::Create()
    $h = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Voice + '|' + $Text)) | ForEach-Object { $_.ToString('x2') })
    return (Join-Path $Script:NeuralDir ($h + '.mp3'))
}

function Start-NeuralJob {
    # Lance la synthèse d'une phrase en arrière-plan (jamais sur le fil de l'interface).
    param($N, [int]$Idx)
    if ($Idx -ge $N.Flat.Count -or $N.Jobs.ContainsKey($Idx)) { return }
    $text = [string]$N.Flat[$Idx].Text
    $file = Get-NeuralFile $text $N.NeuralVoice
    $job = @{ File = $file; PS = $null; Async = $null; State = 'pending'; Error = '' }
    if (Test-Path -LiteralPath $file) { $job.State = 'ready' }
    else {
        try {
            New-Item -ItemType Directory -Path $Script:NeuralDir -Force | Out-Null
            $ps = [PowerShell]::Create()
            [void]$ps.AddScript($Script:NeuralCode).AddArgument($text).AddArgument([string]$N.NeuralVoice).AddArgument($file).AddArgument([string]$N.AzureKey).AddArgument([string]$N.AzureRegion)
            $job.PS = $ps
            $job.Async = $ps.BeginInvoke()
        } catch { $job.State = 'failed'; $job.Error = $_.Exception.Message }
    }
    $N.Jobs[$Idx] = $job
}

function Get-NeuralState {
    param($N, [int]$Idx)
    $job = $N.Jobs[$Idx]
    if (-not $job) { return 'failed' }
    if ($job.State -eq 'pending' -and $job.Async -and $job.Async.IsCompleted) {
        try {
            [void]$job.PS.EndInvoke($job.Async)
            if (Test-Path -LiteralPath $job.File) { $job.State = 'ready' } else { $job.State = 'failed'; $job.Error = 'fichier absent' }
        } catch {
            $job.State = 'failed'
            $job.Error = $_.Exception.Message
            if ($_.Exception.InnerException) { $job.Error = $_.Exception.InnerException.Message }
        }
        try { $job.PS.Dispose() } catch {}
        $job.PS = $null
    }
    return [string]$job.State
}

function Get-SelectedNeuralVoice {
    try { $i = $Script:SumUi.NeuralVoice.SelectedItem; if ($i -and $i.Tag) { return [string]$i.Tag } } catch {}
    return 'fr-FR-DeniseNeural'
}

function Stop-NarrAudio {
    param($N)
    if ($N.Player) { try { $N.Player.Stop() } catch {} }
}

# ---------------------------------------------------------------- Fenêtre animée
$Script:SummaryXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Résumé de l'intervention" Width="1120" Height="700" MinWidth="820" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#FFF6EA" FontFamily="Segoe UI">
  <Grid Margin="30">
    <Grid.ColumnDefinitions><ColumnDefinition Width="360"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Viewbox Grid.Column="0" Grid.Row="0" VerticalAlignment="Center" Stretch="Uniform"><ContentControl x:Name="AvatarHost" Width="300" Height="330"/></Viewbox>
    <StackPanel Grid.Column="1" Grid.Row="0" VerticalAlignment="Center" Margin="14,0,0,0">
      <TextBlock x:Name="SceneTitle" FontSize="22" FontWeight="SemiBold" Foreground="#2A55C4" Margin="10,0,0,14"/>
      <Border Background="White" CornerRadius="28" Padding="34,28" BorderBrush="#F0E3D2" BorderThickness="2" MinHeight="200">
        <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.15"/></Border.Effect>
        <TextBlock x:Name="Bubble" FontSize="30" LineHeight="42" TextWrapping="Wrap" Foreground="#2B2F3A"/>
      </Border>
      <TextBlock x:Name="Note" FontSize="13" Foreground="#8A7F72" Margin="10,14,0,0" TextWrapping="Wrap"/>
    </StackPanel>
    <Grid Grid.Row="1" Grid.ColumnSpan="2" Margin="0,24,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <ProgressBar x:Name="Prog" Grid.Column="0" Height="8" VerticalAlignment="Center" Margin="0,0,24,0" Foreground="#3F7BF0" Background="#EADFCF" BorderThickness="0"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="BtnPause" Content="Pause" Padding="22,10" Margin="0,0,10,0" FontSize="15"/>
        <Button x:Name="BtnNext" Content="Suivant" Padding="22,10" Margin="0,0,10,0" FontSize="15"/>
        <Button x:Name="BtnReplay" Content="Rejouer" Padding="22,10" Margin="0,0,10,0" FontSize="15"/>
        <Button x:Name="BtnFull" Content="Plein écran" Padding="22,10" Margin="0,0,10,0" FontSize="15"/>
        <Button x:Name="BtnClose" Content="Fermer" Padding="22,10" FontSize="15"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$Script:Narr = $null

function Start-NarrFallback {
    # Voix de l'ordinateur (hors ligne), ou simple sous-titre chronométré.
    param($N, $It)
    $N.Mode = 'text'
    $N.Prompt = $null
    if ($N.Synth) {
        try { $N.Prompt = $N.Synth.SpeakAsync([string]$It.Text); $N.Mode = 'sapi' }
        catch { Write-Crash ("Voix : " + $_.Exception.Message); try { $N.Synth.Dispose() } catch {}; $N.Synth = $null }
    }
    if (-not $N.Prompt) { $N.Until = (Get-Date).AddSeconds([Math]::Max(2.5, ([string]$It.Text).Length / 13.0)) }
}

function Start-NarrSentence {
    $n = $Script:Narr
    $it = $n.Flat[$n.Idx]
    $n.Ui.Bubble.Text = [string]$it.Text
    $n.Ui.SceneTitle.Text = [string]$it.Title
    $n.Mood = [string]$it.Mood
    $n.Ui.Prog.Value = $n.Idx
    $n.Prompt = $null
    $n.Mode = 'text'
    if ($n.Neural) {
        # Synthèse de cette phrase et des deux suivantes, pour éviter les silences.
        foreach ($k in 0, 1, 2) { Start-NeuralJob $n ($n.Idx + $k) }
        $n.Mode = 'wait'
        $n.WaitUntil = (Get-Date).AddSeconds($(if ($n.NeuralOk) { 8 } else { 14 }))
    } else { Start-NarrFallback $n $it }
    $n.Speaking = $true
}

function Step-Narr {
    $n = $Script:Narr
    if (-not $n) { return }
    $now = Get-Date
    $t = ($now - $n.T0).TotalSeconds
    if (-not $n.Paused) {
        if ($n.Speaking) {
            $done = $false
            if ($n.Mode -eq 'wait') {
                $st = Get-NeuralState $n $n.Idx
                if ($st -eq 'ready') {
                    try {
                        $n.Ended = $false; $n.PlayFailed = $false
                        $n.Player.Open([Uri]$n.Jobs[$n.Idx].File)
                        $n.Player.Play()
                        $n.Mode = 'play'; $n.PlayStart = $now
                    } catch { $st = 'failed'; $n.Jobs[$n.Idx].Error = $_.Exception.Message }
                }
                if ($st -eq 'failed' -or ($st -eq 'pending' -and $now -ge $n.WaitUntil)) {
                    $why = if ($st -eq 'failed') { [string]$n.Jobs[$n.Idx].Error } else { 'délai dépassé' }
                    $n.NeuralFallbacks++
                    if (-not $n.NeuralOk -or $n.NeuralFallbacks -ge 3) {
                        # Pas de connexion : on abandonne la voix en ligne pour tout le résumé.
                        $n.Neural = $false
                        $n.Ui.Note.Text = 'Voix naturelle indisponible (Internet, clé ou quota) : voix de l''ordinateur utilisée.'
                    }
                    Write-Crash ("Voix naturelle : " + $why)
                    Start-NarrFallback $n $n.Flat[$n.Idx]
                }
            } elseif ($n.Mode -eq 'play') {
                $dur = $null
                try { if ($n.Player.NaturalDuration.HasTimeSpan) { $dur = $n.Player.NaturalDuration.TimeSpan } } catch {}
                if ($n.PlayFailed) {
                    $n.NeuralFallbacks++; $n.Neural = $false
                    $n.Ui.Note.Text = 'Lecture de la voix naturelle impossible : voix de l''ordinateur utilisée.'
                    Start-NarrFallback $n $n.Flat[$n.Idx]
                } elseif ($n.Ended -or ($dur -and $n.Player.Position -ge ($dur - [TimeSpan]::FromMilliseconds(60))) -or (($now - $n.PlayStart).TotalSeconds -gt 90)) {
                    $done = $true
                    if (-not $n.NeuralOk) { $n.NeuralOk = $true; $n.Ui.Note.Text = 'Voix naturelle (Azure).' }
                    $n.NeuralPlayed++
                }
            } elseif ($n.Prompt) { $done = [bool]$n.Prompt.IsCompleted } else { $done = ($now -ge $n.Until) }
            if ($done) { $n.Speaking = $false; $n.GapUntil = $now.AddMilliseconds(500) }
        } elseif (-not $n.Finished -and $now -ge $n.GapUntil) {
            $n.Idx++
            if ($n.Idx -ge $n.Flat.Count) {
                $n.Finished = $true
                $n.Ui.Bubble.Text = 'Fin du résumé. Merci !'
                $n.Ui.Prog.Value = $n.Flat.Count
                $n.Ui.BtnPause.IsEnabled = $false
            } else { Start-NarrSentence }
        }
    }
    # clignement des yeux, toutes les 2 à 5 secondes
    if ($now -ge $n.NextBlink) { $n.BlinkStart = $now; $n.NextBlink = $now.AddSeconds(2 + $n.Rng.NextDouble() * 3) }
    $p = ($now - $n.BlinkStart).TotalSeconds / 0.18
    $blink = 0.0
    if ($p -ge 0 -and $p -le 1) { $blink = 1 - [Math]::Abs(2 * $p - 1) }
    Update-Avatar $n.Av $t ([bool]($n.Speaking -and -not $n.Paused -and -not $n.Finished)) $n.Mood $blink
}

function Stop-Narr {
    $n = $Script:Narr
    if (-not $n) { return }
    try { $n.Timer.Stop() } catch {}
    if ($n.Synth) { try { $n.Synth.SpeakAsyncCancelAll() } catch {}; try { $n.Synth.Dispose() } catch {} }
    foreach ($j in @($n.Jobs.Values)) { if ($j.PS) { try { [void]$j.PS.BeginStop($null, $null) } catch {} } }
    if ($n.Player) { try { $n.Player.Stop(); $n.Player.Close() } catch {} }
    $Script:NarrStats = @{ Played = [int]$n.NeuralPlayed; Fallbacks = [int]$n.NeuralFallbacks }
    # Les fichiers audio contiennent le texte du résumé : on les efface.
    try { if (Test-Path -LiteralPath $Script:NeuralDir) { Get-ChildItem -LiteralPath $Script:NeuralDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } } catch {}
    $Script:Narr = $null
}

function Show-SummaryWindow {
    param($Scenes, [bool]$UseVoice = $true, [int]$AutoCloseSeconds = 0, [bool]$UseNeural = $false, [string]$NeuralVoice = 'fr-FR-DeniseNeural')
    $flat = New-Object 'System.Collections.Generic.List[object]'
    foreach ($sc in $Scenes) { foreach ($l in $sc.Lines) { [void]$flat.Add([pscustomobject]@{ Title = [string]$sc.Title; Mood = [string]$sc.Mood; Text = [string]$l }) } }
    if ($flat.Count -eq 0) { return }
    if ($Script:Narr) { Stop-Narr }
    $w = [Windows.Markup.XamlReader]::Parse($Script:SummaryXaml)
    $ui = @{}
    foreach ($nm in 'AvatarHost', 'SceneTitle', 'Bubble', 'Note', 'Prog', 'BtnPause', 'BtnNext', 'BtnReplay', 'BtnFull', 'BtnClose') { $ui[$nm] = $w.FindName($nm) }
    $av = New-Avatar
    $ui.AvatarHost.Content = $av.Canvas
    $ui.Prog.Maximum = $flat.Count
    $voice = ''
    $synth = $null
    if ($UseVoice) {
        $voice = Get-FrenchVoiceName
        if ($voice) { $synth = New-Narrator $voice }
        if (-not $synth -and -not $UseNeural) { $ui.Note.Text = 'Aucune voix française n''est installée sur cet ordinateur : le résumé s''affiche en sous-titres.' }
    }
    $az = Get-AzureConfig
    $neuralOn = [bool]($UseVoice -and $UseNeural -and $az.Key)
    $player = $null
    if ($neuralOn) {
        try { $player = New-Object Windows.Media.MediaPlayer; $player.Volume = 1.0 } catch { $neuralOn = $false; $player = $null }
    }
    if ($neuralOn) { $ui.Note.Text = 'Préparation de la voix naturelle…' }
    $Script:Narr = @{
        Flat = $flat; Idx = 0; Ui = $ui; Av = $av; Synth = $synth; Prompt = $null; Until = $null; Speaking = $false; Paused = $false; Finished = $false
        Neural = $neuralOn; NeuralVoice = $NeuralVoice; AzureKey = $az.Key; AzureRegion = $az.Region; NeuralOk = $false; NeuralPlayed = 0; NeuralFallbacks = 0; Player = $player; Jobs = @{}; Mode = 'text'; WaitUntil = $null; PlayStart = $null; Ended = $false; PlayFailed = $false
        Mood = 'happy'; T0 = (Get-Date); GapUntil = (Get-Date); NextBlink = (Get-Date).AddSeconds(1.5); BlinkStart = (Get-Date).AddDays(-1)
        Rng = (New-Object Random); PausedAt = $null; Timer = $null
    }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(40)
    $Script:Narr.Timer = $timer
    $timer.Add_Tick({ try { Step-Narr } catch { Write-Crash ("Résumé : " + $_.Exception.ToString()); try { $Script:Narr.Timer.Stop() } catch {} } })
    $Script:Narr.Win = $w
    if ($player) {
        $player.Add_MediaEnded({ if ($Script:Narr) { $Script:Narr.Ended = $true } })
        $player.Add_MediaFailed({ if ($Script:Narr) { $Script:Narr.PlayFailed = $true } })
    }
    $ui.BtnPause.Add_Click({
        $n = $Script:Narr; if (-not $n -or $n.Finished) { return }
        if ($n.Paused) {
            $n.Paused = $false; $n.Ui.BtnPause.Content = 'Pause'
            $d = (Get-Date) - $n.PausedAt
            if ($n.Until) { $n.Until = $n.Until + $d }
            $n.GapUntil = $n.GapUntil + $d
            if ($n.WaitUntil) { $n.WaitUntil = $n.WaitUntil + $d }
            if ($n.Synth) { try { $n.Synth.Resume() } catch {} }
            if ($n.Player -and $n.Mode -eq 'play') { try { $n.Player.Play() } catch {} }
        } else {
            $n.Paused = $true; $n.PausedAt = Get-Date; $n.Ui.BtnPause.Content = 'Reprendre'
            if ($n.Synth) { try { $n.Synth.Pause() } catch {} }
            if ($n.Player -and $n.Mode -eq 'play') { try { $n.Player.Pause() } catch {} }
        }
    })
    $ui.BtnNext.Add_Click({
        $n = $Script:Narr; if (-not $n -or $n.Finished) { return }
        if ($n.Paused) { $n.Paused = $false; $n.Ui.BtnPause.Content = 'Pause'; if ($n.Synth) { try { $n.Synth.Resume() } catch {} } }
        if ($n.Synth) { try { $n.Synth.SpeakAsyncCancelAll() } catch {} }
        Stop-NarrAudio $n
        $n.Speaking = $false; $n.GapUntil = Get-Date
    })
    $ui.BtnReplay.Add_Click({
        $n = $Script:Narr; if (-not $n) { return }
        if ($n.Synth) { try { $n.Synth.SpeakAsyncCancelAll() } catch {}; try { $n.Synth.Resume() } catch {} }
        Stop-NarrAudio $n
        $n.Paused = $false; $n.Finished = $false; $n.Speaking = $false; $n.Idx = 0
        $n.Ui.BtnPause.IsEnabled = $true; $n.Ui.BtnPause.Content = 'Pause'
        Start-NarrSentence
    })
    $ui.BtnFull.Add_Click({
        $n = $Script:Narr; if (-not $n) { return }
        if ($n.Win.WindowState -eq 'Maximized') { $n.Win.WindowState = 'Normal'; $n.Ui.BtnFull.Content = 'Plein écran' } else { $n.Win.WindowState = 'Maximized'; $n.Ui.BtnFull.Content = 'Fenêtre' }
    })
    $ui.BtnClose.Add_Click({ if ($Script:Narr) { $Script:Narr.Win.Close() } })
    $w.Add_KeyDown({
        param($s, $e)
        $n = $Script:Narr; if (-not $n) { return }
        if ($e.Key -eq 'Escape') { $n.Win.Close() }
        elseif ($e.Key -eq 'Space' -and -not $n.Finished) {
            if ($n.Paused) {
                $n.Paused = $false; $n.Ui.BtnPause.Content = 'Pause'
                $d = (Get-Date) - $n.PausedAt
                if ($n.Until) { $n.Until = $n.Until + $d }
                $n.GapUntil = $n.GapUntil + $d
                if ($n.WaitUntil) { $n.WaitUntil = $n.WaitUntil + $d }
                if ($n.Synth) { try { $n.Synth.Resume() } catch {} }
                if ($n.Player -and $n.Mode -eq 'play') { try { $n.Player.Play() } catch {} }
            } else {
                $n.Paused = $true; $n.PausedAt = Get-Date; $n.Ui.BtnPause.Content = 'Reprendre'
                if ($n.Synth) { try { $n.Synth.Pause() } catch {} }
                if ($n.Player -and $n.Mode -eq 'play') { try { $n.Player.Pause() } catch {} }
            }
            $e.Handled = $true
        }
    })
    $w.Add_Closed({ Stop-Narr })
    if ($Script:Window -and $Script:Window.IsLoaded -and $AutoCloseSeconds -le 0) { try { $w.Owner = $Script:Window } catch {} }
    $timer.Start()
    Start-NarrSentence
    if ($AutoCloseSeconds -gt 0) {
        $closer = New-Object Windows.Threading.DispatcherTimer
        $closer.Interval = [TimeSpan]::FromSeconds($AutoCloseSeconds)
        $closer.Add_Tick({ $closer.Stop(); $w.Close() }.GetNewClosure())
        $closer.Start()
    }
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------- Page « Résumé client »
$Script:SumUi = @{}

function Get-DemoEntries {
    $e = @(
        @{ Engine = 'maint'; Title = 'SFC'; Code = 'Invoke-SFC' },
        @{ Engine = 'opt'; Title = 'Réglages : Télémétrie et diagnostics'; Code = '' },
        @{ Engine = 'opt'; Title = 'Réglages : Publicités, recherche et suggestions'; Code = '' },
        @{ Engine = 'opt'; Title = 'DNS Quad9'; Code = 'Set-DnsPreset -Provider quad9' },
        @{ Engine = 'tools'; Title = 'Nettoyage de disque Windows'; Code = 'Invoke-DiskCleanup' },
        @{ Engine = 'tools'; Title = 'Caches des navigateurs'; Code = 'Clear-BrowserCaches' }
    )
    return @($e | ForEach-Object { [pscustomobject]@{ Time = ''; Engine = $_.Engine; Title = $_.Title; Code = $_.Code; Fail = 0; Warn = 0; Ok = @(); Bad = @(); Include = $true } })
}

function Get-SummaryScenesFromUi {
    param([bool]$Demo = $false)
    $entries = if ($Demo) { Get-DemoEntries } else { @($Script:SessionLog) }
    $reboot = [bool]$Script:Sync.Reboot
    return (New-SummaryScenes $entries $Script:SumUi.Client.Text $Script:SumUi.Company.Text $Script:SumUi.Assistant.Text $reboot)
}

function Refresh-SummaryList {
    if (-not $Script:SumUi.List) { return }
    $Script:SumUi.List.Children.Clear()
    if ($Script:SessionLog.Count -eq 0) {
        [void]$Script:SumUi.List.Children.Add((New-Text 'Aucune opération pour le moment. Faites vos interventions, puis revenez ici.' 13 '#9298A3' 'Normal' -Wrap))
        return
    }
    $i = 0
    foreach ($e in $Script:SessionLog) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Margin = '0,8,0,0'
        $cb.IsChecked = [bool]$e.Include
        $cb.Tag = $e
        $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        [void]$sp.Children.Add((New-Text ("{0}  {1}" -f $e.Time, $e.Title) 14 '#ECEDEF'))
        $p = Get-PlainEntry $e
        if ([int]$e.Fail -gt 0) { [void]$sp.Children.Add((New-Tag 'Échec : sera signalé à revoir' 'r')) }
        elseif ([int]$e.Warn -gt 0) { [void]$sp.Children.Add((New-Tag 'Avertissements : sera signalé à revoir (décochez si sans importance)' 'w')) }
        if (-not $p) { [void]$sp.Children.Add((New-Tag 'Non raconté (technique)' 'n')) }
        elseif ($p.Cat -eq 'unknown') { [void]$sp.Children.Add((New-Tag 'Sans phrase prévue' 'n')) }
        $cb.Content = $sp
        $cb.Add_Click({ param($s, $ev) $s.Tag.Include = [bool]$s.IsChecked; try { Update-SummaryPreview } catch {} })
        [void]$Script:SumUi.List.Children.Add($cb)
        $i++
    }
    Update-SummaryPreview
}

function Update-SummaryPreview {
    if (-not $Script:SumUi.Preview) { return }
    $Script:SumUi.Preview.Text = Get-SummaryText (Get-SummaryScenesFromUi)
}

function Build-Summary {
    $p = New-Page 'summary' 'Résumé pour le client' 'Un personnage animé explique au client, avec une voix et des mots simples, ce qui a été fait sur son ordinateur. À lancer en fin d''intervention.'
    $c = New-Card 'Préparer le résumé' 'Ces trois champs personnalisent le message. Tout est facultatif.'
    function New-SumBox { param([string]$Label, [string]$Value) 
        [void]$c.Body.Children.Add((New-Text $Label 12 '#9298A3'))
        $t = New-Object Windows.Controls.TextBox
        $t.Text = $Value; $t.Margin = '0,4,0,10'; $t.Padding = '8,6'; $t.FontSize = 13; $t.MaxLength = 60
        $t.Background = (Br '#15171C'); $t.Foreground = (Br '#ECEDEF'); $t.BorderBrush = (Br '#2A2E36'); $t.CaretBrush = (Br '#ECEDEF')
        $t.Add_TextChanged({ try { Update-SummaryPreview } catch {} })
        [void]$c.Body.Children.Add($t)
        return $t
    }
    $Script:SumUi.Client = New-SumBox 'Prénom du client' ''
    $Script:SumUi.Company = New-SumBox 'Votre entreprise' 'BJMPC Informatique'
    $Script:SumUi.Assistant = New-SumBox 'Prénom du personnage' 'Mia'
    $Script:SumUi.Voice = New-Check 'Activer la voix' $true
    [void]$c.Body.Children.Add($Script:SumUi.Voice)
    $azc = Get-AzureConfig
    $Script:SumUi.Neural = New-Check 'Voix naturelle Azure (Internet requis)' ([bool]$azc.Key)
    [void]$c.Body.Children.Add($Script:SumUi.Neural)
    $row = New-Object Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '26,2,0,6'
    $lbl = New-Text 'Voix :' 13 '#C5C9D0' 'Normal'; $lbl.VerticalAlignment = 'Center'; $lbl.Margin = '0,0,10,0'
    [void]$row.Children.Add($lbl)
    $cb = New-Object Windows.Controls.ComboBox; $cb.MinWidth = 240; $cb.Padding = '8,4'
    foreach ($k in $Script:NeuralVoices.Keys) { $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $Script:NeuralVoices[$k]; $it.Tag = $k; [void]$cb.Items.Add($it) }
    $cb.SelectedIndex = 0
    $Script:SumUi.NeuralVoice = $cb
    [void]$row.Children.Add($cb)
    [void]$c.Body.Children.Add($row)
    $krow = New-Object Windows.Controls.StackPanel; $krow.Orientation = 'Horizontal'; $krow.Margin = '26,0,0,6'
    $l2 = New-Text 'Clé :' 13 '#C5C9D0' 'Normal'; $l2.VerticalAlignment = 'Center'; $l2.Margin = '0,0,10,0'
    [void]$krow.Children.Add($l2)
    $pw = New-Object Windows.Controls.PasswordBox; $pw.MinWidth = 260; $pw.Padding = '8,4'; $pw.Margin = '0,0,10,0'
    if ($azc.Key) { $pw.Password = $azc.Key }
    $Script:SumUi.AzureKey = $pw
    [void]$krow.Children.Add($pw)
    $l3 = New-Text 'Région :' 13 '#C5C9D0' 'Normal'; $l3.VerticalAlignment = 'Center'; $l3.Margin = '0,0,10,0'
    [void]$krow.Children.Add($l3)
    $rg = New-Object Windows.Controls.TextBox; $rg.MinWidth = 130; $rg.Padding = '8,4'; $rg.Text = $azc.Region
    $Script:SumUi.AzureRegion = $rg
    [void]$krow.Children.Add($rg)
    [void]$c.Body.Children.Add($krow)
    $vn = Get-FrenchVoiceName
    $vt = if ($vn) { "Voix de secours (sans Internet ou sans clé) : $vn" } else { 'Aucune voix française installée sur l''ordinateur : sans Internet, le résumé sera affiché en sous-titres (Paramètres Windows, Heure et langue, Voix).' }
    [void]$c.Body.Children.Add((New-Text $vt 12 '#9298A3' 'Normal' -Wrap))
    [void]$c.Body.Children.Add((New-Text 'Voix naturelle : créez une ressource gratuite « Speech » sur portal.azure.com (offre F0, environ 500 000 caractères par mois), copiez la clé et la région ci-dessus. La clé est enregistrée chiffrée par Windows, pour ce compte seulement. Le texte du résumé (prénom du client compris) est envoyé à Microsoft Azure pour être transformé en voix, et n''est pas conservé sur le PC.' 12 '#9298A3' 'Normal' -Wrap))
    $bar = New-Object Windows.Controls.StackPanel; $bar.Orientation = 'Horizontal'; $bar.Margin = '0,14,0,0'
    $go = New-Btn 'Lancer le résumé animé' @{ Fn = {
            $sc = Get-SummaryScenesFromUi
            try {
                $k = ([string]$Script:SumUi.AzureKey.Password).Trim(); $r = ([string]$Script:SumUi.AzureRegion.Text).Trim().ToLower(); if (-not $r) { $r = 'francecentral' }
                $cur = Get-AzureConfig
                if ($k -ne $cur.Key -or $r -ne $cur.Region) { Save-AzureConfig $k $r }
            } catch {}
            Show-SummaryWindow $sc ([bool]$Script:SumUi.Voice.IsChecked) 0 ([bool]$Script:SumUi.Neural.IsChecked) (Get-SelectedNeuralVoice)
        } } -Primary
    $go.Margin = '0,0,0,0'
    [void]$bar.Children.Add($go)
    [void]$bar.Children.Add((New-Btn 'Enregistrer la clé' @{ Fn = {
                try {
                    $reg = ([string]$Script:SumUi.AzureRegion.Text).Trim().ToLower(); if (-not $reg) { $reg = 'francecentral' }
                    Save-AzureConfig ([string]$Script:SumUi.AzureKey.Password).Trim() $reg
                    $Script:SumUi.Neural.IsChecked = [bool]([string]$Script:SumUi.AzureKey.Password).Trim()
                    Add-Console 'Clé de la voix naturelle enregistrée (chiffrée pour ce compte Windows).' 'Green'
                } catch { Add-Console ("  [X]   Enregistrement de la clé impossible : " + $_.Exception.Message) 'Red' }
            } }))
    [void]$bar.Children.Add((New-Btn 'Tester la voix' @{ Fn = {
                $key = ([string]$Script:SumUi.AzureKey.Password).Trim(); $reg = ([string]$Script:SumUi.AzureRegion.Text).Trim().ToLower()
                if (-not $key) { Add-Console '  [X]   Entrez d''abord la clé Azure.' 'Red'; return }
                $f = Join-Path ([IO.Path]::GetTempPath()) 'bjmpc_test_voix.mp3'
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                try {
                    $ps = [PowerShell]::Create()
                    [void]$ps.AddScript($Script:NeuralCode).AddArgument('Bonjour, je suis votre assistante. Voici un test de ma voix.').AddArgument((Get-SelectedNeuralVoice)).AddArgument($f).AddArgument($key).AddArgument($reg)
                    $as = $ps.BeginInvoke()
                    $end = (Get-Date).AddSeconds(25)
                    while (-not $as.IsCompleted -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 100 }
                    if (-not $as.IsCompleted) { Add-Console '  [X]   Le service ne répond pas (délai dépassé).' 'Red'; return }
                    [void]$ps.EndInvoke($as)
                    $pl = New-Object Windows.Media.MediaPlayer
                    $pl.Open([Uri]$f); $pl.Play()
                    Add-Console 'Voix naturelle : test en cours de lecture.' 'Green'
                    $Script:TestPlayer = $pl
                } catch {
                    $m = $_.Exception.Message; if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
                    Add-Console ("  [X]   Test de la voix impossible : " + $m) 'Red'
                }
            } }))
    [void]$bar.Children.Add((New-Btn 'Voir un exemple' @{ Fn = { Show-SummaryWindow (Get-SummaryScenesFromUi $true) ([bool]$Script:SumUi.Voice.IsChecked) 0 ([bool]$Script:SumUi.Neural.IsChecked) (Get-SelectedNeuralVoice) } }))
    [void]$bar.Children.Add((New-Btn 'Copier le texte' @{ Fn = { try { [Windows.Clipboard]::SetText((Get-SummaryText (Get-SummaryScenesFromUi))); $Script:StatusText.Text = 'Texte copié' } catch { Add-Console ("  [X]   Copie impossible : " + $_.Exception.Message) 'Red' } } }))
    [void]$bar.Children.Add((New-Btn 'Enregistrer le texte' @{ Fn = {
                try {
                    $dir = Join-Path $Script:LogDir 'Rapports'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    $f = Join-Path $dir ("Resume_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
                    [IO.File]::WriteAllText($f, (Get-SummaryText (Get-SummaryScenesFromUi)), (New-Object Text.UTF8Encoding($true)))
                    Add-Console ("Résumé enregistré : " + $f) 'Green'
                    Start-Process explorer.exe "/select,`"$f`""
                } catch { Add-Console ("  [X]   Enregistrement impossible : " + $_.Exception.Message) 'Red' }
            } }))
    [void]$c.Body.Children.Add($bar)
    [void]$p.Children.Add($c.Card)

    $l = New-Card 'Ce qui sera raconté' 'Décochez ce que vous ne voulez pas évoquer devant le client. Les opérations purement techniques ne sont pas racontées.'
    $Script:SumUi.List = New-Object Windows.Controls.StackPanel
    $Script:SumUi.List.Margin = '0,8,0,0'
    [void]$l.Body.Children.Add($Script:SumUi.List)
    [void]$l.Body.Children.Add((New-Btn 'Actualiser' @{ Fn = { Refresh-SummaryList } }))
    [void]$p.Children.Add($l.Card)

    $v = New-Card 'Texte du résumé' 'Aperçu de ce que dira le personnage.'
    $Script:SumUi.Preview = New-Text '' 13 '#C5C9D0' 'Normal' -Wrap
    $Script:SumUi.Preview.Margin = '0,10,0,0'
    [void]$v.Body.Children.Add($Script:SumUi.Preview)
    [void]$p.Children.Add($v.Card)
    Import-SessionLog
    Refresh-SummaryList
}

function Test-SummarySelf {
    # Utilisé par l'auto-test : voix, textes, avatar et fenêtre (affichée quelques secondes).
    $o = @()
    $vn = Get-FrenchVoiceName
    $o += ("INFO   Voix française : " + $(if ($vn) { $vn } else { 'aucune' }))
    try {
        $sc = New-SummaryScenes (Get-DemoEntries) 'Marie' 'BJMPC Informatique' 'Mia' $true
        $n = 0; foreach ($s in $sc) { $n += @($s.Lines).Count }
        $o += ("OK     Textes du résumé  {0} scènes, {1} phrases" -f $sc.Count, $n)
    } catch { $o += ("ECHEC  Textes du résumé  " + $_.Exception.Message) }
    try {
        $av = New-Avatar
        foreach ($t in 0.0, 0.5, 1.7) { Update-Avatar $av $t $true 'happy' 0.5 }
        Update-Avatar $av 2.0 $false 'serious' 0
        $o += 'OK     Avatar construit et animé'
    } catch { $o += ("ECHEC  Avatar  " + $_.Exception.ToString()) }
    try {
        if ($vn) {
            $s = New-Narrator $vn
            $s.Volume = 40
            $pr = $s.SpeakAsync('Test de la voix.')
            $end = (Get-Date).AddSeconds(8)
            while (-not $pr.IsCompleted -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 100 }
            $o += ("{0} Voix  parole terminée: {1}" -f $(if ($pr.IsCompleted) { 'OK    ' } else { 'ECHEC ' }), $pr.IsCompleted)
            $s.Dispose()
        }
    } catch { $o += ("ECHEC  Voix  " + $_.Exception.Message) }
    try {
        Show-SummaryWindow (New-SummaryScenes (Get-DemoEntries) 'Marie' 'BJMPC Informatique' 'Mia' $true) $false 4
        $o += 'OK     Fenêtre du résumé ouverte et fermée'
    } catch { $o += ("ECHEC  Fenêtre du résumé  " + $_.Exception.ToString()) }
    try {
        # Voix naturelle : synthèse réelle (si Internet) puis lecture dans la fenêtre pendant quelques secondes.
        $azc = Get-AzureConfig
        if (-not $azc.Key) { $o += 'INFO   Voix naturelle : aucune clé Azure enregistrée (voix de l''ordinateur utilisée)' }
        else {
            $f = Join-Path ([IO.Path]::GetTempPath()) 'bjmpc_selftest_voix.mp3'
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            $ps = [PowerShell]::Create()
            [void]$ps.AddScript($Script:NeuralCode).AddArgument('Test de la voix naturelle.').AddArgument('fr-FR-DeniseNeural').AddArgument($f).AddArgument($azc.Key).AddArgument($azc.Region)
            $as = $ps.BeginInvoke()
            $end = (Get-Date).AddSeconds(25)
            while (-not $as.IsCompleted -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 150 }
            if ($as.IsCompleted) {
                try { [void]$ps.EndInvoke($as); $o += ("OK     Voix naturelle : synthèse {0} octets" -f (Get-Item -LiteralPath $f).Length) }
                catch { $m = $_.Exception.Message; if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }; $o += ("INFO   Voix naturelle indisponible : " + $m) }
            } else { $o += 'INFO   Voix naturelle : délai dépassé (25 s)'; try { [void]$ps.BeginStop($null, $null) } catch {} }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            Show-SummaryWindow (New-SummaryScenes (Get-DemoEntries) 'Marie' 'BJMPC Informatique' 'Mia' $true) $true 14 $true 'fr-FR-DeniseNeural'
            $st = $Script:NarrStats
            if ($st) { $o += ("INFO   Voix naturelle dans la fenêtre : {0} phrase(s) lue(s), {1} repli(s)" -f $st.Played, $st.Fallbacks) }
        }
    } catch { $o += ("ECHEC  Voix naturelle  " + $_.Exception.ToString()) }
    return $o
}

#endregion

# ================================================================ DÉMARRAGE
#region Démarrage

try {
    # Six sections ; chaque onglet est une page (clé de page, libellé).
    Add-Section 'home' 'Accueil' ([string][char]0xE80F) @(@('dash', 'Vue d''ensemble'), @('summary', 'Résumé pour le client'))
    Add-Section 'repair' 'Réparer' ([string][char]0xE90F) @(@('events', 'Réparation automatique'), @('maint', 'Réparer Windows'), @('care', 'Nettoyage et dépannage'), @('tools', 'Diagnostics'))
    Add-Section 'optim' 'Optimiser' ([string][char]0xE945) @(@('gaming', 'Jeux et alimentation'), @('net', 'Réseau et DNS'), @('sys', 'Disque et démarrage'), @('display', 'Affichage et OLED'))
    Add-Section 'settings' 'Confidentialité et réglages' ([string][char]0xE72E) @(@('priv', 'Confidentialité'), @('ui', 'Interface et Explorateur'), @('winset', 'Mises à jour et sécurité'))
    Add-Section 'soft' 'Logiciels et pilotes' ([string][char]0xE71D) @(@('apps', 'Applications'), @('drivers', 'Pilotes'))
    Add-Section 'backup' 'Sauvegarde et restauration' ([string][char]0xE81C) @(@('files', 'Sauvegarde des fichiers'), @('journal', 'Restauration'))

    Build-Dashboard
    Build-Summary
    Build-Events
    Build-Maintenance
    Build-Tools
    Build-Gaming
    Build-Network
    Build-System
    Build-Display
    Build-Privacy
    Build-Interface
    Build-WinSettings
    Build-Apps
    Build-Drivers
    Build-Backup
    Build-Journal
} catch {
    Show-Fatal "Construction de l'interface impossible : $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    exit 1
}

$Script:Window.FindName('BtnCancel').Add_Click({
    $r = [Windows.MessageBox]::Show($Script:Window, "Interrompre l'opération en cours ?`nUne commande système (DISM, SFC, CHKDSK) déjà lancée peut continuer en arrière-plan jusqu'à sa fin.", 'BJMPC Toolbox', 'YesNo', 'Warning')
    if ($r -eq 'Yes') { Stop-Run }
})
$Script:Window.FindName('BtnReboot').Add_Click({
    $r = [Windows.MessageBox]::Show($Script:Window, "Redémarrer le PC maintenant ?`nEnregistrez d'abord vos documents ouverts.", 'BJMPC Toolbox', 'YesNo', 'Question')
    if ($r -eq 'Yes') { Add-Console 'Redémarrage demandé.' 'Yellow'; Restart-Computer -Force }
})
$Script:Window.FindName('BtnClear').Add_Click({ $Script:Console.Document.Blocks.Clear() })
function Get-ConsoleText {
    $doc = $Script:Console.Document
    return (New-Object Windows.Documents.TextRange($doc.ContentStart, $doc.ContentEnd)).Text
}
$Script:Window.FindName('BtnCopy').Add_Click({
    try { [Windows.Clipboard]::SetText((Get-ConsoleText)); $Script:StatusText.Text = 'Sortie copiée dans le presse-papiers' } catch { Add-Console ("  [X]   Copie impossible : " + $_.Exception.Message) 'Red' }
})
$Script:Window.FindName('BtnSave').Add_Click({
    try {
        $dir = Join-Path $Script:LogDir 'Rapports'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $f = Join-Path $dir ("Console_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Set-Content -Path $f -Value (Get-ConsoleText) -Encoding UTF8
        Add-Console ("Sortie enregistrée : " + $f) 'Green'
        Start-Process explorer.exe "/select,`"$f`""
    } catch { Add-Console ("  [X]   Enregistrement impossible : " + $_.Exception.Message) 'Red' }
})
$Script:Window.FindName('BtnLogs').Add_Click({ try { Start-Process explorer.exe $Script:LogDir } catch {} })

$Script:Window.Add_Closing({
    param($s, $e)
    if ($Script:Run) {
        $r = [Windows.MessageBox]::Show($Script:Window, "Une opération est en cours. La fermer maintenant peut laisser une réparation inachevée.`nFermer quand même ?", 'BJMPC Toolbox', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true } else { $Script:Sync.Cancel = $true; [void]$Script:Sync.PromptEvent.Set() }
    }
    if (-not $e.Cancel) { try { Stop-EventWatch } catch {} }
})

$Script:Window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Write-Crash ($e.Exception.ToString())
    try { Add-Console ("  [X]   Erreur interne : " + $e.Exception.Message) 'Red' } catch {}
    $e.Handled = $true
})

$Script:Timer = New-Object Windows.Threading.DispatcherTimer
$Script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
$Script:Timer.Add_Tick({ try { Update-Ui } catch { Write-Crash $_.Exception.ToString() } })
$Script:Timer.Start()

Add-Console ("BJMPC Toolbox {0} · {1} · journal : {2}" -f $Script:AppVersion, $env:COMPUTERNAME, $Script:LogFile) 'Cyan'
if ($Script:EngineError) {
    Add-Console ("  [X]   " + $Script:EngineError) 'Red'
    Add-Console "  Placez tous les fichiers BJMPC-*-Win11.ps1 (Maintenance, Optimisation, Réglages, Outils, Sauvegarde) dans le même dossier que BJMPC-Toolbox.ps1." 'Yellow'
}

$startKey = 'dash'
if ($env:BJMPC_SELFTEST -eq 'PREVIEW' -and $env:BJMPC_PAGE -and $Script:NavItems.ContainsKey($env:BJMPC_PAGE)) { $startKey = $env:BJMPC_PAGE }
Open-Page $startKey
if ($env:BJMPC_SELFTEST -eq 'PREVIEW' -and $env:BJMPC_DEMO) {
    $Script:DemoTimer = New-Object Windows.Threading.DispatcherTimer
    $Script:DemoTimer.Interval = [TimeSpan]::FromSeconds(2)
    $Script:DemoTimer.Add_Tick({ $Script:DemoTimer.Stop(); try { Show-SummaryWindow (Get-SummaryScenesFromUi $true) $true } catch { Write-Crash $_.Exception.ToString() } })
    $Script:Window.Add_ContentRendered({ $Script:DemoTimer.Start() })
}
$Script:Window.Add_ContentRendered({ if (-not $Script:Started) { $Script:Started = $true; if (-not $Script:EngineError) { Refresh-Dashboard } } })


# ---------------------------------------------------------------- Auto-test (BJMPC_SELFTEST) : lecture seule, aucune modification du système
if ($env:BJMPC_SELFTEST -and $env:BJMPC_SELFTEST -ne 'PREVIEW') {
    $Script:SessionFile = Join-Path ([IO.Path]::GetTempPath()) 'bjmpc_selftest_session.json'
    $out = New-Object 'System.Collections.Generic.List[string]'
    function T { param([string]$Name, [bool]$Ok, [string]$Detail = '') $out.Add(("{0,-6} {1}  {2}" -f $(if ($Ok) { 'OK' } else { 'ECHEC' }), $Name, $Detail)) }
    function Wait-Run { param([int]$Sec = 90)
        $end = (Get-Date).AddSeconds($Sec)
        while ($Script:Run -and (Get-Date) -lt $end) {
            $Script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
            $it = $null
            while ($Script:Sync.Queue.TryDequeue([ref]$it)) { if ($it.K -eq 'prompt') { $Script:Sync.PromptAnswer = 'no'; [void]$Script:Sync.PromptEvent.Set() } }
            if ($Script:Run -and $Script:Run.Handle.IsCompleted) { Complete-Run }
            Start-Sleep -Milliseconds 60
        }
        return (-not $Script:Run)
    }
    if ($env:BJMPC_SHOTS) {
        # Captures de chaque page dans le dossier BJMPC_SHOTS, sans afficher la fenêtre : pour relire l'interface
        # après une modification. Lecture seule, puis on quitte sans lancer le reste de l'auto-test.
        try {
            New-Item -ItemType Directory -Path $env:BJMPC_SHOTS -Force | Out-Null
            $w = 1320; $h = 1500
            $root = $Script:Window.Content
            foreach ($k in @($Script:NavItems.Keys | Sort-Object)) {
                Open-Page $k
                if ($k -eq 'dash') { Refresh-Dashboard }
                [void](Wait-Run 120)
                $root.Measure([Windows.Size]::new($w, $h)); $root.Arrange([Windows.Rect]::new(0, 0, $w, $h)); $root.UpdateLayout()
                $Script:Window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::ContextIdle)
                $dv = New-Object Windows.Media.DrawingVisual
                $dc = $dv.RenderOpen(); $dc.DrawRectangle((Br '#050506'), $null, [Windows.Rect]::new(0, 0, $w, $h)); $dc.Close()
                $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                $bmp.Render($dv); $bmp.Render($root)
                $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                [void]$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
                $fs = [IO.File]::Create((Join-Path $env:BJMPC_SHOTS ("{0}_{1}.png" -f [string]$Script:PageSection[$k], $k)))
                try { $enc.Save($fs) } finally { $fs.Dispose() }
            }
        } catch { Write-Crash ("Captures : " + $_.Exception.ToString()); [IO.File]::WriteAllText($env:BJMPC_SELFTEST, ("ECHEC  Captures  " + $_.Exception.ToString())) ; exit 1 }
        [IO.File]::WriteAllText($env:BJMPC_SELFTEST, 'OK     Captures')
        exit 0
    }
    try {
        T 'PowerShell' $true ($PSVersionTable.PSVersion.ToString())
        T 'Moteurs chargés' (-not $Script:EngineError) ([string]$Script:EngineError)
        T 'Catalogues' (-not $Script:CatalogError -and $Script:TweakCatalog.Count -gt 50 -and $Script:AppCatalog.Count -gt 300) ("réglages={0} apps={1} {2}" -f $Script:TweakCatalog.Count, $Script:AppCatalog.Count, $Script:CatalogError)
        T 'Pages' ($Script:Pages.Count -ge 15 -and $Script:Sections.Count -eq 6) ("pages={0} onglets={1} sections={2}" -f $Script:Pages.Count, $Script:NavItems.Count, $Script:Sections.Count)
        foreach ($k in @($Script:Pages.Keys | Sort-Object)) { if (-not $Script:NavItems.ContainsKey($k)) { T "Navigation $k" $false 'page sans onglet' } }
        foreach ($k in @($Script:NavItems.Keys | Sort-Object)) { if (-not $Script:Pages.ContainsKey($k)) { T "Navigation $k" $false 'onglet sans page' } }
        # Chaque onglet s'ouvre et affiche bien sa page
        $navBad = @()
        foreach ($k in @($Script:NavItems.Keys | Sort-Object)) {
            Open-Page $k
            if ($Script:CurrentPage -ne $k -or [string]$Script:Pages[$k].Visibility -ne 'Visible' -or $Script:CurrentSection -ne [string]$Script:PageSection[$k]) { $navBad += $k }
            [void](Wait-Run 60)
        }
        Open-Page 'dash'; [void](Wait-Run 60)
        T 'Ouverture de chaque onglet' ($navBad.Count -eq 0) ($navBad -join ', ')
        # Chaque bouton : spécification valide, code analysable, fonctions existantes dans le moteur
        $bad = 0; $n = 0
        foreach ($b in $Script:ActionButtons) {
            $sp = $b.Tag; $n++
            if (-not $sp) { $bad++; $out.Add("   bouton sans action : $($b.Content)"); continue }
            if ($sp.Fn) { continue }
            $code = [string]$sp.Code
            try { if ($sp.CodeFn) { $code = [string](& $sp.CodeFn) } } catch { $bad++; $out.Add("   CodeFn en erreur ($($b.Content)) : $($_.Exception.Message)"); continue }
            if (-not $code.Trim()) { continue }
            $eng = [string]$sp.Engine
            $e = $null; $ast = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$e)
            if ($e -and $e.Count) { $bad++; $out.Add("   code invalide ($($b.Content)) : $($e[0].Message)"); continue }
            foreach ($c in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] }, $true)) {
                $cn = $c.GetCommandName()
                if ($cn -and $Script:EngineCode[$eng] -notmatch ("(?m)^function " + [regex]::Escape($cn) + "\b") -and -not (Get-Command $cn -ErrorAction SilentlyContinue)) { $bad++; $out.Add("   fonction introuvable ($($b.Content)) : $cn dans '$eng'") }
            }
        }
        T 'Boutons' ($bad -eq 0) ("{0} boutons, {1} problème(s)" -f $n, $bad)
        # Exécutions réelles en lecture seule dans le runspace de l'application
        foreach ($case in @(@('tools', 'Get-LicenseInfo'), @('tools', 'Get-StartupItems'), @('tools', 'Get-StorageHealth'), @('tools', 'Get-SecurityAudit'), @('opt', 'Show-State'), @('opt', 'Show-HardwareProfile'))) {
            $Script:RecentLines.Clear(); $Script:Sync.Result = $null
            Start-Run -Engine $case[0] -Code $case[1] -Title ''
            $done = Wait-Run 120
            T ("Exécution " + $case[1]) $done ''
        }
        Start-Run -Engine 'tools' -Code 'Get-BloatApps' -Title '' -OnDone { param($r) Show-BloatList $r }
        T 'Analyse des applications (Get-BloatApps + liste)' (Wait-Run 120) ("cases={0}" -f $Script:BloatChecks.Count)
        $Script:Sync.Result = $null
        Start-Run -Engine 'tools' -Code 'Get-DriverStoreList' -Title '' -OnDone { param($r) Show-DriverList $r }
        T 'Magasin de pilotes (analyse + liste)' (Wait-Run 180) ("pilotes={0}" -f $Script:DrvChecks.Count)
        Start-Run -Engine 'tools' -Code 'Find-DriverCatalog -Scope Missing' -Title '' -OnDone { param($r) Show-UpdateResults $r }
        T 'Recherche de pilotes (Catalog, appareils sans pilote)' (Wait-Run 300) ("lignes={0}, cases={1}" -f @($Script:UpPanel.Children).Count, $Script:UpChecks.Count)
        Start-Run -Engine 'tools' -Code 'Get-Win11DefaultsState' -Title '' -OnDone { param($r) Show-DefaultsRows $r }
        T 'Comparaison avec Windows 11 (analyse + liste)' (Wait-Run 120) ("écarts={0}, lignes={1}" -f $Script:DefChecks.Count, @($Script:DefPanel.Children).Count)
        $Script:Sync.Result = $null
        Start-Run -Engine 'tools' -Code 'Get-GhostDevices' -Title '' -OnDone { param($r) Show-GhostList $r }
        T 'Appareils fantômes (analyse + liste)' (Wait-Run 120) ("fantômes={0}" -f $Script:GhostChecks.Count)
        Start-Run -Engine 'tools' -Code 'Find-DownloadedDrivers' -Title '' -OnDone { param($r) Show-DownloadedDrivers $r }
        T 'Pilotes téléchargés (recherche + liste)' (Wait-Run 120) (("trouvés={0}" -f $Script:DlBox.Items.Count))
        $Script:DashChecks = 0
        Start-Run -Engine 'none' -Code $Script:DashCode -Title '' -OnDone { param($r) $Script:DashChecks = @($r.Checks).Count }
        T 'Diagnostic du tableau de bord' ((Wait-Run 120) -and $Script:DashChecks -ge 9) ("points vérifiés={0}" -f $Script:DashChecks)
        # Observateur d'événements : analyse réelle (lecture seule), liste affichée, code de réparation analysable
        $Script:Evt.Analyzed = $false
        Start-Run -Engine 'evt' -Code 'Get-EventFindings -Days 7' -Title '' -OnDone { param($r) $Script:EvtRes = $r; Show-EventFindings $r }
        $evOk = Wait-Run 120
        $evN = 0; if ($Script:EvtRes) { $evN = @($Script:EvtRes.Findings).Count }
        T 'Observateur d''événements : analyse et liste' ($evOk -and $Script:Evt.Analyzed -and $null -ne $Script:EvtRes) ("constats={0}, réparables cochés={1}, lignes={2}" -f $evN, $Script:Evt.Rows.Count, @($Script:Evt.Panel.Children).Count)
        $evLit = ConvertTo-EventItems @([pscustomobject]@{ Key = "r:svc|Service d’essai 'x'"; Fix = 'svc_start'; Sub = "Service d’essai 'x'" })
        $ee = $null; [void][Management.Automation.Language.Parser]::ParseInput(('Invoke-EventFix -Items ' + $evLit), [ref]$null, [ref]$ee)
        T 'Observateur d''événements : code de réparation' ($evLit -and -not ($ee -and $ee.Count)) $evLit
        # Les réparations lourdes doivent trouver leurs fonctions dans le moteur réuni (Maintenance + Outils + Événements)
        $missing = @('Clear-DnsCache', 'Sync-Clock', 'Restart-AudioServices', 'Clear-ShaderCache', 'Clear-PrintQueue', 'Reset-Search', 'Reset-Store', 'Reset-WindowsUpdate', 'Invoke-Chkdsk', 'Invoke-DISM', 'Invoke-SFC', 'New-RestorePoint', 'Invoke-EventFix', 'Watch-Events' |
            Where-Object { $Script:EngineCode['evt'] -notmatch ("(?m)^function " + [regex]::Escape($_) + "\b") })
        T 'Observateur d''événements : fonctions de réparation présentes' ($missing.Count -eq 0) ($missing -join ', ')
        # Surveillance en direct : le fil démarre, bat, puis s'arrête proprement
        Start-EventWatch
        $beat = $false; $end = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $end -and -not $beat) { Start-Sleep -Milliseconds 300; $beat = [bool]$Script:Sync.EvtBeat }
        $alive = [bool]($Script:EvtWatch -and -not $Script:EvtWatch.Handle.IsCompleted)
        Stop-EventWatch
        T 'Observateur d''événements : surveillance en direct' ($beat -and $alive -and -not $Script:EvtWatch) ("battement={0}, fil vivant={1}" -f $beat, $alive)
        $Script:BakStatus = $null
        Start-Run -Engine 'bak' -Code 'Get-BackupStatus' -Title '' -OnDone { param($r) Show-BackupStatus $r }
        $bakOk = Wait-Run 120
        T 'Sauvegarde : état, utilisateurs et disques' ($bakOk -and $Script:BakStatus -and $Script:Bak.Profile.Items.Count -ge 1) ("utilisateurs={0}, disques={1}, configurée={2}" -f $Script:Bak.Profile.Items.Count, $Script:Bak.Dest.Items.Count, $(if ($Script:BakStatus) { [bool]$Script:BakStatus.Configured } else { '?' }))
        $bakCode = ''
        if ($Script:Bak.Dest.Items.Count -gt 0) { $Script:Bak.Dest.Text = [string]$Script:Bak.Dest.Items[0] } else { $Script:Bak.Dest.Text = 'X:\Essai' }
        try { $bakCode = Get-BakConfigCode } catch { $bakCode = 'ERREUR ' + $_.Exception.Message }
        $be = $null; [void][Management.Automation.Language.Parser]::ParseInput($bakCode, [ref]$null, [ref]$be)
        T 'Sauvegarde : code de configuration' ($bakCode -match '^Set-BackupConfig -ProfilePath ''' -and -not ($be -and $be.Count)) $bakCode
        $Script:Bak.Dest.Text = ''
        # Journal de session : une exécution titrée doit apparaître, puis on nettoie
        $before = $Script:SessionLog.Count
        Start-Run -Engine 'tools' -Code 'Get-LicenseInfo' -Title 'Licence Windows'
        [void](Wait-Run 60)
        $added = $Script:SessionLog.Count - $before
        $txt = ''
        if ($added -ge 1) { $txt = Get-SummaryText (New-SummaryScenes @($Script:SessionLog[$Script:SessionLog.Count - 1]) '' 'BJMPC Informatique' 'Mia' $false) }
        T 'Journal de session' ($added -eq 1 -and $txt -match 'vérifié que votre Windows est bien activé') ("entrées ajoutées={0}, fichier={1}" -f $added, (Test-Path -LiteralPath $Script:SessionFile))
        $Script:SessionLog.Clear(); try { Remove-Item -LiteralPath $Script:SessionFile -Force -ErrorAction Stop } catch {}
        # Voix et résumé (si présents)
        if (Get-Command Test-SummarySelf -ErrorAction SilentlyContinue) { foreach ($l in (Test-SummarySelf)) { $out.Add($l) } }
    } catch { T 'Auto-test' $false $_.Exception.ToString() }
    $out.Add(''); $out.Add('--- Console de l''application ---')
    try { $out.Add((Get-ConsoleText)) } catch {}
    $dest = $env:BJMPC_SELFTEST
    [IO.File]::WriteAllLines($dest, $out, (New-Object Text.UTF8Encoding($true)))
    exit 0
}

try {
    [void]$Script:Window.ShowDialog()
} catch {
    Show-Fatal "Erreur : $($_.Exception.Message)"
}

#endregion
