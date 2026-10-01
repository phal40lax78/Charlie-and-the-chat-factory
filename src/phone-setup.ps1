# Charlie-and-the-chat-factory, src/phone-setup.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region phone setup: the dialog -----------------------------------------------
# chatnotify -Setup opens this: the Join key, the device, replies from the
# phone and which events reach it, in one window rather than a handful of
# switches to remember. It runs in a process of its own - Windows PowerShell
# with -STA, as the overlay does - so the shell that asked is free at once and
# a pwsh 7 shell can open it too. It saves through Set-ChatqNotifyConfig, the
# same path chatnotify takes, so the two never disagree about the file.
# Self-contained on purpose: nothing here borrows the overlay's or the
# console's WPF helpers.

$script:ChatqPhoneSetupLockPath = Join-Path $script:ChatqData 'phone-setup.lock'
# tests only: a scriptblock that stands in for launching the dialog's process
$script:ChatqPhoneSetupSpawn = $null
# how long chatnotify -Setup waits to see the dialog take its lock before it
# says what went wrong instead
$script:ChatqPhoneSetupWaitSec = 6
# how long the dialog keeps trying for its lock before it says another one is
# open: chatnotify -Setup looks at the same file ten times a second while it
# waits, and one of those looks can hold it for the instant the dialog asks
$script:ChatqPhoneSetupLockRetryMs = 1000
# how long a closed window's process stays to let a pairing alert or a
# confirmation finish: Join and ntfy each try three times at 20 s, and the
# user's command may take 30 s
$script:ChatqPhoneSetupPairWaitSec = 200
# tests only: PowerShell run in the background runspace after the script has
# loaded there, to stand in for the network
$script:ChatqPhoneSetupJobSeam = $null
# sends a closed window stopped waiting for, disposed once they end
$script:ChatqPhoneSetupOrphans = [System.Collections.Generic.List[object]]::new()
# the dialog last built in this process - a fallback for the handlers, which
# otherwise find theirs through the window they fire in
$script:ChatqPhoneSetup = $null
$script:ChatqPhoneSetupJoinSite = 'https://joinjoaomgcd.appspot.com'
$script:ChatqPhoneSetupPairHint = 'Pair phone sends it an alert: tap that on the phone within 15 min, then confirm here the code it shows. A phone paired before stops working.'
$script:ChatqPhoneSetupCandHint = 'Answers to the pairing alert. Confirm the one whose code your phone shows - a code your phone does not show is someone else''s.'
$script:ChatqPhoneSetupServerHint = 'Blank for ntfy.sh. https only. Your own server may want the token below.'

# Two looks, the overlay's colours: a state keeps its meaning in both, the
# light look's darker to read on white. fill is a pressed-in choice (Save, a
# ticked box) - a shade deeper than accent in the dark look, so white text on
# it still reads.
$script:ChatqPhoneSetupPalettes = @{
    dark  = @{
        window = '#FF1E2227'; text = '#FFE8EAED'; dim = '#FF9AA0A6'; faint = '#FF6B7079'; input = '#FF15181C'; edge = '#3DFFFFFF'
        line = '#1FFFFFFF'; hover = '#1FFFFFFF'; accent = '#FF4EA1FF'; fill = '#FF1F6FEB'; onFill = '#FFFFFFFF'; select = '#474EA1FF'
        ok = '#FF4CC38A'; warn = '#FFF5B942'; error = '#FFFF7B72'; link = '#FF8AB8FF'; bar = '#2EF5B942'
    }
    light = @{
        window = '#FFF6F8FA'; text = '#FF1F2328'; dim = '#FF57606A'; faint = '#FF8C959F'; input = '#FFFFFFFF'; edge = '#40000000'
        line = '#1F000000'; hover = '#12000000'; accent = '#FF0969DA'; fill = '#FF0969DA'; onFill = '#FFFFFFFF'; select = '#290969DA'
        ok = '#FF1A7F37'; warn = '#FF9A6700'; error = '#FFCF222E'; link = '#FF0969DA'; bar = '#26D4A72C'
    }
}

$script:ChatqPhoneSetupNativeCode = @'
using System;
using System.Runtime.InteropServices;
public static class ChatqPhoneSetupNative {
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
    // per-monitor v2 where Windows has it (1703+), else system-wide
    public static bool SetDpiAware() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) { return true; } } catch (EntryPointNotFoundException) { }
        try { return SetProcessDPIAware(); } catch (EntryPointNotFoundException) { return false; }
    }
    // a dark title bar over a dark window: attribute 20 from Windows 10 20H1,
    // 19 on the builds just before; anything older ignores both
    public static void DarkTitle(IntPtr h, bool dark) {
        int v = dark ? 1 : 0;
        try { if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) { DwmSetWindowAttribute(h, 19, ref v, 4); } }
        catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
    }
}
'@

# What Send test, Pair phone, a pairing's Confirm and the question hook's
# install or removal (Ask) run in a runspace of their own. A push can take minutes when the network is bad - Join and ntfy
# each try three times, and the user's command may run for 30 s - and on the
# window's thread that is a window Windows calls Not Responding. The runspace
# starts empty, so the script is loaded into it first. One object back,
# marked so stray output from the functions it calls cannot be mistaken for
# it.
# The runspace opens with the execution policy at Bypass, and PowerShell keeps
# that in the process's environment, where every process started from here -
# the watcher an alert starts, the jobs it runs for hours, the user's own
# command - would find it. So it is there for the load only. CHATQ_OVERLAY
# too, as the dialog's own process loaded the script: no key bindings and no
# watches in a process nobody types into, and not handed on either.
$script:ChatqPhoneSetupJobCode = @'
param($Path, $Seam, $Kind, $Text)
$env:CHATQ_OVERLAY = '1'
try { . $Path }
finally { Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference', 'env:CHATQ_OVERLAY' -EA SilentlyContinue }
if ($Seam) { . ([scriptblock]::Create($Seam)) }
$r = [pscustomobject]@{ ChatqSetupJob = $true; Kind = $Kind; Ok = $false; Error = $null; Until = $null; Label = $null; Sent = $null; Lines = @(); Messages = @() }
try {
    if ($Kind -eq 'ask') {
        # the question hook in or out: what chatnotify -Ask on|off does, with
        # its lines handed back for the status line ($Text is on or off)
        $a = Set-ChatqNotifyConfig @{ Ask = $Text } 6>$null
        $r.Error = if ($a.Error) { [string]$a.Error } else { $null }
        $r.Ok = -not $r.Error
        $r.Messages = @(@($a.Messages) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Text = [string]$_.Text; Color = [string]$_.Color } })
    }
    elseif ($Kind -eq 'pair') {
        $p = @(Start-ChatqReplyPairing)[-1]
        $r.Error = if ($p.Error) { [string]$p.Error } else { $null }
        $r.Ok = [bool](-not $p.Error -and $p.Sent)
        $r.Until = $p.Until
    }
    elseif ($Kind -eq 'confirm') {
        $p = @(Confirm-ChatqPairCandidate -Id $Text)[-1]
        $r.Error = if (-not $p) { 'no answer from the pairing code' } elseif ($p.Error) { [string]$p.Error } else { $null }
        $r.Ok = -not $r.Error
        if ($p -and $p.Label) { $r.Label = [string]$p.Label }
        if ($p -and $null -ne $p.Sent) { $r.Sent = [bool]$p.Sent }
    }
    else {
        $r.Ok = [bool](@(Send-ChatqAlert 'test' $Text 1 -Loud)[-1])
        if (-not $r.Ok) { $r.Error = [string]$script:ChatqLastAlertError }
    }
}
catch { $r.Error = $_.Exception.Message }
$r.Lines = @($script:ChatqAlertReport | Where-Object { $_ } | ForEach-Object { [string]$_ })
$r
'@

