# PasChat

A small HexChat-style IRC client written in Free Pascal with the Lazarus LCL.

![status](https://img.shields.io/badge/status-early%20prototype-orange)
![language](https://img.shields.io/badge/Free%20Pascal-3.2%2B-blue)

## Features

- Server / channel / query tree on the left, chat view in the centre, nick list on the right
- TLS and plain-text connections
- Channel and private-message windows with unread markers
- Nick list sorted by rank (`~ & @ % +`), updated on join/part/quit/nick/kick/mode
- Topic bar (press Enter in it to change the topic)
- Input history (Up/Down) and nick completion (Tab)
- CTCP `ACTION` (`/me`) and `VERSION` replies
- mIRC colour/formatting codes are stripped from incoming text
- No third-party packages: just FPC's `ssockets` + OpenSSL

## Requirements

| Requirement | Notes |
|---|---|
| Free Pascal **3.2.0 or newer** | needed for `sslsockets` / `opensslsockets` |
| Lazarus (LCL) | any recent 2.x release |
| OpenSSL runtime libraries | `libssl` and `libcrypto` |

OpenSSL on each platform:

- **Linux:** usually already installed. Check with `ldconfig -p | grep libssl`.
  If missing: `sudo apt install libssl3` (Debian/Ubuntu) or your distro's equivalent.
- **Windows:** place `libssl-*.dll` and `libcrypto-*.dll` (matching your exe's bitness) next to `paschat.exe`.
- **macOS:** install OpenSSL, e.g. `brew install openssl`.

## Building

### From the Lazarus IDE

1. Open `paschat.lpi`.
2. Press **F9** (Run) or **Shift+F9** (Build).

### From the command line

```bash
lazbuild paschat.lpi
./paschat
```

## Project layout

```text
paschat/
├── paschat.lpi     Lazarus project file
├── paschat.lpr     program entry point
├── mainunit.pas    main window: UI (built in code) and IRC event handling
├── mainunit.lfm    minimal form resource
└── irccore.pas     socket thread, IRC line parser, helpers
```

## Usage

### Connecting

**Menu:** `IRC → Connect...`, then enter a server and a nickname.

**Command:**

```text
/server irc.libera.chat 6697
```

All of these forms are accepted:

```text
/server irc.libera.chat
/server irc.libera.chat 6697
/server irc.libera.chat:6697
/server irc.libera.chat/6697
/server +irc.libera.chat
```

> **TLS rule:** port `6667` is plain text. Any other port uses TLS. The default port is `6697`.

Only one connection can be open at a time. To switch servers, run `/quit`, wait for
`* Disconnected.` in the server window, then connect again.

### Logging in to an account (SASL)

Some networks (Libera.Chat blocks many VPN addresses, for example) require you to
authenticate **while connecting**; `/msg NickServ IDENTIFY` is too late for that.

1. Choose `IRC → Account (SASL)...` (or right-click the server in the tree).
2. Enter your account name, then your password.
3. Connect. The server window will show `* Will authenticate as <account> (SASL).`
   and, on success, a "You are now logged in as ..." line.

The details are saved to `paschat.ini` in your user config directory
(`~/.config/paschat/` on Linux). **The password is stored in plain text**, so only
use this on a machine you trust. Leave the account name blank to turn SASL off.

### Joining a channel

```text
/join #freepascal
```

Double-click a nick in the user list to open a private conversation.

### Commands

| Command | Description |
|---|---|
| `/server host [port]` | Connect to a server |
| `/join #chan [key]` (`/j`) | Join a channel |
| `/part [#chan]` (`/leave`) | Leave a channel (defaults to the current one) |
| `/close` | Close the current window (parts first if it is a channel) |
| `/msg <target> <text>` | Send a message to a nick or channel |
| `/query <nick>` | Open a private conversation window |
| `/me <action>` | Send an action (`* you waves`) |
| `/nick <newnick>` | Change nickname |
| `/topic [text]` | Show or set the channel topic |
| `/quit [message]` (`/disconnect`) | Disconnect from the server |
| `/raw <line>` (`/quote`) | Send a raw IRC line |
| `/clear` | Clear the current window |

Any other `/command` is sent to the server unchanged, so things like `/whois nick`,
`/list` or `/away reason` work (their replies appear in the server window).

To send a message that starts with a slash, type `//` (e.g. `//shrug` sends `/shrug`).

### Keyboard

| Key | Action |
|---|---|
| `Enter` | Send the line |
| `Up` / `Down` | Browse input history |
| `Tab` | Complete a nick from the current channel's user list |

## Known limitations

- **TLS certificates are not verified.** The connection is encrypted but the server is
  not authenticated (`VerifyPeerCert := False` in `irccore.pas`). Load a CA bundle and
  enable verification before relying on this for anything sensitive.
- One network at a time.
- No autojoin, DCC, or `/list` window yet. Server, nick and account are saved, but only one set.
- The chat view is a plain `TMemo`: no per-nick colours or clickable links.

## Troubleshooting

| Symptom | Things to try |
|---|---|
| `Error:` line right after "Connecting..." | Check the hostname and port. Test with `/server irc.libera.chat 6667` to rule out TLS. |
| TLS connection fails immediately | Confirm the OpenSSL libraries are installed (see Requirements). |
| `Connection closed (read returned N after X ms)` | The server or TLS layer closed the connection; include this line in a bug report. |
| "Already connected (or still closing)" | Run `/quit`, wait for `* Disconnected.`, then reconnect. |
| Build error about `sslsockets` or `opensslsockets` | Your FPC is older than 3.2.0. |

## Roadmap

- [x] Saved server, nick and account
- [ ] Autojoin channels
- [ ] Multiple networks
- [x] SASL authentication (PLAIN)
- [ ] Certificate verification
- [ ] Coloured nicks and clickable links (`TRichMemo` or custom drawing)
- [ ] Channel list dialog

## Licence

Choose a licence for your repository (e.g. MIT or GPL-2.0) and add a `LICENSE` file.
