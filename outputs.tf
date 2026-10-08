output "website_url" {
  value = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "api_gateway_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}

output "api_via_cloudfront_health_url" {
  value = "https://${aws_cloudfront_distribution.site.domain_name}/api/v1/"
}

output "database_secret_arn" {
  value     = aws_secretsmanager_secret.db.arn
  sensitive = true
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.site.bucket
}

output "artifact_bucket_name" {
  value = aws_s3_bucket.artifacts.bucket
}

output "migration_lambda_name" {
  value = aws_lambda_function.migrations.function_name
}
