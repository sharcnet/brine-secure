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
> - §11 grew from 22 to 61 tests, including a canary test for content logging. (53 since the
>   web-only change of 2026-11-18; 59 with the CILogon tests of 2026-11-20; 60 with the
>   certificate push test.)
>
> **Revision 2026-11-20:** CILogon sign-in built (§8.1): oauth2-proxy plus `review-authz`,
> `WEB_AUTH=sso|basic`, tests 62-67, and a mock OIDC provider for the local test VM.
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
> **Revision 2026-11-11:** a web front end (§8.1), so reviewers can work from a browser
> instead of SSH and a terminal. It runs inside each reviewer's no-network container, behind
> nginx HTTPS sign-in on the host. A local Lima test VM (`local/`) found and fixed several
> bugs, including reviewers being unable to write their own home (§8.2).
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
OpenAI-compatible endpoint) to analyse confidential applications. Most reviewers work from a
**web page** (§8.1); SSH and a terminal are there for admins and anyone who prefers them. Admins load each reviewer's
assigned applications before the reviewer gets access.

### Required properties

1. **The only network destination is brine.** The container itself has no network at all.
2. **pi can do local file operations and call brine, nothing else.**
3. **Reviewers are isolated from each other.** No shared files, processes or network, and no
   shared UID range.
4. **Reviewers never get a host shell.** SSH always lands in their own container, and the web
   page is served from inside their own container.
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
reviewer's browser                       admin VM (same project, fixed address)
   │ HTTPS (sign-in; CILogon + MFA later)   │ ssh (admins only; reviewers have no SSH)
   │                                        │ load-applications
   ▼                                        ▼
┌───────────────────────────── VM (Ubuntu 24.04) ──────────────────────────────┐
│ nginx :443 ── signed-in, ACTIVE reviewer ──► /run/review-web/alice/web.sock  │
│                                                     │                        │
│  ┌──────── container review-alice (network=none) ───▼─────────────────────┐  │
│  │ user "reviewer": web app (node), pi --mode rpc, pdftotext              │  │
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
| Cinder volume type (encrypted is optional, see §4) | default |
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
| `admin-vm/` | Horizon, once | The admin VM: cloud-init and `setup`. Everything below runs there (or on a laptop) |
| `review` | Admin VM | One CLI for everything below. Reads `review.env` |
| `terraform/` | Admin VM → OpenStack | VM, data volume, security groups, floating IP |
| `image/` | Admin VM (x86_64, podman) | Builds the reviewer container image and saves it as a tarball |
| `vm/configure` | VM, as root | Installs packages and every config file; safe to run again |
| `vm/sbin/` | VM, as root | The admin scripts |
| `vm/files/` | VM | nginx, sshd, sudoers, nftables, fail2ban, pam_access, Quadlet template, pi `models.json` |
| `../BRINE-REQUIREMENTS.md` | brine | What brine's admins must set, shared with the sandbox deployment |

**The admin VM (decision 2026-11-18).** Command and control runs on a small VM in the same
project, not on anyone's laptop: Terraform and its state, `review`, the image build and key
minting. Each admin has a named account there (group `gradmin`). It reaches the review VM on
the project network (`VM_ADDRESS=fixed`), so `admin_cidrs` is its fixed address. It adds no one
new to the trust boundary, because anyone with a project role can already reach the review
VM's console. Applications pass through it only in RAM (`/run/grant-review/incoming`). See
[admin-vm/README.md](admin-vm/README.md).

Secrets never sit in this repo, in Terraform state, in user data or in a command line:

- The LiteLLM credential that mints keys stays on the admin VM, in `/etc/grant-review`
  (root:gradmin 0640).
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
- **Data volume** of `volume_type` (the cloud's default if unset). It has `prevent_destroy`,
  so retention (§12) is the only way it goes.
  - **Encryption is optional (decision 2026-11-18).** This deployment uses an unencrypted
    volume. The cost: Ceph doesn't wipe deleted volumes, so retention overwrites the volume
    before deleting it, and that is best effort (old copies can survive in Ceph until reused).
    If a competition owner needs guaranteed destruction, set an encrypted `volume_type`; then
    deleting its key in Barbican destroys the data.
- **Floating IP**, with the same router-gateway check as the sandbox. It has `prevent_destroy`:
  the site's DNS A record points at it, so rebuilding the VM keeps the address. Releasing it
  takes removing that line on purpose (retention step 4).

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
4. Installs the admin scripts (0700) in `/usr/local/sbin`, and removes the old SSH entry
   pieces (`enter-review`, its sudo rule, `/etc/ssh/authorized_keys`) if present.
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
# on the admin VM (x86_64, podman)
grant-review/image/build                 # refuses if curl, python3, git, npm, sudo... are present
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

## 8. Phase 5: reviewers use the web page only (sshd, pam_access, nftables)

**Decision 2026-11-18: reviewers have no SSH access at all.** Everything they do is on the web
page (§8.1). This removes the SSH entry path (`enter-review`, its sudo rule, sftp downloads and
the forwarding controls) and the attack surface that came with it. `configure` deletes those
pieces from a VM that had them.

- **sshd:** `DenyGroups reviewers`, refused before authentication. `MaxAuthTries 3` and
  `PermitRootLogin no` globally. Admins only.
- **Root by SSH key (decision 2026-11-23):** Two named admins (the deployment lead and the sysadmin who
  installs the web certificate) may log in as root with their keys (`ROOT_SSH_KEYS`). Only from
  `ROOT_SSH_CIDRS`: a `Match User root Address` block (`55-root.conf`, `prohibit-password`,
  publickey only), `from=` on every key, a `+:root:` pam_access line, and `root_ssh_cidrs` in
  the security group. Everywhere else root stays refused (test 5 and 69).
- **Security group:** port 22 accepts only `admin_cidrs`; `reviewer_cidrs` reach 443 only.
- **pam_access:** `-:(reviewers):ALL`, so a reviewer account can't log in from anywhere, even
  if sshd were misconfigured.
- **Accounts:** reviewers have no password and `/usr/sbin/nologin` as their shell. The account
  exists for the UID (project quota), the `reviewers` group (nftables) and the container.
- **nftables:** `meta skgid <reviewers> drop` on output. This also covers the metadata service.
- **fail2ban** sshd jail, with the admin addresses in `ignoreip`.
- **Pending reviewers:** `/etc/brine-review/pending/<user>` marks a reviewer who is added but
  not yet activated. `activate-reviewer` removes it (§8.1).
- **Image [follow-up]:** the image still carries `openssh-sftp-server`, now unreachable. Drop it
  at the next image build. (`pi-review` stays: tests 33 and 34 use it from the admin side.)

### 8.1 Web front end (HTTPS)

Reviewers sign in at `https://<VM>/` and get a three-panel page:
- **left:** their applications
- **middle:** the original (the browser's PDF viewer) or its extracted text
- **right:** an assistant panel, plus their notes for that application

Notes and conversations download as Markdown.

```
browser ──HTTPS──► VM: nginx :443 ── sign-in: CILogon (WEB_AUTH=sso) or basic auth (tests)
                        │ active name → /run/review-web/<user>/web.sock   (only that one)
                        ▼
                  container review-<user> (network=none):
                    node /opt/review-web/server.js  (as "reviewer", Unix socket only)
                      └─ pi --mode rpc, one per application, tools read,grep,find,ls,write,edit
                           └─ 127.0.0.1:4000 → brine socket → nginx adds the key → brine
```

- **No new way out:**
  - The web app runs inside the reviewer's existing container, as `reviewer`, and listens only
    on a Unix socket in `/run/review-web/<user>/`, bind-mounted into that container alone.
  - It reaches brine through the same forwarder as SSH sessions.
  - `review-web@<user>.service` starts it with `podman exec` once the container is up.
- **Sign-in and routing:**
  - nginx (`vm/files/nginx-web.conf`) serves TLS on 443. The sign-in itself is in
    `/etc/nginx/review-web-auth.conf`, which `configure` installs for `WEB_AUTH`: **`sso`**
    (CILogon, below; for reviewers) or **`basic`** (a password per reviewer, set with
    `review web-password <user>`; for the local test VM and the first acceptance run).
  - **No passwords with CILogon (2026-11-20).** Switching to `sso` deletes `htpasswd` and
    `htpasswd.pending`, and `web-password` refuses to run, so a CILogon site holds no web
    password. On a real VM `configure` also refuses `sso` while the acceptance accounts
    (`testa`, `testb`, `testa2`, `testp`) exist: they are ordinary names in the Alliance
    namespace, so a real Alliance user with one of them would get that sandbox. Remove them
    after the basic-mode run. Test 63 checks no password file is left.
  - **The active list (2026-11-20).** In both modes the signed-in name must be on
    `/etc/brine-review/web/active.map` before nginx picks a socket. `web-access-sync` writes
    it, with `active` (for review-authz) and `active-emails` (for oauth2-proxy), from every
    reviewer who isn't pending. It is derived from that state each time, never edited line by
    line. `activate-reviewer` and `remove-reviewer` call it.
  - **Activation gates the web too (fixed 2026-11-18).** Until then, a reviewer with a web
    password could sign in before the second-person check. Now a pending reviewer's password
    goes to `htpasswd.pending`, which nginx never reads, and `activate-reviewer` moves it
    across. Test 51 checks a pending reviewer gets 401 on the web.
  - **Web only:** reviewers have no SSH (§8).
  - It picks the socket only from the verified user name: a non-name maps to a path that
    can't exist.
  - It strips the `Authorization` header, so the password never reaches the container.
  - The access log records user, method, status and size, but no URLs, because paths carry
    application file names.
  - fail2ban watches failed sign-ins.
- **Driving pi safely:**
  - The server builds every RPC command itself from a fixed list: prompt, abort, new session,
    set model, get messages.
  - pi's RPC protocol also has a `bash` command that ignores `--tools`. The server never sends
    it, and nothing from the browser reaches pi except the text of a question.
  - Each application gets its own pi session in `~/work/<application>/.sessions`.
  - The system prompt (`image/web/system-prompt.md`) tells pi that the application is data,
    not instructions, and never to write links or images.
- **Browser-side defences:**
  - A strict CSP: `default-src 'none'`, scripts, styles and fetches only from the page itself.
    That means no request can go to another site, even if an answer contained one.
  - Every element is built with `textContent`, and a small safe Markdown subset is rendered by
    hand. Links stay plain text and images never load.
  - Writes need a custom header and JSON, and cross-site requests are refused
    (`Sec-Fetch-Site`).
  - Application names must match the loader's strict pattern.
  - Notes are never written through a symlink.
- **Not in the web page:** uploads, sharing, a shell, other users' anything.
- **SSO: CILogon (chosen 2026-11-18, built 2026-11-20).** Reviewers sign in through
  [CILogon](https://www.cilogon.org/oidc) with their Alliance (CCDB) account and MFA, the same
  login as CCDB. The Alliance IdP `https://idp.alliancecan.ca/idp/shibboleth` is in CILogon's
  list and releases the R&S attributes.

  ```
  browser ─► nginx :443 ─ /oauth2/* ──────────────► oauth2-proxy 127.0.0.1:4180 ─► CILogon
               │                                       (PKCE, nonce, ID token signature,
               │                                        acr = MFA, active eppns only)
               └ every other request: auth_request ─► review-authz 127.0.0.1:4181
                    ▲ 202 + X-Review-User: <name>        │ asks oauth2-proxy for the session,
                    │   (or 401 → sign-in, 403)           │ then checks the ID token itself:
                    └─ name on active.map → that socket   │ idp, acr, eppn, active list
  ```

  - **Client:** a confidential OIDC client registered at https://cilogon.org/oauth2/register.
    Free for academic research (Basic tier), approved by hand in about a day. Scopes:
    `openid email profile org.cilogon.userinfo` (the last carries `eppn` and `idp`).
    Callback: `https://<SSO_HOST>/oauth2/callback`. `SSO_CLIENT_ID` goes in review.env; the
    secret goes to the VM with `review sso-secret` (a 0600 file, or typed), never in the repo
    or user data.
  - **oauth2-proxy** (`vm/files/oauth2-proxy.*`): v7.15.6, fetched by `review deploy` and
    checked against the SHA-256 pins in `vm/files/oauth2-proxy.sha256`, on the admin machine
    and again on the VM. The project publishes no signatures, so the pins are the trust
    anchor; upgrade by changing the version and both hashes together. It runs as its own
    user, loopback only, with systemd sandboxing and `IPAddressAllow=localhost` plus
    `SSO_CIDRS` (CILogon) only. It does the OIDC flow (PKCE S256, nonce checked), sends
    `acr_values=https://refeds.org/profile/mfa` and `idphint=<Alliance IdP>`, refuses any ID
    token whose `acr` isn't MFA (`groupsClaim: acr` plus `allowedGroups`), and allows only the
    eppns in `active-emails`, which it watches: taking a reviewer off the list ends their
    session on the next request (test 65). Sessions are encrypted cookies
    (`__Host-review_sso`, Secure, HttpOnly, SameSite=Lax) that last 12 hours, whatever the
    ID token's lifetime. Request logging is off, because URLs carry application names.
  - **review-authz** (`vm/files/review-authz.py`, Python standard library, about 100 lines):
    the second, independent check, and the only one nginx trusts for the name. oauth2-proxy
    can't check arbitrary claims (it maps only email, groups and user), so review-authz asks
    it for the session over loopback, reads the ID token oauth2-proxy verified at sign-in,
    and checks that `idp` is the Alliance IdP (`idphint` is only a hint), that `acr` is MFA,
    that `eppn` matches `^[a-z][a-z0-9_-]{0,30}@alliancecan\.ca$` and equals the session's
    email, and that the name is on the active list. Any error is a refusal. It runs as its
    own user, loopback only (`IPAddressAllow=localhost`), with no URL logging; refusals are
    logged with the eppn and the reason. It doesn't re-verify the token's signature (it comes
    from oauth2-proxy's encrypted session on loopback) or its `exp` (CILogon ID tokens last
    minutes; the session's length is oauth2-proxy's).
  - **Why not njs:** nginx's JavaScript module could decode the token in nginx, but on Ubuntu
    24.04 it is in universe (no guaranteed security updates) and would sit inside the
    internet-facing nginx. A separate loopback service is easier to audit and to sandbox.
  - **nginx:** `/oauth2/` goes to oauth2-proxy; `/oauth2/auth` is 404 from outside (only
    review-authz asks it); everything else runs `auth_request` to review-authz. Not signed in:
    pages redirect to the sign-in and API calls get 401 (the page reloads). Forged
    `X-Review-User` or `X-Auth-Request-*` headers from a browser are never read: nginx takes
    the name only from review-authz's response. Neither the `Authorization` header nor the
    session cookie reaches a container.
  - **Usernames:** reviewer names are their CCDB usernames, so no mapping table is needed.
    **Confirmed 2026-11-18** at https://cilogon.org/testidp/: the Alliance IdP releases
    `ePPN = <ccdb-username>@alliancecan.ca`, plus name, email and affiliation
    (`member@alliancecan.ca`). It is R&S and SIRTFI, and its assurance is `IAP/low`.
  - **Egress:** the review VM's security group allows 443 to `sso_cidrs` (cilogon.org,
    75.2.49.220 and 99.83.186.75, AWS Global Accelerator static addresses) for the token and
    key endpoints. Containers still have no network, and the reviewers group is still dropped
    by nftables.
  - **CILogon's test instance (2026-11-20).** The pilot client
    (`cilogon:oa4mp,2012:/client_id/6a13…`) is registered on **test.cilogon.org**, so the VM
    runs with `SSO_ISSUER=https://test.cilogon.org` and egress to its own Global Accelerator
    addresses, 3.33.212.95 and 15.197.204.227 (`SSO_CIDRS` in review.env and `sso_cidrs` in
    terraform.tfvars, which must match). Production cilogon.org is blocked meanwhile. The
    Alliance IdP is in test's IdP list, so the IdP and MFA settings stay the same. Moving to
    production means a new client, removing those three settings, `review apply`, then
    `review deploy` and `review sso-secret`. CILogon client IDs contain a comma
    (`oa4mp,2012`); configure accepts it, and the Lima mock uses an ID of the same shape.
  - **Refusal pages (2026-11-21).** A signed-in account that is refused (not active, no MFA,
    another IdP) gets a 403 page saying it is not an active reviewer; the reason is in
    `journalctl -u review-authz`. When oauth2-proxy is down (for example, no client secret
    yet) or review-authz errors, the page says sign-in is unavailable (503). Both still
    refuse; the app's own `/api/` calls get only the status code.
  - **MFA is required (decision 2026-11-18).** **Confirmed 2026-11-18:** the Alliance login
    through CILogon asks for Duo and asserts `AuthnContextClassRef =
    https://refeds.org/profile/mfa`. **[VERIFY]** once the client is registered that CILogon
    passes it on as the OIDC `acr` claim (otherwise every sign-in is refused: it fails closed)
    and that the `idp` claim is the entityID above (test 66).
  - **Tested** on the local VM against `local/mock-oidc.py`, a mock provider that signs in
    whoever the test names (`local/sso on`): the wrong IdP, no or password-only `acr`, a
    non-Alliance eppn, capitals, a non-reviewer, a pending reviewer, and deactivation
    mid-session are all refused (tests 51, 62-65, 67).
  - **Needs:** a DNS name (`SSO_HOST`) and a publicly trusted certificate for it, installed
    with `review web-cert <fullchain.pem> <key.pem>`.
- **Certificate:** `configure` makes a self-signed certificate if none exists.
  `review web-cert` replaces it after checking the key matches, the certificate covers
  `SSO_HOST` and has at least 7 days left (the old one is restored if nginx rejects the new one).
- **Certificate push (2026-11-20).** SHARCNET's Ansible host keeps the certificate current,
  without root or a shell on the VM. Set `CERT_PUSH_KEY` (one public key), `CERT_PUSH_CIDRS`
  (the pusher's addresses; the same in `cert_push_cidrs` in terraform.tfvars) and `SSO_HOST`,
  then `review apply` and `review deploy`. That creates a `certpush` account that can do one
  thing: run `install-web-cert`, which reads a tar of `tls.crt` and `tls.key` on stdin.
  - sshd forces the command for `certpush` (`ForceCommand`, no TTY, no forwarding of any
    kind, public key only). Its key sits in a root-owned file with `from=` and `restrict`.
  - sudo allows `install-web-cert` with no arguments and nothing else. `certpush` isn't a
    reviewer, has no password and owns no files.
  - Port 22 opens to `CERT_PUSH_CIDRS` only, and pam_access admits `certpush` from there
    alone (once `--admin-access` is on).
  - The installer treats the push as untrusted: 1 MiB cap, plain files only (no links), the
    key must match, the certificate must cover `SSO_HOST` for 7 more days, and nginx must
    accept it, or the old pair stays. It logs who installed what.
  - The Ansible side is one task: `tar -c tls.crt tls.key | ssh certpush@SSO_HOST`. Ansible's
    usual modules can't run here (no shell, no sftp), on purpose.
  - Test 68 checks all of it; with `CERT_PUSH_TEST_KEY` (the local VM) it also pushes a wrong
    certificate and a right one.
  - Leave `CERT_PUSH_KEY` empty and `review deploy` removes the account, key file and rule.

### 8.2 Who owns the home folder

Podman's `:U` volume option gives a volume to the container's *main* user, which here is
`fwd`, the forwarder. With `:U` on the home, reviewers couldn't read or write their own home:
pi couldn't save sessions, pdftotext couldn't read, and sftp failed. The local test VM caught
this. Instead:
- **Before each start:** `ExecStartPre` sets the home to 0711, so the container runtime can
  set up mounts inside it in whatever UID range `UserNS=auto` picks.
- **After each start:** `review-own-home` reads the range Podman actually picked and gives the
  home, and the web socket folder, to `reviewer`. It uses `chown -R -h -P`, so as root it never
  follows a link the reviewer made.

---

## 9. Phase 6: reviewers and applications

```bash
./review add alice alice.pub          # mints the key on brine, creates everything, login OFF
./review stage P123.pdf P456.pdf      # streamed onto the data volume's staging dir
./review load assignment.csv          # username,filename lines from the competition owner
./review manifest alice               # second person compares this with the assignment list
./review activate alice "J. Smith"    # login ON; records who checked
./review list                         # each application and its reviewers
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
- **Keys** (admin VM, `review add`):
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
- **`review list`** (VM: `list-assignments`) reports who has which application, from what is
  actually on the VM: the files in each reviewer's `originals`, the accounts and their login
  state. It is read-only and never opens an application.
  - `review list` (or `applications`): each application with its reviewers and their status
    (`active` or `pending`). It also names reviewers with no applications and
    anything staged but not loaded.
  - `review list reviewers`: each reviewer with status, web sign-in set, container up,
    manifest `ok` or `MISMATCH`, and their applications.
  - `review list csv`: `username,filename,status` lines, the assignment list's shape, so
    `diff <(cut -d, -f1,2 list.csv | sort) <(sort assignment.csv)` shows any difference.
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
- Check that `UserNS=auto`, `podman exec`, the web app and the forwarder all still work.
  Run the whole of §11 under gVisor.
- If anything doesn't work, don't force it. Leave gVisor off and tell the human, because the
  rest of the design is still sound.

---

## 11. Acceptance tests

Create three test reviewers, `testa`, `testb` and `testa2`, each with their own LiteLLM key
and a web password. `testa2` is there on purpose: its name starts with another reviewer's name, which
catches prefix and glob bugs in socket, home and container paths. Load `sample.pdf` (and a
`sample.txt`) for each with `review stage` and `review load`, check the manifests, and activate them (§9).

`acceptance.sh` runs the suite from the laptop and writes a dated log to `test-logs/` with
the result and output of every test: PASS, FAIL, MANUAL (needs a person, often a brine admin;
the log says what to check) or SKIP. Put the test reviewers' web passwords in the file named
by `WEB_PASSWORDS_FILE` (`<user> <password>` lines, gitignored). It plants and removes the
canaries itself. Tests that look inside a container use `podman exec` as the container's
`reviewer` user, from the admin side, because reviewers have no shell access of their own.

```bash
./acceptance.sh                    # everything safe to repeat
./acceptance.sh --with-resource    # adds 35-37 (fork bomb, memory hog, disk fill)
./acceptance.sh --with-lifecycle   # adds 52 and 54: revokes testa's key and removes testa
./acceptance.sh --only 23,24,25    # a subset
```

Set `PENDING_USER` to a test reviewer who is added but not activated, and give them a web
password, to cover the last part of test 51. Tests 10, 27, 49, 50 and 53 are always MANUAL; 26 is automated on the VM side, with a
brine-side confirmation. Run the whole suite:

- before go-live
- after every image rebuild (§9.2)
- after any upgrade to sshd, nginx, oauth2-proxy, Podman, LiteLLM or the brine model servers
- after every reboot

Unless a test says otherwise, it runs inside `testa`'s container, as `reviewer`.

**Setup canaries (admin, on the host):** put a file containing `HOST-CANARY-<random>` in
`/root/` and a file containing `TESTB-CANARY-<random>` in `/srv/review/homes/testb/`. If either
string ever shows up in `testa`'s session, the test that showed it failed.

### 11.1 No reviewer SSH

| # | Test | Expected |
|---|---|---|
| 1 | As admin, plant a throwaway key in the reviewers' shared home (`/var/lib/reviewers/home/.ssh/authorized_keys`), then `ssh -i <that key> testa@VM`; remove the key | `Permission denied`; the sshd log says DenyGroups |
| 2 | `getent passwd testa`; `passwd -S testa`; `grep reviewers /etc/security/access.conf` | Shell `/usr/sbin/nologin`; password locked; `-:(reviewers):ALL` (after `configure --admin-access`) |
| 3 | `ls -d /usr/local/sbin/enter-review /etc/sudoers.d/reviewers /etc/ssh/authorized_keys`; `sudo -l -U testa` | None exist; testa may not run sudo |
| 4 | `openstack security group rule list <review group> --ingress` | Port 22 only from `ADMIN_CIDRS`; reviewers' ranges reach 443 only |
| 5 | `sudo sshd -T -C user=testa,host=x,addr=203.0.113.1` | `denygroups reviewers`, `permitrootlogin no`, `permituserenvironment no`, `maxauthtries 3` |
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
| 29 | On the host as admin: `cd /srv/review/originals/testa && sha256sum -c /srv/review/manifests/testa.sha256`; `stat -c '%U %a %n' *`; compare with the assignment list | All `OK`; exactly the assigned files; `root 444` |
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
| 39 | `stat -c '%U %a %n' /usr/local/sbin /usr/local/sbin/add-reviewer /usr/local /usr` | All owned by root; none group- or world-writable |
| 41 | `ls -ld /run/brine-proxy/*`; `podman inspect review-testa --format '{{range .Mounts}}{{.Source}} {{end}}'` | Each directory is root 0755 and holds only `brine.sock`. testa's container mounts only `/run/brine-proxy/testa`, `/run/review-web/testa`, `/srv/review/homes/testa`, `/srv/review/originals/testa` and `models.json` |
| 42 | `sudo -u testa curl -m5 https://BRINE_HOST`; `sudo -u testa curl -m5 http://169.254.169.254/` | Both fail (nftables drop) |
| 43 | `curl -s http://169.254.169.254/openstack/latest/user_data`, and the config drive (`blkid -L config-2`, mount read-only, read `openstack/latest/user_data`) | Contains no secrets |
| 44 | `curl -m5 https://example.com` | Blocked by the security group. `review check` shows only the review group on the port |
| 45 | `swapon --show`; `findmnt /srv/review` | No swap. `nodev,nosuid,noexec,prjquota` |
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
| 51 | Read a marker file in testb's and testa2's containers; before `activate-reviewer`, sign in on the web as a fourth test user | Each container holds its own reviewer's home, never another's. The not-yet-active user gets 401 |
| 52 | Revoke testa's LiteLLM key while testa's container is running | testa's next request fails (401) within a minute or two (LiteLLM caches keys briefly). testb is unaffected |
| 53 | Reboot the VM | Run the **entire** suite again, not just the functional tests. The usual failure is that things work again but the controls didn't come back |
| 54 | `remove-reviewer --purge-data testa` | testa's container, socket, home, originals, manifest and user are gone; the key is revoked; testa's web sign-in fails. **testa2 still works**: its container, model path (23) and web sign-in (58) |

### 11.9 brine's shared IP and leftover connections

| # | Test | Expected |
|---|---|---|
| 55 | On the host as admin (not a reviewer): `curl -sk -m5 -H 'Host: anything' https://<brine IP>/` and `curl -sk -m5 --resolve x.example:443:<brine IP> https://x.example/` | No response from any site other than brine (BRINE-REQUIREMENTS item 1). Until that's fixed, record it as a residual risk: only a compromised host process could use it, since containers have no network and nginx always sends brine's name |
| 56 | `review check` after setup egress is turned off, and again after a reboot | Only the review group on the port; open connections are SSH and brine :443 only |

### 11.10 Web front end

Set `WEB_PASSWORDS_FILE` to a file of `<user> <password>` lines for the test reviewers.

| # | Test | Expected |
|---|---|---|
| 57 | `https://VM/` with no password, with a wrong password, and `http://VM/` | 401 with a sign-in prompt; 401; no plain-HTTP listener |
| 58 | Each test reviewer lists `/api/apps`; `nginx -T` | Each sees only their own applications; the socket comes only from the verified name; `Authorization` is stripped |
| 59 | Cross-site read; a write without `X-Review`; a form-encoded write; `..%2F` and raw `../` paths; `/server.js`; notes replaced by a symlink to `/etc/passwd`, then saved | 403, 403, 403, 400, 404, 404; the save is refused (400) |
| 60 | Response headers; `review-web.access.log`; `/var/lib/nginx` | `default-src 'none'` CSP and HSTS; no URLs or file names in the log; no temp files |
| 61 | Over the web, ask pi to run `cat /etc/passwd` with a shell and to give a link | It completes with only file tools; no shell tool, no passwd contents; read the answer: no link |

### 11.11 SSO sign-in (WEB_AUTH=sso)

Against real CILogon only 62, 63 and 66 can run: the web tests above need to sign in as test
reviewers, which only the mock provider can do. So on a real VM, run the whole suite in basic
mode first, then remove the test reviewers and the passwords file, set `WEB_AUTH=sso`,
`review deploy`, `review sso-secret`, and run 62, 63, 66 and 67. On
the local VM, `local/sso on` runs everything in SSO mode against the mock.

| # | Test | Expected |
|---|---|---|
| 62 | `/oauth2/start` | Redirects to `SSO_ISSUER/authorize` with `acr_values` = MFA, `idphint` = the Alliance IdP, PKCE S256, a nonce, `redirect_uri=https://SSO_HOST/oauth2/callback`, scope with `org.cilogon.userinfo` |
| 63 | `/oauth2/auth` from outside; forged `X-Review-User`/`X-Auth-Request-Email` headers and cookie; listeners; `nginx -T`; secret file modes; `request_logging` | 404; 401; oauth2-proxy and review-authz on 127.0.0.1 only; no `auth_basic`; secrets `root:oauth2-proxy 640`; logging off; no `htpasswd` files |
| 64 | Mock sign-ins: active reviewer with MFA; no `acr`; password-only `acr`; another IdP asserting an Alliance eppn; no `idp`; another domain; a non-reviewer; capitals | 200, then 403 for every other case; review-authz logs the other-IdP refusal itself |
| 65 | Sign in as testa2, mark testa2 pending and sync, reuse the session; then reactivate | The session is refused at once (401/403); signing in works again within seconds |
| 66 | Real CILogon (MANUAL) | An active test reviewer gets in with Alliance login and Duo; a non-reviewer gets Forbidden; logs show the refusal, no URLs; a trusted certificate |
| 67 | Session cookie flags; oauth2-proxy and review-authz logs | `__Host-review_sso`, Secure, HttpOnly, SameSite=Lax; no URLs or file names |
| 68 | `certpush` (when `CERT_PUSH_KEY` is set): `sshd -T` for it and for another user; `sudo -l -U certpush`; its key file; with `CERT_PUSH_TEST_KEY`: a command line, a remote forward, a certificate for another host, then a valid one | `ForceCommand` install-web-cert, no TTY or forwarding, publickey only, nothing forced on other users; sudo: that command with no arguments only; root-owned key with `from=` and `restrict`; the command reaches only the installer, forwarding fails, the wrong host is refused, the valid one is served |

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
  activated. Staging copies sit on the data volume and are deleted once the loading is
  checked. The copy script never opens the files.
- **Data at rest:** homes, originals, manifests, staging and pi's session history are all on
  the Cinder data volume (not encrypted, see §4). Containers' root filesystems are the read-only image; `/tmp`
  is tmpfs, and there is no swap. nginx doesn't buffer bodies to disk. Backups are off by
  default; if any are made, they're encrypted and covered by the same retention rule. Don't
  take snapshots or images of the VM or the volume.
- **Logs:** sshd auth logs, nginx access logs (`brine_meta` format), `brine-review` admin
  actions, and LiteLLM spend records, all metadata only. Never log request bodies, and keep
  prompt storage and callbacks off in LiteLLM. Delete these logs after the agreed
  log-retention period.
- **What counts as content:** applications, extracted text, reviewers' notes, and pi's
  transcripts in `~/.pi/agent/sessions`. All of it lives on the data volume and is
  purged with the reviewer's data.
- **OpenStack project:** only the review admins have a role in it. Anyone with a role can
  snapshot the VM, attach a security group or open the console, so project membership is part
  of the trust boundary. Application credentials get an expiry date.
- **Access:**
  - Reviewers use the web page only, signing in with CILogon and MFA. The VM keeps no web
    passwords in that mode (basic mode is for acceptance testing before CILogon, with test
    accounts only). Sign-in stays off until activation. Reviewers have no SSH access.
  - Admin logins are allowed only from allowlisted addresses (pam_access).
  - fail2ban watches sshd.
- **Offboarding during the review** (conflict of interest, withdrawal or a lost key): for one
  application, `unload-application` the same day. For the whole reviewer,
  `remove-reviewer --purge-data` and revoke the key the same day. Issue a new account if
  needed; never reuse the old one.
- **Retention:** on the agreed date:
  1. Run `remove-reviewer --purge-data` for everyone, and revoke all keys (they also expire).
  2. Check that no snapshots, images or backups exist.
  3. Ceph doesn't wipe deleted volumes. Unmount `/srv/review`, overwrite the volume from
     the VM (`dd if=/dev/zero of=/dev/vdb bs=4M oflag=direct status=progress`), then delete
     it. That is best effort. With an encrypted volume type instead, confirm its key is gone
     from Barbican; that is what destroys the data.
  4. Delete the VM if it's no longer needed. To release its address too, remove `prevent_destroy`
     from the floating IP in `terraform/main.tf`, and have the DNS record deleted.

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
Sign in:      https://<review host>/  with your Alliance (CCDB) account and its MFA
Left:         the applications assigned to you
Middle:       the original PDF, or its extracted text
Right:        the assistant, and your notes for that application
Download:     your notes and the conversation, as Markdown
```

- **Private and offline.** Only you can see your workspace. It has no internet access; the only
  thing it can reach is the brine models. Your prompts and the assistant's answers aren't
  logged. Your conversation history stays in your workspace, and it's deleted along with
  everything else.
- **Originals are protected.** The applications assigned to you are already loaded and
  read-only, so the assistant can't change them. You can't upload files. If something is
  missing, or you have a conflict of interest, contact <admin contact>.
- **The assistant gives advice, not verdicts.** Applications can contain hidden instructions
  meant for AI tools. Check what it tells you against the original.
- **Keep it here.** Don't copy application content into any other AI tool.
- **Deletion.** Your workspace and everything in it will be deleted on **<retention date>**.
  Download anything you're allowed to keep before then.
- **Problems** (a conflict of interest, a lost account, or leaving the review): contact
  <admin contact> right away.