# The whole window, @name@ filled from the palette. Markup rather than code:
# nothing here comes and goes like the overlay's rows, and the flat buttons,
# boxes and the device list need templates - WPF's own ComboBox and CheckBox
# ignore Background and paint the system's light chrome into a dark window.
$script:ChatqPhoneSetupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Charlie - phone alerts" Width="460" SizeToContent="Height" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="Segoe UI" FontSize="12.5" Background="@window@" Foreground="@text@">
  <Window.Resources>
    <Style x:Key="Head" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="@dim@"/>
      <Setter Property="Margin" Value="0,16,0,8"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="@dim@"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,3,0,10"/>
    </Style>
    <Style x:Key="Ghost" TargetType="TextBlock">
      <Setter Property="Foreground" Value="@faint@"/>
      <Setter Property="IsHitTestVisible" Value="False"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="8,0,8,0"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="@input@"/>
      <Setter Property="Foreground" Value="@text@"/>
      <Setter Property="BorderBrush" Value="@edge@"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="@input@"/>
      <Setter Property="Foreground" Value="@text@"/>
      <Setter Property="BorderBrush" Value="@edge@"/>
      <Setter Property="CaretBrush" Value="@text@"/>
      <Setter Property="SelectionBrush" Value="@accent@"/>
      <Setter Property="Padding" Value="5,4,5,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="@input@"/>
      <Setter Property="Foreground" Value="@text@"/>
      <Setter Property="BorderBrush" Value="@edge@"/>
      <Setter Property="CaretBrush" Value="@text@"/>
      <Setter Property="SelectionBrush" Value="@accent@"/>
      <Setter Property="Padding" Value="5,4,5,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="@edge@"/>
      <Setter Property="Foreground" Value="@text@"/>
      <Setter Property="Padding" Value="12,4,12,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="ring" Margin="-3" BorderBrush="@accent@" BorderThickness="1.5" CornerRadius="6" Visibility="Collapsed"/>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="4"/>
              <Border x:Name="lit" Background="@hover@" CornerRadius="4" Visibility="Collapsed"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="lit" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ring" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="@fill@"/>
      <Setter Property="BorderBrush" Value="@fill@"/>
      <Setter Property="Foreground" Value="@onFill@"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="@text@"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Margin" Value="0,3,0,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="16" Height="16" VerticalAlignment="Center">
                <Border x:Name="box" Background="@input@" BorderBrush="@edge@" BorderThickness="1" CornerRadius="3"/>
                <Path x:Name="tick" Data="M 3.5,8 L 6.5,11 L 12.5,4.5" Stroke="@onFill@" StrokeThickness="1.8" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="@accent@"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
                <Setter TargetName="box" Property="Background" Value="@fill@"/>
                <Setter TargetName="box" Property="BorderBrush" Value="@fill@"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="@text@"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="@text@"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="MaxDropDownHeight" Value="280"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="bd" Background="@input@" BorderBrush="@edge@" BorderThickness="1" CornerRadius="3"/>
              <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0" Data="M 0,0 L 4,4 L 8,0"
                    Stroke="@dim@" StrokeThickness="1.5" IsHitTestVisible="False"/>
              <ContentPresenter IsHitTestVisible="False" Margin="8,4,28,5" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <ToggleButton Focusable="False" ClickMode="Press" Cursor="Hand"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"/></ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="None">
                <Border Background="@input@" BorderBrush="@edge@" BorderThickness="1" CornerRadius="3" Margin="0,2,0,0" Padding="0,3,0,3"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="@accent@"/></Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="@accent@"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="@text@"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Background="Transparent" Padding="8,4,8,5"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="@select@"/></Trigger>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="@hover@"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="@text@"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <DockPanel>
              <ToggleButton DockPanel.Dock="Top" Cursor="Hand" FocusVisualStyle="{x:Null}" Content="{TemplateBinding Header}"
                            IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="fr" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="3" Padding="0,2,4,2">
                      <StackPanel Orientation="Horizontal">
                        <Path x:Name="chev" Data="M 0,0 L 4,4 L 0,8" Stroke="@dim@" StrokeThickness="1.5" VerticalAlignment="Center"
                              Margin="2,0,9,0" RenderTransformOrigin="0.5,0.5"/>
                        <ContentPresenter VerticalAlignment="Center"/>
                      </StackPanel>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="chev" Property="RenderTransform"><Setter.Value><RotateTransform Angle="90"/></Setter.Value></Setter>
                      </Trigger>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="chev" Property="Stroke" Value="@text@"/></Trigger>
                      <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="fr" Property="BorderBrush" Value="@accent@"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="body" Visibility="Collapsed"/>
            </DockPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True"><Setter TargetName="body" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <DockPanel Background="@window@">
    <Border DockPanel.Dock="Bottom" BorderBrush="@line@" BorderThickness="0,1,0,0" Padding="18,10,18,12">
      <StackPanel>
        <Border x:Name="Bar" Visibility="Collapsed" Background="@bar@" CornerRadius="4" Padding="10,7,10,7" Margin="0,0,0,10">
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="BarSave" Style="{StaticResource Primary}" Content="Save and close" Margin="0,0,6,0"/>
              <Button x:Name="BarDiscard" Content="Discard" Margin="0,0,6,0" ToolTip="Close without saving"/>
              <Button x:Name="BarKeep" Content="Keep editing" ToolTip="Esc"/>
            </StackPanel>
            <TextBlock Text="Unsaved changes." VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
        </Border>
        <DockPanel>
          <Button x:Name="CloseBtn" DockPanel.Dock="Right" Content="Close" ToolTip="Esc - asks first when something is not saved"/>
          <Button x:Name="SaveBtn" DockPanel.Dock="Right" Style="{StaticResource Primary}" Content="Save" Margin="0,0,6,0" ToolTip="Ctrl+S"/>
          <TextBlock x:Name="Status" VerticalAlignment="Center" Foreground="@dim@" FontSize="11.5" TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
        </DockPanel>
      </StackPanel>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto" Focusable="False">
      <StackPanel Margin="18,14,18,8">
        <TextBlock Text="Phone alerts" FontSize="17" FontWeight="SemiBold"/>
        <TextBlock Style="{StaticResource Hint}" Margin="0,2,0,0" Text="chatq tells your phone when a chat needs you or is done - and you can answer."/>

        <TextBlock Style="{StaticResource Head}" Text="JOIN"/>
        <TextBlock Style="{StaticResource Label}" Text="API key"/>
        <Grid>
          <PasswordBox x:Name="KeyBox" ToolTip="Enter finds your devices"/>
          <TextBlock x:Name="KeyGhost" Style="{StaticResource Ghost}"/>
        </Grid>
        <TextBlock Style="{StaticResource Hint}">From <Hyperlink x:Name="KeyLink" Foreground="@link@" ToolTip="https://joinjoaomgcd.appspot.com">joinjoaomgcd.appspot.com - Join API</Hyperlink>. A whole push URL works too.</TextBlock>
        <TextBlock Style="{StaticResource Label}" Text="Device"/>
        <DockPanel>
          <Button x:Name="FindBtn" DockPanel.Dock="Right" Content="Find devices" Margin="8,0,0,0" ToolTip="Ask Join which devices this key has"/>
          <ComboBox x:Name="DeviceBox"/>
        </DockPanel>
        <TextBlock x:Name="DeviceNote" Style="{StaticResource Hint}"/>
        <DockPanel Margin="0,0,0,2">
          <Button x:Name="TestBtn" DockPanel.Dock="Left" Content="Send test" Margin="0,0,10,0"/>
          <TextBlock x:Name="TestNote" Style="{StaticResource Hint}" Margin="0" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBlock Style="{StaticResource Label}" Margin="0,10,0,2" Text="Read aloud"/>
        <WrapPanel x:Name="SayPanel"/>
        <TextBlock x:Name="SayNote" Style="{StaticResource Hint}"/>

        <StackPanel x:Name="ReplySection">
          <TextBlock Style="{StaticResource Head}" Text="REPLIES"/>
          <CheckBox x:Name="ReplyBox" Content="Reply from the phone"/>
          <TextBlock Style="{StaticResource Hint}" Margin="23,2,0,8" Text="Tap an alert, type the next prompt: it comes back encrypted through ntfy.sh. The phone is paired once, first."/>
          <DockPanel Margin="23,0,0,0">
            <Button x:Name="PairBtn" DockPanel.Dock="Right" Content="Pair phone" Margin="10,0,0,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="ReplyStatus" VerticalAlignment="Center" TextWrapping="Wrap"/>
          </DockPanel>
          <Border x:Name="CandPanel" Visibility="Collapsed" Margin="23,10,0,0" BorderBrush="@line@" BorderThickness="0,1,0,0" Padding="0,8,0,0">
            <StackPanel>
              <TextBlock x:Name="CandHint" Style="{StaticResource Hint}" Margin="0,0,0,6"/>
              <StackPanel x:Name="CandList"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="PairNote" Style="{StaticResource Hint}" Margin="23,4,0,0"/>
          <CheckBox x:Name="PermitBox" Content="Approve tool calls from the phone" Margin="23,10,0,0"/>
          <TextBlock x:Name="PermitHint" Style="{StaticResource Hint}" Margin="46,2,0,0"/>
          <CheckBox x:Name="AskBox" Content="Answer Claude's questions from the phone" Margin="23,10,0,0"/>
          <TextBlock x:Name="AskHint" Style="{StaticResource Hint}" Margin="46,2,0,0" Text="A question in a chat you run yourself shows on the phone with its choices; answer there or at the PC - the first answer counts. Adds a small hook to Claude Code, as a plugin."/>
          <!-- the replies' own options, each indented under Reply from the phone -->
          <CheckBox x:Name="FullBox" Content="Show Claude's whole answer on the phone" Margin="23,10,0,0"/>
          <TextBlock Style="{StaticResource Hint}" Margin="46,2,0,6" Text="With done, needs input and failed. Sealed, like a reply; ntfy.sh passes it on."/>
          <CheckBox x:Name="ComposeBox" Content="Let the phone queue to any chat, or start one" Margin="23,0,0,0"/>
          <TextBlock Style="{StaticResource Hint}" Margin="46,2,0,6" Text="The reply page from a bookmark shows the overlay's board: every chat, the queue, usage."/>
          <CheckBox x:Name="ListenBox" Content="Listen all the time (the phone board and new chats)" Margin="23,0,0,0"/>
          <TextBlock x:Name="ListenNote" Style="{StaticResource Hint}" Margin="46,2,0,6" Text="So the phone can reach the PC without an alert. A hidden PowerShell stays running and asks ntfy.sh every 20 s."/>
        </StackPanel>

        <TextBlock Style="{StaticResource Head}" Text="WHAT REACHES THE PHONE"/>
        <WrapPanel x:Name="EventsPanel"/>
        <TextBlock Style="{StaticResource Hint}" Text="Unticked: the toast and your command only. Tests and replies always go."/>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Quiet while I use this PC for" VerticalAlignment="Center"/>
          <TextBox x:Name="QuietBox" Width="46" Margin="8,0,8,0" HorizontalContentAlignment="Center" MaxLength="4"/>
          <TextBlock Text="min (0 = always send)" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock Style="{StaticResource Hint}" Text="Keyboard or mouse used that recently: you are here, the phone stays quiet."/>
        <StackPanel Orientation="Horizontal">
          <CheckBox x:Name="QuietHoursBox" Content="Quiet hours  from" VerticalAlignment="Center"/>
          <TextBox x:Name="QuietFromBox" Width="54" Margin="8,0,8,0" HorizontalContentAlignment="Center" MaxLength="5"/>
          <TextBlock Text="to" VerticalAlignment="Center"/>
          <TextBox x:Name="QuietToBox" Width="54" Margin="8,0,0,0" HorizontalContentAlignment="Center" MaxLength="5"/>
        </StackPanel>
        <TextBlock Style="{StaticResource Hint}" Margin="23,2,0,4" Text="This PC's clock. Held until then, then one summary."/>
        <TextBlock Margin="23,0,0,2" Text="Still send:"/>
        <WrapPanel x:Name="UrgentPanel" Margin="23,0,0,6"/>
        <CheckBox x:Name="LiveBox" Content="Chats I run myself, when I'm away"/>
        <TextBlock Style="{StaticResource Hint}" Margin="23,2,0,6" Text="The overlay watches them; nothing is sent while you use this PC."/>
        <StackPanel Orientation="Horizontal">
          <CheckBox x:Name="UsageBox" Content="Usage at" VerticalAlignment="Center"/>
          <TextBox x:Name="UsageAtBox" Width="64" Margin="8,0,6,0" HorizontalContentAlignment="Center" MaxLength="8"/>
          <TextBlock Text="%" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock Style="{StaticResource Hint}" Margin="23,2,0,6" Text="Claude or Codex, 5-hour or weekly window. Needs the overlay."/>
        <CheckBox x:Name="ResetBox" Content="When a limit resets with prompts queued"/>
        <TextBlock Style="{StaticResource Hint}" Margin="23,2,0,6" Text="Ten minutes before, with Send now, and when it goes."/>
        <CheckBox x:Name="ToastBox" Content="Desktop toast"/>
        <TextBlock Style="{StaticResource Hint}" Margin="23,2,0,6" Text="A Windows notification on this PC as well - nothing leaves it."/>

        <Expander x:Name="Others" Margin="0,8,0,4">
          <Expander.Header>
            <TextBlock Style="{StaticResource Head}" Margin="0" Text="OTHER CHANNELS - NTFY, YOUR OWN COMMAND"/>
          </Expander.Header>
          <StackPanel Margin="0,10,0,0">
            <TextBlock Style="{StaticResource Label}" Text="ntfy topic"/>
            <Grid>
              <PasswordBox x:Name="NtfyTopicBox"/>
              <TextBlock x:Name="NtfyTopicGhost" Style="{StaticResource Ghost}"/>
            </Grid>
            <TextBlock Style="{StaticResource Hint}" Text="Alerts through ntfy as well. Anyone with the topic reads them: make it long."/>
            <TextBlock Style="{StaticResource Label}" Text="ntfy server"/>
            <Grid>
              <TextBox x:Name="NtfyServerBox"/>
              <TextBlock x:Name="NtfyServerGhost" Style="{StaticResource Ghost}" Text="https://ntfy.sh"/>
            </Grid>
            <TextBlock x:Name="NtfyServerNote" Style="{StaticResource Hint}"/>
            <TextBlock Style="{StaticResource Label}" Text="ntfy token"/>
            <Grid>
              <PasswordBox x:Name="NtfyTokenBox"/>
              <TextBlock x:Name="NtfyTokenGhost" Style="{StaticResource Ghost}"/>
            </Grid>
            <TextBlock Style="{StaticResource Hint}" Text="Only for a server that asks for one."/>
            <TextBlock Style="{StaticResource Label}" Text="Command"/>
            <TextBox x:Name="CommandBox"/>
            <TextBlock Style="{StaticResource Hint}" Margin="0,3,0,2" Text="Your own PowerShell on every alert, given $env:CHATQ_EVENT, _TITLE, _TEXT."/>
            <CheckBox x:Name="CommandLinksBox" Margin="0,6,0,0" Content="Give it the reply link too ($env:CHATQ_LINK)"/>
          </StackPanel>
        </Expander>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@

