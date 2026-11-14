# whip_chat

Chat for [WHIP](https://github.com/WHIPFX/txAdmin-recipe), in WHIP's look. It stands in for FiveM's stock `chat`
resource: its events, exports, modes, templates and `^1` colour codes work the same, so resources written for stock
chat work with it.

## Features

- **Local chat.** A message reaches the players near the speaker, under their character's name. `/global` reaches
  everyone.
- **Typing in the HUD.** **T** turns WHIP's player capsule into the text field, with command suggestions as you type.
  You can still look around while you type.
- **Controller support.** With a controller, **Chat** on the F1 wheel opens WHIP's on-screen keyboard.
- **Your choice of visibility.** Messages fade away, stay on screen or stay hidden. Each player picks, and the choice
  is saved.
- **Spam limits.** A message is at most 256 characters, and the server limits how fast a player can send them.

## Requirements

- `whip_core`.
- No other chat resource. If another chat runs beside it, whip_chat says so in the server console, with the fix.

## Installation

WHIP's txAdmin recipe installs it, without FiveM's stock chat.

By hand, put `whip_chat` in your `resources` folder and add this line to `server.cfg`, after `ensure whip_core`:

```cfg
ensure whip_chat
```

Then remove `ensure chat`. If stock chat still starts, add `stop chat` after `ensure whip_chat`. With two chats
running, every message shows twice and typing can get stuck.

## For players

| Key or command | Does |
| --- | --- |
| **T** | Open chat. Start with `/` for a command; **Tab** and the arrow keys pick a suggestion. |
| **Page Up** / **Page Down** | Scroll the messages while typing |
| **F6** | Switch between messages that fade away, stay on screen, or stay hidden |
| `/global <message>` | Send a message to every player on the server |
| `/clearchat` | Clear your own chat. Nobody else's changes. |
| `/resetchat` | Get the keyboard back if chat seems stuck |

Players can rebind **T** and **F6** in GTA's **Settings > Key Bindings > FiveM**. The visibility choice is also in the
pause menu, under **Server Settings > Chat & voice**.

Admins can send a server notice to everyone with `/say <message>`, from the server console or in game with developer
mode on (`/w`).

## Configuration

whip_chat has no `config.lua`.

| Setting | Where | Does |
| --- | --- | --- |
| `Config.NetworkRange` | whip_core's `config.lua` | How far a message reaches, 424 m by default |
| `set chat_showJoins 0` | `server.cfg` | Hides the "joined" lines |
| `set chat_showQuits 0` | `server.cfg` | Hides the "left" lines |

## For developers

whip_chat answers stock chat's API:

| Side | Events and exports |
| --- | --- |
| Client events | `chat:addMessage`, `chat:addSuggestion`, `chat:addSuggestions`, `chat:removeSuggestion`, `chat:addTemplate`, `chat:addMode`, `chat:removeMode`, `chat:clear`, `chatMessage` |
| Client exports | `addMessage`, `addSuggestion`, `SetChatScale` (the chat's size relative to WHIP's other panels) |
| Server exports | `addMessage`, `registerMessageHook`, `registerMode`, `routeMessage` |
| Server event | `chatMessage`: cancel it to stop a message |

A resource that triggers these events needs no change. One that calls `exports.chat:...`, or has `dependency 'chat'`
in its `fxmanifest.lua`, needs `chat` changed to `whip_chat`.

## License

whip_chat is licensed under the GNU LGPL 3.0; see `LICENSE`. Third-party material is listed in `whip_core`'s
`NOTICE.md`, including the Barlow font (SIL Open Font License 1.1).
