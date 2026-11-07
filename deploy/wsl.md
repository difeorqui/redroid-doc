# Deploy redroid on WSL2 (Windows)

*redroid* runs inside Docker but relies on Linux kernel features (`binderfs`,
`ashmem`/`memfd`, `ION`/`DMA-BUF Heaps`, IPv6, 4KB page size — see the
[mandatory kernel features](README.md)). Windows cannot provide these natively,
so on Windows you run *redroid* inside **WSL2**, which boots a real Linux kernel.

The kernel Microsoft ships with WSL2 does **not** enable these features, so you
must build a WSL2 kernel with them turned on and tell WSL to use it.

> Verified on Windows 11 (amd64), WSL 3.0, kernel `6.18.54.1`, Ubuntu 24.04,
> Docker 29, redroid Android 11–15. You need virtualization enabled in BIOS and
> ~15 GB free to build the kernel.

## 1. Install WSL2 and a build distro

```powershell
wsl --install -d Ubuntu-24.04    # a general-purpose distro to build in
wsl --version                    # note the kernel version (e.g. 6.18.54.1)
```

Run the rest of the Linux commands inside that distro.

## 2. Build a WSL2 kernel with the required features

```bash
## install build dependencies
sudo apt update
sudo apt install -y build-essential flex bison libssl-dev libelf-dev \
    bc dwarves python3 cpio kmod rsync libncurses-dev

## download the official WSL2 kernel source, on the tag that matches the
## version shown by `wsl --version` (tags: linux-msft-wsl-<version>)
## https://github.com/microsoft/WSL2-Linux-Kernel/tags
git clone --depth 1 --branch linux-msft-wsl-6.18.54.1 \
    https://github.com/microsoft/WSL2-Linux-Kernel.git
cd WSL2-Linux-Kernel
cp Microsoft/config-wsl .config
```

Enable the required features. `config-wsl` already enables IPv6; you mainly need
to add binderfs and DMA-BUF Heaps:

```bash
./scripts/config --file .config \
    --enable  CONFIG_DMABUF_HEAPS \
    --enable  CONFIG_DMABUF_HEAPS_SYSTEM \
    --enable  CONFIG_ANDROID \
    --enable  CONFIG_ANDROID_BINDER_IPC \
    --enable  CONFIG_ANDROID_BINDERFS \
    --set-str CONFIG_ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder"
make olddefconfig
```

> `ashmem` (`CONFIG_ASHMEM`, under `CONFIG_STAGING`) was removed from the kernel
> in 5.18 and no longer exists on modern kernels. Use `androidboot.use_memfd=true`
> at run time (step 6) instead.

Build the kernel **and install its modules**. `config-wsl` builds netfilter,
bridge and iptables as *modules* (`=m`), and Docker and Android's `netd` need
them, so `make modules_install` is required — not just the `bzImage`:

```bash
make -j"$(nproc)"
sudo make modules_install          # installs /lib/modules/$(uname -r from build)

## copy the kernel to a Windows path
mkdir -p /mnt/c/Users/<YOU>/wsl-kernel
cp arch/x86/boot/bzImage /mnt/c/Users/<YOU>/wsl-kernel/bzImage-redroid
```

## 3. Tell WSL to use the new kernel