function Start-ChatqPhoneSetup {
    <#
    The dialog, in a process of its own. Windows only: it is WPF. One at a
    time - the open one holds data/phone-setup.lock, as the watcher holds its
    own - and a second ask only says so. Waits a few seconds to see that lock
    taken before it says the dialog opened: a process that fails while it
    loads has no console, and "opens in its own window" followed by nothing
    is the worst answer. Prints one line.
    -NoWait: for a caller on a window's thread - the overlay's tray - that
    cannot sit six seconds: the process is started and that is all, no look
    at the lock before or after, nothing printed. A second dialog then says
    "already open" in data/logs/phone-setup.log and ends. $true when the
    process started.
    #>
    param([switch]$NoWait)
    Set-StrictMode -Off
    if (-not $script:ChatqIsWindows) {
        if ($NoWait) { return $false }
        Write-Host '  the setup dialog is Windows-only - chatnotify -? lists the same settings as switches' -ForegroundColor Yellow
        return
    }
    if (-not $NoWait -and (Test-ChatqLockHeld $script:ChatqPhoneSetupLockPath)) {
        Write-Host '  phone setup is already open' -ForegroundColor DarkGray
        return
    }
    $path = $script:ChatqScriptPath
    if (-not $script:ChatqPhoneSetupSpawn -and (-not $path -or -not (Test-Path -LiteralPath $path))) {
        if ($NoWait) { Write-ChatqPhoneSetupLog 'cannot open phone setup: this process does not know where Charlie-and-the-chat-factory.ps1 is'; return $false }
        Write-Host '  cannot open phone setup: this shell does not know where Charlie-and-the-chat-factory.ps1 is' -ForegroundColor Yellow
        return
    }
    $log = Join-Path $script:ChatqLogDir 'phone-setup.log'
    $logWas = 0
    try { if (-not $NoWait -and (Test-Path -LiteralPath $log)) { $logWas = (Get-Item -LiteralPath $log).Length } } catch {}
    $l = Get-ChatqPhoneSetupLaunch $path
    $proc = $null
    try {
        if ($script:ChatqPhoneSetupSpawn) { $proc = & $script:ChatqPhoneSetupSpawn $l }   # tests: no real process
        else { $proc = Start-Process -FilePath $l.Exe -ArgumentList $l.Args -WindowStyle Hidden -PassThru }
    }
    catch {
        if ($NoWait) { Write-ChatqPhoneSetupLog "cannot open phone setup: $($_.Exception.Message)"; return $false }
        Write-Host "  cannot open phone setup: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }
    if ($NoWait) { return $true }
    if (-not ($proc -is [System.Diagnostics.Process])) { $proc = $null }
    $until = (Get-Date).AddSeconds([double]$script:ChatqPhoneSetupWaitSec)
    while ((Get-Date) -lt $until) {
        if (Test-ChatqLockHeld $script:ChatqPhoneSetupLockPath) {
            Write-Host '  phone setup opens in its own window' -ForegroundColor DarkGray
            return
        }
        if ($proc -and $proc.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    # not open: whatever the process wrote down since it was started says why
    $why = ''
    try {
        if (Test-Path -LiteralPath $log) {
            $b = [System.IO.File]::ReadAllBytes($log)
            if ($b.Length -gt $logWas) {
                $new = [System.Text.Encoding]::UTF8.GetString($b, [int]$logWas, $b.Length - [int]$logWas)
                $last = @($new -split "`r?`n" | Where-Object { $_.Trim() })
                if ($last) { $why = ($last[-1] -replace '^\S+\s+', '').Trim() }
            }
        }
    }
    catch {}
    # another dialog took the lock between the look above and this one's
    if ($why -like 'phone setup is already open*') { Write-Host '  phone setup is already open' -ForegroundColor DarkGray }
    elseif ($why) { Write-Host "  phone setup did not open: $why" -ForegroundColor Yellow }
    elseif ($proc -and $proc.HasExited) { Write-Host "  phone setup did not open - its process ended (exit $($proc.ExitCode)) without a word in data/logs/phone-setup.log" -ForegroundColor Yellow }
    else { Write-Host '  phone setup is still starting - if no window comes, data/logs/phone-setup.log says why' -ForegroundColor DarkGray }
}

function Get-ChatqPhoneSetupLaunch {
    <#
    How the dialog's process starts: @{ Exe; Args; Command }. Windows
    PowerShell with -STA even from pwsh - WPF needs an STA thread, and every
    Windows has powershell.exe. -ExecutionPolicy Bypass for that process
    only: a pwsh 7 user's own policy lives in pwsh's settings, not in Windows
    PowerShell's, whose default on a client Windows refuses every script - so
    without it the dot-source below fails before any window exists.
    CHATQ_OVERLAY=1 is the overlay's own guard: loading the script there then
    binds no keys and starts no watcher, since nobody types into that process.
    Both go again once the script has loaded: -ExecutionPolicy lives on in
    the process's environment as PSExecutionPolicyPreference, and a watcher
    the dialog starts - Pair phone always does when none runs - would hand
    Bypass on to every job it runs for hours, and CHATQ_OVERLAY with it.
    The provider homes go along because the test alert may start a watcher
    from it. A failure before the window is up still reaches
    data/logs/phone-setup.log, which Start-ChatqPhoneSetup reads back.
    From pwsh 7 the module path is put back to Windows PowerShell's own
    first thing: the process inherits pwsh's, which lists pwsh's modules
    ahead of Windows PowerShell's, and the first cmdlet from one of those -
    ConvertTo-SecureString, which every saved secret goes through - fails
    to load there. pwsh mends that itself when it runs powershell.exe
    directly, not through Start-Process.
    #>
    param([string]$Path = $script:ChatqScriptPath)
    $q = { param($s) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$s) + "'" }
    $pre = ''
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $pre = "`$env:PSModulePath = [Environment]::GetFolderPath('MyDocuments') + '\WindowsPowerShell\Modules;' + `$env:ProgramFiles + '\WindowsPowerShell\Modules;' + " +
        "`$PSHOME + '\Modules;' + [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine'); "
    }
    $pre += '$env:CHATQ_OVERLAY=''1''; '
    foreach ($n in 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CHATQ_CLAUDE', 'CHATQ_CODEX', 'CHATQ_GH') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $pre += "`$env:$n=$(& $q $v); " }
    }
    $log = Join-Path $script:ChatqLogDir 'phone-setup.log'
    $drop = "Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference', 'env:CHATQ_OVERLAY' -EA SilentlyContinue"
    $cmd = $pre + "try { . $(& $q $Path); $drop; Show-ChatqPhoneSetup } catch { try { [void][IO.Directory]::CreateDirectory($(& $q $script:ChatqLogDir)); " +
    "[IO.File]::AppendAllText($(& $q $log), (Get-Date).ToString('o') + '  phone setup failed to start: ' + `$_.Exception.Message + [char]10) } catch {} }"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $root = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $exe = Join-Path $root 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc)
    return [pscustomobject]@{ Exe = $exe; Args = $argv; Command = $cmd }
}

function Show-ChatqPhoneSetup {
    <#
    The dialog itself, in the process Start-ChatqPhoneSetup made; returns when
    it closes. -Theme dark|light overrides the Windows app mode.
    #>
    param([ValidateSet('', 'dark', 'light')][string]$Theme = '')
    Set-StrictMode -Off
    $lock = Open-ChatqPhoneSetupLock
    if (-not $lock) { Write-Host '  phone setup is already open' -ForegroundColor DarkGray; return }
    try {
        Initialize-ChatqPhoneSetupNative
        $w = New-ChatqPhoneSetupWindow -Theme $Theme
        [void]$w.ShowDialog()
    }
    catch { Write-ChatqPhoneSetupLog "failed: $($_.Exception.Message)" }
    finally {
        $U = $script:ChatqPhoneSetup
        if ($U) { Stop-ChatqPhoneSetupWork $U }
        # let go first: a dialog opened again meanwhile is a new one, and
        # this process only stays behind for the sends below
        $lock.Dispose()
        # A test push the window stopped gets a moment to end, so its
        # runspace goes away properly rather than with the process. A
        # pairing alert or a confirmation is never stopped halfway - the
        # phone's old key is already gone by then - so the hidden process
        # stays until it is out, as long as the send's own tries take.
        Clear-ChatqPhoneSetupOrphans -WaitMs 3000 -PairWaitMs ([int]$script:ChatqPhoneSetupPairWaitSec * 1000)
    }
}

function Open-ChatqPhoneSetupLock {
    <#
    data/phone-setup.lock, held with no sharing for the dialog's life: the OS
    lets go of it even when the process dies hard, so a crash never leaves it
    "open". $null when another dialog holds it. Tried for a second before
    that is believed: chatnotify -Setup opens the same file ten times a
    second to see whether the dialog is up yet, and a look that lands on the
    very instant this one asks is not another dialog. The verdict goes to
    data/logs/phone-setup.log, the one place the shell can read it from.
    #>
    New-ChatqDir $script:ChatqData
    $until = (Get-Date).AddMilliseconds([double]$script:ChatqPhoneSetupLockRetryMs)
    while ($true) {
        try { return [System.IO.File]::Open($script:ChatqPhoneSetupLockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch {
            if ((Get-Date) -ge $until) { break }
            Start-Sleep -Milliseconds 50
        }
    }
    Write-ChatqPhoneSetupLog 'phone setup is already open - another window holds data/phone-setup.lock'
    return $null
}

function Initialize-ChatqPhoneSetupNative {
    # In the one order that works, as the overlay learned: DPI awareness is
    # process-wide, only the first call sets it, and WPF reads it as it
    # loads. Per-monitor, so the text is sharp on a 150% screen and a drag to
    # another monitor redraws at that one's scale instead of blurring.
    try {
        if (-not ('ChatqPhoneSetupNative' -as [type])) { Add-Type -TypeDefinition $script:ChatqPhoneSetupNativeCode }
        [void][ChatqPhoneSetupNative]::SetDpiAware()
    }
    catch { Write-ChatqPhoneSetupLog "dpi: $($_.Exception.Message)" }
    try { [System.AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false) } catch {}
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
}

function Write-ChatqPhoneSetupLog {
    # data/logs/phone-setup.log: the dialog's process has no console to say
    # anything in
    param([string]$Text)
    try {
        New-ChatqDir $script:ChatqLogDir
        [System.IO.File]::AppendAllText((Join-Path $script:ChatqLogDir 'phone-setup.log'), "$((Get-Date).ToString('o'))  $Text`n", (New-Object System.Text.UTF8Encoding $false))
    }
    catch {}
}

function Test-ChatqPhoneSetupDark {
    # Windows' app mode: AppsUseLightTheme 0 is dark; missing - an older
    # Windows - is light
    try { return ([int](Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -EA Stop) -eq 0) }
    catch { return $false }
}

function New-ChatqPhoneSetupWindow {
    <#
    The window, built, wired and filled from config.json but not shown - the
    tests render it off-screen from here. Its state lives in a hashtable on
    the window's Tag, so each handler finds its own dialog.
    #>
    param([ValidateSet('', 'dark', 'light')][string]$Theme = '')
    Set-StrictMode -Off
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $dark = if ($Theme) { $Theme -eq 'dark' } else { Test-ChatqPhoneSetupDark }
    $pal = $script:ChatqPhoneSetupPalettes[$(if ($dark) { 'dark' } else { 'light' })]
    $xaml = $script:ChatqPhoneSetupXaml
    foreach ($k in $pal.Keys) { $xaml = $xaml.Replace("@$k@", $pal[$k]) }
    $w = [System.Windows.Markup.XamlReader]::Parse($xaml)
    # Charlie on its taskbar button, as on the overlay's (src/overlay-windows.ps1)
    $face = Get-ChatIconSource
    if ($face) { $w.Icon = $face }
    $U = @{
        Win = $w; Dark = $dark; Pal = $pal; Brushes = @{}; Cfg = $null; Loading = $false; Pasting = $false; Closing = $false
        Baseline = ''; Fetch = $null; FetchedKey = ''; Want = ''; Timer = $null; Job = $null; WaitPair = $false; NextLook = [datetime]::MinValue
        HasKey = $false; Device = ''; DeviceName = ''; ReplyOn = $false; EventsWas = ''; QuietWas = 5; ToastWas = $true; LiveWas = $true
        HasTopic = $false; HasToken = $false; ServerWas = ''; CommandWas = ''; CommandLinksWas = $false; Cands = @(); CandSig = ''; PairFailed = $null
    }
    foreach ($n in 'KeyBox', 'KeyGhost', 'KeyLink', 'DeviceBox', 'FindBtn', 'DeviceNote', 'TestBtn', 'TestNote', 'ReplySection', 'ReplyBox', 'ReplyStatus',
        'PairBtn', 'PairNote', 'CandPanel', 'CandHint', 'CandList', 'EventsPanel', 'QuietBox', 'LiveBox', 'ToastBox', 'Others', 'NtfyTopicBox', 'NtfyTopicGhost',
        'NtfyServerBox', 'NtfyServerGhost', 'NtfyServerNote', 'NtfyTokenBox', 'NtfyTokenGhost', 'CommandBox', 'CommandLinksBox', 'Bar', 'BarSave', 'BarDiscard', 'BarKeep',
        'Status', 'SaveBtn', 'CloseBtn') {
        $U[$n] = $w.FindName($n)
    }
    foreach ($n in 'PermitBox', 'PermitHint', 'AskBox', 'AskHint') { $U[$n] = $w.FindName($n) }
    $w.Tag = $U
    # the whole answer, the board and listening all the time (src/phone-board.ps1)
    Initialize-ChatqBoardSetup $U
    $script:ChatqPhoneSetup = $U
    # tall content on a short screen scrolls instead of running off it
    try { $w.MaxHeight = [Math]::Max(360, [System.Windows.SystemParameters]::WorkArea.Height - 24) } catch {}
    foreach ($ev in $script:ChatqPhoneEvents) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        $cb.Content = $ev
        $cb.Tag = $ev
        $cb.Margin = [System.Windows.Thickness]::new(0, 3, 16, 3)
        $cb.ToolTip = "Send '$ev' alerts to the phone"
        # what limited covers since auto-continue (src/auto-continue.ps1)
        if ($ev -eq 'limited') { $cb.ToolTip = 'the limit came back mid-run, or cut off a chat you run yourself that auto-continue will continue' }
        $cb.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
        [void]$U.EventsPanel.Children.Add($cb)
    }
    $U.DeviceNote.Text = 'Where alerts go. Enter in the key box finds your devices too.'
    $U.TestNote.Text = 'Saves first, then alerts the phone right away.'
    $U.QuietBox.ToolTip = 'Minutes; 0 sends to the phone even while you are at the PC'
    $U.CommandBox.ToolTip = 'Runs as -EncodedCommand with the alert in $env:CHATQ_EVENT, CHATQ_TITLE, CHATQ_TEXT, CHATQ_PRIORITY, CHATQ_JOB, CHATQ_PRESENT'
    $U.CommandLinksBox.ToolTip = 'For a Pushover or Telegram command, with neither Join nor ntfy over https: it gets the link on an alert that reaches the phone, runs without one at the PC, and can carry the pairing. The link goes wherever your command sends it.'
    $U.PairNote.Text = $script:ChatqPhoneSetupPairHint
    $U.CandHint.Text = $script:ChatqPhoneSetupCandHint
    $U.PairBtn.ToolTip = 'Saves, then sends the phone a pairing alert. A phone paired before stops working.'
    $U.ReplyBox.ToolTip = 'Each alert carries a link to a reply page; what you type there comes back encrypted. Needs a paired phone.'
    $U.ToastBox.ToolTip = 'A Windows notification here for every alert'
    $U.LiveBox.ToolTip = 'A chat in VS Code that waits on you, or finishes, while you are away - not only the ones chatq runs'
    $U.PermitBox.ToolTip = 'This lets the phone make a command run on this PC. Serve the reply page from a site of your own first (chatnotify -ReplyPage).'
    $U.AskBox.ToolTip = 'This lets the phone answer for you in a chat. Serve the reply page from a site of your own first (chatnotify -ReplyPage).'

    $U.KeyBox.add_PasswordChanged({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupKey $U } })
    $U.KeyBox.add_PreviewKeyDown({
            param($src, $e)
            if ($e.Key -ne [System.Windows.Input.Key]::Return) { return }
            $e.Handled = $true
            Invoke-ChatqPhoneSetupAction $src { param($U) Start-ChatqPhoneSetupFind $U -Force }
        })
    $U.KeyLink.add_Click({ param($src, $e) try { [void][System.Diagnostics.Process]::Start($script:ChatqPhoneSetupJoinSite) } catch {} })
    $U.FindBtn.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Start-ChatqPhoneSetupFind $U -Force } })
    $U.DeviceBox.add_SelectionChanged({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
    $U.TestBtn.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Invoke-ChatqPhoneSetupTest $U } })
    $U.ReplyBox.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupReplyStatus $U; Update-ChatqPhoneSetupDirty $U } })
    $U.PairBtn.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Invoke-ChatqPhoneSetupPair $U } })
    $U.ToastBox.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
    $U.LiveBox.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
    $U.CommandLinksBox.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
    $U.PermitBox.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
    $U.AskBox.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
    foreach ($b in $U.QuietBox, $U.NtfyServerBox, $U.CommandBox) {
        $b.add_TextChanged({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupGhosts $U; Update-ChatqPhoneSetupDirty $U } })
    }
    foreach ($b in $U.NtfyTopicBox, $U.NtfyTokenBox) {
        $b.add_PasswordChanged({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupGhosts $U; Update-ChatqPhoneSetupDirty $U } })
    }
    $U.SaveBtn.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) [void](Save-ChatqPhoneSetup $U) } })
    $U.CloseBtn.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Request-ChatqPhoneSetupClose $U } })
    $U.BarSave.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) if (Save-ChatqPhoneSetup $U) { Close-ChatqPhoneSetup $U } } })
    $U.BarDiscard.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Close-ChatqPhoneSetup $U } })
    $U.BarKeep.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Hide-ChatqPhoneSetupBar $U } })
    $w.add_PreviewKeyDown({
            param($src, $e)
            $U = Get-ChatqPhoneSetupFrom $src
            if (-not $U) { return }
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                # an open device list closes first, as Esc does anywhere else
                if ($U.DeviceBox.IsDropDownOpen) { return }
                $e.Handled = $true
                Invoke-ChatqPhoneSetupAction $src { param($U) if ($U.Bar.Visibility -eq [System.Windows.Visibility]::Visible) { Hide-ChatqPhoneSetupBar $U } else { Request-ChatqPhoneSetupClose $U } }
                return
            }
            $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::S) { $e.Handled = $true; Invoke-ChatqPhoneSetupAction $src { param($U) [void](Save-ChatqPhoneSetup $U) } }
        })
    # the title bar's X, Alt+F4: the same question as Close, asked in the bar
    $w.add_Closing({
            param($src, $e)
            $U = Get-ChatqPhoneSetupFrom $src
            if (-not $U -or $U.Closing) { return }
            if (Test-ChatqPhoneSetupDirty $U) { $e.Cancel = $true; Show-ChatqPhoneSetupBar $U }
        })
    $w.add_Closed({ param($src, $e) $U = Get-ChatqPhoneSetupFrom $src; if ($U) { Stop-ChatqPhoneSetupWork $U } })
    $w.add_SourceInitialized({
            param($src, $e)
            $U = Get-ChatqPhoneSetupFrom $src
            if ($U -and ('ChatqPhoneSetupNative' -as [type])) {
                try { [ChatqPhoneSetupNative]::DarkTitle([System.Windows.Interop.WindowInteropHelper]::new($src).Handle, [bool]$U.Dark) } catch {}
            }
        })
    # the first thing a new user does is paste the key, so the caret waits there
    $w.add_Loaded({ param($src, $e) $U = Get-ChatqPhoneSetupFrom $src; if ($U -and -not $U.HasKey) { [void]$U.KeyBox.Focus() } })
    # read aloud, quiet hours, usage and resets (src/phone-extras.ps1)
    Initialize-ChatqPhoneSetupExtras $U

    Read-ChatqPhoneSetupForm $U
    return $w
}

