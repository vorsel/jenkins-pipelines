data "template_file" "user_data_debian_new" {
    template = "${file("user_data/debian-new.sh")}"
}

data "template_file" "user_data_debian_old" {
    template = "${file("user_data/debian-old.sh")}"
}

data "template_file" "user_data_centos" {
    template = "${file("user_data/centos.sh")}"
}

locals {
  user_data = {
      centos-6-x32 = "${data.template_file.user_data_centos.rendered}"
      centos-6     = "${data.template_file.user_data_centos.rendered}"
      centos-7     = "${data.template_file.user_data_centos.rendered}"

      jessie       = "${data.template_file.user_data_debian_old.rendered}"
      stretch      = "${data.template_file.user_data_debian_new.rendered}"

      trusty       = "${data.template_file.user_data_debian_old.rendered}"
      xenial       = "${data.template_file.user_data_debian_new.rendered}"
      artful       = "${data.template_file.user_data_debian_new.rendered}"
      bionic       = "${data.template_file.user_data_debian_new.rendered}"
  }
}
