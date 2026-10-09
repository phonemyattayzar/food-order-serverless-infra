variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}
variable "project_name" {
  type    = string
  default = "food-order-serverless"
}
variable "environment" {
  type    = string
  default = "sit"
  validation {
    condition     = contains(["sit", "prod"], var.environment)
    error_message = "environment must be sit or prod."
  }
}
variable "vpc_cidr" {
  type    = string
  default = "10.30.0.0/16"
}
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.30.1.0/24", "10.30.2.0/24"]
}
variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.30.11.0/24", "10.30.12.0/24"]
}
variable "lambda_memory_mb" {
  type    = number
  default = 512
}
variable "lambda_timeout_seconds" {
  type    = number
  default = 15
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}
variable "db_multi_az" {
  type    = bool
  default = false
}
variable "db_backup_retention_days" {
  type    = number
  default = 1
}
variable "db_deletion_protection" {
  type    = bool
  default = false
}
variable "skip_final_snapshot" {
  type    = bool
  default = true
}
variable "db_name" {
  type    = string
  default = "food_db"
}
variable "db_username" {
  type    = string
  default = "foodadmin"
}
variable "db_engine_version" {
  description = "PostgreSQL major version; AWS selects an available minor version in the configured region."
  type        = string
  default     = "16"
}
variable "lambda_package_path" {
  type    = string
  default = "build/release/lambda.zip"
}
variable "bootstrap_artifact_bucket" {
  description = "Set true only when targeting the artifact bucket resources before a release package exists."
  type        = bool
  default     = false
}
variable "static_site_path" {
  type    = string
  default = "build/release/frontend-dist"
}
variable "frontend_force_destroy" {
  type    = bool
  default = true
}

variable "secret_recovery_window_days" {
  type    = number
  default = 0
  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "Secrets Manager recovery window must be 0 or between 7 and 30 days."
  }
}

variable "lambda_reserved_concurrency" {
  description = "Use -1 for unreserved account concurrency; positive reservations require spare account quota."
  type        = number
  default     = -1
}

variable "support_tickets_enabled" {
  description = "Enable the support ticket API feature in the application Lambda."
  type        = bool
  default     = false
}