function Get-ChatqPhoneSetupFrom {
    # the dialog state behind any element or window of it
    param($Source)
    $w = $null
    try { $w = [System.Windows.Window]::GetWindow($Source) } catch {}
    if ($w -and $w.Tag -is [hashtable]) { return $w.Tag }
    return $script:ChatqPhoneSetup
}

function Invoke-ChatqPhoneSetupAction {
    # Every handler goes through here: a fault shows in the status line and
    # the log instead of vanishing into a console nobody sees.
    param($Source, [scriptblock]$Do)
    $U = Get-ChatqPhoneSetupFrom $Source
    if (-not $U) { return }
    try { & $Do $U }
    catch {
        Write-ChatqPhoneSetupLog "error: $($_.Exception.Message)"
        Set-ChatqPhoneSetupNote $U $U.Status "something went wrong: $($_.Exception.Message)" 'error'
    }
}

function Get-ChatqPhoneSetupBrush {
    param($U, [string]$Name)
    $hex = $U.Pal[$Name]
    if (-not $hex) { $hex = $U.Pal.text }
    $b = $U.Brushes[$hex]
    if (-not $b) {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
        $b.Freeze()
        $U.Brushes[$hex] = $b
    }
    return $b
}

function Set-ChatqPhoneSetupNote {
    # one of the hint lines, or the status line, saying something else; the
    # full text as a tooltip too, since the status line trims
    param($U, $Block, [string]$Text, [string]$Tone = 'dim')
    if (-not $Block) { return }
    $Block.Text = $Text
    $Block.Foreground = Get-ChatqPhoneSetupBrush $U $Tone
    $Block.ToolTip = if ($Text) { $Text } else { $null }
}

function Get-ChatqPhoneSetupGroups {
    # Join's fixed groups, as a lookup lists them: offered before any lookup,
    # so group.phone is one pick away even with no network
    return @((ConvertFrom-ChatqJoinDevices '{"success":true,"records":[]}').Devices)
}

function Format-ChatqPhoneSetupDevice {
    # a device as the list shows it: its name and, when it adds anything, the model
    param($Device)
    $name = [string]$Device.Name
    $id = [string]$Device.Id
    if ($id -like 'group.*') { return "$name  ($id)" }
    if (-not $name) { return $id }
    $model = [string]$Device.Model
    if ($model -and $model -ne $name) { return "$name  $($script:ChatqDot)  $model" }
    return $name
}

function Read-ChatqPhoneSetupForm {
    <#
    The form from config.json. Secrets are never put back in a box: a stored
    key, topic or token leaves its box empty with "saved - paste to replace"
    showing through, and an empty box on Save keeps what is stored.
    -KeepDevices: after a save, the device list a lookup found stays.
    #>
    param($U, [switch]$KeepDevices)
    $U.Loading = $true
    try {
        $cfg = Get-ChatqConfig
        $U.Cfg = $cfg
        $has = { param($o, $n) $o -and $o.PSObject.Properties[$n] -and $null -ne $o.$n -and '' -ne $o.$n }
        $join = if (& $has $cfg 'join') { $cfg.join } else { $null }
        $U.HasKey = [bool]((& $has $join 'apiKey') -and $join.apiKey.value)
        $U.Device = if (& $has $join 'device') { [string]$join.device } else { '' }
        $U.DeviceName = if (& $has $join 'deviceName') { [string]$join.deviceName } else { '' }
        $U.Pasting = $true
        $U.KeyBox.Password = ''
        $U.Pasting = $false
        if (-not $KeepDevices -or $U.DeviceBox.Items.Count -eq 0) { Set-ChatqPhoneSetupDevices $U @() $U.Device }
        else { Select-ChatqPhoneSetupDevice $U $U.Device }

        # switched on, whether or not a phone is paired: the status line says
        # which, and Pair phone mends it
        $U.ReplyOn = [bool](Get-ChatqReplyConfig $cfg).Wanted
        $U.ReplyBox.IsChecked = $U.ReplyOn
        # absent is every event; an empty list is none of them, as
        # Test-ChatqPhoneEvent reads it
        $pe = if ($cfg.PSObject.Properties['phoneEvents'] -and $null -ne $cfg.phoneEvents) { @($cfg.phoneEvents | ForEach-Object { [string]$_ }) } else { $null }
        foreach ($cb in $U.EventsPanel.Children) { $cb.IsChecked = ($null -eq $pe) -or ($pe -contains [string]$cb.Tag) }
        $U.EventsWas = Get-ChatqPhoneSetupEventsText $U
        $U.QuietWas = [int](Get-ChatqQuietMinutes $cfg)
        $U.QuietBox.Text = [string]$U.QuietWas
        # chats run in VS Code itself: on unless the file says false, as toast
        $U.LiveWas = -not ($cfg.PSObject.Properties['liveAlerts'] -and $cfg.liveAlerts -eq $false)
        $U.LiveBox.IsChecked = $U.LiveWas
        # a queued run's permission prompt asks the phone: off unless the file says on
        $pmc = Get-ChatqPermitConfig $cfg
        $U.PermitWas = [bool]$pmc.On
        $U.PermitBox.IsChecked = $U.PermitWas
        $U.PermitBox.IsEnabled = [bool]$U.ReplyBox.IsChecked
        $U.PermitHint.Text = "A queued run that needs a permission asks the phone - Allow once or Deny - and waits $($pmc.WaitMinutes) min. Off: it stops as needs input."
        # a chat's question answered from the phone (src/ask.ps1): off unless the
        # file says on
        $U.AskWas = [bool](Get-ChatqAskConfig $cfg).On
        $U.AskBox.IsChecked = $U.AskWas
        $U.AskBox.IsEnabled = [bool]$U.ReplyBox.IsChecked
        $U.ToastWas = -not ($cfg.PSObject.Properties['toast'] -and $cfg.toast -eq $false)
        $U.ToastBox.IsChecked = $U.ToastWas
        Read-ChatqBoardSetupForm $U $cfg

        $ntfy = if (& $has $cfg 'ntfy') { $cfg.ntfy } else { $null }
        $U.HasTopic = [bool]((& $has $ntfy 'topic') -and $ntfy.topic.value)
        $U.HasToken = [bool]((& $has $ntfy 'token') -and $ntfy.token.value)
        $U.ServerWas = if (& $has $ntfy 'server') { ([string]$ntfy.server).TrimEnd('/') } else { '' }
        $U.NtfyTopicBox.Password = ''
        $U.NtfyTokenBox.Password = ''
        $U.NtfyServerBox.Text = $U.ServerWas
        $U.CommandWas = if (& $has $cfg 'command') { [string]$cfg.command } else { '' }
        $U.CommandBox.Text = $U.CommandWas
        # the command given the reply link: off unless the file says on
        $U.CommandLinksWas = [bool]((& $has $cfg 'commandLinks') -and $cfg.commandLinks -eq $true)
        $U.CommandLinksBox.IsChecked = $U.CommandLinksWas
        Update-ChatqPhoneSetupGhosts $U
        Update-ChatqPhoneSetupReplyStatus $U
        Read-ChatqPhoneSetupExtras $U $cfg
        $U.Baseline = Get-ChatqPhoneSetupSnapshot $U
    }
    finally { $U.Loading = $false }
    Update-ChatqPhoneSetupDirty $U
}

