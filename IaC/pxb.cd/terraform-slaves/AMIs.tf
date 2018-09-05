data "aws_ami" "centos-6-x32" {
  most_recent = true
  filter {
    name   = "product-code"
    values = ["pwwpwelgj5jk5cie2erh4h3e"]
  }
}

data "aws_ami" "centos-6" {
  most_recent = true
  filter {
    name   = "product-code"
    values = ["6x5jmcajty9edm3f211pqjfn2"]
  }
}

data "aws_ami" "centos-7" {
  most_recent = true
  filter {
    name   = "product-code"
    values = ["aw0evgkw8e5c1q413zgy5pjce"]
  }
}

data "aws_ami" "jessie" {
  most_recent = true
  filter {
    name   = "product-code"
    values = ["3f8t6t8fp5m9xx18yzwriozxi"]
  }
}

data "aws_ami" "stretch" {
  most_recent = true
  filter {
    name   = "product-code"
    values = ["55q52qvgjfpdj2fpfy9mb1lo4"]
  }
}

data "aws_ami" "trusty" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-trusty-14.04-amd64-server-*"]
  }
}

data "aws_ami" "xenial" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }
}

data "aws_ami" "artful" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-artful-17.10-amd64-server-*"]
  }
}

data "aws_ami" "bionic" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }
}

locals {
  aws_amis = {
      centos-6-x32 = "ami-cb1382fb"
      centos-6     = "${data.aws_ami.centos-6.id}"
      centos-7     = "${data.aws_ami.centos-7.id}"

      jessie       = "${data.aws_ami.jessie.id}"
      stretch      = "${data.aws_ami.stretch.id}"

      trusty       = "${data.aws_ami.trusty.id}"
      xenial       = "${data.aws_ami.xenial.id}"
      artful       = "${data.aws_ami.artful.id}"
      bionic       = "${data.aws_ami.bionic.id}"
  }
}
