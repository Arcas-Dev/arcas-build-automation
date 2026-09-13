# Admin Panel: Build Controls

**Status**: SPEC, 2026-09-13. Nothing built.
**Goal**: a Controls section in the admin panel that shows whether the build VM is on, turns it
on, and starts a build, without anyone opening a terminal.

---

## 1. What exists today (verified, not assumed)

| Piece | Reality |
|-------|---------|
| Admin panel | `repos/arcas-admin`, Next.js 14.2.35 App Router, deployed on Vercel at `arcas-champions-admin.vercel.app`, GitHub `Arcas-Dev/arcas-champions-admin` |
| Admin auth | Client-side Firebase Google sign-in. `ALLOWED_EMAILS` is a **hardcoded array** in `components/auth-provider.tsx` |
| Admin server code | **None.** `app/` holds only `layout.tsx` and `page.tsx`. There are no API routes and no server secrets |
| Firestore | Named database `arcas-admin`, rules in `firestore.rules`, deployed via the Rules REST API |
| VM | `arcas-build-server-gpu`, g2-standard-16 + L4, `europe-west6-b`, project `arcas-champions`. **Ephemeral IP** |
| Cloud Function | `vm-stockout-watcher`, gen2, `europe-west6`, runs as SA `vm-watcher@…` via **metadata token** (no key file). Already reads the instance, starts it, polls the zone operation, and DMs Telegram |
| Build entry point | `C:\A\Scripts\build-all.bat` → `build-all.ps1`. Writes `C:\A\status.txt` and `C:\A\Logs\build-all-*.log` |
| Registry guard | `build-all.ps1` phase 0 stops the build when the Edgegap registry holds >= 8 images (`$MaxRegistryImages`), read from `registry.edgegap.com/v2/<image>/tags/list` |

⚠️ **Cruft to delete**: a Windows scheduled task `UE5Build` is enabled on the VM with a one-shot
trigger dated 2026-02-07, pointing at `ArcasChampionsSteam.uproject`, a path that no longer exists.
It is dead. Remove it so it is never confused with the poller below.

---

## 2. Decisions

- **A1. The endpoints live on the Cloud Function, not on Vercel.** Vercel would need a GCP service
  account key as an env var, which is long-lived key material for the project that holds the game
  backend. The function already authenticates with a metadata token and already does the hard half.
- **A2. The build is triggered through instance metadata, not SSH.** SSH from Vercel would need the
  private key stored off-machine plus the VM's ephemeral IP. Metadata is writable by the function
  through the normal API and readable by the VM itself **with no credentials at all**.
- **A3. Build progress comes back as guest attributes**, so the panel gets live status without a
  second channel and without anything connecting inward to the VM.
- **A4. The panel talks to the function through a Next.js route handler**, never from the browser,
  so the shared secret is server side only and is never prefixed `NEXT_PUBLIC_`.

### Rejected

- **SSH from a Vercel function.** Key material off-machine, plus IP chasing. A serverless function
  holding a shell into the build machine is a worse position than we have now.
- **A Cloud Build trigger.** Cloud Build already runs in this pipeline for the Docker push, but the
  UE5 cook has to happen on the Windows VM. It cannot move.
- **Firestore as the request channel.** Would need credentials on the VM. Metadata needs none.

---

## 3. How the build trigger works

```
Controls tab            Next.js route         Cloud Function            Build VM
  [Build] ──────────▶  /api/controls/build ──▶ setMetadata            (metadata server)
                        + shared secret        build-request=<id>
                                                                      poller reads own
                                                                      metadata every 30s
                                                                      id changed? ──▶ build-all.bat
  status  ◀─────────  poll ◀───────────────── read guest attributes ◀── poller writes
                                               + instance state          phase + tag
```

The poller is a small PowerShell script run by a scheduled task at boot, looping every 30 seconds:

1. `GET http://metadata.google.internal/computeMetadata/v1/instance/attributes/build-request`
   with header `Metadata-Flavor: Google`.
