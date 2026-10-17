locals {
  # Applied to every free (zero-cost) resource so the cleanup workflow
  # and manual audits can identify what must never be deleted.
  protect = { do_not_delete = "true" }

  # SES sender for transactional email (password reset). Defaults to
  # noreply@<domain_name>, which the SES domain identity verifies.
  ses_from_email = var.ses_from_email != "" ? var.ses_from_email : "noreply@${var.domain_name}"

  # The ALB needs 2 AZs; each enabled AZ costs a public IPv4 address, so use
  # exactly two. The instance's own subnet must be one of them — an ALB does
  # not route to targets in AZs it is not enabled in. (Default-VPC subnets are
  # one per AZ, so two distinct subnets are always two distinct AZs.)
  alb_subnets = slice(
    distinct(concat([aws_instance.skybroe.subnet_id], sort(data.aws_subnets.default.ids))),
    0, 2
  )
}
