terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "=3.42.0"
    }
  }
}

# NOTE: This stack manages resources in two AWS regions:
#   - var.region (default: us-east-1) for the primary infrastructure below.
#   - us-west-2 (via the aws.us_west_2 provider alias) for the pre-existing SNS topic.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      RepositoryId = "amsgitops/hashicat-aws"
    }
  }
}

# Hardcoded to us-west-2 because the SNS topic predates this stack and lives in a fixed region.
# Intentionally uses the same ambient credentials as the default provider.
# The IAM principal must have sns:SetTopicAttributes permissions in us-west-2.
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

# Manages the existing SNS topic in us-west-2.
# - display_name is Terraform-authoritative: Terraform will enforce "CodeKeeper E2E 1778726225"
#   on the first apply after import. Run `terraform plan` post-import and verify the displayed
#   change is intentional before applying.
# - name is immutable in AWS SNS. Changing it would force resource replacement, which
#   prevent_destroy will block with a hard error. Do not rename this resource.
# - prevent_destroy = true means `terraform destroy` on this workspace will always fail.
#   To decommission this topic, remove prevent_destroy from this block first.
# Import with: terraform import aws_sns_topic.codekeeper_test_alerts arn:aws:sns:us-west-2:<ACCOUNT_ID>:codekeeper-test-alerts
resource "aws_sns_topic" "codekeeper_test_alerts" {
  provider     = aws.us_west_2
  name         = "codekeeper-test-alerts"
  display_name = "CodeKeeper E2E 1778726225"

  lifecycle {
    prevent_destroy = true
    # Ignore delivery/feedback attributes and tags that may be managed outside Terraform
    # to avoid unintended drift after import.
    # kms_master_key_id is intentionally NOT ignored so Terraform enforces encryption state.
    # Note: application_* and firehose_* feedback attributes are excluded because they
    # require provider >= 3.43.0 and this stack is pinned to 3.42.0.
    ignore_changes = [
      tags,
      tags_all,
      delivery_policy,
      lambda_failure_feedback_role_arn,
      lambda_success_feedback_role_arn,
      lambda_success_feedback_sample_rate,
      sqs_failure_feedback_role_arn,
      sqs_success_feedback_role_arn,
      sqs_success_feedback_sample_rate,
      http_failure_feedback_role_arn,
      http_success_feedback_role_arn,
      http_success_feedback_sample_rate,
    ]
  }
}
