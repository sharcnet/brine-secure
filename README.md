# brine-secure

A disposable VM on an Alliance OpenStack cloud (Arbutus, Nibi) running the [Pi](https://pi.dev) coding agent against Brine. The VM can reach Brine and nothing else. It is destroyed when you log out.

```
./sandbox --data ~/project
# ... work with pi ...
exit            # VM, floating IP, and security groups are all destroyed
```

## Requirement: a single-user OpenStack project

Run this only in an OpenStack project where you are the only member. Anyone with a role in the project can snapshot the running VM, attach their own security group to it, or open its console, and that gets them your data and your Brine key. The lockdown below assumes nobody else is in the project.

## How it's locked down

- **Egress is limited to `brine.sharcnet.ca:443`** by an OpenStack security group. Neutron enforces it outside the VM, so root inside the VM can't get around it. The script checks that the internet is unreachable before it hands over your key or data.
- **SSH in is allowed only from your current public IP.** Behind campus NAT or eduroam, that IP is shared by everyone on the NAT. Key-only auth still applies, but a VPN range in `SSH_FROM_CIDR` is tighter.
- **The first SSH connection is already pinned.** The launcher makes the VM's host key and hands it over in user data, so it knows the fingerprint before it connects.
- **Pi runs as `agent`, which has no sudo.**
- **`/data` is read-only.** It's a copy owned by root, bind-mounted with `ro`. Your original files are never touched, and nothing is synced back.
- **The Brine key never reaches Terraform.** It goes into the VM over SSH after egress is locked, so it isn't in the state file or in cloud-init user data.

Boot runs in two phases. The VM first starts with open egress so cloud-init can install Node and Pi. At that point it holds no secrets and no data. The script then removes that security group and verifies the lock twice. It asks OpenStack that the port has only the sandbox group and that the group's only egress rule is Brine, then checks from inside the VM that the internet is unreachable. Only then does it copy in data and your key.

## One-time setup (Nibi cloud)

You need membership in a Nibi cloud project. If you don't have one, ask your PI or use the [cloud project request form](https://docs.alliancecan.ca/wiki/Cloud#Getting_a_cloud_project).

The Nibi cloud API (`nibi.cloud.sharcnet.ca:5000` and the other service ports) is IP-allowlisted. The dashboard loads from anywhere, but the CLI and Terraform hang until a sysadmin adds your public IP. Test it with `timeout 5 bash -c '</dev/tcp/nibi.cloud.sharcnet.ca/5000' && echo ok`.

1. Install [Terraform](https://developer.hashicorp.com/terraform/install), [uv](https://docs.astral.sh/uv/), and rsync. Run `uv sync` here to get the OpenStack CLI.
2. Log in to <https://nibi.cloud.alliancecan.ca> with your CCDB account. Go to *Identity → Application Credentials → Create Application Credential* and download the `clouds.yaml`. Save it as `clouds.yaml` in this folder (or `~/.config/openstack/`), rename its cloud entry from `openstack` to `nibi`, and run `export OS_CLOUD=nibi`. An application credential avoids putting your CCDB password or MFA in the loop. Give it an expiry date, since it can do anything in the project.
3. Put your Brine API key in `./brine.key`.
4. Check the project's router has a public gateway. New projects normally do, but ours didn't, and without one no VM can get a public IP. `./sandbox` stops with this exact fix if it's missing:
   ```
   uv run openstack router list                 # e.g. <project>-router
   uv run openstack router set --external-gateway public-network <router>
   ```

That's it for Nibi: the network is auto-detected and the flavor defaults to `p2-4gb`. To override either (e.g. on Arbutus, whose "p" flavors have no root disk, so you need a "c" flavor), copy `terraform.tfvars.example` to `terraform.tfvars`, which Terraform loads on its own. Use `uv run openstack flavor list` etc. to find values.

The SSH key is generated on first run in `./.ssh/`. `brine.key`, `clouds.yaml`, `terraform.tfvars`, `.ssh/` and the Terraform state are all gitignored. Your project's `default` security group is left alone; the sandbox makes its own.

## Use

- `./sandbox`: start a VM, then land in `~/work` as `agent`. Run `pi`.
- `./sandbox --data DIR`: also copy `DIR` to `/data`, read-only. Everything goes, including hidden files like `.git` and `.env`. `DIR` can't overlap this folder, since it holds your keys.
- `ssh -F .ssh/config agent@sandbox`: open a second shell from another terminal.
- `./sandbox --destroy`: clean up if a run died before it could tear down. Until you do, `./sandbox` refuses to start, so it never reopens egress on a VM that already holds your data. One sandbox per folder at a time.

Set `SSH_FROM_CIDR=x.x.x.x/32` to skip the public-IP lookup, for example on a VPN. The lookup sends your IP to api.ipify.org, a third party.

## Models

Pi defaults to `North-Mini-Code-1.0`. Switch models inside Pi with `/model`. Each launch reads the live list from Brine's `/v1/models` and registers its chat models with Pi.

Models on Brine, from [brine-examples/model-cards](https://github.com/sharcnet/brine-examples/blob/main/model-cards/README.md):

| Model | Modality | Service limit | Tool calling | In Pi |
| --- | --- | ---: | --- | --- |
| `North-Mini-Code-1.0` | Chat | 320,000 tokens | Supported | Default |
| `Qwen3.8-27B` | Chat, image input | 131,072 tokens | Supported | Yes |
| `DeepSeek-V4-Flash-0731` | Chat | 131,072 tokens | Supported | Yes |
| `qwen3-embed` | Embedding | 8,192 tokens | Not applicable | No (not chat) |
| `whisper-large-v3-turbo` | Audio transcription | 25 MB upload | Not applicable | No (not chat) |

Brine's terms say not to submit sensitive data. That applies to anything in `/data`, too: Pi sends whatever it reads to the model.

Treat `/data` as untrusted. Text in it can carry instructions that Pi may follow, and Pi loads `AGENTS.md` and `.pi/` from whatever directory it works in. Don't `cd` Pi into `/data`.

## Limits

- **No installs after lock.** No PyPI, no apt, no npm. The toolset is what cloud-init installed. If that's too tight, the next step is a mirror route or a baked image.
- **No DNS.** Brine is pinned in `/etc/hosts`, and its IP is resolved fresh on each launch. Pi runs with `PI_OFFLINE=1` so it doesn't stall on startup checks.
- **Work on the VM is lost on exit.** To keep something, copy it out from another terminal with `scp -F .ssh/config agent@sandbox:work/file .`.
- **Each launch installs Pi from scratch** (a few minutes). A pre-baked image would remove that.
- **One floating IP per sandbox.** RAS projects get 2 floating IPs, so a project can run at most 2 sandboxes at once (fewer if other VMs hold IPs).
- **Brine must accept traffic from the cloud's floating-IP range.** This is confirmed for Nibi cloud. Arbutus is untested. If it fails, the last setup step reports a Brine error.
