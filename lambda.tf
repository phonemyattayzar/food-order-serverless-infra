resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-${var.environment}-lambda"
  description = "Lambda to private database access"
  vpc_id      = aws_vpc.this.id
}

resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-${var.environment}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "read_db_secret" {
  name = "runtime-access"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.db.arn
      }, {
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.site.arn}/uploads/*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-${var.environment}-api"
  retention_in_days = 30
}

resource "aws_lambda_function" "api" {
  function_name                  = "${var.project_name}-${var.environment}-api"
  role                           = aws_iam_role.lambda.arn
  runtime                        = "python3.12"
  handler                        = "lambda_handler.handler"
  filename                       = var.lambda_package_path
  source_code_hash               = fileexists(var.lambda_package_path) ? filebase64sha256(var.lambda_package_path) : null
  memory_size                    = var.lambda_memory_mb
  timeout                        = var.lambda_timeout_seconds
  reserved_concurrent_executions = var.lambda_reserved_concurrency
  architectures                  = ["x86_64"]
  publish                        = true

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_SECRET_ARN  = aws_secretsmanager_secret.db.arn
      UPLOADS_BUCKET = aws_s3_bucket.site.bucket
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  lifecycle {
    precondition {
      condition     = var.bootstrap_artifact_bucket || fileexists(var.lambda_package_path)
      error_message = "Lambda package '${var.lambda_package_path}' is missing. Build/download a release bundle before planning a Lambda deployment."
    }
  }
}

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project_name}-${var.environment}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["DELETE", "GET", "OPTIONS", "PATCH", "POST", "PUT"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      routeKey  = "$context.routeKey"
      status    = "$context.status"
      latency   = "$context.responseLatency"
    })
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.project_name}-${var.environment}"
  retention_in_days = 30
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_security_group" "endpoints" {
  name   = "${var.project_name}-${var.environment}-endpoints"
  vpc_id = aws_vpc.this.id
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_database" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Lambda to PostgreSQL"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_endpoints" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Lambda to AWS interface endpoints"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_lambda" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS from Lambda"
}

resource "aws_cloudwatch_log_group" "migrations" {
  name              = "/aws/lambda/${var.project_name}-${var.environment}-migrations"
  retention_in_days = 30
}

resource "aws_lambda_function" "migrations" {
  function_name    = "${var.project_name}-${var.environment}-migrations"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "migrate_handler.handler"
  filename         = var.lambda_package_path
  source_code_hash = fileexists(var.lambda_package_path) ? filebase64sha256(var.lambda_package_path) : null
  memory_size      = 512
  timeout          = 300
  architectures    = ["x86_64"]

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_SECRET_ARN = aws_secretsmanager_secret.db.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.migrations]

  lifecycle {
    precondition {
      condition     = var.bootstrap_artifact_bucket || fileexists(var.lambda_package_path)
      error_message = "Lambda package '${var.lambda_package_path}' is missing. Build/download a release bundle before planning a Lambda deployment."
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_s3" {
  security_group_id = aws_security_group.lambda.id
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Lambda upload access to S3 gateway endpoint"
}