Create or edit `C:\Users\<YOU>\.wslconfig`
([docs](https://learn.microsoft.com/windows/wsl/wsl-config#configuration-settings-for-wslconfig)):

```ini
[wsl2]
kernel=C:\\Users\\<YOU>\\wsl-kernel\\bzImage-redroid
```

Apply it from PowerShell, then reopen the distro:

```powershell
wsl --shutdown
```

## 4. Verify the kernel

```bash
uname -r                                   # your rebuilt kernel (note trailing +)
zcat /proc/config.gz | grep -E "BINDERFS|DMABUF_HEAPS|ANDROID_BINDER_IPC"
```

## 5. Install Docker and load the kernel modules it needs

Install Docker (`docker-ce`:
https://docs.docker.com/engine/install/ubuntu/, or Docker Desktop with WSL2
integration).

On an `nft`-based distro (Ubuntu 24.04), switch iptables to the legacy backend,
which Docker needs with this kernel:

```bash
sudo update-alternatives --set iptables  /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

Load the netfilter/bridge modules (Docker's bridge network **and** Android's
`netd` need them) and make them persist across reboots:

```bash
sudo tee /etc/modules-load.d/redroid.conf >/dev/null <<'EOF'
ip_tables
iptable_nat
iptable_filter
iptable_mangle
iptable_raw
ip6_tables
ip6table_nat
ip6table_filter
ip6table_mangle
ip6table_raw
nf_nat
nf_conntrack
nf_conntrack_netlink
nf_log_syslog
nf_reject_ipv4
nf_reject_ipv6
xt_conntrack
xt_addrtype
xt_MASQUERADE
xt_mark
xt_nat
xt_tcpudp
xt_comment
xt_multiport
xt_connmark
xt_CT
xt_owner
xt_socket
xt_state
xt_bpf
xt_IDLETIMER
br_netfilter
bridge
overlay
EOF
sudo systemctl restart systemd-modules-load
sudo systemctl restart docker
docker run --rm hello-world        # should print "Hello from Docker!"
```

> If `dockerd` fails with `addrtype ... missing kernel module` or
> `conntrack ... missing kernel module`, a module above is not loaded.

## 6. Run redroid

```bash
docker run -itd --privileged \
    -v ~/redroid-data:/data \
    -p 5555:5555 \
    --name redroid \
    redroid/redroid:15.0.0-latest \
    androidboot.redroid_gpu_mode=guest \
    androidboot.use_memfd=true
```

> If it fails with `Conflict. The container name "/redroid" is already in use`,
> a container with that name already exists (running or stopped). Reuse it with
> `docker start redroid`, or remove it and run again:
> `docker rm -f redroid` (add `sudo rm -rf ~/redroid-data` to also start with fresh data; `sudo` is
> required because Android creates those files as root, otherwise you get
> `Permission denied`).

**Android version / GPU on WSL.** Use `redroid_gpu_mode=guest` (software
rendering). WSL exposes the GPU over Direct3D12 (`/dev/dri/renderD128`, mesa
`d3d12`), but its EGL/GLES does not satisfy SurfaceFlinger, so
`redroid_gpu_mode=host` crashes SurfaceFlinger on boot (`chooseEglConfig`,
`GLESRenderEngine::create`). In `guest` mode **Android 8.1 through 15 boot
cleanly** (including the `_64only` images); **Android 16 does not boot on WSL
yet**, so prefer Android ≤15. See the main
[README](../README.md#configuration) for all boot options.

> **Why Android 16 fails on WSL (for the curious).** It hits two separate
> blockers. First, SurfaceFlinger aborts while priming its shader cache
> (`output buffer not gpu writeable`); this one is avoidable by setting
> `service.sf.prime_shader_cache=0` (e.g. appended to `/vendor/build.prop` in a
> derived image). Second, Android 16's `ApplicationSharedMemory` opens
> `/dev/ashmem` directly, which does not exist on kernels ≥5.18 and is **not**
> covered by `androidboot.use_memfd=true`; providing it needs an out-of-tree
> `ashmem` module (see [redroid-modules](https://github.com/remote-android/redroid-modules)),
> ported to the 6.x module APIs. These were not fully working at the time of
> writing, hence the Android ≤15 recommendation.

## 7. Connect from Windows

Install [scrcpy](https://github.com/Genymobile/scrcpy) (it bundles `adb`) on
Windows, e.g. `winget install Genymobile.scrcpy`. Port `5555` is reachable from
Windows via WSL2 localhost forwarding:

```powershell
adb connect localhost:5555
adb devices                        # localhost:5555  device
scrcpy -s localhost:5555 --no-audio
```

`--no-audio` avoids a scrcpy startup failure when the redroid image lacks an
OPUS audio encoder (e.g. Android 11).

## Troubleshooting

- **Container disappears / reboots after ~1 min** — SurfaceFlinger is crashing;
  use `redroid_gpu_mode=guest` and Android ≤15 (see step 6). Check
  `docker exec redroid /system/bin/logcat -d -b crash`.
- **Docker daemon won't start** (`addrtype`/`conntrack` *missing kernel module*)
  — load the modules in step 5 and switch to `iptables-legacy`.
- **`/dev/binder` errors** — confirm binderfs: inside the container
  `ls -l /dev/binderfs` should show `binder`, `hwbinder`, `vndbinder`.
- **Networking in `mirrored` mode** may break connectivity; the default NAT mode
  works, or connect by the distro IP (`wsl hostname -I`).
