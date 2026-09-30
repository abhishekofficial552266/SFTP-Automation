locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Workload    = "SFTP"
  }

  resource_prefix = "sftp-${var.environment}"
}