from io import BytesIO
from PIL import Image, ImageDraw, ImageFont
import base64
import boto3

def generate_png_image(width, height, color):
    image = Image.new("RGB", (width, height), color=color)
    draw = ImageDraw.Draw(image)
    text = "Hello World"
    try:
        font = ImageFont.truetype("arial.ttf", size=min(width, height)//10)
    except IOError:
        font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]
    x = (width - text_width) // 2
    y = (height - text_height) // 2
    draw.text((x, y), text, fill="black", font=font)
    buffer = BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()

def generate_svg_image(width, height, color):
    svg_template = f'''
    <svg width="{width}" height="{height}" xmlns="http://www.w3.org/2000/svg">
        <rect width="100%" height="100%" fill="{color}" />
        <text x="50%" y="50%" dominant-baseline="middle" text-anchor="middle" font-size="{min(width, height)//10}" fill="black">Hello World</text>
    </svg>
    '''
    return svg_template.encode('utf-8')

def save_image_to_s3(image_data, object_key, content_type):
    s3 = boto3.client('s3', region_name='us-east-1')
    s3.put_object(Bucket='genato-images', Key=object_key, Body=image_data, ContentType=content_type)

def lambda_handler(event, context):
    try:
        request = event['Records'][0]['cf']['request']
        uri = request['uri']
        
        # Ignore certain URIs
        if uri in ['/favicon.ico']:
            return request
        
        # sample url: /640x480,white,png
        parts = uri.strip('/').split(',')
        size = parts[0].split('x')
        width, height = int(size[0]), int(size[1])
        color = parts[1]
        format = parts[2]
        object_key = uri.strip('/')
        
        s3 = boto3.client('s3', region_name='us-east-1')
        try:
            # Check if the object already exists in S3
            s3.head_object(Bucket='genato-images', Key=object_key)
            # If found, bypass processing and return the request
            return request
        except s3.exceptions.NoSuchKey:
            # Object doesn't exist, continue processing
            pass
        except Exception as ex:
            # If head_object fails because the object doesn't exist, AWS returns a ClientError.
            # Check for 404 error to determine non-existence.
            if ex.response['Error']['Code'] != '404':
                raise

        if format == 'png':
            image_data = generate_png_image(width, height, color)
            content_type = 'image/png'
        elif format == 'svg':
            image_data = generate_svg_image(width, height, color)
            content_type = 'image/svg+xml'
        else:
            raise ValueError("Unsupported format")
        
        save_image_to_s3(image_data, object_key, content_type)
        
        return request
    except Exception as e:
        print("Error:", e)
        return {
            'status': 500,
            'body': "Internal Server Error"
        }

if __name__ == '__main__':
    image_data = generate_png_image(400, 200, "white")
    with open("hello-world.png", "wb") as f:
        f.write(image_data)
    print("hello-world.png generated successfully.")
    
    svg_data = generate_svg_image(400, 200, "white")
    with open("hello-world.svg", "wb") as f:
        f.write(svg_data)
    print("hello-world.svg generated successfully.")
