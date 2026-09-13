# ==============================================================================
# AWS Systems Manager Incident Manager (On-Call Paging & Escalation)
#
# Replaces self-hosted GoAlert with a 100% serverless, managed AWS service.
# - Multi-AZ by default with an AWS 99.99% service SLA.
# - Multi-Region support via Replication Sets (aws_ssmincidents_replication_set)
# - Zero in-cluster stateful database/EBS volume dependencies.
# - Integrates natively with AWS Chatbot (Slack/Teams) and CloudWatch Alarms.
# ==============================================================================

data "aws_caller_identity" "current" {}

# 1. Multi-Region Replication Set
# Replicates incident records, contacts, and response plans across regions.
resource "aws_ssmincidents_replication_set" "main" {
  count = var.enable_ssm_incident_manager ? 1 : 0

  region {
    name = var.aws_region
  }

  tags = {
    Name        = "${var.cluster_name}-incident-replication"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Platform    = "Observability"
  }
}

# 2. On-Call Contact
resource "aws_ssmcontacts_contact" "primary_oncall" {
  count = var.enable_ssm_incident_manager ? 1 : 0

  alias        = "${var.cluster_name}-sre-primary"
  display_name = "Primary On-Call SRE (${var.cluster_name})"
  type         = "PERSONAL"

  tags = {
    Platform = "Observability"
  }
}

# 3. Contact Engagement Channel (Email / SMS)
resource "aws_ssmcontacts_contact_channel" "email" {
  count = var.enable_ssm_incident_manager ? 1 : 0

  contact_id = aws_ssmcontacts_contact.primary_oncall[0].arn
  name       = "primary-email"
  type       = "EMAIL"

  delivery_address {
    simple_address = var.oncall_contact_email
  }
}

# 4. Multi-Stage Escalation Plan
resource "aws_ssmcontacts_plan" "primary_escalation" {
  count = var.enable_ssm_incident_manager ? 1 : 0

  contact_id = aws_ssmcontacts_contact.primary_oncall[0].arn

  stage {
    duration_in_minutes = 15

    target {
      channel_target_info {
        contact_channel_id        = aws_ssmcontacts_contact_channel.email[0].arn
        retry_interval_in_minutes = 2
      }
    }
  }
}

# 5. Incident Response Plan (Triggered on SLO Fast-Burn Alerts)
resource "aws_ssmincidents_response_plan" "slo_burn_rate" {
  count = var.enable_ssm_incident_manager ? 1 : 0

  name         = "${var.cluster_name}-slo-fast-burn"
  display_name = "EKS Fast Error Budget Burn (Google SRE 14.4x/6x)"

  incident_template {
    title         = "CRITICAL: High Error Budget Burn on EKS Service"
    impact        = 1 # 1: Critical, 2: High, 3: Medium, 4: Low
    summary       = "A service on EKS cluster ${var.cluster_name} breached the 14.4x fast burn rate threshold. Error budget is exhausting rapidly."
    dedupe_string = "slo-fast-burn"
  }

  engagements = [
    aws_ssmcontacts_contact.primary_oncall[0].arn
  ]

  depends_on = [
    aws_ssmincidents_replication_set.main
  ]

  tags = {
    Platform = "Observability"
  }
}

# 6. SNS Topic for Mimir Alertmanager & CloudWatch Alarms
# Mimir Alertmanager posts firing alerts to this topic (or HTTP webhook bridge).
# AWS Chatbot subscribes to this topic to post rich incident cards to Slack/Teams.
resource "aws_sns_topic" "incident_alerts" {
  count = var.enable_ssm_incident_manager ? 1 : 0

  name = "${var.cluster_name}-incident-alerts"

  tags = {
    Platform = "Observability"
  }
}

resource "aws_sns_topic_policy" "incident_alerts_policy" {
  count = var.enable_ssm_incident_manager ? 1 : 0

  arn = aws_sns_topic.incident_alerts[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAndEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = [
            "cloudwatch.amazonaws.com",
            "events.amazonaws.com"
          ]
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.incident_alerts[0].arn
      },
      {
        Sid    = "AllowAccountPublish"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.incident_alerts[0].arn
      }
    ]
  })
}
