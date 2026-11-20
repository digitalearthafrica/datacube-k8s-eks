data "aws_ami" "eks_worker" {
  filter {
    name = "name"
    values = [
      var.al2023_enabled
      ? "amazon-eks-node-al2023-x86_64-standard-${var.cluster_version}-v*"
      : "amazon-eks-node-${var.cluster_version}-v*"
    ]
  }

  most_recent = true
  owners      = ["602401143452", "877085696533"] # Amazon EKS AMI Account ID
}

# EKS currently documents this required userdata for EKS worker nodes to
# properly configure Kubernetes applications on the EC2 instance.
# We utilize a Terraform local here to simplify Base64 encoding this
# information into the AutoScaling Launch Template.
# More information: https://docs.aws.amazon.com/eks/latest/userguide/launch-workers.html
locals {
  # return first non-empty value
  ami_id = coalesce(var.ami_image_id, data.aws_ami.eks_worker.id)

  al2_node_userdata = <<USERDATA
#!/bin/bash
set -o xtrace
# Get instance and ami id from the aws ec2 metadate endpoint
id=$(curl http://169.254.169.254/latest/meta-data/instance-id -s)
ami=$(curl http://169.254.169.254/latest/meta-data/ami-id -s)
/etc/eks/bootstrap.sh --apiserver-endpoint '${aws_eks_cluster.eks.endpoint}' --b64-cluster-ca '${aws_eks_cluster.eks.certificate_authority[0].data}' '${aws_eks_cluster.eks.id}' ${var.extra_bootstrap_args} \
  --kubelet-extra-args "--node-labels=cluster=${aws_eks_cluster.eks.id},nodegroup=${var.node_group_name},nodetype=ondemand,instance-id=$id,ami-id=$ami \
  ${var.extra_kubelet_args}"
${var.extra_userdata}
USERDATA

  al2_spot_userdata = <<USERDATA
#!/bin/bash
set -o xtrace
# Get instance and ami id from the aws ec2 metadate endpoint
id=$(curl http://169.254.169.254/latest/meta-data/instance-id -s)
ami=$(curl http://169.254.169.254/latest/meta-data/ami-id -s)
/etc/eks/bootstrap.sh --apiserver-endpoint '${aws_eks_cluster.eks.endpoint}' --b64-cluster-ca '${aws_eks_cluster.eks.certificate_authority[0].data}' '${aws_eks_cluster.eks.id}' ${var.extra_bootstrap_args} \
  --kubelet-extra-args "--node-labels=cluster=${aws_eks_cluster.eks.id},nodegroup=${var.node_group_name},nodetype=spot,instance-id=$id,ami-id=$ami \
  ${var.extra_kubelet_args}"
${var.extra_userdata}
USERDATA

  # nodeadm-config.service reads user data before cloud-init, so instance-id and
  # ami-id cannot be resolved into NodeConfig. Those labels stay on the AL2 path.
  # Each extra_kubelet_args token is its own kubelet flag.
  al2023_kubelet_flags = {
    for nodetype in ["ondemand", "spot"] : nodetype => concat(
      ["--node-labels=cluster=${aws_eks_cluster.eks.id},nodegroup=${var.node_group_name},nodetype=${nodetype}"],
      regexall("\\S+", var.extra_kubelet_args)
    )
  }

  al2023_userdata = {
    for nodetype, flags in local.al2023_kubelet_flags : nodetype => join("", [
      "MIME-Version: 1.0\n",
      "Content-Type: multipart/mixed; boundary=\"BOUNDARY\"\n",
      "\n",
      "--BOUNDARY\n",
      "Content-Type: application/node.eks.aws\n",
      "\n",
      "---\n",
      yamlencode({
        apiVersion = "node.eks.aws/v1alpha1"
        kind       = "NodeConfig"
        spec = {
          cluster = {
            name                 = aws_eks_cluster.eks.id
            apiServerEndpoint    = aws_eks_cluster.eks.endpoint
            certificateAuthority = aws_eks_cluster.eks.certificate_authority[0].data
            cidr                 = aws_eks_cluster.eks.kubernetes_network_config[0].service_ipv4_cidr
          }
          kubelet = {
            flags = flags
          }
        }
      }),
      "--BOUNDARY\n",
      "Content-Type: text/x-shellscript\n",
      "\n",
      "#!/bin/bash\n",
      "set -o xtrace\n",
      var.extra_userdata,
      "\n",
      "--BOUNDARY--\n",
    ])
  }

  eks-node-userdata = var.al2023_enabled ? local.al2023_userdata["ondemand"] : local.al2_node_userdata
  eks-spot-userdata = var.al2023_enabled ? local.al2023_userdata["spot"] : local.al2_spot_userdata

}

resource "aws_launch_template" "node" {
  name_prefix            = aws_eks_cluster.eks.id
  image_id               = local.ami_id
  user_data              = base64encode(local.eks-node-userdata)
  instance_type          = var.default_worker_instance_type
  update_default_version = var.update_default_version

  metadata_options {
    http_endpoint               = lookup(var.metadata_options, "http_endpoint", null)
    http_tokens                 = lookup(var.metadata_options, "http_tokens", null)
    http_put_response_hop_limit = lookup(var.metadata_options, "http_put_response_hop_limit", null)
    http_protocol_ipv6          = lookup(var.metadata_options, "http_protocol_ipv6", null)
    instance_metadata_tags      = lookup(var.metadata_options, "instance_metadata_tags", null)
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.eks_node.id
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.eks_node.id]
    delete_on_termination       = true
  }

  lifecycle {
    create_before_destroy = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = var.volume_encrypted != null ? var.volume_encrypted : null
      volume_size = var.volume_size
      volume_type = var.volume_type != "" ? var.volume_type : null
    }
  }

}

resource "aws_launch_template" "spot" {
  count         = var.spot_nodes_enabled ? 1 : 0
  name_prefix   = aws_eks_cluster.eks.id
  image_id      = local.ami_id
  user_data     = base64encode(local.eks-spot-userdata)
  instance_type = var.default_worker_instance_type

  metadata_options {
    http_endpoint               = lookup(var.metadata_options, "http_endpoint", null)
    http_tokens                 = lookup(var.metadata_options, "http_tokens", null)
    http_put_response_hop_limit = lookup(var.metadata_options, "http_put_response_hop_limit", null)
    http_protocol_ipv6          = lookup(var.metadata_options, "http_protocol_ipv6", null)
    instance_metadata_tags      = lookup(var.metadata_options, "instance_metadata_tags", null)
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.eks_node.id
  }

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price = var.max_spot_price
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.eks_node.id]
    delete_on_termination       = true
  }

  lifecycle {
    create_before_destroy = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = var.volume_encrypted != null ? var.volume_encrypted : null
      volume_size = var.spot_volume_size
      volume_type = var.volume_type != "" ? var.volume_type : null
    }
  }

}

