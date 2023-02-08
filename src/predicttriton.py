# Copyright 2022 Google LLC

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     https://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Simple Flask prediction for a model.

Simple Flask prediction for a model.
"""
import argparse
import os
import subprocess
from typing import List, Tuple

from absl import app as absl_app
from absl import flags
from absl import logging
from absl.flags import argparse_flags
from flask import Flask
from flask import request
import gcsfs
from tritonlocal import T5TritonProcessor 
from transformers import AutoTokenizer

app = Flask(__name__)
FLAGS = flags.FLAGS

flags.DEFINE_integer("port", 5000, "port to expose this server on. Default is '5000'.")
flags.DEFINE_integer("triton_port", 8000, "local triton server port to proxy requests to. Default is '8000'.")
flags.DEFINE_string("triton_host", "localhost", "Optional. Separate host to route triton requests to. Default is 'localhost'.")
flags.DEFINE_string("hf_model_path", "t5-base", "path to the source model on HuggingFace. For example 'google/t5-v1_1-base'.")
flags.DEFINE_string("model_path", "t5-base", "path to the FT converted model on GCS or local filesystem. For example '/all_models/t5-v1_1-base'")

def init_model():
  """Initializes the model using Triton."""
  os.environ["TOKENIZERS_PARALLELISM"] = "false"

  model_path = os.environ.get("AIP_STORAGE_URI", FLAGS.model_path)
  logging.info("Model path: %s", model_path)
  if model_path.startswith("gs://"):
    src = model_path.replace("gs://", "")
    dst = "/workspace/all_models/" + src.split("/")[-1] + "/"
    app.model_directory = dst
    gcs = gcsfs.GCSFileSystem()
    logging.info("Downloading model from %s", model_path)
    gcs.get(src, dst, recursive=True)
    model_path = dst

  app.model_directory = model_path

  app.client = T5TritonProcessor(FLAGS.hf_model_path, FLAGS.triton_host, FLAGS.triton_port)


@app.route("/health")
def health():
  return {"health": "ok"}


@app.route("/summarize", methods=["POST"])
def summarize():
  """Process a summarization request."""
  logging.info("Received request")
  inputs = app.tokenizer(
      
      return_tensors="pt",
      padding=True,
      truncation=True).to(device=app.local_rank)
  text_out = app.client.infer(task="summarize", text=request.json["instances"]) 
  return {"predictions": list(text_out)}


def parse_flags(argv: List[str]) -> Tuple[argparse.Namespace, List[str]]:
  """Parses command line arguments entry_point.

  Args:
    argv: Unparsed arguments.

  Returns:
    Tuple of an argparse result and remaining args.
  """
  parser = argparse_flags.ArgumentParser(allow_abbrev=False)
  return parser.parse_known_args(argv)


def main(argv):
  """Main server method.

  Args:
    argv: unused.
  """
  del argv
  app.host = os.environ.get("SERVER_HOST", "localhost")
  app.port = int(os.environ.get("AIP_HTTP_PORT", str(FLAGS.port)))

  init_model()
  subprocess.Popen(["/opt/tritonserver/bin/tritonserver", f'--model-repository={app.model_directory}'])
  app.run(app.host, app.port, debug=False)


if __name__ == "__main__":
  absl_app.run(main, flags_parser=parse_flags)
