#!/bin/bash
# ============================================
# Genato Deployment Script with Docker Build for Canvas and CloudFront Distribution Creation/Update
# ============================================

# Disable AWS CLI pager so output isn’t paged
export AWS_PAGER=""

# Set variables
LAMBDA_NAME="genato-func"
IMAGE_BUCKET="genato-images"            # Bucket for storing generated images
DEPLOYMENT_BUCKET="genato-lambda"        # Bucket for storing Lambda deployment package
IAM_ROLE_NAME="GenatoRole"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IAM_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$IAM_ROLE_NAME"
ZIP_FILE="genato.zip"
REGION="us-east-1"                       # Lambda@Edge must be in us-east-1
DISTRIBUTION_CONFIG_FILE="cloudfront-config.json"

echo "🚀 Starting deployment for Lambda@Edge function '$LAMBDA_NAME'..."

# -------------------------------
# 1. Ensure required S3 buckets exist
# -------------------------------
for BUCKET in $IMAGE_BUCKET $DEPLOYMENT_BUCKET; do
    echo "🔍 Checking if S3 bucket '$BUCKET' exists..."
    if ! aws s3 ls "s3://$BUCKET" > /dev/null 2>&1; then
        echo "🚀 Creating S3 bucket '$BUCKET'..."
        aws s3 mb "s3://$BUCKET" --region $REGION
        echo "✅ Bucket '$BUCKET' created."
    else
        echo "✅ Bucket '$BUCKET' already exists."
    fi
done

# Unblock all public access for the genato-images bucket
echo "🔓 Unblocking all public access for bucket '$IMAGE_BUCKET'..."
aws s3api put-public-access-block --bucket $IMAGE_BUCKET --region $REGION --public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

# Set the bucket policy for the genato-images bucket
echo "🔒 Setting bucket policy for '$IMAGE_BUCKET'..."
cat <<EOF > bucket-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Stmt1405592139000",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": [
                "arn:aws:s3:::$IMAGE_BUCKET/*",
                "arn:aws:s3:::$IMAGE_BUCKET"
            ]
        },
        {
            "Sid": "AWSLogDeliveryWrite-1622584325",
            "Effect": "Allow",
            "Principal": {
                "Service": "delivery.logs.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::$IMAGE_BUCKET/AWSLogs/548847260059/CloudFront/*",
            "Condition": {
                "StringEquals": {
                    "aws:SourceAccount": "548847260059",
                    "s3:x-amz-acl": "bucket-owner-full-control"
                },
                "ArnLike": {
                    "aws:SourceArn": "arn:aws:logs:us-east-1:548847260059:delivery-source:CreatedByCloudFront-EHVJXNA09NJK6"
                }
            }
        }
    ]
}
EOF
aws s3api put-bucket-policy --bucket $IMAGE_BUCKET --region $REGION --policy file://bucket-policy.json

# -------------------------------
# 2. Ensure the IAM Role exists and attach required policies
# -------------------------------
echo "🔍 Checking if IAM Role '$IAM_ROLE_NAME' exists..."
if ! aws iam get-role --role-name $IAM_ROLE_NAME > /dev/null 2>&1; then
    echo "🚀 Creating IAM Role '$IAM_ROLE_NAME'..."
    cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "lambda.amazonaws.com",
          "edgelambda.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    aws iam create-role --role-name $IAM_ROLE_NAME --assume-role-policy-document file://trust-policy.json > /dev/null
    echo "✅ IAM Role '$IAM_ROLE_NAME' created."
fi

echo "🔒 Attaching policies to IAM Role '$IAM_ROLE_NAME'..."
# Attach AWS managed basic execution policy
aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Create inline policy for S3 access
cat <<EOF > s3-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:HeadObject"
      ],
      "Resource": [
        "arn:aws:s3:::$IMAGE_BUCKET",
        "arn:aws:s3:::$IMAGE_BUCKET/*",
        "arn:aws:s3:::$DEPLOYMENT_BUCKET",
        "arn:aws:s3:::$DEPLOYMENT_BUCKET/*"
      ]
    }
  ]
}
EOF
aws iam put-role-policy --role-name $IAM_ROLE_NAME --policy-name "LambdaEdgeS3Policy" --policy-document file://s3-policy.json

