# brine-secure

A disposable VM on an Alliance OpenStack cloud (Arbutus, Nibi) running the [Pi](https://pi.dev) coding agent against Brine. The VM can reach Brine and nothing else. It is destroyed when you log out.

```
./sandbox --data ~/project
# ... work with pi ...
exit            # VM, floating IP, and security groups are all destroyed
```

## How it's locked down

- **Egress is limited to `brine.sharcnet.ca:443`** by an OpenStack security group. Neutron enforces it outside the VM, so root inside the VM can't get around it. The script checks that the internet is unreachable before it hands over your key or data.
- **SSH in is allowed only from your current public IP.**
- **Pi runs as `agent`, which has no sudo.**
- **`/data` is read-only.** It's a copy owned by root, bind-mounted with `ro`. Your original files are never touched, and nothing is synced back.
- **The Brine key never reaches Terraform.** It goes into the VM over SSH after egress is locked, so it isn't in the state file or in cloud-init user data.

Boot runs in two phases. The VM first starts with open egress so cloud-init can install Node and Pi. At that point it holds no secrets and no data. The script then removes that security group, verifies the lock, and only then copies in data and your key.

## One-time setup

1. Install [Terraform](https://developer.hashicorp.com/terraform/install), [uv](https://docs.astral.sh/uv/), and rsync.
2. In the cloud's dashboard ([Arbutus](https://arbutus.alliancecan.ca), [Nibi](https://nibi.cloud.alliancecan.ca)), go to *Identity → Application Credentials*, create one, and download its `clouds.yaml` to `~/.config/openstack/clouds.yaml`. Then `export OS_CLOUD=<name in that file>`.
3. Run `uv sync` to install the OpenStack CLI, then fill in the cloud-specific names:
   ```
   cp sandbox.tfvars.example sandbox.tfvars
   uv run openstack network list   # private network + external floating-IP pool
   uv run openstack flavor list
   ```
4. Put your Brine API key in `./brine.key`.

The SSH key is generated on first run in `./.ssh/`. `brine.key`, `sandbox.tfvars`, `.ssh/` and the Terraform state are all gitignored.

## Use

- `./sandbox`: start a VM, then land in `~/work` as `agent`. Run `pi`.
- `./sandbox --data DIR`: also copy `DIR` to `/data`, read-only.
- `ssh -F .ssh/config agent@sandbox`: open a second shell from another terminal.
- `./sandbox --destroy`: clean up if a run died before it could tear down.

Set `SSH_FROM_CIDR=x.x.x.x/32` to skip the public-IP lookup (it uses api.ipify.org), for example on a VPN.

## Limits

- **No installs after lock.** No PyPI, no apt, no npm. The toolset is what cloud-init installed. If that's too tight, the next step is a mirror route or a baked image.
- **No DNS.** Brine is pinned in `/etc/hosts`, and its IP is resolved fresh on each launch. Pi runs with `PI_OFFLINE=1` so it doesn't stall on startup checks.
- **Work on the VM is lost on exit.** To keep something, copy it out from another terminal with `scp -F .ssh/config agent@sandbox:work/file .`.
- **Each launch installs Pi from scratch** (a few minutes). A pre-baked image would remove that.
- **Brine must accept traffic from the cloud's floating-IP range.** If it doesn't, the last setup step fails with a Brine error.
