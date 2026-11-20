# grant-review

A second deployment of Pi + Brine, for confidential grant review. Reviewers share one
long-lived VM, each with their own Podman container that has no network at all. Reviewers
use a **web page** only (their applications, the original or its text, an assistant panel,
and their notes), served from inside their own container. They have no SSH access.
The only way out is a Unix socket to nginx on the host, which adds that reviewer's Brine key
and forwards two exact API paths to Brine. Admins pre-load each reviewer's assigned
applications as read-only files. Reviewers can download their notes but never upload.

[PRIMER.md](PRIMER.md) is the design: what each piece does and why, what still needs
verifying, the 53 acceptance tests, and operations. Start there. A security sign-off write-up
with a diagram and threat model exists as a separate document (ask the grant-review admins).

## How it differs from the sandbox

| | Sandbox (top level) | grant-review |
|---|---|---|
| Users | One person, their own project | Many reviewers on one VM (web only), run by admins |
| Lifetime | Destroyed at logout | The length of a competition |
| Agent | Full shell | File tools only, inside a container with no network |
| Brine key | User's own key, inside the VM | Per-reviewer key, held by nginx on the host, never in the container |
| Data | `--data` copy | Admin-loaded from the assignment list, checksum manifest, second-person check |
| Egress | Security group: Brine IP | No network in the container; host nftables drops the reviewer group; security group as backstop |

What both share: [`../BRINE-REQUIREMENTS.md`](../BRINE-REQUIREMENTS.md), the list of what
Brine's admins must set, and the findings in [`../SECURITY-REVIEW.md`](../SECURITY-REVIEW.md).

## Layout

```
admin-vm/              the command-and-control VM: cloud-init, setup, README
review                 admin CLI (admin VM or laptop); reads review.env
acceptance.sh          the 53 acceptance tests; logs to test-logs/
review.env.example
terraform/             VM, data volume, security groups, floating IP
image/                 container image: Containerfile, lockfile, forwarder, build script
image/web/             the reviewers' web app (Node built-ins only), served from inside each container
local/                 a Lima test VM for a Mac: local/up builds everything, see local/README.md
vm/configure           sets up the VM (run by `review deploy`)
vm/sbin/               enter-review and the admin scripts
vm/lib/common.sh       shared helpers for the admin scripts
vm/files/              nginx, sshd, sudoers, nftables, fail2ban, pam_access, Quadlet, models.json
```

## Setup, in order

Everything below runs on the **admin VM** in the same project, not on a laptop. Set that up
first: [admin-vm/README.md](admin-vm/README.md). (A laptop still works, as before.)

The admin VM's cloud-init installs Terraform, the OpenStack CLI, `jq`, `dig` and podman. (On a
laptop: `uv sync` at the top level for the CLI, plus a Linux x86_64 host with podman for the
image.)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in
cp review.env.example review.env                                   # fill in
terraform -chdir=terraform init

./review apply                      # VM + volume; egress locked; shows the plan first
./review pin-hostkey                # host key from the console log
./review setup-egress on            # first setup only; refused once applications exist
./review data-volume /dev/vdb       # check the device with: review ssh lsblk
./review deploy                     # then, with a second session open: ./review deploy --admin-access
image/build                         # on the admin VM (x86_64 + podman)
./review image brine-review-YYYYMMDD.tar
./review setup-egress off           # and never on again
```

Then add three test reviewers (`testa`, `testb`, `testa2`) with `sample.pdf` and
`sample.txt`, and run `./acceptance.sh` (PRIMER §11) before any real reviewer.

Per reviewer:

```bash
./review add alice                  # mints the key on Brine; web sign-in stays off until activate
./review stage P123.pdf P456.pdf
./review load assignment.csv        # username,filename
./review manifest alice             # a second person checks this against the list
./review activate alice "J. Smith"
./review web-password alice         # prints a new web sign-in password once
./review list                       # each application and its reviewers (also: reviewers, csv)
./review remove alice               # purge data, revoke key (asks you to type the name)
```

## Status

Nothing here has been run yet. The scripts have only been syntax-checked, and the templates
render-tested. Every **[VERIFY]** in PRIMER.md must be checked on the real VM. Before go-live:

- **Brine:** items 1 and 12 in BRINE-REQUIREMENTS, plus written answers for the rest.
- **Competition owner:** sign-off under the Tri-agency AI-use guidance.
- **Not run yet:** `acceptance.sh`. Its quoting was dry-run on a Mac, but none of the
  tests has run against a VM.
