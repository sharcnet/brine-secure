# Primer: secure grant-review VM with per-reviewer containers for brine

**Audience:** an admin, or a Claude Code session on an admin's laptop, with access to the
OpenStack project and (later) to the VM. Read this whole document before doing anything.
The scripts and config files in this folder are the build; this primer explains them, lists
what to verify, and holds the acceptance tests.

> **Revision 2026-11-10 (for the human, not the build session).** Changes from the first draft:
> - Admins pre-load each reviewer's applications. Reviewers never upload, and sftp is read-only.
> - A login is only switched on after a second person checks the loaded files.
> - nginx forwards only two exact paths, refuses any odd-looking URL, and drops all client
>   headers.
> - The LiteLLM key no longer appears in any process's command line (`add-reviewer` used
>   `sed`, and key creation used `curl -H`).
> - Keys use opaque names and are bound to a LiteLLM team, with a budget, rate limits and an
>   expiry date.
> - New controls: per-reviewer disk quotas, a size-limited `/tmp`, fail2ban, MaxAuthTries 3,
>   `DisableForwarding`, and admin SSH limited to allowlisted addresses (pam_access).
> - A list of the settings brine needs, now shared as `../BRINE-REQUIREMENTS.md`.
> - §11 grew from 22 to 56 tests, including a canary test for content logging.
>
> **Revision 2026-11-10b:** moved into `sharcnet/brine-secure` as a second deployment. The
> inline code became real files (`review`, `terraform/`, `image/`, `vm/`). Findings from
> `../SECURITY-REVIEW.md` are folded in:
> - brine's shared IP (Plausible)
> - pass-through routes
> - unpinned npm dependencies: now a digest-pinned base image and `npm ci` from a lockfile
> - the image is built off the VM, so egress never reopens once applications are loaded
> - config drive instead of the metadata service
> - the host key is pinned from the console log
> - the OpenStack project is the trust boundary
> - brine's terms
>
> The security sign-off document is https://claude.ai/artifact/4eesUymPrNMEbpVyeMMxi7.

---

## 0. How to work through this primer

- Work phase by phase. At the end of each phase, run that phase's checks and show the
  human the output before moving on.
- **Collect the inputs in §2 from the human first.** Do not invent hostnames, IPs, CIDRs,
  flavours or usernames.
- **Ask before anything irreversible or outward-facing:** creating or deleting OpenStack
  resources, changing security groups, creating LiteLLM keys, adding real reviewer accounts,
  loading applications, activating a reviewer, deleting data.
- **Never write secrets** (LiteLLM keys, OpenStack credentials) into this repo, Terraform
  state, user data, your shell history, command arguments that show up in `ps`, or chat
  output. Pass keys through files
  with mode 0600. Build files that contain keys with shell built-ins (`printf`, parameter
  expansion), never with `sed`, `echo` in a subshell or `curl -H` on the command line.
- **Application content never leaves the VM.** Don't `cat`, `head` or `pdftotext` a real
  application, from your session or as root on the host. Test with `sample.pdf` only.
- **Verify, don't assume.** Some details below come from memory of tools that change quickly.
  Anything marked **[VERIFY]** must be checked against the installed version (`--help`,
  man page or upstream README) before you rely on it. If reality differs, adapt, and tell
  the human what you changed.
- Don't lock yourself out. Admin SSH access must stay outside the `reviewers` restrictions.
  Keep a second admin session open while you change `sshd_config` or PAM, and run `sshd -t`
  before every reload. The OpenStack console is the way back in if you do get locked out.
- If an acceptance test in §11 fails, stop and report it. Do not weaken a control to get
  a test to pass.

---

## 1. Goal and security model

About 50 grant reviewers each get an isolated container on a single OpenStack VM. Inside it
they use the **pi** coding agent with open-weight models served by **brine** (a LiteLLM,
OpenAI-compatible endpoint) to analyse confidential applications. Admins load each reviewer's
assigned applications before the reviewer gets access.

### Required properties

1. **The only network destination is brine.** The container itself has no network at all.
2. **pi can do local file operations and call brine, nothing else.**
3. **Reviewers are isolated from each other.** No shared files, processes or network, and no
   shared UID range.
4. **Reviewers never get a host shell.** SSH always lands in their own container.
5. **Minimal tooling** in the container: no compilers, curl/wget, git, python, ssh client,
   package installs or sudo.
6. **Reviewers never see the brine API key.** nginx adds it outside the container, and each
   reviewer gets their own LiteLLM key so usage can be attributed.
7. **Reviewers can't upload, and can't change the originals.** Applications are loaded by
   admins from the assignment list into a root-owned, read-only `~/originals`. File transfer
   is download-only.
8. **No application content is logged**, on the VM or on brine. Logs hold metadata only.

### Architecture

```
reviewer laptop                          admin laptop (allowlisted address)
   │ ssh; sftp download-only                │ ssh (admin, not a reviewer)
   │ (public key only, no forwarding)       │ load-applications
   ▼                                        ▼
┌───────────────────────────── VM (Ubuntu 24.04) ──────────────────────────────┐
│ sshd ── Match Group reviewers ── ForceCommand ──► sudo enter-review          │
│                                                     │ podman exec            │
│  ┌──────── container review-alice (network=none) ───▼─────────────────────┐  │
│  │ user "reviewer": bash, pi, pdftotext, rg, fd, nano                     │  │
│  │ sftp-server -R (read-only: download, never upload)                     │  │
│  │ user "fwd" (PID 1): node forwarder 127.0.0.1:4000 ──┐                  │  │
│  │ /home/reviewer           ◄─ /srv/review/homes/alice │                  │  │
│  │ /home/reviewer/originals ◄─ /srv/review/originals/  │                  │  │
│  │                             alice (ro, root-owned)  │                  │  │
│  │ /run/brine/brine.sock ◄──────── bind mount ─────────┘                  │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                    │ unix socket (one per reviewer)          │
│  nginx: listens ONLY on /run/brine-proxy/<user>/brine.sock                   │
│         exact-path allowlist, client headers dropped, injects the key        │
└────────────────────────────────────┼─────────────────────────────────────────┘
                                     │ HTTPS (OpenStack SG: egress to brine only)
                                     ▼
                              brine (LiteLLM, review team)
```

