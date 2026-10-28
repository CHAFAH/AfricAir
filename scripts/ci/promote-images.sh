#!/usr/bin/env bash
set -Eeuo pipefail
# Build once, promote by digest: add tag <release> to the manifest already tagged <sha> in ECR.
# No pull, no rebuild: `put-image` with the existing manifest, so the digests are identical by construction.
# Usage: scripts/ci/promote-images.sh <git-sha> <release-tag>
SHA=${1:?git sha}
RELEASE=${2:?release tag}
for repo in africair-web africair-api; do
  manifest=$(aws ecr batch-get-image --repository-name "$repo" --image-ids imageTag="$SHA" \
    --accepted-media-types application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json \
      application/vnd.oci.image.manifest.v1+json application/vnd.docker.distribution.manifest.v2+json \
    --query 'images[0].imageManifest' --output text)
  if [[ -z $manifest || $manifest == None ]]; then
    echo "$repo:$SHA not found: only commits built on main can be released" >&2
    exit 1
  fi
  media_type=$(jq -r .mediaType <<<"$manifest")
  existing=$(aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$RELEASE" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || true)
  source_digest=$(aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$SHA" \
    --query 'imageDetails[0].imageDigest' --output text)
  if [[ -n $existing && $existing != None ]]; then
    [[ $existing == "$source_digest" ]] || { echo "$repo:$RELEASE already exists with another digest" >&2; exit 1; }
  else
    aws ecr put-image --repository-name "$repo" --image-tag "$RELEASE" \
      --image-manifest "$manifest" --image-manifest-media-type "$media_type" >/dev/null
  fi
  released=$(aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$RELEASE" \
    --query 'imageDetails[0].imageDigest' --output text)
  [[ $released == "$source_digest" ]] || { echo "$repo digest mismatch after promotion" >&2; exit 1; }
  echo "$repo $SHA -> $RELEASE $released"
done
