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
  type        = string
  description = "Prefix for every resource this sandbox creates."
}

variable "network" {
  type        = string
  default     = null
  description = "Private network. Unset: the project's only internal network."
}

variable "flavor" {
  type        = string
  default     = "p2-4gb"
  description = "Must have a root disk (Disk > 0 in 'openstack flavor list'). Arbutus 'p' flavors don't; Nibi's do."
}

variable "image_regex" {
  type    = string
  default = "^Ubuntu-24\\.04"
}

variable "ssh_public_key" {
  type = string
}

variable "ssh_host_key" {
  type        = string
  sensitive   = true
  description = "The VM's SSH host private key, so the launcher knows its fingerprint before the first connection."
}

variable "ssh_host_public_key" {
  type = string
}

variable "ssh_from_cidr" {
  type        = string
  description = "Only this range may SSH in."
}

variable "brine_ip" {
  type = string
}

variable "bootstrap" {
  type        = bool
  default     = true
  description = "true: open egress so cloud-init can install Pi. false: egress limited to Brine."
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

resource "openstack_networking_secgroup_v2" "sandbox" {
  name                 = "${var.name}-sandbox"
  description          = "SSH in from the launching user, HTTPS out to Brine, nothing else"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "ssh_in" {
  security_group_id = openstack_networking_secgroup_v2.sandbox.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.ssh_from_cidr
}

resource "openstack_networking_secgroup_rule_v2" "brine_out" {
  security_group_id = openstack_networking_secgroup_v2.sandbox.id
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "${var.brine_ip}/32"
}

resource "openstack_networking_secgroup_v2" "bootstrap" {
  name                 = "${var.name}-bootstrap"
  description          = "Open egress for first boot only (metadata, Node, Pi), before any key or data arrives"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "bootstrap_out" {
  security_group_id = openstack_networking_secgroup_v2.bootstrap.id
  direction         = "egress"
  ethertype         = "IPv4"
}

resource "openstack_networking_port_v2" "sandbox" {
  name       = var.name
  network_id = data.openstack_networking_network_v2.private.id
  security_group_ids = concat(
    [openstack_networking_secgroup_v2.sandbox.id],
    var.bootstrap ? [openstack_networking_secgroup_v2.bootstrap.id] : [],
  )
}

resource "openstack_compute_instance_v2" "sandbox" {
  name        = var.name
  image_id    = data.openstack_images_image_v2.ubuntu.id
  flavor_name = var.flavor
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key      = var.ssh_public_key
    ssh_host_key        = var.ssh_host_key
    ssh_host_public_key = var.ssh_host_public_key
    brine_ip            = var.brine_ip
  })

  network {
    port = openstack_networking_port_v2.sandbox.id
  }
}

resource "openstack_networking_floatingip_v2" "sandbox" {
  pool = data.openstack_networking_network_v2.public.name

  lifecycle {
    precondition {
      condition     = data.openstack_networking_router_v2.project.external_network_id == data.openstack_networking_network_v2.public.id
      error_message = "Router '${data.openstack_networking_router_v2.project.name}' has no gateway to '${data.openstack_networking_network_v2.public.name}', so floating IPs can't work. Fix once per project: openstack router set --external-gateway ${data.openstack_networking_network_v2.public.name} ${data.openstack_networking_router_v2.project.name}"
    }
  }
}

resource "openstack_networking_floatingip_associate_v2" "sandbox" {
  floating_ip = openstack_networking_floatingip_v2.sandbox.address
  port_id     = openstack_networking_port_v2.sandbox.id
  depends_on  = [openstack_compute_instance_v2.sandbox]
}

output "ip" {
  value = openstack_networking_floatingip_v2.sandbox.address
}

output "port_id" {
  value = openstack_networking_port_v2.sandbox.id
}

output "sandbox_group_id" {
  value = openstack_networking_secgroup_v2.sandbox.id
}
