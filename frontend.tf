resource "random_id" "site_bucket" {
  byte_length = 4
}

resource "aws_s3_bucket" "site" {
  bucket        = "${var.project_name}-${var.environment}-${random_id.site_bucket.hex}"
  force_destroy = var.frontend_force_destroy
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project_name}-${var.environment}-oac"
  description                       = "CloudFront access to private frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "frontend-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }
  origin {
    domain_name = trimsuffix(trimprefix(aws_apigatewayv2_api.http.api_endpoint, "https://"), "/")
    origin_id   = "http-api"
    origin_path = ""
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  default_cache_behavior {
    target_origin_id       = "frontend-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 60
    max_ttl                = 3600
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "http-api"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type", "Origin"]
      cookies { forward = "all" }
    }
  }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  viewer_certificate { cloudfront_default_certificate = true }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = ["s3:GetObject"]
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn } }
    }]
  })
}

resource "aws_s3_object" "site_files" {
  for_each     = fileset(var.static_site_path, "**")
  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${var.static_site_path}/${each.value}"
  etag         = filemd5("${var.static_site_path}/${each.value}")
  content_type = endswith(each.value, ".html") ? "text/html" : endswith(each.value, ".css") ? "text/css" : endswith(each.value, ".js") ? "application/javascript" : endswith(each.value, ".svg") ? "image/svg+xml" : endswith(each.value, ".json") ? "application/json" : endswith(each.value, ".ico") ? "image/x-icon" : "application/octet-stream"
}