Why this design:

- **`--network=none`** means the kernel gives the container only a loopback interface. You
  don't need firewall rules to stop it reaching the internet, and it can't reach other
  containers. Its only way out is a Unix socket that the host bind-mounts in, one per
  reviewer.
- **The nginx proxy** on that socket:
  - only talks to brine and only forwards two exact paths;
  - refuses any URL that isn't in its plain form;
  - drops every header the client sent;
  - adds the reviewer's own key.

  Each socket is mounted into one reviewer's container only, so identity can't be spoofed
  from inside a container.
- **A tiny Node forwarder** inside the container turns `127.0.0.1:4000` into the Unix socket,
  because pi needs an HTTP base URL. Node is already there for pi. The forwarder runs as a
  separate user so the reviewer can't kill it.
- **Rootful Podman with `UserNS=auto`** gives every container its own unprivileged host UID
  range. Reviewers can't run podman themselves. A root-owned script, reached through a single
  sudo rule, picks the container from `SUDO_USER`, so nobody can pick someone else's.
- **Admin-loaded, read-only originals.** Applications are copied from the assignment list
  into a root-owned directory that is mounted read-only. That removes uploads as an attack
  path and stops pi (or an injected instruction) altering the source files. A wrong copy
  would be a confidentiality breach, so loading is scripted, recorded in a checksum
  manifest, and checked by a second person before the reviewer's login is switched on.
- **pi's own tool restrictions are not the security boundary.** pi can run shell commands in
  some modes, and extensions are code. The container is the boundary. Restricting pi's tools
  still matters, as a defence against **prompt injection hidden in applications**: with no
  bash tool, an injected instruction can at worst read or edit files in that reviewer's own
  workspace.
- **Defence in depth:**
  - read-only root filesystem, all capabilities dropped, `no-new-privileges`, setuid bits
    stripped
  - the default seccomp profile
  - resource limits and a disk quota
  - `noexec` on the data volume
  - an OpenStack security group with egress only to brine (plus DNS, NTP and the mirror for
    the host itself)
  - the image built off the VM, from a digest-pinned base and a lockfile
  - a host nftables rule that drops any network traffic from reviewer accounts
  - SSH forwarding disabled

  gVisor is an optional extra (§10).

---

## 2. Inputs to collect from the human before starting

