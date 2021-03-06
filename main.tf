terraform {
  required_version = ">= 0.13.1" # see https://releases.hashicorp.com/terraform/
}

data "google_client_config" "google_client" {}

locals {
  instance_name = format("%s-vm-%s", var.instance_name, var.name_suffix)
  external_ip   = var.external_ip == "" ? null : var.external_ip
  tags          = toset(concat(var.tags, [var.name_suffix]))
  zone          = "${data.google_client_config.google_client.region}-${var.zone}"
  pre_defined_sa_roles = [
    # enable the VM instance to write logs and metrics
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/stackdriver.resourceMetadata.writer"
  ]
  sa_name       = var.sa_name == "" ? var.instance_name : var.sa_name
  sa_roles      = toset(concat(local.pre_defined_sa_roles, var.sa_roles))
  create_new_sa = var.sa_email == "" ? true : false
  vm_sa_email   = local.create_new_sa ? module.service_account.0.email : var.sa_email
}

resource "google_project_service" "compute_api" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

module "service_account" {
  count        = local.create_new_sa ? 1 : 0
  source       = "airasia/service_account/google"
  version      = "2.0.1"
  name_suffix  = var.name_suffix
  name         = local.sa_name
  display_name = local.sa_name
  description  = var.sa_description
  roles        = local.sa_roles
}

resource "google_compute_instance" "vm_instance" {
  name         = local.instance_name
  machine_type = var.machine_type
  zone         = local.zone
  tags         = local.tags
  boot_disk {
    initialize_params {
      size  = var.boot_disk_size
      type  = var.boot_disk_type
      image = var.boot_disk_image_source
    }
  }
  network_interface {
    subnetwork = var.vpc_subnetwork
    dynamic "access_config" {
      # Set 'access_config' block only if 'external_ip' is provided
      for_each = local.external_ip == null ? [] : [1]
      content {
        nat_ip = local.external_ip
      }
    }
  }
  metadata = {
    enable-oslogin = (var.os_login_enabled ? "TRUE" : "FALSE") # see https://cloud.google.com/compute/docs/instances/managing-instance-access#enable_oslogin
    windows-keys   = ""                                        # Placeholder to ignore changes. See https://www.terraform.io/docs/configuration/resources.html#ignore_changes
    attached_disk  = null                                      # Placeholder to ignore changes for attached_disk. Null is not intended value here. See https://www.terraform.io/docs/configuration/resources.html#ignore_changes
  }
  service_account {
    email  = local.vm_sa_email
    scopes = ["cloud-platform"]
  }
  allow_stopping_for_update = var.allow_stopping_for_update
  depends_on                = [google_project_service.compute_api]
  lifecycle {
    ignore_changes = [
      attached_disk, # this attached_disk is used to avoid any conflict b/w google_compute_attached_disk & google_compute_instance over the control of disk block.
      metadata["windows-keys"],
    ]
  }
}

resource "google_project_iam_member" "login_role_iap_secured_tunnel_user" {
  count      = length(var.user_groups)
  role       = "roles/iap.tunnelResourceAccessor"
  member     = "group:${var.user_groups[count.index]}"
  depends_on = [google_compute_instance.vm_instance]
}

resource "google_project_iam_member" "login_role_service_account_user" {
  count      = length(var.user_groups)
  role       = "roles/iam.serviceAccountUser"
  member     = "group:${var.user_groups[count.index]}"
  depends_on = [google_compute_instance.vm_instance]
  # see https://cloud.google.com/compute/docs/instances/managing-instance-access#configure_users
}

resource "google_project_iam_member" "login_role_compute_OS_login" {
  count      = length(var.user_groups)
  role       = "roles/compute.osLogin"
  member     = "group:${var.user_groups[count.index]}"
  depends_on = [google_compute_instance.vm_instance]
  # see https://cloud.google.com/compute/docs/instances/managing-instance-access#configure_users
}
