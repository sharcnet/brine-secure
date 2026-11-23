# The grant-review VM: one long-lived Ubuntu 24.04 server, a data volume, and a
# security group whose egress is brine, DNS and the package mirror only.
# Run from the laptop with `review` (or terraform directly). No secret goes into this state.
terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }
}

provider "openstack" {}

variable "name" {
  type    = string
  default = "grant-review"
}

variable "network" {
  type        = string
  default     = null
  description = "Private network. Unset: the project's only internal network."
}

variable "flavor" {
  type        = string
  description = "About 16 vCPU / 32 GB; 8 vCPU / 16 GB is the floor. Needs a root disk."
}

variable "image_regex" {
  type    = string
  default = "^Ubuntu-24\\.04"
}

variable "key_pair" {
  type        = string
  description = "OpenStack keypair for the admin account (ubuntu)."
}

variable "reviewer_cidrs" {
  type        = list(string)
  description = "Addresses reviewers may reach the web page (443) from. Reviewers have no SSH."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Addresses admins connect from. Narrower than reviewer_cidrs."
}

variable "brine_ips" {
  type        = list(string)
  description = "brine.sharcnet.ca's IPv4 address(es). review resolves this for you."
}

variable "dns_cidrs" {
  type        = list(string)
  description = "Institutional DNS resolvers. Must match the subnet's dns_nameservers, which the VM uses."
}

variable "mirror_cidrs" {
  type        = list(string)
  description = "Package mirror(s) for host updates (TCP 80/443). Required: once applications are loaded, setup egress is refused, so without a mirror unattended-upgrades fails silently for months."

  validation {
    condition     = length(var.mirror_cidrs) > 0
    error_message = "Set mirror_cidrs to the package mirror the VM uses (check /etc/apt/sources.list.d/ubuntu.sources after first boot)."
  }
}

variable "ntp_cidrs" {
  type        = list(string)
  default     = []
  description = "NTP servers (UDP 123). Point systemd-timesyncd at the same ones."
}

variable "apt_mirror" {
  type        = string
  default     = ""
  description = "Ubuntu archive URL for the VM (primary and security), e.g. http://mirror.csclub.uwaterloo.ca/ubuntu/. Its address goes in mirror_cidrs. Empty: the image's default (Canonical's, many changing addresses)."
}

variable "ntp_servers" {
  type        = list(string)
  default     = []
  description = "NTP server names for systemd-timesyncd. Their addresses go in ntp_cidrs. Empty: ntp.ubuntu.com, which egress blocks."
}

variable "sso_cidrs" {
  type        = list(string)
  default     = ["75.2.49.220/32", "99.83.186.75/32"]
  description = "The identity provider's addresses (TCP 443) for oauth2-proxy's token and key requests: cilogon.org, AWS Global Accelerator (static). Empty: no SSO egress. Must match SSO_CIDRS in review.env."
}

variable "root_ssh_cidrs" {
  type        = list(string)
  default     = []
  description = "Addresses root may log in from by SSH key (ROOT_SSH_CIDRS in review.env, which also carries the keys). Only the ones not already in admin_cidrs or cert_push_cidrs get a rule here. Empty: none."
}

variable "cert_push_cidrs" {
  type        = list(string)
  default     = []
  description = "Hosts that push the web certificate over SSH to the certpush account (forced command: install-web-cert only), e.g. the Ansible host. Must match CERT_PUSH_CIDRS in review.env. Empty: no such rule."
}

variable "volume_size" {
  type    = number
  default = 150
}

variable "volume_type" {
  type        = string
  default     = null
  description = "Cinder volume type; null = the cloud's default. An encrypted type is optional (PRIMER §4)."
}

variable "setup_egress" {
  type        = bool
  default     = false
  description = "true opens all egress, for first setup only. Never set it once any application is on the VM."
}

data "openstack_networking_network_v2" "public" {
  external = true
}

data "openstack_networking_network_v2" "private" {
  name     = var.network
  external = false
}

data "openstack_networking_port_v2" "router" {
  network_id   = data.openstack_networking_network_v2.private.id
  device_owner = "network:router_interface"
}

data "openstack_networking_router_v2" "project" {
  router_id = data.openstack_networking_port_v2.router.device_id
}

data "openstack_images_image_v2" "ubuntu" {
  name_regex  = var.image_regex
  most_recent = true
}

