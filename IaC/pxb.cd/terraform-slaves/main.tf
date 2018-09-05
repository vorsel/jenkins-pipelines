# Specify the provider and access details
provider "aws" {
  region = "${var.aws_region}"
}

# Request a Spot fleet
resource "aws_spot_fleet_request" "min-x64" {
  count = "${length(var.oses)}"

  allocation_strategy                 = "lowestPrice"
  excess_capacity_termination_policy  = "Default"
  iam_fleet_role                      = "arn:aws:iam::119175775298:role/jenkins-pxb-SpotFleet"  # !!!!!!!!!!!!
  replace_unhealthy_instances         = "true"
  spot_price                          = "0.2"
  target_capacity                     = 0
  terminate_instances_with_expiration = "false"
  fleet_type                          = "maintain"
  valid_until                         = "2018-09-01T00:00:00Z"

  launch_specification {
    instance_type                     = "m4.2xlarge"
    ami                               = "${lookup(local.aws_amis, "${element(var.oses, count.index)}")}"
    subnet_id                         = "subnet-0e37267392583e6d7" # !!!!!!!!!!!!!!!!!!!!!!
    vpc_security_group_ids            = [ "sg-0af219148b58e7954" ] # !!!!!!!!!!!!!!!!!!!!!!
    iam_instance_profile_arn          = "arn:aws:iam::119175775298:instance-profile/jenkins-pxb-slave" # !!!!!!!!!!!!!
    ebs_optimized                     = "true"
    key_name                          = "${var.key_name}"
    monitoring                        = "false"
    user_data                         = "${lookup(local.user_data, "${element(var.oses, count.index)}")}"
    associate_public_ip_address       = "true"
    ebs_block_device {
      device_name                     = "/dev/xvdd"
      volume_type                     = "gp2"
      volume_size                     = "80"
    }
    tags {
      Name                            = "min-${element(var.oses, count.index)}-x64"
      iit-billing-tag                 = "jenkins-pxb-worker"
    }
  }
}
