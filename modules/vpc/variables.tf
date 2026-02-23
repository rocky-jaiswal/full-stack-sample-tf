variable "environment" {
  type = string
}

variable "project_name" {
  type    = string
  default = "app-eks"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["eu-central-1a", "eu-central-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/19", "10.0.32.0/19"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.64.0/19", "10.0.96.0/19"]
}

variable "isolated_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.128.0/19", "10.0.160.0/19"]
}
