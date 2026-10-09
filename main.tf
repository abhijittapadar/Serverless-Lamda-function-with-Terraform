############################################################
# Banquet Hall Survey Portal - low-cost serverless stack
# CloudFront + S3 (frontend) | Cognito (auth) | API Gateway
# + Lambda (backend) | DynamoDB (database)
############################################################
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    random  = { source = "hashicorp/random", version = "~> 3.5" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

variable "region" {
  default = "ap-south-1" # Mumbai
}
variable "project" {
  default = "banquet-survey"
}

provider "aws" {
  region = var.region
}

resource "random_id" "sfx" {
  byte_length = 3
}

locals {
  name = "${var.project}-${random_id.sfx.hex}"
}

############################ FRONTEND ######################
resource "aws_s3_bucket" "web" {
  bucket        = "${local.name}-web"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # includes India, cheaper than "All"

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3web"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3web"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate {
    cloudfront_default_certificate = true # free *.cloudfront.net HTTPS
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.web.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn } }
    }]
  })
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.web.id
  key          = "index.html"
  source       = "${path.module}/web/index.html"
  etag         = filemd5("${path.module}/web/index.html")
  content_type = "text/html"
}

# Runtime config injected into the frontend
resource "aws_s3_object" "config" {
  bucket       = aws_s3_bucket.web.id
  key          = "config.js"
  content_type = "application/javascript"
  content = "window.CONFIG=${jsonencode({
    poolId   = aws_cognito_user_pool.main.id
    clientId = aws_cognito_user_pool_client.web.id
    api      = aws_apigatewayv2_api.api.api_endpoint
  })};"
}

############################ AUTH ##########################
resource "aws_cognito_user_pool" "main" {
  name                     = local.name
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  # User details captured at sign-up
  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }
  schema {
    name                = "phone_number"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 20
    }
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name                = "web"
  user_pool_id        = aws_cognito_user_pool.main.id
  generate_secret     = false
  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

############################ DATABASE ######################
resource "aws_dynamodb_table" "users" {
  name         = "${local.name}-users"
  billing_mode = "PAY_PER_REQUEST" # no idle cost
  hash_key     = "user_id"
  attribute {
    name = "user_id"
    type = "S"
  }
  point_in_time_recovery { enabled = true }
}

resource "aws_dynamodb_table" "survey" {
  name         = "${local.name}-survey"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "submitted_at"
  attribute {
    name = "user_id"
    type = "S"
  }
  attribute {
    name = "submitted_at"
    type = "S"
  }
  point_in_time_recovery { enabled = true }
}

############################ BACKEND #######################
data "archive_file" "fn" {
  type        = "zip"
  source_file = "${path.module}/lambda/app.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_iam_role" "fn" {
  name = "${local.name}-fn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fn" {
  role = aws_iam_role.fn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:Query"]
        Resource = [aws_dynamodb_table.users.arn, aws_dynamodb_table.survey.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.fn.arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "fn" {
  function_name    = local.name
  role             = aws_iam_role.fn.arn
  runtime          = "python3.12"
  architectures    = ["arm64"] # ~20% cheaper
  handler          = "app.handler"
  memory_size      = 128
  timeout          = 10
  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  depends_on       = [aws_cloudwatch_log_group.fn]

  environment {
    variables = {
      USERS_TABLE  = aws_dynamodb_table.users.name
      SURVEY_TABLE = aws_dynamodb_table.survey.name
    }
  }
}

############################ API ###########################
resource "aws_apigatewayv2_api" "api" {
  name          = local.name
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.cdn.domain_name}"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
  }
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.api.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

resource "aws_apigatewayv2_integration" "fn" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.fn.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "r" {
  for_each           = toset(["GET /info", "GET /me", "POST /survey"])
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.fn.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
  default_route_settings { # abuse / cost protection
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGW"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

############################ OUTPUTS #######################
output "portal_url" {
  value = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}
output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}
output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}