| Item | Example |
|---|---|
| OpenStack credentials (openrc / clouds.yaml), project, network name | `def-sharcnet-review`, `def-net` |
| **Who has a role in that project** (only the review admins; anyone with a role can snapshot the VM or open its console) | |
| Image, flavour, admin keypair name | Ubuntu 24.04, 16 vCPU / 32 GB, `admin-key` |
| Encrypted Cinder volume type available? (name) | `LUKS` |
| CIDR(s) allowed to SSH in (reviewers) | campus/VPN ranges |
| Admin address(es) allowed to log in as an admin (narrower than the above) | admin VPN range |
| brine base URL, its IP(s), path prefix if any, and whether it uses an internal CA | `https://brine.example.ca` |
| Models to expose: LiteLLM model names, context window, max output tokens | |
| How LiteLLM per-reviewer keys get created (the brine admin creates them, or gives you a credential limited to the review team) | |
| LiteLLM team for the review, and per-key budget / rpm / tpm | |
| Reviewer list: username plus SSH public key for each | |
| **Assignment list** (which application goes to which reviewer) and how applications reach the admin | from the competition owner |
| Who does the second-person check of each reviewer's manifest | |
| Per-reviewer disk quota | 2 GB |
| Reviewers get a **bash shell** in the container (default) or **pi only**? | |
| Data retention date (when containers and data are destroyed) | end of competition |
| Log-retention period (sshd, nginx, LiteLLM metadata) | |
| DNS servers (must match the subnet's), NTP servers, and package mirror the VM may use | |
| A Linux x86_64 host with podman and internet access, to build the image | build VM or CI |

---

## 3. The files and how they fit

Everything below is in `grant-review/`. The scripts are the build. This primer explains what
they do and why, and lists what to verify.

| Path | Runs where | What it does |
|---|---|---|
| `review` | Admin laptop | One CLI for everything below. Reads `review.env` |
| `terraform/` | Laptop → OpenStack | VM, encrypted data volume, security groups, floating IP |
| `image/` | A Linux x86_64 build host | Builds the reviewer container image and saves it as a tarball |
| `vm/configure` | VM, as root | Installs packages and every config file; safe to run again |
| `vm/sbin/` | VM, as root | `enter-review` and the admin scripts |
| `vm/files/` | VM | nginx, sshd, sudoers, nftables, fail2ban, pam_access, Quadlet template, pi `models.json` |
| `../BRINE-REQUIREMENTS.md` | brine | What brine's admins must set, shared with the sandbox deployment |

Secrets never sit in this repo, in Terraform state, in user data or in a command line:

- The LiteLLM credential that mints keys stays on the laptop, as a 0600 header file.
- Each new reviewer key is held in a shell variable and piped to `add-reviewer` over SSH.
- `add-reviewer` writes the key into nginx with shell built-ins only.

---

## 4. Phase 1: the VM (`review apply`)

`terraform/main.tf` creates:

- **Security group `grant-review-sg`** with the default rules deleted.
  - Ingress: TCP 22 from `reviewer_cidrs` and `admin_cidrs`.
  - Egress: TCP 443 to brine's IP(s), DNS to `dns_cidrs`, NTP to `ntp_cidrs`, and TCP 80/443
    to `mirror_cidrs`.
  - `dns_cidrs` must match the subnet's DNS servers, because that's what the VM uses.
- **Security group `grant-review-setup`** with open egress. It's attached only while
  `setup_egress = true`, which is for first setup only (§6).
- **Server:** Ubuntu 24.04 with the admin keypair. `config_drive = true`, so cloud-init never
  needs the metadata service. User data holds no secrets, and swap is off.
  - `ignore_changes = [image_id]`, so a newer Ubuntu image never rebuilds a VM that holds data.
- **Data volume** of `volume_type`, which must be an encrypted type. It has
  `prevent_destroy`, so retention (§12) is the only way it goes.
- **Floating IP**, with the same router-gateway check as the sandbox.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in
cp review.env.example review.env                                   # fill in
terraform -chdir=terraform init
./review apply            # resolves brine's IP, then shows the plan for approval
./review pin-hostkey      # reads the host key from the console log; no trust-on-first-use
```

`review apply` always applies with `setup_egress = false`. It then asks OpenStack whether the
port carries only the review group, prints that group's egress rules, and lists the open
connections on the VM.

**[VERIFY]** whether this cloud's volume type is really encrypted:
`openstack volume show <id> -c encrypted`.

**Who's in the OpenStack project matters.** Anyone with a role in it can:

- snapshot the VM or the volume
- attach a security group that opens egress
- open the console

That gets them the applications. Use a project whose only members are the review admins.
Give application credentials an expiry date.

---

## 5. Phase 2: data volume and configuration (`review data-volume`, `review deploy`)

```bash
terraform -chdir=terraform output volume_device   # e.g. /dev/vdb [VERIFY] on the VM with lsblk
./review data-volume /dev/vdb
./review deploy
```

`setup-data-volume`:

- refuses any device that already holds a filesystem or partition table;
- formats it with `-O quota,project` **[VERIFY]**;
- mounts it at `/srv/review` with `nodev,nosuid,noexec,prjquota`, in fstab by UUID.

`configure` refuses to run unless that mount and those options are present and swap is off.
It then converges the VM:

1. Installs `podman nginx nftables uidmap tini fail2ban quota jq unattended-upgrades`.
2. Sets up subordinate IDs for `UserNS=auto` and creates the `reviewers` group.
3. Creates the directories (homes, originals, staging, manifests, key aliases).
4. Installs `enter-review` (0755) and the admin scripts (0700) in `/usr/local/sbin`.
5. Sets up nginx:
   - removes the default site;
   - installs the brine snippet, with brine's name as both Host and SNI;
   - sets the metadata-only log format;
   - installs the per-reviewer template (0600).
6. Installs sudoers (checked with `visudo`) and the sshd drop-in (checked with `sshd -t`).
7. Sets up nftables (drops every packet from the reviewers group), then fail2ban. fail2ban
   comes second because restarting nftables flushes the ruleset.
8. Installs pi's `models.json` (dummy key only) and the Quadlet template, with the container
   limits filled in.

`./review deploy --admin-access` also turns on pam_access, so admins can only log in from
`ADMIN_CIDRS` or the console. **Keep a second admin session open** the first time, and check
that a new admin login still works before you close it. **[VERIFY]** that a reviewer from any
approved CIDR still gets in.

---

## 6. Phase 3: the container image (`image/build`, `review image`)

The image is built **off the review VM**, on a Linux x86_64 host with podman and internet
access, such as a build VM or CI. The review VM then never needs open egress once
applications are on it. The one exception is the very first build, which can run on the
review VM while `setup_egress` is on, before anything is loaded.

`image/Containerfile`:

- **Pinning:** the Node base image is pinned by digest. pi is installed with
  `npm ci --ignore-scripts` from the committed `package-lock.json`, so every transitive
  dependency is fixed and no install script runs.
  - **[VERIFY]** pi still works without install scripts. `koffi`, `protobufjs` and
    `@google/genai` declare one.
- **Contents:** bash, coreutils, less, nano, poppler-utils, ripgrep and fd. ripgrep and fd are
  installed so pi never tries to download them **[VERIFY]**.
- **Removed:** npm, npx, corepack, apt and dpkg, plus every setuid bit.
- **Users:** `reviewer` (uid 1000) and `fwd` (uid 1001).
- **Runtime:** PID 1 is tini running `brine-forward.js` as `fwd`. It maps 127.0.0.1:4000 to
  `/run/brine/brine.sock`, because pi needs an HTTP base URL.
- **pi wrapper:** `pi-review` runs pi with `--tools read,write,edit,grep,find,ls`, so there is
  no bash tool **[VERIFY]** the flag with `pi --help`.

```bash
# on the build host
grant-review/image/build                 # refuses if curl, python3, git, npm, sudo... are present
# on the laptop
./review image brine-review-YYYYMMDD.tar # checks the sha256 on the VM, loads it, tags :current
```

To update pi, bump the version in `image/package.json` and regenerate the lockfile with
`npm install --package-lock-only --ignore-scripts`. Review the diff, then rebuild.

**[VERIFY]** against pi's docs:

- the `models.json` schema
- whether pi makes startup calls that need turning off (the image sets `PI_OFFLINE=1`)
- which API paths pi calls (watch the nginx log during test 33)

If pi needs anything beyond `/v1/models` and `/v1/chat/completions`, add that exact path to
`vm/files/nginx-user.conf.tmpl` and tell the human.

---

## 7. Phase 4: the model path (nginx)

`vm/files/brine-proxy.conf` and `nginx-user.conf.tmpl`:

- **Listening:** one server block per reviewer, listening only on
  `/run/brine-proxy/<user>/brine.sock`. No TCP listener.
- **Two exact paths:** `location = /v1/chat/completions` and `location = /v1/models`, plus
  `location / { return 403; }`.
- **Plain URLs only:** any URL containing `..`, `%`, `//` or `?` is refused. That way the path
  nginx matches is exactly the path brine receives.
- **Client headers dropped** (`proxy_pass_request_headers off`). Only Host, Content-Type,
  Accept and the reviewer's Authorization are set **[VERIFY]**. Test 25 checks that bodies and
  streaming still work.
- **Always brine's own name:** Host and SNI are always brine's name. Even though brine's IP is
  shared with other sites (BRINE-REQUIREMENTS item 1), this proxy can only ever reach brine.
- **No body buffering,** so bodies never land in nginx temp files on the root disk.
- **Metadata-only log:** time, method, path, status, sizes and timing.

nginx creates Unix sockets with mode 0666 in a root-owned 0755 directory. Each directory is
bind-mounted only into its owner's container. A host process could connect to any of them,
but reviewers never get a host shell, and the reviewer group's packets are dropped anyway. This
is an accepted residual risk. **[VERIFY]** the socket mode once it exists.

---

## 8. Phase 5: SSH entry (`enter-review`, sudoers, sshd, nftables)

- **sshd (`Match Group reviewers`):**
  - public key only
  - `ForceCommand sudo -n /usr/local/sbin/enter-review`
  - `DisableForwarding` plus every forwarding, tunnel and user-rc option off
  - `MaxAuthTries 3` and `PermitRootLogin no` globally

  The sftp `Subsystem` line stays in the main `sshd_config`. `configure` checks that it's there.
- **sudoers:** `%reviewers ALL=(root) NOPASSWD: /usr/local/sbin/enter-review ""`, where `""`
  means no arguments. `SSH_ORIGINAL_COMMAND` is kept.
- **`enter-review`** picks the container from `SUDO_USER` only. It runs:
  - an interactive shell (or pi only, if `REVIEWER_SHELL=pi`) with `podman exec`, or
  - `sftp-server -R` (read-only).

  It refuses every other remote command, including legacy `scp -O`. **[VERIFY]** what
  `SSH_ORIGINAL_COMMAND` holds for an sftp subsystem request on this OpenSSH version.
- **pi-only mode** is a usability choice, not a stronger boundary. pi can run shell commands
  from its editor **[VERIFY]**, and extensions are code.
- **nftables:** `meta skgid <reviewers> drop` on output. This also covers the metadata service.
- **fail2ban** sshd jail, with the admin addresses in `ignoreip`.

A reviewer's key starts as `/etc/ssh/authorized_keys/<user>.pending`, which sshd ignores.
`activate-reviewer` renames it.

---

## 9. Phase 6: reviewers and applications

```bash
./review add alice alice.pub          # mints the key on brine, creates everything, login OFF
./review stage P123.pdf P456.pdf      # streamed onto the encrypted volume's staging dir
./review load assignment.csv          # username,filename lines from the competition owner
./review manifest alice               # second person compares this with the assignment list
./review activate alice "J. Smith"    # login ON; records who checked
```

- **`add-reviewer`** (VM):
  - creates the user with primary group `reviewers` and no password;
  - sets up the home on the data volume, a project quota of `QUOTA_GB`, and root-owned 0555
    `originals`;
  - writes the tmpfiles entry for the socket directory and the nginx server block (0600, key
    filled with shell built-ins);
  - starts the Quadlet unit `review-<user>`.

  The key arrives on stdin. The opaque alias `gr-<8 hex>` is recorded in
  `/etc/brine-review/keys/aliases`.
- **Keys** (laptop, `review add`):
  - Minted by `POST /key/generate` with `team_id`, `key_alias`, `models`, `duration`,
    `max_budget`, `rpm_limit` and `tpm_limit` from `review.env` **[VERIFY]** the field names
    on brine's LiteLLM version.
  - The minting credential must be limited to the review team. **Never use the LiteLLM master
    key.**
  - If `add-reviewer` fails, the new key is revoked straight away.
- **`load-applications`:**
  - checks every line first: the reviewer exists, the filename is plain, the staged file is
    a regular file, no duplicates, nothing already loaded;
  - then copies with `install -m 0444` and writes a sha256 manifest per reviewer.

  It never opens an application. `review stage` streams files straight into
  `/srv/review/staging`, so no copy lands on the root disk.
- **The second-person check:** a second person (from §2) compares `review manifest <user>`
  with that reviewer's lines in the assignment list. Record who checked and when. **This is a
  procedure, not a technical control.** Admins share one account on the VM, and `checked-by`
  is free text in a log line, so nothing stops one admin loading, "checking" and activating
  alone. Treat it like any other two-person rule: it works only if people follow it.
  `activate-reviewer` re-checks the manifest before switching the login on.
- **Staging is emptied by `load-applications` itself.** Once every copy and manifest is
  written, it deletes the staged copies it loaded, and the assignment list if it was sent
  with `review load`. It warns if anything else is left in staging.
- **`unload-application`:** for a conflict of interest during the review. It removes the file
  and regenerates the manifest. The reviewer's own notes stay; ask the competition owner.
- **`remove-reviewer --purge-data`** (`review remove`):
  - turns the login off first, then removes the container, nginx config, socket and user;
  - with `--purge-data`, also deletes the home, originals, manifest and quota;
  - matches names exactly, so `testa` never touches `testa2`;
  - finally revokes the key by alias **[VERIFY]** that `/key/delete` accepts `key_aliases`.

### 9.1 Settings brine needs

These moved to [`../BRINE-REQUIREMENTS.md`](../BRINE-REQUIREMENTS.md). That list is shared
with the single-user sandbox, so the brine admins answer one list once.

### 9.2 Updating the image

1. Build on the build host (`image/build`). Never reopen egress on the review VM once
   applications are on it. `review setup-egress on` refuses if any file is in originals or
   staging.
2. `./review image <tar>`
3. In a scheduled window: `review ssh sudo systemctl restart 'review-*.service'`. This drops
   reviewers' sessions.
4. Run the whole of §11 again.

---

## 10. Phase 7 (optional): gVisor for stronger isolation

All containers share the VM's kernel, so a kernel exploit is the main remaining path from
one reviewer to another. gVisor (`runsc`) adds a user-space kernel in between. Try it with
two test reviewers before rolling it out:

- Install `runsc` (while `setup_egress` is on, before any data, or from the mirror). Register
  it as a Podman runtime in `/etc/containers/containers.conf` under `[engine.runtimes]`.
- The container must be able to connect to the host Unix socket, which needs runsc's
  host-UDS option (e.g. `--host-uds=open`). **[VERIFY]** the flag, and how to pass runtime
  flags from Quadlet (`GlobalArgs=`/`PodmanArgs=`) on this Podman version.
- Check that `UserNS=auto`, `podman exec`, the sftp path and the forwarder all still work.
  Run the whole of §11 under gVisor.
- If anything doesn't work, don't force it. Leave gVisor off and tell the human, because the
  rest of the design is still sound.

---

## 11. Acceptance tests

Create three test reviewers, `testa`, `testb` and `testa2`, each with their own SSH key and
LiteLLM key. `testa2` is there on purpose: its name starts with another reviewer's name, which
catches prefix and glob bugs in socket, home and container paths. Load `sample.pdf` (and a
`sample.txt`) for each with `review stage` and `review load`, check the manifests, and activate them (§9).

`acceptance.sh` runs the suite from the laptop and writes a dated log to `test-logs/` with
the result and output of every test: PASS, FAIL, MANUAL (needs a person, often a brine admin;
the log says what to check) or SKIP. Put the test reviewers' SSH private keys in
`test-keys/testa`, `test-keys/testb` and `test-keys/testa2` (gitignored). It plants and removes
the canaries itself.

```bash
./acceptance.sh                    # everything safe to repeat
./acceptance.sh --with-resource    # adds 35-37 (fork bomb, memory hog, disk fill)
./acceptance.sh --with-lifecycle   # adds 52 and 54: revokes testa's key and removes testa
./acceptance.sh --only 23,24,25    # a subset
```

Set `PENDING_USER` to a test reviewer who is added but not activated, to cover the last part of
test 51. Tests 10, 27, 49, 50 and 53 are always MANUAL; 26 is automated on the VM side, with a
brine-side confirmation. Run the whole suite:

- before go-live
- after every image rebuild (§9.2)
- after any upgrade to sshd, nginx, Podman, LiteLLM or the brine model servers
- after every reboot

Unless a test says otherwise, run it from the laptop as `testa`, or inside `testa`'s container.

**Setup canaries (admin, on the host):** put a file containing `HOST-CANARY-<random>` in
`/root/` and a file containing `TESTB-CANARY-<random>` in `/srv/review/homes/testb/`. If either
string ever shows up in `testa`'s session, the test that showed it failed.

### 11.1 SSH entry

| # | Test | Expected |
|---|---|---|
| 1 | `ssh testa@VM` | Prompt `review:~$`; `id` shows `reviewer` |
| 2 | `ssh testa@VM whoami`; `ssh -t testa@VM bash`; `ssh -s testa@VM foo` | All refused ("remote commands are not allowed" / subsystem request failed) |
| 3 | `ssh -N -L 9999:BRINE_HOST:443 testa@VM`, then `curl localhost:9999` from the laptop. Also try `-D 1080`, `-R 9999:localhost:22`, `-W BRINE_HOST:443`, `-w 0:0` and `-X` | All refused |
| 4 | `ssh -A testa@VM`, then inside: `echo $SSH_AUTH_SOCK` | Empty; no agent socket in the container |
| 5 | `LC_EVIL='$(id)' ssh -o SendEnv=LC_EVIL testa@VM`, then `echo $LC_EVIL` | Empty |
| 6 | `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive testa@VM` | `Permission denied (publickey)` |
| 7 | Legacy scp: `scp -O testa@VM:originals/sample.pdf .` | Fails (it needs a remote command) |
| 8 | On the host as admin: `sudo sshd -T -C user=testa,host=x,addr=203.0.113.1 \| grep -Ei 'passwordauth\|kbdinteractive\|permitroot\|forwarding\|permittunnel\|permituser\|maxauthtries\|forcecommand'` | `passwordauthentication no`, `kbdinteractiveauthentication no`, `permitrootlogin no`, `disableforwarding yes`, `allowtcpforwarding no`, `allowagentforwarding no`, `allowstreamlocalforwarding no`, `x11forwarding no`, `permittunnel no`, `permituserrc no`, `permituserenvironment no`, `maxauthtries 3`, the expected `forcecommand` |
| 9 | On the host as admin: `sudo fail2ban-client status sshd` | Jail is active |
| 10 | An admin login from an address outside the admin allowlist | Refused (pam_access) |

### 11.2 Container isolation

| # | Test | Expected |
|---|---|---|
| 11 | `which curl wget python3 git ssh apt apt-get dpkg npm sudo gcc` | Nothing found. This is an extra layer only: `node` is a full interpreter. The real controls are the network namespace and the read-only root |
| 12 | `node -e "require('https').get('https://1.1.1.1',r=>console.log(r.statusCode)).on('error',e=>console.log('blocked',e.code))"`. Repeat with `https://example.com`, `https://[2606:4700:4700::1111]` and `http://169.254.169.254/` | `blocked` every time (ENETUNREACH / EAI_AGAIN) |
| 13 | UDP: `node -e "const s=require('dgram').createSocket('udp4');s.send('x',53,'1.1.1.1',e=>{console.log(e?'blocked '+e.code:'SENT');s.close()})"` | `blocked ENETUNREACH` |
| 14 | `cat /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6` | Only one listener: `0100007F:0FA0` (127.0.0.1:4000, the forwarder) |
| 15 | `ls /run/brine`; `ls /home`; `cat /etc/passwd`; `cat /proc/mounts`; `find / -name '*testb*' -o -name '*testa2*' 2>/dev/null` | Only your own socket and home. No other reviewer's name appears anywhere |
| 16 | `grep -rF --exclude-dir=proc --exclude-dir=sys CANARY / 2>/dev/null` | No matches |
| 17 | `touch /usr/bin/x`; `touch ~/x`; `touch /tmp/x`; `grep ' /tmp ' /proc/mounts`; `cp /bin/ls ~/ls && ~/ls` | Read-only fs; ok; ok; `/tmp` is a 256 MB `tmpfs`; the copied binary won't run (noexec) |
| 18 | `ls -l ~/originals`; `touch ~/originals/x`; `rm ~/originals/sample.pdf` | Files are 0444, not owned by `reviewer`; both changes refused |
| 19 | `grep -E 'CapEff\|NoNewPrivs\|Seccomp' /proc/self/status`; `cat /proc/self/uid_map`; `find / -xdev -perm /6000 -type f 2>/dev/null` | `CapEff: 0…0`, `NoNewPrivs: 1`, `Seccomp: 2`. The uid map does not map to host uid 0. No setuid or setgid files |
| 20 | `ls /proc \| grep -E '^[0-9]+$'` | Only this container's few processes |
| 21 | `pkill -f brine-forward`; `kill 1` | Not permitted; test 23 still works |
| 22 | `grep -rs 'sk-' ~ /etc /proc/self/environ; env \| grep -i key`; `cat ~/.pi/agent/models.json` | No real key anywhere; `models.json` holds only the dummy `injected-by-proxy` |

### 11.3 Model access

| # | Test | Expected |
|---|---|---|
| 23 | `node -e "fetch('http://127.0.0.1:4000/v1/models').then(r=>r.text()).then(console.log)"` | The brine model list, even though the container has no key (nginx adds it) |
| 24 | Allowlist and path tricks. This uses `http.get` rather than `fetch` because `fetch` cleans up `..` before sending:<br>`node -e "for (const p of ['/key/info','/key/generate','/user/info','/spend/logs','/model/info','/routes','/openapi.json','/ui','/health','/v1/embeddings','/v1/completions','/models','/v1/../key/info','//key/info','/key/info/','/%6Bey/info','/v1/models/../../key/info','/v1/models?x=1','/v1/%6Dodels']) require('http').get({host:'127.0.0.1',port:4000,path:p},r=>console.log(r.statusCode,p)).on('error',e=>console.log('err',e.code,p))"` | `403` for every path |
| 25 | A chat request with forged headers: `Authorization: Bearer sk-bogus`, `x-litellm-api-key: sk-bogus`, `x-litellm-tags: forged`, using `fetch` with `stream: true` | The request works and streams. brine's logs attribute it to testa's key and show no `forged` tag. This shows client headers are dropped, and bodies and streaming still work |
| 26 | A chat request whose body adds `"api_base":"https://example.com"`, `"base_url":"https://example.com"`, `"langfuse_host":"https://example.com"` and `"metadata":{"callbacks":["langfuse"]}` | Refused (4xx) or ignored. A brine admin confirms brine made no outbound connection and wrote no extra log |
| 27 | A brine admin looks up testa's key | Team = the review team; `models`, `max_budget`, `rpm_limit`/`tpm_limit` set; expiry no later than the retention date; alias is opaque (`gr-…`) |

### 11.4 Files and tools

| # | Test | Expected |
|---|---|---|
| 28 | `sftp testa@VM`: `ls originals`, `get originals/sample.pdf`, then `put x.txt`, `put x.txt originals/`, `mkdir d`, `rm originals/sample.pdf`. Also `scp testa@VM:originals/sample.pdf .` and `scp x.txt testa@VM:` | Downloads work; every upload, mkdir and rm is refused |
| 29 | On the host as admin: `cd /srv/review/originals/testa && sha256sum -c /srv/review/manifests/testa.sha256`; `stat -c '%U %a %n' *`; compare with the assignment list | All `OK`; exactly the assigned files; `root 444` |
| 30 | In sftp: `cd /`, `ls`, `ls /home`, `ls /run/brine`, `get /root/*`, `get /srv/review/homes/testb/*` | You see only the container's view, never the host's files or testb's. No canary is retrieved |
| 31 | Inside the container: `ln -s /root ~/r; ln -s /srv/review/homes/testb ~/b`. Then in sftp: `ls r`, `ls b`, `get -r r`, `get -r b` | Fails, or shows the container's own (empty) paths. No canary is retrieved |
| 32 | `pdftotext ~/originals/sample.pdf ~/sample.txt && head ~/sample.txt` | Text output |
| 33 | `pi -p "Summarise the main aims in ~/originals/sample.txt"` using a brine model. Meanwhile, as admin, watch `/var/log/nginx/brine-testa.access.log` | An answer that uses the file. The log shows only `/v1/models` and `/v1/chat/completions` |
| 34 | In pi, ask it to "run `ls /` with bash" | It can't; there is no bash tool |

### 11.5 Resource isolation

Run each of these as `testa` while `testb` repeats test 23 in a loop. Test 37 assumes the
fork-bomb and memory-hog processes are gone (log out of `testa` first if needed).

| # | Test | Expected |
|---|---|---|
| 35 | Fork bomb: `node -e "const {spawn}=require('child_process');for(;;)spawn(process.execPath,['-e','setTimeout(()=>{},6e5)'])"` | Hits the pids limit (EAGAIN). testb is unaffected |
| 36 | Memory hog: `node -e "const a=[];for(;;)a.push(Buffer.alloc(1e8,1))"` | Killed at the memory limit, inside testa's container only. testb is unaffected |
| 37 | Disk fill: `node -e "const fs=require('fs'),f=fs.openSync(process.env.HOME+'/big','w'),b=Buffer.alloc(1<<26,1);for(;;)fs.writeSync(f,b)"`, then `rm ~/big` | Stops with EDQUOT at testa's quota. testb can still `touch ~/x` |

### 11.6 Host and network (admin, on the host)

| # | Test | Expected |
|---|---|---|
| 38 | `sudo -l -U testa` | Only `enter-review` |
| 39 | `stat -c '%U %a %n' /usr/local/sbin/enter-review /usr/local/sbin /usr/local /usr` | All owned by root; none group- or world-writable |
| 40 | `sudo -u testa sudo -n /usr/local/sbin/enter-review testb` | Refused by sudo (no arguments allowed) |
| 41 | `ls -ld /run/brine-proxy/*`; `podman inspect review-testa --format '{{range .Mounts}}{{.Source}} {{end}}'` | Each directory is root 0755 and holds only `brine.sock`. testa's container mounts only `/run/brine-proxy/testa`, `/srv/review/homes/testa`, `/srv/review/originals/testa` and `models.json` |
| 42 | `sudo -u testa curl -m5 https://BRINE_HOST`; `sudo -u testa curl -m5 http://169.254.169.254/` | Both fail (nftables drop) |
| 43 | `curl -s http://169.254.169.254/openstack/latest/user_data`, and the config drive (`blkid -L config-2`, mount read-only, read `openstack/latest/user_data`) | Contains no secrets |
| 44 | `curl -m5 https://example.com` | Blocked by the security group. `review check` shows only the review group on the port |
| 45 | `swapon --show`; `findmnt /srv/review`; from the laptop: `openstack volume show <data-volume> -c encrypted` | No swap. `nodev,nosuid,noexec,prjquota`. `encrypted: True` |
| 46 | `openstack volume snapshot list`; `openstack image list --private`; `ls /var/lib/nginx/body /var/lib/nginx/proxy` | No snapshots or images of the VM or data volume. nginx temp dirs empty |

### 11.7 No content is logged (canary)

This is the evidence for the Tri-agency sign-off (§12), so don't skip it.

| # | Test | Expected |
|---|---|---|
| 47 | As testa: `pi -p "Repeat exactly: PROMPT-CANARY-<random>"`. Then the admin loads a file containing `FILE-CANARY-<random>` for testa, and testa asks pi to summarise it | pi answers |
| 48 | On the VM: `sudo grep -rF CANARY /var/log /var/lib/nginx /etc /srv 2>/dev/null`; `sudo journalctl --since -1h \| grep -F CANARY` | Matches only in testa's own home (including `~/.pi/agent/sessions`) and originals. Nothing in any log |
| 49 | On the brine side: grep the LiteLLM logs, a dump of the LiteLLM database (including SpendLogs) and the model-server logs for both canaries | No matches |
| 50 | brine/LiteLLM logs | Requests attributed to testa's opaque key alias, with metadata only |

### 11.8 Lifecycle

| # | Test | Expected |
|---|---|---|
| 51 | `ssh testb@VM` and `ssh testa2@VM` while testa is connected; before `activate-reviewer`, `ssh` as a fourth test user | Each lands in its own container, never another reviewer's. testa2 sees nothing of testa. The not-yet-active user is refused |
| 52 | Revoke testa's LiteLLM key while testa is in a session | testa's next request fails (401) within a minute or two (LiteLLM caches keys briefly). testb is unaffected |
| 53 | Reboot the VM | Run the **entire** suite again, not just the functional tests. The usual failure is that things work again but the controls didn't come back |
| 54 | `remove-reviewer --purge-data testa` | testa's container, socket, home, originals, manifest and user are gone; the key is revoked; `ssh testa@VM` fails. **testa2 still works**: re-run tests 1, 23 and 28 as testa2 |

### 11.9 brine's shared IP and leftover connections

| # | Test | Expected |
|---|---|---|
| 55 | On the host as admin (not a reviewer): `curl -sk -m5 -H 'Host: anything' https://<brine IP>/` and `curl -sk -m5 --resolve x.example:443:<brine IP> https://x.example/` | No response from any site other than brine (BRINE-REQUIREMENTS item 1). Until that's fixed, record it as a residual risk: only a compromised host process could use it, since containers have no network and nginx always sends brine's name |
| 56 | `review check` after setup egress is turned off, and again after a reboot | Only the review group on the port; open connections are SSH and brine :443 only |

Then remove the remaining test reviewers with `--purge-data`, revoke their keys, and delete the
canary files.

---

## 12. Operations and confidentiality

- **Threat model:** the controls are built against four things:
  - a curious or malicious reviewer trying to reach other reviewers' files or the internet
  - prompt injection hidden in an application, steering pi
  - outside attackers on the SSH port
  - admin error when loading applications

  Reviewers are trusted with the applications assigned to them, and nothing more.
- **brine's terms of use** currently say not to send sensitive data. They must change (or
  this use be explicitly allowed) before go-live. See BRINE-REQUIREMENTS.