function Update-ChatqPhoneSetupGhosts {
    # the faint words inside an empty box: what it wants, or that a secret is
    # stored and pasting replaces it
    param($U)
    $saved = 'saved - paste to replace'
    $U.KeyGhost.Text = if ($U.HasKey) { $saved } else { 'paste the API key, or the whole push URL' }
    $U.NtfyTopicGhost.Text = if ($U.HasTopic) { $saved } else { 'a long random topic, e.g. chatq-7f3a9c1e2b5d' }
    $U.NtfyTokenGhost.Text = if ($U.HasToken) { $saved } else { 'none' }
    $show = { param($empty) if ($empty) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
    $U.KeyGhost.Visibility = & $show (-not $U.KeyBox.Password)
    $U.NtfyTopicGhost.Visibility = & $show (-not $U.NtfyTopicBox.Password)
    $U.NtfyTokenGhost.Visibility = & $show (-not $U.NtfyTokenBox.Password)
    $U.NtfyServerGhost.Visibility = & $show (-not $U.NtfyServerBox.Text)
    # plain http said at once, not only on Save: an alert and its reply link
    # would cross the network readable by anyone on the way
    if ($U.NtfyServerBox.Text.Trim() -match '^http://') { Set-ChatqPhoneSetupNote $U $U.NtfyServerNote 'https only - over plain http anyone on the way reads the alerts.' 'warn' }
    else { Set-ChatqPhoneSetupNote $U $U.NtfyServerNote $script:ChatqPhoneSetupServerHint 'dim' }
}

function Get-ChatqPhoneSetupEventsText {
    param($U)
    return (@($U.EventsPanel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag }) -join ',')
}

function Get-ChatqPhoneSetupPicked {
    # the device picked in the list, or $null
    param($U)
    $it = $U.DeviceBox.SelectedItem
    if ($it -and $it.Tag) { return $it.Tag }
    return $null
}

function Test-ChatqPhoneSetupSameDevice {
    # Is this pick the saved device? By id, or by name: chatnotify -Device
    # takes a name, and once a lookup lists that device the list holds it
    # under its id - the same device, so neither unsaved nor a change.
    param($U, $Device)
    if (-not $Device) { return (-not $U.Device) }
    return ([string]$Device.Id -eq $U.Device -or ($Device.Name -and [string]$Device.Name -eq $U.Device))
}

function Get-ChatqPhoneSetupSnapshot {
    # everything the form says, as one string: unsaved means it differs from
    # the one taken when the form was last filled. Not the replies box: that
    # one is held against the file itself (ReplyOn), which pairing changes
    # while the form is open. Nor the questions box: held against the file
    # too (AskWas), which its background install changes while the form is open.
    param($U)
    $d = Get-ChatqPhoneSetupPicked $U
    $dev = if (-not $d) { '' } elseif (Test-ChatqPhoneSetupSameDevice $U $d) { '=' } else { [string]$d.Id }
    return (@($U.KeyBox.Password, $dev, (Get-ChatqPhoneSetupEventsText $U),
            $U.QuietBox.Text.Trim(), [bool]$U.LiveBox.IsChecked, [bool]$U.ToastBox.IsChecked, $U.NtfyTopicBox.Password, $U.NtfyServerBox.Text.Trim().TrimEnd('/'),
            $U.NtfyTokenBox.Password, $U.CommandBox.Text, [bool]$U.CommandLinksBox.IsChecked, [bool]$U.PermitBox.IsChecked, (Get-ChatqBoardSetupSnapshot $U)) -join "`n") + "`n" + (Get-ChatqPhoneSetupExtrasSnapshot $U)
}

function Test-ChatqPhoneSetupDirty {
    param($U)
    return ((Get-ChatqPhoneSetupSnapshot $U) -ne $U.Baseline -or [bool]$U.ReplyBox.IsChecked -ne [bool]$U.ReplyOn -or [bool]$U.AskBox.IsChecked -ne [bool]$U.AskWas)
}

function Update-ChatqPhoneSetupDirty {
    # Save is live only while there is something to save
    param($U)
    # permissions from the phone only while replies are on: nothing else answers them
    if ($U.PermitBox) { $U.PermitBox.IsEnabled = [bool]$U.ReplyBox.IsChecked }
    # and questions from the phone the same
    if ($U.AskBox) { $U.AskBox.IsEnabled = [bool]$U.ReplyBox.IsChecked }
    if ($U.Loading) { return }
    $d = Test-ChatqPhoneSetupDirty $U
    # and not while a push is under way: Save would write the file under it
    $U.SaveBtn.IsEnabled = $d -and -not $U.Job
    if (-not $d) { Hide-ChatqPhoneSetupBar $U }
}

function Set-ChatqPhoneSetupDevices {
    <#
    The device list: what a lookup found, Join's groups after it, and the
    saved device at the top when the lookup has not named it - so what is in
    force always shows. Picks -Want when it is there, else the only real
    device when there is exactly one, else leaves the pick as it was.
    #>
    param($U, [object[]]$Devices, [string]$Want)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($Devices)) {
        if (-not $d -or -not $d.Id) { continue }
        $list.Add([pscustomobject]@{ Id = [string]$d.Id; Name = [string]$d.Name; Model = [string]$d.Model; Type = [string]$d.Type })
    }
    foreach ($g in @(Get-ChatqPhoneSetupGroups)) {
        if (-not @($list | Where-Object { $_.Id -eq $g.Id }).Count) { $list.Add([pscustomobject]@{ Id = [string]$g.Id; Name = [string]$g.Name; Model = ''; Type = 'group' }) }
    }
    if ($Want -and -not @($list | Where-Object { $_.Id -eq $Want -or $_.Name -eq $Want }).Count) {
        $name = if ($Want -eq $U.Device -and $U.DeviceName) { $U.DeviceName } else { '' }
        $list.Insert(0, [pscustomobject]@{ Id = $Want; Name = $name; Model = ''; Type = '' })
    }
    $was = Get-ChatqPhoneSetupPicked $U
    $U.DeviceBox.Items.Clear()
    foreach ($d in $list) {
        $it = [System.Windows.Controls.ComboBoxItem]::new()
        $it.Content = Format-ChatqPhoneSetupDevice $d
        $it.Tag = $d
        [void]$U.DeviceBox.Items.Add($it)
    }
    $real = @($list | Where-Object { $_.Id -notlike 'group.*' -and $_.Name })
    if ($Want) { Select-ChatqPhoneSetupDevice $U $Want }
    elseif ($was) { Select-ChatqPhoneSetupDevice $U $was.Id }
    elseif (@($Devices).Count -and $real.Count -eq 1) { Select-ChatqPhoneSetupDevice $U $real[0].Id }
}

function Select-ChatqPhoneSetupDevice {
    # by id, or by name - chatnotify -Device takes a name as well
    param($U, [string]$Id)
    if (-not $Id) { return }
    foreach ($it in $U.DeviceBox.Items) {
        if ($it.Tag.Id -eq $Id) { $U.DeviceBox.SelectedItem = $it; return }
    }
    foreach ($it in $U.DeviceBox.Items) {
        if ($it.Tag.Name -and $it.Tag.Name -eq $Id) { $U.DeviceBox.SelectedItem = $it; return }
    }
}

function Update-ChatqPhoneSetupKey {
    # A paste into the key box. A whole push URL is taken apart; a whole key
    # - Join's are 32 hex digits - looks the devices up at once, so pasting
    # is all a first-time user has to do before picking one.
    param($U)
    if ($U.Pasting) { return }
    $x = ConvertFrom-ChatqJoinPaste $U.KeyBox.Password
    if ($x.FromUrl -and $x.Key) {
        $U.Pasting = $true
        try { $U.KeyBox.Password = $x.Key } finally { $U.Pasting = $false }
        if ($x.Device) {
            $U.Want = $x.Device
            if (-not @($U.DeviceBox.Items | Where-Object { $_.Tag.Id -eq $x.Device -or $_.Tag.Name -eq $x.Device }).Count) {
                Set-ChatqPhoneSetupDevices $U @(@($U.DeviceBox.Items | ForEach-Object { $_.Tag })) $x.Device
            }
            else { Select-ChatqPhoneSetupDevice $U $x.Device }
        }
        Set-ChatqPhoneSetupNote $U $U.Status 'took the key out of the URL you pasted' 'dim'
    }
    Update-ChatqPhoneSetupGhosts $U
    $key = $U.KeyBox.Password.Trim()
    if ($key -match '^[0-9a-fA-F]{32}$' -and $key -ne $U.FetchedKey) { Start-ChatqPhoneSetupFind $U }
    Update-ChatqPhoneSetupDirty $U
}

function Get-ChatqPhoneSetupLookupKey {
    # the key a lookup asks with: the one in the box, else the saved one
    param($U)
    $key = ([string]$U.KeyBox.Password).Trim()
    if (-not $key -and $U.HasKey) { $key = [string](Unprotect-ChatqSecret $U.Cfg.join.apiKey) }
    return $key
}

function Start-ChatqPhoneSetupFind {
    <#
    Find devices, off the window's thread: a WebClient task, looked at by the
    timer every 150 ms, so the window never waits on the network. One lookup
    at a time - a key changed while one runs is looked up when that one comes
    back (Update-ChatqPhoneSetupFind). The key in the box, else the saved
    one. -Force asks again for a key already looked up.
    #>
    param($U, [switch]$Force)
    if ($U.Fetch) { return }
    $key = Get-ChatqPhoneSetupLookupKey $U
    if (-not $key) {
        Set-ChatqPhoneSetupNote $U $U.DeviceNote 'Paste the API key first - the devices come from it.' 'warn'
        [void]$U.KeyBox.Focus()
        return
    }
    if (-not $Force -and $key -eq $U.FetchedKey) { return }
    $url = Get-ChatqJoinDevicesUrl -ApiKey $key
    $f = @{ Task = $null; Client = $null; Text = $null; At = Get-Date; Key = $key }
    try {
        if ($script:ChatqJoinDevicesSeam) { $f.Text = [string](& $script:ChatqJoinDevicesSeam $url) }   # tests: no network
        else {
            Enable-ChatqTls12
            $f.Client = New-Object System.Net.WebClient
            $f.Client.Encoding = [System.Text.Encoding]::UTF8
            $f.Task = $f.Client.DownloadStringTaskAsync([uri]$url)
        }
    }
    catch {
        if ($f.Client) { $f.Client.Dispose() }
        Set-ChatqPhoneSetupNote $U $U.DeviceNote "Could not ask Join: $($_.Exception.Message)" 'warn'
        return
    }
    $U.Fetch = $f
    $U.FindBtn.IsEnabled = $false
    $U.FindBtn.Content = 'Finding...'
    Set-ChatqPhoneSetupNote $U $U.DeviceNote 'Asking Join for your devices...' 'dim'
    Start-ChatqPhoneSetupTimer $U
}

function Start-ChatqPhoneSetupTimer {
    # One timer for all that runs off the window's thread: the device lookup,
    # a push being sent, a phone yet to answer its pairing alert. It stops
    # itself once none is left (Update-ChatqPhoneSetupTick).
    param($U)
    if ($U.Closing) { return }
    if (-not $U.Timer) {
        $t = [System.Windows.Threading.DispatcherTimer]::new()
        $t.Interval = [TimeSpan]::FromMilliseconds(150)
        $t.Tag = $U
        $t.add_Tick({ param($src, $e) Invoke-ChatqPhoneSetupAction $src.Tag.Win { param($U) Update-ChatqPhoneSetupTick $U } })
        $U.Timer = $t
    }
    if (-not $U.Timer.IsEnabled) { $U.Timer.Start() }
}

function Update-ChatqPhoneSetupTick {
    param($U)
    if ($U.Fetch) { Update-ChatqPhoneSetupFind $U }
    if ($U.Job) { Update-ChatqPhoneSetupJob $U }
    if ($U.WaitPair -and (Get-Date) -ge $U.NextLook) {
        # The files, not the form: the watcher puts each answer to the
        # pairing alert into replies.json as it comes in, and a confirm
        # from a shell (chatnotify -Confirm) pairs through config.json.
        # Two small reads every second and a half, and only while a
        # pairing waits.
        $U.NextLook = (Get-Date).AddMilliseconds(1500)
        $U.Cfg = Get-ChatqConfig
        Update-ChatqPhoneSetupReplyStatus $U
    }
    if (-not $U.Fetch -and -not $U.Job -and -not $U.WaitPair -and $U.Timer) { $U.Timer.Stop() }
}

