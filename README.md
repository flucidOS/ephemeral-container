# ephemeral-container (`ec`)

**Fail-Closed 1:1 System Cloning & Manual Artifact Sealer for FlucidOS**

`ephemeral-container` (`ec`) is the official system-level escape valve for **FlucidOS**. It provides an interactive, disposable 1:1 clone of the active local OSTree deployment where administrators can manually compile out-of-tree kernel modules (`.ko`) or install standalone system binaries without introducing a package manager, client-side layering, or runtime filesystem drift.

When an `ec` session is sealed via `ec exit`, the engine automatically signs all newly compiled kernel modules using a transient secret-mounted Machine Owner Key (MOK), executes a single unified `depmod -a` pass across the complete module tree, extracts only the clean target artifacts into a pristine system image, stages the deployment via `bootc`, and truncates all container state.

## Core Architectural Invariants

1. **1:1 Local System Clone (Zero Registry Pull)**
   `ec open` materializes its base image directly from the active local deployment under `/sysroot/ostree/deploy/` into Podman storage. It never pulls a base image from a remote registry, guaranteeing 100% kernel ABI and userspace identity with the running host.

2. **Zero Package Manager (Manual Installation Only)**
   To prevent dependency drift and repository metadata pollution, no package manager (`apt`, `dnf`, `rpm-ostree`) is used. Network access is enabled inside the interactive session strictly for fetching pinned upstream sources (`curl`, `git`, `tar`, `sha256sum`) and compiling manually (`make`, `install`).

3. **Deferred Secret-Mounted MOK Signing**
   The private Machine Owner Key (`/etc/flucid/mok/MOK.priv`) is **never** exposed inside the interactive `ec open` shell. Module signing occurs exclusively after the interactive session closes, inside Stage 1 of `Containerfile.seal` via Podman's `--mount=type=secret` mechanism.

4. **The Single Index Invariant (`modules.dep`)**
   Runtime modification of `/usr/lib/modules` is blocked on the host. `ec-container-finalize` runs `depmod -a "${KVER}"` exactly once across the combined in-tree and newly compiled out-of-tree module set, producing a single, collision-free `modules.dep` index.

5. **Two-Stage Clean Artifact Extraction**
   Stage 2 of `Containerfile.seal` starts from an untouched 1:1 local system clone and copies over only:

   * `/usr/lib/modules/<KVER>` (signed `.ko` modules + unified `modules.dep`)

   * `/usr/lib/modprobe.d/` (module configuration and blacklist rules)

   * `/usr/local/` (manually installed system binaries and libraries)

   All build artifacts, downloaded tarballs, and temporary files in `/tmp` or `/root` are permanently left behind.

6. **Fail-Closed Execution & Zero-Residual Truncation**
   If any step fails—compilation, MOK signature attachment, `depmod` verification, or image build—the pipeline aborts immediately before `bootc switch` is invoked. Regardless of whether a session is committed (`ec exit`) or discarded (`ec abort`), `ec-host-engine` purges the container and all temporary Podman layers on exit.

## Architecture & Lifecycle

```
Host (`ec open`)
  │
  ├─► 1. Acquire single-flight lock (/run/ec-session.lock)
  ├─► 2. Verify / generate local MOK keypair (/etc/flucid/mok/)
  ├─► 3. Import 1:1 local OSTree deployment into Podman (localhost/ec-base-clone:active)
  └─► 4. Launch interactive shell ([ec:1:1-clone /tmp/ec-work]#) with --network=host
          │
          ├── User manually fetches source, compiles, and installs into:
          │     • /usr/lib/modules/${KVER}/extra/
          │     • /usr/lib/modprobe.d/
          │     • /usr/local/bin/ or /usr/local/lib/
          │
          ├─► User runs `ec abort` ──► Discard changes & truncate all containers/layers
          │
          └─► User runs `ec exit`  ──► Write commit marker (/var/tmp/.ec-commit) & close shell
                  │
                  ▼
        Host Finalization (`Containerfile.seal`)
          ├─► Stage 1 (`finalize`):
          │     • Mount MOK keys via --mount=type=secret (/run/secrets/mok.priv & mok.der)
          │     • Sign all .ko modules in extra/ and updates/ via kernel sign-file (SHA-256)
          │     • Execute single unified `depmod -a ${KVER}` pass & verify modules.dep
          │
          ├─► Stage 2 (`final`):
          │     • Start FROM clean 1:1 base clone
          │     • COPY only /usr/lib/modules/${KVER}, /usr/lib/modprobe.d/, and /usr/local/
          │
          ├─► Stage deployment via `bootc switch --transport containers-storage`
          └─► Truncate container and purge all temporary Podman images

```

## Repository Layout

