# Genato: On-Demand Image Generation with Lambda@Edge and CloudFront

## Objective
This project demonstrates using Lambda@Edge to generate images on-demand based on the request URI. Generated images are stored in an S3 bucket and served by a CloudFront distribution as a cache layer. This approach optimizes image delivery by generating images only when requested and caching them for subsequent access. I hope this project can be useful for any who is interested in using Lambda@Edge, and I hope at least part of the package.sh is useful for creating shell scripts in creating different components in Amazon AWS. 

## What This Project is Trying to Solve
This solution addresses scenarios where image generation may be computationally intensive or time-consuming (e.g., dynamic image creation based on user-specific parameters or AI model outputs). By caching generated images through CloudFront, repeat requests are served rapidly from the cache, reducing the load on the image generation process. If an image is requested for the first time, it is generated by Lambda@Edge and saved in S3, avoiding repeated processing and improving overall efficiency.

### Architecture Diagram
Below is a diagram illustrating the structure and flow between the client, CloudFront, Lambda@Edge, and the S3 bucket:

```mermaid
flowchart TD
    Client[Client Request] --> CloudFront[CloudFront Distribution]
    CloudFront -- Cache Hit --> Cache[CloudFront Cache]
    CloudFront -- Cache Miss --> LE[Lambda@Edge Handler]
    LE -->|Generate/Fetch Image| S3[S3 Bucket: genato-images]
    S3 --> CloudFront
```

### CloudFront
Amazon CloudFront is a global content delivery network (CDN) service that securely delivers data, videos, applications, and APIs to customers globally with low latency and high transfer speeds. In this project, CloudFront acts as the primary cache for generated images. When a request is made, CloudFront first checks if the image is already cached at an edge location. If the image is cached (a "cache hit"), it is served directly from the edge location, providing fast response times. If the image is not cached (a "cache miss"), CloudFront forwards the request to the Lambda@Edge function.

