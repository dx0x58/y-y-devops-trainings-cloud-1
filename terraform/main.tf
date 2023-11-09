terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  service_account_key_file = "./tf_key.json"
  folder_id                = local.folder_id
  zone                     = local.zone
}

resource "yandex_vpc_network" "foo" {}

variable "subnets" {
  description = "A map of subnets with zones and CIDR blocks"
  default = {
    "ru-central1-a" = "10.5.0.0/24",
    "ru-central1-b" = "10.6.0.0/24",
  }
}

resource "yandex_vpc_subnet" "foo" {
  for_each       = var.subnets
  zone           = each.key
  network_id     = yandex_vpc_network.foo.id
  v4_cidr_blocks = [each.value]
}

locals {
  folder_id = "b1giqcgsoihb8lse2is3"
  service-accounts = toset([
    "catgpt-main-sa",
  ])
  catgpt-sa-roles = toset([
    "container-registry.images.puller",
    "monitoring.editor",
  ])
  zone = "ru-central1-a"
}
resource "yandex_iam_service_account" "service-accounts" {
  for_each = local.service-accounts
  name     = each.key
}
resource "yandex_resourcemanager_folder_iam_member" "catgpt-roles" {
  for_each  = local.catgpt-sa-roles
  folder_id = local.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.service-accounts["catgpt-main-sa"].id}"
  role      = each.key
}

resource "yandex_iam_service_account" "instance-group-sa" {
  name        = "instance-group-sa"
  description = "Instance Group SA"
}

resource "yandex_resourcemanager_folder_iam_binding" "editor" {
  folder_id = local.folder_id
  role      = "editor"
  members = [
    "serviceAccount:${yandex_iam_service_account.instance-group-sa.id}",
  ]
  depends_on = [
    yandex_iam_service_account.instance-group-sa,
  ]
}

data "yandex_compute_image" "coi" {
  family = "container-optimized-image"
}

resource "yandex_compute_instance_group" "catgpt-group" {
  depends_on = [yandex_resourcemanager_folder_iam_binding.editor]

  name               = "catgpt-group"
  folder_id          = local.folder_id
  service_account_id = yandex_iam_service_account.instance-group-sa.id
  instance_template {
    platform_id = "standard-v2"

    service_account_id = yandex_iam_service_account.service-accounts["catgpt-main-sa"].id

    resources {
      cores         = 2
      memory        = 2
      core_fraction = 5
    }
    boot_disk {
      initialize_params {
        type     = "network-hdd"
        size     = 30
        image_id = data.yandex_compute_image.coi.id
      }
    }
    network_interface {
      network_id = yandex_vpc_network.foo.id
      subnet_ids = values(yandex_vpc_subnet.foo).*.id
      nat        = true
    }
    metadata = {
      docker-compose = base64encode(templatefile("${path.module}/docker-compose.yaml", { image_tag: var.image_tag }))
      ssh-keys       = "ubuntu:${file("${pathexpand("~")}/.ssh/devops_training.pub")}"
      user-data      = "#cloud-config\nruncmd:\n  - wget -O - https://monitoring.api.cloud.yandex.net/monitoring/v2/unifiedAgent/config/install.sh | bash"
    }
    scheduling_policy {
      preemptible = true
    }
  }

  scale_policy {
    fixed_scale {
      size = 2
    }
  }

  allocation_policy {
    zones = values(yandex_vpc_subnet.foo).*.zone
  }

  deploy_policy {
    max_unavailable  = 2
    max_expansion    = 0
    max_deleting     = 2
    startup_duration = 60
  }

  application_load_balancer {
    target_group_name        = "catgpt-tg"
    target_group_description = "load balancer target group"
  }
}

resource "yandex_alb_http_router" "catgpt-router" {
  name = "catgpt-http-router"
}

resource "yandex_alb_virtual_host" "catgpt-virtual-host" {
  name           = "catgpt-virtual-host"
  http_router_id = yandex_alb_http_router.catgpt-router.id
  route {
    name = "catgpt-route"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.catgpt-backend-group.id
        timeout          = "60s"
      }
    }
  }
}

resource "yandex_alb_backend_group" "catgpt-backend-group" {
  depends_on = [
    yandex_alb_load_balancer.catgpt-balancer
  ]

  name = "catgpt-backend-group"

  http_backend {
    name   = "catgpt-http-backend"
    weight = 1
    port   = 8080

    target_group_ids = [yandex_compute_instance_group.catgpt-group.application_load_balancer[0].target_group_id]
    healthcheck {
      timeout  = "10s"
      interval = "3s"
      http_healthcheck {
        path = "/ping"
      }
    }
    http2 = "true"
  }
}

resource "yandex_alb_load_balancer" "catgpt-balancer" {
  name       = "catgpt-alb"
  network_id = yandex_vpc_network.foo.id

  allocation_policy {
    location {
      zone_id   = local.zone
      subnet_id = yandex_vpc_subnet.foo[local.zone].id
    }
  }

  listener {
    name = "catgpt-alb-listener"
    endpoint {
      address {
        external_ipv4_address {
        }
      }
      ports = [80]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.catgpt-router.id
      }
    }
  }

  log_options {
    discard_rule {
      http_code_intervals = ["HTTP_2XX"]
      discard_percent     = 75
    }
  }
}
