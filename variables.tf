variable "flow" {
  type    = string
  default = "24-01"
}

variable "cloud_id" {
  type    = string
  default = "b1g38eh5o8im8vjc1r2d" #идентификатор облака
}
variable "folder_id" {
  type    = string
  default = "b1ghkk8deprh76olu1sh" #идентификатор каталога
}

variable "test" {
  type = map(number)
  default = {
    cores         = 2
    memory        = 1
    core_fraction = 20
  }
}

