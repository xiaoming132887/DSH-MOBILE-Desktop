# Security

DSH-MOBILE runs a full DSH agent (file + terminal access). Treat every remote
connection as remote code execution on the host.

- LAN mode: 6-digit code; only use on a trusted network.
- Public mode: Cloudflare quick tunnel URL + 32-character password; the URL is
  publicly reachable. Use it only temporarily and close it immediately after.
- Never port-forward `3091` directly.
- Do not commit `data/`, `runtime/`, `.credentials.yaml`, logs or session files.
- Report security issues privately to the maintainers, not in a public issue.
