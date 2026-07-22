terraform {
  required_version = ">= 1.0"
}

variable "unused" {
  type = string
}

output "greeting" {
  value = "${"hello"}"
}
