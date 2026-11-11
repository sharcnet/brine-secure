# grant-review

A second deployment of Pi + Brine, for confidential grant review. About 50 reviewers share one
long-lived VM, each with their own Podman container that has no network at all. Reviewers
sign in to a **web page** (their applications, the original or its text, an assistant panel,
and their notes), or use SSH and a terminal if they prefer. Both land in their own container.
The only way out is a Unix socket to nginx on the host, which adds that reviewer's Brine key
and forwards two exact API paths to Brine. Admins pre-load each reviewer's assigned
applications as read-only files. Reviewers can download but never upload.

[PRIMER.md](PRIMER.md) is the design: what each piece does and why, what still needs
verifying, the 61 acceptance tests, and operations. Start there. A security sign-off write-up
with a diagram and threat model exists as a separate document (ask the grant-review admins).

## How it differs from the sandbox

| | Sandbox (top level) | grant-review |
|---|---|---|
| Users | One person, their own project | ~50 reviewers on one VM, run by admins |
| Lifetime | Destroyed at logout | The length of a competition |
| Agent | Full shell | File tools only, inside a container with no network |
| Brine key | User's own key, inside the VM | Per-reviewer key, held by nginx on the host, never in the container |
| Data | `--data` copy | Admin-loaded from the assignment list, checksum manifest, second-person check |
| Egress | Security group: Brine IP | No network in the container; host nftables drops the reviewer group; security group as backstop |

What both share: [`../BRINE-REQUIREMENTS.md`](../BRINE-REQUIREMENTS.md), the list of what
Brine's admins must set, and the findings in [`../SECURITY-REVIEW.md`](../SECURITY-REVIEW.md).

## Layout

```
review                 admin CLI (laptop); reads review.env
acceptance.sh          the 61 acceptance tests (laptop); logs to test-logs/
review.env.example
terraform/             VM, encrypted data volume, security groups, floating IP
image/                 container image: Containerfile, lockfile, forwarder, build script
image/web/             the reviewers' web app (Node built-ins only), served from inside each container
local/                 a Lima test VM for a Mac: local/up builds everything, see local/README.md
vm/configure           sets up the VM (run by `review deploy`)
vm/sbin/               enter-review and the admin scripts
vm/lib/common.sh       shared helpers for the admin scripts
vm/files/              nginx, sshd, sudoers, nftables, fail2ban, pam_access, Quadlet, models.json
```

## Setup, in order

You need Terraform, the OpenStack CLI (`uv sync` at the top level), `jq` and `dig` on the
laptop. You also need a Linux x86_64 host with podman to build the image.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in
cp review.env.example review.env                                   # fill in
terraform -chdir=terraform init

./review apply                      # VM + volume; egress locked; shows the plan first
./review pin-hostkey                # host key from the console log
./review setup-egress on            # first setup only; refused once applications exist
./review data-volume /dev/vdb       # check the device with: review ssh lsblk
./review deploy                     # then, with a second session open: ./review deploy --admin-access
image/build                         # on the build host (or on the VM now, while egress is open)
./review image brine-review-YYYYMMDD.tar
./review setup-egress off           # and never on again
```

Then add three test reviewers (`testa`, `testb`, `testa2`) with `sample.pdf` and
`sample.txt`, and run `./acceptance.sh` (PRIMER §11) before any real reviewer.

Per reviewer:

```bash
./review add alice alice.pub        # mints the key on Brine; login stays off
./review stage P123.pdf P456.pdf
./review load assignment.csv        # username,filename
./review manifest alice             # a second person checks this against the list
./review activate alice "J. Smith"
./review web-password alice         # prints a new web sign-in password once
./review remove alice               # purge data, revoke key (asks you to type the name)
```

## Status

Nothing here has been run yet. The scripts have only been syntax-checked, and the templates
render-tested. Every **[VERIFY]** in PRIMER.md must be checked on the real VM. Before go-live:

- **Brine:** items 1 and 12 in BRINE-REQUIREMENTS, plus written answers for the rest.
- **Competition owner:** sign-off under the Tri-agency AI-use guidance.
- **Not run yet:** `acceptance.sh`. Its quoting was dry-run on a Mac, but none of the
  tests has run against a VM.
