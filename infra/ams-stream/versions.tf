terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # Credenciais vêm do seu ambiente (AWS_PROFILE / variáveis / SSO).
  # Este código NÃO carrega segredo nenhum.
}