- **Tri-agency policy:** NSERC/SSHRC/CIHR guidance limits reviewers putting application
  content into generative AI tools. Before go-live, the human must confirm that this setup is
  acceptable for this competition. That isn't an engineering decision. Give the approver:
  - the data flow: the reviewer's container → nginx on the host → brine LiteLLM → brine model
    servers, with no third party
  - the §11.7 canary results, showing that no prompt or file content is logged anywhere in
    that chain

  Re-run §11.7 after any upgrade to LiteLLM or the model servers.
- **Model access:** reviewers never hold a LiteLLM key; nginx adds it. Each key belongs to the
  review team, has an opaque alias, a budget and rate limits, and expires by the retention
  date. nginx passes only two exact API paths and drops client headers.
- **Loading applications:** admins copy each reviewer's applications from the competition
  owner's assignment list into `~/originals` (root-owned, read-only). The copy produces a
  checksum manifest, and a second person checks it against the list before the reviewer is
  activated. Staging copies sit on the encrypted volume and are deleted once the loading is
  checked. The copy script never opens the files.
- **Data at rest:** homes, originals, manifests, staging and pi's session history are all on
  the encrypted Cinder volume. Containers' root filesystems are the read-only image; `/tmp`
  is tmpfs, and there is no swap. nginx doesn't buffer bodies to disk. Backups are off by
  default; if any are made, they're encrypted and covered by the same retention rule. Don't
  take snapshots or images of the VM or the volume.
