output "oses" {
  value = ["${var.oses}"]
}
output "fleet" {
  value = ["${aws_spot_fleet_request.min-x64.*.id}"]
}
