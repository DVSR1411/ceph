import os
import boto3
from botocore.config import Config
from flask import Flask, request, jsonify, Response, send_from_directory
from flask_cors import CORS
from botocore.exceptions import ClientError
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)
CORS(app)

s3 = boto3.client(
    "s3",
    endpoint_url=f"http://{os.getenv('CEPH_RGW_HOST', 'localhost')}:{os.getenv('RGW_PORT')}",
    aws_access_key_id=os.getenv("RGW_ACCESS_KEY"),
    aws_secret_access_key=os.getenv("RGW_SECRET_KEY"),
    region_name=os.getenv("RGW_REGION", "us-east-1"),
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)

DEFAULT_BUCKET = os.getenv("CEPH_BUCKET")

def ensure_bucket():
    if not DEFAULT_BUCKET:
        return
    try:
        s3.head_bucket(Bucket=DEFAULT_BUCKET)
    except ClientError:
        s3.create_bucket(Bucket=DEFAULT_BUCKET)
        print(f"Created bucket: {DEFAULT_BUCKET}")

ensure_bucket()


def aws_error_response(error, status=500):
    error_info = error.response.get("Error", {})
    code = error_info.get("Code", "ClientError")
    message = error_info.get("Message", str(error))

    if code in {"NoSuchBucket", "404"}:
        status = 404

    return jsonify({"error": message, "code": code}), status


def empty_bucket(bucket):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket):
        objects = page.get("Contents", [])
        if not objects:
            continue
        response = s3.delete_objects(
            Bucket=bucket,
            Delete={
                "Objects": [{"Key": obj["Key"]} for obj in objects],
                "Quiet": True,
            },
        )
        errors = response.get("Errors", [])
        if errors:
            first_error = errors[0]
            raise ClientError(
                {
                    "Error": {
                        "Code": first_error.get("Code", "DeleteObjectsError"),
                        "Message": first_error.get("Message", "Failed to delete one or more objects"),
                    }
                },
                "DeleteObjects",
            )


@app.route("/upload", methods=["POST"])
@app.route("/upload/<bucket>", methods=["POST"])
def upload(bucket=None):
    bucket = bucket or DEFAULT_BUCKET
    if not bucket:
        return jsonify({"error": "No bucket specified and CEPH_BUCKET not set in .env"}), 400
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400
    file = request.files["file"]
    try:
        s3.upload_fileobj(file, bucket, file.filename)
        return jsonify({"message": f"{file.filename} uploaded to {bucket}"}), 200
    except ClientError as e:
        return aws_error_response(e)


@app.route("/buckets", methods=["GET"])
def list_buckets():
    try:
        buckets = [b["Name"] for b in s3.list_buckets().get("Buckets", [])]
        return jsonify({"buckets": buckets}), 200
    except ClientError as e:
        return aws_error_response(e)


@app.route("/buckets/<bucket>", methods=["POST", "DELETE"])
def manage_bucket(bucket):
    try:
        if request.method == "POST":
            s3.create_bucket(Bucket=bucket)
            return jsonify({"message": f"Bucket '{bucket}' created"}), 201
        else:
            empty_bucket(bucket)
            s3.delete_bucket(Bucket=bucket)
            return jsonify({"message": f"Bucket '{bucket}' deleted"}), 200
    except ClientError as e:
        return aws_error_response(e)


@app.route("/files/<bucket>", methods=["GET"])
def list_files(bucket):
    try:
        objects = s3.list_objects_v2(Bucket=bucket).get("Contents", [])
        files = [{"key": o["Key"], "size": o["Size"]} for o in objects]
        return jsonify({"files": files}), 200
    except ClientError as e:
        return aws_error_response(e)


@app.route("/download/<bucket>/<path:key>", methods=["GET"])
def download(bucket, key):
    try:
        obj = s3.get_object(Bucket=bucket, Key=key)
        return Response(
            obj["Body"].read(),
            headers={"Content-Disposition": f"attachment; filename={key}"},
            content_type=obj.get("ContentType", "application/octet-stream"),
        )
    except ClientError as e:
        return aws_error_response(e)


@app.route("/files/<bucket>/<path:key>", methods=["DELETE"])
def delete_file(bucket, key):
    try:
        s3.delete_object(Bucket=bucket, Key=key)
        return jsonify({"message": f"{key} deleted from {bucket}"}), 200
    except ClientError as e:
        return aws_error_response(e)


@app.route("/")
def index():
    return send_from_directory(".", "index.html")


if __name__ == "__main__":
    app.run(host='0.0.0.0',debug=True)