# Create inline policy to allow CloudFront to invoke Lambda
cat <<EOF > lambda-edge-invoke-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$LAMBDA_NAME:*"
    }
  ]
}
EOF
aws iam put-role-policy --role-name $IAM_ROLE_NAME --policy-name "LambdaEdgeCloudFrontPolicy" --policy-document file://lambda-edge-invoke-policy.json

echo "✅ IAM Role '$IAM_ROLE_NAME' is configured."

# -------------------------------
# 4. Package the Lambda function without Docker, using local zip command
echo "📦 Packaging Lambda function..."
rm -f $ZIP_FILE
zip -r $ZIP_FILE handler.py
pushd layer/python
zip -r ../../$ZIP_FILE .
popd

# -------------------------------
# 5. Upload the deployment package to the deployment bucket
# -------------------------------
echo "📤 Uploading package to S3 bucket '$DEPLOYMENT_BUCKET'..."
aws s3 cp $ZIP_FILE s3://$DEPLOYMENT_BUCKET/ --region $REGION

# -------------------------------
# 6. Create or update the Lambda function (in us-east-1)
# -------------------------------
echo "🔍 Checking if Lambda function '$LAMBDA_NAME' exists..."
if aws lambda get-function --function-name $LAMBDA_NAME --region $REGION > /dev/null 2>&1; then
    echo "⚡ Updating existing Lambda function..."
    aws lambda update-function-code --function-name $LAMBDA_NAME --s3-bucket $DEPLOYMENT_BUCKET --s3-key $ZIP_FILE --region $REGION
    echo "⏳ Waiting for Lambda function update to complete..."
    while aws lambda get-function --function-name $LAMBDA_NAME --region $REGION --query 'Configuration.LastUpdateStatus' --output text | grep -q "InProgress"; do
        sleep 5
        echo "⏳ Still updating..."
    done
    echo "✅ Lambda update complete."
    aws lambda update-function-configuration \
      --function-name $LAMBDA_NAME \
      --memory-size 256 \
      --timeout 5 \
      --region $REGION
else
    echo "🚀 Creating new Lambda function..."
    aws lambda create-function \
      --function-name $LAMBDA_NAME \
      --runtime python3.9 \
      --role $IAM_ROLE_ARN \
      --handler handler.lambda_handler \
      --code S3Bucket=$DEPLOYMENT_BUCKET,S3Key=$ZIP_FILE \
      --region $REGION \
      --memory-size 256 \
      --timeout 5
fi

# -------------------------------
# 7. Publish a new Lambda version
# -------------------------------
echo "📌 Publishing a new Lambda version..."
VERSION=""
while [ -z "$VERSION" ]; do
    VERSION=$(aws lambda publish-version --function-name $LAMBDA_NAME --region $REGION --query 'Version' --output text 2>/dev/null)
    if [ -z "$VERSION" ]; then
        echo "⏳ Waiting for version to be available..."
        sleep 5
    fi
done
echo "✅ Published Lambda version: $VERSION"

