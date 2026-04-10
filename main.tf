################################################################################
# 1. ПОИСК ОБРАЗА СИСТЕМЫ
################################################################################
# Этот блок автоматически ищет последний актуальный ID образа Ubuntu 22.04.
# Не нужно прописывать ID вручную (типа fd8...), Terraform найдет его сам.
data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}
################################################################################
# 2. СЕТЕВАЯ ИНФРАСТРУКТУРА
################################################################################
# Создаем виртуальную сеть (VPC). Виртуальный роутер для нашего проекта.
resource "yandex_vpc_network" "develop" {
  name = "develop"
}

# Создаем подсеть в зоне "ru-central1-a". 
# Все наши ресурсы (ВМ и балансировщик) будут жить внутри этой подсети.
resource "yandex_vpc_subnet" "develop" {
  name           = "develop-ru-central1-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.develop.id
  v4_cidr_blocks = ["10.0.1.0/24"] # Внутренние IP будут начинаться на 10.0.1.x
}

################################################################################
# 3. СОЗДАНИЕ ВИРТУАЛЬНЫХ МАШИН
################################################################################
# Используем аргумент count для создания двух одинаковых машин.
resource "yandex_compute_instance" "vm" {
  count = 2 
  name  = "vm-${count.index}" # Имена будут vm-0 и vm-1
  zone  = "ru-central1-a"

  resources {
    cores         = var.test.cores         # Берем кол-во ядер из переменных
    memory        = var.test.memory        # Память из переменных
    core_fraction = var.test.core_fraction # Доля CPU (20% дешевле)
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id # Тот самый образ, что нашли в начале
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.develop.id
    nat       = true # Включаем внешний IP, чтобы Ansible мог зайти из интернета
  }

  metadata = {
    serial-port-enable = 1 # Включаем консоль (помогает при отладке)
    # Пробрасываем SSH-ключ для пользователя ubuntu
    ssh-keys           = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

################################################################################
# 4. ПОДГОТОВКА К ANSIBLE
################################################################################
# Этот ресурс берет шаблон hosts.tftpl и вставляет в него реальные IP-адреса машин.
# На выходе получаем готовый файл hosts.ini.
resource "local_file" "hosts_cfg" {
  content = templatefile("./hosts.tftpl", {
    web_vms = yandex_compute_instance.vm
  })
  filename = "./hosts.ini"
}

# Этот блок запускает сам Ansible после того, как "железо" создано.
resource "null_resource" "web_setup" {
  # Запускаем только когда машины созданы и файл hosts.ini готов
  depends_on = [yandex_compute_instance.vm, local_file.hosts_cfg]

  provisioner "local-exec" {
    # sleep 60 дает машинам время загрузиться, иначе Ansible не достучится по SSH
    command = "sleep 60 && ansible-playbook -i hosts.ini playbook.yml"
  }
}

################################################################################
# 5. БАЛАНСИРОВЩИК (LOAD BALANCER)
################################################################################
# Группируем наши 2 машины в одну "цель" для балансировщика.
resource "yandex_lb_target_group" "tg" {
  name      = "my-target-group"
  region_id = "ru-central1"

  dynamic "target" {
    for_each = yandex_compute_instance.vm # Цикл по всем созданным машинам
    content {
      subnet_id = yandex_vpc_subnet.develop.id
      address   = target.value.network_interface.0.ip_address # Внутренний IP каждой ВМ
    }
  }
}

# Сам балансировщик, который будет принимать трафик снаружи.
resource "yandex_lb_network_load_balancer" "lb" {
  name = "my-load-balancer"

  listener {
    name = "http-listener"
    port = 80 # Какой порт слушаем снаружи
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.tg.id

    # Проверка "живы" ли машины. Если Nginx на ВМ упадет, балансировщик уберет ее из списка.
    healthcheck {
      name = "http"
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}

################################################################################
# 6. ВЫВОД РЕЗУЛЬТАТОВ
################################################################################
# Выводим IP балансировщика в консоль, чтобы знать, куда заходить в браузере.
output "balancer_ip" {
  value = flatten([
    for listener in yandex_lb_network_load_balancer.lb.listener :
    [for spec in listener.external_address_spec : spec.address]
  ])
}