```
ephemeral-container/
├── Makefile                        # Build, FHS installation, and test runner targets
├── README.md                       # Package architecture and usage documentation
├── bin/
│   └── ec                          # Context-aware CLI (/usr/bin/ec) for host and container
├── libexec/
│   ├── ec-host-engine              # Host orchestrator (1:1 clone, Podman lifecycle, truncation)
│   └── ec-container-finalize       # Stage-1 finalizer (MOK signing + single depmod pass)
├── share/
│   └── ephemeral-container/
│       ├── Containerfile.seal      # Two-stage pure Podman artifact sealer
│       └── ec-profile.sh           # Interactive container shell environment & prompt
└── tests/
    └── run-tests.sh                # Automated unit & Podman integration test suite (TC-01..TC-08)

```

## Usage

`/usr/bin/ec` is context-aware: it automatically detects whether it is invoked on the FlucidOS host or inside the interactive 1:1 container clone.

### Host Commands

| Command | Description | 
| ----- | ----- | 
| `ec open` | Clones the active 1:1 local system space and opens an interactive container shell. | 
| `ec status` | Checks whether an ephemeral container session is currently running. | 
| `ec exit` | Signals an open session from the host to seal changes, stage via `bootc`, and truncate. | 
| `ec abort` | Signals an open session from the host to discard all changes and truncate immediately. | 

### In-Container Commands

| Command | Description | 
| ----- | ----- | 
| `ec exit` | Marks the session for sealing, exits the shell, triggers MOK signing + `depmod`, and truncates. | 
| `ec abort` | Discards all changes made during the session and truncates the container immediately. | 
| `ec status` | Displays the active 1:1 clone status and target kernel ABI (`KVER`). | 

### Example Workflow: Installing an Out-of-Tree Kernel Module

```
# 1. Open the 1:1 ephemeral container from the FlucidOS host
$ ec open
[ec] Materializing 1:1 local system clone (commit 8f3a91c4b2e1, Kernel 6.12.0-flucid)...
[ec] Opening ephemeral container (Kernel ABI: 6.12.0-flucid)...
================================================================================

# 2. Inside the container, fetch pinned source, verify checksum, compile, and install manually
[ec:1:1-clone ec-work]# curl -fsSL https://example.org/driver-1.2.0.tar.gz -o driver.tar.gz
[ec:1:1-clone ec-work]# echo "<sha256-hash>  driver.tar.gz" | sha256sum -c -
[ec:1:1-clone ec-work]# tar -xzf driver.tar.gz && cd driver-1.2.0
[ec:1:1-clone driver-1.2.0]# make -j"$(nproc)" KSRC="/usr/lib/modules/${KVER}/build"
[ec:1:1-clone driver-1.2.0]# install -D -m 0644 custom_drv.ko "/usr/lib/modules/${KVER}/extra/custom_drv.ko"

# 3. Seal the session and truncate the container
[ec:1:1-clone driver-1.2.0]# ec exit
[ec] Marking session for sealing, MOK signing, and unified depmod...
================================================================================
[ec] Committing Stage 1 snapshot for finalization...
[ec] Running fail-closed finalizer (MOK signing + unified depmod pass)...
[ec] Staging sealed deployment via bootc...
[ec] Success! New deployment staged. Reboot to activate changes.
[ec] Truncating ephemeral container and purging temporary Podman layers...
[ec] Truncation complete. Zero residual container state.

```

## Building, Testing & Installation

### Dependencies

* **Host Runtime:** `bash`, `podman`, `ostree`, `bootc`, `openssl`, `kmod` (`depmod`), `coreutils`, `findutils`, `tar`

* **Build & Test:** `make`, `bash`, `openssl`, `podman` (optional for `TC-07` and `TC-08` end-to-end sealing tests)

### Running the Automated Test Suite

The repository includes an 8-part test suite (`tests/run-tests.sh`) covering static syntax validation, FHS installation layout, CLI context routing, MOK key generation, fail-closed missing secret detection, `.ko` signing, corrupt `modules.dep` rejection, and end-to-end Podman Stage-2 sealing and truncation:

```
make check

```

### Installing into a Target Rootfs (or BuildStream Sandbox)

```
make install DESTDIR=/path/to/target-rootfs

```

## Security Model

* **Single-Flight Concurrency Lock:** Only one `ec` session can exist at a time, guarded by `/run/ec-session.lock` and Podman container state checks with automatic stale-lock recovery.

* **Zero Private Key Exposure:** `/etc/flucid/mok/MOK.priv` (`0600`) is owned by `root` on the host, excluded from the interactive container, mounted transiently via `--mount=type=secret` only during the non-interactive `Containerfile.seal` build, and excluded from Stage 2.

* **Persistent Marker Isolation:** Session commit state is tracked via `/var/tmp/.ec-commit` inside the container's writable overlay rather than `/run` (`tmpfs`), ensuring deterministic handoff to `ec-host-engine` after the interactive process exits.

## License & Authorship

Developed by **Siddharthan T V** as part of the **FlucidOS** project (*"Computing without Chaos"*).