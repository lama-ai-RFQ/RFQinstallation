#!/usr/bin/env python3
"""
Test script for downloading Mistral model from AWS S3
This script can be run independently to test the download functionality
"""

import os
import sys
import json
import subprocess

# Check if boto3 is installed, install if not
try:
    import boto3
    from botocore.exceptions import ClientError, NoCredentialsError
except ImportError:
    print("boto3 not found. Installing boto3...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "boto3", "--quiet"])
        import boto3
        from botocore.exceptions import ClientError, NoCredentialsError
        print("boto3 installed successfully!")
    except subprocess.CalledProcessError:
        print("ERROR: Failed to install boto3. Please install it manually:")
        print("  pip install boto3")
        sys.exit(1)

def read_env_file(env_path):
    """Read environment variables from .env file"""
    env_vars = {}
    if os.path.exists(env_path):
        with open(env_path, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    env_vars[key.strip()] = value.strip()
    return env_vars

def get_aws_credentials():
    """Get AWS credentials from environment, .env file, or prompt"""
    # Try environment variables first
    aws_key = os.environ.get('AWS_KEY') or os.environ.get('AWS_ACCESS_KEY_ID')
    aws_secret = os.environ.get('AWS_SECRET') or os.environ.get('AWS_SECRET_ACCESS_KEY')
    aws_region = os.environ.get('AWS_REGION') or os.environ.get('AWS_DEFAULT_REGION', 'us-east-1')
    
    # Try .env file in current directory or parent directories
    env_paths = [
        os.path.join(os.getcwd(), '.env'),
        os.path.join(os.path.dirname(os.path.dirname(__file__)), '.env'),
        os.path.join(os.path.expanduser('~'), '.env'),
    ]
    
    for env_path in env_paths:
        if os.path.exists(env_path):
            env_vars = read_env_file(env_path)
            if not aws_key and 'AWS_KEY' in env_vars:
                aws_key = env_vars['AWS_KEY']
            if not aws_secret and 'AWS_SECRET' in env_vars:
                aws_secret = env_vars['AWS_SECRET']
            if not aws_region and 'AWS_REGION' in env_vars:
                aws_region = env_vars['AWS_REGION']
            break
    
    # Prompt if still not found
    if not aws_key:
        aws_key = input("Enter AWS Access Key ID: ").strip()
    if not aws_secret:
        import getpass
        aws_secret = getpass.getpass("Enter AWS Secret Access Key: ").strip()
    if not aws_region:
        aws_region = input("Enter AWS Region (press Enter for us-east-1): ").strip() or 'us-east-1'
    
    return aws_key, aws_secret, aws_region

def download_model(model_dir, aws_key, aws_secret, aws_region):
    """Download model from S3"""
    bucket_name = "rfq-models"
    model_prefix = "Mistral-7B-Instruct-v0-3/"
    
    print("Starting model download from AWS S3...")
    print(f"Bucket: {bucket_name}")
    print(f"Region: {aws_region}")
    print(f"Destination: {model_dir}")
    print("")
    
    # Create destination directory
    os.makedirs(model_dir, exist_ok=True)
    
    # Initialize S3 client
    try:
        s3 = boto3.client(
            "s3",
            aws_access_key_id=aws_key,
            aws_secret_access_key=aws_secret,
            region_name=aws_region
        )
    except Exception as e:
        print(f"ERROR: Failed to initialize S3 client: {e}")
        sys.exit(1)
    
    # List all objects in the model directory
    print("Listing model files in S3...")
    files_downloaded = 0
    total_size = 0
    
    try:
        paginator = s3.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=bucket_name, Prefix=model_prefix)
        
        for page in pages:
            if 'Contents' not in page:
                continue
                
            for obj in page['Contents']:
                key = obj['Key']
                size = obj['Size']
                
                # Skip directories
                if key.endswith('/'):
                    continue
                
                # Skip cache files and metadata files
                if '.cache' in key or key.endswith('.lock') or key.endswith('.metadata'):
                    continue
                
                # Get relative path from model prefix
                relative_path = key[len(model_prefix):]
                local_path = os.path.join(model_dir, relative_path)
                
                # Create subdirectories if needed
                local_dir = os.path.dirname(local_path)
                if local_dir:
                    os.makedirs(local_dir, exist_ok=True)
                
                # Download file
                print(f"Downloading: {relative_path} ({size / 1024 / 1024:.4f} MB)")
                s3.download_file(bucket_name, key, local_path)
                files_downloaded += 1
                total_size += size
    except ClientError as list_error:
        error_code = list_error.response.get('Error', {}).get('Code', '')
        if error_code == 'AccessDenied':
            print("")
            print("WARNING: Access denied when listing bucket contents.")
            print("Your IAM user may not have s3:ListBucket permission.")
            print("")
            print("Attempting to download common model files directly...")
            print("(This requires s3:GetObject permission)")
            print("")
            
            # First, try to download the model index file to get the list of all files
            index_file = "model.safetensors.index.json"
            index_key = model_prefix + index_file
            index_local_path = os.path.join(model_dir, index_file)
            model_files_from_index = []
            
            try:
                # Try to get index file metadata first
                obj_metadata = s3.head_object(Bucket=bucket_name, Key=index_key)
                index_size = obj_metadata['ContentLength']
                
                # Create directory if needed
                local_dir = os.path.dirname(index_local_path)
                if local_dir:
                    os.makedirs(local_dir, exist_ok=True)
                
                # Try to download the index file first
                print(f"Downloading index file: {index_file} ({index_size / 1024 / 1024:.4f} MB)")
                s3.download_file(bucket_name, index_key, index_local_path)
                files_downloaded += 1
                total_size += index_size
                
                # Parse the index file to get list of all model files
                with open(index_local_path, 'r') as f:
                    index_data = json.load(f)
                    if 'weight_map' in index_data:
                        # Extract unique filenames from weight_map
                        model_files_from_index = list(set(index_data['weight_map'].values()))
                        print(f"Found {len(model_files_from_index)} model files in index")
            except ClientError as e:
                error_code = e.response.get('Error', {}).get('Code', '')
                if error_code == 'AccessDenied':
                    print(f"Access denied for index file, trying common files...")
                else:
                    print(f"Index file not available, trying common files...")
            except Exception as e:
                print(f"Could not parse index file: {e}")
            
            # Try to download common model files directly
            common_files = [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "generation_config.json",
            ]
            
            # Combine files from index with common files
            all_files = list(set(common_files + model_files_from_index))
            
            for filename in all_files:
                key = model_prefix + filename
                local_path = os.path.join(model_dir, filename)
                
                try:
                    # Try to get object metadata first to check if it exists
                    try:
                        obj_metadata = s3.head_object(Bucket=bucket_name, Key=key)
                        size = obj_metadata['ContentLength']
                    except ClientError:
                        # File doesn't exist, skip
                        continue
                    
                    # Create subdirectories if needed
                    local_dir = os.path.dirname(local_path)
                    if local_dir:
                        os.makedirs(local_dir, exist_ok=True)
                    
                    # Download file
                    print(f"Downloading: {filename} ({size / 1024 / 1024:.4f} MB)")
                    s3.download_file(bucket_name, key, local_path)
                    files_downloaded += 1
                    total_size += size
                except ClientError as download_error:
                    error_code = download_error.response.get('Error', {}).get('Code', '')
                    if error_code == 'AccessDenied':
                        print(f"  [!] Access denied for: {filename}")
                    else:
                        print(f"  [!] Error downloading {filename}: {download_error}")
                    continue
                except Exception as e:
                    print(f"  [!] Error downloading {filename}: {e}")
                    continue
            
            if files_downloaded == 0:
                print("")
                print("ERROR: Could not download any files.")
                print("")
                print("Required AWS IAM permissions:")
                print("  - s3:ListBucket on arn:aws:s3:::rfq-models")
                print("  - s3:GetObject on arn:aws:s3:::rfq-models/Mistral-7B-Instruct-v0-3/*")
                print("")
                print("Please contact your AWS administrator to grant these permissions.")
                sys.exit(1)
        else:
            # Re-raise if it's not an AccessDenied error
            raise
    
    if files_downloaded == 0:
        print("")
        print("WARNING: No files found in S3 bucket. Check bucket name and prefix.")
        sys.exit(1)
    
    print("")
    print(f"SUCCESS: Model downloaded successfully!")
    print(f"Files downloaded: {files_downloaded}")
    print(f"Total size: {total_size / 1024 / 1024 / 1024:.2f} GB")
    print(f"Model location: {model_dir}")
    return True

def main():
    """Main function"""
    import argparse
    
    parser = argparse.ArgumentParser(description='Test script for downloading Mistral model from AWS S3')
    parser.add_argument('--model-dir', type=str, 
                       default=os.path.join(os.path.expanduser('~'), 'Documents', 'RFQ_Models', 'Mistral-7B-Instruct-v0-3'),
                       help='Directory to download model to (default: ~/Documents/RFQ_Models/Mistral-7B-Instruct-v0-3)')
    parser.add_argument('--aws-key', type=str, help='AWS Access Key ID')
    parser.add_argument('--aws-secret', type=str, help='AWS Secret Access Key')
    parser.add_argument('--aws-region', type=str, default='us-east-1', help='AWS Region (default: us-east-1)')
    
    args = parser.parse_args()
    
    # Get AWS credentials
    if args.aws_key and args.aws_secret:
        aws_key = args.aws_key
        aws_secret = args.aws_secret
        aws_region = args.aws_region
    else:
        aws_key, aws_secret, aws_region = get_aws_credentials()
    
    # Download model
    try:
        success = download_model(args.model_dir, aws_key, aws_secret, aws_region)
        if success:
            print("")
            print("Test completed successfully!")
            sys.exit(0)
    except NoCredentialsError:
        print("")
        print("ERROR: AWS credentials not found or invalid")
        print("Please check AWS_KEY, AWS_SECRET, and AWS_REGION")
        sys.exit(1)
    except ClientError as e:
        print("")
        print(f"ERROR: AWS S3 error: {e}")
        sys.exit(1)
    except Exception as e:
        print("")
        print(f"ERROR: Failed to download model: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == '__main__':
    main()

