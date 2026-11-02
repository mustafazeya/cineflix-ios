# Automatic reinstall

A free Apple team signs apps for only **7 days**. After that the app stops opening until it is installed again.
`scripts/auto-install.sh` reinstalls CineFlix on every paired iPhone, and a macOS LaunchAgent runs it for you.

## Turn it on

```bash
scripts/install-launchagent.sh            # install and start
scripts/install-launchagent.sh --print    # preview the plist without changing anything
scripts/install-launchagent.sh --remove   # stop and delete it
```

The agent (`io.github.cineflix.auto-install`) runs when you log in and then every hour.

## How it behaves

- Each iPhone has its own timer. It is reinstalled only when its last successful install is **more than 20 hours** old,
  so it catches up whenever the Mac is awake and the phone is reachable (cable or the same Wi-Fi). Otherwise it waits for the next hour.
- Phones are found with `scripts/list-iphones.sh`. A newly paired phone is included automatically.
- It does not open the app. It shows a macOS notification on success or failure and writes to `logs/auto-install.log` (trimmed automatically).
- A lock prevents two runs at once, and an unreachable phone is skipped and retried an hour later.
- State is kept in `~/Library/Application Support/CineFlix/` (one timestamp file per phone).

## Handy commands

```bash
scripts/auto-install.sh --force                                       # reinstall on all reachable phones now
launchctl kickstart -k gui/$(id -u)/io.github.cineflix.auto-install  # run the job now
tail -f logs/auto-install.log
```

## Requirements and limits

- The Mac must be on and logged in, and the phone unlocked at least once after a restart.
- Moving the repository folder changes the path in the plist; run `scripts/install-launchagent.sh` again.
- Paid Apple Developer accounts do not need this because their builds last a year.
