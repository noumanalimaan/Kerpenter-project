# karpenter.tf

# Karpenter IAM Role
resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeInstanceProfile-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_ssm_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "KarpenterNodeInstanceProfile-${var.cluster_name}"
  role = aws_iam_role.karpenter_node.name
}

# Karpenter Controller IAM Role
resource "aws_iam_role" "karpenter_controller" {
  name = "karpenter-controller-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}"
      }
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_policy" "karpenter_controller" {
  name = "karpenter-controller-${var.cluster_name}"

  policy = jsonencode({
    Statement = [
      {
        Action = [
          "ssm:GetParameter",
          "ec2:DescribeImages",
          "ec2:RunInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "iam:PassRole",
          "eks:DescribeCluster"
        ]
        Effect   = "Allow"
        Resource = "*"
        Sid      = "Karpenter"
      },
      {
        Action = "ec2:TerminateInstances"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/karpenter.sh/provisioner-name" = "*"
          }
        }
        Effect   = "Allow"
        Resource = "*"
        Sid      = "ConditionalEC2Termination"
      }
    ]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  policy_arn = aws_iam_policy.karpenter_controller.arn
  role       = aws_iam_role.karpenter_controller.name
}

# OIDC Provider
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.cluster_name}-eks-irsa"
  }
}

# Helm provider configuration
provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
    }
  }
}

provider "kubectl" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
  }
}

# Install Karpenter
resource "helm_release" "karpenter" {
  namespace  = "karpenter"
  create_namespace = true
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  wait       = false

  values = [
    <<-EOT
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${aws_iam_role.karpenter_controller.arn}
    settings:
      clusterName: ${aws_eks_cluster.main.name}
      clusterEndpoint: ${aws_eks_cluster.main.endpoint}
      defaultInstanceProfile: ${aws_iam_instance_profile.karpenter_node.name}
      interruptionQueue: ${aws_sqs_queue.karpenter.name}
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
    EOT
  ]

  depends_on = [
    aws_eks_node_group.system
  ]
}

# SQS Queue for Spot Instance Interruption
resource "aws_sqs_queue" "karpenter" {
  name                    = "karpenter-${var.cluster_name}"
  message_retention_seconds = 300
  sqs_managed_sse_enabled = true
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.url
  policy = jsonencode({
    Statement = [{
      Action = ["sqs:SendMessage"]
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = [
            aws_cloudwatch_event_rule.karpenter_instance_state_change.arn,
            aws_cloudwatch_event_rule.karpenter_spot_interruption.arn,
          ]
        }
      }
      Effect = "Allow"
      Principal = {
        Service = ["events.amazonaws.com", "sqs.amazonaws.com"]
      }
      Resource = aws_sqs_queue.karpenter.arn
      Sid      = "SqsWrite"
    }]
    Version = "2012-10-17"
  })
}

# EventBridge Rules for Instance State Changes
resource "aws_cloudwatch_event_rule" "karpenter_instance_state_change" {
  name = "karpenter-instance-state-change-${var.cluster_name}"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    detail-type   = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["shutting-down", "stopped", "stopping", "terminated"]
    }
  })
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state_change" {
  rule      = aws_cloudwatch_event_rule.karpenter_instance_state_change.name
  target_id = "KarpenterInstanceStateChangeTarget"
  arn       = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name = "karpenter-spot-interruption-${var.cluster_name}"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule      = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  target_id = "KarpenterSpotInterruptionTarget"
  arn       = aws_sqs_queue.karpenter.arn
}

# Karpenter Node Pool for x86 instances
resource "kubectl_manifest" "karpenter_nodepool_x86" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: x86-nodepool
    spec:
      template:
        metadata:
          labels:
            arch: "x86"
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["t3.medium", "t3.large", "t3.xlarge", "m5.large", "m5.xlarge", "c5.large", "c5.xlarge"]
          nodeClassRef:
            name: x86-nodeclass
          taints:
            - key: arch
              value: "x86"
              effect: NoSchedule
      limits:
        cpu: 1000
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

# Karpenter Node Pool for ARM64 (Graviton) instances
resource "kubectl_manifest" "karpenter_nodepool_arm64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: arm64-nodepool
    spec:
      template:
        metadata:
          labels:
            arch: "arm64"
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["t4g.medium", "t4g.large", "t4g.xlarge", "m6g.large", "m6g.xlarge", "c6g.large", "c6g.xlarge"]
          nodeClassRef:
            name: arm64-nodeclass
          taints:
            - key: arch
              value: "arm64"
              effect: NoSchedule
      limits:
        cpu: 1000
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

# Node Classes
resource "kubectl_manifest" "karpenter_nodeclass_x86" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: x86-nodeclass
    spec:
      amiFamily: AL2
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      instanceStorePolicy: NVME
      userData: |
        #!/bin/bash
        /etc/eks/bootstrap.sh ${var.cluster_name}
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_nodeclass_arm64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: arm64-nodeclass
    spec:
      amiFamily: AL2
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      instanceStorePolicy: NVME
      userData: |
        #!/bin/bash
        /etc/eks/bootstrap.sh ${var.cluster_name}
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}
