
# Домашнее задание к занятию «Отказоустойчивость в облаке» - Бобков Александр
<details>
<summary><b>Задание 1</b></summary>

Возьмите за основу [решение к заданию 1 из занятия «Подъём инфраструктуры в Яндекс Облаке»](https://github.com/netology-code/sdvps-homeworks/blob/main/7-03.md#задание-1).

1. Теперь вместо одной виртуальной машины сделайте terraform playbook, который:

- создаст 2 идентичные виртуальные машины. Используйте аргумент [count](https://www.terraform.io/docs/language/meta-arguments/count.html) для создания таких ресурсов;
- создаст [таргет-группу](https://registry.terraform.io/providers/yandex-cloud/yandex/latest/docs/resources/lb_target_group). Поместите в неё созданные на шаге 1 виртуальные машины;
- создаст [сетевой балансировщик нагрузки](https://registry.terraform.io/providers/yandex-cloud/yandex/latest/docs/resources/lb_network_load_balancer), который слушает на порту 80, отправляет трафик на порт 80 виртуальных машин и http healthcheck на порт 80 виртуальных машин.

Рекомендуем изучить [документацию сетевого балансировщика нагрузки](https://cloud.yandex.ru/docs/network-load-balancer/quickstart) для того, чтобы было понятно, что вы сделали.

2. Установите на созданные виртуальные машины пакет Nginx любым удобным способом и запустите Nginx веб-сервер на порту 80.

3. Перейдите в веб-консоль Yandex Cloud и убедитесь, что: 

- созданный балансировщик находится в статусе Active,
- обе виртуальные машины в целевой группе находятся в состоянии healthy.

4. Сделайте запрос на 80 порт на внешний IP-адрес балансировщика и убедитесь, что вы получаете ответ в виде дефолтной страницы Nginx.

*В качестве результата пришлите:*

*1. Terraform Playbook.*

*2. Скриншот статуса балансировщика и целевой группы.*

*3. Скриншот страницы, которая открылась при запросе IP-адреса балансировщика.*

-----

### ОТВЕТ:

#   План действий (Workflow):

    Написание кода: Создаем 3 файла: main.tf (инфраструктура), hosts.tftpl (шаблон для Ansible) и playbook.yml (настройка Nginx).
    Проверка: terraform plan (смотрим, что создастся 2 ВМ и балансировщик).
    Запуск: terraform apply (Terraform создает облако, создает файл hosts.ini, ждет 60 сек запускает Ansible).

1. Файл `main.tf`

```config

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

```

2. Файл `hosts.tftp`l (Шаблон для Ansible)

```config

[web]
%{ for vm in web_vms ~}
${vm.name} ansible_host=${vm.network_interface.0.nat_ip_address}
%{ endfor ~}

[web:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
# Отключаем проверку ключа, чтобы Ansible не спрашивал "yes/no" при первом входе
ansible_ssh_common_args='-o StrictHostKeyChecking=no'

```
3. Файл `playbook.yml` (Инструкция для Ansible)

```config

- name: Install Nginx
  hosts: web # Применить ко всем машинам из группы [web]
  become: true # Запускать команды от имени root (sudo)
  tasks:
    - name: Update apt and install nginx
      apt:
        name: nginx
        state: present
        update_cache: true

    - name: Start nginx
      service:
        name: nginx
        state: started
        enabled: true
    # Записываем имя хоста в главную страницу
    - name: Create custom index.html with hostname
      copy:
        content: "<h1>Hello from {{ inventory_hostname }}</h1>"
        dest: /var/www/html/index.html
        mode: '0644'

```

4. Запускаем создание ресурсов в облаке команда `terraform apply`

<summary>Результат развертывания в облаке</summary>
<img src="img/1.jpg" width = 100%>


<summary>Проверка работоспособности балансировщика из консоли</summary>
<img src="img/2.jpg" width = 100%>

<summary>Проверка работоспособности балансировщика <hfepth</summary>
<img src="img/3.jpg" width = 100%>

<summary>ВМ в облаке <hfepth</summary>
<img src="img/4.jpg" width = 100%>

<summary>Балансировщик в облаке <hfepth</summary>
<img src="img/5.jpg" width = 100%>



<details>
<summary><d>Для себя</d></summary>

# 🛸 Шпаргалка: Yandex Cloud + Terraform + Ansible

Этот документ содержит описание логики, параметров и команд для развертывания отказоустойчивой инфраструктуры.

---

## 🏗 1. Логика работы (Workflow)
1. **Terraform**: Создает сеть, подсеть, 2 виртуальные машины (через `count`) и балансировщик (LBO).
2. **Inventory**: Terraform автоматически создает файл `hosts.ini`, подставляя туда IP-адреса созданных машин.
3. **Ansible**: Заходит на машины через 60 секунд после их создания и устанавливает Nginx.

---

## 🛠 2. Справочник ресурсов Terraform (Yandex Cloud)


| Ресурс | Описание | Ключевые параметры |
| :--- | :--- | :--- |
| `yandex_vpc_network` | Виртуальная сеть | `name` — имя сети. |
| `yandex_vpc_subnet` | Подсеть проекта | `v4_cidr_blocks` (напр. `10.0.1.0/24`), `zone`. |
| `yandex_compute_instance` | Виртуальная машина | `count` — кол-во ВМ, `nat = true` — дает внешний IP. |
| `yandex_lb_target_group` | Целевая группа | `target` — список внутренних IP-адресов ВМ. |
| `yandex_lb_network_load_balancer` | Балансировщик | `listener` (порт 80), `healthcheck` (проверка связи). |

**Важные настройки метаданных ВМ:**
* `ssh-keys`: Доступ в формате `"user:${file("~/.ssh/id_rsa.pub")}"`.
* `preemptible = true`: Экономия 50% бюджета (прерываемая машина).

---

## 📦 3. Справочник модулей Ansible


| Модуль | Действие | Пример параметров |
| :--- | :--- | :--- |
| **apt** | Установка софта | `name: nginx`, `state: present`, `update_cache: yes`. |
| **service** | Управление службами | `name: nginx`, `state: started`, `enabled: yes`. |
| **copy** | Создание файлов | `content: "Hello"`, `dest: /var/www/html/index.html`. |
| **local-exec** (в TF) | Запуск из консоли | `command: "ansible-playbook -i hosts.ini playbook.yml"`. |

---

## 💻 4. Основные команды терминала (Debian 13)

### Подготовка и запуск
```bash
# 1. Авторизация (токен живет 24 часа)
export YC_TOKEN=$(yc config get token)

# 2. Инициализация (скачивание плагинов)
terraform init -upgrade

# 3. Развертывание (ВМ + Балансировщик + Ansible)
terraform apply -auto-approve

# 4. Удаление (чтобы не тратить деньги)
terraform destroy -auto-approve
```
</details>
</details>

------
------


<details>
<summary><b>Задание 2*</b></summary>

1. Теперь вместо создания виртуальных машин создайте [группу виртуальных машин с балансировщиком нагрузки](https://cloud.yandex.ru/docs/compute/operations/instance-groups/create-with-balancer).

2. Nginx нужно будет поставить тоже автоматизированно. Для этого вам нужно будет подложить файл установки Nginx в user-data-ключ [метадаты](https://cloud.yandex.ru/docs/compute/concepts/vm-metadata) виртуальной машины.

- [Пример файла установки Nginx](https://github.com/nar3k/yc-public-tasks/blob/master/terraform/metadata.yaml).
- [Как подставлять файл в метадату виртуальной машины.](https://github.com/nar3k/yc-public-tasks/blob/a6c50a5e1d82f27e6d7f3897972adb872299f14a/terraform/main.tf#L38)

3. Перейдите в веб-консоль Yandex Cloud и убедитесь, что: 

- созданный балансировщик находится в статусе Active,
- обе виртуальные машины в целевой группе находятся в состоянии healthy.

4. Сделайте запрос на 80 порт на внешний IP-адрес балансировщика и убедитесь, что вы получаете ответ в виде дефолтной страницы Nginx.

*В качестве результата пришлите*

*1. Terraform Playbook.*

*2. Скриншот статуса балансировщика и целевой группы.*

*3. Скриншот страницы, которая открылась при запросе IP-адреса балансировщика.*

------

## ОТВЕТ:

# 🛸 

Этот проект реализует автоматизированную группу виртуальных машин с сетевым балансировщиком нагрузки. Настройка серверов (установка Nginx) происходит автоматически при загрузке.

---

<details>
<summary><b>📖 Описание логики работы (Architecture)</b></summary>

### Ключевые особенности:
1. **Instance Group (IG)**: Мы используем облачный "автопилот". Если одна машина выйдет из строя, облако само её пересоздаст.
2. **Вменяемые имена**: Благодаря маске `web-{instance.index}`, машины получают понятные имена в консоли и внутри системы (`web-1`, `web-2`).
3. **Cloud-init (User Data)**: Установка Nginx и кастомизация страницы приветствия прописаны в файле `userdata.yaml`. Это позволяет вводить машины в строй без ручного запуска Ansible.
4. **Service Account**: Для работы группы машин создан отдельный сервисный аккаунт с правами `editor`.

</details>

---

<details>
<summary><b>🛠 Конфигурация ресурсов (Terraform)</b></summary>

### Основные компоненты `main.tf`:
* **yandex_compute_instance_group**: Управляет жизненным циклом двух ВМ.
* **yandex_lb_network_load_balancer**: Принимает внешний трафик на порт 80 и распределяет его между машинами группы.
* **depends_on**: Используется для соблюдения строгой очередности (сначала права доступа, потом группа машин, затем балансировщик).

</details>

---

<details>
<summary><b>📄 Скрипт автоматизации (userdata.yaml)</b></summary>

```yaml
#cloud-config
package_update: true
packages:
  - nginx
runcmd:
  - [ systemctl, enable, nginx ]
  - [ systemctl, start, nginx ]
  - [ sh, -c, "echo '<html><head><meta charset=\"utf-8\"></head><body><h1>Привет! Сервер отвечает: $(hostname)</h1></body></html>' > /var/www/html/index.html" ]
```



</details>
