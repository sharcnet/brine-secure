# Explore: Sandboxed Pi workspaces on Brine

Status: exploration sketch, untested.

## Idea

Spawn a disposable OpenStack VM per user with Terraform, install the Pi coding harness, and point it at Brine. Pi keeps its full toolset (including `bash`). The security boundary is the VM and its network, not a stripped-down tool list.

Pitch: **a sandboxed coding-agent workspace where code, data and prompts never leave SHARCNET infrastructure.**

## Why not "strip execution tools"

- The VM is the security boundary. Removing tools only limits what the agent can do, and isn't a security guarantee.
- A Pi without execution is a chat window that reads files. A VM is overkill for that.
- The useful pattern runs the other way: let the agent execute freely inside a box with a small blast radius.

## Shape

```
VM (one per user, destroyed when done)
├── user "agent"  → runs Pi with full tools
└── security group → egress allowed ONLY to brine.sharcnet.ca:443
```

- **Brine** (`https://brine.sharcnet.ca`, 199.241.160.16) is LiteLLM in front of SHARCNET-hosted vLLM workers, so it speaks the OpenAI API.
- **Per-user LiteLLM virtual keys** (budget, expiry, revocable) mean the key can sit in the VM. With egress limited to Brine, a leaked key can only be used against Brine, which the user is already allowed to do.
- **Egress control lives in the OpenStack security group**, outside the VM, so root inside the instance can't get around it. No in-VM proxy or nftables needed.

## Terraform sketch

```hcl
terraform {
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack" }
  }
}

variable "users" {
  type      = map(string) # user => brine key
  sensitive = true
}

resource "openstack_networking_secgroup_v2" "sandbox" {
  name                 = "pi-sandbox"
  delete_default_rules = true # no default allow-all egress
}

resource "openstack_networking_secgroup_rule_v2" "ssh_in" {
  security_group_id = openstack_networking_secgroup_v2.sandbox.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "x.x.x.x/32" # bastion / VPN range
}

resource "openstack_networking_secgroup_rule_v2" "brine_out" {
  security_group_id = openstack_networking_secgroup_v2.sandbox.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "199.241.160.16/32" # brine.sharcnet.ca; brittle if the IP changes
}
# No DNS rule: the name is pinned in /etc/hosts.

resource "openstack_compute_instance_v2" "sandbox" {
  for_each        = nonsensitive(toset(keys(var.users)))
  name            = "pi-${each.key}"
  image_name      = "pi-sandbox-image" # Ubuntu + Node 20+ + Pi baked in
  flavor_name     = "p2-3gb"
  key_pair        = "admin"
  security_groups = [openstack_networking_secgroup_v2.sandbox.name]
  user_data       = templatefile("${path.module}/cloud-init.yaml", { brine_key = var.users[each.key] })
}
```

## cloud-init sketch

```yaml
#cloud-config
users:
  - name: agent
    shell: /bin/bash
    ssh_authorized_keys: ["ssh-ed25519 ..."]

write_files:
  - path: /etc/hosts
    append: true
    content: "199.241.160.16 brine.sharcnet.ca\n"
  - path: /home/agent/.pi/agent/models.json
    owner: agent:agent
    defer: true
    content: |
      { "providers": { "sharcnet": {
          "baseUrl": "https://brine.sharcnet.ca",
          "apiKey": "${brine_key}",
          "api": "openai-completions",
          "models": [{ "id": "North-Mini-Code-1.0" }, { "id": "Qwen3.8-27B" }]
      }}}
```

## Key lifecycle

- Mint one key per sandbox via LiteLLM `/key/generate`, with `duration` and `max_budget` set.
- Delete the key (`/key/delete`) on teardown.
- That could be a small script wrapped around `terraform apply`/`destroy`, or it could go into the existing onboarding flow.

## Known gotchas

- **The metadata service exposes `user_data`**, so the key is readable from inside the VM. That's acceptable here because it's the user's own budgeted, revocable key.
- **Terraform state holds the keys** in plaintext. Use a restricted remote backend, or push keys over SSH after boot.
- **No package installs.** Without a mirror route, the toolset is whatever is baked into the image.
- **`agent` gets no sudo.** That isn't required for the egress guarantee (the security group handles that), but it keeps the box simple.

## Open questions

1. **Which OpenStack cloud?** Arbutus, a SHARCNET cloud, or something else. It needs a network path to 199.241.160.16, and Brine's firewall may need to allow that cloud's floating-IP range.
2. **IP pinning.** If Brine's IP changes, sandboxes break quietly. Is that acceptable for a pilot?
3. **Package access.** Is a fixed toolset fine for the target users, or do we need a PyPI mirror route?
4. **`gaggle-trial` and any externally routed models.** If a Brine model routes off SHARCNET, the "never leaves SHARCNET" claim needs keys scoped to exclude it.