- **Logs:** sshd auth logs, nginx access logs (`brine_meta` format), `brine-review` admin
  actions, and LiteLLM spend records, all metadata only. Never log request bodies, and keep
  prompt storage and callbacks off in LiteLLM. Delete these logs after the agreed
  log-retention period.
- **What counts as content:** applications, extracted text, reviewers' notes, and pi's
  transcripts in `~/.pi/agent/sessions`. All of it lives on the encrypted volume and is
  purged with the reviewer's data.
- **OpenStack project:** only the review admins have a role in it. Anyone with a role can
  snapshot the VM, attach a security group or open the console, so project membership is part
  of the trust boundary. Application credentials get an expiry date.
- **Access:**
  - Reviewers use SSH keys only.
  - Publish the host key fingerprint (from `review pin-hostkey`) through a separate channel.
  - Admin logins are allowed only from allowlisted addresses (pam_access).
  - fail2ban watches sshd.
- **Offboarding during the review** (conflict of interest, withdrawal or a lost key): for one
  application, `unload-application` the same day. For the whole reviewer,
  `remove-reviewer --purge-data` and revoke the key the same day. Issue a new account if
  needed; never reuse the old one.
- **Retention:** on the agreed date:
  1. Run `remove-reviewer --purge-data` for everyone, and revoke all keys (they also expire).
  2. Check that no snapshots, images or backups exist.
  3. Delete the data volume and confirm its encryption key is gone from Barbican. Ceph
     doesn't wipe deleted volumes, so deleting the key is what actually destroys the data.
  4. Delete the VM if it's no longer needed.

  Record the date each step was done.
