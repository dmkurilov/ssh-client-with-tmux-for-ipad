# SmokeTest credentials live **outside** this repo

Drop two files in `~/.ssh-client-tmux-smoke/` on your Mac. They stay
outside the synced project tree so nothing in the repo (or anyone
else's rebase, sync, or reset) can touch them.

```bash
mkdir -p ~/.ssh-client-tmux-smoke

cat > ~/.ssh-client-tmux-smoke/config.json <<'EOF'
{
  "host": "your-vps.example.com",
  "port": 22,
  "user": "root"
}
EOF

cp ~/.ssh/id_ed25519 ~/.ssh-client-tmux-smoke/private-key
```

The project's post-build script copies both files into the app
bundle at every build (see `project.yml → postBuildScripts`). If the
files are missing, the script skips them and the app shows a "not
configured" state — no other functionality is affected.

This whole flow is **for development against your own server only**.
Real key handling will live in the Keychain (Face ID-gated) once we
build the proper credential UI.
