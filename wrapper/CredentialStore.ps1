# Windows Credential Manager helper.
#
# Provides Read/Write/Remove for "Generic" credentials via Win32 P/Invoke.
# Zero PSGallery dependencies. Loaded as a dot-source from the wrapper and
# the installer. Entries land in:
#   Control Panel -> Credential Manager -> Windows Credentials -> Generic.
#
# Public functions:
#   Get-HaloAtlassianCredential   -> [pscustomobject]@{Email; Token} | $null
#   Set-HaloAtlassianCredential   -Email <string> -Token <string>
#   Remove-HaloAtlassianCredential
#
# Target name is intentionally fixed so the wrapper does not need any
# configuration to find the credential.

Set-Variable -Name HaloCredTarget -Value 'halo-atlassian:api-token' -Scope Script -Force -ErrorAction SilentlyContinue

if (-not ('HaloAtlassian.CredentialStoreNative' -as [type])) {
    Add-Type -Namespace HaloAtlassian -Name CredentialStoreNative -MemberDefinition @'
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public struct CREDENTIAL {
            public uint Flags;
            public uint Type;
            public System.IntPtr TargetName;
            public System.IntPtr Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public System.IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public System.IntPtr Attributes;
            public System.IntPtr TargetAlias;
            public System.IntPtr UserName;
        }

        [System.Runtime.InteropServices.DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        public static extern bool CredRead(string target, uint type, uint flags, out System.IntPtr credentialPtr);

        [System.Runtime.InteropServices.DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

        [System.Runtime.InteropServices.DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        public static extern bool CredDelete(string target, uint type, uint flags);

        [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
        public static extern void CredFree(System.IntPtr buffer);
'@
}

# Constants
$script:CRED_TYPE_GENERIC          = 1
$script:CRED_PERSIST_LOCAL_MACHINE = 2

function Get-HaloAtlassianCredential {
    [CmdletBinding()]
    param()

    [System.IntPtr]$credPtr = [System.IntPtr]::Zero
    if (-not [HaloAtlassian.CredentialStoreNative]::CredRead(
            $script:HaloCredTarget, $script:CRED_TYPE_GENERIC, 0, [ref]$credPtr)) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        # 1168 = ERROR_NOT_FOUND. Anything else is a real problem.
        if ($err -eq 1168) { return $null }
        throw "CredRead failed for target '$($script:HaloCredTarget)' (Win32 error $err)"
    }

    try {
        $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
            $credPtr, [type][HaloAtlassian.CredentialStoreNative+CREDENTIAL])

        $email = if ($cred.UserName -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cred.UserName)
        } else { '' }

        # CredentialBlob is raw bytes; we stored UTF-16 LE.
        $token = ''
        if ($cred.CredentialBlobSize -gt 0 -and $cred.CredentialBlob -ne [System.IntPtr]::Zero) {
            $bytes = New-Object byte[] $cred.CredentialBlobSize
            [System.Runtime.InteropServices.Marshal]::Copy(
                $cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
            $token = [System.Text.Encoding]::Unicode.GetString($bytes)
        }

        [pscustomobject]@{ Email = $email; Token = $token }
    }
    finally {
        [HaloAtlassian.CredentialStoreNative]::CredFree($credPtr)
    }
}

function Set-HaloAtlassianCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Token
    )

    $blobBytes = [System.Text.Encoding]::Unicode.GetBytes($Token)
    $blobPtr   = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($blobBytes.Length)
    [System.Runtime.InteropServices.Marshal]::Copy($blobBytes, 0, $blobPtr, $blobBytes.Length)

    $targetPtr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($script:HaloCredTarget)
    $userPtr   = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($Email)

    try {
        $cred = New-Object HaloAtlassian.CredentialStoreNative+CREDENTIAL
        $cred.Type               = $script:CRED_TYPE_GENERIC
        $cred.TargetName         = $targetPtr
        $cred.UserName           = $userPtr
        $cred.CredentialBlob     = $blobPtr
        $cred.CredentialBlobSize = [uint32]$blobBytes.Length
        $cred.Persist            = $script:CRED_PERSIST_LOCAL_MACHINE

        if (-not [HaloAtlassian.CredentialStoreNative]::CredWrite([ref]$cred, 0)) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CredWrite failed for target '$($script:HaloCredTarget)' (Win32 error $err)"
        }
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($targetPtr)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($userPtr)
    }
}

function Remove-HaloAtlassianCredential {
    [CmdletBinding()]
    param()

    if (-not [HaloAtlassian.CredentialStoreNative]::CredDelete(
            $script:HaloCredTarget, $script:CRED_TYPE_GENERIC, 0)) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($err -eq 1168) { return $false }  # not present
        throw "CredDelete failed for target '$($script:HaloCredTarget)' (Win32 error $err)"
    }
    return $true
}
