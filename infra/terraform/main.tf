# ── Default VPC + Internet Gateway ───────────────────────────────
data "aws_vpc" "default" {
  default = true
}

# A default VPC always already has an internet gateway attached. Creating a
# second one fails with "VPC already has an internet gateway attached" and
# leaves a dangling, tainted resource, so reference the existing IGW instead
# of managing our own.
data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── Main route table — clears blackhole, routes internet via IGW ──
data "aws_route_table" "main" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

resource "aws_route" "internet" {
  route_table_id         = data.aws_route_table.main.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.default.id
}

# ── AMI — latest Amazon Linux 2023 for the instance's CPU arch ────
# Graviton (t4g, …) types need the arm64 AMI; the app images are multi-arch.
data "aws_ec2_instance_type" "app" {
  instance_type = var.instance_type
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-${local.arch}"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── IAM role — EC2 reads SSM secrets at boot ─────────────────────
resource "aws_iam_role" "skybroe_ec2" {
  name = "skybroe-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge({ Name = "skybroe-ec2-role" }, local.protect)

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "ssm_read" {
  name = "skybroe-ssm-read"
  role = aws_iam_role.skybroe_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters"
      ]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter${var.ssm_prefix}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.skybroe_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Registers the instance with SSM so the CloudWatch-agent associations in
# monitoring.tf can run (and enables keyless Session Manager shell access).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.skybroe_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.skybroe_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "ses_send" {
  name = "skybroe-ses-send"
  role = aws_iam_role.skybroe_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "skybroe_ec2" {
  name = "skybroe-ec2-profile"
  role = aws_iam_role.skybroe_ec2.name

  tags = merge({ Name = "skybroe-ec2-profile" }, local.protect)

  lifecycle {
    prevent_destroy = true
  }
}

# ── Security group ────────────────────────────────────────────────
resource "aws_security_group" "skybroe" {
  name        = "skybroe-sg"
  description = "Skybroe: HTTP + HTTPS inbound, SSH restricted"
  vpc_id      = data.aws_vpc.default.id

  # Caddy on the instance terminates TLS (no ALB). Port 80 stays open for
  # Let's Encrypt HTTP-01 challenges and the redirect to HTTPS. The backend
  # (3001) is no longer exposed — Caddy reaches it on the Docker network.
  ingress {
    description = "HTTP (ACME challenge + redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "skybroe-sg" }, local.protect)

  lifecycle {
    prevent_destroy = true
  }
}

# ── App subnet — an AZ that actually offers var.instance_type ─────
# Not every AZ carries every type (e.g. t3 is absent from us-east-1e), and an
# unpinned launch can land in one that doesn't, failing the apply.
data "aws_ec2_instance_type_offerings" "app" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_subnets" "app" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.app.locations
  }
}

# ── EC2 instance ──────────────────────────────────────────────────
resource "aws_instance" "skybroe" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.skybroe_ec2.name
  vpc_security_group_ids = [aws_security_group.skybroe.id]
  subnet_id              = sort(data.aws_subnets.app.ids)[0]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  # IMDSv2 required; hop limit 2 so Docker containers can reach the instance
  # metadata service to assume the role (e.g. the SES send permission).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Bootstrap only (Docker, swap, systemd unit). The deploy job ships the
  # compose file + Caddyfile from infra/ and writes .env.
  user_data = file("${path.module}/user_data.sh")

  tags = { Name = "skybroe-app" }

  lifecycle {
    prevent_destroy = true
    # subnet_id: a later instance_type change may shift the eligible AZs;
    # moving subnets would force a replacement that prevent_destroy blocks.
    ignore_changes = [ami, user_data, subnet_id]
  }
}

# ── Elastic IP (pre-existing, managed outside Terraform) ─────────
data "aws_eip" "skybroe" {
  public_ip = var.app_eip
}

resource "aws_eip_association" "skybroe" {
  instance_id   = aws_instance.skybroe.id
  allocation_id = data.aws_eip.skybroe.id
  # No ignore_changes here: if the instance is recreated (e.g. after a cleanup
  # cycle), the association must re-point to the new instance, otherwise the
  # new server comes up without the Elastic IP and the SSH deploy fails.
}
