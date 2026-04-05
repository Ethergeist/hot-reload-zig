# hot-reload-zig

A minimal plugin hot-reloading example for zig 0.15.2.

## Features:
- Renames the plugin files before opening them to avoid file lock issues on windows
- `zig run watch.zig` Launches the app in development mode, and you can live update your plugins
- Minimal dependencies, easy to expand

