Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.IO;

public class FullIconExtractor {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool FreeLibrary(IntPtr hModule);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindResource(IntPtr hModule, IntPtr lpName, IntPtr lpType);

    [DllImport("kernel32.dll")]
    static extern IntPtr LoadResource(IntPtr hModule, IntPtr hResInfo);

    [DllImport("kernel32.dll")]
    static extern IntPtr LockResource(IntPtr hResData);

    [DllImport("kernel32.dll")]
    static extern uint SizeofResource(IntPtr hModule, IntPtr hResInfo);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool EnumResourceNames(IntPtr hModule, IntPtr lpType, EnumResNameProc lpEnumFunc, IntPtr lParam);

    delegate bool EnumResNameProc(IntPtr hModule, IntPtr lpType, IntPtr lpName, IntPtr lParam);

    const uint LOAD_LIBRARY_AS_DATAFILE = 0x00000002;
    const uint LOAD_LIBRARY_AS_IMAGE_RESOURCE = 0x00000020;
    static readonly IntPtr RT_GROUP_ICON = (IntPtr)14;
    static readonly IntPtr RT_ICON = (IntPtr)3;

    public static byte[] ExtractIconResource(string exePath) {
        IntPtr hModule = LoadLibraryEx(exePath, IntPtr.Zero,
            LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
        if (hModule == IntPtr.Zero) return null;

        try {
            IntPtr groupIconName = IntPtr.Zero;
            EnumResourceNames(hModule, RT_GROUP_ICON, (h, t, name, param) => {
                groupIconName = name;
                return false;
            }, IntPtr.Zero);

            if (groupIconName == IntPtr.Zero) return null;

            IntPtr hResInfo = FindResource(hModule, groupIconName, RT_GROUP_ICON);
            if (hResInfo == IntPtr.Zero) return null;

            IntPtr hResData = LoadResource(hModule, hResInfo);
            if (hResData == IntPtr.Zero) return null;

            IntPtr pData = LockResource(hResData);
            uint size = SizeofResource(hModule, hResInfo);
            if (pData == IntPtr.Zero || size == 0) return null;

            byte[] grpHeader = new byte[size];
            Marshal.Copy(pData, grpHeader, 0, (int)size);

            int count = BitConverter.ToUInt16(grpHeader, 4);
            if (count == 0) return null;

            using (var ms = new MemoryStream()) {
                ms.Write(BitConverter.GetBytes((ushort)0), 0, 2);
                ms.Write(BitConverter.GetBytes((ushort)1), 0, 2);
                ms.Write(BitConverter.GetBytes((ushort)count), 0, 2);

                byte[][] iconData = new byte[count][];
                for (int i = 0; i < count; i++) {
                    int offset = 6 + i * 14;
                    ushort id = BitConverter.ToUInt16(grpHeader, offset + 12);

                    IntPtr hIcon = FindResource(hModule, (IntPtr)id, RT_ICON);
                    if (hIcon == IntPtr.Zero) return null;
                    IntPtr hIconData = LoadResource(hModule, hIcon);
                    IntPtr pIconData = LockResource(hIconData);
                    uint iconSize = SizeofResource(hModule, hIcon);

                    iconData[i] = new byte[iconSize];
                    Marshal.Copy(pIconData, iconData[i], 0, (int)iconSize);
                }

                uint dataOffset = (uint)(6 + count * 16);
                for (int i = 0; i < count; i++) {
                    int grpOffset = 6 + i * 14;
                    ms.Write(grpHeader, grpOffset, 8);
                    ms.Write(BitConverter.GetBytes((uint)iconData[i].Length), 0, 4);
                    ms.Write(BitConverter.GetBytes(dataOffset), 0, 4);
                    dataOffset += (uint)iconData[i].Length;
                }

                for (int i = 0; i < count; i++) {
                    ms.Write(iconData[i], 0, iconData[i].Length);
                }

                return ms.ToArray();
            }
        } finally {
            FreeLibrary(hModule);
        }
    }
}
"@ -ErrorAction Stop

$notepadPath = Join-Path $env:SystemRoot "System32\notepad.exe"
$icoBytes = [FullIconExtractor]::ExtractIconResource($notepadPath)

if ($null -ne $icoBytes -and $icoBytes.Length -gt 0) {
    $outPath = Join-Path $env:USERPROFILE "Desktop\notepad.ico"
    [System.IO.File]::WriteAllBytes($outPath, $icoBytes)

    $iconCount = [System.BitConverter]::ToUInt16($icoBytes, 4)
    Write-Host "Saved full-color icon to: $outPath" -ForegroundColor Green
    Write-Host "File size: $($icoBytes.Length) bytes" -ForegroundColor Green
    Write-Host "Icon frames: $iconCount" -ForegroundColor Green

    for ($i = 0; $i -lt $iconCount; $i++) {
        $off = 6 + $i * 16
        $w = [int]$icoBytes[$off]; if ($w -eq 0) { $w = 256 }
        $h = [int]$icoBytes[$off + 1]; if ($h -eq 0) { $h = 256 }
        $bpp = [System.BitConverter]::ToUInt16($icoBytes, $off + 6)
        $sz = [System.BitConverter]::ToUInt32($icoBytes, $off + 8)
        Write-Host "  Frame $($i+1): ${w}x${h} ${bpp}bpp ($sz bytes)" -ForegroundColor Cyan
    }
} else {
    Write-Host "FAILED to extract icon" -ForegroundColor Red
}
