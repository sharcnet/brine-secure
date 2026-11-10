terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }
}

# Credentials come from clouds.yaml via $OS_CLOUD (or a sourced openrc).
provider "openstack" {}

variable "name" {
  type        = string
  description = "Prefix for every resource this sandbox creates."
}

variable "network" {
  type        = string
  description = "Your project's private network (Horizon: Network > Networks)."
}

variable "floating_ip_pool" {
  type        = string
  description = "External network that floating IPs come from (Horizon: Network > Networks, the 'External' one)."
}

variable "flavor" {
  type    = string
  default = "p2-3gb"
}

variable "image_regex" {
  type    = string
  default = "^Ubuntu-24\\.04"
}

variable "ssh_public_key" {
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

data "openstack_networking_network_v2" "private" {
  name = var.network
}

data "openstack_images_image_v2" "ubuntu" {
  name_regex  = var.image_regex
  most_recent = true
}

# The sandbox group is the steady state: SSH in from you, HTTPS out to Brine, nothing else.
# Security groups are enforced by Neutron outside the VM, so root inside can't bypass them.
resource "openstack_networking_secgroup_v2" "sandbox" {
  name                 = "${var.name}-sandbox"
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

# Attached only while cloud-init installs Node and Pi. No secrets or data are on the VM yet.
resource "openstack_networking_secgroup_v2" "bootstrap" {
  name                 = "${var.name}-bootstrap"
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
  # Config drive, not the metadata service: the locked group gives no route to 169.254.169.254.
  config_drive = true
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = var.ssh_public_key
    brine_ip       = var.brine_ip
  })

  network {
    port = openstack_networking_port_v2.sandbox.id
  }
}

resource "openstack_networking_floatingip_v2" "sandbox" {
  pool = var.floating_ip_pool
}

resource "openstack_networking_floatingip_associate_v2" "sandbox" {
  floating_ip = openstack_networking_floatingip_v2.sandbox.address
  port_id     = openstack_networking_port_v2.sandbox.id
  depends_on  = [openstack_compute_instance_v2.sandbox]
}

output "ip" {
  value = openstack_networking_floatingip_v2.sandbox.address
}
