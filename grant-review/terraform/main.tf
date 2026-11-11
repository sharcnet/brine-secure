# The grant-review VM: one long-lived Ubuntu 24.04 server, an encrypted data volume, and a
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
  description = "Addresses reviewers connect from (campus / VPN)."
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

variable "volume_size" {
  type    = number
  default = 150
}

variable "volume_type" {
  type        = string
  description = "An ENCRYPTED volume type. Ceph doesn't wipe deleted volumes; deleting the key does."
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
  description          = "SSH in from reviewers and admins; out only to brine, DNS and the mirror"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "ssh_in" {
  for_each          = toset(distinct(concat(var.reviewer_cidrs, var.admin_cidrs)))
  security_group_id = openstack_networking_secgroup_v2.review.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
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
  config_drive = true # cloud-init reads the config drive, so the VM never needs the metadata service
  user_data    = file("${path.module}/cloud-init.yaml") # no secrets, ever

  network {
    port = openstack_networking_port_v2.review.id
  }

  lifecycle {
    ignore_changes = [image_id] # a newer Ubuntu image must not rebuild a VM holding data
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
