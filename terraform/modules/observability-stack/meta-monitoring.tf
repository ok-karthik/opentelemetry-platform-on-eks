# ==============================================================================
# "Watch the Watcher" - Decoupled External Meta-Monitoring
# 
# If the EKS cluster or the internal Prometheus/Mimir stack completely fails,
# the internal alerting mechanisms will die with it. We must have an external
# watcher outside the failure domain to page us if the system goes dark.
# ==============================================================================

# 1. Decoupled Emergency Pager (SNS Topic)
# This topic routes directly to PagerDuty, GoAlert, or SMS without relying on EKS.
resource "aws_sns_topic" "observability_emergency_pager" {
  name = "${var.cluster_name}-${var.environment}-emergency-pager"
}

# Example Subscription (uncomment and replace with real PagerDuty / OpsGenie HTTPS endpoint or email)
# resource "aws_sns_topic_subscription" "emergency_email" {
#   topic_arn = aws_sns_topic.observability_emergency_pager.arn
#   protocol  = "email"
#   endpoint  = "sre-oncall@example.com"
# }

# 2. CloudWatch Dead-Man's Alarm (Total Cluster / Network Failure)
# This alarm watches the Network Load Balancer (NLB) for the OTel Gateway.
# If the NLB sees 0 healthy targets (all Gateway pods are dead or EKS nodes are down)
# or if it starts resetting TCP connections, CloudWatch fires the alarm independently.
#
# Note: The NLB is provisioned by the AWS Load Balancer Controller via k8s annotations.
# In a real environment with static hostnames, we would use a Route53 Health Check 
# against the ingress endpoint. Here, we demonstrate the architectural pattern.

# data "aws_lb" "otel_gateway_nlb" {
#   name = "obs-cluster-otel-gw"
# }
# 
# resource "aws_cloudwatch_metric_alarm" "otel_gateway_dead" {
#   alarm_name          = "${local.project}-${local.env}-otel-gateway-dead"
#   comparison_operator = "LessThanThreshold"
#   evaluation_periods  = 3
#   metric_name         = "HealthyHostCount"
#   namespace           = "AWS/NetworkELB"
#   period              = 60
#   statistic           = "Minimum"
#   threshold           = 1
#   alarm_description   = "CRITICAL: OTel Gateway NLB has 0 healthy targets. Observability ingestion is completely down."
#   
#   dimensions = {
#     LoadBalancer = data.aws_lb.otel_gateway_nlb.arn_suffix
#   }
# 
#   alarm_actions = [aws_sns_topic.observability_emergency_pager.arn]
#   ok_actions    = [aws_sns_topic.observability_emergency_pager.arn]
# }