# -------------------------------
# 8. Retrieve or create CloudFront distribution for IMAGE_BUCKET
# -------------------------------
echo "🌍 Searching for a CloudFront distribution for '$IMAGE_BUCKET.s3.amazonaws.com'..."
DISTRIBUTION_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Origins.Items[0].DomainName=='$IMAGE_BUCKET.s3.amazonaws.com'].Id" --output text)
if [ -z "$DISTRIBUTION_ID" ]; then
    echo "🚀 No distribution found. Creating a new CloudFront distribution..."
    cat <<EOF > $DISTRIBUTION_CONFIG_FILE
{
  "CallerReference": "$(date +%s)",
  "Aliases": { "Quantity": 0 },
  "DefaultRootObject": "",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "$IMAGE_BUCKET",
        "DomainName": "$IMAGE_BUCKET.s3.amazonaws.com",
        "S3OriginConfig": { "OriginAccessIdentity": "" }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "$IMAGE_BUCKET",
    "ViewerProtocolPolicy": "redirect-to-https",
    "TrustedSigners": { "Enabled": false, "Quantity": 0 },
    "AllowedMethods": {
      "Quantity": 2,
      "Items": [ "GET", "HEAD" ],
      "CachedMethods": { "Quantity": 2, "Items": [ "GET", "HEAD" ]
      },
      "ForwardedValues": {
        "QueryString": false,
        "Cookies": { "Forward": "none" }
      },
      "MinTTL": 0,
      "DefaultTTL": 86400,
      "MaxTTL": 31536000,
      "LambdaFunctionAssociations": {
        "Quantity": 1,
        "Items": [
          {
            "LambdaFunctionARN": "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$LAMBDA_NAME:$VERSION",
            "EventType": "origin-request",
            "IncludeBody": false
          }
        ]
      }
    },
    "Comment": "CloudFront distribution for $IMAGE_BUCKET",
    "Enabled": true
  }
}
EOF
    DISTRIBUTION_ID=$(aws cloudfront create-distribution --distribution-config file://$DISTRIBUTION_CONFIG_FILE --query 'Distribution.Id' --output text)
    echo "✅ Created CloudFront distribution with ID: $DISTRIBUTION_ID"
else
    echo "✅ Found existing CloudFront distribution: $DISTRIBUTION_ID"
fi

# -------------------------------
# 9. Add permission for CloudFront to invoke the new Lambda version
# -------------------------------
echo "🔑 Adding permission for CloudFront to invoke Lambda..."
SOURCE_ARN="arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DISTRIBUTION_ID"
aws lambda add-permission \
  --function-name $LAMBDA_NAME \
  --qualifier $VERSION \
  --statement-id "AllowCloudFrontInvoke" \
  --action "lambda:InvokeFunction" \
  --principal "edgelambda.amazonaws.com" \
  --source-arn "$SOURCE_ARN" \
  --region $REGION 2>/dev/null || echo "✅ Permission already exists."

# -------------------------------
# 10. Update CloudFront distribution to use the new Lambda version
# -------------------------------
echo "🔄 Updating CloudFront distribution to use Lambda version $VERSION..."
aws cloudfront get-distribution-config --id "$DISTRIBUTION_ID" > cloudfront-full.json
ETAG=$(jq -r '.ETag' cloudfront-full.json)
jq '.DistributionConfig' cloudfront-full.json > cloudfront-config-only.json
NEW_LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$LAMBDA_NAME:$VERSION"
NEW_CONFIG=$(jq --arg LAMBDA_ARN "$NEW_LAMBDA_ARN" \
  '.DefaultCacheBehavior.LambdaFunctionAssociations.Items[0].LambdaFunctionARN = $LAMBDA_ARN' \
  cloudfront-config-only.json)
echo "$NEW_CONFIG" > updated-cloudfront-config.json
aws cloudfront update-distribution \
  --id "$DISTRIBUTION_ID" \
  --if-match "$ETAG" \
  --distribution-config file://updated-cloudfront-config.json
echo "✅ CloudFront distribution updated to use Lambda version: $VERSION"

# -------------------------------
# 11. Invalidate CloudFront cache so changes take effect immediately
# -------------------------------
echo "🚀 Invalidating CloudFront cache..."
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*"
echo "✅ CloudFront cache invalidated!"

echo "🎉 Deployment complete! CloudFront will now invoke Lambda@$REGION (version $VERSION) when an image is requested."
