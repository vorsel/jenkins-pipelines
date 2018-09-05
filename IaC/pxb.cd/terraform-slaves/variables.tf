variable "key_name" {
  description = "Desired name of AWS key pair"
  default     = "jenkins"
}

variable "aws_region" {
  description = "AWS region to launch servers."
  default     = "us-west-2"
}

variable "oses" {
  type = "list"
  default = [ "centos-6", "centos-7", "jessie", "stretch", "trusty", "xenial", "artful", "bionic" ]
}
