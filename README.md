# Bash Terminal File Manager

A lightweight, feature-rich, standalone terminal file manager written purely in **Bash**. It provides an intuitive interactive TUI (Text User Interface) for managing files, navigating directories, searching, previewing, and performing batch operations directly from your command line.

## Features

- **Zero Heavy Dependencies**: Single-file script built with pure Bash and standard POSIX/Linux core utilities.
- **Interactive Navigation**: Smooth arrow-key / vi-key navigation with responsive scrolling and dynamic directory tree browsing.
- **Instant File Preview**: View text files, scripts, logs, and inspect binary/media metadata without leaving the terminal.
- **Multi-Item Selection**: Select multiple files/folders to batch delete, batch copy, or batch move.
- **Clipboard Support**: Copy (`c`), Cut (`x`), and Paste (`v`) items across directories with overwrite protection.
- **Batch & Regex Renaming**: Rename individual files or perform multi-file batch rename operations with pattern search/replace.
- **Fast Search**: Find files by name, extension, or search inside file contents.
- **Folder Analytics & Statistics**: Instant visual summary of directory size, hidden items, and top file types.
- **Rich File Type Icons**: Categorized emoji icons for code, images, audio, video, documents, archives, and configs.

---



## ⌨️ Keybindings & Shortcuts


| Key                             | Action                                                 |
| ------------------------------- | ------------------------------------------------------ |
| `↑` **/** `k`                   | Move cursor up                                         |
| `↓` **/** `j`                   | Move cursor down                                       |
| `Enter` **/** `→` **/** `l`     | Open folder / View file                                |
| `Backspace` **/** `←` **/** `h` | Go to parent directory                                 |
| `Space`                         | Toggle selection on current item                       |
| `a`                             | Select all / Deselect all items                        |
| `n`                             | Create new file or folder                              |
| `r`                             | Rename current file/folder                             |
| `R`                             | Batch rename selected files                            |
| `c`                             | Copy current/selected items to clipboard               |
| `x`                             | Cut (move) current/selected items                      |
| `v`                             | Paste clipboard items into current folder              |
| `d`                             | Delete current item or all selected items              |
| `/`                             | Search files by name                                   |
| `t`                             | Find files by extension (e.g., `txt`, `py`, `sh`)      |
| `k`                             | Count keyword occurrences across files                 |
| `s`                             | Show detailed folder statistics                        |
| `p`                             | Show path info & copy current path to system clipboard |
| `q`                             | Quit file manager                                      |


---



## Requirements

- **Bash 4.0+** (Default on modern Linux distributions, WSL, and macOS with updated Bash).
- `ncurses` **(**`tput`**)** — standard on most systems.

---



## How to Run



### 1. Make the script executable

```bash
chmod +x file_manager.sh
```



### 2. Launch

```bash
./file_manager.sh
```

*(Or launch directly with* `bash ./file_manager.sh`*)*

---

