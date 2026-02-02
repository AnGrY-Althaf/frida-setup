# Frida Setup

Automate Frida setup on **Windows** using a PowerShell script.

This repository provides a simple PowerShell script to automate the installation and configuration of **Frida** — a powerful dynamic instrumentation toolkit — on Windows systems.

> 🔧 Currently supports Windows platforms via a PowerShell script (`frida-setup.ps1`).

---

## 🚀 What Is Frida?

Frida is a dynamic instrumentation toolkit that lets you inject JavaScript into running processes, hook functions, inspect APIs, and bypass runtime checks without modifying binaries.

It is commonly used for:

- Reverse engineering
- Mobile and desktop application security testing
- Runtime API inspection
- SSL pinning bypass
- Penetration testing

---

## ✨ Features

- Automates Frida installation
- Downloads required binaries
- Configures the environment automatically
- Reduces manual setup effort
- Designed for Windows systems

---

## 🛠 Prerequisites

Before running the script, make sure you have:

- Windows PowerShell (5.1+) or PowerShell Core
- Internet connection
- Administrator privileges

---

## 📦 Usage

Clone the repository:

```sh
git clone https://github.com/AnGrY-Althaf/frida-setup.git
```

Navigate to the directory:

```powershell
cd frida-setup
```
Run the PowerShell setup script:

```powershell
.\frida-setup.ps1
```

The script will:

- Check for existing Frida installation
- Install or update Frida tools
- Configure required environment settings

---

## ⚠️ PowerShell Execution Policy

If script execution is blocked, run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

Then re-run the script.

---

## 📝 Notes

- This script is intended for **Windows only**
- If Frida is already installed, it may be updated or reconfigured
- Restart your terminal after installation if needed

---

## 🐞 Issues & Support

If you face any problems:

- Check Frida official documentation: https://frida.re/docs/installation/
- Open an issue in this repository

---

## 📜 License

This project is licensed under the **MIT License**.

---

Happy hacking! 🚀
