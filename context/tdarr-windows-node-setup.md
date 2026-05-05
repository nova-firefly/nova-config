# Tdarr Windows Node Setup — RTX 3080 ad-hoc worker

This procedure turns a Windows desktop into a Tdarr remote worker that connects
to the `tdarr-server` running in Nova's media stack. The worker is **ad-hoc**:
spin it up for bulk library cleanup runs, shut it down when the queue is drained.

> **Why ad-hoc?** Nova has a GTX 970 (Maxwell) which is too low quality for
> meaningful HEVC encoding. The RTX 3080 (Ampere, 7th-gen NVENC) is the
> encoder. The desktop doesn't need to be online for ongoing trickle work —
> the server's CPU-only built-in node handles that. See
> [`docker-compose.media.yaml`](../docker-compose.media.yaml) for the
> server-side config and the future-flexibility template (a containerised
> Nova-local node when/if the server GPU is upgraded).

---

## Repeatability checklist

If you've done this before and just need the procedure:

- [ ] Nova: `mkdir -p /data1/tdarr/cache && chown -R $PUID:$PGID /data1/tdarr`
- [ ] Nova: ensure SMB exports cover `/data1`, `/data2`, `/data3` (see § Samba)
- [ ] Nova: `./nova.sh up media` (brings up `tdarr-server`)
- [ ] Windows: SMB-mount `\\<NOVA>\data1`, `\\<NOVA>\data2`, `\\<NOVA>\data3` as drive letters
- [ ] Windows: install latest NVIDIA Studio driver (for stable NVENC)
- [ ] Windows: download Tdarr ZIP from <https://f000.backblazeb2.com/file/tdarr/versions.html>, extract to `C:\Tdarr\`
- [ ] Windows: edit `C:\Tdarr\Tdarr_Node\configs\Tdarr_Node_Config.json` (see § Node config)
- [ ] Windows: open inbound TCP 8267 on the firewall (`netsh advfirewall ...`)
- [ ] Nova: confirm 8266 reachable from desktop (`Test-NetConnection <NOVA> -Port 8266`)
- [ ] Windows: launch `Tdarr_Node.exe` (or the registered service)
- [ ] Tdarr UI: confirm new node appears in the Nodes panel with `Tdarr-Win-3080`
- [ ] Tdarr UI: assign GPU workers to the Windows node, CPU workers to the internal node
- [ ] Tdarr UI: enable target Library + Flow → start the queue

Full detail below.

---

## 1. Nova-side prep

### 1a. Create transcode cache & ensure permissions