function Update-ChatqPhoneSetupFind {
    # the timer's look at the lookup: nothing until it is done, or 15 s pass
    param($U)
    $f = $U.Fetch
    if (-not $f) { return }
    $done = ($null -ne $f.Text) -or $f.Task.IsCompleted
    $late = (-not $done) -and ((Get-Date) - $f.At).TotalSeconds -ge 15
    if (-not $done -and -not $late) { return }
    if ($late) { try { $f.Client.CancelAsync() } catch {} }
    # The key changed while this one was being asked about: the answer is
    # the old key's - another account's devices, perhaps - so it is dropped,
    # and the key in the box now is asked about instead.
    $now = Get-ChatqPhoneSetupLookupKey $U
    if ($now -ne $f.Key) {
        Stop-ChatqPhoneSetupFind $U
        $whole = $now -match '^[0-9a-fA-F]{32}$' -or ($now -and -not ([string]$U.KeyBox.Password).Trim())
        if ($whole) { Start-ChatqPhoneSetupFind $U -Force }
        else { Set-ChatqPhoneSetupNote $U $U.DeviceNote 'The key changed - Find devices looks this one up.' 'dim' }
        return
    }
    $text = $null
    $err = $null
    if ($null -ne $f.Text) { $text = $f.Text }
    elseif ($late) { $err = 'Join did not answer in 15 s - try again' }
    elseif ($f.Task.IsFaulted) {
        $x = $f.Task.Exception
        while ($x.InnerException) { $x = $x.InnerException }
        $err = "Could not reach Join: $($x.Message)"
    }
    elseif ($f.Task.IsCanceled) { $err = 'Join did not answer in 15 s - try again' }
    else { $text = $f.Task.Result }
    Stop-ChatqPhoneSetupFind $U
    if (-not $err) {
        $r = ConvertFrom-ChatqJoinDevices $text
        if ($r.Error) { $err = "Join: $($r.Error)" }
    }
    if ($err) { Set-ChatqPhoneSetupNote $U $U.DeviceNote $err 'warn'; return }
    $U.FetchedKey = $f.Key
    $want = if ($U.Want) { $U.Want } else { $U.Device }
    $U.Want = ''
    Set-ChatqPhoneSetupDevices $U @($r.Devices) $want
    $n = @($r.Devices | Where-Object { $_.Id -notlike 'group.*' }).Count
    $say = if ($n -eq 1) { 'Found 1 device.' } else { "Found $n devices." }
    $say += if (Get-ChatqPhoneSetupPicked $U) { ' Send test, then Save.' } else { ' Pick where alerts go.' }
    Set-ChatqPhoneSetupNote $U $U.DeviceNote $say 'ok'
    if (-not (Get-ChatqPhoneSetupPicked $U)) { $U.DeviceBox.IsDropDownOpen = $U.Win.IsVisible -and $U.Win.IsActive }
    Update-ChatqPhoneSetupDirty $U
}

function Stop-ChatqPhoneSetupFind {
    # the lookup let go of: its client disposed, the button back
    param($U)
    $f = $U.Fetch
    $U.Fetch = $null
    if ($f -and $f.Client) { try { $f.Client.Dispose() } catch {} }
    if ($U.FindBtn) { $U.FindBtn.IsEnabled = $true; $U.FindBtn.Content = 'Find devices' }
}

function Test-ChatqPhoneSetupPaired {
    # a phone paired, as config.json said when the form last read it
    param($U)
    try { return [bool](Get-ChatqReplyConfig $U.Cfg).Paired } catch { return $false }
}

function Get-ChatqPhoneSetupChanges {
    <#
    What Save hands Set-ChatqNotifyConfig: only what differs from the file,
    keyed like chatnotify's own switches. @{ Changes; Error; Pair } - an
    Error (quiet minutes that are not a number) saves nothing. Pair: replies
    switched on with no phone paired, which is a pairing as well as a
    setting - Save writes replies on, then starts the pairing in the
    background (Start-ChatqPhoneSetupJob), never on this thread, since it
    sends a push.
    #>
    param($U)
    $c = @{}
    $key = ([string]$U.KeyBox.Password).Trim()
    if ($key) { $c.ApiKey = $key }
    $d = Get-ChatqPhoneSetupPicked $U
    if ($d -and -not (Test-ChatqPhoneSetupSameDevice $U $d)) {
        $c.Device = $d.Id
        if ($d.Name) { $c.DeviceName = $d.Name }
    }
    elseif ($d -and [string]$d.Id -eq $U.Device -and $d.Name -and $d.Name -ne $U.DeviceName) { $c.DeviceName = $d.Name }
    $pair = $false
    $on = [bool]$U.ReplyBox.IsChecked
    if ($on -and -not $U.ReplyOn) {
        if (Test-ChatqPhoneSetupPaired $U) { $c.Reply = 'on' } else { $pair = $true }
    }
    elseif (-not $on -and $U.ReplyOn) { $c.Reply = 'off' }
    $ev = @($U.EventsPanel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    if (($ev -join ',') -ne $U.EventsWas) {
        # none is refused rather than saved: Set-ChatqNotifyConfig reads an
        # empty list as every event, the opposite of what the boxes say
        if (-not $ev.Count) { return @{ Changes = @{}; Error = 'Tick at least one event - or leave the Join key out to keep the phone out of it.'; Pair = $false } }
        # every one ticked is no filter at all, so events added later go too
        $c.Events = if ($ev.Count -eq @($script:ChatqPhoneEvents).Count) { @('all') } else { [string[]]$ev }
    }
    $qm = 0
    if (-not [int]::TryParse($U.QuietBox.Text.Trim(), [ref]$qm) -or $qm -lt 0 -or $qm -gt 1440) {
        return @{ Changes = @{}; Error = 'Quiet minutes: a whole number from 0 to 1440.'; Pair = $false }
    }
    if ($qm -ne $U.QuietWas) { $c.QuietMinutes = $qm }
    $live = [bool]$U.LiveBox.IsChecked
    if ($live -ne $U.LiveWas) { $c.LiveAlerts = $live }
    $permit = [bool]$U.PermitBox.IsChecked
    if ($permit -ne [bool]$U.PermitWas) { $c.Permit = if ($permit) { 'on' } else { 'off' } }
    # Ask: Save takes it out again and runs it in the background, the install
    # being several claude plugin commands (Start-ChatqPhoneSetupJob 'ask')
    $ask = [bool]$U.AskBox.IsChecked
    if ($ask -ne [bool]$U.AskWas) { $c.Ask = if ($ask) { 'on' } else { 'off' } }
    $toast = [bool]$U.ToastBox.IsChecked
    if ($toast -ne $U.ToastWas) { $c.Toast = if ($toast) { 'on' } else { 'off' } }
    $topic = ([string]$U.NtfyTopicBox.Password).Trim()
    if ($topic) { $c.Ntfy = $topic }
    $server = $U.NtfyServerBox.Text.Trim().TrimEnd('/')
    $token = ([string]$U.NtfyTokenBox.Password).Trim()
    if (($server -and $server -ne $U.ServerWas) -or $token) {
        # a server or token alone would make an ntfy channel with no topic,
        # which then fails on every alert
        if (-not $topic -and -not $U.HasTopic) { return @{ Changes = @{}; Error = 'ntfy: the topic first - the server and token go with it.'; Pair = $false } }
        if ($server -and $server -ne $U.ServerWas) {
            # https only: over plain http the alert, its reply link and the
            # token cross the network for anyone on the way to read
            if ($server -notmatch '^https://[^/\s]') { return @{ Changes = @{}; Error = 'ntfy server: https only, like https://ntfy.sh'; Pair = $false } }
            $c.NtfyServer = $server
        }
        if ($token) { $c.NtfyToken = $token }
    }
    elseif (-not $server -and $U.ServerWas) { $c.NtfyServer = 'https://ntfy.sh' }
    if ($U.CommandBox.Text -ne $U.CommandWas) { $c.Command = $U.CommandBox.Text }
    $links = [bool]$U.CommandLinksBox.IsChecked
    if ($links -ne $U.CommandLinksWas) { $c.CommandLinks = if ($links) { 'on' } else { 'off' } }
    Add-ChatqBoardSetupChanges $U $c
    $xe = Add-ChatqPhoneSetupExtrasChanges $U $c
    if ($xe) { return @{ Changes = @{}; Error = $xe; Pair = $false } }
    return @{ Changes = $c; Error = $null; Pair = $pair }
}

function Save-ChatqPhoneSetup {
    <#
    Save: the changes through Set-ChatqNotifyConfig, then the form read back
    from the file. Replies switched on with no phone paired - or -Pair, the
    button - are saved on first and then go on to pair, in the background.
    $true when saved, or when there was nothing to save. -Quiet: says
    nothing when there was nothing to save (Send test, Pair phone).
    #>
    param($U, [switch]$Quiet, [switch]$Pair)
    if ($U.Job) { Set-ChatqPhoneSetupNote $U $U.Status 'wait - a push is still on its way' 'warn'; return $false }
    $r = Get-ChatqPhoneSetupChanges $U
    if ($r.Error) { Set-ChatqPhoneSetupNote $U $U.Status $r.Error 'warn'; return $false }
    $pair = [bool]($Pair -or $r.Pair)
    # The question hook is not among the keys Set-ChatqNotifyConfig gets here:
    # its install runs several claude plugin commands, so it goes to the
    # background after the rest is saved. With a pairing still to come it
    # waits for the next Save - a question needs a paired phone to reach.
    $askWant = $null
    if ($r.Changes.ContainsKey('Ask')) { $askWant = [string]$r.Changes.Ask; $r.Changes.Remove('Ask') }
    # The pairing alert needs a way to the phone - the one saved, or the one
    # this Save saves, your command given the link among them. Without one,
    # the rest is saved and the box stays ticked, unsaved, with the note
    # saying what is missing.
    $cmdWay = [bool]$U.CommandLinksBox.IsChecked -and ([string]$U.CommandBox.Text).Trim()
    $noWay = $pair -and -not ($U.HasKey -or $U.HasTopic -or ([string]$U.KeyBox.Password).Trim() -or ([string]$U.NtfyTopicBox.Password).Trim() -or $cmdWay)
    if ($noWay) { $pair = $false; $r.Changes.Remove('Reply') }
    # Replies on goes into the file before the pairing starts, not after, so
    # the setting stands whatever becomes of the push - the window closed
    # under it, or Join down.
    elseif ($pair -and -not $U.ReplyOn) { $r.Changes.Reply = 'on' }
    if (-not $r.Changes.Count -and -not $pair -and -not $noWay -and -not $askWant) {
        if (-not $Quiet) { Set-ChatqPhoneSetupNote $U $U.Status 'nothing to save' 'dim' }
        return $true
    }
    if ($r.Changes.Count) {
        $res = try { Set-ChatqNotifyConfig $r.Changes 6>$null } catch { [pscustomobject]@{ Error = $_.Exception.Message; Messages = @() } }
        # its lines are for a console; the one worth the status line is a warning
        $warn = @(@($res.Messages) | Where-Object { $_ -and $_.Color -eq 'Yellow' } | ForEach-Object { [string]$_.Text })
        if ($res.Error) {
            $why = if ($warn) { $warn[-1] } else { [string]$res.Error }
            Set-ChatqPhoneSetupNote $U $U.Status "not saved: $why" 'error'
            return $false
        }
        Read-ChatqPhoneSetupForm $U -KeepDevices
        if ($warn) { Set-ChatqPhoneSetupNote $U $U.Status "saved - $($warn[-1])" 'warn' }
        else { Set-ChatqPhoneSetupNote $U $U.Status "saved $((Get-Date).ToString('HH:mm'))" 'ok' }
    }
    # the form read back from the file put the questions box back as it was
    # saved: it stays as ticked until its install ends, or until the next Save
    if ($askWant) { $U.AskBox.IsChecked = ($askWant -eq 'on') }
    if ($askWant -and ($pair -or $noWay)) {
        Set-ChatqPhoneSetupNote $U $U.Status 'the question hook goes in on the next Save, once the phone is paired' 'warn'
        Update-ChatqPhoneSetupDirty $U
    }
    elseif ($askWant -and -not (Start-ChatqPhoneSetupJob $U 'ask' -Arg $askWant)) {
        Update-ChatqPhoneSetupDirty $U
        return $false
    }
    if ($noWay) {
        $U.ReplyBox.IsChecked = $true
        Set-ChatqPhoneSetupNote $U $U.PairNote 'Pairing goes to the phone as an alert - the Join key (or an ntfy topic) first.' 'warn'
        Update-ChatqPhoneSetupReplyStatus $U
        Update-ChatqPhoneSetupDirty $U
        return $false
    }
    if (-not $pair) { return $true }
    # a new pairing: whatever the last one's failure said is past
    $U.PairFailed = $null
    if (-not (Start-ChatqPhoneSetupJob $U 'pair')) {
        Update-ChatqPhoneSetupReplyStatus $U
        Update-ChatqPhoneSetupDirty $U
        return $false
    }
    Set-ChatqPhoneSetupNote $U $U.PairNote 'The phone gets it in a moment. Closing this window does not stop it.' 'dim'
    Update-ChatqPhoneSetupReplyStatus $U
    return $true
}

function Invoke-ChatqPhoneSetupTest {
    # Send test: saved first, so the test goes where the form says; the push
    # itself in the background, the window live meanwhile
    param($U)
    if ($U.Job) { return }
    if (-not (Save-ChatqPhoneSetup $U -Quiet)) { return }
    if ($U.Job) {
        # the save began the question hook's install: the test waits for it
        if ($U.Job.Kind -eq 'ask') { Set-ChatqPhoneSetupNote $U $U.TestNote 'saved - send the test again once the question hook is in' 'warn'; return }
        # the save switched replies on and so began pairing: that push takes
        # the same way to the phone, so it is the test
        Set-ChatqPhoneSetupNote $U $U.TestNote 'the pairing alert goes instead - it takes the same way' 'dim'
        return
    }
    if (Start-ChatqPhoneSetupJob $U 'test') { Set-ChatqPhoneSetupNote $U $U.TestNote 'sending...' 'dim' }
}

function Invoke-ChatqPhoneSetupPair {
    # Pair phone: the form saved first, so the pairing alert goes where it
    # says, then the pairing itself in the background. The replies box
    # ticks: a pairing is for replies, so Save writes them on with it.
    param($U)
    if ($U.Job) { return }
    $U.ReplyBox.IsChecked = $true
    [void](Save-ChatqPhoneSetup $U -Quiet -Pair)
}

function Start-ChatqPhoneSetupJob {
    <#
    Send test, Pair phone or a pairing answer's Confirm, in a runspace of its
    own ($script:ChatqPhoneSetupJobCode): the timer looks in on it, and the
    buttons that would start a second push or save over this one are off
    until it ends. -Arg: the answer's id, for confirm. $true when it
    started.
    #>
    param($U, [ValidateSet('test', 'pair', 'confirm', 'ask')][string]$Kind, [string]$Arg = '')
    if ($U.Job) { return $false }
    $note = switch ($Kind) { 'test' { $U.TestNote } 'ask' { $U.Status } default { $U.PairNote } }
    $path = $script:ChatqScriptPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        Set-ChatqPhoneSetupNote $U $note 'not sent: this window does not know where Charlie-and-the-chat-factory.ps1 is' 'error'
        return $false
    }
    $text = if ($Kind -eq 'test') { "chatq reaches this device $($script:ChatqDot) $([Environment]::MachineName)" } else { $Arg }
    $j = @{ Kind = $Kind; At = Get-Date; Ps = $null; Rs = $null; Handle = $null; Arg = $Arg }
    try {
        # the lean default: opening it is on this thread, and what the script
        # needs beyond the core commands loads on first use, over there
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
        # as the dialog's own process was started: the runspace loads the
        # same script, and the machine's policy may refuse it. The job
        # drops it again once loaded (the note on its code says why).
        try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch {}
        $j.Rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $j.Rs.Open()
        $j.Ps = [System.Management.Automation.PowerShell]::Create()
        $j.Ps.Runspace = $j.Rs
        [void]$j.Ps.AddScript($script:ChatqPhoneSetupJobCode).AddArgument($path).AddArgument([string]$script:ChatqPhoneSetupJobSeam).AddArgument($Kind).AddArgument($text)
        $j.Handle = $j.Ps.BeginInvoke()
    }
    catch {
        Close-ChatqPhoneSetupJobHandles $j
        Set-ChatqPhoneSetupNote $U $note "not sent: $($_.Exception.Message)" 'error'
        return $false
    }
    $U.Job = $j
    Update-ChatqPhoneSetupBusy $U
    Start-ChatqPhoneSetupTimer $U
    if ($Kind -eq 'ask') { Set-ChatqPhoneSetupNote $U $U.Status "$(if ($Arg -eq 'on') { 'installing' } else { 'removing' }) the question hook..." 'dim' }
    return $true
}

