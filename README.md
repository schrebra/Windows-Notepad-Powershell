# 📝 Notepad (PowerShell Edition)

Welcome to **Notepad**, a text editor built entirely inside **PowerShell 5.1** using **WPF (Windows Presentation Foundation)**. It looks and acts exactly like the classic app you already know, but it runs completely out of your console. 

No bloat, no tracking, just straight-up script-to-GUI magic.

<img width="60%" alt="image" src="https://github.com/user-attachments/assets/8ac551a9-9585-41ad-8313-c3f6c29cd3d8" />

---

## 🤔 What Is It?

**Notepad** is a fully functional desktop text editor packed cleanly into a single PowerShell script. It bridges the gap between script logic and native Windows design tools like `PresentationFramework`. This means you get a snappy, lightweight desktop app without actually installing anything on your system.

---

## 🔥 Why Does It Exist?

* **Testing the Limits:** To prove that PowerShell isn't just for automating background tasks or changing registry keys. It can build real, responsive desktop apps.
* **The Anti-Electron Movement:** Modern text editors often eat up hundreds of megabytes of RAM just to run an entire web browser background environment. This script uses the lightweight .NET framework already built into your operating system.
* **The Perfect SysAdmin Tool:** If you are remoted into a locked-down server and need to quickly check logs or edit a config file, you don't want to install untrusted executables. This script gives you a full GUI using only the native tools already on the machine.

---

## 👥 Who Is This For?

* **PowerShell Fans:** Developers who love looking under the hood and seeing scripts handle things people said they shouldn't.
* **SysAdmins and Techs:** Professionals who need clean, predictable tools that they can read and audit themselves.
* **Minimalists:** Anyone who wants an editor that opens faster than they can blink and takes up almost zero space.

---

## ✨ Features

### 🎨 Clean Layout and Typography
* **Smooth Performance:** Zero lag interface running on your computer's native graphics layers.
* **System Font Selector:** Pick any font installed on your machine. You can scale the text fluidly from a tiny 8pt up to a massive 72pt.
* **Custom Spacing:** Adjust your side margins and line spacing (from 1.0x to 3.0x) so your eyes don't get tired during long reading sessions.

### 🔍 Smart Search and Replace
* **Quick Finder:** A built-in search box that wraps around the document automatically so you never miss a word.
* **Bulk Replace:** Swap out words one by one or use "Replace All" to update everything at once.
* **Match Case:** A simple toggle to lock your searches down to exact capital or lowercase matches.

### 🧠 Smart Saving
* **Remembers Your Setup:** It automatically tracks your favorite layout. The next time you open the app, your window size, word wrap preference, margins, and font choices will load exactly how you left them. They are saved in a simple file at `%APPDATA%\PSNotepad\settings.ini`.
* **Safety Prompt:** If you try to close the window or start a new file with unsaved changes, the app will stop and ask if you want to save your work first.

### 📊 Real-Time Stats
The status bar at the bottom keeps track of your document metrics as you type:
* **Cursor Position:** Shows your exact line and column number.
* **Live Counters:** Displays a real-time count of your words, characters, and total lines.

### ⌨️ Standard Keyboard Shortcuts
Your muscle memory works perfectly here. All the classic shortcuts are fully wired up:
* `Ctrl + N` : Clear everything and start a fresh document
* `Ctrl + O` : Open an existing text file
* `Ctrl + S` : Quick save your current file
* `Ctrl + Shift + S` : Save your work as a brand new file
* `Ctrl + F` : Bring up the search window
* `F3` : Jump to the next search result
* `Ctrl + H` : Open the replace window
* `F5` : Instantly drop the current time and date right where your cursor is

---

## 🚀 How to Run It

Just open your PowerShell terminal and call the script:

```powershell
# Requires -Version 5.1
.\notepad.ps1
```
---

# Installation and Compilation Guide

This guide will walk you through setting up the necessary tools and converting the PowerShell script into a standalone Windows executable (`.exe`) using the files provided in this repository.

### 1. Install the PS2EXE Tool
First, you need to install the module that handles the conversion. We use the `-Verbose` flag so you can see the installation progress details.

1. Open **PowerShell** as an Administrator.
2. Run the following command:

```powershell
Install-Module -Name ps2exe -Scope CurrentUser -Force -Verbose
```
*Note: If prompted to install 'NuGet provider' or 'Untrusted repository', type **Y** and press **Enter**.*

---

### 2. Extract the Notepad Icon
To make the application look authentic, you need to generate the icon file from the system.

1. Locate the file `Extract.Notepad.Icon.To.Desktop.ps1` in your downloaded folder.
2. Right-click the file and select **Run with PowerShell**.
3. A file named `notepad.ico` will be created on your Desktop. 
4. **Move** that `notepad.ico` file into the same folder where `Notepad.ps1` is located.

---

### 3. Compile PS1 to EXE
Now you will use the files `Notepad.ps1` and `notepad.ico` to create your final application.

1. In your PowerShell window, navigate to the folder containing your files.
2. Run the following command:

```powershell
ps2exe -InputFile ".\Notepad.ps1" -OutputFile ".\Notepad.exe" -IconFile ".\notepad.ico" -NoConsole -Title "Notepad" -Description "Text Editor" -Version "5.0.1"
```

### Breakdown of the Command:
*   **-InputFile**: The source code (`Notepad.ps1`).
*   **-OutputFile**: The name of the program to be created (`Notepad.exe`).
*   **-IconFile**: Attaches the icon you extracted so the app looks like the real Notepad.
*   **-NoConsole**: This prevents a black terminal window from appearing behind the editor.
*   **-Version "5.0.1"**: Sets the file version to match the latest update.

You will now have a functional **Notepad.exe** ready to use!