Run on the Nova host (not from inside vibe-kanban — the read-only proxy can't):

```bash
sudo mkdir -p /data1/tdarr/cache
sudo chown -R "$(id -u):$(id -g)" /data1/tdarr   # PUID/PGID from .env
sudo chmod 775 /data1/tdarr/cache
```

The cache lives on `/data1` because (a) it has the most free space, and
(b) the same drive is shared via SMB to the Windows node, which means the
node and server resolve `/temp` and `Z:\tdarr\cache` to the same physical
files — required by Tdarr's distributed worker model.

### 1b. Samba export of the media drives

The Windows node must be able to **read+write** the same files as
`tdarr-server` sees inside the container at `/library1`, `/library2`,
`/library3`, and `/temp`. The simplest path is host-level Samba.

Skip this step if Nova already exposes `/data1`, `/data2`, `/data3` over SMB
(check with `smbclient -L //localhost -N` or by mapping a drive on a Windows
client).

Otherwise, on the Nova host:

```bash
sudo apt update && sudo apt install -y samba
sudo smbpasswd -a "$USER"   # set a password for the SMB user; remember it
```

Append to `/etc/samba/smb.conf`:

```ini
[data1]
  path = /data1
  valid users = your-username
  read only = no
  browseable = yes
  create mask = 0664
  directory mask = 0775

[data2]
  path = /data2
  valid users = your-username
  read only = no
  browseable = yes
  create mask = 0664
  directory mask = 0775

[data3]
  path = /data3
  valid users = your-username
  read only = no
  browseable = yes
  create mask = 0664
  directory mask = 0775
```

Then:

```bash
sudo testparm                 # syntax-check
sudo systemctl restart smbd
sudo ufw allow from 192.168.1.0/24 to any app Samba   # if ufw is on
```

> **Security note.** This SMB share is LAN-only. Do NOT port-forward 445 to
> the internet. If the firewall rule above feels too broad, scope it to a
> single host: `sudo ufw allow from 192.168.1.42 to any app Samba`.

### 1c. Bring up tdarr-server

```bash
docker volume create tdarr_server tdarr_configs tdarr_logs
./nova.sh up media
```

Verify:

```bash
docker logs tdarr-server -f                         # wait for "Server initialised"
curl -fsS http://localhost:8265/api/v2/status | jq  # 200 + status JSON
```

Then in a browser, open `https://tdarr.<NOVA_DOMAIN>` (Authelia gate first). You
should see the Tdarr UI with one node listed: `NovaInternalCPU`.

### 1d. Configure libraries in Tdarr UI

In the UI, **Libraries** panel → **Add new library** for each:

| Library name | Source folder | Plugins source |
|---|---|---|
| Movies — data1 | `/library1/movies` | Community |
| TV — data1 | `/library1/tv` | Community |
| Movies — data2 | `/library2/movies` | Community |
| TV — data2 | `/library2/tv` | Community |
| Movies — data3 | `/library3/movies` | Community |
| TV — data3 | `/library3/tv` | Community |

Cache: `/temp` (default — already set by the bind mount).

Don't enable any flow yet. We'll do that in § 5 once the Windows node is online.

---

## 2. Windows-side: SMB mount

On the Windows desktop, mount each Nova share as a drive letter. PowerShell
(run as a normal user, not admin — admin sessions can't see user drives):

```powershell
$cred = Get-Credential               # user: <NOVA_USER>, password: SMB password from § 1b
New-SmbMapping -LocalPath 'X:' -RemotePath '\\<NOVA_HOSTNAME>\data1' -UserName $cred.UserName -Password ($cred.GetNetworkCredential().Password) -Persistent $true
New-SmbMapping -LocalPath 'Y:' -RemotePath '\\<NOVA_HOSTNAME>\data2' -UserName $cred.UserName -Password ($cred.GetNetworkCredential().Password) -Persistent $true
New-SmbMapping -LocalPath 'Z:' -RemotePath '\\<NOVA_HOSTNAME>\data3' -UserName $cred.UserName -Password ($cred.GetNetworkCredential().Password) -Persistent $true
```

`X:`, `Y:`, `Z:` are arbitrary — pick anything you don't already use. **Whatever
you pick must match the path translators in § 4 exactly.**

Verify: `dir X:\plex_data_1\_data\movies` should list movie folders.

> **If Tdarr_Node will run as a Windows Service** (recommended for unattended
> runs), the LocalSystem account doesn't see user-mounted drives. Either:
> (a) run the node as a console app from your user session for the bulk run,
> or (b) configure the service to run as your user, or (c) use UNC paths
> (`\\<NOVA>\data1\...`) directly in the path translators instead of drive
> letters. Option (a) is simplest and fine for an ad-hoc bulk run.

---

## 3. Windows-side: install Tdarr_Node

1. Update NVIDIA driver to current Studio or Game Ready release (NVENC
   stability matters; ancient drivers occasionally OOM on long encodes).
2. Download the latest `Tdarr_<version>_Windows_x64.zip` from
   <https://f000.backblazeb2.com/file/tdarr/versions.html>.
3. Extract to `C:\Tdarr\`. You should now have:
   ```
   C:\Tdarr\Tdarr_Node\Tdarr_Node.exe
   C:\Tdarr\Tdarr_Node\configs\Tdarr_Node_Config.json
   C:\Tdarr\Tdarr_Updater\Tdarr_Updater.exe   (optional — keeps node updated)
   ```
4. Optional: run `Tdarr_Updater.exe` once to pull the newest patch release.

> Don't run `Tdarr_Server.exe` from this install — the server lives in Docker
> on Nova. Only `Tdarr_Node.exe` is used here.

---

## 4. Node config — `Tdarr_Node_Config.json`

Edit `C:\Tdarr\Tdarr_Node\configs\Tdarr_Node_Config.json`. Replace contents with:

```json
{
  "nodeName": "Tdarr-Win-3080",
  "serverIP": "<NOVA_HOSTNAME_OR_LAN_IP>",
  "serverPort": "8266",
  "nodePort": "8267",
  "nodeType": "mapped",
  "priority": 0,
  "pathTranslators": [
    { "server": "/library1", "node": "X:\\plex_data_1\\_data" },
    { "server": "/library2", "node": "Y:\\" },
    { "server": "/library3", "node": "Z:\\" },
    { "server": "/temp",     "node": "X:\\tdarr\\cache" }
  ],
  "logsPath": "",
  "cronPluginUpdate": "",
  "cronServerCheck": ""
}
```

**Substitute `<NOVA_HOSTNAME_OR_LAN_IP>`** with whatever the Windows machine
can reach Nova on (`nova`, `nova.local`, `192.168.1.x`, etc).

**Substitute the drive letters** (`X:`, `Y:`, `Z:`) with whichever you used in § 2.

> **JSON escape gotcha — read this carefully.** Backslashes in JSON strings
> must be doubled: `"X:\\plex_data_1\\_data"`. A single `\_` is an *invalid*
> JSON escape and most parsers silently drop the backslash, so
> `"X:\plex_data_1\_data"` becomes `X:\plex_data_1_data` at runtime — and
> every job fails with `ENOENT: no such file or directory` because the
> directory `\_data` is missing from the path.
>
> If you prefer to avoid escapes entirely, forward slashes also work on
> Windows: `"X:/plex_data_1/_data"`. Either form is fine; just don't ship
> single-backslash paths.

> **Why the pathTranslators?** The server sees the data at Linux paths like
> `/library1/movies/Movie (2020)/movie.mkv`. The node accesses the same file
> at `X:\plex_data_1\_data\movies\Movie (2020)\movie.mkv`. Path translators
> rewrite the path on each encode job; without them every job will fail with
> "file not found" on the node.
>
> The `/library1` mapping has `\plex_data_1\_data` appended because Plex's
> directory layout on data1 nests an extra level — `/data1/plex_data_1/_data`
> is what `tdarr-server` mounts as `/library1`. data2 and data3 are flat,
> so the translators map directly to drive root.

---

## 5. Firewall holes

The node and server need a TCP socket between them in **both directions**.

**On the Windows desktop** (PowerShell as Administrator):

```powershell
New-NetFirewallRule -DisplayName 'Tdarr Node Inbound' -Direction Inbound -Protocol TCP -LocalPort 8267 -Action Allow
New-NetFirewallRule -DisplayName 'Tdarr Node Outbound' -Direction Outbound -Protocol TCP -RemotePort 8266 -Action Allow
```

**On the Nova host** (port 8266 is already exposed by the compose file via
`ports:`, which writes a Docker-managed iptables rule). Verify from the
Windows desktop:

```powershell
Test-NetConnection <NOVA_HOSTNAME_OR_LAN_IP> -Port 8266
# Expect: TcpTestSucceeded : True
```

If this fails, suspect (in order): Windows firewall outbound rule missing,
host-level firewall on Nova (`sudo ufw status` / `sudo iptables -L -n`),
networking misconfig.

---

## 6. Run the node

For a one-off bulk run, just double-click `C:\Tdarr\Tdarr_Node\Tdarr_Node.exe`.
A console window opens; leave it running. Closing it stops the node. If a
Windows update reboots the desktop mid-encode, in-flight jobs roll back to
the queue and the next launch picks them up.

For unattended runs, register as a Windows Service via NSSM:

```powershell
choco install nssm                 # or download from https://nssm.cc/
nssm install Tdarr_Node "C:\Tdarr\Tdarr_Node\Tdarr_Node.exe"
nssm set    Tdarr_Node AppDirectory "C:\Tdarr\Tdarr_Node"
nssm set    Tdarr_Node ObjectName ".\<your-user>" "<your-password>"   # so SMB drives are visible
nssm start  Tdarr_Node
```

> ⚠ **The LocalSystem trap.** Windows services default to running as
> `LocalSystem`, which **does not see drive letters mapped by your user
> account**. If you skip the `ObjectName` line above (or install the service
> via the GUI without overriding the account), every job will fail with
> `ENOENT: no such file or directory` even though the path itself is
> correct, because the service is looking at a drive letter that doesn't
> exist in its session.
>
> **Two ways to avoid this:**
>
> 1. **Run the service as your user account** — set `ObjectName` as shown
>    above, or after the fact: `services.msc` → `Tdarr_Node` → Properties
>    → Log On tab → "This account" → enter your username and password,
>    then restart the service.
>
> 2. **Switch pathTranslators to UNC paths** — works under LocalSystem
>    without any service reconfiguration, as long as the SMB share allows
>    the access (guest or saved credentials):
>
>    ```json
>    "pathTranslators": [
>      { "server": "/library1", "node": "\\\\NOVA\\data1\\plex_data_1\\_data" },
>      { "server": "/library2", "node": "\\\\NOVA\\data2" },
>      { "server": "/library3", "node": "\\\\NOVA\\data3" },
>      { "server": "/temp",     "node": "X:\\tdarr\\cache" }
>    ]
>    ```
>
>    (UNC needs four backslashes per `\\` due to JSON escaping. Forward
>    slashes do *not* work for UNC — must be backslashes.)

In the Tdarr UI (Nodes panel, top right) you should now see two nodes:
`NovaInternalCPU` and `Tdarr-Win-3080`.

---

## 7. Worker assignment & flow setup

In the Tdarr UI, **Nodes** panel:

| Node | CPU Health Workers | CPU Transcode Workers | GPU Health Workers | GPU Transcode Workers |
|---|---|---|---|---|
| `NovaInternalCPU` | 1 | 1 | 0 | 0 |
| `Tdarr-Win-3080` | 0 | 0 | 1 | **2** |

> The 3080 can run 2 simultaneous NVENC HEVC sessions cleanly (the consumer
> driver's session limit was lifted in the 530+ series). Bumping to 3 is
> usually fine; 4+ trades quality for throughput.

### 7a. Flows to enable

This is the lightweight scope agreed for Path 2 — **no quality reductions, no
1080p H264→HEVC**. Tdarr's library transcoder is configured via **Flows**
(visual node-based pipelines), not classic plugins. The classic
`Tdarr_Plugin_MC93_Migz*` plugin names you may have seen elsewhere are a
separate older system; ignore them — Flows is the actively-developed path
and the only path documented here.

> **Quick orientation.** A Flow is a directed graph of nodes:
> - **Filter nodes** (`checkVideoCodec`, `checkHdr`, `check10Bit`,
>   `checkOverallBitrate`, `checkAudioCodec`, `checkChannelCount`) inspect a
>   file and route it down the **`true`** or **`false`** path.
> - **ffmpeg-command nodes** (`ffmpegCommandStart`, `ffmpegCommandSetVideoEncoder`,
>   `ffmpegCommandSetVideoBitrate`, `ffmpegCommandEnsureAudioStream`,
>   `ffmpegCommandRorderStreams`, `ffmpegCommandExecute`) build up an ffmpeg
>   command pipeline and then run it.
> - **Output nodes** decide what happens to the result (`Replace original
>   file`, `Move to library`, etc.).
>
> A flow always starts at the `Input file` node and ends at one of the
> output terminators. Filters that hit `false` typically connect to "Output
> file: NoChange" — i.e. skip this file.

#### 7a.i. Get oriented with the built-in tutorial flows

Before building anything custom, study the templates that ship with Tdarr:

1. Tdarr UI → **Flows** tab (top nav).
2. Click **Flow+** (top-left button on that tab).
3. The dropdown lists tutorial templates — `Tutorial Flow 1 - Basic`,
   `Tutorial Flow 2 - Branching`, `Tutorial Flow 3 - FFmpegCommand`, etc.
   Pick `Tutorial Flow 3 - FFmpegCommand` and walk the canvas left-to-right.
4. The same dropdown also has fully-formed templates such as
   `Re-encode video to H264 / H265 NVENC`, `Re-encode video to H264 / H265
   QSV`, etc. Spawning one creates a copy you can edit.

> **None of these built-in templates exactly match Path 2's three flows**,
> but `Re-encode video to H264 / H265 NVENC` is ~80% of Flow B (legacy codec
> cleanup) and a reasonable starting point.

#### 7a.ii. Three flows to build

Build each as a separate flow (Flows tab → **Add flow** → name it). Then
assign the appropriate flow to each library (Library card → Edit → switch
**Transcode Mode** to **Flow** → pick the named flow).

##### Flow A — Audio hygiene (root cause of ~50% transcode rate)

**Goal:** every file has at least one English AAC stereo track. Pure audio
remux — no video re-encode.

Flow graph:

```
Input file
  → ffmpegCommandStart
  → checkAudioCodec   (does an AAC stereo English track already exist?)
       │ true  → Output file: NoChange
       └ false →
  → ffmpegCommandEnsureAudioStream
       (codec: aac, channels: 2, language: eng, sample rate: 48000, bitrate: 192k)
  → ffmpegCommandRorderStreams
       (push the new aac/2ch track ahead of legacy tracks)
  → ffmpegCommandExecute
  → Output file: Replace original
```

Settings on `checkAudioCodec`: configure for `audioCodec=aac` AND
`channelCount=2` AND `language=eng`. Tdarr uses `AND` if you chain
`checkAudioCodec` → `checkChannelCount` → `checkLanguage` filters; otherwise
combine them in the single node's "must match all" mode.

Settings on `ffmpegCommandEnsureAudioStream`:
- `Audio encoder` = `aac`
- `Channels` = `2`
- `Bitrate` = `192k`
- `Language` = `eng`
- `Should add` = `true if not present`

Apply to: **all libraries**.

##### Flow B — Legacy codec cleanup

**Goal:** re-encode mpeg2 / vc1 / mpeg4 (xvid/divx) / wmv → H.264 NVENC.
These are old, small, and rare; quality loss is irrelevant.

Flow graph:

```
Input file
  → checkVideoCodec   (codec in [mpeg2video, vc1, mpeg4, msmpeg4v3, wmv3, wmv2, wmv1])
       │ false → Output file: NoChange
       └ true  →
  → ffmpegCommandStart
  → ffmpegCommandSetVideoEncoder   (encoder: h264_nvenc, preset: slow, cq: 19)
  → ffmpegCommandExecute
  → Output file: Replace original
```

> **Why h264_nvenc not h265 here:** the source files are tiny (sub-2 GB)
> and short-lived in importance. h264 keeps the broadest client compat.
> h265 buys ~30% size but adds decode incompatibility on rare clients.

Apply to: **all libraries**.

##### Flow C — Oversized SDR HEVC capping

**Goal:** re-encode SDR HEVC files exceeding Recyclarr's per-minute bitrate
cap (≈83 MB/min for 2160p) down to that ceiling. Skip HDR entirely.

Flow graph:

```
Input file
  → checkVideoCodec       (codec == hevc?)
       │ false → Output: NoChange
       └ true  →
  → check10Bit             (10-bit?  HDR is always 10-bit; this filters HDR out)
       │ true  → Output: NoChange
       └ false →
  → checkHdr               (extra safety belt for HDR-flagged 8-bit edge cases)
       │ true  → Output: NoChange
       └ false →
  → checkOverallBitrate    (bitrate > 8000 kbps for 2160p, > 4000 for 1080p)
       │ false → Output: NoChange
       └ true  →
  → ffmpegCommandStart
  → ffmpegCommandSetVideoEncoder  (encoder: hevc_nvenc, preset: slow)
  → ffmpegCommandSetVideoBitrate  (target: 8000k for 2160p / 4000k for 1080p)
  → ffmpegCommandExecute
  → Output: Replace original
```

> **Why two separate libraries (or two flows):** the bitrate ceiling is
> resolution-dependent. Easiest pattern is to clone Flow C as `C-2160p` and
> `C-1080p` with different bitrate values, then assign each to libraries
> filtered by resolution — or use `checkVideoResolution` filter inside one
> flow and branch.

Apply to: **all libraries**.

> **Explicitly NOT built:** any flow that re-encodes 1080p H264→HEVC (would
> trigger Recyclarr upgrade re-grabs because `x265 (HD)` scores -10000), and
> any HDR re-encoding (10-bit + tone-mapping risk, and the 3080 NVENC
> tonemap path isn't reliable enough for set-and-forget).

#### 7a.iii. Importing the three Nova flows from this repo

Three importable flow JSON files live in `nova-config/tdarr/flows/`,
encoding the three flows above as exact graphs:

| File | Flow |
| --- | --- |
| `audio-hygiene.json` | Flow A — Audio hygiene |
| `legacy-codec-cleanup.json` | Flow B — Legacy codec cleanup (mpeg2/mpeg4/wmv3 → H.264 NVENC) |
| `oversized-sdr-hevc.json` | Flow C — Oversized SDR HEVC capping (1080p > 4000kbps, 4K > 8000kbps) |

**Option 1 — Paste-import in the UI (fastest):**

1. Open one of the JSON files, copy the entire contents.
2. Tdarr UI → **Flows** tab → **Flow+** → **Import flow** → paste → Save.
3. Repeat for the other two.
4. Each flow now appears in the flow list and can be assigned to a library
   (Libraries → choose library → Transcode tab → set "Flow" = Nova flow).

**Option 2 — Drop into the server volume (versioned, survives recreates):**

```bash
# On Nova host, from the nova-config worktree
for f in tdarr/flows/*.json; do
  docker cp "$f" tdarr-server:/app/server/Tdarr/Plugins/Local/
done
docker exec tdarr-server chown -R 1000:1000 /app/server/Tdarr/Plugins/Local/
# Click 🔄 Update plugins in the Tdarr UI top toolbar to pick them up.
```

The flows now persist across container recreates because `tdarr_server` is
an external named volume.

**Option 3 — Build from scratch.** The flow *nodes* (`checkVideoCodec`,
`ffmpegCommandSetVideoEncoder`, etc.) are part of `Tdarr_Plugins`, which is
auto-synced into the server on startup. You can drag them onto a blank
canvas and rebuild any of the three flows by hand using the diagrams in
§ 7a.ii as the reference.

> The Tdarr "Update plugins" button (top toolbar, sync icon) re-pulls the
> upstream `HaveAGitGat/Tdarr_Plugins` repo onto the server. Click it after
> any flow node update is announced, and after dropping local flow JSON into
> the server volume.

> **Tweaking after import:** open a flow, click any node, edit values in
> the side panel, save. The repo JSON is the *baseline* — the running
> server keeps its own copy in `tdarr_server` once imported. Re-export
> from the UI (… menu → Export) and overwrite the repo file when you make
> a change worth committing.

#### 7a.iv. If a flow node is missing

If a node listed above (e.g. `ffmpegCommandEnsureAudioStream`) doesn't
appear in the flow-builder palette, your server hasn't synced plugins yet:

1. Tdarr UI top toolbar → click **🔄 Update plugins**.
2. Wait for the toast notification "Plugins updated".
3. Refresh the flow editor.

If the node still isn't there, check `docker logs tdarr-server | grep -i
plugin` for sync errors, and confirm the server has internet egress
(plugin updates pull from GitHub).

### 7b. Start the queue

Enable the libraries → Tdarr begins scanning. The first scan can take hours
on a big library (it's just `ffprobe` on every file). Once scanning
completes, the queue populates and the Windows node starts encoding.

Monitor in the **Statistics** tab: throughput, GB saved, success rate.

---

## 8. Shutting down cleanly when the bulk run is done

1. Tdarr UI → Nodes panel → set Windows node workers to 0. In-flight jobs
   complete; new jobs route to the internal CPU node.
2. Wait for "Workers" to show 0/0 on the Windows row.
3. Stop `Tdarr_Node.exe` (close console or `nssm stop Tdarr_Node`).
4. Optionally: `Remove-SmbMapping X:,Y:,Z: -Force` if you don't want the
   shares mounted persistently.

The internal CPU node continues handling ongoing audio hygiene and the
occasional new legacy-codec grab, indefinitely.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Node never appears in UI | Windows firewall, wrong `serverIP`, server down | `Test-NetConnection <nova> -Port 8266`; check `docker logs tdarr-server` |
| Jobs fail "file not found on node" | Path translator typo or drive not mounted | Verify drive letters with `Get-SmbMapping`; `dir X:\plex_data_1\_data\movies` |
| Jobs hang at 0% | Cache path inaccessible from node | Confirm `X:\tdarr\cache` exists and is writable; check translator `/temp` mapping |
| NVENC errors / quality issues | Old NVIDIA driver, too many concurrent sessions | Update driver; reduce GPU workers to 1 |
| Service starts but can't see X: | Service running as LocalSystem | Reconfigure service to run as your user (§ 6) or switch to UNC translators |
| Encodes much slower than expected | Source files reading over Wi-Fi | Use wired GbE; UHD sources can saturate Wi-Fi |
| Permission-denied on cache writes | UID/GID mismatch between Nova and SMB | Check `chown` on `/data1/tdarr` matches the SMB user; loosen `create mask` if needed |

### Useful logs

- **Server side:** `docker logs tdarr-server -f`, plus the `tdarr_logs` volume
  (`docker run --rm -it -v tdarr_logs:/logs alpine ls /logs`).
- **Node side:** `C:\Tdarr\Tdarr_Node\logs\` — rolling files, look at the
  newest one.
- **Per-job logs** are visible in the UI by clicking a queued or failed job.

---

## 10. Future flexibility

- **Replace the 3080 desktop with a different machine.** Rerun this procedure
  on the new host. The server is unchanged.
- **Run multiple external nodes.** Both can connect to the same server
  simultaneously; just change `nodeName` and pick non-overlapping worker
  assignments.
- **Add a permanent Nova-local GPU node** (after a Nova GPU upgrade). See the
  template at the bottom of `docker-compose.media.yaml`. The Windows node
  remains compatible; you can keep both or retire the desktop side.
- **Switch path translators to UNC** (`\\nova\data1\...`) if the
  drive-letter approach causes service-account headaches. UNC paths work
  identically; just edit `pathTranslators` in `Tdarr_Node_Config.json`.