- **Patching:**
  - The host updates through unattended-upgrades, via the mirror in `mirror_cidrs`.
  - The image is rebuilt via §9.2 (off the VM) at least monthly, and out of cycle for CVEs in poppler
    (`pdftotext` parses hostile PDFs), Node, pi or Podman.
  - Re-run §11 after every rebuild.
- **Prompt injection:** treat applications as untrusted input.
  - Keep the bash tool off.
  - `~/originals` is read-only, so pi can't change the source files.
  - Suggest one working folder per application. This lowers the chance that an injected
    instruction pulls in other applicants' material, but it is not a boundary: pi's file
    tools can still read anywhere in the container.
  - Tell reviewers that pi's output is advice, and not to open links pi produces. A link can
    carry content out in its URL.

---

## 13. Reviewer quick-start (hand this to reviewers once it's live)

```
First connection: check the server's fingerprint matches the one we sent you separately:
                  SHA256:<fingerprint>
                  If it doesn't match, don't type "yes"; contact <admin contact>.

Connect:           ssh <you>@<VM>
Your applications: already in ~/originals (read-only); you can't upload files
Set up a folder:   mkdir -p ~/work/P123 && cd ~/work/P123
PDF to text:       pdftotext ~/originals/proposal.pdf proposal.txt
Start pi:          pi            # file tools only; models come from brine
One-shot:          pi -p "Summarise the aims and methods in proposal.txt"
Download:          scp <you>@<VM>:work/P123/notes.md .
```

- **Private and offline.** Only you can see your workspace. It has no internet access; the only
  thing it can reach is the brine models. Your prompts and pi's answers aren't logged. pi keeps
  your session history inside your workspace, and it's deleted along with everything else.
- **Originals are protected.** The applications assigned to you are already in `~/originals`.
  It's read-only, so pi can't change them. If something is missing, or you have a conflict
  of interest, contact <admin contact>. Keep each application's work in its own folder under
  `~/work`.
- **pi gives advice, not verdicts.** Applications can contain hidden instructions meant for AI
  tools. Check what pi tells you against the original, and don't open links that pi produces.
- **Keep it here.** Don't copy application content into any other AI tool.
- **Deletion.** Your workspace and everything in it will be deleted on **<retention date>**.
  Download anything you're allowed to keep before then.
- **Problems** (a lost key, a conflict of interest, or leaving the review): contact
  <admin contact> right away.
