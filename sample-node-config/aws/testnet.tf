provider "aws" {
  profile = var.profile
  region  = var.region
}

locals {
  userdata = templatefile("scripts/user_data.sh", {
    ssm_cloudwatch_config = aws_ssm_parameter.cw_agent.name
  })
  private_key = "./env/${var.key_name}.pem"
  tag         = "hydraw-${var.key_name}"
}

output "instance_dns" {
  value = aws_instance.hydra.public_dns
}

resource "aws_eip" "hydra_lb" {
  instance = aws_instance.hydra.id
  vpc      = true
}

output "instance_ip" {
  value = aws_eip.hydra_lb.public_ip
}

resource "aws_instance" "hydra" {
  ami                         = var.ami
  instance_type               = var.instance_type
  key_name                    = var.key_name
  security_groups             = ["${aws_security_group.hydra-sg.id}"]
  subnet_id                   = aws_subnet.hydra-subnet.id
  associate_public_ip_address = true

  provisioner "file" {
    source      = "scripts/"
    destination = "/home/ubuntu"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local.private_key)
      timeout     = "2m"
      agent       = false
      host        = self.public_ip
    }
  }

  provisioner "file" {
    source      = "credentials/"
    destination = "/home/ubuntu"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local.private_key)
      timeout     = "2m"
      agent       = false
      host        = self.public_ip
    }
  }

  provisioner "file" {
    source      = "docker/"
    destination = "/home/ubuntu"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local.private_key)
      timeout     = "2m"
      agent       = false
      host        = self.public_ip
    }
  }

  provisioner "file" {
    source      = "../../hydra-cluster/config/devnet/genesis-shelley.json"
    destination = "/home/ubuntu/genesis-shelley.json"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local.private_key)
      timeout     = "2m"
      agent       = false
      host        = self.public_ip
    }
  }

  provisioner "file" {
    source      = "../../hydra-cluster/config/protocol-parameters.json"
    destination = "/home/ubuntu/protocol-parameters.json"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local.private_key)
      timeout     = "2m"
      agent       = false
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "find /home/ubuntu -type f -iname \"*.sh\" -exec chmod +x {} +"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local.private_key)
      timeout     = "2m"
      agent       = false
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "/home/ubuntu/configure-instance.sh"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local.private_key)
      timeout     = "2m"
      agent       = false
      host        = self.public_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "/home/ubuntu/configure-testnet.sh ${var.gh_account}"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local.private_key)
      timeout     = "2m"
      agent       = false
      host        = self.public_ip
    }
  }

  iam_instance_profile = aws_iam_instance_profile.this.name
  user_data            = local.userdata

  tags = {
    Name = local.tag
  }
}