resource "openstack_networking_secgroup_v2" "review" {
  name                 = "${var.name}-sg"
  description          = "HTTPS in from reviewers and admins, SSH from admins only; out only to brine, DNS, NTP, the mirror and the identity provider"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "ssh_in" {
  for_each          = toset(var.admin_cidrs) # admins only: reviewers use the web page
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
}

# The certificate pusher (e.g. Ansible) gets the certpush account: sshd forces install-web-cert
# for it. If the same address is also in root_ssh_cidrs, root may log in from it too, by key.
resource "openstack_networking_secgroup_rule_v2" "cert_push_in" {
  for_each          = toset(var.cert_push_cidrs)
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
}

# Root by SSH key (named admins), for the addresses not already open above. sshd's Match, the
# keys' from= and pam_access limit root to these addresses too.
resource "openstack_networking_secgroup_rule_v2" "root_ssh_in" {
  for_each          = toset(setsubtract(var.root_ssh_cidrs, concat(var.admin_cidrs, var.cert_push_cidrs)))
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
}

resource "openstack_networking_secgroup_rule_v2" "https_in" {
  for_each          = toset(distinct(concat(var.reviewer_cidrs, var.admin_cidrs)))
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = each.value
}

resource "openstack_networking_secgroup_rule_v2" "brine_out" {
  for_each          = toset(var.brine_ips)
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "${each.value}/32"
}

resource "openstack_networking_secgroup_rule_v2" "dns_out" {
  for_each          = { for p in setproduct(var.dns_cidrs, ["udp", "tcp"]) : "${p[0]}-${p[1]}" => p }
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = each.value[1]
  port_range_min    = 53
  port_range_max    = 53
  remote_ip_prefix  = each.value[0]
}

resource "openstack_networking_secgroup_rule_v2" "mirror_out" {
  for_each          = { for p in setproduct(var.mirror_cidrs, [80, 443]) : "${p[0]}-${p[1]}" => p }
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value[1]
  port_range_max    = each.value[1]
  remote_ip_prefix  = each.value[0]
}

resource "openstack_networking_secgroup_rule_v2" "ntp_out" {
  for_each          = toset(var.ntp_cidrs)
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 123
  port_range_max    = 123
  remote_ip_prefix  = each.value
}

resource "openstack_networking_secgroup_rule_v2" "sso_out" {
  for_each          = toset(var.sso_cidrs)
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = each.value
}

resource "openstack_networking_secgroup_v2" "setup" {
  name                 = "${var.name}-setup"
  description          = "Open egress for first setup only, before any application is loaded"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "setup_out" {
  security_group_id = openstack_networking_secgroup_v2.setup.id
  direction         = "egress"
  ethertype         = "IPv4"
}

resource "openstack_networking_port_v2" "review" {
  name       = var.name
  network_id = data.openstack_networking_network_v2.private.id
  security_group_ids = concat(
    [openstack_networking_secgroup_v2.review.id],
    var.setup_egress ? [openstack_networking_secgroup_v2.setup.id] : [],
  )
}

resource "openstack_compute_instance_v2" "review" {
  name         = var.name
  image_id     = data.openstack_images_image_v2.ubuntu.id
  flavor_name  = var.flavor
  key_pair     = var.key_pair
  config_drive = true                                          # cloud-init reads the config drive, so the VM never needs the metadata service
  user_data = templatefile("${path.module}/cloud-init.yaml", { # no secrets, ever
    apt_mirror  = var.apt_mirror
    ntp_servers = var.ntp_servers
  })

  network {
    port = openstack_networking_port_v2.review.id
  }

  lifecycle {
    # A newer Ubuntu image or edited user data must not rebuild a VM holding data.
    ignore_changes = [image_id, user_data]
  }
}

resource "openstack_blockstorage_volume_v3" "data" {
  name        = "${var.name}-data"
  size        = var.volume_size
  volume_type = var.volume_type

  lifecycle {
    prevent_destroy = true # retention deletes this deliberately (PRIMER section 12), never by accident
  }
}

resource "openstack_compute_volume_attach_v2" "data" {
  instance_id = openstack_compute_instance_v2.review.id
  volume_id   = openstack_blockstorage_volume_v3.data.id
}

resource "openstack_networking_floatingip_v2" "review" {
  pool = data.openstack_networking_network_v2.public.name

  lifecycle {
    prevent_destroy = true # the site's DNS A record and CILogon callback point at this address
    precondition {
      condition     = data.openstack_networking_router_v2.project.external_network_id == data.openstack_networking_network_v2.public.id
      error_message = "Router '${data.openstack_networking_router_v2.project.name}' has no gateway to '${data.openstack_networking_network_v2.public.name}'. Fix once per project: openstack router set --external-gateway ${data.openstack_networking_network_v2.public.name} ${data.openstack_networking_router_v2.project.name}"
    }
  }
}

resource "openstack_networking_floatingip_associate_v2" "review" {
  floating_ip = openstack_networking_floatingip_v2.review.address
  port_id     = openstack_networking_port_v2.review.id
  depends_on  = [openstack_compute_instance_v2.review]
}

output "ip" {
  value = openstack_networking_floatingip_v2.review.address
}

output "fixed_ip" {
  description = "The VM's address on the project network, used from the admin VM (VM_ADDRESS=fixed)"
  value       = openstack_networking_port_v2.review.all_fixed_ips[0]
}

output "server_id" {
  value = openstack_compute_instance_v2.review.id
}

output "port_id" {
  value = openstack_networking_port_v2.review.id
}

output "review_group_id" {
  value = openstack_networking_secgroup_v2.review.id
}

output "volume_id" {
  value = openstack_blockstorage_volume_v3.data.id
}

output "volume_device" {
  value = openstack_compute_volume_attach_v2.data.device
}
