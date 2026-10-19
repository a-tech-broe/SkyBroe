locals {
  # Applied to every free (zero-cost) resource so the cleanup workflow
  # and manual audits can identify what must never be deleted.
  protect = { do_not_delete = "true" }

  # CPU architecture of var.instance_type — selects the matching AMI.
  arch = contains(data.aws_ec2_instance_type.app.supported_architectures, "arm64") ? "arm64" : "x86_64"
}
