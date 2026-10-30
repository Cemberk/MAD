"""Print the software stack of the image being built, as JSON.

Run as the last step of the global_univ2 Dockerfiles; the output is stored at
/opt/mad/build_info.json, which madengine copies into build_manifest.json as
image_info for each image_spec build.
"""

import json
import os
import sys
from importlib import metadata

packages = {}
for dist in metadata.distributions():
    name = dist.metadata.get("Name")
    if name:
        packages[name.lower()] = dist.version

info = {"python": "%d.%d.%d" % sys.version_info[:3]}

rocm_info = "/opt/rocm/.info/version"
if os.path.exists(rocm_info):
    with open(rocm_info) as f:
        info["rocm_version"] = f.read().strip()
elif "rocm" in packages:
    info["rocm_version"] = packages["rocm"]

cuda_info = "/usr/local/cuda/version.json"
if os.path.exists(cuda_info):
    with open(cuda_info) as f:
        info["cuda_version"] = json.load(f)["cuda"]["version"]
elif os.environ.get("CUDA_VERSION"):
    info["cuda_version"] = os.environ["CUDA_VERSION"]

if os.path.exists("/tmp/.docker_type"):
    with open("/tmp/.docker_type") as f:
        info["docker_type"] = f.read().strip()

info["packages"] = dict(sorted(packages.items()))
print(json.dumps(info, indent=1))
