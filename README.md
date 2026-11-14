# whip_chat

whip's chat, in place of FiveM's stock `chat` resource. Players press T to type; the text field is whip's player
capsule, and messages appear in whip's look. F6 shows or hides the messages.

- **Needs:** whip_core.
- **Install:** WHIP's txAdmin recipe installs it and adds `ensure whip_chat` to server.cfg. Nothing else to add, no SQL.
- **Take out stock chat:** remove `ensure chat` from server.cfg. If chat still starts, put `stop chat` after
  `ensure whip_chat`. Both running gives two chat boxes on one key: every message shows twice, and typing can get
  stuck. whip_chat says so in the server console (and in F8) when it finds another chat, stock `chat` or one whose
  fxmanifest.lua says `provide 'chat'`.
- **Other resources keep working:** whip_chat answers the stock chat's events (`chat:addMessage`,
  `chat:addSuggestion`, `chatMessage` ...), so a resource that sends chat messages by event needs no change. One that
  calls `exports.chat:...` (whip_chat has the same `addMessage` and `registerMessageHook`), or whose manifest says
  `dependency 'chat'`, needs `chat` changed to `whip_chat` there.
- **Commands:** `/clearchat` (empties your own chat; nobody else's changes), `/say` (a server notice: the console, or an admin in developer mode), `/resetchat` (a player whose
  keyboard seems stuck to the chat gets it back).
