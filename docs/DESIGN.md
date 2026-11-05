# How QuietHosts works

This page is for the curious and for contributors. To install the app, see the [README](../README.md).

## Architecture

```
QuietHosts.app (menu bar, runs as you)            QuietHostsHelper (LaunchDaemon, root)
├─ Domain index + search (memmem over bytes)      ├─ accepts only the Release-signed app (XPC
├─ Rules (allow / block)                          │  code-signing requirement, same Team ID,
├─ HostsPlanner → sorted hostname list ──XPC──▶   │  no get-task-allow)
├─ Verifies /etc/hosts by checksum                ├─ validates every hostname, renders the lines
└─ ~/Library/Application Support/QuietHosts       ├─ backs up, writes atomically, verifies
                                                  └─ flushes DNS (fixed commands), exits when idle
```

| Folder | What's in it |
|---|---|
| `Packages/QuietHostsCore` | All logic, shared by the app and the helper and unit-tested: hostname validation, the list parser, `DomainIndex`, search, the rule engine, the hosts-section renderer and the safe file writer |
| `QuietHosts/` | The SwiftUI menu-bar app (an `NSStatusItem` with an `NSPopover`), the Manage window and the XPC client |
| `QuietHostsHelper/` | The privileged helper, registered with `SMAppService.daemon` and started on demand by launchd |
| `install.sh` | Detects your signing identity, builds, verifies the signatures, then installs or uninstalls |

### Data model

- **Imported lists** are immutable source data. Each is stored as a sorted, de-duplicated file with one domain per line.
- **`DomainIndex`** merges every list into one contiguous byte buffer, with a 64-bit mask per domain recording which lists contain it.
  Turning a list on or off changes the enabled mask only and never rebuilds the index.
- **Rules** (`rules.json`) hold your exceptions and blocked sites. They are separate from list data, so refreshing a list can't change them.
- **Precedence:**
  1. Your exceptions beat everything.
  2. Your blocked sites come next.
  3. Enabled lists come last.
  4. Anything else is unrestricted.

  The latest action always wins.
- **Search** runs `memmem` over the index buffer. Results are ranked exact → prefix → label prefix (`m.site…`) → substring, shortest first, and capped at 300 rendered rows.

### Files

| Path | Contents |
|---|---|
| `~/Library/Application Support/QuietHosts/settings.json` | Protection state, sources, preferences |
| `~/Library/Application Support/QuietHosts/rules.json` | Exceptions and blocked sites |
| `~/Library/Application Support/QuietHosts/lists/*.txt` | Last known-good copy of each list |
| `/Library/Application Support/QuietHosts/Backups/` | Hosts-file backups (root-owned, readable) |

## Hosts-file safety

- QuietHosts only touches a block between `# >>> QuietHosts BEGIN …` and `# <<< QuietHosts END`. Everything else is preserved byte for byte, including non-UTF-8 content.
- The begin marker carries a SHA-256 of the block. If someone edits inside the block, QuietHosts refuses to write and asks before replacing it.
- It refuses to write if there are duplicate or unbalanced markers, the file is a symlink or not a regular file, the file is oversized, or `/etc/hosts` or `/private/etc` isn't owned by root.
- A new file is written beside the original, then `fsync`ed, given the same owner and mode, and `rename(2)`d into place. The write aborts if the file changed in the meantime, and the result is re-read to verify it.
- Backups:
  - `hosts.original` is the file before QuietHosts first touched it, and is never overwritten.
  - A timestamped copy is kept of every distinct version of the content QuietHosts doesn't manage (last 10).
- The helper's entire interface is: apply a sorted list of hostnames, remove the block, report its version.
  There are no paths, commands or raw file content. Every name is re-validated, and the helper writes `0.0.0.0 name` and `:: name` itself.
  Even a compromised caller could therefore only *block* names, never redirect them.
- Each blocked name gets both `0.0.0.0` and `::`. mDNSResponder only answers from hosts entries of the same address family, so IPv4-only entries let sites load over IPv6.
- "Active" is shown only after the helper reports success *and* the app has re-read `/etc/hosts` and matched its checksum against the current rules.

### Privileged helper and signing

The helper is a LaunchDaemon registered with `SMAppService`. Its XPC listener uses `setConnectionCodeSigningRequirement`:

```
anchor apple generic and identifier "com.quiethosts.QuietHosts"
  and certificate leaf[subject.OU] = "<your team>"
  and !(entitlement["com.apple.security.get-task-allow"] exists)
```

The team is read from the helper's own signature at runtime, so every person who builds QuietHosts gets a helper that trusts only their own build. Debug builds, which other processes can attach to, are rejected.

## Performance

Measured on an Apple Silicon MacBook running macOS 26.6 (Release build).
The synthetic datasets are realistic random hostnames, merged across three overlapping sources.

| | 100k domains | 200k domains | StevenBlack adult list (76,801) |
|---|---|---|---|
| Parse list | 38 ms | 58 ms | 16 ms |
| Merge + de-duplicate 3 sources | 4 ms | 7 ms | – |
| Reload from cache at launch | 11 ms | 24 ms | 8 ms |
| Search, typical query (median) | 1.3 ms | 2.7 ms | 1.0 ms |
| Search, worst case `a` (60k+ matches) | 2.9 ms | 5.9 ms | 2.0 ms |
| Search-as-you-type, p95 per keystroke | 2.5 ms | 5.2 ms | 1.6 ms |
| Rule change + re-plan | 1.2 ms | 2.2 ms | 0.8 ms |
| Render + write + verify the hosts file | 22 ms | 46 ms | 14 ms |
| Index memory | 3.2 MB | 6.4 MB | 2.2 MB |

**End to end on a real system** (`--self-test`, real helper and `/etc/hosts`, 76,801 domains, 153,602 lines):

| Step | Click → hosts file written + DNS flushed | Click → system resolver shows the change |
|---|---|---|
| Allow a listed domain | 412 ms | 2.5 s |
| Block it again | 484 ms | 2.0 s |
| Protection off | 193 ms | 0.9 s |
| Protection on | 352 ms | 1.7 s |

**What a big hosts file costs macOS.** mDNSResponder keeps every hosts entry in memory, at about 1.4 KB per line.
With the default list its footprint went from about 16 MB to about 226 MB, of which macOS had compressed about 219 MB within a minute.
Resident memory briefly peaked at about 450 MB after several back-to-back rewrites, then returned to its baseline. Lookups stay under 10 ms.
Enabling the HaGeZi list as well roughly doubles this.

## Testing

```sh
cd Packages/QuietHostsCore && swift test               # 60 unit tests, temporary files only
swift run -c release qh-bench [list files…]             # benchmarks (synthetic 100k/200k + any real lists)
/Applications/QuietHosts.app/Contents/MacOS/QuietHosts --self-test [domain]   # live end-to-end check
```

The unit tests cover:
- hostname validation and normalisation
- hosts and domain-only parsing, including malicious entries
- de-duplication across sources
- rule precedence and toggling
- search ranking
- rebuilding the managed block
- preserving unrelated content byte for byte
- backups and restore
- repeated enable/disable cycles
- malformed and externally edited files
- symlinks
- failed list updates
- the XPC code-signing requirement strings

The self-test changes `/etc/hosts`. It needs the helper approved and the menu-bar app quit, and it restores your rules and protection state afterwards.
Debug builds can render the UI to PNG with `--render-snapshots <dir>`.