function Update-ChatqPhoneSetupJob {
    # the timer's look at a push under way: how long it has taken so far,
    # then what came of it
    param($U)
    $j = $U.Job
    if (-not $j) { return }
    $note = switch ($j.Kind) { 'test' { $U.TestNote } 'ask' { $U.Status } default { $U.PairNote } }
    if (-not $j.Handle.IsCompleted) {
        $sec = [int][Math]::Floor(((Get-Date) - $j.At).TotalSeconds)
        # past a few seconds, the count says it is still going and not stuck
        if ($sec -ge 3) {
            $what = switch ($j.Kind) {
                'pair' { "still sending - $sec s. Closing this window does not stop it." }
                'confirm' { "pairing - $sec s. Closing this window does not stop it." }
                'ask' { "$(if ($j.Arg -eq 'on') { 'installing' } else { 'removing' }) the question hook... $sec s. Closing this window does not stop it." }
                default { "sending... $sec s" }
            }
            Set-ChatqPhoneSetupNote $U $note $what 'dim'
        }
        return
    }
    $U.Job = $null
    $res = $null
    $err = $null
    try {
        $out = $j.Ps.EndInvoke($j.Handle)
        $res = @($out | Where-Object { $_ -and $_.PSObject.Properties['ChatqSetupJob'] }) | Select-Object -Last 1
    }
    catch {
        $x = $_.Exception
        while ($x.InnerException) { $x = $x.InnerException }
        $err = $x.Message
    }
    if (-not $res -and -not $err) {
        $e1 = @($j.Ps.Streams.Error) | Select-Object -First 1
        $err = if ($e1) { [string]$e1 } else { 'it ended without saying how it went' }
    }
    Close-ChatqPhoneSetupJobHandles $j
    if ($err) { Write-ChatqPhoneSetupLog "$($j.Kind): $err" }
    Update-ChatqPhoneSetupBusy $U
    switch ($j.Kind) {
        'pair' { Complete-ChatqPhoneSetupPair $U $res $err }
        'confirm' { Complete-ChatqPhoneSetupConfirm $U $res $err }
        'ask' { Complete-ChatqPhoneSetupAsk $U $res $err $j.Arg }
        default { Complete-ChatqPhoneSetupTest $U $res $err }
    }
}

function Complete-ChatqPhoneSetupAsk {
    <#
    The question hook's install or removal ended. The file says whether it
    took (a failed install leaves ask.on off), so the box follows it - unless
    it was changed while the job ran. The status line gets what
    Set-ChatqNotifyConfig said: its green and yellow lines, the full text as
    the tooltip.
    #>
    param($U, $Res, [string]$Err, [string]$Want)
    $U.Cfg = Get-ChatqConfig
    $was = ($Want -eq 'on')
    $now = $false
    try { $now = [bool](Get-ChatqAskConfig $U.Cfg).On } catch {}
    if ([bool]$U.AskBox.IsChecked -eq $was) { $U.AskBox.IsChecked = $now }
    $U.AskWas = $now
    $lines = if ($Res) { @(@($Res.Messages) | Where-Object { $_ -and $_.Color -in 'Green', 'Yellow' -and $_.Text } | ForEach-Object { [string]$_.Text }) } else { @() }
    $warned = [bool]($Res -and @(@($Res.Messages) | Where-Object { $_ -and $_.Color -eq 'Yellow' }).Count)
    if ($Err) { $say = "the question hook: $Err"; $tone = 'error' }
    elseif ($Res.Error) { $say = "the question hook: $($Res.Error)"; $tone = 'warn' }
    else {
        $say = if ($lines) { $lines -join '; ' } else { 'the question hook is done' }
        $tone = if ($now -eq $was -and -not $warned) { 'ok' } else { 'warn' }
    }
    Set-ChatqPhoneSetupNote $U $U.Status $say $tone
    Update-ChatqPhoneSetupDirty $U
}

function Complete-ChatqPhoneSetupTest {
    param($U, $Res, [string]$Err)
    $lines = if ($Res) { @($Res.Lines | Where-Object { $_ }) } else { @() }
    if ($Err) { $say = "not sent: $Err"; $tone = 'error' }
    elseif ($Res.Ok) { $say = 'sent - check your phone'; $tone = 'ok' }
    else {
        $say = if ($Res.Error -eq 'no phone channel set up') { 'no phone channel yet - paste the Join key first' } else { 'not sent' }
        $tone = 'warn'
    }
    if ($lines) { $say += " ($($lines -join '; '))" }
    Set-ChatqPhoneSetupNote $U $U.TestNote $say $tone
    $U.Cfg = Get-ChatqConfig
    Update-ChatqPhoneSetupReplyStatus $U
}

function Complete-ChatqPhoneSetupPair {
    # The file says whether replies are on now: Save wrote them on before the
    # pairing began, so a failure leaves them on. The box follows the file
    # unless it was changed while the push was on its way. A pairing alert
    # that did not go out is remembered (PairFailed): the pairing it began is
    # in config.json for 15 minutes all the same, and "waiting for the
    # phone" would send the user looking for an alert that never came.
    param($U, $Res, [string]$Err)
    $U.Cfg = Get-ChatqConfig
    $was = [bool]$U.ReplyOn
    $now = $false
    $rc = $null
    try { $rc = Get-ChatqReplyConfig $U.Cfg; $now = [bool]$rc.Wanted } catch {}
    if ([bool]$U.ReplyBox.IsChecked -eq $was) { $U.ReplyBox.IsChecked = $now }
    $U.ReplyOn = $now
    $ok = [bool]($Res -and $Res.Ok -and -not $Err)
    $U.PairFailed = if ($ok) { $null } else { @{ Until = $(if ($rc) { ConvertTo-ChatqDate $rc.PairUntil } else { $null }) } }
    $lines = if ($Res) { @($Res.Lines | Where-Object { $_ }) } else { @() }
    if ($Err) { $say = "pairing not sent: $Err"; $tone = 'error' }
    elseif ($ok) { $say = 'sent - open it on the phone and tap Pair, then confirm here the code the phone shows'; $tone = 'ok' }
    else {
        $say = if ($Res.Error) { "pairing not sent: $($Res.Error)" } else { 'pairing not sent' }
        $tone = 'warn'
    }
    if ($lines -and -not $ok) { $say += " ($($lines -join '; '))" }
    Set-ChatqPhoneSetupNote $U $U.PairNote $say $tone
    Update-ChatqPhoneSetupReplyStatus $U
    Update-ChatqPhoneSetupDirty $U
}

function Invoke-ChatqPhoneSetupConfirm {
    # Confirm on one answer to the pairing alert: that phone's key taken, the
    # pairing closed, a push to the phone to say so - in the background, as
    # the push may take a while
    param($U, [string]$Id)
    if ($U.Job -or -not $Id) { return }
    $c = @($U.Cands | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $c) { return }
    if (-not (Start-ChatqPhoneSetupJob $U 'confirm' -Arg $Id)) { return }
    $U.Job.Label = [string]$c.Label
    Set-ChatqPhoneSetupNote $U $U.PairNote "pairing with $($c.Label) - code $($c.Code)..." 'dim'
    Update-ChatqPhoneSetupReplyStatus $U
}

function Complete-ChatqPhoneSetupConfirm {
    # The file says whether it took: the status line reads it afresh, and the
    # footer names the phone
    param($U, $Res, [string]$Err)
    $U.Cfg = Get-ChatqConfig
    if ($Err -or -not ($Res -and $Res.Ok)) {
        $why = if ($Err) { $Err } elseif ($Res -and $Res.Error) { [string]$Res.Error } else { 'it did not say why' }
        Update-ChatqPhoneSetupReplyStatus $U
        Set-ChatqPhoneSetupNote $U $U.PairNote "not paired: $why" 'error'
        return
    }
    Update-ChatqPhoneSetupReplyStatus $U
    $label = if ($Res.Label) { [string]$Res.Label } else { 'the phone' }
    Set-ChatqPhoneSetupNote $U $U.PairNote $script:ChatqPhoneSetupPairHint 'dim'
    # paired either way: the push only says so, and a reply works without it
    if ($Res.Sent -eq $false) {
        $lines = @($Res.Lines | Where-Object { $_ })
        Set-ChatqPhoneSetupNote $U $U.Status "paired with $label - the push to say so did not go out$(if ($lines) { " ($($lines -join '; '))" })" 'warn'
    }
    else { Set-ChatqPhoneSetupNote $U $U.Status "paired with $label - it gets a push to say so" 'ok' }
}

function Update-ChatqPhoneSetupBusy {
    # while a push is under way: no second one, and no Save to write the
    # file under it
    param($U)
    $busy = [bool]$U.Job
    $U.TestBtn.IsEnabled = -not $busy
    $U.PairBtn.IsEnabled = -not $busy
    $U.BarSave.IsEnabled = -not $busy
    foreach ($b in @(Get-ChatqPhoneSetupConfirmButtons $U)) { $b.IsEnabled = -not $busy }
    Update-ChatqPhoneSetupDirty $U
}

