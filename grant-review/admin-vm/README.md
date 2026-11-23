# The admin VM (command and control)

A small VM in the same OpenStack project that runs everything an admin laptop used to run:
Terraform and its state, the `review` CLI, the image build, and key minting. Admins SSH in
from wherever they are. Nothing about the review VM depends on anyone's laptop.

```
admin laptop ──SSH (own key)──► admin VM ──SSH, project network──► review VM
                                  │ terraform, openstack CLI ──► OpenStack API
                                  │ image/build (podman) ──► npm, registries
                                  └ review add ──► brine (key minting)
```

## Why it's safe to put it here

- **No new people:** anyone with a role in the project can already open the review VM's
  console or snapshot it. The admin VM adds no one new to the trust boundary.
- **Admins are named:** each admin has their own account (group `gradmin`), so the log shows
  who loaded and who activated. This doesn't make the second-person check a technical control,
  but it does make it auditable.
- **Applications are kept in RAM:** applications pass through the admin VM only in
  `/run/grant-review/incoming`, which is in RAM. Delete them once they're staged.
- **Credentials stay off disk images:** the OpenStack application credential and the LiteLLM
  header file sit in `/etc/grant-review`, readable by `gradmin` only. Neither is in user data
  or in the repo.
- **Egress is open:** the admin VM needs open egress (GitHub, npm, container registries,
  HashiCorp, the OpenStack API, brine). That's why applications must not stay on it.

## Setting it up (once)

1. **Launch it in Horizon** (*Compute → Instances → Launch Instance*):
   - Ubuntu 24.04, a small flavour (2 vCPU / 8 GB / 40 GB is plenty for the image build), the
     project network, and a floating IP.
   - **Security group:** SSH in from the admins' addresses only. Leave the default egress.
   - **Configuration:** paste [`cloud-init.yaml`](cloud-init.yaml) after putting each admin's
     name and laptop public key in `users`.
2. **Check the API is reachable** from it. The cloud's API ports are firewalled. Ask the cloud
   admins to allow this VM's floating IP too:
   `curl -s -m 5 https://nibi.cloud.sharcnet.ca:5000/v3 | head -c 100`
3. **Clone the repo:**
   - Make a deploy key: `sudo ssh-keygen -t ed25519 -f /root/.ssh/brine-secure -N ''`.
   - Add the `.pub` to sharcnet/brine-secure as a **read-only** deploy key (a repo admin does
     this).
   - Then:
     ```bash
     sudo GIT_SSH_COMMAND='ssh -i /root/.ssh/brine-secure' git clone -b grant-review \
       git@github.com:sharcnet/brine-secure.git /opt/grant-review
     sudo /opt/grant-review/grant-review/admin-vm/setup
     ```
4. **Add the credentials:**
   - `/etc/grant-review/clouds.yaml`: the application credential (`member` + `creator`). Use
     cloud name `openstack`.
   - `/etc/grant-review/litellm-admin-header`, only if brine gives you a team-scoped minting
     credential.
   - Fill in `/etc/grant-review/review.env` and `grant-review/terraform/terraform.tfvars`.
   - Run `sudo /opt/grant-review/grant-review/admin-vm/setup` again to fix permissions.
5. **Each admin makes their own key** for the review VM:
   - Run `ssh-keygen -t ed25519` (on the admin VM, as yourself).
   - The first admin's `.pub` becomes the OpenStack keypair (`key_pair` in tfvars).
   - Later admins go into `/etc/grant-review/admin-keys.pub`, and someone already in runs
     `review admin-keys /etc/grant-review/admin-keys.pub`.
6. **In `terraform.tfvars`:**
   - `admin_cidrs` = this VM's **fixed** address /32, plus any break-glass address.
   - `ADMIN_CIDRS` in review.env is the same.
   - The review VM then accepts admin SSH only from here.

Then follow the main [README](../README.md) from `terraform init`, on this VM. `image/build`
runs here too: it is x86_64 with podman. The review VM never needs `setup-egress on` for the
image again.

## Root by SSH key (2026-11-23)

Two named admins (the deployment lead and the sysadmin who installs the web certificate) may
log in as root with their keys, which cloud-init's `disable_root` would otherwise block. It's done by hand, since
cloud-init runs once:

- `/root/.ssh/authorized_keys` (0600): their two keys, each with
  `from="<addresses>",no-agent-forwarding,no-X11-forwarding`.
- `/etc/ssh/sshd_config.d/55-root.conf`: `PermitRootLogin no`, then
  `Match User root Address <addresses>` with `PermitRootLogin prohibit-password` and
  `AuthenticationMethods publickey`.
- Security group `gr-admin`: port 22 from the same addresses (the lead's home address and the
  SHARCNET Ansible host).

Check with `sudo sshd -T -C user=root,host=x,addr=<address>`. The review VM does the same through
`ROOT_SSH_KEYS` / `ROOT_SSH_CIDRS` in review.env (PRIMER §8).

## Day to day

```bash
ssh <you>@<admin-vm>                     # your own account; the environment is set up for you
sudo GIT_SSH_COMMAND='ssh -i /root/.ssh/brine-secure' git -C /opt/grant-review pull \
  && sudo /opt/grant-review/grant-review/admin-vm/setup   # setup again fixes group permissions
scp P123.pdf <you>@<admin-vm>:/run/grant-review/incoming/   # from wherever the applications are
review stage $INCOMING/P123.pdf && rm $INCOMING/P123.pdf
review list
```

## What's still open

- **Acceptance tests from here:** `acceptance.sh` plays a reviewer from outside. To run it from
  the admin VM, add its fixed address to `reviewer_cidrs` for the test run. Or run it from a
  laptop with an admin key.
- **Terraform state** lives in the checkout (`terraform/terraform.tfstate`). It holds no
  secrets, but losing it means importing the resources by hand, so copy it somewhere after
  each `apply`. A Swift backend is an option later.
- **The admin VM itself:** keep it patched (unattended-upgrades is on). Rebuild it from this
  file rather than repair it.
