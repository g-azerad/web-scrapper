terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
  # Defining Gitlab project Terraform feature as backend for the state
  backend "http" {
    address        = "https://gitlab.perso.com/api/v4/projects/${var.gitlab_project_id}/terraform/state/${var.tf_state_name}"
    lock_address   = "https://gitlab.perso.com/api/v4/projects/${var.gitlab_project_id}/terraform/state/${var.tf_state_name}/lock"
    unlock_address = "https://gitlab.perso.com/api/v4/projects/${var.gitlab_project_id}/terraform/state/${var.tf_state_name}/lock"
  }
  required_version = ">= 1.10.0"
}

# Getting AWS provider configuration from variables
provider "aws" {
  region = var.region
}

# Retrieving account information
data "aws_caller_identity" "current" {}

# Defining the SSH key to use with EC2 instances
resource "aws_key_pair" "access_key" {
  key_name   = "access_key"
  public_key = var.ssh_public_key
}

# Get server public IP to set Bastion SSH access
data "external" "config" {
  program = ["../../../scripts/get_public_ip.sh"]
}

# Importing network module to create network configuration
module "network" {
  source             = "../../../modules/network"
  name               = var.environment
  bastion_cidr_ipv4  = "${data.external.config.result["public_ip"]}/32"
  integration_target = var.integration_target
}

# Creating the SSH bastion
module "bastion" {
  source = "../../../modules/bastion"
  subnet_id         = module.network.public_subnet_id
  bastion_sg_id     = module.network.bastion_sg_id
  name              = "${var.application_name}-${var.environment}-bastion"
  key_name          = aws_key_pair.access_key.key_name
  bastion_eni_id    = module.network.bastion_eni_id
}

# Importing rds module to create RDS PostgreSQL database
module "rds" {
  source                     = "../../../modules/rds"
  region                     = var.region
  vpc_id                     = module.network.vpc_id
  security_group_id          = module.network.database_sg_id
  private_subnet_ids         = [module.network.private_subnet_id, module.network.private_subnet_bkp_id]
  allocated_storage          = var.db_allocated_storage
  engine_version             = var.postgresql_version
  backup_retention_period    = var.backup_retention_period
  db_name                    = var.db_name
  db_master_username         = var.db_master_username
  db_port                    = var.db_port
  db_master_user_secret_name = var.db_master_user_secret_name
  public_subnet_ip_range     = module.network.public_subnet_cidr
  account_id                 = data.aws_caller_identity.current.account_id
}

# Creating the Lambda to run the API
module "lambda" {
  count                     = (var.integration_target == "lambda" ? 1 : 0)
  source                    = "../../../modules/lambda"
  region                    = var.region
  api_name                  = "${var.application_name}-${var.environment}-lambda"
  public_subnet_id          = module.network.public_subnet_id
  security_group_id         = module.network.instance_sg_id
  lambda_zip_file           = var.lambda_zip_file
  dependencies_package      = var.dependencies_package
  db_user_secret_name       = var.db_user_secret_name
  db_name                   = var.db_name
  db_username               = var.db_username
  db_port                   = var.db_port
  db_host                   = module.rds.db_host
  api_gateway_execution_arn = module.api_gateway[0].api_gateway_execution_arn
  db_connect_iam_policy_arn = module.rds.db_connect_iam_policy_arn
}

# Creates the ECS instance running API container if integration target is "ecs"
module "ecs" {
  count                     = (var.integration_target == "ecs" ? 1 : 0)
  source                    = "../../../modules/ecs"
  region                    = var.region
  application_name          = var.application_name
  db_connect_iam_policy_arn = module.rds.db_connect_iam_policy_arn
  ecs_service_name          = "${var.application_name}-${var.environment}-ecs"
  vpc_id                    = module.network.vpc_id
  image_name                = var.image_name
  image_tag                 = var.image_tag
  public_subnet_id          = module.network.public_subnet_id
  security_group_id         = module.network.instance_sg_id
  db_user_secret_name       = var.db_user_secret_name
  db_name                   = var.db_name
  db_username               = var.db_username
  db_port                   = var.db_port
  db_host                   = module.rds.db_host
  ssl_mode                  = var.ssl_mode
  ssl_root_cert             = local.ssl_root_cert
  iam_auth                  = var.iam_auth
  debug_mode                = var.debug_mode
}

# Creates the ECS instance running API container behind a cloudmap service
module "ecs_cloudmap" {
  count                     = (var.integration_target == "ecs_cloudmap" ? 1 : 0)
  source                    = "../../../modules/ecs_cloudmap"
  region                    = var.region
  application_name          = var.application_name
  db_connect_iam_policy_arn = module.rds.db_connect_iam_policy_arn
  ecs_service_name          = "${var.application_name}-${var.environment}-ecs"
  vpc_id                    = module.network.vpc_id
  image_name                = var.image_name
  image_tag                 = var.image_tag
  public_subnet_id          = module.network.public_subnet_id
  security_group_id         = module.network.instance_sg_id
  db_user_secret_name       = var.db_user_secret_name
  db_name                   = var.db_name
  db_username               = var.db_username
  db_port                   = var.db_port
  db_host                   = module.rds.db_host
  ssl_mode                  = var.ssl_mode
  ssl_root_cert             = local.ssl_root_cert
  iam_auth                  = var.iam_auth
  debug_mode                = var.debug_mode
}

# Creating the API gateway
module "api_gateway" {
  count                    = (var.api_gateway_type == "rest" ? 1 : 0)
  source                   = "../../../modules/api_gateway"
  api_name                 = "${var.application_name}-${var.environment}"
  api_stage_name           = var.api_stage_name
  integration_target       = var.integration_target
  lambda_invoke_arn        = (var.integration_target == "lambda" ? module.lambda[0].lambda_invoke_arn : null)
  ecs_vpc_link_id          = (var.integration_target == "ecs" ? module.ecs[0].ecs_vpc_link_id : null)
  ecs_lb_uri               = (var.integration_target == "ecs" ? module.ecs[0].ecs_lb_uri : null)
}

module "api_gateway_v2" {
  count                    = (var.api_gateway_type == "v2" ? 1 : 0)
  source                   = "../../../modules/api_gateway_v2"
  api_name                 = "${var.application_name}-${var.environment}"
  api_stage_name           = var.api_stage_name
  public_subnet_id         = module.network.public_subnet_id
  security_group_id        = module.network.instance_sg_id
  integration_target       = var.integration_target
  lambda_invoke_arn        = (var.integration_target == "lambda" ? module.lambda[0].lambda_invoke_arn : null)
  ecs_vpc_link_id          = (var.integration_target == "ecs" ? module.ecs[0].ecs_vpc_link_id : null)
  ecs_lb_uri               = (var.integration_target == "ecs" ? module.ecs[0].ecs_lb_uri : null)
  ecs_cloudmap_service_arn = (var.integration_target == "ecs_cloudmap" ? module.ecs_cloudmap[0].ecs_cloudmap_service_arn : null)
}