### Lambda@Edge
Lambda@Edge extends the functionality of AWS Lambda to CloudFront edge locations. It allows you to run custom code in response to CloudFront events, such as viewer requests, origin requests, viewer responses, and origin responses. In this project, the Lambda@Edge function is triggered when CloudFront receives a request for an image that is not in its cache. The Lambda@Edge function then generates the image (if it doesn't already exist in S3), saves it to S3, and returns the image to CloudFront, which caches it for future requests.

### S3 Bucket
Amazon S3 (Simple Storage Service) is an object storage service offering scalability, data availability, security, and performance. In this project, S3 serves as the origin store for the generated images. The Lambda@Edge function checks if the requested image exists in the S3 bucket. If it does, the function returns the image to CloudFront. If it doesn't, the function generates the image, saves it to the S3 bucket, and then returns it to CloudFront.  The bucket policy is configured to allow public read access (`s3:GetObject`) for images, ensuring that CloudFront can serve the images to clients. Additionally, it includes a statement to allow AWS log delivery to write logs to the bucket.

## Explanation of the Project Structure
- **handler.py**: Contains the Lambda function code that handles image generation and checks S3 for existing images. It parses the request URI to determine image dimensions, color, and format (PNG or SVG). It uses the Pillow library to generate PNG images and string formatting to generate SVG images.  The function also interacts with S3 to check for existing images and save new ones.
- **package.sh**: Automates the deployment process by setting up S3 buckets, IAM roles, packaging the Lambda function (with a required layer), and configuring/updating the CloudFront distribution. It also handles setting bucket policies and IAM role policies.
- **layer/python**: Contains the dependencies required by the Lambda function, such as the Pillow library. This directory is zipped and included in the Lambda deployment package.
- **cloudfront-config.json (generated from package.sh)**: A JSON file used to configure the CloudFront distribution. It specifies the origin (S3 bucket), default cache behavior, and Lambda function associations.
- **bucket-policy.json (generated from package.sh)**: Defines the bucket policy for the S3 bucket, allowing public read access for images and log delivery.
- **trust-policy.json (generated from package.sh)**: Defines the trust policy for the IAM role, allowing Lambda and Lambda@Edge to assume the role.
- **s3-policy.json (generated from package.sh)**: Defines the IAM policy for S3 access, allowing the Lambda function to put, get, list, and head objects in the S3 bucket.
- **lambda-edge-invoke-policy.json (generated from package.sh)**: Defines the IAM policy that allows CloudFront to invoke the Lambda function.

## Explanation of the Handler Function
The `lambda_handler` function in `handler.py` is the entry point for the Lambda@Edge function. It performs the following steps:

1.  **Parse Request URI**: Extracts image dimensions, color, and format from the request URI. For example, a URI like `/640x480,white,png` is parsed to determine a width of 640, a height of 480, a color of white, and a format of PNG.
2.  **Check S3**: Checks if the image already exists in the S3 bucket using `s3.head_object`. If the image exists, the function returns the original request, allowing CloudFront to serve the image from the S3 bucket.
3.  **Generate Image**: If the image does not exist in S3, the function generates the image using either the `generate_png_image` or `generate_svg_image` function, depending on the requested format.
    *   `generate_png_image`: Uses the Pillow library to create a PNG image with the specified dimensions and color. It adds "Hello World" text to the image.
    *   `generate_svg_image`: Creates an SVG image with the specified dimensions and color by embedding the parameters into an SVG template.
4.  **Save to S3**: Saves the generated image to the S3 bucket using `s3.put_object`, with the URI as the object key. The content type is set to `image/png` or `image/svg+xml` depending on the image format.
5.  **Return Request**: Returns the original request to CloudFront, which then fetches the image from the S3 bucket and caches it.

## Explanation of the Package.sh Script
The `package.sh` script automates the deployment process. Here's a breakdown of its key steps:

1.  **Set Variables**: Defines variables for the Lambda function name, S3 bucket names, IAM role name, and other configuration parameters.
2.  **Ensure S3 Buckets Exist**: Checks if the required S3 buckets (`genato-images` and `genato-lambda`) exist. If they don't, the script creates them.
3.  **Configure S3 Bucket**: Configures the `genato-images` bucket by unblocking public access and setting a bucket policy that allows public read access for images.
4.  **Ensure IAM Role Exists**: Checks if the specified IAM role exists. If it doesn't, the script creates it with a trust policy that allows Lambda and Lambda@Edge to assume the role.
5.  **Attach IAM Policies**: Attaches the necessary IAM policies to the role, including:
    *   `AWSLambdaBasicExecutionRole`: Provides basic execution permissions for Lambda functions.
    *   Inline policy for S3 access: Allows the Lambda function to put, get, list, and head objects in the S3 bucket.
    *   Inline policy for CloudFront invoke: Allows CloudFront to invoke the Lambda function.
6.  **Package Lambda Function**: Packages the Lambda function code and dependencies into a ZIP file using the `zip` command.  It includes the `handler.py` file and the contents of the `layer/python` directory (which contains the Pillow library).
7.  **Upload Package to S3**: Uploads the ZIP file to the `genato-lambda` S3 bucket.
8.  **Create/Update Lambda Function**: Checks if the Lambda function already exists. If it does, the script updates the function code and configuration. If it doesn't, the script creates a new Lambda function with the specified configuration, including the runtime, IAM role, handler, and memory size.
9.  **Publish Lambda Version**: Publishes a new version of the Lambda function. This is necessary for Lambda@Edge functions, as CloudFront needs to be associated with a specific version of the function.
10. **Retrieve/Create CloudFront Distribution**: Searches for an existing CloudFront distribution associated with the `genato-images` S3 bucket. If no distribution is found, the script creates a new distribution with the specified configuration, including the origin (S3 bucket), default cache behavior, and Lambda function association.
11. **Add CloudFront Permission**: Adds permission for CloudFront to invoke the new Lambda version.
12. **Update CloudFront Distribution**: Updates the CloudFront distribution to use the new Lambda version.
13. **Invalidate CloudFront Cache**: Invalidates the CloudFront cache to ensure that the changes take effect immediately.

## Testing
Once deployed, go to https://**CLOUDFRONT_DEPLOYMENT_DOMAIN**/640x480,white,png, and you will see an image. 

## Cleanup
To remove all the components created by this project, run the `cleanup.sh` script. This script will remove the CloudFront distribution, Lambda function, IAM role, and S3 buckets.  However, depends on the speed that the distribution is deleted, it would sometimes fail. I usually delete them manually if that happens. 

## Conclusion
This project demonstrates how to use Lambda@Edge and CloudFront for efficient on-demand image generation and caching. While the image generation logic is relatively simple, the methodology can be applied to more resource-intensive operations, such as dynamic image creation based on user-specific data or AI model outputs. This approach can significantly improve the performance and scalability of image delivery in web applications.

## Special note
One thing that *Got* me was unable to find the log group for the Lambda function. For edge function, it is actually in the **/aws/lambda/us-east-1.genato-func** instead of **/aws/lambda/genato-func**.

The name **genato** here is just a name that is a mix of **Gen** (generate), **A** (one), **TO** (pronunciation of the word **picture** in Cantonese).  Making the whole thing sound like **Gelato**.  Just for fun here. 

## Credits
Special thanks to Keith Rozario for his outstanding work on Klayers (https://github.com/keithrozario/Klayers) packaging the Pillow layer, which has greatly simplified image generation for this project.