2. Compare against the last id saved on disk. Unchanged or absent means do nothing.
3. Changed means save the new id **first** (so a crash cannot cause a rebuild loop), then launch
   `build-all.bat` detached.
4. On every loop, publish the first line of `C:\A\status.txt` as a guest attribute.

Saving the id before launching is the important ordering. The reverse would re-run the build on
every restart after a crash.

---

## 4. Endpoints on the Cloud Function

All take a shared secret header. All return JSON.

| Endpoint | Does | Notes |
|----------|------|-------|
| `GET /status` | Instance state, external IP, current build phase, docker tag | One `instances.get` plus guest attributes |
| `POST /start` | Starts the VM | Must return the **stockout** case distinctly, not as a generic failure |
| `POST /stop` | Stops the VM | Refuse while a build is running unless `force` is passed |
| `POST /build` | Writes `build-request` metadata | **Pre-checks the registry guard first** and returns the tag list when full |
| `GET /registry` | Lists Edgegap registry tags and which one is live | Read-only, so the panel can show why a build is blocked |

The registry pre-check matters. Today a full registry makes the build stop one second in, which
reads as a mysterious instant failure. The panel must name the reason and list the tags, since
deleting one needs a human in the Edgegap portal (the push robot has no delete permission).

---

## 5. The Controls tab

- **VM card**: state, IP when running, uptime, with Start and Stop.
- **Build card**: current phase from `status.txt`, the docker tag, elapsed time, and a Build button.
- **Registry card**: image count against the limit of 8, the tag list, which tag is live, and a
  warning when it is full.
- Every action that costs money or changes what players get goes through a confirm dialog naming
  exactly what will happen.

---

## 6. Security

- The shared secret lives in Vercel as a server-only env var and in the function's config.
- The route handler verifies the caller's Firebase ID token **server side** before it calls the
  function. The existing client-side allowlist decides what renders; it must not be what authorises
  a build.
- Consider a separate, narrower allowlist for Controls than for the kanban. A build button pushes
  to Steam and repoints Edgegap, which is not the same privilege as moving a card.

---

## 7. Work items

| # | Item | Where |
|---|------|-------|
| B1 | Split the function into routed endpoints, keeping the scheduled stockout behaviour intact | `infra/vm-stockout-watcher/main.py` |
| B2 | Registry read + guard pre-check | same |
| B3 | Metadata write for build requests | same |
| B4 | Poller script + scheduled task at boot; delete the stale `UE5Build` task | VM, `C:\A\Scripts\` |
| B5 | Guest attribute publishing of build phase | poller |
| B6 | Route handlers with Firebase token verification | `repos/arcas-admin/app/api/controls/` |
| B7 | Controls tab UI with confirms and polling | `repos/arcas-admin/components/` |
| B8 | Secrets into Vercel and the function config | deploy |

Rough effort: a day and a half to two days.

---

## 8. Open questions

- **Q1.** Should Controls have a narrower allowlist than the kanban? Leaning yes.
- **Q2.** Should the panel expose the client-only build, or only the full pipeline? Leaning full
  only. `build.bat` alone ships a client against a stale server, which is a trap worth removing.
- **Q3.** Should Stop be automatic after a successful build, given the VM costs money while idle?
- **Q4.** Keep the Telegram messages when a build is started from the panel, or would that double
  up with the panel already showing status?

---

## 9. Risks

- 🔴 **A web button that spends money and overwrites what players download.** Confirms and a
  narrower allowlist are the mitigation, not optional polish.
- 🟡 **The registry fills after a couple of builds** and only a human can clear it. The panel should
  make that obvious rather than letting it look like a bug.
- 🟡 **Starting the VM can fail on stockout** in `europe-west6-b`, which has a long history of it.
  The panel must say so honestly rather than spin.
- 🟡 **Guest attributes must be enabled** on the instance for the status channel to work. Check
  before relying on it, and fall back to reporting only the instance state if not.
