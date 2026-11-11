# Android client / 双端互联

The Android side is a separate project:

- Repository: <https://github.com/Soodok/Deepseek-Harness-Local-Android>
- DSH-MOBILE Android patch PR: <https://github.com/Soodok/Deepseek-Harness-Local-Android/pull/105>
- Patch source: `xiaoming132887/Deepseek-Harness-Local-Android` branch
  `feat/peer-link-android`

The Android patch adds **Settings → 双端互联**:

- connect to the PC DSH (LAN `http://<PC-IP>:3091` or Cloudflare public URL);
- bidirectional / one-way session sync;
- show phone LAN WebUI address, password and remote-access pairing status.

The PC side in this repository exposes:

- `remote/lan-proxy.mjs` — WebUI proxy + `/__dshm/sync/*`;
- `remote/sync-sessions.mjs` — PC-side sync client;
- `remote/open-phone.ps1` — open the phone's DSH UI in a desktop window.
