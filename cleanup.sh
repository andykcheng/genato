#!/bin/bash
export AWS_PAGER=""

# Set variables
LAMBDA_FUNCTION_NAME="genato-func"
S3_BUCKET_IMAGES="genato-images"
S3_BUCKET_LAMBDA="genato-lambda"
IAM_ROLE_NAME="GenatoRole"
AWS_REGION="us-east-1"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null
then
    echo "AWS CLI could not be found. Please install it."
    exit 1
fi

# Check if CloudFront distribution exists
CLOUDFRONT_DISTRIBUTION_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Origins.Items[0].DomainName==\`$S3_BUCKET_IMAGES.s3.amazonaws.com\`].Id" --output text --region us-east-1)
if [ -z "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
  echo "CloudFront distribution not found for S3 bucket: $S3_BUCKET_IMAGES"
else
  echo "CloudFront distribution ID: $CLOUDFRONT_DISTRIBUTION_ID"

  # Get CloudFront distribution config
  echo "Getting CloudFront distribution config..."
  CLOUDFRONT_DISTRIBUTION_CONFIG_JSON=$(aws cloudfront get-distribution-config --id $CLOUDFRONT_DISTRIBUTION_ID --region us-east-1 --output json)
  CLOUDFRONT_DISTRIBUTION_ETAG=$(echo "$CLOUDFRONT_DISTRIBUTION_CONFIG_JSON" | jq -r '.ETag')
  CLOUDFRONT_DISTRIBUTION_CONFIG=$(echo "$CLOUDFRONT_DISTRIBUTION_CONFIG_JSON" | jq -r '.DistributionConfig')

  # Disable CloudFront distribution
  echo "Disabling CloudFront distribution..."
  CLOUDFRONT_DISTRIBUTION_CONFIG=$(echo "$CLOUDFRONT_DISTRIBUTION_CONFIG" | jq '.Enabled = false')
  aws cloudfront update-distribution --id $CLOUDFRONT_DISTRIBUTION_ID --distribution-config "$CLOUDFRONT_DISTRIBUTION_CONFIG" --if-match "$CLOUDFRONT_DISTRIBUTION_ETAG" --region us-east-1

  # Wait for CloudFront distribution to be disabled using polling
  echo "Waiting for CloudFront distribution to be disabled..."
  COUNT=0
  MAX_ATTEMPTS=30
  while [ $COUNT -lt $MAX_ATTEMPTS ]; do
      STATUS=$(aws cloudfront get-distribution-config --id $CLOUDFRONT_DISTRIBUTION_ID --region us-east-1 --query "DistributionConfig.Enabled" --output text)
      if [ "$STATUS" = "false" ]; then
          echo "Distribution disabled."
          break
      fi
      sleep 20
      COUNT=$((COUNT+1))
  done
  if [ $COUNT -eq $MAX_ATTEMPTS ]; then
      echo "Timeout waiting for distribution to be disabled."
      exit 1
  fi

  # Remove Lambda function association from CloudFront distribution
  echo "Removing Lambda function association from CloudFront distribution..."
  CLOUDFRONT_DISTRIBUTION_CONFIG=$(aws cloudfront get-distribution-config --id $CLOUDFRONT_DISTRIBUTION_ID --region us-east-1 --output json | jq 'del(.DistributionConfig.LambdaFunctionAssociations)')
  CLOUDFRONT_DISTRIBUTION_ETAG=$(echo "$CLOUDFRONT_DISTRIBUTION_CONFIG" | jq -r '.ETag')
  CLOUDFRONT_DISTRIBUTION_CONFIG=$(echo "$CLOUDFRONT_DISTRIBUTION_CONFIG" | jq -r '.DistributionConfig')
  aws cloudfront update-distribution --id $CLOUDFRONT_DISTRIBUTION_ID --distribution-config "$CLOUDFRONT_DISTRIBUTION_CONFIG" --if-match "$CLOUDFRONT_DISTRIBUTION_ETAG" --region us-east-1

  # Delete CloudFront distribution
  echo "Deleting CloudFront distribution..."
  aws cloudfront delete-distribution --id $CLOUDFRONT_DISTRIBUTION_ID --if-match "$CLOUDFRONT_DISTRIBUTION_ETAG" --region us-east-1
fi

# Wait for replication to propagate before deleting Lambda function
echo "Waiting 15 minutes for Lambda@Edge replication to complete..."
sleep 900

# Delete Lambda function
echo "Deleting Lambda function..."
aws lambda delete-function --function-name $LAMBDA_FUNCTION_NAME --region us-east-1

# Check if IAM role exists before attempting to delete
if aws iam get-role --role-name "$IAM_ROLE_NAME" --region us-east-1 >/dev/null 2>&1; then
    # Detach policies from IAM role
    echo "Detaching policies from IAM role..."
    aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text --region us-east-1):policy/service-role/AWSLambdaBasicExecutionRole --region us-east-1

    INLINE_POLICY_NAMES=$(aws iam list-role-policies --role-name $IAM_ROLE_NAME --query PolicyNames --output text --region us-east-1)
    for POLICY_NAME in $INLINE_POLICY_NAMES; do
        echo "Deleting inline policy: $POLICY_NAME"
        aws iam delete-role-policy --role-name $IAM_ROLE_NAME --policy-name "$POLICY_NAME" --region us-east-1
    done

    # Delete IAM role
    echo "Deleting IAM role..."
    aws iam delete-role --role-name $IAM_ROLE_NAME --region us-east-1
else
    echo "IAM role $IAM_ROLE_NAME not found, skipping deletion."
fi

# Delete S3 buckets
echo "Deleting S3 buckets..."

# Function to delete all objects from an S3 bucket
delete_s3_objects() {
  BUCKET_NAME="$1"
  if aws s3 ls "s3://$BUCKET_NAME" --region us-east-1 >/dev/null 2>&1; then
    echo "Deleting all objects from S3 bucket: $BUCKET_NAME"
    aws s3 rm "s3://$BUCKET_NAME" --recursive --quiet --region us-east-1
  else
    echo "S3 bucket $BUCKET_NAME not found, skipping deletion."
  fi
}

# Function to delete an S3 bucket
delete_s3_bucket() {
  BUCKET_NAME="$1"
  if aws s3 ls "s3://$BUCKET_NAME" --region us-east-1 >/dev/null 2>&1; then
    echo "Deleting S3 bucket: $BUCKET_NAME"
    aws s3 rb "s3://$BUCKET_NAME" --region us-east-1
  else
    echo "S3 bucket $BUCKET_NAME not found, skipping deletion."
  fi
}

# Delete objects and buckets
delete_s3_objects "$S3_BUCKET_IMAGES"
delete_s3_objects "$S3_BUCKET_LAMBDA"
delete_s3_bucket "$S3_BUCKET_IMAGES"
delete_s3_bucket "$S3_BUCKET_LAMBDA"

echo "Cleanup complete."
