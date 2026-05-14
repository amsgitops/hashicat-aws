terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "=3.42.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      RepositoryId = "amsgitops/hashicat-aws"
    }
  }
}

# Hardcoded to us-west-2 to match the existing SNS topic:
# arn:aws:sns:us-west-2:...:codekeeper-test-alerts
provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"

  default_tags {
    tags = {
      RepositoryId = "amsgitops/hashicat-aws"
    }
  }
}

resource "aws_vpc" "hashicat" {
  cidr_block           = var.address_space
  enable_dns_hostnames = true

  tags = {
    name        = "${var.prefix}-vpc-${var.region}"
    environment = "Production"
    TestTag     = "github-actions-test"
  }
}

resource "aws_subnet" "hashicat" {
  vpc_id     = aws_vpc.hashicat.id
  cidr_block = var.subnet_prefix

  tags = {
    name = "${var.prefix}-subnet"
  }
}

resource "aws_security_group" "hashicat" {
  name = "${var.prefix}-security-group"

  vpc_id = aws_vpc.hashicat.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
    prefix_list_ids = []
  }

  tags = {
    Name = "${var.prefix}-security-group"
  }
}

resource "aws_internet_gateway" "hashicat" {
  vpc_id = aws_vpc.hashicat.id

  tags = {
    Name = "${var.prefix}-internet-gateway"
  }
}

resource "aws_route_table" "hashicat" {
  vpc_id = aws_vpc.hashicat.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hashicat.id
  }
}

resource "aws_route_table_association" "hashicat" {
  subnet_id      = aws_subnet.hashicat.id
  route_table_id = aws_route_table.hashicat.id
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name = "name"
    #values = ["ubuntu/images/hvm-ssd/ubuntu-disco-19.04-amd64-server-*"]
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_eip" "hashicat" {
  instance = aws_instance.hashicat.id
  vpc      = true
}

resource "aws_eip_association" "hashicat" {
  instance_id   = aws_instance.hashicat.id
  allocation_id = aws_eip.hashicat.id
}

resource "aws_instance" "hashicat" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.hashicat.key_name
  associate_public_ip_address = true
  subnet_id                   = aws_subnet.hashicat.id
  vpc_security_group_ids      = [aws_security_group.hashicat.id]

  tags = {
    Name = "${var.prefix}-hashicat-instance"
  }
}

# We're using a little trick here so we can run the provisioner without
# destroying the VM. Do not do this in production.

# If you need ongoing management (Day N) of your virtual machines a tool such
# as Chef or Puppet is a better choice. These tools track the state of
# individual files and can keep them in the correct configuration.

# Here we do the following steps:
# Sync everything in files/ to the remote VM.
# Set up some environment variables for our script.
# Add execute permissions to our scripts.
# Run the deploy_app.sh script.
resource "null_resource" "configure-cat-app" {
  depends_on = [aws_eip_association.hashicat]

  triggers = {
    build_number = timestamp()
  }

  provisioner "file" {
    source      = "files/"
    destination = "/home/ubuntu/"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.hashicat.private_key_pem
      host        = aws_eip.hashicat.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt -y update",
      "sleep 15",
      "sudo apt -y update",
      "sudo apt -y install apache2",
      "sudo systemctl start apache2",
      "sudo chown -R ubuntu:ubuntu /var/www/html",
      "chmod +x *.sh",
      "PLACEHOLDER=${var.placeholder} WIDTH=${var.width} HEIGHT=${var.height} PREFIX=${var.prefix} ./deploy_app.sh",
      "sudo apt -y install cowsay",
      "cowsay Mooooooooooo!",
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = tls_private_key.hashicat.private_key_pem
      host        = aws_eip.hashicat.public_ip
    }
  }
}

resource "tls_private_key" "hashicat" {
  algorithm = "ED25519"
}

locals {
  private_key_filename = "${var.prefix}-ssh-key.pem"
}

resource "aws_key_pair" "hashicat" {
  key_name   = local.private_key_filename
  public_key = tls_private_key.hashicat.public_key_openssh
}

# Resolve the caller's account ID using the us-west-2 provider so the value
# is authoritative for the SNS resources below.
data "aws_caller_identity" "current" {
  provider = aws.us_west_2
}

# Bring the existing SNS topic under Terraform management.
# IMPORTANT: Before the first `terraform apply`, import the existing topic:
#   terraform import aws_sns_topic.codekeeper_test_alerts \
#     arn:aws:sns:us-west-2:<account_id>:codekeeper-test-alerts
#
# Explicit tags are omitted: aws_sns_topic tag support requires provider
# >= 3.43.0; the RepositoryId tag is applied via provider default_tags.
#
# NOTE: The Terraform execution role must have sns:SetTopicAttributes granted
# via its IAM identity policy to allow Terraform to update display_name and
# other topic attributes. This action is intentionally excluded from the
# resource-based policy below (it is not needed there for same-account callers).
resource "aws_sns_topic" "codekeeper_test_alerts" {
  provider     = aws.us_west_2
  name         = "codekeeper-test-alerts"
  display_name = var.sns_codekeeper_display_name
}

# Least-privilege resource-based policy for the codekeeper-test-alerts topic.
#
# Access is restricted to the account root (covers all IAM principals in the
# account subject to their identity policies). Administrative and destructive
# actions (DeleteTopic, SetTopicAttributes, AddPermission, RemovePermission)
# are intentionally excluded here; they must be granted via IAM identity
# policies on specific roles.
#
# No AWS service principals (e.g. cloudwatch.amazonaws.com) are required for
# this topic at this time. If a service integration is added in future, append
# a new Statement block with the appropriate Service principal and an
# aws:SourceAccount condition to prevent confused-deputy attacks.
#
# IMPORTANT: This resource replaces the entire existing topic policy on apply.
# Verify the current policy in AWS before applying to avoid removing any
# existing service-principal grants.
resource "aws_sns_topic_policy" "codekeeper_test_alerts" {
  provider = aws.us_west_2
  arn      = aws_sns_topic.codekeeper_test_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowTopicOwnerPublishSubscribe"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "SNS:Publish",
          "SNS:Subscribe",
          "SNS:Receive",
          "SNS:GetTopicAttributes",
          "SNS:ListSubscriptionsByTopic",
        ]
        Resource = aws_sns_topic.codekeeper_test_alerts.arn
      }
    ]
  })
}
