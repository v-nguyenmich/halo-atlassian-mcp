# WinForms dialog that collects every field the installer needs in one shot.
# Returns a hashtable @{ Email; Token; JiraUrl; ConfluenceUrl } on OK, or
# $null if the user cancels.
#
# Loaded by Install-HaloAtlassianMcp.ps1 in interactive mode. -NonInteractive
# skips this entirely and uses the -Email / -Token / -JiraUrl /
# -ConfluenceUrl params.

function Show-HaloSetupForm {
    [CmdletBinding()]
    param(
        [string]$Email,
        [string]$JiraUrl,
        [string]$ConfluenceUrl
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'halo-mcp-atlassian setup'
    $form.Size            = New-Object System.Drawing.Size(560, 360)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.Topmost         = $true

    $header = New-Object System.Windows.Forms.Label
    $header.Text     = 'Enter your Atlassian tenant details. All fields required.'
    $header.Location = New-Object System.Drawing.Point(20, 15)
    $header.Size     = New-Object System.Drawing.Size(520, 20)
    $form.Controls.Add($header)

    $tokenLink = New-Object System.Windows.Forms.LinkLabel
    $tokenLink.Text     = 'Create an API token at id.atlassian.com'
    $tokenLink.Location = New-Object System.Drawing.Point(20, 35)
    $tokenLink.Size     = New-Object System.Drawing.Size(400, 18)
    $tokenLink.LinkArea = New-Object System.Windows.Forms.LinkArea(28, 16)
    $tokenLink.Add_LinkClicked({ Start-Process 'https://id.atlassian.com/manage-profile/security/api-tokens' })
    $form.Controls.Add($tokenLink)

    function New-Field {
        param([string]$Label, [int]$Y, [string]$Default = '', [bool]$Mask = $false)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text     = $Label
        $lbl.Location = New-Object System.Drawing.Point(20, $Y)
        $lbl.Size     = New-Object System.Drawing.Size(130, 22)
        $form.Controls.Add($lbl)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(155, ($Y - 3))
        $tb.Size     = New-Object System.Drawing.Size(370, 22)
        $tb.Text     = $Default
        if ($Mask) { $tb.UseSystemPasswordChar = $true }
        $form.Controls.Add($tb)
        return $tb
    }

    $defaultEmail = if ($Email)   { $Email } else { "$env:USERNAME@halostudios.com" }
    $defaultJira  = if ($JiraUrl) { $JiraUrl } else { 'https://343industries.atlassian.net' }
    $defaultConf  = if ($ConfluenceUrl) { $ConfluenceUrl } else { "$defaultJira/wiki" }

    $tbEmail = New-Field 'Atlassian email'   65  $defaultEmail $false
    $tbJira  = New-Field 'Jira base URL'     100 $defaultJira  $false
    $tbConf  = New-Field 'Confluence base URL' 135 $defaultConf $false
    $tbToken = New-Field 'API token'         170 ''            $true

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text      = 'Paste your token above (input is masked). Stored in Windows Credential Manager.'
    $hint.Location  = New-Object System.Drawing.Point(20, 200)
    $hint.Size      = New-Object System.Drawing.Size(520, 18)
    $hint.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($hint)

    $tbJira.Add_TextChanged({
        $newDefault = "$($tbJira.Text.TrimEnd('/'))/wiki"
        if ($tbConf.Text -match '^https?://[^/]+/?wiki/?$' -or [string]::IsNullOrWhiteSpace($tbConf.Text)) {
            $tbConf.Text = $newDefault
        }
    })

    $errLabel = New-Object System.Windows.Forms.Label
    $errLabel.Location  = New-Object System.Drawing.Point(20, 225)
    $errLabel.Size      = New-Object System.Drawing.Size(520, 38)
    $errLabel.ForeColor = [System.Drawing.Color]::Firebrick
    $form.Controls.Add($errLabel)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text     = 'Install'
    $okBtn.Location = New-Object System.Drawing.Point(355, 280)
    $okBtn.Size     = New-Object System.Drawing.Size(80, 28)
    $form.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text         = 'Cancel'
    $cancelBtn.Location     = New-Object System.Drawing.Point(445, 280)
    $cancelBtn.Size         = New-Object System.Drawing.Size(80, 28)
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelBtn)
    $form.CancelButton = $cancelBtn

    $script:_haloResult = $null

    $okBtn.Add_Click({
        $errs = @()
        if ([string]::IsNullOrWhiteSpace($tbEmail.Text)) { $errs += 'Email required.' }
        elseif ($tbEmail.Text -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $errs += 'Email looks invalid.' }
        foreach ($pair in @(@{Tb=$tbJira;Lbl='Jira'}, @{Tb=$tbConf;Lbl='Confluence'})) {
            $u = $pair.Tb.Text.TrimEnd('/')
            if ([string]::IsNullOrWhiteSpace($u))             { $errs += "$($pair.Lbl) URL required."; continue }
            if ($u -notmatch '^https://')                     { $errs += "$($pair.Lbl) URL must start with https://"; continue }
            if ($u -notmatch '\.atlassian\.net(/.*)?$')       { $errs += "$($pair.Lbl) URL must end in .atlassian.net" }
        }
        if ([string]::IsNullOrWhiteSpace($tbToken.Text)) { $errs += 'API token required.' }
        elseif ($tbToken.Text.Length -lt 10)             { $errs += 'API token looks too short.' }

        if ($errs.Count) {
            $errLabel.Text = ($errs -join '  ')
            return
        }
        $script:_haloResult = @{
            Email         = $tbEmail.Text.Trim()
            Token         = $tbToken.Text
            JiraUrl       = $tbJira.Text.TrimEnd('/')
            ConfluenceUrl = $tbConf.Text.TrimEnd('/')
        }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $form.AcceptButton = $okBtn

    [void]$form.ShowDialog()
    $form.Dispose()
    return $script:_haloResult
}
