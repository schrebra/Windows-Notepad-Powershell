# 📝 Notepad (PowerShell Edition)

> "Because opening a massive IDE just to strip clipboard formatting is an existential crisis you don't deserve."

Welcome to **Notepad**—the ultimate production-grade, premium text-editing experience built entirely within **PowerShell 5.1** using **WPF (Windows Presentation Foundation)**. It looks like the classic tool you've known for decades, acts with the snappy speed you expect, but runs completely fueled by your shell console environment. 

No bloat. No tracking. Just pure, unadulterated script-to-GUI wizardry.

---

## 🤔 What Is It?

**Notepad** is a fully functional, event-driven desktop text editor packed cleanly into a single PowerShell script. By bridging the gap between script logic and native Windows presentation assemblies (`PresentationFramework`, `PresentationCore`, `WindowsBase`), this project delivers a lightweight, zero-install graphical user interface straight out of your terminal framework.

---

## 🔥 Why Does It Exist?

* **Pushing the Boundaries:** To prove that PowerShell isn't just for automation scripts and registry tweaks—it’s fully capable of spinning up robust, multi-window desktop applications.
* **Electron Antidote:** In a world where a basic text editor takes up 500MB of RAM and demands its own chromium runtime environment, this script relies strictly on the native .NET framework already baked into your OS.
* **The Ultimate SysAdmin Utility:** Ever found yourself remoted into a secure, air-gapped server environment needing a quick tool to view logs, adjust configurations, or write quick scripts without leaving a footprint or installing unauthorized executables? This is your solution.

---

## 👥 Who Is This For?

* **PowerShell Purists:** Developers who smile at `Add-Type -AssemblyName` and love seeing scripts handle tasks people said they shouldn't.
* **System Administrators & Security Researchers:** Professionals operating in hardened enterprise landscapes who need predictable, native, script-auditable tools.
* **Minimalists:** Anyone tired of software bloat who wants a text editor that launches faster than they can blink.

---

## ✨ Features Breakdown

### 🎨 The Interface & Typography
* **Fluid WPF Rendering:** Zero lag, hardware-accelerated rendering using native system presentation layers.
* **Global Font Engine:** Instantly swap typefaces using a native Windows Font Dialog. Font scales dynamically from a tiny `8pt` up to a booming `72pt`.
* **Micro-Adjustable Layouts:** Custom margin inputs (`0px` to `200px`) and adjustable line-height spacing (`1.0x` to `3.0x`) to create the perfect reading environment for your eyes.

### 🔍 Search & Data Manipulation
* **Strategic Find Capabilities:** Full-featured asynchronous-feeling lookup dialog complete with wrap-around logic so you never miss a match.
* **Precision Replace Engine:** Swap target strings individually or hit **Replace All** to instantly update massive files using dynamic regular expression mapping.
* **Case Sensitivity Toggle:** Easily isolate specific variables or phrases with a dedicated "Match Case" checkbox framework.

### 🧠 State Retention & Storage
* **Persistent User Profiles:** Automatically tracks your environment preferences. Your custom window layout sizing, text-wrapping variables, status bar visibility, margins, and typography metrics are written directly to a clean `%APPDATA%\PSNotepad\settings.ini` file on exit.
* **Safety Net Architecture:** Built-in validation loops. If you have unsaved text changes, the script halts closing or file clearing to safely prompt you with a "Do you want to save changes?" dialogue.

### 📊 Real-Time Metrics & Telemetry
The integrated, toggleable Status Bar updates instantly as you type, keeping vital document analytics right at your fingertips:
* **Caret Coords:** Live spatial tracking showing your exact cursor location (`Ln X, Col Y`).
* **Word Counter:** Regex-parsed word density tracking.
* **Character Gauge:** Total string lengths tracked continuously.
* **Line Tally:** Total structure metrics mapping out exactly how long your script or document is running.

### ⌨️ Standard Power-User Keybindings
No need to relearn muscle memory—all native shortcut parameters are fully wired and functional:
* `Ctrl + N` — Clear environment and initialize a new document
* `Ctrl + O` — Open system dialogue to read external text files
* `Ctrl + S` — Commit rapid changes to disk
* `Ctrl + Shift + S` — Route current workspace to a fresh file target
* `Ctrl + F` — Call the text search window
* `F3` — Cycle quickly through your next search hit
* `Ctrl + H` — Fire up the string replacement console
* `F5` — Instantly stamp a localized, high-fidelity Date/Time string at your cursor spot

---

## 🚀 Execution

To spin up your new favorite lightweight editor, simply call the script path directly from your administrative or local PowerShell terminal window:

```powershell
# Requires -Version 5.1
.\notepad.ps1
