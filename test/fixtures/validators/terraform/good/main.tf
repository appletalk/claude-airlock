terraform {
  required_version = ">= 1.0"
}

variable "name" {
  type    = string
  default = "airlock"
}

output "name" {
  value = var.name
}
