# 📝 Notepad (PowerShell Edition)

> "Because launching a massive IDE just to strip clipboard formatting is a minor life crisis you don't need."

Welcome to **Notepad**, a text editor built entirely inside **PowerShell 5.1** using **WPF (Windows Presentation Foundation)**. It looks and acts exactly like the classic app you already know, but it runs completely out of your console. 

No bloat, no tracking, just straight-up script-to-GUI magic.

<img width="1330" height="965" alt="image" src="https://github.com/user-attachments/assets/17a0fff0-4726-4454-95b0-48741d355385" />


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