function Stop-ChatqPhoneSetupJob {
    <#
    A push the window no longer waits for: it is closing. A test push is
    asked to stop, not waited on - one stuck in Join's retries would hold
    the close for minutes. A pairing alert or a confirmation is never
    stopped: by the time it runs the phone paired before has lost its key,
    and one cut off halfway leaves a pairing nobody was told about, or a key
    taken with no push to say so. Either way it is kept in a list, so the
    end of Show-ChatqPhoneSetup waits for it and disposes of it
    (Clear-ChatqPhoneSetupOrphans).
    #>
    param($U)
    $j = $U.Job
    $U.Job = $null
    if (-not $j) { return }
    if ($j.Handle -and -not $j.Handle.IsCompleted) {
        if ($j.Kind -eq 'test') { try { [void]$j.Ps.BeginStop($null, $null) } catch {} }
        else { Write-ChatqPhoneSetupLog "closed while the $(switch ($j.Kind) { 'pair' { 'pairing alert' } 'ask' { 'question hook change' } default { 'confirmation' } }) was on its way - it goes on" }
        $script:ChatqPhoneSetupOrphans.Add($j)
    }
    else { Close-ChatqPhoneSetupJobHandles $j }
    if ($U.TestBtn) { Update-ChatqPhoneSetupBusy $U }
}

function Clear-ChatqPhoneSetupOrphans {
    # The pushes a closed window let go of: each disposed once it has ended.
    # A stopped test push is waited for -WaitMs at most; a pairing alert or
    # a confirmation, which nothing stops, -PairWaitMs - after that the
    # process ends and takes it along, and the log says so.
    param([int]$WaitMs = 0, [int]$PairWaitMs = 0)
    $t0 = Get-Date
    foreach ($j in @($script:ChatqPhoneSetupOrphans)) {
        $limit = if ($j.Kind -eq 'test') { $WaitMs } else { $PairWaitMs }
        $done = [bool]$j.Handle.IsCompleted
        if (-not $done) {
            $left = [int][Math]::Max(0, ($t0.AddMilliseconds($limit) - (Get-Date)).TotalMilliseconds)
            try { $done = $j.Handle.AsyncWaitHandle.WaitOne($left) } catch {}
        }
        if ($done) { Close-ChatqPhoneSetupJobHandles $j; [void]$script:ChatqPhoneSetupOrphans.Remove($j) }
        elseif ($j.Kind -ne 'test' -and $PairWaitMs -gt 0) { Write-ChatqPhoneSetupLog "the $($j.Kind) push still had not ended after $([int]($PairWaitMs / 1000)) s - left behind" }
    }
}

function Close-ChatqPhoneSetupJobHandles {
    param($Job)
    if ($Job.Ps) { try { $Job.Ps.Dispose() } catch {} }
    if ($Job.Rs) { try { $Job.Rs.Dispose() } catch {} }
}

function Stop-ChatqPhoneSetupWork {
    # everything off the window's thread let go of: the window is closing
    param($U)
    $U.WaitPair = $false
    Stop-ChatqPhoneSetupFind $U
    Stop-ChatqPhoneSetupJob $U
    if ($U.Timer) { $U.Timer.Stop() }
}

function Get-ChatqPhoneSetupReplyText {
    # What Save will do while the box and the file disagree, else the
    # backend's own line (Get-ChatqPhoneStatusText), as chatnotify prints
    # it: "paired - ... - listening until 02:10", "waiting for the phone",
    # "not paired", or off
    param($Cfg, [bool]$Saved, [bool]$Ticked, [bool]$Paired)
    if ($Ticked -and -not $Saved) {
        if ($Paired) { return 'on once saved' }
        return 'not paired - Save sends the phone a pairing alert'
    }
    if (-not $Ticked -and $Saved) { return 'off once saved' }
    if (-not $Saved) { return 'off' }
    try { $t = [string](Get-ChatqPhoneStatusText $Cfg); if ($t) { return $t } } catch {}
    return 'on'
}

function Update-ChatqPhoneSetupReplyStatus {
    <#
    The replies line and its colour, and the answers to a pairing alert.
    While a pairing waits on the phone, the timer reads config.json and
    replies.json every second and a half, so each answer shows as it comes
    in and "paired" shows the moment one is confirmed - here or from a
    shell. What the dialog itself is doing comes first: a pairing alert
    being sent, a confirmation under way, or a pairing alert that did not go
    out, which the file alone would call "waiting for the phone".
    #>
    param($U)
    $rc = $null
    try { $rc = Get-ChatqReplyConfig $U.Cfg } catch {}
    $paired = [bool]($rc -and $rc.Paired)
    # through ConvertTo-ChatqDate even as a [datetime]: a UTC one compares
    # with Get-Date by its digits alone, hours off
    $pu = if ($rc) { ConvertTo-ChatqDate $rc.PairUntil } else { $null }
    $sending = [bool]($U.Job -and $U.Job.Kind -eq 'pair')
    $confirming = [bool]($U.Job -and $U.Job.Kind -eq 'confirm')
    # the failed pairing is the one still in the file, not a newer one a
    # shell began since
    $failed = $false
    if ($U.PairFailed -and -not $paired -and -not $sending) {
        $fu = $U.PairFailed.Until
        $failed = (-not $fu -and -not $pu) -or ($fu -and $pu -and [Math]::Abs(($fu - $pu).TotalSeconds) -lt 2)
        if (-not $failed) { $U.PairFailed = $null }
    }
    $waiting = [bool]($U.ReplyOn -and -not $paired -and $pu -and $pu -gt (Get-Date) -and -not $failed -and -not $sending)
    $ticked = [bool]$U.ReplyBox.IsChecked
    if ($sending) { $t = 'sending the pairing alert...'; $tone = 'dim' }
    elseif ($confirming) { $t = "pairing with $($U.Job.Label)..."; $tone = 'dim' }
    elseif ($failed -and $ticked -eq [bool]$U.ReplyOn) { $t = 'not paired - the pairing alert did not go out'; $tone = 'warn' }
    else {
        $t = Get-ChatqPhoneSetupReplyText $U.Cfg $U.ReplyOn $ticked $paired
        $tone = if ($ticked -ne [bool]$U.ReplyOn -or -not $U.ReplyOn) { 'dim' } elseif ($paired) { 'ok' } else { 'warn' }
    }
    Set-ChatqPhoneSetupNote $U $U.ReplyStatus $t $tone
    if ($U.WaitPair -and $paired) {
        # the moment it pairs: the line above says so in green, the note
        # goes back to what pairing again would do, and the footer says it
        # happened
        Set-ChatqPhoneSetupNote $U $U.PairNote $script:ChatqPhoneSetupPairHint 'dim'
        Set-ChatqPhoneSetupNote $U $U.Status 'the phone is paired - it gets a push to say so' 'ok'
    }
    elseif ($U.WaitPair -and -not $waiting -and -not $U.Job) {
        # the 15 minutes ran out with nothing confirmed: "sent - tap Pair"
        # would be stale advice
        Set-ChatqPhoneSetupNote $U $U.PairNote $script:ChatqPhoneSetupPairHint 'dim'
    }
    Set-ChatqPhoneSetupCandidates $U $(if ($waiting -or $confirming) { @(Get-ChatqPhoneSetupCandidates $U) } else { @() })
    $U.WaitPair = $waiting -and -not $U.Closing
    if ($U.WaitPair) { Start-ChatqPhoneSetupTimer $U }
}

function Get-ChatqPhoneSetupCandidates {
    # The answers to the open pairing, from the backend: @{ Id; Label; Code;
    # At }, the code as the phone shows it ("123 456") and At as local
    # time. None when the backend cannot say - an older script, or
    # replies.json unreadable for a moment.
    param($U)
    $out = @()
    if (-not (Get-Command Get-ChatqPairCandidates -EA SilentlyContinue)) { return $out }
    $raw = @()
    try { $raw = @(Get-ChatqPairCandidates $U.Cfg) } catch { return $out }
    foreach ($c in $raw) {
        if (-not $c -or -not $c.Id) { continue }
        $code = ([string]$c.Code) -replace '\s', ''
        if ($code -match '^\d{6}$') { $code = $code.Substring(0, 3) + ' ' + $code.Substring(3) }
        # local already: a second ToLocalTime would shift a time with no
        # zone on it by the UTC offset
        $at = ConvertTo-ChatqDate $c.At
        $out += [pscustomobject]@{ Id = [string]$c.Id; Label = $(if ($c.Label) { [string]$c.Label } else { 'a phone' }); Code = $code; At = $at }
    }
    return $out
}

function Set-ChatqPhoneSetupCandidates {
    <#
    The answers as rows - the code large, who sent it and when, and Confirm.
    Built again only when the answers change, so a row under the mouse or
    holding the keyboard focus is not swapped out every poll. Hidden with
    none.
    #>
    param($U, [object[]]$Cands)
    $Cands = @($Cands | Where-Object { $_ })
    $U.Cands = $Cands
    $sig = (@($Cands | ForEach-Object { "$($_.Id)|$($_.Code)|$($_.Label)" }) -join ';')
    if ($sig -ne $U.CandSig) {
        $U.CandSig = $sig
        $U.CandList.Children.Clear()
        foreach ($c in $Cands) {
            $row = [System.Windows.Controls.DockPanel]::new()
            $row.Margin = [System.Windows.Thickness]::new(0, 2, 0, 6)
            $row.LastChildFill = $true
            $b = [System.Windows.Controls.Button]::new()
            $b.Content = 'Confirm'
            $b.Tag = $c.Id
            $b.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
            $b.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $b.ToolTip = "Pair this phone - only when your phone shows $($c.Code)"
            $b.add_Click({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Invoke-ChatqPhoneSetupConfirm $U ([string]$src.Tag) } })
            [System.Windows.Controls.DockPanel]::SetDock($b, [System.Windows.Controls.Dock]::Right)
            [void]$row.Children.Add($b)
            $code = [System.Windows.Controls.TextBlock]::new()
            $code.Text = $c.Code
            $code.FontSize = 17
            $code.FontWeight = [System.Windows.FontWeights]::SemiBold
            $code.Foreground = Get-ChatqPhoneSetupBrush $U 'text'
            $code.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $code.Margin = [System.Windows.Thickness]::new(0, 0, 14, 0)
            # same-width digits, so the codes line up one under another
            [System.Windows.Documents.Typography]::SetNumeralAlignment($code, [System.Windows.FontNumeralAlignment]::Tabular)
            [System.Windows.Controls.DockPanel]::SetDock($code, [System.Windows.Controls.Dock]::Left)
            [void]$row.Children.Add($code)
            # the time keeps its place and a long label gives way to it
            $when = [System.Windows.Controls.TextBlock]::new()
            $when.Text = if ($c.At) { $c.At.ToString('HH:mm') } else { '' }
            $when.Foreground = Get-ChatqPhoneSetupBrush $U 'dim'
            $when.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $when.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
            [System.Windows.Controls.DockPanel]::SetDock($when, [System.Windows.Controls.Dock]::Right)
            [void]$row.Children.Add($when)
            $who = [System.Windows.Controls.TextBlock]::new()
            $who.Text = [string]$c.Label
            $who.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $who.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $who.ToolTip = "$($c.Label) answered$(if ($c.At) { ' at ' + $c.At.ToString('HH:mm:ss') }) - code $($c.Code)"
            [void]$row.Children.Add($who)
            [void]$U.CandList.Children.Add($row)
        }
    }
    foreach ($b in @(Get-ChatqPhoneSetupConfirmButtons $U)) { $b.IsEnabled = -not $U.Job }
    $U.CandPanel.Visibility = if ($Cands.Count) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

function Get-ChatqPhoneSetupConfirmButtons {
    param($U)
    if (-not $U.CandList) { return @() }
    return @($U.CandList.Children | ForEach-Object { $_.Children | Where-Object { $_ -is [System.Windows.Controls.Button] } })
}

function Show-ChatqPhoneSetupBar {
    param($U)
    $U.Bar.Visibility = [System.Windows.Visibility]::Visible
    [void]$U.BarSave.Focus()
}

function Hide-ChatqPhoneSetupBar {
    param($U)
    if ($U.Bar.Visibility -ne [System.Windows.Visibility]::Visible) { return }
    $U.Bar.Visibility = [System.Windows.Visibility]::Collapsed
}

function Request-ChatqPhoneSetupClose {
    # Close and Esc: straight away when all is saved, else the bar asks
    param($U)
    if (Test-ChatqPhoneSetupDirty $U) { Show-ChatqPhoneSetupBar $U; return }
    Close-ChatqPhoneSetup $U
}

function Close-ChatqPhoneSetup {
    # closed for good, whatever the form still says - a test push under way
    # stopped, a pairing alert or a confirmation left to finish behind it
    # (Stop-ChatqPhoneSetupJob)
    param($U)
    $U.Closing = $true
    Stop-ChatqPhoneSetupWork $U
    if ($U.Win.IsVisible -or $U.Win.IsLoaded) { $U.Win.Close() }
}

#endregion
