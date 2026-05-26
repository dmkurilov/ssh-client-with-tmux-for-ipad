# SSHConfigTests

For tests that need file I/O, use `TempHome` — it creates a UUID-named
temp directory on init, exposes `write(_:to:)` and a `DiskFileLoader`
rooted there, and cleans up in `deinit`. See `TempHome.swift`.
